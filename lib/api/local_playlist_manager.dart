import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:sqflite/sqflite.dart';

import 'definitions.dart';

class LocalPlaylistManager {
  Database? db;

  Future<void> init(Database database) async {
    Logger.root.info('Initializing LocalPlaylistManager');
    db = database;
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
        "SELECT name FROM sqlite_master WHERE type='table' AND name='LocalPlaylists'"
      );
      
      if (tables.isEmpty) {
        // Table doesn't exist, create it
        Logger.root.info('Table does not exist, creating new table');
        await db!.execute(
          '''CREATE TABLE LocalPlaylists (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            description TEXT,
            trackIds TEXT,
            createdAt TEXT,
            updatedAt TEXT
          )''',
        );
      } else {
        // Table exists, check if trackIds column exists
        Logger.root.info('Table exists, checking schema');
        final columns = await db!.rawQuery('PRAGMA table_info(LocalPlaylists)');
        final columnNames = columns.map((c) => c['name'] as String).toList();
        
        if (!columnNames.contains('trackIds')) {
          Logger.root.info('trackIds column missing, adding it');
          await db!.execute('ALTER TABLE LocalPlaylists ADD COLUMN trackIds TEXT');
        }
        
        if (!columnNames.contains('createdAt')) {
          Logger.root.info('createdAt column missing, adding it');
          await db!.execute('ALTER TABLE LocalPlaylists ADD COLUMN createdAt TEXT');
        }
        
        if (!columnNames.contains('updatedAt')) {
          Logger.root.info('updatedAt column missing, adding it');
          await db!.execute('ALTER TABLE LocalPlaylists ADD COLUMN updatedAt TEXT');
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
    Logger.root.info('Playlist inserted successfully');
    return playlist;
  }

  Future<List<LocalPlaylist>> getAllPlaylists() async {
    Logger.root.info('getAllPlaylists called');
    if (db == null) {
      Logger.root.severe('Database is null in getAllPlaylists');
      throw Exception('Database not initialized');
    }

    final maps = await db!.query('LocalPlaylists');
    Logger.root.info('Query returned ${maps.length} playlists');
    final result = maps.map((map) => LocalPlaylist.fromSQL(map)).toList();
    Logger.root.info('Converted to ${result.length} LocalPlaylist objects');
    return result;
  }

  Future<LocalPlaylist?> getPlaylist(String id) async {
    if (db == null) throw Exception('Database not initialized');

    final maps = await db!.query(
      'LocalPlaylists',
      where: 'id = ?',
      whereArgs: [id],
    );

    if (maps.isEmpty) return null;
    return LocalPlaylist.fromSQL(maps.first);
  }

  Future<void> updatePlaylist(LocalPlaylist playlist) async {
    if (db == null) throw Exception('Database not initialized');

    final updated = playlist.copyWith(updatedAt: DateTime.now());
    await db!.update(
      'LocalPlaylists',
      updated.toSQL(),
      where: 'id = ?',
      whereArgs: [playlist.id],
    );
  }

  Future<void> deletePlaylist(String id) async {
    if (db == null) throw Exception('Database not initialized');

    await db!.delete(
      'LocalPlaylists',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> addTracksToPlaylist(String playlistId, List<String> trackIds) async {
    if (db == null) throw Exception('Database not initialized');

    final playlist = await getPlaylist(playlistId);
    if (playlist == null) throw Exception('Playlist not found');

    final updated = playlist.copyWith(
      trackIds: [...playlist.trackIds, ...trackIds],
      updatedAt: DateTime.now(),
    );
    await updatePlaylist(updated);
  }

  Future<void> removeTrackFromPlaylist(String playlistId, String trackId) async {
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

  Future<LocalPlaylist> importPlaylist(String filePath) async {
    final file = File(filePath);
    final json = jsonDecode(await file.readAsString());
    return LocalPlaylist.fromExportJson(json);
  }

  Future<void> exportAllPlaylists(String filePath) async {
    final playlists = await getAllPlaylists();
    final json = jsonEncode(
      playlists.map((p) => p.toExportJson()).toList(),
    );
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
