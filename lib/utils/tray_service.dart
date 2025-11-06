import 'dart:io';
import 'package:get_it/get_it.dart';
import 'package:saturn/service/audio_service.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

class TrayService {
  static TrayService? _instance;
  bool _isInitialized = false;

  TrayService._();

  static Future<TrayService> getInstance() async {
    _instance ??= TrayService._();
    return _instance!;
  }

  Future<void> initialize() async {
    if (_isInitialized) return;

    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      // Set up tray manager event handlers
      trayManager.addListener(_TrayListener());

      // Load the app icon for the tray
      final iconPath = Platform.isWindows
          ? 'assets/icon-taskbar-white.ico'
          : 'assets/icon-taskbar-white.png';
      await trayManager.setIcon(iconPath);

      // Create the tray menu
      await _createMenu();

      _isInitialized = true;
    }
  }

  Future<void> _createMenu() async {
    Menu menu = Menu(
      items: [
        MenuItem(
          label: 'Restore',
          onClick: (_) async {
            await windowManager.show();
            await windowManager.focus();
          },
        ),
        MenuItem(
          label: 'Play',
          onClick: (_) async {
            GetIt.I<AudioPlayerHandler>().play();
          },
        ),
        MenuItem(
          label: 'Next',
          onClick: (_) async {
            GetIt.I<AudioPlayerHandler>().skipToNext();
          },
        ),
        MenuItem(
          label: 'Previous',
          onClick: (_) async {
            GetIt.I<AudioPlayerHandler>().skipToPrevious();
          },
        ),
        MenuItem(
          label: 'Exit',
          onClick: (_) async {
            await trayManager.destroy();
            exit(0);
          },
        ),
      ],
    );

    await trayManager.setContextMenu(menu);
  }

  Future<void> destroy() async {
    if (_isInitialized) {
      await trayManager.destroy();
      _isInitialized = false;
    }
  }
}

class _TrayListener with TrayListener {
  @override
  void onTrayIconMouseDown() async {
    // Show window on tray icon click
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  void onTrayIconRightMouseDown() async {
    await trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {}
}
