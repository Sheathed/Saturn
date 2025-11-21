import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../api/definitions.dart';
import '../translations.i18n.dart';
import '../ui/details_screens.dart';
import '../ui/downloads_screen.dart';
import '../ui/elements.dart';
import '../ui/error.dart';
import '../ui/home_screen.dart';
import '../ui/library.dart';
import '../ui/log_screen.dart';
import '../ui/player_screen.dart';
import '../ui/search.dart';
import '../ui/settings_screen.dart';
import 'shell_route_scaffold.dart';

// Route paths
class AppRoutes {
  // Root routes
  static const String login = '/login';
  static const String main = '/';

  // Bottom navigation routes (nested under shell)
  static const String home = '/home';
  static const String browse = '/browse';
  static const String search = '/search';
  static const String library = '/library';

  // Library sub-routes
  static const String libraryTracks = '/library/tracks';
  static const String libraryAlbums = '/library/albums';
  static const String libraryArtists = '/library/artists';
  static const String libraryPlaylists = '/library/playlists';
  static const String libraryPodcasts = '/library/podcasts';
  static const String libraryHistory = '/library/history';

  // Detail routes
  static const String album = '/album/:id';
  static const String artist = '/artist/:id';
  static const String playlist = '/playlist/:id';
  static const String show = '/show/:id';

  // Other routes
  static const String settings = '/settings';
  static const String downloads = '/downloads';
  static const String player = '/player';
  static const String logs = '/logs';
  static const String error = '/error';
  static const String searchResults = '/search/results';
  static const String noPremium = '/nopremium';
}

// Global navigator keys
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>(
  debugLabel: 'root',
);
final GlobalKey<NavigatorState> _shellNavigatorKey = GlobalKey<NavigatorState>(
  debugLabel: 'shell',
);

// GoRouter configuration
final GoRouter appRouter = GoRouter(
  navigatorKey: rootNavigatorKey,
  initialLocation: AppRoutes.home,
  debugLogDiagnostics: true,
  routes: [
    // Shell route with bottom navigation
    ShellRoute(
      navigatorKey: _shellNavigatorKey,
      builder: (context, state, child) {
        return ShellRouteScaffold(child: child);
      },
      routes: [
        // Home tab
        GoRoute(
          path: AppRoutes.home,
          pageBuilder: (context, state) =>
              NoTransitionPage(key: state.pageKey, child: const HomeScreen()),
        ),

        // Browse tab
        GoRoute(
          path: AppRoutes.browse,
          pageBuilder: (context, state) => NoTransitionPage(
            key: state.pageKey,
            child: Scaffold(
              appBar: FreezerAppBar('Browse'.i18n),
              body: SingleChildScrollView(
                child: HomePageScreen(
                  channel: DeezerChannel(target: 'channels/explore'),
                ),
              ),
            ),
          ),
        ),

        // Search tab
        GoRoute(
          path: AppRoutes.search,
          pageBuilder: (context, state) =>
              NoTransitionPage(key: state.pageKey, child: const SearchScreen()),
          routes: [
            // Search results
            GoRoute(
              path: 'results',
              builder: (context, state) {
                final query = state.uri.queryParameters['q'] ?? '';
                final offline = state.uri.queryParameters['offline'] == 'true';
                return SearchResultsScreen(query, offline: offline);
              },
            ),
          ],
        ),

        // Library tab
        GoRoute(
          path: AppRoutes.library,
          pageBuilder: (context, state) => NoTransitionPage(
            key: state.pageKey,
            child: const LibraryScreen(),
          ),
        ),

        // Library sub-routes
        GoRoute(
          path: AppRoutes.libraryTracks,
          builder: (context, state) => const LibraryTracks(),
        ),
        GoRoute(
          path: AppRoutes.libraryAlbums,
          builder: (context, state) => const LibraryAlbums(),
        ),
        GoRoute(
          path: AppRoutes.libraryArtists,
          builder: (context, state) => const LibraryArtists(),
        ),
        GoRoute(
          path: AppRoutes.libraryPlaylists,
          builder: (context, state) => const LibraryPlaylists(),
        ),
        GoRoute(
          path: AppRoutes.libraryPodcasts,
          builder: (context, state) => const LibraryShows(),
        ),
        GoRoute(
          path: AppRoutes.libraryHistory,
          builder: (context, state) => const HistoryScreen(),
        ),

        GoRoute(
          path: AppRoutes.settings,
          builder: (context, state) => const SettingsScreen(),
        ),

        GoRoute(
          path: AppRoutes.downloads,
          builder: (context, state) => const DownloadsScreen(),
        ),

        GoRoute(
          path: '/album/:id',
          builder: (context, state){
            final album = state.extra as Album?;
            if (album != null) {
              return AlbumDetails(album);
            }
            return const ErrorScreen();
          },
        ),

        GoRoute(
          path: '/artist/:id',
          builder: (context, state) {
            final artist = state.extra as Artist?;
            if (artist != null) {
              return ArtistDetails(artist);
            }
            return const ErrorScreen();
          },
        ),

        GoRoute(
          path: '/playlist/:id',
          builder: (context, state) {
            final playlist = state.extra as Playlist?;
            if (playlist != null) {
              return PlaylistDetails(playlist);
            }
            return const ErrorScreen();
          },
        ),

        GoRoute(
          path: '/show/:id',
          builder: (context, state) {
            final show = state.extra as Show?;
            if (show != null) {
              return ShowScreen(show);
            }
            return const ErrorScreen();
          },
        ),
      ],
    ),

    // Full-screen routes (outside shell)
    GoRoute(
      path: AppRoutes.player,
      parentNavigatorKey: rootNavigatorKey,
      builder: (context, state) => const PlayerScreen(),
    ),

    GoRoute(
      path: AppRoutes.logs,
      parentNavigatorKey: rootNavigatorKey,
      builder: (context, state) => const ApplicationLogViewer(),
    ),

    GoRoute(
      path: AppRoutes.error,
      parentNavigatorKey: rootNavigatorKey,
      builder: (context, state) => const ErrorScreen(),
    ),
  ],
  errorBuilder: (context, state) => const ErrorScreen(),
);
