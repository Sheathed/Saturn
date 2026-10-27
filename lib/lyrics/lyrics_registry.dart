import 'lyrics_provider.dart';
import 'providers/lrclib.dart';
import 'providers/musixmatch.dart';
import 'providers/genius.dart';
import 'providers/netease.dart';
import 'providers/kugou.dart';
import 'providers/qq.dart';

class LyricsRegistry {
  LyricsRegistry._privateConstructor() {
    register(LrclibLyricsProvider());
    register(MusixmatchLyricsProvider());
    register(NeteaseLyricsProvider());
    register(KugouLyricsProvider());
    register(QQLyricsProvider());
    register(GeniusLyricsProvider());
  }
  static final LyricsRegistry instance = LyricsRegistry._privateConstructor();

  final Map<String, LyricsProvider> _providers = {};

  void register(LyricsProvider provider) {
    _providers[provider.id] = provider;
  }

  LyricsProvider? get(String id) {
    return _providers[id];
  }

  List<LyricsProvider> getAll() {
    return _providers.values.toList();
  }
}
