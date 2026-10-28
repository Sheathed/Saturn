import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:silky_scroll/silky_scroll.dart';
import 'package:saturn/ui/smooth_scroll_config.dart';

import '../api/cache.dart';
import 'music_link_navigation.dart';
import '../platform/platform_manager.dart';
import '../api/definitions.dart';
import '../api/download.dart';
import '../service/audio_service.dart';
import '../translations.i18n.dart';
import '../ui/details_screens.dart';
import '../ui/elements.dart';
import '../ui/menu.dart';
import './error.dart';
import './tiles.dart';
import '../utils/logging.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  _SearchScreenState createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  String? _query;
  bool _offline = false;
  bool _loading = false;
  final TextEditingController _controller = TextEditingController();
  final FocusNode _keyboardListenerFocusNode = FocusNode();
  final FocusNode _textFieldFocusNode = FocusNode();
  List _suggestions = [];
  bool _cancel = false;
  bool _showCards = true;

  void _submit(BuildContext context, {String? query}) async {
    if (query != null) {
      _query = query;
    }

    //URL
    final submittedUrl = _query?.trim();
    if (submittedUrl != null &&
        RegExp(r'^https?://', caseSensitive: false).hasMatch(submittedUrl)) {
      setState(() => _loading = true);
      try {
        await openScreenByURL(submittedUrl);
      } catch (e) {
        if (kDebugMode) {
          appLogger.fine('Search result handling failed', e);
        }
      }
      setState(() => _loading = false);
      return;
    }

    context.push(
      '/search/results?q=${Uri.encodeComponent(_query ?? '')}&offline=$_offline',
    );
  }

  @override
  void initState() {
    _cancel = false;
    //Check for connectivity and enable offline mode
    Connectivity().checkConnectivity().then((res) {
      if (res.isEmpty || res.contains(ConnectivityResult.none)) {
        setState(() {
          _offline = true;
        });
      }
    });

    super.initState();
  }

  //Load search suggestions
  Future<List?> _loadSuggestions() async {
    if (_query == null || _query!.length < 2 || _query!.startsWith('http')) {
      return null;
    }
    String q = _query!;
    await Future.delayed(const Duration(milliseconds: 300));
    if (q != _query) return null;
    //Load
    late List sugg;
    try {
      sugg = await PlatformManager.instance.active.searchSuggestions(_query!);
    } catch (e) {
      if (kDebugMode) {
        appLogger.fine('Search result handling failed', e);
      }
    }

    if (!_cancel) setState(() => _suggestions = sugg);
    return sugg;
  }

  Widget _removeHistoryItemWidget(int index) {
    return IconButton(
      icon: Icon(Icons.close, semanticLabel: 'Remove'.i18n),
      onPressed: () async {
        cache.searchHistory?.removeAt(index);
        setState(() {});
        await cache.save();
      },
    );
  }

  Widget _historyTrailing(int index) {
    return _removeHistoryItemWidget(index);
  }

  @override
  void dispose() {
    _cancel = true;
    _textFieldFocusNode.dispose();
    _keyboardListenerFocusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: FreezerAppBar(
        'Search'.i18n,
        actions: <Widget>[
          IconButton(
            icon: Icon(Icons.file_download, semanticLabel: 'Download'.i18n),
            onPressed: () {
              context.push('/downloads');
            },
          ),
          IconButton(
          icon: const UpdateAwareSettingsIcon(),
            onPressed: () {
              context.push('/settings');
            },
          ),
          const PlatformToggleIcon(),
        ],
      ),
      body: FocusScope(
        child: SilkyListView(
          silkyConfig: silkyScrollConfig,
          children: <Widget>[
            Container(height: 4.0),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Stack(
                      alignment: const Alignment(1.0, 0.0),
                      children: [
                        KeyboardListener(
                          focusNode: _keyboardListenerFocusNode,
                          onKeyEvent: (event) {
                            // For Android TV: quit search textfield
                            if (event is KeyUpEvent) {
                              if (event.logicalKey ==
                                  LogicalKeyboardKey.arrowDown) {
                                _textFieldFocusNode.unfocus();
                              }
                            }
                          },
                          child: TextField(
                            cursorColor: Theme.of(context).primaryColor,
                            onChanged: (String s) {
                              setState(() {
                                _showCards = false;
                                _query = s;
                              });
                              _loadSuggestions();
                            },
                            onTap: () {
                              setState(() => _showCards = false);
                            },
                            focusNode: _textFieldFocusNode,
                            decoration: InputDecoration(
                              labelText: 'Search or paste URL'.i18n,
                              fillColor: Theme.of(
                                context,
                              ).bottomAppBarTheme.color,
                              filled: true,
                              focusedBorder: const OutlineInputBorder(
                                borderSide: BorderSide(color: Colors.grey),
                              ),
                              enabledBorder: const OutlineInputBorder(
                                borderSide: BorderSide(color: Colors.grey),
                              ),
                              floatingLabelStyle: TextStyle(
                                color: Theme.of(context).primaryColor,
                              ),
                            ),
                            controller: _controller,
                            textInputAction: TextInputAction.search,
                            onSubmitted: (String s) {
                              _submit(context, query: s);
                              _textFieldFocusNode.unfocus();
                            },
                          ),
                        ),
                        Focus(
                          canRequestFocus:
                              false, // Focus is moving to cross, and hangs out there,
                          descendantsAreFocusable:
                              false, // so we disable focusing on it at all
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 40.0,
                                child: IconButton(
                                  splashRadius: 20.0,
                                  icon: Icon(
                                    Icons.clear,
                                    semanticLabel: 'Clear'.i18n,
                                  ),
                                  onPressed: () {
                                    setState(() {
                                      _suggestions = [];
                                      _query = '';
                                    });
                                    _controller.clear();
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Container(height: 8.0),
            ListTile(
              title: Text('Offline search'.i18n),
              leading: const Icon(Icons.offline_pin),
              trailing: Switch(
                value: _offline,
                onChanged: (v) {
                  setState(() => _offline = !_offline);
                },
              ),
            ),
            if (_loading)
              LinearProgressIndicator(
                color: Theme.of(context).primaryColor,
                backgroundColor: Theme.of(context).dividerColor,
              ),
            const FreezerDivider(),

            //"Browse" Cards
            if (_showCards) ...[
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
                child: Text(
                  'Quick access',
                  style: TextStyle(fontSize: 20.0, fontWeight: FontWeight.bold),
                ),
              ),
              Builder(
                builder: (context) {
                  final active = PlatformManager.instance.active;
                  final quickItems = active.searchQuickAccessItems;

                  final browseCard = SearchBrowseCard(
                    color: const Color(0xff2c4ea7),
                    text: 'Browse'.i18n,
                    icon: Image.asset('assets/browse_icon.png', width: 26.0),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) => Scaffold(
                          appBar: FreezerAppBar('Browse'.i18n),
                          body: PlatformManager.instance.active
                              .getExploreWidget(context),
                        ),
                      ),
                    ),
                  );

                  final allCards = [
                    ...quickItems.map(
                      (item) => SearchBrowseCard(
                        color: item.color,
                        text: item.title,
                        icon: item.icon,
                        onTap: () => item.onTap(context),
                      ),
                    ),
                    browseCard,
                  ];

                  final rows = <Widget>[];
                  for (int i = 0; i < allCards.length; i += 2) {
                    rows.add(
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          allCards[i],
                          if (i + 1 < allCards.length)
                            allCards[i + 1]
                          else
                            SizedBox(
                              width: MediaQuery.of(context).size.width / 2 - 32,
                            ),
                        ],
                      ),
                    );
                    if (i + 2 < allCards.length) {
                      rows.add(Container(height: 4.0));
                    }
                  }

                  return Column(children: rows);
                },
              ),
            ],

            //History
            if (!_showCards &&
                (cache.searchHistory?.length ?? 0) > 0 &&
                (_query ?? '').length < 2)
              ...List.generate(
                cache.searchHistory!.length > 10
                    ? 10
                    : cache.searchHistory!.length,
                (int i) {
                  final actualIndex = cache.searchHistory!.length - 1 - i;
                  dynamic data = cache.searchHistory![actualIndex].data;
                  switch (cache.searchHistory![actualIndex].type) {
                    case SearchHistoryItemType.TRACK:
                      return TrackTile(
                        data,
                        showPlatformBadge: true,
                        onTap: () {
                          List<Track> queue = cache.searchHistory!
                              .where(
                                (h) => h.type == SearchHistoryItemType.TRACK,
                              )
                              .map<Track>((t) => t.data)
                              .toList();
                          GetIt.I<AudioPlayerHandler>().playFromTrackList(
                            queue,
                            data.id,
                            QueueSource(
                              text: 'Search history'.i18n,
                              source: 'searchhistory',
                              id: 'searchhistory',
                            ),
                          );
                        },
                        onHold: () {
                          MenuSheet m = MenuSheet();
                          m.defaultTrackMenu(data, context: context);
                        },
                        trailing: _historyTrailing(actualIndex),
                      );
                    case SearchHistoryItemType.ALBUM:
                      return AlbumTile(
                        data,
                        showPlatformBadge: true,
                        onTap: () {
                          context.push('/album/${data.id}', extra: data);
                        },
                        onHold: () {
                          MenuSheet m = MenuSheet();
                          m.defaultAlbumMenu(data, context: context);
                        },
                        trailing: _historyTrailing(actualIndex),
                      );
                    case SearchHistoryItemType.ARTIST:
                      return ArtistHorizontalTile(
                        data,
                        showPlatformBadge: true,
                        onTap: () {
                          context.push('/artist/${data.id}', extra: data);
                        },
                        onHold: () {
                          MenuSheet m = MenuSheet();
                          m.defaultArtistMenu(data, context: context);
                        },
                        trailing: _historyTrailing(actualIndex),
                      );
                    case SearchHistoryItemType.PLAYLIST:
                      return PlaylistTile(
                        data,
                        showPlatformBadge: true,
                        onTap: () {
                          context.push('/playlist/${data.id}', extra: data);
                        },
                        onHold: () {
                          MenuSheet m = MenuSheet();
                          m.defaultPlaylistMenu(data, context: context);
                        },
                        trailing: _historyTrailing(actualIndex),
                      );
                    case SearchHistoryItemType.RADIO:
                      return LiveRadioListTile(
                        data,
                        showPlatformBadge: true,
                        onTap: () async {
                          await GetIt.I<AudioPlayerHandler>().playRadio(
                            id: data.id!,
                            title: data.title ?? '',
                            description: data.description,
                            artUrl: data.image?.full ?? data.image?.thumb,
                          );
                        },
                        trailing: _historyTrailing(actualIndex),
                      );
                  }
                },
              ),

            //Clear history
            if (cache.searchHistory != null && cache.searchHistory!.length > 2)
              ListTile(
                title: Text('Clear search history'.i18n),
                leading: const Icon(Icons.clear_all),
                onTap: () {
                  cache.searchHistory = [];
                  cache.save();
                  setState(() {});
                },
              ),

            //Suggestions
            ...List.generate(
              _suggestions.length,
              (i) => ListTile(
                title: Text(_suggestions[i]),
                leading: const Icon(Icons.search),
                onTap: () {
                  setState(() => _query = _suggestions[i]);
                  _submit(context);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SearchBrowseCard extends StatelessWidget {
  final Color color;
  final Widget? icon;
  final VoidCallback onTap;
  final String text;
  const SearchBrowseCard({
    super.key,
    required this.color,
    required this.onTap,
    required this.text,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      color: color,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: MediaQuery.of(context).size.width / 2 - 32,
          height: 75,
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ?icon,
                if (icon != null) Container(width: 8.0),
                Text(
                  text,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 18.0,
                    fontWeight: FontWeight.bold,
                    color: (color.computeLuminance() > 0.5)
                        ? Colors.black
                        : Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HorizontalScrollableSection extends StatefulWidget {
  final List<Widget> children;
  static const double rowHeight = 206.0;

  const _HorizontalScrollableSection({
    required this.children,
  });

  @override
  State<_HorizontalScrollableSection> createState() =>
      _HorizontalScrollableSectionState();
}

class _HorizontalScrollableSectionState
    extends State<_HorizontalScrollableSection> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _HorizontalScrollableSection.rowHeight,
      child: ScrollConfiguration(
        behavior: const MaterialScrollBehavior().copyWith(
          dragDevices: {
            PointerDeviceKind.touch,
            PointerDeviceKind.mouse,
            PointerDeviceKind.stylus,
            PointerDeviceKind.trackpad,
          },
        ),
        child: Scrollbar(
          controller: _scrollController,
          thumbVisibility: kIsWeb ||
              defaultTargetPlatform == TargetPlatform.windows ||
              defaultTargetPlatform == TargetPlatform.linux ||
              defaultTargetPlatform == TargetPlatform.macOS,
          child: SilkySingleChildScrollView(
            silkyConfig: silkyHorizontalScrollConfig,
            controller: _scrollController,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.only(bottom: 10.0, left: 8.0, right: 8.0),
            physics: const AlwaysScrollableScrollPhysics(),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: widget.children,
            ),
          ),
        ),
      ),
    );
  }
}

class SearchResultsScreen extends StatelessWidget {
  final String query;
  final bool? offline;

  const SearchResultsScreen(this.query, {super.key, this.offline});

  Future _search() async {
    if (offline ?? false) {
      return await downloadManager.search(query);
    }
    return await PlatformManager.instance.active.search(query);
  }

  List<Widget> _buildSection<T>({
    required BuildContext context,
    required String title,
    required List<T>? items,
    required Widget Function(T) builder,
    VoidCallback? onShowAll,
    bool horizontal = false,
  }) {
    if (items == null || items.isEmpty) return [];

    List<Widget> content;
    if (horizontal) {
      content = [
        _HorizontalScrollableSection(
          children: items.map((item) => builder(item)).toList(),
        ),
      ];
    } else {
      content = [
        ...items.take(3).map((item) => builder(item)),
        if (onShowAll != null && items.length > 3)
          ListTile(
            title: Text('Show all ${title.toLowerCase()}'.i18n),
            onTap: onShowAll,
          ),
      ];
    }

    return [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
        child: Text(
          title.i18n,
          textAlign: TextAlign.left,
          style: const TextStyle(fontSize: 20.0, fontWeight: FontWeight.bold),
        ),
      ),
      if (horizontal) Container(height: 4.0),
      ...content,
      const FreezerDivider(),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: FreezerAppBar('Search Results'.i18n),
      body: FutureBuilder(
        future: _search(),
        builder: (BuildContext context, AsyncSnapshot snapshot) {
          if (!snapshot.hasData) {
            return Center(
              child: CircularProgressIndicator(
                color: Theme.of(context).primaryColor,
              ),
            );
          }
          if (snapshot.hasError) return const ErrorScreen();

          SearchResults results = snapshot.data;

          if (results.empty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Icon(Icons.warning, size: 64),
                  Text('No results!'.i18n),
                ],
              ),
            );
          }

          return SilkyListView(
            silkyConfig: silkyScrollConfig,
            children: <Widget>[
              Container(height: 8.0),
              ..._buildSection<Track>(
                context: context,
                title: 'Tracks',
                items: results.tracks,
                builder: (t) => TrackTile(
                  t,
                  onTap: () {
                    cache.addToSearchHistory(t);
                    GetIt.I<AudioPlayerHandler>().playFromTrackList(
                      results.tracks!,
                      t.id ?? '',
                      QueueSource(
                        text: 'Search'.i18n,
                        id: query,
                        source: 'search_page',
                      ),
                    );
                  },
                  onHold: () {
                    MenuSheet m = MenuSheet();
                    m.defaultTrackMenu(t, context: context);
                  },
                ),
                onShowAll: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => TrackListScreen(
                        results.tracks!,
                        QueueSource(
                          id: query,
                          source: 'search_page',
                          text: 'Search'.i18n,
                        ),
                      ),
                    ),
                  );
                },
              ),
              ..._buildSection<Album>(
                context: context,
                title: 'Albums',
                items: results.albums,
                builder: (a) => AlbumTile(
                  a,
                  onTap: () {
                    cache.addToSearchHistory(a);
                    context.push('/album/${a.id}', extra: a);
                  },
                  onHold: () {
                    MenuSheet m = MenuSheet();
                    m.defaultAlbumMenu(a, context: context);
                  },
                ),
                onShowAll: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => AlbumListScreen(results.albums!),
                    ),
                  );
                },
              ),
              ..._buildSection<Artist>(
                context: context,
                title: 'Artists',
                horizontal: true,
                items: results.artists,
                builder: (a) => ArtistTile(
                  a,
                  onTap: () {
                    cache.addToSearchHistory(a);
                    context.push('/artist/${a.id}', extra: a);
                  },
                  onHold: () {
                    MenuSheet m = MenuSheet();
                    m.defaultArtistMenu(a, context: context);
                  },
                ),
              ),
              ..._buildSection<Playlist>(
                context: context,
                title: 'Setlists',
                items: results.setlists,
                builder: (p) => PlaylistTile(
                  p,
                  onTap: () {
                    cache.addToSearchHistory(p);
                    context.push('/playlist/${p.id}', extra: p);
                  },
                  onHold: () {
                    MenuSheet m = MenuSheet();
                    m.defaultPlaylistMenu(p, context: context);
                  },
                ),
                onShowAll: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) =>
                          SearchResultPlaylists(results.setlists!),
                    ),
                  );
                },
              ),
              ..._buildSection<Playlist>(
                context: context,
                title: 'Playlists',
                items: results.playlists,
                builder: (p) => PlaylistTile(
                  p,
                  onTap: () {
                    cache.addToSearchHistory(p);
                    context.push('/playlist/${p.id}', extra: p);
                  },
                  onHold: () {
                    MenuSheet m = MenuSheet();
                    m.defaultPlaylistMenu(p, context: context);
                  },
                ),
                onShowAll: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) =>
                          SearchResultPlaylists(results.playlists!),
                    ),
                  );
                },
              ),
              ..._buildSection<Show>(
                context: context,
                title: 'Shows',
                items: results.shows,
                builder: (s) => ShowTile(
                  s,
                  onTap: () async {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (context) => ShowScreen(s)),
                    );
                  },
                  onHold: () {
                    MenuSheet().defaultShowMenu(s, context: context);
                  },
                  trailing: IconButton(
                    icon: const Icon(Icons.more_vert),
                    onPressed: () {
                      MenuSheet().defaultShowMenu(s, context: context);
                    },
                  ),
                ),
                onShowAll: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => ShowListScreen(results.shows!),
                    ),
                  );
                },
              ),
              ..._buildSection<ShowEpisode>(
                context: context,
                title: 'Episodes',
                items: results.episodes,
                builder: (e) => ShowEpisodeTile(
                  e,
                  trailing: IconButton(
                    icon: Icon(Icons.more_vert, semanticLabel: 'Options'.i18n),
                    onPressed: () {
                      MenuSheet m = MenuSheet();
                      m.defaultShowEpisodeMenu(e.show!, e, context: context);
                    },
                  ),
                  onTap: () async {
                    final show =
                        e.show ??
                        Show(
                          id: null,
                          name: 'Podcast',
                          platformId:
                              PlatformManager.instance.active.platformId,
                        );
                    if (show.id == null || show.id!.isEmpty) {
                      await GetIt.I<AudioPlayerHandler>().playShowEpisode(
                        show,
                        [e],
                      );
                      return;
                    }
                    final pId = show.platformId;
                    final episodes = await PlatformManager.instance
                        .getPlatform(pId)
                        .getShowEpisodes(show.id!);
                    final episodeIndex = episodes.indexWhere(
                      (episode) => episode.id == e.id,
                    );
                    if (episodeIndex < 0) {
                      await GetIt.I<AudioPlayerHandler>().playShowEpisode(
                        show,
                        [e],
                      );
                      return;
                    }
                    await GetIt.I<AudioPlayerHandler>().playShowEpisode(
                      show,
                      episodes,
                      index: episodeIndex,
                    );
                  },
                ),
                onShowAll: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) =>
                          EpisodeListScreen(results.episodes!),
                    ),
                  );
                },
              ),
              ..._buildSection<LiveRadio>(
                context: context,
                title: 'Live Radios',
                items: results.radios,
                builder: (r) => LiveRadioListTile(
                  r,
                  onTap: () async {
                    cache.addToSearchHistory(r);
                    await GetIt.I<AudioPlayerHandler>().playRadio(
                      id: r.id!,
                      title: r.title ?? '',
                      description: r.description,
                      artUrl: r.image?.full ?? r.image?.thumb,
                    );
                  },
                ),
                onShowAll: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => RadioListScreen(results.radios!),
                    ),
                  );
                },
              ),
            ],
          );
        },
      ),
    );
  }
}

//List all tracks
class TrackListScreen extends StatefulWidget {
  final QueueSource queueSource;
  final List<Track> tracks;
  final Future<List<Track>> Function()? loadTracks;

  const TrackListScreen(
    this.tracks,
    this.queueSource, {
    this.loadTracks,
    super.key,
  });

  @override
  _TrackListScreenState createState() => _TrackListScreenState();
}

class _TrackListScreenState extends State<TrackListScreen> {
  late List<Track> _tracks;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _tracks = List.from(widget.tracks);
    if (widget.loadTracks != null) {
      _loadMore();
    }
  }

  void _loadMore() async {
    setState(() => _loading = true);
    try {
      final more = await widget.loadTracks!();
      setState(() {
        _tracks = more;
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: FreezerAppBar('Tracks'.i18n),
      body: _loading && _tracks.isEmpty
          ? Center(
              child: CircularProgressIndicator(
                color: Theme.of(context).primaryColor,
              ),
            )
          : SilkyListView.builder(
              silkyConfig: silkyScrollConfig,
              itemCount: _tracks.length + (_loading ? 1 : 0),
              itemBuilder: (BuildContext context, int i) {
                if (i == _tracks.length) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8.0),
                    child: Center(
                      child: CircularProgressIndicator(
                        color: Theme.of(context).primaryColor,
                      ),
                    ),
                  );
                }
                Track t = _tracks[i];
                return TrackTile(
                  t,
                  onTap: () {
                    GetIt.I<AudioPlayerHandler>().playFromTrackList(
                      _tracks,
                      t.id ?? '',
                      widget.queueSource,
                    );
                  },
                  onHold: () {
                    MenuSheet m = MenuSheet();
                    m.defaultTrackMenu(t, context: context);
                  },
                );
              },
            ),
    );
  }
}

//List all albums
class AlbumListScreen extends StatelessWidget {
  final List<Album> albums;
  const AlbumListScreen(this.albums, {super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: FreezerAppBar('Albums'.i18n),
      body: SilkyListView.builder(
        silkyConfig: silkyScrollConfig,
        itemCount: albums.length,
        itemBuilder: (context, i) {
          Album a = albums[i];
          return AlbumTile(
            a,
            onTap: () {
              Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (context) => AlbumDetails(a)));
            },
            onHold: () {
              MenuSheet m = MenuSheet();
              m.defaultAlbumMenu(a, context: context);
            },
          );
        },
      ),
    );
  }
}

class SearchResultPlaylists extends StatelessWidget {
  final List<Playlist> playlists;
  const SearchResultPlaylists(this.playlists, {super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: FreezerAppBar('Playlists'.i18n),
      body: SilkyListView.builder(
        silkyConfig: silkyScrollConfig,
        itemCount: playlists.length,
        itemBuilder: (context, i) {
          Playlist p = playlists[i];
          return PlaylistTile(
            p,
            onTap: () {
              context.push('/playlist/${p.id}', extra: p);
            },
            onHold: () {
              MenuSheet m = MenuSheet();
              m.defaultPlaylistMenu(p, context: context);
            },
          );
        },
      ),
    );
  }
}

class ShowListScreen extends StatelessWidget {
  final List<Show> shows;
  const ShowListScreen(this.shows, {super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: FreezerAppBar('Shows'.i18n),
      body: SilkyListView.builder(
        silkyConfig: silkyScrollConfig,
        itemCount: shows.length,
        itemBuilder: (context, i) {
          Show s = shows[i];
          return ShowTile(
            s,
            onTap: () {
              Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (context) => ShowScreen(s)));
            },
            onHold: () {
              MenuSheet().defaultShowMenu(s, context: context);
            },
            trailing: IconButton(
              icon: const Icon(Icons.more_vert),
              onPressed: () {
                MenuSheet().defaultShowMenu(s, context: context);
              },
            ),
          );
        },
      ),
    );
  }
}

class EpisodeListScreen extends StatelessWidget {
  final List<ShowEpisode> episodes;
  const EpisodeListScreen(this.episodes, {super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: FreezerAppBar('Episodes'.i18n),
      body: SilkyListView.builder(
        silkyConfig: silkyScrollConfig,
        itemCount: episodes.length,
        itemBuilder: (context, i) {
          ShowEpisode e = episodes[i];
          return ShowEpisodeTile(
            e,
            trailing: IconButton(
              icon: Icon(Icons.more_vert, semanticLabel: 'Options'.i18n),
              onPressed: () {
                MenuSheet m = MenuSheet();
                m.defaultShowEpisodeMenu(e.show!, e, context: context);
              },
            ),
            onTap: () async {
              //Load entire show, then play
              final pId = e.show!.platformId;
              List<ShowEpisode> episodes = await PlatformManager.instance
                  .getPlatform(pId)
                  .getShowEpisodes(e.show!.id ?? '');
              await GetIt.I<AudioPlayerHandler>().playShowEpisode(
                e.show!,
                episodes,
                index: episodes.indexWhere((ep) => e.id == ep.id),
              );
            },
          );
        },
      ),
    );
  }
}

class RadioListScreen extends StatelessWidget {
  final List<LiveRadio> radios;
  const RadioListScreen(this.radios, {super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: FreezerAppBar('Live Radios'.i18n),
      body: SilkyListView.builder(
        silkyConfig: silkyScrollConfig,
        itemCount: radios.length,
        itemBuilder: (context, i) {
          LiveRadio r = radios[i];
          return LiveRadioListTile(
            r,
            onTap: () async {
              await GetIt.I<AudioPlayerHandler>().playRadio(
                id: r.id!,
                title: r.title ?? '',
                description: r.description,
                artUrl: r.image?.full ?? r.image?.thumb,
              );
            },
          );
        },
      ),
    );
  }
}
