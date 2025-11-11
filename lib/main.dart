import 'dart:async';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:get_it/get_it.dart';
import 'package:i18n_extension/i18n_extension.dart';
import 'package:logging/logging.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:quick_actions/quick_actions.dart';
import 'package:saturn/utils/rpc_service.dart';
import 'package:saturn/utils/single_instance.dart';
import 'package:saturn/utils/tray_service.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:windows_taskbar/windows_taskbar.dart';

import 'api/cache.dart';
import 'api/deezer.dart';
import 'api/definitions.dart';
import 'api/download.dart';
import 'api/stream_server_dart.dart';
import 'router/app_router.dart';
import 'service/audio_service.dart';
import 'service/service_locator.dart';
import 'settings.dart';
import 'translations.i18n.dart';
import 'ui/restartable.dart';
import 'ui/search.dart';
import 'ui/toast.dart';
import 'utils/directory_migration.dart';
import 'utils/logging.dart';

late Function updateTheme;
late Function logOut;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize single instance service
  final singleInstanceService = await SingleInstanceService.getInstance();
  await singleInstanceService.initialize();

  // Only continue if this is the first instance
  // Note: For Windows, this is handled in initialize()
  if (!Platform.isWindows) {
    final isFirstInstance = await singleInstanceService.isFirstInstance();
    if (!isFirstInstance) {
      exit(0);
    }
  }

  // Request notification permissions on all platforms
  try {
    // Android, iOS, Windows support permission_handler
    if (Platform.isAndroid || Platform.isIOS || Platform.isWindows) {
      final status = await Permission.notification.status;
      if (status.isDenied || status.isPermanentlyDenied) {
        await Permission.notification.request();
      }
    }
    // macOS and Linux notification permissions are typically handled at app level
    // or during notification initialization
  } catch (e) {
    // Silently fail if permission handler doesn't support this platform
    if (kDebugMode) {
      print('Notification permission request error: $e');
    }
  }

  await prepareRun();

  runApp(const Restartable(child: SaturnApp()));
}

Future<void> prepareRun() async {
  await initializeLogging();
  Logger.root.info('Starting Saturn App...');

  // Run directory migration before loading settings
  Logger.root.info('Running directory migration...');
  final migrationSuccess = await DirectoryMigration.migrate();
  if (migrationSuccess) {
    Logger.root.info('Directory migration completed successfully');
  } else {
    Logger.root.warning('Directory migration completed with errors');
  }

  settings = await Settings().loadSettings();
  cache = await Cache.load();
}

class SaturnApp extends StatefulWidget {
  const SaturnApp({super.key});

  @override
  _SaturnAppState createState() => _SaturnAppState();
}

class _SaturnAppState extends State<SaturnApp> {
  @override
  void initState() {
    //Make update theme global
    updateTheme = _updateTheme;
    _updateTheme();
    super.initState();
  }

  @override
  void dispose() {
    super.dispose();
  }

  void _updateTheme() {
    setState(() {
      settings.themeData;
    });
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        systemNavigationBarColor: settings.themeData.bottomAppBarTheme.color,
        systemNavigationBarIconBrightness: settings.isDark
            ? Brightness.light
            : Brightness.dark,
      ),
    );
  }

  Locale? _locale() {
    if (settings.language == null) return null;

    // Support both old format (underscore) and new format (hyphen)
    String language = settings.language!;
    List<String> parts = language.contains('-')
        ? language.split('-')
        : language.split('_');

    if (parts.length < 2) return null;
    return Locale(parts[0], parts[1]);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Saturn',
      shortcuts: <ShortcutActivator, Intent>{
        ...WidgetsApp.defaultShortcuts,
        LogicalKeySet(LogicalKeyboardKey.select):
            const ActivateIntent(), // DPAD center key, for remote controls
      },
      theme: settings.themeData,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: supportedLocales,
      routerConfig: appRouter,
      debugShowCheckedModeBanner: false,
      builder: (context, child) {
        return I18n(
          initialLocale: _locale(),
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}

//Wrapper for login and main screen - now handled by router
class AppInitializer extends StatefulWidget {
  final Widget child;

  const AppInitializer({required this.child, super.key});

  @override
  _AppInitializerState createState() => _AppInitializerState();
}

class _AppInitializerState extends State<AppInitializer> {
  late final AppLifecycleListener _lifeCycleListener;
  Future<void>? _initialization;
  StreamSubscription? _urlLinkStream;

  @override
  void initState() {
    super.initState();
    _lifeCycleListener = AppLifecycleListener(
      onStateChange: _onLifeCycleChanged,
    );

    //Load token on background
    deezerAPI.arl = settings.arl;
    settings.offlineMode = true;
    deezerAPI.authorize().then((b) async {
      if (b) setState(() => settings.offlineMode = false);
    });

    //Global logOut function
    logOut = _logOut;

    // Initialize app
    _initialization = _init();
  }

  Future<void> _init() async {
    //Set display mode
    if ((settings.displayMode ?? -1) >= 0) {
      FlutterDisplayMode.supported.then((modes) async {
        if (modes.length - 1 >= settings.displayMode!.toInt()) {
          FlutterDisplayMode.setPreferredMode(
            modes[settings.displayMode!.toInt()],
          );
        }
      });
    }

    _preloadFavoriteTracksToCache();
    _initDownloadManager();
    String arl = settings.arl ?? '';
    await StreamServerDart.instance.start(arl);
    await _setupServiceLocator();

    //Do on BG
    GetIt.I<AudioPlayerHandler>().authorizeLastFM();

    //Start with parameters
    _setupDeepLinks();
    if (Platform.isAndroid) {
      _loadPreloadInfo();
    }
    if (Platform.isAndroid || Platform.isIOS) {
      _prepareQuickActions();
    }

    if (!Platform.isAndroid && !Platform.isIOS) {
      // Initialize tray service
      final trayService = await TrayService.getInstance();
      await trayService.initialize();

      final rpc = await DiscordRPCService.getInstance();
      rpc.discordRPCController();
    }

    //Restore saved queue
    _loadSavedQueue();
  }

  void _preloadFavoriteTracksToCache() async {
    try {
      cache.libraryTracks = await deezerAPI.getFavoriteTrackIds();
      Logger.root.info(
        'Cached favorite trackIds: ${cache.libraryTracks?.length}',
      );
    } catch (e, st) {
      Logger.root.severe('Error loading favorite trackIds!', e, st);
    }
  }

  void _initDownloadManager() async {
    await downloadManager.init();
  }

  Future<void> _setupServiceLocator() async {
    await setupServiceLocator();
    // Wait for the player to be initialized
    await GetIt.I<AudioPlayerHandler>().waitForPlayerInitialization();
    if (Platform.isWindows) {
      GetIt.I<AudioPlayerHandler>().player.playingStream.listen((
        playing,
      ) async {
        WindowsTaskbar.setThumbnailToolbar([
          ThumbnailToolbarButton(
            ThumbnailToolbarAssetIcon('assets/skip-previous.ico'),
            'Skip Previous',
            () {
              GetIt.I<AudioPlayerHandler>().skipToPrevious();
            },
          ),
          if (playing) ...[
            ThumbnailToolbarButton(
              ThumbnailToolbarAssetIcon('assets/pause.ico'),
              'Pause',
              () {
                GetIt.I<AudioPlayerHandler>().pause();
              },
            ),
          ] else ...[
            ThumbnailToolbarButton(
              ThumbnailToolbarAssetIcon('assets/play.ico'),
              'Play',
              () {
                GetIt.I<AudioPlayerHandler>().play();
              },
            ),
          ],
          ThumbnailToolbarButton(
            ThumbnailToolbarAssetIcon('assets/skip-next.ico'),
            'Skip Next',
            () {
              GetIt.I<AudioPlayerHandler>().skipToNext();
            },
          ),
        ]);

        Menu menu = Menu(
          items: [
            MenuItem(
              label: 'Restore',
              onClick: (_) async {
                await windowManager.show();
                await windowManager.focus();
              },
            ),
            if (playing) ...[
              MenuItem(
                label: 'Pause',
                onClick: (_) async {
                  GetIt.I<AudioPlayerHandler>().pause();
                },
              ),
            ] else ...[
              MenuItem(
                label: 'Play',
                onClick: (_) async {
                  GetIt.I<AudioPlayerHandler>().play();
                },
              ),
            ],
            MenuItem(
              label: 'Next',
              onClick: (_) async {
                GetIt.I<AudioPlayerHandler>().skipToNext();
              },
            ),
            MenuItem(
              label: 'Previous',
              onClick: (_) async {
                GetIt.I<AudioPlayerHandler>().skipToPrevious();
              },
            ),
            MenuItem(
              label: 'Exit',
              onClick: (_) async {
                await trayManager.destroy();
                exit(0);
              },
            ),
          ],
        );

        await trayManager.setContextMenu(menu);
      });
    }
  }

  void _prepareQuickActions() {
    const QuickActions quickActions = QuickActions();
    quickActions.initialize((type) {
      _startPreload(type);
    });

    //Actions
    quickActions.setShortcutItems([
      ShortcutItem(
        type: 'favorites',
        localizedTitle: 'Favorites'.i18n,
        icon: 'ic_favorites',
      ),
      ShortcutItem(type: 'flow', localizedTitle: 'Flow'.i18n, icon: 'ic_flow'),
    ]);
  }

  void _startPreload(String type) async {
    await deezerAPI.authorize();
    if (type == 'flow') {
      await GetIt.I<AudioPlayerHandler>().playFromSmartTrackList(
        SmartTrackList(id: 'flow'),
      );
      return;
    }
    if (type == 'favorites') {
      Playlist p = await deezerAPI.fullPlaylist(
        deezerAPI.favoritesPlaylistId.toString(),
      );
      GetIt.I<AudioPlayerHandler>().playFromPlaylist(p, p.tracks?[0].id ?? '');
    }
  }

  void _loadPreloadInfo() async {
    String info =
        await DownloadManager.platform.invokeMethod('getPreloadInfo') ?? '';
    if (info.isEmpty) return;
    _startPreload(info);
  }

  Future<void> _loadSavedQueue() async {
    GetIt.I<AudioPlayerHandler>().loadQueueFromFile();
  }

  void _setupDeepLinks() async {
    AppLinks deepLinks = AppLinks();

    // Check initial link if app was in cold state (terminated)
    final deepLink = await deepLinks.getInitialLinkString();
    if (deepLink != null && deepLink.length > 4) {
      Logger.root.info('Opening app from deeplink: $deepLink');
      openScreenByURL(deepLink);
    }

    //Listen to URLs when app is in warm state (front or background)
    _urlLinkStream = deepLinks.stringLinkStream.listen(
      (deeplink) {
        Logger.root.info('Opening deeplink: $deeplink');
        openScreenByURL(deeplink);
      },
      onError: (e) {
        Logger.root.severe('Error handling app link: $e');
      },
    );
  }

  void _onLifeCycleChanged(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.detached:
        Logger.root.info('App detached.');
        downloadManager.stop();
        GetIt.I<AudioPlayerHandler>().saveQueueToFile();
      case AppLifecycleState.resumed:
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
    }
  }

  Future _logOut() async {
    try {
      GetIt.I<AudioPlayerHandler>().stop();
      GetIt.I<AudioPlayerHandler>().updateQueue([]);
      GetIt.I<AudioPlayerHandler>().removeSavedQueueFile();
    } catch (e, st) {
      Logger.root.severe(
        'Error stopping and clearing audio service before logout',
        e,
        st,
      );
    }
    await downloadManager.stop();
    await StreamServerDart.instance.stop();
    // Avoid calling setState if this State has been disposed. If we're no
    // longer mounted apply the assignments directly.
    if (mounted) {
      setState(() {
        settings.arl = null;
        settings.offlineMode = false;
        deezerAPI = DeezerAPI();
      });
    } else {
      settings.arl = null;
      settings.offlineMode = false;
      deezerAPI = DeezerAPI();
    }
    await settings.save();
    await Cache.wipe();
    Restartable.restart();
  }

  @override
  void dispose() {
    _urlLinkStream?.cancel();
    _lifeCycleListener.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Initialize toast for desktop platforms
    Fluttertoast.init(context);

    return FutureBuilder(
      future: _initialization,
      builder: (context, snapshot) {
        // Check _initialization status
        if (snapshot.connectionState == ConnectionState.done) {
          // When _initialization is done, render app
          return widget.child;
        } else {
          // While initializing
          return Scaffold(
            body: Center(
              child: CircularProgressIndicator(
                color: Theme.of(context).primaryColor,
              ),
            ),
          );
        }
      },
    );
  }
}
