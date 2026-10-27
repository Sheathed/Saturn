import 'package:saturn/platform/platform_manager.dart';
import 'package:material_ui/material_ui.dart';
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
final GlobalKey<NavigatorState> bodyOverlayNavigatorKey =
    GlobalKey<NavigatorState>(debugLabel: 'bodyOverlay');
final ValueNotifier<bool> bodyOverlayActive = ValueNotifier(false);
final GlobalKey<NavigatorState> _shellNavigatorKey = GlobalKey<NavigatorState>(
  debugLabel: 'shell',
);

bool isShellRouteContext(BuildContext context) =>
    identical(Navigator.maybeOf(context), _shellNavigatorKey.currentState);

class _PlatformScopedPage extends StatelessWidget {
  final WidgetBuilder builder;

  const _PlatformScopedPage({required this.builder});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: PlatformManager.instance,
      builder: (context, _) => KeyedSubtree(
        key: ValueKey(PlatformManager.instance.activePlatformId),
        child: builder(context),
      ),
    );
  }
}

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
          pageBuilder: (context, state) => NoTransitionPage(
            key: state.pageKey,
            child: _PlatformScopedPage(builder: (_) => const HomeScreen()),
          ),
        ),

        // Browse tab
        GoRoute(
          path: AppRoutes.browse,
          pageBuilder: (context, state) => NoTransitionPage(
            key: state.pageKey,
            child: Scaffold(
              appBar: FreezerAppBar('Browse'.i18n),
              body: _PlatformScopedPage(
                builder: (context) =>
                    PlatformManager.instance.active.getExploreWidget(context),
              ),
            ),
          ),
        ),

        // Search tab
        GoRoute(
          path: AppRoutes.search,
          pageBuilder: (context, state) => NoTransitionPage(
            key: state.pageKey,
            child: _PlatformScopedPage(builder: (_) => const SearchScreen()),
          ),
          routes: [
            // Search results
            GoRoute(
              path: 'results',
              pageBuilder: (context, state) {
                final query = state.uri.queryParameters['q'] ?? '';
                final offline = state.uri.queryParameters['offline'] == 'true';
                return NoTransitionPage(
                  key: state.pageKey,
                  child: _PlatformScopedPage(
                    builder: (_) =>
                        SearchResultsScreen(query, offline: offline),
                  ),
                );
              },
            ),
          ],
        ),

        // Library tab
        GoRoute(
          path: AppRoutes.library,
          pageBuilder: (context, state) => NoTransitionPage(
            key: state.pageKey,
            child: _PlatformScopedPage(builder: (_) => const LibraryScreen()),
          ),
        ),

        // Library sub-routes
        GoRoute(
          path: AppRoutes.libraryTracks,
          pageBuilder: (context, state) => NoTransitionPage(
            key: state.pageKey,
            child: _PlatformScopedPage(builder: (_) => const LibraryTracks()),
          ),
        ),
        GoRoute(
          path: AppRoutes.libraryAlbums,
          pageBuilder: (context, state) => NoTransitionPage(
            key: state.pageKey,
            child: _PlatformScopedPage(builder: (_) => const LibraryAlbums()),
          ),
        ),
        GoRoute(
          path: AppRoutes.libraryArtists,
          pageBuilder: (context, state) => NoTransitionPage(
            key: state.pageKey,
            child: _PlatformScopedPage(builder: (_) => const LibraryArtists()),
          ),
        ),
        GoRoute(
          path: AppRoutes.libraryPlaylists,
          pageBuilder: (context, state) => NoTransitionPage(
            key: state.pageKey,
            child: _PlatformScopedPage(
              builder: (_) => const LibraryPlaylists(),
            ),
          ),
        ),
        GoRoute(
          path: AppRoutes.libraryPodcasts,
          pageBuilder: (context, state) => NoTransitionPage(
            key: state.pageKey,
            child: _PlatformScopedPage(builder: (_) => const LibraryShows()),
          ),
        ),
        GoRoute(
          path: AppRoutes.libraryHistory,
          pageBuilder: (context, state) => NoTransitionPage(
            key: state.pageKey,
            child: _PlatformScopedPage(builder: (_) => const HistoryScreen()),
          ),
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
          builder: (context, state) {
            final album = state.extra as Album?;
            if (album != null) {
              return AlbumDetails(album);
            }
            final id = state.pathParameters['id'];
            if (id != null && id.isNotEmpty) {
              return AlbumDetails(Album(id: id));
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
            final id = state.pathParameters['id'];
            if (id != null && id.isNotEmpty) {
              return ArtistDetails(Artist(id: Uri.decodeComponent(id)));
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
            final id = state.pathParameters['id'];
            if (id != null && id.isNotEmpty) {
              return PlaylistDetails(Playlist(id: id));
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
            final id = state.pathParameters['id'];
            if (id != null && id.isNotEmpty) {
              return ShowScreen(Show(id: id));
            }
            return const ErrorScreen();
          },
        ),

        GoRoute(
          path: '/track/:id',
          builder: (context, state) {
            final track = state.extra as Track?;
            if (track != null) {
              return TrackDetails(track);
            }
            final id = state.pathParameters['id'];
            if (id != null && id.isNotEmpty) {
              final platformId =
                  state.uri.queryParameters['platform'] ??
                  PlatformManager.instance.activePlatformId;
              return TrackDetails(
                Track(id: Uri.decodeComponent(id), platformId: platformId),
              );
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
      pageBuilder: (context, state) => CustomTransitionPage<void>(
        key: state.pageKey,
        child: const PlayerScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) =>
            SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 1),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
      ),
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

void openPlayerScreen() {
  final current = appRouter.routerDelegate.currentConfiguration;
  if (current.isNotEmpty && current.last.route.path == AppRoutes.player) return;
  appRouter.push<void>(AppRoutes.player);
}
