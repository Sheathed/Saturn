import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:saturn/platform/platform_capabilities.dart';

import '../main.dart';
import '../settings.dart';
import '../translations.i18n.dart';
import '../ui/login_screen.dart';
import '../ui/music_link_navigation.dart';
import '../ui/player_bar.dart';
import '../ui/elements.dart';
import '../platform/platform_manager.dart';
import '../platform/music_platform.dart';
import '../platform/platform_registry.dart';
import '../api/cache.dart';
import '../api/definitions.dart';
import '../service/audio_service.dart';
import 'package:get_it/get_it.dart';
import 'package:silky_scroll/silky_scroll.dart';
import 'package:saturn/ui/smooth_scroll_config.dart';
import 'app_router.dart';
import '../utils/logging.dart';

class ShellRouteScaffold extends StatefulWidget {
  final Widget child;

  const ShellRouteScaffold({required this.child, super.key});

  @override
  State<ShellRouteScaffold> createState() => _ShellRouteScaffoldState();
}

class _ShellRouteScaffoldState extends State<ShellRouteScaffold> {
  static const double _minimumExpandedSidebarWidth = 150;
  static const double _maximumExpandedSidebarWidth = 440;
  int _selectedIndex = 0;
  final FocusScopeNode _navigationBarFocusNode = FocusScopeNode();
  final FocusNode _screenFocusNode = FocusNode();
  int _keyPressed = 0;
  bool _isRailExtended = false;
  bool _isHoveringSidebarResize = false;
  bool _isPageScrolledUnder = false;
  GoRouter? _observedRouter;
  String? _observedLocation;

  // Search bar state
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  List<String> _searchSuggestions = [];
  OverlayEntry? _suggestionsOverlay;
  final LayerLink _layerLink = LayerLink();
  final GlobalKey _searchBarKey = GlobalKey();
  bool _isClickingSuggestion = false;
  static const Key _playerBarKey = ValueKey('player_bar');

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final router = GoRouter.of(context);
    if (identical(router, _observedRouter)) return;
    _observedRouter?.routeInformationProvider.removeListener(
      _handleRouteChanged,
    );
    _observedRouter = router;
    _observedLocation = router.routeInformationProvider.value.uri.toString();
    router.routeInformationProvider.addListener(_handleRouteChanged);
  }

  void _handleRouteChanged() {
    final location = _observedRouter?.routeInformationProvider.value.uri
        .toString();
    if (location == null || location == _observedLocation) return;
    _observedLocation = location;
    _resetPageScrollUnder();
  }

  @override
  void didUpdateWidget(covariant ShellRouteScaffold oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.child.key != widget.child.key && _isPageScrolledUnder) {
      setState(() => _isPageScrolledUnder = false);
    }
  }

  void _resetPageScrollUnder() {
    if (_isPageScrolledUnder && mounted) {
      setState(() => _isPageScrolledUnder = false);
    }
  }

  bool _handlePageScrollNotification(ScrollNotification notification) {
    if (notification is! ScrollUpdateNotification) return false;
    final direction = notification.metrics.axisDirection;
    if (direction != AxisDirection.down && direction != AxisDirection.up) {
      return false;
    }
    final isScrolled = notification.metrics.extentBefore > 0;
    if (isScrolled != _isPageScrolledUnder && mounted) {
      setState(() => _isPageScrolledUnder = isScrolled);
    }
    return false;
  }

  List<_SidebarItem> get _sidebarItems => [
    _SidebarItem(
      icon: const Icon(Icons.home_outlined),
      selectedIcon: const Icon(Icons.home),
      label: 'Home'.i18n,
      route: AppRoutes.home,
      isVisible: (_) => true,
    ),
    _SidebarItem(
      icon: const Icon(Icons.explore_outlined),
      selectedIcon: const Icon(Icons.explore),
      label: 'Browse'.i18n,
      route: AppRoutes.browse,
      isVisible: (c) => c.supportsExplorePage,
    ),
    _SidebarItem(
      icon: const Icon(Icons.audiotrack_outlined),
      selectedIcon: const Icon(Icons.audiotrack),
      label: 'Tracks'.i18n,
      route: AppRoutes.libraryTracks,
      isVisible: (c) => c.supportsLibrarySync,
    ),
    _SidebarItem(
      icon: const Icon(Icons.album_outlined),
      selectedIcon: const Icon(Icons.album),
      label: 'Albums'.i18n,
      route: AppRoutes.libraryAlbums,
      isVisible: (c) => c.supportsAlbums,
    ),
    _SidebarItem(
      icon: const Icon(Icons.recent_actors_outlined),
      selectedIcon: const Icon(Icons.recent_actors),
      label: 'Artists'.i18n,
      route: AppRoutes.libraryArtists,
      isVisible: (c) => c.supportsArtists,
    ),
    _SidebarItem(
      icon: const Icon(Icons.playlist_play_outlined),
      selectedIcon: const Icon(Icons.playlist_play),
      label: 'Playlists'.i18n,
      route: AppRoutes.libraryPlaylists,
      isVisible: (_) => true,
    ),
    _SidebarItem(
      icon: const Icon(Icons.podcasts_outlined),
      selectedIcon: const Icon(Icons.podcasts),
      label: 'Podcasts'.i18n,
      route: AppRoutes.libraryPodcasts,
      isVisible: (c) => c.supportsShows,
    ),
    _SidebarItem(
      icon: const Icon(Icons.history_outlined),
      selectedIcon: const Icon(Icons.history),
      label: 'History'.i18n,
      route: AppRoutes.libraryHistory,
      isVisible: (_) => true,
    ),
    _SidebarItem(
      icon: const Icon(Icons.download_outlined),
      selectedIcon: const Icon(Icons.download),
      label: 'Downloads'.i18n,
      route: AppRoutes.downloads,
      isVisible: (_) => true,
    ),
    _SidebarItem(
      icon: const Icon(Icons.settings_outlined),
      selectedIcon: const Icon(Icons.settings),
      label: 'Settings'.i18n,
      route: AppRoutes.settings,
      isVisible: (_) => true,
    ),
  ];

  List<_SidebarItem> get _visibleItems {
    if (!PlatformManager.instance.isInitialized) return [];
    final capabilities = PlatformManager.instance.active.capabilities;
    return _sidebarItems.where((item) => item.isVisible(capabilities)).toList();
  }

  Future<List<MusicPlatform>>? _loggedInPlatformsFuture;

  @override
  void initState() {
    super.initState();
    _screenFocusNode.requestFocus();
    _loggedInPlatformsFuture = PlatformRegistry.instance.loggedInPlatforms;
    PlatformManager.instance.addListener(_onPlatformChanged);

    // Listen to search focus changes
    _searchFocusNode.addListener(() {
      if (!_searchFocusNode.hasFocus && !_isClickingSuggestion) {
        _hideSuggestions();
      } else if (_searchFocusNode.hasFocus && _searchController.text.isEmpty) {
        if ((cache.searchHistory?.length ?? 0) > 0) {
          _showSuggestionsOverlay();
        }
      }
    });
  }

  @override
  void dispose() {
    _hideSuggestions();
    _observedRouter?.routeInformationProvider.removeListener(
      _handleRouteChanged,
    );
    _navigationBarFocusNode.dispose();
    _screenFocusNode.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    PlatformManager.instance.removeListener(_onPlatformChanged);
    super.dispose();
  }

  void _onPlatformChanged() async {
    _loggedInPlatformsFuture = PlatformRegistry.instance.loggedInPlatforms;
    if (mounted) setState(() {});
    if (PlatformManager.instance.active.capabilities.supportsLibrarySync) {
      cache.activeLibraryTracks =
          (await PlatformManager.instance.active.getFavoriteTrackIds()) ?? [];
      cache.activeLibraryPlaylists =
          (await PlatformManager.instance.active.getFavoritePlaylistIds()) ??
          [];
      await cache.save();
    }
  }

  void _onDestinationSelected(int index, {bool navbar = false}) {
    if (navbar) {
      int targetRouteIndex = switch (index) {
        0 => 0, // Home
        1 => 9, // Search
        2 => 10, // Library
        _ => index,
      };

      switch (targetRouteIndex) {
        case 0:
          context.go(AppRoutes.home);
          break;
        case 9:
          context.go(AppRoutes.search);
          break;
        case 10:
          context.go(AppRoutes.library);
          break;
      }
    } else {
      final items = _visibleItems;
      if (index >= 0 && index < items.length) {
        setState(() => _selectedIndex = index);
        context.go(items[index].route);
      }
    }

    // Fix statusbar
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(statusBarColor: Colors.transparent),
    );
  }

  // Update selected index based on current location
  void _updateSelectedIndex(BuildContext context) {
    final location = GoRouterState.of(context).uri.path;
    final items = _visibleItems;

    int newIndex = items.indexWhere((item) => location.startsWith(item.route));
    if (newIndex == -1) {
      if (location.startsWith(AppRoutes.search)) {
        newIndex = 9;
      } else if (location.startsWith(AppRoutes.library)) {
        newIndex = 10;
      }
    }

    if (newIndex != -1 && _selectedIndex != newIndex) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _selectedIndex = newIndex);
      });
    }
  }

  void _handleKey(KeyEvent event) {
    FocusNode? primaryFocus = FocusManager.instance.primaryFocus;

    // Movement to navigation bar and back
    if (event is KeyDownEvent) {
      final logicalKey = event.logicalKey;
      final keyCode = logicalKey.keyId;

      if (logicalKey == LogicalKeyboardKey.tvContentsMenu) {
        // Menu key on Android TV
        _focusToNavbar();
      } else if (keyCode == 0x100070000127) {
        // EPG key on Hisense TV
        _focusToNavbar();
      } else if (logicalKey == LogicalKeyboardKey.arrowLeft ||
          logicalKey == LogicalKeyboardKey.arrowRight) {
        if ((_keyPressed == LogicalKeyboardKey.arrowLeft.keyId &&
                logicalKey == LogicalKeyboardKey.arrowRight) ||
            (_keyPressed == LogicalKeyboardKey.arrowRight.keyId &&
                logicalKey == LogicalKeyboardKey.arrowLeft)) {
          // LEFT + RIGHT
          _focusToNavbar();
        }
        _keyPressed = logicalKey.keyId;
        Future.delayed(const Duration(milliseconds: 100), () {
          _keyPressed = 0;
        });
      } else if (logicalKey == LogicalKeyboardKey.arrowDown) {
        // If it's bottom row, go to navigation bar
        var row = primaryFocus?.parent;
        if (row != null) {
          var column = row.parent;
          if (column?.children.last == row) {
            _focusToNavbar();
          }
        }
      } else if (logicalKey == LogicalKeyboardKey.arrowUp) {
        if (_navigationBarFocusNode.hasFocus) {
          _screenFocusNode.parent?.parent?.children.last.nextFocus();
        }
      }
    }
  }

  void _focusToNavbar() {
    _navigationBarFocusNode.requestFocus();
    _navigationBarFocusNode.focusInDirection(TraversalDirection.down);
  }

  @override
  Widget build(BuildContext context) {
    _updateSelectedIndex(context);

    // Check if user is logged in via any connected platform
    return FutureBuilder<List<MusicPlatform>>(
      future: _loggedInPlatformsFuture ??=
          PlatformRegistry.instance.loggedInPlatforms,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final loggedInList = snapshot.data!;
        if (loggedInList.isEmpty) {
          return PlatformLoginScreen(
            callback: () {
              // After login, navigate to home
              if (context.mounted) {
                context.go(AppRoutes.home);
              }
            },
          );
        }

        // Ensure active platform is one of the logged in platforms
        if (!loggedInList.any(
          (p) => p.platformId == PlatformManager.instance.activePlatformId,
        )) {
          PlatformManager.instance.switchPlatform(
            loggedInList.first.platformId,
          );
        }

        return AppInitializer(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final useNavigationRail = constraints.maxWidth >= 600;

              return PopScope(
                canPop: false,
                onPopInvokedWithResult: (bool didPop, Object? result) async {
                  // Check if we can pop the current route
                  if (context.canPop()) {
                    context.pop();
                    return;
                  }

                  return;
                },
                child: KeyboardListener(
                  focusNode: FocusNode(),
                  onKeyEvent: _handleKey,
                  child: useNavigationRail
                      ? _buildNavigationRailLayout(context)
                      : _buildNavigationBarLayout(context),
                ),
              );
            },
          ),
        );
      },
    );
  }

  void _submitSearch(String query) {
    final value = query.trim();
    if (value.isEmpty) return;

    _hideSuggestions();

    if (RegExp(r'^https?://', caseSensitive: false).hasMatch(value)) {
      _searchFocusNode.unfocus();
      openScreenByURL(value).catchError((Object error, StackTrace stackTrace) {
        appLogger.warning(
          'Could not open pasted music link',
          error,
          stackTrace,
        );
      });
      return;
    }

    // Navigate to search results
    context.push('/search/results?q=${Uri.encodeComponent(value)}');

    // Unfocus
    _searchFocusNode.unfocus();
  }

  Future<void> _loadSearchSuggestions(String query) async {
    if (query.isEmpty) {
      if ((cache.searchHistory?.length ?? 0) > 0) {
        _showSuggestionsOverlay();
      } else {
        _hideSuggestions();
      }
      return;
    }

    if (query.length < 2 || query.startsWith('http')) {
      setState(() {
        _searchSuggestions = [];
      });
      _hideSuggestions();
      return;
    }

    String currentQuery = query;
    await Future.delayed(const Duration(milliseconds: 300));

    // Check if query changed during delay
    if (currentQuery != _searchController.text) return;

    try {
      List<String> suggestions = await PlatformManager.instance.active
          .searchSuggestions(query);
      if (currentQuery == _searchController.text && mounted) {
        setState(() {
          _searchSuggestions = suggestions;
        });
        if (suggestions.isNotEmpty) {
          _showSuggestionsOverlay();
        } else {
          _hideSuggestions();
        }
      }
    } catch (e) {
      if (kDebugMode) {
        appLogger.warning('Error loading suggestions', e);
      }
    }
  }

  void _showSuggestionsOverlay() {
    _hideSuggestions();

    _suggestionsOverlay = OverlayEntry(
      builder: (overlayContext) => CompositedTransformFollower(
        link: _layerLink,
        showWhenUnlinked: false,
        offset: const Offset(0, 56),
        child: LayoutBuilder(
          builder: (layoutContext, constraints) {
            // Get the actual width from the search bar's RenderBox dynamically
            final RenderBox? renderBox =
                _searchBarKey.currentContext?.findRenderObject() as RenderBox?;
            final width = renderBox?.size.width ?? 400;

            return Align(
              alignment: Alignment.topLeft,
              child: TapRegion(
                onTapInside: (_) {
                  // Keep the flag set while interacting with suggestions
                  _isClickingSuggestion = true;
                },
                onTapOutside: (_) {
                  // Reset flag when clicking outside
                  _isClickingSuggestion = false;
                  _hideSuggestions();
                },
                child: Material(
                  elevation: 8.0,
                  color: Theme.of(context).scaffoldBackgroundColor,
                  shape: RoundedRectangleBorder(
                    borderRadius: const BorderRadius.only(
                      bottomRight: Radius.circular(8.0),
                      bottomLeft: Radius.circular(8.0),
                    ),
                    side: BorderSide(
                      color: Theme.of(context).dividerColor,
                      width: 1.0,
                    ),
                  ),
                  child: Container(
                    width: width,
                    constraints: const BoxConstraints(maxHeight: 300),
                    child: Builder(
                      builder: (context) {
                        if (_searchController.text.isEmpty &&
                            (cache.searchHistory?.isNotEmpty ?? false)) {
                          final history = cache.searchHistory!;
                          final count = history.length > 10
                              ? 10
                              : history.length;
                          return SilkyListView.builder(
                            silkyConfig: silkyScrollConfig,
                            padding: EdgeInsets.zero,
                            shrinkWrap: true,
                            itemCount: count,
                            itemBuilder: (listContext, index) {
                              final actualIndex = history.length - 1 - index;
                              dynamic data = history[actualIndex].data;

                              IconData icon;
                              String title;
                              String? subtitle;

                              switch (history[actualIndex].type) {
                                case SearchHistoryItemType.TRACK:
                                  icon = Icons.audiotrack;
                                  title = data.title ?? 'Unknown';
                                  subtitle = data.artistString;
                                  break;
                                case SearchHistoryItemType.ALBUM:
                                  icon = Icons.album;
                                  title = data.title ?? 'Unknown';
                                  subtitle = data.artistString;
                                  break;
                                case SearchHistoryItemType.ARTIST:
                                  icon = Icons.person;
                                  title = data.name ?? 'Unknown';
                                  subtitle = 'Artist';
                                  break;
                                case SearchHistoryItemType.PLAYLIST:
                                  icon = Icons.playlist_play;
                                  title = data.title ?? 'Unknown';
                                  subtitle = 'Playlist';
                                  break;
                                case SearchHistoryItemType.RADIO:
                                  icon = Icons.radio;
                                  title = data.title ?? 'Unknown';
                                  subtitle = 'Live Radio';
                                  break;
                              }

                              return ListTile(
                                dense: true,
                                leading: Icon(
                                  icon,
                                  size: 20,
                                  color: Theme.of(context).hintColor,
                                ),
                                title: Text(
                                  title,
                                  style: const TextStyle(fontSize: 14),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: subtitle != null
                                    ? Text(
                                        subtitle,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Theme.of(context).hintColor,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      )
                                    : null,
                                trailing: IconButton(
                                  icon: Icon(
                                    Icons.close,
                                    size: 16,
                                    color: Theme.of(context).hintColor,
                                  ),
                                  onPressed: () {
                                    cache.searchHistory?.removeAt(actualIndex);
                                    cache.save();
                                    // Trigger a rebuild of the overlay by recreating it
                                    _showSuggestionsOverlay();
                                  },
                                ),
                                onTap: () {
                                  switch (history[actualIndex].type) {
                                    case SearchHistoryItemType.TRACK:
                                      List<Track> queue = history
                                          .where(
                                            (h) =>
                                                h.type ==
                                                SearchHistoryItemType.TRACK,
                                          )
                                          .map<Track>((t) => t.data)
                                          .toList();
                                      GetIt.I<AudioPlayerHandler>()
                                          .playFromTrackList(
                                            queue,
                                            data.id,
                                            QueueSource(
                                              text: 'Search history'.i18n,
                                              source: 'searchhistory',
                                              id: 'searchhistory',
                                            ),
                                          );
                                      break;
                                    case SearchHistoryItemType.ALBUM:
                                      context.push(
                                        '/album/${data.id}',
                                        extra: data,
                                      );
                                      break;
                                    case SearchHistoryItemType.ARTIST:
                                      context.push(
                                        '/artist/${data.id}',
                                        extra: data,
                                      );
                                      break;
                                    case SearchHistoryItemType.PLAYLIST:
                                      context.push(
                                        '/playlist/${data.id}',
                                        extra: data,
                                      );
                                      break;
                                    case SearchHistoryItemType.RADIO:
                                      GetIt.I<AudioPlayerHandler>().playRadio(
                                        id: data.id!,
                                        title: data.title ?? '',
                                        description: data.description,
                                        artUrl:
                                            data.image?.full ??
                                            data.image?.thumb,
                                      );
                                      break;
                                  }
                                  _hideSuggestions();
                                  _searchFocusNode.unfocus();
                                  _isClickingSuggestion = false;
                                },
                              );
                            },
                          );
                        } else {
                          return SilkyListView.builder(
                            silkyConfig: silkyScrollConfig,
                            padding: EdgeInsets.zero,
                            shrinkWrap: true,
                            itemCount: _searchSuggestions.length,
                            itemBuilder: (listContext, index) {
                              final suggestion = _searchSuggestions[index];
                              return ListTile(
                                dense: true,
                                leading: const Icon(Icons.search, size: 20),
                                title: Text(
                                  suggestion,
                                  style: const TextStyle(fontSize: 14),
                                ),
                                onTap: () {
                                  // Use the main context, not overlay context
                                  _searchController.text = suggestion;
                                  context.push(
                                    '/search/results?q=${Uri.encodeComponent(suggestion)}',
                                  );
                                  _hideSuggestions();
                                  _searchFocusNode.unfocus();
                                  _isClickingSuggestion = false;
                                },
                              );
                            },
                          );
                        }
                      },
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );

    Overlay.of(context).insert(_suggestionsOverlay!);
  }

  void _hideSuggestions() {
    _suggestionsOverlay?.remove();
    _suggestionsOverlay = null;
  }

  Widget _buildSearchBar(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor, width: 1.0),
        ),
      ),
      child: Row(
        children: [
          _buildPlatformSwitcher(),
          const SizedBox(width: 16.0),
          Expanded(
            child: CompositedTransformTarget(
              link: _layerLink,
              child: SizedBox(
                key: _searchBarKey,
                height: 48.0,
                child: TextField(
                  controller: _searchController,
                  focusNode: _searchFocusNode,
                  cursorColor: Theme.of(context).primaryColor,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: 'Search or paste URL'.i18n,
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              setState(() {
                                _searchController.clear();
                                _searchSuggestions = [];
                              });
                              _hideSuggestions();
                            },
                          )
                        : null,
                    filled: false,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16.0,
                      vertical: 12.0,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24.0),
                      borderSide: BorderSide.none,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24.0),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24.0),
                      borderSide: BorderSide(
                        color: Colors.transparent,
                        width: 2.0,
                      ),
                    ),
                  ),
                  onChanged: (value) {
                    setState(() {}); // Update to show/hide clear button
                    _loadSearchSuggestions(value);
                  },
                  onSubmitted: _submitSearch,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlatformSwitcher() {
    return FutureBuilder<List<MusicPlatform>>(
      future: _loggedInPlatformsFuture ??=
          PlatformRegistry.instance.loggedInPlatforms,
      builder: (context, snapshot) {
        final platforms = List<MusicPlatform>.from(snapshot.data ?? []);
        if (platforms.length <= 1) return const SizedBox.shrink();

        // Ensure current active is in the list, otherwise add it so Dropdown doesn't crash
        final activeId = PlatformManager.instance.activePlatformId;
        final hasActive = platforms.any((p) => p.platformId == activeId);
        if (!hasActive && PlatformManager.instance.isInitialized) {
          platforms.add(PlatformManager.instance.active);
        }

        return Container(
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(24.0),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: activeId,
              icon: const Icon(Icons.arrow_drop_down, size: 20),
              isDense: true,
              items: [
                ...platforms.map((platform) {
                  return DropdownMenuItem<String>(
                    value: platform.platformId,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        platform.buildPlatformIcon(size: 16),
                        const SizedBox(width: 8),
                        Text(
                          platform.platformName,
                          style: const TextStyle(fontSize: 14),
                        ),
                      ],
                    ),
                  );
                }),
                const DropdownMenuItem<String>(
                  value: 'manage_accounts',
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.add_circle_outline, size: 16),
                      SizedBox(width: 8),
                      Text('Add Account...', style: TextStyle(fontSize: 14)),
                    ],
                  ),
                ),
              ],
              onChanged: (String? newId) async {
                if (newId == 'manage_accounts') {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) =>
                          const PlatformLoginScreen(callback: null),
                    ),
                  );
                  return;
                }
                if (newId != null && newId != activeId) {
                  await selectPlatform(newId);
                }
              },
            ),
          ),
        );
      },
    );
  }

  Widget _buildNavigationRailLayout(BuildContext context) {
    final isDesktop =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux);
    final isExtended = settings.keepSidebarOpen == true
        ? true
        : settings.keepSidebarClosed == true
        ? false
        : _isRailExtended;

    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                MouseRegion(
                  onEnter: (_) => setState(() => _isRailExtended = true),
                  onExit: (_) => setState(() => _isRailExtended = false),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FocusScope(
                        node: _navigationBarFocusNode,
                        child: NavigationRail(
                          extended: isExtended,
                          minExtendedWidth: isDesktop
                              ? settings.sidebarExpandedWidth
                                    .clamp(
                                      _minimumExpandedSidebarWidth,
                                      _maximumExpandedSidebarWidth,
                                    )
                                    .toDouble()
                              : null,
                          selectedIndex:
                              (_selectedIndex >= 0 &&
                                  _selectedIndex < _visibleItems.length)
                              ? _selectedIndex
                              : null,
                          onDestinationSelected: _onDestinationSelected,
                          destinations: _visibleItems
                              .map(
                                (item) => NavigationRailDestination(
                                  icon: item.icon,
                                  selectedIcon: item.selectedIcon,
                                  label: Text(item.label),
                                ),
                              )
                              .toList(),
                        ),
                      ),
                      if (isDesktop && isExtended)
                        MouseRegion(
                          cursor: SystemMouseCursors.resizeLeftRight,
                          onEnter: (_) =>
                              setState(() => _isHoveringSidebarResize = true),
                          onExit: (_) =>
                              setState(() => _isHoveringSidebarResize = false),
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onHorizontalDragUpdate: (details) {
                              setState(() {
                                settings.sidebarExpandedWidth =
                                    (settings.sidebarExpandedWidth +
                                            details.delta.dx)
                                        .clamp(
                                          _minimumExpandedSidebarWidth,
                                          _maximumExpandedSidebarWidth,
                                        )
                                        .toDouble();
                              });
                            },
                            onHorizontalDragEnd: (_) async {
                              await settings.save();
                            },
                            child: SizedBox(
                              width: 8,
                              height: double.infinity,
                              child: Center(
                                child: Container(
                                  width: 2,
                                  color: _isHoveringSidebarResize
                                      ? Theme.of(context).colorScheme.primary
                                      : Colors.transparent,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const VerticalDivider(thickness: 1, width: 1),
                Expanded(
                  child: Column(
                    children: [
                      // Search bar at the top of content area
                      _buildSearchBar(context),
                      Expanded(
                        child: Focus(
                          focusNode: _screenFocusNode,
                          skipTraversal: true,
                          canRequestFocus: false,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              Positioned(
                                top: 0,
                                left: 0,
                                right: 0,
                                height: kToolbarHeight,
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 180),
                                  curve: Curves.linear,
                                  color: _isPageScrolledUnder
                                      ? Theme.of(context)
                                            .colorScheme
                                            .surfaceContainerLow
                                      : Theme.of(context)
                                            .scaffoldBackgroundColor,
                                ),
                              ),
                              LayoutBuilder(
                                builder: (context, constraints) {
                                  final screenWidth = MediaQuery.sizeOf(
                                    context,
                                  ).width;
                                  double? maxWidth;
                                  if (screenWidth >= 1904) {
                                    maxWidth = 1785;
                                  } else if (screenWidth >= 1264) {
                                    maxWidth = 1185;
                                  } else if (screenWidth >= 960) {
                                    maxWidth = 900;
                                  }

                                  if (maxWidth != null) {
                                    final constrainedWidth = math.min(
                                      maxWidth,
                                      constraints.maxWidth,
                                    );
                                    return Align(
                                      alignment: Alignment.topCenter,
                                      child: SizedBox(
                                        width: constrainedWidth,
                                        height: constraints.maxHeight,
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 12.0,
                                          ),
                                          child: ScrollUnderScope(
                                            scrolledUnder: _isPageScrolledUnder,
                                            onReset: _resetPageScrollUnder,
                                            child:
                                                NotificationListener<
                                                  ScrollNotification
                                                >(
                                                  onNotification:
                                                      _handlePageScrollNotification,
                                                  child: widget.child,
                                                ),
                                          ),
                                        ),
                                      ),
                                    );
                                  }
                                  return Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12.0,
                                    ),
                                    child: ScrollUnderScope(
                                      scrolledUnder: _isPageScrolledUnder,
                                      onReset: _resetPageScrollUnder,
                                      child:
                                          NotificationListener<
                                            ScrollNotification
                                          >(
                                            onNotification:
                                                _handlePageScrollNotification,
                                            child: widget.child,
                                          ),
                                    ),
                                  );
                                },
                              ),
                              Positioned.fill(
                                child: ValueListenableBuilder<bool>(
                                  valueListenable: bodyOverlayActive,
                                  builder: (context, isActive, _) =>
                                      IgnorePointer(
                                        ignoring: !isActive,
                                        child: Navigator(
                                          key: bodyOverlayNavigatorKey,
                                          onGenerateRoute: (_) =>
                                              PageRouteBuilder<void>(
                                                opaque: false,
                                                barrierColor:
                                                    Colors.transparent,
                                                pageBuilder: (_, _, _) =>
                                                    const SizedBox.shrink(),
                                              ),
                                        ),
                                      ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const PlayerBar(key: _playerBarKey),
        ],
      ),
    );
  }

  Widget _buildNavigationBarLayout(BuildContext context) {
    // Map selected index to navigation bar index
    // NavigationBar only has 3 items: Home (0), Browse/Search (1), Library (2+)
    int navBarIndex = 0;
    if (_selectedIndex == 9) {
      navBarIndex = 1;
    } else if (_selectedIndex == 0) {
      navBarIndex = 0;
    } else if (_selectedIndex == 1) {
      navBarIndex = 1; // Map browse to search/explore tab
    } else {
      navBarIndex = 2; // All library and other routes map to index 2
    }

    return Scaffold(
      bottomNavigationBar: FocusScope(
        node: _navigationBarFocusNode,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const PlayerBar(key: _playerBarKey),
            NavigationBar(
              height: 65,
              backgroundColor: Theme.of(context).bottomAppBarTheme.color,
              selectedIndex: navBarIndex,
              onDestinationSelected: (int index) {
                _onDestinationSelected(index, navbar: true);
              },
              indicatorColor: Theme.of(context).primaryColor,
              destinations: <Widget>[
                NavigationDestination(
                  icon: const Icon(Icons.home),
                  label: 'Home'.i18n,
                ),
                NavigationDestination(
                  icon: const Icon(Icons.search),
                  label: 'Search'.i18n,
                ),
                NavigationDestination(
                  icon: const Icon(Icons.library_music),
                  label: 'Library'.i18n,
                ),
              ],
            ),
          ],
        ),
      ),
      body: Focus(
        focusNode: _screenFocusNode,
        skipTraversal: true,
        canRequestFocus: false,
        child: widget.child,
      ),
    );
  }
}

class _SidebarItem {
  final Widget icon;
  final Widget selectedIcon;
  final String label;
  final String route;
  final bool Function(PlatformCapabilities) isVisible;

  _SidebarItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.route,
    required this.isVisible,
  });
}
