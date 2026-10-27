import '../../youtube_music_client.dart';
import '../../ytmusicapi_translations.dart';
import '../continuations.dart';
import '../navigation.dart';
import '../parsers/browsing.dart';
import '../parsers/podcasts.dart' as podcast_parsers;
import '../parsers/playlists.dart' as playlist_parsers;
import '../parsers/i18n.dart';
import '../type_alias.dart';

/// Podcast browse calls from ytmusicapi's PodcastsMixin.
class PodcastsMixin {
  PodcastsMixin(this.client);
  final YouTubeMusicClient client;

  Future<JsonDict> podcastRaw(String browseId) =>
      client.post('browse', body: {'browseId': browseId});

  Future<JsonDict> getChannelRaw(String channelId) => podcastRaw(channelId);

  Future<JsonDict> getChannel(
    String channelId, {
    YTMusicApiParser? parser,
  }) async {
    final response = await getChannelRaw(channelId);
    final results = asJsonList(
      nav(response, [...singleColumnTab, ...sectionList], absent: true),
    );
    final translations = await YTMusicApiTranslations.load(client.hl);
    final activeParser =
        parser ?? YTMusicApiParser(translate: translations.translate);
    return {
      'title': nav(response, [
        ...headerMusicVisual,
        ...titleText,
      ], absent: true),
      'thumbnails': nav(response, [
        ...headerMusicVisual,
        ...thumbnails,
      ], absent: true),
      ...activeParser.parseChannelContents(results),
    };
  }

  Future<JsonDict> getChannelEpisodesRaw(String channelId, String params) =>
      client.post('browse', body: {'browseId': channelId, 'params': params});

  Future<JsonList> getChannelEpisodes(String channelId, String params) async {
    final response = await getChannelEpisodesRaw(channelId, params);
    final rows = asJsonList(
      nav(response, [
        ...singleColumnTab,
        ...sectionListItem,
        ...gridItems,
      ], absent: true),
    );
    return parseContentList(
      rows,
      podcast_parsers.parseEpisode,
      key: multiRowItem,
    );
  }

  Future<JsonDict> getPodcastRaw(String playlistId) => podcastRaw(
    playlistId.startsWith('MPSP') ? playlistId : 'MPSP$playlistId',
  );

  Future<JsonDict> getPodcast(String playlistId, {int? limit = 100}) async {
    final browseId = playlistId.startsWith('MPSP')
        ? playlistId
        : 'MPSP$playlistId';
    final response = await getPodcastRaw(browseId);
    final header = asJsonDict(
      nav(response, [
        ...twoColumnRenderer,
        ...tabContent,
        ...sectionListItem,
        ...responsiveHeader,
      ], absent: true),
    );
    if (header == null) {
      throw StateError('Podcast response did not contain its header.');
    }
    final podcast = podcast_parsers.parsePodcastHeader(header);
    final shelf = asJsonDict(
      nav(response, [
        ...twoColumnRenderer,
        'secondaryContents',
        ...sectionListItem,
        ...musicShelf,
      ], absent: true),
    );
    if (shelf == null) {
      podcast['episodes'] = <JsonDict>[];
      return podcast;
    }
    final episodes = parseContentList(
      asJsonList(shelf['contents']),
      podcast_parsers.parseEpisode,
      key: multiRowItem,
    );
    if (shelf.containsKey('continuations')) {
      episodes.addAll(
        await getContinuations<JsonDict>(
          initial: shelf,
          continuationType: 'musicShelfContinuation',
          limit: limit == null ? null : limit - episodes.length,
          request: (params) {
            final query = Uri.splitQueryString(
              params.startsWith('&') ? params.substring(1) : params,
            );
            return client.post(
              'browse',
              body: {'browseId': browseId},
              query: query,
            );
          },
          parse: (rows) => parseContentList(
            rows,
            podcast_parsers.parseEpisode,
            key: multiRowItem,
          ),
        ),
      );
    }
    podcast['episodes'] = limit == null
        ? episodes
        : episodes.take(limit).toList();
    return podcast;
  }

  Future<JsonDict> getEpisodeRaw(String videoId) =>
      podcastRaw(videoId.startsWith('MPED') ? videoId : 'MPED$videoId');

  Future<JsonDict> getEpisode(String videoId) async {
    final response = await getEpisodeRaw(videoId);
    final header = asJsonDict(
      nav(response, [
        ...twoColumnRenderer,
        ...tabContent,
        ...sectionListItem,
        ...responsiveHeader,
      ], absent: true),
    );
    if (header == null) {
      throw StateError('Episode response did not contain its header.');
    }
    final episode = podcast_parsers.parseEpisodeHeader(header);
    episode['description'] = null;
    final descriptionRuns = nav(response, [
      ...twoColumnRenderer,
      'secondaryContents',
      ...sectionListItem,
      'musicDescriptionShelfRenderer',
      'description',
      'runs',
    ], absent: true);
    if (descriptionRuns is List) {
      episode['description'] = podcast_parsers.ParsedDescription.fromRuns(
        descriptionRuns,
      );
    }
    return episode;
  }

  Future<JsonDict> getEpisodesPlaylistRaw({String playlistId = 'RDPN'}) =>
      podcastRaw(playlistId.startsWith('VL') ? playlistId : 'VL$playlistId');

  Future<JsonDict> getEpisodesPlaylist({
    String playlistId = 'RDPN',
    int limit = 100,
  }) async {
    final response = await getEpisodesPlaylistRaw(playlistId: playlistId);
    final playlist = playlist_parsers.parsePlaylistHeader(response);
    final shelf = asJsonDict(
      nav(response, [
        ...twoColumnRenderer,
        'secondaryContents',
        ...sectionListItem,
        ...musicShelf,
      ], absent: true),
    );
    final episodes = shelf == null
        ? <JsonDict>[]
        : parseContentList(
            asJsonList(shelf['contents']),
            podcast_parsers.parseEpisode,
            key: multiRowItem,
          );
    playlist['episodes'] = episodes.take(limit).toList();
    return playlist;
  }
}
