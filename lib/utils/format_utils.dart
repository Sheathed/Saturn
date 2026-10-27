import 'dart:io';
import 'package:logging/logging.dart';

class FormatUtils {
  static final Logger _logger = Logger('FormatUtils');

  static bool _containsBytes(List<int> data, List<int> pattern) {
    if (data.length < pattern.length) return false;
    for (var start = 0; start <= data.length - pattern.length; start++) {
      var matches = true;
      for (var offset = 0; offset < pattern.length; offset++) {
        if (data[start + offset] != pattern[offset]) {
          matches = false;
          break;
        }
      }
      if (matches) return true;
    }
    return false;
  }

  /// Estimate bitrate from media size without requesting or decoding audio.
  /// Providers with encrypted streams can use the upstream content length
  /// because encryption does not change the byte count.
  static Future<int?> resolveBitrateFromHeaders(
    String streamUrl, {
    required int? durationSeconds,
    Map<String, String> headers = const {},
  }) async {
    if (durationSeconds == null || durationSeconds <= 0) return null;
    final uri = Uri.tryParse(streamUrl);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4);
    try {
      int? length;

      // 1. Try GET with range bytes=0-0 first (supported by audio CDNs)
      try {
        final response = await _request(
          client,
          uri,
          'GET',
          headers,
          range: 'bytes=0-0',
        );
        if (response.statusCode == HttpStatus.partialContent ||
            response.statusCode == HttpStatus.ok) {
          length = _totalLength(response);
        }
        await response.drain().catchError((_) {});
      } catch (_) {}

      // 2. Fall back to HEAD request if range GET did not provide length
      if (length == null || length <= 0) {
        try {
          final response = await _request(client, uri, 'HEAD', headers);
          if (response.statusCode == HttpStatus.ok) {
            length = _totalLength(response);
          }
          await response.drain().catchError((_) {});
        } catch (_) {}
      }

      if (length == null || length <= 0) return null;
      final rawBitrate = ((length * 8) / 1000 / durationSeconds).round();
      if (rawBitrate <= 0) return null;
      return rawBitrate;
    } catch (error) {
      _logger.fine('Could not resolve bitrate from response headers: $error');
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static Future<HttpClientResponse> _request(
    HttpClient client,
    Uri uri,
    String method,
    Map<String, String> headers, {
    String? range,
  }) async {
    final request = await client.openUrl(method, uri).timeout(
      const Duration(seconds: 5),
    );
    for (final entry in headers.entries) {
      request.headers.set(entry.key, entry.value);
    }
    if (!headers.containsKey('User-Agent') &&
        !headers.containsKey('user-agent')) {
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      );
    }
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    return request.close().timeout(const Duration(seconds: 5));
  }

  static int? _totalLength(HttpClientResponse response) {
    final contentRange = response.headers.value(HttpHeaders.contentRangeHeader);
    if (contentRange != null) {
      final slash = contentRange.lastIndexOf('/');
      if (slash >= 0) {
        final totalStr = contentRange.substring(slash + 1).trim();
        final parsed = int.tryParse(totalStr);
        if (parsed != null && parsed > 0) return parsed;
      }
    }
    return response.contentLength > 0 ? response.contentLength : null;
  }

  static Future<Map<String, dynamic>> resolveStreamInfo(
    String streamUrl, {
    int? durationSeconds,
    Map<String, String> headers = const {},
  }) async {
    String streamFormat = 'MP3';
    bool formatDetected = false;
    int streamBitrate = 0;
    int contentLength = 0;
    int? statusCode;

    try {
      final buffer = <int>[];

      if (streamUrl.startsWith('http')) {
        final client = HttpClient();
        try {
          final request = await client
              .getUrl(Uri.parse(streamUrl))
              .timeout(const Duration(seconds: 5));
          for (final entry in headers.entries) {
            request.headers.set(entry.key, entry.value);
          }
          if (!headers.containsKey('User-Agent') &&
              !headers.containsKey('user-agent')) {
            request.headers.set(
              HttpHeaders.userAgentHeader,
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            );
          }
          request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-8192');
          final response = await request
              .close()
              .timeout(const Duration(seconds: 5));
          statusCode = response.statusCode;

          if (response.statusCode == 200 || response.statusCode == 206) {
            if (response.statusCode == 206) {
              final contentRange = response.headers.value('content-range');
              if (contentRange != null && contentRange.contains('/')) {
                contentLength = int.tryParse(contentRange.split('/').last) ?? 0;
              }
            } else {
              contentLength = response.contentLength;
            }

            await for (final chunk in response.timeout(
              const Duration(seconds: 5),
            )) {
              final remaining = 64 - buffer.length;
              if (remaining > 0) buffer.addAll(chunk.take(remaining));
              if (buffer.length >= 64) break;
            }
            final contentType =
                response.headers.contentType?.toString().toLowerCase() ?? '';
            if (contentType.contains('flac')) {
              streamFormat = 'FLAC';
              formatDetected = true;
            } else if (contentType.contains('mpeg') ||
                contentType.contains('mp3')) {
              streamFormat = 'MP3';
              formatDetected = true;
            } else if (contentType.contains('ogg')) {
              streamFormat = 'OGG';
              formatDetected = true;
            } else if (contentType.contains('mp4')) {
              streamFormat = 'AAC';
              formatDetected = true;
            }
          }
        } finally {
          // Failed probes used to leave a live HttpClient behind. A series of
          // skips on mobile data could accumulate idle sockets in the proxy.
          client.close(force: true);
        }
      } else {
        // Handle local file
        final uri = Uri.parse(streamUrl);
        final file = File.fromUri(uri);
        if (await file.exists()) {
          contentLength = await file.length();
          final stream = file.openRead(0, 64);
          await for (var chunk in stream) {
            buffer.addAll(chunk);
          }
        }
      }

      if (buffer.length >= 4) {
        if (buffer[0] == 0x66 &&
            buffer[1] == 0x4C &&
            buffer[2] == 0x61 &&
            buffer[3] == 0x43) {
          streamFormat = 'FLAC';
          formatDetected = true;
        } else if (buffer[0] == 0x4F &&
            buffer[1] == 0x67 &&
            buffer[2] == 0x67 &&
            buffer[3] == 0x53) {
          streamFormat = _containsBytes(buffer, const [
            0x4F,
            0x70,
            0x75,
            0x73,
            0x48,
            0x65,
            0x61,
            0x64,
          ])
              ? 'OPUS'
              : 'OGG';
          formatDetected = true;
        } else if (buffer[0] == 0x52 &&
            buffer[1] == 0x49 &&
            buffer[2] == 0x46 &&
            buffer[3] == 0x46) {
          streamFormat = 'WAV';
          formatDetected = true;
        } else if (buffer[0] == 0x49 &&
            buffer[1] == 0x44 &&
            buffer[2] == 0x33) {
          streamFormat = 'MP3';
          formatDetected = true;
        } else if (buffer[0] == 0x1A &&
            buffer[1] == 0x45 &&
            buffer[2] == 0xDF &&
            buffer[3] == 0xA3) {
          // WebM audio downloads (including YouTube Music Opus) use the EBML
          // container signature rather than an audio codec sync/header.
          streamFormat = 'WEBM';
          formatDetected = true;
        } else if (buffer.length >= 8 &&
            buffer[4] == 0x66 &&
            buffer[5] == 0x74 &&
            buffer[6] == 0x79 &&
            buffer[7] == 0x70) {
          streamFormat = 'AAC';
          formatDetected = true;
        } else if (buffer[0] == 0xFF && (buffer[1] & 0xE0) == 0xE0) {
          streamFormat = 'MP3';
          formatDetected = true;
        }
      }

      if (contentLength > 0 && durationSeconds != null && durationSeconds > 0) {
        int calcBitrate = (((contentLength * 8) / 1000) / durationSeconds)
            .round();
        if (streamFormat != 'FLAC') {
          if (calcBitrate > 58 && calcBitrate < 70) {
            streamBitrate = 64;
          } else if (calcBitrate > 90 && calcBitrate < 102) {
            streamBitrate = 96;
          } else if (calcBitrate > 120 && calcBitrate < 136) {
            streamBitrate = 128;
          } else if (calcBitrate > 154 && calcBitrate < 170) {
            streamBitrate = 160;
          } else if (calcBitrate > 185 && calcBitrate < 198) {
            streamBitrate = 192;
          } else if (calcBitrate > 245 && calcBitrate < 265) {
            streamBitrate = 256;
          } else if (calcBitrate > 310 && calcBitrate < 330) {
            streamBitrate = 320;
          } else {
            streamBitrate = calcBitrate;
          }
        } else {
          streamBitrate = calcBitrate;
        }
      }
    } catch (e) {
      _logger.warning('Failed to resolve stream info', e);
    }

    return {
      'format': streamFormat,
      'formatDetected': formatDetected,
      'bitrate': streamBitrate,
      'contentLength': contentLength,
      'statusCode': statusCode,
    };
  }
}
