import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../../api/definitions.dart';
import '../enhanced_lrc_parser.dart';
import '../lyrics_provider.dart';

class NeteaseLyricsProvider extends LyricsProvider {
  @override
  String get id => 'netease';

  @override
  String get name => 'Netease';

  static const _headers = {
    'Referer': 'https://music.163.com/',
    'Cookie':
        'os=pc; osver=Microsoft-Windows-10-Professional-build-19042-64bit; appver=2.9.7;',
    'User-Agent': 'NeteaseMusic/2.9.7',
  };

  @override
  Future<Lyrics> getLyrics(Track track) async {
    final title = track.title ?? '';
    final artistStr = track.artistString ?? '';

    final keyword = '$artistStr $title'.trim();
    if (keyword.isEmpty) {
      return Lyrics(errorMessage: 'Empty query');
    }

    try {
      // Step 1: Search for the song ID
      var songId = await _searchSongId(keyword);

      // If initial search returned no results and title had a hyphen or separator, try searching title directly
      if (songId == null && title.contains(' - ')) {
        final cleanedTitle = title.split(' - ').last.trim();
        songId = await _searchSongId('$artistStr $cleanedTitle'.trim());
      }
      if (songId == null && artistStr.isNotEmpty) {
        songId = await _searchSongId(title.trim());
      }

      if (songId == null) {
        return Lyrics(errorMessage: 'No results found on Netease');
      }

      // Step 2: Fetch lyrics
      return await _fetchLyrics(songId);
    } catch (e) {
      debugPrint('[NeteaseProvider] Error: $e');
      return Lyrics(errorMessage: 'Error fetching Netease lyrics: $e');
    }
  }

  Future<String?> _searchSongId(String query) async {
    try {
      final searchUri = Uri.parse('https://music.163.com/api/search/get');
      debugPrint('[NeteaseProvider] Searching: $searchUri query: "$query"');

      final searchResponse = await http.post(
        searchUri,
        headers: _headers,
        body: {
          's': query,
          'type': '1',
          'offset': '0',
          'limit': '5',
        },
      );
      debugPrint('[NeteaseProvider] Search Response Code: ${searchResponse.statusCode}');

      if (searchResponse.statusCode != 200) {
        return null;
      }

      final searchData = jsonDecode(searchResponse.body);
      final rawResult = searchData['result'];

      // Must verify rawResult is Map, as Netease sometimes returns encrypted string for abroad queries
      if (rawResult is! Map<String, dynamic>) {
        debugPrint('[NeteaseProvider] Search result is not a map');
        return null;
      }

      final songs = rawResult['songs'] as List<dynamic>?;
      if (songs == null || songs.isEmpty) {
        return null;
      }

      final songId = songs[0]['id']?.toString();
      debugPrint('[NeteaseProvider] Found song ID: $songId');
      return songId;
    } catch (e) {
      debugPrint('[NeteaseProvider] Search error: $e');
      return null;
    }
  }

  Future<Lyrics> _fetchLyrics(String songId) async {
    final lyricUri = Uri.parse(
      'https://music.163.com/api/song/lyric/v1?id=$songId&cp=false&lv=1&kv=1&tv=-1&rv=-1&yv=1&ytv=-1&yrv=-1',
    );
    debugPrint('[NeteaseProvider] Fetching lyrics: $lyricUri');

    final response = await http.get(lyricUri, headers: _headers);
    debugPrint('[NeteaseProvider] Lyrics Response Code: ${response.statusCode}');

    if (response.statusCode != 200) {
      return Lyrics(errorMessage: 'Failed to fetch Netease lyrics: ${response.statusCode}');
    }

    final data = jsonDecode(response.body);

    // Try YRC (word-level) first
    final yrcLyric = data['yrc']?['lyric'] as String?;
    final translatedLyric = data['tlyric']?['lyric'] as String?;
    final romanizedLyric = data['romalrc']?['lyric'] as String?;
    final translatedLines = _parseOverlay(translatedLyric);
    final romanizedLines = _parseOverlay(romanizedLyric);

    Lyrics withOverlays(List<SynchronizedLyric> lines) {
      attachLyricOverlay(lines, translatedLines, translation: true);
      attachLyricOverlay(lines, romanizedLines, translation: false);
      return Lyrics(syncedLyrics: lines);
    }

    if (yrcLyric != null && yrcLyric.isNotEmpty) {
      debugPrint('[NeteaseProvider] Found YRC (word-level) lyrics');
      final syncedLyrics = _parseYrc(yrcLyric);
      if (syncedLyrics.isNotEmpty) {
        return withOverlays(syncedLyrics);
      }
    }

    // Fallback to standard LRC / mixed format in lrc
    final lrcLyric = data['lrc']?['lyric'] as String?;
    if (lrcLyric != null && lrcLyric.isNotEmpty) {
      debugPrint('[NeteaseProvider] Falling back to lrc field');
      final syncedLyrics = _parseYrc(lrcLyric);
      if (syncedLyrics.isNotEmpty) {
        return withOverlays(syncedLyrics);
      }
      return Lyrics(
        unsyncedLyrics: lrcLyric,
        unsyncedTranslatedLyrics: translatedLyric,
        unsyncedRomanizedLyrics: romanizedLyric,
      );
    }

    if (translatedLyric?.isNotEmpty == true ||
        romanizedLyric?.isNotEmpty == true) {
      return Lyrics(
        unsyncedTranslatedLyrics: translatedLyric,
        unsyncedRomanizedLyrics: romanizedLyric,
      );
    }

    return Lyrics(errorMessage: 'No lyrics found on Netease');
  }

  List<SynchronizedLyric> _parseOverlay(String? lyric) {
    if (lyric == null || lyric.trim().isEmpty) return [];
    final parsed = EnhancedLrcParser.parse(lyric);
    if (parsed.isNotEmpty) return parsed;
    final fallback = Lyrics.fromLRC(lyric);
    return fallback is Lyrics ? fallback.syncedLyrics ?? [] : [];
  }

  /// Parse Netease YRC and mixed LRC format.
  ///
  /// Supports:
  /// 1. JSON lines: {"t":lineStartMs,"c":[{"tx":"word","t":durationMs}, ...]}
  /// 2. Bracket format: [lineStartMs,lineDurMs](wordStartMs,wordDurMs)word text
  /// 3. Standard LRC format: [mm:ss.xx] line text
  List<SynchronizedLyric> _parseYrc(String yrc) {
    final List<SynchronizedLyric> result = [];
    final lines = yrc.split('\n');

    final bracketRegex = RegExp(r'^\[(\d+),(\d+)\]');
    final wordRegex = RegExp(r'\((\d+),(\d+)(?:,-?\d+)?\)([^(]*)');
    final stdLrcRegex = RegExp(r'^\[(\d+):(\d+\.?\d*)\](.*)');

    for (var line in lines) {
      line = line.trim();
      if (line.isEmpty) continue;

      if (line.startsWith('{')) {
        // 1. JSON format
        try {
          final obj = jsonDecode(line) as Map<String, dynamic>;
          final lineStartMs = (obj['t'] as num?)?.toInt() ?? 0;
          final parts = obj['c'] as List<dynamic>? ?? [];

          final List<LyricWord> words = [];
          int cursor = lineStartMs;
          final StringBuffer fullText = StringBuffer();

          for (final part in parts) {
            final tx = part['tx']?.toString() ?? '';
            if (tx.isEmpty) continue;

            final dur = (part['t'] as num?)?.toInt() ?? 0;
            words.add(LyricWord(
              offset: Duration(milliseconds: cursor),
              duration: Duration(milliseconds: dur),
              text: tx,
            ));
            fullText.write(tx);
            if (dur > 0) cursor += dur;
          }

          if (words.isNotEmpty) {
            result.add(SynchronizedLyric(
              offset: Duration(milliseconds: lineStartMs),
              text: fullText.toString(),
              words: words,
            ));
          }
        } catch (e) {
          debugPrint('[NeteaseProvider] Failed to parse YRC JSON line: $e');
        }
      } else if (line.startsWith('[')) {
        final headMatch = bracketRegex.firstMatch(line);
        if (headMatch != null) {
          // 2. Bracket format: [lineStartMs,lineDurMs](wordStartMs,wordDurMs)word
          final lineStartMs = int.parse(headMatch.group(1)!);
          final rest = line.substring(headMatch.end);

          final wordMatches = wordRegex.allMatches(rest);
          final List<LyricWord> words = [];
          final StringBuffer fullText = StringBuffer();

          for (final m in wordMatches) {
            final wordStartMs = int.parse(m.group(1)!);
            final wordDurMs = int.parse(m.group(2)!);
            final text = m.group(3) ?? '';
            if (text.isEmpty) continue;

            words.add(LyricWord(
              offset: Duration(milliseconds: wordStartMs),
              duration: Duration(milliseconds: wordDurMs),
              text: text,
            ));
            fullText.write(text);
          }

          if (words.isNotEmpty) {
            result.add(SynchronizedLyric(
              offset: Duration(milliseconds: lineStartMs),
              text: fullText.toString(),
              words: words,
            ));
          }
        } else {
          // 3. Standard LRC format: [mm:ss.xx]
          final stdMatch = stdLrcRegex.firstMatch(line);
          if (stdMatch != null) {
            final minutes = int.parse(stdMatch.group(1)!);
            final seconds = double.parse(stdMatch.group(2)!);
            final text = stdMatch.group(3)!.trim();

            if (text.isNotEmpty) {
              final totalMs = (minutes * 60 * 1000 + seconds * 1000).toInt();
              result.add(SynchronizedLyric(
                offset: Duration(milliseconds: totalMs),
                text: text,
              ));
            }
          }
        }
      }
    }

    // Sort by timestamp
    result.sort((a, b) => (a.offset ?? Duration.zero).compareTo(b.offset ?? Duration.zero));

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
