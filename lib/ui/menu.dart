import 'package:logging/logging.dart';
import 'package:saturn/platform/platform_manager.dart';
import 'package:saturn/platform/platform_registry.dart';
// ignore_for_file: use_build_context_synchronously

import 'dart:async';
import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:material_ui/material_ui.dart';
import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:silky_scroll/silky_scroll.dart';
import 'package:saturn/ui/smooth_scroll_config.dart';

import '../api/cache.dart';
import '../api/definitions.dart';
import '../api/download.dart';
import '../service/audio_service.dart';
import '../platform/soundcloud/soundcloud_client.dart';
import '../translations.i18n.dart';
import '../ui/cached_image.dart';
import '../ui/mosaic_image.dart';
import '../ui/error.dart';
import 'toast.dart';
import '../router/app_router.dart';
import 'local_playlists.dart';

class MenuSheet {
  Function navigateCallback;
  final bool closeOnAction;

  bool _isPodcastEpisodeTrack(Track track) {
    bool matches(MediaItem? item) =>
        item?.id == track.id && item?.extras?['show'] is String;

    final handler = GetIt.I<AudioPlayerHandler>();
    return matches(handler.mediaItem.value) ||
        handler.queue.value.any(matches);
  }

  // Use no-op callback if not provided
  MenuSheet({Function? navigateCallback, this.closeOnAction = true})
    : navigateCallback = navigateCallback ?? (() {});

  bool _isFavoritesPlaylist(Playlist playlist) =>
      playlist.id == 'favorites_${playlist.platformId}';

  bool _isCurrentTrack(Track track, MediaItem? currentItem) {
    if (currentItem == null) return false;
    final isRadio = AudioPlayerHandler.isRadioItem(currentItem);
    final radioTrackId = currentItem.extras?['radioTrackId'];
    final currentTrackId = isRadio
        ? radioTrackId?.toString()
        : currentItem.id;
    final currentPlatformId =
        currentItem.extras?['platformId']?.toString() ?? track.platformId;
    return currentTrackId == track.id &&
        currentPlatformId == track.platformId;
  }

  /// Extra menu entries a platform wants to show for [item] (generic hook).
  List<Widget> _platformOptions(
    BuildContext context,
    String? platformId,
    Object item,
  ) {
    if (platformId == null) return const [];
    return PlatformRegistry.instance
            .get(platformId)
            ?.getExtraMenuOptions(context, item) ??
        const [];
  }

  //===================
  // DEFAULT
  //===================

  void show(BuildContext context, List<Widget> options) {
    final bodyContext = isShellRouteContext(context)
        ? bodyOverlayNavigatorKey.currentContext
        : null;
    final sheetContext = bodyContext ?? context;
    if (bodyContext != null) bodyOverlayActive.value = true;
    showModalBottomSheet<void>(
      isScrollControlled: true,
      context: sheetContext,
      builder: (BuildContext context) {
        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight:
                (MediaQuery.of(context).orientation == Orientation.landscape)
                ? 220
                : 350,
          ),
          child: SilkySingleChildScrollView(
        silkyConfig: silkyScrollConfig,child: Column(children: options)),
        );
      },
    ).whenComplete(() {
      if (bodyContext != null) bodyOverlayActive.value = false;
    });
  }

  //Show popup menu (anchored to button position)
  Future<void> showPopup(
    BuildContext context,
    List<Widget> options,
    RelativeRect position,
  ) async {
    // Convert ListTile widgets to PopupMenuItems
    final items = options
        .map((widget) {
          if (widget is ListTile) {
            return PopupMenuItem<VoidCallback>(
              padding: EdgeInsets.zero,
              onTap: () {
                // Schedule the onTap callback to run after the popup menu dismisses
                // This avoids navigator lock errors
                if (widget.onTap != null) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    widget.onTap!();
                  });
                }
              },
              child: ListTile(
                leading: widget.leading,
                title: widget.title,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16.0),
                dense: true,
              ),
            );
          }
          return null;
        })
        .whereType<PopupMenuItem<VoidCallback>>()
        .toList();

    await showMenu<VoidCallback>(
      context: context,
      position: position,
      items: items,
    );
  }

  //===================
  // TRACK
  //===================

  void showWithTrack(BuildContext context, Track track, List<Widget> options) {
    final bodyContext = isShellRouteContext(context)
        ? bodyOverlayNavigatorKey.currentContext
        : null;
    final sheetContext = bodyContext ?? context;
    if (bodyContext != null) bodyOverlayActive.value = true;
    showModalBottomSheet<void>(
      isScrollControlled: true,
      context: sheetContext,
      builder: (BuildContext context) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(height: 16.0),
            Row(
              mainAxisSize: MainAxisSize.max,
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: <Widget>[
                Semantics(
                  label: 'Album art'.i18n,
                  image: true,
                  child: CachedImage(
                    url: track.albumArt?.full ?? '',
                    height: 128,
                    width: 128,
                  ),
                ),
                SizedBox(
                  width: 240.0,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        track.title ?? '',
                        maxLines: 1,
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 22.0,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        track.artistString ?? '',
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        style: const TextStyle(fontSize: 20.0),
                      ),
                      Container(height: 8.0),
                      Text(
                        track.album?.title ?? '',
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                      Text(
                        track.durationString ?? '',
                        style: const TextStyle(
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                      if (track.unavailable == true) ...[
                        Container(height: 4.0),
                        Text(
                          track.unavailableMessage,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.redAccent,
                            fontSize: 13.0,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            Container(height: 16.0),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight:
                    (MediaQuery.of(context).orientation ==
                        Orientation.landscape)
                    ? 200
                    : 350,
              ),
              child: SilkySingleChildScrollView(
            silkyConfig: silkyScrollConfig,child: Column(children: options)),
            ),
          ],
        );
      },
    ).whenComplete(() {
      if (bodyContext != null) bodyOverlayActive.value = false;
    });
  }

  //Default track options
  void defaultTrackMenu(
    Track track, {
    required BuildContext context,
    List<Widget> options = const [],
    Function? onRemove,
  }) {
    List<Widget> queueOptions = [];
    final mediaItem = GetIt.I<AudioPlayerHandler>().mediaItem.value;
    final isCurrentRadioStation =
        mediaItem != null &&
        AudioPlayerHandler.isRadioItem(mediaItem) &&
        track.id == mediaItem.id;
    final isRadio =
        track.id?.startsWith('radio:') == true || isCurrentRadioStation;
    final radioTrackId = isCurrentRadioStation
        ? (mediaItem.extras?['radioTrackId'] as String?)
        : null;
    final isRadioWithoutSong =
        isRadio &&
        (radioTrackId == null || radioTrackId.isEmpty) &&
        track.platformId != 'youtube_music';

    if (isRadioWithoutSong) {
      showWithTrack(context, track, [...options]);
      return;
    }

    final effectiveTrack =
        (isRadio && radioTrackId != null && radioTrackId.isNotEmpty)
        ? Track(
            id: radioTrackId,
            title: track.title,
            album: track.album,
            artists: track.artists,
            navigableArtists: track.navigableArtists,
            albumArt: track.albumArt,
            platformId: track.platformId,
          )
        : track;

    final capabilities = PlatformRegistry.instance
        .get(effectiveTrack.platformId)
        ?.capabilities;
    final isPodcastEpisode = _isPodcastEpisodeTrack(effectiveTrack);

    showWithTrack(context, effectiveTrack, [
      ...queueOptions,
      if (!AudioPlayerHandler.isRadioItem(mediaItem) &&
          !_isCurrentTrack(effectiveTrack, mediaItem)) ...[
        addToQueueNext(effectiveTrack, context),
        addToQueue(effectiveTrack, context),
      ],
      if (capabilities?.supportsLibrarySync == true)
        (cache.checkTrackFavorite(effectiveTrack))
            ? removeFavoriteTrack(effectiveTrack, context, onUpdate: onRemove)
            : addTrackFavorite(effectiveTrack, context),
      if (capabilities?.supportsPlaylistEdit == true)
        addToPlaylist(effectiveTrack, context),
      if (!isPodcastEpisode && capabilities?.supportsDownload == true) ...[
        offlineTrack(effectiveTrack, context),
        downloadTrack(effectiveTrack, context),
      ],
      shareTile(
        'track',
        effectiveTrack.id ?? '',
        platformId: effectiveTrack.platformId,
      ),
      if (capabilities?.supportsSmartRadio == true)
        playMix(effectiveTrack, context),
      if (capabilities?.supportsTrackPage == true)
        showTrack(effectiveTrack, context),
      if (effectiveTrack.album != null && effectiveTrack.album!.id != null)
        showAlbum(effectiveTrack.album!, context),
      ...List.generate(
        (effectiveTrack.navigableArtists ?? effectiveTrack.artists)?.length ??
            0,
        (i) => showArtist(
          (effectiveTrack.navigableArtists ?? effectiveTrack.artists)![i],
          context,
        ),
      ),
      ..._platformOptions(context, effectiveTrack.platformId, effectiveTrack),
      ...options,
    ]);
  }

  //Default track popup menu (shows as popup instead of bottom sheet)
  Future<void> defaultTrackPopup(
    Track track, {
    required BuildContext context,
    required RelativeRect position,
    List<Widget> leadingOptions = const [],
    List<Widget> options = const [],
    Function? onRemove,
  }) async {
    final mediaItem = GetIt.I<AudioPlayerHandler>().mediaItem.value;
    final isCurrentRadioStation =
        mediaItem != null &&
        AudioPlayerHandler.isRadioItem(mediaItem) &&
        track.id == mediaItem.id;
    final isRadio =
        track.id?.startsWith('radio:') == true || isCurrentRadioStation;
    final radioTrackId = isCurrentRadioStation
        ? (mediaItem.extras?['radioTrackId'] as String?)
        : null;
    final isRadioWithoutSong =
        isRadio &&
        (radioTrackId == null || radioTrackId.isEmpty) &&
        track.platformId != 'youtube_music';

    if (isRadioWithoutSong) {
      await showPopup(context, [...leadingOptions, ...options], position);
      return;
    }

    final effectiveTrack =
        (isRadio && radioTrackId != null && radioTrackId.isNotEmpty)
        ? Track(
            id: radioTrackId,
            title: track.title,
            album: track.album,
            artists: track.artists,
            navigableArtists: track.navigableArtists,
            albumArt: track.albumArt,
            platformId: track.platformId,
          )
        : track;

    final capabilities = PlatformRegistry.instance
        .get(effectiveTrack.platformId)
        ?.capabilities;
    final isPodcastEpisode = _isPodcastEpisodeTrack(effectiveTrack);
    await showPopup(context, [
      ...leadingOptions,
      if (!AudioPlayerHandler.isRadioItem(mediaItem) &&
          !_isCurrentTrack(effectiveTrack, mediaItem)) ...[
        addToQueueNext(effectiveTrack, context),
        addToQueue(effectiveTrack, context),
      ],
      if (capabilities?.supportsLibrarySync == true)
        (cache.checkTrackFavorite(effectiveTrack))
            ? removeFavoriteTrack(effectiveTrack, context, onUpdate: onRemove)
            : addTrackFavorite(effectiveTrack, context),
      if (capabilities?.supportsPlaylistEdit == true)
        addToPlaylist(effectiveTrack, context),
      if (!isPodcastEpisode && capabilities?.supportsDownload == true) ...[
        offlineTrack(effectiveTrack, context),
        downloadTrack(effectiveTrack, context),
      ],
      shareTile(
        'track',
        effectiveTrack.id ?? '',
        platformId: effectiveTrack.platformId,
      ),
      if (capabilities?.supportsSmartRadio == true)
        playMix(effectiveTrack, context),
      if (capabilities?.supportsTrackPage == true)
        showTrack(effectiveTrack, context),
      if (effectiveTrack.album != null && effectiveTrack.album!.id != null)
        showAlbum(effectiveTrack.album!, context),
      ...List.generate(
        (effectiveTrack.navigableArtists ?? effectiveTrack.artists)?.length ??
            0,
        (i) => showArtist(
          (effectiveTrack.navigableArtists ?? effectiveTrack.artists)![i],
          context,
        ),
      ),
      ..._platformOptions(context, effectiveTrack.platformId, effectiveTrack),
      ...options,
    ], position);
  }

  //===================
  // TRACK OPTIONS
  //===================

  Widget addToQueueNext(Track t, BuildContext context) => ListTile(
    title: Text('Play next'.i18n),
    leading: const Icon(Icons.playlist_play),
    onTap: () async {
      if (t.unavailable == true) {
        Fluttertoast.showToast(msg: t.unavailableMessage);
        return;
      }
      //-1 = next
      await GetIt.I<AudioPlayerHandler>().insertQueueItem(-1, t.toMediaItem());
      Fluttertoast.showToast(
        msg: 'Playing next'.i18n,
        gravity: ToastGravity.BOTTOM,
        toastLength: Toast.LENGTH_SHORT,
      );
      if (context.mounted) _close(context);
    },
  );

  Widget addToQueue(Track t, BuildContext context) => ListTile(
    title: Text('Add to queue'.i18n),
    leading: const Icon(Icons.queue_music),
    onTap: () async {
      if (t.unavailable == true) {
        Fluttertoast.showToast(msg: t.unavailableMessage);
        return;
      }
      await GetIt.I<AudioPlayerHandler>().addQueueItem(t.toMediaItem());
      Fluttertoast.showToast(
        msg: 'Queued'.i18n,
        gravity: ToastGravity.BOTTOM,
        toastLength: Toast.LENGTH_SHORT,
      );
      if (context.mounted) _close(context);
    },
  );

  Widget addTrackFavorite(Track t, BuildContext context) => ListTile(
    title: Text('Add track to favorites'.i18n),
    leading: const Icon(Icons.favorite),
    onTap: () async {
      Logger.root.info(
        '[UI] MenuSheet addTrackFavorite: id=${t.id}, platformId=${t.platformId}',
      );
      try {
        await PlatformRegistry.instance
            .get(t.platformId)
            ?.addFavoriteTrack(t.id!);
      } catch (error, stackTrace) {
        Logger.root.warning(
          'Could not favorite track ${t.id}',
          error,
          stackTrace,
        );
        Fluttertoast.showToast(msg: 'Could not add track to favorites: $error');
        return;
      }
      //Make track offline, if favorites are offline
      Playlist p = Playlist(
        id: 'favorites_${t.platformId}',
        platformId: t.platformId,
      );
      if (await downloadManager.checkOffline(playlist: p)) {
        downloadManager.addOfflinePlaylist(p);
      }
      Fluttertoast.showToast(
        msg: 'Added to library'.i18n,
        gravity: ToastGravity.BOTTOM,
        toastLength: Toast.LENGTH_SHORT,
      );
      cache.updateTrackFavorite(t, favorite: true);
      await cache.save();
      if (context.mounted) _close(context);
    },
  );

  Widget downloadTrack(Track t, BuildContext context) => FutureBuilder<bool>(
    future: downloadManager.isQueued(t.id ?? ''),
    builder: (context, snapshot) {
      if (snapshot.data == true) return const SizedBox();
      return ListTile(
        title: Text('Download'.i18n),
        leading: const Icon(Icons.file_download),
        onTap: () async {
          if (t.unavailable == true) {
            Fluttertoast.showToast(msg: t.unavailableMessage);
            return;
          }
          if (PlatformRegistry.instance
                  .get(t.platformId)
                  ?.capabilities
                  .supportsDownload !=
              true) {
            return;
          }
          if (await downloadManager.addOfflineTrack(
                t,
                private: false,
                isSingleton: true,
              ) !=
              false) {
            showDownloadStartedToast();
          }
          if (context.mounted) _close(context);
        },
      );
    },
  );

  Widget addToPlaylist(Track track, BuildContext context) {
    final trackId = track.id;
    final platformId = track.platformId;
    return ListTile(
      title: Text('Add to playlist'.i18n),
      leading: const Icon(Icons.playlist_add),
      onTap: () async {
        if (trackId == null) return;
        await showDialog(
          context: context,
          builder: (context) => SelectPlaylistDialog(
            track: track,
            callback: (Playlist playlist) async {
              await PlatformManager.instance
                  .getPlatform(platformId)
                  .addToPlaylist(trackId, playlist.id!);
              if (await downloadManager.checkOffline(playlist: playlist)) {
                downloadManager.addOfflinePlaylist(playlist);
              }
            },
          ),
        );
        if (context.mounted) _close(context);
      },
    );
  }

  Widget removeFromPlaylist(
    Track t,
    Playlist p,
    BuildContext context, {
    Function? onRemove,
  }) => ListTile(
    title: Text('Remove from playlist'.i18n),
    leading: const Icon(Icons.delete),
    onTap: () async {
      if (p.platformId == 'local') {
        final localId = p.id!.replaceFirst('local_', '');
        await downloadManager.localPlaylistManager.removeTrackFromPlaylist(
          localId,
          '${t.platformId}:${t.id!}',
        );
        await downloadManager.localPlaylistManager.removeTrackFromPlaylist(
          localId,
          t.id!,
        );
      } else {
        await PlatformManager.instance
            .getPlatform(t.platformId)
            .removeFromPlaylist(t.id!, p.id!);
      }
      if (onRemove != null) onRemove();
      Fluttertoast.showToast(
        msg: 'Track removed from'.i18n + ' ${p.title}',
        toastLength: Toast.LENGTH_SHORT,
        gravity: ToastGravity.BOTTOM,
      );
      if (context.mounted) _close(context);
    },
  );

  Widget removeFavoriteTrack(Track t, BuildContext context, {onUpdate}) =>
      ListTile(
        title: Text('Remove favorite'.i18n),
        leading: const Icon(Icons.delete),
        onTap: () async {
          Logger.root.info(
            '[UI] MenuSheet removeFavoriteTrack: id=${t.id}, platformId=${t.platformId}',
          );
          try {
            await PlatformRegistry.instance
                .get(t.platformId)
                ?.removeFavoriteTrack(t.id!);
          } catch (error, stackTrace) {
            Logger.root.warning(
              'Could not unfavorite track ${t.id}',
              error,
              stackTrace,
            );
            Fluttertoast.showToast(
              msg: 'Could not remove track favorite: $error',
            );
            return;
          }
          //Check if favorites playlist is offline, update it
          Playlist p = Playlist(
            id: 'favorites_${t.platformId}',
            platformId: t.platformId,
          );
          if (await downloadManager.checkOffline(playlist: p)) {
            await downloadManager.addOfflinePlaylist(p);
          }
          cache.updateTrackFavorite(t, favorite: false);
          await cache.save();
          Fluttertoast.showToast(
            msg: 'Track removed from library'.i18n,
            toastLength: Toast.LENGTH_SHORT,
            gravity: ToastGravity.BOTTOM,
          );
          if (onUpdate != null) onUpdate();
          if (context.mounted) _close(context);
        },
      );

  //Redirect to artist page (ie from track)
  Widget showArtist(Artist a, BuildContext context) => ListTile(
    title: Text(
      'Go to'.i18n + ' ${a.name}',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    leading: const Icon(Icons.recent_actors),
    onTap: () {
      final id = a.id;
      if (id == null || id.isEmpty) return;
      _close(context);
      navigateCallback();
      appRouter.push('/artist/${Uri.encodeComponent(id)}', extra: a);
    },
  );

  Widget showPodcast(Show show, BuildContext context) => ListTile(
    title: Text(
      'Go to'.i18n + ' ${show.name ?? 'Podcast'.i18n}',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    leading: const Icon(Icons.podcasts),
    onTap: () {
      final id = show.id;
      if (id == null || id.isEmpty) return;
      _close(context);
      navigateCallback();
      appRouter.push('/show/${Uri.encodeComponent(id)}', extra: show);
    },
  );

  Widget showTrack(Track track, BuildContext context) => ListTile(
    title: Text(
      'Track details'.i18n,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    leading: const Icon(Icons.info_outline),
    onTap: () {
      final id = track.id;
      if (id == null || id.isEmpty) return;
      _close(context);
      navigateCallback();
      appRouter.push(
        '/track/${Uri.encodeComponent(id)}?platform=${track.platformId}',
        extra: track,
      );
    },
  );

  Widget showAlbum(Album a, BuildContext context) => ListTile(
    title: Text(
      'Go to'.i18n + ' ${a.title ?? 'album'.i18n}',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    leading: const Icon(Icons.album),
    onTap: () {
      final id = a.id;
      if (id == null || id.isEmpty) return;
      _close(context);
      navigateCallback();
      appRouter.push('/album/$id', extra: a);
    },
  );

  Widget playMix(Track track, BuildContext context) => ListTile(
    title: Text('Play mix'.i18n),
    leading: const Icon(Icons.online_prediction),
    onTap: () async {
      GetIt.I<AudioPlayerHandler>().playMix(
        track.id!,
        track.title!,
        platformId: track.platformId,
      );
      if (context.mounted) _close(context);
    },
  );

  Widget offlineTrack(Track track, BuildContext context) => FutureBuilder(
    future: downloadManager.checkOffline(track: track),
    builder: (innerContext, snapshot) {
      if (PlatformRegistry.instance
              .get(track.platformId)
              ?.capabilities
              .supportsDownload !=
          true) {
        return const SizedBox.shrink();
      }
      bool isOffline = snapshot.data ?? (track.offline ?? false);
      return ListTile(
        title: Text(isOffline ? 'Remove offline'.i18n : 'Offline'.i18n),
        leading: const Icon(Icons.offline_pin),
        onTap: () async {
          if (!isOffline && track.unavailable == true) {
            Fluttertoast.showToast(msg: track.unavailableMessage);
            return;
          }
          if (isOffline) {
            await downloadManager.removeOfflineTracks([track]);
            Fluttertoast.showToast(
              msg: 'Track removed from offline!'.i18n,
              gravity: ToastGravity.BOTTOM,
              toastLength: Toast.LENGTH_SHORT,
            );
          } else {
            await downloadManager.addOfflineTrack(track, private: true);
          }
          if (context.mounted) _close(context);
        },
      );
    },
  );

  //===================
  // ALBUM
  //===================

  //Default album options
  void defaultAlbumMenu(
    Album album, {
    required BuildContext context,
    List<Widget> options = const [],
    Function? onRemove,
  }) {
    final capabilities = PlatformRegistry.instance
        .get(album.platformId)
        ?.capabilities;
    show(context, [
      if (capabilities?.supportsLibrarySync == true)
        (album.library != null && onRemove != null)
            ? removeAlbum(album, context, onRemove: onRemove)
            : libraryAlbum(album, context),
      if (capabilities?.supportsDownload == true) ...[
        offlineAlbum(album, context),
        downloadAlbum(album, context),
      ],
      shareTile('album', album.id!, platformId: album.platformId),
      ..._platformOptions(context, album.platformId, album),
      ...options,
    ]);
  }

  //===================
  // ALBUM OPTIONS
  //===================

  Widget downloadAlbum(Album a, BuildContext context) => ListTile(
    title: Text('Download'.i18n),
    leading: const Icon(Icons.file_download),
    onTap: () async {
      if (PlatformRegistry.instance
              .get(a.platformId)
              ?.capabilities
              .supportsDownload !=
          true) {
        return;
      }
      if (context.mounted) _close(context);
      if (await downloadManager.addOfflineAlbum(a, private: false) != false) {
        showDownloadStartedToast();
      }
    },
  );

  Widget offlineAlbum(Album a, BuildContext context) => FutureBuilder(
    future: downloadManager.checkOffline(album: a),
    builder: (innerContext, snapshot) {
      if (PlatformRegistry.instance
              .get(a.platformId)
              ?.capabilities
              .supportsDownload !=
          true) {
        return const SizedBox.shrink();
      }
      final isOffline = snapshot.data ?? (a.offline ?? false);
      return ListTile(
        title: Text(isOffline ? 'Remove offline'.i18n : 'Make offline'.i18n),
        leading: const Icon(Icons.offline_pin),
        onTap: () async {
          if (isOffline) {
            await downloadManager.removeOfflineAlbum(
              a.id!,
              platformId: a.platformId,
            );
            Fluttertoast.showToast(
              msg: 'Album removed from offline!'.i18n,
              gravity: ToastGravity.BOTTOM,
              toastLength: Toast.LENGTH_SHORT,
            );
          } else {
            await PlatformManager.instance
                .getPlatform(a.platformId)
                .addFavoriteAlbum(a.id!);
            await downloadManager.addOfflineAlbum(a, private: true);
            showDownloadStartedToast();
          }
          if (context.mounted) _close(context);
        },
      );
    },
  );

  Widget libraryAlbum(Album a, BuildContext context) => ListTile(
    title: Text('Add to library'.i18n),
    leading: const Icon(Icons.library_music),
    onTap: () async {
      await PlatformManager.instance
          .getPlatform(a.platformId)
          .addFavoriteAlbum(a.id!);
      Fluttertoast.showToast(
        msg: 'Added to library'.i18n,
        gravity: ToastGravity.BOTTOM,
      );
      if (context.mounted) _close(context);
    },
  );

  //Remove album from favorites
  Widget removeAlbum(
    Album a,
    BuildContext context, {
    required Function onRemove,
  }) => ListTile(
    title: Text('Remove album'.i18n),
    leading: const Icon(Icons.delete),
    onTap: () async {
      await PlatformManager.instance
          .getPlatform(a.platformId)
          .removeFavoriteAlbum(a.id!);
      await downloadManager.removeOfflineAlbum(a.id!, platformId: a.platformId);
      Fluttertoast.showToast(
        msg: 'Album removed'.i18n,
        toastLength: Toast.LENGTH_SHORT,
        gravity: ToastGravity.BOTTOM,
      );
      onRemove();
      if (context.mounted) _close(context);
    },
  );

  //===================
  // ARTIST
  //===================

  void defaultArtistMenu(
    Artist artist, {
    required BuildContext context,
    List<Widget> options = const [],
    Function? onRemove,
  }) {
    final capabilities = PlatformRegistry.instance
        .get(artist.platformId)
        ?.capabilities;
    show(context, [
      if (capabilities?.supportsLibrarySync == true)
        (artist.library == true)
            ? removeArtist(artist, context, onRemove: onRemove)
            : favoriteArtist(artist, context),
      shareTile('artist', artist.id!, platformId: artist.platformId),
      ..._platformOptions(context, artist.platformId, artist),
      ...options,
    ]);
  }

  //===================
  // ARTIST OPTIONS
  //===================

  Widget removeArtist(Artist a, BuildContext context, {Function? onRemove}) =>
      ListTile(
        title: Text('Remove from favorites'.i18n),
        leading: const Icon(Icons.delete),
        onTap: () async {
          try {
            await PlatformManager.instance
                .getPlatform(a.platformId)
                .removeFavoriteArtist(a.id!);
          } catch (error) {
            Fluttertoast.showToast(
              msg: error is SoundCloudChallengeException
                  ? error.toString()
                  : 'Could not update artist follow'.i18n,
            );
            return;
          }
          a.library = false;
          Fluttertoast.showToast(
            msg: 'Artist removed from library'.i18n,
            toastLength: Toast.LENGTH_SHORT,
            gravity: ToastGravity.BOTTOM,
          );
          if (onRemove != null) onRemove();
          if (context.mounted) _close(context);
        },
      );

  Widget favoriteArtist(Artist a, BuildContext context) => ListTile(
    title: Text('Add to favorites'.i18n),
    leading: const Icon(Icons.favorite),
    onTap: () async {
      try {
        await PlatformManager.instance
            .getPlatform(a.platformId)
            .addFavoriteArtist(a.id!);
      } catch (error) {
        Fluttertoast.showToast(
          msg: error is SoundCloudChallengeException
              ? error.toString()
              : 'Could not update artist follow'.i18n,
        );
        return;
      }
      a.library = true;
      Fluttertoast.showToast(
        msg: 'Added to library'.i18n,
        toastLength: Toast.LENGTH_SHORT,
        gravity: ToastGravity.BOTTOM,
      );
      if (context.mounted) _close(context);
    },
  );

  //===================
  // PLAYLIST
  //===================

  void defaultPlaylistMenu(
    Playlist playlist, {
    required BuildContext context,
    List<Widget> options = const [],
    Function? onRemove,
    Function? onUpdate,
  }) {
    final isLocal =
        playlist.id?.startsWith('local_') == true ||
        playlist.platformId == 'local';
    if (isLocal) {
      show(context, [
        editLocalPlaylist(playlist, context, onUpdate: onUpdate),
        exportLocalPlaylist(playlist, context),
        addPlaylistOffline(playlist, context),
        downloadPlaylist(playlist, context),
        deleteLocalPlaylist(playlist, context, onRemove: onRemove),
        ...options,
      ]);
      return;
    }

    final capabilities = PlatformRegistry.instance
        .get(playlist.platformId)
        ?.capabilities;
    show(context, [
      if (capabilities?.supportsLibrarySync == true)
        cache.checkPlaylistFavorite(playlist)
            ? removePlaylistLibrary(playlist, context, onRemove: onRemove)
            : addPlaylistLibrary(playlist, context),
      if (capabilities?.supportsDownload == true) ...[
        addPlaylistOffline(playlist, context),
        downloadPlaylist(playlist, context),
      ],
      shareTile('playlist', playlist.id!, platformId: playlist.platformId),
      if (capabilities?.supportsPlaylistEdit == true &&
          playlist.editable == true)
        editPlaylist(playlist, context: context, onUpdate: onUpdate),
      ..._platformOptions(context, playlist.platformId, playlist),
      ...options,
    ]);
  }

  //===================
  // PLAYLIST OPTIONS
  //===================

  Widget removePlaylistLibrary(
    Playlist p,
    BuildContext context, {
    Function? onRemove,
  }) => ListTile(
    title: Text('Remove from library'.i18n),
    leading: const Icon(Icons.delete),
    onTap: () async {
      if (p.editable == true) {
        //Delete playlist if own
        await PlatformManager.instance
            .getPlatform(p.platformId)
            .deletePlaylist(p.id!);
      } else {
        //Just remove from library
        await PlatformRegistry.instance
            .get(p.platformId)
            ?.removeFavoritePlaylist(p.id!);
        cache.platformLibraryPlaylists[p.platformId]?.remove(p.id);
        cache.save();
      }
      downloadManager.removeOfflinePlaylist(p.id!, platformId: p.platformId);
      if (onRemove != null) onRemove();
      if (context.mounted) _close(context);
    },
  );

  Widget addPlaylistLibrary(Playlist p, BuildContext context) => ListTile(
    title: Text('Add playlist to library'.i18n),
    leading: const Icon(Icons.favorite),
    onTap: () async {
      if (!_isFavoritesPlaylist(p)) {
        await PlatformRegistry.instance
            .get(p.platformId)
            ?.addFavoritePlaylist(p.id!);
      }
      if (!cache.platformLibraryPlaylists
          .putIfAbsent(p.platformId, () => [])
          .contains(p.id!)) {
        cache.platformLibraryPlaylists[p.platformId]!.add(p.id!);
        cache.save();
      }
      Fluttertoast.showToast(
        msg: 'Added playlist to library'.i18n,
        gravity: ToastGravity.BOTTOM,
      );
      if (context.mounted) _close(context);
    },
  );

  Widget editLocalPlaylist(
    Playlist p,
    BuildContext context, {
    Function? onUpdate,
  }) => ListTile(
    title: Text('Edit'.i18n),
    leading: const Icon(Icons.edit),
    onTap: () async {
      _close(context);
      final localId = p.id!.substring(6);
      final localPlaylist = await downloadManager.localPlaylistManager
          .getPlaylist(localId);
      if (localPlaylist == null) return;

      String? title = localPlaylist.title;
      String? description = localPlaylist.description;

      if (!context.mounted) return;

      await showDialog(
        context: context,
        builder: (context) => CreateLocalPlaylistDialog(
          initialTitle: title,
          initialDescription: description,
          onSave: (t, d) {
            title = t;
            description = d;
          },
        ),
      );

      if (title == null || title!.isEmpty) return;

      try {
        final updated = LocalPlaylist(
          id: localPlaylist.id,
          title: title!,
          description: description,
          trackIds: localPlaylist.trackIds,
          createdAt: localPlaylist.createdAt,
          updatedAt: DateTime.now(),
        );
        await downloadManager.localPlaylistManager.updatePlaylist(updated);
        p.title = title;
        p.description = description;
        if (onUpdate != null) onUpdate();
      } catch (e) {
        Logger.root.severe('Error updating playlist: $e');
      }
    },
  );

  Widget exportLocalPlaylist(Playlist p, BuildContext context) => ListTile(
    title: Text('Export'.i18n),
    leading: const Icon(Icons.file_upload),
    onTap: () async {
      _close(context);
      try {
        final localId = p.id!.substring(6);
        final localPlaylist = await downloadManager.localPlaylistManager
            .getPlaylist(localId);
        if (localPlaylist == null) return;

        final filePath = await downloadManager.localPlaylistManager
            .exportPlaylistWithPicker(
              localPlaylist,
              dialogTitle: 'Export Playlist'.i18n,
            );
        if (filePath == null) return;
        if (context.mounted) {
          showDialog(
            context: context,
            builder: (context) => AlertDialog(
              title: Text('Exported'.i18n),
              content: Text('Playlist saved successfully.'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text('OK'.i18n),
                ),
              ],
            ),
          );
        }
      } catch (e) {
        Logger.root.severe('Error exporting playlist: $e');
        if (context.mounted) {
          showDialog(
            context: context,
            builder: (context) => AlertDialog(
              title: Text('Error'.i18n),
              content: Text('Failed to export playlist: $e'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text('OK'.i18n),
                ),
              ],
            ),
          );
        }
      }
    },
  );

  Widget deleteLocalPlaylist(
    Playlist p,
    BuildContext context, {
    Function? onRemove,
  }) => ListTile(
    title: Text('Delete'.i18n),
    leading: const Icon(Icons.delete),
    onTap: () async {
      _close(context);
      if (!context.mounted) return;

      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Delete playlist?'.i18n),
          content: Text('This cannot be undone.'.i18n),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('Cancel'.i18n),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text('Delete'.i18n),
            ),
          ],
        ),
      );

      if (confirm != true) return;

      try {
        final localId = p.id!.startsWith('local_') ? p.id!.substring(6) : p.id!;
        await downloadManager.removeOfflinePlaylist(p.id!, platformId: 'local');
        await downloadManager.localPlaylistManager.deletePlaylist(localId);
        if (onRemove != null) {
          onRemove();
        } else if (context.mounted) {
          Navigator.pop(context);
        }
      } catch (e) {
        Logger.root.severe('Error deleting playlist: $e');
      }
    },
  );

  Widget addPlaylistOffline(Playlist p, BuildContext context) => FutureBuilder(
    future: downloadManager.checkOffline(playlist: p),
    builder: (innerContext, snapshot) {
      final isLocal =
          p.platformId == 'local' || (p.id?.startsWith('local_') ?? false);
      if (!isLocal &&
          PlatformRegistry.instance
                  .get(p.platformId)
                  ?.capabilities
                  .supportsDownload !=
              true) {
        return const SizedBox.shrink();
      }
      final isOffline = snapshot.data ?? false;
      return ListTile(
        title: Text(
          isOffline ? 'Remove offline'.i18n : 'Make playlist offline'.i18n,
        ),
        leading: const Icon(Icons.offline_pin),
        onTap: () async {
          if (isOffline) {
            await downloadManager.removeOfflinePlaylist(
              p.id!,
              platformId: p.platformId,
            );
            Fluttertoast.showToast(
              msg: 'Playlist removed from offline!'.i18n,
              gravity: ToastGravity.BOTTOM,
              toastLength: Toast.LENGTH_SHORT,
            );
          } else {
            if (!isLocal && !_isFavoritesPlaylist(p)) {
              await PlatformRegistry.instance
                  .get(p.platformId)
                  ?.addFavoritePlaylist(p.id!);
            }
            if (!isLocal && !cache.activeLibraryPlaylists.contains(p.id!)) {
              cache.activeLibraryPlaylists.add(p.id!);
              cache.save();
            }
            downloadManager.addOfflinePlaylist(p, private: true);
            showDownloadStartedToast();
          }
          if (context.mounted) _close(context);
        },
      );
    },
  );

  Widget downloadPlaylist(Playlist p, BuildContext context) => ListTile(
    title: Text('Download'.i18n),
    leading: const Icon(Icons.file_download),
    onTap: () async {
      final isLocal =
          p.platformId == 'local' || (p.id?.startsWith('local_') ?? false);
      if (!isLocal &&
          PlatformRegistry.instance
                  .get(p.platformId)
                  ?.capabilities
                  .supportsDownload !=
              true) {
        return;
      }
      if (context.mounted) _close(context);
      if (await downloadManager.addOfflinePlaylist(p, private: false) !=
          false) {
        showDownloadStartedToast();
      }
    },
  );

  Widget editPlaylist(
    Playlist p, {
    required BuildContext context,
    Function? onUpdate,
  }) => ListTile(
    title: Text('Edit playlist'.i18n),
    leading: const Icon(Icons.edit),
    onTap: () async {
      await showDialog(
        context: context,
        builder: (context) => CreatePlaylistDialog(playlist: p),
      );
      if (context.mounted) _close(context);
      if (onUpdate != null) onUpdate();
    },
  );

  //===================
  // SHOW/EPISODE
  //===================

  void defaultShowMenu(
    Show s, {
    required BuildContext context,
    List<Widget> options = const [],
    Function? onRemove,
    Function? onUpdate,
  }) async {
    show(context, [
      (await PlatformManager.instance
              .getPlatform(s.platformId)
              .isFavoriteShow(s.id!))
          ? removeShowLibrary(s, context, onRemove: onRemove)
          : addShowLibrary(s, context),
      shareShow(s),
      ..._platformOptions(context, s.platformId, s),
      ...options,
    ]);
  }

  void defaultShowEpisodeMenu(
    Show s,
    ShowEpisode e, {
    required BuildContext context,
    bool includeHeader = false,
    List<Widget> options = const [],
    Function? onRemove,
    Function? onUpdate,
  }) async {
    show(context, [
      if (includeHeader) _showEpisodeHeader(context, s, e),
      if (s.id?.isNotEmpty == true) showPodcast(s, context),
      (await PlatformManager.instance
              .getPlatform(s.platformId)
              .isFavoriteShow(s.id!))
          ? removeShowLibrary(s, context, onRemove: onRemove)
          : addShowLibrary(s, context),
      shareTile('episode', e.id!),
      shareShow(s),
      ...options,
    ]);
  }

  Widget _showEpisodeHeader(
    BuildContext context,
    Show show,
    ShowEpisode episode,
  ) {
    final imageUrl =
        episode.art?.full ??
        episode.art?.thumb ??
        show.art?.full ??
        show.art?.thumb ??
        '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Row(
        children: [
          CachedImage(url: imageUrl, width: 96, height: 96),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  episode.title ?? '',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if ((show.name ?? '').isNotEmpty)
                  Text(
                    show.name!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                if (episode.durationString.isNotEmpty)
                  Text(
                    episode.durationString,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget playbackSpeed(
    BuildContext context, {
    bool closeAfterSelection = true,
  }) {
    final handler = GetIt.I<AudioPlayerHandler>();
    final currentSpeed = handler.player.speed;
    final currentLabel = currentSpeed == currentSpeed.roundToDouble()
        ? currentSpeed.toStringAsFixed(0)
        : currentSpeed.toString();
    const speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

    return ListTile(
      title: Text('Playback speed'.i18n),
      subtitle: Text('$currentLabel×'),
      leading: const Icon(Icons.speed),
      onTap: () {
        showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text('Playback speed'.i18n),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: speeds.map((speed) {
                final selected = (handler.player.speed - speed).abs() < 0.001;
                final label = speed == speed.roundToDouble()
                    ? speed.toStringAsFixed(0)
                    : speed.toString();
                return ListTile(
                  title: Text('$label×'),
                  trailing: selected
                      ? Icon(
                          Icons.check,
                          color: Theme.of(dialogContext).colorScheme.primary,
                        )
                      : null,
                  onTap: () async {
                    await handler.player.setSpeed(speed);
                    if (handler.mediaItem.value?.extras?['show'] != null) {
                      cache.podcastPlaybackSpeed = speed;
                      await cache.save();
                    }
                    if (dialogContext.mounted) {
                      Navigator.of(dialogContext).pop();
                    }
                    if (closeAfterSelection && context.mounted) {
                      Navigator.of(context).pop();
                    }
                  },
                );
              }).toList(),
            ),
          ),
        );
      },
    );
  }

  //===================
  // SHOW/EPISODE OPTIONS
  //===================

  Widget shareShow(Show show) => ListTile(
    title: Text('Share show'.i18n),
    leading: const Icon(Icons.share),
    onTap: () async {
      final shareUrl = PlatformManager.instance
          .getPlatform(show.platformId)
          .getShareUrl('show', show.id!);
      SharePlus.instance.share(ShareParams(uri: Uri.parse(shareUrl)));
    },
  );

  Widget removeShowLibrary(
    Show s,
    BuildContext context, {
    Function? onRemove,
  }) => ListTile(
    title: Text('Remove from library'.i18n),
    leading: const Icon(Icons.delete),
    onTap: () async {
      await PlatformManager.instance
          .getPlatform(s.platformId)
          .removeFavoriteShow(s.id!);
      if (onRemove != null) onRemove();
      if (context.mounted) _close(context);
    },
  );

  Widget addShowLibrary(Show s, BuildContext context) => ListTile(
    title: Text('Add podcast to library'.i18n),
    leading: const Icon(Icons.favorite),
    onTap: () async {
      await PlatformManager.instance
          .getPlatform(s.platformId)
          .addFavoriteShow(s.id!);
      Fluttertoast.showToast(
        msg: 'Added Show to library'.i18n,
        gravity: ToastGravity.BOTTOM,
      );
      if (context.mounted) _close(context);
    },
  );

  //===================
  // OTHER
  //===================

  void showDownloadStartedToast() {
    Fluttertoast.showToast(
      msg: 'Downloads added!'.i18n,
      gravity: ToastGravity.BOTTOM,
      toastLength: Toast.LENGTH_SHORT,
    );
  }

  //Create playlist
  Future createPlaylist(BuildContext context) async {
    await showDialog(
      context: context,
      builder: (BuildContext context) {
        return const CreatePlaylistDialog();
      },
    );
  }

  Widget shareTile(String type, String id, {String? platformId}) => ListTile(
    title: Text('Share'.i18n),
    leading: const Icon(Icons.share),
    onTap: () async {
      final platform = platformId == null
          ? PlatformManager.instance.active
          : PlatformRegistry.instance.get(platformId) ??
                PlatformManager.instance.active;
      String url = platform.getShareUrl(type, id);
      if (Platform.isAndroid || Platform.isIOS) {
        SharePlus.instance.share(ShareParams(uri: Uri.parse(url)));
      } else {
        await Clipboard.setData(ClipboardData(text: url));
        Fluttertoast.showToast(
          msg: 'Link copied to clipboard!'.i18n,
          gravity: ToastGravity.BOTTOM,
        );
      }
    },
  );

  Widget sleepTimer(BuildContext context) => ListTile(
    title: Text('Sleep timer'.i18n),
    leading: const Icon(Icons.access_time),
    onTap: () async {
      showDialog(
        context: context,
        builder: (context) {
          return const SleepTimerDialog();
        },
      );
    },
  );

  Widget wakelock(BuildContext context) => ListTile(
    title: Text('Keep the screen on'.i18n),
    leading: const Icon(Icons.screen_lock_portrait),
    onTap: () async {
      _close(context);
      //Enable
      if (!cache.wakelock) {
        WakelockPlus.enable();
        Fluttertoast.showToast(
          msg: 'Wakelock enabled!'.i18n,
          gravity: ToastGravity.BOTTOM,
        );
        cache.wakelock = true;
        return;
      }
      //Disable
      WakelockPlus.disable();
      Fluttertoast.showToast(
        msg: 'Wakelock disabled!'.i18n,
        gravity: ToastGravity.BOTTOM,
      );
      cache.wakelock = false;
    },
  );

  void _close(BuildContext context) {
    if (!closeOnAction) return;
    // Menu sheets in the main shell are hosted by the unconstrained overlay
    // navigator. Menu item callbacks capture the page's (width-constrained)
    // context, so popping Navigator.of(context) would dismiss that page instead
    // of the sheet.
    final overlayNavigator = bodyOverlayNavigatorKey.currentState;
    if (bodyOverlayActive.value && overlayNavigator?.canPop() == true) {
      overlayNavigator!.pop();
      return;
    }
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }
}

class SleepTimerDialog extends StatefulWidget {
  const SleepTimerDialog({super.key});

  @override
  _SleepTimerDialogState createState() => _SleepTimerDialogState();
}

class _SleepTimerDialogState extends State<SleepTimerDialog> {
  int hours = 0;
  int minutes = 30;

  String _endTime() {
    return '${cache.sleepTimerTime!.hour.toString().padLeft(2, '0')}:${cache.sleepTimerTime!.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Sleep timer'.i18n),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Hours:'.i18n),
                  _SleepTimerNumberPicker(
                    value: hours,
                    minValue: 0,
                    maxValue: 23,
                    onChanged: (v) => setState(() => hours = v),
                  ),
                ],
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Minutes:'.i18n),
                  _SleepTimerNumberPicker(
                    value: minutes,
                    minValue: 0,
                    maxValue: 60,
                    onChanged: (v) => setState(() => minutes = v),
                  ),
                ],
              ),
            ],
          ),
          Container(height: 4.0),
          if (cache.sleepTimerTime != null)
            Text(
              'Current timer ends at'.i18n + ': ' + _endTime(),
              textAlign: TextAlign.center,
            ),
        ],
      ),
      actions: [
        TextButton(
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
          child: Text('Dismiss'.i18n),
          onPressed: () {
            Navigator.of(context).pop();
          },
        ),
        if (cache.sleepTimer != null)
          TextButton(
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
            child: Text('Cancel current timer'.i18n),
            onPressed: () {
              cache.sleepTimer!.cancel();
              cache.sleepTimer = null;
              cache.sleepTimerTime = null;
              Fluttertoast.showToast(
                msg: 'Sleep timer canceled'.i18n,
                gravity: ToastGravity.BOTTOM,
                toastLength: Toast.LENGTH_SHORT,
              );
              Navigator.of(context).pop();
            },
          ),
        TextButton(
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
          child: Text('Save'.i18n),
          onPressed: () {
            Duration duration = Duration(hours: hours, minutes: minutes);
            cache.sleepTimer?.cancel();
            //Create timer
            cache.sleepTimer = Stream.fromFuture(Future.delayed(duration))
                .listen((_) {
                  GetIt.I<AudioPlayerHandler>().pause();
                  cache.sleepTimer?.cancel();
                  cache.sleepTimerTime = null;
                  cache.sleepTimer = null;
                });
            cache.sleepTimerTime = DateTime.now().add(duration);
            Fluttertoast.showToast(
              msg: 'Sleep timer set'.i18n,
              gravity: ToastGravity.BOTTOM,
              toastLength: Toast.LENGTH_SHORT,
            );
            Navigator.of(context).pop();
          },
        ),
      ],
    );
  }
}

class _SleepTimerNumberPicker extends StatefulWidget {
  final int value;
  final int minValue;
  final int maxValue;
  final ValueChanged<int> onChanged;

  const _SleepTimerNumberPicker({
    required this.value,
    required this.minValue,
    required this.maxValue,
    required this.onChanged,
  });

  @override
  State<_SleepTimerNumberPicker> createState() =>
      _SleepTimerNumberPickerState();
}

class _SleepTimerNumberPickerState extends State<_SleepTimerNumberPicker> {
  late final FixedExtentScrollController _controller;

  @override
  void initState() {
    super.initState();
    _controller = FixedExtentScrollController(
      initialItem: widget.value - widget.minValue,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.grab,
      child: SizedBox(
        width: 88,
        height: 150,
        child: ScrollConfiguration(
          behavior: _SleepTimerPickerScrollBehavior(),
          child: ListWheelScrollView.useDelegate(
            controller: _controller,
            itemExtent: 50,
            physics: const FixedExtentScrollPhysics(),
            diameterRatio: 2.5,
            overAndUnderCenterOpacity: 0.55,
            onSelectedItemChanged: (index) {
              widget.onChanged(widget.minValue + index);
            },
            childDelegate: ListWheelChildBuilderDelegate(
              childCount: widget.maxValue - widget.minValue + 1,
              builder: (context, index) {
                final value = widget.minValue + index;
                final selected = value == widget.value;
                return Center(
                  child: Text(
                    '$value',
                    textAlign: TextAlign.center,
                    style: selected
                        ? theme.textTheme.headlineSmall?.copyWith(
                                color: theme.colorScheme.primary,
                              ) ??
                              const TextStyle()
                        : theme.textTheme.bodyLarge?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ) ??
                              const TextStyle(),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _SleepTimerPickerScrollBehavior extends MaterialScrollBehavior {
  @override
  Set<PointerDeviceKind> get dragDevices => {
    ...super.dragDevices,
    PointerDeviceKind.mouse,
  };
}

class SelectPlaylistDialog extends StatefulWidget {
  final Track? track;
  final Future<void> Function(Playlist) callback;
  const SelectPlaylistDialog({this.track, required this.callback, super.key});

  @override
  _SelectPlaylistDialogState createState() => _SelectPlaylistDialogState();
}

class _SelectPlaylistDialogState extends State<SelectPlaylistDialog> {
  bool createNew = false;
  bool _adding = false;
  bool _creatingLocal = false;
  late dynamic _platform;
  late Future<List<dynamic>> _playlistsFuture;

  @override
  void initState() {
    super.initState();
    _platform = PlatformManager.instance.getPlatform(
      widget.track?.platformId ?? PlatformManager.instance.active.platformId,
    );
    _playlistsFuture = _loadPlaylists();
  }

  Future<List<dynamic>> _loadPlaylists() async {
    final results = await Future.wait<Object>([
      _platform.getUserPlaylists(),
      downloadManager.localPlaylistManager.getAllPlaylists(),
    ]);
    final platformPlaylists = results[0] as List<Playlist>;
    final localPlaylists = results[1] as List<LocalPlaylist>;

    await Future.wait(
      localPlaylists
          .where((playlist) => playlist.mosaicImages?.isNotEmpty != true)
          .map((playlist) async {
            try {
              final tracks = await downloadManager.loadLocalPlaylistTracks(
                playlist,
                start: 0,
                limit: 4,
              );
              playlist.mosaicImages = tracks
                  .map((track) => track.albumArt?.fullUrl ?? '')
                  .where((url) => url.isNotEmpty)
                  .take(4)
                  .toList();
            } catch (_) {
              // Keep the playlist usable if local artwork cannot be loaded.
            }
          }),
    );
    return [platformPlaylists, localPlaylists];
  }

  Future<void> _addToPlaylist(Playlist playlist) async {
    if (_adding) return;
    setState(() => _adding = true);
    try {
      await widget.callback(playlist);
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('Track added to'.i18n + ' ${playlist.title}')),
        );
    } catch (error) {
      await Fluttertoast.showToast(msg: 'Could not add track: $error');
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _addToLocalPlaylist(LocalPlaylist playlist) async {
    if (_adding) return;
    setState(() => _adding = true);
    try {
      await downloadManager.localPlaylistManager.addTracksToPlaylist(
        playlist.id,
        ['${widget.track!.platformId}:${widget.track!.id!}'],
      );
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('Track added to'.i18n + ' ${playlist.title}')),
        );
    } catch (error) {
      await Fluttertoast.showToast(msg: 'Could not add track: $error');
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _createLocalPlaylist() async {
    if (_creatingLocal) return;
    String? title;
    String? description;

    await showDialog<void>(
      context: context,
      builder: (context) => CreateLocalPlaylistDialog(
        onSave: (value, details) {
          title = value;
          description = details;
        },
      ),
    );
    if (!mounted || title == null || title!.trim().isEmpty) return;

    setState(() => _creatingLocal = true);
    try {
      final track = widget.track;
      final playlist = await downloadManager.localPlaylistManager
          .createPlaylist(
            title: title!.trim(),
            description: description,
            trackIds: track != null && track.id != null
                ? ['${track.platformId}:${track.id}']
                : const [],
          );
      if (!mounted) return;

      if (track != null) {
        final messenger = ScaffoldMessenger.of(context);
        Navigator.of(context).pop();
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text('Track added to'.i18n + ' ${playlist.title}'),
            ),
          );
      } else {
        setState(() => _playlistsFuture = _loadPlaylists());
      }
    } catch (error) {
      await Fluttertoast.showToast(msg: 'Could not create playlist: $error');
    } finally {
      if (mounted) setState(() => _creatingLocal = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    //Create new playlist
    if (createNew) {
      if (widget.track == null) {
        return const CreatePlaylistDialog();
      }
      return CreatePlaylistDialog(tracks: [widget.track!]);
    }

    final platform = _platform;

    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(24, 20, 16, 0),
      contentPadding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      actionsPadding: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          Expanded(
            child: Text(
              'Select playlist'.i18n,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            visualDensity: VisualDensity.compact,
            onPressed: _adding ? null : () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: (MediaQuery.sizeOf(context).height * 0.72)
                .clamp(220.0, 600.0)
                .toDouble(),
          ),
          child: FutureBuilder(
          future: _playlistsFuture,
          builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Center(child: ErrorScreen());
          }
          if (snapshot.connectionState != ConnectionState.done) {
            return SizedBox(
              child: Center(
                child: CircularProgressIndicator(color: colors.primary),
              ),
            );
          }

          // Check if snapshot has data before accessing it
          if (!snapshot.hasData || snapshot.data == null) {
            return const Center(child: ErrorScreen());
          }

          List<Playlist> editablePlaylists =
              (snapshot.data![0] as List<Playlist>)
                  .where((p) => p.editable == true)
                  .toList();
          List<LocalPlaylist> localPlaylists =
              snapshot.data![1] as List<LocalPlaylist>;

          Widget sectionHeading(String label, int count) => Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: colors.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  '$count',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          );

          Widget playlistRow({
            required String title,
            required Widget leading,
            required VoidCallback? onTap,
          }) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              child: ListTile(
                dense: false,
                minLeadingWidth: 48,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: SizedBox(width: 48, height: 48, child: leading),
                ),
                title: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
                trailing: Icon(
                  Icons.chevron_right,
                  color: colors.onSurfaceVariant,
                ),
                onTap: _adding ? null : onTap,
              ),
            ),
          );

          Widget localPlaylistArtwork(LocalPlaylist playlist) {
            final mosaic = playlist.mosaicImages;
            if (mosaic != null && mosaic.isNotEmpty) {
              return MosaicImage(
                urls: mosaic,
                width: 48,
                height: 48,
                rounded: false,
              );
            }
            return DecoratedBox(
              decoration: BoxDecoration(color: colors.secondaryContainer),
              child: Icon(
                Icons.queue_music_rounded,
                color: colors.onSecondaryContainer,
                size: 25,
              ),
            );
          }

          Widget platformPlaylistArtwork(Playlist playlist) {
            final mosaic = playlist.mosaicImages;
            if (mosaic != null && mosaic.isNotEmpty) {
              return MosaicImage(
                urls: mosaic,
                width: 48,
                height: 48,
                rounded: false,
              );
            }
            return CachedImage(url: playlist.image?.thumb ?? '');
          }

          return SilkySingleChildScrollView(
            silkyConfig: silkyScrollConfig,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                sectionHeading('Local Playlists'.i18n, localPlaylists.length),
                ...localPlaylists.map(
                  (playlist) => playlistRow(
                    title: playlist.title,
                    leading: localPlaylistArtwork(playlist),
                    onTap: () => _addToLocalPlaylist(playlist),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                  child: OutlinedButton.icon(
                    onPressed: _adding || _creatingLocal
                        ? null
                        : _createLocalPlaylist,
                    icon: const Icon(Icons.add_rounded),
                    label: Text('Create local playlist'.i18n),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(44),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
                if (editablePlaylists.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Divider(color: colors.outlineVariant),
                  ),
                  sectionHeading(
                    '${platform.platformName} Playlists',
                    editablePlaylists.length,
                  ),
                  ...editablePlaylists.map(
                    (playlist) => playlistRow(
                      title: playlist.title ?? '',
                      leading: platformPlaylistArtwork(playlist),
                      onTap: () => _addToPlaylist(playlist),
                    ),
                  ),
                ],
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                  child: FilledButton.tonalIcon(
                    onPressed: _adding
                        ? null
                        : () => setState(() => createNew = true),
                    icon: const Icon(Icons.add_rounded),
                    label: Text('Create new playlist'.i18n),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          );
          },
          ),
        ),
      ),
    );
  }
}

class CreatePlaylistDialog extends StatefulWidget {
  final List<Track>? tracks;
  //If playlist not null, update
  final Playlist? playlist;
  const CreatePlaylistDialog({this.tracks, this.playlist, super.key});

  @override
  _CreatePlaylistDialogState createState() => _CreatePlaylistDialogState();
}

class _CreatePlaylistDialogState extends State<CreatePlaylistDialog> {
  int _playlistType = 1;
  String _title = '';
  String _description = '';
  TextEditingController? _titleController;
  TextEditingController? _descController;

  //Create or edit mode
  bool get edit => widget.playlist != null;

  @override
  void initState() {
    //Edit playlist mode
    if (edit) {
      _title = widget.playlist?.title ?? '';
      _description = widget.playlist?.description ?? '';
    }

    _titleController = TextEditingController(text: _title);
    _descController = TextEditingController(text: _description);

    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(edit ? 'Edit playlist'.i18n : 'Create playlist'.i18n),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          TextField(
            cursorColor: Theme.of(context).primaryColor,
            decoration: InputDecoration(
              labelText: 'Title'.i18n,
              focusedBorder: UnderlineInputBorder(
                borderSide: BorderSide(
                  color: Theme.of(context).primaryColor,
                ), // Color of the underline when focused
              ),
            ),
            controller: _titleController ?? TextEditingController(),
            onChanged: (String s) => _title = s,
          ),
          TextField(
            cursorColor: Theme.of(context).primaryColor,
            onChanged: (String s) => _description = s,
            controller: _descController ?? TextEditingController(),
            decoration: InputDecoration(
              labelText: 'Description'.i18n,
              focusedBorder: UnderlineInputBorder(
                borderSide: BorderSide(
                  color: Theme.of(context).primaryColor,
                ), // Color of the underline when focused
              ),
            ),
          ),
          Container(height: 4.0),
          DropdownButton<int>(
            value: _playlistType,
            onChanged: (int? v) {
              setState(() => _playlistType = v!);
            },
            items: [
              DropdownMenuItem<int>(value: 1, child: Text('Private'.i18n)),
              DropdownMenuItem<int>(value: 2, child: Text('Public'.i18n)),
            ],
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
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
          child: Text('Cancel'.i18n),
          onPressed: () => Navigator.of(context).pop(),
        ),
        TextButton(
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
          child: Text(edit ? 'Update'.i18n : 'Create'.i18n),
          onPressed: () async {
            if (edit) {
              //Update
              await PlatformManager.instance
                  .getPlatform(widget.playlist!.platformId)
                  .updatePlaylist(
                    widget.playlist!.id!,
                    _titleController!.value.text,
                    description: _descController!.value.text,
                    status: _playlistType,
                  );
            } else {
              List<String> tracks = [];
              tracks = widget.tracks?.map<String>((t) => t.id!).toList() ?? [];
              final platformId =
                  widget.playlist?.platformId ??
                  (widget.tracks?.isNotEmpty == true
                      ? widget.tracks!.first.platformId
                      : PlatformManager.instance.activePlatformId);
              await PlatformManager.instance
                  .getPlatform(platformId)
                  .createPlaylist(
                    _title,
                    status: _playlistType,
                    description: _description,
                    trackIds: tracks,
                  );
            }
            if (!context.mounted) return;
            final messenger = ScaffoldMessenger.of(context);
            Navigator.of(context).pop();
            messenger
              ..hideCurrentSnackBar()
              ..showSnackBar(
                SnackBar(
                  content: Text(
                    edit ? 'Playlist updated!'.i18n : 'Playlist created!'.i18n,
                  ),
                ),
              );
          },
        ),
      ],
    );
  }
}
