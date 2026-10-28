import 'package:material_ui/material_ui.dart';
import 'package:saturn/ui/elements.dart';
import 'package:silky_scroll/silky_scroll.dart';
import 'package:saturn/ui/smooth_scroll_config.dart';

import '../api/cache.dart';
import '../platform/music_platform.dart';
import '../platform/platform_manager.dart';
import '../platform/platform_registry.dart';
import '../translations.i18n.dart';
import 'home_screen.dart';
import 'login_components.dart';
import 'settings_screen.dart';
import '../utils/logging.dart';

/// The main login screen that allows users to pick a platform
/// and renders that platform's specific login UI.
class PlatformLoginScreen extends StatefulWidget {
  final Function? callback;
  const PlatformLoginScreen({required this.callback, super.key});

  @override
  State<PlatformLoginScreen> createState() => _PlatformLoginScreenState();
}

class _PlatformLoginScreenState extends State<PlatformLoginScreen> {
  final Set<String> _expandedPlatforms = {};
  bool _initializedExpansion = false;

  void _ensureInitialExpansion(
    List<MusicPlatform> all,
    List<MusicPlatform> loggedIn,
  ) {
    if (_initializedExpansion) return;
    _initializedExpansion = true;
    if (loggedIn.isEmpty && all.isNotEmpty) {
      final activeId = PlatformManager.instance.activePlatformId;
      _expandedPlatforms.add(activeId);
    }
  }

  Future<void> _openSettings() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (context) => const SettingsScreen()));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final allPlatforms = PlatformRegistry.instance.allPlatforms;

    return Scaffold(
      appBar: FreezerAppBar(
        'Accounts & Platforms'.i18n,
        actions: [
          IconButton(
            icon: const UpdateAwareSettingsIcon(),
            tooltip: 'Settings'.i18n,
            onPressed: _openSettings,
          ),
        ],
      ),
      body: FutureBuilder<List<MusicPlatform>>(
        future: PlatformRegistry.instance.loggedInPlatforms,
        builder: (context, snapshot) {
          final loggedInPlatforms = snapshot.data ?? [];
          _ensureInitialExpansion(allPlatforms, loggedInPlatforms);

          return Center(
            child: SilkySingleChildScrollView(
              silkyConfig: silkyScrollConfig,
              padding: const EdgeInsets.symmetric(
                horizontal: 16.0,
                vertical: 8.0,
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 600),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const FreezerTitle(),
                    const SizedBox(height: 8),
                    Text(
                      'Connect at least one streaming platform to start listening.\nYou only need one connected platform to use Saturn.'
                          .i18n,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(
                          context,
                        ).textTheme.bodyMedium?.color?.withValues(alpha: 0.75),
                      ),
                    ),
                    const SizedBox(height: 24),
                    ...allPlatforms.map(
                      (p) => _buildPlatformCard(p, loggedInPlatforms),
                    ),
                    const SizedBox(height: 24),
                    LoginPrimaryButton(
                      label: loggedInPlatforms.isEmpty
                          ? 'Connect a platform to continue'.i18n
                          : 'Continue'.i18n,
                      icon: Icons.arrow_forward,
                      height: 50.0,
                      onPressed: loggedInPlatforms.isEmpty
                          ? null
                          : () {
                              if (!loggedInPlatforms.any(
                                (p) =>
                                    p.platformId ==
                                    PlatformManager.instance.activePlatformId,
                              )) {
                                PlatformManager.instance.switchPlatform(
                                  loggedInPlatforms.first.platformId,
                                );
                              }
                              if (widget.callback != null) {
                                widget.callback!();
                              } else {
                                Navigator.of(context).pop();
                              }
                            },
                    ),
                    const SizedBox(height: 16),
                    Center(
                      child: TextButton.icon(
                        icon: const UpdateAwareSettingsIcon(size: 18),
                        label: Text('Settings'.i18n),
                        onPressed: _openSettings,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '2k${DateTime.now().year % 100} saturn.kim',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(
                          context,
                        ).textTheme.bodySmall?.color?.withValues(alpha: 0.5),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildPlatformCard(
    MusicPlatform p,
    List<MusicPlatform> loggedInPlatforms,
  ) {
    final isLoggedIn = loggedInPlatforms.any(
      (element) => element.platformId == p.platformId,
    );
    final isActive = PlatformManager.instance.activePlatformId == p.platformId;
    final isExpanded = _expandedPlatforms.contains(p.platformId);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8.0),
      elevation: isLoggedIn ? 1.5 : 0.5,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16.0),
        side: BorderSide(
          color: isActive && isLoggedIn
              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.6)
              : Theme.of(
                  context,
                ).colorScheme.outlineVariant.withValues(alpha: 0.3),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: isLoggedIn
                  ? null
                  : () {
                      setState(() {
                        if (isExpanded) {
                          _expandedPlatforms.remove(p.platformId);
                        } else {
                          _expandedPlatforms.add(p.platformId);
                        }
                      });
                    },
              child: Row(
                children: [
                  p.buildPlatformIcon(size: 28),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          p.platformName,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (isLoggedIn && p.currentUserName != null)
                          Text(
                            p.currentUserName!,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.color
                                      ?.withValues(alpha: 0.7),
                                ),
                          ),
                      ],
                    ),
                  ),
                  if (isLoggedIn) ...[
                    if (isActive)
                      Padding(
                        padding: const EdgeInsets.only(right: 6.0),
                        child: Chip(
                          label: Text('Active'.i18n),
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          labelStyle: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                          backgroundColor: Theme.of(
                            context,
                          ).colorScheme.primaryContainer,
                        ),
                      ),
                    Chip(
                      label: Text('Connected'.i18n),
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      labelStyle: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                      backgroundColor: Colors.green.withValues(alpha: 0.2),
                    ),
                  ] else ...[
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                      ),
                      icon: Icon(
                        isExpanded ? Icons.expand_less : Icons.expand_more,
                        size: 18,
                      ),
                      label: Text(isExpanded ? 'Hide'.i18n : 'Connect'.i18n),
                      onPressed: () {
                        setState(() {
                          if (isExpanded) {
                            _expandedPlatforms.remove(p.platformId);
                          } else {
                            _expandedPlatforms.add(p.platformId);
                          }
                        });
                      },
                    ),
                  ],
                ],
              ),
            ),
            if (isLoggedIn) ...[
              const SizedBox(height: 12),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (!isActive)
                    OutlinedButton(
                      onPressed: () {
                        PlatformManager.instance.switchPlatform(p.platformId);
                        setState(() {});
                      },
                      child: Text('Set as Active'.i18n),
                    ),

                  OutlinedButton.icon(
                    icon: const Icon(Icons.logout, size: 16),
                    label: Text('Log out'.i18n),
                    onPressed: () async {
                      await p.logout();
                      await PlatformManager.instance.refreshLoggedInStatus();
                      setState(() {});
                    },
                  ),
                ],
              ),
            ] else if (isExpanded) ...[
              const Divider(height: 24),
              p.buildLoginWidget(
                onSuccess: () async {
                  PlatformManager.instance.switchPlatform(p.platformId);
                  if (mounted) setState(() {});
                  if (p.capabilities.supportsLibrarySync) {
                    try {
                      cache.activeLibraryTracks =
                          (await p.getFavoriteTrackIds()) ?? [];
                      cache.activeLibraryPlaylists =
                          (await p.getFavoritePlaylistIds()) ?? [];
                      await cache.save();
                    } catch (error) {
                      appLogger.warning(
                        'Could not cache platform favorites',
                        error,
                      );
                    }
                  }
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}
