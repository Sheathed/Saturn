import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';

class DownloadLog {
  IOSink? _writer;
  File? _logFile;
  bool _isWriting = false;
  final List<String> _writeQueue = [];

  /// Open/Create file
  Future<void> open() async {
    try {
      Directory? directory = await getApplicationSupportDirectory();

      _logFile = File('${directory.path}/download.log');

      if (!await _logFile!.exists()) {
        await _logFile!.create();
      }

      _writer = _logFile!.openWrite(mode: FileMode.append);
    } catch (e) {
      debugPrint('Error opening download log: $e');
    }
  }

  /// Close log
  Future<void> close() async {
    try {
      await _writer?.close();
    } catch (e) {
      debugPrint('Error closing download log: $e');
    }
  }

  String _time() {
    final format = DateFormat('yyyy.MM.dd HH:mm:ss');
    return format.format(DateTime.now());
  }

  /// Write error to log
  void error(String info, [DownloadInfo? download]) {
    if (_writer == null) return;

    String data;
    if (download != null) {
      data =
          'E:${_time()} (TrackID: ${download.trackId}, ID: ${download.id}): $info';
    } else {
      data = 'E:${_time()}: $info';
    }

    _queueWrite(data);
    debugPrint('ERROR: $data');
  }

  /// Write warning to log
  void warn(String info, [DownloadInfo? download]) {
    if (_writer == null) return;

    String data;
    if (download != null) {
      data =
          'W:${_time()} (TrackID: ${download.trackId}, ID: ${download.id}): $info';
    } else {
      data = 'W:${_time()}: $info';
    }

    _queueWrite(data);
    debugPrint('WARN: $data');
  }

  /// Write info to log
  void log(String info) {
    if (_writer == null) return;

    final data = 'I:${_time()}: $info';

    _queueWrite(data);
    debugPrint('INFO: $data');
  }

  /// Queue a write operation to prevent concurrent access
  void _queueWrite(String data) {
    _writeQueue.add(data);
    _processQueue();
  }

  /// Process the write queue sequentially
  Future<void> _processQueue() async {
    if (_isWriting || _writeQueue.isEmpty || _writer == null) return;

    _isWriting = true;

    while (_writeQueue.isNotEmpty) {
      final data = _writeQueue.removeAt(0);
      try {
        _writer!.writeln(data);
        await _writer!.flush();
      } catch (e) {
        debugPrint('Error writing into log: $e');
      }
    }

    _isWriting = false;
  }
}

/// Minimal download info for logging
class DownloadInfo {
  final String trackId;
  final int id;

  DownloadInfo({required this.trackId, required this.id});
}
