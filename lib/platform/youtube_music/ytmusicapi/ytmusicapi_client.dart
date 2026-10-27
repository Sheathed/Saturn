import '../youtube_music_client.dart';
import 'mixins/browsing.dart';
import 'mixins/charts.dart';
import 'mixins/explore.dart';
import 'mixins/library.dart';
import 'mixins/playlists.dart';
import 'mixins/podcasts.dart';
import 'mixins/search.dart';
import 'mixins/uploads.dart';
import 'mixins/watch.dart';

/// Composition root for the Dart ytmusicapi port.
///
/// Each mixin keeps the upstream API area separate while sharing Saturn's
/// authenticated Innertube transport and its language/country context.
class YtMusicApiClient {
  YtMusicApiClient(this.client)
    : search = SearchMixin(client),
      browsing = BrowsingMixin(client),
      charts = ChartsMixin(client),
      explore = ExploreMixin(client),
      library = LibraryMixin(client),
      playlists = PlaylistsMixin(client),
      podcasts = PodcastsMixin(client),
      uploads = UploadsMixin(client),
      watch = WatchMixin(client);

  final YouTubeMusicClient client;
  final SearchMixin search;
  final BrowsingMixin browsing;
  final ChartsMixin charts;
  final ExploreMixin explore;
  final LibraryMixin library;
  final PlaylistsMixin playlists;
  final PodcastsMixin podcasts;
  final UploadsMixin uploads;
  final WatchMixin watch;
}
