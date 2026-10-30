import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../../api/definitions.dart';
import '../../settings.dart';
import '../enhanced_lrc_parser.dart';
import '../lyrics_provider.dart';

class MusixmatchLyricsProvider extends LyricsProvider {
  @override
  String get id => 'musixmatch';

  @override
  String get name => 'Musixmatch';

  String? _usertoken;
  final Map<String, Future<String?>> _translationCache = {};

  Future<void> _fetchTokenIfNeeded() async {
    if (_usertoken != null) return;

    try {
      final uri = Uri.parse(
        'https://apic-appmobile.musixmatch.com/ws/1.1/token.get?app_id=mac-ios-v2.0',
      );
      final response = await http.get(
        uri,
        headers: {
          'Host': 'apic-appmobile.musixmatch.com',
          'X-Cookie': 'x-mxm-token-guid=',
          'x-mxm-app-version': '10.1.1',
          'X-User-Agent':
              'Musixmatch/2025120901 CFNetwork/3860.300.31 Darwin/25.2.0',
          'Accept-Language': 'en-US,en;q=0.9',
          'Accept': 'application/json',
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final status = data['message']?['header']?['status_code'];
        if (status == 200) {
          _usertoken = data['message']?['body']?['user_token'];
        } else {
          debugPrint(
            '[MusixmatchProvider] Failed to generate token, status: $status',
          );
        }
      }
    } catch (e) {
      debugPrint('[MusixmatchProvider] Error fetching token: $e');
    }
  }

  @override
  Future<Lyrics> getLyrics(Track track) async {
    await _fetchTokenIfNeeded();
    if (_usertoken == null) {
      return Lyrics(errorMessage: 'Failed to generate Musixmatch token');
    }

    final title = track.title ?? '';
    final artistStr = track.artistString ?? '';
    final duration = (track.duration?.inSeconds ?? 0).toString();

    var queryParams = {
      'format': 'json',
      'namespace': 'lyrics_richsynched',
      'subtitle_format': 'mxm',
      'app_id': 'mac-ios-v2.0',
      'q_album': track.album?.title ?? '',
      'q_artist': artistStr,
      'q_artists': artistStr,
      'q_track': title,
      'q_duration': duration,
      'f_subtitle_length': duration,
      'usertoken': _usertoken!,
      'optional_calls': 'track.richsync',
      'richsync_compact_type': 'words',
      'part':
          'track_lyrics_translation_status,track_structure,track_performer_tagging',
    };

    var uri = Uri.https(
      'apic-appmobile.musixmatch.com',
      '/ws/1.1/macro.subtitles.get',
      queryParams,
    );
    debugPrint('[MusixmatchProvider] Fetching from: $uri');

    try {
      var response = await http.get(
        uri,
        headers: {
          'Host': 'apic-appmobile.musixmatch.com',
          'X-User-Agent':
              'Musixmatch/2025120901 CFNetwork/3860.300.31 Darwin/25.2.0',
          'Accept': 'application/json',
        },
      );

      debugPrint('[MusixmatchProvider] Response Code: ${response.statusCode}');

      if (response.statusCode == 200) {
        var data = jsonDecode(response.body);
        var headerStatusCode = data['message']?['header']?['status_code'];

        if (headerStatusCode == 401) {
          debugPrint(
            '[MusixmatchProvider] Token expired, fetching a new one and retrying...',
          );
          _usertoken = null;
          await _fetchTokenIfNeeded();

          if (_usertoken == null) {
            return Lyrics(
              errorMessage: 'Musixmatch token expired and failed to renew',
            );
          }

          queryParams['usertoken'] = _usertoken!;
          uri = Uri.https(
            'apic-appmobile.musixmatch.com',
            '/ws/1.1/macro.subtitles.get',
            queryParams,
          );
          response = await http.get(
            uri,
            headers: {
              'Host': 'apic-appmobile.musixmatch.com',
              'X-User-Agent':
                  'Musixmatch/2025120901 CFNetwork/3860.300.31 Darwin/25.2.0',
              'Accept': 'application/json',
            },
          );

          data = jsonDecode(response.body);
          headerStatusCode = data['message']?['header']?['status_code'];
          if (headerStatusCode == 401) {
            return Lyrics(
              errorMessage:
                  'Musixmatch token expired (401) again. Rate limited?',
            );
          }
        }

        final macroCalls = data['message']?['body']?['macro_calls'];

        if (macroCalls == null ||
            macroCalls['matcher.track.get']?['message']?['header']?['status_code'] !=
                200) {
          return Lyrics(errorMessage: 'Track not found on Musixmatch');
        }

        final lyricsBody = macroCalls['track.lyrics.get']?['message']?['body'];
        final lyricsData = (lyricsBody is Map) ? lyricsBody['lyrics'] : null;
        if (lyricsData?['restricted'] == 1) {
          return Lyrics(errorMessage: 'Restricted lyrics');
        }

        List<SynchronizedLyric>? syncedLyrics;

        // Try richsync (word-level) first
        final richsyncCall = macroCalls['track.richsync.get'] as Map<String, dynamic>?;
        final rsMessageBody = richsyncCall?['message']?['body'];
        String? richsyncBody;
        if (rsMessageBody is Map) {
          richsyncBody = rsMessageBody['richsync']?['richsync_body'] as String?;
        }

        if (richsyncBody != null && richsyncBody.isNotEmpty) {
          syncedLyrics = _parseRichsync(richsyncBody);
        }

        // Fallback to standard line-level subtitles if no richsync
        if (syncedLyrics == null || syncedLyrics.isEmpty) {
          final subtitlesCall = macroCalls['track.subtitles.get'] as Map<String, dynamic>?;
          final subMessageBody = subtitlesCall?['message']?['body'];
          List<dynamic>? subtitleList;
          if (subMessageBody is Map) {
            subtitleList = subMessageBody['subtitle_list'] as List<dynamic>?;
          }

          if (subtitleList != null && subtitleList.isNotEmpty) {
            final subtitleBody = subtitleList[0]['subtitle']?['subtitle_body'] as String?;
            if (subtitleBody != null && subtitleBody.isNotEmpty) {
              syncedLyrics = _parseMxm(subtitleBody);
            }
          }
        }

        final plainLyrics = lyricsData?['lyrics_body'];
        final matchedTrack =
            macroCalls['matcher.track.get']?['message']?['body']?['track'];
        final commonTrackId = matchedTrack is Map
            ? matchedTrack['commontrack_id']?.toString()
            : null;
        final translationBody = commonTrackId == null
            ? null
            : await _fetchTranslatedSubtitle(commonTrackId, duration);
        final translatedLines = _parseTranslation(translationBody);

        if (syncedLyrics?.isNotEmpty == true && translatedLines.isNotEmpty) {
          attachLyricOverlay(
            syncedLyrics!,
            translatedLines,
            translation: true,
          );
        }

        return Lyrics(
          syncedLyrics: syncedLyrics,
          unsyncedLyrics: plainLyrics,
          unsyncedTranslatedLyrics: syncedLyrics?.isNotEmpty == true
              ? null
              : translationBody,
        );
      } else {
        return Lyrics(
          errorMessage: 'Failed with status: ${response.statusCode}',
        );
      }
    } catch (e) {
      return Lyrics(errorMessage: 'Error fetching lyrics: $e');
    }
  }

  String _translationLanguageCode() {
    try {
      final language = settings.language;
      if (language != null && language.trim().isNotEmpty) {
        return language
            .split(RegExp('[-_]'))
            .first
            .trim()
            .toLowerCase();
      }
    } catch (_) {
      // Settings may not be initialized in a standalone provider context.
    }
    return 'en';
  }

  Future<String?> _fetchTranslatedSubtitle(
    String commonTrackId,
    String duration,
  ) async {
    final language = _translationLanguageCode();
    final cacheKey = '$commonTrackId:$language';
    final cached = _translationCache[cacheKey];
    if (cached != null) return cached;

    final request = _requestTranslatedSubtitle(
      commonTrackId,
      duration,
      language,
    );
    _translationCache[cacheKey] = request;
    final translated = await request;
    // Don't make a temporary network error or expired token suppress this
    // translation for the lifetime of the provider instance.
    if (translated == null) _translationCache.remove(cacheKey);
    return translated;
  }

  Future<String?> _requestTranslatedSubtitle(
    String commonTrackId,
    String duration,
    String language,
  ) async {
    if (_usertoken == null) await _fetchTokenIfNeeded();
    if (_usertoken == null) return null;

    final parsedDuration = int.tryParse(duration);
    Uri makeUri() => Uri.https(
      'apic-appmobile.musixmatch.com',
      '/ws/1.1/track.subtitle.translation.get',
      {
        'format': 'json',
        'app_id': 'mac-ios-v2.0',
        'commontrack_id': commonTrackId,
        'selected_language': language,
        'min_completed': '0.7',
        if (parsedDuration != null && parsedDuration > 0)
          'f_subtitle_length': '$parsedDuration',
        if (parsedDuration != null && parsedDuration > 0)
          'f_subtitle_length_max_deviation': '10',
        'usertoken': _usertoken!,
      },
    );

    try {
      Future<http.Response> sendRequest() => http.get(
        makeUri(),
        headers: {
          'Host': 'apic-appmobile.musixmatch.com',
          'X-User-Agent':
              'Musixmatch/2025120901 CFNetwork/3860.300.31 Darwin/25.2.0',
          'Accept': 'application/json',
        },
      );

      var response = await sendRequest();
      if (response.statusCode != 200) return null;
      var data = jsonDecode(response.body);
      var status = data['message']?['header']?['status_code'];
      if (status == 401) {
        _usertoken = null;
        await _fetchTokenIfNeeded();
        if (_usertoken == null) return null;
        response = await sendRequest();
        if (response.statusCode != 200) return null;
        data = jsonDecode(response.body);
        status = data['message']?['header']?['status_code'];
      }
      if (status != 200) return null;

      final body = data['message']?['body'];
      final translated = body is Map ? body['subtitle_translated'] : null;
      if (translated is Map) {
        return translated['subtitle_body']?.toString();
      }
      return translated?.toString();
    } catch (error) {
      debugPrint('[MusixmatchProvider] Translation fetch failed: $error');
      return null;
    }
  }

  List<SynchronizedLyric> _parseTranslation(String? body) {
    if (body == null || body.trim().isEmpty) return [];
    final mxm = _parseMxm(body);
    if (mxm.isNotEmpty) return mxm;
    final enhanced = EnhancedLrcParser.parse(body);
    if (enhanced.isNotEmpty) return enhanced;
    final lrc = Lyrics.fromLRC(body);
    return lrc is Lyrics ? lrc.syncedLyrics ?? [] : [];
  }

  List<SynchronizedLyric> _parseRichsync(String body) {
    try {
      final List<SynchronizedLyric> result = [];
      final List<dynamic> lines = jsonDecode(body);

      for (var line in lines) {
        final startSec = (line['ts'] as num?)?.toDouble() ?? 0.0;
        final endSec = (line['te'] as num?)?.toDouble() ?? startSec;
        final wordsRaw = line['l'] as List<dynamic>? ?? [];

        final List<LyricWord> words = [];
        final StringBuffer fullText = StringBuffer();

        for (int i = 0; i < wordsRaw.length; i++) {
          final w = wordsRaw[i];
          final wordText = w['c']?.toString() ?? '';
          final offsetSec = (w['o'] as num?)?.toDouble() ?? 0.0;
          final wordStartMs = ((startSec + offsetSec) * 1000).toInt();

          double wordDurSec;
          if (i + 1 < wordsRaw.length) {
            final nextOffset = (wordsRaw[i + 1]['o'] as num?)?.toDouble() ?? offsetSec;
            wordDurSec = (nextOffset - offsetSec).clamp(0.05, 10.0);
          } else {
            wordDurSec = (endSec - (startSec + offsetSec)).clamp(0.1, 5.0);
          }

          words.add(LyricWord(
            offset: Duration(milliseconds: wordStartMs),
            duration: Duration(milliseconds: (wordDurSec * 1000).toInt()),
            text: wordText,
          ));
          fullText.write(wordText);
        }

        final lineOffsetMs = (startSec * 1000).toInt();
        final lineDurMs = ((endSec - startSec) * 1000).toInt();

        result.add(SynchronizedLyric(
          offset: Duration(milliseconds: lineOffsetMs),
          duration: Duration(milliseconds: lineDurMs > 0 ? lineDurMs : 3000),
          text: fullText.isNotEmpty ? fullText.toString() : (line['x']?.toString() ?? ''),
          words: words.isNotEmpty ? words : null,
        ));
      }

      return result;
    } catch (e) {
      debugPrint('[MusixmatchProvider] Error parsing richsync: $e');
      return [];
    }
  }

  List<SynchronizedLyric> _parseMxm(String body) {
    try {
      final List<SynchronizedLyric> result = [];
      final List<dynamic> lines = jsonDecode(body);

      for (var line in lines) {
        final timeData = line['time'];
        final text = line['text'];
        if (timeData != null && text != null) {
          final totalSec = timeData['total'] as num;
          result.add(
            SynchronizedLyric(
              offset: Duration(milliseconds: (totalSec * 1000).toInt()),
              text: text.toString(),
            ),
          );
        }
      }
      return result;
    } catch (e) {
      return [];
    }
  }
}
