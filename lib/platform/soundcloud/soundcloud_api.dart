import 'dart:convert';
import 'dart:io';

import '../../api/definitions.dart';
import '../music_platform.dart';
import '../../utils/logging.dart';
import 'soundcloud_client.dart';
import 'soundcloud_mobile_client.dart';
import 'soundcloud_web_follow.dart';

typedef SoundCloudBrowserChallenge =
    Future<void> Function(
      Uri pageUrl,
      String instruction,
      Future<bool> Function() verify,
    );

class SoundCloudApi {
  SoundCloudApi({
    SoundCloudInternalClient? client,
    this.browserFollow,
    this.browserChallenge,
  }) : client = client ?? SoundCloudMobileClient();

  final SoundCloudInternalClient client;
  final Future<void> Function(String, String, bool)? browserFollow;
  final SoundCloudBrowserChallenge? browserChallenge;
  late final SoundCloudWebFollow _webFollow = SoundCloudWebFollow(client);
  final Map<String, String> _permalinks = {};
  final Set<String> _knownDrmOnlyTrackIds = {};
  String? _userId;
  Set<String>? _followedArtistIds;

  String? get userId => _userId;

  void markDrmOnly(String trackId) {
    if (trackId.isNotEmpty) _knownDrmOnlyTrackIds.add(trackId);
  }

  Future<void> closeBrowserFollow() => _webFollow.close();

  set userId(String? value) {
    if (_userId != value) _followedArtistIds = null;
    _userId = value;
    client.currentUserId = value;
  }

  static String? upscaleArtworkUrl(String? url) {
    if (url == null) return null;
    return url.replaceFirst('-large.', '-t500x500.');
  }

  ImageDetails? _image(String? url) {
    if (url == null || url.trim().isEmpty) return null;
    var thumb = url.trim();
    if (thumb.contains('/labs-') && thumb.contains('-large.')) {
      thumb = thumb.replaceFirst('-large.', '-t500x500.');
    }
    return ImageDetails(
      thumbUrl: thumb,
      fullUrl: upscaleArtworkUrl(thumb) ?? thumb,
    );
  }

  static bool isEncryptedTranscoding(Map entry) {
    if (entry['drm'] == true || entry['encrypted'] == true) return true;
    final protocol =
        (entry['format'] is Map
                ? entry['format']['protocol']?.toString()
                : null)
            ?.toLowerCase() ??
        '';
    final url =
        (entry['url'] ?? entry['stream_url'])?.toString().toLowerCase() ?? '';
    return protocol.contains('encrypted') ||
        protocol.contains('drm') ||
        url.contains('encrypted-hls') ||
        url.contains('encrypted-dash') ||
        url.contains('ctr-encrypted');
  }

  static bool isFullClearTranscoding(Map entry) {
    final url = (entry['url'] ?? entry['stream_url'])?.toString().trim();
    return entry['snipped'] != true &&
        url != null &&
        url.isNotEmpty &&
        !isEncryptedTranscoding(entry);
  }

  static bool isDrmOnlyTranscodingList(Iterable<Map> entries) {
    var hasEncrypted = false;
    var hasFullClear = false;
    final transcodings = entries.toList();
    for (final entry in transcodings) {
      if (isEncryptedTranscoding(entry) && entry['snipped'] != true) {
        hasEncrypted = true;
      }
    }
    for (final entry in transcodings) {
      if (isFullClearTranscoding(entry) &&
          (!hasEncrypted || entry['is_legacy_transcoding'] != true)) {
        hasFullClear = true;
        break;
      }
    }
    return hasEncrypted && !hasFullClear;
  }

  static bool _hasSubscriberTier(Map source, Map? authorization) {
    final model =
        (source['monetizationModel'] ??
                source['monetization_model'] ??
                authorization?['monetizationModel'] ??
                authorization?['monetization_model'])
            ?.toString()
            .toUpperCase();
    return source['subMidTier'] == true ||
        source['sub_mid_tier'] == true ||
        source['subHighTier'] == true ||
        source['sub_high_tier'] == true ||
        authorization?['subMidTier'] == true ||
        authorization?['sub_mid_tier'] == true ||
        authorization?['subHighTier'] == true ||
        authorization?['sub_high_tier'] == true ||
        model == 'SUB_MID_TIER' ||
        model == 'SUB_HIGH_TIER';
  }

  void _remember(String type, Object id, String url) {
    _permalinks['$type:$id'] = url;
  }

  String? permalinkFor(String type, String id) => _permalinks['$type:$id'];

  Future<Uri> _pageUrl(String type, String id) async {
    var url = permalinkFor(type, id);
    if (url == null || url.isEmpty) {
      final path = type == 'track'
          ? '/tracks/$id'
          : type == 'artist'
          ? '/users/$id'
          : id.startsWith('soundcloud:system-playlists:')
          ? '/system-playlists/$id'
          : '/playlists/$id';
      final source = await client.get(path);
      if (source is Map) url = source['permalink_url'] as String?;
    }
    final uri = Uri.tryParse(url ?? '');
    if (uri == null ||
        uri.scheme != 'https' ||
        !{'soundcloud.com', 'm.soundcloud.com'}.contains(uri.host)) {
      throw const SoundCloudChallengeException();
    }
    return uri;
  }

  Future<void> _completeBrowserChallenge(
    Uri pageUrl,
    String instruction,
    Future<bool> Function() verify,
  ) async {
    if (browserChallenge != null) {
      await browserChallenge!(pageUrl, instruction, verify);
    }
  }

  Artist artistFromUser(
    Map<String, dynamic> user, {
    List<Album> albums = const [],
    List<Track> topTracks = const [],
    List<Playlist> playlists = const [],
    List<Artist> similarArtists = const [],
    bool radio = true,
  }) {
    final rawId =
        user['id'] ??
        (user['urn'] is String
            ? (user['urn'] as String).split(':').last
            : null);
    final idInt = rawId is int ? rawId : int.tryParse(rawId?.toString() ?? '');
    if (idInt != null) {
      _remember('artist', idInt, user['permalink_url'] as String? ?? '');
    }
    final artist = Artist(
      id: rawId?.toString() ?? 'unknown',
      name: user['username'] as String? ?? user['name'] as String? ?? 'Unknown',
      picture: _image(
        (user['avatar_url'] ??
                user['avatarUrl'] ??
                (user['avatar_url_template'] != null
                    ? SoundCloudMobileClient.formatArtworkUrl(
                        user['avatar_url_template'].toString(),
                      )
                    : null))
            as String?,
      ),
      fans: (user['followers_count'] ?? user['followersCount']) as int? ?? 0,
      albums: albums,
      albumCount: albums.length,
      topTracks: topTracks,
      description: user['description'] as String?,
      library: _followedArtistIds?.contains(rawId?.toString()) ?? false,
      radio: radio,
      platformId: 'soundcloud',
    );
    artist.playlists = playlists;
    artist.similarArtists = similarArtists;
    return artist;
  }

  Track trackFromSoundCloud(
    Map<String, dynamic> source, {
    Album? album,
    int? trackNumber,
    bool? supportsDrm,
  }) {
    final rawId =
        source['id']?.toString() ??
        (source['urn'] is String
            ? (source['urn'] as String).split(':').last
            : '');
    if (rawId.isNotEmpty) {
      _remember('track', rawId, source['permalink_url'] as String? ?? '');
    }
    final uploaderArtist = artistFromUser(
      source['user'] as Map<String, dynamic>? ?? {},
    );
    final publisherMeta =
        (source['publisher_metadata'] ?? source['publisherMetadata']) as Map?;
    final publisherArtist = publisherMeta?['artist']?.toString().trim();
    final hasActualArtist =
        publisherArtist != null &&
        publisherArtist.isNotEmpty &&
        publisherArtist != '-' &&
        publisherArtist.toLowerCase() != 'unknown';
    final displayedArtist = hasActualArtist
        ? Artist(
            id: uploaderArtist.id,
            name: publisherArtist,
            picture: uploaderArtist.picture,
            platformId: 'soundcloud',
          )
        : uploaderArtist;
    final art = _image(
      source['artwork_url'] as String? ??
          (source['user'] != null
              ? source['user']['avatar_url'] as String?
              : null),
    );
    final media = source['media'] as Map<String, dynamic>?;
    final transcodings =
        (media?['transcodings'] as List<dynamic>?) ??
        (source['transcodings'] as List<dynamic>?);
    final transcodingList = transcodings?.whereType<Map>().toList() ?? [];

    // Authorization is playback access metadata. Publisher metadata contains
    // creator supplied fields and must not be treated as an authorization
    // object when the former is absent.
    final auth = source['authorization'] as Map?;
    final policy =
        (source['policy'] ??
                source['track_authorization_policy'] ??
                auth?['policy'])
        ?.toString()
        .toUpperCase();
    final isBlocked =
        source['blocked'] == true ||
        auth?['blocked'] == true ||
        auth?['policy']?.toString().toUpperCase() == 'BLOCK' ||
        policy == 'BLOCK' ||
        source['access']?.toString().toLowerCase() == 'blocked';

    // Search and feed responses can omit all media data for monetized tracks.
    // The iSpy response, for example, only provides MONETIZE/AD_SUPPORTED and
    // resolves to a protected HLS route. Use monetization as a fallback signal
    // only when SoundCloud provides no clear progressive transcode.
    final hasEncryptedStream = transcodingList.any(isEncryptedTranscoding);
    final hasFullClearStream = transcodingList.any(
      (entry) =>
          isFullClearTranscoding(entry) &&
          (!hasEncryptedStream || entry['is_legacy_transcoding'] != true),
    );
    final monetizationModel =
        (source['monetization_model'] ??
                source['monetizationModel'] ??
                auth?['monetizationModel'] ??
                auth?['monetization_model'])
            ?.toString()
            .toUpperCase();
    final hasSubscriberTier = _hasSubscriberTier(source, auth);
    final hasFullLengthTranscoding = transcodingList.any(
      (entry) =>
          entry['snipped'] != true &&
          (entry['url'] ?? entry['stream_url'])?.toString().trim().isNotEmpty ==
              true,
    );
    final snipDuration = num.tryParse(
      (source['snip_duration'] ?? source['snipDuration'] ?? '').toString(),
    );
    final trackDuration = num.tryParse(
      (source['duration'] ?? '').toString(),
    );
    final fullDuration = num.tryParse(
      (source['full_duration'] ?? source['fullDuration'] ?? '').toString(),
    );
    final hasShortPreviewDuration =
        trackDuration != null &&
        trackDuration > 0 &&
        trackDuration <= 31000;
    final hasPreviewOnlyDuration =
        auth?['snipped'] == true ||
        source['snipped'] == true ||
        hasShortPreviewDuration ||
        (snipDuration != null && snipDuration > 0) ||
        (trackDuration != null &&
            fullDuration != null &&
            trackDuration > 0 &&
            fullDuration > trackDuration) ||
        (transcodingList.isNotEmpty &&
            transcodingList.every((entry) => entry['snipped'] == true));
    final access = source['access']?.toString().toLowerCase();
    // SoundCloud marks tracks that are only available as a preview to this
    // account with authorization.snipped. Their preview transcode can still
    // look like a normal, playable stream and report a 30 second duration, so
    // it must take precedence over the presence of a clear transcode URL.
    final isSubscriberPreviewOnly =
        access == 'preview' ||
        auth?['snipped'] == true ||
        source['snipped'] == true ||
        (hasSubscriberTier &&
            (hasShortPreviewDuration ||
                (!hasFullLengthTranscoding && hasPreviewOnlyDuration)));
    final hasClearProgressiveStream = transcodingList.any((entry) {
      final protocol = (entry['format'] as Map?)?['protocol']
          ?.toString()
          .toLowerCase();
      return isFullClearTranscoding(entry) && protocol == 'progressive';
    });
    final monetizedWithoutClearStream =
        (policy == 'MONETIZE' ||
            monetizationModel == 'AD_SUPPORTED' ||
            auth?['monetizable'] == true) &&
        !hasClearProgressiveStream;
    final isDrmOnly =
        _knownDrmOnlyTrackIds.contains(rawId) ||
        isDrmOnlyTranscodingList(transcodingList) ||
        (hasSubscriberTier && !hasFullClearStream) ||
        monetizedWithoutClearStream;

    final effectiveSupportsDrm = supportsDrm ?? Platform.isAndroid;
    final isDrmUnavailable =
        isSubscriberPreviewOnly || (!effectiveSupportsDrm && isDrmOnly);
    final isUnavailable = isBlocked || isDrmUnavailable;
    final unavailableReason = isDrmUnavailable
        ? 'drm'
        : (isBlocked ? 'blocked' : null);

    return Track(
      id: rawId,
      title: source['title'] as String? ?? 'Unknown Track',
      duration: Duration(
        milliseconds: (source['duration'] as num?)?.round() ?? 0,
      ),
      album: album,
      albumArt: art,
      artists: [displayedArtist],
      displayArtistName: hasActualArtist ? publisherArtist : null,
      navigableArtists: [uploaderArtist],
      trackNumber: trackNumber,
      diskNumber: 1,
      favorite: source['user_favorite'] == true,
      unavailable: isUnavailable,
      unavailableReason: unavailableReason,
      explicit: false,
      addedDate: DateTime.tryParse(
        (source['created_at']?.toString() ?? '').replaceAll('/', '-'),
      )?.millisecondsSinceEpoch,
      playbackDetails: [
        source['permalink_url'] as String? ?? '',
        source['genre'] as String? ?? '',
        source['label_name'] as String? ?? '',
        policy ??
            (monetizationModel == 'AD_SUPPORTED' ||
                    auth?['monetizable'] == true
                ? 'MONETIZE'
                : ''),
        source['duration'] == source['full_duration'],
        if (transcodings != null) jsonEncode(transcodings),
        if (isSubscriberPreviewOnly) 'subscriber_preview',
      ],
      platformId: 'soundcloud',
    );
  }

  Playlist playlistFromSoundCloud(
    Map<String, dynamic> source, {
    List<Track>? tracks,
    int? resolvedDurationMs,
  }) {
    _remember(
      'playlist',
      source['id'] as Object,
      source['permalink_url'] as String? ?? '',
    );
    final rawArtwork =
        (source['artwork_url'] as String? ?? '').trim().isNotEmpty
        ? (source['artwork_url'] as String).trim()
        : (source['calculated_artwork_url'] as String? ?? '').trim().isNotEmpty
        ? (source['calculated_artwork_url'] as String).trim()
        : (source['artwork_url_template'] != null
                  ? SoundCloudMobileClient.formatArtworkUrl(
                      source['artwork_url_template'].toString(),
                    )
                  : null) ??
              (source['artworkUrlTemplate'] != null
                  ? SoundCloudMobileClient.formatArtworkUrl(
                      source['artworkUrlTemplate'].toString(),
                    )
                  : null) ??
              (source['playlistArtworkUrlTemplate'] != null
                  ? SoundCloudMobileClient.formatArtworkUrl(
                      source['playlistArtworkUrlTemplate'].toString(),
                    )
                  : null);
    final image = _image(rawArtwork);
    final userMap = source['user'] as Map<String, dynamic>? ?? {};
    final trackCount =
        (source['track_count'] as num?)?.toInt() ??
        (source['tracks'] is List ? (source['tracks'] as List).length : null) ??
        tracks?.length ??
        0;
    final sourceDurationMs = (source['duration'] as num?)?.toInt();
    var durationMs = sourceDurationMs != null && sourceDurationMs > 0
        ? sourceDurationMs
        : resolvedDurationMs;
    if (durationMs == null && source['tracks'] is List) {
      final sourceTracks = source['tracks'] as List;
      if (sourceTracks.length == trackCount &&
          sourceTracks.every(
            (track) => track is Map && _fullTrackDurationMs(track) != null,
          )) {
        durationMs = sourceTracks.fold<int>(
          0,
          (total, track) => total + _fullTrackDurationMs(track as Map)!,
        );
      }
    }

    return Playlist(
      id: source['id'].toString(),
      title: source['title'] as String? ?? 'Unknown Playlist',
      tracks: tracks,
      image:
          image ?? (tracks?.isNotEmpty == true ? tracks!.first.albumArt : null),
      duration: durationMs == null ? null : Duration(milliseconds: durationMs),
      trackCount: trackCount,
      user: User(
        id: userMap['id']?.toString() ?? 'unknown',
        name: userMap['username'] as String? ?? 'Unknown',
        picture: _image(userMap['avatar_url'] as String?),
      ),
      fans: source['likes_count'] as int? ?? 0,
      library: source['user_favorite'] == true,
      editable: source['editable'] == true,
      description: source['description'] as String?,
      mosaicImages: image == null
          ? tracks
                ?.map((track) => track.albumArt?.thumb)
                .whereType<String>()
                .take(4)
                .toList()
          : null,
      platformId: 'soundcloud',
    );
  }

  int? _fullTrackDurationMs(Map source) =>
      (source['full_duration'] as num?)?.toInt() ??
      (source['duration'] as num?)?.toInt();

  Album albumFromSoundCloud(
    Map<String, dynamic> source, {
    List<Track>? tracks,
  }) {
    final idInt = source['id'] is int
        ? source['id'] as int
        : int.tryParse(source['id']?.toString() ?? '');
    if (idInt != null) {
      _remember('album', idInt, source['permalink_url'] as String? ?? '');
    }
    final userMap =
        (source['user'] as Map<String, dynamic>?) ??
        (source['user_urn'] != null
            ? {
                'id': source['user_urn'].toString().split(':').last,
                'username': source['user_tag'] ?? 'SoundCloud',
              }
            : <String, dynamic>{});
    final artist = artistFromUser(userMap);
    final image =
        _image(source['artwork_url'] as String?) ??
        (tracks?.isNotEmpty == true ? tracks!.first.albumArt : null);

    final summary = Album(
      id: source['id'].toString(),
      title: source['title'] as String? ?? 'Unknown Album',
      art: image,
      artists: [artist],
      fans: source['likes_count'] as int? ?? 0,
      type: AlbumType.ALBUM,
      releaseDate: source['created_at'] as String?,
      platformId: 'soundcloud',
    );
    if (tracks != null) {
      for (var index = 0; index < tracks.length; index++) {
        tracks[index].trackNumber = index + 1;
        tracks[index].album = summary;
      }
    }
    return Album(
      id: summary.id,
      title: summary.title,
      art: summary.art,
      artists: summary.artists,
      tracks: tracks,
      fans: summary.fans,
      type: summary.type,
      releaseDate: summary.releaseDate,
      library: false,
      platformId: 'soundcloud',
    );
  }

  Future<SearchResults> search(
    String query, {
    int limit = 25,
    int offset = 0,
  }) async {
    await _loadFollowedArtistIds();
    final resp = await client.get(
      '/search',
      queryParameters: {'q': query, 'limit': limit * 3, 'offset': offset},
    );
    final items = resp['collection'] as List<dynamic>? ?? [];

    final trackResults = <Map<String, dynamic>>[];
    final playlistResults = <Map<String, dynamic>>[];
    final userResults = <Map<String, dynamic>>[];

    final seenTrackKeys = <String>{};
    final seenPlaylistKeys = <String>{};
    final seenUserKeys = <String>{};

    for (final item in items) {
      if (item is! Map<String, dynamic>) continue;
      final kind = item['kind'] as String?;
      final key = (item['id'] ?? item['urn'])?.toString() ?? '';
      if (kind == 'track') {
        if (key.isNotEmpty && !seenTrackKeys.add(key)) continue;
        trackResults.add(item);
      }
      if (kind == 'playlist') {
        if (key.isNotEmpty && !seenPlaylistKeys.add(key)) continue;
        playlistResults.add(item);
      }
      if (kind == 'user') {
        if (key.isNotEmpty && !seenUserKeys.add(key)) continue;
        userResults.add(item);
      }
    }

    return SearchResults(
      tracks: trackResults.map(trackFromSoundCloud).toList(),
      albums: playlistResults
          .where((result) => result['is_album'] == true)
          .map((a) => albumFromSoundCloud(a))
          .toList(),
      artists: userResults.map((u) => artistFromUser(u)).toList(),
      playlists: playlistResults
          .where((result) => result['is_album'] != true)
          .map((p) => playlistFromSoundCloud(p))
          .toList(),
    );
  }

  Future<List<String>> searchSuggestions(String query) async {
    final resp = await client.get(
      '/search/queries',
      queryParameters: {'q': query},
    );
    final collection = resp['collection'] as List<dynamic>? ?? [];
    return collection.map((e) => e['query'] as String).toList();
  }

  Future<Track> getTrack(String id) async {
    final resp = await client.get('/tracks/$id');
    return trackFromSoundCloud(resp);
  }

  Future<List<Track>> getTracks(
    List<String> ids, {
    void Function(Map<String, dynamic>)? onSource,
  }) async {
    if (ids.isEmpty) return [];
    final resp = await client.get(
      '/tracks',
      queryParameters: {'ids': ids.join(',')},
    );

    // SoundCloud can wrap bulk results or return an array directly.
    final items = resp is Map<String, dynamic>
        ? resp['collection'] as List<dynamic>? ?? []
        : resp is List
        ? resp
        : <dynamic>[];
    return items.map((item) {
      final source = item as Map<String, dynamic>;
      onSource?.call(source);
      return trackFromSoundCloud(source);
    }).toList();
  }

  Future<List<Track>> _resolveTracks(
    List<dynamic> trackList, {
    int? limit,
    void Function(Map<String, dynamic>)? onSource,
  }) async {
    final toResolve = <String>[];
    final count = limit ?? trackList.length;
    final items = trackList.take(count).toList();

    for (final rawItem in items) {
      if (rawItem is! Map) continue;
      final item = Map<String, dynamic>.from(rawItem);
      final id =
          item['id']?.toString() ??
          (item['urn'] is String
              ? (item['urn'] as String).split(':').last
              : null);
      final hasMedia =
          (item['media'] is Map &&
              (item['media'] as Map)['transcodings'] is List &&
              ((item['media'] as Map)['transcodings'] as List).isNotEmpty) ||
          (item['transcodings'] is List &&
              (item['transcodings'] as List).isNotEmpty);
      if ((item['title'] == null || !hasMedia) && id != null) {
        toResolve.add(id);
      }
    }

    final resolvedMap = <String, Track>{};
    if (toResolve.isNotEmpty) {
      for (var i = 0; i < toResolve.length; i += 50) {
        final chunk = toResolve.skip(i).take(50).toList();
        try {
          final resolved = await getTracks(chunk, onSource: onSource);
          for (final t in resolved) {
            if (t.id != null) resolvedMap[t.id!] = t;
          }
        } catch (e) {
          appLogger.warning('Failed to resolve SoundCloud track chunk', e);
        }
      }
    }

    final result = <Track>[];
    for (final rawItem in items) {
      if (rawItem is! Map) continue;
      final item = Map<String, dynamic>.from(rawItem);
      final id =
          item['id']?.toString() ??
          (item['urn'] is String
              ? (item['urn'] as String).split(':').last
              : null);
      if (id != null && resolvedMap.containsKey(id)) {
        result.add(resolvedMap[id]!);
      } else if (item['title'] != null || id != null) {
        onSource?.call(item);
        result.add(trackFromSoundCloud(item));
      }
    }

    return result;
  }

  Future<Album> getAlbum(String id) async {
    final source = await client.get('/playlists/$id');
    final tracksList = source['tracks'] as List<dynamic>? ?? [];
    final tracks = await _resolveTracks(tracksList);
    return albumFromSoundCloud(source, tracks: tracks);
  }

  Future<Playlist> getPlaylist(String id, {int? limit}) async {
    final source = await client.get(
      id.startsWith('soundcloud:system-playlists:')
          ? '/system-playlists/$id'
          : '/playlists/$id',
    );
    final tracksList = source['tracks'] as List<dynamic>? ?? [];
    final trackDurations = <String, int>{};
    final tracks = await _resolveTracks(
      tracksList,
      limit: limit,
      onSource: (track) {
        final trackId = track['id']?.toString();
        final duration = _fullTrackDurationMs(track);
        if (trackId != null && duration != null) {
          trackDurations[trackId] = duration;
        }
      },
    );
    final trackCount =
        (source['track_count'] as num?)?.toInt() ?? tracksList.length;
    final hasFullDuration =
        tracks.length == trackCount &&
        tracks.every((track) => trackDurations.containsKey(track.id));
    final resolvedDurationMs = hasFullDuration
        ? tracks.fold<int>(
            0,
            (total, track) => total + trackDurations[track.id]!,
          )
        : null;
    return playlistFromSoundCloud(
      source,
      tracks: tracks,
      resolvedDurationMs: resolvedDurationMs,
    );
  }

  Future<List<Track>> getArtistTopTracks(
    String artistId, {
    int limit = 50,
  }) async {
    final cleanId = artistId.startsWith('soundcloud:')
        ? artistId.split(':').last
        : artistId;
    try {
      final resp = await client.get(
        '/users/$cleanId/top_tracks',
        queryParameters: {'limit': limit},
      );
      final tracks = _tracks(_collection(resp));
      if (tracks.isNotEmpty) return tracks;
    } catch (_) {}
    try {
      final resp = await client.get(
        '/users/$cleanId/toptracks',
        queryParameters: {'limit': limit},
      );
      final tracks = _tracks(_collection(resp));
      if (tracks.isNotEmpty) return tracks;
    } catch (_) {}
    final tracksList = await _page('/users/$cleanId/tracks', limit: limit);
    return _tracks(_collection(tracksList));
  }

  Future<List<Playlist>> getArtistPlaylists(
    String artistId, {
    int offset = 0,
    int limit = 50,
  }) async {
    try {
      final cleanId = artistId.startsWith('soundcloud:')
          ? artistId.split(':').last
          : artistId;
      final resp = await client.get(
        '/users/$cleanId/playlists',
        queryParameters: {'limit': limit, 'offset': offset},
      );
      final items = resp is Map
          ? (resp['collection'] as List<dynamic>? ?? <dynamic>[])
          : (resp is List ? resp : <dynamic>[]);
      return items
          .whereType<Map<String, dynamic>>()
          .where((p) => p['id'] != null || p['urn'] != null)
          .map((p) => playlistFromSoundCloud(p))
          .toList();
    } catch (e) {
      appLogger.warning('Failed to fetch artist playlists for $artistId: $e');
      return [];
    }
  }

  Future<List<Artist>> getSimilarArtists(
    String artistId, {
    int limit = 20,
  }) async {
    try {
      final cleanId = artistId.startsWith('soundcloud:')
          ? artistId.split(':').last
          : artistId;
      final resp = await client.get(
        '/related-artists/soundcloud:users:$cleanId',
        queryParameters: {'limit': limit},
      );
      final items = resp is Map
          ? (resp['collection'] as List<dynamic>? ?? <dynamic>[])
          : (resp is List ? resp : <dynamic>[]);
      return items
          .whereType<Map<String, dynamic>>()
          .map((u) => artistFromUser(u))
          .toList();
    } catch (e) {
      appLogger.warning('Failed to fetch similar artists for $artistId: $e');
      return [];
    }
  }

  Future<Artist> getArtist(String id) async {
    await _loadFollowedArtistIds();
    final cleanId = id.startsWith('soundcloud:') ? id.split(':').last : id;
    final user = await client.get('/users/$cleanId') as Map<String, dynamic>;

    final results = await Future.wait([
      getArtistTopTracks(cleanId).catchError((e) {
        appLogger.warning('Failed to fetch top tracks for $cleanId: $e');
        return <Track>[];
      }),
      _all('/users/$cleanId/albums').catchError((_) => <dynamic>[]),
      getArtistPlaylists(cleanId).catchError((e) {
        appLogger.warning('Failed to fetch playlists for $cleanId: $e');
        return <Playlist>[];
      }),
      getSimilarArtists(cleanId).catchError((e) {
        appLogger.warning('Failed to fetch similar artists for $cleanId: $e');
        return <Artist>[];
      }),
    ]);

    final topTracks = results[0] as List<Track>;
    final albumsList = results[1];
    final playlists = results[2] as List<Playlist>;
    final similarArtists = results[3] as List<Artist>;

    final albums = albumsList
        .whereType<Map<String, dynamic>>()
        .where((a) => a['id'] != null)
        .map(albumFromSoundCloud)
        .toList();

    final artist = artistFromUser(
      user,
      topTracks: topTracks,
      albums: albums,
      playlists: playlists,
      similarArtists: similarArtists,
      radio: true,
    );
    artist.pageSectionsLoaded = true;
    return artist;
  }

  Future<List<Album>> getDiscography(
    String artistId, {
    int offset = 0,
    int limit = 50,
  }) async {
    final albumsResp = await client.get(
      '/users/$artistId/albums',
      queryParameters: {'limit': limit, 'offset': offset},
    );
    final albumsList = albumsResp['collection'] as List<dynamic>? ?? [];
    return albumsList
        .map((a) => albumFromSoundCloud(a as Map<String, dynamic>))
        .toList();
  }

  Future<List<Track>> getPlaylistTracks(
    String id, {
    int offset = 0,
    int limit = 100,
  }) async {
    final cleanId = id.startsWith('soundcloud:')
        ? id
        : (id.startsWith('system-playlists:') ? 'soundcloud:$id' : id);
    final source = await client.get(
      cleanId.contains('system-playlists')
          ? '/system-playlists/$cleanId'
          : '/playlists/$cleanId',
    );
    final tracksList = source['tracks'] as List<dynamic>? ?? [];
    if (offset >= tracksList.length) return [];
    final subset = tracksList.skip(offset).take(limit).toList();
    return await _resolveTracks(subset);
  }

  Future<List<Track>> getCharts({
    String kind = 'trending',
    String genre = 'soundcloud:genres:all-music',
    int limit = 50,
  }) async {
    final response = await client.get(
      '/charts',
      queryParameters: {'kind': kind, 'genre': genre, 'limit': limit},
    );
    final collection = _collection(response);
    final tracks = <Track>[];
    for (final item in collection) {
      if (item is Map && item['track'] is Map) {
        tracks.add(
          trackFromSoundCloud(Map<String, dynamic>.from(item['track'] as Map)),
        );
      }
    }
    return tracks;
  }

  List<dynamic> _collection(dynamic response) {
    if (response is List) return response;
    if (response is Map) {
      final collection = response['collection'];
      if (collection is List) return collection;
    }
    return [];
  }

  Future<dynamic> _page(
    String path, {
    int offset = 0,
    int limit = 50,
    Map<String, dynamic>? queryParameters,
  }) => client.get(
    path,
    queryParameters: {
      'offset': offset,
      'limit': limit,
      'linked_partitioning': 1,
      ...?queryParameters,
    },
  );

  Future<List<dynamic>> _all(String path) async {
    final items = <dynamic>[];
    dynamic response = await _page(path, limit: 100);
    for (var page = 0; page < 100; page++) {
      items.addAll(_collection(response));
      final next = response is Map ? response['next_href'] as String? : null;
      if (next == null || next.isEmpty) break;
      response = await client.getNext(next);
    }
    return items;
  }

  Map<String, dynamic>? _resource(dynamic item, String key) {
    if (item is! Map) return null;
    final itemMap = Map<String, dynamic>.from(item);
    final nested = itemMap[key];
    if (nested is Map) return Map<String, dynamic>.from(nested);
    if (itemMap['type'] == key && itemMap['origin'] is Map) {
      return Map<String, dynamic>.from(itemMap['origin'] as Map);
    }
    return itemMap['id'] != null ? itemMap : null;
  }

  List<Track> _tracks(
    List<dynamic> items, {
    String key = 'track',
    bool liked = false,
  }) => items
      .map((item) {
        final res = _resource(item, key);
        if (res != null && item is Map && item['created_at'] != null) {
          // Likes/reposts wrap the track; the wrapper timestamp is when it was
          // added, the track's own created_at is its upload date.
          if (liked || res['created_at'] == null) {
            res['created_at'] = item['created_at'];
          }
        }
        return res;
      })
      .whereType<Map<String, dynamic>>()
      .where((track) => track['id'] != null && track['permalink_url'] != null)
      .map(
        (track) => trackFromSoundCloud(
          liked ? {...track, 'user_favorite': true} : track,
        ),
      )
      .toList();

  Future<PaginatedTrackList> getLikedTracks({
    required String userId,
    int start = 0,
    int limit = 100,
  }) async {
    if (client is SoundCloudMobileClient) {
      final response = await _page(
        '/users/$userId/track_likes',
        offset: start,
        limit: limit,
      );
      final next = response is Map ? response['next_href'] as String? : null;
      return PaginatedTrackList(
        tracks: _tracks(_collection(response), liked: true),
        hasMore: next != null && next.isNotEmpty,
      );
    }
    // SoundCloud's next_href uses an opaque timestamp cursor rather than a
    // numeric offset. Follow it until we have enough visible tracks.
    final items = <dynamic>[];
    dynamic response = await _page('/users/$userId/track_likes', limit: limit);
    String? next;
    for (var page = 0; page < 100; page++) {
      items.addAll(_collection(response));
      next = response is Map ? response['next_href'] as String? : null;
      if (next == null ||
          next.isEmpty ||
          _tracks(items, liked: true).length >= start + limit) {
        break;
      }
      response = await client.getNext(next);
    }
    final allTracks = _tracks(items, liked: true);
    return PaginatedTrackList(
      tracks: allTracks.skip(start).take(limit).toList(),
      hasMore:
          allTracks.length > start + limit || (next != null && next.isNotEmpty),
    );
  }

  Future<List<String>> getLikedTrackIds() async {
    final items = await _all('/me/track_likes/ids');
    return items.map((item) => item.toString()).toList();
  }

  Future<List<Track>> getAllLikedTracks(String userId, {int max = 500}) async {
    final items = <dynamic>[];
    try {
      dynamic response = await _page('/users/$userId/track_likes', limit: 50);
      for (var page = 0; page < (max / 50).ceil(); page++) {
        final col = _collection(response);
        if (col.isEmpty) break;
        items.addAll(col);
        final next = response is Map ? response['next_href'] as String? : null;
        if (next == null || next.isEmpty || items.length >= max) break;
        response = await client.getNext(next);
      }
    } catch (error, stackTrace) {
      appLogger.warning('Failed to fetch liked tracks', error, stackTrace);
    }
    return _tracks(items, liked: true);
  }

  Future<List<String>> getLikedPlaylistIds() async {
    final items = await _all('/me/playlist_likes/ids');
    return items.map((item) => item.toString()).toList();
  }

  Future<List<String>> getLikedSystemPlaylistUrns() async {
    final items = await _all('/me/system_playlist_likes/urns');
    return items.map((item) => item.toString()).toList();
  }

  Future<List<dynamic>> _libraryPlaylistItems(String userId) async {
    try {
      return await _all('/users/$userId/playlists/liked_and_owned');
    } catch (_) {
      return [
        ...await _all('/users/$userId/playlists'),
        ...await _all('/users/$userId/playlist_likes'),
      ];
    }
  }

  Future<List<Playlist>> getLibraryPlaylists(String userId) async {
    final items = await _libraryPlaylistItems(userId);
    try {
      items.addAll(await _all('/me/library/stations'));
    } catch (_) {
      // Older accounts may not expose the stations library endpoint.
    }
    final seen = <String>{};
    final result = <Playlist>[];
    for (final item in items) {
      final source = _resource(item, 'playlist');
      if (source == null ||
          source['id'] == null ||
          source['is_album'] == true ||
          source['set_type'] == 'album' ||
          source['set_type'] == 'ep' ||
          !seen.add(source['id'].toString())) {
        continue;
      }
      source['permalink_url'] ??= 'https://soundcloud.com';
      final owner = source['user'] as Map<String, dynamic>?;
      final ownerId =
          owner?['id']?.toString() ??
          source['user_urn']?.toString().split(':').last;
      final playlist = playlistFromSoundCloud(source)
        ..library = true
        ..editable = ownerId == userId;
      result.add(playlist);
    }
    try {
      for (final urn in await getLikedSystemPlaylistUrns()) {
        if (!seen.add(urn)) continue;
        try {
          final station = await getPlaylist(urn);
          station.library = true;
          result.add(station);
        } catch (_) {
          // A station can disappear while still present in the likes list.
        }
      }
    } catch (_) {}
    return result;
  }

  Future<List<Album>> getLibraryAlbums(String userId) async {
    final items = await _libraryPlaylistItems(userId);
    try {
      items.addAll(await _all('/users/$userId/albums'));
    } catch (error) {
      appLogger.warning(
        'Could not load SoundCloud albums posted by user',
        error,
      );
    }
    final seen = <String>{};
    final albums = items
        .map((item) => _resource(item, 'playlist'))
        .whereType<Map<String, dynamic>>()
        .where(
          (item) =>
              item['id'] != null &&
              (item['is_album'] == true ||
                  item['set_type'] == 'album' ||
                  item['set_type'] == 'ep'),
        )
        .where((item) => seen.add(item['id'].toString()))
        .map(albumFromSoundCloud)
        .toList();
    for (final album in albums) {
      album.library = true;
    }
    return albums;
  }

  Future<List<Artist>> getFollowedArtists(String userId) async {
    final items = await _all('/users/$userId/followings');
    final artists = items
        .map((item) => _resource(item, 'user'))
        .whereType<Map<String, dynamic>>()
        .where((user) => user['id'] != null)
        .map(artistFromUser)
        .toList();
    for (final artist in artists) {
      artist.library = true;
    }
    _followedArtistIds = artists
        .map((artist) => artist.id)
        .whereType<String>()
        .toSet();
    return artists;
  }

  Future<Set<String>> getFollowedArtistIds(String userId) async {
    final items = await _all('/users/$userId/followings/ids');
    final ids = items.map((item) => item.toString()).toSet();
    _followedArtistIds = ids;
    return ids;
  }

  Future<void> _loadFollowedArtistIds() async {
    if (userId == null || _followedArtistIds != null) return;
    try {
      await getFollowedArtistIds(userId!);
    } catch (_) {
      // Profiles and search still work if the follow list is unavailable.
    }
  }

  Future<List<Track>> getFeedTracks({int limit = 50}) async {
    final response = await _page('/stream', limit: limit);
    return _tracks(_collection(response));
  }

  Future<({List<Track> tracks, String? nextCursor})> getFeedTracksPage({
    String? cursor,
    int limit = 50,
  }) async {
    dynamic response;
    if (cursor != null && cursor.isNotEmpty) {
      response = await client.getNext(cursor);
    } else {
      response = await _page('/stream', limit: limit);
    }
    final tracks = _tracks(_collection(response));
    final next = response is Map
        ? (response['next_href'] ?? response['next'])?.toString()
        : null;
    return (tracks: tracks, nextCursor: next);
  }

  Future<List<HomePageItem?>> getFeedItems({int limit = 30}) async {
    final response = await _page('/stream', limit: limit);
    final result = <HomePageItem?>[];
    for (final item in _collection(response)) {
      final track = _resource(item, 'track');
      if (track != null &&
          track['id'] != null &&
          track['permalink_url'] != null &&
          item is Map &&
          (item['track'] != null || item['type'] == 'track')) {
        result.add(
          HomePageItem(
            type: HomePageItemType.TRACK,
            value: trackFromSoundCloud(track),
          ),
        );
        continue;
      }
      final playlist = _resource(item, 'playlist');
      if (playlist == null ||
          playlist['id'] == null ||
          playlist['permalink_url'] == null ||
          item is! Map ||
          (item['playlist'] == null && item['type'] != 'playlist')) {
        continue;
      }
      result.add(
        HomePageItem(
          type: playlist['is_album'] == true
              ? HomePageItemType.ALBUM
              : HomePageItemType.PLAYLIST,
          value: playlist['is_album'] == true
              ? albumFromSoundCloud(playlist)
              : playlistFromSoundCloud(playlist),
        ),
      );
    }
    return result;
  }

  Future<List<HomePageItem?>> getRecentlyPlayedItems({int limit = 20}) async {
    if (client is SoundCloudMobileClient) {
      try {
        final res = await client.get(
          '/recently-played/contexts/v2',
          queryParameters: {'limit': limit},
        );
        final section = _selectionSections({
          'collection': [
            {'title': 'Recently played', 'items': res},
          ],
        });
        if (section.isNotEmpty && section.first.items.isNotEmpty) {
          return section.first.items;
        }
      } catch (e) {
        appLogger.warning('Failed to fetch mobile recently played contexts', e);
      }
    }
    final recentTracks = await getRecentTracks(limit: limit);
    return recentTracks
        .map(
          (track) => HomePageItem(type: HomePageItemType.TRACK, value: track),
        )
        .toList();
  }

  Future<List<Track>> getRecentTracks({int limit = 25}) async {
    return (await getHistoryTracks(limit: limit)).tracks;
  }

  Future<HistoryTrackPage> getHistoryTracks({
    String? cursor,
    int limit = 100,
  }) async {
    final response = cursor == null
        ? await _page('/me/play-history/tracks', limit: limit)
        : await client.getNext(cursor);
    final next = response is Map
        ? (response['next_href'] ?? response['next'])?.toString()
        : null;
    final rawTracks = _tracks(_collection(response));
    final seen = <String>{};
    final tracks = rawTracks
        .where((t) => t.id != null && seen.add(t.id!))
        .toList();
    return HistoryTrackPage(
      tracks: tracks,
      nextCursor: next == null || next.isEmpty ? null : next,
    );
  }

  Future<List<HomePageSection>> getMixedSelectionSections({
    bool web = false,
  }) async {
    final response = await _page(
      '/mixed-selections',
      limit: 20,
      queryParameters: web ? {'web': true} : null,
    );
    return _selectionSections(response);
  }

  Future<List<HomePageSection>> getDiscoverSections() async {
    final response = await _page('/discover-feed', limit: 30);
    return _selectionSections(response);
  }

  List<HomePageSection> _selectionSections(dynamic response) {
    final sections = <HomePageSection>[];
    for (final selection in _collection(response)) {
      if (selection is! Map) continue;
      final selectionMap = Map<String, dynamic>.from(selection);
      final title = selectionMap['title'] as String?;
      if (title == null || title.isEmpty) continue;
      final isMixSection =
          title.toLowerCase().startsWith('mixed for') ||
          title.toLowerCase().contains('your mix');
      final items = <HomePageItem?>[];
      final seenItems = <String>{};
      for (final rawItem in _collection(selectionMap['items'])) {
        if (rawItem is! Map) continue;
        final item = Map<String, dynamic>.from(rawItem);
        if (item['id'] == null) continue;
        try {
          if (item['kind'] == 'track') {
            final key = 'track:${item['id']}';
            if (seenItems.contains(key)) continue;
            items.add(
              HomePageItem(
                type: HomePageItemType.TRACK,
                value: trackFromSoundCloud(item),
              ),
            );
            seenItems.add(key);
          } else if (item['kind'] == 'playlist' ||
              item['kind'] == 'system-playlist') {
            final key = 'playlist:${item['id']}';
            if (seenItems.contains(key)) continue;
            final playlist = playlistFromSoundCloud(
              (title == 'More of what you like' ||
                          title.toLowerCase() == 'recently played') &&
                      item['kind'] == 'system-playlist' &&
                      item['short_title'] is String &&
                      (item['short_title'] as String).isNotEmpty
                  ? {...item, 'title': item['short_title']}
                  : item,
            );
            final isMixItem =
                isMixSection ||
                (playlist.title?.toLowerCase().startsWith('your mix') ??
                    false) ||
                item['id'].toString().contains('your-moods') ||
                item['urn']?.toString().contains('your-moods') == true;
            if (isMixItem) {
              items.add(
                HomePageItem(
                  type: HomePageItemType.PLATFORM,
                  platformType: 'smarttracklist',
                  platformId: 'soundcloud',
                  value: SmartTrackList(
                    id: playlist.id,
                    title: '',
                    subtitle: playlist.description ?? playlist.title,
                    description: playlist.description,
                    cover: playlist.image,
                    trackCount: playlist.trackCount,
                    platformId: 'soundcloud',
                  ),
                ),
              );
            } else {
              items.add(
                HomePageItem(type: HomePageItemType.PLAYLIST, value: playlist),
              );
            }
            seenItems.add(key);
          }
        } catch (_) {
          // One malformed recommendation should not hide the other rows.
        }
      }
      final hasOnlyTracks = items.every(
        (i) => i?.type == HomePageItemType.TRACK,
      );
      final isGridRow =
          hasOnlyTracks &&
          (selectionMap['layout'] == 'GRID_ROW' ||
              selectionMap['__typename'] == 'ContentWallSection' ||
              (selectionMap['items_per_column'] is num &&
                  (selectionMap['items_per_column'] as num) > 1) ||
              title.toLowerCase().contains('liked by people you follow'));
      if (items.isNotEmpty) {
        sections.add(
          HomePageSection(
            title: title,
            layout: isGridRow
                ? HomePageSectionLayout.GRID_ROW
                : HomePageSectionLayout.ROW,
            items: items,
          ),
        );
      }
    }
    return sections;
  }

  Future<void> logListen(
    String trackId, {
    String? contextUrn,
    String? playbackContextUrn,
    ListenLogDetails? details,
  }) async {
    if (client.oauthToken == null || client.oauthToken!.isEmpty) return;
    if (client case final SoundCloudMobileClient mobile) {
      final accountId = userId;
      if (accountId == null) return;
      await mobile.logListenNative(
        trackId,
        userId: accountId,
        trackOwnerId: details?.trackOwnerId,
        contextUrn: playbackContextUrn ?? contextUrn,
        recordContext: contextUrn != null,
        startedAt: details?.timestamp,
        listenDuration: details?.listenDuration,
        position: details?.position,
        trackDuration: details?.trackDuration,
        format: details?.format,
        isNext: details?.isNext == true,
      );
      return;
    }
    final body = <String, dynamic>{'track_urn': 'soundcloud:tracks:$trackId'};
    if (contextUrn != null) body['context_urn'] = contextUrn;
    await client.change('POST', '/me/play-history', body: body);
  }

  Future<List<Track>> getRelatedTracks(String trackId, {int limit = 50}) async {
    final cleanId = trackId.startsWith('soundcloud:')
        ? trackId.split(':').last
        : trackId;
    try {
      final stationUrn = 'soundcloud:system-playlists:track-stations:$cleanId';
      final tracks = await getPlaylistTracks(
        stationUrn,
        offset: 0,
        limit: limit,
      );
      if (tracks.isNotEmpty) return tracks;
    } catch (_) {}
    final response = await _page('/tracks/$cleanId/related', limit: limit);
    return _tracks(_collection(response));
  }

  Future<void> likeTrack(
    String userId,
    String trackId, {
    required bool like,
  }) async {
    appLogger.info(
      '[SoundCloudApi] likeTrack: userId=$userId, trackId=$trackId, like=$like, client=${client.runtimeType}',
    );
    try {
      await client.change(
        like ? 'PUT' : 'DELETE',
        '/users/$userId/track_likes/$trackId',
      );
      appLogger.info(
        '[SoundCloudApi] likeTrack completed: trackId=$trackId, like=$like',
      );
    } catch (e, st) {
      appLogger.warning(
        '[SoundCloudApi] likeTrack failed: trackId=$trackId, like=$like: $e',
        e,
        st,
      );
      if (e is SoundCloudChallengeException && browserChallenge != null) {
        await _completeBrowserChallenge(
          await _pageUrl('track', trackId),
          like
              ? 'Like this track on SoundCloud, then tap Done.'
              : 'Unlike this track on SoundCloud, then tap Done.',
          () async => (await getLikedTrackIds()).contains(trackId) == like,
        );
      } else {
        rethrow;
      }
    }
  }

  Future<void> likePlaylist(
    String userId,
    String playlistId, {
    required bool like,
  }) async {
    final system = playlistId.startsWith('soundcloud:system-playlists:');
    appLogger.info(
      '[SoundCloudApi] likePlaylist: userId=$userId, playlistId=$playlistId, system=$system, like=$like, client=${client.runtimeType}',
    );
    try {
      await client.change(
        like ? 'PUT' : 'DELETE',
        system
            ? '/users/$userId/system_playlist_likes/$playlistId'
            : '/users/$userId/playlist_likes/$playlistId',
      );
      appLogger.info(
        '[SoundCloudApi] likePlaylist completed: playlistId=$playlistId, like=$like',
      );
    } catch (e, st) {
      appLogger.warning(
        '[SoundCloudApi] likePlaylist failed: playlistId=$playlistId, like=$like: $e',
        e,
        st,
      );
      if (e is SoundCloudChallengeException && browserChallenge != null) {
        await _completeBrowserChallenge(
          await _pageUrl('playlist', playlistId),
          like
              ? 'Like this playlist on SoundCloud, then tap Done.'
              : 'Unlike this playlist on SoundCloud, then tap Done.',
          () async =>
              (system
                      ? await getLikedSystemPlaylistUrns()
                      : await getLikedPlaylistIds())
                  .contains(playlistId) ==
              like,
        );
      } else {
        rethrow;
      }
    }
  }

  Future<void> followArtist(
    String accountId,
    String artistId, {
    required bool follow,
  }) async {
    appLogger.info(
      '[SoundCloudApi] followArtist: accountId=$accountId, artistId=$artistId, follow=$follow, client=${client.runtimeType}',
    );
    if (client is SoundCloudMobileClient) {
      final targetId = artistId.split(':').last;
      await client.change(
        follow ? 'POST' : 'DELETE',
        '/me/followings/$targetId',
      );
      if (follow) {
        _followedArtistIds?.add(targetId);
      } else {
        _followedArtistIds?.remove(targetId);
      }
      appLogger.info(
        '[SoundCloudApi] followArtist mobile completed: artistId=$targetId, follow=$follow',
      );
      return;
    }
    Future<void> changeFollow({required bool mobile}) async {
      final clientId = mobile
          ? await client.getMobileClientId()
          : await client.getClientId();
      final userAgent = mobile
          ? SoundCloudInternalClient.mobileFollowUserAgent
          : SoundCloudInternalClient.followUserAgent;
      await client.change(
        follow ? 'POST' : 'DELETE',
        '/me/followings/$artistId',
        clientIdOverride: clientId,
        apiHost: mobile ? 'api-mobi.soundcloud.com' : 'api-v2.soundcloud.com',
        queryParameters: follow
            ? {
                'signature': SoundCloudInternalClient.followSignature(
                  accountId,
                  artistId,
                  clientId,
                  userAgent: userAgent,
                ),
              }
            : null,
        headers: mobile
            ? {
                'User-Agent': userAgent,
                'Origin': 'https://m.soundcloud.com',
                'Referer': 'https://m.soundcloud.com/',
              }
            : null,
      );
    }

    try {
      await changeFollow(mobile: false);
    } on SoundCloudChallengeException {
      try {
        if (browserFollow != null) {
          await browserFollow!(accountId, artistId, follow);
        } else {
          await _webFollow.change(
            accountId,
            artistId,
            follow: follow,
            verify: () async =>
                (await getFollowedArtistIds(accountId)).contains(artistId) ==
                follow,
            artistUrl: () async {
              var url = permalinkFor('artist', artistId);
              if (url == null || url.isEmpty) {
                final artist = await client.get('/users/$artistId');
                if (artist is Map) url = artist['permalink_url'] as String?;
              }
              return Uri.parse(url ?? '');
            },
          );
        }
      } on UnsupportedError catch (error) {
        appLogger.warning(
          'SoundCloud browser follow unavailable; trying the mobile API '
          '(${error.runtimeType})',
        );
        await changeFollow(mobile: true);
      }
    }
    if (follow) {
      _followedArtistIds?.add(artistId);
    } else {
      _followedArtistIds?.remove(artistId);
    }
  }

  // The website's api-v2 playlist mutation accepts track IDs directly.
  List<int> _playlistTracks(List<String> ids) => ids.map(int.parse).toList();

  Future<String> createPlaylist(
    String title, {
    String description = '',
    int status = 0,
    List<String> trackIds = const [],
  }) async {
    if (client case final SoundCloudMobileClient mobile) {
      return mobile.createPlaylistNative(
        title,
        isPublic: status == 0,
        description: description,
        trackIds: trackIds,
      );
    }
    final response = await client.change(
      'POST',
      '/playlists',
      body: {
        'playlist': {
          'title': title,
          'description': description,
          'sharing': status == 0 ? 'public' : 'private',
          'tracks': _playlistTracks(trackIds),
        },
      },
    );
    final id = response is Map<String, dynamic> ? response['id'] : null;
    if (id == null) throw const FormatException('No playlist ID in response');
    return id.toString();
  }

  Future<void> updatePlaylist(
    String id,
    String title, {
    String description = '',
    int status = 0,
  }) async {
    final existing = await client.get('/playlists/$id') as Map<String, dynamic>;
    final existingTracks = existing['tracks'] as List<dynamic>? ?? [];
    if (client case final SoundCloudMobileClient mobile) {
      await mobile.updatePlaylistNative(
        id,
        existing,
        existingTracks
            .whereType<Map<String, dynamic>>()
            .map((track) => track['id']?.toString())
            .whereType<String>()
            .toList(),
        title: title,
        description: description,
        isPublic: status == 0,
      );
      return;
    }
    await client.change(
      'PUT',
      '/playlists/$id',
      body: {
        'playlist': {
          'title': title,
          'description': description,
          'sharing': status == 0 ? 'public' : 'private',
          'tracks': existingTracks
              .whereType<Map<String, dynamic>>()
              .map((track) => track['id']?.toString())
              .whereType<String>()
              .map(int.parse)
              .toList(),
        },
      },
    );
  }

  Future<void> deletePlaylist(String id) => client is SoundCloudMobileClient
      ? (client as SoundCloudMobileClient).deletePlaylistNative(id)
      : client.change('DELETE', '/playlists/$id');

  Future<void> editPlaylistTracks(
    String playlistId,
    String trackId, {
    required bool add,
  }) async {
    final playlist =
        await client.get('/playlists/$playlistId') as Map<String, dynamic>;
    final tracks = playlist['tracks'] as List<dynamic>? ?? [];
    final ids = tracks
        .whereType<Map<String, dynamic>>()
        .map((track) => track['id']?.toString())
        .whereType<String>()
        .toList();
    if (add && !ids.contains(trackId)) ids.add(trackId);
    if (!add) ids.removeWhere((id) => id == trackId);
    try {
      if (client case final SoundCloudMobileClient mobile) {
        await mobile.editPlaylistTrackNative(
          playlistId,
          trackId,
          add: add,
          existing: playlist,
          trackIds: ids,
        );
        return;
      }
      await client.change(
        'PUT',
        '/playlists/$playlistId',
        body: {
          'playlist': {'tracks': _playlistTracks(ids)},
        },
      );
    } on SoundCloudChallengeException {
      await _completeBrowserChallenge(
        await _pageUrl('playlist', playlistId),
        add
            ? 'Add the track to this playlist on SoundCloud, then tap Done.'
            : 'Remove the track from this playlist on SoundCloud, then tap Done.',
        () async {
          final current = await client.get('/playlists/$playlistId');
          if (current is! Map) return false;
          final currentTracks = current['tracks'];
          if (currentTracks is! List) return false;
          return currentTracks.whereType<Map>().any(
                (track) => track['id']?.toString() == trackId,
              ) ==
              add;
        },
      );
    }
  }

  Future<List<Map<String, dynamic>>> getStreams(String trackId) async {
    final track = await client.get('/tracks/$trackId');
    final media = track['media'] as Map<String, dynamic>?;
    if (media == null) return [];

    final transcodings = media['transcodings'] as List<dynamic>? ?? [];
    final results = <Map<String, dynamic>>[];

    for (final t in transcodings) {
      if (t is! Map<String, dynamic>) continue;
      results.add(t);
    }
    return results;
  }

  static bool isSoundCloudUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasScheme) return false;
    final host = uri.host.toLowerCase();
    return host == 'soundcloud.com' ||
        host.endsWith('.soundcloud.com') ||
        host == 'snd.sc' ||
        host.endsWith('.snd.sc');
  }

  Future<PlatformLinkData?> parseLink(String value) async {
    if (!isSoundCloudUrl(value)) return null;
    final resp = await client.get('/resolve', queryParameters: {'url': value});
    final kind = resp['kind'] as String?;

    if (kind == 'track') {
      _remember('track', resp['id'] as int, resp['permalink_url'] as String);
      return PlatformLinkData(
        type: PlatformLinkDataType.track,
        id: resp['id'].toString(),
      );
    } else if (kind == 'playlist') {
      final isAlbum = resp['is_album'] == true;
      _remember(
        isAlbum ? 'album' : 'playlist',
        resp['id'] as int,
        resp['permalink_url'] as String,
      );
      return PlatformLinkData(
        type: isAlbum
            ? PlatformLinkDataType.album
            : PlatformLinkDataType.playlist,
        id: resp['id'].toString(),
      );
    } else if (kind == 'user') {
      _remember('artist', resp['id'] as int, resp['permalink_url'] as String);
      return PlatformLinkData(
        type: PlatformLinkDataType.artist,
        id: resp['id'].toString(),
      );
    }

    return null;
  }
}

enum PlatformLinkDataType { track, album, artist, playlist }

class PlatformLinkData {
  const PlatformLinkData({required this.type, required this.id});

  final PlatformLinkDataType type;
  final String id;
}
