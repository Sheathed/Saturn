import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flutter_localizations/flutter_localizations.dart'
    as flutter_localizations;
import 'package:get_it/get_it.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:i18n_extension/i18n_extension.dart';
import 'package:logging/logging.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:quick_actions/quick_actions.dart';
import 'package:saturn/utils/rpc_service.dart';
import 'package:saturn/utils/single_instance.dart';
import 'package:saturn/utils/tray_service.dart';
import 'package:window_manager/window_manager.dart';
import 'package:windows_taskbar/windows_taskbar.dart';
import 'api/cache.dart';
import 'api/definitions.dart';
import 'api/download.dart';
import 'platform/deezer/deezer_platform.dart';
import 'platform/stream_proxy_server.dart';
import 'platform/platform_manager.dart';
import 'platform/platform_registry.dart';
import 'platform/neurokaraoke/neurokaraoke_platform.dart';
import 'platform/soundcloud/soundcloud_platform.dart';
import 'platform/youtube_music/youtube_music_platform.dart';

import 'router/app_router.dart';
import 'service/audio_service.dart';
import 'service/service_locator.dart';
import 'settings.dart';
import 'translations.i18n.dart';
import 'ui/restartable.dart';
import 'ui/music_link_navigation.dart';
import 'ui/toast.dart';
import 'utils/app_config.dart';
import 'utils/directory_migration.dart';
import 'utils/logging.dart';
import 'utils/app_http_proxy.dart';
import 'utils/app_webview_proxy.dart';
import 'utils/update_service.dart';

late Function updateTheme;
late Future<void> Function() logOut;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Set up global error handling
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    Logger.root.severe(
      'Flutter Error: ${details.exception}',
      details.exception,
      details.stack,
    );
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    Logger.root.severe('PlatformDispatcher Error: $error', error, stack);
    return true;
  };

  ErrorWidget.builder = (FlutterErrorDetails details) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Material(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error, color: Colors.red, size: 64.0),
                const SizedBox(height: 16.0),
                Text(
                  'An unexpected error occurred.'.i18n,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8.0),
                Text(
                  details.exceptionAsString(),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12.0),
                ),
                const SizedBox(height: 16.0),
                Text(
                  'Please check the logs for more details.'.i18n,
                  style: const TextStyle(fontSize: 12.0),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  };

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

  // Register the media-session callbacks before any filesystem migration,
  // settings load, or permission prompt. Android may send the resume click as
  // soon as its service process starts; the handler holds player startup until
  // prepareRun has populated the globals and started the proxy.
  if (Platform.isAndroid) await setupServiceLocator();

  await prepareRun();

  runApp(const Restartable(child: SaturnApp()));

  // Permission UI belongs to an attached app window. A cold Android media
  // resumption starts this same Dart entry point without an Activity, and must
  // not wait for a permission dialog before it can prepare playback.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(_configureDesktopWindow());
    if (PlatformDispatcher.instance.views.isNotEmpty) {
      unawaited(() async {
        await _requestNotificationPermission();
        await UpdateService.instance.checkForUpdates(notifyIfAvailable: true);
      }());
    }
  });

  // Restoring the saved playlist creates every audio source and can perform
  // platform/filesystem work. Let Flutter paint the app before doing that so a
  // broken restored queue cannot hold the user on a blank launch screen.
  if (Platform.isAndroid) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(() async {
        final handler = GetIt.I<AudioPlayerHandler>();
        await handler.waitForPlayerInitialization();
        await handler.loadQueueFromFile();
      }());
    });
  }
}

Future<void> _configureDesktopWindow() async {
  if (!Platform.isLinux && !Platform.isWindows && !Platform.isMacOS) return;

  try {
    await windowManager.ensureInitialized();
    await windowManager.setTitle(appTitle);
  } catch (error, stackTrace) {
    Logger.root.warning(
      'Could not configure desktop window: $error',
      error,
      stackTrace,
    );
  }
}

Future<void> _requestNotificationPermission() async {
  if (!Platform.isAndroid && !Platform.isIOS && !Platform.isWindows) return;
  try {
    final status = await Permission.notification.status;
    if (status.isDenied || status.isPermanentlyDenied) {
      await Permission.notification.request();
    }
  } catch (e) {
    if (kDebugMode) {
      appLogger.warning('Notification permission request error', e);
    }
  }
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
  AppHttpProxy.configure(
    settings.proxyAddress,
    username: settings.proxyUsername,
    password: settings.proxyPassword,
  );
  try {
    await AppWebViewProxy.configure(
      settings.proxyAddress,
      username: settings.proxyUsername,
      password: settings.proxyPassword,
    );
  } on MissingPluginException {
    // A background media-resumption engine has no Activity or WebView.
  } on PlatformException catch (error) {
    Logger.root.warning('WebView proxy configuration failed: ${error.code}');
  }
  cache = await Cache.load();

  // Register compiled-in platform plugins
  Logger.root.info('Registering platform plugins...');
  PlatformRegistry.instance.register(DeezerPlatform());
  PlatformRegistry.instance.register(NeuroKaraokePlatform());
  PlatformRegistry.instance.register(SoundCloudPlatform());
  PlatformRegistry.instance.register(YouTubeMusicPlatform());

  // Move old global Deezer credentials into Deezer's own platform config
  // before any service or download worker reads settings.
  await DeezerPlatform.instance.migrateLegacyArlIfNeeded();

  // Initialize the active platform from saved settings
  PlatformManager.instance.initialize(platformId: settings.activePlatformId);
  Logger.root.info(
    'Active platform: ${PlatformManager.instance.activePlatformId}',
  );

  // Every platform uses the local stream proxy. Binding to port zero keeps
  // separate app installs/processes from contending for the same loopback port.
  await StreamProxyServer.instance.start();

  if (Platform.isAndroid) AudioPlayerHandler.markAndroidRuntimeReady();
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
    return DynamicColorBuilder(
      builder: (ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
        settings.dynamicLightScheme = lightDynamic;
        settings.dynamicDarkScheme = darkDynamic;
        return MaterialApp.router(
          title: appTitle,
          // Use the localization delegates bundled with material_ui so its
          // widgets receive the MaterialLocalizations type they look up. The
          // app's translations remain managed by I18n below.
          locale: _locale(),
          localeResolutionCallback: (requestedLocale, appLocales) {
            final materialLocales = appLocales
                .where(GlobalMaterialLocalizations.delegate.isSupported)
                .toList();
            if (requestedLocale != null) {
              for (final candidate in materialLocales) {
                if (candidate.languageCode == requestedLocale.languageCode &&
                    candidate.countryCode == requestedLocale.countryCode) {
                  return candidate;
                }
              }
              for (final candidate in materialLocales) {
                if (candidate.languageCode == requestedLocale.languageCode) {
                  return candidate;
                }
              }
            }
            for (final candidate in materialLocales) {
              if (candidate.languageCode == 'en') return candidate;
            }
            return const Locale('en', 'US');
          },
          shortcuts: <ShortcutActivator, Intent>{
            ...WidgetsApp.defaultShortcuts,
            LogicalKeySet(LogicalKeyboardKey.select):
                const ActivateIntent(), // DPAD center key, for remote controls
          },
          theme: settings.themeData,
          localizationsDelegates: <LocalizationsDelegate<dynamic>>[
            ...GlobalMaterialLocalizations.delegates,
            // CountryPickerDialog still uses Flutter's SDK Material widgets.
            // Register that parallel localization type alongside material_ui's.
            flutter_localizations.GlobalMaterialLocalizations.delegate,
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

    // Load token on background via the connected platforms
    settings.offlineMode = true;
    PlatformRegistry.instance.loggedInPlatforms.then((loggedIn) async {
      await PlatformManager.instance.refreshLoggedInStatus();
      if (loggedIn.isNotEmpty) {
        if (!loggedIn.any(
          (p) => p.platformId == PlatformManager.instance.activePlatformId,
        )) {
          PlatformManager.instance.switchPlatform(loggedIn.first.platformId);
        }
        if (mounted) setState(() => settings.offlineMode = false);
        if (GetIt.I.isRegistered<AudioPlayerHandler>()) {
          unawaited(GetIt.I<AudioPlayerHandler>().retryPendingListenLogs());
        }
      }
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
    await _setupServiceLocator();
    if (settings.useArtColor) {
      settings.initArtColorListener();
    }

    //Do on BG
    GetIt.I<AudioPlayerHandler>().authorizeLastFM();

    //Start with parameters
    _setupDeepLinks();
    if (Platform.isAndroid) {
      unawaited(_loadPreloadInfo());
    }
    if (Platform.isAndroid || Platform.isIOS) {
      unawaited(_prepareQuickActions());
    }

    if (!Platform.isAndroid && !Platform.isIOS) {
      // Initialize tray service
      final trayService = await TrayService.getInstance();
      await trayService.initialize();

      final rpc = await DiscordRPCService.getInstance();
      rpc.discordRPCController();
    }
  }

  void _preloadFavoriteTracksToCache() async {
    try {
      if (PlatformManager.instance.active.capabilities.supportsLibrarySync) {
        cache.activeLibraryTracks =
            (await PlatformManager.instance.active.getFavoriteTrackIds()) ?? [];
        cache.activeLibraryPlaylists =
            (await PlatformManager.instance.active.getFavoritePlaylistIds()) ??
            [];
        await cache.save();
        Logger.root.info(
          'Cached favorite trackIds: ${cache.activeLibraryTracks.length}',
        );
      }
    } catch (e, st) {
      Logger.root.severe('Error loading favorite trackIds!', e, st);
    }
  }

  void _initDownloadManager() async {
    await downloadManager.init();
    try {
      if (GetIt.I.isRegistered<AudioPlayerHandler>()) {
        final handler = GetIt.I<AudioPlayerHandler>();
        handler.notifyChildrenChanged('playlists');
        handler.notifyChildrenChanged('offline');
        handler.notifyChildrenChanged('offline_playlists');
        for (final p in PlatformRegistry.instance.allPlatforms) {
          handler.notifyChildrenChanged('playlists_${p.platformId}');
        }
      }
    } catch (_) {}
  }

  Future<void> _setupServiceLocator() async {
    await setupServiceLocator();
    // Wait for the player to be initialized
    await GetIt.I<AudioPlayerHandler>().waitForPlayerInitialization();
    if (!GetIt.I<AudioPlayerHandler>().isQueueReady) {
      // Restoring builds every audio source; let the first frames paint first.
      // Anything needing the queue earlier calls loadQueueFromFile itself.
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 600), () {
          if (!GetIt.I<AudioPlayerHandler>().isQueueReady) {
            return GetIt.I<AudioPlayerHandler>().loadQueueFromFile();
          }
        }),
      );
    }
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
      });
    }
  }

  Future<void> _prepareQuickActions() async {
    try {
      const quickActions = QuickActions();
      await quickActions.initialize((type) {
        _startPreload(type);
      });
      await quickActions.setShortcutItems([
        ShortcutItem(
          type: 'favorites',
          localizedTitle: 'Favorites'.i18n,
          icon: 'ic_favorites',
        ),
        ShortcutItem(
          type: 'flow',
          localizedTitle: 'Flow'.i18n,
          icon: 'ic_flow',
        ),
      ]);
    } on MissingPluginException {
      // The media-resumption engine has no Activity for this UI plugin.
    } on PlatformException catch (error) {
      Logger.root.info('Quick actions unavailable during startup: $error');
    }
  }

  void _startPreload(String type) async {
    if (!await PlatformManager.instance.active.isLoggedIn()) return;
    if (type == 'flow') {
      await GetIt.I<AudioPlayerHandler>().playFromSmartTrackList(
        SmartTrackList(id: 'flow'),
      );
      return;
    }
    if (type == 'favorites') {
      try {
        final platform = PlatformManager.instance.active;
        // Use the first available user playlist as a fallback for platforms
        // that do not expose a dedicated favorites playlist.
        final playlists = await platform.getUserPlaylists();
        if (playlists.isNotEmpty) {
          Playlist p = await platform.getFullPlaylist(playlists.first.id!);
          final firstTrackId = p.tracks?.isNotEmpty == true
              ? (p.tracks!.first.id ?? '')
              : '';
          GetIt.I<AudioPlayerHandler>().playFromPlaylist(p, firstTrackId);
        }
      } catch (e) {
        Logger.root.severe('Error preloading favorites', e);
      }
    }
  }

  Future<void> _loadPreloadInfo() async {
    try {
      final info =
          await DownloadManager.platform.invokeMethod<String>(
            'getPreloadInfo',
          ) ??
          '';
      if (info.isNotEmpty) _startPreload(info);
    } on MissingPluginException {
      // A background media engine can start before the Activity channel exists.
    }
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

  Future<void> _logOut() async {
    try {
      final audioHandler = GetIt.I<AudioPlayerHandler>();
      await audioHandler.stop();
      await audioHandler.updateQueue([]);
      await audioHandler.removeSavedQueueFile();
    } catch (e, st) {
      Logger.root.severe(
        'Error stopping and clearing audio service before logout',
        e,
        st,
      );
    }
    await downloadManager.stop();
    // Avoid calling setState if this State has been disposed. If we're no
    // longer mounted apply the assignments directly.
    if (mounted) {
      setState(() {
        settings.offlineMode = false;
      });
    } else {
      settings.offlineMode = false;
    }
    Object? logoutError;
    for (final platform in PlatformRegistry.instance.allPlatforms) {
      try {
        await platform.logout();
      } catch (error, stackTrace) {
        logoutError ??= error;
        Logger.root.severe(
          'Failed to log out of ${platform.platformName}',
          error,
          stackTrace,
        );
      }
    }
    await settings.save();
    await Cache.wipe();
    Restartable.restart();
    if (logoutError != null) {
      throw StateError('One or more platforms could not be logged out.');
    }
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
