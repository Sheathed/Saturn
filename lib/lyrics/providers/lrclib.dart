import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:yaml/yaml.dart';
import '../../api/definitions.dart';
import '../enhanced_lrc_parser.dart';
import '../lyrics_provider.dart';

class LrclibLyricsProvider extends LyricsProvider {
  @override
  String get id => 'lrclib';

  @override
  String get name => 'LRCLIB';

  @override
  Future<Lyrics> getLyrics(Track track) async {
    final candidates = await getLyricsCandidates(track);
    return candidates.isEmpty
        ? Lyrics(errorMessage: 'No lyrics found')
        : candidates.first.lyrics;
  }

  @override
  Future<List<LyricsCandidate>> getLyricsCandidates(Track track) async {
    final title = track.title ?? '';
    final artistStr = track.artistString ?? '';
    if (title.trim().isEmpty || artistStr.trim().isEmpty) {
      return const [];
    }

    try {
      final searchUri = Uri.https('lrclib.net', '/api/search', {
        'track_name': title,
        'artist_name': artistStr,
        if (track.album?.title?.isNotEmpty == true)
          'album_name': track.album!.title!,
      });
      final response = await http.get(searchUri, headers: _headers);
      if (response.statusCode == 200) {
        final results = jsonDecode(response.body);
        if (results is List) {
          final matched = results
              .whereType<Map>()
              .map((record) => Map<String, dynamic>.from(record))
              .where((record) => _matchesTrack(record, track))
              .toList();
          matched.sort((a, b) => _compareRecords(a, b, track));
          final candidates = matched
              .map((record) => _candidateFromRecord(record, track))
              .whereType<LyricsCandidate>()
              .toList();
          if (candidates.isNotEmpty) return candidates;
        }
      }

      // Preserve LRCLIB's exact-signature lookup as a fallback when search
      // doesn't return a sufficiently close metadata and duration match.
      final exact = await _getExactRecord(track);
      final candidate = exact == null ? null : _candidateFromRecord(exact, track);
      return candidate == null ? const [] : [candidate];
    } catch (e) {
      debugPrint('[LrclibProvider] Search failed: $e');
      return const [];
    }
  }

  static const _headers = {'User-Agent': 'Saturn/3.0.14'};

  Future<Map<String, dynamic>?> _getExactRecord(Track track) async {
    final duration = track.duration?.inSeconds;
    final uri = Uri.https('lrclib.net', '/api/get', {
      'track_name': track.title ?? '',
      'artist_name': track.artistString ?? '',
      if (track.album?.title != null) 'album_name': track.album!.title!,
      if (duration != null && duration > 0) 'duration': duration.toString(),
    });
    final response = await http.get(uri, headers: _headers);
    if (response.statusCode != 200) {
      return null;
    }
    final record = jsonDecode(response.body);
    return record is Map ? Map<String, dynamic>.from(record) : null;
  }

  bool _matchesTrack(Map<String, dynamic> record, Track track) {
    final expectedDuration = track.duration?.inMilliseconds;
    final recordDuration = (record['duration'] as num?)?.toDouble();
    if (expectedDuration != null && expectedDuration > 0) {
      if (recordDuration == null ||
          (recordDuration * 1000 - expectedDuration).abs() > 2000) {
        return false;
      }
    }

    final expectedTitle = _normalize(track.title ?? '');
    final recordTitle = _normalize(
      (record['trackName'] ?? record['name'] ?? '').toString(),
    );
    if (expectedTitle.isEmpty || recordTitle != expectedTitle) {
      return false;
    }

    final expectedArtist = _normalize(track.artistString ?? '');
    final recordArtist = _normalize((record['artistName'] ?? '').toString());
    return expectedArtist.isNotEmpty &&
        recordArtist.isNotEmpty &&
        (expectedArtist == recordArtist ||
            expectedArtist.contains(recordArtist) ||
            recordArtist.contains(expectedArtist));
  }

  String _normalize(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'\([^)]*\)|\[[^]]*\]'), ' ')
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim()
      .replaceAll(RegExp(r'\s+'), ' ');

  int _compareRecords(
    Map<String, dynamic> a,
    Map<String, dynamic> b,
    Track track,
  ) {
    final aWordSync = a['hasWordSync'] == true ? 1 : 0;
    final bWordSync = b['hasWordSync'] == true ? 1 : 0;
    if (aWordSync != bWordSync) return bWordSync.compareTo(aWordSync);

    final expected = track.duration?.inSeconds;
    final aDiff = expected == null
        ? 0.0
        : (((a['duration'] as num?)?.toDouble() ?? expected) - expected).abs();
    final bDiff = expected == null
        ? 0.0
        : (((b['duration'] as num?)?.toDouble() ?? expected) - expected).abs();
    final durationOrder = aDiff.compareTo(bDiff);
    if (durationOrder != 0) {
      return durationOrder;
    }

    final album = _normalize(track.album?.title ?? '');
    final aAlbum = _normalize((a['albumName'] ?? '').toString());
    final bAlbum = _normalize((b['albumName'] ?? '').toString());
    return (aAlbum == album ? 0 : 1).compareTo(bAlbum == album ? 0 : 1);
  }

  LyricsCandidate? _candidateFromRecord(
    Map<String, dynamic> data,
    Track track,
  ) {
    final synced = data['syncedLyrics'] as String?;
    final plain = data['plainLyrics'] as String?;
    final lyricsFile = data['lyricsfile'] ?? data['lyricsFile'];
    List<SynchronizedLyric>? syncedLyrics;
    if (lyricsFile is String && lyricsFile.isNotEmpty) {
      syncedLyrics = _parseWordSyncedLyrics(lyricsFile);
    }
    if ((syncedLyrics == null || syncedLyrics.isEmpty) && synced != null) {
      syncedLyrics = EnhancedLrcParser.parse(synced);
    }
    final lyrics = Lyrics(
      id: data['id']?.toString(),
      syncedLyrics: syncedLyrics,
      unsyncedLyrics: plain,
    );
    if (!lyrics.isLoaded()) {
      return null;
    }
    final id = data['id']?.toString();
    if (id == null) {
      return null;
    }
    final duration = (data['duration'] as num?)?.toDouble();
    return LyricsCandidate(
      id: id,
      providerId: this.id,
      title: (data['trackName'] ?? data['name'] ?? track.title ?? '').toString(),
      artist: (data['artistName'] ?? track.artistString ?? '').toString(),
      album: data['albumName']?.toString(),
      duration: duration == null
          ? null
          : Duration(milliseconds: (duration * 1000).round()),
      wordSynced: data['hasWordSync'] == true &&
          (syncedLyrics?.any((line) => line.words?.isNotEmpty == true) ?? false),
      lyrics: lyrics,
    );
  }

  List<SynchronizedLyric>? _parseWordSyncedLyrics(String lyricsFile) {
    try {
      final document = loadYaml(lyricsFile);
      if (document is! Map) {
        return null;
      }
      final rawLines = document['lines'];
      if (rawLines is! List) {
        return null;
      }

      int? milliseconds(dynamic value) => value is num
          ? value.round()
          : int.tryParse(value?.toString() ?? '');

      final parsedLines = <SynchronizedLyric>[];
      for (final rawLine in rawLines) {
        if (rawLine is! Map) {
          continue;
        }
        final startMs = milliseconds(rawLine['start_ms']);
        if (startMs == null) {
          continue;
        }
        final rawWords = rawLine['words'];
        if (rawWords is! List || rawWords.isEmpty) {
          continue;
        }

        final wordData = <({String text, int start, int? end})>[];
        for (final rawWord in rawWords) {
          if (rawWord is! Map) {
            continue;
          }
          final text = rawWord['text']?.toString() ?? '';
          final wordStart = milliseconds(rawWord['start_ms']);
          if (text.isEmpty || wordStart == null) {
            continue;
          }
          wordData.add((
            text: text,
            start: wordStart,
            end: milliseconds(rawWord['end_ms']),
          ));
        }
        if (wordData.isEmpty) {
          continue;
        }
        wordData.sort((a, b) => a.start.compareTo(b.start));

        final lineEndMs = milliseconds(rawLine['end_ms']);
        final words = <LyricWord>[];
        for (var index = 0; index < wordData.length; index++) {
          final current = wordData[index];
          final nextStart = index + 1 < wordData.length
              ? wordData[index + 1].start
              : lineEndMs;
          final endMs = current.end ?? nextStart ?? current.start + 250;
          words.add(
            LyricWord(
              offset: Duration(milliseconds: current.start),
              duration: Duration(
                milliseconds: (endMs - current.start).clamp(1, 60000).toInt(),
              ),
              text: current.text,
            ),
          );
        }

        parsedLines.add(
          SynchronizedLyric(
            offset: Duration(milliseconds: startMs),
            duration: lineEndMs == null
                ? null
                : Duration(
                    milliseconds: (lineEndMs - startMs)
                        .clamp(1, 120000)
                        .toInt(),
                  ),
            text: rawLine['text']?.toString() ??
                words.map((word) => word.text).join(),
            words: words,
          ),
        );
      }

      parsedLines.sort((a, b) => a.offset!.compareTo(b.offset!));
      for (var index = 0; index < parsedLines.length - 1; index++) {
        final line = parsedLines[index];
        final nextOffset = parsedLines[index + 1].offset!;
        line.duration ??= nextOffset - line.offset!;
      }
      if (parsedLines.isNotEmpty) {
        parsedLines.last.duration ??= const Duration(seconds: 5);
      }
      if (parsedLines.isEmpty) {
        return null;
      }
      return parsedLines;
    } catch (error) {
      debugPrint('[LrclibProvider] Failed to parse word-synced lyrics: $error');
      return null;
    }
  }
}
