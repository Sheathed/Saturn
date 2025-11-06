import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

class UpdaterScreen extends StatefulWidget {
  const UpdaterScreen({super.key});

  @override
  _UpdaterScreenState createState() => _UpdaterScreenState();
}

class _UpdaterScreenState extends State<UpdaterScreen> {
  bool _loading = true;
  String? _errorMessage;
  String? _latestVersion;
  String? _changelog;
  String? _updateUrl;
  String? _currentVersion;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      PackageInfo info = await PackageInfo.fromPlatform();
      _currentVersion = info.version;

      final response = await http.get(Uri.parse(
          'https://api.github.com/repos/Sheathed/Saturn/releases/latest'));
      if (response.statusCode != 200) {
        throw Exception('Failed to fetch release info');
      }
      final data = jsonDecode(response.body);
      final latestVersionRaw = data['tag_name']; // e.g. "v1.2.3"
      final latestVersion = latestVersionRaw.replaceFirst(
          RegExp(r'^v'), ''); // removes leading 'v'
      final changelog = data['body']; // release notes
      final updateUrl = data['html_url']; // link to release page

      setState(() {
        _latestVersion = latestVersion;
        _changelog = changelog;
        _updateUrl = updateUrl;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Updates'),
        backgroundColor: Theme.of(context).primaryColor, // <-- Add this line
        foregroundColor: Theme.of(context)
            .colorScheme
            .onPrimary, // Ensures text/icon contrast
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'Error: $_errorMessage',
                      style: const TextStyle(color: Colors.red),
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text(
                      'Current version: $_currentVersion',
                      style: const TextStyle(fontSize: 16),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Latest version: $_latestVersion',
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Changelog:',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Text(_changelog ?? '',
                        style: const TextStyle(fontSize: 16)),
                    const SizedBox(height: 24),
                    if (_latestVersion != null &&
                        _currentVersion != null &&
                        _latestVersion != _currentVersion)
                      ElevatedButton(
                        child: const Text('Go to update page'),
                        onPressed: () async {
                          if (_updateUrl != null &&
                              await canLaunchUrl(Uri.parse(_updateUrl!))) {
                            await launchUrl(Uri.parse(_updateUrl!));
                          }
                        },
                      )
                    else
                      const Text(
                        'You are running the latest version.',
                        style: TextStyle(fontSize: 16, color: Colors.green),
                        textAlign: TextAlign.center,
                      ),
                  ],
                ),
    );
  }
}
