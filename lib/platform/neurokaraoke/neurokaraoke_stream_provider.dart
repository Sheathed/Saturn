import 'dart:io';

import '../../api/definitions.dart';
import '../../platform/stream_provider.dart';
import '../../settings.dart';
import '../../utils/format_utils.dart';

import 'neurokaraoke_api.dart';

class NeuroKaraokeStreamProvider extends StreamProvider {
  final NeuroKaraokeAPI? api;

  NeuroKaraokeStreamProvider([this.api]);

  @override
  bool shouldRetryProxyStatus(int statusCode) =>
      statusCode == HttpStatus.forbidden ||
      statusCode == HttpStatus.unauthorized;

  @override
  Future<StreamResponse> getStream(Track track, AudioQuality quality) async {
    var details = track.playbackDetails;
    if ((details == null || details.isEmpty || details[0].toString().isEmpty) &&
        api != null &&
        track.id != null &&
        track.id!.isNotEmpty) {
      try {
        final raw = await api!.getSongRaw(track.id!);
        if (raw != null) {
          final fetched = api!.mapToTrack(raw);
          track.playbackDetails = fetched.playbackDetails;
          details = track.playbackDetails;
        }
      } catch (_) {}
    }

    if (details == null || details.isEmpty || details[0].toString().isEmpty) {
      throw Exception('Track ${track.id} is missing playback details');
    }

    final url = details[0].toString();

    // The provider has already supplied this stable CDN link as track metadata.
    // Do not issue an extra HEAD request on every playback or queue preload.
    final suppliedFormat = details.length > 1 ? details[1].toString() : '';
    final extension = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    final isOpus = suppliedFormat.toLowerCase().contains('opus') ||
        extension.endsWith('.opus') ||
        extension.endsWith('.ogg');
    final format = isOpus
        ? 'OPUS'
        : (extension.endsWith('.mp3')
            ? 'MP3'
            : (suppliedFormat.isNotEmpty
                ? suppliedFormat.toUpperCase()
                : 'MP3'));
    return StreamResponse(
      url: url,
      format: format.isEmpty || format == 'ARBITRARY' ? 'MP3' : format,
      bitrate: null,
      requiresFormatProbe: true,
      requiresDecryption: false,
    );
  }

  @override
  Future<int?> resolveBitrate(Track track, AudioQuality _) async {
    var details = track.playbackDetails;
    if ((details == null || details.isEmpty || details[0].toString().isEmpty) &&
        api != null &&
        track.id != null &&
        track.id!.isNotEmpty) {
      try {
        final raw = await api!.getSongRaw(track.id!);
        if (raw != null) {
          final fetched = api!.mapToTrack(raw);
          track.playbackDetails = fetched.playbackDetails;
          details = track.playbackDetails;
        }
      } catch (_) {}
    }

    if (details != null && details.isNotEmpty) {
      final info = await FormatUtils.resolveStreamInfo(
        details.first.toString(),
        durationSeconds: track.duration?.inSeconds,
      );
      final bitrate = info['bitrate'] as int? ?? 0;
      if (bitrate > 0) return bitrate;

      final headerBitrate = await FormatUtils.resolveBitrateFromHeaders(
        details.first.toString(),
        durationSeconds: track.duration?.inSeconds,
      );
      if (headerBitrate != null && headerBitrate > 0) return headerBitrate;
    }
    return null;
  }

  @override
  Future<void> decryptFile(
    String trackId,
    String inputPath,
    String outputPath,
    Map<String, dynamic> meta,
  ) async {
    // Neuro Karaoke does not require decryption
  }
}
