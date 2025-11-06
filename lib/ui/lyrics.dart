import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:palette_generator/palette_generator.dart';

import '../api/deezer.dart';
import '../api/definitions.dart';
import '../service/audio_service.dart';
import '../settings.dart';
import '../translations.i18n.dart';
import '../ui/elements.dart';
import '../ui/error.dart';
import '../utils/unmanagedtext.dart';

late Function updateColor;
late Color scaffoldBackgroundColor;

class LyricsScreen extends StatefulWidget {
  final Lyrics? lyrics;
  final String trackId;

  const LyricsScreen({this.lyrics, required this.trackId, super.key});

  @override
  _LyricsScreenState createState() => _LyricsScreenState();
}

class _LyricsScreenState extends State<LyricsScreen> {
  String appBarTitle = 'Lyrics'.i18n;
  Lyrics? lyrics;
  bool _loading = true;
  bool _error = false;
  int _currentIndex = 0;
  int _prevIndex = 0;
  Timer? _timer;
  final ScrollController _controller = ScrollController();
  StreamSubscription? _mediaItemSub;
  LinearGradient? _bgGradient;
  ImageProvider? _blurImage;
  final double height = 90;

  @override
  void initState() {
    super.initState();
    _load();

    //Enable visualizer
    if (settings.lyricsVisualizer) {
      GetIt.I<AudioPlayerHandler>().startVisualizer();
    }

    //Track change = exit lyrics
    _mediaItemSub = GetIt.I<AudioPlayerHandler>().mediaItem.listen((event) {
      if (event?.id != widget.trackId) Navigator.of(context).pop();
      _updateColor(); // Update background when track changes
    });

    // Initial background update
    _updateColor();
  }

  Future _load() async {
    if (widget.lyrics?.isLoaded() == true) {
      _updateLyricsState(widget.lyrics!);
      return;
    }

    try {
      Lyrics l = await deezerAPI.lyrics(widget.trackId);
      if (l.isUnsynced() == false && l.isSynced() == false) {
        _updateLyricsState(
          Lyrics(
            syncedLyrics: [
              SynchronizedLyric(
                offset: const Duration(milliseconds: 0),
                text: 'No lyrics found'.i18n,
              ),
            ],
            unsyncedLyrics: null,
            errorMessage: null,
          ),
        );
        return;
      }
      _updateLyricsState(l);
    } catch (e, stack) {
      debugPrint('[Lyrics] Error loading lyrics: $e');
      debugPrint('$stack');
      _timer?.cancel();
      if (mounted) {
        setState(() {
          _error = true;
          _loading = false;
        });
      }
      _updateLyricsState(
        Lyrics(
          syncedLyrics: [
            SynchronizedLyric(
              offset: const Duration(milliseconds: 0),
              text: 'No lyrics found'.i18n,
            ),
          ],
          unsyncedLyrics: null,
          errorMessage: null,
        ),
      );
      return;
    }
  }

  void _updateLyricsState(Lyrics lyrics) {
    String screenTitle = 'Lyrics'.i18n;
    if (lyrics.syncedLyrics!.isNotEmpty) {
      _startSyncTimer();
    } else if (lyrics.unsyncedLyrics!.isNotEmpty) {
      screenTitle = 'Unsynchronized lyrics'.i18n;
      _timer?.cancel();
    }

    setState(() {
      appBarTitle = screenTitle;
      this.lyrics = lyrics;
      _loading = false;
      _error = false;
    });
  }

  void _startSyncTimer() {
    debugPrint('[Lyrics] Starting sync timer');
    Timer.periodic(const Duration(milliseconds: 350), (timer) {
      _timer = timer;
      if (_loading) return;

      //Update current lyric index
      if (mounted) {
        setState(
          () => _currentIndex = lyrics!.syncedLyrics!.lastIndexWhere(
            (lyric) =>
                (lyric.offset ?? const Duration(seconds: 0)) <=
                GetIt.I<AudioPlayerHandler>().playbackState.value.position,
          ),
        );
      }

      //Scroll to current lyric
      if (_currentIndex <= 0) return;
      if (_prevIndex == _currentIndex) return;
      _prevIndex = _currentIndex;
      _controller.animateTo(
        (height * _currentIndex) -
            (MediaQuery.of(context).size.height / 2) +
            (height / 2) +
            56,
        duration: const Duration(milliseconds: 250),
        curve: Curves.ease,
      );
    });
  }

  Future<void> _updateColor() async {
    if (GetIt.I<AudioPlayerHandler>().mediaItem.value == null) return;

    if (!settings.themeAdditonalItems &&
        !settings.colorGradientBackground &&
        !settings.blurPlayerBackground) {
      return;
    }

    // Set blur background image
    if (settings.themeAdditonalItems && settings.blurPlayerBackground) {
      setState(() {
        _blurImage = CachedNetworkImageProvider(
          GetIt.I<AudioPlayerHandler>().mediaItem.value?.extras?['thumb'] ??
              GetIt.I<AudioPlayerHandler>().mediaItem.value?.artUri ??
              '',
        );
      });
    }

    // Generate color palette from the image
    PaletteGenerator palette = await PaletteGenerator.fromImageProvider(
      CachedNetworkImageProvider(
        GetIt.I<AudioPlayerHandler>().mediaItem.value?.extras?['thumb'] ??
            GetIt.I<AudioPlayerHandler>().mediaItem.value?.artUri ??
            '',
      ),
    );

    // Set system UI overlay colors
    if (settings.themeAdditonalItems && settings.blurPlayerBackground) {
      SystemChrome.setSystemUIOverlayStyle(
        SystemUiOverlayStyle(
          statusBarColor: palette.dominantColor!.color.withValues(alpha: 0.25),
          systemNavigationBarColor: Color.alphaBlend(
            palette.dominantColor!.color.withValues(alpha: 0.25),
            scaffoldBackgroundColor,
          ),
        ),
      );
    }

    // Set gradient background color
    if (settings.themeAdditonalItems &&
        !settings.blurPlayerBackground &&
        settings.colorGradientBackground) {
      setState(() {
        _bgGradient = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            palette.dominantColor!.color.withValues(alpha: 0.7),
            const Color.fromARGB(0, 0, 0, 0),
          ],
          stops: const [0.0, 0.6],
        );
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _mediaItemSub?.cancel();
    _controller.dispose();
    //Stop visualizer
    if (settings.lyricsVisualizer) {
      GetIt.I<AudioPlayerHandler>().stopVisualizer();
    }
    //Fix bottom buttons
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        systemNavigationBarColor: settings.themeData.scaffoldBackgroundColor,
      ),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    scaffoldBackgroundColor = Theme.of(context).scaffoldBackgroundColor;

    return Scaffold(
      appBar: FreezerAppBar(
        appBarTitle,
        enableBlur: true,
        opacity: 0,
        blurStrength: 15.0,
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) async {
              setState(() {
                _loading = true;
                _error = false;
              });
              if (value == 'deezer') {
                _load();
              } else {
                final mediaItem = GetIt.I<AudioPlayerHandler>().mediaItem.value;
                if (mediaItem != null) {
                  final query =
                      '${mediaItem.displayTitle} ${mediaItem.displaySubtitle ?? ''}'
                          .trim();
                  final lrc = await LyricsAPI.getLyrics(value, query, '1');
                  if (lrc['lyrics'] == 'error') {
                    _updateLyricsState(
                      Lyrics(
                        syncedLyrics: [
                          SynchronizedLyric(
                            offset: const Duration(milliseconds: 0),
                            text: 'No lyrics found'.i18n,
                          ),
                        ],
                        unsyncedLyrics: null,
                        errorMessage: null,
                      ),
                    );
                  } else {
                    if (lrc['lyrics'] != null) {
                      final lrcText = lrc['lyrics'] as String;
                      final syncedLyrics = <SynchronizedLyric>[];
                      final lines = lrcText.split('\n');

                      // Try to parse as synced lyrics
                      for (final line in lines) {
                        final match = RegExp(
                          r'\[(\d{2}):(\d{2})\.(\d{2})\](.*)',
                        ).firstMatch(line);
                        if (match != null) {
                          final minutes = int.parse(match.group(1)!);
                          final seconds = int.parse(match.group(2)!);
                          final milliseconds = int.parse(match.group(3)!) * 10;
                          final text = match.group(4)!.trim();

                          syncedLyrics.add(
                            SynchronizedLyric(
                              text: text,
                              offset: Duration(
                                minutes: minutes,
                                seconds: seconds,
                                milliseconds: milliseconds,
                              ),
                            ),
                          );
                        }
                      }

                      if (syncedLyrics.isNotEmpty) {
                        _updateLyricsState(
                          Lyrics(
                            syncedLyrics: syncedLyrics,
                            unsyncedLyrics: null,
                            errorMessage: null,
                          ),
                        );
                      } else {
                        _updateLyricsState(
                          Lyrics(
                            syncedLyrics: [],
                            unsyncedLyrics: lrcText,
                            errorMessage: null,
                          ),
                        );
                      }
                    } else {
                      setState(() {
                        _error = true;
                        _loading = false;
                      });
                    }
                  }
                }
              }
            },
            itemBuilder: (BuildContext context) {
              return [
                PopupMenuItem<String>(
                  value: 'deezer',
                  child: Row(
                    children: [
                      const Icon(Icons.music_note),
                      const SizedBox(width: 8),
                      Text('Deezer'.i18n),
                    ],
                  ),
                ),
                PopupMenuItem<String>(
                  enabled: false,
                  child: FutureBuilder<dynamic>(
                    future: LyricsAPI().listProviders(),
                    builder: (context, snapshot) {
                      if (!snapshot.hasData) {
                        return const Row(
                          children: [
                            SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: 8),
                            Text('Loading providers...'),
                          ],
                        );
                      }
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ...snapshot.data['providers'].map<Widget>((provider) {
                            final displayName = provider.keys.first;
                            final providerCode = provider.values.first;
                            return InkWell(
                              onTap: () {
                                Navigator.pop(context, providerCode);
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8.0,
                                ),
                                child: Row(
                                  children: [
                                    const Icon(Icons.cloud),
                                    const SizedBox(width: 8),
                                    Text(displayName),
                                  ],
                                ),
                              ),
                            );
                          }).toList(),
                        ],
                      );
                    },
                  ),
                ),
              ];
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          // Background (Blur Image or Gradient)
          if (settings.themeAdditonalItems &&
              settings.blurPlayerBackground &&
              _blurImage != null)
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
            )
          else if (_bgGradient != null)
            Container(decoration: BoxDecoration(gradient: _bgGradient)),

          // Visualizer
          if (settings.lyricsVisualizer)
            Align(
              alignment: Alignment.bottomCenter,
              child: StreamBuilder(
                stream: GetIt.I<AudioPlayerHandler>().visualizerStream,
                builder: (BuildContext context, AsyncSnapshot snapshot) {
                  List<double> data = snapshot.data ?? [];
                  double width =
                      MediaQuery.of(context).size.width / data.length - 0.25;
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: List.generate(
                      data.length,
                      (i) => AnimatedContainer(
                        duration: const Duration(milliseconds: 130),
                        color: Theme.of(context).primaryColor,
                        height: data[i] * 100,
                        width: width,
                      ),
                    ),
                  );
                },
              ),
            ),

          // Lyrics
          Padding(
            padding: EdgeInsets.fromLTRB(
              0,
              0,
              0,
              settings.lyricsVisualizer ? 100 : 0,
            ),
            child: ListView(
              controller: _controller,
              children: [
                if (_error) const ErrorScreen(),
                if (_loading)
                  Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        CircularProgressIndicator(
                          color: Theme.of(context).primaryColor,
                        ),
                      ],
                    ),
                  ),
                if (lyrics != null && lyrics!.syncedLyrics?.isNotEmpty == true)
                  ...List.generate(lyrics!.syncedLyrics!.length, (i) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8.0),
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8.0),
                          color: (_currentIndex == i)
                              ? Colors.grey.withValues(alpha: 0.25)
                              : Colors.transparent,
                        ),
                        height: height,
                        child: Center(
                          child: GestureDetector(
                            onTap: () {
                              final offset = lyrics!.syncedLyrics![i].offset;
                              if (offset != null) {
                                GetIt.I<AudioPlayerHandler>().seek(offset);
                              }
                            },
                            child: Text(
                              lyrics!.syncedLyrics![i].text ?? '',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 26.0,
                                fontWeight: (_currentIndex == i)
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
                if (lyrics != null &&
                    (lyrics!.syncedLyrics?.isEmpty ?? true) &&
                    lyrics!.unsyncedLyrics != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8.0),
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8.0),
                      ),
                      child: Center(
                        child: Text(
                          lyrics!.unsyncedLyrics!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 26.0),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
