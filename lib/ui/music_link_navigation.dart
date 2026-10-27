import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../api/cache.dart';
import '../api/definitions.dart';
import '../platform/music_platform.dart';
import '../platform/platform_manager.dart';
import '../platform/platform_registry.dart';
import '../service/audio_service.dart';
import '../settings.dart';
import '../translations.i18n.dart';
import '../router/app_router.dart';

/// Resolves a pasted or external music link through the registered platforms
/// and opens the matching item in the app.
Future<void> openScreenByURL(String url) async {
  final active = PlatformManager.instance.active;
  final response = await PlatformRegistry.instance.parseMusicLink(
    url,
    preferredPlatformId: active.platformId,
  );
  if (response == null) return;

  final context = appRouter.routerDelegate.navigatorKey.currentContext;
  if (context == null) return;

  final platform = PlatformRegistry.instance.get(response.platformId);
  if (platform == null) return;
  if (PlatformManager.instance.activePlatformId != platform.platformId) {
    PlatformManager.instance.switchPlatform(platform.platformId);
    settings.activePlatformId = platform.platformId;
    await settings.save();
  }

  switch (response.type) {
    case PlatformLinkType.track:
      final track = await platform.getTrack(response.id);
      cache.addToSearchHistory(track);
      if (platform.capabilities.supportsTrackPage && context.mounted) {
        context.push(
          '/track/${Uri.encodeComponent(track.id ?? response.id)}?platform=${platform.platformId}',
          extra: track,
        );
      } else {
        await GetIt.I<AudioPlayerHandler>().playFromTrackList(
          [track],
          track.id ?? response.id,
          QueueSource(id: response.id, text: 'Link'.i18n, source: 'search_link'),
        );
      }
      break;
    case PlatformLinkType.album:
      final album = await platform.getAlbum(response.id);
      if (context.mounted) {
        context.push(
          '/album/${Uri.encodeComponent(album.id ?? response.id)}',
          extra: album,
        );
      }
      break;
    case PlatformLinkType.artist:
      final artist = await platform.getArtist(response.id);
      if (context.mounted) {
        context.push(
          '/artist/${Uri.encodeComponent(artist.id ?? response.id)}',
          extra: artist,
        );
      }
      break;
    case PlatformLinkType.playlist:
      final playlist = await platform.getPlaylist(response.id);
      if (context.mounted) {
        context.push(
          '/playlist/${Uri.encodeComponent(playlist.id ?? response.id)}',
          extra: playlist,
        );
      }
      break;
  }
}
