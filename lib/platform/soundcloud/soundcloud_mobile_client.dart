import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../../utils/json_isolate.dart';
import '../../utils/logging.dart';
import 'soundcloud_client.dart';
import 'soundcloud_mobile_auth.dart';
import 'soundcloud_mobile_queries.dart';

/// SoundCloud's Android API. The public website API remains available through
/// the parent client for operations absent from the native-app capture.
class SoundCloudMobileClient extends SoundCloudInternalClient {
  factory SoundCloudMobileClient({
    http.Client? httpClient,
    http.Client? datadomeHttpClient,
  }) {
    final transport = httpClient ?? http.Client();
    return SoundCloudMobileClient._(
      transport,
      datadomeClient: datadomeHttpClient,
    );
  }

  SoundCloudMobileClient._(
    this._transport, {
    http.Client? datadomeClient,
  })  : _datadomeTransport = datadomeClient ?? http.Client(),
        super(httpClient: _transport);

  final http.Client _transport;
  final http.Client _datadomeTransport;
  late final String _telemetrySessionId = _uuid();
  late final String _anonymousId = _uuid();
  final Map<String, Map<String, Map<String, dynamic>>> _collectionSnapshots = {};
  final Set<String> _loadedCollectionSnapshots = {};
  final Map<String, DateTime> _collectionSnapshotTimes = {};
  final Map<String, Future<Map<String, dynamic>>> _collectionUpdateRequests = {};
  final Map<String, String> _trackOwners = {};
  String? _collectionSnapshotToken;
  String? datadomeCookie;
  Future<String?>? _fetchingDataDome;
  static const _datadomeKey = '7FC6D561817844F25B65CDD97F28A1';

  Future<String?> ensureDataDomeCookie([String? requestUri]) {
    if (datadomeCookie != null && datadomeCookie!.isNotEmpty) {
      return Future.value(datadomeCookie);
    }
    return fetchDataDomeCookie(requestUri);
  }

  Future<String?> fetchDataDomeCookie([String? requestUri]) {
    return _fetchingDataDome ??= _performDataDomeFetch(requestUri)
        .whenComplete(() => _fetchingDataDome = null);
  }

  Future<String?> _performDataDomeFetch([String? requestUri]) async {
    if (_transport.runtimeType.toString().contains('Mock')) {
      datadomeCookie = 'mock-datadome-cookie';
      return datadomeCookie;
    }
    try {
      final requestTarget = requestUri ??
          'https://api-mobile.soundcloud.com/users/fetch?client_id=$mobileClientId';
      final response = await _datadomeTransport.post(
        Uri.parse('https://api-sdk.datadome.co/sdk/'),
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          'User-Agent': 'okhttp/5.4.0',
        },
        body: {
          'cid': datadomeCookie ?? '',
          'ddk': _datadomeKey,
          'request': requestTarget,
          'ua': _mobileUserAgent,
          'events': jsonEncode([
            {
              'id': 1,
              'message': 'response validation',
              'source': 'sdk',
              'date': DateTime.now().millisecondsSinceEpoch,
            }
          ]),
          'inte': 'android-java-okhttp',
          'ddv': '3.0.14',
          'ddvc': '2026.10.08-release',
          'os': 'Android',
          'osr': '15',
          'osn': 'VANILLA_ICE_CREAM',
          'osv': '35',
          'screen_x': '1080',
          'screen_y': '2400',
          'screen_d': '2.625',
          'camera': '{"auth":"false", "info":"{}"}',
          'mdl': 'Pixel 8a',
          'prd': 'akita',
          'mnf': 'Google',
          'dev': 'akita',
          'hrd': 'akita',
          'fgp': 'google/akita/akita:15/AP2A.240805.005/12025142:user/release-keys',
          'tgs': 'release-keys',
          'd_ifv': _anonymousId.replaceAll('-', '').substring(0, 16),
        },
      );
      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map && decoded['cookie'] is String) {
          final cookieStr = decoded['cookie'] as String;
          final match = RegExp(r'datadome=([^;]+)').firstMatch(cookieStr);
          if (match != null) {
            datadomeCookie = match.group(1);
            appLogger.info(
              '[SoundCloudMobile] Acquired DataDome cookie: ${datadomeCookie?.substring(0, 15)}...',
            );
            return datadomeCookie;
          }
        }
      } else {
        appLogger.warning(
          '[SoundCloudMobile] DataDome SDK returned ${response.statusCode}: ${response.body}',
        );
      }
    } catch (e, st) {
      appLogger.warning(
        '[SoundCloudMobile] Failed to fetch DataDome cookie: $e',
        e,
        st,
      );
    }
    return null;
  }

  // Public Android application client ID observed in the supplied capture.
  static const mobileClientId = 'QOFuKCOeAXIph267vzqj3B1wb65cZVAQ';
  static const _apiHost = 'api-mobile.soundcloud.com';
  static const _mobileUserAgent =
      'SoundCloud/2026.10.08-release (Android 15.0.0; Google Pixel 8a)';

  SoundCloudMobileAuthorization createAuthorization() =>
      SoundCloudMobileAuthorization(
        clientId: mobileClientId,
        locale: language,
      );

  Future<SoundCloudMobileTokens> exchangeAuthorizationCode({
    required String code,
    required String codeVerifier,
  }) => _oauthToken({
    'grant_type': 'authorization_code',
    'client_id': mobileClientId,
    'code': code,
    'redirect_uri': SoundCloudMobileAuthorization.redirectUri,
    'code_verifier': codeVerifier,
  });

  Future<SoundCloudMobileTokens> refreshMobileToken(String refreshToken) =>
      _oauthToken({
        'grant_type': 'refresh_token',
        'client_id': mobileClientId,
        'refresh_token': refreshToken,
      });

  Future<SoundCloudMobileTokens> _oauthToken(Map<String, String> fields) async {
    final response = await _transport.post(
      Uri.https('api-auth.soundcloud.com', '/oauth/token', {
        'client_id': mobileClientId,
      }),
      headers: {
        'Accept': 'application/x-www-form-urlencoded',
        'User-Agent': _mobileUserAgent,
        'Authorization': 'ztQ_RKaMCPavrjcXvMT6t0STPQ0vU2cY4YKGVeLU6Iw',
        'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8',
      },
      body: fields,
    );
    return SoundCloudMobileTokens.fromResponse(response);
  }

  String _uuid() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }

  Map<String, String> _headers([String? token]) => {
    'Accept': 'application/json; charset=utf-8',
    'User-Agent': _mobileUserAgent,
    'app-environment': 'prod',
    'app-locale': language,
    'device-locale': deviceLocale,
    'Accept-Language': acceptLanguageHeader,
    'app-version': '376070',
    'App-Requested-Features':
        'api_ios_podcast=,api_ios_reduced_price=,api_ios_test=,api_test=,system_playlist_in_library=true',
    'apollographql-client-name': 'android',
    'apollographql-client-version': '376070',
    if (datadomeCookie != null && datadomeCookie!.isNotEmpty)
      'Cookie': 'datadome=$datadomeCookie',
    if (token ?? oauthToken case final value? when value.isNotEmpty)
      'Authorization': 'OAuth $value',
  };

  Future<http.Response> _request(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    String? token,
    bool followRedirects = true,
    String host = _apiHost,
    bool includeClientId = true,
  }) async {
    final queryMap = {
      if (includeClientId) 'client_id': mobileClientId,
      ...?query,
    };
    final uri = Uri.https(host, path, queryMap.isNotEmpty ? queryMap : null);
    final sentToken = token ?? oauthToken;

    if (datadomeCookie == null && host == _apiHost) {
      await ensureDataDomeCookie(uri.toString());
    }

    Future<http.Response> send(String? credential) async {
      final request = http.Request(method, uri)
        ..headers.addAll(_headers(credential))
        ..followRedirects = followRedirects;
      if (body != null) {
        request.headers['Content-Type'] = 'application/json';
        request.body = jsonEncode(body);
      }
      return http.Response.fromStream(await _transport.send(request));
    }

    appLogger.info('[SoundCloudMobile] HTTP request: $method $uri (token=${sentToken != null ? "yes" : "no"}, datadome=${datadomeCookie != null ? "yes" : "no"})');
    var response = await send(sentToken);
    appLogger.info('[SoundCloudMobile] HTTP response: ${response.statusCode} for $method $uri (len=${response.bodyBytes.length})');
    if (response.statusCode == 401 && sentToken != null) {
      String? fresh;
      try {
        fresh = await refreshAuthentication?.call(sentToken);
      } catch (_) {}
      if (fresh != null && fresh != sentToken && fresh.isNotEmpty) {
        if (oauthToken == sentToken) oauthToken = fresh;
        if (oauthToken == fresh) response = await send(fresh);
      }
    }
    final setCookie = response.headers['set-cookie'];
    if (setCookie != null && setCookie.contains('datadome=')) {
      final match = RegExp(r'datadome=([^;]+)').firstMatch(setCookie);
      if (match != null) {
        datadomeCookie = match.group(1);
      }
    }

    if (response.statusCode == 403 &&
        response.body.contains('captcha-delivery.com')) {
      appLogger.info(
        '[SoundCloudMobile] 403 CAPTCHA challenge encountered. Requesting fresh DataDome cookie...',
      );
      final refreshed = await fetchDataDomeCookie(uri.toString());
      if (refreshed != null) {
        appLogger.info(
          '[SoundCloudMobile] Retrying request with fresh DataDome cookie...',
        );
        response = await send(sentToken);
        final retrySetCookie = response.headers['set-cookie'];
        if (retrySetCookie != null && retrySetCookie.contains('datadome=')) {
          final match = RegExp(r'datadome=([^;]+)').firstMatch(retrySetCookie);
          if (match != null) {
            datadomeCookie = match.group(1);
          }
        }
        if (response.statusCode < 400) {
          appLogger.info(
            '[SoundCloudMobile] Retry succeeded with HTTP ${response.statusCode}',
          );
          return response;
        }
      }
    }

    if (response.statusCode >= 400) {
      appLogger.warning(
        '[SoundCloudMobile] HTTP error ${response.statusCode} for $method $uri: ${response.body.length > 500 ? response.body.substring(0, 500) : response.body}',
      );
    }
    if (response.statusCode == 403 &&
        response.body.contains('captcha-delivery.com')) {
      throw const SoundCloudChallengeException(
        'SoundCloud rejected this mobile action with a CAPTCHA challenge. '
        'Sign in again and retry.',
      );
    }
    if (response.statusCode == 429) {
      throw const HttpException(
        'SoundCloud rate limit exceeded (HTTP 429). Please wait a moment before retrying.',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 400) {
      throw HttpException('SoundCloud mobile API HTTP ${response.statusCode}');
    }
    return response;
  }

  Future<dynamic> _json(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    String? token,
    String host = _apiHost,
    bool includeClientId = true,
  }) async {
    final response = await _request(
      method,
      path,
      query: query,
      body: body,
      token: token,
      host: host,
      includeClientId: includeClientId,
    );
    return response.body.isEmpty ? null : decodeJsonAsync(response.body);
  }

  String _urn(String kind, String id) {
    if (id.startsWith('soundcloud:')) return id;
    if (id.startsWith('system-playlists:')) return 'soundcloud:$id';
    return 'soundcloud:$kind:$id';
  }

  String _id(String urn) => urn.split(':').last;

  Map<String, dynamic> _user(Map source) {
    final result = Map<String, dynamic>.from(source);
    final urn = source['urn']?.toString() ?? '';
    result['id'] = int.tryParse(_id(urn)) ?? source['id'];
    result['permalink_url'] ??=
        source['permalinkUrl'] ??
        (source['permalink'] == null
            ? null
            : 'https://soundcloud.com/${source['permalink']}');
    result['avatar_url'] ??= source['avatarUrl'];
    result['username'] ??= source['name'];
    result['permalink_url'] ??= source['userPermalinkUrl'];
    result['followers_count'] ??= source['followersCount'];
    return result;
  }

  static String? formatArtworkUrl(
    String? template, {
    String fallbackSize = 'large',
  }) {
    if (template == null) return null;
    final size = template.contains('/labs-') ? 't500x500' : fallbackSize;
    return template.replaceAll('{size}', size);
  }

  Map<String, dynamic> _track(Map source) {
    final result = Map<String, dynamic>.from(source);
    result['id'] =
        int.tryParse(_id(source['urn']?.toString() ?? '')) ?? source['id'];
    final embedded = source['_embedded'];
    if (embedded is Map && embedded['user'] is Map) {
      result['user'] = _user(embedded['user'] as Map);
    } else if (source['user'] is Map) {
      result['user'] = _user(source['user'] as Map);
    }
    final trackIdStr = result['id']?.toString();
    if (trackIdStr != null) {
      final userObj = result['user'];
      if (userObj is Map && userObj['id'] != null) {
        _trackOwners[trackIdStr] = userObj['id'].toString();
      } else if (source['user_urn'] != null) {
        _trackOwners[trackIdStr] = _id(source['user_urn'].toString());
      }
      if (_trackOwners.length > 2000) {
        _trackOwners.remove(_trackOwners.keys.first);
      }
    }
    if (embedded is Map && embedded['stats'] is Map) {
      result.addAll(Map<String, dynamic>.from(embedded['stats'] as Map));
    }
    result['artwork_url'] ??= formatArtworkUrl(
      (source['artworkUrlTemplate'] ?? source['artwork_url_template'])
          ?.toString(),
    );
    result['permalink_url'] ??=
        source['permalinkUrl'] ??
        source['permalink_url'] ??
        (result['id'] != null
            ? 'https://soundcloud.com/tracks/${result['id']}'
            : 'https://soundcloud.com');
    result['duration'] ??= source['fullDuration'];
    result['full_duration'] ??= source['fullDuration'];
    return result;
  }

  Map<String, dynamic> _playlist(Map source) {
    final result = Map<String, dynamic>.from(source);
    final urn = (source['urn'] ?? source['target_urn'])?.toString() ?? '';
    result['urn'] ??= urn;
    result['id'] = urn.startsWith('soundcloud:system-playlists:')
        ? urn
        : int.tryParse(_id(urn)) ?? source['id'];
    final embedded = source['_embedded'];
    if (embedded is Map && embedded['user'] is Map) {
      result['user'] = _user(embedded['user'] as Map);
    } else if (source['user'] is Map) {
      result['user'] = _user(source['user'] as Map);
    } else if (source['user_urn'] != null) {
      final userUrn = source['user_urn'].toString();
      result['user'] = {
        'id': int.tryParse(_id(userUrn)) ?? _id(userUrn),
        'urn': userUrn,
        'username': source['user_tag'] ?? 'SoundCloud',
      };
    }
    if (embedded is Map && embedded['stats'] is Map) {
      result.addAll(Map<String, dynamic>.from(embedded['stats'] as Map));
    }
    result['permalink_url'] ??= source['permalinkUrl'];
    result['permalink_url'] ??= 'https://soundcloud.com';

    final rawArtwork = source['artwork_url']?.toString();
    final template = (source['artworkUrlTemplate'] ??
            source['artwork_url_template'] ??
            source['playlistArtworkUrlTemplate'])
        ?.toString();
    final formatted = formatArtworkUrl(template);
    if (rawArtwork != null && rawArtwork.trim().isNotEmpty) {
      result['artwork_url'] = rawArtwork.trim();
    } else if (formatted != null && formatted.trim().isNotEmpty) {
      result['artwork_url'] = formatted.trim();
    } else {
      result['artwork_url'] = null;
    }

    final title = source['title']?.toString() ??
        source['playlistTitle']?.toString() ??
        '';
    result['title'] = title;
    if (title.startsWith('Related tracks: ')) {
      result['short_title'] ??= title.substring('Related tracks: '.length);
    }

    result['description'] ??=
        source['playlistDescription'] ?? source['description'];
    if (source['is_album'] != null) {
      result['is_album'] = source['is_album'];
    }
    if (source['set_type'] != null) {
      result['set_type'] = source['set_type'];
    }
    if (result['is_album'] == null &&
        (source['set_type'] == 'album' || source['set_type'] == 'ep')) {
      result['is_album'] = true;
    }
    return result;
  }

  Map<String, dynamic> _page(dynamic raw, String kind) {
    final List items;
    String? next;
    if (raw is List) {
      items = raw;
    } else if (raw is Map) {
      items = raw['collection'] is List ? raw['collection'] as List : [];
      final links = raw['_links'];
      next = (links is Map && links['next'] is Map
              ? (links['next'] as Map)['href']?.toString()
              : null) ??
          raw['next_href']?.toString() ??
          raw['next']?.toString();
    } else {
      return {'collection': <dynamic>[]};
    }
    return {
      'collection': items.map((item) {
        if (item is! Map) return item;
        if (kind == 'track') {
          final resource = item['track'] is Map ? item['track'] as Map : item;
          return _track(resource);
        }
        if (kind == 'playlist') {
          final resource = item['playlist'] is Map
              ? item['playlist'] as Map
              : item['playlist_post'] is Map
              ? item['playlist_post'] as Map
              : item;
          return _playlist(resource);
        }
        if (kind == 'user') {
          final resource = item['user'] is Map ? item['user'] as Map : item;
          return _user(resource);
        }
        final resource = item['track'] is Map
            ? item['track'] as Map
            : item['playlist'] is Map
            ? item['playlist'] as Map
            : item['playlist_post'] is Map
            ? item['playlist_post'] as Map
            : item['user'] is Map
            ? item['user'] as Map
            : item;
        return resource;
      }).toList(),
      'next_href': ?next,
    };
  }

  Future<Map<String, dynamic>> _fetchTracks(List<String> ids) async {
    return _fetchInBatches(ids, 'tracks', 100, 'track');
  }

  Future<Map<String, dynamic>> _fetchPlaylists(List<String> ids) async {
    return _fetchInBatches(ids, 'playlists', 50, 'playlist');
  }

  Future<Map<String, dynamic>> _fetchInBatches(
    List<String> ids,
    String resource,
    int batchSize,
    String kind,
  ) async {
    if (ids.isEmpty) return {'collection': <dynamic>[]};
    final byId = <String, Map<String, dynamic>>{};
    final batches = [
      for (var start = 0; start < ids.length; start += batchSize)
        ids.skip(start).take(batchSize).toList(),
    ];
    for (var start = 0; start < batches.length; start += 3) {
      final responses = await Future.wait(
        batches.skip(start).take(3).map(
          (batch) async {
            try {
              return await _json(
                'POST',
                '/$resource/fetch',
                body: {'urns': batch.map((id) => _urn(resource, id)).toList()},
              );
            } catch (error, stackTrace) {
              appLogger.warning(
                '[SoundCloudMobile] Failed to fetch batch for $resource '
                '(${batch.length} IDs)',
                error,
                stackTrace,
              );
              return null;
            }
          },
        ),
      );
      for (final raw in responses) {
        if (raw == null) continue;
        final page = _page(raw, kind);
        for (final item in (page['collection'] as List).whereType<Map>()) {
          final mapItem = Map<String, dynamic>.from(item);
          final id = mapItem['id']?.toString();
          final urn = mapItem['urn']?.toString();
          if (id != null) byId[id] = mapItem;
          if (urn != null) byId[urn] = mapItem;
        }
      }
    }
    return <String, dynamic>{
      'collection': [
        for (final id in ids)
          ?byId[id] ??
              byId[_id(id)] ??
              byId[_urn(resource, id)],
      ],
    };
  }

  Future<Map<String, dynamic>> _collectionUpdates(String kind) {
    if (_collectionSnapshotToken != oauthToken) {
      _collectionSnapshots.clear();
      _loadedCollectionSnapshots.clear();
      _collectionSnapshotTimes.clear();
      _collectionUpdateRequests.clear();
      _collectionSnapshotToken = oauthToken;
    }
    final updatedAt = _collectionSnapshotTimes[kind];
    if (_loadedCollectionSnapshots.contains(kind) &&
        updatedAt != null &&
        DateTime.now().difference(updatedAt) < const Duration(minutes: 2)) {
      return Future.value(_snapshotCollectionResult(kind));
    }
    final existing = _collectionUpdateRequests[kind];
    if (existing != null) return existing;
    late final Future<Map<String, dynamic>> request;
    request = _requestCollectionUpdates(kind).whenComplete(() {
      if (identical(_collectionUpdateRequests[kind], request)) {
        _collectionUpdateRequests.remove(kind);
      }
    });
    _collectionUpdateRequests[kind] = request;
    return request;
  }

  Future<Map<String, dynamic>> _requestCollectionUpdates(String kind) async {
    final short = kind == 'tracks' ? 'a' : 'b';
    final snapshot = _collectionSnapshots.putIfAbsent(
      kind,
      () => <String, Map<String, dynamic>>{},
    );
    final snapshotEntries = snapshot.values.toList();
    Map<String, dynamic> snapshotBody() => {
      'a': {
        short: snapshotEntries,
        kind: snapshotEntries,
      },
      'likes': {
        short: snapshotEntries,
        kind: snapshotEntries,
      },
    };
    final raw = await _json(
      'POST',
      '/you/update_collections/v2',
      body: {'a': snapshotBody(), 'snapshot': snapshotBody()},
    );
    final updates = raw is Map ? raw['collections_updates'] : null;
    final likes = updates is Map ? updates['likes'] : null;
    final entries = likes is Map && likes[kind] is List
        ? likes[kind] as List
        : <dynamic>[];
    for (final entry in entries.whereType<Map>()) {
      final urn = entry['target_urn']?.toString();
      if (urn == null) continue;
      if (entry['action'] == 'add') {
        snapshot[urn] = _collectionSnapshotEntry(
          urn,
          entry['updated_at']?.toString(),
        );
      }
      if (entry['action'] == 'remove') snapshot.remove(urn);
    }
    _loadedCollectionSnapshots.add(kind);
    _collectionSnapshotTimes[kind] = DateTime.now();
    return _snapshotCollectionResult(kind);
  }

  Map<String, dynamic> _snapshotCollectionResult(String kind) => {
    'collection': _collectionSnapshots[kind]?.keys.toList() ?? <String>[],
  };

  Map<String, dynamic> _collectionSnapshotEntry(
    String urn,
    String? updatedAt,
  ) {
    final normalized = (updatedAt ?? '')
        .replaceAll('/', '-')
        .replaceFirstMapped(
          RegExp(r'([+-]\d{2})(\d{2})$'),
          (match) => '${match[1]}:${match[2]}',
        );
    var timestamp = DateTime.tryParse(normalized);
    timestamp ??= DateTime.now().toUtc();
    final utc = timestamp.toUtc();
    final formatted = updatedAt ??
        '${utc.year.toString().padLeft(4, '0')}/'
            '${utc.month.toString().padLeft(2, '0')}/'
            '${utc.day.toString().padLeft(2, '0')} '
            '${utc.hour.toString().padLeft(2, '0')}:'
            '${utc.minute.toString().padLeft(2, '0')}:'
            '${utc.second.toString().padLeft(2, '0')} +0000';
    return {
      'a': urn,
      'b': formatted,
      'target_urn': urn,
      'timestamp': utc.toIso8601String(),
    };
  }

  void _updateCollectionSnapshot(String kind, String urn, {required bool add}) {
    if (_collectionSnapshotToken != oauthToken) {
      _collectionSnapshots.clear();
      _loadedCollectionSnapshots.clear();
      _collectionSnapshotTimes.clear();
      _collectionSnapshotToken = oauthToken;
    }
    final snapshot = _collectionSnapshots.putIfAbsent(
      kind,
      () => <String, Map<String, dynamic>>{},
    );
    if (add) {
      snapshot[urn] = _collectionSnapshotEntry(urn, null);
    } else {
      snapshot.remove(urn);
    }
    if (_loadedCollectionSnapshots.contains(kind)) {
      _collectionSnapshotTimes[kind] = DateTime.now();
    }
  }

  List<dynamic>? _cachedHistoryEntries;
  DateTime? _cachedHistoryTime;

  Future<Map<String, dynamic>> _historyPage([
    Map<String, dynamic>? query,
  ]) async {
    final offset = int.tryParse(query?['offset']?.toString() ?? '') ?? 0;
    final limit = int.tryParse(query?['limit']?.toString() ?? '') ?? 50;

    List<dynamic> entries;
    if (offset > 0 &&
        _cachedHistoryEntries != null &&
        _cachedHistoryTime != null &&
        DateTime.now().difference(_cachedHistoryTime!) <
            const Duration(minutes: 2)) {
      entries = _cachedHistoryEntries!;
    } else {
      final raw = await _json(
        'GET',
        '/recently-played/tracks',
      );
      entries = raw is Map && raw['collection'] is List
          ? raw['collection'] as List
          : <dynamic>[];
      _cachedHistoryEntries = entries;
      _cachedHistoryTime = DateTime.now();
    }

    final seen = <String>{};
    final uniqueUrns = <String>[];
    for (final item in entries.whereType<Map>()) {
      final urn = item['urn']?.toString();
      if (urn != null && urn.isNotEmpty && seen.add(urn)) {
        uniqueUrns.add(urn);
      }
    }

    final pageUrns = uniqueUrns.skip(offset).take(limit).toList();
    final fetched = await _fetchTracks(pageUrns);
    final byId = <String, Map<String, dynamic>>{};
    for (final item in (fetched['collection'] as List).whereType<Map>()) {
      final mapItem = Map<String, dynamic>.from(item);
      final id = mapItem['id']?.toString();
      final urn = mapItem['urn']?.toString();
      if (id != null) byId[id] = mapItem;
      if (urn != null) byId[urn] = mapItem;
    }

    final nextOffset = offset + pageUrns.length;
    final hasMore = nextOffset < uniqueUrns.length;
    final nextHref = hasMore
        ? 'https://$_apiHost/recently-played/tracks?offset=$nextOffset&limit=$limit'
        : null;

    appLogger.info(
      '[SoundCloudMobile] _historyPage: offset=$offset, limit=$limit, '
      'uniqueTotal=${uniqueUrns.length}, pageFetched=${pageUrns.length}, '
      'hasNext=${nextHref != null}',
    );

    final collection = <Map<String, dynamic>>[];
    for (final urn in pageUrns) {
      final item = byId[urn] ?? byId[_id(urn)];
      if (item != null) {
        collection.add(<String, dynamic>{
          ...item,
          'kind': 'track',
        });
      }
    }

    return <String, dynamic>{
      'collection': collection,
      'next_href': ?nextHref,
    };
  }

  Future<Map<String, dynamic>> _recentlyPlayedContextsPage([
    Map<String, dynamic>? query,
  ]) async {
    final queryParams = query?.map((k, v) => MapEntry(k, v.toString()));
    final raw = await _json(
      'GET',
      '/recently-played/contexts/v2',
      query: queryParams,
    );
    final entries = raw is Map && raw['collection'] is List
        ? raw['collection'] as List
        : <dynamic>[];
    final limit = int.tryParse(query?['limit']?.toString() ?? '') ?? 20;
    final urns = entries
        .whereType<Map>()
        .map((item) => item['urn']?.toString())
        .whereType<String>()
        .where((urn) => urn.isNotEmpty)
        .take(limit)
        .toList();

    if (urns.isEmpty) return {'collection': <dynamic>[]};

    final playlistUrns = <String>[];
    final trackUrns = <String>[];
    final systemPlaylistUrns = <String>[];
    final userUrns = <String>[];

    for (final urn in urns) {
      if (urn.startsWith('soundcloud:system-playlists:')) {
        systemPlaylistUrns.add(urn);
      } else if (urn.startsWith('soundcloud:playlists:')) {
        playlistUrns.add(urn);
      } else if (urn.startsWith('soundcloud:tracks:')) {
        trackUrns.add(urn);
      } else if (urn.startsWith('soundcloud:users:')) {
        userUrns.add(urn);
      }
    }

    final byUrn = <String, Map<String, dynamic>>{};
    final futures = <Future<void>>[];

    if (playlistUrns.isNotEmpty) {
      futures.add(() async {
        try {
          final res = await _fetchPlaylists(playlistUrns);
          for (final item in (res['collection'] as List? ?? []).whereType<Map>()) {
            final map = Map<String, dynamic>.from(item);
            final u = map['urn']?.toString() ??
                (map['id'] != null ? 'soundcloud:playlists:${map['id']}' : null);
            final id = map['id']?.toString();
            map['kind'] ??= 'playlist';
            if (u != null) byUrn[u] = map;
            if (id != null) byUrn[id] = map;
          }
        } catch (e) {
          appLogger.warning('Failed to batch fetch recently played playlists', e);
        }
      }());
    }

    if (trackUrns.isNotEmpty) {
      futures.add(() async {
        try {
          final res = await _fetchTracks(trackUrns);
          for (final item in (res['collection'] as List? ?? []).whereType<Map>()) {
            final map = Map<String, dynamic>.from(item);
            final u = map['urn']?.toString() ??
                (map['id'] != null ? 'soundcloud:tracks:${map['id']}' : null);
            final id = map['id']?.toString();
            map['kind'] ??= 'track';
            if (u != null) byUrn[u] = map;
            if (id != null) byUrn[id] = map;
          }
        } catch (e) {
          appLogger.warning('Failed to batch fetch recently played tracks', e);
        }
      }());
    }

    if (userUrns.isNotEmpty) {
      futures.add(() async {
        try {
          final res = await _fetchInBatches(userUrns, 'users', 50, 'user');
          for (final item in (res['collection'] as List? ?? []).whereType<Map>()) {
            final map = Map<String, dynamic>.from(item);
            final u = map['urn']?.toString() ??
                (map['id'] != null ? 'soundcloud:users:${map['id']}' : null);
            final id = map['id']?.toString();
            map['kind'] ??= 'user';
            if (u != null) byUrn[u] = map;
            if (id != null) byUrn[id] = map;
          }
        } catch (e) {
          appLogger.warning('Failed to batch fetch recently played users', e);
        }
      }());
    }

    for (final sysUrn in systemPlaylistUrns) {
      futures.add(() async {
        try {
          final rawInfo = await _json('GET', '/playlists/$sysUrn/info');
          if (rawInfo is Map && rawInfo['playlist'] is Map) {
            final playlistMap =
                Map<String, dynamic>.from(rawInfo['playlist'] as Map);
            final pl = _playlist(playlistMap);
            pl['kind'] = 'system-playlist';
            if (pl['artwork_url'] == null ||
                (pl['artwork_url'] as String).isEmpty) {
              final rawTracks = rawInfo['tracks'];
              final tracksColl =
                  rawTracks is Map && rawTracks['collection'] is List
                      ? rawTracks['collection'] as List
                      : rawTracks is List
                      ? rawTracks
                      : <dynamic>[];
              for (final t in tracksColl) {
                if (t is Map) {
                  final tArt = (t['artwork_url']?.toString().isNotEmpty == true
                          ? t['artwork_url'].toString()
                          : null) ??
                      formatArtworkUrl(
                        (t['artwork_url_template'] ??
                                t['artworkUrlTemplate'] ??
                                t['trackArtworkUrlTemplate'])
                            ?.toString(),
                      );
                  if (tArt != null && tArt.isNotEmpty) {
                    pl['artwork_url'] = tArt;
                    break;
                  }
                }
              }
            }
            byUrn[sysUrn] = pl;
            final id = pl['id']?.toString();
            if (id != null) byUrn[id] = pl;
          }
        } catch (e) {
          appLogger.warning('Failed to fetch system playlist info for $sysUrn', e);
        }
      }());
    }

    await Future.wait(futures);

    final results = <Map<String, dynamic>>[];
    for (final urn in urns) {
      final item = byUrn[urn] ??
          byUrn[_id(urn)] ??
          (urn.startsWith('soundcloud:playlists:')
              ? byUrn['soundcloud:playlists:${_id(urn)}']
              : null) ??
          (urn.startsWith('soundcloud:tracks:')
              ? byUrn['soundcloud:tracks:${_id(urn)}']
              : null);
      if (item != null) {
        results.add(item);
      }
    }

    final links = raw is Map ? raw['_links'] : null;
    final next = links is Map && links['next'] is Map
        ? (links['next'] as Map)['href']?.toString()
        : null;
    return {
      'collection': results,
      'next_href': ?next,
    };
  }

  List<String> _trackUrns(Iterable<String> ids) =>
      ids.map((id) => _urn('tracks', id)).toList();

  Map<String, dynamic> _playlistWriteBody(
    Map<String, dynamic> existing,
    List<String> trackIds, {
    String? title,
    String? description,
    bool? isPublic,
  }) {
    final urns = _trackUrns(trackIds);
    final resolvedTitle = title ?? existing['title']?.toString() ?? '';
    final resolvedDescription =
        description ?? existing['description']?.toString() ?? '';
    final resolvedGenre = existing['genre']?.toString() ?? '';
    final resolvedPublic = isPublic ?? existing['sharing'] != 'private';
    final tags = existing['user_tags'];
    final tagList =
        existing['tag_list']?.toString() ??
        (tags is List ? tags.map((tag) => tag.toString()).join(' ') : '');
    return {
      'track_urns': urns,
      'description': resolvedDescription,
      'title': resolvedTitle,
      'genre': resolvedGenre,
      'public': resolvedPublic,
      'tag_list': tagList,
      // The Android client sends these aliases alongside the named fields.
      'a': urns,
      'b': resolvedDescription,
      'c': resolvedTitle,
      'd': resolvedGenre,
      'e': resolvedPublic,
      'f': tagList,
    };
  }

  Future<String> createPlaylistNative(
    String title, {
    required bool isPublic,
    String description = '',
    List<String> trackIds = const [],
  }) async {
    final raw = await _json(
      'POST',
      '/playlists',
      body: {
        'playlist': {'title': title, 'public': isPublic},
        'track_urns': _trackUrns(trackIds),
      },
    );
    final playlist = raw is Map ? raw['playlist'] : null;
    final urn = playlist is Map ? playlist['urn']?.toString() : null;
    if (urn == null || !urn.startsWith('soundcloud:playlists:')) {
      throw const FormatException(
        'SoundCloud playlist creation returned no ID',
      );
    }
    if (description.isNotEmpty) {
      await updatePlaylistNative(
        _id(urn),
        Map<String, dynamic>.from(playlist as Map),
        trackIds,
        title: title,
        description: description,
        isPublic: isPublic,
      );
    }
    return _id(urn);
  }

  Future<void> updatePlaylistNative(
    String id,
    Map<String, dynamic> existing,
    List<String> trackIds, {
    String? title,
    String? description,
    bool? isPublic,
  }) async {
    await _json(
      'PUT',
      '/playlists/${_urn('playlists', id)}',
      body: _playlistWriteBody(
        existing,
        trackIds,
        title: title,
        description: description,
        isPublic: isPublic,
      ),
    );
  }

  Future<void> editPlaylistTrackNative(
    String playlistId,
    String trackId, {
    required bool add,
    required Map<String, dynamic> existing,
    required List<String> trackIds,
  }) async {
    final playlistUrn = _urn('playlists', playlistId);
    final trackUrn = _urn('tracks', trackId);
    await _json(
      add ? 'POST' : 'DELETE',
      add
          ? '/playlists/$playlistUrn/tracks'
          : '/playlists/$playlistUrn/tracks/$trackUrn',
      body: add ? {'track_urn': trackUrn} : null,
    );
    await updatePlaylistNative(playlistId, existing, trackIds);
  }

  Future<void> deletePlaylistNative(String id) async {
    await _json('DELETE', '/playlists/${_urn('playlists', id)}');
  }

  Future<void> logListenNative(
    String trackId, {
    required String userId,
    String? trackOwnerId,
    String? contextUrn,
    bool recordContext = true,
    DateTime? startedAt,
    Duration? listenDuration,
    Duration? position,
    Duration? trackDuration,
    String? format,
    bool isNext = false,
  }) async {
    final now = DateTime.now();
    final started = startedAt ?? now.subtract(listenDuration ?? Duration.zero);
    final queueId = _uuid();
    final playId = _uuid();
    final cleanTrackId = _id(trackId);
    final owner = trackOwnerId ?? _trackOwners[cleanTrackId] ?? userId;
    final trackOwnerUrn = _urn('users', owner);
    final validContextUrn = (contextUrn != null &&
            !contextUrn.startsWith('http') &&
            contextUrn.isNotEmpty)
        ? _urn('playlists', contextUrn)
        : null;
    final contextParts = validContextUrn?.split(':');
    final source = contextParts == null
        ? 'track'
        : contextParts.length > 2 && contextParts[1] == 'system-playlists'
        ? contextParts[2]
        : 'playlist';
    final protocol = format?.toUpperCase().contains('HLS') == true
        ? 'hls'
        : 'progressive';
    final preset = switch (format?.toUpperCase()) {
      'HLS' => 'aac_96k',
      'MP3' || 'MP3_128' => 'mp3_128k',
      'MP3_320' => 'mp3_320k',
      'FLAC' => 'flac',
      _ => 'aac_96k',
    };
    final base = <String, dynamic>{
      'app_version': '376070',
      'playlist_position': 0,
      'queue_source_id': queueId,
      'preset': preset,
      'source': source,
      'client_id': 3152,
      'local_storage_playback': false,
      'protocol': protocol,
      'page_name': validContextUrn == null ? 'tracks:main' : 'playlists:main',
      'track': _urn('tracks', cleanTrackId),
      'track_owner': trackOwnerUrn,
      'queue_id': queueId,
      'app_state': 'foreground',
      'track_length': trackDuration?.inMilliseconds ?? 0,
      'session_id': _telemetrySessionId,
      'trigger': isNext ? 'auto' : 'manual',
      'in_playlist': ?validContextUrn,
      'player_type': 'Saturn',
      'quality': 'sq',
      'consumer_subs_plan': 'none',
      'anonymous_id': _anonymousId,
      'user': _urn('users', userId),
      'page_urn': ?validContextUrn,
    };
    Map<String, dynamic> event(String action, DateTime at, int position) => {
      'event': 'audio',
      'event-id': _uuid(),
      'version': 'v1.27.45',
      'payload': {
        ...base,
        'playhead_position': position,
        'client_event_id': _uuid(),
        'action': action,
        if (action != 'play_start') 'play_id': playId,
        'ts': at.millisecondsSinceEpoch,
      },
    };

    Object? telemetryError;
    try {
      await _json(
        'POST',
        '/v1/events',
        host: 'telemetry.soundcloud.com',
        includeClientId: false,
        body: {
          'events': [
            event('play_start', started, 0),
            event(
              'checkpoint',
              now,
              position?.inMilliseconds ?? listenDuration?.inMilliseconds ?? 0,
            ),
          ],
          'sent_at': now.toUtc().toIso8601String(),
        },
      );
    } catch (e, st) {
      appLogger.warning(
        '[SoundCloudMobile] Telemetry event logging failed: $e',
        e,
        st,
      );
      telemetryError = e;
    }

    if (recordContext && validContextUrn != null) {
      try {
        await _json(
          'POST',
          '/recently-played/contexts/v2',
          body: {
            'collection': [
              {'played_at': started.millisecondsSinceEpoch, 'urn': validContextUrn},
            ],
            '_links': <String, dynamic>{},
            'query_urn': null,
            'nextPageLink': null,
            'queryUrn': null,
            'nextLink': null,
          },
        );
      } catch (e, st) {
        appLogger.warning(
          '[SoundCloudMobile] Failed to record recently played context: $e',
          e,
          st,
        );
      }
    }

    _cachedHistoryEntries = null;
    if (telemetryError != null) {
      throw telemetryError;
    }
  }

  Future<Map<String, dynamic>> _profile(String userId) async {
    final raw = await _json(
      'GET',
      '/users/${_urn('users', userId)}/profile/v2',
      query: {
        'playlistsFirstPageLimit': '50',
        'tracksFirstPageLimit': '50',
      },
    );
    return Map<String, dynamic>.from(raw as Map);
  }

  Future<Map<String, dynamic>> _search(
    String query,
    int limit, {
    String? contentType,
  }) async {
    if (contentType == null) {
      final perCategoryLimit = (limit / 2).ceil().clamp(10, 30);
      final results = await Future.wait([
        _search(query, perCategoryLimit, contentType: 'TRACKS').catchError(
          (_) => <String, dynamic>{'collection': <dynamic>[]},
        ),
        _search(query, perCategoryLimit, contentType: 'USERS').catchError(
          (_) => <String, dynamic>{'collection': <dynamic>[]},
        ),
        _search(
          query,
          perCategoryLimit,
          contentType: 'PLAYLISTS_WITHOUT_ALBUMS',
        ).catchError((_) => <String, dynamic>{'collection': <dynamic>[]}),
        _search(query, perCategoryLimit, contentType: 'ALBUMS').catchError(
          (_) => <String, dynamic>{'collection': <dynamic>[]},
        ),
      ]);
      final combined = <Map<String, dynamic>>[];
      for (final r in results) {
        combined.addAll(
          (r['collection'] as List? ?? []).whereType<Map<String, dynamic>>(),
        );
      }
      return {'collection': combined};
    }

    final raw = await _json(
      'GET',
      '/search/query',
      query: {
        'q': query,
        'limit': '$limit',
        'version': 'v10',
        'device_time': DateTime.now().toIso8601String(),
        'tcf_version': '2.3',
        'filter.content_type': contentType,
      },
    );
    if (raw is! Map) return {'collection': <dynamic>[]};
    final entities = raw['entities'];
    if (entities is! Map) return {'collection': <dynamic>[]};
    final collection = <Map<String, dynamic>>[];
    for (final entry in entities.entries) {
      if (entry.value is! Map) continue;
      final wrapper = entry.value as Map;
      final value = wrapper['data'] is Map ? wrapper['data'] as Map : wrapper;
      final urn = (value['urn'] ?? entry.key).toString();
      if (urn.startsWith('soundcloud:tracks:')) {
        collection.add({..._track(value), 'kind': 'track'});
      } else if (urn.startsWith('soundcloud:playlists:')) {
        final playlist = _playlist(value);
        if (contentType == 'ALBUMS') {
          playlist['is_album'] = true;
        }
        collection.add({...playlist, 'kind': 'playlist'});
      } else if (urn.startsWith('soundcloud:users:')) {
        collection.add({..._user(value), 'kind': 'user'});
      }
    }
    return {'collection': collection};
  }

  Future<Map<String, dynamic>> _feed({
    required bool discover,
    String? page,
  }) async {
    final response = await _request(
      'POST',
      '/graphql',
      host: 'graph.soundcloud.com',
      body: {
        'query': discover
            ? soundCloudDiscoverFeedQuery
            : soundCloudFollowingFeedQuery,
        if (!discover)
          'variables': {
            'page': page,
            'includePromoted': true,
            'includePlaylists': true,
            'first': 50,
          },
      },
    );
    final raw = await decodeJsonAsync(response.body);
    if (raw is! Map || raw['data'] is! Map) {
      throw const FormatException('SoundCloud feed is missing data');
    }
    final feed =
        (raw['data'] as Map)[discover ? 'discoverFeed' : 'followingFeed'];
    final items = feed is Map && feed['items'] is List
        ? feed['items'] as List
        : <dynamic>[];
    if (discover) {
      final sectionsMap = <String, List<Map<String, dynamic>>>{};
      for (final item in items.whereType<Map>()) {
        final event = item['event'];
        if (event is! Map || event['__typename'] != 'Track') continue;
        final transcodings = event['transcodings'] is List
            ? (event['transcodings'] as List).whereType<Map>().map((entry) {
                final format = entry['format'] is Map
                    ? entry['format'] as Map
                    : <String, dynamic>{};
                return {
                  ...Map<String, dynamic>.from(entry),
                  'format': {
                    ...Map<String, dynamic>.from(format),
                    'mime_type': format['mimeType'] ?? format['mime_type'],
                  },
                };
              }).toList()
            : <Map<String, dynamic>>[];
        final counts = event['counts'] is Map ? event['counts'] as Map : {};
        final track = _track({
          ...Map<String, dynamic>.from(event),
          'duration': event['fullDuration'],
          'full_duration': event['fullDuration'],
          'media': {'transcodings': transcodings},
          'user': event['user'],
          'artwork_url': formatArtworkUrl(
            event['artworkUrlTemplate']?.toString(),
          ),
          'likes_count': counts['likes'],
          'publisher_metadata':
              event['publisherMetadata'] ?? event['publisher_metadata'],
        });
        final reason = (item['reasonText'] as String?)?.trim();
        final sectionTitle =
            (reason != null && reason.isNotEmpty) ? reason : 'Discover';
        sectionsMap.putIfAbsent(sectionTitle, () => []).add({
          ...track,
          'kind': 'track',
        });
      }
      return {
        'collection': [
          for (final entry in sectionsMap.entries)
            {
              'title': entry.key,
              'items': {
                'collection': entry.value,
              },
            },
        ],
      };
    }

    final tracks = <Map<String, dynamic>>[];
    for (final item in items.whereType<Map>()) {
      final event = item['item'];
      if (event is! Map || event['__typename'] != 'Track') continue;
      final transcodings = event['transcodings'] is List
          ? (event['transcodings'] as List).whereType<Map>().map((entry) {
              final format = entry['format'] is Map
                  ? entry['format'] as Map
                  : <String, dynamic>{};
              return {
                ...Map<String, dynamic>.from(entry),
                'format': {
                  ...Map<String, dynamic>.from(format),
                  'mime_type': format['mimeType'] ?? format['mime_type'],
                },
              };
            }).toList()
          : <Map<String, dynamic>>[];
      final counts = event['counts'] is Map ? event['counts'] as Map : {};
      tracks.add(
        _track({
          ...Map<String, dynamic>.from(event),
          'duration': event['fullDuration'],
          'full_duration': event['fullDuration'],
          'media': {'transcodings': transcodings},
          'user': event['user'],
          'artwork_url': formatArtworkUrl(
            event['artworkUrlTemplate']?.toString(),
          ),
          'likes_count': counts['likes'],
          'publisher_metadata':
              event['publisherMetadata'] ?? event['publisher_metadata'],
        }),
      );
    }
    final nextPage = feed is Map && feed['page'] is Map
        ? feed['page']['nextPage']?.toString()
        : null;
    return {
      'collection': tracks.map((track) => {'track': track}).toList(),
      if (nextPage != null && nextPage.isNotEmpty)
        'next_href': '/stream?page=${Uri.encodeQueryComponent(nextPage)}',
    };
  }

  Map<String, dynamic>? _homeItem(Map source) {
    if (source['__typename'] == 'Track') {
      return <String, dynamic>{
        ..._track({
          ...Map<String, dynamic>.from(source),
          'title': source['trackTitle'],
          'permalink_url': source['trackPermalinkUrl'],
          'artwork_url': formatArtworkUrl(
            source['trackArtworkUrlTemplate']?.toString(),
          ),
          'duration': source['fullDuration'],
          'full_duration': source['fullDuration'],
          'user': source['trackUser'],
          'media': {'transcodings': source['transcodings'] ?? []},
          'publisher_metadata':
              source['publisherMetadata'] ?? source['publisher_metadata'],
        }),
        'kind': 'track',
      };
    }
    if (source['__typename'] == 'Playlist') {
      final urn = source['urn']?.toString() ?? '';
      final title = source['playlistTitle']?.toString() ?? '';
      return <String, dynamic>{
        ..._playlist({
          ...Map<String, dynamic>.from(source),
          'title': title,
          'permalink_url': source['playlistPermalinkUrl'],
          'artwork_url': formatArtworkUrl(
            source['playlistArtworkUrlTemplate']?.toString(),
          ),
          'track_count': source['trackCount'],
          'user': source['playlistUser'],
          'is_album': source['playlistType'] == 'ALBUM',
          'description':
              source['playlistDescription'] ?? source['description'],
        }),
        'kind': urn.startsWith('soundcloud:system-playlists:')
            ? 'system-playlist'
            : 'playlist',
        if (title.startsWith('Related tracks: '))
          'short_title': title.substring('Related tracks: '.length),
      };
    }
    return null;
  }

  Future<Map<String, dynamic>> _home() async {
    final raw = await _json(
      'POST',
      '/graphql',
      host: 'graph.soundcloud.com',
      body: {
        'operationName': 'HomeSduiQuery',
        'variables': {
          'input': {
            'useLiteLayout': true,
            'actionParams': null,
            'after': null,
            'first': null,
          },
        },
        'extensions': {
          'persistedQuery': {
            'version': 1,
            'sha256Hash':
                'cdd54c6bb8c0fe7cc5e3c99c74fa5f3dfa28533bd3430fa542ddc0661650ab91',
          },
        },
      },
    );
    final data = raw is Map ? raw['data'] : null;
    final home = data is Map ? data['homeSdui'] : null;
    if (home is! Map || home['sections'] is! List) {
      throw const FormatException('SoundCloud mobile home is missing sections');
    }
    final sections = home['sections'] as List;
    final collection = <Map<String, dynamic>>[];
    for (final section in sections.whereType<Map>()) {
      if (section['results'] is! List) continue;
      final isShortcuts = section['__typename'] == 'ShortcutsSection';
      final title = isShortcuts ? 'Recently played' : section['title'];
      if ((title is! String || title.isEmpty) && !isShortcuts) continue;

      List<Map<String, dynamic>> itemsList = [];
      if (isShortcuts) {
        try {
          final contexts = await _recentlyPlayedContextsPage({'limit': 20});
          final contextItems = (contexts['collection'] as List? ?? [])
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
          if (contextItems.isNotEmpty) {
            itemsList = contextItems;
          }
        } catch (e) {
          appLogger.warning('Failed to fetch recently played contexts', e);
        }
        if (itemsList.isEmpty) {
          try {
            final history = await _historyPage({'limit': 20});
            final historyItems = (history['collection'] as List? ?? [])
                .whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e))
                .toList();
            if (historyItems.isNotEmpty) {
              itemsList = historyItems;
            }
          } catch (e) {
            appLogger.warning('Failed to fetch full recently played history', e);
          }
        }
      }

      if (itemsList.isEmpty) {
        itemsList = [
          for (final wrapper in section['results'] as List)
            if (wrapper is Map)
              ?_homeItem(
                wrapper['result'] is Map
                    ? wrapper['result'] as Map
                    : wrapper,
              ),
        ];
      }

      final itemsPerColumn = section['itemsPerColumn'];
      collection.add(<String, dynamic>{
        'title': title,
        '__typename': section['__typename'],
        'items_per_column': itemsPerColumn,
        'layout': section['__typename'] == 'ContentWallSection' ||
                (itemsPerColumn is num && itemsPerColumn > 1)
            ? 'GRID_ROW'
            : 'ROW',
        'items': <String, dynamic>{
          'collection': itemsList,
        },
      });
    }
    return <String, dynamic>{'collection': collection};
  }

  @override
  Future<Map<String, dynamic>?> accountForToken(String token) async {
    final raw = await _json('GET', '/me', token: token);
    final user =
        raw is Map && raw['user'] is Map ? _user(raw['user'] as Map) : null;
    if (user != null && user['id'] != null) {
      currentUserId ??= user['id'].toString();
    }
    return user;
  }

  @override
  Future<dynamic> get(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) async {
    final query = queryParameters ?? const <String, dynamic>{};
    if (path == '/me') return (await accountForToken(oauthToken ?? '')) ?? {};
    if (path == '/tracks') {
      return _fetchTracks((query['ids']?.toString() ?? '').split(','));
    }
    final trackMatch = RegExp(r'^/tracks/(\d+)$').firstMatch(path);
    if (trackMatch != null) {
      final page = await _fetchTracks([trackMatch.group(1)!]);
      final items = page['collection'] as List;
      if (items.isEmpty) {
        throw const FormatException('SoundCloud track missing');
      }
      return items.first;
    }
    final relatedMatch = RegExp(r'^/tracks/(\d+)/related$').firstMatch(path);
    if (relatedMatch != null) {
      final stationUrn =
          'soundcloud:system-playlists:track-stations:${relatedMatch.group(1)}';
      final raw = await _json('GET', '/playlists/$stationUrn/info');
      final tracks = raw is Map ? raw['tracks'] : null;
      final page = _page(tracks, 'track');
      page['collection'] = (page['collection'] as List)
          .where(
            (track) =>
                track is Map &&
                track['id']?.toString() != relatedMatch.group(1),
          )
          .toList();
      return page;
    }
    final playlistMatch = RegExp(
      r'^/(?:system-playlists|playlists)/(.+)$',
    ).firstMatch(path);
    if (playlistMatch != null) {
      final urn = _urn('playlists', playlistMatch.group(1)!);
      final raw = await _json('GET', '/playlists/$urn/info');
      if (raw is! Map || raw['playlist'] is! Map) {
        throw const FormatException('SoundCloud playlist missing');
      }
      final playlist = _playlist(raw['playlist'] as Map);
      final tracks = raw['tracks'];
      final allTracks = <dynamic>[];
      dynamic page = _page(tracks, 'track');
      for (var index = 0; index < 100; index++) {
        allTracks.addAll((page['collection'] as List).whereType<Map>());
        final next = page['next_href']?.toString();
        if (next == null || next.isEmpty) break;
        page = await getNext(next);
      }
      playlist['tracks'] = allTracks;
      return playlist;
    }
    final posted = RegExp(
      r'^/users/(\d+)/(albums|playlists)$',
    ).firstMatch(path);
    if (posted != null) {
      final section = posted.group(2)!;
      final userId = posted.group(1)!;
      final results = <Map<String, dynamic>>[];
      final seen = <String>{};

      final isSelf = (currentUserId != null && currentUserId == userId) ||
          path.contains('/me/');
      if ((isSelf || currentUserId == null) && oauthToken != null) {
        try {
          final rawPosts =
              await _json('GET', '/you/posts_and_reposts/playlists');
          if (rawPosts is Map && rawPosts['collection'] is List) {
            final urnsToFetch = <String>[];
            for (final item
                in (rawPosts['collection'] as List).whereType<Map>()) {
              final post = item['playlist_post'] is Map
                  ? item['playlist_post'] as Map
                  : item;
              final targetUrn =
                  post['target_urn']?.toString() ?? post['urn']?.toString();
              final playlistMap =
                  post['playlist'] is Map ? post['playlist'] as Map : null;
              if (playlistMap != null) {
                final ownerUrn = playlistMap['user_urn']?.toString() ??
                    (playlistMap['user'] is Map
                        ? playlistMap['user']['urn']?.toString()
                        : null);
                final ownerId = ownerUrn != null ? _id(ownerUrn) : null;
                if (ownerId != null && ownerId != userId) continue;
                final mapped = _playlist(playlistMap);
                final id = mapped['id']?.toString();
                final isAlbum = mapped['is_album'] == true ||
                    mapped['set_type'] == 'album' ||
                    mapped['set_type'] == 'ep';
                if (section == 'albums' ? isAlbum : !isAlbum) {
                  if (id != null && seen.add(id)) {
                    results.add(mapped);
                  }
                }
              } else if (targetUrn != null) {
                urnsToFetch.add(targetUrn);
              }
            }
            if (urnsToFetch.isNotEmpty) {
              final fetched =
                  await _fetchPlaylists(urnsToFetch.map(_id).toList());
              for (final p
                  in (fetched['collection'] as List).whereType<Map>()) {
                final ownerUrn = p['user_urn']?.toString() ??
                    (p['user'] is Map ? p['user']['urn']?.toString() : null);
                final ownerId = ownerUrn != null ? _id(ownerUrn) : null;
                if (ownerId != null && ownerId != userId) continue;
                final id = p['id']?.toString();
                final isAlbum = p['is_album'] == true ||
                    p['set_type'] == 'album' ||
                    p['set_type'] == 'ep';
                if (section == 'albums' ? isAlbum : !isAlbum) {
                  if (id != null && seen.add(id)) {
                    results.add(Map<String, dynamic>.from(p));
                  }
                }
              }
            }
          }
        } catch (e) {
          appLogger.warning(
            'Failed to load /you/posts_and_reposts/playlists',
            e,
          );
        }
      }

      try {
        final raw = await _json(
          'GET',
          '/users/${_urn('users', userId)}/$section/posted',
          query: {'limit': '${query['limit'] ?? 50}'},
        );
        final page = _page(raw, 'playlist');
        for (final p in (page['collection'] as List).whereType<Map>()) {
          final id = p['id']?.toString();
          if (id != null && seen.add(id)) {
            if (section == 'albums') {
              p['is_album'] = true;
            }
            results.add(Map<String, dynamic>.from(p));
          }
        }
      } catch (e) {
        appLogger.warning('Failed to load /users/$userId/$section/posted', e);
      }

      return {'collection': results};
    }
    final userMatch = RegExp(
      r'^/users/(\d+)(?:/(tracks|top_tracks|toptracks))?$',
    ).firstMatch(path);
    if (userMatch != null) {
      final userId = userMatch.group(1)!;
      final section = userMatch.group(2);
      if (section == null) {
        final profile = await _profile(userId);
        return _user(profile['user'] as Map);
      }
      if (section == 'tracks' ||
          section == 'top_tracks' ||
          section == 'toptracks') {
        try {
          final webPath = (section == 'top_tracks' || section == 'toptracks')
              ? '/users/$userId/toptracks'
              : '/users/$userId/tracks';
          final webResp = await super.get(webPath, queryParameters: query);
          if (webResp is Map &&
              webResp['collection'] is List &&
              (webResp['collection'] as List).isNotEmpty) {
            return _page(webResp, 'track');
          }
        } catch (_) {}
      }
      final profile = await _profile(userId);
      if (section == 'top_tracks' || section == 'toptracks') {
        final top = _page(profile['top_tracks'], 'track');
        if ((top['collection'] as List).isNotEmpty) return top;
        return _page(profile['tracks'], 'track');
      }
      return _page(profile[section], 'track');
    }
    final relatedArtistsMatch = RegExp(
      r'^(?:/related-artists/(?:soundcloud:users:)?(\d+)|/users/(\d+)/related-artists)$',
    ).firstMatch(path);
    if (relatedArtistsMatch != null) {
      final userId = relatedArtistsMatch.group(1) ?? relatedArtistsMatch.group(2)!;
      final raw = await _json(
        'GET',
        '/related-artists/soundcloud:users:$userId',
        query: {'limit': '${query['limit'] ?? 30}'},
      );
      return _page(raw, 'user');
    }
    final artistStationMatch =
        RegExp(r'^/users/(\d+)/station$').firstMatch(path);
    if (artistStationMatch != null) {
      final stationUrn =
          'soundcloud:system-playlists:artist-stations:${artistStationMatch.group(1)}';
      final raw = await _json('GET', '/playlists/$stationUrn/info');
      final tracks = raw is Map ? raw['tracks'] : null;
      return _page(tracks, 'track');
    }
    if (path == '/search') {
      final filter = query['filter']?.toString().toLowerCase();
      String? contentType;
      if (filter == 'tracks') {
        contentType = 'TRACKS';
      } else if (filter == 'users' || filter == 'artists') {
        contentType = 'USERS';
      } else if (filter == 'playlists') {
        contentType = 'PLAYLISTS_WITHOUT_ALBUMS';
      } else if (filter == 'albums') {
        contentType = 'ALBUMS';
      }
      return _search(
        query['q']?.toString() ?? '',
        (query['limit'] as num?)?.toInt() ?? 30,
        contentType: contentType,
      );
    }
    if (path == '/stream') {
      return _feed(discover: false, page: query['page']?.toString());
    }
    if (path == '/discover-feed') return _feed(discover: true);
    if (path == '/mixed-selections') {
      if (query['web'] == true || query['web'] == 'true') {
        return super.get(path, queryParameters: queryParameters);
      }
      try {
        return await _home();
      } catch (_) {
        return super.get(path, queryParameters: queryParameters);
      }
    }
    if (path == '/search/queries') {
      final raw = await _json(
        'GET',
        '/search/autocomplete',
        query: {'query': query['q']?.toString() ?? '', 'limit': '10'},
      );
      return _page(raw, 'raw');
    }
    final following = RegExp(
      r'^/users/\d+/followings(?:/ids)?$',
    ).firstMatch(path);
    if (following != null) {
      final raw = await _json('GET', '/you/followings');
      final urns =
          (raw is Map && raw['collection'] is List
                  ? raw['collection'] as List
                  : <dynamic>[])
              .whereType<Map>()
              .map((item) => item['target']?.toString())
              .whereType<String>()
              .toList();
      if (path.endsWith('/ids')) {
        return <String, dynamic>{'collection': urns.map(_id).toList()};
      }
      final users = await _json('POST', '/users/fetch', body: {'urns': urns});
      return _page(users, 'user');
    }
    if (path == '/me/track_likes/ids' ||
        path == '/me/playlist_likes/ids' ||
        path == '/me/system_playlist_likes/urns') {
      final kind = path.contains('track') ? 'tracks' : 'playlists';
      final likes = await _collectionUpdates(kind);
      final urns = likes['collection'] as List<String>;
      return <String, dynamic>{
        'collection': path.contains('system_playlist')
            ? urns
                  .where(
                    (urn) => urn.startsWith('soundcloud:system-playlists:'),
                  )
                  .toList()
            : path.contains('playlist')
            ? urns
                  .where(
                    (urn) => !urn.startsWith('soundcloud:system-playlists:'),
                  )
                  .map(_id)
                  .toList()
            : urns.map(_id).toList(),
      };
    }
    if (RegExp(r'^/users/\d+/track_likes$').hasMatch(path)) {
      final likes = await _collectionUpdates('tracks');
      final urns = likes['collection'] as List<String>;
      final hasPagination = query.containsKey('offset') || query.containsKey('limit');
      final offset = int.tryParse(query['offset']?.toString() ?? '') ?? 0;
      final limit = int.tryParse(query['limit']?.toString() ?? '') ?? 50;
      final pageUrns = hasPagination
          ? urns.skip(offset).take(limit).toList()
          : urns;
      final ids = pageUrns.map(_id).toList();
      final tracks = await _fetchTracks(ids);
      return <String, dynamic>{
        'collection': (tracks['collection'] as List)
            .whereType<Map>()
            .map((track) => <String, dynamic>{
                  ...Map<String, dynamic>.from(track),
                  'user_favorite': true,
                })
            .toList(),
        if (hasPagination && offset + pageUrns.length < urns.length)
          'next_href': Uri.https(_apiHost, path, {
            'offset': '${offset + limit}',
            'limit': '$limit',
          }).toString(),
      };
    }
    if (RegExp(
      r'^/users/\d+/(?:playlist_likes|playlists/liked_and_owned)$',
    ).hasMatch(path)) {
      final likes = await _collectionUpdates('playlists');
      final rawUrns = (likes['collection'] as List<String>);
      final ids = rawUrns
          .map((urn) =>
              urn.startsWith('soundcloud:system-playlists:') ? urn : _id(urn))
          .toList();
      final playlists = await _fetchPlaylists(ids);
      final collection = (playlists['collection'] as List)
          .whereType<Map>()
          .map((playlist) => <String, dynamic>{
                ...Map<String, dynamic>.from(playlist),
                'user_favorite': true,
              })
          .toList();
      if (path.endsWith('/liked_and_owned')) {
        final userId = RegExp(r'^/users/(\d+)/').firstMatch(path)!.group(1)!;
        final posted = await get('/users/$userId/playlists');
        collection.addAll(
          (posted['collection'] as List)
              .whereType<Map>()
              .map((playlist) => Map<String, dynamic>.from(playlist)),
        );
        return <String, dynamic>{
          'collection': collection,
          if (posted['next_href'] != null) 'next_href': posted['next_href'],
        };
      }
      return <String, dynamic>{'collection': collection};
    }
    if (path == '/recently-played/contexts' ||
        path == '/recently-played/contexts/v2' ||
        path == '/me/play-history/contexts') {
      return _recentlyPlayedContextsPage(query);
    }
    if (path == '/me/play-history/tracks' ||
        path == '/recently-played/tracks') {
      return _historyPage(query);
    }
    return super.get(path, queryParameters: queryParameters);
  }

  @override
  Future<dynamic> getNext(String nextHref) async {
    var uri = Uri.tryParse(nextHref);
    if (uri != null && !uri.hasScheme) {
      uri = Uri.parse(
        'https://$_apiHost${nextHref.startsWith('/') ? '' : '/'}$nextHref',
      );
    }
    if (uri?.scheme == 'https' &&
        (uri?.host == _apiHost || uri?.host == 'graph.soundcloud.com')) {
      if (uri!.path == '/stream') {
        return _feed(discover: false, page: uri.queryParameters['page']);
      }
      if (uri.path == '/discover-feed') {
        return _feed(discover: true);
      }
      if (uri.path == '/recently-played/contexts/v2' ||
          uri.path == '/recently-played/contexts') {
        return _recentlyPlayedContextsPage(uri.queryParameters);
      }
      if (uri.path == '/recently-played/tracks' ||
          uri.path == '/me/play-history/tracks') {
        return _historyPage(uri.queryParameters);
      }
      if (RegExp(r'^/users/\d+/track_likes$').hasMatch(uri.path)) {
        return get(uri.path, queryParameters: uri.queryParameters);
      }
      final raw = await _json('GET', uri.path, query: uri.queryParameters);
      final kind = uri.path.endsWith('/tracks')
          ? 'track'
          : uri.path.contains('playlists')
          ? 'playlist'
          : uri.path.contains('users')
          ? 'user'
          : 'track';
      return _page(raw, kind);
    }
    return super.getNext(nextHref);
  }

  @override
  Future<dynamic> getMedia(Uri uri) async {
    if (uri.scheme == 'https' && uri.host == _apiHost) {
      final response = await _request(
        'GET',
        uri.path,
        query: uri.queryParameters,
        followRedirects: false,
      );
      final location = response.headers['location'];
      if (location == null || Uri.tryParse(location)?.hasScheme != true) {
        throw const FormatException('SoundCloud mobile stream URL missing');
      }
      return {
        'url': location,
        'licenseAuthToken': ?response.headers['x-sc-license-auth-token'],
      };
    }
    return super.getMedia(uri);
  }

  @override
  Future<dynamic> change(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? queryParameters,
    Map<String, String>? headers,
    String apiHost = 'api-v2.soundcloud.com',
    String? clientIdOverride,
  }) async {
    appLogger.info('[SoundCloudMobile] change: $method $path');
    final trackLike = RegExp(
      r'^/users/\d+/track_likes/(.+)$',
    ).firstMatch(path);
    if (trackLike != null) {
      final trackId = _id(trackLike.group(1)!);
      final urn = _urn('tracks', trackId);
      final endpoint = '/likes/tracks/${method == 'DELETE' ? 'delete' : 'create'}';
      appLogger.info('[SoundCloudMobile] trackLike: $method urn=$urn endpoint=$endpoint');
      final result = await _json(
        'POST',
        endpoint,
        body: {
          'likes': [
            {'target_urn': urn},
          ],
        },
      );
      appLogger.info('[SoundCloudMobile] trackLike success for $urn: $result');
      _updateCollectionSnapshot('tracks', urn, add: method != 'DELETE');
      return result;
    }
    final playlistLike = RegExp(
      r'^/users/\d+/(?:system_playlist_likes|playlist_likes)/(.+)$',
    ).firstMatch(path);
    if (playlistLike != null) {
      final raw = playlistLike.group(1)!;
      final urn = raw.startsWith('soundcloud:system-playlists:')
          ? raw
          : _urn('playlists', _id(raw));
      final endpoint = '/likes/playlists/${method == 'DELETE' ? 'delete' : 'create'}';
      appLogger.info('[SoundCloudMobile] playlistLike: $method urn=$urn endpoint=$endpoint');
      final result = await _json(
        'POST',
        endpoint,
        body: {
          'likes': [
            {'target_urn': urn},
          ],
        },
      );
      appLogger.info('[SoundCloudMobile] playlistLike success for $urn: $result');
      _updateCollectionSnapshot('playlists', urn, add: method != 'DELETE');
      return result;
    }
    final follow = RegExp(r'^/me/followings/(\d+)$').firstMatch(path);
    if (follow != null) {
      appLogger.info('[SoundCloudMobile] follow: $method user=${follow.group(1)!}');
      return _json(
        method == 'DELETE' ? 'DELETE' : 'POST',
        '/follows/users/${_urn('users', follow.group(1)!)}',
      );
    }
    appLogger.info('[SoundCloudMobile] change fallback to super: $method $path');
    return super.change(
      method,
      path,
      body: body,
      queryParameters: queryParameters,
      headers: headers,
      apiHost: apiHost,
      clientIdOverride: clientIdOverride,
    );
  }
}
