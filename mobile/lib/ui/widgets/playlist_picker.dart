import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../state/auth.dart';
import '../../state/library.dart';
import 'common.dart';
import 'cover.dart';

/// Auswahl "Zu Playlist hinzufügen" (eigene + gemeinsame Playlists, neue anlegen).
Future<void> showAddToPlaylist(BuildContext context, WidgetRef ref, List<Track> tracks) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (sheetContext, controller) => _PlaylistPicker(tracks: tracks, controller: controller, parentContext: context),
    ),
  );
}

/// Liefert die ID einer gewählten Playlist (für "beim Download direkt in Playlist").
Future<int?> pickPlaylist(BuildContext context) {
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      builder: (sheetContext, controller) => _PlaylistPicker(tracks: const [], controller: controller, parentContext: context),
    ),
  );
}

class _PlaylistPicker extends ConsumerWidget {
  final List<Track> tracks;
  final ScrollController controller;
  final BuildContext parentContext;

  const _PlaylistPicker({required this.tracks, required this.controller, required this.parentContext});

  bool get _pickOnly => tracks.isEmpty;

  Future<void> _add(BuildContext context, WidgetRef ref, Playlist playlist) async {
    if (_pickOnly) {
      Navigator.of(context).pop(playlist.id);
      return;
    }
    // Nach dem Schließen gibt es ref nicht mehr – die App-weite Ablage bleibt gültig
    final container = ProviderScope.containerOf(context, listen: false);
    Navigator.of(context).pop();
    try {
      await container.read(apiProvider)!.addToPlaylist(playlist.id, tracks.map((t) => t.id).toList());
      container.invalidate(playlistProvider(playlist.id));
      container.invalidate(libraryOverviewProvider);
      if (parentContext.mounted) showMessage(parentContext, 'Zu „${playlist.name}“ hinzugefügt');
    } catch (e) {
      if (parentContext.mounted) showError(parentContext, e);
    }
  }

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final name = await promptText(context, title: 'Neue Playlist', hint: 'Name der Playlist', confirmLabel: 'Erstellen');
    if (name == null || name.isEmpty || !context.mounted) return;
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      final created =
          await container.read(apiProvider)!.createPlaylist(name: name, trackIds: tracks.map((t) => t.id).toList());
      container.invalidate(libraryOverviewProvider);
      container.invalidate(myPlaylistsProvider);
      if (!context.mounted) return;
      Navigator.of(context).pop(_pickOnly ? created.playlist.id : null);
      if (!_pickOnly && parentContext.mounted) showMessage(parentContext, 'Playlist „$name“ erstellt');
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlists = ref.watch(libraryOverviewProvider);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(_pickOnly ? 'Playlist wählen' : 'Zu Playlist hinzufügen', style: AppText.sectionTitle),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: FilledButton(onPressed: () => _create(context, ref), child: const Text('Neue Playlist')),
        ),
        Expanded(
          child: AsyncBody(
            value: playlists,
            onRetry: () => ref.invalidate(libraryOverviewProvider),
            builder: (library) {
              final editable = library.playlists.where((p) => p.canEdit).toList();
              if (editable.isEmpty) {
                return const EmptyState(icon: Icons.queue_music_rounded, title: 'Noch keine Playlists');
              }
              return ListView.builder(
                controller: controller,
                itemCount: editable.length,
                itemBuilder: (context, index) {
                  final playlist = editable[index];
                  return ListTile(
                    leading: PlaylistCover(coverId: playlist.coverId, mosaic: playlist.mosaic, size: 48),
                    title: Text(playlist.name, style: AppText.tileTitle),
                    subtitle: Text(
                      '${playlist.isCollaborative ? 'Gemeinsam · ' : ''}${pluralSongs(playlist.trackCount)}',
                      style: AppText.tileSubtitle,
                    ),
                    onTap: () => _add(context, ref, playlist),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
