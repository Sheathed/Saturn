import '../navigation.dart';
import '../type_alias.dart';
import 'utils.dart';
import 'songs.dart';

class DescriptionElement {
  const DescriptionElement(this.text);
  final String text;
  @override
  String toString() => text;
}

class DescriptionLink extends DescriptionElement {
  const DescriptionLink(super.text, this.url);
  final String url;
}

class DescriptionTimestamp extends DescriptionElement {
  const DescriptionTimestamp(super.text, this.seconds);
  final int? seconds;
}

class ParsedDescription {
  const ParsedDescription(this.elements);
  final List<DescriptionElement> elements;
  String get text => elements.join();

  factory ParsedDescription.fromRuns(List<dynamic> runs) {
    final elements = <DescriptionElement>[];
    for (final value in runs) {
      final run = asJsonDict(value);
      if (run == null) {
        continue;
      }
      final text = run['text']?.toString() ?? '';
      final endpoint = asJsonDict(
        nav(run, ['navigationEndpoint'], absent: true),
      );
      if (endpoint == null) {
        elements.add(DescriptionElement(text));
      } else if (endpoint.containsKey('urlEndpoint')) {
        final url = nav(endpoint, ['urlEndpoint', 'url'], absent: true);
        elements.add(
          url is String ? DescriptionLink(text, url) : DescriptionElement(text),
        );
      } else if (endpoint.containsKey('watchEndpoint')) {
        elements.add(
          DescriptionTimestamp(
            text,
            nav(endpoint, ['watchEndpoint', 'startTimeSeconds'], absent: true)
                as int?,
          ),
        );
      } else {
        elements.add(DescriptionElement(text));
      }
    }
    return ParsedDescription(elements);
  }
}

const _progressRenderer = ['musicPlaybackProgressRenderer'];
const _durationText = ['durationText', 'runs', 1, 'text'];

JsonDict parseBaseHeader(JsonDict header) {
  final strapline = nav(header, ['straplineTextOne'], absent: true);
  final author = {
    'name': nav(strapline, ['runs', 0, 'text'], absent: true),
    'id': nav(strapline, ['runs', 0, ...navigationBrowseId], absent: true),
  };
  return {
    'author': author['name'] == null ? null : author,
    'title': nav(header, titleText),
    'thumbnails': nav(header, thumbnails, absent: true),
  };
}

JsonDict parsePodcastHeader(JsonDict header) => {
  ...parseBaseHeader(header),
  'description': nav(header, [
    'description',
    ...descriptionShelf,
  ], absent: true),
  'saved': nav(header, [
    'buttons',
    1,
    'toggleButtonRenderer',
    'isToggled',
  ], absent: true),
};

JsonDict parseEpisodeHeader(JsonDict header) {
  final progress = nav(header, ['progress', ..._progressRenderer]);
  String? playlistId;
  final buttons = nav(header, [
    'buttons',
    -1,
    'menuRenderer',
    'items',
  ], absent: true);
  if (buttons is List) {
    for (final value in buttons) {
      final item = asJsonDict(value);
      if (nav(item, [
            'menuNavigationItemRenderer',
            ...iconType,
          ], absent: true) ==
          'BROADCAST') {
        playlistId = nav(item, [
          'menuNavigationItemRenderer',
          ...navigationBrowseId,
        ], absent: true);
      }
    }
  }
  return {
    ...parseBaseHeader(header),
    'date': nav(header, subtitle, absent: true),
    'duration': nav(progress, _durationText, absent: true),
    'progressPercentage': nav(progress, [
      'playbackProgressPercentage',
    ], absent: true),
    'saved':
        nav(header, [
          'buttons',
          0,
          'toggleButtonRenderer',
          'isToggled',
        ], absent: true) ??
        false,
    'playlistId': playlistId,
  };
}

JsonDict parseEpisode(JsonDict data) {
  final progress = nav(data, [
    'playbackProgress',
    ..._progressRenderer,
  ], absent: true);
  final lengthRuns = nav(data, ['lengthText', 'runs'], absent: true);
  final lengthFromRuns = lengthRuns is List
      ? lengthRuns
            .map((run) => asJsonDict(run)?['text']?.toString() ?? '')
            .join(' ')
      : null;
  final duration =
      nav(progress, _durationText, absent: true) ??
      nav(progress, ['durationText', 'simpleText'], absent: true) ??
      nav(data, ['lengthText', 'simpleText'], absent: true) ??
      lengthFromRuns;
  final progressPercentage =
      nav(progress, ['playbackProgressPercentage'], absent: true) ??
      nav(data, [
        'thumbnailOverlay',
        'musicItemThumbnailOverlayRenderer',
        'content',
        'musicPlayButtonRenderer',
        'thumbnailOverlayResumePlaybackRenderer',
        'percentDurationWatched',
      ], absent: true);
  final descriptionRuns = nav(data, ['description', 'runs'], absent: true);
  final descriptionText = descriptionRuns is List
      ? descriptionRuns
            .map((run) => asJsonDict(run)?['text']?.toString() ?? '')
            .join()
      : nav(data, ['description', 'simpleText'], absent: true) ??
            nav(data, description, absent: true);
  final descriptionFromShelf = nav(data, [
    'description',
    ...descriptionShelf,
  ], absent: true);
  final subtitleRuns = nav(data, ['subtitle', 'runs'], absent: true);
  final subtitleText = subtitleRuns is List
      ? subtitleRuns
            .map((run) => asJsonDict(run)?['text']?.toString() ?? '')
            .join()
      : nav(data, subtitle, absent: true);
  final podcast = parseEpisodePodcast(data);
  return {
    'index': nav(data, ['onTap', 'watchEndpoint', 'index'], absent: true),
    'title': nav(data, titleText),
    'description': descriptionText ?? descriptionFromShelf,
    'duration': duration,
    'progressPercentage': progressPercentage,
    'videoId': nav(data, ['onTap', ...watchVideoId], absent: true),
    'podcast': ?podcast,
    'browseId': nav(data, [...title, ...navigationBrowseId], absent: true),
    'videoType': nav(data, [
      'onTap',
      'watchEndpoint',
      'watchEndpointMusicSupportedConfigs',
      'watchEndpointMusicConfig',
      'musicVideoType',
    ], absent: true),
    'date': subtitleText,
    'thumbnails': nav(data, thumbnails, absent: true),
  };
}

JsonDict? parseEpisodePodcast(JsonDict data) {
  final secondTitleRuns = nav(data, ['secondTitle', 'runs'], absent: true);
  if (secondTitleRuns is! List) {
    return null;
  }
  JsonDict? fallback;
  for (final value in secondTitleRuns) {
    final run = asJsonDict(value);
    if (run == null) {
      continue;
    }
    final podcast = parseIdName(run);
    final name = podcast['name'];
    if (name is! String || name.trim().isEmpty) {
      continue;
    }
    fallback ??= podcast;
    final id = podcast['id'];
    if (id is String && id.startsWith('MPSP')) {
      return podcast;
    }
  }
  return fallback;
}

JsonDict parseEpisodeFlat(JsonDict data) => {
  'title': getItemText(data, 0),
  'podcast': parseIdName(
    asJsonDict(nav(getFlexColumnItem(data, 1), textRun, absent: true)),
  ),
  'videoId': nav(data, ['playlistItemData', 'videoId']),
  'browseId': nav(getFlexColumnItem(data, 0), [
    ...textRun,
    ...navigationBrowseId,
  ], absent: true),
  'playlistId': nav(data, [
    'overlay',
    'musicItemThumbnailOverlayRenderer',
    'content',
    'musicPlayButtonRenderer',
    'playNavigationEndpoint',
    ...watchPlaylistId,
  ], absent: true),
  'videoType': nav(data, [
    'overlay',
    'musicItemThumbnailOverlayRenderer',
    'content',
    'musicPlayButtonRenderer',
    'playNavigationEndpoint',
    'watchEndpoint',
    'watchEndpointMusicSupportedConfigs',
    'watchEndpointMusicConfig',
    'musicVideoType',
  ], absent: true),
  'date': getItemText(data, 2),
  'thumbnails': nav(data, thumbnails, absent: true),
};

JsonDict parsePodcast(JsonDict data) => {
  'title':
      nav(data, titleText, absent: true) ??
      nav(data, ['title', 'simpleText'], absent: true),
  'channel': parseIdName(
    asJsonDict(nav(data, [...subtitleRuns, 0], absent: true)),
  ),
  'browseId':
      nav(data, [...title, ...navigationBrowseId], absent: true) ??
      nav(data, ['navigationEndpoint', ...navigationBrowseId], absent: true),
  'podcastId': nav(data, [
    'thumbnailOverlay',
    'musicItemThumbnailOverlayRenderer',
    'content',
    'musicPlayButtonRenderer',
    'playNavigationEndpoint',
    ...watchPlaylistId,
  ], absent: true),
  'thumbnails': nav(data, thumbnailRenderer, absent: true),
  ...parseSongMenuData(data),
};
