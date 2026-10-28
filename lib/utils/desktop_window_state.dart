import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import 'app_config.dart';
import 'logging.dart';

/// Persists desktop window geometry and restores maximized/minimized state.
class DesktopWindowState with WindowListener {
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

  Future<void> initializeAndRestore() async {
    if (_initialized) return;
    _initialized = true;
    await windowManager.ensureInitialized();
    _restoring = true;
    try {
      final state = await _readState();
      if (state != null) {
        final bounds = _rectFromJson(state['bounds']);
        if (bounds != null &&
            bounds.width >= _minimumWindowSize.width &&
            bounds.height >= _minimumWindowSize.height) {
          _normalBounds = bounds;
          await windowManager.setBounds(bounds);
        }
        _maximized = state['maximized'] == true;
        _minimized = state['minimized'] == true;
      } else {
        _maximized = await windowManager.isMaximized();
        _minimized = await windowManager.isMinimized();
      }
      await windowManager.setTitle(appTitle);
      windowManager.addListener(this);
      if (!_maximized && !_minimized) {
        _normalBounds ??= await windowManager.getBounds();
      }
      if (_maximized) await windowManager.maximize();
      if (_minimized) {
        await windowManager.show();
        await windowManager.minimize();
      }
    } finally {
      _restoring = false;
    }
    _scheduleSave();
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
    try {
      _minimized = await windowManager.isMinimized();
      _maximized = await windowManager.isMaximized() || _maximized;
      if (!_minimized && !_maximized) {
        final bounds = await windowManager.getBounds();
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

  @override
  void onWindowMove() => _scheduleSave();

  @override
  void onWindowResize() => _scheduleSave();

  @override
  void onWindowMoved() => _scheduleSave();

  @override
  void onWindowResized() => _scheduleSave();

  @override
  void onWindowMaximize() {
    _maximized = true;
    _minimized = false;
    _scheduleSave();
  }

  @override
  void onWindowUnmaximize() {
    _maximized = false;
    _scheduleSave();
  }

  @override
  void onWindowMinimize() {
    _minimized = true;
    _scheduleSave();
  }

  @override
  void onWindowRestore() {
    _minimized = false;
    _scheduleSave();
  }

  @override
  void onWindowClose() {
    _saveTimer?.cancel();
    unawaited(_saveState());
  }
}
