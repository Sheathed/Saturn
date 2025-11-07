import 'dart:io';
import 'package:windows_single_instance/windows_single_instance.dart';
import 'package:unix_single_instance/unix_single_instance.dart';
import 'package:window_manager/window_manager.dart';

class SingleInstanceService {
  static SingleInstanceService? _instance;
  dynamic _singleInstance;
  bool _isInitialized = false;

  SingleInstanceService._();

  static Future<SingleInstanceService> getInstance() async {
    _instance ??= SingleInstanceService._();
    return _instance!;
  }

  Future<void> initialize() async {
    if (_isInitialized) return;

    if (Platform.isWindows) {
      await WindowsSingleInstance.ensureSingleInstance(
        [],
        'saturn_music_app',
        onSecondWindow: (args) async {
          await windowManager.show();
          await windowManager.focus();
        },
      );
    } else if (Platform.isLinux || Platform.isMacOS) {
      _singleInstance = await unixSingleInstance([], (args) async {
        await windowManager.show();
        await windowManager.focus();
      });
    }

    _isInitialized = true;
  }

  Future<bool> isFirstInstance() async {
    if (!_isInitialized) return true;

    if (Platform.isLinux || Platform.isMacOS) {
      return _singleInstance ?? true;
    }

    // For Windows, we already handle this in initialize()
    return true;
  }
}
