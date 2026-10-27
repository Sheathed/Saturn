import 'dart:async';
import 'dart:io';

import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import 'package:saturn/service/audio_service.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

class TrayService {
  static TrayService? _instance;

  final Logger _logger = Logger('TrayService');
  bool _isInitialized = false;
  TrayIcon? _trayIcon;
  Image? _icon;
  Menu? _contextMenu;
  final List<MenuItem> _menuItems = [];
  ListenerId? _trayListenerId;

  TrayService._();

  static Future<TrayService> getInstance() async {
    _instance ??= TrayService._();
    return _instance!;
  }

  Future<void> initialize() async {
    if (_isInitialized ||
        (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux)) {
      return;
    }

    try {
      final trayIcon = TrayIcon.create();
      if (trayIcon == null) {
        throw StateError('The native tray icon could not be created.');
      }

      final iconPath = Platform.isWindows
          ? 'assets/icon-taskbar-white.ico'
          : 'assets/icon-taskbar-white.png';
      final icon = ImageAsset.fromAsset(iconPath);
      if (icon == null) {
        trayIcon.dispose();
        throw ArgumentError.value(iconPath, 'iconPath', 'Unable to load tray icon');
      }

      _trayIcon = trayIcon;
      _icon = icon;
      trayIcon
        ..icon = icon
        ..setTooltip('Saturn')
        ..setVisible(true);

      _trayListenerId = trayIcon.addListener(_onTrayEvent);
      await _createMenu();
      _isInitialized = true;
    } catch (error, stackTrace) {
      await _disposeNativeObjects();
      _logger.warning('Could not initialize the system tray.', error, stackTrace);
    }
  }

  Future<void> _createMenu() async {
    final trayIcon = _trayIcon;
    if (trayIcon == null) return;

    final menu = Menu.create();
    if (menu == null) throw StateError('The native tray menu could not be created.');

    MenuItem createItem(String label, Future<void> Function() onClick) {
      final item = MenuItem.createWithLabelAndType(label, MenuItemType.normal);
      if (item == null) throw StateError('Could not create tray menu item: $label');
      item.addListener((event) {
        if (event is MenuItemClickedEvent) unawaited(onClick());
      });
      _menuItems.add(item);
      menu.addItem(item);
      return item;
    }

    createItem('Open Saturn', _showWindow);
    createItem('Play/Pause', () async {
      final player = GetIt.I<AudioPlayerHandler>();
      if (player.player.playing) {
        await player.pause();
      } else {
        await player.play();
      }
    });
    createItem('Next', () async {
      await GetIt.I<AudioPlayerHandler>().skipToNext();
    });
    createItem('Previous', () async {
      await GetIt.I<AudioPlayerHandler>().skipToPrevious();
    });
    menu.addSeparator();
    createItem('Exit', () async {
      await destroy();
      exit(0);
    });

    trayIcon.setContextMenu(menu);
    // Linux StatusNotifierItem hosts won't publish the menu when its trigger
    // is left at `none`. Configure it after attaching the menu as well.
    trayIcon.setContextMenuTrigger(ContextMenuTrigger.rightClicked);
    _contextMenu = menu;
  }

  void _onTrayEvent(TrayIconEvent event) {
    switch (event) {
      case TrayIconClickedEvent():
        // The native Linux StatusNotifierItem protocol does not report icon
        // clicks to the app. Linux users can choose Open Saturn from its menu.
        unawaited(_showWindow());
      case TrayIconRightClickedEvent():
        // The attached menu opens natively through the configured trigger.
        break;
      case TrayIconDoubleClickedEvent():
        unawaited(_showWindow());
    }
  }

  Future<void> _showWindow() async {
    if (await windowManager.isMinimized()) {
      await windowManager.restore();
    }
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _disposeNativeObjects() async {
    final trayIcon = _trayIcon;
    final listenerId = _trayListenerId;
    if (trayIcon != null && listenerId != null) {
      trayIcon.removeListener(listenerId);
    }
    _trayListenerId = null;

    // Release the icon after the tray has stopped referencing it.
    trayIcon?.dispose();
    _trayIcon = null;
    _icon?.dispose();
    _icon = null;

    for (final item in _menuItems) {
      item.dispose();
    }
    _menuItems.clear();
    _contextMenu?.dispose();
    _contextMenu = null;
  }

  Future<void> destroy() async {
    if (!_isInitialized && _trayIcon == null) return;
    await _disposeNativeObjects();
    _isInitialized = false;
  }
}
