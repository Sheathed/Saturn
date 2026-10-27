import '../../youtube_music_client.dart';
import '../navigation.dart';
import '../type_alias.dart';
import '../parsers/albums.dart';
import '../parsers/browsing.dart';
import '../parsers/explore.dart';

/// Explore and chart browse calls from ytmusicapi's ExploreMixin.
class ExploreMixin {
  ExploreMixin(this.client);
  final YouTubeMusicClient client;

  Future<JsonDict> exploreRaw() =>
      client.post('browse', body: {'browseId': 'FEmusic_explore'});

  Future<JsonDict> moodCategoriesRaw() =>
      client.post('browse', body: {'browseId': 'FEmusic_moods_and_genres'});

  Future<JsonDict> getMoodCategories() async {
    final response = await moodCategoriesRaw();
    final rows = asJsonList(
      nav(response, [...singleColumnTab, ...sectionList], absent: true),
    );
    final sections = <String, dynamic>{};
    for (final row in rows) {
      final grid = asJsonDict(row['gridRenderer']);
      final title = nav(grid, [
        'header',
        'gridHeaderRenderer',
        ...titleText,
      ], absent: true);
      if (title is! String) {
        continue;
      }
      final categories = <JsonDict>[];
      for (final item in asJsonList(grid?['items'])) {
        categories.add({
          'title': nav(item, categoryTitle, absent: true),
          'params': nav(item, categoryParams, absent: true),
        });
      }
      sections[title] = categories;
    }
    return sections;
  }

  Future<JsonList> getMoodPlaylists(String params) async {
    final response = await client.post(
      'browse',
      body: {'browseId': 'FEmusic_moods_and_genres_category', 'params': params},
    );
    final sections = asJsonList(
      nav(response, [...singleColumnTab, ...sectionList], absent: true),
    );
    final playlists = <JsonDict>[];
    for (final section in sections) {
      final rows = asJsonList(
        section['gridRenderer']?['items'] ??
            section['musicCarouselShelfRenderer']?['contents'] ??
            section['musicImmersiveCarouselShelfRenderer']?['contents'],
      );
      playlists.addAll(parseContentList(rows, parsePlaylist));
    }
    return playlists;
  }

  Future<JsonDict> getExplore() async {
    final response = await exploreRaw();
    final sections = asJsonList(
      nav(response, [...singleColumnTab, ...sectionList], absent: true),
    );
    final explore = <String, dynamic>{};
    for (final section in sections) {
      final shelf = asJsonDict(section['musicCarouselShelfRenderer']);
      if (shelf == null) {
        continue;
      }
      final browseId = nav(shelf, [
        ...carouselTitle,
        ...navigationBrowseId,
      ], absent: true);
      final rows = asJsonList(shelf['contents']);
      switch (browseId) {
        case 'FEmusic_new_releases_albums':
          explore['new_releases'] = parseContentList(rows, parseAlbum);
        case 'FEmusic_moods_and_genres':
          explore['moods_and_genres'] = rows
              .map(
                (item) => {
                  'title': nav(item, categoryTitle, absent: true),
                  'params': nav(item, categoryParams, absent: true),
                },
              )
              .toList();
        case 'FEmusic_top_non_music_audio_episodes':
          explore['top_episodes'] = parseContentList(
            rows,
            parseChartEpisode,
            key: 'musicMultiRowListItemRenderer',
          );
        case 'FEmusic_new_releases_videos':
          explore['new_videos'] = parseContentList(
            rows,
            parseVideo,
            key: 'musicTwoRowItemRenderer',
          );
        default:
          if (browseId is String && browseId.startsWith('VLPL')) {
            explore['top_songs'] = {
              'playlist': browseId,
              'items': parseContentList(
                rows,
                parseChartSong,
                key: 'musicResponsiveListItemRenderer',
              ),
            };
          } else if (browseId is String && browseId.startsWith('VLOLA')) {
            explore['trending'] = {
              'playlist': browseId,
              'items': parseContentList(
                rows,
                parseTrendingItem,
                key: 'musicResponsiveListItemRenderer',
              ),
            };
          }
      }
    }
    return explore;
  }
}
