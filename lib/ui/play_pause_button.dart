import 'package:audio_service/audio_service.dart';
import 'package:get_it/get_it.dart';
import 'package:material_ui/material_ui.dart';

import '../service/audio_service.dart';
import '../translations.i18n.dart';

class PlayPauseButton extends StatefulWidget {
  final double size;
  const PlayPauseButton(this.size, {super.key});

  @override
  _PlayPauseButtonState createState() => _PlayPauseButtonState();
}

class _PlayPauseButtonState extends State<PlayPauseButton>
    with SingleTickerProviderStateMixin {
  double get _buttonExtent => widget.size + 16 > 48 ? widget.size + 16 : 48;

  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
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
    final audioHandler = GetIt.I<AudioPlayerHandler>();
    return StreamBuilder(
      stream: audioHandler.playbackState,
      builder: (context, snapshot) {
        final playbackState = audioHandler.playbackState.value;
        final playing = playbackState.playing;
        final processingState = playbackState.processingState;
        final isRadio =
            audioHandler.isRadio ||
            AudioPlayerHandler.isRadioItem(audioHandler.mediaItem.value);

        if (processingState != AudioProcessingState.loading &&
            processingState != AudioProcessingState.buffering &&
            (playing ||
                processingState == AudioProcessingState.ready ||
                processingState == AudioProcessingState.idle)) {
          if (playing) {
            _controller.forward();
          } else {
            _controller.reverse();
          }

          if (isRadio) {
            return IconButton(
              constraints: BoxConstraints.tightFor(
                width: _buttonExtent,
                height: _buttonExtent,
              ),
              padding: EdgeInsets.zero,
              splashRadius: widget.size,
              icon: AnimatedBuilder(
                animation: _animation,
                builder: (context, child) {
                  return SizedBox(
                    width: widget.size, // matching standard icon footprint
                    height: widget.size,
                    child: CustomPaint(
                      painter: PlayStopPainter(
                        progress: _animation.value,
                        color: IconTheme.of(context).color ?? Colors.white,
                      ),
                    ),
                  );
                },
              ),
              iconSize: widget.size,
              onPressed: () async {
                playing
                    ? await audioHandler.pause()
                    : await audioHandler.play();
              },
            );
          }

          return IconButton(
            constraints: BoxConstraints.tightFor(
              width: _buttonExtent,
              height: _buttonExtent,
            ),
            padding: EdgeInsets.zero,
            splashRadius: widget.size,
            icon: AnimatedIcon(
              icon: AnimatedIcons.play_pause,
              progress: _animation,
              semanticLabel: playing ? 'Pause'.i18n : 'Play'.i18n,
            ),
            iconSize: widget.size,
            onPressed: () async {
              playing ? await audioHandler.pause() : await audioHandler.play();
            },
          );
        }
        switch (processingState) {
          //Loading, connecting, rewinding...
          case AudioProcessingState.buffering:
          case AudioProcessingState.loading:
            return SizedBox(
              width: _buttonExtent,
              height: _buttonExtent,
              child: Center(
                child: SizedBox(
                  width: widget.size * 0.85,
                  height: widget.size * 0.85,
                  child: Center(
                    child: Transform.scale(
                      scale: 0.85,
                      child: CircularProgressIndicator(
                        color: Theme.of(context).primaryColor,
                      ),
                    ),
                  ),
                ),
              ),
            );
          //Stopped/Error
          default:
            return SizedBox(width: _buttonExtent, height: _buttonExtent);
        }
      },
    );
  }
}

class PlayStopPainter extends CustomPainter {
  final double progress;
  final Color color;

  PlayStopPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final path = Path();

    // Ensure the icon is always a square even if the bounding box is constrained
    final double dim = size.width < size.height ? size.width : size.height;

    // Center it within the bounding box
    final double dx = (size.width - dim) / 2;
    final double dy = (size.height - dim) / 2;

    // A standard 24px icon has about 4-6px padding
    final double pad = dim * 0.25;
    final double h = dim - (pad * 2);

    // The play triangle needs a narrower width than height so it doesn't look stretched horizontally
    final double playW = h * 0.8;
    // The stop square has equal width and height
    final double stopW = h;

    // Interpolate width based on progress (0 = Play, 1 = Stop)
    final double w = playW + ((stopW - playW) * progress);

    // Optically center the play icon by shifting its left edge slightly to the right
    final double playOffsetX = pad + (h * 0.1);
    final double stopOffsetX = pad;
    final double offsetX =
        playOffsetX + ((stopOffsetX - playOffsetX) * progress);

    final trY = (h / 2) - ((h / 2) * progress);
    final brY = (h / 2) + ((h / 2) * progress);

    path.moveTo(dx + offsetX, dy + pad); // top left
    path.lineTo(dx + offsetX, dy + pad + h); // bottom left
    path.lineTo(dx + offsetX + w, dy + pad + brY); // bottom right
    path.lineTo(dx + offsetX + w, dy + pad + trY); // top right
    path.close();

    canvas.drawPath(path, paint);
  }

  bool runsHitTest(Offset position) => false;

  @override
  bool shouldRepaint(covariant PlayStopPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}
