import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fluttericon/font_awesome5_icons.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:logging/logging.dart';
import 'package:saturn/settings.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:silky_scroll/silky_scroll.dart';
import 'package:saturn/ui/smooth_scroll_config.dart';

import '../api/cache.dart';
import '../platform/music_platform.dart';
import '../platform/platform_manager.dart';
import '../platform/platform_registry.dart';
import '../api/definitions.dart';
import '../api/download.dart';
import 'login_screen.dart';
import '../service/audio_service.dart';
import 'toast.dart';
import '../translations.i18n.dart';
import '../ui/details_screens.dart';
import '../ui/elements.dart';
import '../ui/error.dart';
import '../ui/tiles.dart';
import '../ui/local_playlists.dart';
import 'menu.dart';
import '../utils/logging.dart';
import 'mobile_scrollbar.dart';

class _LibraryEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;

  const _LibraryEmptyState({
    required this.icon,
    required this.title,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitle = this.subtitle;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: theme.colorScheme.primary),
            const SizedBox(height: 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 8),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class LibraryAppBar extends StatelessWidget implements PreferredSizeWidget {
  const LibraryAppBar({super.key});

  @override
  Size get preferredSize => AppBar().preferredSize;

  @override
  Widget build(BuildContext context) {
    return FreezerAppBar(
      'Library'.i18n,
      actions: <Widget>[
        IconButton(
          icon: Icon(Icons.file_download, semanticLabel: 'Download'.i18n),
          onPressed: () {
            context.push('/downloads');
          },
        ),
        IconButton(
          icon: const UpdateAwareSettingsIcon(),
          onPressed: () {
            context.push('/settings');
          },
        ),
        const PlatformToggleIcon(),
      ],
    );
  }
}

class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const LibraryAppBar(),
      body: SilkyListView(
        silkyConfig: silkyScrollConfig,
        children: <Widget>[
          Container(height: 4.0),
          if (!downloadManager.running && downloadManager.queueSize > 0)
            ListTile(
              title: Text('Downloads'.i18n),
              leading: const LeadingIcon(
                Icons.file_download,
                color: Colors.grey,
              ),
              subtitle: Text(
                'Downloading is currently stopped, click here to resume.'.i18n,
              ),
              onTap: () {
                downloadManager.start();
                context.push('/downloads');
              },
            ),
          ListTile(
            title: Text('Shuffle'.i18n),
            leading: const LeadingIcon(Icons.shuffle, color: Color(0xffeca704)),
            onTap: () async {
              List<Track> tracks = await PlatformManager.instance.active
                  .getLibraryShuffle();
              GetIt.I<AudioPlayerHandler>().playFromTrackList(
                tracks,
                tracks[0].id!,
                QueueSource(
                  id: 'libraryshuffle',
                  source: 'libraryshuffle',
                  text: 'Library shuffle'.i18n,
                ),
              );
            },
          ),
          const FreezerDivider(),
          if (PlatformManager.instance.active.capabilities.supportsLibrarySync)
            ListTile(
              title: Text('Tracks'.i18n),
              leading: const LeadingIcon(
                Icons.audiotrack,
                color: Color(0xffbe3266),
              ),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => const LibraryTracks(),
                  ),
                );
              },
            ),
          if (PlatformManager.instance.active.capabilities.supportsAlbums)
            ListTile(
              title: Text('Albums'.i18n),
              leading: const LeadingIcon(Icons.album, color: Color(0xff4b2e7e)),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => const LibraryAlbums(),
                  ),
                );
              },
            ),
          if (PlatformManager.instance.active.capabilities.supportsArtists)
            ListTile(
              title: Text('Artists'.i18n),
              leading: const LeadingIcon(
                Icons.recent_actors,
                color: Color(0xff384697),
              ),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => const LibraryArtists(),
                  ),
                );
              },
            ),
          ListTile(
            title: Text('Playlists'.i18n),
            leading: const LeadingIcon(
              Icons.playlist_play,
              color: Color(0xff0880b5),
            ),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => const LibraryPlaylists(),
                ),
              );
            },
          ),
          if (PlatformManager.instance.active.capabilities.supportsShows)
            ListTile(
              title: Text('Podcasts'.i18n),
              leading: const LeadingIcon(
                Icons.podcasts,
                color: Color.fromARGB(255, 181, 8, 172),
              ),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (context) => const LibraryShows()),
                );
              },
            ),
          const FreezerDivider(),
          ListTile(
            title: Text('History'.i18n),
            leading: const LeadingIcon(Icons.history, color: Color(0xff009a85)),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (context) => const HistoryScreen()),
              );
            },
          ),
          const FreezerDivider(),
          ExpansionTile(
            title: Text('Statistics'.i18n),
            leading: const LeadingIcon(Icons.insert_chart, color: Colors.grey),
            textColor: Theme.of(context).primaryColor,
            iconColor: Theme.of(context).primaryColor,
            children: <Widget>[
              FutureBuilder(
                future: downloadManager.getStats(),
                builder: (context, snapshot) {
                  if (snapshot.hasError) return const ErrorScreen();
                  if (!snapshot.hasData) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4.0),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: <Widget>[
                          CircularProgressIndicator(
                            color: Theme.of(context).primaryColor,
                          ),
                        ],
                      ),
                    );
                  }
                  List<String> data = snapshot.data!;
                  return Column(
                    children: <Widget>[
                      ListTile(
                        title: Text('Offline tracks'.i18n),
                        leading: const Icon(Icons.audiotrack),
                        trailing: Text(data[0]),
                      ),
                      ListTile(
                        title: Text('Offline albums'.i18n),
                        leading: const Icon(Icons.album),
                        trailing: Text(data[1]),
                      ),
                      ListTile(
                        title: Text('Local Playlists'.i18n),
                        leading: const Icon(Icons.playlist_add),
                        trailing: Text(data[2]),
                      ),
                      ListTile(
                        title: Text('Offline size'.i18n),
                        leading: const Icon(Icons.sd_card),
                        trailing: Text(data[3]),
                      ),
                      ListTile(
                        title: Text('Free space'.i18n),
                        leading: const Icon(Icons.disc_full),
                        trailing: Text(data[4]),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class LibraryTracks extends StatefulWidget {
  const LibraryTracks({super.key});

  @override
  _LibraryTracksState createState() => _LibraryTracksState();
}

class _LibraryTracksState extends State<LibraryTracks> {
  bool _loading = false;
  bool _loadingAllOffline = true;
  final ScrollController _scrollController = ScrollController();
  List<Track> tracks = [];
  List<Track> allTracks = [];
  int? trackCount;
  Sorting _sort = Sorting(sourceType: SortSourceTypes.TRACKS);
  int _sortVersion = 0;

  Playlist get _playlist => Playlist(
    id: 'favorites_${PlatformManager.instance.active.platformId}',
    title: 'Favorites'.i18n,
    tracks: tracks,
    trackCount: tracks.length,
    platformId: PlatformManager.instance.active.platformId,
  );

  Future _reverse() async {
    if (mounted) {
      setState(() {
        _sort.reverse = !_sort.reverse;
        _sortVersion++;
        tracks.clear();
        trackCount = null;
      });
    }
    //Save sorting in cache
    int? index = Sorting.index(SortSourceTypes.TRACKS);
    if (index != null) {
      cache.sorts[index] = _sort;
    } else {
      cache.sorts.add(_sort);
    }
    await cache.save();
    _load();
  }

  Future _load() async {
    if (_loading) return;
    _loading = true;
    final version = _sortVersion;

    //Already loaded
    if (trackCount != null && (tracks.length >= (trackCount ?? 0))) {
      if (cache.activeLibraryTracks.length != trackCount) {
        if (mounted) {
          setState(() {
            cache.activeLibraryTracks = tracks.map((t) => t.id!).toList();
          });
          await cache.save();
        }
      }
      _loading = false;
      return;
    }

    List<ConnectivityResult> connectivity = await Connectivity()
        .checkConnectivity();
    if (connectivity.isNotEmpty &&
        !connectivity.contains(ConnectivityResult.none)) {
      if (mounted) setState(() {});

      PaginatedTrackList? page;
      final platform = PlatformManager.instance.active;
      final start = tracks.length;
      try {
        page = await platform.getFavoriteTracks(
          start: start,
          limit: 100,
          sort: _sort,
        );
      } catch (error, stackTrace) {
        appLogger.warning(
          'Failed to load favorite tracks page: platform=${platform.platformId}, '
          'start=$start, limit=100, sort=${_sort.type}, reverse=${_sort.reverse}',
          error,
          stackTrace,
        );
      }
      //On error load offline
      if (page == null) {
        if (version != _sortVersion) {
          _loading = false;
          _load();
          return;
        }
        // Keep already loaded online favorites if a later page request fails.
        // Replacing the list with the offline-only library here made tracks
        // disappear during scroll pagination when that local list was empty.
        if (tracks.isEmpty) await _loadOffline();
        _loading = false;
        return;
      }
      if (version != _sortVersion) {
        _loading = false;
        _load();
        return;
      }
      if (mounted) {
        setState(() {
          tracks.addAll(page!.tracks);
          if (page.hasMore) {
            trackCount = tracks.length + 1;
          } else {
            trackCount = tracks.length;
          }
          _makeFavorite();
          final platformId = PlatformManager.instance.active.platformId;
          final ids = tracks
              .map((track) => track.id)
              .whereType<String>()
              .toList();
          if (page.hasMore) {
            final cached = cache.platformLibraryTracks.putIfAbsent(
              platformId,
              () => <String>[],
            );
            for (final id in ids) {
              if (!cached.contains(id)) cached.add(id);
            }
          } else {
            cache.platformLibraryTracks[platformId] = ids;
          }
          _loading = false;
        });
        await cache.save();
      } else {
        _loading = false;
      }
    } else {
      await _loadOffline();
      _loading = false;
    }
  }

  Future _loadOffline() async {
    Playlist? p = await downloadManager.getOfflinePlaylist(
      'favorites_${PlatformManager.instance.active.platformId}',
      platformId: PlatformManager.instance.active.platformId,
    );
    if (mounted) {
      setState(() {
        tracks = p?.tracks ?? [];
      });
    }
  }

  Future _loadAllOffline() async {
    List<Track> tracks = [];
    try {
      tracks = await downloadManager.allOfflineTracks();
    } catch (error, stackTrace) {
      appLogger.warning('Failed to load offline tracks', error, stackTrace);
    }
    if (!mounted) return;
    setState(() {
      allTracks = tracks;
      _loadingAllOffline = false;
    });
  }

  //Update tracks with favorite true
  void _makeFavorite() {
    for (int i = 0; i < tracks.length; i++) {
      tracks[i].favorite = true;
    }
  }

  @override
  void initState() {
    // Restore the requested order before the first network page is fetched.
    int? index = Sorting.index(SortSourceTypes.TRACKS);
    if (index != null) _sort = cache.sorts[index];
    _load();
    //Load all offline tracks
    _loadAllOffline();

    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: FreezerAppBar(
        'Tracks'.i18n,
        actions: [
          IconButton(
            icon: Icon(
              _sort.reverse
                  ? FontAwesome5.sort_alpha_up
                  : FontAwesome5.sort_alpha_down,
              semanticLabel: _sort.reverse
                  ? 'Sort descending'.i18n
                  : 'Sort ascending'.i18n,
            ),
            onPressed: () async {
              await _reverse();
            },
          ),
          PopupMenuButton(
            color: Theme.of(context).scaffoldBackgroundColor,
            onSelected: (SortType s) async {
              if (mounted) {
                setState(() {
                  _sort.type = s;
                  _sortVersion++;
                  tracks.clear();
                  trackCount = null;
                });
              }
              //Save sorting in cache
              int? index = Sorting.index(SortSourceTypes.TRACKS);
              if (index != null) {
                cache.sorts[index] = _sort;
              } else {
                cache.sorts.add(_sort);
              }
              await cache.save();
              _load();
            },
            itemBuilder: (context) => <PopupMenuEntry<SortType>>[
              PopupMenuItem(
                value: SortType.DEFAULT,
                child: Text('Default'.i18n, style: popupMenuTextStyle()),
              ),
              PopupMenuItem(
                value: SortType.ALPHABETIC,
                child: Text('Alphabetic'.i18n, style: popupMenuTextStyle()),
              ),
              PopupMenuItem(
                value: SortType.ARTIST,
                child: Text('Artist'.i18n, style: popupMenuTextStyle()),
              ),
            ],
            child: Icon(Icons.sort, size: 32.0, semanticLabel: 'Sort'.i18n),
          ),
          Container(width: 8.0),
        ],
      ),
      body: MobileScrollbar(
        controller: _scrollController,
        backgroundColor: Theme.of(context).primaryColor,
        childBuilder: (scrollController, scrollPhysics) => ListView(
          controller: scrollController,
          physics: scrollPhysics,
          children: <Widget>[
            Row(
              mainAxisSize: MainAxisSize.max,
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: <Widget>[
                MakePlaylistOffline(_playlist, size: 32.0),
                TextButton(
                  style: ButtonStyle(
                    overlayColor: WidgetStateProperty.resolveWith<Color?>((
                      Set<WidgetState> states,
                    ) {
                      if (states.contains(WidgetState.pressed)) {
                        return Theme.of(
                          context,
                        ).primaryColor.withValues(alpha: 0.3);
                      }
                      return null;
                    }),
                  ),
                  child: Row(
                    children: <Widget>[
                      const Icon(Icons.file_download, size: 32.0),
                      Container(width: 4),
                      Text('Download'.i18n),
                    ],
                  ),
                  onPressed: () async {
                    if (await downloadManager.addOfflinePlaylist(
                          _playlist,
                          private: false,
                        ) !=
                        false) {
                      MenuSheet().showDownloadStartedToast();
                    }
                  },
                ),
              ],
            ),
            const FreezerDivider(),
            //Loved tracks
            ...List.generate(tracks.length, (i) {
              Track t = tracks[i];
              return TrackTile(
                t,
                key: Key('track_${t.id}'),
                onTap: () {
                  GetIt.I<AudioPlayerHandler>().playFromTrackList(
                    tracks,
                    t.id!,
                    (PlatformManager.instance.active.favoritesQueueSource
                      ..sort = _sort),
                  );
                },
                onHold: () {
                  MenuSheet m = MenuSheet();
                  m.defaultTrackMenu(
                    t,
                    context: context,
                    onRemove: () {
                      setState(() {
                        tracks.removeWhere((track) => t.id == track.id);
                      });
                    },
                  );
                },
              );
            }),
            if (trackCount != null && tracks.length < trackCount!)
              VisibilityDetector(
                key: ValueKey('favorite-tracks-page-${tracks.length}'),
                onVisibilityChanged: (info) {
                  if (info.visibleFraction > 0 && !_loading) {
                    _load();
                  }
                },
                child: const SizedBox(height: 1),
              ),
            if (_loading)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8.0),
                    child: CircularProgressIndicator(
                      color: Theme.of(context).primaryColor,
                    ),
                  ),
                ],
              ),
            if (tracks.isEmpty &&
                allTracks.isEmpty &&
                !_loading &&
                !_loadingAllOffline)
              SizedBox(
                height: 230,
                child: _LibraryEmptyState(
                  icon: Icons.music_note_rounded,
                  title: 'No tracks in your library yet'.i18n,
                  subtitle: 'Add items to your library to see them here.'.i18n,
                ),
              ),
            const FreezerDivider(),
            Text(
              'All offline tracks'.i18n,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            Container(height: 8),
            ...List.generate(allTracks.length, (i) {
              Track t = allTracks[i];
              return TrackTile(
                t,
                showPlatformBadge: true,
                key: Key('offline_track_${t.id}'),
                onTap: () {
                  GetIt.I<AudioPlayerHandler>().playFromTrackList(
                    allTracks,
                    t.id!,
                    QueueSource(
                      id: 'allTracks',
                      text: 'All offline tracks'.i18n,
                      source: 'offline',
                    ),
                  );
                },
                onHold: () {
                  MenuSheet m = MenuSheet();
                  m.defaultTrackMenu(t, context: context);
                },
              );
            }),
          ],
        ),
      ),
    );
  }
}

class LibraryAlbums extends StatefulWidget {
  const LibraryAlbums({super.key});

  @override
  _LibraryAlbumsState createState() => _LibraryAlbumsState();
}

class _LibraryAlbumsState extends State<LibraryAlbums> {
  List<Album>? _albums;
  Sorting _sort = Sorting(sourceType: SortSourceTypes.ALBUMS);
  final ScrollController _scrollController = ScrollController();

  List<Album> get _sorted {
    List<Album> albums = List.from(_albums ?? []);
    if (albums.isNotEmpty) {
      if (!PlatformManager.instance.active.capabilities.preservesLibraryOrder &&
          albums.every((album) => album.favoriteDate != null)) {
        albums.sort((a, b) => a.favoriteDate!.compareTo(b.favoriteDate!));
      }
      switch (_sort.type) {
        case SortType.DEFAULT:
          break;
        case SortType.ALPHABETIC:
          albums.sort(
            (a, b) => (a.title ?? '').toLowerCase().compareTo(
              (b.title ?? '').toLowerCase(),
            ),
          );
          break;
        case SortType.ARTIST:
          albums.sort(
            (a, b) => (a.artists?.firstOrNull?.name ?? '')
                .toLowerCase()
                .compareTo((b.artists?.firstOrNull?.name ?? '').toLowerCase()),
          );
          break;
        case SortType.RELEASE_DATE:
          albums.sort((a, b) {
            final left = DateTime.tryParse(a.releaseDate ?? '');
            final right = DateTime.tryParse(b.releaseDate ?? '');
            if (left == null) return right == null ? 0 : 1;
            if (right == null) return -1;
            return left.compareTo(right);
          });
          break;
        default:
          break;
      }
    }
    //Reverse
    if (_sort.reverse) return albums.reversed.toList();
    return albums;
  }

  Future _load() async {
    if (settings.offlineMode) return;
    try {
      List<Album> albums = await PlatformManager.instance.active
          .getUserAlbums();
      if (mounted) setState(() => _albums = albums);
    } catch (e) {
      Logger.root.severe('Error loading albums: $e', StackTrace);
    }
  }

  @override
  void initState() {
    _load();
    //Load sorting
    int? index = Sorting.index(SortSourceTypes.ALBUMS);
    if (index != null) {
      _sort = cache.sorts[index];
    }

    super.initState();
  }

  Future _reverse() async {
    setState(() => _sort.reverse = !_sort.reverse);
    //Save sorting in cache
    int? index = Sorting.index(SortSourceTypes.ALBUMS);
    if (index != null) {
      cache.sorts[index] = _sort;
    } else {
      cache.sorts.add(_sort);
    }
    await cache.save();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: FreezerAppBar(
        'Albums'.i18n,
        actions: [
          IconButton(
            icon: Icon(
              _sort.reverse
                  ? FontAwesome5.sort_alpha_up
                  : FontAwesome5.sort_alpha_down,
              semanticLabel: _sort.reverse
                  ? 'Sort descending'.i18n
                  : 'Sort ascending'.i18n,
            ),
            onPressed: () => _reverse(),
          ),
          PopupMenuButton(
            color: Theme.of(context).scaffoldBackgroundColor,
            child: const Icon(Icons.sort, size: 32.0),
            onSelected: (SortType s) async {
              setState(() {
                _sort.type = s;
              });
              //Save to cache
              int? index = Sorting.index(SortSourceTypes.ALBUMS);
              if (index == null) {
                cache.sorts.add(_sort);
              } else {
                cache.sorts[index] = _sort;
              }
              await cache.save();
              await _load();
            },
            itemBuilder: (context) => <PopupMenuEntry<SortType>>[
              PopupMenuItem(
                value: SortType.DEFAULT,
                child: Text('Default'.i18n, style: popupMenuTextStyle()),
              ),
              PopupMenuItem(
                value: SortType.ALPHABETIC,
                child: Text('Alphabetic'.i18n, style: popupMenuTextStyle()),
              ),
              PopupMenuItem(
                value: SortType.ARTIST,
                child: Text('Artist'.i18n, style: popupMenuTextStyle()),
              ),
              PopupMenuItem(
                value: SortType.RELEASE_DATE,
                child: Text('Release date'.i18n, style: popupMenuTextStyle()),
              ),
            ],
          ),
          Container(width: 8.0),
        ],
      ),
      body: MobileScrollbar(
        controller: _scrollController,
        backgroundColor: Theme.of(context).primaryColor,
        childBuilder: (scrollController, scrollPhysics) => ListView(
          controller: scrollController,
          physics: scrollPhysics,
          children: <Widget>[
            Container(height: 8.0),
            if (!settings.offlineMode && _albums == null)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  CircularProgressIndicator(
                    color: Theme.of(context).primaryColor,
                  ),
                ],
              ),
            if (_albums != null)
              Builder(
                builder: (context) {
                  final sortedAlbums = _sorted;
                  if (sortedAlbums.isEmpty) {
                    return const SizedBox.shrink();
                  }
                  if (MediaQuery.sizeOf(context).width >= 960) {
                    return ResponsiveMediaGrid.builder(
                      itemCount: sortedAlbums.length,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      extraTextHeight: 70,
                      itemBuilder: (context, i) {
                        final album = sortedAlbums[i];
                        return LayoutBuilder(
                          builder: (context, constraints) => AlbumCard(
                            album,
                            width: constraints.maxWidth,
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (context) => AlbumDetails(album),
                              ),
                            ),
                            onHold: () => MenuSheet().defaultAlbumMenu(
                              album,
                              context: context,
                              onRemove: () =>
                                  setState(() => _albums?.remove(album)),
                            ),
                          ),
                        );
                      },
                    );
                  }
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: List.generate(sortedAlbums.length, (int i) {
                      Album a = sortedAlbums[i];
                      return AlbumTile(
                        a,
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (context) => AlbumDetails(a),
                            ),
                          );
                        },
                        onHold: () async {
                          MenuSheet m = MenuSheet();
                          m.defaultAlbumMenu(
                            a,
                            context: context,
                            onRemove: () {
                              setState(() => _albums?.remove(a));
                            },
                          );
                        },
                      );
                    }),
                  );
                },
              ),
            FutureBuilder(
              future: downloadManager.getOfflineAlbums(),
              builder: (context, snapshot) {
                if (snapshot.hasError || !snapshot.hasData) {
                  return const SizedBox(height: 0, width: 0);
                }
                if (snapshot.data!.isEmpty) {
                  if (settings.offlineMode || _albums?.isEmpty == true) {
                    return SizedBox(
                      height: 230,
                      child: _LibraryEmptyState(
                        icon: Icons.album_rounded,
                        title: 'No albums in your library yet'.i18n,
                        subtitle:
                            'Add items to your library to see them here.'.i18n,
                      ),
                    );
                  }
                  return const SizedBox.shrink();
                }

                List<Album> albums = snapshot.data!;
                return Column(
                  children: <Widget>[
                    const FreezerDivider(),
                    Text(
                      'Offline albums'.i18n,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 24.0,
                      ),
                    ),
                    if (MediaQuery.sizeOf(context).width >= 960)
                      ResponsiveMediaGrid.builder(
                        itemCount: albums.length,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemBuilder: (context, i) {
                          final album = albums[i];
                          return LayoutBuilder(
                            builder: (context, constraints) => AlbumCard(
                              album,
                              width: constraints.maxWidth,
                              showPlatformBadge: true,
                              onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (context) => AlbumDetails(album),
                                ),
                              ),
                              onHold: () => MenuSheet().defaultAlbumMenu(
                                album,
                                context: context,
                                onRemove: () => setState(() {
                                  albums.remove(album);
                                  _albums?.remove(album);
                                }),
                              ),
                            ),
                          );
                        },
                      )
                    else
                      ...List.generate(albums.length, (i) {
                        final album = albums[i];
                        return AlbumTile(
                          album,
                          showPlatformBadge: true,
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (context) => AlbumDetails(album),
                            ),
                          ),
                          onHold: () => MenuSheet().defaultAlbumMenu(
                            album,
                            context: context,
                            onRemove: () => setState(() {
                              albums.remove(album);
                              _albums?.remove(album);
                            }),
                          ),
                        );
                      }),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class LibraryArtists extends StatefulWidget {
  const LibraryArtists({super.key});

  @override
  _LibraryArtistsState createState() => _LibraryArtistsState();
}

class _LibraryArtistsState extends State<LibraryArtists> {
  List<Artist> _artists = [];
  Sorting _sort = Sorting(sourceType: SortSourceTypes.ARTISTS);
  bool _loading = true;
  bool _error = false;
  final ScrollController _scrollController = ScrollController();

  List<Artist> get _sorted {
    List<Artist> artists = List.from(_artists);
    if (artists.isNotEmpty) {
      if (!PlatformManager.instance.active.capabilities.preservesLibraryOrder &&
          artists.every((artist) => artist.favoriteDate != null)) {
        artists.sort((a, b) => a.favoriteDate!.compareTo(b.favoriteDate!));
      }
      switch (_sort.type) {
        case SortType.DEFAULT:
          break;
        case SortType.POPULARITY:
          artists.sort((a, b) => (b.fans ?? 0) - (a.fans ?? 0));
          break;
        case SortType.ALPHABETIC:
          artists.sort(
            (a, b) => (a.name ?? '').toLowerCase().compareTo(
              (b.name ?? '').toLowerCase(),
            ),
          );
          break;
        default:
          break;
      }
    }
    //Reverse
    if (_sort.reverse) return artists.reversed.toList();
    return artists;
  }

  //Load data
  Future _load() async {
    if (mounted) setState(() => _loading = true);
    //Fetch
    List<Artist>? data;
    try {
      data = await PlatformManager.instance.active.getUserArtists();
    } catch (e) {
      if (kDebugMode) {
        appLogger.fine('Library item loading failed', e);
      }
    }
    //Update UI
    if (mounted) {
      setState(() {
        if (data != null) {
          _artists = data;
        } else {
          _error = true;
        }
        _loading = false;
      });
    }
  }

  Future _reverse() async {
    setState(() => _sort.reverse = !_sort.reverse);
    //Save sorting in cache
    int? index = Sorting.index(SortSourceTypes.ARTISTS);
    if (index != null) {
      cache.sorts[index] = _sort;
    } else {
      cache.sorts.add(_sort);
    }
    await cache.save();
  }

  @override
  void initState() {
    //Restore sort
    int? index = Sorting.index(SortSourceTypes.ARTISTS);
    if (index != null) {
      _sort = cache.sorts[index];
    }

    _load();
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: FreezerAppBar(
        'Artists'.i18n,
        actions: [
          IconButton(
            icon: Icon(
              _sort.reverse
                  ? FontAwesome5.sort_alpha_up
                  : FontAwesome5.sort_alpha_down,
              semanticLabel: _sort.reverse
                  ? 'Sort descending'.i18n
                  : 'Sort ascending'.i18n,
            ),
            onPressed: () => _reverse(),
          ),
          PopupMenuButton(
            color: Theme.of(context).scaffoldBackgroundColor,
            onSelected: (SortType s) async {
              setState(() => _sort.type = s);
              //Save
              int? index = Sorting.index(SortSourceTypes.ARTISTS);
              if (index == null) {
                cache.sorts.add(_sort);
              } else {
                cache.sorts[index] = _sort;
              }
              await cache.save();
            },
            itemBuilder: (context) => <PopupMenuEntry<SortType>>[
              PopupMenuItem(
                value: SortType.DEFAULT,
                child: Text('Default'.i18n, style: popupMenuTextStyle()),
              ),
              PopupMenuItem(
                value: SortType.ALPHABETIC,
                child: Text('Alphabetic'.i18n, style: popupMenuTextStyle()),
              ),
              PopupMenuItem(
                value: SortType.POPULARITY,
                child: Text('Popularity'.i18n, style: popupMenuTextStyle()),
              ),
            ],
            child: const Icon(Icons.sort, size: 32.0),
          ),
          Container(width: 8.0),
        ],
      ),
      body: MobileScrollbar(
        controller: _scrollController,
        backgroundColor: Theme.of(context).primaryColor,
        childBuilder: (scrollController, scrollPhysics) => ListView(
          controller: scrollController,
          physics: scrollPhysics,
          children: <Widget>[
            if (_loading)
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(
                      color: Theme.of(context).primaryColor,
                    ),
                  ],
                ),
              ),
            if (_error) const Center(child: ErrorScreen()),
            if (!_loading && !_error)
              Builder(
                builder: (context) {
                  final sortedArtists = _sorted;
                  if (sortedArtists.isEmpty) {
                    return SizedBox(
                      height: 230,
                      child: _LibraryEmptyState(
                        icon: Icons.people_alt_rounded,
                        title: 'No artists in your library yet'.i18n,
                        subtitle:
                            'Add items to your library to see them here.'.i18n,
                      ),
                    );
                  }
                  if (MediaQuery.sizeOf(context).width >= 960) {
                    return ResponsiveMediaGrid.builder(
                      itemCount: sortedArtists.length,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      extraTextHeight: 58,
                      itemBuilder: (context, i) {
                        final artist = sortedArtists[i];
                        return LayoutBuilder(
                          builder: (context, constraints) => ArtistTile(
                            artist,
                            width: constraints.maxWidth,
                            onTap: () {
                              if (artist.id != null) {
                                context.push(
                                  '/artist/${Uri.encodeComponent(artist.id!)}',
                                  extra: artist,
                                );
                              }
                            },
                            onHold: () => MenuSheet().defaultArtistMenu(
                              artist,
                              context: context,
                              onRemove: () =>
                                  setState(() => _artists.remove(artist)),
                            ),
                          ),
                        );
                      },
                    );
                  }
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: List.generate(sortedArtists.length, (i) {
                      Artist a = sortedArtists[i];
                      return ArtistHorizontalTile(
                        a,
                        onTap: () {
                          if (a.id != null) {
                            context.push(
                              '/artist/${Uri.encodeComponent(a.id!)}',
                              extra: a,
                            );
                          }
                        },
                        onHold: () {
                          MenuSheet m = MenuSheet();
                          m.defaultArtistMenu(
                            a,
                            context: context,
                            onRemove: () {
                              setState(() {
                                _artists.remove(a);
                              });
                            },
                          );
                        },
                      );
                    }),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

class CreatePlaylistGridCard extends StatelessWidget {
  final VoidCallback onTap;

  const CreatePlaylistGridCard({required this.onTap, super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => PlaylistActionCard(
        title: 'Create new playlist'.i18n,
        icon: Icons.playlist_add,
        width: constraints.maxWidth,
        onTap: onTap,
      ),
    );
  }
}

class LibraryPlaylists extends StatefulWidget {
  const LibraryPlaylists({super.key});

  @override
  _LibraryPlaylistsState createState() => _LibraryPlaylistsState();
}

class _LibraryPlaylistsState extends State<LibraryPlaylists> {
  List<Playlist>? _playlists;
  bool _hasLocalOfflinePlaylists = true;
  bool _hasMorePlaylists = false;
  bool _loadingPlaylistPage = false;
  int _playlistRequestGeneration = 0;
  Sorting _sort = Sorting(sourceType: SortSourceTypes.PLAYLISTS);
  final ScrollController _scrollController = ScrollController();
  StreamSubscription<void>? _offlineLibrarySub;
  late Future<List<Playlist>> _offlinePlaylistsFuture;
  String _filter = '';
  Timer? _filterDebounce;

  void _onFilterChanged(String value) {
    setState(() {
      _filter = value;
      _playlists = [];
      _hasMorePlaylists = false;
      _loadingPlaylistPage = false;
      _playlistRequestGeneration++;
    });
    _filterDebounce?.cancel();
    _filterDebounce = Timer(const Duration(milliseconds: 300), () => _load());
  }

  Future<void> _load({bool reset = true}) async {
    if (!reset && _loadingPlaylistPage) return;
    final requestGeneration = reset
        ? ++_playlistRequestGeneration
        : _playlistRequestGeneration;
    final platform = PlatformManager.instance.active;
    final start = reset ? 0 : (_playlists?.length ?? 0);
    if (!mounted) return;
    setState(() {
      _loadingPlaylistPage = true;
      if (reset) {
        _playlists = settings.offlineMode ? [] : null;
        _hasMorePlaylists = false;
      }
    });

    if (settings.offlineMode) {
      try {
        final offlinePlaylists = await downloadManager.getOfflinePlaylists();
        if (!mounted || requestGeneration != _playlistRequestGeneration) return;
        final sorted = offlinePlaylists
            .where((playlist) => playlist.platformId == platform.platformId)
            .toList()
            .applyPlaylistSorting(_sort, query: _filter);
        setState(() {
          _playlists = sorted;
          _hasMorePlaylists = false;
          _loadingPlaylistPage = false;
        });
      } catch (error, stackTrace) {
        Logger.root.severe('Error loading offline playlists: $error', error, stackTrace);
        if (!mounted || requestGeneration != _playlistRequestGeneration) return;
        setState(() {
          _playlists = [];
          _hasMorePlaylists = false;
          _loadingPlaylistPage = false;
        });
      }
      return;
    }

    try {
      final page = await platform.getUserPlaylistsPage(
        start: start,
        limit: 100,
        sort: _sort,
        query: _filter,
        refresh: reset,
      );
      if (!mounted || requestGeneration != _playlistRequestGeneration) return;
      setState(() {
        _playlists = reset
            ? page.playlists
            : [...?_playlists, ...page.playlists];
        _hasMorePlaylists = page.hasMore;
        _loadingPlaylistPage = false;
      });
    } catch (error, stackTrace) {
      Logger.root.severe('Error loading playlists: $error', error, stackTrace);
      if (!mounted || requestGeneration != _playlistRequestGeneration) return;
      setState(() {
        _playlists = reset ? [] : _playlists;
        _hasMorePlaylists = false;
        _loadingPlaylistPage = false;
      });
    }
  }

  Future _reverse() async {
    setState(() => _sort.reverse = !_sort.reverse);
    //Save sorting in cache
    int? index = Sorting.index(SortSourceTypes.PLAYLISTS);
    if (index != null) {
      cache.sorts[index] = _sort;
    } else {
      cache.sorts.add(_sort);
    }
    await cache.save();
    await _load();
  }

  Future<void> _createPlaylist() async {
    if (settings.offlineMode) {
      Fluttertoast.showToast(
        msg: 'Cannot create playlists in offline mode'.i18n,
        gravity: ToastGravity.BOTTOM,
      );
      return;
    }
    await MenuSheet().createPlaylist(context);
    await _load();
  }

  @override
  void initState() {
    super.initState();
    _offlinePlaylistsFuture = downloadManager.getOfflinePlaylists();
    _offlineLibrarySub = downloadManager.offlineLibraryChanged.listen((_) {
      if (!mounted) return;
      setState(() {
        _offlinePlaylistsFuture = downloadManager.getOfflinePlaylists();
      });
    });
    //Restore sort
    int? index = Sorting.index(SortSourceTypes.PLAYLISTS);
    if (index != null) {
      _sort = cache.sorts[index];
    }

    _load();
  }

  @override
  void dispose() {
    _filterDebounce?.cancel();
    _offlineLibrarySub?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: FreezerAppBar(
        'Playlists'.i18n,
        actions: [
          IconButton(
            icon: Icon(
              _sort.reverse
                  ? FontAwesome5.sort_alpha_up
                  : FontAwesome5.sort_alpha_down,
              semanticLabel: _sort.reverse
                  ? 'Sort descending'.i18n
                  : 'Sort ascending'.i18n,
            ),
            onPressed: () => _reverse(),
          ),
          PopupMenuButton(
            color: Theme.of(context).scaffoldBackgroundColor,
            onSelected: (SortType s) async {
              setState(() => _sort.type = s);
              //Save to cache
              int? index = Sorting.index(SortSourceTypes.PLAYLISTS);
              if (index == null) {
                cache.sorts.add(_sort);
              } else {
                cache.sorts[index] = _sort;
              }

              await cache.save();
            },
            itemBuilder: (context) => <PopupMenuEntry<SortType>>[
              PopupMenuItem(
                value: SortType.DEFAULT,
                child: Text('Default'.i18n, style: popupMenuTextStyle()),
              ),
              PopupMenuItem(
                value: SortType.USER,
                child: Text('User'.i18n, style: popupMenuTextStyle()),
              ),
              PopupMenuItem(
                value: SortType.TRACK_COUNT,
                child: Text('Track count'.i18n, style: popupMenuTextStyle()),
              ),
              PopupMenuItem(
                value: SortType.ALPHABETIC,
                child: Text('Alphabetic'.i18n, style: popupMenuTextStyle()),
              ),
            ],
            child: const Icon(Icons.sort, size: 32.0),
          ),
          Container(width: 8.0),
        ],
      ),
      body: MobileScrollbar(
        controller: _scrollController,
        backgroundColor: Theme.of(context).primaryColor,
        childBuilder: (scrollController, scrollPhysics) => ListView(
          controller: scrollController,
          physics: scrollPhysics,
          children: <Widget>[
            //Search
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: TextField(
                cursorColor: Theme.of(context).primaryColor,
                onChanged: _onFilterChanged,
                decoration: InputDecoration(
                  labelText: 'Search'.i18n,
                  fillColor: Theme.of(context).bottomAppBarTheme.color,
                  filled: true,
                  focusedBorder: const OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.grey),
                  ),
                  enabledBorder: const OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.grey),
                  ),
                  floatingLabelStyle: TextStyle(
                    color: Theme.of(context).primaryColor,
                  ),
                ),
              ),
            ),
            LocalPlaylistsSection(
              onPlaylistsChanged: () => setState(() {}),
              onHasPlaylistsChanged: (hasPlaylists) {
                if (_hasLocalOfflinePlaylists != hasPlaylists) {
                  setState(() => _hasLocalOfflinePlaylists = hasPlaylists);
                }
              },
            ),
            if (MediaQuery.sizeOf(context).width < 960) ...[
              const FreezerDivider(),
              ListTile(
                title: Text('Create new playlist'.i18n),
                leading: const LeadingIcon(
                  Icons.playlist_add,
                  color: Color(0xff009a85),
                ),
                onTap: _createPlaylist,
              ),
              const FreezerDivider(),
            ],

            if (_playlists == null ||
                (_loadingPlaylistPage && _playlists!.isEmpty))
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  CircularProgressIndicator(
                    color: Theme.of(context).primaryColor,
                  ),
                ],
              ),

            if (MediaQuery.sizeOf(context).width >= 960)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                child: Text(
                  'Playlists'.i18n,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),

            if (_playlists != null)
              Builder(
                builder: (context) {
                  final sortedPlaylists = _playlists!;
                  if (sortedPlaylists.isEmpty && !_hasLocalOfflinePlaylists) {
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (MediaQuery.sizeOf(context).width >= 960)
                          ResponsiveMediaGrid.builder(
                            itemCount: 1,
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            itemBuilder: (context, index) =>
                                CreatePlaylistGridCard(onTap: _createPlaylist),
                          ),
                        SizedBox(
                          height: 230,
                          child: _LibraryEmptyState(
                            icon: Icons.queue_music_rounded,
                            title: 'No playlists found'.i18n,
                            subtitle:
                                'Add items to your library to see them here.'
                                    .i18n,
                          ),
                        ),
                      ],
                    );
                  }
                  if (MediaQuery.sizeOf(context).width >= 960) {
                    return ResponsiveMediaGrid.builder(
                      itemCount: sortedPlaylists.length + 1,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      extraTextHeight: 70,
                      itemBuilder: (context, i) {
                        if (i == 0) {
                          return CreatePlaylistGridCard(
                            onTap: _createPlaylist,
                          );
                        }
                        final playlist = sortedPlaylists[i - 1];
                        return LayoutBuilder(
                          builder: (context, constraints) => PlaylistCardTile(
                            playlist,
                            width: constraints.maxWidth,
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (context) => PlaylistDetails(playlist),
                              ),
                            ),
                            onHold: () => MenuSheet().defaultPlaylistMenu(
                              playlist,
                              context: context,
                              onRemove: () => setState(
                                () => _playlists!.remove(playlist),
                              ),
                              onUpdate: _load,
                            ),
                          ),
                        );
                      },
                    );
                  }
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: List.generate(sortedPlaylists.length, (int i) {
                      Playlist p = sortedPlaylists[i];
                      return PlaylistTile(
                        p,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (context) => PlaylistDetails(p),
                          ),
                        ),
                        onHold: () {
                          MenuSheet m = MenuSheet();
                          m.defaultPlaylistMenu(
                            p,
                            context: context,
                            onRemove: () {
                              setState(() => _playlists!.remove(p));
                            },
                            onUpdate: () {
                              _load();
                            },
                          );
                        },
                      );
                    }),
                  );
                },
              ),
            if (_hasMorePlaylists)
              VisibilityDetector(
                key: ValueKey('playlist-page-${_playlists?.length ?? 0}'),
                onVisibilityChanged: (info) {
                  if (info.visibleFraction > 0 && !_loadingPlaylistPage) {
                    _load(reset: false);
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: _loadingPlaylistPage
                      ? const Center(child: CircularProgressIndicator())
                      : const SizedBox(height: 1),
                ),
              ),

            FutureBuilder(
              future: _offlinePlaylistsFuture,
              builder: (context, snapshot) {
                if (snapshot.hasError || !snapshot.hasData) {
                  return const SizedBox(height: 0, width: 0);
                }
                if (!snapshot.hasData || snapshot.data!.isEmpty) {
                  return const SizedBox(height: 0, width: 0);
                }

                List<Playlist> playlists = snapshot.data!;
                if (playlists.isEmpty) {
                  return const SizedBox.shrink();
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const FreezerDivider(),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                      child: Text(
                        'Offline playlists'.i18n,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    if (MediaQuery.sizeOf(context).width >= 960)
                      ResponsiveMediaGrid.builder(
                        itemCount: playlists.length,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        extraTextHeight: 70,
                        itemBuilder: (context, i) {
                          final playlist = playlists[i];
                          return LayoutBuilder(
                            builder: (context, constraints) => PlaylistCardTile(
                              playlist,
                              showPlatformBadge: true,
                              subtitleOverride:
                                  '${playlist.trackCount ?? playlist.tracks?.length ?? 0} ${'Tracks'.i18n}',
                              width: constraints.maxWidth,
                              onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (context) =>
                                      PlaylistDetails(playlist),
                                ),
                              ),
                              onHold: () => MenuSheet().defaultPlaylistMenu(
                                playlist,
                                context: context,
                                onRemove: () => setState(() {
                                  playlists.remove(playlist);
                                  _playlists!.remove(playlist);
                                }),
                              ),
                            ),
                          );
                        },
                      )
                    else
                      ...List.generate(playlists.length, (i) {
                        final playlist = playlists[i];
                        return PlaylistTile(
                          playlist,
                          showPlatformBadge: true,
                          subtitleOverride:
                              '${playlist.trackCount ?? playlist.tracks?.length ?? 0} ${'Tracks'.i18n}',
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (context) => PlaylistDetails(playlist),
                            ),
                          ),
                          onHold: () => MenuSheet().defaultPlaylistMenu(
                            playlist,
                            context: context,
                            onRemove: () => setState(() {
                              playlists.remove(playlist);
                              _playlists!.remove(playlist);
                            }),
                          ),
                        );
                      }),
                  ],
                );
              },
            ),
            if (MediaQuery.sizeOf(context).width >= 960 &&
                !_hasLocalOfflinePlaylists)
              LocalPlaylistsSection(
                actionsOnly: true,
                onHasPlaylistsChanged: (hasPlaylists) {
                  if (_hasLocalOfflinePlaylists != hasPlaylists) {
                    setState(() => _hasLocalOfflinePlaylists = hasPlaylists);
                  }
                },
              ),
          ],
        ),
      ),
    );
  }
}

class LibraryShows extends StatefulWidget {
  const LibraryShows({super.key});

  @override
  _LibraryShowsState createState() => _LibraryShowsState();
}

class _LibraryShowsState extends State<LibraryShows> {
  List<Show>? _shows;
  Sorting _sort = Sorting(sourceType: SortSourceTypes.SHOWS);
  final ScrollController _scrollController = ScrollController();
  String _filter = '';

  List<Show> get _sorted {
    List<Show> shows = List.from(
      _shows!.where(
        (p) => p.name!.toLowerCase().contains(_filter.toLowerCase()),
      ),
    );
    switch (_sort.type) {
      case SortType.DEFAULT:
        break;
      case SortType.ALPHABETIC:
        shows.sort(
          (a, b) => a.name!.toLowerCase().compareTo(b.name!.toLowerCase()),
        );
        break;
      default:
        break;
    }
    if (_sort.reverse) return shows.reversed.toList();
    return shows;
  }

  Future _load() async {
    if (!settings.offlineMode) {
      try {
        List<Show> shows = await PlatformManager.instance.active.getUserShows();
        if (mounted) setState(() => _shows = shows);
      } catch (e) {
        Logger.root.severe('Error loading shows: $e');
      }
    }
  }

  Future _reverse() async {
    setState(() => _sort.reverse = !_sort.reverse);
    //Save sorting in cache
    int? index = Sorting.index(SortSourceTypes.SHOWS);
    if (index != null) {
      cache.sorts[index] = _sort;
    } else {
      cache.sorts.add(_sort);
    }
    await cache.save();
  }

  @override
  void initState() {
    //Restore sort
    int? index = Sorting.index(SortSourceTypes.SHOWS);
    if (index != null) {
      _sort = cache.sorts[index];
    }

    _load();
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: FreezerAppBar(
        'Podcasts'.i18n,
        actions: [
          IconButton(
            icon: Icon(
              _sort.reverse
                  ? FontAwesome5.sort_alpha_up
                  : FontAwesome5.sort_alpha_down,
              semanticLabel: _sort.reverse
                  ? 'Sort descending'.i18n
                  : 'Sort ascending'.i18n,
            ),
            onPressed: () => _reverse(),
          ),
          PopupMenuButton(
            color: Theme.of(context).scaffoldBackgroundColor,
            onSelected: (SortType s) async {
              setState(() => _sort.type = s);
              //Save to cache
              int? index = Sorting.index(SortSourceTypes.SHOWS);
              if (index == null) {
                cache.sorts.add(_sort);
              } else {
                cache.sorts[index] = _sort;
              }

              await cache.save();
            },
            itemBuilder: (context) => <PopupMenuEntry<SortType>>[
              PopupMenuItem(
                value: SortType.DEFAULT,
                child: Text('Default'.i18n, style: popupMenuTextStyle()),
              ),
              PopupMenuItem(
                value: SortType.ALPHABETIC,
                child: Text('Alphabetic'.i18n, style: popupMenuTextStyle()),
              ),
            ],
            child: const Icon(Icons.sort, size: 32.0),
          ),
          Container(width: 8.0),
        ],
      ),
      body: MobileScrollbar(
        controller: _scrollController,
        backgroundColor: Theme.of(context).primaryColor,
        childBuilder: (scrollController, scrollPhysics) => ListView(
          controller: scrollController,
          physics: scrollPhysics,
          children: <Widget>[
            //Search
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: TextField(
                cursorColor: Theme.of(context).primaryColor,
                onChanged: (String s) => setState(() => _filter = s),
                decoration: InputDecoration(
                  labelText: 'Search'.i18n,
                  fillColor: Theme.of(context).bottomAppBarTheme.color,
                  filled: true,
                  focusedBorder: const OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.grey),
                  ),
                  enabledBorder: const OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.grey),
                  ),
                  floatingLabelStyle: TextStyle(
                    color: Theme.of(context).primaryColor,
                  ),
                ),
              ),
            ),
            const FreezerDivider(),

            if (!settings.offlineMode && _shows == null)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  CircularProgressIndicator(
                    color: Theme.of(context).primaryColor,
                  ),
                ],
              ),

            if (_shows != null)
              Builder(
                builder: (context) {
                  final sortedShows = _sorted;
                  if (sortedShows.isEmpty) {
                    return SizedBox(
                      height: 230,
                      child: _LibraryEmptyState(
                        icon: Icons.podcasts_rounded,
                        title: 'No podcasts found'.i18n,
                        subtitle:
                            'Add items to your library to see them here.'.i18n,
                      ),
                    );
                  }
                  if (MediaQuery.sizeOf(context).width >= 960) {
                    return ResponsiveMediaGrid.builder(
                      itemCount: sortedShows.length,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      extraTextHeight: 64,
                      itemBuilder: (context, i) {
                        final show = sortedShows[i];
                        return LayoutBuilder(
                          builder: (context, constraints) => ShowCard(
                            show,
                            width: constraints.maxWidth,
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (context) => ShowScreen(show),
                              ),
                            ),
                            onHold: () => MenuSheet().defaultShowMenu(
                              show,
                              context: context,
                              onRemove: () =>
                                  setState(() => _shows!.remove(show)),
                              onUpdate: _load,
                            ),
                          ),
                        );
                      },
                    );
                  }
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: List.generate(sortedShows.length, (int i) {
                      Show s = sortedShows[i];
                      return ShowTile(
                        s,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (context) => ShowScreen(s),
                          ),
                        ),
                        onHold: () {
                          MenuSheet m = MenuSheet();
                          m.defaultShowMenu(
                            s,
                            context: context,
                            onRemove: () {
                              setState(() => _shows!.remove(s));
                            },
                            onUpdate: () {
                              _load();
                            },
                          );
                        },
                        trailing: IconButton(
                          icon: const Icon(Icons.more_vert),
                          onPressed: () {
                            MenuSheet m = MenuSheet();
                            m.defaultShowMenu(
                              s,
                              context: context,
                              onRemove: () {
                                setState(() => _shows!.remove(s));
                              },
                              onUpdate: () {
                                _load();
                              },
                            );
                          },
                        ),
                      );
                    }),
                  );
                },
              ),
            if (settings.offlineMode && _shows == null)
              SizedBox(
                height: 230,
                child: _LibraryEmptyState(
                  icon: Icons.podcasts_rounded,
                  title: 'No podcasts found'.i18n,
                  subtitle: 'Add items to your library to see them here.'.i18n,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  _HistoryScreenState createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  late final List<MusicPlatform> _historyPlatforms;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _historyPlatforms = PlatformRegistry.instance.allPlatforms
        .where((p) => p.capabilities.supportsHistory)
        .toList();

    final activeIndex = _historyPlatforms.indexWhere(
      (p) => p.platformId == PlatformManager.instance.activePlatformId,
    );
    final initialIndex = activeIndex >= 0 ? activeIndex + 1 : 0;
    _tabController = TabController(
      length: 1 + _historyPlatforms.length,
      vsync: this,
      initialIndex: initialIndex,
    );
    _tabController.addListener(_onTabChanged);
  }

  void _onTabChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Widget _trackTile(
    Track track,
    List<Track> tracks,
    String source,
    int index,
  ) => TrackTile(
    track,
    showPlatformBadge: true,
    key: Key('${source}_track_${track.id}_$index'),
    onTap: () {
      GetIt.I<AudioPlayerHandler>().playFromTrackList(
        tracks,
        track.id!,
        QueueSource(id: null, text: 'History'.i18n, source: source),
      );
    },
    onHold: () {
      MenuSheet().defaultTrackMenu(track, context: context);
    },
  );

  Widget _localHistory() {
    final seen = <String>{};
    final tracks = cache.history.reversed
        .where((t) => t.id == null || seen.add(t.id!))
        .toList();
    if (tracks.isEmpty) {
      return _LibraryEmptyState(
        icon: Icons.history_rounded,
        title: 'No listening history yet.'.i18n,
      );
    }
    return MobileScrollbar(
      controller: _scrollController,
      backgroundColor: Theme.of(context).primaryColor,
      childBuilder: (scrollController, scrollPhysics) => ListView.builder(
        controller: scrollController,
        physics: scrollPhysics,
        itemCount: tracks.length,
        itemBuilder: (context, index) =>
            _trackTile(tracks[index], tracks, 'history_page', index),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasPlatformTabs = _historyPlatforms.isNotEmpty;
    return Scaffold(
      appBar: FreezerAppBar(
        'History'.i18n,
        height: hasPlatformTabs ? 104 : 56,
        bottom: hasPlatformTabs
            ? TabBar(
                controller: _tabController,
                isScrollable: _historyPlatforms.length > 1,
                tabAlignment: _historyPlatforms.length > 1
                    ? TabAlignment.start
                    : null,
                tabs: [
                  Tab(text: 'On this device'.i18n),
                  for (final p in _historyPlatforms) Tab(text: p.platformName),
                ],
              )
            : null,
        actions: [
          if (_tabController.index == 0)
            IconButton(
              tooltip: 'Clear local history',
              icon: Icon(Icons.delete_sweep, semanticLabel: 'Clear all'.i18n),
              onPressed: () {
                setState(() => cache.history = []);
                cache.save();
              },
            ),
        ],
      ),
      body: hasPlatformTabs
          ? TabBarView(
              controller: _tabController,
              children: [
                _localHistory(),
                for (final p in _historyPlatforms)
                  _PlatformHistoryView(
                    key: ValueKey(p.platformId),
                    platform: p,
                  ),
              ],
            )
          : _localHistory(),
    );
  }
}

class _PlatformHistoryView extends StatefulWidget {
  final MusicPlatform platform;

  const _PlatformHistoryView({super.key, required this.platform});

  @override
  State<_PlatformHistoryView> createState() => _PlatformHistoryViewState();
}

class _PlatformHistoryViewState extends State<_PlatformHistoryView>
    with AutomaticKeepAliveClientMixin {
  final ScrollController _scrollController = ScrollController();
  List<Track> _tracks = [];
  String? _error;
  bool _loading = false;
  bool _loadingMore = false;
  bool _signedIn = true;
  String? _nextCursor;
  int _request = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadHistory();
  }

  @override
  void didUpdateWidget(covariant _PlatformHistoryView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.platform.platformId != widget.platform.platformId) {
      _loadHistory();
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients ||
        _loading ||
        _loadingMore ||
        _nextCursor == null) {
      return;
    }
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 400) {
      _loadMore();
    }
  }

  Future<void> _loadHistory() async {
    if (_loading) return;
    final platform = widget.platform;
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
      _nextCursor = null;
    });
    try {
      if (!await platform.isLoggedIn()) {
        if (mounted && request == _request) {
          setState(() {
            _signedIn = false;
            _tracks = [];
          });
        }
        return;
      }
      final page = await platform.getHistoryTracks();
      if (!mounted || request != _request) return;
      final seen = <String>{};
      final uniqueTracks = page.tracks
          .where((t) => t.id == null || seen.add(t.id!))
          .toList();
      appLogger.info(
        '[_PlatformHistoryView] _loadHistory(${platform.platformId}) loaded '
        '${uniqueTracks.length} tracks, nextCursor=${page.nextCursor}',
      );
      setState(() {
        _signedIn = true;
        _tracks = uniqueTracks;
        _nextCursor = page.nextCursor;
      });
    } catch (error, stackTrace) {
      appLogger.warning(
        'Could not load history for ${platform.platformId}',
        error,
        stackTrace,
      );
      if (mounted && request == _request) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted && request == _request) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || _nextCursor == null) return;
    final platform = widget.platform;
    final request = _request;
    var cursor = _nextCursor;
    setState(() {
      _loadingMore = true;
    });
    try {
      final existingIds = _tracks.map((t) => t.id).whereType<String>().toSet();
      final newUniqueTracks = <Track>[];
      var nextCursor = cursor;

      // Loop in case a page contains only duplicates of tracks already seen
      while (newUniqueTracks.isEmpty && nextCursor != null) {
        final page = await platform.getHistoryTracks(cursor: nextCursor);
        if (!mounted || request != _request) return;
        nextCursor = page.nextCursor;
        final additional = page.tracks
            .where((t) => t.id == null || existingIds.add(t.id!))
            .toList();
        newUniqueTracks.addAll(additional);
      }

      appLogger.info(
        '[_PlatformHistoryView] _loadMore(${platform.platformId}) loaded '
        '${newUniqueTracks.length} new unique tracks, nextCursor=$nextCursor',
      );
      setState(() {
        _tracks.addAll(newUniqueTracks);
        _nextCursor = nextCursor;
      });
    } catch (error, stackTrace) {
      appLogger.warning(
        'Could not load more history for ${platform.platformId}',
        error,
        stackTrace,
      );
    } finally {
      if (mounted && request == _request) {
        setState(() => _loadingMore = false);
      }
    }
  }

  Widget _trackTile(Track track, List<Track> tracks, int index) => TrackTile(
    track,
    key: Key('${widget.platform.platformId}_history_track_${track.id}_$index'),
    onTap: () {
      GetIt.I<AudioPlayerHandler>().playFromTrackList(
        tracks,
        track.id!,
        QueueSource(
          id: widget.platform.platformId,
          text: 'History'.i18n,
          source: 'platform_history_page',
        ),
      );
    },
    onHold: () {
      MenuSheet().defaultTrackMenu(track, context: context);
    },
  );

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (!_signedIn) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                'Sign in to view your ${widget.platform.platformName} listening history.'
                    .i18n,
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ElevatedButton(
                  onPressed: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) =>
                            const PlatformLoginScreen(callback: null),
                      ),
                    );
                    if (mounted) _loadHistory();
                  },
                  child: Text('Sign in'.i18n),
                ),
                const SizedBox(width: 8),
                TextButton(onPressed: _loadHistory, child: Text('Retry'.i18n)),
              ],
            ),
          ],
        ),
      );
    }
    if (_tracks.isEmpty && _loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_tracks.isEmpty && _error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(_error!, textAlign: TextAlign.center),
            ),
            const SizedBox(height: 8),
            TextButton(onPressed: _loadHistory, child: Text('Retry'.i18n)),
          ],
        ),
      );
    }
    if (_tracks.isEmpty) {
      return RefreshIndicator(
        onRefresh: _loadHistory,
        child: SilkyListView(
          silkyConfig: silkyScrollConfig,
          controller: _scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.5,
              child: _LibraryEmptyState(
                icon: Icons.history_rounded,
                title: 'No listening history yet.'.i18n,
              ),
            ),
          ],
        ),
      );
    }
    final showFooter = _nextCursor != null || _loadingMore;
    final totalCount = _tracks.length + (showFooter ? 1 : 0);
    return RefreshIndicator(
      onRefresh: _loadHistory,
      child: NotificationListener<ScrollNotification>(
        onNotification: (scrollInfo) {
          if (scrollInfo.metrics.extentAfter < 500) {
            _loadMore();
          }
          return false;
        },
        child: MobileScrollbar(
          controller: _scrollController,
          backgroundColor: Theme.of(context).primaryColor,
          childBuilder: (scrollController, scrollPhysics) => ListView.builder(
            controller: scrollController,
            physics: scrollPhysics == null
                ? const AlwaysScrollableScrollPhysics()
                : AlwaysScrollableScrollPhysics(parent: scrollPhysics),
            itemCount: totalCount,
            itemBuilder: (context, index) {
              if (index >= _tracks.length) {
                return VisibilityDetector(
                  key: ValueKey(
                    '${widget.platform.platformId}-history-footer-${_tracks.length}',
                  ),
                  onVisibilityChanged: (info) {
                    if (info.visibleFraction > 0 &&
                        !_loadingMore &&
                        !_loading) {
                      _loadMore();
                    }
                  },
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                );
              }
              if (index >= _tracks.length - 3 &&
                  !_loadingMore &&
                  _nextCursor != null) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _loadMore();
                });
              }
              return _trackTile(_tracks[index], _tracks, index);
            },
          ),
        ),
      ),
    );
  }
}
