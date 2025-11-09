import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:logging/logging.dart';
import '../api/deezer_login.dart';

import '../ui/toast.dart';
import '../api/deezer.dart';
import '../api/definitions.dart';
import '../settings.dart';
import '../translations.i18n.dart';
import 'home_screen.dart';

class LoginWidget extends StatefulWidget {
  final Function? callback;
  const LoginWidget({required this.callback, super.key});

  @override
  _LoginWidgetState createState() => _LoginWidgetState();
}

class _LoginWidgetState extends State<LoginWidget> {
  String? _arl;
  String? _error;

  //Initialize deezer etc
  Future _init() async {
    deezerAPI.arl = settings.arl;
    //await GetIt.I<AudioPlayerHandler>().start();

    //Pre-cache homepage
    if (!await HomePage().exists()) {
      await deezerAPI.authorize();
      settings.offlineMode = false;
      HomePage hp = await deezerAPI.homePage();
      if (hp.sections.isNotEmpty) await hp.save();
    }
  }

  //Call _init()
  void _start() async {
    if (settings.arl != null) {
      _init().then((_) {
        if (widget.callback != null) widget.callback!();
      });
    }
  }

  //Check if deezer available in current country
  void _checkAvailability() async {
    bool? available = await DeezerAPI.checkAvailability();
    if (!(available ?? false)) {
      // Avoid showing a dialog during init/build phase. Schedule it after the
      // first frame so we don't call setState/push routes while widgets are
      // being built.
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

  void errorDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Error'.i18n),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Error logging in! Please check your token and internet connection and try again.'
                    .i18n,
              ),
              if (_error != null) Text('\n\n$_error'),
            ],
          ),
          actions: <Widget>[
            TextButton(
              child: Text('Dismiss'.i18n),
              onPressed: () {
                _error = null;
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }

  void _update() async {
    setState(() => {});

    //Try logging in
    try {
      deezerAPI.arl = settings.arl;
      bool resp = await deezerAPI.rawAuthorize(
        onError: (e) => setState(() => _error = e.toString()),
      );
      if (resp == false) {
        //false, not null
        int arlLength = (settings.arl ?? '').length;
        if (arlLength != 175 && arlLength != 192) {
          _error = '${(_error ?? '')}Invalid ARL length!';
        }
        setState(() => settings.arl = null);
        errorDialog();
      }
      //On error show dialog and reset to null
    } catch (e) {
      _error = e.toString();
      if (kDebugMode) {
        print('Login error: $e');
      }
      setState(() => settings.arl = null);
      errorDialog();
    }

    await settings.save();
    _start();
  }

  // ARL auth: called on "Save" click, Enter and DPAD_Center press
  void goARL(FocusNode? node, TextEditingController controller) {
    node?.unfocus();
    controller.clear();
    settings.arl = _arl?.trim();
    Navigator.of(context).pop();
    _update();
  }

  bool premiumOpen = false;

  @override
  Widget build(BuildContext context) {
    //If arl is null, show loading
    if (settings.arl != null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    TextEditingController controller = TextEditingController();
    // For "DPAD center" key handling on remote controls
    FocusNode focusNode = FocusNode(
      skipTraversal: true,
      descendantsAreFocusable: false,
      onKeyEvent: (node, event) {
        if (event.logicalKey == LogicalKeyboardKey.select) {
          goARL(node, controller);
        }
        return KeyEventResult.handled;
      },
    );
    if (settings.noPremium == true && !premiumOpen) {
      // Avoid side-effects and showing dialogs directly during build.
      // Schedule the dialog and the settings mutation after the frame.
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        premiumOpen = true;
        String tier = settings.tier ?? 'Unknown';
        settings.noPremium = false;
        settings.tier = null;
        await settings.save();
        await showDialog(
          // ignore: use_build_context_synchronously
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Non-Premium Account'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Icon(Icons.account_circle, color: Colors.red, size: 64.0),
                Container(height: 4.0),
                Text(
                  'Saturn doesn\'t allow for usage of non-paid accounts.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                Container(height: 4.0),
                Text(
                  'Current Tier: $tier',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                Container(height: 16.0),
              ],
            ),
            actions: <Widget>[
              TextButton(
                child: Text('Dismiss'),
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
    if (settings.arl == null) {
      return Scaffold(
        body: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0),
          child: ListView(
            children: <Widget>[
              const FreezerTitle(),
              Container(height: 8.0),
              Text(
                'Please login using your Deezer account.'.i18n,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16.0),
              ),
              Container(height: 16.0),
              //Email login dialog
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32.0),
                child: OutlinedButton(
                  child: Text('Login with email'.i18n),
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (context) => EmailLogin(_update),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32.0),
                child: OutlinedButton(
                  child: Text('Login using browser'.i18n),
                  onPressed: () {
                    if (Platform.isLinux) {
                      showDialog(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: Text('Login using browser'.i18n),
                          content: Text(
                            'Login using browser is not supported on Linux. Please use a different method.',
                          ),
                          actions: [
                            TextButton(
                              child: Text('Dismiss'.i18n),
                              onPressed: () {
                                Navigator.of(context).pop();
                              },
                            ),
                          ],
                        ),
                      );
                    } else {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) => LoginBrowser(_update),
                        ),
                      );
                    }
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32.0),
                child: OutlinedButton(
                  child: Text('Login using token'.i18n),
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (context) {
                        Future.delayed(
                          const Duration(seconds: 1),
                          () => {focusNode.requestFocus()},
                        );
                        return AlertDialog(
                          title: Text('Enter ARL'.i18n),
                          content: TextField(
                            onChanged: (String s) => _arl = s,
                            decoration: InputDecoration(
                              labelText: 'Token (ARL)'.i18n,
                            ),
                            focusNode: focusNode,
                            controller: controller,
                            onSubmitted: (String s) {
                              goARL(focusNode, controller);
                            },
                          ),
                          actions: <Widget>[
                            TextButton(
                              child: Text('Save'.i18n),
                              onPressed: () => goARL(null, controller),
                            ),
                          ],
                        );
                      },
                    );
                  },
                ),
              ),
              Container(height: 16.0),
              Container(height: 8.0),
              const Divider(),
              Container(height: 8.0),
              Text(
                '2k25 saturn.kim'.i18n,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16.0),
              ),
            ],
          ),
        ),
      );
    }
    return Container();
  }
}

class LoginBrowser extends StatelessWidget {
  final Function updateParent;
  const LoginBrowser(this.updateParent, {super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Expanded(
          child: InAppWebView(
            initialUrlRequest: URLRequest(
              url: WebUri('https://deezer.com/login'),
            ),
            onLoadStart:
                (InAppWebViewController controller, WebUri? loadedUri) async {
                  //Offers URL
                  if (!loadedUri!.path.contains('/login') &&
                      !loadedUri.path.contains('/register')) {
                    controller.evaluateJavascript(
                      source: 'window.location.href = "/open_app"',
                    );
                  }

                  //Parse arl from url
                  if (loadedUri.toString().startsWith(
                        'intent://deezer.page.link',
                      ) ||
                      loadedUri.toString().startsWith(
                        'intent://dzr.page.link',
                      )) {
                    try {
                      //Actual url is in `link` query parameter
                      Uri linkUri = Uri.parse(
                        loadedUri.queryParameters['link']!,
                      );
                      String? arl = linkUri.queryParameters['arl'];
                      settings.arl = arl;
                      // Clear cookies for next login after logout
                      CookieManager.instance().deleteAllCookies();
                      Navigator.of(context).pop();
                      updateParent();
                    } catch (e) {
                      Logger.root.severe(
                        'Error loading ARL from browser login: $e',
                      );
                    }
                  }
                },
          ),
        ),
      ],
    );
  }
}

class EmailLogin extends StatefulWidget {
  final Function callback;
  const EmailLogin(this.callback, {super.key});

  @override
  _EmailLoginState createState() => _EmailLoginState();
}

class _EmailLoginState extends State<EmailLogin> {
  String? _email;
  String? _password;
  bool _loading = false;

  Future _login() async {
    setState(() => _loading = true);
    //Try logging in
    String? arl;
    String? exception;
    try {
      arl = await DeezerLogin.getArlByEmailAndPassword(_email!, _password!);
    } on DeezerLoginException catch (dle) {
      exception = dle.toString();
    } catch (e, st) {
      exception = e.toString();
      if (kDebugMode) {
        print(e);
        print(st);
      }
    }
    setState(() => _loading = false);
    settings.arl = arl;
    if (mounted) Navigator.of(context).pop();

    if (exception == null) {
      //Success
      widget.callback();
      return;
    } else if (mounted) {
      //Error
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Error logging in!'.i18n),
          content: Text(
            'Error logging in using email, please check your credentials.\n\nError: ${exception!}',
          ),
          actions: [
            TextButton(
              child: Text('Dismiss'.i18n),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Email Login'.i18n),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: _loading
            ? [const CircularProgressIndicator()]
            : [
                TextField(
                  decoration: InputDecoration(labelText: 'Email'.i18n),
                  onChanged: (s) => _email = s,
                ),
                Container(height: 8.0),
                TextField(
                  obscureText: true,
                  decoration: InputDecoration(labelText: 'Password'.i18n),
                  onChanged: (s) => _password = s,
                ),
              ],
      ),
      actions: [
        if (!_loading)
          TextButton(
            child: const Text('Login'),
            onPressed: () async {
              if (_email != null && _password != null) {
                await _login();
              } else {
                Fluttertoast.showToast(
                  msg: 'Missing email or password!'.i18n,
                  gravity: ToastGravity.BOTTOM,
                  toastLength: Toast.LENGTH_SHORT,
                );
              }
            },
          ),
      ],
    );
  }
}
