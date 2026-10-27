import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../../api/definitions.dart';
import '../lyrics_provider.dart';

class KugouLyricsProvider extends LyricsProvider {
  @override
  String get id => 'kugou';

  @override
  String get name => 'Kugou';

  /// KRC XOR decryption key (16 bytes)
  static const _krcKey = [
    64,
    71,
    97,
    119,
    94,
    50,
    116,
    71,
    81,
    54,
    49,
    45,
    206,
    210,
    110,
    105,
  ];

  @override
  Future<Lyrics> getLyrics(Track track) async {
    final title = track.title ?? '';
    final artistStr = track.artistString ?? '';

    final keyword = '$artistStr $title'.trim();
    if (keyword.isEmpty) {
      return Lyrics(errorMessage: 'Empty query');
    }

    try {
      // Step 1: Search for the song
      final searchUri = Uri.parse(
        'http://songsearch.kugou.com/song_search_v2?keyword=${Uri.encodeComponent(keyword)}&page=1&pagesize=8',
      );
      debugPrint('[KugouProvider] Searching: $searchUri');

      final searchResponse = await http.get(searchUri);
      debugPrint(
        '[KugouProvider] Search Response Code: ${searchResponse.statusCode}',
      );

      if (searchResponse.statusCode != 200) {
        return Lyrics(
          errorMessage: 'Kugou search failed: ${searchResponse.statusCode}',
        );
      }

      final searchData = jsonDecode(searchResponse.body);
      final lists =
          searchData['data']?['lists'] as List<dynamic>? ??
          searchData['lists'] as List<dynamic>? ??
          [];

      if (lists.isEmpty) {
        return Lyrics(errorMessage: 'No results found on Kugou');
      }

      // Try each result until we find one with lyrics
      for (final song in lists) {
        final hash =
            (song['FileHash'] ?? song['HQFileHash'] ?? song['SQFileHash'])
                ?.toString();
        if (hash == null || hash.isEmpty) continue;

        debugPrint('[KugouProvider] Trying hash: $hash');

        try {
          final lyrics = await _fetchByHash(hash);
          if (lyrics != null) return lyrics;
        } catch (e) {
          debugPrint('[KugouProvider] Failed for hash $hash: $e');
          continue;
        }
      }

      return Lyrics(errorMessage: 'No KRC lyrics found on Kugou');
    } catch (e) {
      debugPrint('[KugouProvider] Error: $e');
      return Lyrics(errorMessage: 'Error fetching Kugou lyrics: $e');
    }
  }

  Future<Lyrics?> _fetchByHash(String hash) async {
    // Step 2: Search for KRC candidates
    final lookupUri = Uri.parse(
      'http://krcs.kugou.com/search?ver=1&man=yes&client=mobi&hash=${Uri.encodeComponent(hash)}',
    );
    final lookupResponse = await http.get(lookupUri);
    if (lookupResponse.statusCode != 200) return null;

    final lookupData = jsonDecode(lookupResponse.body);
    final candidates = lookupData['candidates'] as List<dynamic>? ?? [];

    String? krcId;
    String? accessKey;
    for (final c in candidates) {
      krcId = c['id']?.toString();
      accessKey = c['accesskey']?.toString();
      if (krcId != null &&
          krcId.isNotEmpty &&
          accessKey != null &&
          accessKey.isNotEmpty) {
        break;
      }
      krcId = null;
      accessKey = null;
    }

    if (krcId == null || accessKey == null) return null;

    // Step 3: Download KRC
    final downloadUri = Uri.parse(
      'http://lyrics.kugou.com/download?ver=1&client=pc&id=${Uri.encodeComponent(krcId)}&accesskey=${Uri.encodeComponent(accessKey)}&fmt=krc&charset=utf8',
    );
    debugPrint('[KugouProvider] Downloading KRC: $downloadUri');

    final downloadResponse = await http.get(downloadUri);
    if (downloadResponse.statusCode != 200) return null;

    final downloadData = jsonDecode(downloadResponse.body);
    final content = downloadData['content']?.toString();
    if (content == null || content.isEmpty) return null;

    // Step 4: Decrypt KRC
    final plainKrc = _decryptKrc(content);
    if (plainKrc == null || plainKrc.isEmpty) return null;

    debugPrint(
      '[KugouProvider] Decrypted KRC (first 200 chars): ${plainKrc.substring(0, plainKrc.length.clamp(0, 200))}',
    );

    // Step 5: Parse KRC into word-level lyrics
    final syncedLyrics = _parseKrc(plainKrc);
    if (syncedLyrics.isEmpty) return null;

    _attachLanguageOverlays(plainKrc, syncedLyrics);

    return Lyrics(syncedLyrics: syncedLyrics);
  }

  /// KRC stores optional translation and romanization in a base64 JSON
  /// `[language:]` header. These tracks are line-aligned with the source.
  void _attachLanguageOverlays(String krc, List<SynchronizedLyric> lyrics) {
    final match = RegExp(
      r'^\[language:([^\]]+)\]',
      multiLine: true,
    ).firstMatch(krc);
    if (match == null) return;

    try {
      final decoded = jsonDecode(utf8.decode(base64Decode(match.group(1)!)));
      if (decoded is! Map || decoded['content'] is! List) return;

      for (final language in decoded['content'] as List) {
        if (language is! Map || language['lyricContent'] is! List) continue;
        final type = language['type'];
        final content = language['lyricContent'] as List;
        final count = lyrics.length < content.length
            ? lyrics.length
            : content.length;

        for (var i = 0; i < count; i++) {
          final row = content[i];
          if (row is! List || row.isEmpty) continue;
          final text = row
              .whereType<String>()
              .join(type == 0 ? ' ' : '')
              .trim();
          if (text.isEmpty) continue;
          if (type == 1) {
            lyrics[i].translatedText = text;
          } else if (type == 0) {
            lyrics[i].romanizedText = text;
          }
        }
      }
    } catch (e) {
      // Some KRC files have malformed optional language metadata. Keep the
      // usable source lyrics and simply omit those overlays.
      debugPrint('[KugouProvider] Invalid language metadata: $e');
    }
  }

  String? _decryptKrc(String base64Content) {
    try {
      final bytes = base64Decode(base64Content);
      if (bytes.length < 4) return null;

      // XOR decrypt (skip first 4 header bytes)
      final decrypted = Uint8List(bytes.length - 4);
      for (int i = 4; i < bytes.length; i++) {
        decrypted[i - 4] = bytes[i] ^ _krcKey[(i - 4) % 16];
      }

      // Zlib decompress
      final decompressed = zlib.decode(decrypted);
      return utf8.decode(decompressed, allowMalformed: true);
    } catch (e) {
      debugPrint('[KugouProvider] KRC decryption error: $e');
      return null;
    }
  }

  /// Parse KRC format into SynchronizedLyric with word-level timing.
  ///
  /// KRC line format: `[lineStartMs,lineDurMs]<wordOffsetMs,wordDurMs,-1>word text`
  List<SynchronizedLyric> _parseKrc(String krc) {
    final List<SynchronizedLyric> result = [];
    final lines = krc.split('\n');

    final lineRegex = RegExp(r'^\[(\d+),(\d+)\](.*)$');
    final wordRegex = RegExp(r'<(\d+),(\d+),-?\d+>([^<]*)');

    for (var line in lines) {
      line = line.trim();
      if (line.isEmpty || !line.startsWith('[')) continue;

      // Skip metadata lines
      if (RegExp(r'^\[[a-zA-Z$]').hasMatch(line)) continue;

      final lineMatch = lineRegex.firstMatch(line);
      if (lineMatch == null) continue;

      final lineStartMs = int.parse(lineMatch.group(1)!);
      final body = lineMatch.group(3)!;

      final wordMatches = wordRegex.allMatches(body);
      final List<LyricWord> words = [];
      final StringBuffer fullText = StringBuffer();

      for (final m in wordMatches) {
        final wordOffsetMs = int.parse(m.group(1)!);
        final wordDurMs = int.parse(m.group(2)!);
        final text = m.group(3) ?? '';
        if (text.isEmpty) continue;

        words.add(
          LyricWord(
            offset: Duration(milliseconds: lineStartMs + wordOffsetMs),
            duration: Duration(milliseconds: wordDurMs),
            text: text,
          ),
        );
        fullText.write(text);
      }

      if (words.isEmpty && body.isNotEmpty) {
        // No word-level timing, just a plain line
        result.add(
          SynchronizedLyric(
            offset: Duration(milliseconds: lineStartMs),
            text: body,
          ),
        );
      } else if (words.isNotEmpty) {
        result.add(
          SynchronizedLyric(
            offset: Duration(milliseconds: lineStartMs),
            text: fullText.toString(),
            words: words,
          ),
        );
      }
    }

    // Calculate line durations
    for (int i = 0; i < result.length - 1; i++) {
      result[i].duration ??= result[i + 1].offset! - result[i].offset!;
    }
    if (result.isNotEmpty) {
      result.last.duration ??= const Duration(seconds: 5);
    }

    return result;
  }
}
