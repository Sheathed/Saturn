import 'package:material_ui/material_ui.dart';
import 'package:get_it/get_it.dart';
import 'package:silky_scroll/silky_scroll.dart';
import 'package:saturn/ui/smooth_scroll_config.dart';

import '../api/definitions.dart';
import '../service/audio_service.dart';
import 'cached_image.dart';
import 'details_screens.dart';
import 'menu.dart';
import 'toast.dart';

/// A universal, responsive grid widget for media tiles.
///
/// Automatically calculates columns and cell aspect ratios so that square (1:1)
/// artwork and metadata scale seamlessly across all screen sizes (phones, tablets,
/// desktops) without unsightly gaps or dead space.
class ResponsiveMediaGrid extends StatelessWidget {
  final int itemCount;
  final Widget Function(BuildContext context, int index) itemBuilder;
  final EdgeInsetsGeometry padding;
  final double mainAxisSpacing;
  final double crossAxisSpacing;
  final ScrollPhysics? physics;
  final ScrollController? controller;
  final bool shrinkWrap;
  final double targetCardWidth;
  final double extraTextHeight;
  final int? minColumns;
  final int? maxColumns;

  const ResponsiveMediaGrid({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.padding = const EdgeInsets.all(12.0),
    this.mainAxisSpacing = 10.0,
    this.crossAxisSpacing = 10.0,
    this.physics,
    this.controller,
    this.shrinkWrap = false,
    this.targetCardWidth = 165.0,
    this.extraTextHeight = 48.0,
    this.minColumns,
    this.maxColumns,
  });

  static Widget builder({
    Key? key,
    required int itemCount,
    required Widget Function(BuildContext context, int index) itemBuilder,
    EdgeInsetsGeometry padding = const EdgeInsets.all(12.0),
    double mainAxisSpacing = 10.0,
    double crossAxisSpacing = 10.0,
    ScrollPhysics? physics,
    ScrollController? controller,
    bool shrinkWrap = false,
    double targetCardWidth = 165.0,
    double extraTextHeight = 48.0,
    int? minColumns,
    int? maxColumns,
  }) {
    return ResponsiveMediaGrid(
      key: key,
      itemCount: itemCount,
      itemBuilder: itemBuilder,
      padding: padding,
      mainAxisSpacing: mainAxisSpacing,
      crossAxisSpacing: crossAxisSpacing,
      physics: physics,
      controller: controller,
      shrinkWrap: shrinkWrap,
      targetCardWidth: targetCardWidth,
      extraTextHeight: extraTextHeight,
      minColumns: minColumns,
      maxColumns: maxColumns,
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double availableWidth = constraints.maxWidth - padding.horizontal;

        int columns;
        if (availableWidth < 600) {
          columns = 2; // Mobile portrait
        } else {
          // Use the largest whole number of cards that fit at the target
          // width. Rounding up made cards too wide and rounding down from a
          // fixed three-column fallback wasted space around tablet widths.
          columns = (availableWidth / (targetCardWidth + crossAxisSpacing))
              .floor()
              .clamp(3, 14);
        }

        if (minColumns != null && columns < minColumns!) {
          columns = minColumns!;
        }
        if (maxColumns != null && columns > maxColumns!) {
          columns = maxColumns!;
        }

        final double columnWidth =
            (availableWidth - ((columns - 1) * crossAxisSpacing)) / columns;
        final double itemHeight = columnWidth + extraTextHeight;
        final double childAspectRatio = columnWidth / itemHeight;

        // Library pages place these grids inside their own scrolling list.
        // Avoid nesting another Scrollable there: on desktop the inner grid
        // captures mouse-wheel events even when its physics are disabled.
        if (shrinkWrap) {
          return Padding(
            padding: padding,
            child: Wrap(
              spacing: crossAxisSpacing,
              runSpacing: mainAxisSpacing,
              children: List<Widget>.generate(
                itemCount,
                (index) => SizedBox(
                  width: columnWidth,
                  height: itemHeight,
                  child: itemBuilder(context, index),
                ),
              ),
            ),
          );
        }

        return SilkyGridView.builder(
          silkyConfig: silkyScrollConfig,
          controller: controller,
          padding: padding,
          physics: physics ?? ScrollConfiguration.of(context).getScrollPhysics(context),
          shrinkWrap: shrinkWrap,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: mainAxisSpacing,
            crossAxisSpacing: crossAxisSpacing,
            childAspectRatio: childAspectRatio,
          ),
          itemCount: itemCount,
          itemBuilder: itemBuilder,
        );
      },
    );
  }
}

/// A responsive, universal media card tile for grids.
///
/// Fills the grid column width with a 1:1 square artwork (or circular avatar
/// for artists) and places title + subtitle neatly beneath it.
class MediaCardTile extends StatelessWidget {
  final dynamic item;
  final String? title;
  final String? subtitle;
  final String? imageUrl;
  final bool? isArtist;
  final bool? pinned;
  final int? variation;
  final bool? explicit;
  final VoidCallback? onTap;
  final VoidCallback? onHold;
  final BorderRadius? borderRadius;

  const MediaCardTile({
    super.key,
    required this.item,
    this.title,
    this.subtitle,
    this.imageUrl,
    this.isArtist,
    this.pinned,
    this.variation,
    this.explicit,
    this.onTap,
    this.onHold,
    this.borderRadius,
  });

  void _defaultTap(BuildContext context) {
    if (item is Album) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => AlbumDetails(item as Album)),
      );
    } else if (item is Playlist) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => PlaylistDetails(item as Playlist)),
      );
    } else if (item is Artist) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => ArtistDetails(item as Artist)),
      );
    } else if (item is Show) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => ShowScreen(item as Show)),
      );
    } else if (item is LiveRadio) {
      final radio = item as LiveRadio;
      if (radio.isMix && radio.id != null) {
        GetIt.I<AudioPlayerHandler>().playMix(
          radio.id!,
          radio.title ?? 'Mix',
          platformId: radio.platformId ?? 'general',
        );
      } else if (radio.id != null) {
        GetIt.I<AudioPlayerHandler>().playRadio(
          id: radio.id!,
          title: radio.title ?? 'Radio',
          description: radio.description,
          artUrl: radio.image?.full ?? radio.image?.thumb,
          platformId: radio.platformId ?? 'general',
        );
      }
    } else if (item is ShowEpisode) {
      final episode = item as ShowEpisode;
      GetIt.I<AudioPlayerHandler>().playShowEpisode(
        episode.show ?? Show(name: 'Podcast', platformId: 'general'),
        [episode],
        index: 0,
      );
    } else if (item is Track) {
      final track = item as Track;
      if (track.unavailable == true) {
        Fluttertoast.showToast(msg: track.unavailableMessage);
        return;
      }
      GetIt.I<AudioPlayerHandler>().playFromTrackList(
        [track],
        track.id ?? '',
        QueueSource(id: track.id, text: track.title, source: 'browse'),
      );
    }
  }

  void _defaultHold(BuildContext context) {
    final menu = MenuSheet();
    if (item is Track) {
      menu.defaultTrackMenu(item as Track, context: context);
    } else if (item is Album) {
      menu.defaultAlbumMenu(item as Album, context: context);
    } else if (item is Playlist) {
      menu.defaultPlaylistMenu(item as Playlist, context: context);
    } else if (item is Artist) {
      menu.defaultArtistMenu(item as Artist, context: context);
    } else if (item is Show) {
      menu.defaultShowMenu(item as Show, context: context);
    } else if (item is ShowEpisode) {
      final episode = item as ShowEpisode;
      menu.defaultShowEpisodeMenu(
        episode.show ?? Show(name: 'Podcast', platformId: 'general'),
        episode,
        context: context,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    String resolvedTitle = title ?? '';
    String? resolvedSubtitle = subtitle;
    String? resolvedImage = imageUrl;
    bool resolvedIsArtist = isArtist ?? false;
    bool resolvedExplicit = explicit ?? false;
    int? resolvedVariation = variation;
    bool resolvedPinned = pinned ?? false;

    if (item is Album) {
      final a = item as Album;
      if (resolvedTitle.isEmpty) resolvedTitle = a.title ?? '';
      resolvedSubtitle ??= a.artistString?.isNotEmpty == true
          ? a.artistString
          : a.artists?.map((art) => art.name).whereType<String>().join(', ');
      resolvedImage ??= a.art?.full ?? a.art?.thumb;
      resolvedPinned = pinned ?? a.pinned;
    } else if (item is Track) {
      final t = item as Track;
      if (resolvedTitle.isEmpty) resolvedTitle = t.title ?? '';
      resolvedSubtitle ??= t.artistString ?? 'Song';
      resolvedImage ??= t.albumArt?.full ?? t.albumArt?.thumb;
      resolvedExplicit = explicit ?? (t.explicit ?? false);
      resolvedVariation ??= t.variation;
      resolvedPinned = pinned ?? t.pinned;
    } else if (item is Playlist) {
      final p = item as Playlist;
      if (resolvedTitle.isEmpty) resolvedTitle = p.title ?? '';
      resolvedSubtitle ??= '';
      resolvedImage ??= p.image?.full ?? p.image?.thumb;
      resolvedPinned = pinned ?? p.pinned;
    } else if (item is Artist) {
      final art = item as Artist;
      if (resolvedTitle.isEmpty) resolvedTitle = art.name ?? '';
      resolvedSubtitle ??= '';
      resolvedImage ??= art.picture?.full ?? art.picture?.thumb;
      resolvedIsArtist = isArtist ?? true;
      resolvedPinned = pinned ?? art.pinned;
      resolvedVariation ??= art.variation;
    } else if (item is Show) {
      final s = item as Show;
      if (resolvedTitle.isEmpty) resolvedTitle = s.name ?? '';
      resolvedSubtitle ??= s.creator ?? 'Podcast';
      resolvedImage ??= s.art?.full ?? s.art?.thumb;
      resolvedPinned = pinned ?? s.pinned;
    } else if (item is ShowEpisode) {
      final ep = item as ShowEpisode;
      if (resolvedTitle.isEmpty) resolvedTitle = ep.title ?? '';
      resolvedSubtitle ??= ep.show?.name ?? 'Podcast';
      resolvedImage ??= ep.art?.full ?? ep.art?.thumb ?? ep.show?.art?.full;
      resolvedPinned = pinned ?? ep.pinned;
    } else if (item is LiveRadio) {
      final r = item as LiveRadio;
      if (resolvedTitle.isEmpty) resolvedTitle = r.title ?? '';
      resolvedSubtitle ??= r.description?.isNotEmpty == true
          ? r.description
          : 'Live radio';
      resolvedImage ??= r.image?.full ?? r.image?.thumb;
      resolvedPinned = pinned ?? r.pinned;
    }

    final effectiveRadius = resolvedIsArtist
        ? BorderRadius.circular(1000)
        : (borderRadius ?? BorderRadius.circular(10));

    final tile = InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap ?? () => _defaultTap(context),
      onLongPress: onHold ?? () => _defaultHold(context),
      child: Column(
        crossAxisAlignment: resolvedIsArtist
            ? CrossAxisAlignment.center
            : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Artwork
          AspectRatio(
            aspectRatio: 1.0,
            child: ClipRRect(
              borderRadius: effectiveRadius,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    child: resolvedImage != null && resolvedImage.isNotEmpty
                        ? CachedImage(url: resolvedImage, fit: BoxFit.cover)
                        : Icon(
                            resolvedIsArtist ? Icons.person : Icons.album,
                            size: 48,
                            color: Theme.of(context).colorScheme.outline,
                          ),
                  ),
                  if (item is Track && (item as Track).unavailable == true)
                    Positioned.fill(
                      child: Container(
                        color: Colors.black45,
                        child: const Center(
                          child: Icon(
                            Icons.error_outline,
                            color: Colors.red,
                            size: 32.0,
                          ),
                        ),
                      ),
                    ),
                  if (resolvedPinned)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: const BoxDecoration(
                          color: Colors.black54,
                          shape: BoxShape.circle,
                        ),
                        child: Transform.rotate(
                          angle: 0.5,
                          child: const Icon(
                            Icons.push_pin,
                            color: Colors.white,
                            size: 13,
                          ),
                        ),
                      ),
                    ),
                  if (resolvedVariation != null)
                    Positioned(
                      left: 6,
                      bottom: 6,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(3),
                          child: Icon(
                            resolvedVariation > 0
                                ? Icons.arrow_upward
                                : resolvedVariation == 0
                                ? Icons.arrow_forward
                                : Icons.arrow_downward,
                            color: resolvedVariation > 0
                                ? Colors.greenAccent
                                : resolvedVariation == 0
                                ? Colors.white70
                                : Colors.orangeAccent,
                            size: 14,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6.0),
          // Title
          Text(
            resolvedTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: resolvedIsArtist ? TextAlign.center : TextAlign.start,
            style: const TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.1,
            ),
          ),
          // Subtitle
          if (resolvedSubtitle != null && resolvedSubtitle.isNotEmpty) ...[
            const SizedBox(height: 2.0),
            Row(
              mainAxisAlignment: resolvedIsArtist
                  ? MainAxisAlignment.center
                  : MainAxisAlignment.start,
              children: [
                if (resolvedExplicit)
                  Container(
                    margin: const EdgeInsets.only(right: 4.0),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 3,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.outlineVariant,
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: const Text(
                      'E',
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                Expanded(
                  child: Text(
                    resolvedSubtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: resolvedIsArtist
                        ? TextAlign.center
                        : TextAlign.start,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: Theme.of(
                        context,
                      ).textTheme.bodySmall?.color?.withValues(alpha: 0.7),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );

    if (item is Track && (item as Track).unavailable == true) {
      return Opacity(opacity: 0.5, child: tile);
    }
    return tile;
  }
}
