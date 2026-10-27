import '../navigation.dart';
import '../type_alias.dart';
import 'artists.dart';
import 'songs.dart';

/// Port of ytmusicapi.parsers.albums.parse_album_playlistid_if_exists.
String? parseAlbumPlaylistIdIfExists(dynamic command) {
  final endpoint = asJsonDict(command);
  final watch =
      nav(endpoint, ['watchPlaylistEndpoint', 'playlistId'], absent: true) ??
      nav(endpoint, ['watchEndpoint', 'playlistId'], absent: true);
  return watch is String ? watch : null;
}

/// Port of the common musicTwoRowItemRenderer album parser.
JsonDict parseAlbum(JsonDict result) {
  final subtitleRuns = nav(result, ['subtitle', 'runs'], absent: true);
  return {
    'title': nav(result, titleText),
    'artists': subtitleRuns is List
        ? parseArtistsRuns(
            subtitleRuns,
          ).where((artist) => artist['id'] != null).toList()
        : <JsonDict>[],
    'browseId': nav(result, [...title, ...navigationBrowseId]),
    'audioPlaylistId': parseAlbumPlaylistIdIfExists(
      nav(result, [
        'thumbnailOverlay',
        'musicItemThumbnailOverlayRenderer',
        'content',
        'musicPlayButtonRenderer',
        'playNavigationEndpoint',
      ], absent: true),
    ),
    'thumbnails': nav(result, [
      'thumbnailRenderer',
      'musicThumbnailRenderer',
      ...thumbnail,
    ], absent: true),
    'isExplicit':
        nav(result, [
          'subtitleBadges',
          0,
          'musicInlineBadgeRenderer',
          'accessibilityData',
          'accessibilityData',
          'label',
        ], absent: true) !=
        null,
    ...parseSongMenuData(result),
  };
}
