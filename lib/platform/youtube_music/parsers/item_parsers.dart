import 'package:material_ui/material_ui.dart';
import '../../../api/definitions.dart';
import '../ytmusicapi/parsers/songs.dart' as ytmusicapi_songs;
import '../ytmusicapi/parsers/utils.dart' as ytmusicapi_utils;
import '../ytmusicapi/parsers/albums.dart' as ytmusicapi_albums;
import '../ytmusicapi/parsers/browsing.dart' as ytmusicapi_browsing;
import '../ytmusicapi/parsers/podcasts.dart' as ytmusicapi_podcasts;
import '../ytmusicapi/parsers/search.dart' as ytmusicapi_search;
import '../ytmusicapi/parsers/watch.dart' as ytmusicapi_watch;
import '../ytmusicapi/parsers/explore.dart' as ytmusicapi_explore;

/// Data extracted from a YouTube Music context menu regarding Listen Again.
class YouTubeMusicListenAgainData {
  final bool isPinned;
  final bool? inLibrary;
  final String? pinFeedbackToken;
  final String? unpinFeedbackToken;
  final String? addLibraryFeedbackToken;
  final String? removeLibraryFeedbackToken;
  final String? historyFeedbackToken;

  const YouTubeMusicListenAgainData({
    this.isPinned = false,
    this.inLibrary,
    this.pinFeedbackToken,
    this.unpinFeedbackToken,
    this.addLibraryFeedbackToken,
    this.removeLibraryFeedbackToken,
    this.historyFeedbackToken,
  });

  bool get hasTokens => pinFeedbackToken != null || unpinFeedbackToken != null;
}

/// Utilities and parsers for YouTube Music Innertube renderers.
class YouTubeMusicParsers {
  static final Map<String, YouTubeMusicListenAgainData>
  _listenAgainDataByItemId = {};

  static User? playlistUserFromAuthor(dynamic author) {
    if (author is String) {
      final name = author.trim();
      return name.isEmpty ? null : User(name: name);
    }
    if (author is Map) {
      final name = author['name']?.toString().trim();
      if (name == null || name.isEmpty) return null;
      return User(id: author['id']?.toString(), name: name);
    }
    if (author is List) {
      final authors = author
          .whereType<Map>()
          .map((value) => value['name']?.toString().trim() ?? '')
          .where((name) => name.isNotEmpty)
          .toList();
      if (authors.isEmpty) return null;
      final first = author.whereType<Map>().first;
      return User(id: first['id']?.toString(), name: authors.join(', '));
    }
    return null;
  }

  static YouTubeMusicListenAgainData? listenAgainDataFor(String? itemId) {
    if (itemId == null || itemId.isEmpty) {
      return null;
    }
    final normalizedId = itemId.startsWith('VL') ? itemId.substring(2) : itemId;
    return _listenAgainDataByItemId[itemId] ??
        _listenAgainDataByItemId[normalizedId] ??
        _listenAgainDataByItemId['VL$itemId'];
  }

  static void _rememberListenAgain(
    String? itemId,
    Map<String, dynamic> renderer,
  ) {
    if (itemId == null || itemId.isEmpty) {
      return;
    }
    var data = parseListenAgainMenuData(renderer);
    if (!data.hasTokens) {
      return;
    }
    final normalizedId = itemId.startsWith('VL') ? itemId.substring(2) : itemId;
    final previous = listenAgainDataFor(itemId);
    if (previous != null &&
        previous.pinFeedbackToken == data.pinFeedbackToken &&
        previous.unpinFeedbackToken == data.unpinFeedbackToken) {
      data = YouTubeMusicListenAgainData(
        isPinned: previous.isPinned,
        inLibrary: data.inLibrary,
        pinFeedbackToken: data.pinFeedbackToken,
        unpinFeedbackToken: data.unpinFeedbackToken,
        addLibraryFeedbackToken: data.addLibraryFeedbackToken,
        removeLibraryFeedbackToken: data.removeLibraryFeedbackToken,
        historyFeedbackToken: data.historyFeedbackToken,
      );
    }
    _listenAgainDataByItemId[itemId] = data;
    _listenAgainDataByItemId[normalizedId] = data;
    _listenAgainDataByItemId['VL$normalizedId'] = data;
  }

  static void updateListenAgainData(
    String itemId,
    YouTubeMusicListenAgainData data,
  ) {
    if (!data.hasTokens) {
      return;
    }
    final normalizedId = itemId.startsWith('VL') ? itemId.substring(2) : itemId;
    _listenAgainDataByItemId[itemId] = data;
    _listenAgainDataByItemId[normalizedId] = data;
    _listenAgainDataByItemId['VL$normalizedId'] = data;
  }

  static bool _pinnedForItem(String? itemId, Map<String, dynamic> renderer) {
    _rememberListenAgain(itemId, renderer);
    return listenAgainDataFor(itemId)?.isPinned ??
        parseListenAgainMenuData(renderer).isPinned;
  }

  static String? _likeStatusFromMenu(Map<String, dynamic> renderer) {
    final menuItems =
        renderer['menu']?['menuRenderer']?['items'] ??
        renderer['menu']?['items'] ??
        renderer['menuItems'];
    if (menuItems is! List) {
      return null;
    }
    for (final value in menuItems) {
      if (value is! Map) {
        continue;
      }
      final item =
          value['menuNavigationItemRenderer'] ??
          value['menuServiceItemRenderer'] ??
          value['toggleMenuServiceItemRenderer'];
      final endpoint =
          item?['defaultServiceEndpoint'] ?? item?['toggledServiceEndpoint'];
      final like = endpoint?['likeEndpoint'];
      if (like is Map) {
        return like['status'] == 'LIKE' ? 'LIKE' : 'INDIFFERENT';
      }
    }
    return null;
  }

  static String? _videoId(Map<String, dynamic> renderer) {
    final id =
        renderer['playlistItemData']?['videoId'] ??
        renderer['onTap']?['watchEndpoint']?['videoId'] ??
        renderer['playbackEndpoint']?['watchEndpoint']?['videoId'] ??
        renderer['flexColumns']?[0]?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs']?[0]?['navigationEndpoint']?['watchEndpoint']?['videoId'] ??
        renderer['overlay']?['musicItemThumbnailOverlayRenderer']?['content']?['musicPlayButtonRenderer']?['playNavigationEndpoint']?['watchEndpoint']?['videoId'] ??
        renderer['navigationEndpoint']?['watchEndpoint']?['videoId'];
    return id is String && id.isNotEmpty ? id : null;
  }

  static String? _browseIdFromRun(Map<String, dynamic> run) {
    return run['navigationEndpoint']?['browseEndpoint']?['browseId'] as String?;
  }

  static String? _pageTypeFromRun(Map<String, dynamic> run) {
    return run['navigationEndpoint']?['browseEndpoint']?['browseEndpointContextSupportedConfigs']?['browseEndpointContextMusicConfig']?['pageType']
        as String?;
  }

  static List<Map<String, dynamic>> _runsFromColumn(dynamic column) {
    final runs =
        column?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs'];
    return runs is List
        ? runs
              .whereType<Map>()
              .map((run) => Map<String, dynamic>.from(run))
              .toList()
        : [];
  }

  static Duration? _durationFromTexts(Iterable<String> texts) {
    for (final text in texts.toList().reversed) {
      final candidate = text
          .trim()
          .replaceAll(RegExp(r'[,\.]'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      final humanized = RegExp(
        r'^(?:(\d+)\s*(?:h|hrs?|hours?)\s*)?(?:(\d+)\s*(?:m|mins?|minutes?)\s*)?(?:(\d+)\s*(?:s|secs?|seconds?)\s*)?$',
        caseSensitive: false,
      ).firstMatch(candidate);
      if (humanized != null &&
          humanized.group(0)!.trim().isNotEmpty &&
          (humanized.group(1) != null ||
              humanized.group(2) != null ||
              humanized.group(3) != null)) {
        return Duration(
          hours: int.tryParse(humanized.group(1) ?? '0') ?? 0,
          minutes: int.tryParse(humanized.group(2) ?? '0') ?? 0,
          seconds: int.tryParse(humanized.group(3) ?? '0') ?? 0,
        );
      }
      if (!RegExp(r'^(?:\d{1,3}:)?[0-5]?\d:[0-5]\d$').hasMatch(candidate)) {
        continue;
      }
      final duration = parseDuration(candidate);
      if (duration != null) {
        return duration;
      }
    }
    return null;
  }

  static String? _description(Map<String, dynamic> renderer) {
    for (final key in ['description', 'descriptionSnippet', 'secondaryText']) {
      final value = parseRuns(renderer[key]);
      if (value.trim().isNotEmpty) {
        return value.trim();
      }
    }
    return null;
  }

  static List<String> _rendererDurationTexts(Map<String, dynamic> renderer) {
    final durationText =
        renderer['playbackProgress']?['musicPlaybackProgressRenderer']?['durationText'];
    final runs = durationText?['runs'];
    return [
      if (runs is List) ...runs.map((run) => run['text'] as String? ?? ''),
      parseRuns(renderer['lengthText']),
    ];
  }

  /// Parses a podcast show from a YTM search result row.
  static Show? parseShowFromResponsiveListItem(Map<String, dynamic> renderer) {
    final parsed = ytmusicapi_search.parseSearchResult(
      renderer,
      resultType: 'podcast',
    );
    final browseId = parsed['browseId'] as String?;
    if (browseId == null || browseId.isEmpty) {
      return null;
    }

    _rememberListenAgain(browseId, renderer);
    return Show(
      id: browseId,
      name: parsed['title'] as String? ?? 'Unknown Podcast',
      art: parseImageDetails({'thumbnails': parsed['thumbnails']}),
      pinned: _pinnedForItem(browseId, renderer),
      platformId: 'youtube_music',
    );
  }

  /// Parses a podcast episode from a responsive search result row.
  static ShowEpisode? parseEpisodeFromResponsiveListItem(
    Map<String, dynamic> renderer, {
    Show? fallbackShow,
  }) {
    final upstream = ytmusicapi_search.parseSearchResult(
      renderer,
      resultType: 'episode',
    );
    final id = upstream['videoId'] as String? ?? _videoId(renderer);
    final flexColumns = renderer['flexColumns'] as List? ?? [];
    if (id == null || flexColumns.isEmpty) {
      return null;
    }

    final title =
        upstream['title'] as String? ??
        parseRuns(
          flexColumns
              .first?['musicResponsiveListItemFlexColumnRenderer']?['text'],
        );
    final subtitleRuns = <Map<String, dynamic>>[];
    for (final column in flexColumns.skip(1)) {
      subtitleRuns.addAll(_runsFromColumn(column));
    }

    var show = fallbackShow;
    final upstreamPodcast = upstream['podcast'];
    if (show == null && upstreamPodcast is Map) {
      show = Show(
        id: upstreamPodcast['id'] as String?,
        name: upstreamPodcast['name'] as String? ?? '',
        platformId: 'youtube_music',
      );
    }
    final art = upstream['thumbnails'] == null
        ? parseImageDetails(
            renderer['thumbnail'] ?? renderer['thumbnailRenderer'],
          )
        : parseImageDetails({'thumbnails': upstream['thumbnails']});
    Duration? duration = _durationFromTexts([
      ..._rendererDurationTexts(renderer),
      ...subtitleRuns.map((run) => run['text'] as String? ?? ''),
    ]);
    String? publishedDate = upstream['date'] as String?;
    final episodeMetadata = <String>[];
    void addEpisodeMetadata(String value) {
      final text = value.trim();
      final isViews = RegExp(
        r'^\d[\d,.]*\s*[KMB]?\s+views?$',
        caseSensitive: false,
      ).hasMatch(text);
      final isDate = RegExp(
        r'^(?:today|yesterday|\d+\s+(?:hours?|minutes?|days?|weeks?|months?|years?)\s+ago|[A-Za-z]{3,9}\s+\d{1,2}(?:,\s*\d{4})?|\d{4}-\d{2}-\d{2}|\d{4})$',
        caseSensitive: false,
      ).hasMatch(text);
      if ((isViews || isDate) && !episodeMetadata.contains(text)) {
        episodeMetadata.add(text);
      }
    }

    if (publishedDate != null) {
      addEpisodeMetadata(publishedDate);
    }
    for (final run in subtitleRuns) {
      final text = (run['text'] as String? ?? '').trim();
      addEpisodeMetadata(text);
      final browseId = _browseIdFromRun(run);
      if (browseId != null &&
          (_pageTypeFromRun(run) ==
                  'MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE' ||
              browseId.startsWith('MPSP'))) {
        show ??= Show(id: browseId, name: text, platformId: 'youtube_music');
      }
      if (publishedDate == null &&
          text.isNotEmpty &&
          text.toLowerCase() != 'episode' &&
          text != '•' &&
          text != '|' &&
          browseId == null &&
          parseDuration(text) == null) {
        publishedDate = text;
      }
    }

    // Saved/New Episodes rows sometimes render the show name as plain text.
    // Keep it for playback even when YouTube omits the show browse endpoint.
    if (show == null) {
      for (final run in subtitleRuns) {
        final text = (run['text'] as String? ?? '').trim();
        if (text.isEmpty ||
            text == '•' ||
            text == '|' ||
            text.toLowerCase() == 'episode' ||
            parseDuration(text) != null ||
            RegExp(
              r'^(?:today|yesterday|\d+\s+(?:hours?|minutes?|days?|weeks?|months?|years?)\s+ago)$',
              caseSensitive: false,
            ).hasMatch(text)) {
          continue;
        }
        show = Show(name: text, platformId: 'youtube_music');
        break;
      }
    }
    if (show != null && publishedDate == show.name) {
      publishedDate = null;
      for (final run in subtitleRuns) {
        final text = (run['text'] as String? ?? '').trim();
        if (text.isNotEmpty &&
            text != show.name &&
            text != '•' &&
            text != '|' &&
            parseDuration(text) == null) {
          publishedDate = text;
          break;
        }
      }
    }
    if (episodeMetadata.isNotEmpty) {
      publishedDate = episodeMetadata.join(' • ');
    }

    final progress = _parseEpisodeProgress(renderer, duration);

    show ??= Show(name: 'YouTube Music Podcast', platformId: 'youtube_music');
    _rememberListenAgain(id, renderer);
    return ShowEpisode(
      id: id,
      title: title.isNotEmpty ? title : 'Unknown Episode',
      description: _description(renderer),
      art: art,
      duration: duration,
      publishedDate: publishedDate,
      show: show,
      bookmarkSeconds: progress.bookmarkSeconds,
      isHeard: progress.isHeard,
      progressPercentage: progress.progressPercentage,
      pinned: _pinnedForItem(id, renderer),
    );
  }

  /// Parses an episode from the multi-row renderer used by podcast browse pages.
  static ShowEpisode? parseEpisodeFromMultiRowListItem(
    Map<String, dynamic> renderer, {
    Show? show,
  }) {
    final parsed = ytmusicapi_podcasts.parseEpisode(renderer);
    final id = parsed['videoId'] as String?;
    if (id == null || id.isEmpty) {
      return null;
    }
    if (show == null) {
      final podcast = _asMap(parsed['podcast']);
      show = Show(
        id: podcast?['id'] as String?,
        name: podcast?['name'] as String? ?? 'YouTube Music Podcast',
        platformId: 'youtube_music',
      );
    }
    final subtitleRuns = renderer['subtitle']?['runs'];
    final duration = _durationFromTexts([
      parsed['duration'] as String? ?? '',
      ..._rendererDurationTexts(renderer),
      if (subtitleRuns is List)
        ...subtitleRuns.map((run) => run['text'] as String? ?? ''),
    ]);
    final progressValue = parsed['progressPercentage'];
    final rendererProgress = _parseEpisodeProgress(renderer, duration);
    final progress = progressValue is num
        ? (progressValue / 100).clamp(0.0, 1.0).toDouble()
        : rendererProgress.progressPercentage;
    return ShowEpisode(
      id: id,
      title: parsed['title'] as String? ?? 'Unknown Episode',
      description: parsed['description'] as String?,
      art: parseImageDetails({'thumbnails': parsed['thumbnails']}),
      duration: duration,
      publishedDate: parsed['date'] as String?,
      show: show,
      bookmarkSeconds:
          rendererProgress.bookmarkSeconds ??
          (progress != null && duration != null
              ? (progress * duration.inSeconds).round()
              : null),
      isHeard:
          rendererProgress.isHeard ?? (progress != null && progress >= 0.95),
      progressPercentage: progress,
      pinned: _pinnedForItem(id, renderer),
    );
  }

  static ({int? bookmarkSeconds, bool? isHeard, double? progressPercentage})
  _parseEpisodeProgress(Map<String, dynamic> renderer, Duration? duration) {
    int? bookmarkSeconds;
    bool? isHeard;
    double? progressPercentage;

    final overlays =
        renderer['thumbnailOverlay'] ??
        renderer['thumbnailOverlays'] ??
        renderer['thumbnailRenderer']?['musicThumbnailRenderer']?['thumbnailOverlays'];
    if (overlays is List) {
      for (final overlay in overlays) {
        if (overlay is! Map) {
          continue;
        }
        final resumeRenderer =
            overlay['thumbnailOverlayResumePlaybackRenderer'] ??
            overlay['musicPlayButtonRenderer']?['thumbnailOverlayResumePlaybackRenderer'];
        if (resumeRenderer is Map) {
          final percent = resumeRenderer['percentDurationWatched'];
          if (percent is num) {
            progressPercentage = (percent / 100.0).clamp(0.0, 1.0);
            if (duration != null && duration.inSeconds > 0) {
              bookmarkSeconds = (progressPercentage * duration.inSeconds)
                  .round();
            }
            if (percent >= 95) {
              isHeard = true;
            }
          }
        }
      }
    }

    final playbackProgressRenderer =
        renderer['playbackProgress']?['musicPlaybackProgressRenderer'];
    if (playbackProgressRenderer is Map) {
      final percent = playbackProgressRenderer['playbackProgressPercentage'];
      if (percent is num) {
        progressPercentage = (percent / 100.0).clamp(0.0, 1.0);
        if (duration != null && duration.inSeconds > 0) {
          bookmarkSeconds = (progressPercentage * duration.inSeconds).round();
        }
        if (percent >= 95) {
          isHeard = true;
        }
      }
    }

    final navEndpoint =
        renderer['navigationEndpoint'] ??
        renderer['playNavigationEndpoint'] ??
        renderer['onTap']?['watchEndpoint'];
    if (navEndpoint is Map) {
      final watchEndpoint = navEndpoint['watchEndpoint'] ?? navEndpoint;
      if (watchEndpoint is Map) {
        final startTime =
            watchEndpoint['startTimeSeconds'] ??
            watchEndpoint['playbackProgressSeconds'];
        if (startTime is num && startTime > 0) {
          bookmarkSeconds = startTime.toInt();
          if (duration != null && duration.inSeconds > 0) {
            progressPercentage = (bookmarkSeconds / duration.inSeconds).clamp(
              0.0,
              1.0,
            );
          }
        }
      }
    }

    return (
      bookmarkSeconds: bookmarkSeconds,
      isHeard: isHeard,
      progressPercentage: progressPercentage,
    );
  }

  /// Extracts concatenated text from a runs array or simpleText.
  static String parseRuns(dynamic runsData) {
    if (runsData == null) {
      return '';
    }
    if (runsData is Map) {
      final simpleText = runsData['simpleText'];
      if (simpleText is String) {
        return simpleText;
      }
      return ytmusicapi_utils.parseRuns(runsData);
    } else if (runsData is List) {
      return ytmusicapi_utils.parseRuns({'runs': runsData});
    }
    return '';
  }

  /// Parses clock-style and humanized YouTube duration text into a [Duration].
  static Duration? parseDuration(String? text) {
    if (text == null || text.trim().isEmpty) {
      return null;
    }
    final upstreamSeconds = ytmusicapi_utils.parseDuration(text);
    if (upstreamSeconds != null) {
      return Duration(seconds: upstreamSeconds);
    }
    final normalizedText = text
        .trim()
        .replaceAll(RegExp(r'[,\.]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final humanized = RegExp(
      r'^(?:(\d+)\s*(?:h|hrs?|hours?)\s*)?(?:(\d+)\s*(?:m|mins?|minutes?)\s*)?(?:(\d+)\s*(?:s|secs?|seconds?)\s*)?$',
      caseSensitive: false,
    ).firstMatch(normalizedText);
    if (humanized != null &&
        humanized.group(0)!.trim().isNotEmpty &&
        (humanized.group(1) != null ||
            humanized.group(2) != null ||
            humanized.group(3) != null)) {
      return Duration(
        hours: int.tryParse(humanized.group(1) ?? '0') ?? 0,
        minutes: int.tryParse(humanized.group(2) ?? '0') ?? 0,
        seconds: int.tryParse(humanized.group(3) ?? '0') ?? 0,
      );
    }
    final match = RegExp(
      r'^(?:(\d{1,3}):)?([0-5]?\d):([0-5]\d)$',
    ).firstMatch(text.trim());
    if (match == null) {
      final totalSec = int.tryParse(text.trim());
      if (totalSec != null && totalSec > 0) {
        return Duration(seconds: totalSec);
      }
      return null;
    }
    final hours = match.group(1) != null ? int.parse(match.group(1)!) : 0;
    final minutes = int.parse(match.group(2)!);
    final seconds = int.parse(match.group(3)!);
    return Duration(hours: hours, minutes: minutes, seconds: seconds);
  }

  /// Upscales YouTube thumbnail URL to higher resolution.
  static String? upscaleThumbnail(String? url) {
    if (url == null || url.isEmpty) {
      return null;
    }
    // YouTube image URLs commonly encode the requested size as either
    // `=w120-h120...` or `=s120...`. Preserve the remaining transform flags
    // (crop, quality, background) while asking the image server for a larger
    // source. The old `w` rewrite discarded those flags and missed URLs whose
    // dimensions were expressed with `s`.
    final dimensions = RegExp(r'=w\d+-h\d+').firstMatch(url);
    if (dimensions != null) {
      return url.replaceRange(dimensions.start, dimensions.end, '=w1200-h1200');
    }
    final size = RegExp(r'=s\d+').firstMatch(url);
    if (size != null) {
      return url.replaceRange(size.start, size.end, '=s1200');
    }
    return url;
  }

  /// Extracts ImageDetails from thumbnail renderers.
  static ImageDetails? parseImageDetails(dynamic thumbnailObj) {
    if (thumbnailObj == null) {
      return null;
    }
    List? thumbnails;
    if (thumbnailObj is Map) {
      thumbnails =
          thumbnailObj['thumbnails'] as List? ??
          thumbnailObj['musicThumbnailRenderer']?['thumbnail']?['thumbnails']
              as List? ??
          thumbnailObj['thumbnail']?['thumbnails'] as List? ??
          thumbnailObj['croppedSquareThumbnailRenderer']?['thumbnail']?['thumbnails']
              as List?;
    }
    if (thumbnails == null || thumbnails.isEmpty) {
      return null;
    }

    final entries = thumbnails
        .whereType<Map>()
        .where((thumbnail) => thumbnail['url'] is String)
        .where((thumbnail) => (thumbnail['url'] as String).isNotEmpty)
        .toList();
    if (entries.isEmpty) {
      return null;
    }
    // Renderer arrays are usually ordered by size, but that is not guaranteed
    // across browse, album, and playlist responses. Prefer the largest declared
    // rendition rather than relying on response order.
    int resolution(Map thumbnail) {
      final width = thumbnail['width'] as num?;
      final height = thumbnail['height'] as num?;
      if (width != null && height != null) {
        return width.toInt() * height.toInt();
      }
      final url = thumbnail['url'] as String? ?? '';
      final dimensions = RegExp(r'=w(\d+)-h(\d+)').firstMatch(url);
      if (dimensions != null) {
        return (int.tryParse(dimensions.group(1)!) ?? 0) *
            (int.tryParse(dimensions.group(2)!) ?? 0);
      }
      final size = RegExp(r'=s(\d+)').firstMatch(url);
      return int.tryParse(size?.group(1) ?? '') ?? 0;
    }

    entries.sort((a, b) {
      return resolution(a).compareTo(resolution(b));
    });
    final urls = entries.map((entry) => entry['url'] as String).toList();
    final smallest = urls.first;
    final largest = urls.last;
    final upscaled = upscaleThumbnail(largest);

    return ImageDetails(thumbUrl: smallest, fullUrl: upscaled ?? largest);
  }

  /// Parses a [Track] from a `musicResponsiveListItemRenderer`.
  static Track? parseTrackFromResponsiveListItem(
    Map<String, dynamic> renderer, {
    Album? fallbackAlbum,
  }) {
    final parsed = ytmusicapi_search.parseSearchResult(
      renderer,
      resultType: 'song',
    );
    final videoId = parsed['videoId'] as String? ?? _videoId(renderer);
    if (videoId == null || videoId.isEmpty) {
      return null;
    }
    final parsedArtists = _modelArtists(parsed['artists']);
    final artists = parsedArtists.isNotEmpty
        ? parsedArtists
        : (fallbackAlbum?.artists ?? <Artist>[]);
    final parsedAlbum = _modelAlbum(parsed['album']);
    final album =
        fallbackAlbum != null &&
            (parsedAlbum?.id == fallbackAlbum.id || parsedAlbum == null)
        ? fallbackAlbum
        : parsedAlbum;
    final seconds = parsed['duration_seconds'];
    final videoType = parsed['videoType'] as String?;
    final badges = renderer['badges'] as List? ?? const [];
    final isLive =
        parsed['isLive'] == true ||
        videoType == 'MUSIC_VIDEO_TYPE_LIVE' ||
        badges.any(
          (badge) =>
              badge['liveBadgeRenderer'] != null ||
              badge['musicInlineBadgeRenderer']?['icon']?['iconType'] ==
                  'MUSIC_LIVE_BADGE' ||
              badge['musicInlineBadgeRenderer']?['icon']?['iconType'] == 'LIVE',
        );
    final likeStatus = _likeStatusFromMenu(renderer);
    _rememberListenAgain(videoId, renderer);
    return Track(
      id: isLive ? 'radio:$videoId' : videoId,
      title: parsed['title'] as String? ?? 'Unknown Title',
      artists: artists,
      navigableArtists: artists,
      album: album,
      duration: seconds is int ? Duration(seconds: seconds) : null,
      albumArt:
          parseImageDetails({'thumbnails': parsed['thumbnails']}) ??
          parseImageDetails(
            renderer['thumbnailRenderer'] ?? renderer['thumbnail'],
          ),
      explicit: parsed['isExplicit'] == true,
      favorite: likeStatus == null ? null : likeStatus == 'LIKE',
      pinned: _pinnedForItem(videoId, renderer),
      unavailable: parsed['isAvailable'] == false,
      platformId: 'youtube_music',
      trackNumber: (parsed['trackNumber'] as int?) ??
          int.tryParse(parsed['rank']?.toString() ?? ''),
      variation: _chartVariation(renderer) ?? _chartVariation(parsed),
    );
  }

  static Track? parseTrackFromParsedPlaylistItem(
    Map<String, dynamic> parsed, {
    Album? fallbackAlbum,
  }) {
    final videoId = parsed['videoId'] as String?;
    if (videoId == null || videoId.isEmpty) {
      return null;
    }
    final seconds = parsed['duration_seconds'];
    final durationText =
        parsed['duration'] as String? ?? parsed['length'] as String?;
    final duration = seconds is int
        ? Duration(seconds: seconds)
        : parseDuration(durationText);
    final parsedArtists = _modelArtists(parsed['artists']);
    final artists = parsedArtists.isNotEmpty
        ? parsedArtists
        : (fallbackAlbum?.artists ?? <Artist>[]);
    final videoType = parsed['videoType'] as String?;
    final isLive =
        parsed['isLive'] == true || videoType == 'MUSIC_VIDEO_TYPE_LIVE';
    return Track(
      id: isLive ? 'radio:$videoId' : videoId,
      title: parsed['title'] as String? ?? 'Unknown Track',
      artists: artists,
      navigableArtists: artists,
      album: _modelAlbum(parsed['album']) ?? fallbackAlbum,
      duration: duration,
      albumArt:
          parseImageDetails({'thumbnails': parsed['thumbnails']}) ??
          parseImageDetails({'thumbnails': parsed['thumbnail']}) ??
          fallbackAlbum?.art,
      explicit: parsed['isExplicit'] == true,
      favorite: parsed['likeStatus'] == 'LIKE',
      pinned: parsed['pinnedToListenAgain'] == true,
      platformId: 'youtube_music',
      trackNumber: (parsed['trackNumber'] as int?) ??
          int.tryParse(parsed['rank']?.toString() ?? ''),
      variation: _chartVariation(parsed),
    );
  }

  /// Casts a normalized ytmusicapi home item into Saturn's model types.
  static HomePageItem? parseHomeItem(Map<String, dynamic> data) {
    final browseId = data['browseId'] as String?;
    final playlistId = data['playlistId'] as String?;
    if (browseId != null && browseId.startsWith('MPRE')) {
      final artists = _modelArtists(data['artists']);
      return HomePageItem(
        type: HomePageItemType.ALBUM,
        value: Album(
          id: browseId,
          title: data['title'] as String?,
          artists: artists,
          art: parseImageDetails({'thumbnails': data['thumbnails']}),
          releaseDate: data['year']?.toString(),
          pinned: data['pinnedToListenAgain'] == true,
          platformId: 'youtube_music',
        ),
      );
    }
    if (browseId != null && browseId.startsWith('MPSP')) {
      final channel = _asMap(data['channel']);
      return HomePageItem(
        type: HomePageItemType.SHOW,
        value: Show(
          id: browseId,
          name: data['title'] as String? ?? 'Podcast',
          creator: channel?['name'] as String?,
          art: parseImageDetails({'thumbnails': data['thumbnails']}),
          pinned: data['pinnedToListenAgain'] == true,
          platformId: 'youtube_music',
        ),
      );
    }
    if (browseId != null &&
        (browseId.startsWith('UC') || browseId.startsWith('MPLA'))) {
      return HomePageItem(
        type: HomePageItemType.ARTIST,
        value: Artist(
          id: browseId,
          name: data['title'] as String?,
          picture: parseImageDetails({'thumbnails': data['thumbnails']}),
          pinned: data['pinnedToListenAgain'] == true,
          platformId: 'youtube_music',
        ),
      );
    }
    if ((browseId != null &&
            (browseId.startsWith('VLRD') || browseId.startsWith('RD'))) ||
        (playlistId != null &&
            playlistId.startsWith('RD') &&
            data['videoId'] == null)) {
      final id = playlistId ??
          (browseId?.startsWith('VL') == true
              ? browseId!.substring(2)
              : browseId);
      return HomePageItem(
        type: HomePageItemType.RADIO,
        playMix: true,
        value: LiveRadio(
          id: id,
          title: data['title'] as String? ?? 'Mix',
          customImageUrl: parseImageDetails({
            'thumbnails': data['thumbnails'],
          })?.fullUrl,
          platformId: 'youtube_music',
          isMix: true,
        ),
      );
    }
    if (browseId != null &&
        (browseId.startsWith('VL') || browseId.startsWith('PL'))) {
      return HomePageItem(
        type: HomePageItemType.PLAYLIST,
        value: Playlist(
          id: browseId.startsWith('VL') ? browseId : 'VL$browseId',
          title: data['title'] as String?,
          image: parseImageDetails({'thumbnails': data['thumbnails']}),
          pinned: data['pinnedToListenAgain'] == true,
          platformId: 'youtube_music',
        ),
      );
    }
    if (playlistId != null &&
        playlistId.isNotEmpty &&
        data['videoId'] == null) {
      return HomePageItem(
        type: HomePageItemType.PLAYLIST,
        value: Playlist(
          id: playlistId.startsWith('VL') ? playlistId : 'VL$playlistId',
          title: data['title'] as String?,
          image: parseImageDetails({'thumbnails': data['thumbnails']}),
          pinned: data['pinnedToListenAgain'] == true,
          platformId: 'youtube_music',
        ),
      );
    }
    if (browseId != null &&
        (browseId.startsWith('MPED') ||
            data['videoType'] == 'MUSIC_VIDEO_TYPE_PODCAST_EPISODE')) {
      final duration = parseDuration(
        data['duration'] as String? ?? data['length'] as String?,
      );
      final rawProgress = data['progressPercentage'];
      final progress = rawProgress is num
          ? (rawProgress / 100).clamp(0.0, 1.0).toDouble()
          : null;
      final podcast = _asMap(data['podcast']);
      final show = Show(
        id: podcast?['id'] as String?,
        name: podcast?['name'] as String? ?? 'YouTube Music Podcast',
        platformId: 'youtube_music',
      );
      return HomePageItem(
        type: HomePageItemType.EPISODE,
        value: ShowEpisode(
          id: data['videoId'] as String?,
          title: data['title'] as String? ?? 'Unknown Episode',
          description: data['description'] as String?,
          show: show,
          art: parseImageDetails({'thumbnails': data['thumbnails']}),
          duration: duration,
          publishedDate: data['date'] as String?,
          bookmarkSeconds: duration != null && progress != null
              ? (duration.inSeconds * progress).round()
              : null,
          progressPercentage: progress,
          isHeard: progress != null && progress >= 0.95,
          pinned: data['pinnedToListenAgain'] == true,
        ),
      );
    }
    if (data['videoId'] is String) {
      final track = parseTrackFromParsedPlaylistItem(data);
      if (track == null) {
        return null;
      }
      if (data['isLive'] == true ||
          data['videoType'] == 'MUSIC_VIDEO_TYPE_LIVE') {
        track.id = 'radio:${track.id}';
      }
      track.pinned = data['pinnedToListenAgain'] == true;
      return HomePageItem(
        type: HomePageItemType.TRACK,
        value: track,
        playMix: true,
      );
    }
    return null;
  }

  static bool isTwoRowLive(Map twoRow) {
    for (final key in const ['badges', 'subtitleBadges']) {
      final badges = twoRow[key];
      if (badges is! List) continue;
      for (final b in badges) {
        if (b is! Map) continue;
        if (b.containsKey('liveBadgeRenderer')) return true;
        final iconType = b['musicInlineBadgeRenderer']?['icon']?['iconType'];
        if (iconType == 'MUSIC_LIVE_BADGE' || iconType == 'LIVE') return true;
        final runs = b['liveBadgeRenderer']?['label']?['runs'] as List?;
        if (runs != null &&
            runs.any((r) => r['text']?.toString().toLowerCase() == 'live')) {
          return true;
        }
      }
    }
    return false;
  }

  static bool responsiveItemHasPodcastShow(dynamic renderer) {
    if (renderer is! Map) return false;
    final columns = renderer['flexColumns'] as List? ?? [];
    for (final column in columns) {
      final runs =
          column?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs']
              as List? ??
          [];
      for (final run in runs) {
        final endpoint = run is Map ? run['navigationEndpoint'] : null;
        final browseEndpoint = endpoint is Map
            ? endpoint['browseEndpoint']
            : null;
        final browseId = browseEndpoint is Map
            ? browseEndpoint['browseId']
            : null;
        if (browseId is String && browseId.startsWith('MPSP')) return true;
      }
    }
    return false;
  }

  static HomePageItem? parseBrowseItem(dynamic rawItem) {
    if (rawItem is! Map) return null;

    if (rawItem['musicTwoRowItemRenderer'] != null) {
      final twoRow = Map<String, dynamic>.from(
        rawItem['musicTwoRowItemRenderer'] as Map,
      );
      final nav = twoRow['navigationEndpoint']?['browseEndpoint'];
      final pageType = nav?['browseEndpointContextSupportedConfigs']
              ?['browseEndpointContextMusicConfig']?['pageType'] as String?;
      final browseId = nav?['browseId'] as String?;

      if (pageType == 'MUSIC_PAGE_TYPE_ALBUM' ||
          (browseId != null && browseId.startsWith('MPRE'))) {
        final a = parseAlbumFromTwoRowItem(twoRow);
        if (a != null) return HomePageItem(type: HomePageItemType.ALBUM, value: a);
      } else if (browseId != null &&
          (browseId.startsWith('VLRD') || browseId.startsWith('RD'))) {
        final title = parseRuns(twoRow['title']);
        final subtitle = parseRuns(twoRow['subtitle']);
        final art = parseImageDetails(twoRow['thumbnailRenderer'] ?? twoRow['thumbnail']);
        final cleanId = browseId.startsWith('VL') ? browseId.substring(2) : browseId;
        final radio = LiveRadio(
          id: cleanId,
          title: title.isNotEmpty ? title : 'Mix',
          description: subtitle,
          customImageUrl: art?.fullUrl,
          pinned: isPinnedToListenAgain(twoRow),
          platformId: 'youtube_music',
          isMix: true,
        );
        return HomePageItem(type: HomePageItemType.RADIO, value: radio, playMix: true);
      } else if (pageType == 'MUSIC_PAGE_TYPE_PLAYLIST' ||
          (browseId != null && browseId.startsWith('VL'))) {
        final p = parsePlaylistFromTwoRowItem(twoRow);
        if (p != null) {
          final isMix = p.id != null && (p.id!.startsWith('VLRD') || p.id!.startsWith('RD'));
          return HomePageItem(
            type: isMix ? HomePageItemType.RADIO : HomePageItemType.PLAYLIST,
            value: isMix
                ? LiveRadio(
                    id: p.id!.startsWith('VL') ? p.id!.substring(2) : p.id!,
                    title: p.title ?? 'Mix',
                    customImageUrl: p.image?.fullUrl,
                    pinned: p.pinned,
                    platformId: 'youtube_music',
                    isMix: true,
                  )
                : p,
            playMix: isMix,
          );
        }
      } else if (pageType == 'MUSIC_PAGE_TYPE_ARTIST' ||
          (browseId != null && (browseId.startsWith('UC') || browseId.startsWith('MPLA')))) {
        final art = parseArtistFromTwoRowItem(twoRow);
        if (art != null) return HomePageItem(type: HomePageItemType.ARTIST, value: art);
      } else if (pageType == 'MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE' ||
          (browseId != null && browseId.startsWith('MPSP'))) {
        final s = parseShowFromTwoRowItem(twoRow);
        if (s != null) return HomePageItem(type: HomePageItemType.SHOW, value: s);
      } else if (pageType == 'MUSIC_PAGE_TYPE_NON_MUSIC_AUDIO_TRACK_PAGE' ||
          (browseId != null && browseId.startsWith('MPED'))) {
        final ep = parseEpisodeFromTwoRowItem(Map<String, dynamic>.from(twoRow));
        if (ep != null) return HomePageItem(type: HomePageItemType.EPISODE, value: ep);
      } else {
        final watch = twoRow['navigationEndpoint']?['watchEndpoint'] ??
            twoRow['thumbnailOverlay']?['musicItemThumbnailOverlayRenderer']?['content']?['musicPlayButtonRenderer']?['playNavigationEndpoint']?['watchEndpoint'] ??
            twoRow['onTap']?['watchEndpoint'];
        final watchPlaylistId = watch?['playlistId'] as String?;
        final videoId = watch?['videoId'] as String?;
        final isLive = isTwoRowLive(twoRow);

        if (isLive && videoId != null) {
          final t = parseRuns(twoRow['title']);
          final s = parseRuns(twoRow['subtitle']);
          final art = parseImageDetails(twoRow['thumbnailRenderer'] ?? twoRow['thumbnail']);
          final radio = LiveRadio(
            id: videoId,
            title: t.isNotEmpty ? t : 'Station',
            description: s,
            customImageUrl: art?.fullUrl,
            pinned: isPinnedToListenAgain(twoRow),
            platformId: 'youtube_music',
          );
          return HomePageItem(type: HomePageItemType.RADIO, value: radio);
        }
        if (videoId != null) {
          final t = parseTrackFromTwoRowItem(twoRow);
          if (t != null) return HomePageItem(type: HomePageItemType.TRACK, value: t, playMix: true);
        }
        if (watchPlaylistId != null && (watchPlaylistId.startsWith('RD') || watchPlaylistId.startsWith('VLRD'))) {
          final cleanId = watchPlaylistId.startsWith('VL') ? watchPlaylistId.substring(2) : watchPlaylistId;
          final t = parseRuns(twoRow['title']);
          final s = parseRuns(twoRow['subtitle']);
          final art = parseImageDetails(twoRow['thumbnailRenderer'] ?? twoRow['thumbnail']);
          final radio = LiveRadio(
            id: cleanId,
            title: t.isNotEmpty ? t : 'Mix',
            description: s,
            customImageUrl: art?.fullUrl,
            pinned: isPinnedToListenAgain(twoRow),
            platformId: 'youtube_music',
            isMix: true,
          );
          return HomePageItem(type: HomePageItemType.RADIO, value: radio, playMix: true);
        }
        final t = parseTrackFromTwoRowItem(twoRow);
        if (t != null) return HomePageItem(type: HomePageItemType.TRACK, value: t, playMix: true);
      }
    }

    if (rawItem['musicResponsiveListItemRenderer'] != null) {
      final renderer = Map<String, dynamic>.from(rawItem['musicResponsiveListItemRenderer'] as Map);
      final navigation = renderer['navigationEndpoint'];
      final endpoint = navigation is Map ? navigation['browseEndpoint'] : null;
      final endpointConfig = endpoint is Map ? endpoint['browseEndpointContextSupportedConfigs'] : null;
      final musicConfig = endpointConfig is Map ? endpointConfig['browseEndpointContextMusicConfig'] : null;
      final pageType = musicConfig is Map ? musicConfig['pageType'] : null;

      if (pageType == 'MUSIC_PAGE_TYPE_ARTIST') {
        final art = parseChartArtistFromResponsiveListItem(renderer) ??
            (endpoint is Map && endpoint['browseId'] != null
                ? Artist(
                    id: endpoint['browseId'] as String?,
                    name: parseRuns(renderer['flexColumns']?[0]?['musicResponsiveListItemFlexColumnRenderer']?['text']),
                    picture: parseImageDetails(renderer['thumbnail']?['musicThumbnailRenderer']?['thumbnail']),
                    platformId: 'youtube_music',
                  )
                : null);
        if (art != null) return HomePageItem(type: HomePageItemType.ARTIST, value: art);
      }

      final browseId = endpoint is Map ? endpoint['browseId'] as String? : null;
      final isEpisode = (browseId != null && browseId.startsWith('MPED')) ||
          responsiveItemHasPodcastShow(renderer);
      if (isEpisode) {
        final ep = parseEpisodeFromResponsiveListItem(renderer);
        if (ep != null) return HomePageItem(type: HomePageItemType.EPISODE, value: ep);
      }

      final t = parseTrackFromResponsiveListItem(renderer);
      if (t != null) return HomePageItem(type: HomePageItemType.TRACK, value: t, playMix: true);
    }

    if (rawItem['musicMultiRowListItemRenderer'] != null) {
      final renderer = Map<String, dynamic>.from(rawItem['musicMultiRowListItemRenderer'] as Map);
      final ep = parseEpisodeFromMultiRowListItem(renderer);
      if (ep != null) return HomePageItem(type: HomePageItemType.EPISODE, value: ep);
    }

    if (rawItem['musicNavigationButtonRenderer'] != null) {
      final btn = rawItem['musicNavigationButtonRenderer'] as Map;
      final btnTitle = parseRuns(btn['buttonText']);
      final endpoint = btn['clickCommand']?['browseEndpoint'];
      final browseId = endpoint?['browseId'] as String?;
      final params = endpoint?['params'] as String?;
      final path = (browseId != null && params != null && params.isNotEmpty)
          ? '$browseId?params=$params'
          : (browseId ?? '');
      final colorInt = btn['solid']?['leftStripeColor'] ?? btn['color'];
      Color? stripeColor;
      if (colorInt is int) stripeColor = Color(colorInt);

      final channel = DeezerChannel(
        id: path,
        title: btnTitle,
        target: path,
        backgroundColor: stripeColor,
      );
      return HomePageItem(
        type: HomePageItemType.PLATFORM,
        platformType: 'channel',
        value: channel,
        platformId: 'youtube_music',
      );
    }

    return null;
  }

  static HomePageSection? parseBrowseSection(Map section) {
    if (section['musicCarouselShelfRenderer'] != null) {
      final carousel = section['musicCarouselShelfRenderer'] as Map;
      final header = carousel['header']?['musicCarouselShelfBasicHeaderRenderer'];
      final title = parseRuns(header?['title']);
      final strapline = parseRuns(header?['strapline']);
      final thumbObj = header?['thumbnail'];
      final headerThumb = thumbObj?['musicThumbnailRenderer']?['thumbnail'] ?? thumbObj;
      final headerImageUrl = parseImageDetails(headerThumb)?.fullUrl;

      final moreBtn = header?['moreContentButton']?['buttonRenderer'];
      final titleRuns = header?['title']?['runs'] as List? ?? [];
      final titleNav = (titleRuns.isNotEmpty && titleRuns[0]['navigationEndpoint'] != null)
          ? titleRuns[0]['navigationEndpoint']
          : null;
      final nav = moreBtn?['navigationEndpoint'] ?? titleNav;
      String? pagePath;
      if (nav != null) {
        if (nav['browseEndpoint'] != null) {
          final bId = nav['browseEndpoint']['browseId'] as String?;
          final p = nav['browseEndpoint']['params'] as String?;
          if (bId != null) {
            pagePath = (p != null && p.isNotEmpty) ? '$bId?params=$p' : bId;
          }
        } else if (nav['watchEndpoint'] != null) {
          final videoId = nav['watchEndpoint']['videoId'] as String?;
          final playlistId = nav['watchEndpoint']['playlistId'] as String?;
          if (playlistId != null && playlistId.startsWith('RD')) {
            pagePath = 'mix:${videoId ?? playlistId.substring(2)}';
          } else if (playlistId != null) {
            pagePath = 'playlist:$playlistId';
          } else if (videoId != null) {
            pagePath = 'play:$videoId';
          }
        }
      }

      final items = carousel['contents'] as List? ?? [];
      final parsedItems = <HomePageItem>[];
      for (final it in items) {
        final parsed = parseBrowseItem(it);
        if (parsed != null) parsedItems.add(parsed);
      }
      if (parsedItems.isEmpty) return null;

      return HomePageSection(
        title: title.isNotEmpty ? title : null,
        subtitle: strapline.isNotEmpty ? strapline : null,
        image: headerImageUrl,
        items: parsedItems,
        layout: HomePageSectionLayout.ROW,
        pagePath: pagePath,
        hasMore: pagePath != null,
      );
    }

    if (section['gridRenderer'] != null) {
      final grid = section['gridRenderer'] as Map;
      final title = parseRuns(grid['header']?['gridHeaderRenderer']?['title']);
      final items = grid['items'] as List? ?? [];
      final parsedItems = <HomePageItem>[];
      for (final it in items) {
        final parsed = parseBrowseItem(it);
        if (parsed != null) parsedItems.add(parsed);
      }
      if (parsedItems.isEmpty) return null;

      return HomePageSection(
        title: title.isNotEmpty ? title : null,
        items: parsedItems,
        layout: HomePageSectionLayout.GRID,
      );
    }

    if (section['musicShelfRenderer'] != null) {
      final shelf = section['musicShelfRenderer'] as Map;
      final title = parseRuns(
        shelf['title'] ?? shelf['header']?['musicShelfHeaderRenderer']?['title'],
      );
      final items = shelf['contents'] as List? ?? [];
      final parsedItems = <HomePageItem>[];
      for (final it in items) {
        final parsed = parseBrowseItem(it);
        if (parsed != null) parsedItems.add(parsed);
      }
      if (parsedItems.isEmpty) return null;

      return HomePageSection(
        title: title.isNotEmpty ? title : null,
        items: parsedItems,
        layout: HomePageSectionLayout.ROW,
      );
    }

    if (section['musicPlaylistShelfRenderer'] != null) {
      final shelf = section['musicPlaylistShelfRenderer'] as Map;
      final title = parseRuns(
        shelf['title'] ?? shelf['header']?['musicShelfHeaderRenderer']?['title'],
      );
      final items = shelf['contents'] as List? ?? [];
      final parsedItems = <HomePageItem>[];
      for (final it in items) {
        final parsed = parseBrowseItem(it);
        if (parsed != null) parsedItems.add(parsed);
      }
      if (parsedItems.isEmpty) return null;

      return HomePageSection(
        title: title.isNotEmpty ? title : null,
        items: parsedItems,
        layout: HomePageSectionLayout.ROW,
      );
    }

    return null;
  }

  static const _typeSpecifierNames = <String>{
    'song',
    'chanson',
    'canción',
    'cancion',
    'lied',
    'musique',
    'video',
    'vidéo',
    'video clip',
    'single',
    'ep',
    'album',
    'track',
    'podcast',
    'episode',
    'épisode',
    'artist',
    'artiste',
  };

  static bool _isTypeSpecifier(String? name, String? id) {
    if (name == null || name.trim().isEmpty) return true;
    if (id != null && id.isNotEmpty) return false;
    return _typeSpecifierNames.contains(name.toLowerCase().trim());
  }

  static List<Artist> _modelArtists(dynamic value) {
    if (value is! List) {
      return [];
    }
    return value
        .whereType<Map>()
        .map((artist) => Map<String, dynamic>.from(artist))
        .where((artist) {
          final id = artist['id'] as String?;
          final name = artist['name'] as String?;
          return !_isTypeSpecifier(name, id);
        })
        .map(
          (artist) => Artist(
            id: artist['id'] as String?,
            name: (artist['name'] as String?)?.trim(),
            platformId: 'youtube_music',
          ),
        )
        .toList();
  }

  /// Casts ytmusicapi's normalized library album result to Saturn's model.
  static Album? parseLibraryAlbum(Map<String, dynamic> data) {
    final id = data['browseId'] as String?;
    if (id == null || id.isEmpty) {
      return null;
    }
    final type = (data['type'] as String? ?? '').toLowerCase();
    return Album(
      id: id,
      title: data['title'] as String?,
      artists: _modelArtists(data['artists']),
      art: parseImageDetails({'thumbnails': data['thumbnails']}),
      releaseDate: data['year']?.toString(),
      type: type.contains('single') ? AlbumType.SINGLE : AlbumType.ALBUM,
      pinned: data['pinnedToListenAgain'] == true,
      platformId: 'youtube_music',
    );
  }

  /// Casts ytmusicapi's normalized library artist result to Saturn's model.
  static Artist? parseLibraryArtist(Map<String, dynamic> data) {
    final id = data['browseId'] as String?;
    if (id == null || id.isEmpty) {
      return null;
    }
    return Artist(
      id: id,
      name: data['artist'] as String?,
      picture: parseImageDetails({'thumbnails': data['thumbnails']}),
      topSongsPlaylistId:
          data['shuffleId'] as String? ?? data['radioId'] as String?,
      radio: data['radioId'] is String,
      pinned: data['pinnedToListenAgain'] == true,
      platformId: 'youtube_music',
    );
  }

  /// Casts ytmusicapi's normalized library podcast result to Saturn's model.
  static Show? parseLibraryShow(Map<String, dynamic> data) {
    final id = data['browseId'] as String?;
    if (id == null || id.isEmpty) {
      return null;
    }
    final channel = _asMap(data['channel']);
    return Show(
      id: id,
      name: data['title'] as String? ?? 'Unknown Podcast',
      creator: channel?['name'] as String?,
      art: parseImageDetails({'thumbnails': data['thumbnails']}),
      pinned: data['pinnedToListenAgain'] == true,
      platformId: 'youtube_music',
    );
  }

  static Album? _modelAlbum(dynamic value) {
    final album = _asMap(value);
    if (album == null) {
      return null;
    }
    return Album(
      id: album['id'] as String?,
      title: album['name'] as String?,
      artists: _modelArtists(album['artists']),
      platformId: 'youtube_music',
    );
  }

  /// Ports ytmusicapi's `parse_song_menu_data` behavior for track menus.
  /// State and feedback actions are determined from service icon types, which
  /// remain stable across languages, rather than translated menu labels.
  static YouTubeMusicListenAgainData parseSongMenuData(
    Map<String, dynamic>? data,
  ) {
    if (data == null) {
      return const YouTubeMusicListenAgainData();
    }

    final renderer =
        _asMap(data['musicTwoRowItemRenderer']) ??
        _asMap(data['musicResponsiveListItemRenderer']) ??
        _asMap(data['musicMultiRowListItemRenderer']) ??
        data;
    final parsed = ytmusicapi_songs.parseSongMenuData(renderer);
    final tokens = _asMap(parsed['listenAgainFeedbackTokens']);
    final libraryTokens = _asMap(parsed['feedbackTokens']);
    var isPinned = parsed['pinnedToListenAgain'] == true;
    final badgeLists = [renderer['subtitleBadges'], renderer['badges']];
    for (final badgeList in badgeLists.whereType<List>()) {
      for (final badge in badgeList) {
        final inlineBadge = _asMap(_asMap(badge)?['musicInlineBadgeRenderer']);
        final iconType = _asMap(inlineBadge?['icon'])?['iconType'];
        final label = _asMap(
          _asMap(inlineBadge?['accessibilityData'])?['accessibilityData'],
        )?['label'];
        if (iconType == 'KEEP' &&
            label is String &&
            label.toLowerCase().contains('pinned')) {
          isPinned = true;
        }
      }
    }
    return YouTubeMusicListenAgainData(
      isPinned: isPinned,
      inLibrary: parsed['inLibrary'] as bool?,
      pinFeedbackToken: tokens?['pin'] as String?,
      unpinFeedbackToken: tokens?['unpin'] as String?,
      addLibraryFeedbackToken: libraryTokens?['add'] as String?,
      removeLibraryFeedbackToken: libraryTokens?['remove'] as String?,
      historyFeedbackToken: parsed['feedbackToken'] as String?,
    );
  }

  /// Backwards-compatible name used by existing UI call sites.
  static YouTubeMusicListenAgainData parseListenAgainMenuData(
    Map<String, dynamic>? data,
  ) => parseSongMenuData(data);

  static Map<String, dynamic>? _asMap(dynamic value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    return null;
  }

  /// Reads Listen again pin state from the item's context menu.
  static bool isPinnedToListenAgain(Map<String, dynamic> renderer) {
    return parseListenAgainMenuData(renderer).isPinned;
  }

  /// Parses an [Album] from a `musicResponsiveListItemRenderer` (from Album search).
  static Album? parseAlbumFromResponsiveListItem(
    Map<String, dynamic> renderer,
  ) {
    final parsed = ytmusicapi_search.parseSearchResult(
      renderer,
      resultType: 'album',
    );
    final browseId = parsed['browseId'] as String?;
    if (browseId == null || browseId.isEmpty) {
      return null;
    }
    final year = parsed['year']?.toString();
    final type = (parsed['type'] as String?)?.toLowerCase();

    _rememberListenAgain(browseId, renderer);
    return Album(
      id: browseId,
      title: parsed['title'] as String? ?? 'Unknown Album',
      artists: _modelArtists(parsed['artists']),
      art: parseImageDetails({'thumbnails': parsed['thumbnails']}),
      type: type == 'single' ? AlbumType.SINGLE : AlbumType.ALBUM,
      releaseDate: year,
      pinned: _pinnedForItem(browseId, renderer),
      platformId: 'youtube_music',
    );
  }

  /// Parses an [Artist] from a `musicResponsiveListItemRenderer` (from Artist search).
  static Artist? parseArtistFromResponsiveListItem(
    Map<String, dynamic> renderer,
  ) {
    final parsed = ytmusicapi_search.parseSearchResult(
      renderer,
      resultType: 'artist',
    );
    final browseId = parsed['browseId'] as String?;
    if (browseId == null || browseId.isEmpty) {
      return null;
    }

    _rememberListenAgain(browseId, renderer);
    return Artist(
      id: browseId,
      name: parsed['artist'] as String? ?? 'Unknown Artist',
      picture: parseImageDetails({'thumbnails': parsed['thumbnails']}),
      topSongsPlaylistId:
          parsed['shuffleId'] as String? ?? parsed['radioId'] as String?,
      radio: parsed['radioId'] is String,
      pinned: _pinnedForItem(browseId, renderer),
      platformId: 'youtube_music',
    );
  }

  /// Parses a ranked artist chart item using ytmusicapi's chart parser.
  static Artist? parseChartArtistFromResponsiveListItem(
    Map<String, dynamic> renderer,
  ) {
    final parsed = ytmusicapi_explore.parseChartArtist(renderer);
    final browseId = parsed['browseId'] as String?;
    if (browseId == null || browseId.isEmpty) return null;
    _rememberListenAgain(browseId, renderer);
    return Artist(
      id: browseId,
      name: parsed['title'] as String? ?? 'Unknown Artist',
      fans: _parseCompactCount(parsed['subscribers']?.toString()),
      picture: parseImageDetails({'thumbnails': parsed['thumbnails']}),
      pinned: _pinnedForItem(browseId, renderer),
      variation: _chartVariation(parsed),
      platformId: 'youtube_music',
    );
  }

  static int? _parseCompactCount(String? value) {
    if (value == null) return null;
    final match = RegExp(r'([\d,.]+)\s*([KMB]?)', caseSensitive: false)
        .firstMatch(value.replaceAll(',', ''));
    if (match == null) return int.tryParse(value);
    final number = double.tryParse(match.group(1)!) ?? 0;
    final multiplier = switch (match.group(2)?.toUpperCase()) {
      'K' => 1000,
      'M' => 1000000,
      'B' => 1000000000,
      _ => 1,
    };
    return (number * multiplier).round();
  }

  /// Parses a [Playlist] from a `musicResponsiveListItemRenderer` (from Playlist search).
  static Playlist? parsePlaylistFromResponsiveListItem(
    Map<String, dynamic> renderer,
  ) {
    final parsed = ytmusicapi_search.parseSearchResult(
      renderer,
      resultType: 'playlist',
    );
    final browseId =
        parsed['browseId'] as String? ?? parsed['playlistId'] as String?;
    if (browseId == null || browseId.isEmpty) {
      return null;
    }

    _rememberListenAgain(browseId, renderer);
    return Playlist(
      id: browseId,
      title: parsed['title'] as String? ?? 'Unknown Playlist',
      user: playlistUserFromAuthor(parsed['author']),
      image: parseImageDetails({'thumbnails': parsed['thumbnails']}),
      trackCount: parsed['itemCount'] as int?,
      pinned: _pinnedForItem(browseId, renderer),
      platformId: 'youtube_music',
    );
  }

  /// Parses an [Album] from a `musicTwoRowItemRenderer`.
  static Album? parseAlbumFromTwoRowItem(Map<String, dynamic> renderer) {
    final parsed = ytmusicapi_albums.parseAlbum(renderer);
    final browseId = parsed['browseId'] as String?;
    if (browseId == null || browseId.isEmpty) {
      return null;
    }
    final artists = <Artist>[
      for (final artist in (parsed['artists'] as List? ?? const []))
        if (artist is Map)
          Artist(
            id: artist['id'] as String?,
            name: artist['name'] as String? ?? '',
            platformId: 'youtube_music',
          ),
    ];
    final year = int.tryParse(parsed['year']?.toString() ?? '');
    final art =
        parseImageDetails({'thumbnails': parsed['thumbnails']}) ??
        parseImageDetails(
          renderer['thumbnailRenderer'] ?? renderer['thumbnail'],
        );

    _rememberListenAgain(browseId, renderer);
    return Album(
      id: browseId,
      title: parsed['title'] as String? ?? 'Unknown Album',
      artists: artists,
      art: art,
      releaseDate: year != null ? '$year' : null,
      pinned: _pinnedForItem(browseId, renderer),
      platformId: 'youtube_music',
    );
  }

  /// Parses an [Artist] from a `musicTwoRowItemRenderer`.
  static Artist? parseArtistFromTwoRowItem(Map<String, dynamic> renderer) {
    final parsed = ytmusicapi_browsing.parseRelatedArtist(renderer);
    final browseId = parsed['browseId'] as String?;
    if (browseId == null || browseId.isEmpty) {
      return null;
    }
    final art =
        parseImageDetails({'thumbnails': parsed['thumbnails']}) ??
        parseImageDetails(
          renderer['thumbnailRenderer'] ?? renderer['thumbnail'],
        );

    _rememberListenAgain(browseId, renderer);
    return Artist(
      id: browseId,
      name: parsed['title'] as String? ?? 'Unknown Artist',
      picture: art,
      pinned: _pinnedForItem(browseId, renderer),
      platformId: 'youtube_music',
    );
  }

  /// Parses a [Playlist] from a `musicTwoRowItemRenderer`.
  static Playlist? parsePlaylistFromTwoRowItem(Map<String, dynamic> renderer) {
    final parsed = ytmusicapi_browsing.parsePlaylist(renderer);
    final browseId =
        renderer['navigationEndpoint']?['browseEndpoint']?['browseId']
            as String? ??
        renderer['title']?['runs']?[0]?['navigationEndpoint']?['browseEndpoint']?['browseId']
            as String?;
    if (browseId == null || browseId.isEmpty) {
      return null;
    }
    final art = parseImageDetails({'thumbnails': parsed['thumbnails']});

    _rememberListenAgain(browseId, renderer);
    return Playlist(
      id: browseId,
      title: parsed['title'] as String? ?? 'Unknown Playlist',
      user: playlistUserFromAuthor(parsed['author']),
      image: art,
      editable: parsed['owned'] == true,
      pinned: _pinnedForItem(browseId, renderer),
      platformId: 'youtube_music',
    );
  }

  /// Parses a [Show] from a `musicTwoRowItemRenderer`.
  static Show? parseShowFromTwoRowItem(Map<String, dynamic> renderer) {
    final parsed = ytmusicapi_podcasts.parsePodcast(renderer);
    final browseId = parsed['browseId'] as String?;
    if (browseId == null || browseId.isEmpty) {
      return null;
    }
    final channel = parsed['channel'];
    final art = parseImageDetails({'thumbnails': parsed['thumbnails']});

    _rememberListenAgain(browseId, renderer);
    return Show(
      id: browseId,
      name: parsed['title'] as String? ?? 'Unknown Podcast',
      creator: channel is Map ? channel['name'] as String? : null,
      art: art,
      pinned: _pinnedForItem(browseId, renderer),
      platformId: 'youtube_music',
    );
  }

  /// Parses a podcast episode represented by a two-row browse item.
  static ShowEpisode? parseEpisodeFromTwoRowItem(
    Map<String, dynamic> renderer,
  ) {
    final parsed = ytmusicapi_podcasts.parseEpisode(renderer);
    final id = parsed['videoId'] as String?;
    if (id == null || id.isEmpty) {
      return null;
    }
    final subtitle = parseRuns(renderer['subtitle']);
    final duration = _durationFromTexts([
      parsed['duration'] as String? ?? '',
      ..._rendererDurationTexts(renderer),
      subtitle,
    ]);
    final art = parseImageDetails({'thumbnails': parsed['thumbnails']});
    final show = Show(name: subtitle, platformId: 'youtube_music');
    _rememberListenAgain(id, renderer);
    return ShowEpisode(
      id: id,
      title: parsed['title'] as String? ?? 'Unknown Episode',
      description: parsed['description'] as String?,
      show: show,
      art: art,
      duration: duration,
      bookmarkSeconds: parsed['progressPercentage'] is num && duration != null
          ? ((parsed['progressPercentage'] as num) / 100 * duration.inSeconds)
                .round()
          : null,
      progressPercentage: parsed['progressPercentage'] is num
          ? ((parsed['progressPercentage'] as num) / 100).clamp(0.0, 1.0)
          : null,
      isHeard:
          parsed['progressPercentage'] is num &&
          (parsed['progressPercentage'] as num) >= 95,
      pinned: _pinnedForItem(id, renderer),
    );
  }

  /// Parses a [Track] from a `musicTwoRowItemRenderer` (e.g. video / single / song item).
  static Track? parseTrackFromTwoRowItem(Map<String, dynamic> renderer) {
    final parsed = ytmusicapi_songs.parseSong(renderer);
    final videoId = parsed['videoId'] as String?;
    if (videoId == null || videoId.isEmpty) {
      return null;
    }
    final artists = _modelArtists(parsed['artists']);
    final art =
        parseImageDetails({'thumbnails': parsed['thumbnails']}) ??
        parseImageDetails(
          renderer['thumbnailRenderer'] ?? renderer['thumbnail'],
        );
    final durationSeconds = parsed['duration_seconds'];
    final badges = renderer['badges'] as List? ?? const [];
    final isLive =
        parsed['isLive'] == true ||
        parsed['videoType'] == 'MUSIC_VIDEO_TYPE_LIVE' ||
        badges.any(
          (badge) =>
              badge['liveBadgeRenderer'] != null ||
              badge['musicInlineBadgeRenderer']?['icon']?['iconType'] ==
                  'MUSIC_LIVE_BADGE' ||
              badge['musicInlineBadgeRenderer']?['icon']?['iconType'] == 'LIVE',
        );
    final likeStatus = _likeStatusFromMenu(renderer);
    _rememberListenAgain(videoId, renderer);
    return Track(
      id: isLive ? 'radio:$videoId' : videoId,
      title: parsed['title'] as String? ?? 'Unknown Track',
      artists: artists,
      navigableArtists: artists,
      duration: durationSeconds is int
          ? Duration(seconds: durationSeconds)
          : null,
      albumArt: art,
      explicit: parsed['isExplicit'] == true,
      favorite: likeStatus == null ? null : likeStatus == 'LIKE',
      pinned: _pinnedForItem(videoId, renderer),
      platformId: 'youtube_music',
      trackNumber: (parsed['trackNumber'] as int?) ??
          int.tryParse(parsed['rank']?.toString() ?? ''),
      variation: _chartVariation(renderer) ?? _chartVariation(parsed),
    );
  }

  static int? _chartVariation(Map<String, dynamic> renderer) {
    if (renderer['variation'] != null) {
      final v = renderer['variation'];
      if (v is int) return v;
      if (v is num) return v.toInt();
      final parsed = int.tryParse(v.toString());
      if (parsed != null) return parsed;
    }

    final trend = renderer['trend'] as String?;
    if (trend != null) {
      final lower = trend.toLowerCase();
      if (lower == 'up' ||
          lower.contains('increase') ||
          lower.contains('ascend')) {
        return 1;
      }
      if (lower == 'down' ||
          lower.contains('decrease') ||
          lower.contains('descend')) {
        return -1;
      }
      if (lower == 'neutral' ||
          lower == 'same' ||
          lower.contains('stay') ||
          lower.contains('unchange')) {
        return 0;
      }
    }

    final parts = <String>[];
    final icons = <String>[];
    final colorStyles = <String>[];

    void collect(dynamic value) {
      if (value is Map) {
        final text = value['text'];
        if (text is String) {
          parts.add(text);
        }
        final iconType = value['icon']?['iconType'] ?? value['iconType'];
        if (iconType is String) {
          icons.add(iconType.toUpperCase());
        }
        final colorStyle = value['iconColorStyle'];
        if (colorStyle is String) {
          colorStyles.add(colorStyle.toUpperCase());
        }
        final label = value['accessibilityData']?['label'] ??
            value['accessibilityData']?['accessibilityData']?['label'] ??
            value['accessibility']?['accessibilityData']?['label'];
        if (label is String) {
          parts.add(label);
        }
        for (final entry in value.entries) {
          if (entry.key != 'text' &&
              entry.key != 'accessibilityData' &&
              entry.key != 'accessibility') {
            collect(entry.value);
          }
        }
      } else if (value is List) {
        for (final child in value) {
          collect(child);
        }
      }
    }

    collect(renderer['customIndexColumn']);
    collect(renderer['musicCustomIndexColumnRenderer']);
    collect(renderer['fixedColumns']);
    collect(renderer['badges']);
    collect(renderer['accessibility']);
    collect(renderer['accessibilityData']);
    if (renderer.containsKey('icon') ||
        renderer.containsKey('iconType') ||
        renderer.containsKey('iconColorStyle')) {
      collect(renderer);
    }

    final status = parts.join(' ').toLowerCase();

    final deltaMovement = RegExp(
      r'\b(?:up|down|increased|decreased)\s*by\s*(\d+)\b',
    ).firstMatch(status);

    for (final icon in icons) {
      if (icon == 'ARROW_DROP_UP' ||
          icon == 'ARROW_UP' ||
          icon.contains('TRENDING_UP') ||
          icon == 'TREND_UP') {
        if (deltaMovement != null) {
          final amt = int.tryParse(deltaMovement.group(1)!);
          if (amt != null && amt > 0) return amt;
        }
        return 1;
      }
      if (icon == 'ARROW_DROP_DOWN' ||
          icon == 'ARROW_DOWN' ||
          icon.contains('TRENDING_DOWN') ||
          icon == 'TREND_DOWN') {
        if (deltaMovement != null) {
          final amt = int.tryParse(deltaMovement.group(1)!);
          if (amt != null && amt > 0) return -amt;
        }
        return -1;
      }
      if (icon == 'ARROW_CHART_NEUTRAL' ||
          icon == 'ARROW_RIGHT' ||
          icon == 'NON_MOVER' ||
          icon == 'UNCHANGED' ||
          icon == 'TREND_NEUTRAL') {
        return 0;
      }
    }

    for (final style in colorStyles) {
      if (style.contains('GREEN')) return 1;
      if (style.contains('RED')) return -1;
      if (style.contains('GREY') || style.contains('GRAY')) return 0;
    }

    if (deltaMovement != null) {
      final amount = int.tryParse(deltaMovement.group(1)!);
      if (amount != null) {
        return (status.contains('down') || status.contains('decreased'))
            ? -amount
            : amount;
      }
    }

    if (RegExp(
      r'\b(stayed|neutral|same|no change|no movement|non-mover|unchanged)\b',
    ).hasMatch(status)) {
      return 0;
    }
    if (RegExp(r'\b(increased|ascended|moved up|moving up)\b').hasMatch(status)) {
      return 1;
    }
    if (RegExp(r'\b(decreased|descended|moved down|moving down)\b').hasMatch(status)) {
      return -1;
    }

    return null;
  }

  /// Parses a [Track] from a `playlistPanelVideoRenderer` (Radio / Queue / Automix).
  static Track? parseTrackFromPlaylistPanelVideo(
    Map<String, dynamic> renderer,
  ) {
    final wrapper = _asMap(renderer['playlistPanelVideoWrapperRenderer']);
    final data = wrapper?['primaryRenderer'] is Map
        ? Map<String, dynamic>.from(wrapper!['primaryRenderer'] as Map)
        : renderer;
    final parsed = ytmusicapi_watch.parseWatchTrack(data);
    final videoId = parsed['videoId'] as String?;
    if (videoId == null || videoId.isEmpty) {
      return null;
    }
    final artistRows = parsed['artists'] as List? ?? const [];
    final artists = artistRows
        .whereType<Map>()
        .map((artist) => Map<String, dynamic>.from(artist))
        .map(
          (artist) => Artist(
            id: artist['id'] as String?,
            name: artist['name'] as String?,
            platformId: 'youtube_music',
          ),
        )
        .toList();
    final albumData = _asMap(parsed['album']);
    final album = albumData == null
        ? null
        : Album(
            id: albumData['id'] as String?,
            title: albumData['name'] as String?,
            platformId: 'youtube_music',
          );
    final durationText = parsed['length'] as String?;
    final art = parseImageDetails({'thumbnails': parsed['thumbnail']});
    final badges = data['badges'] as List?;
    final isLive =
        parsed['isLive'] == true ||
        (badges?.any(
              (b) =>
                  b['liveBadgeRenderer'] != null ||
                  b['musicInlineBadgeRenderer']?['icon']?['iconType'] ==
                      'MUSIC_LIVE_BADGE' ||
                  b['musicInlineBadgeRenderer']?['icon']?['iconType'] == 'LIVE',
            ) ??
            false);

    _rememberListenAgain(videoId, data);
    return Track(
      id: isLive ? 'radio:$videoId' : videoId,
      title: parsed['title'] as String?,
      album: album,
      artists: artists,
      navigableArtists: artists,
      duration: parseDuration(durationText) ?? Duration.zero,
      albumArt: art,
      favorite: parsed['likeStatus'] == 'LIKE',
      pinned: _pinnedForItem(videoId, data),
      platformId: 'youtube_music',
      variation: _chartVariation(data) ?? _chartVariation(parsed),
    );
  }
}
