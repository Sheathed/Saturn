import 'dart:io';

import 'package:webview_all/webview_all.dart';

import 'soundcloud_client.dart';

/// Selects SoundCloud's mobile layout for browser-based follow actions.
///
/// Do not use this identity for authentication. Login must keep the native
/// browser identity, including its platform and User-Agent Client Hints.
class SoundCloudWebIdentity {
  static const _mobileWebKitUserAgent =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 '
      'Mobile/15E148 Safari/604.1';

  static Future<String> mobileUserAgent(WebViewController controller) async {
    if (Platform.isLinux || Platform.isMacOS) return _mobileWebKitUserAgent;
    if (Platform.isWindows) {
      String? nativeUserAgent;
      try {
        nativeUserAgent = await controller.getUserAgent();
      } catch (_) {}
      final version = RegExp(
        r'(?:Chrome|Chromium)/(\d+)',
      ).firstMatch(nativeUserAgent ?? '')?.group(1);
      if (version != null) {
        return 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/$version.0.0.0 Mobile Safari/537.36';
      }
    }
    return SoundCloudInternalClient.mobileFollowUserAgent;
  }

  static Future<String> configure(WebViewController controller) async {
    final userAgent = await mobileUserAgent(controller);
    await controller.setUserAgent(userAgent);
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    return userAgent;
  }
}
