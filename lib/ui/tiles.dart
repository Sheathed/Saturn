import 'package:saturn/platform/platform_manager.dart';
import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fluttericon/octicons_icons.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:saturn/api/cache.dart';
import 'package:saturn/ui/menu.dart';
import 'package:saturn/ui/toast.dart';
import 'package:saturn/ui/mosaic_image.dart';
import '../utils/logging.dart';

import '../api/definitions.dart';
import '../api/download.dart';
import '../platform/platform_registry.dart';
import '../service/audio_service.dart';
import '../translations.i18n.dart';
import 'cached_image.dart';
export 'responsive_media_grid.dart';

Widget _pinnedBadge() => Tooltip(
  message: 'Pinned to Listen again',
  child: Container(
    padding: const EdgeInsets.all(2),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.55),
      shape: BoxShape.circle,
    ),
    child: Transform.rotate(
      angle: 0.7853981633974483,
      child: const Icon(
        Icons.push_pin,
        color: Colors.white,
        size: 21,
        shadows: [Shadow(color: Colors.black87, blurRadius: 2)],
      ),
    ),
  ),
);

const Widget _offlineDot = Padding(
  padding: EdgeInsets.symmetric(horizontal: 2.0),
  child: Icon(Octicons.primitive_dot, color: Colors.green, size: 12.0),
);

String _trackArtworkUrl(Track track) {
  // High-density tiles need the full source. Neurokaraoke's 128px thumbnail
  // variant becomes visibly soft when rendered or cropped on desktop.
  return track.albumArt?.full ?? track.albumArt?.thumb ?? '';
}

Widget _episodeProgressBadge(BuildContext context, double progress) => SizedBox(
  width: 12,
  height: 12,
  child: CircularProgressIndicator(
    value: progress.clamp(0.0, 1.0).toDouble(),
    strokeWidth: 1.8,
    color: Theme.of(context).colorScheme.primary,
    backgroundColor: Colors.transparent,
  ),
);

Widget _episodeCompleteBadge(BuildContext context) => Container(
  padding: const EdgeInsets.all(2),
  decoration: BoxDecoration(
    color: Theme.of(context).colorScheme.primaryContainer,
    shape: BoxShape.circle,
  ),
  child: Icon(
    Icons.check,
    size: 12,
    color: Theme.of(context).colorScheme.onPrimaryContainer,
  ),
);

Widget _pinnedImage(Widget image, bool pinned) => Stack(
  clipBehavior: Clip.none,
  children: [
    image,
    if (pinned) Positioned(top: 2, right: 2, child: _pinnedBadge()),
  ],
);

class PlatformBadge extends StatelessWidget {
  final String platformId;
  final bool iconOnly;
  final bool dense;

  const PlatformBadge(
    this.platformId, {
    super.key,
    this.iconOnly = false,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: PlatformManager.instance,
      builder: (context, _) {
        if (!PlatformManager.instance.hasMultipleLoggedInPlatforms) {
          return const SizedBox.shrink();
        }
        final platform = PlatformRegistry.instance.get(platformId);
        final icon =
            platform?.buildPlatformIcon(size: 14) ??
            const Icon(Icons.music_note, size: 14);
        if (iconOnly) {
          return Tooltip(
            message: platform?.platformName ?? platformId,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: dense ? 2 : 8),
              child: icon,
            ),
          );
        }

        return Container(
          constraints: const BoxConstraints(maxWidth: 120),
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
          decoration: BoxDecoration(
            border: Border.all(color: Theme.of(context).dividerColor),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              platform?.buildPlatformIcon(size: 12) ??
                  const Icon(Icons.music_note, size: 12),
              const SizedBox(width: 3),
              Flexible(
                child: Text(
                  platform?.platformName ?? platformId,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

Widget platformSubtitle(BuildContext context, String text, String platformId) {
  if (platformId == 'local' ||
      platformId.isEmpty) {
    return Text(text, maxLines: 1, overflow: TextOverflow.ellipsis);
  }
  return Row(
    children: [
      Flexible(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis)),
      const SizedBox(width: 6),
      PlatformBadge(platformId),
    ],
  );
}

/// Displays artist names as links when the platform supplied artist IDs.
class ArtistLinksText extends StatefulWidget {
  final List<Artist>? artists;
  final String? fallback;
  final TextStyle? style;
  final int maxLines;
  final TextAlign textAlign;

  const ArtistLinksText({
    super.key,
    required this.artists,
    this.fallback,
    this.style,
    this.maxLines = 1,
    this.textAlign = TextAlign.start,
  });

  @override
  State<ArtistLinksText> createState() => _ArtistLinksTextState();
}

class _ArtistLinksTextState extends State<ArtistLinksText> {
  List<TapGestureRecognizer?> _recognizers = [];

  @override
  void initState() {
    super.initState();
    _createRecognizers();
  }

  @override
  void didUpdateWidget(covariant ArtistLinksText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artists != widget.artists) {
      _disposeRecognizers();
      _createRecognizers();
    }
  }

  void _createRecognizers() {
    _recognizers = (widget.artists ?? const <Artist>[]).map((artist) {
      final id = artist.id;
      if (id == null || id.isEmpty) return null;
      return TapGestureRecognizer()
        ..onTap = () =>
            context.push('/artist/${Uri.encodeComponent(id)}', extra: artist);
    }).toList();
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer?.dispose();
    }
    _recognizers = [];
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final artists = widget.artists ?? const <Artist>[];
    final linkedArtists = artists
        .asMap()
        .entries
        .where((entry) => (entry.value.name ?? '').isNotEmpty)
        .toList();
    if (linkedArtists.isEmpty) {
      return Text(
        widget.fallback ?? '',
        maxLines: widget.maxLines,
        textAlign: widget.textAlign,
        overflow: TextOverflow.ellipsis,
        style: widget.style,
      );
    }

    final spans = <InlineSpan>[];
    for (final entry in linkedArtists) {
      if (spans.isNotEmpty) spans.add(const TextSpan(text: ', '));
      spans.add(
        TextSpan(
          text: entry.value.name,
          recognizer: _recognizers[entry.key],
          style: widget.style,
        ),
      );
    }
    return Text.rich(
      TextSpan(children: spans),
      maxLines: widget.maxLines,
      textAlign: widget.textAlign,
      overflow: TextOverflow.ellipsis,
      style: widget.style,
    );
  }
}

class TrackTile extends StatefulWidget {
  final Track track;
  final VoidCallback? onTap;
  final VoidCallback? onHold;
  final Widget? trailing;
  final bool? trailingBypass;
  final List<Widget> popupLeadingOptions;
  final bool showPlatformBadge;
  final bool hidePlatformBadge;
  final bool hideDuration;
  final bool minimal;
  final String? subtitleOverride;
  final String? secondarySubtitle;
  final double? imageProgress;
  final bool imageProgressComplete;
  final EdgeInsetsGeometry? contentPadding;
  final Color? tileColor;
  final ShapeBorder? shape;
  final int? rank;
  final double? minTileHeight;

  const TrackTile(
    this.track, {
    this.onTap,
    this.onHold,
    this.trailing,
    this.trailingBypass,
    this.popupLeadingOptions = const [],
    this.showPlatformBadge = false,
    this.hidePlatformBadge = false,
    this.hideDuration = false,
    this.minimal = false,
    this.subtitleOverride,
    this.secondarySubtitle,
    this.imageProgress,
    this.imageProgressComplete = false,
    this.contentPadding,
    this.tileColor,
    this.shape,
    this.rank,
    this.minTileHeight,
    super.key,
  });

  @override
  _TrackTileState createState() => _TrackTileState();
}

class _TrackTileState extends State<TrackTile> {
  StreamSubscription? _mediaItemSub;
  StreamSubscription<void>? _offlineLibrarySub;
  bool _isOffline = false;
  bool nowPlaying = false;

  @override
  void initState() {
    super.initState();
    _offlineLibrarySub = downloadManager.offlineLibraryChanged.listen((_) {
      _refreshOfflineState();
    });
    nowPlaying =
        widget.track.id == GetIt.I<AudioPlayerHandler>().mediaItem.value?.id;
    _mediaItemSub = GetIt.I<AudioPlayerHandler>().mediaItem.listen((item) {
      if (mounted) {
        final isNowPlaying = widget.track.id == item?.id;
        if (nowPlaying != isNowPlaying) {
          setState(() {
            nowPlaying = isNowPlaying;
          });
        }
      }
    });
    _refreshOfflineState();
  }

  Future<void> _refreshOfflineState() async {
    final offline = await downloadManager.checkOffline(track: widget.track);
    if (mounted && offline != _isOffline) setState(() => _isOffline = offline);
  }

  @override
  void didUpdateWidget(TrackTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.track.id != widget.track.id ||
        oldWidget.track.platformId != widget.track.platformId) {
      nowPlaying =
          widget.track.id ==
          GetIt.I<AudioPlayerHandler>().mediaItem.value?.id;
      _refreshOfflineState();
    }
  }

  @override
  void dispose() {
    _mediaItemSub?.cancel();
    _offlineLibrarySub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWideScreen = constraints.maxWidth >= 668;
        final capabilities = PlatformRegistry.instance
            .get(widget.track.platformId)
            ?.capabilities;
        // A Deezer station is represented in the queue by a radio:<id>
        // item. Inline library actions operate on Track IDs, so keep them off
        // the station itself. Once radio metadata supplies a real track ID,
        // that song can use the normal favorite/playlist actions.
        final isDeezerRadioStation =
            widget.track.platformId == 'deezer' &&
            widget.track.id?.startsWith('radio:') == true;

        Widget tile = ListTile(
          contentPadding: widget.contentPadding,
          minTileHeight: widget.minTileHeight,
          minVerticalPadding: widget.minTileHeight == null ? null : 0,
          tileColor: widget.tileColor,
          shape: widget.shape,
          title: Text(
            widget.track.title ?? '',
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: nowPlaying ? Theme.of(context).primaryColor : null,
            ),
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  if (widget.track.explicit == true && widget.hideDuration)
                    Container(
                      margin: const EdgeInsets.only(right: 6.0),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4.0,
                        vertical: 1.0,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(2.0),
                      ),
                      child: const Text(
                        'E',
                        style: TextStyle(
                          color: Colors.red,
                          fontSize: 10.0,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  Flexible(
                    child: widget.track.unavailable == true
                        ? Text(
                            'Track is unavailable'.i18n,
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.ellipsis,
                          )
                        : widget.subtitleOverride != null
                        ? Text(
                            widget.subtitleOverride!,
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.ellipsis,
                          )
                        : Text(
                            widget.track.artistString ?? '',
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.ellipsis,
                          ),
                  ),
                  if (!widget.minimal &&
                      widget.showPlatformBadge &&
                      !widget.hidePlatformBadge &&
                      widget.track.platformId.isNotEmpty &&
                      widget.track.platformId != 'local') ...[
                    const SizedBox(width: 6),
                    PlatformBadge(widget.track.platformId),
                  ],
                ],
              ),
              if (widget.secondarySubtitle?.isNotEmpty == true)
                Text(
                  widget.secondarySubtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
          leading: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.rank != null)
                Padding(
                  padding: const EdgeInsets.only(right: 8.0),
                  child: SizedBox(
                    width: 22,
                    child: Text(
                      '${widget.rank}',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 15.0,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).textTheme.bodySmall?.color,
                      ),
                    ),
                  ),
                ),
              Stack(
                alignment: Alignment.center,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4.0),
                    child: CachedImage(
                      url: _trackArtworkUrl(widget.track),
                      width: 48,
                      height: 48,
                    ),
                  ),
                  if (widget.track.unavailable == true)
                    Container(
                      width: 48,
                      height: 48,
                      color: Colors.black45,
                      child: const Icon(
                        Icons.error_outline,
                        color: Colors.red,
                        size: 32.0,
                      ),
                    ),
                  if (widget.track.pinned &&
                      !widget.imageProgressComplete &&
                      (widget.imageProgress == null ||
                          widget.imageProgress! <= 0))
                    Positioned(top: 2, right: 2, child: _pinnedBadge()),
                  if (widget.imageProgressComplete)
                    Positioned(
                      top: 2,
                      right: 2,
                      child: _episodeCompleteBadge(context),
                    )
                  else if (widget.imageProgress != null &&
                      widget.imageProgress! > 0)
                    Positioned(
                      top: 2,
                      right: 2,
                      child: _episodeProgressBadge(
                        context,
                        widget.imageProgress!,
                      ),
                    ),
                ],
              ),
              if (widget.track.variation != null)
                Padding(
                  padding: const EdgeInsets.only(left: 8.0),
                  child: Icon(
                    !widget.track.variation!.isNegative &&
                            widget.track.variation! != 0
                        ? Icons.arrow_upward
                        : !widget.track.variation!.isNegative &&
                              widget.track.variation! == 0
                        ? Icons.arrow_forward
                        : Icons.arrow_downward,
                    color:
                        !widget.track.variation!.isNegative &&
                            widget.track.variation! != 0
                        ? Colors.green
                        : !widget.track.variation!.isNegative &&
                              widget.track.variation! == 0
                        ? Colors.grey
                        : Colors.orange,
                    size: 30.0,
                  ),
                ),
            ],
          ),
          onTap: widget.track.unavailable == true
              ? () =>
                    Fluttertoast.showToast(msg: widget.track.unavailableMessage)
              : widget.onTap,
          onLongPress: widget.onHold,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!widget.minimal && _isOffline) _offlineDot,
              if (!widget.minimal && !widget.hideDuration) ...[
                if (widget.track.explicit == true)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 2.0),
                    child: Text('E', style: TextStyle(color: Colors.red)),
                  ),
                SizedBox(
                  width: 42.0,
                  child: Text(
                    widget.track.durationString ?? '',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
              if (!widget.minimal)
                widget.trailing ?? const SizedBox(width: 0, height: 0),
              if (!widget.minimal &&
                  ((widget.trailing == null && isWideScreen) ||
                      (widget.trailingBypass == true && isWideScreen))) ...[
                if (!isDeezerRadioStation &&
                    capabilities?.supportsLibrarySync == true)
                  IconButton(
                    icon: cache.checkTrackFavorite(widget.track)
                        ? const Icon(Icons.favorite)
                        : const Icon(Icons.favorite_border),
                    onPressed: () async {
                      final isFavorite = cache.checkTrackFavorite(widget.track);
                      final pId = widget.track.platformId;
                      final trackId = widget.track.id ?? '';
                      appLogger.info(
                        '[UI] TrackTile favorite pressed: trackId=$trackId, platformId=$pId, currentlyFavorite=$isFavorite',
                      );
                      final platform = PlatformManager.instance.getPlatform(
                        pId,
                      );
                      cache.updateTrackFavorite(
                        widget.track,
                        favorite: !isFavorite,
                      );
                      setState(() {});
                      try {
                        if (isFavorite) {
                          await platform.removeFavoriteTrack(trackId);
                        } else {
                          await platform.addFavoriteTrack(trackId);
                        }
                      } catch (error, stackTrace) {
                        appLogger.warning(
                          '[UI] Could not update track favorite: trackId=$trackId',
                          error,
                          stackTrace,
                        );
                        cache.updateTrackFavorite(
                          widget.track,
                          favorite: isFavorite,
                        );
                        if (mounted) setState(() {});
                        Fluttertoast.showToast(
                          msg: 'Could not update favorite: $error',
                        );
                        return;
                      }
                      await cache.save();
                      if (mounted) setState(() {});
                    },
                  ),
                if (!isDeezerRadioStation &&
                    capabilities?.supportsPlaylistEdit == true)
                  IconButton(
                    icon: const Icon(Icons.playlist_add_outlined),
                    onPressed: () async {
                      final selectedTrack = widget.track;
                      await showDialog(
                        context: context,
                        builder: (context) {
                          return SelectPlaylistDialog(
                            track: selectedTrack,
                            callback: (Playlist p) async {
                              final pId = selectedTrack.platformId;
                              final platform = PlatformManager.instance
                                  .getPlatform(pId);
                              await platform.addToPlaylist(
                                selectedTrack.id!,
                                p.id!,
                              );
                              //Update the playlist if offline
                              if (await downloadManager.checkOffline(
                                playlist: p,
                              )) {
                                downloadManager.addOfflinePlaylist(p);
                              }
                            },
                          );
                        },
                      );
                    },
                  ),
                Builder(
                  builder: (BuildContext buttonContext) {
                    return IconButton(
                      icon: const Icon(Icons.more_vert),
                      onPressed: () {
                        // Get button position for popup menu
                        final RenderBox button =
                            buttonContext.findRenderObject() as RenderBox;
                        final RenderBox overlay =
                            Overlay.of(buttonContext).context.findRenderObject()
                                as RenderBox;
                        final RelativeRect position = RelativeRect.fromRect(
                          Rect.fromPoints(
                            button.localToGlobal(
                              Offset.zero,
                              ancestor: overlay,
                            ),
                            button.localToGlobal(
                              button.size.bottomRight(Offset.zero),
                              ancestor: overlay,
                            ),
                          ),
                          Offset.zero & overlay.size,
                        );

                        MenuSheet().defaultTrackPopup(
                          widget.track,
                          context: context,
                          position: position,
                          leadingOptions: widget.popupLeadingOptions,
                        );
                      },
                    );
                  },
                ),
              ],
            ],
          ),
        );

        if (widget.track.unavailable == true) {
          return Opacity(opacity: 0.5, child: tile);
        }

        return tile;
      },
    );
  }
}

class AlbumTile extends StatelessWidget {
  final Album album;
  final VoidCallback? onTap;
  final VoidCallback? onHold;
  final Widget? trailing;
  final bool showPlatformBadge;
  final bool hidePlatformBadge;
  final String? subtitleOverride;

  const AlbumTile(
    this.album, {
    super.key,
    this.onTap,
    this.onHold,
    this.trailing,
    this.showPlatformBadge = false,
    this.hidePlatformBadge = false,
    this.subtitleOverride,
  });

  @override
  Widget build(BuildContext context) {
    final subtitle = Row(
      children: [
        Flexible(
          child: ArtistLinksText(
            artists: album.artists,
            fallback: album.artistString,
            maxLines: 1,
          ),
        ),
        if (showPlatformBadge &&
            !hidePlatformBadge &&
            album.platformId != 'local' &&
            album.platformId.isNotEmpty) ...[
          const SizedBox(width: 6),
          PlatformBadge(album.platformId),
        ],
      ],
    );
    return ListTile(
      title: Text(album.title ?? '', maxLines: 1),
      subtitle: subtitle,
      leading: _pinnedImage(
        CachedImage(url: album.art?.thumb ?? '', width: 48),
        album.pinned,
      ),
      onTap: onTap,
      onLongPress: onHold,
      trailing: trailing,
    );
  }
}

class ArtistTile extends StatelessWidget {
  final Artist artist;
  final VoidCallback? onTap;
  final VoidCallback? onHold;
  final double? width;

  const ArtistTile(
    this.artist, {
    super.key,
    this.onTap,
    this.onHold,
    this.width,
  });

  @override
  Widget build(BuildContext context) {
    final cardWidth = width ?? 150.0;
    final containerSize = (cardWidth - 16.0).clamp(60.0, 400.0);
    final circleSize = (containerSize - 16.0).clamp(40.0, 380.0);
    final cardHeight = containerSize + 64.0;
    return SizedBox(
      width: cardWidth,
      height: cardHeight,
      child: InkWell(
        borderRadius: BorderRadius.circular(12.0),
        onTap: onTap,
        onLongPress: onHold,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: SizedBox(
                width: containerSize,
                height: containerSize,
                child: Stack(
                  children: [
                    Center(
                      child: CachedImage(
                        url: artist.picture?.thumb ?? '',
                        circular: true,
                        width: circleSize,
                        height: circleSize,
                      ),
                    ),
                    if (artist.pinned)
                      Positioned(top: 4, right: 4, child: _pinnedBadge()),
                  ],
                ),
              ),
            ),
            Container(height: 2.0),
            SizedBox(
              width: (cardWidth - 6.0).clamp(50.0, 400.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: Text(
                      artist.name ?? '',
                      maxLines: 1,
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14.0),
                    ),
                  ),
                  if (artist.variation != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Icon(
                        artist.variation! > 0
                            ? Icons.arrow_upward
                            : artist.variation! == 0
                            ? Icons.arrow_forward
                            : Icons.arrow_downward,
                        color: artist.variation! > 0
                            ? Colors.green
                            : artist.variation! == 0
                            ? Colors.grey
                            : Colors.orange,
                        size: 18,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PlaylistTile extends StatefulWidget {
  final Playlist playlist;
  final VoidCallback? onTap;
  final VoidCallback? onHold;
  final Widget? trailing;
  final bool showPlatformBadge;
  final bool hidePlatformBadge;
  final String? subtitleOverride;

  const PlaylistTile(
    this.playlist, {
    super.key,
    this.onHold,
    this.onTap,
    this.trailing,
    this.showPlatformBadge = false,
    this.hidePlatformBadge = false,
    this.subtitleOverride,
  });

  @override
  State<PlaylistTile> createState() => _PlaylistTileState();
}

class _PlaylistTileState extends State<PlaylistTile> {
  late bool _isOffline;
  StreamSubscription<void>? _offlineLibrarySub;

  @override
  void initState() {
    super.initState();
    _isOffline = false;
    _offlineLibrarySub = downloadManager.offlineLibraryChanged.listen((_) {
      _refreshOfflineState();
    });
    _refreshOfflineState();
  }

  @override
  void didUpdateWidget(covariant PlaylistTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playlist.id != widget.playlist.id ||
        oldWidget.playlist.platformId != widget.playlist.platformId) {
      _isOffline = false;
      _refreshOfflineState();
    }
  }

  Future<void> _refreshOfflineState() async {
    final isOffline = await downloadManager.checkOffline(
      playlist: widget.playlist,
    );
    if (mounted && isOffline != _isOffline) {
      setState(() => _isOffline = isOffline);
    }
  }

  @override
  void dispose() {
    _offlineLibrarySub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playlist = widget.playlist;
    final creatorName = playlist.user?.name;
    final subtitle = widget.subtitleOverride ?? creatorName;
    final showBadge = widget.showPlatformBadge &&
        !widget.hidePlatformBadge &&
        playlist.platformId.isNotEmpty &&
        playlist.platformId != 'local';
    return ListTile(
      title: Text(playlist.title ?? '', maxLines: 1),
      subtitle: Row(
        children: [
          Flexible(
            child: Text(
              subtitle?.trim().isNotEmpty == true ? subtitle! : ' ',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (showBadge) ...[
            const SizedBox(width: 6),
            PlatformBadge(playlist.platformId),
          ],
        ],
      ),
      leading: _pinnedImage(
        ((playlist.image?.thumb ?? '').isEmpty &&
                playlist.mosaicImages != null &&
                playlist.mosaicImages!.isNotEmpty)
            ? MosaicImage(urls: playlist.mosaicImages!, width: 48, height: 48)
            : CachedImage(url: playlist.image?.thumb ?? '', width: 48),
        playlist.pinned,
      ),
      onTap: widget.onTap,
      onLongPress: widget.onHold,
      trailing: _isOffline || widget.trailing != null
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_isOffline) _offlineDot,
                if (widget.trailing != null) widget.trailing!,
              ],
            )
          : null,
    );
  }
}

class ArtistHorizontalTile extends StatelessWidget {
  final Artist artist;
  final int? rank;
  final VoidCallback? onTap;
  final VoidCallback? onHold;
  final Widget? trailing;
  final bool showPlatformBadge;

  const ArtistHorizontalTile(
    this.artist, {
    super.key,
    this.rank,
    this.onHold,
    this.onTap,
    this.trailing,
    this.showPlatformBadge = false,
  });

  @override
  Widget build(BuildContext context) {
    final showBadge = showPlatformBadge &&
        artist.platformId.isNotEmpty &&
        artist.platformId != 'local';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.0),
      child: ListTile(
        title: Row(
          children: [
            if (rank != null)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text('$rank'),
              ),
            Expanded(
              child: Text(
                artist.name ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        subtitle: artist.fansString.isNotEmpty || showBadge
            ? Row(
                children: [
                  if (artist.fansString.isNotEmpty)
                    Flexible(
                      child: Text(
                        '${artist.fansString} ${PlatformRegistry.instance.get(artist.platformId)?.capabilities.audienceLabel ?? 'fans'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  if (showBadge) ...[
                    if (artist.fansString.isNotEmpty) const SizedBox(width: 6),
                    PlatformBadge(artist.platformId),
                  ],
                ],
              )
            : null,
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _pinnedImage(
              CachedImage(url: artist.picture?.thumb ?? '', circular: true),
              artist.pinned,
            ),
            if (artist.variation != null)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Icon(
                  artist.variation! > 0
                      ? Icons.arrow_upward
                      : artist.variation == 0
                      ? Icons.arrow_forward
                      : Icons.arrow_downward,
                  color: artist.variation! > 0
                      ? Colors.green
                      : artist.variation == 0
                      ? Colors.grey
                      : Colors.orange,
                  size: 30,
                ),
              ),
          ],
        ),
        onTap: onTap,
        onLongPress: onHold,
        trailing: trailing,
      ),
    );
  }
}

class ArtistMessageCard extends StatelessWidget {
  final String message;
  final ImageDetails? artistImage;

  const ArtistMessageCard({required this.message, this.artistImage, super.key});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: accent.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          ClipOval(
            child: CachedImage(
              url: artistImage?.thumb ?? '',
              width: 40,
              height: 40,
              circular: true,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(message)),
        ],
      ),
    );
  }
}

class PlaylistCardTile extends StatefulWidget {
  final Playlist playlist;
  final VoidCallback? onTap;
  final VoidCallback? onHold;
  final double? width;
  final String? subtitleOverride;
  final bool showPlatformBadge;

  const PlaylistCardTile(
    this.playlist, {
    super.key,
    this.onTap,
    this.onHold,
    this.width,
    this.subtitleOverride,
    this.showPlatformBadge = false,
  });

  @override
  State<PlaylistCardTile> createState() => _PlaylistCardTileState();
}

class _PlaylistCardTileState extends State<PlaylistCardTile> {
  late bool _isOffline;
  StreamSubscription<void>? _offlineLibrarySub;

  @override
  void initState() {
    super.initState();
    _isOffline = false;
    _offlineLibrarySub = downloadManager.offlineLibraryChanged.listen((_) {
      _refreshOfflineState();
    });
    _refreshOfflineState();
  }

  @override
  void didUpdateWidget(covariant PlaylistCardTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playlist.id != widget.playlist.id ||
        oldWidget.playlist.platformId != widget.playlist.platformId) {
      _isOffline = false;
      _refreshOfflineState();
    }
  }

  Future<void> _refreshOfflineState() async {
    final isOffline = await downloadManager.checkOffline(
      playlist: widget.playlist,
    );
    if (mounted && isOffline != _isOffline) {
      setState(() => _isOffline = isOffline);
    }
  }

  @override
  void dispose() {
    _offlineLibrarySub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playlist = widget.playlist;
    final creatorName = playlist.user?.name;
    final subtitle = widget.subtitleOverride ?? creatorName;
    final cardWidth = widget.width ?? 150.0;
    final imageSize = (cardWidth - 16.0).clamp(60.0, 400.0);
    final cardHeight = imageSize + 64.0;
    final showBadge = widget.showPlatformBadge &&
        playlist.platformId.isNotEmpty &&
        playlist.platformId != 'local';
    return SizedBox(
      height: cardHeight,
      width: cardWidth,
      child: InkWell(
        borderRadius: BorderRadius.circular(12.0),
        onTap: widget.onTap,
        onLongPress: widget.onHold,
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(8),
              child: Stack(
                children: [
                  ((playlist.image?.thumb ?? '').isEmpty &&
                          playlist.mosaicImages != null &&
                          playlist.mosaicImages!.isNotEmpty)
                      ? MosaicImage(
                          urls: playlist.mosaicImages!,
                          width: imageSize,
                          height: imageSize,
                          rounded: true,
                        )
                      : CachedImage(
                          url: playlist.image?.thumb ?? '',
                          width: imageSize,
                          height: imageSize,
                          rounded: true,
                        ),
                  if (playlist.pinned)
                    Positioned(top: 4, right: 4, child: _pinnedBadge()),
                ],
              ),
            ),
            Container(height: 2.0),
            SizedBox(
              width: (cardWidth - 6.0).clamp(50.0, 400.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (showBadge)
                        PlatformBadge(
                          playlist.platformId,
                          iconOnly: true,
                          dense: true,
                        ),
                      if (showBadge) const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          playlist.title ?? '',
                          maxLines: 1,
                          textAlign: TextAlign.center,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 14.0),
                        ),
                      ),
                      if (_isOffline) _offlineDot,
                    ],
                  ),
                  Text(
                    subtitle?.trim().isNotEmpty == true ? subtitle! : ' ',
                    maxLines: 1,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PlaylistActionCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final VoidCallback onTap;
  final double? width;

  const PlaylistActionCard({
    required this.title,
    required this.icon,
    required this.onTap,
    this.width,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return SizedBox(
      width: width,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: AspectRatio(
                aspectRatio: 1,
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Center(child: Icon(icon, color: color, size: 44)),
                ),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              title,
              maxLines: 2,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AlbumCard extends StatelessWidget {
  final Album album;
  final VoidCallback? onTap;
  final VoidCallback? onHold;
  final double? width;
  final bool showPlatformBadge;

  const AlbumCard(
    this.album, {
    super.key,
    this.onTap,
    this.onHold,
    this.width,
    this.showPlatformBadge = false,
  });

  @override
  Widget build(BuildContext context) {
    final cardWidth = width ?? 150.0;
    final imageSize = (cardWidth - 16.0).clamp(60.0, 400.0);
    final cardHeight = imageSize + 64.0;
    final artistSubtitle = album.artistString?.trim() ?? '';
    final showBadge = showPlatformBadge &&
        album.platformId.isNotEmpty &&
        album.platformId != 'local';
    return SizedBox(
      width: cardWidth,
      height: cardHeight,
      child: InkWell(
        borderRadius: BorderRadius.circular(12.0),
        onTap: onTap,
        onLongPress: onHold,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Stack(
                children: [
                  CachedImage(
                    width: imageSize,
                    height: imageSize,
                    url: album.art?.thumb ?? '',
                    rounded: true,
                  ),
                  if (album.pinned)
                    Positioned(top: 4, right: 4, child: _pinnedBadge()),
                  if (showBadge)
                    Positioned(
                      top: 4,
                      left: 4,
                      child: PlatformBadge(album.platformId, iconOnly: true),
                    ),
                ],
              ),
            ),
            SizedBox(
              width: (cardWidth - 6.0).clamp(50.0, 400.0),
              child: Text(
                album.title ?? '',
                maxLines: 1,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14.0),
              ),
            ),
            Container(height: 4.0),
            SizedBox(
              width: (cardWidth - 6.0).clamp(50.0, 400.0),
              child: ArtistLinksText(
                artists: album.artists,
                fallback: artistSubtitle,
                maxLines: 1,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12.0,
                  color: (Theme.of(context).brightness == Brightness.light)
                      ? Colors.grey[800]
                      : Colors.white70,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class TrackCard extends StatefulWidget {
  final Track track;
  final VoidCallback? onTap;
  final VoidCallback? onHold;
  final double? width;

  const TrackCard(
    this.track, {
    super.key,
    this.onTap,
    this.onHold,
    this.width,
  });

  @override
  State<TrackCard> createState() => _TrackCardState();
}

class _TrackCardState extends State<TrackCard> {
  late bool _isOffline;
  StreamSubscription<void>? _offlineLibrarySub;

  @override
  void initState() {
    super.initState();
    _isOffline = widget.track.offline == true;
    _offlineLibrarySub = downloadManager.offlineLibraryChanged.listen((_) {
      _refreshOfflineState();
    });
    _refreshOfflineState();
  }

  @override
  void didUpdateWidget(covariant TrackCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.track.id != widget.track.id ||
        oldWidget.track.platformId != widget.track.platformId) {
      _isOffline = widget.track.offline == true;
      _refreshOfflineState();
    }
  }

  Future<void> _refreshOfflineState() async {
    final isOffline = await downloadManager.checkOffline(track: widget.track);
    if (mounted && isOffline != _isOffline) {
      setState(() => _isOffline = isOffline);
    }
  }

  @override
  void dispose() {
    _offlineLibrarySub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final track = widget.track;
    final effectiveOnTap = track.unavailable == true
        ? () => Fluttertoast.showToast(msg: track.unavailableMessage)
        : widget.onTap;

    final cardWidth = widget.width ?? 150.0;
    final imageSize = (cardWidth - 16.0).clamp(60.0, 400.0);
    final cardHeight = imageSize + 64.0;

    final card = SizedBox(
      width: cardWidth,
      height: cardHeight,
      child: InkWell(
        borderRadius: BorderRadius.circular(12.0),
        onTap: effectiveOnTap,
        onLongPress: widget.onHold,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 8.0,
                vertical: 6.0,
              ),
              child: Stack(
                children: [
                  CachedImage(
                    width: imageSize,
                    height: imageSize,
                    url: _trackArtworkUrl(track),
                    rounded: true,
                  ),
                  if (track.unavailable == true)
                    Positioned.fill(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.black45,
                          borderRadius: BorderRadius.circular(12.0),
                        ),
                        child: const Center(
                          child: Icon(
                            Icons.error_outline,
                            color: Colors.red,
                            size: 32.0,
                          ),
                        ),
                      ),
                    ),
                  if (track.pinned)
                    Positioned(top: 2, right: 2, child: _pinnedBadge()),
                  if (track.variation != null)
                    Positioned(
                      left: 4,
                      bottom: 4,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black87,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(3),
                          child: Icon(
                            track.variation! > 0
                                ? Icons.arrow_upward
                                : track.variation! == 0
                                ? Icons.arrow_forward
                                : Icons.arrow_downward,
                            color: track.variation! > 0
                                ? Colors.greenAccent
                                : track.variation! == 0
                                ? Colors.white70
                                : Colors.orangeAccent,
                            size: 15,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            SizedBox(
              width: (cardWidth - 6.0).clamp(50.0, 400.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: Text(
                      track.title ?? '',
                      maxLines: 1,
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14.0),
                    ),
                  ),
                  if (_isOffline) _offlineDot,
                ],
              ),
            ),
            Container(height: 4.0),
            SizedBox(
              width: (cardWidth - 6.0).clamp(50.0, 400.0),
              child: Text(
                track.artistString ?? '',
                maxLines: 1,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.0,
                  color: (Theme.of(context).brightness == Brightness.light)
                      ? Colors.grey[800]
                      : Colors.white70,
                ),
              ),
            ),
          ],
        ),
      ),
    );

    if (track.unavailable == true) {
      return Opacity(opacity: 0.5, child: card);
    }
    return card;
  }
}

class ShowCard extends StatelessWidget {
  final Show show;
  final VoidCallback? onTap;
  final VoidCallback? onHold;
  final Widget? trailing;
  final double? width;

  const ShowCard(
    this.show, {
    super.key,
    this.onTap,
    this.onHold,
    this.trailing,
    this.width,
  });

  @override
  Widget build(BuildContext context) {
    final cardWidth = width ?? 150.0;
    final imageSize = (cardWidth - 16.0).clamp(60.0, 400.0);
    final cardHeight = imageSize + 64.0;

    return SizedBox(
      width: cardWidth,
      height: cardHeight,
      child: InkWell(
        borderRadius: BorderRadius.circular(12.0),
        onTap: onTap,
        onLongPress: onHold,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8.0,
                    vertical: 6.0,
                  ),
                  child: CachedImage(
                    url: show.art?.thumb ?? '',
                    width: imageSize,
                    height: imageSize,
                    rounded: true,
                  ),
                ),
                if (trailing != null)
                  Positioned(left: 0, top: 0, child: trailing!),
                if (show.pinned)
                  Positioned(top: 8, right: 8, child: _pinnedBadge()),
              ],
            ),
            SizedBox(
              width: (cardWidth - 6.0).clamp(50.0, 400.0),
              child: Text(
                show.name ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14.0),
              ),
            ),
            if (show.creator != null && show.creator!.isNotEmpty)
              Container(height: 4.0),
            if (show.creator != null && show.creator!.isNotEmpty)
              SizedBox(
                width: (cardWidth - 6.0).clamp(50.0, 400.0),
                child: Text(
                  show.creator ?? '',
                  maxLines: 1,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.0,
                    color: (Theme.of(context).brightness == Brightness.light)
                        ? Colors.grey[800]
                        : Colors.white70,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

Widget _episodeExplicitBadge(BuildContext context) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
  decoration: BoxDecoration(
    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.15),
    borderRadius: BorderRadius.circular(2),
  ),
  child: const Text(
    'E',
    style: TextStyle(
      color: Colors.red,
      fontSize: 10,
      fontWeight: FontWeight.bold,
    ),
  ),
);

class ShowEpisodeCard extends StatelessWidget {
  final ShowEpisode episode;
  final VoidCallback? onTap;
  final VoidCallback? onHold;
  final Widget? trailing;
  final double? width;

  const ShowEpisodeCard(
    this.episode, {
    super.key,
    this.onTap,
    this.onHold,
    this.trailing,
    this.width,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final artUrl =
        episode.art?.thumb ??
        episode.art?.full ??
        episode.show?.art?.thumb ??
        episode.show?.art?.full;
    final isHeard = episode.isHeard == true;
    final bookmarkSec = episode.bookmarkSeconds;
    final duration = episode.duration;
    final progress =
        episode.progressPercentage ??
        (bookmarkSec != null && duration != null && duration.inSeconds > 0
            ? bookmarkSec / duration.inSeconds
            : null);

    final cardWidth = width ?? 150.0;
    final imageSize = (cardWidth - 16.0).clamp(60.0, 400.0);
    final cardHeight = imageSize + 64.0;

    return SizedBox(
      width: cardWidth,
      height: cardHeight,
      child: InkWell(
        borderRadius: BorderRadius.circular(12.0),
        onTap: onTap,
        onLongPress: onHold,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 8.0,
                vertical: 6.0,
              ),
              child: Stack(
                children: [
                  CachedImage(
                    url: artUrl ?? '',
                    width: imageSize,
                    height: imageSize,
                    rounded: true,
                  ),
                  if (trailing != null)
                    Positioned(left: 0, top: 0, child: trailing!),
                  if (isHeard)
                    Positioned(
                      top: 2,
                      right: 2,
                      child: _episodeCompleteBadge(context),
                    )
                  else if (progress != null && progress > 0.0)
                    Positioned(
                      top: 2,
                      right: 2,
                      child: _episodeProgressBadge(context, progress),
                    ),
                  if (episode.pinned &&
                      !isHeard &&
                      (progress == null || progress <= 0))
                    Positioned(top: 8, right: 8, child: _pinnedBadge()),
                ],
              ),
            ),
            SizedBox(
              width: (cardWidth - 6.0).clamp(50.0, 400.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: Text(
                      episode.title ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 14.0),
                    ),
                  ),
                  if (episode.isExplicit == true) ...[
                    const SizedBox(width: 4),
                    _episodeExplicitBadge(context),
                  ],
                ],
              ),
            ),
            if (episode.show?.name != null && episode.show!.name!.isNotEmpty)
              Container(height: 4.0),
            if (episode.show?.name != null && episode.show!.name!.isNotEmpty)
              SizedBox(
                width: (cardWidth - 6.0).clamp(50.0, 400.0),
                child: Text(
                  episode.show!.name!,
                  maxLines: 1,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.0,
                    color: (theme.brightness == Brightness.light)
                        ? Colors.grey[800]
                        : Colors.white70,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class ShowTile extends StatelessWidget {
  final Show show;
  final VoidCallback? onTap;
  final VoidCallback? onHold;
  final Widget? trailing;

  const ShowTile(
    this.show, {
    super.key,
    this.onTap,
    this.onHold,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(
        show.name ?? '',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        show.creator ?? '',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: onTap,
      onLongPress: onHold,
      leading: _pinnedImage(
        CachedImage(url: show.art?.thumb ?? '', width: 48),
        show.pinned,
      ),
      trailing: trailing,
    );
  }
}

class ShowEpisodeTile extends StatelessWidget {
  final ShowEpisode episode;
  final VoidCallback? onTap;
  final VoidCallback? onHold;
  final Widget? trailing;

  const ShowEpisodeTile(
    this.episode, {
    super.key,
    this.onTap,
    this.onHold,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final artUrl =
        episode.art?.thumb ??
        episode.art?.full ??
        episode.show?.art?.thumb ??
        episode.show?.art?.full;

    final isHeard = episode.isHeard == true;
    final bookmarkSec = episode.bookmarkSeconds;
    final duration = episode.duration;
    final progress =
        episode.progressPercentage ??
        (bookmarkSec != null && duration != null && duration.inSeconds > 0
            ? bookmarkSec / duration.inSeconds
            : null);

    String? progressText;
    if (isHeard) {
      progressText = 'Played'.i18n;
    } else if (progress != null && progress > 0.02 && duration != null) {
      final playedSeconds =
          bookmarkSec ??
          ((progress.clamp(0.0, 1.0) * duration.inSeconds).round());
      final remaining = duration.inSeconds - playedSeconds;
      if (remaining > 60) {
        progressText = '${remaining ~/ 60}m left';
      } else {
        progressText = '${(progress * 100).round()}%';
      }
    }

    final metadata = [
      if (episode.publishedDate?.isNotEmpty == true) episode.publishedDate!,
      if (episode.durationString.isNotEmpty) episode.durationString,
      if (progressText != null && progressText.isNotEmpty) progressText,
    ].join(' • ');

    return InkWell(
      onLongPress: onHold,
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 16.0,
              vertical: 10.0,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        width: 58,
                        height: 58,
                        color: theme.colorScheme.surfaceContainerHighest,
                        child: artUrl != null && artUrl.isNotEmpty
                            ? CachedImage(url: artUrl, fit: BoxFit.cover)
                            : const Icon(Icons.podcasts, size: 28),
                      ),
                    ),
                    if (isHeard)
                      Positioned(
                        top: 2,
                        right: 2,
                        child: _episodeCompleteBadge(context),
                      )
                    else if (progress != null && progress > 0.0)
                      Positioned(
                        top: 2,
                        right: 2,
                        child: _episodeProgressBadge(context, progress),
                      ),
                    if (episode.pinned &&
                        !isHeard &&
                        (progress == null || progress <= 0))
                      Positioned(top: 2, right: 2, child: _pinnedBadge()),
                  ],
                ),
                const SizedBox(width: 12.0),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              episode.title ?? '',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                                fontSize: 14.5,
                              ),
                            ),
                          ),
                          if (episode.isExplicit == true) ...[
                            const SizedBox(width: 6),
                            _episodeExplicitBadge(context),
                          ],
                        ],
                      ),
                      if (episode.description?.isNotEmpty == true) ...[
                        const SizedBox(height: 3.0),
                        Text(
                          episode.description!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            color: theme.textTheme.titleMedium?.color
                                ?.withValues(alpha: 0.75),
                          ),
                        ),
                      ],
                      if (metadata.isNotEmpty) ...[
                        const SizedBox(height: 5.0),
                        Text(
                          metadata,
                          textAlign: TextAlign.left,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.bold,
                            fontFeatures: const [FontFeature.tabularFigures()],
                            color: isHeard
                                ? theme.colorScheme.primary
                                : theme.textTheme.titleMedium?.color
                                      ?.withValues(alpha: 0.6),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
          const Divider(height: 1),
        ],
      ),
    );
  }
}

class LiveRadioTile extends StatelessWidget {
  final LiveRadio radio;
  final VoidCallback? onTap;
  final VoidCallback? onHold;
  final double? width;
  const LiveRadioTile(
    this.radio, {
    super.key,
    this.onHold,
    this.onTap,
    this.width,
  });

  @override
  Widget build(BuildContext context) {
    final cardWidth = width ?? 150.0;
    final imageSize = (cardWidth - 16.0).clamp(60.0, 400.0);
    final cardHeight = imageSize + 72.0;

    return SizedBox(
      width: cardWidth,
      height: cardHeight,
      child: InkWell(
        borderRadius: BorderRadius.circular(12.0),
        onTap: onTap,
        onLongPress: onHold,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Stack(
                children: [
                  CachedImage(
                    url: radio.imageUrl ?? '',
                    rounded: true,
                    width: imageSize,
                    height: imageSize,
                  ),
                  if (radio.pinned)
                    Positioned(top: 4, right: 4, child: _pinnedBadge()),
                ],
              ),
            ),
            Container(height: 2.0),
            SizedBox(
              width: (cardWidth - 6.0).clamp(50.0, 400.0),
              child: Text(
                radio.title ?? '',
                maxLines: 1,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14.0,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            if (radio.description != null && radio.description!.isNotEmpty)
              SizedBox(
                width: (cardWidth - 6.0).clamp(50.0, 400.0),
                child: Text(
                  radio.description!,
                  maxLines: 1,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.0,
                    color: Theme.of(context).textTheme.bodySmall?.color,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class LiveRadioListTile extends StatelessWidget {
  final LiveRadio radio;
  final VoidCallback? onTap;
  final VoidCallback? onHold;
  final Widget? trailing;
  final bool showPlatformBadge;

  const LiveRadioListTile(
    this.radio, {
    super.key,
    this.onTap,
    this.onHold,
    this.trailing,
    this.showPlatformBadge = false,
  });

  @override
  Widget build(BuildContext context) {
    final platformId = radio.platformId ?? '';
    final showBadge = showPlatformBadge &&
        platformId.isNotEmpty &&
        platformId != 'local';
    return ListTile(
      title: Text(radio.title ?? '', maxLines: 1),
      subtitle: Row(
        children: [
          Expanded(
            child: Text(
              radio.description?.trim().isNotEmpty == true
                  ? radio.description!.trim()
                  : 'Live Radio',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (showBadge) ...[
            const SizedBox(width: 6),
            PlatformBadge(platformId),
          ],
        ],
      ),
      leading: _pinnedImage(
        CachedImage(url: radio.imageUrl ?? '', width: 48, rounded: true),
        radio.pinned,
      ),
      onTap: onTap,
      onLongPress: onHold,
      trailing: trailing,
    );
  }
}
