import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:get_it/get_it.dart';

import '../../../api/definitions.dart';
import '../../../service/audio_service.dart';
import '../../../ui/app_theme.dart';
import '../../../ui/cached_image.dart';
import 'neuro_radio_history_dialog.dart';
import 'neuro_radio_request_dialog.dart';
import 'neuro_radio_service.dart';

class NeuroRadioStationCard extends StatefulWidget {
  final NeuroRadioService radio;

  const NeuroRadioStationCard({super.key, required this.radio});

  @override
  State<NeuroRadioStationCard> createState() => _NeuroRadioStationCardState();
}

class _NeuroRadioStationCardState extends State<NeuroRadioStationCard> {
  StreamSubscription<NeuroRadioUpdate>? _updateSub;
  StreamSubscription<dynamic>? _playbackSub;
  StreamSubscription<dynamic>? _mediaItemSub;
  NeuroRadioUpdate? _update;
  late final Stream<String?> _stationChanges;
  late final Stream<bool> _playbackChanges;

  @override
  void initState() {
    super.initState();
    _update = widget.radio.latest;
    final handler = GetIt.I<AudioPlayerHandler>();
    // The card only needs playback rebuilds when its station or play state
    // changes, not for every position or radio metadata event.
    _stationChanges = handler.radioStateStream
        .map((state) => state?.stationId)
        .distinct();
    _playbackChanges = handler.playbackState
        .map((state) => state.playing)
        .distinct();
    _syncLiveSubscription();
    _playbackSub = _playbackChanges.listen((_) => _syncLiveSubscription());
    _mediaItemSub = handler.mediaItem
        .map((item) => item?.id)
        .distinct()
        .listen((_) => _syncLiveSubscription());
    if (_updateSub == null) _loadSnapshot();
  }

  bool get _isNeuroRadioPlaying {
    final handler = GetIt.I<AudioPlayerHandler>();
    return handler.playbackState.value.playing &&
        (handler.radioState?.stationId == kNeuroRadioStationId ||
            handler.mediaItem.value?.id == 'radio:$kNeuroRadioStationId');
  }

  void _syncLiveSubscription() {
    if (_isNeuroRadioPlaying) {
      if (_updateSub != null) return;
      _updateSub = widget.radio.updates.listen((update) {
        if (mounted) setState(() => _update = update);
      });
      return;
    }
    _updateSub?.cancel();
    _updateSub = null;
  }

  Future<void> _loadSnapshot() async {
    try {
      final state = await widget.radio.fetchCurrentState();
      if (!mounted || _isNeuroRadioPlaying || _updateSub != null) return;
      setState(() => _update = NeuroRadioUpdate(state));
    } catch (_) {
      // Keep the station card usable if the status endpoint is unavailable.
    }
  }

  @override
  void dispose() {
    _updateSub?.cancel();
    _playbackSub?.cancel();
    _mediaItemSub?.cancel();
    super.dispose();
  }

  Future<void> _togglePlayback(Track? track) async {
    final handler = GetIt.I<AudioPlayerHandler>();
    final isThisRadio =
        (handler.isRadio &&
            handler.radioState?.stationId == kNeuroRadioStationId) ||
        (handler.mediaItem.value?.id == 'radio:$kNeuroRadioStationId');

    if (isThisRadio) {
      if (handler.playbackState.value.playing) {
        await handler.pause();
      } else {
        await handler.play();
      }
    } else {
      await handler.playRadio(
        id: kNeuroRadioStationId,
        title: kNeuroRadioStationName,
        description: 'Live radio',
        artUrl: track?.albumArt?.fullUrl,
        platformId: 'neurokaraoke',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final legibleAccent = AppTheme.legibleAccent(
      colorScheme.primary,
      isDark: isDark,
    );
    final handler = GetIt.I<AudioPlayerHandler>();

    final actionButtonStyle = FilledButton.styleFrom(
      padding: const EdgeInsets.symmetric(
        horizontal: 12,
        vertical: 6,
      ),
      visualDensity: VisualDensity.compact,
      backgroundColor: colorScheme.primary.withValues(
        alpha: isDark ? 0.14 : 0.10,
      ),
      foregroundColor: legibleAccent,
      side: BorderSide(
        color: colorScheme.primary.withValues(
          alpha: isDark ? 0.35 : 0.25,
        ),
        width: 1,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
      ),
    );

    final actionIconButtonStyle = IconButton.styleFrom(
      visualDensity: VisualDensity.compact,
      backgroundColor: colorScheme.primary.withValues(
        alpha: isDark ? 0.14 : 0.10,
      ),
      foregroundColor: legibleAccent,
      side: BorderSide(
        color: colorScheme.primary.withValues(
          alpha: isDark ? 0.35 : 0.25,
        ),
        width: 1,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
      ),
    );

    final state = _update?.state;
    final current = state?.current;
    final isOffline = state?.offline ?? false;
    final listenerCount = state?.listenerCount ?? 0;
    final playlistName =
        (state?.playlistName != null && state!.playlistName!.isNotEmpty)
        ? state.playlistName!
        : 'Streaming Playlist';

    final trackTitle = current != null
        ? radioDisplayTitle(current)
        : (isOffline ? 'Station Offline' : 'Tuning in...');
    final artistName =
        current?.artistString ?? (isOffline ? 'Off Air' : 'Live stream');
    final artUrl =
        current?.albumArt?.fullUrl ??
        'https://www.neurokaraoke.com/img/nosource.png';

    return StreamBuilder<String?>(
      stream: _stationChanges,
      builder: (context, radioSnap) {
        return StreamBuilder(
          stream: _playbackChanges,
          builder: (context, playSnap) {
            final isPlayingThisRadio =
                ((handler.isRadio &&
                        handler.radioState?.stationId ==
                            kNeuroRadioStationId) ||
                    (handler.mediaItem.value?.id ==
                        'radio:$kNeuroRadioStationId')) &&
                handler.playbackState.value.playing;

            return Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 24.0,
                vertical: 12.0,
              ),
              child: Container(
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: colorScheme.outlineVariant.withValues(alpha: 0.3),
                  ),
                ),
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header Row: Station Name + Live badge + History & Request buttons
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final isCompact = constraints.maxWidth < 440;
                        final isVeryCompact = constraints.maxWidth < 360;

                        return Row(
                          children: [
                            // Station Name + Live indicator badge
                            Expanded(
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.sensors_rounded,
                                    color: isOffline
                                        ? Colors.grey
                                        : legibleAccent,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Text(
                                      kNeuroRadioStationName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.titleMedium
                                          ?.copyWith(
                                            fontWeight: FontWeight.bold,
                                            letterSpacing: 0.3,
                                          ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),

                                  // Live indicator badge
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 7,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: isOffline
                                          ? Colors.grey.withValues(alpha: 0.2)
                                          : Colors.redAccent.withValues(
                                              alpha: 0.18,
                                            ),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: isOffline
                                            ? Colors.grey.withValues(alpha: 0.4)
                                            : Colors.redAccent.withValues(
                                                alpha: 0.4,
                                              ),
                                        width: 1,
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Container(
                                          width: 7,
                                          height: 7,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: isOffline
                                                ? Colors.grey
                                                : Colors.redAccent,
                                          ),
                                        ),
                                        const SizedBox(width: 5),
                                        Text(
                                          isOffline
                                              ? 'OFFLINE'
                                              : isVeryCompact
                                              ? '$listenerCount'
                                              : '$listenerCount listening',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                            color: isOffline
                                                ? Colors.grey
                                                : Colors.redAccent,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),

                            const SizedBox(width: 8),

                            // Action buttons: History & Request
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (isCompact) ...[
                                  IconButton(
                                    icon: const Icon(
                                      Icons.history_rounded,
                                      size: 18,
                                    ),
                                    tooltip: 'Station History',
                                    style: actionIconButtonStyle,
                                    onPressed: () =>
                                        NeuroRadioHistoryDialog.show(
                                          context,
                                          widget.radio,
                                        ),
                                  ),
                                  const SizedBox(width: 6),
                                  IconButton(
                                    icon: const Icon(
                                      Icons.queue_music_rounded,
                                      size: 18,
                                    ),
                                    tooltip: 'Request a Song',
                                    style: actionIconButtonStyle,
                                    onPressed: () =>
                                        NeuroRadioRequestDialog.show(
                                          context,
                                          widget.radio,
                                        ),
                                  ),
                                ] else ...[
                                  FilledButton.icon(
                                    icon: const Icon(
                                      Icons.history_rounded,
                                      size: 16,
                                    ),
                                    label: const Text('History'),
                                    style: actionButtonStyle,
                                    onPressed: () =>
                                        NeuroRadioHistoryDialog.show(
                                          context,
                                          widget.radio,
                                        ),
                                  ),
                                  const SizedBox(width: 8),
                                  FilledButton.icon(
                                    icon: const Icon(
                                      Icons.queue_music_rounded,
                                      size: 16,
                                    ),
                                    label: const Text('Request'),
                                    style: actionButtonStyle,
                                    onPressed: () =>
                                        NeuroRadioRequestDialog.show(
                                          context,
                                          widget.radio,
                                        ),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        );
                      },
                    ),

                    const SizedBox(height: 16),

                    // Main Row: Album Art + Track Info + Play Button Column on the right
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // Album Art
                        ZoomableImage(
                          url: artUrl,
                          width: 100,
                          height: 100,
                          rounded: true,
                          caption: current?.albumArt?.caption,
                        ),

                        const SizedBox(width: 18),

                        // Track Title, Artist, & Playlist Tag
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                trackTitle,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 17,
                                  height: 1.25,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                artistName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.textTheme.bodyMedium?.color
                                      ?.withValues(alpha: 0.75),
                                ),
                              ),
                              const SizedBox(height: 10),

                              // Playlist tag chip
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 9,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: colorScheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.playlist_play_rounded,
                                      size: 14,
                                      color: legibleAccent,
                                    ),
                                    const SizedBox(width: 4),
                                    Flexible(
                                      child: Text(
                                        playlistName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                          color: colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(width: 16),

                        // Column on the right side with the Play Button
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            FilledButton(
                              onPressed: () => _togglePlayback(current),
                              style: FilledButton.styleFrom(
                                shape: const CircleBorder(),
                                padding: const EdgeInsets.all(16),
                                backgroundColor: colorScheme.primary,
                                foregroundColor: colorScheme.onPrimary,
                              ),
                              child: Icon(
                                isPlayingThisRadio
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                                size: 30,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),

                    // Up Next (Upcoming) Section
                    if (state?.upcoming.isNotEmpty == true) ...[
                      const SizedBox(height: 14),
                      Container(
                        height: 1,
                        color: colorScheme.outlineVariant.withValues(
                          alpha: 0.2,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Icon(
                            Icons.schedule_rounded,
                            size: 15,
                            color: legibleAccent,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'Up Next',
                            style: theme.textTheme.labelMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: legibleAccent,
                              letterSpacing: 0.3,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Builder(
                        builder: (context) {
                          final nextTrack = state!.upcoming.first;
                          final nextTitle = nextTrack.title ?? 'Unknown Track';
                          final nextArtist =
                              nextTrack.artistString ?? 'Unknown Artist';
                          final nextArt =
                              nextTrack.albumArt?.thumbUrl ??
                              nextTrack.albumArt?.fullUrl ??
                              '';
                          final duration = nextTrack.duration;
                          String durationStr = '';
                          if (duration != null && duration > Duration.zero) {
                            final m = duration.inMinutes;
                            final s = duration.inSeconds
                                .remainder(60)
                                .toString()
                                .padLeft(2, '0');
                            durationStr = '$m:$s';
                          }

                          return Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: colorScheme.surfaceContainerHighest
                                  .withValues(alpha: 0.4),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: colorScheme.outlineVariant.withValues(
                                  alpha: 0.2,
                                ),
                              ),
                            ),
                            child: Row(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: Container(
                                    width: 40,
                                    height: 40,
                                    color: colorScheme.surfaceContainerHighest,
                                    child: nextArt.isNotEmpty
                                        ? Image.network(
                                            nextArt,
                                            fit: BoxFit.cover,
                                            errorBuilder: (c, e, s) =>
                                                const Icon(
                                                  Icons.music_note_rounded,
                                                  size: 20,
                                                  color: Colors.white54,
                                                ),
                                          )
                                        : const Icon(
                                            Icons.music_note_rounded,
                                            size: 20,
                                            color: Colors.white54,
                                          ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        nextTitle,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.bodyMedium
                                            ?.copyWith(
                                              fontWeight: FontWeight.w600,
                                              fontSize: 13,
                                            ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        nextArtist,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              fontSize: 11,
                                              color: theme
                                                  .textTheme
                                                  .bodySmall
                                                  ?.color
                                                  ?.withValues(alpha: 0.7),
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (durationStr.isNotEmpty) ...[
                                  const SizedBox(width: 8),
                                  Text(
                                    durationStr,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontFeatures: const [
                                        FontFeature.tabularFigures(),
                                      ],
                                      color: theme.textTheme.bodySmall?.color
                                          ?.withValues(alpha: 0.6),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          );
                        },
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}
