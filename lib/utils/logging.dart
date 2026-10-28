import 'app_config.dart';
import 'dart:async';
import 'dart:collection';
import 'dart:developer';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final Logger appLogger = () {
  _ensureLoggingConfigured();
  return Logger('Saturn');
}();

LogQueueManager? _globalLogQueueManager;
bool _loggingConfigured = false;

void _ensureLoggingConfigured() {
  if (_loggingConfigured) return;
  _loggingConfigured = true;
  hierarchicalLoggingEnabled = true;
  Logger.root.level = Level.ALL;

  Logger.root.onRecord.listen((record) {
    final logMessage = _formatLogMessage(record);
    // ignore: avoid_print
    print(logMessage.trimRight());
    _globalLogQueueManager?.enqueue(logMessage);
  });
}

class LogQueueManager {
  final File logFile;
  final Queue<String> _logQueue = Queue<String>();
  bool _isWriting = false;

  LogQueueManager(this.logFile);

  void enqueue(String logEntry) {
    _logQueue.add(logEntry);
    _processQueue();
  }

  Future<void> _processQueue() async {
    if (_isWriting) return;
    _isWriting = true;

    while (_logQueue.isNotEmpty) {
      String logEntry = _logQueue.removeFirst();
      log(logEntry.trimRight(), name: 'Saturn');
      try {
        await logFile.writeAsString(logEntry, mode: FileMode.append);
      } catch (e) {
        debugPrint('Error writing to log file: $e');
        log('Error writing to log file: $e');
      }
    }

    _isWriting = false;
  }
}

Future<void> initializeLogging() async {
  _ensureLoggingConfigured();

  final String path = p.join(
    (await getFlavorSupportDirectory()).path,
    'saturn.log',
  );
  final File logFile = File(path);

  if (!await logFile.exists()) {
    await logFile.create(recursive: true);
  }

  // Clear old session data
  await logFile.writeAsString('');

  _globalLogQueueManager = LogQueueManager(logFile);
}

String _formatLogMessage(LogRecord record) {
  final buffer = StringBuffer();
  buffer.write('${record.level.name}: ${record.time}: ${record.message}\n');

  if (record.error != null) {
    buffer.write('Error: ${record.error}\n');
  }

  if (record.stackTrace != null) {
    buffer.write('Stack Trace: ${record.stackTrace}\n');
  }

  return buffer.toString();
}
