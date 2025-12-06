import 'dart:async';
import 'dart:io';
import 'package:sqflite/sqflite.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../api/download_isolate.dart';
import '../api/download_log.dart';
import '../settings.dart';
import '../service/download_background_service.dart';

/// Download Service - acts as UI client for the download isolate coordinator
class DownloadServiceDart {
  static final DownloadServiceDart _instance = DownloadServiceDart._internal();
  factory DownloadServiceDart() => _instance;
  DownloadServiceDart._internal();

  bool running = false;
  int queueSize = 0;
  int activeDownloads = 0;

  final List<Map<String, dynamic>> _currentDownloads = [];
  final List<Map<String, dynamic>> _downloads = []; // Cache of all downloads
  final StreamController<Map<String, dynamic>> _serviceEvents =
      StreamController.broadcast();

  Database? _db;
  DownloadLog? _logger;
  DownloadIsolateManager? _isolateManager;

  // Notifications and background service
  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();
  bool _notificationsInitialized = false;
  static const int _notificationIdStart = 6969;
  static const String _channelId = 'saturn_downloads';
  static const String _channelName = 'Downloads';
  final Map<int, DateTime> _lastNotificationUpdate = {};

  DownloadBackgroundService? _backgroundService;
  bool _backgroundServiceRunning = false;

  int get maxThreads => settings.downloadThreads;

  Stream<Map<String, dynamic>> get serviceEvents => _serviceEvents.stream;

  /// Initialize the download service
  Future<void> init(Database db) async {
    _db = db;
    _logger = DownloadLog();
    await _logger!.open();

    _logger!.log('[DownloadService] init() called');
    _logger!.log('[DownloadService] Platform: ${Platform.operatingSystem}');
    _logger!.log('[DownloadService] Database path: ${db.path}');

    // Initialize notifications FIRST - required before starting foreground service
    // The notification channel must exist before startForeground is called on Android 8.0+
    await _initNotifications();

    // Initialize background service (mobile only) - but don't start it yet
    // It will be started when downloads begin and stopped when complete
    if (Platform.isAndroid || Platform.isIOS) {
      _backgroundService = DownloadBackgroundService();
      try {
        await _backgroundService!.initialize();
        _logger!.log(
          'Background service initialized (not started - will start when downloads begin)',
        );
      } catch (e) {
        _logger!.log('Failed to initialize background service: $e');
      }
    }

    // Initialize isolate manager
    _logger!.log('[DownloadService] Initializing isolate manager...');
    _isolateManager = DownloadIsolateManager();
    await _isolateManager!.start(
      settings.arl ?? '',
      _db!.path,
      settings.toJson(),
    );
    _logger!.log('[DownloadService] Isolate manager started');

    // Listen for isolate responses
    _isolateManager!.responses.listen(_handleIsolateResponse);
    _logger!.log('[DownloadService] Listening for isolate responses');

    // Request initial downloads list
    _isolateManager!.sendMessage(CoordinatorMessage(type: 'getDownloads'));
    _logger!.log('[DownloadService] Requested initial downloads list');

    _logger!.log('[DownloadService] Download service fully initialized');
  }

  /// Initialize notifications
  Future<void> _initNotifications() async {
    try {
      const androidSettings = AndroidInitializationSettings(
        '@mipmap/ic_launcher',
      );
      const iosSettings = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: false,
        requestSoundPermission: false,
      );
      const macosSettings = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: false,
        requestSoundPermission: false,
      );
      const linuxSettings = LinuxInitializationSettings(
        defaultActionName: 'Open',
      );
      const windowsSettings = WindowsInitializationSettings(
        appName: 'Saturn',
        appUserModelId: 's.s.saturn.SaturnApp',
        guid: '8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a',
      );

      final initSettings = InitializationSettings(
        android: androidSettings,
        iOS: iosSettings,
        macOS: macosSettings,
        linux: linuxSettings,
        windows: windowsSettings,
      );

      final initialized = await _notificationsPlugin.initialize(initSettings);

      if (initialized == false) {
        _logger?.log('Notification initialization returned false');
      }

      if (Platform.isAndroid) {
        const androidChannel = AndroidNotificationChannel(
          _channelId,
          _channelName,
          description: 'Download progress notifications',
          importance: Importance.low,
          enableVibration: false,
          playSound: false,
        );

        await _notificationsPlugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >()
            ?.createNotificationChannel(androidChannel);
      }

      if (Platform.isIOS) {
        await _notificationsPlugin
            .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin
            >()
            ?.requestPermissions(alert: true, badge: false, sound: false);
      }

      if (Platform.isMacOS) {
        await _notificationsPlugin
            .resolvePlatformSpecificImplementation<
              MacOSFlutterLocalNotificationsPlugin
            >()
            ?.requestPermissions(alert: true, badge: false, sound: false);
      }

      _notificationsInitialized = true;
      _logger?.log('Notifications initialized for ${Platform.operatingSystem}');
    } catch (e, stackTrace) {
      _logger?.log('Failed to initialize notifications: $e');
      _logger?.log('Stack trace: $stackTrace');
      _notificationsInitialized = false;
    }
  }

  /// Handle responses from the isolate
  void _handleIsolateResponse(IsolateResponse response) {
    _logger?.log(
      '[DownloadService] Received isolate response: ${response.type}',
    );

    switch (response.type) {
      case 'stateChange':
        running = response.data!['running'] as bool;
        queueSize = response.data!['queueSize'] as int;
        activeDownloads = response.data!['activeDownloads'] as int;
        _logger?.log(
          '[DownloadService] State change - running: $running, queueSize: $queueSize, activeDownloads: $activeDownloads',
        );

        // Start background service when downloads are active
        if ((queueSize > 0 || activeDownloads > 0) &&
            !_backgroundServiceRunning) {
          _startBackgroundService();
        }
        // Stop background service when all downloads are finished
        else if (queueSize == 0 &&
            activeDownloads == 0 &&
            _backgroundServiceRunning) {
          _stopBackgroundService();
        }

        _serviceEvents.add({
          'type': 'stateChange',
          'running': running,
          'queueSize': queueSize,
        });
        break;

      case 'progress':
        final downloads = response.data!['downloads'] as List;
        _currentDownloads.clear();
        _currentDownloads.addAll(downloads.cast<Map<String, dynamic>>());

        // Update the downloads cache with progress data
        for (var progressDownload in downloads) {
          final id = progressDownload['id'];
          final index = _downloads.indexWhere((d) => d['id'] == id);
          if (index != -1) {
            _downloads[index] = progressDownload;
          }
        }

        // Update notifications for active downloads
        if (_notificationsInitialized) {
          for (var download in downloads) {
            _updateNotification(download);
          }
        }

        _serviceEvents.add({'type': 'progress', 'data': downloads});
        break;

      case 'downloadsAdded':
        final count = response.data!['count'] as int;
        _logger?.log('[DownloadService] Downloads added event - count: $count');

        // Request updated downloads list
        _isolateManager?.sendMessage(CoordinatorMessage(type: 'getDownloads'));

        _serviceEvents.add({'type': 'downloadsAdded', 'count': count});
        break;

      case 'downloadsList':
        final downloads = response.data!['downloads'] as List;
        _logger?.log(
          '[DownloadService] Downloads list received - count: ${downloads.length}',
        );
        _downloads.clear();
        _downloads.addAll(downloads.cast<Map<String, dynamic>>());
        _serviceEvents.add({'type': 'downloadsList', 'downloads': downloads});
        break;

      case 'downloadComplete':
        final id = response.data!['id'] as int;
        final trackId = response.data!['trackId'] as String;
        _logger?.log(
          '[DownloadService] Download complete - id: $id, trackId: $trackId',
        );

        // Update downloads cache
        final index = _downloads.indexWhere((d) => d['id'] == id);
        if (index != -1) {
          _downloads[index]['state'] = DownloadStateDart.DONE.index;

          // Show completion notification
          if (_notificationsInitialized) {
            _showCompletionNotification(_downloads[index]);
          }
        }

        _serviceEvents.add({
          'type': 'downloadComplete',
          'id': id,
          'trackId': trackId,
        });
        break;

      case 'downloadError':
        final id = response.data!['id'] as int;
        final trackId = response.data!['trackId'] as String;
        final state = response.data!['state'] as int;
        _logger?.error(
          '[DownloadService] Download error - id: $id, trackId: $trackId, state: $state',
        );

        // Update downloads cache
        final index = _downloads.indexWhere((d) => d['id'] == id);
        if (index != -1) {
          _downloads[index]['state'] = state;

          // Show error notification
          if (_notificationsInitialized) {
            _showErrorNotification(_downloads[index]);
          }
        }

        _serviceEvents.add({
          'type': 'downloadError',
          'id': id,
          'trackId': trackId,
          'state': state,
        });
        break;
    }
  }

  /// Start the background service (mobile only)
  Future<void> _startBackgroundService() async {
    if (_backgroundService == null || _backgroundServiceRunning) return;

    try {
      final started = await _backgroundService!.startService();
      _backgroundServiceRunning = started;
      _logger?.log('[DownloadService] Background service started: $started');
    } catch (e) {
      _logger?.log('[DownloadService] Failed to start background service: $e');
    }
  }

  /// Stop the background service (mobile only)
  Future<void> _stopBackgroundService() async {
    if (_backgroundService == null || !_backgroundServiceRunning) return;

    try {
      await _backgroundService!.stopService();
      _backgroundServiceRunning = false;
      _logger?.log('[DownloadService] Background service stopped');
    } catch (e) {
      _logger?.log('[DownloadService] Failed to stop background service: $e');
    }
  }

  /// Start/Resume downloads
  Future<void> start() async {
    _logger?.log(
      '[DownloadService] start() called - current running state: $running',
    );
    running = true; // Update immediately for UI responsiveness
    _isolateManager?.sendMessage(CoordinatorMessage(type: 'start'));
    _logger?.log('[DownloadService] start() - Message sent to isolate');
  }

  /// Stop/Pause downloads
  Future<void> stop() async {
    _logger?.log('[DownloadService] stop() called');
    running = false; // Update immediately for UI responsiveness
    _isolateManager?.sendMessage(CoordinatorMessage(type: 'stop'));
    _logger?.log('[DownloadService] stop() - Message sent to isolate');
  }

  /// Get all downloads
  List<Map<String, dynamic>> getDownloads() {
    return _downloads;
  }

  /// Add downloads to queue
  Future<void> addDownloads(List<Map<dynamic, dynamic>> downloads) async {
    _logger?.log(
      '[DownloadService] addDownloads called with ${downloads.length} downloads',
    );

    if (_db == null) {
      _logger?.error(
        '[DownloadService] addDownloads - ERROR: Database is null!',
      );
      return;
    }

    // Log each download being added
    for (int i = 0; i < downloads.length; i++) {
      final d = downloads[i];
      _logger?.log(
        '[DownloadService] addDownloads[$i] - trackId: ${d['trackId']}, title: ${d['title']}, path: ${d['path']}',
      );
      _logger?.log(
        '[DownloadService] addDownloads[$i] - md5origin: ${d['md5origin']}, quality: ${d['quality']}',
      );
    }

    _isolateManager?.sendMessage(
      CoordinatorMessage(type: 'addDownloads', data: {'downloads': downloads}),
    );
    _logger?.log(
      '[DownloadService] addDownloads - Message sent to isolate coordinator',
    );
  }

  /// Remove download
  Future<void> removeDownload(int id) async {
    _isolateManager?.sendMessage(
      CoordinatorMessage(type: 'removeDownload', data: {'id': id}),
    );

    // Wait a bit for the operation to complete, then request updated list
    await Future.delayed(const Duration(milliseconds: 100));
    _isolateManager?.sendMessage(CoordinatorMessage(type: 'getDownloads'));
  }

  /// Retry failed downloads
  Future<void> retryDownloads() async {
    _isolateManager?.sendMessage(CoordinatorMessage(type: 'retryDownloads'));

    // Wait a bit for the operation to complete, then request updated list
    await Future.delayed(const Duration(milliseconds: 100));
    _isolateManager?.sendMessage(CoordinatorMessage(type: 'getDownloads'));
  }

  /// Remove downloads by state
  Future<void> removeDownloads(DownloadStateDart state) async {
    _isolateManager?.sendMessage(
      CoordinatorMessage(type: 'removeByState', data: {'state': state.index}),
    );

    // Wait a bit for the operation to complete, then request updated list
    await Future.delayed(const Duration(milliseconds: 100));
    _isolateManager?.sendMessage(CoordinatorMessage(type: 'getDownloads'));
  }

  /// Update settings
  Future<void> updateSettings(Map<String, dynamic> settingsJson) async {
    _isolateManager?.sendMessage(
      CoordinatorMessage(type: 'updateSettings', data: settingsJson),
    );
  }

  /// Update notification for a download
  void _updateNotification(Map<String, dynamic> download) {
    if (!_notificationsInitialized) return;

    final id = download['id'] as int;
    final state = download['state'] as int;
    final notificationId = _notificationIdStart + id;

    // Only show progress notifications on mobile
    if (!(Platform.isAndroid || Platform.isIOS)) return;

    // Only update downloading state
    if (state != DownloadStateDart.DOWNLOADING.index) return;

    // Don't show notification if filesize not determined yet
    final filesize = download['filesize'] as int;
    if (filesize == 0) return;

    // Throttle updates - 500ms
    final now = DateTime.now();
    final lastUpdate = _lastNotificationUpdate[id];
    if (lastUpdate != null && now.difference(lastUpdate).inMilliseconds < 500) {
      return;
    }
    _lastNotificationUpdate[id] = now;

    final title = download['title'] as String;
    final received = download['received'] as int;

    if (Platform.isAndroid) {
      _notificationsPlugin.show(
        notificationId,
        title,
        '${_formatFilesize(received)} / ${_formatFilesize(filesize)}',
        NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: 'Download progress notifications',
            importance: Importance.low,
            priority: Priority.low,
            showProgress: true,
            maxProgress: filesize > 0 ? filesize : 100,
            progress: received,
            ongoing: true,
            onlyAlertOnce: true,
            enableVibration: false,
            playSound: false,
            autoCancel: false,
          ),
        ),
      );
    } else if (Platform.isIOS) {
      _notificationsPlugin.show(
        notificationId,
        title,
        '${_formatFilesize(received)} / ${_formatFilesize(filesize)}',
        const NotificationDetails(
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: false,
            presentSound: false,
          ),
        ),
      );
    }
  }

  /// Show completion notification
  Future<void> _showCompletionNotification(
    Map<String, dynamic> download,
  ) async {
    if (!_notificationsInitialized) return;

    final id = download['id'] as int;
    final title = download['title'] as String;
    final notificationId = _notificationIdStart + id;

    _lastNotificationUpdate.remove(id);

    if (Platform.isAndroid) {
      await _notificationsPlugin.show(
        notificationId,
        'Download Complete',
        title,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: 'Download completion notifications',
            importance: Importance.low,
            priority: Priority.low,
            enableVibration: false,
            playSound: false,
            autoCancel: true,
          ),
        ),
      );
    } else if (Platform.isIOS) {
      await _notificationsPlugin.show(
        notificationId,
        'Download Complete',
        title,
        const NotificationDetails(
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: false,
            presentSound: false,
          ),
        ),
      );
    } else if (Platform.isMacOS) {
      await _notificationsPlugin.show(
        notificationId,
        'Download Complete',
        title,
        const NotificationDetails(
          macOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: false,
            presentSound: false,
          ),
        ),
      );
    } else if (Platform.isLinux) {
      await _notificationsPlugin.show(
        notificationId,
        'Download Complete',
        title,
        const NotificationDetails(
          linux: LinuxNotificationDetails(
            urgency: LinuxNotificationUrgency.low,
          ),
        ),
      );
    } else if (Platform.isWindows) {
      await _notificationsPlugin.show(
        notificationId,
        'Download Complete',
        title,
        null,
      );
    }
  }

  /// Show error notification
  Future<void> _showErrorNotification(Map<String, dynamic> download) async {
    if (!_notificationsInitialized) return;

    final id = download['id'] as int;
    final title = download['title'] as String;
    final state = download['state'] as int;
    final notificationId = _notificationIdStart + id;

    _lastNotificationUpdate.remove(id);

    // Determine error message based on state
    String errorMessage = 'Download failed';
    if (state == DownloadStateDart.DEEZER_ERROR.index) {
      errorMessage = 'Deezer error';
    }

    if (Platform.isAndroid) {
      await _notificationsPlugin.show(
        notificationId,
        errorMessage,
        title,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: 'Download error notifications',
            importance: Importance.low,
            priority: Priority.low,
            enableVibration: false,
            playSound: false,
            autoCancel: true,
          ),
        ),
      );
    } else if (Platform.isIOS) {
      await _notificationsPlugin.show(
        notificationId,
        errorMessage,
        title,
        const NotificationDetails(
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: false,
            presentSound: false,
          ),
        ),
      );
    } else if (Platform.isMacOS) {
      await _notificationsPlugin.show(
        notificationId,
        errorMessage,
        title,
        const NotificationDetails(
          macOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: false,
            presentSound: false,
          ),
        ),
      );
    } else if (Platform.isLinux) {
      await _notificationsPlugin.show(
        notificationId,
        errorMessage,
        title,
        const NotificationDetails(
          linux: LinuxNotificationDetails(
            urgency: LinuxNotificationUrgency.normal,
          ),
        ),
      );
    } else if (Platform.isWindows) {
      await _notificationsPlugin.show(
        notificationId,
        errorMessage,
        title,
        null,
      );
    }
  }

  String _formatFilesize(int size) {
    if (size <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    int digitGroups = (size.toString().length - 1) ~/ 3;
    if (digitGroups >= units.length) digitGroups = units.length - 1;
    if (digitGroups == 0) return '$size B';
    double value = size / (1 << (10 * digitGroups));
    return '${value.toStringAsFixed(2)} ${units[digitGroups]}';
  }

  Future<void> dispose() async {
    await stop();

    // Stop background service if running
    if (_backgroundServiceRunning) {
      await _stopBackgroundService();
    }
    await _backgroundService?.dispose();

    // Cancel all notifications
    if (_notificationsInitialized) {
      await _notificationsPlugin.cancelAll();
    }

    await _isolateManager?.stop();
    await _logger?.close();
    await _serviceEvents.close();
  }
}
