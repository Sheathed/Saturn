import 'package:logging/logging.dart';

import '../../youtube_music_client.dart';
import '../continuations.dart';
import '../parsers/playlists.dart' as playlist_parsers;
import '../type_alias.dart';
import 'utils.dart' show htmlToText, validateWriteResponse;

/// Playlist mutations and reads from ytmusicapi's PlaylistsMixin.
class PlaylistsMixin {
  PlaylistsMixin(this.client);
  final YouTubeMusicClient client;
  final Logger _log = Logger('YouTubeMusicPlaylistsMixin');
  final Map<String, _PlaylistPageCache> _playlistPageCache = {};

  Future<JsonDict> playlistRaw(String playlistId) => client.post(
    'browse',
    body: {
      'browseId': playlistId.startsWith('VL') ? playlistId : 'VL$playlistId',
    },
  );

  Future<JsonDict> getLikedSongsRaw() => playlistRaw('LM');
  Future<JsonDict> getSavedEpisodesRaw() => playlistRaw('SE');

  Future<JsonDict> getPlaylist(String playlistId, {int? limit = 100}) async {
    try {
      final response = await playlistRaw(playlistId);
      final parsed = await playlist_parsers.parseAudioPlaylist(
        response,
        limit: limit,
        request: (body) => client.post('browse', body: body),
      );
      parsed.addAll(playlist_parsers.parsePlaylistHeader(response));
      _log.fine(
        'Loaded playlist $playlistId: '
        '${parsed['tracks'] is List ? (parsed['tracks'] as List).length : 0} '
        'tracks (owned=${parsed['owned']})',
      );
      return parsed;
    } catch (error, stackTrace) {
      _log.warning('Failed to load playlist $playlistId', error, stackTrace);
      rethrow;
    }
  }

  Future<JsonDict> getPlaylistPage(
    String playlistId, {
    required int start,
    required int limit,
  }) async {
    if (start < 0 || limit < 0) {
      throw ArgumentError('Playlist page start and limit must be non-negative');
    }
    final normalizedId = playlist_parsers.validatePlaylistId(playlistId);
    var pageCache = _playlistPageCache[normalizedId];
    if (pageCache == null) {
      final response = await playlistRaw(normalizedId);
      final parsed = playlist_parsers.parseAudioPlaylistPageStart(response);
      pageCache = _PlaylistPageCache(
        header: parsed,
        tracks: List<JsonDict>.from(parsed['tracks'] as List? ?? const []),
        continuation: parsed['continuation'] as String?,
      );
      _playlistPageCache[normalizedId] = pageCache;
    }

    final end = start + limit;
    while (pageCache.tracks.length < end &&
        pageCache.continuation != null &&
        !pageCache.exhausted) {
      final response = await client.post(
        'browse',
        body: {'continuation': pageCache.continuation},
      );
      final rows = getContinuationItems(response);
      if (rows.isEmpty) {
        pageCache.exhausted = true;
        pageCache.continuation = null;
        break;
      }
      final tracks = playlist_parsers.parsePlaylistItems(rows);
      if (tracks.isEmpty) {
        pageCache.exhausted = true;
        pageCache.continuation = null;
        break;
      }
      pageCache.tracks.addAll(tracks);
      pageCache.continuation = getContinuationToken(rows);
      pageCache.exhausted = pageCache.continuation == null;
    }

    final hasMore = !pageCache.exhausted;
    final cachedHeader = Map<String, dynamic>.from(pageCache.header)
      ..remove('tracks')
      ..remove('continuation');
    return {
      ...cachedHeader,
      'tracks': pageCache.tracks.skip(start).take(limit).toList(),
      'trackCount':
          cachedHeader['trackCount'] as int? ??
          pageCache.tracks.length + (hasMore ? 1 : 0),
      'hasMore': hasMore,
    };
  }

  Future<JsonDict> getLikedSongs({int limit = 100}) =>
      getPlaylist('LM', limit: limit);

  Future<JsonDict> getSavedEpisodes({int limit = 100}) =>
      getPlaylist('SE', limit: limit);

  Future<JsonDict> createPlaylistRaw(
    String title, {
    String description = '',
    String privacyStatus = 'PRIVATE',
    List<String>? videoIds,
    String? sourcePlaylistId,
  }) => client.post(
    'playlist/create',
    body: <String, dynamic>{
      'title': title,
      'description': htmlToText(description),
      'privacyStatus': privacyStatus,
      'videoIds': ?videoIds,
      'sourcePlaylistId': ?sourcePlaylistId,
    },
  );

  Future<JsonDict> editPlaylistRaw(String playlistId, JsonList actions) async {
    final response = await client.post(
      'browse/edit_playlist',
      body: {
        'playlistId': playlistId.startsWith('VL')
            ? playlistId.substring(2)
            : playlistId,
        'actions': actions,
      },
    );
    _playlistPageCache.remove(playlist_parsers.validatePlaylistId(playlistId));
    return response;
  }

  Future<JsonDict> deletePlaylistRaw(String playlistId) async {
    final response = await client.post(
      'playlist/delete',
      body: {
        'playlistId': playlistId.startsWith('VL')
            ? playlistId.substring(2)
            : playlistId,
      },
    );
    _playlistPageCache.remove(playlist_parsers.validatePlaylistId(playlistId));
    return response;
  }

  Future<JsonDict> addPlaylistItemsRaw(
    String playlistId,
    JsonList actions,
  ) async {
    final response = await client.post(
      'browse/edit_playlist',
      body: {
        'playlistId': playlistId.startsWith('VL')
            ? playlistId.substring(2)
            : playlistId,
        'actions': actions,
      },
    );
    _playlistPageCache.remove(playlist_parsers.validatePlaylistId(playlistId));
    return response;
  }

  Future<JsonDict> removePlaylistItemsRaw(
    String playlistId,
    JsonList actions,
  ) => addPlaylistItemsRaw(playlistId, actions);

  Future<JsonDict> addPlaylistItems(
    String playlistId, {
    List<String>? videoIds,
    String? sourcePlaylistId,
    bool duplicates = false,
  }) async {
    if ((videoIds == null || videoIds.isEmpty) && sourcePlaylistId == null) {
      throw ArgumentError('Provide video IDs or a source playlist.');
    }
    final actions = <JsonDict>[
      if (videoIds != null)
        for (final videoId in videoIds)
          {
            'action': 'ACTION_ADD_VIDEO',
            'addedVideoId': videoId,
            if (duplicates) 'dedupeOption': 'DEDUPE_OPTION_SKIP',
          },
      if (sourcePlaylistId != null) ...[
        {'action': 'ACTION_ADD_PLAYLIST', 'addedFullListId': sourcePlaylistId},
        if (videoIds == null || videoIds.isEmpty)
          {'action': 'ACTION_ADD_VIDEO', 'addedVideoId': null},
      ],
    ];
    final response = await addPlaylistItemsRaw(playlistId, actions);
    validateWriteResponse(response);
    return response;
  }

  Future<JsonDict> removePlaylistItems(
    String playlistId,
    List<JsonDict> videos,
  ) async {
    if (videos.any((video) => video['setVideoId'] == null)) {
      throw ArgumentError('Every video needs a setVideoId to be removed.');
    }
    final actions = videos
        .map(
          (video) => <String, dynamic>{
            'action': 'ACTION_REMOVE_VIDEO',
            'setVideoId': video['setVideoId'],
            'removedVideoId': video['videoId'],
          },
        )
        .toList();
    final response = await removePlaylistItemsRaw(playlistId, actions);
    validateWriteResponse(response);
    return response;
  }

  Future<JsonDict> joinCollaborativePlaylist(
    String playlistId,
    String joinCollaborationToken,
  ) => editPlaylistRaw(playlistId, [
    {
      'action': 'ACTION_JOIN_COLLABORATION',
      'joinCollaborationToken': joinCollaborationToken,
    },
  ]);
}

class _PlaylistPageCache {
  _PlaylistPageCache({
    required this.header,
    required this.tracks,
    required this.continuation,
  });

  final JsonDict header;
  final JsonList tracks;
  String? continuation;
  bool exhausted = false;
}
