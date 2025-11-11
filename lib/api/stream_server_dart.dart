import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:saturn/service/audio_service.dart';
import 'package:saturn/settings.dart';
import '../api/deezer.dart';
import '../api/deezer_decryptor.dart';
import '../api/download_log.dart';

/// Dart-based stream server to replace Java implementation
class StreamServerDart {
  static final StreamServerDart instance = StreamServerDart();

  HttpServer? _server;
  String? _offlinePath;
  DeezerAPI? _deezer;
  DownloadLog? _logger;
  bool _authorized = false;

  final Map<String, StreamInfo> streams = {};
  final List<String> _streamHistory = []; // Track order for LRU
  static const int _maxStreams = 5; // Keep last 5 streams

  Future<void> start(String arl) async {
    if (_server != null) {
      return;
    }

    Directory? directory;
    if (Platform.isAndroid || Platform.isIOS) {
      directory = await getExternalStorageDirectory();
    } else {
      directory = await getApplicationSupportDirectory();
    }

    _offlinePath = p.join(directory!.path, 'offline/');
    _logger = DownloadLog();
    await _logger!.open();

    _deezer = DeezerAPI(arl: arl);

    try {
      _server = await HttpServer.bind('127.0.0.1', 10069);
      _logger!.log('Stream server started on 127.0.0.1:10069');

      _server!.listen(
        _handleRequest,
        onError: (error) {
          _logger?.log('Stream server error: $error');
        },
      );
    } catch (e, st) {
      _logger?.log('Error starting stream server: $e\n$st');
      rethrow;
    }
  }

  /// Stop the server
  Future<void> stop() async {
    if (_server != null) {
      _logger?.log('Stopping stream server');
      await _server?.close(force: true);
      _server = null;
    }
    await _logger?.close();
    _logger = null;
  }

  /// Handle incoming HTTP requests
  Future<void> _handleRequest(HttpRequest request) async {
    if (request.method != 'GET') {
      request.response
        ..statusCode = HttpStatus.methodNotAllowed
        ..write('Only GET request supported!')
        ..close();
      return;
    }

    try {
      final uri = request.uri;

      // Check if offline stream
      if (uri.queryParameters.containsKey('id') &&
          uri.queryParameters.length < 6) {
        await _handleOfflineStream(request);
      } else if (uri.queryParameters.length >= 6) {
        await _handleDeezerStream(request);
      } else {
        request.response
          ..statusCode = HttpStatus.badRequest
          ..write('Invalid / Missing query parameters')
          ..close();
      }
    } catch (e) {
      request.response
        ..statusCode = HttpStatus.internalServerError
        ..write('An error occurred while serving the request.')
        ..close();
    }
  }

  /// Handle offline file streaming
  Future<void> _handleOfflineStream(HttpRequest request) async {
    final trackId = request.uri.queryParameters['id'];
    if (trackId == null) {
      request.response
        ..statusCode = HttpStatus.badRequest
        ..write('Missing track ID')
        ..close();
      return;
    }

    final file = File(p.join(_offlinePath!, trackId));
    if (!await file.exists()) {
      request.response
        ..statusCode = HttpStatus.notFound
        ..write('File not found')
        ..close();
      return;
    }

    final size = await file.length();

    // Check if FLAC
    bool isFlac = false;
    final header = await file.openRead(0, 4).first;
    if (String.fromCharCodes(header) == 'fLaC') {
      isFlac = true;
    }

    // Parse range header
    final rangeHeader = request.headers.value('range');
    int startBytes = 0;
    int? endBytes;
    bool isRanged = false;

    if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
      isRanged = true;
      final ranges = rangeHeader.substring(6).split('-');
      startBytes = int.parse(ranges[0]);
      if (ranges.length > 1 && ranges[1].isNotEmpty) {
        endBytes = int.parse(ranges[1]);
      }
    }

    final contentLength = (endBytes ?? size - 1) - startBytes + 1;

    // Set response headers
    request.response
      ..statusCode = isRanged ? HttpStatus.partialContent : HttpStatus.ok
      ..headers.contentType = ContentType('audio', isFlac ? 'flac' : 'mpeg')
      ..headers.set('Accept-Ranges', 'bytes')
      ..headers.contentLength = contentLength;

    if (isRanged) {
      request.response.headers.set(
        'Content-Range',
        'bytes $startBytes-${endBytes ?? size - 1}/$size',
      );
    }

    // Save stream info with LRU cache
    _addStreamInfo(
      trackId,
      StreamInfo(
        format: isFlac ? 'FLAC' : 'MP3',
        size: size,
        source: 'Offline',
      ),
    );

    // Stream file and clean up when done
    try {
      await file
          .openRead(startBytes, endBytes != null ? endBytes + 1 : null)
          .pipe(request.response);
    } finally {
      // Keep stream info for quality display - don't remove
      _logger?.log('Offline stream closed for track: $trackId');
    }
  }

  /// Get requested stream quality based on connection and settings.
  Future<int> getStreamQuality() async {
    int quality = settings.getQualityInt(settings.mobileQuality);
    List<ConnectivityResult> conn = await Connectivity().checkConnectivity();
    if (conn.contains(ConnectivityResult.wifi) ||
        conn.contains(ConnectivityResult.ethernet)) {
      quality = settings.getQualityInt(settings.wifiQuality);
    }
    return quality;
  }

  /// Handle Deezer stream
  Future<void> _handleDeezerStream(HttpRequest request) async {
    final params = request.uri.queryParameters;
    final trackId = params['id'] ?? '';

    // Authorize if needed
    if (!_authorized) {
      await _deezer!.authorize();
      _authorized = true;
    }

    final quality = await getStreamQuality();

    final streamTrackId = params['streamTrackId'] ?? '';
    final trackToken = params['trackToken'] ?? '';
    final md5origin = params['md5origin'] ?? '';
    final mediaVersion = params['mv'] ?? '';

    // Get track URL from Deezer CDN
    final url = await _getTrackUrl(
      streamTrackId,
      trackToken,
      md5origin,
      mediaVersion,
      quality,
    );

    if (url == null) {
      _logger?.log('ERROR: Failed to get track URL');
      await GetIt.I<AudioPlayerHandler>().skipToNext();
      request.response
        ..statusCode = HttpStatus.notFound
        ..write('Track not available')
        ..close();
      return;
    }

    // Parse range header
    final rangeHeader = request.headers.value('range');
    int startBytes = 0;
    int? endBytes;
    bool isRanged = false;

    if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
      isRanged = true;
      final ranges = rangeHeader.substring(6).split('-');
      startBytes = int.parse(ranges[0]);
      if (ranges.length > 1 && ranges[1].isNotEmpty) {
        endBytes = int.parse(ranges[1]);
      }
    }

    // All Deezer URLs are encrypted with BF_CBC_STRIPE
    const encrypted = true;
    int deezerStart = startBytes;
    if (encrypted) {
      deezerStart = startBytes - (startBytes % 2048);
    }
    final dropBytes = startBytes % 2048;

    // Make request to Deezer
    final client = HttpClient();
    try {
      final deezerRequest = await client.getUrl(Uri.parse(url));
      deezerRequest.headers.set(
        'User-Agent',
        'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/79.0.3945.130 Safari/537.36',
      );
      deezerRequest.headers.set(
        'Range',
        'bytes=$deezerStart-${endBytes ?? ""}',
      );

      final deezerResponse = await deezerRequest.close();

      if (deezerResponse.statusCode != HttpStatus.ok &&
          deezerResponse.statusCode != HttpStatus.partialContent) {
        _logger?.log(
          'ERROR: Deezer returned non-success status: ${deezerResponse.statusCode}',
        );
        request.response
          ..statusCode = deezerResponse.statusCode
          ..write('Deezer CDN error')
          ..close();
        return;
      }

      // Set response headers
      request.response
        ..statusCode = isRanged ? HttpStatus.partialContent : HttpStatus.ok
        ..headers.contentType = ContentType(
          'audio',
          quality == 9 ? 'flac' : 'mpeg',
        )
        ..headers.set('Accept-Ranges', 'bytes');

      if (isRanged) {
        final contentLength = deezerResponse.contentLength;
        request.response.headers.set(
          'Content-Range',
          'bytes $startBytes-${endBytes ?? (contentLength + deezerStart - 1)}/${contentLength + deezerStart}',
        );
      }

      // user-uploaded MP3s have negative streamTrackId so it has to be an MP3
      String format;
      if (streamTrackId.startsWith('-')) {
        format = 'MP3';
      } else {
        format = quality == 9 ? 'FLAC' : 'MP3';
      }

      // Save stream info with LRU cache
      _addStreamInfo(
        trackId,
        StreamInfo(
          format: format,
          size: deezerResponse.contentLength + deezerStart,
          source: 'Stream',
        ),
      );

      // Stream with decryption
      try {
        await _streamWithDecryption(
          deezerResponse,
          request.response,
          streamTrackId,
          deezerStart,
          dropBytes,
        );
      } catch (e, st) {
        _logger?.log('ERROR during streaming: $e\n$st');
        rethrow;
      }
    } catch (e, st) {
      _logger?.log('ERROR in _handleDeezerStream: $e\n$st');
      request.response
        ..statusCode = HttpStatus.internalServerError
        ..write('Stream error: $e')
        ..close();
    }
  }

  /// Stream with decryption - matches Java FilterInputStream implementation
  Future<void> _streamWithDecryption(
    HttpClientResponse input,
    HttpResponse output,
    String trackId,
    int deezerStart,
    int dropBytes,
  ) async {
    final key = DeezerDecryptor.getKey(trackId);
    int counter = deezerStart ~/ 2048;
    int drop = dropBytes;
    final inputBuffer = <int>[];

    // Create a flag to indicate if the client is still connected
    bool clientConnected = true;

    // When output.done completes, set clientConnected to false
    output.done.then((_) {
      clientConnected = false;
    });

    try {
      await for (var chunk in input) {
        if (!clientConnected) break;
        inputBuffer.addAll(chunk);

        // Process complete 2048-byte blocks
        while (inputBuffer.length >= 2048) {
          if (!clientConnected) break;
          final buffer = inputBuffer.sublist(0, 2048);
          inputBuffer.removeRange(0, 2048);

          List<int> decrypted;
          if ((counter % 3) == 0) {
            decrypted = DeezerDecryptor.decryptChunk(key, buffer);
          } else {
            decrypted = buffer;
          }

          if (drop > 0) {
            final outputBlock = decrypted.sublist(drop, 2048);
            drop = 0;
            counter++;
            try {
              output.add(outputBlock);
            } catch (_) {
              clientConnected = false;
              break;
            }
            continue;
          }

          try {
            output.add(decrypted);
          } catch (_) {
            clientConnected = false;
            break;
          }
          counter++;
        }
        if (!clientConnected) break;
      }

      if (inputBuffer.isNotEmpty && clientConnected) {
        try {
          output.add(inputBuffer);
        } catch (_) {
          // Ignore errors if output is already closed
        }
      }
    } catch (e) {
      // Ignore errors if output is already closed (skip/stop)
    } finally {
      try {
        await output.close();
      } catch (_) {
        // Ignore errors if already closed
      }
    }
  }

  /// Fetch fresh track token from Deezer API
  Future<String?> _getFreshTrackToken(String trackId) async {
    try {
      Map<dynamic, dynamic> data = await _deezer!.callGwApi(
        'song.getListData',
        params: {
          'sng_ids': [trackId],
        },
      );

      if (data['results']?['data'] != null &&
          (data['results']['data'] as List).isNotEmpty) {
        final trackData = data['results']['data'][0];
        final freshToken = trackData['TRACK_TOKEN'];
        return freshToken;
      }

      _logger?.log('No track data returned for trackId: $trackId');
      return null;
    } catch (e, st) {
      _logger?.log('Error fetching fresh track token: $e\n$st');
      return null;
    }
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
      if (_deezer?.licenseToken != null &&
          _deezer?.licenseToken!.isNotEmpty == true) {
        var url = await _getTrackUrlFromAPI(trackId, trackToken, quality);
        if (url == null) {
          final freshToken = await _getFreshTrackToken(trackId);
          if (freshToken != null && freshToken.isNotEmpty) {
            url = await _getTrackUrlFromAPI(trackId, freshToken, quality);
          }
        }

        if (url != null && url.isNotEmpty) {
          return url;
        }
      } else {
        _logger?.log(
          'No license token available (licenseToken: ${_deezer?.licenseToken})',
        );
      }
      return null;
    } catch (e, st) {
      _logger?.log('Error getting track URL: $e\n$st');
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
                return url;
              } else {
                _logger?.log('No sources in media item');
              }
            } else {
              _logger?.log('No media in data item');
            }
          }
          _logger?.log('No valid URL found in API response data');
        } else {
          _logger?.log('API response has no data field');
        }
      } else {
        _logger?.log(
          'API returned status ${response.statusCode}: ${response.body}',
        );
      }
    } catch (e, st) {
      _logger?.log('Error getting track URL from API: $e\n$st');
    }
    return null;
  }

  void _addStreamInfo(String trackId, StreamInfo info) {
    streams[trackId] = info;
    _streamHistory.remove(trackId); // Remove if exists
    _streamHistory.add(trackId); // Add to end (most recent)

    while (_streamHistory.length > _maxStreams) {
      final oldest = _streamHistory.removeAt(0);
      streams.remove(oldest);
    }
  }

  Map<String, dynamic>? getStreamInfo(String id) {
    return streams[id]?.toJson();
  }
}

/// Stream information
class StreamInfo {
  final String format;
  final int size;
  final String source;

  StreamInfo({required this.format, required this.size, required this.source});

  Map<String, dynamic> toJson() {
    return {'format': format, 'size': size, 'source': source};
  }
}
