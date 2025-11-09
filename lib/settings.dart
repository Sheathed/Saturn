import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:external_path/external_path.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'api/download.dart';
import 'main.dart';
import 'service/audio_service.dart';
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

  //Account
  String? arl;
  @JsonKey(includeFromJson: false)
  @JsonKey(includeToJson: false)
  bool offlineMode = false;

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
  @JsonKey(defaultValue: Themes.Dark)
  late Themes theme;
  @JsonKey(defaultValue: false)
  late bool useSystemTheme;
  @JsonKey(defaultValue: true)
  late bool colorGradientBackground;
  @JsonKey(defaultValue: false)
  late bool blurPlayerBackground;
  @JsonKey(defaultValue: false)
  late bool themeAdditonalItems;
  @JsonKey(defaultValue: 'Deezer')
  late String font;
  @JsonKey(defaultValue: false)
  late bool lyricsVisualizer;
  @JsonKey(defaultValue: false)
  late bool keepSidebarOpen;
  @JsonKey(defaultValue: false)
  late bool keepSidebarClosed;
  @JsonKey(defaultValue: null)
  int? displayMode;

  //Colors
  @JsonKey(toJson: _colorToJson, fromJson: _colorFromJson)
  Color primaryColor = Colors.blue;

  static int _colorToJson(Color c) => c.toARGB32();
  static Color _colorFromJson(int? v) => v == null ? Colors.blue : Color(v);

  @JsonKey(defaultValue: false)
  bool useArtColor = false;
  StreamSubscription? _useArtColorSub;

  //Deezer
  @JsonKey(defaultValue: 'en')
  late String deezerLanguage;
  @JsonKey(defaultValue: 'US')
  late String deezerCountry;
  @JsonKey(defaultValue: false)
  late bool logListen;
  @JsonKey(defaultValue: null)
  String? proxyAddress;

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

  Settings({this.downloadPath, this.arl});

  // List of rainbow colors
  static const List<Color> _rainbowColors = [
    Color(0xFFF44336),
    Color(0xFFE91E63),
    Color(0xFF9C27B0),
    Color(0xFF673AB7),
    Color(0xFF3F51B5),
    Color(0xFF2196F3),
    Color(0xFF03A9F4),
    Color(0xFF00BCD4),
    Color(0xFF009688),
    Color(0xFF4CAF50),
    Color(0xFF8BC34A),
    Color(0xFFCDDC39),
    Color(0xFFFFEB3B),
    Color(0xFFFFC107),
    Color(0xFFFF9800),
    Color(0xFFFF5722),
    Color(0xFF795548),
    Color(0xFF607D8B),
    Color(0xFF9E9E9E),
  ];

  late Timer _rainbowColorTimer = Timer(Duration.zero, () {});
  int _currentColorIndex = 0;

  // Method to start cycling rainbow colors
  void startRainbowColorUpdates() {
    if (_rainbowColorTimer.isActive) {
      _rainbowColorTimer.cancel();
    }
    _rainbowColorTimer = Timer.periodic(const Duration(milliseconds: 300), (
      timer,
    ) {
      primaryColor = _rainbowColors[_currentColorIndex];
      _currentColorIndex = (_currentColorIndex + 1) % _rainbowColors.length;
      updateTheme(); // Make sure this method updates the app theme with the new primary color
    });
  }

  // Method to stop cycling rainbow colors
  void stopRainbowColorUpdates() {
    if (_rainbowColorTimer.isActive) {
      _rainbowColorTimer.cancel();
    }
  }

  ThemeData get themeData {
    //System theme
    if (useSystemTheme) {
      if (PlatformDispatcher.instance.platformBrightness == Brightness.light) {
        return _themeData[Themes.Light]!;
      } else {
        if (theme == Themes.Light) return _themeData[Themes.Dark]!;
        return _themeData[theme]!;
      }
    }
    //Theme
    return _themeData[theme] ?? ThemeData();
  }

  //Get all available fonts
  List<String> get fonts {
    return ['Deezer', ...GoogleFonts.asMap().keys];
  }

  //JSON to forward into download service
  Map getServiceSettings() {
    return {'json': jsonEncode(toJson())};
  }

  void updateUseArtColor(bool v) {
    useArtColor = v;
    if (v) {
      //On media item change set color
      _useArtColorSub = GetIt.I<AudioPlayerHandler>().mediaItem.listen((
        event,
      ) async {
        if (event == null || event.artUri == null) return;
        primaryColor = await imagesDatabase.getPrimaryColor(
          event.artUri.toString(),
        );
        updateTheme();
      });
    } else {
      //Cancel stream subscription
      _useArtColorSub?.cancel();
      _useArtColorSub = null;
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
    if (useSystemTheme) {
      if (PlatformDispatcher.instance.platformBrightness == Brightness.light) {
        return false;
      }
      return true;
    }
    if (theme == Themes.Light) return false;
    return true;
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
      side: WidgetStateProperty.all(BorderSide(color: Colors.grey.shade800)),
    ),
  );
  TextButtonThemeData get textButtonTheme => TextButtonThemeData(
    style: ButtonStyle(
      foregroundColor: WidgetStateProperty.all(
        isDark ? Colors.white : Colors.black,
      ),
    ),
  );

  Map<Themes, ThemeData> get _themeData => {
    Themes.Light: ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      textTheme: textTheme,
      fontFamily: _fontFamily,
      primaryColor: primaryColor,
      sliderTheme: SliderThemeData(),
      outlinedButtonTheme: outlinedButtonTheme,
      textButtonTheme: textButtonTheme,
      colorScheme: ColorScheme.fromSeed(
        seedColor: primaryColor,
        brightness: Brightness.light,
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith<Color?>((
          Set<WidgetState> states,
        ) {
          if (states.contains(WidgetState.disabled)) {
            return null;
          }
          if (states.contains(WidgetState.selected)) {
            return primaryColor;
          }
          return null;
        }),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith<Color?>((
          Set<WidgetState> states,
        ) {
          if (states.contains(WidgetState.disabled)) {
            return null;
          }
          if (states.contains(WidgetState.selected)) {
            return primaryColor;
          }
          return null;
        }),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith<Color?>((
          Set<WidgetState> states,
        ) {
          if (states.contains(WidgetState.disabled)) {
            return null;
          }
          if (states.contains(WidgetState.selected)) {
            return primaryColor;
          }
          return null;
        }),
        trackColor: WidgetStateProperty.resolveWith<Color?>((
          Set<WidgetState> states,
        ) {
          if (states.contains(WidgetState.disabled)) {
            return null;
          }
          if (states.contains(WidgetState.selected)) {
            return primaryColor;
          }
          return null;
        }),
      ),
      bottomAppBarTheme: const BottomAppBarThemeData(color: Color(0xfff5f5f5)),
    ),
    Themes.Dark: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      textTheme: textTheme,
      fontFamily: _fontFamily,
      primaryColor: primaryColor,
      sliderTheme: SliderThemeData(),
      outlinedButtonTheme: outlinedButtonTheme,
      textButtonTheme: textButtonTheme,
      colorScheme: ColorScheme.fromSeed(
        seedColor: primaryColor,
        brightness: Brightness.dark,
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith<Color?>((
          Set<WidgetState> states,
        ) {
          if (states.contains(WidgetState.disabled)) {
            return null;
          }
          if (states.contains(WidgetState.selected)) {
            return primaryColor;
          }
          return null;
        }),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith<Color?>((
          Set<WidgetState> states,
        ) {
          if (states.contains(WidgetState.disabled)) {
            return null;
          }
          if (states.contains(WidgetState.selected)) {
            return primaryColor;
          }
          return null;
        }),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith<Color?>((
          Set<WidgetState> states,
        ) {
          if (states.contains(WidgetState.disabled)) {
            return null;
          }
          if (states.contains(WidgetState.selected)) {
            return primaryColor;
          }
          return null;
        }),
        trackColor: WidgetStateProperty.resolveWith<Color?>((
          Set<WidgetState> states,
        ) {
          if (states.contains(WidgetState.disabled)) {
            return null;
          }
          if (states.contains(WidgetState.selected)) {
            return primaryColor;
          }
          return null;
        }),
      ),
      bottomAppBarTheme: const BottomAppBarThemeData(color: Color(0xff424242)),
    ),
    Themes.Deezer: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      textTheme: textTheme,
      fontFamily: _fontFamily,
      primaryColor: primaryColor,
      sliderTheme: SliderThemeData(),
      scaffoldBackgroundColor: deezerBg,
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: deezerBottom,
      ),
      cardColor: deezerBg,
      outlinedButtonTheme: outlinedButtonTheme,
      textButtonTheme: textButtonTheme,
      colorScheme: ColorScheme.fromSeed(
        seedColor: primaryColor,
        brightness: Brightness.dark,
      ).copyWith(surface: deezerBg),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith<Color?>((
          Set<WidgetState> states,
        ) {
          if (states.contains(WidgetState.disabled)) {
            return null;
          }
          if (states.contains(WidgetState.selected)) {
            return primaryColor;
          }
          return null;
        }),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith<Color?>((
          Set<WidgetState> states,
        ) {
          if (states.contains(WidgetState.disabled)) {
            return null;
          }
          if (states.contains(WidgetState.selected)) {
            return primaryColor;
          }
          return null;
        }),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith<Color?>((
          Set<WidgetState> states,
        ) {
          if (states.contains(WidgetState.disabled)) {
            return null;
          }
          if (states.contains(WidgetState.selected)) {
            return primaryColor;
          }
          return null;
        }),
        trackColor: WidgetStateProperty.resolveWith<Color?>((
          Set<WidgetState> states,
        ) {
          if (states.contains(WidgetState.disabled)) {
            return null;
          }
          if (states.contains(WidgetState.selected)) {
            return primaryColor;
          }
          return null;
        }),
      ),
      bottomAppBarTheme: const BottomAppBarThemeData(color: deezerBottom),
    ),
    Themes.Black: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      textTheme: textTheme,
      fontFamily: _fontFamily,
      primaryColor: primaryColor,
      scaffoldBackgroundColor: Colors.black,
      sliderTheme: SliderThemeData(),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Colors.black,
      ),
      outlinedButtonTheme: outlinedButtonTheme,
      textButtonTheme: textButtonTheme,
      colorScheme: ColorScheme.fromSeed(
        seedColor: primaryColor,
        brightness: Brightness.dark,
      ).copyWith(surface: Colors.black),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith<Color?>((
          Set<WidgetState> states,
        ) {
          if (states.contains(WidgetState.disabled)) {
            return null;
          }
          if (states.contains(WidgetState.selected)) {
            return primaryColor;
          }
          return null;
        }),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith<Color?>((
          Set<WidgetState> states,
        ) {
          if (states.contains(WidgetState.disabled)) {
            return null;
          }
          if (states.contains(WidgetState.selected)) {
            return primaryColor;
          }
          return null;
        }),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith<Color?>((
          Set<WidgetState> states,
        ) {
          if (states.contains(WidgetState.disabled)) {
            return null;
          }
          if (states.contains(WidgetState.selected)) {
            return primaryColor;
          }
          return null;
        }),
        trackColor: WidgetStateProperty.resolveWith<Color?>((
          Set<WidgetState> states,
        ) {
          if (states.contains(WidgetState.disabled)) {
            return null;
          }
          if (states.contains(WidgetState.selected)) {
            return primaryColor;
          }
          return null;
        }),
      ),
      bottomAppBarTheme: const BottomAppBarThemeData(color: Colors.black),
    ),
  };

  Future<String> getPath() async =>
      p.join((await getApplicationSupportDirectory()).path, 'settings.json');

  //JSON
  factory Settings.fromJson(Map<String, dynamic> json) =>
      _$SettingsFromJson(json);
  Map<String, dynamic> toJson() => _$SettingsToJson(this);
}

enum AudioQuality { MP3_128, MP3_320, FLAC, ASK }

enum Themes { Light, Dark, Deezer, Black }
