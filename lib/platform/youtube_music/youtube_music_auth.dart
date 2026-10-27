import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Authorization schemes used by YouTube Music's signed-in web client.
String? musicAuthorization(
  String? cookie, {
  String origin = 'https://music.youtube.com',
  int? timestampSeconds,
  bool preferSecure3P = false,
}) {
  final values = _sessionCookies(cookie);

  final timestamp =
      timestampSeconds ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final schemes = <String>[];
  void addScheme(String scheme, String? sid) {
    if (sid == null || sid.isEmpty) return;
    final digest = sha1.convert(utf8.encode('$timestamp $sid $origin'));
    schemes.add('$scheme ${timestamp}_$digest');
  }

  final sapisid = values['SAPISID'];
  final secure3P = values['__Secure-3PAPISID'];
  addScheme(
    'SAPISIDHASH',
    preferSecure3P && secure3P?.isNotEmpty == true
        ? secure3P
        : sapisid == null || sapisid.isEmpty
        ? secure3P
        : sapisid,
  );
  addScheme('SAPISID1PHASH', values['__Secure-1PAPISID']);
  addScheme('SAPISID3PHASH', secure3P);
  return schemes.isEmpty ? null : schemes.join(' ');
}

bool hasMusicSessionCookie(String? cookie) {
  final values = _sessionCookies(cookie);
  return [
    'SAPISID',
    '__Secure-1PAPISID',
    '__Secure-3PAPISID',
  ].any((name) => values[name]?.isNotEmpty ?? false);
}

Map<String, String> _sessionCookies(String? cookie) {
  final values = <String, String>{};
  if (cookie == null || cookie.isEmpty) return values;
  for (final part in cookie.split(';')) {
    final separator = part.indexOf('=');
    if (separator < 0) continue;
    values[part.substring(0, separator).trim()] = part
        .substring(separator + 1)
        .trim();
  }
  return values;
}
