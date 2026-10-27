import 'dart:ui';
import 'dart:async';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';

import '../service/audio_service.dart';
import '../router/app_router.dart';
import '../settings.dart';
import '../translations.i18n.dart';
import 'cached_image.dart';
import 'player_screen.dart';
import 'play_pause_button.dart';
import '../utils/seasonal_track_matcher.dart';

export 'play_pause_button.dart';

bool get _isDesktopPlatform =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux);

class PlayerBar extends StatefulWidget {
  const PlayerBar({super.key});

  @override
  PlayerBarState createState() => PlayerBarState();
}

class PlayerBarState extends State<PlayerBar> {
  final double iconSize = 28;
  ImageProvider? _blurImage;
  LinearGradient? _bgGradient;
  Color scaffoldBackgroundColor = Colors.black;
  AudioPlayerHandler audioHandler = GetIt.I<AudioPlayerHandler>();
  StreamSubscription? _mediaItemSub;
  String? _lastPaletteSource;
  int _paletteRequestId = 0;
  late final FocusNode _focusNode;

  double get _progress {
    if (audioHandler.playbackState.value.processingState ==
        AudioProcessingState.idle) {
      return 0.0;
    }
    final item = audioHandler.mediaItem.value;
    final dur = item?.duration;
    if (dur == null || dur.inMilliseconds == 0) {
      return 0.0; // Avoid division by 0 and null pointer exception
    }
    if (audioHandler.isRadio && !audioHandler.hasRadioClock) {
      return 0.0;
    }
    final pos = audioHandler.isRadio
        ? audioHandler.syncedPosition
        : audioHandler.playbackState.value.position;
    return (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0);
  }

  Future<void> _updateBackground() async {
    final item = audioHandler.mediaItem.value;
    if (item == null) return;
    if (!settings.colorGradientBackground && !settings.blurPlayerBackground) {
      return;
    }
    final source = item.extras?['thumb'] ?? item.artUri?.toString();
    if (source == null || source.isEmpty || source == _lastPaletteSource) {
      return;
    }
    _lastPaletteSource = source;
    final requestId = ++_paletteRequestId;

    // Load image for blur background
    if (settings.blurPlayerBackground) {
      setState(() {
        _blurImage = imageProviderForSource(source);
      });
    }

    // Generate a color palette from the image
    final palette = await imagesDatabase.getPaletteGenerator(source);
    if (!mounted || requestId != _paletteRequestId) return;

    // Set gradient based on the dominant color
    setState(() {
      _bgGradient = LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [
          palette.dominantColor?.color.withValues(alpha: 0.7) ?? Colors.black,
          Colors.transparent,
        ],
        stops: const [0.0, 0.6],
      );
    });
  }

  void _handleFocusChange() {
    if (mounted) setState(() {});
  }

  void updateBackground() {
    _updateBackground();
  }

  late final Stream<MediaItem?> _displayItemStream = audioHandler.mediaItem
      .distinct(mediaItemDisplayEquals);

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    _focusNode.addListener(_handleFocusChange);
    _mediaItemSub = audioHandler.mediaItem.listen((event) {
      if (event == null) return;
      final source = event.extras?['thumb'] ?? event.artUri?.toString();
      if (source != _lastPaletteSource) updateBackground();
    });

    updateColor = _updateBackground;
    // Only register if not already registered (prevents duplicate during layout transitions)
    if (!GetIt.I.isRegistered<PlayerBarState>()) {
      GetIt.I.registerSingleton<PlayerBarState>(this);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    updateBackground();
  }

  @override
  void dispose() {
    super.dispose();
    _mediaItemSub?.cancel();
    _focusNode.removeListener(_handleFocusChange);
    _focusNode.dispose();
    // Only unregister if this instance is the registered one
    if (GetIt.I.isRegistered<PlayerBarState>() &&
        GetIt.I.get<PlayerBarState>() == this) {
      GetIt.I.unregister<PlayerBarState>();
    }
  }

  @override
  Widget build(BuildContext context) {
    final useDesktopLayout =
        _isDesktopPlatform && MediaQuery.sizeOf(context).width >= 900;

    return Stack(
      children: [
        // Blur background image
        if (settings.themeAdditonalItems &&
            settings.blurPlayerBackground &&
            _blurImage != null)
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: SizedBox(
              height: 100.0,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Container(
                      color: Theme.of(context).bottomAppBarTheme.color,
                    ),
                  ),
                  if (_blurImage != null)
                    ClipRect(
                      child: Container(
                        decoration: BoxDecoration(
                          image: DecorationImage(
                            image: _blurImage!,
                            fit: BoxFit.cover,
                            colorFilter: ColorFilter.mode(
                              Colors.black.withValues(alpha: 0.25),
                              BlendMode.dstATop,
                            ),
                          ),
                        ),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                          child: Container(color: Colors.transparent),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),

        // Gradient overlay
        if (settings.themeAdditonalItems &&
            !settings.blurPlayerBackground &&
            settings.colorGradientBackground &&
            _bgGradient != null)
          Positioned.fill(
            child: Container(decoration: BoxDecoration(gradient: _bgGradient)),
          ),

        StreamBuilder<MediaItem?>(
          stream: _displayItemStream,
          initialData: audioHandler.mediaItem.valueOrNull,
          builder: (context, snapshot) {
            final season = settings.eastereggsDisabled
                ? null
                : seasonalEffectForTrack(snapshot.data);
            final activeSeason =
                seasonalEffectIsInDateWindow(season, DateTime.now())
                ? season
                : null;
            return Positioned.fill(
              child: IgnorePointer(
                // Keep the animation state mounted while tracks change. If the
                // effect widget is removed between stream events its ticker
                // restarts at zero and falling decorations visibly jump.
                child: _PlayerBarSeasonalDecoration(season: activeSeason),
              ),
            );
          },
        ),

        GestureDetector(
          onHorizontalDragEnd: useDesktopLayout
              ? null
              : (DragEndDetails details) async {
                  if ((details.primaryVelocity ?? 0) < -100) {
                    // Swiped left
                    await audioHandler.skipToPrevious();
                  } else if ((details.primaryVelocity ?? 0) > 100) {
                    // Swiped right
                    await audioHandler.skipToNext();
                  }
                },
          onVerticalDragEnd: useDesktopLayout
              ? null
              : (DragEndDetails details) async {
                  if ((details.primaryVelocity ?? 0) < -100) {
                    // Swiped up
                    openPlayerScreen();
                    SystemChrome.setSystemUIOverlayStyle(
                      SystemUiOverlayStyle(
                        systemNavigationBarColor:
                            settings.themeData.scaffoldBackgroundColor,
                      ),
                    );
                  }
                },
          child: StreamBuilder(
            stream: _displayItemStream,
            initialData: audioHandler.mediaItem.valueOrNull,
            builder: (BuildContext context, AsyncSnapshot snapshot) {
              if (audioHandler.mediaItem.value == null) {
                return const SizedBox.shrink();
              }

              if (useDesktopLayout) {
                return _buildDesktopBar(context, audioHandler.mediaItem.value!);
              }

              return Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Container(
                    color: _focusNode.hasFocus
                        ? Colors.black26
                        : settings.themeAdditonalItems
                        ? Colors.transparent
                        : Theme.of(context).bottomAppBarTheme.color,
                    child: ListTile(
                      dense: true,
                      focusNode: _focusNode,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8.0,
                      ),
                      onTap: () {
                        openPlayerScreen();
                        SystemChrome.setSystemUIOverlayStyle(
                          SystemUiOverlayStyle(
                            systemNavigationBarColor:
                                settings.themeData.scaffoldBackgroundColor,
                          ),
                        );
                      },
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(4.0),
                        child: AspectRatio(
                          aspectRatio: 1.0,
                          child: CachedImage(
                            width: 50,
                            height: 50,
                            url:
                                audioHandler
                                    .mediaItem
                                    .value
                                    ?.extras?['thumb'] ??
                                audioHandler.mediaItem.value?.artUri
                                    ?.toString() ??
                                '',
                          ),
                        ),
                      ),
                      title: Text(
                        audioHandler.mediaItem.value?.displayTitle ?? '',
                        overflow: TextOverflow.clip,
                        maxLines: 1,
                      ),
                      subtitle: Text(
                        audioHandler.mediaItem.value?.displaySubtitle ?? '',
                        overflow: TextOverflow.clip,
                        maxLines: 1,
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          if (!audioHandler.isRadio &&
                              !AudioPlayerHandler.isRadioItem(
                                audioHandler.mediaItem.value,
                              ))
                            PrevNextButton(
                              iconSize,
                              prev: true,
                              hidePrev: true,
                            ),
                          PlayPauseButton(iconSize),
                          if (!audioHandler.isRadio &&
                              !AudioPlayerHandler.isRadioItem(
                                audioHandler.mediaItem.value,
                              ))
                            PrevNextButton(iconSize),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(
                    height: 3.0,
                    child: StreamBuilder(
                      stream: Stream.periodic(
                        const Duration(milliseconds: 250),
                      ),
                      builder: (context, _) {
                        final duration = audioHandler.mediaItem.value?.duration;
                        if (audioHandler.isRadio &&
                            (!audioHandler.hasRadioClock ||
                                duration == null ||
                                duration <= Duration.zero)) {
                          return const SizedBox.shrink();
                        }
                        return LinearProgressIndicator(
                          color: Theme.of(context).primaryColor,
                          backgroundColor: Theme.of(
                            context,
                          ).primaryColor.withValues(alpha: 0.1),
                          value: _progress,
                        );
                      },
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildDesktopBar(BuildContext context, MediaItem item) {
    final foreground = Theme.of(context).colorScheme.onSurface;
    final transport =
        AudioPlayerHandler.isRadioItem(item) || audioHandler.isRadio;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          focusNode: _focusNode,
          onTap: () {
            openPlayerScreen();
            SystemChrome.setSystemUIOverlayStyle(
              SystemUiOverlayStyle(
                systemNavigationBarColor:
                    settings.themeData.scaffoldBackgroundColor,
              ),
            );
          },
          child: Container(
            height: 64,
            color: _focusNode.hasFocus
                ? Colors.black26
                : settings.themeAdditonalItems
                ? Colors.transparent
                : Theme.of(context).bottomAppBarTheme.color,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Expanded(
                  flex: 4,
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: CachedImage(
                          width: 48,
                          height: 48,
                          url:
                              item.extras?['thumb'] ??
                              item.artUri?.toString() ??
                              '',
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.displayTitle ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 15),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              item.displaySubtitle ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                color: foreground.withValues(alpha: 0.82),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (!transport) PrevNextButton(iconSize, prev: true),
                      PlayPauseButton(iconSize),
                      if (!transport) PrevNextButton(iconSize),
                    ],
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      StreamBuilder(
                        stream: audioHandler.playbackState,
                        builder: (context, _) {
                          final position =
                              audioHandler.isRadio && audioHandler.hasRadioClock
                              ? audioHandler.syncedPosition
                              : audioHandler.playbackState.value.position;
                          return Text(
                            _formatPosition(position),
                            style: const TextStyle(
                              fontFeatures: [FontFeature.tabularFigures()],
                            ).copyWith(color: foreground),
                          );
                        },
                      ),
                      const SizedBox(width: 12),
                      const Flexible(child: QualityInfoWidget()),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                const DesktopVolumeControl(),
              ],
            ),
          ),
        ),
        SizedBox(
          height: 4,
          child: LayoutBuilder(
            builder: (context, constraints) => GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: transport || item.duration == null
                  ? null
                  : (details) => _seekFromProgress(
                      details.localPosition.dx,
                      constraints.maxWidth,
                      item.duration!,
                    ),
              onHorizontalDragUpdate: transport || item.duration == null
                  ? null
                  : (details) => _seekFromProgress(
                      details.localPosition.dx,
                      constraints.maxWidth,
                      item.duration!,
                    ),
              child: StreamBuilder(
                stream: Stream.periodic(const Duration(milliseconds: 250)),
                builder: (context, _) {
                  final duration = item.duration;
                  if (transport &&
                      (!audioHandler.hasRadioClock ||
                          duration == null ||
                          duration <= Duration.zero)) {
                    return const SizedBox.shrink();
                  }
                  return LinearProgressIndicator(
                    minHeight: 4,
                    color: Theme.of(context).primaryColor,
                    backgroundColor: Theme.of(
                      context,
                    ).primaryColor.withValues(alpha: 0.1),
                    value: _progress,
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }

  String _formatPosition(Duration position) {
    final minutes = position.inMinutes;
    final seconds = position.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  void _seekFromProgress(double offset, double width, Duration duration) {
    if (width <= 0 || duration <= Duration.zero) return;
    final progress = (offset / width).clamp(0.0, 1.0);
    unawaited(
      audioHandler.seek(
        Duration(milliseconds: (duration.inMilliseconds * progress).round()),
      ),
    );
  }
}

class _PlayerBarSeasonalDecoration extends StatefulWidget {
  final SeasonalTrackEffect? season;

  const _PlayerBarSeasonalDecoration({required this.season});

  @override
  State<_PlayerBarSeasonalDecoration> createState() =>
      _PlayerBarSeasonalDecorationState();
}

class _PlayerBarSeasonalDecorationState
    extends State<_PlayerBarSeasonalDecoration>
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
  void didUpdateWidget(covariant _PlayerBarSeasonalDecoration oldWidget) {
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
        painter: _PlayerBarSeasonalPainter(
          widget.season,
          _clock.elapsedMicroseconds / 1000000,
        ),
        size: Size.infinite,
      ),
    ),
  );
}

class _PlayerBarSeasonalPainter extends CustomPainter {
  final SeasonalTrackEffect? season;
  final double timeSeconds;

  const _PlayerBarSeasonalPainter(this.season, this.timeSeconds);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    if (season == null) return;
    if (season == SeasonalTrackEffect.christmas) {
      _paintSnow(canvas, size);
      _paintChristmasLights(canvas, size);
    } else {
      _paintHalloweenDetails(canvas, size);
    }
  }

  void _paintChristmasLights(Canvas canvas, Size size) {
    final droops = (size.width / 380).ceil().clamp(1, 6).toInt();
    final layoutSeed =
        (size.width.round() * 31 + size.height.round()) & 0x7fffffff;
    final layoutRandom = math.Random(layoutSeed);
    final baseBulbs = (size.width / 105).round().clamp(4, 18).toInt();
    final bulbs = (baseBulbs - 1 + layoutRandom.nextInt(3))
        .clamp(4, 18)
        .toInt();
    final segmentWidth = size.width / droops;
    const top = 1.5;
    final sag = (segmentWidth * 0.06).clamp(5.0, 10.0).toDouble();
    final wire = Path()..moveTo(0, top);
    for (var i = 0; i < droops; i++) {
      final x = segmentWidth * i;
      wire.cubicTo(
        x + segmentWidth * 0.25,
        top + sag,
        x + segmentWidth * 0.75,
        top + sag,
        x + segmentWidth,
        top,
      );
    }
    canvas.drawPath(
      wire,
      Paint()
        ..color = const Color(0xFF52705B).withValues(alpha: 0.42)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
    const colors = [
      Color(0xFFFF626B),
      Color(0xFFFFD166),
      Color(0xFF73D99A),
      Color(0xFF74C9FF),
    ];
    for (var i = 0; i < bulbs; i++) {
      final globalT = (i + 0.5) / bulbs;
      final position = globalT * droops;
      final segment = math.min(position.floor(), droops - 1).toInt();
      final t = position - segment;
      final inverseT = 1 - t;
      final x0 = segmentWidth * segment;
      final x1 = segmentWidth * (segment + 1);
      final x =
          inverseT * inverseT * inverseT * x0 +
          3 * inverseT * inverseT * t * (x0 + segmentWidth * 0.25) +
          3 * inverseT * t * t * (x0 + segmentWidth * 0.75) +
          t * t * t * x1;
      final y =
          inverseT * inverseT * inverseT * top +
          3 * inverseT * inverseT * t * (top + sag) +
          3 * inverseT * t * t * (top + sag) +
          t * t * t * top;
      final phaseOffset = i.isEven ? 0.0 : math.pi;
      final phase = (math.sin(timeSeconds * 5.2 + phaseOffset) + 1) / 2;
      final glowStrength = 0.12 + 0.88 * phase * phase;
      final color = colors[i % colors.length];
      final bulb = Path()
        ..moveTo(x - 2, y + 2)
        ..quadraticBezierTo(x - 3.5, y + 5, x, y + 8)
        ..quadraticBezierTo(x + 3.5, y + 5, x + 2, y + 2)
        ..close();
      canvas.drawPath(
        bulb,
        Paint()..color = color.withValues(alpha: 0.30 + 0.60 * glowStrength),
      );
      final glow = Rect.fromCircle(
        center: Offset(x, y + 5),
        radius: 8 * glowStrength,
      );
      canvas.drawRect(
        glow,
        Paint()
          ..shader = RadialGradient(
            colors: [
              color.withValues(alpha: 0.30 * glowStrength),
              color.withValues(alpha: 0),
            ],
          ).createShader(glow),
      );
    }
  }

  void _paintHalloweenDetails(Canvas canvas, Size size) {
    // Match the full player: cobwebs sit in both upper corners and stay
    // clipped to the player bar's own bounds.
    final webRadius = math.min(54.0, size.height * 0.82);
    _paintCobweb(canvas, Offset.zero, webRadius, flipX: false);
    _paintCobweb(canvas, Offset(size.width, 0), webRadius, flipX: true);
    final batPaint = Paint()
      ..color = const Color(0xFF28182B).withValues(alpha: 0.34);
    final layoutSeed = size.width.round() * 31 + size.height.round();
    final random = math.Random(layoutSeed & 0x7fffffff);
    final baseCount = (size.width / 180).round().clamp(5, 10).toInt();
    final count = (baseCount + random.nextInt(3)).clamp(5, 12).toInt();
    for (var i = 0; i < count; i++) {
      final xSeed = random.nextDouble();
      final ySeed = random.nextDouble();
      final swayPhase = random.nextDouble() * math.pi * 2;
      final swayAmplitude = 4 + random.nextDouble() * 10;
      final fallDuration = 3.5 + random.nextDouble() * 9;
      final scale = 0.30 + random.nextDouble() * 0.25;
      final kind = random.nextDouble();
      const verticalMargin = 18.0;
      final fallDistance = size.height + verticalMargin * 2;
      final x =
          (xSeed * size.width +
              math.sin(timeSeconds * 0.62 + swayPhase) * swayAmplitude +
              size.width) %
          size.width;
      final y =
          ((ySeed + timeSeconds / fallDuration) % 1).toDouble() * fallDistance -
          verticalMargin;
      canvas.save();
      canvas.translate(x, y);
      canvas.scale(scale);
      if (i == 0 || kind < 0.32) {
        _drawMiniPumpkin(canvas);
      } else {
        _drawBat(canvas, batPaint);
      }
      canvas.restore();
    }
  }

  void _paintCobweb(
    Canvas canvas,
    Offset corner,
    double radius, {
    required bool flipX,
  }) {
    final sign = flipX ? -1.0 : 1.0;
    final paint = Paint()
      ..color = const Color(0xFFE6D8EE).withValues(alpha: 0.42)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;
    for (var ray = 0; ray <= 4; ray++) {
      final angle = ray * math.pi / 8;
      canvas.drawLine(
        corner,
        corner +
            Offset(math.cos(angle) * radius * sign, math.sin(angle) * radius),
        paint,
      );
    }
    for (var ring = 1; ring <= 3; ring++) {
      final r = radius * ring / 3;
      final path = Path();
      for (var ray = 0; ray <= 4; ray++) {
        final angle = ray * math.pi / 8;
        final point =
            corner + Offset(math.cos(angle) * r * sign, math.sin(angle) * r);
        if (ray == 0) {
          path.moveTo(point.dx, point.dy);
        } else {
          path.quadraticBezierTo(
            corner.dx + math.cos(angle - math.pi / 16) * r * 0.92 * sign,
            corner.dy + math.sin(angle - math.pi / 16) * r * 0.92,
            point.dx,
            point.dy,
          );
        }
      }
      canvas.drawPath(path, paint);
    }
  }

  void _paintSnow(Canvas canvas, Size size) {
    final layoutSeed =
        (size.width.round() * 31 + size.height.round()) & 0x7fffffff;
    final random = math.Random(layoutSeed);
    final baseCount = (size.width / 52).ceil().clamp(8, 24).toInt();
    final count = (baseCount - 1 + random.nextInt(3)).clamp(8, 24).toInt();
    final snowPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.30)
      ..strokeWidth = 0.8
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < count; i++) {
      final xSeed = random.nextDouble();
      final ySeed = random.nextDouble();
      final swayPhase = random.nextDouble() * math.pi * 2;
      final swayAmplitude = 4 + random.nextDouble() * 8;
      final fallDuration = 4 + random.nextDouble() * 10;
      final radius = 0.7 + random.nextDouble() * 1.05;
      const verticalMargin = 5.0;
      final fallDistance = size.height + verticalMargin * 2;
      final sway = math.sin(timeSeconds * 0.7 + swayPhase) * swayAmplitude;
      final x = (xSeed * size.width + sway + size.width) % size.width;
      final y =
          ((ySeed + timeSeconds / fallDuration) % 1).toDouble() * fallDistance -
          verticalMargin;
      canvas.drawCircle(Offset(x, y), radius, snowPaint);
      if (random.nextDouble() < 0.17) {
        _drawSnowflake(canvas, Offset(x, y), radius * 1.6, snowPaint);
      }
    }
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

  void _drawMiniPumpkin(Canvas canvas) {
    canvas.drawOval(
      Rect.fromCenter(center: Offset.zero, width: 34, height: 25),
      Paint()..color = const Color(0xFFF47720).withValues(alpha: 0.65),
    );
    canvas.drawLine(
      const Offset(-7, -10),
      const Offset(-8, 10),
      Paint()
        ..color = const Color(0xFFFFC15B).withValues(alpha: 0.65)
        ..strokeWidth = 1.5,
    );
    final stem = Path()
      ..moveTo(-2, -11)
      ..quadraticBezierTo(-4, -18, 2, -18)
      ..lineTo(4, -17)
      ..lineTo(2, -10)
      ..close();
    canvas.drawPath(stem, Paint()..color = const Color(0xFF69864C));
    final face = Path()
      ..moveTo(-10, -4)
      ..lineTo(-5, 0)
      ..lineTo(-10, 3)
      ..close()
      ..moveTo(10, -4)
      ..lineTo(5, 0)
      ..lineTo(10, 3)
      ..close()
      ..moveTo(-9, 6)
      ..lineTo(-5, 4)
      ..lineTo(-2, 7)
      ..lineTo(2, 4)
      ..lineTo(5, 7)
      ..lineTo(9, 6)
      ..quadraticBezierTo(0, 12, -9, 6)
      ..close();
    canvas.drawPath(face, Paint()..color = const Color(0xFFFFE28A));
  }

  @override
  bool shouldRepaint(covariant _PlayerBarSeasonalPainter oldDelegate) =>
      oldDelegate.season != season || oldDelegate.timeSeconds != timeSeconds;
}

class DesktopVolumeControl extends StatelessWidget {
  const DesktopVolumeControl({super.key});

  @override
  Widget build(BuildContext context) {
    final player = GetIt.I<AudioPlayerHandler>().player;
    return StreamBuilder<double>(
      stream: player.volumeStream,
      initialData: player.volume,
      builder: (context, snapshot) {
        final volume = (snapshot.data ?? 1.0).clamp(0.0, 1.0);
        return SizedBox(
          width: 230,
          child: Row(
            children: [
              IconButton(
                tooltip: volume == 0 ? 'Unmute' : 'Mute',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 28,
                  height: 28,
                ),
                icon: Icon(
                  volume == 0 ? Icons.volume_off : Icons.volume_up,
                  size: 21,
                ),
                onPressed: () {
                  player.setVolume(volume == 0 ? 1 : 0);
                },
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 2,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 5,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 10,
                    ),
                  ),
                  child: Slider(
                    value: volume,
                    onChanged: (value) {
                      player.setVolume(value);
                    },
                  ),
                ),
              ),
              SizedBox(
                width: 42,
                child: Text(
                  '${(volume * 100).round()}%',
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class PrevNextButton extends StatelessWidget {
  final double size;
  final bool prev;
  final bool hidePrev;

  const PrevNextButton(
    this.size, {
    super.key,
    this.prev = false,
    this.hidePrev = false,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: GetIt.I<AudioPlayerHandler>().queueStateStream,
      builder: (context, snapshot) {
        final queueState = snapshot.data;
        if (!prev) {
          final hasNext = queueState?.hasNext ?? false;
          return IconButton(
            icon: Icon(Icons.skip_next, semanticLabel: 'Play next'.i18n),
            iconSize: size,
            onPressed: hasNext
                ? () => GetIt.I<AudioPlayerHandler>().skipToNext()
                : null,
          );
        }
        if (prev) {
          final hasPrevious = queueState?.hasPrevious ?? false;
          if (!hasPrevious && hidePrev) {
            return const SizedBox(height: 0, width: 0);
          }
          return IconButton(
            icon: Icon(
              Icons.skip_previous,
              semanticLabel: 'Play previous'.i18n,
            ),
            iconSize: size,
            onPressed: hasPrevious
                ? () => GetIt.I<AudioPlayerHandler>().skipToPrevious()
                : null,
          );
        }
        return Container();
      },
    );
  }
}
