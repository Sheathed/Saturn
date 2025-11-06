import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../api/deezer.dart';
import '../main.dart';
import '../settings.dart';
import '../translations.i18n.dart';
import '../ui/login_screen.dart';
import '../ui/player_bar.dart';
import 'app_router.dart';

class ShellRouteScaffold extends StatefulWidget {
  final Widget child;

  const ShellRouteScaffold({required this.child, super.key});

  @override
  State<ShellRouteScaffold> createState() => _ShellRouteScaffoldState();
}

class _ShellRouteScaffoldState extends State<ShellRouteScaffold> {
  int _selectedIndex = 0;
  final FocusScopeNode _navigationBarFocusNode = FocusScopeNode();
  final FocusNode _screenFocusNode = FocusNode();
  int _keyPressed = 0;
  bool _isRailExtended = false;

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
  void initState() {
    super.initState();
    _screenFocusNode.requestFocus();

    // Listen to search focus changes
    _searchFocusNode.addListener(() {
      if (!_searchFocusNode.hasFocus && !_isClickingSuggestion) {
        _hideSuggestions();
      }
    });
  }

  @override
  void dispose() {
    _hideSuggestions();
    _navigationBarFocusNode.dispose();
    _screenFocusNode.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _onDestinationSelected(int index, {bool navbar = false}) {
    int finalIndex = index;

    if (navbar) {
      finalIndex = switch (index) {
        0 => 0, // Home
        1 => 9, // Search
        2 => 10, // Library (Tracks)
        _ => index,
      };
    }

    setState(() {
      _selectedIndex = index;
    });

    // Navigate to the selected destination
    switch (finalIndex) {
      case 0:
        context.go(AppRoutes.home);
        break;
      case 1:
        context.go(AppRoutes.browse);
        break;
      case 2:
        context.go(AppRoutes.libraryTracks);
        break;
      case 3:
        context.go(AppRoutes.libraryAlbums);
        break;
      case 4:
        context.go(AppRoutes.libraryArtists);
        break;
      case 5:
        context.go(AppRoutes.libraryPlaylists);
        break;
      case 6:
        context.go(AppRoutes.libraryPodcasts);
        break;
      case 7:
        context.go(AppRoutes.downloads);
        break;
      case 8:
        context.go(AppRoutes.settings);
        break;
      case 9:
        context.go(AppRoutes.search);
        break;
      case 10:
        context.go(AppRoutes.library);
        break;
    }

    // Fix statusbar
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(statusBarColor: Colors.transparent),
    );
  }

  // Update selected index based on current location
  void _updateSelectedIndex(BuildContext context) {
    final location = GoRouterState.of(context).uri.path;

    // Update selected index based on current route
    if (location.startsWith(AppRoutes.home)) {
      if (_selectedIndex != 0) {
        setState(() => _selectedIndex = 0);
      }
    } else if (location.startsWith(AppRoutes.browse)) {
      if (_selectedIndex != 1) {
        setState(() => _selectedIndex = 1);
      }
    } else if (location.startsWith(AppRoutes.libraryTracks)) {
      if (_selectedIndex != 2) {
        setState(() => _selectedIndex = 2);
      }
    } else if (location.startsWith(AppRoutes.libraryAlbums)) {
      if (_selectedIndex != 3) {
        setState(() => _selectedIndex = 3);
      }
    } else if (location.startsWith(AppRoutes.libraryArtists)) {
      if (_selectedIndex != 4) {
        setState(() => _selectedIndex = 4);
      }
    } else if (location.startsWith(AppRoutes.libraryPlaylists)) {
      if (_selectedIndex != 5) {
        setState(() => _selectedIndex = 5);
      }
    } else if (location.startsWith(AppRoutes.libraryPodcasts)) {
      if (_selectedIndex != 6) {
        setState(() => _selectedIndex = 6);
      }
    } else if (location.startsWith(AppRoutes.downloads)) {
      if (_selectedIndex != 7) {
        setState(() => _selectedIndex = 7);
      }
    } else if (location.startsWith(AppRoutes.settings)) {
      if (_selectedIndex != 8) {
        setState(() => _selectedIndex = 8);
      }
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

    // Check if user is logged in
    if (settings.arl == null) {
      return LoginWidget(
        callback: () {
          // After login, navigate to home
          if (context.mounted) {
            context.go(AppRoutes.home);
          }
        },
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
  }

  void _submitSearch(String query) {
    if (query.isEmpty) return;

    _hideSuggestions();

    // Navigate to search results
    context.push('/search/results?q=${Uri.encodeComponent(query)}');

    // Unfocus
    _searchFocusNode.unfocus();
  }

  Future<void> _loadSearchSuggestions(String query) async {
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
      List suggestions = await deezerAPI.searchSuggestions(query);
      if (currentQuery == _searchController.text && mounted) {
        setState(() {
          _searchSuggestions = suggestions.cast<String>();
        });
        if (suggestions.isNotEmpty) {
          _showSuggestionsOverlay();
        } else {
          _hideSuggestions();
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('Error loading suggestions: $e');
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
                  borderRadius: BorderRadius.only(
                    bottomRight: const Radius.circular(8.0),
                    bottomLeft: const Radius.circular(8.0),
                  ),
                  child: Container(
                    width: width,
                    constraints: const BoxConstraints(maxHeight: 300),
                    decoration: BoxDecoration(
                      color: Theme.of(context).scaffoldBackgroundColor,
                      borderRadius: BorderRadius.only(
                        bottomRight: const Radius.circular(8.0),
                        bottomLeft: const Radius.circular(8.0),
                      ),
                      border: Border.all(
                        color: Theme.of(context).dividerColor,
                        width: 1.0,
                      ),
                    ),
                    child: ListView.builder(
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

                            // Navigate using the widget's context
                            context.push(
                              '/search/results?q=${Uri.encodeComponent(suggestion)}',
                            );

                            // Hide and cleanup
                            _hideSuggestions();
                            _searchFocusNode.unfocus();
                            _isClickingSuggestion = false;
                          },
                        );
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

  Widget _buildNavigationRailLayout(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                MouseRegion(
                  onEnter: (_) => setState(() => _isRailExtended = true),
                  onExit: (_) => setState(() => _isRailExtended = false),
                  child: FocusScope(
                    node: _navigationBarFocusNode,
                    child: NavigationRail(
                      extended: (settings.keepSidebarOpen == true)
                          ? true
                          : (settings.keepSidebarClosed == true)
                          ? false
                          : _isRailExtended,
                      selectedIndex: _selectedIndex,
                      onDestinationSelected: _onDestinationSelected,
                      destinations: [
                        // Main navigation
                        NavigationRailDestination(
                          icon: const Icon(Icons.home_outlined),
                          selectedIcon: const Icon(Icons.home),
                          label: Text('Home'.i18n),
                        ),
                        NavigationRailDestination(
                          icon: const Icon(Icons.explore_outlined),
                          selectedIcon: const Icon(Icons.explore),
                          label: Text('Browse'.i18n),
                        ),
                        // Library section
                        NavigationRailDestination(
                          icon: const Icon(Icons.audiotrack_outlined),
                          selectedIcon: const Icon(Icons.audiotrack),
                          label: Text('Tracks'.i18n),
                        ),
                        NavigationRailDestination(
                          icon: const Icon(Icons.album_outlined),
                          selectedIcon: const Icon(Icons.album),
                          label: Text('Albums'.i18n),
                        ),
                        NavigationRailDestination(
                          icon: const Icon(Icons.recent_actors_outlined),
                          selectedIcon: const Icon(Icons.recent_actors),
                          label: Text('Artists'.i18n),
                        ),
                        NavigationRailDestination(
                          icon: const Icon(Icons.playlist_play_outlined),
                          selectedIcon: const Icon(Icons.playlist_play),
                          label: Text('Playlists'.i18n),
                        ),
                        NavigationRailDestination(
                          icon: const Icon(Icons.podcasts_outlined),
                          selectedIcon: const Icon(Icons.podcasts),
                          label: Text('Podcasts'.i18n),
                        ),
                        // Other
                        NavigationRailDestination(
                          icon: const Icon(Icons.download_outlined),
                          selectedIcon: const Icon(Icons.download),
                          label: Text('Downloads'.i18n),
                        ),
                        NavigationRailDestination(
                          icon: const Icon(Icons.settings_outlined),
                          selectedIcon: const Icon(Icons.settings),
                          label: Text('Settings'.i18n),
                        ),
                      ],
                    ),
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
                          child: widget.child,
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
    int navBarIndex = _selectedIndex;
    if (_selectedIndex >= 2) {
      navBarIndex = 2; // All library routes map to index 2
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
