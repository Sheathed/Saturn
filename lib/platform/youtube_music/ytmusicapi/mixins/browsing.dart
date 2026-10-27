import '../../youtube_music_client.dart';
import '../../ytmusicapi_translations.dart';
import '../continuations.dart';
import '../helpers.dart';
import '../models/lyrics.dart';
import '../navigation.dart';
import '../parsers/albums.dart' as album_parsers;
import '../parsers/browsing.dart' as browsing_parsers;
import '../parsers/album_headers.dart';
import '../parsers/i18n.dart';
import '../parsers/library.dart' as library_parsers;
import '../parsers/playlists.dart' as playlist_parsers;
import '../type_alias.dart';

/// Innertube browse calls used by ytmusicapi's BrowsingMixin.
class BrowsingMixin {
  BrowsingMixin(this.client);
  final YouTubeMusicClient client;

  Future<JsonDict> browseRaw(String browseId, {String? params}) => client.post(
    'browse',
    body: <String, dynamic>{'browseId': browseId, 'params': ?params},
  );

  Future<JsonDict> getHomeRaw() => browseRaw('FEmusic_home');
  Future<JsonDict> getArtistRaw(String channelId) => browseRaw(channelId);
  Future<JsonDict> getUserRaw(String channelId) => browseRaw(channelId);
  Future<JsonDict> getAlbumRaw(String browseId) => browseRaw(browseId);
  Future<JsonDict> getSongCreditsRaw(String browseId) => browseRaw(browseId);
  Future<JsonDict> getSongRelatedRaw(String browseId) => browseRaw(browseId);
  Future<JsonDict> getTasteProfileRaw() => browseRaw('FEmusic_tastebuilder');

  Future<JsonList> getHome({int limit = 3}) async {
    if (limit <= 0) {
      return [];
    }
    final response = await getHomeRaw();
    final sections = asJsonList(
      nav(response, [...singleColumnTab, ...sectionList], absent: true),
    );
    final home = browsing_parsers.parseMixedContent(sections);
    final shelf = asJsonDict(
      nav(response, [...singleColumnTab, 'sectionListRenderer'], absent: true),
    );
    if (shelf != null &&
        shelf.containsKey('continuations') &&
        home.length < limit) {
      home.addAll(
        await getContinuations<JsonDict>(
          initial: shelf,
          continuationType: 'sectionListContinuation',
          limit: limit - home.length,
          request: (continuation) =>
              _continuationRequest('FEmusic_home', continuation),
          parse: browsing_parsers.parseMixedContent,
        ),
      );
    }
    return home.take(limit).toList();
  }

  Future<JsonDict> getArtist(
    String channelId, {
    String Function(String)? translate,
  }) async {
    final response = await getArtistRaw(channelId);
    var sections = asJsonList(
      nav(response, [...singleColumnTab, ...sectionList], absent: true),
    );
    if (sections.isEmpty) {
      sections = asJsonList(
        nav(response, [
          ...twoColumnRenderer,
          ...tabContent,
          ...sectionList,
        ], absent: true),
      );
    }
    final header =
        asJsonDict(
          nav(response, [
            'header',
            'musicImmersiveHeaderRenderer',
          ], absent: true),
        ) ??
        asJsonDict(nav(response, headerMusicVisual, absent: true));
    final descriptionRow = asJsonDict(
      findObjectByKey(sections, 'musicDescriptionShelfRenderer'),
    );
    final descriptionShelf = asJsonDict(
      descriptionRow?['musicDescriptionShelfRenderer'],
    );
    final rawDescriptionRuns = nav(
      descriptionShelf,
      ['description', 'runs'],
      absent: true,
    );
    final description = rawDescriptionRuns is List
        ? parseDescriptionRuns(rawDescriptionRuns)['description'] as String?
        : null;
    final radioButton = asJsonDict(
      nav(header, ['startRadioButton', 'buttonRenderer'], absent: true),
    );
    final radioPlaylistId =
        nav(radioButton, navigationPlaylistId, absent: true) ??
        nav(radioButton, navigationWatchPlaylistId, absent: true);
    final shelf = asJsonDict(
      nav(sections, [0, 'musicShelfRenderer'], absent: true),
    );
    final songs = <String, dynamic>{'browseId': null};
    if (shelf != null) {
      songs['browseId'] = nav(shelf, [
        ...title,
        ...navigationBrowseId,
      ], absent: true);
      songs['results'] = playlist_parsers.parsePlaylistItems(
        asJsonList(shelf['contents']),
      );
    }
    final translations = await YTMusicApiTranslations.load(client.hl);
    final parser = YTMusicApiParser(
      translate: translate ?? translations.translate,
    );
    return {
      'artist': nav(header, titleText, absent: true),
      'channelId': channelId,
      'thumbnails': nav(header, thumbnails, absent: true),
      'description': description,
      'radioPlaylistId': radioPlaylistId,
      'songs': songs,
      ...parser.parseChannelContents(sections),
    };
  }

  Future<JsonDict> getAlbum(String browseId) async {
    if (!browseId.startsWith('MPRE')) {
      throw ArgumentError.value(
        browseId,
        'browseId',
        'Album browse IDs must start with MPRE.',
      );
    }
    final response = await getAlbumRaw(browseId);
    final album = parseAlbumHeader2024(response);
    final trackShelf = asJsonDict(
      nav(response, [
        ...twoColumnRenderer,
        'secondaryContents',
        ...sectionListItem,
        ...musicShelf,
      ], absent: true),
    );
    final tracks = playlist_parsers.parsePlaylistItems(
      asJsonList(trackShelf?['contents']),
      isAlbum: true,
    );
    album['tracks'] = tracks;
    final carousels = asJsonList(
      nav(response, [
        ...twoColumnRenderer,
        'secondaryContents',
        ...sectionList,
      ], absent: true),
    );
    for (final value in carousels.skip(1)) {
      final carousel = asJsonDict(
        nav(value, ['musicCarouselShelfRenderer'], absent: true),
      );
      if (carousel == null) {
        continue;
      }
      final key = switch (carousel['itemSize']) {
        'COLLECTION_STYLE_ITEM_SIZE_SMALL' => 'related_recommendations',
        'COLLECTION_STYLE_ITEM_SIZE_MEDIUM' => 'other_versions',
        _ => null,
      };
      if (key != null) {
        album[key] = browsing_parsers.parseContentList(
          asJsonList(carousel['contents']),
          album_parsers.parseAlbum,
        );
      }
    }
    album['duration_seconds'] = sumTotalDuration(album);
    for (final track in tracks) {
      track['album'] = album['title'];
      track['artists'] ??= album['artists'];
    }
    return album;
  }

  Future<JsonList> getArtistAlbums(
    String channelId,
    String params, {
    int? limit,
  }) async {
    final response = await browseRaw(channelId, params: params);
    final result = nav(response, [
      ...singleColumnTab,
      ...sectionListItem,
    ], absent: true);
    final rows = asJsonList(
      nav(result, gridItems, absent: true) ??
          nav(result, carouselContents, absent: true),
    );
    final albums = library_parsers.parseAlbums(rows);
    final grid = asJsonDict(nav(result, ['gridRenderer'], absent: true));
    if (grid != null && grid.containsKey('continuations')) {
      albums.addAll(
        await getContinuations<JsonDict>(
          initial: grid,
          continuationType: 'gridContinuation',
          limit: limit == null ? null : limit - albums.length,
          request: (continuation) => _continuationRequest(
            channelId,
            continuation,
            browseParams: params,
          ),
          parse: library_parsers.parseAlbums,
        ),
      );
    }
    return limit == null ? albums : albums.take(limit).toList();
  }

  Future<JsonList> getUserPlaylists(String channelId, String params) async {
    final response = await browseRaw(channelId, params: params);
    final rows = asJsonList(
      nav(response, [
        ...singleColumnTab,
        ...sectionListItem,
        ...gridItems,
      ], absent: true),
    );
    return browsing_parsers.parseContentList(
      rows,
      browsing_parsers.parsePlaylist,
    );
  }

  Future<JsonList> getUserVideos(
    String channelId,
    String? params, {
    int? limit = 100,
  }) async {
    if (limit != null && limit <= 0) {
      return [];
    }
    final response = await browseRaw(channelId, params: params);
    final result = asJsonDict(nav(response, [
      ...singleColumnTab,
      ...sectionListItem,
    ], absent: true));
    final rows = asJsonList(
      nav(result, gridItems, absent: true) ??
          nav(result, carouselContents, absent: true),
    );
    final videos = browsing_parsers.parseContentList(
      rows,
      browsing_parsers.parseVideo,
    );
    final grid = asJsonDict(nav(result, ['gridRenderer'], absent: true));
    if (grid != null && grid.containsKey('continuations')) {
      videos.addAll(
        await getContinuations<JsonDict>(
          initial: grid,
          continuationType: 'gridContinuation',
          limit: limit == null ? null : limit - videos.length,
          request: (continuation) => _continuationRequest(
            channelId,
            continuation,
            browseParams: params,
          ),
          parse: (continuationRows) => browsing_parsers.parseContentList(
            continuationRows,
            browsing_parsers.parseVideo,
          ),
        ),
      );
    }
    return limit == null ? videos : videos.take(limit).toList();
  }

  Future<JsonDict> _continuationRequest(
    String browseId,
    String params, {
    String? browseParams,
  }) {
    final query = Uri.splitQueryString(
      params.startsWith('&') ? params.substring(1) : params,
    );
    return client.post(
      'browse',
      body: <String, dynamic>{'browseId': browseId, 'params': ?browseParams},
      query: query,
    );
  }

  Future<JsonList> getSongRelated(String browseId) async {
    if (browseId.isEmpty) {
      throw ArgumentError.value(browseId, 'browseId');
    }
    final response = await getSongRelatedRaw(browseId);
    return browsing_parsers.parseMixedContent(
      asJsonList(nav(response, ['contents', ...sectionList], absent: true)),
    );
  }

  Future<JsonDict> getSongCredits(
    String browseId, {
    String Function(String)? translate,
  }) async {
    if (!browseId.startsWith('MPTC')) {
      throw ArgumentError.value(
        browseId,
        'browseId',
        'Song credits browse IDs must start with MPTC.',
      );
    }
    final response = await getSongCreditsRaw(browseId);
    final sections = asJsonList(nav(response, creditsSections, absent: true));
    final translations = await YTMusicApiTranslations.load(client.hl);
    final sectionNames = YTMusicApiParser(
      translate: translate ?? translations.translate,
    ).getSongCreditSectionMap();
    final credits = <String, dynamic>{'other_sections': <JsonDict>[]};
    for (final row in sections) {
      final section = asJsonDict(
        nav(row, ['dismissableDialogContentSectionRenderer'], absent: true),
      );
      if (section == null) {
        continue;
      }
      final name = nav(section, titleText)?.toString() ?? '';
      final runs = asJsonList(nav(section, subtitleRuns, absent: true));
      final data = <String>[
        for (final run in runs)
          if (asJsonDict(run)?['text'] is String)
            asJsonDict(run)!['text'] as String,
      ];
      final entry = <String, dynamic>{'localized_title': name, 'data': data};
      final key = sectionNames[name];
      if (key is String) {
        credits[key] = entry;
      } else {
        (credits['other_sections'] as List<JsonDict>).add(entry);
      }
    }
    return credits;
  }

  Future<YtMusicLyrics?> getLyrics(
    String browseId, {
    bool timestamps = false,
  }) async {
    if (browseId.isEmpty) {
      throw ArgumentError.value(browseId, 'browseId');
    }
    final response = await client.post(
      'browse',
      body: {'browseId': browseId},
      mobileClient: timestamps,
    );
    final timedData = nav(response, timestampedLyrics, absent: true);
    if (timestamps && timedData is Map) {
      final rawLines = timedData['timedLyricsData'];
      if (rawLines is List && rawLines.isNotEmpty) {
        final source = timedData['sourceMessage'] as String?;
        final allTimed = rawLines.every(
          (line) => line is Map && line['cueRange'] is Map,
        );
        if (allTimed) {
          final lines = <YtMusicLyricLine>[];
          for (final raw in rawLines) {
            final cue = asJsonDict(raw['cueRange'])!;
            final metadata = asJsonDict(cue['metadata']);
            lines.add(
              YtMusicLyricLine(
                text: raw['lyricLine'] as String? ?? '',
                startTime:
                    int.tryParse(
                      cue['startTimeMilliseconds']?.toString() ?? '',
                    ) ??
                    0,
                endTime:
                    int.tryParse(
                      cue['endTimeMilliseconds']?.toString() ?? '',
                    ) ??
                    0,
                id: int.tryParse(metadata?['id']?.toString() ?? '') ?? 0,
              ),
            );
          }
          return YtMusicLyrics(
            lyrics: lines,
            source: source,
            hasTimestamps: true,
          );
        }
        return YtMusicLyrics(
          lyrics: rawLines
              .map((line) => asJsonDict(line)?['lyricLine']?.toString() ?? '')
              .join('\n'),
          source: source,
          hasTimestamps: false,
        );
      }
    }
    final lyrics = nav(response, [
      'contents',
      ...sectionListItem,
      'musicDescriptionShelfRenderer',
      'description',
      ...runText,
    ], absent: true);
    if (lyrics is! String) {
      return null;
    }
    final source = nav(response, [
      'contents',
      ...sectionListItem,
      'musicDescriptionShelfRenderer',
      'subheader',
      ...runText,
    ], absent: true);
    return YtMusicLyrics(
      lyrics: lyrics,
      source: source as String?,
      hasTimestamps: false,
    );
  }

  Future<JsonDict> getTasteProfile() async {
    final response = await getTasteProfileRaw();
    final profiles = nav(response, tasteProfileItems, absent: true);
    if (profiles is! List) {
      return {};
    }
    final result = <String, dynamic>{};
    for (final profileList in profiles) {
      final items = nav(profileList, [
        'tastebuilderItemListRenderer',
        'contents',
      ], absent: true);
      if (items is! List) {
        continue;
      }
      for (final item in items) {
        final renderer = nav(item, ['tastebuilderItemRenderer'], absent: true);
        final artist = nav(renderer, tasteProfileArtist, absent: true);
        final name = nav(artist, [0, 'text'], absent: true);
        if (name is String) {
          result[name] = {
            'selectionValue': nav(renderer, [
              'selectionFormValue',
            ], absent: true),
            'impressionValue': nav(renderer, [
              'impressionFormValue',
            ], absent: true),
          };
        }
      }
    }
    return result;
  }

  Future<JsonDict> setTasteProfileRaw(
    List<String> artists,
    JsonDict tasteProfile,
  ) {
    final selectedValues = <String>[];
    final impressionValues = <String>[];
    for (final entry in tasteProfile.entries) {
      final values = asJsonDict(entry.value) ?? {};
      final impression = values['impressionValue'];
      if (impression is String) {
        impressionValues.add(impression);
      }
    }
    for (final artist in artists) {
      final values = asJsonDict(tasteProfile[artist]);
      final selection = values?['selectionValue'];
      if (selection is! String) {
        throw ArgumentError(
          'Artist $artist is not available in the taste profile.',
        );
      }
      selectedValues.add(selection);
    }
    return client.post(
      'browse',
      body: {
        'browseId': 'FEmusic_home',
        'formData': {
          'impressionValues': impressionValues,
          'selectedValues': selectedValues,
        },
      },
    );
  }

  Future<JsonDict> getSongRaw(String videoId, {int? signatureTimestamp}) {
    return client.post(
      'player',
      body: <String, dynamic>{
        'videoId': videoId,
        'playbackContext': <String, dynamic>{
          'contentPlaybackContext': <String, dynamic>{
            'signatureTimestamp': ?signatureTimestamp,
          },
        },
      },
    );
  }
}
