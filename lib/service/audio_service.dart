import '../utils/app_config.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart';
import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
import 'package:audio_service_mpris/audio_service_mpris.dart';
import 'package:audio_session/audio_session.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_discord_rpc/flutter_discord_rpc.dart';
import 'package:just_audio/just_audio.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:rxdart/rxdart.dart';
import 'package:scrobblenaut/scrobblenaut.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:saturn/utils/rpc_service.dart';
import 'package:window_manager/window_manager.dart';

import '../api/cache.dart';
import '../api/download.dart';
import '../router/app_router.dart';
import '../ui/toast.dart';
import '../platform/music_platform.dart';
import '../platform/desktop_audio_player.dart';
import '../platform/platform_manager.dart';
import '../platform/platform_registry.dart';
import '../platform/stream_proxy_server.dart';
import '../platform/stream_audio_source.dart';
import '../platform/stream_provider.dart';
import '../api/definitions.dart';
import '../settings.dart';
import '../translations.i18n.dart';
import '../ui/android_auto.dart';
import '../utils/mediaitem_converter.dart';
import '../utils/format_utils.dart';

Future<AudioPlayerHandler> initAudioService() async {
  AudioPlayerHandler? handler;
  if (Platform.isLinux) {
    AudioServiceMpris.init(
      dBusName: 'Saturn',
      identity: 'Saturn',
      desktopEntry: 's.s.saturn',
      canGoNext: true,
      canGoPrevious: true,
      canPlay: true,
      canPause: true,
      canControl: true,
      onRaiseRequest: () => unawaited(_raiseWindowFromMpris()),
      onQuitRequest: () => unawaited(_quitFromMpris(handler)),
    );
  }
  handler = await AudioService.init(
    builder: () => AudioPlayerHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 's.s.saturn.audio',
      androidNotificationChannelName: 'Saturn',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
      androidNotificationClickStartsActivity: true,
      androidNotificationChannelDescription: 'Saturn',
      androidNotificationIcon: 'drawable/ic_logo',
      androidResumeOnClick: true,
      // Keep session artwork small enough for MediaSession clients such as
      // Wear OS, which receive the artwork bitmap through the session bundle.
      artDownscaleWidth: 384,
      artDownscaleHeight: 384,
    ),
  );
  return handler;
}

Future<void> _raiseWindowFromMpris() async {
  try {
    await windowManager.show();
    if (await windowManager.isMinimized()) await windowManager.restore();
    await windowManager.focus();
    if (rootNavigatorKey.currentState != null) {
      openPlayerScreen();
    } else {
      // MPRIS can be ready before Flutter has mounted its first route.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (rootNavigatorKey.currentState != null) openPlayerScreen();
      });
    }
  } catch (error, stack) {
    Logger.root.warning('Could not raise Saturn window: $error', error, stack);
  }
}

Future<void> _quitFromMpris(AudioPlayerHandler? handler) async {
  try {
    await handler?.stop();
  } catch (error, stack) {
    Logger.root.warning(
      'Could not stop playback before quitting: $error',
      error,
      stack,
    );
  }
  exit(0);
}

/// State of live radio playback. Non-null on the handler while a radio
/// station is the active item.
class RadioState {
  final String stationId;
  final String stationName;
  final String platformId;

  /// Song currently on air, when the station is fingerprinted and known.
  final Track? nowPlaying;

  const RadioState({
    required this.stationId,
    required this.stationName,
    this.platformId = '',
    this.nowPlaying,
  });

  RadioState copyWith({Track? nowPlaying, bool clearNowPlaying = false}) =>
      RadioState(
        stationId: stationId,
        stationName: stationName,
        platformId: platformId,
        nowPlaying: clearNowPlaying ? null : (nowPlaying ?? this.nowPlaying),
      );
}

class AudioPlayerHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  AudioPlayerHandler() {
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      if (results.any((result) => result != ConnectivityResult.none)) {
        unawaited(_flushPendingListenLogs());
      }
    });
    // Connectivity streams don't emit the current state on every platform.
    // Flush records left from a previous session as soon as the handler starts.
    unawaited(_flushPendingListenLogs());
    _offlineTracksRemovedSub = downloadManager.offlineTracksRemoved.listen((
      track,
    ) {
      unawaited(_refreshPlayingTrackAfterOfflineRemoval(track));
    });
    _unavailableStreamSub = StreamProxyServer.instance.unavailableEvents.listen((
      event,
    ) {
      if (event.platformId != 'soundcloud' ||
          !event.message.contains('DRM-encrypted') ||
          event.trackId != mediaItem.value?.id) {
        return;
      }
      final now = DateTime.now();
      if (_lastDrmTrackId == event.trackId &&
          _lastDrmNoticeAt != null &&
          now.difference(_lastDrmNoticeAt!) < const Duration(seconds: 10)) {
        return;
      }
      _lastDrmTrackId = event.trackId;
      _lastDrmNoticeAt = now;
      Fluttertoast.showToast(
        msg:
            'SoundCloud only provides a DRM-protected stream for this track. Saturn cannot play it.',
        toastLength: Toast.LENGTH_LONG,
      );
    });
    _init();
  }

  late final StreamSubscription<
    ({String platformId, String trackId, String message})
  >
  _unavailableStreamSub;
  late final StreamSubscription<Track> _offlineTracksRemovedSub;
  late final StreamSubscription<List<ConnectivityResult>> _connectivitySub;
  bool _flushingPendingListenLogs = false;
  String? _lastDrmTrackId;
  DateTime? _lastDrmNoticeAt;
  Future<void> _playbackSpeedUpdateTail = Future<void>.value();

  static final Completer<void> _androidRuntimeReady = Completer<void>();

  /// Unblock player construction after settings, providers, and the stream
  /// proxy are ready. Android can dispatch a media-resume click before then.
  static void markAndroidRuntimeReady() {
    if (!_androidRuntimeReady.isCompleted) _androidRuntimeReady.complete();
  }

  final AndroidAuto _androidAuto =
      AndroidAuto(); // Create an instance of AndroidAuto

  // Media commands can arrive before the player has finished initializing.
  final Completer<void> _playerInitializedCompleter = Completer<void>();
  // Completes when the saved queue has been loaded (or when it's confirmed there is none).
  final Completer<void> _queueReadyCompleter = Completer<void>();
  bool get isQueueReady => _queueReadyCompleter.isCompleted;
  late AudioPlayer _player;

  AudioPlayer get player => _player;

  Scrobblenaut? _scrobblenaut;
  bool _scrobblenautReady = false;
  // Last logged track id
  String? _loggedTrackId;
  bool emptied = false;

  DateTime? _currentTrackStartTime;
  int _currentTrackListenedSeconds = 0;
  int _currentTrackSeekCount = 0;
  int _currentTrackPauseCount = 0;
  String? _currentTrackStreamId;
  int _lastLoggedPartialPositionSeconds = -1;
  // ignore: unused_field flutter no detect this for some reason??
  bool _hasLoggedFullListen = false;

  void _startListenSession() {
    _currentTrackStartTime = DateTime.now();
    _currentTrackListenedSeconds = 0;
    _currentTrackSeekCount = 0;
    _currentTrackPauseCount = 0;
    String hex(int len) => List.generate(
      len,
      (_) => math.Random().nextInt(16).toRadixString(16),
    ).join();
    _currentTrackStreamId =
        '${hex(8)}-${hex(4)}-4${hex(3)}-a${hex(3)}-${hex(12)}';
    _lastLoggedPartialPositionSeconds = -1;
    _hasLoggedFullListen = false;
  }

  QueueSource? queueSource;
  StreamSubscription? _queueStateSub;
  final BehaviorSubject<QueueState> _queueStateSubject =
      BehaviorSubject<QueueState>.seeded(QueueState.empty);
  Stream<QueueState> get queueStateStream => _queueStateSubject.stream;
  QueueState get queueState =>
      _queueStateSubject.valueOrNull ?? QueueState.empty;
  bool get isPreparingQueueForShuffle => _preparingQueueForShuffle;
  bool get isLoadingMoreQueue => _queueEndRequest != null;
  bool _queueSourceExhausted = false;
  bool get canLoadMoreQueue {
    if (_queueSourceExhausted) return false;
    final source = queueSource?.source;
    return (source == 'playlist_page' ||
            source == 'favorites_page' ||
            source == 'platform_history_page' ||
            source == 'show_page_partial' ||
            source == 'libraryshuffle' ||
            source == 'artist_smartradio' ||
            source == 'smartradio' ||
            source == 'smarttracklist' ||
            source == 'track_mix_contextual' ||
            source == 'mix' ||
            source == 'flow') &&
        _lastQueueLoadAtLength != currentQueue.length;
  }

  Future<bool> loadMoreQueueItems({bool force = false}) {
    if (force) {
      _queueSourceExhausted = false;
      _lastQueueLoadAtLength = -1;
    }
    return _loadMoreAtQueueEnd();
  }

  // ---------------------------------------------------------------------
  // Live radio
  final BehaviorSubject<RadioState?> _radioStateSubject =
      BehaviorSubject<RadioState?>.seeded(null);
  Stream<RadioState?> get radioStateStream => _radioStateSubject.stream;
  RadioState? get radioState => _radioStateSubject.value;
  bool get isRadio => isRadioItem(mediaItem.value) || _radioStationItem != null;
  StreamSubscription<RadioNowPlaying>? _radioSubscription;
  Timer? _radioFallbackTimer;
  bool _radioRefreshInFlight = false;
  Timer? _streamMetadataTimer;
  String? _directBitrateKey;
  Future<int?>? _directBitrateLookup;
  MediaItem? _radioStationItem;
  // Station start time for the current radio song. The stream clock below
  // maps it onto the audio actually being played.
  DateTime? _radioSongStart;
  // Local time represented by position zero in the current radio stream.
  // Calibrated on load and moved to live after a buffering stall.
  DateTime? _radioStreamPositionZero;
  // Track audible playout time independently of just_audio's event position,
  // which can lag behind its extrapolated position after buffering.
  Duration _radioPlayoutBase = Duration.zero;
  final Stopwatch _radioPlayoutClock = Stopwatch();
  bool _radioReanchorAfterBuffering = false;

  static bool isRadioItem(MediaItem? item) =>
      item?.extras?['isRadio'] == true ||
      item?.extras?['radioUrl'] != null ||
      item?.id.startsWith('radio:') == true;

  /// True while live radio can say where in the current song the listener is.
  bool get hasRadioClock =>
      isRadio && _radioSongStart != null && _radioStreamPositionZero != null;

  DateTime? get _radioAudibleTime {
    final streamZero = _radioStreamPositionZero;
    if (streamZero == null) return null;
    return streamZero.add(_radioPlayoutBase + _radioPlayoutClock.elapsed);
  }

  void _reanchorRadioClockToLive() {
    if (_radioStreamPositionZero == null) return;
    _radioStreamPositionZero = DateTime.now().toUtc().subtract(
      _radioPlayoutBase + _radioPlayoutClock.elapsed,
    );
    final state = radioState;
    if (state != null) _radioStateSubject.add(state);
  }

  void _updateRadioPlayoutClock({
    bool? playing,
    ProcessingState? processingState,
  }) {
    if (_radioStreamPositionZero == null) return;
    final active = playing ?? _player.playing;
    final state = processingState ?? _player.processingState;
    if (state == ProcessingState.buffering && active) {
      _radioReanchorAfterBuffering = true;
    }
    if (active && state == ProcessingState.ready) {
      if (_radioReanchorAfterBuffering) {
        // A resumed live stream should use the station's current live time,
        // rather than wait for the player's stale position to catch up.
        _reanchorRadioClockToLive();
        _radioReanchorAfterBuffering = false;
      }
      if (!_radioPlayoutClock.isRunning) _radioPlayoutClock.start();
    } else if (_radioPlayoutClock.isRunning) {
      _radioPlayoutClock.stop();
      _radioPlayoutBase += _radioPlayoutClock.elapsed;
      _radioPlayoutClock.reset();
    }
  }

  /// Position within the current song. For live radio with a known start this
  /// follows the stream's playout clock, otherwise from the player.
  Duration get syncedPosition {
    final start = _radioSongStart;
    if (!isRadio) return _player.position;
    if (start == null) return Duration.zero;
    final playoutTime = _radioAudibleTime;
    if (playoutTime == null) return Duration.zero;
    final station = radioState;
    final adjustment = station == null
        ? Duration.zero
        : PlatformRegistry.instance
                  .get(station.platformId)
                  ?.radioPositionAdjustment(station.stationId) ??
              Duration.zero;
    final elapsed = playoutTime.difference(start.toUtc()) + adjustment;
    if (elapsed.isNegative) return Duration.zero;
    final length = mediaItem.value?.duration;
    if (length != null && length > Duration.zero && elapsed > length) {
      return length;
    }
    return elapsed;
  }

  bool _captureRadioStreamClock() {
    if (!isRadio) return false;
    if (!_player.playing || _player.processingState != ProcessingState.ready) {
      return false;
    }
    if (_radioStreamPositionZero != null) return false;
    final position = _player.position;
    final queuedAudio = _player.bufferedPosition - position;
    final initialDelay =
        queuedAudio > Duration.zero &&
            queuedAudio <= const Duration(seconds: 30)
        ? queuedAudio
        : Duration.zero;
    // Some live decoders report no meaningful buffered position. In that case
    // start at the live point rather than leave the song clock uninitialized.
    _radioStreamPositionZero = DateTime.now().toUtc().subtract(
      position + initialDelay,
    );
    _radioPlayoutBase = position;
    _radioPlayoutClock
      ..reset()
      ..start();
    // Publish the first usable clock even if song timing arrived before audio.
    final state = radioState;
    if (state != null) _radioStateSubject.add(state);
    final adjustment = state == null
        ? Duration.zero
        : PlatformRegistry.instance
                  .get(state.platformId)
                  ?.radioPositionAdjustment(state.stationId) ??
              Duration.zero;
    Logger.root.info(
      initialDelay > Duration.zero
          ? 'Radio player reported ${initialDelay.inMilliseconds} ms buffered '
                '(position adjustment ${adjustment.inMilliseconds} ms; '
                'station stream delay unknown)'
          : 'Radio player buffer unavailable; assuming 0 ms '
                '(position adjustment ${adjustment.inMilliseconds} ms; '
                'station stream delay unknown)',
    );
    return true;
  }

  void _resetRadioStreamClock() {
    _radioStreamPositionZero = null;
    _radioPlayoutClock
      ..stop()
      ..reset();
    _radioPlayoutBase = Duration.zero;
    _radioReanchorAfterBuffering = false;
  }

  static bool _isExcludedQueueLivestream(Track track) =>
      track.id?.startsWith('radio:') == true;

  static bool _isExcludedQueueLivestreamItem(MediaItem item) =>
      item.id.startsWith('radio:');

  /// Replace metadata of the currently playing item without touching the
  /// audio source. Used by live radio where the song changes mid-stream.
  void setMetadata(MediaItem updated) {
    if (currentIndex < 0 || currentIndex >= currentQueue.length) return;
    if (currentQueue[currentIndex].id != updated.id) return;
    currentQueue[currentIndex] = updated;
    _publishMediaItem(updated);
    queue.add(List.unmodifiable(currentQueue));
    if (!Platform.isAndroid && !Platform.isIOS) {
      unawaited(_updateDiscordRPC(updated));
    }
  }

  Future<void> _refreshPlayingTrackAfterOfflineRemoval(Track track) async {
    if (!_playerInitializedCompleter.isCompleted) {
      await _playerInitializedCompleter.future;
    }
    // Queue paging may currently be appending sources. Let that transaction
    // finish, then replace any loaded queue entries still backed by the
    // deleted file. The removed item may be later in the queue, not current.
    final pendingSources = _pendingQueueSources;
    if (pendingSources != null) {
      try {
        await pendingSources;
      } catch (_) {
        // The replacement below will resolve the current item independently.
      }
    }

    final sources = List<AudioSource>.of(_player.audioSources);
    final loadedCount = math.min(sources.length, currentQueue.length);
    final indexesToReplace = <int>[];
    for (var index = 0; index < loadedCount; index++) {
      final queuedTrack = Track.fromMediaItem(currentQueue[index]);
      final source = sources[index];
      if (queuedTrack.id == track.id &&
          queuedTrack.platformId == track.platformId &&
          source is UriAudioSource &&
          source.uri.scheme.toLowerCase() == 'file') {
        indexesToReplace.add(index);
      }
    }
    if (indexesToReplace.isEmpty) return;

    final wasPlaying = _player.playing;
    final position = _player.position;
    final requestId = ++_playRequestId;
    final index = currentIndex;
    _requestedIndex = index;
    _rearranging = true;
    try {
      for (final replacementIndex in indexesToReplace) {
        final replacement = await _getTrackAudioSource(
          currentQueue[replacementIndex],
        );
        if (requestId != _playRequestId) return;
        if (replacement == null) continue;
        if (replacement is UriAudioSource && replacement.tag is MediaItem) {
          currentQueue[replacementIndex] = replacement.tag as MediaItem;
        }
        sources[replacementIndex] = replacement;
      }
      await _player.setAudioSources(
        sources,
        initialIndex: index >= 0 && index < sources.length ? index : null,
        initialPosition: position,
      );
      if (requestId != _playRequestId) return;
      _requestedIndex = -1;
      if (index >= 0 && index < currentQueue.length) currentIndex = index;
      queue.add(List.unmodifiable(currentQueue));
      if (currentIndex >= 0 && currentIndex < currentQueue.length) {
        _publishMediaItem(currentQueue[currentIndex]);
        _onSelectedSourceReady(currentIndex);
      }
      if (wasPlaying) unawaited(_player.play());
      _saveQueueToFile();
    } catch (error, stackTrace) {
      if (requestId == _playRequestId) _requestedIndex = -1;
      Logger.root.warning(
        'Could not switch queued tracks back to streaming after removing an offline file: $error',
        error,
        stackTrace,
      );
    } finally {
      _rearranging = false;
    }
  }

  bool _hasPositiveDuration(Duration? value) =>
      value != null && value > Duration.zero;

  /// Keep a duration already learned for an item when later queue/source
  /// metadata for that same ID omits it or carries a zero placeholder.
  void _publishMediaItem(MediaItem? item) {
    final generation = ++_publishedMediaGeneration;
    if (item == null) {
      mediaItem.add(null);
      return;
    }
    var published = item;
    if (!_hasPositiveDuration(item.duration) && !isRadioItem(item)) {
      final current = mediaItem.value;
      Duration? knownDuration;
      if (current?.id == item.id && _hasPositiveDuration(current?.duration)) {
        knownDuration = current!.duration;
      } else {
        for (final queued in currentQueue) {
          if (queued.id == item.id && _hasPositiveDuration(queued.duration)) {
            knownDuration = queued.duration;
            break;
          }
        }
      }
      if (knownDuration != null) {
        published = item.copyWith(duration: knownDuration);
      }
    }
    if (currentIndex >= 0 && currentIndex < currentQueue.length) {
      final queued = currentQueue[currentIndex];
      if (queued.id == published.id &&
          !_hasPositiveDuration(queued.duration) &&
          _hasPositiveDuration(published.duration)) {
        currentQueue[currentIndex] = published;
      }
    }
    if (settings.cropMediaArtwork && published.artUri != null) {
      unawaited(_publishItemWithCroppedArtwork(published, generation));
      return;
    }
    mediaItem.add(published);
  }

  Future<void> _publishItemWithCroppedArtwork(
    MediaItem item,
    int generation,
  ) async {
    try {
      final sourceUri = item.artUri!;
      final cacheKey = sourceUri.toString();
      final cropRequest = _croppedArtworkUris.putIfAbsent(
        cacheKey,
        () => _createSquareArtwork(sourceUri, item.artHeaders),
      );
      final croppedUri = await cropRequest;
      if (_croppedArtworkUris.length > 64) {
        _croppedArtworkUris.remove(_croppedArtworkUris.keys.first);
      }
      if (generation != _publishedMediaGeneration) return;
      // audio_service publishes this item both to native media controls and
      // to Saturn's own player UI. Keep the source URI in extras so the app
      // can continue showing the original artwork while the platform receives
      // its square-cropped copy.
      mediaItem.add(
        item.copyWith(
          artUri: croppedUri,
          extras: {
            ...?item.extras,
            'saturnOriginalArtUri': sourceUri.toString(),
          },
        ),
      );
    } catch (error, stackTrace) {
      _croppedArtworkUris.remove(item.artUri!.toString());
      Logger.root.warning(
        'Could not crop artwork for media controls; using the original image.',
        error,
        stackTrace,
      );
      if (generation == _publishedMediaGeneration) mediaItem.add(item);
    }
  }

  Future<Uri> _createSquareArtwork(
    Uri sourceUri,
    Map<String, String>? headers,
  ) async {
    final appDirectory = await getTemporaryDirectory();
    final cacheDirectory = Directory(
      p.join(appDirectory.path, 'media_artwork'),
    );
    await cacheDirectory.create(recursive: true);
    final digest = sha256.convert(utf8.encode(sourceUri.toString()));
    // v2 stores a true center crop. v1 decoded non-square inputs into a square
    // first, which stretched the artwork before the crop was applied.
    final output = File(p.join(cacheDirectory.path, 'square-v2-$digest.png'));
    if (await output.exists() && await output.length() > 0) {
      return output.uri;
    }

    final sourceFile = sourceUri.scheme == 'file'
        ? File.fromUri(sourceUri)
        : await DefaultCacheManager().getSingleFile(
            sourceUri.toString(),
            headers: headers,
          );
    final encodedImage = await ui.ImmutableBuffer.fromUint8List(
      await sourceFile.readAsBytes(),
    );
    try {
      final descriptor = await ui.ImageDescriptor.encoded(encodedImage);
      try {
        // Decode with the shorter edge at 512px while letting the other edge
        // follow the original aspect ratio. This preserves enough pixels for
        // the square crop without stretching the source.
        final codec = await descriptor.instantiateCodec(
          targetWidth: descriptor.width <= descriptor.height ? 512 : null,
          targetHeight: descriptor.height < descriptor.width ? 512 : null,
        );
        try {
          final frame = await codec.getNextFrame();
          final sourceImage = frame.image;
          try {
            final side = math
                .min(sourceImage.width, sourceImage.height)
                .toDouble();
            final sourceRect = ui.Rect.fromLTWH(
              (sourceImage.width - side) / 2,
              (sourceImage.height - side) / 2,
              side,
              side,
            );
            final recorder = ui.PictureRecorder();
            final canvas = ui.Canvas(recorder);
            canvas.drawImageRect(
              sourceImage,
              sourceRect,
              ui.Rect.fromLTWH(0, 0, 512, 512),
              ui.Paint()..filterQuality = ui.FilterQuality.high,
            );
            final squareImage = await recorder.endRecording().toImage(512, 512);
            try {
              final png = await squareImage.toByteData(
                format: ui.ImageByteFormat.png,
              );
              if (png == null) {
                throw const FormatException('Artwork encode failed');
              }
              await output.writeAsBytes(
                png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
                flush: true,
              );
            } finally {
              squareImage.dispose();
            }
          } finally {
            sourceImage.dispose();
          }
        } finally {
          codec.dispose();
        }
      } finally {
        descriptor.dispose();
      }
    } finally {
      encodedImage.dispose();
    }
    return output.uri;
  }

  /// Re-publish the original queued item after the artwork preference changes.
  void refreshMediaMetadata() {
    if (currentIndex >= 0 && currentIndex < currentQueue.length) {
      _publishMediaItem(currentQueue[currentIndex]);
    }
  }

  /// Start playing a live radio station using platform-generic endpoints.
  Future<void> playRadio({
    required String id,
    required String title,
    String? description,
    String? artUrl,
    String? platformId,
  }) async {
    final pId = platformId ?? PlatformManager.instance.active.platformId;
    final platform =
        PlatformRegistry.instance.get(pId) ?? PlatformManager.instance.active;
    final url = await platform.getRadioStreamUrl(id);
    final path = url != null
        ? (Uri.tryParse(url)?.path.toLowerCase() ?? '')
        : '';
    final urlLower = url?.toLowerCase() ?? '';
    var format = 'MP3';
    int bitrate = 128;
    if (urlLower.isNotEmpty &&
        (path.endsWith('.m4a') ||
            path.endsWith('.mp4') ||
            path.endsWith('.aac') ||
            urlLower.contains('aac') ||
            urlLower.contains('m3u8') ||
            urlLower.contains('hls'))) {
      format = 'AAC';
      bitrate = 128;
    } else if (path.endsWith('.opus') || path.endsWith('.ogg')) {
      format = 'OPUS';
      bitrate = 128;
    } else if (path.endsWith('.flac')) {
      format = 'FLAC';
      bitrate = 0;
    }

    final subtitle = 'Live Radio'.i18n;
    final station = MediaItem(
      id: 'radio:$id',
      title: title,
      artist: subtitle,
      displayTitle: title,
      displaySubtitle: subtitle,
      displayDescription: description,
      artUri: artUrl != null ? Uri.tryParse(artUrl) : null,
      extras: {
        'platformId': pId,
        'isRadio': true,
        'radioId': id,
        'radioUrl': ?url,
        'radioTitle': title,
        'displayArtistName': subtitle,
        'artists': '[]',
        'navigableArtists': '[]',
        'qualityFormat': format,
        'qualityBitrate': bitrate,
        'unavailable': false,
      },
    );
    _radioStationItem = station;
    _radioStateSubject.add(
      RadioState(stationId: id, stationName: title, platformId: pId),
    );
    await _loadQueueAndPlayAtIndex(
      QueueSource(id: id, text: title, source: 'radio'),
      [station],
      0,
    );
    _startRadioPolling();
  }

  void _startRadioPolling() {
    _radioSubscription?.cancel();
    var station = _radioStationItem;
    var state = radioState;
    if (station == null && isRadioItem(mediaItem.value)) {
      station = mediaItem.value;
      _radioStationItem = station;
    }
    if (station == null) return;
    final targetStation = station;

    final pId =
        targetStation.extras?['platformId'] as String? ??
        state?.platformId ??
        'neurokaraoke';
    final radioId =
        targetStation.extras?['radioId'] as String? ??
        state?.stationId ??
        (targetStation.id.startsWith('radio:')
            ? targetStation.id.substring('radio:'.length)
            : targetStation.id);

    if (state == null) {
      state = RadioState(
        stationId: radioId,
        stationName: targetStation.title,
        platformId: pId,
      );
      _radioStateSubject.add(state);
    }

    final platform =
        PlatformRegistry.instance.get(pId) ?? PlatformManager.instance.active;

    _radioSubscription = platform.getRadioInfoStream(state.stationId).listen((
      info,
    ) {
      _applyRadioNowPlaying(targetStation, info);
    });

    _radioFallbackTimer?.cancel();
    if (!platform.supportsRadioTiming && platform.capabilities.supportsRadio) {
      unawaited(_refreshRadioNowPlaying(platform, targetStation));
      _radioFallbackTimer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => unawaited(_refreshRadioNowPlaying(platform, targetStation)),
      );
    }
  }

  Future<void> _refreshRadioNowPlaying(
    MusicPlatform platform,
    MediaItem station,
  ) async {
    if (_radioRefreshInFlight || _radioStationItem?.id != station.id) return;
    _radioRefreshInFlight = true;
    try {
      final state = radioState;
      if (state == null) return;
      final track = await platform.getRadioNowPlaying(state.stationId);
      _applyRadioNowPlaying(station, RadioNowPlaying(track: track));
    } catch (error, stack) {
      Logger.root.fine('Could not refresh live radio metadata: $error');
      Logger.root.fine('$stack');
    } finally {
      _radioRefreshInFlight = false;
    }
  }

  void _applyRadioNowPlaying(MediaItem station, RadioNowPlaying info) {
    if (_radioStationItem?.id != station.id) return;
    final currentState = radioState;
    if (currentState == null) return;

    final track = info.track;
    if (track == null) {
      _radioSongStart = null;
      if (currentState.nowPlaying != null) {
        _radioStateSubject.add(currentState.copyWith(clearNowPlaying: true));
        setMetadata(station);
      }
      return;
    }

    final previousStart = _radioSongStart;
    if (info.startedAt != null) {
      final start = info.startedAt!.toUtc();
      final audibleTime = _radioAudibleTime;
      if (currentState.nowPlaying?.id != track.id &&
          _player.playing &&
          _player.processingState == ProcessingState.ready &&
          audibleTime != null &&
          audibleTime.isBefore(start) &&
          !start.isAfter(DateTime.now().toUtc())) {
        // A confirmed new song has passed the playout clock. Move to live
        // instead of leaving its progress pinned at zero.
        _reanchorRadioClockToLive();
      }
      if (previousStart != null &&
          currentState.nowPlaying?.id == track.id &&
          previousStart != info.startedAt) {
        Logger.root.info(
          'Radio timing revised for ${track.id}: '
          '${info.startedAt!.difference(previousStart).inMilliseconds} ms',
        );
      }
      _radioSongStart = info.startedAt;
    } else if (currentState.nowPlaying?.id != track.id) {
      _radioSongStart = null;
    }
    final trackInfo = track.toMediaItem();
    final title =
        info.displayTitle ??
        (trackInfo.artist != null
            ? '${trackInfo.artist} - ${trackInfo.title}'
            : trackInfo.title);
    final updatedStation = station.copyWith(
      title: title,
      album: trackInfo.album,
      artist: currentState.stationName,
      displayTitle: title,
      displaySubtitle: currentState.stationName,
      artUri: trackInfo.artUri ?? station.artUri,
      duration: hasRadioClock && _player.playing ? track.duration : null,
      extras: {
        ...?station.extras,
        'thumb': trackInfo.extras?['thumb'],
        'albumId': trackInfo.extras?['albumId'],
        'artists': trackInfo.extras?['artists'],
        'navigableArtists': trackInfo.extras?['navigableArtists'],
        'contributors': trackInfo.extras?['contributors'],
        'caption': trackInfo.extras?['caption'],
        'radioTrackId': track.id,
      },
    );
    final previousStation = _radioStationItem;
    if (currentState.nowPlaying?.id == track.id &&
        previousStart == _radioSongStart &&
        previousStation?.title == updatedStation.title &&
        previousStation?.album == updatedStation.album &&
        previousStation?.artist == updatedStation.artist &&
        previousStation?.displayTitle == updatedStation.displayTitle &&
        previousStation?.displaySubtitle == updatedStation.displaySubtitle &&
        previousStation?.artUri == updatedStation.artUri &&
        previousStation?.duration == updatedStation.duration &&
        mapEquals(previousStation?.extras, updatedStation.extras)) {
      return;
    }
    _radioStateSubject.add(currentState.copyWith(nowPlaying: track));
    _radioStationItem = updatedStation;
    if (currentIndex >= 0 && currentIndex < currentQueue.length) {
      currentQueue[currentIndex] = updatedStation;
    }
    setMetadata(updatedStation);
    // Playback state carries the position shown by notifications and MPRIS.
    unawaited(_broadcastState(_player.playerEvent));
  }

  void _stopRadioPolling() {
    _resetRadioStreamClock();
    _radioSubscription?.cancel();
    _radioSubscription = null;
    _radioFallbackTimer?.cancel();
    _radioFallbackTimer = null;
    _radioRefreshInFlight = false;
    _radioStationItem = null;
    _radioSongStart = null;
    if (_radioStateSubject.value != null) _radioStateSubject.add(null);
  }

  int currentIndex = 0;
  List<MediaItem> currentQueue = [];
  final BehaviorSubject<List<int>> _shuffleIndicesSubject =
      BehaviorSubject<List<int>>.seeded([]);
  List<int> _shuffleIndices = [];
  bool _shuffleModeEnabled = false;
  // True while currentQueue is the shuffled copy of _preShuffleQueue.
  bool _queueShuffled = false;
  List<MediaItem>? _preShuffleQueue;

  int _playRequestId = 0;
  Future<void>? _queueEndRequest;
  Future<void>? _queueLoadRequest;
  int _requestedIndex = -1;
  // A completed event is only actionable after the selected source reached
  // ready. Reopening a failed YTM stream can emit completion for the old load.
  int _completionArmedIndex = -1;
  int _lastQueueLoadAtLength = -1;
  bool _rearranging = false;
  bool _recoveringPlayerError = false;
  bool _playbackRequested = false;
  int _publishedMediaGeneration = 0;
  final Map<String, Future<Uri>> _croppedArtworkUris = {};

  String? _lastRpcTrackId;
  bool? _lastRpcPlaying;
  int? _lastRpcStartTimeMs;

  Future<void>? _disposeRequest;
  Future<void> _playCommandTail = Future<void>.value();
  Future<List<AudioSource>>? _pendingQueueSources;
  int _queueGeneration = 0;
  int _nextTrackPrefetchGeneration = -1;
  final Map<String, ({DateTime? expiresAt, bool failed})>
  _nextTrackPrefetchAttempts = {};
  final Set<String> _nextTrackAudioAttempts = {};
  // Source rows consumed by a paginated queue can exceed visible queue length
  // when live streams are filtered out.
  int _queueSourceOffset = 0;
  String? _sortedPlaylistQueueId;
  List<Track>? _sortedPlaylistQueueTracks;
  bool _preparingQueueForShuffle = false;
  int _consecutiveSourceErrors = 0;
  static const int _maxConsecutiveSourceErrors = 3;
  int _lastSavedPositionMs = 0;
  int _lastSavedQueueIndex = -1;

  AndroidEqualizer equalizer = AndroidEqualizer();

  Future<void> _init() async {
    if (Platform.isAndroid) await _androidRuntimeReady.future;
    await _startSession();
    _playerInitializedCompleter.complete();

    // Keep podcast speed as a preference, and apply it only while an episode
    // is active. Serialize updates so a delayed setSpeed from the previous
    // item cannot override the speed for the newly selected item.
    mediaItem.listen((item) {
      _schedulePlaybackSpeedForCurrentItem();
      if (_radioStateSubject.value != null &&
          (item == null || !isRadioItem(item))) {
        _stopRadioPolling();
      }
    });

    _queueStateSub =
        Rx.combineLatest3<
              List<MediaItem>,
              PlaybackState,
              List<int>,
              QueueState
            >(queue, playbackState, _shuffleIndicesSubject, (
              queue,
              playbackState,
              shuffleIndices,
            ) {
              final validShuffleIndices =
                  playbackState.shuffleMode == AudioServiceShuffleMode.all &&
                      shuffleIndices.length == queue.length
                  ? shuffleIndices
                  : null;
              return QueueState(
                queue,
                playbackState.queueIndex,
                validShuffleIndices,
                playbackState.repeatMode,
                playbackState.shuffleMode,
                canLoadMore: canLoadMoreQueue,
              );
            })
            .distinct()
            .listen(_queueStateSubject.add);

    // Propagate all events from the audio player to AudioService clients.
    _player.playerEventStream.listen((event) {
      _captureRadioStreamClock();
      _updateRadioPlayoutClock(
        playing: event.playing,
        processingState: event.playbackEvent.processingState,
      );
      _broadcastState(event);
    }, onError: _playbackError);

    _player.errorStream.listen((error) {
      Logger.root.warning(
        'Player source failed at queue index $currentIndex: $error',
      );
      if (!_playbackRequested ||
          _requestedIndex >= 0 ||
          (error.index != null && error.index != currentIndex)) {
        return;
      }
      unawaited(_advanceAfterPlayerError(error.index ?? currentIndex));
    });

    // A media item can be published before just_audio has finished installing
    // its source. Reapply on ready so loading a normal track cannot restore a
    // podcast's old speed after the earlier reset.
    _player.processingStateStream.listen((state) {
      if (state == ProcessingState.ready) {
        _schedulePlaybackSpeedForCurrentItem();
      }
    });

    // Keep handler metadata and media controls derived from just_audio's active
    // playlist index. This avoids a separate, potentially stale song pointer.
    _player.currentIndexStream.listen((index) {
      if (_rearranging || index == null) return;
      int queueIndex = index;
      if (queueIndex < 0 || queueIndex >= currentQueue.length) return;
      if (_requestedIndex >= 0 && queueIndex != _requestedIndex) return;
      if (_recoveringPlayerError && queueIndex != currentIndex) return;
      if (queueIndex != currentIndex) {
        Logger.root.info(
          'AudioService: natural track progression from $currentIndex to $queueIndex. Listened: $_currentTrackListenedSeconds seconds',
        );
        if (_currentTrackListenedSeconds >= 10 &&
            currentIndex >= 0 &&
            currentIndex < currentQueue.length) {
          _logListen(currentQueue[currentIndex], isNext: true);
        }
        _startListenSession();
        _completionArmedIndex = -1;
        _consecutiveSourceErrors = 0;
      }
      currentIndex = queueIndex;
      final activeItem = currentQueue[queueIndex];
      _publishMediaItem(activeItem);
      _schedulePlaybackSpeedForCurrentItem();
      unawaited(_addToHistory(activeItem));
      playbackState.add(playbackState.value.copyWith(queueIndex: queueIndex));
      if (currentQueue.length - queueIndex <= 3) {
        unawaited(_loadMoreAtQueueEnd());
      }
      // With just_audio's concatenated sources, a seamless track boundary can
      // change currentIndex without emitting another ProcessingState.ready.
      // Refresh the active stream details here as well so the quality badge
      // is populated for naturally advanced tracks.
      if (_player.processingState == ProcessingState.ready) {
        _onSelectedSourceReady(queueIndex);
      }
    });

    // Update mediaItem duration when player discovers track length (e.g. from stream)
    _player.durationStream.listen((playerDuration) {
      if (isRadioItem(mediaItem.value)) return;
      final playerIndex = _player.currentIndex;
      final sourceTag = _player.sequenceState.currentSource?.tag;
      final current = mediaItem.value;
      if (sourceTag is MediaItem) {
        if (current == null || sourceTag.id != current.id) return;
      } else if (playerIndex == null || playerIndex != currentIndex) {
        return;
      }
      if (playerDuration != null && playerDuration > Duration.zero) {
        final isPodcastEpisode =
            current?.extras?['show'] != null ||
            current?.extras?['showUrl'] != null;
        final shouldUsePlayerDuration =
            isPodcastEpisode ||
            current?.duration == null ||
            current?.duration == Duration.zero;
        if (current != null &&
            shouldUsePlayerDuration &&
            current.duration != playerDuration) {
          final updated = current.copyWith(duration: playerDuration);
          if (currentIndex >= 0 && currentIndex < currentQueue.length) {
            final queuedItem = currentQueue[currentIndex];
            if (queuedItem.id == current.id) {
              currentQueue[currentIndex] = updated;
              queue.add(List.unmodifiable(currentQueue));
              unawaited(_saveQueueToFile());
            }
          }
          _publishMediaItem(updated);
        }
        if (currentIndex >= 0 && currentIndex < currentQueue.length) {
          final activeExtras = currentQueue[currentIndex].extras;
          if (activeExtras?['qualityBitrate'] == null ||
              activeExtras?['qualityBitrate'] == 0) {
            unawaited(_updateActiveStreamMetadata(currentIndex));
          }
        }
      }
    });

    _player.processingStateStream.listen((state) {
      Logger.root.fine(
        'AudioService: _player processingStateStream emitted: $state (repeatMode=${playbackState.value.repeatMode}, handlingCompletion=$_isHandlingCompletion)',
      );
      if (state == ProcessingState.ready) {
        // A damaged stream may briefly become ready after each retry. Keep
        // its retry budget until a different track is selected.
        _onSelectedSourceReady(currentIndex);
      }
      if (state == ProcessingState.completed) {
        _handlePlayerCompleted();
      }
    });

    _player.androidAudioSessionIdStream.listen((session) {
      if (!settings.enableEqualizer && Platform.isAndroid) return;

      equalizer.setEnabled(false);
    });

    // Throttle position updates to avoid spamming the main thread
    _player.positionStream.throttleTime(const Duration(seconds: 1)).listen((
      position,
    ) {
      if (_captureRadioStreamClock()) {
        unawaited(_broadcastState(_player.playerEvent));
      }
      // Safety net: if the completed event was dropped (e.g. it raced the
      // arming of the new source), pick the track end up on the next tick.
      if (_player.processingState == ProcessingState.completed) {
        _handlePlayerCompleted();
      }
      if (mediaItem.value == null || !playbackState.value.playing) {
        return;
      }

      // A signed URL prepared at the start of a long song may expire before
      // the transition. Refresh it near the end while the current song plays.
      final duration = _player.duration ?? mediaItem.value?.duration;
      if (!isRadio &&
          duration != null &&
          duration > Duration.zero &&
          position <= duration) {
        final remaining = duration - position;
        if (remaining <= const Duration(seconds: 30)) {
          unawaited(
            _precacheNextTrack(
              currentIndex,
              minimumValidity: DateTime.now().add(
                remaining + const Duration(seconds: 20),
              ),
            ),
          );
        }
      }

      _currentTrackListenedSeconds++;

      final positionMs = position.inMilliseconds;
      if (currentIndex != _lastSavedQueueIndex ||
          (positionMs - _lastSavedPositionMs).abs() >= 10000) {
        _lastSavedQueueIndex = currentIndex;
        _lastSavedPositionMs = positionMs;
        unawaited(_saveQueueToFile());
      }

      final dur = mediaItem.value?.duration;
      final isEpisode =
          mediaItem.value?.extras?['show'] != null ||
          mediaItem.value?.extras?['showUrl'] != null ||
          queueSource?.source?.startsWith('show') == true ||
          (dur != null && dur > const Duration(minutes: 10));

      // Partial checkpoints for podcasts / long audio / radios every 60 seconds
      if ((isEpisode || isRadioItem(mediaItem.value) || isRadio) &&
          _currentTrackListenedSeconds >= 15) {
        if ((position.inSeconds - _lastLoggedPartialPositionSeconds).abs() >=
            60) {
          _lastLoggedPartialPositionSeconds = position.inSeconds;
          _logListen(mediaItem.value!, isPartial: true);
        }
      }
    });
  }

  void _schedulePlaybackSpeedForCurrentItem() {
    _playbackSpeedUpdateTail = _playbackSpeedUpdateTail.catchError((_) {}).then(
      (_) async {
        // Read after prior updates complete: if the active item changed
        // while setSpeed was in flight, the newest item's preference wins.
        final activeItem =
            currentIndex >= 0 && currentIndex < currentQueue.length
            ? currentQueue[currentIndex]
            : mediaItem.value;
        final isPodcast =
            activeItem?.extras?['show'] != null ||
            activeItem?.extras?['showUrl'] != null;
        final targetSpeed = isPodcast ? cache.podcastPlaybackSpeed : 1.0;
        if ((_player.speed - targetSpeed).abs() > 0.001) {
          await _player.setSpeed(targetSpeed);
        }
      },
    );
  }

  bool _isHandlingCompletion = false;

  /// True when the player is parked at the very end of the selected track.
  /// A stale completion from a failed reload always reports position ~0, so
  /// this is a safe alternative to the "armed" flag.
  bool _playerAtTrackEnd() {
    final duration = _player.duration ?? mediaItem.value?.duration;
    if (duration == null || duration <= Duration.zero) return false;
    final position = _player.position;
    return position > Duration.zero &&
        position >= duration - const Duration(seconds: 2);
  }

  /// Advance (or repeat) after the selected source finished naturally.
  void _handlePlayerCompleted() {
    if (_isHandlingCompletion ||
        !_playbackRequested ||
        _requestedIndex >= 0 ||
        _player.currentIndex != currentIndex) {
      return;
    }
    if (_completionArmedIndex != currentIndex && !_playerAtTrackEnd()) return;
    _completionArmedIndex = -1;
    _isHandlingCompletion = true;
    final completedIndex = currentIndex;
    final Future<void> action;
    if (playbackState.value.repeatMode == AudioServiceRepeatMode.one) {
      action = _player.seek(Duration.zero).then((_) {
        if (currentIndex == completedIndex &&
            _player.currentIndex == completedIndex) {
          _completionArmedIndex = completedIndex;
        }
        unawaited(_player.play());
      });
    } else {
      action = skipToNext();
    }
    // The watchdog guarantees a hung skip can never block later completions.
    unawaited(
      action
          .timeout(const Duration(seconds: 20), onTimeout: () {})
          .catchError((Object error, StackTrace stack) {
            Logger.root.warning(
              'Could not advance after track completion: $error',
              error,
              stack,
            );
          })
          .whenComplete(() => _isHandlingCompletion = false),
    );
  }

  @override
  Future<void> play() async {
    Logger.root.info('AudioService: play callback received');
    // A cold Android media-resumption callback can arrive while _init is still
    // waiting for app settings and the proxy. Do not touch the late player
    // field until that startup work has finished.
    await _playerInitializedCompleter.future;
    _playbackRequested = true;
    if (_consecutiveSourceErrors >= _maxConsecutiveSourceErrors) {
      _consecutiveSourceErrors = 0;
    }
    if (currentQueue.isEmpty) {
      await _ensureQueueLoaded();
    }
    if (!_playbackRequested) return;
    if (currentQueue.isEmpty && cache.history.isNotEmpty) {
      await playFromTrackList(
        [cache.history.last],
        cache.history.last.id!,
        QueueSource(source: 'history', id: 'resume', text: 'Resumed'),
      );
      return;
    }
    if (currentQueue.isEmpty) {
      _playbackRequested = false;
      return;
    }
    final activeItem = mediaItem.value;
    if (activeItem != null && activeItem.id != _loggedTrackId) {
      _addToHistory(activeItem);
    }
    final isRadioActive = isRadioItem(activeItem) || isRadio;
    if (isRadioActive && _radioSubscription == null) {
      _startRadioPolling();
    }
    if (_player.playing) return;
    if (isRadioActive) {
      await _playTrackAtIndex(currentIndex, autoPlay: true);
      return;
    }
    unawaited(_player.play());
  }

  @override
  Future<void> playFromMediaId(
    String mediaId, [
    Map<String, dynamic>? extras,
  ]) async {
    await _ensureQueueLoaded();
    // Check if the mediaId is for Android Auto
    if (mediaId.startsWith(AndroidAuto.prefix)) {
      // Forward the event to Android Auto
      await _androidAuto.playItem(mediaId);
      return;
    }

    // Handle other mediaIds by playing the item at index
    final index = currentQueue.indexWhere((item) => item.id == mediaId);
    if (index != -1) {
      final targetItem = currentQueue[index];
      if (isRadioItem(targetItem) &&
          mediaItem.value?.id == targetItem.id &&
          _radioSubscription == null) {
        _startRadioPolling();
      }
      await _playTrackAtIndex(
        index,
        position: index == currentIndex ? _player.position : Duration.zero,
      );
      if (isRadioItem(targetItem) &&
          mediaItem.value?.id == targetItem.id &&
          _radioSubscription == null) {
        _startRadioPolling();
      }
    } else if (currentQueue.isEmpty) {
      // History is only a fallback when there is no saved queue. Replacing a
      // restored queue here turns Android resumption into a one-track queue.
      final historyIndex = cache.history.indexWhere(
        (item) => item.id == mediaId,
      );
      if (historyIndex != -1) {
        await playFromTrackList(
          [cache.history[historyIndex]],
          cache.history[historyIndex].id!,
          QueueSource(source: 'history', id: 'resume', text: 'Resumed'),
        );
      } else {
        Logger.root.severe(
          'playFromMediaId: MediaItem not found for mediaId: $mediaId',
        );
      }
    } else {
      Logger.root.warning(
        'playFromMediaId: Ignoring stale media ID $mediaId; '
        'keeping the restored queue (${currentQueue.length} items)',
      );
    }
  }

  /// Called by Android when the user taps the media resumption notification
  /// while the app is fully closed. We must load the saved queue here so that
  /// the subsequent play() call has something to play.
  ///
  /// audio_service exposes prepare and prepareFromMediaId as distinct resume
  /// callbacks. Restore the queue before Android asks the handler to play.
  @override
  Future<void> prepare() async {
    Logger.root.info('AudioService: prepare() called (media resumption)');
    await _ensureQueueLoaded();
  }

  @override
  Future<void> prepareFromMediaId(
    String mediaId, [
    Map<String, dynamic>? extras,
  ]) async {
    await _ensureQueueLoaded();
    var index = currentQueue.indexWhere((item) => item.id == mediaId);
    if (index < 0 && currentQueue.isEmpty) {
      index = cache.history.indexWhere((item) => item.id == mediaId);
      if (index >= 0) {
        final item = cache.history[index].toMediaItem();
        queueSource = QueueSource(
          source: 'history',
          id: 'resume',
          text: 'Resumed',
        );
        await _loadQueueAtIndex([item], 0);
        return;
      }
    }
    if (index >= 0 && index < currentQueue.length) {
      await _playTrackAtIndex(
        index,
        position: index == currentIndex ? _player.position : Duration.zero,
        autoPlay: false,
      );
    } else if (currentQueue.isNotEmpty) {
      Logger.root.warning(
        'prepareFromMediaId: Ignoring stale media ID $mediaId; '
        'keeping the restored queue (${currentQueue.length} items)',
      );
    }
  }

  @override
  Future<void> playMediaItem(MediaItem mediaItem) async {
    final track = Track.fromMediaItem(mediaItem);
    await playFromTrackList(
      [track],
      track.id ?? mediaItem.id,
      QueueSource(
        id: mediaItem.id,
        text: mediaItem.title,
        source: 'media_item',
      ),
    );
  }

  Future<void> _ensureQueueLoaded() async {
    await _playerInitializedCompleter.future;
    if (!_queueReadyCompleter.isCompleted) await loadQueueFromFile();
    await _queueReadyCompleter.future;
  }

  @override
  Future<void> pause() async {
    final isRadioActive = isRadioItem(mediaItem.value) || isRadio;
    _playbackRequested = false;
    _currentTrackPauseCount++;
    if (_currentTrackListenedSeconds >= 5 && mediaItem.value != null) {
      _logListen(mediaItem.value!, isPartial: true);
    }
    if (!Platform.isAndroid && !Platform.isIOS) {
      // Never make the pause wait on the Discord IPC connection.
      unawaited(
        DiscordRPCService.getInstance()
            .then((rpc) => rpc.clearRPC())
            .catchError((Object _) {}),
      );
    }
    if (isRadioActive) {
      _resetRadioStreamClock();
      _radioSubscription?.cancel();
      _radioSubscription = null;
      _radioFallbackTimer?.cancel();
      _radioFallbackTimer = null;
      _radioRefreshInFlight = false;
      _radioSongStart = null;
      await _player.stop();
      unawaited(_broadcastState(_player.playerEvent));
      unawaited(_saveQueueToFile());
      return;
    }
    await _player.pause();
    unawaited(_saveQueueToFile());
  }

  @override
  Future<void> stop() async {
    _playbackRequested = false;
    Logger.root.info('stopping player');
    if (_currentTrackListenedSeconds >= 5 && mediaItem.value != null) {
      _logListen(mediaItem.value!, isPartial: true);
    }
    final isRadioActive = isRadioItem(mediaItem.value) || isRadio;
    if (isRadioActive) {
      _stopRadioPolling();
    }
    await _saveQueueToFile();
    await _player.stop();
    if (!Platform.isAndroid && !Platform.isIOS) {
      final rpc = await DiscordRPCService.getInstance();
      rpc.clearRPC();
    }
    await super.stop();
    Logger.root.info('queue saved');
  }

  Future<bool> playing() async {
    return (_player.playing);
  }

  Future<Duration> position() async {
    final position = _player.position;
    return (position);
  }

  @override
  Future<void> addQueueItem(MediaItem mediaItem) async {
    await addQueueItems([mediaItem]);
  }

  @override
  Future<void> addQueueItems(List<MediaItem> mediaItems) =>
      _addQueueItems(mediaItems);

  Future<void> _addQueueItems(
    List<MediaItem> mediaItems, {
    int? expectedQueueGeneration,
  }) async {
    mediaItems = mediaItems
        .where((item) => !_isExcludedQueueLivestreamItem(item))
        .toList();
    if (mediaItems.isEmpty) return;
    if (_player.audioSource == null) {
      final combined = [...currentQueue, ...mediaItems];
      currentQueue = combined;
      _updateShuffleIndices();
      final sources = await _itemsToSources(currentQueue);
      if (expectedQueueGeneration != null &&
          expectedQueueGeneration != _queueGeneration) {
        return;
      }
      await _player.setAudioSources(sources);
      currentIndex = 0;
    } else {
      if (expectedQueueGeneration != null &&
          expectedQueueGeneration != _queueGeneration) {
        return;
      }
      final appendAt = currentQueue.length;
      currentQueue.addAll(mediaItems);
      _preShuffleQueue?.addAll(mediaItems);
      _updateShuffleIndices();
      final sources = await _itemsToSources(mediaItems);
      if (expectedQueueGeneration != null &&
          expectedQueueGeneration != _queueGeneration) {
        return;
      }
      for (var i = 0; i < mediaItems.length; i++) {
        currentQueue[appendAt + i] = mediaItems[i];
      }
      if (sources.isNotEmpty) await _player.addAudioSources(sources);
    }
    queue.add(List.unmodifiable(currentQueue));
    _lastQueueLoadAtLength = -1;
    _updateShuffleIndices();
    playbackState.add(playbackState.value.copyWith(queueIndex: currentIndex));
    // Queue paging may append the next track after the current source became
    // ready. Re-run the one-track pre-cache so that newly available next item
    // is resolved before just_audio needs to open its local proxy URL.
    if (_player.audioSource != null && currentIndex >= 0) {
      unawaited(_precacheNextTrack(currentIndex));
    }
  }

  @override
  Future<void> insertQueueItem(int index, MediaItem mediaItem) async {
    if (index == -1) index = currentIndex + 1;
    index = index.clamp(0, currentQueue.length);
    final source = await _getTrackAudioSource(mediaItem);
    if (source == null) return;
    final updatedItem = source is UriAudioSource && source.tag is MediaItem
        ? source.tag as MediaItem
        : mediaItem;
    _rearranging = true;
    try {
      final hadPlayerQueue = _player.audioSource != null;
      final hadShuffle =
          _shuffleModeEnabled && _shuffleIndices.length == currentQueue.length;
      currentQueue.insert(index, updatedItem);
      _preShuffleQueue?.add(updatedItem);
      if (hadShuffle) {
        // Queue indices at/after the insert point move up by one; the new
        // track is played straight after the current one.
        _shuffleIndices = _shuffleIndices
            .map((i) => i >= index ? i + 1 : i)
            .toList();
        if (index <= currentIndex) currentIndex++;
        final pos = _shuffleIndices.indexOf(currentIndex);
        _shuffleIndices.insert(
          pos >= 0 ? pos + 1 : _shuffleIndices.length,
          index,
        );
      } else if (index <= currentIndex && hadPlayerQueue) {
        currentIndex++;
      }
      _updateShuffleIndices();
      if (!hadPlayerQueue) {
        await _player.setAudioSources(await _itemsToSources(currentQueue));
        currentIndex = 0;
      } else {
        playbackState.add(
          playbackState.value.copyWith(queueIndex: currentIndex),
        );
        await _player.insertAudioSource(index, source);
      }
      queue.add(List.unmodifiable(currentQueue));
    } finally {
      _rearranging = false;
    }
  }

  @override
  Future<void> updateQueue(List<MediaItem> queue) async {
    _queueGeneration++;
    _pendingQueueSources = null;
    _lastQueueLoadAtLength = -1;
    currentQueue = List<MediaItem>.from(queue);
    _queueShuffled = false;
    _preShuffleQueue = null;
    this.queue.add(List.unmodifiable(currentQueue));
    currentIndex = 0;
    _shuffleIndices = [];
    _updateShuffleIndices();
    if (currentQueue.isEmpty) {
      if (mediaItem.hasValue) mediaItem.add(null);
      await _player.clearAudioSources();
      currentIndex = 0;
      playbackState.add(playbackState.value.copyWith(queueIndex: 0));
      return;
    }
    final sources = await _itemsToSources(currentQueue);
    this.queue.add(List.unmodifiable(currentQueue));
    _rearranging = true;
    try {
      await _player.setAudioSources(sources);
    } finally {
      _rearranging = false;
    }
    currentIndex = 0;
    playbackState.add(playbackState.value.copyWith(queueIndex: 0));
  }

  Future<void> clearQueue() async {
    _queueGeneration++;
    _pendingQueueSources = null;
    _lastQueueLoadAtLength = -1;
    currentQueue.clear();
    _queueShuffled = false;
    _preShuffleQueue = null;
    currentIndex = 0;
    queue.add([]);
    _updateShuffleIndices();
    queueSource = null;

    playbackState.add(playbackState.value.copyWith(queueIndex: 0));
    mediaItem.add(null);
    emptied = true;
    await _player.clearAudioSources();
    await removeSavedQueueFile();
  }

  @override
  Future<void> removeQueueItem(MediaItem mediaItem) async {
    final idx = currentQueue.indexOf(mediaItem);
    if (idx != -1) {
      await removeQueueItemAt(idx);
    }
  }

  @override
  Future<void> removeQueueItemAt(int index) async {
    if (index < 0 || index >= currentQueue.length) return;
    _rearranging = true;
    try {
      final removedCurrent = currentIndex == index;
      _preShuffleQueue?.remove(currentQueue[index]);
      currentQueue.removeAt(index);
      if (_shuffleIndices.isNotEmpty) {
        _shuffleIndices = _shuffleIndices
            .where((i) => i != index)
            .map((i) => i > index ? i - 1 : i)
            .toList();
      }
      if (!removedCurrent && currentIndex > index) currentIndex--;
      queue.add(List.unmodifiable(currentQueue));
      _updateShuffleIndices();
      if (removedCurrent) {
        if (currentIndex < currentQueue.length) {
          await _playTrackAtIndex(currentIndex);
        } else if (currentQueue.isNotEmpty) {
          await _playTrackAtIndex(currentQueue.length - 1);
        } else {
          await stop();
        }
      } else {
        playbackState.add(
          playbackState.value.copyWith(queueIndex: currentIndex),
        );
        await _player.removeAudioSourceAt(index);
      }
    } finally {
      _rearranging = false;
    }
  }

  Future<void> moveQueueItem(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= currentQueue.length) return;
    if (newIndex < 0 || newIndex >= currentQueue.length) return;
    _rearranging = true;
    try {
      int remap(int i) {
        if (i == oldIndex) return newIndex;
        var j = i;
        if (j > oldIndex) j--;
        if (j >= newIndex) j++;
        return j;
      }

      final item = currentQueue.removeAt(oldIndex);
      currentQueue.insert(newIndex, item);
      if (_shuffleIndices.isNotEmpty) {
        _shuffleIndices = _shuffleIndices.map(remap).toList();
      }
      currentIndex = remap(currentIndex);
      queue.add(List.unmodifiable(currentQueue));
      _updateShuffleIndices();
      playbackState.add(playbackState.value.copyWith(queueIndex: currentIndex));
      if (_player.audioSource != null) {
        await _player.moveAudioSource(oldIndex, newIndex);
      }
    } finally {
      _rearranging = false;
    }
  }

  @override
  Future<void> skipToNext() async {
    if (currentQueue.isEmpty) return;
    final nextIndex = currentIndex + 1;
    if (nextIndex < currentQueue.length &&
        _playerQueueCanSeekTo(nextIndex) &&
        _requestedIndex < 0 &&
        _player.processingState != ProcessingState.idle &&
        _player.processingState != ProcessingState.loading) {
      _playbackRequested = true;
      await _player.seekToNext();
      _addToHistory(currentQueue[nextIndex]);
      unawaited(_saveQueueToFile());
      return;
    }
    if (nextIndex < currentQueue.length) {
      await _playTrackAtIndex(nextIndex, autoPlay: true);
      return;
    }
    if (playbackState.value.repeatMode == AudioServiceRepeatMode.all &&
        _playerQueueCanSeekTo(0) &&
        _requestedIndex < 0 &&
        _player.processingState != ProcessingState.idle &&
        _player.processingState != ProcessingState.loading) {
      _playbackRequested = true;
      await _player.seek(Duration.zero, index: 0);
      _addToHistory(currentQueue.first);
      unawaited(_saveQueueToFile());
      return;
    }
    if (playbackState.value.repeatMode == AudioServiceRepeatMode.all) {
      await _playTrackAtIndex(0, autoPlay: true);
      return;
    }

    final previousLength = currentQueue.length;
    await _loadMoreAtQueueEnd(force: true);
    if (currentQueue.length > previousLength) {
      await skipToNext();
    } else {
      await stop();
    }
  }

  @override
  Future<void> skipToPrevious() async {
    if (currentQueue.isEmpty) return;
    if (_player.position.inSeconds > 5 &&
        _player.processingState != ProcessingState.idle) {
      if (_player.processingState == ProcessingState.loading) {
        await _playTrackAtIndex(currentIndex, autoPlay: true);
      } else {
        await _player.seek(Duration.zero);
      }
      return;
    }
    final previousIndex = currentIndex > 0
        ? currentIndex - 1
        : playbackState.value.repeatMode == AudioServiceRepeatMode.all
        ? currentQueue.length - 1
        : 0;
    if (_playerQueueCanSeekTo(previousIndex) &&
        _requestedIndex < 0 &&
        _player.processingState != ProcessingState.idle &&
        _player.processingState != ProcessingState.loading) {
      _playbackRequested = true;
      if (currentIndex == 0 && previousIndex == currentQueue.length - 1) {
        await _player.seek(Duration.zero, index: previousIndex);
      } else {
        await _player.seekToPrevious();
      }
      _addToHistory(currentQueue[previousIndex]);
      unawaited(_saveQueueToFile());
      return;
    }
    await _playTrackAtIndex(previousIndex, autoPlay: true);
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (index < 0 || index >= currentQueue.length) return;
    if (_playerQueueCanSeekTo(index) &&
        _requestedIndex < 0 &&
        _player.processingState != ProcessingState.idle &&
        _player.processingState != ProcessingState.loading) {
      _playbackRequested = true;
      await _player.seek(Duration.zero, index: index);
      _addToHistory(currentQueue[index]);
      unawaited(_saveQueueToFile());
      return;
    }
    await _playTrackAtIndex(index, autoPlay: true);
  }

  @override
  Future<void> seek(Duration position) async {
    _currentTrackSeekCount++;
    // After the queue ended (or a stop) the native player is idle and would
    // silently ignore seek(). Reload the selected track at that position.
    if (_player.processingState == ProcessingState.idle &&
        currentQueue.isNotEmpty &&
        currentIndex >= 0 &&
        currentIndex < currentQueue.length &&
        !isRadioItem(mediaItem.value)) {
      await _playTrackAtIndex(
        currentIndex,
        position: position,
        autoPlay: _playbackRequested,
      );
      return;
    }
    await _player.seek(position);
    unawaited(_broadcastState(_player.playerEvent));
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    playbackState.add(playbackState.value.copyWith(repeatMode: repeatMode));
    // The window is only ever a few tracks long, so wrapping at the end of the
    // queue is handled by skipToNext rather than by the native loop mode.
    await _player.setLoopMode(
      repeatMode == AudioServiceRepeatMode.one ? LoopMode.one : LoopMode.off,
    );
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    _shuffleModeEnabled = shuffleMode == AudioServiceShuffleMode.all;
    if (_shuffleModeEnabled &&
        (queueSource?.source == 'playlist_page' ||
            queueSource?.source == 'favorites_page' ||
            queueSource?.source == 'show_page_partial' ||
            queueSource?.source == 'libraryshuffle')) {
      _preparingQueueForShuffle = true;
      try {
        while (canLoadMoreQueue) {
          final previousLength = currentQueue.length;
          await _loadMoreAtQueueEnd();
          if (currentQueue.length == previousLength) break;
        }
      } finally {
        _preparingQueueForShuffle = false;
      }
    }

    await _player.setShuffleModeEnabled(false);

    if (currentQueue.isNotEmpty) {
      final currentItem =
          currentIndex >= 0 && currentIndex < currentQueue.length
          ? currentQueue[currentIndex]
          : null;
      if (_shuffleModeEnabled && !_queueShuffled) {
        // Shuffle = reorder the queue itself: playing track first, rest random.
        _preShuffleQueue = List<MediaItem>.from(currentQueue);
        final rest = List<MediaItem>.from(currentQueue);
        if (currentItem != null) rest.removeAt(currentIndex);
        rest.shuffle();
        currentQueue = [?currentItem, ...rest];
        currentIndex = 0;
        _queueShuffled = true;
      } else if (!_shuffleModeEnabled && _queueShuffled) {
        final original = _preShuffleQueue ?? currentQueue;
        final known = original.map((e) => e.id).toSet();
        final byId = {for (final item in currentQueue) item.id: item};
        // Keep refreshed metadata and anything added while shuffled.
        currentQueue = [
          ...original.map((e) => byId[e.id] ?? e),
          ...currentQueue.where((e) => !known.contains(e.id)),
        ];
        final restored = currentItem == null
            ? -1
            : currentQueue.indexWhere((e) => e.id == currentItem.id);
        currentIndex = restored >= 0 ? restored : 0;
        _preShuffleQueue = null;
        _queueShuffled = false;
      }
      queue.add(List.unmodifiable(currentQueue));
      playbackState.add(playbackState.value.copyWith(queueIndex: currentIndex));
      if (_player.audioSource != null) {
        await _player.setAudioSources(
          await _itemsToSources(currentQueue),
          initialIndex: currentIndex,
          initialPosition: _player.position,
        );
        queue.add(List.unmodifiable(currentQueue));
      }
    }

    _updateShuffleIndices();
    playbackState.add(playbackState.value.copyWith(shuffleMode: shuffleMode));
  }

  void _updateShuffleIndices() {
    // Shuffling reorders the queue itself, so no separate index map is kept.
    _shuffleIndices = [];
    _shuffleIndicesSubject.add(const []);
  }

  void saveQueueToFile() async {
    await _saveQueueToFile();
  }

  @override
  Future<void> onTaskRemoved() async {
    await dispose();
  }

  @override
  Future<void> onNotificationDeleted() async {
    // Android can remove the notification while a failed source is being
    // retried. The handler must stay alive until that recovery completes.
    if (_playbackRequested) return;
    await dispose();
  }

  @override
  Future<List<MediaItem>> getChildren(
    String parentMediaId, [
    Map<String, dynamic>? options,
  ]) async {
    if (parentMediaId == AudioService.recentRootId) {
      if (cache.history.isNotEmpty) {
        return [cache.history.last.toMediaItem()];
      }
      return [];
    }
    //Android audio callback
    return _androidAuto.getScreen(parentMediaId);
  }

  final Map<String, BehaviorSubject<Map<String, dynamic>>> _childrenSubjects =
      {};

  @override
  ValueStream<Map<String, dynamic>> subscribeToChildren(String parentMediaId) {
    return _childrenSubjects.putIfAbsent(
      parentMediaId,
      () => BehaviorSubject.seeded(<String, dynamic>{}),
    );
  }

  void notifyChildrenChanged([String parentMediaId = 'root']) {
    _childrenSubjects[parentMediaId]?.add(<String, dynamic>{});
    try {
      unawaited(
        AudioServicePlatform.instance
            .notifyChildrenChanged(
              NotifyChildrenChangedRequest(
                parentMediaId: parentMediaId,
                options: const <String, dynamic>{},
              ),
            )
            .catchError((Object error, StackTrace stackTrace) {
              if (error is UnimplementedError) return;
              Logger.root.warning(
                'Failed to notify children changed for $parentMediaId',
                error,
                stackTrace,
              );
            }),
      );
    } catch (e) {
      if (e is UnimplementedError) return;
      Logger.root.warning(
        'Failed to notify children changed for $parentMediaId: $e',
      );
    }
  }

  //----------------------------------------------
  // Start internal methods native to AudioHandler
  //----------------------------------------------

  Future<void> _startSession() async {
    Logger.root.info('starting audio service...');

    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());

    configureDesktopAudioPlayer();

    if (settings.ignoreInterruptions == true) {
      _player = AudioPlayer(
        useProxyForRequestHeaders: false,
        useLazyPreparation: true,
        handleInterruptions: false,
        audioPipeline: Platform.isAndroid
            ? AudioPipeline(androidAudioEffects: [equalizer])
            : null,
      );
      // Handle audio interruptions. (ignore)
      session.interruptionEventStream.listen((_) {
        debugPrint('becoming interrupted');
      });
      // Handle unplugged headphones. (ignore)
      session.becomingNoisyEventStream.listen((_) {
        debugPrint('becoming noisy');
      });
    } else {
      _player = AudioPlayer(
        useProxyForRequestHeaders: false,
        useLazyPreparation: true,
        audioPipeline: Platform.isAndroid
            ? AudioPipeline(androidAudioEffects: [equalizer])
            : null,
      );
    }

    await _loadEmptyPlaylist();
    Logger.root.info('audio player initialized!');
    if (Platform.isAndroid) {
      equalizer.setEnabled(false);
    }
  }

  bool? _lastMprisRadio;

  /// Broadcasts the current state to all clients.
  Future<void> _broadcastState(PlayerEvent event) async {
    final keepAlive = _recoveringPlayerError && _playbackRequested;
    final playing = _player.playing || keepAlive;

    final isRadioActive = isRadioItem(mediaItem.value) || isRadio;
    if (isRadioActive && mediaItem.value != null) {
      final current = mediaItem.value!;
      final duration = hasRadioClock && _player.playing
          ? radioState?.nowPlaying?.duration
          : null;
      if (current.duration != duration) {
        setMetadata(current.copyWith(duration: duration));
      }
    }
    final radioPosition = isRadioActive && hasRadioClock
        ? syncedPosition
        : Duration.zero;
    final bufferedAhead = _player.bufferedPosition - _player.position;
    var radioBufferedPosition =
        radioPosition +
        (bufferedAhead > Duration.zero ? bufferedAhead : Duration.zero);
    final radioDuration = mediaItem.value?.duration;
    if (radioDuration != null && radioBufferedPosition > radioDuration) {
      radioBufferedPosition = radioDuration;
    }

    var controls = [
      if (!isRadioActive) MediaControl.skipToPrevious,
      if (playing) MediaControl.pause else MediaControl.play,
      if (!isRadioActive) MediaControl.skipToNext,
      const MediaControl(
        androidIcon: 'drawable/ic_action_stop',
        label: 'stop',
        action: MediaAction.stop,
      ),
    ];

    final Set<MediaAction> systemActions = {
      if (!isRadioActive) ...[
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
        MediaAction.setShuffleMode,
        MediaAction.setRepeatMode,
      ],
    };

    if (Platform.isLinux && _lastMprisRadio != isRadioActive) {
      _lastMprisRadio = isRadioActive;
      final mpris = Mpris();
      mpris.canPause = true;
      mpris.canGoNext = !isRadioActive;
      mpris.canGoPrevious = !isRadioActive;
    }

    playbackState.add(
      playbackState.value.copyWith(
        controls: controls,
        systemActions: systemActions,
        androidCompactActionIndices: isRadioActive
            ? const [0, 1]
            : const [0, 1, 2],
        processingState: _requestedIndex >= 0
            ? AudioProcessingState.loading
            : keepAlive && _player.processingState == ProcessingState.idle
            ? AudioProcessingState.buffering
            : (isRadioActive && _player.processingState == ProcessingState.idle)
            ? AudioProcessingState.ready
            : (_player.audioSource == null &&
                  currentQueue.isNotEmpty &&
                  !_player.playing)
            ? AudioProcessingState.ready
            : const {
                ProcessingState.idle: AudioProcessingState.idle,
                ProcessingState.loading: AudioProcessingState.loading,
                ProcessingState.buffering: AudioProcessingState.buffering,
                ProcessingState.ready: AudioProcessingState.ready,
                ProcessingState.completed: AudioProcessingState.completed,
              }[_player.processingState]!,
        playing: playing,
        updatePosition: _requestedIndex >= 0
            ? Duration.zero
            : isRadioActive
            ? radioPosition
            : _player.position,
        bufferedPosition: _requestedIndex >= 0
            ? Duration.zero
            : isRadioActive
            ? (hasRadioClock && playing ? radioBufferedPosition : Duration.zero)
            : _player.bufferedPosition,
        speed: isRadioActive && _player.processingState != ProcessingState.ready
            ? 0.0
            : _player.speed,
        queueIndex: currentIndex,
      ),
    );

    if (!Platform.isAndroid && !Platform.isIOS && mediaItem.value != null) {
      final positionMs = _player.position.inMilliseconds;
      if (!playing) {
        if (_lastRpcPlaying != false) {
          final rpc = await DiscordRPCService.getInstance();
          rpc.clearRPC();
          _lastRpcPlaying = false;
          _lastRpcStartTimeMs = null;
        }
      } else {
        final currentStartTimeMs =
            DateTime.now().millisecondsSinceEpoch - positionMs;
        bool shouldUpdate =
            _lastRpcTrackId != mediaItem.value!.id ||
            _lastRpcPlaying != true ||
            _lastRpcStartTimeMs == null ||
            (_lastRpcStartTimeMs! - currentStartTimeMs).abs() > 3000;

        if (shouldUpdate) {
          _lastRpcTrackId = mediaItem.value!.id;
          _lastRpcPlaying = true;
          _lastRpcStartTimeMs = currentStartTimeMs;
          unawaited(_updateDiscordRPC(mediaItem.value!));
        }
      }
    }
  }

  Future<void> _loadEmptyPlaylist() async {
    try {
      Logger.root.info('Loading empty playlist...');
      await _player.clearAudioSources();
      currentQueue = [];
      queue.add([]);
      mediaItem.add(null);
    } catch (e) {
      Logger.root.severe('Error loading empty playlist: $e');
    }
  }

  Future<List<AudioSource>> _itemsToSources(List<MediaItem> mediaItems) async {
    // A restored queue can contain hundreds of items. Share these platform
    // lookups instead of sending one storage and connectivity call per item.
    final storageDirectory = Platform.isAndroid || Platform.isIOS
        ? getExternalStorageDirectory()
        : getFlavorSupportDirectory();
    Future<int>? cachedQualityCode;
    Future<int> qualityCode() => cachedQualityCode ??= _preferredQualityCode();
    // Resolve in chunks and yield between them. Firing hundreds of file
    // checks at once floods the event loop with completions and drops frames.
    const chunkSize = 24;
    final resolved = <AudioSource?>[];
    for (var start = 0; start < mediaItems.length; start += chunkSize) {
      final end = math.min(start + chunkSize, mediaItems.length);
      resolved.addAll(
        await Future.wait(
          mediaItems
              .sublist(start, end)
              .map(
                (item) => _getTrackAudioSource(
                  item,
                  storageDirectory: storageDirectory,
                  qualityCode: qualityCode,
                ),
              ),
        ),
      );
      if (end < mediaItems.length) await Future<void>.delayed(Duration.zero);
    }
    final missing = resolved.indexWhere((source) => source == null);
    if (missing >= 0) {
      throw StateError(
        'Could not create audio source for ${mediaItems[missing].id}',
      );
    }
    for (var i = 0; i < resolved.length; i++) {
      final source = resolved[i]!;
      if (source is UriAudioSource && source.tag is MediaItem) {
        mediaItems[i] = source.tag as MediaItem;
      }
    }
    return resolved.cast<AudioSource>();
  }

  Future<AudioSource?> _getTrackAudioSource(
    MediaItem mediaItem, {
    Future<Directory?>? storageDirectory,
    Future<int> Function()? qualityCode,
  }) async {
    String offlinePath = '';
    //Check if offline
    final Directory? directory =
        await (storageDirectory ??
            (Platform.isAndroid || Platform.isIOS
                ? getExternalStorageDirectory()
                : getFlavorSupportDirectory()));
    offlinePath = p.join(directory!.path, 'offline/');

    final platformId = Track.fromMediaItem(mediaItem).platformId;
    File f = File(p.join(offlinePath, platformId, mediaItem.id));
    final legacyFile = File(p.join(offlinePath, mediaItem.id));
    var offlineExists = await f.exists();
    if (!offlineExists && await legacyFile.exists()) {
      f = legacyFile;
      offlineExists = true;
    }
    if (offlineExists) {
      // Offline stream
      try {
        await downloadManager.recoverOfflineTrackMetadata(
          Track.fromMediaItem(mediaItem),
        );
      } catch (error, stackTrace) {
        Logger('AudioPlayerHandler').warning(
          'Could not repair offline metadata for ${mediaItem.id}: $error',
          error,
          stackTrace,
        );
      }
      final currentExtras = Map<String, dynamic>.from(mediaItem.extras ?? {});
      currentExtras['streamUrl'] = Uri.file(f.path).toString();
      final fileInfo = await FormatUtils.resolveStreamInfo(
        Uri.file(f.path).toString(),
        durationSeconds: mediaItem.duration?.inSeconds,
      );
      final downloadedQuality = await downloadManager.getOfflineTrackQuality(
        platformId,
        mediaItem.id,
      );
      final fileFormat = fileInfo['format'] as String?;
      final fileBitrate = fileInfo['bitrate'];
      final formatWasDetected = fileInfo['formatDetected'] == true;
      final storedFormat =
          downloadedQuality?['resolvedFormat'] as String? ??
          currentExtras['qualityFormat'] as String?;
      final storedBitrate =
          downloadedQuality?['resolvedBitrate'] ??
          currentExtras['qualityBitrate'];
      final fileCodec =
          platformId == 'youtube_music' &&
              (fileFormat == 'OGG' || fileFormat == 'WEBM')
          ? 'OPUS'
          : fileFormat;
      // For offline playback, the saved file is authoritative. In particular,
      // YTM files can be WebM/Opus even when old stored metadata says MP3.
      final resolvedFormat = formatWasDetected
          ? fileCodec
          : storedFormat?.isNotEmpty == true
          ? storedFormat
          : null;
      final resolvedBitrate = fileBitrate is num && fileBitrate > 0
          ? fileBitrate
          : storedBitrate;
      if (resolvedFormat != null && resolvedFormat.isNotEmpty) {
        currentExtras['qualityFormat'] = resolvedFormat.toUpperCase();
        if (resolvedBitrate is num && resolvedBitrate > 0) {
          currentExtras['qualityBitrate'] = resolvedBitrate.round();
        } else {
          currentExtras.remove('qualityBitrate');
        }
      } else {
        final qualityIndex = downloadedQuality?['quality'];
        final selectedQuality =
            qualityIndex is int &&
                qualityIndex >= 0 &&
                qualityIndex < AudioQuality.values.length
            ? AudioQuality.values[qualityIndex]
            : null;
        switch (selectedQuality) {
          case AudioQuality.FLAC:
            currentExtras['qualityFormat'] = 'FLAC';
            currentExtras['qualityBitrate'] = 1411;
            break;
          case AudioQuality.MP3_320:
            currentExtras['qualityFormat'] = 'MP3';
            currentExtras['qualityBitrate'] = 320;
            break;
          case AudioQuality.MP3_128:
            currentExtras['qualityFormat'] = 'MP3';
            currentExtras['qualityBitrate'] = 128;
            break;
          default:
            currentExtras.remove('qualityFormat');
            currentExtras.remove('qualityBitrate');
        }
      }
      final updatedMediaItem = mediaItem.copyWith(extras: currentExtras);
      return AudioSource.uri(Uri.file(f.path), tag: updatedMediaItem);
    }

    //Live radio stream
    if (mediaItem.extras?['radioUrl'] != null) {
      final url = mediaItem.extras!['radioUrl'] as String;
      final currentExtras = Map<String, dynamic>.from(mediaItem.extras ?? {});
      if (currentExtras['qualityFormat'] == null) {
        final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
        final urlLower = url.toLowerCase();
        var format = 'MP3';
        int bitrate = 128;
        if (path.endsWith('.m4a') ||
            path.endsWith('.mp4') ||
            path.endsWith('.aac') ||
            urlLower.contains('aac') ||
            urlLower.contains('m3u8') ||
            urlLower.contains('hls')) {
          format = 'AAC';
          bitrate = 128;
        } else if (path.endsWith('.opus') || path.endsWith('.ogg')) {
          format = 'OPUS';
          bitrate = 128;
        } else if (path.endsWith('.flac')) {
          format = 'FLAC';
          bitrate = 0;
        }
        currentExtras['qualityFormat'] = format;
        currentExtras['qualityBitrate'] = bitrate;
      }
      currentExtras['streamUrl'] = url;
      final updatedMediaItem = mediaItem.copyWith(extras: currentExtras);
      return AudioSource.uri(Uri.parse(url), tag: updatedMediaItem);
    }

    //Show episode direct link
    if (mediaItem.extras?['showUrl'] != null) {
      final url = mediaItem.extras!['showUrl'] as String;
      final currentExtras = Map<String, dynamic>.from(mediaItem.extras ?? {});
      final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
      var format = 'MP3';
      if (path.endsWith('.m4a') || path.endsWith('.mp4')) {
        format = 'AAC';
      } else if (path.endsWith('.opus') || path.endsWith('.ogg')) {
        format = 'OPUS';
      } else if (path.endsWith('.flac')) {
        format = 'FLAC';
      }

      currentExtras['qualityFormat'] = format;
      if (format == 'MP3') {
        currentExtras['qualityBitrate'] =
            128; // Deezer episodes are usually 128kbps
      }
      currentExtras['streamUrl'] = url;
      final updatedMediaItem = mediaItem.copyWith(extras: currentExtras);
      return AudioSource.uri(Uri.parse(url), tag: updatedMediaItem);
    }

    try {
      final platform = PlatformRegistry.instance.get(platformId);
      if (platform == null) return null;
      final sourceItem = mediaItem.copyWith(
        extras: {...?mediaItem.extras, 'platformId': platformId},
      );
      final directUri = platform.directPlaybackUri(
        Track.fromMediaItem(sourceItem),
      );
      if (directUri != null) {
        final currentExtras = Map<String, dynamic>.from(
          sourceItem.extras ?? {},
        );
        currentExtras['streamUrl'] = directUri.toString();
        final path = directUri.path.toLowerCase();
        if (path.endsWith('.opus') || path.endsWith('.ogg')) {
          currentExtras['qualityFormat'] = 'OPUS';
        } else if (path.endsWith('.mp3')) {
          currentExtras['qualityFormat'] = 'MP3';
        } else if (path.endsWith('.flac')) {
          currentExtras['qualityFormat'] = 'FLAC';
        }
        final updated = mediaItem.copyWith(extras: currentExtras);
        return AudioSource.uri(directUri, tag: updated);
      }
      final selectedQualityCode =
          await (qualityCode?.call() ?? _preferredQualityCode());
      final streamUri = StreamProxyServer.instance.streamUriFor(
        sourceItem,
        selectedQualityCode,
      );
      final currentExtras = Map<String, dynamic>.from(sourceItem.extras ?? {});
      currentExtras['streamUrl'] = streamUri.toString();

      final updated = mediaItem.copyWith(extras: currentExtras);
      return PlatformAudioSourceFactory.forProvider(
        provider: platform.getStreamProvider(),
        track: Track.fromMediaItem(sourceItem),
        streamUri: streamUri,
        licenseUri: StreamProxyServer.instance.licenseUriFor(
          sourceItem,
          selectedQualityCode,
        ),
        item: updated,
      );
    } catch (e, st) {
      Logger.root.warning('Failed to create local stream URL', e, st);
    }

    return null;
  }

  Future<int> _preferredQualityCode() async {
    var quality = settings.mobileQuality;
    final connectivity = await Connectivity().checkConnectivity();
    if (connectivity.contains(ConnectivityResult.wifi) ||
        connectivity.contains(ConnectivityResult.ethernet)) {
      quality = settings.wifiQuality;
    }
    return settings.getQualityInt(quality);
  }

  void _onSelectedSourceReady(int index) {
    if (_requestedIndex >= 0 ||
        index != currentIndex ||
        _player.currentIndex != index ||
        _player.processingState != ProcessingState.ready) {
      return;
    }
    _schedulePlaybackSpeedForCurrentItem();
    _streamMetadataTimer?.cancel();
    _streamMetadataTimer = null;
    _completionArmedIndex = index;
    unawaited(_updateActiveStreamMetadata(index));
    unawaited(_precacheNextTrack(index));
  }

  Future<void> _updateActiveStreamMetadata(int index) async {
    if (index < 0 || index >= currentQueue.length) return;
    final item = currentQueue[index];
    if (item.extras?['showUrl'] != null || item.extras?['radioUrl'] != null) {
      return;
    }
    try {
      final streamUri = Uri.tryParse(
        item.extras?['streamUrl'] as String? ?? '',
      );
      if (streamUri?.scheme == 'https') {
        await _updateDirectStreamBitrate(item, index, streamUri!);
        return;
      }
      if (streamUri?.scheme == 'file') return;
      final quality =
          int.tryParse(streamUri?.queryParameters['quality'] ?? '') ??
          await _preferredQualityCode();
      final response = await StreamProxyServer.instance.precacheTrack(
        item,
        quality,
      );
      if (response == null || index >= currentQueue.length) return;
      if (currentQueue[index].id != item.id || currentIndex != index) return;
      if (response.requiresFormatProbe ||
          response.bitrate == null ||
          response.bitrate! <= 0) {
        unawaited(_resolveActiveStreamMetadata(item, quality, response, index));
      }

      final extras = Map<String, dynamic>.from(
        currentQueue[index].extras ?? {},
      );
      if (response.format?.isNotEmpty == true) {
        extras['qualityFormat'] = response.format;
      }
      if (response.bitrate != null && response.bitrate! > 0) {
        extras['qualityBitrate'] = response.bitrate;
      }
      if (extras['qualityFormat'] ==
              currentQueue[index].extras?['qualityFormat'] &&
          extras['qualityBitrate'] ==
              currentQueue[index].extras?['qualityBitrate']) {
        return;
      }
      final updated = currentQueue[index].copyWith(extras: extras);
      currentQueue[index] = updated;
      // Publish only active metadata. Re-emitting the queue here can prompt
      // media-session clients to rebuild their queue while playback is active.
      _publishMediaItem(updated);
      unawaited(_saveQueueToFile());
    } catch (error, stack) {
      Logger.root.fine(
        'Could not update active stream quality metadata: $error',
      );
      Logger.root.fine('$stack');
    }
  }

  Future<void> _updateDirectStreamBitrate(
    MediaItem item,
    int index,
    Uri streamUri,
  ) async {
    final existingBitrate = item.extras?['qualityBitrate'];
    if (existingBitrate is num && existingBitrate > 0) return;
    final track = Track.fromMediaItem(item);
    final platform = PlatformRegistry.instance.get(track.platformId);
    if (platform?.directPlaybackUri(track) != streamUri) return;

    final key = '${track.platformId}:${item.id}:$streamUri';
    if (_directBitrateKey != key) {
      _directBitrateKey = key;
      _directBitrateLookup = platform!.getStreamProvider().resolveBitrate(
        track,
        settings.mobileQuality,
      );
    }
    final bitrate = await _directBitrateLookup;
    if (bitrate == null || bitrate <= 0 || index >= currentQueue.length) {
      return;
    }
    if (currentIndex != index ||
        currentQueue[index].id != item.id ||
        currentQueue[index].extras?['streamUrl'] != streamUri.toString()) {
      return;
    }
    final extras = Map<String, dynamic>.from(currentQueue[index].extras ?? {});
    if (extras['qualityBitrate'] == bitrate) return;
    extras['qualityBitrate'] = bitrate;
    final updated = currentQueue[index].copyWith(extras: extras);
    currentQueue[index] = updated;
    _publishMediaItem(updated);
    unawaited(_saveQueueToFile());
  }

  Future<void> _resolveActiveStreamMetadata(
    MediaItem item,
    int quality,
    StreamResponse resolved,
    int index,
  ) async {
    if (index >= currentQueue.length ||
        currentIndex != index ||
        currentQueue[index].id != item.id) {
      return;
    }
    try {
      final effectiveItem =
          (item.duration != null && item.duration! > Duration.zero)
          ? item
          : (_player.duration != null && _player.duration! > Duration.zero
                ? item.copyWith(duration: _player.duration)
                : item);
      final metadata = await StreamProxyServer.instance.resolveStreamMetadata(
        effectiveItem,
        quality,
        resolved,
      );
      if (metadata == null ||
          index >= currentQueue.length ||
          currentIndex != index ||
          currentQueue[index].id != item.id) {
        return;
      }
      final extras = Map<String, dynamic>.from(
        currentQueue[index].extras ?? {},
      );
      final knownFormat =
          currentQueue[index].extras?['qualityFormat'] as String?;
      if (metadata.format?.isNotEmpty == true && knownFormat != 'FLAC 24-bit') {
        extras['qualityFormat'] = metadata.format;
      }
      if (metadata.bitrate != null && metadata.bitrate! > 0) {
        extras['qualityBitrate'] = metadata.bitrate;
      }
      if (extras['qualityFormat'] ==
              currentQueue[index].extras?['qualityFormat'] &&
          extras['qualityBitrate'] ==
              currentQueue[index].extras?['qualityBitrate']) {
        return;
      }
      final updated = currentQueue[index].copyWith(extras: extras);
      currentQueue[index] = updated;
      _publishMediaItem(updated);
      unawaited(_saveQueueToFile());
    } catch (error, stack) {
      Logger.root.fine('Could not resolve stream format metadata: $error');
      Logger.root.fine('$stack');
    }
  }

  Future<void> _precacheNextTrack(
    int currentQueueIndex, {
    DateTime? minimumValidity,
  }) async {
    final generation = _queueGeneration;
    if (currentQueueIndex < 0 || currentQueueIndex >= currentQueue.length) {
      return;
    }
    var nextIndex = currentQueueIndex + 1;
    if (_shuffleModeEnabled && _shuffleIndices.length == currentQueue.length) {
      final shufflePosition = _shuffleIndices.indexOf(currentQueueIndex);
      if (shufflePosition < 0 ||
          shufflePosition + 1 >= _shuffleIndices.length) {
        return;
      }
      nextIndex = _shuffleIndices[shufflePosition + 1];
    }
    if (nextIndex >= currentQueue.length) return;
    await _precacheQueueItem(
      currentQueue[nextIndex],
      generation,
      minimumValidity: minimumValidity,
    );
  }

  Future<void> _precacheQueueItem(
    MediaItem item,
    int generation, {
    DateTime? minimumValidity,
  }) async {
    if (generation != _queueGeneration) return;
    if (item.extras?['showUrl'] != null || item.extras?['radioUrl'] != null) {
      return;
    }
    try {
      final sourceUri = Uri.tryParse(
        item.extras?['streamUrl'] as String? ?? '',
      );
      if (sourceUri?.scheme == 'https' || sourceUri?.scheme == 'file') return;
      final quality =
          int.tryParse(sourceUri?.queryParameters['quality'] ?? '') ??
          await _preferredQualityCode();
      if (generation != _queueGeneration) return;
      if (_nextTrackPrefetchGeneration != generation) {
        _nextTrackPrefetchGeneration = generation;
        _nextTrackPrefetchAttempts.clear();
        _nextTrackAudioAttempts.clear();
      }
      final key = '${item.extras?['platformId']}:${item.id}:$quality';
      final previous = _nextTrackPrefetchAttempts[key];
      if (previous?.failed == true) return;
      if (previous != null &&
          (previous.expiresAt == null ||
              previous.expiresAt!.isAfter(
                minimumValidity ??
                    DateTime.now().add(const Duration(seconds: 20)),
              ))) {
        if (minimumValidity != null && _nextTrackAudioAttempts.add(key)) {
          final response = await StreamProxyServer.instance.precacheTrack(
            item,
            quality,
          );
          if (response != null) {
            unawaited(
              StreamProxyServer.instance.precacheAudio(item, quality, response),
            );
          }
        }
        return;
      }
      // Mark the request before awaiting it so repeated player events share
      // one attempt. A failed attempt is not retried in the background.
      _nextTrackPrefetchAttempts[key] = (expiresAt: null, failed: true);
      final response = await StreamProxyServer.instance.precacheTrack(
        item,
        quality,
        minimumValidity: minimumValidity,
      );
      if (generation == _queueGeneration && response != null) {
        _nextTrackPrefetchAttempts[key] = (
          expiresAt: response.expiresAt,
          failed:
              minimumValidity != null &&
              response.expiresAt != null &&
              !response.expiresAt!.isAfter(minimumValidity),
        );
        // Resolve the next URL early, but defer copying the full audio file
        // until the current track is near its end. Downloading up to 64 MiB
        // as soon as playback starts can compete with the active stream,
        // especially on mobile and on stable CDN URLs with no expiry.
        final canWarmAudioNow = minimumValidity != null;
        if (canWarmAudioNow && _nextTrackAudioAttempts.add(key)) {
          unawaited(
            StreamProxyServer.instance.precacheAudio(item, quality, response),
          );
        }
      }
    } catch (error, stack) {
      Logger.root.fine('Could not pre-resolve stream ${item.id}: $error');
      Logger.root.fine('$stack');
    }
  }

  Future<void> _startSourceLoad(
    List<AudioSource> sources,
    int index,
    int requestId, {
    Duration position = Duration.zero,
  }) {
    return _player
        .setAudioSources(
          sources,
          initialIndex: index,
          initialPosition: position,
        )
        .then((_) {
          if (requestId != _playRequestId) return;
          _pendingQueueSources = null;
          _requestedIndex = -1;
          _onSelectedSourceReady(index);
          unawaited(_broadcastState(_player.playerEvent));
        })
        .catchError((Object error, StackTrace stack) {
          if (requestId != _playRequestId) return;
          _pendingQueueSources = null;
          _requestedIndex = -1;
          unawaited(_broadcastState(_player.playerEvent));
          Logger.root.warning(
            'Could not load selected queue item $index: $error',
            error,
            stack,
          );
          if (_playbackRequested) {
            unawaited(_advanceAfterPlayerError(index));
          }
        });
  }

  bool _playerQueueCanSeekTo(int index) {
    final sources = _player.audioSources;
    if (_player.audioSource == null ||
        index < 0 ||
        index >= sources.length ||
        sources.length > currentQueue.length) {
      return false;
    }
    final source = sources[index];
    return source is UriAudioSource &&
        source.tag is MediaItem &&
        (source.tag as MediaItem).id == currentQueue[index].id;
  }

  bool _playerQueueHasMatchingPrefix() {
    final sources = _player.audioSources;
    if (_player.audioSource == null || sources.length > currentQueue.length) {
      return false;
    }
    // Queue paging appends MediaItems before it finishes constructing and
    // appending their AudioSources. The already loaded prefix is still valid
    // for skips within that prefix and must not cause a playlist replacement.
    for (var i = 0; i < sources.length; i++) {
      final source = sources[i];
      if (source is! UriAudioSource || source.tag is! MediaItem) {
        return false;
      }
      if ((source.tag as MediaItem).id != currentQueue[i].id) {
        return false;
      }
    }
    return true;
  }

  Future<void> _playTrackAtIndex(
    int index, {
    Duration position = Duration.zero,
    bool autoPlay = true,
  }) async {
    if (index < 0 || index >= currentQueue.length) return;
    _playbackRequested = autoPlay;
    _consecutiveSourceErrors = 0;
    final requestId = ++_playRequestId;
    final bool trackChanged = currentIndex != index;
    if (trackChanged) {
      Logger.root.info(
        'AudioService: track changed from $currentIndex to $index. Listened: $_currentTrackListenedSeconds seconds',
      );
      if (_currentTrackListenedSeconds >= 10 &&
          currentIndex >= 0 &&
          currentIndex < currentQueue.length) {
        _logListen(currentQueue[currentIndex], isNext: true);
      }
      _startListenSession();
    }
    _requestedIndex = index;
    _completionArmedIndex = -1;
    currentIndex = index;
    playbackState.add(
      playbackState.value.copyWith(
        queueIndex: index,
        processingState: AudioProcessingState.loading,
      ),
    );
    final item = currentQueue[index];
    if (isRadioItem(item)) _resetRadioStreamClock();
    _publishMediaItem(item);
    // A track jump should not block on a slow previous network load so a newer
    // selection can immediately replace it.
    final previousCommand = Future<void>.value();
    var targetPosition = position;
    if (targetPosition == Duration.zero) {
      final targetItem = currentQueue[index];
      final isEpisode =
          targetItem.extras?['show'] != null ||
          targetItem.extras?['showUrl'] != null ||
          queueSource?.source?.startsWith('show') == true;
      if (isEpisode) {
        final rawOffset = targetItem.extras?['offset'];
        final offsetSeconds = rawOffset is int
            ? rawOffset
            : (rawOffset is String ? int.tryParse(rawOffset) : null);
        final isHeard = targetItem.extras?['isHeard'] == true;
        if (!isHeard && offsetSeconds != null && offsetSeconds > 5) {
          final totalSeconds = targetItem.duration?.inSeconds ?? 0;
          if (totalSeconds == 0 || offsetSeconds < totalSeconds - 10) {
            targetPosition = Duration(seconds: offsetSeconds);
          }
        }
      }
    }

    final command = previousCommand.catchError((_) {}).then((_) async {
      // Media buttons (especially watch controllers) can issue several skips
      // while an earlier seek is still completing. Let only the newest request
      // touch the player, and let it run after any already-issued seek settles.
      if (requestId != _playRequestId) return;
      try {
        // Keep playWhenReady true during a skip. Pausing here exits Android's
        // media foreground service and releases its wake lock. A cellular
        // stream may then lose background access before the new source loads.
        if (!autoPlay && _player.playing) {
          await _player.pause();
          if (requestId != _playRequestId) return;
        }
        final pendingSources = _pendingQueueSources;
        final playerPos = index;
        // just_audio ignores seeks while loading. Replace that load with the
        // latest requested item instead of waiting for it to finish.
        var canSeekLoadedQueue = _playerQueueCanSeekTo(playerPos);
        if (!canSeekLoadedQueue &&
            pendingSources == null &&
            _playerQueueHasMatchingPrefix() &&
            playerPos >= _player.audioSources.length) {
          // New MediaItems are published before their sources finish appending.
          // Wait for that append rather than rebuilding the loaded prefix.
          try {
            await _player.sequenceStateStream
                .firstWhere(
                  (_) =>
                      requestId != _playRequestId ||
                      _playerQueueCanSeekTo(playerPos),
                )
                .timeout(const Duration(seconds: 20));
          } on TimeoutException {
            final activeIndex = _player.currentIndex;
            if (requestId == _playRequestId &&
                activeIndex != null &&
                activeIndex >= 0 &&
                activeIndex < currentQueue.length) {
              currentIndex = activeIndex;
              _publishMediaItem(currentQueue[activeIndex]);
              playbackState.add(
                playbackState.value.copyWith(queueIndex: activeIndex),
              );
            }
            throw TimeoutException(
              'Timed out waiting for queue source $playerPos to be appended',
            );
          }
          if (requestId != _playRequestId) return;
          canSeekLoadedQueue = _playerQueueCanSeekTo(playerPos);
        }
        if (canSeekLoadedQueue &&
            _player.processingState != ProcessingState.idle &&
            _player.processingState != ProcessingState.loading &&
            playerPos >= 0) {
          await _player.seek(targetPosition, index: playerPos);
          if (requestId != _playRequestId) return;
          _pendingQueueSources = null;
          _requestedIndex = -1;
          _onSelectedSourceReady(index);
        } else if (!canSeekLoadedQueue ||
            pendingSources != null ||
            playerPos < 0 ||
            _player.audioSource == null ||
            _player.processingState == ProcessingState.loading ||
            (canSeekLoadedQueue &&
                _player.processingState == ProcessingState.idle)) {
          // Reuse existing sources when interrupting a native load. Queue
          // paging appends new sources separately above.
          final List<AudioSource> sources;
          if (pendingSources != null) {
            sources = await pendingSources;
          } else if (_playerQueueHasMatchingPrefix()) {
            sources = List<AudioSource>.of(_player.audioSources);
          } else {
            sources = await _itemsToSources(currentQueue);
          }
          if (requestId != _playRequestId) return;
          final sourceLoad = _startSourceLoad(
            sources,
            index,
            requestId,
            position: targetPosition,
          );
          if (!autoPlay) {
            // Android sends prepareFromMediaId and play as separate callbacks
            // for media resumption. Finish installing the saved source before
            // prepare returns, or the following play callback can race the
            // setAudioSources operation and be dropped by just_audio.
            await sourceLoad;
            if (requestId != _playRequestId) return;
          } else {
            unawaited(sourceLoad);
          }
        } else {
          await _player.seek(targetPosition, index: playerPos);
          if (requestId != _playRequestId) return;
          _requestedIndex = -1;
          _onSelectedSourceReady(index);
        }
        if (autoPlay) {
          unawaited(_player.play());
          _addToHistory(item);
        } else {
          await _player.pause();
        }
        _saveQueueToFile();
      } catch (e, st) {
        if (requestId != _playRequestId) return;
        _requestedIndex = -1;
        Logger.root.severe('Error selecting queue item $index: $e', e, st);
        rethrow;
      }
    });
    _playCommandTail = command;
    await command;
  }

  /// Load new queue of MediaItems & play given index & position
  Future<void> _loadQueueAtIndex(
    List<MediaItem> newQueue,
    int index, {
    Duration position = Duration.zero,
  }) async {
    _queueGeneration++;
    _pendingQueueSources = null;
    _lastQueueLoadAtLength = -1;
    currentQueue = List<MediaItem>.from(newQueue);
    queue.add(List.unmodifiable(currentQueue));
    _shuffleModeEnabled = false;
    _queueShuffled = false;
    _preShuffleQueue = null;
    await _player.setShuffleModeEnabled(false);
    if (currentQueue.isEmpty) {
      _updateShuffleIndices();
      await _player.clearAudioSources();
      mediaItem.add(null);
      return;
    }
    _updateShuffleIndices();
    final target = index.clamp(0, currentQueue.length - 1);
    final requestId = ++_playRequestId;
    _consecutiveSourceErrors = 0;
    _requestedIndex = target;
    _completionArmedIndex = -1;
    currentIndex = target;
    _rearranging = true;
    try {
      final sources = await _itemsToSources(currentQueue);
      queue.add(List.unmodifiable(currentQueue));
      _publishMediaItem(currentQueue[target]);
      await _player.setAudioSources(
        sources,
        initialIndex: target,
        initialPosition: position,
      );
      queue.add(List.unmodifiable(currentQueue));
    } catch (_) {
      // A failed load must not leave a pending request behind: while
      // _requestedIndex is set, natural progression and completion are ignored.
      if (requestId == _playRequestId) _requestedIndex = -1;
      rethrow;
    } finally {
      _rearranging = false;
    }
    if (requestId != _playRequestId) return;
    _requestedIndex = -1;
    _onSelectedSourceReady(target);
    _updateShuffleIndices();
    _publishMediaItem(currentQueue[target]);
    playbackState.add(playbackState.value.copyWith(queueIndex: target));
    // Stream URLs and quality metadata are resolved after the source is ready.
    if (currentQueue.length - target <= 3) unawaited(_loadMoreAtQueueEnd());
  }

  Future<void> _loadQueueAndPlayAtIndex(
    QueueSource newQueueSource,
    List<MediaItem> newQueue,
    int index, {
    int? sourceItemsConsumed,
  }) async {
    if (newQueue.isEmpty || index < 0 || index >= newQueue.length) return;
    if (newQueueSource.source == 'radio') {
      _resetRadioStreamClock();
      _radioSongStart = null;
    } else {
      _stopRadioPolling();
    }
    _queueGeneration++;
    _lastQueueLoadAtLength = -1;
    _queueSourceExhausted = false;
    _playbackRequested = true;
    if (_sortedPlaylistQueueId != newQueueSource.id) {
      _sortedPlaylistQueueId = null;
      _sortedPlaylistQueueTracks = null;
    }
    queueSource = newQueueSource;
    _queueSourceOffset = sourceItemsConsumed ?? newQueue.length;
    if (_sortedPlaylistQueueId == newQueueSource.id &&
        (_sortedPlaylistQueueTracks?.length ?? 0) <= _queueSourceOffset) {
      _queueSourceExhausted = true;
    }
    _shuffleModeEnabled = false;
    _queueShuffled = false;
    _preShuffleQueue = null;
    currentQueue = List<MediaItem>.from(newQueue);
    queue.add(List.unmodifiable(currentQueue));
    final requestId = ++_playRequestId;
    _consecutiveSourceErrors = 0;
    _requestedIndex = index;
    _completionArmedIndex = -1;
    currentIndex = index;
    _publishMediaItem(currentQueue[index]);
    playbackState.add(
      playbackState.value.copyWith(
        queueIndex: index,
        shuffleMode: AudioServiceShuffleMode.none,
        processingState: AudioProcessingState.loading,
      ),
    );
    var initialPosition = Duration.zero;
    final targetItem = currentQueue[index];
    final isEpisode =
        targetItem.extras?['show'] != null ||
        targetItem.extras?['showUrl'] != null ||
        newQueueSource.source?.startsWith('show') == true;
    if (isEpisode) {
      final rawOffset = targetItem.extras?['offset'];
      final offsetSeconds = rawOffset is int
          ? rawOffset
          : (rawOffset is String ? int.tryParse(rawOffset) : null);
      final isHeard = targetItem.extras?['isHeard'] == true;
      if (!isHeard && offsetSeconds != null && offsetSeconds > 5) {
        final totalSeconds = targetItem.duration?.inSeconds ?? 0;
        if (totalSeconds == 0 || offsetSeconds < totalSeconds - 10) {
          initialPosition = Duration(seconds: offsetSeconds);
        }
      }
    }

    final sourceSetup = _itemsToSources(currentQueue);
    _pendingQueueSources = sourceSetup;
    try {
      final sources = await sourceSetup;
      if (requestId != _playRequestId) return;
      queue.add(List.unmodifiable(currentQueue));
      _publishMediaItem(currentQueue[index]);
      await _player.setShuffleModeEnabled(false);
      if (requestId != _playRequestId) return;
      _updateShuffleIndices();
      // The selected item is already visible. Start the native load and let
      // the user replace it immediately if they skip again.
      unawaited(
        _startSourceLoad(sources, index, requestId, position: initialPosition),
      );
      unawaited(_player.play());
      if (currentQueue.length - index <= 3) unawaited(_loadMoreAtQueueEnd());
    } catch (error, stack) {
      if (requestId == _playRequestId) {
        _pendingQueueSources = null;
        _requestedIndex = -1;
        _playbackRequested = false;
        playbackState.add(
          playbackState.value.copyWith(
            processingState: AudioProcessingState.idle,
          ),
        );
        Logger.root.warning('Could not start selected queue', error, stack);
      }
      rethrow;
    }
  }

  /// Attempt to load more tracks when queue ends
  Future<bool> _loadMoreAtQueueEnd({bool force = false}) async {
    final pending = _queueEndRequest;
    if (pending != null) {
      await pending;
      return currentQueue.length > _lastQueueLoadAtLength;
    }
    if (force) {
      _queueSourceExhausted = false;
      _lastQueueLoadAtLength = -1;
    }
    if (_queueSourceExhausted ||
        _lastQueueLoadAtLength == currentQueue.length) {
      return false;
    }
    final lengthBefore = currentQueue.length;
    _lastQueueLoadAtLength = lengthBefore;
    final Future<void> request = _onQueueEnd();
    _queueEndRequest = request;
    try {
      await request;
      final added = currentQueue.length > lengthBefore;
      if (!added) {
        _queueSourceExhausted = true;
      }
      return added;
    } catch (error, stack) {
      _queueSourceExhausted = true;
      Logger.root.warning(
        'Failed to extend playback queue: $error',
        error,
        stack,
      );
      return false;
    } finally {
      if (identical(_queueEndRequest, request)) _queueEndRequest = null;
    }
  }

  Future<void> _onQueueEnd() async {
    //Flow
    final source = queueSource;
    if (source == null) return;
    final generation = _queueGeneration;

    String targetId = source.id ?? '';
    String platformId = currentQueue.isEmpty
        ? PlatformManager.instance.active.platformId
        : currentQueue.first.extras?['platformId'] as String? ??
              PlatformManager.instance.active.platformId;

    if (targetId.startsWith('local:')) {
      targetId = targetId.substring('local:'.length);
      platformId = 'local';
    } else if (source.source == 'platform_history_page' &&
        targetId.contains('|')) {
      final prefix = targetId.substring(0, targetId.indexOf('|'));
      if (PlatformRegistry.instance.get(prefix) != null) {
        platformId = prefix;
      }
    } else if (targetId.contains(':') && !targetId.startsWith('local_')) {
      final colonIndex = targetId.indexOf(':');
      final prefix = targetId.substring(0, colonIndex);
      if (PlatformRegistry.instance.get(prefix) != null) {
        platformId = prefix;
        targetId = targetId.substring(colonIndex + 1);
      }
    }

    final platform =
        PlatformRegistry.instance.get(platformId) ??
        PlatformManager.instance.active;
    List<Track> tracks = [];
    List<MediaItem> showItems = [];
    bool? showHasMore;
    int consumedPageCount = 0;
    if (source.source == 'flow') {
      tracks = await platform.getFlow();
    }
    if (source.source == 'smartradio' || source.source == 'artist_smartradio') {
      tracks = await platform.getSmartRadio(targetId);
    }
    if (source.source == 'libraryshuffle') {
      tracks = await platform.getLibraryShuffle(start: _queueSourceOffset);
    }
    if (source.source == 'mix' || source.source == 'track_mix_contextual') {
      tracks = await platform.getMix(targetId);
    }
    if (source.source == 'smarttracklist') {
      try {
        final stl = await platform.getSmartTrackList(targetId);
        final rawTracks = stl.tracks ?? [];
        if (_queueSourceOffset < rawTracks.length) {
          tracks = rawTracks.skip(_queueSourceOffset).take(100).toList();
          consumedPageCount = tracks.length;
        } else {
          tracks = await platform.getMix(targetId);
        }
      } catch (_) {
        tracks = await platform.getMix(targetId);
      }
    }

    final isFavorites =
        source.source == 'favorites_page' ||
        targetId == platform.favoritesQueueSource.id ||
        source.id == platform.favoritesQueueSource.id;
    if (isFavorites) {
      final page = await platform.getFavoriteTracks(
        start: _queueSourceOffset,
        limit: _preparingQueueForShuffle ? 1000 : 100,
        sort: source.sort,
      );
      tracks = page.tracks;
      consumedPageCount = tracks.length;
      if (!page.hasMore) {
        _queueSourceExhausted = true;
      }
    } else if (source.source == 'platform_history_page') {
      final separator = (source.id ?? '').indexOf('|');
      var cursor = separator < 0 ? '' : source.id!.substring(separator + 1);
      if (cursor.isEmpty) {
        _queueSourceExhausted = true;
        return;
      }
      for (
        var skippedEmptyPages = 0;
        skippedEmptyPages < 10;
        skippedEmptyPages++
      ) {
        final page = await platform.getHistoryTracks(cursor: cursor);
        tracks = page.tracks;
        consumedPageCount += tracks.length;
        source.id = '$platformId|${page.nextCursor ?? ''}';
        if (page.nextCursor == null) _queueSourceExhausted = true;
        if (tracks.isNotEmpty || page.nextCursor == null) break;
        cursor = page.nextCursor!;
      }
    } else if (source.source == 'playlist_page' && targetId.isNotEmpty) {
      final pageSize = _preparingQueueForShuffle ? 1000 : 100;
      final isLocal = targetId.startsWith('local_') || platformId == 'local';
      final sort = source.sort;
      final needsSort =
          sort != null && (sort.reverse || sort.type != SortType.DEFAULT);
      if (needsSort) {
        var allTracks = _sortedPlaylistQueueId == source.id
            ? _sortedPlaylistQueueTracks
            : null;
        if (allTracks == null) {
          if (isLocal) {
            final localId = targetId.startsWith('local_')
                ? targetId.substring('local_'.length)
                : targetId;
            final playlist = await downloadManager.getFullLocalPlaylist(
              localId,
            );
            allTracks = playlist?.tracks ?? [];
          } else {
            final playlist = await platform.getFullPlaylist(targetId);
            allTracks = playlist.tracks ?? [];
          }
          allTracks = (allTracks).applySorting(sort);
          _sortedPlaylistQueueId = source.id;
          _sortedPlaylistQueueTracks = allTracks;
        }
        final sortedTracks = allTracks;
        tracks = sortedTracks.skip(_queueSourceOffset).take(pageSize).toList();
        consumedPageCount = tracks.length;
        if (_queueSourceOffset + consumedPageCount >= sortedTracks.length) {
          _queueSourceExhausted = true;
        }
      } else if (isLocal) {
        final cleanId = targetId.startsWith('local_')
            ? targetId.substring('local_'.length)
            : targetId;
        final res = await _getLocalPlaylistPage(
          cleanId,
          _queueSourceOffset,
          pageSize,
        );
        tracks = res.tracks;
        consumedPageCount = res.consumedCount;
      } else {
        tracks = await platform.getPlaylistTracks(
          targetId,
          _queueSourceOffset,
          nb: pageSize,
        );
        consumedPageCount = tracks.length;
      }
    }
    if (source.source == 'show_page_partial' && targetId.isNotEmpty) {
      final page = await platform.getShowEpisodesPage(
        targetId,
        start: currentQueue.length,
        limit: _preparingQueueForShuffle ? 1000 : 50,
      );
      final fallbackShow = Show(
        id: targetId,
        name: source.text,
        platformId: platformId,
      );
      showItems = page.episodes
          .map((episode) => episode.toMediaItem(episode.show ?? fallbackShow))
          .toList();
      showHasMore = page.hasMore;
    }
    if (generation != _queueGeneration || !identical(source, queueSource)) {
      return;
    }
    final sourcePageCount = tracks.length;
    if (isFavorites ||
        source.source == 'playlist_page' ||
        source.source == 'libraryshuffle') {
      _queueSourceOffset += consumedPageCount > 0
          ? consumedPageCount
          : sourcePageCount;
    }
    // Deduplicate tracks already in queue with the same id
    final queueIds = currentQueue
        .map((item) => '${item.extras?['platformId']}\u0000${item.id}')
        .toSet();
    tracks.removeWhere(
      (track) =>
          _isExcludedQueueLivestream(track) ||
          queueIds.contains('${track.platformId}\u0000${track.id}'),
    );
    final extraTracks = tracks.map<MediaItem>((t) => t.toMediaItem()).toList()
      ..addAll(
        showItems.where(
          (item) => !queueIds.contains('$platformId\u0000${item.id}'),
        ),
      );
    if ((consumedPageCount == 0 && sourcePageCount == 0) ||
        extraTracks.isEmpty) {
      _queueSourceExhausted = true;
      _lastQueueLoadAtLength = currentQueue.length;
    }
    if (extraTracks.isEmpty &&
        (consumedPageCount > 0 || sourcePageCount > 0) &&
        (isFavorites ||
            source.source == 'platform_history_page' ||
            source.source == 'playlist_page' ||
            source.source == 'libraryshuffle' ||
            source.source == 'smarttracklist' ||
            source.source == 'flow' ||
            source.source == 'smartradio' ||
            source.source == 'artist_smartradio' ||
            source.source == 'mix' ||
            source.source == 'track_mix_contextual')) {
      // Consume pages containing only live streams or duplicates and keep
      // looking for finite tracks so the queue doesn't stop prematurely.
      _queueSourceExhausted = false;
      _lastQueueLoadAtLength = -1;
      await _onQueueEnd();
      return;
    }
    await _addQueueItems(extraTracks, expectedQueueGeneration: generation);
    if (showHasMore == false && generation == _queueGeneration) {
      _queueSourceExhausted = true;
      _lastQueueLoadAtLength = currentQueue.length;
    }
  }

  Future<({List<Track> tracks, int consumedCount})> _getLocalPlaylistPage(
    String playlistId,
    int start,
    int limit,
  ) async {
    final cleanId = playlistId.startsWith('local_')
        ? playlistId.substring('local_'.length)
        : playlistId;
    final localPlaylist = await downloadManager.localPlaylistManager
        .getPlaylist(cleanId);
    if (localPlaylist == null || start >= localPlaylist.trackIds.length) {
      return (tracks: <Track>[], consumedCount: 0);
    }

    final pageIds = localPlaylist.trackIds.skip(start).take(limit).toList();
    final tracks = await downloadManager.loadLocalPlaylistTracks(
      localPlaylist,
      start: start,
      limit: limit,
    );
    return (tracks: tracks, consumedCount: pageIds.length);
  }

  Future<void> _advanceAfterPlayerError(int failedIndex) async {
    if (_recoveringPlayerError) return;
    _recoveringPlayerError = true;
    unawaited(_broadcastState(_player.playerEvent));
    final requestId = _playRequestId;
    try {
      // Error events can arrive after a controller has already selected a new
      // item. Debounce them and verify the failing source is still current.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (failedIndex >= 0 && failedIndex < queue.value.length) {
        final failedItem = queue.value[failedIndex];
        if (failedItem.extras?['unavailable'] == true) {
          Logger.root.warning(
            'Skipping permanently unavailable track: ${failedItem.title}',
          );
          _consecutiveSourceErrors = 0;
          if (failedIndex < queue.value.length - 1) {
            unawaited(skipToNext());
          } else {
            _playbackRequested = false;
            _completionArmedIndex = -1;
            if (requestId == _playRequestId) await _player.pause();
          }
          return;
        }
      }
      for (; _consecutiveSourceErrors < _maxConsecutiveSourceErrors;) {
        if (requestId != _playRequestId ||
            !_playbackRequested ||
            _requestedIndex >= 0 ||
            failedIndex != currentIndex) {
          return;
        }
        _consecutiveSourceErrors++;
        // Wait for a seek already started by a skip command before retrying.
        await _playCommandTail.catchError((_) {});
        await Future<void>.delayed(
          Duration(milliseconds: 150 * _consecutiveSourceErrors),
        );
        if (requestId != _playRequestId || !_playbackRequested) return;
        try {
          final retryPosition = _player.position;
          final retrySources = List<AudioSource>.of(_player.audioSources);
          if (isRadioItem(mediaItem.value)) {
            _resetRadioStreamClock();
          } else if (failedIndex >= 0 && failedIndex < currentQueue.length) {
            final failedItem = currentQueue[failedIndex];
            final oldUri = Uri.tryParse(
              failedItem.extras?['streamUrl'] as String? ?? '',
            );
            final quality =
                int.tryParse(oldUri?.queryParameters['quality'] ?? '') ??
                await _preferredQualityCode();
            if (oldUri?.scheme != 'file' &&
                failedItem.extras?['radioUrl'] == null &&
                failedItem.extras?['showUrl'] == null) {
              StreamProxyServer.instance.invalidateResolvedTrack(
                failedItem,
                quality,
              );
            }
            final refreshedSource = await _getTrackAudioSource(
              failedItem,
              qualityCode: () async => quality,
            );
            if (refreshedSource == null) {
              throw StateError(
                'Could not rebuild stream source for ${failedItem.id}',
              );
            }
            if (failedIndex >= retrySources.length) {
              retrySources
                ..clear()
                ..addAll(await _itemsToSources(currentQueue));
            } else {
              retrySources[failedIndex] = refreshedSource;
            }
            if (refreshedSource is UriAudioSource &&
                refreshedSource.tag is MediaItem) {
              currentQueue[failedIndex] = refreshedSource.tag as MediaItem;
              queue.add(List.unmodifiable(currentQueue));
            }
          }
          await _player.setAudioSources(
            retrySources,
            initialIndex: failedIndex < 0 ? 0 : failedIndex,
            initialPosition: retryPosition,
          );
          if (requestId != _playRequestId || !_playbackRequested) return;
          // play() completes when playback finishes, so do not await it here.
          unawaited(_player.play());
          return;
        } catch (error, stack) {
          Logger.root.warning(
            'Could not retry queue item $failedIndex '
            '(attempt $_consecutiveSourceErrors): $error',
            error,
            stack,
          );
        }
      }
      Logger.root.warning(
        'Keeping queue item $failedIndex selected after '
        '$_consecutiveSourceErrors source errors; it can be retried manually.',
      );
      _playbackRequested = false;
      _completionArmedIndex = -1;
      if (requestId == _playRequestId) await _player.pause();
    } finally {
      _recoveringPlayerError = false;
      unawaited(_broadcastState(_player.playerEvent));
    }
  }

  void _playbackError(dynamic err, StackTrace stacktrace) {
    Logger.root.severe('Playback Error from audioservice: ${err.code}', err);
    if (err.code == 'abort' && err.message == 'Connection aborted') {
      return;
    }
    _onError(err, stacktrace);
  }

  void _onError(
    PlatformException err,
    StackTrace stacktrace, {
    bool stopService = false,
  }) {
    Logger.root.severe('Error from audioservice: ${err.code}', err);
    if (stopService) stop();
  }

  Future<void> _addToHistory(MediaItem item) async {
    if (!_player.playing) return;
    if (_scrobblenautReady && _loggedTrackId != item.id) {
      Logger.root.info('scrobbling track ${item.id} to recently LastFM');
      _loggedTrackId = item.id;
      try {
        await _scrobblenaut?.track.scrobble(
          track: item.title,
          artist: item.artist ?? '',
          album: item.album,
        );
      } catch (error, stack) {
        Logger.root.warning(
          'Could not scrobble ${item.id} to Last.fm',
          error,
          stack,
        );
      }
    }

    if (cache.history.isNotEmpty && cache.history.last.id == item.id) return;
    Logger.root.info('adding track ${item.id} to recently played history');
    cache.history.add(Track.fromMediaItem(item));
    cache.scheduleSave();
  }

  Future<void> _updateDiscordRPC(MediaItem item) async {
    try {
      final rpc = await DiscordRPCService.getInstance();
      final platformId = item.extras?['platformId'] as String?;
      final platform = platformId != null
          ? PlatformRegistry.instance.get(platformId)
          : null;
      final platformName = platform?.platformName;
      final shareUrl = platform?.getShareUrl('track', item.id);

      // Determine if radio item (duration is null or 0 for radios usually, but could also be explicitly flagged)
      final bool radio =
          isRadioItem(item) ||
          isRadio ||
          item.duration == null ||
          item.duration == Duration.zero;

      final isPlaying = _player.playing;

      if (!isPlaying) {
        rpc.clearRPC();
        return;
      }

      rpc.updateRPC(
        item.title,
        item.artist ?? '',
        item.artUri?.toString() ?? '',
        item.album ?? '',
        platformName: platformName,
        shareUrl: shareUrl,
        timestamps: RPCTimestamps(
          start:
              DateTime.now().millisecondsSinceEpoch -
              _player.position.inMilliseconds,
          end: (!radio && item.duration != null)
              ? DateTime.now().millisecondsSinceEpoch +
                    (item.duration! - _player.position).inMilliseconds
              : null,
        ),
      );
    } catch (e) {
      Logger.root.warning('Failed to update Discord RPC: $e');
    }
  }

  // Get queue save file path
  Future<String> _getQueueFilePath() async {
    Directory? directory = await getFlavorSupportDirectory();
    return p.join(directory.path, 'playback.json');
  }

  bool _queueSaveInFlight = false;
  bool _queueSaveDirty = false;
  final Expando<String> _queueItemJsonCache = Expando<String>('queueItemJson');

  String _encodedQueueItem(MediaItem item) => _queueItemJsonCache[item] ??=
      jsonEncode(MediaItemConverter.mediaItemToMap(item));

  //Export queue to JSON. Requests are coalesced: skips, metadata updates and
  //position ticks can fire many saves, but only one write runs at a time and
  //it always persists the latest state.
  Future _saveQueueToFile() async {
    if (currentIndex == 0 && queue.value.isEmpty) return;
    _queueSaveDirty = true;
    if (_queueSaveInFlight) return;
    _queueSaveInFlight = true;
    try {
      while (_queueSaveDirty) {
        _queueSaveDirty = false;
        // Snapshot synchronously so the written state is self-consistent.
        // MediaItems are immutable, so each item's JSON is encoded once and
        // reused; this avoids re-encoding (or copying into an isolate) the
        // whole queue on every skip.
        final String encoded;
        try {
          final itemsJson = currentQueue.map(_encodedQueueItem).join(',');
          final rest = jsonEncode(<String, dynamic>{
            'index': currentIndex,
            'position': _player.position.inMilliseconds,
            'queueSource': (queueSource ?? QueueSource()).toJson(),
            'sourceOffset': _queueSourceOffset,
            'loopMode': playbackState.value.repeatMode.index,
          });
          encoded =
              '${rest.substring(0, rest.length - 1)},"queue":[$itemsJson]}';
        } catch (error, stack) {
          Logger.root.warning('Could not encode queue: $error', error, stack);
          continue;
        }
        try {
          final path = await _getQueueFilePath();
          await File(path).writeAsString(encoded);
        } catch (error, stack) {
          Logger.root.warning('Could not save queue: $error', error, stack);
        }
      }
    } finally {
      _queueSaveInFlight = false;
    }
  }

  //----------------------------------------------------------------------------------------------
  // Start app specific public methods.
  // Candidates for refactoring to "customAction"s to be called from the UI (PlayerHelper class)?
  //----------------------------------------------------------------------------------------------

  Future<void> waitForPlayerInitialization() async {
    await _playerInitializedCompleter.future;
  }

  Future<void> dispose() => _disposeRequest ??= _disposeInternal();

  Future<void> _disposeInternal() async {
    await _unavailableStreamSub.cancel();
    await _offlineTracksRemovedSub.cancel();
    await _connectivitySub.cancel();
    _streamMetadataTimer?.cancel();
    _queueStateSub?.cancel();
    await _shuffleIndicesSubject.close();
    await stop();
    await _player.dispose();
    await StreamProxyServer.instance.stop();
  }

  //Restore queue & playback info from path. Keep one in-flight restore so
  //startup and Android media-resumption callbacks cannot race to replace it.
  Future<void> loadQueueFromFile() =>
      _queueLoadRequest ??= _loadQueueFromFile();

  Future<void> _loadQueueFromFile() async {
    Logger.root.info('looking for saved queue file...');
    try {
      File f = File(await _getQueueFilePath());
      if (await f.exists()) {
        Logger.root.info('saved queue file found, loading...');
        final content = await f.readAsString();
        final Map<String, dynamic> json = jsonDecode(content);
        List<MediaItem> savedQueue = (json['queue'] ?? []).map<MediaItem>((mi) {
          var item = MediaItemConverter.mediaItemFromMap(mi);
          final restoredPlatformId =
              item.extras?['platformId'] as String? ?? 'deezer';
          if (item.extras?['platformId'] == null) {
            item = item.copyWith(
              extras: {...?item.extras, 'platformId': restoredPlatformId},
            );
          }
          if (!isRadioItem(item)) return item;
          final stationName = item.extras?['radioTitle'];
          if (stationName is! String || stationName.isEmpty) return item;
          return item.copyWith(
            artist: 'Live Radio'.i18n,
            displaySubtitle: 'Live Radio'.i18n,
            extras: {...?item.extras, 'displayArtistName': 'Live Radio'.i18n},
          );
        }).toList();
        final int savedIndex = json['index'] ?? 0;
        final consumedQueueLength = savedQueue.length;
        final Duration lastPos = Duration(milliseconds: json['position'] ?? 0);
        queueSource = QueueSource.fromJson(json['queueSource'] ?? {});
        if (queueSource?.source != 'radio') {
          savedQueue.removeWhere(_isExcludedQueueLivestreamItem);
        }
        final lastIndex = savedIndex
            .clamp(0, savedQueue.isEmpty ? 0 : savedQueue.length - 1)
            .toInt();
        final loopModeIndex = json['loopMode'] ?? 0;
        final repeatMode = loopModeIndex < AudioServiceRepeatMode.values.length
            ? AudioServiceRepeatMode.values[loopModeIndex]
            : AudioServiceRepeatMode.none;
        await setRepeatMode(repeatMode);
        //Restore queue & Broadcast
        await _loadQueueAtIndex(savedQueue, lastIndex, position: lastPos);
        _queueSourceOffset =
            (json['sourceOffset'] as int?) ?? consumedQueueLength;
        if (savedQueue.isNotEmpty &&
            lastIndex >= 0 &&
            lastIndex < savedQueue.length) {
          final active = savedQueue[lastIndex];
          if (isRadioItem(active)) {
            _radioStationItem = active;
            _radioStateSubject.add(
              RadioState(
                stationId:
                    active.extras?['radioId'] ??
                    active.id.replaceFirst('radio:', ''),
                stationName: active.extras?['radioTitle'] ?? active.title,
                platformId:
                    active.extras?['platformId'] ??
                    PlatformManager.instance.activePlatformId,
              ),
            );
          }
        }
        // Rebuild sources using current provider/proxy URLs, then persist the
        // regenerated MediaItem tags so stale proxy ports are not restored
        // again on the next launch.
        unawaited(_saveQueueToFile());
        Logger.root.info('saved queue loaded from file!');
      }
    } catch (error, stack) {
      Logger.root.warning(
        'Could not restore the saved playback queue: $error',
        error,
        stack,
      );
    } finally {
      // Always signal that the queue-load attempt is complete, even if it failed or
      // no file existed — so play() doesn't block forever waiting.
      if (!_queueReadyCompleter.isCompleted) {
        _queueReadyCompleter.complete();
      }
    }
  }

  Future removeSavedQueueFile() async {
    String path = await _getQueueFilePath();
    File f = File(path);
    if (await f.exists()) {
      await f.delete();
      Logger.root.info('saved queue file removed!');
    }
  }

  Future authorizeLastFM() async {
    if (settings.lastFMPassword == null) return;
    String username = settings.lastFMUsername ?? '';
    String password = settings.lastFMPassword ?? '';
    try {
      LastFM lastFM = await LastFM.authenticateWithPasswordHash(
        apiKey: settings.lastFMAPIKey ?? '',
        apiSecret: settings.lastFMAPISecret ?? '',
        username: username,
        passwordHash: password,
      );
      _scrobblenaut = Scrobblenaut(lastFM: lastFM);
      _scrobblenautReady = true;
    } catch (e) {
      Logger.root.severe('Error authorizing LastFM: $e');
      Fluttertoast.showToast(msg: 'Authorization error!'.i18n);
    }
  }

  Future<void> disableLastFM() async {
    _scrobblenaut = null;
    _scrobblenautReady = false;
  }

  Future toggleShuffle() async {
    await setShuffleMode(
      _shuffleModeEnabled
          ? AudioServiceShuffleMode.none
          : AudioServiceShuffleMode.all,
    );
  }

  LoopMode getLoopMode() {
    // Map AudioServiceRepeatMode to LoopMode for UI compatibility
    switch (playbackState.value.repeatMode) {
      case AudioServiceRepeatMode.one:
        return LoopMode.one;
      case AudioServiceRepeatMode.all:
        return LoopMode.all;
      default:
        return LoopMode.off;
    }
  }

  //Repeat toggle
  Future changeRepeat() async {
    //Change to next repeat type
    switch (playbackState.value.repeatMode) {
      case AudioServiceRepeatMode.one:
        setRepeatMode(AudioServiceRepeatMode.none);
        break;
      case AudioServiceRepeatMode.all:
        setRepeatMode(AudioServiceRepeatMode.one);
        break;
      default:
        setRepeatMode(AudioServiceRepeatMode.all);
        break;
    }
  }

  Future<void> updateQueueQuality() async {
    if (currentQueue.isEmpty) return;
    final wasPlaying = _player.playing;
    final index = currentIndex.clamp(0, currentQueue.length - 1);
    final position = _player.position;
    await _player.pause();
    _resolvedQualityMetadata(currentQueue);
    _rearranging = true;
    try {
      final sources = await _itemsToSources(currentQueue);
      queue.add(List.unmodifiable(currentQueue));
      await _player.setAudioSources(
        sources,
        initialIndex: index,
        initialPosition: position,
      );
    } finally {
      _rearranging = false;
    }
    currentIndex = index;
    _publishMediaItem(currentQueue[index]);
    playbackState.add(playbackState.value.copyWith(queueIndex: index));
    if (wasPlaying) unawaited(_player.play());
  }

  void _resolvedQualityMetadata(List<MediaItem> items) {
    for (var i = 0; i < items.length; i++) {
      final extras = Map<String, dynamic>.from(items[i].extras ?? {});
      extras.remove('qualityFormat');
      extras.remove('qualityBitrate');
      items[i] = items[i].copyWith(extras: extras);
    }
    queue.add(List.unmodifiable(items));
  }

  //Play track from album
  Future playFromAlbum(Album album, String trackId) async {
    await playFromTrackList(
      album.tracks ?? [],
      trackId,
      QueueSource(id: album.id, text: album.title, source: 'album_page'),
    );
  }

  //Play mix by track
  Future playMix(
    String trackId,
    String trackTitle, {
    String? platformId,
    Track? seedTrack,
  }) async {
    final platform = platformId == null
        ? PlatformManager.instance.active
        : PlatformManager.instance.getPlatform(platformId);
    final tracks = await platform.getMix(trackId);
    if (tracks.isEmpty) {
      final cleanSeedId = trackId.startsWith('RDAMVM')
          ? trackId.substring(6)
          : trackId;
      final seed = seedTrack ?? await platform.getTrack(cleanSeedId);
      await playFromTrackList(
        [seed],
        seed.id ?? cleanSeedId,
        QueueSource(id: trackId, text: trackTitle, source: 'homepage'),
      );
      return;
    }
    final String cleanSeedVideoId = trackId.startsWith('RDAMVM')
        ? trackId.substring(6)
        : trackId;
    Track? resolvedSeed = seedTrack;
    if (resolvedSeed == null) {
      for (final track in tracks) {
        if (track.id == trackId || track.id == cleanSeedVideoId) {
          resolvedSeed = track;
          break;
        }
      }
    }
    resolvedSeed ??= tracks.first;

    final isSeedTrackMatch =
        seedTrack != null ||
        resolvedSeed.id == trackId ||
        resolvedSeed.id == cleanSeedVideoId;
    final mixQueue = <Track>[resolvedSeed];
    for (var i = 0; i < tracks.length; i++) {
      final t = tracks[i];
      if (t.id != resolvedSeed.id) {
        mixQueue.add(t);
      }
    }
    await playFromTrackList(
      mixQueue,
      resolvedSeed.id ?? trackId,
      QueueSource(
        id: trackId,
        text: isSeedTrackMatch
            ? ('Mix based on'.i18n + ' $trackTitle')
            : trackTitle,
        source: 'track_mix_contextual',
      ),
    );
  }

  //Play from artist top tracks
  Future playFromTopTracks(
    List<Track> tracks,
    String trackId,
    Artist artist,
  ) async {
    await playFromTrackList(
      tracks,
      trackId,
      QueueSource(
        id: artist.id,
        text: 'Top ${artist.name}',
        source: 'artist_top',
      ),
    );
  }

  Future playFromPlaylist(
    Playlist playlist,
    String trackId, {
    Sorting? sort,
    int? initialTrackLimit,
  }) async {
    final isLocal =
        playlist.platformId == 'local' ||
        (playlist.id?.startsWith('local_') ?? false);
    final cleanId = playlist.id?.startsWith('local_') == true
        ? playlist.id!.substring('local_'.length)
        : (playlist.id ?? '');
    final queueId = isLocal
        ? 'local_$cleanId'
        : '${playlist.platformId}:${playlist.id}';
    final tracks = playlist.tracks ?? [];
    final needsSort =
        sort != null && (sort.reverse || sort.type != SortType.DEFAULT);
    if (!needsSort && _sortedPlaylistQueueId == queueId) {
      _sortedPlaylistQueueId = null;
      _sortedPlaylistQueueTracks = null;
    }
    if (needsSort && initialTrackLimit != null) {
      final selectedIndex = tracks.indexWhere((track) => track.id == trackId);
      if (selectedIndex < 0) return;
      _sortedPlaylistQueueId = queueId;
      _sortedPlaylistQueueTracks = List<Track>.unmodifiable(tracks);
      final pageLength = selectedIndex + 1 > initialTrackLimit
          ? selectedIndex + 1
          : initialTrackLimit;
      final initialTracks = tracks.take(pageLength).toList();
      await playFromTrackList(
        initialTracks,
        trackId,
        QueueSource(
          id: queueId,
          text: playlist.title,
          source: 'playlist_page',
          sort: sort,
        ),
      );
      return;
    }
    await playFromTrackList(
      tracks,
      trackId,
      QueueSource(
        id: queueId,
        text: playlist.title,
        source: 'playlist_page',
        sort: sort,
      ),
    );
  }

  //Play episode from show, load whole show as queue
  Future playShowEpisode(
    Show show,
    List<ShowEpisode> episodes, {
    int index = 0,
    bool loadMore = false,
  }) async {
    QueueSource showQueueSource = QueueSource(
      id: show.id,
      text: show.name,
      source: loadMore ? 'show_page_partial' : 'show_page',
    );

    //Generate media items
    List<MediaItem> episodeQueue = episodes
        .map<MediaItem>((e) => e.toMediaItem(e.show ?? show))
        .toList();

    // Check if queue is the same by comparing MediaItem IDs
    bool isSameQueue =
        queueSource?.id != null &&
        showQueueSource.id == queueSource!.id &&
        showQueueSource.source == queueSource!.source &&
        episodeQueue.length == currentQueue.length &&
        episodeQueue.asMap().entries.every(
          (entry) => entry.value.id == currentQueue[entry.key].id,
        );

    if (isSameQueue) {
      await skipToQueueItem(index);
    } else {
      //Load and play
      await _loadQueueAndPlayAtIndex(showQueueSource, episodeQueue, index);
    }
  }

  //Load tracks as queue, play track id, set queue source
  Future playFromTrackList(
    List<Track> tracks,
    String trackId,
    QueueSource trackQueueSource,
  ) async {
    Track? liveTrack;
    for (final track in tracks) {
      if (track.id == trackId) {
        liveTrack = track;
        break;
      }
    }
    final selectedLiveTrack = liveTrack;
    if (selectedLiveTrack != null &&
        selectedLiveTrack.id?.startsWith('radio:') == true) {
      await playRadio(
        id: selectedLiveTrack.id!.substring('radio:'.length),
        title: selectedLiveTrack.title ?? '',
        description: selectedLiveTrack.artistString,
        artUrl:
            selectedLiveTrack.albumArt?.full ??
            selectedLiveTrack.albumArt?.thumb,
        platformId: selectedLiveTrack.platformId,
      );
      return;
    }
    _stopRadioPolling();
    //Generate media items
    final trackQueue = tracks
        .where((track) => !_isExcludedQueueLivestream(track))
        .map<MediaItem>((track) => track.toMediaItem())
        .toList();

    // Check if queue is the same by comparing MediaItem IDs
    bool isSameQueue =
        queueSource?.id != null &&
        trackQueueSource.id == queueSource!.id &&
        trackQueue.length == currentQueue.length &&
        trackQueue.asMap().entries.every(
          (entry) => entry.value.id == currentQueue[entry.key].id,
        );

    if (isSameQueue) {
      await skipToQueueItem(trackQueue.indexWhere((m) => m.id == trackId));
    } else {
      //Load and play
      await _loadQueueAndPlayAtIndex(
        trackQueueSource,
        trackQueue,
        trackQueue.indexWhere((m) => m.id == trackId),
        sourceItemsConsumed: tracks.length,
      );
    }
  }

  //Load smart track list as queue, start from beginning
  Future playFromSmartTrackList(SmartTrackList stl) async {
    //Load from API if no tracks
    if ((stl.tracks?.length ?? 0) == 0) {
      if (settings.offlineMode) {
        Fluttertoast.showToast(
          msg: "Offline mode, can't play flow or smart track lists.".i18n,
          gravity: ToastGravity.BOTTOM,
          toastLength: Toast.LENGTH_SHORT,
        );
        return;
      }

      //Flow songs cannot be accessed by smart track list call
      if (stl.id == 'flow') {
        stl.tracks = await PlatformManager.instance.active.getFlow(
          type: stl.flowType,
        );
      } else {
        stl = await PlatformManager.instance.active.getSmartTrackList(
          stl.id ?? '',
        );
      }
    }
    QueueSource queueSource = QueueSource(
      id: stl.id,
      source: (stl.id == 'flow') ? 'flow' : 'smarttracklist',
      text:
          stl.title ??
          ((stl.id == 'flow') ? 'Flow'.i18n : 'Smart track list'.i18n),
    );
    await playFromTrackList(
      stl.tracks ?? [],
      stl.tracks?[0].id ?? '',
      queueSource,
    );
  }

  void _logListen(
    MediaItem item, {
    bool isPartial = false,
    bool isNext = false,
  }) {
    Logger.root.info(
      'AudioService: _logListen called for ${item.id}, isPartial: $isPartial, isNext: $isNext',
    );
    if (!settings.logListen) {
      Logger.root.info(
        'AudioService: _logListen aborted because settings.logListen is false',
      );
      return;
    }
    final dur = item.duration;
    final pos = _player.position;

    // A listen is partial if explicitly requested (e.g., periodic heartbeat)
    // or if the total time listened is less than 75% of the track duration.
    final bool computedPartial =
        isPartial ||
        (dur != null && dur > Duration.zero
            ? _currentTrackListenedSeconds < (dur.inSeconds * 0.75)
            : true);

    String? nextId;
    String? nextType;
    if (currentIndex + 1 < currentQueue.length) {
      final nextItem = currentQueue[currentIndex + 1];
      nextId = nextItem.id;
      final nextSrc = nextItem.extras?['show'];
      nextType = nextSrc != null ? 'episode' : 'song';
    }

    final format =
        item.extras?['qualityFormat'] as String? ??
        (settings.wifiQuality == AudioQuality.FLAC
            ? 'FLAC'
            : settings.wifiQuality == AudioQuality.MP3_320
            ? 'MP3_320'
            : 'MP3_128');

    String? trackOwnerId;
    final navArtistsRaw = item.extras?['navigableArtists'];
    if (navArtistsRaw != null && navArtistsRaw != 'null') {
      try {
        final decoded = navArtistsRaw is String
            ? jsonDecode(navArtistsRaw)
            : navArtistsRaw;
        if (decoded is List && decoded.isNotEmpty) {
          final first = decoded.first;
          if (first is Map && first['id'] != null) {
            trackOwnerId = first['id'].toString();
          }
        }
      } catch (_) {}
    }
    if (trackOwnerId == null) {
      final artistsRaw = item.extras?['artists'];
      if (artistsRaw != null && artistsRaw != 'null') {
        try {
          final decoded = artistsRaw is String
              ? jsonDecode(artistsRaw)
              : artistsRaw;
          if (decoded is List && decoded.isNotEmpty) {
            final first = decoded.first;
            if (first is Map && first['id'] != null) {
              trackOwnerId = first['id'].toString();
            }
          }
        } catch (_) {}
      }
    }

    final details = ListenLogDetails(
      listenDuration: Duration(seconds: _currentTrackListenedSeconds),
      position: pos,
      trackDuration: dur,
      isPartial: computedPartial,
      seekCount: _currentTrackSeekCount,
      pauseCount: _currentTrackPauseCount,
      isNext: isNext,
      isShuffle: playbackState.value.shuffleMode == AudioServiceShuffleMode.all,
      format: format,
      streamId: _currentTrackStreamId,
      nextTrackId: nextId,
      nextTrackType: nextType,
      timestamp:
          _currentTrackStartTime ??
          DateTime.now().subtract(
            Duration(seconds: _currentTrackListenedSeconds),
          ),
      listenTimestamp: DateTime.now(),
      trackOwnerId: trackOwnerId,
    );

    final pId = item.extras?['platformId'] as String?;
    final platform = pId != null
        ? PlatformManager.instance.getPlatform(pId)
        : PlatformManager.instance.active;

    final record = <String, dynamic>{
      'trackId': item.id,
      'platformId': platform.platformId,
      'queueSource': queueSource?.toJson(),
      'details': _listenLogDetailsToJson(details),
    };
    unawaited(_submitOrQueueListenLog(record));
  }

  Map<String, dynamic> _listenLogDetailsToJson(ListenLogDetails details) => {
    'listenDurationMs': details.listenDuration?.inMilliseconds,
    'positionMs': details.position?.inMilliseconds,
    'trackDurationMs': details.trackDuration?.inMilliseconds,
    'isPartial': details.isPartial,
    'seekCount': details.seekCount,
    'pauseCount': details.pauseCount,
    'isNext': details.isNext,
    'isShuffle': details.isShuffle,
    'format': details.format,
    'streamId': details.streamId,
    'nextTrackId': details.nextTrackId,
    'nextTrackType': details.nextTrackType,
    'timestamp': details.timestamp?.toIso8601String(),
    'listenTimestamp': details.listenTimestamp?.toIso8601String(),
    'trackOwnerId': details.trackOwnerId,
  };

  ListenLogDetails _listenLogDetailsFromJson(Map<String, dynamic> json) =>
      ListenLogDetails(
        listenDuration: _durationFromListenLog(json['listenDurationMs']),
        position: _durationFromListenLog(json['positionMs']),
        trackDuration: _durationFromListenLog(json['trackDurationMs']),
        isPartial: json['isPartial'] as bool? ?? false,
        seekCount: json['seekCount'] as int? ?? 0,
        pauseCount: json['pauseCount'] as int? ?? 0,
        isNext: json['isNext'] as bool?,
        isShuffle: json['isShuffle'] as bool?,
        format: json['format'] as String?,
        streamId: json['streamId'] as String?,
        nextTrackId: json['nextTrackId'] as String?,
        nextTrackType: json['nextTrackType'] as String?,
        timestamp: DateTime.tryParse(json['timestamp'] as String? ?? ''),
        listenTimestamp: DateTime.tryParse(
          json['listenTimestamp'] as String? ?? '',
        ),
        trackOwnerId: json['trackOwnerId'] as String?,
      );

  Duration? _durationFromListenLog(dynamic milliseconds) =>
      milliseconds is num ? Duration(milliseconds: milliseconds.round()) : null;

  Future<void> _submitOrQueueListenLog(Map<String, dynamic> record) async {
    var online = false;
    try {
      final results = await Connectivity().checkConnectivity();
      online = results.any((result) => result != ConnectivityResult.none);
    } catch (error) {
      Logger.root.fine(
        'Could not check connectivity before listen log: $error',
      );
    }
    if (!online || settings.offlineMode) {
      cache.pendingListenLogs.add(record);
      await cache.save();
      Logger.root.info(
        'Queued offline listen log for ${record['platformId']}:${record['trackId']}',
      );
      return;
    }
    try {
      await _sendListenLog(record);
    } catch (error, stack) {
      cache.pendingListenLogs.add(record);
      await cache.save();
      Logger.root.warning(
        'Listen logging failed; queued for retry: $error',
        error,
        stack,
      );
    }
    unawaited(_flushPendingListenLogs());
  }

  Future<void> _flushPendingListenLogs() async {
    // Android may construct the audio handler for a media-resume callback
    // before prepareRun() has loaded settings and cache. The handler's player
    // startup already waits for this gate; pending-log retries must do so too.
    if (Platform.isAndroid) await _androidRuntimeReady.future;
    if (_flushingPendingListenLogs || settings.offlineMode) return;
    List<ConnectivityResult> results;
    try {
      results = await Connectivity().checkConnectivity();
    } catch (error) {
      Logger.root.fine(
        'Could not check connectivity for listen log retry: $error',
      );
      return;
    }
    if (!results.any((result) => result != ConnectivityResult.none)) return;
    _flushingPendingListenLogs = true;
    try {
      while (cache.pendingListenLogs.isNotEmpty && !settings.offlineMode) {
        final record = cache.pendingListenLogs.first;
        try {
          await _sendListenLog(record);
          cache.pendingListenLogs.removeAt(0);
          await cache.save();
        } catch (error, stack) {
          Logger.root.warning(
            'Could not submit queued listen log; will retry later: $error',
            error,
            stack,
          );
          break;
        }
      }
    } finally {
      _flushingPendingListenLogs = false;
    }
  }

  Future<void> _sendListenLog(Map<String, dynamic> record) async {
    final trackId = record['trackId'] as String;
    final platformId = record['platformId'] as String;
    final queueJson = record['queueSource'];
    final detailsJson = record['details'];
    final queue = queueJson is Map
        ? QueueSource.fromJson(Map<String, dynamic>.from(queueJson))
        : null;
    final details = detailsJson is Map
        ? _listenLogDetailsFromJson(Map<String, dynamic>.from(detailsJson))
        : null;
    final platform = PlatformManager.instance.getPlatform(platformId);
    Logger.root.info(
      'AudioService: logging listen for $trackId to platform $platformId',
    );
    await platform.logListen(trackId, queue, details: details);
  }

  Future<void> retryPendingListenLogs() => _flushPendingListenLogs();
}

/// True when two items would render identically in the player UI, so that
/// metadata-only updates (quality badge, etc.) don't rebuild whole screens.
bool mediaItemDisplayEquals(MediaItem? a, MediaItem? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  return a.id == b.id &&
      a.title == b.title &&
      a.displayTitle == b.displayTitle &&
      a.artist == b.artist &&
      a.displaySubtitle == b.displaySubtitle &&
      a.album == b.album &&
      a.artUri == b.artUri &&
      a.duration == b.duration &&
      a.extras?['thumb'] == b.extras?['thumb'] &&
      a.extras?['isRadio'] == b.extras?['isRadio'];
}

class QueueState {
  static const QueueState empty = QueueState(
    [],
    0,
    [],
    AudioServiceRepeatMode.none,
    AudioServiceShuffleMode.none,
    canLoadMore: false,
  );

  final List<MediaItem> queue;
  final int? queueIndex;
  final List<int>? shuffleIndices;
  final AudioServiceRepeatMode repeatMode;
  final AudioServiceShuffleMode shuffleMode;
  final bool canLoadMore;

  const QueueState(
    this.queue,
    this.queueIndex,
    this.shuffleIndices,
    this.repeatMode,
    this.shuffleMode, {
    this.canLoadMore = false,
  });

  // Same items are usually the very same instances; avoid deep MediaItem
  // comparisons (extras maps) on every playback-state emission.
  static bool _sameQueue(List<MediaItem> a, List<MediaItem> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i]) && a[i] != b[i]) return false;
    }
    return true;
  }

  List<int> get indices =>
      shuffleIndices ?? List.generate(queue.length, (i) => i);

  int get currentOrderIndex => indices.indexOf(queueIndex ?? 0);

  bool get hasPrevious =>
      repeatMode != AudioServiceRepeatMode.none || currentOrderIndex > 0;

  bool get hasNext =>
      repeatMode != AudioServiceRepeatMode.none ||
      (currentOrderIndex >= 0 && currentOrderIndex + 1 < indices.length) ||
      canLoadMore;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is QueueState &&
          runtimeType == other.runtimeType &&
          _sameQueue(queue, other.queue) &&
          queueIndex == other.queueIndex &&
          listEquals(shuffleIndices, other.shuffleIndices) &&
          repeatMode == other.repeatMode &&
          shuffleMode == other.shuffleMode &&
          canLoadMore == other.canLoadMore;

  @override
  int get hashCode => Object.hash(
    Object.hashAll(queue),
    queueIndex,
    shuffleIndices == null ? null : Object.hashAll(shuffleIndices!),
    repeatMode,
    shuffleMode,
    canLoadMore,
  );
}
