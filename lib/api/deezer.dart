import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:saturn/main.dart';
import '../api/definitions.dart';
import '../settings.dart';

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
  }) async {
    //Generate URL
    Uri uri = Uri.https('www.deezer.com', '/ajax/gw-light.php', {
      'api_version': '1.0',
      'api_token': token,
      'input': '3',
      'method': method,
      'cid': Random().nextInt(1000000000).toString(),
      //Used for homepage
      if (gatewayInput != null) 'gateway_input': gatewayInput,
    });
    //Post
    http.Response res = await http.post(
      uri,
      headers: headers,
      body: jsonEncode(params),
    );
    dynamic body = jsonDecode(res.body);
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
      return callGwApi(method, params: params, gatewayInput: gatewayInput);
    }
    return body;
  }

  Future<Map<dynamic, dynamic>> callPublicApi(String path) async {
    http.Response res = await http.get(
      Uri.parse('https://api.deezer.com/' + path),
    );
    return jsonDecode(res.body);
  }

  Future<String> getJsonWebToken() async {
    //Generate URL
    //Uri uri = Uri.parse('https://auth.deezer.com/login/arl?jo=p&rto=c&i=c');
    Uri uri = Uri.https('auth.deezer.com', '/login/arl', {
      'jo': 'p',
      'rto': 'c',
      'i': 'c',
    });
    //Post
    http.Response res = await http.post(uri, headers: headers);
    dynamic body = jsonDecode(res.body);
    //Grab jwt token
    if (body['jwt']?.isNotEmpty) {
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
    Map<String, String> pipeApiHeaders = headers;
    // Add jwt token to headers
    pipeApiHeaders['Authorization'] = 'Bearer $jwtToken';
    // Change Content-Type to application/json
    pipeApiHeaders['Content-Type'] = 'application/json';
    //Generate URL
    //Uri uri = Uri.parse('https://pipe.deezer.com/api');
    Uri uri = Uri.https('pipe.deezer.com', '/api/');
    //Post
    http.Response res = await http.post(
      uri,
      headers: pipeApiHeaders,
      body: jsonEncode(params),
    );
    dynamic body = jsonDecode(res.body);

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

    return Album.fromPrivateJson(
      data['results']['DATA'],
      songsJson: data['results']['SONGS'],
    );
  }

  //Get artist details
  Future<Artist> artist(String id) async {
    Map<dynamic, dynamic> data = await callGwApi(
      'deezer.pageArtist',
      params: {'art_id': id, 'lang': _deezerLanguage},
    );
    return Artist.fromPrivateJson(
      data['results']['DATA'],
      topJson: data['results']['TOP'],
      albumsJson: data['results']['ALBUMS'],
      highlight: data['results']['HIGHLIGHT'],
    );
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
    return Playlist.fromPrivateJson(
      data['results']['DATA'],
      songsJson: data['results']['SONGS'],
    );
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
    return data['results']['TAB']['playlists']['data']
        .map<Playlist>((json) => Playlist.fromPrivateJson(json, library: true))
        .toList();
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
              milliseconds
              duration
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
    if (data['errors'] != null && data['errors'].length > 0) {
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

  //Get homepage/music library from deezer
  Future<HomePage> homePage() async {
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
    ];

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

    Map data = await callGwApi(
      'page.get',
      gatewayInput: jsonEncode({
        'PAGE': 'home',
        'VERSION': '2.5',
        'SUPPORT': {
          /*
        "deeplink-list": ["deeplink"],
        "list": ["episode"],
        "grid-preview-one": grid,
        "grid-preview-two": grid,
        "slideshow": grid,
        "message": ["call_onboarding"],
        */
          'filterable-grid': ['flow'],
          'grid': grid,
          'horizontal-grid': grid,
          'item-highlight': ['radio'],
          'large-card': ['album', 'playlist', 'show', 'video-link'],
          'ads': [], //Nope
        },
        'LANG': _deezerLanguage,
        'OPTIONS': [],
      }),
    );
    return HomePage.fromPrivateJson(data['results']);
  }

  //Log song listen to deezer
  Future logListen(String trackId, QueueSource? queue) async {
    final String? queuesrc = queue?.source;
    final String? queueid = queue?.id;
    await callGwApi(
      'log.listen',
      params: {
        'params': {
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'ts_listen': DateTime.now().millisecondsSinceEpoch,
          'type': 1,
          'stat': {'seek': 0, 'pause': 0, 'sync': 1},
          'ctxt': {'t': queuesrc, 'id': queueid},
          'media': {'id': trackId, 'type': 'song', 'format': 'MP3_128'},
        },
      },
    );
  }

  Future<HomePage> getChannel(String target) async {
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
    ];
    Map data = await callGwApi(
      'page.get',
      gatewayInput: jsonEncode({
        'PAGE': target,
        'VERSION': '2.5',
        'SUPPORT': {
          /*
        "deeplink-list": ["deeplink"],
        "list": ["episode"],
        "grid-preview-one": grid,
        "grid-preview-two": grid,
        "slideshow": grid,
        "message": ["call_onboarding"],
        */
          'filterable-grid': ['flow'],
          'grid': grid,
          'horizontal-grid': grid,
          'item-highlight': ['radio'],
          'large-card': ['album', 'playlist', 'show', 'video-link'],
          'ads': [], //Nope
        },
        'LANG': _deezerLanguage,
        'OPTIONS': [],
      }),
    );
    return HomePage.fromPrivateJson(data['results']);
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

  Future<List<ShowEpisode>> allShowEpisodes(String showId) async {
    Map data = await callGwApi(
      'deezer.pageShow',
      params: {
        'country': _deezerCountry,
        'lang': _deezerLanguage,
        'nb': 1000,
        'show_id': showId,
        'start': 0,
        'user_id': int.parse(deezerAPI.userId ?? ''),
      },
    );
    return data['results']['EPISODES']['data']
        .map<ShowEpisode>((e) => ShowEpisode.fromPrivateJson(e))
        .toList();
  }
}
