import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:webview_all/webview_all.dart';

import '../../router/app_router.dart';
import '../../settings.dart';
import '../../ui/app_webview_screen.dart';
import '../../utils/app_webview_proxy.dart';
import 'soundcloud_client.dart';
import 'soundcloud_web_cookies.dart';
import 'soundcloud_web_identity.dart';

/// Keeps SoundCloud's own browser page alive between follow changes.
class SoundCloudWebFollow {
  SoundCloudWebFollow(this.client);

  final SoundCloudInternalClient client;
  OffscreenWebViewSession? _session;
  Future<OffscreenWebViewSession>? _creating;
  Future<void> _changeChain = Future<void>.value();

  Future<void> close() async {
    final creating = _creating;
    var session = _session;
    _session = null;
    _creating = null;
    if (session == null && creating != null) {
      try {
        session = await creating;
      } catch (_) {
        return;
      }
    }
    try {
      await session?.close();
    } catch (_) {
      // Releasing a browser must not prevent sign out or a new sign in.
    }
  }

  Future<OffscreenWebViewSession> _browser() async {
    if (_session case final session?) return session;
    if (_creating case final creating?) return creating;
    final creating = _createBrowser();
    _creating = creating;
    try {
      return _session = await creating;
    } finally {
      _creating = null;
    }
  }

  Future<OffscreenWebViewSession> _createBrowser() async {
    final session = await OffscreenWebViewSession.create();
    try {
      final controller = session.controller;
      await SoundCloudWebIdentity.configure(controller);
      final token = client.oauthToken;
      if (token != null &&
          token.isNotEmpty &&
          await SoundCloudWebCookies.readOauthToken() == null) {
        await SoundCloudWebCookies.install({'oauth_token': token});
      }
      final ready = Completer<void>();
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            if (!ready.isCompleted) ready.complete();
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
      await ready.future.timeout(const Duration(seconds: 20));
      return session;
    } catch (_) {
      await session.close();
      rethrow;
    }
  }

  Future<void> change(
    String accountId,
    String artistId, {
    required bool follow,
    required Future<bool> Function() verify,
    required Future<Uri> Function() artistUrl,
  }) {
    final result = _changeChain.then(
      (_) => _change(
        accountId,
        artistId,
        follow: follow,
        verify: verify,
        artistUrl: artistUrl,
      ),
    );
    _changeChain = result.catchError((Object _) {});
    return result;
  }

  Future<void> _change(
    String accountId,
    String artistId, {
    required bool follow,
    required Future<bool> Function() verify,
    required Future<Uri> Function() artistUrl,
  }) async {
    final token = client.oauthToken;
    if (token == null || token.isEmpty) {
      throw StateError('SoundCloud sign in is required');
    }
    final controller = (await _browser()).controller;
    final pageHost = Uri.tryParse(await controller.currentUrl() ?? '')?.host;
    if (pageHost != 'soundcloud.com' && pageHost != 'm.soundcloud.com') {
      throw const SoundCloudChallengeException();
    }
    final mobile = pageHost == 'm.soundcloud.com';
    final clientId = mobile
        ? await client.getMobileClientId()
        : await client.getClientId();
    final userAgent = await controller.getUserAgent();
    if (userAgent == null || userAgent.isEmpty) {
      throw const FormatException('SoundCloud browser User-Agent unavailable');
    }
    final uri = Uri.https(
      mobile ? 'api-mobi.soundcloud.com' : 'api-v2.soundcloud.com',
      '/me/followings/$artistId',
      {
        'client_id': clientId,
        if (follow)
          'signature': SoundCloudInternalClient.followSignature(
            accountId,
            artistId,
            clientId,
            userAgent: userAgent,
          ),
      },
    );
    Map? response;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        response =
            await controller.callAsyncJavaScript(
                  r'''
          if (location.hostname !== pageHost) return {status: 0};
          try {
            const response = await fetch(requestUrl, {
              method: requestMethod,
              credentials: 'include',
              headers: {
                'Authorization': 'OAuth ' + oauthToken,
                'Accept': 'application/json, text/javascript, */*; q=0.1'
              }
            });
            return {
              status: response.status,
              challenge: response.status === 403 &&
                (await response.text()).includes('captcha-delivery.com')
            };
          } catch (_) {
            return {status: 0};
          }
        ''',
                  arguments: {
                    'requestUrl': uri.toString(),
                    'requestMethod': follow ? 'POST' : 'DELETE',
                    'oauthToken': token,
                    'pageHost': pageHost,
                  },
                  timeout: const Duration(seconds: 20),
                )
                as Map?;
      } on TimeoutException {
        response = {'status': 0};
      }
      final status = response?['status'];
      if (status is int && status >= 200 && status < 300) return;
      if (response?['challenge'] != true && status != 0) {
        throw HttpException('SoundCloud browser follow HTTP $status');
      }
      if (attempt == 0) await Future<void>.delayed(const Duration(seconds: 2));
    }

    final url = await artistUrl();
    await _completeInBrowser(
      url,
      follow
          ? 'Follow this creator on SoundCloud, then tap Done.'
          : 'Unfollow this creator on SoundCloud, then tap Done.',
      verify,
    );
  }

  Future<void> completeInBrowser(
    Uri url,
    String instruction,
    Future<bool> Function() verify,
  ) {
    final result = _changeChain.then(
      (_) => _completeInBrowser(url, instruction, verify),
    );
    _changeChain = result.catchError((Object _) {});
    return result;
  }

  Future<void> _completeInBrowser(
    Uri url,
    String instruction,
    Future<bool> Function() verify,
  ) async {
    final context = rootNavigatorKey.currentContext;
    if (context == null || !context.mounted) {
      throw const SoundCloudChallengeException();
    }
    if (url.scheme != 'https' ||
        !{'soundcloud.com', 'm.soundcloud.com'}.contains(url.host)) {
      throw const SoundCloudChallengeException();
    }
    final visible = WebViewController();
    await SoundCloudWebIdentity.configure(visible);
    final token = client.oauthToken;
    if (token != null &&
        token.isNotEmpty &&
        await SoundCloudWebCookies.readOauthToken() == null) {
      await SoundCloudWebCookies.install({'oauth_token': token});
    }
    await visible.setNavigationDelegate(
      NavigationDelegate(
        onHttpAuthRequest:
            !AppWebViewProxy.handlesAuthChallenges ||
                settings.proxyUsername == null
            ? null
            : AppWebViewProxy.handleHttpAuthRequest,
      ),
    );
    await visible.loadRequest(url);
    if (!context.mounted) throw const SoundCloudChallengeException();
    final done = await openAppWebView<bool>(
      context: context,
      serviceName: 'SoundCloud',
      barrierDismissible: false,
      actions: [
        Builder(
          builder: (actionContext) => TextButton(
            onPressed: () => Navigator.pop(actionContext, true),
            child: const Text('Done'),
          ),
        ),
      ],
      bottomBar: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          border: Border(
            top: BorderSide(
              color: Theme.of(context).dividerColor.withValues(alpha: 0.2),
            ),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(instruction, style: const TextStyle(fontSize: 13)),
            ),
            const SizedBox(width: 12),
            Builder(
              builder: (btnContext) => TextButton(
                onPressed: () => Navigator.pop(btnContext, false),
                child: const Text('Cancel'),
              ),
            ),
            const SizedBox(width: 8),
            Builder(
              builder: (btnContext) => FilledButton(
                onPressed: () => Navigator.pop(btnContext, true),
                child: const Text('Done'),
              ),
            ),
          ],
        ),
      ),
      child: WebViewWidget(controller: visible),
    );
    if (done != true) throw const SoundCloudChallengeException();
    if (await verify()) return;
    await Future<void>.delayed(const Duration(seconds: 1));
    if (await verify()) return;
    throw StateError('SoundCloud did not confirm the change.');
  }
}
