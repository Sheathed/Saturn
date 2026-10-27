import '../helpers.dart';
import '../navigation.dart';
import '../type_alias.dart';
import 'artists.dart';
import 'songs.dart';

JsonDict parseAlbumHeader(JsonDict response) {
  final albumHeader = asJsonDict(nav(response, headerDetail));
  if (albumHeader == null) {
    throw StateError('Expected album detail header');
  }
  final subtitleRunsValue = nav(albumHeader, subtitleRuns);
  final subtitleRunsList = subtitleRunsValue is List
      ? subtitleRunsValue
      : <dynamic>[];
  final secondSubtitle = nav(albumHeader, ['secondSubtitle', 'runs']);
  final secondRuns = secondSubtitle is List ? secondSubtitle : <dynamic>[];
  final album = <String, dynamic>{
    'title': nav(albumHeader, titleText),
    'type': nav(albumHeader, subtitle),
    'thumbnails': nav(albumHeader, thumbnailCropped, absent: true),
    'isExplicit': nav(albumHeader, subtitleBadgeLabel, absent: true) != null,
  };
  final description = nav(albumHeader, [
    'description',
    'runs',
    0,
    'text',
  ], absent: true);
  if (description != null) {
    album['description'] = description;
  }
  album.addAll(parseSongRuns(subtitleRunsList.skip(2).toList()));
  if (secondRuns.length > 1) {
    album['trackCount'] = toInt(
      asJsonDict(secondRuns[0])?['text']?.toString() ?? '',
    );
    album['duration'] = asJsonDict(secondRuns[2])?['text'];
  } else if (secondRuns.isNotEmpty) {
    album['duration'] = asJsonDict(secondRuns[0])?['text'];
  }
  final buttons = nav(albumHeader, menuTopLevelButtons);
  final audio =
      nav(buttons, [
        0,
        'buttonRenderer',
        ...navigationWatchPlaylistId,
      ], absent: true) ??
      nav(buttons, [
        0,
        'buttonRenderer',
        ...navigationPlaylistId,
      ], absent: true);
  if (audio != null) {
    album['audioPlaylistId'] = audio;
  }
  final service = nav(buttons, [
    1,
    'buttonRenderer',
    'defaultServiceEndpoint',
  ], absent: true);
  if (service != null) {
    album['likeStatus'] = parseLikeStatus(asJsonDict(service) ?? {});
  }
  return album;
}

JsonDict parseAlbumHeader2024(JsonDict response) {
  final albumHeader = asJsonDict(
    nav(response, [
      ...twoColumnRenderer,
      ...tabContent,
      ...sectionListItem,
      ...responsiveHeader,
    ]),
  );
  if (albumHeader == null) {
    throw StateError('Expected responsive album header');
  }
  final album = <String, dynamic>{
    'title': nav(albumHeader, titleText),
    'type': nav(albumHeader, subtitle),
    'thumbnails': nav(albumHeader, thumbnails, absent: true),
    'isExplicit': nav(albumHeader, subtitleBadgeLabel, absent: true) != null,
  };
  final rawDescriptionRuns = nav(albumHeader, [
    'description',
    'musicDescriptionShelfRenderer',
    'description',
    'runs',
  ], absent: true);
  final description = parseDescriptionRuns(rawDescriptionRuns);
  album['description'] = description['description'];
  album['descriptionRuns'] = description['descriptionRuns'];
  final subtitleRunsValue = nav(albumHeader, subtitleRuns);
  final subtitleRunsList = subtitleRunsValue is List
      ? subtitleRunsValue
      : <dynamic>[];
  final albumInfo = parseSongRuns(subtitleRunsList.skip(2).toList());
  final strapline = nav(albumHeader, [
    'straplineTextOne',
    'runs',
  ], absent: true);
  albumInfo['artists'] = strapline is List ? parseArtistsRuns(strapline) : null;
  album.addAll(albumInfo);
  final secondRunsValue = nav(albumHeader, ['secondSubtitle', 'runs']);
  final secondRuns = secondRunsValue is List ? secondRunsValue : <dynamic>[];
  if (secondRuns.length > 1) {
    album['trackCount'] = toInt(
      asJsonDict(secondRuns[0])?['text']?.toString() ?? '',
    );
    album['duration'] = asJsonDict(secondRuns[2])?['text'];
  } else if (secondRuns.isNotEmpty) {
    album['duration'] = asJsonDict(secondRuns[0])?['text'];
  }
  final buttons = asJsonList(albumHeader['buttons']);
  final playButton = findObjectByKey(buttons, 'musicPlayButtonRenderer');
  album['audioPlaylistId'] = nav(playButton, [
    'musicPlayButtonRenderer',
    'playNavigationEndpoint',
    ...watchPlaylistId,
  ], absent: true);
  album['likeStatus'] = 'INDIFFERENT';
  final toggleButton = findObjectByKey(buttons, 'toggleButtonRenderer');
  final service = nav(toggleButton, [
    'toggleButtonRenderer',
    'defaultServiceEndpoint',
  ], absent: true);
  if (service != null) {
    album['likeStatus'] = parseLikeStatus(asJsonDict(service) ?? {});
  }
  return album;
}
