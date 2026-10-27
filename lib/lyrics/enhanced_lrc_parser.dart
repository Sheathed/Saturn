import '../api/definitions.dart';

/// Parses Enhanced LRC format (word-level timestamps) into SynchronizedLyric objects.
///
/// Enhanced LRC format:
///   [MM:SS.CC]<MM:SS.CC>word1<MM:SS.CC>word2<MM:SS.CC>
///
/// The first [MM:SS.CC] is the line start time.
/// Each <MM:SS.CC> marks the start of the next word (or end of the last word).
class EnhancedLrcParser {
  static final _lineRegex = RegExp(r'^\[(\d+):(\d+(?:\.\d+)?)\](.*)$');
  static final _wordTimestampRegex = RegExp(r'<(\d+):(\d+(?:\.\d+)?)>');

  /// Parse an Enhanced LRC string into a list of SynchronizedLyric with word-level timing.
  static List<SynchronizedLyric> parse(String lrc) {
    final List<SynchronizedLyric> result = [];
    final lines = lrc.split('\n');

    for (var line in lines) {
      line = line.trim();
      if (line.isEmpty) continue;

      // Skip metadata lines like [ar:Artist]
      if (line.startsWith('[') && RegExp(r'^\[[a-zA-Z]').hasMatch(line)) {
        continue;
      }

      final lineMatch = _lineRegex.firstMatch(line);
      if (lineMatch == null) continue;

      final body = lineMatch.group(3)!.trim();

      // Detect and skip explicit instrumental lines so the gap timer takes over
      if (RegExp(
        r'^[\(\[【]?\s*instrumental(?:\s+break)?\s*[\)\]】]?$',
        caseSensitive: false,
      ).hasMatch(body)) {
        continue;
      }

      // Filter out Chinese fluff headers like 作词 (Lyricist), 作曲 (Composer), 编曲 (Arranger), etc.
      if (RegExp(
        r'^(作词|作曲|编曲|制作人|出品|后期|混音|母带|吉他|贝斯|鼓|和声|录音|混音|监制|OP|SP)\s*[:：]',
      ).hasMatch(body)) {
        continue;
      }

      final lineMinutes = int.parse(lineMatch.group(1)!);
      final lineSeconds = double.parse(lineMatch.group(2)!);
      final lineOffsetMs = (lineMinutes * 60 * 1000 + lineSeconds * 1000)
          .toInt();

      // Check if this line has word-level timestamps
      final wordMatches = _wordTimestampRegex.allMatches(body).toList();

      if (wordMatches.isEmpty) {
        // Standard LRC line — no word-level timing
        result.add(
          SynchronizedLyric(
            offset: Duration(milliseconds: lineOffsetMs),
            text: body.trim(),
          ),
        );
        continue;
      }

      // Enhanced LRC — parse word-level timestamps:
      // Format: <00:05.23>Hello <00:05.50>World<00:06.00>
      final List<LyricWord> words = [];
      final List<int> timestamps = [];

      for (int i = 0; i < wordMatches.length; i++) {
        final mins = int.parse(wordMatches[i].group(1)!);
        final secs = double.parse(wordMatches[i].group(2)!);
        final offsetMs = (mins * 60 * 1000 + secs * 1000).toInt();
        timestamps.add(offsetMs);
      }

      // Split by timestamps
      final parts = body.split(_wordTimestampRegex);

      for (int i = 0; i < timestamps.length; i++) {
        final textIdx = i + 1;
        if (textIdx < parts.length && parts[textIdx].isNotEmpty) {
          final wordOffset = timestamps[i];
          final wordDuration = (i + 1 < timestamps.length)
              ? timestamps[i + 1] - timestamps[i]
              : 1000; // default 1s for last word

          words.add(
            LyricWord(
              offset: Duration(milliseconds: wordOffset),
              duration: Duration(milliseconds: wordDuration),
              text: parts[textIdx],
            ),
          );
        }
      }

      // Build the full line text
      final fullText = words.map((w) => w.text).join('');

      if (words.isNotEmpty) {
        final lineDuration =
            words.last.offset +
            words.last.duration -
            Duration(milliseconds: lineOffsetMs);
        result.add(
          SynchronizedLyric(
            offset: Duration(milliseconds: lineOffsetMs),
            duration: lineDuration,
            text: fullText,
            words: words,
          ),
        );
      }
    }

    // Calculate durations for lines without word-level timing
    for (int i = 0; i < result.length - 1; i++) {
      result[i].duration ??= result[i + 1].offset! - result[i].offset!;
    }
    if (result.isNotEmpty) {
      result.last.duration ??= const Duration(seconds: 5);
    }

    return result;
  }
}
