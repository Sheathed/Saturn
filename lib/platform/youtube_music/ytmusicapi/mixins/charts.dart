import '../../youtube_music_client.dart';
import '../navigation.dart';
import '../type_alias.dart';
import '../parsers/browsing.dart';
import '../parsers/explore.dart';

/// Chart requests from ytmusicapi's ChartsMixin.
class ChartsMixin {
  ChartsMixin(this.client);
  final YouTubeMusicClient client;

  Future<JsonDict> chartsRaw({String country = 'ZZ'}) {
    return client.post(
      'browse',
      body: <String, dynamic>{
        'browseId': 'FEmusic_charts',
        if (country.isNotEmpty)
          'formData': {
            'selectedValues': [country],
          },
      },
    );
  }

  Future<JsonDict> getCharts({String country = 'ZZ'}) async {
    final response = await chartsRaw(country: country);
    final sections = asJsonList(
      nav(response, [...singleColumnTab, ...sectionList], absent: true),
    );
    final chart = <String, dynamic>{'countries': <String, dynamic>{}};
    if (sections.isEmpty) {
      return chart;
    }
    final selected = nav(sections.first, [
      'musicShelfRenderer',
      'subheaders',
      0,
      'musicSideAlignedItemRenderer',
      'startItems',
      0,
      'musicSortFilterButtonRenderer',
      ...titleText,
    ], absent: true);
    (chart['countries'] as JsonDict)['selected'] = selected;
    final mutations = asJsonList(
      nav(response, frameworkMutations, absent: true),
    );
    (chart['countries'] as JsonDict)['options'] = mutations
        .map(
          (mutation) => nav(mutation, [
            'payload',
            'musicFormBooleanChoice',
            'opaqueToken',
          ], absent: true),
        )
        .whereType<String>()
        .toList();

    final carousels = <List<dynamic>>[];
    final artistCarousels = <List<dynamic>>[];
    for (final section in sections.skip(1)) {
      final rows = asJsonList(
        nav(section, ['musicCarouselShelfRenderer', 'contents'], absent: true),
      );
      if (rows.isEmpty) {
        continue;
      }
      final browseId = nav(rows.first, [
        'musicTwoRowItemRenderer',
        ...title,
        ...navigationBrowseId,
      ], absent: true);
      if (browseId is String && browseId.startsWith('VL')) {
        carousels.add(rows);
      } else if (rows.first.containsKey('musicResponsiveListItemRenderer')) {
        artistCarousels.add(rows);
      }
    }
    final playlistNames = <String>['videos'];
    if (country == 'US') {
      playlistNames.add('genres');
    } else if (country == 'IN') {
      playlistNames.add('languages');
    }
    if (carousels.length > playlistNames.length) {
      playlistNames
        ..clear()
        ..addAll(['daily', 'weekly']);
      if (country == 'US') {
        playlistNames.add('genres');
      } else if (country == 'IN') {
        playlistNames.add('languages');
      }
    }
    for (
      var index = 0;
      index < carousels.length && index < playlistNames.length;
      index++
    ) {
      chart[playlistNames[index]] = parseContentList(
        carousels[index],
        parseChartPlaylist,
        key: 'musicTwoRowItemRenderer',
      );
    }
    if (artistCarousels.isNotEmpty) {
      chart['artists'] = parseContentList(
        artistCarousels.first,
        parseChartArtist,
        key: 'musicResponsiveListItemRenderer',
      );
    }
    return chart;
  }
}
