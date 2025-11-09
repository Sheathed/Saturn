import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:metatagger/metatagger.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';

import '../api/deezer.dart';
import '../api/download_isolate.dart';
import '../api/download_log.dart';
import '../api/definitions.dart';
import '../settings.dart';

class DownloadServiceDart {
  static final DownloadServiceDart _instance = DownloadServiceDart._internal();
  factory DownloadServiceDart() => _instance;
  DownloadServiceDart._internal();

  bool running = false;
  int queueSize = 0;

  final List<DownloadTask> _downloads = [];
  final List<DownloadThread> _threads = [];
  final StreamController<Map<String, dynamic>> _serviceEvents =
      StreamController.broadcast();

  Database? _db;
  DownloadLog? _logger;
  DeezerAPI? _deezer;
  final List<DownloadIsolateManager> _isolates = [];
  Timer? _progressUpdateTimer;

  int get maxThreads => settings.downloadThreads;

  Stream<Map<String, dynamic>> get serviceEvents => _serviceEvents.stream;

  /// Initialize the download service
  Future<void> init(Database db) async {
    _db = db;
    _logger = DownloadLog();
    await _logger!.open();

    _deezer = DeezerAPI(arl: settings.arl);
    await _deezer!.authorize();

    // Initialize isolates for parallel downloads
    for (int i = 0; i < maxThreads; i++) {
      final isolate = DownloadIsolateManager();
      await isolate.start();
      _isolates.add(isolate);
    }

    _createProgressUpdateTimer();
  }

  void _createProgressUpdateTimer() {
    _progressUpdateTimer?.cancel();
    _progressUpdateTimer = Timer.periodic(const Duration(milliseconds: 500), (
      timer,
    ) {
      if (running && _threads.isNotEmpty) {
        _updateProgress();
      }
    });
  }

  /// Start/Resume downloads
  Future<void> start() async {
    running = true;
    await _loadDownloads();
    _updateQueue();
    _updateState();
  }

  /// Stop/Pause downloads
  Future<void> stop() async {
    running = false;
    for (var thread in _threads) {
      thread.stop();
    }
    // Stop all isolates
    for (var isolate in _isolates) {
      await isolate.stop();
    }
    _isolates.clear();
    _updateState();
  }

  /// Load downloads from database
  Future<void> _loadDownloads() async {
    if (_db == null) return;

    final List<Map<String, dynamic>> results = await _db!.query('Downloads');

    for (var row in results) {
      final download = DownloadTask.fromSQL(row);

      // Check for duplicates
      bool exists = _downloads.any((d) => d.id == download.id);
      if (!exists) {
        _downloads.add(download);
      }
    }

    _updateState();
  }

  /// Get all downloads
  List<Map<String, dynamic>> getDownloads() {
    return _downloads.map((d) => d.toMap()).toList();
  }

  /// Add downloads to queue
  Future<void> addDownloads(List<Map<dynamic, dynamic>> downloads) async {
    if (_db == null) return;

    for (var downloadData in downloads) {
      // Check if exists
      final existing = await _db!.query(
        'Downloads',
        where: 'trackId = ? AND path = ?',
        whereArgs: [downloadData['trackId'], downloadData['path']],
      );

      if (existing.isNotEmpty) {
        // Update state to NONE if done or error
        final state = existing[0]['state'] as int;
        if (state >= 3) {
          await _db!.update(
            'Downloads',
            {'state': 0},
            where: 'id = ?',
            whereArgs: [existing[0]['id']],
          );
        }
        continue;
      }

      // Insert new download
      await _db!.insert('Downloads', {
        'path': downloadData['path'],
        'private': downloadData['private'] ? 1 : 0,
        'state': 0,
        'trackId': downloadData['trackId'],
        'md5origin': downloadData['md5origin'],
        'mediaVersion': downloadData['mediaVersion'],
        'title': downloadData['title'],
        'image': downloadData['image'],
        'quality': downloadData['quality'],
        'trackToken': downloadData['trackToken'],
        'streamTrackId': downloadData['streamTrackId'],
      });
    }

    await _loadDownloads();
  }

  /// Remove download
  Future<void> removeDownload(int id) async {
    if (_db == null) return;

    _downloads.removeWhere((d) => d.id == id);
    await _db!.delete('Downloads', where: 'id = ?', whereArgs: [id]);
    _updateState();
  }

  /// Retry failed downloads
  Future<void> retryDownloads() async {
    if (_db == null) return;

    for (var download in _downloads) {
      if (download.state == DownloadStateDart.DEEZER_ERROR ||
          download.state == DownloadStateDart.ERROR) {
        download.state = DownloadStateDart.NONE;
        await _db!.update(
          'Downloads',
          {'state': 0},
          where: 'id = ?',
          whereArgs: [download.id],
        );
      }
    }
    _updateState();
  }

  /// Remove downloads by state
  Future<void> removeDownloads(DownloadStateDart state) async {
    if (_db == null) return;
    if (state == DownloadStateDart.DOWNLOADING ||
        state == DownloadStateDart.POST) {
      return;
    }

    _downloads.removeWhere((d) => d.state == state);
    await _db!.delete(
      'Downloads',
      where: 'state = ?',
      whereArgs: [state.index],
    );
    _updateState();
  }

  /// Wrapper to prevent threads racing
  bool _updating = false;
  final List<bool> _updateRequests = [];

  Future<void> _updateQueueWrapper() async {
    _updateRequests.add(true);
    if (_updating) return;
    _updating = true;

    while (_updateRequests.isNotEmpty) {
      _updateRequests.clear();
      await _updateQueue();
    }

    _updating = false;
  }

  /// Update queue and start new downloads
  Future<void> _updateQueue() async {
    await _db?.execute('BEGIN TRANSACTION');

    try {
      // Clear downloaded tracks (iterate backwards)
      for (int i = _threads.length - 1; i >= 0; i--) {
        final thread = _threads[i];
        final state = thread.download.state;

        if (state == DownloadStateDart.NONE ||
            state == DownloadStateDart.DONE ||
            state == DownloadStateDart.ERROR ||
            state == DownloadStateDart.DEEZER_ERROR) {
          final d = thread.download;

          // Update in queue
          final index = _downloads.indexWhere((dl) => dl.id == d.id);
          if (index != -1) {
            _downloads[index] = d;
          }

          _updateProgress();

          // Save to DB
          await _db?.update(
            'Downloads',
            {'state': state.index, 'quality': d.quality},
            where: 'id = ?',
            whereArgs: [d.id],
          );

          // Log completion/error
          if (state == DownloadStateDart.DONE) {
            _logger?.log('Download completed: ${d.title}');
            _serviceEvents.add({
              'action': 'onDownloadComplete',
              'id': d.id,
              'trackId': d.trackId,
            });
          } else if (state == DownloadStateDart.ERROR ||
              state == DownloadStateDart.DEEZER_ERROR) {
            _logger?.error(
              'Download failed with state: $state',
              DownloadInfo(trackId: d.trackId, id: d.id),
            );
            _serviceEvents.add({
              'action': 'onDownloadError',
              'id': d.id,
              'trackId': d.trackId,
              'state': state.index,
            });
          }

          // Remove thread
          _threads.removeAt(i);
        }
      }

      await _db?.execute('COMMIT');
    } catch (e) {
      await _db?.execute('ROLLBACK');
      _logger?.error('Error in updateQueue: $e');
    }

    // Start new downloads
    if (running) {
      // Ensure we have enough isolates
      if (_isolates.length < maxThreads) {
        await _adjustIsolateCount();
      }

      final availableSlots = maxThreads - _threads.length;

      for (var i = 0; i < availableSlots; i++) {
        final download = _downloads.firstWhere(
          (d) => d.state == DownloadStateDart.NONE,
          orElse: () => DownloadTask(
            id: -1,
            path: '',
            private: false,
            quality: 0,
            state: DownloadStateDart.NONE,
            trackId: '',
            md5origin: '',
            mediaVersion: '',
            title: '',
            image: '',
            trackToken: '',
            streamTrackId: '',
          ),
        );

        if (download.id == -1) break;

        // Safety check: ensure we have isolates
        if (_isolates.isEmpty) {
          _logger?.error('No isolates available for download');
          break;
        }

        download.state = DownloadStateDart.DOWNLOADING;
        // Get an available isolate (round-robin)
        final isolate = _isolates[_threads.length % _isolates.length];
        final thread = DownloadThread(download, _deezer!, _logger!, isolate);
        thread.start(() => _onThreadComplete(thread));
        _threads.add(thread);
      }

      if (_threads.isEmpty) {
        running = false;
      }
    }

    _updateProgress();
    _updateState();
  }

  Future<void> _onThreadComplete(DownloadThread thread) async {
    await _updateQueueWrapper();
  }

  void _updateState() {
    queueSize = _downloads
        .where((d) => d.state == DownloadStateDart.NONE)
        .length;

    _serviceEvents.add({
      'action': 'onStateChange',
      'running': running,
      'queueSize': queueSize,
    });
  }

  /// Send progress update event
  void _updateProgress() {
    if (_threads.isEmpty) return;

    final downloads = _threads
        .map(
          (thread) => {
            'id': thread.download.id,
            'received': thread.download.received,
            'filesize': thread.download.filesize,
            'quality': thread.download.quality,
            'state': thread.download.state.index,
          },
        )
        .toList();

    _serviceEvents.add({'action': 'onProgress', 'data': downloads});
  }

  /// Update settings
  Future<void> updateSettings(Map<String, dynamic> settingsJson) async {
    // Note: downloadThreads is now read directly from settings.downloadThreads
    // If thread count changed, we need to adjust isolates
    if (settingsJson.containsKey('downloadThreads')) {
      await _adjustIsolateCount();
    }
    if (settingsJson.containsKey('arl')) {
      _deezer?.arl = settingsJson['arl'];
    }
  }

  /// Adjust isolate count to match settings
  Future<void> _adjustIsolateCount() async {
    final targetCount = maxThreads;
    final currentCount = _isolates.length;

    if (targetCount > currentCount) {
      // Add more isolates
      for (int i = currentCount; i < targetCount; i++) {
        final isolate = DownloadIsolateManager();
        await isolate.start();
        _isolates.add(isolate);
      }
    } else if (targetCount < currentCount) {
      // Remove excess isolates
      for (int i = currentCount - 1; i >= targetCount; i--) {
        await _isolates[i].stop();
        _isolates.removeAt(i);
      }
    }
  }

  Future<void> dispose() async {
    await stop();
    _progressUpdateTimer?.cancel();
    await _logger?.close();
    await _serviceEvents.close();
  }
}

/// Download task model
class DownloadTask {
  int id;
  String path;
  bool private;
  int quality;
  String trackId;
  String streamTrackId;
  String trackToken;
  String md5origin;
  String mediaVersion;
  DownloadStateDart state;
  String title;
  String image;

  // Dynamic
  int received = 0;
  int filesize = 0;

  DownloadTask({
    required this.id,
    required this.path,
    required this.private,
    required this.quality,
    required this.state,
    required this.trackId,
    required this.md5origin,
    required this.mediaVersion,
    required this.title,
    required this.image,
    required this.trackToken,
    required this.streamTrackId,
  });

  factory DownloadTask.fromSQL(Map<String, dynamic> row) {
    return DownloadTask(
      id: row['id'],
      path: row['path'],
      private: row['private'] == 1,
      quality: row['quality'],
      state: DownloadStateDart.values[row['state']],
      trackId: row['trackId'],
      md5origin: row['md5origin'],
      mediaVersion: row['mediaVersion'],
      title: row['title'],
      image: row['image'],
      trackToken: row['trackToken'],
      streamTrackId: row['streamTrackId'],
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'path': path,
      'private': private,
      'quality': quality,
      'trackId': trackId,
      'state': state.index,
      'title': title,
      'image': image,
    };
  }

  bool get isUserUploaded => trackId.startsWith('-');
}

/// Download thread
class DownloadThread {
  final DownloadTask download;
  final DeezerAPI deezer;
  final DownloadLog logger;
  final DownloadIsolateManager isolate;
  final tagger = MetaTagger();

  bool _stopDownload = false;

  DownloadThread(this.download, this.deezer, this.logger, this.isolate);

  void stop() {
    _stopDownload = true;
  }

  Future<void> start(Function onComplete) async {
    download.state = DownloadStateDart.DOWNLOADING;

    try {
      await _downloadTrack();
    } catch (e) {
      logger.error(
        'Download error: $e',
        DownloadInfo(trackId: download.trackId, id: download.id),
      );
      download.state = DownloadStateDart.ERROR;
    } finally {
      onComplete();
    }
  }

  Future<void> _downloadTrack() async {
    // Fetch track and album metadata
    Track? track;
    Album? album;
    if (!download.private) {
      try {
        track = await deezer.track(download.trackId);
        if (track.album?.id != null) {
          album = await deezer.album(track.album!.id!);
        }
      } catch (e) {
        logger.error(
          'Unable to fetch track and album metadata! $e',
          DownloadInfo(trackId: download.trackId, id: download.id),
        );
        download.state = DownloadStateDart.ERROR;
        return;
      }
    }

    // Get track URL
    final url = await _getTrackUrl(
      download.streamTrackId,
      download.trackToken,
      download.md5origin,
      download.mediaVersion,
      download.quality,
    );
    if (url == null) {
      download.state = DownloadStateDart.DEEZER_ERROR;
      return;
    }

    // Generate proper filename with metadata
    File outFile;
    if (!download.private && track != null) {
      try {
        final generatedPath = _generateFilename(
          download.path,
          track,
          album,
          download.quality,
        );
        outFile = File(generatedPath);
      } catch (e) {
        logger.error(
          'Error generating track filename: $e',
          DownloadInfo(trackId: download.trackId, id: download.id),
        );
        download.state = DownloadStateDart.ERROR;
        return;
      }
    } else {
      outFile = File(download.path);
    }

    // Check if file exists and overwrite setting
    if (await outFile.exists()) {
      if (settings.overwriteDownload) {
        await outFile.delete();
      } else {
        download.state = DownloadStateDart.DONE;
        return;
      }
    }

    // Get cache directory for temp file
    Directory? directory;
    if (Platform.isAndroid || Platform.isIOS) {
      directory = await getExternalStorageDirectory();
    } else {
      directory = await getDownloadsDirectory();
    }

    if (directory == null) {
      download.state = DownloadStateDart.ERROR;
      return;
    }

    final tmpFile = File(p.join(directory.path, 'cache', '${download.id}.ENC'));
    await tmpFile.parent.create(recursive: true);

    // Download file
    final success = await _downloadFile(url, tmpFile);
    if (!success) return;

    // Decrypt if needed
    File finalFile = tmpFile;
    if (url.contains('dzcdn.net')) {
      final decFile = File('${tmpFile.path}.DEC');
      await _decryptFile(tmpFile, decFile);
      await tmpFile.delete();
      finalFile = decFile;
    }

    // Create output directory
    await outFile.parent.create(recursive: true);

    // Move to final location using isolate
    final response = await isolate.moveFile(
      finalFile.path,
      outFile.path,
      deleteSource: true,
    );

    if (!response.success) {
      logger.error(
        'File move error: ${response.error}',
        DownloadInfo(trackId: download.trackId, id: download.id),
      );
      download.state = DownloadStateDart.ERROR;
      return;
    }

    // Cover & Tags for non-private downloads
    if (!download.private && track != null) {
      // Download cover art
      await _downloadCoverArt(outFile, track);

      // Download LRC lyrics if enabled
      if (settings.downloadLyrics) {
        await _downloadLrcLyrics(outFile, track);
      }

      // Tag file with metadata
      await _tagFile(outFile, track);
    }

    download.state = DownloadStateDart.DONE;
  }

  /// Get track URL - tries modern API first, falls back to legacy
  Future<String?> _getTrackUrl(
    String trackId,
    String trackToken,
    String md5origin,
    String mediaVersion,
    int quality,
  ) async {
    try {
      // Try modern API with license token first
      if (deezer.licenseToken != null &&
          deezer.licenseToken!.isNotEmpty == true) {
        final url = await _getTrackUrlFromAPI(trackId, trackToken, quality);
        if (url != null && url.isNotEmpty) {
          return url;
        }
      }
      return null;
    } catch (e) {
      logger.log('Error getting track URL: $e');
      return null;
    }
  }

  /// Get track URL from Deezer API (modern method)
  Future<String?> _getTrackUrlFromAPI(
    String trackId,
    String trackToken,
    int quality,
  ) async {
    try {
      String format = 'FLAC';
      if (quality == 3) format = 'MP3_320';
      if (quality == 1) format = 'MP3_128';
      if (trackId.startsWith('-')) format = 'MP3_MISC';

      final payload = {
        'license_token': deezer.licenseToken,
        'media': [
          {
            'type': 'FULL',
            'formats': [
              {'cipher': 'BF_CBC_STRIPE', 'format': format},
            ],
          },
        ],
        'track_tokens': [trackToken],
      };

      // Make POST request to Deezer media API
      final headers = {
        'Content-Type': 'application/json',
        'Cookie': 'arl=${deezer.arl}',
      };

      final response = await http.post(
        Uri.parse('https://media.deezer.com/v1/get_url'),
        headers: headers,
        body: jsonEncode(payload),
      );

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body);
        if (body['data'] != null) {
          final data = body['data'] as List;
          for (var item in data) {
            if (item['media'] != null && (item['media'] as List).isNotEmpty) {
              final media = item['media'][0];
              if (media['sources'] != null &&
                  (media['sources'] as List).isNotEmpty) {
                final url = media['sources'][0]['url'];
                logger.log('Got track URL from API: $url');
                return url;
              }
            }
          }
        }
      } else {
        logger.log(
          'API returned status ${response.statusCode}: ${response.body}',
        );
      }
    } catch (e) {
      logger.log('Error getting track URL from API: $e');
    }
    return null;
  }

  Future<bool> _downloadFile(String url, File outputFile) async {
    try {
      // Check if download was stopped before starting
      if (_stopDownload) {
        download.state = DownloadStateDart.NONE;
        return false;
      }

      // Use isolate for file download
      final response = await isolate.downloadFile(
        url,
        outputFile.path,
        onProgress: (received, total) {
          if (_stopDownload) return;
          download.filesize = total;
          download.received = received;
        },
      );

      // Check if download was stopped during download
      if (_stopDownload) {
        download.state = DownloadStateDart.NONE;
        return false;
      }

      if (!response.success) {
        logger.error(
          'Download error: ${response.error}',
          DownloadInfo(trackId: download.trackId, id: download.id),
        );
        return false;
      }

      return true;
    } catch (e) {
      logger.error(
        'Download error: $e',
        DownloadInfo(trackId: download.trackId, id: download.id),
      );
      return false;
    }
  }

  Future<void> _decryptFile(File inputFile, File outputFile) async {
    try {
      // Use isolate for file decryption
      final response = await isolate.decryptFile(
        download.streamTrackId,
        inputFile.path,
        outputFile.path,
      );

      if (!response.success) {
        logger.error(
          'Decryption error: ${response.error}',
          DownloadInfo(trackId: download.trackId, id: download.id),
        );
      }
    } catch (e) {
      logger.error(
        'Decryption error: $e',
        DownloadInfo(trackId: download.trackId, id: download.id),
      );
    }
  }

  /// Generate filename with metadata placeholders
  String _generateFilename(
    String original,
    Track track,
    Album? album,
    int quality,
  ) {
    String result = original;

    // Basic replacements
    result = result.replaceAll('%title%', _sanitize(track.title ?? ''));
    result = result.replaceAll('%album%', _sanitize(track.album?.title ?? ''));
    result = result.replaceAll(
      '%artist%',
      _sanitize(track.artists?.first.name ?? ''),
    );

    // Album artist
    if (album != null && album.artists != null && album.artists!.isNotEmpty) {
      result = result.replaceAll(
        '%albumArtist%',
        _sanitize(album.artists!.first.name ?? ''),
      );
    } else {
      result = result.replaceAll(
        '%albumArtist%',
        _sanitize(track.artists?.first.name ?? ''),
      );
    }

    // Artists
    if (track.artists != null && track.artists!.isNotEmpty) {
      final artists = track.artists!.map((a) => a.name).join(', ');
      result = result.replaceAll('%artists%', _sanitize(artists));

      // Feats (all artists except first)
      if (track.artists!.length > 1) {
        final feats = track.artists!.skip(1).map((a) => a.name).join(', ');
        result = result.replaceAll('%feats%', _sanitize(feats));
      } else {
        result = result.replaceAll('%feats%', '');
      }
    }

    // Track number
    final trackNumber = track.trackNumber ?? 1;
    result = result.replaceAll('%trackNumber%', trackNumber.toString());
    result = result.replaceAll(
      '%0trackNumber%',
      trackNumber.toString().padLeft(2, '0'),
    );

    // Year and date
    if (track.album?.releaseDate != null) {
      result = result.replaceAll(
        '%year%',
        track.album!.releaseDate!.substring(0, 4),
      );
      result = result.replaceAll('%date%', track.album!.releaseDate!);
    }

    // Remove leading dots
    result = result.replaceAll(RegExp(r'/\.+'), '/');

    // Add extension
    if (quality == 9) {
      return '$result.flac';
    }
    return '$result.mp3';
  }

  String _sanitize(String input) {
    return input
        .replaceAll(RegExp(r'[\\/?*:%<>|"]'), '')
        .replaceAll('\$', '\\\$');
  }

  Future<void> _downloadCoverArt(File audioFile, Track track) async {
    try {
      // Generate cover filename
      final coverPath =
          audioFile.path.substring(0, audioFile.path.lastIndexOf('.')) + '.jpg';
      final coverFile = File(coverPath);

      // Get cover URL
      final coverUrl = track.albumArt?.full ?? track.album?.art?.full;
      if (coverUrl == null) return;

      // Download cover
      final response = await http.get(Uri.parse(coverUrl));
      if (response.statusCode == 200) {
        await coverFile.writeAsBytes(response.bodyBytes);
      }
    } catch (e) {
      logger.error(
        'Error downloading cover! $e',
        DownloadInfo(trackId: download.trackId, id: download.id),
      );
    }
  }

  /// Download LRC lyrics file
  Future<void> _downloadLrcLyrics(File audioFile, Track track) async {
    try {
      // Check if track has synced lyrics
      if (track.lyrics == null ||
          track.lyrics!.syncedLyrics == null ||
          track.lyrics!.syncedLyrics!.isEmpty) {
        logger.log('No synced lyrics for track, skipping lyrics file');
        return;
      }

      // Generate LRC filename
      final lrcPath =
          audioFile.path.substring(0, audioFile.path.lastIndexOf('.')) + '.lrc';
      final lrcFile = File(lrcPath);

      // Generate LRC content
      final lrcData = _generateLRC(track);

      // Write to file
      await lrcFile.writeAsString(lrcData);

      logger.log('Downloaded LRC lyrics: ${lrcFile.path}');
    } catch (e) {
      logger.error(
        'Error downloading lyrics! $e',
        DownloadInfo(trackId: download.trackId, id: download.id),
      );
    }
  }

  /// Generate LRC format from lyrics data
  String _generateLRC(Track track) {
    final output = StringBuffer();

    // Write metadata
    if (track.artists != null && track.artists!.isNotEmpty) {
      final artists = track.artists!.map((a) => a.name).join(', ');
      output.write('[ar:$artists]\r\n');
    }

    if (track.album?.title != null) {
      output.write('[al:${track.album!.title}]\r\n');
    }

    if (track.title != null) {
      output.write('[ti:${track.title}]\r\n');
    }

    // Write synced lyrics
    if (track.lyrics?.syncedLyrics != null) {
      for (var lyric in track.lyrics!.syncedLyrics!) {
        if (lyric.lrcTimestamp != null && lyric.text != null) {
          output.write('[${lyric.lrcTimestamp}]${lyric.text}\r\n');
        }
      }
    }

    return output.toString();
  }

  /// Tag file with metadata
  Future<void> _tagFile(File audioFile, Track track) async {
    try {
      List<MetadataTag> tags = [];
      Map<dynamic, dynamic> publicAlbum = await deezer.callPublicApi(
        '/album/${track.album?.id}',
      );
      Map<dynamic, dynamic> publicTrack = await deezer.callPublicApi(
        '/track/${track.album?.id}',
      );

      // Title
      if (settings.tags.contains('title') && track.title != null) {
        tags.add(MetadataTag.text(CommonTags.title, track.title!));
      }
      // Album
      if (settings.tags.contains('album') && track.album!.title != null) {
        tags.add(MetadataTag.text(CommonTags.album, track.album!.title!));
      }

      // Artists
      if (settings.tags.contains('artist') &&
          track.artists != null &&
          track.artists!.isNotEmpty) {
        tags.add(
          MetadataTag.text(
            CommonTags.artist,
            track.artists!.map((a) => a.name).join(settings.artistSeparator),
          ),
        );
      }

      // Album artist
      if (settings.tags.contains('albumArtist') &&
          track.album != null &&
          track.album!.artists != null &&
          track.album!.artists!.isNotEmpty) {
        tags.add(
          MetadataTag.text(
            CommonTags.albumArtist,
            track.album!.artists!.first.name!,
          ),
        );
      }

      // Track number
      if (settings.tags.contains('track')) {
        tags.add(
          MetadataTag.text(CommonTags.track, track.trackNumber.toString()),
        );
      }

      // Disc number
      if (settings.tags.contains('disc')) {
        tags.add(
          MetadataTag.text(CommonTags.disc, track.diskNumber.toString()),
        );
      }

      // Track total
      if (settings.tags.contains('trackTotal') &&
          track.album != null &&
          track.album!.tracks != null) {
        tags.add(
          MetadataTag.text(
            CommonTags.trackTotal,
            track.album!.tracks!.length.toString(),
          ),
        );
      }

      // Date
      if (settings.tags.contains('date') && track.album?.releaseDate != null) {
        tags.add(MetadataTag.text(CommonTags.date, track.album!.releaseDate!));
      }

      // Genre
      int genreId = publicAlbum['genre_id'];
      if (settings.tags.contains('genre') &&
          publicAlbum['genres'][genreId] != null) {
        tags.add(
          MetadataTag.text(
            CommonTags.genre,
            publicAlbum['genres'][genreId]['name'],
          ),
        );
      }

      // BPM
      if (settings.tags.contains('bpm') && publicTrack['bpm'] != null) {
        tags.add(
          MetadataTag.text(CommonTags.bpm, publicTrack['bpm'].toString()),
        );
      }

      // Label
      if (settings.tags.contains('label') && publicAlbum['label'] != null) {
        tags.add(
          MetadataTag(key: CommonTags.label, value: publicAlbum['label']),
        );
      }

      // ISRC
      if (settings.tags.contains('isrc') && publicTrack['isrc'] != null) {
        tags.add(MetadataTag(key: CommonTags.isrc, value: publicTrack['isrc']));
      }

      // UPC
      if (settings.tags.contains('upc') && publicAlbum['upc'] != null) {
        tags.add(
          MetadataTag(key: CommonTags.barcode, value: publicAlbum['upc']),
        );
      }

      // Lyrics
      if (settings.tags.contains('lyrics') &&
          track.lyrics != null &&
          track.lyrics!.unsyncedLyrics != null) {
        tags.add(
          MetadataTag.text(CommonTags.lyrics, track.lyrics!.unsyncedLyrics!),
        );
      }

      // Cover art
      if (settings.tags.contains('art')) {
        final coverPath =
            '${audioFile.path.substring(0, audioFile.path.lastIndexOf('.'))}.jpg';
        final coverFile = await File(coverPath).readAsBytes();
        tags.add(MetadataTag.binary(CommonTags.albumArt, coverFile));
      }

      // Write metadata
      await tagger.writeTags(audioFile.path, tags);

      logger.log('Tagged file: ${audioFile.path}');
    } catch (e, stackTrace) {
      logger.error(
        'Tagging error! $e',
        DownloadInfo(trackId: download.trackId, id: download.id),
      );
      logger.error(stackTrace.toString());
    }
  }
}

enum DownloadStateDart { NONE, DOWNLOADING, POST, DONE, DEEZER_ERROR, ERROR }
