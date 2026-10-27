import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// An authorization request for SoundCloud's Android application OAuth flow.
class SoundCloudMobileAuthorization {
  SoundCloudMobileAuthorization({required this.clientId, this.locale = 'en'})
    : codeVerifier = _randomUrlSafe(48),
      deviceId = _randomHex(16),
      anonymousId = _randomUuid();

  final String clientId;
  final String codeVerifier;
  final String deviceId;
  final String anonymousId;
  final String locale;

  static const redirectUri = 'sc://auth';

  Uri get url => Uri.https('secure.soundcloud.com', '/web-auth', {
    'client_id': clientId,
    'app_id': '3152',
    'device_id': deviceId,
    'start_view': 'sign_in',
    'redirect_uri': redirectUri,
    'response_type': 'code',
    'code_challenge': base64Url
        .encode(sha256.convert(utf8.encode(codeVerifier)).bytes)
        .replaceAll('=', ''),
    'code_challenge_method': 'S256',
    'ui_evo': 'true',
    'stand_alone': 'true',
    'tracking': 'local',
    'show_confirmation': 'true',
    'theme': 'dark',
    'locale': locale,
    'sc_tracking_anonymous_id': anonymousId,
  });

  static String _randomUrlSafe(int byteCount) {
    final random = Random.secure();
    return base64Url
        .encode(List<int>.generate(byteCount, (_) => random.nextInt(256)))
        .replaceAll('=', '');
  }

  static String _randomHex(int byteCount) {
    final random = Random.secure();
    return List<int>.generate(byteCount, (_) => random.nextInt(256))
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  static String _randomUuid() {
    final hex = _randomHex(16).split('');
    hex[12] = '4';
    hex[16] = ((int.parse(hex[16], radix: 16) & 3) | 8).toRadixString(16);
    final value = hex.join();
    return '${value.substring(0, 8)}-${value.substring(8, 12)}-'
        '${value.substring(12, 16)}-${value.substring(16, 20)}-'
        '${value.substring(20)}';
  }
}

class SoundCloudMobileTokens {
  const SoundCloudMobileTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
  });

  final String accessToken;
  final String refreshToken;
  final DateTime expiresAt;

  factory SoundCloudMobileTokens.fromResponse(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SoundCloudMobileAuthException(response.statusCode);
    }
    final json = jsonDecode(response.body);
    if (json is! Map) throw const FormatException('Invalid OAuth response');
    final accessToken = json['access_token'];
    final refreshToken = json['refresh_token'];
    final seconds = json['expires_in'];
    if (accessToken is! String ||
        accessToken.isEmpty ||
        refreshToken is! String ||
        refreshToken.isEmpty ||
        seconds is! num) {
      throw const FormatException('Incomplete OAuth response');
    }
    return SoundCloudMobileTokens(
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresAt: DateTime.now().toUtc().add(Duration(seconds: seconds.toInt())),
    );
  }
}

class SoundCloudMobileAuthException implements Exception {
  const SoundCloudMobileAuthException(this.statusCode);

  final int statusCode;

  @override
  String toString() => 'SoundCloud sign in failed (HTTP $statusCode)';
}
