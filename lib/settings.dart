import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:external_path/external_path.dart';
import 'package:material_ui/material_ui.dart';
import 'package:get_it/get_it.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'api/download.dart';
import 'main.dart';
import 'package:audio_service/audio_service.dart';
import 'service/audio_service.dart';
import 'ui/app_theme.dart';
import 'ui/cached_image.dart';

part 'settings.g.dart';

late Settings settings;

@JsonSerializable()
class Settings {
  //Language
  @JsonKey(defaultValue: null)
  String? language;

  //Main
  @JsonKey(defaultValue: false)
  late bool ignoreInterruptions;
  @JsonKey(defaultValue: false)
  late bool enableEqualizer;
  @JsonKey(defaultValue: false)
  late bool eastereggsDisabled;

  // Legacy Deezer ARL. Read only so startup can migrate old settings into
  // platformConfigs['deezer']; never write credentials back to the root.
  @JsonKey(includeToJson: false)
  String? arl;
  @JsonKey(includeFromJson: false)
  @JsonKey(includeToJson: false)
  bool offlineMode = false;

  @JsonKey(includeFromJson: false)
  @JsonKey(includeToJson: false)
  bool preventSave = false;

  //Quality
  @JsonKey(defaultValue: AudioQuality.MP3_320)
  late AudioQuality wifiQuality;
  @JsonKey(defaultValue: AudioQuality.MP3_128)
  late AudioQuality mobileQuality;
  @JsonKey(defaultValue: AudioQuality.FLAC)
  late AudioQuality offlineQuality;
  @JsonKey(defaultValue: AudioQuality.FLAC)
  late AudioQuality downloadQuality;

  //Download options
  String? downloadPath;

  @JsonKey(defaultValue: '%artist% - %title%')
  late String downloadFilename;
  @JsonKey(defaultValue: true)
  late bool albumFolder;
  @JsonKey(defaultValue: true)
  late bool artistFolder;
  @JsonKey(defaultValue: false)
  late bool albumDiscFolder;
  @JsonKey(defaultValue: false)
  late bool overwriteDownload;
  @JsonKey(defaultValue: 2)
  late int downloadThreads;
  @JsonKey(defaultValue: false)
  late bool playlistFolder;
  @JsonKey(defaultValue: true)
  late bool downloadLyrics;
  @JsonKey(defaultValue: false)
  late bool downloadEnhancedLrc;
  @JsonKey(defaultValue: false)
  late bool saveOfflineTrackLyrics;
  @JsonKey(defaultValue: false)
  late bool trackCover;
  @JsonKey(defaultValue: true)
  late bool albumCover;
  @JsonKey(defaultValue: false)
  late bool nomediaFiles;
  @JsonKey(defaultValue: ', ')
  late String artistSeparator;
  @JsonKey(defaultValue: '%artist% - %title%')
  late String singletonFilename;
  @JsonKey(defaultValue: 1400)
  late int albumArtResolution;
  @JsonKey(
    defaultValue: [
      'title',
      'album',
      'artist',
      'track',
      'disc',
      'albumArtist',
      'date',
      'label',
      'isrc',
      'upc',
      'trackTotal',
      'bpm',
      'lyrics',
      'genre',
      'contributors',
      'art',
    ],
  )
  late List<String> tags;

  //Appearance
  @JsonKey(defaultValue: Themes.MaterialYouPrimary)
  late Themes theme;
  @JsonKey(defaultValue: true)
  late bool darkMode;
  @JsonKey(defaultValue: false)
  late bool useSystemTheme;

  /// Device (Material You) schemes, filled by the app root at runtime.
  @JsonKey(includeFromJson: false, includeToJson: false)
  ColorScheme? dynamicLightScheme;
  @JsonKey(includeFromJson: false, includeToJson: false)
  ColorScheme? dynamicDarkScheme;
  @JsonKey(defaultValue: false)
  late bool colorGradientBackground;
  @JsonKey(defaultValue: true)
  late bool blurPlayerBackground;
  @JsonKey(defaultValue: true)
  late bool themeAdditonalItems;
  @JsonKey(defaultValue: 'Deezer')
  late String font;
  @JsonKey(defaultValue: false)
  late bool keepSidebarOpen;
  @JsonKey(defaultValue: false)
  late bool keepSidebarClosed;
  @JsonKey(defaultValue: 256.0)
  late double sidebarExpandedWidth;
  @JsonKey(defaultValue: null)
  int? displayMode;

  //Colors
  @JsonKey(toJson: _colorToJson, fromJson: _colorFromJson)
  Color primaryColor = Colors.blue;

  static int _colorToJson(Color c) => c.toARGB32();
  static Color _colorFromJson(int? v) => v == null ? Colors.blue : Color(v);

  @JsonKey(defaultValue: true)
  bool useArtColor = false;
  StreamSubscription? _useArtColorSub;
  StreamSubscription? _playbackStateSub;
  Color? _activeArtColor;
  String? _lastProcessedArtUri;

  /// Effective primary color: uses current album art color only when active,
  /// preserving [primaryColor] for when player is stopped/idle or art color is off.
  Color get effectivePrimaryColor => (useArtColor && _activeArtColor != null)
      ? _activeArtColor!
      : primaryColor;

  //Deezer
  @JsonKey(defaultValue: 'en')
  late String deezerLanguage;
  @JsonKey(defaultValue: 'US')
  late String deezerCountry;
  @JsonKey(defaultValue: true)
  late bool logListen;
  @JsonKey(defaultValue: null)
  String? proxyAddress;
  @JsonKey(defaultValue: null)
  String? proxyUsername;
  @JsonKey(defaultValue: null)
  String? proxyPassword;

  //LastFM
  @JsonKey(defaultValue: null)
  String? lastFMUsername;
  @JsonKey(defaultValue: null)
  String? lastFMPassword;
  @JsonKey(defaultValue: null)
  String? lastFMAPIKey;
  @JsonKey(defaultValue: null)
  String? lastFMAPISecret;

  //Discord RPC
  @JsonKey(defaultValue: false)
  bool enableDiscordRPC = false;

  //premium
  @JsonKey(defaultValue: false)
  bool noPremium = false;
  @JsonKey(defaultValue: null)
  String? tier;

  //Platform management
  /// The platform ID the user last selected, e.g. 'deezer', 'soundcloud'.
  @JsonKey(defaultValue: 'deezer')
  String activePlatformId = 'deezer';

  /// Per-platform opaque config maps, keyed by platformId.
  @JsonKey(defaultValue: {})
  Map<String, dynamic> platformConfigs = {};

  /// Preferred provider and lyric record for previously selected tracks.
  @JsonKey(defaultValue: {})
  Map<String, String> lyricsChoices = {};

  /// Preferred content language for SoundCloud requests.
  @JsonKey(includeFromJson: false, includeToJson: false)
  String get soundcloudLanguage =>
      (platformConfigs['soundcloud'] as Map?)?['language'] as String? ?? 'en';
  set soundcloudLanguage(String val) {
    final cfg = platformConfigs['soundcloud'];
    final map = cfg is Map
        ? Map<String, dynamic>.from(cfg)
        : <String, dynamic>{};
    map['language'] = val;
    platformConfigs['soundcloud'] = map;
  }

  Settings({this.downloadPath, this.arl});

  /// The single app-wide theme, built by [AppTheme].
  ThemeData get themeData {
    return AppTheme.build(
      theme: theme,
      primary: effectivePrimaryColor,
      isDark: isDark,
      textTheme: textTheme,
      fontFamily: _fontFamily,
      outlinedButtonTheme: outlinedButtonTheme,
      textButtonTheme: textButtonTheme,
      dynamicLight: dynamicLightScheme,
      dynamicDark: dynamicDarkScheme,
    );
  }

  //Get all available fonts
  List<String> get fonts {
    return ['Deezer', ...GoogleFonts.asMap().keys];
  }

  void initArtColorListener() {
    _useArtColorSub?.cancel();
    _playbackStateSub?.cancel();
    if (!useArtColor) return;
    if (!GetIt.I.isRegistered<AudioPlayerHandler>()) return;

    final handler = GetIt.I<AudioPlayerHandler>();

    // Check once per song change
    _useArtColorSub = handler.mediaItem.listen((item) async {
      if (!useArtColor) return;
      final uri = item?.artUri?.toString();
      if (uri == null || uri.isEmpty) {
        if (_activeArtColor != null || _lastProcessedArtUri != null) {
          _activeArtColor = null;
          _lastProcessedArtUri = null;
          updateTheme();
        }
        return;
      }
      if (uri == _lastProcessedArtUri) return;
      _lastProcessedArtUri = uri;

      try {
        final color = await imagesDatabase.getPrimaryColor(uri);
        if (useArtColor &&
            _lastProcessedArtUri == uri &&
            _activeArtColor != color) {
          _activeArtColor = color;
          updateTheme();
        }
      } catch (_) {
        if (_activeArtColor != null) {
          _activeArtColor = null;
          updateTheme();
        }
      }
    });

    // When player is inactive/stopped, revert to user's primary color
    _playbackStateSub = handler.playbackState.listen((state) {
      if (!useArtColor) return;
      final isInactive =
          state.processingState == AudioProcessingState.idle ||
          state.processingState == AudioProcessingState.completed;
      if (isInactive) {
        if (_activeArtColor != null || _lastProcessedArtUri != null) {
          _activeArtColor = null;
          _lastProcessedArtUri = null;
          updateTheme();
        }
      }
    });
  }

  void updateUseArtColor(bool v) {
    useArtColor = v;
    save();
    if (v) {
      initArtColorListener();
    } else {
      _useArtColorSub?.cancel();
      _useArtColorSub = null;
      _playbackStateSub?.cancel();
      _playbackStateSub = null;
      _activeArtColor = null;
      _lastProcessedArtUri = null;
      updateTheme();
    }
  }

  void updateKeepSidebar(bool v, bool open) {
    if (open) {
      keepSidebarOpen = v;
      if (v) {
        keepSidebarClosed = false;
      }
    } else {
      keepSidebarClosed = v;
      if (v) {
        keepSidebarOpen = false;
      }
    }
    updateTheme();
  }

  //Load settings/init
  Future<Settings> loadSettings() async {
    String path = await getPath();
    File f = File(path);
    if (await f.exists()) {
      String data = await f.readAsString();
      return Settings.fromJson(jsonDecode(data));
    }
    Settings s = Settings.fromJson({});
    //Set default path, because async
    if (Platform.isAndroid) {
      s.downloadPath = await ExternalPath.getExternalStoragePublicDirectory(
        ExternalPath.DIRECTORY_MUSIC,
      );
    } else {
      s.downloadPath = (await getDownloadsDirectory())!.path;
    }
    s.save();
    return s;
  }

  Future save() async {
    if (preventSave) return;
    File f = File(await getPath());
    await f.writeAsString(jsonEncode(toJson()));
    await downloadManager.updateServiceSettings();
  }

  //AudioQuality to deezer int
  int getQualityInt(AudioQuality q) {
    switch (q) {
      case AudioQuality.MP3_128:
        return 1;
      case AudioQuality.MP3_320:
        return 3;
      case AudioQuality.FLAC:
        return 9;
      //Deezer default
      default:
        return 8;
    }
  }

  //Check if is dark, can't use theme directly, because of system themes, and Theme.of(context).brightness broke
  bool get isDark {
    if (theme == Themes.Light) return false;
    if (!themeHasLightVersion(theme)) return true;
    if (useSystemTheme) {
      return PlatformDispatcher.instance.platformBrightness != Brightness.light;
    }
    return darkMode;
  }

  static const deezerBg = Color(0xFF1F1A16);
  static const deezerBottom = Color(0xFF1b1714);
  TextTheme? get textTheme => (font == 'Deezer')
      ? null
      : GoogleFonts.getTextTheme(
          font,
          isDark ? ThemeData.dark().textTheme : ThemeData.light().textTheme,
        );
  String? get _fontFamily => (font == 'Deezer') ? 'MabryPro' : null;

  //Overrides for the non-deprecated buttons to look like the old ones
  OutlinedButtonThemeData get outlinedButtonTheme => OutlinedButtonThemeData(
    style: ButtonStyle(
      foregroundColor: WidgetStateProperty.all(
        isDark ? Colors.white : Colors.black,
      ),
      side: WidgetStateProperty.all(
        BorderSide(color: isDark ? Colors.grey.shade800 : Colors.grey.shade300),
      ),
    ),
  );
  TextButtonThemeData get textButtonTheme => TextButtonThemeData(
    style: ButtonStyle(
      foregroundColor: WidgetStateProperty.all(
        isDark ? Colors.white : Colors.black,
      ),
    ),
  );

  Future<String> getPath() async =>
      p.join((await getApplicationSupportDirectory()).path, 'settings.json');

  //JSON
  factory Settings.fromJson(Map<String, dynamic> json) {
    if (json['theme'] == 'Light') {
      json['theme'] = 'Dark';
      json['darkMode'] ??= false;
    }
    if (json['themeSource'] == 'materialYou') {
      json['theme'] ??= 'MaterialYou';
    } else if (json['themeSource'] == 'seed') {
      json['theme'] ??= 'MaterialYouPrimary';
    }
    return _$SettingsFromJson(json);
  }
  Map<String, dynamic> toJson() => _$SettingsToJson(this);
}

bool themeHasLightVersion(Themes theme) {
  switch (theme) {
    case Themes.Dark:
    case Themes.MaterialYou:
    case Themes.MaterialYouPrimary:
      return true;
    case Themes.Black:
    case Themes.Deezer:
      return false;
    case Themes.Light:
      return true;
  }
}

enum AudioQuality { MP3_128, MP3_320, FLAC, ASK }

enum Themes { Light, Dark, Deezer, Black, MaterialYou, MaterialYouPrimary }
