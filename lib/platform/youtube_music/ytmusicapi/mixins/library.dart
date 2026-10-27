import '../../youtube_music_client.dart';
import '../continuations.dart';
import '../helpers.dart';
import '../navigation.dart';
import '../parsers/browsing.dart';
import '../parsers/library.dart' as library_parsers;
import '../parsers/playlists.dart' as playlist_parsers;
import '../type_alias.dart';
import 'utils.dart'
    show prepareLikeEndpoint, validateOrderParameter, validateWriteResponse;

/// Library browse methods following ytmusicapi's LibraryMixin endpoints.
class LibraryMixin {
  LibraryMixin(this.client);
  final YouTubeMusicClient client;

  Future<JsonDict> libraryRaw(String browseId, {String? params}) => client.post(
    'browse',
    body: <String, dynamic>{'browseId': browseId, 'params': ?params},
  );

  Future<JsonDict> getLibraryPlaylistsRaw() =>
      libraryRaw('FEmusic_liked_playlists');
  Future<JsonDict> getLibrarySongsRaw({String? params}) =>
      libraryRaw('FEmusic_liked_videos', params: params);
  Future<JsonDict> getLibraryAlbumsRaw({String? params}) =>
      libraryRaw('FEmusic_liked_albums', params: params);
  Future<JsonDict> getLibraryArtistsRaw({String? params}) =>
      libraryRaw('FEmusic_library_corpus_track_artists', params: params);
  Future<JsonDict> getLibrarySubscriptionsRaw({String? params}) =>
      libraryRaw('FEmusic_library_corpus_artists', params: params);
  Future<JsonDict> getLibraryPodcastsRaw({String? params}) =>
      libraryRaw('FEmusic_library_non_music_audio_list', params: params);
  Future<JsonDict> getLibraryChannelsRaw({String? params}) => libraryRaw(
    'FEmusic_library_non_music_audio_channels_list',
    params: params,
  );
  Future<JsonDict> getHistoryRaw() => libraryRaw('FEmusic_history');

  Future<JsonList> getLibrarySongs({int? limit = 25, String? order}) async {
    validateOrderParameter(order);
    final response = await libraryRaw(
      'FEmusic_liked_videos',
      params: prepareOrderParams(order),
    );
    final parsed = library_parsers.parseLibrarySongs(response);
    final rows = parsed['parsed'];
    if (rows is! List) {
      return [];
    }
    final songs = rows
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
    final results = asJsonDict(parsed['results']);
    if (results != null && results.containsKey('continuations')) {
      songs.addAll(
        await getContinuations<JsonDict>(
          initial: results,
          continuationType: 'musicShelfContinuation',
          limit: limit == null ? null : limit - songs.length,
          request: (params) => _continuationRequest(
            'FEmusic_liked_videos',
            params,
            order: order,
          ),
          parse: (continuationRows) =>
              playlist_parsers.parsePlaylistItems(continuationRows),
        ),
      );
    }
    return limit == null ? songs : songs.take(limit).toList();
  }

  Future<JsonList> getLibraryPlaylists({int? limit = 25}) async {
    final response = await getLibraryPlaylistsRaw();
    final contents = library_parsers.getLibraryContents(response, grid);
    if (contents == null) {
      return [];
    }
    final rows = asJsonList(contents['items']);
    final playlists = library_parsers.parseLibraryPlaylists(rows);
    if (contents.containsKey('continuations')) {
      playlists.addAll(
        await getContinuations<JsonDict>(
          initial: contents,
          continuationType: 'gridContinuation',
          limit: limit == null ? null : limit - playlists.length,
          request: (params) =>
              _continuationRequest('FEmusic_liked_playlists', params),
          parse: (rows) => parseContentList(rows, parsePlaylist),
        ),
      );
    }
    return limit == null ? playlists : playlists.take(limit).toList();
  }

  Future<JsonList> getLibraryAlbums({int? limit = 25, String? order}) async {
    validateOrderParameter(order);
    final response = await libraryRaw(
      'FEmusic_liked_albums',
      params: prepareOrderParams(order),
    );
    return library_parsers.getLibraryAlbums(
      response,
      limit: limit,
      request: (params) =>
          _continuationRequest('FEmusic_liked_albums', params, order: order),
    );
  }

  Future<JsonList> getLibraryArtists({int? limit = 25, String? order}) async {
    validateOrderParameter(order);
    final response = await libraryRaw(
      'FEmusic_library_corpus_track_artists',
      params: prepareOrderParams(order),
    );
    return library_parsers.getLibraryArtists(
      response,
      limit: limit,
      request: (params) => _continuationRequest(
        'FEmusic_library_corpus_track_artists',
        params,
        order: order,
      ),
    );
  }

  Future<JsonList> getLibraryPodcasts({int? limit = 25, String? order}) async {
    validateOrderParameter(order);
    final response = await libraryRaw(
      'FEmusic_library_non_music_audio_list',
      params: prepareOrderParams(order),
    );
    return library_parsers.getLibraryPodcasts(
      response,
      limit: limit,
      request: (params) => _continuationRequest(
        'FEmusic_library_non_music_audio_list',
        params,
        order: order,
      ),
    );
  }

  Future<JsonList> getLibrarySubscriptions({
    int? limit = 25,
    String? order,
  }) async {
    validateOrderParameter(order);
    final response = await libraryRaw(
      'FEmusic_library_corpus_artists',
      params: prepareOrderParams(order),
    );
    return library_parsers.getLibraryArtists(
      response,
      limit: limit,
      request: (params) => _continuationRequest(
        'FEmusic_library_corpus_artists',
        params,
        order: order,
      ),
    );
  }

  Future<JsonList> getLibraryChannels({int? limit = 25, String? order}) async {
    validateOrderParameter(order);
    final response = await libraryRaw(
      'FEmusic_library_non_music_audio_channels_list',
      params: prepareOrderParams(order),
    );
    return library_parsers.getLibraryArtists(
      response,
      limit: limit,
      request: (params) => _continuationRequest(
        'FEmusic_library_non_music_audio_channels_list',
        params,
        order: order,
      ),
    );
  }

  Future<JsonList> getHistory() async {
    final response = await getHistoryRaw();
    final sections = asJsonList(
      nav(response, [...singleColumnTab, ...sectionList], absent: true),
    );
    final history = <JsonDict>[];
    for (final section in sections) {
      final shelf = asJsonDict(nav(section, musicShelf, absent: true));
      final rows = asJsonList(
        nav(section, [...musicShelf, 'contents'], absent: true),
      );
      if (shelf == null || rows.isEmpty) {
        continue;
      }
      final played = nav(shelf, titleText, absent: true);
      for (final song in playlist_parsers.parsePlaylistItems(rows)) {
        history.add({...song, 'played': played});
      }
    }
    return history;
  }

  Future<JsonDict> _continuationRequest(
    String browseId,
    String params, {
    String? order,
  }) {
    final query = Uri.splitQueryString(
      params.startsWith('&') ? params.substring(1) : params,
    );
    return client.post(
      'browse',
      body: <String, dynamic>{
        'browseId': browseId,
        'params': ?prepareOrderParams(order),
      },
      query: query,
    );
  }

  Future<JsonDict> accountInfoRaw() => client.post('account/account_menu');

  Future<JsonDict> rateSongRaw(
    String videoId, {
    String rating = 'INDIFFERENT',
  }) {
    return client.post(
      prepareLikeEndpoint(rating),
      body: {
        'target': {'videoId': videoId},
      },
    );
  }

  Future<JsonDict> editSongLibraryStatusRaw({
    List<String>? feedbackTokens,
    bool gzipBody = false,
  }) {
    return client.post(
      'feedback',
      body: {'feedbackTokens': feedbackTokens},
      gzipBody: gzipBody,
    );
  }

  Future<JsonDict> removeHistoryItemsRaw(List<String> feedbackTokens) =>
      editSongLibraryStatusRaw(feedbackTokens: feedbackTokens);

  Future<JsonDict> ratePlaylistRaw(
    String playlistId, {
    String rating = 'INDIFFERENT',
  }) {
    return client.post(
      prepareLikeEndpoint(rating),
      body: {
        'target': {'playlistId': playlistId},
      },
    );
  }

  Future<JsonDict> subscribeArtistsRaw(
    List<String> channelIds, {
    required bool subscribe,
  }) {
    return client.post(
      subscribe ? 'subscription/subscribe' : 'subscription/unsubscribe',
      body: {'channelIds': channelIds},
    );
  }

  Future<JsonDict> rateSong(String videoId, {String rating = 'INDIFFERENT'}) =>
      rateSongRaw(videoId, rating: rating);

  Future<JsonDict> editSongLibraryStatus(List<String> feedbackTokens) async {
    final response = await editSongLibraryStatusRaw(
      feedbackTokens: feedbackTokens,
    );
    validateWriteResponse(response);
    return response;
  }

  Future<JsonDict> ratePlaylist(
    String playlistId, {
    String rating = 'INDIFFERENT',
  }) => ratePlaylistRaw(playlistId, rating: rating);

  Future<JsonDict> subscribeArtist(String channelId) =>
      subscribeArtistsRaw([channelId], subscribe: true);

  Future<JsonDict> unsubscribeArtists(List<String> channelIds) =>
      subscribeArtistsRaw(channelIds, subscribe: false);
}
