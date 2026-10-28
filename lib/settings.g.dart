// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'settings.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Settings _$SettingsFromJson(Map<String, dynamic> json) =>
    Settings(
        downloadPath: json['downloadPath'] as String?,
        arl: json['arl'] as String?,
      )
      ..language = json['language'] as String?
      ..ignoreInterruptions = json['ignoreInterruptions'] as bool? ?? false
      ..enableEqualizer = json['enableEqualizer'] as bool? ?? false
      ..eastereggsDisabled = json['eastereggsDisabled'] as bool? ?? false
      ..spacebarPlaybackToggle = json['spacebarPlaybackToggle'] as bool? ?? true
      ..wifiQuality =
          $enumDecodeNullable(_$AudioQualityEnumMap, json['wifiQuality']) ??
          AudioQuality.MP3_320
      ..mobileQuality =
          $enumDecodeNullable(_$AudioQualityEnumMap, json['mobileQuality']) ??
          AudioQuality.MP3_128
      ..offlineQuality =
          $enumDecodeNullable(_$AudioQualityEnumMap, json['offlineQuality']) ??
          AudioQuality.FLAC
      ..downloadQuality =
          $enumDecodeNullable(_$AudioQualityEnumMap, json['downloadQuality']) ??
          AudioQuality.FLAC
      ..downloadFilename =
          json['downloadFilename'] as String? ?? '%artist% - %title%'
      ..albumFolder = json['albumFolder'] as bool? ?? true
      ..artistFolder = json['artistFolder'] as bool? ?? true
      ..albumDiscFolder = json['albumDiscFolder'] as bool? ?? false
      ..overwriteDownload = json['overwriteDownload'] as bool? ?? false
      ..downloadThreads = (json['downloadThreads'] as num?)?.toInt() ?? 2
      ..playlistFolder = json['playlistFolder'] as bool? ?? false
      ..downloadLyrics = json['downloadLyrics'] as bool? ?? true
      ..downloadEnhancedLrc = json['downloadEnhancedLrc'] as bool? ?? false
      ..saveOfflineTrackLyrics =
          json['saveOfflineTrackLyrics'] as bool? ?? false
      ..trackCover = json['trackCover'] as bool? ?? false
      ..albumCover = json['albumCover'] as bool? ?? true
      ..nomediaFiles = json['nomediaFiles'] as bool? ?? false
      ..artistSeparator = json['artistSeparator'] as String? ?? ', '
      ..singletonFilename =
          json['singletonFilename'] as String? ?? '%artist% - %title%'
      ..albumArtResolution =
          (json['albumArtResolution'] as num?)?.toInt() ?? 1400
      ..tags =
          (json['tags'] as List<dynamic>?)?.map((e) => e as String).toList() ??
          [
            'title',
            'album',
            'artist',
            'track',
            'disc',
            'albumArtist',
            'date',
            'label',
            'isrc',
            'upc',
            'trackTotal',
            'bpm',
            'lyrics',
            'genre',
            'contributors',
            'art',
          ]
      ..theme =
          $enumDecodeNullable(_$ThemesEnumMap, json['theme']) ??
          Themes.MaterialYouPrimary
      ..darkMode = json['darkMode'] as bool? ?? true
      ..useSystemTheme = json['useSystemTheme'] as bool? ?? false
      ..colorGradientBackground =
          json['colorGradientBackground'] as bool? ?? false
      ..blurPlayerBackground = json['blurPlayerBackground'] as bool? ?? true
      ..themeAdditonalItems = json['themeAdditonalItems'] as bool? ?? true
      ..font = json['font'] as String? ?? 'Deezer'
      ..keepSidebarOpen = json['keepSidebarOpen'] as bool? ?? false
      ..keepSidebarClosed = json['keepSidebarClosed'] as bool? ?? false
      ..sidebarExpandedWidth =
          (json['sidebarExpandedWidth'] as num?)?.toDouble() ?? 256.0
      ..displayMode = (json['displayMode'] as num?)?.toInt()
      ..primaryColor = Settings._colorFromJson(
        (json['primaryColor'] as num?)?.toInt(),
      )
      ..useArtColor = json['useArtColor'] as bool? ?? true
      ..cropMediaArtwork = json['cropMediaArtwork'] as bool? ?? true
      ..deezerLanguage = json['deezerLanguage'] as String? ?? 'en'
      ..deezerCountry = json['deezerCountry'] as String? ?? 'US'
      ..logListen = json['logListen'] as bool? ?? true
      ..proxyAddress = json['proxyAddress'] as String?
      ..proxyUsername = json['proxyUsername'] as String?
      ..proxyPassword = json['proxyPassword'] as String?
      ..lastFMUsername = json['lastFMUsername'] as String?
      ..lastFMPassword = json['lastFMPassword'] as String?
      ..lastFMAPIKey = json['lastFMAPIKey'] as String?
      ..lastFMAPISecret = json['lastFMAPISecret'] as String?
      ..enableDiscordRPC = json['enableDiscordRPC'] as bool? ?? false
      ..noPremium = json['noPremium'] as bool? ?? false
      ..tier = json['tier'] as String?
      ..activePlatformId = json['activePlatformId'] as String? ?? 'deezer'
      ..platformConfigs = json['platformConfigs'] as Map<String, dynamic>? ?? {}
      ..lyricsChoices =
          (json['lyricsChoices'] as Map<String, dynamic>?)?.map(
            (k, e) => MapEntry(k, e as String),
          ) ??
          {}
      ..lyricsTranslationVisibility =
          (json['lyricsTranslationVisibility'] as Map<String, dynamic>?)?.map(
            (k, e) => MapEntry(k, e as bool),
          ) ??
          {}
      ..lyricsRomanizationVisibility =
          (json['lyricsRomanizationVisibility'] as Map<String, dynamic>?)?.map(
            (k, e) => MapEntry(k, e as bool),
          ) ??
          {};

Map<String, dynamic> _$SettingsToJson(Settings instance) => <String, dynamic>{
  'language': instance.language,
  'ignoreInterruptions': instance.ignoreInterruptions,
  'enableEqualizer': instance.enableEqualizer,
  'eastereggsDisabled': instance.eastereggsDisabled,
  'spacebarPlaybackToggle': instance.spacebarPlaybackToggle,
  'wifiQuality': _$AudioQualityEnumMap[instance.wifiQuality]!,
  'mobileQuality': _$AudioQualityEnumMap[instance.mobileQuality]!,
  'offlineQuality': _$AudioQualityEnumMap[instance.offlineQuality]!,
  'downloadQuality': _$AudioQualityEnumMap[instance.downloadQuality]!,
  'downloadPath': instance.downloadPath,
  'downloadFilename': instance.downloadFilename,
  'albumFolder': instance.albumFolder,
  'artistFolder': instance.artistFolder,
  'albumDiscFolder': instance.albumDiscFolder,
  'overwriteDownload': instance.overwriteDownload,
  'downloadThreads': instance.downloadThreads,
  'playlistFolder': instance.playlistFolder,
  'downloadLyrics': instance.downloadLyrics,
  'downloadEnhancedLrc': instance.downloadEnhancedLrc,
  'saveOfflineTrackLyrics': instance.saveOfflineTrackLyrics,
  'trackCover': instance.trackCover,
  'albumCover': instance.albumCover,
  'nomediaFiles': instance.nomediaFiles,
  'artistSeparator': instance.artistSeparator,
  'singletonFilename': instance.singletonFilename,
  'albumArtResolution': instance.albumArtResolution,
  'tags': instance.tags,
  'theme': _$ThemesEnumMap[instance.theme]!,
  'darkMode': instance.darkMode,
  'useSystemTheme': instance.useSystemTheme,
  'colorGradientBackground': instance.colorGradientBackground,
  'blurPlayerBackground': instance.blurPlayerBackground,
  'themeAdditonalItems': instance.themeAdditonalItems,
  'font': instance.font,
  'keepSidebarOpen': instance.keepSidebarOpen,
  'keepSidebarClosed': instance.keepSidebarClosed,
  'sidebarExpandedWidth': instance.sidebarExpandedWidth,
  'displayMode': instance.displayMode,
  'primaryColor': Settings._colorToJson(instance.primaryColor),
  'useArtColor': instance.useArtColor,
  'cropMediaArtwork': instance.cropMediaArtwork,
  'deezerLanguage': instance.deezerLanguage,
  'deezerCountry': instance.deezerCountry,
  'logListen': instance.logListen,
  'proxyAddress': instance.proxyAddress,
  'proxyUsername': instance.proxyUsername,
  'proxyPassword': instance.proxyPassword,
  'lastFMUsername': instance.lastFMUsername,
  'lastFMPassword': instance.lastFMPassword,
  'lastFMAPIKey': instance.lastFMAPIKey,
  'lastFMAPISecret': instance.lastFMAPISecret,
  'enableDiscordRPC': instance.enableDiscordRPC,
  'noPremium': instance.noPremium,
  'tier': instance.tier,
  'activePlatformId': instance.activePlatformId,
  'platformConfigs': instance.platformConfigs,
  'lyricsChoices': instance.lyricsChoices,
  'lyricsTranslationVisibility': instance.lyricsTranslationVisibility,
  'lyricsRomanizationVisibility': instance.lyricsRomanizationVisibility,
};

const _$AudioQualityEnumMap = {
  AudioQuality.MP3_128: 'MP3_128',
  AudioQuality.MP3_320: 'MP3_320',
  AudioQuality.FLAC: 'FLAC',
  AudioQuality.ASK: 'ASK',
};

const _$ThemesEnumMap = {
  Themes.Light: 'Light',
  Themes.Dark: 'Dark',
  Themes.Deezer: 'Deezer',
  Themes.Black: 'Black',
  Themes.MaterialYou: 'MaterialYou',
  Themes.MaterialYouPrimary: 'MaterialYouPrimary',
};
