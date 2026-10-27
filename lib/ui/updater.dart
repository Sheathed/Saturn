import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:silky_scroll/silky_scroll.dart';
import 'package:saturn/ui/smooth_scroll_config.dart';

import 'elements.dart';

class UpdaterScreen extends StatefulWidget {
  const UpdaterScreen({super.key});

  @override
  State<UpdaterScreen> createState() => _UpdaterScreenState();
}

class _UpdaterScreenState extends State<UpdaterScreen> {
  bool _loading = true;
  String? _errorMessage;
  String? _latestVersion;
  String? _changelog;
  String? _updateUrl;
  String? _currentVersion;

  bool get _updateAvailable =>
      _latestVersion != null &&
      _currentVersion != null &&
      _compareVersions(_latestVersion!, _currentVersion!) > 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _errorMessage = null;
    });
    try {
      final info = await PackageInfo.fromPlatform();
      final response = await http.get(
        Uri.parse(
          'https://api.github.com/repos/Sheathed/Saturn/releases/latest',
        ),
        headers: const {'Accept': 'application/vnd.github+json'},
      );
      if (response.statusCode != 200) {
        throw Exception('GitHub returned HTTP ${response.statusCode}');
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final tag = data['tag_name'] as String?;
      if (tag == null || tag.trim().isEmpty) {
        throw const FormatException('The release response had no version tag.');
      }
      if (!mounted) return;
      setState(() {
        _currentVersion = info.version;
        _latestVersion = tag.replaceFirst(RegExp(r'^v'), '');
        _changelog = data['body'] as String?;
        _updateUrl = data['html_url'] as String?;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = error.toString();
        _loading = false;
      });
    }
  }

  int _compareVersions(String left, String right) {
    final leftParts = RegExp(
      r'\d+',
    ).allMatches(left.split('+').first).map((m) => int.parse(m[0]!));
    final rightParts = RegExp(
      r'\d+',
    ).allMatches(right.split('+').first).map((m) => int.parse(m[0]!));
    final a = leftParts.toList();
    final b = rightParts.toList();
    final length = a.length > b.length ? a.length : b.length;
    for (var index = 0; index < length; index++) {
      final comparison = (index < a.length ? a[index] : 0).compareTo(
        index < b.length ? b[index] : 0,
      );
      if (comparison != 0) return comparison;
    }
    return 0;
  }

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
                          child: SelectableText(
                            (_changelog?.trim().isNotEmpty ?? false)
                                ? _changelog!.trim()
                                : 'No release notes were provided for this version.',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              height: 1.55,
                            ),
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
