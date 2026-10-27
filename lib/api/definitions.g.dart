// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'definitions.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Track _$TrackFromJson(Map<String, dynamic> json) => Track(
  id: json['id'] as String?,
  title: json['title'] as String?,
  duration: json['duration'] == null
      ? null
      : Duration(microseconds: (json['duration'] as num).toInt()),
  album: json['album'] == null
      ? null
      : Album.fromJson(json['album'] as Map<String, dynamic>),
  playbackDetails: json['playbackDetails'] as List<dynamic>?,
  albumArt: json['albumArt'] == null
      ? null
      : ImageDetails.fromJson(json['albumArt'] as Map<String, dynamic>),
  artists: (json['artists'] as List<dynamic>?)
      ?.map((e) => Artist.fromJson(e as Map<String, dynamic>))
      .toList(),
  displayArtistName: json['displayArtistName'] as String?,
  trackNumber: (json['trackNumber'] as num?)?.toInt(),
  offline: json['offline'] as bool?,
  qualityFormat: json['qualityFormat'] as String?,
  qualityBitrate: (json['qualityBitrate'] as num?)?.toInt(),
  lyrics: json['lyrics'] == null
      ? null
      : LyricsFull.fromJson(json['lyrics'] as Map<String, dynamic>),
  favorite: json['favorite'] as bool?,
  pinned: json['pinned'] as bool? ?? false,
  diskNumber: (json['diskNumber'] as num?)?.toInt(),
  explicit: json['explicit'] as bool?,
  addedDate: (json['addedDate'] as num?)?.toInt(),
  contributors: json['contributors'] == null
      ? null
      : Contributors.fromJson(json['contributors'] as Map<String, dynamic>),
  fallback: json['fallback'] == null
      ? null
      : Track.fromJson(json['fallback'] as Map<String, dynamic>),
  playbackDetailsFallback: json['playbackDetailsFallback'] as List<dynamic>?,
  variation: (json['variation'] as num?)?.toInt(),
  navigableArtists: (json['navigableArtists'] as List<dynamic>?)
      ?.map((e) => Artist.fromJson(e as Map<String, dynamic>))
      .toList(),
  platformId: json['platformId'] as String? ?? 'deezer',
  unavailable: json['unavailable'] as bool? ?? false,
  unavailableReason: json['unavailableReason'] as String?,
);

Map<String, dynamic> _$TrackToJson(Track instance) => <String, dynamic>{
  'id': instance.id,
  'title': instance.title,
  'album': instance.album,
  'artists': instance.artists,
  'displayArtistName': instance.displayArtistName,
  'duration': instance.duration?.inMicroseconds,
  'albumArt': instance.albumArt,
  'trackNumber': instance.trackNumber,
  'offline': instance.offline,
  'qualityFormat': instance.qualityFormat,
  'qualityBitrate': instance.qualityBitrate,
  'lyrics': instance.lyrics,
  'favorite': instance.favorite,
  'pinned': instance.pinned,
  'diskNumber': instance.diskNumber,
  'explicit': instance.explicit,
  'addedDate': instance.addedDate,
  'contributors': instance.contributors,
  'fallback': instance.fallback,
  'variation': instance.variation,
  'unavailable': instance.unavailable,
  'unavailableReason': instance.unavailableReason,
  'platformId': instance.platformId,
  'playbackDetails': instance.playbackDetails,
  'playbackDetailsFallback': instance.playbackDetailsFallback,
  'navigableArtists': instance.navigableArtists,
};

Contributors _$ContributorsFromJson(Map<String, dynamic> json) => Contributors(
  composers: (json['composers'] as List<dynamic>?)
      ?.map((e) => e as String)
      .toList(),
  engineers: (json['engineers'] as List<dynamic>?)
      ?.map((e) => e as String)
      .toList(),
  mixers: (json['mixers'] as List<dynamic>?)?.map((e) => e as String).toList(),
  producers: (json['producers'] as List<dynamic>?)
      ?.map((e) => e as String)
      .toList(),
  authors: (json['authors'] as List<dynamic>?)
      ?.map((e) => e as String)
      .toList(),
  writers: (json['writers'] as List<dynamic>?)
      ?.map((e) => e as String)
      .toList(),
);

Map<String, dynamic> _$ContributorsToJson(Contributors instance) =>
    <String, dynamic>{
      'composers': instance.composers,
      'engineers': instance.engineers,
      'mixers': instance.mixers,
      'producers': instance.producers,
      'authors': instance.authors,
      'writers': instance.writers,
    };

Album _$AlbumFromJson(Map<String, dynamic> json) => Album(
  id: json['id'] as String?,
  title: json['title'] as String?,
  art: json['art'] == null
      ? null
      : ImageDetails.fromJson(json['art'] as Map<String, dynamic>),
  artists: (json['artists'] as List<dynamic>?)
      ?.map((e) => Artist.fromJson(e as Map<String, dynamic>))
      .toList(),
  tracks: (json['tracks'] as List<dynamic>?)
      ?.map((e) => Track.fromJson(e as Map<String, dynamic>))
      .toList(),
  fans: (json['fans'] as num?)?.toInt(),
  offline: json['offline'] as bool?,
  library: json['library'] as bool?,
  pinned: json['pinned'] as bool? ?? false,
  type:
      $enumDecodeNullable(_$AlbumTypeEnumMap, json['type']) ?? AlbumType.ALBUM,
  releaseDate: json['releaseDate'] as String?,
  favoriteDate: json['favoriteDate'] as String?,
  platformId: json['platformId'] as String? ?? 'deezer',
  hasIdentifiedAIContent: json['hasIdentifiedAIContent'] as bool? ?? false,
);

Map<String, dynamic> _$AlbumToJson(Album instance) => <String, dynamic>{
  'id': instance.id,
  'title': instance.title,
  'artists': instance.artists,
  'tracks': instance.tracks,
  'art': instance.art,
  'fans': instance.fans,
  'offline': instance.offline,
  'library': instance.library,
  'pinned': instance.pinned,
  'type': _$AlbumTypeEnumMap[instance.type],
  'releaseDate': instance.releaseDate,
  'favoriteDate': instance.favoriteDate,
  'hasIdentifiedAIContent': instance.hasIdentifiedAIContent,
  'platformId': instance.platformId,
};

const _$AlbumTypeEnumMap = {
  AlbumType.ALBUM: 'ALBUM',
  AlbumType.SINGLE: 'SINGLE',
  AlbumType.FEATURED: 'FEATURED',
};

ArtistHighlight _$ArtistHighlightFromJson(Map<String, dynamic> json) =>
    ArtistHighlight(
      data: json['data'],
      type: $enumDecodeNullable(_$ArtistHighlightTypeEnumMap, json['type']),
      title: json['title'] as String?,
    );

Map<String, dynamic> _$ArtistHighlightToJson(ArtistHighlight instance) =>
    <String, dynamic>{
      'data': instance.data,
      'type': _$ArtistHighlightTypeEnumMap[instance.type],
      'title': instance.title,
    };

const _$ArtistHighlightTypeEnumMap = {ArtistHighlightType.ALBUM: 'ALBUM'};

Artist _$ArtistFromJson(Map<String, dynamic> json) => Artist(
  id: json['id'] as String?,
  name: json['name'] as String?,
  albums:
      (json['albums'] as List<dynamic>?)
          ?.map((e) => Album.fromJson(e as Map<String, dynamic>))
          .toList() ??
      const [],
  albumCount: (json['albumCount'] as num?)?.toInt(),
  topTracks:
      (json['topTracks'] as List<dynamic>?)
          ?.map((e) => Track.fromJson(e as Map<String, dynamic>))
          .toList() ??
      const [],
  topSongsPlaylistId: json['topSongsPlaylistId'] as String?,
  picture: json['picture'] == null
      ? null
      : ImageDetails.fromJson(json['picture'] as Map<String, dynamic>),
  fans: (json['fans'] as num?)?.toInt(),
  offline: json['offline'] as bool?,
  library: json['library'] as bool?,
  pinned: json['pinned'] as bool? ?? false,
  radio: json['radio'] as bool?,
  variation: (json['variation'] as num?)?.toInt(),
  description: json['description'] as String?,
  favoriteDate: json['favoriteDate'] as String?,
  highlight: json['highlight'] == null
      ? null
      : ArtistHighlight.fromJson(json['highlight'] as Map<String, dynamic>),
  platformId: json['platformId'] as String? ?? 'deezer',
);

Map<String, dynamic> _$ArtistToJson(Artist instance) => <String, dynamic>{
  'id': instance.id,
  'name': instance.name,
  'albums': instance.albums,
  'albumCount': instance.albumCount,
  'topTracks': instance.topTracks,
  'topSongsPlaylistId': instance.topSongsPlaylistId,
  'picture': instance.picture,
  'fans': instance.fans,
  'offline': instance.offline,
  'library': instance.library,
  'pinned': instance.pinned,
  'radio': instance.radio,
  'variation': instance.variation,
  'description': instance.description,
  'favoriteDate': instance.favoriteDate,
  'highlight': instance.highlight,
  'platformId': instance.platformId,
};

Playlist _$PlaylistFromJson(Map<String, dynamic> json) => Playlist(
  id: json['id'] as String?,
  title: json['title'] as String?,
  tracks: (json['tracks'] as List<dynamic>?)
      ?.map((e) => Track.fromJson(e as Map<String, dynamic>))
      .toList(),
  image: json['image'] == null
      ? null
      : ImageDetails.fromJson(json['image'] as Map<String, dynamic>),
  trackCount: (json['trackCount'] as num?)?.toInt(),
  duration: json['duration'] == null
      ? null
      : Duration(microseconds: (json['duration'] as num).toInt()),
  user: json['user'] == null
      ? null
      : User.fromJson(json['user'] as Map<String, dynamic>),
  fans: (json['fans'] as num?)?.toInt(),
  library: json['library'] as bool?,
  pinned: json['pinned'] as bool? ?? false,
  description: json['description'] as String?,
  editable: json['editable'] as bool?,
  mosaicImages: (json['mosaicImages'] as List<dynamic>?)
      ?.map((e) => e as String)
      .toList(),
  mosaicImageCaptions: (json['mosaicImageCaptions'] as List<dynamic>?)
      ?.map((e) => e as String?)
      .toList(),
  disableDownload: json['disableDownload'] as bool?,
  platformId: json['platformId'] as String? ?? 'deezer',
);

Map<String, dynamic> _$PlaylistToJson(Playlist instance) => <String, dynamic>{
  'id': instance.id,
  'title': instance.title,
  'tracks': instance.tracks,
  'image': instance.image,
  'duration': instance.duration?.inMicroseconds,
  'trackCount': instance.trackCount,
  'user': instance.user,
  'fans': instance.fans,
  'library': instance.library,
  'pinned': instance.pinned,
  'description': instance.description,
  'editable': instance.editable,
  'mosaicImages': instance.mosaicImages,
  'mosaicImageCaptions': instance.mosaicImageCaptions,
  'disableDownload': instance.disableDownload,
  'platformId': instance.platformId,
};

LocalPlaylist _$LocalPlaylistFromJson(Map<String, dynamic> json) =>
    LocalPlaylist(
      id: json['id'] as String,
      title: json['title'] as String,
      description: json['description'] as String?,
      trackIds: (json['trackIds'] as List<dynamic>)
          .map((e) => e as String)
          .toList(),
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      offline: json['offline'] as bool? ?? false,
      mosaicImages: (json['mosaicImages'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList(),
    );

Map<String, dynamic> _$LocalPlaylistToJson(LocalPlaylist instance) =>
    <String, dynamic>{
      'id': instance.id,
      'title': instance.title,
      'description': instance.description,
      'trackIds': instance.trackIds,
      'createdAt': instance.createdAt.toIso8601String(),
      'updatedAt': instance.updatedAt.toIso8601String(),
      'offline': instance.offline,
      'mosaicImages': instance.mosaicImages,
    };

User _$UserFromJson(Map<String, dynamic> json) => User(
  id: json['id'] as String?,
  name: json['name'] as String?,
  picture: json['picture'] == null
      ? null
      : ImageDetails.fromJson(json['picture'] as Map<String, dynamic>),
);

Map<String, dynamic> _$UserToJson(User instance) => <String, dynamic>{
  'id': instance.id,
  'name': instance.name,
  'picture': instance.picture,
};

ImageDetails _$ImageDetailsFromJson(Map<String, dynamic> json) => ImageDetails(
  fullUrl: json['fullUrl'] as String?,
  thumbUrl: json['thumbUrl'] as String?,
  type: json['type'] as String?,
  imageHash: json['imageHash'] as String?,
  caption: json['caption'] as String?,
);

Map<String, dynamic> _$ImageDetailsToJson(ImageDetails instance) =>
    <String, dynamic>{
      'fullUrl': instance.fullUrl,
      'thumbUrl': instance.thumbUrl,
      'type': instance.type,
      'imageHash': instance.imageHash,
      'caption': instance.caption,
    };

FlowImage _$FlowImageFromJson(Map<String, dynamic> json) => FlowImage(
  fullUrl: json['fullUrl'] as String?,
  thumbUrl: json['thumbUrl'] as String?,
  type: json['type'] as String?,
  imageHash: json['imageHash'] as String?,
);

Map<String, dynamic> _$FlowImageToJson(FlowImage instance) => <String, dynamic>{
  'fullUrl': instance.fullUrl,
  'thumbUrl': instance.thumbUrl,
  'type': instance.type,
  'imageHash': instance.imageHash,
};

LogoDetails _$LogoDetailsFromJson(Map<String, dynamic> json) => LogoDetails(
  fullUrl: json['fullUrl'] as String?,
  thumbUrl: json['thumbUrl'] as String?,
  type: json['type'] as String?,
  imageHash: json['imageHash'] as String?,
);

Map<String, dynamic> _$LogoDetailsToJson(LogoDetails instance) =>
    <String, dynamic>{
      'fullUrl': instance.fullUrl,
      'thumbUrl': instance.thumbUrl,
      'type': instance.type,
      'imageHash': instance.imageHash,
    };

LyricsClassic _$LyricsClassicFromJson(Map<String, dynamic> json) =>
    LyricsClassic(
        id: json['id'] as String?,
        writers: json['writers'] as String?,
        syncedLyrics: (json['syncedLyrics'] as List<dynamic>?)
            ?.map((e) => SynchronizedLyric.fromJson(e as Map<String, dynamic>))
            .toList(),
        errorMessage: json['errorMessage'] as String?,
        unsyncedLyrics: json['unsyncedLyrics'] as String?,
        unsyncedTranslatedLyrics: json['unsyncedTranslatedLyrics'] as String?,
        unsyncedRomanizedLyrics: json['unsyncedRomanizedLyrics'] as String?,
      )
      ..isExplicit = json['isExplicit'] as bool?
      ..copyright = json['copyright'] as String?;

Map<String, dynamic> _$LyricsClassicToJson(LyricsClassic instance) =>
    <String, dynamic>{
      'id': instance.id,
      'writers': instance.writers,
      'syncedLyrics': instance.syncedLyrics,
      'errorMessage': instance.errorMessage,
      'unsyncedLyrics': instance.unsyncedLyrics,
      'unsyncedTranslatedLyrics': instance.unsyncedTranslatedLyrics,
      'unsyncedRomanizedLyrics': instance.unsyncedRomanizedLyrics,
      'isExplicit': instance.isExplicit,
      'copyright': instance.copyright,
    };

LyricsFull _$LyricsFullFromJson(Map<String, dynamic> json) => LyricsFull(
  id: json['id'] as String?,
  writers: json['writers'] as String?,
  syncedLyrics: (json['syncedLyrics'] as List<dynamic>?)
      ?.map((e) => SynchronizedLyric.fromJson(e as Map<String, dynamic>))
      .toList(),
  errorMessage: json['errorMessage'] as String?,
  unsyncedLyrics: json['unsyncedLyrics'] as String?,
  unsyncedTranslatedLyrics: json['unsyncedTranslatedLyrics'] as String?,
  unsyncedRomanizedLyrics: json['unsyncedRomanizedLyrics'] as String?,
  isExplicit: json['isExplicit'] as bool?,
  copyright: json['copyright'] as String?,
);

Map<String, dynamic> _$LyricsFullToJson(LyricsFull instance) =>
    <String, dynamic>{
      'id': instance.id,
      'writers': instance.writers,
      'syncedLyrics': instance.syncedLyrics,
      'errorMessage': instance.errorMessage,
      'unsyncedLyrics': instance.unsyncedLyrics,
      'unsyncedTranslatedLyrics': instance.unsyncedTranslatedLyrics,
      'unsyncedRomanizedLyrics': instance.unsyncedRomanizedLyrics,
      'isExplicit': instance.isExplicit,
      'copyright': instance.copyright,
    };

LyricWord _$LyricWordFromJson(Map<String, dynamic> json) => LyricWord(
  offset: Duration(microseconds: (json['offset'] as num).toInt()),
  duration: Duration(microseconds: (json['duration'] as num).toInt()),
  text: json['text'] as String,
);

Map<String, dynamic> _$LyricWordToJson(LyricWord instance) => <String, dynamic>{
  'offset': instance.offset.inMicroseconds,
  'duration': instance.duration.inMicroseconds,
  'text': instance.text,
};

SynchronizedLyric _$SynchronizedLyricFromJson(Map<String, dynamic> json) =>
    SynchronizedLyric(
      offset: json['offset'] == null
          ? null
          : Duration(microseconds: (json['offset'] as num).toInt()),
      duration: json['duration'] == null
          ? null
          : Duration(microseconds: (json['duration'] as num).toInt()),
      text: json['text'] as String?,
      translatedText: json['translatedText'] as String?,
      romanizedText: json['romanizedText'] as String?,
      lrcTimestamp: json['lrcTimestamp'] as String?,
      words: (json['words'] as List<dynamic>?)
          ?.map((e) => LyricWord.fromJson(e as Map<String, dynamic>))
          .toList(),
    );

Map<String, dynamic> _$SynchronizedLyricToJson(SynchronizedLyric instance) =>
    <String, dynamic>{
      'offset': instance.offset?.inMicroseconds,
      'duration': instance.duration?.inMicroseconds,
      'text': instance.text,
      'translatedText': instance.translatedText,
      'romanizedText': instance.romanizedText,
      'lrcTimestamp': instance.lrcTimestamp,
      'words': instance.words,
    };

QueueSource _$QueueSourceFromJson(Map<String, dynamic> json) => QueueSource(
  id: json['id'] as String?,
  text: json['text'] as String?,
  source: json['source'] as String?,
  sort: json['sort'] == null
      ? null
      : Sorting.fromJson(json['sort'] as Map<String, dynamic>),
);

Map<String, dynamic> _$QueueSourceToJson(QueueSource instance) =>
    <String, dynamic>{
      'id': instance.id,
      'text': instance.text,
      'source': instance.source,
      'sort': instance.sort,
    };

SmartTrackList _$SmartTrackListFromJson(Map<String, dynamic> json) =>
    SmartTrackList(
      id: json['id'] as String?,
      title: json['title'] as String?,
      description: json['description'] as String?,
      trackCount: (json['trackCount'] as num?)?.toInt(),
      tracks: (json['tracks'] as List<dynamic>?)
          ?.map((e) => Track.fromJson(e as Map<String, dynamic>))
          .toList(),
      cover: json['cover'] == null
          ? null
          : ImageDetails.fromJson(json['cover'] as Map<String, dynamic>),
      subtitle: json['subtitle'] as String?,
      flowType: json['flowType'] as String?,
      platformId: json['platformId'] as String? ?? 'deezer',
    );

Map<String, dynamic> _$SmartTrackListToJson(SmartTrackList instance) =>
    <String, dynamic>{
      'platformId': instance.platformId,
      'id': instance.id,
      'title': instance.title,
      'subtitle': instance.subtitle,
      'description': instance.description,
      'trackCount': instance.trackCount,
      'tracks': instance.tracks,
      'cover': instance.cover,
      'flowType': instance.flowType,
    };

HomePage _$HomePageFromJson(Map<String, dynamic> json) => HomePage(
  sections:
      (json['sections'] as List<dynamic>?)
          ?.map((e) => HomePageSection.fromJson(e as Map<String, dynamic>))
          .toList() ??
      const [],
);

Map<String, dynamic> _$HomePageToJson(HomePage instance) => <String, dynamic>{
  'sections': instance.sections,
};

HomePageSection _$HomePageSectionFromJson(Map<String, dynamic> json) =>
    HomePageSection(
      layout: $enumDecodeNullable(
        _$HomePageSectionLayoutEnumMap,
        json['layout'],
      ),
      items: json['items'] == null
          ? const []
          : HomePageSection._homePageItemFromJson(json['items'] as List),
      title: json['title'] as String?,
      subtitle: json['subtitle'] as String?,
      image: json['image'] as String?,
      pagePath: json['pagePath'] as String?,
      hasMore: json['hasMore'] as bool?,
    );

Map<String, dynamic> _$HomePageSectionToJson(HomePageSection instance) =>
    <String, dynamic>{
      'title': instance.title,
      'subtitle': instance.subtitle,
      'image': instance.image,
      'layout': _$HomePageSectionLayoutEnumMap[instance.layout],
      'pagePath': instance.pagePath,
      'hasMore': instance.hasMore,
      'items': HomePageSection._homePageItemToJson(instance.items),
    };

const _$HomePageSectionLayoutEnumMap = {
  HomePageSectionLayout.ROW: 'ROW',
  HomePageSectionLayout.GRID: 'GRID',
  HomePageSectionLayout.GRID_ROW: 'GRID_ROW',
  HomePageSectionLayout.BROWSE_CATEGORIES: 'BROWSE_CATEGORIES',
  HomePageSectionLayout.FEATURED_LIST: 'FEATURED_LIST',
  HomePageSectionLayout.PILLS: 'PILLS',
  HomePageSectionLayout.STATS_CHART: 'STATS_CHART',
  HomePageSectionLayout.QUICK_ACCESS: 'QUICK_ACCESS',
};

DeezerChannel _$DeezerChannelFromJson(Map<String, dynamic> json) =>
    DeezerChannel(
      id: json['id'] as String?,
      title: json['title'] as String?,
      backgroundColor: DeezerChannel._colorFromJson(
        (json['backgroundColor'] as num?)?.toInt(),
      ),
      target: json['target'] as String?,
      backgroundImage: json['backgroundImage'] == null
          ? null
          : ImageDetails.fromJson(
              json['backgroundImage'] as Map<String, dynamic>,
            ),
      logo: json['logo'] as String?,
      logoImage: json['logoImage'] == null
          ? null
          : LogoDetails.fromJson(json['logoImage'] as Map<String, dynamic>),
    );

Map<String, dynamic> _$DeezerChannelToJson(DeezerChannel instance) =>
    <String, dynamic>{
      'id': instance.id,
      'target': instance.target,
      'title': instance.title,
      'logo': instance.logo,
      'backgroundColor': DeezerChannel._colorToJson(instance.backgroundColor),
      'backgroundImage': instance.backgroundImage,
      'logoImage': instance.logoImage,
    };

DeezerFlow _$DeezerFlowFromJson(Map<String, dynamic> json) => DeezerFlow(
  id: json['id'] as String?,
  title: json['title'] as String?,
  target: json['target'] as String?,
  cover: json['cover'] == null
      ? null
      : FlowImage.fromJson(json['cover'] as Map<String, dynamic>),
);

Map<String, dynamic> _$DeezerFlowToJson(DeezerFlow instance) =>
    <String, dynamic>{
      'id': instance.id,
      'target': instance.target,
      'title': instance.title,
      'cover': instance.cover,
    };

Sorting _$SortingFromJson(Map<String, dynamic> json) => Sorting(
  type:
      $enumDecodeNullable(_$SortTypeEnumMap, json['type']) ?? SortType.DEFAULT,
  reverse: json['reverse'] as bool? ?? false,
  id: json['id'] as String?,
  sourceType: $enumDecodeNullable(_$SortSourceTypesEnumMap, json['sourceType']),
);

Map<String, dynamic> _$SortingToJson(Sorting instance) => <String, dynamic>{
  'type': _$SortTypeEnumMap[instance.type]!,
  'reverse': instance.reverse,
  'id': instance.id,
  'sourceType': _$SortSourceTypesEnumMap[instance.sourceType],
};

const _$SortTypeEnumMap = {
  SortType.DEFAULT: 'DEFAULT',
  SortType.ALPHABETIC: 'ALPHABETIC',
  SortType.ARTIST: 'ARTIST',
  SortType.ALBUM: 'ALBUM',
  SortType.RELEASE_DATE: 'RELEASE_DATE',
  SortType.POPULARITY: 'POPULARITY',
  SortType.USER: 'USER',
  SortType.TRACK_COUNT: 'TRACK_COUNT',
  SortType.DATE_ADDED: 'DATE_ADDED',
};

const _$SortSourceTypesEnumMap = {
  SortSourceTypes.TRACKS: 'TRACKS',
  SortSourceTypes.PLAYLISTS: 'PLAYLISTS',
  SortSourceTypes.SHOWS: 'SHOWS',
  SortSourceTypes.ALBUMS: 'ALBUMS',
  SortSourceTypes.ARTISTS: 'ARTISTS',
  SortSourceTypes.PLAYLIST: 'PLAYLIST',
};

Show _$ShowFromJson(Map<String, dynamic> json) => Show(
  name: json['name'] as String?,
  creator: json['creator'] as String?,
  description: json['description'] as String?,
  art: json['art'] == null
      ? null
      : ImageDetails.fromJson(json['art'] as Map<String, dynamic>),
  id: json['id'] as String?,
  platformId: json['platformId'] as String? ?? 'deezer',
  pinned: json['pinned'] as bool? ?? false,
);

Map<String, dynamic> _$ShowToJson(Show instance) => <String, dynamic>{
  'platformId': instance.platformId,
  'name': instance.name,
  'creator': instance.creator,
  'description': instance.description,
  'art': instance.art,
  'id': instance.id,
  'pinned': instance.pinned,
};

ShowEpisode _$ShowEpisodeFromJson(Map<String, dynamic> json) => ShowEpisode(
  id: json['id'] as String?,
  title: json['title'] as String?,
  description: json['description'] as String?,
  art: json['art'] == null
      ? null
      : ImageDetails.fromJson(json['art'] as Map<String, dynamic>),
  url: json['url'] as String?,
  duration: json['duration'] == null
      ? null
      : Duration(microseconds: (json['duration'] as num).toInt()),
  publishedDate: json['publishedDate'] as String?,
  show: json['show'] == null
      ? null
      : Show.fromJson(json['show'] as Map<String, dynamic>),
  bookmarkSeconds: (json['bookmarkSeconds'] as num?)?.toInt(),
  isHeard: json['isHeard'] as bool?,
  isExplicit: json['isExplicit'] as bool?,
  progressPercentage: (json['progressPercentage'] as num?)?.toDouble(),
  pinned: json['pinned'] as bool? ?? false,
);

Map<String, dynamic> _$ShowEpisodeToJson(ShowEpisode instance) =>
    <String, dynamic>{
      'id': instance.id,
      'title': instance.title,
      'description': instance.description,
      'art': instance.art,
      'url': instance.url,
      'duration': instance.duration?.inMicroseconds,
      'publishedDate': instance.publishedDate,
      'show': instance.show,
      'bookmarkSeconds': instance.bookmarkSeconds,
      'isHeard': instance.isHeard,
      'isExplicit': instance.isExplicit,
      'progressPercentage': instance.progressPercentage,
      'pinned': instance.pinned,
    };
