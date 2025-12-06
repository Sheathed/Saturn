import 'dart:async';
import 'dart:io';

import 'package:filesize/filesize.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../api/download.dart';
import '../translations.i18n.dart';
import 'elements.dart';
import 'cached_image.dart';

final _log = Logger('DownloadsScreen');

class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});

  @override
  _DownloadsScreenState createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  List<Download> downloads = [];
  StreamSubscription? _stateSubscription;
  Timer? _reloadDebouncer;
  bool _needsReload = false;

  //Sublists
  List<Download> get downloading => downloads
      .where(
        (d) =>
            d.state == DownloadState.DOWNLOADING ||
            d.state == DownloadState.POST,
      )
      .toList();
  List<Download> get queued =>
      downloads.where((d) => d.state == DownloadState.NONE).toList();
  List<Download> get failed => downloads
      .where(
        (d) =>
            d.state == DownloadState.ERROR ||
            d.state == DownloadState.DEEZER_ERROR,
      )
      .toList();
  List<Download> get finished =>
      downloads.where((d) => d.state == DownloadState.DONE).toList();

  Future _load() async {
    _log.info('[DownloadsScreen] _load() called');
    //Load downloads
    List<Download> d = await downloadManager.getDownloads();
    _log.info(
      '[DownloadsScreen] Loaded ${d.length} downloads - downloading: ${d.where((x) => x.state == DownloadState.DOWNLOADING).length}, queued: ${d.where((x) => x.state == DownloadState.NONE).length}, failed: ${d.where((x) => x.state == DownloadState.ERROR || x.state == DownloadState.DEEZER_ERROR).length}, done: ${d.where((x) => x.state == DownloadState.DONE).length}',
    );
    setState(() {
      downloads = d;
    });
  }

  @override
  void initState() {
    _log.info('[DownloadsScreen] initState() called');
    _load();

    //Subscribe to state update
    _stateSubscription = downloadManager.serviceEvents.stream.listen((e) {
      _log.fine('[DownloadsScreen] Service event received: ${e['type']}');

      //State change = update
      if (e['type'] == 'stateChange') {
        _log.info(
          '[DownloadsScreen] State change event - running: ${downloadManager.running}, queueSize: ${e['queueSize']}',
        );
        setState(() {
          // The downloadManager.running is already updated by the download manager itself
          // We just need to trigger a rebuild
        });
      }
      //Progress change
      if (e['type'] == 'progress') {
        // Progress is already throttled at service level (500ms)
        // Just update data and UI together
        setState(() {
          for (Map su in e['data']) {
            downloads
                .firstWhere((d) => d.id == su['id'], orElse: () => Download())
                .updateFromJson(su);
          }
        });
      }
      //Download completed - reload to show in "Done" section
      if (e['type'] == 'downloadComplete' || e['type'] == 'downloadError') {
        _debouncedReload();
      }

      //Downloads added - reload to show new downloads
      if (e['type'] == 'downloadsAdded') {
        _debouncedReload();
      }

      //Downloads list updated - reload to show current state
      if (e['type'] == 'downloadsList') {
        _debouncedReload();
      }
    });

    super.initState();
  }

  @override
  void dispose() {
    _stateSubscription?.cancel();
    _stateSubscription = null;
    _reloadDebouncer?.cancel();
    super.dispose();
  }

  void _debouncedReload() {
    _needsReload = true;
    _reloadDebouncer?.cancel();
    _reloadDebouncer = Timer(const Duration(milliseconds: 500), () {
      if (_needsReload && mounted) {
        _needsReload = false;
        _load();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: FreezerAppBar(
        'Downloads'.i18n,
        actions: [
          IconButton(
            icon: Icon(Icons.delete_sweep, semanticLabel: 'Clear all'.i18n),
            onPressed: () async {
              await downloadManager.removeDownloads(DownloadState.ERROR);
              await downloadManager.removeDownloads(DownloadState.DEEZER_ERROR);
              await downloadManager.removeDownloads(DownloadState.DONE);
              await downloadManager.removeDownloads(DownloadState.NONE);
              await _load();
            },
          ),
          IconButton(
            icon: Icon(
              downloadManager.running ? Icons.stop : Icons.play_arrow,
              semanticLabel: downloadManager.running
                  ? 'Stop'.i18n
                  : 'Start'.i18n,
            ),
            onPressed: () async {
              _log.info(
                '[DownloadsScreen] Start/Stop button pressed - current running: ${downloadManager.running}',
              );
              if (downloadManager.running) {
                _log.info('[DownloadsScreen] Stopping downloads...');
                await downloadManager.stop();
              } else {
                _log.info('[DownloadsScreen] Starting downloads...');
                await downloadManager.start();
              }
              _log.info(
                '[DownloadsScreen] Start/Stop complete - new running: ${downloadManager.running}',
              );
              setState(() {});
            },
          ),
        ],
      ),
      body: ListView(
        children: [
          //Now downloading
          Container(height: 2.0),
          Column(
            children: List.generate(
              downloading.length,
              (int i) =>
                  DownloadTile(downloading[i], updateCallback: () => _load()),
            ),
          ),
          Container(height: 8.0),

          //Queued
          if (queued.isNotEmpty)
            Text(
              'Queued'.i18n,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 24.0,
                fontWeight: FontWeight.bold,
              ),
            ),
          Column(
            children: List.generate(
              queued.length,
              (int i) => DownloadTile(queued[i], updateCallback: () => _load()),
            ),
          ),
          if (queued.isNotEmpty)
            ListTile(
              title: Text('Clear queue'.i18n),
              leading: const Icon(Icons.delete),
              onTap: () async {
                await downloadManager.removeDownloads(DownloadState.NONE);
                await _load();
              },
            ),

          //Failed
          if (failed.isNotEmpty)
            Text(
              'Failed'.i18n,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 24.0,
                fontWeight: FontWeight.bold,
              ),
            ),
          Column(
            children: List.generate(
              failed.length,
              (int i) => DownloadTile(failed[i], updateCallback: () => _load()),
            ),
          ),
          //Restart failed
          if (failed.isNotEmpty)
            ListTile(
              title: Text('Restart failed downloads'.i18n),
              leading: const Icon(Icons.restore),
              onTap: () async {
                await downloadManager.retryDownloads();
                await _load();
              },
            ),
          if (failed.isNotEmpty)
            ListTile(
              title: Text('Clear failed'.i18n),
              leading: const Icon(Icons.delete),
              onTap: () async {
                await downloadManager.removeDownloads(DownloadState.ERROR);
                await downloadManager.removeDownloads(
                  DownloadState.DEEZER_ERROR,
                );
                await _load();
              },
            ),

          //Finished
          if (finished.isNotEmpty)
            Text(
              'Done'.i18n,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 24.0,
                fontWeight: FontWeight.bold,
              ),
            ),
          Column(
            children: List.generate(
              finished.length,
              (int i) =>
                  DownloadTile(finished[i], updateCallback: () => _load()),
            ),
          ),
          if (finished.isNotEmpty)
            ListTile(
              title: Text('Clear downloads history'.i18n),
              leading: const Icon(Icons.delete),
              onTap: () async {
                await downloadManager.removeDownloads(DownloadState.DONE);
                await _load();
              },
            ),
        ],
      ),
    );
  }
}

class DownloadTile extends StatelessWidget {
  final Download download;
  final Function updateCallback;
  const DownloadTile(this.download, {super.key, required this.updateCallback});

  String subtitle() {
    String out = '';

    if (download.state != DownloadState.DOWNLOADING &&
        download.state != DownloadState.POST) {
      //Download type
      if (download.private ?? false) {
        out += 'Offline'.i18n;
      } else {
        out += 'External'.i18n;
      }
      out += ' | ';
    }

    if (download.state == DownloadState.POST) {
      return 'Post processing...'.i18n;
    }

    //Quality
    if (download.quality == 9) out += 'FLAC';
    if (download.quality == 3) out += 'MP3 320kbps';
    if (download.quality == 1) out += 'MP3 128kbps';

    //Downloading show progress
    if (download.state == DownloadState.DOWNLOADING) {
      if (download.received != null && download.filesize != null) {
        out +=
            ' | ${filesize(download.received, 2)} / ${filesize(download.filesize, 2)}';
        double progress =
            download.received!.toDouble() / download.filesize!.toDouble();
        out += ' ${(progress * 100.0).toStringAsFixed(2)}%';
      }
    }

    return out;
  }

  Future onClick(BuildContext context) async {
    if (download.state != DownloadState.DOWNLOADING &&
        download.state != DownloadState.POST) {
      showDialog(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: Text('Delete'.i18n),
            content: Text(
              'Are you sure you want to delete this download?'.i18n,
            ),
            actions: [
              TextButton(
                style: ButtonStyle(
                  overlayColor: WidgetStateProperty.resolveWith<Color?>((
                    Set<WidgetState> states,
                  ) {
                    if (states.contains(WidgetState.pressed)) {
                      return Theme.of(
                        context,
                      ).primaryColor.withValues(alpha: 0.3);
                    }
                    return null;
                  }),
                ),
                child: Text('Cancel'.i18n),
                onPressed: () => Navigator.of(context).pop(),
              ),
              TextButton(
                style: ButtonStyle(
                  overlayColor: WidgetStateProperty.resolveWith<Color?>((
                    Set<WidgetState> states,
                  ) {
                    if (states.contains(WidgetState.pressed)) {
                      return Theme.of(
                        context,
                      ).primaryColor.withValues(alpha: 0.3);
                    }
                    return null;
                  }),
                ),
                child: Text('Delete'.i18n),
                onPressed: () async {
                  await downloadManager.removeDownload(download.id!);
                  updateCallback();
                  if (context.mounted) Navigator.of(context).pop();
                },
              ),
            ],
          );
        },
      );
    }
  }

  //Trailing icon with state
  Widget trailing() {
    switch (download.state) {
      case DownloadState.NONE:
        return const Icon(Icons.query_builder);
      case DownloadState.DOWNLOADING:
        return const Icon(Icons.download_rounded);
      case DownloadState.POST:
        return const Icon(Icons.miscellaneous_services);
      case DownloadState.DONE:
        return const Icon(Icons.done, color: Colors.green);
      case DownloadState.DEEZER_ERROR:
        return const Icon(Icons.error, color: Colors.blue);
      case DownloadState.ERROR:
        return const Icon(Icons.error, color: Colors.red);
      default:
        return Container();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ListTile(
          title: Text(download.title!),
          leading: CachedImage(url: download.image!),
          subtitle: Text(
            subtitle(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: trailing(),
          onTap: () => onClick(context),
        ),
        if (download.state == DownloadState.DOWNLOADING)
          LinearProgressIndicator(
            value: download.progress,
            color: Theme.of(context).primaryColor,
            backgroundColor: Theme.of(
              context,
            ).primaryColor.withValues(alpha: 0.1),
          ),
        if (download.state == DownloadState.POST)
          LinearProgressIndicator(
            color: Theme.of(context).primaryColor,
            backgroundColor: Theme.of(
              context,
            ).primaryColor.withValues(alpha: 0.1),
          ),
      ],
    );
  }
}

class DownloadLogViewer extends StatefulWidget {
  const DownloadLogViewer({super.key});

  @override
  _DownloadLogViewerState createState() => _DownloadLogViewerState();
}

class _DownloadLogViewerState extends State<DownloadLogViewer> {
  List<String> data = [];

  //Load log from file
  Future _load() async {
    Directory? directory = await getApplicationSupportDirectory();
    String path = p.join(directory.path, 'download.log');
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
    if (line.startsWith('E:')) return Colors.red;
    if (line.startsWith('W:')) return Colors.orange[600];
    return null;
  }

  @override
  void initState() {
    _load();
    super.initState();
  }

  Future<void> _clearLog() async {
    Directory? directory = await getApplicationSupportDirectory();
    String path = p.join(directory.path, 'download.log');
    File file = File(path);
    if (await file.exists()) {
      await file.writeAsString('');
      setState(() {
        data = [];
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: FreezerAppBar(
        'Download Log'.i18n,
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear log'.i18n,
            onPressed: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: Text('Clear Log'.i18n),
                  content: Text(
                    'Are you sure you want to clear the download log?'.i18n,
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: Text('Cancel'.i18n),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: Text('Clear'.i18n),
                    ),
                  ],
                ),
              );
              if (confirmed == true) {
                await _clearLog();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Log cleared'.i18n),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                }
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy to clipboard'.i18n,
            onPressed: () {
              final logText = data.join('\n');
              Clipboard.setData(ClipboardData(text: logText));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Log copied to clipboard'.i18n),
                  duration: const Duration(seconds: 2),
                ),
              );
            },
          ),
        ],
      ),
      body: ListView.builder(
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
