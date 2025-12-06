import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';
import 'package:saturn/ui/menu.dart';
import 'package:saturn/ui/tiles.dart';

import '../api/definitions.dart';
import '../api/download.dart';
import '../api/deezer.dart';
import '../service/audio_service.dart';
import '../translations.i18n.dart';

class LocalPlaylistsSection extends StatefulWidget {
  final Function? onPlaylistsChanged;

  const LocalPlaylistsSection({this.onPlaylistsChanged, super.key});

  @override
  State<LocalPlaylistsSection> createState() => _LocalPlaylistsSectionState();
}

class _LocalPlaylistsSectionState extends State<LocalPlaylistsSection> {
  List<LocalPlaylist> playlists = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    Logger.root.info('LocalPlaylistsSection initState');
    _loadPlaylists();
  }

  Future<void> _loadPlaylists() async {
    try {
      Logger.root.info('Loading playlists...');
      final loaded = await downloadManager.localPlaylistManager
          .getAllPlaylists();
      Logger.root.info('Loaded ${loaded.length} playlists');
      if (mounted) {
        setState(() {
          playlists = loaded;
          loading = false;
        });
      }
    } catch (e) {
      Logger.root.severe('Error loading playlists: $e');
      if (mounted) {
        setState(() => loading = false);
      }
    }
  }

  Future<void> _createPlaylist() async {
    String? title;
    String? description;

    if (!mounted) return;

    Logger.root.info('Opening create playlist dialog');

    await showDialog(
      context: context,
      builder: (context) => _CreateLocalPlaylistDialog(
        onSave: (t, d) {
          Logger.root.info('Dialog onSave called with title: $t');
          title = t;
          description = d;
        },
      ),
    );

    Logger.root.info('Dialog closed. Title: $title, Description: $description');

    if (title == null || title!.isEmpty) {
      Logger.root.info('Title is empty, returning');
      return;
    }

    try {
      Logger.root.info('Creating playlist with title: $title');
      await downloadManager.localPlaylistManager.createPlaylist(
        title: title!,
        description: description,
      );
      Logger.root.info('Playlist created successfully');
      await _loadPlaylists();
      widget.onPlaylistsChanged?.call();
    } catch (e) {
      Logger.root.severe('Error creating playlist: $e');
    }
  }

  Future<void> _importPlaylist() async {
    try {
      Logger.root.info('Opening file picker for import');

      // Use file dialog to select JSON file
      final result = await _pickJsonFile();
      if (result == null) {
        Logger.root.info('Import cancelled by user');
        return;
      }

      Logger.root.info('Importing playlist from: $result');

      final imported = await downloadManager.localPlaylistManager
          .importPlaylist(result);

      // Create new playlist with imported data
      await downloadManager.localPlaylistManager.createPlaylist(
        title: imported.title,
        description: imported.description,
        trackIds: imported.trackIds,
      );

      await _loadPlaylists();
      widget.onPlaylistsChanged?.call();

      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Imported'.i18n),
            content: Text('Playlist "${imported.title}" imported successfully'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text('OK'.i18n),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      Logger.root.severe('Error importing playlist: $e');
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Error'.i18n),
            content: Text('Failed to import playlist: $e'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text('OK'.i18n),
              ),
            ],
          ),
        );
      }
    }
  }

  Future<String?> _pickJsonFile() async {
    try {
      // TODO: this sucks
      final result = await showDialog<String>(
        context: context,
        builder: (context) => _FilePickerDialog(),
      );
      return result;
    } catch (e) {
      Logger.root.severe('Error picking file: $e');
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const SizedBox(height: 0, width: 0);
    }

    if (playlists.isEmpty) {
      return Column(
        children: [
          ListTile(
            title: Text('Create local playlist'.i18n),
            leading: const Icon(Icons.playlist_add),
            onTap: _createPlaylist,
          ),
          ListTile(
            title: Text('Import playlist'.i18n),
            leading: const Icon(Icons.file_download),
            onTap: _importPlaylist,
          ),
        ],
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
          child: Text(
            'Local Playlists'.i18n,
            style: const TextStyle(fontSize: 18.0, fontWeight: FontWeight.bold),
          ),
        ),
        ...playlists.map((playlist) {
          return _LocalPlaylistTile(
            playlist,
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => LocalPlaylistDetailsScreen(
                    playlist,
                    onChanged: _loadPlaylists,
                  ),
                ),
              );
            },
            onLongPress: () {
              _showPlaylistMenu(context, playlist);
            },
          );
        }),
        ListTile(
          title: Text('Create local playlist'.i18n),
          leading: const Icon(Icons.playlist_add),
          onTap: _createPlaylist,
        ),
        ListTile(
          title: Text('Import playlist'.i18n),
          leading: const Icon(Icons.file_download),
          onTap: _importPlaylist,
        ),
      ],
    );
  }

  void _showPlaylistMenu(BuildContext context, LocalPlaylist playlist) {
    showModalBottomSheet(
      context: context,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: Text('Edit'.i18n),
            leading: const Icon(Icons.edit),
            onTap: () {
              Navigator.pop(context);
              _editPlaylist(playlist);
            },
          ),
          ListTile(
            title: Text('Export'.i18n),
            leading: const Icon(Icons.file_upload),
            onTap: () {
              Navigator.pop(context);
              _exportPlaylist(playlist);
            },
          ),
          ListTile(
            title: Text('Delete'.i18n),
            leading: const Icon(Icons.delete),
            onTap: () {
              Navigator.pop(context);
              _deletePlaylist(playlist);
            },
          ),
        ],
      ),
    );
  }

  Future<void> _editPlaylist(LocalPlaylist playlist) async {
    String? title = playlist.title;
    String? description = playlist.description;

    if (!mounted) return;

    await showDialog(
      context: context,
      builder: (context) => _CreateLocalPlaylistDialog(
        initialTitle: playlist.title,
        initialDescription: playlist.description,
        onSave: (t, d) {
          title = t;
          description = d;
        },
      ),
    );

    if (title == null || title!.isEmpty) return;

    try {
      final updated = LocalPlaylist(
        id: playlist.id,
        title: title!,
        description: description,
        trackIds: playlist.trackIds,
        createdAt: playlist.createdAt,
        updatedAt: DateTime.now(),
      );
      await downloadManager.localPlaylistManager.updatePlaylist(updated);
      await _loadPlaylists();
      widget.onPlaylistsChanged?.call();
    } catch (e) {
      // Error updating playlist
    }
  }

  Future<void> _exportPlaylist(LocalPlaylist playlist) async {
    try {
      Logger.root.info('Exporting playlist: ${playlist.title}');

      final dir = await getApplicationDocumentsDirectory();
      final fileName =
          '${playlist.title.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}_${DateTime.now().millisecondsSinceEpoch}.json';
      final filePath = '${dir.path}/$fileName';

      await downloadManager.localPlaylistManager.exportPlaylist(
        playlist,
        filePath,
      );

      Logger.root.info('Playlist exported to: $filePath');

      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Exported'.i18n),
            content: Text('Playlist saved to: $fileName'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text('OK'.i18n),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      Logger.root.severe('Error exporting playlist: $e');
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Error'.i18n),
            content: Text('Failed to export playlist: $e'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text('OK'.i18n),
              ),
            ],
          ),
        );
      }
    }
  }

  Future<void> _deletePlaylist(LocalPlaylist playlist) async {
    if (!mounted) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete playlist?'.i18n),
        content: Text('This cannot be undone.'.i18n),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel'.i18n),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Delete'.i18n),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      await downloadManager.localPlaylistManager.deletePlaylist(playlist.id);
      await _loadPlaylists();
      widget.onPlaylistsChanged?.call();
    } catch (e) {
      // Error deleting playlist
    }
  }
}

class _LocalPlaylistTile extends StatelessWidget {
  final LocalPlaylist playlist;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const _LocalPlaylistTile(this.playlist, {this.onTap, this.onLongPress});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(playlist.title, maxLines: 1),
      subtitle: Text('${playlist.trackCount} ' + 'Tracks'.i18n, maxLines: 1),
      leading: const Icon(Icons.playlist_play),
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }
}

class LocalPlaylistDetailsScreen extends StatefulWidget {
  final LocalPlaylist playlist;
  final Function? onChanged;

  const LocalPlaylistDetailsScreen(this.playlist, {this.onChanged, super.key});

  @override
  State<LocalPlaylistDetailsScreen> createState() =>
      _LocalPlaylistDetailsScreenState();
}

class _LocalPlaylistDetailsScreenState
    extends State<LocalPlaylistDetailsScreen> {
  late LocalPlaylist playlist;
  List<Track> tracks = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    playlist = widget.playlist;
    _loadTracks();
  }

  Future<void> _loadTracks() async {
    try {
      Logger.root.info(
        'Loading ${playlist.trackIds.length} tracks for playlist',
      );
      List<Track> loadedTracks = [];

      try {
        loadedTracks = await deezerAPI.tracks(playlist.trackIds);
      } catch (e) {
        Logger.root.warning('Failed to load tracks: $e');
      }

      if (mounted) {
        setState(() {
          tracks = loadedTracks;
          loading = false;
        });
      }
    } catch (e) {
      Logger.root.severe('Error loading tracks: $e');
      if (mounted) {
        setState(() => loading = false);
      }
    }
  }

  Future<void> _removeTrack(String trackId) async {
    try {
      await downloadManager.localPlaylistManager.removeTrackFromPlaylist(
        playlist.id,
        trackId,
      );
      setState(() {
        playlist = LocalPlaylist(
          id: playlist.id,
          title: playlist.title,
          description: playlist.description,
          trackIds: playlist.trackIds.where((id) => id != trackId).toList(),
          createdAt: playlist.createdAt,
          updatedAt: DateTime.now(),
        );
        tracks.removeWhere((t) => t.id == trackId);
      });
      widget.onChanged?.call();
    } catch (e) {
      Logger.root.severe('Error removing track: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(playlist.title)),
      body: loading
          ? Center(
              child: CircularProgressIndicator(
                color: Theme.of(context).primaryColor,
              ),
            )
          : ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (playlist.description != null &&
                          playlist.description!.isNotEmpty)
                        Text(
                          playlist.description!,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      const SizedBox(height: 8),
                      Text(
                        '${tracks.length} ' + 'Tracks'.i18n,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                ...List.generate(tracks.length, (index) {
                  final track = tracks[index];
                  return TrackTile(
                    track,
                    onTap: () {
                      GetIt.I<AudioPlayerHandler>().playFromTrackList(
                        tracks,
                        track.id ?? '',
                        QueueSource(
                          text: playlist.title,
                          source: 'localplaylist',
                        ),
                      );
                    },
                    onHold: () {
                      MenuSheet m = MenuSheet();
                      m.defaultTrackMenu(track, context: context);
                    },
                    trailing: IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => _removeTrack(track.id!),
                    ),
                    trailingBypass: true,
                  );
                }),
              ],
            ),
    );
  }
}

class _CreateLocalPlaylistDialog extends StatefulWidget {
  final String? initialTitle;
  final String? initialDescription;
  final Function(String, String?) onSave;

  const _CreateLocalPlaylistDialog({
    this.initialTitle,
    this.initialDescription,
    required this.onSave,
  });

  @override
  State<_CreateLocalPlaylistDialog> createState() =>
      _CreateLocalPlaylistDialogState();
}

class _CreateLocalPlaylistDialogState
    extends State<_CreateLocalPlaylistDialog> {
  late TextEditingController titleController;
  late TextEditingController descriptionController;

  @override
  void initState() {
    super.initState();
    titleController = TextEditingController(text: widget.initialTitle ?? '');
    descriptionController = TextEditingController(
      text: widget.initialDescription ?? '',
    );
  }

  @override
  void dispose() {
    titleController.dispose();
    descriptionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.initialTitle == null
            ? 'Create playlist'.i18n
            : 'Edit playlist'.i18n,
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: titleController,
            decoration: InputDecoration(
              labelText: 'Title'.i18n,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: descriptionController,
            decoration: InputDecoration(
              labelText: 'Description'.i18n,
              border: const OutlineInputBorder(),
            ),
            maxLines: 3,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Cancel'.i18n),
        ),
        TextButton(
          onPressed: () {
            widget.onSave(
              titleController.text,
              descriptionController.text.isEmpty
                  ? null
                  : descriptionController.text,
            );
            Navigator.pop(context);
          },
          child: Text('Save'.i18n),
        ),
      ],
    );
  }
}

class _FilePickerDialog extends StatefulWidget {
  const _FilePickerDialog();

  @override
  State<_FilePickerDialog> createState() => _FilePickerDialogState();
}

class _FilePickerDialogState extends State<_FilePickerDialog> {
  late TextEditingController _pathController;

  @override
  void initState() {
    super.initState();
    _pathController = TextEditingController();
  }

  @override
  void dispose() {
    _pathController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Import Playlist'.i18n),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Enter the path to the playlist JSON file:'),
          const SizedBox(height: 16),
          TextField(
            controller: _pathController,
            decoration: InputDecoration(
              labelText: 'File path'.i18n,
              border: const OutlineInputBorder(),
              hintText: 'C:\\Users\\...\\playlist.json',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Cancel'.i18n),
        ),
        TextButton(
          onPressed: () {
            final path = _pathController.text.trim();
            if (path.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Please enter a file path'.i18n)),
              );
              return;
            }

            final file = File(path);
            if (!file.existsSync()) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text('File not found'.i18n)));
              return;
            }

            Navigator.pop(context, path);
          },
          child: Text('Import'.i18n),
        ),
      ],
    );
  }
}
