import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import 'music_platform.dart';
import 'platform_registry.dart';

/// Manages the currently active platform and provides a convenient global
/// access point that replaces the old `deezerAPI` singleton.
///
/// The active platform is set from [Settings.activePlatformId] on startup and
/// can be changed by the platform switcher UI.
class PlatformManager extends ChangeNotifier {
  PlatformManager._();
  static final PlatformManager instance = PlatformManager._();

  static final _log = Logger('PlatformManager');

  MusicPlatform? _active;

  /// The currently active platform. Throws if not yet initialized.
  MusicPlatform get active {
    assert(_active != null,
        'PlatformManager.initialize() must be called before accessing .active');
    return _active!;
  }

  /// Get a specific platform by ID, or fall back to active.
  MusicPlatform getPlatform(String platformId) {
    return PlatformRegistry.instance.get(platformId) ?? active;
  }

  String get activePlatformId => _active!.platformId;

  bool get isInitialized => _active != null;

  int _loggedInCount = 0;
  int get loggedInCount => _loggedInCount;
  bool get hasMultipleLoggedInPlatforms => _loggedInCount > 1;

  Future<void> refreshLoggedInStatus() async {
    try {
      final list = await PlatformRegistry.instance.loggedInPlatforms;
      if (_loggedInCount != list.length) {
        _loggedInCount = list.length;
        notifyListeners();
      }
    } catch (_) {}
  }

  /// Switch to [platformId] as the active platform.
  /// The platform must already be registered in [PlatformRegistry].
  void switchPlatform(String platformId) {
    final platform = PlatformRegistry.instance.get(platformId);
    if (platform == null) {
      _log.severe('Cannot switch to unknown platform: $platformId');
      throw ArgumentError('Platform "$platformId" is not registered.');
    }
    _log.info('Switching active platform to: $platformId');
    _active = platform;
    refreshLoggedInStatus();
    notifyListeners();
  }

  /// Initialize from a saved [platformId].  Falls back to the first registered
  /// platform if [platformId] is null or unknown.
  void initialize({String? platformId}) {
    final all = PlatformRegistry.instance.allPlatforms;
    if (all.isEmpty) {
      throw StateError('No platforms registered. Call PlatformRegistry.instance.register() first.');
    }

    if (platformId != null) {
      final p = PlatformRegistry.instance.get(platformId);
      if (p != null) {
        _active = p;
        _log.info('Active platform initialized to: $platformId');
        return;
      }
      _log.warning('Saved platform "$platformId" not found, falling back.');
    }

    _active = all.first;
    _log.info('Active platform defaulting to: ${_active!.platformId}');
    refreshLoggedInStatus();
  }
}
