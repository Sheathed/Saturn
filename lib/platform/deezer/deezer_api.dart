import 'package:saturn/platform/platform_manager.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:saturn/main.dart';
import '../../api/definitions.dart';
import '../../settings.dart';
import '../../utils/json_isolate.dart';
import '../music_platform.dart';

DeezerAPI deezerAPI = DeezerAPI();

class DeezerAPI {
  DeezerAPI({this.arl, this.settingsMap});

  String? arl;
  String? token;
  String? licenseToken;
  String? userId;
  String? userName;
  String? favoritesPlaylistId;
  String? sid;
  Map<String, dynamic>? settingsMap;

  Future? _authorizing;

  // Helper to get settings value, fallback to global settings if settingsMap not provided
  String get _deezerLanguage =>
      settingsMap?['deezerLanguage'] ?? settings.deezerLanguage;
  String get _deezerCountry =>
      settingsMap?['deezerCountry'] ?? settings.deezerCountry;

  //Get headers
  Map<String, String> get headers => {
    'User-Agent':
        'Deezer/8.0.0.0 (Android; ${8 + Random().nextInt(8)}; Tablet; $_deezerLanguage)',
    'Content-Language': '$_deezerLanguage-$_deezerCountry',
    'Content-Type': 'text/plain;charset=UTF-8',
    //'origin': 'https://www.deezer.com',
    //'Cache-Control': 'max-age=0',
    'Accept': '*/*',
    'Accept-Charset': 'utf-8,ISO-8859-1;q=0.7,*;q=0.3',
    'Accept-Language':
        '$_deezerLanguage-$_deezerCountry,$_deezerLanguage;q=0.9,en-US;q=0.8,en;q=0.7',
    'Connection': 'keep-alive',
    //'sec-fetch-site': 'same-origin',
    //'sec-fetch-mode': 'same-origin',
    //'sec-fetch-dest': 'empty',
    //'referer': 'https://www.deezer.com/',
    'Cookie': 'arl=$arl' + ((sid == null) ? '' : '; sid=$sid'),
  };

  //Call private GW-light API
  Future<Map<String, dynamic>> callGwApi(
    String method, {
    Map<String, dynamic>? params,
    String? gatewayInput,
    bool useGet = false,
    bool useWebHeaders = false,
  }) async {
    //Generate URL
    Uri uri = Uri.https('www.deezer.com', '/ajax/gw-light.php', {
      'api_version': '1.0',
      'api_token': token,
      'input': '3',
      'method': method,
      'cid': Random().nextInt(1000000000).toString(),
      //Used for homepage
      'gateway_input': ?gatewayInput,
    });
    final requestHeaders = <String, String>{...headers};
    if (useGet) {
      requestHeaders.remove('Content-Type');
    }
    if (useWebHeaders) {
      requestHeaders.addAll({
        'User-Agent':
            'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
        'Origin': 'https://www.deezer.com',
        'Referer': 'https://www.deezer.com/',
        'Accept': 'application/json, text/plain, */*',
      });
    }
    final http.Response res = useGet
        ? await http.get(uri, headers: requestHeaders)
        : await http.post(
            uri,
            headers: requestHeaders,
            body: jsonEncode(params),
          );
    dynamic body = await decodeJsonAsync(res.body);
    //Grab SID
    if (method == 'deezer.getUserData' && res.headers['set-cookie'] != null) {
      for (String cookieHeader in res.headers['set-cookie']!.split(';')) {
        if (cookieHeader.startsWith('sid=')) {
          sid = cookieHeader.split('=')[1];
        }
      }
    }
    // In case of error "Invalid CSRF token" retrieve new one and retry the same call
    // Except for "deezer.getUserData" method, which would cause infinite loop
    if (body['error'].isNotEmpty &&
        body['error'].containsKey('VALID_TOKEN_REQUIRED') &&
        (method != 'deezer.getUserData' && await rawAuthorize())) {
      return callGwApi(
        method,
        params: params,
        gatewayInput: gatewayInput,
        useGet: useGet,
        useWebHeaders: useWebHeaders,
      );
    }
    return body;
  }

  Future<Map<dynamic, dynamic>> callPublicApi(String path) async {
    http.Response res = await http.get(
      Uri.parse('https://api.deezer.com/' + path),
    );
    return await decodeJsonAsync(res.body);
  }

  Future<String> getJsonWebToken() async {
    Uri uri = Uri.https('auth.deezer.com', '/login/arl', {
      'jo': 'p',
      'rto': 'c',
      'i': 'c',
    });
    //Post
    http.Response res = await http.post(uri, headers: headers);
    dynamic body = await decodeJsonAsync(res.body);
    //Grab jwt token
    if (body['jwt']?.isNotEmpty == true) {
      return body['jwt'];
    }
    return '';
  }

  //Call private pipe API
  Future<Map<String, dynamic>> callPipeApi({
    Map<String, dynamic>? params,
  }) async {
    //Get jwt auth token
    String jwtToken = await getJsonWebToken();
    Map<String, String> pipeApiHeaders = Map<String, String>.from(headers);
    // Add jwt token to headers
    if (jwtToken.isNotEmpty) {
      pipeApiHeaders['Authorization'] = 'Bearer $jwtToken';
    }
    // Change Content-Type to application/json
    pipeApiHeaders['Content-Type'] = 'application/json';
    Uri uri = Uri.https('pipe.deezer.com', '/api/');
    //Post
    http.Response res = await http.post(
      uri,
      headers: pipeApiHeaders,
      body: jsonEncode(params),
    );
    dynamic body = await decodeJsonAsync(res.body);

    return body;
  }

  //Wrapper so it can be globally awaited
  Future<bool> authorize() async {
    return await (_authorizing ??= rawAuthorize().then((success) {
      _authorizing = null;
      return success;
    }));
  }

  //Authorize, bool = success
  Future<bool> rawAuthorize({Function? onError}) async {
    try {
      Map<dynamic, dynamic> data = await callGwApi('deezer.getUserData');
      if (data['results']['USER']['USER_ID'] == 0) {
        return false;
      } else {
        token = data['results']['checkForm'];
        userId = data['results']['USER']['USER_ID']?.toString() ?? '';
        userName = data['results']['USER']['BLOG_NAME'];
        favoritesPlaylistId = data['results']['USER']['LOVEDTRACKS_ID'];
        licenseToken = data['results']['USER']['OPTIONS']['license_token'];
        return true;
      }
    } catch (e) {
      if (onError != null) {
        onError(e);
      }
      Logger.root.severe('Login Error (D): ' + e.toString());
      return false;
    }
  }

  //URL/Link parser
  Future<DeezerLinkResponse?> parseLink(String url) async {
    Uri uri = Uri.parse(url);
    //https://www.deezer.com/NOTHING_OR_COUNTRY/TYPE/ID
    if (uri.host == 'www.deezer.com' || uri.host == 'deezer.com') {
      if (uri.pathSegments.length < 2) return null;
      DeezerLinkType? type = DeezerLinkResponse.typeFromString(
        uri.pathSegments[uri.pathSegments.length - 2],
      );
      return DeezerLinkResponse(
        type: type,
        id: uri.pathSegments[uri.pathSegments.length - 1],
      );
    }
    //Share URL
    if (uri.host == 'dzr.page.link' || uri.host == 'www.dzr.page.link') {
      http.BaseRequest request = http.Request('HEAD', Uri.parse(url));
      request.followRedirects = false;
      http.StreamedResponse response = await request.send();
      String newUrl = response.headers['location'] ?? '';
      return parseLink(newUrl);
    }
    return null;
  }

  //Check if Deezer available in country
  static Future<bool?> checkAvailability() async {
    try {
      http.Response res = await http.get(
        Uri.parse('https://api.deezer.com/infos'),
      );
      return jsonDecode(res.body)['open'];
    } catch (e) {
      return null;
    }
  }

  //Search
  Future<SearchResults> search(String query) async {
    Map<String, dynamic> data = await callGwApi(
      'deezer.pageSearch',
      params: {'nb': 128, 'query': query, 'start': 0},
    );
    return SearchResults.fromPrivateJson(data['results']);
  }

  Future<Track> track(String id) async {
    Map<dynamic, dynamic> data = await callGwApi(
      'song.getListData',
      params: {
        'sng_ids': [id],
      },
    );
    return Track.fromPrivateJson(data['results']['data'][0]);
  }

  Future<Map<String, dynamic>?> trackFull(String id) async {
    const query = r'''
query TrackFull($trackId: String!) {
  track(trackId: $trackId) {
    id
    title
    duration
    isExplicit
    album {
      id
      displayTitle
      releaseDate
      isExplicit
      cover {
        small: urls(pictureRequest: {height: 100, width: 100})
        medium: urls(pictureRequest: {width: 264, height: 264})
        large: urls(pictureRequest: {width: 500, height: 500})
      }
      contributors {
        edges {
          node {
            ... on Artist {
              id
              name
            }
          }
        }
      }
    }
    contributors {
      edges {
        node {
          ... on Artist {
            id
            name
            picture {
              small: urls(pictureRequest: {height: 100, width: 100})
              medium: urls(pictureRequest: {width: 264, height: 264})
            }
          }
        }
      }
    }
    lyrics {
      id
      copyright
      text
      writers
      synchronizedLines {
        line
      }
    }
    relatedTracks(first: 10) {
      edges {
        node {
          id
          title
          duration
          album {
            id
            displayTitle
            cover {
              small: urls(pictureRequest: {height: 100, width: 100})
              medium: urls(pictureRequest: {width: 264, height: 264})
            }
          }
          contributors {
            edges {
              node {
                ... on Artist {
                  id
                  name
                }
              }
            }
          }
        }
      }
    }
  }
}
''';
    try {
      final res = await callPipeApi(
        params: {
          'operationName': 'TrackFull',
          'query': query,
          'variables': {'trackId': id},
        },
      );
      if (res['data']?['track'] != null) {
        return (res['data']['track'] as Map).cast<String, dynamic>();
      }
    } catch (e) {
      Logger.root.warning('Deezer trackFull error: $e');
    }
    return null;
  }

  Future<List<Track>> tracks(List<String> ids) async {
    Map<dynamic, dynamic> data = await callGwApi(
      'song.getListData',
      params: {'sng_ids': ids},
    );
    return data['results']['data']
        .map<Track>((json) => Track.fromPrivateJson(json))
        .toList();
  }

  //Get album details, tracks
  Future<Album> album(String id) async {
    Map<dynamic, dynamic> data = await callGwApi(
      'deezer.pageAlbum',
      params: {'alb_id': id, 'header': true, 'lang': _deezerLanguage},
    );
    if (data['error'] != null &&
        data['payload'] != null &&
        data['payload']['FALLBACK']['ALB_ID'] != null) {
      Map<dynamic, dynamic> fbdata = await callGwApi(
        'deezer.pageAlbum',
        params: {
          'alb_id': data['payload']['FALLBACK']['ALB_ID'],
          'header': true,
          'lang': _deezerLanguage,
        },
      );
      data = fbdata;
    }
    final album = Album.fromPrivateJson(
      data['results']['DATA'],
      songsJson: data['results']['SONGS'],
    );
    album.platformId = 'deezer';
    try {
      const query = r'''
        query AlbumAIContent($albumId: String!) {
          album(albumId: $albumId) {
            hasIdentifiedAIContent
          }
        }
      ''';
      final pipeData = await callPipeApi(
        params: {
          'operationName': 'AlbumAIContent',
          'variables': {'albumId': id},
          'query': query,
        },
      );
      final albumData = pipeData['data']?['album'];
      if (albumData is Map) {
        album.hasIdentifiedAIContent =
            albumData['hasIdentifiedAIContent'] == true;
      }
    } catch (error, stackTrace) {
      // Keep album loading available if the optional Pipe API metadata fails.
      Logger.root.fine(
        'Could not read Deezer AI-content flag for album $id: $error',
        error,
        stackTrace,
      );
    }
    return album;
  }

  //Get artist details
  Future<Artist> artist(String id) async {
    Map<dynamic, dynamic> data = await callGwApi(
      'deezer.pageArtist',
      params: {'art_id': id, 'lang': _deezerLanguage},
    );
    final results = data['results'];
    final artistData = results is Map ? results['DATA'] : null;
    if (results is! Map || artistData is! Map) {
      throw FormatException('Deezer artist $id has no artist data');
    }
    final details = Artist.fromPrivateJson(artistData);
    details.id ??= id;
    final albumsSection = results['ALBUMS'];
    if (albumsSection is Map) {
      details.albumCount = _intValue(albumsSection['total']);
    }
    details.albums = _privateItems(albumsSection)
        .map((item) {
          try {
            return Album.fromPrivateJson(item);
          } catch (error) {
            Logger.root.fine('Skipping malformed Deezer artist album: $error');
            return null;
          }
        })
        .whereType<Album>()
        .toList();
    details.topTracks = _privateItems(results['TOP'])
        .map((item) {
          try {
            return Track.fromPrivateJson(item);
          } catch (error) {
            Logger.root.fine('Skipping malformed Deezer artist track: $error');
            return null;
          }
        })
        .whereType<Track>()
        .toList();
    final highlight = results['HIGHLIGHT'];
    if (highlight is Map) {
      try {
        details.highlight = ArtistHighlight.fromPrivateJson(highlight);
      } catch (error) {
        Logger.root.fine('Skipping malformed Deezer artist highlight: $error');
      }
    }
    final bioSection = results['BIO'];
    final bio = bioSection is Map ? bioSection['BIO']?.toString() : null;
    details.description = _htmlToPlainText(bio);
    final status = artistData['STATUS'];
    final artistMessage = status is Map ? status['status']?.toString() : null;
    details.customData = {
      if (artistMessage != null && artistMessage.trim().isNotEmpty)
        'artistMessage': artistMessage.trim(),
    };
    details.playlists =
        [
              ..._privateItems(results['SELECTED_PLAYLIST']),
              ..._privateItems(results['RELATED_PLAYLIST']),
            ]
            .where((item) => item['PLAYLIST_ID'] != null)
            .map((item) {
              try {
                final imageHash = item['PLAYLIST_PICTURE']?.toString();
                return Playlist(
                  id: item['PLAYLIST_ID'].toString(),
                  title: item['TITLE']?.toString(),
                  trackCount: _intValue(item['NB_SONG'] ?? item['NB_TRACKS']),
                  image: imageHash == null || imageHash.isEmpty
                      ? null
                      : ImageDetails.fromPrivateString(
                          imageHash,
                          type: item['PICTURE_TYPE']?.toString() ?? 'playlist',
                        ),
                  description: item['DESCRIPTION']?.toString(),
                  platformId: 'deezer',
                );
              } catch (error) {
                Logger.root.fine('Skipping malformed Deezer playlist: $error');
                return null;
              }
            })
            .whereType<Playlist>()
            .toList();
    details.similarArtists = _privateItems(results['RELATED_ARTISTS'])
        .where((item) => item['ART_ID'] != null)
        .map((item) {
          try {
            return Artist.fromPrivateJson(item)..platformId = 'deezer';
          } catch (error) {
            Logger.root.fine('Skipping malformed related artist: $error');
            return null;
          }
        })
        .whereType<Artist>()
        .toList();
    try {
      await getArtistPlaylists(details, limit: 50);
    } catch (error, stackTrace) {
      Logger.root.warning(
        'Failed to fetch Deezer artist playlists from Pipe API',
        error,
        stackTrace,
      );
    }
    details.pageSectionsLoaded = true;
    return details;
  }

  Future<List<Playlist>> getArtistPlaylists(Artist artist, {int? limit}) async {
    final artistId = artist.id;
    if (artistId == null || artistId.isEmpty || (limit != null && limit <= 0)) {
      return const [];
    }

    var loaded = artist.customData['artistPlaylistsLoaded'] == true;
    final playlists = List<Playlist>.of(loaded ? artist.playlists : const []);
    var hasNextPage = artist.customData['artistPlaylistsHasNextPage'] == true;
    var cursor = artist.customData['artistPlaylistsEndCursor'] as String?;

    while (!loaded ||
        (hasNextPage && (limit == null || playlists.length < limit))) {
      final response = await callPipeApi(
        params: {
          'operationName': 'ArtistRelatedPlaylists',
          'variables': {
            'artistId': artistId,
            'relatedPlaylistFirst': 50,
            'cursor': cursor,
          },
          'query': _artistRelatedPlaylistsQuery,
        },
      );
      final data = response['data'] as Map?;
      final artistData = data?['artist'] as Map?;
      final connection =
          ((artistData?['playlists'] as Map?)?['relatedPlaylists'] as Map?);
      if (connection == null) {
        final errors = response['errors'];
        throw StateError(
          'Pipe API artist playlists response was invalid: $errors',
        );
      }

      final edges = connection['edges'] as List? ?? const [];
      for (final edgeValue in edges) {
        if (edgeValue is! Map) {
          continue;
        }
        final node = edgeValue['node'];
        if (node is! Map) {
          continue;
        }
        final id = node['id']?.toString();
        if (id == null ||
            id.isEmpty ||
            playlists.any((item) => item.id == id)) {
          continue;
        }
        final picture = node['picture'] as Map?;
        final urls = picture?['large'] as List? ?? const [];
        final imageUrl = urls.whereType<String>().firstOrNull;
        final owner = node['owner'] as Map?;
        final playlist = Playlist(
          id: id,
          title: node['title']?.toString(),
          fans: _intValue(node['fansCount']),
          trackCount: _intValue(node['estimatedTracksCount']),
          image: imageUrl == null
              ? null
              : ImageDetails(fullUrl: imageUrl, thumbUrl: imageUrl),
          user: owner == null
              ? null
              : User(
                  id: owner['id']?.toString(),
                  name: owner['name']?.toString(),
                ),
          library: node['isFavorite'] as bool?,
          editable:
              node['isPrivate'] == true || node['isCollaborative'] == true,
          platformId: 'deezer',
        );
        playlists.add(playlist);
      }

      final pageInfo = connection['pageInfo'] as Map?;
      loaded = true;
      hasNextPage = pageInfo?['hasNextPage'] == true;
      cursor = pageInfo?['endCursor']?.toString();
      if (edges.isEmpty || cursor == null || cursor.isEmpty) {
        hasNextPage = false;
      }
      artist.customData = {
        ...artist.customData,
        'artistPlaylistsLoaded': true,
        'artistPlaylistsHasNextPage': hasNextPage,
        'artistPlaylistsEndCursor': cursor,
      };
      artist.playlists = playlists;
    }

    return List<Playlist>.of(limit == null ? playlists : playlists.take(limit));
  }

  static int? _intValue(dynamic value) =>
      value is int ? value : int.tryParse(value?.toString() ?? '');

  static const String _artistRelatedPlaylistsQuery = '''
    query ArtistRelatedPlaylists(\$artistId: String!, \$relatedPlaylistFirst: Int!, \$cursor: String) {
      artist(artistId: \$artistId) {
        playlists {
          relatedPlaylists(first: \$relatedPlaylistFirst, after: \$cursor) {
            edges {
              node {
                id
                title
                fansCount
                picture {
                  large: urls(pictureRequest: {width: 500, height: 500})
                }
                owner { id name }
                isPrivate
                isCollaborative
                isFavorite
                estimatedTracksCount
              }
            }
            pageInfo { hasNextPage endCursor }
          }
        }
      }
    }
  ''';

  List<Map<dynamic, dynamic>> _privateItems(dynamic section) {
    final data = (section as Map?)?['data'];
    if (data is! List) return [];
    return data.whereType<Map>().toList(growable: false);
  }

  String? _htmlToPlainText(String? html) {
    if (html == null || html.trim().isEmpty) return null;
    return html
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</p\s*>', caseSensitive: false), '\n\n')
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .trim();
  }

  //Get playlist tracks at offset
  Future<List<Track>> playlistTracksPage(
    String id,
    int start, {
    int nb = 50,
  }) async {
    Map data = await callGwApi(
      'deezer.pagePlaylist',
      params: {
        'playlist_id': id,
        'lang': _deezerLanguage,
        'nb': nb,
        'tags': true,
        'start': start,
      },
    );
    return data['results']['SONGS']['data']
        .map<Track>((json) => Track.fromPrivateJson(json))
        .toList();
  }

  //Get playlist details
  Future<Playlist> playlist(String id, {int nb = 100}) async {
    Map<dynamic, dynamic> data = await callGwApi(
      'deezer.pagePlaylist',
      params: {
        'playlist_id': id,
        'lang': _deezerLanguage,
        'nb': nb,
        'tags': true,
        'start': 0,
      },
    );
    final p = Playlist.fromPrivateJson(
      data['results']['DATA'],
      songsJson: data['results']['SONGS'],
    );
    if (p.user?.id == userId) {
      p.editable = true;
    }
    return p;
  }

  //Get playlist with all tracks
  Future<Playlist> fullPlaylist(String id) async {
    return await playlist(id, nb: 100000);
  }

  //Add track to favorites
  Future addFavoriteTrack(String id) async {
    await callGwApi('favorite_song.add', params: {'SNG_ID': id});
  }

  //Add album to favorites/library
  Future addFavoriteAlbum(String id) async {
    await callGwApi('album.addFavorite', params: {'ALB_ID': id});
  }

  //Add artist to favorites/library
  Future addFavoriteArtist(String id) async {
    await callGwApi('artist.addFavorite', params: {'ART_ID': id});
  }

  //Add show to favorites/library
  Future addFavoriteShow(String id) async {
    await callGwApi('show.addFavorite', params: {'SHOW_ID': id});
  }

  //Remove show from favorites/library
  Future removeShow(String id) async {
    await callGwApi('show.deleteFavorite', params: {'SHOW_ID': id});
  }

  //Remove artist from favorites/library
  Future removeArtist(String id) async {
    await callGwApi('artist.deleteFavorite', params: {'ART_ID': id});
  }

  // Mark track as disliked
  Future dislikeTrack(String id) async {
    await callGwApi('favorite_dislike.add', params: {'ID': id, 'TYPE': 'song'});
  }

  //Add tracks to playlist
  Future addToPlaylist(
    String trackId,
    String playlistId, {
    int offset = -1,
  }) async {
    await callGwApi(
      'playlist.addSongs',
      params: {
        'offset': offset,
        'playlist_id': playlistId,
        'songs': [
          [trackId, 0],
        ],
      },
    );
  }

  //Remove track from playlist
  Future removeFromPlaylist(String trackId, String playlistId) async {
    await callGwApi(
      'playlist.deleteSongs',
      params: {
        'playlist_id': playlistId,
        'songs': [
          [trackId, 0],
        ],
      },
    );
  }

  //Get users playlists
  Future<List<Playlist>> getPlaylists() async {
    Map data = await callGwApi(
      'deezer.pageProfile',
      params: {'nb': 100, 'tab': 'playlists', 'user_id': userId},
    );
    return data['results']['TAB']['playlists']['data'].map<Playlist>((json) {
      final p = Playlist.fromPrivateJson(json, library: true);
      p.editable = true;
      return p;
    }).toList();
  }

  //Get users playlists
  Future<List<Show>> getShows() async {
    Map data = await callGwApi(
      'deezer.pageProfile',
      params: {'nb': 100, 'tab': 'shows', 'user_id': userId},
    );
    return data['results']['TAB']['shows']['data']
        .map<Show>((json) => Show.fromPrivateJson(json))
        .toList();
  }

  //Get favorite trackIds
  Future<List<String>?> getFavoriteTrackIds() async {
    Map data = await callGwApi(
      'user.getAllFeedbacks',
      params: {'checksums': null},
    );
    final songsData = data['results']?['FAVORITES']?['SONGS']?['data'];

    if (songsData is List) {
      return songsData.map<String>((song) => song['SNG_ID'] as String).toList();
    }
    return null;
  }

  // Get listening history tracks
  Future<HistoryTrackPage> getHistoryTracks({
    String? cursor,
    int limit = 100,
  }) async {
    final start = cursor != null ? int.tryParse(cursor) ?? 0 : 0;
    final Map<String, dynamic> data = await callGwApi(
      'user.getSongsHistory',
      params: {'nb': limit, 'start': start},
    );

    final results = data['results'];
    if (results == null || results is! Map) {
      return const HistoryTrackPage(tracks: []);
    }

    final rawList = results['data'];
    if (rawList is! List || rawList.isEmpty) {
      return const HistoryTrackPage(tracks: []);
    }

    final total = results['total'];
    final totalCount = total is num
        ? total.toInt()
        : (int.tryParse(total?.toString() ?? '') ?? 0);

    final seen = <String>{};
    final tracks = <Track>[];
    for (final item in rawList) {
      if (item is Map) {
        try {
          final track = Track.fromPrivateJson(item);
          track.platformId = 'deezer';
          if (track.id != null && seen.add(track.id!)) {
            tracks.add(track);
          }
        } catch (e, st) {
          Logger.root.warning(
            'Failed to parse Deezer history track: $e',
            e,
            st,
          );
        }
      }
    }

    final nextStart = start + rawList.length;
    final hasMore = totalCount > 0
        ? (nextStart < totalCount)
        : (rawList.length >= limit);

    return HistoryTrackPage(
      tracks: tracks,
      nextCursor: hasMore ? nextStart.toString() : null,
    );
  }

  Future<bool> checkShowFavorite(Show s) async {
    Map data = await callGwApi(
      'deezer.pageShow',
      params: {'show_id': s.id, 'user_id': userId},
    );
    final favorited = data['results']['FAVORITE_STATUS'];
    return favorited;
  }

  //Get favorite albums
  Future<List<Album>> getAlbums() async {
    Map data = await callGwApi(
      'deezer.pageProfile',
      params: {'nb': 50, 'tab': 'albums', 'user_id': userId},
    );
    List albumList = data['results']['TAB']['albums']['data'];
    List<Album> albums = albumList
        .map<Album>((json) => Album.fromPrivateJson(json, library: true))
        .toList();
    return albums;
  }

  //Remove album from library
  Future removeAlbum(String id) async {
    await callGwApi('album.deleteFavorite', params: {'ALB_ID': id});
  }

  //Remove track from favorites
  Future removeFavorite(String id) async {
    await callGwApi('favorite_song.remove', params: {'SNG_ID': id});
  }

  //Get favorite artists
  Future<List<Artist>> getArtists() async {
    Map data = await callGwApi(
      'deezer.pageProfile',
      params: {'nb': 40, 'tab': 'artists', 'user_id': userId},
    );
    return data['results']['TAB']['artists']['data']
        .map<Artist>((json) => Artist.fromPrivateJson(json, library: true))
        .toList();
  }

  //Get lyrics by track id
  Future<Lyrics> lyrics(String trackId) async {
    // First try to get lyrics from pipe API
    Lyrics lyricsFromPipeApi = await lyricsFull(trackId);

    if (lyricsFromPipeApi.errorMessage == null &&
        lyricsFromPipeApi.isLoaded()) {
      return lyricsFromPipeApi;
    }

    // Fallback to get lyrics from legacy GW api
    Lyrics lyricsFromLegacy = await lyricsLegacy(trackId);

    if (lyricsFromLegacy.errorMessage == null && lyricsFromLegacy.isLoaded()) {
      return lyricsFromLegacy;
    }

    // No lyrics found, prefer to use pipe api error message
    return lyricsFromPipeApi;
  }

  //Get lyrics by track id from legacy GW api
  Future<dynamic> lyricsLegacy(String trackId) async {
    Map data = await callGwApi('song.getLyrics', params: {'sng_id': trackId});
    if (data['error'] != null && data['error'].length > 0) {
      return Lyrics.error(data['error']['DATA_ERROR']);
    }
    return LyricsClassic.fromPrivateJson(data['results']);
  }

  //Get lyrics by track id from pipe API
  Future<dynamic> lyricsFull(String trackId) async {
    // Create lyrics request body with GraphQL query
    String queryStringGraphQL = '''
      query SynchronizedTrackLyrics(\$trackId: String!) {
        track(trackId: \$trackId) {
          id
          isExplicit
          lyrics {
            id
            copyright
            text
            writers
            synchronizedLines {
              lrcTimestamp
              line
              lineTranslated
              milliseconds
              duration
            }
            synchronizedWordByWordLines {
              start
              end
              words {
                start
                end
                word
              }
            }
          }
        }
      }''';

    /* Alternative query using fragments, used by Deezer web app
    String queryStringGraphQL = '''
      query SynchronizedTrackLyrics(\$trackId: String!) {
        track(trackId: \$trackId) {
          ...SynchronizedTrackLyrics
        }
      }
      fragment SynchronizedTrackLyrics on Track {
        id
        isExplicit
        lyrics {
          ...Lyrics
        }
      }
      fragment Lyrics on Lyrics {
        id
        copyright
        text
        writers
        synchronizedLines {
          ...LyricsSynchronizedLines
        }
      }
      fragment LyricsSynchronizedLines on LyricsSynchronizedLine {
        lrcTimestamp
        line
        milliseconds
        duration
      }
      ''';
    */

    Map<String, dynamic> requestParams = {
      'operationName': 'SynchronizedTrackLyrics',
      'variables': {'trackId': trackId},
      'query': queryStringGraphQL,
    };
    Map data = await callPipeApi(params: requestParams);
    Logger.root.info('Deezer Pipe API response for lyrics ($trackId): $data');
    if (data['errors'] != null && data['errors'].length > 0) {
      Logger.root.warning('Deezer Pipe API returned errors: ${data['errors']}');
      return Lyrics.error(data['errors']['message']);
    }
    return LyricsFull.fromPrivateJson(data['data']);
  }

  Future<SmartTrackList> smartTrackList(String id) async {
    Map data = await callGwApi(
      'deezer.pageSmartTracklist',
      params: {'smarttracklist_id': id},
    );
    return SmartTrackList.fromPrivateJson(
      data['results']['DATA'],
      songsJson: data['results']['SONGS'],
    );
  }

  Future<List<Track>> flow({String? type}) async {
    Map data = await callGwApi(
      'radio.getUserRadio',
      params: {'user_id': userId, 'config_id': type},
    );
    return data['results']['data']
        .map<Track>((json) => Track.fromPrivateJson(json))
        .toList();
  }

  /// Resolve the playable stream URL of a live radio station.
  /// Returns the highest bitrate URL found, preferring mp3 then aac.
  Future<String?> getLivestreamUrl(String id) async {
    final data = await callGwApi(
      'livestream.getData',
      params: {
        'livestream_id': id,
        'supported_codecs': ['mp3', 'aac'],
      },
    );
    final urls = data['results']?['LIVESTREAM_URLS']?['data'];
    if (urls is! Map) return null;
    String? best;
    var bestRank = -1;
    for (final entry in urls.entries) {
      final bitrate = int.tryParse(entry.key.toString()) ?? 0;
      final codecs = entry.value;
      if (codecs is! Map) continue;
      for (final codec in codecs.entries) {
        final rank = bitrate + (codec.key == 'mp3' ? 1000 : 0);
        if (rank > bestRank && codec.value != null) {
          bestRank = rank;
          best = codec.value.toString();
        }
      }
    }
    return best;
  }

  /// Song currently on air for a fingerprinted radio, or null when unknown
  /// (e.g. between songs, ads or presenters).
  Future<Track?> getLivestreamNowPlaying(String id) async {
    final data = await callGwApi(
      'livestream.getMedia',
      params: {'LIVESTREAM_ID': int.tryParse(id) ?? id},
    );
    final results = data['results'];
    if (results is! Map || results['SNG_ID'] == null) return null;
    try {
      return await track(results['SNG_ID'].toString());
    } catch (_) {
      return Track.fromPrivateJson(results);
    }
  }

  /// Streams the currently playing track for a live radio station.
  Stream<Track?> getLivestreamNowPlayingStream(String id) async* {
    yield await getLivestreamNowPlaying(id);
    while (true) {
      WebSocket? ws;
      try {
        final userData = await callGwApi('deezer.getUserData');
        final userToken = userData['results']?['USER_TOKEN']?.toString();
        if (userToken == null || userToken.isEmpty) {
          throw StateError('Deezer did not return a live radio user token');
        }

        // Reconnect when Deezer closes or drops its live metadata socket.
        ws = await WebSocket.connect(
          'wss://live.deezer.com/ws/$userToken?version=10020261006120233',
        ).timeout(const Duration(seconds: 10));
        ws.add(jsonEncode(['sub', '-1_0_LIVESTREAM_$id']));

        await for (final event in ws) {
          if (event is! String) continue;
          try {
            final payload = jsonDecode(event);
            if (payload is! List ||
                payload.length <= 2 ||
                payload[0] != 'msg') {
              continue;
            }
            final data = payload[2];
            if (data is! Map || data['APP'] != 'LIVESTREAM') continue;
            final value = data['VALUE'];
            final media = value is Map ? value['MEDIA'] : null;
            if (media is! Map) {
              yield null;
              continue;
            }

            final trackId = media['ID']?.toString();
            if (trackId == null || trackId.isEmpty) {
              yield null;
              continue;
            }
            try {
              yield await track(trackId);
            } catch (_) {
              yield Track(
                id: trackId,
                title: media['TITLE']?.toString() ?? '',
                artists: [
                  Artist(name: media['CREATOR_NAME']?.toString() ?? ''),
                ],
                album: Album(
                  art: ImageDetails(imageHash: media['PICTURE']?.toString()),
                  id: '',
                  title: '',
                ),
                duration: Duration.zero,
                platformId: 'deezer',
              );
            }
          } catch (error) {
            Logger.root.fine('Ignoring malformed Deezer radio update: $error');
          }
        }
      } catch (error, stack) {
        Logger.root.warning(
          'Deezer radio metadata connection failed: $error',
          error,
          stack,
        );
      } finally {
        try {
          await ws?.close();
        } catch (_) {}
      }

      // Refresh the station metadata after reconnecting, then keep listening.
      await Future<void>.delayed(const Duration(seconds: 5));
      try {
        yield await getLivestreamNowPlaying(id);
      } catch (error) {
        Logger.root.fine('Could not refresh Deezer radio metadata: $error');
      }
    }
  }

  //Get homepage/music library from deezer
  Future<HomePage> homePage() async {
    // CHECK FOR FREE USERS
    // Call API to get user data
    Map usrdata = await callGwApi('deezer.getUserData', params: {});
    // Extract OFFER_NAME from user data
    int offerId = usrdata['results'] != null
        ? usrdata['results']['OFFER_ID']
        : null;
    String offerName = usrdata['results'] != null
        ? usrdata['results']['OFFER_NAME']
        : null;

    if (offerId == 0 &&
        usrdata['results']['USER']['SETTING']['global']['recommendation_country'] !=
            'FM') {
      settings.noPremium = true;
      settings.tier = offerName;
      settings.save();
      logOut();
      updateTheme();
    }

    List grid = [
      'album',
      'artist',
      'channel',
      'flow',
      'playlist',
      'radio',
      'show',
      'smarttracklist',
      'track',
      'user',
      'livestream',
    ];

    Map data = await callGwApi(
      'page.get',
      gatewayInput: jsonEncode({
        'PAGE': 'home',
        'VERSION': '2.5',
        'SUPPORT': {
          'filterable-grid': ['flow'],
          'grid': grid,
          'horizontal-grid': grid,
          'horizontal-list': ['track', 'song'],
          'item-highlight': ['radio'],
          'large-card': ['album', 'playlist', 'show', 'video-link'],
          'ads': [],
        },
        'LANG': _deezerLanguage,
        'OPTIONS': [],
      }),
    );
    final page = HomePage.fromPrivateJson(data['results']);
    for (final section in page.sections.where(
      (section) => section.title?.toLowerCase().contains('genre') == true,
    )) {
      final itemSummary = section.items
          .whereType<HomePageItem>()
          .map((item) {
            final value = item.value;
            final title = switch (value) {
              DeezerChannel channel => channel.title,
              SmartTrackList list => list.title,
              Playlist playlist => playlist.title,
              Album album => album.title,
              _ => value.runtimeType.toString(),
            };
            return '${item.type}/${item.platformType}:$title';
          })
          .join(' | ');
      Logger.root.info(
        'Deezer homepage genre section: layout=${section.layout}, items=$itemSummary',
      );
    }
    try {
      final pinned = await getPinnedItems();
      page.sections.insert(
        0,
        HomePageSection(
          title: 'Quick access',
          layout: HomePageSectionLayout.QUICK_ACCESS,
          items: pinned,
        ),
      );
    } catch (e, st) {
      Logger.root.warning(
        'Failed to fetch pinned items for homepage: $e',
        e,
        st,
      );
      page.sections.insert(
        0,
        HomePageSection(
          title: 'Quick access',
          layout: HomePageSectionLayout.QUICK_ACCESS,
          items: [],
        ),
      );
    }
    return page;
  }

  //Log song listen to deezer
  Future logListen(
    String trackId,
    QueueSource? queue, {
    ListenLogDetails? details,
  }) async {
    final String? queuesrc = queue?.source;
    String? queueid = queue?.id;
    if (queueid != null && queueid.contains(':')) {
      queueid = queueid.split(':').sublist(1).join(':');
    }
    final isEpisode =
        queuesrc?.startsWith('show_page') == true ||
        details?.nextTrackType == 'episode';

    final isLive = trackId.startsWith('radio:');
    final actualTrackId = isLive ? trackId.replaceFirst('radio:', '') : trackId;

    final mediaType = isLive ? 'live' : (isEpisode ? 'episode' : 'song');

    final format = isLive
        ? 'EXTERNAL'
        : (details?.format ??
              (settings.wifiQuality == AudioQuality.FLAC
                  ? 'FLAC'
                  : settings.wifiQuality == AudioQuality.MP3_320
                  ? 'MP3_320'
                  : 'MP3_128'));

    final listenSeconds =
        details?.listenDuration?.inSeconds ?? details?.position?.inSeconds ?? 0;

    final startTimestamp =
        details?.timestamp ??
        DateTime.now().subtract(Duration(seconds: listenSeconds));
    final eventTimestamp = details?.listenTimestamp ?? DateTime.now();

    Map<String, dynamic> ctxt;
    if (isLive) {
      ctxt = {
        't': 'dynamic_page_livestream',
        'id': actualTrackId,
        'c': actualTrackId,
      };
    } else {
      ctxt = {'t': queuesrc ?? 'dynamic_page_album', 'id': queueid ?? ''};
    }

    final params = <String, dynamic>{
      'timestamp': startTimestamp.millisecondsSinceEpoch ~/ 1000,
      'ts_listen': eventTimestamp.millisecondsSinceEpoch ~/ 1000,
      'type': details?.isPartial == true ? 0 : 1,
      'lt': listenSeconds,
      'stat': {
        'seek': details?.seekCount ?? 0,
        'pause': details?.pauseCount ?? 0,
        'sync': 0,
      },
      'ctxt': ctxt,
      'media': {'id': actualTrackId, 'type': mediaType, 'format': format},
      'payload': <String, dynamic>{},
      'dev': {'v': '10020261004155858', 't': 0},
      'ls': <dynamic>[],
      'is_shuffle': details?.isShuffle ?? false,
      if (details?.streamId case final streamId? when streamId.isNotEmpty)
        'stream_id': streamId,
    };

    final nextId = details?.nextTrackId;
    final body = <String, dynamic>{
      'params': params,
      if (nextId != null && nextId.isNotEmpty)
        'next_media': {
          'media': {'id': nextId, 'type': details?.nextTrackType ?? 'song'},
        },
    };

    Logger.root.info('Deezer logListen body: $body');

    try {
      final response = await callGwApi('log.listen', params: body);
      Logger.root.info('Deezer logListen response: $response');
    } catch (e, st) {
      Logger.root.severe('Deezer logListen failed: $e', e, st);
    }

    if (isEpisode) {
      final totalSec = details?.trackDuration?.inSeconds.toDouble() ?? 0.0;
      final posSec = details?.position?.inSeconds ?? listenSeconds;
      final isHeard =
          details?.isPartial == false ||
          (totalSec > 0 && posSec >= (totalSec * 0.95));
      unawaited(
        setEpisodeBookmark(
          trackId,
          isHeard ? 0 : posSec,
          totalSec,
          isHeard: isHeard,
        ),
      );
    }
  }

  Future<HomePage> getChannel(
    String target, {
    bool useGet = false,
    bool useWebHeaders = false,
  }) async {
    final isExplore = target.contains('channels/explore');
    final isRadios =
        target.replaceFirst(RegExp(r'^/'), '') == 'channels/radios';
    if (isExplore || isRadios) {
      Logger.root.info(
        'Deezer ${isRadios ? 'radios' : 'explore'} page.get request '
        'transport=${useGet ? 'GET' : 'POST'}, '
        'webHeaders=$useWebHeaders',
      );
    }
    const exploreItems = [
      'album',
      'artist',
      'artistLineUp',
      'channel',
      'flow',
      'livestream',
      'playlist',
      'radio',
      'show',
      'smarttracklist',
      'track',
      'user',
      'video-link',
      'external-link',
    ];
    Map data = await callGwApi(
      'page.get',
      useGet: useGet,
      useWebHeaders: useWebHeaders,
      gatewayInput: jsonEncode({
        'PAGE': target,
        'VERSION': '2.5',
        'SUPPORT': {
          'event-card': ['live-event'],
          'grid-preview-one': exploreItems,
          'grid-preview-two': exploreItems,
          'grid': exploreItems,
          'horizontal-grid': exploreItems,
          'horizontal-list': ['track', 'song'],
          'large-card': [
            'album',
            'external-link',
            'playlist',
            'show',
            'smarttracklist',
            'video-link',
          ],
          'list': ['episode'],
          'message': ['call_onboarding'],
          'mini-banner': ['external-link'],
          'slideshow': [
            'album',
            'artist',
            'channel',
            'external-link',
            'flow',
            'livestream',
            'playlist',
            'show',
            'smarttracklist',
            'user',
            'video-link',
          ],
          'small-horizontal-grid': ['flow'],
          'long-card-horizontal-grid': exploreItems,
          'filterable-grid': ['flow'],
        },
        'LANG': _deezerLanguage,
        'OPTIONS': ['deeplink_newsandentertainment', 'deeplink_subscribeoffer'],
      }),
    );
    final results = data['results'];
    if (isExplore || isRadios) {
      final rawSections = results is Map && results['sections'] is List
          ? results['sections'] as List
          : const [];
      final summary = rawSections
          .map((dynamic section) {
            if (section is! Map) return section.runtimeType.toString();
            final items = section['items'] is List
                ? section['items'] as List
                : const [];
            final itemSummary = items
                .take(8)
                .map((dynamic item) {
                  if (item is! Map) return item.runtimeType.toString();
                  return '${item['type']}:${item['title']} -> ${item['target']}';
                })
                .join(' | ');
            return '${section['title'] ?? '(untitled)'} '
                '[${section['layout']}; ${items.length} items]: $itemSummary';
          })
          .join('\n');
      Logger.root.info(
        'Deezer ${isRadios ? 'radios' : 'explore'} raw sections:\n$summary',
      );
    }

    final page = HomePage.fromPrivateJson(results);
    if (isExplore || isRadios) {
      final summary = page.sections
          .map((section) {
            final items = section.items
                .whereType<HomePageItem>()
                .map((item) {
                  final value = item.value;
                  final title = value is DeezerChannel
                      ? value.title
                      : value is Playlist
                      ? value.title
                      : value is LiveRadio
                      ? value.title
                      : value.toString();
                  return '${item.type}/${item.platformType}:$title';
                })
                .join(' | ');
            return '${section.title ?? '(untitled)'} '
                '[${section.layout}; ${section.items.length} items]: $items';
          })
          .join('\n');
      Logger.root.info(
        'Deezer ${isRadios ? 'radios' : 'explore'} parsed sections:\n$summary',
      );
    }
    return page;
  }

  //Add playlist to library
  Future addPlaylist(String id) async {
    await callGwApi(
      'playlist.addFavorite',
      params: {'parent_playlist_id': int.parse(id)},
    );
  }

  //Remove playlist from library
  Future removePlaylist(String id) async {
    await callGwApi(
      'playlist.deleteFavorite',
      params: {'playlist_id': int.parse(id)},
    );
  }

  //Delete playlist
  Future deletePlaylist(String id) async {
    await callGwApi('playlist.delete', params: {'playlist_id': id});
  }

  //Create playlist
  //Status 1 - private, 2 - collaborative
  Future<String> createPlaylist(
    String title, {
    String description = '',
    int status = 1,
    List<String> trackIds = const [],
  }) async {
    Map data = await callGwApi(
      'playlist.create',
      params: {
        'title': title,
        'description': description,
        'songs': trackIds
            .map<List>((id) => [int.parse(id), trackIds.indexOf(id)])
            .toList(),
        'status': status,
      },
    );
    //Return playlistId
    return data['results'].toString();
  }

  //Get part of discography
  Future<List<Album>> discographyPage(
    String artistId, {
    int start = 0,
    int nb = 50,
  }) async {
    Map data = await callGwApi(
      'album.getDiscography',
      params: {
        'art_id': int.parse(artistId),
        'discography_mode': 'all',
        'nb': nb,
        'start': start,
        'nb_songs': 30,
      },
    );

    return data['results']['data']
        .map<Album>((a) => Album.fromPrivateJson(a))
        .toList();
  }

  Future<List> searchSuggestions(String query) async {
    Map data = await callGwApi(
      'search_getSuggestedQueries',
      params: {'QUERY': query},
    );
    return data['results']['SUGGESTION'].map((s) => s['QUERY']).toList();
  }

  //Get smart radio for artist id
  Future<List<Track>> smartRadio(String artistId) async {
    Map data = await callGwApi(
      'smart.getSmartRadio',
      params: {'art_id': int.parse(artistId)},
    );
    return data['results']['data']
        .map<Track>((t) => Track.fromPrivateJson(t))
        .toList();
  }

  //Update playlist metadata, status = see createPlaylist
  Future updatePlaylist(
    String id,
    String title,
    String description, {
    int status = 1,
  }) async {
    await callGwApi(
      'playlist.update',
      params: {
        'description': description,
        'title': title,
        'playlist_id': int.parse(id),
        'status': status,
        'songs': [],
      },
    );
  }

  //Get shuffled library
  Future<List<Track>> libraryShuffle({int start = 0}) async {
    Map data = await callGwApi(
      'tracklist.getShuffledCollection',
      params: {'nb': 50, 'start': start},
    );
    return data['results']['data']
        .map<Track>((t) => Track.fromPrivateJson(t))
        .toList();
  }

  //Get similar tracks for track with id [trackId]
  Future<List<Track>> playMix(String trackId) async {
    Map data = await callGwApi(
      'song.getSearchTrackMix',
      params: {'sng_id': trackId, 'start_with_input_track': 'true'},
    );
    return data['results']['data']
        .map<Track>((t) => Track.fromPrivateJson(t))
        .toList();
  }

  Map<String, ({int offset, bool isHeard})> _cachedEpisodeBookmarks = {};
  DateTime? _bookmarksLastFetched;

  Future<Map<String, ({int offset, bool isHeard})>> getEpisodeBookmarks({
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh &&
        _bookmarksLastFetched != null &&
        DateTime.now().difference(_bookmarksLastFetched!) <
            const Duration(minutes: 5)) {
      return _cachedEpisodeBookmarks;
    }
    try {
      final res = await callGwApi(
        'deezer.userMenu',
        params: {'checksum': true, 'checksums': false},
      );
      final list = res['results']?['EPISODE_BOOKMARKS']?['data'] as List? ?? [];
      final map = <String, ({int offset, bool isHeard})>{};
      for (final item in list) {
        if (item is! Map) continue;
        final epId = item['EPISODE_ID']?.toString();
        if (epId == null || epId.isEmpty) continue;
        final offset = int.tryParse(item['OFFSET']?.toString() ?? '0') ?? 0;
        final isHeardVal = item['IS_HEARD'] ?? item['ISHEARD'];
        final isHeard =
            isHeardVal == '1' || isHeardVal == 1 || isHeardVal == true;
        map[epId] = (offset: offset, isHeard: isHeard);
      }
      _cachedEpisodeBookmarks = map;
      _bookmarksLastFetched = DateTime.now();
      return map;
    } catch (e, st) {
      Logger.root.warning(
        'Failed to fetch Deezer episode bookmarks: $e',
        e,
        st,
      );
      return _cachedEpisodeBookmarks;
    }
  }

  void _applyBookmark(
    ShowEpisode ep,
    Map<String, ({int offset, bool isHeard})> bookmarks,
  ) {
    if (ep.id == null) return;
    final bm = bookmarks[ep.id];
    if (bm != null) {
      ep.bookmarkSeconds = bm.offset;
      ep.isHeard = bm.isHeard;
      final durSec = ep.duration?.inSeconds ?? 0;
      if (!bm.isHeard && durSec > 0 && bm.offset > 0) {
        ep.progressPercentage = (bm.offset / durSec).clamp(0.0, 1.0);
      } else if (bm.isHeard) {
        ep.progressPercentage = 1.0;
      }
    }
  }

  Future<List<ShowEpisode>> allShowEpisodes(String showId) async {
    final episodes = <ShowEpisode>[];
    final seen = <String?>{};
    var offset = 0;
    while (true) {
      final page = await showEpisodesPage(showId, start: offset);
      offset += page.episodes.length;
      final unique = page.episodes.where((e) => seen.add(e.id)).toList();
      episodes.addAll(unique);
      if (!page.hasMore || unique.isEmpty) return episodes;
    }
  }

  Future<PaginatedShowEpisodeList> showEpisodesPage(
    String showId, {
    int start = 0,
    int limit = 50,
  }) async {
    final pageSize = limit.clamp(1, 50);
    Map data = await callGwApi(
      'deezer.pageShow',
      params: {
        'country': _deezerCountry,
        'lang': _deezerLanguage,
        'nb': pageSize,
        'show_id': showId,
        'start': start,
        'user_id': int.parse(
          PlatformManager.instance.active.currentUserId ?? '',
        ),
      },
    );
    final rows = data['results']['EPISODES']['data'] as List? ?? [];
    final bookmarks = await getEpisodeBookmarks();
    final episodes = rows.take(pageSize).map<ShowEpisode>((e) {
      final ep = ShowEpisode.fromPrivateJson(e);
      _applyBookmark(ep, bookmarks);
      return ep;
    }).toList();

    return PaginatedShowEpisodeList(
      episodes: episodes,
      hasMore: rows.length >= pageSize,
    );
  }

  Future<bool> setEpisodeBookmark(
    String episodeId,
    int offset,
    double duration, {
    bool isHeard = false,
  }) async {
    try {
      final res = await callGwApi(
        'episode.bookmarkSet',
        params: {
          'EPISODE_ID': episodeId,
          'OFFSET': offset,
          'DURATION': duration,
          'ISHEARD': isHeard ? 1 : 0,
        },
      );
      _cachedEpisodeBookmarks[episodeId] = (offset: offset, isHeard: isHeard);
      return res['results'] == true;
    } catch (e, st) {
      Logger.root.warning(
        'Failed to set Deezer episode bookmark for $episodeId: $e',
        e,
        st,
      );
      return false;
    }
  }

  Future<bool> markEpisodePlayed(String episodeId, bool isPlayed) async {
    try {
      final res = await callGwApi(
        isPlayed ? 'episode.markAsPlayed' : 'episode.markAsNotPlayed',
        params: {'EPISODE_ID': episodeId},
      );
      _cachedEpisodeBookmarks[episodeId] = (
        offset: isPlayed
            ? 0
            : (_cachedEpisodeBookmarks[episodeId]?.offset ?? 0),
        isHeard: isPlayed,
      );
      return res['results'] == true;
    } catch (e, st) {
      Logger.root.warning(
        'Failed to mark Deezer episode $episodeId as played=$isPlayed: $e',
        e,
        st,
      );
      return false;
    }
  }

  final Set<String> _pinnedItemIds = {};
  bool isItemPinned(String id) => _pinnedItemIds.contains(id);
  int get pinnedItemCount => _pinnedItemIds.length;

  HomePageItem? parseQuickAccessNode(Map node) {
    final typename = node['__typename']?.toString();
    final id = node['id']?.toString() ?? '';
    switch (typename) {
      case 'Album':
        final title =
            node['displayTitle']?.toString() ?? node['title']?.toString() ?? '';
        final coverUrl =
            (node['cover']?['large'] as List?)?.firstOrNull?.toString() ??
            (node['cover']?['medium'] as List?)?.firstOrNull?.toString() ??
            (node['cover']?['small'] as List?)?.firstOrNull?.toString();
        final artistName = (node['contributors']?['edges'] as List?)
            ?.firstOrNull?['node']?['name']
            ?.toString();
        final album = Album(
          id: id,
          title: title,
          art: coverUrl != null
              ? ImageDetails(fullUrl: coverUrl, thumbUrl: coverUrl)
              : null,
          artists: artistName != null
              ? [Artist(name: artistName, platformId: 'deezer')]
              : null,
          platformId: 'deezer',
        );
        return HomePageItem(type: HomePageItemType.ALBUM, value: album);
      case 'Artist':
        final name = node['name']?.toString() ?? '';
        final picUrl =
            (node['picture']?['large'] as List?)?.firstOrNull?.toString() ??
            (node['picture']?['medium'] as List?)?.firstOrNull?.toString() ??
            (node['picture']?['small'] as List?)?.firstOrNull?.toString();
        final artist = Artist(
          id: id,
          name: name,
          picture: picUrl != null
              ? ImageDetails(fullUrl: picUrl, thumbUrl: picUrl)
              : null,
          platformId: 'deezer',
        );
        return HomePageItem(type: HomePageItemType.ARTIST, value: artist);
      case 'Playlist':
        final title = node['title']?.toString() ?? '';
        final picUrl =
            (node['picture']?['large'] as List?)?.firstOrNull?.toString() ??
            (node['picture']?['medium'] as List?)?.firstOrNull?.toString() ??
            (node['picture']?['small'] as List?)?.firstOrNull?.toString();
        final ownerName = node['owner']?['name']?.toString();
        final playlist = Playlist(
          id: id,
          title: title,
          image: picUrl != null
              ? ImageDetails(fullUrl: picUrl, thumbUrl: picUrl)
              : null,
          user: ownerName != null
              ? User(name: ownerName, id: node['owner']?['id']?.toString())
              : null,
          platformId: 'deezer',
        );
        return HomePageItem(type: HomePageItemType.PLAYLIST, value: playlist);
      case 'Podcast':
        final title =
            node['displayTitle']?.toString() ?? node['title']?.toString() ?? '';
        final coverUrl =
            (node['cover']?['large'] as List?)?.firstOrNull?.toString() ??
            (node['cover']?['medium'] as List?)?.firstOrNull?.toString() ??
            (node['cover']?['small'] as List?)?.firstOrNull?.toString();
        final show = Show(
          id: id,
          name: title,
          art: coverUrl != null
              ? ImageDetails(fullUrl: coverUrl, thumbUrl: coverUrl)
              : null,
          platformId: 'deezer',
        );
        return HomePageItem(type: HomePageItemType.SHOW, value: show);
      case 'Track':
        final title = node['title']?.toString() ?? '';
        final coverUrl =
            (node['album']?['cover']?['large'] as List?)?.firstOrNull
                ?.toString() ??
            (node['album']?['cover']?['medium'] as List?)?.firstOrNull
                ?.toString() ??
            (node['album']?['cover']?['small'] as List?)?.firstOrNull
                ?.toString();
        final artistName =
            (node['contributors']?['edges'] as List?)
                ?.firstOrNull?['node']?['name']
                ?.toString() ??
            (node['album']?['contributors']?['edges'] as List?)
                ?.firstOrNull?['node']?['name']
                ?.toString();
        final albumId = node['album']?['id']?.toString();
        final track = Track(
          id: id,
          title: title,
          album: albumId != null
              ? Album(id: albumId, platformId: 'deezer')
              : null,
          albumArt: coverUrl != null
              ? ImageDetails(fullUrl: coverUrl, thumbUrl: coverUrl)
              : null,
          artists: artistName != null
              ? [Artist(name: artistName, platformId: 'deezer')]
              : null,
          platformId: 'deezer',
        );
        return HomePageItem(
          type: HomePageItemType.TRACK,
          platformId: 'deezer',
          value: track,
          playMix: true,
        );
      case 'SmartTracklist':
        final title = node['title']?.toString() ?? '';
        final coverUrl = (node['mosaicCover']?['xxx_small'] as List?)
            ?.firstOrNull
            ?.toString();
        final stl = SmartTrackList(
          id: id,
          title: title,
          cover: coverUrl != null
              ? ImageDetails(fullUrl: coverUrl, thumbUrl: coverUrl)
              : null,
        );
        return HomePageItem(
          type: HomePageItemType.PLATFORM,
          platformId: 'deezer',
          platformType: 'smarttracklist',
          value: stl,
        );
      case 'FlowConfig':
        final title = node['title']?.toString() ?? 'Flow';
        final coverUrl =
            (node['visuals']?['dynamicPageIcon']?['small'] as List?)
                ?.firstOrNull
                ?.toString();
        final flow = DeezerFlow(
          id: id,
          title: title,
          cover: coverUrl != null
              ? FlowImage(fullUrl: coverUrl, thumbUrl: coverUrl)
              : null,
        );
        return HomePageItem(
          type: HomePageItemType.PLATFORM,
          platformId: 'deezer',
          platformType: 'flow',
          value: flow,
        );
      case 'Livestream':
        final title =
            node['name']?.toString() ?? node['title']?.toString() ?? 'Radio';
        final coverUrl =
            (node['cover']?['large'] as List?)?.firstOrNull?.toString() ??
            (node['cover']?['small'] as List?)?.firstOrNull?.toString();
        final radio = LiveRadio(id: id, title: title, customImageUrl: coverUrl);
        return HomePageItem(type: HomePageItemType.RADIO, value: radio);
      default:
        return null;
    }
  }

  static const String _fragPictureSmall = '''
fragment PictureSmall on Picture {
  id
  small: urls(pictureRequest: {height: 100, width: 100})
  explicitStatus
  __typename
}
''';

  static const String _fragPictureMedium = '''
fragment PictureMedium on Picture {
  id
  medium: urls(pictureRequest: {width: 264, height: 264})
  explicitStatus
  __typename
}
''';

  static const String _fragPictureLarge = '''
fragment PictureLarge on Picture {
  id
  large: urls(pictureRequest: {width: 500, height: 500})
  explicitStatus
  __typename
}
''';

  static const String _fragPictureXSmall = '''
fragment PictureXSmall on Picture {
  id
  xxx_small: urls(pictureRequest: {width: 40, height: 40})
  explicitStatus
  __typename
}
''';

  static const String _fragPictures =
      _fragPictureSmall + _fragPictureMedium + _fragPictureLarge;

  static const String _fragAlbumBase = '''
fragment AlbumBase on Album {
  id
  displayTitle
  cover {
    ...PictureSmall
    ...PictureMedium
    ...PictureLarge
    __typename
  }
  releaseDate
  isFavorite
  isExplicit
  __typename
}
''';

  static const String _fragArtistBase = '''
fragment ArtistBase on Artist {
  id
  name
  fansCount
  hasSmartRadio
  isFavorite
  picture {
    ...PictureSmall
    ...PictureMedium
    ...PictureLarge
    __typename
  }
  __typename
}
''';

  static const String _fragPlaylistBase = '''
fragment PlaylistBase on Playlist {
  id
  picture {
    ...PictureSmall
    ...PictureMedium
    ...PictureLarge
    __typename
  }
  title
  __typename
}
''';

  static const String _fragPinDrawerPlaylist = '''
fragment PinDrawerPlaylist on Playlist {
  id
  owner {
    id
    name
    __typename
  }
  ...PlaylistBase
  __typename
}
''';

  static const String _fragPinDrawerAlbum = '''
fragment PinDrawerAlbum on Album {
  id
  contributors {
    edges {
      node {
        ... on Artist {
          id
          name
          __typename
        }
        __typename
      }
      __typename
    }
    __typename
  }
  ...AlbumBase
  __typename
}
''';

  static const String _fragPinDrawerTrack = '''
fragment PinDrawerTrack on Track {
  id
  title
  album {
    id
    displayTitle
    contributors {
      edges {
        node {
          ... on Artist {
            id
            name
            __typename
          }
          __typename
        }
        __typename
      }
      __typename
    }
    cover {
      ...PictureSmall
      __typename
    }
    __typename
  }
  __typename
}
''';

  static const String _fragPinItemOnly = '''
fragment PinItem on QuickAccessItem {
  ... on Album {
    id
    ...AlbumBase
    contributors {
      edges {
        node {
          ... on Artist {
            id
            name
            __typename
          }
          __typename
        }
        __typename
      }
      __typename
    }
    __typename
  }
  ... on Artist {
    id
    ...ArtistBase
    __typename
  }
  ... on Playlist {
    id
    ...PlaylistBase
    owner {
      id
      name
      __typename
    }
    __typename
  }
  ... on Podcast {
    id
    displayTitle
    cover {
      ...PictureSmall
      __typename
    }
    __typename
  }
  ... on FlowConfig {
    id
    title
    visuals {
      dynamicPageIcon {
        id
        small: urls(uiAssetRequest: {height: 100, width: 100})
        __typename
      }
      __typename
    }
    __typename
  }
  ... on Livestream {
    id
    name
    cover {
      ...PictureSmall
      ...PictureLarge
      __typename
    }
    __typename
  }
  ... on Track {
    id
    title
    album {
      id
      cover {
        ...PictureSmall
        __typename
      }
      __typename
    }
    contributors {
      edges {
        node {
          ... on Artist {
            id
            name
            __typename
          }
          __typename
        }
        __typename
      }
      __typename
    }
    __typename
  }
  ... on SmartTracklist {
    id
    title
    mosaicCover {
      ...PictureXSmall
      __typename
    }
    __typename
  }
  __typename
}
''';

  // Exactly the fragments used by the PinItem query family in the web client.
  static const String _quickAccessFragments =
      _fragPinItemOnly +
      _fragAlbumBase +
      _fragPictures +
      _fragArtistBase +
      _fragPlaylistBase +
      _fragPictureXSmall;

  /// Quick access only returns a mosaic stub for smart tracklists; load the
  /// full info (cover, subtitle, ...) the same way the regular home page does.
  Future<List<HomePageItem>> _enrichSmartTrackLists(
    List<HomePageItem> items,
  ) async {
    await Future.wait(
      items.map((item) async {
        if (!item.isPlatformItem('smarttracklist')) return;
        final SmartTrackList stub = item.value;
        if (stub.id == null) return;
        try {
          final full = await smartTrackList(stub.id!);
          item.value = SmartTrackList(
            id: stub.id,
            title: (full.title?.isNotEmpty ?? false) ? full.title : stub.title,
            subtitle: full.subtitle,
            description: full.description,
            trackCount: full.trackCount,
            cover: full.cover ?? stub.cover,
          );
        } catch (e) {
          Logger.root.warning('Failed to load smart tracklist ${stub.id}: $e');
        }
      }),
    );
    return items;
  }

  QuickAccessPage _parseQuickAccessConnection(dynamic conn) {
    if (conn is! Map) return QuickAccessPage();
    final items = <HomePageItem>[];
    for (final edge in (conn['edges'] as List? ?? [])) {
      final node = edge is Map ? edge['node'] : null;
      if (node is Map) {
        final item = parseQuickAccessNode(node);
        if (item != null) items.add(item);
      }
    }
    final pageInfo = conn['pageInfo'];
    return QuickAccessPage(
      items: items,
      endCursor: pageInfo?['endCursor']?.toString(),
      hasNextPage: pageInfo?['hasNextPage'] == true,
    );
  }

  Future<List<HomePageItem>> getPinnedItems({
    String context = 'HOMEPAGE',
  }) async {
    const String query =
        '''
query PinnedItems(\$context: QuickAccessContextInput!, \$support: [QuickAccessTypeInput!] = [ALBUM, ARTIST, PLAYLIST, PODCAST, FLOW_CONFIG, TRACK, LIVESTREAM, SMART_TRACKLIST]) {
  me {
    id
    quickAccess(context: \$context) {
      pinnedItems(support: \$support) {
        item {
          ...PinItem
          __typename
        }
        __typename
      }
      __typename
    }
    __typename
  }
}
$_quickAccessFragments
''';

    try {
      final res = await callPipeApi(
        params: {
          'operationName': 'PinnedItems',
          'query': query,
          'variables': {
            'context': context,
            'support': [
              'ALBUM',
              'ARTIST',
              'PLAYLIST',
              'PODCAST',
              'FLOW_CONFIG',
              'TRACK',
              'LIVESTREAM',
              'SMART_TRACKLIST',
            ],
          },
        },
      );
      final rawList =
          res['data']?['me']?['quickAccess']?['pinnedItems'] as List? ?? [];
      final items = <HomePageItem>[];
      _pinnedItemIds.clear();
      for (final entry in rawList) {
        if (entry is! Map) continue;
        final node = entry['item'];
        if (node == null || node is! Map) continue;
        final item = parseQuickAccessNode(node);
        if (item != null) {
          items.add(item);
          if (item.value?.id != null) {
            _pinnedItemIds.add(item.value.id.toString());
          }
        }
      }
      Logger.root.info(
        'Fetched ${items.length} Deezer quickAccess pinned items',
      );
      return await _enrichSmartTrackLists(items);
    } catch (e, st) {
      Logger.root.warning(
        'Failed to fetch Deezer quickAccess pinned items: $e',
        e,
        st,
      );
      return [];
    }
  }

  Future<PinResult> pinQuickAccessItem(String id, String type) async {
    const mutation =
        '''
mutation PinItem(\$id: String!, \$type: QuickAccessTypeInput!, \$context: QuickAccessContextInput!, \$support: [QuickAccessTypeInput!] = [ALBUM, ARTIST, PLAYLIST, PODCAST, FLOW_CONFIG, TRACK, LIVESTREAM, SMART_TRACKLIST]) {
  quickAccessAppendItem(input: {id: \$id, type: \$type, context: \$context}) {
    ... on QuickAccessAppendItemMutationError {
      isLimitExceed
      isUnsupportedItemType
      __typename
    }
    ... on QuickAccessAppendItemMutationOutput {
      quickAccess {
        pinnedItems(support: \$support) {
          item {
            ...PinItem
            __typename
          }
          __typename
        }
        __typename
      }
      __typename
    }
    __typename
  }
}
$_quickAccessFragments
''';
    try {
      final res = await callPipeApi(
        params: {
          'operationName': 'PinItem',
          'query': mutation,
          'variables': {
            'id': id,
            'type': type,
            'context': 'HOMEPAGE',
            'support': [
              'ALBUM',
              'ARTIST',
              'PLAYLIST',
              'PODCAST',
              'FLOW_CONFIG',
              'TRACK',
              'LIVESTREAM',
              'SMART_TRACKLIST',
            ],
          },
        },
      );
      final output = res['data']?['quickAccessAppendItem'];
      if (output != null && output['quickAccess'] != null) {
        _pinnedItemIds.add(id);
        return PinResult.success;
      }
      if (output != null && output['isLimitExceed'] == true) {
        return PinResult.limitExceeded;
      }
      return PinResult.failed;
    } catch (e, st) {
      Logger.root.warning(
        'Failed to pin quick access item $id ($type): $e',
        e,
        st,
      );
      return PinResult.failed;
    }
  }

  Future<bool> unpinQuickAccessItem(String id, String type) async {
    const mutation =
        '''
mutation UnpinItem(\$id: String!, \$type: QuickAccessTypeInput!, \$context: QuickAccessContextInput!, \$support: [QuickAccessTypeInput!] = [ALBUM, ARTIST, PLAYLIST, PODCAST, FLOW_CONFIG, TRACK, LIVESTREAM, SMART_TRACKLIST]) {
  quickAccessUnpinItem(input: {id: \$id, type: \$type, context: \$context}) {
    ... on QuickAccessUnpinItemMutationError {
      isItemNotFound
      __typename
    }
    ... on QuickAccessUnpinItemMutationOutput {
      quickAccess {
        pinnedItems(support: \$support) {
          item {
            ...PinItem
            __typename
          }
          __typename
        }
        __typename
      }
      __typename
    }
    __typename
  }
}
$_quickAccessFragments
''';
    try {
      final res = await callPipeApi(
        params: {
          'operationName': 'UnpinItem',
          'query': mutation,
          'variables': {
            'id': id,
            'type': type,
            'context': 'HOMEPAGE',
            'support': [
              'ALBUM',
              'ARTIST',
              'PLAYLIST',
              'PODCAST',
              'FLOW_CONFIG',
              'TRACK',
              'LIVESTREAM',
              'SMART_TRACKLIST',
            ],
          },
        },
      );
      final output = res['data']?['quickAccessUnpinItem'];
      if (output != null && output['quickAccess'] != null) {
        _pinnedItemIds.remove(id);
        return true;
      }
      return false;
    } catch (e, st) {
      Logger.root.warning(
        'Failed to unpin quick access item $id ($type): $e',
        e,
        st,
      );
      return false;
    }
  }

  Future<List<HomePageItem>> getQuickAccessSuggestions() async {
    const query =
        '''
query PinnedDrawerSuggestedItems(\$context: QuickAccessContextInput!, \$support: [QuickAccessTypeInput!] = [ALBUM, ARTIST, PLAYLIST, PODCAST, FLOW_CONFIG, LIVESTREAM, TRACK, SMART_TRACKLIST]) {
  me {
    id
    quickAccess(context: \$context) {
      suggestedItems(support: \$support) {
        item {
          ...PinItem
          __typename
        }
        __typename
      }
      __typename
    }
    __typename
  }
}
$_quickAccessFragments
''';
    try {
      final res = await callPipeApi(
        params: {
          'operationName': 'PinnedDrawerSuggestedItems',
          'query': query,
          'variables': {
            'context': 'HOMEPAGE',
            'support': [
              'ALBUM',
              'ARTIST',
              'PLAYLIST',
              'PODCAST',
              'FLOW_CONFIG',
              'LIVESTREAM',
              'TRACK',
              'SMART_TRACKLIST',
            ],
          },
        },
      );
      final List<dynamic>? entries =
          res['data']?['me']?['quickAccess']?['suggestedItems'];
      if (entries == null) return [];
      List<HomePageItem> items = [];
      for (final entry in entries) {
        final node = entry['item'];
        if (node != null && node is Map) {
          final item = parseQuickAccessNode(node);
          if (item != null) items.add(item);
        }
      }
      return await _enrichSmartTrackLists(items);
    } catch (e, st) {
      Logger.root.warning('Failed to get QuickAccess suggestions: $e', e, st);
      return [];
    }
  }

  Future<QuickAccessPage> getQuickAccessByDeezer({
    int first = 50,
    String? cursor,
  }) async {
    const query =
        '''
query PinnedDrawerSmartTracklistItems(\$smartTracklistFirst: Int!, \$smartTracklistCursor: String, \$context: QuickAccessContextInput!) {
  me {
    id
    quickAccess(context: \$context) {
      suggestedSmartTracklists(
        first: \$smartTracklistFirst
        after: \$smartTracklistCursor
      ) {
        pageInfo {
          hasNextPage
          endCursor
          __typename
        }
        edges {
          node {
            id
            title
            mosaicCover {
              ...PictureXSmall
              __typename
            }
            __typename
          }
          __typename
        }
        __typename
      }
      __typename
    }
    __typename
  }
}
$_fragPictureXSmall
''';
    try {
      final res = await callPipeApi(
        params: {
          'operationName': 'PinnedDrawerSmartTracklistItems',
          'query': query,
          'variables': {
            'smartTracklistFirst': first,
            'smartTracklistCursor': cursor,
            'context': 'HOMEPAGE',
          },
        },
      );
      final page = _parseQuickAccessConnection(
        res['data']?['me']?['quickAccess']?['suggestedSmartTracklists'],
      );
      await _enrichSmartTrackLists(page.items);
      return page;
    } catch (e, st) {
      Logger.root.warning(
        'Failed to get QuickAccess By Deezer items: $e',
        e,
        st,
      );
      return QuickAccessPage();
    }
  }

  Future<QuickAccessPage> getQuickAccessPlaylists({
    int first = 50,
    String? cursor,
  }) async {
    const query =
        '''
query PinnedDrawerPlaylistItems(\$playlistFirst: Int, \$playlistCursor: String) {
  me {
    quickAccess(context: HOMEPAGE) {
      suggestedPlaylists(first: \$playlistFirst, after: \$playlistCursor) {
        pageInfo {
          hasNextPage
          endCursor
          __typename
        }
        edges {
          node {
            ...PinDrawerPlaylist
            __typename
          }
          __typename
        }
        __typename
      }
      __typename
    }
    __typename
  }
}
$_fragPinDrawerPlaylist$_fragPlaylistBase$_fragPictures
''';
    try {
      final res = await callPipeApi(
        params: {
          'operationName': 'PinnedDrawerPlaylistItems',
          'query': query,
          'variables': {'playlistFirst': first, 'playlistCursor': cursor},
        },
      );
      return _parseQuickAccessConnection(
        res['data']?['me']?['quickAccess']?['suggestedPlaylists'],
      );
    } catch (e, st) {
      Logger.root.warning('Failed to get QuickAccess playlists: $e', e, st);
      return QuickAccessPage();
    }
  }

  Future<QuickAccessPage> getQuickAccessFlows({
    int first = 50,
    String? cursor,
  }) async {
    const query = '''
query PinnedDrawerFlowConfigItems(\$flowConfigFirst: Int, \$flowConfigCursor: String) {
  me {
    quickAccess(context: HOMEPAGE) {
      suggestedFlowConfigs(first: \$flowConfigFirst, after: \$flowConfigCursor) {
        pageInfo {
          hasNextPage
          endCursor
          __typename
        }
        edges {
          node {
            ... on FlowConfig {
              id
              title
              visuals {
                dynamicPageIcon {
                  id
                  small: urls(uiAssetRequest: {height: 100, width: 100})
                  __typename
                }
                __typename
              }
              __typename
            }
            __typename
          }
          __typename
        }
        __typename
      }
      __typename
    }
    __typename
  }
}

''';
    try {
      final res = await callPipeApi(
        params: {
          'operationName': 'PinnedDrawerFlowConfigItems',
          'query': query,
          'variables': {'flowConfigFirst': first, 'flowConfigCursor': cursor},
        },
      );
      return _parseQuickAccessConnection(
        res['data']?['me']?['quickAccess']?['suggestedFlowConfigs'],
      );
    } catch (e, st) {
      Logger.root.warning('Failed to get QuickAccess Flow items: $e', e, st);
      return QuickAccessPage();
    }
  }

  Future<QuickAccessPage> getQuickAccessAlbums({
    int first = 50,
    String? cursor,
  }) async {
    const query =
        '''
query PinnedDrawerAlbumItems(\$albumFirst: Int, \$albumCursor: String) {
  me {
    quickAccess(context: HOMEPAGE) {
      suggestedAlbums(first: \$albumFirst, after: \$albumCursor) {
        pageInfo {
          hasNextPage
          endCursor
          __typename
        }
        edges {
          node {
            ...PinDrawerAlbum
            __typename
          }
          __typename
        }
        __typename
      }
      __typename
    }
    __typename
  }
}
$_fragPinDrawerAlbum$_fragAlbumBase$_fragPictures
''';
    try {
      final res = await callPipeApi(
        params: {
          'operationName': 'PinnedDrawerAlbumItems',
          'query': query,
          'variables': {'albumFirst': first, 'albumCursor': cursor},
        },
      );
      return _parseQuickAccessConnection(
        res['data']?['me']?['quickAccess']?['suggestedAlbums'],
      );
    } catch (e, st) {
      Logger.root.warning('Failed to get QuickAccess albums: $e', e, st);
      return QuickAccessPage();
    }
  }

  Future<QuickAccessPage> getQuickAccessArtists({
    int first = 50,
    String? cursor,
  }) async {
    const query =
        '''
query PinnedDrawerArtistItems(\$artistFirst: Int, \$artistCursor: String) {
  me {
    quickAccess(context: HOMEPAGE) {
      suggestedArtists(first: \$artistFirst, after: \$artistCursor) {
        pageInfo {
          hasNextPage
          endCursor
          __typename
        }
        edges {
          node {
            ... on Artist {
              id
              ...ArtistBase
              __typename
            }
            __typename
          }
          __typename
        }
        __typename
      }
      __typename
    }
    __typename
  }
}
$_fragArtistBase$_fragPictures
''';
    try {
      final res = await callPipeApi(
        params: {
          'operationName': 'PinnedDrawerArtistItems',
          'query': query,
          'variables': {'artistFirst': first, 'artistCursor': cursor},
        },
      );
      return _parseQuickAccessConnection(
        res['data']?['me']?['quickAccess']?['suggestedArtists'],
      );
    } catch (e, st) {
      Logger.root.warning('Failed to get QuickAccess artists: $e', e, st);
      return QuickAccessPage();
    }
  }

  Future<QuickAccessPage> getQuickAccessTracks({
    int first = 50,
    String? cursor,
  }) async {
    const query =
        '''
query PinnedDrawerTrackItems(\$trackFirst: Int, \$trackCursor: String) {
  me {
    quickAccess(context: HOMEPAGE) {
      suggestedTracks(first: \$trackFirst, after: \$trackCursor) {
        pageInfo {
          hasNextPage
          endCursor
          __typename
        }
        edges {
          node {
            ...PinDrawerTrack
            __typename
          }
          __typename
        }
        __typename
      }
      __typename
    }
    __typename
  }
}
$_fragPinDrawerTrack$_fragPictureSmall
''';
    try {
      final res = await callPipeApi(
        params: {
          'operationName': 'PinnedDrawerTrackItems',
          'query': query,
          'variables': {'trackFirst': first, 'trackCursor': cursor},
        },
      );
      return _parseQuickAccessConnection(
        res['data']?['me']?['quickAccess']?['suggestedTracks'],
      );
    } catch (e, st) {
      Logger.root.warning('Failed to get QuickAccess tracks: $e', e, st);
      return QuickAccessPage();
    }
  }

  Future<QuickAccessPage> getQuickAccessPodcasts({
    int first = 50,
    String? cursor,
  }) async {
    const query =
        '''
query PinnedDrawerPodcastItems(\$podcastFirst: Int, \$podcastCursor: String) {
  me {
    quickAccess(context: HOMEPAGE) {
      suggestedPodcasts(first: \$podcastFirst, after: \$podcastCursor) {
        pageInfo {
          hasNextPage
          endCursor
          __typename
        }
        edges {
          node {
            ... on Podcast {
              id
              displayTitle
              cover {
                ...PictureSmall
                __typename
              }
              __typename
            }
            __typename
          }
          __typename
        }
        __typename
      }
      __typename
    }
    __typename
  }
}
$_fragPictureSmall
''';
    try {
      final res = await callPipeApi(
        params: {
          'operationName': 'PinnedDrawerPodcastItems',
          'query': query,
          'variables': {'podcastFirst': first, 'podcastCursor': cursor},
        },
      );
      return _parseQuickAccessConnection(
        res['data']?['me']?['quickAccess']?['suggestedPodcasts'],
      );
    } catch (e, st) {
      Logger.root.warning('Failed to get QuickAccess podcasts: $e', e, st);
      return QuickAccessPage();
    }
  }
}

/// Result of attempting to pin an item to quick access.
enum PinResult { success, limitExceeded, failed }

/// One page of quick access drawer items.
class QuickAccessPage {
  final List<HomePageItem> items;
  final String? endCursor;
  final bool hasNextPage;
  QuickAccessPage({
    this.items = const [],
    this.endCursor,
    this.hasNextPage = false,
  });
}
