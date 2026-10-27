import 'package:audio_service/audio_service.dart';
import 'package:material_ui/material_ui.dart';

import '../api/definitions.dart';
import 'download_metadata.dart';
import 'platform_capabilities.dart';
import 'stream_provider.dart';
import 'platform_settings.dart';

/// Represents a link parsed from a platform URL.
class PlatformLinkResponse {
  final PlatformLinkType type;
  final String id;
  final String platformId;

  const PlatformLinkResponse({
    required this.type,
    required this.id,
    required this.platformId,
  });
}

enum PlatformLinkType { track, album, artist, playlist }

/// One page of a platform's listening history. Cursors are opaque to the UI.
class HistoryTrackPage {
  final List<Track> tracks;
  final String? nextCursor;

  const HistoryTrackPage({required this.tracks, this.nextCursor});
}

/// Defines a platform-specific quick access item for the search screen.
class QuickAccessItem {
  final String title;
  final Widget icon;
  final Color color;
  final void Function(BuildContext context) onTap;

  const QuickAccessItem({
    required this.title,
    required this.icon,
    required this.color,
    required this.onTap,
  });
}

enum ArtistPageSectionPosition {
  top,
  beforeTracks,
  afterTracks,
  afterAlbums,
  end,
}

class ArtistPageSection {
  final ArtistPageSectionPosition position;
  final String title;
  final int previewLimit;
  final bool showMore;
  final Future<List<dynamic>> Function(int? limit) loadItems;
  final List<dynamic> Function()? getCachedItems;
  final Widget Function(BuildContext context, dynamic item, List<dynamic> items)
  itemBuilder;

  const ArtistPageSection({
    required this.position,
    required this.title,
    required this.loadItems,
    required this.itemBuilder,
    this.previewLimit = 5,
    this.showMore = true,
    this.getCachedItems,
  });
}

Future<List<dynamic>> artistPageSectionItems<T>(
  List<T> items,
  int? limit,
) async => List<dynamic>.of(limit == null ? items : items.take(limit));

/// Extensible data model for track details pages.
class TrackPageData {
  final Track track;
  final String? bio;
  final Album? album;
  final Lyrics? lyrics;
  final String? lyricsWriters;
  final String? lyricsCopyright;
  final List<Track>? similarTracks;
  final List<TrackPageChipGroup>? chipGroups;
  final TrackCommunityRating? rating;
  final Map<String, dynamic>? details;
  final Map<String, String>? credits;
  final String? disclaimer;
  final String? disclaimerUpdatedDate;
  final String? disclaimerUpdatedBy;
  final Map<String, dynamic>? custom;

  const TrackPageData({
    required this.track,
    this.bio,
    this.album,
    this.lyrics,
    this.lyricsWriters,
    this.lyricsCopyright,
    this.similarTracks,
    this.chipGroups,
    this.rating,
    this.details,
    this.credits,
    this.disclaimer,
    this.disclaimerUpdatedDate,
    this.disclaimerUpdatedBy,
    this.custom,
  });
}

class TrackPageChipGroup {
  final String title;
  final List<String> chips;

  const TrackPageChipGroup({required this.title, required this.chips});
}

class TrackCommunityRating {
  final int totalVotes;
  final String? date;
  final int masterpiece;
  final int amazing;
  final int good;
  final int bad;

  const TrackCommunityRating({
    required this.totalVotes,
    this.date,
    this.masterpiece = 0,
    this.amazing = 0,
    this.good = 0,
    this.bad = 0,
  });
}

class TrackPageSection {
  final String? title;
  final Widget Function(BuildContext context) builder;

  const TrackPageSection({this.title, required this.builder});
}

/// Result of a login attempt.
class AuthResult {
  final bool success;
  final String? error;

  const AuthResult.success() : success = true, error = null;
  const AuthResult.failure(this.error) : success = false;
}

/// What a live radio station is playing right now.
class RadioNowPlaying {
  /// Song on air, or null when unknown.
  final Track? track;

  /// When the station started the song, on the device clock. The player
  /// accounts for its stream buffer before showing progress and synced lyrics.
  /// Null if the station can't tell.
  final DateTime? startedAt;

  /// Title to show instead of the default "artist - title" composition.
  final String? displayTitle;

  const RadioNowPlaying({this.track, this.startedAt, this.displayTitle});
}

/// The abstract interface every music platform plugin must implement.
/// Deezer and SoundCloud each provide a concrete class.
///
/// Capability flags (via [capabilities]) tell the UI and download pipeline
abstract class MusicPlatform {
  // ---------------------------------------------------------------------------
  // Identity
  // ---------------------------------------------------------------------------

  /// Stable machine identifier, e.g. "deezer", "soundcloud".
  String get platformId;

  /// Human-readable display name, e.g. "Deezer", "SoundCloud".
  String get platformName;

  /// Icon to show in the platform switcher.
  IconData get platformIcon;

  /// Optional Widget to use instead of the icon font.
  Widget buildPlatformIcon({double size = 24, Color? color}) {
    return Icon(platformIcon, size: size, color: color);
  }

  /// What this platform supports.
  PlatformCapabilities get capabilities;

  /// Settings models to be rendered in the platform-specific settings screen.
  List<PlatformSetting> get settings => [];

  /// Quick access items to display on the search screen for this platform.
  List<QuickAccessItem> get searchQuickAccessItems => [];

  /// Extra entries a platform wants appended to the default context menus
  /// (track, album, artist, playlist, show). [item] is the model object the
  /// menu was opened for.
  List<Widget> getExtraMenuOptions(BuildContext context, Object item) =>
      const [];

  /// Optional platform-specific sections to append to an artist detail page.
  List<ArtistPageSection> buildArtistPageSections(
    BuildContext? context,
    Artist artist,
  ) => const [];

  /// Optional platform-specific sections to render on the track details page.
  /// If empty, the default sections from [TrackPageData] are rendered.
  List<TrackPageSection> buildTrackPageSections(
    BuildContext context,
    Track track,
    TrackPageData? data,
  ) => const [];

  /// Fetches platform-specific extended track details (bio, tags, rating, etc.).
  Future<TrackPageData?> getTrackPageData(String trackId) async => null;

  // ---------------------------------------------------------------------------
  // Auth
  // ---------------------------------------------------------------------------

  Future<bool> isLoggedIn();

  /// Authenticate using platform-specific [credentials].
  Future<AuthResult> login(Map<String, dynamic> credentials);

  Future<void> logout();

  /// Gets the currently logged in user ID, if available.
  String? get currentUserId;

  /// Gets the currently logged in user name, if available.
  String? get currentUserName;

  /// The playlist ID representing user's favorite tracks, if applicable.
  String? get favoritesPlaylistId => null;

  List<Track>? _cachedSortedFavorites;
  Sorting? _cachedSort;

  /// Drop the in-memory sorted favorites snapshot after a library mutation.
  void invalidateFavoriteTracksCache() {
    _cachedSortedFavorites = null;
    _cachedSort = null;
  }

  /// Returns all favorite tracks for the user (unpaginated).
  /// Subclasses can override this to return their full favorites list directly.
  Future<List<Track>> getAllFavoriteTracks() async {
    final favId = favoritesPlaylistId;
    if (favId != null) {
      final p = await getFullPlaylist(favId);
      return p.tracks ?? [];
    }
    return [];
  }

  /// Gets favorite tracks for the currently active user.
  /// When [sort] is active, fetches [getAllFavoriteTracks], applies [applySorting],
  /// and returns the requested page slice.
  Future<PaginatedTrackList> getFavoriteTracks({
    int start = 0,
    int limit = 100,
    Sorting? sort,
  }) async {
    final needsSort =
        sort != null && (sort.reverse || sort.type != SortType.DEFAULT);
    if (needsSort) {
      if (start == 0 ||
          _cachedSortedFavorites == null ||
          _cachedSort?.type != sort.type ||
          _cachedSort?.reverse != sort.reverse) {
        _cachedSortedFavorites =
            (await getAllFavoriteTracks()).applySorting(sort);
        _cachedSort = Sorting(
          type: sort.type,
          reverse: sort.reverse,
          sourceType: sort.sourceType,
          id: sort.id,
        );
      }
      final all = _cachedSortedFavorites!;
      return PaginatedTrackList(
        tracks: all.skip(start).take(limit).toList(),
        hasMore: all.length > start + limit,
      );
    }
    _cachedSortedFavorites = null;
    _cachedSort = null;
    final favId = favoritesPlaylistId;
    if (favId != null) {
      final tracks = await getPlaylistTracks(favId, start, nb: limit + 1);
      return PaginatedTrackList(
        tracks: tracks.take(limit).toList(),
        hasMore: tracks.length > limit,
      );
    }
    final all = await getAllFavoriteTracks();
    return PaginatedTrackList(
      tracks: all.skip(start).take(limit).toList(),
      hasMore: all.length > start + limit,
    );
  }

  /// Builds the login UI widget for this platform.
  Widget buildLoginWidget({required VoidCallback onSuccess});

  // ---------------------------------------------------------------------------
  // Search
  // ---------------------------------------------------------------------------

  Future<SearchResults> search(String query);
  Future<List<String>> searchSuggestions(String query);

  // ---------------------------------------------------------------------------
  // Content fetching
  // ---------------------------------------------------------------------------

  Future<Track> getTrack(String id);
  Future<List<Track>> getTracks(List<String> ids);
  Future<Album> getAlbum(String id);
  Future<Artist> getArtist(String id);
  Future<List<Track>> getArtistTopTracks(String artistId);

  /// Fetch a playlist.  Implementations should respect [limit] where possible.
  Future<Playlist> getPlaylist(String id, {int limit = 100});
  Future<Playlist> getFullPlaylist(String id);

  /// Fetch lyrics. Returns an error [Lyrics] if unsupported.
  Future<Lyrics> getLyrics(String trackId);

  /// Formats the search query used for third-party lyric providers.
  /// Subclasses can override this to optimize searches for their specific platform.
  String getLyricsSearchQuery(Track track) {
    final artistStr = track.artistString ?? '';
    return '${track.title} $artistStr'.trim();
  }

  String getShareUrl(String type, String id);

  // ---------------------------------------------------------------------------
  // Library (read)
  // ---------------------------------------------------------------------------

  Future<List<Playlist>> getUserPlaylists();
  Future<List<Album>> getUserAlbums();
  Future<List<Artist>> getUserArtists();
  Future<List<Show>> getUserShows();

  /// Returns a list of favourite track IDs (for quick in-memory lookup).
  Future<List<String>?> getFavoriteTrackIds();
  Future<List<String>?> getFavoritePlaylistIds();

  /// Optional signed-in listening history, newest play first.
  Future<HistoryTrackPage> getHistoryTracks({
    String? cursor,
    int limit = 50,
  }) async => const HistoryTrackPage(tracks: []);

  /// Returns the QueueSource to use when playing favorites.
  QueueSource get favoritesQueueSource => QueueSource(
    id: 'favorites_$platformId',
    text: 'Favorites',
    source: 'favorites_page',
  );

  // ---------------------------------------------------------------------------
  // Library mutations (favourites)
  // ---------------------------------------------------------------------------

  Future<void> addFavoriteTrack(String id);
  Future<void> removeFavoriteTrack(String id);
  Future<void> addFavoriteAlbum(String id);
  Future<void> removeFavoriteAlbum(String id);
  Future<void> addFavoriteArtist(String id);
  Future<void> removeFavoriteArtist(String id);

  /// Dislikes a track to improve algorithmic recommendations (Flow/Radio).
  Future<void> dislikeTrack(String id);

  // ---------------------------------------------------------------------------
  // Playlist mutations
  // ---------------------------------------------------------------------------

  Future<void> addFavoritePlaylist(String id);
  Future<void> removeFavoritePlaylist(String id);

  Future<String> createPlaylist(
    String title, {
    String description = '',
    int status = 0,
    List<String> trackIds = const [],
  });
  Future<void> updatePlaylist(
    String id,
    String title, {
    String description = '',
    int status = 0,
  });
  Future<void> deletePlaylist(String id);
  Future<void> addToPlaylist(String trackId, String playlistId);
  Future<void> removeFromPlaylist(String trackId, String playlistId);

  // ---------------------------------------------------------------------------
  // Discovery
  // ---------------------------------------------------------------------------

  Future<HomePage> getHomePage();
  Widget getHomeWidget(BuildContext context);

  Listenable? get homeQuickAccessListenable => null;
  Future<List<HomePageItem>> getPinnedHomePageItems() async => [];
  bool get supportsHomeQuickAccessEditor => false;
  void openHomeQuickAccessEditor(BuildContext context) {}
  Widget buildHomeFlowItem(BuildContext context, HomePageItem item) =>
      const SizedBox.shrink();

  /// Builds homepage rows whose presentation belongs to a platform.
  /// Return null to let the shared homepage renderer handle [item].
  Widget? buildPlatformHomeItem(BuildContext context, HomePageItem item) =>
      null;

  /// Builds custom homepage sections whose presentation belongs to a platform.
  /// Return null to let the shared homepage renderer handle [section].
  Widget? buildPlatformHomeSection(
    BuildContext context,
    HomePageSection section,
  ) => null;

  /// Handles platform-specific home section links. Return false to use the
  /// shared channel navigation fallback.
  bool handleHomeSectionNavigation(
    BuildContext context,
    String path, {
    String? title,
  }) => false;

  bool isPlayableHomeSectionPath(String path) => false;

  /// Handles platform-specific home item playback. Return false to use the
  /// shared playback behavior.
  bool handleHomeItemTap(BuildContext context, HomePageItem item) => false;

  /// Get a curated generic explore/browse page.
  Future<HomePage> getExplorePage();
  Widget getExploreWidget(BuildContext context);
  Future<HomePage> getChannel(String target);
  Future<List<Track>> getFlow({String? type});
  Future<SmartTrackList> getSmartTrackList(String id);
  Future<List<Track>> getSmartRadio(String artistId);
  Future<List<Track>> getLibraryShuffle({int start = 0});
  Future<List<Track>> getMix(String trackId);

  // ---------------------------------------------------------------------------
  // Radio
  // ---------------------------------------------------------------------------

  /// Fetches a playable direct stream URL for a live radio station.
  Future<String?> getRadioStreamUrl(String id) => Future.value(null);

  /// Fetches the currently playing track for a live radio station, or null if unknown.
  Future<Track?> getRadioNowPlaying(String id) => Future.value(null);

  /// Streams the currently playing track for a live radio station.
  Stream<Track?> getRadioNowPlayingStream(String id) => Stream.empty();

  /// Like [getRadioNowPlayingStream], but may also carry when the song started
  /// so the player can show progress and play time-synced lyrics. Platforms
  /// that only know the track don't need to override this.
  Stream<RadioNowPlaying> getRadioInfoStream(String id) =>
      getRadioNowPlayingStream(
        id,
      ).map((track) => RadioNowPlaying(track: track));

  /// Whether [getRadioInfoStream] reports when songs start, enabling progress
  /// and time-synced lyrics for this platform's radio.
  bool get supportsRadioTiming => false;

  /// Platform-specific correction applied only to the displayed radio position.
  Duration radioPositionAdjustment(String stationId) => Duration.zero;

  // ---------------------------------------------------------------------------
  // Shows / podcasts
  // ---------------------------------------------------------------------------

  Future<List<ShowEpisode>> getShowEpisodes(String showId);
  Future<PaginatedShowEpisodeList> getShowEpisodesPage(
    String showId, {
    int start = 0,
    int limit = 50,
  });

  Future<bool> isFavoriteShow(String id);
  Future<void> addFavoriteShow(String id);
  Future<void> removeFavoriteShow(String id);

  // ---------------------------------------------------------------------------
  // Streaming
  // ---------------------------------------------------------------------------

  StreamProvider getStreamProvider();

  /// A public, stable stream URL that can be played without the local proxy.
  Uri? directPlaybackUri(Track track) => null;

  /// Metadata and quality choices exposed to the generic download pipeline.
  Future<PlatformDownloadMetadata> getDownloadMetadata(String trackId);
  List<DownloadQualityOption> get availableDownloadQualities;

  // ---------------------------------------------------------------------------
  // Deep-link parsing
  // ---------------------------------------------------------------------------

  /// Returns null if the URL doesn't belong to this platform.
  Future<PlatformLinkResponse?> parseLink(String url);

  // ---------------------------------------------------------------------------
  // Listen logging
  // ---------------------------------------------------------------------------

  Future<void> logListen(
    String trackId,
    QueueSource? queue, {
    ListenLogDetails? details,
  });

  // ---------------------------------------------------------------------------
  // Discography paging
  // ---------------------------------------------------------------------------

  Future<List<Album>> getDiscographyPage(
    String artistId, {
    int start = 0,
    int nb = 50,
  });

  Future<List<Track>> getPlaylistTracks(String id, int start, {int nb = 100});

  // ---------------------------------------------------------------------------
  // Android Auto
  // ---------------------------------------------------------------------------

  /// Optional platform-specific Android Auto media items for a given screen ID.
  /// If null is returned, Android Auto uses the default capability-based resolver.
  Future<List<MediaItem>?> getAndroidAutoItems(String parentId) async => null;

  /// Optional platform-specific handler for playing an Android Auto item.
  /// Returns true if handled.
  Future<bool> playAndroidAutoItem(String id) async => false;
}

/// Detailed playback statistics and metadata for rich listen logging.
class ListenLogDetails {
  final Duration? listenDuration;
  final Duration? position;
  final Duration? trackDuration;
  final bool isPartial;
  final int seekCount;
  final int pauseCount;
  final bool? isNext;
  final bool? isShuffle;
  final String? format;
  final String? streamId;
  final String? nextTrackId;
  final String? nextTrackType;
  final DateTime? timestamp;
  final DateTime? listenTimestamp;
  final String? trackOwnerId;

  const ListenLogDetails({
    this.listenDuration,
    this.position,
    this.trackDuration,
    this.isPartial = false,
    this.seekCount = 0,
    this.pauseCount = 0,
    this.isNext,
    this.isShuffle,
    this.format,
    this.streamId,
    this.nextTrackId,
    this.nextTrackType,
    this.timestamp,
    this.listenTimestamp,
    this.trackOwnerId,
  });
}
