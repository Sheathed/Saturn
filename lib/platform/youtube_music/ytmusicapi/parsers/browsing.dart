import '../navigation.dart';
import '../type_alias.dart';
import 'albums.dart';
import 'artists.dart';
import 'podcasts.dart';
import 'songs.dart';
import 'utils.dart';

/// Port of ytmusicapi.parsers.browsing.parse_content_list.
JsonList parseContentList(
  List<dynamic> rows,
  JsonDict Function(JsonDict) parse, {
  String key = twoRowItem,
}) {
  final output = <JsonDict>[];
  for (final rowValue in rows) {
    final row = asJsonDict(rowValue);
    final renderer = asJsonDict(row?[key]);
    if (renderer != null) {
      output.add(parse(renderer));
    }
  }
  return output;
}

/// Returns renderer rows from a shelf, keeping parsing separate from models.
JsonList parseShelfRows(JsonDict response) {
  final shelf = asJsonDict(nav(response, ['musicShelfRenderer'], absent: true));
  final carousel = asJsonDict(
    nav(response, ['musicCarouselShelfRenderer'], absent: true),
  );
  final grid = asJsonDict(nav(response, ['gridRenderer'], absent: true));
  return asJsonList(
    shelf?['contents'] ?? carousel?['contents'] ?? grid?['items'],
  );
}

/// Parses the song renderer forms used by browse shelves into ytmusicapi shaped maps.
JsonList parseSongRows(List<dynamic> rows) {
  final output = <JsonDict>[];
  for (final value in rows) {
    final row = asJsonDict(value);
    if (row == null) {
      continue;
    }
    final responsive = asJsonDict(row[responsiveItem]);
    final twoRow = asJsonDict(row[twoRowItem]);
    if (responsive != null) {
      output.add(parseSongFlat(responsive));
    } else if (twoRow != null &&
        nav(twoRow, navigationVideoId, absent: true) != null) {
      output.add(parseSong(twoRow));
    }
  }
  return output;
}

JsonDict parseAlbumSingleSubtitle(JsonDict result, JsonDict item) {
  final typeOrYear = nav(result, subtitle, absent: true);
  if (typeOrYear is String) {
    if (RegExp(r'^\d+$').hasMatch(typeOrYear)) {
      item['year'] = typeOrYear;
    } else {
      item['type'] = typeOrYear;
      final year = nav(result, ['subtitle', 'runs', 2, 'text'], absent: true);
      if (year is String && RegExp(r'^\d+$').hasMatch(year)) {
        item['year'] = year;
      }
    }
  }
  return item;
}

JsonDict parseSingle(JsonDict result) => parseAlbumSingleSubtitle(result, {
  'title': nav(result, titleText),
  'browseId': nav(result, [...title, ...navigationBrowseId]),
  'thumbnails': nav(result, thumbnailRenderer, absent: true),
});

JsonDict parseVideo(JsonDict result) {
  final runsValue = nav(result, subtitleRuns);
  final runs = runsValue is List ? runsValue : <dynamic>[];
  final separator = getDotSeparatorIndex(runs);
  var videoId = nav(result, navigationVideoId, absent: true);
  if (videoId == null) {
    final menuValues = nav(result, menuItems);
    if (menuValues is List) {
      for (final value in menuValues) {
        final id = nav(value, [
          ...menuService,
          'queueAddEndpoint',
          'queueTarget',
          'videoId',
        ], absent: true);
        if (id != null) {
          videoId = id;
          break;
        }
      }
    }
  }
  final lastRun = runs.isEmpty ? null : asJsonDict(runs.last);
  return {
    'title': nav(result, titleText),
    'videoId': videoId,
    'artists': parseArtistsRuns(runs.take(separator).toList()),
    'playlistId': nav(result, navigationPlaylistId, absent: true),
    'thumbnails': nav(result, thumbnailRenderer, absent: true),
    'views': lastRun?['text']?.toString().split(' ').first,
  };
}

JsonDict parsePlaylist(JsonDict data) {
  final browseId = nav(data, [...title, ...navigationBrowseId]).toString();
  final result = <String, dynamic>{
    'title': nav(data, titleText, absent: true),
    'playlistId': browseId.length >= 2 ? browseId.substring(2) : browseId,
    'thumbnails': nav(data, thumbnailRenderer, absent: true),
    'owned': false,
  };
  final menuValues = nav(data, menuItems, absent: true);
  if (menuValues is List) {
    result['owned'] = menuValues.any(
      (value) =>
          nav(value, [
            menuNavigationItem,
            'navigationEndpoint',
            'playlistEditorEndpoint',
            'playlistId',
          ], absent: true) ==
          result['playlistId'],
    );
  }
  final subtitle = nav(data, ['subtitle', 'runs'], absent: true);
  if (subtitle is List) {
    result['description'] = subtitle
        .map((run) => asJsonDict(run)?['text'] ?? '')
        .join();
    final countIndex = subtitle.indexWhere((run) {
      final text = asJsonDict(run)?['text']?.toString() ?? '';
      return RegExp(
        r'\b\d[\d,.]*\s+(songs?|tracks?|videos?|items?)\b',
        caseSensitive: false,
      ).hasMatch(text);
    });
    if (countIndex >= 0) {
      final countText = asJsonDict(subtitle[countIndex])?['text']
              ?.toString() ??
          '';
      result['count'] = countText.split(' ').first;
      final authorRuns = subtitle.take(countIndex).toList();
      final authors = parseArtistsRuns(authorRuns);
      if (authors.isNotEmpty) {
        result['author'] = authors;
      }
    }
  }
  result.addAll(parseSongMenuData(data));
  return result;
}

JsonDict parseRelatedArtist(JsonDict data) {
  final subscribers = nav(data, subtitle, absent: true)?.toString();
  return {
    'title': nav(data, titleText),
    'browseId': nav(data, [...title, ...navigationBrowseId]),
    'subscribers': subscribers?.split(' ').first,
    'thumbnails': nav(data, thumbnailRenderer, absent: true),
    ...parseSongMenuData(data),
  };
}

JsonDict parseWatchPlaylist(JsonDict data) => {
  'title': nav(data, titleText),
  'playlistId': nav(data, navigationWatchPlaylistId),
  'thumbnails': nav(data, thumbnailRenderer, absent: true),
};

/// Port of ytmusicapi.parsers.browsing.parse_mixed_content.
JsonList parseMixedContent(List<dynamic> rows) {
  final output = <JsonDict>[];
  for (final rowValue in rows) {
    final row = asJsonDict(rowValue);
    if (row == null || row.isEmpty) {
      continue;
    }
    final description = asJsonDict(row['musicDescriptionShelfRenderer']);
    if (description != null) {
      output.add({
        'title': nav(description, ['header', ...titleText], absent: true),
        'contents': nav(description, [
          'description',
          'runs',
          0,
          'text',
        ], absent: true),
      });
      continue;
    }
    final shelf = asJsonDict(row.values.first);
    final shelfContents = shelf?['contents'];
    if (shelfContents is! List) {
      continue;
    }
    final titleTextValue =
        nav(shelf, [
          'header',
          'musicCarouselShelfBasicHeaderRenderer',
          ...titleText,
        ], absent: true) ??
        nav(shelf, [
          'header',
          'musicCarouselShelfBasicHeaderRenderer',
          'strapline',
          ...runText,
        ], absent: true);
    final carouselHeader = asJsonDict(
      nav(shelf, [
        'header',
        'musicCarouselShelfBasicHeaderRenderer',
      ], absent: true),
    );
    final navigation =
        nav(carouselHeader, [
          'moreContentButton',
          'buttonRenderer',
          'navigationEndpoint',
        ], absent: true) ??
        nav(carouselHeader, [...title, 'navigationEndpoint'], absent: true);
    final browseId = nav(navigation, navigationBrowseId, absent: true);
    final watch = nav(navigation, ['watchEndpoint'], absent: true);
    final pagePath = browseId is String
        ? browseId
        : (watch is Map
              ? ((watch['playlistId'] is String &&
                        (watch['playlistId'] as String).startsWith('RD'))
                    ? 'mix:${watch['videoId'] ?? watch['playlistId']}'
                    : (watch['playlistId'] is String
                          ? 'playlist:${watch['playlistId']}'
                          : (watch['videoId'] is String
                                ? 'play:${watch['videoId']}'
                                : null)))
              : null);
    final parsedContents = <JsonDict>[];
    for (final contentValue in shelfContents) {
      final content = asJsonDict(contentValue);
      if (content == null) {
        continue;
      }
      final data = asJsonDict(content[twoRowItem]);
      final flatSong = asJsonDict(content[responsiveItem]);
      final episode = asJsonDict(content[multiRowItem]);
      if (data != null) {
        final page = nav(data, [
          ...title,
          ...navigationBrowse,
          ...pageType,
        ], absent: true);
        if (page == null) {
          if (nav(data, navigationWatchPlaylistId, absent: true) != null) {
            parsedContents.add(parseWatchPlaylist(data));
          } else if (nav(data, navigationVideoId, absent: true) != null) {
            parsedContents.add(parseSong(data));
          }
        } else if (page == 'MUSIC_PAGE_TYPE_ALBUM' ||
            page == 'MUSIC_PAGE_TYPE_AUDIOBOOK') {
          parsedContents.add(parseAlbum(data));
        } else if (page == 'MUSIC_PAGE_TYPE_ARTIST' ||
            page == 'MUSIC_PAGE_TYPE_USER_CHANNEL') {
          parsedContents.add(parseRelatedArtist(data));
        } else if (page == 'MUSIC_PAGE_TYPE_PLAYLIST') {
          parsedContents.add(parsePlaylist(data));
        } else if (page == 'MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE') {
          parsedContents.add(parsePodcast(data));
        }
      } else if (flatSong != null) {
        parsedContents.add(parseSongFlat(flatSong, withPlaylistId: true));
      } else if (episode != null) {
        parsedContents.add(parseEpisode(episode));
      }
    }
    output.add({
      'title': titleTextValue,
      'pagePath': pagePath,
      'contents': parsedContents,
    });
  }
  return output;
}
