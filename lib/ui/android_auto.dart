import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';

import '../api/definitions.dart';
import '../api/cache.dart';
import '../api/download.dart';
import '../platform/music_platform.dart';
import '../platform/platform_manager.dart';
import '../platform/platform_registry.dart';
import '../platform/neurokaraoke/radio/neuro_radio_service.dart';
import '../service/audio_service.dart';
import '../settings.dart';
import '../translations.i18n.dart';
import '../utils/logging.dart';

class AndroidAuto {
  // Prefix for "playable" MediaItem
  static const prefix = '_aa_';

  // Android Auto / Automotive content style hint constants
  static const contentStylePlayableHint =
      'android.media.browse.CONTENT_STYLE_PLAYABLE_HINT';
  static const contentStyleBrowsableHint =
      'android.media.browse.CONTENT_STYLE_BROWSABLE_HINT';
  static const contentStyleGroupTitleHint =
      'android.media.browse.CONTENT_STYLE_GROUP_TITLE_HINT';
  static const extraDownloadStatus =
      'android.media.extra.DOWNLOAD_STATUS';

  static const contentStyleList = 1;
  static const contentStyleGrid = 2;
  static const downloadStatusDownloaded = 2;

  static const gridItemExtras = <String, dynamic>{
    contentStylePlayableHint: contentStyleGrid,
    contentStyleBrowsableHint: contentStyleGrid,
  };

  static const listItemExtras = <String, dynamic>{
    contentStylePlayableHint: contentStyleList,
    contentStyleBrowsableHint: contentStyleList,
  };

  static const downloadedGridExtras = <String, dynamic>{
    contentStylePlayableHint: contentStyleGrid,
    contentStyleBrowsableHint: contentStyleGrid,
    extraDownloadStatus: downloadStatusDownloaded,
  };

  /// Safe helper to extract an art URI from any media model without throwing NoSuchMethodError.
  Uri? _extractArtUri(dynamic data) {
    if (data == null) return null;
    String? url;
    if (data is Track) {
      url = data.albumArt?.thumb ?? data.albumArt?.full;
    } else if (data is Album) {
      url = data.art?.thumb ?? data.art?.full;
    } else if (data is LocalPlaylist) {
      if (data.mosaicImages != null && data.mosaicImages!.isNotEmpty) {
        url = data.mosaicImages!.first;
      }
    } else if (data is Playlist) {
      url = data.image?.full ??
          data.image?.thumb ??
          (data.mosaicImages != null && data.mosaicImages!.isNotEmpty
              ? data.mosaicImages!.first
              : null);
      if (url == null || url.startsWith('assets/')) {
        final titleLower = data.title?.toLowerCase() ?? '';
        if (titleLower.contains('loved') || titleLower.contains('favorite')) {
          url =
              'https://e-cdns-images.dzcdn.net/images/cover/d41d8cd98f00b204e9800998ecf8427e/500x500-000000-80-0-0.jpg';
        }
      }
    } else if (data is Artist) {
      url = data.picture?.thumb ?? data.picture?.full;
    } else if (data is LiveRadio) {
      url = data.imageUrl;
    } else if (data is Show) {
      url = data.art?.thumb ?? data.art?.full;
    } else if (data is ShowEpisode) {
      url = data.art?.thumb ?? data.art?.full;
    } else if (data is SmartTrackList) {
      url = data.cover?.thumb ?? data.cover?.full;
    } else if (data is DeezerFlow) {
      url = data.cover?.thumb ?? data.cover?.full;
    } else if (data is DeezerChannel) {
      url = data.logo ?? data.backgroundImage?.thumb;
    } else {
      try {
        url = (data.imageUrl ??
            data.picture?.thumb ??
            data.image?.thumb ??
            data.art?.thumb ??
            data.cover?.thumb)?.toString();
      } catch (_) {}
    }
    if (url != null && url.isNotEmpty) {
      final parsed = Uri.tryParse(url);
      if (parsed != null) {
        if (parsed.hasScheme) return parsed;
        if (url.startsWith('/')) return Uri.file(url);
      }
    }
    return null;
  }

  /// Helper to resolve (platform, cleanParentId) from a platform-scoped parentId.
  (MusicPlatform platform, String cleanParentId) _parsePlatformScopedId(
    String parentId,
  ) {
    for (final p in PlatformRegistry.instance.allPlatforms) {
      if (parentId.endsWith('_${p.platformId}')) {
        final base = parentId.substring(
          0,
          parentId.length - p.platformId.length - 1,
        );
        return (p, base);
      }
    }
    final active = PlatformManager.instance.isInitialized
        ? PlatformManager.instance.active
        : PlatformRegistry.instance.allPlatforms.first;
    return (active, parentId);
  }

  static final Map<String, ({String title, String? subtitle, String? artUrl})>
      _radioStationCache = {};

  /// Helper to robustly extract (platformId, contentId) from a compound ID string,
  /// sorting by platformId length descending so prefixes like 'youtube_music_'
  /// match before single-word prefixes.
  (String platformId, String contentId) _extractPlatformAndId(
    String text,
    String defaultPlatformId,
  ) {
    final platforms = PlatformRegistry.instance.allPlatforms.toList()
      ..sort((a, b) => b.platformId.length.compareTo(a.platformId.length));
    for (final p in platforms) {
      if (text.startsWith('${p.platformId}_')) {
        return (p.platformId, text.substring(p.platformId.length + 1));
      }
    }
    return (defaultPlatformId, text);
  }

  Future<List<MusicPlatform>> _loggedInPlatforms() async {
    final platforms = PlatformRegistry.instance.allPlatforms;
    final loginStates = await Future.wait(
      platforms.map((platform) async {
        try {
          return await platform.isLoggedIn();
        } catch (_) {
          return false;
        }
      }),
    );
    return [
      for (var i = 0; i < platforms.length; i++)
        if (loginStates[i]) platforms[i],
    ];
  }

  /// Applies the user's saved sorting order to a list of tracks.
  List<Track> _applyUserSort(List<Track> input, Sorting? sort) =>
      input.applySorting(sort);

  Sorting? _savedTracksSort() {
    final index = Sorting.index(SortSourceTypes.TRACKS);
    return index == null ? null : cache.sorts[index];
  }

  /// The platform applies custom sorting to the full favorites set, then
  /// returns only the first queue page. Later pages use the same sort/cache.
  Future<List<Track>> _loadFavoritesForPlayback(MusicPlatform platform) async {
    final sort = _savedTracksSort();
    final page = await platform.getFavoriteTracks(limit: 100, sort: sort);
    return page.tracks;
  }

  MediaItem _buildPlatformsMenuItem(MusicPlatform activePlatform) {
    return MediaItem(
      id: 'platforms',
      title: 'Platforms'.i18n,
      album: 'Platforms'.i18n,
      displayTitle: 'Platforms'.i18n,
      displaySubtitle: '${'Active:'.i18n} ${activePlatform.platformName}',
      playable: false,
    );
  }

  Future<List<MediaItem>> _buildHomePageMediaItems(
    HomePage hp,
    MusicPlatform scopedPlatform, {
    int maxItemsPerSection = 10,
  }) async {
    final List<MediaItem> out = [];
    List<HomePageItem?>? pinnedItems;

    for (final section in hp.sections) {
      List<HomePageItem?> items = section.items;

      // If this section is QUICK_ACCESS, load pinned items if available (like desktop/mobile)
      if (section.layout == HomePageSectionLayout.QUICK_ACCESS) {
        try {
          final pinned =
              pinnedItems ??= await scopedPlatform.getPinnedHomePageItems();
          if (pinned.isNotEmpty) {
            items = pinned;
          }
        } catch (_) {}
      }

      if (items.isEmpty) continue;

      final sectionTitle = section.title?.trim();

      int count = 0;
      for (final item in items) {
        if (item == null) continue;
        final data = item.value;
        if (data == null) continue;
        if (count >= maxItemsPerSection) break;

        final itemExtras = <String, dynamic>{
          contentStylePlayableHint: contentStyleGrid,
          contentStyleBrowsableHint: contentStyleGrid,
          if (sectionTitle != null && sectionTitle.isNotEmpty)
            contentStyleGroupTitleHint: sectionTitle,
        };

        MediaItem? mediaItem;

        switch (item.type) {
          case HomePageItemType.RADIO:
            final isMix = (data is LiveRadio && data.isMix) ||
                (data.id != null &&
                    (data.id.toString().startsWith('RD') ||
                        data.id.toString().startsWith('VLRD') ||
                        data.id.toString().startsWith('mix:')));
            final title = data is LiveRadio
                ? (data.title ?? (isMix ? 'Mix'.i18n : 'Radio'.i18n))
                : (data.title ?? (isMix ? 'Mix'.i18n : 'Radio'.i18n));
            final subtitle = isMix ? 'Mix'.i18n : 'Live Radio'.i18n;
            _radioStationCache['${scopedPlatform.platformId}_${data.id}'] = (
              title: title,
              subtitle: subtitle,
              artUrl: data is LiveRadio ? data.imageUrl : null,
            );
            final itemId = isMix
                ? '${prefix}mix_${scopedPlatform.platformId}_${data.id}'
                : '${prefix}radio_${scopedPlatform.platformId}_${data.id}';
            mediaItem = MediaItem(
              id: itemId,
              title: title,
              album: scopedPlatform.platformName,
              displayTitle: title,
              displaySubtitle: subtitle,
              playable: true,
              artUri: _extractArtUri(data),
              extras: itemExtras,
            );
            break;

          case HomePageItemType.PLAYLIST:
            final isMix = item.playMix ||
                (data.id != null &&
                    (data.id.toString().startsWith('RD') ||
                        data.id.toString().startsWith('VLRD') ||
                        data.id.toString().startsWith('mix:')));
            final itemId = isMix
                ? '${prefix}mix_${scopedPlatform.platformId}_${data.id}'
                : '${prefix}playlist_${scopedPlatform.platformId}_${data.id}';
            mediaItem = MediaItem(
              id: itemId,
              title: data.title ?? '',
              album: scopedPlatform.platformName,
              displayTitle: data.title,
              displaySubtitle: isMix
                  ? 'Mix'.i18n
                  : '${data.trackCount ?? ''} ${'Tracks'.i18n}'.trim(),
              playable: true,
              artUri: _extractArtUri(data),
              extras: itemExtras,
            );
            break;

          case HomePageItemType.ALBUM:
            mediaItem = MediaItem(
              id: '${prefix}album_${scopedPlatform.platformId}_${data.id}',
              title: data.title ?? '',
              album: data.title ?? '',
              displayTitle: data.title,
              displaySubtitle: data.artistString ?? '',
              playable: true,
              artUri: _extractArtUri(data),
              extras: itemExtras,
            );
            break;

          case HomePageItemType.ARTIST:
            mediaItem = MediaItem(
              id: 'artist_${scopedPlatform.platformId}_${data.id}',
              title: data.name ?? '',
              album: scopedPlatform.platformName,
              displayTitle: data.name,
              playable: false,
              artUri: _extractArtUri(data),
              extras: itemExtras,
            );
            break;

          case HomePageItemType.TRACK:
            final isMix = data is Track &&
                data.id != null &&
                (data.id!.startsWith('RD') ||
                    data.id!.startsWith('VLRD') ||
                    data.id!.startsWith('mix:'));
            final itemId = isMix
                ? '${prefix}mix_${scopedPlatform.platformId}_${data.id}'
                : '${prefix}track_${scopedPlatform.platformId}_${data.id}';
            mediaItem = MediaItem(
              id: itemId,
              title: data.title ?? '',
              album: data.album?.title ?? '',
              displayTitle: data.title,
              displaySubtitle: data.artistString ?? '',
              playable: true,
              artUri: _extractArtUri(data),
              extras: itemExtras,
            );
            break;

          case HomePageItemType.SHOW:
            mediaItem = MediaItem(
              id: 'show_${scopedPlatform.platformId}_${data.id}',
              title: data.name ?? '',
              album: scopedPlatform.platformName,
              displayTitle: data.name,
              playable: false,
              artUri: _extractArtUri(data),
              extras: itemExtras,
            );
            break;

          case HomePageItemType.EPISODE:
            mediaItem = MediaItem(
              id: '${prefix}episode_${scopedPlatform.platformId}_${data.show?.id ?? ''}_${data.id}',
              title: data.title ?? '',
              album: data.show?.name ?? '',
              displayTitle: data.title,
              displaySubtitle: data.show?.name ?? '',
              playable: true,
              artUri: _extractArtUri(data),
              extras: itemExtras,
            );
            break;

          case HomePageItemType.PLATFORM:
            if (item.isPlatformItem('smarttracklist')) {
              mediaItem = MediaItem(
                id: '${prefix}stl_${scopedPlatform.platformId}_${data.id}',
                title: data.title ?? '',
                album: scopedPlatform.platformName,
                displayTitle: data.title,
                displaySubtitle: data.subtitle ?? '',
                playable: true,
                artUri: _extractArtUri(data),
                extras: itemExtras,
              );
            } else if (item.isPlatformItem('flow') && data is DeezerFlow) {
              mediaItem = MediaItem(
                id: '${prefix}flow_${scopedPlatform.platformId}_${data.id ?? ''}',
                title: data.title ?? 'Radio'.i18n,
                album: scopedPlatform.platformName,
                displayTitle: data.title ?? 'Radio'.i18n,
                displaySubtitle: 'Radio'.i18n,
                playable: true,
                artUri: _extractArtUri(data),
                extras: itemExtras,
              );
            } else if (item.isPlatformItem('channel') || data is DeezerChannel) {
              final target = (data is DeezerChannel
                      ? data.target
                      : (data.target ?? data.id))
                  ?.toString();
              if (target != null && target.isNotEmpty) {
                mediaItem = MediaItem(
                  id: 'channel_${scopedPlatform.platformId}_$target',
                  title: data.title ?? '',
                  album: scopedPlatform.platformName,
                  displayTitle: data.title,
                  displaySubtitle: '',
                  playable: false,
                  artUri: _extractArtUri(data),
                  extras: itemExtras,
                );
              }
            }
            break;

          case HomePageItemType.GENRE:
            final target = (data.target ?? data.id)?.toString();
            if (target != null && target.isNotEmpty) {
              mediaItem = MediaItem(
                id: 'channel_${scopedPlatform.platformId}_$target',
                title: data.title ?? '',
                album: scopedPlatform.platformName,
                displayTitle: data.title,
                displaySubtitle: 'Genre'.i18n,
                playable: false,
                artUri: _extractArtUri(data),
                extras: itemExtras,
              );
            }
            break;

          default:
            break;
        }

        if (mediaItem != null) {
          out.add(mediaItem);
          count++;
        }
      }
    }

    return out;
  }

  // Get media items for parent id
  Future<List<MediaItem>> getScreen(String parentId) async {
    if (kDebugMode) {
      appLogger.fine('Android Auto: loading screen $parentId');
    }

    try {
      // 1. Homescreen / Root
      if (parentId == 'root') return await homeScreen();

      // 2. Platforms screen (lists logged-in/connected platforms to switch or browse)
      if (parentId == 'platforms') {
        final active = PlatformManager.instance.isInitialized
            ? PlatformManager.instance.active
            : PlatformRegistry.instance.allPlatforms.first;

        final loggedIn = await _loggedInPlatforms();
        final platformsToShow = loggedIn.isNotEmpty ? loggedIn : [active];

        return platformsToShow.map((p) {
          final isActive = p.platformId == active.platformId;
          return MediaItem(
            id: 'platform_screen_${p.platformId}',
            title: p.platformName,
            album: 'Platforms'.i18n,
            displayTitle: p.platformName,
            displaySubtitle:
                isActive ? 'Active platform'.i18n : 'Switch or browse'.i18n,
            playable: false,
          );
        }).toList();
      }

      // 3. Platform-specific screen
      if (parentId.startsWith('platform_screen_')) {
        final platformId = parentId.replaceFirst('platform_screen_', '');
        final platform = PlatformRegistry.instance.get(platformId);
        if (platform == null) return [];

        final active = PlatformManager.instance.isInitialized
            ? PlatformManager.instance.active
            : PlatformRegistry.instance.allPlatforms.first;
        final isActive = platform.platformId == active.platformId;

        final out = <MediaItem>[];

        // 1-tap action to switch active platform
        out.add(
          MediaItem(
            id: '${prefix}switch_${platform.platformId}',
            title: '${'Switch to'.i18n} ${platform.platformName}',
            album: platform.platformName,
            displayTitle: '${'Switch to'.i18n} ${platform.platformName}',
            displaySubtitle:
                isActive ? 'Currently active'.i18n : 'Set as active platform'.i18n,
            playable: true,
          ),
        );

        final customRoot = await platform.getAndroidAutoItems('root');
        if (customRoot != null && customRoot.isNotEmpty) {
          out.addAll(customRoot);
          return out;
        }

        if (platform.capabilities.supportsRadio) {
          out.add(
            MediaItem(
              id: 'radio_${platform.platformId}',
              title: 'Live Radio'.i18n,
              album: platform.platformName,
              displayTitle: 'Live Radio'.i18n,
              displaySubtitle: platform.platformName,
              playable: false,
              extras: gridItemExtras,
            ),
          );
        }

        out.add(
          MediaItem(
            id: 'homescreen_${platform.platformId}',
            title: 'Home'.i18n,
            album: platform.platformName,
            displayTitle: 'Home'.i18n,
            displaySubtitle: platform.platformName,
            playable: false,
            extras: gridItemExtras,
          ),
        );

        if (platform.capabilities.supportsFlow) {
          out.add(
            MediaItem(
              id: '${prefix}flow_${platform.platformId}',
              title: 'Radio'.i18n,
              album: platform.platformName,
              displayTitle: 'Radio'.i18n,
              displaySubtitle: platform.platformName,
              playable: true,
            ),
          );
        }

        if (platform.capabilities.supportsLibrarySync) {
          out.add(
            MediaItem(
              id: '${prefix}tracks_${platform.platformId}',
              title: 'Loved tracks'.i18n,
              album: platform.platformName,
              displayTitle: 'Loved tracks'.i18n,
              displaySubtitle: platform.platformName,
              playable: true,
              extras: listItemExtras,
            ),
          );
        }

        out.add(
          MediaItem(
            id: 'playlists_${platform.platformId}',
            title: 'Playlists'.i18n,
            album: platform.platformName,
            displayTitle: 'Playlists'.i18n,
            displaySubtitle: platform.platformName,
            playable: false,
            extras: gridItemExtras,
          ),
        );

        if (platform.capabilities.supportsAlbums) {
          out.add(
            MediaItem(
              id: 'albums_${platform.platformId}',
              title: 'Albums'.i18n,
              album: platform.platformName,
              displayTitle: 'Albums'.i18n,
              displaySubtitle: platform.platformName,
              playable: false,
              extras: gridItemExtras,
            ),
          );
        }

        if (platform.capabilities.supportsArtists) {
          out.add(
            MediaItem(
              id: 'artists_${platform.platformId}',
              title: 'Artists'.i18n,
              album: platform.platformName,
              displayTitle: 'Artists'.i18n,
              displaySubtitle: platform.platformName,
              playable: false,
              extras: gridItemExtras,
            ),
          );
        }

        if (platform.capabilities.supportsShows) {
          out.add(
            MediaItem(
              id: 'shows_${platform.platformId}',
              title: 'Podcasts'.i18n,
              album: platform.platformName,
              displayTitle: 'Podcasts'.i18n,
              displaySubtitle: platform.platformName,
              playable: false,
              extras: gridItemExtras,
            ),
          );
        }

        if (platform.capabilities.supportsExplorePage) {
          out.add(
            MediaItem(
              id: 'explore_${platform.platformId}',
              title: 'Explore'.i18n,
              album: platform.platformName,
              displayTitle: 'Explore'.i18n,
              displaySubtitle: platform.platformName,
              playable: false,
              extras: gridItemExtras,
            ),
          );
        }

        return out;
      }

      final (scopedPlatform, cleanParentId) = _parsePlatformScopedId(parentId);

      // Check if platform provides custom items for this parentId
      final customItems =
          await scopedPlatform.getAndroidAutoItems(cleanParentId);
      if (customItems != null && customItems.isNotEmpty) {
        for (final item in customItems) {
          if (item.id.startsWith('${prefix}radio_')) {
            final stripped = item.id.replaceFirst('${prefix}radio_', '');
            final (pId, sId) = _extractPlatformAndId(
              stripped,
              scopedPlatform.platformId,
            );
            _radioStationCache['${pId}_$sId'] = (
              title: item.title,
              subtitle: item.displaySubtitle,
              artUrl: item.artUri?.toString(),
            );
            _radioStationCache[sId] = (
              title: item.title,
              subtitle: item.displaySubtitle,
              artUrl: item.artUri?.toString(),
            );
          }
        }
        return customItems;
      }

      // 4. Offline playlists screen
      if (cleanParentId == 'offline' || cleanParentId == 'offline_playlists') {
        try {
          if (downloadManager.db == null) await downloadManager.init();
          final List<Playlist> offlinePlaylists =
              await downloadManager.getOfflinePlaylists();
          return offlinePlaylists.map<MediaItem>((p) {
            final countStr = p.trackCount != null
                ? '${p.trackCount} ${'Tracks'.i18n}'
                : '';
            return MediaItem(
              id: '${prefix}offline_playlist_${p.platformId}_${p.id}',
              title: p.title ?? '',
              album: 'Offline Playlists'.i18n,
              displayTitle: p.title,
              displaySubtitle: countStr,
              playable: true,
              artUri: _extractArtUri(p),
              extras: downloadedGridExtras,
            );
          }).toList();
        } catch (e, stack) {
          appLogger.warning('Android Auto error loading offline playlists: $e\n$stack');
          return [];
        }
      }

      // 5. Radio screen
      if (cleanParentId == 'radio') {
        if (scopedPlatform.platformId == 'neurokaraoke') {
          return [
            MediaItem(
              id: '${prefix}radio_${scopedPlatform.platformId}_$kNeuroRadioStationId',
              title: kNeuroRadioStationName,
              album: scopedPlatform.platformName,
              displayTitle: kNeuroRadioStationName,
              displaySubtitle: 'Live 24/7 Stream'.i18n,
              playable: true,
              extras: gridItemExtras,
            ),
          ];
        }

        if (scopedPlatform.platformId == 'deezer') {
          try {
            final radiosPage =
                await (scopedPlatform as dynamic).getChannel('channels/radios');
            final radioItems = <MediaItem>[];
            for (final section in radiosPage.sections) {
              for (final item in section.items) {
                if (item?.type == HomePageItemType.RADIO) {
                  final data = item!.value;
                  final title = data is LiveRadio
                      ? (data.title ?? 'Radio'.i18n)
                      : (data.title ?? 'Radio'.i18n);
                  final subtitle = section.title ?? 'Live Radio'.i18n;
                  _radioStationCache['${scopedPlatform.platformId}_${data.id}'] = (
                    title: title,
                    subtitle: subtitle,
                    artUrl: data is LiveRadio ? data.imageUrl : null,
                  );
                  radioItems.add(
                    MediaItem(
                      id: '${prefix}radio_${scopedPlatform.platformId}_${data.id}',
                      title: title,
                      album: scopedPlatform.platformName,
                      displayTitle: title,
                      displaySubtitle: subtitle,
                      playable: true,
                      artUri: _extractArtUri(data),
                      extras: gridItemExtras,
                    ),
                  );
                }
              }
            }
            if (radioItems.isNotEmpty) return radioItems;
          } catch (e, stack) {
            appLogger.warning('Deezer radio Android Auto loading failed: $e\n$stack');
          }
        }

        try {
          final home = await scopedPlatform.getHomePage();
          final radioItems = <MediaItem>[];
          for (final section in home.sections) {
            for (final item in section.items) {
              if (item?.type == HomePageItemType.RADIO) {
                final data = item!.value;
                final title = data is LiveRadio
                    ? (data.title ?? 'Radio'.i18n)
                    : (data.title ?? 'Radio'.i18n);
                final subtitle = (section.title != null && section.title!.isNotEmpty)
                    ? section.title!
                    : (data is LiveRadio && data.description?.isNotEmpty == true
                        ? data.description!
                        : 'Live Radio'.i18n);
                _radioStationCache['${scopedPlatform.platformId}_${data.id}'] = (
                  title: title,
                  subtitle: subtitle,
                  artUrl: data is LiveRadio ? data.imageUrl : null,
                );
                radioItems.add(
                  MediaItem(
                    id: '${prefix}radio_${scopedPlatform.platformId}_${data.id}',
                    title: title,
                    album: scopedPlatform.platformName,
                    displayTitle: title,
                    displaySubtitle: subtitle,
                    playable: true,
                    artUri: _extractArtUri(data),
                    extras: gridItemExtras,
                  ),
                );
              }
            }
          }
          if (radioItems.isNotEmpty) return radioItems;
        } catch (_) {}
        return [];
      }

      // 6. Playlists screen
      if (cleanParentId == 'playlists') {
        final out = <MediaItem>[];

        // Ensure DownloadManager and its SQLite DB are initialized before querying
        if (downloadManager.db == null) {
          try {
            await downloadManager.init();
          } catch (e, st) {
            appLogger.warning(
              'Android Auto failed to init downloadManager: $e\n$st',
            );
          }
        }

        // 1. Gather all offlined playlist IDs to mark download badges directly without duplicating
        final Set<String> offlinedIds = {};
        final List<Playlist> offlinePlaylists = [];
        try {
          offlinePlaylists.addAll(await downloadManager.getOfflinePlaylists());
          for (final op in offlinePlaylists) {
            if (op.id != null) {
              offlinedIds.add(op.id!);
              offlinedIds.add('local_${op.id}');
              offlinedIds.add('${op.platformId}_${op.id}');
            }
          }
        } catch (_) {}

        // 2. Local playlists FIRST (regardless of platform, include all local playlists)
        List<LocalPlaylist> localPlaylists = [];
        try {
          localPlaylists =
              await downloadManager.localPlaylistManager.getAllPlaylists();
          appLogger.fine(
            'Android Auto: loaded ${localPlaylists.length} local playlists for $parentId',
          );
        } catch (e, st) {
          appLogger.warning(
            'Failed to fetch local playlists for Android Auto: $e\n$st',
          );
        }

        final localGroup = 'Local Playlists'.i18n;
        for (final lp in localPlaylists) {
          final isOfflined = lp.offline ||
              offlinedIds.contains(lp.id) ||
              offlinedIds.contains('local_${lp.id}');
          final countStr = '${lp.trackCount} ${'Tracks'.i18n}';

          out.add(
            MediaItem(
              id: '${prefix}local_playlist_${lp.id}',
              title: lp.title,
              album: 'Local Playlists'.i18n,
              displayTitle: lp.title,
              displaySubtitle: countStr,
              playable: true,
              artUri: _extractArtUri(lp),
              extras: {
                ...gridItemExtras,
                if (isOfflined) extraDownloadStatus: downloadStatusDownloaded,
                contentStyleGroupTitleHint: localGroup,
              },
            ),
          );
        }

        // 3. Platform / Online playlists
        List<Playlist> onlinePlaylists = [];
        try {
          onlinePlaylists = await scopedPlatform.getUserPlaylists();
        } catch (e) {
          appLogger.fine('Failed to fetch online playlists (might be offline): $e');
        }

        final playlistsGroup = 'Playlists'.i18n;
        if (onlinePlaylists.isNotEmpty) {
          for (final p in onlinePlaylists) {
            final isOfflined = offlinedIds.contains(p.id) ||
                offlinedIds.contains('${scopedPlatform.platformId}_${p.id}');

            int? count = p.trackCount;
            final titleLower = p.title?.toLowerCase() ?? '';
            if ((count == null || count == 0) &&
                (titleLower.contains('loved') || titleLower.contains('favorite'))) {
              if (cache.activeLibraryTracks.isNotEmpty) {
                count = cache.activeLibraryTracks.length;
              }
            }

            final countStr = count != null && count > 0
                ? '$count ${'Tracks'.i18n}'
                : '';

            out.add(
              MediaItem(
                id: '${prefix}playlist_${scopedPlatform.platformId}_${p.id}',
                title: p.title ?? '',
                album: scopedPlatform.platformName,
                displayTitle: p.title,
                displaySubtitle: countStr,
                playable: true,
                artUri: _extractArtUri(p),
                extras: {
                  ...gridItemExtras,
                  if (isOfflined) extraDownloadStatus: downloadStatusDownloaded,
                  contentStyleGroupTitleHint: playlistsGroup,
                },
              ),
            );
          }
        } else {
          // Fallback if offline: show downloaded platform playlists directly
          for (final p in offlinePlaylists) {
            if (p.platformId == 'local') continue;
            final countStr = p.trackCount != null && p.trackCount! > 0
                ? '${p.trackCount} ${'Tracks'.i18n}'
                : '';
            out.add(
              MediaItem(
                id: '${prefix}offline_playlist_${p.platformId}_${p.id}',
                title: p.title ?? '',
                album: scopedPlatform.platformName,
                displayTitle: p.title,
                displaySubtitle: countStr,
                playable: true,
                artUri: _extractArtUri(p),
                extras: {
                  ...downloadedGridExtras,
                  contentStyleGroupTitleHint: playlistsGroup,
                },
              ),
            );
          }
        }

        return out;
      }

      // 7. Albums screen
      if (cleanParentId == 'albums') {
        final List<Album> albums = await scopedPlatform.getUserAlbums();
        final albumGroup = 'Albums'.i18n;
        return albums.map<MediaItem>((a) {
          return MediaItem(
            id: '${prefix}album_${scopedPlatform.platformId}_${a.id}',
            title: a.title ?? '',
            album: a.title ?? '',
            displayTitle: a.title,
            displaySubtitle: a.artistString ?? '',
            playable: true,
            artUri: _extractArtUri(a),
            extras: {
              ...gridItemExtras,
              contentStyleGroupTitleHint: albumGroup,
            },
          );
        }).toList();
      }

      // 8. Artists screen
      if (cleanParentId == 'artists') {
        final List<Artist> artists = await scopedPlatform.getUserArtists();
        final artistGroup = 'Artists'.i18n;
        return artists.map<MediaItem>((a) {
          return MediaItem(
            id: 'artist_albums_${scopedPlatform.platformId}_${a.id}',
            title: a.name ?? '',
            album: scopedPlatform.platformName,
            displayTitle: a.name,
            playable: false,
            artUri: _extractArtUri(a),
            extras: {
              ...gridItemExtras,
              contentStyleGroupTitleHint: artistGroup,
            },
          );
        }).toList();
      }

      // 8. Artist page (Top Tracks, Albums, Playlists, Custom Sections / Videos)
      if (parentId.startsWith('artist_albums_') ||
          parentId.startsWith('artist_') ||
          parentId.startsWith('${prefix}albums')) {
        String platformId = scopedPlatform.platformId;
        String artistId;
        if (parentId.startsWith('artist_albums_')) {
          final remainder = parentId.replaceFirst('artist_albums_', '');
          final (pId, aId) =
              _extractPlatformAndId(remainder, scopedPlatform.platformId);
          platformId = pId;
          artistId = aId;
        } else if (parentId.startsWith('artist_')) {
          final remainder = parentId.replaceFirst('artist_', '');
          final (pId, aId) =
              _extractPlatformAndId(remainder, scopedPlatform.platformId);
          platformId = pId;
          artistId = aId;
        } else {
          artistId = parentId.replaceFirst('${prefix}albums', '');
        }

        final platform = PlatformManager.instance.getPlatform(platformId);
        final Artist artist = await platform.getArtist(artistId);
        final items = <MediaItem>[];

        // 1. Top Tracks
        List<Track> topTracks = artist.topTracks;
        if (topTracks.isEmpty) {
          try {
            topTracks = await platform.getArtistTopTracks(artistId);
          } catch (_) {}
        }
        for (final t in topTracks.take(10)) {
          items.add(
            MediaItem(
              id: '${prefix}track_${platform.platformId}_${t.id}',
              title: t.title ?? '',
              album: artist.name ?? '',
              displayTitle: t.title,
              displaySubtitle: t.artistString ?? artist.name ?? '',
              playable: true,
              artUri: _extractArtUri(t),
              extras: {
                ...listItemExtras,
                contentStyleGroupTitleHint: 'Top Tracks'.i18n,
              },
            ),
          );
        }

        // 2. Albums
        List<Album> albums = artist.albums;
        if (albums.isEmpty) {
          try {
            albums = await platform.getDiscographyPage(artistId);
          } catch (_) {}
        }
        for (final a in albums) {
          items.add(
            MediaItem(
              id: '${prefix}album_${platform.platformId}_${a.id}',
              title: a.title ?? '',
              album: a.title ?? '',
              displayTitle: a.title,
              displaySubtitle: a.artistString ?? '',
              playable: true,
              artUri: _extractArtUri(a),
              extras: {
                ...gridItemExtras,
                contentStyleGroupTitleHint: 'Albums'.i18n,
              },
            ),
          );
        }

        // 3. Playlists (Essentials, Featured, etc.)
        for (final p in artist.playlists) {
          items.add(
            MediaItem(
              id: '${prefix}playlist_${platform.platformId}_${p.id}',
              title: p.title ?? '',
              album: artist.name ?? '',
              displayTitle: p.title,
              displaySubtitle: '${p.trackCount ?? 0} ${'Tracks'.i18n}'.trim(),
              playable: true,
              artUri: _extractArtUri(p),
              extras: {
                ...gridItemExtras,
                contentStyleGroupTitleHint: 'Playlists'.i18n,
              },
            ),
          );
        }

        // 4. Custom Sections (e.g. Videos for YouTube Music, Singles & EPs, etc.)
        try {
          final customSections = platform.buildArtistPageSections(null, artist);
          for (final section in customSections) {
            if (section.title.toLowerCase().contains('album') &&
                albums.isNotEmpty) {
              continue;
            }
            final sectionData = await section.loadItems(10);
            for (final entry in sectionData) {
              if (entry is Track) {
                final isMix = entry.id != null &&
                    (entry.id!.startsWith('RD') ||
                        entry.id!.startsWith('VLRD') ||
                        entry.id!.startsWith('mix:'));
                items.add(
                  MediaItem(
                    id: isMix
                        ? '${prefix}mix_${platform.platformId}_${entry.id}'
                        : '${prefix}track_${platform.platformId}_${entry.id}',
                    title: entry.title ?? '',
                    album: artist.name ?? '',
                    displayTitle: entry.title,
                    displaySubtitle: isMix
                        ? 'Mix'.i18n
                        : (entry.artistString ?? artist.name ?? ''),
                    playable: true,
                    artUri: _extractArtUri(entry),
                    extras: {
                      ...listItemExtras,
                      contentStyleGroupTitleHint: section.title,
                    },
                  ),
                );
              } else if (entry is Album) {
                items.add(
                  MediaItem(
                    id: '${prefix}album_${platform.platformId}_${entry.id}',
                    title: entry.title ?? '',
                    album: entry.title ?? '',
                    displayTitle: entry.title,
                    displaySubtitle: entry.artistString ?? '',
                    playable: true,
                    artUri: _extractArtUri(entry),
                    extras: {
                      ...gridItemExtras,
                      contentStyleGroupTitleHint: section.title,
                    },
                  ),
                );
              } else if (entry is Playlist) {
                items.add(
                  MediaItem(
                    id: '${prefix}playlist_${platform.platformId}_${entry.id}',
                    title: entry.title ?? '',
                    album: artist.name ?? '',
                    displayTitle: entry.title,
                    displaySubtitle:
                        '${entry.trackCount ?? 0} ${'Tracks'.i18n}'.trim(),
                    playable: true,
                    artUri: _extractArtUri(entry),
                    extras: {
                      ...gridItemExtras,
                      contentStyleGroupTitleHint: section.title,
                    },
                  ),
                );
              }
            }
          }
        } catch (_) {}

        return items;
      }

      // 10. Shows / Podcasts screen
      if (cleanParentId == 'shows') {
        final List<Show> shows = await scopedPlatform.getUserShows();
        final podcastGroup = 'Podcasts'.i18n;
        return shows.map<MediaItem>((s) {
          return MediaItem(
            id: 'show_${scopedPlatform.platformId}_${s.id}',
            title: s.name ?? '',
            album: scopedPlatform.platformName,
            displayTitle: s.name,
            displaySubtitle: s.description ?? '',
            playable: false,
            artUri: _extractArtUri(s),
            extras: {
              ...gridItemExtras,
              contentStyleGroupTitleHint: podcastGroup,
            },
          );
        }).toList();
      }

      // 11. Episodes for a show
      if (parentId.startsWith('show_')) {
        final remainder = parentId.replaceFirst('show_', '');
        final (platformId, showId) =
            _extractPlatformAndId(remainder, scopedPlatform.platformId);
        final platform = PlatformManager.instance.getPlatform(platformId);
        final page = await platform.getShowEpisodesPage(showId, limit: 30);
        return page.episodes.map<MediaItem>((e) {
          return MediaItem(
            id: '${prefix}episode_${platform.platformId}_${showId}_${e.id}',
            title: e.title ?? '',
            album: e.show?.name ?? '',
            displayTitle: e.title,
            displaySubtitle: e.publishedDate ?? '',
            playable: true,
            artUri: _extractArtUri(e),
            extras: listItemExtras,
          );
        }).toList();
      }

      // 12. Explore screen
      if (cleanParentId == 'explore') {
        final HomePage hp = await scopedPlatform.getExplorePage();
        return await _buildHomePageMediaItems(hp, scopedPlatform);
      }

      // 13. Homescreen feed
      if (cleanParentId == 'homescreen') {
        final HomePage hp = await scopedPlatform.getHomePage();
        return await _buildHomePageMediaItems(hp, scopedPlatform);
      }

      // 14. Channels / Sub-pages (genres, category pages, etc.)
      if (parentId.startsWith('channel_')) {
        final remainder = parentId.replaceFirst('channel_', '');
        final (platformId, target) =
            _extractPlatformAndId(remainder, scopedPlatform.platformId);
        final platform = PlatformManager.instance.getPlatform(platformId);
        final page = await platform.getChannel(target);
        return await _buildHomePageMediaItems(page, platform);
      }

      return [];
    } catch (e, stack) {
      appLogger.warning('Android Auto error loading screen $parentId: $e\n$stack');
      return [];
    }
  }

  // Load virtual mediaItem
  Future<void> playItem(String id) async {
    if (kDebugMode) {
      appLogger.fine('Android Auto: playing item $id');
    }

    try {
      final active = PlatformManager.instance.isInitialized
          ? PlatformManager.instance.active
          : PlatformRegistry.instance.allPlatforms.first;

      // 1. Check if platform handles playback directly
      if (await active.playAndroidAutoItem(id)) return;

      // 2. Switch platform action
      if (id.startsWith('${prefix}switch_')) {
        final platformId = id.replaceFirst('${prefix}switch_', '');
        await _handleSwitchPlatform(platformId);
        return;
      }

      // 3. Play flow / radio
      if (id == '${prefix}flow' ||
          id == '${prefix}stlflow' ||
          id.startsWith('${prefix}flow_')) {
        MusicPlatform platform = active;
        if (id.startsWith('${prefix}flow_')) {
          final pid = id.replaceFirst('${prefix}flow_', '');
          platform = PlatformManager.instance.getPlatform(pid);
        }
        if (platform.platformId == 'youtube_music') {
          await GetIt.I<AudioPlayerHandler>().playMix(
            'RDMM',
            'Radio'.i18n,
            platformId: 'youtube_music',
          );
          return;
        }
        final tracks = await platform.getFlow();
        if (tracks.isNotEmpty) {
          await GetIt.I<AudioPlayerHandler>().playFromTrackList(
            tracks,
            tracks[0].id ?? '',
            QueueSource(
              id: 'flow_${platform.platformId}',
              text: 'Flow'.i18n,
              source: 'flow',
            ),
          );
        }
        return;
      }

      // 3b. Play mix
      if (id.startsWith('${prefix}mix_')) {
        final remainder = id.replaceFirst('${prefix}mix_', '');
        final (platformId, rawId) =
            _extractPlatformAndId(remainder, active.platformId);
        final cleanId = rawId.startsWith('mix:')
            ? rawId.substring(4)
            : (rawId.startsWith('radio:')
                ? rawId.substring(6)
                : (rawId.startsWith('VL') ? rawId.substring(2) : rawId));
        final cached = _radioStationCache['${platformId}_$rawId'] ??
            _radioStationCache[rawId] ??
            _radioStationCache[cleanId];
        await GetIt.I<AudioPlayerHandler>().playMix(
          cleanId,
          cached?.title ?? 'Mix'.i18n,
          platformId: platformId,
        );
        return;
      }

      // 4. Play library tracks / Loved tracks
      if (id == '${prefix}tracks' || id.startsWith('${prefix}tracks_')) {
        MusicPlatform platform = active;
        if (id.startsWith('${prefix}tracks_')) {
          final pid = id.replaceFirst('${prefix}tracks_', '');
          platform = PlatformManager.instance.getPlatform(pid);
        }
        List<Track>? favTracks;
        try {
          favTracks = await _loadFavoritesForPlayback(platform);
        } catch (e) {
          if (kDebugMode) {
            appLogger.warning('Android Auto item playback failed', e);
          }
        }
        if (favTracks == null || favTracks.isEmpty) return;

        await GetIt.I<AudioPlayerHandler>().playFromTrackList(
          favTracks,
          favTracks[0].id ?? '',
          QueueSource(
            id: platform.favoritesQueueSource.id,
            text: platform.favoritesQueueSource.text,
            source: platform.favoritesQueueSource.source,
            sort: _savedTracksSort(),
          ),
        );
        return;
      }

      // 5. Play radio
      if (id.startsWith('${prefix}radio_')) {
        final stripped = id.replaceFirst('${prefix}radio_', '');
        var (platformId, stationId) = _extractPlatformAndId(
          stripped,
          active.platformId,
        );

        final cached = _radioStationCache['${platformId}_$stationId'] ??
            _radioStationCache[stationId] ??
            _radioStationCache[stripped];

        String stationTitle = cached?.title ?? 'Radio'.i18n;
        String? stationArt = cached?.artUrl;

        if (platformId == 'neurokaraoke' &&
            (stationId == kNeuroRadioStationId ||
                stationId == 'neuro_21' ||
                stationId == 'neuro21')) {
          stationTitle = kNeuroRadioStationName;
          stationId = kNeuroRadioStationId;
        }

        if (stationId.startsWith('RD') ||
            stationId.startsWith('VLRD') ||
            stationId.startsWith('mix:')) {
          final cleanId = stationId.startsWith('mix:')
              ? stationId.substring(4)
              : (stationId.startsWith('VL')
                  ? stationId.substring(2)
                  : stationId);
          await GetIt.I<AudioPlayerHandler>().playMix(
            cleanId,
            stationTitle,
            platformId: platformId,
          );
          return;
        }

        if (stationId.startsWith('radio:')) {
          stationId = stationId.substring(6);
        }

        await GetIt.I<AudioPlayerHandler>().playRadio(
          id: stationId,
          title: stationTitle,
          description: 'Live Radio'.i18n,
          artUrl: stationArt,
          platformId: platformId,
        );
        return;
      }

      // 6. Play single track
      if (id.startsWith('${prefix}track_')) {
        final remainder = id.replaceFirst('${prefix}track_', '');
        final (platformId, rawTrackId) =
            _extractPlatformAndId(remainder, active.platformId);

        if (rawTrackId.startsWith('RD') ||
            rawTrackId.startsWith('VLRD') ||
            rawTrackId.startsWith('mix:')) {
          final cleanId = rawTrackId.startsWith('mix:')
              ? rawTrackId.substring(4)
              : (rawTrackId.startsWith('VL')
                  ? rawTrackId.substring(2)
                  : rawTrackId);
          await GetIt.I<AudioPlayerHandler>().playMix(
            cleanId,
            'Mix'.i18n,
            platformId: platformId,
          );
          return;
        }

        final trackId = rawTrackId.startsWith('radio:')
            ? rawTrackId.substring(6)
            : rawTrackId;

        final platform = PlatformManager.instance.getPlatform(platformId);
        final track = await platform.getTrack(trackId);
        await GetIt.I<AudioPlayerHandler>().playFromTrackList(
          [track],
          track.id ?? trackId,
          QueueSource(
            id: 'track_${platform.platformId}_$trackId',
            text: track.title,
            source: 'android_auto',
          ),
        );
        return;
      }

      // 7. Offline playlist playback
      if (id.startsWith('${prefix}offline_playlist_')) {
        if (downloadManager.db == null) await downloadManager.init();
        final remainder = id.replaceFirst('${prefix}offline_playlist_', '');
        final (platformId, playlistId) =
            _extractPlatformAndId(remainder, 'deezer');
        final p = await downloadManager.getOfflinePlaylist(
          playlistId,
          platformId: platformId,
        );
        if (p != null && p.tracks != null && p.tracks!.isNotEmpty) {
          final sort =
              Sorting.forPlaylist(playlistId, platformId: platformId);
          final sortedTracks = _applyUserSort(p.tracks!, sort);
          final sortedPlaylist = Playlist(
            id: p.id,
            title: p.title,
            description: p.description,
            tracks: sortedTracks,
            trackCount: p.trackCount,
            platformId: p.platformId,
            image: p.image,
            mosaicImages: p.mosaicImages,
          );
          await GetIt.I<AudioPlayerHandler>().playFromPlaylist(
            sortedPlaylist,
            sortedTracks[0].id ?? '',
            sort: sort,
            initialTrackLimit: sort != null &&
                    (sort.reverse || sort.type != SortType.DEFAULT)
                ? 100
                : null,
          );
        }
        return;
      }

      // 8. Play local playlists
      if (id.startsWith('${prefix}local_playlist_') ||
          id.startsWith('${prefix}playlist_local_')) {
        if (downloadManager.db == null) await downloadManager.init();
        final localId = id.startsWith('${prefix}local_playlist_')
            ? id.replaceFirst('${prefix}local_playlist_', '')
            : id.replaceFirst('${prefix}playlist_local_', '');
        final localPlaylist =
            await downloadManager.localPlaylistManager.getPlaylist(localId);
        if (localPlaylist != null && localPlaylist.trackIds.isNotEmpty) {
          final sort = Sorting.forPlaylist(localId, platformId: 'local');

          List<Track> tracks;
          if (sort != null &&
              (sort.reverse || sort.type != SortType.DEFAULT)) {
            final fullPlaylist =
                await downloadManager.getFullLocalPlaylist(localId);
            tracks = fullPlaylist?.tracks ?? [];
            tracks = _applyUserSort(tracks, sort);
          } else {
            // Fast start: fetch initial batch of 15 tracks so playback begins in < 300ms.
            // Subsequent tracks are fetched lazily on-the-fly by AudioPlayerHandler.
            tracks = await downloadManager.loadLocalPlaylistTracks(
              localPlaylist,
              limit: 15,
            );
          }

          if (tracks.isNotEmpty) {
            final playlist = Playlist(
              id: 'local_${localPlaylist.id}',
              title: localPlaylist.title,
              description: localPlaylist.description,
              tracks: tracks,
              trackCount: localPlaylist.trackIds.length,
              platformId: 'local',
              mosaicImages: localPlaylist.mosaicImages,
            );
            await GetIt.I<AudioPlayerHandler>().playFromPlaylist(
              playlist,
              tracks[0].id ?? '',
              sort: sort,
              initialTrackLimit: sort != null &&
                      (sort.reverse || sort.type != SortType.DEFAULT)
                  ? 100
                  : null,
            );
          }
        }
        return;
      }

      // 9. Play playlists
      if (id.startsWith('${prefix}playlist')) {
        String platformId = active.platformId;
        String playlistId;
        if (id.startsWith('${prefix}playlist_')) {
          final remainder = id.replaceFirst('${prefix}playlist_', '');
          final (pId, plId) =
              _extractPlatformAndId(remainder, active.platformId);
          platformId = pId;
          playlistId = plId;
        } else {
          playlistId = id.replaceFirst('${prefix}playlist', '');
        }

        if (playlistId.startsWith('RD') ||
            playlistId.startsWith('VLRD') ||
            playlistId.startsWith('mix:')) {
          final cleanId = playlistId.startsWith('mix:')
              ? playlistId.substring(4)
              : (playlistId.startsWith('VL')
                  ? playlistId.substring(2)
                  : playlistId);
          await GetIt.I<AudioPlayerHandler>().playMix(
            cleanId,
            'Mix'.i18n,
            platformId: platformId,
          );
          return;
        }

        if (platformId == 'local') {
          if (downloadManager.db == null) await downloadManager.init();
          final localPlaylist =
              await downloadManager.localPlaylistManager.getPlaylist(playlistId);
          if (localPlaylist != null && localPlaylist.trackIds.isNotEmpty) {
            final sort =
                Sorting.forPlaylist(playlistId, platformId: 'local');

            List<Track> tracks;
            if (sort != null &&
                (sort.reverse || sort.type != SortType.DEFAULT)) {
              final fullPlaylist =
                  await downloadManager.getFullLocalPlaylist(playlistId);
              tracks = fullPlaylist?.tracks ?? [];
              tracks = _applyUserSort(tracks, sort);
            } else {
              tracks = await downloadManager.loadLocalPlaylistTracks(
                localPlaylist,
                limit: 15,
              );
            }

            if (tracks.isNotEmpty) {
              final playlist = Playlist(
                id: 'local_${localPlaylist.id}',
                title: localPlaylist.title,
                description: localPlaylist.description,
                tracks: tracks,
                trackCount: localPlaylist.trackIds.length,
                platformId: 'local',
                mosaicImages: localPlaylist.mosaicImages,
              );
              await GetIt.I<AudioPlayerHandler>().playFromPlaylist(
                playlist,
                tracks[0].id ?? '',
                sort: sort,
                initialTrackLimit: sort != null &&
                        (sort.reverse || sort.type != SortType.DEFAULT)
                    ? 100
                    : null,
              );
            }
          }
          return;
        }

        final platform = PlatformManager.instance.getPlatform(platformId);
        Playlist? p;
        final sort = Sorting.forPlaylist(playlistId, platformId: platformId);
        final needsFullSort = sort != null &&
            (sort.reverse || sort.type != SortType.DEFAULT);
        try {
          p = needsFullSort
              ? await platform.getFullPlaylist(playlistId)
              : await platform.getPlaylist(playlistId, limit: 50);
        } catch (_) {}

        if (p != null && p.tracks != null && p.tracks!.isNotEmpty) {
          final sortedTracks = _applyUserSort(p.tracks!, sort);
          final sortedPlaylist = Playlist(
            id: p.id,
            title: p.title,
            description: p.description,
            tracks: sortedTracks,
            trackCount: p.trackCount,
            platformId: p.platformId,
            image: p.image,
            mosaicImages: p.mosaicImages,
          );
          await GetIt.I<AudioPlayerHandler>().playFromPlaylist(
            sortedPlaylist,
            sortedTracks[0].id ?? '',
            sort: sort,
            initialTrackLimit: needsFullSort ? 100 : null,
          );
          return;
        }

        // Fallback for Loved tracks or playlists loaded via favorite tracks
        try {
          final sort = _savedTracksSort();
          final sortedTracks = await _loadFavoritesForPlayback(platform);
          if (sortedTracks.isNotEmpty) {
            await GetIt.I<AudioPlayerHandler>().playFromTrackList(
              sortedTracks,
              sortedTracks[0].id ?? '',
              QueueSource(
                id: platform.favoritesQueueSource.id,
                text: platform.favoritesQueueSource.text,
                source: platform.favoritesQueueSource.source,
                sort: sort,
              ),
            );
          }
        } catch (_) {}
        return;
      }

      // 10. Play albums
      if (id.startsWith('${prefix}album')) {
        String platformId = active.platformId;
        String albumId;
        if (id.startsWith('${prefix}album_')) {
          final remainder = id.replaceFirst('${prefix}album_', '');
          final (pId, aId) =
              _extractPlatformAndId(remainder, active.platformId);
          platformId = pId;
          albumId = aId;
        } else {
          albumId = id.replaceFirst('${prefix}album', '');
        }

        final platform = PlatformManager.instance.getPlatform(platformId);
        final Album a = await platform.getAlbum(albumId);
        if (a.tracks != null && a.tracks!.isNotEmpty) {
          await GetIt.I<AudioPlayerHandler>().playFromAlbum(
            a,
            a.tracks![0].id ?? '',
          );
        }
        return;
      }

      // 11. Play smart track list
      if (id.startsWith('${prefix}stl')) {
        String platformId = active.platformId;
        String stlId;
        if (id.startsWith('${prefix}stl_')) {
          final remainder = id.replaceFirst('${prefix}stl_', '');
          final (pId, sId) =
              _extractPlatformAndId(remainder, active.platformId);
          platformId = pId;
          stlId = sId;
        } else {
          stlId = id.replaceFirst('${prefix}stl', '');
        }
        final platform = PlatformManager.instance.getPlatform(platformId);
        final SmartTrackList stl = await platform.getSmartTrackList(stlId);
        await GetIt.I<AudioPlayerHandler>().playFromSmartTrackList(stl);
        return;
      }

      // 12. Play podcast episode
      if (id.startsWith('${prefix}episode_')) {
        final remainder = id.replaceFirst('${prefix}episode_', '');
        final (platformId, rest) =
            _extractPlatformAndId(remainder, active.platformId);
        final separator = rest.indexOf('_');
        if (separator > 0) {
          final showId = rest.substring(0, separator);
          final episodeId = rest.substring(separator + 1);
          final platform = PlatformManager.instance.getPlatform(platformId);
          final page = await platform.getShowEpisodesPage(showId, limit: 20);
          final episodes = page.episodes;
          if (episodes.isNotEmpty) {
            final epIndex = episodes.indexWhere((e) => e.id == episodeId);
            final show = episodes.first.show ??
                Show(id: showId, name: 'Podcast', platformId: platformId);
            await GetIt.I<AudioPlayerHandler>().playShowEpisode(
              show,
              episodes,
              index: epIndex >= 0 ? epIndex : 0,
              loadMore: page.hasMore,
            );
          }
        }
        return;
      }
    } catch (e, stack) {
      if (kDebugMode) {
        appLogger.warning('Android Auto: item playback failed for $id: $e\n$stack');
      }
    }
  }

  Future<void> _handleSwitchPlatform(String platformId) async {
    final platform = PlatformRegistry.instance.get(platformId);
    if (platform == null) return;
    PlatformManager.instance.switchPlatform(platformId);
    settings.activePlatformId = platformId;
    unawaited(settings.save());

    final handler = GetIt.I<AudioPlayerHandler>();
    final screensToNotify = [
      'root',
      AudioService.browsableRootId,
      'platforms',
      'homescreen',
      'playlists',
      'radio',
      'albums',
      'artists',
      'shows',
      'explore',
      'offline',
      'offline_playlists',
    ];
    for (final s in screensToNotify) {
      handler.notifyChildrenChanged(s);
    }
    for (final p in PlatformRegistry.instance.allPlatforms) {
      handler.notifyChildrenChanged('platform_screen_${p.platformId}');
      handler.notifyChildrenChanged('homescreen_${p.platformId}');
      handler.notifyChildrenChanged('playlists_${p.platformId}');
      handler.notifyChildrenChanged('radio_${p.platformId}');
      handler.notifyChildrenChanged('albums_${p.platformId}');
      handler.notifyChildrenChanged('artists_${p.platformId}');
      handler.notifyChildrenChanged('shows_${p.platformId}');
      handler.notifyChildrenChanged('explore_${p.platformId}');
    }

    if (!handler.playbackState.value.playing) {
      if (platform.platformId == 'neurokaraoke' &&
          platform.capabilities.supportsRadio) {
        await handler.playRadio(
          id: kNeuroRadioStationId,
          title: kNeuroRadioStationName,
          description: 'Live radio',
          platformId: 'neurokaraoke',
        );
      } else if (platform.capabilities.supportsFlow) {
        try {
          final flowTracks = await platform.getFlow();
          if (flowTracks.isNotEmpty) {
            await handler.playFromTrackList(
              flowTracks,
              flowTracks[0].id ?? '',
              QueueSource(
                id: 'flow_${platform.platformId}',
                text: 'Radio'.i18n,
                source: 'flow',
              ),
            );
          }
        } catch (_) {}
      }
    }
  }

  // Homescreen items
  Future<List<MediaItem>> homeScreen() async {
    final activePlatform = PlatformManager.instance.isInitialized
        ? PlatformManager.instance.active
        : PlatformRegistry.instance.allPlatforms.first;

    final loggedIn = await _loggedInPlatforms();
    final showPlatformSwitcher = loggedIn.length > 1;

    // Check if the active platform defines custom root items for Android Auto
    final customRoot = await activePlatform.getAndroidAutoItems('root');
    if (customRoot != null && customRoot.isNotEmpty) {
      return [
        if (showPlatformSwitcher) _buildPlatformsMenuItem(activePlatform),
        ...customRoot,
      ];
    }

    final out = <MediaItem>[];

    // 1. Platforms Switcher entry
    if (showPlatformSwitcher) {
      out.add(_buildPlatformsMenuItem(activePlatform));
    }

    // 2. Flow / Radio (if supported)
    if (activePlatform.capabilities.supportsFlow) {
      out.add(
        MediaItem(
          id: '${prefix}flow',
          title: 'Radio'.i18n,
          album: 'Radio'.i18n,
          displayTitle: 'Radio'.i18n,
          displaySubtitle: activePlatform.platformName,
          playable: true,
        ),
      );
    }

    // 3. Live Radio (if supported)
    if (activePlatform.capabilities.supportsRadio) {
      out.add(
        MediaItem(
          id: 'radio',
          title: 'Live Radio'.i18n,
          album: 'Live Radio'.i18n,
          displayTitle: 'Live Radio'.i18n,
          displaySubtitle: activePlatform.platformName,
          playable: false,
          extras: gridItemExtras,
        ),
      );
    }

    // 4. Home (loads feed or getHomePage)
    out.add(
      MediaItem(
        id: 'homescreen',
        title: 'Home'.i18n,
        album: '',
        displayTitle: 'Home'.i18n,
        displaySubtitle: activePlatform.platformName,
        playable: false,
        extras: gridItemExtras,
      ),
    );

    // 5. Loved / Favorite tracks (if supported)
    if (activePlatform.capabilities.supportsLibrarySync) {
      out.add(
        MediaItem(
          id: '${prefix}tracks',
          title: 'Loved tracks'.i18n,
          album: '',
          displayTitle: 'Loved tracks'.i18n,
          displaySubtitle: activePlatform.platformName,
          playable: true,
          extras: listItemExtras,
        ),
      );
    }

    // 6. Playlists
    out.add(
      MediaItem(
        id: 'playlists',
        title: 'Playlists'.i18n,
        album: '',
        displayTitle: 'Playlists'.i18n,
        displaySubtitle: activePlatform.platformName,
        playable: false,
        extras: gridItemExtras,
      ),
    );

    // 7. Albums (if supported)
    if (activePlatform.capabilities.supportsAlbums) {
      out.add(
        MediaItem(
          id: 'albums',
          title: 'Albums'.i18n,
          album: '',
          displayTitle: 'Albums'.i18n,
          displaySubtitle: activePlatform.platformName,
          playable: false,
          extras: gridItemExtras,
        ),
      );
    }

    // 8. Artists (if supported)
    if (activePlatform.capabilities.supportsArtists) {
      out.add(
        MediaItem(
          id: 'artists',
          title: 'Artists'.i18n,
          album: '',
          displayTitle: 'Artists'.i18n,
          displaySubtitle: activePlatform.platformName,
          playable: false,
          extras: gridItemExtras,
        ),
      );
    }

    // 9. Podcasts / Shows (if supported)
    if (activePlatform.capabilities.supportsShows) {
      out.add(
        MediaItem(
          id: 'shows',
          title: 'Podcasts'.i18n,
          album: '',
          displayTitle: 'Podcasts'.i18n,
          displaySubtitle: activePlatform.platformName,
          playable: false,
          extras: gridItemExtras,
        ),
      );
    }

    // 10. Explore / Browse (if supported)
    if (activePlatform.capabilities.supportsExplorePage) {
      out.add(
        MediaItem(
          id: 'explore',
          title: 'Explore'.i18n,
          album: '',
          displayTitle: 'Explore'.i18n,
          displaySubtitle: activePlatform.platformName,
          playable: false,
          extras: gridItemExtras,
        ),
      );
    }

    return out;
  }
}
