import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:audio_service/audio_service.dart';
import 'package:path_provider/path_provider.dart';
import '../api/download_log.dart';
import '../api/definitions.dart';
import '../settings.dart';
import '../utils/mediaitem_converter.dart';
import 'platform_registry.dart';
import 'music_platform.dart';
import 'stream_provider.dart';
import '../utils/format_utils.dart';

/// Shared loopback media proxy for every registered streaming platform.
class StreamProxyServer {
  static final StreamProxyServer instance = StreamProxyServer();

  HttpServer? _server;
  int? _remotePort;
  DownloadLog? _logger;
  Future<void>? _startRequest;
  Future<void>? _persistRequest;
  Timer? _persistTimer;
  File? _stateFile;
  final Map<String, MediaItem> _registeredItems = {};
  final Map<String, ({MusicPlatform platform, StreamProvider provider})>
  _streamProviders = {};
  final Map<String, Future<StreamResponse>> _resolvedStreams = {};
  final Map<String, Future<StreamResponse?>> _precacheRequests = {};
  final Map<String, Future<StreamResponse?>> _metadataRequests = {};
  Future<void>? _audioPrefetch;
  String? _audioPrefetchKey;
  HttpClient? _audioPrefetchClient;
  _CachedAudio? _cachedAudio;
  final StreamController<({String platformId, String trackId, String message})>
  _unavailableEvents = StreamController.broadcast();

  Stream<({String platformId, String trackId, String message})>
  get unavailableEvents => _unavailableEvents.stream;

  int? get port => _server?.port ?? _remotePort;
  Uri get baseUri {
    final boundPort = port;
    if (boundPort == null) throw StateError('Stream proxy is not running');
    return Uri(scheme: 'http', host: '127.0.0.1', port: boundPort);
  }

  /// Configure a background isolate to use the main isolate's proxy listener.
  /// The listener binds dynamically, so its port must be passed to workers.
  void configureRemotePort(int port) {
    if (port < 1 || port > 65535) {
      throw ArgumentError.value(port, 'port', 'Must be a valid TCP port');
    }
    _remotePort = port;
  }

  /// Register metadata with the main-isolate proxy from a download worker.
  Future<void> registerTrackWithProxy(MediaItem item) async {
    if (_server != null) {
      registerTrack(item);
      return;
    }
    final remotePort = _remotePort;
    if (remotePort == null) {
      throw StateError('Stream proxy port was not provided to this isolate');
    }

    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri(
          scheme: 'http',
          host: '127.0.0.1',
          port: remotePort,
          path: '/register',
        ),
      );
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(MediaItemConverter.mediaItemToMap(item)));
      final response = await request.close();
      final responseBody = await utf8.decoder.bind(response).join();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'Stream proxy rejected track registration '
          '(${response.statusCode}): $responseBody',
          uri: request.uri,
        );
      }
    } finally {
      client.close(force: true);
    }
  }

  Future<void> start() {
    if (_server != null) return Future.value();
    return _startRequest ??= _startInternal().whenComplete(() {
      _startRequest = null;
    });
  }

  Future<void> _startInternal() async {
    _logger = DownloadLog();
    await _logger!.open();

    try {
      final appDirectory = await getApplicationSupportDirectory();
      _stateFile = File('${appDirectory.path}/stream_proxy_state.json');
      final savedState = await _readSavedState();

      // Pick a port dynamically on first launch, then keep it for this app
      // installation. Android media resumption can retain the prior stream
      // URI after the process dies, so changing ports on every launch breaks
      // those saved sessions. App variants have separate support directories.
      final savedPort = savedState?['port'] as int?;
      if (savedPort != null && savedPort > 0 && savedPort < 65536) {
        try {
          _server = await HttpServer.bind(
            InternetAddress.loopbackIPv4,
            savedPort,
          );
        } on SocketException {
          // Another process may have claimed it. Move this installation to a
          // free port and persist that choice for its next launch.
          _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        }
      } else {
        _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      }

      final savedItems = savedState?['items'];
      if (savedItems is List) {
        for (final entry in savedItems) {
          if (entry is! Map) continue;
          try {
            final item = MediaItemConverter.mediaItemFromMap(
              Map<String, dynamic>.from(entry),
            );
            final token = _tokenFor(item);
            _registeredItems[token] = item;
          } catch (_) {
            // Ignore damaged cache entries; the saved queue will re-register
            // valid items when AudioService restores its playlist.
          }
        }
      }

      _scheduleStatePersist();
      unawaited(_removeStaleAudioCacheFiles());
      _logger!.log(
        'Stream proxy started on ${_server!.address.address}:${_server!.port}',
      );

      _server!.listen(
        _handleRequest,
        onError: (error) {
          _logger?.log('Stream server error: $error');
        },
      );
    } catch (e, st) {
      _logger?.log('Error starting stream server: $e\n$st');
      await _logger?.close();
      _logger = null;
      rethrow;
    }
  }

  Future<void> _removeStaleAudioCacheFiles() async {
    try {
      final directory = await getTemporaryDirectory();
      final cutoff = DateTime.now().subtract(const Duration(hours: 1));
      await for (final entity in directory.list()) {
        if (entity is! File ||
            !entity.uri.pathSegments.last.startsWith('saturn_next_audio_')) {
          continue;
        }
        if ((await entity.stat()).modified.isBefore(cutoff)) {
          await entity.delete();
        }
      }
    } catch (error) {
      _logger?.log('Could not clear stale audio cache files: $error');
    }
  }

  /// Stop the shared server when the application itself is shutting down.
  Future<void> stop() async {
    final pendingStart = _startRequest;
    if (pendingStart != null) await pendingStart;
    _persistTimer?.cancel();
    if (_server != null) await _persistState();
    if (_server != null) {
      _logger?.log('Stopping stream server');
      await _server?.close(force: true);
      _server = null;
    }
    await _logger?.close();
    _registeredItems.clear();
    _streamProviders.clear();
    _resolvedStreams.clear();
    _precacheRequests.clear();
    _metadataRequests.clear();
    _audioPrefetchClient?.close(force: true);
    await _audioPrefetch;
    final cachedAudio = _cachedAudio;
    _cachedAudio = null;
    cachedAudio?.retire();
    _logger = null;
    _stateFile = null;
  }

  /// Handle incoming HTTP requests
  Future<void> _handleRequest(HttpRequest request) async {
    final isLicenseRequest = request.uri.path.startsWith('/license/');
    final isRegistrationRequest = request.uri.path == '/register';
    if (request.method != 'GET' &&
        request.method != 'HEAD' &&
        !((isLicenseRequest || isRegistrationRequest) &&
            request.method == 'POST')) {
      request.response
        ..statusCode = HttpStatus.methodNotAllowed
        ..write('Only GET and HEAD requests supported!')
        ..close();
      return;
    }

    try {
      final uri = request.uri;

      if (isRegistrationRequest) {
        await _handleRegistrationRequest(request);
      } else if (isLicenseRequest) {
        await _handleLicenseRequest(request);
      } else if (uri.path.startsWith('/stream/')) {
        await _handlePlatformStream(request);
      } else {
        request.response
          ..statusCode = HttpStatus.badRequest
          ..write('Invalid path')
          ..close();
      }
    } catch (e) {
      final reason = e is StreamUnavailableException
          ? e.message
          : e is HttpException
          ? e.message
          : e.toString();
      _logger?.warn(
        'Stream proxy request failed for ${request.uri.path}: $reason',
      );
      try {
        request.response
          ..statusCode = HttpStatus.badGateway
          ..write('An error occurred while serving the request.');
      } on StateError {
        // The upstream may fail after the response headers or body have
        // already started. In that case only finish the partial response.
      }
      try {
        await request.response.close();
      } on StateError {
        // The response may already have been closed by the failing handler.
      }
    }
  }

  Future<void> _handleRegistrationRequest(HttpRequest request) async {
    if (request.contentLength > 1024 * 1024) {
      request.response.statusCode = HttpStatus.requestEntityTooLarge;
      await request.response.close();
      return;
    }
    final decoded = jsonDecode(await utf8.decoder.bind(request).join());
    if (decoded is! Map) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }
    final itemData = Map<String, dynamic>.from(decoded);
    if (itemData['id'] is! String || itemData['extras'] is! Map) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }
    final item = MediaItemConverter.mediaItemFromMap(
      itemData,
    );
    if (item.id.isEmpty || item.extras?['platformId'] is! String) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }
    final token = registerTrack(item);
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode({'token': token}));
    await request.response.close();
  }

  /// Register queue metadata so the proxy can resolve a stream without asking
  /// the platform API for metadata again (especially important for NeuroKaraoke).
  String registerTrack(MediaItem item) {
    final token = _tokenFor(item);
    _registeredItems.remove(token);
    _registeredItems[token] = item;
    while (_registeredItems.length > 8192) {
      final oldest = _registeredItems.keys.first;
      _registeredItems.remove(oldest);
      _resolvedStreams.removeWhere((key, _) => key.startsWith('$oldest:'));
      _precacheRequests.removeWhere((key, _) => key.startsWith('$oldest:'));
    }
    _scheduleStatePersist();
    return token;
  }

  String _tokenFor(MediaItem item) {
    final platformId = item.extras?['platformId'] as String? ?? 'deezer';
    return base64Url
        .encode(utf8.encode('$platformId\u0000${item.id}'))
        .replaceAll('=', '');
  }

  Future<Map<String, dynamic>?> _readSavedState() async {
    final file = _stateFile;
    if (file == null || !await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (error) {
      _logger?.log('Could not read saved stream proxy state: $error');
      return null;
    }
  }

  void _scheduleStatePersist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 250), () {
      unawaited(_persistState());
    });
  }

  Future<void> _persistState() async {
    final file = _stateFile;
    final boundPort = port;
    if (file == null || boundPort == null) return;
    final previousWrite = _persistRequest;
    final write = () async {
      if (previousWrite != null) await previousWrite;
      final state = {
        'port': boundPort,
        'items': _registeredItems.values
            .map(MediaItemConverter.mediaItemToMap)
            .toList(growable: false),
      };
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(jsonEncode(state));
      await temporary.rename(file.path);
    }();
    _persistRequest = write;
    try {
      await write;
    } catch (error) {
      _logger?.log('Could not save stream proxy state: $error');
    } finally {
      if (identical(_persistRequest, write)) _persistRequest = null;
    }
  }

  Uri streamUriFor(MediaItem item, int quality) {
    final qualityCode = quality == 1 || quality == 3 || quality == 9
        ? quality
        : 3;
    final token = registerTrack(item);
    return baseUri.replace(
      path: '/stream/$token',
      queryParameters: {'quality': '$qualityCode'},
    );
  }

  /// Discard cached resolution state after the player reports that a proxied
  /// stream failed, so the next request asks the platform for a fresh URL.
  void invalidateResolvedTrack(MediaItem item, int quality) {
    final platformId = item.extras?['platformId'] as String? ?? '';
    final platform = PlatformRegistry.instance.get(platformId);
    if (platform == null) return;

    final qualityCode = quality == 1 || quality == 3 || quality == 9
        ? quality
        : 3;
    final provider = _streamProviderFor(platformId, platform);
    final token = _tokenFor(item);
    final key = '$token:$qualityCode:${provider.streamCacheRevision}';
    _resolvedStreams.remove(key);
    _precacheRequests.remove(key);
    _metadataRequests.remove(key);
    provider.invalidateCachedStream(
      Track.fromMediaItem(item),
      _audioQuality(qualityCode),
    );

    if (_cachedAudio?.key == key) {
      final cached = _cachedAudio;
      _cachedAudio = null;
      cached?.retire();
    }
    if (_audioPrefetchKey == key) {
      _audioPrefetchClient?.close(force: true);
    }
  }

  Uri licenseUriFor(MediaItem item, int quality) {
    final streamUri = streamUriFor(item, quality);
    return streamUri.replace(
      path: streamUri.path.replaceFirst('/stream/', '/license/'),
    );
  }

  Future<void> _handleLicenseRequest(HttpRequest request) async {
    if (request.method != 'POST' || request.uri.pathSegments.length != 2) {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      await request.response.close();
      return;
    }
    final item = _registeredItems[request.uri.pathSegments[1]];
    if (item == null) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final platformId = item.extras?['platformId'] as String? ?? 'deezer';
    final platform = PlatformRegistry.instance.get(platformId);
    if (platform == null) {
      _logger?.log('No registered platform "$platformId" for stream ${item.id}');
      request.response.statusCode = HttpStatus.badGateway;
      await request.response.close();
      return;
    }
    final provider = _streamProviderFor(platformId, platform);
    final quality =
        int.tryParse(request.uri.queryParameters['quality'] ?? '') ?? 3;
    if (!await provider.handleLicenseRequest(
      request,
      Track.fromMediaItem(item),
      _audioQuality(quality),
    )) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    }
  }

  /// Resolve and retain a track's upstream response before playback reaches
  /// it. The same future is shared with the eventual HTTP request.
  Future<StreamResponse?> precacheTrack(
    MediaItem item,
    int quality, {
    DateTime? minimumValidity,
  }) async {
    final platformId = item.extras?['platformId'] as String? ?? '';
    final platform = PlatformRegistry.instance.get(platformId);
    if (platform == null) return null;
    final token = registerTrack(item);
    final qualityCode = quality == 1 || quality == 3 || quality == 9
        ? quality
        : 3;
    final provider = _streamProviderFor(platformId, platform);
    await provider.prepareStream();
    final key = '$token:$qualityCode:${provider.streamCacheRevision}';
    final pending = _precacheRequests[key];
    if (pending != null) {
      final cached = await pending;
      if (cached != null && _validFor(cached, minimumValidity)) return cached;
      if (identical(_precacheRequests[key], pending)) {
        _precacheRequests.remove(key);
      }
    }
    return _precacheRequests.putIfAbsent(
      key,
      () => _precacheTrack(item, provider, qualityCode, key, minimumValidity),
    );
  }

  bool _validFor(StreamResponse response, DateTime? minimumValidity) =>
      !response.isExpired &&
      (minimumValidity == null ||
          response.expiresAt == null ||
          response.expiresAt!.isAfter(minimumValidity));

  /// Download one upcoming progressive track on mobile. Playback still uses
  /// the normal proxy while the download is incomplete or if it fails.
  Future<void> precacheAudio(
    MediaItem item,
    int quality,
    StreamResponse resolved,
  ) async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    final platformId = item.extras?['platformId'] as String? ?? '';
    final platform = PlatformRegistry.instance.get(platformId);
    if (platform == null) return;
    final provider = _streamProviderFor(platformId, platform);
    if (await provider.precacheMedia(
      Track.fromMediaItem(item),
      _audioQuality(quality),
      resolved,
    )) {
      return;
    }
    final format = resolved.format?.toUpperCase();
    if (format == 'HLS' ||
        format == 'M3U8' ||
        format == 'DASH' ||
        resolved.meta['drmLicenseUrl'] != null) {
      return;
    }
    final hint = provider.playbackHint(
      Track.fromMediaItem(item),
      licenseUriFor(item, quality),
      resolved: resolved,
    );
    final hintedFormat = hint?.format.toUpperCase();
    if (hint?.drm != null || hintedFormat == 'HLS' || hintedFormat == 'DASH') {
      return;
    }
    final key =
        '${registerTrack(item)}:$quality:${provider.streamCacheRevision}';
    if (_cachedAudio?.key == key || _audioPrefetchKey == key) return;
    while (_audioPrefetch != null) {
      _audioPrefetchClient?.close(force: true);
      await _audioPrefetch;
      if (_cachedAudio?.key == key || _audioPrefetchKey == key) return;
    }
    _audioPrefetchKey = key;
    final request = _downloadAudioLead(item, quality, key);
    _audioPrefetch = request;
    try {
      await request;
    } finally {
      if (identical(_audioPrefetch, request)) {
        _audioPrefetch = null;
        _audioPrefetchKey = null;
      }
    }
  }

  Future<void> _downloadAudioLead(
    MediaItem item,
    int quality,
    String key,
  ) async {
    const maxBytes = 64 * 1024 * 1024;
    final client = HttpClient()..autoUncompress = false;
    _audioPrefetchClient = client;
    File? temporary;
    IOSink? sink;
    try {
      final request = await client.getUrl(streamUriFor(item, quality));
      request.headers.set('X-Saturn-Audio-Prefetch', '1');
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode != HttpStatus.ok ||
          response.contentLength > maxBytes) {
        await response.drain<void>();
        return;
      }
      final directory = await getTemporaryDirectory();
      temporary = File(
        '${directory.path}/saturn_next_audio_${DateTime.now().microsecondsSinceEpoch}',
      );
      sink = temporary.openWrite();
      var length = 0;
      await for (final chunk in response.timeout(const Duration(seconds: 20))) {
        length += chunk.length;
        if (length > maxBytes) return;
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (length == 0 ||
          (response.contentLength >= 0 && response.contentLength != length)) {
        return;
      }
      final previous = _cachedAudio;
      _cachedAudio = _CachedAudio(
        key: key,
        file: temporary,
        length: length,
        contentType: response.headers.contentType,
      );
      temporary = null;
      previous?.retire();
    } catch (error) {
      _logger?.log('Could not cache next audio track ${item.id}: $error');
    } finally {
      client.close(force: true);
      if (identical(_audioPrefetchClient, client)) _audioPrefetchClient = null;
      try {
        await sink?.close();
        if (temporary != null && await temporary.exists()) {
          await temporary.delete();
        }
      } catch (error) {
        _logger?.log('Could not clear incomplete audio cache: $error');
      }
    }
  }

  Future<bool> _serveCachedAudio(HttpRequest request, String key) async {
    final cached = _cachedAudio;
    if (cached == null || cached.key != key) return false;
    final range = request.headers.value(HttpHeaders.rangeHeader);
    final match = range == null
        ? null
        : RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
    if (range != null && match == null) return false;
    final start = match == null ? 0 : int.parse(match.group(1)!);
    if (start >= cached.length) {
      request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes */${cached.length}',
      );
      await request.response.close();
      return true;
    }
    final requestedEnd = match?.group(2)?.isNotEmpty == true
        ? int.parse(match!.group(2)!)
        : cached.length - 1;
    if (requestedEnd < start) return false;
    final end = requestedEnd.clamp(start, cached.length - 1);
    request.response.statusCode = match == null
        ? HttpStatus.ok
        : HttpStatus.partialContent;
    request.response.headers
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..contentLength = end - start + 1;
    if (cached.contentType != null) {
      request.response.headers.contentType = cached.contentType;
    }
    if (match != null) {
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/${cached.length}',
      );
    }
    if (request.method == 'GET') {
      cached.readers++;
      try {
        await request.response.addStream(cached.file.openRead(start, end + 1));
      } finally {
        cached.readers--;
        cached.deleteIfRetired();
      }
    }
    await request.response.close();
    return true;
  }

  /// Resolve bitrate or format metadata after the stream URL is ready.
  /// Callers should run this independently of queue and player operations.
  Future<StreamResponse?> resolveStreamMetadata(
    MediaItem item,
    int quality,
    StreamResponse resolved,
  ) async {
    final platformId = item.extras?['platformId'] as String? ?? '';
    final platform = PlatformRegistry.instance.get(platformId);
    if (platform == null) return null;
    final provider = _streamProviderFor(platformId, platform);
    final token = registerTrack(item);
    final qualityCode = quality == 1 || quality == 3 || quality == 9
        ? quality
        : 3;
    final key = '$token:$qualityCode:${provider.streamCacheRevision}';
    final metadataRequest = _metadataRequests.putIfAbsent(
      key,
      () => _resolveStreamMetadata(item, provider, qualityCode, resolved),
    );
    StreamResponse? metadata;
    try {
      metadata = await metadataRequest;
    } catch (_) {
      if (identical(_metadataRequests[key], metadataRequest)) {
        _metadataRequests.remove(key);
      }
      rethrow;
    }
    while (_metadataRequests.length > 512) {
      _metadataRequests.remove(_metadataRequests.keys.first);
    }
    return metadata;
  }

  Future<StreamResponse?> _resolveStreamMetadata(
    MediaItem item,
    StreamProvider provider,
    int qualityCode,
    StreamResponse resolved,
  ) async {
    final track = Track.fromMediaItem(item);
    final audioQuality = _audioQuality(qualityCode);
    var format = resolved.format;
    var bitrate = resolved.bitrate;

    if (resolved.requiresFormatProbe || bitrate == null || bitrate <= 0) {
      final probeUrl = resolved.url.startsWith('http')
          ? resolved.url
          : streamUriFor(item, qualityCode).toString();
      final info = await FormatUtils.resolveStreamInfo(
        probeUrl,
        durationSeconds: track.duration?.inSeconds,
        headers: resolved.requestHeaders,
      );
      if (info['formatDetected'] == true) {
        format = info['format'] as String? ?? format;
      }
      final detectedBitrate = info['bitrate'] as int? ?? 0;
      if (detectedBitrate > 0) bitrate = detectedBitrate;
    }

    if (bitrate == null || bitrate <= 0) {
      bitrate = await provider.resolveBitrate(track, audioQuality);
    }
    if (format == resolved.format && bitrate == resolved.bitrate) {
      return resolved;
    }
    return StreamResponse(
      url: resolved.url,
      format: format,
      bitrate: bitrate,
      requiresDecryption: resolved.requiresDecryption,
      requestHeaders: resolved.requestHeaders,
      requiresFormatProbe: false,
      expiresAt: resolved.expiresAt,
      meta: resolved.meta,
    );
  }

  StreamProvider _streamProviderFor(String platformId, MusicPlatform platform) {
    final cached = _streamProviders[platformId];
    if (cached != null && identical(cached.platform, platform)) {
      return cached.provider;
    }
    final provider = platform.getStreamProvider();
    _streamProviders[platformId] = (platform: platform, provider: provider);
    return provider;
  }

  Future<StreamResponse> _resolveStream(
    String key,
    StreamProvider provider,
    Track track,
    AudioQuality quality, {
    DateTime? minimumValidity,
  }) async {
    final pending = _resolvedStreams[key];
    if (pending != null) {
      try {
        final cached = await pending;
        if (_validFor(cached, minimumValidity)) return cached;
        if (!cached.isExpired && minimumValidity != null) {
          provider.invalidateCachedStream(track, quality);
        }
      } catch (_) {
        if (identical(_resolvedStreams[key], pending)) {
          _resolvedStreams.remove(key);
          _precacheRequests.remove(key);
        }
        // All waiters on this attempt see the same failure. A later explicit
        // request can retry; don't start another extraction for each waiter.
        rethrow;
      }
      if (identical(_resolvedStreams[key], pending)) {
        _resolvedStreams.remove(key);
        _precacheRequests.remove(key);
      }
    }
    // Share a replacement started by another waiter after the old URL expired.
    final loading = _resolvedStreams.putIfAbsent(
      key,
      () => provider.getStream(track, quality),
    );
    try {
      return await loading;
    } catch (_) {
      if (identical(_resolvedStreams[key], loading)) {
        _resolvedStreams.remove(key);
        _precacheRequests.remove(key);
      }
      rethrow;
    }
  }

  Future<StreamResponse?> _precacheTrack(
    MediaItem item,
    StreamProvider provider,
    int qualityCode,
    String key,
    DateTime? minimumValidity,
  ) async {
    try {
      final track = Track.fromMediaItem(item);
      await provider.precacheStream(track, _audioQuality(qualityCode));
      final resolved = await _resolveStream(
        key,
        provider,
        track,
        _audioQuality(qualityCode),
        minimumValidity: minimumValidity,
      );
      return resolved;
    } catch (error, stack) {
      // _resolveStream evicts a failed future by identity. Do not discard a
      // newer playback resolution when an older prefetch finishes failing.
      _logger?.log(
        'Could not pre-resolve ${item.id}: $error'
        '${error is StreamUnavailableException ? '' : '\n$stack'}',
      );
      return null;
    }
  }

  Future<void> _handlePlatformStream(HttpRequest request) async {
    final segments = request.uri.pathSegments;
    if (segments.length < 2) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }
    final token = segments[1];
    final item = _registeredItems[token];
    if (item == null) {
      _logger?.warn(
        'Stream request arrived before its media item was registered '
        '(token: $token, port: ${port ?? 'stopped'}).',
      );
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    final platformId = item.extras?['platformId'] as String? ?? 'deezer';
    final platform = PlatformRegistry.instance.get(platformId);
    if (platform == null) {
      _logger?.log('No registered platform "$platformId" for stream ${item.id}');
      request.response.statusCode = HttpStatus.badGateway;
      await request.response.close();
      return;
    }
    final streamProvider = _streamProviderFor(platformId, platform);
    final quality =
        int.tryParse(request.uri.queryParameters['quality'] ?? '') ?? 3;
    final audioQuality = _audioQuality(quality);
    final cacheKey = '$token:$quality:${streamProvider.streamCacheRevision}';
    if (await _serveCachedAudio(request, cacheKey)) return;
    // If playback reaches this track before its complete local copy is ready,
    // give the player the connection instead of downloading it twice.
    if (request.method == 'GET' &&
        request.headers.value('X-Saturn-Audio-Prefetch') != '1' &&
        _audioPrefetchKey == cacheKey) {
      _audioPrefetchClient?.close(force: true);
    }
    if (await streamProvider.handleProxyRequest(
      request,
      Track.fromMediaItem(item),
      audioQuality,
    )) {
      return;
    }
    await streamProvider.prepareStream();
    final client = HttpClient()..autoUncompress = false;
    try {
      for (var attempt = 0; attempt < 2; attempt++) {
        late HttpClientResponse upstream;
        late StreamResponse resolved;
        try {
          resolved = await _resolveStream(
            cacheKey,
            streamProvider,
            Track.fromMediaItem(item),
            audioQuality,
          );
          if (resolved.format == 'HLS' || resolved.format == 'M3U8') {
            request.response
              ..statusCode = HttpStatus.found
              ..headers.add(HttpHeaders.locationHeader, resolved.url)
              ..close();
            return;
          }
          final range = request.headers.value(HttpHeaders.rangeHeader);
          final upstreamRequest = await streamProvider.openProxyRequest(
            client,
            resolved,
            method: request.method,
            range: range,
          );
          upstream = await upstreamRequest.close();
        } on SocketException catch (_) {
          if (attempt == 0) {
            _resolvedStreams.remove(cacheKey);
            await Future<void>.delayed(const Duration(milliseconds: 300));
            continue;
          }
          rethrow;
        } on HttpException catch (_) {
          if (attempt == 0) {
            _resolvedStreams.remove(cacheKey);
            await Future<void>.delayed(const Duration(milliseconds: 300));
            continue;
          }
          rethrow;
        } on TimeoutException catch (_) {
          if (attempt == 0) {
            _resolvedStreams.remove(cacheKey);
            await Future<void>.delayed(const Duration(milliseconds: 300));
            continue;
          }
          rethrow;
        }
        final shouldRetry = streamProvider.shouldRetryProxyStatus(
          upstream.statusCode,
        );
        if (shouldRetry && attempt == 0) {
          streamProvider.onProxyResponseStatus(
            Track.fromMediaItem(item),
            audioQuality,
            upstream.statusCode,
            resolved,
          );
        }
        if (shouldRetry && attempt == 0) {
          await upstream.drain<void>();
          _resolvedStreams.remove(cacheKey);
          continue;
        }
        if (upstream.statusCode >= HttpStatus.internalServerError &&
            attempt == 0) {
          await upstream.drain<void>();
          _resolvedStreams.remove(cacheKey);
          await Future<void>.delayed(const Duration(milliseconds: 300));
          continue;
        }

        if (upstream.statusCode != HttpStatus.ok &&
            upstream.statusCode != HttpStatus.partialContent) {
          _logger?.warn(
            'Upstream $platformId stream for ${item.id} returned '
            'HTTP ${upstream.statusCode}',
          );
        }

        request.response.statusCode = upstream.statusCode;
        final contentType = upstream.headers.contentType;
        if (contentType != null) {
          request.response.headers.contentType = contentType;
        }
        for (final header in [
          HttpHeaders.acceptRangesHeader,
          HttpHeaders.contentRangeHeader,
          HttpHeaders.etagHeader,
          HttpHeaders.lastModifiedHeader,
        ]) {
          final value = upstream.headers.value(header);
          if (value != null) request.response.headers.set(header, value);
        }
        if (upstream.contentLength >= 0) {
          request.response.headers.contentLength = upstream.contentLength;
        }
        if (request.method == 'HEAD') {
          await request.response.close();
        } else {
          await request.response.addStream(upstream);
          await request.response.close();
        }
        return;
      }
    } catch (error, stack) {
      // Canceling a background copy closes its loopback client. Its aborted
      // response must not discard the URL needed by the real player request.
      if (request.headers.value('X-Saturn-Audio-Prefetch') != '1') {
        _resolvedStreams.remove(cacheKey);
      }
      if (error is StreamUnavailableException) {
        _unavailableEvents.add((
          platformId: platformId,
          trackId: item.id,
          message: error.message,
        ));
      }
      _logger?.log(
        'Platform proxy failed for ${item.id}: $error'
        '${error is StreamUnavailableException ? '' : '\n$stack'}',
      );
      try {
        request.response.statusCode = HttpStatus.badGateway;
        await request.response.close();
      } catch (_) {
        // The response may already have started streaming.
      }
    } finally {
      client.close(force: true);
    }
  }

  AudioQuality _audioQuality(int quality) => switch (quality) {
    1 => AudioQuality.MP3_128,
    3 => AudioQuality.MP3_320,
    9 => AudioQuality.FLAC,
    _ => AudioQuality.MP3_320,
  };
}

class _CachedAudio {
  _CachedAudio({
    required this.key,
    required this.file,
    required this.length,
    required this.contentType,
  });

  final String key;
  final File file;
  final int length;
  final ContentType? contentType;
  int readers = 0;
  bool retired = false;

  void retire() {
    retired = true;
    deleteIfRetired();
  }

  void deleteIfRetired() {
    if (retired && readers == 0) {
      unawaited(file.delete().then((_) {}).catchError((Object _) {}));
    }
  }
}
