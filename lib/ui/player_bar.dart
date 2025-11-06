import 'dart:ui';
import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:get_it/get_it.dart';

import '../service/audio_service.dart';
import '../settings.dart';
import '../translations.i18n.dart';
import '../ui/router.dart';
import 'cached_image.dart';
import 'player_screen.dart';

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

  double get _progress {
    if (audioHandler.playbackState.value.processingState ==
        AudioProcessingState.idle) {
      return 0.0;
    }
    if (audioHandler.mediaItem.value == null) {
      return 0.0;
    }
    if (audioHandler.mediaItem.value!.duration!.inSeconds == 0) {
      return 0.0; // Avoid division by 0
    }
    return audioHandler.playbackState.value.position.inSeconds /
        audioHandler.mediaItem.value!.duration!.inSeconds;
  }

  Future<void> _updateBackground() async {
    if (audioHandler.mediaItem.value == null) return;

    // Load image for blur background
    if (settings.blurPlayerBackground) {
      setState(() {
        _blurImage = CachedNetworkImageProvider(
          audioHandler.mediaItem.value?.extras?['thumb'] ??
              audioHandler.mediaItem.value?.artUri,
        );
      });
    }

    // Generate a color palette from the image
    PaletteGenerator palette = await PaletteGenerator.fromImageProvider(
      CachedNetworkImageProvider(
        audioHandler.mediaItem.value?.extras?['thumb'] ??
            audioHandler.mediaItem.value?.artUri,
      ),
    );

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

  void updateBackground() {
    _updateBackground();
  }

  @override
  void initState() {
    super.initState();
    _mediaItemSub = audioHandler.mediaItem.listen((event) {
      updateBackground();
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
    // Only unregister if this instance is the registered one
    if (GetIt.I.isRegistered<PlayerBarState>() && 
        GetIt.I.get<PlayerBarState>() == this) {
      GetIt.I.unregister<PlayerBarState>();
    }
  }

  @override
  Widget build(BuildContext context) {
    var focusNode = FocusNode();

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

        GestureDetector(
          key: UniqueKey(),
          onHorizontalDragEnd: (DragEndDetails details) async {
            if ((details.primaryVelocity ?? 0) < -100) {
              // Swiped left
              await audioHandler.skipToPrevious();
            } else if ((details.primaryVelocity ?? 0) > 100) {
              // Swiped right
              await audioHandler.skipToNext();
            }
          },
          onVerticalDragEnd: (DragEndDetails details) async {
            if ((details.primaryVelocity ?? 0) < -100) {
              // Swiped up
              Navigator.of(
                context,
              ).push(SlideBottomRoute(widget: const PlayerScreen()));
              SystemChrome.setSystemUIOverlayStyle(
                SystemUiOverlayStyle(
                  systemNavigationBarColor:
                      settings.themeData.scaffoldBackgroundColor,
                ),
              );
            }
          },
          child: StreamBuilder(
            stream: Stream.periodic(const Duration(milliseconds: 250)),
            builder: (BuildContext context, AsyncSnapshot snapshot) {
              if (audioHandler.mediaItem.value == null) {
                return const SizedBox.shrink();
              }

              return Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Container(
                    color: focusNode.hasFocus
                        ? Colors.black26
                        : settings.themeAdditonalItems
                        ? Colors.transparent
                        : Theme.of(context).bottomAppBarTheme.color,
                    child: ListTile(
                      dense: true,
                      focusNode: focusNode,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8.0,
                      ),
                      onTap: () {
                        Navigator.of(
                          context,
                        ).push(SlideBottomRoute(widget: const PlayerScreen()));
                        SystemChrome.setSystemUIOverlayStyle(
                          SystemUiOverlayStyle(
                            systemNavigationBarColor:
                                settings.themeData.scaffoldBackgroundColor,
                          ),
                        );
                      },
                      leading: CachedImage(
                        width: 50,
                        height: 50,
                        url:
                            audioHandler.mediaItem.value?.extras?['thumb'] ??
                            audioHandler.mediaItem.value?.artUri,
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
                          PrevNextButton(iconSize, prev: true, hidePrev: true),
                          PlayPauseButton(iconSize),
                          PrevNextButton(iconSize),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(
                    height: 3.0,
                    child: LinearProgressIndicator(
                      color: Theme.of(context).primaryColor,
                      backgroundColor: Theme.of(
                        context,
                      ).primaryColor.withValues(alpha: 0.1),
                      value: _progress,
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
          if (!(queueState?.hasNext ?? false)) {
            return IconButton(
              icon: Icon(Icons.skip_next, semanticLabel: 'Play next'.i18n),
              iconSize: size,
              onPressed: null,
            );
          }
          while (true) {
            return IconButton(
              icon: Icon(Icons.skip_next, semanticLabel: 'Play next'.i18n),
              iconSize: size,
              onPressed: () => GetIt.I<AudioPlayerHandler>().skipToNext(),
            );
          }
        }
        if (prev) {
          if (!(queueState?.hasPrevious ?? false)) {
            if (hidePrev) {
              return const SizedBox(height: 0, width: 0);
            }

            return IconButton(
              icon: Icon(
                Icons.skip_previous,
                semanticLabel: 'Play previous'.i18n,
              ),
              iconSize: size,
              onPressed: null,
            );
          }
          while (true) {
            return IconButton(
              icon: Icon(
                Icons.skip_previous,
                semanticLabel: 'Play previous'.i18n,
              ),
              iconSize: size,
              onPressed: () => GetIt.I<AudioPlayerHandler>().skipToPrevious(),
            );
          }
        }
        return Container();
      },
    );
  }
}

class PlayPauseButton extends StatefulWidget {
  final double size;
  const PlayPauseButton(this.size, {super.key});

  @override
  _PlayPauseButtonState createState() => _PlayPauseButtonState();
}

class _PlayPauseButtonState extends State<PlayPauseButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _animation = Tween<double>(
      begin: 0,
      end: 1,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
    super.initState();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: GetIt.I<AudioPlayerHandler>().playbackState,
      builder: (context, snapshot) {
        final playbackState = GetIt.I<AudioPlayerHandler>().playbackState.value;
        final playing = playbackState.playing;
        final processingState = playbackState.processingState;

        // Animated icon by pato05
        // Morph from pause to play or from play to pause
        if (playing ||
            processingState == AudioProcessingState.ready ||
            processingState == AudioProcessingState.idle) {
          if (playing) {
            _controller.forward();
          } else {
            _controller.reverse();
          }

          return IconButton(
            splashRadius: widget.size,
            icon: AnimatedIcon(
              icon: AnimatedIcons.play_pause,
              progress: _animation,
              semanticLabel: playing ? 'Pause'.i18n : 'Play'.i18n,
            ),
            iconSize: widget.size,
            onPressed: () async {
              playing
                  ? await GetIt.I<AudioPlayerHandler>().pause()
                  : await GetIt.I<AudioPlayerHandler>().play();
            },
          );
        }
        switch (processingState) {
          //Loading, connecting, rewinding...
          case AudioProcessingState.buffering:
          case AudioProcessingState.loading:
            return SizedBox(
              width: widget.size * 0.85,
              height: widget.size * 0.85,
              child: Center(
                child: Transform.scale(
                  scale: 0.85, // Adjust the scale to 75% of the original size
                  child: CircularProgressIndicator(
                    color: Theme.of(context).primaryColor,
                  ),
                ),
              ),
            );
          //Stopped/Error
          default:
            return SizedBox(width: widget.size, height: widget.size);
        }
      },
    );
  }
}
