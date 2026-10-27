import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:webview_all/webview_all.dart';

import '../../settings.dart';
import '../../ui/app_webview_screen.dart';
import '../../ui/login_components.dart';
import '../../utils/app_webview_proxy.dart';
import '../music_platform.dart';
import 'soundcloud_mobile_auth.dart';
import 'soundcloud_mobile_client.dart';
import 'soundcloud_platform.dart';

class SoundCloudLoginWidget extends StatefulWidget {
  const SoundCloudLoginWidget({
    required this.platform,
    required this.onSuccess,
    super.key,
  });

  final SoundCloudPlatform platform;
  final VoidCallback onSuccess;

  @override
  State<SoundCloudLoginWidget> createState() => _SoundCloudLoginWidgetState();
}

class _SoundCloudLoginWidgetState extends State<SoundCloudLoginWidget> {
  bool _checking = false;
  bool _connected = false;
  bool _embeddedBlocked = false;
  String? _embeddedUserAgent;
  String? _error;
  final _accessTokenController = TextEditingController();
  final _refreshTokenController = TextEditingController();

  bool get _desktop =>
      Platform.isLinux || Platform.isWindows || Platform.isMacOS;

  @override
  void dispose() {
    _accessTokenController.dispose();
    _refreshTokenController.dispose();
    super.dispose();
  }

  Future<void> _submitToken() async {
    if (_checking || _connected) return;
    final access = _accessTokenController.text.trim();
    final refresh = _refreshTokenController.text.trim();
    if (access.isEmpty) {
      setState(() => _error = 'Enter a SoundCloud mobile access token.');
      return;
    }
    setState(() {
      _checking = true;
      _error = null;
    });
    AuthResult result;
    try {
      result = await widget.platform.login({
        'oauth_token': access,
        if (refresh.isNotEmpty) 'refresh_token': refresh,
      });
    } catch (_) {
      result = const AuthResult.failure('Could not connect to SoundCloud.');
    }
    if (!mounted) return;
    setState(() => _checking = false);
    if (result.success) {
      _connected = true;
      widget.onSuccess();
    } else {
      setState(() => _error = result.error ?? 'SoundCloud sign in failed.');
    }
  }

  Future<void> _startWebViewLogin() async {
    if (_checking || _connected) return;
    setState(() {
      _embeddedBlocked = false;
      _embeddedUserAgent = null;
      _error = null;
    });
    final authorization = SoundCloudMobileAuthorization(
      clientId: SoundCloudMobileClient.mobileClientId,
    );
    final controller = WebViewController();
    BuildContext? webViewContext;
    var webViewClosed = false;

    void closeWebView() {
      if (!webViewClosed && (webViewContext?.mounted ?? false)) {
        webViewClosed = true;
        Navigator.of(webViewContext!).pop(true);
      }
    }

    Future<void> complete(String code) async {
      if (_checking || _connected || !mounted) return;
      setState(() {
        _checking = true;
        _error = null;
      });
      AuthResult result;
      try {
        result = await widget.platform.login({
          'authorization_code': code,
          'code_verifier': authorization.codeVerifier,
        });
      } catch (_) {
        result = const AuthResult.failure(
          'SoundCloud sign in failed. Please try again.',
        );
      }
      if (!mounted) return;
      setState(() => _checking = false);
      closeWebView();
      if (result.success) {
        _connected = true;
        widget.onSuccess();
      } else {
        setState(() => _error = result.error ?? 'SoundCloud sign in failed.');
      }
    }

    try {
      // Keep the native browser identity for authentication. The mobile UA
      // used to select m.soundcloud.com's layout does not belong here: it
      // misrepresents desktop engines/OSes and overrides WebView2 client hints.
      // Even setting the native UA explicitly can affect client hints, so leave
      // the fresh controller's UA untouched.
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            if (uri?.scheme == 'sc' && uri?.host == 'auth') {
              final code = uri!.queryParameters['code'];
              if (code != null && code.isNotEmpty) {
                unawaited(complete(code));
              } else if (mounted) {
                closeWebView();
                setState(
                  () => _error =
                      'SoundCloud did not complete sign in. Please try again.',
                );
              }
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
          onPageFinished: (_) {
            if (!webViewClosed) {
              unawaited(_checkBlockedPage(controller, closeWebView));
            }
          },
          onHttpAuthRequest:
              !AppWebViewProxy.handlesAuthChallenges ||
                  settings.proxyUsername == null
              ? null
              : AppWebViewProxy.handleHttpAuthRequest,
        ),
      );
      await controller.loadRequest(authorization.url);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not open SoundCloud sign in.');
      }
      return;
    }
    if (!mounted) return;
    setState(() => _error = null);
    await openAppWebView(
      context: context,
      serviceName: 'SoundCloud',
      controller: controller,
      actions: [
        IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: 'Reload',
          onPressed: () => controller.reload(),
        ),
        Builder(
          builder: (context) {
            webViewContext = context;
            if (_connected || _embeddedBlocked) {
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => closeWebView(),
              );
            }
            return const SizedBox.shrink();
          },
        ),
      ],
    );
  }

  Future<void> _checkBlockedPage(
    WebViewController controller,
    VoidCallback close,
  ) async {
    try {
      final blocked = await controller.runJavaScriptReturningResult(
        'Boolean(document.body && '
        'document.body.innerText.includes("You have been blocked") && '
        'document.body.innerText.includes("unusual activity"))',
      );
      // WebKit can return JavaScript primitive results as strings.
      if ((blocked != true && blocked != 'true') || !mounted) return;
      String? userAgent;
      try {
        userAgent = await controller.getUserAgent();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _embeddedBlocked = true;
        _embeddedUserAgent = userAgent;
        _error = 'SoundCloud blocked sign in inside the embedded browser.';
      });
      close();
    } catch (_) {}
  }

  Future<void> _continueAsGuest() async {
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final result = await widget.platform.login({'guest': true});
      if (!mounted) return;
      if (result.success) {
        widget.onSuccess();
      } else {
        setState(() => _error = result.error ?? 'Guest mode failed');
      }
    } catch (error) {
      if (mounted) setState(() => _error = 'Guest login error: $error');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Sign in to access your SoundCloud library, playlists, and likes.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.75),
            ),
          ),
          const SizedBox(height: 16),
          LoginBrowserButton(
            label: 'Sign in with SoundCloud',
            onPressed: _checking ? null : _startWebViewLogin,
          ),
          const LoginDivider(),
          LoginTextField(
            controller: _accessTokenController,
            labelText: 'Mobile access token',
            hintText: 'Paste the SoundCloud mobile API access token',
            prefixIcon: const Icon(Icons.key),
            enabled: !_checking,
            onSubmitted: (_) => _submitToken(),
          ),
          const SizedBox(height: 8),
          LoginTextField(
            controller: _refreshTokenController,
            labelText: 'Refresh token (optional)',
            hintText: 'Paste for automatic renewal',
            prefixIcon: const Icon(Icons.autorenew),
            enabled: !_checking,
            onSubmitted: (_) => _submitToken(),
          ),
          const SizedBox(height: 8),
          Text(
            'Use mobile API tokens. A website oauth_token cookie will not work. '
            'Without a refresh token, sign in again when the access token expires.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          LoginPrimaryButton(
            label: 'Connect with token',
            onPressed: _checking ? null : _submitToken,
            isLoading: _checking,
          ),
          if (_error != null)
            LoginErrorBanner(
              message: _error!,
              onDismiss: () => setState(() => _error = null),
            ),
          if (_embeddedBlocked && _desktop) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.amber.withValues(alpha: 0.4)),
              ),
              child: Text(
                'Platform: ${Platform.isLinux
                    ? 'WebKitGTK'
                    : Platform.isWindows
                    ? 'WebView2'
                    : 'WKWebView'}; '
                'app proxy: ${settings.proxyAddress == null ? 'off' : 'on'}.'
                '${_embeddedUserAgent == null ? '' : '\nUser-Agent: $_embeddedUserAgent'}',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ),
          ],
          const SizedBox(height: 16),
          LoginSecondaryButton(
            label: 'Continue as Guest',
            onPressed: _checking ? null : _continueAsGuest,
          ),
        ],
      ),
    );
  }
}
