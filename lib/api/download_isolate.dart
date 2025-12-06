import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:metatagger/metatagger.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path_provider/path_provider.dart';

import '../api/deezer.dart';
import '../api/definitions.dart';
import '../api/download_log.dart';
import '../api/deezer_decryptor.dart';
import '../settings.dart' as settings_module;

/// Messages from main isolate to coordinator
class CoordinatorMessage {
  final String type;
  final Map<String, dynamic>? data;

  CoordinatorMessage({required this.type, this.data});

  Map<String, dynamic> toJson() => {'type': type, 'data': data};
  factory CoordinatorMessage.fromJson(Map<String, dynamic> json) =>
      CoordinatorMessage(type: json['type'], data: json['data']);
}

/// Messages from coordinator/workers back to main
class IsolateResponse {
  final String type;
  final Map<String, dynamic>? data;

  IsolateResponse({required this.type, this.data});

  Map<String, dynamic> toJson() => {'type': type, 'data': data};
  factory IsolateResponse.fromJson(Map<String, dynamic> json) =>
      IsolateResponse(type: json['type'], data: json['data']);
}

/// Download state enum
enum DownloadStateDart { NONE, DOWNLOADING, POST, DONE, DEEZER_ERROR, ERROR }

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
  int downloaded = 0; // Bytes already downloaded (for resume)

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
    )..downloaded = row['downloaded'] ?? 0;
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
      'received': received,
      'filesize': filesize,
    };
  }

  Map<String, dynamic> toSQL() {
    return {
      'id': id,
      'path': path,
      'private': private ? 1 : 0,
      'quality': quality,
      'trackId': trackId,
      'state': state.index,
      'title': title,
      'image': image,
      'md5origin': md5origin,
      'mediaVersion': mediaVersion,
      'trackToken': trackToken,
      'streamTrackId': streamTrackId,
      'downloaded': downloaded,
    };
  }

  bool get isUserUploaded => trackId.startsWith('-');
}

/// Manager for download isolate coordinator
class DownloadIsolateManager {
  Isolate? _isolate;
  SendPort? _isolateSendPort;
  final ReceivePort _receivePort = ReceivePort();
  final Completer<void> _readyCompleter = Completer<void>();
  final StreamController<IsolateResponse> _responseController =
      StreamController.broadcast();

  bool get isReady => _readyCompleter.isCompleted;
  Stream<IsolateResponse> get responses => _responseController.stream;

  /// Start the coordinator isolate
  Future<void> start(
    String arl,
    String dbPath,
    Map<String, dynamic> settings,
  ) async {
    if (_isolate != null) return;

    _isolate = await Isolate.spawn(_coordinatorEntryPoint, {
      'sendPort': _receivePort.sendPort,
      'arl': arl,
      'dbPath': dbPath,
      'rootIsolateToken': RootIsolateToken.instance!,
      'settings': settings,
    });

    _receivePort.listen((msg) {
      if (_isolateSendPort == null && msg is SendPort) {
        _isolateSendPort = msg;
        _readyCompleter.complete();
        return;
      }
      if (msg is Map<String, dynamic>) {
        final response = IsolateResponse.fromJson(msg);
        _responseController.add(response);
      }
    });

    await _readyCompleter.future;
  }

  /// Stop the isolate
  Future<void> stop() async {
    if (_isolate == null) return;
    sendMessage(CoordinatorMessage(type: 'shutdown'));
    await Future.delayed(const Duration(milliseconds: 100));
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _isolateSendPort = null;
    _receivePort.close();
    await _responseController.close();
  }

  /// Send a message to the coordinator
  void sendMessage(CoordinatorMessage message) {
    if (!isReady) return;
    _isolateSendPort?.send(message.toJson());
  }

  /// Coordinator entry point - manages queue and spawns workers
  static Future<void> _coordinatorEntryPoint(Map<String, dynamic> args) async {
    final mainSendPort = args['sendPort'] as SendPort;
    final arl = args['arl'] as String;
    final dbPath = args['dbPath'] as String;
    final rootIsolateToken = args['rootIsolateToken'] as RootIsolateToken;
    final settings = args['settings'] as Map<String, dynamic>;

    final receivePort = ReceivePort();
    mainSendPort.send(receivePort.sendPort);

    // Initialize coordinator state
    final coordinator = _DownloadCoordinator(
      mainSendPort: mainSendPort,
      arl: arl,
      dbPath: dbPath,
      rootIsolateToken: rootIsolateToken,
      settings: settings,
    );

    await coordinator.init();

    await for (var msg in receivePort) {
      if (msg is Map<String, dynamic>) {
        final message = CoordinatorMessage.fromJson(msg);
        await coordinator.handleMessage(message);

        // Only dispose and exit on explicit shutdown, not on pause/stop
        if (message.type == 'shutdown') {
          await coordinator.dispose();
          receivePort.close();
          return;
        }
      }
    }
  }
}

/// Internal coordinator class that runs in the isolate
class _DownloadCoordinator {
  final SendPort mainSendPort;
  final String arl;
  final String dbPath;
  final RootIsolateToken rootIsolateToken;
  Map<String, dynamic> settings;

  Database? _db;
  DeezerAPI? _deezer;
  DownloadLog? _logger;

  final List<DownloadTask> _queue = [];
  final Map<int, _WorkerHandle> _activeWorkers = {};
  bool _running = false;
  Timer? _progressTimer;

  _DownloadCoordinator({
    required this.mainSendPort,
    required this.arl,
    required this.dbPath,
    required this.rootIsolateToken,
    required this.settings,
  });

  Future<void> init() async {
    // Initialize BackgroundIsolateBinaryMessenger for Flutter plugins in isolate
    BackgroundIsolateBinaryMessenger.ensureInitialized(rootIsolateToken);

    // Initialize database factory for desktop platforms
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    _logger = DownloadLog();
    await _logger!.open();

    _deezer = DeezerAPI(arl: arl);
    await _deezer!.authorize();

    _db = await openDatabase(dbPath);

    await _loadQueue();

    _progressTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      _sendProgressUpdate();
    });

    _logger!.log('Download coordinator initialized');
  }

  Future<void> _updateNotification(DownloadTask task) async {
    // Notifications handled in main isolate
  }

  Future<void> dispose() async {
    _progressTimer?.cancel();

    await _logger?.close();
    await _db?.close();

    // Stop all active workers and clean up
    for (var worker in _activeWorkers.values) {
      worker.isolate.kill(priority: Isolate.immediate);
      worker.receivePort.close();
    }
    _activeWorkers.clear();
  }

  Future<void> handleMessage(CoordinatorMessage message) async {
    _logger?.log('[Coordinator] handleMessage received: ${message.type}');

    switch (message.type) {
      case 'start':
        _logger?.log(
          '[Coordinator] Starting downloads - current queue: ${_queue.length}, active workers: ${_activeWorkers.length}',
        );
        _running = true;
        await _loadQueue(); // Reload queue to get updated 'downloaded' values
        _logger?.log(
          '[Coordinator] Queue reloaded, ${_queue.where((d) => d.state == DownloadStateDart.NONE).length} downloads pending',
        );
        _sendDownloadsList(); // Send fresh list to UI
        await _updateQueue();
        _sendStateUpdate();
        break;

      case 'stop':
        _running = false;
        // Save partial download progress and reset state for resume
        for (var worker in _activeWorkers.values) {
          // Kill the isolate
          worker.isolate.kill(priority: Isolate.immediate);

          // Close the receive port to clean up
          worker.receivePort.close();

          // Reset download state to NONE so it can be resumed
          worker.download.state = DownloadStateDart.NONE;
          await _db!.update(
            'Downloads',
            {
              'state': DownloadStateDart.NONE.index,
              'downloaded': worker.download.received, // Save progress
            },
            where: 'id = ?',
            whereArgs: [worker.download.id],
          );
        }
        _activeWorkers.clear();

        // Reload queue to ensure consistency
        await _loadQueue();

        _sendStateUpdate();
        _sendDownloadsList();
        break;

      case 'addDownloads':
        await _addDownloads(message.data!['downloads'] as List);
        break;

      case 'removeDownload':
        await _removeDownload(message.data!['id'] as int);
        break;

      case 'retryDownloads':
        await _retryDownloads();
        break;

      case 'removeByState':
        await _removeByState(
          DownloadStateDart.values[message.data!['state'] as int],
        );
        break;

      case 'getDownloads':
        _sendDownloadsList();
        break;

      case 'updateSettings':
        settings = message.data!;
        break;
    }
  }

  Future<void> _loadQueue() async {
    if (_db == null) return;

    final results = await _db!.query('Downloads');
    _queue.clear();

    for (var row in results) {
      final task = DownloadTask.fromSQL(row);

      // Reset orphaned DOWNLOADING state to NONE
      // (downloads that were downloading when app was closed)
      if (task.state == DownloadStateDart.DOWNLOADING) {
        task.state = DownloadStateDart.NONE;
        // Update in database
        await _db!.update(
          'Downloads',
          {'state': DownloadStateDart.NONE.index},
          where: 'id = ?',
          whereArgs: [task.id],
        );
      }

      _queue.add(task);
    }

    _logger?.log('Loaded ${_queue.length} downloads from database');
  }

  Future<void> _addDownloads(List<dynamic> downloads) async {
    if (_db == null) {
      _logger?.error('[Coordinator] _addDownloads - ERROR: Database is null!');
      return;
    }

    _logger?.log(
      '[Coordinator] _addDownloads called with ${downloads.length} downloads',
    );

    int added = 0;
    for (var downloadData in downloads) {
      // Check if exists using trackId and path (not id, which is auto-generated)
      final trackId = downloadData['trackId'];
      final path = downloadData['path'];

      _logger?.log(
        '[Coordinator] _addDownloads - Processing trackId: $trackId',
      );
      _logger?.log('[Coordinator] _addDownloads - Path: $path');
      _logger?.log(
        '[Coordinator] _addDownloads - md5origin: ${downloadData['md5origin']}, mediaVersion: ${downloadData['mediaVersion']}',
      );

      if (trackId == null || path == null) {
        _logger?.warn(
          '[Coordinator] _addDownloads - Skipping invalid download: trackId=$trackId, path=$path',
        );
        continue; // Skip invalid downloads
      }

      final existing = await _db!.query(
        'Downloads',
        where: 'trackId = ? AND path = ?',
        whereArgs: [trackId, path],
      );

      if (existing.isEmpty) {
        _logger?.log(
          '[Coordinator] _addDownloads - Inserting new download for trackId: $trackId',
        );
        // Insert new download (id is auto-generated by database)
        await _db!.insert('Downloads', {
          'path': downloadData['path'],
          'private': downloadData['private'] == true ? 1 : 0,
          'state': 0,
          'trackId': downloadData['trackId'],
          'md5origin': downloadData['md5origin'],
          'mediaVersion': downloadData['mediaVersion'],
          'title': downloadData['title'],
          'image': downloadData['image'],
          'quality': downloadData['quality'],
          'trackToken': downloadData['trackToken'],
          'streamTrackId': downloadData['streamTrackId'],
          'downloaded': 0,
        });
        _logger?.log(
          '[Coordinator] _addDownloads - Insert successful for trackId: $trackId',
        );
        added++;
      } else {
        _logger?.log(
          '[Coordinator] _addDownloads - Download already exists for trackId: $trackId, state: ${existing[0]['state']}',
        );
        // Update state to NONE if done or error (allow re-download)
        final state = existing[0]['state'] as int;
        if (state >= 3) {
          _logger?.log(
            '[Coordinator] _addDownloads - Resetting state to NONE for re-download',
          );
          await _db!.update(
            'Downloads',
            {'state': 0},
            where: 'id = ?',
            whereArgs: [existing[0]['id']],
          );
          added++;
        }
      }
    }

    _logger?.log(
      '[Coordinator] _addDownloads - Added $added downloads, reloading queue',
    );
    await _loadQueue();
    _sendResponse(
      IsolateResponse(type: 'downloadsAdded', data: {'count': added}),
    );
    _sendStateUpdate();
    _sendDownloadsList();
    _logger?.log(
      '[Coordinator] _addDownloads - Complete, queue size: ${_queue.length}',
    );

    if (_running) {
      await _updateQueue();
    }
  }

  Future<void> _removeDownload(int id) async {
    if (_db == null) return;

    _queue.removeWhere((d) => d.id == id);
    await _db!.delete('Downloads', where: 'id = ?', whereArgs: [id]);
    await _loadQueue(); // Reload to ensure consistency

    _sendStateUpdate();
    _sendDownloadsList();
  }

  Future<void> _retryDownloads() async {
    for (var download in _queue) {
      if (download.state == DownloadStateDart.DEEZER_ERROR ||
          download.state == DownloadStateDart.ERROR) {
        download.state = DownloadStateDart.NONE;
        await _db!.update(
          'Downloads',
          {'state': download.state.index},
          where: 'id = ?',
          whereArgs: [download.id],
        );
      }
    }

    await _loadQueue(); // Reload to get fresh state
    _sendStateUpdate();
    _sendDownloadsList();

    if (_running) {
      await _updateQueue();
    }
  }

  Future<void> _removeByState(DownloadStateDart state) async {
    if (_db == null) return;
    if (state == DownloadStateDart.DOWNLOADING ||
        state == DownloadStateDart.POST) {
      return;
    }

    _queue.removeWhere((d) => d.state == state);
    await _db!.delete(
      'Downloads',
      where: 'state = ?',
      whereArgs: [state.index],
    );
    await _loadQueue(); // Reload to ensure consistency

    _sendStateUpdate();
    _sendDownloadsList();
  }

  Future<void> _updateQueue() async {
    // Remove completed workers
    final completedIds = <int>[];
    // Create a copy of entries to avoid concurrent modification
    final workerEntries = _activeWorkers.entries.toList();
    for (var entry in workerEntries) {
      final download = _queue.firstWhere(
        (d) => d.id == entry.key,
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

      if (download.state == DownloadStateDart.DONE ||
          download.state == DownloadStateDart.DEEZER_ERROR ||
          download.state == DownloadStateDart.ERROR) {
        // Kill isolate and close receive port
        entry.value.isolate.kill(priority: Isolate.immediate);
        entry.value.receivePort.close();
        completedIds.add(entry.key);

        // Update database
        await _db!.update(
          'Downloads',
          download.toSQL(),
          where: 'id = ?',
          whereArgs: [download.id],
        );
      }
    }

    for (var id in completedIds) {
      _activeWorkers.remove(id);
    }

    // Start new downloads
    if (_running && _activeWorkers.length < settings['downloadThreads']) {
      final availableSlots =
          settings['downloadThreads'] - _activeWorkers.length;

      for (var i = 0; i < availableSlots; i++) {
        final nextDownload = _queue.firstWhere(
          (d) =>
              d.state == DownloadStateDart.NONE &&
              !_activeWorkers.containsKey(d.id),
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

        if (nextDownload.id == -1) break;

        // Start worker
        await _startWorker(nextDownload);
      }
    }

    _sendStateUpdate();
    _sendDownloadsList(); // Send updated list after starting workers
  }

  Future<void> _startWorker(DownloadTask download) async {
    // Guard: Don't start a worker if one is already running for this download
    if (_activeWorkers.containsKey(download.id)) {
      _logger?.log(
        '[Coordinator] Worker already exists for download ${download.id}, skipping',
      );
      return;
    }

    _logger?.log(
      '[Coordinator] _startWorker - Starting worker for download ${download.id}: ${download.title}',
    );
    _logger?.log(
      '[Coordinator] _startWorker - trackId: ${download.trackId}, streamTrackId: ${download.streamTrackId}',
    );
    _logger?.log(
      '[Coordinator] _startWorker - md5origin: ${download.md5origin}, quality: ${download.quality}',
    );
    _logger?.log('[Coordinator] _startWorker - path: ${download.path}');

    download.state = DownloadStateDart.DOWNLOADING;

    // Update database with new state
    await _db!.update(
      'Downloads',
      {'state': download.state.index},
      where: 'id = ?',
      whereArgs: [download.id],
    );

    final workerReceivePort = ReceivePort();
    final isolate = await Isolate.spawn(_workerEntryPoint, {
      'sendPort': workerReceivePort.sendPort,
      'download': download.toSQL(),
      'arl': arl,
      'settings': settings,
      'rootIsolateToken': rootIsolateToken,
    });

    final worker = _WorkerHandle(
      isolate: isolate,
      receivePort: workerReceivePort,
      download: download,
    );

    _activeWorkers[download.id] = worker;

    // Listen for updates from worker
    workerReceivePort.listen((msg) {
      if (msg is Map<String, dynamic>) {
        _handleWorkerMessage(download.id, msg);
      }
    });

    _logger?.log(
      'Started worker for download ${download.id}: ${download.title}',
    );
  }

  void _handleWorkerMessage(int downloadId, Map<String, dynamic> msg) {
    final type = msg['type'] as String;

    switch (type) {
      case 'progress':
        final download = _queue.firstWhere((d) => d.id == downloadId);
        download.received = msg['received'] as int;
        download.filesize = msg['total'] as int;
        break;

      case 'stateChange':
        final download = _queue.firstWhere((d) => d.id == downloadId);
        final oldState = download.state;
        download.state = DownloadStateDart.values[msg['state'] as int];

        // Send completion/error events to UI
        if (download.state == DownloadStateDart.DONE &&
            oldState != DownloadStateDart.DONE) {
          _logger?.log('Download completed: ${download.title}');

          _sendResponse(
            IsolateResponse(
              type: 'downloadComplete',
              data: {
                'id': download.id,
                'trackId': download.trackId,
                'title': download.title,
              },
            ),
          );
        } else if ((download.state == DownloadStateDart.ERROR ||
                download.state == DownloadStateDart.DEEZER_ERROR) &&
            oldState != DownloadStateDart.ERROR &&
            oldState != DownloadStateDart.DEEZER_ERROR) {
          _logger?.error('Download failed: ${download.title}');

          // Update notification for error
          _updateNotification(download);

          _sendResponse(
            IsolateResponse(
              type: 'downloadError',
              data: {
                'id': download.id,
                'trackId': download.trackId,
                'state': download.state.index,
              },
            ),
          );
        }

        if (download.state == DownloadStateDart.DONE ||
            download.state == DownloadStateDart.DEEZER_ERROR ||
            download.state == DownloadStateDart.ERROR) {
          // Worker finished, update queue
          _updateQueue();
          // Send updated downloads list to UI
          _sendDownloadsList();
        }
        break;

      case 'log':
        _logger?.log(msg['message'] as String);
        break;

      case 'error':
        _logger?.error(msg['message'] as String);
        break;
    }
  }

  void _sendProgressUpdate() {
    if (_activeWorkers.isEmpty) return;

    final downloads = _activeWorkers.values
        .map((w) => w.download.toMap())
        .toList();

    _sendResponse(
      IsolateResponse(type: 'progress', data: {'downloads': downloads}),
    );

    // Update notifications for active downloads
    for (var worker in _activeWorkers.values) {
      _updateNotification(worker.download);
    }
  }

  void _sendStateUpdate() {
    final queueSize = _queue
        .where((d) => d.state == DownloadStateDart.NONE)
        .length;

    _sendResponse(
      IsolateResponse(
        type: 'stateChange',
        data: {
          'running': _running,
          'queueSize': queueSize,
          'activeDownloads': _activeWorkers.length,
        },
      ),
    );
  }

  void _sendDownloadsList() {
    _sendResponse(
      IsolateResponse(
        type: 'downloadsList',
        data: {'downloads': _queue.map((d) => d.toMap()).toList()},
      ),
    );
  }

  void _sendResponse(IsolateResponse response) {
    mainSendPort.send(response.toJson());
  }
}

/// Handle for active worker isolate
class _WorkerHandle {
  final Isolate isolate;
  final ReceivePort receivePort;
  final DownloadTask download;

  _WorkerHandle({
    required this.isolate,
    required this.receivePort,
    required this.download,
  });
}

/// Worker entry point - handles individual download
Future<void> _workerEntryPoint(Map<String, dynamic> args) async {
  final mainSendPort = args['sendPort'] as SendPort;
  final downloadData = args['download'] as Map<String, dynamic>;
  final arl = args['arl'] as String;
  final settingsData = args['settings'] as Map<String, dynamic>;
  final rootIsolateToken = args['rootIsolateToken'] as RootIsolateToken;

  // Initialize BackgroundIsolateBinaryMessenger for Flutter plugins in worker isolate
  BackgroundIsolateBinaryMessenger.ensureInitialized(rootIsolateToken);

  // Initialize a minimal settings stub for DeezerAPI
  // DeezerAPI accesses global settings.deezerLanguage and settings.deezerCountry
  // Use noSuchMethod to create a dynamic proxy that handles any property access
  settings_module.settings = _MinimalSettings(
    deezerLanguage: settingsData['deezerLanguage'] as String? ?? 'en',
    deezerCountry: settingsData['deezerCountry'] as String? ?? 'US',
  );

  final download = DownloadTask.fromSQL(downloadData);
  final worker = _DownloadWorker(
    sendPort: mainSendPort,
    download: download,
    arl: arl,
    settings: settingsData,
  );

  await worker.execute();
}

/// Minimal settings stub for worker isolate - mimics Settings class for DeezerAPI
@pragma('vm:entry-point')
class _MinimalSettings extends settings_module.Settings {
  @override
  // ignore: overridden_fields
  final String deezerLanguage;
  @override
  // ignore: overridden_fields
  final String deezerCountry;

  _MinimalSettings({required this.deezerLanguage, required this.deezerCountry})
    : super(arl: null, downloadPath: null);

  @override
  dynamic noSuchMethod(Invocation invocation) {
    // Return safe defaults for any undefined property
    return null;
  }
}

/// Worker that executes the download
class _DownloadWorker {
  final SendPort sendPort;
  final DownloadTask download;
  final String arl;
  final Map<String, dynamic> settings;

  DeezerAPI? _deezer;

  _DownloadWorker({
    required this.sendPort,
    required this.download,
    required this.arl,
    required this.settings,
  });

  void _log(String message) {
    sendPort.send({'type': 'log', 'message': message});
  }

  void _error(String message) {
    sendPort.send({'type': 'error', 'message': message});
  }

  String _safeSubstring(String str, int maxLength) {
    if (str.length <= maxLength) return str;
    return str.substring(0, maxLength);
  }

  void _updateState(DownloadStateDart state) {
    download.state = state;
    sendPort.send({'type': 'stateChange', 'state': state.index});
  }

  void _updateProgress(int received, int total) {
    sendPort.send({'type': 'progress', 'received': received, 'total': total});
  }

  Future<void> execute() async {
    try {
      _deezer = DeezerAPI(arl: arl);
      await _deezer!.authorize();

      _log('Starting download: ${download.title}');

      // Fetch track and album metadata
      Track? track;
      Album? album;
      Map<dynamic, dynamic>? publicTrack;
      Map<dynamic, dynamic>? publicAlbum;
      Lyrics? lyrics;

      if (!download.private) {
        try {
          _log('Fetching track metadata for ID: ${download.trackId}');

          try {
            track = await _deezer!.track(download.trackId);
          } catch (trackError) {
            _error(
              'Track API call failed for ID ${download.trackId}: $trackError',
            );
            _updateState(DownloadStateDart.DEEZER_ERROR);
            return;
          }

          if (track.album?.id == null) {
            _error('Track has no album ID: ${download.trackId}');
            _updateState(DownloadStateDart.DEEZER_ERROR);
            return;
          }

          _log('Fetching album metadata for ID: ${track.album!.id}');

          try {
            album = await _deezer!.album(track.album!.id!);
          } catch (albumError) {
            _error(
              'Album API call failed for ID ${track.album!.id}: $albumError',
            );
            _updateState(DownloadStateDart.DEEZER_ERROR);
            return;
          }

          _log('Fetching public track API for ID: ${download.trackId}');

          try {
            final trackData = await _deezer!.callPublicApi(
              'track/${download.trackId}',
            );

            publicTrack = trackData;
            _log('Public track data received: ${trackData.keys.join(", ")}');
          } catch (publicTrackError) {
            _error('Public track API call failed: $publicTrackError');
            _updateState(DownloadStateDart.DEEZER_ERROR);
            return;
          }

          _log('Fetching lyrics for ID: ${download.trackId}');

          try {
            final lyricsData = await _deezer!.lyrics(download.trackId);

            lyrics = lyricsData;
            _log('Lyrics data received: ${lyrics..toString()}');
          } catch (lyricsError) {
            _error('Lyrics API call failed: $lyricsError');
            _updateState(DownloadStateDart.DEEZER_ERROR);
            return;
          }

          _log('Fetching public album API for ID: ${track.album!.id}');

          try {
            final albumData = await _deezer!.callPublicApi(
              'album/${track.album!.id}',
            );

            publicAlbum = albumData;
            _log('Public album data received: ${albumData.keys.join(", ")}');
          } catch (publicAlbumError) {
            _error('Public album API call failed: $publicAlbumError');
            _updateState(DownloadStateDart.DEEZER_ERROR);
            return;
          }
        } catch (e, stackTrace) {
          _error('Failed to fetch metadata: $e');
          _error('Stack trace: ${_safeSubstring(stackTrace.toString(), 500)}');
          _updateState(DownloadStateDart.DEEZER_ERROR);
          return;
        }
      }

      // Get track URL
      _log('Fetching track URL for streamTrackId: ${download.streamTrackId}');
      final url = await _getTrackUrl(
        download.streamTrackId,
        download.trackToken,
        download.md5origin,
        download.mediaVersion,
        download.quality,
      );

      if (url == null) {
        _error(
          'Failed to get track URL for streamTrackId: ${download.streamTrackId}',
        );
        _updateState(DownloadStateDart.DEEZER_ERROR);
        return;
      }

      _log('Track URL obtained: ${_safeSubstring(url, 50)}...');

      // Generate proper filename
      File outFile;
      if (!download.private && track != null) {
        // download.path already contains the full path template from download.dart
        // Process the entire path to replace all placeholders
        final fullPath = _processPathTemplate(
          download.path,
          track,
          album,
          download.quality,
        );
        outFile = File(fullPath);
      } else {
        // Private downloads use the path as-is
        outFile = File(download.path);
      }

      // Check if file exists
      if (await outFile.exists()) {
        if (!(settings['overwriteFile'] as bool? ?? false)) {
          _log('File already exists, skipping: ${outFile.path}');
          _updateState(DownloadStateDart.DONE);
          return;
        }
      }

      // Get cache directory
      Directory? directory;
      if (Platform.isAndroid || Platform.isIOS) {
        directory = await getExternalStorageDirectory();
      } else {
        directory = await getApplicationSupportDirectory();
      }

      if (directory == null) {
        _error('Failed to get cache directory');
        _updateState(DownloadStateDart.ERROR);
        return;
      }

      final tmpFile = File(
        p.join(directory.path, 'cache', '${download.id}.mp3'),
      );
      await tmpFile.parent.create(recursive: true);

      // Download file with streaming decryption
      final success = await _downloadWithDecryption(url, tmpFile);
      if (!success) {
        _updateState(DownloadStateDart.ERROR);
        return;
      }

      // Post processing
      _updateState(DownloadStateDart.POST);

      // Create output directory
      await outFile.parent.create(recursive: true);

      // Move to final location
      await tmpFile.copy(outFile.path);
      await tmpFile.delete();

      _log('File saved to: ${outFile.path}');

      // Cover & Tags for non-private downloads
      if (!download.private && track != null) {
        try {
          // Download cover art bytes once and store in memory
          Uint8List? coverArtBytes;

          final resolution = settings['albumArtResolution'] as int;
          _log('Album art resolution setting: $resolution');

          // Get image hash from album (prioritize album art over track art)
          String? imageHash = track.albumArt?.imageHash;

          _log('Final image hash: $imageHash');

          if (imageHash != null && imageHash.isNotEmpty) {
            final coverUrl =
                'http://e-cdn-images.deezer.com/images/cover/$imageHash/${resolution}x$resolution-000000-80-0-0.jpg';
            _log('Attempting to download cover art from: $coverUrl');

            try {
              final response = await http.get(Uri.parse(coverUrl));
              _log('Cover art HTTP response: ${response.statusCode}');
              if (response.statusCode == 200) {
                coverArtBytes = response.bodyBytes;
                _log(
                  'Successfully downloaded cover art to memory (${coverArtBytes.length} bytes)',
                );
              } else {
                _error(
                  'Failed to download cover art: HTTP ${response.statusCode}',
                );
              }
            } catch (e) {
              _error('Error downloading cover art: $e');
            }
          } else {
            _log('No image hash available, skipping cover art download');
          }

          // Save track cover art as separate file if setting enabled
          final trackCoverEnabled = settings['trackCover'] as bool? ?? false;
          _log('Track cover setting enabled: $trackCoverEnabled');
          if (trackCoverEnabled) {
            if (coverArtBytes != null) {
              _log('Calling _saveCoverArt with ${coverArtBytes.length} bytes');
              await _saveCoverArt(outFile, coverArtBytes);
            } else {
              _log('Track cover enabled but coverArtBytes is null, skipping');
            }
          }

          // Save album cover if setting enabled
          final albumCoverEnabled = settings['albumCover'] as bool? ?? false;
          if (albumCoverEnabled) {
            await _downloadAlbumCover(outFile, album!);
          }

          // Tag file (pass cover art bytes for tagging)
          await _tagFile(
            outFile,
            track,
            publicAlbum!,
            publicTrack!,
            lyrics,
            coverArtBytes,
          );

          // Download LRC if enabled
          final lyricsEnabled = settings['downloadLyrics'] as bool? ?? false;
          _log('Download lyrics setting enabled: $lyricsEnabled');
          if (lyricsEnabled && lyrics?.isSynced() == true) {
            _log('Calling _downloadLrcLyrics');
            await _downloadLrcLyrics(outFile, track);
          }
        } catch (e) {
          _error('Post-processing error: $e');
        }
      }

      _updateState(DownloadStateDart.DONE);
      _log('Download completed: ${download.title}');
    } catch (e, stackTrace) {
      _error('Download failed: $e\n$stackTrace');
      _updateState(DownloadStateDart.ERROR);
    }
  }

  /// Download file with streaming decryption (like stream_server_dart.dart)
  Future<bool> _downloadWithDecryption(String url, File outputFile) async {
    try {
      // Check if partial file exists and get resume position
      int startByte = 0;

      if (await outputFile.exists()) {
        // Temp file exists, we can resume from where it left off
        startByte = await outputFile.length();
        _log('Resuming download from byte $startByte (temp file exists)');
      } else if (download.downloaded > 0) {
        // Temp file was deleted but we had progress
        // For encrypted content, we can't resume without the file, so start over
        if (url.contains('dzcdn.net')) {
          _log(
            'Temp file missing and content is encrypted, starting from beginning',
          );
          startByte = 0;
          download.downloaded = 0; // Reset the download counter
        } else {
          // For non-encrypted content, we could theoretically resume
          // but it's safer to start over
          _log('Temp file missing, starting from beginning');
          startByte = 0;
          download.downloaded = 0;
        }
      }

      if (startByte > 0) {
        _log('Resuming download from byte $startByte');
      }

      final client = HttpClient();
      final request = await client.getUrl(Uri.parse(url));

      // Add Range header for resume support
      if (startByte > 0) {
        request.headers.set('Range', 'bytes=$startByte-');
      }

      final response = await request.close();

      // Accept both 200 (full) and 206 (partial) responses
      if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.partialContent) {
        _error('HTTP ${response.statusCode} from server');
        return false;
      }

      // Calculate total file size correctly
      // For 206 Partial Content, contentLength is just the remaining bytes
      // For 200 OK, contentLength is the full file size
      int totalFileSize;
      if (response.statusCode == HttpStatus.partialContent) {
        // For partial response, total = start + remaining
        totalFileSize =
            startByte +
            (response.contentLength > 0 ? response.contentLength : 0);
      } else {
        // For full response, contentLength is already the total
        totalFileSize = response.contentLength > 0 ? response.contentLength : 0;
      }

      int received = startByte;
      final sink = outputFile.openWrite(
        mode: startByte > 0 ? FileMode.append : FileMode.write,
      );

      // Check if URL is from Deezer CDN (needs decryption)
      if (url.contains('dzcdn.net')) {
        final key = DeezerDecryptor.getKey(download.streamTrackId);
        // Calculate starting counter for resumed downloads
        int counter = startByte ~/ 2048;
        final inputBuffer = <int>[];

        await for (var chunk in response) {
          inputBuffer.addAll(chunk);

          // Process complete 2048-byte blocks
          while (inputBuffer.length >= 2048) {
            final buffer = inputBuffer.sublist(0, 2048);
            inputBuffer.removeRange(0, 2048);

            List<int> decrypted;
            if ((counter % 3) == 0) {
              decrypted = DeezerDecryptor.decryptChunk(key, buffer);
            } else {
              decrypted = buffer;
            }

            sink.add(decrypted);
            received += decrypted.length;
            _updateProgress(received, totalFileSize);
            counter++;
          }
        }

        // Write any remaining bytes
        if (inputBuffer.isNotEmpty) {
          sink.add(inputBuffer);
          received += inputBuffer.length;
          _updateProgress(received, totalFileSize);
        }
      } else {
        // Normal download (no decryption needed)
        await for (var chunk in response) {
          sink.add(chunk);
          received += chunk.length;
          _updateProgress(received, totalFileSize);
        }
      }

      await sink.close();
      _log('Downloaded $received bytes');
      return true;
    } catch (e) {
      _error('Download failed: $e');
      return false;
    }
  }

  /// Get track URL from Deezer
  Future<String?> _getTrackUrl(
    String trackId,
    String trackToken,
    String md5origin,
    String mediaVersion,
    int quality,
  ) async {
    try {
      _log(
        'Attempting to get track URL - trackId: $trackId, quality: $quality',
      );
      _log(
        'Has licenseToken: ${_deezer?.licenseToken != null && _deezer!.licenseToken!.isNotEmpty}',
      );

      if (_deezer?.licenseToken != null && _deezer!.licenseToken!.isNotEmpty) {
        _log('Trying API method with trackToken');
        var url = await _getTrackUrlFromAPI(trackId, trackToken, quality);

        if (url == null) {
          _log('First API attempt returned null, fetching fresh token');
          final freshToken = await _getFreshTrackToken(trackId);

          if (freshToken != null && freshToken.isNotEmpty) {
            _log('Got fresh token, retrying API');
            url = await _getTrackUrlFromAPI(trackId, freshToken, quality);
          } else {
            _log('Fresh token is null or empty');
          }
        }

        if (url != null && url.isNotEmpty) {
          _log('Successfully got URL from API');
          return url;
        } else {
          _log('API method failed, url is null or empty');
        }
      } else {
        _log('No license token, skipping API method');
      }
      return null;
    } catch (e, stackTrace) {
      _error('Error getting track URL: $e');
      _error('Stack trace: ${_safeSubstring(stackTrace.toString(), 300)}');
      return null;
    }
  }

  /// Fetch fresh track token
  Future<String?> _getFreshTrackToken(String trackId) async {
    try {
      _log('Fetching fresh track token for: $trackId');
      Map<dynamic, dynamic> data = await _deezer!.callGwApi(
        'song.getListData',
        params: {
          'sng_ids': [trackId],
        },
      );

      _log('Token fetch response keys: ${data.keys.join(", ")}');

      if (data['results']?['data'] != null &&
          (data['results']['data'] as List).isNotEmpty) {
        final trackData = data['results']['data'][0];
        final token = trackData['TRACK_TOKEN'];
        _log(
          'Fresh token obtained: ${token != null ? _safeSubstring(token, 20) : "null"}...',
        );
        return token;
      }

      _log('Token fetch: no results/data in response');
      return null;
    } catch (e, stackTrace) {
      _error('Error fetching fresh token: $e');
      _error('Stack trace: ${_safeSubstring(stackTrace.toString(), 300)}');
      return null;
    }
  }

  /// Get track URL from API
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

      _log(
        'API call - format: $format, trackToken: ${_safeSubstring(trackToken, 20)}...',
      );

      final payload = {
        'license_token': _deezer!.licenseToken,
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

      final headers = {
        'Content-Type': 'application/json',
        'Cookie': 'arl=${_deezer!.arl}',
      };

      _log('Calling media.deezer.com/v1/get_url');
      final response = await http.post(
        Uri.parse('https://media.deezer.com/v1/get_url'),
        headers: headers,
        body: jsonEncode(payload),
      );

      _log('API response status: ${response.statusCode}');

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body);
        _log('Response body keys: ${body.keys.join(", ")}');

        if (body['data'] != null) {
          final data = body['data'] as List;
          _log('Data array length: ${data.length}');

          for (var item in data) {
            if (item['media'] != null && (item['media'] as List).isNotEmpty) {
              final media = item['media'][0];
              if (media['sources'] != null &&
                  (media['sources'] as List).isNotEmpty) {
                final url = media['sources'][0]['url'];
                _log('Found URL in API response');
                return url;
              } else {
                _log('No sources in media');
              }
            } else {
              _log('No media in item');
            }
          }
        } else {
          _log('No data in response body');
        }
      } else {
        _log(
          'API returned status ${response.statusCode}: ${_safeSubstring(response.body, 200)}',
        );
      }
    } catch (e, stackTrace) {
      _error('Error getting track URL from API: $e');
      _error('Stack trace: ${_safeSubstring(stackTrace.toString(), 300)}');
    }
    return null;
  }

  /// Save cover art as separate file next to audio file
  Future<void> _saveCoverArt(File audioFile, Uint8List coverBytes) async {
    try {
      _log('_saveCoverArt called with audio file: ${audioFile.path}');
      final coverPath =
          audioFile.path.substring(0, audioFile.path.lastIndexOf('.')) + '.jpg';
      _log('Calculated cover path: $coverPath');
      final coverFile = File(coverPath);
      _log('Writing ${coverBytes.length} bytes to cover file');
      await coverFile.writeAsBytes(coverBytes);
      _log('Successfully saved track cover art: ${coverFile.path}');

      // Verify file was created
      final exists = await coverFile.exists();
      final size = exists ? await coverFile.length() : 0;
      _log('Verification - File exists: $exists, Size: $size bytes');
    } catch (e, stackTrace) {
      _error('Error saving cover art: $e');
      _error('Stack trace: ${_safeSubstring(stackTrace.toString(), 300)}');
    }
  }

  /// Download album cover
  Future<void> _downloadAlbumCover(File audioFile, Album album) async {
    try {
      final parentDir = audioFile.parent;
      final coverFile = File(p.join(parentDir.path, 'cover.jpg'));

      if (await coverFile.exists()) {
        _log('Album cover already exists: ${coverFile.path}');
        return;
      }

      final resolution = settings['albumArtResolution'] as int;
      final imageHash = album.art?.imageHash;
      final coverUrl =
          'http://e-cdn-images.deezer.com/images/cover/$imageHash/${resolution}x$resolution-000000-80-0-0.jpg';

      await coverFile.create(recursive: true);

      final response = await http.get(Uri.parse(coverUrl));
      if (response.statusCode == 200) {
        await coverFile.writeAsBytes(response.bodyBytes);
        _log('Downloaded album cover: ${coverFile.path}');

        if (settings['nomediaFiles'] as bool? ?? false) {
          final nomediaFile = File(p.join(parentDir.path, '.nomedia'));
          if (!await nomediaFile.exists()) {
            await nomediaFile.create();
          }
        }
      } else {
        await coverFile.delete();
      }
    } catch (e) {
      _error('Error downloading album cover: $e');
    }
  }

  /// Download LRC lyrics
  Future<void> _downloadLrcLyrics(File audioFile, Track track) async {
    try {
      _log('_downloadLrcLyrics called with audio file: ${audioFile.path}');
      Lyrics? lyrics = track.lyrics;

      if (lyrics == null || !lyrics.isLoaded()) {
        _log('Lyrics not loaded, fetching from API for track ID: ${track.id}');
        lyrics = await _deezer!.lyrics(track.id ?? '');
      }

      if (!lyrics.isLoaded()) {
        _log('No lyrics available for track - lyrics is not loaded.');
        return;
      }

      final lrcPath =
          audioFile.path.substring(0, audioFile.path.lastIndexOf('.')) + '.lrc';
      final lrcFile = File(lrcPath);

      _log('Calculated LRC path: ${lrcFile.path}');

      final lrcData = _generateLRC(track, lyrics);
      _log('Generated LRC data (${lrcData.length} characters)');

      await lrcFile.writeAsString(lrcData);
      _log('Successfully wrote LRC file');

      // Verify file was created
      final exists = await lrcFile.exists();
      final size = exists ? await lrcFile.length() : 0;
      _log('Verification - LRC file exists: $exists, Size: $size bytes');
    } catch (e, stackTrace) {
      _error('Error downloading LRC lyrics: $e');
      _error('Stack trace: ${_safeSubstring(stackTrace.toString(), 300)}');
    }
  }

  /// Generate LRC format from lyrics
  String _generateLRC(Track track, Lyrics lyrics) {
    final output = StringBuffer();

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

    if (lyrics.syncedLyrics != null) {
      for (var lyric in lyrics.syncedLyrics!) {
        if (lyric.lrcTimestamp != null && lyric.text != null) {
          output.write('${lyric.lrcTimestamp}${lyric.text}\r\n');
        }
      }
    }

    return output.toString();
  }

  /// Tag file with metadata
  Future<void> _tagFile(
    File audioFile,
    Track track,
    Map<dynamic, dynamic> publicAlbum,
    Map<dynamic, dynamic> publicTrack,
    Lyrics? lyrics,
    Uint8List? coverArtBytes,
  ) async {
    try {
      final tagger = MetaTagger();
      List<MetadataTag> tags = [];

      final enabledTags = settings['tags'] as List<dynamic>;

      // Title
      if (enabledTags.contains('title') && track.title != null) {
        tags.add(MetadataTag.text(CommonTags.title, track.title!));
      }
      // Album
      if (enabledTags.contains('album') && track.album!.title != null) {
        tags.add(MetadataTag.text(CommonTags.album, track.album!.title!));
      }

      // Artists
      if (enabledTags.contains('artist') &&
          track.artists != null &&
          track.artists!.isNotEmpty) {
        tags.add(
          MetadataTag.text(
            CommonTags.artist,
            track.artists!.map((a) => a.name).join(settings['artistSeparator']),
          ),
        );
      }

      // Album artist
      if (enabledTags.contains('albumArtist') &&
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
      if (enabledTags.contains('track')) {
        tags.add(
          MetadataTag.text(CommonTags.track, track.trackNumber.toString()),
        );
      }

      // Disc number
      if (enabledTags.contains('disc')) {
        tags.add(
          MetadataTag.text(CommonTags.disc, track.diskNumber.toString()),
        );
      }

      // Track total
      if (enabledTags.contains('trackTotal') &&
          publicAlbum['nb_tracks'] != null) {
        tags.add(
          MetadataTag.text(
            CommonTags.trackTotal,
            publicAlbum['nb_tracks'].toString(),
          ),
        );
      }

      // Date
      if (enabledTags.contains('date') && track.album?.releaseDate != null) {
        tags.add(MetadataTag.text(CommonTags.date, track.album!.releaseDate!));
      }

      // Genre
      if (enabledTags.contains('genre')) {
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

      // Contributors (Composer, Engineer, Mixer, Producer, Author, Writer)
      if (enabledTags.contains('contributors') && track.contributors != null) {
        final contrib = track.contributors!;
        final sep = settings['artistSeparator'];

        // Composer
        if (contrib.composers != null && contrib.composers!.isNotEmpty) {
          final composer = contrib.composers!.join(sep);
          tags.add(MetadataTag.text(CommonTags.composer, composer));
        }
        // Engineer
        if (contrib.engineers != null && contrib.engineers!.isNotEmpty) {
          final engineer = contrib.engineers!.join(sep);
          tags.add(MetadataTag.text(CommonTags.comment, engineer));
        }
        // Mixer
        if (contrib.mixers != null && contrib.mixers!.isNotEmpty) {
          final mixer = contrib.mixers!.join(sep);
          tags.add(MetadataTag.text('MIXER', mixer));
        }
        // Producer
        if (contrib.producers != null && contrib.producers!.isNotEmpty) {
          final producer = contrib.producers!.join(sep);
          tags.add(MetadataTag.text('PRODUCER', producer));
        }
        // Author
        if (contrib.authors != null && contrib.authors!.isNotEmpty) {
          final author = contrib.authors!.join(sep);
          tags.add(MetadataTag.text('AUTHOR', author));
        }
        // Writer
        if (contrib.writers != null && contrib.writers!.isNotEmpty) {
          final writer = contrib.writers!.join(sep);
          tags.add(MetadataTag.text('WRITER', writer));
        }
      }

      // BPM
      if (enabledTags.contains('bpm') && publicTrack['bpm'] != null) {
        tags.add(
          MetadataTag.text(CommonTags.bpm, publicTrack['bpm'].toString()),
        );
      }

      // Label
      if (enabledTags.contains('label') && publicAlbum['label'] != null) {
        tags.add(MetadataTag.text(CommonTags.label, publicAlbum['label']));
      }

      // ISRC
      if (enabledTags.contains('isrc') && publicTrack['isrc'] != null) {
        tags.add(MetadataTag.text(CommonTags.isrc, publicTrack['isrc']));
      }

      // UPC
      if (enabledTags.contains('upc') && publicAlbum['upc'] != null) {
        tags.add(MetadataTag.text(CommonTags.barcode, publicAlbum['upc']));
      }

      // Lyrics
      if (enabledTags.contains('lyrics') &&
          lyrics != null &&
          lyrics.unsyncedLyrics != null) {
        tags.add(MetadataTag.text(CommonTags.lyrics, lyrics.unsyncedLyrics!));
      }

      // Cover art - use in-memory bytes if available
      if (enabledTags.contains('art') && coverArtBytes != null) {
        _log('Adding cover art to tags (${coverArtBytes.length} bytes)');
        tags.add(MetadataTag.binary(CommonTags.albumArt, coverArtBytes));
      }
      // Write metadata
      await tagger.writeTags(audioFile.path, tags);

      _log('Tagged file: ${audioFile.path}');
    } catch (e, stackTrace) {
      _error('Tagging error: $e\n$stackTrace');
    }
  }

  /// Generate filename with metadata
  /// Process the full path template replacing all placeholders
  String _processPathTemplate(
    String pathTemplate,
    Track track,
    Album? album,
    int quality,
  ) {
    String result = pathTemplate;

    result = result.replaceAll('%title%', _sanitize(track.title ?? ''));
    result = result.replaceAll('%album%', _sanitize(track.album?.title ?? ''));

    if (album != null && album.artists != null && album.artists!.isNotEmpty) {
      result = result.replaceAll(
        '%albumArtist%',
        _sanitize(album.artists!.first.name ?? ''),
      );
    } else {
      result = result.replaceAll('%albumArtist%', '');
    }

    if (track.artists != null && track.artists!.isNotEmpty) {
      final artistSep = settings['artistSeparator'] as String? ?? ', ';
      result = result.replaceAll(
        '%artists%',
        _sanitize(track.artists!.map((a) => a.name).join(artistSep)),
      );
      result = result.replaceAll(
        '%artist%',
        _sanitize(track.artists!.first.name ?? ''),
      );
    }

    final trackNumber = track.trackNumber ?? 1;
    result = result.replaceAll('%trackNumber%', trackNumber.toString());
    result = result.replaceAll(
      '%0trackNumber%',
      trackNumber.toString().padLeft(2, '0'),
    );

    if (track.album?.releaseDate != null) {
      final year = track.album!.releaseDate!.split('-')[0];
      result = result.replaceAll('%year%', year);
      result = result.replaceAll('%date%', track.album!.releaseDate!);
    }

    // Clean up any double slashes or dots in the path
    result = result.replaceAll(RegExp(r'/\.+'), '/');
    result = result.replaceAll(RegExp(r'\\\.+'), '\\');

    // Ensure the path has the correct extension based on quality
    // Only add extension if the path doesn't already have one
    if (!result.endsWith('.mp3') && !result.endsWith('.flac')) {
      if (quality == 9) {
        result = '$result.flac';
      } else {
        result = '$result.mp3';
      }
    }

    return result;
  }

  String _sanitize(String input) {
    return input
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}
