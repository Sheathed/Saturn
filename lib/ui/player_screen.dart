import 'package:saturn/platform/platform_manager.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:get_it/get_it.dart';
import 'package:just_audio/just_audio.dart';
import 'package:marquee/marquee.dart';
import 'package:rxdart/rxdart.dart';
import 'package:silky_scroll/silky_scroll.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../api/cache.dart';
import '../api/definitions.dart';
import '../api/download.dart';
import '../router/app_router.dart';

import '../service/audio_service.dart';
import '../settings.dart';
import '../translations.i18n.dart';
import 'app_theme.dart';
import 'cached_image.dart';
import 'elements.dart';
import 'toast.dart';
import 'lyrics.dart';
import 'menu.dart';
import 'player_bar.dart';
import 'router.dart';
import 'settings_screen.dart';
import 'smooth_scroll_config.dart';
import 'tiles.dart';
import '../utils/logging.dart';
import '../utils/seasonal_track_matcher.dart';

bool _queueHasMixedPlatforms(Iterable<MediaItem> items) =>
    items
        .map((item) => item.extras?['platformId'] as String? ?? 'deezer')
        .where((platformId) => platformId.isNotEmpty)
        .toSet()
        .length >
    1;

String _playbackSourceLabel(MediaItem item) {
  final source = item.extras?['source']?.toString().toLowerCase();
  final streamUrl = Uri.tryParse(item.extras?['streamUrl']?.toString() ?? '');
  return source == 'offline' || streamUrl?.scheme.toLowerCase() == 'file'
      ? 'Offline'.i18n
      : 'Stream'.i18n;
}

class _SeasonalPlayerEffects extends StatefulWidget {
  final SeasonalTrackEffect? season;

  const _SeasonalPlayerEffects({required this.season});

  @override
  State<_SeasonalPlayerEffects> createState() => _SeasonalPlayerEffectsState();
}

class _SeasonalPlayerEffectsState extends State<_SeasonalPlayerEffects>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation;
  final Stopwatch _clock = Stopwatch();

  @override
  void initState() {
    super.initState();
    _animation = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
    if (widget.season != null) _startEffectClock();
  }

  @override
  void didUpdateWidget(covariant _SeasonalPlayerEffects oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.season == null && widget.season != null) {
      _startEffectClock();
    } else if (widget.season == null && oldWidget.season != null) {
      _stopEffectClock();
    }
  }

  void _startEffectClock() {
    _clock.start();
    if (!_animation.isAnimating) _animation.repeat();
  }

  void _stopEffectClock() {
    _animation.stop();
    _clock
      ..stop()
      ..reset();
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: AnimatedBuilder(
      animation: _animation,
      builder: (context, _) => CustomPaint(
        painter: _SeasonalEffectsPainter(
          season: widget.season,
          timeSeconds: _clock.elapsedMicroseconds / 1000000,
        ),
        size: Size.infinite,
      ),
    ),
  );
}

class _SeasonalEffectsPainter extends CustomPainter {
  final SeasonalTrackEffect? season;
  final double timeSeconds;

  const _SeasonalEffectsPainter({
    required this.season,
    required this.timeSeconds,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    if (season == null) return;
    if (season == SeasonalTrackEffect.christmas) {
      _drawGlow(
        canvas,
        size,
        Offset(size.width * 0.08, size.height * 0.14),
        const Color(0xFFB72E39),
        0.12,
      );
      _drawGlow(
        canvas,
        size,
        Offset(size.width * 0.92, size.height * 0.18),
        const Color(0xFF2C9B62),
        0.12,
      );

      final snowPaint = Paint()
        ..color = Colors.white.withValues(alpha: 0.34)
        ..strokeWidth = 1.35
        ..strokeCap = StrokeCap.round;
      final snowCount = (size.width / 14).ceil().clamp(24, 96).toInt();
      for (var i = 0; i < snowCount; i++) {
        final random = math.Random(0x51A0 + i * 104729);
        final xSeed = random.nextDouble();
        final ySeed = random.nextDouble();
        final swayPhase = random.nextDouble() * math.pi * 2;
        final swayAmplitude = 10 + random.nextDouble() * 16;
        final fallDuration = 13 + random.nextDouble() * 17;
        final radius = 1.4 + random.nextDouble() * 3.0;
        const verticalMargin = 12.0;
        final fallDistance = size.height + verticalMargin * 2;
        final sway = math.sin(timeSeconds * 0.7 + swayPhase) * swayAmplitude;
        final x = i * 14.0 + xSeed * 14.0 + sway;
        final y =
            ((ySeed + timeSeconds / fallDuration) % 1).toDouble() *
                fallDistance -
            verticalMargin;
        canvas.drawCircle(Offset(x, y), radius, snowPaint);
        if (random.nextDouble() < 0.2) {
          _drawSnowflake(canvas, Offset(x, y), radius * 1.7, snowPaint);
        }
      }

      // Run one continuous strand across the full player, including mobile.
      _drawFairyLights(canvas, size);
      return;
    }

    _drawGlow(
      canvas,
      size,
      Offset(size.width * 0.10, size.height * 0.83),
      const Color(0xFFFF6B25),
      0.16,
    );
    _drawGlow(
      canvas,
      size,
      Offset(size.width * 0.91, size.height * 0.26),
      const Color(0xFF7650A8),
      0.14,
    );
    final moonCenter = Offset(size.width * 0.90, size.height * 0.17);
    // Draw a single crescent silhouette. Avoid an even-odd cutout: it can
    // blend into the album art and read as a broken dark disk.
    const moonRadius = 35.0;
    final moon = Path()
      ..moveTo(moonCenter.dx + 12, moonCenter.dy - moonRadius)
      ..cubicTo(
        moonCenter.dx - 34,
        moonCenter.dy - 30,
        moonCenter.dx - 37,
        moonCenter.dy + 28,
        moonCenter.dx + 12,
        moonCenter.dy + moonRadius,
      )
      ..cubicTo(
        moonCenter.dx - 5,
        moonCenter.dy + 13,
        moonCenter.dx - 5,
        moonCenter.dy - 13,
        moonCenter.dx + 12,
        moonCenter.dy - moonRadius,
      )
      ..close();
    canvas.drawPath(
      moon,
      Paint()..color = const Color(0xFFFFD79A).withValues(alpha: 0.18),
    );
    _drawCobweb(canvas, const Offset(0, 0), 116, flipX: false);
    _drawCobweb(canvas, Offset(size.width, 0), 100, flipX: true);

    final batPaint = Paint()
      ..color = const Color(0xFF1A1022).withValues(alpha: 0.48)
      ..style = PaintingStyle.fill;
    final emberPaint = Paint()
      ..color = const Color(0xFFFFA54A).withValues(alpha: 0.42);
    final count = (size.width / 45).ceil().clamp(10, 48).toInt();
    for (var i = 0; i < count; i++) {
      final random = math.Random(0xA110 + i * 104729);
      final xSeed = random.nextDouble();
      final ySeed = random.nextDouble();
      final swayPhase = random.nextDouble() * math.pi * 2;
      final swayAmplitude = 24 + random.nextDouble() * 36;
      final fallDuration = 12 + random.nextDouble() * 18;
      final kind = random.nextDouble();
      final scale = 0.62 + random.nextDouble() * 0.55;
      const verticalMargin = 40.0;
      final fallDistance = size.height + verticalMargin * 2;
      final x =
          i * 45.0 +
          xSeed * 45.0 +
          math.sin(timeSeconds * 0.62 + swayPhase) * swayAmplitude;
      final y =
          ((ySeed + timeSeconds / fallDuration) % 1).toDouble() * fallDistance -
          verticalMargin;
      if (i != 0 && kind < 0.14) {
        final pulse = 0.7 + 0.3 * math.sin(timeSeconds * 1.2 + i * 13.7);
        canvas.drawCircle(
          Offset(x, y),
          (1.7 + random.nextDouble() * 2) * pulse,
          emberPaint,
        );
        continue;
      }
      canvas.save();
      canvas.translate(x, y);
      canvas.scale(scale * (0.9 + 0.1 * math.sin(timeSeconds * 0.8 + i * 9.1)));
      if (i == 0 || kind < 0.42) {
        _drawJackOLantern(canvas);
      } else {
        _drawBat(canvas, batPaint);
      }
      canvas.restore();
    }
  }

  void _drawGlow(
    Canvas canvas,
    Size size,
    Offset center,
    Color color,
    double alpha,
  ) {
    final bounds = Rect.fromCircle(
      center: center,
      radius: size.shortestSide * 0.42,
    );
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = RadialGradient(
          colors: [
            color.withValues(alpha: alpha),
            color.withValues(alpha: 0),
          ],
        ).createShader(bounds),
    );
  }

  void _drawSnowflake(
    Canvas canvas,
    Offset center,
    double radius,
    Paint paint,
  ) {
    for (var arm = 0; arm < 6; arm++) {
      final angle = arm * math.pi / 3;
      final direction = Offset(math.cos(angle), math.sin(angle));
      final end = center + direction * radius;
      canvas.drawLine(center, end, paint);
      final branch = center + direction * radius * 0.58;
      for (final side in [-1, 1]) {
        final branchAngle = angle + side * math.pi / 3;
        final branchEnd =
            branch +
            Offset(math.cos(branchAngle), math.sin(branchAngle)) *
                radius *
                0.24;
        canvas.drawLine(branch, branchEnd, paint);
      }
    }
  }

  void _drawFairyLights(Canvas canvas, Size size) {
    final droopCount = (size.width / 430).ceil().clamp(1, 7).toInt();
    final bulbCount = (size.width / 82).round().clamp(5, 28).toInt();
    final segmentWidth = size.width / droopCount;
    final sag = (segmentWidth * 0.075).clamp(15.0, 32.0).toDouble();
    const wireTop = 2.0;
    final wire = Path()..moveTo(0, wireTop);
    for (var droop = 0; droop < droopCount; droop++) {
      final x0 = segmentWidth * droop;
      final x1 = segmentWidth * (droop + 1);
      wire.cubicTo(
        x0 + segmentWidth * 0.25,
        wireTop + sag,
        x0 + segmentWidth * 0.75,
        wireTop + sag,
        x1,
        wireTop,
      );
    }
    canvas.drawPath(
      wire,
      Paint()
        ..color = const Color(0xFF52705B).withValues(alpha: 0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true,
    );
    const colors = [
      Color(0xFFFF626B),
      Color(0xFFFFD166),
      Color(0xFF73D99A),
      Color(0xFF74C9FF),
    ];
    for (var i = 0; i < bulbCount; i++) {
      final t = (i + 0.5) / bulbCount;
      final segmentPosition = t * droopCount;
      final segment = math.min(segmentPosition.floor(), droopCount - 1).toInt();
      final localT = segmentPosition - segment;
      final inverseT = 1 - localT;
      final x0 = segmentWidth * segment;
      final x1 = segmentWidth * (segment + 1);
      final x =
          inverseT * inverseT * inverseT * x0 +
          3 * inverseT * inverseT * localT * (x0 + segmentWidth * 0.25) +
          3 * inverseT * localT * localT * (x0 + segmentWidth * 0.75) +
          localT * localT * localT * x1;
      final y =
          inverseT * inverseT * inverseT * wireTop +
          3 * inverseT * inverseT * localT * (wireTop + sag) +
          3 * inverseT * localT * localT * (wireTop + sag) +
          localT * localT * localT * wireTop;
      // Alternate neighboring bulbs in pairs of opposing fades. Eight cycles
      // per animation loop keeps the lights lively without a sharp blink.
      final phaseOffset = i.isEven ? 0.0 : math.pi;
      final phase = (math.sin(timeSeconds * 5.2 + phaseOffset) + 1) / 2;
      final twinkle = 0.12 + 0.88 * phase * phase;
      final color = colors[i % colors.length];
      final glowBounds = Rect.fromCircle(
        center: Offset(x, y + 7),
        radius: 18 * twinkle,
      );
      canvas.drawRect(
        glowBounds,
        Paint()
          ..isAntiAlias = true
          ..shader = RadialGradient(
            colors: [
              color.withValues(alpha: 0.42 * twinkle),
              color.withValues(alpha: 0.14 * twinkle),
              color.withValues(alpha: 0),
            ],
            stops: const [0, 0.38, 1],
          ).createShader(glowBounds),
      );
      // Socket straddles the wire; the rounded bulb hangs below it.
      final socket = RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(x, y + 1.5), width: 7, height: 6),
        const Radius.circular(2),
      );
      canvas.drawRRect(
        socket,
        Paint()
          ..isAntiAlias = true
          ..color = const Color(0xFF9A9A78),
      );
      final bulbPath = Path()
        ..moveTo(x - 4.2, y + 3)
        ..quadraticBezierTo(x - 6.2, y + 8, x, y + 16)
        ..quadraticBezierTo(x + 6.2, y + 8, x + 4.2, y + 3)
        ..close();
      canvas.drawPath(
        bulbPath,
        Paint()
          ..isAntiAlias = true
          ..color = color.withValues(alpha: 0.35 + 0.65 * twinkle),
      );
      canvas.drawOval(
        Rect.fromCenter(center: Offset(x - 1.4, y + 7), width: 2.2, height: 5),
        Paint()
          ..isAntiAlias = true
          ..color = Colors.white.withValues(alpha: 0.18 + 0.48 * twinkle),
      );
    }
  }

  void _drawCobweb(
    Canvas canvas,
    Offset corner,
    double radius, {
    required bool flipX,
  }) {
    final sign = flipX ? -1.0 : 1.0;
    final paint = Paint()
      ..color = const Color(0xFFE6D8EE).withValues(alpha: 0.28)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1;
    for (var ray = 0; ray <= 5; ray++) {
      final angle = ray * math.pi / 10;
      canvas.drawLine(
        corner,
        corner +
            Offset(math.cos(angle) * radius * sign, math.sin(angle) * radius),
        paint,
      );
    }
    for (var ring = 1; ring <= 4; ring++) {
      final r = radius * ring / 4;
      final path = Path();
      for (var ray = 0; ray <= 5; ray++) {
        final angle = ray * math.pi / 10;
        final point =
            corner + Offset(math.cos(angle) * r * sign, math.sin(angle) * r);
        if (ray == 0) {
          path.moveTo(point.dx, point.dy);
        } else {
          path.quadraticBezierTo(
            corner.dx + math.cos(angle - math.pi / 20) * r * 0.92 * sign,
            corner.dy + math.sin(angle - math.pi / 20) * r * 0.92,
            point.dx,
            point.dy,
          );
        }
      }
      canvas.drawPath(path, paint);
    }
  }

  void _drawBat(Canvas canvas, Paint paint) {
    final bat = Path()
      ..moveTo(-19, -1)
      ..quadraticBezierTo(-13, -12, -4, -5)
      ..lineTo(-1, -9)
      ..lineTo(0, -3)
      ..lineTo(1, -9)
      ..lineTo(4, -5)
      ..quadraticBezierTo(13, -12, 19, -1)
      ..lineTo(10, 7)
      ..lineTo(4, 4)
      ..lineTo(0, 10)
      ..lineTo(-4, 4)
      ..lineTo(-10, 7)
      ..close();
    canvas.drawPath(bat, paint);
  }

  void _drawJackOLantern(Canvas canvas) {
    // The ribbed silhouette and bright carved face read clearly at the same
    // small scale as the bats while drifting down the player background.
    final body = RRect.fromRectAndRadius(
      const Rect.fromLTWH(-17, -12, 34, 25),
      const Radius.circular(12),
    );
    canvas.drawOval(
      const Rect.fromLTWH(-19, -10, 15, 22),
      Paint()..color = const Color(0xFFB94B13),
    );
    canvas.drawOval(
      const Rect.fromLTWH(4, -10, 15, 22),
      Paint()..color = const Color(0xFFB94B13),
    );
    canvas.drawRRect(
      body,
      Paint()
        ..shader = const LinearGradient(
          colors: [Color(0xFFFFB13B), Color(0xFFF47720), Color(0xFFD85318)],
        ).createShader(const Rect.fromLTWH(-17, -12, 34, 25)),
    );
    canvas.drawLine(
      const Offset(-7, -10),
      const Offset(-8, 10),
      Paint()
        ..color = const Color(0xFFFFD07B).withValues(alpha: 0.6)
        ..strokeWidth = 1.4,
    );
    canvas.drawLine(
      const Offset(7, -10),
      const Offset(8, 10),
      Paint()
        ..color = const Color(0xFFB94B13).withValues(alpha: 0.7)
        ..strokeWidth = 1.4,
    );
    final stem = Path()
      ..moveTo(-3, -11)
      ..quadraticBezierTo(-5, -18, 1, -19)
      ..lineTo(4, -18)
      ..lineTo(2, -11)
      ..close();
    canvas.drawPath(stem, Paint()..color = const Color(0xFF668044));

    final facePaint = Paint()..color = const Color(0xFFFFE28A);
    final faceGlow = Paint()
      ..color = const Color(0xFFFFB52E).withValues(alpha: 0.22)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5);
    final face = Path()
      ..moveTo(-12, -4)
      ..lineTo(-5, -1)
      ..lineTo(-9, 4)
      ..close()
      ..moveTo(12, -4)
      ..lineTo(5, -1)
      ..lineTo(9, 4)
      ..close()
      ..moveTo(0, 0)
      ..lineTo(-2, 4)
      ..lineTo(2, 4)
      ..close()
      ..moveTo(-11, 7)
      ..lineTo(-7, 5)
      ..lineTo(-4, 8)
      ..lineTo(0, 5)
      ..lineTo(4, 8)
      ..lineTo(7, 5)
      ..lineTo(11, 7)
      ..quadraticBezierTo(0, 14, -11, 7)
      ..close();
    canvas.drawPath(face, faceGlow);
    canvas.drawPath(face, facePaint);
  }

  @override
  bool shouldRepaint(covariant _SeasonalEffectsPainter oldDelegate) =>
      oldDelegate.season != season || oldDelegate.timeSeconds != timeSeconds;
}

//So can be updated when going back from lyrics
late Function updateColor;
late Color scaffoldBackgroundColor;

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  _PlayerScreenState createState() => _PlayerScreenState();
}

String? _displayArtworkSource(MediaItem? item) {
  final originalArt = item?.extras?['saturnOriginalArtUri'];
  if (originalArt is String && originalArt.isNotEmpty) return originalArt;
  final artUri = item?.artUri?.toString();
  if (artUri != null && artUri.isNotEmpty) return artUri;
  final thumb = item?.extras?['thumb'];
  if (thumb is String && thumb.isNotEmpty) return thumb;
  return null;
}

class _PlayerScreenState extends State<PlayerScreen> {
  AudioPlayerHandler audioHandler = GetIt.I<AudioPlayerHandler>();
  LinearGradient? _bgGradient;
  StreamSubscription? _mediaItemSub;
  ImageProvider? _blurImage;
  String? _lastPaletteSource;
  int _paletteRequestId = 0;
  late final Stream<MediaItem?> _displayItemStream = audioHandler.mediaItem
      .distinct(mediaItemDisplayEquals);

  //Calculate background color
  Future _updateColor() async {
    final currentItem = audioHandler.mediaItem.value;
    if (currentItem == null) return;

    if (!settings.colorGradientBackground && !settings.blurPlayerBackground) {
      return;
    }
    final source = _displayArtworkSource(currentItem);
    if (source == null || source.isEmpty || source == _lastPaletteSource) {
      return;
    }
    _lastPaletteSource = source;
    final requestId = ++_paletteRequestId;

    //BG Image
    if (settings.blurPlayerBackground) {
      setState(() {
        _blurImage = imageProviderForSource(source);
      });
    }

    final palette = await imagesDatabase.getPaletteGenerator(source);
    if (!mounted || requestId != _paletteRequestId) return;

    //Update notification
    if (settings.blurPlayerBackground) {
      SystemChrome.setSystemUIOverlayStyle(
        SystemUiOverlayStyle(
          statusBarColor:
              (palette.dominantColor?.color ?? scaffoldBackgroundColor)
                  .withValues(alpha: 0.25),
          systemNavigationBarColor: Color.alphaBlend(
            (palette.dominantColor?.color ?? scaffoldBackgroundColor)
                .withValues(alpha: 0.25),
            scaffoldBackgroundColor,
          ),
        ),
      );
    }

    //Color gradient
    if (!settings.blurPlayerBackground) {
      SystemChrome.setSystemUIOverlayStyle(
        SystemUiOverlayStyle(
          statusBarColor:
              (palette.dominantColor?.color ?? scaffoldBackgroundColor)
                  .withValues(alpha: 0.7),
        ),
      );
      setState(
        () => _bgGradient = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            palette.dominantColor!.color.withValues(alpha: 0.7),
            const Color.fromARGB(0, 0, 0, 0),
          ],
          stops: const [0.0, 0.6],
        ),
      );
    }
  }

  @override
  void initState() {
    _updateColor;
    _mediaItemSub = audioHandler.mediaItem.listen((event) {
      if (event == null) return;
      final source = _displayArtworkSource(event);
      if (source != _lastPaletteSource) _updateColor();
    });

    updateColor = _updateColor;
    super.initState();
  }

  @override
  void dispose() {
    _mediaItemSub?.cancel();
    //Fix bottom buttons
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        systemNavigationBarColor: settings.themeData.bottomAppBarTheme.color,
        statusBarColor: Colors.transparent,
      ),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    //Avoid async gap
    scaffoldBackgroundColor = Theme.of(context).scaffoldBackgroundColor;

    return Scaffold(
      body: SafeArea(
        child: Container(
          decoration: BoxDecoration(
            gradient: settings.blurPlayerBackground ? null : _bgGradient,
          ),
          child: Stack(
            children: [
              if (settings.blurPlayerBackground)
                ClipRect(
                  child: ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        image: DecorationImage(
                          image: _blurImage ?? const NetworkImage(''),
                          fit: BoxFit.cover,
                          colorFilter: ColorFilter.mode(
                            Colors.black.withValues(alpha: 0.25),
                            BlendMode.dstATop,
                          ),
                        ),
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              StreamBuilder<MediaItem?>(
                stream: audioHandler.mediaItem,
                initialData: audioHandler.mediaItem.value,
                builder: (context, snapshot) {
                  final item = snapshot.data;
                  var season = settings.eastereggsDisabled
                      ? null
                      : seasonalEffectForTrack(item);
                  if (!seasonalEffectIsInDateWindow(season, DateTime.now())) {
                    season = null;
                  }

                  return Positioned.fill(
                    child: IgnorePointer(
                      child: _SeasonalPlayerEffects(season: season),
                    ),
                  );
                },
              ),
              StreamBuilder(
                // Playback controls subscribe to playback state themselves.
                // Rebuild the whole player layout only when the selected item
                // changes, not for every playback-state update.
                stream: _displayItemStream,
                initialData: audioHandler.mediaItem.valueOrNull,
                builder: (BuildContext context, AsyncSnapshot snapshot) {
                  //When disconnected
                  if (audioHandler.mediaItem.value == null) {
                    //playerHelper.startService();
                    return Center(
                      child: CircularProgressIndicator(
                        color: Theme.of(context).primaryColor,
                      ),
                    );
                  }

                  return LayoutBuilder(
                    builder: (context, constraints) {
                      //Responsive
                      ScreenUtil.init(context, minTextAdapt: true);
                      final isDesktop =
                          !kIsWeb &&
                          (defaultTargetPlatform == TargetPlatform.macOS ||
                              defaultTargetPlatform == TargetPlatform.windows ||
                              defaultTargetPlatform == TargetPlatform.linux);
                      final useDesktopLayout =
                          isDesktop &&
                          constraints.maxWidth >= 900 &&
                          constraints.maxHeight >= 600;
                      if (useDesktopLayout) {
                        // This screen reads the current MediaItem in build.
                        // Returning the same canonical const widget prevents
                        // it from rebuilding when the outer stream emits a
                        // new track.
                        return PlayerScreenDesktop();
                      }
                      // The player can be hosted in a route or dialog whose
                      // constraints do not match the actual desktop window.
                      // Use the window aspect ratio so compact but wide
                      // desktop windows still select the landscape layout.
                      final windowSize = MediaQuery.sizeOf(context);
                      final isWideScreen =
                          windowSize.width >= windowSize.height * 1.15 &&
                          (!isDesktop || windowSize.width >= 850);
                      //Wide screen (desktop/landscape)
                      if (isWideScreen) {
                        // ignore: prefer_const_constructors
                        return PlayerScreenHorizontal();
                      }
                      //Narrow screen (portrait)
                      // ignore: prefer_const_constructors
                      return PlayerScreenVertical();
                    },
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class PlayerScreenDesktop extends StatelessWidget {
  const PlayerScreenDesktop({super.key});

  @override
  Widget build(BuildContext context) {
    final handler = GetIt.I<AudioPlayerHandler>();
    final item = handler.mediaItem.value;
    if (item == null) return const SizedBox.shrink();

    return Row(
      children: [
        Expanded(
          flex: 10,
          child: Column(
            children: [
              SizedBox(
                height: 54,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: MaterialLocalizations.of(
                          context,
                        ).closeButtonTooltip,
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: const Icon(Icons.close),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Playing from:'.i18n +
                              ' ' +
                              (handler.queueSource?.text ?? ''),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: Center(
                          child: LayoutBuilder(
                            builder: (context, constraints) => ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: math
                                    .min(620.0, constraints.maxWidth)
                                    .toDouble(),
                                maxHeight: math
                                    .min(620.0, constraints.maxHeight)
                                    .toDouble(),
                              ),
                              child: const AspectRatio(
                                aspectRatio: 1,
                                child: BigAlbumArt(),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final title = item.displayTitle ?? item.title;
                          final style = Theme.of(context)
                              .textTheme
                              .headlineSmall
                              ?.copyWith(fontWeight: FontWeight.bold);
                          final painter = TextPainter(
                            text: TextSpan(text: title, style: style),
                            maxLines: 1,
                            textDirection: Directionality.of(context),
                          )..layout(maxWidth: constraints.maxWidth);
                          if (painter.didExceedMaxLines) {
                            return SizedBox(
                              height: 34,
                              child: Marquee(
                                text: title,
                                style: style,
                                blankSpace: 32,
                                startPadding: 8,
                                accelerationDuration: const Duration(
                                  seconds: 1,
                                ),
                                pauseAfterRound: const Duration(seconds: 2),
                              ),
                            );
                          }
                          return Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: style,
                          );
                        },
                      ),
                      const SizedBox(height: 4),
                      Text(
                        item.displaySubtitle ?? item.artist ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: Theme.of(context).colorScheme.primary,
                            ),
                      ),
                      const SizedBox(height: 12),
                      const SeekBar(11, horizontalPadding: 24),
                      const SizedBox(height: 8),
                      PlaybackControls(48, horizontalPadding: 16),
                      const SizedBox(height: 8),
                      Padding(
                        padding: const EdgeInsets.only(left: 16),
                        child: Row(
                          children: [
                            Expanded(child: _DesktopTrackActions(item: item)),
                            const SizedBox(width: 8),
                            const _DesktopVolumeControl(),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          flex: 10,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 16, 16, 16),

            child: const _DesktopPlayerTabs(),
          ),
        ),
      ],
    );
  }
}

class _DesktopTrackActions extends StatelessWidget {
  final MediaItem item;

  const _DesktopTrackActions({required this.item});

  @override
  Widget build(BuildContext context) {
    final track = Track.fromMediaItem(item);
    final show = _podcastShowFromMediaItem(item);
    final isPodcastEpisode = show != null;
    final isDeezerRadioWithoutTrack =
        track.platformId == 'deezer' &&
        AudioPlayerHandler.isRadioItem(item) &&
        (item.extras?['radioTrackId'] as String?)?.isNotEmpty != true;
    final capabilities = PlatformManager.instance
        .getPlatform(track.platformId)
        .capabilities;
    final menu = MenuSheet(closeOnAction: false);
    final entries = <ListTile>[
      if (!isDeezerRadioWithoutTrack && capabilities.supportsPlaylistEdit)
        menuEntry(menu.addToPlaylist(track, context)),
      if (!isPodcastEpisode &&
          !isDeezerRadioWithoutTrack &&
          capabilities.supportsDownload)
        ListTile(
          title: Text('Offline'.i18n),
          leading: const Icon(Icons.download_for_offline_outlined),
          onTap: () async {
            final isOffline = await downloadManager.checkOffline(track: track);
            if (isOffline) {
              await downloadManager.removeOfflineTracks([track]);
              Fluttertoast.showToast(msg: 'Track removed from offline!'.i18n);
            } else if (track.unavailable == true) {
              Fluttertoast.showToast(msg: track.unavailableMessage);
            } else {
              await downloadManager.addOfflineTrack(track, private: true);
            }
          },
        ),
      if (!isPodcastEpisode &&
          !isDeezerRadioWithoutTrack &&
          capabilities.supportsDownload)
        ListTile(
          title: Text('Download'.i18n),
          leading: const Icon(Icons.file_download),
          onTap: () async {
            if (track.unavailable == true) {
              Fluttertoast.showToast(msg: track.unavailableMessage);
              return;
            }
            if (await downloadManager.addOfflineTrack(
                  track,
                  private: false,
                  isSingleton: true,
                ) !=
                false) {
              menu.showDownloadStartedToast();
            }
          },
        ),
      if (!isDeezerRadioWithoutTrack)
        menuEntry(
          menu.shareTile('track', track.id ?? '', platformId: track.platformId),
        ),
      if (isPodcastEpisode)
        menuEntry(menu.playbackSpeed(context, closeAfterSelection: false)),
      if (!isDeezerRadioWithoutTrack && capabilities.supportsSmartRadio)
        menuEntry(menu.playMix(track, context)),
      if (!isDeezerRadioWithoutTrack &&
          !isPodcastEpisode &&
          capabilities.supportsTrackPage)
        menuEntry(menu.showTrack(track, context)),
      if (!isDeezerRadioWithoutTrack)
        ...PlatformManager.instance
            .getPlatform(track.platformId)
            .getExtraMenuOptions(context, track)
            .whereType<ListTile>(),
      menuEntry(menu.sleepTimer(context)),
      menuEntry(menu.wakelock(context)),
    ];

    final actions = entries.map((entry) {
      final label = (entry.title as Text).data ?? '';
      final isTrackDetails = label == 'Track details'.i18n;
      return _DesktopPlayerAction(
        label: label,
        icon: entry.leading ?? const Icon(Icons.more_horiz),
        onPressed: isTrackDetails
            ? () async {
                _popPlayerThenOpen(
                  context,
                  '/track/${Uri.encodeComponent(track.id ?? '')}?platform=${track.platformId}',
                  track,
                );
              }
            : () async => entry.onTap?.call(),
      );
    }).toList();
    return LayoutBuilder(
      builder: (context, constraints) {
        final actionIconColor = Theme.of(context).colorScheme.onSurfaceVariant;
        const actionSlotWidth = 32.0;
        const actionSlotHeight = 36.0;
        final availableSlots =
            ((constraints.maxWidth - actionSlotWidth) / actionSlotWidth)
                .floor()
                .clamp(0, actions.length)
                .toInt();
        final needsOverflow = availableSlots < actions.length;
        final visibleCount = needsOverflow
            ? (availableSlots - 1).clamp(0, actions.length).toInt()
            : actions.length;
        final visibleActions = actions.take(visibleCount).toList();
        final hasOverflow = needsOverflow && availableSlots > 0;
        return Row(
          mainAxisSize: MainAxisSize.max,
          children: [
            const _DesktopRepeatButton(),
            ...visibleActions.map(
              (action) => IconButton(
                tooltip: action.label,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: actionSlotWidth,
                  height: actionSlotHeight,
                ),
                color: actionIconColor,
                icon: _desktopActionIcon(action.icon, actionIconColor),
                onPressed: () => unawaited(action.onPressed()),
              ),
            ),
            if (hasOverflow)
              _DesktopTrackOverflowButton(
                actions: actions.skip(visibleCount).toList(),
              ),
          ],
        );
      },
    );
  }

  ListTile menuEntry(Widget entry) => entry as ListTile;
}

Widget _desktopActionIcon(Widget source, Color defaultColor) {
  if (source is Icon && source.icon != null) {
    final visualSize = switch (source.icon!) {
      Icons.playlist_add => 28.0,
      Icons.download_for_offline_outlined => 25.0,
      Icons.file_download => 22.0,
      Icons.share => 22.0,
      Icons.online_prediction => 25.0,
      Icons.access_time => 22.0,
      Icons.screen_lock_portrait => 21.0,
      _ => 24.0,
    };
    return SizedBox(
      width: 30,
      height: 30,
      child: Center(
        child: Icon(
          source.icon,
          size: visualSize,
          color: source.color ?? defaultColor,
          semanticLabel: source.semanticLabel,
        ),
      ),
    );
  }
  return SizedBox(
    width: 30,
    height: 30,
    child: Center(
      child: IconTheme.merge(
        data: IconThemeData(size: 22, color: defaultColor),
        child: source,
      ),
    ),
  );
}

class _DesktopTrackOverflowButton extends StatelessWidget {
  final List<_DesktopPlayerAction> actions;

  const _DesktopTrackOverflowButton({required this.actions});

  @override
  Widget build(BuildContext context) {
    final iconColor = Theme.of(context).colorScheme.onSurfaceVariant;
    return PopupMenuButton<_DesktopPlayerAction>(
      tooltip: 'Options'.i18n,
      padding: EdgeInsets.zero,
      child: SizedBox(
        width: 32,
        height: 36,
        child: Center(child: Icon(Icons.more_vert, size: 22, color: iconColor)),
      ),
      onSelected: (action) => unawaited(action.onPressed()),
      itemBuilder: (context) => actions
          .map(
            (action) => PopupMenuItem<_DesktopPlayerAction>(
              value: action,
              child: Row(
                children: [
                  _desktopActionIcon(action.icon, iconColor),
                  const SizedBox(width: 12),
                  Flexible(child: Text(action.label)),
                ],
              ),
            ),
          )
          .toList(),
    );
  }
}

class _DesktopRepeatButton extends StatefulWidget {
  const _DesktopRepeatButton();

  @override
  State<_DesktopRepeatButton> createState() => _DesktopRepeatButtonState();
}

class _DesktopRepeatButtonState extends State<_DesktopRepeatButton> {
  final AudioPlayerHandler _handler = GetIt.I<AudioPlayerHandler>();

  @override
  Widget build(BuildContext context) {
    final mode = _handler.getLoopMode();
    final isRepeating = mode != LoopMode.off;
    return IconButton(
      tooltip: mode == LoopMode.one
          ? 'Repeat one'.i18n
          : isRepeating
          ? 'Repeat'.i18n
          : 'Repeat off'.i18n,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 32, height: 36),
      color: isRepeating ? Theme.of(context).colorScheme.primary : null,
      icon: Icon(
        mode == LoopMode.one ? Icons.repeat_one : Icons.repeat,
        size: 22,
      ),
      onPressed: () async {
        await _handler.changeRepeat();
        if (mounted) setState(() {});
      },
    );
  }
}

class _DesktopPlayerAction {
  final String label;
  final Widget icon;
  final Future<void> Function() onPressed;

  const _DesktopPlayerAction({
    required this.label,
    required this.icon,
    required this.onPressed,
  });
}

class _DesktopPlayerTabs extends StatefulWidget {
  const _DesktopPlayerTabs();

  @override
  State<_DesktopPlayerTabs> createState() => _DesktopPlayerTabsState();
}

class _DesktopPlayerTabsState extends State<_DesktopPlayerTabs> {
  final LyricsScreenController _lyricsController = LyricsScreenController();
  final ValueNotifier<bool> _queueLoading = ValueNotifier(false);

  @override
  void dispose() {
    _lyricsController.dispose();
    _queueLoading.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Builder(
        builder: (context) {
          final tabs = DefaultTabController.of(context);
          return Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: TabBar(
                        isScrollable: true,
                        tabAlignment: TabAlignment.start,
                        padding: EdgeInsets.zero,
                        dividerColor: Colors.transparent,
                        dividerHeight: 0,
                        tabs: [
                          Tab(text: 'Queue'.i18n),
                          Tab(text: 'Info'.i18n),
                          Tab(text: 'Lyrics'.i18n),
                        ],
                      ),
                    ),
                  ),
                  AnimatedBuilder(
                    animation: tabs,
                    builder: (context, child) {
                      if (tabs.index == 0) {
                        return StreamBuilder<QueueState>(
                          stream:
                              GetIt.I<AudioPlayerHandler>().queueStateStream,
                          initialData: GetIt.I<AudioPlayerHandler>().queueState,
                          builder: (context, snapshot) {
                            final handler = GetIt.I<AudioPlayerHandler>();
                            final shuffleEnabled =
                                (snapshot.data ?? handler.queueState)
                                    .shuffleMode ==
                                AudioServiceShuffleMode.all;
                            return Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ValueListenableBuilder<bool>(
                                  valueListenable: _queueLoading,
                                  builder: (context, isLoading, _) => isLoading
                                      ? const Padding(
                                          padding: EdgeInsets.symmetric(
                                            horizontal: 10,
                                          ),
                                          child: SizedBox.square(
                                            dimension: 18,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          ),
                                        )
                                      : const SizedBox.shrink(),
                                ),
                                IconButton(
                                  tooltip: 'Shuffle'.i18n,
                                  visualDensity: VisualDensity.compact,
                                  color: shuffleEnabled
                                      ? Theme.of(context).primaryColor
                                      : null,
                                  onPressed: handler.isPreparingQueueForShuffle
                                      ? null
                                      : () => handler.toggleShuffle(),
                                  icon: const Icon(Icons.shuffle),
                                ),
                                IconButton(
                                  tooltip: 'Clear all'.i18n,
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () async {
                                    final navigator = Navigator.of(context);
                                    await handler.clearQueue();
                                    if (navigator.mounted &&
                                        navigator.canPop()) {
                                      navigator.pop();
                                    }
                                  },
                                  icon: const Icon(Icons.close),
                                ),
                              ],
                            );
                          },
                        );
                      }
                      if (tabs.index == 1) {
                        return const PlayerMenuButton(
                          iconSize: 22,
                          includeAlbumAndArtists: false,
                        );
                      }
                      if (tabs.index == 1) {
                        return const PlayerMenuButton(
                          iconSize: 22,
                          includeAlbumAndArtists: false,
                        );
                      }
                      if (tabs.index == 1) {
                        return const PlayerMenuButton(
                          iconSize: 22,
                          includeAlbumAndArtists: false,
                        );
                      }
                      if (tabs.index != 2) return const SizedBox.shrink();
                      return ValueListenableBuilder<LyricsToolbarState>(
                        valueListenable: _lyricsController.toolbarState,
                        builder: (context, state, child) => Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (state.canChooseLyrics)
                              IconButton(
                                tooltip: 'Choose lyrics'.i18n,
                                visualDensity: VisualDensity.compact,
                                onPressed: _lyricsController.showLyricsChoices,
                                icon: const Icon(Icons.lyrics_outlined),
                              ),
                            if (state.hasTranslation)
                              IconButton(
                                tooltip: 'Translation'.i18n,
                                visualDensity: VisualDensity.compact,
                                style: IconButton.styleFrom(
                                  foregroundColor: state.showTranslation
                                      ? Theme.of(context).colorScheme.primary
                                      : null,
                                ),
                                onPressed: _lyricsController.toggleTranslation,
                                icon: const Icon(Icons.translate),
                              ),
                            if (state.hasRomanization)
                              IconButton(
                                tooltip: 'Romanization'.i18n,
                                visualDensity: VisualDensity.compact,
                                style: IconButton.styleFrom(
                                  foregroundColor: state.showRomanization
                                      ? Theme.of(context).colorScheme.primary
                                      : null,
                                ),
                                onPressed: _lyricsController.toggleRomanization,
                                icon: const Icon(Icons.text_fields),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                  const SizedBox(width: 8),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _DesktopQueueTab(
                      onLoadingChanged: (loading) {
                        if (mounted) _queueLoading.value = loading;
                      },
                    ),
                    _DesktopInfoTab(),
                    _DesktopLyricsTab(controller: _lyricsController),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _DesktopQueueTab extends StatefulWidget {
  final ValueChanged<bool> onLoadingChanged;

  const _DesktopQueueTab({required this.onLoadingChanged});

  @override
  State<_DesktopQueueTab> createState() => _DesktopQueueTabState();
}

class _DesktopQueueTabState extends State<_DesktopQueueTab> {
  final AudioPlayerHandler _handler = GetIt.I<AudioPlayerHandler>();
  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController()..addListener(_maybeLoadMore);
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_maybeLoadMore)
      ..dispose();
    super.dispose();
  }

  void _maybeLoadMore() {
    if (!_scrollController.hasClients ||
        !_handler.canLoadMoreQueue ||
        _handler.isLoadingMoreQueue) {
      return;
    }
    final position = _scrollController.position;
    if (position.maxScrollExtent - position.pixels <
        position.viewportDimension * 1.25) {
      unawaited(_loadMoreQueue());
    }
  }

  Future<void> _loadMoreQueue() async {
    widget.onLoadingChanged(true);
    try {
      await _handler.loadMoreQueueItems();
    } finally {
      widget.onLoadingChanged(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QueueState>(
      stream: _handler.queueStateStream,
      initialData: _handler.queueState,
      builder: (context, snapshot) {
        final state = snapshot.data ?? _handler.queueState;
        final showPlatformBadges = _queueHasMixedPlatforms(state.queue);
        return SilkyScroll.fromConfig(
          config: silkyScrollConfig,
          controller: _scrollController,
          builder: (context, controller, physics, _) {
            Widget buildQueueItem(int displayIndex) {
              final queueIndex =
                  state.shuffleMode == AudioServiceShuffleMode.all &&
                      displayIndex < state.indices.length
                  ? state.indices[displayIndex]
                  : displayIndex;
              final item = state.queue[queueIndex];
              final track = Track.fromMediaItem(item);
              final removeFromQueueOption = ListTile(
                title: Text('Remove from queue'.i18n),
                leading: const Icon(Icons.remove_circle_outline),
                onTap: () => _handler.removeQueueItem(item),
              );
              return LayoutBuilder(
                key: ValueKey('${item.id}:$queueIndex'),
                builder: (context, constraints) {
                  final isCompact = constraints.maxWidth < 668;
                  final trailing = isCompact
                      ? Builder(
                          builder: (buttonContext) => IconButton(
                            tooltip: 'Options'.i18n,
                            icon: const Icon(Icons.more_vert),
                            onPressed: () {
                              final button =
                                  buttonContext.findRenderObject() as RenderBox;
                              final overlay =
                                  Overlay.of(
                                        buttonContext,
                                      ).context.findRenderObject()
                                      as RenderBox;
                              final position = RelativeRect.fromRect(
                                Rect.fromPoints(
                                  button.localToGlobal(
                                    Offset.zero,
                                    ancestor: overlay,
                                  ),
                                  button.localToGlobal(
                                    button.size.bottomRight(Offset.zero),
                                    ancestor: overlay,
                                  ),
                                ),
                                Offset.zero & overlay.size,
                              );
                              MenuSheet().defaultTrackPopup(
                                track,
                                context: context,
                                position: position,
                                leadingOptions: [removeFromQueueOption],
                              );
                            },
                          ),
                        )
                      : IconButton(
                          tooltip: 'Remove from queue'.i18n,
                          icon: const Icon(Icons.close),
                          onPressed: () => _handler.removeQueueItem(item),
                        );
                  final canReorder =
                      state.shuffleMode != AudioServiceShuffleMode.all;
                  return TrackTile(
                    track,
                    showPlatformBadge: showPlatformBadges,
                    onTap: () => _handler.skipToQueueItem(queueIndex),
                    trailing: canReorder
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              trailing,
                              ReorderableDragStartListener(
                                index: displayIndex,
                                child: const Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 8),
                                  child: MouseRegion(
                                    cursor: SystemMouseCursors.grab,
                                    child: Icon(Icons.drag_handle),
                                  ),
                                ),
                              ),
                            ],
                          )
                        : trailing,
                    trailingBypass: true,
                    popupLeadingOptions: [removeFromQueueOption],
                  );
                },
              );
            }

            if (state.shuffleMode == AudioServiceShuffleMode.all) {
              return ListView.builder(
                controller: controller,
                physics: physics,
                itemCount: state.queue.length,
                itemBuilder: (context, index) => buildQueueItem(index),
              );
            }
            return ReorderableListView.builder(
              scrollController: controller,
              physics: physics,
              buildDefaultDragHandles: false,
              itemCount: state.queue.length,
              onReorderItem: (oldIndex, newIndex) async {
                if (newIndex > oldIndex) newIndex--;
                if (oldIndex != newIndex) {
                  await _handler.moveQueueItem(oldIndex, newIndex);
                }
              },
              itemBuilder: (context, index) => buildQueueItem(index),
            );
          },
        );
      },
    );
  }
}

class _DesktopInfoTab extends StatelessWidget {
  const _DesktopInfoTab();

  @override
  Widget build(BuildContext context) {
    final handler = GetIt.I<AudioPlayerHandler>();
    return StreamBuilder<MediaItem?>(
      stream: handler.mediaItem,
      initialData: handler.mediaItem.value,
      builder: (context, snapshot) {
        final item = snapshot.data;
        if (item == null) return const SizedBox.shrink();
        final track = Track.fromMediaItem(item);
        final show = _podcastShowFromMediaItem(item);
        final isPodcastEpisode = show != null;
        final album = track.album;
        if (album != null) {
          album.art ??= track.albumArt;
          album.artists ??= track.displayArtists;
        }
        final albumForTile =
            album ??
            Album(
              title: item.album,
              art: track.albumArt,
              artists: track.displayArtists,
              platformId: track.platformId,
            );
        final albumId = album?.id;
        final albumTitle = album?.title ?? item.album ?? '';
        // Match the artist entries exposed by the track menu: prefer
        // navigable artists when the platform provides them.
        final artists =
            track.navigableArtists ?? track.artists ?? const <Artist>[];
        final textTheme = Theme.of(context).textTheme;

        final sectionShape = RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        );
        Widget section(String title, Widget content) => Card(
          margin: EdgeInsets.zero,
          elevation: 1,
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          shape: sectionShape,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 2, bottom: 6),
                  child: Text(
                    title.i18n,
                    style: textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                content,
              ],
            ),
          ),
        );

        final metadata = <(String, String?)>[
          ('Quality'.i18n, _qualityDescription(item)),
          ('Duration'.i18n, track.durationString),
          ('Disc number'.i18n, track.diskNumber?.toString()),
          ('Track number'.i18n, track.trackNumber?.toString()),
          (
            'Explicit'.i18n,
            track.explicit == null ? null : (track.explicit! ? 'Yes' : 'No'),
          ),
          ('Source'.i18n, _playbackSourceLabel(item)),
          ('ID'.i18n, item.id),
        ].where((entry) => entry.$2?.trim().isNotEmpty == true).toList();

        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Card(
              margin: EdgeInsets.zero,
              elevation: 2,
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              shape: sectionShape,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: CachedImage(
                        url: _displayArtworkSource(item) ?? '',
                        width: 128,
                        height: 128,
                      ),
                    ),
                    const SizedBox(width: 18),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.displayTitle ?? item.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            track.artistString ?? item.displaySubtitle ?? '',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.bodyLarge?.copyWith(
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (!isPodcastEpisode && albumTitle.trim().isNotEmpty)
              section(
                'Album',
                AlbumTile(
                  albumForTile,
                  onTap: albumId == null
                      ? null
                      : () => _popPlayerThenOpen(
                          context,
                          '/album/${Uri.encodeComponent(albumId)}',
                          albumForTile,
                        ),
                ),
              ),
            if (!isPodcastEpisode &&
                albumTitle.trim().isNotEmpty &&
                artists.isNotEmpty)
              const SizedBox(height: 14),
            if (show != null)
              section(
                'Podcast',
                ShowTile(
                  show,
                  onTap: show.id == null || show.id!.isEmpty
                      ? null
                      : () => _popPlayerThenOpen(
                          context,
                          '/show/${Uri.encodeComponent(show.id!)}',
                          show,
                        ),
                ),
              )
            else if (artists.isNotEmpty)
              section(
                'Artists',
                Column(
                  children: artists
                      .map(
                        (artist) => ArtistHorizontalTile(
                          artist,
                          onTap: artist.id == null || artist.id!.isEmpty
                              ? null
                              : () => _popPlayerThenOpen(
                                  context,
                                  '/artist/${Uri.encodeComponent(artist.id!)}',
                                  artist,
                                ),
                        ),
                      )
                      .toList(),
                ),
              ),
            if (!isPodcastEpisode &&
                artists.isEmpty &&
                track.artistString != null)
              section('Artists', Text(track.artistString!)),
            if (metadata.isNotEmpty) ...[
              const SizedBox(height: 18),
              Text(
                'Track details'.i18n,
                style: textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              LayoutBuilder(
                builder: (context, constraints) {
                  final cardWidth = (constraints.maxWidth - 12) / 2;
                  return Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: metadata.map((entry) {
                      return SizedBox(
                        width: cardWidth,
                        child: Card(
                          margin: EdgeInsets.zero,
                          elevation: 1,
                          color: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerLow,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  entry.$1.i18n,
                                  style: textTheme.labelSmall?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  entry.$2!,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: textTheme.bodyMedium,
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  );
                },
              ),
            ],
          ],
        );
      },
    );
  }

  String? _qualityDescription(MediaItem item) {
    final format = item.extras?['qualityFormat'] as String?;
    final bitrate = item.extras?['qualityBitrate'];
    if (format == null || format.isEmpty) return null;
    return bitrate is num && bitrate > 0
        ? '$format ${bitrate.round()}kbps'
        : format;
  }
}

void _popPlayerThenOpen(BuildContext context, String route, Object extra) {
  final navigator = Navigator.of(context);
  if (navigator.canPop()) navigator.pop();
  WidgetsBinding.instance.addPostFrameCallback((_) {
    appRouter.push(route, extra: extra);
  });
}

Show? _podcastShowFromMediaItem(MediaItem item) {
  final encodedShow = item.extras?['show'];
  if (encodedShow is! String || encodedShow.isEmpty) return null;
  try {
    final decoded = jsonDecode(encodedShow);
    if (decoded is Map<String, dynamic>) return Show.fromJson(decoded);
    if (decoded is Map) {
      return Show.fromJson(Map<String, dynamic>.from(decoded));
    }
  } catch (error) {
    appLogger.warning('Could not parse podcast show from media item: $error');
  }
  return null;
}

class _DesktopLyricsTab extends StatelessWidget {
  final LyricsScreenController controller;

  const _DesktopLyricsTab({required this.controller});

  @override
  Widget build(BuildContext context) {
    final item = GetIt.I<AudioPlayerHandler>().mediaItem.value;
    if (item == null) return const SizedBox.shrink();
    final track = Track.fromMediaItem(item);
    return ClipRect(
      child: LyricsScreen(
        trackId: item.id,
        lyrics: track.lyrics,
        embedded: true,
        controller: controller,
      ),
    );
  }
}

class _DesktopVolumeControl extends StatefulWidget {
  const _DesktopVolumeControl();

  @override
  State<_DesktopVolumeControl> createState() => _DesktopVolumeControlState();
}

class _DesktopVolumeControlState extends State<_DesktopVolumeControl> {
  final AudioPlayerHandler _handler = GetIt.I<AudioPlayerHandler>();
  double _lastVolume = 1;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<double>(
      stream: _handler.player.volumeStream,
      initialData: _handler.player.volume,
      builder: (context, snapshot) {
        final volume = (snapshot.data ?? _handler.player.volume)
            .clamp(0.0, 1.0)
            .toDouble();
        if (volume > 0) _lastVolume = volume;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: volume == 0 ? 'Unmute'.i18n : 'Mute'.i18n,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 40, height: 34),
              onPressed: () =>
                  _handler.player.setVolume(volume == 0 ? _lastVolume : 0),
              icon: Icon(volume == 0 ? Icons.volume_off : Icons.volume_up),
            ),
            SizedBox(
              width: 200,
              child: Slider(
                value: volume,
                onChanged: (value) => _handler.player.setVolume(value),
              ),
            ),
            SizedBox(
              width: 64,
              child: Padding(
                // Align the text's visible edge with the slider track, whose
                // painted track is inset inside its hit target.
                padding: const EdgeInsets.only(right: 24),
                child: Text(
                  '${(volume * 100).round()}%',
                  maxLines: 1,
                  softWrap: false,
                  textAlign: TextAlign.end,
                  style: const TextStyle(
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

//Landscape
class PlayerScreenHorizontal extends StatefulWidget {
  const PlayerScreenHorizontal({super.key});

  @override
  _PlayerScreenHorizontalState createState() => _PlayerScreenHorizontalState();
}

class _PlayerScreenHorizontalState extends State<PlayerScreenHorizontal> {
  @override
  Widget build(BuildContext context) {
    final isDesktop =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.windows);
    final actionIconSize = isDesktop ? 22.0 : ScreenUtil().setWidth(12);
    return Row(
      mainAxisSize: MainAxisSize.max,
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 2),
          child: SizedBox(
            width: ScreenUtil().setWidth(160),
            child: const Stack(children: <Widget>[BigAlbumArt()]),
          ),
        ),
        //Right side
        SizedBox(
          width: ScreenUtil().setWidth(170),
          child: Column(
            mainAxisSize: MainAxisSize.max,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                child: PlayerScreenTopRow(
                  textSize: ScreenUtil().setSp(28),
                  iconSize: isDesktop ? 24 : ScreenUtil().setSp(38),
                  textWidth: ScreenUtil().setWidth(150),
                  short: false,
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  SizedBox(
                    height: ScreenUtil().setSp(56),
                    child:
                        GetIt.I<AudioPlayerHandler>()
                                .mediaItem
                                .value!
                                .displayTitle!
                                .length >=
                            22
                        ? Marquee(
                            text: GetIt.I<AudioPlayerHandler>()
                                .mediaItem
                                .value!
                                .displayTitle!,
                            style: TextStyle(
                              fontSize: ScreenUtil().setSp(40),
                              fontWeight: FontWeight.bold,
                            ),
                            blankSpace: 32.0,
                            startPadding: 10.0,
                            accelerationDuration: const Duration(seconds: 1),
                            pauseAfterRound: const Duration(seconds: 2),
                          )
                        : Text(
                            GetIt.I<AudioPlayerHandler>()
                                .mediaItem
                                .value!
                                .displayTitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: ScreenUtil().setSp(40),
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                  ),
                  Container(height: 4),
                  Text(
                    GetIt.I<AudioPlayerHandler>()
                            .mediaItem
                            .value!
                            .displaySubtitle ??
                        '',
                    maxLines: 1,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.clip,
                    style: TextStyle(
                      fontSize: ScreenUtil().setSp(32),
                      color: Theme.of(context).primaryColor,
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: const SeekBar(24.0),
              ),
              PlaybackControls(
                isDesktop ? 48 : ScreenUtil().setSp(60),
                horizontalPadding: 16,
              ),
              Padding(
                //padding: EdgeInsets.fromLTRB(4, 0, 4, 8),
                padding: const EdgeInsets.symmetric(vertical: 8.0),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: Row(
                    mainAxisSize: MainAxisSize.max,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: <Widget>[
                      LyricsIconButton(
                        isDesktop ? 22 : 12,
                        afterOnPressed: updateColor,
                      ),
                      if (!GetIt.I<AudioPlayerHandler>().isRadio &&
                          !AudioPlayerHandler.isRadioItem(
                            GetIt.I<AudioPlayerHandler>().mediaItem.value,
                          ) &&
                          GetIt.I<AudioPlayerHandler>()
                                  .mediaItem
                                  .value
                                  ?.extras?['show'] ==
                              null)
                        IconButton(
                          icon: Icon(
                            Icons.file_download,
                            size: actionIconSize,
                            semanticLabel: 'Download'.i18n,
                          ),
                          onPressed: () async {
                            Track t = Track.fromMediaItem(
                              GetIt.I<AudioPlayerHandler>().mediaItem.value!,
                            );
                            if (await downloadManager.addOfflineTrack(
                                  t,
                                  private: false,
                                  isSingleton: true,
                                ) !=
                                false) {
                              Fluttertoast.showToast(
                                msg: 'Downloads added!'.i18n,
                                gravity: ToastGravity.BOTTOM,
                                toastLength: Toast.LENGTH_SHORT,
                              );
                            }
                          },
                        )
                      else
                        SizedBox(width: actionIconSize),
                      const QualityInfoWidget(),
                      if (!GetIt.I<AudioPlayerHandler>().isRadio &&
                          !AudioPlayerHandler.isRadioItem(
                            GetIt.I<AudioPlayerHandler>().mediaItem.value,
                          ))
                        RepeatButton(actionIconSize)
                      else
                        SizedBox(width: actionIconSize),
                      const PlayerMenuButton(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

//Portrait
class PlayerScreenVertical extends StatefulWidget {
  const PlayerScreenVertical({super.key});

  @override
  _PlayerScreenVerticalState createState() => _PlayerScreenVerticalState();
}

class _PlayerScreenVerticalState extends State<PlayerScreenVertical> {
  @override
  Widget build(BuildContext context) {
    final isDesktop =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.windows);
    final actionIconSize = isDesktop ? 22.0 : ScreenUtil().setWidth(20);
    return Column(
      mainAxisSize: MainAxisSize.max,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 4, 16, 0),
          child: PlayerScreenTopRow(
            textSize: ScreenUtil().setSp(14),
            iconSize: ScreenUtil().setSp(18),
            textWidth: ScreenUtil().setWidth(350),
            short: true,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          child: SizedBox(
            height: ScreenUtil().setHeight(360),
            child: const Stack(children: <Widget>[BigAlbumArt()]),
          ),
        ),
        Container(height: 4.0),
        Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              height: ScreenUtil().setSp(32),
              child:
                  (GetIt.I<AudioPlayerHandler>()
                                  .mediaItem
                                  .value
                                  ?.displayTitle ??
                              '')
                          .length >=
                      26
                  ? Marquee(
                      text:
                          GetIt.I<AudioPlayerHandler>()
                              .mediaItem
                              .value
                              ?.displayTitle ??
                          '',
                      style: TextStyle(
                        fontSize: ScreenUtil().setSp(22),
                        fontWeight: FontWeight.bold,
                      ),
                      blankSpace: 32.0,
                      startPadding: 10.0,
                      accelerationDuration: const Duration(seconds: 1),
                      pauseAfterRound: const Duration(seconds: 2),
                    )
                  : Text(
                      GetIt.I<AudioPlayerHandler>()
                              .mediaItem
                              .value
                              ?.displayTitle ??
                          '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: ScreenUtil().setSp(22),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
            ),
            Container(height: 4),
            Text(
              GetIt.I<AudioPlayerHandler>().mediaItem.value?.displaySubtitle ??
                  '',
              maxLines: 1,
              textAlign: TextAlign.center,
              overflow: TextOverflow.clip,
              style: TextStyle(
                fontSize: ScreenUtil().setSp(16),
                color: Theme.of(context).primaryColor,
              ),
            ),
          ],
        ),
        const SeekBar(12.0),
        PlaybackControls(
          isDesktop ? 32 : ScreenUtil().setSp(36),
          horizontalPadding: 16,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 0, horizontal: 16.0),
          child: Row(
            mainAxisSize: MainAxisSize.max,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              LyricsIconButton(
                isDesktop ? 22 : 20,
                afterOnPressed: updateColor,
              ),
              if (!GetIt.I<AudioPlayerHandler>().isRadio &&
                  !AudioPlayerHandler.isRadioItem(
                    GetIt.I<AudioPlayerHandler>().mediaItem.value,
                  ) &&
                  GetIt.I<AudioPlayerHandler>()
                          .mediaItem
                          .value
                          ?.extras?['show'] ==
                      null)
                IconButton(
                  icon: Icon(
                    Icons.file_download,
                    size: actionIconSize,
                    semanticLabel: 'Download'.i18n,
                  ),
                  onPressed: () async {
                    Track t = Track.fromMediaItem(
                      GetIt.I<AudioPlayerHandler>().mediaItem.value!,
                    );
                    if (await downloadManager.addOfflineTrack(
                          t,
                          private: false,
                          isSingleton: true,
                        ) !=
                        false) {
                      Fluttertoast.showToast(
                        msg: 'Downloads added!'.i18n,
                        gravity: ToastGravity.BOTTOM,
                        toastLength: Toast.LENGTH_SHORT,
                      );
                    }
                  },
                )
              else
                SizedBox(width: actionIconSize),
              const QualityInfoWidget(),
              if (!GetIt.I<AudioPlayerHandler>().isRadio &&
                  !AudioPlayerHandler.isRadioItem(
                    GetIt.I<AudioPlayerHandler>().mediaItem.value,
                  ))
                RepeatButton(actionIconSize)
              else
                SizedBox(width: actionIconSize),
              const PlayerMenuButton(),
            ],
          ),
        ),
      ],
    );
  }
}

class QualityInfoWidget extends StatefulWidget {
  const QualityInfoWidget({super.key});

  @override
  State<QualityInfoWidget> createState() => _QualityInfoWidgetState();
}

class _QualityInfoWidgetState extends State<QualityInfoWidget> {
  final AudioPlayerHandler audioHandler = GetIt.I<AudioPlayerHandler>();
  StreamSubscription? _mediaItemSub;
  String? _format;
  int? _bitrate;

  @override
  void initState() {
    super.initState();
    final initialExtras = audioHandler.mediaItem.value?.extras;
    _format = initialExtras?['qualityFormat'] as String?;
    _bitrate = initialExtras?['qualityBitrate'] as int?;

    _mediaItemSub = audioHandler.mediaItem.listen((mediaItem) {
      if (!mounted) return;

      final extras = mediaItem?.extras;
      final newFormat = extras?['qualityFormat'] as String?;
      final newBitrate = extras?['qualityBitrate'] as int?;
      if (_format != newFormat || _bitrate != newBitrate) {
        setState(() {
          _format = newFormat;
          _bitrate = newBitrate;
        });
      }
    });
  }

  @override
  void dispose() {
    _mediaItemSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_format == null || _format!.isEmpty) {
      return const SizedBox.shrink();
    }

    final label = (_bitrate != null && _bitrate! > 0)
        ? '$_format ${_bitrate}kbps'
        : _format!;

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final badgeTextColor = AppTheme.legibleAccent(
      theme.colorScheme.primary,
      isDark: isDark,
    );

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () {
          if (audioHandler.isRadio ||
              AudioPlayerHandler.isRadioItem(audioHandler.mediaItem.value)) {
            return;
          }
          Navigator.of(context).push(
            MaterialPageRoute(builder: (context) => const QualitySettings()),
          );
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(
            border: Border.all(
              color: theme.colorScheme.primary.withValues(
                alpha: isDark ? 0.6 : 0.45,
              ),
              width: 1.2,
            ),
            borderRadius: BorderRadius.circular(6),
            color: theme.colorScheme.primary.withValues(
              alpha: isDark ? 0.15 : 0.08,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
              color: badgeTextColor,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
    );
  }
}

class LyricsIconButton extends StatelessWidget {
  final double width;
  final Function? afterOnPressed;

  const LyricsIconButton(this.width, {super.key, this.afterOnPressed});

  @override
  Widget build(BuildContext context) {
    final mediaItem = GetIt.I<AudioPlayerHandler>().mediaItem.value;
    final isDesktop =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.windows);
    final iconSize = isDesktop ? width : ScreenUtil().setWidth(width);
    if (mediaItem == null) return const SizedBox.shrink();
    final isRadio =
        GetIt.I<AudioPlayerHandler>().isRadio ||
        AudioPlayerHandler.isRadioItem(mediaItem);
    final radioTrackId = mediaItem.extras?['radioTrackId'] as String?;
    if (isRadio && (radioTrackId == null || radioTrackId.isEmpty)) {
      return SizedBox(width: iconSize);
    }
    final trackId = radioTrackId ?? mediaItem.id;

    return Opacity(
      opacity: 1.0,
      child: IconButton(
        icon: Icon(Icons.lyrics, size: iconSize, semanticLabel: 'Lyrics'.i18n),
        onPressed: () async {
          //Fix bottom buttons
          SystemChrome.setSystemUIOverlayStyle(
            const SystemUiOverlayStyle(statusBarColor: Colors.transparent),
          );

          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => LyricsScreen(trackId: trackId),
            ),
          );

          if (afterOnPressed != null) {
            afterOnPressed!();
          }
        },
      ),
    );
  }
}

class PlayerMenuButton extends StatelessWidget {
  final double? iconSize;
  final bool includeAlbumAndArtists;

  const PlayerMenuButton({
    this.iconSize,
    this.includeAlbumAndArtists = true,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(
        Icons.more_vert,
        size: iconSize ?? 24,
        semanticLabel: 'Options'.i18n,
      ),
      onPressed: () {
        Track t = Track.fromMediaItem(
          GetIt.I<AudioPlayerHandler>().mediaItem.value!,
        );
        MenuSheet m = MenuSheet(
          navigateCallback: () {
            Navigator.of(context).pop();
          },
        );
        if (GetIt.I<AudioPlayerHandler>().mediaItem.value!.extras?['show'] ==
            null) {
          final currentItem = GetIt.I<AudioPlayerHandler>().mediaItem.value!;
          final isDeezerRadioWithoutTrack =
              t.platformId == 'deezer' &&
              AudioPlayerHandler.isRadioItem(currentItem) &&
              (currentItem.extras?['radioTrackId'] as String?)?.isNotEmpty !=
                  true;
          final options = [m.sleepTimer(context), m.wakelock(context)];
          if (includeAlbumAndArtists) {
            m.defaultTrackMenu(t, context: context, options: options);
          } else {
            final platform = PlatformManager.instance.getPlatform(t.platformId);
            final capabilities = platform.capabilities;
            m.show(context, [
              if (!isDeezerRadioWithoutTrack &&
                  capabilities.supportsLibrarySync)
                cache.checkTrackFavorite(t)
                    ? m.removeFavoriteTrack(t, context)
                    : m.addTrackFavorite(t, context),
              if (!isDeezerRadioWithoutTrack &&
                  capabilities.supportsPlaylistEdit)
                m.addToPlaylist(t, context),
              if (!isDeezerRadioWithoutTrack &&
                  capabilities.supportsDownload) ...[
                m.offlineTrack(t, context),
                m.downloadTrack(t, context),
              ],
              if (!isDeezerRadioWithoutTrack)
                m.shareTile('track', t.id ?? '', platformId: t.platformId),
              if (!isDeezerRadioWithoutTrack && capabilities.supportsSmartRadio)
                m.playMix(t, context),
              if (!isDeezerRadioWithoutTrack && capabilities.supportsTrackPage)
                m.showTrack(t, context),
              ...platform.getExtraMenuOptions(context, t),
              ...options,
            ]);
          }
        } else {
          m.defaultShowEpisodeMenu(
            Show.fromJson(
              jsonDecode(
                GetIt.I<AudioPlayerHandler>().mediaItem.value!.extras?['show'],
              ),
            ),
            ShowEpisode.fromMediaItem(
              GetIt.I<AudioPlayerHandler>().mediaItem.value!,
            ),
            context: context,
            includeHeader: includeAlbumAndArtists,
            options: [
              m.playbackSpeed(context),
              m.sleepTimer(context),
              m.wakelock(context),
            ],
          );
        }
      },
    );
  }
}

class RepeatButton extends StatefulWidget {
  final double iconSize;
  const RepeatButton(this.iconSize, {super.key});

  @override
  _RepeatButtonState createState() => _RepeatButtonState();
}

class _RepeatButtonState extends State<RepeatButton> {
  Icon get repeatIcon {
    switch (GetIt.I<AudioPlayerHandler>().getLoopMode()) {
      case LoopMode.off:
        return Icon(
          Icons.repeat,
          size: widget.iconSize,
          semanticLabel: 'Repeat off'.i18n,
        );
      case LoopMode.all:
        return Icon(
          Icons.repeat,
          color: Theme.of(context).primaryColor,
          size: widget.iconSize,
          semanticLabel: 'Repeat'.i18n,
        );
      case LoopMode.one:
        return Icon(
          Icons.repeat_one,
          color: Theme.of(context).primaryColor,
          size: widget.iconSize,
          semanticLabel: 'Repeat one'.i18n,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: repeatIcon,
      onPressed: () async {
        await GetIt.I<AudioPlayerHandler>().changeRepeat();
        setState(() {});
      },
    );
  }
}

class PlaybackControls extends StatefulWidget {
  final double iconSize;
  final double horizontalPadding;
  const PlaybackControls(
    this.iconSize, {
    this.horizontalPadding = 16,
    super.key,
  });

  @override
  _PlaybackControlsState createState() => _PlaybackControlsState();
}

class _PlaybackControlsState extends State<PlaybackControls> {
  AudioPlayerHandler audioHandler = GetIt.I<AudioPlayerHandler>();
  Icon get libraryIcon {
    final item = audioHandler.mediaItem.value;
    final trackId =
        item?.extras?['radioTrackId'] as String? ??
        (item?.extras?['isRadio'] == true ? null : item?.id);
    if (trackId != null &&
        cache.checkTrackFavorite(
          Track(
            id: trackId,
            platformId: Track.fromMediaItem(
              audioHandler.mediaItem.value!,
            ).platformId,
          ),
        )) {
      return Icon(
        Icons.favorite,
        size: widget.iconSize * 0.64,
        semanticLabel: 'Unlove'.i18n,
      );
    }
    return Icon(
      Icons.favorite_border,
      size: widget.iconSize * 0.64,
      semanticLabel: 'Love'.i18n,
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = audioHandler.mediaItem.value;
    final isRadio =
        audioHandler.isRadio || AudioPlayerHandler.isRadioItem(item);
    final supportsDislike =
        item != null &&
        PlatformManager.instance
            .getPlatform(Track.fromMediaItem(item).platformId)
            .capabilities
            .supportsDislike;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: widget.horizontalPadding),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        mainAxisSize: MainAxisSize.max,
        children: [
          if (isRadio || !supportsDislike)
            SizedBox(width: widget.iconSize * 0.64 + 16)
          else
            IconButton(
              padding: EdgeInsets.zero,
              icon: Icon(
                Icons.sentiment_very_dissatisfied,
                size: widget.iconSize * 0.64,
                semanticLabel: 'Dislike'.i18n,
              ),
              onPressed: () async {
                await PlatformManager.instance
                    .getPlatform(
                      Track.fromMediaItem(
                        audioHandler.mediaItem.value!,
                      ).platformId,
                    )
                    .dislikeTrack(audioHandler.mediaItem.value!.id);
                Fluttertoast.showToast(
                  msg: 'Track disliked!'.i18n,
                  gravity: ToastGravity.BOTTOM,
                  toastLength: Toast.LENGTH_SHORT,
                );
                if (audioHandler.queueState.hasNext) {
                  audioHandler.skipToNext();
                }
              },
            ),
          if (isRadio)
            SizedBox(width: widget.iconSize)
          else
            PrevNextButton(widget.iconSize, prev: true),
          PlayPauseButton(widget.iconSize * 1.25),
          if (isRadio)
            SizedBox(width: widget.iconSize)
          else
            PrevNextButton(widget.iconSize),
          if (!isRadio ||
              (item?.extras?['radioTrackId'] as String?)?.isNotEmpty == true)
            IconButton(
              padding: EdgeInsets.zero,
              icon: libraryIcon,
              onPressed: () async {
                final currentItem = audioHandler.mediaItem.value;
                if (currentItem == null) return;
                final track = Track.fromMediaItem(currentItem);
                final trackId =
                    currentItem.extras?['radioTrackId'] as String? ??
                    (currentItem.extras?['isRadio'] == true
                        ? null
                        : currentItem.id);
                if (trackId == null) return;
                final favTrack = Track(
                  id: trackId,
                  platformId: track.platformId,
                );
                final isFavorite = cache.checkTrackFavorite(favTrack);
                appLogger.info(
                  '[UI] PlayerScreen favorite pressed: trackId=$trackId, platformId=${track.platformId}, currentlyFavorite=$isFavorite',
                );
                cache.updateTrackFavorite(favTrack, favorite: !isFavorite);
                setState(() {});
                final platform = PlatformManager.instance.getPlatform(
                  track.platformId,
                );
                try {
                  if (isFavorite) {
                    await platform.removeFavoriteTrack(trackId);
                  } else {
                    await platform.addFavoriteTrack(trackId);
                  }
                } catch (error, stackTrace) {
                  appLogger.warning(
                    '[UI] PlayerScreen error updating track favorite: trackId=$trackId',
                    error,
                    stackTrace,
                  );
                  cache.updateTrackFavorite(favTrack, favorite: isFavorite);
                  if (mounted) setState(() {});
                  Fluttertoast.showToast(
                    msg: 'Could not update favorite: $error',
                  );
                  return;
                }
                await cache.save();
                if (mounted) setState(() {});
              },
            )
          else
            SizedBox(width: widget.iconSize * 0.64 + 16),
        ],
      ),
    );
  }
}

class BigAlbumArt extends StatefulWidget {
  const BigAlbumArt({super.key});

  @override
  _BigAlbumArtState createState() => _BigAlbumArtState();
}

class _BigAlbumArtState extends State<BigAlbumArt> with WidgetsBindingObserver {
  final AudioPlayerHandler audioHandler = GetIt.I<AudioPlayerHandler>();
  List<MediaItem> _queue = [];
  late PageController _pageController;
  StreamSubscription? _currentItemAndQueueSub;
  late int _lastKnownCurrentIndex;
  bool _isVisible = false;
  // Count of active programmatic page transitions.
  // Intermediate pages passed during programmatic moves must not trigger skips.
  int _programmaticScrollCount = 0;
  bool get _programmaticScroll => _programmaticScrollCount > 0;
  int? _animatingTargetPage;
  int? _pendingUserPage;
  int? _pendingUserPageFrom;

  @override
  void initState() {
    super.initState();
    final initialIndex = audioHandler.currentIndex;
    _lastKnownCurrentIndex = initialIndex < 0 ? 0 : initialIndex;
    _pageController = PageController(initialPage: _lastKnownCurrentIndex);

    _queue = audioHandler.queue.value;

    _currentItemAndQueueSub =
        Rx.combineLatest2<MediaItem?, List<MediaItem>, void>(
          audioHandler.mediaItem,
          audioHandler.queue,
          (mediaItem, queue) {
            if (queue.isNotEmpty) {
              final queueChanged = _didQueueChange(queue);
              final currentIndex = audioHandler.currentIndex;
              final activeItem = mediaItem;
              final currentItemWasReordered =
                  queueChanged &&
                  queue.length == _queue.length &&
                  currentIndex != _lastKnownCurrentIndex &&
                  _lastKnownCurrentIndex >= 0 &&
                  _lastKnownCurrentIndex < _queue.length &&
                  currentIndex >= 0 &&
                  currentIndex < queue.length &&
                  activeItem != null &&
                  _queue[_lastKnownCurrentIndex].id == activeItem.id &&
                  queue[currentIndex].id == activeItem.id;

              _lastKnownCurrentIndex = currentIndex;
              if (queueChanged) {
                setState(() {
                  // AudioService publishes immutable queue snapshots. Keep
                  // the snapshot itself so media-item-only events can be
                  // recognized by identity without copying a large queue.
                  _queue = queue;
                });
              }

              if (currentItemWasReordered) {
                // A queue reorder changes the current track's numeric index,
                // but the track itself hasn't changed. Keep its artwork in
                // place without animating through the newly reordered items.
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted && _pageController.hasClients) {
                    _pageController.jumpToPage(currentIndex);
                  }
                });
              } else {
                _handleMediaItemChange(mediaItem);
              }
            }
          },
        ).listen((_) {});

    WidgetsBinding.instance.addObserver(this);
  }

  bool _didQueueChange(List<MediaItem> newQueue) {
    if (identical(newQueue, _queue)) return false;
    if (newQueue.length != _queue.length) {
      return true;
    }
    for (int i = 0; i < newQueue.length; i++) {
      if (newQueue[i].id != _queue[i].id ||
          newQueue[i].artUri != _queue[i].artUri ||
          newQueue[i].extras?['caption'] != _queue[i].extras?['caption']) {
        return true;
      }
    }
    return false;
  }

  void _handleMediaItemChange(MediaItem? item) async {
    final targetItemId = item?.id ?? '';
    final queue = audioHandler.queue.value;
    final activeIndex = audioHandler.currentIndex;
    int targetPage = -1;
    if (activeIndex >= 0 &&
        activeIndex < queue.length &&
        queue[activeIndex].id == targetItemId) {
      targetPage = activeIndex;
    } else {
      targetPage = queue.indexWhere((it) => it.id == targetItemId);
    }
    if (targetPage == -1) return;

    // A media item/queue update from the outgoing track can arrive while a
    // swipe-triggered seek is still resolving. Don't animate the pager back to
    // that stale item; let the requested page settle first.
    final pendingPage = _pendingUserPage;
    if (pendingPage != null) {
      if (targetPage == pendingPage) {
        _pendingUserPage = null;
        _pendingUserPageFrom = null;
      } else {
        final outgoingIndex = _pendingUserPageFrom;
        final didAdvanceElsewhere =
            activeIndex == targetPage &&
            outgoingIndex != null &&
            activeIndex != outgoingIndex;
        if (!didAdvanceElsewhere) return;
        // The requested source may have failed and the player advanced to its
        // fallback. Follow that actual active item instead of leaving the UI
        // parked on the failed swipe target.
        _pendingUserPage = null;
        _pendingUserPageFrom = null;
      }
    }

    if (!_pageController.hasClients) return;

    // An animation to this exact page is already in progress. Protect it from
    // being aborted and restarted by secondary stream events (duration,
    // artwork cache, etc.) arriving mid-animation.
    if (_animatingTargetPage == targetPage) return;

    // No need to animate if we are already settled on the target page.
    if (_animatingTargetPage == null &&
        _pageController.page?.round() == targetPage) {
      return;
    }

    final currentPage = _pageController.page?.round();
    final distance = currentPage == null ? 0 : (currentPage - targetPage).abs();

    _animatingTargetPage = targetPage;
    _programmaticScrollCount++;
    try {
      if (_isVisible && distance <= 1) {
        // Neighbouring track: animate. Shuffle can jump hundreds of pages, which
        // would sweep through every album art in between, so those jump.
        await _pageController.animateToPage(
          targetPage,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      } else {
        _pageController.jumpToPage(targetPage);
      }
    } finally {
      if (_animatingTargetPage == targetPage) {
        _animatingTargetPage = null;
      }
      _programmaticScrollCount--;
    }
  }

  Future<void> _selectUserPage(int index) async {
    if (index == audioHandler.currentIndex) return;
    _pendingUserPageFrom ??= audioHandler.currentIndex;
    _pendingUserPage = index;
    try {
      await audioHandler.skipToQueueItem(index);
    } catch (_) {
      if (!mounted || _pendingUserPage != index) return;
      _pendingUserPage = null;
      _pendingUserPageFrom = null;
      _handleMediaItemChange(audioHandler.mediaItem.value);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _currentItemAndQueueSub?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    setState(() {
      _isVisible = state == AppLifecycleState.resumed;
    });
  }

  @override
  Widget build(BuildContext context) {
    final keyCounts = <String, int>{};
    final pageKeys = <Key>[];
    final keyToIndex = <Key, int>{};
    for (var index = 0; index < _queue.length; index++) {
      final id = _queue[index].id;
      final occurrence = keyCounts.update(
        id,
        (count) => count + 1,
        ifAbsent: () => 0,
      );
      final key = ValueKey<String>('$id#$occurrence');
      pageKeys.add(key);
      keyToIndex[key] = index;
    }

    return VisibilityDetector(
      key: const Key('big_album_art'),
      onVisibilityChanged: (VisibilityInfo info) {
        if (mounted) {
          setState(() {
            _isVisible = info.visibleFraction > 0.0;
          });
        }
      },
      child: GestureDetector(
        onVerticalDragUpdate: (DragUpdateDetails details) {
          if (details.delta.dy > 16) {
            Navigator.of(context).pop();
          }
        },
        child: Center(
          child: AspectRatio(
            aspectRatio: 1.0,
            child: PageView.builder(
              controller: _pageController,
              itemCount: _queue.length,
              findChildIndexCallback: (key) => keyToIndex[key],
              itemBuilder: (context, index) {
                final item = _queue[index];
                return ZoomableImage(
                  key: pageKeys[index],
                  url: _displayArtworkSource(item) ?? '',
                  caption: item.extras?['caption'] as String?,
                );
              },
              onPageChanged: (int index) {
                if (_programmaticScroll) return;
                if (index != audioHandler.currentIndex) {
                  unawaited(_selectUserPage(index));
                }
              },
            ),
          ),
        ),
      ),
    );
  }
}

//Top row containing QueueSource, queue...
class PlayerScreenTopRow extends StatelessWidget {
  final double? textSize;
  final double? iconSize;
  final double? textWidth;
  final bool? short;

  const PlayerScreenTopRow({
    super.key,
    this.textSize,
    this.iconSize,
    this.textWidth,
    this.short,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.max,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        IconButton(
          icon: const Icon(Icons.keyboard_arrow_down_sharp),
          iconSize: iconSize ?? ScreenUtil().setSp(52),
          splashRadius: iconSize ?? ScreenUtil().setWidth(52),
          onPressed: () async {
            // Navigate back
            Navigator.pop(context);
          },
        ),
        Expanded(
          child: SizedBox(
            width: textWidth ?? ScreenUtil().setWidth(800),
            child: Text(
              (short ?? false)
                  ? (GetIt.I<AudioPlayerHandler>().queueSource?.text ?? '')
                  : 'Playing from:'.i18n +
                        ' ' +
                        (GetIt.I<AudioPlayerHandler>().queueSource?.text ?? ''),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.left,
              style: TextStyle(fontSize: textSize ?? ScreenUtil().setSp(16)),
            ),
          ),
        ),
        Builder(
          builder: (buttonContext) => IconButton(
            icon: Icon(Icons.menu, semanticLabel: 'Queue'.i18n),
            iconSize: iconSize ?? ScreenUtil().setSp(52),
            splashRadius: iconSize ?? ScreenUtil().setWidth(52),
            onPressed: () async {
              SystemChrome.setSystemUIOverlayStyle(
                const SystemUiOverlayStyle(statusBarColor: Colors.transparent),
              );

              // Calculate the center of the icon safely
              Offset? buttonOffset;
              try {
                final RenderBox? buttonRenderBox =
                    buttonContext.findRenderObject() as RenderBox?;
                if (buttonRenderBox != null && buttonRenderBox.hasSize) {
                  buttonOffset = buttonRenderBox.localToGlobal(
                    buttonRenderBox.size.center(Offset.zero),
                  );
                }
              } catch (_) {}

              // Navigate
              await Navigator.of(context).push(
                CircularExpansionRoute(
                  widget: const QueueScreen(),
                  centerOffset: buttonOffset,
                ),
              );
              // Fix colors
              updateColor();
            },
          ),
        ),
      ],
    );
  }
}

class SeekBar extends StatefulWidget {
  final double relativeTextSize;
  final double horizontalPadding;
  const SeekBar(
    this.relativeTextSize, {
    this.horizontalPadding = 24,
    super.key,
  });

  @override
  _SeekBarState createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  AudioPlayerHandler audioHandler = GetIt.I<AudioPlayerHandler>();
  final FocusNode _sliderFocusNode = FocusNode(
    canRequestFocus: false,
    skipTraversal: true,
  );
  bool _seeking = false;
  double _pos = 0;

  @override
  void dispose() {
    _sliderFocusNode.dispose();
    super.dispose();
  }

  double get position {
    if (_seeking) return _pos;
    if (audioHandler.isRadio && audioHandler.hasRadioClock) {
      final p = audioHandler.syncedPosition.inMilliseconds.toDouble();
      final knownDuration = audioHandler.mediaItem.value?.duration;
      if (knownDuration != null &&
          knownDuration > Duration.zero &&
          p > knownDuration.inMilliseconds) {
        return knownDuration.inMilliseconds.toDouble();
      }
      return p;
    }
    double p = audioHandler.playbackState.value.position.inMilliseconds
        .toDouble();
    if (p > duration) return duration;
    return p;
  }

  //Duration to mm:ss or h:mm:ss
  String _timeString(double pos) {
    Duration d = Duration(milliseconds: pos.toInt());
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (d.inHours > 0) {
      return '${d.inHours}:${d.inMinutes.remainder(60).toString().padLeft(2, '0')}:$seconds';
    }
    return '${d.inMinutes}:$seconds';
  }

  double get duration {
    final item = audioHandler.mediaItem.value;
    if (item == null || item.duration == null) return 1.0;
    return item.duration!.inMilliseconds.toDouble();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: Stream.periodic(const Duration(milliseconds: 250)),
      builder: (BuildContext context, AsyncSnapshot snapshot) {
        final isRadio =
            audioHandler.isRadio ||
            AudioPlayerHandler.isRadioItem(audioHandler.mediaItem.value);
        if (isRadio && !audioHandler.hasRadioClock) {
          return const SizedBox.shrink();
        }
        final radioDuration = audioHandler.mediaItem.value?.duration;
        if (isRadio &&
            (radioDuration == null || radioDuration <= Duration.zero)) {
          return Padding(
            padding: EdgeInsets.symmetric(horizontal: widget.horizontalPadding),
            child: Text(
              _timeString(position),
              style: TextStyle(
                fontSize: ScreenUtil().setSp(widget.relativeTextSize),
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          );
        }

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: EdgeInsets.symmetric(
                vertical: 0.0,
                horizontal: widget.horizontalPadding,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: <Widget>[
                  Text(
                    _timeString(position),
                    style: TextStyle(
                      fontSize: ScreenUtil().setSp(widget.relativeTextSize),
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  Text(
                    _timeString(duration),
                    style: TextStyle(
                      fontSize: ScreenUtil().setSp(widget.relativeTextSize),
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 32.0,
              child: Slider(
                focusNode: _sliderFocusNode,
                value: position,
                max: duration,
                onChangeStart: isRadio
                    ? null
                    : (double d) {
                        setState(() {
                          _seeking = true;
                          _pos = d;
                        });
                      },
                onChanged: isRadio
                    ? null
                    : (double d) {
                        setState(() {
                          _pos = d;
                        });
                      },
                onChangeEnd: isRadio
                    ? null
                    : (double d) {
                        setState(() {
                          _pos = d;
                          _seeking = false;
                        });
                        audioHandler.seek(Duration(milliseconds: d.round()));
                      },
              ),
            ),
          ],
        );
      },
    );
  }
}

class QueueScreen extends StatefulWidget {
  const QueueScreen({super.key});

  @override
  _QueueScreenState createState() => _QueueScreenState();
}

class _QueueScreenState extends State<QueueScreen> with WidgetsBindingObserver {
  static const double _queueItemExtent = 64;
  AudioPlayerHandler audioHandler = GetIt.I<AudioPlayerHandler>();
  late StreamSubscription _queueStateSub;
  late ScrollController _scrollController;
  int? _previousMediaItemIndex;
  List<MediaItem>? _previousQueue;
  AudioServiceShuffleMode? _previousShuffleMode;
  AudioServiceRepeatMode? _previousRepeatMode;
  bool _loadingMore = false;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _scrollController.addListener(_maybeLoadMoreQueue);
    _queueStateSub = audioHandler.queueStateStream.listen((queueState) {
      if (!mounted) return;
      final indexChanged = queueState.queueIndex != _previousMediaItemIndex;
      final listChanged = !identical(queueState.queue, _previousQueue);
      final modesChanged =
          queueState.shuffleMode != _previousShuffleMode ||
          queueState.repeatMode != _previousRepeatMode;
      _previousQueue = queueState.queue;
      _previousShuffleMode = queueState.shuffleMode;
      _previousRepeatMode = queueState.repeatMode;
      _previousMediaItemIndex = queueState.queueIndex;
      if (listChanged || indexChanged || modesChanged) setState(() {});
      if (listChanged) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _maybeLoadMoreQueue();
        });
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _scrollToCurrentItem();
        _maybeLoadMoreQueue();
      }
    });
  }

  @override
  void dispose() {
    _queueStateSub.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToCurrentItem() {
    final queueState = audioHandler.queueState;
    final currentIndex = queueState.queueIndex ?? 0;
    final displayIndex = queueState.shuffleMode == AudioServiceShuffleMode.all
        ? queueState.indices.indexOf(currentIndex)
        : currentIndex;
    final targetIndex = displayIndex < 0 ? currentIndex : displayIndex;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final target = (targetIndex * _queueItemExtent).clamp(
        0.0,
        _scrollController.position.maxScrollExtent,
      );
      if ((_scrollController.offset - target).abs() > 1) {
        _scrollController.jumpTo(target);
      }
    });
  }

  Future<void> _maybeLoadMoreQueue() async {
    if (_loadingMore ||
        !audioHandler.canLoadMoreQueue ||
        !_scrollController.hasClients) {
      return;
    }
    final position = _scrollController.position;
    if (position.maxScrollExtent - position.pixels >
        position.viewportDimension * 1.25) {
      return;
    }

    setState(() => _loadingMore = true);
    try {
      await audioHandler.loadMoreQueueItems();
    } finally {
      if (mounted) {
        setState(() => _loadingMore = false);
      }
    }
  }

  int _queueIndexAt(int displayIndex, QueueState queueState) {
    if (queueState.shuffleMode != AudioServiceShuffleMode.all) {
      return displayIndex;
    }
    return queueState.indices[displayIndex];
  }

  @override
  Widget build(BuildContext context) {
    final queueState = audioHandler.queueState;
    final showPlatformBadges = _queueHasMixedPlatforms(queueState.queue);
    final shuffleModeEnabled =
        queueState.shuffleMode == AudioServiceShuffleMode.all;

    return Scaffold(
      appBar: FreezerAppBar(
        'Queue'.i18n,
        actions: <Widget>[
          if (_loadingMore ||
              audioHandler.isLoadingMoreQueue ||
              audioHandler.isPreparingQueueForShuffle)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),

          Padding(
            padding: const EdgeInsets.fromLTRB(0, 4, 0, 0),
            child: IconButton(
              icon: Icon(
                Icons.shuffle,
                semanticLabel: 'Shuffle'.i18n,
                color: shuffleModeEnabled
                    ? Theme.of(context).primaryColor
                    : null,
              ),
              onPressed: audioHandler.isPreparingQueueForShuffle
                  ? null
                  : () async {
                      final request = audioHandler.toggleShuffle();
                      if (mounted) setState(() {});
                      await request;
                      if (mounted) setState(() {});
                    },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 4, 16, 0),
            child: IconButton(
              icon: Icon(Icons.close, semanticLabel: 'Clear all'.i18n),
              onPressed: () async {
                final navigator = Navigator.of(context);
                await audioHandler.clearQueue();
                if (navigator.mounted) {
                  navigator.pop(); // Close queue screen.
                  if (navigator.canPop()) {
                    navigator.pop(); // Close player screen.
                  }
                }
              },
            ),
          ),
        ],
      ),
      body: ListTileTheme(
        data: ListTileTheme.of(
          context,
        ).copyWith(minVerticalPadding: 0, visualDensity: VisualDensity.compact),
        child: SilkyScroll.fromConfig(
          config: silkyScrollConfig,
          controller: _scrollController,
          builder: (context, controller, physics, _) => shuffleModeEnabled
              ? ListView.builder(
                  controller: controller,
                  physics: physics,
                  padding: EdgeInsets.zero,
                  itemExtent: _queueItemExtent,
                  itemCount: queueState.queue.length,
                  itemBuilder: (context, index) {
                    final queueIndex = _queueIndexAt(index, queueState);
                    final mediaItem = queueState.queue[queueIndex];
                    final track = Track.fromMediaItem(mediaItem);
                    return TrackTile(
                      track,
                      showPlatformBadge: showPlatformBadges,
                      onTap: () async {
                        await audioHandler.skipToQueueItem(queueIndex);
                        if (context.mounted) Navigator.of(context).pop();
                      },
                      key: Key('${mediaItem.id}:$queueIndex'),
                      trailing: IconButton(
                        icon: Icon(Icons.close, semanticLabel: 'Close'.i18n),
                        onPressed: () async {
                          await audioHandler.removeQueueItem(mediaItem);
                        },
                      ),
                    );
                  },
                )
              : ReorderableListView.builder(
                  scrollController: controller,
                  physics: physics,
                  padding: EdgeInsets.zero,
                  itemExtent: _queueItemExtent,
                  itemCount: queueState.queue.length,
                  onReorderItem: (int oldIndex, int newIndex) async {
                    if (newIndex > oldIndex) newIndex -= 1;
                    if (oldIndex == newIndex) return;
                    await audioHandler.moveQueueItem(oldIndex, newIndex);
                  },
                  itemBuilder: (context, index) {
                    final queueIndex = _queueIndexAt(index, queueState);
                    final mediaItem = queueState.queue[queueIndex];
                    final track = Track.fromMediaItem(mediaItem);
                    return TrackTile(
                      track,
                      showPlatformBadge: showPlatformBadges,
                      onTap: () async {
                        await audioHandler.skipToQueueItem(queueIndex);
                        if (context.mounted) Navigator.of(context).pop();
                      },
                      key: Key('${mediaItem.id}:$queueIndex'),
                      trailing: IconButton(
                        icon: Icon(Icons.close, semanticLabel: 'Close'.i18n),
                        onPressed: () async {
                          await audioHandler.removeQueueItem(mediaItem);
                        },
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }
}

class QueueScreenNoDRG extends StatefulWidget {
  const QueueScreenNoDRG({super.key});

  @override
  _QueueScreenNoDRGState createState() => _QueueScreenNoDRGState();
}

class _QueueScreenNoDRGState extends State<QueueScreenNoDRG> {
  AudioPlayerHandler audioHandler = GetIt.I<AudioPlayerHandler>();
  late StreamSubscription _queueStateSub;

  @override
  void initState() {
    super.initState();
    _queueStateSub = audioHandler.queueStateStream.listen((queueState) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _queueStateSub.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final queueState = audioHandler.queueState;
    final showPlatformBadges = _queueHasMixedPlatforms(queueState.queue);

    return Scaffold(
      appBar: FreezerAppBar('Queue'.i18n),
      body: ListTileTheme(
        data: ListTileTheme.of(
          context,
        ).copyWith(minVerticalPadding: 0, visualDensity: VisualDensity.compact),
        child: SilkyListView.builder(
          silkyConfig: silkyScrollConfig,
          padding: EdgeInsets.zero,
          itemCount: queueState.queue.length,
          itemBuilder: (context, index) {
            final mediaItem = queueState.queue[index];
            final track = Track.fromMediaItem(mediaItem);
            return TrackTile(
              track,
              showPlatformBadge: showPlatformBadges,
              onTap: () async {
                await audioHandler.skipToQueueItem(index);
                if (context.mounted) Navigator.of(context).pop();
              },
              key: Key(mediaItem.id),
              trailing: IconButton(
                icon: Icon(Icons.close, semanticLabel: 'Close'.i18n),
                onPressed: () async {
                  await audioHandler.removeQueueItem(mediaItem);
                },
              ),
            );
          },
        ),
      ),
    );
  }
}
