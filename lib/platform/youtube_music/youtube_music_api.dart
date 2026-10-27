import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import '../../api/definitions.dart';
import '../music_platform.dart';
import 'parsers/item_parsers.dart';
import 'youtube_music_account.dart';
import 'youtube_music_client.dart';
import 'ytmusicapi_translations.dart';
import 'ytmusicapi/ytmusicapi_client.dart';

/// High-level API for YouTube Music operations in Saturn.
class YouTubeMusicApi {
  YouTubeMusicApi({YouTubeMusicClient? client})
    : this._(client ?? YouTubeMusicClient());

  YouTubeMusicApi._(this.client) : ytmusicapi = YtMusicApiClient(client);

  final YouTubeMusicClient client;
  final YtMusicApiClient ytmusicapi;
  final Logger _log = Logger('YouTubeMusicApi');
  final Map<String, List<Track>> _sortedLikedTracksCache = {};

  /// Applies an opaque Listen again action token returned by YouTube Music.
  Future<void> sendFeedbackToken(String token) async {
    if (token.isEmpty) {
      return;
    }
    final response = await ytmusicapi.library.editSongLibraryStatusRaw(
      feedbackTokens: [token],
      gzipBody: true,
    );
    if (response['error'] != null) {
      throw StateError(
        'YouTube Music rejected the Listen again change: ${response['error']}',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Search
  // ---------------------------------------------------------------------------

  /// Search for songs, albums, artists, playlists, podcasts, and episodes.
  Future<SearchResults> search(String query) async {
    _log.fine('Searching YTM for query: "$query"');

    final results = await Future.wait([
      _searchCategory(
        query,
        'songs',
        (r) => YouTubeMusicParsers.parseTrackFromResponsiveListItem(r),
        twoRowParser: YouTubeMusicParsers.parseTrackFromTwoRowItem,
      ),
      _searchCategory(
        query,
        'albums',
        (r) => YouTubeMusicParsers.parseAlbumFromResponsiveListItem(r),
        twoRowParser: YouTubeMusicParsers.parseAlbumFromTwoRowItem,
      ),
      _searchCategory(
        query,
        'artists',
        (r) => YouTubeMusicParsers.parseArtistFromResponsiveListItem(r),
      ),
      _searchCategory(
        query,
        'playlists',
        (r) => YouTubeMusicParsers.parsePlaylistFromResponsiveListItem(r),
      ),
      _searchCategory(
        query,
        'podcasts',
        (r) => YouTubeMusicParsers.parseShowFromResponsiveListItem(r),
        twoRowParser: YouTubeMusicParsers.parseShowFromTwoRowItem,
      ),
      _searchCategory(
        query,
        'episodes',
        (r) => YouTubeMusicParsers.parseEpisodeFromResponsiveListItem(r),
        multiRowParser: (r) =>
            YouTubeMusicParsers.parseEpisodeFromMultiRowListItem(r),
        twoRowParser: YouTubeMusicParsers.parseEpisodeFromTwoRowItem,
      ),
      _searchCategory(
        query,
        'videos',
        (r) => YouTubeMusicParsers.parseTrackFromResponsiveListItem(r),
        twoRowParser: YouTubeMusicParsers.parseTrackFromTwoRowItem,
      ),
    ]);

    final tracksAndVideos = [
      ...results[0].cast<Track>(),
      ...results[6].cast<Track>(),
    ];

    final radios = <LiveRadio>[];
    final normalTracks = <Track>[];
    for (final track in tracksAndVideos) {
      if (track.id!.startsWith('radio:')) {
        radios.add(
          LiveRadio(
            id: track.id!.substring(6),
            title: track.title,
            description: track.artistString ?? '',
            customImageUrl: track.albumArt?.fullUrl,
          ),
        );
      } else {
        normalTracks.add(track);
      }
    }

    return SearchResults(
      tracks: normalTracks,
      albums: results[1].cast<Album>(),
      artists: results[2].cast<Artist>(),
      playlists: results[3].cast<Playlist>(),
      shows: results[4].cast<Show>(),
      episodes: results[5].cast<ShowEpisode>(),
      radios: radios,
    );
  }

  Future<List<T>> _searchCategory<T>(
    String query,
    String filter,
    T? Function(Map<String, dynamic>) parser, {
    T? Function(Map<String, dynamic>)? multiRowParser,
    T? Function(Map<String, dynamic>)? twoRowParser,
  }) async {
    try {
      final translations = await YTMusicApiTranslations.load(client.hl);
      return await ytmusicapi.search.searchMapped<T>(
        query,
        filter: filter,
        limit: 20,
        parseResponsive: parser,
        parseMultiRow: multiRowParser,
        parseTwoRow: twoRowParser,
        translate: translations.translate,
      );
    } catch (error, stackTrace) {
      _log.warning(
        'Error in _searchCategory ($filter): $error',
        error,
        stackTrace,
      );
      return [];
    }
  }

  static Map<String, dynamic>? _asMap(dynamic value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    return null;
  }

  /// Instant search suggestions.
  Future<List<String>> searchSuggestions(String query) async {
    try {
      final suggestions = await ytmusicapi.search.getSearchSuggestions(query);
      return suggestions.whereType<String>().toList();
    } catch (e) {
      _log.warning('Error fetching YTM suggestions: $e');
      return [];
    }
  }

  Future<String?> getRadioStreamUrl(String id) async {
    final cleanId = id.startsWith('radio:')
        ? id.substring(6)
        : (id.startsWith('mix:') ? id.substring(4) : id);
    try {
      final response = await http.post(
        Uri.parse('https://www.youtube.com/youtubei/v1/player'),
        headers: {
          'Content-Type': 'application/json',
          'User-Agent':
              'com.google.android.youtube/21.01.38 (Linux; U; Android 11; ${client.hl}_${client.gl}) gzip',
        },
        body: jsonEncode({
          'context': {
            'client': {
              'clientName': 'ANDROID',
              'clientVersion': '21.01.38',
              'hl': client.hl,
              'gl': client.gl,
            },
          },
          'videoId': cleanId,
          'contentCheckOk': true,
          'racyCheckOk': true,
        }),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final hls = data['streamingData']?['hlsManifestUrl'];
        if (hls is String && hls.isNotEmpty) {
          return hls;
        }
      }
    } catch (e) {
      _log.warning('Failed to fetch radio stream URL: $e');
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Content Fetching
  // ---------------------------------------------------------------------------

  /// Fetches track metadata by YouTube videoId.
  Future<Track> getTrack(String id) async {
    _log.fine('Fetching track details for id=$id');
    final realId = id.startsWith('radio:')
        ? id.substring(6)
        : (id.startsWith('mix:') ? id.substring(4) : id);
    try {
      final parsed = await ytmusicapi.watch.getWatchPlaylist(
        videoId: realId,
        limit: 10,
      );
      for (final value in parsed['tracks'] as List? ?? const []) {
        if (value is! Map || value['videoId'] != realId) {
          continue;
        }
        final track = YouTubeMusicParsers.parseTrackFromParsedPlaylistItem(
          Map<String, dynamic>.from(value),
        );
        if (track != null) {
          if (id.startsWith('radio:')) {
            track.id = 'radio:$realId';
          }
          return track;
        }
      }
    } catch (e) {
      _log.warning('Error in getTrack: $e');
    }

    // The watch-next queue can omit a track when it is requested without its
    // original playlist context. The player response still exposes the video
    // metadata needed to render local playlists correctly.
    try {
      final player = await ytmusicapi.watch.playerRaw(realId);
      final details = _asMap(player['videoDetails']);
      final title = details?['title']?.toString();
      if (details != null && title != null && title.isNotEmpty) {
        final author = details['author']?.toString().replaceFirst(
          RegExp(r'\s+-\s+Topic$'),
          '',
        );
        final channelId = details['channelId']?.toString();
        final artists = author != null && author.isNotEmpty
            ? [Artist(id: channelId, name: author, platformId: 'youtube_music')]
            : <Artist>[];
        final thumbnail = YouTubeMusicParsers.parseImageDetails(
          details['thumbnail'],
        );
        final durationSeconds = int.tryParse(
          details['lengthSeconds']?.toString() ?? '',
        );
        final isLive =
            details['isLiveContent'] == true ||
            details['isLive'] == true ||
            details['musicVideoType'] == 'MUSIC_VIDEO_TYPE_LIVE';
        return Track(
          id: isLive || id.startsWith('radio:') ? 'radio:$realId' : realId,
          title: title,
          artists: artists,
          navigableArtists: artists,
          duration: durationSeconds == null
              ? null
              : Duration(seconds: durationSeconds),
          albumArt:
              thumbnail ??
              ImageDetails(
                fullUrl: 'https://i.ytimg.com/vi/$realId/hqdefault.jpg',
              ),
          platformId: 'youtube_music',
        );
      }
    } catch (e) {
      _log.warning('Could not load player metadata for track $realId: $e');
    }

    // Fallback minimal track
    return Track(
      id: realId,
      title: 'YouTube Track $realId',
      platformId: 'youtube_music',
      duration: Duration.zero,
      artists: const [],
      navigableArtists: const [],
      albumArt: ImageDetails(
        fullUrl: 'https://i.ytimg.com/vi/$realId/hqdefault.jpg',
      ),
    );
  }

  /// Fetches multiple tracks by ID.
  Future<List<Track>> getTracks(List<String> ids) async {
    // Keep playlist order and duplicates while limiting concurrent Innertube
    // requests so loading a page does not issue a burst of requests at once.
    final tracks = <Track>[];
    const batchSize = 4;
    for (var start = 0; start < ids.length; start += batchSize) {
      final end = (start + batchSize).clamp(0, ids.length).toInt();
      tracks.addAll(await Future.wait(ids.sublist(start, end).map(getTrack)));
    }
    return tracks;
  }

  /// Fetches an album by its browseId (e.g. MPREb_...).
  Future<Album> getAlbum(String id) async {
    _log.fine('Fetching album browseId=$id');
    final parsed = await ytmusicapi.browsing.getAlbum(id);
    final artists = (parsed['artists'] as List? ?? const [])
        .whereType<Map>()
        .map(
          (artist) => Artist(
            id: artist['id'] as String?,
            name: artist['name'] as String?,
            platformId: 'youtube_music',
          ),
        )
        .toList();
    final album = Album(
      id: id,
      title: parsed['title'] as String? ?? 'Unknown Album',
      artists: artists,
      art: YouTubeMusicParsers.parseImageDetails({
        'thumbnails': parsed['thumbnails'],
      }),
      releaseDate: parsed['year']?.toString(),
      platformId: 'youtube_music',
    );
    final tracks = <Track>[];
    for (final value in parsed['tracks'] as List? ?? const []) {
      if (value is! Map) {
        continue;
      }
      final track = YouTubeMusicParsers.parseTrackFromParsedPlaylistItem(
        Map<String, dynamic>.from(value),
        fallbackAlbum: album,
      );
      if (track != null) {
        track.trackNumber ??= tracks.length + 1;
        tracks.add(track);
      }
    }
    for (final track in tracks) {
      if (album.art == null && track.albumArt != null) {
        album.art = track.albumArt;
      }
    }
    for (final track in tracks) {
      track.albumArt ??= album.art;
    }
    album.tracks = tracks;
    return album;
  }

  /// Fetches an artist by browseId/channelId (e.g. UC...).
  Future<Artist> getArtist(String id) async {
    _log.fine('Fetching artist browseId=$id');
    final translations = await YTMusicApiTranslations.load(client.hl);
    final browseId = id.startsWith('MPLA') ? id.substring(4) : id;
    final parsed = await ytmusicapi.browsing.getArtist(
      browseId,
      translate: translations.translate,
    );
    final songs = _asMap(parsed['songs']) ?? const <String, dynamic>{};
    final topTracks = <Track>[];
    for (final value in songs['results'] as List? ?? const []) {
      if (value is Map) {
        final track = YouTubeMusicParsers.parseTrackFromParsedPlaylistItem(
          Map<String, dynamic>.from(value),
        );
        if (track != null) {
          topTracks.add(track);
        }
      }
    }
    final albums = <Album>[];
    for (final key in ['albums', 'singles']) {
      final section = _asMap(parsed[key]);
      for (final value in section?['results'] as List? ?? const []) {
        if (value is! Map) {
          continue;
        }
        final data = Map<String, dynamic>.from(value);
        final artists = (data['artists'] as List? ?? const [])
            .whereType<Map>()
            .map(
              (artist) => Artist(
                id: artist['id'] as String?,
                name: artist['name'] as String?,
                platformId: 'youtube_music',
              ),
            )
            .toList();
        albums.add(
          Album(
            id: data['browseId'] as String?,
            title: data['title'] as String?,
            artists: artists,
            art: YouTubeMusicParsers.parseImageDetails({
              'thumbnails': data['thumbnails'],
            }),
            pinned: data['pinnedToListenAgain'] == true,
            type: key == 'singles' ? AlbumType.SINGLE : AlbumType.ALBUM,
            releaseDate: data['year']?.toString(),
            platformId: 'youtube_music',
          ),
        );
      }
    }
    final artistPlaylists = <Playlist>[];
    final playlistSection = _asMap(parsed['playlists']);
    for (final value in playlistSection?['results'] as List? ?? const []) {
      if (value is! Map) {
        continue;
      }
      final data = Map<String, dynamic>.from(value);
      final playlistId = data['playlistId'] as String?;
      if (playlistId == null || playlistId.isEmpty) {
        continue;
      }
      artistPlaylists.add(
        Playlist(
          id: playlistId,
          title: data['title'] as String?,
          trackCount: int.tryParse(data['count']?.toString() ?? ''),
          image: YouTubeMusicParsers.parseImageDetails({
            'thumbnails': data['thumbnails'],
          }),
          description: data['description'] as String?,
          platformId: 'youtube_music',
        ),
      );
    }
    final similarArtists = <Artist>[];
    final relatedSection = _asMap(parsed['related']);
    for (final value in relatedSection?['results'] as List? ?? const []) {
      if (value is! Map) {
        continue;
      }
      final data = Map<String, dynamic>.from(value);
      final relatedId = data['browseId'] as String?;
      if (relatedId == null || relatedId.isEmpty) {
        continue;
      }
      similarArtists.add(
        Artist(
          id: relatedId,
          name: data['title'] as String?,
          picture: YouTubeMusicParsers.parseImageDetails({
            'thumbnails': data['thumbnails'],
          }),
          platformId: 'youtube_music',
        ),
      );
    }
    final videos = _parseArtistVideos(parsed);
    final videoSection = _asMap(parsed['videos']);
    final rawBrowseId = videoSection?['browseId'] as String?;
    final videoPlaylistId = (rawBrowseId != null &&
            (rawBrowseId.startsWith('VL') ||
                rawBrowseId.startsWith('PL') ||
                rawBrowseId.startsWith('OLAK5uy_')))
        ? rawBrowseId
        : '';

    return Artist(
      id: browseId,
      name: parsed['artist'] as String? ?? 'Unknown Artist',
      picture: YouTubeMusicParsers.parseImageDetails({
        'thumbnails': parsed['thumbnails'],
      }),
      topTracks: topTracks,
      topSongsPlaylistId: songs['browseId'] as String?,
      albums: albums,
      albumCount: albums.length,
      description: parsed['description'] as String?,
      playlists: artistPlaylists,
      similarArtists: similarArtists,
      pageSectionsLoaded: true,
      customData: {'videos': videos, 'videoPlaylistId': videoPlaylistId},
      radio: parsed['radioPlaylistId'] is String,
      platformId: 'youtube_music',
    );
  }

  Future<List<Track>> getArtistVideos(
    Object artistOrId, {
    int? limit = 5,
  }) async {
    if (limit != null && limit <= 0) {
      return const [];
    }
    // Accept an Artist so the section can share its runtime customData cache,
    // while retaining ID compatibility for other callers.
    final artist = artistOrId is Artist
        ? artistOrId
        : await getArtist(artistOrId.toString());
    var cached =
        (artist.customData['videos'] as List?)?.whereType<Track>().toList() ??
        <Track>[];
    final videoPlaylistId = artist.customData['videoPlaylistId'] as String?;
    if (!artist.customData.containsKey('videos') && artist.id != null) {
      try {
        final refreshed = await getArtist(artist.id!);
        artist.customData = refreshed.customData;
        cached = List<Track>.of(
          (artist.customData['videos'] as List?)?.whereType<Track>() ?? const [],
        );
      } catch (e, st) {
        _log.warning('Failed to refresh artist videos for ${artist.id}', e, st);
      }
    }
    final playlistId =
        videoPlaylistId ?? artist.customData['videoPlaylistId'] as String?;
    if ((limit == null || cached.length < limit) &&
        playlistId != null &&
        playlistId.isNotEmpty) {
      try {
        final parsedPlaylist = await ytmusicapi.playlists.getPlaylist(
          playlistId,
          limit: limit,
        );
        final parsedVideos = parsedPlaylist['tracks'] as List? ?? const [];
        final fetched = <Track>[];
        for (final value in parsedVideos) {
          final track = YouTubeMusicParsers.parseTrackFromParsedPlaylistItem(
            value,
          );
          if (track != null &&
              !cached.any((existing) => existing.id == track.id) &&
              !fetched.any((existing) => existing.id == track.id)) {
            fetched.add(track);
          }
        }
        if (fetched.isNotEmpty) {
          cached = [...cached, ...fetched];
          artist.customData = {...artist.customData, 'videos': cached};
        }
      } catch (e, st) {
        _log.warning(
          'Failed to load artist videos from playlist $playlistId: $e',
          e,
          st,
        );
      }
    }
    return List<Track>.of(limit == null ? cached : cached.take(limit));
  }

  List<Track> _parseArtistVideos(Map<String, dynamic> parsed) {
    final section = _asMap(parsed['videos']);
    final videos = <Track>[];
    for (final value in section?['results'] as List? ?? const []) {
      if (value is! Map) {
        continue;
      }
      final video = YouTubeMusicParsers.parseTrackFromParsedPlaylistItem(
        Map<String, dynamic>.from(value),
      );
      if (video != null) {
        videos.add(video);
      }
    }
    return videos;
  }

  void _collectRenderer(
    dynamic value,
    String key,
    List<Map<String, dynamic>> output,
  ) {
    if (value is Map) {
      for (final entry in value.entries) {
        if (entry.key == key && entry.value is Map) {
          output.add(Map<String, dynamic>.from(entry.value as Map));
        } else {
          _collectRenderer(entry.value, key, output);
        }
      }
    } else if (value is List) {
      for (final item in value) {
        _collectRenderer(item, key, output);
      }
    }
  }

  Future<Show> _showFromParsedPodcast(
    String showId,
    Map<String, dynamic> parsed,
  ) async {
    final channel = parsed['channel'];
    return Show(
      id: showId,
      name: parsed['title'] as String? ?? 'Podcast',
      creator: channel is Map ? channel['name'] as String? : null,
      description: parsed['description'] as String?,
      art: YouTubeMusicParsers.parseImageDetails({
        'thumbnails': parsed['thumbnails'],
      }),
      platformId: 'youtube_music',
    );
  }

  ShowEpisode? _episodeFromParsedPodcast(
    Map<String, dynamic> parsed,
    Show show, {
    Show? collection,
  }) {
    final id = parsed['videoId'] as String?;
    if (id == null || id.isEmpty) {
      return null;
    }
    final duration = YouTubeMusicParsers.parseDuration(
      parsed['duration'] as String? ?? parsed['length'] as String?,
    );
    final rawProgress = parsed['progressPercentage'];
    final progress = rawProgress is num
        ? (rawProgress / 100).clamp(0.0, 1.0).toDouble()
        : null;
    final podcast = _asMap(parsed['podcast']);
    final episodeShow = collection == null
        ? show
        : Show(
            id: podcast?['id'] as String?,
            name: podcast?['name'] as String? ?? 'YouTube Music Podcast',
            platformId: 'youtube_music',
          );
    return ShowEpisode(
      id: id,
      title: parsed['title'] as String? ?? 'Unknown Episode',
      description: parsed['description'] as String?,
      show: episodeShow,
      art: YouTubeMusicParsers.parseImageDetails({
        'thumbnails': parsed['thumbnails'] ?? parsed['thumbnail'],
      }),
      duration: duration,
      publishedDate: parsed['date'] as String?,
      bookmarkSeconds: duration != null && progress != null
          ? (duration.inSeconds * progress).round()
          : null,
      progressPercentage: progress,
      isHeard: progress != null && progress >= 0.95,
      collection: collection,
    );
  }

  bool _isEpisodeCollectionId(String id) =>
      id == 'VLRDPN' || id == 'VLSE' || id == 'RDPN' || id == 'SE';

  Future<PaginatedShowEpisodeList> _getEpisodeCollectionPage(
    String collectionId, {
    required int start,
    required int limit,
  }) async {
    if (collectionId == 'VLSE' || collectionId == 'SE') {
      final parsed = await ytmusicapi.playlists.getSavedEpisodes(
        limit: start + limit + 1,
      );
      final collection = Show(
        id: collectionId,
        name: parsed['title'] as String? ?? 'Episodes for later',
        description: parsed['description'] as String?,
        art: YouTubeMusicParsers.parseImageDetails({
          'thumbnails': parsed['thumbnails'],
        }),
        platformId: 'youtube_music',
      );
      final episodes = <ShowEpisode>[];
      for (final value in parsed['tracks'] as List? ?? const []) {
        if (value is! Map) {
          continue;
        }
        final track = YouTubeMusicParsers.parseTrackFromParsedPlaylistItem(
          Map<String, dynamic>.from(value),
        );
        if (track == null) {
          continue;
        }
        final rawProgress = value['progressPercentage'];
        final progress = rawProgress is num
            ? (rawProgress / 100).clamp(0.0, 1.0).toDouble()
            : null;
        final albumArtists = track.album?.artists;
        final firstArtist = albumArtists != null && albumArtists.isNotEmpty
            ? albumArtists.first
            : null;
        episodes.add(
          ShowEpisode(
            id: track.id,
            title: track.title,
            description: value['description'] as String?,
            art: track.albumArt ?? collection.art,
            duration: track.duration,
            show: firstArtist == null
                ? Show(
                    name: 'YouTube Music Podcast',
                    platformId: 'youtube_music',
                  )
                : Show(
                    id: firstArtist.id,
                    name: firstArtist.name,
                    platformId: 'youtube_music',
                  ),
            pinned: track.pinned,
            bookmarkSeconds: progress != null && track.duration != null
                ? (progress * track.duration!.inSeconds).round()
                : null,
            progressPercentage: progress,
            isHeard: progress != null && progress >= 0.95,
            collection: collection,
          ),
        );
      }
      return PaginatedShowEpisodeList(
        episodes: episodes.skip(start).take(limit).toList(),
        hasMore: episodes.length > start + limit,
      );
    }
    final playlistId = collectionId.startsWith('VL')
        ? collectionId.substring(2)
        : collectionId;
    final parsed = await ytmusicapi.podcasts.getEpisodesPlaylist(
      playlistId: playlistId,
      limit: start + limit + 1,
    );
    final collection = Show(
      id: collectionId,
      name: parsed['title'] as String? ?? 'Episodes',
      description: parsed['description'] as String?,
      art: YouTubeMusicParsers.parseImageDetails({
        'thumbnails': parsed['thumbnails'],
      }),
      platformId: 'youtube_music',
    );
    final episodes = (parsed['episodes'] as List? ?? const [])
        .whereType<Map>()
        .map(
          (value) => _episodeFromParsedPodcast(
            Map<String, dynamic>.from(value),
            collection,
            collection: collection,
          ),
        )
        .whereType<ShowEpisode>()
        .toList();
    return PaginatedShowEpisodeList(
      episodes: episodes.skip(start).take(limit).toList(),
      hasMore: episodes.length > start + limit,
    );
  }

  Future<PaginatedShowEpisodeList> getShowEpisodesPage(
    String showId, {
    int start = 0,
    int limit = 50,
  }) async {
    final offset = start < 0 ? 0 : start;
    final size = limit < 1 ? 1 : limit;
    if (_isEpisodeCollectionId(showId)) {
      return _getEpisodeCollectionPage(showId, start: offset, limit: size);
    }
    final parsed = await ytmusicapi.podcasts.getPodcast(
      showId,
      limit: offset + size + 1,
    );
    final show = await _showFromParsedPodcast(showId, parsed);
    final episodes = (parsed['episodes'] as List? ?? const [])
        .whereType<Map>()
        .map(
          (value) =>
              _episodeFromParsedPodcast(Map<String, dynamic>.from(value), show),
        )
        .whereType<ShowEpisode>()
        .toList();
    return PaginatedShowEpisodeList(
      episodes: episodes.skip(offset).take(size).toList(),
      hasMore: episodes.length > offset + size,
    );
  }

  Future<List<ShowEpisode>> getShowEpisodes(String showId) async {
    if (_isEpisodeCollectionId(showId)) {
      final page = await _getEpisodeCollectionPage(
        showId,
        start: 0,
        limit: 10000,
      );
      return page.episodes;
    }
    final parsed = await ytmusicapi.podcasts.getPodcast(showId, limit: null);
    final show = await _showFromParsedPodcast(showId, parsed);
    return (parsed['episodes'] as List? ?? const [])
        .whereType<Map>()
        .map(
          (value) =>
              _episodeFromParsedPodcast(Map<String, dynamic>.from(value), show),
        )
        .whereType<ShowEpisode>()
        .toList();
  }

  /// Fetches a playlist by ID (e.g. PL... or VL...).
  Future<Playlist> getPlaylist(String id, {int? limit = 100}) async {
    final parsed = await ytmusicapi.playlists.getPlaylist(id, limit: limit);
    final tracks = <Track>[];
    for (final value in parsed['tracks'] as List? ?? const []) {
      if (value is! Map) {
        continue;
      }
      final track = YouTubeMusicParsers.parseTrackFromParsedPlaylistItem(
        Map<String, dynamic>.from(value),
      );
      if (track != null) {
        track.trackNumber ??= tracks.length + 1;
        tracks.add(track);
      }
    }
    return Playlist(
      id: id,
      title: parsed['title'] as String? ?? 'Playlist $id',
      user: YouTubeMusicParsers.playlistUserFromAuthor(parsed['author']),
      image: YouTubeMusicParsers.parseImageDetails({
        'thumbnails': parsed['thumbnails'],
      }),
      description: parsed['description'] as String?,
      editable: parsed['owned'] == true,
      duration: parsed['duration_seconds'] is int
          ? Duration(seconds: parsed['duration_seconds'] as int)
          : null,
      tracks: tracks,
      trackCount: parsed['trackCount'] as int? ?? tracks.length,
      platformId: 'youtube_music',
    );
  }

  Future<List<Track>> getPlaylistTracksPage(
    String id,
    int start, {
    int limit = 100,
  }) async {
    final parsed = await ytmusicapi.playlists.getPlaylistPage(
      id,
      start: start,
      limit: limit,
    );
    final tracks = <Track>[];
    for (final value in parsed['tracks'] as List? ?? const []) {
      if (value is! Map) continue;
      final track = YouTubeMusicParsers.parseTrackFromParsedPlaylistItem(
        Map<String, dynamic>.from(value),
      );
      if (track != null) {
        track.trackNumber ??= start + tracks.length + 1;
        tracks.add(track);
      }
    }
    return tracks;
  }

  // ---------------------------------------------------------------------------
  // Lyrics
  // ---------------------------------------------------------------------------

  static String _cleanLyricLine(String text) => text
      .replaceAll(RegExp(r'[♪♫♬♩🎵🎶]'), '')
      .replaceAll(RegExp(r'[ \t]+'), ' ')
      .trim();

  static String _cleanLyrics(String text) => text
      .split('\n')
      .map(_cleanLyricLine)
      .where((line) => line.isNotEmpty)
      .join('\n');

  static String? _lyricsBrowseId(Map<String, dynamic> response) {
    final tabs =
        response['contents']?['singleColumnMusicWatchNextResultsRenderer']?['tabbedRenderer']?['watchNextTabbedResultsRenderer']?['tabs']
            as List?;
    for (final tab in tabs ?? const []) {
      final endpoint = tab['tabRenderer']?['endpoint']?['browseEndpoint'];
      final pageType =
          endpoint?['browseEndpointContextSupportedConfigs']?['browseEndpointContextMusicConfig']?['pageType'];
      if (pageType == 'MUSIC_PAGE_TYPE_TRACK_LYRICS') {
        return endpoint?['browseId'] as String?;
      }
    }
    return null;
  }

  Future<List<SynchronizedLyric>> _timedLyrics(String browseId) async {
    final response = await client.post(
      'browse',
      body: {'browseId': browseId},
      query: {'key': YouTubeMusicClient.webRemixApiKey},
      mobileClient: true,
    );
    final lines =
        response['contents']?['elementRenderer']?['newElement']?['type']?['componentType']?['model']?['timedLyricsModel']?['lyricsData']?['timedLyricsData'];
    if (lines is! List) {
      return [];
    }
    final synced = <SynchronizedLyric>[];
    for (final line in lines) {
      final cue = line['cueRange'];
      final start = num.tryParse(
        '${cue?['startTimeMilliseconds'] ?? ''}',
      )?.round();
      final end = num.tryParse('${cue?['endTimeMilliseconds'] ?? ''}')?.round();
      final text = _cleanLyricLine(line['lyricLine'] as String? ?? '');
      if (start == null || start < 0 || text.isEmpty) {
        continue;
      }
      synced.add(
        SynchronizedLyric(
          offset: Duration(milliseconds: start),
          duration: end != null && end > start
              ? Duration(milliseconds: end - start)
              : null,
          text: text,
        ),
      );
    }
    return synced;
  }

  Future<List<SynchronizedLyric>> _matchedSongLyrics(
    String trackId,
    Map<String, dynamic> nextResponse,
  ) async {
    final panel =
        nextResponse['contents']?['singleColumnMusicWatchNextResultsRenderer']?['tabbedRenderer']?['watchNextTabbedResultsRenderer']?['tabs']?[0]?['tabRenderer']?['content']?['musicQueueRenderer']?['content']?['playlistPanelRenderer'];
    final items = panel?['contents'] as List?;
    final renderer = items?.isNotEmpty == true
        ? items!.first['playlistPanelVideoRenderer']
        : null;
    if (renderer is! Map) {
      return [];
    }
    final source = YouTubeMusicParsers.parseTrackFromPlaylistPanelVideo(
      Map<String, dynamic>.from(renderer),
    );
    final title = source?.title?.trim() ?? '';
    if (title.isEmpty) {
      return [];
    }
    final query = '$title ${source?.artistString ?? ''}'.trim();
    final candidates = await _searchCategory<Track>(
      query,
      'EgWKAQIIAWoKEAkQBRAKEAMQBA==',
      YouTubeMusicParsers.parseTrackFromResponsiveListItem,
    );
    final normalizedTitle = title.toLowerCase();
    for (final candidate
        in candidates
            .where(
              (candidate) =>
                  candidate.id != trackId &&
                  candidate.title?.trim().toLowerCase() == normalizedTitle,
            )
            .take(5)) {
      try {
        final next = await client.post(
          'next',
          body: {
            'videoId': candidate.id,
            'enablePersistentPlaylistPanel': true,
            'isAudioOnly': true,
          },
        );
        final browseId = _lyricsBrowseId(next);
        if (browseId == null || browseId.isEmpty) {
          continue;
        }
        final synced = await _timedLyrics(browseId);
        if (synced.isNotEmpty) {
          _log.info(
            'Using timed lyrics from matching song ${candidate.id} for $trackId',
          );
          return synced;
        }
      } catch (e) {
        _log.fine('Matching song lyrics unavailable for ${candidate.id}: $e');
      }
    }
    return [];
  }

  /// Fetches lyrics for a track, first attempting YouTube Music's native lyrics.
  Future<Lyrics> getLyrics(String trackId) async {
    _log.fine('Fetching lyrics for trackId=$trackId');
    try {
      final nextRes = await client.post(
        'next',
        body: {
          'videoId': trackId,
          'enablePersistentPlaylistPanel': true,
          'isAudioOnly': true,
        },
      );

      final lyricsBrowseId = _lyricsBrowseId(nextRes);

      if (lyricsBrowseId != null && lyricsBrowseId.isNotEmpty) {
        try {
          final synced = await _timedLyrics(lyricsBrowseId);
          if (synced.isNotEmpty) {
            return Lyrics(id: trackId, syncedLyrics: synced);
          }
        } catch (e) {
          _log.fine('Timed lyrics unavailable for $trackId: $e');
        }

        final matched = await _matchedSongLyrics(trackId, nextRes);
        if (matched.isNotEmpty) {
          return Lyrics(id: trackId, syncedLyrics: matched);
        }

        final browseRes = await client.post(
          'browse',
          body: {'browseId': lyricsBrowseId},
        );

        final contents =
            browseRes['contents']?['sectionListRenderer']?['contents'] as List?;
        final shelf = contents?[0]?['musicDescriptionShelfRenderer'];
        final rawLyrics = shelf?['description']?['runs']
            ?.map((r) => r['text'] ?? '')
            ?.join('');

        if (rawLyrics != null && _cleanLyrics(rawLyrics).isNotEmpty) {
          return Lyrics(id: trackId, unsyncedLyrics: _cleanLyrics(rawLyrics));
        }
      }
    } catch (e) {
      _log.warning('Error fetching YTM lyrics: $e');
    }

    return Lyrics(id: trackId);
  }

  // ---------------------------------------------------------------------------
  // Discovery & Flow (Radio)
  // ---------------------------------------------------------------------------

  /// Fetches the YouTube Music home feed through ytmusicapi's parser.
  Future<HomePage> getHomePage() async {
    // The home feed is rendered as a long, vertically scrolling page. Keep
    // its initial request bounded so opening Home does not fetch dozens of
    // continuation shelves before the user scrolls anywhere near them.
    final parsedSections = await ytmusicapi.browsing.getHome(limit: 24);
    final sections = <HomePageSection>[];
    for (final section in parsedSections) {
      final rows = section['contents'] as List? ?? const [];
      final items = <HomePageItem?>[];
      for (final row in rows) {
        if (row is Map) {
          final item = YouTubeMusicParsers.parseHomeItem(
            Map<String, dynamic>.from(row),
          );
          if (item != null) {
            items.add(item);
          }
        }
      }
      if (items.isNotEmpty) {
        sections.add(
          HomePageSection(
            title: section['title'] as String?,
            pagePath: section['pagePath'] as String?,
            layout: HomePageSectionLayout.ROW,
            items: items,
          ),
        );
      }
    }
    return HomePage(sections: sections);
  }

  /// Fetches an Innertube channel / browse endpoint and parses its shelves into a [HomePage].
  Future<HomePage> getChannel(String target, {String? params}) async {
    String browseId = target;
    String? finalParams = params;
    if (target.contains('?')) {
      final uri = Uri.tryParse(target);
      if (uri != null) {
        if (uri.path.isNotEmpty) browseId = uri.path;
        finalParams ??= uri.queryParameters['params'];
      }
    }
    if (browseId.startsWith('/')) {
      browseId = browseId.substring(1);
    }

    try {
      final body = <String, dynamic>{
        'browseId': browseId,
        if (finalParams != null && finalParams.isNotEmpty)
          'params': finalParams,
      };
      final res = await client.post('browse', body: body);
      final contentsMap = res['contents'] as Map<dynamic, dynamic>?;
      final singleColumn =
          contentsMap?['singleColumnBrowseResultsRenderer']
              as Map<dynamic, dynamic>?;
      final tabs = singleColumn?['tabs'] as List?;
      Map<dynamic, dynamic>? sectionList;
      if (tabs != null && tabs.isNotEmpty && tabs[0] is Map) {
        final tab = tabs[0] as Map;
        sectionList =
            tab['tabRenderer']?['content']?['sectionListRenderer']
                as Map<dynamic, dynamic>?;
      }
      sectionList ??=
          singleColumn?['sectionListRenderer'] as Map<dynamic, dynamic>?;
      final rawSections = sectionList != null
          ? (sectionList['contents'] as List? ?? [])
          : (singleColumn?['contents'] as List? ?? []);

      final sections = <HomePageSection>[];
      for (final s in rawSections) {
        if (s is Map) {
          final parsed = YouTubeMusicParsers.parseBrowseSection(s);
          if (parsed != null) sections.add(parsed);
        }
      }
      return HomePage(sections: sections);
    } catch (e, st) {
      _log.warning('Error in getChannel($target): $e', e, st);
      return HomePage(sections: []);
    }
  }

  /// Fetches an endless / flow radio mix for a track or seed.
  Future<List<Track>> getMix(String trackId) async {
    var cleanTrackId = trackId.startsWith('mix:')
        ? trackId.substring(4)
        : (trackId.startsWith('radio:') ? trackId.substring(6) : trackId);
    if (cleanTrackId.startsWith('VL')) {
      cleanTrackId = cleanTrackId.substring(2);
    }
    _log.fine('Fetching radio mix for id=$cleanTrackId');
    try {
      final String? videoId;
      final String playlistId;
      if (cleanTrackId.startsWith('RDAMVM')) {
        videoId = cleanTrackId.substring(6);
        playlistId = cleanTrackId;
      } else if (cleanTrackId.startsWith('RD')) {
        videoId = null;
        playlistId = cleanTrackId;
      } else {
        videoId = cleanTrackId;
        playlistId = 'RDAMVM$cleanTrackId';
      }
      final parsed = await ytmusicapi.watch.getWatchPlaylist(
        videoId: videoId,
        playlistId: playlistId,
        radio: true,
      );
      return _tracksFromParsedItems(parsed['tracks']);
    } catch (e, st) {
      _log.severe('Error getting mix', e, st);
      return [];
    }
  }

  /// Fetches an endless / flow radio mix for a given radio playlistId (e.g. from an artist).
  Future<List<Track>> getWatchPlaylist(String playlistId) async {
    var cleanId = playlistId;
    if (cleanId.startsWith('VL')) {
      cleanId = cleanId.substring(2);
    }
    _log.fine('Fetching watch playlist for playlistId=$cleanId');
    try {
      final parsed = await ytmusicapi.watch.getWatchPlaylist(
        playlistId: cleanId,
        radio: cleanId.startsWith('RD'),
      );
      return _tracksFromParsedItems(parsed['tracks']);
    } catch (e, st) {
      _log.severe('Error getting watch playlist', e, st);
      return [];
    }
  }

  List<Track> _tracksFromParsedItems(dynamic items) {
    if (items is! List) {
      return [];
    }
    final tracks = <Track>[];
    for (final item in items) {
      if (item is! Map) {
        continue;
      }
      final map = item is Map<String, dynamic>
          ? item
          : Map<String, dynamic>.from(item);
      final track = YouTubeMusicParsers.parseTrackFromParsedPlaylistItem(map);
      if (track != null) {
        tracks.add(track);
      }
    }
    return tracks;
  }

  /// YouTube Music exposes the visible history shelves in one browse result.
  Future<HistoryTrackPage> getHistoryTracks() async {
    final items = await ytmusicapi.library.getHistory();
    final rawTracks = _tracksFromParsedItems(items);
    final seen = <String>{};
    final tracks = rawTracks
        .where((t) => t.id != null && seen.add(t.id!))
        .toList();
    return HistoryTrackPage(tracks: tracks, nextCursor: null);
  }

  // ---------------------------------------------------------------------------
  // Account & User Library
  // ---------------------------------------------------------------------------

  /// Fetches authenticated account info using Innertube's account_menu endpoint.
  /// Returns [YouTubeMusicAccount] if valid and authenticated, or null if unauthenticated.
  Future<YouTubeMusicAccount?> getAccountInfo() async {
    _log.fine('Checking account info via account/account_menu');
    try {
      final res = await ytmusicapi.library.accountInfoRaw();
      final actions = res['actions'] as List?;
      if (actions == null || actions.isEmpty) {
        return null;
      }

      final header =
          actions[0]?['openPopupAction']?['popup']?['multiPageMenuRenderer']?['header']?['activeAccountHeaderRenderer'];

      if (header == null) {
        _log.fine(
          'No activeAccountHeaderRenderer in account_menu (not authenticated)',
        );
        return null;
      }

      final name = YouTubeMusicParsers.parseRuns(header['accountName']);
      final email = YouTubeMusicParsers.parseRuns(header['email']);
      final channelHandle = YouTubeMusicParsers.parseRuns(
        header['channelHandle'],
      );
      final photoDetails = YouTubeMusicParsers.parseImageDetails(
        header['accountPhoto'],
      );
      final photoUrl = photoDetails?.fullUrl ?? photoDetails?.thumbUrl;

      return YouTubeMusicAccount(
        name: name.isNotEmpty ? name : 'Google Account',
        email: email.isNotEmpty ? email : null,
        channelHandle: channelHandle.isNotEmpty ? channelHandle : null,
        photoUrl: photoUrl,
      );
    } catch (e) {
      _log.warning('Error fetching account info: $e');
      return null;
    }
  }

  /// Fetches the user's library playlists (FEmusic_liked_playlists).
  Future<List<Playlist>> getUserPlaylists() async {
    _log.fine('Fetching user library playlists');
    try {
      if (!client.isAuthenticated) {
        return [];
      }
      final parsed = await ytmusicapi.library.getLibraryPlaylists(limit: null);
      return parsed
          .whereType<Map>()
          .map((entry) {
            final playlist = Map<String, dynamic>.from(entry);
            final rawId = playlist['playlistId']?.toString();
            final normalizedId = rawId?.startsWith('VL') == true
                ? rawId!.substring(2)
                : rawId;
            // RDPN and SE are YouTube Music's generated podcast episode
            // collections, not regular playlists. Their contents use podcast
            // episode rows and must be loaded through the podcast endpoint.
            if (normalizedId == 'RDPN' || normalizedId == 'SE') {
              return null;
            }
            final id = rawId == null || rawId.isEmpty
                ? null
                : (rawId.startsWith('VL') ? rawId : 'VL$rawId');
            return Playlist(
              id: id,
              title: playlist['title'] as String? ?? 'Unknown Playlist',
              user: YouTubeMusicParsers.playlistUserFromAuthor(
                playlist['author'],
              ),
              image: YouTubeMusicParsers.parseImageDetails({
                'thumbnails': playlist['thumbnails'],
              }),
              description: playlist['description'] as String?,
              trackCount: int.tryParse(playlist['count']?.toString() ?? ''),
              editable: playlist['owned'] == true,
              platformId: 'youtube_music',
            );
          })
          .whereType<Playlist>()
          .where((playlist) => playlist.id != null)
          .toList();
    } catch (e) {
      _log.warning('Error fetching user playlists: $e');
      return [];
    }
  }

  /// Fetches the user's Liked Music (LM / VLLM) tracks page.
  Future<PaginatedTrackList> getFavoriteTracks({
    int start = 0,
    int limit = 100,
  }) async {
    _log.fine('Fetching favorite tracks (Liked Music)');
    try {
      final parsed = await ytmusicapi.playlists.getPlaylistPage(
        'LM',
        start: start,
        limit: limit,
      );
      return PaginatedTrackList(
        tracks: _tracksFromParsedItems(parsed['tracks']),
        hasMore: parsed['hasMore'] == true,
      );
    } catch (e) {
      _log.warning('Error fetching favorite tracks: $e');
      return PaginatedTrackList(tracks: [], hasMore: false);
    }
  }

  Future<List<Track>> getAllLikedTracks() async {
    try {
      final playlist = await getPlaylist('LM', limit: null);
      final tracks = playlist.tracks;
      if (tracks != null && tracks.isNotEmpty) return tracks;
    } catch (e) {
      _log.fine('Failed to fetch full liked playlist via getPlaylist: $e');
    }
    try {
      final parsed = await ytmusicapi.playlists.getPlaylistPage(
        'LM',
        start: 0,
        limit: 1000,
      );
      return _tracksFromParsedItems(parsed['tracks']);
    } catch (e) {
      _log.fine('Failed to fetch liked tracks via page: $e');
      return [];
    }
  }

  Future<List<T>> _libraryItems<T>(
    Future<List<dynamic>> Function() load,
    T? Function(Map<String, dynamic>) castModel,
  ) async {
    if (!client.isAuthenticated) {
      return [];
    }
    final items = <T>[];
    for (final value in await load()) {
      if (value is! Map) {
        continue;
      }
      final item = castModel(Map<String, dynamic>.from(value));
      if (item != null) {
        items.add(item);
      }
    }
    return items;
  }

  Future<List<Album>> getUserAlbums() => _libraryItems<Album>(
    () => ytmusicapi.library.getLibraryAlbums(limit: null),
    YouTubeMusicParsers.parseLibraryAlbum,
  );

  Future<List<Artist>> getUserArtists() => _libraryItems<Artist>(
    () => ytmusicapi.library.getLibraryArtists(limit: null),
    YouTubeMusicParsers.parseLibraryArtist,
  );

  Future<List<Show>> getUserShows() => _libraryItems<Show>(
    () => ytmusicapi.library.getLibraryPodcasts(limit: null),
    YouTubeMusicParsers.parseLibraryShow,
  );

  void _requireAuthentication() {
    if (!client.isAuthenticated) {
      throw StateError('Sign in to YouTube Music to change your library.');
    }
  }

  String _playlistId(String id) => id.startsWith('VL') ? id.substring(2) : id;

  void _checkEditResponse(Map<String, dynamic> response) {
    final status = response['status'] as String?;
    if (status != null && !status.contains('SUCCEEDED')) {
      throw StateError('YouTube Music rejected the playlist change: $status');
    }
  }

  Future<void> rateTrack(String id, {required String rating}) async {
    _requireAuthentication();
    final videoId = id.startsWith('radio:') ? id.substring(6) : id;
    await ytmusicapi.library.rateSongRaw(videoId, rating: rating);
    _sortedLikedTracksCache.clear();
  }

  Future<void> ratePlaylist(String id, {required bool add}) async {
    _requireAuthentication();
    await ytmusicapi.library.ratePlaylistRaw(
      _playlistId(id),
      rating: add ? 'LIKE' : 'INDIFFERENT',
    );
  }

  Future<void> rateAlbum(String id, {required bool add}) async {
    _requireAuthentication();
    final response = await ytmusicapi.browsing.browseRaw(id);
    final playButtons = <Map<String, dynamic>>[];
    _collectRenderer(response, 'musicPlayButtonRenderer', playButtons);
    String? playlistId;
    for (final button in playButtons) {
      playlistId =
          button['playNavigationEndpoint']?['watchEndpoint']?['playlistId']
              as String?;
      if (playlistId != null && playlistId.isNotEmpty) {
        break;
      }
    }
    if (playlistId == null || playlistId.isEmpty) {
      throw StateError('No playlist ID found for album $id');
    }
    await ratePlaylist(playlistId, add: add);
  }

  Future<void> subscribeArtist(String id, {required bool subscribe}) async {
    _requireAuthentication();
    await ytmusicapi.library.subscribeArtistsRaw([id], subscribe: subscribe);
  }

  Future<String> createPlaylist(
    String title, {
    String description = '',
    int status = 1,
    List<String> trackIds = const [],
  }) async {
    _requireAuthentication();
    final response = await ytmusicapi.playlists.createPlaylistRaw(
      title,
      description: description,
      privacyStatus: status == 2 ? 'PUBLIC' : 'PRIVATE',
      videoIds: trackIds,
    );
    final id = response['playlistId'] as String?;
    if (id == null || id.isEmpty) {
      throw StateError('YouTube Music did not return a playlist ID.');
    }
    return id;
  }

  Future<void> updatePlaylist(
    String id,
    String title, {
    String description = '',
    int status = 1,
  }) async {
    _requireAuthentication();
    final response = await ytmusicapi.playlists.editPlaylistRaw(
      _playlistId(id),
      [
        {'action': 'ACTION_SET_PLAYLIST_NAME', 'playlistName': title},
        {
          'action': 'ACTION_SET_PLAYLIST_DESCRIPTION',
          'playlistDescription': description,
        },
        {
          'action': 'ACTION_SET_PLAYLIST_PRIVACY',
          'playlistPrivacy': status == 2 ? 'PUBLIC' : 'PRIVATE',
        },
      ],
    );
    _checkEditResponse(response);
  }

  Future<void> deletePlaylist(String id) async {
    _requireAuthentication();
    final response = await ytmusicapi.playlists.deletePlaylistRaw(
      _playlistId(id),
    );
    _checkEditResponse(response);
  }

  Future<void> addToPlaylist(String trackId, String playlistId) async {
    _requireAuthentication();
    final response = await ytmusicapi.playlists.addPlaylistItemsRaw(
      _playlistId(playlistId),
      [
        {'action': 'ACTION_ADD_VIDEO', 'addedVideoId': trackId},
      ],
    );
    _checkEditResponse(response);
  }

  Future<void> removeFromPlaylist(String trackId, String playlistId) async {
    _requireAuthentication();
    final browseId = 'VL${_playlistId(playlistId)}';
    final response = await ytmusicapi.playlists.playlistRaw(browseId);
    final rows = <Map<String, dynamic>>[];
    _collectRenderer(response, 'musicResponsiveListItemRenderer', rows);
    String? setVideoId;
    for (final row in rows) {
      final menuItems = row['menu']?['menuRenderer']?['items'] as List? ?? [];
      for (final item in menuItems) {
        final actions =
            item['menuServiceItemRenderer']?['serviceEndpoint']?['playlistEditEndpoint']?['actions']
                as List? ??
            [];
        for (final action in actions) {
          if (action['removedVideoId'] == trackId) {
            setVideoId = action['setVideoId'] as String?;
            break;
          }
        }
        if (setVideoId != null) {
          break;
        }
      }
      if (setVideoId != null) {
        break;
      }
    }
    if (setVideoId == null) {
      throw StateError('Could not find $trackId in playlist $playlistId.');
    }
    final editResponse = await ytmusicapi.playlists.removePlaylistItemsRaw(
      _playlistId(playlistId),
      [
        {
          'action': 'ACTION_REMOVE_VIDEO',
          'removedVideoId': trackId,
          'setVideoId': setVideoId,
        },
      ],
    );
    _checkEditResponse(editResponse);
  }
}
