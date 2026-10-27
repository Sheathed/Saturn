import 'package:just_audio_media_kit/just_audio_media_kit.dart';

import '../utils/app_config.dart';

void configureDesktopAudioPlayer() {
  // MPV can prepare the following playlist entry while the current one plays.
  JustAudioMediaKit.nativeProperties = {
    'network-timeout': '90',
    'prefetch-playlist': 'yes',
  };
  JustAudioMediaKit.ensureInitialized(title: appTitle);
}
