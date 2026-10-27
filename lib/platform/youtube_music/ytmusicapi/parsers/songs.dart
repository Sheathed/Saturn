import '../navigation.dart';
import '../type_alias.dart';
import 'constants.dart';
import 'utils.dart';

bool isLiveRenderer(JsonDict renderer, {dynamic videoType}) {
  if (videoType == 'MUSIC_VIDEO_TYPE_LIVE') {
    return true;
  }
  for (final key in ['badges', 'subtitleBadges']) {
    final badges = renderer[key];
    if (badges is! List) {
      continue;
    }
    for (final value in badges) {
      final badge = asJsonDict(value);
      if (badge?.containsKey('liveBadgeRenderer') == true) {
        return true;
      }
      final inline = asJsonDict(badge?['musicInlineBadgeRenderer']);
      final icon = asJsonDict(inline?['icon']);
      if (icon?['iconType'] == 'MUSIC_LIVE_BADGE' ||
          icon?['iconType'] == 'LIVE') {
        return true;
      }
    }
  }
  return false;
}

JsonList parseSongArtists(JsonDict data, int index) {
  final column = getFlexColumnItem(data, index);
  final runs = nav(column, ['text', 'runs'], absent: true);
  if (runs is! List) {
    return [];
  }
  final artists = <JsonDict>[];
  for (final value in runs) {
    final item = asJsonDict(value);
    if (item != null && item.containsKey('navigationEndpoint')) {
      artists.add({
        'name': item['text'],
        'id': nav(item, navigationBrowseId, absent: true),
      });
    }
  }
  return artists;
}

String? parseViews(String text) {
  var value = text;
  var prefixed = false;
  if (!RegExp('[a-zA-Z]').hasMatch(value)) {
    final match = RegExp(
      r'^\D*?[\s:\uff1a\u200e-\u200f\u202a-\u202e]',
    ).firstMatch(value);
    if (match != null) {
      value = value.substring(match.end);
      prefixed = true;
    }
  }
  if (!RegExp(r'^\d').hasMatch(value)) {
    return null;
  }
  if (!prefixed &&
      value.codeUnits.every((unit) => unit < 128) &&
      !value.contains(' ')) {
    return null;
  }
  final head = value.split(' ').first.split('\u00a0');
  return head.take(2).join('\u00a0');
}

JsonDict parseSongRun(JsonDict run) {
  final text = run['text']?.toString() ?? '';
  if (run.containsKey('navigationEndpoint')) {
    final item = {
      'name': text,
      'id': nav(run, navigationBrowseId, absent: true),
    };
    final id = item['id']?.toString() ?? '';
    return {
      'type': id.startsWith('MPRE') || id.contains('release_detail')
          ? 'album'
          : 'artist',
      'data': item,
    };
  }
  if (RegExp(r'^(\d+:)*\d+:\d+$').hasMatch(text)) {
    return {'type': 'duration', 'data': text};
  }
  if (RegExp(r'^\d{4}$').hasMatch(text)) {
    return {'type': 'year', 'data': text};
  }
  final views = parseViews(text);
  if (views != null) {
    return {'type': 'views', 'data': views};
  }
  return {
    'type': 'artist',
    'data': {'name': text, 'id': null},
  };
}

JsonDict parseSongRuns(List<dynamic> sourceRuns, {bool skipTypeSpec = false}) {
  var runs = sourceRuns;
  if (skipTypeSpec && runs.length > 2) {
    final first = asJsonDict(runs[0]) ?? {};
    final second = asJsonDict(runs[1]) ?? {};
    final third = asJsonDict(runs[2]) ?? {};
    final sep = second['text']?.toString().trim();
    final isSeparator = sep == '•' || second['text'] == dotSeparatorRun['text'];
    if (!first.containsKey('navigationEndpoint') &&
        isSeparator &&
        (parseSongRun(first)['type'] == 'artist') &&
        [
          'artist',
          'duration',
          'views',
          'year',
        ].contains(parseSongRun(third)['type'])) {
      runs = runs.sublist(2);
    }
  }
  final parsed = <String, dynamic>{};
  for (var i = 0; i < runs.length; i += 2) {
    final run = asJsonDict(runs[i]);
    if (run == null) {
      continue;
    }
    final result = parseSongRun(run);
    final data = result['data'];
    switch (result['type']) {
      case 'album':
        parsed['album'] = data;
        break;
      case 'artist':
        (parsed['artists'] ??= <JsonDict>[]).add(data);
        break;
      case 'views':
        parsed['views'] = data;
        break;
      case 'duration':
        parsed['duration'] = data;
        parsed['duration_seconds'] = parseDuration(data as String?);
        break;
      case 'year':
        parsed['year'] = data;
        break;
    }
  }
  return parsed;
}

JsonDict? parseSongAlbum(JsonDict data, int index) {
  final column = getFlexColumnItem(data, index);
  if (column == null) {
    return null;
  }
  return {
    'name': getItemText(data, index),
    'id': nav(column, [...textRun, ...navigationBrowseId], absent: true),
  };
}

/// Port of ytmusicapi.parsers.songs.parse_song for carousel song renderers.
JsonDict parseSong(JsonDict renderer) {
  final runs = nav(renderer, subtitleRuns, absent: true);
  final videoType = nav(renderer, [
    'thumbnailOverlay',
    'musicItemThumbnailOverlayRenderer',
    'content',
    'musicPlayButtonRenderer',
    'playNavigationEndpoint',
    ...watchEndpointVideoType,
  ], absent: true);
  final song = <String, dynamic>{
    'title': nav(renderer, titleText),
    'videoId': nav(renderer, navigationVideoId),
    'playlistId': nav(renderer, navigationPlaylistId, absent: true),
    'videoType': videoType,
    'isLive': isLiveRenderer(renderer, videoType: videoType),
    'isExplicit': nav(renderer, badgeLabel, absent: true) != null,
    'thumbnails': nav(renderer, [
      'thumbnailRenderer',
      'musicThumbnailRenderer',
      ...thumbnail,
    ], absent: true),
    ...parseSongMenuData(renderer),
  };
  if (runs is List) {
    song.addAll(parseSongRuns(runs, skipTypeSpec: true));
  }
  return song;
}

/// Port of ytmusicapi.parsers.songs.parse_song_flat for responsive rows.
JsonDict parseSongFlat(JsonDict renderer, {bool withPlaylistId = false}) {
  final flexColumns = renderer['flexColumns'] is List
      ? renderer['flexColumns'] as List
      : const [];
  final columns = [
    for (var i = 0; i < flexColumns.length; i++) getFlexColumnItem(renderer, i),
  ];
  final first = columns.isNotEmpty ? columns.first : null;
  final videoId =
      nav(first, [...textRun, ...navigationVideoId], absent: true) ??
      nav(renderer, [
        'overlay',
        'musicItemThumbnailOverlayRenderer',
        'content',
        'musicPlayButtonRenderer',
        'playNavigationEndpoint',
        ...watchVideoId,
      ], absent: true);
  final videoType = nav(renderer, [
    'overlay',
    'musicItemThumbnailOverlayRenderer',
    'content',
    'musicPlayButtonRenderer',
    'playNavigationEndpoint',
    ...watchEndpointVideoType,
  ], absent: true);
  final song = <String, dynamic>{
    'title': nav(first, textRunText, absent: true),
    'videoId': videoId,
    'videoType': videoType,
    'isLive': isLiveRenderer(renderer, videoType: videoType),
    'thumbnails': nav(renderer, [
      'thumbnail',
      'musicThumbnailRenderer',
      ...thumbnail,
    ], absent: true),
    'isExplicit':
        nav(renderer, [
          'badges',
          0,
          'musicInlineBadgeRenderer',
          'accessibilityData',
          'accessibilityData',
          'label',
        ], absent: true) !=
        null,
  };
  if (withPlaylistId) {
    song['playlistId'] =
        nav(first, [...textRun, ...navigationPlaylistId], absent: true) ??
        nav(renderer, [
          'overlay',
          'musicItemThumbnailOverlayRenderer',
          'content',
          'musicPlayButtonRenderer',
          'playNavigationEndpoint',
          ...watchPlaylistId,
        ], absent: true);
  }
  final secondRuns = nav(
    columns.length > 1 ? columns[1] : null,
    textRuns,
    absent: true,
  );
  if (secondRuns is List) {
    song.addAll(parseSongRuns(secondRuns, skipTypeSpec: true));
  }
  if (columns.length > 2 && columns[2] != null) {
    final run = nav(columns[2], textRun, absent: true);
    if (run is Map &&
        asJsonDict(run)?.containsKey('navigationEndpoint') == true) {
      song['album'] = {
        'name': nav(columns[2], textRunText, absent: true),
        'id': nav(columns[2], [
          ...textRun,
          ...navigationBrowseId,
        ], absent: true),
      };
    }
  }
  final fixed = getFixedColumnItem(renderer, 0);
  final durationRuns = nav(fixed, textRuns, absent: true);
  if (durationRuns is List && durationRuns.isNotEmpty) {
    final duration = asJsonDict(durationRuns.first)?['text']?.toString();
    song['duration'] = duration;
    song['duration_seconds'] = parseDuration(duration);
  }
  return song;
}

/// Port of ytmusicapi.parsers.songs.parse_song_menu_data.
JsonDict parseSongMenuData(JsonDict data) {
  final menuData = nav(data, menuItems, absent: true);
  if (menuData is! List) {
    return {};
  }
  final result = <String, dynamic>{};
  for (final itemValue in menuData) {
    final item = asJsonDict(itemValue);
    if (item == null) {
      continue;
    }
    final menuItem =
        asJsonDict(
          nav(item, ['toggleMenuServiceItemRenderer'], absent: true),
        ) ??
        asJsonDict(nav(item, ['menuServiceItemRenderer'], absent: true));
    if (menuItem == null) {
      continue;
    }
    result.putIfAbsent('inLibrary', () => false);
    result.putIfAbsent('pinnedToListenAgain', () => false);
    final icon =
        nav(menuItem, ['defaultIcon', 'iconType'], absent: true) ??
        nav(menuItem, iconType, absent: true);
    final toggled = menuItem['isToggled'] == true;
    String? token(String endpoint) =>
        nav(menuItem, [endpoint, ...feedbackToken], absent: true) as String?;
    switch (icon) {
      case 'KEEP':
        result['pinnedToListenAgain'] = toggled;
        result['listenAgainFeedbackTokens'] = {
          'pin': token('defaultServiceEndpoint'),
          'unpin': token('toggledServiceEndpoint'),
        };
        break;
      case 'KEEP_OFF':
        result['pinnedToListenAgain'] = true;
        result['listenAgainFeedbackTokens'] = {
          'pin': token('toggledServiceEndpoint'),
          'unpin': token('defaultServiceEndpoint'),
        };
        break;
      case 'BOOKMARK_BORDER':
        result['inLibrary'] = toggled;
        result['feedbackTokens'] = {
          'add': token('defaultServiceEndpoint'),
          'remove': token('toggledServiceEndpoint'),
        };
        break;
      case 'BOOKMARK':
        result['inLibrary'] = true;
        result['feedbackTokens'] = {
          'add': token('toggledServiceEndpoint'),
          'remove': token('defaultServiceEndpoint'),
        };
        break;
      case 'REMOVE_FROM_HISTORY':
        result['feedbackToken'] = token('serviceEndpoint');
        break;
    }
  }
  return result;
}

String parseLikeStatus(JsonDict service) {
  const statuses = ['LIKE', 'INDIFFERENT'];
  final status = nav(service, ['likeEndpoint', 'status']);
  final index = statuses.indexOf(status?.toString() ?? '');
  if (index < 0) {
    throw StateError('Unknown YouTube Music like status: $status');
  }
  return statuses[(index - 1 + statuses.length) % statuses.length];
}
