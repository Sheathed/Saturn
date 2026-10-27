import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../../api/definitions.dart';
import '../../settings.dart';
import '../../utils/format_utils.dart';
import '../../utils/json_isolate.dart';
import '../stream_provider.dart';
import 'youtube_music_auth.dart';
import 'youtube_music_javascript.dart';

final _youtubeUserAgent = YoutubeHttpClient.defaultHeaders['user-agent']!;
const _visionOsUserAgent =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) '
    'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15';
const _tvUserAgent = 'Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version';

// The fork's default VisionOS/Safari manifest does not request YouTube Music's
// account-only audio formats. Keep this profile aligned with WEB_REMIX.
YoutubeApiClient _musicPlayerClient(
  String? visitorData, {
  required String language,
  required String country,
}) => YoutubeApiClient(
  {
    'context': {
      'client': {
        'clientName': 'WEB_REMIX',
        'clientVersion': '1.20260707.12.00',
        'hl': language,
        'gl': country,
        if (visitorData != null && visitorData.isNotEmpty)
          'visitorData': visitorData,
      },
    },
  },
  'https://music.youtube.com/youtubei/v1/player?key=AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30&prettyPrint=false',
  headers: {
    'X-YouTube-Client-Name': '67',
    'Origin': 'https://music.youtube.com',
    'X-Origin': 'https://music.youtube.com',
    'Referer': 'https://music.youtube.com/',
  },
);

/// Adds the current Music session to YouTube requests made by the library.
class _AuthenticatedHttpClient extends http.BaseClient {
  _AuthenticatedHttpClient(
    this._inner,
    this._cookieGetter,
    this._visitorDataGetter,
  );

  final http.Client _inner;
  final String? Function()? _cookieGetter;
  final String? Function()? _visitorDataGetter;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final host = request.url.host;
    final isVisionOsPlayer =
        request.url.path == '/youtubei/v1/player' &&
        request.headers['X-YouTube-Client-Name'] == 'VISIONOS';
    if (host == 'youtube.com' || host.endsWith('.youtube.com')) {
      final cookie = _cookieGetter?.call();
      if (cookie != null && cookie.isNotEmpty && !isVisionOsPlayer) {
        request.headers['Cookie'] = cookie;
        if (host == 'music.youtube.com' &&
            request.url.path == '/youtubei/v1/player') {
          const origin = 'https://music.youtube.com';
          final visitorData = _visitorDataGetter?.call();
          if (visitorData != null && visitorData.isNotEmpty) {
            request.headers['X-Goog-Visitor-Id'] = visitorData;
          }
          final authorization = musicAuthorization(cookie);
          if (authorization != null) {
            request.headers['Authorization'] = authorization;
            request.headers['Origin'] = origin;
            request.headers['X-Origin'] = origin;
            request.headers['Referer'] = '$origin/';
            request.headers['X-Goog-AuthUser'] = '0';
          }
        }
      }
    }
    request.headers.putIfAbsent('User-Agent', () => _youtubeUserAgent);
    if (request.method == 'HEAD' &&
        (host == 'googlevideo.com' || host.endsWith('.googlevideo.com'))) {
      // The fork checks the first manifest URL with HEAD. GoogleVideo can
      // reject HEAD even when the same URL accepts a ranged GET, which would
      // make the fork discard every stream from that player response.
      final probe = http.Request('GET', request.url)
        ..headers.addAll(request.headers)
        ..headers['Range'] = 'bytes=0-0';
      final response = await _inner.send(probe);
      final headers = Map<String, String>.from(response.headers);
      final totalLength = RegExp(
        r'^bytes\s+\d+-\d+/(\d+)$',
      ).firstMatch(headers['content-range'] ?? '')?.group(1);
      if (totalLength != null) headers['content-length'] = totalLength;
      await response.stream.listen((_) {}).cancel();
      final mime = request.url.queryParameters['mime'] ?? '';
      final itag = request.url.queryParameters['itag'];
      final isVideoProbe =
          mime.startsWith('video/') || itag == '18' || itag == '137';
      // The fork probes only streams.first before returning the manifest.
      // That stream is often a video format even though this provider will
      // select audio-only. A rejected video URL does not invalidate the audio.
      final statusCode =
          response.statusCode == HttpStatus.forbidden && isVideoProbe
          ? HttpStatus.ok
          : response.statusCode;
      return http.StreamedResponse(
        const Stream<List<int>>.empty(),
        statusCode,
        headers: headers,
        request: request,
        contentLength: 0,
        reasonPhrase: response.reasonPhrase,
      );
    }
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

class YouTubeMusicStreamProvider extends StreamProvider {
  YouTubeMusicStreamProvider({
    YoutubeExplode? yt,
    String? Function()? cookieGetter,
    String? Function()? visitorDataGetter,
    String Function()? languageGetter,
    String Function()? countryGetter,
    Future<bool> Function()? refreshAuthentication,
    Future<Map<String, dynamic>> Function(
      String endpoint, {
      Map<String, dynamic> body,
      Map<String, String>? query,
      bool mobileClient,
      bool anonymous,
      bool retryOnAuthError,
      bool retryWithRefreshedCookie,
    })?
    innertubePost,
    Future<String> Function(String jsCode)? executeJavaScriptOnRootIsolate,
  }) : _customYt = yt,
       _cookieGetter = cookieGetter,
       _visitorDataGetter = visitorDataGetter,
       _languageGetter = languageGetter,
       _countryGetter = countryGetter,
       _refreshAuthentication = refreshAuthentication,
       _innertubePost = innertubePost,
       _executeJavaScriptOnRootIsolate = executeJavaScriptOnRootIsolate {
    // The package logs expected unplayable responses as SEVERE before throwing
    // them, even when this provider catches the exception and tries another
    // client. Keep those probe failures out of Flutter's uncaught-error output;
    // this provider logs the final, classified result instead.
    hierarchicalLoggingEnabled = true;
    Logger('YoutubeExplode.StreamsClient').level = Level.OFF;
  }

  final YoutubeExplode? _customYt;
  final String? Function()? _cookieGetter;
  final String? Function()? _visitorDataGetter;
  final String Function()? _languageGetter;
  final String Function()? _countryGetter;
  String get _language => _languageGetter?.call() ?? 'en';
  String get _country => _countryGetter?.call() ?? 'US';
  final Future<bool> Function()? _refreshAuthentication;
  final Future<Map<String, dynamic>> Function(
    String endpoint, {
    Map<String, dynamic> body,
    Map<String, String>? query,
    bool mobileClient,
    bool anonymous,
    bool retryOnAuthError,
    bool retryWithRefreshedCookie,
  })?
  _innertubePost;
  final Future<String> Function(String jsCode)?
  _executeJavaScriptOnRootIsolate;
  final _log = Logger('YouTubeMusicStreamProvider');
  Future<YoutubeExplode>? _cachedYt;
  Future<YoutubeExplode>? _guestYt;
  Future<YoutubeExplode>? _guestSolvedYt;
  String? _lastCookie;
  DateTime _lastRefresh = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void>? _refreshing;
  final _rejectedItags = <String, (String, int)>{};
  final _premiumOnlyGuestVideos = <String>{};
  final _accountRefreshAttempts = <String>{};

  @override
  String get streamCacheRevision {
    final cookie = _cookieGetter?.call() ?? '';
    final visitorData = _visitorDataGetter?.call() ?? '';
    if (cookie.isEmpty && visitorData.isEmpty) return '';
    return sha256.convert(utf8.encode('$cookie\u0000$visitorData')).toString();
  }

  @override
  Future<void> prepareStream() => _refreshCookie();

  Future<void> _refreshCookie({bool force = false}) async {
    final pending = _refreshing;
    if (pending != null) return pending;
    final now = DateTime.now();
    if (!force && now.difference(_lastRefresh) < const Duration(minutes: 1)) {
      return;
    }
    _lastRefresh = now;
    final refresh = () async {
      try {
        await _refreshAuthentication?.call().timeout(
          const Duration(seconds: 5),
        );
      } catch (error) {
        _log.fine('Could not refresh YouTube Music cookies: $error');
      }
    }();
    _refreshing = refresh;
    try {
      await refresh;
    } finally {
      if (identical(_refreshing, refresh)) _refreshing = null;
    }
  }

  Future<YoutubeExplode> _createYoutube({
    required bool authenticated,
    required bool solveChallenges,
  }) async {
    return YoutubeExplode(
      httpClient: YoutubeHttpClient(
        _AuthenticatedHttpClient(
          http.Client(),
          authenticated ? _cookieGetter : null,
          authenticated ? _visitorDataGetter : null,
        ),
      ),
      jsSolver: solveChallenges
          ? YouTubeMusicSignatureSolver(
              executeOnRootIsolate: _executeJavaScriptOnRootIsolate,
            )
          : null,
    );
  }

  Future<YoutubeExplode> get _yt async {
    if (_customYt != null) return _customYt;
    final cookie = _cookieGetter?.call();
    if (_cachedYt == null || cookie != _lastCookie) {
      final old = _cachedYt;
      if (old != null) {
        unawaited(old.then((yt) => yt.close()).catchError((_) {}));
      }
      _rejectedItags.clear();
      _accountRefreshAttempts.clear();
      _lastCookie = cookie;
      _cachedYt = _createYoutube(authenticated: true, solveChallenges: true);
    }
    final pending = _cachedYt!;
    try {
      return await pending;
    } catch (_) {
      if (identical(_cachedYt, pending)) _cachedYt = null;
      rethrow;
    }
  }

  Future<YoutubeExplode> get _guest async {
    if (_customYt != null) return _customYt;
    final pending = _guestYt ??= _createYoutube(
      authenticated: false,
      solveChallenges: false,
    );
    try {
      return await pending;
    } catch (_) {
      if (identical(_guestYt, pending)) _guestYt = null;
      rethrow;
    }
  }

  Future<YoutubeExplode> get _guestWithSolver async {
    if (_customYt != null) return _customYt;
    final pending = _guestSolvedYt ??= _createYoutube(
      authenticated: false,
      solveChallenges: true,
    );
    try {
      return await pending;
    } catch (_) {
      if (identical(_guestSolvedYt, pending)) _guestSolvedYt = null;
      rethrow;
    }
  }

  Future<bool> _canReadAudio(
    StreamInfo stream,
    Map<String, String> headers,
  ) async {
    final client = http.Client();
    try {
      final request = http.Request('GET', stream.url)
        ..headers.addAll(headers)
        ..headers['Range'] = 'bytes=0-';
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.partialContent) {
        _log.info(
          'YouTube audio itag ${stream.tag} returned HTTP ${response.statusCode}',
        );
        return false;
      }
      final first = await response.stream.first.timeout(
        const Duration(seconds: 8),
      );
      return first.isNotEmpty;
    } on TimeoutException {
      _log.warning('Timed out reading YouTube audio itag ${stream.tag}');
      rethrow;
    } catch (error) {
      _log.info(
        'Could not read YouTube audio itag ${stream.tag}: ${error.runtimeType}',
      );
      return false;
    } finally {
      client.close();
    }
  }

  Future<StreamInfo?> _playableStream(
    StreamManifest manifest,
    AudioQuality quality,
    Map<String, String> headers, {
    int? rejectedItag,
  }) async {
    final audio =
        manifest.audioOnly
            .where(
              (stream) =>
                  stream.fragments.isEmpty && stream.tag != rejectedItag,
            )
            .toList()
          ..sort((a, b) => a.bitrate.compareTo(b.bitrate));
    final defaultAudio = audio
        .where(
          (stream) =>
              stream.audioTrack == null || stream.audioTrack!.audioIsDefault,
        )
        .toList();
    final candidates = defaultAudio.isNotEmpty ? defaultAudio : audio;
    final target = switch (quality) {
      AudioQuality.MP3_128 => 48,
      AudioQuality.MP3_320 => 128,
      AudioQuality.FLAC || AudioQuality.ASK => 256,
    };
    final preferred = candidates
        .where((stream) => stream.bitrate.kiloBitsPerSecond <= target + 8)
        .toList()
        .reversed;
    final other = candidates
        .where((stream) => stream.bitrate.kiloBitsPerSecond > target + 8)
        .toList();
    for (final stream in [...preferred, ...other].take(4)) {
      if (await _canReadAudio(stream, headers)) return stream;
    }
    final muxed =
        manifest.muxed
            .where(
              (stream) =>
                  stream.container.name == 'mp4' &&
                  stream.fragments.isEmpty &&
                  stream.tag != rejectedItag,
            )
            .toList()
          ..sort(
            (a, b) => a.tag == 18
                ? -1
                : b.tag == 18
                ? 1
                : 0,
          );
    for (final stream in muxed.take(1)) {
      if (await _canReadAudio(stream, headers)) return stream;
    }
    return null;
  }

  @override
  Future<HttpClientRequest> openProxyRequest(
    HttpClient client,
    StreamResponse stream, {
    required String method,
    String? range,
  }) => super.openProxyRequest(
    client,
    stream,
    // GoogleVideo handles GET ranges more consistently than HEAD.
    method: 'GET',
    range: range ?? 'bytes=0-',
  );

  @override
  Future<StreamResponse> getStream(Track track, AudioQuality quality) async {
    final videoId = track.id;
    if (videoId == null || videoId.isEmpty) {
      throw ArgumentError('YouTube Music track ID is missing');
    }

    if (videoId.startsWith('radio:')) {
      final liveUrl = await getLiveStreamUrl(videoId);
      if (liveUrl != null) {
        return StreamResponse(
          url: liveUrl,
          format: 'HLS',
          requiresFormatProbe: false,
        );
      }
      throw StreamUnavailableException(
        'Could not resolve livestream for $videoId',
      );
    }

    await _refreshCookie();

    final directResponse = await _tryGetDirectExternalPodcastStream(
      track,
      videoId,
    );
    if (directResponse != null) {
      return directResponse;
    }

    final cookie = _cookieGetter?.call() ?? '';
    final hasAccount = hasMusicSessionCookie(cookie);
    StreamInfo? selected;
    var usedClient = 'VISIONOS';
    var streamHeaders = <String, String>{
      'User-Agent': _visionOsUserAgent,
      'Accept-Encoding': 'identity',
      'Origin': 'https://www.youtube.com',
      'Referer': 'https://www.youtube.com/',
    };
    final rejected = _rejectedItags.remove('$videoId/${quality.name}');
    String? accountFailureReason;
    var ageRestricted = false;
    var guestRequiresPremium = _premiumOnlyGuestVideos.contains(videoId);
    bool isAgeRestricted(Object error) =>
        error.toString().toLowerCase().contains('sign in to confirm your age');

    Future<void> tryMusicAccount() async {
      try {
        final yt = await _yt;
        final manifest = await yt.videos.streamsClient.getManifest(
          videoId,
          ytClients: [
            _musicPlayerClient(
              _visitorDataGetter?.call(),
              language: _language,
              country: _country,
            ),
          ],
        );
        final musicHeaders = <String, String>{
          'User-Agent': _youtubeUserAgent,
          'Accept-Encoding': 'identity',
          'Origin': 'https://music.youtube.com',
          'Referer': 'https://music.youtube.com/',
        };
        selected = await _playableStream(
          manifest,
          quality,
          musicHeaders,
          rejectedItag: rejected?.$1 == 'WEB_REMIX' ? rejected?.$2 : null,
        );
        if (selected != null) {
          usedClient = 'WEB_REMIX';
          streamHeaders = musicHeaders;
          accountFailureReason = null;
        } else {
          accountFailureReason = 'no readable audio formats';
        }
      } catch (error) {
        ageRestricted |= isAgeRestricted(error);
        accountFailureReason = error is YoutubeExplodeException
            ? error.message.split('Reason: ').last.trim()
            : error.runtimeType.toString();
        _log.info(
          'Music account streams unavailable for $videoId: '
          '${error.runtimeType}: $accountFailureReason',
        );
      }
    }

    Future<void> tryVisionOs() async {
      if (guestRequiresPremium) return;
      try {
        final guest = await _guest;
        final manifest = await guest.videos.streamsClient.getManifest(
          videoId,
          ytClients: [YoutubeApiClient.visionos],
        );
        selected = await _playableStream(
          manifest,
          quality,
          streamHeaders,
          rejectedItag: rejected?.$1 == 'VISIONOS' ? rejected?.$2 : null,
        );
      } catch (error) {
        ageRestricted |= isAgeRestricted(error);
        if (error is VideoUnplayableException &&
            error.message.toLowerCase().contains('music premium')) {
          guestRequiresPremium = true;
          if (_premiumOnlyGuestVideos.length >= 100) {
            _premiumOnlyGuestVideos.remove(_premiumOnlyGuestVideos.first);
          }
          _premiumOnlyGuestVideos.add(videoId);
          _log.info('Guest VisionOS requires Music Premium for $videoId');
          return;
        }
        _log.info(
          'Guest VisionOS streams unavailable for $videoId: ${error.runtimeType}',
        );
      }
    }

    // Try the authenticated Music client first so age-gated videos can use
    // the user's session instead of generating an expected guest failure.
    if (hasAccount) {
      await tryMusicAccount();
      if (selected == null &&
          _refreshAuthentication != null &&
          DateTime.now().difference(_lastRefresh) >
              const Duration(seconds: 10) &&
          _accountRefreshAttempts.add(videoId)) {
        final previousCookie = _cookieGetter?.call();
        await _refreshCookie(force: true);
        final refreshedCookie = _cookieGetter?.call();
        if (refreshedCookie != previousCookie &&
            hasMusicSessionCookie(refreshedCookie)) {
          await tryMusicAccount();
        }
      }
    }
    if (selected == null && !ageRestricted) {
      await tryVisionOs();
    }
    if (selected == null && !guestRequiresPremium && !ageRestricted) {
      try {
        final guest = await _guestWithSolver;
        final manifest = await guest.videos.streamsClient.getManifest(
          videoId,
          ytClients: [YoutubeApiClient.tv],
        );
        final tvHeaders = <String, String>{
          'User-Agent': _tvUserAgent,
          'Accept-Encoding': 'identity',
          'Origin': 'https://www.youtube.com',
          'Referer': 'https://www.youtube.com/',
        };
        selected = await _playableStream(
          manifest,
          quality,
          tvHeaders,
          rejectedItag: rejected?.$1 == 'TVHTML5' ? rejected?.$2 : null,
        );
        if (selected != null) {
          usedClient = 'TVHTML5';
          streamHeaders = tvHeaders;
        }
      } catch (error) {
        ageRestricted |= isAgeRestricted(error);
        _log.info(
          'Guest TV streams unavailable for $videoId: ${error.runtimeType}',
        );
      }
    }
    final stream = selected;
    if (stream == null) {
      final liveUrl = await getLiveStreamUrl(videoId);
      if (liveUrl != null) {
        return StreamResponse(
          url: liveUrl,
          format: 'HLS',
          requiresFormatProbe: false,
        );
      }

      if (guestRequiresPremium) {
        throw StreamUnavailableException(
          hasAccount
              ? 'YouTube Music requires Premium for $videoId, and the saved '
                    'Music session did not return a playable stream'
                    '${accountFailureReason == null ? '' : ' ($accountFailureReason)'}.'
              : 'YouTube Music requires a Premium account for $videoId. '
                    'Sign in to play this track.',
        );
      }
      if (ageRestricted) {
        throw StreamUnavailableException(
          'YouTube requires age verification to play $videoId. '
          'Sign in to a YouTube Music account that can play this video.',
        );
      }
      throw StreamUnavailableException(
        'No readable YouTube audio streams found for $videoId'
        '${accountFailureReason == null ? '' : ' (Music account: $accountFailureReason)'}.',
      );
    }

    if (track.duration == null || track.duration == Duration.zero) {
      final seconds = double.tryParse(stream.url.queryParameters['dur'] ?? '');
      if (seconds != null && seconds.isFinite && seconds > 0) {
        track.duration = Duration(milliseconds: (seconds * 1000).round());
      }
    }
    if (track.duration == null || track.duration == Duration.zero) {
      try {
        final duration = (await (await _guest).videos.get(videoId)).duration;
        if (duration != null && duration > Duration.zero) {
          track.duration = duration;
        }
      } catch (error) {
        _log.fine('Could not fetch duration for $videoId: $error');
      }
    }

    final codec = stream is AudioStreamInfo
        ? stream.audioCodec
        : stream is MuxedStreamInfo
        ? stream.audioCodec
        : stream.codec.parameters['codecs'] ?? '';
    final format = codec.toLowerCase().contains('opus')
        ? 'OPUS'
        : codec.toLowerCase().contains('mp4a') || stream.container.name == 'mp4'
        ? 'AAC'
        : stream.container.name.toUpperCase();
    final url = stream.url;
    final expire = int.tryParse(url.queryParameters['expire'] ?? '');
    final expiresAt = expire == null
        ? DateTime.now().add(const Duration(minutes: 5))
        : DateTime.fromMillisecondsSinceEpoch(
            expire * 1000,
          ).subtract(const Duration(seconds: 60));
    // A muxed stream's bitrate includes video and must not be reported as an
    // audio bitrate.
    final audioBitrate = stream is AudioOnlyStreamInfo
        ? stream.bitrate.kiloBitsPerSecond.round()
        : null;
    _log.info(
      'Selected YouTube stream: itag=${stream.tag}, '
      '$format ${audioBitrate == null ? 'muxed' : '$audioBitrate kbps'} '
      'for $videoId from $usedClient',
    );
    if (quality == AudioQuality.FLAC &&
        audioBitrate != null &&
        audioBitrate < 192) {
      _log.info(
        'YouTube Music did not offer a 256 kbps stream for $videoId; '
        'best playable stream is $audioBitrate kbps',
      );
    }
    return StreamResponse(
      url: url.toString(),
      format: format,
      bitrate: audioBitrate,
      requiresFormatProbe: false,
      expiresAt: expiresAt,
      requestHeaders: streamHeaders,
      meta: {
        'videoId': videoId,
        'itag': stream.tag,
        'playerClient': usedClient,
        'codec': codec,
        'container': stream.container.name,
        'size': stream.size.totalBytes,
        if (track.duration != null && track.duration! > Duration.zero)
          'durationMilliseconds': track.duration!.inMilliseconds,
      },
    );
  }

  @override
  void onProxyResponseStatus(
    Track track,
    AudioQuality quality,
    int statusCode,
    StreamResponse response,
  ) {
    final id = track.id;
    final itag = response.meta['itag'];
    final client = response.meta['playerClient'];
    if (id != null &&
        itag is int &&
        client is String &&
        shouldRetryProxyStatus(statusCode)) {
      _log.warning(
        'YouTube $client itag $itag returned HTTP $statusCode for $id; retrying',
      );
      _rejectedItags['$id/${quality.name}'] = (client, itag);
    }
  }

  @override
  Future<void> decryptFile(
    String trackId,
    String inputPath,
    String outputPath,
    Map<String, dynamic> meta,
  ) async {
    final input = File(inputPath);
    if (!await input.exists()) {
      throw FileSystemException('Input file not found', inputPath);
    }
    await File(outputPath).parent.create(recursive: true);
    await input.copy(outputPath);
  }

  Future<StreamResponse?> _tryGetDirectExternalPodcastStream(
    Track track,
    String videoId,
  ) async {
    try {
      Map<String, dynamic>? playerRes;
      if (_innertubePost case final post?) {
        playerRes = await post('player', body: {'videoId': videoId});
      } else {
        final cookie = _cookieGetter?.call();
        final visitorData = _visitorDataGetter?.call();
        final authorization = cookie != null
            ? musicAuthorization(cookie)
            : null;
        final res = await http.post(
          Uri.parse(
            'https://music.youtube.com/youtubei/v1/player?key=AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30&prettyPrint=false',
          ),
          headers: {
            'User-Agent': _youtubeUserAgent,
            'Content-Type': 'application/json',
            'Origin': 'https://music.youtube.com',
            'Referer': 'https://music.youtube.com/',
            'X-YouTube-Client-Name': '67',
            'X-YouTube-Client-Version': '1.20260707.12.00',
            if (cookie != null && cookie.isNotEmpty) 'Cookie': cookie,
            if (authorization != null) ...{'Authorization': authorization},
            if (visitorData != null && visitorData.isNotEmpty)
              'X-Goog-Visitor-Id': visitorData,
          },
          body: jsonEncode({
            'context': {
              'client': {
                'clientName': 'WEB_REMIX',
                'clientVersion': '1.20260707.12.00',
                'hl': _language,
                'gl': _country,
                if (visitorData != null && visitorData.isNotEmpty)
                  'visitorData': visitorData,
              },
            },
            'videoId': videoId,
          }),
        );
        if (res.statusCode >= 200 && res.statusCode < 300) {
          playerRes =
              (await decodeJsonAsync(utf8.decode(res.bodyBytes)))
                  as Map<String, dynamic>;
        }
      }

      if (playerRes == null) return null;

      final videoDetails = playerRes['videoDetails'] as Map<String, dynamic>?;
      final isExternallyHosted =
          videoDetails?['isExternallyHostedPodcast'] == true;
      final musicVideoType = videoDetails?['musicVideoType'] as String?;
      final isPodcast =
          musicVideoType == 'MUSIC_VIDEO_TYPE_PODCAST_EPISODE' ||
          isExternallyHosted;

      final streamingData = playerRes['streamingData'] as Map<String, dynamic>?;
      if (streamingData == null) return null;

      final rawFormats = [
        if (streamingData['formats'] is List) ...streamingData['formats'],
        if (streamingData['adaptiveFormats'] is List)
          ...streamingData['adaptiveFormats'],
      ];

      for (final raw in rawFormats) {
        if (raw is! Map) continue;
        final format = Map<String, dynamic>.from(raw);
        final streamUrl = format['url'] as String?;
        if (streamUrl == null || streamUrl.isEmpty) continue;

        final isExternalHost = !streamUrl.contains('googlevideo.com');
        if (isExternalHost &&
            (isExternallyHosted || isPodcast || format['itag'] == 15)) {
          final mime = (format['mimeType'] as String?)?.toLowerCase() ?? '';
          final formatStr =
              mime.contains('mpeg') ||
                  mime.contains('mp3') ||
                  streamUrl.toLowerCase().contains('.mp3')
              ? 'MP3'
              : mime.contains('mp4') ||
                    mime.contains('aac') ||
                    mime.contains('m4a')
              ? 'AAC'
              : mime.contains('ogg') || mime.contains('opus')
              ? 'OGG'
              : 'MP3';

          final rawBitrate =
              (format['bitrate'] as num?)?.toInt() ??
              (format['averageBitrate'] as num?)?.toInt();
          int? audioBitrate;
          if (rawBitrate != null && rawBitrate > 0) {
            audioBitrate = rawBitrate > 1000
                ? (rawBitrate / 1000).round()
                : rawBitrate;
          }

          if (track.duration == null || track.duration == Duration.zero) {
            final durMs = int.tryParse(
              format['approxDurationMs']?.toString() ?? '',
            );
            if (durMs != null && durMs > 0) {
              track.duration = Duration(milliseconds: durMs);
            } else {
              final lenSec = int.tryParse(
                videoDetails?['lengthSeconds']?.toString() ?? '',
              );
              if (lenSec != null && lenSec > 0) {
                track.duration = Duration(seconds: lenSec);
              }
            }
          }

          if (audioBitrate == null || audioBitrate <= 0) {
            final bytes = int.tryParse(
              format['contentLength']?.toString() ?? '',
            );
            final durMs =
                int.tryParse(format['approxDurationMs']?.toString() ?? '') ??
                track.duration?.inMilliseconds;
            if (bytes != null && bytes > 0 && durMs != null && durMs > 0) {
              final calc = (((bytes * 8) / 1000) / (durMs / 1000.0)).round();
              if (calc > 58 && calc < 70) {
                audioBitrate = 64;
              } else if (calc > 90 && calc < 102) {
                audioBitrate = 96;
              } else if (calc > 120 && calc < 136) {
                audioBitrate = 128;
              } else if (calc > 154 && calc < 170) {
                audioBitrate = 160;
              } else if (calc > 185 && calc < 198) {
                audioBitrate = 192;
              } else if (calc > 245 && calc < 265) {
                audioBitrate = 256;
              } else if (calc > 310 && calc < 330) {
                audioBitrate = 320;
              } else if (calc > 0) {
                audioBitrate = calc;
              }
            }
          }

          final expiresInSeconds =
              int.tryParse(
                streamingData['expiresInSeconds']?.toString() ?? '',
              ) ??
              21600;
          final expiresAt = DateTime.now()
              .add(Duration(seconds: expiresInSeconds))
              .subtract(const Duration(seconds: 60));

          _log.info(
            'Selected external podcast RSS stream for $videoId ($formatStr ${audioBitrate != null ? '$audioBitrate kbps' : 'probed'}): $streamUrl',
          );

          return StreamResponse(
            url: streamUrl,
            format: formatStr,
            bitrate: audioBitrate,
            requiresFormatProbe: audioBitrate == null || audioBitrate <= 0,
            expiresAt: expiresAt,
            requestHeaders: {
              'User-Agent': _youtubeUserAgent,
              'Accept-Encoding': 'identity',
            },
            meta: {
              'videoId': videoId,
              'itag': format['itag'] ?? 15,
              'playerClient': 'EXTERNAL_PODCAST_RSS',
              'mimeType': format['mimeType'],
              'contentLength': format['contentLength'],
              if (track.duration != null && track.duration! > Duration.zero)
                'durationMilliseconds': track.duration!.inMilliseconds,
            },
          );
        }
      }
    } catch (e, st) {
      _log.fine(
        'Checking external podcast stream for $videoId skipped: $e',
        e,
        st,
      );
    }
    return null;
  }

  Future<String?> getLiveStreamUrl(String videoId) async {
    final cleanId = videoId.startsWith('radio:')
        ? videoId.substring(6)
        : videoId;
    try {
      final body = {
        'context': {
          'client': {
            'clientName': 'ANDROID',
            'clientVersion': '21.01.38',
            'hl': _language,
            'gl': _country,
          },
        },
        'videoId': cleanId,
        'contentCheckOk': true,
        'racyCheckOk': true,
      };
      final res = await http.post(
        Uri.parse('https://www.youtube.com/youtubei/v1/player'),
        headers: {
          'Content-Type': 'application/json',
          'User-Agent':
              'com.google.android.youtube/21.01.38 (Linux; U; Android 11; ${_language}_$_country) gzip',
        },
        body: jsonEncode(body),
      );
      if (res.statusCode == 200) {
        final data =
            await decodeJsonAsync(res.body) as Map<String, dynamic>;
        final hls = data['streamingData']?['hlsManifestUrl'] as String?;
        if (hls != null && hls.isNotEmpty) {
          return hls;
        }
      }
    } catch (e) {
      _log.fine('Error resolving Android HLS livestream for $cleanId: $e');
    }

    try {
      final yt = await _yt;
      final liveUrl = await yt.videos.streamsClient.getHttpLiveStreamUrl(
        VideoId(cleanId),
      );
      return liveUrl;
    } catch (e) {
      _log.fine('Could not fetch as livestream for $cleanId: $e');
    }
    return null;
  }

  @override
  Future<bool> handleProxyRequest(
    HttpRequest request,
    Track track,
    AudioQuality quality,
  ) async {
    final videoId = track.id;
    if (videoId != null && videoId.startsWith('radio:')) {
      final actualId = videoId.substring(6);
      try {
        final url = await getLiveStreamUrl(actualId);
        if (url != null) {
          request.response
            ..statusCode = HttpStatus.found
            ..headers.set(HttpHeaders.locationHeader, url)
            ..close();
          return true;
        }
      } catch (error) {
        _log.warning(
          'Failed to handle YouTube Music livestream for $actualId: $error',
        );
      }
    }
    return false;
  }

  void close() {
    final cached = _cachedYt;
    final guest = _guestYt;
    final guestSolved = _guestSolvedYt;
    if (cached != null) {
      unawaited(cached.then((yt) => yt.close()).catchError((_) {}));
    }
    if (guest != null) {
      unawaited(guest.then((yt) => yt.close()).catchError((_) {}));
    }
    if (guestSolved != null) {
      unawaited(guestSolved.then((yt) => yt.close()).catchError((_) {}));
    }
    _customYt?.close();
  }

  @override
  Future<int?> resolveBitrate(Track track, AudioQuality quality) async {
    try {
      final response = await getStream(track, quality);
      if (response.bitrate != null && response.bitrate! > 0) {
        return response.bitrate;
      }
      return await FormatUtils.resolveBitrateFromHeaders(
        response.url,
        durationSeconds: track.duration?.inSeconds,
        headers: response.requestHeaders,
      );
    } catch (_) {
      return null;
    }
  }
}
