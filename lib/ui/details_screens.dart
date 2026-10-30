import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:fluttericon/font_awesome5_icons.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import 'package:silky_scroll/silky_scroll.dart';
import 'package:saturn/ui/smooth_scroll_config.dart';

import '../api/cache.dart';
import '../api/definitions.dart';
import '../api/download.dart';
import '../platform/music_platform.dart';
import '../platform/platform_manager.dart';
import '../platform/platform_registry.dart';
import '../platform/soundcloud/soundcloud_client.dart';
import '../service/audio_service.dart';
import '../translations.i18n.dart';
import '../ui/elements.dart';
import '../ui/error.dart';
import '../ui/search.dart';
import 'cached_image.dart';
import 'mosaic_image.dart';
import 'menu.dart';
import 'tiles.dart';
import 'toast.dart';
import 'mobile_scrollbar.dart';
export 'track_details.dart';

String? _playlistArtworkCredit(Playlist playlist) {
  if (playlist.mosaicImages?.isNotEmpty == true) {
    final credits = playlist.mosaicImageCaptions
        ?.whereType<String>()
        .map((credit) => credit.trim())
        .where((credit) => credit.isNotEmpty)
        .toSet();
    if (credits?.isNotEmpty == true) return credits!.join(', ');
  }
  return playlist.image?.caption;
}

class AlbumDetails extends StatefulWidget {
  final Album album;
  const AlbumDetails(this.album, {super.key});

  @override
  _AlbumDetailsState createState() => _AlbumDetailsState();
}

class _AlbumDetailsState extends State<AlbumDetails> {
  Album album = Album();
  bool _loading = true;
  bool _error = false;

  Future _loadAlbum() async {
    // Deezer's Pipe API has the AI-content marker; refresh Deezer album data
    // even when tracks were passed in from a previous page.
    final needsTracks = (album.tracks ?? []).isEmpty;
    if (needsTracks || album.platformId == 'deezer') {
      try {
        Album a = await PlatformManager.instance
            .getPlatform(album.platformId)
            .getAlbum(album.id ?? '');
        //Preserve library
        a.library = album.library;
        setState(() => album = a);
      } catch (e) {
        if (needsTracks) {
          setState(() => _error = true);
        } else {
          Logger.root.fine('Could not refresh Deezer album metadata: $e');
        }
      }
    }
    setState(() => _loading = false);
  }

  //Get count of CDs in album
  int get cdCount {
    int c = 1;
    for (Track t in (album.tracks ?? [])) {
      if ((t.diskNumber ?? 1) > c) c = t.diskNumber!;
    }
    return c;
  }

  Widget _albumTitle(
    BuildContext context, {
    required TextAlign textAlign,
    required int maxLines,
    required double fontSize,
  }) {
    return Row(
      mainAxisAlignment: textAlign == TextAlign.center
          ? MainAxisAlignment.center
          : MainAxisAlignment.start,
      children: [
        Flexible(
          child: Text(
            album.title ?? '',
            textAlign: textAlign,
            overflow: TextOverflow.ellipsis,
            maxLines: maxLines,
            style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.bold),
          ),
        ),
        if (album.hasIdentifiedAIContent) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              'AI',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSecondaryContainer,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ],
    );
  }

  @override
  void initState() {
    album = widget.album;
    _loadAlbum();
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: FreezerAppBar(
        album.title ?? 'Album'.i18n,
        actions: [
          PlatformBadge(album.platformId, iconOnly: true),
          IconButton(
            icon: const Icon(Icons.more_vert),
            onPressed: () {
              MenuSheet m = MenuSheet();
              m.defaultAlbumMenu(album, context: context);
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
              children: <Widget>[
                //Album art, title, artists
                Container(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final isWideScreen = constraints.maxWidth > 668;
                      final imageSize = isWideScreen
                          ? 250.0
                          : MediaQuery.of(context).size.width * 0.5;

                      if (isWideScreen) {
                        // Row layout for wide screens
                        return Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              ZoomableImage(
                                url: album.art?.full ?? '',
                                width: imageSize,
                                rounded: true,
                                caption: album.art?.caption,
                              ),
                              const SizedBox(width: 24.0),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: <Widget>[
                                    _albumTitle(
                                      context,
                                      textAlign: TextAlign.left,
                                      maxLines: 3,
                                      fontSize: 24,
                                    ),
                                    const SizedBox(height: 8.0),
                                    ArtistLinksText(
                                      artists: album.artists,
                                      fallback: album.artistString,
                                      textAlign: TextAlign.left,
                                      maxLines: 2,
                                      style: TextStyle(
                                        fontSize: 18.0,
                                        color: Theme.of(context).primaryColor,
                                      ),
                                    ),
                                    const SizedBox(height: 8.0),
                                    if (album.releaseDate != null &&
                                        album.releaseDate!.length >= 4)
                                      Text(
                                        album.releaseDate!,
                                        textAlign: TextAlign.left,
                                        style: TextStyle(
                                          fontSize: 14.0,
                                          color: Theme.of(
                                            context,
                                          ).disabledColor,
                                        ),
                                      ),
                                    const SizedBox(height: 16.0),
                                    // Details in wide screen
                                    Wrap(
                                      spacing: 16.0,
                                      runSpacing: 8.0,
                                      children: [
                                        Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Icons.audiotrack,
                                              size: 20.0,
                                              semanticLabel: 'Tracks'.i18n,
                                            ),
                                            const SizedBox(width: 6.0),
                                            Text(
                                              album.tracks?.length.toString() ??
                                                  '0',
                                              style: const TextStyle(
                                                fontSize: 14.0,
                                                fontFeatures: [
                                                  FontFeature.tabularFigures(),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
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
                                              album.durationString,
                                              style: const TextStyle(
                                                fontSize: 14.0,
                                                fontFeatures: [
                                                  FontFeature.tabularFigures(),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                        Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Icons.people,
                                              size: 20.0,
                                              semanticLabel: 'Fans'.i18n,
                                            ),
                                            const SizedBox(width: 6.0),
                                            Text(
                                              album.fansString ?? '',
                                              style: const TextStyle(
                                                fontSize: 14.0,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 16.0),
                                    // Actions in wide screen
                                    Row(
                                      children: [
                                        if (PlatformManager
                                            .instance
                                            .active
                                            .capabilities
                                            .supportsAlbums)
                                          TextButton.icon(
                                            style: ButtonStyle(
                                              overlayColor:
                                                  WidgetStateProperty.resolveWith<
                                                    Color?
                                                  >((Set<WidgetState> states) {
                                                    if (states.contains(
                                                      WidgetState.pressed,
                                                    )) {
                                                      return Theme.of(
                                                        context,
                                                      ).primaryColor.withValues(
                                                        alpha: 0.3,
                                                      );
                                                    }
                                                    return null;
                                                  }),
                                            ),
                                            icon: Icon(
                                              (album.library ?? false)
                                                  ? Icons.favorite
                                                  : Icons.favorite_border,
                                              size: 20,
                                            ),
                                            label: Text('Library'.i18n),
                                            onPressed: () async {
                                              //Add to library
                                              if (!(album.library ?? false)) {
                                                await PlatformManager
                                                    .instance
                                                    .active
                                                    .addFavoriteAlbum(
                                                      album.id ?? '',
                                                    );
                                                Fluttertoast.showToast(
                                                  msg: 'Added to library'.i18n,
                                                  toastLength:
                                                      Toast.LENGTH_SHORT,
                                                  gravity: ToastGravity.BOTTOM,
                                                );
                                                setState(
                                                  () => album.library = true,
                                                );
                                                return;
                                              }
                                              //Remove
                                              await PlatformManager
                                                  .instance
                                                  .active
                                                  .removeFavoriteAlbum(
                                                    album.id ?? '',
                                                  );
                                              Fluttertoast.showToast(
                                                msg:
                                                    'Album removed from library!'
                                                        .i18n,
                                                toastLength: Toast.LENGTH_SHORT,
                                                gravity: ToastGravity.BOTTOM,
                                              );
                                              setState(
                                                () => album.library = false,
                                              );
                                            },
                                          ),
                                        MakeAlbumOffline(album: album),
                                        TextButton.icon(
                                          style: ButtonStyle(
                                            overlayColor:
                                                WidgetStateProperty.resolveWith<
                                                  Color?
                                                >((Set<WidgetState> states) {
                                                  if (states.contains(
                                                    WidgetState.pressed,
                                                  )) {
                                                    return Theme.of(context)
                                                        .primaryColor
                                                        .withValues(alpha: 0.3);
                                                  }
                                                  return null;
                                                }),
                                          ),
                                          icon: const Icon(
                                            Icons.file_download,
                                            size: 20.0,
                                          ),
                                          label: Text('Download'.i18n),
                                          onPressed: () async {
                                            if (await downloadManager
                                                    .addOfflineAlbum(
                                                      album,
                                                      private: false,
                                                    ) !=
                                                false) {
                                              MenuSheet()
                                                  .showDownloadStartedToast();
                                            }
                                          },
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      } else {
                        // Column layout for narrow screens
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Container(height: 8.0),
                            ZoomableImage(
                              url: album.art?.full ?? '',
                              width: imageSize,
                              rounded: true,
                              caption: album.art?.caption,
                            ),
                            Container(height: 8),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16.0,
                              ),
                              child: _albumTitle(
                                context,
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                fontSize: 20,
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16.0,
                              ),
                              child: ArtistLinksText(
                                artists: album.artists,
                                fallback: album.artistString,
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                style: TextStyle(
                                  fontSize: 16.0,
                                  color: Theme.of(context).primaryColor,
                                ),
                              ),
                            ),
                            Container(height: 4.0),
                            if (album.releaseDate != null &&
                                album.releaseDate!.length >= 4)
                              Text(
                                album.releaseDate!,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 12.0,
                                  color: Theme.of(context).disabledColor,
                                ),
                              ),
                            Container(height: 8.0),
                          ],
                        );
                      }
                    },
                  ),
                ),
                // Only show divider and separate details/actions on narrow screens
                LayoutBuilder(
                  builder: (context, constraints) {
                    final isWideScreen = constraints.maxWidth > 668;
                    if (isWideScreen) {
                      return const SizedBox.shrink();
                    }
                    return Column(
                      children: [
                        const FreezerDivider(),
                        //Details
                        Row(
                          mainAxisSize: MainAxisSize.max,
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: <Widget>[
                            Row(
                              children: <Widget>[
                                Icon(
                                  Icons.audiotrack,
                                  size: 32.0,
                                  semanticLabel: 'Tracks'.i18n,
                                ),
                                const SizedBox(
                                  width: 8.0,
                                  height: 42.0,
                                ), //Height to adjust card height
                                Text(
                                  album.tracks?.length.toString() ?? '0',
                                  style: const TextStyle(
                                    fontSize: 16.0,
                                    fontFeatures: [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            Row(
                              children: <Widget>[
                                Icon(
                                  Icons.timelapse,
                                  size: 32.0,
                                  semanticLabel: 'Duration'.i18n,
                                ),
                                Container(width: 8.0),
                                Text(
                                  album.durationString,
                                  style: const TextStyle(
                                    fontSize: 16.0,
                                    fontFeatures: [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            Row(
                              children: <Widget>[
                                Icon(
                                  Icons.people,
                                  size: 32.0,
                                  semanticLabel: 'Fans'.i18n,
                                ),
                                Container(width: 8.0),
                                Text(
                                  album.fansString ?? '',
                                  style: const TextStyle(fontSize: 16.0),
                                ),
                              ],
                            ),
                          ],
                        ),
                        const FreezerDivider(),
                        //Options (offline, download...)
                        Row(
                          mainAxisSize: MainAxisSize.max,
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: <Widget>[
                            if (PlatformManager
                                .instance
                                .active
                                .capabilities
                                .supportsAlbums)
                              TextButton(
                                style: ButtonStyle(
                                  overlayColor:
                                      WidgetStateProperty.resolveWith<Color?>((
                                        Set<WidgetState> states,
                                      ) {
                                        if (states.contains(
                                          WidgetState.pressed,
                                        )) {
                                          return Theme.of(
                                            context,
                                          ).primaryColor.withValues(alpha: 0.3);
                                        }
                                        return null;
                                      }),
                                ),
                                child: Row(
                                  children: <Widget>[
                                    Icon(
                                      (album.library ?? false)
                                          ? Icons.favorite
                                          : Icons.favorite_border,
                                      size: 32,
                                    ),
                                    Container(width: 4),
                                    Text('Library'.i18n),
                                  ],
                                ),
                                onPressed: () async {
                                  //Add to library
                                  if (!(album.library ?? false)) {
                                    await PlatformManager.instance
                                        .getPlatform(album.platformId)
                                        .addFavoriteAlbum(album.id ?? '');
                                    Fluttertoast.showToast(
                                      msg: 'Added to library'.i18n,
                                      toastLength: Toast.LENGTH_SHORT,
                                      gravity: ToastGravity.BOTTOM,
                                    );
                                    setState(() => album.library = true);
                                    return;
                                  }
                                  //Remove
                                  await PlatformManager.instance
                                      .getPlatform(album.platformId)
                                      .removeFavoriteAlbum(album.id ?? '');
                                  Fluttertoast.showToast(
                                    msg: 'Album removed from library!'.i18n,
                                    toastLength: Toast.LENGTH_SHORT,
                                    gravity: ToastGravity.BOTTOM,
                                  );
                                  setState(() => album.library = false);
                                },
                              ),
                            MakeAlbumOffline(album: album, size: 32.0),
                            TextButton(
                              style: ButtonStyle(
                                overlayColor:
                                    WidgetStateProperty.resolveWith<Color?>((
                                      Set<WidgetState> states,
                                    ) {
                                      if (states.contains(
                                        WidgetState.pressed,
                                      )) {
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
                                if (await downloadManager.addOfflineAlbum(
                                      album,
                                      private: false,
                                    ) !=
                                    false) {
                                  MenuSheet().showDownloadStartedToast();
                                }
                              },
                            ),
                          ],
                        ),
                      ],
                    );
                  },
                ),
                const FreezerDivider(),
                ...List.generate(cdCount, (cdi) {
                  List<Track> tracks = [];
                  if (album.tracks != null) {
                    tracks.addAll(
                      album.tracks!
                          .where((t) => (t.diskNumber ?? 1) == cdi + 1)
                          .toList(),
                    );
                  }
                  return Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4.0),
                        child: Text(
                          'Disk'.i18n.toUpperCase() + ' ${cdi + 1}',
                          style: const TextStyle(
                            fontSize: 12.0,
                            fontWeight: FontWeight.w300,
                          ),
                        ),
                      ),
                      ...List.generate(
                        tracks.length,
                        (i) => TrackTile(
                          tracks[i],
                          onTap: () {
                            GetIt.I<AudioPlayerHandler>().playFromAlbum(
                              album,
                              tracks[i].id!,
                            );
                          },
                          onHold: () {
                            MenuSheet m = MenuSheet();
                            m.defaultTrackMenu(tracks[i], context: context);
                          },
                        ),
                      ),
                    ],
                  );
                }),
              ],
            ),
    );
  }
}

class MakeAlbumOffline extends StatefulWidget {
  final Album? album;
  final double size;
  const MakeAlbumOffline({super.key, this.album, this.size = 20.0});

  @override
  _MakeAlbumOfflineState createState() => _MakeAlbumOfflineState();
}

class _MakeAlbumOfflineState extends State<MakeAlbumOffline> {
  bool _offline = false;

  @override
  void initState() {
    super.initState();
    downloadManager.checkOffline(album: widget.album).then((v) {
      setState(() {
        _offline = v;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return TextButton(
      style: ButtonStyle(
        overlayColor: WidgetStateProperty.resolveWith<Color?>((
          Set<WidgetState> states,
        ) {
          if (states.contains(WidgetState.pressed)) {
            return Theme.of(context).primaryColor.withValues(alpha: 0.3);
          }
          return null;
        }),
      ),
      child: Row(
        children: <Widget>[
          Icon(_offline ? Icons.wifi_off : Icons.wifi, size: widget.size),
          Container(width: 4),
          Text('Offline'.i18n),
        ],
      ),
      onPressed: () async {
        if (!_offline) {
          //Add to offline
          await PlatformManager.instance
              .getPlatform(widget.album?.platformId ?? '')
              .addFavoriteAlbum(widget.album?.id ?? '');
          downloadManager.addOfflineAlbum(
            widget.album ?? Album(),
            private: true,
          );
          MenuSheet().showDownloadStartedToast();
          setState(() {
            _offline = true;
          });
          return;
        }
        downloadManager.removeOfflineAlbum(
          widget.album?.id ?? '',
          platformId: widget.album?.platformId,
        );
        Fluttertoast.showToast(
          msg: 'Removed album from offline!'.i18n,
          gravity: ToastGravity.BOTTOM,
          toastLength: Toast.LENGTH_SHORT,
        );
        setState(() {
          _offline = false;
        });
      },
    );
  }
}

class ArtistDetails extends StatefulWidget {
  final Artist artist;
  const ArtistDetails(this.artist, {super.key});

  @override
  _ArtistDetailsState createState() => _ArtistDetailsState();
}

class _ArtistDetailsState extends State<ArtistDetails> {
  late Artist artist = Artist();
  bool _loading = true;
  bool _error = false;

  Future _loadArtist() async {
    //Load artist from api if no albums
    final platform = PlatformManager.instance.getPlatform(artist.platformId);
    if (artist.albums.isEmpty ||
        (platform.capabilities.supportsArtists && !artist.pageSectionsLoaded) ||
        (artist.description == null && !artist.pageSectionsLoaded)) {
      try {
        Artist a = await PlatformManager.instance
            .getPlatform(artist.platformId)
            .getArtist(artist.id ?? '');
        if (a.name == 'Unknown Artist' && artist.name?.isNotEmpty == true) {
          a.name = artist.name;
        }
        a.picture ??= artist.picture;
        a.description ??= artist.description;
        a.library = artist.library == true || a.library == true;
        setState(() => artist = a);
      } catch (e, stackTrace) {
        Logger.root.warning(
          'Could not load artist ${artist.id}',
          e,
          stackTrace,
        );
        setState(() => _error = true);
      }
    }
    setState(() => _loading = false);
  }

  @override
  void initState() {
    super.initState();
    artist = widget.artist;
    _loadArtist();
  }

  @override
  Widget build(BuildContext context) {
    final artistPlatform = PlatformManager.instance.getPlatform(
      artist.platformId,
    );
    final artistPageSections = artistPlatform.buildArtistPageSections(
      context,
      artist,
    );
    return Scaffold(
      appBar: FreezerAppBar(
        artist.name ?? 'Artist'.i18n,
        actions: [PlatformBadge(artist.platformId, iconOnly: true)],
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
              children: <Widget>[
                //Artist picture, name, stats
                Container(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final isWideScreen = constraints.maxWidth > 668;
                      final imageSize = isWideScreen
                          ? 250.0
                          : MediaQuery.of(context).size.width * 0.5;

                      if (isWideScreen) {
                        // Row layout for wide screens
                        return Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              ZoomableImage(
                                url: artist.picture?.full ?? '',
                                width: imageSize,
                                circular: true,
                                caption: artist.name,
                              ),
                              const SizedBox(width: 24.0),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: <Widget>[
                                    Text(
                                      artist.name ?? 'Unavailable',
                                      textAlign: TextAlign.left,
                                      overflow: TextOverflow.ellipsis,
                                      maxLines: 3,
                                      style: const TextStyle(
                                        fontSize: 24.0,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(height: 16.0),
                                    // Stats in wide screen
                                    Wrap(
                                      spacing: 16.0,
                                      runSpacing: 8.0,
                                      children: [
                                        if (artist.fans != null)
                                          Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                Icons.people,
                                                size: 20.0,
                                                semanticLabel: 'Fans'.i18n,
                                              ),
                                              const SizedBox(width: 6.0),
                                              Text(
                                                artist.fansString,
                                                style: const TextStyle(
                                                  fontSize: 14.0,
                                                ),
                                              ),
                                            ],
                                          ),
                                        if (artist.albumCount != null)
                                          Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                Icons.album,
                                                size: 20.0,
                                                semanticLabel: 'Albums'.i18n,
                                              ),
                                              const SizedBox(width: 6.0),
                                              Text(
                                                artist.albumCountString,
                                                style: const TextStyle(
                                                  fontSize: 14.0,
                                                ),
                                              ),
                                            ],
                                          ),
                                      ],
                                    ),
                                    const SizedBox(height: 16.0),
                                    // Actions in wide screen
                                    Row(
                                      children: [
                                        if (artistPlatform
                                            .capabilities
                                            .supportsArtists)
                                          TextButton.icon(
                                            style: ButtonStyle(
                                              overlayColor:
                                                  WidgetStateProperty.resolveWith<
                                                    Color?
                                                  >((Set<WidgetState> states) {
                                                    if (states.contains(
                                                      WidgetState.pressed,
                                                    )) {
                                                      return Theme.of(
                                                        context,
                                                      ).primaryColor.withValues(
                                                        alpha: 0.3,
                                                      );
                                                    }
                                                    return null;
                                                  }),
                                            ),
                                            icon: Icon(
                                              artist.library == true
                                                  ? Icons.favorite
                                                  : Icons.favorite_border,
                                              size: 20,
                                            ),
                                            label: Text(
                                              artist.library == true
                                                  ? 'Following'.i18n
                                                  : 'Library'.i18n,
                                            ),
                                            onPressed: () async {
                                              final wasFollowing =
                                                  artist.library == true;
                                              try {
                                                if (wasFollowing) {
                                                  await artistPlatform
                                                      .removeFavoriteArtist(
                                                        artist.id ?? '',
                                                      );
                                                } else {
                                                  await artistPlatform
                                                      .addFavoriteArtist(
                                                        artist.id ?? '',
                                                      );
                                                }
                                              } catch (error) {
                                                Fluttertoast.showToast(
                                                  msg:
                                                      error
                                                          is SoundCloudChallengeException
                                                      ? error.toString()
                                                      : 'Could not update artist follow'
                                                            .i18n,
                                                );
                                                return;
                                              }
                                              if (mounted) {
                                                setState(
                                                  () => artist.library =
                                                      !wasFollowing,
                                                );
                                              }
                                              Fluttertoast.showToast(
                                                msg: wasFollowing
                                                    ? 'Artist removed from library'
                                                          .i18n
                                                    : 'Added to library'.i18n,
                                                toastLength: Toast.LENGTH_SHORT,
                                                gravity: ToastGravity.BOTTOM,
                                              );
                                            },
                                          ),
                                        if ((artist.radio ?? false))
                                          TextButton.icon(
                                            style: ButtonStyle(
                                              overlayColor:
                                                  WidgetStateProperty.resolveWith<
                                                    Color?
                                                  >((Set<WidgetState> states) {
                                                    if (states.contains(
                                                      WidgetState.pressed,
                                                    )) {
                                                      return Theme.of(
                                                        context,
                                                      ).primaryColor.withValues(
                                                        alpha: 0.3,
                                                      );
                                                    }
                                                    return null;
                                                  }),
                                            ),
                                            icon: const Icon(
                                              Icons.radio,
                                              size: 20.0,
                                            ),
                                            label: Text('Radio'.i18n),
                                            onPressed: () async {
                                              List<Track> tracks =
                                                  await artistPlatform
                                                      .getSmartRadio(
                                                        artist.id ?? '',
                                                      );
                                              if (tracks.isNotEmpty) {
                                                GetIt.I<AudioPlayerHandler>()
                                                    .playFromTrackList(
                                                      tracks,
                                                      tracks[0].id!,
                                                      QueueSource(
                                                        id: artist.id,
                                                        text:
                                                            'Radio'.i18n +
                                                            ' ${artist.name}',
                                                        source:
                                                            'artist_smartradio',
                                                      ),
                                                    );
                                              }
                                            },
                                          ),
                                      ],
                                    ),
                                    if (artist.description?.trim().isNotEmpty ==
                                        true)
                                      ArtistBiographySection(
                                        description: artist.description!,
                                        showDivider: false,
                                        showTitle: false,
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      } else {
                        // Column layout for narrow screens
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Container(height: 4.0),
                            ZoomableImage(
                              url: artist.picture?.full ?? '',
                              width: imageSize,
                              circular: true,
                              caption: artist.name,
                            ),
                            Container(height: 8.0),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16.0,
                              ),
                              child: Text(
                                artist.name ?? 'Unavailable',
                                textAlign: TextAlign.center,
                                overflow: TextOverflow.ellipsis,
                                maxLines: 4,
                                style: const TextStyle(
                                  fontSize: 20.0,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            Container(height: 8.0),
                          ],
                        );
                      }
                    },
                  ),
                ),
                // Only show divider and separate details/actions on narrow screens
                LayoutBuilder(
                  builder: (context, constraints) {
                    final isWideScreen = constraints.maxWidth > 668;
                    if (isWideScreen) {
                      return const SizedBox.shrink();
                    }
                    return Column(
                      children: [
                        //Stats & Description
                        if (artist.fans != null ||
                            artist.albumCount != null) ...[
                          const FreezerDivider(),
                          Row(
                            mainAxisSize: MainAxisSize.max,
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: <Widget>[
                              if (artist.fans != null)
                                Row(
                                  children: <Widget>[
                                    Icon(
                                      Icons.people,
                                      size: 32.0,
                                      semanticLabel: 'Fans'.i18n,
                                    ),
                                    const SizedBox(width: 8.0, height: 42.0),
                                    Text(
                                      artist.fansString,
                                      style: const TextStyle(fontSize: 16),
                                    ),
                                  ],
                                ),
                              if (artist.albumCount != null)
                                Row(
                                  children: <Widget>[
                                    Icon(
                                      Icons.album,
                                      size: 32.0,
                                      semanticLabel: 'Albums'.i18n,
                                    ),
                                    Container(width: 8.0),
                                    Text(
                                      artist.albumCountString,
                                      style: const TextStyle(fontSize: 16),
                                    ),
                                  ],
                                ),
                            ],
                          ),
                        ],
                        //Actions
                        Row(
                          mainAxisSize: MainAxisSize.max,
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: <Widget>[
                            if (artistPlatform.capabilities.supportsArtists)
                              TextButton(
                                style: ButtonStyle(
                                  overlayColor:
                                      WidgetStateProperty.resolveWith<Color?>((
                                        Set<WidgetState> states,
                                      ) {
                                        if (states.contains(
                                          WidgetState.pressed,
                                        )) {
                                          return Theme.of(
                                            context,
                                          ).primaryColor.withValues(alpha: 0.3);
                                        }
                                        return null;
                                      }),
                                ),
                                child: Row(
                                  children: <Widget>[
                                    Icon(
                                      artist.library == true
                                          ? Icons.favorite
                                          : Icons.favorite_border,
                                      size: 32,
                                    ),
                                    Container(width: 4),
                                    Text(
                                      artist.library == true
                                          ? 'Following'.i18n
                                          : 'Library'.i18n,
                                    ),
                                  ],
                                ),
                                onPressed: () async {
                                  final wasFollowing = artist.library == true;
                                  try {
                                    if (wasFollowing) {
                                      await artistPlatform.removeFavoriteArtist(
                                        artist.id ?? '',
                                      );
                                    } else {
                                      await artistPlatform.addFavoriteArtist(
                                        artist.id ?? '',
                                      );
                                    }
                                  } catch (error) {
                                    Fluttertoast.showToast(
                                      msg: error is SoundCloudChallengeException
                                          ? error.toString()
                                          : 'Could not update artist follow'
                                                .i18n,
                                    );
                                    return;
                                  }
                                  if (mounted) {
                                    setState(
                                      () => artist.library = !wasFollowing,
                                    );
                                  }
                                  Fluttertoast.showToast(
                                    msg: wasFollowing
                                        ? 'Artist removed from library'.i18n
                                        : 'Added to library'.i18n,
                                    toastLength: Toast.LENGTH_SHORT,
                                    gravity: ToastGravity.BOTTOM,
                                  );
                                },
                              ),
                            if ((artist.radio ?? false))
                              TextButton(
                                style: ButtonStyle(
                                  overlayColor:
                                      WidgetStateProperty.resolveWith<Color?>((
                                        Set<WidgetState> states,
                                      ) {
                                        if (states.contains(
                                          WidgetState.pressed,
                                        )) {
                                          return Theme.of(
                                            context,
                                          ).primaryColor.withValues(alpha: 0.3);
                                        }
                                        return null;
                                      }),
                                ),
                                child: Row(
                                  children: <Widget>[
                                    const Icon(Icons.radio, size: 32),
                                    Container(width: 4),
                                    Text('Radio'.i18n),
                                  ],
                                ),
                                onPressed: () async {
                                  List<Track> tracks = await artistPlatform
                                      .getSmartRadio(artist.id ?? '');
                                  if (tracks.isNotEmpty) {
                                    GetIt.I<AudioPlayerHandler>()
                                        .playFromTrackList(
                                          tracks,
                                          tracks[0].id!,
                                          QueueSource(
                                            id: artist.id,
                                            text:
                                                'Radio'.i18n +
                                                ' ${artist.name}',
                                            source: 'artist_smartradio',
                                          ),
                                        );
                                  }
                                },
                              ),
                          ],
                        ),
                      ],
                    );
                  },
                ),
                ...artistPageSections
                    .where(
                      (section) =>
                          section.position == ArtistPageSectionPosition.top,
                    )
                    .map(
                      (section) => ArtistPageSectionPreview(section: section),
                    ),
                const FreezerDivider(),
                Container(height: 12.0),
                //Highlight
                if (artist.highlight != null)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16.0,
                          vertical: 2.0,
                        ),
                        child: Text(
                          artist.highlight?.title ?? '',
                          textAlign: TextAlign.left,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 20.0,
                          ),
                        ),
                      ),
                      if ((artist.highlight?.type ?? '') ==
                          ArtistHighlightType.ALBUM)
                        AlbumTile(
                          artist.highlight?.data,
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (context) =>
                                    AlbumDetails(artist.highlight?.data),
                              ),
                            );
                          },
                        ),
                      Container(height: 8.0),
                    ],
                  ),
                //Top tracks
                ...artistPageSections
                    .where(
                      (section) =>
                          section.position ==
                          ArtistPageSectionPosition.beforeTracks,
                    )
                    .map(
                      (section) => ArtistPageSectionPreview(section: section),
                    ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16.0,
                    vertical: 2.0,
                  ),
                  child: Text(
                    artist.albums.isEmpty ? 'Tracks'.i18n : 'Top Tracks'.i18n,
                    textAlign: TextAlign.left,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 20.0,
                    ),
                  ),
                ),
                Container(height: 4.0),
                ...List.generate(5, (i) {
                  if (artist.topTracks.length <= i) {
                    return const SizedBox(height: 0, width: 0);
                  }
                  Track t = artist.topTracks[i];
                  return TrackTile(
                    t,
                    onTap: () {
                      GetIt.I<AudioPlayerHandler>().playFromTopTracks(
                        artist.topTracks,
                        t.id!,
                        artist,
                      );
                    },
                    onHold: () {
                      MenuSheet mi = MenuSheet();
                      mi.defaultTrackMenu(t, context: context);
                    },
                  );
                }),
                ListTile(
                  title: Text('Show more tracks'.i18n),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) => TrackListScreen(
                          artist.topTracks,
                          QueueSource(
                            id: artist.id,
                            text: 'Top'.i18n + ' ' + '${artist.name}',
                            source: 'artist_top',
                          ),
                          loadTracks: () => PlatformManager.instance
                              .getPlatform(artist.platformId)
                              .getArtistTopTracks(artist.id!),
                        ),
                      ),
                    );
                  },
                ),
                ...artistPageSections
                    .where(
                      (section) =>
                          section.position ==
                          ArtistPageSectionPosition.afterTracks,
                    )
                    .map(
                      (section) => ArtistPageSectionPreview(section: section),
                    ),
                //Albums
                if (artist.albums.isNotEmpty) ...[
                  const FreezerDivider(),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16.0,
                      vertical: 8.0,
                    ),
                    child: Text(
                      'Top Albums'.i18n,
                      textAlign: TextAlign.left,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 20.0,
                      ),
                    ),
                  ),
                  ...List.generate(
                    artist.albums.length > 10 ? 11 : artist.albums.length + 1,
                    (i) {
                      //Show discography
                      if (i == 10 || i == artist.albums.length) {
                        return ListTile(
                          title: Text('Show all albums'.i18n),
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (context) =>
                                    DiscographyScreen(artist: artist),
                              ),
                            );
                          },
                        );
                      }
                      //Top albums
                      Album a = artist.albums[i];
                      return AlbumTile(
                        a,
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (context) => AlbumDetails(a),
                            ),
                          );
                        },
                        onHold: () {
                          MenuSheet m = MenuSheet();
                          m.defaultAlbumMenu(a, context: context);
                        },
                      );
                    },
                  ),
                ],
                ...artistPageSections
                    .where(
                      (section) =>
                          section.position ==
                          ArtistPageSectionPosition.afterAlbums,
                    )
                    .map(
                      (section) => ArtistPageSectionPreview(section: section),
                    ),
                ...artistPageSections
                    .where(
                      (section) =>
                          section.position == ArtistPageSectionPosition.end,
                    )
                    .map(
                      (section) => ArtistPageSectionPreview(section: section),
                    ),
                LayoutBuilder(
                  builder: (context, constraints) {
                    if (constraints.maxWidth > 668 ||
                        artist.description?.trim().isNotEmpty != true) {
                      return const SizedBox.shrink();
                    }
                    return ArtistBiographySection(
                      description: artist.description!,
                    );
                  },
                ),
              ],
            ),
    );
  }
}

class ArtistPageSectionPreview extends StatefulWidget {
  final ArtistPageSection section;

  const ArtistPageSectionPreview({required this.section, super.key});

  @override
  State<ArtistPageSectionPreview> createState() =>
      _ArtistPageSectionPreviewState();
}

class _ArtistPageSectionPreviewState extends State<ArtistPageSectionPreview> {
  late Future<List<dynamic>> _items;

  @override
  void initState() {
    super.initState();
    _items = widget.section.loadItems(widget.section.previewLimit);
  }

  @override
  void didUpdateWidget(covariant ArtistPageSectionPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.section != widget.section) {
      _items = widget.section.loadItems(widget.section.previewLimit);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<dynamic>>(
    future: _items,
    builder: (context, snapshot) {
      final items = snapshot.data ?? const <dynamic>[];
      if (items.isEmpty) {
        return const SizedBox.shrink();
      }
      final section = widget.section;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const FreezerDivider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              section.title,
              style: DefaultTextStyle.of(
                context,
              ).style.copyWith(fontWeight: FontWeight.bold, fontSize: 20),
            ),
          ),
          ...items.map((item) => section.itemBuilder(context, item, items)),
          if (section.showMore && items.length >= section.previewLimit)
            ListTile(
              title: Text('${'Show more'.i18n} ${section.title.toLowerCase()}'),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ArtistPageSectionScreen(
                    section: section,
                    initialItems: items,
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
}

class ArtistPageSectionScreen extends StatefulWidget {
  final ArtistPageSection section;
  final List<dynamic>? initialItems;

  const ArtistPageSectionScreen({
    required this.section,
    this.initialItems,
    super.key,
  });

  @override
  State<ArtistPageSectionScreen> createState() =>
      _ArtistPageSectionScreenState();
}

class _ArtistPageSectionScreenState extends State<ArtistPageSectionScreen> {
  List<dynamic> _items = const [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    final cached = widget.section.getCachedItems?.call() ?? widget.initialItems;
    if (cached != null && cached.isNotEmpty) {
      _items = List<dynamic>.of(cached);
    }
    _loadItems();
  }

  Future<void> _loadItems() async {
    try {
      final items = await widget.section.loadItems(null);
      if (mounted) {
        setState(() {
          if (items.isNotEmpty) {
            _items = items;
          }
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: FreezerAppBar(widget.section.title),
    body: _isLoading && _items.isEmpty
        ? const Center(child: CircularProgressIndicator())
        : Stack(
            children: [
              SilkyListView.builder(
                silkyConfig: silkyScrollConfig,
                itemCount: _items.length,
                itemBuilder: (context, index) =>
                    widget.section.itemBuilder(context, _items[index], _items),
              ),
              if (_isLoading && _items.isNotEmpty)
                const Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: LinearProgressIndicator(minHeight: 2),
                ),
            ],
          ),
  );
}

class ArtistBiographySection extends StatefulWidget {
  final String description;
  final bool showDivider;
  final bool showTitle;

  const ArtistBiographySection({
    required this.description,
    this.showDivider = true,
    this.showTitle = true,
    super.key,
  });

  @override
  State<ArtistBiographySection> createState() => _ArtistBiographySectionState();
}

class _ArtistBiographySectionState extends State<ArtistBiographySection> {
  static const int _previewLines = 5;
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodyMedium?.copyWith(fontSize: 14);
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.description, style: style),
          textDirection: Directionality.of(context),
          maxLines: _previewLines,
        )..layout(maxWidth: constraints.maxWidth - 32);
        final canExpand = painter.didExceedMaxLines;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.showDivider) const FreezerDivider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.showTitle) ...[
                    Text(
                      'Biography'.i18n,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  AnimatedSize(
                    duration: const Duration(milliseconds: 200),
                    alignment: Alignment.topCenter,
                    child: Text(
                      widget.description,
                      maxLines: canExpand && !_expanded ? _previewLines : null,
                      overflow: canExpand && !_expanded
                          ? TextOverflow.ellipsis
                          : TextOverflow.visible,
                      style: style,
                    ),
                  ),
                  if (canExpand)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: () => setState(() => _expanded = !_expanded),
                        icon: Icon(
                          _expanded ? Icons.expand_less : Icons.expand_more,
                        ),
                        label: Text(
                          _expanded ? 'Show less'.i18n : 'Read more'.i18n,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class DiscographyScreen extends StatefulWidget {
  final Artist artist;
  const DiscographyScreen({required this.artist, super.key});

  @override
  _DiscographyScreenState createState() => _DiscographyScreenState();
}

class _DiscographyScreenState extends State<DiscographyScreen> {
  late Artist artist;
  bool _loading = false;
  bool _error = false;
  final List<ScrollController> _controllers = [
    ScrollController(),
    ScrollController(),
    ScrollController(),
  ];

  Future _load() async {
    if (artist.albums.length >= (artist.albumCount ?? 0) || _loading) return;
    setState(() => _loading = true);

    //Fetch data
    List<Album> data;
    try {
      data = await PlatformManager.instance
          .getPlatform(widget.artist.platformId)
          .getDiscographyPage(artist.id ?? '', start: artist.albums.length);
    } catch (e) {
      setState(() {
        _error = true;
        _loading = false;
      });
      return;
    }

    //Save
    setState(() {
      artist.albums.addAll(data);
      _loading = false;
    });
  }

  //Get album tile
  Widget _tile(Album a) => AlbumTile(
    a,
    onTap: () => Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (context) => AlbumDetails(a))),
    onHold: () {
      MenuSheet m = MenuSheet();
      m.defaultAlbumMenu(a, context: context);
    },
  );

  Widget get _loadingWidget {
    if (_loading) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8.0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Theme.of(context).primaryColor),
          ],
        ),
      );
    }
    //Error
    if (_error) return const ErrorScreen();
    //Success
    return const SizedBox(width: 0, height: 0);
  }

  @override
  void initState() {
    artist = widget.artist;

    //Lazy loading scroll
    for (var c in _controllers) {
      c.addListener(() {
        double off = c.position.maxScrollExtent * 0.85;
        if (c.position.pixels > off) _load();
      });
    }

    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    final artistPlatform = PlatformManager.instance.getPlatform(
      widget.artist.platformId,
    );
    final hasSinglesTab = artistPlatform.capabilities.supportsSingles;
    final hasFeaturedTab =
        artistPlatform.capabilities.supportsFeaturedArtistAlbums;

    if (!hasSinglesTab && !hasFeaturedTab) {
      return Scaffold(
        appBar: FreezerAppBar('Discography'.i18n),
        body: SilkyListView.builder(
          silkyConfig: silkyScrollConfig,
          controller: _controllers[0],
          itemCount: artist.albums.length + 1,
          itemBuilder: (context, i) {
            if (i == artist.albums.length) return _loadingWidget;
            return _tile(artist.albums[i]);
          },
        ),
      );
    }

    final tabs = <Widget>[
      Tab(icon: Icon(Icons.album, semanticLabel: 'Albums'.i18n)),
    ];
    final tabViews = <Widget>[
      //Albums
      SilkyListView.builder(
        silkyConfig: silkyScrollConfig,
        controller: _controllers[0],
        itemCount: artist.albums.length + 1,
        itemBuilder: (context, i) {
          if (i == artist.albums.length) return _loadingWidget;
          if (!hasSinglesTab || artist.albums[i].type == AlbumType.ALBUM) {
            return _tile(artist.albums[i]);
          }
          return const SizedBox(width: 0, height: 0);
        },
      ),
    ];

    if (hasSinglesTab) {
      tabs.add(
        Tab(icon: Icon(Icons.audiotrack, semanticLabel: 'Singles'.i18n)),
      );
      tabViews.add(
        //Singles
        SilkyListView.builder(
          silkyConfig: silkyScrollConfig,
          controller: _controllers[1],
          itemCount: artist.albums.length + 1,
          itemBuilder: (context, i) {
            if (i == artist.albums.length) return _loadingWidget;
            if (artist.albums[i].type == AlbumType.SINGLE) {
              return _tile(artist.albums[i]);
            }
            return const SizedBox(width: 0, height: 0);
          },
        ),
      );
    }

    if (hasFeaturedTab) {
      tabs.add(
        Tab(icon: Icon(Icons.recent_actors, semanticLabel: 'Featured'.i18n)),
      );
      tabViews.add(
        //Featured
        SilkyListView.builder(
          silkyConfig: silkyScrollConfig,
          controller: _controllers[2],
          itemCount: artist.albums.length + 1,
          itemBuilder: (context, i) {
            if (i == artist.albums.length) return _loadingWidget;
            if (artist.albums[i].type == AlbumType.FEATURED) {
              return _tile(artist.albums[i]);
            }
            return const SizedBox(width: 0, height: 0);
          },
        ),
      );
    }

    return DefaultTabController(
      length: tabs.length,
      child: Builder(
        builder: (BuildContext context) {
          final TabController tabController = DefaultTabController.of(context);
          tabController.addListener(() {
            if (!tabController.indexIsChanging) {
              //Load data if empty tabs
              int nSingles = hasSinglesTab
                  ? artist.albums
                        .where((a) => a.type == AlbumType.SINGLE)
                        .length
                  : 1;
              int nFeatures = hasFeaturedTab
                  ? artist.albums
                        .where((a) => a.type == AlbumType.FEATURED)
                        .length
                  : 1;
              if ((nSingles == 0 || nFeatures == 0) && !_loading) _load();
            }
          });

          return Scaffold(
            appBar: FreezerAppBar(
              'Discography'.i18n,
              bottom: TabBar(
                dividerColor: Colors.transparent,
                indicatorColor: Theme.of(context).primaryColor,
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
                labelColor: Theme.of(context).primaryColor,
                tabs: tabs,
              ),
              height: 100.0,
            ),
            body: TabBarView(children: tabViews),
          );
        },
      ),
    );
  }
}

class PlaylistDetails extends StatefulWidget {
  final Playlist playlist;
  const PlaylistDetails(this.playlist, {super.key});

  @override
  _PlaylistDetailsState createState() => _PlaylistDetailsState();
}

class _PlaylistDetailsState extends State<PlaylistDetails> {
  late Playlist playlist;
  bool _loading = false;
  bool _error = false;
  bool _hasMoreTracks = true;
  int _trackLoadVersion = 0;
  late Sorting _sort;
  final ScrollController _scrollController = ScrollController();

  //Get sorted playlist
  List<Track>? _cachedSortedTracks;
  Sorting? _lastAppliedSort;
  List<Track>? _lastSourceTracks;

  List<Track> get sorted {
    final currentTracks = playlist.tracks ?? [];
    // Remote playlist pages are already sorted by their platform. Local
    // playlists still use this view-level sort after loading their full list.
    if (playlist.platformId != 'local' &&
        !(playlist.id?.startsWith('local_') ?? false)) {
      return currentTracks;
    }
    if (_cachedSortedTracks != null &&
        identical(currentTracks, _lastSourceTracks) &&
        _lastAppliedSort?.type == _sort.type &&
        _lastAppliedSort?.reverse == _sort.reverse) {
      return _cachedSortedTracks!;
    }
    _lastSourceTracks = currentTracks;
    _lastAppliedSort = Sorting(
      type: _sort.type,
      reverse: _sort.reverse,
      sourceType: _sort.sourceType,
      id: _sort.id,
    );
    return _cachedSortedTracks = currentTracks.applySorting(_sort);
  }

  //Load tracks from api
  Future<void> _loadTracks() async {
    // Got all tracks, return
    if (_loading ||
        !_hasMoreTracks ||
        (playlist.trackCount != null &&
            (playlist.tracks ?? []).length >= playlist.trackCount!)) {
      return;
    }

    final loadVersion = _trackLoadVersion;
    setState(() => _loading = true);
    int pos = (playlist.tracks ?? []).length;
    //Get another page of tracks
    List<Track> tracks;
    try {
      final isLocal =
          playlist.platformId == 'local' ||
          (playlist.id?.startsWith('local_') ?? false);
      if (isLocal) {
        final localId = playlist.id!.startsWith('local_')
            ? playlist.id!.substring(6)
            : playlist.id!;
        final localPlaylist = await downloadManager.localPlaylistManager
            .getPlaylist(localId);
        if (localPlaylist == null) {
          if (mounted) {
            setState(() {
              _error = true;
              _loading = false;
            });
          }
          return;
        }

        if (pos >= localPlaylist.trackIds.length) {
          setState(() => _loading = false);
          return;
        }

        tracks = await downloadManager.loadLocalPlaylistTracks(
          localPlaylist,
          start: pos,
          limit: 25,
        );

        int pageDurationSecs = 0;
        for (final t in tracks) {
          if (t.duration != null) {
            pageDurationSecs += t.duration!.inSeconds;
          }
        }

        if (playlist.duration == null) {
          playlist.duration = Duration(seconds: pageDurationSecs);
        } else {
          playlist.duration = Duration(
            seconds: playlist.duration!.inSeconds + pageDurationSecs,
          );
        }

        if (pos == 0) {
          playlist.mosaicImages = tracks
              .take(4)
              .map((t) => t.albumArt?.fullUrl ?? '')
              .where((u) => u.isNotEmpty)
              .toList();
          localPlaylist.mosaicImages = playlist.mosaicImages;
          await downloadManager.localPlaylistManager.updatePlaylist(
            localPlaylist,
          );
        }
      } else {
        final page = await PlatformManager.instance
            .getPlatform(playlist.platformId)
            .getPlaylistTracksPage(
              id: playlist.id!,
              start: pos,
              limit: 25,
              sort: _sort,
            );
        tracks = page.tracks;
        _hasMoreTracks = page.hasMore;
      }
    } catch (e) {
      if (loadVersion != _trackLoadVersion) return;
      if (mounted) {
        setState(() {
          _error = true;
          _loading = false;
        });
      }
      return;
    }

    if (loadVersion != _trackLoadVersion) return;

    setState(() {
      if (tracks.isEmpty) {
        playlist.trackCount = (playlist.tracks ?? []).length;
      } else if (playlist.tracks == null) {
        playlist.tracks = tracks;
      } else {
        playlist.tracks!.addAll(tracks);
      }
      _loading = false;
    });
  }

  // Find cached sorting index (shared lookup, same as Android Auto/queue)
  int? _findSortIndex() => Sorting.playlistIndex(
    playlist.id,
    platformId: playlist.platformId.isNotEmpty
        ? playlist.platformId
        : PlatformManager.instance.active.platformId,
  );

  // Full loading is retained for local playlists, whose contents are sorted
  // in memory. Remote platforms page their globally sorted results instead.
  bool _fullLoaded = false;
  Future<void>? _fullLoad;
  Future<void> _ensureFullPlaylist() {
    if (_fullLoaded || playlist.id == null) return Future.value();
    return _fullLoad ??= _loadFullPlaylist().whenComplete(
      () => _fullLoad = null,
    );
  }

  Future<void> _loadFullPlaylist() async {
    if (mounted) setState(() => _loading = true);
    try {
      final isLocal =
          playlist.platformId == 'local' || playlist.id!.startsWith('local_');
      if (isLocal) {
        final localId = playlist.id!.startsWith('local_')
            ? playlist.id!.substring(6)
            : playlist.id!;
        final complete = await downloadManager.getFullLocalPlaylist(localId);
        if (complete != null && mounted) {
          _fullLoaded = true;
          setState(() => playlist = complete);
        }
      } else {
        return;
      }
    } catch (e) {
      Logger.root.fine('Playlist preload error: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _preserveCurrentMosaic(Playlist refreshed) {
    if (widget.playlist.platformId == 'neurokaraoke') {
      refreshed.mosaicImages = widget.playlist.mosaicImages;
      refreshed.mosaicImageCaptions = widget.playlist.mosaicImageCaptions;
    }
  }

  //Load cached playlist sorting
  void _restoreSort() {
    int? index = _findSortIndex();
    if (index == null) return;

    _sort = cache.sorts[index];
    if (mounted) {
      setState(() {});
    }
    if ((playlist.platformId == 'local' ||
            (playlist.id?.startsWith('local_') ?? false)) &&
        (_sort.reverse || _sort.type != SortType.DEFAULT)) {
      _ensureFullPlaylist();
    }
  }

  Future _reverse() async {
    setState(() => _sort.reverse = !_sort.reverse);
    int? index = _findSortIndex();
    if (index != null) {
      cache.sorts[index] = _sort;
    } else {
      cache.sorts.add(_sort);
    }
    await cache.save();

    if ((playlist.platformId == 'local' ||
            (playlist.id?.startsWith('local_') ?? false)) &&
        (_sort.reverse || _sort.type != SortType.DEFAULT)) {
      await _ensureFullPlaylist();
    } else if (playlist.platformId != 'local' &&
        !(playlist.id?.startsWith('local_') ?? false)) {
      await _reloadForSort();
    }
  }

  Future<void> _reloadForSort() async {
    if (playlist.platformId == 'local' ||
        (playlist.id?.startsWith('local_') ?? false)) {
      _cachedSortedTracks = null;
      await _ensureFullPlaylist();
      if (mounted) setState(() {});
      return;
    }
    setState(() {
      _trackLoadVersion++;
      _loading = false;
      playlist.tracks = <Track>[];
      _hasMoreTracks = true;
      _cachedSortedTracks = null;
      _lastSourceTracks = null;
      _error = false;
    });
    await _loadTracks();
  }

  @override
  void initState() {
    playlist = widget.playlist;
    _sort = Sorting(sourceType: SortSourceTypes.PLAYLIST, id: playlist.id);
    _restoreSort();

    //If scrolled past 90% load next tracks
    _scrollController.addListener(() {
      double off = _scrollController.position.maxScrollExtent * 0.90;
      if (_scrollController.position.pixels > off) {
        _loadTracks();
      }
    });
    final sortedRemotePlaylist =
        playlist.platformId != 'local' &&
        !(playlist.id?.startsWith('local_') ?? false) &&
        (_sort.reverse || _sort.type != SortType.DEFAULT);
    if (sortedRemotePlaylist) {
      playlist.tracks = <Track>[];
      _hasMoreTracks = true;
      _loadTracks();
    }
    // Initial load if no tracks
    if ((playlist.tracks ?? []).isEmpty && !sortedRemotePlaylist) {
      //Get correct metadata
      setState(() => _loading = true);
      if (playlist.id!.startsWith('local_')) {
        setState(() => _loading = false);
        _loadTracks();
      } else {
        PlatformManager.instance
            .getPlatform(playlist.platformId)
            .getPlaylist(playlist.id!, limit: 25)
            .then((Playlist p) async {
              if (!mounted) return;
              _preserveCurrentMosaic(p);
              setState(() {
                if (p.title == null ||
                    p.title == 'Playlist ${p.id}' ||
                    p.title == 'Playlist VL${p.id}') {
                  p.title = playlist.title;
                }
                p.description ??= playlist.description;
                p.image ??= playlist.image;
                p.editable = p.editable == true || playlist.editable == true;
                if (_fullLoaded) {
                  p.tracks = playlist.tracks;
                  p.trackCount = playlist.trackCount;
                }
                playlist = p;
                _loading = false;
              });
              if (_sort.reverse || _sort.type != SortType.DEFAULT) {
                if (playlist.platformId == 'local') {
                  await _ensureFullPlaylist();
                } else {
                  await _reloadForSort();
                }
              }
            })
            .catchError((e) {
              if (mounted) setState(() => _error = true);
            });
      }
    }

    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    final artworkCredit = _playlistArtworkCredit(playlist);
    return Scaffold(
      appBar: FreezerAppBar(
        playlist.title ?? 'Playlist'.i18n,
        actions: [
          PlatformBadge(playlist.platformId, iconOnly: true),
          IconButton(
            icon: const Icon(Icons.more_vert),
            onPressed: () {
              MenuSheet m = MenuSheet();
              m.defaultPlaylistMenu(playlist, context: context);
            },
          ),
        ],
      ),
      body: MobileScrollbar(
        controller: _scrollController,
        backgroundColor: Theme.of(context).primaryColor,
        childBuilder: (scrollController, scrollPhysics) => ListView(
          controller: scrollController,
          physics: scrollPhysics,
          children: <Widget>[
            //Playlist image, title, user
            Container(
              color: Theme.of(context).scaffoldBackgroundColor,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final isWideScreen = constraints.maxWidth > 668;
                  final imageSize = isWideScreen
                      ? 250.0
                      : MediaQuery.of(context).size.width * 0.5;

                  if (isWideScreen) {
                    // Row layout for wide screens
                    return Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          (playlist.mosaicImages?.isNotEmpty == true)
                              ? MosaicImage(
                                  urls: playlist.mosaicImages!,
                                  captions: playlist.mosaicImageCaptions,
                                  width: imageSize,
                                  height: imageSize,
                                  rounded: true,
                                  zoomOnTap: true,
                                  caption: playlist.image?.caption,
                                )
                              : ZoomableImage(
                                  url: playlist.image?.full ?? '',
                                  width: imageSize,
                                  rounded: true,
                                  caption: playlist.image?.caption,
                                ),
                          const SizedBox(width: 24.0),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Text(
                                  playlist.title ?? '',
                                  textAlign: TextAlign.left,
                                  overflow: TextOverflow.ellipsis,
                                  maxLines: 3,
                                  style: const TextStyle(
                                    fontSize: 24.0,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                if (playlist.user?.name?.isNotEmpty ==
                                    true) ...[
                                  const SizedBox(height: 8.0),
                                  Text(
                                    playlist.user!.name!,
                                    textAlign: TextAlign.left,
                                    overflow: TextOverflow.ellipsis,
                                    maxLines: 2,
                                    style: TextStyle(
                                      fontSize: 18.0,
                                      color: Theme.of(context).primaryColor,
                                    ),
                                  ),
                                ],
                                if (artworkCredit?.isNotEmpty == true) ...[
                                  const SizedBox(height: 4.0),
                                  Text(
                                    'Artwork by'.i18n + ' $artworkCredit',
                                    textAlign: TextAlign.left,
                                    style: TextStyle(
                                      fontSize: 14.0,
                                      color: Theme.of(context).disabledColor,
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 16.0),
                                // Stats in wide screen
                                Wrap(
                                  spacing: 16.0,
                                  runSpacing: 8.0,
                                  children: [
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.audiotrack,
                                          size: 20.0,
                                          semanticLabel: 'Tracks'.i18n,
                                        ),
                                        const SizedBox(width: 6.0),
                                        Text(
                                          (playlist.trackCount ??
                                                  (playlist.tracks ?? [])
                                                      .length)
                                              .toString(),
                                          style: const TextStyle(
                                            fontSize: 14.0,
                                          ),
                                        ),
                                      ],
                                    ),
                                    if (playlist.duration != null)
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
                                            playlist.durationString,
                                            style: const TextStyle(
                                              fontSize: 14.0,
                                              fontFeatures: [
                                                FontFeature.tabularFigures(),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                  ],
                                ),
                                if (playlist.description != null &&
                                    playlist.description!.isNotEmpty) ...[
                                  const SizedBox(height: 12.0),
                                  Text(
                                    playlist.description!,
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.left,
                                    style: TextStyle(
                                      fontSize: 14.0,
                                      color: Theme.of(context).disabledColor,
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 16.0),
                                // Actions in wide screen
                                Row(
                                  children: [
                                    MakePlaylistOffline(playlist),
                                    if (playlist.user?.name !=
                                            PlatformManager
                                                .instance
                                                .active
                                                .currentUserName &&
                                        playlist.disableDownload != true &&
                                        !playlist.id!.startsWith('local_'))
                                      TextButton.icon(
                                        style: ButtonStyle(
                                          overlayColor:
                                              WidgetStateProperty.resolveWith<
                                                Color?
                                              >((Set<WidgetState> states) {
                                                if (states.contains(
                                                  WidgetState.pressed,
                                                )) {
                                                  return Theme.of(context)
                                                      .primaryColor
                                                      .withValues(alpha: 0.3);
                                                }
                                                return null;
                                              }),
                                        ),
                                        icon: Icon(
                                          cache.checkPlaylistFavorite(playlist)
                                              ? Icons.favorite
                                              : Icons.favorite_outline,
                                          size: 20,
                                        ),
                                        label: Text('Library'.i18n),
                                        onPressed: () async {
                                          //Add to library
                                          if (!cache.checkPlaylistFavorite(
                                            playlist,
                                          )) {
                                            await PlatformManager
                                                .instance
                                                .active
                                                .addFavoritePlaylist(
                                                  playlist.id!,
                                                );
                                            cache.activeLibraryPlaylists.add(
                                              playlist.id!,
                                            );
                                            cache.save();
                                            Fluttertoast.showToast(
                                              msg: 'Added to library'.i18n,
                                              toastLength: Toast.LENGTH_SHORT,
                                              gravity: ToastGravity.BOTTOM,
                                            );
                                            setState(
                                              () => playlist.library = true,
                                            );
                                            return;
                                          }
                                          //Remove
                                          await PlatformManager.instance
                                              .getPlatform(playlist.platformId)
                                              .removeFavoritePlaylist(
                                                playlist.id!,
                                              );
                                          cache.activeLibraryPlaylists.remove(
                                            playlist.id!,
                                          );
                                          cache.save();
                                          Fluttertoast.showToast(
                                            msg:
                                                'Playlist removed from library!'
                                                    .i18n,
                                            toastLength: Toast.LENGTH_SHORT,
                                            gravity: ToastGravity.BOTTOM,
                                          );
                                          setState(
                                            () => playlist.library = false,
                                          );
                                        },
                                      ),
                                    if (((playlist.platformId == 'local' ||
                                                (playlist.id?.startsWith(
                                                      'local_',
                                                    ) ??
                                                    false)) ||
                                            PlatformRegistry.instance
                                                    .get(playlist.platformId)
                                                    ?.capabilities
                                                    .supportsDownload ==
                                                true) &&
                                        playlist.disableDownload != true)
                                      TextButton.icon(
                                        style: ButtonStyle(
                                          overlayColor:
                                              WidgetStateProperty.resolveWith<
                                                Color?
                                              >((Set<WidgetState> states) {
                                                if (states.contains(
                                                  WidgetState.pressed,
                                                )) {
                                                  return Theme.of(context)
                                                      .primaryColor
                                                      .withValues(alpha: 0.3);
                                                }
                                                return null;
                                              }),
                                        ),
                                        icon: const Icon(
                                          Icons.file_download,
                                          size: 20.0,
                                        ),
                                        label: Text('Download'.i18n),
                                        onPressed: () async {
                                          if (await downloadManager
                                                  .addOfflinePlaylist(
                                                    playlist,
                                                    private: false,
                                                  ) !=
                                              false) {
                                            MenuSheet()
                                                .showDownloadStartedToast();
                                          }
                                        },
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 16.0),
                                // Sort controls in wide screen
                                Row(
                                  children: [
                                    PopupMenuButton(
                                      color: Theme.of(
                                        context,
                                      ).scaffoldBackgroundColor,
                                      onSelected: (SortType s) async {
                                        setState(() => _sort.type = s);

                                        //Save sort type to cache
                                        int? index = _findSortIndex();
                                        if (index == null) {
                                          cache.sorts.add(_sort);
                                        } else {
                                          cache.sorts[index] = _sort;
                                        }
                                        await cache.save();

                                        await _reloadForSort();
                                      },
                                      itemBuilder: (context) =>
                                          <PopupMenuEntry<SortType>>[
                                            PopupMenuItem(
                                              value: SortType.DEFAULT,
                                              child: Text(
                                                'Default'.i18n,
                                                style: popupMenuTextStyle(),
                                              ),
                                            ),
                                            PopupMenuItem(
                                              value: SortType.ALPHABETIC,
                                              child: Text(
                                                'Alphabetic'.i18n,
                                                style: popupMenuTextStyle(),
                                              ),
                                            ),
                                            PopupMenuItem(
                                              value: SortType.ARTIST,
                                              child: Text(
                                                'Artist'.i18n,
                                                style: popupMenuTextStyle(),
                                              ),
                                            ),
                                            PopupMenuItem(
                                              value: SortType.DATE_ADDED,
                                              child: Text(
                                                'Date added'.i18n,
                                                style: popupMenuTextStyle(),
                                              ),
                                            ),
                                          ],
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            Icons.sort,
                                            size: 20.0,
                                            semanticLabel: 'Sort playlist'.i18n,
                                          ),
                                          const SizedBox(width: 8),
                                          Text('Sort'.i18n),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 8.0),
                                    TextButton.icon(
                                      style: ButtonStyle(
                                        overlayColor:
                                            WidgetStateProperty.resolveWith<
                                              Color?
                                            >((Set<WidgetState> states) {
                                              if (states.contains(
                                                WidgetState.pressed,
                                              )) {
                                                return Theme.of(context)
                                                    .primaryColor
                                                    .withValues(alpha: 0.3);
                                              }
                                              return null;
                                            }),
                                      ),
                                      icon: Icon(
                                        _sort.reverse
                                            ? FontAwesome5.sort_alpha_up
                                            : FontAwesome5.sort_alpha_down,
                                        size: 20.0,
                                        semanticLabel: _sort.reverse
                                            ? 'Sort descending'.i18n
                                            : 'Sort ascending'.i18n,
                                      ),
                                      label: Text(
                                        _sort.reverse
                                            ? 'Descending'.i18n
                                            : 'Ascending'.i18n,
                                      ),
                                      onPressed: () => _reverse(),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  } else {
                    // Column layout for narrow screens
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Container(height: 4.0),
                        (playlist.mosaicImages?.isNotEmpty == true)
                            ? MosaicImage(
                                urls: playlist.mosaicImages!,
                                captions: playlist.mosaicImageCaptions,
                                width: imageSize,
                                height: imageSize,
                                rounded: true,
                                zoomOnTap: true,
                                caption: playlist.image?.caption,
                              )
                            : ZoomableImage(
                                url: playlist.image?.full ?? '',
                                width: imageSize,
                                rounded: true,
                                caption: playlist.image?.caption,
                              ),
                        Container(height: 8.0),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16.0),
                          child: Text(
                            playlist.title ?? '',
                            textAlign: TextAlign.center,
                            overflow: TextOverflow.ellipsis,
                            maxLines: 3,
                            style: const TextStyle(
                              fontSize: 20.0,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        if (playlist.user?.name?.isNotEmpty == true) ...[
                          Container(height: 4.0),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16.0,
                            ),
                            child: Text(
                              playlist.user!.name!,
                              textAlign: TextAlign.center,
                              overflow: TextOverflow.ellipsis,
                              maxLines: 2,
                              style: TextStyle(
                                fontSize: 16.0,
                                color: Theme.of(context).primaryColor,
                              ),
                            ),
                          ),
                        ],
                        if (artworkCredit?.isNotEmpty == true) ...[
                          Container(height: 2.0),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16.0,
                            ),
                            child: Text(
                              'Artwork by'.i18n + ' $artworkCredit',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 13.0,
                                color: Theme.of(context).disabledColor,
                              ),
                            ),
                          ),
                        ],
                        Container(height: 8.0),
                      ],
                    );
                  }
                },
              ),
            ),
            // Only show divider and separate details on narrow screens
            LayoutBuilder(
              builder: (context, constraints) {
                final isWideScreen = constraints.maxWidth > 668;
                if (isWideScreen) {
                  return const SizedBox.shrink();
                }
                return Column(
                  children: [
                    const FreezerDivider(),
                    //Stats
                    Row(
                      mainAxisSize: MainAxisSize.max,
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Icon(
                              Icons.audiotrack,
                              size: 32.0,
                              semanticLabel: 'Tracks'.i18n,
                            ),
                            const SizedBox(width: 8.0, height: 42.0),
                            Text(
                              (playlist.trackCount ??
                                      (playlist.tracks ?? []).length)
                                  .toString(),
                              style: const TextStyle(fontSize: 16),
                            ),
                          ],
                        ),
                        if (playlist.duration != null)
                          Row(
                            children: <Widget>[
                              Icon(
                                Icons.timelapse,
                                size: 32.0,
                                semanticLabel: 'Duration'.i18n,
                              ),
                              Container(width: 8.0),
                              Text(
                                playlist.durationString,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ],
                );
              },
            ),
            if (playlist.description != null &&
                playlist.description!.isNotEmpty)
              LayoutBuilder(
                builder: (context, constraints) {
                  final isWideScreen = constraints.maxWidth > 668;
                  if (isWideScreen) {
                    return const SizedBox.shrink();
                  }
                  return Column(
                    children: [
                      const FreezerDivider(),
                      Padding(
                        padding: const EdgeInsets.all(6.0),
                        child: Text(
                          playlist.description!,
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 16.0),
                        ),
                      ),
                    ],
                  );
                },
              ),
            // Action buttons and sort controls - with divider only on narrow screens
            LayoutBuilder(
              builder: (context, constraints) {
                final isWideScreen = constraints.maxWidth > 668;
                return Column(
                  children: [
                    if (!isWideScreen) const FreezerDivider(),
                    Row(
                      mainAxisSize: MainAxisSize.max,
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: <Widget>[
                        if (!isWideScreen) ...[
                          MakePlaylistOffline(playlist, size: 32.0),
                          if ((playlist.platformId == 'local' ||
                                  (playlist.id?.startsWith('local_') ??
                                      false) ||
                                  playlist.user?.name !=
                                      PlatformManager
                                          .instance
                                          .active
                                          .currentUserName) &&
                              playlist.disableDownload != true)
                            if (((playlist.platformId == 'local' ||
                                        (playlist.id?.startsWith('local_') ??
                                            false)) ||
                                    PlatformRegistry.instance
                                            .get(playlist.platformId)
                                            ?.capabilities
                                            .supportsDownload ==
                                        true) &&
                                playlist.disableDownload != true)
                              IconButton(
                                icon: Icon(
                                  Icons.file_download,
                                  size: 32.0,
                                  semanticLabel: 'Download'.i18n,
                                ),
                                onPressed: () async {
                                  if (await downloadManager.addOfflinePlaylist(
                                        playlist,
                                        private: false,
                                      ) !=
                                      false) {
                                    MenuSheet().showDownloadStartedToast();
                                  }
                                },
                              ),
                        ],
                        if (!isWideScreen) ...[
                          PopupMenuButton(
                            color: Theme.of(context).scaffoldBackgroundColor,
                            onSelected: (SortType s) async {
                              setState(() => _sort.type = s);

                              //Save sort type to cache
                              int? index = _findSortIndex();
                              if (index == null) {
                                cache.sorts.add(_sort);
                              } else {
                                cache.sorts[index] = _sort;
                              }
                              await cache.save();

                              await _reloadForSort();
                            },
                            itemBuilder: (context) =>
                                <PopupMenuEntry<SortType>>[
                                  PopupMenuItem(
                                    value: SortType.DEFAULT,
                                    child: Text(
                                      'Default'.i18n,
                                      style: popupMenuTextStyle(),
                                    ),
                                  ),
                                  PopupMenuItem(
                                    value: SortType.ALPHABETIC,
                                    child: Text(
                                      'Alphabetic'.i18n,
                                      style: popupMenuTextStyle(),
                                    ),
                                  ),
                                  PopupMenuItem(
                                    value: SortType.ARTIST,
                                    child: Text(
                                      'Artist'.i18n,
                                      style: popupMenuTextStyle(),
                                    ),
                                  ),
                                  PopupMenuItem(
                                    value: SortType.DATE_ADDED,
                                    child: Text(
                                      'Date added'.i18n,
                                      style: popupMenuTextStyle(),
                                    ),
                                  ),
                                ],
                            child: Icon(
                              Icons.sort,
                              size: 32.0,
                              semanticLabel: 'Sort playlist'.i18n,
                            ),
                          ),
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
                          Container(width: 4.0),
                        ],
                      ],
                    ),
                  ],
                );
              },
            ),
            const FreezerDivider(),
            Builder(
              builder: (context) {
                final sortedTracks = sorted;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: List.generate(sortedTracks.length, (i) {
                    Track t = sortedTracks[i];
                    return TrackTile(
                      t,
                      showPlatformBadge: playlist.platformId == 'local',
                      onTap: () {
                        Playlist p = Playlist(
                          title: playlist.title,
                          id: playlist.id,
                          platformId: playlist.platformId,
                          trackCount: playlist.trackCount,
                          tracks: sortedTracks,
                        );
                        GetIt.I<AudioPlayerHandler>().playFromPlaylist(
                          p,
                          t.id!,
                          sort: _sort,
                        );
                      },
                      onHold: () {
                        MenuSheet m = MenuSheet();
                        m.defaultTrackMenu(
                          t,
                          context: context,
                          options: [
                            (playlist.platformId == 'local' ||
                                    playlist.editable == true ||
                                    (playlist.user?.id != null &&
                                        playlist.user?.id ==
                                            PlatformManager.instance
                                                .getPlatform(
                                                  playlist.platformId,
                                                )
                                                .currentUserId))
                                ? m.removeFromPlaylist(
                                    t,
                                    playlist,
                                    context,
                                    onRemove: () {
                                      setState(() {
                                        playlist.tracks?.removeWhere(
                                          (track) => track.id == t.id,
                                        );
                                        playlist.trackCount =
                                            (playlist.trackCount ?? 1) - 1;
                                      });
                                    },
                                  )
                                : const SizedBox(width: 0, height: 0),
                          ],
                        );
                      },
                    );
                  }),
                );
              },
            ),
            if (_loading)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    CircularProgressIndicator(
                      color: Theme.of(context).primaryColor,
                    ),
                  ],
                ),
              ),
            if (_error) const ErrorScreen(),
          ],
        ),
      ),
    );
  }
}

class MakePlaylistOffline extends StatefulWidget {
  final Playlist playlist;
  final double size;
  const MakePlaylistOffline(this.playlist, {super.key, this.size = 20.0});

  @override
  _MakePlaylistOfflineState createState() => _MakePlaylistOfflineState();
}

class _MakePlaylistOfflineState extends State<MakePlaylistOffline> {
  late Playlist playlist;
  bool _offline = false;
  StreamSubscription<void>? _offlineLibrarySub;

  @override
  void initState() {
    super.initState();
    _offlineLibrarySub = downloadManager.offlineLibraryChanged.listen((_) {
      _refreshOfflineState();
    });
    _refreshOfflineState();
  }

  Future<void> _refreshOfflineState() async {
    final offline = await downloadManager.checkOffline(
      playlist: widget.playlist,
    );
    if (mounted && offline != _offline) setState(() => _offline = offline);
  }

  @override
  void dispose() {
    _offlineLibrarySub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isLocal =
        widget.playlist.platformId == 'local' ||
        (widget.playlist.id?.startsWith('local_') ?? false);
    final supportsDownload =
        isLocal ||
        (PlatformRegistry.instance
                .get(widget.playlist.platformId)
                ?.capabilities
                .supportsDownload ==
            true);
    if (!supportsDownload || widget.playlist.disableDownload == true) {
      return const SizedBox.shrink();
    }
    return TextButton(
      style: ButtonStyle(
        overlayColor: WidgetStateProperty.resolveWith<Color?>((
          Set<WidgetState> states,
        ) {
          if (states.contains(WidgetState.pressed)) {
            return Theme.of(context).primaryColor.withValues(alpha: 0.3);
          }
          return null;
        }),
      ),
      child: Row(
        children: <Widget>[
          Icon(_offline ? Icons.wifi_off : Icons.wifi, size: widget.size),
          Container(width: 4),
          Text('Offline'.i18n),
        ],
      ),
      onPressed: () async {
        if (!_offline) {
          //Add to offline
          await downloadManager.addOfflinePlaylist(
            widget.playlist,
            private: true,
          );
          MenuSheet().showDownloadStartedToast();
          setState(() {
            _offline = true;
          });
          return;
        }
        await downloadManager.removeOfflinePlaylist(
          widget.playlist.id!,
          platformId: widget.playlist.platformId,
        );
        Fluttertoast.showToast(
          msg: 'Playlist removed from offline!'.i18n,
          gravity: ToastGravity.BOTTOM,
          toastLength: Toast.LENGTH_SHORT,
        );
        setState(() {
          _offline = false;
        });
      },
    );
  }
}

class ShowScreen extends StatefulWidget {
  final Show show;
  const ShowScreen(this.show, {super.key});

  @override
  _ShowScreenState createState() => _ShowScreenState();
}

class _ShowScreenState extends State<ShowScreen> {
  late Show _show;
  bool _loading = true;
  bool _loadingMore = false;
  bool _loadingAll = false;
  bool _hasMore = true;
  int _loadVersion = 0;
  int _nextEpisodeStart = 0;
  bool _error = false;
  List<ShowEpisode> _episodes = [];
  Sorting _sort = Sorting(sourceType: SortSourceTypes.SHOWS);
  String _filter = '';
  final ScrollController _scrollController = ScrollController();

  List<ShowEpisode> get _sorted {
    List<ShowEpisode> episodes = List.from(
      _episodes.where(
        (a) => a.title!.toLowerCase().contains(_filter.toLowerCase()),
      ),
    );
    switch (_sort.type) {
      case SortType.DEFAULT:
        break;
      case SortType.ALPHABETIC:
        episodes.sort(
          (a, b) => a.title!.toLowerCase().compareTo(b.title!.toLowerCase()),
        );
        break;
      default:
        break;
    }
    if (_sort.reverse) return episodes.reversed.toList();
    return episodes;
  }

  Future<void> _load() async {
    if (_loadingMore || _loadingAll || !_hasMore) return;
    final version = _loadVersion;
    setState(() => _loadingMore = true);
    PaginatedShowEpisodeList page;
    try {
      page = await PlatformManager.instance
          .getPlatform(_show.platformId)
          .getShowEpisodesPage(_show.id!, start: _nextEpisodeStart);
    } catch (e) {
      if (!mounted || version != _loadVersion) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = _episodes.isEmpty;
      });
      return;
    }
    if (!mounted || version != _loadVersion) return;
    setState(() {
      _nextEpisodeStart += page.episodes.length;
      final previousCount = _episodes.length;
      final knownIds = _episodes.map((episode) => episode.id).toSet();
      _episodes.addAll(
        page.episodes.where((episode) => knownIds.add(episode.id)),
      );
      _hasMore = page.hasMore && _episodes.length > previousCount;
      _updateShowMetadata();
      _loading = false;
      _loadingMore = false;
      _error = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _maybeLoadMoreEpisodes();
    });
  }

  Future<void> _loadAllEpisodes() async {
    if (_loadingAll || !_hasMore) return;
    final version = ++_loadVersion;
    setState(() {
      _loadingAll = true;
      _loading = true;
      _loadingMore = false;
    });
    try {
      final episodes = await PlatformManager.instance
          .getPlatform(_show.platformId)
          .getShowEpisodes(_show.id!);
      if (!mounted || version != _loadVersion) return;
      setState(() {
        _episodes = episodes;
        _nextEpisodeStart = episodes.length;
        _hasMore = false;
        _updateShowMetadata();
        _loading = false;
        _loadingAll = false;
        _error = false;
      });
    } catch (_) {
      if (!mounted || version != _loadVersion) return;
      setState(() {
        _loading = false;
        _loadingAll = false;
        _error = _episodes.isEmpty;
      });
    }
  }

  void _updateShowMetadata() {
    final e = _episodes;
    if (e.isEmpty) return;
    final isEpisodeCollection = e.first.collection != null;
    if (isEpisodeCollection) {
      final collection = e.first.collection!;
      _show = Show(
        id: _show.id,
        name: _show.name?.isNotEmpty == true ? _show.name : collection.name,
        creator: _show.creator,
        description: collection.description?.isNotEmpty == true
            ? collection.description
            : _show.description,
        art: _show.art ?? collection.art,
        platformId: _show.platformId,
      );
    } else if (!isEpisodeCollection && e.first.show != null) {
      final fetchedShow = e.first.show!;
      _show = Show(
        id: _show.id ?? fetchedShow.id,
        name: _show.name?.isNotEmpty == true ? _show.name : fetchedShow.name,
        creator: fetchedShow.creator ?? _show.creator,
        description: fetchedShow.description ?? _show.description,
        art: fetchedShow.art ?? _show.art,
        platformId: _show.platformId,
      );
    }
  }

  void _maybeLoadMoreEpisodes() {
    if (!_hasMore ||
        _loadingMore ||
        _loadingAll ||
        !_scrollController.hasClients) {
      return;
    }
    final position = _scrollController.position;
    if (position.extentAfter <= position.viewportDimension * 1.25) {
      _load();
    }
  }

  Future _reverse() async {
    setState(() => _sort.reverse = !_sort.reverse);
    if (_hasMore) _loadAllEpisodes();
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
    super.initState();
    //Restore sort
    int? index = Sorting.index(SortSourceTypes.SHOWS);
    if (index != null) {
      _sort = cache.sorts[index];
    }

    _show = widget.show;
    _scrollController.addListener(_maybeLoadMoreEpisodes);
    if (_sort.type != SortType.DEFAULT || _sort.reverse) {
      _loadAllEpisodes();
    } else {
      _load();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final displayedEpisodes = !_loading && !_error ? _sorted : <ShowEpisode>[];
    return Scaffold(
      appBar: FreezerAppBar(_show.name!),
      body: MobileScrollbar(
        controller: _scrollController,
        backgroundColor: Theme.of(context).primaryColor,
        childBuilder: (scrollController, scrollPhysics) => ListView(
          controller: scrollController,
          physics: scrollPhysics,
          children: <Widget>[
            //Show art, name, description
            Container(
              color: Theme.of(context).scaffoldBackgroundColor,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final isWideScreen = constraints.maxWidth > 668;
                  final imageSize = isWideScreen
                      ? 250.0
                      : MediaQuery.of(context).size.width * 0.5;

                  if (isWideScreen) {
                    // Row layout for wide screens
                    return Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          ZoomableImage(
                            url: _show.art?.full ?? '',
                            width: imageSize,
                            rounded: true,
                          ),
                          const SizedBox(width: 24.0),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Text(
                                  _show.name!,
                                  textAlign: TextAlign.left,
                                  overflow: TextOverflow.ellipsis,
                                  maxLines: 2,
                                  style: const TextStyle(
                                    fontSize: 24.0,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                if (_show.creator?.isNotEmpty == true) ...[
                                  const SizedBox(height: 4.0),
                                  Text(
                                    _show.creator!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 15.0,
                                      color: Theme.of(context).disabledColor,
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 12.0),
                                Text(
                                  _show.description ?? '',
                                  maxLines: 8,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.left,
                                  style: TextStyle(
                                    fontSize: 14.0,
                                    color: Theme.of(context).disabledColor,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  } else {
                    // Column layout for narrow screens
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Container(height: 4.0),
                        ZoomableImage(
                          url: _show.art?.full ?? '',
                          width: imageSize,
                          rounded: true,
                        ),
                        Container(height: 8.0),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16.0),
                          child: Text(
                            _show.name!,
                            textAlign: TextAlign.center,
                            overflow: TextOverflow.ellipsis,
                            maxLines: 2,
                            style: const TextStyle(
                              fontSize: 20.0,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        Container(height: 8.0),
                        if (_show.creator?.isNotEmpty == true)
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16.0,
                            ),
                            child: Text(
                              _show.creator!,
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14.0,
                                color: Theme.of(context).disabledColor,
                              ),
                            ),
                          ),
                        Container(height: 8.0),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16.0),
                          child: Text(
                            _show.description ?? '',
                            textAlign: TextAlign.center,
                            overflow: TextOverflow.ellipsis,
                            maxLines: 6,
                            style: const TextStyle(fontSize: 14.0),
                          ),
                        ),
                        Container(height: 8.0),
                      ],
                    );
                  }
                },
              ),
            ),
            const FreezerDivider(),
            Row(
              mainAxisSize: MainAxisSize.max,
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: <Widget>[
                FutureBuilder<bool>(
                  future: PlatformManager.instance
                      .getPlatform(_show.platformId)
                      .isFavoriteShow(_show.id ?? ''), // Asynchronous call
                  builder: (context, snapshot) {
                    // Check the state of the future
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return CircularProgressIndicator(
                        color: Theme.of(context).primaryColor,
                      );
                    } else if (snapshot.hasError) {
                      return const Icon(Icons.error); // Handle errors here
                    } else {
                      bool isFavorited =
                          snapshot.data ?? false; // Default to false if null

                      return TextButton(
                        style: ButtonStyle(
                          overlayColor: WidgetStateProperty.resolveWith<Color?>(
                            (Set<WidgetState> states) {
                              if (states.contains(WidgetState.pressed)) {
                                return Theme.of(
                                  context,
                                ).primaryColor.withValues(alpha: 0.3);
                              }
                              return null;
                            },
                          ),
                        ),
                        child: Row(
                          children: <Widget>[
                            Icon(
                              isFavorited
                                  ? Icons.favorite
                                  : Icons.favorite_outline,
                              size: 32,
                              semanticLabel: isFavorited
                                  ? 'Unlove'.i18n
                                  : 'Love'.i18n,
                            ),
                            Container(width: 4),
                            Text('Library'.i18n),
                          ],
                        ),
                        onPressed: () async {
                          // Add to library
                          if (!isFavorited) {
                            await PlatformManager.instance
                                .getPlatform(_show.platformId)
                                .addFavoriteShow(_show.id!);
                            setState(() => isFavorited = true);
                            Fluttertoast.showToast(
                              msg: 'Added to library'.i18n,
                              toastLength: Toast.LENGTH_SHORT,
                              gravity: ToastGravity.BOTTOM,
                            );
                          } else {
                            // Remove
                            await PlatformManager.instance
                                .getPlatform(_show.platformId)
                                .removeFavoriteShow(_show.id!);
                            setState(() => isFavorited = false);
                            Fluttertoast.showToast(
                              msg: 'Show removed from library!'.i18n,
                              toastLength: Toast.LENGTH_SHORT,
                              gravity: ToastGravity.BOTTOM,
                            );
                          }
                        },
                      );
                    }
                  },
                ),
                PopupMenuButton(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  onSelected: (SortType s) async {
                    setState(() => _sort.type = s);
                    if (_hasMore) _loadAllEpisodes();
                    // Save to cache
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
                      child: Text(
                        'Alphabetic'.i18n,
                        style: popupMenuTextStyle(),
                      ),
                    ),
                  ],
                  child: Row(
                    children: [
                      const Icon(Icons.sort, size: 32.0),
                      const SizedBox(width: 8),
                      Text('Sort'.i18n),
                    ],
                  ),
                ),
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
                      Icon(
                        _sort.reverse
                            ? FontAwesome5.sort_alpha_up
                            : FontAwesome5.sort_alpha_down,
                        semanticLabel: _sort.reverse
                            ? 'Sort descending'.i18n
                            : 'Sort ascending'.i18n,
                      ),
                      Container(width: 4),
                      Text(
                        _sort.reverse
                            ? 'Sort descending'.i18n
                            : 'Sort ascending'.i18n,
                      ),
                    ],
                  ),
                  onPressed: () => _reverse(),
                ),
                Container(width: 4.0),
              ],
            ),
            const FreezerDivider(),
            // Search
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: TextField(
                cursorColor: Theme.of(context).primaryColor,
                onChanged: (String s) {
                  setState(() => _filter = s);
                  if (s.isNotEmpty && _hasMore) _loadAllEpisodes();
                },
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

            // Error
            if (_error) const ErrorScreen(),

            // Loading
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

            // Data
            if (!_loading && !_error)
              ...List.generate(displayedEpisodes.length, (int i) {
                ShowEpisode e = displayedEpisodes[i];
                return ShowEpisodeTile(
                  e,
                  trailing: IconButton(
                    icon: Icon(Icons.more_vert, semanticLabel: 'Options'.i18n),
                    onPressed: () {
                      MenuSheet m = MenuSheet();
                      m.defaultShowEpisodeMenu(_show, e, context: context);
                    },
                  ),
                  onTap: () async {
                    await GetIt.I<AudioPlayerHandler>().playShowEpisode(
                      _show,
                      displayedEpisodes,
                      index: i,
                      loadMore:
                          _hasMore &&
                          _sort.type == SortType.DEFAULT &&
                          !_sort.reverse &&
                          _filter.isEmpty,
                    );
                  },
                );
              }),
            if (!_loading && _loadingMore)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              ),
          ],
        ),
      ),
    );
  }
}
