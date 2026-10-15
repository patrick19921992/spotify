import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../state/auth.dart';
import '../../state/library.dart';
import '../widgets/common.dart';
import '../widgets/cover.dart';

// Dialoge und Blätter der Playlist-Seite: Bearbeiten und „Songs hinzufügen“.

/// Ergebnis des Bearbeiten-Dialogs.
typedef PlaylistEdit = ({String name, String description, bool isPublic, bool isCollaborative});

/// Name, Beschreibung, Sichtbarkeit und „gemeinsam“ bearbeiten. Liefert null bei Abbruch.
Future<PlaylistEdit?> showEditPlaylistDialog(BuildContext context, Playlist playlist) {
  return showDialog<PlaylistEdit>(
    context: context,
    useRootNavigator: true,
    builder: (_) => _EditPlaylistDialog(playlist: playlist),
  );
}

class _EditPlaylistDialog extends StatefulWidget {
  final Playlist playlist;
  const _EditPlaylistDialog({required this.playlist});

  @override
  State<_EditPlaylistDialog> createState() => _EditPlaylistDialogState();
}

class _EditPlaylistDialogState extends State<_EditPlaylistDialog> {
  late final TextEditingController _name = TextEditingController(text: widget.playlist.name);
  late final TextEditingController _description = TextEditingController(text: widget.playlist.description);
  late bool _public = widget.playlist.isPublic || widget.playlist.isCollaborative;
  late bool _collaborative = widget.playlist.isCollaborative;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  bool get _valid => _name.text.trim().isNotEmpty;

  void _save() {
    if (!_valid) return;
    Navigator.of(context).pop<PlaylistEdit>((
      name: _name.text.trim(),
      description: _description.text.trim(),
      isPublic: _public || _collaborative,
      isCollaborative: _collaborative,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Playlist bearbeiten'),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              maxLength: 100,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Name', counterText: ''),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _description,
              maxLength: 500,
              minLines: 2,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Beschreibung (optional)', alignLabelWithHint: true),
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _public || _collaborative,
              onChanged: _collaborative ? null : (value) => setState(() => _public = value),
              title: const Text('Für die Familie sichtbar'),
              subtitle: Text(
                _collaborative
                    ? 'Gemeinsame Playlists sehen immer alle.'
                    : 'Andere können die Playlist finden, hören und ihr folgen.',
                style: AppText.caption,
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _collaborative,
              onChanged: (value) => setState(() {
                _collaborative = value;
                if (value) _public = true;
              }),
              title: const Text('Gemeinsame Playlist – alle dürfen Songs hinzufügen'),
              subtitle: const Text(
                'Alle in der Familie können Songs hinzufügen, entfernen und umsortieren.',
                style: AppText.caption,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Abbrechen')),
        TextButton(onPressed: _valid ? _save : null, child: const Text('Speichern')),
      ],
    );
  }
}

// ------------------------------------------------------------------ Songs hinzufügen

/// Blatt „Songs hinzufügen“: Bibliothek durchsuchen und Songs per „+“ in die Playlist legen.
/// [onOpenSearch] wechselt zur Suche (für neue Songs von YouTube).
Future<void> showAddSongsSheet(
  BuildContext context, {
  required int playlistId,
  required String playlistName,
  required Set<int> existingTrackIds,
  required VoidCallback onOpenSearch,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    builder: (sheetContext) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.92,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, controller) => _AddSongsSheet(
        playlistId: playlistId,
        playlistName: playlistName,
        existingTrackIds: existingTrackIds,
        controller: controller,
        onOpenSearch: () {
          Navigator.of(sheetContext).pop();
          onOpenSearch();
        },
      ),
    ),
  );
}

class _AddSongsSheet extends ConsumerStatefulWidget {
  final int playlistId;
  final String playlistName;
  final Set<int> existingTrackIds;
  final ScrollController controller;
  final VoidCallback onOpenSearch;

  const _AddSongsSheet({
    required this.playlistId,
    required this.playlistName,
    required this.existingTrackIds,
    required this.controller,
    required this.onOpenSearch,
  });

  @override
  ConsumerState<_AddSongsSheet> createState() => _AddSongsSheetState();
}

class _AddSongsSheetState extends ConsumerState<_AddSongsSheet> {
  final _search = TextEditingController();
  Timer? _debounce;
  String _query = '';
  bool _searching = false;
  Object? _error;
  List<Track> _results = const [];
  int _requestId = 0;

  /// Schon in der Playlist (vorher oder gerade hinzugefügt).
  late final Set<int> _inPlaylist = {...widget.existingTrackIds};
  final Set<int> _adding = {};
  int _addedCount = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    final query = value.trim();
    if (query.isEmpty) {
      _requestId++;
      setState(() {
        _query = '';
        _results = const [];
        _searching = false;
        _error = null;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350), () => _runSearch(query));
  }

  Future<void> _runSearch(String query) async {
    final request = ++_requestId;
    setState(() {
      _query = query;
      _searching = true;
      _error = null;
    });
    try {
      final result = await ref.read(apiProvider)!.search(query, limit: 40);
      if (!mounted || request != _requestId) return;
      setState(() {
        _results = result.tracks;
        _searching = false;
      });
    } catch (e) {
      if (!mounted || request != _requestId) return;
      setState(() {
        _error = e;
        _searching = false;
      });
    }
  }

  Future<void> _add(Track track) async {
    if (_adding.contains(track.id)) return;
    if (_inPlaylist.contains(track.id)) {
      final again = await confirm(
        context,
        title: 'Schon in der Playlist',
        message: '„${track.title}“ ist bereits in „${widget.playlistName}“. Trotzdem noch einmal hinzufügen?',
        confirmLabel: 'Hinzufügen',
      );
      if (!again || !mounted) return;
    }
    setState(() => _adding.add(track.id));
    // Das Blatt kann während der Anfrage geschlossen werden ("Fertig") – dann gibt es ref nicht mehr
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      await container.read(apiProvider)!.addToPlaylist(widget.playlistId, [track.id]);
      container.invalidate(playlistProvider(widget.playlistId));
      container.invalidate(libraryOverviewProvider);
      if (!mounted) return;
      setState(() {
        _inPlaylist.add(track.id);
        _addedCount++;
      });
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _adding.remove(track.id));
    }
  }

  Widget _trackRow(Track track) {
    final added = _inPlaylist.contains(track.id);
    final busy = _adding.contains(track.id);
    final subtitle = [
      if (track.isVideo) 'Video',
      track.artistDisplay,
      if (track.album != null) track.album!.title,
    ].where((s) => s.isNotEmpty).join(' · ');
    return ListTile(
      onTap: busy ? null : () => _add(track),
      leading: CoverImage(
        coverId: track.coverId,
        size: 48,
        placeholderIcon: track.isVideo ? Icons.movie_rounded : Icons.music_note_rounded,
      ),
      title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.tileTitle),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.tileSubtitle),
      trailing: busy
          ? const Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
            )
          : IconButton(
              tooltip: added ? 'Schon in der Playlist' : 'Hinzufügen',
              onPressed: () => _add(track),
              icon: Icon(
                added ? Icons.check_circle_rounded : Icons.add_circle_outline_rounded,
                color: added ? AppColors.accent : Colors.white,
                size: 28,
              ),
            ),
    );
  }

  Widget _youtubeHint() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Material(
        color: AppColors.surfaceHighest,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: widget.onOpenSearch,
          child: const Padding(
            padding: EdgeInsets.all(14),
            child: Row(
              children: [
                Icon(Icons.smart_display_rounded, color: AppColors.accent, size: 28),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Song nicht dabei?', style: AppText.tileTitle),
                      SizedBox(height: 2),
                      Text(
                        'In der Suche kannst du neue Songs von YouTube holen – auch direkt in diese Playlist.',
                        style: AppText.caption,
                      ),
                    ],
                  ),
                ),
                SizedBox(width: 8),
                Icon(Icons.chevron_right_rounded, color: AppColors.textSecondary),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _suggestions(AsyncValue<List<LikedTrack>> liked) {
    final tracks = (liked.value ?? const <LikedTrack>[]).map((e) => e.track).take(50).toList();
    if (liked.isLoading && tracks.isEmpty) {
      return const [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          ),
        ),
      ];
    }
    if (tracks.isEmpty) {
      return const [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(top: 24),
            child: EmptyState(
              icon: Icons.search_rounded,
              title: 'Suche nach Songs',
              message: 'Gib einen Titel, Künstler oder ein Album ein.',
            ),
          ),
        ),
      ];
    }
    return [
      const SliverToBoxAdapter(
        child: SectionHeader('Aus deinen Lieblingssongs', padding: EdgeInsets.fromLTRB(16, 16, 16, 4)),
      ),
      SliverList.builder(itemCount: tracks.length, itemBuilder: (_, index) => _trackRow(tracks[index])),
    ];
  }

  List<Widget> _searchResults() {
    if (_searching && _results.isEmpty) {
      return const [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          ),
        ),
      ];
    }
    if (_error != null) {
      return [
        SliverToBoxAdapter(
          child: ErrorView(message: errorText(_error!), onRetry: () => _runSearch(_query)),
        ),
      ];
    }
    if (_results.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: EmptyState(
            icon: Icons.search_off_rounded,
            title: 'Nichts gefunden für „$_query“',
            message: 'Vielleicht ist der Song noch nicht in deiner Bibliothek.',
          ),
        ),
      ];
    }
    return [
      if (_searching) const SliverToBoxAdapter(child: LinearProgressIndicator(minHeight: 2)),
      SliverList.builder(itemCount: _results.length, itemBuilder: (_, index) => _trackRow(_results[index])),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    // Vorschläge: die eigenen Lieblingssongs (immer beobachten, damit sie beim Suchen nicht neu laden)
    final liked = ref.watch(likedTracksProvider);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Songs hinzufügen', style: AppText.sectionTitle),
                    const SizedBox(height: 2),
                    Text(
                      _addedCount == 0
                          ? 'zu „${widget.playlistName}“'
                          : '${pluralSongs(_addedCount)} zu „${widget.playlistName}“ hinzugefügt',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.caption.copyWith(color: _addedCount == 0 ? null : AppColors.accent),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text(
                  'Fertig',
                  style: TextStyle(color: AppColors.accent, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            controller: _search,
            autofocus: false,
            onChanged: _onChanged,
            textInputAction: TextInputAction.search,
            onSubmitted: (value) {
              _debounce?.cancel();
              if (value.trim().isNotEmpty) _runSearch(value.trim());
            },
            decoration: InputDecoration(
              hintText: 'Songs oder Künstler suchen',
              prefixIcon: const Icon(Icons.search_rounded),
              isDense: true,
              suffixIcon: ValueListenableBuilder<TextEditingValue>(
                valueListenable: _search,
                builder: (context, value, _) => value.text.isEmpty
                    ? const SizedBox.shrink()
                    : IconButton(
                        tooltip: 'Leeren',
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () {
                          _search.clear();
                          _onChanged('');
                        },
                      ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: CustomScrollView(
            controller: widget.controller,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            slivers: [
              ...(_query.isEmpty ? _suggestions(liked) : _searchResults()),
              SliverToBoxAdapter(child: _youtubeHint()),
              SliverToBoxAdapter(child: SizedBox(height: 24 + bottomInset)),
            ],
          ),
        ),
      ],
    );
  }
}
