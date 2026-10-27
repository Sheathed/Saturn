import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import '../../platform/deezer/deezer_api.dart';
import '../../platform/deezer/deezer_decryptor.dart';
import '../../api/definitions.dart';
import '../../platform/stream_provider.dart';
import '../../settings.dart';
import '../../utils/format_utils.dart';
import '../stream_proxy_server.dart';

/// Deezer playback is served by the shared local proxy. Token resolution and
/// decryption stay entirely on the server side.
class DeezerStreamProvider extends StreamProvider {
  static const _flac24DisplayFormat = 'FLAC 24-bit';

  final DeezerAPI api;

  DeezerStreamProvider(this.api);

  final Map<String, ({String url, int quality, String format})> _resolvedUrls =
      {};
  bool _authorized = false;

  @override
  Future<bool> handleProxyRequest(
    HttpRequest request,
    Track track,
    AudioQuality quality,
  ) async {
    await _handleDeezerStream(request, track.toMediaItem());
    return true;
  }

  @override
  Future<StreamResponse> getStream(Track track, AudioQuality quality) async {
    final trackId = track.id!;
    final streamTrackId = track.fallback?.id ?? trackId;
    final isUploadedMp3 = streamTrackId.startsWith('-');

    // The shared proxy uses the process-specific port selected at startup.
    final qualityCode = switch (quality) {
      AudioQuality.MP3_128 => 1,
      AudioQuality.MP3_320 => 3,
      AudioQuality.FLAC => 9,
      AudioQuality.ASK => 3,
    };
    final effectiveQualityCode =
        _resolvedUrls['$trackId:$qualityCode']?.quality ?? qualityCode;
    final proxyUrl = StreamProxyServer.instance
        .streamUriFor(track.toMediaItem(), qualityCode)
        .toString();

    final isFlac = effectiveQualityCode == 9 && !isUploadedMp3;
    final resolved = _resolvedUrls['$trackId:$qualityCode'];
    final resolvedFormat = resolved?.format;
    final format = _displayFormat(resolvedFormat) ??
        (isUploadedMp3 ? 'MP3' : (isFlac ? 'FLAC' : 'MP3'));
    return StreamResponse(
      url: proxyUrl,
      format: format,
      bitrate: null,
      requiresFormatProbe: true,
      requiresDecryption: false, // Proxy handles decryption in-flight
      meta: {'trackId': trackId, 'streamTrackId': streamTrackId},
    );
  }

  @override
  Future<void> decryptFile(
    String trackId,
    String inputPath,
    String outputPath,
    Map<String, dynamic> meta,
  ) async {
    throw UnsupportedError(
      'Deezer stream-server responses are already decrypted',
    );
  }

  @override
  Future<int?> resolveBitrate(Track track, AudioQuality quality) async {
    final trackId = track.id;
    if (trackId == null) return null;
    final qualityCode = switch (quality) {
      AudioQuality.MP3_128 => 1,
      AudioQuality.MP3_320 => 3,
      AudioQuality.FLAC => 9,
      AudioQuality.ASK => 3,
    };
    var resolved = _resolvedUrls['$trackId:$qualityCode'];
    if (resolved == null) {
      try {
        await precacheStream(track, quality);
      } catch (_) {}
      resolved = _resolvedUrls['$trackId:$qualityCode'];
    }
    if (resolved == null) {
      final matchingEntry = _resolvedUrls.entries
          .where((e) => e.key.startsWith('$trackId:'))
          .map((e) => e.value)
          .firstOrNull;
      if (matchingEntry != null) resolved = matchingEntry;
    }
    if (resolved != null) {
      if (resolved.quality == 1) return 128;
      if (resolved.quality == 3) return 320;
    }
    final streamUrl = resolved?.url;
    if (streamUrl != null) {
      final duration = track.duration?.inSeconds;
      final info = await FormatUtils.resolveStreamInfo(
        streamUrl,
        durationSeconds: duration,
      );
      final detected = info['bitrate'] as int? ?? 0;
      if (detected > 0) return detected;

      final headerBitrate = await FormatUtils.resolveBitrateFromHeaders(
        streamUrl,
        durationSeconds: duration,
      );
      if (headerBitrate != null && headerBitrate > 0) return headerBitrate;
    }
    return null;
  }

  String? _displayFormat(String? apiFormat) {
    if (apiFormat == null || apiFormat.isEmpty) return null;
    if (apiFormat == 'FLAC_24') return _flac24DisplayFormat;
    return apiFormat;
  }

  @override
  Future<void> precacheStream(Track track, AudioQuality quality) async {
    final trackId = track.id;
    if (trackId == null || trackId.isEmpty) return;
    final streamTrackId = track.fallback?.id ?? trackId;
    if (streamTrackId.startsWith('radio:')) return;

    final qualityCode = switch (quality) {
      AudioQuality.MP3_128 => 1,
      AudioQuality.MP3_320 => 3,
      AudioQuality.FLAC => 9,
      AudioQuality.ASK => 3,
    };
    final cacheKey = '$trackId:$qualityCode';
    if (_resolvedUrls.containsKey(cacheKey)) return;

    if (!_authorized || api.licenseToken?.isNotEmpty != true) {
      _authorized =
          await api.authorize() && api.licenseToken?.isNotEmpty == true;
      if (!_authorized) return;
    }

    final details = await _playbackDetailsForTrack(track, streamTrackId);
    final token = details != null && details.length >= 3
        ? details[2]?.toString() ?? ''
        : '';
    if (token.isEmpty) return;
    final playbackDetails = details!;

    final candidates = streamTrackId.startsWith('-')
        ? <int>[qualityCode]
        : switch (qualityCode) {
            9 => <int>[9, 3, 1],
            3 => <int>[3, 1],
            _ => <int>[1],
          };
    for (final candidateQuality in candidates) {
      final candidate = await _getTrackUrl(
        streamTrackId,
        token,
        playbackDetails[0]?.toString() ?? '',
        playbackDetails[1]?.toString() ?? '',
        candidateQuality,
      );
      if (candidate == null || candidate.url.isEmpty) continue;
      _resolvedUrls[cacheKey] = (
        url: candidate.url,
        quality: candidateQuality,
        format: candidate.format,
      );
      while (_resolvedUrls.length > 512) {
        _resolvedUrls.remove(_resolvedUrls.keys.first);
      }
      return;
    }
  }

  bool _hasTrackToken(List<dynamic>? details) =>
      details != null &&
      details.length >= 3 &&
      details[2]?.toString().trim().isNotEmpty == true;

  Future<List<dynamic>?> _playbackDetailsForTrack(
    Track track,
    String streamTrackId,
  ) async {
    if (_hasTrackToken(track.playbackDetailsFallback)) {
      return track.playbackDetailsFallback;
    }
    if (_hasTrackToken(track.playbackDetails)) return track.playbackDetails;
    try {
      final fullTrack = await api.track(streamTrackId);
      if (_hasTrackToken(fullTrack.playbackDetailsFallback)) {
        return fullTrack.playbackDetailsFallback;
      }
      return fullTrack.playbackDetails;
    } catch (error, stack) {
      Logger.root.warning(
        'Failed to fetch full track details for $streamTrackId: $error',
        error,
        stack,
      );
      return null;
    }
  }

  Future<void> _handleDeezerStream(
    HttpRequest request,
    MediaItem registeredItem,
  ) async {
    final params = request.uri.queryParameters;

    final streamTrackId =
        registeredItem.extras?['fallbackId'] as String? ?? registeredItem.id;
    final trackId = registeredItem.id;

    // Authorize if needed
    if (!_authorized || api.licenseToken?.isNotEmpty != true) {
      _authorized =
          await api.authorize() && api.licenseToken?.isNotEmpty == true;
      if (!_authorized) {
        request.response.statusCode = HttpStatus.serviceUnavailable;
        await request.response.close();
        return;
      }
    }

    final requestedQuality = int.tryParse(params['quality'] ?? '') ?? 3;
    final quality = const {1, 3, 9}.contains(requestedQuality)
        ? requestedQuality
        : 3;

    final cacheKey = '$trackId:$quality';

    if (streamTrackId.startsWith('radio:')) {
      final radioId = streamTrackId.substring(6);
      final url = await api.getLivestreamUrl(radioId);
      if (url != null) {
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set(HttpHeaders.locationHeader, url)
          ..close();
        return;
      }
    }

    var resolved = _resolvedUrls[cacheKey];
    if (resolved == null) {
      // Resolve once for HEAD/GET/range requests. The upstream URL remains
      // usable throughout an active stream, avoiding repeated API calls.
      final track = Track.fromMediaItem(registeredItem);
      final playbackDetails = await _playbackDetailsForTrack(
        track,
        streamTrackId,
      );
      if (!_hasTrackToken(playbackDetails)) {
        Logger.root.warning('ERROR: Track $trackId missing playback details');
        request.response
          ..statusCode = HttpStatus.notFound
          ..write('Track not available')
          ..close();
        return;
      }
      // Some tracks have no FLAC or 320 kbps source. Fall back only after
      // Deezer cannot provide the requested format, then report the format
      // actually served to the player and quality probe.
      final candidateQualities = streamTrackId.startsWith('-')
          ? <int>[quality]
          : switch (quality) {
              9 => <int>[9, 3, 1],
              3 => <int>[3, 1],
              _ => <int>[1],
            };
      for (final candidateQuality in candidateQualities) {
        final candidate = await _getTrackUrl(
          streamTrackId,
          playbackDetails?[2]?.toString() ?? '',
          playbackDetails?[0]?.toString() ?? '',
          playbackDetails?[1]?.toString() ?? '',
          candidateQuality,
        );
        if (candidate != null) {
          resolved = (
            url: candidate.url,
            quality: candidateQuality,
            format: candidate.format,
          );
          break;
        }
      }
      if (resolved != null) {
        _resolvedUrls.remove(cacheKey);
        _resolvedUrls[cacheKey] = resolved;
        while (_resolvedUrls.length > 512) {
          _resolvedUrls.remove(_resolvedUrls.keys.first);
        }
      }
    }
    if (resolved == null) {
      Logger.root.warning('ERROR: Failed to get track URL');
      request.response
        ..statusCode = HttpStatus.serviceUnavailable
        ..write('Stream temporarily unavailable')
        ..close();
      return;
    }
    final url = resolved.url;
    final effectiveQuality = resolved.quality;

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

    // All Deezer URLs are encrypted with BF_CBC_STRIPE in 2048-byte chunks
    const encrypted = true;
    int deezerStart = startBytes;
    if (encrypted) {
      deezerStart = startBytes - (startBytes % 2048);
    }
    final dropBytes = startBytes % 2048;

    // Align end range to full 2048-byte chunk boundaries so Blowfish-CBC
    // can decrypt the trailing chunk if needed
    int? deezerEnd;
    if (endBytes != null) {
      final endChunk = endBytes ~/ 2048;
      deezerEnd = ((endChunk + 1) * 2048) - 1;
    }

    // Make request to Deezer
    final client = HttpClient();
    try {
      Future<HttpClientResponse> openStreamUrl(String streamUrl) async {
        final upstreamRequest = request.method == 'HEAD'
            ? await client.headUrl(Uri.parse(streamUrl))
            : await client.getUrl(Uri.parse(streamUrl));
        upstreamRequest.headers.set(
          'User-Agent',
          'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/79.0.3945.130 Safari/537.36',
        );
        upstreamRequest.headers.set(
          'Range',
          'bytes=$deezerStart-${deezerEnd ?? ""}',
        );
        return upstreamRequest.close();
      }

      var deezerResponse = await openStreamUrl(url);

      if (deezerResponse.statusCode != HttpStatus.ok &&
          deezerResponse.statusCode != HttpStatus.partialContent) {
        final failedStatus = deezerResponse.statusCode;
        final expiredStatus =
            failedStatus == HttpStatus.forbidden ||
            failedStatus == HttpStatus.unauthorized ||
            failedStatus == HttpStatus.notFound ||
            failedStatus == HttpStatus.gone;
        if (expiredStatus) {
          await deezerResponse.drain<void>();
          _resolvedUrls.remove(cacheKey);
          if (failedStatus == HttpStatus.unauthorized) {
            _authorized = false;
            api.licenseToken = null;
          }

          // A cached CDN URL or queue-provided token may have expired. Refresh
          // the token once in the proxy and retry this same range request.
          if (failedStatus == HttpStatus.unauthorized) {
            _authorized =
                await api.authorize() && api.licenseToken?.isNotEmpty == true;
          }
          final freshToken = _authorized
              ? await _getFreshTrackToken(streamTrackId)
              : null;
          if (freshToken?.isNotEmpty == true) {
            final refreshedUrl = await _getTrackUrlFromAPI(
              streamTrackId,
              freshToken!,
              effectiveQuality,
            );
            if (refreshedUrl != null && refreshedUrl.url.isNotEmpty) {
              _resolvedUrls[cacheKey] = (
                url: refreshedUrl.url,
                quality: effectiveQuality,
                format: refreshedUrl.format,
              );
              deezerResponse = await openStreamUrl(refreshedUrl.url);
            }
          }
        }
        if (deezerResponse.statusCode != HttpStatus.ok &&
            deezerResponse.statusCode != HttpStatus.partialContent) {
          Logger.root.warning(
            'ERROR: Deezer returned non-success status: ${deezerResponse.statusCode}',
          );
          request.response
            ..statusCode = HttpStatus.badGateway
            ..write('Deezer CDN error')
            ..close();
          return;
        }
      }

      final upstreamRange = deezerResponse.headers.value('content-range');
      int totalSize = 0;
      if (upstreamRange != null && upstreamRange.contains('/')) {
        totalSize = int.tryParse(upstreamRange.split('/')[1]) ?? 0;
      } else if (deezerResponse.contentLength >= 0) {
        totalSize = deezerResponse.contentLength + deezerStart;
      }

      int? outContentLength;
      if (endBytes != null) {
        var effectiveEnd = endBytes;
        if (totalSize > 0 && effectiveEnd >= totalSize) {
          effectiveEnd = totalSize - 1;
        }
        if (effectiveEnd >= startBytes) {
          outContentLength = effectiveEnd - startBytes + 1;
        }
      } else if (totalSize > 0) {
        outContentLength = totalSize - startBytes;
      } else if (deezerResponse.contentLength >= 0) {
        final available = deezerResponse.contentLength - dropBytes;
        if (available > 0) {
          outContentLength = available;
        }
      }

      // user-uploaded MP3s have negative streamTrackId so it has to be an MP3
      String format;
      if (streamTrackId.startsWith('-')) {
        format = 'MP3';
      } else {
        format = effectiveQuality == 9 ? 'FLAC' : 'MP3';
      }

      if (request.method == 'HEAD') {
        request.response
          ..statusCode = isRanged ? HttpStatus.partialContent : HttpStatus.ok
          ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes')
          ..headers.contentType = ContentType(
            'audio',
            format == 'FLAC' ? 'flac' : 'mpeg',
          );
        if (isRanged && outContentLength != null && outContentLength > 0) {
          request.response.headers.contentLength = outContentLength;
          final rangeEnd = startBytes + outContentLength - 1;
          final totalStr = totalSize > 0 ? '$totalSize' : '*';
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $startBytes-$rangeEnd/$totalStr',
          );
        } else if (totalSize > 0) {
          request.response.headers.contentLength = totalSize;
        }
        await request.response.close();
        return;
      }

      // Set response headers
      request.response
        ..statusCode = isRanged ? HttpStatus.partialContent : HttpStatus.ok
        ..headers.contentType = ContentType(
          'audio',
          format == 'FLAC' ? 'flac' : 'mpeg',
        )
        ..headers.set(HttpHeaders.acceptRangesHeader, 'bytes');

      if (outContentLength != null && outContentLength > 0) {
        request.response.headers.contentLength = outContentLength;
      }

      if (isRanged && outContentLength != null && outContentLength > 0) {
        final rangeEnd = startBytes + outContentLength - 1;
        final totalStr = totalSize > 0 ? '$totalSize' : '*';
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $startBytes-$rangeEnd/$totalStr',
        );
      }

      // Stream with decryption
      try {
        await _streamWithDecryption(
          deezerResponse,
          request.response,
          streamTrackId,
          deezerStart,
          dropBytes,
          outContentLength,
        );
      } catch (e, st) {
        Logger.root.warning('ERROR during streaming: $e\n$st');
        rethrow;
      }
    } catch (e, st) {
      Logger.root.warning('ERROR in _handleDeezerStream: $e\n$st');
      try {
        request.response
          ..statusCode = HttpStatus.badGateway
          ..write('Stream error')
          ..close();
      } catch (_) {
        // The downstream response may already have started streaming.
      }
    } finally {
      client.close(force: true);
    }
  }

  /// Stream with decryption - matches Java FilterInputStream implementation
  Future<void> _streamWithDecryption(
    HttpClientResponse input,
    HttpResponse output,
    String trackId,
    int deezerStart,
    int dropBytes,
    int? maxOutputBytes,
  ) async {
    final key = await DeezerDecryptor.getKey(trackId);
    final decryptor = DeezerChunkDecryptor(key);
    int counter = deezerStart ~/ 2048;
    int drop = dropBytes;
    int bytesWritten = 0;
    final inputBuffer = <int>[];

    // Create a flag to indicate if the client is still connected
    bool clientConnected = true;

    // When output.done completes, set clientConnected to false
    output.done
        .then((_) {
          clientConnected = false;
        })
        .catchError((_) {
          clientConnected = false;
        });

    try {
      await for (final chunk in input) {
        if (!clientConnected) break;
        inputBuffer.addAll(chunk);

        // Process complete 2048-byte blocks
        while (inputBuffer.length >= 2048 &&
            clientConnected &&
            (maxOutputBytes == null || bytesWritten < maxOutputBytes)) {
          final buffer = inputBuffer.sublist(0, 2048);
          inputBuffer.removeRange(0, 2048);

          List<int> decrypted;
          if ((counter % 3) == 0) {
            decrypted = decryptor.decrypt(buffer);
          } else {
            decrypted = buffer;
          }
          counter++;

          int startOffset = 0;
          if (drop > 0) {
            startOffset = drop.clamp(0, decrypted.length);
            drop = 0;
          }
          int endOffset = decrypted.length;
          if (maxOutputBytes != null) {
            final available = endOffset - startOffset;
            final needed = maxOutputBytes - bytesWritten;
            if (available > needed) {
              endOffset = startOffset + needed;
            }
          }

          if (endOffset > startOffset) {
            final outputBlock =
                (startOffset == 0 && endOffset == decrypted.length)
                ? decrypted
                : decrypted.sublist(startOffset, endOffset);
            try {
              output.add(outputBlock);
              bytesWritten += outputBlock.length;
            } catch (_) {
              clientConnected = false;
              break;
            }
          }

          if (maxOutputBytes != null && bytesWritten >= maxOutputBytes) {
            break;
          }
        }

        if (!clientConnected ||
            (maxOutputBytes != null && bytesWritten >= maxOutputBytes)) {
          break;
        }
      }

      if (inputBuffer.isNotEmpty &&
          clientConnected &&
          (maxOutputBytes == null || bytesWritten < maxOutputBytes)) {
        int startOffset = 0;
        if (drop > 0) {
          startOffset = drop.clamp(0, inputBuffer.length);
          drop = 0;
        }
        int endOffset = inputBuffer.length;
        if (maxOutputBytes != null) {
          final available = endOffset - startOffset;
          final needed = maxOutputBytes - bytesWritten;
          if (available > needed) {
            endOffset = startOffset + needed;
          }
        }
        if (endOffset > startOffset) {
          final outputBlock =
              (startOffset == 0 && endOffset == inputBuffer.length)
              ? inputBuffer
              : inputBuffer.sublist(startOffset, endOffset);
          try {
            output.add(outputBlock);
            bytesWritten += outputBlock.length;
          } catch (_) {
            // Ignore errors if output is already closed
          }
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
      Map<dynamic, dynamic> data = await api.callGwApi(
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

      Logger.root.warning('No track data returned for trackId: $trackId');
      return null;
    } catch (e, st) {
      Logger.root.warning('Error fetching fresh track token: $e\n$st');
      return null;
    }
  }

  /// Get track URL - tries modern API first, falls back to legacy
  Future<({String url, String format})?> _getTrackUrl(
    String trackId,
    String trackToken,
    String md5origin,
    String mediaVersion,
    int quality,
  ) async {
    try {
      if (api.licenseToken != null && api.licenseToken!.isNotEmpty == true) {
        var resolved = await _getTrackUrlFromAPI(
          trackId,
          trackToken,
          quality,
        );
        if (resolved == null) {
          final freshToken = await _getFreshTrackToken(trackId);
          if (freshToken != null && freshToken.isNotEmpty) {
            resolved = await _getTrackUrlFromAPI(trackId, freshToken, quality);
          }
        }

        if (resolved != null && resolved.url.isNotEmpty) {
          return resolved;
        }
      } else {
        Logger.root.warning(
          'No license token available (licenseToken: ${api.licenseToken})',
        );
      }
      return null;
    } catch (e, st) {
      Logger.root.warning('Error getting track URL: $e\n$st');
      return null;
    }
  }

  /// Get track URL from Deezer API (modern method)
  Future<({String url, String format})?> _getTrackUrlFromAPI(
    String trackId,
    String trackToken,
    int quality,
  ) async {
    try {
      final formats = trackId.startsWith('-')
          ? <String>['MP3_MISC']
          : switch (quality) {
              9 => <String>['FLAC_24', 'FLAC'],
              3 => <String>['MP3_320'],
              _ => <String>['MP3_128'],
            };

      final payload = {
        'license_token': api.licenseToken,
        'media': [
          {
            'type': 'FULL',
            'formats': formats
                .map(
                  (format) => {
                    'cipher': 'BF_CBC_STRIPE',
                    'format': format,
                  },
                )
                .toList(),
          },
        ],
        'track_tokens': [trackToken],
      };

      final headers = {
        'Content-Type': 'application/json',
        'Cookie': 'arl=${api.arl}',
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
                final url = media['sources'][0]['url']?.toString();
                if (url == null || url.isEmpty) continue;
                // The API's returned format is authoritative. When older API
                // responses omit it, report regular FLAC for a FLAC request
                // rather than claiming 24-bit based only on request order.
                final format = media['format']?.toString() ??
                    (quality == 9 ? 'FLAC' : formats.first);
                return (url: url, format: format);
              } else {
                Logger.root.warning('No sources in media item');
              }
            } else {
              Logger.root.warning('No media in data item');
            }
          }
          Logger.root.warning('No valid URL found in API response data');
        } else {
          Logger.root.warning('API response has no data field');
        }
      } else {
        Logger.root.warning(
          'API returned status ${response.statusCode}: ${response.body}',
        );
      }
    } catch (e, st) {
      Logger.root.warning('Error getting track URL from API: $e\n$st');
    }
    return null;
  }
}
