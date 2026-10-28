import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:get_it/get_it.dart';
import 'package:material_ui/material_ui.dart';
import 'package:saturn/platform/platform_settings.dart';
import 'package:intl/intl.dart';
import '../../utils/logging.dart';
import '../../translations.i18n.dart';
import '../../ui/login_components.dart';

import '../../api/definitions.dart';
import '../../settings.dart' as app_settings;
import '../../platform/music_platform.dart';
import '../../platform/download_metadata.dart';
import '../../platform/platform_capabilities.dart';
import '../../platform/stream_provider.dart';
import 'neurokaraoke_capabilities.dart';
import 'neurokaraoke_api.dart';
import 'neurokaraoke_stream_provider.dart';
import 'neurokaraoke_browse_page.dart';
import 'package:fluttericon/font_awesome5_icons.dart';
import 'package:fluttericon/typicons_icons.dart';

import 'neurokaraoke_explore_page.dart';
import 'radio/neuro_radio_service.dart';
import '../../ui/details_screens.dart';
import '../../ui/home_screen.dart';
import '../../platform/platform_manager.dart';
import '../../service/audio_service.dart';

class NeuroKaraokePlatform extends MusicPlatform {
  final NeuroKaraokeAPI _api = NeuroKaraokeAPI();

  /// Live state of the Neuro 21 radio station. Connects only while listened to.
  late final NeuroRadioService radio = NeuroRadioService(
    mapTrack: (song) => _withPlatformTrack(_api.mapToRadioTrack(song)),
  );

  Track _withPlatformTrack(Track track) {
    track.platformId = platformId;
    track.album?.platformId = platformId;
    for (final artist in track.artists ?? <Artist>[]) {
      artist.platformId = platformId;
    }
    return track;
  }

  Playlist _withPlatformPlaylist(Playlist playlist) {
    playlist.platformId = platformId;
    for (final track in playlist.tracks ?? <Track>[]) {
      _withPlatformTrack(track);
    }
    return playlist;
  }

  SearchResults _withPlatformSearchResults(SearchResults results) {
    results.tracks = results.tracks?.map(_withPlatformTrack).toList();
    results.playlists = results.playlists?.map(_withPlatformPlaylist).toList();
    results.setlists = results.setlists?.map(_withPlatformPlaylist).toList();
    return results;
  }

  // ---------------------------------------------------------------------------
  // Identity
  // ---------------------------------------------------------------------------

  @override
  String get platformId => 'neurokaraoke';

  @override
  String get platformName => 'Neuro Karaoke';

  @override
  IconData get platformIcon => Icons.music_note;

  @override
  Widget buildPlatformIcon({double size = 24, Color? color}) {
    return Builder(
      builder: (context) {
        final effectiveColor =
            color ??
            IconTheme.of(context).color ??
            Theme.of(context).colorScheme.onSurface;
        return Image.asset(
          'assets/neurokaraoke_icon.png',
          width: size,
          height: size,
          color: effectiveColor,
          colorBlendMode: BlendMode.srcIn,
        );
      },
    );
  }

  @override
  PlatformCapabilities get capabilities => neurokaraokeCapabilities;

  // ---------------------------------------------------------------------------
  // Auth
  // ---------------------------------------------------------------------------

  @override
  Future<bool> isLoggedIn() async {
    if (_api.hasAuthToken && _api.currentUsername == null) {
      await _api.fetchCurrentUser();
    }
    return _api.isLoggedIn();
  }

  @override
  List<PlatformAppShortcut> get appShortcuts => [
    PlatformAppShortcut(
      id: 'trending',
      title: 'Trending'.i18n,
      icon: 'shortcut_trending',
    ),
  ];

  @override
  Future<void> handleAppShortcut(String id) async {
    if (id != 'trending') return;
    final playlist = await getFullPlaylist('trending');
    final tracks = playlist.tracks;
    if (tracks == null || tracks.isEmpty) return;
    final firstTrackId = tracks.first.id;
    if (firstTrackId == null) return;
    await GetIt.I<AudioPlayerHandler>().playFromPlaylist(
      playlist,
      firstTrackId,
    );
  }

  @override
  Future<AuthResult> login(Map<String, dynamic> credentials) async {
    final token = credentials['token'] as String?;
    if (token != null && token.isNotEmpty) {
      return await _api.loginWithToken(token);
    }

    final username = credentials['username'] as String?;
    final password = credentials['password'] as String?;

    // Guest login
    if (username == null && password == null) {
      await _api.loginAsGuest();
      return const AuthResult.success();
    }

    if (username == null || password == null) {
      return const AuthResult.failure('Username or password missing');
    }
    return await _api.login(username, password);
  }

  @override
  Future<void> logout() async {
    await _api.logout();
  }

  @override
  String? get currentUserId => _api.currentUserId;

  @override
  String? get currentUserName =>
      _api.isGuest ? 'Guest' : (_api.currentUsername ?? 'Authenticated User');

  String? get authToken => _api.authToken;

  @override
  Future<List<Track>> getAllFavoriteTracks() async {
    final allTracks = (await _api.getFavoriteTracks())
        .map(_withPlatformTrack)
        .toList();
    final Set<String> seenIds = {};
    final List<Track> uniqueTracks = [];
    for (var track in allTracks) {
      if (track.id != null && !seenIds.contains(track.id)) {
        seenIds.add(track.id!);
        uniqueTracks.add(track);
      }
    }
    return uniqueTracks;
  }

  @override
  Widget buildLoginWidget({required VoidCallback onSuccess}) {
    return _NeuroKaraokeLoginForm(onSuccess: onSuccess, platform: this);
  }

  // ---------------------------------------------------------------------------
  // Search
  // ---------------------------------------------------------------------------

  @override
  Future<SearchResults> search(String query) async =>
      _withPlatformSearchResults(await _api.search(query));

  @override
  Future<List<String>> searchSuggestions(String query) async => [];

  // ---------------------------------------------------------------------------
  // Content fetching
  // ---------------------------------------------------------------------------

  @override
  Future<Track> getTrack(String id) async =>
      _withPlatformTrack(await _api.getTrack(id));

  @override
  Future<List<Track>> getTracks(List<String> ids) async {
    try {
      final tracks = await _api.getTracks(ids);
      return tracks.map((t) => _withPlatformTrack(t)).toList();
    } catch (_) {
      return [];
    }
  }

  @override
  Future<Album> getAlbum(String id) async {
    throw UnimplementedError('getAlbum not implemented for Neuro Karaoke');
  }

  @override
  Future<Artist> getArtist(String id) async {
    final artist = await _api.getArtist(id);
    if (artist == null) {
      throw Exception('Artist not found: $id');
    }
    return artist;
  }

  static String _cleanPlaylistId(String id) {
    if (id.startsWith('neurokaraoke_')) {
      return id.substring('neurokaraoke_'.length);
    }
    if (id.startsWith('neurokaraoke:')) {
      return id.substring('neurokaraoke:'.length);
    }
    return id;
  }

  @override
  Future<Playlist> getPlaylist(String id, {int limit = 100}) async {
    final cleanId = _cleanPlaylistId(id);
    final playlist = _withPlatformPlaylist(
      await _api.getPlaylist(cleanId, limit: limit),
    );
    if (playlist.tracks != null && playlist.tracks!.length > limit) {
      final total = playlist.trackCount ?? playlist.tracks!.length;
      playlist.tracks = playlist.tracks!.sublist(0, limit);
      playlist.trackCount = total;
    }
    return playlist;
  }

  @override
  Future<Playlist> getFullPlaylist(String id) async {
    return _withPlatformPlaylist(
      await _api.getPlaylist(_cleanPlaylistId(id), limit: 500),
    );
  }

  @override
  Future<Lyrics> getLyrics(String trackId) async {
    return await _api.getLyrics(trackId);
  }

  @override
  String getLyricsSearchQuery(Track track) {
    String title = (track.title ?? '').trim();
    // The radio display can be "Artist - Song (Cover artist)". Remove the
    // performer credit before searching, including names such as Neuro x Evil.
    final coverTag = RegExp(
      r'\s*[\(\[]((?:Neuro|Evil|Duet)[^\)\]]*)[\)\]]\s*$',
      caseSensitive: false,
    ).firstMatch(title);
    final coverName = coverTag?.group(1)?.trim();
    if (coverTag != null) {
      title = title.substring(0, coverTag.start).trim();
    }
    title = title
        .replaceAll(
          RegExp(
            r'\s*[\(\[](?:Neuro|Evil|Duet)[^\)\]]*[\)\]]',
            caseSensitive: false,
          ),
          '',
        )
        .trim();

    final separator = title.indexOf(' - ');
    if (separator >= 0) {
      final artist = title.substring(0, separator).trim();
      final song = title.substring(separator + 3).trim();
      if (coverName != null &&
          artist.toLowerCase() == coverName.toLowerCase() &&
          song.isNotEmpty) {
        return song;
      }
      return title;
    }

    // If original artists are in navigableArtists, use "OriginalArtist - Title"
    final originalArtist = track.navigableArtists?.firstOrNull?.name;
    if (originalArtist != null && originalArtist.isNotEmpty) {
      return '$originalArtist - $title';
    }

    // Otherwise, append artist if it's not a cover artist or station name
    final artistStr = track.artistString ?? '';
    if (artistStr.isNotEmpty &&
        !artistStr.toLowerCase().contains('station') &&
        !artistStr.toLowerCase().contains('radio') &&
        artistStr != 'Neuro' &&
        artistStr != 'Evil' &&
        artistStr != 'Duet') {
      return '$title $artistStr'.trim();
    }

    return title;
  }

  // ---------------------------------------------------------------------------
  // User Actions (Favorites, Playlists)
  // ---------------------------------------------------------------------------

  @override
  Future<void> addFavoriteTrack(String id) async {
    await _api.toggleFavoriteTrack(id);
    invalidateFavoriteTracksCache();
  }

  @override
  Future<void> removeFavoriteTrack(String id) async {
    await _api.toggleFavoriteTrack(id);
    invalidateFavoriteTracksCache();
  }

  // ---------------------------------------------------------------------------
  // Library (read)
  // ---------------------------------------------------------------------------

  @override
  Future<List<Playlist>> getUserPlaylists() async {
    final favorites = await _api.getFavoritePlaylists();
    final created = await _api.getCreatedPlaylists();

    final allPlaylists = [...created, ...favorites].map(_withPlatformPlaylist);

    final Set<String> seenIds = {};
    final List<Playlist> uniquePlaylists = [];
    for (var playlist in allPlaylists) {
      if (playlist.id != null && !seenIds.contains(playlist.id)) {
        seenIds.add(playlist.id!);
        uniquePlaylists.add(playlist);
      }
    }
    return uniquePlaylists;
  }

  @override
  Future<List<Album>> getUserAlbums() async => [];

  @override
  String getShareUrl(String type, String id) {
    if (type == 'track') type = 'song';
    return 'https://www.neurokaraoke.com/$type/$id';
  }

  @override
  Future<List<Artist>> getUserArtists() async => [];

  @override
  Future<List<Show>> getUserShows() async => [];

  @override
  Future<List<String>?> getFavoriteTrackIds() async {
    final allTracks = await _api.getFavoriteTracks();
    return allTracks.map((t) => t.id!).toSet().toList();
  }

  @override
  Future<List<String>?> getFavoritePlaylistIds() async {
    final allPlaylists = await _api.getFavoritePlaylists();
    return allPlaylists.map((p) => p.id!).toSet().toList();
  }

  // ---------------------------------------------------------------------------
  // Library mutations
  // ---------------------------------------------------------------------------

  @override
  Future<void> addFavoriteAlbum(String id) async {}

  @override
  Future<void> removeFavoriteAlbum(String id) async {}

  @override
  Future<void> addFavoriteArtist(String id) async {}

  @override
  Future<void> removeFavoriteArtist(String id) async {}

  @override
  Future<void> dislikeTrack(String id) async {}

  @override
  Future<void> addFavoritePlaylist(String id) async {
    await _api.toggleFavoritePlaylist(id);
  }

  @override
  Future<void> removeFavoritePlaylist(String id) async {
    await _api.toggleFavoritePlaylist(id);
  }

  @override
  Future<String> createPlaylist(
    String title, {
    String description = '',
    int status = 0,
    List<String> trackIds = const [],
  }) async {
    final newId = await _api.createPlaylist(
      title,
      description: description,
      isPublic: status == 2,
    );
    // Add initial tracks one by one if provided
    for (final trackId in trackIds) {
      await _api.addToPlaylist(trackId, newId);
    }
    return newId;
  }

  @override
  Future<void> updatePlaylist(
    String id,
    String title, {
    String description = '',
    int status = 0,
  }) async {
    await _api.updatePlaylist(
      id,
      title,
      description: description,
      isPublic: status == 2,
    );
  }

  @override
  Future<void> deletePlaylist(String id) async {
    await _api.deletePlaylist(id);
  }

  @override
  Future<void> addToPlaylist(String trackId, String playlistId) async {
    await _api.addToPlaylist(trackId, playlistId);
    invalidatePlaylistTracksCache(playlistId);
  }

  @override
  Future<void> removeFromPlaylist(String trackId, String playlistId) async {
    await _api.removeFromPlaylist(trackId, playlistId);
    invalidatePlaylistTracksCache(playlistId);
  }

  // ---------------------------------------------------------------------------
  // Streaming
  // ---------------------------------------------------------------------------

  @override
  StreamProvider getStreamProvider() => NeuroKaraokeStreamProvider(_api);

  @override
  Uri? directPlaybackUri(Track track) {
    // Mobile plays this through the shared proxy so the next track can be
    // downloaded there before ExoPlayer reaches it.
    if (Platform.isAndroid || Platform.isIOS) return null;
    final details = track.playbackDetails;
    if (details == null || details.isEmpty) return null;
    final uri = Uri.tryParse(details.first.toString());
    if (uri?.scheme != 'https' || uri?.host != 'storage.neurokaraoke.com') {
      return null;
    }
    return uri;
  }

  @override
  List<DownloadQualityOption> get availableDownloadQualities => const [
    DownloadQualityOption(
      app_settings.AudioQuality.MP3_320,
      'Original quality',
    ),
  ];

  @override
  Future<PlatformDownloadMetadata> getDownloadMetadata(String trackId) async {
    final track = await getTrack(trackId);
    final details = track.playbackDetails;
    final url = details == null || details.isEmpty
        ? null
        : details.first.toString().toLowerCase();
    final isMp3 = url?.contains('.mp3') == true;
    return PlatformDownloadMetadata.fromTrack(
      track,
      format: isMp3 ? 'MP3' : 'OGG',
      mimeType: isMp3 ? 'audio/mpeg' : 'audio/ogg',
      fileExtension: isMp3 ? 'mp3' : 'ogg',
    );
  }

  // ---------------------------------------------------------------------------
  // Discovery & Radio
  // ---------------------------------------------------------------------------

  @override
  Future<HomePage> getHomePage() async => HomePage(sections: []);

  @override
  Widget getHomeWidget(BuildContext context) =>
      NeuroKaraokeExplorePage(api: _api, radio: radio);

  @override
  Future<HomePage> getExplorePage() async =>
      getChannel('public_playlists?startIndex=0');

  @override
  Widget getExploreWidget(BuildContext context) =>
      const NeuroKaraokeBrowsePage();
  @override
  Future<HomePage> getChannel(String target) async {
    if (target.startsWith('public_playlists')) {
      final uri = Uri.parse(target);
      final startIndex =
          int.tryParse(uri.queryParameters['startIndex'] ?? '0') ?? 0;
      final isSetlist = uri.queryParameters['isSetlist'] == 'true';
      final playlists = await _api.getPublicPlaylists(
        startIndex: startIndex,
        pageSize: 25,
        isSetlist: isSetlist,
      );
      final items = playlists
          .map((p) => HomePageItem(type: HomePageItemType.PLAYLIST, value: p))
          .toList();

      return HomePage(
        sections: [
          HomePageSection(
            title: isSetlist ? 'All Setlists' : 'Public Playlists',
            items: items,
            layout: HomePageSectionLayout.GRID,
            hasMore: playlists.length == 25,
            pagePath:
                'public_playlists?startIndex=${startIndex + 25}&isSetlist=$isSetlist',
          ),
        ],
      );
    }
    return HomePage(sections: []);
  }

  @override
  Future<List<Track>> getFlow({String? type}) async => [];

  @override
  Future<SmartTrackList> getSmartTrackList(String id) async =>
      throw UnimplementedError();

  @override
  Future<List<Track>> getSmartRadio(String artistId) async => [];

  @override
  Future<List<Track>> getLibraryShuffle({int start = 0}) async => [];

  @override
  Future<List<Track>> getMix(String trackId) async => [];

  // ---------------------------------------------------------------------------
  // Radio (Neuro 21 Station)
  // ---------------------------------------------------------------------------

  @override
  bool get supportsRadioTiming => true;

  @override
  Duration radioPositionAdjustment(String stationId) {
    if (stationId != kNeuroRadioStationId) return Duration.zero;
    if (Platform.isAndroid) return const Duration(seconds: 5);
    if (Platform.isLinux || Platform.isWindows) {
      return const Duration(seconds: 3);
    }
    return Duration.zero;
  }

  @override
  Future<String?> getRadioStreamUrl(String id) => radio.fetchStreamUrl();

  @override
  Stream<RadioNowPlaying> getRadioInfoStream(String id) =>
      radio.updates.map((update) {
        final track = update.state.current;
        if (track == null) return const RadioNowPlaying();
        return RadioNowPlaying(
          track: track,
          startedAt: update.timing?.songId == track.id
              ? update.timing?.startedAt
              : null,
          displayTitle: radioDisplayTitle(track),
        );
      });

  // ---------------------------------------------------------------------------
  // Shows / podcasts
  // ---------------------------------------------------------------------------

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
  Future<void> addFavoriteShow(String id) async {}

  @override
  Future<void> removeFavoriteShow(String id) async {}

  // ---------------------------------------------------------------------------
  // Android Auto
  // ---------------------------------------------------------------------------

  @override
  Future<List<MediaItem>?> getAndroidAutoItems(String parentId) async {
    const contentStylePlayableHint =
        'android.media.browse.CONTENT_STYLE_PLAYABLE_HINT';
    const contentStyleBrowsableHint =
        'android.media.browse.CONTENT_STYLE_BROWSABLE_HINT';
    const contentStyleGroupTitleHint =
        'android.media.browse.CONTENT_STYLE_GROUP_TITLE_HINT';
    const contentStyleGrid = 2;

    final radioItem = MediaItem(
      id: '_aa_radio_${platformId}_$kNeuroRadioStationId',
      title: kNeuroRadioStationName,
      album: platformName,
      displayTitle: kNeuroRadioStationName,
      displaySubtitle: 'Live 24/7 Stream'.i18n,
      playable: true,
      extras: const {
        contentStylePlayableHint: contentStyleGrid,
        contentStyleBrowsableHint: contentStyleGrid,
        contentStyleGroupTitleHint: 'Radio',
      },
    );

    if (parentId == 'radio') {
      return [radioItem];
    }

    if (parentId == 'homescreen') {
      final items = <MediaItem>[radioItem];
      try {
        final recent = await _api.getRecentSetlist();
        items.addAll([
          MediaItem(
            id: '_aa_playlist_${platformId}_made-for-you',
            title: 'Your mix'.i18n,
            album: platformName,
            displayTitle: 'Your mix'.i18n,
            displaySubtitle: 'Made for You'.i18n,
            playable: true,
            artUri: Uri.tryParse(
              'https://www.neurokaraoke.com/img/nosource.png',
            ),
            extras: const {
              contentStylePlayableHint: contentStyleGrid,
              contentStyleBrowsableHint: contentStyleGrid,
              contentStyleGroupTitleHint: 'Featured',
            },
          ),
          MediaItem(
            id: '_aa_playlist_${platformId}_trending',
            title: 'Trending This Week'.i18n,
            album: platformName,
            displayTitle: 'Trending This Week'.i18n,
            displaySubtitle: 'Charts'.i18n,
            playable: true,
            artUri: Uri.tryParse(
              'https://www.neurokaraoke.com/img/nosource.png',
            ),
            extras: const {
              contentStylePlayableHint: contentStyleGrid,
              contentStyleBrowsableHint: contentStyleGrid,
              contentStyleGroupTitleHint: 'Featured',
            },
          ),
          if (recent != null)
            MediaItem(
              id: '_aa_playlist_${platformId}_recent',
              title: recent.title ?? 'Recent Setlist'.i18n,
              album: platformName,
              displayTitle: recent.title ?? 'Recent Setlist'.i18n,
              displaySubtitle: 'Recent Setlist'.i18n,
              playable: true,
              artUri: Uri.tryParse(
                recent.image?.thumb ?? recent.image?.full ?? '',
              ),
              extras: const {
                contentStylePlayableHint: contentStyleGrid,
                contentStyleBrowsableHint: contentStyleGrid,
                contentStyleGroupTitleHint: 'Featured',
              },
            ),
        ]);
      } catch (_) {}

      try {
        final playlists = await getUserPlaylists();
        for (final p in playlists.take(15)) {
          items.add(
            MediaItem(
              id: '_aa_playlist_${platformId}_${p.id}',
              title: p.title ?? '',
              album: 'Playlist'.i18n,
              displayTitle: p.title,
              displaySubtitle: '${p.trackCount ?? 0} ${'Tracks'.i18n}',
              playable: true,
              artUri: Uri.tryParse(p.image?.thumb ?? ''),
              extras: const {
                contentStylePlayableHint: contentStyleGrid,
                contentStyleBrowsableHint: contentStyleGrid,
                contentStyleGroupTitleHint: 'Playlists',
              },
            ),
          );
        }
      } catch (_) {}
      return items;
    }

    if (parentId == 'explore') {
      final items = <MediaItem>[];
      // 1. Public playlists
      try {
        final playlists = await _api.getPublicPlaylists(
          startIndex: 0,
          pageSize: 10,
          isSetlist: false,
        );
        for (final p in playlists) {
          items.add(
            MediaItem(
              id: '_aa_playlist_${platformId}_${p.id}',
              title: p.title ?? '',
              album: platformName,
              displayTitle: p.title,
              displaySubtitle: '${p.trackCount ?? 0} ${'Tracks'.i18n}',
              playable: true,
              artUri: Uri.tryParse(p.image?.thumb ?? ''),
              extras: const {
                contentStylePlayableHint: contentStyleGrid,
                contentStyleBrowsableHint: contentStyleGrid,
                contentStyleGroupTitleHint: 'Public Playlists',
              },
            ),
          );
        }
      } catch (_) {}

      // 2. Setlists
      try {
        final setlists = await _api.getPublicPlaylists(
          startIndex: 0,
          pageSize: 10,
          isSetlist: true,
        );
        for (final p in setlists) {
          items.add(
            MediaItem(
              id: '_aa_playlist_${platformId}_${p.id}',
              title: p.title ?? '',
              album: platformName,
              displayTitle: p.title,
              displaySubtitle: '${p.trackCount ?? 0} ${'Tracks'.i18n}',
              playable: true,
              artUri: Uri.tryParse(p.image?.thumb ?? ''),
              extras: const {
                contentStylePlayableHint: contentStyleGrid,
                contentStyleBrowsableHint: contentStyleGrid,
                contentStyleGroupTitleHint: 'Setlists',
              },
            ),
          );
        }
      } catch (_) {}

      // 3. Artists
      try {
        final artists = await _api.getArtists(startIndex: 0, pageSize: 10);
        for (final a in artists) {
          items.add(
            MediaItem(
              id: 'artist_${platformId}_${a.id}',
              title: a.name ?? '',
              album: platformName,
              displayTitle: a.name,
              displaySubtitle: '${a.fans ?? ''} ${'Tracks'.i18n}'.trim(),
              playable: false,
              artUri: Uri.tryParse(a.picture?.thumb ?? a.picture?.full ?? ''),
              extras: const {
                contentStylePlayableHint: contentStyleGrid,
                contentStyleBrowsableHint: contentStyleGrid,
                contentStyleGroupTitleHint: 'Artists',
              },
            ),
          );
        }
      } catch (_) {}

      return items;
    }

    return null;
  }

  // ---------------------------------------------------------------------------
  // Discography & Pagination
  // ---------------------------------------------------------------------------

  @override
  Future<List<Track>> getArtistTopTracks(String artistId) async {
    final artist = await getArtist(artistId);
    return artist.topTracks;
  }

  @override
  Future<List<Album>> getDiscographyPage(
    String artistId, {
    int start = 0,
    int nb = 50,
  }) async => [];

  @override
  Future<List<Track>> getPlaylistTracks(
    String id,
    int start, {
    int nb = 100,
  }) async {
    final playlist = await getFullPlaylist(id);
    final tracks = playlist.tracks ?? [];

    if (start >= tracks.length) return [];
    final end = (start + nb < tracks.length) ? start + nb : tracks.length;
    return tracks.sublist(start, end);
  }

  // ---------------------------------------------------------------------------
  // Listen logging
  // ---------------------------------------------------------------------------

  @override
  Future<void> logListen(
    String trackId,
    QueueSource? queue, {
    ListenLogDetails? details,
  }) async {
    String? playlistId;
    if (queue != null) {
      if (queue.source == 'favorites_page') {
        playlistId = 'favorites';
      } else if (queue.source == 'playlist_page' && queue.id != null) {
        playlistId = queue.id;
        if (playlistId!.contains(':')) {
          playlistId = playlistId.split(':').sublist(1).join(':');
        }
      }
    }
    await _api.logPlayCount(trackId, playlistId);
  }

  // ---------------------------------------------------------------------------
  // Internal Links
  // ---------------------------------------------------------------------------

  @override
  Future<TrackPageData?> getTrackPageData(String trackId) async {
    try {
      final raw = await _api.getSongRaw(trackId);
      if (raw == null) return null;

      final track = _withPlatformTrack(_api.mapToTrack(raw));

      final pollFuture = _api.getSongPoll(trackId);
      final lyricsFuture = _api
          .getLyrics(trackId)
          .catchError((_) => Lyrics(id: trackId));

      final poll = await pollFuture;
      final lyrics = await lyricsFuture;

      final metadata = (raw['metadata'] as Map?)?.cast<String, dynamic>() ?? {};

      final coverArtistsList =
          (raw['coverArtists'] as List?)
              ?.map((a) => a is Map ? a['name'] : a.toString())
              .whereType<String>()
              .toList() ??
          [];
      final originalArtistsList =
          (raw['originalArtists'] as List?)
              ?.map((a) => a is Map ? a['name'] : a.toString())
              .whereType<String>()
              .toList() ??
          [];

      final playCount = (raw['playCount'] as num?)?.toInt();
      final setlist = raw['setlist'] as String?;

      final bio = metadata['description'] as String?;

      final chipGroups = <TrackPageChipGroup>[];
      final genresList = (raw['genres'] as List?)
          ?.map((g) => g is Map ? g['name']?.toString() : g.toString())
          .whereType<String>()
          .where((s) => s.isNotEmpty)
          .toList();
      if (genresList != null && genresList.isNotEmpty) {
        chipGroups.add(
          TrackPageChipGroup(title: 'GENRES'.i18n, chips: genresList),
        );
      }

      final moodsList = (raw['moods'] as List?)
          ?.map((m) => m is Map ? m['name']?.toString() : m.toString())
          .whereType<String>()
          .where((s) => s.isNotEmpty)
          .toList();
      if (moodsList != null && moodsList.isNotEmpty) {
        chipGroups.add(
          TrackPageChipGroup(title: 'MOODS'.i18n, chips: moodsList),
        );
      }

      final themesList = (raw['themes'] as List?)
          ?.map((t) => t is Map ? t['name']?.toString() : t.toString())
          .whereType<String>()
          .where((s) => s.isNotEmpty)
          .toList();
      if (themesList != null && themesList.isNotEmpty) {
        chipGroups.add(
          TrackPageChipGroup(title: 'THEMES'.i18n, chips: themesList),
        );
      }

      final details = <String, dynamic>{};
      if (metadata['tempoBPM'] != null && metadata['tempoBPM'] != 0) {
        details['Tempo'] = '${metadata['tempoBPM']} BPM';
      }
      if (metadata['key'] != null && metadata['key'].toString().isNotEmpty) {
        details['Key'] = metadata['key'].toString();
      }
      if (metadata['energyLevel'] != null) {
        details['Energy'] = metadata['energyLevel'];
      }
      if (metadata['language'] != null &&
          metadata['language'].toString().isNotEmpty) {
        details['Language'] = metadata['language'].toString();
      }
      if (metadata['occasion'] != null &&
          metadata['occasion'].toString().isNotEmpty) {
        details['Occasion'] = metadata['occasion'].toString();
      }

      final credits = <String, String>{};
      if (track.albumArt?.caption != null &&
          track.albumArt!.caption!.isNotEmpty) {
        credits['Artwork'] = track.albumArt!.caption!;
      }
      if (metadata['publishers'] != null &&
          metadata['publishers'].toString().isNotEmpty) {
        credits['Publishers'] = metadata['publishers'].toString();
      }
      if (metadata['writers'] != null &&
          metadata['writers'].toString().isNotEmpty) {
        credits['Writers'] = metadata['writers'].toString();
      }
      if (metadata['composers'] != null &&
          metadata['composers'].toString().isNotEmpty) {
        credits['Composers'] = metadata['composers'].toString();
      }

      final disclaimerUpdatedBy = metadata['updatedBy'] as String?;
      String? disclaimerUpdatedDate = metadata['updatedDate'] as String?;
      if (disclaimerUpdatedDate != null) {
        try {
          final dt = DateTime.parse(disclaimerUpdatedDate);
          disclaimerUpdatedDate = DateFormat.yMMMd().format(dt);
        } catch (_) {}
      }

      final similarRaw = raw['similarSongs'] as List?;
      final similarTracks = <Track>[];
      if (similarRaw != null) {
        for (final item in similarRaw) {
          if (item is Map) {
            similarTracks.add(
              _withPlatformTrack(_api.mapToTrack(item.cast<String, dynamic>())),
            );
          }
        }
      }

      return TrackPageData(
        track: track,
        bio: bio?.isNotEmpty == true ? bio : null,
        chipGroups: chipGroups.isNotEmpty ? chipGroups : null,
        rating: poll,
        details: details.isNotEmpty ? details : null,
        credits: credits.isNotEmpty ? credits : null,
        disclaimer:
            'Information about song bio, energy, genres, themes, and moods was retrieved from online sources using Perplexity and may be inaccurate or incomplete.',
        disclaimerUpdatedDate: disclaimerUpdatedDate,
        disclaimerUpdatedBy: disclaimerUpdatedBy,
        similarTracks: similarTracks.isNotEmpty ? similarTracks : null,
        lyrics:
            (lyrics.syncedLyrics?.isNotEmpty ?? false) ||
                (lyrics.unsyncedLyrics?.isNotEmpty ?? false)
            ? lyrics
            : null,
        custom: {
          if (coverArtistsList.isNotEmpty)
            'coverArtists': coverArtistsList.join(', '),
          if (originalArtistsList.isNotEmpty)
            'originalArtists': originalArtistsList.join(', '),
          'setlist': ?setlist,
          'playCount': ?playCount,
        },
      );
    } catch (e, stack) {
      appLogger.warning('Failed to load NeuroKaraoke track page: $e', e, stack);
      return null;
    }
  }

  @override
  Future<PlatformLinkResponse?> parseLink(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    if (uri.host.contains('neurokaraoke.com')) {
      if (uri.pathSegments.length >= 2 &&
          (uri.pathSegments[0] == 'song' || uri.pathSegments[0] == 'track')) {
        return PlatformLinkResponse(
          type: PlatformLinkType.track,
          id: uri.pathSegments[1],
          platformId: platformId,
        );
      }
    }
    return null;
  }

  @override
  List<PlatformSetting> get settings => [
    ChoicePlatformSetting(
      id: 'neurokaraoke_listen_site',
      title: 'Site used'.i18n,
      description:
          'Choose which Neuro Karaoke site to use. This changes which currency you earn.'
              .i18n,
      icon: Icons.language,
      currentValue:
          (app_settings.settings.platformConfigs['neurokaraoke'] is Map
          ? app_settings.settings.platformConfigs['neurokaraoke']['listenSite']
                    as String? ??
                'https://www.neurokaraoke.com'
          : 'https://www.neurokaraoke.com'),
      options: [
        ChoicePlatformOption(
          value: 'https://www.neurokaraoke.com',
          label: 'Neuro Karaoke'.i18n,
        ),
        ChoicePlatformOption(
          value: 'https://evilkaraoke.com',
          label: 'Evil Karaoke'.i18n,
        ),
        ChoicePlatformOption(
          value: 'https://twinskaraoke.com',
          label: 'Twins Karaoke'.i18n,
        ),
      ],
      onChanged: (value) async {
        final current = app_settings.settings.platformConfigs['neurokaraoke'];
        final config = current is Map
            ? Map<String, dynamic>.from(current)
            : <String, dynamic>{};
        config['listenSite'] = value;
        app_settings.settings.platformConfigs['neurokaraoke'] = config;
        await app_settings.settings.save();
      },
    ),
    ActionPlatformSetting(
      id: 'neurokaraoke_copy_token',
      title: 'Copy Token'.i18n,
      description: 'Copy userToken/ARL Cookie for use in other apps.'.i18n,
      icon: Icons.copy,
      currentValueDisplay: '',
      onAction: (context) async {
        final token =
            authToken ??
            (app_settings.settings.platformConfigs['neurokaraoke'] is Map
                ? app_settings.settings.platformConfigs['neurokaraoke']['token']
                      as String?
                : null) ??
            '';
        if (token.isNotEmpty) {
          await Clipboard.setData(ClipboardData(text: token));
          await Fluttertoast.showToast(msg: 'Copied'.i18n);
        } else {
          await Fluttertoast.showToast(
            msg: 'No token available (guest mode)'.i18n,
          );
        }
      },
    ),
  ];

  @override
  List<QuickAccessItem> get searchQuickAccessItems => [
    QuickAccessItem(
      title: 'Setlists',
      icon: const Icon(
        Typicons.waves,
        color: Colors.white,
      ), // Use waves or list? Flow uses waves. Let's use format_list_bulleted or FontAwesome5 list
      color: const Color(0xff11b192), // Deezer Flow color
      onTap: (context) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => Scaffold(
              appBar: AppBar(title: const Text('All Setlists')),
              body: HomePageScreen(
                loadPage: () => PlatformManager.instance
                    .getPlatform('neurokaraoke')
                    .getChannel('public_playlists?startIndex=0&isSetlist=true'),
              ),
            ),
          ),
        );
      },
    ),
    QuickAccessItem(
      title: 'Charts',
      icon: const Icon(FontAwesome5.chart_line, color: Colors.white),
      color: const Color(0xffff555d), // Deezer Charts color
      onTap: (context) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => PlaylistDetails(
              Playlist(
                id: 'trending',
                title: 'Trending This Week',
                platformId: 'neurokaraoke',
              ),
            ),
          ),
        );
      },
    ),
    QuickAccessItem(
      title: 'Artists',
      icon: const Icon(FontAwesome5.user, color: Colors.white),
      color: const Color(0xff7c42bb), // Deezer Shows color
      onTap: (context) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => Scaffold(
              appBar: AppBar(title: const Text('Artists')),
              body: const NeuroKaraokeArtistsGrid(),
            ),
          ),
        );
      },
    ),
  ];
}

class _NeuroKaraokeLoginForm extends StatefulWidget {
  final VoidCallback onSuccess;
  final NeuroKaraokePlatform platform;

  const _NeuroKaraokeLoginForm({
    required this.onSuccess,
    required this.platform,
  });

  @override
  State<_NeuroKaraokeLoginForm> createState() => _NeuroKaraokeLoginFormState();
}

class _NeuroKaraokeLoginFormState extends State<_NeuroKaraokeLoginForm> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _tokenController = TextEditingController();
  bool _isLoading = false;
  bool _isTokenLoading = false;
  String? _error;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    final result = await widget.platform.login({
      'username': _usernameController.text.trim(),
      'password': _passwordController.text,
    });

    if (!mounted) return;

    if (result.success) {
      widget.onSuccess();
    } else {
      setState(() {
        _error = result.error ?? 'Unknown error';
        _isLoading = false;
      });
    }
  }

  Future<void> _submitToken() async {
    final token = _tokenController.text.trim();
    if (token.isEmpty) {
      setState(() => _error = 'Please enter or paste your token.');
      return;
    }

    setState(() {
      _isTokenLoading = true;
      _error = null;
    });

    final result = await widget.platform.login({'token': token});
    if (!mounted) return;

    if (result.success) {
      widget.onSuccess();
    } else {
      setState(() {
        _error = result.error ?? 'Unknown error';
        _isTokenLoading = false;
      });
    }
  }

  Future<void> _continueAsGuest() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    await widget.platform.login({});
    if (mounted) {
      widget.onSuccess();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isBusy = _isLoading || _isTokenLoading;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LoginTextField(
            controller: _usernameController,
            labelText: 'Username',
            prefixIcon: const Icon(Icons.person_outline),
            enabled: !isBusy,
          ),
          const SizedBox(height: 12),
          LoginTextField(
            controller: _passwordController,
            labelText: 'Password',
            isPassword: true,
            prefixIcon: const Icon(Icons.lock_outline),
            enabled: !isBusy,
            onSubmitted: (_) => _submit(),
          ),
          if (_error != null)
            LoginErrorBanner(
              message: _error!,
              onDismiss: () => setState(() => _error = null),
            ),
          const SizedBox(height: 16),
          LoginPrimaryButton(
            label: 'Log In',
            onPressed: isBusy ? null : _submit,
            isLoading: _isLoading,
          ),
          const LoginDivider(),
          LoginTextField(
            controller: _tokenController,
            labelText: 'Token',
            hintText: 'Enter or paste your token...',
            prefixIcon: const Icon(Icons.key),
            enabled: !isBusy,
            onSubmitted: (_) => _submitToken(),
          ),
          const SizedBox(height: 16),
          LoginPrimaryButton(
            label: 'Connect with Token',
            onPressed: isBusy ? null : _submitToken,
            isLoading: _isTokenLoading,
          ),
          const SizedBox(height: 8),
          LoginSecondaryButton(
            label: 'Continue as Guest',
            onPressed: isBusy ? null : _continueAsGuest,
          ),
        ],
      ),
    );
  }
}
