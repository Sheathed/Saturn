import 'package:material_ui/material_ui.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:silky_scroll/silky_scroll.dart';
import 'package:saturn/ui/smooth_scroll_config.dart';
import '../../api/definitions.dart';
import '../../translations.i18n.dart';
import '../../ui/elements.dart';
import '../../ui/menu.dart';
import '../../ui/cached_image.dart';
import '../../ui/tiles.dart';
import 'deezer_api.dart';
import '../../utils/logging.dart';

enum QuickAccessTab {
  suggestions,
  byDeezer,
  playlists,
  flow,
  albums,
  artists,
  tracks,
  podcasts,
}

/// Bumped whenever a pin/unpin succeeds so open screens can refresh.
final ValueNotifier<int> deezerPinRevision = ValueNotifier<int>(0);

/// Quick access type string Deezer expects for a model object, or null if
/// the object can't be pinned.
String? deezerQuickAccessType(Object item) {
  if (item is Track) return 'TRACK';
  if (item is Album) return 'ALBUM';
  if (item is Artist) return 'ARTIST';
  if (item is Show) return 'PODCAST';
  if (item is SmartTrackList) return 'SMART_TRACKLIST';
  if (item is DeezerFlow) return 'FLOW_CONFIG';
  if (item is LiveRadio) return 'LIVESTREAM';
  if (item is Playlist) {
    final id = item.id ?? '';
    if (id.startsWith('local_') || id.startsWith('favorites_')) return null;
    return 'PLAYLIST';
  }
  return null;
}

String? _deezerQuickAccessId(Object item) {
  try {
    return (item as dynamic).id?.toString();
  } catch (_) {
    return null;
  }
}

/// Pins or unpins [id], showing a toast. Returns true if the call succeeded.
Future<bool> toggleDeezerQuickAccessPin(String id, String type) async {
  final api = deezerAPI;
  if (api.isItemPinned(id)) {
    final ok = await api.unpinQuickAccessItem(id, type);
    Fluttertoast.showToast(
      msg: ok
          ? 'Removed from quick access'.i18n
          : 'Failed to remove from quick access'.i18n,
      gravity: ToastGravity.BOTTOM,
    );
    if (ok) deezerPinRevision.value++;
    return ok;
  }
  final result = await api.pinQuickAccessItem(id, type);
  Fluttertoast.showToast(
    msg: switch (result) {
      PinResult.success => 'Added to quick access'.i18n,
      PinResult.limitExceeded => 'Quick access is full (maximum 8 items)'.i18n,
      PinResult.failed => 'Failed to add to quick access'.i18n,
    },
    gravity: ToastGravity.BOTTOM,
  );
  if (result == PinResult.success) deezerPinRevision.value++;
  return result == PinResult.success;
}

/// Menu entry that adds/removes [item] to/from Deezer quick access, or null
/// if the item isn't supported.
Widget? buildDeezerPinMenuOption(
  BuildContext context,
  Object item, {
  VoidCallback? onChanged,
}) {
  final type = deezerQuickAccessType(item);
  final id = _deezerQuickAccessId(item);
  if (type == null || id == null || id.isEmpty) return null;
  
  final pinned = deezerAPI.isItemPinned(id);
  if (!pinned && deezerAPI.pinnedItemCount >= 8) {
    return null;
  }
  
  return ListTile(
    leading: Icon(pinned ? Icons.push_pin_outlined : Icons.push_pin),
    title: Text(
      pinned ? 'Remove from quick access'.i18n : 'Add to quick access'.i18n,
    ),
    onTap: () async {
      Navigator.of(context).pop();
      if (await toggleDeezerQuickAccessPin(id, type)) onChanged?.call();
    },
  );
}

class DeezerQuickAccessCustomizationScreen extends StatefulWidget {
  final DeezerAPI api;

  DeezerQuickAccessCustomizationScreen({DeezerAPI? api, super.key})
    : api = api ?? deezerAPI;

  @override
  State<DeezerQuickAccessCustomizationScreen> createState() =>
      _DeezerQuickAccessCustomizationScreenState();
}

class _DeezerQuickAccessCustomizationScreenState
    extends State<DeezerQuickAccessCustomizationScreen> {
  QuickAccessTab _selectedTab = QuickAccessTab.suggestions;
  bool _loading = false;
  String? _error;
  List<HomePageItem> _items = [];

  final Map<QuickAccessTab, List<HomePageItem>> _cachedItems = {};
  final Map<QuickAccessTab, String?> _cursors = {};
  final Map<QuickAccessTab, bool> _hasMore = {};
  bool _loadingMore = false;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    deezerPinRevision.addListener(_onPinChanged);
    _loadTab(_selectedTab);
  }

  @override
  void dispose() {
    deezerPinRevision.removeListener(_onPinChanged);
    _scrollController.dispose();
    super.dispose();
  }

  void _onPinChanged() {
    if (mounted) setState(() {});
  }

  void _onScroll() {
    if (_scrollController.hasClients &&
        _scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 300) {
      _loadMore();
    }
  }

  Future<QuickAccessPage> _fetchPage(QuickAccessTab tab, String? cursor) async {
    final api = widget.api;
    switch (tab) {
      case QuickAccessTab.suggestions:
        return QuickAccessPage(items: await api.getQuickAccessSuggestions());
      case QuickAccessTab.byDeezer:
        return api.getQuickAccessByDeezer(cursor: cursor);
      case QuickAccessTab.playlists:
        return api.getQuickAccessPlaylists(cursor: cursor);
      case QuickAccessTab.flow:
        return api.getQuickAccessFlows(cursor: cursor);
      case QuickAccessTab.albums:
        return api.getQuickAccessAlbums(cursor: cursor);
      case QuickAccessTab.artists:
        return api.getQuickAccessArtists(cursor: cursor);
      case QuickAccessTab.tracks:
        return api.getQuickAccessTracks(cursor: cursor);
      case QuickAccessTab.podcasts:
        return api.getQuickAccessPodcasts(cursor: cursor);
    }
  }

  Future<void> _loadMore() async {
    final tab = _selectedTab;
    if (_loading || _loadingMore || _hasMore[tab] != true) return;
    setState(() => _loadingMore = true);
    try {
      final page = await _fetchPage(tab, _cursors[tab]);
      final list = _cachedItems[tab] ??= [];
      list.addAll(page.items);
      _cursors[tab] = page.endCursor;
      _hasMore[tab] = page.hasNextPage && page.endCursor != null;
    } catch (e) {
      _hasMore[tab] = false;
    }
    if (mounted) {
      setState(() {
        _loadingMore = false;
        if (_selectedTab == tab) _items = _cachedItems[tab] ?? [];
      });
    }
  }

  String _tabLabel(QuickAccessTab tab) {
    switch (tab) {
      case QuickAccessTab.suggestions:
        return 'Suggestions'.i18n;
      case QuickAccessTab.byDeezer:
        return 'By Deezer'.i18n;
      case QuickAccessTab.playlists:
        return 'Playlists'.i18n;
      case QuickAccessTab.flow:
        return 'Flow'.i18n;
      case QuickAccessTab.albums:
        return 'Albums'.i18n;
      case QuickAccessTab.artists:
        return 'Artists'.i18n;
      case QuickAccessTab.tracks:
        return 'Tracks'.i18n;
      case QuickAccessTab.podcasts:
        return 'Podcasts'.i18n;
    }
  }

  Future<void> _loadTab(QuickAccessTab tab) async {
    setState(() {
      _selectedTab = tab;
      _loading = true;
      _error = null;
    });

    if (_cachedItems.containsKey(tab)) {
      if (mounted) {
        setState(() {
          _items = _cachedItems[tab]!;
          _loading = false;
        });
      }
      return;
    }

    List<HomePageItem> results = [];
    try {
      final page = await _fetchPage(tab, null);
      results = List.of(page.items);
      _cursors[tab] = page.endCursor;
      _hasMore[tab] = page.hasNextPage && page.endCursor != null;
    } catch (e, st) {
      appLogger.warning('QuickAccessScreen: Error loading tab $tab', e, st);
      _error = e.toString();
    }

    _cachedItems[tab] = results;
    if (mounted) {
      setState(() {
        _items = results;
        _loading = false;
      });
    }
  }

  String _getItemType(HomePageItem item) {
    if (item.isPlatformItem('smarttracklist')) return 'SMART_TRACKLIST';
    if (item.isPlatformItem('flow')) return 'FLOW_CONFIG';
    switch (item.type) {
      case HomePageItemType.ALBUM:
        return 'ALBUM';
      case HomePageItemType.ARTIST:
        return 'ARTIST';
      case HomePageItemType.PLAYLIST:
        return 'PLAYLIST';
      case HomePageItemType.SHOW:
        return 'PODCAST';
      case HomePageItemType.TRACK:
        return 'TRACK';
      case HomePageItemType.RADIO:
        return 'LIVESTREAM';
      default:
        return 'TRACK';
    }
  }

  String? _getItemId(HomePageItem item) {
    return item.value?.id?.toString();
  }

  bool _isPinned(HomePageItem item) {
    final id = _getItemId(item);
    if (id == null) return false;
    return widget.api.isItemPinned(id);
  }

  Future<void> _togglePin(HomePageItem item) async {
    final id = _getItemId(item);
    if (id == null) return;
    final type = _getItemType(item);

    await toggleDeezerQuickAccessPin(id, type);
  }

  Widget _buildPinContextOption(HomePageItem item) {
    final isPinned = _isPinned(item);
    if (!isPinned && widget.api.pinnedItemCount >= 8) return const SizedBox.shrink();
    
    return ListTile(
      leading: Icon(isPinned ? Icons.push_pin_outlined : Icons.push_pin),
      title: Text(
        isPinned ? 'Remove from quick access'.i18n : 'Add to quick access'.i18n,
      ),
      onTap: () {
        Navigator.of(context).pop();
        _togglePin(item);
      },
    );
  }

  Widget _buildTile(HomePageItem item) {
    final isPinned = _isPinned(item);
    final trailing = (!isPinned && widget.api.pinnedItemCount >= 8)
        ? null
        : IconButton(
            icon: Icon(
              isPinned ? Icons.push_pin : Icons.push_pin_outlined,
              color: isPinned ? Theme.of(context).primaryColor : null,
            ),
            tooltip: isPinned
                ? 'Remove from quick access'.i18n
                : 'Add to quick access'.i18n,
            onPressed: () => _togglePin(item),
          );

    switch (item.type) {
      case HomePageItemType.TRACK:
        final Track t = item.value;
        return TrackTile(
          t,
          trailing: trailing,
          onTap: () => _togglePin(item),
          onHold: () => MenuSheet().defaultTrackMenu(t, context: context),
        );
      case HomePageItemType.ALBUM:
        final Album a = item.value;
        return AlbumTile(
          a,
          trailing: trailing,
          onTap: () => _togglePin(item),
          onHold: () => MenuSheet().defaultAlbumMenu(a, context: context),
        );
      case HomePageItemType.ARTIST:
        final Artist art = item.value;
        return ArtistHorizontalTile(
          art,
          trailing: trailing,
          onTap: () => _togglePin(item),
          onHold: () => MenuSheet().defaultArtistMenu(art, context: context),
        );
      case HomePageItemType.PLAYLIST:
        final Playlist p = item.value;
        return PlaylistTile(
          p,
          trailing: trailing,
          onTap: () => _togglePin(item),
          onHold: () => MenuSheet().defaultPlaylistMenu(p, context: context),
        );
      case HomePageItemType.SHOW:
        final Show s = item.value;
        return ListTile(
          leading: CachedImage(
            url: s.art?.thumb ?? '',
            width: 48,
            rounded: true,
          ),
          title: Text(
            s.name ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text('Podcast'.i18n),
          trailing: trailing,
          onTap: () => _togglePin(item),
          onLongPress: () => MenuSheet().defaultShowMenu(s, context: context),
        );
      case HomePageItemType.PLATFORM:
        if (item.isPlatformItem('smarttracklist')) {
          final SmartTrackList stl = item.value;
          return ListTile(
            leading:
                (stl.cover?.thumb != null && stl.cover!.thumb!.isNotEmpty)
                ? CachedImage(url: stl.cover!.thumb!, width: 48, rounded: true)
                : const Icon(Icons.queue_music, size: 48),
            title: Text(
              stl.title ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              (stl.subtitle?.isNotEmpty ?? false)
                  ? stl.subtitle!
                  : 'By Deezer'.i18n,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: trailing,
            onTap: () => _togglePin(item),
            onLongPress: () =>
                MenuSheet().show(context, [_buildPinContextOption(item)]),
          );
        }
        if (item.isPlatformItem('flow')) {
          final DeezerFlow flow = item.value;
          return ListTile(
            leading:
                (flow.cover?.thumb != null && flow.cover!.thumb!.isNotEmpty)
                ? CachedImage(url: flow.cover!.thumb!, width: 48, rounded: true)
                : const Icon(Icons.graphic_eq, size: 48),
            title: Text(
              flow.title ?? 'Flow'.i18n,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text('Flow'.i18n),
            trailing: trailing,
            onTap: () => _togglePin(item),
            onLongPress: () =>
                MenuSheet().show(context, [_buildPinContextOption(item)]),
          );
        }
        return const SizedBox.shrink();
      case HomePageItemType.RADIO:
        final LiveRadio r = item.value;
        return ListTile(
          leading: (r.imageUrl != null && r.imageUrl!.isNotEmpty)
              ? CachedImage(url: r.imageUrl!, width: 48, rounded: true)
              : const Icon(Icons.radio, size: 48),
          title: Text(
            r.title ?? 'Radio'.i18n,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            (r.description != null && r.description!.isNotEmpty)
                ? r.description!
                : 'Radio'.i18n,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: trailing,
          onTap: () => _togglePin(item),
          onLongPress: () =>
              MenuSheet().show(context, [_buildPinContextOption(item)]),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: FreezerAppBar('${'Customise quick access'.i18n} (${widget.api.pinnedItemCount}/8)'),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Filter tabs
          SizedBox(
            height: 52,
            child: SilkyListView.separated(
              silkyConfig: silkyHorizontalScrollConfig,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(
                horizontal: 16.0,
                vertical: 8.0,
              ),
              itemCount: QuickAccessTab.values.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final tab = QuickAccessTab.values[index];
                final isSelected = tab == _selectedTab;
                return ChoiceChip(
                  label: Text(_tabLabel(tab)),
                  selected: isSelected,
                  selectedColor: theme.primaryColor.withValues(alpha: 0.25),
                  backgroundColor: theme.cardColor.withValues(alpha: 0.5),
                  labelStyle: TextStyle(
                    color: isSelected
                        ? theme.primaryColorLight
                        : Colors.grey.shade400,
                    fontWeight: isSelected
                        ? FontWeight.bold
                        : FontWeight.normal,
                    fontSize: 14.0,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                    side: BorderSide(
                      color: isSelected
                          ? theme.primaryColor
                          : Colors.grey.withValues(alpha: 0.3),
                    ),
                  ),
                  showCheckmark: isSelected,
                  checkmarkColor: theme.primaryColorLight,
                  onSelected: (selected) {
                    if (selected && tab != _selectedTab) {
                      _loadTab(tab);
                    }
                  },
                );
              },
            ),
          ),
          const Divider(height: 1),
          // Items list
          Expanded(
            child: _loading
                ? Center(
                    child: CircularProgressIndicator(color: theme.primaryColor),
                  )
                : _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Text(
                        'Error: $_error',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ),
                  )
                : _items.isEmpty
                ? Center(
                    child: Text(
                      'No items found'.i18n,
                      style: theme.textTheme.bodyLarge,
                    ),
                  )
                : SilkyListView.builder(
                    silkyConfig: silkyScrollConfig,
                    controller: _scrollController,
                    itemCount: _items.length + 1,
                    itemBuilder: (context, index) {
                      if (index == _items.length) {
                        return _loadingMore
                            ? const Padding(
                                padding: EdgeInsets.all(16.0),
                                child: Center(
                                  child: CircularProgressIndicator(),
                                ),
                              )
                            : const SizedBox.shrink();
                      }
                      return _buildTile(_items[index]);
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
