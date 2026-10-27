import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:silky_scroll/silky_scroll.dart';
import 'package:saturn/ui/smooth_scroll_config.dart';

import '../platform/platform_manager.dart';
import '../platform/platform_registry.dart';
import '../api/definitions.dart';
import '../service/audio_service.dart';
import '../settings.dart';
import '../translations.i18n.dart';
import '../ui/elements.dart';
import '../ui/error.dart';
import '../ui/menu.dart';
import 'details_screens.dart';
import 'tiles.dart';
import '../utils/logging.dart';
import '../utils/app_config.dart';

void _openHomeSection(BuildContext context, String path, String? title) {
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: FreezerAppBar(title ?? ''),
        body: HomePageScreen(
          loadPage: () => PlatformManager.instance.active.getChannel(path),
        ),
      ),
    ),
  );
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const HomeAppBar(),
      body: PlatformManager.instance.active.getHomeWidget(context),
    );
  }
}

class HomeAppBar extends StatelessWidget implements PreferredSizeWidget {
  const HomeAppBar({super.key});

  @override
  Size get preferredSize => AppBar().preferredSize;

  @override
  Widget build(BuildContext context) {
    return FreezerAppBar(
      'Home'.i18n,
      actions: <Widget>[
        IconButton(
          icon: Icon(Icons.file_download, semanticLabel: 'Download'.i18n),
          onPressed: () {
            context.push('/downloads');
          },
        ),
        IconButton(
          icon: Icon(Icons.settings, semanticLabel: 'Settings'.i18n),
          onPressed: () {
            context.push('/settings');
          },
        ),
        const PlatformToggleIcon(),
      ],
    );
  }
}

class FreezerTitle extends StatelessWidget {
  const FreezerTitle({super.key});

  String _getBannerAsset() {
    switch (appBuildFlavor) {
      case 'canary':
        return 'assets/banner-canary.png';
      case 'dev':
        return 'assets/banner-dev.png';
      default:
        return 'assets/banner.png';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 24, 0, 8),
      child: Row(
        mainAxisSize: MainAxisSize.max,
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[Image.asset(_getBannerAsset(), height: 80)],
          ),
        ],
      ),
    );
  }
}

class HomePageScreen extends StatefulWidget {
  final HomePage? homePage;
  final Future<HomePage> Function()? loadPage;
  const HomePageScreen({this.homePage, this.loadPage, super.key});

  @override
  _HomePageScreenState createState() => _HomePageScreenState();
}

class _HomePageScreenState extends State<HomePageScreen> {
  HomePage? _homePage;
  bool _cancel = false;
  bool _error = false;

  void _loadChannel() async {
    if (widget.loadPage == null) return;

    HomePage? hp;
    //Fetch page from api
    try {
      final loadedPage = await widget.loadPage!();
      hp = loadedPage;
    } catch (e) {
      if (kDebugMode) {
        appLogger.fine('Home content loading failed', e);
      }
    }
    if (!mounted) return;
    if (hp == null) {
      //On error
      setState(() => _error = true);
      return;
    }
    setState(() => _homePage = hp);
  }

  void _loadHomePage() async {
    //Load local
    try {
      HomePage hp = await HomePage().load();
      setState(() => _homePage = hp);
    } catch (e) {
      if (kDebugMode) {
        appLogger.fine('Home content loading failed', e);
      }
    }
    //On background load from API
    try {
      if (settings.offlineMode) {
        await PlatformManager.instance.active.isLoggedIn();
      }
      HomePage hp = await PlatformManager.instance.active.getHomePage();
      if (_cancel) return;
      if (hp.sections.isEmpty) return;
      if (!mounted) return;
      setState(() => _homePage = hp);
      //Save to cache
      await _homePage?.save();
    } catch (e) {
      if (kDebugMode) {
        appLogger.fine('Home content loading failed', e);
      }
    }
  }

  final ScrollController _scrollController = ScrollController();
  bool _loadingMore = false;

  void _onScroll() {
    if (_homePage == null ||
        _loadingMore ||
        !_homePage!.hasMore ||
        _homePage!.loadMore == null ||
        !_scrollController.hasClients) {
      return;
    }
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 400) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _homePage?.loadMore == null) return;
    setState(() => _loadingMore = true);
    try {
      final newSections = await _homePage!.loadMore!();
      if (!mounted) return;
      if (newSections.isNotEmpty) {
        setState(() {
          _homePage!.sections.addAll(newSections);
        });
      }
    } catch (e) {
      if (kDebugMode) {
        appLogger.fine('Failed to load more home sections', e);
      }
    } finally {
      if (mounted) {
        setState(() => _loadingMore = false);
      }
    }
  }

  void _load() {
    if (widget.homePage != null) {
      setState(() => _homePage = widget.homePage);
    } else if (widget.loadPage != null) {
      _loadChannel();
    } else {
      _loadHomePage();
    }
  }

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _cancel = true;
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_homePage == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(8.0),
          child: CircularProgressIndicator(
            color: Theme.of(context).primaryColor,
          ),
        ),
      );
    }
    if (_error) return const ErrorScreen();
    final totalCount =
        _homePage!.sections.length + (_homePage!.hasMore ? 1 : 0);
    return SilkyListView.builder(
      silkyConfig: silkyScrollConfig,
      controller: _scrollController,
      itemCount: totalCount,
      itemBuilder: (context, index) {
        if (index >= _homePage!.sections.length) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 24.0),
              child: _loadingMore
                  ? CircularProgressIndicator(
                      color: Theme.of(context).primaryColor,
                    )
                  : const SizedBox.shrink(),
            ),
          );
        }
        final section = _homePage!.sections[index];
        final platformSection = PlatformManager.instance.active
            .buildPlatformHomeSection(context, section);
        if (platformSection != null) return platformSection;

        switch (section.layout) {
          case HomePageSectionLayout.QUICK_ACCESS:
          case HomePageSectionLayout.ROW:
            return HomepageRowSection(section);
          case HomePageSectionLayout.GRID:
            return HomePageGridSection(section);
          case HomePageSectionLayout.GRID_ROW:
            final hasOnlyTracks = section.items.every(
              (i) => i?.type == HomePageItemType.TRACK,
            );
            if (!hasOnlyTracks) {
              return HomepageRowSection(section);
            }
            return HomepageGridRowSection(section);
          default:
            return HomepageRowSection(section);
        }
      },
    );
  }
}

class HomepageRowSection extends StatefulWidget {
  final HomePageSection section;
  const HomepageRowSection(this.section, {super.key});

  @override
  State<HomepageRowSection> createState() => _HomepageRowSectionState();
}

class _HomepageRowSectionState extends State<HomepageRowSection> {
  final ScrollController _scrollController = ScrollController();
  List<HomePageItem>? _dynamicItems;
  Listenable? _quickAccessListenable;

  double _itemHeight(HomePageItem? item) {
    if (item == null) return 0;
    if (item.isPlatformItem('smarttracklist')) return 225;
    if (item.isPlatformItem('channel')) return 101;
    if (item.isPlatformItem('flow')) return 192;
    if (item.type == HomePageItemType.RADIO) return 200;
    if (item.type == HomePageItemType.EPISODE) return 192;
    return 192;
  }

  @override
  void initState() {
    super.initState();
    if (widget.section.layout == HomePageSectionLayout.QUICK_ACCESS) {
      _quickAccessListenable =
          PlatformManager.instance.active.homeQuickAccessListenable;
      _quickAccessListenable?.addListener(_onPinRevisionChanged);
    }
  }

  @override
  void dispose() {
    if (widget.section.layout == HomePageSectionLayout.QUICK_ACCESS) {
      _quickAccessListenable?.removeListener(_onPinRevisionChanged);
    }
    _scrollController.dispose();
    super.dispose();
  }

  void _onPinRevisionChanged() async {
    if (mounted) {
      try {
        final items = await PlatformManager.instance.active
            .getPinnedHomePageItems();
        if (mounted) {
          setState(() {
            _dynamicItems = items;
          });
        }
      } catch (_) {
        // Ignored
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _dynamicItems ?? widget.section.items;
    final rowHeight = items.fold<double>(
      0,
      (height, item) => math.max(height, _itemHeight(item)),
    );

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(
        horizontal: 4.0,
        vertical: 2.0,
      ),
      title: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 6.0),
        child: Row(
          children: [
            if (widget.section.image != null &&
                widget.section.image!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 12.0),
                child: ClipOval(
                  child: CachedNetworkImage(
                    imageUrl: widget.section.image!,
                    width: 48,
                    height: 48,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.section.image != null &&
                      widget.section.image!.isNotEmpty &&
                      widget.section.subtitle != null &&
                      widget.section.subtitle!.isNotEmpty)
                    Text(
                      widget.section.subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14.0,
                        color: Theme.of(context).textTheme.bodySmall?.color,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  Text(
                    widget.section.title ?? '',
                    textAlign: TextAlign.left,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 20.0,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  if ((widget.section.image == null ||
                          widget.section.image!.isEmpty) &&
                      widget.section.subtitle != null &&
                      widget.section.subtitle!.isNotEmpty)
                    Text(
                      widget.section.subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14.0,
                        color: Theme.of(context).textTheme.bodySmall?.color,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
            ),
            if (widget.section.hasMore == true &&
                widget.section.pagePath != null)
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                ),
                onPressed: () {
                  final path = widget.section.pagePath!;
                  final platform = PlatformManager.instance.active;
                  if (!platform.handleHomeSectionNavigation(
                    context,
                    path,
                    title: widget.section.title,
                  )) {
                    _openHomeSection(context, path, widget.section.title);
                  }
                },
                child: Text(
                  PlatformManager.instance.active.isPlayableHomeSectionPath(
                        widget.section.pagePath!,
                      )
                      ? 'Play all'.i18n
                      : 'View all'.i18n,
                ),
              ),
            if (PlatformManager.instance.active.supportsHomeQuickAccessEditor &&
                widget.section.layout == HomePageSectionLayout.QUICK_ACCESS &&
                items.length < 8)
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 20),
                tooltip: 'Customise quick access'.i18n,
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  PlatformManager.instance.active.openHomeQuickAccessEditor(
                    context,
                  );
                },
              ),
          ],
        ),
      ),
      subtitle:
          (PlatformManager.instance.active.supportsHomeQuickAccessEditor &&
              widget.section.layout == HomePageSectionLayout.QUICK_ACCESS &&
              items.isEmpty)
          ? Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 8.0,
                vertical: 8.0,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.add_circle_outline),
                  label: Text('Customise quick access'.i18n),
                  onPressed: () {
                    PlatformManager.instance.active.openHomeQuickAccessEditor(
                      context,
                    );
                  },
                ),
              ),
            )
          : SizedBox(
              // Fit the row to its tallest tile. Deezer channel tiles are
              // square and compact, while smart track lists need extra room
              // for their descriptions.
              height: rowHeight + 8,
              child: Scrollbar(
                controller: _scrollController,
                child: SilkyListView.builder(
                  silkyConfig: silkyHorizontalScrollConfig,
                  controller: _scrollController,
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.only(bottom: 8.0),
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    if (index >= items.length) return null;
                    return HomePageItemWidget(items[index] ?? HomePageItem());
                  },
                ),
              ),
            ),
    );
  }
}

class HomePageGridSection extends StatefulWidget {
  final HomePageSection section;
  const HomePageGridSection(this.section, {super.key});

  @override
  State<HomePageGridSection> createState() => _HomePageGridSectionState();
}

class _HomePageGridSectionState extends State<HomePageGridSection> {
  bool _loading = false;

  void _loadMore() async {
    if (widget.section.pagePath == null || _loading) return;
    setState(() => _loading = true);
    try {
      final newPage = await PlatformManager.instance.active.getChannel(
        widget.section.pagePath!,
      );
      if (newPage.sections.isNotEmpty) {
        final newSection = newPage.sections.first;
        widget.section.items.addAll(newSection.items);
        widget.section.hasMore = newSection.hasMore;
        widget.section.pagePath = newSection.pagePath;
      } else {
        widget.section.hasMore = false;
      }
    } catch (e) {
      if (kDebugMode) appLogger.fine('Home section pagination failed', e);
      widget.section.hasMore = false;
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(
        horizontal: 4.0,
        vertical: 2.0,
      ),
      title: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 6.0),
        child: Row(
          children: [
            if (widget.section.image != null &&
                widget.section.image!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 12.0),
                child: ClipOval(
                  child: CachedNetworkImage(
                    imageUrl: widget.section.image!,
                    width: 48,
                    height: 48,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.section.image != null &&
                      widget.section.image!.isNotEmpty &&
                      widget.section.subtitle != null &&
                      widget.section.subtitle!.isNotEmpty)
                    Text(
                      widget.section.subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14.0,
                        color: Theme.of(context).textTheme.bodySmall?.color,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  Text(
                    widget.section.title ?? '',
                    textAlign: TextAlign.left,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 20.0,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  if ((widget.section.image == null ||
                          widget.section.image!.isEmpty) &&
                      widget.section.subtitle != null &&
                      widget.section.subtitle!.isNotEmpty)
                    Text(
                      widget.section.subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14.0,
                        color: Theme.of(context).textTheme.bodySmall?.color,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
            ),
            if (widget.section.hasMore == true &&
                widget.section.pagePath != null)
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                ),
                onPressed: () {
                  final path = widget.section.pagePath!;
                  final platform = PlatformManager.instance.active;
                  if (!platform.handleHomeSectionNavigation(
                    context,
                    path,
                    title: widget.section.title,
                  )) {
                    _openHomeSection(context, path, widget.section.title);
                  }
                },
                child: Text(
                  PlatformManager.instance.active.isPlayableHomeSectionPath(
                        widget.section.pagePath!,
                      )
                      ? 'Play all'.i18n
                      : 'View all'.i18n,
                ),
              ),
          ],
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              const double horizontalPadding = 12.0; // 6.0 on each side
              final double availableWidth =
                  constraints.maxWidth - horizontalPadding;
              const double spacing = 12.0;

              // Keep 2 items on mobile portrait (< 600px) and scale them nicely to fill the screen
              int columns;
              if (availableWidth < 600) {
                columns = 2;
              } else if (availableWidth < 840) {
                columns = 3;
              } else if (availableWidth < 1100) {
                columns = 4;
              } else {
                columns = (availableWidth / 200).floor().clamp(4, 8);
              }

              final double itemWidth =
                  ((availableWidth - ((columns - 1) * spacing)) / columns)
                      .floorToDouble();

              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6.0),
                child: Wrap(
                  alignment: WrapAlignment.start,
                  spacing: spacing,
                  runSpacing: spacing,
                  children: List.generate(widget.section.items.length, (i) {
                    //Item
                    return HomePageItemWidget(
                      widget.section.items[i] ?? HomePageItem(),
                      width: itemWidth,
                    );
                  }),
                ),
              );
            },
          ),
          if (widget.section.hasMore ?? false)
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: VisibilityDetector(
                key: Key(
                  'grid-section-${widget.section.title ?? widget.section.hashCode}',
                ),
                onVisibilityChanged: (info) {
                  if (info.visibleFraction > 0.1 && !_loading) {
                    _loadMore();
                  }
                },
                child: const CircularProgressIndicator(),
              ),
            ),
        ],
      ),
    );
  }
}

class HomePageItemWidget extends StatelessWidget {
  final HomePageItem item;
  final double? width;
  const HomePageItemWidget(this.item, {super.key, this.width});

  @override
  Widget build(BuildContext context) {
    final activePlatformId = PlatformManager.instance.isInitialized
        ? PlatformManager.instance.activePlatformId
        : '';
    final platform = PlatformRegistry.instance.get(
      item.platformId ?? activePlatformId,
    );
    final platformItem = platform?.buildPlatformHomeItem(context, item);
    if (platformItem != null) {
      return width != null
          ? SizedBox(width: width, child: platformItem)
          : platformItem;
    }

    switch (item.type) {
      case HomePageItemType.RADIO:
        final LiveRadio radio = item.value;
        return LiveRadioTile(
          radio,
          width: width,
          onTap: () {
            if (PlatformRegistry.instance
                    .get(radio.platformId ?? '')
                    ?.handleHomeItemTap(context, item) ==
                true) {
              return;
            }
            if (radio.id != null) {
              GetIt.I<AudioPlayerHandler>().playRadio(
                id: radio.id!,
                title: radio.title ?? 'Radio'.i18n,
                description: radio.description,
                artUrl: radio.image?.full ?? radio.image?.thumb,
                platformId:
                    radio.platformId ??
                    PlatformManager.instance.activePlatformId,
              );
            }
          },
          onHold: () {
            final platform = PlatformRegistry.instance.get(
              radio.platformId ?? PlatformManager.instance.activePlatformId,
            );
            final opts =
                platform?.getExtraMenuOptions(context, item.value) ?? const [];
            if (opts.isNotEmpty) {
              MenuSheet().show(context, opts);
            }
          },
        );
      case HomePageItemType.PLATFORM:
        return const SizedBox.shrink();
      case HomePageItemType.ALBUM:
        return AlbumCard(
          item.value,
          width: width,
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (context) => AlbumDetails(item.value)),
            );
          },
          onHold: () {
            MenuSheet m = MenuSheet();
            m.defaultAlbumMenu(item.value, context: context);
          },
        );
      case HomePageItemType.ARTIST:
        return ArtistTile(
          item.value,
          width: width,
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) => ArtistDetails(item.value),
              ),
            );
          },
          onHold: () {
            MenuSheet m = MenuSheet();
            m.defaultArtistMenu(item.value, context: context);
          },
        );
      case HomePageItemType.PLAYLIST:
        return PlaylistCardTile(
          item.value,
          width: width,
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) => PlaylistDetails(item.value),
              ),
            );
          },
          onHold: () {
            MenuSheet m = MenuSheet();
            m.defaultPlaylistMenu(item.value, context: context);
          },
        );
      case HomePageItemType.SHOW:
        return ShowCard(
          item.value,
          width: width,
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (context) => ShowScreen(item.value)),
            );
          },
          onHold: () {
            MenuSheet().defaultShowMenu(item.value, context: context);
          },
        );
      case HomePageItemType.TRACK:
        return TrackCard(
          item.value,
          width: width,
          onTap: () async {
            final Track t = item.value;
            final platformId = t.platformId.isNotEmpty
                ? t.platformId
                : (item.platformId ??
                      PlatformManager.instance.activePlatformId);
            final platform = PlatformRegistry.instance.get(platformId);
            if (platform?.handleHomeItemTap(context, item) == true) {
              return;
            }
            Track fullTrack = t;
            if (t.id != null) {
              try {
                final platform =
                    PlatformRegistry.instance.get(t.platformId) ??
                    PlatformManager.instance.active;
                final fetchedTrack = await platform.getTrack(t.id!);
                final fetchedTitle = fetchedTrack.title?.trim() ?? '';
                if (fetchedTitle.isNotEmpty &&
                    !fetchedTitle.startsWith('YouTube Track ')) {
                  fullTrack = fetchedTrack;
                }
              } catch (_) {
                fullTrack = t;
              }
            }
            GetIt.I<AudioPlayerHandler>().playFromTrackList(
              [fullTrack],
              fullTrack.id ?? '',
              QueueSource(
                id: fullTrack.id,
                text: fullTrack.title,
                source: 'homepage',
              ),
            );
          },
          onHold: () {
            MenuSheet().defaultTrackMenu(item.value, context: context);
          },
        );
      case HomePageItemType.EPISODE:
        return ShowEpisodeCard(
          item.value,
          width: width,
          onTap: () {
            final ShowEpisode ep = item.value;
            final Show s = ep.show ?? Show(id: ep.id, name: ep.title);
            GetIt.I<AudioPlayerHandler>().playShowEpisode(s, [ep], index: 0);
          },
          onHold: () {
            final ShowEpisode ep = item.value;
            MenuSheet().defaultShowEpisodeMenu(
              ep.show ?? Show(),
              ep,
              context: context,
            );
          },
        );
      default:
        return const SizedBox(height: 0, width: 0);
    }
  }
}

class HomepageGridRowSection extends StatefulWidget {
  final HomePageSection section;
  const HomepageGridRowSection(this.section, {super.key});

  @override
  State<HomepageGridRowSection> createState() => _HomepageGridRowSectionState();
}

class _HomepageGridRowSectionState extends State<HomepageGridRowSection> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double screenWidth = constraints.maxWidth;

        int crossAxisCount;
        if (screenWidth > 1200) {
          crossAxisCount = 2; // Large screens: 2 rows (6 columns for 12 items)
        } else {
          crossAxisCount = 3; // Normal screens: 3 rows (4 columns for 12 items)
        }

        // A compact two-line row leaves enough room for the 48px cover while
        // removing the unused vertical space from the standard ListTile.
        const double itemHeight = 64.0;
        final double crossAxisSpacing = 0.0;
        final double mainAxisSpacing = 0.0;
        final double height =
            (crossAxisCount * itemHeight) +
            ((crossAxisCount - 1) * crossAxisSpacing);

        final double width;
        if (screenWidth > 1600) {
          width = (screenWidth - 32.0) / 5 - 1.0;
        } else if (screenWidth > 1200) {
          width = (screenWidth - 32.0) / 4 - 1.0;
        } else if (screenWidth > 900) {
          width = (screenWidth - 32.0) / 3 - 1.0;
        } else if (screenWidth > 600) {
          width = (screenWidth - 32.0) / 2 - 1.0;
        } else {
          width = math.max(300.0, screenWidth * 0.85);
        }

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
              child: Row(
                children: [
                  if (widget.section.image != null &&
                      widget.section.image!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(right: 12.0),
                      child: ClipOval(
                        child: CachedNetworkImage(
                          imageUrl: widget.section.image!,
                          width: 48,
                          height: 48,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (widget.section.image != null &&
                            widget.section.image!.isNotEmpty &&
                            widget.section.subtitle != null &&
                            widget.section.subtitle!.isNotEmpty)
                          Text(
                            widget.section.subtitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14.0,
                              color: Theme.of(
                                context,
                              ).textTheme.bodySmall?.color,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        Text(
                          widget.section.title ?? '',
                          textAlign: TextAlign.left,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 20.0,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        if ((widget.section.image == null ||
                                widget.section.image!.isEmpty) &&
                            widget.section.subtitle != null &&
                            widget.section.subtitle!.isNotEmpty)
                          Text(
                            widget.section.subtitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14.0,
                              color: Theme.of(
                                context,
                              ).textTheme.bodySmall?.color,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (widget.section.hasMore == true &&
                      widget.section.pagePath != null)
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                      ),
                      onPressed: () {
                        final path = widget.section.pagePath!;
                        final platform = PlatformManager.instance.active;
                        if (!platform.handleHomeSectionNavigation(
                          context,
                          path,
                          title: widget.section.title,
                        )) {
                          _openHomeSection(context, path, widget.section.title);
                        }
                      },
                      child: Text(
                        PlatformManager.instance.active
                                .isPlayableHomeSectionPath(
                                  widget.section.pagePath!,
                                )
                            ? 'Play all'.i18n
                            : 'View all'.i18n,
                      ),
                    ),
                ],
              ),
            ),
            SizedBox(
              height: height,
              child: Scrollbar(
                controller: _scrollController,
                child: SilkyGridView.builder(
                  silkyConfig: silkyHorizontalScrollConfig,
                  controller: _scrollController,
                  scrollDirection: Axis.horizontal,
                  // Keep the first column aligned with the section heading;
                  // the trailing inset still gives the carousel an edge gap.
                  padding: const EdgeInsets.only(left: 10.0, right: 16.0),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: crossAxisCount,
                    mainAxisExtent: width,
                    crossAxisSpacing: crossAxisSpacing,
                    mainAxisSpacing: mainAxisSpacing,
                  ),
                  itemCount: widget.section.items.length,
                  itemBuilder: (context, i) {
                    final item = widget.section.items[i];
                    if (item == null) return const SizedBox();

                    if (item.type == HomePageItemType.TRACK) {
                      final t = item.value as Track;
                      return Center(
                        child: TrackTile(
                          t,
                          hideDuration: true,
                          hidePlatformBadge: true,
                          minTileHeight: itemHeight,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 8.0,
                          ),
                          onTap: () async {
                            if (PlatformRegistry.instance
                                    .get(t.platformId)
                                    ?.handleHomeItemTap(context, item) ==
                                true) {
                              return;
                            }
                            Track fullTrack = t;
                            if (t.id != null) {
                              try {
                                final platform =
                                    PlatformRegistry.instance.get(
                                      t.platformId,
                                    ) ??
                                    PlatformManager.instance.active;
                                fullTrack = await platform.getTrack(t.id!);
                              } catch (_) {
                                fullTrack = t;
                              }
                            }
                            GetIt.I<AudioPlayerHandler>().playFromTrackList(
                              [fullTrack],
                              fullTrack.id ?? '',
                              QueueSource(
                                id: fullTrack.id,
                                text: fullTrack.title,
                                source: 'homepage',
                              ),
                            );
                          },
                          onHold: () {
                            MenuSheet().defaultTrackMenu(t, context: context);
                          },
                        ),
                      );
                    }

                    return HomePageItemWidget(item);
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
