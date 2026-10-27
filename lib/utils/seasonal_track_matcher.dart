import 'package:audio_service/audio_service.dart';

enum SeasonalTrackEffect { halloween, christmas }

/// Stable pseudo-random value in [0, 1), suitable for painter layouts that
/// should look varied without changing on every animation frame.
double seasonalRandom01(int seed) {
  var value = seed & 0xFFFFFFFF;
  value = ((value ^ (value >> 16)) * 0x45D9F3B) & 0xFFFFFFFF;
  value = ((value ^ (value >> 16)) * 0x45D9F3B) & 0xFFFFFFFF;
  value = (value ^ (value >> 16)) & 0xFFFFFFFF;
  return value / 0x100000000;
}

bool seasonalEffectIsInDateWindow(SeasonalTrackEffect? effect, DateTime date) {
  switch (effect) {
    case SeasonalTrackEffect.halloween:
      return date.month == 10 && date.day >= 25 && date.day <= 31;
    case SeasonalTrackEffect.christmas:
      return date.month == 12;
    case null:
      return false;
  }
}

SeasonalTrackEffect? seasonalEffectForTrack(MediaItem? item) {
  if (item == null) return null;
  final title = item.title.toLowerCase();
  final album = (item.album ?? '').toLowerCase();
  final artist = (item.artist ?? '').toLowerCase();
  final metadata = '$title $album';

  // Keep matches fairly specific so generic words such as "ghost", "snow",
  // or "holiday" don't decorate unrelated songs (e.g. "Ghost" or Madonna's
  // "Holiday").
  const halloweenTerms = [
    'halloween',
    'trick or treat',
    'monster mash',
    'this is halloween',
    'nightmare before christmas',
    'ghostbusters',
    'thriller',
    'spooky',
    'haunted',
    'pumpkin',
    'zombie',
    'skeleton',
    // Common Halloween staples whose titles don't contain obvious keywords.
    'dead man\'s party',
    'somebody\'s watching me',
    'werewolves of london',
    'i put a spell on you',
    'season of the witch',
    'witchy woman',
    'the time warp',
    'addams family',
    'people are strange',
    'psycho killer',
    'bad moon rising',
    'highway to hell',
    'devil went down to georgia',
    'superstition',
    'black magic woman',
    'disturbia',
    'pet sematary',
    'bela lugosi\'s dead',
    'a nightmare on my street',
    'feed my frankenstein',
    'runnin\' with the devil',
    'bury a friend',
    'enter sandman',
    'werewolf bar mitzvah',
    'black no. 1',
  ];
  const christmasTerms = [
    'christmas',
    'xmas',
    'x-mas',
    'x mas',
    'santa',
    'grinch',
    'noel',
    'mistletoe',
    'reindeer',
    'jingle bells',
    'sleigh ride',
    'white christmas',
    'winter wonderland',
    'let it snow',
    // Well-known Christmas songs with no Christmas keyword in the title.
    'fairytale of new york',
    'christmas wrapping',
    'stop the cavalry',
    '2000 miles',
    'a spaceman came travelling',
    'same old lang syne',
    'carol of the bells',
    'coventry carol',
    'good king wenceslas',
    'o holy night',
    'little drummer boy',
    'do you hear what i hear',
    'mary\'s boy child',
    'december will be magic again',
    'home for the holidays',
    'baby it\'s cold outside',
    'father christmas',
    'the bells of st. mary',
    'the season\'s upon us',
    'somewhere only we know',
    'don\'t waste your wishes',
  ];

  if (halloweenTerms.any(metadata.contains)) {
    return SeasonalTrackEffect.halloween;
  }
  // These seasonal standards have generic titles, so require the artist too
  // to avoid decorating unrelated tracks with the same name.
  if (title.contains('river') && artist.contains('joni mitchell')) {
    return SeasonalTrackEffect.christmas;
  }
  if (title.contains('the power of love') &&
      artist.contains('frankie goes to hollywood')) {
    return SeasonalTrackEffect.christmas;
  }
  if (christmasTerms.any(metadata.contains)) {
    return SeasonalTrackEffect.christmas;
  }
  return null;
}
