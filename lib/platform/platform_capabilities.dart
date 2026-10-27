/// The UI uses these flags to conditionally show/hide features.
class PlatformCapabilities {
  /// Basic search works
  final bool supportsSearch;

  /// Lyrics fetching works
  final bool supportsLyrics;

  /// Synced/karaoke-style lyrics
  final bool supportsSyncedLyrics;

  /// Personalised radio/flow (Deezer Flow, etc.)
  final bool supportsFlow;

  /// Browse albums
  final bool supportsAlbums;

  /// Browse artists
  final bool supportsArtists;

  /// Show the separate featured-albums tab on artist pages.
  final bool supportsFeaturedArtistAlbums;

  /// Artist smart radio
  final bool supportsSmartRadio;

  /// Tracks can be downloaded for offline use
  final bool supportsDownload;

  /// Podcasts / shows
  final bool supportsShows;

  /// User can create/edit playlists on this platform
  final bool supportsPlaylistEdit;

  /// Library sync (favourites, saved albums, artists)
  final bool supportsLibrarySync;

  /// Dedicated explore/browse page
  final bool supportsExplorePage;

  /// Whether play-count logging back to the platform is supported
  final bool supportsListenLogging;

  /// The platform exposes the signed-in user's listening history.
  final bool supportsHistory;

  /// Live radio stations (livestreams with metadata polling)
  final bool supportsRadio;

  /// Label used to describe followers/fans (e.g. 'fans', 'subscribers', 'followers')
  final String audienceLabel;

  /// Whether the platform provides library items in a preserved order that should not be re-sorted
  final bool preservesLibraryOrder;

  /// Dislike tracks to tune recommendations on this platform.
  final bool supportsDislike;

  /// Dedicated individual track details page
  final bool supportsTrackPage;

  /// Show the separate singles tab on artist discography.
  final bool supportsSingles;

  const PlatformCapabilities({
    this.supportsSearch = true,
    this.supportsLyrics = false,
    this.supportsSyncedLyrics = false,
    this.supportsFlow = false,
    this.supportsAlbums = true,
    this.supportsArtists = true,
    this.supportsFeaturedArtistAlbums = true,
    this.supportsSingles = true,
    this.supportsSmartRadio = false,
    this.supportsDownload = false,
    this.supportsShows = false,
    this.supportsPlaylistEdit = false,
    this.supportsLibrarySync = false,
    this.supportsExplorePage = false,
    this.supportsListenLogging = false,
    this.supportsHistory = false,
    this.supportsRadio = false,
    this.audienceLabel = 'fans',
    this.preservesLibraryOrder = false,
    this.supportsDislike = false,
    this.supportsTrackPage = false,
  });
}
