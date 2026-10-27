import '../navigation.dart';
import '../type_alias.dart';
import 'albums.dart';
import 'browsing.dart';
import 'podcasts.dart';

/// Dart counterpart of ytmusicapi.parsers.i18n.Parser.
/// The callback should be backed by the matching upstream gettext catalog.
class YTMusicApiParser {
  const YTMusicApiParser({String Function(String)? translate})
    : _translate = translate ?? _identity;

  final String Function(String) _translate;
  static String _identity(String value) => value;
  String _(String value) => _translate(value);

  List<String> getSearchResultTypes() => [
    _('album'),
    _('artist'),
    _('playlist'),
    _('song'),
    _('video'),
    _('station'),
    _('profile'),
    _('podcast'),
    _('episode'),
  ];

  List<String> getApiResultTypes() => [
    'single',
    'ep',
    ...getSearchResultTypes(),
  ];

  JsonDict getSongCreditSectionMap() => {
    _('performed_by'): 'performed_by',
    _('written_by'): 'written_by',
    _('produced_by'): 'produced_by',
    _('music_metadata_provided_by'): 'music_metadata_provided_by',
  };

  JsonDict parseChannelContents(List<dynamic> rows) {
    final categories = <(String, String, JsonDict Function(JsonDict), String)>[
      ('albums', _('albums'), parseAlbum, twoRowItem),
      ('singles', _('singles & eps'), parseSingle, twoRowItem),
      ('shows', _('shows'), parseAlbum, twoRowItem),
      ('videos', _('videos'), parseVideo, twoRowItem),
      ('playlists', _('playlists'), parsePlaylist, twoRowItem),
      ('related', _('related'), parseRelatedArtist, twoRowItem),
      ('episodes', _('episodes'), parseEpisode, multiRowItem),
      ('podcasts', _('podcasts'), parsePodcast, twoRowItem),
    ];
    final artist = <String, dynamic>{};
    for (final (category, localizedTitle, parser, key) in categories) {
      JsonDict? matchingShelf;
      for (final value in rows) {
        final row = asJsonDict(value);
        final shelf = asJsonDict(row?['musicCarouselShelfRenderer']);
        final actualTitle = nav(shelf, [
          'header',
          'musicCarouselShelfBasicHeaderRenderer',
          ...titleText,
        ], absent: true);
        final normalizedTitle = actualTitle is String
            ? actualTitle.toLowerCase()
            : '';
        final normalizedCategory = localizedTitle.toLowerCase();
        final isCategory = normalizedTitle == normalizedCategory ||
            (category == 'playlists' &&
                normalizedTitle.startsWith('$normalizedCategory '));
        if (isCategory) {
          matchingShelf = shelf;
          break;
        }
      }
      if (matchingShelf == null) {
        continue;
      }
      final section = <String, dynamic>{
        'browseId': null,
        'results': <JsonDict>[],
      };
      final browseId = nav(matchingShelf, [
        'header',
        'musicCarouselShelfBasicHeaderRenderer',
        ...title,
        ...navigationBrowseId,
      ], absent: true);
      if (browseId != null) {
        section['browseId'] = browseId;
        section['params'] = nav(matchingShelf, [
          'header',
          'musicCarouselShelfBasicHeaderRenderer',
          ...title,
          ...navigationBrowse,
          'params',
        ], absent: true);
      }
      final contents = matchingShelf['contents'];
      if (contents is List) {
        section['results'] = parseContentList(contents, parser, key: key);
      }
      artist[category] = section;
    }
    return artist;
  }
}
