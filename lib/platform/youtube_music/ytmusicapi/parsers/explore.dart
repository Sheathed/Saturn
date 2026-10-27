import '../navigation.dart';
import '../type_alias.dart';
import 'podcasts.dart';
import 'songs.dart';
import 'utils.dart';

const _trends = {
  'ARROW_DROP_UP': 'up',
  'ARROW_DROP_DOWN': 'down',
  'ARROW_CHART_NEUTRAL': 'neutral',
  'TRENDING_UP': 'up',
  'TRENDING_DOWN': 'down',
  'ARROW_UP': 'up',
  'ARROW_DOWN': 'down',
  'NON_MOVER': 'neutral',
  'UNCHANGED': 'neutral',
};

JsonDict parseRanking(JsonDict data, {bool absent = false}) {
  final customIndex = nav(data, [
    'customIndexColumn',
    'musicCustomIndexColumnRenderer',
  ], absent: true) ?? (data['musicCustomIndexColumnRenderer'] != null ? data : null);

  if (customIndex is! Map) {
    if (absent) return {};
    return {'rank': null, 'trend': null, 'variation': null};
  }
  final customDict = asJsonDict(
    customIndex['musicCustomIndexColumnRenderer'] ?? customIndex,
  ) ?? {};

  final rawIcon = nav(customDict, iconType, absent: true);
  final icon = rawIcon is String ? rawIcon : null;
  final rankText = nav(customDict, textRunText, absent: true);
  final colorStyle = customDict['iconColorStyle'] as String?;
  final label = (nav(customDict, ['accessibilityData', 'accessibilityData', 'label'], absent: true) ??
      nav(customDict, ['accessibilityData', 'label'], absent: true)) as String?;

  String? trend = icon != null ? _trends[icon] : null;
  int? variation;

  if (icon == 'ARROW_DROP_UP' ||
      icon == 'ARROW_UP' ||
      (icon != null && icon.contains('TRENDING_UP')) ||
      (colorStyle != null && colorStyle.contains('GREEN'))) {
    trend = 'up';
    variation = 1;
  } else if (icon == 'ARROW_DROP_DOWN' ||
      icon == 'ARROW_DOWN' ||
      (icon != null && icon.contains('TRENDING_DOWN')) ||
      (colorStyle != null && colorStyle.contains('RED'))) {
    trend = 'down';
    variation = -1;
  } else if (icon == 'ARROW_CHART_NEUTRAL' ||
      icon == 'NON_MOVER' ||
      icon == 'UNCHANGED' ||
      (colorStyle != null &&
          (colorStyle.contains('GREY') || colorStyle.contains('GRAY')))) {
    trend = 'neutral';
    variation = 0;
  }

  if (label != null) {
    final lower = label.toLowerCase();
    final deltaMatch = RegExp(
      r'\b(?:up|down|increased|decreased)\s*by\s*(\d+)\b',
    ).firstMatch(lower);
    if (deltaMatch != null) {
      final amt = int.tryParse(deltaMatch.group(1)!);
      if (amt != null) {
        if (lower.contains('down') || lower.contains('decreased')) {
          variation = -amt;
          trend = 'down';
        } else {
          variation = amt;
          trend = 'up';
        }
      }
    } else if (variation == null) {
      if (lower.contains('increased') ||
          lower.contains('ascend') ||
          lower.contains('up')) {
        trend = 'up';
        variation = 1;
      } else if (lower.contains('decreased') ||
          lower.contains('descend') ||
          lower.contains('down')) {
        trend = 'down';
        variation = -1;
      } else if (lower.contains('stayed') ||
          lower.contains('neutral') ||
          lower.contains('same') ||
          lower.contains('unchange')) {
        trend = 'neutral';
        variation = 0;
      }
    }
  }

  final result = <String, dynamic>{
    'rank': rankText,
    'trend': trend,
  };
  if (variation != null) {
    result['variation'] = variation;
  }
  return result;
}

JsonDict parseChartSong(JsonDict data) {
  final episode =
      nav(data, [
        ...playNavigationEndpoint,
        ...watchEndpointVideoType,
      ], absent: true) ==
      'MUSIC_VIDEO_TYPE_PODCAST_EPISODE';
  final parsed = episode
      ? parseEpisodeFlat(data)
      : parseSongFlat(data, withPlaylistId: true);
  parsed.addAll(parseRanking(data));
  return parsed;
}

JsonDict parseTrendingItem(JsonDict data) {
  final episode =
      nav(data, [...playNavigationEndpoint, ...watchEndpointVideoType]) ==
      'MUSIC_VIDEO_TYPE_PODCAST_EPISODE';
  return episode
      ? parseEpisodeFlat(data)
      : parseSongFlat(data, withPlaylistId: true);
}

JsonDict parseChartPlaylist(JsonDict data) => {
  'title': nav(data, titleText),
  'playlistId': (nav(data, [...title, ...navigationBrowseId]) as String)
      .replaceFirst(RegExp(r'^VL'), ''),
  'thumbnails': nav(data, thumbnailRenderer, absent: true),
};

JsonDict parseChartEpisode(JsonDict data) {
  final episode = parseEpisode(data)..remove('index');
  episode['podcast'] = parseIdName(
    asJsonDict(nav(data, ['secondTitle', 'runs', 0], absent: true)),
  );
  episode['duration'] = nav(data, [
    'playbackProgress',
    'musicPlaybackProgressRenderer',
    ...['durationText', 'runs', 1, 'text'],
  ], absent: true);
  return episode;
}

JsonDict parseChartArtist(JsonDict data) {
  final subscriberText = getItemText(data, 1);
  final parsed = <String, dynamic>{
    'title': getItemText(data, 0),
    'browseId': nav(data, navigationBrowseId),
    'subscribers': subscriberText?.split(' ').first,
    'thumbnails': nav(data, thumbnails, absent: true),
  };
  parsed.addAll(parseRanking(data, absent: true));
  return parsed;
}
