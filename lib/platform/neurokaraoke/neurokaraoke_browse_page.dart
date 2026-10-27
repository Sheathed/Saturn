import 'package:material_ui/material_ui.dart';
import '../../api/definitions.dart';
import '../../ui/home_screen.dart';
import '../../ui/tiles.dart';
import '../../platform/platform_manager.dart';
import '../../ui/details_screens.dart';
import '../../ui/menu.dart';
import 'neurokaraoke_api.dart';

enum BrowseTab { playlists, setlists, artists }

class NeuroKaraokeBrowsePage extends StatefulWidget {
  const NeuroKaraokeBrowsePage({super.key});

  @override
  State<NeuroKaraokeBrowsePage> createState() => _NeuroKaraokeBrowsePageState();
}

class _NeuroKaraokeBrowsePageState extends State<NeuroKaraokeBrowsePage> {
  BrowseTab _selectedTab = BrowseTab.playlists;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: SegmentedButton<BrowseTab>(
            segments: const [
              ButtonSegment<BrowseTab>(
                value: BrowseTab.playlists,
                label: Text('Playlists'),
                icon: Icon(Icons.queue_music),
              ),
              ButtonSegment<BrowseTab>(
                value: BrowseTab.setlists,
                label: Text('Setlists'),
                icon: Icon(Icons.format_list_bulleted),
              ),
              ButtonSegment<BrowseTab>(
                value: BrowseTab.artists,
                label: Text('Artists'),
                icon: Icon(Icons.person),
              ),
            ],
            selected: {_selectedTab},
            onSelectionChanged: (Set<BrowseTab> newSelection) {
              setState(() {
                _selectedTab = newSelection.first;
              });
            },
          ),
        ),
        Expanded(
          child: _selectedTab == BrowseTab.artists 
            ? const NeuroKaraokeArtistsGrid()
            : HomePageScreen(
                key: ValueKey(_selectedTab),
                loadPage: () => PlatformManager.instance.active.getChannel(
                  'public_playlists?startIndex=0&isSetlist=${_selectedTab == BrowseTab.setlists}',
                ),
              ),
        ),
      ],
    );
  }
}

class NeuroKaraokeArtistsGrid extends StatefulWidget {
  const NeuroKaraokeArtistsGrid({super.key});

  @override
  State<NeuroKaraokeArtistsGrid> createState() => _NeuroKaraokeArtistsGridState();
}

class _NeuroKaraokeArtistsGridState extends State<NeuroKaraokeArtistsGrid> {
  final List<Artist> _artists = [];
  bool _isLoading = false;
  bool _hasMore = true;
  int _startIndex = 0;
  final int _pageSize = 25;
  final ScrollController _scrollController = ScrollController();
  final NeuroKaraokeAPI _api = NeuroKaraokeAPI();

  @override
  void initState() {
    super.initState();
    _fetchArtists();
    _scrollController.addListener(() {
      if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 200 && !_isLoading && _hasMore) {
        _fetchArtists();
      }
    });
  }

  Future<void> _fetchArtists() async {
    if (_isLoading) return;
    setState(() {
      _isLoading = true;
    });

    try {
      final newArtists = await _api.getArtists(startIndex: _startIndex, pageSize: _pageSize);
      setState(() {
        _artists.addAll(newArtists);
        _startIndex += newArtists.length;
        if (newArtists.length < _pageSize) {
          _hasMore = false;
        }
      });
    } catch (e) {
      debugPrint('Error fetching artists: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_artists.isEmpty && _isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    
    return ResponsiveMediaGrid.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(16.0),
      mainAxisSpacing: 12.0,
      crossAxisSpacing: 12.0,
      itemCount: _artists.length + (_hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == _artists.length) {
          return const Center(child: CircularProgressIndicator());
        }
        final artist = _artists[index];
        return MediaCardTile(
          item: artist,
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) => ArtistDetails(artist),
              ),
            );
          },
          onHold: () {
            MenuSheet m = MenuSheet();
            m.defaultArtistMenu(artist, context: context);
          },
        );
      },
    );
  }
}
