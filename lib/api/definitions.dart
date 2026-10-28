import 'dart:convert';
import 'dart:io';
import 'package:logging/logging.dart';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:intl/intl.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../api/cache.dart';
import '../translations.i18n.dart';

part 'definitions.g.dart';

@JsonSerializable()
class Track {
  String? id;
  String? title;
  Album? album;
  List<Artist>? artists;

  /// Artist text for display when no navigable artist is available.
  String? displayArtistName;
  Duration? duration;
  ImageDetails? albumArt;
  int? trackNumber;
  bool? offline;
  String? qualityFormat;
  int? qualityBitrate;
  LyricsFull? lyrics;
  bool? favorite;
  bool pinned;
  int? diskNumber;
  bool? explicit;
  //Date added to playlist / favorites
  int? addedDate;
  Contributors? contributors;
  Track? fallback;
  //Charts
  int? variation;
  bool? unavailable;
  String? unavailableReason;

  /// The platform this track originated from, e.g. 'deezer', 'soundcloud'.
  @JsonKey(defaultValue: 'deezer')
  String platformId;

  List<dynamic>? playbackDetails;
  List<dynamic>? playbackDetailsFallback;

  List<Artist>? navigableArtists;

  /// Returns a list of search queries optimized for finding lyrics,
  /// from most specific to most broad.
  List<String> get lyricSearchQueries {
    final t = title ?? '';
    final a = artistString ?? '';

    final cleanTitle = t
        .replaceAll(RegExp(r'\(.*?\)'), '')
        .replaceAll(RegExp(r'\[.*?\]'), '')
        .trim();

    final firstArtist = artists?.isNotEmpty == true
        ? artists!.first.name
        : (navigableArtists?.isNotEmpty == true
                  ? navigableArtists!.first.name
                  : displayArtistName) ??
              '';

    final queries = [
      '$t $a'.trim(),
      if (cleanTitle != t || firstArtist != a)
        '$cleanTitle $firstArtist'.trim(),
      if (cleanTitle.isNotEmpty) cleanTitle,
    ];

    return queries.where((q) => q.isNotEmpty).toSet().toList();
  }

  Track({
    this.id,
    this.title,
    this.duration,
    this.album,
    this.playbackDetails,
    this.albumArt,
    this.artists,
    this.displayArtistName,
    this.trackNumber,
    this.offline,
    this.qualityFormat,
    this.qualityBitrate,
    this.lyrics,
    this.favorite,
    this.pinned = false,
    this.diskNumber,
    this.explicit,
    this.addedDate,
    this.contributors,
    this.fallback,
    this.playbackDetailsFallback,
    this.variation,
    this.navigableArtists,
    this.platformId = 'deezer',
    this.unavailable = false,
    this.unavailableReason,
  });

  String get unavailableMessage => unavailableReason == 'drm'
      ? 'Track is unavailable due to DRM'
      : 'Track is unavailable'.i18n;

  List<Artist>? get displayArtists =>
      artists?.isNotEmpty == true ? artists : navigableArtists;
  String? get artistString {
    if (displayArtistName?.isNotEmpty == true) return displayArtistName;
    return displayArtists?.map<String>((art) => art.name ?? '').join(', ');
  }

  String? get durationString {
    final value = duration;
    if (value == null || value == Duration.zero) return null;
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (value.inHours > 0) {
      return '${value.inHours}:${value.inMinutes.remainder(60).toString().padLeft(2, '0')}:$seconds';
    }
    return '${value.inMinutes}:$seconds';
  }

  Uri? get _albumArtUri {
    final uri = Uri.tryParse(albumArt?.full ?? '');
    return uri != null &&
            ((uri.hasAuthority &&
                    (uri.scheme == 'https' || uri.scheme == 'http')) ||
                (uri.scheme == 'file' && uri.path.isNotEmpty))
        ? uri
        : null;
  }

  //MediaItem
  MediaItem toMediaItem() => MediaItem(
    title: title ?? '',
    album: album?.title ?? '',
    artist: artistString,
    displayTitle: title,
    displaySubtitle: artistString,
    displayDescription: album?.title,
    artUri: _albumArtUri,
    duration: duration,
    id: id ?? '',
    playable: !(unavailable == true),
    extras: {
      'unavailable': unavailable == true,
      'unavailableReason': unavailableReason,
      'playbackDetails': jsonEncode(playbackDetails),
      'thumb': albumArt?.thumb,
      'lyrics': jsonEncode(lyrics?.toJson()),
      'albumId': album?.id,
      'trackNumber': trackNumber,
      'discNumber': diskNumber,
      'explicit': explicit,
      'artists': jsonEncode(artists?.map<Map>((art) => art.toJson()).toList()),
      'navigableArtists': navigableArtists != null
          ? jsonEncode(
              navigableArtists?.map<Map>((art) => art.toJson()).toList(),
            )
          : null,
      'contributors': jsonEncode(contributors?.toJson()),
      'fallbackId': fallback?.id,
      'playbackDetailsFallback': jsonEncode(playbackDetailsFallback),
      'variation': variation,
      'platformId': platformId,
      'caption': albumArt?.caption,
      'displayArtistName': displayArtistName,
      if (qualityFormat != null) 'qualityFormat': qualityFormat,
      if (qualityBitrate != null) 'qualityBitrate': qualityBitrate,
    },
  );

  factory Track.fromMediaItem(MediaItem mi) {
    //Load album, artists & originalId (if track is result of fallback).
    //It is stored separately, to save id and other metadata
    final pId = mi.extras?['platformId'] as String? ?? 'deezer';
    final explicitValue = mi.extras?['explicit'];
    final explicit = explicitValue is bool
        ? explicitValue
        : explicitValue == 1 || explicitValue == '1'
        ? true
        : explicitValue == 0 || explicitValue == '0'
        ? false
        : null;
    Album album = Album(title: mi.album, platformId: pId);
    List<Artist> artists = [
      Artist(name: mi.displaySubtitle ?? mi.artist, platformId: pId),
    ];
    album.id = mi.extras?['albumId'];
    if (mi.extras?['artists'] != null && mi.extras?['artists'] != 'null') {
      try {
        final decoded = jsonDecode(mi.extras!['artists']);
        if (decoded is List) {
          artists = decoded.map<Artist>((j) => Artist.fromJson(j)).toList();
        }
      } catch (_) {}
    }
    List<String>? playbackDetails;
    if (mi.extras?['playbackDetails'] != null) {
      playbackDetails = (jsonDecode(mi.extras?['playbackDetails']) ?? [])
          .map<String>((e) => e.toString())
          .toList();
    }
    Contributors? contributors;
    if (mi.extras?['contributors'] != null &&
        mi.extras?['contributors'] != 'null') {
      contributors = Contributors.fromJson(
        jsonDecode(mi.extras?['contributors']),
      );
    }

    Track fallback = Track(id: mi.extras?['fallbackId'], platformId: pId);
    List<String>? playbackDetailsFallback;
    if (mi.extras?['playbackDetailsFallback'] != null) {
      playbackDetailsFallback =
          (jsonDecode(mi.extras?['playbackDetailsFallback']) ?? [])
              .map<String>((e) => e.toString())
              .toList();
    }

    int? variation;
    if (mi.extras?['variation'] != null) {
      variation = mi.extras?['variation'] as int?;
    }

    List<Artist>? navigableArtists;
    if (mi.extras?['navigableArtists'] != null &&
        mi.extras?['navigableArtists'] != 'null') {
      try {
        final decoded = jsonDecode(mi.extras!['navigableArtists']);
        if (decoded is List) {
          navigableArtists = decoded
              .map<Artist>((j) => Artist.fromJson(j))
              .toList();
        }
      } catch (_) {}
    }

    return Track(
      title: mi.title.isEmpty ? mi.displayTitle : mi.title,
      artists: artists,
      displayArtistName: mi.extras?['displayArtistName'] as String?,
      album: album,
      id: (mi.extras?['radioTrackId'] as String?) ?? mi.id,
      albumArt: ImageDetails(
        fullUrl: mi.artUri?.toString(),
        thumbUrl: mi.extras?['thumb'],
        caption: mi.extras?['caption'] as String?,
      ),
      platformId: mi.extras?['platformId'] ?? 'deezer',
      duration: mi.duration,
      trackNumber: int.tryParse(mi.extras?['trackNumber']?.toString() ?? ''),
      diskNumber: int.tryParse(mi.extras?['discNumber']?.toString() ?? ''),
      qualityFormat: mi.extras?['qualityFormat'] as String?,
      qualityBitrate: int.tryParse(
        mi.extras?['qualityBitrate']?.toString() ?? '',
      ),
      explicit: explicit,
      navigableArtists: navigableArtists,
      playbackDetails: playbackDetails,
      lyrics: (mi.extras?['lyrics'] != null && mi.extras!['lyrics'] != 'null')
          ? LyricsFull.fromJson(jsonDecode(mi.extras!['lyrics']))
          : null,
      contributors: contributors,
      fallback: fallback,
      playbackDetailsFallback: playbackDetailsFallback,
      variation: variation,
      unavailable: mi.extras?['unavailable'] == true,
      unavailableReason: mi.extras?['unavailableReason'] as String?,
    );
  }

  //JSON
  factory Track.fromPrivateJson(
    Map<dynamic, dynamic> originalJson, {
    bool favorite = false,
  }) {
    // If a fallback is provided, use the fallback's data for everything except the original ID.
    // This perfectly routes metadata, artwork, lyrics, and stream to the available track
    // while keeping the original track ID intact for playlist management.
    final json = originalJson['FALLBACK'] ?? originalJson;

    String title = json['SNG_TITLE']?.toString() ?? '';
    if (json['VERSION'] != null && json['VERSION'] != '') {
      title = "${json['SNG_TITLE']} ${json['VERSION']}";
    }
    return Track(
      id: originalJson['SNG_ID']?.toString(),
      title: title,
      duration: Duration(
        seconds: int.tryParse(json['DURATION']?.toString() ?? '0') ?? 0,
      ),
      albumArt: json['ALB_PICTURE'] != null
          ? ImageDetails.fromPrivateString(json['ALB_PICTURE'].toString())
          : null,
      album: Album.fromPrivateJson(json),
      artists: (json['ARTISTS'] ?? [json])
          .map<Artist>((dynamic art) => Artist.fromPrivateJson(art))
          .toList(),
      displayArtistName:
          (json['ARTISTS'] is List && (json['ARTISTS'] as List).isEmpty)
          ? (json['ART_NAME'] as String?)
          : null,
      trackNumber: int.tryParse((json['TRACK_NUMBER'] ?? '0').toString()) ?? 0,
      playbackDetails: [
        json['MD5_ORIGIN'],
        json['MEDIA_VERSION'],
        json['TRACK_TOKEN'],
      ],
      lyrics: LyricsFull(id: json['LYRICS_ID']?.toString() ?? ''),
      favorite: favorite,
      diskNumber: int.tryParse((json['DISK_NUMBER'] ?? '1').toString()) ?? 1,
      explicit: (json['EXPLICIT_LYRICS'].toString() == '1') ? true : false,
      addedDate: () {
        final val = originalJson['DATE_PLAYED'] ??
            originalJson['DATE_ADD'] ??
            json['DATE_ADD'];
        if (val is int) return val;
        if (val != null) return int.tryParse(val.toString());
        return null;
      }(),
      contributors:
          (json['SNG_CONTRIBUTORS'] != null && json['SNG_CONTRIBUTORS'] is Map)
          ? Contributors.fromPrivateJson(json['SNG_CONTRIBUTORS'])
          : null,
      fallback: (originalJson['FALLBACK'] != null)
          ? Track(id: originalJson['FALLBACK']['SNG_ID'].toString())
          : null,
      playbackDetailsFallback: (originalJson['FALLBACK'] != null)
          ? [
              originalJson['FALLBACK']['MD5_ORIGIN'],
              originalJson['FALLBACK']?['MEDIA_VERSION'],
              originalJson['FALLBACK']?['TRACK_TOKEN'],
            ]
          : null,
      variation: json['VARIATION'],
      unavailable:
          originalJson['RIGHTS'] != null &&
          originalJson['RIGHTS'] is Map &&
          (originalJson['RIGHTS'] as Map).isEmpty &&
          originalJson['FALLBACK'] == null,
    );
  }
  Map<String, dynamic> toSQL({bool off = false}) => {
    'id': id,
    'title': title,
    'album': album?.id,
    'artists': artists?.map<String>((dynamic a) => a.id).join(','),
    'duration': duration?.inSeconds,
    'albumArt': albumArt?.full,
    'trackNumber': trackNumber,
    'qualityFormat': qualityFormat,
    'qualityBitrate': qualityBitrate,
    'offline': off ? 1 : 0,
    'lyrics': jsonEncode(lyrics?.toJson()),
    'unavailable': unavailable == true ? 1 : 0,
    'unavailableReason': unavailableReason,
    'favorite': (favorite ?? false) ? 1 : 0,
    'diskNumber': diskNumber,
    'explicit': (explicit ?? false) ? 1 : 0,
    'contributors': jsonEncode(contributors?.toJson()),
    'fallback': fallback?.id,
    'platformId': platformId,
    //'favoriteDate': favoriteDate
  };
  factory Track.fromSQL(Map<String, dynamic> data) => Track(
    id: data['trackId'] ?? data['id'], //If loading from downloads table
    title: data['title'],
    album: Album(id: data['album'], title: ''),
    duration: Duration(seconds: data['duration'] ?? 0),
    albumArt: ImageDetails(fullUrl: data['albumArt']),
    trackNumber: data['trackNumber'],
    qualityFormat: data['qualityFormat'] as String?,
    qualityBitrate: data['qualityBitrate'] as int?,
    artists: List<Artist>.generate(
      (data['artists'] as String? ?? '')
          .split(',')
          .where((id) => id.isNotEmpty)
          .length,
      (i) => Artist(
        id: (data['artists'] as String? ?? '')
            .split(',')
            .where((id) => id.isNotEmpty)
            .elementAt(i),
      ),
    ),
    offline: (data['offline'] == 1) ? true : false,
    unavailable: data['unavailable'] == 1 || data['unavailable'] == true,
    unavailableReason: data['unavailableReason'] as String?,
    lyrics: data['lyrics'] == null || data['lyrics'] == 'null'
        ? null
        : LyricsFull.fromJson(jsonDecode(data['lyrics'])),
    favorite: (data['favorite'] == 1) ? true : false,
    diskNumber: data['diskNumber'],
    explicit: (data['explicit'] == 1) ? true : false,
    contributors: data['contributors'] == null || data['contributors'] == 'null'
        ? null
        : Contributors.fromJson(jsonDecode(data['contributors'])),
    fallback: data['fallback'] != null
        ? Track(id: data['fallback'].toString())
        : null,
    platformId: data['platformId'] as String? ?? 'deezer',
    //favoriteDate: data['favoriteDate']
  );

  factory Track.fromJson(Map<String, dynamic> json) => _$TrackFromJson(json);
  Map<String, dynamic> toJson() => _$TrackToJson(this);
}

@JsonSerializable()
class Contributors {
  List<String>? composers;
  List<String>? engineers;
  List<String>? mixers;
  List<String>? producers;
  List<String>? authors;
  List<String>? writers;

  Contributors({
    this.composers,
    this.engineers,
    this.mixers,
    this.producers,
    this.authors,
    this.writers,
  });

  factory Contributors.fromPrivateJson(Map<dynamic, dynamic> json) {
    return Contributors(
      composers: json['composer'] != null
          ? List<String>.from(json['composer'])
          : null,
      engineers: json['engineer'] != null
          ? List<String>.from(json['engineer'])
          : null,
      mixers: json['mixer'] != null ? List<String>.from(json['mixer']) : null,
      producers: json['producer'] != null
          ? List<String>.from(json['producer'])
          : null,
      authors: json['author'] != null
          ? List<String>.from(json['author'])
          : null,
      writers: json['writer'] != null
          ? List<String>.from(json['writer'])
          : null,
    );
  }

  factory Contributors.fromJson(Map<String, dynamic> json) =>
      _$ContributorsFromJson(json);
  Map<String, dynamic> toJson() => _$ContributorsToJson(this);
}

enum AlbumType { ALBUM, SINGLE, FEATURED }

@JsonSerializable()
class Album {
  String? id;
  String? title;
  List<Artist>? artists;
  List<Track>? tracks;
  ImageDetails? art;
  int? fans;
  bool? offline; //If the album is offline, or just saved in db as metadata
  bool? library;
  bool pinned;
  AlbumType? type;
  String? releaseDate;
  String? favoriteDate;
  bool hasIdentifiedAIContent;

  /// The platform this album originated from, e.g. 'deezer', 'soundcloud'.
  @JsonKey(defaultValue: 'deezer')
  String platformId;

  Album({
    this.id,
    this.title,
    this.art,
    this.artists,
    this.tracks,
    this.fans,
    this.offline,
    this.library,
    this.pinned = false,
    this.type = AlbumType.ALBUM,
    this.releaseDate,
    this.favoriteDate,
    this.platformId = 'deezer',
    this.hasIdentifiedAIContent = false,
  });

  String? get artistString {
    final artistNames = (artists ?? const <Artist>[])
        .map((artist) => artist.name?.trim() ?? '')
        .where((name) => name.isNotEmpty)
        .toList();
    if (artistNames.isNotEmpty) return artistNames.join(', ');

    for (final track in tracks ?? const <Track>[]) {
      final name = track.artistString?.trim();
      if (name != null && name.isNotEmpty) return name;
    }
    return null;
  }
  Duration get duration {
    final tr = tracks;
    if (tr == null || tr.isEmpty) return Duration.zero;
    return Duration(
      seconds: tr.fold(0, (v, t) => v + (t.duration?.inSeconds ?? 0)),
    );
  }

  String get durationString {
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (duration.inHours > 0) {
      return '${duration.inHours}:${duration.inMinutes.remainder(60).toString().padLeft(2, '0')}:$seconds';
    }
    return '${duration.inMinutes}:$seconds';
  }

  String? get fansString =>
      fans != null ? NumberFormat.compact().format(fans) : '';

  //JSON
  factory Album.fromPrivateJson(
    Map<dynamic, dynamic> json, {
    Map<dynamic, dynamic> songsJson = const {},
    bool library = false,
  }) {
    AlbumType type = AlbumType.ALBUM;
    if (json['TYPE'] != null && json['TYPE'].toString() == '0') {
      type = AlbumType.SINGLE;
    }
    if (json['ROLE_ID'] == 5) type = AlbumType.FEATURED;

    return Album(
      id: json['ALB_ID']?.toString(),
      title: json['ALB_TITLE'],
      art: json['ALB_PICTURE'] != null
          ? ImageDetails.fromPrivateString(json['ALB_PICTURE'].toString())
          : null,
      artists:
          ((json['ARTISTS'] is List &&
                      (json['ARTISTS'] as List).isNotEmpty)
                  ? json['ARTISTS'] as List
                  : (json['ART_NAME'] != null ? [json] : <dynamic>[]))
          .map<Artist>((dynamic art) => Artist.fromPrivateJson(art))
          .toList(),
      tracks: (songsJson['data'] ?? [])
          .map<Track>((dynamic track) => Track.fromPrivateJson(track))
          .toList(),
      fans: json['NB_FAN'],
      library: library,
      type: type,
      releaseDate:
          json['DIGITAL_RELEASE_DATE'] ?? json['PHYSICAL_RELEASE_DATE'],
      favoriteDate: json['DATE_FAVORITE'],
    );
  }
  Map<String, dynamic> toSQL({bool off = false}) => {
    'id': id,
    'title': title,
    'artists': (artists ?? []).map<String>((dynamic a) => a.id).join(','),
    'tracks': (tracks ?? []).map<String>((dynamic t) => t.id).join(','),
    'art': art?.full ?? '',
    'fans': fans,
    'offline': off ? 1 : 0,
    'library': (library ?? false) ? 1 : 0,
    'type': (type != null) ? AlbumType.values.indexOf(type!) : -1,
    'releaseDate': releaseDate,
    'platformId': platformId,
    //'favoriteDate': favoriteDate
  };
  factory Album.fromSQL(Map<String, dynamic> data) => Album(
    id: data['id'],
    title: data['title'],
    artists: List<Artist>.generate(
      data['artists'].split(',').length,
      (i) => Artist(id: data['artists'].split(',')[i]),
    ),
    tracks: List<Track>.generate(
      data['tracks'].split(',').length,
      (i) => Track(id: data['tracks'].split(',')[i]),
    ),
    art: ImageDetails(fullUrl: data['art']),
    fans: data['fans'],
    offline: (data['offline'] == 1) ? true : false,
    library: (data['library'] == 1) ? true : false,
    type: AlbumType.values[(data['type'] == -1) ? 0 : data['type']],
    releaseDate: data['releaseDate'],
    platformId: data['platformId'] as String? ?? 'deezer',
    //favoriteDate: data['favoriteDate']
  );

  factory Album.fromJson(Map<String, dynamic> json) => _$AlbumFromJson(json);
  Map<String, dynamic> toJson() => _$AlbumToJson(this);
}

enum ArtistHighlightType { ALBUM }

@JsonSerializable()
class ArtistHighlight {
  dynamic data;
  ArtistHighlightType? type;
  String? title;

  ArtistHighlight({this.data, this.type, this.title});

  static ArtistHighlight? fromPrivateJson(Map<dynamic, dynamic> json) {
    if (json['ITEM'] == null) return null;
    switch (json['TYPE']) {
      case 'album':
        return ArtistHighlight(
          data: Album.fromPrivateJson(json['ITEM']),
          type: ArtistHighlightType.ALBUM,
          title: json['TITLE'],
        );
    }
    return null;
  }

  //JSON
  factory ArtistHighlight.fromJson(Map<String, dynamic> json) =>
      _$ArtistHighlightFromJson(json);
  Map<String, dynamic> toJson() => _$ArtistHighlightToJson(this);
}

@JsonSerializable()
class Artist {
  String? id;
  String? name;
  List<Album> albums;
  int? albumCount;
  List<Track> topTracks;
  String? topSongsPlaylistId;
  ImageDetails? picture;
  int? fans;
  bool? offline;
  bool? library;
  bool pinned;
  bool? radio;

  /// Chart movement: positive moved up, negative moved down, zero unchanged.
  int? variation;
  String? description;
  @JsonKey(includeFromJson: false, includeToJson: false)
  List<Playlist> playlists;
  @JsonKey(includeFromJson: false, includeToJson: false)
  List<Artist> similarArtists;
  @JsonKey(includeFromJson: false, includeToJson: false)
  bool pageSectionsLoaded;

  /// Runtime-only data owned by the platform adapter for custom page sections.
  @JsonKey(includeFromJson: false, includeToJson: false)
  Map<String, dynamic> customData;
  String? favoriteDate;
  ArtistHighlight? highlight;

  /// The platform this artist originated from, e.g. 'deezer', 'soundcloud'.
  @JsonKey(defaultValue: 'deezer')
  String platformId;

  Artist({
    this.id,
    this.name,
    this.albums = const [],
    this.albumCount,
    this.topTracks = const [],
    this.topSongsPlaylistId,
    this.picture,
    this.fans,
    this.offline,
    this.library,
    this.pinned = false,
    this.radio,
    this.variation,
    this.description,
    this.playlists = const [],
    this.similarArtists = const [],
    this.pageSectionsLoaded = false,
    this.customData = const {},
    this.favoriteDate,
    this.highlight,
    this.platformId = 'deezer',
  });

  String get fansString =>
      fans != null ? NumberFormat.compact().format(fans) : '';
  String get albumCountString =>
      albumCount != null ? NumberFormat.compact().format(albumCount) : '';

  //JSON
  factory Artist.fromPrivateJson(
    Map<dynamic, dynamic> json, {
    Map<dynamic, dynamic> albumsJson = const {},
    Map<dynamic, dynamic> topJson = const {},
    Map<dynamic, dynamic> highlight = const {},
    bool library = false,
  }) {
    //Get wether radio is available
    bool radio = false;
    if (json['SMARTRADIO'] == true || json['SMARTRADIO'] == 1) radio = true;

    return Artist(
      id: json['ART_ID']?.toString(),
      name: json['ART_NAME'],
      fans: json['NB_FAN'],
      picture: json['ART_PICTURE'] == null
          ? null
          : ImageDetails.fromPrivateString(json['ART_PICTURE'], type: 'artist'),
      albumCount: albumsJson['total'],
      albums: (albumsJson['data'] ?? [])
          .map<Album>((dynamic data) => Album.fromPrivateJson(data))
          .toList(),
      topTracks: (topJson['data'] ?? [])
          .map<Track>((dynamic data) => Track.fromPrivateJson(data))
          .toList(),
      library: library,
      radio: radio,
      favoriteDate: json['DATE_FAVORITE'],
      highlight: ArtistHighlight.fromPrivateJson(highlight),
    );
  }
  Map<String, dynamic> toSQL({bool off = false}) => {
    'id': id,
    'name': name,
    'albums': albums.map<String>((dynamic a) => a.id).join(','),
    'topTracks': topTracks.map<String>((dynamic t) => t.id).join(','),
    'picture': picture?.full ?? '',
    'fans': fans,
    'albumCount': albumCount ?? albums.length,
    'offline': off ? 1 : 0,
    'library': (library ?? false) ? 1 : 0,
    'radio': (radio ?? false) ? 1 : 0,
    'platformId': platformId,
    //'favoriteDate': favoriteDate
  };
  factory Artist.fromSQL(Map<String, dynamic> data) => Artist(
    id: data['id'],
    name: data['name'],
    topTracks: List<Track>.generate(
      data['topTracks'].split(',').length,
      (i) => Track(id: data['topTracks'].split(',')[i]),
    ),
    albums: List<Album>.generate(
      data['albums'].split(',').length,
      (i) => Album(id: data['albums'].split(',')[i], title: ''),
    ),
    albumCount: data['albumCount'],
    picture: ImageDetails(fullUrl: data['picture']),
    fans: data['fans'],
    offline: (data['offline'] == 1) ? true : false,
    library: (data['library'] == 1) ? true : false,
    radio: (data['radio'] == 1) ? true : false,
    platformId: data['platformId'] as String? ?? 'deezer',
    //favoriteDate: data['favoriteDate']
  );

  factory Artist.fromJson(Map<String, dynamic> json) => _$ArtistFromJson(json);
  Map<String, dynamic> toJson() => _$ArtistToJson(this);
}

@JsonSerializable()
class Playlist {
  String? id;
  String? title;
  List<Track>? tracks;
  ImageDetails? image;
  Duration? duration;
  int? trackCount;
  User? user;
  int? fans;
  bool? library;
  bool pinned;
  String? description;
  bool? editable;
  List<String>? mosaicImages;
  List<String?>? mosaicImageCaptions;
  bool? disableDownload;

  /// The platform this playlist originated from, e.g. 'deezer', 'soundcloud'.
  @JsonKey(defaultValue: 'deezer')
  String platformId;

  Playlist({
    this.id,
    this.title,
    this.tracks,
    this.image,
    this.trackCount,
    this.duration,
    this.user,
    this.fans,
    this.library,
    this.pinned = false,
    this.description,
    this.editable,
    this.mosaicImages,
    this.mosaicImageCaptions,
    this.disableDownload,
    this.platformId = 'deezer',
  });

  String get durationString {
    final d = duration;
    if (d == null) return '0:00';
    if (d.inHours > 0) {
      return "${d.inHours}:${d.inMinutes.remainder(60).toString().padLeft(2, '0')}:${d.inSeconds.remainder(60).toString().padLeft(2, '0')}";
    }
    return "${d.inMinutes}:${d.inSeconds.remainder(60).toString().padLeft(2, '0')}";
  }

  //JSON
  factory Playlist.fromPrivateJson(
    Map<dynamic, dynamic> json, {
    Map<dynamic, dynamic> songsJson = const {},
    bool library = false,
  }) => Playlist(
    id: json['PLAYLIST_ID'].toString(),
    title: json['TITLE'],
    trackCount: json['NB_SONG'] ?? songsJson['total'],
    image: ImageDetails.fromPrivateString(
      json['PLAYLIST_PICTURE'],
      type: json['PICTURE_TYPE'],
    ),
    fans: json['NB_FAN'],
    duration: Duration(seconds: json['DURATION'] ?? 0),
    description: json['DESCRIPTION'],
    user: User(
      id: json['PARENT_USER_ID'],
      name: json['PARENT_USERNAME'] ?? '',
      picture: ImageDetails.fromPrivateString(
        json['PARENT_USER_PICTURE'] ?? '',
        type: 'user',
      ),
    ),
    tracks: (songsJson['data'] ?? [])
        .map<Track>((dynamic data) => Track.fromPrivateJson(data))
        .toList(),
    library: library,
  );
  Map<String, dynamic> toSQL() => {
    'id': id,
    'title': title,
    'tracks': tracks?.map<String>((dynamic t) => t.id).join(','),
    'image': image?.full,
    'duration': duration?.inSeconds,
    'userId': user?.id,
    'userName': user?.name,
    'fans': fans,
    'description': description,
    'library': (library ?? false) ? 1 : 0,
    'platformId': platformId,
    'mosaicImages': mosaicImages != null ? jsonEncode(mosaicImages) : null,
  };
  factory Playlist.fromSQL(Map<String, dynamic> data) => Playlist(
    id: data['id'],
    title: data['title'],
    description: data['description'],
    tracks: (data['tracks'] as String? ?? '')
        .split(',')
        .where((id) => id.isNotEmpty)
        .map((id) => Track(id: id))
        .toList(),
    image: ImageDetails(fullUrl: data['image']),
    duration: Duration(seconds: data['duration'] ?? 0),
    user: User(id: data['userId'], name: data['userName']),
    fans: data['fans'],
    library: (data['library'] == 1) ? true : false,
    platformId: data['platformId'] as String? ?? 'deezer',
    mosaicImages: data['mosaicImages'] == null
        ? null
        : List<String>.from(jsonDecode(data['mosaicImages'].toString())),
  );

  factory Playlist.fromJson(Map<String, dynamic> json) =>
      _$PlaylistFromJson(json);
  Map<String, dynamic> toJson() => _$PlaylistToJson(this);
}

@JsonSerializable()
class LocalPlaylist {
  String id;
  String title;
  String? description;
  List<String> trackIds;
  DateTime createdAt;
  DateTime updatedAt;
  bool offline;
  List<String>? mosaicImages;

  LocalPlaylist({
    required this.id,
    required this.title,
    this.description,
    required this.trackIds,
    required this.createdAt,
    required this.updatedAt,
    this.offline = false,
    this.mosaicImages,
  });

  LocalPlaylist copyWith({
    String? title,
    String? description,
    List<String>? trackIds,
    DateTime? updatedAt,
    bool? offline,
    List<String>? mosaicImages,
  }) {
    return LocalPlaylist(
      id: id,
      title: title ?? this.title,
      description: description ?? this.description,
      trackIds: trackIds ?? this.trackIds,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      offline: offline ?? this.offline,
      mosaicImages: mosaicImages ?? this.mosaicImages,
    );
  }

  int get trackCount => trackIds.length;

  Duration get duration => Duration.zero;

  String get durationString => '0:00:00';

  Map<String, dynamic> toExportJson() => {
    'title': title,
    'description': description,
    'trackIds': trackIds,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'mosaicImages': mosaicImages,
  };

  factory LocalPlaylist.fromExportJson(Map<String, dynamic> json) =>
      LocalPlaylist(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        title: json['title'] ?? 'Imported Playlist',
        description: json['description'],
        trackIds: List<String>.from(json['trackIds'] ?? []),
        createdAt: DateTime.parse(
          json['createdAt'] ?? DateTime.now().toIso8601String(),
        ),
        updatedAt: DateTime.parse(
          json['updatedAt'] ?? DateTime.now().toIso8601String(),
        ),
        mosaicImages: json['mosaicImages'] != null
            ? List<String>.from(json['mosaicImages'])
            : null,
      );

  Map<String, dynamic> toSQL() => {
    'id': id,
    'title': title,
    'description': description,
    'trackIds': trackIds.join(','),
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'offline': offline ? 1 : 0,
    'mosaicImages': mosaicImages != null ? jsonEncode(mosaicImages) : null,
  };

  factory LocalPlaylist.fromSQL(Map<String, dynamic> data) => LocalPlaylist(
    id: data['id'],
    title: data['title'],
    description: data['description'],
    trackIds:
        (data['trackIds'] as String?)
            ?.split(',')
            .where((id) => id.isNotEmpty)
            .toList() ??
        [],
    createdAt: data['createdAt'] != null
        ? DateTime.tryParse(data['createdAt'].toString()) ?? DateTime.now()
        : DateTime.now(),
    updatedAt: data['updatedAt'] != null
        ? DateTime.tryParse(data['updatedAt'].toString()) ?? DateTime.now()
        : DateTime.now(),
    offline: data['offline'] == 1,
    mosaicImages: data['mosaicImages'] != null
        ? (data['mosaicImages'].toString().startsWith('[')
              ? List<String>.from(jsonDecode(data['mosaicImages']))
              : (data['mosaicImages'] as String)
                    .split(',')
                    .where((e) => e.isNotEmpty)
                    .toList())
        : null,
  );

  factory LocalPlaylist.fromJson(Map<String, dynamic> json) =>
      _$LocalPlaylistFromJson(json);
  Map<String, dynamic> toJson() => _$LocalPlaylistToJson(this);
}

@JsonSerializable()
class User {
  String? id;
  String? name;
  ImageDetails? picture;

  User({this.id, this.name, this.picture});

  //Mostly handled by playlist

  factory User.fromJson(Map<String, dynamic> json) => _$UserFromJson(json);
  Map<String, dynamic> toJson() => _$UserToJson(this);
}

@JsonSerializable()
class ImageDetails {
  String? fullUrl;
  String? thumbUrl;
  String? type;
  String? imageHash;
  String? caption;

  ImageDetails({
    this.fullUrl,
    this.thumbUrl,
    this.type,
    this.imageHash,
    this.caption,
  });

  //Get full/thumb with fallback
  String? get full => fullUrl ?? thumbUrl;
  String? get thumb => thumbUrl ?? fullUrl;

  //Get custom sized image
  String customUrl(String height, String width, {String quality = '80'}) {
    return 'https://e-cdns-images.dzcdn.net/images/$type/$imageHash/${height}x$width-000000-$quality-0-0.jpg';
  }

  //JSON
  factory ImageDetails.fromPrivateString(
    String imageHash, {
    String type = 'cover',
  }) => ImageDetails(
    type: type,
    imageHash: imageHash,
    fullUrl:
        'https://e-cdns-images.dzcdn.net/images/$type/$imageHash/1000x1000-000000-80-0-0.jpg',
    thumbUrl:
        'https://e-cdns-images.dzcdn.net/images/$type/$imageHash/140x140-000000-80-0-0.jpg',
  );
  factory ImageDetails.fromPrivateJson(Map<dynamic, dynamic> json) =>
      ImageDetails.fromPrivateString(
        json['MD5'] ?? json['md5'],
        type: json['TYPE'] ?? json['type'],
      );
  //ImageDetails.fromPrivateString((json['MD5']?.split('-')?.first) ?? json['md5'],
  //type: json['TYPE'] ?? json['type']);

  factory ImageDetails.fromJson(Map<String, dynamic> json) =>
      _$ImageDetailsFromJson(json);
  Map<String, dynamic> toJson() => _$ImageDetailsToJson(this);
}

@JsonSerializable()
class FlowImage {
  String? fullUrl;
  String? thumbUrl;
  String? type;
  String? imageHash;

  FlowImage({this.fullUrl, this.thumbUrl, this.type, this.imageHash});

  //Get full/thumb with fallback
  String? get full => fullUrl ?? thumbUrl;
  String? get thumb => thumbUrl ?? fullUrl;

  //Get custom sized image
  String customUrl(String height, String width, {String quality = '80'}) {
    return 'https://e-cdns-images.dzcdn.net/images/$type/$imageHash/${height}x$width-000000-$quality-0-0.png';
  }

  //JSON
  factory FlowImage.fromPrivateString(
    String imageHash, {
    String type = 'cover',
  }) => FlowImage(
    type: type,
    imageHash: imageHash,
    fullUrl:
        'https://e-cdns-images.dzcdn.net/images/$type/$imageHash/1000x1000-000000-80-0-0.png',
    thumbUrl:
        'https://e-cdns-images.dzcdn.net/images/$type/$imageHash/140x140-000000-80-0-0.png',
  );
  factory FlowImage.fromPrivateJson(Map<dynamic, dynamic> json) =>
      FlowImage.fromPrivateString(
        json['MD5'] ?? json['md5'],
        type: json['TYPE'] ?? json['type'],
      );
  //ImageDetails.fromPrivateString((json['MD5']?.split('-')?.first) ?? json['md5'],
  //type: json['TYPE'] ?? json['type']);

  factory FlowImage.fromJson(Map<String, dynamic> json) =>
      _$FlowImageFromJson(json);
  Map<String, dynamic> toJson() => _$FlowImageToJson(this);
}

@JsonSerializable()
class LogoDetails {
  String? fullUrl;
  String? thumbUrl;
  String? type;
  String? imageHash;

  LogoDetails({this.fullUrl, this.thumbUrl, this.type, this.imageHash});

  //Get full/thumb with fallback
  String? get full => fullUrl ?? thumbUrl;
  String? get thumb => thumbUrl ?? fullUrl;

  //Get custom sized logo
  String customUrl(
    String height, {
    String width = '0',
    String quality = '100',
  }) {
    return 'https://e-cdns-images.dzcdn.net/images/$type/$imageHash/${height}x$width-none-$quality-0-0.png';
  }

  //JSON
  factory LogoDetails.fromPrivateString(
    String imageHash, {
    String type = 'misc',
  }) => LogoDetails(
    type: type,
    imageHash: imageHash,
    fullUrl:
        'https://e-cdns-images.dzcdn.net/images/$type/$imageHash/208x0-none-100-0-0.png',
    thumbUrl:
        'https://e-cdns-images.dzcdn.net/images/$type/$imageHash/52x0-none-100-0-0.png',
  );
  factory LogoDetails.fromPrivateJson(Map<dynamic, dynamic> json) =>
      LogoDetails.fromPrivateString(
        (json['MD5']?.split('-')?.first) ?? json['md5'],
        type: json['TYPE'] ?? json['type'],
      );

  factory LogoDetails.fromJson(Map<String, dynamic> json) =>
      _$LogoDetailsFromJson(json);
  Map<String, dynamic> toJson() => _$LogoDetailsToJson(this);
}

class SearchResults {
  List<Track>? tracks;
  List<Album>? albums;
  List<Artist>? artists;
  List<Playlist>? playlists;
  List<Playlist>? setlists;
  List<Show>? shows;
  List<ShowEpisode>? episodes;
  List<LiveRadio>? radios;

  SearchResults({
    this.tracks,
    this.albums,
    this.artists,
    this.playlists,
    this.setlists,
    this.shows,
    this.episodes,
    this.radios,
  });

  //Check if no search results
  bool get empty {
    return ((tracks == null || tracks!.isEmpty) &&
        (albums == null || albums!.isEmpty) &&
        (artists == null || artists!.isEmpty) &&
        (playlists == null || playlists!.isEmpty) &&
        (setlists == null || setlists!.isEmpty) &&
        (shows == null || shows!.isEmpty) &&
        (episodes == null || episodes!.isEmpty) &&
        (radios == null || radios!.isEmpty));
  }

  factory SearchResults.fromPrivateJson(Map<dynamic, dynamic> json) {
    final result = SearchResults(
      tracks: json['TRACK']?['data']
          ?.map<Track>((dynamic data) => Track.fromPrivateJson(data))
          .toList(),
      albums: json['ALBUM']?['data']
          ?.map<Album>((dynamic data) => Album.fromPrivateJson(data))
          .toList(),
      artists: json['ARTIST']?['data']
          ?.map<Artist>((dynamic data) => Artist.fromPrivateJson(data))
          .toList(),
      playlists: json['PLAYLIST']?['data']
          ?.map<Playlist>((dynamic data) => Playlist.fromPrivateJson(data))
          .toList(),
      shows: json['SHOW']?['data']
          ?.map<Show>((dynamic data) => Show.fromPrivateJson(data))
          .toList(),
      episodes: json['EPISODE']?['data']
          ?.map<ShowEpisode>(
            (dynamic data) => ShowEpisode.fromPrivateJson(data),
          )
          .toList(),
      radios:
          [
                if (json['RADIO']?['data'] != null) ...json['RADIO']!['data'],
                if (json['LIVESTREAM']?['data'] != null)
                  ...json['LIVESTREAM']!['data'],
                if (json['CHANNEL']?['data'] != null)
                  ...json['CHANNEL']!['data'],
              ]
              .map<LiveRadio>((dynamic data) => LiveRadio.fromPrivateJson(data))
              .where(
                (r) =>
                    r.id != null &&
                    (r.title != null && r.title!.trim().isNotEmpty),
              )
              .toList(),
    );
    return result;
  }
}

class Lyrics {
  String? id;
  String? writers;
  List<SynchronizedLyric>? syncedLyrics;
  String? errorMessage;
  String? unsyncedLyrics;
  String? unsyncedTranslatedLyrics;
  String? unsyncedRomanizedLyrics;
  bool? isExplicit;
  String? copyright;

  Lyrics({
    this.id,
    this.writers,
    this.syncedLyrics,
    this.unsyncedLyrics,
    this.unsyncedTranslatedLyrics,
    this.unsyncedRomanizedLyrics,
    this.errorMessage,
    this.isExplicit,
    this.copyright,
  });

  static void error(String? message) => Lyrics(
    id: null,
    writers: null,
    syncedLyrics: [
      SynchronizedLyric(
        offset: const Duration(milliseconds: 0),
        text: 'Lyrics unavailable, empty or failed to load!'.i18n,
      ),
    ],
    errorMessage: message,
  );

  static dynamic fromLRC(String lrcContent) {
    try {
      final List<SynchronizedLyric> syncedLyrics = [];
      // LRC commonly uses [mm:ss.xx], while some providers (including
      // NeuroKaraoke) return [hh:mm:ss.fffffff]. Accept both and normalize
      // fractional seconds to milliseconds when calculating offsets.
      final RegExp timeTagRegex = RegExp(
        r'\[((?:\d{2,}):)?(\d{2}):(\d{2})\.(\d{1,})\]',
      );
      final List<String> lines = lrcContent.split('\n');

      // Metadata fields from LRC
      String? author;

      for (String line in lines) {
        line = line.trim();
        if (line.isEmpty) continue;

        if (line.startsWith('[au:')) {
          author = line.substring(4, line.length - 1);
          continue;
        }

        // Parse time tags and lyrics
        final matches = timeTagRegex.allMatches(line);
        if (matches.isEmpty) continue;

        String lyricText = line.replaceAll(timeTagRegex, '').trim();

        for (Match match in matches) {
          final hours = match.group(1) == null
              ? 0
              : int.parse(match.group(1)!.substring(0, match.group(1)!.length - 1));
          final minutes = int.parse(match.group(2)!);
          final seconds = int.parse(match.group(3)!);
          final fraction = match.group(4)!;
          final millis = int.parse(
            fraction.length >= 3
                ? fraction.substring(0, 3)
                : fraction.padRight(3, '0'),
          );

          final offset = Duration(
            hours: hours,
            minutes: minutes,
            seconds: seconds,
            milliseconds: millis,
          );

          syncedLyrics.add(
            SynchronizedLyric(
              offset: offset,
              text: lyricText,
              lrcTimestamp: match
                  .group(0)!
                  .substring(1, match.group(0)!.length - 1),
            ),
          );
        }
      }

      // Sort lyrics by time
      syncedLyrics.sort((a, b) => a.offset!.compareTo(b.offset!));

      // Calculate durations
      for (int i = 0; i < syncedLyrics.length - 1; i++) {
        syncedLyrics[i].duration =
            syncedLyrics[i + 1].offset! - syncedLyrics[i].offset!;
      }
      // Last lyric duration (assume 5 seconds if no next lyric)
      if (syncedLyrics.isNotEmpty) {
        syncedLyrics.last.duration = const Duration(seconds: 5);
      }

      return Lyrics(syncedLyrics: syncedLyrics, writers: author);
    } catch (e) {
      return error('Failed to parse LRC file: $e');
    }
  }

  bool isLoaded() =>
      syncedLyrics?.isNotEmpty == true ||
      unsyncedLyrics?.isNotEmpty == true ||
      unsyncedTranslatedLyrics?.isNotEmpty == true ||
      unsyncedRomanizedLyrics?.isNotEmpty == true;

  bool isSynced() =>
      syncedLyrics?.isNotEmpty == true && syncedLyrics!.length > 1;

  bool isUnsynced() =>
      !isSynced() &&
      (unsyncedLyrics?.isNotEmpty == true ||
          unsyncedTranslatedLyrics?.isNotEmpty == true ||
          unsyncedRomanizedLyrics?.isNotEmpty == true);
}

@JsonSerializable()
class LyricsClassic extends Lyrics {
  LyricsClassic({
    super.id,
    super.writers,
    super.syncedLyrics,
    super.errorMessage,
    super.unsyncedLyrics,
    super.unsyncedTranslatedLyrics,
    super.unsyncedRomanizedLyrics,
  });

  factory LyricsClassic.fromPrivateJson(Map<dynamic, dynamic> json) {
    LyricsClassic l = LyricsClassic(
      id: json['LYRICS_ID'],
      writers: json['LYRICS_WRITERS'],
      syncedLyrics: (json['LYRICS_SYNC_JSON'] ?? [])
          .map<SynchronizedLyric>((l) => SynchronizedLyric.fromPrivateJson(l))
          .toList(),
      unsyncedLyrics: json['LYRICS_TEXT'],
    );
    l.syncedLyrics?.removeWhere((l) => l.offset == null);
    return l;
  }

  factory LyricsClassic.fromJson(Map<String, dynamic> json) =>
      _$LyricsClassicFromJson(json);

  Map<String, dynamic> toJson() => _$LyricsClassicToJson(this);
}

@JsonSerializable()
class LyricsFull extends Lyrics {
  LyricsFull({
    super.id,
    super.writers,
    super.syncedLyrics,
    super.errorMessage,
    super.unsyncedLyrics,
    super.unsyncedTranslatedLyrics,
    super.unsyncedRomanizedLyrics,
    super.isExplicit,
    super.copyright,
  });

  factory LyricsFull.fromPrivateJson(Map<dynamic, dynamic> json) {
    var lyricsJson = json['track']?['lyrics'];
    if (lyricsJson == null) {
      Logger.root.warning(
        'LyricsFull.fromPrivateJson: lyricsJson is null for json: $json',
      );
      lyricsJson = {};
    }

    Logger.root.info(
      'LyricsFull.fromPrivateJson processing track ID: ${json['track']?['id']}, lyrics keys: ${lyricsJson.keys}',
    );

    final rawWordByWord = lyricsJson['synchronizedWordByWordLines'] as List?;

    List<SynchronizedLyric> syncedLyrics;

    if (rawWordByWord != null && rawWordByWord.isNotEmpty) {
      List<LyricWord> parseWordList(List rawWords) {
        final List<LyricWord> wordList = [];
        for (int i = 0; i < rawWords.length; i++) {
          final w = rawWords[i];
          if (w is! Map) continue;
          final startMs = (w['start'] as num?)?.toInt() ?? 0;
          final endMs = (w['end'] as num?)?.toInt() ?? startMs;
          final durMs = (endMs > startMs) ? (endMs - startMs) : 120;
          final rawText = (w['word'] ?? w['text'] ?? '').toString();
          if (rawText.isEmpty) continue;
          final isLast = i == rawWords.length - 1;
          final wordText = (!isLast && !rawText.endsWith(' '))
              ? '$rawText '
              : rawText;
          wordList.add(
            LyricWord(
              offset: Duration(milliseconds: startMs),
              duration: Duration(milliseconds: durMs),
              text: wordText,
            ),
          );
        }
        return wordList;
      }

      final rawSyncedLines = (lyricsJson['synchronizedLines'] ?? [])
          .map<SynchronizedLyric>(
            (l) =>
                SynchronizedLyric.fromPrivateJson(l as Map<dynamic, dynamic>),
          )
          .where((l) => l.offset != null)
          .toList();

      syncedLyrics = [];
      for (final wLine in rawWordByWord) {
        if (wLine is! Map) continue;
        final startMs = (wLine['start'] as num?)?.toInt() ?? 0;
        final endMs = (wLine['end'] as num?)?.toInt() ?? startMs;
        final durMs = (endMs > startMs) ? (endMs - startMs) : 3000;
        final rawWords = wLine['words'] as List? ?? [];
        final words = parseWordList(rawWords);
        final lineText = words.isNotEmpty
            ? words.map((w) => w.text).join().trim()
            : (wLine['text']?.toString() ?? '');

        String? translatedText;
        String? romanizedText;
        if (rawSyncedLines.isNotEmpty) {
          SynchronizedLyric? bestMatch;
          int bestDiff = 5000;
          for (final l in rawSyncedLines) {
            final lMs = l.offset?.inMilliseconds ?? -1;
            final diff = (lMs - startMs).abs();
            if (diff < bestDiff) {
              bestDiff = diff;
              bestMatch = l;
            }
          }
          if (bestMatch != null) {
            translatedText = bestMatch.translatedText;
            romanizedText = bestMatch.romanizedText;
          }
        }

        syncedLyrics.add(
          SynchronizedLyric(
            offset: Duration(milliseconds: startMs),
            duration: Duration(milliseconds: durMs),
            text: lineText,
            words: words.isNotEmpty ? words : null,
            translatedText: translatedText,
            romanizedText: romanizedText,
          ),
        );
      }
    } else {
      syncedLyrics = (lyricsJson['synchronizedLines'] ?? [])
          .map<SynchronizedLyric>(
            (l) =>
                SynchronizedLyric.fromPrivateJson(l as Map<dynamic, dynamic>),
          )
          .where((l) => l.offset != null)
          .toList();
    }

    return LyricsFull(
      id: lyricsJson['id'],
      writers: lyricsJson['writers'],
      syncedLyrics: syncedLyrics,
      unsyncedLyrics: lyricsJson['text'],
      isExplicit: json['track']?['isExplicit'],
      copyright: lyricsJson['copyright'],
    );
  }

  factory LyricsFull.fromJson(Map<String, dynamic> json) =>
      _$LyricsFullFromJson(json);

  Map<String, dynamic> toJson() => _$LyricsFullToJson(this);
}

/// Represents a single word with its own timing for word-by-word sync (Enhanced LRC).
@JsonSerializable()
class LyricWord {
  final Duration offset;
  final Duration duration;
  final String text;

  LyricWord({required this.offset, required this.duration, required this.text});

  factory LyricWord.fromJson(Map<String, dynamic> json) =>
      _$LyricWordFromJson(json);

  Map<String, dynamic> toJson() => _$LyricWordToJson(this);
}

@JsonSerializable()
class SynchronizedLyric {
  Duration? offset;
  Duration? duration;
  String? text;
  String? translatedText;
  String? romanizedText;
  String? lrcTimestamp;

  /// Word-level timestamps for word-by-word highlighting (Enhanced LRC).
  /// When populated, the UI renders per-word color interpolation.
  /// When null, falls back to line-by-line highlighting.
  List<LyricWord>? words;

  SynchronizedLyric({
    this.offset,
    this.duration,
    this.text,
    this.translatedText,
    this.romanizedText,
    this.lrcTimestamp,
    this.words,
  });

  //JSON
  factory SynchronizedLyric.fromPrivateJson(Map<dynamic, dynamic> json) {
    if (json['milliseconds'] == null || json['line'] == null) {
      return SynchronizedLyric(); //Empty lyric
    }
    return SynchronizedLyric(
      offset: Duration(
        milliseconds: int.parse(json['milliseconds'].toString()),
      ),
      duration: Duration(milliseconds: int.parse(json['duration'].toString())),
      text: json['line'],
      translatedText:
          json['lineTranslated'] ??
          json['line_translated'] ??
          json['translatedLine'],
      // lrc_timestamp from classic GW API, lrcTimestamp from pipe API
      lrcTimestamp: json['lrcTimestamp'] ?? json['lrc_timestamp'],
    );
  }

  factory SynchronizedLyric.fromJson(Map<String, dynamic> json) {
    final rawWords = json['words'];
    return SynchronizedLyric(
      offset: json['offset'] is num
          ? Duration(microseconds: (json['offset'] as num).toInt())
          : null,
      duration: json['duration'] is num
          ? Duration(microseconds: (json['duration'] as num).toInt())
          : null,
      text: json['text'] as String?,
      translatedText: json['translatedText'] as String?,
      romanizedText: json['romanizedText'] as String?,
      lrcTimestamp: json['lrcTimestamp'] as String?,
      words: rawWords is List
          ? rawWords.whereType<Map>().map((word) {
              final offset = word['offset'];
              final duration = word['duration'];
              return LyricWord(
                offset: Duration(
                  microseconds: offset is num ? offset.toInt() : 0,
                ),
                duration: Duration(
                  microseconds: duration is num ? duration.toInt() : 0,
                ),
                text: word['text']?.toString() ?? '',
              );
            }).toList()
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'offset': offset?.inMicroseconds,
    'duration': duration?.inMicroseconds,
    'text': text,
    'translatedText': translatedText,
    'romanizedText': romanizedText,
    'lrcTimestamp': lrcTimestamp,
    'words': words
        ?.map(
          (word) => {
            'offset': word.offset.inMicroseconds,
            'duration': word.duration.inMicroseconds,
            'text': word.text,
          },
        )
        .toList(),
  };
}

/// Attaches translated or romanized lines to the nearest matching timestamp.
void attachLyricOverlay(
  List<SynchronizedLyric> original,
  List<SynchronizedLyric> overlay, {
  required bool translation,
}) {
  if (original.isEmpty || overlay.isEmpty) return;
  for (final overlayLine in overlay) {
    final offset = overlayLine.offset;
    final value = overlayLine.text?.trim();
    if (offset == null || value == null || value.isEmpty) continue;

    var closestIndex = -1;
    var closestDistance = const Duration(days: 1);
    for (var i = 0; i < original.length; i++) {
      final originalOffset = original[i].offset;
      if (originalOffset == null) continue;
      final distance = (originalOffset - offset).abs();
      if (distance < closestDistance) {
        closestDistance = distance;
        closestIndex = i;
      }
    }
    if (closestIndex < 0 || closestDistance > const Duration(seconds: 3)) {
      continue;
    }
    if (translation) {
      original[closestIndex].translatedText = value;
    } else {
      original[closestIndex].romanizedText = value;
    }
  }
}

@JsonSerializable()
class QueueSource {
  String? id;
  String? text;
  String? source;
  Sorting? sort;

  QueueSource({this.id, this.text, this.source, this.sort});

  factory QueueSource.fromJson(Map<String, dynamic> json) {
    final rawSort = json['sort'];
    return QueueSource(
      id: json['id'] as String?,
      text: json['text'] as String?,
      source: json['source'] as String?,
      // A live QueueSource.toJson() used to leave this as a Sorting object;
      // persisted JSON turns it into a map. Accept both representations.
      sort: rawSort is Sorting
          ? rawSort
          : rawSort is Map
          ? Sorting.fromJson(Map<String, dynamic>.from(rawSort))
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'source': source,
    'sort': sort?.toJson(),
  };
}

@JsonSerializable()
class SmartTrackList {
  String platformId;
  String? id;
  String? title;
  String? subtitle;
  String? description;
  int? trackCount;
  List<Track>? tracks;
  ImageDetails? cover;
  String? flowType;

  SmartTrackList({
    this.id,
    this.title,
    this.description,
    this.trackCount,
    this.tracks,
    this.cover,
    this.subtitle,
    this.flowType,
    this.platformId = 'deezer',
  });

  //JSON
  factory SmartTrackList.fromPrivateJson(
    Map<dynamic, dynamic> json, {
    Map<dynamic, dynamic> songsJson = const {},
  }) => SmartTrackList(
    id: json['SMARTTRACKLIST_ID'],
    title: json['TITLE'],
    subtitle: json['SUBTITLE'],
    description: json['DESCRIPTION'],
    trackCount: json['NB_SONG'] ?? (songsJson['total']),
    tracks: (songsJson['data'] ?? [])
        .map<Track>((t) => Track.fromPrivateJson(t))
        .toList(),
    cover: ImageDetails.fromPrivateJson(json['COVER']),
  );

  factory SmartTrackList.fromJson(Map<String, dynamic> json) {
    return _$SmartTrackListFromJson(json)
      ..platformId = json['platformId'] as String? ?? 'deezer';
  }
  Map<String, dynamic> toJson() {
    return _$SmartTrackListToJson(this)..['platformId'] = platformId;
  }
}

@JsonSerializable()
class HomePage {
  List<HomePageSection> sections;
  @JsonKey(includeFromJson: false, includeToJson: false)
  bool hasMore;
  @JsonKey(includeFromJson: false, includeToJson: false)
  Future<List<HomePageSection>> Function()? loadMore;

  HomePage({
    this.sections = const [],
    this.hasMore = false,
    this.loadMore,
  });

  //Save/Load
  Future<String> _getPath() async {
    Directory d = await getApplicationSupportDirectory();
    return p.join(d.path, 'homescreen.json');
  }

  Future exists() async {
    String path = await _getPath();
    return await File(path).exists();
  }

  Future save() async {
    String path = await _getPath();
    final jsonString = jsonEncode(toJson());
    // Offload file writing to background isolate
    await compute(_writeFileString, {'path': path, 'data': jsonString});
  }

  Future<HomePage> load() async {
    String path = await _getPath();
    // Offload file reading to background isolate
    String fileContent = await compute(_readFileString, path);
    Map<String, dynamic> data = jsonDecode(fileContent);
    return HomePage.fromJson(data);
  }

  Future wipe() async {
    await File(await _getPath()).delete();
  }

  //JSON
  factory HomePage.fromPrivateJson(Map<dynamic, dynamic> json) {
    HomePage hp = HomePage(sections: []);
    //Parse every section
    for (var s in (json['sections'] ?? [])) {
      HomePageSection? section = HomePageSection.fromPrivateJson(s);
      if (section != null) hp.sections.add(section);
    }
    return hp;
  }

  factory HomePage.fromJson(Map<String, dynamic> json) =>
      _$HomePageFromJson(json);
  Map<String, dynamic> toJson() => _$HomePageToJson(this);
}

@JsonSerializable()
class HomePageSection {
  String? title;
  String? subtitle;
  String? image;
  HomePageSectionLayout? layout;

  //For loading more items
  String? pagePath;
  bool? hasMore;

  @JsonKey(fromJson: _homePageItemFromJson, toJson: _homePageItemToJson)
  List<HomePageItem?> items;

  HomePageSection({
    this.layout,
    this.items = const [],
    this.title,
    this.subtitle,
    this.image,
    this.pagePath,
    this.hasMore,
  });

  //JSON
  static HomePageSection? fromPrivateJson(Map<dynamic, dynamic> json) {
    String? imageUrl;
    String title = json['title'] ?? '';
    String subtitle = json['subtitle'] ?? '';
    String? pagePath = json['target'];
    bool hasMore = json['hasMoreItems'] ?? false;

    // Handle enriched titles (e.g. "Since you like [Artist]")
    if (json['enriched_title'] != null) {
      final enriched = json['enriched_title'];
      title = enriched['title'] ?? title;
      subtitle = enriched['lead_in'] ?? subtitle;
      if (enriched['pictures'] != null &&
          enriched['pictures'] is List &&
          enriched['pictures'].isNotEmpty) {
        final pic = enriched['pictures'][0];
        if (pic['md5'] != null) {
          final String type = pic['type'] ?? 'artist';
          imageUrl =
              'https://e-cdns-images.dzcdn.net/images/$type/${pic['md5']}/500x500-000000-80-0-0.jpg';
        }
      }
    }

    if (imageUrl == null) {
      if (json['picture'] != null) {
        imageUrl = json['picture'];
      } else if (json['image'] != null) {
        imageUrl = json['image'];
      } else if (json['thumbnail'] != null) {
        imageUrl = json['thumbnail'];
      } else if (json['cover'] != null) {
        imageUrl = json['cover'];
      } else if (json['pictures'] != null &&
          json['pictures'] is List &&
          json['pictures'].isNotEmpty) {
        imageUrl = json['pictures'][0];
      }
    }

    if (json['related'] != null) {
      final related = json['related'];
      if (related['target'] != null) {
        pagePath = related['target'];
        // Deezer's regular home modules use `related.target` as their
        // "view all" route and often omit `hasMoreItems`. Enriched
        // recommendation headers (for example, "Since you like …") also
        // carry related targets, but those are contextual suggestions rather
        // than sections with a separate full listing.
        if (json['enriched_title'] == null) {
          hasMore = true;
        }
      }
    }

    HomePageSection hps = HomePageSection(
      title: title,
      subtitle: subtitle,
      image: imageUrl,
      items: [],
      pagePath: pagePath,
      hasMore: hasMore,
    );

    String layout = json['layout'];
    final rawItems = json['items'] is List ? json['items'] as List : const [];
    final isBrowseCategories =
        title.isEmpty &&
        rawItems.isNotEmpty &&
        rawItems.every(
          (dynamic item) =>
              item is Map &&
              (item['type']?.toString().toLowerCase() == 'external-link' ||
                  item['type']?.toString().toLowerCase() == 'channel'),
        );
    switch (layout) {
      case 'ads':
        return null;
      case 'quick-access':
      case 'quick_access':
      case 'pinned':
        hps.layout = HomePageSectionLayout.QUICK_ACCESS;
        break;
      case 'small-horizontal-grid':
      case 'long-card-horizontal-grid':
      case 'filterable-grid':
      case 'item-highlight':
      case 'slideshow':
        hps.layout = HomePageSectionLayout.ROW;
        break;
      case 'horizontal-list':
        hps.layout = HomePageSectionLayout.GRID_ROW;
        break;
      case 'horizontal-grid':
        hps.layout = isBrowseCategories
            ? HomePageSectionLayout.BROWSE_CATEGORIES
            : HomePageSectionLayout.ROW;
        break;
      case 'grid':
      case 'grid-preview-one':
      case 'grid-preview-two':
      case 'list':
        hps.layout = HomePageSectionLayout.GRID;
        break;
      case 'large-card':
        hps.layout = HomePageSectionLayout.ROW;
        break;
      default:
        hps.layout = HomePageSectionLayout.ROW;
        break;
    }

    // Parse items once per unique entity. Some Deezer channels repeat the
    // same playlist in multiple positions in a section response.
    final seenItems = <String>{};
    for (var i in rawItems) {
      if (i is Map) {
        final target = i['target']?.toString().toLowerCase() ?? '';
        if (target == '/concerts' ||
            target == 'concerts' ||
            target == '/channels/games' ||
            target == 'channels/games') {
          continue;
        }
      }
      HomePageItem? hpi = HomePageItem.fromPrivateJson(i);

      if (hpi != null) {
        final dynamic value = hpi.value;
        final String? itemId = switch (value) {
          Map item => item['id']?.toString(),
          ShowEpisode episode => episode.id,
          DeezerChannel channel => channel.id,
          Playlist playlist => playlist.id,
          Album album => album.id,
          Artist artist => artist.id,
          _ => null,
        };
        final itemKey =
            itemId ?? i['target']?.toString() ?? i['id']?.toString();
        if ((hpi.type == HomePageItemType.PLAYLIST ||
                hpi.type == HomePageItemType.EPISODE) &&
            itemKey != null &&
            !seenItems.add(itemKey)) {
          continue;
        }
        hps.items.add(hpi);
      }
    }

    // Keep episode recommendations in the same compact carousel layout as
    // podcast tiles instead of expanding their artwork across a responsive
    // grid on wide screens.
    if (hps.items.isNotEmpty &&
        hps.items.every((item) => item?.type == HomePageItemType.EPISODE)) {
      hps.layout = HomePageSectionLayout.ROW;
    }
    return hps;
  }

  factory HomePageSection.fromJson(Map<String, dynamic> json) =>
      _$HomePageSectionFromJson(json);
  Map<String, dynamic> toJson() => _$HomePageSectionToJson(this);

  static List<HomePageItem?> _homePageItemFromJson(List<dynamic> json) => json
      .map<HomePageItem?>(
        (d) =>
            d != null ? HomePageItem.fromJson(d as Map<String, dynamic>) : null,
      )
      .toList();
  static List<Map<String, dynamic>?> _homePageItemToJson(
    List<HomePageItem?> items,
  ) => items.map((i) => i?.toJson()).toList();
}

class HomePageItem {
  HomePageItemType? type;
  dynamic value;
  bool playMix;
  String? platformId;
  String? platformType;

  HomePageItem({
    this.type,
    this.value,
    this.playMix = false,
    this.platformId,
    this.platformType,
  });

  bool isPlatformItem(String type) =>
      this.type == HomePageItemType.PLATFORM &&
      platformType?.toLowerCase() == type.toLowerCase();

  static HomePageItem? fromPrivateJson(Map<dynamic, dynamic> json) {
    String type = json['type']?.toString().toLowerCase() ?? '';
    final itemData = json['data'] ?? json;

    // Determine if we should play a mix based on target URL
    bool shouldPlayMix = false;
    final target = json['target']?.toString();
    if (target != null && target.contains('mix=true')) {
      shouldPlayMix = true;
    }

    switch (type) {
      case 'flow':
        return HomePageItem(
          type: HomePageItemType.PLATFORM,
          platformId: 'deezer',
          platformType: 'flow',
          value: DeezerFlow.fromPrivateJson(json),
          playMix: shouldPlayMix,
        );
      case 'smarttracklist':
        //Smart Track List
        return HomePageItem(
          type: HomePageItemType.PLATFORM,
          platformId: 'deezer',
          platformType: 'smarttracklist',
          value: SmartTrackList.fromPrivateJson(itemData),
          playMix: shouldPlayMix,
        );
      case 'playlist':
        return HomePageItem(
          type: HomePageItemType.PLAYLIST,
          value: Playlist.fromPrivateJson(itemData),
          playMix: shouldPlayMix,
        );
      case 'artist':
        return HomePageItem(
          type: HomePageItemType.ARTIST,
          value: Artist.fromPrivateJson(itemData),
          playMix: shouldPlayMix,
        );
      case 'external-link':
      case 'channel':
        return HomePageItem(
          type: HomePageItemType.PLATFORM,
          platformId: 'deezer',
          platformType: 'channel',
          value: DeezerChannel.fromPrivateJson(json),
          playMix: shouldPlayMix,
        );
      case 'album':
        return HomePageItem(
          type: HomePageItemType.ALBUM,
          value: Album.fromPrivateJson(itemData),
          playMix: shouldPlayMix,
        );
      case 'show':
        return HomePageItem(
          type: HomePageItemType.SHOW,
          value: Show.fromPrivateJson(itemData),
          playMix: shouldPlayMix,
        );
      case 'track':
      case 'song':
        return HomePageItem(
          type: HomePageItemType.TRACK,
          value: Track.fromPrivateJson(itemData),
          playMix: shouldPlayMix,
        );
      case 'episode':
        return HomePageItem(
          type: HomePageItemType.EPISODE,
          value: ShowEpisode.fromPrivateJson(itemData),
          playMix: shouldPlayMix,
        );
      case 'livestream':
      case 'radio':
        return HomePageItem(
          type: HomePageItemType.RADIO,
          platformId: 'deezer',
          value: LiveRadio.fromPrivateJson(json)..platformId = 'deezer',
          playMix: shouldPlayMix,
        );
      default:
        return null;
    }
  }

  factory HomePageItem.fromJson(Map<String, dynamic> json) {
    String t = json['type'];
    bool mix = json['playMix'] ?? false;
    if (t == 'PLATFORM') {
      return HomePageItem(
        type: HomePageItemType.PLATFORM,
        value: json['value'],
        playMix: mix,
        platformId: json['platformId']?.toString(),
        platformType: json['platformType']?.toString(),
      );
    }
    switch (t) {
      case 'FLOW': // Legacy saved homepage data.
        return HomePageItem(
          type: HomePageItemType.PLATFORM,
          platformId: 'deezer',
          platformType: 'flow',
          value: DeezerFlow.fromJson(json['value']),
          playMix: mix,
        );
      case 'SMARTTRACKLIST': // Legacy saved homepage data.
        return HomePageItem(
          type: HomePageItemType.PLATFORM,
          platformId: 'deezer',
          platformType: 'smarttracklist',
          value: SmartTrackList.fromJson(json['value']),
          playMix: mix,
        );
      case 'PLAYLIST':
        return HomePageItem(
          type: HomePageItemType.PLAYLIST,
          value: Playlist.fromJson(json['value']),
          playMix: mix,
        );
      case 'ARTIST':
        return HomePageItem(
          type: HomePageItemType.ARTIST,
          value: Artist.fromJson(json['value']),
          playMix: mix,
        );
      case 'CHANNEL': // Legacy saved homepage data.
        return HomePageItem(
          type: HomePageItemType.PLATFORM,
          platformId: 'deezer',
          platformType: 'channel',
          value: DeezerChannel.fromJson(json['value']),
          playMix: mix,
        );
      case 'ALBUM':
        return HomePageItem(
          type: HomePageItemType.ALBUM,
          value: Album.fromJson(json['value']),
          playMix: mix,
        );
      case 'SHOW':
        return HomePageItem(
          type: HomePageItemType.SHOW,
          value: Show.fromPrivateJson(json['value']),
          playMix: mix,
        );
      case 'TRACK':
        return HomePageItem(
          type: HomePageItemType.TRACK,
          value: Track.fromJson(json['value']),
          playMix: mix,
          platformId: json['platformId']?.toString(),
        );
      case 'EPISODE':
        return HomePageItem(
          type: HomePageItemType.EPISODE,
          value: ShowEpisode.fromJson(json['value']),
          playMix: mix,
        );
      case 'RADIO':
      case 'LIVESTREAM':
        return HomePageItem(
          type: HomePageItemType.RADIO,
          value: LiveRadio.fromJson(json['value']),
          playMix: mix,
        );
      default:
        return HomePageItem();
    }
  }

  Map<String, dynamic> toJson() {
    return {
      'type': type == HomePageItemType.PLATFORM
          ? 'PLATFORM'
          : type.toString().split('.').last,
      'value': value is Map ? value : (value?.toJson()),
      'playMix': playMix,
      if (platformId != null) 'platformId': platformId,
      if (platformType != null) 'platformType': platformType,
    };
  }
}

@JsonSerializable()
class DeezerChannel {
  String? id;
  String? target;
  String? title;
  String? logo;
  @JsonKey(fromJson: _colorFromJson, toJson: _colorToJson)
  Color? backgroundColor;
  ImageDetails? backgroundImage;
  LogoDetails? logoImage;

  DeezerChannel({
    this.id,
    this.title,
    this.backgroundColor,
    this.target,
    this.backgroundImage,
    this.logo,
    this.logoImage,
  });

  factory DeezerChannel.fromPrivateJson(Map<dynamic, dynamic> json) {
    String? linkedImageUrl;
    if (json['image_linked_item'] != null) {
      final item = json['image_linked_item'];
      if (item['md5'] != null) {
        linkedImageUrl =
            'https://e-cdns-images.dzcdn.net/images/${item['type'] ?? 'playlist'}/${item['md5']}/500x500-000000-80-0-0.jpg';
      }
    }
    return DeezerChannel(
      id: json['id'],
      title: json['title'],
      logo: linkedImageUrl ?? json['data']?['logo'],
      backgroundColor: Color(
        int.parse(
          (json['background_color'] ?? '#000000').replaceFirst('#', 'FF'),
          radix: 16,
        ),
      ),
      target: json['target']?.replaceFirst('/', ''),
      backgroundImage:
          ((json['pictures'] == null ||
              (json['pictures'] is List && json['pictures'].isEmpty)))
          ? null
          : ImageDetails.fromPrivateJson(json['pictures'][0]),
      logoImage: ((json['logo_image']) == null)
          ? null
          : LogoDetails.fromPrivateJson(json['logo_image']),
    );
  }

  //JSON
  static int _colorToJson(Color? c) => c?.toARGB32() ?? 0;
  static Color _colorFromJson(int? v) => Color(v ?? Colors.blue.toARGB32());
  factory DeezerChannel.fromJson(Map<String, dynamic> json) =>
      _$DeezerChannelFromJson(json);
  Map<String, dynamic> toJson() => _$DeezerChannelToJson(this);
}

@JsonSerializable()
class DeezerFlow {
  String? id;
  String? target;
  String? title;
  FlowImage? cover;

  DeezerFlow({this.id, this.title, this.target, this.cover});

  factory DeezerFlow.fromPrivateJson(Map<dynamic, dynamic> json) => DeezerFlow(
    id: json['id'],
    title: json['title'],
    cover: FlowImage.fromPrivateJson(json['pictures'][0]),
    target: json['target'].replaceFirst('/', ''),
  );

  //JSON
  factory DeezerFlow.fromJson(Map<String, dynamic> json) =>
      _$DeezerFlowFromJson(json);
  Map<String, dynamic> toJson() => _$DeezerFlowToJson(this);
}

/// A Deezer live radio station (livestream). Streams from an external URL and
/// exposes the currently playing song through a separate polled endpoint.
class LiveRadio {
  String? id;
  String? title;
  String? description;
  String? imageMd5;
  String? customImageUrl;
  String? platformId;
  bool pinned;
  bool isMix;

  LiveRadio({
    this.id,
    this.title,
    this.description,
    this.imageMd5,
    this.customImageUrl,
    this.platformId,
    this.pinned = false,
    this.isMix = false,
  });

  ImageDetails? get image {
    String? thumb;
    String? full;

    if (customImageUrl != null && customImageUrl!.isNotEmpty) {
      thumb = customImageUrl;
      // Convert URL sizes (like 500x500) to 1500x1500 for full res
      full = customImageUrl!.replaceAll(RegExp(r'\d+x\d+'), '1500x1500');
    } else if (imageMd5 != null && imageMd5!.isNotEmpty) {
      thumb =
          'https://e-cdns-images.dzcdn.net/images/misc/$imageMd5/500x500-000000-80-0-0.jpg';
      full =
          'https://e-cdns-images.dzcdn.net/images/misc/$imageMd5/1500x1500-000000-80-0-0.jpg';
    }

    if (thumb == null && full == null) return null;
    return ImageDetails(fullUrl: full, thumbUrl: thumb);
  }

  String? get imageUrl => image?.thumb;

  factory LiveRadio.fromPrivateJson(Map<dynamic, dynamic> json) {
    final data = (json['data'] ?? json) as Map;
    final pic = (json['pictures'] is List && json['pictures'].isNotEmpty)
        ? json['pictures'][0]['md5']
        : null;
    return LiveRadio(
      id: (data['LIVESTREAM_ID'] ?? json['id'])?.toString(),
      title: (data['LIVESTREAM_TITLE'] ?? json['title'])?.toString(),
      description: (data['LIVESTREAM_DESCRIPTION'] ?? json['description'])
          ?.toString(),
      imageMd5: (data['LIVESTREAM_IMAGE_MD5'] ?? pic)?.toString(),
    );
  }

  factory LiveRadio.fromJson(Map<String, dynamic> json) => LiveRadio(
    id: json['id'] as String?,
    title: json['title'] as String?,
    description: json['description'] as String?,
    imageMd5: json['imageMd5'] as String?,
    customImageUrl: json['customImageUrl'] as String?,
    platformId: json['platformId'] as String?,
    pinned: json['pinned'] as bool? ?? false,
    isMix: json['isMix'] as bool? ?? false,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'description': description,
    'imageMd5': imageMd5,
    if (customImageUrl != null) 'customImageUrl': customImageUrl,
    if (platformId != null) 'platformId': platformId,
    'pinned': pinned,
    'isMix': isMix,
  };
}

enum HomePageItemType {
  RADIO,
  PLATFORM,
  PLAYLIST,
  ARTIST,
  ALBUM,
  SHOW,
  GENRE,
  STATS,
  TRACK,
  EPISODE,
}

enum HomePageSectionLayout {
  ROW,
  GRID,
  GRID_ROW,
  BROWSE_CATEGORIES,
  FEATURED_LIST,
  PILLS,
  STATS_CHART,
  QUICK_ACCESS,
}

enum DeezerLinkType { TRACK, ALBUM, ARTIST, PLAYLIST }

class DeezerLinkResponse {
  DeezerLinkType? type;
  String? id;

  DeezerLinkResponse({this.type, this.id});

  //String to DeezerLinkType
  static DeezerLinkType? typeFromString(String t) {
    t = t.toLowerCase().trim();
    if (t == 'album') return DeezerLinkType.ALBUM;
    if (t == 'artist') return DeezerLinkType.ARTIST;
    if (t == 'playlist') return DeezerLinkType.PLAYLIST;
    if (t == 'track') return DeezerLinkType.TRACK;
    return null;
  }
}

//Sorting
enum SortType {
  DEFAULT,
  ALPHABETIC,
  ARTIST,
  ALBUM,
  RELEASE_DATE,
  POPULARITY,
  USER,
  TRACK_COUNT,
  DATE_ADDED,
}

enum SortSourceTypes {
  //Library
  TRACKS,
  PLAYLISTS,
  SHOWS,
  ALBUMS,
  ARTISTS,

  PLAYLIST,
}

@JsonSerializable()
class Sorting {
  SortType type;
  bool reverse;

  //For preserving sorting
  String? id;
  SortSourceTypes? sourceType;

  Sorting({
    this.type = SortType.DEFAULT,
    this.reverse = false,
    this.id,
    this.sourceType,
  });

  //Find index of sorting from cache
  static int? index(SortSourceTypes type, {String? id}) {
    //Find index
    int? index;
    if (id != null) {
      index = cache.sorts.indexWhere((s) => s.sourceType == type && s.id == id);
    } else {
      index = cache.sorts.indexWhere((s) => s.sourceType == type);
    }
    if (index == -1) return null;
    return index;
  }

  /// Single lookup used by every screen (details page, Android Auto, queue)
  /// to find a playlist's saved sorting regardless of how its ID is prefixed
  /// (`VL`, `local_`, `<platform>_`, `<platform>:`).
  static int? playlistIndex(String? id, {String? platformId}) {
    if (id == null || id.isEmpty) return null;
    final candidates = <String>{id};
    void addVariants(String v) {
      candidates.add(v);
      if (v.startsWith('VL')) {
        candidates.add(v.substring(2));
      } else {
        candidates.add('VL$v');
      }
      if (v.startsWith('local_')) candidates.add(v.substring(6));
    }

    addVariants(id);
    final pid = platformId ?? '';
    for (final sep in ['_', ':']) {
      if (pid.isNotEmpty && id.startsWith('$pid$sep')) {
        addVariants(id.substring(pid.length + 1));
      }
      if (pid.isNotEmpty) candidates.add('$pid$sep$id');
    }
    for (final c in candidates) {
      final idx = Sorting.index(SortSourceTypes.PLAYLIST, id: c);
      if (idx != null) return idx;
    }
    return null;
  }

  /// Saved sorting for a playlist, or null when none is stored.
  static Sorting? forPlaylist(String? id, {String? platformId}) {
    final idx = playlistIndex(id, platformId: platformId);
    return idx == null ? null : cache.sorts[idx];
  }

  factory Sorting.fromJson(Map<String, dynamic> json) =>
      _$SortingFromJson(json);
  Map<String, dynamic> toJson() => _$SortingToJson(this);
}

@JsonSerializable()
class Show {
  String platformId;
  String? name;
  String? creator;
  String? description;
  ImageDetails? art;
  String? id;
  bool pinned;

  Show({
    this.name,
    this.creator,
    this.description,
    this.art,
    this.id,
    this.platformId = 'deezer',
    this.pinned = false,
  });

  //JSON
  factory Show.fromPrivateJson(Map<dynamic, dynamic> json) => Show(
    id: json['SHOW_ID'],
    name: json['SHOW_NAME'],
    creator: json['SHOW_CREATOR'],
    art: ImageDetails.fromPrivateString(json['SHOW_ART_MD5'], type: 'talk'),
    description: json['SHOW_DESCRIPTION'],
  );

  factory Show.fromJson(Map<String, dynamic> json) {
    return _$ShowFromJson(json)
      ..platformId = json['platformId'] as String? ?? 'deezer';
  }
  Map<String, dynamic> toJson() {
    return _$ShowToJson(this)..['platformId'] = platformId;
  }
}

@JsonSerializable()
class ShowEpisode {
  String? id;
  String? title;
  String? description;
  ImageDetails? art;
  String? url;
  Duration? duration;
  String? publishedDate;
  //Might not be fully available
  Show? show;
  int? bookmarkSeconds;
  bool? isHeard;
  bool? isExplicit;
  double? progressPercentage;
  bool pinned;
  // Metadata for a collection such as New Episodes; distinct from the
  // episode's own podcast in [show].
  @JsonKey(includeFromJson: false, includeToJson: false)
  Show? collection;

  ShowEpisode({
    this.id,
    this.title,
    this.description,
    this.art,
    this.url,
    this.duration,
    this.publishedDate,
    this.show,
    this.bookmarkSeconds,
    this.isHeard,
    this.isExplicit,
    this.progressPercentage,
    this.pinned = false,
    this.collection,
  });

  String get durationString {
    final value = duration;
    if (value == null || value == Duration.zero) return '';
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (value.inHours > 0) {
      return '${value.inHours}:${value.inMinutes.remainder(60).toString().padLeft(2, '0')}:$seconds';
    }
    return '${value.inMinutes}:$seconds';
  }

  //Generate MediaItem for playback
  MediaItem toMediaItem(Show show) {
    final playbackShow = this.show ?? show;
    final episodeArt = art ?? playbackShow.art;

    var format = 'MP3';
    int? bitrate;
    if (url != null) {
      final path = Uri.tryParse(url!)?.path.toLowerCase() ?? '';
      if (path.endsWith('.m4a') || path.endsWith('.mp4')) {
        format = 'AAC';
      } else if (path.endsWith('.opus') || path.endsWith('.ogg')) {
        format = 'OPUS';
      } else if (path.endsWith('.flac')) {
        format = 'FLAC';
      }
      if (format == 'MP3') bitrate = 128;
    }

    return MediaItem(
      title: title ?? '',
      artist: playbackShow.name,
      displayTitle: title,
      displaySubtitle: playbackShow.name,
      album: playbackShow.name ?? '',
      id: id ?? '',
      extras: {
        'showUrl': url,
        'show': jsonEncode(playbackShow.toJson()),
        'platformId': playbackShow.platformId,
        'thumb': episodeArt?.thumb,
        'publishedDate': publishedDate,
        'qualityFormat': format,
        'qualityBitrate': ?bitrate,
        'offset': bookmarkSeconds,
        'isHeard': isHeard,
        'isExplicit': isExplicit,
        'explicit': isExplicit,
        'progressPercentage': progressPercentage,
      },
      displayDescription: description,
      duration: duration,
      artUri: Uri.parse(episodeArt?.full ?? ''),
    );
  }

  factory ShowEpisode.fromMediaItem(MediaItem mi) {
    return ShowEpisode(
      id: mi.id,
      title: mi.title,
      description: mi.displayDescription,
      art: mi.extras?['thumb'] is String
          ? ImageDetails(thumbUrl: mi.extras?['thumb'] as String)
          : null,
      url: mi.extras?['showUrl'],
      duration: mi.duration,
      publishedDate: mi.extras?['publishedDate'] as String?,
      show: mi.extras?['show'] != null
          ? Show.fromJson(jsonDecode(mi.extras!['show'] as String))
          : null,
      bookmarkSeconds: mi.extras?['offset'] as int?,
      isHeard: mi.extras?['isHeard'] as bool?,
      isExplicit:
          mi.extras?['isExplicit'] as bool? ?? mi.extras?['explicit'] as bool?,
      progressPercentage: (mi.extras?['progressPercentage'] as num?)
          ?.toDouble(),
    );
  }

  //JSON
  factory ShowEpisode.fromPrivateJson(Map<dynamic, dynamic> json) {
    final artMd5 = json['EPISODE_IMAGE_MD5'] ?? json['SHOW_ART_MD5'];
    final durRaw = json['DURATION'];
    final durSec = durRaw != null ? int.tryParse(durRaw.toString()) : null;
    final bookmarkRaw = json['BOOKMARK'] ?? json['OFFSET'];
    final bookmarkSec = bookmarkRaw != null
        ? int.tryParse(bookmarkRaw.toString())
        : null;
    final isHeardVal = json['ISHEARD'];
    final isHeard = isHeardVal == 1 || isHeardVal == '1' || isHeardVal == true;
    final explicitValue = json['SHOW_IS_EXPLICIT'];
    final isExplicit = explicitValue == true ||
        explicitValue == 1 ||
        explicitValue?.toString() == '1';

    return ShowEpisode(
      id: json['EPISODE_ID']?.toString(),
      title: json['EPISODE_TITLE'],
      description: json['EPISODE_DESCRIPTION'],
      art: artMd5 != null && artMd5.toString().isNotEmpty
          ? ImageDetails.fromPrivateString(artMd5.toString(), type: 'talk')
          : null,
      url: json['EPISODE_DIRECT_STREAM_URL'],
      duration: durSec != null ? Duration(seconds: durSec) : null,
      publishedDate: json['EPISODE_PUBLISHED_TIMESTAMP'],
      show: Show.fromPrivateJson(json),
      bookmarkSeconds: bookmarkSec,
      isHeard: isHeard,
      isExplicit: isExplicit,
      progressPercentage: bookmarkSec != null && durSec != null && durSec > 0
          ? (bookmarkSec / durSec).clamp(0.0, 1.0)
          : (isHeard ? 1.0 : null),
    );
  }

  factory ShowEpisode.fromJson(Map<String, dynamic> json) =>
      _$ShowEpisodeFromJson(json);
  Map<String, dynamic> toJson() => _$ShowEpisodeToJson(this);
}

class StreamQualityInfo {
  String? format;
  int? size;
  String? source;

  StreamQualityInfo({this.format, this.size, this.source});

  factory StreamQualityInfo.fromJson(Map json) => StreamQualityInfo(
    format: json['format'],
    size: json['size'],
    source: json['source'],
  );

  int bitrate(Duration duration) {
    if ((size ?? 0) == 0) return 0;
    int bitrate = (((size! * 8) / 1000) / duration.inSeconds).round();
    //Round to known values
    if (bitrate > 122 && bitrate < 134) return 128;
    if (bitrate > 315 && bitrate < 325) return 320;
    return bitrate;
  }
}

// Helper functions for background file I/O
String _readFileString(String path) {
  return File(path).readAsStringSync();
}

void _writeFileString(Map<String, String> params) {
  File(params['path']!).writeAsStringSync(params['data']!);
}

class PaginatedTrackList {
  final List<Track> tracks;
  final bool hasMore;

  PaginatedTrackList({required this.tracks, required this.hasMore});
}

class PaginatedPlaylistList {
  final List<Playlist> playlists;
  final bool hasMore;

  PaginatedPlaylistList({required this.playlists, required this.hasMore});
}

extension PlaylistListSorting on List<Playlist> {
  List<Playlist> applyPlaylistSorting(Sorting? sort, {String query = ''}) {
    final normalizedQuery = query.trim().toLowerCase();
    final entries = asMap().entries
        .where(
          (entry) => (entry.value.title ?? '').toLowerCase().contains(
            normalizedQuery,
          ),
        )
        .toList();

    int compareValues(Playlist left, Playlist right) {
      switch (sort?.type ?? SortType.DEFAULT) {
        case SortType.ALPHABETIC:
          return (left.title ?? '').toLowerCase().compareTo(
            (right.title ?? '').toLowerCase(),
          );
        case SortType.USER:
          return (left.user?.name ?? '').toLowerCase().compareTo(
            (right.user?.name ?? '').toLowerCase(),
          );
        case SortType.TRACK_COUNT:
          return (left.trackCount ?? left.tracks?.length ?? 0).compareTo(
            right.trackCount ?? right.tracks?.length ?? 0,
          );
        default:
          return 0;
      }
    }

    entries.sort((left, right) {
      final comparison = compareValues(left.value, right.value);
      return comparison == 0 ? left.key.compareTo(right.key) : comparison;
    });
    if (sort?.reverse == true) return entries.reversed.map((e) => e.value).toList();
    return entries.map((entry) => entry.value).toList();
  }
}

class PaginatedShowEpisodeList {
  final List<ShowEpisode> episodes;
  final bool hasMore;

  PaginatedShowEpisodeList({required this.episodes, required this.hasMore});
}

extension TrackListSorting on List<Track> {
  List<Track> applySorting(Sorting? sort) {
    if (sort == null || (sort.type == SortType.DEFAULT && !sort.reverse)) {
      return this;
    }

    List<Track> tcopy = List.from(this);
    switch (sort.type) {
      case SortType.ALPHABETIC:
        final alphabeticTracks = tcopy
            .map((track) => (track: track, key: (track.title ?? '').toLowerCase()))
            .toList();
        alphabeticTracks.sort((a, b) => a.key.compareTo(b.key));
        tcopy = alphabeticTracks.map((entry) => entry.track).toList();
        break;
      case SortType.ARTIST:
        final artistTracks = tcopy
            .map(
              (track) => (
                track: track,
                key: (track.artistString ?? '').toLowerCase(),
              ),
            )
            .toList();
        artistTracks.sort((a, b) => a.key.compareTo(b.key));
        tcopy = artistTracks.map((entry) => entry.track).toList();
        break;
      case SortType.DATE_ADDED:
        tcopy.sort((a, b) => (a.addedDate ?? 0).compareTo(b.addedDate ?? 0));
        break;
      case SortType.DEFAULT:
      default:
        break;
    }
    //Reverse
    if (sort.reverse) return tcopy.reversed.toList();
    return tcopy;
  }
}
