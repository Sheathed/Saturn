import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:silky_scroll/silky_scroll.dart';
import 'package:saturn/ui/smooth_scroll_config.dart';

import 'elements.dart';
import '../utils/update_service.dart';

class UpdaterScreen extends StatefulWidget {
  const UpdaterScreen({super.key});

  @override
  State<UpdaterScreen> createState() => _UpdaterScreenState();
}

class _UpdaterScreenState extends State<UpdaterScreen> {
  UpdateService get _updates => UpdateService.instance;
  bool get _loading => _updates.isChecking;
  String? get _errorMessage => _updates.errorMessage;
  String? get _latestVersion => _updates.latestVersion;
  String? get _changelog => _updates.changelog;
  String? get _updateUrl => _updates.releasePageUrl;
  String? get _currentVersion => _updates.currentVersion;
  bool get _updateAvailable => _updates.updateAvailable;

  @override
  void initState() {
    super.initState();
    _updates.addListener(_onUpdateChanged);
    // checkForUpdates notifies listeners immediately when it starts. This page
    // can be mounted inside SettingsScreen's Builder, whose parent also listens
    // to UpdateService; starting the check here would mark that parent dirty
    // while Flutter is still mounting the route.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  void _onUpdateChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _updates.removeListener(_onUpdateChanged);
    super.dispose();
  }

  Future<void> _load() => _updates.checkForUpdates();

  Future<void> _openRelease() async {
    final url = _updateUrl;
    if (url == null) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Widget _versionCard({
    required BuildContext context,
    required String label,
    required String version,
    required IconData icon,
  }) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.42),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            Icon(icon, color: theme.colorScheme.primary),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: theme.textTheme.bodyMedium),
                  const SizedBox(height: 4),
                  Text(
                    version,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final markdownText = theme.colorScheme.onSurface;
    final markdownBody = theme.textTheme.bodyMedium?.copyWith(
      color: markdownText,
      height: 1.55,
    );
    final statusColor = _updateAvailable
        ? theme.colorScheme.primary
        : Colors.green;

    return Scaffold(
      appBar: FreezerAppBar(
        'Updates',
        actions: [
          IconButton(
            tooltip: 'Check again',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: theme.colorScheme.primary),
                  const SizedBox(height: 16),
                  const Text('Checking for updates…'),
                ],
              ),
            )
          : _errorMessage != null
          ? Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.cloud_off_outlined,
                        size: 44,
                        color: theme.colorScheme.error,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Couldn’t check for updates',
                        style: theme.textTheme.titleLarge,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _errorMessage!,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        onPressed: _load,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Try again'),
                      ),
                    ],
                  ),
                ),
              ),
            )
          : LayoutBuilder(
              builder: (context, constraints) => Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 960),
                  child: SilkyListView(
                    silkyConfig: silkyScrollConfig,
                    padding: const EdgeInsets.all(24),
                    children: [
                      Card(
                        margin: EdgeInsets.zero,
                        elevation: 0,
                        color: statusColor.withValues(alpha: 0.10),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                          side: BorderSide(
                            color: statusColor.withValues(alpha: 0.35),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(22),
                          child: Row(
                            children: [
                              Icon(
                                _updateAvailable
                                    ? Icons.system_update_alt
                                    : Icons.check_circle_outline,
                                size: 34,
                                color: statusColor,
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _updateAvailable
                                          ? 'An update is available'
                                          : 'You’re up to date',
                                      style: theme.textTheme.titleLarge
                                          ?.copyWith(
                                            fontWeight: FontWeight.bold,
                                          ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      _updateAvailable
                                          ? 'Version $_latestVersion is ready to download.'
                                          : 'You’re running the latest release of Saturn.',
                                      style: theme.textTheme.bodyMedium,
                                    ),
                                  ],
                                ),
                              ),
                              if (_updateAvailable)
                                FilledButton.icon(
                                  onPressed: _openRelease,
                                  icon: const Icon(Icons.open_in_new),
                                  label: const Text('View update'),
                                ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      if (constraints.maxWidth >= 620)
                        Row(
                          children: [
                            Expanded(
                              child: _versionCard(
                                context: context,
                                label: 'Installed version',
                                version: _currentVersion ?? 'Unknown',
                                icon: Icons.install_mobile_outlined,
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: _versionCard(
                                context: context,
                                label: 'Latest release',
                                version: _latestVersion ?? 'Unknown',
                                icon: Icons.new_releases_outlined,
                              ),
                            ),
                          ],
                        )
                      else ...[
                        _versionCard(
                          context: context,
                          label: 'Installed version',
                          version: _currentVersion ?? 'Unknown',
                          icon: Icons.install_mobile_outlined,
                        ),
                        const SizedBox(height: 12),
                        _versionCard(
                          context: context,
                          label: 'Latest release',
                          version: _latestVersion ?? 'Unknown',
                          icon: Icons.new_releases_outlined,
                        ),
                      ],
                      const SizedBox(height: 24),
                      Text('Release notes', style: theme.textTheme.titleLarge),
                      const SizedBox(height: 10),
                      Card(
                        margin: EdgeInsets.zero,
                        elevation: 0,
                        color: theme.colorScheme.surfaceContainerHighest
                            .withValues(alpha: 0.28),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: BorderSide(
                            color: theme.colorScheme.outlineVariant,
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: MarkdownBody(
                            data: (_changelog?.trim().isNotEmpty ?? false)
                                ? _changelog!.trim()
                                : 'No release notes were provided for this version.',
                            selectable: true,
                            styleSheet: MarkdownStyleSheet(
                              a: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.primary,
                                decoration: TextDecoration.underline,
                              ),
                              p: markdownBody,
                              h1: theme.textTheme.headlineSmall?.copyWith(
                                color: markdownText,
                              ),
                              h2: theme.textTheme.titleLarge?.copyWith(
                                color: markdownText,
                              ),
                              h3: theme.textTheme.titleMedium?.copyWith(
                                color: markdownText,
                              ),
                              h4: theme.textTheme.bodyLarge?.copyWith(
                                color: markdownText,
                              ),
                              h5: theme.textTheme.bodyLarge?.copyWith(
                                color: markdownText,
                              ),
                              h6: theme.textTheme.bodyLarge?.copyWith(
                                color: markdownText,
                              ),
                              code: markdownBody?.copyWith(
                                color: markdownText,
                                fontFamily: 'monospace',
                              ),
                              em: TextStyle(
                                color: markdownText,
                                fontStyle: FontStyle.italic,
                              ),
                              strong: TextStyle(
                                color: markdownText,
                                fontWeight: FontWeight.bold,
                              ),
                              del: TextStyle(
                                color: markdownText,
                                decoration: TextDecoration.lineThrough,
                              ),
                              blockquote: markdownBody,
                              img: markdownBody,
                              checkbox: TextStyle(color: markdownText),
                              listBullet: markdownBody,
                              tableHead: TextStyle(
                                color: markdownText,
                                fontWeight: FontWeight.w600,
                              ),
                              tableBody: markdownBody,
                              blockquoteDecoration: BoxDecoration(
                                color: theme.colorScheme.surfaceContainerHigh,
                                border: Border(
                                  left: BorderSide(
                                    color: theme.colorScheme.primary,
                                    width: 3,
                                  ),
                                ),
                              ),
                              tableBorder: TableBorder.all(
                                color: theme.colorScheme.outlineVariant,
                              ),
                            ),
                            onTapLink: (text, href, title) {
                              if (href == null) return;
                              final uri = Uri.tryParse(href);
                              if (uri != null) {
                                unawaited(
                                  launchUrl(
                                    uri,
                                    mode: LaunchMode.externalApplication,
                                  ),
                                );
                              }
                            },
                          ),
                        ),
                      ),
                      if (!_updateAvailable && _updateUrl != null) ...[
                        const SizedBox(height: 12),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: _openRelease,
                            icon: const Icon(Icons.open_in_new),
                            label: const Text('View release on GitHub'),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}
