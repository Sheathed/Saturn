import '../../youtube_music_client.dart';
import '../continuations.dart';
import '../helpers.dart';
import '../navigation.dart';
import '../parsers/album_headers.dart';
import '../parsers/library.dart' as library_parsers;
import '../parsers/uploads.dart' as upload_parsers;
import '../type_alias.dart';

/// Uploaded music operations from ytmusicapi's UploadsMixin.
class UploadsMixin {
  UploadsMixin(this.client);
  final YouTubeMusicClient client;

  Future<JsonDict> uploadsRaw(String browseId) =>
      client.post('browse', body: {'browseId': browseId});

  Future<JsonDict> getLibraryUploadSongsRaw({String? order}) => client.post(
    'browse',
    body: <String, dynamic>{
      'browseId': 'FEmusic_library_privately_owned_tracks',
      'params': ?prepareOrderParams(order),
    },
  );
  Future<JsonDict> getLibraryUploadAlbumsRaw({String? order}) => client.post(
    'browse',
    body: <String, dynamic>{
      'browseId': 'FEmusic_library_privately_owned_releases',
      'params': ?prepareOrderParams(order),
    },
  );
  Future<JsonDict> getLibraryUploadArtistsRaw({String? order}) => client.post(
    'browse',
    body: <String, dynamic>{
      'browseId': 'FEmusic_library_privately_owned_artists',
      'params': ?prepareOrderParams(order),
    },
  );

  Future<JsonList> getLibraryUploadSongs({
    int? limit = 25,
    String? order,
  }) async {
    final response = await getLibraryUploadSongsRaw(order: order);
    final results = library_parsers.getLibraryContents(response, musicShelf);
    if (results == null) {
      return [];
    }
    library_parsers.popLibraryRandomMix(results);
    final songs = upload_parsers.parseUploadedItems(
      asJsonList(results['contents']),
    );
    if (results.containsKey('continuations')) {
      songs.addAll(
        await getContinuations<JsonDict>(
          initial: results,
          continuationType: 'musicShelfContinuation',
          limit: limit == null ? null : limit - songs.length,
          request: (params) => _continuationRequest(
            'FEmusic_library_privately_owned_tracks',
            params,
            order: order,
          ),
          parse: upload_parsers.parseUploadedItems,
        ),
      );
    }
    return limit == null ? songs : songs.take(limit).toList();
  }

  Future<JsonList> getLibraryUploadAlbums({
    int? limit = 25,
    String? order,
  }) async {
    final response = await getLibraryUploadAlbumsRaw(order: order);
    return library_parsers.getLibraryAlbums(
      response,
      limit: limit,
      request: (params) => _continuationRequest(
        'FEmusic_library_privately_owned_releases',
        params,
        order: order,
      ),
    );
  }

  Future<JsonList> getLibraryUploadArtists({
    int? limit = 25,
    String? order,
  }) async {
    final response = await getLibraryUploadArtistsRaw(order: order);
    return library_parsers.getLibraryArtists(
      response,
      limit: limit,
      uploaded: true,
      request: (params) => _continuationRequest(
        'FEmusic_library_privately_owned_artists',
        params,
        order: order,
      ),
    );
  }

  Future<JsonList> getLibraryUploadArtist(
    String browseId, {
    int? limit = 25,
  }) async {
    final response = await uploadsRaw(browseId);
    final results = asJsonDict(
      nav(response, [
        ...singleColumnTab,
        ...sectionListItem,
        ...musicShelf,
      ], absent: true),
    );
    if (results == null) {
      return [];
    }
    final rows = asJsonList(results['contents']);
    if (rows.length > 1) {
      rows.removeAt(0);
    }
    final items = upload_parsers.parseUploadedItems(rows);
    if (results.containsKey('continuations')) {
      items.addAll(
        await getContinuations<JsonDict>(
          initial: results,
          continuationType: 'musicShelfContinuation',
          limit: limit == null ? null : limit - items.length,
          request: (params) => _continuationRequest(browseId, params),
          parse: upload_parsers.parseUploadedItems,
        ),
      );
    }
    return limit == null ? items : items.take(limit).toList();
  }

  Future<JsonDict> getLibraryUploadAlbum(String browseId) async {
    final response = await uploadsRaw(browseId);
    final album = parseAlbumHeader(response);
    final results = asJsonDict(
      nav(response, [
        ...singleColumnTab,
        ...sectionListItem,
        ...musicShelf,
      ], absent: true),
    );
    final tracks = upload_parsers.parseUploadedItems(
      asJsonList(results?['contents']),
    );
    album['tracks'] = tracks;
    album['duration_seconds'] = sumTotalDuration(album);
    return album;
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

  Future<JsonDict> deleteUploadRaw(String entityId) => client.post(
    'music/delete_privately_owned_entity',
    body: {'entityId': entityId},
  );
}
