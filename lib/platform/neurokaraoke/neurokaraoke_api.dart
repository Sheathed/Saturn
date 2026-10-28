import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import '../../api/definitions.dart';
import '../../settings.dart';
import '../music_platform.dart';
import '../../utils/json_isolate.dart';
import '../../utils/logging.dart';

const String _kNeuroApiBaseUrl = 'https://api.neurokaraoke.com/api';
const String _kNeuroStorageBaseUrl = 'https://storage.neurokaraoke.com';
const String _kNeuroImageBaseUrl = 'https://images.neurokaraoke.com';

String _formatNeuroImageUrl(
  dynamic path, {
  int width = 1024,
  int height = 1024,
  int quality = 90,
}) {
  if (path is Map) {
    final cloudflareId = path['cloudflareId']?.toString().trim();
    if (cloudflareId != null && cloudflareId.isNotEmpty && cloudflareId != 'null') {
      path = '/WxURxyML82UkE7gY-PiBKw/$cloudflareId';
    } else {
      path = path['absolutePath'] ?? path['url'] ?? path['art'];
    }
  }
  if (path == null) return 'https://www.neurokaraoke.com/img/nosource.png';
  final p = path.toString().trim();
  if (p.isEmpty || p == 'null' || p.contains('nosource.png')) {
    return 'https://www.neurokaraoke.com/img/nosource.png';
  }
  if (p.startsWith('http://') || p.startsWith('https://')) return p;
  final normalized = p.startsWith('/') ? p : '/$p';
  if (normalized.startsWith('/WxURxyML82UkE7gY-PiBKw/')) {
    final pathWithoutVariant = normalized.replaceFirst(
      RegExp(r'/(public|thumbnail)$'),
      '',
    );
    final variant = width <= 128 ? 'thumbnail' : 'public';
    return '$_kNeuroImageBaseUrl$pathWithoutVariant/$variant';
  }
  return '$_kNeuroStorageBaseUrl/${normalized.substring(1)}';
}

List<Track> _tracksWithUniqueArt(List<Track> tracks) {
  final seen = <String>{};
  return tracks.where((track) {
    final url = track.albumArt?.fullUrl?.trim();
    return url != null &&
        url.isNotEmpty &&
        !url.contains('/img/nosource.png') &&
        seen.add(url);
  }).take(4).toList();
}

List<String>? _trackMosaicUrls(List<Track> tracks) {
  final artTracks = _tracksWithUniqueArt(tracks);
  return artTracks.isEmpty
      ? null
      : artTracks.map((track) => track.albumArt!.fullUrl!).toList();
}

List<String?>? _trackMosaicCaptions(List<Track> tracks) {
  final artTracks = _tracksWithUniqueArt(tracks);
  return artTracks.isEmpty
      ? null
      : artTracks.map((track) => track.albumArt?.caption).toList();
}

class GenreData {
  final String id;
  final String name;
  final int songCount;

  GenreData({required this.id, required this.name, required this.songCount});

  factory GenreData.fromJson(Map<String, dynamic> json) {
    return GenreData(
      id: json['id'],
      name: json['name'],
      songCount: json['songCount'] ?? 0,
    );
  }
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'songCount': songCount,
  };
}

class CoverDistributionStats {
  final int totalSongs;
  final int neuroCount;
  final int evilCount;
  final int duetCount;
  final int otherCount;

  CoverDistributionStats({
    required this.totalSongs,
    required this.neuroCount,
    required this.evilCount,
    required this.duetCount,
    required this.otherCount,
  });

  factory CoverDistributionStats.fromJson(Map<String, dynamic> json) {
    return CoverDistributionStats(
      totalSongs: json['totalSongs'] ?? 0,
      neuroCount: json['neuroCount'] ?? 0,
      evilCount: json['evilCount'] ?? 0,
      duetCount: json['duetCount'] ?? 0,
      otherCount: json['otherCount'] ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'neuroCount': neuroCount,
    'evilCount': evilCount,
    'duetCount': duetCount,
    'otherCount': otherCount,
  };
}

class NeuroKaraokeAPI {
  final http.Client _client = http.Client();
  late String _guestId;
  String? _authToken;
  String? currentUserId;
  String? currentUsername;
  String? currentUserAvatarUrl;
  String _userAgent = 'SaturnApp';

  NeuroKaraokeAPI() {
    _loadAuthToken();
    _loadGuestId();
    _loadUserAgent();
  }

  void _loadUserAgent() {
    PackageInfo.fromPlatform()
        .then((info) {
          _userAgent = 'SaturnApp:${info.version}';
        })
        .catchError((_) {
          _userAgent = 'SaturnApp:Unknown';
        });
  }

  void _loadAuthToken() {
    try {
      final config = settings.platformConfigs['neurokaraoke'];
      if (config != null && config['token'] != null) {
        _authToken = config['token'];
        currentUsername = config['username'];
        currentUserId = config['id']?.toString();
        currentUserAvatarUrl = config['avatarUrl'] as String?;
        if (currentUsername == null) fetchCurrentUser();
      }
    } catch (_) {}
  }

  Future<void> fetchCurrentUser() async {
    if (_authToken == null) return;
    try {
      final response = await _client.get(
        Uri.parse('$_kNeuroApiBaseUrl/auth/me'),
        headers: _headers,
      );
      if (response.statusCode == 200) {
        final data = await decodeJsonAsync(response.body);
        currentUsername = data['userName'] ?? data['username'];
        currentUserId = data['id']?.toString();
        currentUserAvatarUrl = data['avatarUrl'] as String?;
        final currentConfig =
            settings.platformConfigs['neurokaraoke'] is Map
                ? Map<String, dynamic>.from(
                    settings.platformConfigs['neurokaraoke'],
                  )
                : <String, dynamic>{};
        settings.platformConfigs['neurokaraoke'] = {
          ...currentConfig,
          'token': _authToken,
          if (currentUsername != null) 'username': currentUsername,
          if (currentUserId != null) 'id': currentUserId,
          if (currentUserAvatarUrl != null) 'avatarUrl': currentUserAvatarUrl,
        };
        await settings.save();
      }
    } catch (_) {}
  }

  void _loadGuestId() {
    try {
      final config = settings.platformConfigs['neurokaraoke'];
      if (config != null && config['guestId'] != null) {
        _guestId = config['guestId'];
      } else {
        _guestId = _generateGuestId();
        settings.platformConfigs['neurokaraoke'] = {
          ...?config,
          'guestId': _guestId,
        };
        settings.save();
      }
    } catch (_) {
      _guestId = _generateGuestId();
    }
  }

  static String _generateGuestId() {
    final random = Random();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  Map<String, String> get _headers {
    final headers = {
      'Accept': '*/*',
      'User-Agent': _userAgent,
      'Origin': _siteOrigin,
      'Referer': '$_siteOrigin/',
      'x-guest-id': _guestId,
      'Content-Type': 'application/json',
    };
    if (_authToken != null) {
      headers['Authorization'] = 'Bearer $_authToken';
    }
    return headers;
  }

  String get _siteOrigin {
    final config = settings.platformConfigs['neurokaraoke'];
    final selectedSite = config is Map
        ? config['listenSite']?.toString()
        : null;
    return switch (selectedSite) {
      'https://evilkaraoke.com' => 'https://evilkaraoke.com',
      'https://twinskaraoke.com' => 'https://twinskaraoke.com',
      _ => 'https://www.neurokaraoke.com',
    };
  }

  Future<void> logPlayCount(String trackId, String? playlistId) async {
    try {
      var uri = Uri.parse('$_kNeuroApiBaseUrl/songs/playCount/$trackId');
      if (playlistId != null) {
        uri = uri.replace(queryParameters: {'playlistId': playlistId});
      }
      await _client.put(uri, headers: _headers);
    } catch (e) {
      if (kDebugMode) {
        appLogger.warning('Error logging play count', e);
      }
    }
  }

  Future<AuthResult> login(String username, String password) async {
    try {
      final response = await _client.post(
        Uri.parse('$_kNeuroApiBaseUrl/auth/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'username': username, 'password': password}),
      );

      if (response.statusCode == 200) {
        final data = await decodeJsonAsync(response.body);
        final token = data['token'];
        if (token != null) {
          _authToken = token;
          settings.platformConfigs['neurokaraoke'] = {'token': token};
          await settings.save();
          await fetchCurrentUser();
          return const AuthResult.success();
        }
      } else if (response.statusCode == 401) {
        final data = await decodeJsonAsync(response.body);
        return AuthResult.failure(
          data['message'] ?? 'Invalid username or password.',
        );
      }
      return AuthResult.failure(
        'Login failed with status ${response.statusCode}',
      );
    } catch (e) {
      return AuthResult.failure(e.toString());
    }
  }

  Future<AuthResult> loginWithToken(String token) async {
    try {
      _authToken = token;
      settings.platformConfigs['neurokaraoke'] = {'token': token};
      await settings.save();
      await fetchCurrentUser();
      return const AuthResult.success();
    } catch (e) {
      return AuthResult.failure(e.toString());
    }
  }

  bool get isGuest {
    final config = settings.platformConfigs['neurokaraoke'];
    return config != null && config['isGuest'] == true;
  }

  bool get hasAuthToken => _authToken != null;
  String? get authToken => _authToken;

  bool isLoggedIn() {
    return hasAuthToken || isGuest;
  }

  Future<void> loginAsGuest() async {
    _authToken = null;
    settings.platformConfigs['neurokaraoke'] = {'isGuest': true};
    await settings.save();
  }

  Future<void> logout() async {
    _authToken = null;
    currentUsername = null;
    currentUserId = null;
    currentUserAvatarUrl = null;
    settings.platformConfigs['neurokaraoke'] = null;
    await settings.save();
  }

  Future<List<Track>> getFavoriteTracks() async {
    if (currentUsername == null && hasAuthToken) {
      await fetchCurrentUser();
    }
    final response = await _client.get(
      Uri.parse('$_kNeuroApiBaseUrl/favorites/type?type=0'),
      headers: _headers,
    );

    if (response.statusCode != 200) {
      appLogger.warning(
        'Get favorites failed with status ${response.statusCode}: ${response.body}',
      );
      return [];
    }

    final List<dynamic> data = await decodeJsonAsync(response.body);
    final tracks = <Track>[];
    for (int i = 0; i < data.length; i++) {
      final item = data[i];
      final songMap = (item is Map && item['song'] is Map)
          ? Map<String, dynamic>.from(item['song'] as Map)
          : (item is Map<String, dynamic> && item['title'] != null
              ? item
              : null);
      if (songMap != null) {
        final track = _mapToTrack(songMap);
        final added = item is Map
            ? (item['createdAt'] ?? item['created_at'] ?? item['order'])
            : null;
        if (added is int) {
          track.addedDate = added < 10000000000 ? added * 1000 : added;
        } else if (added is String) {
          track.addedDate = DateTime.tryParse(
            added.replaceAll('/', '-'),
          )?.millisecondsSinceEpoch ?? i;
        } else {
          track.addedDate = i;
        }
        tracks.add(track);
      }
    }
    return tracks;
  }

  Future<void> toggleFavoriteTrack(String songId) async {
    final response = await _client.put(
      Uri.parse('$_kNeuroApiBaseUrl/user/favorites/$songId'),
      headers: _headers,
    );

    if (response.statusCode != 200) {
      appLogger.warning('Toggle favorite failed with status ${response.statusCode}: ${response.body}');
    }
  }

  Future<List<Playlist>> getFavoritePlaylists() async {
    if (currentUsername == null) await fetchCurrentUser();
    final response = await _client.get(
      Uri.parse('$_kNeuroApiBaseUrl/favorites/type?type=3'),
      headers: _headers,
    );

    if (response.statusCode != 200) {
      appLogger.warning('Get favorite playlists failed with status ${response.statusCode}: ${response.body}');
      return [];
    }

    final List<dynamic> data = await decodeJsonAsync(response.body);
    return data
        .map((item) {
          final playlistMap = item['playlist'] as Map<String, dynamic>?;
          if (playlistMap != null) {
            return _mapToPlaylist(playlistMap);
          }
          return null;
        })
        .where((p) => p != null)
        .cast<Playlist>()
        .toList();
  }

  Future<List<Playlist>> getCreatedPlaylists() async {
    if (currentUsername == null) await fetchCurrentUser();
    final response = await _client.get(
      Uri.parse(
        '$_kNeuroApiBaseUrl/playlists?startIndex=0&pageSize=100&search=&sortBy=&sortDescending=False&isSetlist=False&year=0',
      ),
      headers: _headers,
    );

    if (response.statusCode != 200) {
      appLogger.warning('Get created playlists failed with status ${response.statusCode}: ${response.body}');
      return [];
    }

    final List<dynamic> data = await decodeJsonAsync(response.body);
    return data.map((item) {
      final p = _mapToPlaylist(item as Map<String, dynamic>);
      return p;
    }).toList();
  }

  Future<void> toggleFavoritePlaylist(String id) async {
    final response = await _client.post(
      Uri.parse('$_kNeuroApiBaseUrl/favorites/toggle?itemId=$id&type=3'),
      headers: _headers,
    );

    if (response.statusCode != 200) {
      appLogger.warning('Toggle favorite playlist failed with status ${response.statusCode}: ${response.body}');
    }
  }

  Future<SearchResults> search(String query) async {
    if (currentUsername == null) await fetchCurrentUser();
    final tracksFuture = _client.post(
      Uri.parse('$_kNeuroApiBaseUrl/songs'),
      headers: _headers,
      body: jsonEncode({
        'search': query,
        'page': 1,
        'pageSize': 20,
        'sortBy': 'KaraokeDate',
        'sortDesc': true,
        'genreIds': null,
      }),
    );

    final playlistsFuture = _client.get(
      Uri.parse(
        '$_kNeuroApiBaseUrl/playlist/public?startIndex=0&pageSize=25&search=${Uri.encodeComponent(query)}&sortBy=UpdatedAt&sortDescending=True',
      ),
      headers: _headers,
    );

    final setlistsFuture = _client.get(
      Uri.parse(
        '$_kNeuroApiBaseUrl/playlists?startIndex=0&pageSize=25&search=${Uri.encodeComponent(query)}&sortBy=&sortDescending=False&isSetlist=True&year=0',
      ),
      headers: _headers,
    );

    final artistsFuture = _client.get(
      Uri.parse(
        '$_kNeuroApiBaseUrl/artists?startIndex=0&pageSize=25&search=${Uri.encodeComponent(query)}&sortBy=Name&sortDescending=False',
      ),
      headers: _headers,
    );

    final responses = await Future.wait([
      tracksFuture,
      playlistsFuture,
      setlistsFuture,
      artistsFuture,
    ]);

    // Parse tracks
    List<Track> tracks = [];
    if (responses[0].statusCode == 200) {
      final data = await decodeJsonAsync(responses[0].body);
      final items = data['items'] as List<dynamic>? ?? [];
      tracks = items
          .map((item) => _mapToTrack(item as Map<String, dynamic>))
          .toList();
    }

    // Parse playlists
    List<Playlist> playlists = [];
    if (responses[1].statusCode == 200) {
      final data = await decodeJsonAsync(responses[1].body) as List<dynamic>? ?? [];
      playlists = data
          .map((item) => _mapToPlaylist(item as Map<String, dynamic>))
          .toList();
    }

    // Parse setlists
    List<Playlist> setlists = [];
    if (responses[2].statusCode == 200) {
      final data = await decodeJsonAsync(responses[2].body) as List<dynamic>? ?? [];
      setlists = data
          .map((item) => _mapToPlaylist(item as Map<String, dynamic>))
          .toList();
    }

    // Parse artists
    List<Artist> artists = [];
    if (responses[3].statusCode == 200) {
      final data = await decodeJsonAsync(responses[3].body) as List<dynamic>? ?? [];
      artists = data
          .map((item) => _mapToArtist(item as Map<String, dynamic>))
          .toList();
    }

    return SearchResults(
      tracks: tracks,
      playlists: playlists,
      setlists: setlists,
      artists: artists,
    );
  }

  Artist _mapToArtist(Map<String, dynamic> artistData) {
    List<Track> topTracks = [];
    if (artistData['songListDTOs'] != null) {
      final songsList = artistData['songListDTOs'] as List<dynamic>;
      topTracks = songsList.map((s) => _mapToTrack(s)).toList();
    }

    String imageUrl = artistData['imagePath'] != null
        ? '$_kNeuroStorageBaseUrl${artistData['imagePath']}'
        : '$_kNeuroStorageBaseUrl/media/artist/${artistData['id']}.png';

    return Artist(
      id: artistData['id'],
      name: artistData['name'],
      description: artistData['summary'],
      picture: ImageDetails(fullUrl: imageUrl, thumbUrl: imageUrl),
      topTracks: topTracks,
      platformId: 'neurokaraoke',
    );
  }

  Future<List<Track>> getTracks(List<String> ids) async {
    final response = await _client.post(
      Uri.parse('https://idk.neurokaraoke.com/public/songs/by-ids'),
      headers: {'Content-Type': 'application/json', ..._headers},
      body: jsonEncode(ids),
    );

    if (response.statusCode != 200) {
      if (kDebugMode) {
        appLogger.warning('Get tracks failed with status ${response.statusCode}: ${response.body}');
      }
      throw Exception('Failed to fetch tracks by ids');
    }

    final List data = await decodeJsonAsync(response.body);
    return data.map((json) => _mapToTrack(json)).toList();
  }

  Future<Track> getTrack(String id) async {
    final response = await _client.get(
      Uri.parse('$_kNeuroApiBaseUrl/songs/$id'),
      headers: _headers,
    );

    if (response.statusCode != 200) {
      appLogger.warning('Get track failed with status ${response.statusCode}: ${response.body}');
      throw Exception('Failed to fetch track: $id');
    }

    final data = await decodeJsonAsync(response.body);
    return _mapToTrack(data);
  }

  Track mapToTrack(Map<String, dynamic> song) => _mapToTrack(song);

  /// Radio updates describe the song on the station stream; they need no
  /// separate audio URL. A track opened on its own can resolve one by ID.
  Track mapToRadioTrack(Map<String, dynamic> song) =>
      _mapToTrack(song, expectAudioPath: false);

  Future<Map<String, dynamic>?> getSongRaw(String id) async {
    final response = await _client.get(
      Uri.parse('$_kNeuroApiBaseUrl/songs/$id'),
      headers: _headers,
    );

    if (response.statusCode != 200) {
      appLogger.warning('Get song raw failed with status ${response.statusCode}');
      return null;
    }

    final data = await decodeJsonAsync(response.body);
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return data.cast<String, dynamic>();
    return null;
  }

  Future<TrackCommunityRating?> getSongPoll(String id) async {
    try {
      final response = await _client.get(
        Uri.parse('$_kNeuroApiBaseUrl/polls/song/$id'),
        headers: _headers,
      );

      if (response.statusCode != 200) return null;

      final data = await decodeJsonAsync(response.body);
      if (data is List && data.isNotEmpty) {
        final first = (data[0] as Map).cast<String, dynamic>();
        return TrackCommunityRating(
          totalVotes: (first['totalVotes'] as num?)?.toInt() ?? 0,
          date: first['date'] as String?,
          masterpiece: (first['masterpiece'] as num?)?.toInt() ?? 0,
          amazing: (first['amazing'] as num?)?.toInt() ?? 0,
          good: (first['good'] as num?)?.toInt() ?? 0,
          bad: (first['bad'] as num?)?.toInt() ?? 0,
        );
      }
    } catch (e) {
      appLogger.warning('Failed to fetch song poll for $id: $e');
    }
    return null;
  }

  Future<Artist?> getArtist(String name) async {
    String? artistId = name;
    if (!RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
      caseSensitive: false,
    ).hasMatch(name.trim())) {
      // 1. Search for the artist by name
      final searchUri = Uri.parse('$_kNeuroApiBaseUrl/artists').replace(
        queryParameters: {
          'startIndex': '0',
          'pageSize': '25',
          'search': name,
          'sortBy': 'Name',
          'sortDescending': 'False',
        },
      );
      final searchRes = await _client.get(searchUri, headers: _headers);
      if (searchRes.statusCode != 200) return null;

      final List<dynamic> searchData = await decodeJsonAsync(searchRes.body);
      if (searchData.isEmpty) return null;

      // Find exact match by name (case-insensitive), fallback to the first result if not found
      final match = searchData.firstWhere(
        (artist) =>
            (artist['name'] as String?)?.toLowerCase() == name.toLowerCase(),
        orElse: () => searchData[0],
      );

      artistId = match['id'];
      if (artistId == null) return null;
    }

    // 2. Fetch full artist page
    final artistUri = Uri.parse('$_kNeuroApiBaseUrl/artist/$artistId');
    final artistRes = await _client.get(artistUri, headers: _headers);
    if (artistRes.statusCode != 200) return null;

    final Map<String, dynamic> artistData = await decodeJsonAsync(artistRes.body);

    return _mapToArtist(artistData);
  }

  Future<List<Playlist>> getPublicPlaylists({
    int startIndex = 0,
    int pageSize = 25,
    bool isSetlist = false,
  }) async {
    if (currentUsername == null) await fetchCurrentUser();

    final uri = isSetlist
        ? '$_kNeuroApiBaseUrl/playlists?startIndex=$startIndex&pageSize=$pageSize&search=&sortBy=&sortDescending=False&isSetlist=True&year=0'
        : '$_kNeuroApiBaseUrl/playlist/public?startIndex=$startIndex&pageSize=$pageSize&search=&sortBy=UpdatedAt&sortDescending=True';

    final response = await _client.get(Uri.parse(uri), headers: _headers);

    if (response.statusCode != 200) {
      appLogger.warning('Failed to get public playlists: ${response.body}');
      return [];
    }

    final List<dynamic> data = await decodeJsonAsync(response.body);
    return data.map((json) => _mapToPlaylist(json)).toList();
  }

  Future<Playlist> getPlaylist(String id, {int limit = 100}) async {
    if (currentUsername == null) await fetchCurrentUser();

    if (id == 'made-for-you') {
      final response = await _client.get(
        Uri.parse('$_kNeuroApiBaseUrl/user/suggestions?take=500'),
        headers: _headers,
      );
      if (response.statusCode != 200) {
        throw Exception('Failed to fetch suggestions');
      }
      final List<dynamic> data = await decodeJsonAsync(response.body);
      final tracks = data.asMap().entries.map((entry) {
        final t = _mapToTrack(entry.value as Map<String, dynamic>);
        t.addedDate = entry.key;
        return t;
      }).toList();
      int totalSeconds = tracks.fold(
        0,
        (sum, t) => sum + (t.duration?.inSeconds ?? 0),
      );
      return Playlist(
        id: 'made-for-you',
        title: 'Your mix',
        description:
            'Personalized song recommendations based on your listening history',
        tracks: tracks,
        trackCount: tracks.length,
        duration: Duration(seconds: totalSeconds),
        image: tracks.isNotEmpty
            ? (tracks.first.albumArt ??
                  ImageDetails(
                    fullUrl: 'https://www.neurokaraoke.com/img/nosource.png',
                  ))
            : ImageDetails(
                fullUrl: 'https://www.neurokaraoke.com/img/nosource.png',
              ),
        mosaicImages: _trackMosaicUrls(tracks),
        mosaicImageCaptions: _trackMosaicCaptions(tracks),
        disableDownload: true,
        platformId: 'neurokaraoke',
      );
    }

    if (id == 'trending') {
      final response = await _client.get(
        Uri.parse('$_kNeuroApiBaseUrl/explore/trendings?days=7&take=500'),
        headers: _headers,
      );
      if (response.statusCode != 200) {
        throw Exception('Failed to fetch trending');
      }
      final List<dynamic> data = await decodeJsonAsync(response.body);
      final tracks = data.asMap().entries.map((entry) {
        final t = _mapToTrack(entry.value as Map<String, dynamic>);
        t.addedDate = entry.key;
        return t;
      }).toList();
      int totalSeconds = tracks.fold(
        0,
        (sum, t) => sum + (t.duration?.inSeconds ?? 0),
      );
      return Playlist(
        id: 'trending',
        title: 'Trending This Week',
        description: 'The most played songs over the past 7 days',
        tracks: tracks,
        trackCount: tracks.length,
        duration: Duration(seconds: totalSeconds),
        image: tracks.isNotEmpty
            ? (tracks.first.albumArt ??
                  ImageDetails(
                    fullUrl: 'https://www.neurokaraoke.com/img/nosource.png',
                  ))
            : ImageDetails(
                fullUrl: 'https://www.neurokaraoke.com/img/nosource.png',
              ),
        mosaicImages: _trackMosaicUrls(tracks),
        mosaicImageCaptions: _trackMosaicCaptions(tracks),
        disableDownload: true,
        platformId: 'neurokaraoke',
      );
    }

    if (id == 'recent' || id == 'recent-setlist') {
      final recent = await getRecentSetlist();
      if (recent != null) return recent;
    }

    final response = await _client.get(
      Uri.parse('$_kNeuroApiBaseUrl/playlist/$id'),
      headers: _headers,
    );

    if (response.statusCode != 200) {
      appLogger.warning('Get playlist failed with status ${response.statusCode}: ${response.body}');
      throw Exception('Failed to fetch playlist: $id');
    }

    final data = await decodeJsonAsync(response.body);
    final songs = data['songListDTOs'] as List<dynamic>? ?? [];
    songs.sort(
      (a, b) => (a['order'] as int? ?? 0).compareTo(b['order'] as int? ?? 0),
    );

    final tracks = songs.asMap().entries.map((entry) {
      final item = entry.value as Map<String, dynamic>;
      final t = _mapToTrack(item);
      t.addedDate = item['order'] as int? ?? entry.key;
      return t;
    }).toList();

    Playlist p = _mapToPlaylist(data);
    p.tracks = tracks;
    if (p.trackCount == null || p.trackCount == 0) p.trackCount = tracks.length;
    if ((p.image?.caption == null || p.image!.caption!.isEmpty) &&
        tracks.isNotEmpty &&
        tracks.first.albumArt?.caption != null) {
      p.image = ImageDetails(
        fullUrl: p.image?.fullUrl,
        thumbUrl: p.image?.thumbUrl,
        caption: tracks.first.albumArt?.caption,
      );
    }

    int totalSeconds = 0;
    for (final t in tracks) {
      if (t.duration != null) totalSeconds += t.duration!.inSeconds;
    }
    p.duration = Duration(seconds: totalSeconds);

    return p;
  }

  Future<String> createPlaylist(
    String title, {
    String description = '',
    bool isPublic = false,
  }) async {
    final response = await _client.post(
      Uri.parse('$_kNeuroApiBaseUrl/playlist/save'),
      headers: _headers,
      body: jsonEncode({
        'Id': null,
        'Name': title,
        'Description': description,
        'CreatedBy': null,
        'MediaListDTO': null,
        'IsPublic': isPublic,
        'SongId': null,
        'IsSetList': false,
        'SetListDate': null,
      }),
    );

    if (response.statusCode != 200) {
      appLogger.warning('Create playlist failed: ${response.statusCode}: ${response.body}');
      throw Exception('Failed to create playlist');
    }
    return response.body.replaceAll('"', '').trim();
  }

  Future<void> updatePlaylist(
    String id,
    String title, {
    String description = '',
    bool isPublic = false,
  }) async {
    final getResponse = await _client.get(
      Uri.parse('$_kNeuroApiBaseUrl/playlist/$id'),
      headers: _headers,
    );
    if (getResponse.statusCode != 200) {
      throw Exception('Failed to get playlist');
    }
    final Map<String, dynamic> playlistData = await decodeJsonAsync(getResponse.body);

    playlistData['Name'] = title;
    playlistData['name'] = title; // Handle API casing inconsistencies
    playlistData['Description'] = description;
    playlistData['description'] = description;
    playlistData['IsPublic'] = isPublic;
    playlistData['isPublic'] = isPublic;

    final saveResponse = await _client.post(
      Uri.parse('$_kNeuroApiBaseUrl/playlist/save'),
      headers: _headers,
      body: jsonEncode(playlistData),
    );
    if (saveResponse.statusCode != 200) {
      appLogger.warning('Update playlist failed: ${saveResponse.statusCode}: ${saveResponse.body}');
      throw Exception('Failed to update playlist');
    }
  }

  Future<void> deletePlaylist(String id) async {
    final response = await _client.delete(
      Uri.parse('$_kNeuroApiBaseUrl/playlist/$id'),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      appLogger.warning('Delete playlist failed: ${response.statusCode}: ${response.body}');
    }
  }

  Future<void> addToPlaylist(String trackId, String playlistId) async {
    final response = await _client.put(
      Uri.parse(
        '$_kNeuroApiBaseUrl/user/playlists/$playlistId?songId=$trackId',
      ),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      throw Exception('Failed to add track to playlist');
    }
  }

  Future<void> removeFromPlaylist(String trackId, String playlistId) async {
    final response = await _client.delete(
      Uri.parse('$_kNeuroApiBaseUrl/playlist/$playlistId/song/$trackId'),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      throw Exception('Failed to remove track from playlist');
    }
  }

  Future<Lyrics> getLyrics(String id) async {
    final response = await _client.get(
      Uri.parse('$_kNeuroApiBaseUrl/songs/$id/lyrics'),
      headers: _headers,
    );

    if (response.statusCode != 200) {
      appLogger.warning('Get lyrics failed with status ${response.statusCode}: ${response.body}');
      return Lyrics(id: id, errorMessage: 'Lyrics not found');
    }

    final List<dynamic> data = await decodeJsonAsync(response.body);
    final List<SynchronizedLyric> syncedLyrics = [];

    for (final item in data) {
      if (item is Map<String, dynamic> &&
          item['time'] != null &&
          item['text'] != null) {
        final timeStr = item['time'] as String;
        final text = item['text'] as String;
        final offset = _parseTime(timeStr);
        syncedLyrics.add(
          SynchronizedLyric(offset: offset, text: text, lrcTimestamp: timeStr),
        );
      }
    }

    // Sort lyrics by offset
    syncedLyrics.sort((a, b) => a.offset!.compareTo(b.offset!));

    // Calculate durations
    for (int i = 0; i < syncedLyrics.length - 1; i++) {
      syncedLyrics[i].duration =
          syncedLyrics[i + 1].offset! - syncedLyrics[i].offset!;
    }
    if (syncedLyrics.isNotEmpty) {
      syncedLyrics.last.duration = const Duration(seconds: 5);
    }

    return Lyrics(id: id, syncedLyrics: syncedLyrics);
  }

  Duration _parseTime(String timeStr) {
    final value = timeStr.trim().replaceAll(RegExp(r'^\[|\]$'), '');
    // The API generally returns hh:mm:ss with high precision, but accept
    // standard LRC mm:ss as well. Keep only millisecond precision for UI use.
    final match = RegExp(
      r'^(?:(\d+):)?(\d{1,2}):(\d{1,2})(?:\.(\d+))?$',
    ).firstMatch(value);
    if (match == null) {
      throw FormatException('Invalid lyric timestamp: $timeStr');
    }

    final fraction = match.group(4) ?? '';
    final milliseconds = int.parse(
      fraction.isEmpty
          ? '0'
          : fraction.length >= 3
          ? fraction.substring(0, 3)
          : fraction.padRight(3, '0'),
    );
    return Duration(
      hours: int.parse(match.group(1) ?? '0'),
      minutes: int.parse(match.group(2)!),
      seconds: int.parse(match.group(3)!),
      milliseconds: milliseconds,
    );
  }

  String? _extractCoverArtArtist(dynamic coverArt, [dynamic container]) {
    if (coverArt is Map) {
      final artist = coverArt['artist'] ??
          coverArt['author'] ??
          coverArt['creator'] ??
          coverArt['credit'] ??
          coverArt['by'];
      if (artist is Map) {
        final name =
            artist['name'] ?? artist['username'] ?? artist['displayName'];
        if (name != null && name.toString().trim().isNotEmpty) {
          return name.toString().trim();
        }
      } else if (artist is String && artist.trim().isNotEmpty) {
        return artist.trim();
      }
      final caption = coverArt['caption'] ?? coverArt['creditText'];
      if (caption is String && caption.trim().isNotEmpty) {
        return caption.trim();
      }
    }
    if (container is Map) {
      final alt = container['coverArtArtist'] ??
          container['artArtist'] ??
          container['artistCredit'] ??
          container['artCredit'];
      if (alt is Map) {
        final name =
            alt['name'] ?? alt['username'] ?? alt['displayName'];
        if (name != null && name.toString().trim().isNotEmpty) {
          return name.toString().trim();
        }
      } else if (alt is String && alt.trim().isNotEmpty) {
        return alt.trim();
      }
      final meta = container['metadata'];
      if (meta is Map) {
        final art = meta['artArtist'] ??
            meta['coverArtist'] ??
            meta['coverArtArtist'] ??
            meta['artworkArtist'];
        if (art is String && art.trim().isNotEmpty) return art.trim();
      }
    }
    return null;
  }

  Track _mapToTrack(
    Map<String, dynamic> song, {
    bool expectAudioPath = true,
  }) {
    List<String> extractArtists(List<dynamic>? neuroArtists) {
      if (neuroArtists == null) return [];
      final result = <String>[];
      for (final a in neuroArtists) {
        if (a is String) {
          result.add(a);
        } else if (a is Map<String, dynamic> && a['name'] != null) {
          result.add(a['name']);
        }
      }
      return result;
    }

    final coverArtists = extractArtists(song['coverArtists']);
    final originalArtists = extractArtists(song['originalArtists']);

    String originalArtistsStr = originalArtists.isNotEmpty
        ? originalArtists.join(', ')
        : 'Unknown';
    String rawTitle = song['title'] ?? 'Unknown Track';
    String title = '$originalArtistsStr - $rawTitle';

    List<String> artists = coverArtists.isNotEmpty
        ? coverArtists
        : originalArtists;

    String streamUrl = '';
    String format = 'arbitrary';

    final path =
        song['absolutePath'] ?? song['opus'] ?? song['audioUrl'] ?? song['oss'];
    if (path != null) {
      streamUrl = '$_kNeuroStorageBaseUrl/$path';
      if (path.toString().endsWith('.ogg') ||
          path.toString().endsWith('.opus')) {
        format = 'ogg/opus';
      }
    } else if (expectAudioPath) {
      appLogger.warning('No audio path found for track "${song['title']}"');
    }

    final coverArt = song['coverArt'];
    dynamic imagePath;
    if (coverArt is Map) {
      imagePath = coverArt;
    } else if (coverArt is String && coverArt.isNotEmpty) {
      imagePath = coverArt;
    } else {
      imagePath = song['art'] ?? song['artwork'] ?? song['image'];
    }

    final fullImageUrl = _formatNeuroImageUrl(
      imagePath,
      width: 1024,
      height: 1024,
      quality: 90,
    );
    final thumbImageUrl = _formatNeuroImageUrl(
      imagePath,
      width: 128,
      height: 128,
      quality: 90,
    );

    return Track(
      id: song['id']?.toString() ?? '',
      title: title,
      album: null,
      duration: Duration(seconds: (song['duration'] as num?)?.toInt() ?? 0),
      albumArt: ImageDetails(
        fullUrl: fullImageUrl,
        thumbUrl: thumbImageUrl,
        caption: _extractCoverArtArtist(coverArt, song),
      ),
      artists: artists.isNotEmpty
          ? artists
                .map((a) => Artist(id: a, name: a, platformId: 'neurokaraoke'))
                .toList()
          : [
              Artist(
                id: 'unknown',
                name: 'Unknown Artist',
                platformId: 'neurokaraoke',
              ),
            ],
      navigableArtists: originalArtists.isNotEmpty
          ? originalArtists
                .map((a) => Artist(id: a, name: a, platformId: 'neurokaraoke'))
                .toList()
          : null,
      playbackDetails: path == null ? const [] : [streamUrl, format],
      platformId: 'neurokaraoke',
    );
  }

  Playlist _mapToPlaylist(Map<String, dynamic> data) {
    final id = data['id'];
    final name = data['name'] ?? 'Neuro Karaoke Playlist';

    final media = data['media'];
    String? imagePath;
    if (media is Map) {
      final cloudflareId = media['cloudflareId']?.toString().trim();
      final path = cloudflareId != null &&
              cloudflareId.isNotEmpty &&
              cloudflareId != 'null'
          ? '/WxURxyML82UkE7gY-PiBKw/$cloudflareId'
          : media['absolutePath'] ?? media['url'];
      imagePath = path?.toString();
    }
    if (imagePath != null &&
        (imagePath.trim().isEmpty || imagePath.contains('nosource.png'))) {
      imagePath = null;
    }
    final bool hasCustomImage = imagePath != null;

    final mosaicMedia = data['mosaicMedia'] as List<dynamic>?;
    final songList = data['songListDTOs'] as List<dynamic>?;

    // Keep the API's image order: it defines the collage positions shown by
    // Neurokaraoke. Deduplicate without changing that order.
    List<String> mosaicUrls = [];
    final mosaicCaptions = <String?>[];
    final seenMosaicUrls = <String>{};
    void addMosaicImage(dynamic image) {
      final url = _formatNeuroImageUrl(
        image,
        width: 1024,
        height: 1024,
        quality: 90,
      );
      if (url == 'https://www.neurokaraoke.com/img/nosource.png' ||
          url.trim().isEmpty ||
          !seenMosaicUrls.add(url)) {
        return;
      }
      mosaicUrls.add(url);
      mosaicCaptions.add(_extractCoverArtArtist(image));
    }

    if (mosaicMedia != null && mosaicMedia.isNotEmpty) {
      for (final image in mosaicMedia) {
        addMosaicImage(image);
      }
    } else if (songList != null && songList.isNotEmpty) {
      for (final song in songList) {
        addMosaicImage(song['coverArt']);
      }
    }

    final playlistArtCaption = _extractCoverArtArtist(media, data);

    final fullImageUrl = imagePath == null
        ? null
        : _formatNeuroImageUrl(
            imagePath,
            width: 1024,
            height: 1024,
            quality: 90,
          );

    final creator = data['createdBy'];

    return Playlist(
      id: id,
      title: name,
      description: data['description'],
      user: creator != null ? User(name: creator) : null,
      trackCount: data['songCount'] ?? 0,
      image: ImageDetails(
        fullUrl: fullImageUrl,
        caption: playlistArtCaption,
      ),
      mosaicImages: (mosaicUrls.isNotEmpty && !hasCustomImage)
          ? mosaicUrls
          : null,
      mosaicImageCaptions: (mosaicUrls.isNotEmpty && !hasCustomImage)
          ? mosaicCaptions
          : null,
      editable:
          creator != null &&
          currentUsername != null &&
          creator.toLowerCase() == currentUsername!.toLowerCase(),
      platformId: 'neurokaraoke',
    );
  }

  Future<List<GenreData>> getExploreGenres() async {
    final response = await _client.get(
      Uri.parse('$_kNeuroApiBaseUrl/genres/explore'),
      headers: _headers,
    );
    if (response.statusCode == 200) {
      final List<dynamic> data = await decodeJsonAsync(response.body);
      return data.map((g) => GenreData.fromJson(g)).toList();
    }
    return [];
  }

  Future<Playlist?> getRecentSetlist() async {
    final response = await _client.get(
      Uri.parse('$_kNeuroApiBaseUrl/playlist/recent'),
      headers: _headers,
    );
    if (response.statusCode == 200) {
      final data = await decodeJsonAsync(response.body);
      final p = _mapToPlaylist(data);
      if (data['songListDTOs'] != null) {
        final List<dynamic> songs = data['songListDTOs'];
        songs.sort(
          (a, b) =>
              (a['order'] as int? ?? 0).compareTo(b['order'] as int? ?? 0),
        );
        p.tracks = songs.map((s) => _mapToTrack(s)).toList();
        if ((p.image?.caption == null || p.image!.caption!.isEmpty) &&
            p.tracks!.isNotEmpty &&
            p.tracks!.first.albumArt?.caption != null) {
          p.image = ImageDetails(
            fullUrl: p.image?.fullUrl,
            thumbUrl: p.image?.thumbUrl,
            caption: p.tracks!.first.albumArt?.caption,
          );
        }
        final int totalSeconds = p.tracks!.fold(
          0,
          (sum, t) => sum + (t.duration?.inSeconds ?? 0),
        );
        p.duration = Duration(seconds: totalSeconds);
      }
      return p;
    }
    return null;
  }

  Future<List<Track>> getUserSuggestions({int take = 20}) async {
    final response = await _client.get(
      Uri.parse('$_kNeuroApiBaseUrl/user/suggestions?take=$take'),
      headers: _headers,
    );
    if (response.statusCode == 200) {
      final List<dynamic> data = await decodeJsonAsync(response.body);
      return data.map((t) => _mapToTrack(t)).toList();
    }
    return [];
  }

  Future<List<Track>> getTrending({int days = 7, int take = 20}) async {
    final response = await _client.get(
      Uri.parse('$_kNeuroApiBaseUrl/explore/trendings?days=$days&take=$take'),
      headers: _headers,
    );
    if (response.statusCode == 200) {
      final List<dynamic> data = await decodeJsonAsync(response.body);
      return data.map((t) => _mapToTrack(t)).toList();
    }
    return [];
  }

  Future<CoverDistributionStats?> getCoverDistribution() async {
    final response = await _client.get(
      Uri.parse('$_kNeuroApiBaseUrl/stats/cover-distribution'),
      headers: _headers,
    );
    if (response.statusCode == 200) {
      return CoverDistributionStats.fromJson(await decodeJsonAsync(response.body));
    }
    return null;
  }

  Future<List<Artist>> getArtists({
    int startIndex = 0,
    int pageSize = 25,
    String search = '',
    String sortBy = 'Name',
    bool sortDescending = false,
  }) async {
    final response = await _client.get(
      Uri.parse(
        '$_kNeuroApiBaseUrl/artists?startIndex=$startIndex&pageSize=$pageSize&search=$search&sortBy=$sortBy&sortDescending=$sortDescending',
      ),
      headers: _headers,
    );

    if (response.statusCode == 200) {
      final List<dynamic> data = await decodeJsonAsync(response.body);
      return data.map((json) {
        String pictureUrl = json['imagePath'] != null
            ? '$_kNeuroStorageBaseUrl${json['imagePath']}'
            : '$_kNeuroStorageBaseUrl/media/artist/${json['id']}.png';

        return Artist(
          id: json['id'],
          name: json['name'],
          description: json['summary'] ?? json['content'],
          picture: ImageDetails(fullUrl: pictureUrl, thumbUrl: pictureUrl),
          platformId: 'neurokaraoke',
          // Note: using fans to store songCount as there is no specific field for it on the model yet
          fans: json['songCount'],
        );
      }).toList();
    }
    return [];
  }
}
