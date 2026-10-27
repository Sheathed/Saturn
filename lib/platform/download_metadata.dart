import '../api/definitions.dart';
import '../settings.dart';

/// Platform-neutral metadata used by the download pipeline.
///
/// Every field except [track] is optional so platforms can expose only the
/// metadata they actually support. The downloader applies available fields on
/// a best-effort basis.
class PlatformDownloadMetadata {
  final Track track;
  final String? title;
  final List<String>? artists;
  final String? album;
  final String? albumArtist;
  final int? trackNumber;
  final int? trackTotal;
  final int? discNumber;
  final String? releaseDate;
  final bool? explicit;
  final Duration? duration;
  final String? lyricsTrackId;
  final String? coverUrl;
  final String? mimeType;
  final String? format;
  final String? fileExtension;
  final String? genre;
  final String? label;
  final String? isrc;
  final String? upc;
  final String? bpm;
  final Contributors? contributors;
  final Map<String, String> extraTags;

  const PlatformDownloadMetadata({
    required this.track,
    this.title,
    this.artists,
    this.album,
    this.albumArtist,
    this.trackNumber,
    this.trackTotal,
    this.discNumber,
    this.releaseDate,
    this.explicit,
    this.duration,
    this.lyricsTrackId,
    this.coverUrl,
    this.mimeType,
    this.format,
    this.fileExtension,
    this.genre,
    this.label,
    this.isrc,
    this.upc,
    this.bpm,
    this.contributors,
    this.extraTags = const {},
  });

  factory PlatformDownloadMetadata.fromTrack(
    Track track, {
    int? trackTotal,
    String? genre,
    String? label,
    String? isrc,
    String? upc,
    String? bpm,
    String? mimeType,
    String? format,
    String? fileExtension,
    String? coverUrl,
    Map<String, String> extraTags = const {},
  }) {
    final navigableArtists = track.navigableArtists
        ?.map((artist) => artist.name)
        .whereType<String>()
        .toList();
    final trackArtists = navigableArtists?.isNotEmpty == true
        ? navigableArtists!
        : track.artists
              ?.map((artist) => artist.name)
              .whereType<String>()
              .toList();
    final albumArtist =
        track.album?.artists
            ?.map((artist) => artist.name)
            .whereType<String>()
            .firstOrNull ??
        (trackArtists?.isNotEmpty == true ? trackArtists!.first : null);
    return PlatformDownloadMetadata(
      track: track,
      title: track.title,
      artists: trackArtists,
      album: track.album?.title,
      albumArtist: albumArtist,
      trackNumber: track.trackNumber,
      trackTotal: trackTotal,
      discNumber: track.diskNumber,
      releaseDate: track.album?.releaseDate,
      explicit: track.explicit,
      duration: track.duration,
      lyricsTrackId: track.id,
      coverUrl: coverUrl ?? track.albumArt?.full ?? track.album?.art?.full,
      genre: genre,
      label: label,
      isrc: isrc,
      upc: upc,
      bpm: bpm,
      contributors: track.contributors,
      mimeType: mimeType,
      format: format,
      fileExtension: fileExtension,
      extraTags: extraTags,
    );
  }

  PlatformDownloadMetadata withStreamFormat({
    required String format,
    String? mimeType,
    String? fileExtension,
  }) {
    return PlatformDownloadMetadata(
      track: track,
      title: title,
      artists: artists,
      album: album,
      albumArtist: albumArtist,
      trackNumber: trackNumber,
      trackTotal: trackTotal,
      discNumber: discNumber,
      releaseDate: releaseDate,
      explicit: explicit,
      duration: duration,
      lyricsTrackId: lyricsTrackId,
      coverUrl: coverUrl,
      mimeType: mimeType ?? this.mimeType,
      format: format,
      fileExtension: fileExtension ?? this.fileExtension,
      genre: genre,
      label: label,
      isrc: isrc,
      upc: upc,
      bpm: bpm,
      contributors: contributors,
      extraTags: extraTags,
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

class DownloadQualityOption {
  final AudioQuality quality;
  final String label;

  const DownloadQualityOption(this.quality, this.label);
}
