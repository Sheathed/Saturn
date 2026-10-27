import 'package:material_ui/material_ui.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:silky_scroll/silky_scroll.dart';
import 'package:saturn/ui/smooth_scroll_config.dart';

import '../api/cache.dart';
import '../api/definitions.dart';
import '../api/download.dart';
import '../platform/music_platform.dart';
import '../platform/platform_capabilities.dart';
import '../platform/platform_manager.dart';
import '../platform/platform_registry.dart';
import '../service/audio_service.dart';
import '../translations.i18n.dart';
import 'cached_image.dart';
import 'elements.dart';
import 'error.dart';
import 'menu.dart';
import 'tiles.dart';
import '../utils/logging.dart';

class TrackDetails extends StatefulWidget {
  final Track track;
  const TrackDetails(this.track, {super.key});

  @override
  State<TrackDetails> createState() => _TrackDetailsState();
}

class _TrackDetailsState extends State<TrackDetails> {
  late Track _track;
  TrackPageData? _pageData;
  bool _loading = true;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _track = widget.track;
    _loadTrackData();
  }

  Future<void> _loadTrackData() async {
    setState(() {
      _loading = true;
      _error = false;
    });

    try {
      final pId = _track.platformId;
      final platform = PlatformManager.instance.getPlatform(pId);

      // Attempt to load rich track page data first
      final data = await platform.getTrackPageData(_track.id ?? '');
      if (data != null) {
        if (mounted) {
          setState(() {
            _pageData = data;
            _track = data.track;
            _loading = false;
          });
        }
        return;
      }

      // If getTrackPageData returned null, fetch track directly
      final fetchedTrack = await platform.getTrack(_track.id ?? '');
      if (mounted) {
        setState(() {
          _track = fetchedTrack;
          _pageData = TrackPageData(track: fetchedTrack);
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = true;
        });
      }
    }
  }

  ButtonStyle _saturnButtonStyle(BuildContext context) {
    return ButtonStyle(
      overlayColor: WidgetStateProperty.resolveWith<Color?>((
        Set<WidgetState> states,
      ) {
        if (states.contains(WidgetState.pressed)) {
          return Theme.of(context).primaryColor.withValues(alpha: 0.3);
        }
        return null;
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final capabilities = PlatformRegistry.instance
        .get(_track.platformId)
        ?.capabilities;

    return Scaffold(
      appBar: FreezerAppBar(
        _track.title ?? 'Track'.i18n,
        actions: [
          PlatformBadge(_track.platformId, iconOnly: true),
          IconButton(
            icon: const Icon(Icons.more_vert),
            onPressed: () {
              MenuSheet().defaultTrackMenu(_track, context: context);
            },
          ),
        ],
      ),
      body: _error
          ? const ErrorScreen()
          : _loading
          ? Center(
              child: CircularProgressIndicator(
                color: Theme.of(context).primaryColor,
              ),
            )
          : SilkyListView(
              silkyConfig: silkyScrollConfig,
              children: [
                _buildHeader(context, capabilities),
                ..._buildBodySections(context),
                const SizedBox(height: 32.0),
              ],
            ),
    );
  }

  Widget _buildHeader(
    BuildContext context,
    PlatformCapabilities? capabilities,
  ) {
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isWideScreen = constraints.maxWidth > 668;
          final imageSize = isWideScreen
              ? 250.0
              : MediaQuery.of(context).size.width * 0.5;

          final custom = _pageData?.custom ?? const {};
          final coverBy = custom['coverArtists'] as String?;
          final origBy = custom['originalArtists'] as String?;
          final setlist = custom['setlist'] as String?;
          final playCount = custom['playCount'] as int?;
          final artUrl = _track.albumArt?.full ?? _track.albumArt?.thumb ?? '';
          final artCredit = _track.albumArt?.caption;

          if (isWideScreen) {
            return Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ZoomableImage(
                    url: artUrl,
                    width: imageSize,
                    rounded: true,
                    caption: artCredit,
                  ),
                  const SizedBox(width: 24.0),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _track.title ?? '',
                          textAlign: TextAlign.left,
                          overflow: TextOverflow.ellipsis,
                          maxLines: 3,
                          style: const TextStyle(
                            fontSize: 24.0,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8.0),
                        Row(
                          children: [
                            Flexible(
                              child: ArtistLinksText(
                                artists: _track.displayArtists,
                                fallback: _track.artistString,
                                textAlign: TextAlign.left,
                                maxLines: 2,
                                style: TextStyle(
                                  fontSize: 18.0,
                                  color: Theme.of(context).primaryColor,
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (coverBy != null && coverBy.isNotEmpty) ...[
                          const SizedBox(height: 6.0),
                          Text(
                            'Cover by'.i18n + ' $coverBy',
                            textAlign: TextAlign.left,
                            style: TextStyle(
                              fontSize: 14.0,
                              color: Theme.of(context).disabledColor,
                            ),
                          ),
                        ],
                        if (origBy != null && origBy.isNotEmpty) ...[
                          const SizedBox(height: 4.0),
                          Text(
                            'Original by'.i18n + ' $origBy',
                            textAlign: TextAlign.left,
                            style: TextStyle(
                              fontSize: 14.0,
                              color: Theme.of(context).disabledColor,
                            ),
                          ),
                        ],
                        if (artCredit != null && artCredit.isNotEmpty) ...[
                          const SizedBox(height: 4.0),
                          Text(
                            'Artwork by'.i18n + ' $artCredit',
                            textAlign: TextAlign.left,
                            style: TextStyle(
                              fontSize: 14.0,
                              color: Theme.of(context).disabledColor,
                            ),
                          ),
                        ],
                        if (setlist != null && setlist.isNotEmpty) ...[
                          const SizedBox(height: 4.0),
                          Text(
                            setlist,
                            textAlign: TextAlign.left,
                            style: TextStyle(
                              fontSize: 14.0,
                              color: Theme.of(context).disabledColor,
                            ),
                          ),
                        ],
                        const SizedBox(height: 16.0),
                        Wrap(
                          spacing: 16.0,
                          runSpacing: 8.0,
                          children: [
                            if (_track.durationString != null)
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.timelapse,
                                    size: 20.0,
                                    semanticLabel: 'Duration'.i18n,
                                  ),
                                  const SizedBox(width: 6.0),
                                  Text(
                                    _track.durationString!,
                                    style: const TextStyle(
                                      fontSize: 14.0,
                                      fontFeatures: [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            if (playCount != null && playCount > 0)
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.play_circle_outline,
                                    size: 20.0,
                                  ),
                                  const SizedBox(width: 6.0),
                                  Text(
                                    '${NumberFormat.decimalPattern().format(playCount)} ' +
                                        'plays'.i18n,
                                    style: const TextStyle(fontSize: 14.0),
                                  ),
                                ],
                              ),
                            if (_track.explicit == true)
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4.0,
                                      vertical: 2.0,
                                    ),
                                    decoration: BoxDecoration(
                                      border: Border.all(
                                        color: Theme.of(context).disabledColor,
                                        width: 1.0,
                                      ),
                                      borderRadius: BorderRadius.circular(2.0),
                                    ),
                                    child: const Text(
                                      'E',
                                      style: TextStyle(
                                        fontSize: 10.0,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                          ],
                        ),
                        if (_track.unavailable == true)
                          Padding(
                            padding: const EdgeInsets.only(top: 6.0),
                            child: Text(
                              _track.unavailableMessage,
                              style: const TextStyle(
                                color: Colors.redAccent,
                                fontSize: 13.0,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        const SizedBox(height: 16.0),
                        _buildWideActionButtons(context, capabilities),
                      ],
                    ),
                  ),
                ],
              ),
            );
          } else {
            // Narrow mobile layout matching AlbumDetails
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 8.0),
                ZoomableImage(
                  url: artUrl,
                  width: imageSize,
                  rounded: true,
                  caption: artCredit,
                ),
                const SizedBox(height: 8.0),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: Text(
                    _track.title ?? '',
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 2,
                    style: const TextStyle(
                      fontSize: 20.0,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: ArtistLinksText(
                    artists: _track.displayArtists,
                    fallback: _track.artistString,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    style: TextStyle(
                      fontSize: 16.0,
                      color: Theme.of(context).primaryColor,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                if (_track.unavailable == true)
                  Padding(
                    padding: const EdgeInsets.only(top: 6.0),
                    child: Text(
                      _track.unavailableMessage,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.redAccent,
                        fontSize: 13.0,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                if (coverBy != null && coverBy.isNotEmpty) ...[
                  const SizedBox(height: 4.0),
                  Text(
                    'Cover by'.i18n + ' $coverBy',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13.0,
                      color: Theme.of(context).disabledColor,
                    ),
                  ),
                ],
                if (origBy != null && origBy.isNotEmpty) ...[
                  const SizedBox(height: 2.0),
                  Text(
                    'Original by'.i18n + ' $origBy',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13.0,
                      color: Theme.of(context).disabledColor,
                    ),
                  ),
                ],
                if (artCredit != null && artCredit.isNotEmpty) ...[
                  const SizedBox(height: 2.0),
                  Text(
                    'Artwork by'.i18n + ' $artCredit',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13.0,
                      color: Theme.of(context).disabledColor,
                    ),
                  ),
                ],
                if (setlist != null && setlist.isNotEmpty) ...[
                  const SizedBox(height: 4.0),
                  Text(
                    setlist,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13.0,
                      color: Theme.of(context).disabledColor,
                    ),
                  ),
                ],
                const FreezerDivider(),
                Row(
                  mainAxisSize: MainAxisSize.max,
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    if (_track.durationString != null)
                      Row(
                        children: [
                          Icon(
                            Icons.timelapse,
                            size: 28.0,
                            semanticLabel: 'Duration'.i18n,
                          ),
                          const SizedBox(width: 8.0),
                          Text(
                            _track.durationString!,
                            style: const TextStyle(
                              fontSize: 16.0,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ],
                      ),
                    if (playCount != null && playCount > 0)
                      Row(
                        children: [
                          const Icon(Icons.play_circle_outline, size: 28.0),
                          const SizedBox(width: 8.0),
                          Text(
                            '${NumberFormat.decimalPattern().format(playCount)} ' +
                                'plays'.i18n,
                            style: const TextStyle(fontSize: 16.0),
                          ),
                        ],
                      ),
                  ],
                ),
                const FreezerDivider(),
                _buildNarrowActionButtons(context, capabilities),
              ],
            );
          }
        },
      ),
    );
  }

  Widget _buildWideActionButtons(
    BuildContext context,
    PlatformCapabilities? capabilities,
  ) {
    final isFavorite = cache.checkTrackFavorite(_track);

    return Row(
      children: [
        TextButton.icon(
          style: _saturnButtonStyle(context),
          icon: const Icon(Icons.play_arrow, size: 20),
          label: Text('Play'.i18n),
          onPressed: () {
            if (_track.unavailable == true) {
              Fluttertoast.showToast(msg: _track.unavailableMessage);
              return;
            }
            GetIt.I<AudioPlayerHandler>().playFromTrackList(
              [_track],
              _track.id ?? '',
              QueueSource(
                id: _track.id ?? '',
                text: _track.title ?? '',
                source: 'track_page',
              ),
            );
          },
        ),
        if (capabilities?.supportsLibrarySync == true)
          TextButton.icon(
            style: _saturnButtonStyle(context),
            icon: Icon(
              isFavorite ? Icons.favorite : Icons.favorite_border,
              size: 20,
            ),
            label: Text('Library'.i18n),
            onPressed: () async {
              final trackId = _track.id ?? '';
              appLogger.info(
                '[UI] TrackDetails library pressed (wide): trackId=$trackId, platformId=${_track.platformId}, currentlyFavorite=$isFavorite',
              );
              final platform = PlatformManager.instance.getPlatform(
                _track.platformId,
              );
              cache.updateTrackFavorite(_track, favorite: !isFavorite);
              setState(() {});
              try {
                if (isFavorite) {
                  await platform.removeFavoriteTrack(trackId);
                  Fluttertoast.showToast(
                    msg: 'Track removed from library'.i18n,
                    toastLength: Toast.LENGTH_SHORT,
                    gravity: ToastGravity.BOTTOM,
                  );
                } else {
                  await platform.addFavoriteTrack(trackId);
                  Fluttertoast.showToast(
                    msg: 'Added to library'.i18n,
                    toastLength: Toast.LENGTH_SHORT,
                    gravity: ToastGravity.BOTTOM,
                  );
                }
              } catch (e, st) {
                appLogger.warning(
                  '[UI] TrackDetails error updating favorite: trackId=$trackId',
                  e,
                  st,
                );
                cache.updateTrackFavorite(_track, favorite: isFavorite);
                if (mounted) setState(() {});
                Fluttertoast.showToast(msg: 'Could not update favorite: $e');
              }
            },
          ),
        if (capabilities?.supportsDownload == true)
          MakeTrackOffline(track: _track, isWide: true),
        if (capabilities?.supportsDownload == true)
          TextButton.icon(
            style: _saturnButtonStyle(context),
            icon: const Icon(Icons.file_download, size: 20),
            label: Text('Download'.i18n),
            onPressed: () async {
              if (await downloadManager.addOfflineTrack(
                    _track,
                    private: false,
                  ) !=
                  false) {
                MenuSheet().showDownloadStartedToast();
              }
            },
          ),
        if (capabilities?.supportsSmartRadio == true)
          TextButton.icon(
            style: _saturnButtonStyle(context),
            icon: const Icon(Icons.radio, size: 20),
            label: Text('Radio'.i18n),
            onPressed: () async {
              GetIt.I<AudioPlayerHandler>().playMix(
                _track.id!,
                _track.title ?? '',
                platformId: _track.platformId,
                seedTrack: _track,
              );
            },
          ),
      ],
    );
  }

  Widget _buildNarrowActionButtons(
    BuildContext context,
    PlatformCapabilities? capabilities,
  ) {
    final isFavorite = cache.checkTrackFavorite(_track);

    return Row(
      mainAxisSize: MainAxisSize.max,
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        TextButton(
          style: _saturnButtonStyle(context),
          onPressed: () {
            if (_track.unavailable == true) {
              Fluttertoast.showToast(msg: _track.unavailableMessage);
              return;
            }
            GetIt.I<AudioPlayerHandler>().playFromTrackList(
              [_track],
              _track.id ?? '',
              QueueSource(
                id: _track.id ?? '',
                text: _track.title ?? '',
                source: 'track_page',
              ),
            );
          },
          child: Row(
            children: [
              const Icon(Icons.play_arrow, size: 32),
              Container(width: 4),
              Text('Play'.i18n),
            ],
          ),
        ),
        if (capabilities?.supportsLibrarySync == true)
          TextButton(
            style: _saturnButtonStyle(context),
            onPressed: () async {
              final trackId = _track.id ?? '';
              appLogger.info(
                '[UI] TrackDetails library pressed (compact): trackId=$trackId, platformId=${_track.platformId}, currentlyFavorite=$isFavorite',
              );
              final platform = PlatformManager.instance.getPlatform(
                _track.platformId,
              );
              cache.updateTrackFavorite(_track, favorite: !isFavorite);
              setState(() {});
              try {
                if (isFavorite) {
                  await platform.removeFavoriteTrack(trackId);
                  Fluttertoast.showToast(
                    msg: 'Track removed from library'.i18n,
                    toastLength: Toast.LENGTH_SHORT,
                    gravity: ToastGravity.BOTTOM,
                  );
                } else {
                  await platform.addFavoriteTrack(trackId);
                  Fluttertoast.showToast(
                    msg: 'Added to library'.i18n,
                    toastLength: Toast.LENGTH_SHORT,
                    gravity: ToastGravity.BOTTOM,
                  );
                }
              } catch (e, st) {
                appLogger.warning(
                  '[UI] TrackDetails error updating favorite: trackId=$trackId',
                  e,
                  st,
                );
                cache.updateTrackFavorite(_track, favorite: isFavorite);
                if (mounted) setState(() {});
                Fluttertoast.showToast(msg: 'Could not update favorite: $e');
              }
            },
            child: Row(
              children: [
                Icon(
                  isFavorite ? Icons.favorite : Icons.favorite_border,
                  size: 32,
                ),
                Container(width: 4),
                Text('Library'.i18n),
              ],
            ),
          ),
        if (capabilities?.supportsDownload == true)
          MakeTrackOffline(track: _track, isWide: false),
        if (capabilities?.supportsDownload == true)
          TextButton(
            style: _saturnButtonStyle(context),
            onPressed: () async {
              if (await downloadManager.addOfflineTrack(
                    _track,
                    private: false,
                  ) !=
                  false) {
                MenuSheet().showDownloadStartedToast();
              }
            },
            child: Row(
              children: [
                const Icon(Icons.file_download, size: 32),
                Container(width: 4),
                Text('Download'.i18n),
              ],
            ),
          ),
        if (capabilities?.supportsSmartRadio == true)
          TextButton(
            style: _saturnButtonStyle(context),
            onPressed: () async {
              GetIt.I<AudioPlayerHandler>().playMix(
                _track.id!,
                _track.title ?? '',
                platformId: _track.platformId,
                seedTrack: _track,
              );
            },
            child: Row(
              children: [
                const Icon(Icons.radio, size: 32),
                Container(width: 4),
                Text('Radio'.i18n),
              ],
            ),
          ),
      ],
    );
  }

  List<Widget> _buildBodySections(BuildContext context) {
    final platform = PlatformManager.instance.getPlatform(_track.platformId);
    final customSections = platform.buildTrackPageSections(
      context,
      _track,
      _pageData,
    );

    if (customSections.isNotEmpty) {
      return customSections.map((s) => s.builder(context)).toList();
    }

    final data = _pageData;
    if (data == null) return const [];

    final widgets = <Widget>[];

    // 1. Featured in Album
    if (data.album != null && data.album!.title?.isNotEmpty == true) {
      widgets.add(_buildFeaturedAlbumSection(context, data.album!));
    }

    // 2. Song Bio
    if (data.bio != null && data.bio!.isNotEmpty) {
      widgets.add(_buildSongBioSection(context, data.bio!));
    }

    // 3. Tags (Genres, Moods, Themes)
    if (data.chipGroups != null && data.chipGroups!.isNotEmpty) {
      widgets.add(_buildTagsSection(context, data.chipGroups!));
    }

    // 4. Community Rating
    if (data.rating != null && data.rating!.totalVotes > 0) {
      widgets.add(_buildRatingSection(context, data.rating!));
    }

    // 5. Details (Tempo, Key, Energy, Language, Occasion)
    if (data.details != null && data.details!.isNotEmpty) {
      widgets.add(_buildDetailsSection(context, data.details!));
    }

    // 6. Credits (Publishers, Writers, Composers)
    if (data.credits != null && data.credits!.isNotEmpty) {
      widgets.add(_buildCreditsSection(context, data.credits!));
    }

    // 7. Disclaimer
    if (data.disclaimer != null && data.disclaimer!.isNotEmpty) {
      widgets.add(
        _buildDisclaimerSection(
          context,
          data.disclaimer!,
          data.disclaimerUpdatedBy,
          data.disclaimerUpdatedDate,
        ),
      );
    }

    // 8. Lyrics
    if (data.lyrics != null &&
        ((data.lyrics!.syncedLyrics?.isNotEmpty ?? false) ||
            (data.lyrics!.unsyncedLyrics?.isNotEmpty ?? false))) {
      widgets.add(
        _buildLyricsSection(
          context,
          data.lyrics!,
          data.lyricsWriters,
          data.lyricsCopyright,
        ),
      );
    }

    // 9. Similar Songs
    if (data.similarTracks != null && data.similarTracks!.isNotEmpty) {
      widgets.add(_buildSimilarTracksSection(context, data.similarTracks!));
    }

    return widgets;
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: Text(
        title,
        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 20.0),
      ),
    );
  }

  Widget _buildFeaturedAlbumSection(BuildContext context, Album album) {
    final trackArtists = _track.displayArtists ?? _track.artists;
    final displayAlbum =
        (album.artists == null || album.artists!.isEmpty) &&
            (trackArtists != null && trackArtists.isNotEmpty)
        ? Album(
            id: album.id,
            title: album.title,
            art: album.art,
            releaseDate: album.releaseDate,
            artists: trackArtists,
            tracks: album.tracks,
            platformId: album.platformId,
          )
        : album;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const FreezerDivider(),
        _buildSectionTitle('Featured in'.i18n),
        AlbumTile(
          displayAlbum,
          onTap: () {
            if (displayAlbum.id != null && displayAlbum.id!.isNotEmpty) {
              context.push(
                '/album/${Uri.encodeComponent(displayAlbum.id!)}',
                extra: displayAlbum,
              );
            }
          },
        ),
      ],
    );
  }

  Widget _buildSongBioSection(BuildContext context, String bio) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const FreezerDivider(),
        _buildSectionTitle('Song Bio'.i18n),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
          child: Text(
            bio,
            style: TextStyle(
              fontSize: 15.0,
              height: 1.5,
              color: Theme.of(context).textTheme.bodyMedium?.color,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTagsSection(
    BuildContext context,
    List<TrackPageChipGroup> chipGroups,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const FreezerDivider(),
        _buildSectionTitle('Tags'.i18n),
        ...chipGroups.map((group) {
          return Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 16.0,
              vertical: 4.0,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  group.title.toUpperCase(),
                  style: TextStyle(
                    fontSize: 12.0,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                    color: Theme.of(context).disabledColor,
                  ),
                ),
                const SizedBox(height: 6.0),
                Wrap(
                  spacing: 6.0,
                  runSpacing: 6.0,
                  children: group.chips.map((chipText) {
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10.0,
                        vertical: 5.0,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).dividerColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(16.0),
                      ),
                      child: Text(
                        chipText,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 6.0),
              ],
            ),
          );
        }),
      ],
    );
  }

  Widget _buildRatingSection(
    BuildContext context,
    TrackCommunityRating rating,
  ) {
    final total = rating.totalVotes > 0 ? rating.totalVotes : 1;

    Widget buildBar(String emoji, String label, int count, Color color) {
      final double pct = (count / total).clamp(0.0, 1.0);
      final pctString = (pct * 100).toStringAsFixed(1);

      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4.0),
        child: Column(
          children: [
            Row(
              children: [
                Text(emoji, style: const TextStyle(fontSize: 14.0)),
                const SizedBox(width: 8.0),
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const Spacer(),
                Text(
                  '$count  $pctString%',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: Theme.of(context).disabledColor,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4.0),
            ClipRRect(
              borderRadius: BorderRadius.circular(4.0),
              child: LinearProgressIndicator(
                value: pct,
                minHeight: 6.0,
                backgroundColor: Theme.of(
                  context,
                ).dividerColor.withValues(alpha: 0.12),
                valueColor: AlwaysStoppedAnimation<Color>(color),
              ),
            ),
          ],
        ),
      );
    }

    String? formattedDate = rating.date;
    if (formattedDate != null) {
      try {
        final dt = DateTime.parse(formattedDate);
        formattedDate = DateFormat.yMMMMd().format(dt);
      } catch (_) {}
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const FreezerDivider(),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Community Rating'.i18n,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 20.0,
                ),
              ),
              Text(
                '${rating.totalVotes} ' + 'total votes'.i18n,
                style: TextStyle(
                  fontSize: 12.5,
                  color: Theme.of(context).disabledColor,
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (formattedDate != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8.0),
                  child: Text(
                    formattedDate,
                    style: TextStyle(
                      fontSize: 12.0,
                      color: Theme.of(context).disabledColor,
                    ),
                  ),
                ),
              buildBar(
                '🏆',
                'Masterpiece'.i18n,
                rating.masterpiece,
                const Color(0xFFBA68C8),
              ),
              buildBar(
                '⭐',
                'Amazing'.i18n,
                rating.amazing,
                const Color(0xFF64B5F6),
              ),
              buildBar('👍', 'Good'.i18n, rating.good, const Color(0xFF81C784)),
              buildBar('👎', 'Bad'.i18n, rating.bad, const Color(0xFFE57373)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDetailsSection(
    BuildContext context,
    Map<String, dynamic> details,
  ) {
    Widget buildRow(IconData icon, String label, dynamic value) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 6.0),
        child: Row(
          children: [
            Icon(icon, size: 18.0, color: Theme.of(context).disabledColor),
            const SizedBox(width: 12.0),
            Expanded(
              flex: 2,
              child: Text(
                label.i18n,
                style: TextStyle(
                  fontSize: 13.5,
                  color: Theme.of(context).disabledColor,
                ),
              ),
            ),
            Expanded(
              flex: 3,
              child: label == 'Energy' && value is num
                  ? Row(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(4.0),
                            child: LinearProgressIndicator(
                              value: (value / 10).clamp(0.0, 1.0),
                              minHeight: 6.0,
                              backgroundColor: Theme.of(
                                context,
                              ).dividerColor.withValues(alpha: 0.12),
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Theme.of(context).primaryColor,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8.0),
                        Text(
                          '$value/10',
                          style: const TextStyle(
                            fontSize: 13.0,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    )
                  : Text(
                      value.toString(),
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const FreezerDivider(),
        _buildSectionTitle('Details'.i18n),
        if (details.containsKey('Tempo'))
          buildRow(Icons.speed, 'Tempo', details['Tempo']),
        if (details.containsKey('Key'))
          buildRow(Icons.music_note, 'Key', details['Key']),
        if (details.containsKey('Energy'))
          buildRow(Icons.bolt, 'Energy', details['Energy']),
        if (details.containsKey('Language'))
          buildRow(Icons.language, 'Language', details['Language']),
        if (details.containsKey('Occasion'))
          buildRow(Icons.celebration, 'Occasion', details['Occasion']),
      ],
    );
  }

  Widget _buildCreditsSection(
    BuildContext context,
    Map<String, String> credits,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const FreezerDivider(),
        _buildSectionTitle('Credits'.i18n),
        ...credits.entries.map((entry) {
          return Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 16.0,
              vertical: 4.0,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.business,
                  size: 18.0,
                  color: Theme.of(context).disabledColor,
                ),
                const SizedBox(width: 12.0),
                Expanded(
                  flex: 2,
                  child: Text(
                    entry.key.i18n,
                    style: TextStyle(
                      fontSize: 13.5,
                      color: Theme.of(context).disabledColor,
                    ),
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: Text(
                    entry.value,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }

  Widget _buildDisclaimerSection(
    BuildContext context,
    String disclaimer,
    String? updatedBy,
    String? updatedDate,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const FreezerDivider(),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.info_outline,
                size: 18.0,
                color: Theme.of(context).disabledColor,
              ),
              const SizedBox(width: 8.0),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      disclaimer,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.4,
                        color: Theme.of(context).disabledColor,
                      ),
                    ),
                    if (updatedBy != null || updatedDate != null) ...[
                      const SizedBox(height: 4.0),
                      Text(
                        'Last edited by'.i18n +
                            ' ${updatedBy ?? ''}' +
                            (updatedDate != null ? ' on $updatedDate' : ''),
                        style: TextStyle(
                          fontSize: 11.0,
                          color: Theme.of(context).disabledColor,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildLyricsSection(
    BuildContext context,
    Lyrics lyrics,
    String? writers,
    String? copyright,
  ) {
    String textContent = '';
    final synced = lyrics.syncedLyrics;
    if (synced != null && synced.isNotEmpty) {
      textContent = synced.map((l) => l.text ?? '').join('\n');
    } else if (lyrics.unsyncedLyrics?.isNotEmpty == true) {
      textContent = lyrics.unsyncedLyrics!;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const FreezerDivider(),
        _buildSectionTitle('Lyrics'.i18n),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
          child: SelectableText(
            textContent,
            style: const TextStyle(
              fontSize: 15.0,
              height: 1.8,
              letterSpacing: 0.3,
            ),
          ),
        ),
        if (writers != null && writers.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 16.0,
              vertical: 4.0,
            ),
            child: Text(
              'Writers'.i18n + ': $writers',
              style: TextStyle(
                fontSize: 12.0,
                fontStyle: FontStyle.italic,
                color: Theme.of(context).disabledColor,
              ),
            ),
          ),
        ],
        if (copyright != null && copyright.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 16.0,
              vertical: 2.0,
            ),
            child: Text(
              copyright,
              style: TextStyle(
                fontSize: 11.0,
                color: Theme.of(context).disabledColor,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildSimilarTracksSection(BuildContext context, List<Track> tracks) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const FreezerDivider(),
        _buildSectionTitle('Similar Songs'.i18n),
        ...tracks.map(
          (t) => TrackTile(
            t,
            onTap: () {
              GetIt.I<AudioPlayerHandler>().playFromTrackList(
                tracks,
                t.id ?? '',
                QueueSource(
                  id: _track.id ?? '',
                  text: _track.title ?? '',
                  source: 'similar_tracks',
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class MakeTrackOffline extends StatefulWidget {
  final Track track;
  final bool isWide;
  const MakeTrackOffline({super.key, required this.track, this.isWide = true});

  @override
  State<MakeTrackOffline> createState() => _MakeTrackOfflineState();
}

class _MakeTrackOfflineState extends State<MakeTrackOffline> {
  bool _offline = false;

  @override
  void initState() {
    super.initState();
    downloadManager.checkOffline(track: widget.track).then((v) {
      if (mounted) setState(() => _offline = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final style = ButtonStyle(
      overlayColor: WidgetStateProperty.resolveWith<Color?>((
        Set<WidgetState> states,
      ) {
        if (states.contains(WidgetState.pressed)) {
          return Theme.of(context).primaryColor.withValues(alpha: 0.3);
        }
        return null;
      }),
    );

    if (widget.isWide) {
      return TextButton.icon(
        style: style,
        icon: Icon(_offline ? Icons.wifi_off : Icons.wifi, size: 20.0),
        label: Text('Offline'.i18n),
        onPressed: _toggleOffline,
      );
    } else {
      return TextButton(
        style: style,
        onPressed: _toggleOffline,
        child: Row(
          children: [
            Icon(_offline ? Icons.wifi_off : Icons.wifi, size: 32.0),
            Container(width: 4),
            Text('Offline'.i18n),
          ],
        ),
      );
    }
  }

  Future<void> _toggleOffline() async {
    if (!_offline) {
      await downloadManager.addOfflineTrack(widget.track, private: true);
      MenuSheet().showDownloadStartedToast();
      if (mounted) setState(() => _offline = true);
    } else {
      await downloadManager.removeOfflineTracks([widget.track]);
      if (mounted) setState(() => _offline = false);
    }
  }
}
