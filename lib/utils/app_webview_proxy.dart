import 'dart:io';

import 'package:flutter/services.dart';
import 'package:webview_all/webview_all.dart';
import 'package:webview_all_windows/webview_all_windows.dart';

import 'app_http_proxy.dart';

/// Applies the app's HTTP proxy to the supported native WebView network stacks.
class AppWebViewProxy {
  static const _channel = MethodChannel('s.s.saturn/webview_proxy');

  static bool get handlesAuthChallenges =>
      Platform.isAndroid || Platform.isLinux || Platform.isWindows;

  static Future<void> configure(
    String? address, {
    String? username,
    String? password,
  }) async {
    if (Platform.isWindows) {
      if (address != null) {
        await WindowsWebViewController.ensureEnvironment(
          additionalArguments: '--proxy-server=http://$address',
        );
      }
      return;
    }
    if (!Platform.isAndroid &&
        !Platform.isLinux &&
        !Platform.isIOS &&
        !Platform.isMacOS) {
      return;
    }
    await _channel.invokeMethod<void>('configure', {
      'address': address,
      'username': username,
      'password': password,
    });
  }

  static void handleHttpAuthRequest(HttpAuthRequest request) {
    final credentials = AppHttpProxy.credentialsForHost(request.host);
    if (handlesAuthChallenges && credentials != null) {
      request.onProceed(
        WebViewCredential(
          user: credentials.user,
          password: credentials.password,
        ),
      );
    } else {
      request.onCancel();
    }
  }
}
