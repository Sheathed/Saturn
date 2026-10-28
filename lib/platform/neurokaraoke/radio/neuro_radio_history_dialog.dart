import 'package:material_ui/material_ui.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import 'package:silky_scroll/silky_scroll.dart';
import 'package:saturn/ui/smooth_scroll_config.dart';

import '../../../api/cache.dart';
import '../../../api/definitions.dart';
import '../../../platform/platform_manager.dart';
import '../../../service/audio_service.dart';
import '../../../ui/toast.dart';
import 'neuro_radio_service.dart';

final Logger _log = Logger('NeuroRadioHistoryDialog');

class NeuroRadioHistoryDialog extends StatefulWidget {
  final NeuroRadioService radio;

  const NeuroRadioHistoryDialog({super.key, required this.radio});

  static Future<void> show(BuildContext context, NeuroRadioService radio) {
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (context) => NeuroRadioHistoryDialog(radio: radio),
    );
  }

  @override
  State<NeuroRadioHistoryDialog> createState() =>
      _NeuroRadioHistoryDialogState();
}

class _NeuroRadioHistoryDialogState extends State<NeuroRadioHistoryDialog> {
  bool _isLoading = true;
  String? _errorMessage;
  List<Track> _history = [];

  @override
  void initState() {
    super.initState();
    final cached = widget.radio.latest?.state.history;
    if (cached != null && cached.isNotEmpty) {
      _history = List.from(cached);
      _isLoading = false;
    }
    _fetchHistory();
  }

  Future<void> _fetchHistory() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final items = await widget.radio.fetchHistory();
      if (!mounted) return;
      setState(() {
        _history = items;
        _isLoading = false;
      });
    } catch (e) {
      _log.warning('Failed to load station history: $e');
      if (!mounted) return;
      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }

  bool _isTrackFavorite(Track track) {
    final pid = track.platformId.isNotEmpty ? track.platformId : 'neurokaraoke';
    track.platformId = pid;
    if (track.favorite != null) {
      return track.favorite!;
    }
    return cache.checkTrackFavorite(track);
  }

  Future<void> _toggleFavorite(Track track) async {
    final trackId = track.id;
    if (trackId == null || trackId.isEmpty) return;

    final pid = track.platformId.isNotEmpty ? track.platformId : 'neurokaraoke';
    track.platformId = pid;

    final isFav = _isTrackFavorite(track);
    final newFav = !isFav;
    track.favorite = newFav;
    cache.updateTrackFavorite(track, favorite: newFav);
    setState(() {});

    try {
      final platform = PlatformManager.instance.getPlatform(pid);
      if (newFav) {
        await platform.addFavoriteTrack(trackId);
        Fluttertoast.showToast(
          msg: 'Added to favorites',
          backgroundColor: const Color(0xFF00695C),
          textColor: Colors.white,
        );
      } else {
        await platform.removeFavoriteTrack(trackId);
        Fluttertoast.showToast(
          msg: 'Removed from favorites',
          backgroundColor: Colors.grey[850],
          textColor: Colors.white,
        );
      }
      await cache.save();
    } catch (e) {
      _log.fine('Could not update favorite: $e');
    }
    if (mounted) setState(() {});
  }

  String _formatDuration(Duration? duration) {
    if (duration == null || duration == Duration.zero) return '';
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  Future<void> _playTrack(Track track) async {
    try {
      var trackToPlay = track;
      final details = trackToPlay.playbackDetails;
      final streamUrl = details != null && details.isNotEmpty
          ? details[0].toString()
          : '';
      if (streamUrl.isEmpty && track.id != null && track.id!.isNotEmpty) {
        try {
          final pid = track.platformId.isNotEmpty
              ? track.platformId
              : 'neurokaraoke';
          final platform = PlatformManager.instance.getPlatform(pid);
          final fetched = await platform.getTrack(track.id!);
          trackToPlay = fetched;
        } catch (e) {
          _log.fine('Could not fetch full track info: $e');
        }
      }

      final trackIndex = _history.indexOf(track);
      if (trackIndex != -1) {
        _history[trackIndex] = trackToPlay;
      }

      final playableQueue = _history
          .where(
            (t) => t.unavailable != true && t.id != null && t.id!.isNotEmpty,
          )
          .toList();

      final handler = GetIt.I<AudioPlayerHandler>();
      await handler.playFromTrackList(
        playableQueue.isNotEmpty ? playableQueue : [trackToPlay],
        trackToPlay.id ?? '',
        QueueSource(
          id: 'radio_history',
          text: 'Radio History',
          source: 'radio_history',
        ),
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      _log.warning('Could not play history track: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Dialog(
      backgroundColor:
          theme.dialogTheme.backgroundColor ??
          theme.colorScheme.surfaceContainerHigh,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: 480,
          maxHeight: 520,
          minWidth: 320,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Title Header
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 10, 8),
              child: Row(
                children: [
                  Icon(
                    Icons.history_rounded,
                    color: colorScheme.primary,
                    size: 22,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Station History',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          'Recently played on $kNeuroRadioStationName',
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 11,
                            color: theme.textTheme.bodySmall?.color?.withValues(
                              alpha: 0.7,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh_rounded, size: 20),
                    tooltip: 'Refresh',
                    visualDensity: VisualDensity.compact,
                    onPressed: _isLoading ? null : _fetchHistory,
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 20),
                    tooltip: 'Close',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),

            if (_isLoading)
              LinearProgressIndicator(minHeight: 2, color: colorScheme.primary),

            const Divider(height: 1),

            // Content Body
            Flexible(
              child: _history.isEmpty
                  ? (_isLoading
                        ? const Padding(
                            padding: EdgeInsets.symmetric(vertical: 36),
                            child: Center(child: CircularProgressIndicator()),
                          )
                        : _errorMessage != null
                        ? Padding(
                            padding: const EdgeInsets.all(20),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.error_outline_rounded,
                                  color: Colors.redAccent,
                                  size: 36,
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  'Could not load station history',
                                  style: theme.textTheme.titleSmall,
                                ),
                                const SizedBox(height: 12),
                                OutlinedButton.icon(
                                  onPressed: _fetchHistory,
                                  icon: const Icon(
                                    Icons.refresh_rounded,
                                    size: 16,
                                  ),
                                  label: const Text('Try Again'),
                                ),
                              ],
                            ),
                          )
                        : const Padding(
                            padding: EdgeInsets.all(28),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.history_rounded,
                                  size: 40,
                                  color: Colors.white38,
                                ),
                                SizedBox(height: 10),
                                Text(
                                  'No recently played songs recorded yet',
                                  style: TextStyle(
                                    color: Colors.white60,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          ))
                  : SilkyListView.separated(
                      silkyConfig: silkyScrollConfig,
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(6, 4, 6, 8),
                      itemCount: _history.length,
                      separatorBuilder: (context, index) =>
                          const Divider(height: 1, indent: 62),
                      itemBuilder: (context, index) {
                        final track = _history[index];
                        final artUrl =
                            track.albumArt?.fullUrl ??
                            track.albumArt?.thumbUrl ??
                            '';
                        final title = track.title ?? 'Unknown Track';
                        final artist = track.artistString ?? 'Unknown Artist';
                        final durationStr = _formatDuration(track.duration);
                        final canPlay =
                            track.unavailable != true &&
                            track.id != null &&
                            track.id!.isNotEmpty;

                        return ListTile(
                          dense: true,
                          visualDensity: VisualDensity.compact,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          leading: Opacity(
                            opacity: canPlay ? 1.0 : 0.6,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Container(
                                width: 42,
                                height: 42,
                                color: colorScheme.surfaceContainerHighest,
                                child: artUrl.isNotEmpty
                                    ? Image.network(
                                        artUrl,
                                        fit: BoxFit.cover,
                                        errorBuilder: (c, e, s) => const Icon(
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
                          ),
                          title: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 13.5,
                              color: canPlay
                                  ? null
                                  : theme.textTheme.bodyMedium?.color
                                        ?.withValues(alpha: 0.6),
                            ),
                          ),
                          subtitle: Text(
                            artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.textTheme.bodyMedium?.color
                                  ?.withValues(alpha: canPlay ? 0.7 : 0.4),
                            ),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (durationStr.isNotEmpty)
                                Text(
                                  durationStr,
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures(),
                                    ],
                                    color: theme.textTheme.bodySmall?.color
                                        ?.withValues(alpha: 0.6),
                                  ),
                                ),
                              if (canPlay) ...[
                                const SizedBox(width: 2),
                                IconButton(
                                  icon: Icon(
                                    _isTrackFavorite(track)
                                        ? Icons.favorite_rounded
                                        : Icons.favorite_border_rounded,
                                    color: _isTrackFavorite(track)
                                        ? Colors.white
                                        : Colors.white60,
                                    size: 19,
                                  ),
                                  visualDensity: VisualDensity.compact,
                                  tooltip: _isTrackFavorite(track)
                                      ? 'Remove from favorites'
                                      : 'Add to favorites',
                                  onPressed: () => _toggleFavorite(track),
                                ),
                                const SizedBox(width: 2),
                                IconButton(
                                  icon: const Icon(
                                    Icons.play_circle_filled_rounded,
                                    size: 26,
                                  ),
                                  visualDensity: VisualDensity.compact,
                                  tooltip: 'Play track',
                                  onPressed: () => _playTrack(track),
                                ),
                              ],
                            ],
                          ),
                          onTap: canPlay ? () => _playTrack(track) : null,
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
