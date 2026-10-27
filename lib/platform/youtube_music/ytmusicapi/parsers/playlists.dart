import '../navigation.dart';
import '../continuations.dart';
import '../helpers.dart';
import '../type_alias.dart';
import 'explore.dart';
import 'songs.dart';
import 'utils.dart';

JsonDict parsePlaylistHeader(JsonDict response) {
  final tabHeader = nav(response, [
    ...twoColumnRenderer,
    ...tabContent,
    ...sectionListItem,
  ], absent: true);
  final editable =
      nav(
        tabHeader,
        ['musicEditablePlaylistDetailHeaderRenderer'],
        absent: true,
      ) ??
      nav(response, [
        'header',
        'musicEditablePlaylistDetailHeaderRenderer',
      ], absent: true);
  final isOwned = editable != null;
  final headerData = editable != null
      ? nav(editable, ['header', ...responsiveHeader], absent: true)
      : (nav(response, headerDetail, absent: true) ??
            nav(tabHeader, [...responsiveHeader], absent: true));
  final header = asJsonDict(headerData);
  if (header == null) {
    throw StateError('Expected playlist header');
  }
  final result = <String, dynamic>{
    'owned': isOwned,
    'privacy': editable == null
        ? 'PUBLIC'
        : nav(editable, [
            'editHeader',
            'musicPlaylistEditHeaderRenderer',
            'privacy',
          ]),
    ...parsePlaylistHeaderMeta(header),
    'description': nav(header, [
      'description',
      ...descriptionShelf,
    ], absent: true),
    'year': nav(header, ['subtitle', 'runs', 2, 'text']),
  };
  if (result['thumbnails'] == null) {
    result['thumbnails'] = nav(header, thumbnailCropped, absent: true);
  }
  return result;
}

JsonDict parsePlaylistHeaderMeta(JsonDict header) {
  final result = <String, dynamic>{
    'views': null,
    'duration': null,
    'trackCount': null,
    'title': parseRuns(header['title']),
    'thumbnails': nav(header, thumbnails, absent: true),
  };
  final facepile = asJsonDict(header['facepile']);
  if (facepile != null) {
    final stack = asJsonDict(
      nav(facepile, ['avatarStackViewModel'], absent: true),
    );
    final context = nav(stack, ['rendererContext'], absent: true);
    final command = nav(context, [
      'commandContext',
      'onTap',
      'innertubeCommand',
    ], absent: true);
    if (nav(command, [
          'showEngagementPanelEndpoint',
          'identifier',
          'tag',
        ], absent: true) ==
        'PAplaylist_collaborate') {
      final avatars = nav(stack, ['avatars'], absent: true);
      final avatarImages = <dynamic>[];
      if (avatars is List) {
        for (final avatar in avatars) {
          final image = nav(avatar, [
            'avatarViewModel',
            'image',
            'sources',
            0,
          ], absent: true);
          if (image != null) {
            avatarImages.add(image);
          }
        }
      }
      result['collaborators'] = {
        'text': nav(context, ['accessibilityContext', 'label'], absent: true),
        'avatars': avatarImages,
      };
    } else {
      result['author'] = {
        'name': nav(stack, ['text', 'content'], absent: true),
        'id': nav(command, ['browseEndpoint', 'browseId'], absent: true),
      };
    }
  }
  final subtitle = nav(header, ['secondSubtitle', 'runs'], absent: true);
  if (subtitle is List) {
    final hasViews = subtitle.length > 3 ? 2 : 0;
    final hasDuration = subtitle.length > 1 ? 2 : 0;
    if (hasViews > 0) {
      result['views'] = toInt(
        asJsonDict(subtitle[0])?['text']?.toString() ?? '',
      );
    }
    if (hasDuration > 0 && subtitle.length > hasViews + hasDuration) {
      result['duration'] = asJsonDict(
        subtitle[hasViews + hasDuration],
      )?['text'];
    }
    final countText = asJsonDict(subtitle[hasViews])?['text']?.toString() ?? '';
    final digits = countText.replaceAll(RegExp(r'\D'), '');
    result['trackCount'] = digits.isEmpty ? null : int.tryParse(digits);
  }
  return result;
}

Future<JsonDict> parseAudioPlaylist(
  JsonDict response, {
  int? limit,
  required Future<JsonDict> Function(JsonDict) request,
}) async {
  final shelf = asJsonDict(
    nav(response, [
      ...twoColumnRenderer,
      'secondaryContents',
      ...section,
      ...content,
      'musicPlaylistShelfRenderer',
    ]),
  );
  if (shelf == null) {
    throw StateError('Expected audio playlist shelf');
  }
  final rows = shelf['contents'] is List
      ? shelf['contents'] as List
      : <dynamic>[];
  final tracks = parsePlaylistItems(rows);
  final continuedTracks = await getContinuations2025(
    initial: shelf,
    limit: limit == null ? null : limit - tracks.length,
    request: request,
    parse: (continuationRows) => parsePlaylistItems(continuationRows),
  );
  final allTracks = [...tracks, ...continuedTracks];
  final playlist = <String, dynamic>{
    'owned': false,
    'privacy': 'PUBLIC',
    'description': null,
    'views': null,
    'duration': null,
    'tracks': allTracks,
    'thumbnails': <dynamic>[],
    'related': <dynamic>[],
    'id': nav(shelf, ['targetId']),
    'trackCount': allTracks.length,
    'title': allTracks.isEmpty
        ? null
        : nav(allTracks.first, ['album', 'name'], absent: true),
    'duration_seconds': sumTotalDuration({'tracks': allTracks}),
  };
  return playlist;
}

/// Parses the first playlist shelf response without consuming continuation
/// pages. The caller can retain the continuation token and request only the
/// next page when needed.
JsonDict parseAudioPlaylistPageStart(JsonDict response) {
  final shelf = asJsonDict(
    nav(response, [
      ...twoColumnRenderer,
      'secondaryContents',
      ...section,
      ...content,
      'musicPlaylistShelfRenderer',
    ]),
  );
  if (shelf == null) {
    throw StateError('Expected audio playlist shelf');
  }
  final rows = shelf['contents'] is List
      ? shelf['contents'] as List
      : <dynamic>[];
  return {
    ...parsePlaylistHeader(response),
    'id': nav(shelf, ['targetId']),
    'tracks': parsePlaylistItems(rows),
    'continuation': getContinuationToken(rows),
  };
}

String validatePlaylistId(String playlistId) =>
    playlistId.startsWith('VL') ? playlistId.substring(2) : playlistId;

JsonList parsePlaylistItems(
  List<dynamic> rows, {
  bool isAlbum = false,
  bool isCollaborative = false,
}) {
  final songs = <JsonDict>[];
  for (final row in rows) {
    final renderer = asJsonDict(asJsonDict(row)?[responsiveItem]);
    if (renderer == null) {
      continue;
    }
    final song = parsePlaylistItem(
      renderer,
      isAlbum: isAlbum,
      isCollaborative: isCollaborative,
    );
    if (song != null) {
      songs.add(song);
    }
  }
  return songs;
}

/// Port of ytmusicapi.parsers.playlists.parse_playlist_item.
JsonDict? parsePlaylistItem(
  JsonDict data, {
  bool isAlbum = false,
  bool isCollaborative = false,
}) {
  String? videoId;
  String? setVideoId;
  String? creditsBrowseId;
  String? like;
  final items = nav(data, menuItems, absent: true);
  if (items is List) {
    for (final value in items) {
      final entry = asJsonDict(value);
      if (entry == null) {
        continue;
      }
      final service = asJsonDict(entry['menuServiceItemRenderer']);
      if (service != null) {
        final endpoint = nav(service, [
          'serviceEndpoint',
          'playlistEditEndpoint',
        ], absent: true);
        setVideoId =
            nav(endpoint, ['actions', 0, 'setVideoId'], absent: true)
                as String? ??
            setVideoId;
        videoId =
            nav(endpoint, ['actions', 0, 'removedVideoId'], absent: true)
                as String? ??
            videoId;
      }
      final navItem = asJsonDict(entry[menuNavigationItem]);
      final maybeCredits = nav(navItem, navigationBrowseId, absent: true);
      if (maybeCredits is String && maybeCredits.startsWith('MPTC')) {
        creditsBrowseId = maybeCredits;
      }
    }
  }
  final play = nav(data, [
    'overlay',
    'musicItemThumbnailOverlayRenderer',
    'content',
    'musicPlayButtonRenderer',
    'playNavigationEndpoint',
    'watchEndpoint',
    'videoId',
  ], absent: true);
  if (play is String) {
    videoId = play;
    like = nav(data, [...menuLikeStatus], absent: true) as String?;
  }
  final available =
      data['musicItemRendererDisplayPolicy'] !=
      'MUSIC_ITEM_RENDERER_DISPLAY_POLICY_GREY_OUT';
  final videoType = nav(
    items is List && items.isNotEmpty ? items.first : null,
    [menuNavigationItem, 'navigationEndpoint', ...watchEndpointVideoType],
    absent: true,
  );
  var titleIndex = (isAlbum || !available) ? 0 : -1;
  var artistIndex = (isAlbum || !available) ? 1 : -1;
  var albumIndex = (isAlbum || !available) ? (isCollaborative ? 3 : 2) : -1;
  var durationIndex = -1;
  var unrecognizedIndex = -1;
  final userChannelIndexes = <int>[];
  final flexColumns = data['flexColumns'] is List
      ? data['flexColumns'] as List
      : const [];
  for (var index = 0; index < flexColumns.length; index++) {
    final column = getFlexColumnItem(data, index);
    final endpoint = nav(column, [
      ...textRun,
      'navigationEndpoint',
    ], absent: true);
    if (endpoint is! Map) {
      final run = nav(column, textRun, absent: true);
      final runMap = asJsonDict(run);
      if (runMap != null && runMap['text'] is String) {
        if (parseSongRun(runMap)['type'] == 'duration') {
          durationIndex = index;
        } else if (unrecognizedIndex < 0) {
          unrecognizedIndex = index;
        }
      }
      continue;
    }
    if (endpoint.containsKey('watchEndpoint')) {
      titleIndex = index;
    } else if (endpoint.containsKey('browseEndpoint')) {
      final page = nav(endpoint, ['browseEndpoint', ...pageType], absent: true);
      if (page == 'MUSIC_PAGE_TYPE_ARTIST' ||
          page == 'MUSIC_PAGE_TYPE_UNKNOWN') {
        artistIndex = index;
      } else if (page == 'MUSIC_PAGE_TYPE_ALBUM' ||
          page == 'MUSIC_PAGE_TYPE_AUDIOBOOK') {
        albumIndex = index;
      } else if (page == 'MUSIC_PAGE_TYPE_USER_CHANNEL') {
        userChannelIndexes.add(index);
      } else if (page == 'MUSIC_PAGE_TYPE_NON_MUSIC_AUDIO_TRACK_PAGE') {
        titleIndex = index;
      }
    }
  }
  if (artistIndex < 0 && unrecognizedIndex >= 0) {
    artistIndex = unrecognizedIndex;
  }
  if (artistIndex < 0 && userChannelIndexes.isNotEmpty) {
    artistIndex = userChannelIndexes.last;
  }
  final titleValue = titleIndex < 0 ? null : getItemText(data, titleIndex);
  if (titleValue == 'Song deleted') {
    return null;
  }
  final artists = artistIndex < 0 ? null : parseSongArtists(data, artistIndex);
  final album = albumIndex < 0 ? null : parseSongAlbum(data, albumIndex);
  var duration = durationIndex < 0 ? null : getItemText(data, durationIndex);
  final fixed = getFixedColumnItem(data, 0);
  final fixedText =
      nav(fixed, ['text', 'simpleText'], absent: true) ??
      nav(fixed, textRunText, absent: true);
  if (fixedText is String) {
    duration = fixedText;
  }
  final result = <String, dynamic>{
    'videoId': videoId,
    'title': titleValue,
    'artists': artists,
    'album': album,
    'likeStatus': like,
    'thumbnails': nav(data, thumbnails, absent: true),
    'isAvailable': available,
    'isExplicit': nav(data, badgeLabel, absent: true) != null,
    'progressPercentage': nav(data, [
      'playbackProgress',
      'musicPlaybackProgressRenderer',
      'playbackProgressPercentage',
    ], absent: true),
    'videoType': videoType,
    'isLive': isLiveRenderer(data, videoType: videoType),
    'views': isAlbum ? getItemText(data, 2) : null,
    ...parseSongMenuData(data),
  };
  final ranking = parseRanking(data, absent: true);
  if (ranking.isNotEmpty) {
    result.addAll(ranking);
  }
  if (data['customIndexColumn'] != null) {
    result['customIndexColumn'] = data['customIndexColumn'];
  }
  if (isAlbum) {
    result['trackNumber'] = available
        ? int.tryParse(
            nav(data, ['index', 'runs', 0, 'text'], absent: true)?.toString() ??
                '',
          )
        : null;
  } else if (ranking['rank'] != null) {
    result['trackNumber'] = int.tryParse(ranking['rank'].toString());
  }
  if (duration != null) {
    result['duration'] = duration;
    result['duration_seconds'] = parseDuration(duration);
  }
  if (setVideoId != null) {
    result['setVideoId'] = setVideoId;
  }
  if (creditsBrowseId != null) {
    result['creditsBrowseId'] = creditsBrowseId;
  }
  return result;
}
