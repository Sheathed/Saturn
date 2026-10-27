import '../../youtube_music_client.dart';
import '../../ytmusicapi_translations.dart';
import '../type_alias.dart';
import '../parsers/search.dart';
import '../continuations.dart';
import '../navigation.dart';

/// Search request methods following ytmusicapi's SearchMixin contract.
class SearchMixin {
  SearchMixin(this.client, {String Function(String)? translate})
    : _translate = translate;

  final YouTubeMusicClient client;
  final String Function(String)? _translate;

  Future<List<T>> searchMapped<T>(
    String query, {
    required String filter,
    int limit = 20,
    required T? Function(JsonDict renderer) parseResponsive,
    T? Function(JsonDict renderer)? parseMultiRow,
    T? Function(JsonDict renderer)? parseTwoRow,
    String Function(String)? translate,
  }) async {
    if (!filters.contains(filter)) {
      throw ArgumentError.value(filter, 'filter');
    }
    if (limit <= 0) {
      return [];
    }
    final response = await searchRaw(query, filter: filter);
    final contents = asJsonDict(response['contents']);
    final tabbed = asJsonDict(contents?['tabbedSearchResultsRenderer']);
    final tabs = asJsonList(tabbed?['tabs']);
    final results = tabs.isNotEmpty
        ? asJsonDict(nav(tabs.first, ['tabRenderer', 'content'], absent: true))
        : contents;
    if (results == null) {
      return [];
    }
    final sections = asJsonList(nav(results, sectionList, absent: true));
    final items = sections.isNotEmpty
        ? sections
        : <JsonDict>[
            if (asJsonDict(results['musicShelfRenderer']) != null)
              {'musicShelfRenderer': results['musicShelfRenderer']},
            if (asJsonDict(results['musicPlaylistShelfRenderer']) != null)
              {
                'musicPlaylistShelfRenderer':
                    results['musicPlaylistShelfRenderer'],
              },
          ];
    final output = <T>[];
    final internalFilter = filter.contains('playlists') ? 'playlists' : filter;
    final translations = await YTMusicApiTranslations.load(client.hl);
    final translateText = translate ?? _translate ?? translations.translate;
    final expectedCategory = translateText(
      internalFilter == 'playlists'
          ? 'playlist'
          : (internalFilter.endsWith('s')
                ? internalFilter.substring(0, internalFilter.length - 1)
                : internalFilter),
    );

    List<T> parseRows(List<dynamic> rows) {
      final parsed = <T>[];
      for (final value in rows) {
        final row = asJsonDict(value);
        if (row == null) {
          continue;
        }
        final responsive = asJsonDict(row[responsiveItem]);
        if (responsive != null) {
          final item = parseResponsive(responsive);
          if (item != null) {
            parsed.add(item);
          }
          continue;
        }
        final multi = asJsonDict(row[multiRowItem]);
        if (multi != null && parseMultiRow != null) {
          final item = parseMultiRow(multi);
          if (item != null) {
            parsed.add(item);
          }
        }
        final twoRow = asJsonDict(row[twoRowItem]);
        if (twoRow != null && parseTwoRow != null) {
          final item = parseTwoRow(twoRow);
          if (item != null) {
            parsed.add(item);
          }
        }
      }
      return parsed;
    }

    for (final section in items) {
      if (output.length >= limit) {
        break;
      }
      final shelf = asJsonDict(section['musicShelfRenderer']);
      final playlistShelf = asJsonDict(section['musicPlaylistShelfRenderer']);
      final itemSection = asJsonDict(section['itemSectionRenderer']);
      final contents = asJsonList(
        shelf?['contents'] ??
            playlistShelf?['contents'] ??
            itemSection?['contents'],
      );
      if (contents.isEmpty) {
        continue;
      }
      var category = nav(shelf, titleText, absent: true)?.toString();
      if (category == null && internalFilter == 'playlists') {
        category = nav(playlistShelf, titleText, absent: true)?.toString();
      }
      if (category != null &&
          !category.toLowerCase().contains(expectedCategory.toLowerCase())) {
        continue;
      }
      output.addAll(parseRows(contents).take(limit - output.length));
      if (shelf != null &&
          shelf.containsKey('continuations') &&
          output.length < limit) {
        final params = getSearchParams(filter: filter);
        final continued = await getContinuations<T>(
          initial: shelf,
          continuationType: 'musicShelfContinuation',
          limit: limit - output.length,
          request: (continuationParams) {
            final queryParams = Uri.splitQueryString(
              continuationParams.startsWith('&')
                  ? continuationParams.substring(1)
                  : continuationParams,
            );
            return client.post(
              'search',
              body: <String, dynamic>{'query': query, 'params': params},
              query: queryParams,
            );
          },
          parse: parseRows,
        );
        output.addAll(continued.take(limit - output.length));
      }
    }
    return output;
  }

  Future<JsonList> search(
    String query, {
    String? filter,
    String? scope,
    int limit = 20,
    bool ignoreSpelling = false,
    List<String>? localizedTypes,
  }) async {
    if (limit <= 0) {
      return [];
    }
    final response = await searchRaw(
      query,
      filter: filter,
      scope: scope,
      ignoreSpelling: ignoreSpelling,
    );
    final translations = await YTMusicApiTranslations.load(client.hl);
    final contents = asJsonDict(response['contents']);
    if (contents == null) {
      return [];
    }
    final tabbed = asJsonDict(contents['tabbedSearchResultsRenderer']);
    var results = contents;
    if (tabbed != null) {
      final tabs = asJsonList(tabbed['tabs']);
      final selectedTab = scope == null || filter != null
          ? 0
          : (scope == 'library' ? 1 : 2);
      if (selectedTab >= tabs.length) {
        return [];
      }
      final tab = asJsonDict(tabs[selectedTab]);
      results =
          asJsonDict(nav(tab, ['tabRenderer', 'content'], absent: true)) ??
          <String, dynamic>{};
    }
    final sections = asJsonList(nav(results, sectionList, absent: true));
    final parsed = <JsonDict>[];
    var internalFilter = filter;
    String? resultType;
    if (internalFilter != null && internalFilter.contains('playlists')) {
      internalFilter = 'playlists';
    } else if (scope == 'uploads') {
      internalFilter = 'uploads';
      resultType = 'upload';
    }

    for (final section in sections) {
      if (parsed.length >= limit) {
        break;
      }
      final card = asJsonDict(section['musicCardShelfRenderer']);
      if (card != null) {
        final translations = await YTMusicApiTranslations.load(client.hl);
        parsed.add(
          parseTopResult(
            card,
            localizedTypes ??
                allResultTypes.map(translations.translate).toList(),
          ),
        );
        final shelfRows = nav(section, [
          'musicCardShelfRenderer',
          'contents',
        ], absent: true);
        if (shelfRows is! List || shelfRows.isEmpty) {
          continue;
        }
        final rows = List<dynamic>.from(shelfRows);
        var category = nav(rows.first, [
          'messageRenderer',
          ...textRunText,
        ], absent: true);
        if (asJsonDict(asJsonDict(rows.first)?['messageRenderer']) != null) {
          rows.removeAt(0);
        }
        final found = parseSearchResults(
          rows,
          resultType: resultType,
          category: category?.toString(),
        );
        parsed.addAll(found.take(limit - parsed.length));
        continue;
      }

      final shelf = asJsonDict(section['musicShelfRenderer']);
      final itemSection = asJsonDict(section['itemSectionRenderer']);
      final shelfRows = asJsonList(
        shelf?['contents'] ?? itemSection?['contents'],
      );
      if (shelfRows.isEmpty ||
          asJsonDict(asJsonDict(shelfRows.first)?[responsiveItem]) == null) {
        continue;
      }
      final category = nav(shelf, titleText, absent: true)?.toString();
      if (internalFilter != null && scope != 'uploads' && category != null) {
        final expected = internalFilter == 'playlists'
            ? 'playlist'
            : internalFilter.endsWith('s')
            ? internalFilter.substring(0, internalFilter.length - 1)
            : internalFilter;
        final translatedExpected = (_translate ?? translations.translate)(
          expected,
        );
        if (!category.toLowerCase().contains(
          translatedExpected.toLowerCase(),
        )) {
          continue;
        }
        resultType = expected;
      }
      final found = parseSearchResults(
        shelfRows,
        resultType: resultType,
        category: category,
      );
      parsed.addAll(found.take(limit - parsed.length));

      if (shelf != null &&
          shelf.containsKey('continuations') &&
          parsed.length < limit) {
        final remaining = limit - parsed.length;
        final searchParams = getSearchParams(
          filter: filter,
          scope: scope,
          ignoreSpelling: ignoreSpelling,
        );
        final continued = await getContinuations<JsonDict>(
          initial: shelf,
          continuationType: 'musicShelfContinuation',
          limit: remaining,
          request: (params) {
            final queryParams = Uri.splitQueryString(
              params.startsWith('&') ? params.substring(1) : params,
            );
            return client.post(
              'search',
              body: <String, dynamic>{'query': query, 'params': ?searchParams},
              query: queryParams,
            );
          },
          parse: (rows) => parseSearchResults(
            rows,
            resultType: resultType,
            category: category,
          ),
        );
        parsed.addAll(continued.take(remaining));
      }
    }
    return parsed.take(limit).toList();
  }

  static const filters = <String>{
    'songs',
    'videos',
    'albums',
    'artists',
    'playlists',
    'community_playlists',
    'featured_playlists',
    'profiles',
    'podcasts',
    'episodes',
  };
  static const scopes = <String>{'library', 'uploads'};

  Future<JsonDict> searchRaw(
    String query, {
    String? filter,
    String? scope,
    bool ignoreSpelling = false,
  }) async {
    if (filter != null && !filters.contains(filter)) {
      throw ArgumentError.value(
        filter,
        'filter',
        'Unsupported ytmusicapi search filter',
      );
    }
    if (scope != null && !scopes.contains(scope)) {
      throw ArgumentError.value(
        scope,
        'scope',
        'Unsupported ytmusicapi search scope',
      );
    }
    if (scope == 'uploads' && filter != null) {
      throw ArgumentError('Search filters cannot be used with uploads scope.');
    }
    if (scope == 'library' &&
        (filter == 'community_playlists' || filter == 'featured_playlists')) {
      throw ArgumentError('This filter cannot be used with library scope.');
    }

    final params = getSearchParams(
      filter: filter,
      scope: scope,
      ignoreSpelling: ignoreSpelling,
    );
    return client.post(
      'search',
      body: <String, dynamic>{'query': query, 'params': ?params},
    );
  }

  /// Sends a search using an already encoded upstream params value.
  Future<JsonDict> searchWithParamsRaw(String query, String params) {
    return client.post('search', body: {'query': query, 'params': params});
  }

  Future<JsonDict> suggestionsRaw(String query) {
    return client.post('music/get_search_suggestions', body: {'input': query});
  }

  Future<List<dynamic>> getSearchSuggestions(
    String query, {
    bool detailedRuns = false,
  }) async {
    final response = await suggestionsRaw(query);
    return parseSearchSuggestions(response, detailedRuns: detailedRuns);
  }

  Future<JsonDict> removeSearchSuggestionsRaw(List<String> feedbackTokens) {
    if (feedbackTokens.isEmpty) {
      throw ArgumentError('At least one history feedback token is required.');
    }
    return client.post('feedback', body: {'feedbackTokens': feedbackTokens});
  }

  Future<bool> removeSearchSuggestions(
    List<dynamic> suggestions, {
    List<int>? indices,
  }) async {
    if (!suggestions.any(
      (value) => asJsonDict(value)?['fromHistory'] == true,
    )) {
      throw ArgumentError('No history suggestions were provided.');
    }
    final chosen =
        indices ?? List<int>.generate(suggestions.length, (index) => index);
    if (chosen.any((index) => index < 0 || index >= suggestions.length)) {
      throw RangeError('Search suggestion index is out of range.');
    }
    final tokens = chosen
        .map((index) => asJsonDict(suggestions[index])?['feedbackToken'])
        .whereType<String>()
        .toList();
    if (tokens.isEmpty) {
      return false;
    }
    final response = await removeSearchSuggestionsRaw(tokens);
    return nav(response, [
          'feedbackResponses',
          0,
          'isProcessed',
        ], absent: true) ==
        true;
  }
}
