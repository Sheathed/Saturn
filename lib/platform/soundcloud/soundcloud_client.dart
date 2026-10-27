import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import '../../utils/json_isolate.dart';
import '../../utils/logging.dart';

class SoundCloudChallengeException implements Exception {
  const SoundCloudChallengeException([
    this.message =
        'SoundCloud requires CAPTCHA verification on its website before this action can complete.',
  ]);

  final String message;

  @override
  String toString() => message;
}

class SoundCloudInternalClient {
  SoundCloudInternalClient({http.Client? httpClient})
    : _http = httpClient ?? http.Client();

  String? _clientId;
  String? _mobileClientId;
  final http.Client _http;
  String? oauthToken;
  String? currentUserId;
  Future<String?> Function(String expiredToken)? refreshAuthentication;
  String language = 'en';

  static const Map<String, String> defaultDeviceLocales = {
    'en': 'en-US',
    'de': 'de-DE',
    'es': 'es-ES',
    'fr': 'fr-FR',
    'it': 'it-IT',
    'nl': 'nl-NL',
    'pl': 'pl-PL',
    'pt': 'pt-BR',
    'sv': 'sv-SE',
  };

  String get deviceLocale =>
      defaultDeviceLocales[language] ?? '$language-${language.toUpperCase()}';

  String get acceptLanguageHeader =>
      '$deviceLocale,$language;q=0.9,en-US;q=0.8,en;q=0.7';

  Future<http.Response> _retryWithFreshAuthentication(
    http.Response response,
    Future<http.Response> Function() retry,
    String? requestToken,
  ) async {
    if (response.statusCode != 401 || requestToken == null) return response;
    final expiredToken = requestToken;
    String? freshToken;
    try {
      freshToken = await refreshAuthentication?.call(expiredToken);
    } catch (_) {
      // Preserve the original API error when browser recovery is unavailable.
      return response;
    }
    if (freshToken == null ||
        freshToken.isEmpty ||
        freshToken == expiredToken) {
      return response;
    }
    // Logout or a new login may have happened while the browser was loading.
    if (oauthToken == expiredToken) oauthToken = freshToken;
    if (oauthToken != freshToken) return response;
    return retry();
  }

  Future<Map<String, dynamic>?> accountForToken(String token) async {
    final uri = Uri.https('api-v2.soundcloud.com', '/me', {
      'client_id': await getClientId(),
    });
    final response = await _http.get(
      uri,
      headers: {'Authorization': 'OAuth $token'},
    );
    if (response.statusCode != 200) return null;
    final user = await _decode(response);
    return user is Map<String, dynamic> ? user : null;
  }

  // The web player signs follow requests using this public client constant.
  // Keep the signature and the request User-Agent in sync.
  static const followUserAgent =
      'Mozilla/5.0 (X11; Linux x86_64; rv:157.0) Gecko/20100101 Firefox/157.0';
  static const mobileFollowUserAgent =
      'Mozilla/5.0 (Linux; Android 15; Mobile) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';
  static const _followSignatureSecret = '5Dpr3ubBw8LFtbvQcd4Hx6hU';

  static String followSignature(
    String userId,
    String artistId,
    String clientId, {
    String userAgent = followUserAgent,
  }) {
    final words = userAgent.split(RegExp(r'[ /]'));
    final selected = words[words.first.length % words.length];
    final value =
        '1$_followSignatureSecret$clientId'
        '$_followSignatureSecret$artistId$userId$selected';
    var hash = 7996111;
    for (final byte in utf8.encode(value)) {
      hash = ((hash >> 1) + ((hash & 1) << 23) + byte) & 0xffffff;
    }
    return '1:${hash.toRadixString(16)}';
  }

  Map<String, String> get _authHeaders => {
    if (oauthToken != null && oauthToken!.isNotEmpty)
      'Authorization': 'OAuth $oauthToken',
    'Accept-Language': acceptLanguageHeader,
  };

  Map<String, String> get _webMutationHeaders => {
    ..._authHeaders,
    'Accept': 'application/json, text/javascript, */*; q=0.1',
    'Accept-Language': acceptLanguageHeader,
    'Origin': 'https://soundcloud.com',
    'Referer': 'https://soundcloud.com/',
    'User-Agent': followUserAgent,
  };

  Future<String> getClientId() async {
    if (_clientId != null) return _clientId!;

    try {
      var response = await _http.get(Uri.https('soundcloud.com', ''));
      if (response.statusCode == 200) {
        final scripts =
            RegExp('<script.*?src="(.*?)"').allMatches(response.body);
        if (scripts.isNotEmpty) {
          final scriptUrl = scripts.last.group(1);
          if (scriptUrl != null) {
            response = await _http.get(Uri.parse(scriptUrl));
            if (response.statusCode == 200) {
              final parts = response.body.split(',client_id');
              if (parts.length >= 2) {
                _clientId = parts[1].split('"')[1];
                return _clientId!;
              }
            }
          }
        }
      }
    } catch (_) {}

    return _clientId = 'QOFuKCOeAXIph267vzqj3B1wb65cZVAQ';
  }

  Future<String> getMobileClientId() async {
    if (_mobileClientId != null) return _mobileClientId!;
    final response = await _http.get(
      Uri.https('m.soundcloud.com', '/discover', {
        'prevent_desktop_redirect': 'true',
      }),
      headers: {'User-Agent': mobileFollowUserAgent},
    );
    if (response.statusCode != 200) {
      throw Exception('Failed to load mobile SoundCloud');
    }
    final match = RegExp(r'"clientId":"([^"]+)"').firstMatch(response.body);
    if (match == null) {
      throw const FormatException('Mobile SoundCloud client ID not found');
    }
    return _mobileClientId = match.group(1)!;
  }

  Future<http.Response> _sendWithRetries(
    Future<http.Response> Function() send, {
    String? requestToken,
  }) async {
    var response = await send();
    if (response.statusCode == 401 && requestToken != null) {
      response = await _retryWithFreshAuthentication(
        response,
        send,
        requestToken,
      );
    }
    return response;
  }

  Future<dynamic> _internalGet(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) async {
    final clientId = await getClientId();
    final params = queryParameters ?? {};
    params['client_id'] = clientId;

    // api-v2.soundcloud.com
    final uri = Uri.https(
      'api-v2.soundcloud.com',
      path,
      params.map((k, v) => MapEntry(k, v.toString())),
    );
    final requestToken = oauthToken;
    final response = await _sendWithRetries(
      () => _http.get(uri, headers: _authHeaders),
      requestToken: requestToken,
    );
    return _decode(response);
  }

  Future<dynamic> get(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) async {
    if (path == '/search') {
      final filter = queryParameters?['filter']?.toString().toLowerCase();
      if (filter == 'tracks') {
        return get('/search/tracks', queryParameters: queryParameters);
      } else if (filter == 'users' || filter == 'artists') {
        return get('/search/users', queryParameters: queryParameters);
      } else if (filter == 'playlists') {
        return get(
          '/search/playlists_without_albums',
          queryParameters: queryParameters,
        ).catchError(
          (_) => get('/search/playlists', queryParameters: queryParameters),
        );
      } else if (filter == 'albums') {
        return get('/search/albums', queryParameters: queryParameters);
      }
      final perCategoryLimit =
          (((queryParameters?['limit'] as num?)?.toInt() ?? 30) / 2)
              .ceil()
              .clamp(10, 30);
      final searchParams = {
        ...?queryParameters,
        'limit': perCategoryLimit,
      };
      final results = await Future.wait([
        get('/search/tracks', queryParameters: searchParams).catchError(
          (_) => {'collection': <dynamic>[]},
        ),
        get('/search/users', queryParameters: searchParams).catchError(
          (_) => {'collection': <dynamic>[]},
        ),
        get('/search/playlists_without_albums', queryParameters: searchParams)
            .catchError(
              (_) => get(
                '/search/playlists',
                queryParameters: searchParams,
              ).catchError((_) => {'collection': <dynamic>[]}),
            ),
        get('/search/albums', queryParameters: searchParams).catchError(
          (_) => {'collection': <dynamic>[]},
        ),
      ]);
      final combined = <dynamic>[];
      for (final r in results) {
        if (r is Map && r['collection'] is List) {
          combined.addAll(r['collection'] as List);
        }
      }
      if (combined.isNotEmpty) {
        return {'collection': combined};
      }
    }
    return _internalGet(path, queryParameters: queryParameters);
  }

  Future<dynamic> getNext(String nextHref) async {
    final uri = Uri.parse(nextHref);
    if (uri.scheme != 'https' || uri.host != 'api-v2.soundcloud.com') {
      throw ArgumentError.value(
        nextHref,
        'nextHref',
        'Invalid SoundCloud page',
      );
    }
    final requestToken = oauthToken;
    final response = await _sendWithRetries(
      () => _http.get(uri, headers: _authHeaders),
      requestToken: requestToken,
    );
    return _decode(response);
  }

  Future<dynamic> getMedia(Uri uri) async {
    if (uri.scheme != 'https' ||
        !{'api-v2.soundcloud.com', 'api.soundcloud.com'}.contains(uri.host)) {
      throw ArgumentError.value(uri, 'uri', 'Invalid SoundCloud media URL');
    }
    final clientId = await getClientId();
    final requestUri = uri.replace(
      queryParameters: {...uri.queryParameters, 'client_id': clientId},
    );
    // Public media resolution worked without account headers before sign in.
    // Some SoundCloud media endpoints reject an unnecessary OAuth header.
    var response = await _sendWithRetries(() => _http.get(requestUri));
    if ((response.statusCode == 401 ||
            response.statusCode == 403 ||
            response.statusCode == 404) &&
        oauthToken != null &&
        oauthToken!.isNotEmpty) {
      final requestToken = oauthToken;
      response = await _sendWithRetries(
        () => _http.get(requestUri, headers: _authHeaders),
        requestToken: requestToken,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (response.statusCode == 429) {
        throw const HttpException(
          'SoundCloud rate limited this request (HTTP 429). Please wait a moment and try again.',
        );
      }
      throw HttpException('SoundCloud media HTTP ${response.statusCode}');
    }
    return _decode(response);
  }

  Future<dynamic> change(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? queryParameters,
    Map<String, String>? headers,
    String apiHost = 'api-v2.soundcloud.com',
    String? clientIdOverride,
  }) async {
    if (oauthToken == null || oauthToken!.isEmpty) {
      throw StateError('SoundCloud sign in is required');
    }
    final clientId = clientIdOverride ?? await getClientId();
    final uri = Uri.https(apiHost, path, {
      'client_id': clientId,
      ...?queryParameters,
    });
    Future<http.Response> send() async {
      final request = http.Request(method, uri)
        ..headers.addAll(_webMutationHeaders)
        ..headers.addAll(headers ?? const {});
      if (body != null) {
        request.headers['Content-Type'] = 'application/json';
        request.body = jsonEncode(body);
      }
      return http.Response.fromStream(await _http.send(request));
    }

    appLogger.info('[SoundCloudWebClient] change: $method $uri');
    final requestToken = oauthToken;
    final response = await _sendWithRetries(
      send,
      requestToken: requestToken,
    );
    appLogger.info(
      '[SoundCloudWebClient] change response: ${response.statusCode} for $method $uri',
    );
    return _decode(response);
  }

  Future<dynamic> _decode(http.Response response) async {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      appLogger.warning(
        '[SoundCloudWebClient] HTTP error: ${response.statusCode} - ${response.body.length > 500 ? response.body.substring(0, 500) : response.body}',
      );
      if (response.statusCode == 403 &&
          response.body.contains('captcha-delivery.com')) {
        throw const SoundCloudChallengeException();
      }
      if (response.statusCode == 429) {
        throw const HttpException(
          'SoundCloud rate limited this request (HTTP 429). Please wait a moment and try again.',
        );
      }
      throw Exception(
        'SoundCloud API error: ${response.statusCode} - ${response.body}',
      );
    }
    if (response.body.isEmpty) return null;
    return await decodeJsonAsync(response.body);
  }
}
