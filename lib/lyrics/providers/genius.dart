import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../../api/definitions.dart';
import '../lyrics_provider.dart';

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

    final searchUri = Uri.parse('https://genius.com/api/search/multi?per_page=5&q=${Uri.encodeComponent(query)}');
    debugPrint('[GeniusProvider] Searching: $searchUri');

    try {
      final searchResponse = await http.get(searchUri);
      debugPrint('[GeniusProvider] Search Response Code: ${searchResponse.statusCode}');
      debugPrint('[GeniusProvider] Search Response Body: ${searchResponse.body}');
      
      if (searchResponse.statusCode != 200) {
        return Lyrics(errorMessage: 'Genius search failed: ${searchResponse.statusCode}');
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

      final html = lyricsResponse.body;
      
      // Simple regex extraction for Genius lyrics container
      // This looks for <div data-lyrics-container="true" class="...">...</div>
      final RegExp lyricsRegex = RegExp(
        r'<div data-lyrics-container="true"[^>]*>(.*?)<\/div>',
        multiLine: true,
        dotAll: true,
      );

      final matches = lyricsRegex.allMatches(html);
      if (matches.isEmpty) {
        return Lyrics(errorMessage: 'Could not parse lyrics from page');
      }

      StringBuffer plainLyrics = StringBuffer();
      for (final match in matches) {
        String containerContent = match.group(1) ?? '';
        
        // Clean up HTML tags
        // 1. Replace <br/> or <br> with newlines
        containerContent = containerContent.replaceAll(RegExp(r'<br\s*\/?>', caseSensitive: false), '\n');
        
        // 2. Remove all other HTML tags
        containerContent = containerContent.replaceAll(RegExp(r'<[^>]*>'), '');
        
        // 3. Decode HTML entities (basic ones)
        containerContent = containerContent
            .replaceAll('&amp;', '&')
            .replaceAll('&lt;', '<')
            .replaceAll('&gt;', '>')
            .replaceAll('&quot;', '"')
            .replaceAll('&#x27;', "'")
            .replaceAll('&#x2005;', ' ');
            
        plainLyrics.writeln(containerContent.trim());
        plainLyrics.writeln(); // Blank line between containers
      }

      var finalLyrics = plainLyrics.toString().trim();
      
      // Clean up common Genius fluff at the top (e.g. "71 ContributorsTranslations...")
      finalLyrics = finalLyrics.replaceFirst(RegExp(r'^\d*\s*Contributors?[^\n]*\n*'), '');
      
      // Some Genius pages start with "Song Name Lyrics"
      finalLyrics = finalLyrics.replaceFirst(RegExp(r'^[^\n]*?Lyrics\n+'), '');
      
      // Clean up "Embed" at the very end
      finalLyrics = finalLyrics.replaceFirst(RegExp(r'\d*\s*Embed$'), '').trim();

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
