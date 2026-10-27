import 'dart:async';
import 'dart:math';

import 'package:material_ui/material_ui.dart';
import 'package:logging/logging.dart';
import 'package:silky_scroll/silky_scroll.dart';
import 'package:saturn/ui/smooth_scroll_config.dart';

import '../../../ui/toast.dart';
import 'neuro_radio_service.dart';

final Logger _log = Logger('NeuroRadioRequestDialog');

class NeuroRadioRequestDialog extends StatefulWidget {
  final NeuroRadioService radio;

  const NeuroRadioRequestDialog({super.key, required this.radio});

  static Future<void> show(BuildContext context, NeuroRadioService radio) {
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (context) => NeuroRadioRequestDialog(radio: radio),
    );
  }

  @override
  State<NeuroRadioRequestDialog> createState() =>
      _NeuroRadioRequestDialogState();
}

class _NeuroRadioRequestDialogState extends State<NeuroRadioRequestDialog> {
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  Timer? _debounceTimer;

  bool _isLoading = true;
  String? _errorMessage;
  RadioRequestPage? _pageData;
  int _currentPage = 1;
  final Set<String> _requestingIds = {};
  final Set<String> _requestedIds = {};

  @override
  void initState() {
    super.initState();
    _fetchPage(1);
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 350), () {
      if (mounted) {
        _fetchPage(1, query: value);
      }
    });
  }

  Future<void> _fetchPage(int page, {String? query}) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _currentPage = page;
    });

    try {
      final q = query ?? _searchController.text;
      final result = await widget.radio.fetchRequestableSongs(
        page: page,
        perPage: 25,
        query: q,
      );
      if (!mounted) return;
      setState(() {
        _pageData = result;
        _isLoading = false;
      });
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    } catch (e) {
      _log.warning('Failed to load request songs: $e');
      if (!mounted) return;
      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _requestSong(RadioRequestSong song) async {
    if (_requestingIds.contains(song.requestId) ||
        _requestedIds.contains(song.requestId)) {
      return;
    }

    setState(() {
      _requestingIds.add(song.requestId);
    });

    try {
      final message = await widget.radio.requestSong(song);
      if (!mounted) return;
      setState(() {
        _requestedIds.add(song.requestId);
        _requestingIds.remove(song.requestId);
      });
      Fluttertoast.showToast(
        msg: message,
        backgroundColor: const Color(0xFF00695C),
        textColor: Colors.white,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _requestingIds.remove(song.requestId);
      });

      final msg = e is RadioRequestException ? e.message : e.toString();
      Fluttertoast.showToast(
        msg: msg,
        backgroundColor: const Color(0xFFC62828),
        textColor: Colors.white,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final total = _pageData?.total ?? 0;
    final perPage = _pageData?.perPage ?? 25;
    final totalPages = _pageData?.totalPages ?? 1;
    final startItem = total == 0 ? 0 : (_currentPage - 1) * perPage + 1;
    final endItem = min(_currentPage * perPage, total);

    return Dialog(
      backgroundColor: theme.dialogTheme.backgroundColor ??
          theme.colorScheme.surfaceContainerHigh,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: 680,
          maxHeight: 760,
          minWidth: 320,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Title Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
              child: Row(
                children: [
                  Icon(
                    Icons.queue_music_rounded,
                    color: colorScheme.primary,
                    size: 24,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Request a Song',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),

            // Search Bar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: TextField(
                controller: _searchController,
                onChanged: _onSearchChanged,
                decoration: InputDecoration(
                  hintText: 'Search for a song',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _searchController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear_rounded, size: 20),
                          onPressed: () {
                            _searchController.clear();
                            _fetchPage(1, query: '');
                          },
                        )
                      : null,
                  filled: true,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),

            // Results counter
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
              child: Text(
                _isLoading && _pageData == null
                    ? 'Loading songs...'
                    : 'Showing $startItem - $endItem of $total songs',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.textTheme.bodySmall?.color?.withValues(
                    alpha: 0.7,
                  ),
                ),
              ),
            ),

            const Divider(height: 1),

            // Main List
            Expanded(
              child: _isLoading && _pageData == null
                  ? const Center(child: CircularProgressIndicator())
                  : _errorMessage != null && _pageData == null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24.0),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.error_outline_rounded,
                              size: 48,
                              color: Colors.redAccent,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'Could not load songs',
                              style: theme.textTheme.titleMedium,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _errorMessage!,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodySmall,
                            ),
                            const SizedBox(height: 16),
                            FilledButton.tonal(
                              onPressed: () => _fetchPage(_currentPage),
                              child: const Text('Retry'),
                            ),
                          ],
                        ),
                      ),
                    )
                  : (_pageData?.songs.isEmpty ?? true)
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32.0),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.music_off_rounded,
                              size: 48,
                              color: colorScheme.onSurface.withValues(alpha: 0.4),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'No matching songs found',
                              style: theme.textTheme.titleMedium,
                            ),
                          ],
                        ),
                      ),
                    )
                  : Stack(
                      children: [
                        SilkyListView.separated(
                          silkyConfig: silkyScrollConfig,
                          controller: _scrollController,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          itemCount: _pageData!.songs.length,
                          separatorBuilder: (context, index) =>
                              const Divider(height: 1, indent: 64),
                          itemBuilder: (context, index) {
                            final song = _pageData!.songs[index];
                            final isRequesting = _requestingIds.contains(
                              song.requestId,
                            );
                            final isRequested = _requestedIds.contains(
                              song.requestId,
                            );

                            return ListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              leading: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Container(
                                  width: 48,
                                  height: 48,
                                  color: colorScheme.surfaceContainerHighest,
                                  child: song.artUrl != null &&
                                          song.artUrl!.isNotEmpty
                                      ? Image.network(
                                          song.artUrl!,
                                          fit: BoxFit.cover,
                                          errorBuilder: (c, e, s) =>
                                              const Icon(
                                                Icons.music_note_rounded,
                                              ),
                                        )
                                      : const Icon(Icons.music_note_rounded),
                                ),
                              ),
                              title: Text(
                                song.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              subtitle: Text(
                                song.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: theme.textTheme.bodyMedium?.color
                                      ?.withValues(alpha: 0.7),
                                ),
                              ),
                              trailing: OutlinedButton(
                                onPressed: (isRequesting || isRequested)
                                    ? null
                                    : () => _requestSong(song),
                                style: OutlinedButton.styleFrom(
                                  side: BorderSide(
                                    color: isRequested
                                        ? Colors.teal
                                        : colorScheme.primary.withValues(
                                            alpha: 0.7,
                                          ),
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 8,
                                  ),
                                ),
                                child: isRequesting
                                    ? SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: colorScheme.primary,
                                        ),
                                      )
                                    : isRequested
                                    ? const Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            Icons.check,
                                            size: 16,
                                            color: Colors.teal,
                                          ),
                                          SizedBox(width: 4),
                                          Text(
                                            'REQUESTED',
                                            style: TextStyle(
                                              color: Colors.teal,
                                              fontSize: 12,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ],
                                      )
                                    : Text(
                                        'REQUEST',
                                        style: TextStyle(
                                          color: colorScheme.primary,
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                              ),
                            );
                          },
                        ),
                        if (_isLoading)
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            child: LinearProgressIndicator(
                              minHeight: 2,
                              color: colorScheme.primary,
                            ),
                          ),
                      ],
                    ),
            ),

            const Divider(height: 1),

            // Pagination Controls
            if (totalPages > 1)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.first_page_rounded),
                      tooltip: 'First Page',
                      onPressed: _currentPage > 1
                          ? () => _fetchPage(1)
                          : null,
                    ),
                    IconButton(
                      icon: const Icon(Icons.chevron_left_rounded),
                      tooltip: 'Previous Page',
                      onPressed: _currentPage > 1
                          ? () => _fetchPage(_currentPage - 1)
                          : null,
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '$_currentPage / $totalPages',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.chevron_right_rounded),
                      tooltip: 'Next Page',
                      onPressed: _currentPage < totalPages
                          ? () => _fetchPage(_currentPage + 1)
                          : null,
                    ),
                    IconButton(
                      icon: const Icon(Icons.last_page_rounded),
                      tooltip: 'Last Page',
                      onPressed: _currentPage < totalPages
                          ? () => _fetchPage(totalPages)
                          : null,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
