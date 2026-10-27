import '../../youtube_music_client.dart';
import '../continuations.dart';
import '../navigation.dart';
import '../type_alias.dart';
import '../parsers/watch.dart';

/// Innertube player and watch-next calls used by ytmusicapi's WatchMixin.
class WatchMixin {
  WatchMixin(this.client);
  final YouTubeMusicClient client;

  Future<JsonDict> playerRaw(String videoId, {String? playlistId}) =>
      client.post(
        'player',
        body: <String, dynamic>{'videoId': videoId, 'playlistId': ?playlistId},
      );

  Future<JsonDict> watchNextRaw({
    String? videoId,
    String? playlistId,
    int limit = 25,
    bool radio = false,
    bool shuffle = false,
  }) {
    final body = _watchNextBody(
      videoId: videoId,
      playlistId: playlistId,
      radio: radio,
      shuffle: shuffle,
    );
    return client.post('next', body: body);
  }

  Future<JsonDict> getWatchPlaylist({
    String? videoId,
    String? playlistId,
    int limit = 25,
    bool radio = false,
    bool shuffle = false,
  }) async {
    final body = _watchNextBody(
      videoId: videoId,
      playlistId: playlistId,
      radio: radio,
      shuffle: shuffle,
    );
    final response = await client.post('next', body: body);
    final watchNextRenderer = asJsonDict(
      nav(response, [
        'contents',
        'singleColumnMusicWatchNextResultsRenderer',
        'tabbedRenderer',
        'watchNextTabbedResultsRenderer',
      ], absent: true),
    );
    if (watchNextRenderer == null) {
      return {
        'tracks': <JsonDict>[],
        'playlistId': null,
        'lyrics': null,
        'related': null,
      };
    }
    final browseIds = getTabBrowseIds(watchNextRenderer);
    final results = asJsonDict(
      nav(watchNextRenderer, [
        ...tabContent,
        'musicQueueRenderer',
        'content',
        'playlistPanelRenderer',
      ], absent: true),
    );
    if (results == null) {
      return {
        'tracks': <JsonDict>[],
        'playlistId': null,
        'lyrics': browseIds['MUSIC_PAGE_TYPE_TRACK_LYRICS'],
        'related': browseIds['MUSIC_PAGE_TYPE_TRACK_RELATED'],
      };
    }
    final rows = asJsonList(results['contents']);
    final tracks = parseWatchPlaylistRows(rows);
    final resolvedPlaylistId = rows
        .map(
          (row) => nav(row, [
            'playlistPanelVideoRenderer',
            ...navigationPlaylistId,
          ], absent: true),
        )
        .whereType<String>()
        .firstOrNull;
    if (results.containsKey('continuations') && tracks.length < limit) {
      final continued = await getContinuations<JsonDict>(
        initial: results,
        continuationType: 'playlistPanelContinuation',
        ctokenPath: radio ? 'Radio' : '',
        limit: limit - tracks.length,
        request: (params) {
          final query = Uri.splitQueryString(
            params.startsWith('&') ? params.substring(1) : params,
          );
          return client.post('next', body: body, query: query);
        },
        parse: parseWatchPlaylistRows,
      );
      tracks.addAll(continued);
    }
    return {
      'tracks': tracks,
      'playlistId': resolvedPlaylistId,
      'lyrics': browseIds['MUSIC_PAGE_TYPE_TRACK_LYRICS'],
      'related': browseIds['MUSIC_PAGE_TYPE_TRACK_RELATED'],
    };
  }

  JsonDict _watchNextBody({
    String? videoId,
    String? playlistId,
    required bool radio,
    required bool shuffle,
  }) {
    if ((videoId == null || videoId.isEmpty) &&
        (playlistId == null || playlistId.isEmpty)) {
      throw ArgumentError('Provide a video ID, playlist ID, or both.');
    }
    final body = <String, dynamic>{
      'enablePersistentPlaylistPanel': true,
      'isAudioOnly': true,
      'tunerSettingValue': 'AUTOMIX_SETTING_NORMAL',
    };
    if (videoId != null && videoId.isNotEmpty) {
      body['videoId'] = videoId;
      if (playlistId == null && !radio && !shuffle) {
        playlistId = 'RDAMVM$videoId';
        body['watchEndpointMusicSupportedConfigs'] = {
          'watchEndpointMusicConfig': {
            'hasPersistentPlaylistPanel': true,
            'musicVideoType': 'MUSIC_VIDEO_TYPE_ATV',
          },
        };
      }
    }
    if (playlistId != null && playlistId.isNotEmpty) {
      body['playlistId'] = playlistId;
    }
    if (shuffle && playlistId != null) {
      body['params'] = 'wAEB8gECKAE%3D';
    }
    if (radio) {
      body['params'] = 'wAEB';
    }
    return body;
  }
}
