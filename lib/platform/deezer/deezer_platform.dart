import 'package:flutter/services.dart';
import 'package:flutter/material.dart' as flutter_material;
import 'package:fluttertoast/fluttertoast.dart';
import 'package:logging/logging.dart';
import 'package:saturn/platform/deezer/deezer_widgets.dart';
import 'package:saturn/platform/platform_registry.dart';

import 'deezer_login_widget.dart';
import 'package:material_ui/material_ui.dart';

import '../../platform/deezer/deezer_api.dart';
import '../../api/definitions.dart';
import '../../api/cache.dart';
import '../../platform/music_platform.dart';
import '../../platform/platform_manager.dart';
import '../../platform/download_metadata.dart';
import '../../platform/platform_capabilities.dart';
import '../../platform/stream_provider.dart';
import '../../settings.dart' as g;
import '../../translations.i18n.dart';

import 'deezer_capabilities.dart';
import 'deezer_image_urls.dart';
import 'deezer_browse_categories_section.dart';
import '../../ui/home_screen.dart';
import '../../ui/menu.dart';
import '../../ui/details_screens.dart';
import '../../utils/logging.dart';
import '../../ui/elements.dart';
import '../../ui/tiles.dart';
import 'deezer_stream_provider.dart';
import 'deezer_quick_access_screen.dart';
import 'package:simple_icons/simple_icons.dart';
import 'package:fluttericon/font_awesome5_icons.dart';
import 'package:fluttericon/typicons_icons.dart';
import 'package:audio_service/audio_service.dart';
import 'package:get_it/get_it.dart';
import '../../service/audio_service.dart';
import '../platform_settings.dart';
import 'package:country_currency_pickers/country.dart';
import 'package:country_currency_pickers/country_picker_dialog.dart';
import 'package:country_currency_pickers/utils/utils.dart';

/// Deezer platform plugin.
///
/// This adapter wraps the existing [DeezerAPI] singleton so that the rest of the
/// app can talk to Deezer through the abstract [MusicPlatform] interface without
/// any direct DeezerAPI references outside this directory.
class DeezerPlatform extends MusicPlatform {
  static DeezerPlatform get instance =>
      PlatformRegistry.instance.get('deezer') as DeezerPlatform? ??
      DeezerPlatform();

  // Keep a reference to the existing global singleton so we don't break the
  // old code paths that still reference it during the migration.
  DeezerAPI get _api => deezerAPI;

  Map<String, dynamic> get _config {
    final c = g.settings.platformConfigs['deezer'];
    if (c is Map<String, dynamic>) return c;
    if (c is Map) {
      final converted = Map<String, dynamic>.from(c);
      g.settings.platformConfigs['deezer'] = converted;
      return converted;
    }
    final newMap = <String, dynamic>{};
    g.settings.platformConfigs['deezer'] = newMap;
    return newMap;
  }

  /// Migrates legacy root settings.arl into platformConfigs['deezer']['arl'].
  Future<void> migrateLegacyArlIfNeeded() async {
    final legacy = g.settings.arl;
    if (legacy != null && legacy.isNotEmpty) {
      final cfg = _config;
      final storedArl = cfg['arl'];
      if (storedArl is! String || storedArl.isEmpty) {
        cfg['arl'] = legacy;
        g.settings.platformConfigs['deezer'] = cfg;
      }
      g.settings.arl = null;
      await g.settings.save();
    }
  }

  String? get arl {
    final cfg = g.settings.platformConfigs['deezer'];
    if (cfg is Map &&
        cfg['arl'] is String &&
        (cfg['arl'] as String).isNotEmpty) {
      return cfg['arl'] as String;
    }
    return null;
  }

  set arl(String? value) {
    final cfg = _config;
    if (value != null && value.isNotEmpty) {
      cfg['arl'] = value;
    } else {
      cfg.remove('arl');
    }
    g.settings.platformConfigs['deezer'] = cfg;
    g.settings.arl = null;
    _api.arl = value;
    deezerAPI.arl = value;
  }

  // ---------------------------------------------------------------------------
  // Identity
  // ---------------------------------------------------------------------------

  @override
  String get platformId => 'deezer';

  @override
  String get platformName => 'Deezer';

  @override
  IconData get platformIcon => SimpleIcons.deezer;

  @override
  Widget buildPlatformIcon({double size = 24, Color? color}) {
    return Icon(platformIcon, size: size, color: color);
  }

  @override
  PlatformCapabilities get capabilities => deezerCapabilities;

  @override
  List<PlatformAppShortcut> get appShortcuts => [
    PlatformAppShortcut(id: 'flow', title: 'Flow'.i18n, icon: 'shortcut_flow'),
  ];

  @override
  Future<void> handleAppShortcut(String id) async {
    if (id == 'flow') {
      final tracks = await getFlow();
      if (tracks.isEmpty) return;
      await GetIt.I<AudioPlayerHandler>().playFromTrackList(
        tracks,
        tracks.first.id ?? '',
        QueueSource(id: 'flow:deezer', text: 'Flow'.i18n, source: 'flow'),
      );
    }
  }

  @override
  List<Widget> getExtraMenuOptions(BuildContext context, Object item) {
    final option = buildDeezerPinMenuOption(context, item);
    return option == null ? const [] : [option];
  }

  @override
  List<QuickAccessItem> get searchQuickAccessItems => [
    QuickAccessItem(
      title: 'Flow'.i18n,
      icon: const Icon(Typicons.waves, color: Colors.white),
      color: const Color(0xff11b192),
      onTap: (context) async {
        await GetIt.I<AudioPlayerHandler>().playFromSmartTrackList(
          SmartTrackList(id: 'flow', platformId: 'deezer'),
        );
      },
    ),
    QuickAccessItem(
      title: 'Shows'.i18n,
      icon: const Icon(FontAwesome5.podcast, color: Colors.white),
      color: const Color(0xff7c42bb),
      onTap: (context) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => ShowScreen(
              Show(id: 'shows', name: 'Shows'.i18n, platformId: 'deezer'),
            ),
          ),
        );
      },
    ),
    QuickAccessItem(
      title: 'Charts'.i18n,
      icon: const Icon(FontAwesome5.chart_line, color: Colors.white),
      color: const Color(0xffff555d),
      onTap: (context) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => Scaffold(
              appBar: FreezerAppBar('Charts'.i18n),
              body: HomePageScreen(
                loadPage: () => PlatformManager.instance
                    .getPlatform('deezer')
                    .getChannel('channels/charts'),
              ),
            ),
          ),
        );
      },
    ),
  ];

  @override
  List<PlatformSetting> get settings => [
    ChoicePlatformSetting(
      id: 'deezer_language',
      title: 'Content language'.i18n,
      description:
          'Not app language, used in headers. Now'.i18n +
          ': ${g.settings.deezerLanguage}',
      icon: Icons.language,
      currentValue: g.settings.deezerLanguage,
      options: const [
        ChoicePlatformOption(value: 'en', label: 'English'),
        ChoicePlatformOption(value: 'ar', label: 'العربية'),
        ChoicePlatformOption(value: 'bg', label: 'Български'),
        ChoicePlatformOption(value: 'hr', label: 'Hrvatski'),
        ChoicePlatformOption(value: 'cs', label: 'Čeština'),
        ChoicePlatformOption(value: 'da', label: 'Dansk'),
        ChoicePlatformOption(value: 'nl', label: 'Nederlands'),
        ChoicePlatformOption(value: 'fi', label: 'Suomi'),
        ChoicePlatformOption(value: 'fr', label: 'Français'),
        ChoicePlatformOption(value: 'de', label: 'Deutsch'),
        ChoicePlatformOption(value: 'hu', label: 'Magyar'),
        ChoicePlatformOption(value: 'it', label: 'Italiano'),
        ChoicePlatformOption(value: 'ja', label: '日本語'),
        ChoicePlatformOption(value: 'pl', label: 'Polski'),
        ChoicePlatformOption(value: 'pt', label: 'Português'),
        ChoicePlatformOption(value: 'ro', label: 'Română'),
        ChoicePlatformOption(value: 'ru', label: 'Русский'),
        ChoicePlatformOption(value: 'sk', label: 'Slovenčina'),
        ChoicePlatformOption(value: 'es', label: 'Español'),
        ChoicePlatformOption(value: 'sv', label: 'Svenska'),
        ChoicePlatformOption(value: 'tr', label: 'Türkçe'),
        ChoicePlatformOption(value: 'uk', label: 'Українська'),
      ],
      onChanged: (value) async {
        g.settings.deezerLanguage = value;
        await g.settings.save();
      },
    ),
    ActionPlatformSetting(
      id: 'deezer_country',
      title: 'Content country'.i18n,
      description:
          'Country used in headers. Now'.i18n + ': ${g.settings.deezerCountry}',
      icon: Icons.vpn_lock,
      currentValueDisplay: g.settings.deezerCountry,
      onAction: (context) async {
        showDialog(
          context: context,
          builder: (context) {
            final brightness = g.settings.isDark
                ? flutter_material.Brightness.dark
                : flutter_material.Brightness.light;
            final pickerTheme = flutter_material.ThemeData(
              brightness: brightness,
              colorScheme: flutter_material.ColorScheme.fromSeed(
                seedColor: g.settings.themeData.colorScheme.primary,
                brightness: brightness,
              ),
              useMaterial3: true,
            );
            return flutter_material.Theme(
              data: pickerTheme,
              child: CountryPickerDialog(
                title: Text('Select country'.i18n),
                titlePadding: const EdgeInsets.all(8.0),
                isSearchable: true,
                itemBuilder: (country) => Row(
                  children: <Widget>[
                    CountryPickerUtils.getDefaultFlagImage(country),
                    const SizedBox(width: 8.0),
                    Expanded(
                      child: Text('${country.name} (${country.isoCode})'),
                    ),
                  ],
                ),
                onValuePicked: (Country country) {
                  g.settings.deezerCountry = country.isoCode ?? 'US';
                  g.settings.save();
                },
              ),
            );
          },
        );
      },
    ),
    ActionPlatformSetting(
      id: 'deezer_copy_arl',
      title: 'Copy ARL'.i18n,
      description: 'Copy userToken/ARL Cookie for use in other apps.'.i18n,
      icon: Icons.copy,
      currentValueDisplay: '',
      onAction: (context) async {
        final currentArl = arl ?? '';
        if (currentArl.isNotEmpty) {
          await Clipboard.setData(ClipboardData(text: currentArl));
          await Fluttertoast.showToast(msg: 'Copied'.i18n);
        } else {
          await Fluttertoast.showToast(msg: 'No ARL saved'.i18n);
        }
      },
    ),
  ];

  // ---------------------------------------------------------------------------
  // Auth
  // ---------------------------------------------------------------------------

  @override
  Future<bool> isLoggedIn() async {
    await migrateLegacyArlIfNeeded();
    final currentArl = arl;
    if (currentArl == null || currentArl.isEmpty) return false;
    if (_api.token != null) {
      return true;
    }

    // Try to re-authorize using saved ARL
    _api.arl = currentArl;
    deezerAPI.arl = currentArl;
    final success = await _api.authorize();
    return success;
  }

  @override
  Future<AuthResult> login(Map<String, dynamic> credentials) async {
    final newArl = credentials['arl'] as String?;
    if (newArl == null || newArl.isEmpty) {
      return const AuthResult.failure('ARL is required');
    }
    arl = newArl;
    await g.settings.save();
    final success = await _api.rawAuthorize();
    if (success) {
      return const AuthResult.success();
    }
    return const AuthResult.failure('Invalid ARL');
  }

  @override
  Future<void> logout() async {
    arl = null;
    deezerAPI = DeezerAPI();
    await g.settings.save();
  }

  @override
  String? get currentUserId => _api.userId;

  @override
  String? get currentUserName => _api.userName;

  @override
  String? get favoritesPlaylistId => _api.favoritesPlaylistId?.toString();

  @override
  Future<List<Track>> getAllFavoriteTracks() async {
    final favId = favoritesPlaylistId;
    if (favId != null) {
      final playlist = await getFullPlaylist(favId);
      return playlist.tracks ?? [];
    }
    return [];
  }

  @override
  Widget buildLoginWidget({required VoidCallback onSuccess}) {
    return DeezerLoginWidget(callback: onSuccess);
  }

  // ---------------------------------------------------------------------------
  // Search
  // ---------------------------------------------------------------------------

  @override
  Future<SearchResults> search(String query) => _api.search(query);

  @override
  Future<List<String>> searchSuggestions(String query) =>
      _api.searchSuggestions(query).then((r) => r.cast<String>());

  // ---------------------------------------------------------------------------
  // Content fetching
  // ---------------------------------------------------------------------------

  @override
  Future<Track> getTrack(String id) => _api.track(id);

  @override
  Future<List<Track>> getTracks(List<String> ids) => _api.tracks(ids);

  @override
  Future<Album> getAlbum(String id) => _api.album(id);

  @override
  Future<Artist> getArtist(String id) => _api.artist(id);

  @override
  Future<TrackPageData?> getTrackPageData(String trackId) async {
    try {
      final raw = await _api.trackFull(trackId);
      if (raw != null) {
        return _parseDeezerTrackPageData(raw);
      }
    } catch (e) {
      Logger.root.warning('Deezer getTrackPageData GraphQL failed: $e');
    }

    try {
      final track = await getTrack(trackId);
      Album? album = track.album;
      if (album?.id != null && (album?.tracks ?? []).isEmpty) {
        try {
          final fullAlbum = await getAlbum(album!.id!);
          album = fullAlbum;
        } catch (_) {}
      }
      if (album != null && (album.artists == null || album.artists!.isEmpty)) {
        album.artists = track.artists;
      }
      Lyrics? lyrics;
      try {
        lyrics = await getLyrics(trackId);
      } catch (_) {}

      return TrackPageData(track: track, album: album, lyrics: lyrics);
    } catch (e) {
      Logger.root.warning('Deezer getTrackPageData fallback failed: $e');
      return null;
    }
  }

  @visibleForTesting
  TrackPageData parseDeezerTrackPageDataForTesting(Map<String, dynamic> raw) =>
      _parseDeezerTrackPageData(raw);

  TrackPageData _parseDeezerTrackPageData(Map<String, dynamic> raw) {
    final trackId = raw['id']?.toString() ?? '';
    final title = raw['title'] as String? ?? '';
    final duration = raw['duration'] is num
        ? Duration(seconds: (raw['duration'] as num).toInt())
        : null;
    final isExplicit = raw['isExplicit'] == true;

    final artists = <Artist>[];
    final rawContribs = raw['contributors']?['edges'] as List?;
    if (rawContribs != null) {
      for (final edge in rawContribs) {
        final node = edge?['node'] as Map?;
        if (node != null && node['name'] != null) {
          artists.add(
            Artist(
              id: node['id']?.toString() ?? '',
              name: node['name']?.toString() ?? '',
              platformId: platformId,
            ),
          );
        }
      }
    }

    Album? album;
    final rawAlbum = raw['album'] as Map?;
    if (rawAlbum != null) {
      final albumId = rawAlbum['id']?.toString();
      final albumTitle = rawAlbum['displayTitle'] as String?;
      final releaseDate = rawAlbum['releaseDate'] as String?;
      final rawCover = rawAlbum['cover'] as Map?;
      String? coverThumb;
      String? coverFull;
      if (rawCover != null) {
        final smallList = rawCover['small'] as List?;
        final mediumList = rawCover['medium'] as List?;
        final largeList = rawCover['large'] as List?;
        coverThumb =
            (mediumList?.isNotEmpty == true
                    ? mediumList!.first
                    : smallList?.first)
                ?.toString();
        coverFull =
            (largeList?.isNotEmpty == true ? largeList!.first : coverThumb)
                ?.toString();
      }

      final albumArtists = <Artist>[];
      final rawAlbumContribs = rawAlbum['contributors']?['edges'] as List?;
      if (rawAlbumContribs != null) {
        for (final edge in rawAlbumContribs) {
          final node = edge?['node'] as Map?;
          if (node != null && node['name'] != null) {
            albumArtists.add(
              Artist(
                id: node['id']?.toString() ?? '',
                name: node['name']?.toString() ?? '',
                platformId: platformId,
              ),
            );
          }
        }
      }
      final resolvedAlbumArtists = albumArtists.isNotEmpty
          ? albumArtists
          : artists;

      album = Album(
        id: albumId,
        title: albumTitle,
        releaseDate: releaseDate,
        art: ImageDetails(thumbUrl: coverThumb, fullUrl: coverFull),
        artists: resolvedAlbumArtists.isNotEmpty ? resolvedAlbumArtists : null,
        platformId: platformId,
      );
    }

    final track = Track(
      id: trackId,
      title: title,
      duration: duration,
      explicit: isExplicit,
      album: album,
      artists: artists,
      albumArt: album?.art,
      platformId: platformId,
    );

    Lyrics? lyrics;
    String? writers;
    String? copyright;
    final rawLyrics = raw['lyrics'] as Map?;
    if (rawLyrics != null) {
      writers = rawLyrics['writers'] as String?;
      copyright = rawLyrics['copyright'] as String?;
      final text = rawLyrics['text'] as String?;
      final syncLines = rawLyrics['synchronizedLines'] as List?;
      final synced = <SynchronizedLyric>[];
      if (syncLines != null) {
        for (final l in syncLines) {
          final lineText = l?['line'] as String?;
          if (lineText != null) {
            synced.add(SynchronizedLyric(text: lineText));
          }
        }
      }
      lyrics = Lyrics(
        id: rawLyrics['id']?.toString() ?? trackId,
        writers: writers,
        copyright: copyright,
        unsyncedLyrics: text,
        syncedLyrics: synced,
      );
    }

    final similarTracks = <Track>[];
    final rawRelated = raw['relatedTracks']?['edges'] as List?;
    if (rawRelated != null) {
      for (final edge in rawRelated) {
        final node = edge?['node'] as Map?;
        if (node != null) {
          final relId = node['id']?.toString() ?? '';
          final relTitle = node['title'] as String? ?? '';
          final relDur = node['duration'] is num
              ? Duration(seconds: (node['duration'] as num).toInt())
              : null;
          final relAlbMap = node['album'] as Map?;
          Album? relAlb;
          if (relAlbMap != null) {
            final relCover = relAlbMap['cover'] as Map?;
            final thumb =
                (relCover?['medium'] as List?)?.firstOrNull?.toString() ??
                (relCover?['small'] as List?)?.firstOrNull?.toString();
            relAlb = Album(
              id: relAlbMap['id']?.toString(),
              title: relAlbMap['displayTitle'] as String?,
              art: ImageDetails(thumbUrl: thumb, fullUrl: thumb),
              platformId: platformId,
            );
          }
          final relArtists = <Artist>[];
          final relContrEdges = node['contributors']?['edges'] as List?;
          if (relContrEdges != null) {
            for (final cEdge in relContrEdges) {
              final cNode = cEdge?['node'] as Map?;
              if (cNode?['name'] != null) {
                relArtists.add(
                  Artist(
                    id: cNode!['id']?.toString() ?? '',
                    name: cNode['name']?.toString() ?? '',
                    platformId: platformId,
                  ),
                );
              }
            }
          }
          similarTracks.add(
            Track(
              id: relId,
              title: relTitle,
              duration: relDur,
              album: relAlb,
              artists: relArtists,
              albumArt: relAlb?.art,
              platformId: platformId,
            ),
          );
        }
      }
    }

    return TrackPageData(
      track: track,
      album: album,
      lyrics: lyrics,
      lyricsWriters: writers,
      lyricsCopyright: copyright,
      similarTracks: similarTracks.isNotEmpty ? similarTracks : null,
    );
  }

  @override
  List<ArtistPageSection> buildArtistPageSections(
    BuildContext? context,
    Artist artist,
  ) {
    final sections = <ArtistPageSection>[];
    final message = artist.customData['artistMessage'] as String?;
    if (message?.isNotEmpty == true) {
      sections.add(
        ArtistPageSection(
          position: ArtistPageSectionPosition.top,
          title: 'Artist message'.i18n,
          previewLimit: 1,
          showMore: false,
          loadItems: (limit) => artistPageSectionItems([message!], limit),
          itemBuilder: (context, item, items) => ArtistMessageCard(
            message: item as String,
            artistImage: artist.picture,
          ),
        ),
      );
    }
    if (artist.id != null) {
      sections.add(
        ArtistPageSection(
          position: ArtistPageSectionPosition.afterAlbums,
          title: 'Playlists'.i18n,
          loadItems: (limit) => _api.getArtistPlaylists(artist, limit: limit),
          itemBuilder: (context, item, items) {
            final playlist = item as Playlist;
            return PlaylistTile(
              playlist,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => PlaylistDetails(playlist),
                ),
              ),
            );
          },
        ),
      );
    }
    if (artist.similarArtists.isNotEmpty) {
      sections.add(
        ArtistPageSection(
          position: ArtistPageSectionPosition.end,
          title: 'Similar artists'.i18n,
          loadItems: (limit) =>
              artistPageSectionItems(artist.similarArtists, limit),
          itemBuilder: (context, item, items) {
            final similar = item as Artist;
            return ArtistHorizontalTile(
              similar,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => ArtistDetails(similar)),
              ),
            );
          },
        ),
      );
    }
    return sections;
  }

  @override
  Future<Playlist> getPlaylist(String id, {int limit = 100}) =>
      _api.playlist(id, nb: limit);

  @override
  Future<Playlist> getFullPlaylist(String id) => _api.fullPlaylist(id);

  @override
  Future<Lyrics> getLyrics(String trackId) => _api.lyrics(trackId);

  @override
  String getLyricsSearchQuery(Track track) {
    String title = track.title ?? '';
    // Strip common tags that mess up lyric searches
    title = title.replaceAll(
      RegExp(r'\(.*?Remaster.*?\)', caseSensitive: false),
      '',
    );
    title = title.replaceAll(
      RegExp(r'\(.*?Radio Edit.*?\)', caseSensitive: false),
      '',
    );
    final artistStr = track.artistString ?? '';
    return '$title $artistStr'.trim();
  }

  @override
  String getShareUrl(String type, String id) {
    return 'https://deezer.com/$type/$id';
  }

  // ---------------------------------------------------------------------------
  // Library (read)
  // ---------------------------------------------------------------------------

  @override
  Future<List<Playlist>> getUserPlaylists() async {
    final playlists = await _api.getPlaylists();
    final favId = _api.favoritesPlaylistId?.toString();
    if (favId != null) {
      int? favCount;
      if (cache.activeLibraryTracks.isNotEmpty) {
        favCount = cache.activeLibraryTracks.length;
      }
      playlists.insert(
        0,
        Playlist(
          id: favId,
          title: 'Loved tracks'.i18n,
          user: User(name: _api.userName ?? 'Unavailable'),
          image: ImageDetails(
            thumbUrl: 'assets/favorites_thumb.jpg',
            fullUrl:
                'https://e-cdns-images.dzcdn.net/images/cover/d41d8cd98f00b204e9800998ecf8427e/500x500-000000-80-0-0.jpg',
          ),
          trackCount: favCount,
          library: true,
        ),
      );
    }
    return playlists;
  }

  @override
  Future<List<Album>> getUserAlbums() => _api.getAlbums();

  @override
  Future<List<Artist>> getUserArtists() => _api.getArtists();

  @override
  Future<List<Show>> getUserShows() => _api.getShows();

  @override
  Future<List<String>?> getFavoriteTrackIds() => _api.getFavoriteTrackIds();

  @override
  Future<List<String>?> getFavoritePlaylistIds() async {
    final playlists = await _api.getPlaylists();
    return playlists.map((p) => p.id!).toList();
  }

  @override
  Future<HistoryTrackPage> getHistoryTracks({String? cursor, int limit = 50}) =>
      _api.getHistoryTracks(cursor: cursor, limit: limit);

  // ---------------------------------------------------------------------------
  // Library mutations
  // ---------------------------------------------------------------------------

  @override
  Future<void> addFavoriteTrack(String id) async {
    appLogger.info('[DeezerPlatform] addFavoriteTrack: id=$id');
    try {
      await _api.addFavoriteTrack(id);
      invalidateFavoriteTracksCache();
      appLogger.info('[DeezerPlatform] addFavoriteTrack completed for id=$id');
    } catch (e, st) {
      appLogger.warning(
        '[DeezerPlatform] addFavoriteTrack error for id=$id: $e',
        e,
        st,
      );
      rethrow;
    }
  }

  @override
  Future<void> removeFavoriteTrack(String id) async {
    appLogger.info('[DeezerPlatform] removeFavoriteTrack: id=$id');
    try {
      await _api.removeFavorite(id);
      invalidateFavoriteTracksCache();
      appLogger.info(
        '[DeezerPlatform] removeFavoriteTrack completed for id=$id',
      );
    } catch (e, st) {
      appLogger.warning(
        '[DeezerPlatform] removeFavoriteTrack error for id=$id: $e',
        e,
        st,
      );
      rethrow;
    }
  }

  @override
  Future<void> addFavoriteAlbum(String id) async {
    appLogger.info('[DeezerPlatform] addFavoriteAlbum: id=$id');
    try {
      await _api.addFavoriteAlbum(id);
      appLogger.info('[DeezerPlatform] addFavoriteAlbum completed for id=$id');
    } catch (e, st) {
      appLogger.warning(
        '[DeezerPlatform] addFavoriteAlbum error for id=$id: $e',
        e,
        st,
      );
      rethrow;
    }
  }

  @override
  Future<void> removeFavoriteAlbum(String id) async {
    appLogger.info('[DeezerPlatform] removeFavoriteAlbum: id=$id');
    try {
      await _api.removeAlbum(id);
      appLogger.info(
        '[DeezerPlatform] removeFavoriteAlbum completed for id=$id',
      );
    } catch (e, st) {
      appLogger.warning(
        '[DeezerPlatform] removeFavoriteAlbum error for id=$id: $e',
        e,
        st,
      );
      rethrow;
    }
  }

  @override
  Future<void> addFavoriteArtist(String id) async {
    appLogger.info('[DeezerPlatform] addFavoriteArtist: id=$id');
    try {
      await _api.addFavoriteArtist(id);
      appLogger.info('[DeezerPlatform] addFavoriteArtist completed for id=$id');
    } catch (e, st) {
      appLogger.warning(
        '[DeezerPlatform] addFavoriteArtist error for id=$id: $e',
        e,
        st,
      );
      rethrow;
    }
  }

  @override
  Future<void> removeFavoriteArtist(String id) async {
    appLogger.info('[DeezerPlatform] removeFavoriteArtist: id=$id');
    try {
      await _api.removeArtist(id);
      appLogger.info(
        '[DeezerPlatform] removeFavoriteArtist completed for id=$id',
      );
    } catch (e, st) {
      appLogger.warning(
        '[DeezerPlatform] removeFavoriteArtist error for id=$id: $e',
        e,
        st,
      );
      rethrow;
    }
  }

  @override
  Future<void> dislikeTrack(String id) async {
    appLogger.info('[DeezerPlatform] dislikeTrack: id=$id');
    try {
      await _api.dislikeTrack(id);
      appLogger.info('[DeezerPlatform] dislikeTrack completed for id=$id');
    } catch (e, st) {
      appLogger.warning(
        '[DeezerPlatform] dislikeTrack error for id=$id: $e',
        e,
        st,
      );
      rethrow;
    }
  }

  @override
  Future<void> addFavoritePlaylist(String id) async {
    appLogger.info('[DeezerPlatform] addFavoritePlaylist: id=$id');
    try {
      await _api.addPlaylist(id);
      appLogger.info(
        '[DeezerPlatform] addFavoritePlaylist completed for id=$id',
      );
    } catch (e, st) {
      appLogger.warning(
        '[DeezerPlatform] addFavoritePlaylist error for id=$id: $e',
        e,
        st,
      );
      rethrow;
    }
  }

  @override
  Future<void> removeFavoritePlaylist(String id) async {
    appLogger.info('[DeezerPlatform] removeFavoritePlaylist: id=$id');
    try {
      await _api.removePlaylist(id);
      appLogger.info(
        '[DeezerPlatform] removeFavoritePlaylist completed for id=$id',
      );
    } catch (e, st) {
      appLogger.warning(
        '[DeezerPlatform] removeFavoritePlaylist error for id=$id: $e',
        e,
        st,
      );
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Playlist mutations
  // ---------------------------------------------------------------------------

  @override
  Future<String> createPlaylist(
    String title, {
    String description = '',
    int status = 0,
    List<String> trackIds = const [],
  }) => _api.createPlaylist(
    title,
    description: description,
    status: status,
    trackIds: trackIds,
  );

  @override
  Future<void> updatePlaylist(
    String id,
    String title, {
    String description = '',
    int status = 0,
  }) => _api.updatePlaylist(id, title, description, status: status);

  @override
  Future<void> deletePlaylist(String id) => _api.deletePlaylist(id);

  @override
  Future<void> addToPlaylist(String trackId, String playlistId) async {
    await _api.addToPlaylist(trackId, playlistId);
    invalidatePlaylistTracksCache(playlistId);
  }

  @override
  Future<void> removeFromPlaylist(String trackId, String playlistId) async {
    await _api.removeFromPlaylist(trackId, playlistId);
    invalidatePlaylistTracksCache(playlistId);
  }

  // ---------------------------------------------------------------------------
  // Discovery
  // ---------------------------------------------------------------------------

  @override
  Future<HomePage> getHomePage() => _api.homePage();
  @override
  Widget getHomeWidget(BuildContext context) =>
      HomePageScreen(loadPage: getHomePage);

  @override
  Listenable get homeQuickAccessListenable => deezerPinRevision;

  @override
  Future<List<HomePageItem>> getPinnedHomePageItems() => _api.getPinnedItems();

  @override
  bool get supportsHomeQuickAccessEditor => true;

  @override
  void openHomeQuickAccessEditor(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DeezerQuickAccessCustomizationScreen(api: _api),
      ),
    );
  }

  @override
  Widget buildHomeFlowItem(BuildContext context, HomePageItem item) =>
      FlowTrackListTile(
        item.value,
        onTap: () => handleHomeItemTap(context, item),
        onHold: () {
          final options = getExtraMenuOptions(context, item.value);
          if (options.isNotEmpty) MenuSheet().show(context, options);
        },
      );

  @override
  Widget? buildPlatformHomeItem(BuildContext context, HomePageItem item) {
    if (item.platformId != platformId ||
        item.type != HomePageItemType.PLATFORM) {
      return null;
    }
    _decodeSerializedPlatformItem(item);
    switch (item.platformType?.toLowerCase()) {
      case 'flow':
        return buildHomeFlowItem(context, item);
      case 'smarttracklist':
        return SmartTrackListTile(
          item.value,
          onTap: () =>
              GetIt.I<AudioPlayerHandler>().playFromSmartTrackList(item.value),
          onHold: () {
            final options = getExtraMenuOptions(context, item.value);
            if (options.isNotEmpty) MenuSheet().show(context, options);
          },
        );
      case 'channel':
        return ChannelTile(
          item.value,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => Scaffold(
                appBar: FreezerAppBar(item.value.title.toString()),
                body: HomePageScreen(
                  loadPage: () => getChannel(item.value.target),
                ),
              ),
            ),
          ),
        );
      default:
        return null;
    }
  }

  @override
  Widget? buildPlatformHomeSection(
    BuildContext context,
    HomePageSection section,
  ) {
    if (section.layout == HomePageSectionLayout.BROWSE_CATEGORIES) {
      return DeezerBrowseCategoriesSection(section);
    }
    return null;
  }

  @override
  bool handleHomeItemTap(BuildContext context, HomePageItem item) {
    _decodeSerializedPlatformItem(item);
    if (item.isPlatformItem('flow') && item.value is DeezerFlow) {
      final flow = item.value as DeezerFlow;
      GetIt.I<AudioPlayerHandler>().playFromSmartTrackList(
        SmartTrackList(id: 'flow', title: flow.title, flowType: flow.id),
      );
      return true;
    }
    if (item.type != HomePageItemType.TRACK || !item.playMix) return false;
    final track = item.value as Track;
    if (track.id == null) return true;
    GetIt.I<AudioPlayerHandler>().playMix(
      track.id!,
      track.title ?? '',
      platformId: platformId,
      seedTrack: track,
    );
    return true;
  }

  void _decodeSerializedPlatformItem(HomePageItem item) {
    if (item.value is! Map) return;
    final data = Map<String, dynamic>.from(item.value as Map);
    switch (item.platformType?.toLowerCase()) {
      case 'flow':
        item.value = DeezerFlow.fromJson(data);
        break;
      case 'smarttracklist':
        item.value = SmartTrackList.fromJson(data);
        break;
      case 'channel':
        item.value = DeezerChannel.fromJson(data);
        break;
    }
  }

  @override
  Future<HomePage> getExplorePage() async {
    final page = await _api.getChannel(
      'channels/explore/explore-tab',
      useGet: true,
      useWebHeaders: true,
    );

    // The explore response only includes one featured playlist for some
    // large-card modules. Fetch that module's page so the browse row gets its
    // complete set of playlists at initial load.
    for (final section in page.sections) {
      final modulePath = section.pagePath;
      if (section.layout != HomePageSectionLayout.ROW ||
          section.items.length > 1 ||
          modulePath == null ||
          !modulePath.contains('/channels/module/')) {
        continue;
      }
      try {
        final modulePage = await _api.getChannel(
          modulePath,
          useGet: true,
          useWebHeaders: true,
        );
        final moduleItems = modulePage.sections
            .expand((moduleSection) => moduleSection.items)
            .whereType<HomePageItem>()
            .where((item) => item.type == HomePageItemType.PLAYLIST);
        final seenIds = section.items
            .whereType<HomePageItem>()
            .map((item) => (item.value as Playlist).id)
            .whereType<String>()
            .toSet();
        for (final item in moduleItems) {
          final playlist = item.value as Playlist;
          if (playlist.id == null || seenIds.add(playlist.id!)) {
            section.items.add(item);
          }
        }
      } catch (e, st) {
        Logger.root.warning(
          'Failed to load Deezer explore module $modulePath: $e',
          e,
          st,
        );
      }
    }

    // Keep the untitled category strip recognizable even if Deezer adds
    // metadata to the section title in a future response.
    for (final section in page.sections) {
      final items = section.items.whereType<HomePageItem>().toList();
      if (section.layout == HomePageSectionLayout.ROW &&
          (section.title == null || section.title!.trim().isEmpty) &&
          items.isNotEmpty &&
          items.every((item) => item.isPlatformItem('channel')) &&
          items.any((item) => item.value is DeezerChannel)) {
        section.layout = HomePageSectionLayout.BROWSE_CATEGORIES;
      }
    }
    return page;
  }

  @override
  Widget getExploreWidget(BuildContext context) =>
      HomePageScreen(loadPage: getExplorePage);

  @override
  Future<HomePage> getChannel(String target) => _api.getChannel(
    target,
    // Deezer's web client loads channel pages (including /channels/radios)
    // with page.get over GET. The POST response can omit modules such as the
    // user's live radio stations even though the request advertises support.
    useGet: true,
    useWebHeaders: true,
  );

  @override
  Future<List<Track>> getFlow({String? type}) => _api.flow(type: type);

  @override
  Future<SmartTrackList> getSmartTrackList(String id) =>
      _api.smartTrackList(id);

  @override
  Future<List<Track>> getSmartRadio(String artistId) =>
      _api.smartRadio(artistId);

  @override
  Future<List<Track>> getLibraryShuffle({int start = 0}) =>
      _api.libraryShuffle(start: start);

  @override
  Future<List<Track>> getMix(String trackId) => _api.playMix(trackId);

  // ---------------------------------------------------------------------------
  // Radio
  // ---------------------------------------------------------------------------

  @override
  Future<String?> getRadioStreamUrl(String id) => _api.getLivestreamUrl(id);

  @override
  Future<Track?> getRadioNowPlaying(String id) =>
      _api.getLivestreamNowPlaying(id);

  @override
  Stream<Track?> getRadioNowPlayingStream(String id) =>
      _api.getLivestreamNowPlayingStream(id);

  // ---------------------------------------------------------------------------
  // Shows
  // ---------------------------------------------------------------------------

  @override
  Future<List<ShowEpisode>> getShowEpisodes(String showId) =>
      _api.allShowEpisodes(showId);

  @override
  Future<PaginatedShowEpisodeList> getShowEpisodesPage(
    String showId, {
    int start = 0,
    int limit = 50,
  }) => _api.showEpisodesPage(showId, start: start, limit: limit);

  @override
  Future<bool> isFavoriteShow(String id) async {
    // Requires full Show object or ID parsing in DeezerAPI if it expects a Show
    // For now we assume the ID is enough if we adjust checkShowFavorite.
    // Deezer checkShowFavorite takes a Show. Let's just create a dummy one.
    return _api.checkShowFavorite(Show(id: id));
  }

  @override
  Future<void> addFavoriteShow(String id) => _api.addFavoriteShow(id);

  @override
  Future<void> removeFavoriteShow(String id) => _api.removeShow(id);

  // ---------------------------------------------------------------------------
  // Streaming
  // ---------------------------------------------------------------------------

  @override
  StreamProvider getStreamProvider() => DeezerStreamProvider(_api);

  @override
  List<DownloadQualityOption> get availableDownloadQualities => const [
    DownloadQualityOption(g.AudioQuality.MP3_128, 'MP3 128 kbps'),
    DownloadQualityOption(g.AudioQuality.MP3_320, 'MP3 320 kbps'),
    DownloadQualityOption(g.AudioQuality.FLAC, 'FLAC'),
  ];

  @override
  Future<PlatformDownloadMetadata> getDownloadMetadata(String trackId) async {
    final track = await getTrack(trackId);
    Map<dynamic, dynamic> publicTrack = const {};
    Map<dynamic, dynamic> publicAlbum = const {};

    try {
      publicTrack = await _api.callPublicApi('track/$trackId');
    } catch (_) {}
    final albumId = track.album?.id;
    if (albumId != null) {
      try {
        publicAlbum = await _api.callPublicApi('album/$albumId');
      } catch (_) {}
    }

    String? genre;
    final genres = publicAlbum['genres']?['data'];
    if (genres is List && genres.isNotEmpty) {
      genre = genres.first['name']?.toString();
    }
    final art = track.albumArt ?? track.album?.art;
    final resolution = g.settings.albumArtResolution.toString();
    final coverUrl = art?.imageHash?.isNotEmpty == true && art?.type != null
        ? deezerImageUrl(art!.type, art.imageHash, resolution, resolution)
        : art?.full;

    return PlatformDownloadMetadata.fromTrack(
      track,
      coverUrl: coverUrl,
      trackTotal: publicAlbum['nb_tracks'] as int?,
      genre: genre,
      label: publicAlbum['label']?.toString(),
      isrc: publicTrack['isrc']?.toString(),
      upc: publicAlbum['upc']?.toString(),
      bpm: publicTrack['bpm']?.toString(),
    );
  }

  // ---------------------------------------------------------------------------
  // Deep-link parsing
  // ---------------------------------------------------------------------------

  @override
  Future<PlatformLinkResponse?> parseLink(String url) async {
    final response = await _api.parseLink(url);
    if (response == null || response.type == null) return null;
    PlatformLinkType type;
    switch (response.type!) {
      case DeezerLinkType.TRACK:
        type = PlatformLinkType.track;
        break;
      case DeezerLinkType.ALBUM:
        type = PlatformLinkType.album;
        break;
      case DeezerLinkType.ARTIST:
        type = PlatformLinkType.artist;
        break;
      case DeezerLinkType.PLAYLIST:
        type = PlatformLinkType.playlist;
        break;
    }
    return PlatformLinkResponse(
      type: type,
      id: response.id!,
      platformId: platformId,
    );
  }

  // ---------------------------------------------------------------------------
  // Logging
  // ---------------------------------------------------------------------------

  @override
  QueueSource get favoritesQueueSource => QueueSource(
    id: _api.favoritesPlaylistId?.toString() ?? 'favorites_$platformId',
    text: 'Favorites'.i18n,
    source: 'playlist_page',
  );

  @override
  Future<void> logListen(
    String trackId,
    QueueSource? queue, {
    ListenLogDetails? details,
  }) => _api.logListen(trackId, queue, details: details);

  // ---------------------------------------------------------------------------
  // Discography
  // ---------------------------------------------------------------------------

  @override
  Future<List<Track>> getArtistTopTracks(String artistId) async {
    final artist = await getArtist(artistId);
    return artist.topTracks;
  }

  @override
  Future<List<Album>> getDiscographyPage(
    String artistId, {
    int start = 0,
    int nb = 50,
  }) => _api.discographyPage(artistId, start: start, nb: nb);

  @override
  Future<List<Track>> getPlaylistTracks(String id, int start, {int nb = 100}) =>
      _api.playlistTracksPage(id, start, nb: nb);

  @override
  Future<List<MediaItem>?> getAndroidAutoItems(String parentId) async {
    final cleanId = parentId.contains('_')
        ? parentId.split('_').first
        : parentId;
    if (cleanId == 'radio') {
      try {
        final radiosPage = await getChannel('channels/radios');
        final items = <MediaItem>[];
        for (final section in radiosPage.sections) {
          for (final item in section.items) {
            if (item?.type == HomePageItemType.RADIO &&
                item?.value is LiveRadio) {
              final r = item!.value as LiveRadio;
              items.add(
                MediaItem(
                  id: '_aa_radio_deezer_${r.id}',
                  title: r.title ?? 'Radio'.i18n,
                  album: 'Deezer',
                  displayTitle: r.title,
                  displaySubtitle:
                      (section.title != null &&
                          section.title!.isNotEmpty &&
                          section.title!.toLowerCase() != 'radio')
                      ? section.title!
                      : 'Live Radio'.i18n,
                  playable: true,
                  artUri: r.imageUrl != null && r.imageUrl!.isNotEmpty
                      ? Uri.tryParse(r.imageUrl!)
                      : null,
                ),
              );
            }
          }
        }
        if (items.isNotEmpty) return items;
      } catch (e, stack) {
        Logger.root.warning(
          'Deezer radio Android Auto loading failed: $e',
          e,
          stack,
        );
      }
    }
    return null;
  }
}
