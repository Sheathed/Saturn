import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:metatagger/metatagger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../platform/download_metadata.dart';
import '../platform/download_platform_factory.dart';
import '../platform/music_platform.dart';
import '../platform/stream_proxy_server.dart';
import '../lyrics/lyrics_registry.dart';
import '../settings.dart';
import '../utils/app_http_proxy.dart';
import 'definitions.dart';
import 'download_log.dart';

class CoordinatorMessage {
  final String type;
  final Map<String, dynamic>? data;

  CoordinatorMessage({required this.type, this.data});

  Map<String, dynamic> toJson() => {'type': type, 'data': data};

  factory CoordinatorMessage.fromJson(Map<String, dynamic> json) =>
      CoordinatorMessage(
        type: json['type'] as String,
        data: json['data'] as Map<String, dynamic>?,
      );
}

class IsolateResponse {
  final String type;
  final Map<String, dynamic>? data;

  IsolateResponse({required this.type, this.data});

  Map<String, dynamic> toJson() => {'type': type, 'data': data};

  factory IsolateResponse.fromJson(Map<String, dynamic> json) =>
      IsolateResponse(
        type: json['type'] as String,
        data: json['data'] as Map<String, dynamic>?,
      );
}

/// Index 4 intentionally remains the platform-specific failure state so rows
/// written by releases that called it DEEZER_ERROR remain compatible.
enum DownloadStateDart {
  NONE,
  DOWNLOADING,
  POST,
  DONE,
  PLATFORM_ERROR,
  ERROR,
  UNAVAILABLE,
}

class DownloadTask {
  int id;
  String path;
  bool private;
  int quality;
  String platformId;
  String trackId;
  DownloadStateDart state;
  String title;
  String image;
  int received;
  int filesize;
  int downloaded;
  String? resolvedFormat;
  int? resolvedBitrate;
  bool unavailable;
  Map<String, dynamic>? lyrics;

  DownloadTask({
    required this.id,
    required this.path,
    required this.private,
    required this.quality,
    required this.platformId,
    required this.trackId,
    required this.state,
    required this.title,
    required this.image,
    this.received = 0,
    this.filesize = 0,
    this.downloaded = 0,
    this.resolvedFormat,
    this.resolvedBitrate,
    this.unavailable = false,
    this.lyrics,
  });

  factory DownloadTask.fromSQL(Map<String, dynamic> row) {
    final downloaded = row['downloaded'] as int? ?? 0;
    return DownloadTask(
      id: row['id'] as int,
      path: row['path'] as String,
      private: row['private'] == 1,
      quality: row['quality'] as int,
      platformId: row['platformId'] as String? ?? 'deezer',
      trackId: row['trackId'] as String,
      state: DownloadStateDart.values[row['state'] as int],
      title: row['title'] as String? ?? '',
      image: row['image'] as String? ?? '',
      received: downloaded,
      filesize: downloaded,
      downloaded: downloaded,
      resolvedFormat: row['resolvedFormat'] as String?,
      resolvedBitrate: row['resolvedBitrate'] as int?,
      unavailable: row['unavailable'] == 1,
    );
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'path': path,
    'private': private,
    'quality': quality,
    'platformId': platformId,
    'trackId': trackId,
    'state': state.index,
    'title': title,
    'image': image,
    'received': received,
    'filesize': filesize,
    'resolvedFormat': resolvedFormat,
    'resolvedBitrate': resolvedBitrate,
    'unavailable': unavailable,
    if (lyrics != null) 'lyrics': lyrics,
  };

  Map<String, dynamic> toSQL() => {
    'id': id,
    'path': path,
    'private': private ? 1 : 0,
    'quality': quality,
    'platformId': platformId,
    'trackId': trackId,
    'state': state.index,
    'title': title,
    'image': image,
    'downloaded': downloaded,
    'resolvedFormat': resolvedFormat,
    'resolvedBitrate': resolvedBitrate,
    'unavailable': unavailable ? 1 : 0,
  };
}

class DownloadIsolateManager {
  Isolate? _isolate;
  SendPort? _isolateSendPort;
  final ReceivePort _receivePort = ReceivePort();
  final Completer<void> _readyCompleter = Completer<void>();
  final StreamController<IsolateResponse> _responseController =
      StreamController.broadcast();

  bool get isReady => _readyCompleter.isCompleted;
  Stream<IsolateResponse> get responses => _responseController.stream;

  Future<void> start(
    String dbPath,
    Map<String, dynamic> settings, {
    required int streamProxyPort,
  }) async {
    if (_isolate != null) return;
    _isolate = await Isolate.spawn(_coordinatorEntryPoint, {
      'sendPort': _receivePort.sendPort,
      'dbPath': dbPath,
      'rootIsolateToken': RootIsolateToken.instance!,
      'settings': settings,
      'streamProxyPort': streamProxyPort,
    });
    _receivePort.listen((message) {
      if (_isolateSendPort == null && message is SendPort) {
        _isolateSendPort = message;
        _readyCompleter.complete();
      } else if (message is Map<String, dynamic>) {
        _responseController.add(IsolateResponse.fromJson(message));
      }
    });
    await _readyCompleter.future;
  }

  Future<void> stop() async {
    if (_isolate == null) return;
    sendMessage(CoordinatorMessage(type: 'shutdown'));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _isolateSendPort = null;
  }

  void sendMessage(CoordinatorMessage message) {
    if (isReady) _isolateSendPort?.send(message.toJson());
  }

  static Future<void> _coordinatorEntryPoint(
    Map<String, dynamic> arguments,
  ) async {
    final mainSendPort = arguments['sendPort'] as SendPort;
    final receivePort = ReceivePort();
    mainSendPort.send(receivePort.sendPort);

    final coordinator = _DownloadCoordinator(
      mainSendPort: mainSendPort,
      dbPath: arguments['dbPath'] as String,
      rootIsolateToken: arguments['rootIsolateToken'] as RootIsolateToken,
      settings: arguments['settings'] as Map<String, dynamic>,
      streamProxyPort: arguments['streamProxyPort'] as int,
    );
    await coordinator.init();

    await for (final message in receivePort) {
      if (message is! Map<String, dynamic>) continue;
      final parsed = CoordinatorMessage.fromJson(message);
      await coordinator.handleMessage(parsed);
      if (parsed.type == 'shutdown') {
        await coordinator.dispose();
        receivePort.close();
        return;
      }
    }
  }
}

class _DownloadCoordinator {
  final SendPort mainSendPort;
  final String dbPath;
  final RootIsolateToken rootIsolateToken;
  final int streamProxyPort;
  Map<String, dynamic> settings;

  Database? _db;
  DownloadLog? _logger;
  final List<DownloadTask> _queue = [];
  final Map<int, _WorkerHandle> _activeWorkers = {};
  bool _running = false;
  bool _queueUpdateInProgress = false;
  bool _queueUpdateRequested = false;
  Timer? _progressTimer;

  _DownloadCoordinator({
    required this.mainSendPort,
    required this.dbPath,
    required this.rootIsolateToken,
    required this.settings,
    required this.streamProxyPort,
  });

  Future<void> init() async {
    BackgroundIsolateBinaryMessenger.ensureInitialized(rootIsolateToken);
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    _logger = DownloadLog();
    await _logger!.open();
    _db = await openDatabase(
      dbPath,
      onConfigure: (Database db) async {
        await db.rawQuery('PRAGMA busy_timeout = 10000');
        await db.rawQuery('PRAGMA journal_mode = WAL');
      },
    );
    await _loadQueue();
    _progressTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _sendProgressUpdate(),
    );
    _logger!.log('Multiplatform download coordinator initialized');
  }

  Future<void> dispose() async {
    _progressTimer?.cancel();
    for (final worker in _activeWorkers.values) {
      worker.isolate.kill(priority: Isolate.immediate);
      worker.receivePort.close();
      worker.errorPort.close();
    }
    _activeWorkers.clear();
    await _logger?.close();
    await _db?.close();
  }

  Future<void> handleMessage(CoordinatorMessage message) async {
    switch (message.type) {
      case 'start':
        _running = true;
        await _loadQueue();
        await _updateQueue();
        break;
      case 'stop':
        await _stopWorkers();
        break;
      case 'addDownloads':
        await _addDownloads(message.data!['downloads'] as List<dynamic>);
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
      case 'shutdown':
        _running = false;
        break;
    }
  }

  Future<void> _loadQueue() async {
    final rows = await _db!.query('Downloads');
    _queue.clear();
    for (final row in rows) {
      final task = DownloadTask.fromSQL(row);
      if (task.state == DownloadStateDart.DOWNLOADING ||
          task.state == DownloadStateDart.POST) {
        task.state = DownloadStateDart.NONE;
        await _db!.update(
          'Downloads',
          {'state': task.state.index},
          where: 'id = ?',
          whereArgs: [task.id],
        );
      }
      _queue.add(task);
    }
  }

  Future<void> _stopWorkers() async {
    _running = false;
    for (final worker in _activeWorkers.values) {
      worker.isolate.kill(priority: Isolate.immediate);
      worker.receivePort.close();
      worker.download.state = DownloadStateDart.NONE;
      await _db!.update(
        'Downloads',
        {
          'state': DownloadStateDart.NONE.index,
          'downloaded': worker.download.received,
        },
        where: 'id = ?',
        whereArgs: [worker.download.id],
      );
    }
    _activeWorkers.clear();
    await _loadQueue();
    _sendStateUpdate();
    _sendDownloadsList();
  }

  Future<void> _addDownloads(List<dynamic> downloads) async {
    var added = 0;
    for (final raw in downloads) {
      final data = Map<String, dynamic>.from(raw as Map);
      final trackId = data['trackId'] as String?;
      final path = data['path'] as String?;
      final unavailable = data['unavailable'] == true;
      final platformId =
          data['platformId'] as String? ??
          (settings['activePlatformId'] as String?) ??
          'general';
      if (trackId == null || path == null) continue;

      final existing = await _db!.query(
        'Downloads',
        where: 'platformId = ? AND trackId = ? AND path = ?',
        whereArgs: [platformId, trackId, path],
      );
      if (existing.isEmpty) {
        await _db!.insert('Downloads', {
          'path': path,
          'private': data['private'] == true ? 1 : 0,
          'quality': data['quality'] as int,
          'platformId': platformId,
          'state': unavailable
              ? DownloadStateDart.UNAVAILABLE.index
              : DownloadStateDart.NONE.index,
          'trackId': trackId,
          'title': data['title'] ?? '',
          'image': data['image'] ?? '',
          'downloaded': 0,
          'unavailable': unavailable ? 1 : 0,
        });
        added++;
      } else if (unavailable) {
        await _db!.update(
          'Downloads',
          {'state': DownloadStateDart.UNAVAILABLE.index, 'unavailable': 1},
          where: 'id = ?',
          whereArgs: [existing.first['id']],
        );
        added++;
      } else if ((existing.first['state'] as int) >=
          DownloadStateDart.DONE.index) {
        await _db!.update(
          'Downloads',
          {
            'state': DownloadStateDart.NONE.index,
            'downloaded': 0,
            'unavailable': 0,
          },
          where: 'id = ?',
          whereArgs: [existing.first['id']],
        );
        added++;
      }
    }
    await _loadQueue();
    _sendResponse(
      IsolateResponse(type: 'downloadsAdded', data: {'count': added}),
    );
    _sendStateUpdate();
    _sendDownloadsList();
    if (_running) await _updateQueue();
  }

  Future<void> _removeDownload(int id) async {
    final worker = _activeWorkers.remove(id);
    worker?.isolate.kill(priority: Isolate.immediate);
    worker?.receivePort.close();
    worker?.errorPort.close();
    await _db!.delete('Downloads', where: 'id = ?', whereArgs: [id]);
    await _loadQueue();
    _sendStateUpdate();
    _sendDownloadsList();
  }

  Future<void> _retryDownloads() async {
    await _db!.update(
      'Downloads',
      {'state': DownloadStateDart.NONE.index, 'downloaded': 0},
      where: 'state IN (?, ?)',
      whereArgs: [
        DownloadStateDart.PLATFORM_ERROR.index,
        DownloadStateDart.ERROR.index,
      ],
    );
    await _loadQueue();
    _sendDownloadsList();
    if (_running) await _updateQueue();
  }

  Future<void> _removeByState(DownloadStateDart state) async {
    if (state == DownloadStateDart.DOWNLOADING ||
        state == DownloadStateDart.POST) {
      return;
    }
    await _db!.delete(
      'Downloads',
      where: 'state = ?',
      whereArgs: [state.index],
    );
    await _loadQueue();
    _sendStateUpdate();
    _sendDownloadsList();
  }

  Future<void> _updateQueue() async {
    if (_queueUpdateInProgress) {
      _queueUpdateRequested = true;
      return;
    }
    _queueUpdateInProgress = true;
    try {
      do {
        _queueUpdateRequested = false;
        await _updateQueueOnce();
      } while (_queueUpdateRequested);
    } finally {
      _queueUpdateInProgress = false;
    }
  }

  Future<void> _updateQueueOnce() async {
    final finishedIds = _activeWorkers.entries
        .where((entry) => _isTerminal(entry.value.download.state))
        .map((entry) => entry.key)
        .toList();
    for (final id in finishedIds) {
      final worker = _activeWorkers.remove(id)!;
      _logger?.log(
        'Persisting terminal state ${worker.download.state.name} '
        'for download id $id',
      );
      worker.isolate.kill(priority: Isolate.immediate);
      worker.receivePort.close();
      worker.errorPort.close();
      try {
        final updatedRows = await _db!.update(
          'Downloads',
          worker.download.toSQL(),
          where: 'id = ?',
          whereArgs: [id],
        );
        _logger?.log(
          'Persisted terminal state for download id $id '
          '(updated rows: $updatedRows)',
        );
      } catch (error, stackTrace) {
        _logger?.error(
          'Could not persist terminal state for download id $id: '
          '$error\n$stackTrace',
        );
      }
    }

    final maxThreads = settings['downloadThreads'] as int? ?? 2;
    while (_running && _activeWorkers.length < maxThreads) {
      DownloadTask? next;
      for (final candidate in _queue) {
        if (candidate.state == DownloadStateDart.NONE &&
            !_activeWorkers.containsKey(candidate.id)) {
          next = candidate;
          break;
        }
      }
      if (next == null) break;
      await _startWorker(next);
    }
    _sendStateUpdate();
    _sendDownloadsList();
  }

  Future<void> _startWorker(DownloadTask download) async {
    download.state = DownloadStateDart.DOWNLOADING;
    await _db!.update(
      'Downloads',
      {'state': download.state.index},
      where: 'id = ?',
      whereArgs: [download.id],
    );
    final receivePort = ReceivePort();
    final errorPort = ReceivePort();
    late final Isolate isolate;
    try {
      isolate = await Isolate.spawn(
        _workerEntryPoint,
        {
          'sendPort': receivePort.sendPort,
          'download': download.toSQL(),
          'settings': settings,
          'rootIsolateToken': rootIsolateToken,
          'streamProxyPort': streamProxyPort,
        },
        onError: errorPort.sendPort,
        errorsAreFatal: true,
      );
    } catch (error, stackTrace) {
      receivePort.close();
      errorPort.close();
      download.state = DownloadStateDart.ERROR;
      await _db!.update(
        'Downloads',
        {'state': download.state.index},
        where: 'id = ?',
        whereArgs: [download.id],
      );
      _logger?.error(
        'Could not start worker for ${download.platformId} '
        '${download.trackId}: $error\n$stackTrace',
      );
      return;
    }
    _activeWorkers[download.id] = _WorkerHandle(
      isolate: isolate,
      receivePort: receivePort,
      errorPort: errorPort,
      download: download,
    );
    receivePort.listen((message) {
      if (message is Map<String, dynamic>) {
        unawaited(_handleWorkerMessage(download.id, message));
      }
    });
    errorPort.listen((message) {
      final details = message is List
          ? message.map((part) => part.toString()).join('\n')
          : message.toString();
      _handleWorkerIsolateError(download.id, details);
    });
    _logger?.log(
      'Started ${download.platformId} worker for ${download.trackId}',
    );
  }

  void _handleWorkerIsolateError(int downloadId, String details) {
    final worker = _activeWorkers[downloadId];
    if (worker == null || _isTerminal(worker.download.state)) return;

    final download = worker.download;
    download.state = DownloadStateDart.ERROR;
    _logger?.error(
      'Worker isolate crashed for ${download.platformId} ${download.trackId}:\n'
      '$details',
    );
    _sendResponse(
      IsolateResponse(
        type: 'downloadError',
        data: {
          'id': download.id,
          'platformId': download.platformId,
          'trackId': download.trackId,
          'state': download.state.index,
        },
      ),
    );
    unawaited(_updateQueue());
  }

  Future<void> _handleWorkerMessage(
    int downloadId,
    Map<String, dynamic> message,
  ) async {
    final download = _queue.firstWhere((item) => item.id == downloadId);
    switch (message['type']) {
      case 'progress':
        download.received = message['received'] as int;
        download.filesize = message['total'] as int;
        download.downloaded = download.received;
        download.resolvedFormat =
            message['resolvedFormat'] as String? ?? download.resolvedFormat;
        download.resolvedBitrate =
            message['resolvedBitrate'] as int? ?? download.resolvedBitrate;
        break;
      case 'stateChange':
        final previous = download.state;
        download.state = DownloadStateDart.values[message['state'] as int];
        if (message['unavailable'] is bool) {
          download.unavailable = message['unavailable'] as bool;
        }
        if (message['lyrics'] is Map) {
          download.lyrics = Map<String, dynamic>.from(message['lyrics'] as Map);
        }
        _logger?.log(
          'Worker state message for id $downloadId: '
          '${previous.name} -> ${download.state.name}',
        );
        if (download.state == DownloadStateDart.DONE &&
            previous != DownloadStateDart.DONE) {
          _logger?.log(
            'Forwarding downloadComplete for id $downloadId to the app',
          );
          _sendResponse(
            IsolateResponse(
              type: 'downloadComplete',
              data: {
                'id': download.id,
                'platformId': download.platformId,
                'trackId': download.trackId,
                'title': download.title,
                'download': download.toMap(),
              },
            ),
          );
        }
        if (_isTerminal(download.state)) {
          // Persist the terminal state before notifying the app. The app may
          // immediately refresh offline playlists in response to this event.
          await _updateQueue();
          if (download.state != DownloadStateDart.DONE) {
            _sendResponse(
              IsolateResponse(
                type: 'downloadError',
                data: {
                  'id': download.id,
                  'platformId': download.platformId,
                  'trackId': download.trackId,
                  'state': download.state.index,
                  'private': download.private,
                },
              ),
            );
          }
        }
        break;
      case 'log':
        _logger?.log(message['message'] as String);
        break;
      case 'error':
        _logger?.error(message['message'] as String);
        break;
      case 'youtubeJavaScriptRequest':
        _sendResponse(
          IsolateResponse(
            type: 'youtubeJavaScriptRequest',
            data: {
              'requestId': message['requestId'],
              'jsCode': message['jsCode'],
              'replyPort': message['replyPort'],
            },
          ),
        );
        break;
    }
  }

  bool _isTerminal(DownloadStateDart state) =>
      state == DownloadStateDart.DONE ||
      state == DownloadStateDart.PLATFORM_ERROR ||
      state == DownloadStateDart.ERROR ||
      state == DownloadStateDart.UNAVAILABLE;

  void _sendProgressUpdate() {
    if (_activeWorkers.isEmpty) return;
    _sendResponse(
      IsolateResponse(
        type: 'progress',
        data: {
          'downloads': _activeWorkers.values
              .map((worker) => worker.download.toMap())
              .toList(),
        },
      ),
    );
  }

  void _sendStateUpdate() {
    _sendResponse(
      IsolateResponse(
        type: 'stateChange',
        data: {
          'running': _running,
          'queueSize': _queue
              .where((item) => item.state == DownloadStateDart.NONE)
              .length,
          'activeDownloads': _activeWorkers.length,
        },
      ),
    );
  }

  void _sendDownloadsList() {
    _sendResponse(
      IsolateResponse(
        type: 'downloadsList',
        data: {'downloads': _queue.map((item) => item.toMap()).toList()},
      ),
    );
  }

  void _sendResponse(IsolateResponse response) {
    mainSendPort.send(response.toJson());
  }
}

class _WorkerHandle {
  final Isolate isolate;
  final ReceivePort receivePort;
  final ReceivePort errorPort;
  final DownloadTask download;

  _WorkerHandle({
    required this.isolate,
    required this.receivePort,
    required this.errorPort,
    required this.download,
  });
}

Future<void> _workerEntryPoint(Map<String, dynamic> arguments) async {
  final rootToken = arguments['rootIsolateToken'] as RootIsolateToken;
  BackgroundIsolateBinaryMessenger.ensureInitialized(rootToken);
  final workerSettings = arguments['settings'] as Map<String, dynamic>;
  StreamProxyServer.instance.configureRemotePort(
    arguments['streamProxyPort'] as int,
  );
  final javascriptBridge = _RootIsolateJavaScriptBridge(
    arguments['sendPort'] as SendPort,
  );
  AppHttpProxy.configure(
    workerSettings['proxyAddress'] as String?,
    username: workerSettings['proxyUsername'] as String?,
    password: workerSettings['proxyPassword'] as String?,
  );
  try {
    final platformId =
        (arguments['download'] as Map<String, dynamic>)['platformId'] as String;
    final platform = await createDownloadPlatform(
      platformId,
      workerSettings,
      executeJavaScriptOnRootIsolate: javascriptBridge.execute,
    );
    final worker = _DownloadWorker(
      sendPort: arguments['sendPort'] as SendPort,
      download: DownloadTask.fromSQL(
        arguments['download'] as Map<String, dynamic>,
      ),
      settings: workerSettings,
      platform: platform,
      executeJavaScriptOnRootIsolate: javascriptBridge.execute,
    );
    await worker.execute();
  } finally {
    javascriptBridge.close();
  }
}

/// Proxies YouTube's JavaScript signature challenges to the root isolate,
/// where Flutter platform channels and the offscreen WebView are available.
class _RootIsolateJavaScriptBridge {
  _RootIsolateJavaScriptBridge(this._coordinatorSendPort) {
    _responses.listen((message) {
      if (message is! Map) return;
      final id = message['requestId'];
      if (id is! int) return;
      final completer = _pending.remove(id);
      if (completer == null) return;
      final error = message['error'];
      if (error is String) {
        completer.completeError(StateError(error));
      } else if (message['result'] is String) {
        completer.complete(message['result'] as String);
      } else {
        completer.completeError(
          StateError('Root isolate returned an invalid YouTube JS result'),
        );
      }
    });
  }

  final SendPort _coordinatorSendPort;
  final ReceivePort _responses = ReceivePort();
  final Map<int, Completer<String>> _pending = {};
  int _nextRequestId = 0;
  bool _closed = false;

  Future<String> execute(String jsCode) async {
    if (_closed) throw StateError('YouTube JS bridge is closed');
    final id = ++_nextRequestId;
    final completer = Completer<String>();
    _pending[id] = completer;
    _coordinatorSendPort.send({
      'type': 'youtubeJavaScriptRequest',
      'requestId': id,
      'jsCode': jsCode,
      'replyPort': _responses.sendPort,
    });
    try {
      return await completer.future.timeout(const Duration(seconds: 60));
    } finally {
      _pending.remove(id);
    }
  }

  void close() {
    _closed = true;
    _responses.close();
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('YouTube JS bridge closed'));
      }
    }
    _pending.clear();
  }
}

class _DownloadWorker {
  final SendPort sendPort;
  final DownloadTask download;
  final Map<String, dynamic> settings;
  final MusicPlatform platform;
  final Future<String> Function(String jsCode)? executeJavaScriptOnRootIsolate;

  _DownloadWorker({
    required this.sendPort,
    required this.download,
    required this.settings,
    required this.platform,
    this.executeJavaScriptOnRootIsolate,
  });

  void _log(String message) => sendPort.send({
    'type': 'log',
    'message': '[${download.platformId} id:${download.id}] $message',
  });

  void _error(String message) => sendPort.send({
    'type': 'error',
    'message': '[${download.platformId} id:${download.id}] $message',
  });

  void _updateState(
    DownloadStateDart state, {
    bool? unavailable,
    Map<String, dynamic>? lyrics,
  }) {
    download.state = state;
    if (unavailable != null) download.unavailable = unavailable;
    _log('Reporting worker state ${state.name}');
    sendPort.send({
      'type': 'stateChange',
      'state': state.index,
      'unavailable': ?unavailable,
      'lyrics': ?lyrics,
    });
  }

  void _updateProgress(
    int received,
    int total, {
    String? resolvedFormat,
    int? resolvedBitrate,
  }) {
    download.received = received;
    download.filesize = total;
    download.downloaded = received;
    if (resolvedFormat != null) download.resolvedFormat = resolvedFormat;
    if (resolvedBitrate != null) download.resolvedBitrate = resolvedBitrate;
    sendPort.send({
      'type': 'progress',
      'received': received,
      'total': total,
      'resolvedFormat': download.resolvedFormat,
      'resolvedBitrate': download.resolvedBitrate,
    });
  }

  Future<void> execute() async {
    PlatformDownloadMetadata metadata;
    try {
      _log('Resolving track metadata');
      if (!platform.capabilities.supportsDownload) {
        throw UnsupportedError(
          '${platform.platformName} does not support downloads',
        );
      }
      metadata = await platform
          .getDownloadMetadata(download.trackId)
          .timeout(
            const Duration(seconds: 45),
            onTimeout: () => throw TimeoutException(
              'Timed out resolving ${platform.platformName} track metadata',
            ),
          );
      _log('Track metadata resolved');
    } catch (error, stackTrace) {
      _error('Platform setup or metadata failed: $error\n$stackTrace');
      _updateState(DownloadStateDart.PLATFORM_ERROR);
      return;
    }

    try {
      final quality = _qualityFromIndex(download.quality);
      _log('Registering track with shared stream proxy');
      await StreamProxyServer.instance.registerTrackWithProxy(
        metadata.track.toMediaItem(),
      );
      _log('Resolving download stream');
      final stream = await platform
          .getStreamProvider()
          .getStream(metadata.track, quality)
          .timeout(
            const Duration(seconds: 45),
            onTimeout: () => throw TimeoutException(
              'Timed out resolving ${platform.platformName} download stream',
            ),
          );
      // The generic downloader writes a standalone audio file. A Widevine
      // stream needs a persistent DRM license and DRM-aware offline storage,
      // neither of which this worker currently provides. Keep this failure
      // scoped to the download task so normal online playback remains allowed.
      if (stream.meta['drmLicenseUrl'] is String &&
          (stream.meta['drmLicenseUrl'] as String).isNotEmpty) {
        _log('Stream requires Widevine; offline DRM licenses are unsupported');
        _updateState(DownloadStateDart.UNAVAILABLE, unavailable: true);
        return;
      }
      if (stream.meta['downloadable'] == false) {
        throw UnsupportedError(
          'This track only exposes an adaptive stream and cannot be downloaded as a direct audio file.',
        );
      }
      final resolvedFormat = stream.format ?? 'MP3';
      var resolvedBitrate = stream.bitrate;
      final extension = _extensionFor(metadata, resolvedFormat);
      metadata = metadata.withStreamFormat(
        format: resolvedFormat,
        fileExtension: extension,
      );
      _updateProgress(
        download.received,
        download.filesize,
        resolvedFormat: resolvedFormat,
        resolvedBitrate: resolvedBitrate,
      );

      final outputPath = download.private
          ? download.path
          : _processPathTemplate(download.path, metadata, extension);
      final outputFile = File(outputPath);
      final overwrite =
          settings['overwriteDownload'] as bool? ??
          settings['overwriteFile'] as bool? ??
          false;
      if (await outputFile.exists() && !overwrite) {
        _log('File already exists, skipping ${outputFile.path}');
        final outputSize = await outputFile.length();
        resolvedBitrate ??= _estimateBitrateKbps(
          outputSize,
          metadata.track.duration,
        );
        _updateProgress(
          outputSize,
          outputSize,
          resolvedFormat: resolvedFormat,
          resolvedBitrate: resolvedBitrate,
        );
        final lyrics = download.private
            ? await _resolveOfflineLyrics(platform, metadata)
            : null;
        _updateState(
          DownloadStateDart.DONE,
          lyrics: lyrics == null ? null : _lyricsToJson(lyrics),
        );
        return;
      }

      final tempRoot = await _temporaryRoot();
      final tempFile = File(
        p.join(
          tempRoot.path,
          'cache',
          '${download.platformId}_${download.id}.$extension.part',
        ),
      );
      await tempFile.parent.create(recursive: true);
      _log('Requesting audio bytes');
      final downloaded = await _download(
        stream.url,
        tempFile,
        requestHeaders: stream.requestHeaders,
      );
      if (downloaded == null) {
        _updateState(DownloadStateDart.ERROR);
        return;
      }
      resolvedBitrate ??= _estimateBitrateKbps(
        downloaded,
        metadata.track.duration,
      );
      _updateProgress(
        downloaded,
        downloaded,
        resolvedFormat: resolvedFormat,
        resolvedBitrate: resolvedBitrate,
      );

      _updateState(DownloadStateDart.POST);
      await outputFile.parent.create(recursive: true);
      if (await outputFile.exists()) await outputFile.delete();
      await tempFile.copy(outputFile.path);
      await tempFile.delete();

      if (!download.private) {
        _log('Audio file saved; applying optional tags and artwork');
        await _postProcess(outputFile, platform, metadata);
      }
      final offlineLyrics = download.private
          ? await _resolveOfflineLyrics(platform, metadata)
          : null;
      final outputSize = await outputFile.length();
      _updateProgress(outputSize, outputSize);
      _updateState(
        DownloadStateDart.DONE,
        lyrics: offlineLyrics == null ? null : _lyricsToJson(offlineLyrics),
      );
      _log('Download completed: ${outputFile.path}');
    } catch (error, stackTrace) {
      _error('Download failed: $error\n$stackTrace');
      _updateState(DownloadStateDart.ERROR);
    }
  }

  Map<String, dynamic> _lyricsToJson(LyricsFull lyrics) => {
    'id': lyrics.id,
    'writers': lyrics.writers,
    'syncedLyrics': lyrics.syncedLyrics
        ?.map((line) => line.toJson())
        .toList(),
    'errorMessage': lyrics.errorMessage,
    'unsyncedLyrics': lyrics.unsyncedLyrics,
    'unsyncedTranslatedLyrics': lyrics.unsyncedTranslatedLyrics,
    'unsyncedRomanizedLyrics': lyrics.unsyncedRomanizedLyrics,
    'isExplicit': lyrics.isExplicit,
    'copyright': lyrics.copyright,
  };

  Future<LyricsFull?> _resolveOfflineLyrics(
    MusicPlatform nativePlatform,
    PlatformDownloadMetadata metadata,
  ) async {
    final track = metadata.track;
    if (!(settings['saveOfflineTrackLyrics'] as bool? ?? false)) {
      _log('Skipping offline lyrics: saveOfflineTrackLyrics is disabled');
      return null;
    }
    final savedChoice = _savedLyricsChoice(track);
    var resolvedSource = savedChoice ?? 'default';
    try {
      Lyrics? lyrics;
      if (savedChoice != null &&
          savedChoice != 'default' &&
          savedChoice != 'native' &&
          savedChoice.startsWith('platform:')) {
        final platformId = savedChoice.substring('platform:'.length);
        final provider = platformId == nativePlatform.platformId
            ? nativePlatform
            : await createDownloadPlatform(
                platformId,
                settings,
                executeJavaScriptOnRootIsolate:
                    executeJavaScriptOnRootIsolate,
              );
        resolvedSource = 'platform:${provider.platformId}';
        if (provider.platformId == nativePlatform.platformId) {
          lyrics = await _getNativeLyrics(provider, metadata);
        } else {
          final queries = <String>{
            provider.getLyricsSearchQuery(track),
            ...track.lyricSearchQueries,
          }..removeWhere((query) => query.trim().isEmpty);
          for (final query in queries) {
            final results = await provider.search(query);
            final result = results.tracks?.firstOrNull;
            if (result?.id == null) continue;
            lyrics = await provider.getLyrics(result!.id!);
            if (lyrics.isLoaded()) break;
          }
        }
      } else if (savedChoice != null &&
          savedChoice != 'default' &&
          savedChoice != 'native') {
        final separator = savedChoice.indexOf('|');
        final providerId = separator > 0
            ? savedChoice.substring(0, separator)
            : savedChoice;
        final candidateId = separator > 0
            ? savedChoice.substring(separator + 1)
            : null;
        final lyricProvider = LyricsRegistry.instance.get(providerId);
        if (lyricProvider != null) {
          resolvedSource = providerId;
          final candidates = await lyricProvider.getLyricsCandidates(track);
          final selected = candidateId == null
              ? null
              : candidates.where((candidate) => candidate.id == candidateId)
                    .firstOrNull;
          lyrics = selected?.lyrics ?? await lyricProvider.getLyrics(track);
        }
      }

      if (lyrics?.isLoaded() != true) {
        if (nativePlatform.capabilities.supportsLyrics) {
          resolvedSource = 'platform:${nativePlatform.platformId}';
          lyrics = await _getNativeLyrics(nativePlatform, metadata);
        } else {
          final lrclib = LyricsRegistry.instance.get('lrclib');
          resolvedSource = 'lrclib';
          lyrics = lrclib == null ? null : await lrclib.getLyrics(track);
        }
      }
      if (lyrics?.isLoaded() != true) {
        _log(
          'No offline lyrics found for ${track.id} (${track.title}) '
          'using $resolvedSource',
        );
        return null;
      }
      final loadedLyrics = lyrics!;
      _log(
        'Resolved offline lyrics for ${track.id} (${track.title}) '
        'using $resolvedSource: '
        '${loadedLyrics.syncedLyrics?.length ?? 0} synced lines, '
        '${loadedLyrics.syncedLyrics?.fold<int>(0, (total, line) => total + (line.words?.length ?? 0)) ?? 0} synced words, '
        'unsynced=${loadedLyrics.unsyncedLyrics?.isNotEmpty == true}',
      );
      return LyricsFull(
        id: loadedLyrics.id,
        writers: loadedLyrics.writers,
        syncedLyrics: loadedLyrics.syncedLyrics,
        unsyncedLyrics: loadedLyrics.unsyncedLyrics,
        unsyncedTranslatedLyrics: loadedLyrics.unsyncedTranslatedLyrics,
        unsyncedRomanizedLyrics: loadedLyrics.unsyncedRomanizedLyrics,
        isExplicit: loadedLyrics.isExplicit,
        copyright: loadedLyrics.copyright,
      );
    } catch (error, stackTrace) {
      _error('Could not save selected offline lyrics: $error\n$stackTrace');
      return null;
    }
  }

  Future<Lyrics?> _getNativeLyrics(
    MusicPlatform platform,
    PlatformDownloadMetadata metadata,
  ) async {
    if (metadata.track.lyrics?.isLoaded() == true) {
      return metadata.track.lyrics;
    }
    final trackId = metadata.lyricsTrackId ?? metadata.track.id;
    if (trackId == null) return null;
    var lyrics = await platform.getLyrics(trackId);
    if (!lyrics.isLoaded() && metadata.track.fallback?.id != null) {
      lyrics = await platform.getLyrics(metadata.track.fallback!.id!);
    }
    return lyrics;
  }

  String? _savedLyricsChoice(Track track) {
    final title = (track.title ?? '').trim().toLowerCase();
    if (title.isEmpty) return null;
    final artist = (track.artistString ?? '').trim().toLowerCase();
    final choices = settings['lyricsChoices'];
    if (choices is! Map) return null;
    final primaryKey = '$title|$artist';
    final exact = choices[primaryKey];
    if (exact is String) return exact;
    for (final entry in choices.entries) {
      if (entry.key is String &&
          (entry.key as String).startsWith('$primaryKey|') &&
          entry.value is String) {
        return entry.value as String;
      }
    }
    for (final entry in choices.entries) {
      if (entry.key is String &&
          (entry.key as String).startsWith('$title|') &&
          entry.value is String) {
        return entry.value as String;
      }
    }
    return null;
  }

  int? _estimateBitrateKbps(int bytes, Duration? duration) {
    if (bytes <= 0 || duration == null || duration <= Duration.zero) {
      return null;
    }
    final kbps = (bytes * 8 / 1000 / duration.inMilliseconds * 1000).round();
    return kbps > 0 ? kbps : null;
  }

  AudioQuality _qualityFromIndex(int index) {
    if (index < 0 || index >= AudioQuality.values.length) {
      return AudioQuality.MP3_320;
    }
    final quality = AudioQuality.values[index];
    return quality == AudioQuality.ASK ? AudioQuality.MP3_320 : quality;
  }

  Future<Directory> _temporaryRoot() async {
    if (Platform.isAndroid || Platform.isIOS) {
      return await getExternalStorageDirectory() ??
          await getApplicationSupportDirectory();
    }
    return getApplicationSupportDirectory();
  }

  Future<int?> _download(
    String url,
    File outputFile, {
    Map<String, String> requestHeaders = const {},
  }) async {
    HttpClient? client;
    IOSink? sink;
    try {
      var startByte = await outputFile.exists() ? await outputFile.length() : 0;
      client = HttpClient();
      final expectedLength = await _contentLength(
        client,
        url,
        requestHeaders: requestHeaders,
      );
      final request = await client
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 20));
      requestHeaders.forEach(request.headers.set);
      if (startByte > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$startByte-');
      }
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.partialContent) {
        _error('HTTP ${response.statusCode} from stream URL');
        return null;
      }

      if (startByte > 0 && response.statusCode == HttpStatus.ok) {
        startByte = 0;
      }
      final total = response.contentLength > 0
          ? startByte + response.contentLength
          : expectedLength > 0
          ? expectedLength
          : 0;
      var received = startByte;
      sink = outputFile.openWrite(
        mode: startByte > 0 ? FileMode.append : FileMode.write,
      );
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        sink.add(chunk);
        received += chunk.length;
        _updateProgress(received, total);
        // Some progressive audio endpoints keep the response open after
        // sending the number of bytes they advertised. Once the declared
        // payload is complete, finish the file instead of waiting forever
        // for the server to close the connection.
        if (total > 0 && received >= total) {
          _log('Received the declared stream length ($received bytes)');
          break;
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
      final resolvedTotal = total > 0 ? total : received;
      _updateProgress(received, resolvedTotal);
      return received;
    } catch (error) {
      _error('HTTP download failed: $error');
      return null;
    } finally {
      await sink?.close();
      client?.close(force: true);
    }
  }

  Future<int> _contentLength(
    HttpClient client,
    String url, {
    Map<String, String> requestHeaders = const {},
  }) async {
    try {
      final request = await client
          .headUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 8));
      requestHeaders.forEach(request.headers.set);
      final response = await request.close().timeout(
        const Duration(seconds: 8),
      );
      final length = response.contentLength;
      await response.drain<void>().timeout(const Duration(seconds: 8));
      return length > 0 ? length : 0;
    } catch (_) {
      return 0;
    }
  }

  Future<void> _postProcess(
    File outputFile,
    MusicPlatform platform,
    PlatformDownloadMetadata metadata,
  ) async {
    Uint8List? coverBytes;
    if (metadata.coverUrl?.isNotEmpty == true) {
      try {
        final response = await http.get(Uri.parse(metadata.coverUrl!));
        if (response.statusCode == HttpStatus.ok) {
          coverBytes = response.bodyBytes;
        }
      } catch (error) {
        _error('Cover download failed: $error');
      }
    }

    Lyrics? lyrics;
    final enabledTags = (settings['tags'] as List<dynamic>? ?? const []);
    final needsLyrics =
        (settings['downloadLyrics'] as bool? ?? false) ||
        enabledTags.contains('lyrics');
    if (needsLyrics &&
        platform.capabilities.supportsLyrics &&
        metadata.lyricsTrackId != null) {
      try {
        lyrics = await platform.getLyrics(metadata.lyricsTrackId!);
      } catch (error) {
        _error('Lyrics download failed: $error');
      }
    }

    if ((settings['trackCover'] as bool? ?? false) && coverBytes != null) {
      await File(_sidecarPath(outputFile, 'jpg')).writeAsBytes(coverBytes);
    }
    if ((settings['albumCover'] as bool? ?? false) && coverBytes != null) {
      final albumCover = File(p.join(outputFile.parent.path, 'cover.jpg'));
      if (!await albumCover.exists()) await albumCover.writeAsBytes(coverBytes);
    }
    if (settings['nomediaFiles'] as bool? ?? false) {
      final nomedia = File(p.join(outputFile.parent.path, '.nomedia'));
      if (!await nomedia.exists()) await nomedia.create();
    }

    await _tagFile(outputFile, metadata, lyrics, coverBytes);
    // Enhanced LRC uses per-word timestamps where available. If the provider
    // only supplies ordinary synchronized lines, _generateLrc writes standard
    // line-timed LRC instead. A single timed line is still valid LRC.
    if ((settings['downloadLyrics'] as bool? ?? false) &&
        lyrics?.syncedLyrics?.isNotEmpty == true) {
      final useEnhancedLrc =
          settings['downloadEnhancedLrc'] as bool? ?? false;
      await File(
        _sidecarPath(outputFile, 'lrc'),
      ).writeAsString(
        _generateLrc(metadata, lyrics!, enhanced: useEnhancedLrc),
      );
    }
  }

  Future<void> _tagFile(
    File audioFile,
    PlatformDownloadMetadata metadata,
    Lyrics? lyrics,
    Uint8List? coverBytes,
  ) async {
    try {
      final enabled = settings['tags'] as List<dynamic>? ?? const [];
      final separator = settings['artistSeparator'] as String? ?? ', ';
      final tags = <MetadataTag>[];

      void textTag(String setting, String tag, Object? value) {
        final stringValue = value?.toString();
        if (enabled.contains(setting) && stringValue?.isNotEmpty == true) {
          tags.add(MetadataTag.text(tag, stringValue!));
        }
      }

      textTag('title', CommonTags.title, metadata.title);
      textTag('album', CommonTags.album, metadata.album);
      textTag('artist', CommonTags.artist, metadata.artists?.join(separator));
      textTag('albumArtist', CommonTags.albumArtist, metadata.albumArtist);
      textTag('track', CommonTags.track, metadata.trackNumber);
      textTag('disc', CommonTags.disc, metadata.discNumber);
      textTag('trackTotal', CommonTags.trackTotal, metadata.trackTotal);
      textTag('date', CommonTags.date, metadata.releaseDate);
      textTag('genre', CommonTags.genre, metadata.genre);
      textTag('bpm', CommonTags.bpm, metadata.bpm);
      textTag('label', CommonTags.label, metadata.label);
      textTag('isrc', CommonTags.isrc, metadata.isrc);
      textTag('upc', CommonTags.barcode, metadata.upc);
      textTag('lyrics', CommonTags.lyrics, lyrics?.unsyncedLyrics);

      if (enabled.contains('contributors')) {
        final contributors = metadata.contributors;
        textTag(
          'contributors',
          CommonTags.composer,
          contributors?.composers?.join(separator),
        );
        textTag(
          'contributors',
          CommonTags.comment,
          contributors?.engineers?.join(separator),
        );
        textTag('contributors', 'MIXER', contributors?.mixers?.join(separator));
        textTag(
          'contributors',
          'PRODUCER',
          contributors?.producers?.join(separator),
        );
        textTag(
          'contributors',
          'AUTHOR',
          contributors?.authors?.join(separator),
        );
        textTag(
          'contributors',
          'WRITER',
          contributors?.writers?.join(separator),
        );
      }
      for (final entry in metadata.extraTags.entries) {
        tags.add(MetadataTag.text(entry.key, entry.value));
      }
      if (enabled.contains('art') && coverBytes != null) {
        tags.add(MetadataTag.binary(CommonTags.albumArt, coverBytes));
      }
      if (tags.isNotEmpty) await MetaTagger().writeTags(audioFile.path, tags);
    } catch (error, stackTrace) {
      _error('Tagging failed: $error\n$stackTrace');
    }
  }

  String _generateLrc(
    PlatformDownloadMetadata metadata,
    Lyrics lyrics, {
    bool enhanced = false,
  }) {
    final output = StringBuffer();
    if (metadata.artists?.isNotEmpty == true) {
      output.writeln('[ar:${metadata.artists!.join(', ')}]');
    }
    if (metadata.album?.isNotEmpty == true) {
      output.writeln('[al:${metadata.album}]');
    }
    if (metadata.title?.isNotEmpty == true) {
      output.writeln('[ti:${metadata.title}]');
    }
    for (final line in lyrics.syncedLyrics ?? const <SynchronizedLyric>[]) {
      // Provider timestamps are not consistently LRC-formatted. NeuroKaraoke,
      // for example, supplies hh:mm:ss.fffffff; write a canonical mm:ss.hh
      // timestamp from the already-parsed offset instead of copying it raw.
      final timestamp = _formatTimestamp(line.offset) ?? line.lrcTimestamp;
      if (timestamp != null && enhanced && line.words?.isNotEmpty == true) {
        final wrapped = timestamp.startsWith('[') ? timestamp : '[$timestamp]';
        final body = StringBuffer(wrapped);
        for (final word in line.words!) {
          final wordTimestamp = _formatTimestamp(word.offset);
          if (wordTimestamp == null) continue;
          body
            ..write('<$wordTimestamp>')
            ..write(word.text);
        }
        final lastWord = line.words!.last;
        final endTimestamp = _formatTimestamp(
          lastWord.offset + lastWord.duration,
        );
        if (endTimestamp != null) body.write('<$endTimestamp>');
        output.writeln(body);
      } else if (timestamp != null && line.text != null) {
        final wrapped = timestamp.startsWith('[') ? timestamp : '[$timestamp]';
        output.writeln('$wrapped${line.text}');
      }
    }
    return output.toString();
  }

  String? _formatTimestamp(Duration? offset) {
    if (offset == null) return null;
    final minutes = offset.inMinutes.toString().padLeft(2, '0');
    final seconds = offset.inSeconds.remainder(60).toString().padLeft(2, '0');
    final hundredths = (offset.inMilliseconds.remainder(1000) ~/ 10)
        .toString()
        .padLeft(2, '0');
    return '$minutes:$seconds.$hundredths';
  }

  String _processPathTemplate(
    String template,
    PlatformDownloadMetadata metadata,
    String extension,
  ) {
    var result = template;
    final artists = metadata.artists ?? const <String>[];
    final separator = settings['artistSeparator'] as String? ?? ', ';
    final replacements = <String, String>{
      '%title%': _sanitize(metadata.title ?? ''),
      '%album%': _sanitize(metadata.album ?? ''),
      '%albumArtist%': _sanitize(metadata.albumArtist ?? ''),
      '%artists%': _sanitize(artists.join(separator)),
      '%artist%': _sanitize(artists.isEmpty ? '' : artists.first),
      '%trackNumber%': (metadata.trackNumber ?? 1).toString(),
      '%0trackNumber%': (metadata.trackNumber ?? 1).toString().padLeft(2, '0'),
      '%date%': metadata.releaseDate ?? '',
      '%year%': metadata.releaseDate?.split('-').first ?? '',
    };
    for (final entry in replacements.entries) {
      result = result.replaceAll(entry.key, entry.value);
    }
    result = result
        .replaceAll(RegExp(r'/\.+'), '/')
        .replaceAll(RegExp(r'\\\.+'), '\\');
    final currentExtension = p.extension(result).toLowerCase();
    const audioExtensions = {'.mp3', '.flac', '.ogg', '.opus', '.m4a', '.aac'};
    if (!audioExtensions.contains(currentExtension)) {
      result = '$result.$extension';
    }
    return result;
  }

  String _extensionFor(PlatformDownloadMetadata metadata, String streamFormat) {
    final provided = metadata.fileExtension
        ?.replaceFirst('.', '')
        .toLowerCase();
    if (provided?.isNotEmpty == true) return provided!;
    final normalized = streamFormat.toLowerCase();
    if (normalized == 'mpeg') return 'mp3';
    return normalized.isEmpty ? 'mp3' : normalized;
  }

  String _sidecarPath(File audioFile, String extension) =>
      p.setExtension(audioFile.path, '.$extension');

  String _sanitize(String input) => input
      .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}
