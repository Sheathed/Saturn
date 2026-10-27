import 'package:dynamic_color/dynamic_color.dart';
import 'package:material_color_utilities/material_color_utilities.dart';
import 'package:material_ui/material_ui.dart';

import '../settings.dart';

/// Fixed surface palette used by classic Saturn themes.
class _ClassicPalette {
  final Brightness brightness;
  final Color surface;
  final Color lowest;
  final Color low;
  final Color container;
  final Color high;
  final Color highest;
  final Color bottomBar;
  final Color onSurface;
  final Color onSurfaceVariant;
  final Color outline;
  final Color outlineVariant;

  const _ClassicPalette({
    required this.brightness,
    required this.surface,
    required this.lowest,
    required this.low,
    required this.container,
    required this.high,
    required this.highest,
    required this.bottomBar,
    required this.onSurface,
    required this.onSurfaceVariant,
    required this.outline,
    required this.outlineVariant,
  });

  static const light = _ClassicPalette(
    brightness: Brightness.light,
    surface: Color(0xfffafafa),
    lowest: Color(0xffffffff),
    low: Color(0xfff5f5f5),
    container: Color(0xffeeeeee),
    high: Color(0xffe0e0e0),
    highest: Color(0xffd6d6d6),
    bottomBar: Color(0xfff5f5f5),
    onSurface: Color(0xde000000),
    onSurfaceVariant: Color(0x99000000),
    outline: Color(0xff9e9e9e),
    outlineVariant: Color(0xffd0d0d0),
  );

  static const dark = _ClassicPalette(
    brightness: Brightness.dark,
    surface: Color(0xff303030),
    lowest: Color(0xff262626),
    low: Color(0xff2c2c2c),
    container: Color(0xff383838),
    high: Color(0xff424242),
    highest: Color(0xff4a4a4a),
    bottomBar: Color(0xff424242),
    onSurface: Color(0xffffffff),
    onSurfaceVariant: Color(0xb3ffffff),
    outline: Color(0xff757575),
    outlineVariant: Color(0xff494949),
  );

  static const deezer = _ClassicPalette(
    brightness: Brightness.dark,
    surface: Settings.deezerBg,
    lowest: Color(0xff171310),
    low: Settings.deezerBottom,
    container: Color(0xff261f1b),
    high: Color(0xff2d2621),
    highest: Color(0xff38302a),
    bottomBar: Settings.deezerBottom,
    onSurface: Color(0xffffffff),
    onSurfaceVariant: Color(0xb3ffffff),
    outline: Color(0xff7a706a),
    outlineVariant: Color(0xff453c36),
  );

  static const black = _ClassicPalette(
    brightness: Brightness.dark,
    surface: Color(0xff000000),
    lowest: Color(0xff000000),
    low: Color(0xff0a0a0a),
    container: Color(0xff121212),
    high: Color(0xff1a1a1a),
    highest: Color(0xff242424),
    bottomBar: Color(0xff000000),
    onSurface: Color(0xffffffff),
    onSurfaceVariant: Color(0xb3ffffff),
    outline: Color(0xff6e6e6e),
    outlineVariant: Color(0xff3a3a3a),
  );

  static _ClassicPalette of(Themes t, {bool isDark = true}) {
    switch (t) {
      case Themes.Light:
        return light;
      case Themes.Dark:
        return isDark ? dark : light;
      case Themes.Deezer:
        return deezer;
      case Themes.Black:
        return black;
      case Themes.MaterialYou:
      case Themes.MaterialYouPrimary:
        return isDark ? dark : light;
    }
  }
}

Color _on(Color c) =>
    ThemeData.estimateBrightnessForColor(c) == Brightness.dark
        ? Colors.white
        : Colors.black;

/// Builds the one and only [ThemeData] of the app.
///
/// Every widget should take its colors from `Theme.of(context)`
/// (`colorScheme`, `primaryColor`, `textTheme`) and nothing else.
class AppTheme {
  /// Adjusts [color]'s perceptual tone using Material Design's HCT color space
  /// (Hue, Chroma, Tone via [material_color_utilities]) so it is always clearly
  /// legible as text or an icon against [isDark] surfaces and tinted containers,
  /// while preserving the user's chosen hue and vibrant chroma.
  ///
  /// In HSL, colors like purple and deep blue appear much darker to human eyes
  /// than green or yellow at the same lightness value. Material Design's HCT Tone
  /// directly maps to perceptual luminance (L*). Material 3 specifies Tone 80–90
  /// for dark mode foreground elements to ensure WCAG AA/AAA contrast ratios (>= 7:1).
  static Color legibleAccent(Color color, {required bool isDark}) {
    final hct = Hct.fromInt(color.toARGB32());
    if (isDark) {
      if (hct.tone < 82.0) {
        return Color(Hct.from(hct.hue, hct.chroma, 84.0).toInt());
      }
      return color;
    } else {
      if (hct.tone > 38.0) {
        return Color(Hct.from(hct.hue, hct.chroma, 34.0).toInt());
      }
      return color;
    }
  }

  /// Resolve the brightness of [theme] (taking the system setting into account).
  static Themes resolveTheme(Themes theme, {required bool useSystemTheme}) {
    return theme;
  }

  static ColorScheme buildColorScheme({
    required Themes theme,
    required Color primary,
    required bool isDark,
    ColorScheme? dynamicLight,
    ColorScheme? dynamicDark,
  }) {
    switch (theme) {
      case Themes.Light:
      case Themes.Dark:
      case Themes.Deezer:
      case Themes.Black:
        final palette = _ClassicPalette.of(theme, isDark: isDark);
        final base = ColorScheme.fromSeed(
          seedColor: primary,
          brightness: palette.brightness,
        );
        return base.copyWith(
          primary: primary,
          onPrimary: _on(primary),
          surface: palette.surface,
          onSurface: palette.onSurface,
          onSurfaceVariant: palette.onSurfaceVariant,
          surfaceContainerLowest: palette.lowest,
          surfaceContainerLow: palette.low,
          surfaceContainer: palette.container,
          surfaceContainerHigh: palette.high,
          surfaceContainerHighest: palette.highest,
          surfaceTint: Colors.transparent,
          outline: palette.outline,
          outlineVariant: palette.outlineVariant,
        );

      case Themes.MaterialYou:
        final dyn = isDark ? dynamicDark : dynamicLight;
        if (dyn != null) {
          return dyn.harmonized();
        }
        return ColorScheme.fromSeed(
          seedColor: primary,
          brightness: isDark ? Brightness.dark : Brightness.light,
        );

      case Themes.MaterialYouPrimary:
        return ColorScheme.fromSeed(
          seedColor: primary,
          brightness: isDark ? Brightness.dark : Brightness.light,
        );
    }
  }

  static ThemeData build({
    required Themes theme,
    required Color primary,
    required bool isDark,
    required TextTheme? textTheme,
    required String? fontFamily,
    required OutlinedButtonThemeData outlinedButtonTheme,
    required TextButtonThemeData textButtonTheme,
    ColorScheme? dynamicLight,
    ColorScheme? dynamicDark,
  }) {
    final scheme = buildColorScheme(
      theme: theme,
      primary: primary,
      isDark: isDark,
      dynamicLight: dynamicLight,
      dynamicDark: dynamicDark,
    );
    final accent = scheme.primary;

    WidgetStateProperty<Color?> accentWhenSelected() =>
        WidgetStateProperty.resolveWith<Color?>((states) {
          if (states.contains(WidgetState.disabled)) return null;
          if (states.contains(WidgetState.selected)) return accent;
          return null;
        });

    final isClassic = theme == Themes.Light ||
        theme == Themes.Dark ||
        theme == Themes.Deezer ||
        theme == Themes.Black;

    return ThemeData(
      useMaterial3: true,
      brightness: scheme.brightness,
      colorScheme: scheme,
      textTheme: textTheme,
      fontFamily: fontFamily,
      primaryColor: accent,
      scaffoldBackgroundColor: scheme.surface,
      canvasColor: scheme.surface,
      cardColor: scheme.surfaceContainer,
      dialogTheme: DialogThemeData(backgroundColor: scheme.surfaceContainerHigh),
      popupMenuTheme: PopupMenuThemeData(color: scheme.surfaceContainerHigh),
      sliderTheme: SliderThemeData(),
      outlinedButtonTheme: outlinedButtonTheme,
      textButtonTheme: textButtonTheme,
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
      ),
      checkboxTheme: CheckboxThemeData(fillColor: accentWhenSelected()),
      radioTheme: RadioThemeData(fillColor: accentWhenSelected()),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith<Color?>((states) {
          if (states.contains(WidgetState.disabled)) return null;
          if (states.contains(WidgetState.selected)) return scheme.onPrimary;
          return null;
        }),
        trackColor: accentWhenSelected(),
      ),
      bottomAppBarTheme: BottomAppBarThemeData(
        color: isClassic
            ? _ClassicPalette.of(theme, isDark: isDark).bottomBar
            : scheme.surfaceContainer,
      ),
    );
  }
}
