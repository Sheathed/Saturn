import 'package:material_ui/material_ui.dart';
import 'package:saturn/ui/toast.dart';

import '../../api/definitions.dart';
import '../../ui/cached_image.dart';
import '../../ui/menu.dart';
import 'parsers/item_parsers.dart';
import 'youtube_music_speed_dial.dart';

/// Modern YTM Card Tile for Albums, Playlists, Artists, and Shows.
class YTMCardTile extends StatelessWidget {
  final dynamic item;
  final VoidCallback? onTap;
  final double width;
  final YouTubeMusicSpeedDialItem? listenAgainItem;
  final Future<void> Function(String token)? onSendFeedback;
  final VoidCallback? onRefreshNeeded;

  const YTMCardTile({
    super.key,
    required this.item,
    this.onTap,
    this.width = 155.0,
    this.listenAgainItem,
    this.onSendFeedback,
    this.onRefreshNeeded,
  });

  @override
  Widget build(BuildContext context) {
    String title = '';
    String? subtitle;
    String? imageUrl;
    bool isArtist = false;
    bool explicit = false;
    int? variation;
    final resolvedListenAgain =
        listenAgainItem ?? YouTubeMusicSpeedDialItem.fromDynamic(item);
    final hasListenAgainTokens =
        resolvedListenAgain?.hasListenAgainTokens == true;
    final modelPinned = switch (item) {
      Track value => value.pinned,
      Album value => value.pinned,
      Artist value => value.pinned,
      Playlist value => value.pinned,
      Show value => value.pinned,
      ShowEpisode value => value.pinned,
      LiveRadio value => value.pinned,
      _ => false,
    };
    final isPinnedToListenAgain = hasListenAgainTokens
        ? resolvedListenAgain!.isPinnedInYouTubeMusic
        : modelPinned;
    final listenAgainToken = isPinnedToListenAgain
        ? resolvedListenAgain?.unpinFeedbackToken
        : resolvedListenAgain?.pinFeedbackToken;

    if (item is Album) {
      final a = item as Album;
      title = a.title ?? '';
      subtitle =
          a.artists?.map((art) => art.name).whereType<String>().join(', ') ??
          'Album';
      if (a.releaseDate != null) subtitle = '$subtitle • ${a.releaseDate}';
      imageUrl = a.art?.full ?? a.art?.thumb;
    } else if (item is Track) {
      final t = item as Track;
      title = t.title ?? '';
      subtitle = t.artistString ?? 'Song';
      imageUrl = t.albumArt?.full ?? t.albumArt?.thumb;
      explicit = t.explicit ?? false;
      variation = t.variation;
    } else if (item is Playlist) {
      final p = item as Playlist;
      title = p.title ?? '';
      subtitle = p.user?.name ?? 'Playlist';
      imageUrl = p.image?.full ?? p.image?.thumb;
    } else if (item is Artist) {
      final art = item as Artist;
      title = art.name ?? '';
      subtitle = 'Artist';
      imageUrl = art.picture?.full ?? art.picture?.thumb;
      isArtist = true;
    } else if (item is Show) {
      final s = item as Show;
      title = s.name ?? '';
      subtitle = s.creator ?? 'Podcast';
      imageUrl = s.art?.full ?? s.art?.thumb;
    } else if (item is LiveRadio) {
      final r = item as LiveRadio;
      title = r.title ?? '';
      subtitle = r.description?.isNotEmpty == true
          ? r.description
          : 'Live radio';
      imageUrl = r.image?.full ?? r.image?.thumb;
    }

    final imageRadius = isArtist
        ? BorderRadius.circular(width / 2)
        : BorderRadius.circular(10);

    return Container(
      width: width,
      margin: const EdgeInsets.symmetric(horizontal: 6.0),
      child: Align(
        alignment: Alignment.topCenter,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            onLongPress: () => _showMenu(context),
            child: Column(
              crossAxisAlignment: isArtist
                  ? CrossAxisAlignment.center
                  : CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Artwork
                AspectRatio(
                  aspectRatio: 1.0,
                  child: ClipRRect(
                    borderRadius: imageRadius,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Container(
                          color: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHighest,
                          child: imageUrl != null && imageUrl.isNotEmpty
                              ? CachedImage(url: imageUrl, fit: BoxFit.cover)
                              : Icon(
                                  isArtist ? Icons.person : Icons.album,
                                  size: 48,
                                  color: Theme.of(context).colorScheme.outline,
                                ),
                        ),
                        if (isPinnedToListenAgain && listenAgainToken == null)
                          const Positioned(
                            top: 8,
                            right: 8,
                            child: Icon(
                              Icons.push_pin,
                              color: Colors.white,
                              shadows: [
                                Shadow(color: Colors.black87, blurRadius: 4),
                              ],
                            ),
                          ),
                        if (listenAgainToken != null && onSendFeedback != null)
                          Positioned(
                            top: 2,
                            right: 2,
                            child: Material(
                              color: Colors.black54,
                              shape: const CircleBorder(),
                              child: IconButton(
                                tooltip: isPinnedToListenAgain
                                    ? 'Unpin from Listen again'
                                    : 'Pin to Listen again',
                                constraints: const BoxConstraints.tightFor(
                                  width: 38,
                                  height: 38,
                                ),
                                padding: EdgeInsets.zero,
                                icon: Icon(
                                  isPinnedToListenAgain
                                      ? Icons.push_pin
                                      : Icons.push_pin_outlined,
                                  color: Colors.white,
                                  size: 19,
                                ),
                                onPressed: () =>
                                    _toggleListenAgain(resolvedListenAgain),
                              ),
                            ),
                          ),
                        if (variation != null)
                          Positioned(
                            left: 7,
                            bottom: 7,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(3),
                                child: Icon(
                                  variation > 0
                                      ? Icons.arrow_upward
                                      : variation == 0
                                      ? Icons.arrow_forward
                                      : Icons.arrow_downward,
                                  color: variation > 0
                                      ? Colors.greenAccent
                                      : variation == 0
                                      ? Colors.white70
                                      : Colors.orangeAccent,
                                  size: 16,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8.0),
                // Title
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: isArtist ? TextAlign.center : TextAlign.start,
                  style: const TextStyle(
                    fontSize: 14.0,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.1,
                  ),
                ),
                const SizedBox(height: 2.0),
                // Subtitle & Badges
                Row(
                  mainAxisAlignment: isArtist
                      ? MainAxisAlignment.center
                      : MainAxisAlignment.start,
                  children: [
                    if (explicit)
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
                    if (subtitle != null && subtitle.isNotEmpty)
                      Expanded(
                        child: Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: isArtist
                              ? TextAlign.center
                              : TextAlign.start,
                          style: TextStyle(
                            fontSize: 12.0,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _toggleListenAgain(YouTubeMusicSpeedDialItem? item) async {
    if (item == null) return;
    try {
      await YouTubeMusicSpeedDialManager.instance.togglePin(
        item,
        onSendFeedback: onSendFeedback,
      );
      onRefreshNeeded?.call();
    } catch (error) {
      Fluttertoast.showToast(msg: 'Could not update Listen again: $error');
    }
  }

  void _showMenu(BuildContext context) {
    final listenAgain = listenAgainItem;
    if (listenAgain != null) {
      YouTubeMusicParsers.updateListenAgainData(
        listenAgain.id,
        YouTubeMusicListenAgainData(
          isPinned: listenAgain.isPinnedInYouTubeMusic,
          pinFeedbackToken: listenAgain.pinFeedbackToken,
          unpinFeedbackToken: listenAgain.unpinFeedbackToken,
        ),
      );
    }
    final speedDialItem = YouTubeMusicSpeedDialItem.fromDynamic(item);
    final menu = MenuSheet();
    if (item is Track) {
      menu.defaultTrackMenu(item, context: context);
    } else if (item is Album) {
      menu.defaultAlbumMenu(item, context: context);
    } else if (item is Playlist) {
      menu.defaultPlaylistMenu(item, context: context);
    } else if (item is Artist) {
      menu.defaultArtistMenu(item, context: context);
    } else if (item is Show) {
      menu.defaultShowMenu(item, context: context);
    } else if (speedDialItem != null &&
        speedDialItem.hasListenAgainTokens &&
        onSendFeedback != null) {
      // Fallback for raw renderer items that do not have a Saturn model type.
      showModalBottomSheet(
        context: context,
        builder: (ctx) => SafeArea(
          child: ListTile(
            leading: Icon(
              speedDialItem.isPinnedInYouTubeMusic
                  ? Icons.push_pin_outlined
                  : Icons.push_pin,
            ),
            title: Text(
              speedDialItem.isPinnedInYouTubeMusic
                  ? 'Unpin from Listen again'
                  : 'Pin to Listen again',
            ),
            onTap: () async {
              Navigator.pop(ctx);
              try {
                await YouTubeMusicSpeedDialManager.instance.togglePin(
                  listenAgainItem ?? speedDialItem,
                  onSendFeedback: onSendFeedback,
                );
                onRefreshNeeded?.call();
              } catch (error) {
                Fluttertoast.showToast(
                  msg: 'Could not update Listen again: $error',
                );
              }
            },
          ),
        ),
      );
    }
  }
}

/// Compact horizontal song row tile used in 4-row Quick Picks grid (matching Metrolist YouTubeListItem).

/// Moods & Genres Navigation Card with colorful stripe (matching Metrolist MoodAndGenresButton).
class YTMMoodGenreCard extends StatelessWidget {
  final String title;
  final Color? stripeColor;
  final String? iconType;
  final bool showIcon;
  final VoidCallback? onTap;

  const YTMMoodGenreCard({
    super.key,
    required this.title,
    this.stripeColor,
    this.iconType,
    this.showIcon = true,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = stripeColor ?? theme.colorScheme.primary;
    final icon = switch (iconType) {
      'MUSIC_NEW_RELEASE' => Icons.new_releases_outlined,
      'TRENDING_UP' => Icons.trending_up,
      'STICKER_EMOTICON' => Icons.mood_outlined,
      'BROADCAST' => Icons.podcasts,
      _ => Icons.explore_outlined,
    };

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          height: 48,
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainer,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
              width: 0.8,
            ),
          ),
          child: Row(
            children: [
              // Left color stripe
              Container(
                width: 6,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(8),
                    bottomLeft: Radius.circular(8),
                  ),
                ),
              ),
              const SizedBox(width: 9),
              if (showIcon) ...[
                Icon(icon, size: 19, color: color),
                const SizedBox(width: 9),
              ],
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }
}

/// Podcast Episode Tile for 2-row multi-row carousel.
