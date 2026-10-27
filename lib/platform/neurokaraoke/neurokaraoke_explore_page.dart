import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:get_it/get_it.dart';
import '../../utils/logging.dart';
import '../../api/definitions.dart';
import '../../service/audio_service.dart';
import '../../ui/details_screens.dart';
import '../../ui/home_screen.dart';
import '../../platform/platform_manager.dart';
import '../../ui/mosaic_image.dart';
import '../../ui/tiles.dart';
import '../../ui/menu.dart';
import 'neurokaraoke_api.dart';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:silky_scroll/silky_scroll.dart';
import 'package:saturn/ui/smooth_scroll_config.dart';
import '../../ui/app_theme.dart';
import 'radio/neuro_radio_service.dart';
import 'radio/neuro_radio_station_card.dart';

class NeuroKaraokeExplorePage extends StatefulWidget {
  final NeuroKaraokeAPI api;
  final NeuroRadioService radio;
  const NeuroKaraokeExplorePage({
    super.key,
    required this.api,
    required this.radio,
  });

  @override
  State<NeuroKaraokeExplorePage> createState() =>
      _NeuroKaraokeExplorePageState();
}

class _NeuroKaraokeExplorePageState extends State<NeuroKaraokeExplorePage> {
  bool _loading = true;
  Playlist? _recent;
  List<Track> _suggestions = [];
  List<Track> _trending = [];
  CoverDistributionStats? _stats;
  List<GenreData> _genres = [];

  (List<String>, List<String?>) _mosaicForTracks(List<Track> tracks) {
    final urls = <String>[];
    final captions = <String?>[];
    final seen = <String>{};
    for (final track in tracks) {
      final url = track.albumArt?.fullUrl?.trim();
      if (url == null ||
          url.isEmpty ||
          url.contains('/img/nosource.png') ||
          !seen.add(url)) {
        continue;
      }
      urls.add(url);
      captions.add(track.albumArt?.caption);
      if (urls.length == 4) break;
    }
    return (urls, captions);
  }

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<String> _getCachePath() async {
    Directory d = await getApplicationSupportDirectory();
    return p.join(d.path, 'nk_explore_cache.json');
  }

  Future<void> _loadCache() async {
    try {
      final path = await _getCachePath();
      final file = File(path);
      if (await file.exists()) {
        final jsonStr = await file.readAsString();
        final data = jsonDecode(jsonStr);
        if (mounted) {
          setState(() {
            if (data['recent'] != null) {
              _recent = Playlist.fromJson(data['recent']);
            }
            if (data['suggestions'] != null) {
              _suggestions = (data['suggestions'] as List)
                  .map((e) => Track.fromJson(e))
                  .toList();
            }
            if (data['trending'] != null) {
              _trending = (data['trending'] as List)
                  .map((e) => Track.fromJson(e))
                  .toList();
            }
            if (data['stats'] != null) {
              _stats = CoverDistributionStats.fromJson(data['stats']);
            }
            if (data['genres'] != null) {
              _genres = (data['genres'] as List)
                  .map((e) => GenreData.fromJson(e))
                  .toList();
            }
            _loading = false;
          });
        }
      }
    } catch (e) {
      if (kDebugMode) {
        appLogger.fine('Failed to load cache', e);
      }
    }
  }

  Future<void> _saveCache() async {
    try {
      final path = await _getCachePath();
      final data = {
        'recent': _recent?.toJson(),
        'suggestions': _suggestions.map((e) => e.toJson()).toList(),
        'trending': _trending.map((e) => e.toJson()).toList(),
        'stats': _stats?.toJson(),
        'genres': _genres.map((e) => e.toJson()).toList(),
      };
      await File(path).writeAsString(jsonEncode(data));
    } catch (e) {
      if (kDebugMode) {
        appLogger.fine('Failed to save cache', e);
      }
    }
  }

  Future<void> _loadData() async {
    await _loadCache();

    final futures = <Future>[
      widget.api
          .getRecentSetlist()
          .then((v) => _recent = v)
          .catchError((_) => null),
      widget.api
          .getUserSuggestions()
          .then((v) => _suggestions = v)
          .catchError((_) => <Track>[]),
      widget.api
          .getTrending()
          .then((v) => _trending = v)
          .catchError((_) => <Track>[]),
      widget.api
          .getCoverDistribution()
          .then((v) => _stats = v)
          .catchError((_) => null),
      widget.api
          .getExploreGenres()
          .then((v) => _genres = v)
          .catchError((_) => <GenreData>[]),
    ];

    await Future.wait(futures);

    if (mounted) {
      setState(() {
        _loading = false;
      });
      _saveCache();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return SilkyListView(
      silkyConfig: silkyScrollConfig,
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        NeuroRadioStationCard(radio: widget.radio),

        if (_recent != null)
          _buildFeaturedList(
            context,
            'Recent Setlist',
            _recent!,
            _recent!.tracks ?? [],
          ),

        if (_suggestions.isNotEmpty)
          _buildFeaturedList(
            context,
            'Made for You',
            Playlist(
              id: 'made-for-you',
              title: 'Your mix',
              description:
                  'Personalized song recommendations based on your listening history',
              tracks: _suggestions,
              trackCount: _suggestions.length,
              image:
                  _suggestions.first.albumArt ??
                  ImageDetails(
                    fullUrl: 'https://www.neurokaraoke.com/img/nosource.png',
                  ),
              mosaicImages: _mosaicForTracks(_suggestions).$1,
              mosaicImageCaptions: _mosaicForTracks(_suggestions).$2,
              platformId: 'neurokaraoke',
            ),
            _suggestions,
          ),

        if (_trending.isNotEmpty)
          _buildFeaturedList(
            context,
            'Trending This Week',
            Playlist(
              id: 'trending',
              title: 'Trending This Week',
              description: 'The most played songs over the past 7 days',
              tracks: _trending,
              trackCount: _trending.length,
              image:
                  _trending.first.albumArt ??
                  ImageDetails(
                    fullUrl: 'https://www.neurokaraoke.com/img/nosource.png',
                  ),
              mosaicImages: _mosaicForTracks(_trending).$1,
              mosaicImageCaptions: _mosaicForTracks(_trending).$2,
              platformId: 'neurokaraoke',
            ),
            _trending,
          ),

        if (_stats != null || _genres.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 24.0,
              vertical: 16.0,
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                bool isWide = constraints.maxWidth > 800;
                final statsWidget = _stats != null
                    ? _buildStatsSection(context, _stats!)
                    : const SizedBox();
                final genresWidget = _genres.isNotEmpty
                    ? _buildGenresSection(context, _genres)
                    : const SizedBox();
                if (isWide) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: statsWidget),
                      const SizedBox(width: 32),
                      Expanded(child: genresWidget),
                    ],
                  );
                } else {
                  return Column(
                    children: [
                      statsWidget,
                      const SizedBox(height: 16),
                      genresWidget,
                    ],
                  );
                }
              },
            ),
          ),
      ],
    );
  }

  Widget _buildFeaturedList(
    BuildContext context,
    String title,
    Playlist playlist,
    List<Track> tracks,
  ) {
    if (tracks.isEmpty) return const SizedBox();

    return LayoutBuilder(
      builder: (context, constraints) {
        bool isWide = constraints.maxWidth > 800;

        Widget headerRow = Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                title,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  fontSize: 22,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Row(
              children: [
                if (title == 'Recent Setlist') ...[
                  TextButton.icon(
                    onPressed: () {},
                    icon: const Icon(Icons.download, size: 16),
                    label: const Text(
                      'Download Setlist',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) => HomePageScreen(
                            loadPage: () =>
                                PlatformManager.instance.active.getChannel(
                                  'public_playlists?startIndex=0&isSetlist=true',
                                ),
                          ),
                        ),
                      );
                    },
                    child: const Text(
                      'Show All Setlists',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ] else ...[
                  TextButton(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) => PlaylistDetails(
                            Playlist(
                              id: playlist.id,
                              title: playlist.title,
                              description: playlist.description,
                              image: playlist.image,
                              duration: playlist.duration,
                              trackCount: playlist.trackCount,
                              mosaicImages:
                                  playlist.mosaicImages ??
                                  tracks
                                      .take(4)
                                      .map((t) => t.albumArt?.fullUrl ?? '')
                                      .where((u) => u.isNotEmpty)
                                      .toList(),
                              mosaicImageCaptions: playlist.mosaicImageCaptions,
                              disableDownload: true,
                              tracks: null,
                              platformId: playlist.platformId,
                            ),
                          ),
                        ),
                      );
                    },
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        Text(
                          'See All',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SizedBox(width: 4),
                        Icon(Icons.arrow_forward, size: 16),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ],
        );

        final heroWidget = GestureDetector(
          onTap: () {
            if (title == 'Recent Setlist') {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => PlaylistDetails(playlist),
                ),
              );
            } else {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => PlaylistDetails(
                    Playlist(
                      id: playlist.id,
                      title: playlist.title,
                      description: playlist.description,
                      image: playlist.image,
                      duration: playlist.duration,
                      trackCount: playlist.trackCount,
                      mosaicImages:
                          playlist.mosaicImages ??
                          tracks
                              .take(4)
                              .map((t) => t.albumArt?.fullUrl ?? '')
                              .where((u) => u.isNotEmpty)
                              .toList(),
                      mosaicImageCaptions: playlist.mosaicImageCaptions,
                      disableDownload: true,
                      tracks: null,
                      platformId: playlist.platformId,
                    ),
                  ),
                ),
              );
            }
          },
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: MosaicImage(
                      urls:
                          playlist.mosaicImages ??
                          tracks
                              .take(4)
                              .map((t) => t.albumArt?.fullUrl ?? '')
                              .where((u) => u.isNotEmpty)
                              .toList(),
                      captions: playlist.mosaicImageCaptions,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  playlist.title ?? '',
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                if (playlist.description != null)
                  Text(
                    playlist.description!,
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: Colors.grey),
                  ),
                const SizedBox(height: 8),
                if (title == 'Recent Setlist')
                  Builder(
                    builder: (context) {
                      int totalSeconds = tracks.fold(
                        0,
                        (sum, t) => sum + (t.duration?.inSeconds ?? 0),
                      );
                      int totalMinutes = (totalSeconds / 60).round();
                      int displayMinutes =
                          playlist.duration != null &&
                              playlist.duration!.inMinutes > 0
                          ? playlist.duration!.inMinutes
                          : totalMinutes;

                      return Row(
                        children: [
                          const Icon(
                            Icons.music_note,
                            size: 14,
                            color: Colors.grey,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '${playlist.trackCount ?? tracks.length} songs',
                            style: Theme.of(
                              context,
                            ).textTheme.bodySmall?.copyWith(color: Colors.grey),
                          ),
                          if (displayMinutes > 0) ...[
                            const Text(
                              ' • ',
                              style: TextStyle(color: Colors.grey),
                            ),
                            Text(
                              '$displayMinutes min',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: Colors.grey),
                            ),
                          ],
                        ],
                      );
                    },
                  ),
              ],
            ),
          ),
        );

        final listWidget = SilkyListView.builder(
          silkyConfig: silkyScrollConfig,
          shrinkWrap: true,
          physics: isWide
              ? ScrollConfiguration.of(context).getScrollPhysics(context)
              : const NeverScrollableScrollPhysics(),
          itemCount: tracks.length,
          itemBuilder: (context, index) {
            final track = tracks[index];
            return TrackTile(
              track,
              onTap: () {
                GetIt.I<AudioPlayerHandler>().playFromPlaylist(
                  playlist,
                  track.id!,
                );
              },
              onHold: () {
                MenuSheet m = MenuSheet();
                m.defaultTrackMenu(track, context: context);
              },
            );
          },
        );

        final constrainedListWidget = isWide
            ? ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 450),
                child: listWidget,
              )
            : listWidget;

        if (isWide) {
          return Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 24.0,
              vertical: 24.0,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                headerRow,
                const SizedBox(height: 24),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 1, child: heroWidget),
                    const SizedBox(width: 32),
                    Expanded(flex: 3, child: constrainedListWidget),
                  ],
                ),
              ],
            ),
          );
        } else {
          return Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                headerRow,
                const SizedBox(height: 16),
                constrainedListWidget,
                const SizedBox(height: 24),
                heroWidget,
              ],
            ),
          );
        }
      },
    );
  }

  Widget _buildGenresSection(BuildContext context, List<GenreData> genres) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final onSurface = theme.colorScheme.onSurface;
    final cardBorder = theme.colorScheme.outlineVariant;
    final tagBg = isDark
        ? Colors.white.withValues(alpha: 0.03)
        : Colors.black.withValues(alpha: 0.04);
    final countColor = AppTheme.legibleAccent(
      Colors.purpleAccent,
      isDark: isDark,
    );

    return Container(
      padding: const EdgeInsets.all(24.0),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Top Genres',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 24),
          Wrap(
            spacing: 12.0,
            runSpacing: 12.0,
            children: genres.map((genre) {
              return Container(
                width: 180,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: tagBg,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        genre.name,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: onSurface,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      genre.songCount.toString(),
                      style: TextStyle(
                        fontSize: 12,
                        color: countColor,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsSection(
    BuildContext context,
    CoverDistributionStats stats,
  ) {
    final theme = Theme.of(context);
    final cardBorder = theme.colorScheme.outlineVariant;
    int total = stats.totalSongs;
    return Container(
      padding: const EdgeInsets.all(24.0),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Cover Distribution',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                total.toString(),
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          _buildProgressBar(
            context,
            'Neuro V3',
            stats.neuroCount,
            total,
            Colors.cyan,
          ),
          const SizedBox(height: 12),
          _buildProgressBar(
            context,
            'Evil',
            stats.evilCount,
            total,
            Colors.pink,
          ),
          const SizedBox(height: 12),
          _buildProgressBar(
            context,
            'Duet',
            stats.duetCount,
            total,
            Colors.purpleAccent,
          ),
          const SizedBox(height: 12),
          _buildProgressBar(
            context,
            'Other',
            stats.otherCount,
            total,
            Colors.grey,
          ),
        ],
      ),
    );
  }

  Widget _buildProgressBar(
    BuildContext context,
    String label,
    int count,
    int total,
    Color color,
  ) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final onSurfaceVariant = theme.colorScheme.onSurfaceVariant;
    final onSurface = theme.colorScheme.onSurface;
    final trackBg = isDark ? Colors.white10 : Colors.black12;
    double progress = total > 0 ? count / total : 0;
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: TextStyle(fontSize: 12, color: onSurfaceVariant),
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              backgroundColor: trackBg,
              valueColor: AlwaysStoppedAnimation<Color>(color),
              minHeight: 4,
            ),
          ),
        ),
        const SizedBox(width: 16),
        SizedBox(
          width: 40,
          child: Text(
            count.toString(),
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: onSurface,
            ),
          ),
        ),
      ],
    );
  }
}
