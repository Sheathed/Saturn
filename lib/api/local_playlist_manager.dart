import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:logging/logging.dart';
import 'package:sqflite/sqflite.dart';

import 'definitions.dart';

/// Platform-qualified reference stored in a local playlist. Plain IDs are
/// legacy entries from the original Deezer-only playlist format.
class LocalPlaylistTrackReference {
  const LocalPlaylistTrackReference({
    required this.platformId,
    required this.trackId,
  });

  final String platformId;
  final String trackId;

  factory LocalPlaylistTrackReference.parse(String storedId) {
    final separator = storedId.indexOf(':');
    if (separator < 0) {
      return LocalPlaylistTrackReference(
        platformId: 'deezer',
        trackId: storedId,
      );
    }
    return LocalPlaylistTrackReference(
      platformId: storedId.substring(0, separator),
      trackId: storedId.substring(separator + 1),
    );
  }

  String get storageKey => '$platformId:$trackId';
}

class LocalPlaylistManager {
  Database? db;
  List<LocalPlaylist>? _allPlaylistsCache;
  Future<List<LocalPlaylist>>? _allPlaylistsLoad;

  void _invalidatePlaylistsCache() {
    _allPlaylistsCache = null;
    _allPlaylistsLoad = null;
  }

  Future<void> init(Database database) async {
    Logger.root.info('Initializing LocalPlaylistManager');
    db = database;
    _invalidatePlaylistsCache();
    await _createTable();
    Logger.root.info('LocalPlaylistManager initialized');
  }

  Future<void> _createTable() async {
    if (db == null) {
      Logger.root.warning('Database is null in _createTable');
      return;
    }
    try {
      Logger.root.info('Creating LocalPlaylists table');

      // Check if table exists
      final tables = await db!.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='LocalPlaylists'",
      );

      if (tables.isEmpty) {
        // Table doesn't exist, create it
        Logger.root.info('Table does not exist, creating new table');
        await db!.execute('''CREATE TABLE LocalPlaylists (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            description TEXT,
            trackIds TEXT,
            createdAt TEXT,
            updatedAt TEXT,
            offline INTEGER DEFAULT 0,
            mosaicImages TEXT
          )''');
      } else {
        // Table exists, check if trackIds column exists
        Logger.root.info('Table exists, checking schema');
        final columns = await db!.rawQuery('PRAGMA table_info(LocalPlaylists)');
        final columnNames = columns.map((c) => c['name'] as String).toList();

        if (!columnNames.contains('trackIds')) {
          Logger.root.info('trackIds column missing, adding it');
          await db!.execute(
            'ALTER TABLE LocalPlaylists ADD COLUMN trackIds TEXT',
          );
        }

        if (!columnNames.contains('createdAt')) {
          Logger.root.info('createdAt column missing, adding it');
          await db!.execute(
            'ALTER TABLE LocalPlaylists ADD COLUMN createdAt TEXT',
          );
        }

        if (!columnNames.contains('updatedAt')) {
          Logger.root.info('updatedAt column missing, adding it');
          await db!.execute(
            'ALTER TABLE LocalPlaylists ADD COLUMN updatedAt TEXT',
          );
        }

        if (!columnNames.contains('offline')) {
          Logger.root.info('offline column missing, adding it');
          await db!.execute(
            'ALTER TABLE LocalPlaylists ADD COLUMN offline INTEGER DEFAULT 0',
          );
        }

        if (!columnNames.contains('mosaicImages')) {
          Logger.root.info('mosaicImages column missing, adding it');
          await db!.execute(
            'ALTER TABLE LocalPlaylists ADD COLUMN mosaicImages TEXT',
          );
        }
      }

      Logger.root.info('LocalPlaylists table ready');
    } catch (e) {
      Logger.root.severe('Error creating table: $e');
    }
  }

  Future<LocalPlaylist> createPlaylist({
    required String title,
    String? description,
    List<String> trackIds = const [],
  }) async {
    Logger.root.info('createPlaylist called with title: $title');
    if (db == null) {
      Logger.root.severe('Database is null in createPlaylist');
      throw Exception('Database not initialized');
    }

    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final now = DateTime.now();

    final playlist = LocalPlaylist(
      id: id,
      title: title,
      description: description,
      trackIds: trackIds,
      createdAt: now,
      updatedAt: now,
    );

    Logger.root.info('Inserting playlist with id: $id');
    final sqlData = playlist.toSQL();
    Logger.root.info('SQL data: $sqlData');

    await db!.insert('LocalPlaylists', sqlData);
    _invalidatePlaylistsCache();
    Logger.root.info('Playlist inserted successfully');
    return playlist;
  }

  Future<List<LocalPlaylist>> getAllPlaylists() async {
    if (db == null) {
      Logger.root.severe('Database is null in getAllPlaylists');
      throw Exception('Database not initialized');
    }
    final cached = _allPlaylistsCache;
    if (cached != null) return List<LocalPlaylist>.from(cached);

    final inFlight = _allPlaylistsLoad;
    if (inFlight != null) {
      return List<LocalPlaylist>.from(await inFlight);
    }

    Logger.root.info('getAllPlaylists called');
    final load = () async {
      final maps = await db!.query('LocalPlaylists');
      Logger.root.info('Query returned ${maps.length} playlists');
      final result = maps.map((map) => LocalPlaylist.fromSQL(map)).toList();
      Logger.root.info('Converted to ${result.length} LocalPlaylist objects');
      return result;
    }();
    _allPlaylistsLoad = load;
    try {
      final result = await load;
      if (identical(_allPlaylistsLoad, load)) _allPlaylistsCache = result;
      return List<LocalPlaylist>.from(result);
    } finally {
      if (identical(_allPlaylistsLoad, load)) _allPlaylistsLoad = null;
    }
  }

  Future<LocalPlaylist?> getPlaylist(String id) async {
    if (db == null) throw Exception('Database not initialized');

    final cleanId = id.startsWith('local_') ? id.substring(6) : id;
    final maps = await db!.query(
      'LocalPlaylists',
      where: 'id = ?',
      whereArgs: [cleanId],
    );

    if (maps.isEmpty) return null;
    return LocalPlaylist.fromSQL(maps.first);
  }

  Future<void> updatePlaylist(LocalPlaylist playlist) async {
    if (db == null) throw Exception('Database not initialized');

    final cleanId = playlist.id.startsWith('local_')
        ? playlist.id.substring(6)
        : playlist.id;
    final updated = playlist.copyWith(updatedAt: DateTime.now());
    final sqlData = updated.toSQL();
    sqlData['id'] = cleanId;
    await db!.update(
      'LocalPlaylists',
      sqlData,
      where: 'id = ?',
      whereArgs: [cleanId],
    );
    _invalidatePlaylistsCache();
  }

  Future<void> deletePlaylist(String id) async {
    if (db == null) throw Exception('Database not initialized');

    final cleanId = id.startsWith('local_') ? id.substring(6) : id;
    await db!.delete('LocalPlaylists', where: 'id = ?', whereArgs: [cleanId]);
    _invalidatePlaylistsCache();
  }

  Future<void> addTracksToPlaylist(
    String playlistId,
    List<String> trackIds,
  ) async {
    if (db == null) throw Exception('Database not initialized');

    final playlist = await getPlaylist(playlistId);
    if (playlist == null) throw Exception('Playlist not found');

    final newTrackIds = trackIds
        .where((id) => !playlist.trackIds.contains(id))
        .toList();
    if (newTrackIds.isEmpty) return;

    final updated = playlist.copyWith(
      trackIds: [...playlist.trackIds, ...newTrackIds],
      updatedAt: DateTime.now(),
    );
    await updatePlaylist(updated);
  }

  Future<void> removeTrackFromPlaylist(
    String playlistId,
    String trackId,
  ) async {
    if (db == null) throw Exception('Database not initialized');

    final playlist = await getPlaylist(playlistId);
    if (playlist == null) throw Exception('Playlist not found');

    final updated = playlist.copyWith(
      trackIds: playlist.trackIds.where((id) => id != trackId).toList(),
      updatedAt: DateTime.now(),
    );
    await updatePlaylist(updated);
  }

  Future<void> exportPlaylist(LocalPlaylist playlist, String filePath) async {
    final file = File(filePath);
    final json = jsonEncode(playlist.toExportJson());
    await file.writeAsString(json);
  }

  /// Opens the platform save dialog and exports a local playlist as JSON.
  /// Returns the chosen path, or null when the user cancels.
  Future<String?> exportPlaylistWithPicker(
    LocalPlaylist playlist, {
    String dialogTitle = 'Export Playlist',
  }) async {
    final safeTitle = playlist.title
        .replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    final fileName =
        '${safeTitle.isEmpty ? 'playlist' : safeTitle}_${DateTime.now().millisecondsSinceEpoch}.json';
    final bytes = Uint8List.fromList(
      utf8.encode(jsonEncode(playlist.toExportJson())),
    );

    final result = await FilePicker.saveFile(
      dialogTitle: dialogTitle,
      fileName: fileName,
      bytes: bytes,
    );
    return result?.toString();
  }

  Future<LocalPlaylist> importPlaylist(String filePath) async {
    final file = File(filePath);
    final json = jsonDecode(await file.readAsString());
    return LocalPlaylist.fromExportJson(json);
  }

  Future<void> exportAllPlaylists(String filePath) async {
    final playlists = await getAllPlaylists();
    final json = jsonEncode(playlists.map((p) => p.toExportJson()).toList());
    final file = File(filePath);
    await file.writeAsString(json);
  }

  Future<void> importAllPlaylists(String filePath) async {
    final file = File(filePath);
    final json = jsonDecode(await file.readAsString()) as List;

    for (final item in json) {
      final playlist = LocalPlaylist.fromExportJson(item);
      await db!.insert('LocalPlaylists', playlist.toSQL());
    }
    _invalidatePlaylistsCache();
  }
}

extension LocalPlaylistCopy on LocalPlaylist {
  LocalPlaylist copyWith({
    String? id,
    String? title,
    String? description,
    List<String>? trackIds,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return LocalPlaylist(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      trackIds: trackIds ?? this.trackIds,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
