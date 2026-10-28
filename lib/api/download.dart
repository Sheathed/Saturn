import '../utils/app_config.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:disk_space_2/disk_space_2.dart' as disk_space_2;
import 'package:universal_disk_space/universal_disk_space.dart';
import 'package:filesize/filesize.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../ui/toast.dart';
import '../platform/music_platform.dart';
import '../platform/platform_manager.dart';
import '../platform/platform_registry.dart';
import '../api/definitions.dart';
import '../api/local_playlist_manager.dart';
import '../utils/navigator_keys.dart';
import '../router/app_router.dart';
import '../settings.dart';
import '../translations.i18n.dart';
import '../utils/file_utils.dart';
import '../api/download_service_dart.dart';
import '../api/download_isolate.dart';
import '../api/download_log.dart';
import '../utils/logging.dart';
import '../utils/format_utils.dart';

DownloadManager downloadManager = DownloadManager();

// Shared download log instance for the download chain
DownloadLog? _downloadLog;

class DownloadManager {
  //Platform channels
  static const MethodChannel platform = MethodChannel('s.s.saturn/native');

  bool running = false;
  int queueSize = 0;

  StreamController serviceEvents = StreamController.broadcast();
  final StreamController<Track> _offlineTracksRemoved =
      StreamController<Track>.broadcast();
  Stream<Track> get offlineTracksRemoved => _offlineTracksRemoved.stream;
  final StreamController<void> _offlineLibraryChanged =
      StreamController<void>.broadcast();
  Stream<void> get offlineLibraryChanged => _offlineLibraryChanged.stream;
  String? offlinePath;
  Database? db;

  // Dart download service
  final DownloadServiceDart _downloadService = DownloadServiceDart();
  final Map<String, bool> _offlineTrackCache = {};

  // Local playlist manager
  late LocalPlaylistManager localPlaylistManager;
  bool _localPlaylistManagerInitialized = false;

  String _offlineTable(String platformId, String entity) {
    final safeId = platformId.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
    return '${safeId}_$entity';
  }

  Future<List<String>> _offlinePlatformIds() async {
    if (_initFuture != null) await _initFuture;
    if (db == null) return [];
    final rows = await db!.query('OfflinePlatforms', columns: ['platformId']);
    return rows.map((row) => row['platformId'] as String).toList();
  }

  Future<void> _createPlatformTables(
    Database database,
    String platformId,
  ) async {
    final tracks = _offlineTable(platformId, 'Tracks');
    final albums = _offlineTable(platformId, 'Albums');
    final artists = _offlineTable(platformId, 'Artists');
    final playlists = _offlineTable(platformId, 'Playlists');
    final batch = database.batch();
    batch.execute('''CREATE TABLE IF NOT EXISTS $tracks (
      id TEXT PRIMARY KEY, title TEXT, album TEXT, artists TEXT DEFAULT '',
      duration INTEGER DEFAULT 0, albumArt TEXT, trackNumber INTEGER,
      offline INTEGER DEFAULT 0, lyrics TEXT, unavailable INTEGER DEFAULT 0,
      unavailableReason TEXT,
      favorite INTEGER DEFAULT 0,
      library INTEGER DEFAULT 0, diskNumber INTEGER, explicit INTEGER DEFAULT 0,
      contributors TEXT, fallback TEXT, qualityFormat TEXT,
      qualityBitrate INTEGER, platformId TEXT NOT NULL)''');
    batch.execute('''CREATE TABLE IF NOT EXISTS $albums (
      id TEXT PRIMARY KEY, title TEXT, artists TEXT DEFAULT '', tracks TEXT DEFAULT '',
      art TEXT, fans INTEGER, offline INTEGER DEFAULT 0, library INTEGER DEFAULT 0,
      type INTEGER DEFAULT -1, releaseDate TEXT, platformId TEXT NOT NULL)''');
    batch.execute(
      '''CREATE TABLE IF NOT EXISTS $artists (
      id TEXT PRIMARY KEY, name TEXT, albums TEXT DEFAULT '', topTracks TEXT DEFAULT '',
      picture TEXT, fans INTEGER, albumCount INTEGER, offline INTEGER DEFAULT 0,
      library INTEGER DEFAULT 0, radio INTEGER DEFAULT 0, platformId TEXT NOT NULL)''',
    );
    batch.execute('''CREATE TABLE IF NOT EXISTS $playlists (
      id TEXT PRIMARY KEY, title TEXT, tracks TEXT DEFAULT '', image TEXT,
      duration INTEGER DEFAULT 0, userId TEXT, userName TEXT, fans INTEGER,
      library INTEGER DEFAULT 0, description TEXT, offline INTEGER DEFAULT 0,
      platformId TEXT NOT NULL, mosaicImages TEXT)''');
    batch.insert('OfflinePlatforms', {
      'platformId': platformId,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    await batch.commit();

    // Older databases created this table without `offline`, even though the
    // playlist insert and offline-state refresh both use that field.
    final playlistColumns = await database.rawQuery(
      'PRAGMA table_info($playlists)',
    );
    if (!playlistColumns.any((column) => column['name'] == 'offline')) {
      await database.execute(
        'ALTER TABLE $playlists ADD COLUMN offline INTEGER DEFAULT 0',
      );
    }
    if (!playlistColumns.any((column) => column['name'] == 'mosaicImages')) {
      await database.execute(
        'ALTER TABLE $playlists ADD COLUMN mosaicImages TEXT',
      );
    }
  }

  bool _isFavoritesPlaylist(Playlist playlist) {
    return playlist.id == 'favorites_${playlist.platformId}';
  }

  Future<Playlist> _loadFavoritesPlaylist(
    MusicPlatform musicPlatform,
    Playlist playlist,
  ) async {
    final tracks = <Track>[];
    if (playlist.tracks?.isNotEmpty == true) {
      tracks.addAll(playlist.tracks!);
    } else {
      var start = 0;
      const limit = 100;
      while (true) {
        final page = await musicPlatform.getFavoriteTracks(
          start: start,
          limit: limit,
        );
        tracks.addAll(page.tracks);
        if (!page.hasMore || page.tracks.isEmpty) break;
        start += page.tracks.length;
      }
    }
    for (final track in tracks) {
      track.platformId = musicPlatform.platformId;
    }
    return Playlist(
      id: playlist.id,
      title: playlist.title ?? 'Favorites',
      tracks: tracks,
      trackCount: tracks.length,
      platformId: musicPlatform.platformId,
      library: true,
    );
  }

  Future<void> _migrateLegacyOfflineTables(Database database) async {
    await _createPlatformTables(database, 'deezer');
    final legacyTables = await database.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    );
    final names = legacyTables.map((row) => row['name']).toSet();
    for (final entity in const ['Tracks', 'Albums', 'Artists', 'Playlists']) {
      if (!names.contains(entity)) continue;
      final sourceColumns = (await database.rawQuery(
        'PRAGMA table_info($entity)',
      )).map((row) => row['name'] as String).toSet();
      final targetTable = _offlineTable('deezer', entity);
      final targetColumns = (await database.rawQuery(
        'PRAGMA table_info($targetTable)',
      )).map((row) => row['name'] as String).toSet();
      final columns = sourceColumns.intersection(targetColumns).toList();
      final rows = await database.query(entity);
      for (final row in rows) {
        final values = <String, Object?>{
          for (final column in columns) column: row[column],
          'platformId': 'deezer',
        };
        await database.insert(
          targetTable,
          values,
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
    }
    for (final table in const ['Tracks', 'Albums', 'Artists', 'Playlists']) {
      if (names.contains(table)) await database.execute('DROP TABLE $table');
    }
  }

  /// Import the pre-platform database without deleting it. Older releases used
  /// `offline.db`; current releases use `offline2.db` with platform-scoped
  /// tables. Keep the source as a recovery copy and record completion in the
  /// destination so this only runs once.
  Future<void> _importLegacyOfflineDatabase(Database destination) async {
    final legacyPath = p.join(await getFlavorDatabaseDirectory(), 'offline.db');
    final legacyFile = File(legacyPath);
    if (!await legacyFile.exists()) return;

    await destination.execute('''CREATE TABLE IF NOT EXISTS SchemaMigrations (
      migrationId TEXT PRIMARY KEY)''');
    final alreadyImported = await destination.query(
      'SchemaMigrations',
      where: 'migrationId = ?',
      whereArgs: ['offline_db_to_offline2_v1'],
      limit: 1,
    );
    if (alreadyImported.isNotEmpty) return;

    Database? legacy;
    try {
      legacy = await openDatabase(legacyPath, readOnly: true);
      final sourceTables = (await legacy.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      )).map((row) => row['name'] as String).toSet();

      // Local playlists are also stored in this database and must survive the
      // database filename transition.
      await destination.execute('''CREATE TABLE IF NOT EXISTS LocalPlaylists (
        id TEXT PRIMARY KEY, title TEXT NOT NULL, description TEXT,
        trackIds TEXT, createdAt TEXT, updatedAt TEXT,
        offline INTEGER DEFAULT 0, mosaicImages TEXT)''');

      await destination.transaction((txn) async {
        Future<void> copyRows(
          String from,
          String to, {
          String? defaultPlatformId,
          bool regenerateId = false,
        }) async {
          if (!sourceTables.contains(from)) return;
          final sourceColumns = (await legacy!.rawQuery(
            'PRAGMA table_info($from)',
          )).map((row) => row['name'] as String).toSet();
          final targetColumns = (await txn.rawQuery(
            'PRAGMA table_info($to)',
          )).map((row) => row['name'] as String).toSet();
          final commonColumns = sourceColumns
              .intersection(targetColumns)
              .where((column) => !(regenerateId && column == 'id'))
              .toList();
          if (commonColumns.isEmpty) return;

          final rows = await legacy!.query(from);
          for (final row in rows) {
            final values = <String, Object?>{
              for (final column in commonColumns) column: row[column],
            };
            if (defaultPlatformId != null &&
                targetColumns.contains('platformId') &&
                values['platformId'] == null) {
              values['platformId'] = defaultPlatformId;
            }
            await txn.insert(
              to,
              values,
              conflictAlgorithm: ConflictAlgorithm.ignore,
            );
          }
        }

        for (final entity in const [
          'Tracks',
          'Albums',
          'Artists',
          'Playlists',
        ]) {
          await copyRows(
            entity,
            _offlineTable('deezer', entity),
            defaultPlatformId: 'deezer',
          );
        }
        await copyRows(
          'Downloads',
          'Downloads',
          defaultPlatformId: 'deezer',
          regenerateId: true,
        );
        await copyRows('LocalPlaylists', 'LocalPlaylists');
        await txn.insert('SchemaMigrations', {
          'migrationId': 'offline_db_to_offline2_v1',
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      });
      _downloadLog?.log(
        '[DownloadManager] Imported legacy offline.db metadata, downloads, and local playlists; original database retained',
      );
    } catch (error, stack) {
      _downloadLog?.log(
        '[DownloadManager] Legacy offline.db import failed: $error\n$stack',
      );
      rethrow;
    } finally {
      await legacy?.close();
    }
  }

  Future<void> _moveLegacyOfflineFiles(Directory sourceDirectory) async {
    if (!await sourceDirectory.exists() || offlinePath == null) return;
    final deezerDirectory = Directory(p.join(offlinePath!, 'deezer'));
    await deezerDirectory.create(recursive: true);

    // The old single-platform layout stored files directly in offline/.
    // Move those into Deezer's platform directory and update their persisted
    // download paths. Existing platform-scoped folders are left untouched.
    await for (final entity in sourceDirectory.list(followLinks: false)) {
      if (entity is! File) continue;
      final destination = File(
        p.join(deezerDirectory.path, p.basename(entity.path)),
      );
      var moved = false;
      try {
        if (!await destination.exists()) await entity.rename(destination.path);
        moved = await destination.exists();
      } on FileSystemException {
        // rename may cross filesystem boundaries when migrating from the old
        // desktop Downloads directory to Application Support.
        try {
          if (!await destination.exists()) await entity.copy(destination.path);
          moved =
              await destination.exists() &&
              await destination.length() == await entity.length();
          if (moved) await entity.delete();
        } catch (error, stack) {
          _downloadLog?.log(
            '[DownloadManager] Could not migrate offline file ${entity.path}: $error\n$stack',
          );
        }
      }
      if (moved && db != null) {
        await db!.update(
          'Downloads',
          {'path': destination.path},
          where: 'path = ?',
          whereArgs: [entity.path],
        );
      }
    }
  }

  Future<void> _migrateLegacyOfflineFiles() async {
    if (offlinePath == null) return;
    await _moveLegacyOfflineFiles(Directory(offlinePath!));

    // Desktop used Downloads/offline before switching to
    // ApplicationSupport/offline. Keep old files playable after that change.
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      final downloadsDirectory = await getDownloadsDirectory();
      if (downloadsDirectory != null) {
        final previousPath = p.join(downloadsDirectory.path, 'offline');
        if (p.normalize(previousPath) != p.normalize(offlinePath!)) {
          await _moveLegacyOfflineFiles(Directory(previousPath));
        }
      }
    }
  }

  //Start/Resume downloads
  Future start() async {
    await updateServiceSettings();
    await _downloadService.start();
  }

  //Stop/Pause downloads
  Future stop() async {
    await _downloadService.stop();
  }

  Future<void>? _initFuture;

  Future init() {
    _initFuture ??= _doInit();
    return _initFuture!;
  }

  Future _doInit() async {
    // Initialize download log early
    _downloadLog = DownloadLog();
    await _downloadLog!.open();
    _downloadLog!.log('[DownloadManager] Initializing download manager...');
    _downloadLog!.log(
      '[DownloadManager] Platform: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
    );

    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      _downloadLog!.log(
        '[DownloadManager] Initializing FFI database for desktop',
      );
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    String dbPath = p.join(await getFlavorDatabaseDirectory(), 'offline2.db');
    //Open db
    db = await openDatabase(
      dbPath,
      version: 3,
      onConfigure: (Database db) async {
        await db.rawQuery('PRAGMA busy_timeout = 10000');
        await db.rawQuery('PRAGMA journal_mode = WAL');
      },
      onCreate: (Database db, int version) async {
        await db.execute('''CREATE TABLE OfflinePlatforms (
          platformId TEXT PRIMARY KEY)''');
      },
      onUpgrade: (Database db, int oldVersion, int newVersion) async {
        if (oldVersion < 2) {
          await db.execute('''CREATE TABLE IF NOT EXISTS OfflinePlatforms (
            platformId TEXT PRIMARY KEY)''');
          await _migrateLegacyOfflineTables(db);
          try {
            await db.execute(
              "ALTER TABLE Downloads ADD COLUMN platformId TEXT DEFAULT 'deezer'",
            );
          } catch (_) {}
          await db.execute('''UPDATE Downloads SET quality = CASE quality
            WHEN 1 THEN 0 WHEN 3 THEN 1 WHEN 9 THEN 2 ELSE quality END''');
        }
        if (oldVersion < 3) {
          await _ensureUnavailableTrackColumn(db);
        }
      },
    );

    await db!.execute('''CREATE TABLE IF NOT EXISTS OfflinePlatforms (
      platformId TEXT PRIMARY KEY)''');
    // Also repair databases opened from development builds where schema
    // changes may have been made without a version bump.
    await _ensureUnavailableTrackColumn(db!);
    for (final musicPlatform in PlatformRegistry.instance.allPlatforms) {
      await _createPlatformTables(db!, musicPlatform.platformId);
    }

    //Create offline directory
    Directory? directory;
    if (Platform.isAndroid || Platform.isIOS) {
      directory = await getExternalStorageDirectory();
    } else {
      directory = await getFlavorSupportDirectory();
    }
    offlinePath = p.join(await getFlavorDatabaseDirectory(), 'offline/');
    await Directory(offlinePath!).create(recursive: true);
    if (directory != null) {
      offlinePath = p.join(directory.path, 'offline/');
      await Directory(offlinePath!).create(recursive: true);
    }
    await Directory(p.join(offlinePath!, 'deezer')).create(recursive: true);

    //Update settings
    await updateServiceSettings();

    // Create Downloads table if it doesn't exist
    await db!.execute('''CREATE TABLE IF NOT EXISTS Downloads (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      path TEXT,
      private INTEGER,
      quality INTEGER,
      platformId TEXT NOT NULL DEFAULT 'deezer',
      state INTEGER,
      trackId TEXT,
      title TEXT,
      image TEXT,
      downloaded INTEGER DEFAULT 0,
      resolvedFormat TEXT,
      resolvedBitrate INTEGER,
      unavailable INTEGER DEFAULT 0
    )''');

    // Migrate existing Downloads table to add downloaded column if missing
    try {
      await db!.execute(
        'ALTER TABLE Downloads ADD COLUMN downloaded INTEGER DEFAULT 0',
      );
    } catch (e) {
      // Column already exists, ignore error
    }
    try {
      await db!.execute(
        "ALTER TABLE Downloads ADD COLUMN platformId TEXT DEFAULT 'deezer'",
      );
    } catch (_) {}
    try {
      await db!.execute('ALTER TABLE Downloads ADD COLUMN resolvedFormat TEXT');
    } catch (_) {}
    try {
      await db!.execute(
        'ALTER TABLE Downloads ADD COLUMN resolvedBitrate INTEGER',
      );
    } catch (_) {}
    try {
      await db!.execute(
        'ALTER TABLE Downloads ADD COLUMN unavailable INTEGER DEFAULT 0',
      );
    } catch (_) {}

    // Older releases stored all offline metadata in offline.db. Import it only
    // after the platform tables and Downloads schema are ready.
    await _importLegacyOfflineDatabase(db!);
    await _migrateLegacyOfflineFiles();

    // Initialize download service (this will try to load downloads from DB)
    _downloadLog!.log('[DownloadManager] Initializing download service...');
    await _downloadService.init(db!);
    _downloadLog!.log('[DownloadManager] Download service initialized');

    // Initialize local playlist manager
    _downloadLog!.log(
      '[DownloadManager] Initializing local playlist manager...',
    );
    localPlaylistManager = LocalPlaylistManager();
    await localPlaylistManager.init(db!);
    _localPlaylistManagerInitialized = true;
    _downloadLog!.log('[DownloadManager] Local playlist manager initialized');
    _downloadLog!.log('[DownloadManager] Download manager fully initialized');

    //Listen to state change event from Dart service
    _downloadService.serviceEvents.listen((e) async {
      if (e['type'] == 'stateChange') {
        // Sync running state from service (which updates immediately)
        running = _downloadService.running;
        queueSize = e['queueSize'];
      }
      if (e['type'] == 'downloadComplete' && e['download'] is Map) {
        await _markOfflineDownloadComplete(
          Map<String, dynamic>.from(e['download'] as Map),
        );
      }
      if (e['type'] == 'downloadError' &&
          e['state'] == DownloadState.UNAVAILABLE.index &&
          e['private'] == true) {
        final platformId = e['platformId'] as String?;
        if (platformId != null) {
          await _refreshOfflineContainers(platformId);
        }
      }

      _offlineTrackCache.clear();
      //Forward
      serviceEvents.add(e);
    });
  }

  Future<void> _ensureUnavailableTrackColumn(Database database) async {
    final rows = await database.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE '%_Tracks'",
    );
    for (final row in rows) {
      final table = row['name'] as String?;
      if (table == null) continue;
      final columns = await database.rawQuery('PRAGMA table_info($table)');
      final columnNames = columns.map((column) => column['name']).toSet();
      if (!columnNames.contains('unavailable')) {
        await database.execute(
          'ALTER TABLE "$table" ADD COLUMN unavailable INTEGER DEFAULT 0',
        );
      }
      if (!columnNames.contains('unavailableReason')) {
        await database.execute(
          'ALTER TABLE "$table" ADD COLUMN unavailableReason TEXT',
        );
      }
      if (!columnNames.contains('qualityFormat')) {
        await database.execute(
          'ALTER TABLE "$table" ADD COLUMN qualityFormat TEXT',
        );
      }
      if (!columnNames.contains('qualityBitrate')) {
        await database.execute(
          'ALTER TABLE "$table" ADD COLUMN qualityBitrate INTEGER',
        );
      }
    }
  }

  Future<void> _markOfflineDownloadComplete(
    Map<String, dynamic> download,
  ) async {
    if (download['private'] != true) return;
    final platformId = download['platformId'] as String? ?? 'deezer';
    final trackId = download['trackId'] as String?;
    final path = download['path'] as String?;
    if (trackId == null || path == null || !await File(path).exists()) return;

    var qualityFormat = download['resolvedFormat'] as String?;
    var qualityBitrate = download['resolvedBitrate'];
    // Providers normally report the selected stream metadata. YouTube Music
    // can omit one or both fields, so inspect the completed local file as a
    // fallback instead of leaving offline tracks without a quality badge.
    if (platformId == 'youtube_music' ||
        qualityFormat == null ||
        qualityFormat.isEmpty ||
        qualityBitrate is! num ||
        qualityBitrate <= 0) {
      int? durationSeconds;
      final trackRows = await db!.query(
        _offlineTable(platformId, 'Tracks'),
        columns: ['duration'],
        where: 'id = ?',
        whereArgs: [trackId],
        limit: 1,
      );
      if (trackRows.isNotEmpty) {
        final duration = trackRows.first['duration'];
        if (duration is int && duration > 0) {
          durationSeconds = duration;
        }
      }
      final fileInfo = await FormatUtils.resolveStreamInfo(
        Uri.file(path).toString(),
        durationSeconds: durationSeconds,
      );
      final detectedFormat = fileInfo['format'] as String?;
      final formatDetected = fileInfo['formatDetected'] == true;
      if (detectedFormat != null &&
          formatDetected &&
          (platformId == 'youtube_music' ||
              qualityFormat == null ||
              qualityFormat.isEmpty)) {
        qualityFormat =
            platformId == 'youtube_music' &&
                (detectedFormat == 'OGG' || detectedFormat == 'WEBM')
            ? 'OPUS'
            : detectedFormat;
      }
      final detectedBitrate = fileInfo['bitrate'];
      if (detectedBitrate is num &&
          detectedBitrate > 0 &&
          (platformId == 'youtube_music' ||
              qualityBitrate is! num ||
              qualityBitrate <= 0)) {
        qualityBitrate = detectedBitrate.round();
      }
    }
    final trackValues = <String, Object?>{'offline': 1};
    if (qualityFormat != null && qualityFormat.isNotEmpty) {
      trackValues['qualityFormat'] = qualityFormat;
    }
    if (qualityBitrate is num && qualityBitrate > 0) {
      trackValues['qualityBitrate'] = qualityBitrate.round();
    }
    final lyrics = download['lyrics'];
    if (lyrics is Map<String, dynamic>) {
      trackValues['lyrics'] = jsonEncode(lyrics);
    } else if (lyrics is Map) {
      trackValues['lyrics'] = jsonEncode(Map<String, dynamic>.from(lyrics));
    }

    final updatedRows = await db!.update(
      _offlineTable(platformId, 'Tracks'),
      trackValues,
      where: 'id == ?',
      whereArgs: [trackId],
    );
    _downloadLog?.log(
      '[DownloadManager] Saved offline track metadata for $platformId:$trackId '
      '(rows=$updatedRows, lyrics=${lyrics is Map ? 'present' : 'missing'})',
    );

    await _refreshOfflineContainers(platformId);
  }

  Future<void> _refreshOfflineContainers(String platformId) async {
    _offlineTrackCache.clear();
    final tracksTable = _offlineTable(platformId, 'Tracks');
    final albumsTable = _offlineTable(platformId, 'Albums');
    final rawAlbums = await db!.query(albumsTable, columns: ['id', 'tracks']);
    for (final rawAlbum in rawAlbums) {
      final trackIds = _splitIds(rawAlbum['tracks'] as String?);
      final downloaded = await _countDownloadedTracks(
        platformId,
        tracksTable,
        trackIds,
      );
      await db!.update(
        albumsTable,
        {
          'offline': trackIds.isNotEmpty && downloaded == trackIds.length
              ? 1
              : 0,
        },
        where: 'id == ?',
        whereArgs: [rawAlbum['id']],
      );
    }

    final playlistsTable = _offlineTable(platformId, 'Playlists');
    final rawPlaylists = await db!.query(
      playlistsTable,
      columns: ['id', 'tracks'],
    );
    for (final rawPlaylist in rawPlaylists) {
      final trackIds = _splitIds(rawPlaylist['tracks'] as String?);
      final downloaded = await _countDownloadedTracks(
        platformId,
        tracksTable,
        trackIds,
      );
      await db!.update(
        playlistsTable,
        {
          'offline': trackIds.isNotEmpty && downloaded == trackIds.length
              ? 1
              : 0,
        },
        where: 'id == ?',
        whereArgs: [rawPlaylist['id']],
      );
    }

    // Process local playlists
    if (_localPlaylistManagerInitialized && localPlaylistManager.db != null) {
      final localPlaylists = await localPlaylistManager.getAllPlaylists();
      for (final lp in localPlaylists) {
        if (lp.trackIds.isEmpty) {
          await localPlaylistManager.updatePlaylist(
            lp.copyWith(offline: false),
          );
          continue;
        }
        int downloaded = 0;
        for (final idStr in lp.trackIds) {
          String pId = 'deezer';
          String tId = idStr;
          if (idStr.contains(':')) {
            final parts = idStr.split(':');
            pId = parts[0];
            tId = parts.sublist(1).join(':');
          }
          final tTable = _offlineTable(pId, 'Tracks');
          if (await _countDownloadedTracks(pId, tTable, [tId]) > 0) {
            downloaded++;
          }
        }
        await localPlaylistManager.updatePlaylist(
          lp.copyWith(offline: downloaded == lp.trackIds.length),
        );
      }
    }
  }

  List<String> _splitIds(String? value) =>
      (value ?? '').split(',').where((id) => id.isNotEmpty).toList();

  Future<int> _countDownloadedTracks(
    String platformId,
    String tracksTable,
    List<String> ids,
  ) async {
    var count = 0;
    for (final id in ids) {
      final rows = await db!.query(
        tracksTable,
        where: 'id == ?',
        whereArgs: [id],
        columns: ['id', 'offline', 'unavailable'],
      );
      if (rows.isEmpty) continue;
      final row = rows.first;
      if (row['unavailable'] == 1 ||
          (row['offline'] == 1 && await _offlineFileExists(platformId, id))) {
        count++;
        continue;
      }

      // A DRM-protected item can be unavailable for offline download while
      // remaining playable online. Count that download-only skip toward the
      // playlist's offline completion without marking the Track unavailable.
      final skippedDownloads = await db!.query(
        'Downloads',
        columns: ['id'],
        where: 'platformId = ? AND trackId = ? AND private = 1 AND state = ?',
        whereArgs: [platformId, id, DownloadState.UNAVAILABLE.index],
        limit: 1,
      );
      if (skippedDownloads.isNotEmpty) count++;
    }
    return count;
  }

  Future<bool> _offlineFileExists(String platformId, String? trackId) async {
    if (trackId == null) return false;
    final platformFile = File(p.join(offlinePath!, platformId, trackId));
    if (await platformFile.exists()) return true;
    return File(p.join(offlinePath!, trackId)).exists();
  }

  Future<Map<String, dynamic>?> getOfflineTrackQuality(
    String platformId,
    String trackId,
  ) async {
    final database = db;
    if (database == null) return null;
    final trackRows = await database.query(
      _offlineTable(platformId, 'Tracks'),
      columns: ['qualityFormat', 'qualityBitrate'],
      where: 'id = ?',
      whereArgs: [trackId],
      limit: 1,
    );
    final quality = <String, dynamic>{};
    if (trackRows.isNotEmpty) {
      final row = trackRows.first;
      if (row['qualityFormat'] != null) {
        quality['resolvedFormat'] = row['qualityFormat'];
      }
      if (row['qualityBitrate'] != null) {
        quality['resolvedBitrate'] = row['qualityBitrate'];
      }
    }
    final rows = await database.query(
      'Downloads',
      columns: ['quality', 'resolvedFormat', 'resolvedBitrate'],
      where: 'private = 1 AND platformId = ? AND trackId = ? AND state = ?',
      whereArgs: [platformId, trackId, DownloadState.DONE.index],
      orderBy: 'id DESC',
      limit: 1,
    );
    if (rows.isNotEmpty) {
      final download = rows.first;
      quality['quality'] = download['quality'];
      if (quality['resolvedFormat'] == null &&
          download['resolvedFormat'] != null) {
        quality['resolvedFormat'] = download['resolvedFormat'];
      }
      if (quality['resolvedBitrate'] == null &&
          download['resolvedBitrate'] != null) {
        quality['resolvedBitrate'] = download['resolvedBitrate'];
      }
    }
    return quality.isEmpty ? null : quality;
  }

  //Get all downloads from db
  Future<List<Download>> getDownloads() async {
    List<Map<String, dynamic>> raw = _downloadService.getDownloads();
    return raw.map((d) => Download.fromJson(d)).toList();
  }

  Future<bool> isQueued(String trackId) async {
    final downloads = await getDownloads();
    return downloads.any(
      (d) =>
          d.trackId == trackId &&
          d.state != DownloadState.DONE &&
          d.state != DownloadState.UNAVAILABLE,
    );
  }

  //Insert track and metadata to DB
  Future _addTrackToDB(
    Batch batch,
    Track track,
    bool overwriteTrack, {
    bool downloaded = false,
  }) async {
    track.album?.platformId = track.platformId;
    for (final artist in track.artists ?? <Artist>[]) {
      artist.platformId = track.platformId;
    }
    final tracksTable = _offlineTable(track.platformId, 'Tracks');
    final albumsTable = _offlineTable(track.platformId, 'Albums');
    final artistsTable = _offlineTable(track.platformId, 'Artists');
    batch.insert(
      tracksTable,
      track.toSQL(off: downloaded),
      conflictAlgorithm: overwriteTrack
          ? ConflictAlgorithm.replace
          : ConflictAlgorithm.ignore,
    );
    // Keep an unavailable flag current even when the track row already exists.
    batch.update(
      tracksTable,
      {
        'unavailable': track.unavailable == true ? 1 : 0,
        'unavailableReason': track.unavailableReason,
      },
      where: 'id == ?',
      whereArgs: [track.id],
    );
    if (track.album != null) {
      batch.insert(
        albumsTable,
        track.album!.toSQL(off: false),
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    //Artists
    if (track.artists != null) {
      for (Artist a in track.artists!) {
        batch.insert(
          artistsTable,
          a.toSQL(off: false),
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
    }
    return batch;
  }

  //Quality selector for custom quality
  Future<AudioQuality?> qualitySelect({required String platformId}) async {
    // Try to get context from mainNavigatorKey first, then fall back to appRouter
    BuildContext? context = mainNavigatorKey.currentState?.overlay?.context;
    context ??=
        appRouter.routerDelegate.navigatorKey.currentState?.overlay?.context;

    if (context == null) {
      return null;
    }

    final platform = PlatformRegistry.instance.get(platformId);
    final options = platform?.availableDownloadQualities ?? const [];
    if (options.isEmpty) return null;
    AudioQuality? quality;
    await showModalBottomSheet(
      context: context,
      builder: (context) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 12, 0, 2),
              child: Text(
                'Quality'.i18n,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 20.0,
                ),
              ),
            ),
            ...options.map(
              (option) => ListTile(
                title: Text(option.label),
                onTap: () {
                  quality = option.quality;
                  Navigator.of(context).pop();
                },
              ),
            ),
          ],
        );
      },
    );
    return quality;
  }

  Future<bool> openStoragePermissionSettingsDialog() async {
    Completer<bool> completer = Completer<bool>();

    // Try to get context from mainNavigatorKey first, then fall back to appRouter
    BuildContext? context = mainNavigatorKey.currentState?.overlay?.context;
    context ??=
        appRouter.routerDelegate.navigatorKey.currentState?.overlay?.context;
    if (context == null) return false;

    await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Storage Permission Required'.i18n),
          content: Text(
            'Storage permission is required to download content.\nPlease open system settings and grant storage permission to Saturn.'
                .i18n,
          ),
          actions: <Widget>[
            TextButton(
              style: ButtonStyle(
                overlayColor: WidgetStateProperty.resolveWith<Color?>((
                  Set<WidgetState> states,
                ) {
                  if (states.contains(WidgetState.pressed)) {
                    return Theme.of(
                      context,
                    ).primaryColor.withValues(alpha: 0.3);
                  }
                  return null;
                }),
              ),
              child: Text('Cancel'.i18n),
              onPressed: () {
                Navigator.of(context).pop();
                completer.complete(false);
              },
            ),
            TextButton(
              style: ButtonStyle(
                overlayColor: WidgetStateProperty.resolveWith<Color?>((
                  Set<WidgetState> states,
                ) {
                  if (states.contains(WidgetState.pressed)) {
                    return Theme.of(
                      context,
                    ).primaryColor.withValues(alpha: 0.3);
                  }
                  return null;
                }),
              ),
              child: Text('Open system settings'.i18n),
              onPressed: () {
                Navigator.of(context).pop();
                completer.complete(true);
              },
            ),
          ],
        );
      },
    );

    return completer.future;
  }

  Future<bool> openSAFPermissionDialog() async {
    Completer<bool> completer = Completer<bool>();

    // Try to get context from mainNavigatorKey first, then fall back to appRouter
    BuildContext? context = mainNavigatorKey.currentState?.overlay?.context;
    context ??=
        appRouter.routerDelegate.navigatorKey.currentState?.overlay?.context;
    if (context == null) return false;

    await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('External Storage Access Required'.i18n),
          content: Text(
            'To download files to the external storage, please grant access to the SD card or USB root directory in the following screen.'
                .i18n,
          ),
          actions: <Widget>[
            TextButton(
              style: ButtonStyle(
                overlayColor: WidgetStateProperty.resolveWith<Color?>((
                  Set<WidgetState> states,
                ) {
                  if (states.contains(WidgetState.pressed)) {
                    return Theme.of(
                      context,
                    ).primaryColor.withValues(alpha: 0.3);
                  }
                  return null;
                }),
              ),
              child: Text('Cancel'.i18n),
              onPressed: () {
                Navigator.of(context).pop();
                completer.complete(false);
              },
            ),
            TextButton(
              style: ButtonStyle(
                overlayColor: WidgetStateProperty.resolveWith<Color?>((
                  Set<WidgetState> states,
                ) {
                  if (states.contains(WidgetState.pressed)) {
                    return Theme.of(
                      context,
                    ).primaryColor.withValues(alpha: 0.3);
                  }
                  return null;
                }),
              ),
              child: Text('Continue'.i18n),
              onPressed: () {
                Navigator.of(context).pop();
                completer.complete(true);
              },
            ),
          ],
        );
      },
    );

    return completer.future;
  }

  Future<bool> addOfflineTrack(
    Track track, {
    private = true,
    isSingleton = false,
    AudioQuality? quality,
  }) async {
    _downloadLog?.log(
      '[DownloadManager] addOfflineTrack called - trackId: ${track.id}, title: ${track.title}, private: $private, isSingleton: $isSingleton',
    );

    final musicPlatform = PlatformRegistry.instance.get(track.platformId);
    if (musicPlatform == null || !musicPlatform.capabilities.supportsDownload) {
      _downloadLog?.warn(
        '[DownloadManager] ${track.platformId} does not support downloads',
      );
      return false;
    }

    //Permission
    if (!private && !(await checkPermission())) {
      _downloadLog?.warn(
        '[DownloadManager] addOfflineTrack - Permission denied for public download',
      );
      return false;
    }

    //Ask for quality
    if (!private &&
        settings.downloadQuality == AudioQuality.ASK &&
        quality == null) {
      quality = await qualitySelect(platformId: track.platformId);
      if (quality == null) return false;
    }

    //Fetch track if missing meta
    if (track.artists == null || track.artists!.isEmpty) {
      _downloadLog?.log(
        '[DownloadManager] addOfflineTrack - Fetching full track metadata for ${track.id}',
      );
      track = await musicPlatform.getTrack(track.id!);
      _downloadLog?.log(
        '[DownloadManager] addOfflineTrack - Track metadata fetched: ${track.title}',
      );
    }

    //Add to DB
    if (private) {
      Batch b = db!.batch();
      b = await _addTrackToDB(b, track, true, downloaded: false);
      await b.commit();

      //Cache art
      DefaultCacheManager().getSingleFile(track.albumArt?.thumb ?? '');
      DefaultCacheManager().getSingleFile(track.albumArt?.full ?? '');
    }

    //Get path
    String path = _generatePath(track, private, isSingleton: isSingleton);
    if (private) {
      await Directory(p.dirname(path)).create(recursive: true);
    }
    _downloadLog?.log(
      '[DownloadManager] addOfflineTrack - Generated path: $path',
    );

    final trackJson = await Download.jsonFromTrack(
      track,
      path,
      private: private,
      quality: quality,
    );
    _downloadLog?.log(
      '[DownloadManager] addOfflineTrack - Created download JSON: platform=${trackJson['platformId']}, trackId=${trackJson['trackId']}, quality=${trackJson['quality']}',
    );

    await _downloadService.addDownloads([Map<String, dynamic>.from(trackJson)]);
    if (private) await _refreshOfflineContainers(track.platformId);
    _downloadLog?.log(
      '[DownloadManager] addOfflineTrack - Download added to service, starting...',
    );
    await start();
    _downloadLog?.log(
      '[DownloadManager] addOfflineTrack - Complete for track ${track.id}',
    );
    return true;
  }

  Future addOfflineAlbum(
    Album album, {
    private = true,
    AudioQuality? quality,
  }) async {
    _downloadLog?.log(
      '[DownloadManager] addOfflineAlbum called - albumId: ${album.id}, title: ${album.title}, private: $private',
    );

    final musicPlatform = PlatformRegistry.instance.get(album.platformId);
    if (musicPlatform == null || !musicPlatform.capabilities.supportsDownload) {
      return false;
    }

    //Permission
    if (!private && !(await checkPermission())) {
      _downloadLog?.warn(
        '[DownloadManager] addOfflineAlbum - Permission denied for public download',
      );
      return;
    }

    //Ask for quality
    if (!private &&
        settings.downloadQuality == AudioQuality.ASK &&
        quality == null) {
      quality = await qualitySelect(platformId: album.platformId);
      if (quality == null) return false;
    }

    //Get from API if no tracks
    if (album.tracks == null || album.tracks!.isEmpty) {
      _downloadLog?.log(
        '[DownloadManager] addOfflineAlbum - Fetching album tracks from API for ${album.id}',
      );
      album = await musicPlatform.getAlbum(album.id ?? '');
      album.platformId = musicPlatform.platformId;
      _downloadLog?.log(
        '[DownloadManager] addOfflineAlbum - Fetched ${album.tracks?.length ?? 0} tracks',
      );
    }
    album.platformId = musicPlatform.platformId;
    for (final track in album.tracks ?? <Track>[]) {
      track.platformId = album.platformId;
    }

    //Add to DB
    if (private) {
      //Cache art
      DefaultCacheManager().getSingleFile(album.art?.thumb ?? '');
      DefaultCacheManager().getSingleFile(album.art?.full ?? '');

      Batch b = db!.batch();
      b.insert(
        _offlineTable(album.platformId, 'Albums'),
        album.toSQL(off: false),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      for (Track t in album.tracks ?? []) {
        t.platformId = album.platformId;
        b = await _addTrackToDB(b, t, false);
      }
      await b.commit();
    }

    //Create downloads
    List<Map> out = [];
    for (Track t in (album.tracks ?? [])) {
      if (t.unavailable == true) {
        _downloadLog?.log(
          '[DownloadManager] Queuing unavailable album track as skipped: ${t.id} (${t.title})',
        );
      }
      t.platformId = album.platformId;
      final path = _generatePath(t, private);
      if (private) {
        await Directory(p.dirname(path)).create(recursive: true);
      }
      out.add(
        await Download.jsonFromTrack(
          t,
          path,
          private: private,
          quality: quality,
        ),
      );
    }
    if (out.isNotEmpty) {
      await _downloadService.addDownloads(out);
      if (private) await _refreshOfflineContainers(album.platformId);
      await start();
    } else if (private) {
      await _refreshOfflineContainers(album.platformId);
    }
  }

  Future<List<Track>> loadLocalPlaylistTracks(
    LocalPlaylist playlist, {
    int start = 0,
    int? limit,
  }) async {
    final trackIds = limit == null
        ? playlist.trackIds.skip(start).toList()
        : playlist.trackIds.skip(start).take(limit).toList();
    if (trackIds.isEmpty) return [];

    final platformToIds = <String, List<String>>{};
    for (final idStr in trackIds) {
      final ref = LocalPlaylistTrackReference.parse(idStr);
      (platformToIds[ref.platformId] ??= []).add(ref.trackId);
    }

    final trackMap = <String, Track>{};
    await Future.wait(
      platformToIds.entries.map((entry) async {
        final platform = PlatformRegistry.instance.get(entry.key);
        if (platform == null) return;
        try {
          final fetched = await platform.getTracks(entry.value);
          for (final t in fetched) {
            t.platformId = entry.key;
            trackMap['${entry.key}:${t.id}'] = t;
          }
        } catch (e) {
          _downloadLog?.warn('Failed to load tracks from ${entry.key}: $e');
        }
      }),
    );

    // Fallback to offline tracks if network fetch was missing or offline
    for (final idStr in trackIds) {
      final ref = LocalPlaylistTrackReference.parse(idStr);
      if (!trackMap.containsKey(ref.storageKey)) {
        try {
          final offlineTrack = await getOfflineTrack(
            ref.trackId,
            platformId: ref.platformId,
          );
          if (offlineTrack != null) {
            offlineTrack.platformId = ref.platformId;
            trackMap[ref.storageKey] = offlineTrack;
          }
        } catch (_) {}
      }
    }

    return trackIds
        .map(
          (idStr) =>
              trackMap[LocalPlaylistTrackReference.parse(idStr).storageKey],
        )
        .whereType<Track>()
        .toList();
  }

  Future<Playlist?> getFullLocalPlaylist(String id) async {
    final cleanId = id.startsWith('local_') ? id.substring(6) : id;
    final localPlaylist = await localPlaylistManager.getPlaylist(cleanId);
    if (localPlaylist == null) return null;
    final tracks = await loadLocalPlaylistTracks(localPlaylist);
    return Playlist(
      id: 'local_${localPlaylist.id}',
      title: localPlaylist.title,
      description: localPlaylist.description,
      tracks: tracks,
      trackCount: localPlaylist.trackIds.length,
      platformId: 'local',
      mosaicImages: localPlaylist.mosaicImages,
    );
  }

  Future addOfflinePlaylist(
    Playlist playlist, {
    private = true,
    AudioQuality? quality,
  }) async {
    _downloadLog?.log(
      '[DownloadManager] addOfflinePlaylist called - playlistId: ${playlist.id}, title: ${playlist.title}, private: $private, trackCount: ${playlist.trackCount}',
    );

    final isLocal =
        playlist.platformId == 'local' ||
        (playlist.id?.startsWith('local_') ?? false);

    if (isLocal) {
      final localId = playlist.id!.startsWith('local_')
          ? playlist.id!.substring(6)
          : playlist.id!;
      final localPlaylist = await localPlaylistManager.getPlaylist(localId);
      if (localPlaylist == null) return false;

      if (!private && !(await checkPermission())) {
        _downloadLog?.warn(
          '[DownloadManager] addOfflinePlaylist - Permission denied for public download',
        );
        return false;
      }

      if (!private &&
          settings.downloadQuality == AudioQuality.ASK &&
          quality == null) {
        quality = await qualitySelect(
          platformId: PlatformManager.instance.activePlatformId,
        );
        if (quality == null) return false;
      }

      if (private) {
        await localPlaylistManager.updatePlaylist(
          localPlaylist.copyWith(offline: false),
        );
      }

      final tracks = await loadLocalPlaylistTracks(localPlaylist);

      List<Map> out = [];
      int i = 0;
      for (final t in tracks) {
        if (private) {
          if (t.unavailable == true) {
            _downloadLog?.log(
              '[DownloadManager] Queuing unavailable local-playlist track as skipped: ${t.id} (${t.title})',
            );
            Batch b = db!.batch();
            b = await _addTrackToDB(b, t, false, downloaded: false);
            await b.commit();
          } else if (await checkOffline(track: t)) {
            i++;
            continue;
          } else {
            Batch b = db!.batch();
            b = await _addTrackToDB(b, t, false, downloaded: false);
            await b.commit();
            DefaultCacheManager().getSingleFile(t.albumArt?.thumb ?? '');
            DefaultCacheManager().getSingleFile(t.albumArt?.full ?? '');
          }
        }

        final path = _generatePath(
          t,
          private,
          playlistName: playlist.title,
          playlistTrackNumber: i,
        );
        if (private) {
          await Directory(p.dirname(path)).create(recursive: true);
        }
        out.add(
          await Download.jsonFromTrack(
            t,
            path,
            private: private,
            quality: quality,
          ),
        );
        i++;
      }

      if (out.isNotEmpty) {
        await _downloadService.addDownloads(out);
        if (private) {
          await _refreshOfflineContainers(
            tracks.isNotEmpty
                ? tracks.first.platformId
                : PlatformManager.instance.activePlatformId,
          );
        }
        await start();
      } else if (private) {
        await _refreshOfflineContainers(
          tracks.isNotEmpty
              ? tracks.first.platformId
              : PlatformManager.instance.activePlatformId,
        );
      }
      return true;
    }

    final musicPlatform = PlatformRegistry.instance.get(playlist.platformId);
    if (musicPlatform == null || !musicPlatform.capabilities.supportsDownload) {
      return false;
    }

    //Permission
    if (!private && !(await checkPermission())) {
      _downloadLog?.warn(
        '[DownloadManager] addOfflinePlaylist - Permission denied for public download',
      );
      return;
    }

    //Ask for quality
    if (!private &&
        settings.downloadQuality == AudioQuality.ASK &&
        quality == null) {
      quality = await qualitySelect(platformId: playlist.platformId);
      if (quality == null) return false;
    }

    if (_isFavoritesPlaylist(playlist)) {
      playlist = await _loadFavoritesPlaylist(musicPlatform, playlist);
    }

    //Get tracks if missing
    if (!_isFavoritesPlaylist(playlist) &&
        ((playlist.tracks == null) ||
            (playlist.tracks?.length ?? 0) < (playlist.trackCount ?? 0))) {
      final playlistMosaic = playlist.mosaicImages;
      _downloadLog?.log(
        '[DownloadManager] addOfflinePlaylist - Fetching full playlist from API for ${playlist.id}',
      );
      playlist = await musicPlatform.getFullPlaylist(playlist.id ?? '');
      playlist.platformId = musicPlatform.platformId;
      if (playlist.mosaicImages?.isNotEmpty != true &&
          playlistMosaic?.isNotEmpty == true) {
        playlist.mosaicImages = playlistMosaic;
      }
      _downloadLog?.log(
        '[DownloadManager] addOfflinePlaylist - Fetched ${playlist.tracks?.length ?? 0} tracks',
      );
    }
    playlist.platformId = musicPlatform.platformId;
    for (final track in playlist.tracks ?? <Track>[]) {
      track.platformId = playlist.platformId;
    }

    //Add to DB
    if (private) {
      Batch b = db!.batch();
      final sqlData = playlist.toSQL();
      sqlData['offline'] = 0;
      b.insert(
        _offlineTable(playlist.platformId, 'Playlists'),
        sqlData,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      for (Track t in (playlist.tracks ?? [])) {
        t.platformId = playlist.platformId;
        b = await _addTrackToDB(b, t, false);
        //Cache art
        DefaultCacheManager().getSingleFile(t.albumArt?.thumb ?? '');
        DefaultCacheManager().getSingleFile(t.albumArt?.full ?? '');
      }
      await b.commit();
    }

    //Generate downloads
    List<Map> out = [];
    for (int i = 0; i < (playlist.tracks?.length ?? 0); i++) {
      Track t = playlist.tracks![i];
      if (t.unavailable == true) {
        _downloadLog?.log(
          '[DownloadManager] Queuing unavailable playlist track as skipped: ${t.id} (${t.title})',
        );
      }
      t.platformId = playlist.platformId;
      final path = _generatePath(
        t,
        private,
        playlistName: playlist.title,
        playlistTrackNumber: i,
      );
      if (private) {
        await Directory(p.dirname(path)).create(recursive: true);
      }
      out.add(
        await Download.jsonFromTrack(
          t,
          path,
          private: private,
          quality: quality,
        ),
      );
    }
    if (out.isNotEmpty) {
      await _downloadService.addDownloads(out);
      if (private) await _refreshOfflineContainers(playlist.platformId);
      await start();
    } else if (private) {
      await _refreshOfflineContainers(playlist.platformId);
    }
    return true;
  }

  //Get track and meta from offline DB
  Future<Track?> getOfflineTrack(
    String id, {
    String? platformId,
    Album? album,
    List<Artist>? artists,
    bool includeUnavailable = false,
  }) async {
    final sourceId = platformId ?? PlatformManager.instance.activePlatformId;
    final tracksTable = _offlineTable(sourceId, 'Tracks');
    final albumsTable = _offlineTable(sourceId, 'Albums');
    final artistsTable = _offlineTable(sourceId, 'Artists');
    List tracks = await db!.query(
      tracksTable,
      where: 'id == ?',
      whereArgs: [id],
    );
    if (tracks.isEmpty) return null;
    Track track = Track.fromSQL(tracks[0]);
    final hasOfflineFile = await _offlineFileExists(sourceId, id);
    if (!hasOfflineFile && !(includeUnavailable && track.unavailable == true)) {
      return null;
    }
    if (hasOfflineFile && track.offline != true) {
      track.offline = true;
      await db!.update(
        tracksTable,
        {'offline': 1},
        where: 'id = ?',
        whereArgs: [id],
      );
      _offlineTrackCache.remove('$sourceId:$id');
    }

    //Get album
    if (album == null) {
      final albumId = track.album?.id;
      if (albumId != null) {
        final rawAlbums = await db!.query(
          albumsTable,
          where: 'id == ?',
          whereArgs: [albumId],
        );
        if (rawAlbums.isNotEmpty) track.album = Album.fromSQL(rawAlbums[0]);
      }
    } else {
      track.album = album;
    }

    //Get artists
    if (artists == null) {
      List<Artist> newArtists = [];
      for (Artist artist in (track.artists ?? [])) {
        final artistId = artist.id;
        if (artistId == null) continue;
        final rawArtist = await db!.query(
          artistsTable,
          where: 'id == ?',
          whereArgs: [artistId],
        );
        if (rawArtist.isNotEmpty) newArtists.add(Artist.fromSQL(rawArtist[0]));
      }
      if (newArtists.isNotEmpty) track.artists = newArtists;
    } else {
      track.artists = artists;
    }
    return track;
  }

  /// Recreates the offline-library row when playback finds a downloaded file
  /// whose metadata row was lost (for example after an interrupted upgrade).
  Future<void> recoverOfflineTrackMetadata(Track track) async {
    final id = track.id;
    if (id == null || id.isEmpty) return;
    if (_initFuture != null) await _initFuture;
    final database = db;
    if (database == null) return;

    final batch = database.batch();
    await _addTrackToDB(batch, track, false, downloaded: true);
    await batch.commit();
    await database.update(
      _offlineTable(track.platformId, 'Tracks'),
      {'offline': 1},
      where: 'id = ?',
      whereArgs: [id],
    );
    _offlineTrackCache.remove('${track.platformId}:$id');
    if (_localPlaylistManagerInitialized) {
      await _refreshOfflineContainers(track.platformId);
    }
    _offlineLibraryChanged.add(null);
    _downloadLog?.log(
      '[DownloadManager] Recovered offline track metadata for ${track.platformId}:$id',
    );
  }

  //Get offline library tracks
  Future<List<Track>> getOfflineTracks() async {
    List<Track> out = [];
    for (final platformId in await _offlinePlatformIds()) {
      await _repairOfflineTrackFlags(platformId);
      final rawTracks = await db!.query(
        _offlineTable(platformId, 'Tracks'),
        where: 'favorite == 1 AND offline == 1',
        columns: ['id'],
      );
      for (final rawTrack in rawTracks) {
        final offlineTrack = await getOfflineTrack(
          rawTrack['id'] as String,
          platformId: platformId,
        );
        if (offlineTrack != null) out.add(offlineTrack);
      }
    }
    return out;
  }

  //Get all offline available tracks
  Future<List<Track>> allOfflineTracks() async {
    List<Track> out = [];
    for (final platformId in await _offlinePlatformIds()) {
      await _repairOfflineTrackFlags(platformId);
      final rawTracks = await db!.query(
        _offlineTable(platformId, 'Tracks'),
        where: 'offline == 1',
        columns: ['id'],
      );
      for (final rawTrack in rawTracks) {
        final offlineTrack = await getOfflineTrack(
          rawTrack['id'] as String,
          platformId: platformId,
        );
        if (offlineTrack != null) out.add(offlineTrack);
      }
    }
    return out;
  }

  //Get all offline albums
  Future<List<Album>> getOfflineAlbums() async {
    List<Album> out = [];
    for (final platformId in await _offlinePlatformIds()) {
      final rawAlbums = await db!.query(
        _offlineTable(platformId, 'Albums'),
        where: 'offline == 1',
        columns: ['id'],
      );
      for (final rawAlbum in rawAlbums) {
        final offlineAlbum = await getOfflineAlbum(
          rawAlbum['id'] as String,
          platformId: platformId,
        );
        if (offlineAlbum != null) out.add(offlineAlbum);
      }
    }
    return out;
  }

  //Get offline album with meta
  Future<Album?> getOfflineAlbum(String id, {String? platformId}) async {
    final sourceId = platformId ?? PlatformManager.instance.activePlatformId;
    List rawAlbums = await db!.query(
      _offlineTable(sourceId, 'Albums'),
      where: 'id == ?',
      whereArgs: [id],
    );
    if (rawAlbums.isEmpty) return null;
    Album album = Album.fromSQL(rawAlbums[0]);

    List<Track> tracks = [];
    final expectedTrackCount = album.tracks?.length ?? 0;
    //Load tracks
    for (int i = 0; i < (album.tracks?.length ?? 0); i++) {
      var offlineTrack = await getOfflineTrack(
        album.tracks![i].id!,
        platformId: sourceId,
      );
      if (offlineTrack != null) tracks.add(offlineTrack);
    }
    if (expectedTrackCount > 0 && tracks.length < expectedTrackCount) {
      return null;
    }
    if (expectedTrackCount == 0 && tracks.isEmpty) return null;
    album.tracks = tracks;
    //Load artists
    List<Artist> artists = [];
    for (int i = 0; i < (album.artists?.length ?? 0); i++) {
      artists.add(
        (await getOfflineArtist(
              album.artists![i].id ?? '',
              platformId: sourceId,
            )) ??
            album.artists![i],
      );
    }
    album.artists = artists;

    return album;
  }

  //Get offline artist METADATA, not tracks
  Future<Artist?> getOfflineArtist(String id, {String? platformId}) async {
    final sourceId = platformId ?? PlatformManager.instance.activePlatformId;
    List rawArtists = await db!.query(
      _offlineTable(sourceId, 'Artists'),
      where: 'id == ?',
      whereArgs: [id],
    );
    if (rawArtists.isEmpty) return null;
    return Artist.fromSQL(rawArtists[0]);
  }

  //Get all offline playlists
  Future<List<Playlist>> getOfflinePlaylists() async {
    List<Playlist> out = [];
    for (final platformId in await _offlinePlatformIds()) {
      final rawPlaylists = await db!.query(
        _offlineTable(platformId, 'Playlists'),
        columns: ['id'],
      );
      for (final rawPlaylist in rawPlaylists) {
        final offlinePlaylist = await getOfflinePlaylist(
          rawPlaylist['id'] as String,
          platformId: platformId,
        );
        if (offlinePlaylist != null) out.add(offlinePlaylist);
      }
    }
    try {
      final localPlaylists = await localPlaylistManager.getAllPlaylists();
      for (final lp in localPlaylists) {
        if (lp.offline) {
          final offlinePl = await getOfflinePlaylist(
            'local_${lp.id}',
            platformId: 'local',
          );
          if (offlinePl != null) out.add(offlinePl);
        }
      }
    } catch (e) {
      _downloadLog?.warn('Failed to load local offline playlists: $e');
    }
    return out;
  }

  //Get offline playlist
  Future<Playlist?> getOfflinePlaylist(String id, {String? platformId}) async {
    final isLocal = platformId == 'local' || id.startsWith('local_');
    if (isLocal) {
      final cleanId = id.startsWith('local_') ? id.substring(6) : id;
      final localPlaylist = await localPlaylistManager.getPlaylist(cleanId);
      if (localPlaylist == null || !localPlaylist.offline) return null;

      List<Track> tracks = [];
      for (final idStr in localPlaylist.trackIds) {
        final ref = LocalPlaylistTrackReference.parse(idStr);
        final offlineTrack = await getOfflineTrack(
          ref.trackId,
          platformId: ref.platformId,
          includeUnavailable: true,
        );
        if (offlineTrack != null) {
          offlineTrack.platformId = ref.platformId;
          tracks.add(offlineTrack);
        }
      }
      return Playlist(
        id: 'local_${localPlaylist.id}',
        title: localPlaylist.title,
        description: localPlaylist.description,
        tracks: tracks,
        trackCount: localPlaylist.trackIds.length,
        platformId: 'local',
        mosaicImages: localPlaylist.mosaicImages,
      );
    }

    final sourceId = platformId ?? PlatformManager.instance.activePlatformId;
    List rawPlaylists = await db!.query(
      _offlineTable(sourceId, 'Playlists'),
      where: 'id == ?',
      whereArgs: [id],
    );
    if (rawPlaylists.isEmpty) return null;

    Playlist playlist = Playlist.fromSQL(rawPlaylists[0]);
    //Load tracks
    List<Track> tracks = [];
    final expectedTrackCount = playlist.tracks?.length ?? 0;
    if (playlist.tracks != null) {
      for (Track t in playlist.tracks!) {
        var offlineTrack = await getOfflineTrack(
          t.id!,
          platformId: sourceId,
          includeUnavailable: true,
        );
        if (offlineTrack != null) tracks.add(offlineTrack);
      }
    }
    // Unavailable tracks are retained as metadata-only entries. They count
    // toward a complete offline playlist alongside tracks with local files.
    if (expectedTrackCount > 0 && tracks.length < expectedTrackCount) {
      return null;
    }
    if (expectedTrackCount == 0 && tracks.isEmpty) return null;
    playlist.tracks = tracks;
    // Older offline playlist rows predate persisted mosaic metadata. Recover a
    // reasonable cover from the saved track art when the playlist has no
    // custom cover, while newly saved rows retain the API's exact mosaic order.
    if ((playlist.image?.thumb ?? playlist.image?.full ?? '').isEmpty &&
        playlist.mosaicImages?.isNotEmpty != true) {
      final seenArt = <String>{};
      playlist.mosaicImages = tracks
          .map((track) => track.albumArt?.full ?? track.albumArt?.thumb)
          .whereType<String>()
          .where((url) => url.isNotEmpty && seenArt.add(url))
          .take(4)
          .toList();
    }
    return playlist;
  }

  Future removeOfflineTracks(List<Track> tracks) async {
    _offlineTrackCache.clear();
    final platformsToRefresh = <String>{};
    for (Track t in tracks) {
      platformsToRefresh.add(t.platformId);
      final tracksTable = _offlineTable(t.platformId, 'Tracks');
      final albumsTable = _offlineTable(t.platformId, 'Albums');
      final playlistsTable = _offlineTable(t.platformId, 'Playlists');
      //Check if library
      List rawTrack = await db!.query(
        tracksTable,
        where: 'id == ?',
        whereArgs: [t.id],
        columns: ['favorite'],
      );
      if (rawTrack.isNotEmpty) {
        //Count occurrences in playlists and albums
        List albums = await db!.rawQuery(
          'SELECT (id) FROM $albumsTable WHERE tracks LIKE ?',
          ['%${t.id}%'],
        );
        List playlists = await db!.rawQuery(
          'SELECT (id) FROM $playlistsTable WHERE tracks LIKE ?',
          ['%${t.id}%'],
        );
        if (albums.length + playlists.length == 0 &&
            rawTrack[0]['favorite'] == 0) {
          //Safe to remove
          await db!.delete(tracksTable, where: 'id == ?', whereArgs: [t.id]);
        } else {
          await db!.update(
            tracksTable,
            {'offline': 0},
            where: 'id == ?',
            whereArgs: [t.id],
          );
        }
      }

      //Remove file
      try {
        await File(p.join(offlinePath!, t.platformId, t.id)).delete();
      } catch (e) {
        Logger.root.severe('Error deleting offline track: ${t.id}', e);
      }
      _offlineTracksRemoved.add(t);
    }
    for (final platformId in platformsToRefresh) {
      await _refreshOfflineContainers(platformId);
    }
    _offlineLibraryChanged.add(null);
  }

  Future removeOfflineAlbum(String id, {String? platformId}) async {
    final sourceId = platformId ?? PlatformManager.instance.activePlatformId;
    final albumsTable = _offlineTable(sourceId, 'Albums');
    //Get album
    List rawAlbums = await db!.query(
      albumsTable,
      where: 'id == ?',
      whereArgs: [id],
    );
    if (rawAlbums.isEmpty) return;
    Album album = Album.fromSQL(rawAlbums[0]);
    //Remove album
    await db!.delete(albumsTable, where: 'id == ?', whereArgs: [id]);
    for (final track in album.tracks ?? <Track>[]) {
      track.platformId = sourceId;
    }
    //Remove tracks
    await removeOfflineTracks(album.tracks!);
  }

  Future removeOfflinePlaylist(String id, {String? platformId}) async {
    final isLocal = platformId == 'local' || id.startsWith('local_');
    if (isLocal) {
      final localId = id.startsWith('local_') ? id.substring(6) : id;
      final localPlaylist = await localPlaylistManager.getPlaylist(localId);
      if (localPlaylist == null) return;
      await localPlaylistManager.updatePlaylist(
        localPlaylist.copyWith(offline: false),
      );
      _offlineLibraryChanged.add(null);

      final otherOfflinePlaylists =
          (await localPlaylistManager.getAllPlaylists()).where(
            (p) => p.id != localPlaylist.id && p.offline,
          );
      final tracksInOtherLocalOffline = <String>{};
      for (final other in otherOfflinePlaylists) {
        for (final idStr in other.trackIds) {
          final ref = LocalPlaylistTrackReference.parse(idStr);
          tracksInOtherLocalOffline.add('${ref.platformId}:${ref.trackId}');
        }
      }

      List<Track> dummyTracks = [];
      for (final idStr in localPlaylist.trackIds) {
        final ref = LocalPlaylistTrackReference.parse(idStr);
        if (!tracksInOtherLocalOffline.contains(
          '${ref.platformId}:${ref.trackId}',
        )) {
          dummyTracks.add(Track(id: ref.trackId, platformId: ref.platformId));
        }
      }
      if (dummyTracks.isNotEmpty) {
        await removeOfflineTracks(dummyTracks);
      }
      return;
    }

    final sourceId = platformId ?? PlatformManager.instance.activePlatformId;
    final playlistsTable = _offlineTable(sourceId, 'Playlists');
    //Fetch playlist
    List rawPlaylists = await db!.query(
      playlistsTable,
      where: 'id == ?',
      whereArgs: [id],
    );
    if (rawPlaylists.isEmpty) return;
    Playlist playlist = Playlist.fromSQL(rawPlaylists[0]);
    //Remove playlist
    await db!.delete(playlistsTable, where: 'id == ?', whereArgs: [id]);
    for (final track in playlist.tracks ?? <Track>[]) {
      track.platformId = sourceId;
    }
    await removeOfflineTracks(playlist.tracks!);
  }

  /// Repairs stale track flags from older versions using the actual offline
  /// files as the source of truth. A file may be playable even when an older
  /// download completion callback failed to update its metadata row.
  Future<void> _repairOfflineTrackFlags(String platformId) async {
    final database = db;
    if (database == null) return;
    final table = _offlineTable(platformId, 'Tracks');
    final rows = await database.query(
      table,
      columns: ['id'],
      where: 'offline != 1',
    );
    if (rows.isEmpty) return;

    final batch = database.batch();
    var repaired = 0;
    const chunkSize = 32;
    for (var start = 0; start < rows.length; start += chunkSize) {
      final chunk = rows.skip(start).take(chunkSize).toList();
      final ids = chunk.map((row) => row['id'] as String?).toList();
      final fileResults = await Future.wait(
        ids.map(
          (id) => id == null
              ? Future<bool>.value(false)
              : _offlineFileExists(platformId, id),
        ),
      );
      for (var index = 0; index < ids.length; index++) {
        final id = ids[index];
        if (id == null || !fileResults[index]) continue;
        batch.update(table, {'offline': 1}, where: 'id = ?', whereArgs: [id]);
        repaired++;
      }
    }
    if (repaired > 0) {
      await batch.commit(noResult: true);
      _offlineTrackCache.clear();
    }
  }

  //Check if album, track or playlist is offline
  Future<bool> checkOffline({
    Album? album,
    Track? track,
    Playlist? playlist,
  }) async {
    if (track != null) {
      if (track.id == null) return false;
      final key = '${track.platformId}:${track.id}';
      final cached = _offlineTrackCache[key];
      if (cached != null) return cached;
      if (db == null) return false;

      // Playback already treats the local file as authoritative. Match that
      // behavior here so stale metadata does not hide a real download.
      final rows = await db!.query(
        _offlineTable(track.platformId, 'Tracks'),
        columns: ['offline'],
        where: 'id = ?',
        whereArgs: [track.id],
        limit: 1,
      );
      final isOffline =
          rows.isNotEmpty &&
          await _offlineFileExists(track.platformId, track.id);
      if (isOffline && rows.first['offline'] != 1) {
        await db!.update(
          _offlineTable(track.platformId, 'Tracks'),
          {'offline': 1},
          where: 'id = ?',
          whereArgs: [track.id],
        );
      }
      _offlineTrackCache[key] = isOffline;
      if (_offlineTrackCache.length > 2048) {
        _offlineTrackCache.remove(_offlineTrackCache.keys.first);
      }
      return isOffline;
    } else if (album != null) {
      if (db == null) return false;
      //Album
      List res = await db!.query(
        _offlineTable(album.platformId, 'Albums'),
        where: 'id == ? AND offline == 1',
        whereArgs: [album.id],
      );
      if (res.isEmpty) return false;
      return getOfflineAlbum(
        album.id!,
        platformId: album.platformId,
      ).then((offlineAlbum) => offlineAlbum != null);
    } else if (playlist != null) {
      //Playlist
      if (playlist.platformId == 'local' ||
          (playlist.id?.startsWith('local_') ?? false)) {
        final localId = playlist.id!.startsWith('local_')
            ? playlist.id!.substring(6)
            : playlist.id!;
        final localPlaylist = await localPlaylistManager.getPlaylist(localId);
        return localPlaylist?.offline ?? false;
      }

      List res = await db!.query(
        _offlineTable(playlist.platformId, 'Playlists'),
        where: 'id == ?',
        whereArgs: [playlist.id],
      );
      if (res.isEmpty) return false;
      return getOfflinePlaylist(
        playlist.id!,
        platformId: playlist.platformId,
      ).then((offlinePlaylist) => offlinePlaylist != null);
    }
    return false;
  }

  //Offline search
  Future<SearchResults> search(String query) async {
    SearchResults results = SearchResults(
      tracks: [],
      albums: [],
      artists: [],
      playlists: [],
    );
    for (final platformId in await _offlinePlatformIds()) {
      final tracksData = await db!.query(
        _offlineTable(platformId, 'Tracks'),
        where: 'offline == 1 AND title LIKE ?',
        whereArgs: ['%$query%'],
      );
      for (final trackData in tracksData) {
        final offlineTrack = await getOfflineTrack(
          trackData['id'] as String,
          platformId: platformId,
        );
        if (offlineTrack != null) results.tracks!.add(offlineTrack);
      }
      final albumsData = await db!.query(
        _offlineTable(platformId, 'Albums'),
        where: 'offline == 1 AND title LIKE ?',
        whereArgs: ['%$query%'],
        columns: ['id'],
      );
      for (final albumData in albumsData) {
        final offlineAlbum = await getOfflineAlbum(
          albumData['id'] as String,
          platformId: platformId,
        );
        if (offlineAlbum != null) results.albums!.add(offlineAlbum);
      }
      final playlistsData = await db!.query(
        _offlineTable(platformId, 'Playlists'),
        where: 'title LIKE ?',
        whereArgs: ['%$query%'],
        columns: ['id'],
      );
      for (final playlistData in playlistsData) {
        final offlinePlaylist = await getOfflinePlaylist(
          playlistData['id'] as String,
          platformId: platformId,
        );
        if (offlinePlaylist != null) results.playlists!.add(offlinePlaylist);
      }
    }
    return results;
  }

  //Sanitize filename
  String sanitize(String input) {
    RegExp sanitize = RegExp(r'[\/\\\?\%\*\:\|\"\<\>]');
    return input.replaceAll(sanitize, '');
  }

  //Generate track download path
  String _generatePath(
    Track track,
    bool private, {
    String? playlistName,
    int? playlistTrackNumber,
    bool isSingleton = false,
  }) {
    String path;
    if (private) {
      path = p.join(offlinePath!, track.platformId, track.id);
    } else {
      //Download path
      path = settings.downloadPath ?? '';

      if ((settings.playlistFolder) && playlistName != null) {
        path = p.join(path, sanitize(playlistName));
      }

      if (settings.artistFolder) path = p.join(path, '%albumArtist%');

      //Album folder / with disk number
      if (settings.albumFolder) {
        if (settings.albumDiscFolder) {
          path = p.join(
            path,
            '%album%' + ' - Disk ' + (track.diskNumber ?? 1).toString(),
          );
        } else {
          path = p.join(path, '%album%');
        }
      }
      //Final path
      path = p.join(
        path,
        isSingleton ? settings.singletonFilename : settings.downloadFilename,
      );
      //Playlist track number variable (not accessible in service)
      if (playlistTrackNumber != null) {
        path = path.replaceAll(
          '%playlistTrackNumber%',
          playlistTrackNumber.toString(),
        );
        path = path.replaceAll(
          '%0playlistTrackNumber%',
          playlistTrackNumber.toString().padLeft(2, '0'),
        );
      } else {
        path = path.replaceAll('%playlistTrackNumber%', '');
        path = path.replaceAll('%0playlistTrackNumber%', '');
      }
    }
    return path;
  }

  //Get stats for library screen
  Future<List<String>> getStats() async {
    if (db == null) {
      return ['0', '0', '0', '0 B', '0 B'];
    }
    //Free space
    double diskSpace = 0;
    if (!Platform.isAndroid && !Platform.isIOS) {
      final diskSpacelib = DiskSpace();
      await diskSpacelib.scan();
      var disks = diskSpacelib.disks;
      for (final disk in disks) {
        diskSpace += disk.availableSpace;
      }
    } else {
      try {
        diskSpace =
            (await disk_space_2.DiskSpace.getFreeDiskSpace ?? 0) * 1048576.0;
      } catch (e) {
        appLogger.warning('Error getting disk space', e);
      }
    }

    //Get offline counts
    var trackCount = 0;
    var albumCount = 0;
    var playlistCount = 0;
    for (final platformId in await _offlinePlatformIds()) {
      trackCount +=
          Sqflite.firstIntValue(
            await db!.rawQuery(
              'SELECT COUNT(*) FROM ${_offlineTable(platformId, 'Tracks')} WHERE offline == 1',
            ),
          ) ??
          0;
      albumCount +=
          Sqflite.firstIntValue(
            await db!.rawQuery(
              'SELECT COUNT(*) FROM ${_offlineTable(platformId, 'Albums')} WHERE offline == 1',
            ),
          ) ??
          0;
      playlistCount +=
          Sqflite.firstIntValue(
            await db!.rawQuery(
              'SELECT COUNT(*) FROM ${_offlineTable(platformId, 'Playlists')}',
            ),
          ) ??
          0;
    }
    //Used space
    List<FileSystemEntity> offlineStat = await Directory(
      offlinePath!,
    ).list().toList();
    int offlineSize = 0;
    for (var fs in offlineStat) {
      offlineSize += (await fs.stat()).size;
    }
    //Return in list, todo: Make into class in future
    return ([
      trackCount.toString(),
      albumCount.toString(),
      playlistCount.toString(),
      filesize(offlineSize),
      filesize((diskSpace).floor()),
    ]);
  }

  //Send settings to download service
  Future updateServiceSettings() async {
    final settingsMap = settings.toJson();
    await _downloadService.updateSettings(settingsMap);
  }

  //Check storage permission
  Future<bool> checkPermission() async {
    //if (await FileUtils.checkManageStoragePermission(
    //    openStoragePermissionSettingsDialog)) {
    if (await FileUtils.checkExternalStoragePermissions(
      openStoragePermissionSettingsDialog,
    )) {
      return true;
    } else {
      Fluttertoast.showToast(
        msg: 'Storage permission denied!'.i18n,
        toastLength: Toast.LENGTH_SHORT,
        gravity: ToastGravity.BOTTOM,
      );
      return false;
    }
  }

  //Remove download from queue/finished
  Future removeDownload(int id) async {
    await _downloadService.removeDownload(id);
  }

  //Restart failed downloads
  Future retryDownloads() async {
    //Permission
    if (!(await checkPermission())) return;
    await _downloadService.retryDownloads();
  }

  //Delete downloads by state
  Future removeDownloads(DownloadState state) async {
    // Convert local DownloadState to service DownloadState
    final serviceState = DownloadStateDart.values[state.index];
    await _downloadService.removeDownloads(serviceState);
  }
}

class Download {
  int? id;
  String? path;
  bool? private;
  String? platformId;
  String? trackId;
  String? title;
  String? image;
  int? quality;
  //Dynamic
  DownloadState? state;
  int? received;
  int? filesize;
  String? resolvedFormat;
  int? resolvedBitrate;
  bool unavailable;

  Download({
    this.id,
    this.path,
    this.private,
    this.platformId,
    this.trackId,
    this.title,
    this.image,
    this.state,
    this.received,
    this.filesize,
    this.quality,
    this.resolvedFormat,
    this.resolvedBitrate,
    this.unavailable = false,
  });

  //Get progress between 0 - 1
  double get progress {
    final total = filesize ?? 0;
    if (total <= 0) return 0.0;
    return ((received?.toDouble() ?? 0.0) / total.toDouble()).toDouble();
  }

  factory Download.fromJson(Map<dynamic, dynamic> data) {
    return Download(
      path: data['path'],
      image: data['image'],
      private: data['private'],
      platformId: data['platformId'] as String? ?? 'deezer',
      trackId: data['trackId'],
      id: data['id'],
      state: DownloadState.values[data['state']],
      title: data['title'],
      quality: data['quality'],
      received: data['received'] ?? data['downloaded'] ?? 0,
      filesize: data['filesize'] ?? data['downloaded'] ?? 0,
      resolvedFormat: data['resolvedFormat'],
      resolvedBitrate: data['resolvedBitrate'],
      unavailable: data['unavailable'] == true || data['unavailable'] == 1,
    );
  }

  //Change values from "update json"
  void updateFromJson(Map<dynamic, dynamic> data) {
    quality = data['quality'];
    received = data['received'] ?? 0;
    state = DownloadState.values[data['state']];
    filesize = data['filesize'] ?? 0;
    resolvedFormat = data['resolvedFormat'] ?? resolvedFormat;
    resolvedBitrate = data['resolvedBitrate'] ?? resolvedBitrate;
    unavailable = data['unavailable'] == true || data['unavailable'] == 1;
  }

  //Track to download JSON for service
  static Future<Map> jsonFromTrack(
    Track t,
    String path, {
    private = true,
    AudioQuality? quality,
  }) async {
    _downloadLog?.log(
      '[Download] jsonFromTrack called - trackId: ${t.id}, title: ${t.title}, private: $private',
    );

    final selectedQuality = private
        ? settings.offlineQuality
        : (quality ?? settings.downloadQuality);
    return {
      'private': private,
      'platformId': t.platformId,
      'trackId': t.id,
      'quality': selectedQuality.index,
      'title': t.title,
      'path': path,
      'image': t.albumArt?.thumb,
      'unavailable': t.unavailable == true,
    };
  }
}

//Has to be same order as in java
enum DownloadState {
  NONE,
  DOWNLOADING,
  POST,
  DONE,
  PLATFORM_ERROR,
  ERROR,
  UNAVAILABLE,
}
