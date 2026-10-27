import 'music_platform.dart';

/// Central registry of compiled-in platform plugins.
///
/// Usage:
///   PlatformRegistry.instance.register(DeezerPlatform());
///   PlatformRegistry.instance.register(SoundCloudPlatform());
class PlatformRegistry {
  PlatformRegistry._();
  static final PlatformRegistry instance = PlatformRegistry._();

  final Map<String, MusicPlatform> _platforms = {};

  /// Register a platform. Called once at app startup in [prepareRun].
  void register(MusicPlatform platform) {
    _platforms[platform.platformId] = platform;
  }

  /// Look up a platform by its stable ID.
  MusicPlatform? get(String platformId) => _platforms[platformId];

  /// Ask each registered platform whether it recognizes a music URL.
  /// The preferred platform is checked first so links remain predictable when
  /// URL patterns overlap between services.
  Future<PlatformLinkResponse?> parseMusicLink(
    String url, {
    String? preferredPlatformId,
  }) async {
    final preferredPlatform = preferredPlatformId == null
        ? null
        : _platforms[preferredPlatformId];
    final orderedPlatforms = <MusicPlatform>[
      ?preferredPlatform,
      ..._platforms.values.where(
        (platform) => platform.platformId != preferredPlatformId,
      ),
    ];

    for (final platform in orderedPlatforms) {
      try {
        final response = await platform.parseLink(url);
        if (response != null) return response;
      } catch (_) {
        // A platform that cannot parse this URL should not block other
        // registered platforms from recognizing it.
      }
    }
    return null;
  }

  /// All registered platforms.
  List<MusicPlatform> get allPlatforms => _platforms.values.toList();

  /// Platforms the user is currently authenticated with.
  Future<List<MusicPlatform>> get loggedInPlatforms async {
    final result = <MusicPlatform>[];
    for (final p in _platforms.values) {
      if (await p.isLoggedIn()) result.add(p);
    }
    return result;
  }

  bool get isEmpty => _platforms.isEmpty;
}
