/// A timed lyric cue returned by YouTube Music's mobile lyrics endpoint.
class YtMusicLyricLine {
  const YtMusicLyricLine({
    required this.text,
    required this.startTime,
    required this.endTime,
    required this.id,
  });

  final String text;
  final int startTime;
  final int endTime;
  final int id;
}

/// Lyrics returned by ytmusicapi's `get_lyrics` operation.
class YtMusicLyrics {
  const YtMusicLyrics({
    required this.lyrics,
    required this.source,
    required this.hasTimestamps,
  });

  final Object lyrics;
  final String? source;
  final bool hasTimestamps;
}
