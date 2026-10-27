import '../platform_capabilities.dart';

/// Capabilities supported by the YouTube Music platform integration.
const youtubeMusicCapabilities = PlatformCapabilities(
  supportsSearch: true,
  supportsLyrics: true,
  supportsSyncedLyrics: true,
  supportsFlow: true,
  supportsAlbums: true,
  supportsArtists: true,
  supportsFeaturedArtistAlbums: false,
  supportsSmartRadio: true,
  supportsDownload: true,
  supportsShows: true,
  supportsPlaylistEdit: true,
  supportsLibrarySync: true,
  supportsExplorePage: true,
  supportsListenLogging: true,
  supportsHistory: true,
  supportsDislike: true,
  audienceLabel: 'subscribers',
  preservesLibraryOrder: true,
);
