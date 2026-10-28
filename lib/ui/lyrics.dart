import 'dart:async';
import 'dart:ui';

import 'package:audio_service/audio_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:silky_scroll/silky_scroll.dart';
import 'package:saturn/ui/smooth_scroll_config.dart';

import '../api/definitions.dart';
import '../api/download.dart';
import '../lyrics/lyrics_provider.dart';
import '../lyrics/lyrics_registry.dart';
import '../platform/platform_registry.dart';
import '../platform/music_platform.dart';
import '../service/audio_service.dart';
import '../settings.dart';
import '../translations.i18n.dart';
import '../ui/elements.dart';
import '../ui/cached_image.dart';
import '../ui/error.dart';
import '../ui/play_pause_button.dart';
import 'app_theme.dart';

late Function updateColor;
late Color scaffoldBackgroundColor;

class LyricsToolbarState {
  final bool canChooseLyrics;
  final bool hasTranslation;
  final bool showTranslation;
  final bool hasRomanization;
  final bool showRomanization;

  const LyricsToolbarState({
    this.canChooseLyrics = false,
    this.hasTranslation = false,
    this.showTranslation = false,
    this.hasRomanization = false,
    this.showRomanization = false,
  });
}

class LyricsScreenController {
  final ValueNotifier<LyricsToolbarState> toolbarState = ValueNotifier(
    const LyricsToolbarState(),
  );
  VoidCallback? _showLyricsChoices;
  VoidCallback? _toggleTranslation;
  VoidCallback? _toggleRomanization;
  bool _disposed = false;

  void _updateToolbar({
    required LyricsToolbarState state,
    required VoidCallback? showLyricsChoices,
    required VoidCallback? toggleTranslation,
    required VoidCallback? toggleRomanization,
  }) {
    if (_disposed) return;
    toolbarState.value = state;
    _showLyricsChoices = showLyricsChoices;
    _toggleTranslation = toggleTranslation;
    _toggleRomanization = toggleRomanization;
  }

  void showLyricsChoices() => _showLyricsChoices?.call();
  void toggleTranslation() => _toggleTranslation?.call();
  void toggleRomanization() => _toggleRomanization?.call();

  void dispose() {
    _disposed = true;
    _showLyricsChoices = null;
    _toggleTranslation = null;
    _toggleRomanization = null;
    toolbarState.dispose();
  }
}

class LyricsScreen extends StatefulWidget {
  final Lyrics? lyrics;
  final String trackId;
  final bool embedded;
  final LyricsScreenController? controller;

  const LyricsScreen({
    this.lyrics,
    required this.trackId,
    this.embedded = false,
    this.controller,
    super.key,
  });

  @override
  _LyricsScreenState createState() => _LyricsScreenState();
}

class _OfflineLyricsProvider {
  const _OfflineLyricsProvider();

  String get name => 'Offline lyrics'.i18n;
}

const _offlineLyricsProvider = _OfflineLyricsProvider();

class _LyricsScreenState extends State<LyricsScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const double _providerSwitcherHeight = 60;
  String appBarTitle = 'Lyrics'.i18n;
  Lyrics? lyrics;
  bool _loading = true;
  bool _error = false;
  bool _lyricsUnavailable = false;
  String? _errorMessage;

  int _currentIndex = 0;
  Duration _currentPosition = Duration.zero;
  bool _isUserScrolling = false;
  bool _instrumentalLayoutAnimating = false;
  int? _pendingAutoScrollIndex;
  int _selectedProviderIndex = -1;
  List<LyricsCandidate> _lyricsCandidates = const [];
  String? _selectedLyricsCandidateId;
  bool _showTranslation = true;
  bool _showRomanization = false;
  String _lyricsDisplayProviderId = 'default';
  late String _activeTrackId;
  int _lyricsLoadGeneration = 0;
  Duration? _seekPreview;

  Timer? _syncTimer;
  final ScrollController _scrollController = ScrollController();
  final ScrollController _providerScrollController = ScrollController();
  final GlobalKey _miniPlayerKey = GlobalKey();
  double? _miniPlayerHeight;
  final ValueNotifier<Duration> _positionNotifier = ValueNotifier(
    Duration.zero,
  );
  StreamSubscription? _mediaItemSub;
  StreamSubscription? _radioStateSub;
  late Future<List<dynamic>> _providersFuture;
  bool _hadRadioClock = false;
  LinearGradient? _bgGradient;
  ImageProvider? _blurImage;

  List<GlobalKey> _lyricKeys = [];
  EdgeInsets _lyricEdgePadding = EdgeInsets.zero;
  bool _edgePaddingMeasurementScheduled = false;
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _activeTrackId = widget.trackId;
    _providersFuture = _getAllProviders();
    final handler = GetIt.I<AudioPlayerHandler>();
    final activePlatform = handler.mediaItem.value == null
        ? null
        : PlatformRegistry.instance.get(
            Track.fromMediaItem(handler.mediaItem.value!).platformId,
          );
    _selectedProviderIndex = activePlatform?.capabilities.supportsLyrics == true
        ? 0
        : -1;
    if (activePlatform != null) {
      _setLyricsDisplayProvider('platform:${activePlatform.platformId}');
    }
    _hadRadioClock = handler.hasRadioClock;

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);

    _load();

    // Keep the lyrics route open and fetch the new track's lyrics in place.
    _mediaItemSub = handler.mediaItem.listen((event) {
      final currentRadioTrackId = event?.extras?['radioTrackId'] as String?;
      final targetId = currentRadioTrackId ?? event?.id;
      if (event != null && targetId != _activeTrackId) {
        _handleTrackChange(event);
      }
      _updateColor();
    });
    _radioStateSub = handler.radioStateStream.listen((_) {
      final hasClock = handler.hasRadioClock;
      final clockBecameAvailable = hasClock && !_hadRadioClock;
      _hadRadioClock = hasClock;
      if (!clockBecameAvailable || !mounted) return;
      final item = handler.mediaItem.value;
      final trackId = (item?.extras?['radioTrackId'] as String?) ?? item?.id;
      if (trackId != _activeTrackId ||
          lyrics?.syncedLyrics?.isNotEmpty != true) {
        return;
      }
      final position = handler.syncedPosition;
      _positionNotifier.value = position;
      setState(() {
        _currentPosition = position;
        _currentIndex = _lyricIndexAt(position);
      });
    });

    _updateColor();
  }

  void _handleTrackChange(MediaItem item) {
    final handler = GetIt.I<AudioPlayerHandler>();
    _activeTrackId = (item.extras?['radioTrackId'] as String?) ?? item.id;
    _providersFuture = _getAllProviders();
    final activePlatform = PlatformRegistry.instance.get(
      Track.fromMediaItem(item).platformId,
    );
    if (activePlatform != null) {
      _setLyricsDisplayProvider('platform:${activePlatform.platformId}');
    }
    _lyricsLoadGeneration++;
    _syncTimer?.cancel();
    _seekPreview = null;
    if (mounted) {
      setState(() {
        lyrics = null;
        _loading = true;
        _error = false;
        _lyricsUnavailable = false;
        _errorMessage = null;
        _currentIndex = 0;
        _currentPosition = handler.isRadio
            ? handler.syncedPosition
            : handler.player.position;
        _isUserScrolling = false;
        _instrumentalLayoutAnimating = false;
        _pendingAutoScrollIndex = null;
        _selectedProviderIndex =
            activePlatform?.capabilities.supportsLyrics == true ? 0 : -1;
        _lyricsCandidates = const [];
        _selectedLyricsCandidateId = null;
      });
    }
    _syncLyricsChoicesButton();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) _scrollController.jumpTo(0);
    });
    unawaited(_load());
  }

  List<LyricsCandidate> get _lyricsVersionCandidates {
    final seen = <String>{};
    return _lyricsCandidates.where((candidate) {
      final id = candidate.id.trim();
      if (id.isEmpty ||
          id.toLowerCase() == 'default' ||
          id.toLowerCase() == 'native' ||
          id == candidate.providerId) {
        return false;
      }
      return seen.add('${candidate.providerId}|$id');
    }).toList();
  }

  void _syncLyricsChoicesButton() {
    // A chooser is useful only when there are multiple real records.
    final hasChoices = _lyricsVersionCandidates.length > 1;
    widget.controller?._updateToolbar(
      state: LyricsToolbarState(
        canChooseLyrics: hasChoices,
        hasTranslation: _hasTranslation,
        showTranslation: _showTranslation,
        hasRomanization: _hasRomanization,
        showRomanization: _showRomanization,
      ),
      showLyricsChoices: hasChoices
          ? () => unawaited(_showLyricsCandidateSheet())
          : null,
      toggleTranslation: _hasTranslation
          ? () => _setTranslationVisibility(!_showTranslation)
          : null,
      toggleRomanization: _hasRomanization
          ? () => _setRomanizationVisibility(!_showRomanization)
          : null,
    );
  }

  void _setLyricsDisplayProvider(String providerId) {
    _lyricsDisplayProviderId = providerId;
    _showTranslation = settings.lyricsTranslationVisibility[providerId] ?? true;
    _showRomanization =
        settings.lyricsRomanizationVisibility[providerId] ?? false;
  }

  void _setTranslationVisibility(bool value) {
    if (_showTranslation == value) return;
    setState(() => _showTranslation = value);
    settings.lyricsTranslationVisibility[_lyricsDisplayProviderId] = value;
    unawaited(settings.save());
    _syncLyricsChoicesButton();
  }

  void _setRomanizationVisibility(bool value) {
    if (_showRomanization == value) return;
    setState(() => _showRomanization = value);
    settings.lyricsRomanizationVisibility[_lyricsDisplayProviderId] = value;
    unawaited(settings.save());
    _syncLyricsChoicesButton();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !mounted) return;
    final handler = GetIt.I<AudioPlayerHandler>();
    final position = handler.isRadio
        ? handler.syncedPosition
        : handler.player.position;
    final index = _lyricIndexAt(position);
    _syncTimer?.cancel();
    if (_scrollController.hasClients) {
      // jumpTo cancels any stale drag/ballistic activity left suspended by
      // the platform while the app was backgrounded.
      _scrollController.jumpTo(_scrollController.position.pixels);
    }
    setState(() {
      _isUserScrolling = false;
      _currentPosition = position;
      _currentIndex = index;
      _pendingAutoScrollIndex = index;
    });
    if (lyrics?.syncedLyrics?.isNotEmpty == true) _startSyncTimer();
    _schedulePendingAutoScroll();
  }

  @override
  void dispose() {
    widget.controller?._updateToolbar(
      state: const LyricsToolbarState(),
      showLyricsChoices: null,
      toggleTranslation: null,
      toggleRomanization: null,
    );
    WidgetsBinding.instance.removeObserver(this);
    _syncTimer?.cancel();
    _mediaItemSub?.cancel();
    _radioStateSub?.cancel();
    _scrollController.dispose();
    _providerScrollController.dispose();
    _positionNotifier.dispose();
    _pulseController.dispose();

    if (!widget.embedded) {
      SystemChrome.setSystemUIOverlayStyle(
        SystemUiOverlayStyle(
          systemNavigationBarColor: settings.themeData.scaffoldBackgroundColor,
        ),
      );
    }
    super.dispose();
  }

  Future<void> _load() async {
    final requestId = ++_lyricsLoadGeneration;
    final trackId = _activeTrackId;
    final currentItem = GetIt.I<AudioPlayerHandler>().mediaItem.value;
    var currentTrack = currentItem == null
        ? null
        : Track.fromMediaItem(currentItem);
    if (currentTrack != null) {
      currentTrack = await _withOfflineLyrics(currentTrack);
    }
    final savedChoice = currentTrack == null
        ? null
        : _getSavedLyricsChoice(currentTrack);

    // Lyrics saved with an offline track are available without a network
    // provider. Use them as the default unless the user has an explicit
    // provider choice saved for this track.
    if (currentTrack?.lyrics?.isLoaded() == true &&
        (savedChoice == null ||
            savedChoice == 'default' ||
            savedChoice == 'native')) {
      final providers = await _getAllProviders();
      final offlineIndex = providers.indexOf(_offlineLyricsProvider);
      if (!mounted || requestId != _lyricsLoadGeneration) return;
      if (offlineIndex >= 0) {
        _setLyricsDisplayProvider('offline');
        setState(() => _selectedProviderIndex = offlineIndex);
        _updateLyricsState(currentTrack!.lyrics!);
        return;
      }
    }
    if (savedChoice == null &&
        trackId == widget.trackId &&
        widget.lyrics?.isLoaded() == true) {
      final platformId = currentTrack?.platformId;
      if (platformId != null) _setLyricsDisplayProvider('platform:$platformId');
      _updateLyricsState(widget.lyrics!);
      return;
    }

    try {
      final mediaItem = GetIt.I<AudioPlayerHandler>().mediaItem.value;
      if (mediaItem != null) {
        final track = Track.fromMediaItem(mediaItem);
        final preferredChoice = _getSavedLyricsChoice(track);
        if (preferredChoice != null &&
            preferredChoice != 'default' &&
            preferredChoice != 'native') {
          // 1. Alternate MusicPlatform (e.g. platform:youtube_music)
          if (preferredChoice.startsWith('platform:')) {
            final targetPlatformId = preferredChoice.substring(
              'platform:'.length,
            );
            final targetPlatform = PlatformRegistry.instance.get(
              targetPlatformId,
            );
            if (targetPlatform != null) {
              _setLyricsDisplayProvider('platform:$targetPlatformId');
              final allProviders = await _getAllProviders();
              final provIdx = allProviders.indexWhere(
                (p) => p is MusicPlatform && p.platformId == targetPlatformId,
              );
              if (provIdx >= 0) {
                _selectedProviderIndex = provIdx;
                await _loadPlatformLyrics(targetPlatform, requestId);
                return;
              }
            }
          }

          // 2. LyricsProvider (with or without candidate ID)
          final separator = preferredChoice.indexOf('|');
          final providerId = separator > 0
              ? preferredChoice.substring(0, separator)
              : preferredChoice;
          final candidateId = separator > 0
              ? preferredChoice.substring(separator + 1)
              : null;

          final lyricsProvider = LyricsRegistry.instance.get(providerId);
          if (lyricsProvider != null) {
            _setLyricsDisplayProvider('provider:$providerId');
            final allProviders = await _getAllProviders();
            final provIdx = allProviders.indexWhere(
              (p) => p is LyricsProvider && p.id == providerId,
            );
            if (provIdx >= 0) {
              _selectedProviderIndex = provIdx;
            }

            try {
              final candidates = await lyricsProvider.getLyricsCandidates(
                track,
              );
              if (!mounted || requestId != _lyricsLoadGeneration) return;

              final usableCandidates = _distinctUsableCandidates(candidates);

              if (usableCandidates.isNotEmpty) {
                LyricsCandidate selected = usableCandidates.first;
                if (candidateId != null) {
                  final matched = usableCandidates
                      .where((c) => c.id == candidateId)
                      .firstOrNull;
                  if (matched != null) selected = matched;
                }
                _lyricsCandidates = usableCandidates;
                _selectedLyricsCandidateId = selected.id;
                _syncLyricsChoicesButton();
                _updateLyricsState(selected.lyrics);
                return;
              }

              final l = await lyricsProvider.getLyrics(track);
              if (!mounted || requestId != _lyricsLoadGeneration) return;
              if (_hasAnyLyrics(l)) {
                _lyricsCandidates = const [];
                _selectedLyricsCandidateId = null;
                _syncLyricsChoicesButton();
                _updateLyricsState(l);
                return;
              }
            } catch (error) {
              debugPrint(
                '[Lyrics] Saved lyrics provider ($providerId) failed: $error',
              );
            }
          }
        }
      }
      final platformId = mediaItem == null
          ? null
          : Track.fromMediaItem(mediaItem).platformId;
      final platform = platformId == null
          ? null
          : PlatformRegistry.instance.get(platformId);
      final track = mediaItem != null ? Track.fromMediaItem(mediaItem) : null;
      if (platform == null || !platform.capabilities.supportsLyrics) {
        if (!mounted || requestId != _lyricsLoadGeneration) return;
        final allProviders = await _getAllProviders();
        final lrclibIndex = allProviders.indexWhere(
          (provider) => provider is LyricsProvider && provider.id == 'lrclib',
        );
        final lrclib = LyricsRegistry.instance.get('lrclib');
        if (track != null && lrclib != null && lrclibIndex >= 0) {
          _setLyricsDisplayProvider('provider:lrclib');
          setState(() => _selectedProviderIndex = lrclibIndex);
          await _loadLyricsFromProvider(lrclib, track, requestId);
        } else {
          _showLyricsUnavailable();
        }
        return;
      }
      Lyrics? l;
      if (track?.lyrics?.isLoaded() == true) {
        l = track!.lyrics;
      } else {
        l = await platform.getLyrics(trackId);
        if (!_hasAnyLyrics(l) && track?.fallback?.id != null) {
          final fallbackL = await platform.getLyrics(track!.fallback!.id!);
          if (_hasAnyLyrics(fallbackL)) l = fallbackL;
        }
      }

      if (!mounted || requestId != _lyricsLoadGeneration) return;
      if (l == null || !_hasAnyLyrics(l)) {
        _showLyricsUnavailable();
        return;
      }
      if (track != null)
        _setLyricsDisplayProvider('platform:${track.platformId}');
      _updateLyricsState(l);
    } catch (e, stack) {
      if (!mounted || requestId != _lyricsLoadGeneration) return;
      debugPrint('[Lyrics] Error loading lyrics: $e\n$stack');
      _showLyricsUnavailable();
    }
  }

  Future<Track> _withOfflineLyrics(Track track) async {
    if (track.id == null) return track;
    try {
      final offlineTrack = await downloadManager.getOfflineTrack(
        track.id!,
        platformId: track.platformId,
        includeUnavailable: true,
      );
      // The current media item may carry platform lyrics or an empty lyrics
      // placeholder. Prefer the explicitly saved offline copy when available.
      if (offlineTrack?.lyrics?.isLoaded() == true) return offlineTrack!;
    } catch (error) {
      debugPrint('[Lyrics] Could not load saved offline lyrics: $error');
    }
    return track;
  }

  Future<void> _loadLyricsFromProvider(
    LyricsProvider provider,
    Track track,
    int requestId,
  ) async {
    _setLyricsDisplayProvider('provider:${provider.id}');
    try {
      final candidates = await provider.getLyricsCandidates(track);
      if (!mounted || requestId != _lyricsLoadGeneration) return;
      final usableCandidates = _distinctUsableCandidates(candidates);
      if (usableCandidates.isNotEmpty) {
        final selected = usableCandidates.first;
        _lyricsCandidates = usableCandidates;
        _selectedLyricsCandidateId = selected.id;
        _syncLyricsChoicesButton();
        _updateLyricsState(selected.lyrics);
        return;
      }

      _showLyricsUnavailable();
    } catch (error, stack) {
      if (!mounted || requestId != _lyricsLoadGeneration) return;
      debugPrint(
        '[Lyrics] Default provider (${provider.id}) failed: $error\n$stack',
      );
      _showLyricsUnavailable();
    }
  }

  String _lyricsPreferenceKey(Track track) {
    final title = (track.title ?? '').trim().toLowerCase();
    final artist = (track.artistString ?? '').trim().toLowerCase();
    return '$title|$artist';
  }

  String? _getSavedLyricsChoice(Track track) {
    final title = (track.title ?? '').trim().toLowerCase();
    if (title.isEmpty) return null;
    final primaryKey = _lyricsPreferenceKey(track);
    if (settings.lyricsChoices.containsKey(primaryKey)) {
      return settings.lyricsChoices[primaryKey];
    }
    // Backward compatibility with legacy 4-part keys (title|artist|album|duration)
    final legacyPrefix = '$primaryKey|';
    for (final entry in settings.lyricsChoices.entries) {
      if (entry.key.startsWith(legacyPrefix)) {
        return entry.value;
      }
    }
    // Resilient fallback by track title prefix
    for (final entry in settings.lyricsChoices.entries) {
      if (entry.key.startsWith('$title|')) {
        return entry.value;
      }
    }
    return null;
  }

  void _removeSavedLyricsChoice(Track track) {
    final title = (track.title ?? '').trim().toLowerCase();
    final primaryKey = _lyricsPreferenceKey(track);
    settings.lyricsChoices.remove(primaryKey);
    final legacyPrefix = '$primaryKey|';
    settings.lyricsChoices.removeWhere((k, _) => k.startsWith(legacyPrefix));
    if (title.isNotEmpty) {
      settings.lyricsChoices.removeWhere(
        (k, _) =>
            k == title ||
            k.startsWith('$title|') ||
            (track.artistString?.trim().isNotEmpty == true &&
                k.toLowerCase().contains(title)),
      );
    }
    unawaited(settings.save());
  }

  Future<void> _chooseLyricsCandidate(LyricsCandidate candidate) async {
    _setLyricsDisplayProvider('provider:${candidate.providerId}');
    final requestId = ++_lyricsLoadGeneration;
    final mediaItem = GetIt.I<AudioPlayerHandler>().mediaItem.value;
    if (mediaItem == null) {
      return;
    }
    final track = Track.fromMediaItem(mediaItem);
    _removeSavedLyricsChoice(track);
    settings.lyricsChoices[_lyricsPreferenceKey(track)] =
        '${candidate.providerId}|${candidate.id}';
    unawaited(settings.save());
    if (!mounted || requestId != _lyricsLoadGeneration) {
      return;
    }
    final allProviders = await _getAllProviders();
    final provIdx = allProviders.indexWhere(
      (entry) => entry is LyricsProvider && entry.id == candidate.providerId,
    );
    setState(() {
      _selectedLyricsCandidateId = candidate.id;
      if (provIdx >= 0) {
        _selectedProviderIndex = provIdx;
      }
    });
    _updateLyricsState(candidate.lyrics);
  }

  Future<void> _resetToDefaultLyrics() async {
    final mediaItem = GetIt.I<AudioPlayerHandler>().mediaItem.value;
    if (mediaItem != null) {
      final track = Track.fromMediaItem(mediaItem);
      _setLyricsDisplayProvider('platform:${track.platformId}');
      _removeSavedLyricsChoice(track);
    }
    setState(() {
      _selectedProviderIndex = 0;
      _selectedLyricsCandidateId = null;
      _lyricsCandidates = const [];
      _loading = true;
      lyrics = null;
      _error = false;
      _lyricsUnavailable = false;
    });
    _syncLyricsChoicesButton();
    await _load();
  }

  void _showLyricsUnavailable() {
    _syncTimer?.cancel();
    if (!mounted) return;
    setState(() {
      appBarTitle = 'Lyrics'.i18n;
      lyrics = null;
      _loading = false;
      _error = false;
      _lyricsUnavailable = true;
      _currentIndex = 0;
      _lyricsCandidates = const [];
      _selectedLyricsCandidateId = null;
    });
    // Keep the desktop tab bar in sync when a provider returns no usable
    // candidates (or fails after a previous provider exposed several).
    _syncLyricsChoicesButton();
  }

  Widget _buildLyricsUnavailable(Color textColor, Color primaryColor) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.lyrics_outlined,
              size: 48,
              color: primaryColor.withValues(alpha: 0.8),
            ),
            const SizedBox(height: 16),
            Text(
              'No lyrics found'.i18n,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: textColor,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Try another lyric provider or check again later.'.i18n,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: textColor.withValues(alpha: 0.65),
                fontSize: 14,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _loadPlatformLyrics(
    MusicPlatform platform,
    int requestId,
  ) async {
    _setLyricsDisplayProvider('platform:${platform.platformId}');
    final trackId = _activeTrackId;
    _lyricsCandidates = const [];
    _selectedLyricsCandidateId = null;
    _syncLyricsChoicesButton();
    try {
      final mediaItem = GetIt.I<AudioPlayerHandler>().mediaItem.value;
      if (mediaItem == null) {
        if (mounted && requestId == _lyricsLoadGeneration) {
          _showLyricsUnavailable();
        }
        return;
      }
      final track = Track.fromMediaItem(mediaItem);
      final nativePlatformId = track.platformId;
      Lyrics? l;

      if (platform.platformId == nativePlatformId) {
        _removeSavedLyricsChoice(track);
        if (track.lyrics?.isLoaded() == true) {
          l = track.lyrics;
        } else if (widget.lyrics?.isLoaded() == true &&
            trackId == widget.trackId) {
          l = widget.lyrics;
        } else {
          l = await platform.getLyrics(trackId);
          if (!_hasAnyLyrics(l) && track.fallback?.id != null) {
            final fallbackL = await platform.getLyrics(track.fallback!.id!);
            if (_hasAnyLyrics(fallbackL)) l = fallbackL;
          }
        }
      } else {
        final nativePlatform = PlatformRegistry.instance.get(nativePlatformId);
        final nativeQuery =
            nativePlatform?.getLyricsSearchQuery(track) ??
            '${track.title} ${track.artistString ?? ''}'.trim();

        final queriesToTry = [
          nativeQuery,
          ...track.lyricSearchQueries,
        ].where((q) => q.isNotEmpty).toSet().toList();

        for (final query in queriesToTry) {
          if (!mounted || requestId != _lyricsLoadGeneration) return;
          if (query.isEmpty) continue;
          final searchResults = await platform.search(query);
          if (!mounted || requestId != _lyricsLoadGeneration) return;
          if (searchResults.tracks?.isNotEmpty == true) {
            final platformTrackId = searchResults.tracks!.first.id!;
            try {
              l = await platform.getLyrics(platformTrackId);
              if (_hasAnyLyrics(l)) break;
            } catch (e) {
              debugPrint(
                '[Lyrics] Search hit found but getLyrics failed for query "$query": $e',
              );
            }
          }
        }

        if (l == null || !_hasAnyLyrics(l)) {
          throw Exception(
            'Track not found or no lyrics on platform ${platform.platformId}',
          );
        }
      }

      if (!mounted || requestId != _lyricsLoadGeneration) return;
      if (l == null || !_hasAnyLyrics(l)) throw Exception('No lyrics found');
      _updateLyricsState(l);
    } catch (e) {
      if (!mounted || requestId != _lyricsLoadGeneration) return;
      debugPrint('[Lyrics] Error loading platform lyrics: $e');
      _showLyricsUnavailable();
    }
  }

  void _updateLyricsState(Lyrics newLyrics) {
    // Globally clean up common fluff from all providers (Chinese and English)
    final metadataFluffRegex = RegExp(
      r'^(?:作词|作曲|编曲|制作|监制|混音|和声|原唱|翻唱|演唱|后期|母带|发行|企划|吉他|贝斯|鼓|键盘|录音|出品|发行公司|OP|SP|词|曲|lyricist|composer|arranger|producer)\s*[:：]',
      caseSensitive: false,
    );
    final instrumentalRegex = RegExp(
      r'^[\(\[【]?(?:instrumental|music|solo|间奏|前奏|尾奏|纯音乐|伴奏)[\)\]】]?$',
      caseSensitive: false,
    );

    if (newLyrics.syncedLyrics != null) {
      newLyrics.syncedLyrics!.removeWhere((l) {
        final text = l.text?.trim() ?? '';
        return metadataFluffRegex.hasMatch(text) ||
            instrumentalRegex.hasMatch(text);
      });
    }

    if (newLyrics.unsyncedLyrics != null) {
      final lines = newLyrics.unsyncedLyrics!.split('\n');
      lines.removeWhere(
        (line) =>
            metadataFluffRegex.hasMatch(line.trim()) ||
            instrumentalRegex.hasMatch(line.trim()),
      );
      newLyrics.unsyncedLyrics = lines.join('\n');
    }

    final handler = GetIt.I<AudioPlayerHandler>();
    final isRadio =
        handler.isRadio ||
        AudioPlayerHandler.isRadioItem(handler.mediaItem.value);
    final radioPlatformId =
        handler.radioState?.platformId ??
        handler.mediaItem.value?.extras?['platformId'] as String?;
    final canSyncRadio =
        radioPlatformId != null &&
        PlatformRegistry.instance.get(radioPlatformId)?.supportsRadioTiming ==
            true;
    if (isRadio &&
        !canSyncRadio &&
        newLyrics.syncedLyrics?.isNotEmpty == true) {
      newLyrics = Lyrics(
        id: newLyrics.id,
        writers: newLyrics.writers,
        unsyncedLyrics: newLyrics.unsyncedLyrics?.trim().isNotEmpty == true
            ? newLyrics.unsyncedLyrics
            : newLyrics.syncedLyrics!
                  .map((line) => line.text ?? '')
                  .where((text) => text.trim().isNotEmpty)
                  .join('\n'),
        unsyncedTranslatedLyrics: newLyrics.unsyncedTranslatedLyrics,
        unsyncedRomanizedLyrics: newLyrics.unsyncedRomanizedLyrics,
        errorMessage: newLyrics.errorMessage,
        isExplicit: newLyrics.isExplicit,
        copyright: newLyrics.copyright,
      );
    }

    String screenTitle = 'Lyrics'.i18n;

    _lyricKeys = List.generate(
      newLyrics.syncedLyrics?.length ?? 0,
      (_) => GlobalKey(),
    );
    _lyricEdgePadding = EdgeInsets.zero;

    _syncTimer?.cancel();

    if (newLyrics.syncedLyrics?.isNotEmpty == true) {
      _startSyncTimer();
    } else if (newLyrics.unsyncedLyrics?.isNotEmpty == true) {
      screenTitle = 'Unsynchronized lyrics'.i18n;
    }

    final playerHandler = GetIt.I<AudioPlayerHandler>();
    final position = playerHandler.isRadio
        ? playerHandler.syncedPosition
        : playerHandler.player.position;
    final initialIndex = newLyrics.syncedLyrics?.isNotEmpty == true
        ? _lyricIndexAt(position)
        : 0;

    if (mounted) {
      setState(() {
        appBarTitle = screenTitle;
        lyrics = newLyrics;
        _loading = false;
        _error = false;
        _lyricsUnavailable = false;
        _isUserScrolling = false;
        _currentPosition = position;
        _positionNotifier.value = position;
        _currentIndex = initialIndex;
      });
      _syncLyricsChoicesButton();
      if (newLyrics.syncedLyrics?.isNotEmpty == true &&
          initialIndex >= 0 &&
          _instrumentalCardAt(position) == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _scrollToIndex(initialIndex);
        });
      }
    }
  }

  List<LyricsCandidate> _distinctUsableCandidates(
    Iterable<LyricsCandidate> candidates,
  ) {
    final seen = <String>{};
    return candidates.where((candidate) {
      if (!_hasAnyLyrics(candidate.lyrics)) return false;
      final key = '${candidate.providerId}|${candidate.id}';
      return seen.add(key);
    }).toList();
  }

  bool _hasAnyLyrics(Lyrics value) =>
      value.errorMessage == null &&
      (value.isLoaded() ||
          value.syncedLyrics?.any(
                (line) =>
                    (line.translatedText?.isNotEmpty ?? false) ||
                    (line.romanizedText?.isNotEmpty ?? false),
              ) ==
              true);

  bool get _hasTranslation =>
      lyrics?.unsyncedTranslatedLyrics?.isNotEmpty == true ||
      lyrics?.syncedLyrics?.any(
            (line) => line.translatedText?.isNotEmpty == true,
          ) ==
          true;

  bool get _hasRomanization =>
      lyrics?.unsyncedRomanizedLyrics?.isNotEmpty == true ||
      lyrics?.syncedLyrics?.any(
            (line) => line.romanizedText?.isNotEmpty == true,
          ) ==
          true;

  Widget _buildLyricOverlays(SynchronizedLyric lyric) {
    final translation = _showTranslation ? lyric.translatedText?.trim() : null;
    final romanization = _showRomanization ? lyric.romanizedText?.trim() : null;
    if ((translation == null || translation.isEmpty) &&
        (romanization == null || romanization.isEmpty)) {
      return const SizedBox.shrink();
    }
    final muted =
        Theme.of(context).textTheme.bodyMedium?.color ?? Colors.white70;
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (translation != null && translation.isNotEmpty)
            Text(
              translation,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 17,
                height: 1.35,
                color: muted.withValues(alpha: 0.86),
                fontWeight: FontWeight.w500,
              ),
            ),
          if (romanization != null && romanization.isNotEmpty)
            Text(
              romanization,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                height: 1.3,
                color: muted.withValues(alpha: 0.62),
                fontStyle: FontStyle.italic,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTranslationControls() {
    if (!_hasTranslation && !_hasRomanization && _lyricsCandidates.length < 2) {
      return const SizedBox.shrink();
    }
    final primary = Theme.of(context).colorScheme.primary;
    final onSurface = Theme.of(context).colorScheme.onSurface;

    Widget toggle({
      required String label,
      required IconData icon,
      required bool selected,
      required ValueChanged<bool> onChanged,
    }) => IconButton(
      tooltip: label.i18n,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 36, height: 36),
      padding: EdgeInsets.zero,
      style: IconButton.styleFrom(
        foregroundColor: selected ? primary : onSurface.withValues(alpha: 0.72),
        backgroundColor: selected
            ? primary.withValues(alpha: 0.20)
            : Colors.transparent,
        shape: const CircleBorder(),
      ),
      onPressed: () => onChanged(!selected),
      icon: Icon(icon, size: 19),
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_lyricsCandidates.length > 1)
          IconButton(
            tooltip: 'Choose lyrics'.i18n,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints.tightFor(width: 36, height: 36),
            padding: EdgeInsets.zero,
            onPressed: _showLyricsCandidateSheet,
            icon: const Icon(Icons.lyrics_outlined, size: 19),
          ),
        if (_hasTranslation)
          toggle(
            label: 'Translation',
            icon: Icons.translate,
            selected: _showTranslation,
            onChanged: _setTranslationVisibility,
          ),
        if (_hasRomanization)
          toggle(
            label: 'Romanization',
            icon: Icons.text_fields,
            selected: _showRomanization,
            onChanged: _setRomanizationVisibility,
          ),
      ],
    );
  }

  String _formatPlayerTime(Duration? duration) {
    final seconds = (duration ?? Duration.zero).inSeconds;
    final minutes = seconds ~/ 60;
    final remainder = seconds % 60;
    return '$minutes:${remainder.toString().padLeft(2, '0')}';
  }

  Widget _buildMiniPlayer() {
    final handler = GetIt.I<AudioPlayerHandler>();
    final item = handler.mediaItem.value;
    final primary = Theme.of(context).colorScheme.primary;
    final surface = Theme.of(context).colorScheme.surface;
    final duration = handler.player.duration;
    final artUrl =
        item?.extras?['saturnOriginalArtUri'] as String? ??
        item?.artUri?.toString() ??
        item?.extras?['thumb'] as String? ??
        '';

    return Container(
      key: _miniPlayerKey,
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: primary.withValues(alpha: 0.3))),
      ),
      child: ClipRect(
        child: Stack(
          children: [
            Positioned.fill(
              child: ColoredBox(color: surface.withValues(alpha: 0.42)),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 7, 12, 5),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(7),
                          child: SizedBox(
                            width: 44,
                            height: 44,
                            child: CachedImage(
                              width: 44,
                              height: 44,
                              url: artUrl,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                item?.title ?? 'Nothing playing'.i18n,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                              if (item?.artist?.isNotEmpty == true)
                                Text(
                                  item!.artist!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                            ],
                          ),
                        ),
                        _buildTranslationControls(),
                        if (!handler.isRadio &&
                            !AudioPlayerHandler.isRadioItem(item))
                          IconButton(
                            tooltip: 'Previous'.i18n,
                            visualDensity: VisualDensity.compact,
                            onPressed: handler.skipToPrevious,
                            icon: const Icon(Icons.skip_previous_rounded),
                          ),
                        const PlayPauseButton(25),
                        if (!handler.isRadio &&
                            !AudioPlayerHandler.isRadioItem(item))
                          IconButton(
                            tooltip: 'Next'.i18n,
                            visualDensity: VisualDensity.compact,
                            onPressed: handler.skipToNext,
                            icon: const Icon(Icons.skip_next_rounded),
                          ),
                      ],
                    ),
                    if ((!handler.isRadio &&
                            !AudioPlayerHandler.isRadioItem(item)) ||
                        handler.hasRadioClock)
                      StreamBuilder<Duration>(
                        stream: handler.isRadio
                            ? Stream.periodic(
                                const Duration(milliseconds: 250),
                                (_) => handler.syncedPosition,
                              )
                            : handler.player.positionStream,
                        initialData: handler.isRadio
                            ? handler.syncedPosition
                            : handler.player.position,
                        builder: (context, positionSnapshot) =>
                            StreamBuilder<Duration?>(
                              stream: handler.isRadio
                                  ? Stream.value(item?.duration)
                                  : handler.player.durationStream,
                              initialData: item?.duration ?? duration,
                              builder: (context, durationSnapshot) {
                                final total =
                                    durationSnapshot.data ?? Duration.zero;
                                final shownPosition = handler.isRadio
                                    ? handler.syncedPosition
                                    : (_seekPreview ??
                                          positionSnapshot.data ??
                                          Duration.zero);
                                final maxMs = total.inMilliseconds;
                                final value = maxMs <= 0
                                    ? 0.0
                                    : shownPosition.inMilliseconds
                                          .clamp(0, maxMs)
                                          .toDouble();
                                return Row(
                                  children: [
                                    Text(
                                      _formatPlayerTime(shownPosition),
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelSmall
                                          ?.copyWith(
                                            fontFeatures: const [
                                              FontFeature.tabularFigures(),
                                            ],
                                          ),
                                    ),
                                    Expanded(
                                      child: SliderTheme(
                                        data: SliderTheme.of(context).copyWith(
                                          trackHeight: 2.5,
                                          thumbShape:
                                              const RoundSliderThumbShape(
                                                enabledThumbRadius: 6,
                                              ),
                                          overlayShape:
                                              const RoundSliderOverlayShape(
                                                overlayRadius: 12,
                                              ),
                                        ),
                                        child: Slider(
                                          min: 0,
                                          max: maxMs > 0 ? maxMs.toDouble() : 1,
                                          value: value,
                                          onChanged:
                                              (handler.isRadio || maxMs <= 0)
                                              ? null
                                              : (next) => setState(() {
                                                  _seekPreview = Duration(
                                                    milliseconds: next.round(),
                                                  );
                                                }),
                                          onChangeEnd:
                                              (handler.isRadio || maxMs <= 0)
                                              ? null
                                              : (next) {
                                                  handler.seek(
                                                    Duration(
                                                      milliseconds: next
                                                          .round(),
                                                    ),
                                                  );
                                                  setState(
                                                    () => _seekPreview = null,
                                                  );
                                                },
                                        ),
                                      ),
                                    ),
                                    Text(
                                      _formatPlayerTime(total),
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelSmall
                                          ?.copyWith(
                                            fontFeatures: const [
                                              FontFeature.tabularFigures(),
                                            ],
                                          ),
                                    ),
                                  ],
                                );
                              },
                            ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _scheduleMiniPlayerMeasurement() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final renderObject = _miniPlayerKey.currentContext?.findRenderObject();
      if (renderObject is! RenderBox || !renderObject.hasSize) return;
      final height = renderObject.size.height;
      if (_miniPlayerHeight == null ||
          (_miniPlayerHeight! - height).abs() > 1) {
        setState(() => _miniPlayerHeight = height);
      }
    });
  }

  void _markLyricsUserScrolling(double delta) {
    if (delta == 0 || !mounted || _isUserScrolling) return;
    if (_scrollController.hasClients) {
      final position = _scrollController.position;
      const edgeTolerance = 0.5;
      // Silky reports input before applying the delta. Ignore input trapped
      // against a clamped edge; it did not move the lyrics away from sync.
      if ((delta < 0 &&
              position.pixels <= position.minScrollExtent + edgeTolerance) ||
          (delta > 0 &&
              position.pixels >= position.maxScrollExtent - edgeTolerance)) {
        return;
      }
    } else {
      return;
    }
    setState(() {
      _isUserScrolling = true;
      _pendingAutoScrollIndex = null;
    });
  }

  void _startSyncTimer() {
    _syncTimer?.cancel();
    // Update word timing at 30fps. A 16ms timer woke and rebuilt the active
    // lyric line every display frame, even when no word boundary changed.
    _syncTimer = Timer.periodic(const Duration(milliseconds: 33), (timer) {
      if (!mounted ||
          _loading ||
          lyrics?.syncedLyrics == null ||
          lyrics!.syncedLyrics!.isEmpty) {
        return;
      }

      final playerHandler = GetIt.I<AudioPlayerHandler>();
      // Use real-time audio pipeline position for millisecond-accurate sync
      final position = playerHandler.isRadio
          ? playerHandler.syncedPosition
          : playerHandler.player.position;

      // If paused and position hasn't changed, skip update
      if (_currentPosition == position &&
          !playerHandler.playbackState.value.playing) {
        return;
      }

      final newIndex = _lyricIndexAt(position);

      final previousIndex = _currentIndex;
      final indexChanged = (newIndex != _currentIndex);
      final previousPosition = _currentPosition;
      final wasInInstrumentalGap =
          _instrumentalCardAt(previousPosition, activeIndex: previousIndex) !=
          null;
      final isInInstrumentalGap =
          _instrumentalCardAt(position, activeIndex: newIndex) != null;

      // Rich word highlights are driven by a notifier in the active line.
      // Rebuild this screen only when the active line changes or an
      // instrumental card needs to appear, disappear, or tick its countdown.
      final updateInstrumentalCard =
          wasInInstrumentalGap != isInInstrumentalGap ||
          (isInInstrumentalGap &&
              previousPosition.inSeconds != position.inSeconds);
      _currentPosition = position;
      _positionNotifier.value = position;
      if (indexChanged || updateInstrumentalCard) {
        if (mounted) {
          setState(() {
            _currentIndex = newIndex;
          });
        }
      }

      if (indexChanged && newIndex >= 0 && !_isUserScrolling) {
        _pendingAutoScrollIndex = newIndex;
        final instrumentalLayoutChanged =
            _instrumentalCardAt(previousPosition, activeIndex: previousIndex) !=
            _instrumentalCardAt(position, activeIndex: newIndex);
        if (instrumentalLayoutChanged) {
          _instrumentalLayoutAnimating = true;
        } else if (!_instrumentalLayoutAnimating) {
          _schedulePendingAutoScroll();
        }
      }
    });
  }

  int _lyricIndexAt(Duration position) {
    final lines = lyrics?.syncedLyrics;
    if (lines == null || lines.isEmpty) return -1;
    final positionMs = position.inMilliseconds;
    var low = 0;
    var high = lines.length;
    while (low < high) {
      final middle = (low + high) >> 1;
      final startMs = lines[middle].offset?.inMilliseconds ?? 0;
      if (startMs <= positionMs) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low - 1;
  }

  int? _instrumentalCardAt(Duration position, {int? activeIndex}) {
    final lines = lyrics?.syncedLyrics;
    if (lines == null || lines.isEmpty) return null;
    final positionMs = position.inMilliseconds;
    final firstStartMs = lines.first.offset?.inMilliseconds ?? 0;
    if (firstStartMs >= 5000 && positionMs < firstStartMs) return -1;

    // Find the active line in logarithmic time; lyrics can contain thousands
    // of entries and this check runs on every position tick.
    activeIndex ??= _lyricIndexAt(position);
    if (activeIndex >= 0 && activeIndex + 1 < lines.length) {
      final activeLine = lines[activeIndex];
      final lineEndMs =
          (activeLine.offset?.inMilliseconds ?? 0) +
          (activeLine.duration?.inMilliseconds ?? 3000);
      final nextStartMs =
          lines[activeIndex + 1].offset?.inMilliseconds ?? lineEndMs;
      if (nextStartMs - lineEndMs >= 5000 &&
          positionMs >= lineEndMs &&
          positionMs < nextStartMs) {
        return activeIndex;
      }
    }
    return null;
  }

  void _schedulePendingAutoScroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final index = _pendingAutoScrollIndex;
      if (!mounted ||
          _isUserScrolling ||
          _instrumentalLayoutAnimating ||
          index == null) {
        return;
      }
      _pendingAutoScrollIndex = null;
      if (_currentIndex == index) _scrollToIndex(index);
    });
  }

  void _onInstrumentalLayoutAnimationEnd() {
    _instrumentalLayoutAnimating = false;
    _schedulePendingAutoScroll();
  }

  /// The lyric viewport sits below the provider strip. Keep the lyric center
  /// aligned to the center of the combined provider + lyric area by moving the
  /// target up by half of that strip's height within the scroll viewport.
  double _lyricsCenterInViewport(double viewportHeight) =>
      (viewportHeight - _providerSwitcherHeight) / 2;

  void _scrollToIndex(int index, {bool animated = true}) {
    if (index < 0) {
      if (_lyricKeys.isNotEmpty) {
        index = 0;
      } else {
        return;
      }
    }
    if (index >= _lyricKeys.length) return;
    final key = _lyricKeys[index];
    final keyContext = key.currentContext;
    if (keyContext == null) return;

    final renderBox = keyContext.findRenderObject() as RenderBox?;
    if (renderBox != null &&
        renderBox.hasSize &&
        _scrollController.hasClients) {
      final viewportBox =
          _scrollController.position.context.notificationContext
                  ?.findRenderObject()
              as RenderBox?;

      double targetOffset;
      if (viewportBox != null && viewportBox.hasSize) {
        final itemTopInViewport = renderBox
            .localToGlobal(Offset.zero, ancestor: viewportBox)
            .dy;
        final itemCenterInViewport =
            itemTopInViewport + (renderBox.size.height / 2);
        final viewportCenter = _lyricsCenterInViewport(viewportBox.size.height);
        final delta = itemCenterInViewport - viewportCenter;
        targetOffset = _scrollController.offset + delta;
      } else {
        final viewport = RenderAbstractViewport.of(renderBox);
        targetOffset = viewport.getOffsetToReveal(renderBox, 0.5).offset;
      }

      final clampedOffset = targetOffset.clamp(
        _scrollController.position.minScrollExtent,
        _scrollController.position.maxScrollExtent,
      );
      if (animated) {
        _scrollController.animateTo(
          clampedOffset,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeInOutCubic,
        );
      } else {
        _scrollController.jumpTo(clampedOffset);
      }
      return;
    }

    Scrollable.ensureVisible(
      keyContext,
      duration: Duration(milliseconds: animated ? 220 : 0),
      curve: Curves.easeInOutCubic,
      alignment: 0.5,
    );
  }

  void _scheduleLyricsEdgePaddingMeasurement() {
    if (_edgePaddingMeasurementScheduled || _lyricKeys.isEmpty) {
      return;
    }
    _edgePaddingMeasurementScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _edgePaddingMeasurementScheduled = false;
      if (!mounted || !_scrollController.hasClients || _lyricKeys.isEmpty) {
        return;
      }
      final firstBox =
          _lyricKeys.first.currentContext?.findRenderObject() as RenderBox?;
      final lastBox =
          _lyricKeys.last.currentContext?.findRenderObject() as RenderBox?;
      final position = _scrollController.position;
      final viewportBox =
          position.context.notificationContext?.findRenderObject()
              as RenderBox?;
      if (firstBox == null ||
          lastBox == null ||
          !firstBox.hasSize ||
          !lastBox.hasSize ||
          viewportBox == null ||
          !viewportBox.hasSize) {
        return;
      }

      // Use the same render-box dimensions as the item coordinates below.
      // ScrollPosition.viewportDimension can differ slightly from the box
      // measured by localToGlobal (for example when the scroll view is wrapped
      // in a shader/expanded layout), which skews both edge-padding values.
      final targetCenter = _lyricsCenterInViewport(viewportBox.size.height);
      final firstTop =
          firstBox.localToGlobal(Offset.zero, ancestor: viewportBox).dy +
          position.pixels;
      final lastTop =
          lastBox.localToGlobal(Offset.zero, ancestor: viewportBox).dy +
          position.pixels;
      final firstCenter = firstTop + firstBox.size.height / 2;
      final lastCenterAtEnd =
          lastTop + lastBox.size.height / 2 - position.maxScrollExtent;
      final top = (_lyricEdgePadding.top + targetCenter - firstCenter)
          .clamp(0.0, double.infinity)
          .toDouble();
      final bottom = (_lyricEdgePadding.bottom + lastCenterAtEnd - targetCenter)
          .clamp(0.0, double.infinity)
          .toDouble();
      if ((top - _lyricEdgePadding.top).abs() > 0.5 ||
          (bottom - _lyricEdgePadding.bottom).abs() > 0.5) {
        setState(() {
          _lyricEdgePadding = EdgeInsets.only(top: top, bottom: bottom);
        });
        // The initial auto-scroll can run before this measurement, while the
        // list still has zero edge padding. Re-center the active line after
        // the corrected padding has been laid out so early lyrics do not get
        // clamped against the start of the scroll range.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted ||
              _isUserScrolling ||
              _instrumentalLayoutAnimating ||
              _currentIndex < 0 ||
              _instrumentalCardAt(_currentPosition) != null) {
            return;
          }
          _scrollToIndex(_currentIndex, animated: false);
        });
      }
    });
  }

  Future<void> _updateColor() async {
    if (widget.embedded) return;
    final mediaItem = GetIt.I<AudioPlayerHandler>().mediaItem.value;
    if (mediaItem == null) return;

    if (!settings.themeAdditonalItems &&
        !settings.colorGradientBackground &&
        !settings.blurPlayerBackground) {
      return;
    }

    final artUrl =
        mediaItem.extras?['saturnOriginalArtUri'] ??
        mediaItem.artUri?.toString() ??
        mediaItem.extras?['thumb'] ??
        '';
    if (artUrl.isEmpty) return;

    final imageProvider = CachedNetworkImageProvider(artUrl);

    if (settings.themeAdditonalItems && settings.blurPlayerBackground) {
      if (mounted) {
        setState(() {
          _blurImage = imageProvider;
        });
      }
    }

    try {
      final palette = await imagesDatabase.getPaletteGenerator(artUrl);
      final dominantColor = palette.dominantColor?.color ?? Colors.black;

      if (!mounted) return;

      if (settings.themeAdditonalItems && settings.blurPlayerBackground) {
        SystemChrome.setSystemUIOverlayStyle(
          SystemUiOverlayStyle(
            statusBarColor: dominantColor.withValues(alpha: 0.25),
            systemNavigationBarColor: Color.alphaBlend(
              dominantColor.withValues(alpha: 0.25),
              scaffoldBackgroundColor,
            ),
          ),
        );
      }

      if (settings.themeAdditonalItems &&
          !settings.blurPlayerBackground &&
          settings.colorGradientBackground) {
        setState(() {
          _bgGradient = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              dominantColor.withValues(alpha: settings.isDark ? 0.7 : 0.35),
              const Color.fromARGB(0, 0, 0, 0),
            ],
            stops: const [0.0, 0.6],
          );
        });
      }
    } catch (_) {}
  }

  Future<List<dynamic>> _getAllProviders() async {
    final lyricPlatforms = <MusicPlatform>[];
    for (final platform in PlatformRegistry.instance.allPlatforms) {
      if (!platform.capabilities.supportsLyrics) continue;
      try {
        if (await platform.isLoggedIn()) lyricPlatforms.add(platform);
      } catch (_) {
        // An unavailable login state should not expose this service's
        // provider or prevent other lyrics sources from being shown.
      }
    }
    final mediaItem = GetIt.I<AudioPlayerHandler>().mediaItem.value;
    var currentTrack = mediaItem == null
        ? null
        : Track.fromMediaItem(mediaItem);
    if (currentTrack != null) {
      currentTrack = await _withOfflineLyrics(currentTrack);
    }
    final providers = <dynamic>[
      if (currentTrack?.lyrics?.isLoaded() == true) _offlineLyricsProvider,
      ...lyricPlatforms,
      ...LyricsRegistry.instance.getAll(),
    ];
    final nativePlatformId = currentTrack?.platformId;
    final nativePlatform = nativePlatformId == null
        ? null
        : PlatformRegistry.instance.get(nativePlatformId);
    final preferredPlatformId =
        nativePlatform?.capabilities.supportsLyrics == true
        ? nativePlatformId
        : null;
    final preferredIndex = preferredPlatformId == null
        ? -1
        : providers.indexWhere(
            (provider) =>
                provider is MusicPlatform &&
                provider.platformId == preferredPlatformId,
          );
    final offlineProviderIndex = providers.indexOf(_offlineLyricsProvider);
    final firstPlatformIndex = offlineProviderIndex == 0 ? 1 : 0;
    if (preferredIndex > firstPlatformIndex) {
      final preferred = providers.removeAt(preferredIndex);
      providers.insert(firstPlatformIndex, preferred);
    }
    return providers;
  }

  Widget _buildProviderSwitcher() {
    return FutureBuilder<List<dynamic>>(
      future: _providersFuture,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const SizedBox(height: _providerSwitcherHeight);
        }
        return _buildProviderSwitcherItems(snapshot.data!);
      },
    );
  }

  void _scrollProviderStripBy(double delta) {
    if (!_providerScrollController.hasClients) return;
    final position = _providerScrollController.position;
    _providerScrollController.jumpTo(
      (position.pixels + delta)
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble(),
    );
  }

  Widget _buildProviderSwitcherItems(List<dynamic> allProviders) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8.0),
      height: 44,
      child: Center(
        child: ScrollConfiguration(
          // Flutter's default desktop behavior doesn't let a mouse drag a
          // scroll view. The provider strip should be draggable with a mouse
          // as well as swipeable on touch screens.
          behavior: const MaterialScrollBehavior().copyWith(
            dragDevices: {
              PointerDeviceKind.touch,
              PointerDeviceKind.mouse,
              PointerDeviceKind.stylus,
            },
          ),
          child: Listener(
            onPointerSignal: (event) {
              if (event is! PointerScrollEvent ||
                  !_providerScrollController.hasClients) {
                return;
              }
              final delta = event.scrollDelta.dx != 0
                  ? event.scrollDelta.dx
                  : event.scrollDelta.dy;
              _scrollProviderStripBy(delta);
            },
            onPointerPanZoomUpdate: (event) {
              if (!_providerScrollController.hasClients) return;
              // Trackpads send pan/zoom events instead of wheel events. A
              // positive pan means the fingers moved right/down, so move the
              // horizontal strip in the opposite direction.
              final pan = event.panDelta.dx != 0
                  ? event.panDelta.dx
                  : event.panDelta.dy;
              _scrollProviderStripBy(-pan);
            },
            child: SilkySingleChildScrollView(
              silkyConfig: silkyHorizontalScrollConfig,
              controller: _providerScrollController,
              scrollDirection: Axis.horizontal,
              physics: const AlwaysScrollableScrollPhysics(),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: List.generate(allProviders.length, (index) {
                  final isSelected = _selectedProviderIndex == index;
                  final provider = allProviders[index];
                  final name = provider is MusicPlatform
                      ? provider.platformName
                      : provider is _OfflineLyricsProvider
                      ? provider.name
                      : (provider as LyricsProvider).name;
                  final icon = provider is MusicPlatform
                      ? provider.buildPlatformIcon(size: 16)
                      : provider is _OfflineLyricsProvider
                      ? const Icon(Icons.download_done, size: 16)
                      : const Icon(Icons.lyrics, size: 16);
                  final theme = Theme.of(context);
                  final primary = theme.colorScheme.primary;
                  final isDark = theme.brightness == Brightness.dark;
                  final selectedColor = AppTheme.legibleAccent(
                    primary,
                    isDark: isDark,
                  );
                  final unselectedColor = isDark
                      ? Colors.white70
                      : theme.colorScheme.onSurface.withValues(alpha: 0.70);
                  final unselectedBg = isDark
                      ? Colors.white.withValues(alpha: 0.07)
                      : theme.colorScheme.surfaceContainerHighest.withValues(
                          alpha: 0.40,
                        );
                  final unselectedBorder = isDark
                      ? Colors.white.withValues(alpha: 0.12)
                      : theme.colorScheme.outlineVariant.withValues(
                          alpha: 0.45,
                        );

                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOutCubic,
                      decoration: BoxDecoration(
                        color: isSelected
                            ? primary.withValues(alpha: isDark ? 0.22 : 0.12)
                            : unselectedBg,
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(
                          color: isSelected
                              ? selectedColor.withValues(
                                  alpha: isDark ? 0.8 : 0.6,
                                )
                              : unselectedBorder,
                          width: isSelected ? 1.5 : 1,
                        ),
                      ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(22),
                        onTap: () async {
                          final mediaItem =
                              GetIt.I<AudioPlayerHandler>().mediaItem.value;
                          var track = mediaItem != null
                              ? Track.fromMediaItem(mediaItem)
                              : null;
                          if (track != null) {
                            track = await _withOfflineLyrics(track);
                          }
                          if (!mounted) return;
                          final nativePlatformId = track?.platformId;
                          final isNativePlatform =
                              provider is MusicPlatform &&
                              provider.platformId == nativePlatformId;

                          if (provider is _OfflineLyricsProvider) {
                            _setLyricsDisplayProvider('offline');
                            if (track?.lyrics?.isLoaded() == true) {
                              setState(() {
                                _selectedProviderIndex = index;
                                _selectedLyricsCandidateId = null;
                                _lyricsCandidates = const [];
                              });
                              _syncLyricsChoicesButton();
                              _updateLyricsState(track!.lyrics!);
                            } else {
                              _showLyricsUnavailable();
                            }
                            return;
                          }

                          // Only the track's own platform represents the
                          // default/native lyrics source. The first visible
                          // provider can be another platform (for example,
                          // Deezer while playing a SoundCloud track), and must
                          // use the cross-platform search path below.
                          if (isNativePlatform) {
                            if (_selectedProviderIndex == index &&
                                _selectedLyricsCandidateId == null &&
                                track != null &&
                                _getSavedLyricsChoice(track) == null &&
                                !_loading) {
                              return;
                            }
                            await _resetToDefaultLyrics();
                            return;
                          }

                          if (_selectedProviderIndex == index &&
                              !_loading &&
                              _selectedLyricsCandidateId == null) {
                            return;
                          }
                          final requestId = ++_lyricsLoadGeneration;
                          setState(() {
                            _selectedProviderIndex = index;
                            _loading = true;
                            lyrics = null;
                            _error = false;
                            _lyricsUnavailable = false;
                            _lyricsCandidates = const [];
                            _selectedLyricsCandidateId = null;
                          });
                          _syncLyricsChoicesButton();
                          if (provider is MusicPlatform) {
                            _setLyricsDisplayProvider(
                              'platform:${provider.platformId}',
                            );
                            if (track != null) {
                              _removeSavedLyricsChoice(track);
                              settings.lyricsChoices[_lyricsPreferenceKey(
                                    track,
                                  )] =
                                  'platform:${provider.platformId}';
                              unawaited(settings.save());
                            }
                            await _loadPlatformLyrics(provider, requestId);
                          } else {
                            if (mediaItem == null) {
                              if (mounted &&
                                  requestId == _lyricsLoadGeneration) {
                                _showLyricsUnavailable();
                              }
                              return;
                            }
                            final lyricsProvider = provider as LyricsProvider;
                            _setLyricsDisplayProvider(
                              'provider:${lyricsProvider.id}',
                            );
                            final track = Track.fromMediaItem(mediaItem);
                            _removeSavedLyricsChoice(track);
                            settings.lyricsChoices[_lyricsPreferenceKey(
                                  track,
                                )] =
                                lyricsProvider.id;
                            unawaited(settings.save());

                            try {
                              final candidates = await lyricsProvider
                                  .getLyricsCandidates(track);
                              if (!mounted ||
                                  requestId != _lyricsLoadGeneration) {
                                return;
                              }
                              final usableCandidates =
                                  _distinctUsableCandidates(candidates);
                              if (usableCandidates.isNotEmpty) {
                                final selected = usableCandidates.first;
                                _lyricsCandidates = usableCandidates;
                                _selectedLyricsCandidateId = selected.id;
                                _syncLyricsChoicesButton();
                                _updateLyricsState(selected.lyrics);
                              } else {
                                final l = await lyricsProvider.getLyrics(track);
                                if (!mounted ||
                                    requestId != _lyricsLoadGeneration) {
                                  return;
                                }
                                if (_hasAnyLyrics(l)) {
                                  _lyricsCandidates = const [];
                                  _selectedLyricsCandidateId = null;
                                  _syncLyricsChoicesButton();
                                  _updateLyricsState(l);
                                } else {
                                  _showLyricsUnavailable();
                                }
                              }
                            } catch (_) {
                              if (mounted &&
                                  requestId == _lyricsLoadGeneration) {
                                _showLyricsUnavailable();
                              }
                            }
                          }
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconTheme(
                                data: IconThemeData(
                                  size: 16,
                                  color: isSelected
                                      ? selectedColor
                                      : unselectedColor,
                                ),
                                child: icon,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                name,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: isSelected
                                      ? FontWeight.bold
                                      : FontWeight.w500,
                                  color: isSelected
                                      ? selectedColor
                                      : unselectedColor,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showLyricsCandidateSheet() async {
    final versionCandidates = _lyricsVersionCandidates;
    if (versionCandidates.length < 2) return;
    final selectedId = _selectedLyricsCandidateId;
    final mediaItem = GetIt.I<AudioPlayerHandler>().mediaItem.value;
    final currentTitle = mediaItem?.title;
    final selectedCandidate = versionCandidates
        .where((candidate) => candidate.id == selectedId)
        .firstOrNull;
    final candidate = await showModalBottomSheet<LyricsCandidate>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.58,
        minChildSize: 0.38,
        maxChildSize: 0.9,
        builder: (context, scrollController) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 8),
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context).dividerColor,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Lyrics versions'.i18n,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          currentTitle ??
                              selectedCandidate?.displayTitle ??
                              'Choose a match'.i18n,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                    onPressed: () => Navigator.pop(sheetContext),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: SilkyListView.separated(
                silkyConfig: silkyScrollConfig,
                controller: scrollController,
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: versionCandidates.length,
                separatorBuilder: (context, index) =>
                    const Divider(height: 1, indent: 72),
                itemBuilder: (context, index) {
                  final item = versionCandidates[index];
                  final isSelected = item.id == selectedId;
                  final details = <String>[
                    item.artist,
                    if (item.album?.isNotEmpty == true) item.album!,
                    if (item.duration != null)
                      '${item.duration!.inMinutes}:${(item.duration!.inSeconds % 60).toString().padLeft(2, '0')}',
                  ].where((value) => value.isNotEmpty).join(' · ');
                  final isSynced = item.lyrics.syncedLyrics?.isNotEmpty == true;
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
                      child: Icon(
                        isSelected ? Icons.check : Icons.music_note,
                        color: isSelected
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    title: Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          details,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                        const SizedBox(height: 5),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            _lyricsTypeBadge(
                              isSynced
                                  ? 'Synchronized lyrics'.i18n
                                  : 'Plain text lyrics'.i18n,
                              selected: isSelected,
                            ),
                            if (item.wordSynced)
                              _lyricsTypeBadge(
                                'Word-by-word'.i18n,
                                selected: isSelected,
                              ),
                          ],
                        ),
                      ],
                    ),
                    trailing: isSelected
                        ? Icon(
                            Icons.check_circle,
                            color: Theme.of(context).colorScheme.primary,
                          )
                        : null,
                    tileColor: Colors.transparent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    onTap: () => Navigator.pop(sheetContext, item),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
    if (candidate != null) {
      await _chooseLyricsCandidate(candidate);
    }
  }

  Widget _lyricsTypeBadge(String label, {required bool selected}) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final primary = theme.colorScheme.primary;
    final color = selected
        ? AppTheme.legibleAccent(primary, isDark: isDark)
        : theme.colorScheme.onSurfaceVariant;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildInstrumentalCard({
    required int secondsRemaining,
    VoidCallback? onSkip,
    bool isIntro = false,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final primaryColor = theme.colorScheme.primary;
    final accentColor = AppTheme.legibleAccent(primaryColor, isDark: isDark);

    final content = Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: primaryColor.withValues(alpha: isDark ? 0.22 : 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: primaryColor.withValues(alpha: isDark ? 0.6 : 0.35),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: primaryColor.withValues(alpha: 0.1),
            blurRadius: 10,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.music_note, color: accentColor, size: 18),
          const SizedBox(width: 8),
          Text(
            isIntro
                ? 'Instrumental Intro ($secondsRemaining\s)'
                : 'Instrumental Break ($secondsRemaining\s)',
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: accentColor,
              letterSpacing: 0.3,
            ),
          ),
          if (onSkip != null) ...[
            const SizedBox(width: 8),
            Icon(
              Icons.fast_forward,
              color: accentColor.withValues(alpha: 0.8),
              size: 16,
            ),
          ],
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12.0),
      child: Center(
        child: onSkip != null
            ? InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: onSkip,
                child: content,
              )
            : content,
      ),
    );
  }

  Widget _buildAnimatedInstrumentalCard({
    required bool visible,
    required int secondsRemaining,
    VoidCallback? onSkip,
    bool isIntro = false,
  }) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeInOutCubic,
      alignment: Alignment.topCenter,
      onEnd: _onInstrumentalLayoutAnimationEnd,
      child: visible
          ? _buildInstrumentalCard(
              secondsRemaining: secondsRemaining,
              onSkip: onSkip,
              isIntro: isIntro,
            )
          : const SizedBox.shrink(),
    );
  }

  Widget _buildWordSyncedLine(
    SynchronizedLyric lyric,
    bool isCurrentLine,
    Color textColor,
  ) {
    if (!isCurrentLine) {
      return _buildWordSyncedLineAtPosition(
        lyric,
        false,
        textColor,
        _currentPosition,
      );
    }
    return ValueListenableBuilder<Duration>(
      valueListenable: _positionNotifier,
      builder: (context, position, _) =>
          _buildWordSyncedLineAtPosition(lyric, true, textColor, position),
    );
  }

  Widget _buildWordSyncedLineAtPosition(
    SynchronizedLyric lyric,
    bool isCurrentLine,
    Color textColor,
    Duration position,
  ) {
    final words = lyric.words!;
    final currentPosMs = position.inMilliseconds;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final primaryColor = theme.colorScheme.primary;
    final legibleColor = AppTheme.legibleAccent(primaryColor, isDark: isDark);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          alignment: WrapAlignment.center,
          children: List.generate(words.length, (i) {
            final word = words[i];
            final wordStartMs = word.offset.inMilliseconds;
            final wordEndMs = wordStartMs + word.duration.inMilliseconds;
            final nextWordStartMs = (i + 1 < words.length)
                ? words[i + 1].offset.inMilliseconds
                : null;

            Color wordColor;
            final isPastThisWord =
                (nextWordStartMs != null && currentPosMs >= nextWordStartMs) ||
                (currentPosMs >= wordEndMs);
            final isSinging =
                isCurrentLine && !isPastThisWord && currentPosMs >= wordStartMs;
            if (!isCurrentLine) {
              wordColor = textColor.withValues(alpha: 0.40);
            } else if (isPastThisWord) {
              // Already sung -> fades smoothly back to white
              wordColor = textColor;
            } else if (isSinging) {
              // Currently actively singing this word!
              wordColor = legibleColor;
            } else {
              // Upcoming word in active line
              wordColor = textColor.withValues(alpha: 0.35);
            }

            final wordShadow = [
              Shadow(
                color: primaryColor.withValues(
                  alpha: isSinging ? (isDark ? 0.85 : 0.45) : 0.0,
                ),
                blurRadius: isSinging ? 12.0 : 0.0,
              ),
            ];

            return AnimatedDefaultTextStyle(
              duration: isSinging
                  ? const Duration(milliseconds: 60)
                  : const Duration(milliseconds: 250),
              curve: isSinging ? Curves.easeOut : Curves.easeOutQuad,
              style: TextStyle(
                color: wordColor,
                fontWeight: FontWeight.bold,
                fontSize: 26.0,
                shadows: wordShadow,
                letterSpacing: 0.2,
              ),
              child: Text(word.text),
            );
          }),
        ),
        _buildLyricOverlays(lyric),
      ],
    );
  }

  Widget _buildLineByLineText(
    SynchronizedLyric lyric,
    bool isCurrentLine,
    Color textColor,
  ) {
    final theme = Theme.of(context);
    final primaryColor = theme.colorScheme.primary;
    final isDark = theme.brightness == Brightness.dark;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOut,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 26.0,
            fontWeight: FontWeight.bold,
            color: isCurrentLine
                ? textColor
                : textColor.withValues(alpha: 0.40),
            letterSpacing: 0.2,
            shadows: [
              Shadow(
                color: primaryColor.withValues(
                  alpha: isCurrentLine ? (isDark ? 0.4 : 0.2) : 0.0,
                ),
                blurRadius: isCurrentLine ? 12.0 : 0.0,
              ),
            ],
          ),
          child: Text(lyric.text ?? ''),
        ),
        _buildLyricOverlays(lyric),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.embedded) _scheduleMiniPlayerMeasurement();
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final textColor = isDark
        ? Colors.white
        : (theme.textTheme.bodyLarge?.color ?? Colors.black);
    final primaryColor = theme.colorScheme.primary;
    final audioHandler = GetIt.I<AudioPlayerHandler>();
    final isRadioPlayback =
        audioHandler.isRadio ||
        AudioPlayerHandler.isRadioItem(audioHandler.mediaItem.value);

    final syncedList = lyrics?.syncedLyrics ?? [];
    final currentPosMs = _currentPosition.inMilliseconds;

    final topPadding = widget.embedded
        ? 0.0
        : MediaQuery.of(context).padding.top + kToolbarHeight;

    final body = Stack(
      children: [
        // Background (Blur Image or Gradient)
        if (!widget.embedded &&
            settings.themeAdditonalItems &&
            settings.blurPlayerBackground &&
            _blurImage != null)
          ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      image: DecorationImage(
                        image: _blurImage!,
                        fit: BoxFit.cover,
                        colorFilter: ColorFilter.mode(
                          (isDark ? Colors.black : Colors.white).withValues(
                            alpha: isDark ? 0.35 : 0.70,
                          ),
                          isDark ? BlendMode.darken : BlendMode.lighten,
                        ),
                      ),
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
                Container(
                  color: (isDark ? Colors.black : Colors.white).withValues(
                    alpha: isDark ? 0.2 : 0.35,
                  ),
                ),
              ],
            ),
          )
        else if (!widget.embedded && _bgGradient != null)
          Container(decoration: BoxDecoration(gradient: _bgGradient)),

        // Main Lyrics Body
        Padding(
          padding: EdgeInsets.only(top: topPadding),
          child: Column(
            children: [
              _buildProviderSwitcher(),
              Expanded(
                child: ShaderMask(
                  blendMode: BlendMode.dstIn,
                  shaderCallback: (bounds) => const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black,
                      Colors.black,
                      Colors.transparent,
                    ],
                    stops: [0.0, 0.09, 0.91, 1.0],
                  ).createShader(bounds),
                  child: SizedBox.expand(
                    child: _error
                        ? Transform.translate(
                            offset: const Offset(
                              0,
                              -_providerSwitcherHeight / 2,
                            ),
                            child: Center(
                              child: ErrorScreen(message: _errorMessage),
                            ),
                          )
                        : _loading
                        ? Transform.translate(
                            offset: const Offset(
                              0,
                              -_providerSwitcherHeight / 2,
                            ),
                            child: Center(
                              child: CircularProgressIndicator(
                                color: primaryColor,
                              ),
                            ),
                          )
                        : _lyricsUnavailable
                        ? Transform.translate(
                            offset: const Offset(
                              0,
                              -_providerSwitcherHeight / 2,
                            ),
                            child: _buildLyricsUnavailable(
                              textColor,
                              primaryColor,
                            ),
                          )
                        : LayoutBuilder(
                            builder: (context, _) {
                              _scheduleLyricsEdgePaddingMeasurement();
                              return NotificationListener<
                                ScrollUpdateNotification
                              >(
                                onNotification: (notification) {
                                  if (notification.dragDetails != null) {
                                    _markLyricsUserScrolling(
                                      notification.scrollDelta ?? 0,
                                    );
                                  }
                                  return false;
                                },
                                child: Listener(
                                  onPointerSignal: (event) {
                                    if (event is PointerScrollEvent) {
                                      _markLyricsUserScrolling(
                                        event.scrollDelta.dy,
                                      );
                                    }
                                  },
                                  child: SingleChildScrollView(
                                    controller: _scrollController,
                                    physics:
                                        const AlwaysScrollableScrollPhysics(
                                          parent: ClampingScrollPhysics(),
                                        ),
                                    padding: EdgeInsets.only(
                                      left: 16,
                                      right: 16,
                                      top: _lyricEdgePadding.top,
                                      bottom: _lyricEdgePadding.bottom,
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        // Instrumental intro gap before the first lyric.
                                        if (syncedList.isNotEmpty &&
                                            (syncedList
                                                        .first
                                                        .offset
                                                        ?.inMilliseconds ??
                                                    0) >=
                                                5000)
                                          _buildAnimatedInstrumentalCard(
                                            visible:
                                                currentPosMs <
                                                (syncedList
                                                        .first
                                                        .offset
                                                        ?.inMilliseconds ??
                                                    0),
                                            isIntro: true,
                                            secondsRemaining:
                                                ((syncedList
                                                                .first
                                                                .offset!
                                                                .inMilliseconds -
                                                            currentPosMs) /
                                                        1000)
                                                    .ceil(),
                                            onSkip: isRadioPlayback
                                                ? null
                                                : () {
                                                    final target =
                                                        syncedList
                                                            .first
                                                            .offset! -
                                                        const Duration(
                                                          milliseconds: 500,
                                                        );
                                                    GetIt.I<
                                                          AudioPlayerHandler
                                                        >()
                                                        .seek(
                                                          target < Duration.zero
                                                              ? Duration.zero
                                                              : target,
                                                        );
                                                    setState(
                                                      () => _isUserScrolling =
                                                          false,
                                                    );
                                                  },
                                          ),

                                        // Synchronized lyrics lines
                                        if (syncedList.isNotEmpty)
                                          ...List.generate(syncedList.length, (
                                            i,
                                          ) {
                                            final lyric = syncedList[i];
                                            final isCurrentLine =
                                                (_currentIndex == i);
                                            final nextLyric =
                                                i + 1 < syncedList.length
                                                ? syncedList[i + 1]
                                                : null;
                                            final lineEndMs =
                                                (lyric.offset?.inMilliseconds ??
                                                    0) +
                                                (lyric
                                                        .duration
                                                        ?.inMilliseconds ??
                                                    3000);
                                            final nextStartMs =
                                                nextLyric
                                                    ?.offset
                                                    ?.inMilliseconds ??
                                                lineEndMs;
                                            final showBreakAfter =
                                                nextStartMs - lineEndMs >=
                                                    5000 &&
                                                currentPosMs >= lineEndMs &&
                                                currentPosMs < nextStartMs;
                                            final breakSecondsRemaining =
                                                ((nextStartMs - currentPosMs) /
                                                        1000)
                                                    .ceil();

                                            return Column(
                                              children: [
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        vertical: 4.0,
                                                      ),
                                                  child: Container(
                                                    key: _lyricKeys.length > i
                                                        ? _lyricKeys[i]
                                                        : null,
                                                    decoration: BoxDecoration(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            16.0,
                                                          ),
                                                      color: isCurrentLine
                                                          ? primaryColor
                                                                .withValues(
                                                                  alpha: isDark
                                                                      ? 0.12
                                                                      : 0.10,
                                                                )
                                                          : Colors.transparent,
                                                    ),
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                          horizontal: 14.0,
                                                          vertical: 8.0,
                                                        ),
                                                    child: Center(
                                                      child: GestureDetector(
                                                        behavior:
                                                            HitTestBehavior
                                                                .opaque,
                                                        onTap: isRadioPlayback
                                                            ? null
                                                            : () {
                                                                final offset =
                                                                    lyric
                                                                        .offset;
                                                                if (offset !=
                                                                    null) {
                                                                  GetIt.I<
                                                                        AudioPlayerHandler
                                                                      >()
                                                                      .seek(
                                                                        offset,
                                                                      );
                                                                  setState(() {
                                                                    _isUserScrolling =
                                                                        false;
                                                                  });
                                                                  _scrollToIndex(
                                                                    i,
                                                                  );
                                                                }
                                                              },
                                                        child:
                                                            lyric.words !=
                                                                    null &&
                                                                lyric
                                                                    .words!
                                                                    .isNotEmpty
                                                            ? _buildWordSyncedLine(
                                                                lyric,
                                                                isCurrentLine,
                                                                textColor,
                                                              )
                                                            : _buildLineByLineText(
                                                                lyric,
                                                                isCurrentLine,
                                                                textColor,
                                                              ),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                                _buildAnimatedInstrumentalCard(
                                                  visible: showBreakAfter,
                                                  secondsRemaining:
                                                      breakSecondsRemaining,
                                                  onSkip: isRadioPlayback
                                                      ? null
                                                      : () {
                                                          final target =
                                                              (nextLyric
                                                                      ?.offset ??
                                                                  Duration
                                                                      .zero) -
                                                              const Duration(
                                                                milliseconds:
                                                                    500,
                                                              );
                                                          GetIt.I<
                                                                AudioPlayerHandler
                                                              >()
                                                              .seek(
                                                                target <
                                                                        Duration
                                                                            .zero
                                                                    ? Duration
                                                                          .zero
                                                                    : target,
                                                              );
                                                          setState(
                                                            () =>
                                                                _isUserScrolling =
                                                                    false,
                                                          );
                                                        },
                                                ),
                                              ],
                                            );
                                          }),

                                        // Unsynchronized lyrics fallback
                                        if (syncedList.isEmpty &&
                                            lyrics?.unsyncedLyrics != null &&
                                            lyrics!.unsyncedLyrics!.isNotEmpty)
                                          Padding(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 16.0,
                                              vertical: 24.0,
                                            ),
                                            child: SelectableText(
                                              lyrics!.unsyncedLyrics!,
                                              textAlign: TextAlign.center,
                                              style: TextStyle(
                                                fontSize: 22.0,
                                                height: 1.8,
                                                color: textColor.withValues(
                                                  alpha: 0.9,
                                                ),
                                              ),
                                            ),
                                          ),
                                        if (syncedList.isEmpty &&
                                            (lyrics
                                                        ?.unsyncedTranslatedLyrics
                                                        ?.isNotEmpty ==
                                                    true ||
                                                lyrics
                                                        ?.unsyncedRomanizedLyrics
                                                        ?.isNotEmpty ==
                                                    true))
                                          Padding(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 16,
                                              vertical: 12,
                                            ),
                                            child: Column(
                                              children: [
                                                if (_showTranslation &&
                                                    lyrics
                                                            ?.unsyncedTranslatedLyrics
                                                            ?.isNotEmpty ==
                                                        true)
                                                  SelectableText(
                                                    lyrics!
                                                        .unsyncedTranslatedLyrics!,
                                                    textAlign: TextAlign.center,
                                                    style: TextStyle(
                                                      fontSize: 18,
                                                      height: 1.6,
                                                      color: textColor
                                                          .withValues(
                                                            alpha: 0.85,
                                                          ),
                                                    ),
                                                  ),
                                                if (_showRomanization &&
                                                    lyrics
                                                            ?.unsyncedRomanizedLyrics
                                                            ?.isNotEmpty ==
                                                        true)
                                                  SelectableText(
                                                    lyrics!
                                                        .unsyncedRomanizedLyrics!,
                                                    textAlign: TextAlign.center,
                                                    style: TextStyle(
                                                      fontSize: 15,
                                                      height: 1.5,
                                                      color: textColor
                                                          .withValues(
                                                            alpha: 0.65,
                                                          ),
                                                      fontStyle:
                                                          FontStyle.italic,
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ),
              ),
              if (!widget.embedded) _buildMiniPlayer(),
            ],
          ),
        ),

        if (syncedList.isNotEmpty)
          Positioned(
            bottom:
                (widget.embedded
                    ? 0
                    : (_miniPlayerHeight ??
                          MediaQuery.paddingOf(context).bottom + 64)) +
                12,
            left: 0,
            right: 0,
            child: AnimatedSlide(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOutCubic,
              offset: _isUserScrolling ? Offset.zero : const Offset(0, 0.6),
              child: AnimatedOpacity(
                duration: Duration(milliseconds: _isUserScrolling ? 200 : 100),
                opacity: _isUserScrolling ? 1 : 0,
                child: Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                      child: Material(
                        color: (isDark ? Colors.black : Colors.white)
                            .withValues(alpha: isDark ? 0.40 : 0.70),
                        child: InkWell(
                          onTap: () {
                            setState(() {
                              _isUserScrolling = false;
                              _pendingAutoScrollIndex = _currentIndex;
                            });
                            if (!_instrumentalLayoutAnimating) {
                              _schedulePendingAutoScroll();
                            }
                          },
                          borderRadius: BorderRadius.circular(24),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(
                                color: primaryColor.withValues(alpha: 0.6),
                                width: 1.5,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.sync, size: 18, color: primaryColor),
                                const SizedBox(width: 8),
                                Text(
                                  'Back to sync'.i18n,
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    color: textColor,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );

    if (widget.embedded) return body;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: FreezerAppBar(
        appBarTitle,
        enableBlur: true,
        opacity: 0,
        blurStrength: 15.0,
      ),
      body: body,
    );
  }
}
