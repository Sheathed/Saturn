import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:get_it/get_it.dart';

import 'package:material_ui/material_ui.dart';
import 'package:fluttericon/font_awesome5_icons.dart';
import 'package:fluttericon/typicons_icons.dart';
import 'package:simple_icons/simple_icons.dart';
import 'package:logging/logging.dart';
import 'package:saturn/platform/youtube_music/youtube_music_speed_dial.dart';
import 'package:webview_all/webview_all.dart';

import '../../api/definitions.dart';
import '../../service/audio_service.dart';
import '../../translations.i18n.dart';
import '../../ui/details_screens.dart';
import '../../ui/elements.dart';
import '../../ui/home_screen.dart';
import '../../ui/menu.dart';
import '../../ui/tiles.dart';
import '../deezer/deezer_widgets.dart';
import '../../settings.dart' show AudioQuality;
import '../../settings.dart' as app_settings;
import '../download_metadata.dart';
import '../music_platform.dart';
import '../platform_capabilities.dart';
import '../platform_settings.dart';
import '../stream_provider.dart';
import 'youtube_music_account.dart';
import 'youtube_music_api.dart';
import 'youtube_music_auth.dart';
import 'youtube_music_browse_widget.dart';
import 'youtube_music_capabilities.dart';
import 'youtube_music_client.dart';
import 'youtube_music_login_widget.dart';
import 'youtube_music_stream_provider.dart';
import 'ytmusicapi_locale.dart';

class YouTubeMusicPlatform extends MusicPlatform {
  static YouTubeMusicPlatform? _instance;
  static YouTubeMusicPlatform get instance =>
      _instance ??= YouTubeMusicPlatform();

  factory YouTubeMusicPlatform({
    YouTubeMusicApi? api,
    YouTubeMusicStreamProvider? streamProvider,
    Future<String> Function(String jsCode)? executeJavaScriptOnRootIsolate,
    bool refreshSessionFromWebView = true,
  }) {
    if (_instance != null &&
        api == null &&
        streamProvider == null &&
        executeJavaScriptOnRootIsolate == null &&
        refreshSessionFromWebView) {
      return _instance!;
    }
    final effectiveApi = api ?? YouTubeMusicApi();
    final effectiveStreamProvider =
        streamProvider ??
        YouTubeMusicStreamProvider(
          cookieGetter: () => effectiveApi.client.cookie,
          visitorDataGetter: () => effectiveApi.client.visitorData,
          languageGetter: () => effectiveApi.client.hl,
          countryGetter: () => effectiveApi.client.gl,
          refreshAuthentication: () async =>
              await effectiveApi.client.refreshAuthentication?.call() ?? false,
          innertubePost: effectiveApi.client.post,
          executeJavaScriptOnRootIsolate: executeJavaScriptOnRootIsolate,
        );
    final platform = YouTubeMusicPlatform._(
      effectiveApi,
      effectiveStreamProvider,
      refreshSessionFromWebView: refreshSessionFromWebView,
    );
    _instance = platform;
    return platform;
  }

  YouTubeMusicPlatform._(
    this._api,
    this._streamProvider, {
    required bool refreshSessionFromWebView,
  }) {
    _instance = this;
    _applySavedLocale();
    _loadStoredCredentials();
    _api.client.onSessionExpired = _handleSessionExpired;
    _api.client.refreshAuthentication = refreshSessionFromWebView
        ? _refreshCookieFromWebView
        : null;
  }

  final YouTubeMusicApi _api;
  final YouTubeMusicStreamProvider _streamProvider;
  final Logger _log = Logger('YouTubeMusicPlatform');
  YouTubeMusicAccount? _account;
  bool _isGuest = false;
  bool _sessionExpired = false;

  Map<String, dynamic> _storedConfig() {
    final raw = app_settings.settings.platformConfigs['youtube_music'];
    return raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
  }

  Future<void> _saveLocale(String key, String value) async {
    final isLanguage = key == 'language';
    if ((isLanguage && !ytmusicApiLanguages.contains(value)) ||
        (!isLanguage &&
            (key != 'country' || !ytmusicApiLocations.contains(value)))) {
      throw ArgumentError.value(value, key, 'Unsupported YouTube Music locale');
    }
    final config = _storedConfig()..[key] = value;
    app_settings.settings.platformConfigs['youtube_music'] = config;
    if (key == 'language') _api.client.hl = value;
    if (key == 'country') _api.client.gl = value;
    await app_settings.settings.save();
  }

  void _applySavedLocale() {
    final config = _storedConfig();
    final language = config['language'];
    final country = config['country'];
    _api.client.hl =
        language is String && ytmusicApiLanguages.contains(language)
        ? language
        : 'en';
    _api.client.gl = country is String && ytmusicApiLocations.contains(country)
        ? country
        : 'US';
  }

  YouTubeMusicApi get api => _api;
  bool get isGuest => _isGuest;
  bool get sessionExpired => _sessionExpired;

  void _handleSessionExpired() {
    _log.warning('YouTube Music session expired. Reverting to guest mode.');
    _account = null;
    _isGuest = true;
    _sessionExpired = true;
    try {
      app_settings.settings.platformConfigs['youtube_music'] = {
        ..._storedConfig(),
        'isGuest': true,
        'sessionExpired': true,
      };
      app_settings.settings.save();
    } catch (e) {
      _log.warning('Failed to save session expiration to settings: $e');
    }
  }

  Future<bool> _refreshCookieFromWebView() async {
    final freshCookie = await readWebViewCookieHeader();
    if (!RegExp(r'(?:^|;\s*)SAPISID=[^;]+').hasMatch(freshCookie) ||
        freshCookie == _api.client.cookie) {
      return false;
    }

    _api.client.cookie = freshCookie;
    _isGuest = false;
    _sessionExpired = false;
    final storedConfig = app_settings.settings.platformConfigs['youtube_music'];
    final config = storedConfig is Map
        ? Map<String, dynamic>.from(storedConfig)
        : <String, dynamic>{};
    config
      ..['cookie'] = freshCookie
      ..['isGuest'] = false
      ..remove('sessionExpired');
    app_settings.settings.platformConfigs['youtube_music'] = config;
    await app_settings.settings.save();
    _log.info('Updated YouTube Music session cookies from WebView storage.');
    return true;
  }

  /// Reads the WebView session used by the login screen.
  Future<String> readWebViewCookieHeader() async {
    if (WebViewPlatform.instance == null) return '';
    final cookies = await WebViewCookieManager().getCookies(
      domain: Uri.parse('https://music.youtube.com'),
    );
    return cookies.map((cookie) => '${cookie.name}=${cookie.value}').join('; ');
  }

  void _loadStoredCredentials() {
    try {
      final config = app_settings.settings.platformConfigs['youtube_music'];
      if (config is Map) {
        if (config['isGuest'] == true) {
          _isGuest = true;
        }
        if (config['sessionExpired'] == true) {
          _sessionExpired = true;
        }
        final cookie = config['cookie'] as String?;
        if (cookie != null && cookie.isNotEmpty) {
          _api.client.cookie = cookie;
        }
        final visitorData = config['visitorData'] as String?;
        if (visitorData != null && visitorData.isNotEmpty) {
          _api.client.visitorData = visitorData;
        }
        if (config['account'] is Map) {
          _account = YouTubeMusicAccount.fromJson(
            Map<String, dynamic>.from(config['account'] as Map),
          );
        } else if (config['accountName'] != null) {
          _account = YouTubeMusicAccount(
            name: config['accountName'] as String,
            email: config['accountEmail'] as String?,
            channelHandle: config['accountChannelHandle'] as String?,
            photoUrl: config['accountPhoto'] as String?,
          );
        }
      }
    } catch (_) {}
  }

  Never _unsupported(String operation) => throw UnsupportedError(
    '$operation is not supported in anonymous mode or requires user authentication.',
  );

  // ---------------------------------------------------------------------------
  // Identity
  // ---------------------------------------------------------------------------

  @override
  String get platformId => 'youtube_music';

  @override
  String get platformName => 'YouTube Music';

  @override
  IconData get platformIcon => SimpleIcons.youtubemusic;

  @override
  Widget buildPlatformIcon({double size = 24, Color? color}) {
    return Icon(platformIcon, size: size, color: color);
  }

  @override
  PlatformCapabilities get capabilities => youtubeMusicCapabilities;

  @override
  List<PlatformSetting> get settings => [
    ChoicePlatformSetting(
      id: 'language',
      title: 'Language',
      description: 'Language used for YouTube Music results.',
      icon: Icons.language,
      currentValue: _api.client.hl,
      options: ytmusicApiLanguages
          .map((code) => ChoicePlatformOption(value: code, label: code))
          .toList(growable: false),
      onChanged: (value) => _saveLocale('language', value),
    ),
    ChoicePlatformSetting(
      id: 'country',
      title: 'Country or region',
      description: 'Location used for YouTube Music charts and results.',
      icon: Icons.public,
      currentValue: _api.client.gl,
      options: ytmusicApiLocations
          .map((code) => ChoicePlatformOption(value: code, label: code))
          .toList(growable: false),
      onChanged: (value) => _saveLocale('country', value),
    ),
  ];

  @override
  List<QuickAccessItem> get searchQuickAccessItems => [
    QuickAccessItem(
      title: 'Charts'.i18n,
      icon: const Icon(FontAwesome5.chart_line, color: Colors.white),
      color: const Color(0xffff555d),
      onTap: (context) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => YouTubeMusicBrowseWidget(
              browseId: 'FEmusic_charts',
              title: 'Charts'.i18n,
              api: _api,
            ),
          ),
        );
      },
    ),
    QuickAccessItem(
      title: 'Moods & genres'.i18n,
      icon: const Icon(Icons.grid_view_rounded, color: Colors.white),
      color: const Color(0xff7c42bb),
      onTap: (context) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => YouTubeMusicBrowseWidget(
              browseId: 'FEmusic_moods_and_genres',
              title: 'Moods & genres'.i18n,
              api: _api,
            ),
          ),
        );
      },
    ),
    QuickAccessItem(
      title: 'New releases'.i18n,
      icon: const Icon(Icons.fiber_new, color: Colors.white),
      color: const Color(0xffff8a00),
      onTap: (context) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => YouTubeMusicBrowseWidget(
              browseId: 'FEmusic_new_releases',
              title: 'New releases'.i18n,
              api: _api,
            ),
          ),
        );
      },
    ),
    QuickAccessItem(
      title: 'Podcasts'.i18n,
      icon: const Icon(FontAwesome5.podcast, color: Colors.white),
      color: const Color(0xff11b192),
      onTap: (context) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => YouTubeMusicBrowseWidget(
              browseId: 'FEmusic_non_music_audio',
              title: 'Podcasts'.i18n,
              api: _api,
            ),
          ),
        );
      },
    ),
    QuickAccessItem(
      title: 'Radio'.i18n,
      icon: const Icon(Typicons.waves, color: Colors.white),
      color: const Color(0xff2ba640),
      onTap: (context) async {
        await GetIt.I<AudioPlayerHandler>().playMix(
          'RDMM',
          'Radio'.i18n,
          platformId: platformId,
        );
      },
    ),
  ];

  // ---------------------------------------------------------------------------
  // Auth
  // ---------------------------------------------------------------------------

  @override
  Future<bool> isLoggedIn() async =>
      _api.client.isAuthenticated || (_isGuest && !_sessionExpired);

  @override
  Future<AuthResult> login(Map<String, dynamic> credentials) async {
    if (credentials['guest'] == true || credentials['isGuest'] == true) {
      _isGuest = true;
      _sessionExpired = false;
      _account = null;
      _api.client.cookie = null;
      app_settings.settings.platformConfigs['youtube_music'] = {
        ..._storedConfig(),
        'isGuest': true,
      };
      await app_settings.settings.save();
      return const AuthResult.success();
    }

    final rawInput = (credentials['cookie'] ?? credentials['token']) as String?;
    if (rawInput == null || rawInput.trim().isEmpty) {
      return const AuthResult.failure('No cookie or token provided.');
    }

    final sanitizedCookie = _sanitizeCookieInput(rawInput);
    final visitorData =
        credentials['visitorData'] as String? ?? _extractVisitorData(rawInput);

    final previousCookie = _api.client.cookie;
    final previousVisitor = _api.client.visitorData;

    _api.client.cookie = sanitizedCookie;
    if (visitorData != null) {
      _api.client.visitorData = visitorData;
    }

    try {
      final account = await _api.getAccountInfo();
      if (account == null) {
        _api.client.cookie = previousCookie;
        _api.client.visitorData = previousVisitor;
        return const AuthResult.failure(
          'Failed to authenticate. The provided token or cookie is invalid or expired.',
        );
      }

      _account = account;
      _isGuest = false;
      _sessionExpired = false;

      // Persist to Saturn configuration
      app_settings.settings.platformConfigs['youtube_music'] = {
        ..._storedConfig(),
        'cookie': sanitizedCookie,
        if (_api.client.visitorData != null)
          'visitorData': _api.client.visitorData,
        'account': account.toJson(),
      };
      await app_settings.settings.save();

      return const AuthResult.success();
    } catch (e) {
      _api.client.cookie = previousCookie;
      _api.client.visitorData = previousVisitor;
      return AuthResult.failure('Login failed: $e');
    }
  }

  @override
  Future<void> logout() async {
    _isGuest = false;
    _sessionExpired = false;
    _api.client.cookie = null;
    _account = null;
    final config = _storedConfig()
      ..remove('cookie')
      ..remove('visitorData')
      ..remove('account')
      ..remove('accountName')
      ..remove('accountEmail')
      ..remove('accountChannelHandle')
      ..remove('accountPhoto')
      ..remove('isGuest')
      ..remove('sessionExpired');
    if (config.isEmpty) {
      app_settings.settings.platformConfigs.remove('youtube_music');
    } else {
      app_settings.settings.platformConfigs['youtube_music'] = config;
    }
    await app_settings.settings.save();
    try {
      if (WebViewPlatform.instance != null) {
        await WebViewCookieManager().clearCookies();
      }
    } catch (error, stack) {
      _log.warning(
        'Could not clear YouTube Music WebView cookies.',
        error,
        stack,
      );
    }
  }

  @override
  String? get currentUserId => _account?.email ?? _account?.channelHandle;

  @override
  String? get currentUserName =>
      _account?.name ??
      (_api.client.isAuthenticated
          ? 'Google Account'
          : (_isGuest ? 'Guest' : null));
  @override
  String? get favoritesPlaylistId => 'LM';

  @override
  Future<List<Track>> getAllFavoriteTracks() => _api.getAllLikedTracks();

  @override
  Future<PaginatedTrackList> getFavoriteTracks({
    int start = 0,
    int limit = 100,
    Sorting? sort,
  }) async {
    if (!_api.client.isAuthenticated) {
      return PaginatedTrackList(tracks: [], hasMore: false);
    }
    final needsSort =
        sort != null && (sort.reverse || sort.type != SortType.DEFAULT);
    if (needsSort) {
      return super.getFavoriteTracks(start: start, limit: limit, sort: sort);
    }
    return _api.getFavoriteTracks(start: start, limit: limit);
  }

  @override
  Future<HistoryTrackPage> getHistoryTracks({String? cursor, int limit = 50}) {
    if (!_api.client.isAuthenticated) {
      throw StateError('Sign in to YouTube Music to view listening history.');
    }
    return _api.getHistoryTracks();
  }

  @override
  Widget buildLoginWidget({required VoidCallback onSuccess}) {
    return YouTubeMusicLoginWidget(platform: this, onSuccess: onSuccess);
  }

  static String _sanitizeCookieInput(String raw) {
    var text = raw.trim();

    // Check for JSON string
    if (text.startsWith('{') && text.endsWith('}')) {
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map && decoded['cookie'] is String) {
          text = (decoded['cookie'] as String).trim();
        }
      } catch (_) {}
    }

    // Strip "Cookie:" or "cookie:" header prefix if copied directly from devtools/curl
    if (text.toLowerCase().startsWith('cookie:')) {
      text = text.substring(text.indexOf(':') + 1).trim();
    }

    // Check for Metrolist / ytmusicapi multi-line text format
    if (text.contains('***INNERTUBE COOKIE*** =')) {
      for (final line in text.split('\n')) {
        final trimmed = line.trim();
        if (trimmed.startsWith('***INNERTUBE COOKIE*** =')) {
          text = trimmed.substring('***INNERTUBE COOKIE*** ='.length).trim();
          break;
        }
      }
    }

    // If the user pasted only their SAPISID token value (e.g. no '=' in the text)
    if (!text.contains('=') && text.isNotEmpty) {
      return 'SAPISID=$text; __Secure-3PAPISID=$text';
    }

    return text;
  }

  static String? _extractVisitorData(String raw) {
    final text = raw.trim();
    if (text.startsWith('{') && text.endsWith('}')) {
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map && decoded['visitorData'] is String) {
          return decoded['visitorData'] as String;
        }
      } catch (_) {}
    }
    if (text.contains('***VISITOR DATA*** =')) {
      for (final line in text.split('\n')) {
        final trimmed = line.trim();
        if (trimmed.startsWith('***VISITOR DATA*** =')) {
          final val = trimmed.substring('***VISITOR DATA*** ='.length).trim();
          if (val.isNotEmpty) return val;
        }
      }
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Search
  // ---------------------------------------------------------------------------

  @override
  Future<SearchResults> search(String query) => _api.search(query);

  @override
  Future<List<String>> searchSuggestions(String query) =>
      _api.searchSuggestions(query);

  // ---------------------------------------------------------------------------
  // Content fetching
  // ---------------------------------------------------------------------------

  @override
  Future<Track> getTrack(String id) => _api.getTrack(id);

  @override
  Future<List<Track>> getTracks(List<String> ids) => _api.getTracks(ids);

  @override
  Future<Album> getAlbum(String id) => _api.getAlbum(id);

  @override
  Future<Artist> getArtist(String id) => _api.getArtist(id);

  @override
  List<ArtistPageSection> buildArtistPageSections(
    BuildContext? context,
    Artist artist,
  ) {
    if (artist.platformId != platformId || artist.id == null) {
      return const [];
    }
    final sections = <ArtistPageSection>[
      ArtistPageSection(
        position: ArtistPageSectionPosition.afterTracks,
        title: 'Videos'.i18n,
        getCachedItems: () =>
            (artist.customData['videos'] as List?)
                ?.whereType<Track>()
                .toList() ??
            const [],
        loadItems: (limit) => _api.getArtistVideos(artist, limit: limit),
        itemBuilder: (context, item, items) {
          final video = item as Track;
          final videos = items.cast<Track>();
          return TrackTile(
            video,
            hideDuration: true,
            hidePlatformBadge: true,
            onTap: () {
              final id = video.id;
              if (id == null || id.isEmpty) {
                return;
              }
              GetIt.I<AudioPlayerHandler>().playFromTrackList(
                videos,
                id,
                QueueSource(
                  source: 'artist_videos',
                  id: artist.id,
                  text: '${'Videos'.i18n} · ${artist.name ?? ''}',
                ),
              );
            },
            onHold: () => MenuSheet().defaultTrackMenu(video, context: context),
          );
        },
      ),
    ];
    if (artist.playlists.isNotEmpty) {
      sections.add(
        ArtistPageSection(
          position: ArtistPageSectionPosition.afterAlbums,
          title: 'Playlists'.i18n,
          loadItems: (limit) => artistPageSectionItems(artist.playlists, limit),
          itemBuilder: (context, item, items) {
            final playlist = item as Playlist;
            return PlaylistTile(
              playlist,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => PlaylistDetails(playlist),
                ),
              ),
            );
          },
        ),
      );
    }
    if (artist.similarArtists.isNotEmpty) {
      sections.add(
        ArtistPageSection(
          position: ArtistPageSectionPosition.end,
          title: 'Similar artists'.i18n,
          loadItems: (limit) =>
              artistPageSectionItems(artist.similarArtists, limit),
          itemBuilder: (context, item, items) {
            final similar = item as Artist;
            return ArtistHorizontalTile(
              similar,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => ArtistDetails(similar)),
              ),
            );
          },
        ),
      );
    }
    return sections;
  }

  static String _cleanPlaylistId(String id) {
    if (id.startsWith('youtube_music_')) {
      return id.substring('youtube_music_'.length);
    }
    if (id.startsWith('youtube_music:')) {
      return id.substring('youtube_music:'.length);
    }
    return id;
  }

  @override
  Future<Playlist> getPlaylist(String id, {int limit = 100}) =>
      _api.getPlaylist(_cleanPlaylistId(id), limit: limit);

  @override
  Future<Playlist> getFullPlaylist(String id) =>
      _api.getPlaylist(_cleanPlaylistId(id), limit: null);

  @override
  Future<Lyrics> getLyrics(String trackId) => _api.getLyrics(trackId);

  @override
  String getLyricsSearchQuery(Track track) {
    final artistStr = track.artistString ?? '';
    return '${track.title} $artistStr'.trim();
  }

  @override
  String getShareUrl(String type, String id) {
    switch (type) {
      case 'track':
        return 'https://music.youtube.com/watch?v=$id';
      case 'album':
      case 'playlist':
        return 'https://music.youtube.com/playlist?list=$id';
      case 'artist':
        return 'https://music.youtube.com/channel/$id';
      default:
        return 'https://music.youtube.com';
    }
  }

  // ---------------------------------------------------------------------------
  // Library (read)
  // ---------------------------------------------------------------------------

  @override
  Future<List<Playlist>> getUserPlaylists() async {
    if (!_api.client.isAuthenticated) return [];
    final playlists = await _api.getUserPlaylists();
    final accountName = currentUserName;
    if (accountName == null || accountName.trim().isEmpty) return playlists;
    for (final playlist in playlists) {
      if (playlist.user == null && playlist.editable == true) {
        playlist.user = User(name: accountName);
      }
    }
    return playlists;
  }

  @override
  Future<List<Album>> getUserAlbums() async =>
      _api.client.isAuthenticated ? _api.getUserAlbums() : [];

  @override
  Future<List<Artist>> getUserArtists() async =>
      _api.client.isAuthenticated ? _api.getUserArtists() : [];

  @override
  Future<List<Show>> getUserShows() async =>
      _api.client.isAuthenticated ? _api.getUserShows() : [];

  @override
  Future<List<String>?> getFavoriteTrackIds() async {
    if (!_api.client.isAuthenticated) return [];
    final result = await getFavoriteTracks(limit: 500);
    return result.tracks.map((t) => t.id).whereType<String>().toList();
  }

  @override
  Future<List<String>?> getFavoritePlaylistIds() async {
    if (!_api.client.isAuthenticated) return [];
    final playlists = await getUserPlaylists();
    return playlists.map((p) => p.id).whereType<String>().toList();
  }

  // ---------------------------------------------------------------------------
  // Library mutations
  // ---------------------------------------------------------------------------

  @override
  Future<void> addFavoriteTrack(String id) async {
    _log.info('[YouTubeMusicPlatform] addFavoriteTrack: id=$id');
    try {
      await _api.rateTrack(id, rating: 'LIKE');
      invalidateFavoriteTracksCache();
      _log.info('[YouTubeMusicPlatform] addFavoriteTrack completed for id=$id');
    } catch (e, st) {
      _log.warning(
        '[YouTubeMusicPlatform] addFavoriteTrack error for id=$id: $e',
        e,
        st,
      );
      rethrow;
    }
  }

  @override
  Future<void> removeFavoriteTrack(String id) async {
    _log.info('[YouTubeMusicPlatform] removeFavoriteTrack: id=$id');
    try {
      await _api.rateTrack(id, rating: 'INDIFFERENT');
      invalidateFavoriteTracksCache();
      _log.info(
        '[YouTubeMusicPlatform] removeFavoriteTrack completed for id=$id',
      );
    } catch (e, st) {
      _log.warning(
        '[YouTubeMusicPlatform] removeFavoriteTrack error for id=$id: $e',
        e,
        st,
      );
      rethrow;
    }
  }

  @override
  Future<void> addFavoriteAlbum(String id) async {
    _log.info('[YouTubeMusicPlatform] addFavoriteAlbum: id=$id');
    try {
      await _api.rateAlbum(id, add: true);
      _log.info('[YouTubeMusicPlatform] addFavoriteAlbum completed for id=$id');
    } catch (e, st) {
      _log.warning(
        '[YouTubeMusicPlatform] addFavoriteAlbum error for id=$id: $e',
        e,
        st,
      );
      rethrow;
    }
  }

  @override
  Future<void> removeFavoriteAlbum(String id) async {
    _log.info('[YouTubeMusicPlatform] removeFavoriteAlbum: id=$id');
    try {
      await _api.rateAlbum(id, add: false);
      _log.info(
        '[YouTubeMusicPlatform] removeFavoriteAlbum completed for id=$id',
      );
    } catch (e, st) {
      _log.warning(
        '[YouTubeMusicPlatform] removeFavoriteAlbum error for id=$id: $e',
        e,
        st,
      );
      rethrow;
    }
  }

  @override
  Future<void> addFavoriteArtist(String id) async {
    _log.info('[YouTubeMusicPlatform] addFavoriteArtist: id=$id');
    try {
      await _api.subscribeArtist(id, subscribe: true);
      _log.info(
        '[YouTubeMusicPlatform] addFavoriteArtist completed for id=$id',
      );
    } catch (e, st) {
      _log.warning(
        '[YouTubeMusicPlatform] addFavoriteArtist error for id=$id: $e',
        e,
        st,
      );
      rethrow;
    }
  }

  @override
  Future<void> removeFavoriteArtist(String id) async {
    _log.info('[YouTubeMusicPlatform] removeFavoriteArtist: id=$id');
    try {
      await _api.subscribeArtist(id, subscribe: false);
      _log.info(
        '[YouTubeMusicPlatform] removeFavoriteArtist completed for id=$id',
      );
    } catch (e, st) {
      _log.warning(
        '[YouTubeMusicPlatform] removeFavoriteArtist error for id=$id: $e',
        e,
        st,
      );
      rethrow;
    }
  }

  @override
  Future<void> dislikeTrack(String id) async {
    _log.info('[YouTubeMusicPlatform] dislikeTrack: id=$id');
    try {
      await _api.rateTrack(id, rating: 'DISLIKE');
      _log.info('[YouTubeMusicPlatform] dislikeTrack completed for id=$id');
    } catch (e, st) {
      _log.warning(
        '[YouTubeMusicPlatform] dislikeTrack error for id=$id: $e',
        e,
        st,
      );
      rethrow;
    }
  }

  @override
  Future<void> addFavoritePlaylist(String id) async {
    _log.info('[YouTubeMusicPlatform] addFavoritePlaylist: id=$id');
    try {
      await _api.ratePlaylist(id, add: true);
      _log.info(
        '[YouTubeMusicPlatform] addFavoritePlaylist completed for id=$id',
      );
    } catch (e, st) {
      _log.warning(
        '[YouTubeMusicPlatform] addFavoritePlaylist error for id=$id: $e',
        e,
        st,
      );
      rethrow;
    }
  }

  @override
  Future<void> removeFavoritePlaylist(String id) async {
    _log.info('[YouTubeMusicPlatform] removeFavoritePlaylist: id=$id');
    try {
      await _api.ratePlaylist(id, add: false);
      _log.info(
        '[YouTubeMusicPlatform] removeFavoritePlaylist completed for id=$id',
      );
    } catch (e, st) {
      _log.warning(
        '[YouTubeMusicPlatform] removeFavoritePlaylist error for id=$id: $e',
        e,
        st,
      );
      rethrow;
    }
  }

  @override
  Future<String> createPlaylist(
    String title, {
    String description = '',
    int status = 0,
    List<String> trackIds = const [],
  }) => _api.createPlaylist(
    title,
    description: description,
    status: status,
    trackIds: trackIds,
  );

  @override
  Future<void> updatePlaylist(
    String id,
    String title, {
    String description = '',
    int status = 0,
  }) =>
      _api.updatePlaylist(id, title, description: description, status: status);

  @override
  Future<void> deletePlaylist(String id) async => _api.deletePlaylist(id);

  @override
  Future<void> addToPlaylist(String trackId, String playlistId) async =>
      _api.addToPlaylist(trackId, playlistId);

  @override
  Future<void> removeFromPlaylist(String trackId, String playlistId) async =>
      _api.removeFromPlaylist(trackId, playlistId);

  // ---------------------------------------------------------------------------
  // Discovery
  // ---------------------------------------------------------------------------

  @override
  Future<HomePage> getHomePage() => _api.getHomePage();

  @override
  Widget getHomeWidget(BuildContext context) =>
      YouTubeMusicBrowseWidget(browseId: 'FEmusic_home', api: _api);

  @override
  bool handleHomeSectionNavigation(
    BuildContext context,
    String path, {
    String? title,
  }) {
    if (path.startsWith('play:') || path.startsWith('mix:')) {
      final id = path.substring(path.indexOf(':') + 1);
      GetIt.I<AudioPlayerHandler>().playMix(
        id,
        title ?? 'Mix',
        platformId: platformId,
      );
      return true;
    }
    if (path.startsWith('VLRD') || path.startsWith('RD')) {
      final cleanId = path.startsWith('VL') ? path.substring(2) : path;
      GetIt.I<AudioPlayerHandler>().playMix(
        cleanId,
        title ?? 'Mix',
        platformId: platformId,
      );
      return true;
    }
    if (path.startsWith('playlist:')) {
      GetIt.I<AudioPlayerHandler>().playFromPlaylist(
        Playlist(
          id: path.substring('playlist:'.length),
          platformId: platformId,
        ),
        '',
      );
      return true;
    }
    String cleanBrowseId = path;
    String? cleanParams;
    if (path.contains('?')) {
      final uri = Uri.tryParse(path);
      if (uri != null) {
        if (uri.path.isNotEmpty) cleanBrowseId = uri.path;
        cleanParams = uri.queryParameters['params'];
      }
    }
    if (cleanBrowseId.startsWith('/')) {
      cleanBrowseId = cleanBrowseId.substring(1);
    }

    if (cleanBrowseId.startsWith('VL') || cleanBrowseId.startsWith('PL')) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PlaylistDetails(
            Playlist(id: cleanBrowseId, title: title, platformId: platformId),
          ),
        ),
      );
      return true;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => YouTubeMusicBrowseWidget(
          browseId: cleanBrowseId,
          params: cleanParams,
          title: title,
          api: _api,
        ),
      ),
    );
    return true;
  }

  @override
  bool isPlayableHomeSectionPath(String path) =>
      path.startsWith('play:') ||
      path.startsWith('mix:') ||
      path.startsWith('VLRD') ||
      path.startsWith('RD') ||
      path.startsWith('playlist:');

  @override
  bool handleHomeItemTap(BuildContext context, HomePageItem item) {
    if (item.type == HomePageItemType.RADIO) {
      final radio = item.value as LiveRadio;
      if (radio.id == null) return true;
      if (item.playMix ||
          radio.isMix ||
          radio.id!.startsWith('RD') ||
          radio.id!.startsWith('VLRD')) {
        final cleanId = radio.id!.startsWith('VL')
            ? radio.id!.substring(2)
            : radio.id!;
        GetIt.I<AudioPlayerHandler>().playMix(
          cleanId,
          radio.title ?? 'Mix',
          platformId: platformId,
        );
        return true;
      }
    }
    if (item.type == HomePageItemType.TRACK) {
      final track = item.value as Track;
      if (track.id == null) return true;
      if (item.playMix) {
        final mixId = track.id!.startsWith('RD')
            ? track.id!
            : 'RDAMVM${track.id!}';
        GetIt.I<AudioPlayerHandler>().playMix(
          mixId,
          track.title ?? '',
          platformId: platformId,
          seedTrack: track,
        );
        return true;
      }
    }
    if (item.type == HomePageItemType.PLAYLIST) {
      final playlist = item.value as Playlist;
      if (playlist.id != null &&
          (playlist.id!.startsWith('VLRD') || playlist.id!.startsWith('RD'))) {
        final cleanId = playlist.id!.startsWith('VL')
            ? playlist.id!.substring(2)
            : playlist.id!;
        GetIt.I<AudioPlayerHandler>().playMix(
          cleanId,
          playlist.title ?? 'Mix',
          platformId: platformId,
        );
        return true;
      }
    }
    return false;
  }

  @override
  Widget? buildPlatformHomeItem(BuildContext context, HomePageItem item) {
    if (item.isPlatformItem('channel') && item.value is DeezerChannel) {
      final channel = item.value as DeezerChannel;
      return ChannelTile(
        channel,
        onTap: () {
          final target = channel.target;
          if (target == null || target.isEmpty) return;
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => Scaffold(
                appBar: FreezerAppBar(channel.title ?? ''),
                body: HomePageScreen(loadPage: () => _api.getChannel(target)),
              ),
            ),
          );
        },
      );
    }
    return null;
  }

  @override
  Future<HomePage> getExplorePage() => _api.getChannel('FEmusic_explore');

  @override
  Widget getExploreWidget(BuildContext context) =>
      YouTubeMusicBrowseWidget(browseId: 'FEmusic_explore', api: _api);

  @override
  Future<HomePage> getChannel(String target) => _api.getChannel(target);

  @override
  Future<List<Track>> getFlow({String? type}) async => getMix('RDMM');

  @override
  Future<SmartTrackList> getSmartTrackList(String id) async =>
      _unsupported('Smart track lists');

  @override
  Future<List<Track>> getSmartRadio(String artistId) async {
    final res = await _api.client.post('browse', body: {'browseId': artistId});

    final header =
        res['header']?['musicImmersiveHeaderRenderer'] ??
        res['header']?['musicVisualHeaderRenderer'];

    final navigation =
        header?['startRadioButton']?['buttonRenderer']?['navigationEndpoint'];
    final radioId =
        navigation?['watchEndpoint']?['playlistId'] as String? ??
        navigation?['watchPlaylistEndpoint']?['playlistId'] as String?;

    if (radioId != null) {
      return _api.getWatchPlaylist(radioId);
    }
    return [];
  }

  @override
  Future<List<Track>> getLibraryShuffle({int start = 0}) async => [];

  @override
  Future<List<Track>> getMix(String trackId) => _api.getMix(trackId);

  // ---------------------------------------------------------------------------
  // Shows / podcasts
  // ---------------------------------------------------------------------------

  @override
  Future<List<ShowEpisode>> getShowEpisodes(String showId) =>
      _api.getShowEpisodes(showId);

  @override
  Future<PaginatedShowEpisodeList> getShowEpisodesPage(
    String showId, {
    int start = 0,
    int limit = 50,
  }) => _api.getShowEpisodesPage(showId, start: start, limit: limit);

  @override
  Future<bool> isFavoriteShow(String id) async {
    if (!_api.client.isAuthenticated) return false;
    final saved = await _api.getUserShows();
    String playlistId(String value) =>
        value.startsWith('MPSP') ? value.substring(4) : value;
    return saved.any(
      (show) => show.id != null && playlistId(show.id!) == playlistId(id),
    );
  }

  @override
  Future<void> addFavoriteShow(String id) async => _api.ratePlaylist(
    id.startsWith('MPSP') ? id.substring(4) : id,
    add: true,
  );

  @override
  Future<void> removeFavoriteShow(String id) async => _api.ratePlaylist(
    id.startsWith('MPSP') ? id.substring(4) : id,
    add: false,
  );

  // ---------------------------------------------------------------------------
  // Streaming
  // ---------------------------------------------------------------------------

  @override
  StreamProvider getStreamProvider() => _streamProvider;

  @override
  List<DownloadQualityOption> get availableDownloadQualities => const [
    DownloadQualityOption(
      AudioQuality.MP3_320,
      'High Quality (Opus ~160kbps / AAC 256kbps)',
    ),
    DownloadQualityOption(AudioQuality.MP3_128, 'Standard Quality (~128kbps)'),
  ];

  @override
  Future<PlatformDownloadMetadata> getDownloadMetadata(String trackId) async {
    if (trackId.startsWith('radio:')) {
      throw UnsupportedError(
        'YouTube Music livestreams cannot be downloaded',
      );
    }
    final track = await getTrack(trackId);
    // The selected YouTube stream may be Opus/WebM or AAC/M4A. Let the
    // download worker derive the extension from the resolved stream instead
    // of assuming every track uses Opus.
    return PlatformDownloadMetadata.fromTrack(track);
  }

  // ---------------------------------------------------------------------------
  // Deep-link parsing
  // ---------------------------------------------------------------------------

  @override
  Future<PlatformLinkResponse?> parseLink(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;

    final host = uri.host.toLowerCase();
    final isYouTubeHost =
        host == 'youtube.com' ||
        host.endsWith('.youtube.com') ||
        host == 'youtu.be';
    if (!isYouTubeHost) {
      return null;
    }

    // youtu.be/<id>
    if (host == 'youtu.be' && uri.pathSegments.isNotEmpty) {
      return PlatformLinkResponse(
        type: PlatformLinkType.track,
        id: uri.pathSegments.first,
        platformId: platformId,
      );
    }

    // watch?v=<id>
    final v = uri.queryParameters['v'];
    if (v != null && v.isNotEmpty) {
      return PlatformLinkResponse(
        type: PlatformLinkType.track,
        id: v,
        platformId: platformId,
      );
    }

    // playlist?list=<id>
    final list = uri.queryParameters['list'];
    if (list != null && list.isNotEmpty) {
      return PlatformLinkResponse(
        type: PlatformLinkType.playlist,
        id: list,
        platformId: platformId,
      );
    }

    // YouTube Music album, artist, and playlist path links.
    final segments = uri.pathSegments;
    final browseIndex = segments.indexOf('browse');
    final channelIndex = segments.indexOf('channel');
    final artistIndex = segments.indexOf('artist');
    final albumIndex = segments.indexOf('album');
    final playlistIndex = segments.indexOf('playlist');
    final entityIndex = browseIndex >= 0
        ? browseIndex
        : channelIndex >= 0
        ? channelIndex
        : artistIndex >= 0
        ? artistIndex
        : albumIndex >= 0
        ? albumIndex
        : playlistIndex;
    if (entityIndex >= 0 && entityIndex + 1 < segments.length) {
      final id = segments[entityIndex + 1];
      if (id.startsWith('MPRE')) {
        return PlatformLinkResponse(
          type: PlatformLinkType.album,
          id: id,
          platformId: platformId,
        );
      }
      if (id.startsWith('MPSP')) return null;
      if (id.startsWith('VL') || id.startsWith('PL')) {
        return PlatformLinkResponse(
          type: PlatformLinkType.playlist,
          id: id,
          platformId: platformId,
        );
      }
      if (id.startsWith('UC') || id.startsWith('MPLA')) {
        return PlatformLinkResponse(
          type: PlatformLinkType.artist,
          id: id,
          platformId: platformId,
        );
      }
      if (channelIndex == entityIndex || artistIndex == entityIndex) {
        return PlatformLinkResponse(
          type: PlatformLinkType.artist,
          id: id,
          platformId: platformId,
        );
      }
      if (albumIndex == entityIndex) {
        return PlatformLinkResponse(
          type: PlatformLinkType.album,
          id: id,
          platformId: platformId,
        );
      }
    }

    // /channel/<id>
    if (uri.pathSegments.contains('channel')) {
      final idx = uri.pathSegments.indexOf('channel');
      if (idx + 1 < uri.pathSegments.length) {
        return PlatformLinkResponse(
          type: PlatformLinkType.artist,
          id: uri.pathSegments[idx + 1],
          platformId: platformId,
        );
      }
    }

    return null;
  }

  @override
  Future<void> logListen(
    String trackId,
    QueueSource? queue, {
    ListenLogDetails? details,
  }) async {
    if (isGuest) return; // Do not log listens for unauthenticated users

    try {
      var actualTrackId = trackId;
      if (actualTrackId.startsWith('radio:')) {
        actualTrackId = actualTrackId.substring(6);
      } else if (actualTrackId.startsWith('mix:')) {
        actualTrackId = actualTrackId.substring(4);
      }

      final body = <String, dynamic>{'videoId': actualTrackId};
      if (queue != null && queue.id != null && queue.id!.isNotEmpty) {
        final src = queue.source ?? '';
        if (!src.contains('history') &&
            !src.contains('library') &&
            !src.contains('offline') &&
            !src.contains('search') &&
            queue.id != 'resume') {
          String qId = queue.id!;
          if (qId.contains(':')) {
            qId = qId.split(':').sublist(1).join(':');
          }
          body['playlistId'] = qId == 'favorites' ? 'LM' : qId;
        }
      }

      final res = await _api.client.post('player', body: body);

      final playbackUrl =
          res['playbackTracking']?['videostatsPlaybackUrl']?['baseUrl']
              as String?;
      final watchtimeUrl =
          res['playbackTracking']?['videostatsWatchtimeUrl']?['baseUrl']
              as String?;

      final trackingUrls = [playbackUrl, watchtimeUrl].whereType<String>();

      if (trackingUrls.isNotEmpty) {
        const chars =
            'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_';
        final rand = math.Random();
        final cpn = List.generate(
          16,
          (index) => chars[rand.nextInt(chars.length)],
        ).join();

        final cookie = _api.client.cookie;
        final auth = musicAuthorization(cookie);
        final headers = <String, String>{
          'User-Agent': YouTubeMusicClient.userAgent,
          'Origin': 'https://music.youtube.com',
          'Referer': 'https://music.youtube.com/',
          if (cookie != null && cookie.isNotEmpty) ...{
            'Cookie': cookie,
            if (auth != null) ...{'Authorization': auth},
            'X-Goog-AuthUser': '0',
          },
          if (_api.client.visitorData != null &&
              _api.client.visitorData!.isNotEmpty)
            'X-Goog-Visitor-Id': _api.client.visitorData!,
        };

        for (final trackingUrl in trackingUrls) {
          final queryParams = <String, String>{
            ...Uri.parse(trackingUrl).queryParameters,
            'ver': '2',
            'c': 'WEB_REMIX',
            'cpn': cpn,
          };

          if (details?.position != null) {
            final cmtNum = details!.position!.inMilliseconds / 1000.0;
            final cmt = cmtNum.toStringAsFixed(3);
            queryParams['cmt'] = cmt;

            if (trackingUrl == watchtimeUrl) {
              final listenSec =
                  details.listenDuration?.inSeconds.toDouble() ?? 0.0;
              final st = math.max(0.0, cmtNum - listenSec).toStringAsFixed(3);
              queryParams['st'] = st;
              queryParams['et'] = cmt;
              queryParams['state'] = details.isPartial ? 'paused' : 'playing';
            }
          }

          final uri = Uri.parse(
            trackingUrl,
          ).replace(queryParameters: queryParams);

          await http.get(uri, headers: headers);
        }

        _log.fine(
          'Logged listen for YouTube Music track: $trackId (partial: ${details?.isPartial})',
        );
      }
    } catch (e, st) {
      _log.warning(
        'Failed to log listen for YouTube Music track: $trackId',
        e,
        st,
      );
    }
  }

  @override
  Future<List<Track>> getArtistTopTracks(String artistId) async {
    final artist = await _api.getArtist(artistId);
    if (artist.topSongsPlaylistId != null) {
      return getPlaylistTracks(artist.topSongsPlaylistId!, 0);
    }
    return artist.topTracks;
  }

  @override
  Future<List<Album>> getDiscographyPage(
    String artistId, {
    int start = 0,
    int nb = 50,
  }) async {
    try {
      final artist = await _api.getArtist(artistId);
      return artist.albums;
    } catch (_) {
      return [];
    }
  }

  @override
  Future<List<Track>> getPlaylistTracks(String id, int start, {int nb = 100}) =>
      _api.getPlaylistTracksPage(id, start, limit: nb);

  @override
  Future<String?> getRadioStreamUrl(String id) async {
    return await _streamProvider.getLiveStreamUrl(id) ??
        await _api.getRadioStreamUrl(id);
  }

  @override
  List<Widget> getExtraMenuOptions(BuildContext context, Object item) {
    final speedDialItem = YouTubeMusicSpeedDialItem.fromDynamic(item);
    if (speedDialItem != null && speedDialItem.hasListenAgainTokens) {
      final isPinned = speedDialItem.isPinnedInYouTubeMusic;
      return [
        ListTile(
          leading: Icon(isPinned ? Icons.push_pin_outlined : Icons.push_pin),
          title: Text(
            isPinned ? 'Unpin from Listen again' : 'Pin to Listen again',
          ),
          onTap: () {
            Navigator.pop(context);
            YouTubeMusicSpeedDialManager.instance.togglePin(
              speedDialItem,
              onSendFeedback: _api.sendFeedbackToken,
            );
          },
        ),
      ];
    }
    return const [];
  }
}
