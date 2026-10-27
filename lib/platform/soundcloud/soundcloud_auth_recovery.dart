import 'dart:async';

import 'package:webview_all/webview_all.dart';

import '../../settings.dart';
import '../../utils/app_webview_proxy.dart';
import 'soundcloud_web_cookies.dart';
import 'soundcloud_web_identity.dart';

/// Lets SoundCloud's already signed-in browser renew its own session, then
/// reads the resulting OAuth cookie. No browser credentials leave the WebView.
class SoundCloudAuthRecovery {
  static Future<String?> refreshedCookie(String expiredToken) async {
    final existing = await SoundCloudWebCookies.readOauthToken(
      excluding: expiredToken,
    );
    if (existing != null) return existing;
    if (WebViewPlatform.instance == null) return null;

    final session = await OffscreenWebViewSession.create();
    try {
      final controller = session.controller;
      await SoundCloudWebIdentity.configure(controller);
      final loaded = Completer<void>();
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            if (!loaded.isCompleted) loaded.complete();
          },
          onHttpAuthRequest:
              !AppWebViewProxy.handlesAuthChallenges ||
                  settings.proxyUsername == null
              ? null
              : AppWebViewProxy.handleHttpAuthRequest,
        ),
      );
      await controller.loadRequest(
        Uri.https('m.soundcloud.com', '/discover', {
          'prevent_desktop_redirect': 'true',
        }),
      );
      await loaded.future.timeout(const Duration(seconds: 20));
      for (var attempt = 0; attempt < 8; attempt++) {
        final token = await SoundCloudWebCookies.readOauthToken(
          excluding: expiredToken,
        );
        if (token != null) return token;
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      return null;
    } finally {
      await session.close();
    }
  }
}
