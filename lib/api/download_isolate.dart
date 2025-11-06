import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'deezer_decryptor.dart';

/// Message types for isolate communication
class DownloadIsolateMessage {
  final String type;
  final Map<String, dynamic> data;
  final SendPort? responsePort;

  DownloadIsolateMessage({
    required this.type,
    required this.data,
    this.responsePort,
  });
}

/// Response from isolate
class DownloadIsolateResponse {
  final bool success;
  final String? error;
  final Map<String, dynamic>? data;

  DownloadIsolateResponse({
    required this.success,
    this.error,
    this.data,
  });
}

/// Isolate entry point for download operations
Future<void> downloadIsolateEntryPoint(SendPort mainSendPort) async {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);

  await for (var message in receivePort) {
    if (message is DownloadIsolateMessage) {
      DownloadIsolateResponse response;

      try {
        switch (message.type) {
          case 'download':
            response = await _handleDownload(message.data);
            break;
          case 'decrypt':
            response = await _handleDecrypt(message.data);
            break;
          case 'move':
            response = await _handleMove(message.data);
            break;
          case 'stop':
            receivePort.close();
            return;
          default:
            response = DownloadIsolateResponse(
              success: false,
              error: 'Unknown message type: ${message.type}',
            );
        }
      } catch (e) {
        response = DownloadIsolateResponse(
          success: false,
          error: e.toString(),
        );
      }

      message.responsePort?.send(response);
    }
  }
}

/// Handle file download in isolate
Future<DownloadIsolateResponse> _handleDownload(
  Map<String, dynamic> data,
) async {
  try {
    final url = data['url'] as String;
    final outputPath = data['outputPath'] as String;
    final progressPort = data['progressPort'] as SendPort?;

    final outputFile = File(outputPath);
    await outputFile.parent.create(recursive: true);

    final request = await HttpClient().getUrl(Uri.parse(url));
    final response = await request.close();

    final contentLength = response.contentLength;
    int received = 0;

    final sink = outputFile.openWrite();

    await for (var chunk in response) {
      sink.add(chunk);
      received += chunk.length;

      // Send progress updates
      progressPort?.send({
        'received': received,
        'total': contentLength,
      });
    }

    await sink.close();

    return DownloadIsolateResponse(
      success: true,
      data: {
        'filesize': contentLength,
        'path': outputPath,
      },
    );
  } catch (e) {
    return DownloadIsolateResponse(
      success: false,
      error: 'Download failed: $e',
    );
  }
}

/// Handle file decryption in isolate
Future<DownloadIsolateResponse> _handleDecrypt(
  Map<String, dynamic> data,
) async {
  try {
    final trackId = data['trackId'] as String;
    final inputPath = data['inputPath'] as String;
    final outputPath = data['outputPath'] as String;

    await DeezerDecryptor.decryptFile(trackId, inputPath, outputPath);

    return DownloadIsolateResponse(
      success: true,
      data: {'path': outputPath},
    );
  } catch (e) {
    return DownloadIsolateResponse(
      success: false,
      error: 'Decryption failed: $e',
    );
  }
}

/// Handle file move/copy in isolate
Future<DownloadIsolateResponse> _handleMove(Map<String, dynamic> data) async {
  try {
    final sourcePath = data['sourcePath'] as String;
    final destPath = data['destPath'] as String;
    final deleteSource = data['deleteSource'] as bool? ?? true;

    final sourceFile = File(sourcePath);
    final destFile = File(destPath);

    await destFile.parent.create(recursive: true);
    await sourceFile.copy(destPath);

    if (deleteSource) {
      await sourceFile.delete();
    }

    return DownloadIsolateResponse(
      success: true,
      data: {'path': destPath},
    );
  } catch (e) {
    return DownloadIsolateResponse(
      success: false,
      error: 'Move failed: $e',
    );
  }
}

/// Manager for download isolates
class DownloadIsolateManager {
  Isolate? _isolate;
  SendPort? _isolateSendPort;
  final ReceivePort _receivePort = ReceivePort();
  final Completer<void> _readyCompleter = Completer<void>();

  bool get isReady => _readyCompleter.isCompleted;

  /// Start the isolate
  Future<void> start() async {
    if (_isolate != null) return;

    _isolate = await Isolate.spawn(
      downloadIsolateEntryPoint,
      _receivePort.sendPort,
    );

    // Wait for isolate to send back its SendPort
    _isolateSendPort = await _receivePort.first as SendPort;
    _readyCompleter.complete();
  }

  /// Stop the isolate
  Future<void> stop() async {
    if (_isolate == null) return;

    _isolateSendPort?.send(DownloadIsolateMessage(
      type: 'stop',
      data: {},
    ));

    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _isolateSendPort = null;
    _receivePort.close();
  }

  /// Send a message to the isolate and wait for response
  Future<DownloadIsolateResponse> sendMessage(
    String type,
    Map<String, dynamic> data,
  ) async {
    if (!isReady) {
      await _readyCompleter.future;
    }

    final responsePort = ReceivePort();
    final message = DownloadIsolateMessage(
      type: type,
      data: data,
      responsePort: responsePort.sendPort,
    );

    _isolateSendPort!.send(message);

    final response = await responsePort.first as DownloadIsolateResponse;
    responsePort.close();

    return response;
  }

  /// Download a file in the isolate
  Future<DownloadIsolateResponse> downloadFile(
    String url,
    String outputPath, {
    Function(int received, int total)? onProgress,
    Duration timeout = const Duration(minutes: 10),
  }) async {
    SendPort? progressPort;
    ReceivePort? progressReceivePort;

    if (onProgress != null) {
      progressReceivePort = ReceivePort();
      progressPort = progressReceivePort.sendPort;

      progressReceivePort.listen((data) {
        if (data is Map<String, dynamic>) {
          onProgress(data['received'] as int, data['total'] as int);
        }
      });
    }

    try {
      final response = await sendMessage('download', {
        'url': url,
        'outputPath': outputPath,
        'progressPort': progressPort,
      }).timeout(
        timeout,
        onTimeout: () => DownloadIsolateResponse(
          success: false,
          error: 'Download timed out after ${timeout.inMinutes} minutes',
        ),
      );

      progressReceivePort?.close();
      return response;
    } catch (e) {
      progressReceivePort?.close();
      return DownloadIsolateResponse(
        success: false,
        error: 'Download failed: $e',
      );
    }
  }

  /// Decrypt a file in the isolate
  Future<DownloadIsolateResponse> decryptFile(
    String trackId,
    String inputPath,
    String outputPath, {
    Duration timeout = const Duration(minutes: 5),
  }) async {
    try {
      return await sendMessage('decrypt', {
        'trackId': trackId,
        'inputPath': inputPath,
        'outputPath': outputPath,
      }).timeout(
        timeout,
        onTimeout: () => DownloadIsolateResponse(
          success: false,
          error: 'Decryption timed out after ${timeout.inMinutes} minutes',
        ),
      );
    } catch (e) {
      return DownloadIsolateResponse(
        success: false,
        error: 'Decryption failed: $e',
      );
    }
  }

  /// Move/copy a file in the isolate
  Future<DownloadIsolateResponse> moveFile(
    String sourcePath,
    String destPath, {
    bool deleteSource = true,
    Duration timeout = const Duration(minutes: 2),
  }) async {
    try {
      return await sendMessage('move', {
        'sourcePath': sourcePath,
        'destPath': destPath,
        'deleteSource': deleteSource,
      }).timeout(
        timeout,
        onTimeout: () => DownloadIsolateResponse(
          success: false,
          error: 'File move timed out after ${timeout.inMinutes} minutes',
        ),
      );
    } catch (e) {
      return DownloadIsolateResponse(
        success: false,
        error: 'File move failed: $e',
      );
    }
  }
}
