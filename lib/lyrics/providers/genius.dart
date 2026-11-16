import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import '../../api/definitions.dart';
import '../lyrics_provider.dart';

const _lyricsBlockElements = {'div', 'p', 'li', 'section', 'h1', 'h2', 'h3'};

String _lyricsNodeText(dom.Node node) {
  if (node is dom.Text) return node.data;
  if (node is dom.Element && node.localName == 'br') return '\n';

  final text = node.nodes.map(_lyricsNodeText).join();
  if (node is dom.Element &&
      _lyricsBlockElements.contains(node.localName) &&
      text.trim().isNotEmpty) {
    final separator = node.localName == 'p' || node.localName == 'section'
        ? '\n\n'
        : '\n';
    return '$text$separator';
  }
  return text;
}

String _normalizeLyrics(String lyrics) {
  final lines = lyrics
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll('\u00a0', ' ')
      .split('\n')
      .map((line) => line.replaceAll(RegExp(r'[\t ]+'), ' ').trim())
      .toList();

  final normalized = <String>[];
  var previousWasBlank = false;
  for (final line in lines) {
    final isBlank = line.isEmpty;
    if (isBlank && (normalized.isEmpty || previousWasBlank)) continue;
    normalized.add(line);
    previousWasBlank = isBlank;
  }
  return normalized.join('\n').trim();
}

class GeniusLyricsProvider extends LyricsProvider {
  @override
  String get id => 'genius';

  @override
  String get name => 'Genius';

  @override
  Future<Lyrics> getLyrics(Track track) async {
    final title = track.title ?? '';
    final artistStr = track.artistString ?? '';

    final query = '$title $artistStr'.trim();
    if (query.isEmpty) {
      return Lyrics(errorMessage: 'Empty query');
    }

    final searchUri = Uri.parse(
      'https://genius.com/api/search/multi?per_page=5&q=${Uri.encodeComponent(query)}',
    );
    debugPrint('[GeniusProvider] Searching: $searchUri');

    try {
      final searchResponse = await http.get(searchUri);
      debugPrint(
        '[GeniusProvider] Search Response Code: ${searchResponse.statusCode}',
      );
      debugPrint(
        '[GeniusProvider] Search Response Body: ${searchResponse.body}',
      );

      if (searchResponse.statusCode != 200) {
        return Lyrics(
          errorMessage: 'Genius search failed: ${searchResponse.statusCode}',
        );
      }

      final data = jsonDecode(searchResponse.body);
      final sections = data['response']['sections'] as List<dynamic>?;
      if (sections == null) return Lyrics(errorMessage: 'No results');

      final songSection = sections.firstWhere(
        (s) => s['type'] == 'song',
        orElse: () => null,
      );

      if (songSection == null || songSection['hits'].isEmpty) {
        return Lyrics(errorMessage: 'No song match found');
      }

      final hit = songSection['hits'][0]['result'];
      final String url = hit['url'];

      debugPrint('[GeniusProvider] Fetching lyrics from: $url');
      final lyricsResponse = await http.get(Uri.parse(url));

      if (lyricsResponse.statusCode != 200) {
        return Lyrics(errorMessage: 'Failed to fetch lyrics page');
      }

      final document = html_parser.parse(lyricsResponse.body);
      final containers = document.querySelectorAll(
        '[data-lyrics-container="true"]',
      );
      if (containers.isEmpty) {
        return Lyrics(errorMessage: 'Could not parse lyrics from page');
      }

      // Genius nests block elements inside each lyrics container. Regex that
      // stops at the first closing div truncates the rest of the song. Parse
      // the DOM so nested verse/line wrappers are traversed in full.
      var finalLyrics = _normalizeLyrics(
        containers.map(_lyricsNodeText).join('\n\n'),
      );

      // Clean up common Genius fluff at the top (e.g. "71 ContributorsTranslations...")
      finalLyrics = finalLyrics.replaceFirst(
        RegExp(r'^\d*\s*Contributors?[^\n]*\n*'),
        '',
      );

      // Some Genius pages start with "Song Name Lyrics"
      finalLyrics = finalLyrics.replaceFirst(RegExp(r'^[^\n]*?Lyrics\n+'), '');

      // Clean up "Embed" at the very end
      finalLyrics = finalLyrics
          .replaceFirst(RegExp(r'\d*\s*Embed$'), '')
          .trim();

      if (finalLyrics.isEmpty) {
        return Lyrics(errorMessage: 'Parsed lyrics were empty');
      }

      return Lyrics(
        syncedLyrics: null, // Genius rarely has synced lyrics via web scraper
        unsyncedLyrics: finalLyrics,
      );
    } catch (e) {
      debugPrint('[GeniusProvider] Error: $e');
      return Lyrics(errorMessage: 'Error fetching Genius lyrics: $e');
    }
  }
}
