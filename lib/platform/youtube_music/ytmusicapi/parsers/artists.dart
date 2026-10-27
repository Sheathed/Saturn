import '../navigation.dart';
import '../type_alias.dart';

/// Port of ytmusicapi.parsers.artists.parse_artists_runs.
JsonList parseArtistsRuns(List<dynamic> runs) {
  final artists = <JsonDict>[];
  for (var index = 0; index < runs.length; index += 2) {
    final run = asJsonDict(runs[index]);
    if (run == null) {
      continue;
    }
    artists.add({
      'name': run['text'],
      'id': nav(run, navigationBrowseId, absent: true),
    });
  }
  return artists;
}
