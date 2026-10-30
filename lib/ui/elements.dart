import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'package:saturn/platform/music_platform.dart';
import 'package:saturn/platform/platform_manager.dart';
import 'package:saturn/platform/platform_registry.dart';
import '../utils/update_service.dart';
import '../translations.i18n.dart';

import '../settings.dart';

class LeadingIcon extends StatelessWidget {
  final IconData icon;
  final Color? color;
  const LeadingIcon(this.icon, {super.key, this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 42.0,
      height: 42.0,
      decoration: BoxDecoration(
        color: (color ?? Theme.of(context).primaryColor).withValues(alpha: 1.0),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, color: Colors.white),
    );
  }
}

class UpdateAwareSettingsIcon extends StatelessWidget {
  final double size;

  const UpdateAwareSettingsIcon({super.key, this.size = 24});

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: UpdateService.instance,
    builder: (context, child) => Stack(
      clipBehavior: Clip.none,
      children: [
        Icon(Icons.settings, size: size, semanticLabel: 'Settings'.i18n),
        if (UpdateService.instance.updateAvailable)
          Positioned(
            right: -2,
            top: -2,
            child: Container(
              width: size * 0.38,
              height: size * 0.38,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.error,
                shape: BoxShape.circle,
                border: Border.all(
                  color: Theme.of(context).colorScheme.surface,
                  width: 1.5,
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

//Container with set size to match LeadingIcon
class EmptyLeading extends StatelessWidget {
  const EmptyLeading({super.key});

  @override
  Widget build(BuildContext context) {
    return const SizedBox(width: 42.0, height: 42.0);
  }
}

class ScrollUnderScope extends InheritedWidget {
  final bool scrolledUnder;
  final VoidCallback? onReset;

  const ScrollUnderScope({
    required this.scrolledUnder,
    this.onReset,
    required super.child,
    super.key,
  });

  static ScrollUnderScope? _scopeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ScrollUnderScope>();

  static bool? maybeOf(BuildContext context) =>
      _scopeOf(context)?.scrolledUnder;

  static void reset(BuildContext context) {
    final scope =
        context
                .getElementForInheritedWidgetOfExactType<ScrollUnderScope>()
                ?.widget
            as ScrollUnderScope?;
    scope?.onReset?.call();
  }

  @override
  bool updateShouldNotify(ScrollUnderScope oldWidget) =>
      scrolledUnder != oldWidget.scrolledUnder;
}

class FreezerAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final List<Widget> actions;
  final Widget? bottom;
  final double height;
  final bool enableBlur;
  final double opacity;
  final double blurStrength;

  const FreezerAppBar(
    this.title, {
    super.key,
    this.actions = const [],
    this.bottom,
    this.height = 56.0,
    this.enableBlur = false, // Defaults to no blur
    this.opacity = 0, // Defaults to fully opaque
    this.blurStrength = 0, // Defaults to a standard blur level
  });

  @override
  Size get preferredSize => Size.fromHeight(height);

  @override
  Widget build(BuildContext context) {
    final scopedScrollState = ScrollUnderScope.maybeOf(context);
    final hasScopedDesktopScrollState =
        !enableBlur &&
        MediaQuery.sizeOf(context).width >= 600 &&
        scopedScrollState != null;
    final Color appBarBackground;
    if (enableBlur || MediaQuery.sizeOf(context).width < 600) {
      appBarBackground = Theme.of(
        context,
      ).scaffoldBackgroundColor.withValues(alpha: opacity);
    } else if (hasScopedDesktopScrollState) {
      appBarBackground = Colors.transparent;
    } else {
      appBarBackground = WidgetStateColor.resolveWith((states) {
        return states.contains(WidgetState.scrolledUnder)
            ? Theme.of(context).colorScheme.surfaceContainerLow
            : Theme.of(context).scaffoldBackgroundColor;
      });
    }

    return Stack(
      children: [
        if (hasScopedDesktopScrollState)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: kToolbarHeight,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.linear,
              color: scopedScrollState
                  ? Theme.of(context).colorScheme.surfaceContainerLow
                  : Theme.of(context).scaffoldBackgroundColor,
            ),
          ),
        if (enableBlur)
          ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(
                sigmaX: blurStrength,
                sigmaY: blurStrength,
              ),
              child: Container(
                color: Theme.of(
                  context,
                ).scaffoldBackgroundColor.withValues(alpha: opacity),
              ),
            ),
          ),
        AppBar(
          systemOverlayStyle: SystemUiOverlayStyle(
            statusBarBrightness: Theme.of(context).brightness,
          ),
          elevation: 0.0,
          backgroundColor: appBarBackground,
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: 0,
          foregroundColor: (Theme.of(context).brightness == Brightness.light)
              ? Colors.black
              : Colors.white,
          title: Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w900),
          ),
          actions: actions,
          bottom: bottom as PreferredSizeWidget?,
        ),
      ],
    );
  }
}

class FreezerDivider extends StatelessWidget {
  const FreezerDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return const Divider(thickness: 1.5, indent: 16.0, endIndent: 16.0);
  }
}

TextStyle popupMenuTextStyle() {
  return TextStyle(color: settings.isDark ? Colors.white : Colors.black);
}

class PlatformToggleIcon extends StatelessWidget {
  const PlatformToggleIcon({super.key});

  static List<MusicPlatform>? _lastKnownLoggedInPlatforms;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.of(context).size.width >= 600) {
      return const SizedBox.shrink();
    }

    return ListenableBuilder(
      listenable: PlatformManager.instance,
      builder: (context, _) {
        return FutureBuilder<List<MusicPlatform>>(
          future: PlatformRegistry.instance.loggedInPlatforms,
          initialData: _lastKnownLoggedInPlatforms,
          builder: (context, snapshot) {
            final resolvedPlatforms = snapshot.data;
            if (resolvedPlatforms != null) {
              _lastKnownLoggedInPlatforms = resolvedPlatforms;
            }
            final platforms =
                resolvedPlatforms ?? _lastKnownLoggedInPlatforms ?? const [];
            if (platforms.length <= 1) return const SizedBox.shrink();

            final activeId = PlatformManager.instance.activePlatformId;
            final activePlatform = platforms.firstWhere(
              (p) => p.platformId == activeId,
              orElse: () => platforms.first,
            );

            return IconButton(
              icon: activePlatform.buildPlatformIcon(),
              tooltip: 'Switch Platform',
              onPressed: () async {
                final currentIndex = platforms.indexWhere(
                  (p) => p.platformId == activeId,
                );
                final nextIndex = (currentIndex + 1) % platforms.length;
                final newId = platforms[nextIndex].platformId;

                await selectPlatform(newId);
              },
            );
          },
        );
      },
    );
  }
}

Future<void> selectPlatform(String platformId) async {
  if (PlatformManager.instance.activePlatformId == platformId) return;

  PlatformManager.instance.switchPlatform(platformId);
  settings.activePlatformId = platformId;
  await settings.save();
}
