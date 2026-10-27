import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:get_it/get_it.dart';
import 'package:webview_all/webview_all.dart';
import 'package:logging/logging.dart';

import '../../api/definitions.dart';
import '../../platform/deezer/deezer_api.dart';
import '../../platform/deezer/deezer_login.dart';
import '../../platform/deezer/deezer_platform.dart';
import '../../settings.dart';
import '../../service/audio_service.dart';
import '../../translations.i18n.dart';
import '../../ui/app_webview_screen.dart';
import '../../ui/login_components.dart';
import '../../utils/app_webview_proxy.dart';
import '../../utils/logging.dart';
import '../platform_manager.dart';

class DeezerLoginWidget extends StatefulWidget {
  final Function? callback;
  const DeezerLoginWidget({required this.callback, super.key});

  @override
  _DeezerLoginWidgetState createState() => _DeezerLoginWidgetState();
}

class _DeezerLoginWidgetState extends State<DeezerLoginWidget> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _arlController = TextEditingController();

  String? _error;
  bool _isEmailLoading = false;
  bool _isArlLoading = false;
  bool premiumOpen = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _arlController.dispose();
    super.dispose();
  }

  // Initialize deezer etc
  Future _init() async {
    deezerAPI.arl = DeezerPlatform.instance.arl;

    // Pre-cache homepage
    if (!await HomePage().exists()) {
      await deezerAPI.authorize();
      settings.offlineMode = false;
      if (GetIt.I.isRegistered<AudioPlayerHandler>()) {
        unawaited(GetIt.I<AudioPlayerHandler>().retryPendingListenLogs());
      }
      HomePage hp = await PlatformManager.instance.active.getHomePage();
      if (hp.sections.isNotEmpty) await hp.save();
    }
  }

  // Call _init()
  void _start() async {
    if (DeezerPlatform.instance.arl != null) {
      _init().then((_) {
        if (widget.callback != null) widget.callback!();
      });
    }
  }

  // Check if deezer available in current country
  void _checkAvailability() async {
    bool? available = await DeezerAPI.checkAvailability();
    if (!(available ?? false)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Deezer is unavailable'.i18n),
            content: Text(
              'Deezer is unavailable in your country, Saturn might not work properly. Please use a VPN'
                  .i18n,
            ),
            actions: [
              TextButton(
                child: Text('Continue'.i18n),
                onPressed: () {
                  if (context.mounted) Navigator.of(context).pop();
                },
              ),
            ],
          ),
        );
      });
    }
  }

  @override
  void initState() {
    _start();
    _checkAvailability();
    super.initState();
  }

  void _update() async {
    try {
      deezerAPI.arl = DeezerPlatform.instance.arl;
      bool resp = await deezerAPI.rawAuthorize(
        onError: (e) => setState(() => _error = e.toString()),
      );
      if (resp == false) {
        int arlLength = (DeezerPlatform.instance.arl ?? '').length;
        if (arlLength != 175 && arlLength != 192) {
          _error = '${(_error ?? '')} Invalid ARL length!';
        } else {
          _error = _error ?? 'Failed to authorize with Deezer.';
        }
        setState(() => DeezerPlatform.instance.arl = null);
      }
    } catch (e) {
      _error = e.toString();
      if (kDebugMode) {
        appLogger.warning('Login error', e);
      }
      setState(() => DeezerPlatform.instance.arl = null);
    } finally {
      if (mounted) {
        setState(() {
          _isEmailLoading = false;
          _isArlLoading = false;
        });
      }
    }

    await settings.save();
    _start();
  }

  Future<void> _loginWithEmail() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      setState(() => _error = 'Missing email or password!'.i18n);
      return;
    }

    setState(() {
      _isEmailLoading = true;
      _error = null;
    });

    String? arl;
    String? exception;
    try {
      arl = await DeezerLogin.getArlByEmailAndPassword(email, password);
    } on DeezerLoginException catch (dle) {
      exception = dle.toString();
    } catch (e, st) {
      exception = e.toString();
      if (kDebugMode) {
        appLogger.warning('Deezer login failed', e, st);
      }
    }

    if (!mounted) return;

    if (exception == null && arl != null) {
      DeezerPlatform.instance.arl = arl;
      _update();
    } else {
      setState(() {
        _isEmailLoading = false;
        _error = exception ?? 'Could not log in with email.';
      });
    }
  }

  void _submitArl() {
    final input = _arlController.text.trim();
    if (input.isEmpty) {
      setState(() => _error = 'Please enter or paste your ARL token.'.i18n);
      return;
    }
    setState(() {
      _error = null;
      _isArlLoading = true;
    });
    DeezerPlatform.instance.arl = input;
    _update();
  }

  @override
  Widget build(BuildContext context) {
    if (DeezerPlatform.instance.arl != null) {
      return const Padding(
        padding: EdgeInsets.all(32.0),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (settings.noPremium == true && !premiumOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        premiumOpen = true;
        String tier = settings.tier ?? 'Unknown';
        settings.noPremium = false;
        settings.tier = null;
        await settings.save();
        if (!context.mounted) return;
        await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Non-Premium Account'.i18n),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Icon(Icons.account_circle, color: Colors.red, size: 64.0),
                const SizedBox(height: 8.0),
                Text(
                  'Saturn doesn\'t allow for usage of non-paid accounts.'.i18n,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 4.0),
                Text(
                  '${'Current Tier:'.i18n} $tier',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
            actions: <Widget>[
              TextButton(
                child: Text('Dismiss'.i18n),
                onPressed: () async {
                  premiumOpen = false;
                  Navigator.of(context).pop();
                },
              ),
            ],
          ),
        );
      });
    }

    final theme = Theme.of(context);
    final isBusy = _isEmailLoading || _isArlLoading;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            'Log in with your Deezer email and password, or use your ARL token.'
                .i18n,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.75),
            ),
          ),
          const SizedBox(height: 16.0),
          LoginTextField(
            controller: _emailController,
            enabled: !isBusy,
            labelText: 'Email'.i18n,
            prefixIcon: const Icon(Icons.email_outlined),
          ),
          const SizedBox(height: 12.0),
          LoginTextField(
            controller: _passwordController,
            enabled: !isBusy,
            labelText: 'Password'.i18n,
            isPassword: true,
            prefixIcon: const Icon(Icons.lock_outline),
            onSubmitted: (_) => _loginWithEmail(),
          ),
          if (_error != null)
            LoginErrorBanner(
              message: _error!,
              onDismiss: () => setState(() => _error = null),
            ),
          const SizedBox(height: 16.0),
          LoginPrimaryButton(
            label: 'Log In'.i18n,
            onPressed: isBusy ? null : _loginWithEmail,
            isLoading: _isEmailLoading,
          ),
          const LoginDivider(),
          LoginTextField(
            controller: _arlController,
            enabled: !isBusy,
            maxLines: 2,
            minLines: 1,
            labelText: 'Token'.i18n,
            hintText: 'Paste your 192-character ARL token...',
            prefixIcon: const Icon(Icons.key),
            onSubmitted: (_) => _submitArl(),
          ),
          const SizedBox(height: 10),
          LoginHelpSection(
            title: 'How to get your Deezer ARL token?'.i18n,
            content: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '1. Open deezer.com in a desktop web browser and sign in.\n'
                  '2. Press F12 to open Developer Tools.\n'
                  '3. Navigate to Application (Chrome/Edge) or Storage (Firefox) > Cookies > https://www.deezer.com.\n'
                  '4. Find the cookie named "arl" and copy its value (usually 192 characters).\n'
                  '5. Paste the value into the field above and click "Connect with Token".',
                  style: TextStyle(fontSize: 12, height: 1.45),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16.0),
          LoginPrimaryButton(
            label: 'Connect with Token'.i18n,
            onPressed: isBusy ? null : _submitArl,
            isLoading: _isArlLoading,
          ),
          const SizedBox(height: 8.0),
          LoginBrowserButton(
            label: 'Login using browser'.i18n,
            onPressed: isBusy
                ? null
                : () => openAppWebView(
                    context: context,
                    serviceName: 'Deezer',
                    child: LoginBrowser(_update),
                  ),
          ),
        ],
      ),
    );
  }
}

class LoginBrowser extends StatefulWidget {
  final Function updateParent;
  const LoginBrowser(this.updateParent, {super.key});

  @override
  State<LoginBrowser> createState() => _LoginBrowserState();
}

class _LoginBrowserState extends State<LoginBrowser> {
  late final WebViewController controller;

  @override
  void initState() {
    super.initState();
    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onHttpAuthRequest:
              !AppWebViewProxy.handlesAuthChallenges ||
                  settings.proxyUsername == null
              ? null
              : AppWebViewProxy.handleHttpAuthRequest,
          onNavigationRequest: (NavigationRequest request) {
            final loadedUri = Uri.parse(request.url);

            // Parse arl from url
            if (request.url.startsWith('intent://deezer.page.link') ||
                request.url.startsWith('intent://dzr.page.link')) {
              try {
                Uri linkUri = Uri.parse(loadedUri.queryParameters['link']!);
                String? arl = linkUri.queryParameters['arl'];
                DeezerPlatform.instance.arl = arl;
                // Clear cookies for next login after logout
                WebViewCookieManager().clearCookies();
                if (mounted && Navigator.canPop(context)) {
                  Navigator.of(context).pop();
                }
                widget.updateParent();
              } catch (e) {
                Logger.root.severe('Error loading ARL from browser login: $e');
              }
              return NavigationDecision.prevent;
            }

            return NavigationDecision.navigate;
          },
          onPageStarted: (String url) {
            final loadedUri = Uri.parse(url);
            if (!loadedUri.path.contains('/login') &&
                !loadedUri.path.contains('/register')) {
              controller.runJavaScript('window.location.href = "/open_app"');
            }
          },
        ),
      )
      ..loadRequest(Uri.parse('https://deezer.com/login'));
  }

  @override
  Widget build(BuildContext context) {
    return WebViewWidget(controller: controller);
  }
}
