import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:json_annotation/json_annotation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../api/definitions.dart';
import '../platform/platform_manager.dart';

part 'cache.g.dart';

late Cache cache;

//Cache for miscellaneous things
@JsonSerializable()
class Cache {
  //Map of platform ID to ID's of tracks that are in library
  @JsonKey(defaultValue: {})
  Map<String, List<String>> platformLibraryTracks = {};

  //Map of platform ID to ID's of playlists that are in library
  @JsonKey(defaultValue: {})
  Map<String, List<String>> platformLibraryPlaylists = {};

  //Track ID of logged track, to prevent duplicates
  @JsonKey(includeFromJson: false)
  @JsonKey(includeToJson: false)
  String? loggedTrackId;

  @JsonKey(defaultValue: [])
  List<Track> history = [];

  /// Listen events that could not be submitted while the app was offline.
  @JsonKey(defaultValue: [])
  List<Map<String, dynamic>> pendingListenLogs = [];

  //All sorting cached
  @JsonKey(defaultValue: [])
  List<Sorting> sorts = [];

  @JsonKey(defaultValue: 1.0)
  double podcastPlaybackSpeed = 1.0;

  //Sleep timer
  @JsonKey(includeFromJson: false)
  @JsonKey(includeToJson: false)
  DateTime? sleepTimerTime;
  @JsonKey(includeFromJson: false)
  @JsonKey(includeToJson: false)
  StreamSubscription? sleepTimer;

  //Search history
  @JsonKey(
    name: 'searchHistory2',
    toJson: _searchHistoryToJson,
    fromJson: _searchHistoryFromJson,
  )
  List<SearchHistoryItem>? searchHistory;

  //If download threads warning was shown
  @JsonKey(defaultValue: false)
  bool threadsWarning = false;

  //Last time update check
  @JsonKey(defaultValue: 0)
  int? lastUpdateCheck;

  @JsonKey(includeFromJson: false)
  @JsonKey(includeToJson: false)
  bool wakelock = false;

  Cache({
    Map<String, List<String>>? platformLibraryTracks,
    Map<String, List<String>>? platformLibraryPlaylists,
  }) {
    if (platformLibraryTracks != null) {
      this.platformLibraryTracks = platformLibraryTracks;
    }
    if (platformLibraryPlaylists != null) {
      this.platformLibraryPlaylists = platformLibraryPlaylists;
    }
  }

  // Get active platform's library tracks list, initializing if necessary
  @JsonKey(includeFromJson: false, includeToJson: false)
  List<String> get activeLibraryTracks {
    final pid = PlatformManager.instance.activePlatformId;
    return platformLibraryTracks.putIfAbsent(pid, () => <String>[]);
  }

  set activeLibraryTracks(List<String> tracks) {
    final pid = PlatformManager.instance.activePlatformId;
    platformLibraryTracks[pid] = tracks;
  }

  //Wrapper to test if track is favorite against cache
  bool checkTrackFavorite(Track t) {
    final tracks = platformLibraryTracks[t.platformId];
    // Once a platform's library is cached, that list is authoritative. This
    // lets an optimistic favorite change override stale Track.favorite data.
    if (tracks != null) return tracks.contains(t.id);
    return t.favorite ?? false;
  }

  /// Updates a favorite track ID in the cache belonging to its own platform.
  void updateTrackFavorite(Track track, {required bool favorite}) {
    final id = track.id;
    if (id == null || id.isEmpty) return;
    final tracks = platformLibraryTracks.putIfAbsent(
      track.platformId,
      () => <String>[],
    );
    if (favorite) {
      if (!tracks.contains(id)) tracks.add(id);
    } else {
      tracks.removeWhere((trackId) => trackId == id);
    }
  }

  // Get active platform's library playlists list, initializing if necessary
  @JsonKey(includeFromJson: false, includeToJson: false)
  List<String> get activeLibraryPlaylists {
    final pid = PlatformManager.instance.activePlatformId;
    return platformLibraryPlaylists.putIfAbsent(pid, () => <String>[]);
  }

  set activeLibraryPlaylists(List<String> playlists) {
    final pid = PlatformManager.instance.activePlatformId;
    platformLibraryPlaylists[pid] = playlists;
  }

  //Wrapper to test if playlist is favorite against cache
  bool checkPlaylistFavorite(Playlist p) {
    final playlists = platformLibraryPlaylists[p.platformId];
    return playlists?.contains(p.id) ?? (p.library == true);
  }

  //Add to history
  void addToSearchHistory(dynamic item) async {
    searchHistory ??= [];

    // Remove duplicate
    int i = searchHistory!.indexWhere((e) => e.data.id == item.id);
    if (i != -1) {
      searchHistory!.removeAt(i);
    }

    if (item is Track) {
      searchHistory!.add(SearchHistoryItem(item, SearchHistoryItemType.TRACK));
    }
    if (item is Album) {
      searchHistory!.add(SearchHistoryItem(item, SearchHistoryItemType.ALBUM));
    }
    if (item is Artist) {
      searchHistory!.add(SearchHistoryItem(item, SearchHistoryItemType.ARTIST));
    }
    if (item is Playlist) {
      searchHistory!.add(
        SearchHistoryItem(item, SearchHistoryItemType.PLAYLIST),
      );
    }
    if (item is LiveRadio) {
      searchHistory!.add(SearchHistoryItem(item, SearchHistoryItemType.RADIO));
    }

    if (searchHistory!.length > 50) {
      searchHistory!.removeAt(0);
    }

    await save();
  }

  //Save, load
  static Future<String> getPath() async {
    return p.join(
      (await getApplicationSupportDirectory()).path,
      'metacache.json',
    );
  }

  static Future wipe() async {
    String cacheFilePath = await Cache.getPath();
    if (await File(cacheFilePath).exists()) {
      await File(cacheFilePath).delete();
    }
  }

  static Future<Cache> load() async {
    File file = File(await Cache.getPath());
    //Doesn't exist, create new
    if (!(await file.exists())) {
      Cache c = Cache();
      await c.save();
      return c;
    }
    Map<String, dynamic> cacheJson = {};
    String fileContent = await file.readAsString();
    if (fileContent.isNotEmpty) {
      cacheJson = jsonDecode(fileContent);
    }
    return Cache.fromJson(cacheJson);
  }

  bool _saving = false;
  bool _saveAgain = false;
  Timer? _saveDebounce;

  /// Schedules a save shortly in the future, collapsing bursts of requests
  /// (e.g. rapid track skips) into one serialization + write.
  void scheduleSave({Duration delay = const Duration(seconds: 3)}) {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(delay, () {
      _saveDebounce = null;
      unawaited(save());
    });
  }

  /// Persists the cache. Concurrent calls are coalesced into one follow-up
  /// write so writes never overlap, and the file is replaced atomically.
  Future save() async {
    _saveAgain = true;
    if (_saving) return;
    _saving = true;
    try {
      while (_saveAgain) {
        _saveAgain = false;
        try {
          final path = await Cache.getPath();
          final tmp = File('$path.tmp');
          await tmp.writeAsString(
            jsonEncode(toJson(), toEncodable: _encodeJsonModel),
            flush: true,
          );
          await tmp.rename(path);
        } catch (e, stack) {
          // A failed save must not wedge future saves.
          // ignore: avoid_print
          print('Could not save cache: $e\n$stack');
        }
      }
    } finally {
      _saving = false;
    }
  }

  //JSON
  factory Cache.fromJson(Map<String, dynamic> json) => _$CacheFromJson(json);
  Map<String, dynamic> toJson() {
    threadsWarning = threadsWarning == true;
    return _$CacheToJson(this);
  }

  /// Cache fields include model objects inside lists and maps. The generated
  /// serializers leave some of those nested objects unconverted, so convert
  /// them at the JSON encoder boundary as well.
  static Object? _encodeJsonModel(Object? value) {
    try {
      return (value as dynamic).toJson();
    } on NoSuchMethodError catch (error) {
      throw JsonUnsupportedObjectError(value, cause: error);
    }
  }

  //Search History JSON
  static List<SearchHistoryItem> _searchHistoryFromJson(List<dynamic>? json) {
    return (json ?? [])
        .map<SearchHistoryItem?>((i) {
          try {
            return _searchHistoryItemFromJson(i);
          } catch (_) {
            return null;
          }
        })
        .whereType<SearchHistoryItem>()
        .toList();
  }

  static SearchHistoryItem _searchHistoryItemFromJson(
    Map<String, dynamic> json,
  ) {
    SearchHistoryItemType type = SearchHistoryItemType.values[json['type']];
    dynamic data;
    switch (type) {
      case SearchHistoryItemType.TRACK:
        data = Track.fromJson(json['data']);
        break;
      case SearchHistoryItemType.ALBUM:
        data = Album.fromJson(json['data']);
        break;
      case SearchHistoryItemType.ARTIST:
        data = Artist.fromJson(json['data']);
        break;
      case SearchHistoryItemType.PLAYLIST:
        data = Playlist.fromJson(json['data']);
        break;
      case SearchHistoryItemType.RADIO:
        data = LiveRadio.fromJson(json['data']);
        break;
    }
    return SearchHistoryItem(data, type);
  }

  static List<Map<String, dynamic>> _searchHistoryToJson(
    List<SearchHistoryItem>? data,
  ) => (data ?? [])
      .map<Map<String, dynamic>?>((i) {
        try {
          final serializedData = i.data is Map ? i.data : i.data?.toJson();
          if (serializedData == null) return null;
          return {'type': i.type.index, 'data': serializedData};
        } catch (_) {
          return null;
        }
      })
      .whereType<Map<String, dynamic>>()
      .toList();
}

@JsonSerializable()
class SearchHistoryItem {
  dynamic data;
  SearchHistoryItemType type;

  SearchHistoryItem(this.data, this.type);
}

enum SearchHistoryItemType { TRACK, ALBUM, ARTIST, PLAYLIST, RADIO }
