import '../settings.dart' as settings_module;
import 'deezer/deezer_api.dart';
import 'deezer/deezer_platform.dart';
import 'music_platform.dart';
import 'neurokaraoke/neurokaraoke_platform.dart';
import 'soundcloud/soundcloud_platform.dart';
import 'youtube_music/youtube_music_platform.dart';

/// Creates a fresh platform service inside a download worker isolate.
///
/// Platform-specific setup is intentionally kept here so the generic queue and
/// worker do not depend on platform APIs, credentials, or stream internals.
Future<MusicPlatform> createDownloadPlatform(
  String platformId,
  Map<String, dynamic> settingsJson, {
  Future<String> Function(String jsCode)? executeJavaScriptOnRootIsolate,
}) async {
  settings_module.settings = settings_module.Settings.fromJson(settingsJson);
  settings_module.settings.preventSave = true;

  switch (platformId) {
    case 'deezer':
      final deezerConfig = settings_module.settings.platformConfigs['deezer'];
      final deezerArl = deezerConfig is Map
          ? deezerConfig['arl'] as String?
          : null;
      deezerAPI = DeezerAPI(arl: deezerArl);
      final authorized = await deezerAPI.authorize();
      if (!authorized) {
        throw StateError('Deezer authentication failed');
      }
      return DeezerPlatform();
    case 'neurokaraoke':
      return NeuroKaraokePlatform();
    case 'soundcloud':
      return SoundCloudPlatform();
    case 'youtube_music':
      return YouTubeMusicPlatform(
        executeJavaScriptOnRootIsolate: executeJavaScriptOnRootIsolate,
        refreshSessionFromWebView: false,
      );
    default:
      throw UnsupportedError('Unknown download platform: $platformId');
  }
}
