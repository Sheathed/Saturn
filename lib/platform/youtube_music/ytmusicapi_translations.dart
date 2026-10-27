import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Loads the gettext catalogs shipped with ytmusicapi.
///
/// These are the same compiled catalogs used by Python's GNUTranslations, so
/// parser labels stay in sync with the upstream language support.
class YTMusicApiTranslations {
  YTMusicApiTranslations._(this.language, this._messages);

  static const _magic = 0x950412de;
  static final Map<String, Future<YTMusicApiTranslations>> _cache = {};

  final String language;
  final Map<String, String> _messages;

  static Future<YTMusicApiTranslations> load(String language) =>
      _cache.putIfAbsent(language, () => _load(language));

  String translate(String message) {
    final translated = _messages[message];
    return translated == null || translated.isEmpty ? message : translated;
  }

  static Future<YTMusicApiTranslations> _load(String language) async {
    try {
      final data = await rootBundle.load(
        'assets/ytmusicapi_locales/$language.mo',
      );
      if (data.lengthInBytes < 28) {
        throw const FormatException('Invalid gettext catalog header');
      }
      final littleEndian = data.getUint32(0, Endian.little) == _magic;
      final endian = littleEndian ? Endian.little : Endian.big;
      if (!littleEndian && data.getUint32(0, Endian.big) != _magic) {
        throw const FormatException('Invalid gettext catalog magic');
      }

      final count = data.getUint32(8, endian);
      final originalsOffset = data.getUint32(12, endian);
      final translationsOffset = data.getUint32(16, endian);
      final messages = <String, String>{};
      for (var i = 0; i < count; i++) {
        final originalLength = data.getUint32(originalsOffset + i * 8, endian);
        final originalOffset = data.getUint32(
          originalsOffset + i * 8 + 4,
          endian,
        );
        final translatedLength = data.getUint32(
          translationsOffset + i * 8,
          endian,
        );
        final translatedOffset = data.getUint32(
          translationsOffset + i * 8 + 4,
          endian,
        );
        final original = utf8.decode(
          data.buffer.asUint8List(
            data.offsetInBytes + originalOffset,
            originalLength,
          ),
          allowMalformed: true,
        );
        if (original.isEmpty) continue;
        final translated = utf8.decode(
          data.buffer.asUint8List(
            data.offsetInBytes + translatedOffset,
            translatedLength,
          ),
          allowMalformed: true,
        ).split('\u0000').first;
        if (translated.isNotEmpty) messages[original] = translated;
      }
      return YTMusicApiTranslations._(language, messages);
    } catch (_) {
      // Unknown/missing catalog files use the same English message IDs as
      // gettext's fallback behavior.
      return YTMusicApiTranslations._(language, const {});
    }
  }
}
