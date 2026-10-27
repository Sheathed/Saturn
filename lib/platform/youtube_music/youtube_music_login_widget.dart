import 'package:material_ui/material_ui.dart';
import 'package:webview_all/webview_all.dart';

import 'youtube_music_platform.dart';
import '../../settings.dart';
import '../../ui/app_webview_screen.dart';
import '../../ui/login_components.dart';
import '../../utils/app_webview_proxy.dart';

/// Interactive login widget allowing users to authenticate with YouTube Music
/// using a cookie string or SAPISID token.
class YouTubeMusicLoginWidget extends StatefulWidget {
  const YouTubeMusicLoginWidget({
    required this.platform,
    required this.onSuccess,
    super.key,
  });

  final YouTubeMusicPlatform platform;
  final VoidCallback onSuccess;

  @override
  State<YouTubeMusicLoginWidget> createState() =>
      _YouTubeMusicLoginWidgetState();
}

class _YouTubeMusicLoginWidgetState extends State<YouTubeMusicLoginWidget> {
  final TextEditingController _controller = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;
  bool _checkingWebViewSession = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final rawInput = _controller.text.trim();
    if (rawInput.isEmpty) {
      setState(() {
        _errorMessage = 'Please enter or paste your cookie or SAPISID token.';
      });
      return;
    }

    await _authenticateCookie(rawInput);
  }

  Future<void> _authenticateCookie(String cookie, {String? visitorData}) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final result = await widget.platform.login({
        'cookie': cookie,
        if (visitorData != null && visitorData.isNotEmpty)
          'visitorData': visitorData,
      });
      if (!mounted) return;

      if (result.success) {
        widget.onSuccess();
      } else {
        setState(() {
          _errorMessage =
              result.error ??
              'Authentication failed. Please verify that your cookie contains a valid SAPISID session.';
          _isLoading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Login error: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _startWebViewLogin() async {
    final controller = WebViewController();
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    BuildContext? currentWebViewContext;

    void closeWebView() {
      if (currentWebViewContext != null && currentWebViewContext!.mounted) {
        Navigator.of(currentWebViewContext!).pop(true);
      }
    }

    await controller.setNavigationDelegate(
      NavigationDelegate(
        onPageFinished: (_) => _captureWebViewSession(
          controller: controller,
          onCaptured: closeWebView,
        ),
        onHttpAuthRequest:
            !AppWebViewProxy.handlesAuthChallenges ||
                settings.proxyUsername == null
            ? null
            : AppWebViewProxy.handleHttpAuthRequest,
      ),
    );

    await controller.loadRequest(
      Uri.parse(
        'https://accounts.google.com/ServiceLogin?continue='
        'https%3A%2F%2Fmusic.youtube.com',
      ),
    );

    if (!mounted) return;
    setState(() => _errorMessage = null);

    await openAppWebView(
      context: context,
      serviceName: 'YouTube Music',
      controller: controller,
      actions: [
        IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: 'Reload',
          onPressed: () => controller.reload(),
        ),
        Builder(
          builder: (actionContext) {
            currentWebViewContext = actionContext;
            return TextButton.icon(
              icon: const Icon(Icons.verified_user_outlined),
              label: const Text('Use session'),
              onPressed: () => _captureWebViewSession(
                controller: controller,
                onCaptured: closeWebView,
              ),
            );
          },
        ),
      ],
    );
  }

  Future<void> _captureWebViewSession({
    required WebViewController controller,
    VoidCallback? onCaptured,
  }) async {
    if (_isLoading || _checkingWebViewSession) {
      return;
    }
    _checkingWebViewSession = true;
    try {
      final cookie = await widget.platform.readWebViewCookieHeader();
      if (!RegExp(r'(?:^|;\s*)SAPISID=[^;]+').hasMatch(cookie)) return;

      String? visitorData;
      try {
        final result = await controller.runJavaScriptReturningResult(
          'window.yt&&window.yt.config_?window.yt.config_.VISITOR_DATA:""',
        );
        if (result is String && result.isNotEmpty) visitorData = result;
      } catch (_) {}
      onCaptured?.call();
      await _authenticateCookie(cookie, visitorData: visitorData);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage =
            'Could not read the YouTube Music WebView session: $error';
      });
    } finally {
      _checkingWebViewSession = false;
    }
  }

  Future<void> _continueAsGuest() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final result = await widget.platform.login({
        'guest': true,
      });
      if (!mounted) return;
      if (result.success) {
        widget.onSuccess();
      } else {
        setState(() {
          _errorMessage =
              result.error ?? 'Failed to enter guest mode.';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Guest login error: $e';
      });
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
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
            'Log in to access your personal library, liked songs, and playlists.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.textTheme.bodyMedium?.color?.withValues(
                alpha: 0.75,
              ),
            ),
          ),
          const SizedBox(height: 16),
          LoginBrowserButton(
            label: 'Sign in with Google',
            onPressed: _isLoading ? null : _startWebViewLogin,
          ),
          const LoginDivider(),
          LoginTextField(
            controller: _controller,
            enabled: !_isLoading,
            maxLines: 3,
            minLines: 1,
            labelText: 'Cookie / SAPISID Token',
            hintText: 'Paste SAPISID token or full Cookie header here...',
            prefixIcon: const Icon(Icons.key),
            onSubmitted: (_) => _submit(),
          ),
          if (_errorMessage != null)
            LoginErrorBanner(
              message: _errorMessage!,
              onDismiss: () => setState(() => _errorMessage = null),
            ),
          if (widget.platform.sessionExpired) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.amber.withValues(alpha: 0.4)),
              ),
              child: const Row(
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    color: Colors.amber,
                    size: 22,
                  ),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Your previous YouTube Music session expired. You are currently browsing as a guest. Paste a new cookie or SAPISID token to re-link your library.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 10),
          const LoginHelpSection(
            title: 'How to get your YouTube Music token / cookie?',
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Follow these steps:',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                SizedBox(height: 6),
                Text(
                  '1. Open music.youtube.com in your web browser and sign in.\n'
                  '2. Open Developer Tools (F12) > Application/Storage > Cookies.\n'
                  '3. Locate the SAPISID cookie and copy its value (or copy the entire Cookie header from any Network request).\n'
                  '4. Paste it here and click "Log In".',
                  style: TextStyle(fontSize: 12, height: 1.45),
                ),
                SizedBox(height: 6),
                Text(
                  'Supported formats: Raw SAPISID token, SAPISID=..., full Cookie header, and Metrolist/ytmusicapi exports.',
                  style: TextStyle(
                    fontSize: 11,
                    fontStyle: FontStyle.italic,
                    color: Colors.grey,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          LoginPrimaryButton(
            label: 'Log In',
            onPressed: _submit,
            isLoading: _isLoading,
          ),
          const SizedBox(height: 8),
          LoginSecondaryButton(
            label: 'Continue as Guest',
            onPressed: _isLoading ? null : _continueAsGuest,
          ),
        ],
      ),
    );
  }
}
