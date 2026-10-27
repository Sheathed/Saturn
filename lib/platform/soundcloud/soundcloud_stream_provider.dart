import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../api/definitions.dart';
import '../../settings.dart';
import '../stream_provider.dart';
import 'soundcloud_api.dart';

class SoundCloudStreamProvider extends StreamProvider {
  SoundCloudStreamProvider(this.api, {bool? supportsWidevine, bool? preferHls})
    : supportsWidevine = supportsWidevine ?? Platform.isAndroid,
      preferHls = preferHls ?? (Platform.isAndroid || Platform.isIOS);

  final SoundCloudApi api;
  final bool supportsWidevine;
  final bool preferHls;
  final Map<String, Uri> _hlsResources = {};
  final Map<Uri, ({Uint8List bytes, ContentType? contentType})>
  _prefetchedHlsSegments = {};
  final Map<String, StreamResponse> _resolved = {};
  int _nextHlsResource = 0;

  @override
  StreamPlaybackHint? playbackHint(
    Track track,
    Uri licenseUri, {
    StreamResponse? resolved,
  }) {
    final usesHls = resolved != null
        ? resolved.format == 'HLS'
        : shouldUseHlsSource(track) ||
              (savedTranscodings(track).isEmpty && preferHls);
    if (!usesHls) return null;
    final needsWidevine =
        supportsWidevine &&
        (resolved != null
            ? resolved.meta['drmLicenseUrl'] != null
            : isDrmOnly(track));
    return StreamPlaybackHint(
      format: 'HLS',
      drm: needsWidevine
          ? StreamDrmConfiguration(licenseUrl: licenseUri.toString())
          : null,
    );
  }

  static List<Map<String, dynamic>> savedTranscodings(Track track) {
    final details = track.playbackDetails;
    if (details == null || details.length <= 5) return [];
    try {
      final decoded = jsonDecode(details[5].toString());
      if (decoded is List) {
        return decoded.whereType<Map>().map(Map<String, dynamic>.from).toList();
      }
    } catch (_) {
      // Older queue entries may not contain usable transcoding metadata.
    }
    return [];
  }

  static bool isEncrypted(Map<String, dynamic> stream) =>
      SoundCloudApi.isEncryptedTranscoding(stream);

  static bool isHls(Map<String, dynamic> stream) =>
      ((stream['format'] as Map?)?['protocol']?.toString() ?? '')
          .toLowerCase()
          .contains('hls');

  static bool isWidevineHls(Map<String, dynamic> stream) =>
      ((stream['format'] as Map?)?['protocol']?.toString() ?? '')
          .toLowerCase() ==
      'ctr-encrypted-hls';

  static bool isSnipped(Map<String, dynamic> stream) =>
      stream['snipped'] == true;

  static bool isDrmOnly(Track track) {
    final transcodings = savedTranscodings(track);
    if (SoundCloudApi.isDrmOnlyTranscodingList(transcodings)) return true;
    final policy = track.playbackDetails != null &&
            track.playbackDetails!.length > 3
        ? track.playbackDetails![3]?.toString().toUpperCase()
        : null;
    return policy == 'MONETIZE' &&
        !transcodings.any((stream) {
          final protocol = (stream['format'] as Map?)?['protocol']
              ?.toString()
              .toLowerCase();
          return SoundCloudApi.isFullClearTranscoding(stream) &&
              protocol == 'progressive';
        });
  }

  static bool isSubscriberPreviewOnly(Track track) =>
      track.playbackDetails?.contains('subscriber_preview') ?? false;

  static bool hasWidevine(Track track) => savedTranscodings(
    track,
  ).any((stream) => isWidevineHls(stream) && !isSnipped(stream));

  static bool shouldUseHlsSource(Track track) {
    final streams = savedTranscodings(track);
    if (hasWidevine(track)) return true;
    final fullClear = streams
        .where(
          (stream) =>
              !isEncrypted(stream) &&
              !isSnipped(stream) &&
              stream['is_legacy_transcoding'] != true,
        )
        .toList();
    final clear = fullClear.isNotEmpty
        ? fullClear
        : streams.where((stream) => !isEncrypted(stream)).toList();
    return clear.any(isHls);
  }

  @override
  String get streamCacheRevision =>
      api.client.oauthToken?.hashCode.toString() ?? '';

  @override
  Future<bool> precacheMedia(
    Track track,
    AudioQuality quality,
    StreamResponse response,
  ) async {
    if (response.format != 'HLS') return false;
    // Keep Widevine media and its license exchange entirely on the normal
    // player path. Only clear HLS segments can be replayed from this cache.
    if (response.meta['drmLicenseUrl'] != null) return true;
    try {
      await _prefetchFirstHlsSegment(Uri.parse(response.url));
    } catch (_) {
      // The player can always request the segment normally.
    }
    return true;
  }

  Future<void> _prefetchFirstHlsSegment(Uri playlist, {int depth = 0}) async {
    if (depth > 2) return;
    final client = HttpClient();
    try {
      final request = await client.getUrl(playlist);
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      if (response.statusCode != HttpStatus.ok) return;
      final body = await utf8.decoder
          .bind(response.timeout(const Duration(seconds: 15)))
          .join();
      if (!body.startsWith('#EXTM3U')) return;
      final lines = body.split('\n').map((line) => line.trim()).toList();
      final media = lines.where(
        (line) => line.isNotEmpty && !line.startsWith('#'),
      );
      if (media.isEmpty) return;
      final first = playlist.resolve(media.first);
      if (body.contains('#EXT-X-STREAM-INF') ||
          first.path.toLowerCase().endsWith('.m3u8')) {
        await _prefetchFirstHlsSegment(first, depth: depth + 1);
        return;
      }
      // Byte-range playlists can reuse one large resource for many segments.
      // The normal relay preserves their range requests.
      if (body.contains('#EXT-X-BYTERANGE')) return;
      final resources = <Uri>[];
      final map = RegExp(r'#EXT-X-MAP:[^\n]*URI="([^"]+)"').firstMatch(body);
      if (map != null) {
        resources.add(playlist.resolve(map.group(1)!));
      }
      final aesKey = RegExp(
        r'#EXT-X-KEY:[^\n]*METHOD=AES-128[^\n]*URI="([^"]+)"',
      ).firstMatch(body);
      if (aesKey != null) {
        resources.add(playlist.resolve(aesKey.group(1)!));
      }
      resources.add(first);
      await Future.wait(resources.map(_prefetchHlsResource));
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _prefetchHlsResource(Uri uri) async {
    if (_prefetchedHlsSegments.containsKey(uri)) return;
    const maxBytes = 4 * 1024 * 1024;
    final client = HttpClient()..autoUncompress = false;
    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      if (response.statusCode != HttpStatus.ok ||
          (response.headers.value(HttpHeaders.contentEncodingHeader) != null &&
              response.headers.value(HttpHeaders.contentEncodingHeader) !=
                  'identity') ||
          response.contentLength > maxBytes) {
        return;
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 15))) {
        builder.add(chunk);
        if (builder.length > maxBytes) return;
      }
      if (builder.length == 0) return;
      _prefetchedHlsSegments[uri] = (
        bytes: builder.takeBytes(),
        contentType: response.headers.contentType,
      );
      while (_prefetchedHlsSegments.length > 4) {
        _prefetchedHlsSegments.remove(_prefetchedHlsSegments.keys.first);
      }
    } finally {
      client.close(force: true);
    }
  }

  @override
  void invalidateCachedStream(Track track, AudioQuality quality) {
    if (track.id != null) _resolved.remove('$streamCacheRevision:${track.id}');
  }

  static List<Map<String, dynamic>> sortStreams(
    List<Map<String, dynamic>> streams,
  ) {
    if (streams.isEmpty) {
      throw StateError('SoundCloud did not return a playable stream');
    }

    final fullLength = streams
        .where((stream) => !(stream['snipped'] as bool? ?? false))
        .toList();
    final candidates = fullLength.isEmpty ? streams : fullLength;

    int score(Map<String, dynamic> stream) {
      final format = stream['format'] as Map<String, dynamic>? ?? {};
      final mimeType = format['mime_type'] as String? ?? '';
      final container = mimeType.split(';').first.split('/').last.toLowerCase();
      final protocol = format['protocol'] as String? ?? '';
      final quality = stream['quality'] as String? ?? '';

      var value = 0;
      if (protocol.toLowerCase() == 'progressive') value += 100;
      if (container == 'mp3' || container == 'mpeg') value += 20;
      if (quality == 'hq') value += 5;
      return value;
    }

    candidates.sort((a, b) => score(b).compareTo(score(a)));
    return candidates;
  }

  @override
  Future<StreamResponse> getStream(Track track, AudioQuality quality) async {
    if (track.id == null) throw ArgumentError('SoundCloud track ID is missing');
    if (isSubscriberPreviewOnly(track)) {
      throw const StreamUnavailableException(
        'A SoundCloud Go+ subscription is required to play the full track',
      );
    }
    final cacheKey = '$streamCacheRevision:${track.id}';
    final cached = _resolved[cacheKey];
    if (cached != null && !cached.isExpired) return cached;

    var transcodings = savedTranscodings(track);
    final hadSavedTranscodings = transcodings.isNotEmpty;
    final expectedHls = preferHls && hadSavedTranscodings
        ? (shouldUseHlsSource(track) || isDrmOnly(track))
        : null;
    if (!supportsWidevine &&
        (track.unavailableReason == 'drm' ||
            (track.unavailable == true && isDrmOnly(track)) ||
            (hadSavedTranscodings && isDrmOnly(track)))) {
      throw const StreamUnavailableException(
        'SoundCloud only provided a DRM-encrypted stream for this track',
      );
    }

    if (!hadSavedTranscodings) {
      transcodings = await api.getStreams(track.id!);
      if (!supportsWidevine &&
          !transcodings.any((t) => !isEncrypted(t) && !isSnipped(t)) &&
          transcodings.any((t) => isEncrypted(t) && !isSnipped(t))) {
        throw const StreamUnavailableException(
          'SoundCloud only provided a DRM-encrypted stream for this track',
        );
      }
    }
    String? failure;
    var encryptedOnly = false;
    var widevineAvailable = false;
    for (var pass = 0; pass < (hadSavedTranscodings ? 2 : 1); pass++) {
      if (pass == 1) {
        try {
          transcodings = await api.getStreams(track.id!);
        } catch (error) {
          failure = 'metadata refresh: ${error.runtimeType}';
          break;
        }
      }
      final clear = transcodings.where((t) => !isEncrypted(t)).toList();
      final encryptedFull = transcodings
          .where((t) => isWidevineHls(t) && !isSnipped(t))
          .toList();
      widevineAvailable = encryptedFull.isNotEmpty;
      var available = clear;
      if (expectedHls != null) {
        available = available
            .where((stream) => isHls(stream) == expectedHls)
            .toList();
      } else if (preferHls && available.any(isHls)) {
        available = available.where(isHls).toList();
      }
      final preferredEncrypted = supportsWidevine
          ? encryptedFull
                .where(
                  (stream) =>
                      expectedHls == null || isHls(stream) == expectedHls,
                )
                .toList()
          : <Map<String, dynamic>>[];
      if (available.isEmpty && preferredEncrypted.isEmpty) {
        if (transcodings.isNotEmpty) encryptedOnly = clear.isEmpty;
        if (!supportsWidevine && clear.isEmpty && widevineAvailable) {
          break;
        }
        continue;
      }
      encryptedOnly = false;
      final sortedCandidates = [
        if (available.isNotEmpty) ...sortStreams(available),
        if (preferredEncrypted.isNotEmpty) ...sortStreams(preferredEncrypted),
      ];

      for (final selected in sortedCandidates) {
        final uri = Uri.tryParse(selected['url']?.toString() ?? '');
        if (uri == null) continue;
        Map<String, dynamic> response;
        try {
          response = await api.client.getMedia(uri) as Map<String, dynamic>;
        } catch (error) {
          failure = error is HttpException
              ? error.message
              : error.runtimeType.toString();
          continue;
        }
        final licenseToken = response['licenseAuthToken'] as String?;
        final hasLicenseToken = licenseToken?.isNotEmpty == true;
        // The mobile API can expose a protected HLS resource as `hls` rather
        // than an `*-encrypted-hls` transcoding. Its license token is the
        // authoritative DRM signal in that case.
        final encrypted = isEncrypted(selected) || hasLicenseToken;
        if (hasLicenseToken) api.markDrmOnly(track.id!);
        if (hasLicenseToken && !supportsWidevine) {
          track
            ..unavailable = true
            ..unavailableReason = 'drm';
          throw const StreamUnavailableException(
            'SoundCloud only provided a DRM-encrypted stream for this track',
          );
        }
        final resolvedUrl = response['url'] as String?;
        if (resolvedUrl == null) continue;

        final formatMap = selected['format'] as Map<String, dynamic>? ?? {};
        final mimeType = formatMap['mime_type'] as String? ?? '';
        final container = mimeType
            .split(';')
            .first
            .split('/')
            .last
            .toLowerCase();

        final protocol = formatMap['protocol'] as String? ?? '';
        if (encrypted && !hasLicenseToken) {
          failure = 'Widevine license token missing';
          continue;
        }
        final isSnipped = selected['snipped'] as bool? ?? false;
        final qualityStr = selected['quality'] as String? ?? '';

        final isMp3 = container == 'mp3' || container == 'mpeg';
        final isOpus = container == 'opus' || container == 'ogg';
        final format = isHls(selected)
            ? 'HLS'
            : (isMp3 ? 'MP3' : (isOpus ? 'OGG' : container.toUpperCase()));
        final bitrate = qualityStr == 'hq' ? 256 : (isMp3 ? 128 : 64);

        final stream = StreamResponse(
          url: resolvedUrl,
          format: format,
          bitrate: bitrate,
          requiresDecryption: false,
          requiresFormatProbe: false,
          expiresAt: DateTime.now().add(const Duration(minutes: 2)),
          meta: {
            'protocol': protocol,
            'snipped': isSnipped,
            'downloadable': protocol.toLowerCase() == 'progressive',
            if (encrypted) 'drmLicenseUrl': Uri.https(
                'license.media-streaming.soundcloud.cloud',
                '/playback/widevine',
                {'license_token': licenseToken},
              ).toString(),
          },
        );
        _resolved[cacheKey] = stream;
        while (_resolved.length > 200) {
          _resolved.remove(_resolved.keys.first);
        }
        return stream;
      }
    }

    throw StreamUnavailableException(
      widevineAvailable && !supportsWidevine
          ? 'SoundCloud only provided a DRM-encrypted stream for this track'
          : encryptedOnly
          ? supportsWidevine
                ? 'SoundCloud did not provide a Widevine stream for this track'
                : 'SoundCloud only provided a DRM-encrypted stream for this track'
          : 'SoundCloud media resolution failed${failure == null ? '' : ' ($failure)'}',
    );
  }

  @override
  Future<bool> handleProxyRequest(
    HttpRequest request,
    Track track,
    AudioQuality quality,
  ) async {
    final resourceId = request.uri.queryParameters['sc_hls'];
    if (resourceId != null) {
      final uri = _hlsResources[resourceId];
      if (uri == null) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      } else {
        await _relayHls(request, uri);
      }
      return true;
    }

    final stream = await getStream(track, quality);
    if (stream.format != 'HLS') return false;
    await _relayHls(request, Uri.parse(stream.url));
    return true;
  }

  @override
  Future<bool> handleLicenseRequest(
    HttpRequest request,
    Track track,
    AudioQuality quality,
  ) async {
    if (!supportsWidevine) return false;
    final stream = await getStream(track, quality);
    final licenseUrl = Uri.tryParse(
      stream.meta['drmLicenseUrl'] as String? ?? '',
    );
    if (licenseUrl?.scheme != 'https' ||
        licenseUrl?.host != 'license.media-streaming.soundcloud.cloud' ||
        licenseUrl?.path != '/playback/widevine') {
      request.response.statusCode = HttpStatus.badGateway;
      await request.response.close();
      return true;
    }
    final client = HttpClient();
    try {
      final upstream = await client.postUrl(licenseUrl!);
      upstream.headers.contentType = ContentType('application', 'octet-stream');
      upstream.headers.set('Origin', 'https://soundcloud.com');
      upstream.headers.set('Referer', 'https://soundcloud.com/');
      await upstream.addStream(request);
      final response = await upstream.close();
      request.response.statusCode = response.statusCode;
      request.response.headers.contentType =
          response.headers.contentType ??
          ContentType('application', 'octet-stream');
      await request.response.addStream(response);
      await request.response.close();
      return true;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _relayHls(HttpRequest request, Uri uri) async {
    final cached = _prefetchedHlsSegments[uri];
    if (cached != null) {
      final range = request.headers.value(HttpHeaders.rangeHeader);
      final match = range == null
          ? null
          : RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
      if (range == null || match != null) {
        final start = match == null ? 0 : int.parse(match.group(1)!);
        if (start >= cached.bytes.length) {
          request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes */${cached.bytes.length}',
          );
          await request.response.close();
          return;
        }
        final requestedEnd = match?.group(2)?.isNotEmpty == true
            ? int.parse(match!.group(2)!)
            : cached.bytes.length - 1;
        if (requestedEnd >= start) {
          final end = requestedEnd.clamp(start, cached.bytes.length - 1);
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
              'bytes $start-$end/${cached.bytes.length}',
            );
          }
          if (request.method != 'HEAD') {
            request.response.add(cached.bytes.sublist(start, end + 1));
          }
          await request.response.close();
          return;
        }
      }
    }
    // SoundCloud serves HLS playlists with gzip encoding. Let HttpClient
    // decompress them before decoding and rewriting their URI lines.
    final client = HttpClient();
    try {
      final upstreamRequest = await client.openUrl(request.method, uri);
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null) {
        upstreamRequest.headers.set(HttpHeaders.rangeHeader, range);
      }
      final upstream = await upstreamRequest.close();
      request.response.statusCode = upstream.statusCode;
      final contentType = upstream.headers.contentType;
      final isPlaylist =
          uri.path.endsWith('.m3u8') ||
          contentType?.mimeType == 'application/vnd.apple.mpegurl' ||
          contentType?.mimeType == 'application/x-mpegurl';
      if (isPlaylist && upstream.statusCode == HttpStatus.ok) {
        final body = await utf8.decoder.bind(upstream).join();
        final rewritten = _rewritePlaylist(body, uri, request);
        request.response.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
        );
        if (request.method != 'HEAD') request.response.write(rewritten);
      } else {
        if (contentType != null) {
          request.response.headers.contentType = contentType;
        }
        for (final name in [
          HttpHeaders.acceptRangesHeader,
          HttpHeaders.contentRangeHeader,
        ]) {
          final value = upstream.headers.value(name);
          if (value != null) request.response.headers.set(name, value);
        }
        if (upstream.contentLength >= 0) {
          request.response.headers.contentLength = upstream.contentLength;
        }
        if (request.method != 'HEAD') {
          await request.response.addStream(upstream);
        }
      }
      await request.response.close();
    } finally {
      client.close(force: true);
    }
  }

  String _rewritePlaylist(String body, Uri source, HttpRequest request) {
    String localUrl(String raw) {
      final upstream = source.resolve(raw);
      if (upstream.scheme != 'http' && upstream.scheme != 'https') return raw;
      final key = '${++_nextHlsResource}';
      _hlsResources[key] = upstream;
      while (_hlsResources.length > 10000) {
        _hlsResources.remove(_hlsResources.keys.first);
      }
      return Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: request.connectionInfo!.localPort,
        path: request.uri.path,
        queryParameters: {
          if (request.uri.queryParameters['quality'] != null)
            'quality': request.uri.queryParameters['quality']!,
          'sc_hls': key,
        },
      ).toString();
    }

    final lines = body.split('\n').map((line) {
      if (line.startsWith('#')) {
        return line.replaceAllMapped(
          RegExp(r'URI="([^"]+)"'),
          (match) => 'URI="${localUrl(match.group(1)!)}"',
        );
      }
      return line.trim().isEmpty ? line : localUrl(line.trim());
    });
    return lines.join('\n');
  }

  @override
  Future<int?> resolveBitrate(Track track, AudioQuality _) async {
    return null;
  }

  @override
  Future<void> decryptFile(
    String trackId,
    String inputPath,
    String outputPath,
    Map<String, dynamic> meta,
  ) async {}
}
