import 'dart:async';

import 'package:webview_all/webview_all.dart';
import 'package:youtube_explode_dart/js_challenge.dart';
import '../../settings.dart';
import '../../utils/app_webview_proxy.dart';

/// Runs EJS in an offscreen WebView without attaching a page to the UI.
class _YouTubeMusicJavaScript {
  Future<OffscreenWebViewSession>? _session;
  Future<void> _tail = Future.value();
  bool _closed = false;

  Future<OffscreenWebViewSession> _create() async {
    final session = await OffscreenWebViewSession.create();
    try {
      final controller = session.controller;
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      final ready = Completer<void>();
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onHttpAuthRequest:
              !AppWebViewProxy.handlesAuthChallenges ||
                  settings.proxyUsername == null
              ? null
              : AppWebViewProxy.handleHttpAuthRequest,
          onPageFinished: (_) {
            if (!ready.isCompleted) ready.complete();
          },
        ),
      );
      await controller.loadHtmlString(
        '<!doctype html><html><head></head><body></body></html>',
        baseUrl: 'https://www.youtube.com/',
      );
      await ready.future.timeout(const Duration(seconds: 15));
      return session;
    } catch (_) {
      await session.close();
      rethrow;
    }
  }

  Future<Object?> call(
    String body, [
    Map<String, Object?> arguments = const {},
  ]) {
    final result = _tail.then((_) async {
      if (_closed) throw StateError('YouTube JavaScript runtime is closed');
      final pending = _session ??= _create();
      late OffscreenWebViewSession session;
      try {
        session = await pending;
      } catch (_) {
        if (identical(_session, pending)) _session = null;
        rethrow;
      }
      return session.controller
          .callAsyncJavaScript(
            body,
            arguments: arguments,
            timeout: const Duration(seconds: 20),
          )
          .timeout(const Duration(seconds: 22));
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> reset() {
    final result = _tail.then((_) async {
      final pending = _session;
      _session = null;
      if (pending != null) {
        try {
          await (await pending).close().timeout(const Duration(seconds: 5));
        } catch (_) {
          // A dead renderer or failed creation may already be gone.
        }
      }
    });
    _tail = result;
    return result;
  }

  Future<void> close() {
    _closed = true;
    return reset();
  }
}

/// Runs the library's EJS signature and `n` solver in an offscreen WebView.
class YouTubeMusicSignatureSolver extends BaseEJSSolver {
  YouTubeMusicSignatureSolver({this.executeOnRootIsolate});

  /// Optional executor for callers running outside Flutter's root isolate.
  /// Platform WebViews are only available on the root isolate.
  final Future<String> Function(String jsCode)? executeOnRootIsolate;
  final _runtime = _YouTubeMusicJavaScript();
  Future<void>? _ready;

  Future<void> _initialize() async {
    final modules = await EJSBuilder.getJSModules().timeout(
      const Duration(seconds: 20),
    );
    final initialized = await _runtime.call(
      r'''
      // EJS targets a standalone JS runtime. Its generated preamble assigns
      // globalThis.location, which would navigate (and destroy) a WebView page.
      // Give generated player functions their own globals, while leaving the
      // maintained solver source untouched.
      const NativeFunction = globalThis.Function;
      const realGlobal = globalThis;
      const globals = new Proxy(Object.create(null), {
        get(target, key) {
          if (key in target) return target[key];
          const value = realGlobal[key];
          // Browser methods such as matchMedia reject a proxy as `this`.
          // Constructors retain their prototype and should not be rebound.
          return typeof value === 'function' &&
              !Object.prototype.hasOwnProperty.call(value, 'prototype')
            ? value.bind(realGlobal) : value;
        },
        set(target, key, value) { target[key] = value; return true; }
      });
      globals.document = Object.create(null);
      globals.navigator = Object.create(null);
      globals.location = new URL('https://www.youtube.com/watch?v=yt-dlp-wins');
      globals.XMLHttpRequest = {prototype: {}};
      globals.window = globals.self = globals.globalThis = globals;
      function PlayerFunction(...parts) {
        const compiled = NativeFunction(
          'globalThis', 'window', 'self', 'document', 'navigator', 'location',
          'XMLHttpRequest', 'Function', ...parts);
        return function(...args) {
          return compiled.call(globals, globals, globals, globals,
            globals.document, globals.navigator, globals.location,
            globals.XMLHttpRequest, PlayerFunction, ...args);
        };
      }
      globals.Function = PlayerFunction;
      globalThis.saturnSolveYouTube = NativeFunction(
        'Function', source + '\nreturn jsc;')(PlayerFunction);
      return typeof globalThis.saturnSolveYouTube === 'function';
    ''',
      {'source': modules},
    );
    if (initialized != true) {
      throw StateError('YouTube WebView EJS failed to initialize');
    }
  }

  @override
  Future<String> executeJavaScript(String jsCode) async {
    final rootExecutor = executeOnRootIsolate;
    if (rootExecutor != null) return rootExecutor(jsCode);

    final pending = _ready ??= _initialize();
    try {
      await pending;
    } catch (_) {
      if (identical(_ready, pending)) _ready = null;
      rethrow;
    }
    try {
      final result = await _runtime.call(
        'return (function(jsc) { return eval(source); })(globalThis.saturnSolveYouTube);',
        {'source': jsCode},
      );
      if (result is! String) {
        throw StateError('Invalid YouTube signature result');
      }
      return result;
    } catch (error) {
      _ready = null;
      await _runtime.reset();
      if (error is JavaScriptExecutionException) {
        final message = error.message
            .replaceAll(RegExp(r'https?://[^\s]+'), '[URL]')
            .replaceAll(RegExp(r'[A-Za-z0-9_\-=/+]{64,}'), '[data]');
        throw StateError(
          'Signature JavaScript ${error.name ?? 'error'}: '
          '${message.length > 240 ? message.substring(0, 240) : message}',
        );
      }
      rethrow;
    }
  }

  @override
  void dispose() {
    unawaited(_runtime.close());
    super.dispose();
  }
}
