import '../api/definitions.dart';

abstract class LyricsProvider {
  String get id;
  String get name;

  /// Fetches lyrics for the given track.
  Future<Lyrics> getLyrics(Track track);

  /// Returns alternate lyric records when a provider exposes multiple matches.
  /// Providers with one best match inherit this default implementation.
  Future<List<LyricsCandidate>> getLyricsCandidates(Track track) async {
    final lyrics = await getLyrics(track);
    if (!lyrics.isLoaded()) {
      return const [];
    }
    return [
      LyricsCandidate(
        id: lyrics.id ?? id,
        providerId: id,
        title: track.title ?? name,
        artist: track.artistString ?? '',
        album: track.album?.title,
        duration: track.duration,
        lyrics: lyrics,
      ),
    ];
  }
}

class LyricsCandidate {
  final String id;
  final String providerId;
  final String title;
  final String artist;
  final String? album;
  final Duration? duration;
  final bool wordSynced;
  final Lyrics lyrics;

  const LyricsCandidate({
    required this.id,
    required this.providerId,
    required this.title,
    required this.artist,
    this.album,
    this.duration,
    this.wordSynced = false,
    required this.lyrics,
  });

  String get displayTitle => '$title — $artist';
}
