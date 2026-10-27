import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:logging/logging.dart';
import 'package:saturn/ui/tiles.dart';
import 'package:file_picker/file_picker.dart';

import '../api/definitions.dart';
import '../api/download.dart';
import '../translations.i18n.dart';
import 'details_screens.dart';
import 'menu.dart';

class LocalPlaylistsSection extends StatefulWidget {
  final Function? onPlaylistsChanged;
  final ValueChanged<bool>? onHasPlaylistsChanged;
  final bool actionsOnly;

  const LocalPlaylistsSection({
    this.onPlaylistsChanged,
    this.onHasPlaylistsChanged,
    this.actionsOnly = false,
    super.key,
  });

  @override
  State<LocalPlaylistsSection> createState() => _LocalPlaylistsSectionState();
}

class _LocalPlaylistsSectionState extends State<LocalPlaylistsSection> {
  List<LocalPlaylist> playlists = [];
  bool loading = true;
  StreamSubscription<void>? _offlineLibrarySub;

  @override
  void initState() {
    super.initState();
    _offlineLibrarySub = downloadManager.offlineLibraryChanged.listen((_) {
      if (!widget.actionsOnly) _loadPlaylists();
    });
    Logger.root.info('LocalPlaylistsSection initState');
    if (!widget.actionsOnly) _loadPlaylists();
  }

  @override
  void dispose() {
    _offlineLibrarySub?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant LocalPlaylistsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.actionsOnly && !widget.actionsOnly) {
      _loadPlaylists();
    }
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
        widget.onHasPlaylistsChanged?.call(loaded.isNotEmpty);
      }
    } catch (e) {
      Logger.root.severe('Error loading playlists: $e');
      if (mounted) {
        setState(() => loading = false);
        widget.onHasPlaylistsChanged?.call(playlists.isNotEmpty);
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
      builder: (context) => CreateLocalPlaylistDialog(
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
      final result = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['json'],
        dialogTitle: 'Import Playlist'.i18n,
      );
      if (result != null && result.path != null) {
        return result.path;
      }
      return null;
    } catch (e) {
      Logger.root.severe('Error picking file: $e');
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (loading && !widget.actionsOnly) {
      return const SizedBox(height: 0, width: 0);
    }

    final isWide = MediaQuery.sizeOf(context).width >= 900;

    Widget actionCards() => SizedBox(
      width: double.infinity,
      child: ResponsiveMediaGrid.builder(
        itemCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        extraTextHeight: 70,
        itemBuilder: (context, index) => LayoutBuilder(
          builder: (context, constraints) => PlaylistActionCard(
            title: index == 0
                ? 'Create local playlist'.i18n
                : 'Import playlist'.i18n,
            icon: index == 0 ? Icons.playlist_add : Icons.file_download,
            width: constraints.maxWidth,
            onTap: index == 0 ? _createPlaylist : _importPlaylist,
          ),
        ),
      ),
    );

    if (widget.actionsOnly) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Local Playlists'.i18n,
                style: const TextStyle(
                  fontSize: 20.0,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          actionCards(),
        ],
      );
    }

    if (playlists.isEmpty && isWide) {
      return const SizedBox.shrink();
    }

    if (playlists.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
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

    if (isWide) {
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              vertical: 8.0,
              horizontal: 16.0,
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Local Playlists'.i18n,
                style: const TextStyle(
                  fontSize: 20.0,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          SizedBox(
            width: double.infinity,
            child: ResponsiveMediaGrid.builder(
              itemCount: playlists.length + 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              extraTextHeight: 70,
              itemBuilder: (context, index) {
              if (index < 2) {
                final actionIndex = index;
                return LayoutBuilder(
                  builder: (context, constraints) => PlaylistActionCard(
                    title: actionIndex == 0
                        ? 'Create local playlist'.i18n
                        : 'Import playlist'.i18n,
                    icon: actionIndex == 0
                        ? Icons.playlist_add
                        : Icons.file_download,
                    width: constraints.maxWidth,
                    onTap: actionIndex == 0 ? _createPlaylist : _importPlaylist,
                  ),
                );
              }
              final playlist = playlists[index - 2];
              final item = Playlist(
                id: 'local_${playlist.id}',
                title: playlist.title,
                description: playlist.description,
                trackCount: playlist.trackIds.length,
                platformId: 'local',
                mosaicImages: playlist.mosaicImages,
              );
              return LayoutBuilder(
                builder: (context, constraints) => PlaylistCardTile(
                  item,
                  width: constraints.maxWidth,
                  subtitleOverride:
                      '${playlist.trackIds.length} ${'Tracks'.i18n}',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => PlaylistDetails(item),
                    ),
                  ),
                  onHold: () => _showPlaylistMenu(context, playlist),
                ),
              );
              },
            ),
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
          final p = Playlist(
            id: 'local_${playlist.id}',
            title: playlist.title,
            description: playlist.description,
            trackCount: playlist.trackIds.length,
            platformId: 'local',
          );
          p.mosaicImages = playlist.mosaicImages;
          return PlaylistTile(
            p,
            subtitleOverride: '${playlist.trackIds.length} ${'Tracks'.i18n}',
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (context) => PlaylistDetails(p)),
              );
            },
            onHold: () {
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
    final p = Playlist(
      id: 'local_${playlist.id}',
      title: playlist.title,
      description: playlist.description,
      trackCount: playlist.trackIds.length,
      platformId: 'local',
      mosaicImages: playlist.mosaicImages,
    );
    MenuSheet().defaultPlaylistMenu(
      p,
      context: context,
      onRemove: () {
        _loadPlaylists();
        widget.onPlaylistsChanged?.call();
      },
      onUpdate: () {
        _loadPlaylists();
        widget.onPlaylistsChanged?.call();
      },
    );
  }
}

class CreateLocalPlaylistDialog extends StatefulWidget {
  final String? initialTitle;
  final String? initialDescription;
  final Function(String, String?) onSave;

  const CreateLocalPlaylistDialog({
    super.key,
    this.initialTitle,
    this.initialDescription,
    required this.onSave,
  });

  @override
  State<CreateLocalPlaylistDialog> createState() =>
      CreateLocalPlaylistDialogState();
}

class CreateLocalPlaylistDialogState extends State<CreateLocalPlaylistDialog> {
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
