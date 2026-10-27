import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

import '../api/definitions.dart';
import 'stream_provider.dart';

/// Chooses the native source type for a platform stream. The service only
/// supplies the local proxy URL and queue metadata.
class PlatformAudioSourceFactory {
  static AudioSource forUri(Uri uri, MediaItem item) {
    if ((Platform.isAndroid || Platform.isIOS) &&
        uri.path.toLowerCase().endsWith('.m3u8')) {
      return HlsAudioSource(uri, tag: item);
    }
    return AudioSource.uri(uri, tag: item);
  }

  static AudioSource forProvider({
    required StreamProvider provider,
    required Track track,
    required Uri streamUri,
    required Uri licenseUri,
    required MediaItem item,
  }) {
    if (!Platform.isAndroid && !Platform.isIOS && !Platform.isMacOS) {
      return AudioSource.uri(streamUri, tag: item);
    }
    // Queue construction must stay local and cheap. Resolving a stream here
    // used to perform network requests for every queued SoundCloud track,
    // making initial playback and skips wait on unrelated tracks. The proxy
    // resolves the selected track when its stream is opened.
    final hint = provider.playbackHint(track, licenseUri);
    final config = hint?.drm;
    final drm = Platform.isAndroid && config != null
        ? DrmConfiguration(
            licenseUrl: config.licenseUrl,
            licenseHeaders: config.licenseHeaders,
          )
        : null;
    switch (hint?.format.toUpperCase()) {
      case 'HLS':
        return HlsAudioSource(streamUri, tag: item, drm: drm);
      case 'DASH':
        return DashAudioSource(streamUri, tag: item, drm: drm);
      default:
        return AudioSource.uri(streamUri, tag: item);
    }
  }
}
