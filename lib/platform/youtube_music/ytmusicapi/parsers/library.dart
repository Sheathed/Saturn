import '../navigation.dart';
import '../continuations.dart';
import '../type_alias.dart';
import 'browsing.dart';
import 'playlists.dart';
import 'podcasts.dart';
import 'songs.dart';
import 'utils.dart';

JsonList parseLibraryArtists(List<dynamic> rows, {bool uploaded = false}) {
  final artists = <JsonDict>[];
  for (final row in rows) {
    final data = asJsonDict(asJsonDict(row)?[responsiveItem]);
    if (data == null) {
      continue;
    }
    final pageTypeValue = nav(data, [
      ...navigationBrowse,
      ...pageType,
    ], absent: true);
    final artist = <String, dynamic>{
      'browseId': nav(data, navigationBrowseId),
      'artist': getItemText(data, 0),
      if (pageTypeValue == 'MUSIC_PAGE_TYPE_USER_CHANNEL') 'type': 'channel',
      if (pageTypeValue == 'MUSIC_PAGE_TYPE_ARTIST') 'type': 'artist',
      'thumbnails': nav(data, thumbnails, absent: true),
    };
    parseMenuPlaylists(data, artist);
    final subtitle = getItemText(data, 1) ?? '';
    if (uploaded) {
      artist['songs'] = subtitle.split(' ').first;
    } else if (subtitle.isNotEmpty) {
      artist['subscribers'] = subtitle.split(' ').first;
    }
    artists.add(artist);
  }
  return artists;
}

void popLibraryRandomMix(JsonDict? results) {
  final rows = results?['contents'];
  if (rows is List && rows.length >= 2) {
    rows.removeAt(0);
  }
}

JsonList parseAlbums(List<dynamic> rows) {
  final albums = <JsonDict>[];
  for (final row in rows) {
    final data = asJsonDict(asJsonDict(row)?[twoRowItem]);
    if (data == null) {
      continue;
    }
    final album = <String, dynamic>{
      'browseId': nav(data, [...title, ...navigationBrowseId]),
      'playlistId': nav(data, [
        ...menuItems,
        0,
        menuNavigationItem,
        ...navigationPlaylistId,
      ], absent: true),
      'title': nav(data, titleText),
      'thumbnails': nav(data, thumbnailRenderer, absent: true),
    };
    final runs = nav(data, subtitleRuns, absent: true);
    if (runs is List) {
      album['type'] = nav(data, subtitle, absent: true);
      album.addAll(parseSongRuns(runs.skip(2).toList()));
    }
    albums.add(album);
  }
  return albums;
}

JsonList parseLibraryPlaylists(
  List<dynamic> rows, {
  bool skipAddButton = true,
}) {
  final items = skipAddButton && rows.isNotEmpty ? rows.skip(1).toList() : rows;
  return parseContentList(items, parsePlaylist);
}

JsonDict? getLibraryContents(JsonDict response, List<Object> renderer) {
  final sectionRows = nav(response, [
    ...singleColumnTab,
    ...sectionList,
  ], absent: true);
  dynamic contents;
  if (sectionRows == null) {
    final tabs = nav(response, [...singleColumn, 'tabs'], absent: true);
    final tabCount = tabs is List ? tabs.length : 0;
    contents = nav(response, [
      ...singleColumn,
      ...(tabCount < 3 ? tab1Content : tab2Content),
      ...sectionListItem,
      ...renderer,
    ], absent: true);
  } else if (sectionRows is List) {
    final found = findObjectByKey(sectionRows, 'itemSectionRenderer');
    contents = found == null
        ? nav(response, [
            ...singleColumnTab,
            ...sectionListItem,
            ...renderer,
          ], absent: true)
        : nav(found, [...itemSection, ...renderer], absent: true);
  }
  return asJsonDict(contents);
}

JsonDict parseLibrarySongs(JsonDict response) {
  final results = getLibraryContents(response, musicShelf);
  final rows = results?['contents'];
  if (rows is List && rows.length >= 2) {
    rows.removeAt(0);
  } // Random mix, matching upstream behavior.
  return {
    'results': results,
    'parsed': rows is List ? parsePlaylistItems(rows) : results,
  };
}

void parseMenuPlaylists(JsonDict data, JsonDict result) {
  final rows = nav(data, menuItems, absent: true);
  if (rows is! List) {
    return;
  }
  for (final row in rows) {
    final item = asJsonDict(asJsonDict(row)?[menuNavigationItem]);
    if (item == null) {
      continue;
    }
    final icon = nav(item, iconType, absent: true);
    final key = icon == 'MUSIC_SHUFFLE'
        ? 'shuffleId'
        : (icon == 'MIX' ? 'radioId' : null);
    if (key == null) {
      continue;
    }
    final id =
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
    if (id is String && id.isNotEmpty) {
      result[key] = id;
    }
  }
}

JsonList parseLibraryPodcasts(List<dynamic> rows) {
  final podcasts = <JsonDict>[];
  for (final row in rows.skip(rows.isNotEmpty ? 1 : 0)) {
    final renderer = asJsonDict(asJsonDict(row)?[twoRowItem]);
    if (renderer != null) {
      podcasts.add(parsePodcast(renderer));
    }
  }
  return podcasts;
}

Future<JsonList> getLibraryAlbums(
  JsonDict response, {
  int? limit,
  required Future<JsonDict> Function(String) request,
}) async {
  final results = getLibraryContents(response, grid);
  if (results == null) {
    return [];
  }
  final rows = results['items'] is List
      ? results['items'] as List
      : <dynamic>[];
  final albums = parseAlbums(rows);
  if (!results.containsKey('continuations')) {
    return albums;
  }
  final remaining = limit == null ? null : limit - albums.length;
  albums.addAll(
    await getContinuations(
      initial: results,
      continuationType: 'gridContinuation',
      limit: remaining,
      request: request,
      parse: parseAlbums,
    ),
  );
  return albums;
}

Future<JsonList> getLibraryArtists(
  JsonDict response, {
  int? limit,
  bool uploaded = false,
  required Future<JsonDict> Function(String) request,
}) async {
  final results = getLibraryContents(response, musicShelf);
  if (results == null) {
    return [];
  }
  final rows = results['contents'] is List
      ? results['contents'] as List
      : <dynamic>[];
  final artists = parseLibraryArtists(rows, uploaded: uploaded);
  if (!results.containsKey('continuations')) {
    return artists;
  }
  final remaining = limit == null ? null : limit - artists.length;
  artists.addAll(
    await getContinuations(
      initial: results,
      continuationType: 'musicShelfContinuation',
      limit: remaining,
      request: request,
      parse: (continuationRows) =>
          parseLibraryArtists(continuationRows, uploaded: uploaded),
    ),
  );
  return artists;
}

Future<JsonList> getLibraryPodcasts(
  JsonDict response, {
  int? limit,
  required Future<JsonDict> Function(String) request,
}) async {
  final results = getLibraryContents(response, grid);
  if (results == null) {
    return [];
  }
  final rows = results['items'] is List
      ? results['items'] as List
      : <dynamic>[];
  final podcasts = parseLibraryPodcasts(rows);
  if (!results.containsKey('continuations')) {
    return podcasts;
  }
  final remaining = limit == null ? null : limit - podcasts.length;
  podcasts.addAll(
    await getContinuations(
      initial: results,
      continuationType: 'gridContinuation',
      limit: remaining,
      request: request,
      parse: (continuationRows) =>
          parseContentList(continuationRows, parsePodcast),
    ),
  );
  return podcasts;
}
