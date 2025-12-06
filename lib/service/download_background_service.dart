import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

/// Background service wrapper for downloads
/// Only used on mobile platforms (iOS/Android)
@pragma('vm:entry-point')
class DownloadBackgroundService {
  static final DownloadBackgroundService _instance =
      DownloadBackgroundService._internal();
  factory DownloadBackgroundService() => _instance;
  DownloadBackgroundService._internal();

  final FlutterBackgroundService _service = FlutterBackgroundService();
  bool _isInitialized = false;
  bool _isRunning = false;

  // Batching for platform channel communication
  final List<Map<String, dynamic>> _messageQueue = [];
  Timer? _batchTimer;
  static const Duration _batchInterval = Duration(milliseconds: 500);
  static const int _maxBatchSize = 20;

  // Callbacks for progress updates
  final StreamController<Map<String, dynamic>> _eventsController =
      StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get events => _eventsController.stream;

  /// Check if background service should be used (mobile only)
  static bool get shouldUseBackgroundService {
    return Platform.isAndroid || Platform.isIOS;
  }

  /// Initialize background service (mobile only)
  Future<void> initialize() async {
    if (!shouldUseBackgroundService) {
      debugPrint('Background service not available on this platform');
      return;
    }

    if (_isInitialized) return;

    try {
      // Create notification channel BEFORE configuring service
      // This is critical - the channel must exist before startForeground is called
      if (Platform.isAndroid) {
        final FlutterLocalNotificationsPlugin notificationsPlugin =
            FlutterLocalNotificationsPlugin();

        const channel = AndroidNotificationChannel(
          'saturn_downloads',
          'Downloads',
          description: 'Download progress notifications',
          importance: Importance.low,
        );

        await notificationsPlugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >()
            ?.createNotificationChannel(channel);
      }

      await _service.configure(
        iosConfiguration: IosConfiguration(
          autoStart: false,
          onForeground: onStart,
          onBackground: onIosBackground,
        ),
        androidConfiguration: AndroidConfiguration(
          onStart: onStart,
          isForegroundMode: true,
          autoStart: false,
          autoStartOnBoot: false,
          notificationChannelId: 'saturn_downloads',
          initialNotificationTitle: 'Saturn Downloads',
          initialNotificationContent: 'Download service is running',
          foregroundServiceNotificationId: 888,
          foregroundServiceTypes: [AndroidForegroundType.dataSync],
        ),
      );

      // Listen to service events
      _service.on('update').listen((event) {
        if (event != null) {
          _eventsController.add(Map<String, dynamic>.from(event));
        }
      });

      _isInitialized = true;
      debugPrint('Background service initialized');
    } catch (e) {
      debugPrint('Failed to initialize background service: $e');
    }
  }

  /// Start the background service
  Future<bool> startService() async {
    if (!shouldUseBackgroundService || !_isInitialized) return false;

    try {
      // On Android 13+ (API 33+), notification permission must be granted
      // before starting a foreground service, otherwise it will crash
      if (Platform.isAndroid) {
        final status = await Permission.notification.status;
        if (!status.isGranted) {
          debugPrint(
            'Notification permission not granted, cannot start foreground service',
          );
          // Try to request permission
          final result = await Permission.notification.request();
          if (!result.isGranted) {
            debugPrint(
              'User denied notification permission, skipping foreground service',
            );
            return false;
          }
        }
      }

      final isRunning = await _service.isRunning();
      if (isRunning) {
        _isRunning = true;
        return true;
      }

      final started = await _service.startService();
      _isRunning = started;
      return started;
    } catch (e) {
      debugPrint('Failed to start background service: $e');
      return false;
    }
  }

  /// Stop the background service
  Future<void> stopService() async {
    if (!shouldUseBackgroundService) return;

    try {
      _batchTimer?.cancel();
      _batchTimer = null;

      final isRunning = await _service.isRunning();
      if (isRunning) {
        _service.invoke('stop');
      }
      _isRunning = false;
    } catch (e) {
      debugPrint('Failed to stop background service: $e');
    }
  }

  /// Send message to background service with batching
  void sendMessage(String type, Map<String, dynamic> data) {
    if (!shouldUseBackgroundService || !_isRunning) return;

    _messageQueue.add({'type': type, 'data': data});

    // Send immediately if batch is full
    if (_messageQueue.length >= _maxBatchSize) {
      _flushMessageQueue();
    } else {
      // Schedule batch send
      _batchTimer?.cancel();
      _batchTimer = Timer(_batchInterval, _flushMessageQueue);
    }
  }

  /// Flush queued messages to background service
  void _flushMessageQueue() {
    if (_messageQueue.isEmpty) return;

    try {
      _service.invoke('batch', {
        'messages': List<Map<String, dynamic>>.from(_messageQueue),
      });
      _messageQueue.clear();
    } catch (e) {
      debugPrint('Failed to send batch messages: $e');
    }

    _batchTimer?.cancel();
    _batchTimer = null;
  }

  /// Check if service is running
  Future<bool> isServiceRunning() async {
    if (!shouldUseBackgroundService) return false;

    try {
      return await _service.isRunning();
    } catch (e) {
      return false;
    }
  }

  /// Dispose resources
  Future<void> dispose() async {
    _batchTimer?.cancel();
    await stopService();
    await _eventsController.close();
  }

  /// Service entry point (Android)
  @pragma('vm:entry-point')
  static void onStart(ServiceInstance service) async {
    DartPluginRegistrant.ensureInitialized();

    // Create notification channel for Android
    if (Platform.isAndroid) {
      final FlutterLocalNotificationsPlugin notificationsPlugin =
          FlutterLocalNotificationsPlugin();

      const channel = AndroidNotificationChannel(
        'saturn_downloads',
        'Downloads',
        description: 'Download progress notifications',
        importance: Importance.low,
      );

      final androidPlugin = notificationsPlugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();

      await androidPlugin?.createNotificationChannel(channel);
    }

    // Handle stop command
    service.on('stop').listen((event) {
      service.stopSelf();
    });

    // Handle batch messages
    service.on('batch').listen((event) {
      if (event == null) return;

      try {
        final messages = event['messages'] as List;
        for (var message in messages) {
          final type = message['type'] as String;
          final data = message['data'] as Map<String, dynamic>?;

          // Process message
          _handleMessage(service, type, data);
        }
      } catch (e) {
        debugPrint('Error processing batch messages: $e');
      }
    });

    // The service runs until explicitly stopped
    // Download isolate handles all download logic and sends updates via batch messages
  }

  /// Background handler for iOS
  @pragma('vm:entry-point')
  static Future<bool> onIosBackground(ServiceInstance service) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    return true;
  }

  /// Handle individual messages in the background service
  static void _handleMessage(
    ServiceInstance service,
    String type,
    Map<String, dynamic>? data,
  ) {
    // Forward message to download coordinator
    // The actual download logic remains in the isolate
    service.invoke('update', data ?? {});
  }
}
