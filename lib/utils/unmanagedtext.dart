import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class LyricsAPI {
  static const baseUrl = 'aHR0cHM6Ly9seXJpY3Muc2F0dXJuLmtpbQ==';

  static Future<Map<String, dynamic>> getLyrics(
    String provider,
    String trackId,
    String query,
  ) async {
    final decodedBaseUrl = utf8.decode(base64.decode(baseUrl));
    final fullUrl = '$decodedBaseUrl/$provider/$trackId/$query';

    final now = DateTime.now();

    final year = now.year.toString();

    final month = now.month.toString().padLeft(2, '0');

    final day = now.day.toString().padLeft(2, '0');

    final dateBytes = utf8.encode(year + month + day);

    final keyBytes = utf8.encode(
      year + now.month.toString() + now.day.toString(),
    );
    debugPrint('[LyricsAPI] Key bytes: $keyBytes');

    final hmac = Hmac(sha256, keyBytes);
    final digest = hmac.convert(dateBytes);

    final base64Signature = base64.encode(digest.bytes);

    final cleanSignature = base64Signature.replaceAll(
      RegExp(r'[^A-Za-z0-9]+'),
      '',
    );

    final authenticatedUrl = '$fullUrl/$cleanSignature';

    try {
      final response = await http.get(Uri.parse(authenticatedUrl));

      if (response.statusCode == 200) {
        final result = jsonDecode(response.body);
        return result;
      } else if (response.statusCode == 500) {
        return {'lyrics': 'error'};
      }
      throw Exception('E${response.statusCode}');
    } catch (e) {
      debugPrint('[LyricsAPI] Error during request: $e');
      return {'lyrics': 'error'};
    }
  }

  Future listProviders() async {
    try {
      String web = 'https://lyrics.saturn.kim/providers';
      final response = await http.get(Uri.parse(web));

      if (response.statusCode == 200) {
        final providers = jsonDecode(response.body);
        return providers;
      }
      throw Exception('E${response.statusCode}');
    } catch (e) {
      throw Exception('E$e');
    }
  }
}
