import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:metatagger/metatagger.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../api/deezer.dart';
import '../api/download_isolate.dart';
import '../api/download_log.dart';
import '../api/definitions.dart';
import '../settings.dart';

class DownloadServiceDart {
  static final DownloadServiceDart _instance = DownloadServiceDart._internal();
  factory DownloadServiceDart() => _instance;
  DownloadServiceDart._internal();

  bool running = false;
  int queueSize = 0;

  final List<DownloadTask> _downloads = [];
  final List<DownloadThread> _threads = [];
  final StreamController<Map<String, dynamic>> _serviceEvents =
      StreamController.broadcast();

  Database? _db;
  DownloadLog? _logger;
  DeezerAPI? _deezer;
  final List<DownloadIsolateManager> _isolates = [];
  Timer? _progressUpdateTimer;

  // Notification support
  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();
  bool _notificationsInitialized = false;
  static const int _notificationIdStart = 6969;
  static const String _channelId = 'saturn_downloads';
  static const String _channelName = 'Downloads';

  int get maxThreads => settings.downloadThreads;

  Stream<Map<String, dynamic>> get serviceEvents => _serviceEvents.stream;

  /// Initialize the download service
  Future<void> init(Database db) async {
    _db = db;
    _logger = DownloadLog();
    await _logger!.open();

    _deezer = DeezerAPI(arl: settings.arl);
    await _deezer!.authorize();

    // Initialize isolates for parallel downloads
    for (int i = 0; i < maxThreads; i++) {
      final isolate = DownloadIsolateManager();
      await isolate.start();
      _isolates.add(isolate);
    }

    // Initialize notifications
    await _initNotifications();

    // Load existing downloads from database
    await _loadDownloads();

    _createProgressUpdateTimer();
  }

  /// Initialize notifications
  Future<void> _initNotifications() async {
    try {
      // Platform-specific initialization settings
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
        guid: '8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a', // Windows 10/11 GUID
      );

      // Initialize for all platforms
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

      // Create notification channel on Android
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

      // Request permissions on iOS/macOS
      if (Platform.isIOS || Platform.isMacOS) {
        await _notificationsPlugin
            .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin
            >()
            ?.requestPermissions(alert: true, badge: false, sound: false);

        await _notificationsPlugin
            .resolvePlatformSpecificImplementation<
              MacOSFlutterLocalNotificationsPlugin
            >()
            ?.requestPermissions(alert: true, badge: false, sound: false);
      }

      _notificationsInitialized = true;
      _logger?.log(
        'Notifications initialized successfully for ${Platform.operatingSystem}',
      );
    } catch (e, stackTrace) {
      _logger?.error('Failed to initialize notifications: $e');
      _logger?.error('Stack trace: $stackTrace');
      _notificationsInitialized = false;
    }
  }

  void _createProgressUpdateTimer() {
    _progressUpdateTimer?.cancel();
    _progressUpdateTimer = Timer.periodic(const Duration(milliseconds: 500), (
      timer,
    ) {
      if (running && _threads.isNotEmpty) {
        _updateProgress();
      }
    });
  }

  /// Start/Resume downloads
  Future<void> start() async {
    running = true;
    await _loadDownloads();
    _updateQueue();
    _updateState();
  }

  /// Stop/Pause downloads
  Future<void> stop() async {
    running = false;
    for (var thread in _threads) {
      thread.stop();
    }
    // Stop all isolates
    for (var isolate in _isolates) {
      await isolate.stop();
    }
    _isolates.clear();

    // Cancel all download notifications
    if (_notificationsInitialized) {
      for (var thread in _threads) {
        await _notificationsPlugin.cancel(
          _notificationIdStart + thread.download.id,
        );
      }
    }

    _updateState();
  }

  /// Load downloads from database
  Future<void> _loadDownloads() async {
    if (_db == null) return;

    final List<Map<String, dynamic>> results = await _db!.query('Downloads');

    for (var row in results) {
      final download = DownloadTask.fromSQL(row);

      // Check for duplicates
      bool exists = _downloads.any((d) => d.id == download.id);
      if (!exists) {
        _downloads.add(download);
      }
    }

    _updateState();
  }

  /// Get all downloads
  List<Map<String, dynamic>> getDownloads() {
    return _downloads.map((d) => d.toMap()).toList();
  }

  /// Add downloads to queue
  Future<void> addDownloads(List<Map<dynamic, dynamic>> downloads) async {
    if (_db == null) return;

    for (var downloadData in downloads) {
      // Check if exists
      final existing = await _db!.query(
        'Downloads',
        where: 'trackId = ? AND path = ?',
        whereArgs: [downloadData['trackId'], downloadData['path']],
      );

      if (existing.isNotEmpty) {
        // Update state to NONE if done or error
        final state = existing[0]['state'] as int;
        if (state >= 3) {
          await _db!.update(
            'Downloads',
            {'state': 0},
            where: 'id = ?',
            whereArgs: [existing[0]['id']],
          );
        }
        continue;
      }

      // Insert new download
      await _db!.insert('Downloads', {
        'path': downloadData['path'],
        'private': downloadData['private'] ? 1 : 0,
        'state': 0,
        'trackId': downloadData['trackId'],
        'md5origin': downloadData['md5origin'],
        'mediaVersion': downloadData['mediaVersion'],
        'title': downloadData['title'],
        'image': downloadData['image'],
        'quality': downloadData['quality'],
        'trackToken': downloadData['trackToken'],
        'streamTrackId': downloadData['streamTrackId'],
      });
    }

    await _loadDownloads();

    // Emit event to notify UI that downloads were added
    _serviceEvents.add({
      'action': 'onDownloadsAdded',
      'count': downloads.length,
    });
  }

  /// Remove download
  Future<void> removeDownload(int id) async {
    if (_db == null) return;

    _downloads.removeWhere((d) => d.id == id);
    await _db!.delete('Downloads', where: 'id = ?', whereArgs: [id]);
    _updateState();
  }

  /// Retry failed downloads
  Future<void> retryDownloads() async {
    if (_db == null) return;

    for (var download in _downloads) {
      if (download.state == DownloadStateDart.DEEZER_ERROR ||
          download.state == DownloadStateDart.ERROR) {
        download.state = DownloadStateDart.NONE;
        await _db!.update(
          'Downloads',
          {'state': 0},
          where: 'id = ?',
          whereArgs: [download.id],
        );
      }
    }
    _updateState();
  }

  /// Remove downloads by state
  Future<void> removeDownloads(DownloadStateDart state) async {
    if (_db == null) return;
    if (state == DownloadStateDart.DOWNLOADING ||
        state == DownloadStateDart.POST) {
      return;
    }

    _downloads.removeWhere((d) => d.state == state);
    await _db!.delete(
      'Downloads',
      where: 'state = ?',
      whereArgs: [state.index],
    );
    _updateState();
  }

  /// Wrapper to prevent threads racing
  bool _updating = false;
  final List<bool> _updateRequests = [];

  Future<void> _updateQueueWrapper() async {
    _updateRequests.add(true);
    if (_updating) return;
    _updating = true;

    while (_updateRequests.isNotEmpty) {
      _updateRequests.clear();
      await _updateQueue();
    }

    _updating = false;
  }

  /// Update queue and start new downloads
  Future<void> _updateQueue() async {
    await _db?.execute('BEGIN TRANSACTION');

    try {
      // Clear downloaded tracks (iterate backwards)
      for (int i = _threads.length - 1; i >= 0; i--) {
        final thread = _threads[i];
        final state = thread.download.state;

        if (state == DownloadStateDart.NONE ||
            state == DownloadStateDart.DONE ||
            state == DownloadStateDart.ERROR ||
            state == DownloadStateDart.DEEZER_ERROR) {
          final d = thread.download;

          // Update in queue
          final index = _downloads.indexWhere((dl) => dl.id == d.id);
          if (index != -1) {
            _downloads[index] = d;
          }

          _updateProgress();

          // Save to DB
          await _db?.update(
            'Downloads',
            {'state': state.index, 'quality': d.quality},
            where: 'id = ?',
            whereArgs: [d.id],
          );

          // Log completion/error
          if (state == DownloadStateDart.DONE) {
            _logger?.log('Download completed: ${d.title}');

            // Show completion notification
            await _showCompletionNotification(d);

            _serviceEvents.add({
              'action': 'onDownloadComplete',
              'id': d.id,
              'trackId': d.trackId,
            });
          } else if (state == DownloadStateDart.ERROR ||
              state == DownloadStateDart.DEEZER_ERROR) {
            _logger?.error(
              'Download failed with state: $state',
              DownloadInfo(trackId: d.trackId, id: d.id),
            );
            _serviceEvents.add({
              'action': 'onDownloadError',
              'id': d.id,
              'trackId': d.trackId,
              'state': state.index,
            });
          }

          // Remove thread
          _threads.removeAt(i);
        }
      }

      await _db?.execute('COMMIT');
    } catch (e) {
      await _db?.execute('ROLLBACK');
      _logger?.error('Error in updateQueue: $e');
    }

    // Start new downloads
    if (running) {
      // Ensure we have enough isolates
      if (_isolates.length < maxThreads) {
        await _adjustIsolateCount();
      }

      final availableSlots = maxThreads - _threads.length;

      for (var i = 0; i < availableSlots; i++) {
        final download = _downloads.firstWhere(
          (d) => d.state == DownloadStateDart.NONE,
          orElse: () => DownloadTask(
            id: -1,
            path: '',
            private: false,
            quality: 0,
            state: DownloadStateDart.NONE,
            trackId: '',
            md5origin: '',
            mediaVersion: '',
            title: '',
            image: '',
            trackToken: '',
            streamTrackId: '',
          ),
        );

        if (download.id == -1) break;

        // Safety check: ensure we have isolates
        if (_isolates.isEmpty) {
          _logger?.error('No isolates available for download');
          break;
        }

        download.state = DownloadStateDart.DOWNLOADING;
        // Get an available isolate (round-robin)
        final isolate = _isolates[_threads.length % _isolates.length];
        final thread = DownloadThread(download, _deezer!, _logger!, isolate);
        thread.start(() => _onThreadComplete(thread));
        _threads.add(thread);
      }

      if (_threads.isEmpty) {
        running = false;
      }
    }

    _updateProgress();
    _updateState();
  }

  Future<void> _onThreadComplete(DownloadThread thread) async {
    await _updateQueueWrapper();
  }

  void _updateState() {
    queueSize = _downloads
        .where((d) => d.state == DownloadStateDart.NONE)
        .length;

    _serviceEvents.add({
      'action': 'onStateChange',
      'running': running,
      'queueSize': queueSize,
    });
  }

  /// Send progress update event
  void _updateProgress() {
    if (_threads.isEmpty) return;

    final downloads = _threads
        .map(
          (thread) => {
            'id': thread.download.id,
            'received': thread.download.received,
            'filesize': thread.download.filesize,
            'quality': thread.download.quality,
            'state': thread.download.state.index,
          },
        )
        .toList();

    _serviceEvents.add({'action': 'onProgress', 'data': downloads});

    // Update notifications
    if (_notificationsInitialized) {
      for (var thread in _threads) {
        _updateNotification(thread.download);
      }
    }
  }

  /// Update or cancel notification for a download
  Future<void> _updateNotification(DownloadTask download) async {
    if (!_notificationsInitialized) return;

    final notificationId = _notificationIdStart + download.id;

    // Cancel notification for done/none/error downloads
    if (download.state == DownloadStateDart.NONE || download.state.index >= 3) {
      await _notificationsPlugin.cancel(notificationId);
      return;
    }

    // On desktop (Windows/Linux/macOS), only show completion notification
    // to avoid notification spam since we can't update in-place reliably
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      // Don't show progress notifications on desktop
      return;
    }

    // Mobile (Android/iOS) - show progress notifications
    if (Platform.isAndroid) {
      await _showAndroidNotification(download, notificationId);
    } else if (Platform.isIOS) {
      await _showIOSNotification(download, notificationId);
    }
  }

  /// Show Android notification with progress
  Future<void> _showAndroidNotification(
    DownloadTask download,
    int notificationId,
  ) async {
    final androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: 'Download progress notifications',
      importance: Importance.low,
      priority: Priority.low,
      showProgress: download.state == DownloadStateDart.DOWNLOADING,
      maxProgress: download.filesize > 0 ? download.filesize : 100,
      progress: download.received,
      indeterminate: download.state == DownloadStateDart.POST,
      ongoing: true,
      autoCancel: false,
      enableVibration: false,
      playSound: false,
    );

    final notificationDetails = NotificationDetails(android: androidDetails);

    String contentText;
    if (download.state == DownloadStateDart.DOWNLOADING) {
      contentText =
          '${_formatFilesize(download.received)} / ${_formatFilesize(download.filesize)}';
    } else if (download.state == DownloadStateDart.POST) {
      contentText = 'Post processing...';
    } else {
      contentText = 'Downloading...';
    }

    await _notificationsPlugin.show(
      notificationId,
      download.title,
      contentText,
      notificationDetails,
    );
  }

  /// Show iOS notification (simplified, no progress bar)
  Future<void> _showIOSNotification(
    DownloadTask download,
    int notificationId,
  ) async {
    final iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: false,
      presentSound: false,
    );

    final notificationDetails = NotificationDetails(iOS: iosDetails);

    String contentText;
    if (download.state == DownloadStateDart.DOWNLOADING) {
      contentText =
          '${_formatFilesize(download.received)} / ${_formatFilesize(download.filesize)}';
    } else if (download.state == DownloadStateDart.POST) {
      contentText = 'Post processing...';
    } else {
      contentText = 'Downloading...';
    }

    await _notificationsPlugin.show(
      notificationId,
      download.title,
      contentText,
      notificationDetails,
    );
  }

  /// Show completion notification (for all platforms)
  Future<void> _showCompletionNotification(DownloadTask download) async {
    if (!_notificationsInitialized) return;

    const notificationId = 9999; // Use a fixed ID for completion notifications

    try {
      if (Platform.isAndroid) {
        const androidDetails = AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: 'Download completion notifications',
          importance: Importance.low,
          priority: Priority.low,
          enableVibration: false,
          playSound: false,
          autoCancel: true,
        );
        const notificationDetails = NotificationDetails(
          android: androidDetails,
        );

        await _notificationsPlugin.show(
          notificationId,
          'Download Complete',
          download.title,
          notificationDetails,
        );
      } else if (Platform.isIOS) {
        const iosDetails = DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: false,
          presentSound: false,
        );
        const notificationDetails = NotificationDetails(iOS: iosDetails);

        await _notificationsPlugin.show(
          notificationId,
          'Download Complete',
          download.title,
          notificationDetails,
        );
      } else if (Platform.isMacOS) {
        const macDetails = DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: false,
          presentSound: false,
        );
        const notificationDetails = NotificationDetails(macOS: macDetails);

        await _notificationsPlugin.show(
          notificationId,
          'Download Complete',
          download.title,
          notificationDetails,
        );
      } else if (Platform.isLinux) {
        const linuxDetails = LinuxNotificationDetails(
          urgency: LinuxNotificationUrgency.low,
        );
        const notificationDetails = NotificationDetails(linux: linuxDetails);

        await _notificationsPlugin.show(
          notificationId,
          'Download Complete',
          download.title,
          notificationDetails,
        );
      } else if (Platform.isWindows) {
        // Windows notification
        await _notificationsPlugin.show(
          notificationId,
          'Download Complete',
          download.title,
          null, // Windows will use default notification details
        );
      }

      _logger?.log('Completion notification shown for: ${download.title}');
    } catch (e, stackTrace) {
      _logger?.error('Failed to show completion notification: $e');
      _logger?.error('Stack trace: $stackTrace');
    }
  }

  /// Format file size for display
  String _formatFilesize(int size) {
    if (size <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    int digitGroups = (size.toString().length - 1) ~/ 3;
    if (digitGroups >= units.length) digitGroups = units.length - 1;
    double value = size / (1024 * digitGroups);
    return '${value.toStringAsFixed(2)} ${units[digitGroups]}';
  }

  /// Update settings
  Future<void> updateSettings(Map<String, dynamic> settingsJson) async {
    // Note: downloadThreads is now read directly from settings.downloadThreads
    // If thread count changed, we need to adjust isolates
    if (settingsJson.containsKey('downloadThreads')) {
      await _adjustIsolateCount();
    }
    if (settingsJson.containsKey('arl')) {
      _deezer?.arl = settingsJson['arl'];
    }
  }

  /// Adjust isolate count to match settings
  Future<void> _adjustIsolateCount() async {
    final targetCount = maxThreads;
    final currentCount = _isolates.length;

    if (targetCount > currentCount) {
      // Add more isolates
      for (int i = currentCount; i < targetCount; i++) {
        final isolate = DownloadIsolateManager();
        await isolate.start();
        _isolates.add(isolate);
      }
    } else if (targetCount < currentCount) {
      // Remove excess isolates
      for (int i = currentCount - 1; i >= targetCount; i--) {
        await _isolates[i].stop();
        _isolates.removeAt(i);
      }
    }
  }

  Future<void> dispose() async {
    await stop();
    _progressUpdateTimer?.cancel();

    // Cancel all notifications
    if (_notificationsInitialized) {
      await _notificationsPlugin.cancelAll();
    }

    await _logger?.close();
    await _serviceEvents.close();
  }
}

/// Download task model
class DownloadTask {
  int id;
  String path;
  bool private;
  int quality;
  String trackId;
  String streamTrackId;
  String trackToken;
  String md5origin;
  String mediaVersion;
  DownloadStateDart state;
  String title;
  String image;

  // Dynamic
  int received = 0;
  int filesize = 0;

  DownloadTask({
    required this.id,
    required this.path,
    required this.private,
    required this.quality,
    required this.state,
    required this.trackId,
    required this.md5origin,
    required this.mediaVersion,
    required this.title,
    required this.image,
    required this.trackToken,
    required this.streamTrackId,
  });

  factory DownloadTask.fromSQL(Map<String, dynamic> row) {
    return DownloadTask(
      id: row['id'],
      path: row['path'],
      private: row['private'] == 1,
      quality: row['quality'],
      state: DownloadStateDart.values[row['state']],
      trackId: row['trackId'],
      md5origin: row['md5origin'],
      mediaVersion: row['mediaVersion'],
      title: row['title'],
      image: row['image'],
      trackToken: row['trackToken'],
      streamTrackId: row['streamTrackId'],
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'path': path,
      'private': private,
      'quality': quality,
      'trackId': trackId,
      'state': state.index,
      'title': title,
      'image': image,
    };
  }

  bool get isUserUploaded => trackId.startsWith('-');
}

/// Download thread
class DownloadThread {
  final DownloadTask download;
  final DeezerAPI deezer;
  final DownloadLog logger;
  final DownloadIsolateManager isolate;
  final tagger = MetaTagger();

  bool _stopDownload = false;

  DownloadThread(this.download, this.deezer, this.logger, this.isolate);

  void stop() {
    _stopDownload = true;
  }

  Future<void> start(Function onComplete) async {
    download.state = DownloadStateDart.DOWNLOADING;

    try {
      await _downloadTrack();
    } catch (e) {
      logger.error(
        'Download error: $e',
        DownloadInfo(trackId: download.trackId, id: download.id),
      );
      download.state = DownloadStateDart.ERROR;
    } finally {
      onComplete();
    }
  }

  Future<void> _downloadTrack() async {
    // Fetch track and album metadata
    Track? track;
    Album? album;
    if (!download.private) {
      try {
        track = await deezer.track(download.trackId);
        if (track.album?.id != null) {
          album = await deezer.album(track.album!.id!);
        }
      } catch (e) {
        logger.error(
          'Unable to fetch track and album metadata! $e',
          DownloadInfo(trackId: download.trackId, id: download.id),
        );
        download.state = DownloadStateDart.ERROR;
        return;
      }
    }

    // Get track URL
    final url = await _getTrackUrl(
      download.streamTrackId,
      download.trackToken,
      download.md5origin,
      download.mediaVersion,
      download.quality,
    );
    if (url == null) {
      download.state = DownloadStateDart.DEEZER_ERROR;
      return;
    }

    // Generate proper filename with metadata
    File outFile;
    if (!download.private && track != null) {
      try {
        final generatedPath = _generateFilename(
          download.path,
          track,
          album,
          download.quality,
        );
        outFile = File(generatedPath);
      } catch (e) {
        logger.error(
          'Error generating track filename: $e',
          DownloadInfo(trackId: download.trackId, id: download.id),
        );
        download.state = DownloadStateDart.ERROR;
        return;
      }
    } else {
      outFile = File(download.path);
    }

    // Check if file exists and overwrite setting
    if (await outFile.exists()) {
      if (settings.overwriteDownload) {
        await outFile.delete();
      } else {
        download.state = DownloadStateDart.DONE;
        return;
      }
    }

    // Get cache directory for temp file
    Directory? directory;
    if (Platform.isAndroid || Platform.isIOS) {
      directory = await getExternalStorageDirectory();
    } else {
      directory = await getApplicationSupportDirectory();
    }

    if (directory == null) {
      download.state = DownloadStateDart.ERROR;
      return;
    }

    final tmpFile = File(p.join(directory.path, 'cache', '${download.id}.ENC'));
    await tmpFile.parent.create(recursive: true);

    // Download file
    final success = await _downloadFile(url, tmpFile);
    if (!success) return;

    // Set state to POST processing
    download.state = DownloadStateDart.POST;

    // Decrypt if needed
    File finalFile = tmpFile;
    if (url.contains('dzcdn.net')) {
      final decFile = File('${tmpFile.path}.DEC');
      await _decryptFile(tmpFile, decFile);
      await tmpFile.delete();
      finalFile = decFile;
    }

    // Create output directory
    await outFile.parent.create(recursive: true);

    // Move to final location using isolate
    final response = await isolate.moveFile(
      finalFile.path,
      outFile.path,
      deleteSource: true,
    );

    if (!response.success) {
      logger.error(
        'File move error: ${response.error}',
        DownloadInfo(trackId: download.trackId, id: download.id),
      );
      download.state = DownloadStateDart.ERROR;
      return;
    }

    // Cover & Tags for non-private downloads
    if (!download.private && track != null) {
      // Always download cover art for tagging purposes
      final coverPath =
          outFile.path.substring(0, outFile.path.lastIndexOf('.')) + '.jpg';
      final coverFile = File(coverPath);
      await _downloadCoverArt(outFile, track);

      // Download album cover if enabled
      if (settings.albumCover) {
        await _downloadAlbumCover(outFile, track, album);
      }

      // Download LRC lyrics if enabled
      if (settings.downloadLyrics) {
        await _downloadLrcLyrics(outFile, track);
      }

      // Tag file with metadata
      await _tagFile(outFile, track);

      // Delete track cover if trackCover setting is disabled
      if (!settings.trackCover && await coverFile.exists()) {
        await coverFile.delete();
        logger.log('Deleted track cover (trackCover setting disabled)');
      }
    }

    download.state = DownloadStateDart.DONE;
  }

  /// Get track URL - tries modern API first, falls back to legacy
  Future<String?> _getTrackUrl(
    String trackId,
    String trackToken,
    String md5origin,
    String mediaVersion,
    int quality,
  ) async {
    try {
      // Try modern API with license token first
      if (deezer.licenseToken != null &&
          deezer.licenseToken!.isNotEmpty == true) {
        final url = await _getTrackUrlFromAPI(trackId, trackToken, quality);
        if (url != null && url.isNotEmpty) {
          return url;
        }
      }
      return null;
    } catch (e) {
      logger.log('Error getting track URL: $e');
      return null;
    }
  }

  /// Get track URL from Deezer API (modern method)
  Future<String?> _getTrackUrlFromAPI(
    String trackId,
    String trackToken,
    int quality,
  ) async {
    try {
      String format = 'FLAC';
      if (quality == 3) format = 'MP3_320';
      if (quality == 1) format = 'MP3_128';
      if (trackId.startsWith('-')) format = 'MP3_MISC';

      final payload = {
        'license_token': deezer.licenseToken,
        'media': [
          {
            'type': 'FULL',
            'formats': [
              {'cipher': 'BF_CBC_STRIPE', 'format': format},
            ],
          },
        ],
        'track_tokens': [trackToken],
      };

      // Make POST request to Deezer media API
      final headers = {
        'Content-Type': 'application/json',
        'Cookie': 'arl=${deezer.arl}',
      };

      final response = await http.post(
        Uri.parse('https://media.deezer.com/v1/get_url'),
        headers: headers,
        body: jsonEncode(payload),
      );

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body);
        if (body['data'] != null) {
          final data = body['data'] as List;
          for (var item in data) {
            if (item['media'] != null && (item['media'] as List).isNotEmpty) {
              final media = item['media'][0];
              if (media['sources'] != null &&
                  (media['sources'] as List).isNotEmpty) {
                final url = media['sources'][0]['url'];
                logger.log('Got track URL from API: $url');
                return url;
              }
            }
          }
        }
      } else {
        logger.log(
          'API returned status ${response.statusCode}: ${response.body}',
        );
      }
    } catch (e) {
      logger.log('Error getting track URL from API: $e');
    }
    return null;
  }

  Future<bool> _downloadFile(String url, File outputFile) async {
    try {
      // Check if download was stopped before starting
      if (_stopDownload) {
        download.state = DownloadStateDart.NONE;
        return false;
      }

      // Use isolate for file download
      final response = await isolate.downloadFile(
        url,
        outputFile.path,
        onProgress: (received, total) {
          if (_stopDownload) return;
          download.filesize = total;
          download.received = received;
        },
      );

      // Check if download was stopped during download
      if (_stopDownload) {
        download.state = DownloadStateDart.NONE;
        return false;
      }

      if (!response.success) {
        logger.error(
          'Download error: ${response.error}',
          DownloadInfo(trackId: download.trackId, id: download.id),
        );
        return false;
      }

      return true;
    } catch (e) {
      logger.error(
        'Download error: $e',
        DownloadInfo(trackId: download.trackId, id: download.id),
      );
      return false;
    }
  }

  Future<void> _decryptFile(File inputFile, File outputFile) async {
    try {
      // Use isolate for file decryption
      final response = await isolate.decryptFile(
        download.streamTrackId,
        inputFile.path,
        outputFile.path,
      );

      if (!response.success) {
        logger.error(
          'Decryption error: ${response.error}',
          DownloadInfo(trackId: download.trackId, id: download.id),
        );
      }
    } catch (e) {
      logger.error(
        'Decryption error: $e',
        DownloadInfo(trackId: download.trackId, id: download.id),
      );
    }
  }

  /// Generate filename with metadata placeholders
  String _generateFilename(
    String original,
    Track track,
    Album? album,
    int quality,
  ) {
    String result = original;

    // Basic replacements
    result = result.replaceAll('%title%', _sanitize(track.title ?? ''));
    result = result.replaceAll('%album%', _sanitize(track.album?.title ?? ''));
    result = result.replaceAll(
      '%artist%',
      _sanitize(track.artists?.first.name ?? ''),
    );

    // Album artist
    if (album != null && album.artists != null && album.artists!.isNotEmpty) {
      result = result.replaceAll(
        '%albumArtist%',
        _sanitize(album.artists!.first.name ?? ''),
      );
    } else {
      result = result.replaceAll(
        '%albumArtist%',
        _sanitize(track.artists?.first.name ?? ''),
      );
    }

    // Artists
    if (track.artists != null && track.artists!.isNotEmpty) {
      final artists = track.artists!.map((a) => a.name).join(', ');
      result = result.replaceAll('%artists%', _sanitize(artists));

      // Feats (all artists except first)
      if (track.artists!.length > 1) {
        final feats = track.artists!.skip(1).map((a) => a.name).join(', ');
        result = result.replaceAll('%feats%', _sanitize(feats));
      } else {
        result = result.replaceAll('%feats%', '');
      }
    }

    // Track number
    final trackNumber = track.trackNumber ?? 1;
    result = result.replaceAll('%trackNumber%', trackNumber.toString());
    result = result.replaceAll(
      '%0trackNumber%',
      trackNumber.toString().padLeft(2, '0'),
    );

    // Year and date
    if (track.album?.releaseDate != null) {
      result = result.replaceAll(
        '%year%',
        track.album!.releaseDate!.substring(0, 4),
      );
      result = result.replaceAll('%date%', track.album!.releaseDate!);
    }

    // Remove leading dots
    result = result.replaceAll(RegExp(r'/\.+'), '/');

    // Add extension
    if (quality == 9) {
      return '$result.flac';
    }
    return '$result.mp3';
  }

  String _sanitize(String input) {
    return input
        .replaceAll(RegExp(r'[\\/?*:%<>|"]'), '')
        .replaceAll('\$', '\\\$');
  }

  Future<void> _downloadCoverArt(File audioFile, Track track) async {
    try {
      // Generate cover filename
      final coverPath =
          audioFile.path.substring(0, audioFile.path.lastIndexOf('.')) + '.jpg';
      final coverFile = File(coverPath);

      // Get image hash (MD5) for cover image
      String? imageHash;
      if (track.albumArt?.imageHash != null) {
        imageHash = track.albumArt!.imageHash;
      } else if (track.album?.art?.imageHash != null) {
        imageHash = track.album!.art!.imageHash;
      }

      if (imageHash == null) {
        // Fallback: try to get from public API
        try {
          Map<dynamic, dynamic> publicTrack = await deezer.callPublicApi(
            '/track/${download.trackId}',
          );
          if (publicTrack['album'] != null &&
              publicTrack['album']['md5_image'] != null) {
            imageHash = publicTrack['album']['md5_image'];
          }
        } catch (e) {
          logger.log('Could not fetch image hash from public API: $e');
        }
      }

      if (imageHash == null) {
        logger.log('No album art hash found for track');
        return;
      }

      // Use settings for album art resolution
      final resolution = settings.albumArtResolution;
      final coverUrl =
          'http://e-cdn-images.deezer.com/images/cover/$imageHash/${resolution}x$resolution-000000-80-0-0.jpg';

      // Download cover
      final response = await http.get(Uri.parse(coverUrl));
      if (response.statusCode == 200) {
        await coverFile.writeAsBytes(response.bodyBytes);
        logger.log('Downloaded track cover art: ${coverFile.path}');
      }
    } catch (e) {
      logger.error(
        'Error downloading cover! $e',
        DownloadInfo(trackId: download.trackId, id: download.id),
      );
    }
  }

  /// Download album cover (cover.jpg in album folder)
  Future<void> _downloadAlbumCover(
    File audioFile,
    Track track,
    Album? album,
  ) async {
    try {
      // Check if path contains %album% placeholder (has album folder)
      if (!download.path.contains('%album%')) {
        return;
      }

      final parentDir = audioFile.parent;
      final coverFile = File(p.join(parentDir.path, 'cover.jpg'));

      // Don't download if already exists
      if (await coverFile.exists()) {
        return;
      }

      // Get image hash (MD5) for cover image
      String? imageHash;
      if (album?.art?.imageHash != null) {
        imageHash = album!.art!.imageHash;
      } else if (track.album?.art?.imageHash != null) {
        imageHash = track.album!.art!.imageHash;
      } else if (track.albumArt?.imageHash != null) {
        imageHash = track.albumArt!.imageHash;
      }

      if (imageHash == null) {
        // Fallback: try to get from public API
        try {
          Map<dynamic, dynamic> publicAlbum = await deezer.callPublicApi(
            '/album/${track.album?.id}',
          );
          if (publicAlbum['md5_image'] != null) {
            imageHash = publicAlbum['md5_image'];
          }
        } catch (e) {
          logger.log('Could not fetch image hash from public API: $e');
        }
      }

      if (imageHash == null) {
        logger.log('No album art hash found for album cover');
        return;
      }

      // Use settings for album art resolution
      final resolution = settings.albumArtResolution;
      final coverUrl =
          'http://e-cdn-images.deezer.com/images/cover/$imageHash/${resolution}x$resolution-000000-80-0-0.jpg';

      // Create file to lock it
      await coverFile.create(recursive: true);

      // Download cover
      final response = await http.get(Uri.parse(coverUrl));
      if (response.statusCode == 200) {
        await coverFile.writeAsBytes(response.bodyBytes);
        logger.log('Downloaded album cover: ${coverFile.path}');

        // Create .nomedia file if enabled
        if (settings.nomediaFiles) {
          final nomediaFile = File(p.join(parentDir.path, '.nomedia'));
          if (!await nomediaFile.exists()) {
            await nomediaFile.create();
            logger.log('Created .nomedia file in ${parentDir.path}');
          }
        }
      } else {
        // Delete failed file
        await coverFile.delete();
      }
    } catch (e) {
      logger.error(
        'Error downloading album cover! $e',
        DownloadInfo(trackId: download.trackId, id: download.id),
      );
      // Clean up on error
      try {
        final parentDir = audioFile.parent;
        final coverFile = File(p.join(parentDir.path, 'cover.jpg'));
        if (await coverFile.exists()) {
          await coverFile.delete();
        }
      } catch (_) {}
    }
  }

  /// Download LRC lyrics file
  Future<void> _downloadLrcLyrics(File audioFile, Track track) async {
    try {
      // Fetch lyrics if not already loaded
      Lyrics? lyrics = track.lyrics;
      if (lyrics == null || !lyrics.isLoaded()) {
        try {
          logger.log('Fetching lyrics for track ${download.trackId}');
          lyrics = await deezer.lyrics(download.trackId);
        } catch (e) {
          logger.log('Failed to fetch lyrics: $e');
          return;
        }
      }

      // Check if track has synced lyrics
      if (lyrics.syncedLyrics == null || lyrics.syncedLyrics!.isEmpty) {
        logger.log(
          'No synced lyrics available for track, skipping lyrics file',
        );
        return;
      }

      // Generate LRC filename
      final lrcPath =
          audioFile.path.substring(0, audioFile.path.lastIndexOf('.')) + '.lrc';
      final lrcFile = File(lrcPath);

      // Generate LRC content
      final lrcData = _generateLRC(track, lyrics);

      // Write to file
      await lrcFile.writeAsString(lrcData);

      logger.log('Downloaded LRC lyrics: ${lrcFile.path}');
    } catch (e) {
      logger.error(
        'Error downloading lyrics! $e',
        DownloadInfo(trackId: download.trackId, id: download.id),
      );
    }
  }

  /// Generate LRC format from lyrics data
  String _generateLRC(Track track, Lyrics lyrics) {
    final output = StringBuffer();

    // Write metadata
    if (track.artists != null && track.artists!.isNotEmpty) {
      final artists = track.artists!.map((a) => a.name).join(', ');
      output.write('[ar:$artists]\r\n');
    }

    if (track.album?.title != null) {
      output.write('[al:${track.album!.title}]\r\n');
    }

    if (track.title != null) {
      output.write('[ti:${track.title}]\r\n');
    }

    // Write synced lyrics
    if (lyrics.syncedLyrics != null) {
      for (var lyric in lyrics.syncedLyrics!) {
        if (lyric.lrcTimestamp != null && lyric.text != null) {
          // lrcTimestamp already contains brackets, don't add more
          output.write('${lyric.lrcTimestamp}${lyric.text}\r\n');
        }
      }
    }

    return output.toString();
  }

  /// Tag file with metadata
  Future<void> _tagFile(File audioFile, Track track) async {
    try {
      List<MetadataTag> tags = [];
      Map<dynamic, dynamic> publicAlbum = await deezer.callPublicApi(
        '/album/${track.album?.id}',
      );
      Map<dynamic, dynamic> publicTrack = await deezer.callPublicApi(
        '/track/${download.trackId}',
      );

      // Title
      if (settings.tags.contains('title') && track.title != null) {
        tags.add(MetadataTag.text(CommonTags.title, track.title!));
      }
      // Album
      if (settings.tags.contains('album') && track.album!.title != null) {
        tags.add(MetadataTag.text(CommonTags.album, track.album!.title!));
      }

      // Artists
      if (settings.tags.contains('artist') &&
          track.artists != null &&
          track.artists!.isNotEmpty) {
        tags.add(
          MetadataTag.text(
            CommonTags.artist,
            track.artists!.map((a) => a.name).join(settings.artistSeparator),
          ),
        );
      }

      // Album artist
      if (settings.tags.contains('albumArtist') &&
          track.album != null &&
          track.album!.artists != null &&
          track.album!.artists!.isNotEmpty) {
        tags.add(
          MetadataTag.text(
            CommonTags.albumArtist,
            track.album!.artists!.first.name!,
          ),
        );
      }

      // Track number
      if (settings.tags.contains('track')) {
        tags.add(
          MetadataTag.text(CommonTags.track, track.trackNumber.toString()),
        );
      }

      // Disc number
      if (settings.tags.contains('disc')) {
        tags.add(
          MetadataTag.text(CommonTags.disc, track.diskNumber.toString()),
        );
      }

      // Track total
      if (settings.tags.contains('trackTotal') &&
          publicAlbum['nb_tracks'] != null) {
        tags.add(
          MetadataTag.text(
            CommonTags.trackTotal,
            publicAlbum['nb_tracks'].toString(),
          ),
        );
      }

      // Date
      if (settings.tags.contains('date') && track.album?.releaseDate != null) {
        tags.add(MetadataTag.text(CommonTags.date, track.album!.releaseDate!));
      }

      // Genre
      if (settings.tags.contains('genre')) {
        String? genreName;

        // Try to get genre from genres array
        if (publicAlbum['genres'] != null &&
            publicAlbum['genres']['data'] != null &&
            (publicAlbum['genres']['data'] as List).isNotEmpty) {
          genreName = publicAlbum['genres']['data'][0]['name'];
        }

        if (genreName != null) {
          tags.add(MetadataTag.text(CommonTags.genre, genreName));
        }
      }

      // BPM
      if (settings.tags.contains('bpm') && publicTrack['bpm'] != null) {
        tags.add(
          MetadataTag.text(CommonTags.bpm, publicTrack['bpm'].toString()),
        );
      }

      // Label
      if (settings.tags.contains('label') && publicAlbum['label'] != null) {
        tags.add(MetadataTag.text(CommonTags.label, publicAlbum['label']));
      }

      // ISRC
      if (settings.tags.contains('isrc') && publicTrack['isrc'] != null) {
        tags.add(MetadataTag.text(CommonTags.isrc, publicTrack['isrc']));
      }

      // UPC
      if (settings.tags.contains('upc') && publicAlbum['upc'] != null) {
        tags.add(MetadataTag.text(CommonTags.barcode, publicAlbum['upc']));
      }

      // Lyrics
      if (settings.tags.contains('lyrics') &&
          track.lyrics != null &&
          track.lyrics!.unsyncedLyrics != null) {
        tags.add(
          MetadataTag.text(CommonTags.lyrics, track.lyrics!.unsyncedLyrics!),
        );
      }

      // Cover art
      if (settings.tags.contains('art')) {
        final coverPath =
            '${audioFile.path.substring(0, audioFile.path.lastIndexOf('.'))}.jpg';
        final coverFile = await File(coverPath).readAsBytes();
        tags.add(MetadataTag.binary(CommonTags.albumArt, coverFile));
      }

      // Write metadata
      await tagger.writeTags(audioFile.path, tags);

      logger.log('Tagged file: ${audioFile.path}');
    } catch (e, stackTrace) {
      logger.error(
        'Tagging error! $e',
        DownloadInfo(trackId: download.trackId, id: download.id),
      );
      logger.error(stackTrace.toString());
    }
  }
}

enum DownloadStateDart { NONE, DOWNLOADING, POST, DONE, DEEZER_ERROR, ERROR }
