import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../../api/definitions.dart';
import '../lyrics_provider.dart';
import 'qq_des.dart';

class QQLyricsProvider extends LyricsProvider {
  @override
  String get id => 'qq';

  @override
  String get name => 'QQ Music';

  static const _headers = {
    'Referer': 'https://y.qq.com/',
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
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
      // Step 1: Search song ID
      final songId = await _searchSongId(title, artistStr);
      if (songId == null) {
        return Lyrics(errorMessage: 'No results found on QQ Music');
      }

      // Step 2: Download & decrypt lyrics
      final lyrics = await _fetchLyrics(songId);
      if (lyrics != null) {
        return lyrics;
      }

      return Lyrics(errorMessage: 'No QRC lyrics found on QQ Music');
    } catch (e) {
      debugPrint('[QQProvider] Error: $e');
      return Lyrics(errorMessage: 'Error fetching QQ lyrics: $e');
    }
  }

  Future<String?> _searchSongId(String title, String artist) async {
    // Attempt 1: PC LRC Search API
    try {
      final queryParams = {
        'SONGNAME': title,
        'SINGERNAME': artist,
        'TYPE': '2',
        'RANGE_MIN': '1',
        'RANGE_MAX': '5',
      };
      final searchUri = Uri.https(
        'c.y.qq.com',
        '/lyric/fcgi-bin/fcg_search_pc_lrc.fcg',
        queryParams,
      );
      final response = await http.get(searchUri, headers: _headers);
      debugPrint('[QQProvider] PC Search URI: $searchUri');
      debugPrint('[QQProvider] PC Search Response Code: ${response.statusCode}');
      debugPrint('[QQProvider] PC Search Response Body length: ${utf8.decode(response.bodyBytes, allowMalformed: true).length}');
      debugPrint('[QQProvider] PC Search Response Body: ${utf8.decode(response.bodyBytes, allowMalformed: true)}');
      if (response.statusCode == 200) {
        final idMatch = RegExp(r'<songinfo[^>]*id="(\d+)"').firstMatch(utf8.decode(response.bodyBytes, allowMalformed: true));
        if (idMatch != null) {
          final id = idMatch.group(1);
          debugPrint('[QQProvider] Found song ID from PC search: $id');
          return id;
        }
      }
    } catch (e) {
      debugPrint('[QQProvider] PC search failed: $e');
    }

    // Attempt 2: Client search API fallback
    try {
      final keyword = '$artist $title'.trim();
      final clientSearchUri = Uri.https(
        'c.y.qq.com',
        '/soso/fcgi-bin/client_search_cp',
        {'w': keyword, 'n': '5', 'format': 'json'},
      );
      final response = await http.get(clientSearchUri, headers: _headers);
      debugPrint('[QQProvider] Client Search URI: $clientSearchUri');
      debugPrint('[QQProvider] Client Search Response Code: ${response.statusCode}');
      debugPrint('[QQProvider] Client Search Response Body length: ${utf8.decode(response.bodyBytes, allowMalformed: true).length}');
      debugPrint('[QQProvider] Client Search Response Body: ${utf8.decode(response.bodyBytes, allowMalformed: true)}');
      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes, allowMalformed: true));
        final list = data['data']?['song']?['list'] as List<dynamic>?;
        if (list != null && list.isNotEmpty) {
          final id = (list[0]['songid'] ?? list[0]['id'])?.toString();
          if (id != null && id.isNotEmpty) {
            debugPrint('[QQProvider] Found song ID from client search: $id');
            return id;
          }
        }
      }
    } catch (e) {
      debugPrint('[QQProvider] Client search fallback failed: $e');
    }

    return null;
  }

  Future<Lyrics?> _fetchLyrics(String songId) async {
    // This endpoint can return original, translated, and romanized tracks.
    try {
      final postUri = Uri.parse('https://u.y.qq.com/cgi-bin/musicu.fcg');
      final payload = jsonEncode({
        'comm': {
          'ct': 11,
          'cv': '1003006',
          'v': '1003006',
          'tmeAppID': 'qqmusiclight',
        },
        'request': {
          'module': 'music.musichallSong.PlayLyricInfo',
          'method': 'GetPlayLyricInfo',
          'param': {
            'songID': int.tryParse(songId) ?? 0,
            'qrc': 1,
            'trans': 1,
            'roma': 1,
            'crypt': 1,
          },
        },
      });
      final response = await http.post(
        postUri,
        headers: {..._headers, 'Content-Type': 'application/json'},
        body: payload,
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes, allowMalformed: true));
        final lyricData = data['request']?['data'] ??
            data['music.musichallSong.PlayLyricInfo.GetPlayLyricInfo']?[
              'data'
            ];
        final original = _parseLyricPayload(lyricData?['lyric']);
        if (original.isNotEmpty) {
          attachLyricOverlay(
            original,
            _parseLyricPayload(lyricData?['trans']),
            translation: true,
          );
          attachLyricOverlay(
            original,
            _parseLyricPayload(lyricData?['roma']),
            translation: false,
          );
          return Lyrics(syncedLyrics: original);
        }
      }
    } catch (e) {
      debugPrint('[QQProvider] PlayLyricInfo failed: $e');
    }

    // Fallback for tracks unavailable through PlayLyricInfo.
    try {
      final downloadUri = Uri.parse(
        'https://c.y.qq.com/qqmusic/fcgi-bin/lyric_download.fcg?version=15&miniversion=82&lrctype=4&musicid=${Uri.encodeComponent(songId)}',
      );
      final response = await http.get(downloadUri, headers: _headers);
      if (response.statusCode == 200) {
        final contentMatch = RegExp(
          r'<content[^>]*>(.*?)</content>',
          dotAll: true,
        ).firstMatch(utf8.decode(response.bodyBytes, allowMalformed: true));
        if (contentMatch != null) {
          var rawHex = contentMatch.group(1)!.trim();
          rawHex = rawHex.replaceAll('<![CDATA[', '').replaceAll(']]>', '').trim();
          if (rawHex.isNotEmpty && rawHex.length.isEven) {
            final plainXml = _decryptHex(rawHex);
            if (plainXml != null && plainXml.isNotEmpty) {
              final synced = _parseQrcXml(plainXml);
              if (synced.isNotEmpty) return Lyrics(syncedLyrics: synced);
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[QQProvider] lyric_download failed: $e');
    }

    return null;
  }

  String? _decryptHex(String hex) {
    try {
      final cleanHex = hex.replaceAll(RegExp(r'\s+'), '');
      final raw = Uint8List(cleanHex.length ~/ 2);
      for (int i = 0; i < raw.length; i++) {
        raw[i] = int.parse(cleanHex.substring(i * 2, i * 2 + 2), radix: 16);
      }
      return QQMusicDes.decryptQrc(raw);
    } catch (e) {
      debugPrint('[QQProvider] Decryption error: $e');
      return null;
    }
  }

  List<SynchronizedLyric> _parseLyricPayload(dynamic payload) {
    if (payload == null) return [];
    final value = payload.toString().trim();
    if (value.isEmpty) return [];
    final decoded = _decryptHex(value) ?? value;
    return _parseQrcXml(decoded);
  }

  /// Parses decrypted QRC XML into word-level SynchronizedLyric list.
  List<SynchronizedLyric> _parseQrcXml(String xml) {
    // Extract LyricContent
    String lyricContent = xml;
    final match = RegExp(r'LyricContent="([\s\S]*?)"\s*/>', dotAll: true).firstMatch(xml) ??
        RegExp(r"LyricContent='([\s\S]*?)'\s*/>", dotAll: true).firstMatch(xml);
    if (match != null) {
      lyricContent = match.group(1)!;
    }

    // Decode HTML entities
    lyricContent = lyricContent
        .replaceAll('&#10;', '\n')
        .replaceAll('&#13;', '\r')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&amp;', '&');

    final List<SynchronizedLyric> result = [];
    final lines = lyricContent.split(RegExp(r'\r?\n'));

    final lineRegex = RegExp(r'^\[(\d+),(\d+)\](.*)$');
    final wordRegex = RegExp(r'([^(]*)\((\d+),(\d+)\)');

    for (var line in lines) {
      line = line.trim();
      if (line.isEmpty || !line.startsWith('[')) continue;

      // Skip metadata lines like [ti:], [ar:], [al:], [offset:]
      if (RegExp(r'^\[[a-zA-Z$]').hasMatch(line)) continue;

      final lineMatch = lineRegex.firstMatch(line);
      if (lineMatch == null) {
        // Check for standard LRC format in QRC [mm:ss.xx]
        final stdMatch = RegExp(r'^\[(\d+):(\d+\.?\d*)\](.*)').firstMatch(line);
        if (stdMatch != null) {
          final minutes = int.parse(stdMatch.group(1)!);
          final seconds = double.parse(stdMatch.group(2)!);
          final totalMs = (minutes * 60 * 1000 + seconds * 1000).toInt();
          result.add(SynchronizedLyric(
            offset: Duration(milliseconds: totalMs),
            text: stdMatch.group(3)!.trim(),
          ));
        }
        continue;
      }

      final lineStartMs = int.parse(lineMatch.group(1)!);
      final rest = lineMatch.group(3)!;

      final wordMatches = wordRegex.allMatches(rest);
      final List<LyricWord> words = [];
      final StringBuffer fullText = StringBuffer();

      for (final m in wordMatches) {
        final text = m.group(1) ?? '';
        final wordStartMs = int.parse(m.group(2)!);
        final wordDurMs = int.parse(m.group(3)!);

        if (text.isEmpty && wordDurMs == 0) continue;

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
      } else if (rest.isNotEmpty) {
        result.add(SynchronizedLyric(
          offset: Duration(milliseconds: lineStartMs),
          text: rest.replaceAll(RegExp(r'\(\d+,\d+\)'), '').trim(),
        ));
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
