import 'dart:convert';
import 'dart:io' as io;
import 'dart:isolate';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import 'youtube_music_auth.dart';

/// Low-level HTTP client for YouTube Music's Innertube API.
class YouTubeMusicClient {
  YouTubeMusicClient({
    http.Client? httpClient,
    this.gl = 'US',
    this.hl = 'en',
    this.onSessionExpired,
  }) : _client = httpClient ?? http.Client();

  final http.Client _client;
  final Logger _log = Logger('YouTubeMusicClient');

  /// Bodies larger than this are decoded in a background isolate.
  static const int _isolateDecodeThreshold = 32 * 1024;

  static const String baseUrl = 'https://music.youtube.com/youtubei/v1/';
  static String get webRemixVersion {
    final utc = DateTime.now().toUtc();
    final date =
        '${utc.year}${utc.month.toString().padLeft(2, '0')}${utc.day.toString().padLeft(2, '0')}';
    return '1.$date.01.00';
  }

  static const String webRemixApiKey =
      'AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30';
  static const String androidMusicVersion = '7.21.50';
  static const String userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36';
  static const String androidMusicUserAgent =
      'com.google.android.apps.youtube.music/7.21.50 (Linux; U; Android 13; en_US) gzip';

  String get _androidUserAgent => androidMusicUserAgent.replaceFirst(
    'en_US',
    '${hl.replaceAll('_', '-')}_${gl.toUpperCase()}',
  );

  String gl;
  String hl;
  String? visitorData;
  String? cookie;
  void Function()? onSessionExpired;
  Future<bool> Function()? refreshAuthentication;

  bool get isAuthenticated => hasMusicSessionCookie(cookie);

  Map<String, String> _buildHeaders({
    bool anonymous = false,
    bool mobileClient = false,
    required String webVersion,
    bool gzipBody = false,
  }) {
    final headers = <String, String>{
      'User-Agent': mobileClient ? _androidUserAgent : userAgent,
      'Accept': '*/*',
      'Accept-Language': _acceptLanguage,
      'Content-Type': 'application/json',
      if (gzipBody) 'Content-Encoding': 'gzip',
      if (!mobileClient) ...{
        'Origin': 'https://music.youtube.com',
        'Referer': 'https://music.youtube.com/',
        'X-Origin': 'https://music.youtube.com',
      },
      'X-YouTube-Client-Name': mobileClient ? '21' : '67',
      'X-YouTube-Client-Version': mobileClient
          ? androidMusicVersion
          : webVersion,
    };

    if (!anonymous && visitorData != null && visitorData!.isNotEmpty) {
      headers['X-Goog-Visitor-Id'] = visitorData!;
    }

    if (!anonymous && cookie != null && cookie!.isNotEmpty) {
      headers['Cookie'] = cookie!;
      final authorization = musicAuthorization(cookie, preferSecure3P: true);
      if (authorization != null) {
        headers['Authorization'] = authorization;
        headers['X-Goog-AuthUser'] = '0';
      }
    }

    return headers;
  }

  String get _acceptLanguage {
    final normalized = hl.replaceAll('_', '-');
    final base = normalized.split('-').first;
    return normalized == base ? normalized : '$normalized,$base;q=0.9';
  }

  Map<String, dynamic> _buildContext({
    bool mobileClient = false,
    bool anonymous = false,
    required String webVersion,
  }) {
    return {
      'client': {
        'clientName': mobileClient ? 'ANDROID_MUSIC' : 'WEB_REMIX',
        'clientVersion': mobileClient ? androidMusicVersion : webVersion,
        'hl': hl,
        'gl': gl,
        if (mobileClient) ...{
          'platform': 'MOBILE',
          'osName': 'Android',
          'osVersion': '13',
          'androidSdkVersion': 33,
        },
        if (!anonymous && visitorData != null && visitorData!.isNotEmpty)
          'visitorData': visitorData,
      },
      'user': {'lockedSafetyMode': false},
    };
  }

  /// Sends a POST request to an Innertube endpoint.
  Future<Map<String, dynamic>> post(
    String endpoint, {
    Map<String, dynamic> body = const {},
    Map<String, String>? query,
    bool mobileClient = false,
    bool anonymous = false,
    bool gzipBody = false,
    bool retryOnAuthError = true,
    bool retryWithRefreshedCookie = true,
  }) async {
    // A browser session cannot authenticate ANDROID_MUSIC. Mobile calls in
    // this client are guest-only; a future mobile login needs its own transport.
    anonymous = anonymous || mobileClient;
    final webVersion = webRemixVersion;
    var uri = Uri.parse('$baseUrl$endpoint?prettyPrint=false');
    if (!anonymous && isAuthenticated) {
      uri = uri.replace(
        queryParameters: {...uri.queryParameters, 'key': webRemixApiKey},
      );
    }
    if (query != null && query.isNotEmpty) {
      final q = Map<String, dynamic>.from(uri.queryParameters)..addAll(query);
      uri = uri.replace(queryParameters: q);
    }

    final requestBody = {
      'context': _buildContext(
        mobileClient: mobileClient,
        anonymous: anonymous,
        webVersion: webVersion,
      ),
      ...body,
    };
    final requestCookie = anonymous ? null : cookie;

    _log.fine('POST $uri');

    try {
      final response = await _client.post(
        uri,
        headers: _buildHeaders(
          anonymous: anonymous,
          mobileClient: mobileClient,
          webVersion: webVersion,
          gzipBody: gzipBody,
        ),
        body: gzipBody
            ? io.gzip.encode(utf8.encode(jsonEncode(requestBody)))
            : jsonEncode(requestBody),
      );

      // Capture visitor data from headers if present
      final responseVisitorId = response.headers['x-goog-visitor-id'];
      if (!anonymous &&
          responseVisitorId != null &&
          responseVisitorId.isNotEmpty) {
        visitorData = responseVisitorId;
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        _log.warning(
          'Innertube request failed (${response.statusCode}): ${response.body}',
        );

        // Check if authentication error due to expired / invalid cookie / SAPISID
        final isAuthenticationFailure =
            response.statusCode == 401 ||
            ((response.statusCode == 400 || response.statusCode == 403) &&
                _isAuthError(response.body));
        if (!anonymous && cookie != null && isAuthenticationFailure) {
          // Another request may already have replaced this session cookie.
          // Never let a late response from the old cookie clear the new one.
          if (requestCookie != cookie && isAuthenticated) {
            return await post(
              endpoint,
              body: body,
              query: query,
              mobileClient: mobileClient,
              anonymous: anonymous,
              gzipBody: gzipBody,
              retryOnAuthError: retryOnAuthError,
              retryWithRefreshedCookie: false,
            );
          }
          if (retryWithRefreshedCookie && refreshAuthentication != null) {
            var refreshed = false;
            try {
              refreshed = await refreshAuthentication!.call();
            } catch (error, stack) {
              _log.warning(
                'Could not refresh the YouTube Music cookie from WebView storage.',
                error,
                stack,
              );
            }
            if (refreshed && isAuthenticated) {
              _log.info(
                'Retrying Innertube request with refreshed WebView cookies.',
              );
              return await post(
                endpoint,
                body: body,
                query: query,
                mobileClient: mobileClient,
                anonymous: anonymous,
                gzipBody: gzipBody,
                retryOnAuthError: retryOnAuthError,
                retryWithRefreshedCookie: false,
              );
            }
          }
          _log.warning(
            'Innertube auth failed ($endpoint, status ${response.statusCode}). Session token or cookie is expired. Reverting to guest mode.',
          );
          cookie = null;
          try {
            onSessionExpired?.call();
          } catch (e) {
            _log.warning('Error in onSessionExpired callback: $e');
          }

          if (retryOnAuthError) {
            _log.info(
              'Retrying Innertube request to $endpoint as unauthenticated guest...',
            );
            return await post(
              endpoint,
              body: body,
              query: query,
              mobileClient: mobileClient,
              anonymous: anonymous,
              gzipBody: gzipBody,
              retryOnAuthError: false,
              retryWithRefreshedCookie: false,
            );
          }
        }

        throw HttpException(
          'Innertube request to $endpoint failed with status ${response.statusCode}: ${response.body}',
          statusCode: response.statusCode,
        );
      }

      final bytes = response.bodyBytes;
      if (bytes.length > _isolateDecodeThreshold) {
        return await Isolate.run(
          () => jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>,
        );
      }
      return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } catch (e, st) {
      if (e is! HttpException) {
        _log.severe('Error making Innertube request to $endpoint: $e', e, st);
      }
      rethrow;
    }
  }

  bool _isAuthError(String body) {
    final lower = body.toLowerCase();
    return lower.contains('unauthenticated') ||
        lower.contains('unauthorized') ||
        lower.contains('authentication') ||
        lower.contains('sapisid') ||
        lower.contains('invalid credential') ||
        lower.contains('invalid_credentials') ||
        lower.contains('login_required') ||
        lower.contains('login required') ||
        lower.contains('sign in to continue');
  }

  void close() {
    _client.close();
  }
}

class HttpException implements Exception {
  final String message;
  final int statusCode;
  const HttpException(this.message, {required this.statusCode});
  @override
  String toString() => message;
}
