import 'dart:collection';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:material_ui/material_ui.dart';
import 'package:silky_scroll/silky_scroll.dart';
import 'package:saturn/ui/smooth_scroll_config.dart';

import '../../translations.i18n.dart';

import '../../api/definitions.dart';
import '../../service/audio_service.dart';
import '../../ui/details_screens.dart';
import '../../ui/elements.dart';
import '../../ui/error.dart';
import '../../ui/home_screen.dart';
import '../../ui/menu.dart';
import '../../ui/tiles.dart';
import '../platform_registry.dart';
import 'parsers/item_parsers.dart';
import 'youtube_music_api.dart';
import 'youtube_music_platform.dart';
import 'youtube_music_speed_dial.dart';
import 'youtube_music_tiles.dart';

/// Full-featured YouTube Music Browse and Home widget matching Metrolist styling and behavior.
class YouTubeMusicBrowseWidget extends StatefulWidget {
  final String browseId;
  final String? params;
  final String? title;
  final YouTubeMusicApi? api;

  const YouTubeMusicBrowseWidget({
    super.key,
    this.browseId = 'FEmusic_home',
    this.params,
    this.title,
    this.api,
  });

  @override
  State<YouTubeMusicBrowseWidget> createState() =>
      _YouTubeMusicBrowseWidgetState();
}

class _YouTubeMusicBrowseWidgetState extends State<YouTubeMusicBrowseWidget> {
  late YouTubeMusicApi _api;
  final ScrollController _scrollController = ScrollController();
  // Building a section parses raw Innertube JSON; keep the result per section.
  final Map<Object, Widget> _sectionWidgetCache = HashMap.identity();

  bool _loading = true;
  bool _loadingMore = false;
  String? _error;

  List<dynamic> _sections = [];
  List<Map<String, dynamic>> _chips = [];
  int? _selectedChipIndex;

  String? _continuationToken;
  List<YouTubeMusicSpeedDialItem> _speedDialItems = [];
  Map<String, YouTubeMusicSpeedDialItem> _listenAgainItemsById = {};
  String? _listenAgainBrowseId;
  String? _listenAgainParams;

  bool get _isDesktop =>
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.macOS;

  @override
  void initState() {
    super.initState();
    final platform = PlatformRegistry.instance.get('youtube_music');
    if (widget.api != null) {
      _api = widget.api!;
    } else if (platform is YouTubeMusicPlatform) {
      _api = platform.api;
    } else {
      _api = YouTubeMusicApi();
    }

    YouTubeMusicSpeedDialManager.instance.addListener(_onListenAgainChanged);
    _scrollController.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    YouTubeMusicSpeedDialManager.instance.removeListener(_onListenAgainChanged);
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onListenAgainChanged() {
    if (!mounted) return;
    YouTubeMusicSpeedDialItem syncItem(YouTubeMusicSpeedDialItem item) {
      final data = YouTubeMusicParsers.listenAgainDataFor(item.id);
      if (data == null || !data.hasTokens) return item;
      return item.withListenAgainTokens(
        pinToken: data.pinFeedbackToken,
        unpinToken: data.unpinFeedbackToken,
        isPinned: data.isPinned,
      );
    }

    setState(() {
      _sectionWidgetCache.clear();
      _speedDialItems = _speedDialItems.map(syncItem).toList();
      _listenAgainItemsById.updateAll((_, item) => syncItem(item));
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Cached sections capture theme-derived values when built.
    _sectionWidgetCache.clear();
  }

  void _onScroll() {
    if (_continuationToken == null || _loadingMore || _loading) return;
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 400) {
      _loadMore();
    }
  }

  int _loadGeneration = 0;

  Future<void> _load({String? chipParams}) async {
    if (!mounted) return;
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      String cleanBrowseId = widget.browseId;
      String? cleanParams = widget.params;
      if (cleanBrowseId.contains('?')) {
        final uri = Uri.tryParse(cleanBrowseId);
        if (uri != null) {
          if (uri.path.isNotEmpty) cleanBrowseId = uri.path;
          cleanParams ??= uri.queryParameters['params'];
        }
      }
      if (cleanBrowseId.startsWith('/')) {
        cleanBrowseId = cleanBrowseId.substring(1);
      }

      final body = <String, dynamic>{
        'browseId': cleanBrowseId,
        if (chipParams != null || cleanParams != null)
          'params': chipParams ?? cleanParams,
      };

      final res = await _api.client.post('browse', body: body);
      if (!mounted || generation != _loadGeneration) return;

      final contentsMap = res['contents'] as Map<dynamic, dynamic>?;
      final singleColumn =
          contentsMap?['singleColumnBrowseResultsRenderer']
              as Map<dynamic, dynamic>?;
      final tabs = singleColumn?['tabs'] as List?;

      Map<dynamic, dynamic>? sectionList;
      if (tabs != null && tabs.isNotEmpty && tabs[0] is Map) {
        final tab = tabs[0] as Map;
        sectionList =
            tab['tabRenderer']?['content']?['sectionListRenderer']
                as Map<dynamic, dynamic>?;
      }
      sectionList ??=
          singleColumn?['sectionListRenderer'] as Map<dynamic, dynamic>?;

      List<dynamic> contents = [];
      if (sectionList != null) {
        contents = (sectionList['contents'] as List? ?? []);
        // Continuation token
        final continuations = sectionList['continuations'] as List?;
        if (continuations != null && continuations.isNotEmpty) {
          final firstCont = continuations[0] as Map<dynamic, dynamic>?;
          _continuationToken =
              firstCont?['nextContinuationData']?['continuation'] as String?;
        } else {
          _continuationToken = null;
        }

        // Parse Chips (only update chips if not already in a sub-chip view)
        if (chipParams == null && widget.params == null) {
          final header = sectionList['header'] as Map<dynamic, dynamic>?;
          final chipCloud =
              header?['chipCloudRenderer']?['chips'] as List? ??
              header?['sectionListRenderer']?['header']?['chipCloudRenderer']?['chips']
                  as List?;
          if (chipCloud != null) {
            _chips = chipCloud
                .whereType<Map>()
                .map((c) => c['chipCloudChipRenderer'] as Map<String, dynamic>?)
                .whereType<Map<String, dynamic>>()
                .toList();
          }
        }
      } else {
        // Fallback for direct contents / grid renderers
        contents = (singleColumn?['contents'] as List? ?? []);
      }

      final displaySections = List<dynamic>.from(contents);
      // Index first: it records which renderers carry Listen-again tokens so
      // the section detection below never has to re-parse every menu.
      _listenAgainItemsById = {};
      final tokenRenderers = HashSet<Object>.identity();
      await _indexListenAgainActions(contents, tokenRenderers);
      if (!mounted || generation != _loadGeneration) return;

      Map<dynamic, dynamic>? listenAgainSection;
      for (final section in contents) {
        final carousel = section['musicCarouselShelfRenderer'];
        if (carousel == null) continue;
        final sectionTitle = YouTubeMusicParsers.parseRuns(
          carousel['header']?['musicCarouselShelfBasicHeaderRenderer']?['title'],
        );
        final titleLower = sectionTitle.toLowerCase();
        final hasListenAgainTitle =
            titleLower.contains('listen again') ||
            titleLower.contains('écouter à nouveau') ||
            titleLower.contains('ecouter a nouveau') ||
            titleLower.contains('volver a escuchar') ||
            titleLower.contains('wieder ansehen') ||
            titleLower.contains('ouvir novamente') ||
            titleLower.contains('di nuovo');

        final carouselContents = carousel['contents'] as List? ?? [];
        final hasListenAgainItems = carouselContents.any((c) {
          if (c is! Map) return false;
          final renderer =
              c['musicTwoRowItemRenderer'] ??
              c['musicResponsiveListItemRenderer'] ??
              c['musicMultiRowListItemRenderer'];
          return renderer is Map && tokenRenderers.contains(renderer);
        });

        if (hasListenAgainTitle || hasListenAgainItems) {
          listenAgainSection = section as Map<dynamic, dynamic>;
          break;
        }
      }
      final listenAgainRawItems =
          listenAgainSection?['musicCarouselShelfRenderer']?['contents']
              as List? ??
          [];
      if (!_isDesktop &&
          widget.browseId == 'FEmusic_home' &&
          _selectedChipIndex == null) {
        if (listenAgainSection != null) {
          final headerRenderer =
              listenAgainSection['musicCarouselShelfRenderer']?['header']
                  ?['musicCarouselShelfBasicHeaderRenderer'];
          final moreBtn =
              headerRenderer?['moreContentButton']?['buttonRenderer'];
          final titleRuns =
              headerRenderer?['title']?['runs'] as List? ?? [];
          final titleNav =
              (titleRuns.isNotEmpty && titleRuns[0]['navigationEndpoint'] != null)
                  ? titleRuns[0]['navigationEndpoint']
                  : null;
          final nav = moreBtn?['navigationEndpoint'] ?? titleNav;
          if (nav != null && nav['browseEndpoint'] != null) {
            _listenAgainBrowseId = nav['browseEndpoint']['browseId'] as String?;
            _listenAgainParams = nav['browseEndpoint']['params'] as String?;
          }
          displaySections.remove(listenAgainSection);
        }
        _buildSpeedDialFromContents(keepListening: listenAgainRawItems);
      } else {
        _speedDialItems = [];
      }

      if (mounted) {
        setState(() {
          _sectionWidgetCache.clear();
          _sections = displaySections;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  /// Walks the raw response looking for Listen-again renderers. A cheap menu
  /// check gates the (expensive) full item parse, and the walk periodically
  /// yields so a large home page cannot block a frame. Renderers that carry
  /// pin tokens are added to [tokenRenderers] (by identity).
  Future<void> _indexListenAgainActions(
    dynamic root,
    Set<Object> tokenRenderers,
  ) async {
    final stack = <dynamic>[root];
    var processed = 0;
    while (stack.isNotEmpty) {
      final value = stack.removeLast();
      if (value is Map) {
        for (final entry in value.entries) {
          final key = entry.key.toString();
          final child = entry.value;
          if (child is Map &&
              (key == 'musicTwoRowItemRenderer' ||
                  key == 'musicResponsiveListItemRenderer' ||
                  key == 'musicMultiRowListItemRenderer')) {
            if (++processed % 6 == 0) {
              await Future<void>.delayed(Duration.zero);
              if (!mounted) return;
            }
            final menuData = YouTubeMusicParsers.parseListenAgainMenuData(
              child is Map<String, dynamic>
                  ? child
                  : Map<String, dynamic>.from(child),
            );
            if (!menuData.hasTokens) continue;
            tokenRenderers.add(child);
            final item = YouTubeMusicSpeedDialItem.fromDynamic({key: child});
            if (item != null && item.id.isNotEmpty) {
              YouTubeMusicParsers.updateListenAgainData(
                item.id,
                YouTubeMusicListenAgainData(
                  isPinned: item.isPinnedInYouTubeMusic,
                  pinFeedbackToken: item.pinFeedbackToken,
                  unpinFeedbackToken: item.unpinFeedbackToken,
                ),
              );
              _listenAgainItemsById[item.id] = item;
              if (item.secondaryId != null && item.secondaryId!.isNotEmpty) {
                _listenAgainItemsById[item.secondaryId!] = item;
              }
              if (item.id.startsWith('VL')) {
                _listenAgainItemsById[item.id.substring(2)] = item;
              } else if (item.id.startsWith('PL')) {
                _listenAgainItemsById['VL${item.id}'] = item;
              }
            }
          }
        }
        // Push children reversed so they are visited in document order.
        final children = value.values.toList(growable: false);
        for (var i = children.length - 1; i >= 0; i--) {
          final c = children[i];
          if (c is Map || c is List) stack.add(c);
        }
      } else if (value is List) {
        for (var i = value.length - 1; i >= 0; i--) {
          final c = value[i];
          if (c is Map || c is List) stack.add(c);
        }
      }
    }
  }

  void _buildSpeedDialFromContents({required List<dynamic> keepListening}) {
    _speedDialItems = YouTubeMusicSpeedDialManager.instance.buildSpeedDialItems(
      keepListening: keepListening,
    );
  }

  void _refreshSpeedDial() {
    String? chipParams;
    if (_selectedChipIndex != null && _selectedChipIndex! < _chips.length) {
      chipParams =
          _chips[_selectedChipIndex!]['navigationEndpoint']?['browseEndpoint']?['params']
              as String?;
    }
    _load(chipParams: chipParams);
  }

  Future<void> _loadMore() async {
    if (_continuationToken == null || _loadingMore) return;
    setState(() => _loadingMore = true);

    try {
      final res = await _api.client.post(
        'browse',
        body: {'continuation': _continuationToken},
      );

      final continuationContents =
          res['continuationContents']?['sectionListContinuation'];
      final newSections = continuationContents?['contents'] as List? ?? [];

      final nextContinuations = continuationContents?['continuations'] as List?;
      if (nextContinuations != null && nextContinuations.isNotEmpty) {
        _continuationToken =
            nextContinuations[0]?['nextContinuationData']?['continuation']
                as String?;
      } else {
        _continuationToken = null;
      }
      await _indexListenAgainActions(newSections, HashSet<Object>.identity());

      if (mounted) {
        setState(() {
          _sections.addAll(newSections);
          _loadingMore = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _toggleChip(int index) {
    if (_selectedChipIndex == index) {
      // Deselect chip and restore full home page
      _selectedChipIndex = null;
      _load();
    } else {
      // Select chip
      _selectedChipIndex = index;
      final chip = _chips[index];
      final endpoint = chip['navigationEndpoint']?['browseEndpoint'];
      final params = endpoint?['params'] as String?;
      _load(chipParams: params);
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget content;
    if (_loading) {
      content = const Center(child: CircularProgressIndicator());
    } else if (_error != null) {
      content = ErrorScreen(message: _error);
    } else {
      content = RefreshIndicator(
        onRefresh: () {
          String? chipParam;
          if (_selectedChipIndex != null &&
              _selectedChipIndex! < _chips.length) {
            chipParam =
                _chips[_selectedChipIndex!]['navigationEndpoint']?['browseEndpoint']?['params']
                    as String?;
          }
          return _load(chipParams: chipParam);
        },
        child: SilkyListView.builder(
          silkyConfig: silkyScrollConfig,
          controller: _scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 32, top: 4),
          itemCount: _calculateItemCount(),
          itemBuilder: (context, index) {
            return _buildListItem(index);
          },
        ),
      );
    }

    if (widget.title != null) {
      return Scaffold(
        appBar: FreezerAppBar(widget.title!),
        body: content,
      );
    }

    return content;
  }

  int _calculateItemCount() {
    int count = 0;
    if (_chips.isNotEmpty) count++; // Chips bar
    if (!_isDesktop &&
        widget.browseId == 'FEmusic_home' &&
        _selectedChipIndex == null &&
        _speedDialItems.isNotEmpty) {
      count++; // Mobile Listen again presentation
    }
    count += _sections.length;
    if (_loadingMore) count++; // Loading indicator at bottom
    return count;
  }

  Widget _buildListItem(int index) {
    int currentIndex = index;

    // 1. Top Filter Chips Bar
    if (_chips.isNotEmpty) {
      if (currentIndex == 0) {
        return _buildChipsBar();
      }
      currentIndex--;
    }

    // 2. Mobile Listen again section
    if (!_isDesktop &&
        widget.browseId == 'FEmusic_home' &&
        _selectedChipIndex == null &&
        _speedDialItems.isNotEmpty) {
      if (currentIndex == 0) {
        return SpeedDialSection(
          items: _speedDialItems,
          onRefreshNeeded: _refreshSpeedDial,
          onSendFeedback: _api.sendFeedbackToken,
          browseId: _listenAgainBrowseId,
          params: _listenAgainParams,
          onSeeMore: _listenAgainBrowseId != null
              ? () {
                  final browseId = _listenAgainBrowseId!;
                  if (browseId.startsWith('VL') || browseId.startsWith('PL')) {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => PlaylistDetails(
                          Playlist(
                            id: browseId,
                            title: 'Listen again'.i18n,
                            platformId: 'youtube_music',
                          ),
                        ),
                      ),
                    );
                  } else {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => YouTubeMusicBrowseWidget(
                          browseId: browseId,
                          params: _listenAgainParams,
                          title: 'Listen again'.i18n,
                          api: _api,
                        ),
                      ),
                    );
                  }
                }
              : null,
        );
      }
      currentIndex--;
    }

    // 3. Section Content
    if (currentIndex < _sections.length) {
      return _buildSection(_sections[currentIndex]);
    }

    // 4. Loading More Spinner
    if (_loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24.0),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    return const SizedBox.shrink();
  }

  Widget _buildChipsBar() {
    final colorScheme = Theme.of(context).colorScheme;
    final primaryColorId = colorScheme.primary.toARGB32();
    final containerColorId = colorScheme.surfaceContainerHigh.toARGB32();

    return Container(
      height: 48,
      margin: const EdgeInsets.only(bottom: 4.0),
      child: SilkyListView.builder(
        silkyConfig: silkyHorizontalScrollConfig,
        key: ValueKey('chips_list_${primaryColorId}_$containerColorId'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12.0),
        itemCount: _chips.length,
        itemBuilder: (context, i) {
          final chip = _chips[i];
          final title = YouTubeMusicParsers.parseRuns(chip['text']);
          final isSelected = _selectedChipIndex == i;

          return Padding(
            key: ValueKey('chip_pad_${i}_${title}_${primaryColorId}_$isSelected'),
            padding: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 6.0),
            child: FilterChip(
              key: ValueKey('chip_${i}_${title}_${primaryColorId}_$isSelected'),
              label: Text(
                title,
                style: TextStyle(
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                  fontSize: 13.5,
                  color: isSelected
                      ? colorScheme.onPrimaryContainer
                      : colorScheme.onSurface,
                ),
              ),
              selected: isSelected,
              selectedColor: colorScheme.primaryContainer,
              backgroundColor: colorScheme.surfaceContainerHigh,
              showCheckmark: false,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(
                  color: isSelected
                      ? colorScheme.primary
                      : colorScheme.outlineVariant.withValues(alpha: 0.4),
                  width: 1,
                ),
              ),
              onSelected: (_) => _toggleChip(i),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSection(dynamic section) {
    if (section is! Map) return const SizedBox.shrink();
    return _sectionWidgetCache.putIfAbsent(
      section,
      () => _buildSectionUncached(section),
    );
  }

  Widget _buildSectionUncached(Map section) {
    if (section['musicCarouselShelfRenderer'] != null) {
      return _buildCarouselShelf(section['musicCarouselShelfRenderer']);
    } else if (section['gridRenderer'] != null) {
      return _buildGridRenderer(section['gridRenderer']);
    } else if (section['musicShelfRenderer'] != null) {
      return _buildMusicShelf(section['musicShelfRenderer']);
    } else if (section['musicPlaylistShelfRenderer'] != null) {
      return _buildMusicShelf(section['musicPlaylistShelfRenderer']);
    }

    return const SizedBox.shrink();
  }

  Widget _buildCarouselShelf(Map<dynamic, dynamic> carousel) {
    final headerRenderer =
        carousel['header']?['musicCarouselShelfBasicHeaderRenderer'];
    final title = YouTubeMusicParsers.parseRuns(headerRenderer?['title']);
    final strapline = YouTubeMusicParsers.parseRuns(
      headerRenderer?['strapline'],
    );
    final thumbObj = headerRenderer?['thumbnail'];
    final headerThumb =
        thumbObj?['musicThumbnailRenderer']?['thumbnail'] ?? thumbObj;
    final headerImageUrl = YouTubeMusicParsers.parseImageDetails(
      headerThumb,
    )?.fullUrl;

    final moreBtn = headerRenderer?['moreContentButton']?['buttonRenderer'];
    final titleRuns = headerRenderer?['title']?['runs'] as List? ?? [];
    final titleNav =
        (titleRuns.isNotEmpty && titleRuns[0]['navigationEndpoint'] != null)
        ? titleRuns[0]['navigationEndpoint']
        : null;
    final nav = moreBtn?['navigationEndpoint'] ?? titleNav;

    String? pagePath;
    String? moreParams;
    if (nav != null) {
      if (nav['browseEndpoint'] != null) {
        pagePath = nav['browseEndpoint']['browseId'] as String?;
        moreParams = nav['browseEndpoint']['params'] as String?;
      } else if (nav['watchEndpoint'] != null) {
        final videoId = nav['watchEndpoint']['videoId'] as String?;
        final playlistId = nav['watchEndpoint']['playlistId'] as String?;
        if (playlistId != null && playlistId.startsWith('RD')) {
          pagePath = 'mix:${videoId ?? playlistId.substring(2)}';
        } else if (playlistId != null) {
          pagePath = 'playlist:$playlistId';
        } else if (videoId != null) {
          pagePath = 'play:$videoId';
        }
      }
    }

    final items = carousel['contents'] as List? ?? [];
    if (items.isEmpty) return const SizedBox.shrink();

    final isSongList = items.any(
      (it) =>
          it['musicResponsiveListItemRenderer'] != null &&
          !_responsiveItemHasPodcastShow(it['musicResponsiveListItemRenderer']),
    );

    final isMultiRow = !isSongList && items.any(
      (it) =>
          it['musicMultiRowListItemRenderer'] != null ||
          (it['musicResponsiveListItemRenderer'] != null &&
              _responsiveItemHasPodcastShow(
                it['musicResponsiveListItemRenderer'],
              )),
    );

    final isNavButtons = items.any(
      (it) => it['musicNavigationButtonRenderer'] != null,
    );

    final isArtistChart =
        !isNavButtons &&
        items.isNotEmpty &&
        items.every((item) {
          if (item is! Map) return false;
          final renderer = item['musicResponsiveListItemRenderer'];
          if (renderer is! Map) return false;
          final navigation = renderer['navigationEndpoint'];
          final endpoint = navigation is Map
              ? navigation['browseEndpoint']
              : null;
          final endpointConfig = endpoint is Map
              ? endpoint['browseEndpointContextSupportedConfigs']
              : null;
          final musicConfig = endpointConfig is Map
              ? endpointConfig['browseEndpointContextMusicConfig']
              : null;
          final pageType = musicConfig is Map ? musicConfig['pageType'] : null;
          return pageType == 'MUSIC_PAGE_TYPE_ARTIST' &&
              renderer['customIndexColumn'] != null;
        });

    if (isArtistChart) {
      final artists = <Artist>[];
      for (final item in items) {
        final renderer = item['musicResponsiveListItemRenderer'];
        if (renderer is! Map) continue;
        final artist =
            YouTubeMusicParsers.parseChartArtistFromResponsiveListItem(
              Map<String, dynamic>.from(renderer),
            );
        if (artist != null) artists.add(artist);
      }
      return YouTubeMusicArtistChart(
        title: title,
        artists: artists,
        onArtistTap: (artist) => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => ArtistDetails(artist)),
        ),
      );
    }

    // Two-row standard items (Albums, Playlists, Artists, Shows, Radios)
    if (!isSongList && !isMultiRow && !isNavButtons) {
      final parsed = YouTubeMusicParsers.parseBrowseSection({
        'musicCarouselShelfRenderer': carousel,
      });
      if (parsed != null && parsed.items.isNotEmpty) {
        return HomepageRowSection(parsed);
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section Header
        if (title.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(6.0, 8.0, 6.0, 8.0),
            child: Row(
              children: [
                if (headerImageUrl != null && headerImageUrl.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(right: 12.0),
                    child: ClipOval(
                      child: CachedNetworkImage(
                        imageUrl: headerImageUrl,
                        width: 48,
                        height: 48,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (headerImageUrl != null &&
                          headerImageUrl.isNotEmpty &&
                          strapline.isNotEmpty)
                        Text(
                          strapline,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14.0,
                            color: Theme.of(context).textTheme.bodySmall?.color,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      Text(
                        title,
                        textAlign: TextAlign.left,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 20.0,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      if ((headerImageUrl == null || headerImageUrl.isEmpty) &&
                          strapline.isNotEmpty)
                        Text(
                          strapline,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14.0,
                            color: Theme.of(context).textTheme.bodySmall?.color,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                    ],
                  ),
                ),
                if (pagePath != null)
                  Builder(
                    builder: (context) {
                      final String path = pagePath!;
                      return OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20),
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                        ),
                        onPressed: () {
                          if (path.startsWith('play:')) {
                            final id = path.substring(5);
                            GetIt.I<AudioPlayerHandler>().playMix(
                              id,
                              title,
                              platformId: 'youtube_music',
                            );
                          } else if (path.startsWith('mix:')) {
                            final id = path.substring(4);
                            GetIt.I<AudioPlayerHandler>().playMix(
                              id,
                              title,
                              platformId: 'youtube_music',
                            );
                          } else if (path.startsWith('VLRD') || path.startsWith('RD')) {
                            final cleanId = path.startsWith('VL') ? path.substring(2) : path;
                            GetIt.I<AudioPlayerHandler>().playMix(
                              cleanId,
                              title,
                              platformId: 'youtube_music',
                            );
                          } else if (path.startsWith('playlist:')) {
                            final id = path.substring(9);
                            GetIt.I<AudioPlayerHandler>().playFromPlaylist(
                              Playlist(id: id, platformId: 'youtube_music'),
                              '',
                            );
                          } else if (path.startsWith('VL') || path.startsWith('PL')) {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => PlaylistDetails(
                                  Playlist(
                                    id: path,
                                    title: title,
                                    platformId: 'youtube_music',
                                  ),
                                ),
                              ),
                            );
                          } else {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => YouTubeMusicBrowseWidget(
                                  browseId: path,
                                  params: moreParams,
                                  title: title,
                                  api: _api,
                                ),
                              ),
                            );
                          }
                        },
                        child: Text(
                          path.startsWith('play:') ||
                                  path.startsWith('mix:') ||
                                  path.startsWith('VLRD') ||
                                  path.startsWith('RD') ||
                                  path.startsWith('playlist:')
                              ? 'Play all'.i18n
                              : 'View all'.i18n,
                        ),
                      );
                    },
                  ),
              ],
            ),
          ),

        // 1. Songs List Carousel -> 4-row horizontal scrolling grid (Metrolist style!)
        if (isSongList)
          _build4RowSongsGrid(items)
        // 2. Podcast Episodes Carousel -> 2-row horizontal scrolling grid
        else if (isMultiRow)
          _build2RowEpisodesGrid(items)
        // 3. Moods & Genres Navigation Buttons
        else if (isNavButtons)
          _buildNavButtonsCarousel(items),
      ],
    );
  }

  Widget _build4RowSongsGrid(List items) {
    final parsedTracks = <Track>[];

    for (final item in items) {
      if (item['musicResponsiveListItemRenderer'] != null) {
        final t = YouTubeMusicParsers.parseTrackFromResponsiveListItem(
          item['musicResponsiveListItemRenderer'],
        );
        if (t != null) parsedTracks.add(t);
      } else if (item['musicTwoRowItemRenderer'] != null) {
        final t = YouTubeMusicParsers.parseTrackFromTwoRowItem(
          item['musicTwoRowItemRenderer'],
        );
        if (t != null) parsedTracks.add(t);
      }
    }

    if (parsedTracks.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final double screenWidth = constraints.maxWidth;

        int crossAxisCount;
        if (screenWidth > 1200) {
          crossAxisCount = 2; // Large screens: 2 rows
        } else {
          crossAxisCount = 4; // Normal screens: 4 rows for YTM
        }

        final double width;
        if (screenWidth > 1600) {
          width = (screenWidth - 24.0) / 5 - 1.0;
        } else if (screenWidth > 1200) {
          width = (screenWidth - 24.0) / 4 - 1.0;
        } else if (screenWidth > 900) {
          width = (screenWidth - 24.0) / 3 - 1.0;
        } else if (screenWidth > 600) {
          width = (screenWidth - 24.0) / 2 - 1.0;
        } else {
          width = math.max(300.0, screenWidth * 0.85);
        }

        const double itemHeight = 76.0;
        final double totalHeight = crossAxisCount * itemHeight;

        return YTMHorizontalScrollWrapper(
          builder: (context, scrollController) {
            return SizedBox(
              height: totalHeight,
              child: SilkyGridView.builder(
                silkyConfig: silkyHorizontalScrollConfig,
                controller: scrollController,
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12.0),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  mainAxisExtent: width,
                  mainAxisSpacing: 4.0,
                  crossAxisSpacing: 2.0,
                ),
                itemCount: parsedTracks.length,
                itemBuilder: (context, i) {
                  final track = parsedTracks[i];
                  return TrackTile(
                    track,
                    rank: track.trackNumber ?? (i + 1),
                    hideDuration: true,
                    hidePlatformBadge: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8.0),
                    onTap: () {
                      GetIt.I<AudioPlayerHandler>().playFromTrackList(
                        parsedTracks,
                        track.id ?? '',
                        QueueSource(
                          source: 'browse',
                          id: track.id ?? '',
                          text: track.title ?? '',
                        ),
                      );
                    },
                    onHold: () {
                      MenuSheet().defaultTrackMenu(track, context: context);
                    },
                  );
                },
              ),
            );
          },
        );
      },
    );
  }

  String? _episodeDescription(ShowEpisode? episode) {
    final description = episode?.description?.trim();
    if (description != null && description.isNotEmpty) {
      return description;
    }
    return episode?.show?.name;
  }

  double? _episodeProgressFraction(ShowEpisode? episode) {
    if (episode == null) {
      return null;
    }
    final progress = episode.progressPercentage;
    if (progress != null) {
      return progress.clamp(0.0, 1.0).toDouble();
    }
    final bookmark = episode.bookmarkSeconds;
    final duration = episode.duration;
    if (bookmark != null && duration != null && duration.inSeconds > 0) {
      return (bookmark / duration.inSeconds).clamp(0.0, 1.0).toDouble();
    }
    return null;
  }

  String? _episodeMetadataText(ShowEpisode? episode) {
    if (episode == null) {
      return null;
    }
    final parts = <String>[];
    final dateOrViews = episode.publishedDate?.trim();
    if (dateOrViews?.isNotEmpty == true) {
      parts.add(dateOrViews!);
    }
    final progress = _episodeProgressFraction(episode);
    final bookmark = episode.bookmarkSeconds;
    final duration = episode.duration;
    if (episode.isHeard == true) {
      parts.add('Played'.i18n);
    } else if (duration != null &&
        ((progress != null && progress > 0.02) ||
            (bookmark != null && bookmark > 0))) {
      final playedSeconds =
          bookmark ??
          (((progress ?? 0.0).clamp(0.0, 1.0) * duration.inSeconds).round());
      final remaining = duration.inSeconds - playedSeconds;
      if (remaining > 60) {
        parts.add('${remaining ~/ 60}m left');
      } else if (progress != null) {
        parts.add('${(progress * 100).round()}%');
      }
    }
    return parts.isEmpty ? null : parts.join(' • ');
  }

  Widget _build2RowEpisodesGrid(List items) {
    final episodes = <ShowEpisode>[];
    for (final item in items) {
      final multi = item['musicMultiRowListItemRenderer'];
      if (multi != null) {
        final ep = YouTubeMusicParsers.parseEpisodeFromMultiRowListItem(multi);
        if (ep != null) episodes.add(ep);
      } else if (item['musicResponsiveListItemRenderer'] != null &&
          _responsiveItemHasPodcastShow(
            item['musicResponsiveListItemRenderer'],
          )) {
        final ep = YouTubeMusicParsers.parseEpisodeFromResponsiveListItem(
          Map<String, dynamic>.from(item['musicResponsiveListItemRenderer']),
        );
        if (ep != null) episodes.add(ep);
      } else if (item['musicTwoRowItemRenderer'] != null) {
        final ep = YouTubeMusicParsers.parseEpisodeFromTwoRowItem(
          Map<String, dynamic>.from(item['musicTwoRowItemRenderer']),
        );
        if (ep != null) episodes.add(ep);
      }
    }

    if (episodes.isEmpty) return const SizedBox.shrink();

    return SizedBox(
      height: 160,
      child: YTMHorizontalScrollWrapper(
        builder: (context, scrollController) {
          return SilkyGridView.builder(
            silkyConfig: silkyHorizontalScrollConfig,
            controller: scrollController,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12.0),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisExtent: 330,
              mainAxisSpacing: 8.0,
              crossAxisSpacing: 6.0,
            ),
            itemCount: episodes.length,
            itemBuilder: (context, i) {
              final ep = episodes[i];
              final t = Track(
                id: ep.id,
                title: ep.title,
                artists: ep.show?.name != null
                    ? [Artist(name: ep.show!.name, platformId: 'youtube_music')]
                    : [],
                albumArt: ep.art ?? ep.show?.art,
                duration: ep.duration ?? Duration.zero,
                platformId: 'youtube_music',
              );
              return TrackTile(
                t,
                minimal: true,
                subtitleOverride: _episodeDescription(ep),
                secondarySubtitle: _episodeMetadataText(ep),
                imageProgress: _episodeProgressFraction(ep),
                imageProgressComplete: ep.isHeard == true,
                onTap: () {
                  GetIt.I<AudioPlayerHandler>().playShowEpisode(
                    ep.show ??
                        Show(name: 'Podcast', platformId: 'youtube_music'),
                    [ep],
                    index: 0,
                  );
                },
                onHold: () {
                  MenuSheet().defaultShowEpisodeMenu(
                    ep.show ??
                        Show(name: 'Podcast', platformId: 'youtube_music'),
                    ep,
                    context: context,
                  );
                },
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildNavButtonsCarousel(List items) {
    final showIcons = _navButtonsHaveDistinctIcons(items);
    return SizedBox(
      height: 110,
      child: YTMHorizontalScrollWrapper(
        builder: (context, scrollController) {
          return SilkyGridView.builder(
            silkyConfig: silkyHorizontalScrollConfig,
            controller: scrollController,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisExtent: 180,
              mainAxisSpacing: 8.0,
              crossAxisSpacing: 8.0,
            ),
            itemCount: items.length,
            itemBuilder: (context, i) {
              final btn = items[i]['musicNavigationButtonRenderer'];
              if (btn == null) return const SizedBox.shrink();
              final title = YouTubeMusicParsers.parseRuns(btn['buttonText']);
              final endpoint = btn['clickCommand']?['browseEndpoint'];
              final browseId = endpoint?['browseId'] as String?;
              final params = endpoint?['params'] as String?;

              final colorInt = btn['solid']?['leftStripeColor'] ?? btn['color'];
              Color? stripeColor;
              if (colorInt is int) {
                stripeColor = Color(colorInt);
              }
              final iconType =
                  btn['iconStyle']?['icon']?['iconType'] as String?;

              return YTMMoodGenreCard(
                title: title,
                stripeColor: stripeColor,
                iconType: iconType,
                showIcon: showIcons,
                onTap: () {
                  if (browseId != null) {
                    if (browseId.startsWith('VL') || browseId.startsWith('PL')) {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => PlaylistDetails(
                            Playlist(
                              id: browseId,
                              title: title,
                              platformId: 'youtube_music',
                            ),
                          ),
                        ),
                      );
                    } else {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => YouTubeMusicBrowseWidget(
                            browseId: browseId,
                            params: params,
                            title: title,
                            api: _api,
                          ),
                        ),
                      );
                    }
                  }
                },
              );
            },
          );
        },
      ),
    );
  }

  bool _navButtonsHaveDistinctIcons(List items) {
    String iconFamily(dynamic value) {
      final type =
          value?['musicNavigationButtonRenderer']?['iconStyle']?['icon']?['iconType'];
      return switch (type) {
        'MUSIC_NEW_RELEASE' => 'new-releases',
        'TRENDING_UP' => 'trending',
        'STICKER_EMOTICON' => 'mood',
        'BROADCAST' => 'podcast',
        _ => 'generic',
      };
    }

    return items
            .whereType<Map>()
            .where((item) => item['musicNavigationButtonRenderer'] != null)
            .map(iconFamily)
            .toSet()
            .length >
        1;
  }

  bool _responsiveItemHasPodcastShow(dynamic renderer) {
    if (renderer is! Map) return false;
    final columns = renderer['flexColumns'] as List? ?? [];
    for (final column in columns) {
      final runs =
          column?['musicResponsiveListItemFlexColumnRenderer']?['text']?['runs']
              as List? ??
          [];
      for (final run in runs) {
        final endpoint = run is Map ? run['navigationEndpoint'] : null;
        final browseEndpoint = endpoint is Map
            ? endpoint['browseEndpoint']
            : null;
        final browseId = browseEndpoint is Map
            ? browseEndpoint['browseId']
            : null;
        if (browseId is String && browseId.startsWith('MPSP')) return true;
      }
    }
    return false;
  }

  Widget _buildGridRenderer(Map<dynamic, dynamic> grid) {
    final title = YouTubeMusicParsers.parseRuns(
      grid['header']?['gridHeaderRenderer']?['title'],
    );
    final items = grid['items'] as List? ?? [];
    if (items.isEmpty) return const SizedBox.shrink();

    final isNav = items.any(
      (it) => it['musicNavigationButtonRenderer'] != null,
    );

    if (isNav) {
      final showIcons = _navButtonsHaveDistinctIcons(items);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16.0, 16.0, 16.0, 8.0),
              child: Text(
                title,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  letterSpacing: -0.3,
                ),
              ),
            ),
          LayoutBuilder(
            builder: (context, constraints) {
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12.0),
                child: SilkyGridView.builder(
                  silkyConfig: silkyScrollConfig,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: constraints.maxWidth > 1200
                        ? 4
                        : (constraints.maxWidth > 700 ? 3 : 2),
                    mainAxisSpacing: 8.0,
                    crossAxisSpacing: 8.0,
                    mainAxisExtent: 56.0,
                  ),
                  itemCount: items.length,
                  itemBuilder: (context, i) {
                    final it = items[i];
                    final btn = it['musicNavigationButtonRenderer'];
                    if (btn == null) return const SizedBox.shrink();
                    final btnTitle = YouTubeMusicParsers.parseRuns(
                      btn['buttonText'],
                    );
                    final endpoint = btn['clickCommand']?['browseEndpoint'];
                    final browseId = endpoint?['browseId'] as String?;
                    final params = endpoint?['params'] as String?;

                    final colorInt =
                        btn['solid']?['leftStripeColor'] ?? btn['color'];
                    Color? stripeColor;
                    if (colorInt is int) stripeColor = Color(colorInt);
                    final iconType =
                        btn['iconStyle']?['icon']?['iconType'] as String?;

                    return YTMMoodGenreCard(
                      title: btnTitle,
                      stripeColor: stripeColor,
                      iconType: iconType,
                      showIcon: showIcons,
                      onTap: () {
                        if (browseId != null) {
                          if (browseId.startsWith('VL') || browseId.startsWith('PL')) {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => PlaylistDetails(
                                  Playlist(
                                    id: browseId,
                                    title: btnTitle,
                                    platformId: 'youtube_music',
                                  ),
                                ),
                              ),
                            );
                          } else {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => YouTubeMusicBrowseWidget(
                                  browseId: browseId,
                                  params: params,
                                  title: btnTitle,
                                  api: _api,
                                ),
                              ),
                            );
                          }
                        }
                      },
                    );
                  },
                ),
              );
            },
          ),
        ],
      );
    }

    final parsed = YouTubeMusicParsers.parseBrowseSection({'gridRenderer': grid});
    if (parsed != null) {
      return HomePageGridSection(parsed);
    }
    return const SizedBox.shrink();
  }

  Widget _buildMusicShelf(Map<dynamic, dynamic> shelf) {
    final title = YouTubeMusicParsers.parseRuns(
      shelf['title'] ?? shelf['header']?['musicShelfHeaderRenderer']?['title'],
    );
    final items = shelf['contents'] as List? ?? [];
    if (items.isEmpty) return const SizedBox.shrink();

    final isPopularEpisodes =
        title.toLowerCase().contains('popular episode') ||
        title.toLowerCase().contains('episode') ||
        widget.browseId == 'FEmusic_non_music_audio';

    final tracks = <Track>[];
    final episodesById = <String, ShowEpisode>{};
    for (final item in items) {
      if (item['musicResponsiveListItemRenderer'] != null) {
        final renderer = item['musicResponsiveListItemRenderer'];
        final episode = isPopularEpisodes
            ? YouTubeMusicParsers.parseEpisodeFromResponsiveListItem(
                Map<String, dynamic>.from(renderer),
              )
            : null;
        final t = episode != null
            ? Track(
                id: episode.id,
                title: episode.title,
                artists: episode.show?.name == null
                    ? []
                    : [
                        Artist(
                          name: episode.show!.name,
                          platformId: 'youtube_music',
                        ),
                      ],
                albumArt: episode.art,
                duration: episode.duration,
                platformId: 'youtube_music',
              )
            : YouTubeMusicParsers.parseTrackFromResponsiveListItem(renderer);
        if (t != null) {
          tracks.add(t);
          if (episode != null && episode.id != null) {
            episodesById[episode.id!] = episode;
          }
        }
      }
    }

    if (tracks.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16.0, 18.0, 16.0, 8.0),
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
                letterSpacing: -0.3,
              ),
            ),
          ),
        ...tracks.asMap().entries.map((entry) {
          final i = entry.key;
          final track = entry.value;
          return TrackTile(
            track,
            rank: track.trackNumber ?? (i + 1),
            minimal: isPopularEpisodes,
            hideDuration: isPopularEpisodes,
            hidePlatformBadge: true,
            subtitleOverride: _episodeDescription(episodesById[track.id]),
            secondarySubtitle: _episodeMetadataText(episodesById[track.id]),
            imageProgress: _episodeProgressFraction(episodesById[track.id]),
            imageProgressComplete: episodesById[track.id]?.isHeard == true,
            onTap: () {
              final episode = track.id == null ? null : episodesById[track.id!];
              if (episode != null) {
                GetIt.I<AudioPlayerHandler>().playShowEpisode(
                  episode.show ??
                      Show(name: 'Podcast', platformId: 'youtube_music'),
                  [episode],
                  index: 0,
                );
                return;
              }
              GetIt.I<AudioPlayerHandler>().playFromTrackList(
                tracks,
                track.id ?? '',
                QueueSource(
                  source: 'browse',
                  id: track.id ?? '',
                  text: track.title ?? '',
                ),
              );
            },
            onHold: () {
              MenuSheet().defaultTrackMenu(track, context: context);
            },
          );
        }),
      ],
    );
  }
}

class YTMHorizontalScrollWrapper extends StatefulWidget {
  final Widget Function(BuildContext context, ScrollController controller)
  builder;
  const YTMHorizontalScrollWrapper({required this.builder, super.key});

  @override
  State<YTMHorizontalScrollWrapper> createState() =>
      _YTMHorizontalScrollWrapperState();
}

class _YTMHorizontalScrollWrapperState
    extends State<YTMHorizontalScrollWrapper> {
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      controller: _scrollController,
      child: widget.builder(context, _scrollController),
    );
  }
}

class YouTubeMusicArtistChart extends StatelessWidget {
  final String title;
  final List<Artist> artists;
  final ValueChanged<Artist> onArtistTap;

  const YouTubeMusicArtistChart({
    required this.title,
    required this.artists,
    required this.onArtistTap,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    if (artists.isEmpty) {
      return const SizedBox.shrink();
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final screenWidth = constraints.maxWidth;
        final crossAxisCount = screenWidth > 1200 ? 2 : 4;
        final double itemWidth = screenWidth > 1600
            ? (screenWidth - 24.0) / 5 - 1.0
            : screenWidth > 1200
            ? (screenWidth - 24.0) / 4 - 1.0
            : screenWidth > 900
            ? (screenWidth - 24.0) / 3 - 1.0
            : screenWidth > 600
            ? (screenWidth - 24.0) / 2 - 1.0
            : math.max(300.0, screenWidth * 0.85).toDouble();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
              child: Text(
                title,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            YTMHorizontalScrollWrapper(
              builder: (context, scrollController) => SizedBox(
                height: crossAxisCount * 76.0,
                child: SilkyGridView.builder(
                  silkyConfig: silkyHorizontalScrollConfig,
                  controller: scrollController,
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: crossAxisCount,
                    mainAxisExtent: itemWidth,
                    mainAxisSpacing: 4,
                    crossAxisSpacing: 2,
                  ),
                  itemCount: artists.length,
                  itemBuilder: (context, index) {
                    final artist = artists[index];
                    return ArtistHorizontalTile(
                      artist,
                      rank: index + 1,
                      onTap: () => onArtistTap(artist),
                    );
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
