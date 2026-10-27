import 'dart:math';
import 'package:flutter/gestures.dart';
import 'package:get_it/get_it.dart';
import 'package:material_ui/material_ui.dart';
import 'package:silky_scroll/silky_scroll.dart';
import 'package:saturn/ui/smooth_scroll_config.dart';

import '../../api/definitions.dart';
import '../../service/audio_service.dart';
import '../../translations.i18n.dart';
import '../../ui/cached_image.dart';
import '../../ui/details_screens.dart';
import '../../ui/menu.dart';
import '../../ui/toast.dart';
import 'parsers/item_parsers.dart';
import 'youtube_music_browse_widget.dart';
import 'youtube_music_platform.dart';

/// Supported item types in YouTube Music's Listen again section.
enum SpeedDialItemType { song, album, artist, playlist, show, episode }

/// A normalized item for the mobile Listen again presentation.
class YouTubeMusicSpeedDialItem {
  final String id;
  final String? secondaryId;
  final String title;
  final String? subtitle;
  final String? subtitleIds;
  final String? thumbnailUrl;
  final SpeedDialItemType type;
  final bool explicit;
  final int createDate;
  final String? albumId;
  final String? albumName;
  final String? pinFeedbackToken;
  final String? unpinFeedbackToken;
  final bool isPinnedInYouTubeMusic;

  bool get hasListenAgainTokens =>
      pinFeedbackToken != null || unpinFeedbackToken != null;

  YouTubeMusicSpeedDialItem({
    required this.id,
    this.secondaryId,
    required this.title,
    this.subtitle,
    this.subtitleIds,
    this.thumbnailUrl,
    required this.type,
    this.explicit = false,
    int? createDate,
    this.albumId,
    this.albumName,
    this.pinFeedbackToken,
    this.unpinFeedbackToken,
    this.isPinnedInYouTubeMusic = false,
  }) : createDate = createDate ?? DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> toJson() => {
    'id': id,
    if (secondaryId != null) 'secondaryId': secondaryId,
    'title': title,
    if (subtitle != null) 'subtitle': subtitle,
    if (subtitleIds != null) 'subtitleIds': subtitleIds,
    if (thumbnailUrl != null) 'thumbnailUrl': thumbnailUrl,
    'type': type.name,
    'explicit': explicit,
    'createDate': createDate,
    if (albumId != null) 'albumId': albumId,
    if (albumName != null) 'albumName': albumName,
  };

  factory YouTubeMusicSpeedDialItem.fromJson(Map<String, dynamic> json) {
    return YouTubeMusicSpeedDialItem(
      id: json['id'] as String? ?? '',
      secondaryId: json['secondaryId'] as String?,
      title: json['title'] as String? ?? '',
      subtitle: json['subtitle'] as String?,
      subtitleIds: json['subtitleIds'] as String?,
      thumbnailUrl: json['thumbnailUrl'] as String?,
      type: SpeedDialItemType.values.firstWhere(
        (t) => t.name == (json['type'] as String?),
        orElse: () => SpeedDialItemType.song,
      ),
      explicit: json['explicit'] as bool? ?? false,
      createDate: json['createDate'] as int?,
      albumId: json['albumId'] as String?,
      albumName: json['albumName'] as String?,
    );
  }

  factory YouTubeMusicSpeedDialItem.fromTrack(Track track) {
    final listenAgain = YouTubeMusicParsers.listenAgainDataFor(track.id);
    return YouTubeMusicSpeedDialItem(
      id: track.id ?? '',
      title: track.title ?? 'Unknown Track',
      subtitle: track.artistString,
      thumbnailUrl: track.albumArt?.full ?? track.albumArt?.thumb,
      type: SpeedDialItemType.song,
      explicit: track.explicit ?? false,
      albumId: track.album?.id,
      albumName: track.album?.title,
      pinFeedbackToken: listenAgain?.pinFeedbackToken,
      unpinFeedbackToken: listenAgain?.unpinFeedbackToken,
      isPinnedInYouTubeMusic: listenAgain?.isPinned ?? track.pinned,
    );
  }

  factory YouTubeMusicSpeedDialItem.fromAlbum(Album album) {
    final listenAgain = YouTubeMusicParsers.listenAgainDataFor(album.id);
    return YouTubeMusicSpeedDialItem(
      id: album.id ?? '',
      title: album.title ?? 'Unknown Album',
      subtitle: album.artists
          ?.map((a) => a.name)
          .whereType<String>()
          .join(', '),
      thumbnailUrl: album.art?.full ?? album.art?.thumb,
      type: SpeedDialItemType.album,
      pinFeedbackToken: listenAgain?.pinFeedbackToken,
      unpinFeedbackToken: listenAgain?.unpinFeedbackToken,
      isPinnedInYouTubeMusic: listenAgain?.isPinned ?? album.pinned,
    );
  }

  factory YouTubeMusicSpeedDialItem.fromArtist(Artist artist) {
    final listenAgain = YouTubeMusicParsers.listenAgainDataFor(artist.id);
    return YouTubeMusicSpeedDialItem(
      id: artist.id ?? '',
      title: artist.name ?? 'Unknown Artist',
      subtitle: 'Artist',
      thumbnailUrl: artist.picture?.full ?? artist.picture?.thumb,
      type: SpeedDialItemType.artist,
      pinFeedbackToken: listenAgain?.pinFeedbackToken,
      unpinFeedbackToken: listenAgain?.unpinFeedbackToken,
      isPinnedInYouTubeMusic: listenAgain?.isPinned ?? artist.pinned,
    );
  }

  factory YouTubeMusicSpeedDialItem.fromPlaylist(Playlist playlist) {
    final listenAgain = YouTubeMusicParsers.listenAgainDataFor(playlist.id);
    return YouTubeMusicSpeedDialItem(
      id: playlist.id ?? '',
      title: playlist.title ?? 'Unknown Playlist',
      subtitle: playlist.user?.name ?? 'Playlist',
      thumbnailUrl: playlist.image?.full ?? playlist.image?.thumb,
      type: SpeedDialItemType.playlist,
      pinFeedbackToken: listenAgain?.pinFeedbackToken,
      unpinFeedbackToken: listenAgain?.unpinFeedbackToken,
      isPinnedInYouTubeMusic: listenAgain?.isPinned ?? playlist.pinned,
    );
  }

  factory YouTubeMusicSpeedDialItem.fromShow(Show show) {
    final listenAgain = YouTubeMusicParsers.listenAgainDataFor(show.id);
    return YouTubeMusicSpeedDialItem(
      id: show.id ?? '',
      title: show.name ?? 'Unknown Podcast',
      subtitle: show.creator ?? 'Podcast',
      thumbnailUrl: show.art?.full ?? show.art?.thumb,
      type: SpeedDialItemType.show,
      pinFeedbackToken: listenAgain?.pinFeedbackToken,
      unpinFeedbackToken: listenAgain?.unpinFeedbackToken,
      isPinnedInYouTubeMusic: listenAgain?.isPinned ?? show.pinned,
    );
  }

  factory YouTubeMusicSpeedDialItem.fromEpisode(ShowEpisode episode) {
    final listenAgain = YouTubeMusicParsers.listenAgainDataFor(episode.id);
    return YouTubeMusicSpeedDialItem(
      id: episode.id ?? '',
      title: episode.title ?? 'Unknown Episode',
      subtitle: episode.show?.name ?? 'Episode',
      thumbnailUrl: episode.art?.full ?? episode.art?.thumb,
      type: SpeedDialItemType.episode,
      pinFeedbackToken: listenAgain?.pinFeedbackToken,
      unpinFeedbackToken: listenAgain?.unpinFeedbackToken,
      isPinnedInYouTubeMusic: listenAgain?.isPinned ?? episode.pinned,
    );
  }

  static YouTubeMusicSpeedDialItem? fromDynamic(dynamic item) {
    if (item == null) return null;
    if (item is YouTubeMusicSpeedDialItem) return item;
    if (item is Track) return YouTubeMusicSpeedDialItem.fromTrack(item);
    if (item is Album) return YouTubeMusicSpeedDialItem.fromAlbum(item);
    if (item is Artist) return YouTubeMusicSpeedDialItem.fromArtist(item);
    if (item is Playlist) return YouTubeMusicSpeedDialItem.fromPlaylist(item);
    if (item is Show) return YouTubeMusicSpeedDialItem.fromShow(item);
    if (item is ShowEpisode) return YouTubeMusicSpeedDialItem.fromEpisode(item);
    if (item is Map && item is! Map<String, dynamic>) {
      item = Map<String, dynamic>.from(item);
    }
    if (item is Map<String, dynamic>) {
      final rawRenderer =
          (item['musicTwoRowItemRenderer'] as Map<String, dynamic>?) ??
          (item['musicMultiRowListItemRenderer'] as Map<String, dynamic>?) ??
          (item['musicResponsiveListItemRenderer'] as Map<String, dynamic>?) ??
          (item.containsKey('menu') ? item : null);

      final listenAgainData = YouTubeMusicParsers.parseListenAgainMenuData(
        rawRenderer ?? item,
      );

      YouTubeMusicSpeedDialItem? parsed;
      // Check if it's a raw Innertube renderer
      if (item['musicTwoRowItemRenderer'] != null) {
        final twoRow = item['musicTwoRowItemRenderer'] as Map<String, dynamic>;
        final titleRuns = twoRow['title']?['runs'];
        final titleRun = titleRuns is List && titleRuns.isNotEmpty
            ? titleRuns.first
            : null;
        final titleNavigation = titleRun is Map
            ? titleRun['navigationEndpoint']
            : null;
        final rootNavigation = twoRow['navigationEndpoint'];
        final nav =
            (rootNavigation is Map ? rootNavigation['browseEndpoint'] : null) ??
            (titleNavigation is Map ? titleNavigation['browseEndpoint'] : null);
        final pageType =
            nav?['browseEndpointContextSupportedConfigs']?['browseEndpointContextMusicConfig']?['pageType']
                as String?;
        final browseId = nav?['browseId'] as String?;

        if (pageType == 'MUSIC_PAGE_TYPE_ALBUM' ||
            (browseId != null && browseId.startsWith('MPRE'))) {
          final a = YouTubeMusicParsers.parseAlbumFromTwoRowItem(twoRow);
          if (a != null) parsed = YouTubeMusicSpeedDialItem.fromAlbum(a);
        } else if (pageType == 'MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE' ||
            (browseId != null && browseId.startsWith('MPSP'))) {
          final s = YouTubeMusicParsers.parseShowFromTwoRowItem(twoRow);
          if (s != null) parsed = YouTubeMusicSpeedDialItem.fromShow(s);
        } else if (pageType == 'MUSIC_PAGE_TYPE_PLAYLIST' ||
            (browseId != null && browseId.startsWith('VL'))) {
          final p = YouTubeMusicParsers.parsePlaylistFromTwoRowItem(twoRow);
          if (p != null) parsed = YouTubeMusicSpeedDialItem.fromPlaylist(p);
        } else if (pageType == 'MUSIC_PAGE_TYPE_ARTIST' ||
            (browseId != null &&
                (browseId.startsWith('UC') || browseId.startsWith('MPLA')))) {
          final art = YouTubeMusicParsers.parseArtistFromTwoRowItem(twoRow);
          if (art != null) parsed = YouTubeMusicSpeedDialItem.fromArtist(art);
        } else if (pageType == 'MUSIC_PAGE_TYPE_NON_MUSIC_AUDIO_TRACK_PAGE' ||
            (browseId != null && browseId.startsWith('MPED'))) {
          final ep = YouTubeMusicParsers.parseEpisodeFromTwoRowItem(twoRow);
          if (ep != null) parsed = YouTubeMusicSpeedDialItem.fromEpisode(ep);
        } else {
          final t = YouTubeMusicParsers.parseTrackFromTwoRowItem(twoRow);
          if (t != null) parsed = YouTubeMusicSpeedDialItem.fromTrack(t);
        }
      } else if (item['musicResponsiveListItemRenderer'] != null) {
        final renderer =
            item['musicResponsiveListItemRenderer'] as Map<String, dynamic>;
        final flexColumns = renderer['flexColumns'] as List? ?? [];
        final hasShowBrowseId = flexColumns.any((column) {
          final runs =
              column?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs']
                  as List? ??
              [];
          return runs.any((run) {
            final endpoint = run is Map ? run['navigationEndpoint'] : null;
            final browseEndpoint = endpoint is Map
                ? endpoint['browseEndpoint']
                : null;
            final id = browseEndpoint is Map
                ? browseEndpoint['browseId']
                : null;
            return id is String && id.startsWith('MPSP');
          });
        });
        if (hasShowBrowseId) {
          final ep = YouTubeMusicParsers.parseEpisodeFromResponsiveListItem(
            renderer,
          );
          if (ep != null) parsed = YouTubeMusicSpeedDialItem.fromEpisode(ep);
        } else {
          final t = YouTubeMusicParsers.parseTrackFromResponsiveListItem(
            renderer,
          );
          if (t != null) parsed = YouTubeMusicSpeedDialItem.fromTrack(t);
        }
      } else if (item['musicMultiRowListItemRenderer'] != null) {
        final episode = YouTubeMusicParsers.parseEpisodeFromMultiRowListItem(
          Map<String, dynamic>.from(item['musicMultiRowListItemRenderer']),
        );
        if (episode != null) {
          parsed = YouTubeMusicSpeedDialItem.fromEpisode(episode);
        }
      }
      // Listen again commonly uses a bare watchEndpoint for songs, without a
      // browseEndpoint. The upstream search-row parser expects the latter, so
      // preserve these valid video rows as generic tracks.
      if (parsed == null && item['musicTwoRowItemRenderer'] is Map) {
        final renderer = Map<String, dynamic>.from(
          item['musicTwoRowItemRenderer'] as Map,
        );
        final navigation = renderer['navigationEndpoint'];
        final watch = navigation is Map ? navigation['watchEndpoint'] : null;
        final playlistItem = renderer['playlistItemData'];
        final playOverlay = renderer['thumbnailOverlay'];
        final overlayRenderer = playOverlay is Map
            ? playOverlay['musicItemThumbnailOverlayRenderer']
            : null;
        final overlayContent = overlayRenderer is Map
            ? overlayRenderer['content']
            : null;
        final playButton = overlayContent is Map
            ? overlayContent['musicPlayButtonRenderer']
            : null;
        final playNavigation = playButton is Map
            ? playButton['playNavigationEndpoint']
            : null;
        final playWatch = playNavigation is Map
            ? playNavigation['watchEndpoint']
            : null;
        final videoId =
            (watch is Map ? watch['videoId'] : null) ??
            (playlistItem is Map ? playlistItem['videoId'] : null) ??
            (playWatch is Map ? playWatch['videoId'] : null);
        final title = YouTubeMusicParsers.parseRuns(renderer['title']);
        if (videoId is String && videoId.isNotEmpty && title.isNotEmpty) {
          final subtitle = YouTubeMusicParsers.parseRuns(renderer['subtitle']);
          final thumbnail = YouTubeMusicParsers.parseImageDetails(
            renderer['thumbnailRenderer'] ?? renderer['thumbnail'],
          );
          parsed = YouTubeMusicSpeedDialItem(
            id: videoId,
            title: title,
            subtitle: subtitle.isEmpty ? null : subtitle,
            thumbnailUrl: thumbnail?.full ?? thumbnail?.thumb,
            type: SpeedDialItemType.song,
          );
        }
      }
      if (parsed != null) {
        if (listenAgainData.hasTokens) {
          YouTubeMusicParsers.updateListenAgainData(parsed.id, listenAgainData);
        }
        return YouTubeMusicSpeedDialItem(
          id: parsed.id,
          secondaryId: parsed.secondaryId,
          title: parsed.title,
          subtitle: parsed.subtitle,
          subtitleIds: parsed.subtitleIds,
          thumbnailUrl: parsed.thumbnailUrl,
          type: parsed.type,
          explicit: parsed.explicit,
          albumId: parsed.albumId,
          albumName: parsed.albumName,
          pinFeedbackToken: listenAgainData.pinFeedbackToken,
          unpinFeedbackToken: listenAgainData.unpinFeedbackToken,
          isPinnedInYouTubeMusic:
              listenAgainData.isPinned || parsed.isPinnedInYouTubeMusic,
        );
      }
    }
    return null;
  }

  Track toTrack() {
    return Track(
      id: id,
      title: title,
      artists: subtitle != null && subtitle!.isNotEmpty
          ? [Artist(name: subtitle, platformId: 'youtube_music')]
          : [],
      album: albumId != null || albumName != null
          ? Album(id: albumId, title: albumName, platformId: 'youtube_music')
          : null,
      albumArt: ImageDetails(fullUrl: thumbnailUrl, thumbUrl: thumbnailUrl),
      explicit: explicit,
      pinned: isPinnedInYouTubeMusic,
      platformId: 'youtube_music',
    );
  }

  Album toAlbum() {
    return Album(
      id: id,
      title: title,
      artists: subtitle != null && subtitle!.isNotEmpty
          ? [Artist(name: subtitle, platformId: 'youtube_music')]
          : [],
      art: ImageDetails(fullUrl: thumbnailUrl, thumbUrl: thumbnailUrl),
      platformId: 'youtube_music',
      pinned: isPinnedInYouTubeMusic,
    );
  }

  Artist toArtist() {
    return Artist(
      id: id,
      name: title,
      picture: ImageDetails(fullUrl: thumbnailUrl, thumbUrl: thumbnailUrl),
      platformId: 'youtube_music',
      pinned: isPinnedInYouTubeMusic,
    );
  }

  Playlist toPlaylist() {
    return Playlist(
      id: id,
      title: title,
      user: subtitle != null ? User(name: subtitle!) : null,
      image: ImageDetails(fullUrl: thumbnailUrl, thumbUrl: thumbnailUrl),
      platformId: 'youtube_music',
      pinned: isPinnedInYouTubeMusic,
    );
  }

  Show toShow() {
    return Show(
      id: id,
      name: title,
      creator: subtitle,
      art: ImageDetails(fullUrl: thumbnailUrl, thumbUrl: thumbnailUrl),
      pinned: isPinnedInYouTubeMusic,
      platformId: 'youtube_music',
    );
  }

  ShowEpisode toEpisode() {
    return ShowEpisode(
      id: id,
      title: title,
      show: Show(
        name: subtitle ?? 'YouTube Music Podcast',
        platformId: 'youtube_music',
      ),
      art: ImageDetails(fullUrl: thumbnailUrl, thumbUrl: thumbnailUrl),
      pinned: isPinnedInYouTubeMusic,
    );
  }

  YouTubeMusicSpeedDialItem withListenAgainTokens({
    required String? pinToken,
    required String? unpinToken,
    required bool isPinned,
  }) => YouTubeMusicSpeedDialItem(
    id: id,
    secondaryId: secondaryId,
    title: title,
    subtitle: subtitle,
    subtitleIds: subtitleIds,
    thumbnailUrl: thumbnailUrl,
    type: type,
    explicit: explicit,
    createDate: createDate,
    albumId: albumId,
    albumName: albumName,
    pinFeedbackToken: pinToken,
    unpinFeedbackToken: unpinToken,
    isPinnedInYouTubeMusic: isPinned,
  );
}

/// Adapts YouTube Music's Listen again rows to Saturn's mobile grid.
class YouTubeMusicSpeedDialManager extends ChangeNotifier {
  static final YouTubeMusicSpeedDialManager instance =
      YouTubeMusicSpeedDialManager._();

  YouTubeMusicSpeedDialManager._();

  Future<void> togglePin(
    dynamic rawItem, {
    Future<void> Function(String token)? onSendFeedback,
  }) async {
    final item = YouTubeMusicSpeedDialItem.fromDynamic(rawItem);
    if (item == null || item.id.isEmpty) {
      return;
    }
    final currentlyPinned = item.isPinnedInYouTubeMusic;
    final feedbackToken = currentlyPinned
        ? item.unpinFeedbackToken
        : item.pinFeedbackToken;
    if (feedbackToken == null || feedbackToken.isEmpty) {
      throw StateError(
        'YouTube Music did not provide a Listen again action for this item.',
      );
    }
    if (onSendFeedback != null) {
      await onSendFeedback(feedbackToken);
    } else {
      await YouTubeMusicPlatform.instance.api.sendFeedbackToken(feedbackToken);
    }
    YouTubeMusicParsers.updateListenAgainData(
      item.id,
      YouTubeMusicListenAgainData(
        isPinned: !currentlyPinned,
        pinFeedbackToken: item.pinFeedbackToken,
        unpinFeedbackToken: item.unpinFeedbackToken,
      ),
    );
    notifyListeners();
    Fluttertoast.showToast(
      msg: currentlyPinned
          ? 'Unpinned from Listen again'
          : 'Pinned to Listen again',
    );
  }

  /// Maps the actual Listen again shelf to the mobile card grid.
  List<YouTubeMusicSpeedDialItem> buildSpeedDialItems({
    required List<dynamic> keepListening,
  }) {
    final result = <YouTubeMusicSpeedDialItem>[];

    void addItem(dynamic raw) {
      final item = YouTubeMusicSpeedDialItem.fromDynamic(raw);
      if (item == null || item.id.isEmpty) return;
      final existingIndex = result.indexWhere((entry) => entry.id == item.id);
      if (existingIndex >= 0) {
        final existing = result[existingIndex];
        if (item.pinFeedbackToken != null || item.unpinFeedbackToken != null) {
          result[existingIndex] = existing.withListenAgainTokens(
            pinToken: item.pinFeedbackToken,
            unpinToken: item.unpinFeedbackToken,
            isPinned: item.isPinnedInYouTubeMusic,
          );
        }
        return;
      }
      result.add(item);
    }

    for (final raw in keepListening) {
      addItem(raw);
    }

    return result;
  }
}

/// Modern Listen again grid item matching Metrolist styling.
class SpeedDialGridItemWidget extends StatelessWidget {
  final YouTubeMusicSpeedDialItem item;
  final bool isPinned;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const SpeedDialGridItemWidget({
    super.key,
    required this.item,
    required this.isPinned,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final isArtist = item.type == SpeedDialItemType.artist;
    final borderRadius = isArtist
        ? BorderRadius.circular(999)
        : BorderRadius.circular(12);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(12),
        child: AspectRatio(
          aspectRatio: 1.0,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Clipped Thumbnail & Gradient
              ClipRRect(
                borderRadius: borderRadius,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Container(
                      color: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
                      child:
                          item.thumbnailUrl != null &&
                              item.thumbnailUrl!.isNotEmpty
                          ? CachedImage(
                              url: item.thumbnailUrl!,
                              fit: BoxFit.cover,
                            )
                          : const Icon(
                              Icons.music_note,
                              size: 36,
                              color: Colors.white54,
                            ),
                    ),
                    // Gradient Overlay
                    Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black.withValues(alpha: 0.45),
                            Colors.transparent,
                            Colors.black.withValues(alpha: 0.55),
                            Colors.black.withValues(alpha: 0.90),
                          ],
                          stops: const [0.0, 0.4, 0.75, 1.0],
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // Pinned icon badge (top right) - outside clip
              if (isPinned || item.isPinnedInYouTubeMusic)
                Positioned(
                  top: 6,
                  right: 6,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.4),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.push_pin,
                      color: Colors.white,
                      size: 14,
                    ),
                  ),
                ),

              // Title and Chevron (bottom) - outside clip
              Positioned(
                left: 8,
                right: 8,
                bottom: 8,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          letterSpacing: -0.2,
                          shadows: [
                            Shadow(
                              color: Colors.black87,
                              blurRadius: 4,
                              offset: Offset(0, 1),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (item.type != SpeedDialItemType.song &&
                        item.type != SpeedDialItemType.episode)
                      const Padding(
                        padding: EdgeInsets.only(left: 2.0),
                        child: Icon(
                          Icons.chevron_right,
                          color: Colors.white70,
                          size: 16,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Metrolist-style animated 5-dots Dice Randomize Grid Item.
class SpeedDialRandomizeItemWidget extends StatefulWidget {
  final VoidCallback onTap;

  const SpeedDialRandomizeItemWidget({super.key, required this.onTap});

  @override
  State<SpeedDialRandomizeItemWidget> createState() =>
      _SpeedDialRandomizeItemWidgetState();
}

class _SpeedDialRandomizeItemWidgetState
    extends State<SpeedDialRandomizeItemWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _rotation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _rotation = Tween<double>(begin: 0.0, end: 2 * pi).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOutCubic),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleTap() {
    _controller.forward(from: 0.0);
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dotColor = theme.colorScheme.onSecondaryContainer;
    const dotSize = 8.0;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _handleTap,
        borderRadius: BorderRadius.circular(12),
        child: AspectRatio(
          aspectRatio: 1.0,
          child: Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Stack(
              children: [
                Center(
                  child: AnimatedBuilder(
                    animation: _rotation,
                    builder: (context, child) {
                      return Transform.rotate(
                        angle: _rotation.value,
                        child: SizedBox(
                          width: 44,
                          height: 44,
                          child: Stack(
                            children: [
                              // Top Left
                              Positioned(
                                top: 4,
                                left: 4,
                                child: _buildDot(dotColor, dotSize),
                              ),
                              // Top Right
                              Positioned(
                                top: 4,
                                right: 4,
                                child: _buildDot(dotColor, dotSize),
                              ),
                              // Center
                              Positioned(
                                top: 18,
                                left: 18,
                                child: _buildDot(dotColor, dotSize),
                              ),
                              // Bottom Left
                              Positioned(
                                bottom: 4,
                                left: 4,
                                child: _buildDot(dotColor, dotSize),
                              ),
                              // Bottom Right
                              Positioned(
                                bottom: 4,
                                right: 4,
                                child: _buildDot(dotColor, dotSize),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                Positioned(
                  bottom: 8,
                  left: 8,
                  right: 8,
                  child: Text(
                    'Discover',
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: dotColor,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDot(Color color, double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

/// Paginated Listen again section with a page indicator.
class SpeedDialSection extends StatefulWidget {
  final List<YouTubeMusicSpeedDialItem> items;
  final VoidCallback onRefreshNeeded;
  final Future<void> Function(String token)? onSendFeedback;
  final VoidCallback? onSeeMore;
  final String? browseId;
  final String? params;

  const SpeedDialSection({
    super.key,
    required this.items,
    required this.onRefreshNeeded,
    this.onSendFeedback,
    this.onSeeMore,
    this.browseId,
    this.params,
  });

  @override
  State<SpeedDialSection> createState() => _SpeedDialSectionState();
}

class _SpeedDialSectionState extends State<SpeedDialSection> {
  final PageController _pageController = PageController();
  int _currentPage = 0;

  void _openListenAgain(BuildContext context) {
    if (widget.onSeeMore != null) {
      widget.onSeeMore!();
      return;
    }
    if (widget.browseId == null || widget.browseId!.isEmpty) return;
    final baseId = widget.browseId!;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => YouTubeMusicBrowseWidget(
          browseId: baseId,
          params: widget.params,
          title: 'Listen again'.i18n,
          api: YouTubeMusicPlatform.instance.api,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _onItemTap(YouTubeMusicSpeedDialItem item) {
    switch (item.type) {
      case SpeedDialItemType.song:
        GetIt.I<AudioPlayerHandler>().playMix(
          item.id,
          item.title,
          platformId: 'youtube_music',
          seedTrack: item.toTrack(),
        );
        break;
      case SpeedDialItemType.episode:
        final episode = item.toEpisode();
        GetIt.I<AudioPlayerHandler>().playShowEpisode(
          episode.show ?? Show(name: 'Podcast', platformId: 'youtube_music'),
          [episode],
          index: 0,
        );
        break;
      case SpeedDialItemType.album:
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => AlbumDetails(item.toAlbum())),
        );
        break;
      case SpeedDialItemType.artist:
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => ArtistDetails(item.toArtist())),
        );
        break;
      case SpeedDialItemType.playlist:
        final pl = item.toPlaylist();
        if (pl.id != null &&
            (pl.id!.startsWith('VLRD') || pl.id!.startsWith('RD'))) {
          final cleanId =
              pl.id!.startsWith('VL') ? pl.id!.substring(2) : pl.id!;
          GetIt.I<AudioPlayerHandler>().playMix(
            cleanId,
            pl.title ?? 'Mix',
            platformId: 'youtube_music',
          );
        } else {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => PlaylistDetails(pl)),
          );
        }
        break;
      case SpeedDialItemType.show:
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => ShowScreen(item.toShow())),
        );
        break;
    }
  }

  void _onItemLongPress(YouTubeMusicSpeedDialItem item) {
    YouTubeMusicParsers.updateListenAgainData(
      item.id,
      YouTubeMusicListenAgainData(
        isPinned: item.isPinnedInYouTubeMusic,
        pinFeedbackToken: item.pinFeedbackToken,
        unpinFeedbackToken: item.unpinFeedbackToken,
      ),
    );
    switch (item.type) {
      case SpeedDialItemType.song:
        MenuSheet().defaultTrackMenu(item.toTrack(), context: context);
        break;
      case SpeedDialItemType.album:
        MenuSheet().defaultAlbumMenu(item.toAlbum(), context: context);
        break;
      case SpeedDialItemType.artist:
        MenuSheet().defaultArtistMenu(item.toArtist(), context: context);
        break;
      case SpeedDialItemType.playlist:
        MenuSheet().defaultPlaylistMenu(item.toPlaylist(), context: context);
        break;
      case SpeedDialItemType.show:
        MenuSheet().defaultShowMenu(item.toShow(), context: context);
        break;
      case SpeedDialItemType.episode:
        final ep = item.toEpisode();
        MenuSheet().defaultShowEpisodeMenu(
          ep.show ?? Show(name: 'Podcast', platformId: 'youtube_music'),
          ep,
          context: context,
        );
        break;
    }
  }

  void _onRandomizeTap() {
    if (widget.items.isEmpty) return;
    final random = Random();
    final candidate = widget.items[random.nextInt(widget.items.length)];
    _onItemTap(candidate);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final screenWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : (MediaQuery.maybeOf(context)?.size.width ?? 800.0);
        final columns = screenWidth > 1200
            ? 7
            : (screenWidth > 900 ? 6 : (screenWidth > 600 ? 4 : 3));
        final rows = columns >= 6 ? 1 : (columns >= 4 ? 2 : 3);
        final itemsPerPage = columns * rows;

        final displayItems = List<YouTubeMusicSpeedDialItem>.from(widget.items);
        final pageCount = ((displayItems.length + 1) / itemsPerPage)
            .ceil()
            .clamp(1, 4);

        // Approximate height calculation:
        // Available width per item: (screenWidth - padding - gaps) / columns
        final paddingHorizontal = 16.0 * 2;
        final spacing = 8.0 * (columns - 1);
        final itemWidth = (screenWidth - paddingHorizontal - spacing) / columns;
        final gridHeight = (itemWidth * rows) + (8.0 * (rows - 1));

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16.0, 16.0, 16.0, 8.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.onSeeMore != null ||
                          (widget.browseId != null &&
                              widget.browseId!.isNotEmpty)) ...[
                        InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () => _openListenAgain(context),
                          child: Text(
                            'Listen again'.i18n,
                            style: Theme.of(context)
                                .textTheme
                                .titleLarge
                                ?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: -0.3,
                                ),
                          ),
                        ),
                        const SizedBox(width: 2),
                        IconButton(
                          icon: const Icon(Icons.arrow_forward),
                          iconSize: 20,
                          visualDensity: VisualDensity.compact,
                          tooltip: 'Listen again'.i18n,
                          onPressed: () => _openListenAgain(context),
                        ),
                      ] else ...[
                        Text(
                          'Listen again'.i18n,
                          style: Theme.of(context)
                              .textTheme
                              .titleLarge
                              ?.copyWith(
                                fontWeight: FontWeight.bold,
                                letterSpacing: -0.3,
                              ),
                        ),
                      ],
                    ],
                  ),
                  if (pageCount > 1)
                    Row(
                      children: List.generate(pageCount, (index) {
                        final isSelected = _currentPage == index;
                        return AnimatedContainer(
                          duration: const Duration(milliseconds: 250),
                          margin: const EdgeInsets.symmetric(horizontal: 2.5),
                          width: isSelected ? 16 : 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: isSelected
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context).colorScheme.outlineVariant,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        );
                      }),
                    ),
                ],
              ),
            ),
            SizedBox(
              width: screenWidth,
              height: gridHeight,
              child: ScrollConfiguration(
                behavior: ScrollConfiguration.of(context).copyWith(
                  dragDevices: {
                    PointerDeviceKind.touch,
                    PointerDeviceKind.mouse,
                    PointerDeviceKind.trackpad,
                  },
                ),
                child: PageView.builder(
                  controller: _pageController,
                  itemCount: pageCount,
                  onPageChanged: (index) =>
                      setState(() => _currentPage = index),
                  itemBuilder: (context, pageIndex) {
                    final startIndex = pageIndex * itemsPerPage;

                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0),
                      child: SilkyGridView.builder(
                        silkyConfig: silkyScrollConfig,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          mainAxisSpacing: 8.0,
                          crossAxisSpacing: 8.0,
                          childAspectRatio: 1.0,
                        ),
                        itemCount: itemsPerPage,
                        itemBuilder: (context, slotIndex) {
                          // Slot (itemsPerPage - 1) on Page 0 is the Dice Randomize slot (like Metrolist)
                          if (pageIndex == 0 && slotIndex == itemsPerPage - 1) {
                            return SpeedDialRandomizeItemWidget(
                              onTap: _onRandomizeTap,
                            );
                          }

                          // Adjust index because of the randomize button slot on page 0
                          int itemIndex;
                          if (pageIndex == 0) {
                            itemIndex = slotIndex > (itemsPerPage - 1)
                                ? slotIndex - 1
                                : slotIndex;
                          } else {
                            itemIndex = startIndex + slotIndex - 1;
                          }

                          if (itemIndex >= displayItems.length) {
                            return const SizedBox.shrink();
                          }

                          final speedDialItem = displayItems[itemIndex];
                          final isPinned = speedDialItem.isPinnedInYouTubeMusic;

                          return SpeedDialGridItemWidget(
                            item: speedDialItem,
                            isPinned: isPinned,
                            onTap: () => _onItemTap(speedDialItem),
                            onLongPress: () => _onItemLongPress(speedDialItem),
                          );
                        },
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
