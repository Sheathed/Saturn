import '../navigation.dart';
import '../helpers.dart';
import '../type_alias.dart';
import 'albums.dart';
import 'songs.dart';
import 'utils.dart';
import 'artists.dart';

const allResultTypes = [
  'album',
  'artist',
  'playlist',
  'song',
  'video',
  'station',
  'profile',
  'podcast',
  'episode',
];

/// Port of ytmusicapi.parsers.search.get_search_result_type.
String? getSearchResultType(
  String? localizedType,
  List<String> localizedTypes,
) {
  if (localizedType == null || localizedType.isEmpty) {
    return null;
  }
  final index = localizedTypes.indexOf(localizedType.toLowerCase());
  return index < 0 ? 'album' : allResultTypes[index];
}

/// Port of the result classification and common metadata in parse_search_result.
JsonDict parseSearchResult(
  JsonDict data, {
  String? resultType,
  String? category,
}) {
  final videoType = nav(data, [
    ...playButton,
    'playNavigationEndpoint',
    ...watchEndpointVideoType,
  ], absent: true);
  const browsePrefixes = {
    'VM': 'playlist',
    'RD': 'playlist',
    'VL': 'playlist',
    'MPLA': 'artist',
    'MPRE': 'album',
    'MPSP': 'podcast',
    'MPED': 'episode',
    'UC': 'artist',
  };
  var kind = resultType;
  if (kind == null) {
    final browseId =
        nav(data, navigationBrowseId, absent: true)?.toString() ?? '';
    for (final entry in browsePrefixes.entries) {
      if (browseId.startsWith(entry.key)) {
        kind = entry.value;
        break;
      }
    }
    kind ??= videoType == 'MUSIC_VIDEO_TYPE_ATV'
        ? 'song'
        : (videoType == 'MUSIC_VIDEO_TYPE_PODCAST_EPISODE'
              ? 'episode'
              : 'video');
  }
  final result = <String, dynamic>{'category': category, 'resultType': kind};
  final defaultOffset = kind == 'album' ? 2 : 0;
  if (kind != 'artist') {
    result['title'] = getItemText(data, 0);
  }
  if (kind == 'artist') {
    result['artist'] = getItemText(data, 0);
    final menuValues = nav(data, menuItems, absent: true);
    if (menuValues is List) {
      for (final value in menuValues) {
        final item = asJsonDict(asJsonDict(value)?[menuNavigationItem]);
        final icon = nav(item, iconType, absent: true);
        final key = icon == 'MUSIC_SHUFFLE'
            ? 'shuffleId'
            : (icon == 'MIX' ? 'radioId' : null);
        if (key != null) {
          result[key] =
              nav(item, [
                'navigationEndpoint',
                'watchPlaylistEndpoint',
                'playlistId',
              ], absent: true) ??
              nav(item, [
                'navigationEndpoint',
                'watchEndpoint',
                'playlistId',
              ], absent: true);
        }
      }
    }
  } else if (kind == 'album') {
    result['type'] = getItemText(data, 1);
    final play = nav(data, [
      ...playButton,
      'playNavigationEndpoint',
    ], absent: true);
    result['playlistId'] = parseAlbumPlaylistIdIfExists(play);
  } else if (kind == 'playlist') {
    final runs = nav(getFlexColumnItem(data, 1), textRuns, absent: true);
    final runList = runs is List ? runs : <dynamic>[];
    final hasAuthor = runList.length == defaultOffset + 3;
    final infoText = (getItemText(data, 1, runIndex: hasAuthor ? 2 : 0) ?? '')
        .split(' ');
    result['itemCount'] = infoText.length >= 2 && infoText[1] == 'songs'
        ? infoText.first
        : null;
    if (result['itemCount'] is String &&
        RegExp(r'^\d+$').hasMatch(result['itemCount'] as String)) {
      result['itemCount'] = toInt(result['itemCount'] as String);
    }
    result['author'] = hasAuthor
        ? getItemText(data, 1, runIndex: defaultOffset)
        : null;
    final playlistMenu = nav(data, [
      ...menuItems,
      0,
      menuNavigationItem,
      ...navigationWatchPlaylistId,
    ], absent: true);
    result['playlistId'] = playlistMenu;
  } else if (kind == 'station') {
    result['videoId'] = nav(data, navigationVideoId);
    result['playlistId'] = nav(data, navigationPlaylistId);
  } else if (kind == 'profile') {
    result['name'] = getItemText(data, 1, runIndex: 2, noneIfAbsent: true);
  } else if (kind == 'song') {
    result['album'] = null;
    result.addAll(parseSongMenuData(data));
  } else if (kind == 'upload') {
    final browseId = nav(data, navigationBrowseId, absent: true);
    if (browseId == null) {
      final firstRuns = nav(getFlexColumnItem(data, 0), textRuns, absent: true);
      final secondRuns = nav(
        getFlexColumnItem(data, 1),
        textRuns,
        absent: true,
      );
      if (firstRuns is List && firstRuns.isNotEmpty) {
        result['videoId'] = nav(
          firstRuns.first,
          navigationVideoId,
          absent: true,
        );
        result['playlistId'] = nav(
          firstRuns.first,
          navigationPlaylistId,
          absent: true,
        );
      }
      if (secondRuns is List) {
        result.addAll(parseSongRuns(secondRuns));
      }
      result['resultType'] = 'song';
    } else {
      result['browseId'] = browseId;
      result['resultType'] = browseId.toString().contains('artist')
          ? 'artist'
          : 'album';
      final titleRun = getFlexColumnItem(data, 1);
      final runs = nav(titleRun, textRuns, absent: true);
      if (runs is List && runs.length > 1) {
        result['artist'] = asJsonDict(runs[1])?['text'];
      }
    }
  }
  if (['song', 'video', 'episode'].contains(kind)) {
    result['videoId'] = nav(data, [
      ...playButton,
      'playNavigationEndpoint',
      ...watchVideoId,
    ], absent: true);
    result['videoType'] = videoType;
    result['isLive'] = isLiveRenderer(data, videoType: videoType);
    result['isAvailable'] =
        data['musicItemRendererDisplayPolicy'] !=
        'MUSIC_ITEM_RENDERER_DISPLAY_POLICY_GREY_OUT';
  }
  if (['song', 'video', 'album'].contains(kind)) {
    final column1 = getFlexColumnItem(data, 1);
    final firstRuns = nav(column1, textRuns, absent: true);
    if (firstRuns is List) {
      final combinedRuns = <dynamic>[...firstRuns];
      final column2 = nav(getFlexColumnItem(data, 2), textRuns, absent: true);
      if (column2 is List) {
        combinedRuns.addAll([
          {'text': ''},
          ...column2,
        ]);
      }
      result['duration'] = null;
      result['year'] = null;
      result.addAll(parseSongRuns(combinedRuns, skipTypeSpec: true));
    }
  }
  if (['artist', 'album', 'playlist', 'profile', 'podcast'].contains(kind)) {
    result['browseId'] = nav(data, navigationBrowseId, absent: true);
  }
  if (kind == 'song' || kind == 'album') {
    result['isExplicit'] = nav(data, badgeLabel, absent: true) != null;
  }
  if (kind == 'episode') {
    final column = getFlexColumnItem(data, 1);
    final rawRuns = nav(column, textRuns, absent: true);
    final episodeRuns = rawRuns is List
        ? rawRuns.skip(defaultOffset).toList()
        : <dynamic>[];
    final hasDate = episodeRuns.length > 1;
    result['live'] =
        nav(data, ['badges', 0, 'liveBadgeRenderer'], absent: true) != null;
    if (hasDate) {
      result['date'] = asJsonDict(episodeRuns.first)?['text'];
    }
    final podcastIndex = hasDate ? 2 : 0;
    if (episodeRuns.length > podcastIndex) {
      result['podcast'] = parseIdName(asJsonDict(episodeRuns[podcastIndex]));
    }
  }
  result['thumbnails'] = nav(data, thumbnails, absent: true);
  return result;
}

JsonList parseSearchResults(
  List<dynamic> rows, {
  String? resultType,
  String? category,
}) {
  final parsed = <JsonDict>[];
  for (final value in rows) {
    final renderer = asJsonDict(asJsonDict(value)?[responsiveItem]);
    if (renderer != null) {
      parsed.add(
        parseSearchResult(renderer, resultType: resultType, category: category),
      );
    }
  }
  return parsed;
}

String? getSearchParams({
  String? filter,
  String? scope,
  bool ignoreSpelling = false,
}) {
  const filterCodes = {
    'songs': 'II',
    'videos': 'IQ',
    'albums': 'IY',
    'artists': 'Ig',
    'playlists': 'Io',
    'profiles': 'JY',
    'podcasts': 'JQ',
    'episodes': 'JI',
  };
  if (filter == null && scope == null && !ignoreSpelling) {
    return null;
  }
  var params = '';
  var param1 = 'EgWKAQ';
  var param2 = '';
  var param3 = '';
  if (scope == 'uploads') {
    return 'agIYAw%3D%3D';
  }
  if (scope == 'library') {
    if (filter != null) {
      param2 =
          filterCodes[filter] ?? (throw ArgumentError.value(filter, 'filter'));
      param3 = 'AWoKEAUQCRADEAoYBA%3D%3D';
    } else {
      return 'agIYBA%3D%3D';
    }
  }
  if (scope == null && filter != null) {
    if (filter == 'playlists') {
      return 'Eg-KAQwIABAAGAAgACgB${ignoreSpelling ? 'MABCAggBagoQBBADEAkQBRAK' : 'MABqChAEEAMQCRAFEAo%3D'}';
    }
    if (filter == 'featured_playlists' || filter == 'community_playlists') {
      param1 = 'EgeKAQQoA';
      param2 = filter == 'featured_playlists' ? 'Dg' : 'EA';
      param3 = ignoreSpelling
          ? 'BQgIIAWoMEA4QChADEAQQCRAF'
          : 'BagwQDhAKEAMQBBAJEAU%3D';
    } else {
      param2 =
          filterCodes[filter] ?? (throw ArgumentError.value(filter, 'filter'));
      param3 = ignoreSpelling
          ? 'AUICCAFqDBAOEAoQAxAEEAkQBQ%3D%3D'
          : 'AWoMEA4QChADEAQQCRAF';
    }
  }
  if (scope == null && filter == null && ignoreSpelling) {
    return 'EhGKAQ4IARABGAEgASgAOAFAAUICCAE%3D';
  }
  return params.isNotEmpty ? params : '$param1$param2$param3';
}

List<dynamic> parseSearchSuggestions(
  JsonDict results, {
  bool detailedRuns = false,
}) {
  final rows = nav(results, [
    'contents',
    0,
    'searchSuggestionsSectionRenderer',
    'contents',
  ], absent: true);
  if (rows is! List) {
    return [];
  }
  final suggestions = <dynamic>[];
  for (final rowValue in rows) {
    final row = asJsonDict(rowValue);
    if (row == null) {
      continue;
    }
    final fromHistory = row.containsKey('historySuggestionRenderer');
    final suggestion = asJsonDict(
      row[fromHistory
          ? 'historySuggestionRenderer'
          : 'searchSuggestionRenderer'],
    );
    if (suggestion == null) {
      continue;
    }
    final query = nav(suggestion, [
      'navigationEndpoint',
      'searchEndpoint',
      'query',
    ], absent: true);
    final runs = nav(suggestion, ['suggestion', 'runs'], absent: true);
    final token = nav(suggestion, [
      'serviceEndpoint',
      ...feedbackToken,
    ], absent: true);
    if (detailedRuns) {
      suggestions.add({
        'text': query,
        'runs': runs,
        'fromHistory': fromHistory && token != null,
        'feedbackToken': token,
      });
    } else if (query is String) {
      suggestions.add(query);
    }
  }
  return suggestions;
}

JsonDict parseTopResult(JsonDict data, List<String> localizedTypes) {
  final localizedType = nav(data, subtitle, absent: true)?.toString();
  final resultType = getSearchResultType(localizedType, localizedTypes);
  final category =
      nav(data, [
        'header',
        'musicCardShelfHeaderBasicRenderer',
        ...titleText,
      ], absent: true) ??
      'Top result';
  final result = <String, dynamic>{
    'category': category,
    'resultType': resultType,
  };
  final titleValue = nav(data, titleText, absent: true);
  final subtitleValues = nav(data, subtitleRuns, absent: true);
  final runs = subtitleValues is List ? subtitleValues : <dynamic>[];
  if (resultType == 'artist') {
    final subscribers = nav(data, [
      'subtitle',
      'runs',
      2,
      'text',
    ], absent: true);
    if (subscribers is String) {
      result['subscribers'] = subscribers.split(' ').first;
    }
    final titleRunsValue = nav(data, ['title', 'runs'], absent: true);
    if (titleRunsValue is List) {
      result.addAll(parseSongRuns(titleRunsValue));
    }
  }
  if (resultType == 'song' || resultType == 'video' || resultType == 'album') {
    result['videoId'] = nav(data, ['onTap', ...watchVideoId], absent: true);
    result['videoType'] = nav(data, [
      'onTap',
      ...watchEndpointVideoType,
    ], absent: true);
    result['title'] = titleValue;
    result.addAll(parseSongRuns(runs.skip(2).toList()));
  }
  if (resultType == 'album') {
    result['browseId'] = nav(data, [
      ...title,
      ...navigationBrowseId,
    ], absent: true);
    result['playlistId'] = nav(data, [
      'buttons',
      0,
      'buttonRenderer',
      'command',
      'watchPlaylistEndpoint',
      'playlistId',
    ], absent: true);
  }
  if (resultType == 'playlist') {
    result['playlistId'] = nav(data, [
      ...menuItems,
      0,
      menuNavigationItem,
      ...navigationWatchPlaylistId,
    ]);
    result['title'] = titleValue;
    result['author'] = parseArtistsRuns(runs.skip(2).toList());
  }
  if (resultType == 'episode') {
    result['title'] = titleValue;
    result['videoId'] = nav(data, [
      ...playButton,
      'playNavigationEndpoint',
      ...watchVideoId,
    ]);
    result['videoType'] = nav(data, [
      ...playButton,
      'playNavigationEndpoint',
      ...watchEndpointVideoType,
    ]);
    final episodeRuns = runs.skip(2).toList();
    if (episodeRuns.isNotEmpty) {
      result['date'] = asJsonDict(episodeRuns.first)?['text'];
    }
    if (episodeRuns.length > 2) {
      result['podcast'] = parseIdName(asJsonDict(episodeRuns[2]));
    }
  }
  result['thumbnails'] = nav(data, thumbnails, absent: true);
  return result;
}
