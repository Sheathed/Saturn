import '../navigation.dart';
import '../type_alias.dart';
import 'songs.dart';

JsonList parseWatchPlaylistRows(List<dynamic> rows) {
  final tracks = <JsonDict>[];
  for (final value in rows) {
    var row = asJsonDict(value);
    if (row == null) {
      continue;
    }
    final wrapper = asJsonDict(row['playlistPanelVideoWrapperRenderer']);
    JsonDict? counterpart;
    if (wrapper != null) {
      final counterpartRows = wrapper['counterpart'];
      if (counterpartRows is List && counterpartRows.isNotEmpty) {
        final counterpartRenderer = asJsonDict(
          asJsonDict(counterpartRows.first)?['counterpartRenderer'],
        );
        counterpart = asJsonDict(
          counterpartRenderer?['playlistPanelVideoRenderer'],
        );
      }
      row = asJsonDict(wrapper['primaryRenderer']) ?? row;
    }
    final data = asJsonDict(row['playlistPanelVideoRenderer']) ??
        (row.containsKey('videoId') ? row : null);
    if (data == null || data.containsKey('unplayableText')) {
      continue;
    }
    try {
      final track = parseWatchTrack(data);
      if (counterpart != null) {
        try {
          track['counterpart'] = parseWatchTrack(counterpart);
        } catch (_) {}
      }
      tracks.add(track);
    } catch (_) {
      // Continue parsing remaining tracks
    }
  }
  return tracks;
}

JsonDict parseWatchTrack(JsonDict data) {
  String? likeStatus;
  final menuRenderer = data['menu']?['menuRenderer'];
  final items = menuRenderer is Map ? menuRenderer['items'] as List? : null;
  if (items != null) {
    for (final value in items) {
      if (value is! Map) continue;
      final toggle = value['toggleMenuServiceItemRenderer'] as Map?;
      final service = toggle?['defaultServiceEndpoint'] as Map?;
      if (service != null && service.containsKey('likeEndpoint')) {
        likeStatus = parseLikeStatus(asJsonDict(service) ?? {});
        break;
      }
    }
  }

  final navEndpoint = data['navigationEndpoint'] as Map?;
  final watchEndpoint = navEndpoint?['watchEndpoint'] as Map?;
  final videoType = watchEndpoint?['watchEndpointMusicSupportedConfigs']
      ?['watchEndpointMusicConfig']?['musicVideoType'] as String?;

  String titleTextValue = '';
  final rawTitle = data['title'];
  if (rawTitle is Map) {
    final runs = rawTitle['runs'];
    if (runs is List && runs.isNotEmpty && runs[0] is Map) {
      titleTextValue = runs[0]['text']?.toString() ?? '';
    }
    if (titleTextValue.isEmpty) {
      titleTextValue = rawTitle['simpleText']?.toString() ?? '';
    }
  } else if (rawTitle != null) {
    titleTextValue = rawTitle.toString();
  }

  String? lengthTextValue;
  final rawLength = data['lengthText'];
  if (rawLength is Map) {
    final runs = rawLength['runs'];
    if (runs is List && runs.isNotEmpty && runs[0] is Map) {
      lengthTextValue = runs[0]['text']?.toString();
    }
    lengthTextValue ??= rawLength['simpleText']?.toString();
  }

  final rawThumb = data['thumbnail'];
  dynamic thumbVal;
  if (rawThumb is Map) {
    thumbVal = rawThumb['thumbnails'] ?? rawThumb;
  } else if (rawThumb is List) {
    thumbVal = rawThumb;
  }

  final result = <String, dynamic>{
    'videoId': data['videoId'] ?? watchEndpoint?['videoId'],
    'title': titleTextValue,
    'length': lengthTextValue,
    'thumbnail': thumbVal,
    'likeStatus': likeStatus,
    'videoType': videoType,
    'isLive': isLiveRenderer(data, videoType: videoType),
    'inLibrary': null,
    'feedbackTokens': null,
    'pinnedToListenAgain': null,
    'listenAgainFeedbackTokens': null,
    ...parseSongMenuData(data),
  };
  final byline = (data['longBylineText']?['runs'] as List?) ??
      (data['shortBylineText']?['runs'] as List?);
  if (byline != null) {
    result.addAll(parseSongRuns(byline, skipTypeSpec: true));
  }
  return result;
}

Map<String, String> getTabBrowseIds(JsonDict watchNextRenderer) {
  final result = <String, String>{};
  final tabs = watchNextRenderer['tabs'];
  if (tabs is! List) {
    return result;
  }
  for (final value in tabs) {
    final tab = asJsonDict(asJsonDict(value)?['tabRenderer']);
    if (tab == null || tab.containsKey('unselectable')) {
      continue;
    }
    final endpoint = asJsonDict(
      nav(tab, ['endpoint', 'browseEndpoint'], absent: true),
    );
    if (endpoint == null) {
      continue;
    }
    final type = nav(endpoint, pageType, absent: true);
    final id = endpoint['browseId'];
    if (type is String && id is String) {
      result[type] = id;
    }
  }
  return result;
}
