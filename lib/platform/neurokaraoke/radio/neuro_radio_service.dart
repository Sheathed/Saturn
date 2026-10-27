import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import '../../../api/definitions.dart';
import 'signalr_client.dart';

final Logger _log = Logger('NeuroRadio');

/// Station id used by the app (and the AzuraCast station shortcode).
const String kNeuroRadioStationId = 'neuro_21';
const String kNeuroRadioStationName = 'Neuro 21 Station';

const String _kHubUrl = 'https://socket.neurokaraoke.com/radiohub';
const String _kStateUrl =
    'https://socket.neurokaraoke.com/api/radio/current-state';
const String _kAzuraBase = 'https://radio.twinskaraoke.com';
const int _kAzuraStationId = 1;
const String _kStreamUrl =
    '$_kAzuraBase/listen/$kNeuroRadioStationId/radio.mp3';

typedef NeuroTrackMapper = Track Function(Map<String, dynamic> song);

/// The site's own requests carry these; the station and hub check the origin.
const Map<String, String> _kDefaultHeaders = {
  'Accept': '*/*',
  'Origin': 'https://www.neurokaraoke.com',
  'Referer': 'https://www.neurokaraoke.com/',
};

/// "Original artist - Song (Cover artist)", as the station's own player shows
/// it. Neuro Karaoke track titles already carry the original artist.
String radioDisplayTitle(Track track) {
  final title = track.title ?? '';
  final cover = track.artistString;
  return cover == null || cover.isEmpty ? title : '$title ($cover)';
}

/// Snapshot pushed by the radio hub (`RadioStateUpdated`).
class NeuroRadioState {
  final Track? current;
  final List<Track> upcoming;
  final List<Track> history;
  final int listenerCount;
  final bool offline;
  final String? playlistName;

  const NeuroRadioState({
    this.current,
    this.upcoming = const [],
    this.history = const [],
    this.listenerCount = 0,
    this.offline = false,
    this.playlistName,
  });

  factory NeuroRadioState.fromJson(
    Map<String, dynamic> json,
    NeuroTrackMapper mapTrack,
  ) {
    List<Track> tracks(Object? value) => [
      for (final song in value as List<dynamic>? ?? const [])
        if (song is Map<String, dynamic>) mapTrack(song),
    ];
    final current = json['current'];
    return NeuroRadioState(
      current: current is Map<String, dynamic> ? mapTrack(current) : null,
      upcoming: tracks(json['upcoming']),
      history: tracks(json['history']),
      listenerCount: (json['listenerCount'] as num?)?.toInt() ?? 0,
      offline: json['offline'] == true,
      playlistName: json['playlistName'] as String?,
    );
  }

  NeuroRadioState copyWith({
    Track? current,
    List<Track>? upcoming,
    List<Track>? history,
    int? listenerCount,
    bool? offline,
    String? playlistName,
  }) {
    return NeuroRadioState(
      current: current ?? this.current,
      upcoming: upcoming ?? this.upcoming,
      history: history ?? this.history,
      listenerCount: listenerCount ?? this.listenerCount,
      offline: offline ?? this.offline,
      playlistName: playlistName ?? this.playlistName,
    );
  }
}

/// When the station started the song, expressed on this device's clock.
class NeuroRadioTiming {
  /// Neuro Karaoke song id the timing belongs to.
  final String songId;

  /// Station start time before the listener's stream buffer delay.
  final DateTime startedAt;

  const NeuroRadioTiming({required this.songId, required this.startedAt});
}

class NeuroRadioUpdate {
  final NeuroRadioState state;

  /// Null until the station's now-playing feed confirms the current song.
  final NeuroRadioTiming? timing;

  const NeuroRadioUpdate(this.state, [this.timing]);
}

/// One row of the AzuraCast "request a song" catalogue.
class RadioRequestSong {
  final String requestId;
  final String requestUrl;
  final String title;
  final String artist;
  final String? artUrl;
  final String? songId;

  const RadioRequestSong({
    required this.requestId,
    required this.requestUrl,
    required this.title,
    required this.artist,
    this.artUrl,
    this.songId,
  });

  factory RadioRequestSong.fromJson(Map<String, dynamic> row) {
    final song = (row['song'] as Map<String, dynamic>?) ?? const {};
    final custom = song['custom_fields'];
    return RadioRequestSong(
      requestId: row['request_id'] as String,
      requestUrl: row['request_url'] as String,
      title: (song['title'] as String?) ?? (song['text'] as String? ?? ''),
      artist: (song['artist'] as String?) ?? '',
      artUrl: song['art'] as String?,
      songId: custom is Map ? custom['songId'] as String? : null,
    );
  }
}

class RadioRequestPage {
  final List<RadioRequestSong> songs;
  final int page;
  final int perPage;
  final int total;
  final int totalPages;

  const RadioRequestPage({
    required this.songs,
    required this.page,
    required this.perPage,
    required this.total,
    required this.totalPages,
  });

  factory RadioRequestPage.fromJson(Map<String, dynamic> json) =>
      RadioRequestPage(
        songs: [
          for (final row in json['rows'] as List<dynamic>? ?? const [])
            if (row is Map<String, dynamic>) RadioRequestSong.fromJson(row),
        ],
        page: (json['page'] as num?)?.toInt() ?? 1,
        perPage: (json['per_page'] as num?)?.toInt() ?? 25,
        total: (json['total'] as num?)?.toInt() ?? 0,
        totalPages: (json['total_pages'] as num?)?.toInt() ?? 1,
      );
}

/// Raised when the station refuses a request (rate limit, already queued...).
class RadioRequestException implements Exception {
  final String message;

  const RadioRequestException(this.message);

  @override
  String toString() => message;
}

/// Live state of the Neuro 21 radio station.
///
/// The hub (SignalR) pushes which song is on air and how many people are
/// listening. The station's own now-playing feed knows when that song started,
/// which is what makes a progress bar and time-synced lyrics possible. Its
/// played_at is converted from the station clock to this device's clock.
///
/// The connection exists only while [updates] has listeners.
class NeuroRadioService {
  final NeuroTrackMapper _mapTrack;
  final http.Client _http;
  final SignalRClient _hub;
  final DateTime Function() _now;
  final Map<String, String> _headers;
  final Duration timingRetryDelay;

  late final StreamController<NeuroRadioUpdate> _controller =
      StreamController<NeuroRadioUpdate>.broadcast(
        onListen: _start,
        onCancel: _stop,
      );

  NeuroRadioUpdate? _latest;
  NeuroRadioTiming? _timing;
  StreamSubscription<SignalRInvocation>? _hubSub;
  StreamSubscription<String>? _stationEventsSub;
  int _generation = 0;
  bool _hubStateReceived = false;
  int? _azuraFallbackGeneration;
  Future<Duration?>? _clockOffsetFuture;
  DateTime? _clockOffsetFetchedAt;
  Future<_NowPlayingFeed>? _nowPlayingInFlight;
  _NowPlayingFeed? _latestStationFeed;
  DateTime? _lastConfirmedStart;

  NeuroRadioService({
    required NeuroTrackMapper mapTrack,
    Map<String, String> headers = _kDefaultHeaders,
    http.Client? httpClient,
    SignalRClient? hub,
    DateTime Function()? now,
    this.timingRetryDelay = const Duration(seconds: 1),
  }) : _mapTrack = mapTrack,
       _headers = headers,
       _http = httpClient ?? http.Client(),
       _now = now ?? DateTime.now,
       _hub =
           hub ?? SignalRClient(hubUrl: Uri.parse(_kHubUrl), headers: headers);

  /// Latest known state, replayed immediately to new listeners.
  NeuroRadioUpdate? get latest => _latest;

  Stream<NeuroRadioUpdate> get updates =>
      Stream<NeuroRadioUpdate>.multi((controller) {
        final replay = _latest;
        if (replay != null) controller.add(replay);
        final subscription = _controller.stream.listen(
          controller.add,
          onError: controller.addError,
        );
        controller.onCancel = subscription.cancel;
      });

  void _start() {
    final generation = ++_generation;
    _hubStateReceived = false;
    _hubSub = _hub.invocations.listen(
      (invocation) => _onInvocation(invocation, generation),
    );
    _hub.start();
    unawaited(_loadInitialState(generation));
    unawaited(_listenForStationEvents(generation));
  }

  void _stop() {
    _generation++;
    _hubSub?.cancel();
    _hubSub = null;
    _stationEventsSub?.cancel();
    _stationEventsSub = null;
    unawaited(_hub.stop());
    _latest = null;
    _timing = null;
    _nowPlayingInFlight = null;
    _latestStationFeed = null;
    _lastConfirmedStart = null;
    _azuraFallbackGeneration = null;
  }

  Future<void> dispose() async {
    _stop();
    await _hub.dispose();
    _http.close();
    await _controller.close();
  }

  bool _isCurrent(int generation) => generation == _generation;

  Future<void> _listenForStationEvents(int generation) async {
    try {
      final request = http.Request(
        'GET',
        Uri.parse('$_kAzuraBase/api/live/nowplaying/sse'),
      )..headers.addAll({..._headers, 'Accept': 'text/event-stream'});
      final response = await _http.send(request);
      if (!_isCurrent(generation)) {
        await response.stream.listen((_) {}).cancel();
        return;
      }
      if (response.statusCode != 200) {
        await response.stream.listen((_) {}).cancel();
        return;
      }
      _stationEventsSub = response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) {
              if (!line.startsWith('data:')) return;
              unawaited(
                _applyStationEvent(line.substring(5).trim(), generation),
              );
            },
            onError: (Object error) =>
                _log.fine('Radio station event stream failed: $error'),
          );
    } catch (error) {
      _log.fine('Could not open radio station events: $error');
    }
  }

  Future<void> _applyStationEvent(String data, int generation) async {
    if (!_isCurrent(generation) || data.isEmpty) return;
    try {
      final payload = jsonDecode(data);
      // AzuraCast also sends empty events when now-playing may have changed.
      if (payload is Map && payload.isEmpty) {
        final feed = await _fetchNowPlaying();
        if (!_isCurrent(generation)) return;
        _applyStationFeed(feed);
        return;
      }
      final stations = payload is List ? payload : [payload];
      for (final value in stations) {
        if (value is! Map<String, dynamic>) continue;
        final station = value['station'];
        if (station is! Map<String, dynamic> ||
            station['shortcode'] != kNeuroRadioStationId ||
            value['now_playing'] is! Map) {
          continue;
        }
        final offset = await _getClockOffset();
        if (!_isCurrent(generation)) return;
        final feed = _NowPlayingFeed.fromJson(
          value,
          _mapTrack,
          _now().toUtc(),
          offset ?? Duration.zero,
        );
        _applyStationFeed(feed);
        return;
      }
    } catch (error) {
      _log.fine('Could not read radio station event: $error');
    }
  }

  void _applyStationFeed(_NowPlayingFeed feed) {
    if (feed.playedAt <= 0) return;
    _latestStationFeed = feed;
    final state = _latest?.state;
    final current = state?.current;
    if (state != null && current != null && _matchesTrack(feed, current)) {
      _applyConfirmedTiming(current, feed, state);
    }
  }

  bool _applyConfirmedTiming(
    Track current,
    _NowPlayingFeed feed,
    NeuroRadioState state,
  ) {
    if (current.id == null) return false;
    final lastStart = _lastConfirmedStart;
    if (_timing?.songId != current.id &&
        lastStart != null &&
        !feed.startedAt.isAfter(lastStart)) {
      return false;
    }
    final needsDuration =
        (current.duration == null || current.duration == Duration.zero) &&
        feed.duration != null &&
        feed.duration! > Duration.zero;
    final needsUpcoming = state.upcoming.isEmpty && feed.playingNext != null;
    if (_timing?.songId == current.id &&
        _timing?.startedAt == feed.startedAt &&
        !needsDuration &&
        !needsUpcoming) {
      return true;
    }
    _applyNowPlayingMetadata(current, feed);
    _timing = NeuroRadioTiming(songId: current.id!, startedAt: feed.startedAt);
    _lastConfirmedStart = feed.startedAt;
    if (state.upcoming.isEmpty && feed.playingNext != null) {
      state = state.copyWith(upcoming: [feed.playingNext!]);
    }
    _emit(NeuroRadioUpdate(state, _timing));
    return true;
  }

  Future<void> _loadInitialState(int generation) async {
    try {
      // Fetch the station's song timestamp alongside the hub snapshot so the
      // first published position does not wait for two serial requests.
      final nowPlayingFuture = _fetchNowPlaying().then<_NowPlayingFeed?>(
        (feed) => feed,
        onError: (Object error, StackTrace stack) => null,
      );
      final state = await fetchCurrentState();
      if (!_isCurrent(generation)) return;
      if (state.offline && !_hubStateReceived) {
        _applyState(state, generation);
        return;
      }
      final nowPlaying = await nowPlayingFuture;
      if (!_isCurrent(generation)) return;
      if (_hubStateReceived) {
        // Keep the hub's newer state, but use the parallel AzuraCast request
        // when it confirms that state. Otherwise the first timestamp waits
        // for another network round trip after the socket connects.
        final latestState = _latest?.state;
        final current = latestState?.current;
        if (latestState != null &&
            current != null &&
            nowPlaying != null &&
            _matchesTrack(nowPlaying, current)) {
          _applyConfirmedTiming(current, nowPlaying, latestState);
        }
        return;
      }
      final current = state.current;
      var resolvedCurrent = current;
      if (nowPlaying != null && nowPlaying.playedAt > 0) {
        if (current != null &&
            current.id != null &&
            _matchesTrack(nowPlaying, current)) {
          _applyNowPlayingMetadata(current, nowPlaying);
          _timing = NeuroRadioTiming(
            songId: current.id!,
            startedAt: nowPlaying.startedAt,
          );
          _lastConfirmedStart = nowPlaying.startedAt;
        } else {
          // The hub can describe the next song before AzuraCast switches
          // the stream. On join, use the stream's current song and time.
          final azuraTrack = nowPlaying.toTrack();
          if (azuraTrack != null) {
            resolvedCurrent = azuraTrack;
            _timing = NeuroRadioTiming(
              songId: azuraTrack.id!,
              startedAt: nowPlaying.startedAt,
            );
            _lastConfirmedStart = nowPlaying.startedAt;
          }
        }
      }
      // A hub update received during the AzuraCast request supersedes this
      // snapshot, even if the hub was quiet when the request began.
      if (!_isCurrent(generation) || _hubStateReceived) return;
      _applyState(state.copyWith(current: resolvedCurrent), generation);
    } catch (error) {
      _log.fine('Could not load initial radio state: $error');
    }
  }

  void _onInvocation(SignalRInvocation invocation, int generation) {
    if (!_isCurrent(generation) ||
        invocation.target != 'RadioStateUpdated' ||
        invocation.arguments.isEmpty ||
        invocation.arguments.first is! Map<String, dynamic>) {
      return;
    }
    try {
      var state = NeuroRadioState.fromJson(
        invocation.arguments.first as Map<String, dynamic>,
        _mapTrack,
      );
      _hubStateReceived = true;
      final previousCurrent = _latest?.state.current;
      final currentMissingFromHub = state.current == null;
      if (currentMissingFromHub && !state.offline && previousCurrent != null) {
        state = state.copyWith(current: previousCurrent);
      }
      _applyState(state, generation);
      if (currentMissingFromHub && !state.offline) {
        unawaited(
          _resolveAzuraFallback(generation, previousCurrent: previousCurrent),
        );
      }
    } catch (error) {
      _log.warning('Could not parse radio state: $error');
    }
  }

  Future<void> _resolveAzuraFallback(
    int generation, {
    Track? previousCurrent,
  }) async {
    if (_azuraFallbackGeneration == generation || !_isCurrent(generation)) {
      return;
    }
    _azuraFallbackGeneration = generation;
    try {
      final nowPlaying = await _fetchNowPlaying();
      if (!_isCurrent(generation) || nowPlaying.playedAt <= 0) return;
      final latestState = _latest?.state;
      if (latestState == null ||
          latestState.offline ||
          latestState.current?.id != previousCurrent?.id) {
        return;
      }
      final track =
          previousCurrent != null && _matchesTrack(nowPlaying, previousCurrent)
          ? previousCurrent
          : nowPlaying.toTrack();
      if (track == null) return;
      // A static snapshot can still describe the previous song just after a
      // hub update. Keep the current track until AzuraCast advances too.
      if (previousCurrent != null &&
          track.id != previousCurrent.id &&
          _timing?.songId == previousCurrent.id &&
          !nowPlaying.startedAt.isAfter(_timing!.startedAt)) {
        return;
      }
      final previousDuration = track.duration;
      _applyNowPlayingMetadata(track, nowPlaying);
      if (track.id == latestState.current?.id &&
          _timing?.songId == track.id &&
          _timing?.startedAt == nowPlaying.startedAt &&
          previousDuration == track.duration) {
        return;
      }
      _timing = NeuroRadioTiming(
        songId: track.id!,
        startedAt: nowPlaying.startedAt,
      );
      _lastConfirmedStart = nowPlaying.startedAt;
      _emit(NeuroRadioUpdate(latestState.copyWith(current: track), _timing));
    } catch (error) {
      _log.fine('Could not load AzuraCast current track: $error');
    } finally {
      if (_azuraFallbackGeneration == generation) {
        _azuraFallbackGeneration = null;
      }
    }
  }

  void _applyState(NeuroRadioState state, int generation) {
    if (!_isCurrent(generation)) return;
    final current = state.current;
    final previous = _latest?.state.current;
    final previousTiming = _timing;
    final previousDuration = previous?.duration;
    if (current != null &&
        current.id == previous?.id &&
        (current.duration == null || current.duration == Duration.zero) &&
        previousDuration != null &&
        previousDuration > Duration.zero) {
      // Hub refreshes can omit duration after AzuraCast supplied it. Keep the
      // confirmed length for the progress bar.
      current.duration = previousDuration;
    }
    final songChanged = current?.id != previous?.id;
    var resolveTiming = false;
    if (songChanged && _timing?.songId != current?.id) {
      _timing = null;
    }
    final stationFeed = _latestStationFeed;
    if (current?.id != null &&
        stationFeed != null &&
        _matchesTrack(stationFeed, current!) &&
        (!songChanged ||
            (previousTiming == null ||
                    stationFeed.startedAt.isAfter(previousTiming.startedAt)) &&
                (_lastConfirmedStart == null ||
                    stationFeed.startedAt.isAfter(_lastConfirmedStart!)))) {
      _applyNowPlayingMetadata(current, stationFeed);
      _timing = NeuroRadioTiming(
        songId: current.id!,
        startedAt: stationFeed.startedAt,
      );
      _lastConfirmedStart = stationFeed.startedAt;
    }
    if (songChanged && current != null && current.id != null) {
      if (_timing == null || _timing?.songId != current.id) {
        // The hub can announce a song before it reaches the stream. Do not
        // publish a guessed start time that later moves lyrics backwards.
        resolveTiming = true;
      }
    }
    _emit(NeuroRadioUpdate(state, _timing));
    if (resolveTiming) unawaited(_resolveTiming(current!, generation));
  }

  void _emit(NeuroRadioUpdate update) {
    _latest = update;
    if (!_controller.isClosed) _controller.add(update);
  }

  /// Waits for the station's now-playing feed to report the song the hub
  /// announced, then derives when it started. The feed can trail the hub, so
  /// keep checking until the station reports that song or it changes again.
  Future<void> _resolveTiming(Track track, int generation) async {
    // The hub can announce a song before AzuraCast publishes its new state.
    for (var attempt = 0; ; attempt++) {
      if (_timing?.songId == track.id) return;
      if (!_isCurrent(generation) || _latest?.state.current?.id != track.id) {
        return;
      }
      try {
        final nowPlaying = await _fetchNowPlaying();
        if (!_isCurrent(generation) || _latest?.state.current?.id != track.id) {
          return;
        }
        if (_matchesTrack(nowPlaying, track)) {
          final current = _latest!.state.current!;
          _latestStationFeed = nowPlaying;
          if (_applyConfirmedTiming(current, nowPlaying, _latest!.state)) {
            return;
          }
        }
      } catch (error) {
        _log.fine('Radio timing lookup failed: $error');
      }
      await Future<void>.delayed(
        attempt < 7 ? timingRetryDelay : const Duration(seconds: 5),
      );
    }
  }

  bool _matchesTrack(_NowPlayingFeed feed, Track track) {
    if (feed.playedAt <= 0) return false;
    final trackId = track.id;
    if (feed.songId != null && feed.songId!.isNotEmpty) {
      if (trackId != null && trackId.isNotEmpty && feed.songId == trackId) {
        return true;
      }
    }
    String normalize(String s) {
      return s
          .replaceAll(
            RegExp(r'\s*\((Neuro|Evil|Duet)[^\)]*\)', caseSensitive: false),
            '',
          )
          .replaceAll(RegExp(r'[^a-zA-Z0-9\s]'), '')
          .trim()
          .toLowerCase();
    }

    final tTitle = normalize(track.title ?? '');
    final songTitle = normalize(
      (track.title ?? '').split(RegExp(r'\s+-\s+')).last,
    );
    final fTitle = normalize(feed.title ?? '');
    final fText = normalize(feed.text ?? '');

    if (tTitle.isNotEmpty) {
      if (songTitle.isNotEmpty && (songTitle == fTitle || songTitle == fText)) {
        return true;
      }
      if ((fTitle.isNotEmpty && fTitle == tTitle) ||
          (fTitle.length >= 5 &&
              (fTitle.contains(tTitle) || tTitle.contains(fTitle)))) {
        return true;
      }
      if ((fText.isNotEmpty && fText == tTitle) ||
          (fText.length >= 5 &&
              (fText.contains(tTitle) || tTitle.contains(fText)))) {
        return true;
      }
    }
    return false;
  }

  void _applyNowPlayingMetadata(Track track, _NowPlayingFeed feed) {
    final duration = feed.duration;
    if ((track.duration == null || track.duration == Duration.zero) &&
        duration != null &&
        duration > Duration.zero) {
      track.duration = duration;
    }
  }

  Future<_NowPlayingFeed> _fetchNowPlaying() async {
    final inFlight = _nowPlayingInFlight;
    if (inFlight != null) return inFlight;
    final request = _requestNowPlaying();
    _nowPlayingInFlight = request;
    try {
      return await request;
    } finally {
      if (identical(_nowPlayingInFlight, request)) {
        _nowPlayingInFlight = null;
      }
    }
  }

  Future<_NowPlayingFeed> _requestNowPlaying() async {
    final clockOffset = _getClockOffset();
    final response = await _http
        .get(
          Uri.parse('$_kAzuraBase/api/nowplaying/$kNeuroRadioStationId'),
          headers: {..._headers, 'Cache-Control': 'no-cache'},
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw http.ClientException(
        'Now playing feed returned ${response.statusCode}',
      );
    }
    return _NowPlayingFeed.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
      _mapTrack,
      _now().toUtc(),
      await clockOffset ?? Duration.zero,
    );
  }

  /// Reuse a clock sample across station updates and short listening sessions.
  /// Refresh periodically because the device clock or server clock can drift.
  Future<Duration?> _getClockOffset() {
    final cached = _clockOffsetFuture;
    final fetchedAt = _clockOffsetFetchedAt;
    final age = fetchedAt == null
        ? null
        : _now().toUtc().difference(fetchedAt);
    if (cached != null &&
        (fetchedAt == null ||
            (age! >= Duration.zero && age < const Duration(minutes: 30)))) {
      return cached;
    }

    final request = _fetchClockOffset();
    _clockOffsetFuture = request;
    _clockOffsetFetchedAt = null;
    unawaited(request.then((offset) {
      if (!identical(_clockOffsetFuture, request)) return;
      if (offset == null) {
        _clockOffsetFuture = null;
      } else {
        _clockOffsetFetchedAt = _now().toUtc();
      }
    }));
    return request;
  }

  Future<Duration?> _fetchClockOffset() async {
    try {
      final sent = _now().toUtc();
      final response = await _http
          .get(
            Uri.parse('$_kAzuraBase/api/time'),
            headers: {..._headers, 'Cache-Control': 'no-cache'},
          )
          .timeout(const Duration(seconds: 2));
      final received = _now().toUtc();
      final roundTrip = received.difference(sent);
      if (response.statusCode != 200 ||
          roundTrip.isNegative ||
          roundTrip > const Duration(seconds: 2)) {
        return null;
      }
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final rawTime = body['utc_json'] as String?;
      final serverTime = rawTime == null ? null : DateTime.tryParse(rawTime);
      if (serverTime == null) return null;
      final midpoint = sent.add(
        Duration(microseconds: roundTrip.inMicroseconds ~/ 2),
      );
      final offset = serverTime.toUtc().difference(midpoint);
      _log.fine(
        'Radio server clock offset ${offset.inMilliseconds} ms '
        '(round trip ${roundTrip.inMilliseconds} ms; '
        'half round trip ${roundTrip.inMilliseconds ~/ 2} ms)',
      );
      return offset;
    } catch (error) {
      _log.fine('Could not sync the radio clock: $error');
      return null;
    }
  }

  /// Fetches recently played tracks on the radio station in order of last played.
  Future<List<Track>> fetchHistory() async {
    List<Track> stateHistory = const [];
    try {
      final state = await fetchCurrentState();
      if (state.history.isNotEmpty) {
        stateHistory = state.history;
      }
    } catch (e) {
      _log.fine('Could not fetch state history: $e');
    }

    if (stateHistory.isEmpty &&
        _latest != null &&
        _latest!.state.history.isNotEmpty) {
      stateHistory = _latest!.state.history;
    }

    // Fetch AzuraCast nowplaying for authoritative played_at chronological order.
    try {
      final response = await _http
          .get(
            Uri.parse('$_kAzuraBase/api/nowplaying/$_kAzuraStationId'),
            headers: {..._headers, 'Cache-Control': 'no-cache'},
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final rawHistory = body['song_history'] as List<dynamic>? ?? const [];
        final historyList = List<Map<String, dynamic>>.from(
          rawHistory.whereType<Map<String, dynamic>>(),
        );

        // Sort descending by played_at (most recently played first)
        historyList.sort((a, b) {
          final timeA = (a['played_at'] as num?)?.toInt() ?? 0;
          final timeB = (b['played_at'] as num?)?.toInt() ?? 0;
          return timeB.compareTo(timeA);
        });

        if (historyList.isNotEmpty) {
          final byId = <String, Track>{};
          final byTitle = <String, Track>{};
          for (final track in stateHistory) {
            if (track.id != null && track.id!.isNotEmpty) {
              byId[track.id!] = track;
            }
            if (track.title != null && track.title!.isNotEmpty) {
              byTitle[track.title!.toLowerCase().trim()] = track;
            }
          }

          final sortedTracks = <Track>[];
          for (final item in historyList) {
            final song = item['song'] as Map<String, dynamic>? ?? const {};
            final custom = song['custom_fields'];
            final songId =
                (custom is Map ? custom['songId']?.toString() : null) ??
                song['id']?.toString() ??
                '';
            final songTitle = (song['title'] ?? song['text'] ?? '')
                .toString()
                .trim();

            Track? matchedTrack;
            if (songId.isNotEmpty && byId.containsKey(songId)) {
              matchedTrack = byId[songId];
            } else if (songTitle.isNotEmpty) {
              final clean = songTitle
                  .replaceAll(
                    RegExp(
                      r'\s*\((Neuro|Evil|Duet)[^\)]*\)',
                      caseSensitive: false,
                    ),
                    '',
                  )
                  .trim()
                  .toLowerCase();
              if (clean.isNotEmpty) {
                for (final entry in byTitle.entries) {
                  if (entry.key == songTitle.toLowerCase() ||
                      entry.key == clean ||
                      (clean.length >= 3 &&
                          (entry.key.contains(clean) ||
                              clean.contains(entry.key)))) {
                    matchedTrack = entry.value;
                    break;
                  }
                }
              }
            }

            if (matchedTrack != null) {
              matchedTrack.unavailable = false;
              sortedTracks.add(matchedTrack);
            } else {
              final track = _mapTrack({
                'id': songId,
                'title': song['title'] ?? song['text'] ?? '',
                'originalArtists': [if (song['artist'] != null) song['artist']],
                'duration': item['duration'] ?? song['duration'] ?? 0,
                'art': song['art'],
              });
              track.unavailable = true;
              track.playbackDetails = const [];
              sortedTracks.add(track);
            }
          }

          if (sortedTracks.isNotEmpty) return sortedTracks;
        }
      }
    } catch (e) {
      _log.fine('Could not fetch AzuraCast song history: $e');
    }

    if (stateHistory.isNotEmpty) return stateHistory;

    return const [];
  }

  /// REST copy of what the hub pushes.
  Future<NeuroRadioState> fetchCurrentState() async {
    final response = await _http
        .get(Uri.parse(_kStateUrl), headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw http.ClientException('Radio state returned ${response.statusCode}');
    }
    return NeuroRadioState.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
      _mapTrack,
    );
  }

  /// AzuraCast's stable station endpoint; no metadata request is needed to
  /// begin playback.
  Future<String> fetchStreamUrl() => Future.value(_kStreamUrl);

  // ---------------------------------------------------------------------
  // Song requests

  Future<RadioRequestPage> fetchRequestableSongs({
    int page = 1,
    int perPage = 25,
    String query = '',
  }) async {
    final uri = Uri.parse('$_kAzuraBase/api/station/$_kAzuraStationId/requests')
        .replace(
          queryParameters: {
            'internal': 'true',
            'rowCount': '$perPage',
            'current': '$page',
            if (query.trim().isNotEmpty) 'searchPhrase': query.trim(),
          },
        );
    final response = await _http
        .get(uri, headers: _headers)
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw http.ClientException(
        'Request list returned ${response.statusCode}',
      );
    }
    return RadioRequestPage.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  /// Submits a request, returning the station's confirmation message.
  /// Throws [RadioRequestException] with the station's reason when refused.
  Future<String> requestSong(RadioRequestSong song) async {
    final response = await _http
        .post(Uri.parse('$_kAzuraBase${song.requestUrl}'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    Map<String, dynamic>? body;
    try {
      body = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {}
    final message = (body?['formatted_message'] ?? body?['message']) as String?;
    if (response.statusCode == 200 && body?['success'] != false) {
      return message ?? 'Request submitted';
    }
    throw RadioRequestException(
      message ?? 'Could not submit request (${response.statusCode})',
    );
  }
}

/// The parts of the AzuraCast now-playing feed the app uses.
class _NowPlayingFeed {
  final String? songId;
  final String? title;
  final String? text;
  final String? artist;
  final String? artUrl;
  final int playedAt;
  final Duration elapsed;
  final Duration? duration;
  final DateTime observedAt;
  final Duration clockOffset;
  final Track? playingNext;

  const _NowPlayingFeed({
    required this.songId,
    required this.title,
    required this.text,
    required this.artist,
    required this.artUrl,
    required this.playedAt,
    required this.elapsed,
    required this.duration,
    required this.observedAt,
    required this.clockOffset,
    this.playingNext,
  });

  factory _NowPlayingFeed.fromJson(
    Map<String, dynamic> json, [
    NeuroTrackMapper? mapTrack,
    DateTime? observedAt,
    Duration clockOffset = Duration.zero,
  ]) {
    final nowPlaying = json['now_playing'] as Map<String, dynamic>? ?? const {};
    final song = (nowPlaying['song'] as Map<String, dynamic>?) ?? const {};
    final custom = song['custom_fields'];
    final customSongId = custom is Map ? custom['songId']?.toString() : null;
    final rawSongId = song['id']?.toString();
    final songId = (customSongId != null && customSongId.isNotEmpty)
        ? customSongId
        : rawSongId;

    Track? playingNext;
    final playingNextJson = json['playing_next'] as Map<String, dynamic>?;
    if (playingNextJson != null && playingNextJson['song'] is Map) {
      final s = playingNextJson['song'] as Map<String, dynamic>;
      final nextCustom = s['custom_fields'];
      final nextSongId =
          (nextCustom is Map ? nextCustom['songId']?.toString() : null) ??
          s['id']?.toString() ??
          '';
      final nextDuration = Duration(
        milliseconds: (((playingNextJson['duration'] as num?) ?? 0) * 1000)
            .round(),
      );
      if (mapTrack != null) {
        playingNext = mapTrack({
          'id': nextSongId,
          'title': s['title'] ?? s['text'] ?? '',
          'originalArtists': [if (s['artist'] != null) s['artist']],
          'duration': nextDuration.inSeconds,
          'art': s['art'],
        });
      } else {
        playingNext = Track(
          id: nextSongId,
          title: s['title'] as String? ?? s['text'] as String?,
          artists: [
            if (s['artist'] != null) Artist(name: s['artist'] as String),
          ],
          duration: nextDuration,
          albumArt: s['art'] != null
              ? ImageDetails(
                  fullUrl: s['art'] as String,
                  thumbUrl: s['art'] as String,
                )
              : null,
          platformId: 'neurokaraoke',
        );
      }
    }

    return _NowPlayingFeed(
      songId: songId,
      title: song['title'] as String?,
      text: song['text'] as String?,
      artist: song['artist'] as String?,
      artUrl: song['art'] as String?,
      playedAt: (nowPlaying['played_at'] as num?)?.toInt() ?? 0,
      elapsed: Duration(
        milliseconds: (((nowPlaying['elapsed'] as num?) ?? 0) * 1000).round(),
      ),
      duration:
          _durationFromSeconds(nowPlaying['duration'] ?? song['duration']) ??
          _sumDurations(
            _durationFromSeconds(nowPlaying['elapsed']),
            _durationFromSeconds(nowPlaying['remaining']),
          ),
      observedAt: observedAt ?? DateTime.now().toUtc(),
      clockOffset: clockOffset,
      playingNext: playingNext,
    );
  }

  // Elapsed can disagree with the station clock even in the live feed.
  // played_at is the fixed station timestamp for this song.
  DateTime get startedAt => playedAt > 0
      ? DateTime.fromMillisecondsSinceEpoch(
          playedAt * 1000,
          isUtc: true,
        ).subtract(clockOffset)
      : observedAt.subtract(elapsed);

  Track? toTrack() {
    final trackTitle = title ?? text;
    if (trackTitle == null || trackTitle.isEmpty) return null;
    final trackId = songId;
    if (trackId == null || trackId.isEmpty) return null;
    return Track(
      id: trackId,
      title: trackTitle,
      displayArtistName: artist,
      artists: [
        if (artist != null && artist!.isNotEmpty)
          Artist(id: artist, name: artist, platformId: 'neurokaraoke'),
      ],
      duration: duration,
      albumArt: artUrl != null && artUrl!.isNotEmpty
          ? ImageDetails(fullUrl: artUrl!, thumbUrl: artUrl!)
          : null,
      platformId: 'neurokaraoke',
    );
  }
}

Duration? _durationFromSeconds(Object? value) {
  final seconds = switch (value) {
    num value => value.toDouble(),
    String value => double.tryParse(value),
    _ => null,
  };
  if (seconds == null || !seconds.isFinite || seconds <= 0) return null;
  return Duration(milliseconds: (seconds * 1000).round());
}

Duration? _sumDurations(Duration? first, Duration? second) {
  if (first == null || second == null) return null;
  return first + second;
}
