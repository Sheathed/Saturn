import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:silky_scroll/silky_scroll.dart';
import 'package:saturn/ui/smooth_scroll_config.dart';

import '../translations.i18n.dart';
import 'elements.dart';

class ApplicationLogViewer extends StatefulWidget {
  const ApplicationLogViewer({super.key});

  @override
  _ApplicationLogViewerState createState() => _ApplicationLogViewerState();
}

class _ApplicationLogViewerState extends State<ApplicationLogViewer> {
  List<String> data = [];

  String get _logText => data.join('\n');

  Future<void> _copyLogs() async {
    await Clipboard.setData(ClipboardData(text: _logText));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Log copied to clipboard'.i18n),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _saveLogs() async {
    try {
      final fileName =
          'saturn_application_log_${DateTime.now().millisecondsSinceEpoch}.txt';
      final path = await FilePicker.saveFile(
        dialogTitle: 'Save application log'.i18n,
        fileName: fileName,
        bytes: Uint8List.fromList(utf8.encode(_logText)),
      );
      if (!mounted || path == null) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Log saved to $path'),
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not save log: $error')));
    }
  }

  //Load log from file
  Future _load() async {
    Directory? directory = await getApplicationSupportDirectory();
    String path = p.join(directory.path, 'saturn.log');
    File file = File(path);
    if (await file.exists()) {
      String d = await file.readAsString();
      setState(() {
        data = d.replaceAll('\r', '').split('\n');
      });
    }
  }

  //Get color by log type
  Color? color(String line) {
    if (line.startsWith('[log] SEVERE:')) return Colors.red;
    if (line.startsWith('[log] WARNING:')) return Colors.orange[600];
    return null;
  }

  @override
  void initState() {
    _load();
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: FreezerAppBar(
        'Application Log'.i18n,
        actions: [
          IconButton(
            icon: const Icon(Icons.save_alt),
            tooltip: 'Save logs as text file'.i18n,
            onPressed: data.isEmpty ? null : _saveLogs,
          ),
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy to clipboard'.i18n,
            onPressed: data.isEmpty ? null : _copyLogs,
          ),
        ],
      ),
      body: SilkyListView.builder(
        silkyConfig: silkyScrollConfig,
        itemCount: data.length,
        itemBuilder: (context, i) {
          return Padding(
            padding: const EdgeInsets.all(8.0),
            child: Text(
              data[i],
              style: TextStyle(fontSize: 14.0, color: color(data[i])),
            ),
          );
        },
      ),
    );
  }
}
