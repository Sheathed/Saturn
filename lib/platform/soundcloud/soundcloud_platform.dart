import 'package:flutter/services.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fluttericon/font_awesome5_icons.dart';
import 'package:fluttericon/typicons_icons.dart';
import 'package:get_it/get_it.dart';
import 'package:saturn/platform/platform_settings.dart';

import '../../api/definitions.dart';
import '../../service/audio_service.dart';
import '../../settings.dart' as app_settings;
import '../../translations.i18n.dart';
import '../../ui/details_screens.dart';
import '../../ui/elements.dart';
import '../../ui/home_screen.dart';
import '../../ui/menu.dart';
import '../../ui/tiles.dart';
import '../../utils/logging.dart';
import '../deezer/deezer_widgets.dart';
import '../download_metadata.dart';
import '../music_platform.dart';
import '../platform_capabilities.dart';
import '../stream_provider.dart';
import 'soundcloud_api.dart';
import 'soundcloud_auth_recovery.dart';
import 'soundcloud_capabilities.dart';
import 'soundcloud_stream_provider.dart';
import 'soundcloud_login_widget.dart';
import 'soundcloud_mobile_client.dart';
import 'soundcloud_mobile_auth.dart';
import 'soundcloud_web_cookies.dart';

class SoundCloudPlatform extends MusicPlatform {
  SoundCloudPlatform({
    SoundCloudApi? api,
    Future<String?> Function(String expiredToken)? recoverCookie,
  }) : _api = api ?? SoundCloudApi(),
       _recoverCookie =
           recoverCookie ?? SoundCloudAuthRecovery.refreshedCookie {
    _api.client.refreshAuthentication = _refreshAuthentication;
    _applyLanguage(_currentLanguage);
  }

  final SoundCloudApi _api;
  final Future<String?> Function(String expiredToken) _recoverCookie;
  String? _userId;
  String? _userName;
  final Set<String> _loggedListenSessions = {};
  final Expando<bool> _reportedPlaylistContexts = Expando<bool>();
  Future<String?>? _refreshingAuthentication;
  String? _lastExpiredToken;
  String? _lastRecoveredToken;
  String? _flowNextCursor;
  final Set<String> _seenFlowTrackIds = <String>{};
  int _flowFallbackOffset = 0;

  Future<String?> _refreshAuthentication(String expiredToken) {
    if (_api.client.oauthToken != expiredToken) {
      return Future.value(
        _lastExpiredToken == expiredToken &&
                _api.client.oauthToken == _lastRecoveredToken
            ? _lastRecoveredToken
            : null,
      );
    }
    return _refreshingAuthentication ??= _recoverAuthentication(
      expiredToken,
    ).whenComplete(() => _refreshingAuthentication = null);
  }

  Future<String?> _recoverAuthentication(String expiredToken) async {
    final config = app_settings.settings.platformConfigs['soundcloud'];
    if (config is! Map || config['oauth_token'] != expiredToken) return null;
    final accountId = config['user_id']?.toString() ?? _userId;
    if (accountId == null) return null;
    SoundCloudMobileTokens? refreshed;
    String? candidate;
    if (_api.client case final SoundCloudMobileClient mobile) {
      final refreshToken = config['refresh_token'];
      if (refreshToken is! String || refreshToken.isEmpty) return null;
      try {
        refreshed = await mobile.refreshMobileToken(refreshToken);
        candidate = refreshed.accessToken;
      } catch (error) {
        appLogger.warning('Could not refresh SoundCloud mobile session', error);
        return null;
      }
    } else {
      candidate = await _recoverCookie(expiredToken);
    }
    if (candidate == null) return null;
    Map<String, dynamic>? user;
    try {
      user = await _api.client.accountForToken(candidate);
    } catch (error) {
      appLogger.warning('Could not verify refreshed SoundCloud session', error);
      return null;
    }
    if (user?['id']?.toString() != accountId) return null;
    if (_api.client.oauthToken != expiredToken ||
        (app_settings.settings.platformConfigs['soundcloud']
                as Map?)?['oauth_token'] !=
            expiredToken) {
      return null;
    }
    _api.client.oauthToken = candidate;
    _lastExpiredToken = expiredToken;
    _lastRecoveredToken = candidate;
    final dd = (_api.client is SoundCloudMobileClient)
        ? (_api.client as SoundCloudMobileClient).datadomeCookie
        : null;
    app_settings.settings.platformConfigs['soundcloud'] = {
      ...config,
      'oauth_token': candidate,
      if (refreshed != null) 'refresh_token': refreshed.refreshToken,
      if (refreshed != null)
        'expires_at': refreshed.expiresAt.toIso8601String(),
      if (dd != null && dd.isNotEmpty) 'datadome_cookie': dd,
    };
    try {
      await app_settings.settings.save();
    } catch (error) {
      appLogger.warning('Could not save refreshed SoundCloud session', error);
    }
    return candidate;
  }

  Never _unsupported(String operation) =>
      throw UnsupportedError('$operation is not supported by SoundCloud.');

  String get _accountId {
    final id = _userId;
    if (id == null) throw StateError('SoundCloud sign in is required');
    return id;
  }

  Future<void> _syncWebCookies(
    String token, [
    Map<String, String>? browserCookies,
  ]) async {
    try {
      // A restored API token may be older than the browser's refreshed cookie.
      // Only an explicit login should replace an existing browser session.
      if (browserCookies == null &&
          await SoundCloudWebCookies.readOauthToken() != null) {
        return;
      }
      await SoundCloudWebCookies.install({
        ...?browserCookies,
        'oauth_token': token,
      });
    } catch (error) {
      appLogger.warning('Could not sync SoundCloud WebView cookies', error);
    }
  }

  @override
  String get platformId => 'soundcloud';

  @override
  String get platformName => 'SoundCloud';

  @override
  IconData get platformIcon => FontAwesome5.soundcloud;

  @override
  Widget buildPlatformIcon({double size = 24, Color? color}) {
    return Icon(platformIcon, size: size, color: color);
  }

  @override
  PlatformCapabilities get capabilities => soundCloudCapabilities;

  @override
  Future<bool> isLoggedIn() async {
    _applyLanguage(_currentLanguage);
    final cfg = app_settings.settings.platformConfigs['soundcloud'];
    if (cfg is Map && cfg['guest'] == true) {
      _api.client.oauthToken = null;
      _userId = null;
      _userName = 'Guest';
      _api.userId = null;
      return true;
    }
    final token = cfg is Map ? cfg['oauth_token'] as String? : null;
    if (token == null || token.isEmpty) {
      _api.client.oauthToken = null;
      _userId = null;
      _userName = null;
      _api.userId = null;
      return false;
    }
    if (_api.client is SoundCloudMobileClient &&
        (cfg is! Map ||
            (cfg['auth_type'] != 'mobile' &&
                cfg['refresh_token'] is! String))) {
      // Old website cookies cannot authorize the Android API session.
      _api.client.oauthToken = null;
      _userId = null;
      _userName = null;
      _api.userId = null;
      return false;
    }
    if (_api.client.oauthToken == token && _userId != null) return true;
    _api.client.oauthToken = token;
    if (_api.client is SoundCloudMobileClient && cfg is Map) {
      final ddCookie = cfg['datadome_cookie'] as String?;
      if (ddCookie != null && ddCookie.isNotEmpty) {
        (_api.client as SoundCloudMobileClient).datadomeCookie = ddCookie;
      }
      final expiresAt = DateTime.tryParse(cfg['expires_at']?.toString() ?? '');
      if (expiresAt != null &&
          !expiresAt.isAfter(
            DateTime.now().toUtc().add(const Duration(minutes: 2)),
          )) {
        final renewed = await _refreshAuthentication(token);
        if (renewed == null) return false;
        return isLoggedIn();
      }
    }
    final savedUserId = cfg is Map ? cfg['user_id']?.toString() : null;
    if (savedUserId != null &&
        savedUserId.isNotEmpty &&
        !(_api.client is SoundCloudMobileClient &&
            cfg is Map &&
            cfg['refresh_token'] is! String)) {
      _userId = savedUserId;
      _userName = cfg is Map ? cfg['username'] as String? : null;
      _api.userId = savedUserId;
      if (_api.client is! SoundCloudMobileClient) await _syncWebCookies(token);
      return _api.client.oauthToken == token &&
          (app_settings.settings.platformConfigs['soundcloud']
                  as Map?)?['oauth_token'] ==
              token;
    }
    _userId = null;
    _userName = null;
    _api.userId = null;
    late final Map<String, dynamic> user;
    try {
      user = await _api.client.get('/me') as Map<String, dynamic>;
    } catch (_) {
      // A network or client-ID lookup failure does not invalidate the cookie.
      // Keep the token so a later check can retry.
      return false;
    }
    if (_api.client.oauthToken != token ||
        (app_settings.settings.platformConfigs['soundcloud']
                as Map?)?['oauth_token'] !=
            token) {
      return false;
    }
    final userId = user['id']?.toString();
    if (userId == null || userId.isEmpty) return false;
    _userId = userId;
    _userName = user['username'] as String?;
    _api.userId = userId;
    if (_api.client is! SoundCloudMobileClient) await _syncWebCookies(token);
    app_settings.settings.platformConfigs['soundcloud'] = {
      ...cfg as Map,
      'user_id': userId,
      if (_userName != null) 'username': _userName,
    };
    try {
      await app_settings.settings.save();
    } catch (error) {
      // The verified session is still usable in this process.
      appLogger.warning('Could not save SoundCloud account details', error);
    }
    return true;
  }

  @override
  Future<AuthResult> login(Map<String, dynamic> credentials) async {
    _lastExpiredToken = null;
    _lastRecoveredToken = null;
    if (credentials['guest'] == true) {
      _api.client.oauthToken = null;
      _userId = null;
      _userName = 'Guest';
      _api.userId = null;
      app_settings.settings.platformConfigs['soundcloud'] = {'guest': true};
      await app_settings.settings.save();
      return const AuthResult.success();
    }
    SoundCloudMobileTokens? nativeTokens;
    if (_api.client case final SoundCloudMobileClient mobile) {
      final code = credentials['authorization_code'];
      final verifier = credentials['code_verifier'];
      if (code is String && verifier is String) {
        try {
          nativeTokens = await mobile.exchangeAuthorizationCode(
            code: code,
            codeVerifier: verifier,
          );
        } catch (error) {
          appLogger.warning('SoundCloud mobile sign in failed', error);
          return AuthResult.failure(error.toString());
        }
      } else {
        final access = credentials['oauth_token'];
        final refresh = credentials['refresh_token'];
        if (access is String &&
            access.isNotEmpty &&
            refresh is String &&
            refresh.isNotEmpty) {
          nativeTokens = SoundCloudMobileTokens(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: DateTime.now().toUtc().add(const Duration(days: 7)),
          );
        } else if (access is! String || access.isEmpty) {
          return const AuthResult.failure(
            'Enter a SoundCloud mobile access token.',
          );
        }
      }
    }
    final token =
        nativeTokens?.accessToken ?? credentials['oauth_token'] as String?;
    final suppliedCookies = credentials['web_cookies'];
    final browserCookies = suppliedCookies is Map<String, String>
        ? suppliedCookies
        : null;
    if (token == null || token.isEmpty) {
      return const AuthResult.failure('SoundCloud sign in has not finished.');
    }
    final previousToken = _api.client.oauthToken;
    final previousUserId = _userId;
    final previousUserName = _userName;
    _api.client.oauthToken = token;
    try {
      final user = await _api.client.get('/me') as Map<String, dynamic>;
      if (user['id'] == null) throw const FormatException('No SoundCloud user');
      _userId = user['id'].toString();
      _userName = user['username'] as String?;
      _api.userId = _userId;
      await _api.closeBrowserFollow();
      final dd = (_api.client is SoundCloudMobileClient)
          ? (_api.client as SoundCloudMobileClient).datadomeCookie
          : null;
      app_settings.settings.platformConfigs['soundcloud'] = {
        'oauth_token': token,
        if (_api.client is SoundCloudMobileClient) 'auth_type': 'mobile',
        if (nativeTokens != null) 'refresh_token': nativeTokens.refreshToken,
        if (nativeTokens != null)
          'expires_at': nativeTokens.expiresAt.toIso8601String(),
        if (dd != null && dd.isNotEmpty) 'datadome_cookie': dd,
        'user_id': _userId,
        if (_userName != null) 'username': _userName,
      };
      await app_settings.settings.save();
      if (_api.client is! SoundCloudMobileClient) {
        await _syncWebCookies(token, browserCookies ?? {'oauth_token': token});
      }
      return const AuthResult.success();
    } catch (_) {
      _api.client.oauthToken = previousToken;
      _userId = previousUserId;
      _userName = previousUserName;
      _api.userId = previousUserId;
      return const AuthResult.failure(
        'Could not validate the SoundCloud session.',
      );
    }
  }

  @override
  Future<void> logout() async {
    _lastExpiredToken = null;
    _lastRecoveredToken = null;
    _api.client.oauthToken = null;
    _userId = null;
    _userName = null;
    _api.userId = null;
    app_settings.settings.platformConfigs['soundcloud'] = <String, dynamic>{};
    await _api.closeBrowserFollow();
    try {
      await SoundCloudWebCookies.clear();
    } catch (error) {
      appLogger.warning('Could not clear SoundCloud WebView cookies', error);
    }
    await app_settings.settings.save();
  }

  @override
  String? get currentUserId => _userId;

  @override
  String? get currentUserName => _userName;

  @override
  Widget buildLoginWidget({required VoidCallback onSuccess}) =>
      SoundCloudLoginWidget(platform: this, onSuccess: onSuccess);

  @override
  Future<List<Track>> getAllFavoriteTracks() async {
    if (_userId == null) await isLoggedIn();
    final uid = _userId;
    if (uid == null) return [];
    return _api.getAllLikedTracks(uid);
  }

  @override
  Future<PaginatedTrackList> getFavoriteTracks({
    int start = 0,
    int limit = 100,
    Sorting? sort,
  }) async {
    if (_userId == null) await isLoggedIn();
    final uid = _userId;
    if (uid == null) {
      return PaginatedTrackList(tracks: [], hasMore: false);
    }
    final needsSort =
        sort != null && (sort.reverse || sort.type != SortType.DEFAULT);
    if (needsSort) {
      return super.getFavoriteTracks(start: start, limit: limit, sort: sort);
    }
    return _api.getLikedTracks(userId: uid, start: start, limit: limit);
  }

  @override
  Future<SearchResults> search(String query) => _api.search(query);

  @override
  Future<List<String>> searchSuggestions(String query) =>
      _api.searchSuggestions(query);

  @override
  Future<Track> getTrack(String id) => _api.getTrack(id);

  @override
  Future<List<Track>> getTracks(List<String> ids) => _api.getTracks(ids);

  @override
  Future<Album> getAlbum(String id) async {
    final album = await _api.getAlbum(id);
    try {
      final liked = await _api.getLikedPlaylistIds();
      if (liked.contains(id) ||
          (album.id != null && liked.contains(album.id))) {
        album.library = true;
      }
    } catch (_) {}
    return album;
  }

  @override
  Future<Artist> getArtist(String id) => _api.getArtist(id);

  static String _cleanPlaylistId(String id) {
    if (id.startsWith('soundcloud_')) {
      return id.substring('soundcloud_'.length);
    }
    if (id.startsWith('soundcloud:') &&
        !id.startsWith('soundcloud:system-playlists:')) {
      return id.substring('soundcloud:'.length);
    }
    return id;
  }

  @override
  Future<Playlist> getPlaylist(String id, {int limit = 100}) async {
    final cleanId = _cleanPlaylistId(id);
    final playlist = await _api.getPlaylist(
      cleanId,
      limit: limit == 100 ? null : limit,
    );
    try {
      final liked = await getFavoritePlaylistIds();
      if (liked != null &&
          (liked.contains(id) ||
              liked.contains(cleanId) ||
              (playlist.id != null && liked.contains(playlist.id)))) {
        playlist.library = true;
      }
    } catch (_) {}
    return playlist;
  }

  @override
  Future<Playlist> getFullPlaylist(String id) =>
      _api.getPlaylist(_cleanPlaylistId(id));

  @override
  Future<Lyrics> getLyrics(String trackId) async => Lyrics(
    id: trackId,
    errorMessage:
        'SoundCloud does not expose lyrics through its public web player.',
  );

  @override
  String getLyricsSearchQuery(Track track) {
    String title = track.title ?? '';
    final artistStr = track.artistString ?? '';
    return '$title $artistStr'.trim();
  }

  @override
  String getShareUrl(String type, String id) =>
      _api.permalinkFor(type, id) ?? 'https://soundcloud.com';

  @override
  Future<List<Playlist>> getUserPlaylists() =>
      _api.getLibraryPlaylists(_accountId);

  @override
  Future<List<Album>> getUserAlbums() => _api.getLibraryAlbums(_accountId);

  @override
  Future<List<Artist>> getUserArtists() => _api.getFollowedArtists(_accountId);

  @override
  Future<List<Show>> getUserShows() async => [];

  @override
  Future<List<String>?> getFavoriteTrackIds() => _api.getLikedTrackIds();

  @override
  Future<HistoryTrackPage> getHistoryTracks({String? cursor, int limit = 50}) {
    if (_api.client.oauthToken == null) {
      throw StateError('SoundCloud sign in is required');
    }
    return _api.getHistoryTracks(cursor: cursor, limit: limit);
  }

  @override
  Future<List<String>?> getFavoritePlaylistIds() async {
    final liked = await _api.getLikedPlaylistIds();
    List<String> stations;
    try {
      stations = await _api.getLikedSystemPlaylistUrns();
    } catch (_) {
      stations = [];
    }
    final owned = await _api.getLibraryPlaylists(_accountId);
    return {
      ...liked,
      ...stations,
      ...owned
          .where((playlist) => playlist.editable == true)
          .map((playlist) => playlist.id)
          .whereType<String>(),
    }.toList();
  }

  @override
  Future<void> addFavoriteTrack(String id) async {
    appLogger.info(
      '[SoundCloudPlatform] addFavoriteTrack: id=$id, accountId=$_userId, client=${_api.client.runtimeType}',
    );
    try {
      await _api.likeTrack(_accountId, id, like: true);
      invalidateFavoriteTracksCache();
      appLogger.info(
        '[SoundCloudPlatform] addFavoriteTrack completed for id=$id',
      );
    } catch (e, st) {
      appLogger.warning(
        '[SoundCloudPlatform] addFavoriteTrack error for id=$id: $e',
        e,
        st,
      );
      rethrow;
    }
  }

  @override
  Future<void> removeFavoriteTrack(String id) async {
    appLogger.info(
      '[SoundCloudPlatform] removeFavoriteTrack: id=$id, accountId=$_userId, client=${_api.client.runtimeType}',
    );
    try {
      await _api.likeTrack(_accountId, id, like: false);
      invalidateFavoriteTracksCache();
      appLogger.info(
        '[SoundCloudPlatform] removeFavoriteTrack completed for id=$id',
      );
    } catch (e, st) {
      appLogger.warning(
        '[SoundCloudPlatform] removeFavoriteTrack error for id=$id: $e',
        e,
        st,
      );
      rethrow;
    }
  }

  @override
  Future<void> addFavoriteAlbum(String id) async {
    appLogger.info(
      '[SoundCloudPlatform] addFavoriteAlbum: id=$id, accountId=$_userId',
    );
    try {
      await _api.likePlaylist(_accountId, id, like: true);
      appLogger.info(
        '[SoundCloudPlatform] addFavoriteAlbum completed for id=$id',
      );
    } catch (e, st) {
      appLogger.warning(
        '[SoundCloudPlatform] addFavoriteAlbum error for id=$id: $e',
        e,
        st,
      );
      rethrow;
    }
  }

  @override
  Future<void> removeFavoriteAlbum(String id) async {
    appLogger.info(
      '[SoundCloudPlatform] removeFavoriteAlbum: id=$id, accountId=$_userId',
    );
    try {
      await _api.likePlaylist(_accountId, id, like: false);
      appLogger.info(
        '[SoundCloudPlatform] removeFavoriteAlbum completed for id=$id',
      );
    } catch (e, st) {
      appLogger.warning(
        '[SoundCloudPlatform] removeFavoriteAlbum error for id=$id: $e',
        e,
        st,
      );
      rethrow;
    }
  }

  @override
  Future<void> addFavoriteArtist(String id) async {
    appLogger.info(
      '[SoundCloudPlatform] addFavoriteArtist: id=$id, accountId=$_userId',
    );
    try {
      await _api.followArtist(_accountId, id, follow: true);
      appLogger.info(
        '[SoundCloudPlatform] addFavoriteArtist completed for id=$id',
      );
    } catch (e, st) {
      appLogger.warning(
        '[SoundCloudPlatform] addFavoriteArtist error for id=$id: $e',
        e,
        st,
      );
      rethrow;
    }
  }

  @override
  Future<void> removeFavoriteArtist(String id) async {
    appLogger.info(
      '[SoundCloudPlatform] removeFavoriteArtist: id=$id, accountId=$_userId',
    );
    try {
      await _api.followArtist(_accountId, id, follow: false);
      appLogger.info(
        '[SoundCloudPlatform] removeFavoriteArtist completed for id=$id',
      );
    } catch (e, st) {
      appLogger.warning(
        '[SoundCloudPlatform] removeFavoriteArtist error for id=$id: $e',
        e,
        st,
      );
      rethrow;
    }
  }

  @override
  Future<void> dislikeTrack(String id) async =>
      _unsupported('Disliking tracks');

  @override
  Future<void> addFavoritePlaylist(String id) async {
    appLogger.info(
      '[SoundCloudPlatform] addFavoritePlaylist: id=$id, accountId=$_userId',
    );
    try {
      await _api.likePlaylist(_accountId, id, like: true);
      appLogger.info(
        '[SoundCloudPlatform] addFavoritePlaylist completed for id=$id',
      );
    } catch (e, st) {
      appLogger.warning(
        '[SoundCloudPlatform] addFavoritePlaylist error for id=$id: $e',
        e,
        st,
      );
      rethrow;
    }
  }

  @override
  Future<void> removeFavoritePlaylist(String id) async {
    appLogger.info(
      '[SoundCloudPlatform] removeFavoritePlaylist: id=$id, accountId=$_userId',
    );
    try {
      await _api.likePlaylist(_accountId, id, like: false);
      appLogger.info(
        '[SoundCloudPlatform] removeFavoritePlaylist completed for id=$id',
      );
    } catch (e, st) {
      appLogger.warning(
        '[SoundCloudPlatform] removeFavoritePlaylist error for id=$id: $e',
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
  Future<void> deletePlaylist(String id) => _api.deletePlaylist(id);

  @override
  Future<void> addToPlaylist(String trackId, String playlistId) async {
    await _api.editPlaylistTracks(playlistId, trackId, add: true);
    invalidatePlaylistTracksCache(playlistId);
  }

  @override
  Future<void> removeFromPlaylist(String trackId, String playlistId) async {
    await _api.editPlaylistTracks(playlistId, trackId, add: false);
    invalidatePlaylistTracksCache(playlistId);
  }

  List<HomePageItem?> _items(SearchResults results) => [
    ...?results.albums?.map(
      (album) => HomePageItem(type: HomePageItemType.ALBUM, value: album),
    ),
    ...?results.playlists?.map(
      (playlist) =>
          HomePageItem(type: HomePageItemType.PLAYLIST, value: playlist),
    ),
    ...?results.artists?.map(
      (artist) => HomePageItem(type: HomePageItemType.ARTIST, value: artist),
    ),
  ];

  HomePageSection _section(String title, List<HomePageItem?> items) =>
      HomePageSection(
        title: title,
        layout: HomePageSectionLayout.ROW,
        items: items,
      );

  @override
  Future<HomePage> getHomePage() async {
    final signedIn = _api.client.oauthToken != null;
    final sections = <HomePageSection>[];
    try {
      sections.addAll(await _api.getMixedSelectionSections());
    } catch (error) {
      appLogger.warning('SoundCloud mobile home failed', error);
    }
    if (signedIn) {
      try {
        final feed = await _api.getFeedItems(limit: 30);
        if (feed.isNotEmpty) sections.add(_section('Your stream', feed));
      } catch (error) {
        appLogger.warning('SoundCloud following feed failed', error);
      }
    }
    if (_api.client is SoundCloudMobileClient && sections.length < 3) {
      try {
        sections.addAll(await _api.getDiscoverSections());
      } catch (error) {
        appLogger.warning('SoundCloud discover feed failed', error);
      }
    }
    final recentIndex = sections.indexWhere(
      (s) => s.title?.toLowerCase() == 'recently played',
    );
    if (signedIn &&
        (recentIndex == -1 || sections[recentIndex].items.length <= 4)) {
      try {
        final recentItems = await _api.getRecentlyPlayedItems(limit: 20);
        if (recentItems.isNotEmpty) {
          final recentSection = _section('Recently played', recentItems);
          if (recentIndex != -1) {
            sections[recentIndex] = recentSection;
          } else {
            sections.insert(0, recentSection);
          }
        }
      } catch (error) {
        appLogger.warning('SoundCloud recent items failed', error);
      }
    }
    if (sections.isEmpty) {
      final results = await _api.search('new music', limit: 12);
      sections.add(_section('New on SoundCloud', _items(results)));
    }

    final genreCategories = [
      'Trending Hip-Hop & Rap',
      'Trending Electronic',
      'Trending Pop',
      'Trending Dance & EDM',
      'Trending Rock',
      'Trending R&B & Soul',
      'Trending Indie',
      'Chill & Ambient',
    ];
    int genreIndex = 0;

    Future<List<HomePageSection>> loadMoreHomeSections() async {
      final moreSections = <HomePageSection>[];
      final seen = sections.map((s) => s.title?.toLowerCase() ?? '').toSet();
      while (genreIndex < genreCategories.length && moreSections.length < 2) {
        final category = genreCategories[genreIndex++];
        if (seen.contains(category.toLowerCase())) continue;
        try {
          final results = await _api.search(category, limit: 12);
          final items = _items(results);
          if (items.isNotEmpty) {
            seen.add(category.toLowerCase());
            moreSections.add(_section(category, items));
          }
        } catch (_) {}
      }
      return moreSections;
    }

    return HomePage(
      sections: sections,
      hasMore: true,
      loadMore: loadMoreHomeSections,
    );
  }

  @override
  Widget getHomeWidget(BuildContext context) =>
      HomePageScreen(loadPage: getHomePage);

  @override
  Widget? buildPlatformHomeItem(BuildContext context, HomePageItem item) {
    if (item.isPlatformItem('smarttracklist') && item.value is SmartTrackList) {
      final stl = item.value as SmartTrackList;
      final playlist = Playlist(
        id: stl.id,
        title: stl.description ?? stl.title ?? 'Mix',
        description: stl.subtitle ?? stl.description,
        image: stl.cover,
        trackCount: stl.trackCount,
        tracks: stl.tracks,
        platformId: 'soundcloud',
      );
      return SmartTrackListTile(
        stl,
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (context) => PlaylistDetails(playlist)),
          );
        },
        onHold: () {
          final options = getExtraMenuOptions(context, playlist);
          if (options.isNotEmpty) {
            MenuSheet().show(context, options);
          } else {
            MenuSheet().defaultPlaylistMenu(playlist, context: context);
          }
        },
      );
    }
    return null;
  }

  @override
  Future<HomePage> getExplorePage() async {
    final sections = <HomePageSection>[];
    if (_api.client is SoundCloudMobileClient) {
      try {
        final discovery = await _api.getDiscoverSections();
        sections.addAll(discovery);
      } catch (error) {
        appLogger.warning('SoundCloud browse feed failed', error);
      }
    }
    if (sections.isEmpty) {
      try {
        final mixed = await _api.getMixedSelectionSections(web: true);
        sections.addAll(mixed);
      } catch (error) {
        appLogger.warning('SoundCloud web mixed selections failed', error);
      }
    }
    if (sections.length < 5) {
      try {
        final trending = await _api.search('trending', limit: 12);
        final items = _items(trending);
        if (items.isNotEmpty) {
          sections.add(_section('Trending on SoundCloud', items));
        }
      } catch (error) {
        appLogger.warning('SoundCloud explore trending failed', error);
      }
    }
    if (sections.isEmpty) {
      final results = await _api.search('trending', limit: 12);
      sections.add(_section('Trending on SoundCloud', _items(results)));
    }

    final exploreGenres = [
      'Electronic',
      'Hip-Hop & Rap',
      'Pop',
      'Dance & EDM',
      'Rock',
      'R&B & Soul',
      'Indie',
      'Chill',
    ];
    int exploreGenreIndex = 0;

    Future<List<HomePageSection>> loadMoreExploreSections() async {
      final moreSections = <HomePageSection>[];
      final seen = sections.map((s) => s.title?.toLowerCase() ?? '').toSet();
      while (exploreGenreIndex < exploreGenres.length &&
          moreSections.length < 2) {
        final genre = exploreGenres[exploreGenreIndex++];
        final title = 'Explore $genre';
        if (seen.contains(title.toLowerCase())) continue;
        try {
          final results = await _api.search('$genre music', limit: 12);
          final items = _items(results);
          if (items.isNotEmpty) {
            seen.add(title.toLowerCase());
            moreSections.add(_section(title, items));
          }
        } catch (_) {}
      }
      return moreSections;
    }

    return HomePage(
      sections: sections,
      hasMore: true,
      loadMore: loadMoreExploreSections,
    );
  }

  @override
  Widget getExploreWidget(BuildContext context) =>
      HomePageScreen(loadPage: getExplorePage);

  @override
  Future<HomePage> getChannel(String target) async {
    final uri = Uri.parse(target);
    final query = uri.queryParameters['q'] ?? target;
    final results = await _api.search(query, limit: 25);
    return HomePage(sections: [_section(query, _items(results))]);
  }

  @override
  Future<List<Track>> getFlow({String? type}) async {
    if (type != null && type.isNotEmpty) {
      _flowNextCursor = null;
      _seenFlowTrackIds.clear();
      _flowFallbackOffset = 0;
    }

    // 1. Try following feed with cursor pagination
    if (_flowNextCursor != null || _seenFlowTrackIds.isEmpty) {
      try {
        final page = await _api.getFeedTracksPage(
          cursor: _flowNextCursor,
          limit: 50,
        );
        _flowNextCursor = page.nextCursor;
        final newTracks = page.tracks
            .where((t) => t.id != null && _seenFlowTrackIds.add(t.id!))
            .toList();
        if (newTracks.isNotEmpty) {
          return newTracks;
        }
      } catch (error) {
        appLogger.warning('SoundCloud feed tracks flow page failed', error);
      }
    }

    // 2. Continuous fallback: related tracks based on recently played stream tracks
    final recentId = _seenFlowTrackIds.isNotEmpty
        ? _seenFlowTrackIds.last
        : null;
    if (recentId != null) {
      try {
        final related = await _api.getRelatedTracks(recentId);
        final newTracks = related
            .where((t) => t.id != null && _seenFlowTrackIds.add(t.id!))
            .toList();
        if (newTracks.isNotEmpty) {
          return newTracks;
        }
      } catch (error) {
        appLogger.warning('SoundCloud related tracks flow failed', error);
      }
    }

    // 3. Continuous fallback: trending search tracks with offset
    try {
      final results = await _api.search(
        'trending',
        limit: 25,
        offset: _flowFallbackOffset,
      );
      _flowFallbackOffset += 25;
      final tracks = (results.tracks ?? [])
          .where((t) => t.id != null && _seenFlowTrackIds.add(t.id!))
          .toList();
      if (tracks.isNotEmpty) {
        return tracks;
      }
    } catch (error) {
      appLogger.warning('SoundCloud trending fallback flow failed', error);
    }

    final fallback = await _api.search('trending', limit: 25);
    return fallback.tracks ?? [];
  }

  Future<HomePage> getChartsPage() async {
    final sections = <HomePageSection>[];
    final seenTitles = <String>{};

    void addSection(HomePageSection section) {
      final title = section.title?.trim() ?? '';
      if (title.isEmpty || section.items.isEmpty) return;
      if (seenTitles.add(title.toLowerCase())) {
        sections.add(section);
      }
    }

    // 1. Trending Tracks (try /charts first, fallback to search)
    try {
      final tracks = await _api.getCharts(
        kind: 'trending',
        genre: 'soundcloud:genres:all-music',
        limit: 50,
      );
      if (tracks.isNotEmpty) {
        addSection(
          HomePageSection(
            title: 'Top Trending Tracks',
            layout: HomePageSectionLayout.GRID_ROW,
            items: tracks
                .map(
                  (t) => HomePageItem(type: HomePageItemType.TRACK, value: t),
                )
                .toList(),
          ),
        );
      }
    } catch (error) {
      appLogger.warning('SoundCloud charts trending API failed', error);
    }

    if (!seenTitles.contains('top trending tracks')) {
      try {
        final trendingResults = await _api.search('trending', limit: 30);
        final trendingTracks = (trendingResults.tracks ?? [])
            .map((t) => HomePageItem(type: HomePageItemType.TRACK, value: t))
            .toList();
        if (trendingTracks.isNotEmpty) {
          addSection(
            HomePageSection(
              title: 'Top Trending Tracks',
              layout: HomePageSectionLayout.GRID_ROW,
              items: trendingTracks,
            ),
          );
        }
      } catch (error) {
        appLogger.warning('SoundCloud trending tracks search failed', error);
      }
    }

    // 2. Official Top 50 Playlists
    try {
      final topPlaylists = await _api.search('Top 50', limit: 20);
      final playlistItems = (topPlaylists.playlists ?? [])
          .map((p) => HomePageItem(type: HomePageItemType.PLAYLIST, value: p))
          .toList();
      if (playlistItems.isNotEmpty) {
        addSection(
          HomePageSection(title: 'Top 50 Playlists', items: playlistItems),
        );
      }
    } catch (error) {
      appLogger.warning('SoundCloud Top 50 playlists chart failed', error);
    }

    // 3. Curated genre charts and playlists from mixed-selections
    try {
      final mixed = await _api.getMixedSelectionSections(web: true);
      for (final sec in mixed) {
        addSection(sec);
      }
    } catch (error) {
      appLogger.warning('SoundCloud mixed selections chart failed', error);
    }

    // 4. Hot & New Playlists
    try {
      final hotPlaylists = await _api.search('SoundCloud Hot', limit: 15);
      final hotItems = (hotPlaylists.playlists ?? [])
          .map((p) => HomePageItem(type: HomePageItemType.PLAYLIST, value: p))
          .toList();
      if (hotItems.isNotEmpty) {
        addSection(HomePageSection(title: 'Hot & New', items: hotItems));
      }
    } catch (error) {
      appLogger.warning('SoundCloud hot playlists chart failed', error);
    }

    // 5. Top Albums
    try {
      final albumResults = await _api.search('top', limit: 20);
      final albumItems = (albumResults.albums ?? [])
          .map((a) => HomePageItem(type: HomePageItemType.ALBUM, value: a))
          .toList();
      if (albumItems.isNotEmpty) {
        addSection(HomePageSection(title: 'Top Albums', items: albumItems));
      }
    } catch (error) {
      appLogger.warning('SoundCloud top albums chart failed', error);
    }

    // 6. Top Artists
    try {
      final artistResults = await _api.search('top', limit: 20);
      final artistItems = (artistResults.artists ?? [])
          .map((a) => HomePageItem(type: HomePageItemType.ARTIST, value: a))
          .toList();
      if (artistItems.isNotEmpty) {
        addSection(HomePageSection(title: 'Top Artists', items: artistItems));
      }
    } catch (error) {
      appLogger.warning('SoundCloud top artists chart failed', error);
    }

    // Fallback if everything was empty
    if (sections.isEmpty) {
      final results = await _api.search('trending', limit: 25);
      final items = _items(results);
      if (items.isNotEmpty) {
        addSection(
          HomePageSection(title: 'Trending on SoundCloud', items: items),
        );
      }
    }

    return HomePage(sections: sections);
  }

  @override
  Future<SmartTrackList> getSmartTrackList(String id) async {
    final playlist = await getPlaylist(id);
    return SmartTrackList(
      id: id,
      title: '',
      subtitle: playlist.description ?? playlist.title,
      description: playlist.description,
      cover: playlist.image,
      trackCount: playlist.trackCount,
      tracks: playlist.tracks,
      platformId: 'soundcloud',
    );
  }

  @override
  Future<List<Track>> getSmartRadio(String artistId) async {
    try {
      final cleanId = artistId.startsWith('soundcloud:')
          ? artistId.split(':').last
          : artistId;
      final stationUrn = 'soundcloud:system-playlists:artist-stations:$cleanId';
      final tracks = await getPlaylistTracks(stationUrn, 0, nb: 50);
      if (tracks.isNotEmpty) return tracks;
    } catch (e) {
      appLogger.warning('Failed to load artist station for $artistId: $e');
    }
    try {
      final top = await getArtistTopTracks(artistId);
      if (top.isNotEmpty) {
        final related = await _api.getRelatedTracks(top.first.id ?? '');
        return [top.first, ...related.where((t) => t.id != top.first.id)];
      }
    } catch (_) {}
    return [];
  }

  @override
  List<ArtistPageSection> buildArtistPageSections(
    BuildContext? context,
    Artist artist,
  ) {
    if (artist.platformId != platformId || artist.id == null) {
      return const [];
    }
    final sections = <ArtistPageSection>[];

    // Playlists section
    sections.add(
      ArtistPageSection(
        position: ArtistPageSectionPosition.afterAlbums,
        title: 'Playlists'.i18n,
        getCachedItems: () => artist.playlists,
        loadItems: (limit) async {
          if (artist.playlists.isNotEmpty &&
              (limit == null || artist.playlists.length >= limit)) {
            return limit != null
                ? artist.playlists.take(limit).toList()
                : artist.playlists;
          }
          final loaded = await _api.getArtistPlaylists(
            artist.id!,
            limit: limit ?? 50,
          );
          artist.playlists = loaded;
          return loaded;
        },
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

    // Similar artists / Fans also like section
    sections.add(
      ArtistPageSection(
        position: ArtistPageSectionPosition.end,
        title: 'Similar artists'.i18n,
        getCachedItems: () => artist.similarArtists,
        loadItems: (limit) async {
          if (artist.similarArtists.isNotEmpty &&
              (limit == null || artist.similarArtists.length >= limit)) {
            return limit != null
                ? artist.similarArtists.take(limit).toList()
                : artist.similarArtists;
          }
          final loaded = await _api.getSimilarArtists(
            artist.id!,
            limit: limit ?? 30,
          );
          artist.similarArtists = loaded;
          return loaded;
        },
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

    return sections;
  }

  @override
  Future<List<Track>> getLibraryShuffle({int start = 0}) async {
    final tracks = await _api.getAllLikedTracks(_accountId);
    tracks.shuffle();
    return tracks.skip(start).toList();
  }

  @override
  Future<List<Track>> getMix(String trackId) => _api.getRelatedTracks(trackId);

  @override
  Future<List<ShowEpisode>> getShowEpisodes(String showId) async => [];

  @override
  Future<PaginatedShowEpisodeList> getShowEpisodesPage(
    String showId, {
    int start = 0,
    int limit = 50,
  }) async => PaginatedShowEpisodeList(episodes: [], hasMore: false);

  @override
  Future<bool> isFavoriteShow(String id) async => false;

  @override
  Future<void> addFavoriteShow(String id) async =>
      _unsupported('Following shows');

  @override
  Future<void> removeFavoriteShow(String id) async =>
      _unsupported('Unfollowing shows');

  @override
  StreamProvider getStreamProvider() => SoundCloudStreamProvider(_api);

  @override
  List<DownloadQualityOption> get availableDownloadQualities => const [
    DownloadQualityOption(
      app_settings.AudioQuality.MP3_128,
      'SoundCloud standard quality',
    ),
  ];

  @override
  Future<PlatformDownloadMetadata> getDownloadMetadata(String trackId) async {
    final track = await getTrack(trackId);
    final details = track.playbackDetails;
    return PlatformDownloadMetadata.fromTrack(
      track,
      genre:
          details != null &&
              details.length > 1 &&
              details[1].toString().isNotEmpty
          ? details[1].toString()
          : null,
      label:
          details != null &&
              details.length > 2 &&
              details[2].toString().isNotEmpty
          ? details[2].toString()
          : null,
      mimeType: 'audio/mpeg',
      format: 'MP3',
      fileExtension: 'mp3',
    );
  }

  @override
  Future<PlatformLinkResponse?> parseLink(String url) async {
    final result = await _api.parseLink(url);
    if (result == null) return null;
    final type = switch (result.type) {
      PlatformLinkDataType.track => PlatformLinkType.track,
      PlatformLinkDataType.album => PlatformLinkType.album,
      PlatformLinkDataType.artist => PlatformLinkType.artist,
      PlatformLinkDataType.playlist => PlatformLinkType.playlist,
    };
    return PlatformLinkResponse(
      type: type,
      id: result.id,
      platformId: platformId,
    );
  }

  @override
  Future<void> logListen(
    String trackId,
    QueueSource? queue, {
    ListenLogDetails? details,
  }) async {
    if ((details?.listenDuration ?? Duration.zero) <
        const Duration(seconds: 10)) {
      return;
    }
    if (_api.client.oauthToken?.isNotEmpty != true) return;
    final session =
        details?.streamId ??
        (details?.timestamp == null
            ? null
            : '$trackId:${details!.timestamp!.microsecondsSinceEpoch}');
    if (session != null && !_loggedListenSessions.add(session)) return;
    String? contextUrn;
    String? playbackContextUrn;
    var claimedPlaylistContext = false;
    if (queue?.id != null && queue!.id!.isNotEmpty) {
      if (queue.source == 'playlist_page' || queue.source == 'album_page') {
        var id = queue.id!;
        while (id.startsWith('soundcloud:soundcloud:')) {
          id = id.substring('soundcloud:'.length);
        }
        playbackContextUrn =
            id.startsWith('soundcloud:playlists:') ||
                id.startsWith('soundcloud:system-playlists:')
            ? id
            : id.startsWith('system-playlists:')
            ? 'soundcloud:$id'
            : 'soundcloud:playlists:${id.startsWith('soundcloud:') ? id.substring('soundcloud:'.length) : id}';
        if (_reportedPlaylistContexts[queue] != true) {
          contextUrn = playbackContextUrn;
        }
      }
      if (contextUrn != null) {
        _reportedPlaylistContexts[queue] = true;
        claimedPlaylistContext = true;
      }
    }
    try {
      await _api.logListen(
        trackId,
        contextUrn: contextUrn,
        playbackContextUrn: playbackContextUrn,
        details: details,
      );
      while (_loggedListenSessions.length > 200) {
        _loggedListenSessions.remove(_loggedListenSessions.first);
      }
    } catch (_) {
      if (session != null) _loggedListenSessions.remove(session);
      if (claimedPlaylistContext) _reportedPlaylistContexts[queue!] = false;
      rethrow;
    }
  }

  @override
  Future<List<Track>> getArtistTopTracks(String artistId) async {
    final cleanId = artistId.startsWith('soundcloud:')
        ? artistId.split(':').last
        : artistId;
    return _api.getArtistTopTracks(cleanId, limit: 50);
  }

  @override
  Future<List<Album>> getDiscographyPage(
    String artistId, {
    int start = 0,
    int nb = 50,
  }) => _api.getDiscography(artistId, offset: start, limit: nb);

  @override
  Future<List<Track>> getPlaylistTracks(String id, int start, {int nb = 100}) =>
      _api.getPlaylistTracks(_cleanPlaylistId(id), offset: start, limit: nb);

  static const List<ChoicePlatformOption> soundCloudLanguages = [
    ChoicePlatformOption(value: 'en', label: 'English'),
    ChoicePlatformOption(value: 'de', label: 'Deutsch'),
    ChoicePlatformOption(value: 'es', label: 'Español'),
    ChoicePlatformOption(value: 'fr', label: 'Français'),
    ChoicePlatformOption(value: 'it', label: 'Italiano'),
    ChoicePlatformOption(value: 'nl', label: 'Nederlands'),
    ChoicePlatformOption(value: 'pl', label: 'Polski'),
    ChoicePlatformOption(value: 'pt', label: 'Português'),
    ChoicePlatformOption(value: 'sv', label: 'Svenska'),
  ];

  String get _currentLanguage {
    try {
      final cfg = app_settings.settings.platformConfigs['soundcloud'];
      return (cfg is Map ? cfg['language'] as String? : null) ?? 'en';
    } catch (_) {
      return 'en';
    }
  }

  void _applyLanguage(String lang) {
    _api.client.language = lang;
  }

  static String _languageLabel(String code) {
    for (final opt in soundCloudLanguages) {
      if (opt.value == code) return opt.label;
    }
    return code;
  }

  @override
  List<PlatformSetting> get settings => [
    ChoicePlatformSetting(
      id: 'soundcloud_language',
      title: 'Content language'.i18n,
      description:
          'Not app language, used in headers. Now'.i18n +
          ': ${_languageLabel(_currentLanguage)}',
      icon: Icons.language,
      currentValue: _currentLanguage,
      options: soundCloudLanguages,
      onChanged: (value) async {
        final cfg = app_settings.settings.platformConfigs['soundcloud'];
        final map = cfg is Map
            ? Map<String, dynamic>.from(cfg)
            : <String, dynamic>{};
        map['language'] = value;
        app_settings.settings.platformConfigs['soundcloud'] = map;
        _applyLanguage(value);
        await app_settings.settings.save();
      },
    ),
    ActionPlatformSetting(
      id: 'soundcloud_copy_access_token',
      title: 'Copy access token',
      description: 'Copy userToken/ARL Cookie for use in other apps.',
      icon: Icons.copy,
      currentValueDisplay: '',
      onAction: (context) async {
        final config = app_settings.settings.platformConfigs['soundcloud'];
        String? token = config is Map ? config['oauth_token'] as String? : null;
        if (token == null ||
            token.isEmpty ||
            config is! Map ||
            (config['auth_type'] != 'mobile' &&
                config['refresh_token'] is! String)) {
          await Fluttertoast.showToast(msg: 'No SoundCloud access token saved');
          return;
        }
        final expiresAt = DateTime.tryParse(
          config['expires_at']?.toString() ?? '',
        );
        if (expiresAt != null &&
            !expiresAt.isAfter(
              DateTime.now().toUtc().add(const Duration(minutes: 2)),
            )) {
          _api.client.oauthToken = token;
          token = await _refreshAuthentication(token);
        }
        if (token == null || token.isEmpty) {
          await Fluttertoast.showToast(
            msg: 'Could not refresh SoundCloud access token',
          );
          return;
        }
        await Clipboard.setData(ClipboardData(text: token));
        await Fluttertoast.showToast(msg: 'SoundCloud access token copied');
      },
    ),
  ];

  @override
  List<QuickAccessItem> get searchQuickAccessItems => [
    QuickAccessItem(
      title: 'Stream'.i18n,
      icon: const Icon(Typicons.waves, color: Colors.white),
      color: const Color(0xffff5500),
      onTap: (context) async {
        await GetIt.I<AudioPlayerHandler>().playFromSmartTrackList(
          SmartTrackList(
            id: 'flow',
            title: 'Stream'.i18n,
            platformId: 'soundcloud',
          ),
        );
      },
    ),
    QuickAccessItem(
      title: 'Mixes'.i18n,
      icon: const Icon(Icons.queue_music, color: Colors.white),
      color: const Color(0xff7c42bb),
      onTap: (context) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => Scaffold(
              appBar: FreezerAppBar('Mixes'.i18n),
              body: HomePageScreen(
                loadPage: () async {
                  final sections = <HomePageSection>[];
                  if (_api.client is SoundCloudMobileClient) {
                    try {
                      final discovery = await _api.getDiscoverSections();
                      final mixSections = discovery.where((s) {
                        final t = s.title?.toLowerCase() ?? '';
                        return t.contains('mix') ||
                            t.contains('upload') ||
                            t.contains('weekly') ||
                            t.contains('for you');
                      }).toList();
                      sections.addAll(mixSections);
                    } catch (error) {
                      appLogger.warning(
                        'SoundCloud mixes discovery failed',
                        error,
                      );
                    }
                  }
                  try {
                    final webSections = await _api.getMixedSelectionSections();
                    final mixSections = webSections.where((s) {
                      final t = s.title?.toLowerCase() ?? '';
                      return t.contains('mix') ||
                          t.contains('upload') ||
                          t.contains('weekly') ||
                          t.contains('for you');
                    }).toList();
                    sections.addAll(mixSections);
                  } catch (error) {
                    appLogger.warning(
                      'SoundCloud mixes web selections failed',
                      error,
                    );
                  }
                  if (sections.isEmpty) {
                    final results = await _api.search('mix', limit: 25);
                    final items = _items(results);
                    if (items.isNotEmpty) {
                      sections.add(_section('SoundCloud Mixes', items));
                    }
                  }
                  return HomePage(sections: sections);
                },
              ),
            ),
          ),
        );
      },
    ),
    QuickAccessItem(
      title: 'Charts'.i18n,
      icon: const Icon(FontAwesome5.chart_line, color: Colors.white),
      color: const Color(0xffff555d),
      onTap: (context) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => Scaffold(
              appBar: FreezerAppBar('Charts'.i18n),
              body: HomePageScreen(loadPage: getChartsPage),
            ),
          ),
        );
      },
    ),
  ];
}
