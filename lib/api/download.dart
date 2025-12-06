import 'dart:async';
import 'dart:io';

import 'package:universal_disk_space/universal_disk_space.dart';
import 'package:disk_space_plus/disk_space_plus.dart';
import 'package:filesize/filesize.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../ui/toast.dart';
import '../api/deezer.dart';
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

DownloadManager downloadManager = DownloadManager();

// Shared download log instance for the download chain
DownloadLog? _downloadLog;

class DownloadManager {
  //Platform channels
  static const MethodChannel platform = MethodChannel('s.s.saturn/native');

  bool running = false;
  int queueSize = 0;

  StreamController serviceEvents = StreamController.broadcast();
  String? offlinePath;
  Database? db;

  // Dart download service
  final DownloadServiceDart _downloadService = DownloadServiceDart();

  // Local playlist manager
  late LocalPlaylistManager localPlaylistManager;

  //Start/Resume downloads
  Future start() async {
    await updateServiceSettings();
    await _downloadService.start();
  }

  //Stop/Pause downloads
  Future stop() async {
    await _downloadService.stop();
  }

  Future init() async {
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

    //Remove old DB
    File oldDbFile = File(p.join((await getDatabasesPath()), 'offline.db'));
    if (await oldDbFile.exists()) {
      await oldDbFile.delete();
    }

    String dbPath = p.join((await getDatabasesPath()), 'offline2.db');
    //Open db
    db = await openDatabase(
      dbPath,
      version: 1,
      onCreate: (Database db, int version) async {
        Batch b = db.batch();
        //Create tables, if doesn't exit
        b.execute(
          '''CREATE TABLE Tracks (
        id TEXT PRIMARY KEY, title TEXT, album TEXT, artists TEXT, duration INTEGER, albumArt TEXT, trackNumber INTEGER, offline INTEGER, lyrics TEXT, favorite INTEGER, diskNumber INTEGER, explicit INTEGER, fallback INTEGER)''',
        );
        b.execute(
          '''CREATE TABLE Albums (
        id TEXT PRIMARY KEY, title TEXT, artists TEXT, tracks TEXT, art TEXT, fans INTEGER, offline INTEGER, library INTEGER, type INTEGER, releaseDate TEXT)''',
        );
        b.execute(
          '''CREATE TABLE Artists (
        id TEXT PRIMARY KEY, name TEXT, albums TEXT, topTracks TEXT, picture TEXT, fans INTEGER, albumCount INTEGER, offline INTEGER, library INTEGER, radio INTEGER)''',
        );
        b.execute(
          '''CREATE TABLE Playlists (
        id TEXT PRIMARY KEY, title TEXT, tracks TEXT, image TEXT, duration INTEGER, userId TEXT, userName TEXT, fans INTEGER, library INTEGER, description TEXT)''',
        );
        await b.commit();
      },
    );

    //Create offline directory
    Directory? directory;
    if (Platform.isAndroid || Platform.isIOS) {
      directory = await getExternalStorageDirectory();
    } else {
      directory = await getApplicationSupportDirectory();
    }
    offlinePath = p.join((await getDatabasesPath()), 'offline/');
    await Directory(offlinePath!).create(recursive: true);
    if (directory != null) {
      offlinePath = p.join(directory.path, 'offline/');
      await Directory(offlinePath!).create(recursive: true);
    }

    //Update settings
    await updateServiceSettings();

    // Create Downloads table if it doesn't exist
    await db!.execute('''CREATE TABLE IF NOT EXISTS Downloads (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      path TEXT,
      private INTEGER,
      quality INTEGER,
      state INTEGER,
      trackId TEXT,
      md5origin TEXT,
      mediaVersion TEXT,
      title TEXT,
      image TEXT,
      trackToken TEXT,
      streamTrackId TEXT,
      downloaded INTEGER DEFAULT 0
    )''');

    // Migrate existing Downloads table to add downloaded column if missing
    try {
      await db!.execute(
        'ALTER TABLE Downloads ADD COLUMN downloaded INTEGER DEFAULT 0',
      );
    } catch (e) {
      // Column already exists, ignore error
    }

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
    _downloadLog!.log('[DownloadManager] Local playlist manager initialized');
    _downloadLog!.log('[DownloadManager] Download manager fully initialized');

    //Listen to state change event from Dart service
    _downloadService.serviceEvents.listen((e) {
      if (e['type'] == 'stateChange') {
        // Sync running state from service (which updates immediately)
        running = _downloadService.running;
        queueSize = e['queueSize'];
      }

      //Forward
      serviceEvents.add(e);
    });
  }

  //Get all downloads from db
  Future<List<Download>> getDownloads() async {
    List<Map<String, dynamic>> raw = _downloadService.getDownloads();
    return raw.map((d) => Download.fromJson(d)).toList();
  }

  //Insert track and metadata to DB
  Future _addTrackToDB(Batch batch, Track track, bool overwriteTrack) async {
    batch.insert(
      'Tracks',
      track.toSQL(off: true),
      conflictAlgorithm: overwriteTrack
          ? ConflictAlgorithm.replace
          : ConflictAlgorithm.ignore,
    );
    batch.insert(
      'Albums',
      track.album?.toSQL(off: false) as Map<String, dynamic>,
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    //Artists
    if (track.artists != null) {
      for (Artist a in track.artists!) {
        batch.insert(
          'Artists',
          a.toSQL(off: false),
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
    }
    return batch;
  }

  //Quality selector for custom quality
  Future<AudioQuality?> qualitySelect() async {
    // Try to get context from mainNavigatorKey first, then fall back to appRouter
    BuildContext? context = mainNavigatorKey.currentState?.overlay?.context;
    context ??=
        appRouter.routerDelegate.navigatorKey.currentState?.overlay?.context;

    if (context == null) {
      return null;
    }

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
            ListTile(
              title: const Text('MP3 128kbps'),
              onTap: () {
                quality = AudioQuality.MP3_128;
                Navigator.of(context).pop();
              },
            ),
            ListTile(
              title: const Text('MP3 320kbps'),
              onTap: () {
                quality = AudioQuality.MP3_320;
                Navigator.of(context).pop();
              },
            ),
            ListTile(
              title: const Text('FLAC'),
              onTap: () {
                quality = AudioQuality.FLAC;
                Navigator.of(context).pop();
              },
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
  }) async {
    _downloadLog?.log(
      '[DownloadManager] addOfflineTrack called - trackId: ${track.id}, title: ${track.title}, private: $private, isSingleton: $isSingleton',
    );

    //Permission
    if (!private && !(await checkPermission())) {
      _downloadLog?.warn(
        '[DownloadManager] addOfflineTrack - Permission denied for public download',
      );
      return false;
    }

    //Ask for quality
    AudioQuality? quality;
    if (!private && settings.downloadQuality == AudioQuality.ASK) {
      quality = await qualitySelect();
      if (quality == null) return false;
    }

    //Fetch track if missing meta
    if (track.artists == null || track.artists!.isEmpty) {
      _downloadLog?.log(
        '[DownloadManager] addOfflineTrack - Fetching full track metadata for ${track.id}',
      );
      track = await deezerAPI.track(track.id!);
      _downloadLog?.log(
        '[DownloadManager] addOfflineTrack - Track metadata fetched: ${track.title}',
      );
    }

    //Add to DB
    if (private) {
      Batch b = db!.batch();
      b = await _addTrackToDB(b, track, true);
      await b.commit();

      //Cache art
      DefaultCacheManager().getSingleFile(track.albumArt?.thumb ?? '');
      DefaultCacheManager().getSingleFile(track.albumArt?.full ?? '');
    }

    //Get path
    String path = _generatePath(track, private, isSingleton: isSingleton);
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
      '[DownloadManager] addOfflineTrack - Created download JSON: trackId=${trackJson['trackId']}, streamTrackId=${trackJson['streamTrackId']}, quality=${trackJson['quality']}',
    );
    _downloadLog?.log(
      '[DownloadManager] addOfflineTrack - md5origin: ${trackJson['md5origin']}, mediaVersion: ${trackJson['mediaVersion']}',
    );

    await _downloadService.addDownloads([Map<String, dynamic>.from(trackJson)]);
    _downloadLog?.log(
      '[DownloadManager] addOfflineTrack - Download added to service, starting...',
    );
    await start();
    _downloadLog?.log(
      '[DownloadManager] addOfflineTrack - Complete for track ${track.id}',
    );
    return true;
  }

  Future addOfflineAlbum(Album album, {private = true}) async {
    _downloadLog?.log(
      '[DownloadManager] addOfflineAlbum called - albumId: ${album.id}, title: ${album.title}, private: $private',
    );

    //Permission
    if (!private && !(await checkPermission())) {
      _downloadLog?.warn(
        '[DownloadManager] addOfflineAlbum - Permission denied for public download',
      );
      return;
    }

    //Ask for quality
    AudioQuality? quality;
    if (!private && settings.downloadQuality == AudioQuality.ASK) {
      quality = await qualitySelect();
      if (quality == null) return false;
    }

    //Get from API if no tracks
    if (album.tracks == null || album.tracks!.isEmpty) {
      _downloadLog?.log(
        '[DownloadManager] addOfflineAlbum - Fetching album tracks from API for ${album.id}',
      );
      album = await deezerAPI.album(album.id ?? '');
      _downloadLog?.log(
        '[DownloadManager] addOfflineAlbum - Fetched ${album.tracks?.length ?? 0} tracks',
      );
    }

    //Add to DB
    if (private) {
      //Cache art
      DefaultCacheManager().getSingleFile(album.art?.thumb ?? '');
      DefaultCacheManager().getSingleFile(album.art?.full ?? '');

      Batch b = db!.batch();
      b.insert(
        'Albums',
        album.toSQL(off: true),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      for (Track t in album.tracks ?? []) {
        b = await _addTrackToDB(b, t, false);
      }
      await b.commit();
    }

    //Create downloads
    List<Map> out = [];
    for (Track t in (album.tracks ?? [])) {
      out.add(
        await Download.jsonFromTrack(
          t,
          _generatePath(t, private),
          private: private,
          quality: quality,
        ),
      );
    }
    await _downloadService.addDownloads(out);
    await start();
  }

  Future addOfflinePlaylist(
    Playlist playlist, {
    private = true,
    AudioQuality? quality,
  }) async {
    _downloadLog?.log(
      '[DownloadManager] addOfflinePlaylist called - playlistId: ${playlist.id}, title: ${playlist.title}, private: $private, trackCount: ${playlist.trackCount}',
    );

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
      quality = await qualitySelect();
      if (quality == null) return false;
    }

    //Get tracks if missing
    if ((playlist.tracks == null) ||
        (playlist.tracks?.length ?? 0) < (playlist.trackCount ?? 0)) {
      _downloadLog?.log(
        '[DownloadManager] addOfflinePlaylist - Fetching full playlist from API for ${playlist.id}',
      );
      playlist = await deezerAPI.fullPlaylist(playlist.id ?? '');
      _downloadLog?.log(
        '[DownloadManager] addOfflinePlaylist - Fetched ${playlist.tracks?.length ?? 0} tracks',
      );
    }

    //Add to DB
    if (private) {
      Batch b = db!.batch();
      b.insert(
        'Playlists',
        playlist.toSQL(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      for (Track t in (playlist.tracks ?? [])) {
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
      out.add(
        await Download.jsonFromTrack(
          t,
          _generatePath(
            t,
            private,
            playlistName: playlist.title,
            playlistTrackNumber: i,
          ),
          private: private,
          quality: quality,
        ),
      );
    }
    await _downloadService.addDownloads(out);
    await start();
  }

  //Get track and meta from offline DB
  Future<Track?> getOfflineTrack(
    String id, {
    Album? album,
    List<Artist>? artists,
  }) async {
    List tracks = await db!.query('Tracks', where: 'id == ?', whereArgs: [id]);
    if (tracks.isEmpty) return null;
    Track track = Track.fromSQL(tracks[0]);

    //Get album
    if (album == null) {
      List rawAlbums = await db!.query(
        'Albums',
        where: 'id == ?',
        whereArgs: [track.album?.id],
      );
      if (rawAlbums.isNotEmpty) track.album = Album.fromSQL(rawAlbums[0]);
    } else {
      track.album = album;
    }

    //Get artists
    if (artists == null) {
      List<Artist> newArtists = [];
      for (Artist artist in (track.artists ?? [])) {
        List rawArtist = await db!.query(
          'Artists',
          where: 'id == ?',
          whereArgs: [artist.id],
        );
        if (rawArtist.isNotEmpty) newArtists.add(Artist.fromSQL(rawArtist[0]));
      }
      if (newArtists.isNotEmpty) track.artists = newArtists;
    } else {
      track.artists = artists;
    }
    return track;
  }

  //Get offline library tracks
  Future<List<Track>> getOfflineTracks() async {
    List rawTracks = await db!.query(
      'Tracks',
      where: 'library == 1 AND offline == 1',
      columns: ['id'],
    );
    List<Track> out = [];
    //Load track meta individually
    for (Map rawTrack in rawTracks) {
      var offlineTrack = await getOfflineTrack(rawTrack['id']);
      if (offlineTrack != null) out.add(offlineTrack);
    }
    return out;
  }

  //Get all offline available tracks
  Future<List<Track>> allOfflineTracks() async {
    List rawTracks = await db!.query(
      'Tracks',
      where: 'offline == 1',
      columns: ['id'],
    );
    List<Track> out = [];
    //Load track meta individually
    for (Map rawTrack in rawTracks) {
      var offlineTrack = await getOfflineTrack(rawTrack['id']);
      if (offlineTrack != null) out.add(offlineTrack);
    }
    return out;
  }

  //Get all offline albums
  Future<List<Album>> getOfflineAlbums() async {
    List rawAlbums = await db!.query(
      'Albums',
      where: 'offline == 1',
      columns: ['id'],
    );
    List<Album> out = [];
    //Load each album
    for (Map rawAlbum in rawAlbums) {
      var offlineAlbum = await getOfflineAlbum(rawAlbum['id']);
      if (offlineAlbum != null) out.add(offlineAlbum);
    }
    return out;
  }

  //Get offline album with meta
  Future<Album?> getOfflineAlbum(String id) async {
    List rawAlbums = await db!.query(
      'Albums',
      where: 'id == ?',
      whereArgs: [id],
    );
    if (rawAlbums.isEmpty) return null;
    Album album = Album.fromSQL(rawAlbums[0]);

    List<Track> tracks = [];
    //Load tracks
    for (int i = 0; i < (album.tracks?.length ?? 0); i++) {
      var offlineTrack = await getOfflineTrack(album.tracks![i].id!);
      if (offlineTrack != null) tracks.add(offlineTrack);
    }
    album.tracks = tracks;
    //Load artists
    List<Artist> artists = [];
    for (int i = 0; i < (album.artists?.length ?? 0); i++) {
      artists.add(
        (await getOfflineArtist(album.artists![i].id ?? '')) ??
            album.artists![i],
      );
    }
    album.artists = artists;

    return album;
  }

  //Get offline artist METADATA, not tracks
  Future<Artist?> getOfflineArtist(String id) async {
    List rawArtists = await db!.query(
      'Artists',
      where: 'id == ?',
      whereArgs: [id],
    );
    if (rawArtists.isEmpty) return null;
    return Artist.fromSQL(rawArtists[0]);
  }

  //Get all offline playlists
  Future<List<Playlist>> getOfflinePlaylists() async {
    List rawPlaylists = await db!.query('Playlists', columns: ['id']);
    List<Playlist> out = [];
    for (Map rawPlaylist in rawPlaylists) {
      var offlinePlayList = await getOfflinePlaylist(rawPlaylist['id']);
      if (offlinePlayList != null) out.add(offlinePlayList);
    }
    return out;
  }

  //Get offline playlist
  Future<Playlist?> getOfflinePlaylist(String id) async {
    List rawPlaylists = await db!.query(
      'Playlists',
      where: 'id == ?',
      whereArgs: [id],
    );
    if (rawPlaylists.isEmpty) return null;

    Playlist playlist = Playlist.fromSQL(rawPlaylists[0]);
    //Load tracks
    List<Track> tracks = [];
    if (playlist.tracks != null) {
      for (Track t in playlist.tracks!) {
        var offlineTrack = await getOfflineTrack(t.id!);
        if (offlineTrack != null) tracks.add(offlineTrack);
      }
    }
    playlist.tracks = tracks;
    return playlist;
  }

  Future removeOfflineTracks(List<Track> tracks) async {
    for (Track t in tracks) {
      //Check if library
      List rawTrack = await db!.query(
        'Tracks',
        where: 'id == ?',
        whereArgs: [t.id],
        columns: ['favorite'],
      );
      if (rawTrack.isNotEmpty) {
        //Count occurrences in playlists and albums
        List albums = await db!.rawQuery(
          'SELECT (id) FROM Albums WHERE tracks LIKE "%${t.id}%"',
        );
        List playlists = await db!.rawQuery(
          'SELECT (id) FROM Playlists WHERE tracks LIKE "%${t.id}%"',
        );
        if (albums.length + playlists.length == 0 &&
            rawTrack[0]['favorite'] == 0) {
          //Safe to remove
          await db!.delete('Tracks', where: 'id == ?', whereArgs: [t.id]);
        } else {
          await db!.update(
            'Tracks',
            {'offline': 0},
            where: 'id == ?',
            whereArgs: [t.id],
          );
        }
      }

      //Remove file
      try {
        File(p.join(offlinePath!, t.id)).delete();
      } catch (e) {
        Logger.root.severe('Error deleting offline track: ${t.id}', e);
      }
    }
  }

  Future removeOfflineAlbum(String id) async {
    //Get album
    List rawAlbums = await db!.query(
      'Albums',
      where: 'id == ?',
      whereArgs: [id],
    );
    if (rawAlbums.isEmpty) return;
    Album album = Album.fromSQL(rawAlbums[0]);
    //Remove album
    await db!.delete('Albums', where: 'id == ?', whereArgs: [id]);
    //Remove tracks
    await removeOfflineTracks(album.tracks!);
  }

  Future removeOfflinePlaylist(String id) async {
    //Fetch playlist
    List rawPlaylists = await db!.query(
      'Playlists',
      where: 'id == ?',
      whereArgs: [id],
    );
    if (rawPlaylists.isEmpty) return;
    Playlist playlist = Playlist.fromSQL(rawPlaylists[0]);
    //Remove playlist
    await db!.delete('Playlists', where: 'id == ?', whereArgs: [id]);
    await removeOfflineTracks(playlist.tracks!);
  }

  //Check if album, track or playlist is offline
  Future<bool> checkOffline({
    Album? album,
    Track? track,
    Playlist? playlist,
  }) async {
    if (track != null) {
      //Track
      List res = await db!.query(
        'Tracks',
        where: 'id == ? AND offline == 1',
        whereArgs: [track.id],
      );
      if (res.isEmpty) return false;
      return true;
    } else if (album != null) {
      //Album
      List res = await db!.query(
        'Albums',
        where: 'id == ? AND offline == 1',
        whereArgs: [album.id],
      );
      if (res.isEmpty) return false;
      return true;
    } else if (playlist != null) {
      //Playlist
      List res = await db!.query(
        'Playlists',
        where: 'id == ?',
        whereArgs: [playlist.id],
      );
      if (res.isEmpty) return false;
      return true;
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
    //Tracks
    List tracksData = await db!.rawQuery(
      'SELECT * FROM Tracks WHERE offline == 1 AND title like "%$query%"',
    );
    for (Map trackData in tracksData) {
      var offlineTrack = await getOfflineTrack(trackData['id']);
      if (offlineTrack != null) results.tracks!.add(offlineTrack);
    }
    //Albums
    List albumsData = await db!.rawQuery(
      'SELECT (id) FROM Albums WHERE offline == 1 AND title like "%$query%"',
    );
    for (Map rawAlbum in albumsData) {
      var offlineAlbum = await getOfflineAlbum(rawAlbum['id']);
      if (offlineAlbum != null) results.albums!.add(offlineAlbum);
    }
    //Playlists
    List playlists = await db!.rawQuery(
      'SELECT * FROM Playlists WHERE title like "%$query%"',
    );
    for (Map playlist in playlists) {
      var offlinePlaylist = await getOfflinePlaylist(playlist['id']);
      if (offlinePlaylist != null) results.playlists!.add(offlinePlaylist);
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
      path = p.join(offlinePath!, track.id);
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
      diskSpace = (await DiskSpacePlus().getFreeDiskSpace ?? 0) * 1000000;
    }
    //Get offline counts
    int? trackCount = Sqflite.firstIntValue(
      (await db!.rawQuery('SELECT COUNT(*) FROM Tracks WHERE offline == 1')),
    );
    int? albumCount = Sqflite.firstIntValue(
      (await db!.rawQuery('SELECT COUNT(*) FROM Albums WHERE offline == 1')),
    );
    int? playlistCount = Sqflite.firstIntValue(
      (await db!.rawQuery('SELECT COUNT(*) FROM Playlists')),
    );
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
  String? trackId;
  String? streamTrackId;
  String? trackToken;
  String? md5origin;
  String? mediaVersion;
  String? title;
  String? image;
  int? quality;
  //Dynamic
  DownloadState? state;
  int? received;
  int? filesize;

  Download({
    this.id,
    this.path,
    this.private,
    this.trackId,
    this.streamTrackId,
    this.trackToken,
    this.md5origin,
    this.mediaVersion,
    this.title,
    this.image,
    this.state,
    this.received,
    this.filesize,
    this.quality,
  });

  //Get progress between 0 - 1
  double get progress {
    return ((received?.toDouble() ?? 0.0) / (filesize?.toDouble() ?? 1.0))
        .toDouble();
  }

  factory Download.fromJson(Map<dynamic, dynamic> data) {
    return Download(
      path: data['path'],
      image: data['image'],
      private: data['private'],
      trackId: data['trackId'],
      id: data['id'],
      state: DownloadState.values[data['state']],
      title: data['title'],
      quality: data['quality'],
    );
  }

  //Change values from "update json"
  void updateFromJson(Map<dynamic, dynamic> data) {
    quality = data['quality'];
    received = data['received'] ?? 0;
    state = DownloadState.values[data['state']];
    //Prevent null division later
    filesize = ((data['filesize'] ?? 0) <= 0) ? 1 : (data['filesize'] ?? 1);
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

    //Get download info
    if (t.playbackDetails?.isEmpty ?? true) {
      _downloadLog?.log(
        '[Download] jsonFromTrack - playbackDetails empty, fetching track from API',
      );
      t = await deezerAPI.track(t.id ?? '');
      _downloadLog?.log(
        '[Download] jsonFromTrack - Track fetched, playbackDetails: ${t.playbackDetails?.length ?? 0} items',
      );
    }

    // Select playbackDetails for audio stream
    List<dynamic>? playbackDetails =
        t.playbackDetailsFallback?.isNotEmpty == true
        ? t.playbackDetailsFallback
        : t.playbackDetails;

    _downloadLog?.log(
      '[Download] jsonFromTrack - Using ${t.playbackDetailsFallback?.isNotEmpty == true ? "fallback" : "primary"} playbackDetails',
    );
    _downloadLog?.log(
      '[Download] jsonFromTrack - md5origin: ${playbackDetails?[0]}, mediaVersion: ${playbackDetails?[1]}, trackToken length: ${(playbackDetails?[2] as String?)?.length ?? 0}',
    );

    if (playbackDetails == null || playbackDetails.isEmpty) {
      _downloadLog?.error(
        '[Download] jsonFromTrack - ERROR: playbackDetails is null or empty for track ${t.id}',
      );
    }
    if (playbackDetails?[0] == null) {
      _downloadLog?.error(
        '[Download] jsonFromTrack - ERROR: md5origin is null for track ${t.id}',
      );
    }
    if (playbackDetails?[2] == null) {
      _downloadLog?.error(
        '[Download] jsonFromTrack - ERROR: trackToken is null for track ${t.id}',
      );
    }

    return {
      'private': private,
      'trackId': t.id,
      'streamTrackId': t.fallback?.id ?? t.id,
      'md5origin': playbackDetails?[0],
      'mediaVersion': playbackDetails?[1],
      'trackToken': playbackDetails?[2],
      'quality': private
          ? settings.getQualityInt(settings.offlineQuality)
          : settings.getQualityInt((quality ?? settings.downloadQuality)),
      'title': t.title,
      'path': path,
      'image': t.albumArt?.thumb,
    };
  }
}

//Has to be same order as in java
enum DownloadState { NONE, DOWNLOADING, POST, DONE, DEEZER_ERROR, ERROR }
