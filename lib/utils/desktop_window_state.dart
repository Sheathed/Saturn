import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import 'app_config.dart';
import 'logging.dart';

/// Persists desktop window geometry and restores maximized/minimized state.
class DesktopWindowState {
  DesktopWindowState._();

  static final DesktopWindowState instance = DesktopWindowState._();
  static const _fileName = 'window_state.json';
  static const _minimumWindowSize = Size(350, 500);

  Timer? _saveTimer;
  Rect? _normalBounds;
  bool _maximized = false;
  bool _minimized = false;
  bool _restoring = false;
  bool _initialized = false;
  bool _closeInProgress = false;
  bool _allowClose = false;
  Future<void> Function()? _shutdownCallback;
  Window? _window;
  ListenerId? _listenerId;

  void setShutdownCallback(Future<void> Function() callback) {
    _shutdownCallback = callback;
  }

  Future<void> initializeAndRestore() async {
    if (_initialized) return;
    _initialized = true;
    if (!Platform.isLinux && !Platform.isWindows && !Platform.isMacOS) return;

    final window = WindowManager.instance.getCurrent();
    _window = window;
    if (window == null) return;

    _restoring = true;
    try {
      final state = await _readState();
      if (state != null) {
        final bounds = _rectFromJson(state['bounds']);
        if (bounds != null &&
            bounds.width >= _minimumWindowSize.width &&
            bounds.height >= _minimumWindowSize.height) {
          _normalBounds = bounds;
          window.bounds = bounds.toNative();
        }
        _maximized = state['maximized'] == true;
        _minimized = state['minimized'] == true;
      } else {
        _maximized = window.isMaximized;
        _minimized = window.isMinimized;
      }
      window.title = appTitle;
      // Keep the native window alive while Dart services are shut down. The
      // Linux MPV backend owns native callbacks that must be released before
      // Flutter tears down its engine.
      _listenerId = window.addListener(_onWindowEvent);
      if (!_maximized && !_minimized) {
        _normalBounds ??= window.bounds.toRect();
      }
      if (_maximized) window.maximize();
      if (_minimized) {
        window.show();
        window.minimize();
      }
    } finally {
      _restoring = false;
    }
    _scheduleSave();
  }

  void _onWindowEvent(WindowEvent event) {
    switch (event) {
      case WindowMovedEvent():
      case WindowResizedEvent():
        _scheduleSave();
      case WindowMaximizedEvent():
        _maximized = true;
        _minimized = false;
        _scheduleSave();
      case WindowMinimizedEvent():
        _minimized = true;
        _scheduleSave();
      case WindowRestoredEvent():
        if (_minimized) {
          _minimized = false;
        } else if (_maximized) {
          _maximized = false;
        } else {
          _minimized = false;
        }
        _scheduleSave();
      case WindowCloseRequestedEvent(:final request):
        if (_allowClose) return;
        if (request.isCancelable) {
          request.cancel();
        }
        if (_closeInProgress) return;
        _closeInProgress = true;
        _saveTimer?.cancel();
        unawaited(_closeGracefully());
      default:
        break;
    }
  }

  Future<Map<String, dynamic>?> _readState() async {
    try {
      final file = File(await _statePath());
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (error, stackTrace) {
      appLogger.warning(
        'Could not read saved desktop window state',
        error,
        stackTrace,
      );
      return null;
    }
  }

  Future<String> _statePath() async =>
      p.join((await getFlavorSupportDirectory()).path, _fileName);

  void _scheduleSave() {
    if (_restoring) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 350), () {
      unawaited(_saveState());
    });
  }

  Future<void> _saveState() async {
    final window = _window;
    if (window == null) return;
    try {
      _minimized = window.isMinimized;
      _maximized = window.isMaximized || _maximized;
      if (!_minimized && !_maximized) {
        final bounds = window.bounds.toRect();
        if (bounds.width >= _minimumWindowSize.width &&
            bounds.height >= _minimumWindowSize.height) {
          _normalBounds = bounds;
        }
      }
      final bounds = _normalBounds;
      final data = <String, Object?>{
        'bounds': bounds == null
            ? null
            : <String, double>{
                'x': bounds.left,
                'y': bounds.top,
                'width': bounds.width,
                'height': bounds.height,
              },
        'maximized': _maximized,
        'minimized': _minimized,
      };
      final file = File(await _statePath());
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(data), flush: true);
    } catch (error, stackTrace) {
      appLogger.warning(
        'Could not save desktop window state',
        error,
        stackTrace,
      );
    }
  }

  Rect? _rectFromJson(Object? raw) {
    if (raw is! Map) return null;
    final x = (raw['x'] as num?)?.toDouble();
    final y = (raw['y'] as num?)?.toDouble();
    final width = (raw['width'] as num?)?.toDouble();
    final height = (raw['height'] as num?)?.toDouble();
    if (x == null || y == null || width == null || height == null) return null;
    if (![x, y, width, height].every((value) => value.isFinite)) return null;
    return Rect.fromLTWH(x, y, width, height);
  }

  Future<void> _closeGracefully() async {
    try {
      // prevent-close keeps native window APIs and plugin channels available
      // while the final geometry snapshot and service cleanup run.
      await _saveState();
      await _shutdownCallback?.call();
    } catch (error, stackTrace) {
      appLogger.warning(
        'Error while shutting down desktop services',
        error,
        stackTrace,
      );
    } finally {
      try {
        _allowClose = true;
        final listenerId = _listenerId;
        if (listenerId != null) {
          _window?.removeListener(listenerId);
          _listenerId = null;
        }
        _window?.close();
      } catch (error, stackTrace) {
        appLogger.warning(
          'Could not close desktop window cleanly',
          error,
          stackTrace,
        );
      }
    }
  }
}
