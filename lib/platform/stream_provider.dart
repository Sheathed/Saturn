import 'dart:io';

import '../api/definitions.dart';
import '../settings.dart';

/// A stream that the provider cannot play under the current account/session.
class StreamUnavailableException implements Exception {
  const StreamUnavailableException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Playback settings supplied by a platform before a local proxy URL is played.
/// Native players use the format to select the correct source implementation.
class StreamPlaybackHint {
  final String format;
  final StreamDrmConfiguration? drm;

  const StreamPlaybackHint({required this.format, this.drm});
}

class StreamDrmConfiguration {
  final String licenseUrl;
  final Map<String, String> licenseHeaders;

  const StreamDrmConfiguration({
    required this.licenseUrl,
    this.licenseHeaders = const {},
  });
}

/// The response returned by a platform's stream provider: enough information
/// for the shared local stream proxy and download pipeline.
class StreamResponse {
  /// A URL that can be fed directly to just_audio (either a CDN URL or the
  final String url;

  /// Optional: the detected audio format
  final String? format;

  /// Optional: the detected bitrate in kbps
  final int? bitrate;

  /// Optional: the track needs to be decrypted after download (e.g. Deezer).
  final bool requiresDecryption;

  /// Headers required when requesting [url], retained through the shared proxy.
  final Map<String, String> requestHeaders;

  /// Whether the proxy should fetch a sample to inspect the resolved stream.
  /// Some providers already return reliable metadata and may issue one-use URLs.
  final bool requiresFormatProbe;

  /// Providers with expiring signed URLs can retire a cached stream before
  /// playback opens it. Static CDN links leave this unset.
  final DateTime? expiresAt;

  bool get isExpired =>
      expiresAt != null && !DateTime.now().isBefore(expiresAt!);

  /// Opaque platform-specific data passed through to [StreamProvider.decryptFile].
  final Map<String, dynamic> meta;

  const StreamResponse({
    required this.url,
    this.format,
    this.bitrate,
    this.requiresDecryption = false,
    this.requestHeaders = const {},
    this.requiresFormatProbe = true,
    this.expiresAt,
    this.meta = const {},
  });
}

/// Abstract interface that each platform must implement to provide audio
/// streaming and (optionally) download capability.
abstract class StreamProvider {
  /// Refresh account state before the proxy chooses a cache key.
  Future<void> prepareStream() async {}

  /// Changes when previously resolved stream URLs should no longer be reused.
  /// Providers with account-specific URLs can include a session fingerprint.
  String get streamCacheRevision => '';

  /// Describe HLS/DASH and DRM for native playback. A null hint means a
  /// normal progressive source. [licenseUri] is a local proxy endpoint that
  /// providers may use when license parameters expire with the media URL.
  StreamPlaybackHint? playbackHint(
    Track track,
    Uri licenseUri, {
    StreamResponse? resolved,
  }) => null;

  /// Build the [StreamResponse] for a given track at the requested quality.
  /// Called by the shared proxy when an item is prepared and by downloads.
  Future<StreamResponse> getStream(Track track, AudioQuality quality);

  /// Resolve provider-side playback data ahead of the player reaching a track.
  /// Providers can use this to cache signed URLs without downloading a probe.
  Future<void> precacheStream(Track track, AudioQuality quality) async {}

  /// Prepare media bytes for formats served by a provider-specific proxy,
  /// such as HLS segments. Return true when the provider handled the format.
  Future<bool> precacheMedia(
    Track track,
    AudioQuality quality,
    StreamResponse response,
  ) async => false;

  /// Drop a provider-side URL when background preparation needs a longer-lived
  /// response than the one already cached. Normal playback remains unchanged.
  void invalidateCachedStream(Track track, AudioQuality quality) {}

  /// Open a provider's upstream request. Providers can adapt methods/headers
  /// without putting platform-specific transport rules in the shared proxy.
  Future<HttpClientRequest> openProxyRequest(
    HttpClient client,
    StreamResponse stream, {
    required String method,
    String? range,
  }) async {
    final request = await client.openUrl(method, Uri.parse(stream.url));
    for (final header in stream.requestHeaders.entries) {
      request.headers.set(header.key, header.value);
    }
    if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
    if (request.headers.value(HttpHeaders.userAgentHeader) == null) {
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'Mozilla/5.0 (compatible; SaturnAudioProxy/1.0)',
      );
    }
    return request;
  }

  /// Handle platform-specific streaming behavior at the shared proxy
  /// endpoint. Return true when handled; otherwise the proxy relays getStream.
  Future<bool> handleProxyRequest(
    HttpRequest request,
    Track track,
    AudioQuality quality,
  ) async => false;

  /// Handle a native player's license challenge for a protected stream.
  Future<bool> handleLicenseRequest(
    HttpRequest request,
    Track track,
    AudioQuality quality,
  ) async => false;

  /// Whether the shared proxy should discard this URL and resolve a fresh
  /// one after receiving [statusCode] from the upstream server.
  bool shouldRetryProxyStatus(int statusCode) =>
      statusCode == HttpStatus.forbidden ||
      statusCode == HttpStatus.unauthorized ||
      statusCode == HttpStatus.notFound ||
      statusCode == HttpStatus.gone;

  /// Lets a provider switch extraction strategies after its resolved URL is
  /// rejected, before the proxy asks it to resolve the track again.
  void onProxyResponseStatus(
    Track track,
    AudioQuality quality,
    int statusCode,
    StreamResponse response,
  ) {}

  /// Decrypt an already-downloaded file in-place (or to a separate output
  /// path).  Platforms that don't encrypt can simply copy the file.
  Future<void> decryptFile(
    String trackId,
    String inputPath,
    String outputPath,
    Map<String, dynamic> meta,
  );

  /// Resolves bitrate from provider metadata without opening the audio stream.
  Future<int?> resolveBitrate(Track track, AudioQuality quality) async => null;
}
