import '../navigation.dart';
import '../type_alias.dart';
import 'songs.dart';
import 'utils.dart';

JsonList parseUploadedItems(List<dynamic> rows) {
  final songs = <JsonDict>[];
  for (final value in rows) {
    final data = asJsonDict(asJsonDict(value)?[responsiveItem]);
    if (data == null || !data.containsKey('menu')) {
      continue;
    }
    final entityId = nav(data, [
      ...menuItems,
      -1,
      menuNavigationItem,
      'navigationEndpoint',
      'confirmDialogEndpoint',
      'content',
      'confirmDialogRenderer',
      'confirmButton',
      'buttonRenderer',
      'command',
      'musicDeletePrivatelyOwnedEntityCommand',
      'entityId',
    ]);
    final videoId = nav(data, [
      ...menuItems,
      0,
      ...menuService,
      'queueAddEndpoint',
      'queueTarget',
      'videoId',
    ]);
    final duration =
        nav(getFixedColumnItem(data, 0), textRunText, absent: true) as String?;
    songs.add({
      'entityId': entityId,
      'videoId': videoId,
      'title': getItemText(data, 0),
      'duration': duration,
      'duration_seconds': parseDuration(duration),
      'artists': parseSongArtists(data, 1),
      'album': parseSongAlbum(data, 2),
      'likeStatus': nav(data, menuLikeStatus),
      'thumbnails': nav(data, thumbnails, absent: true),
    });
  }
  return songs;
}
