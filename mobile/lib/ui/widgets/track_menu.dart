import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/models.dart';
import '../../player/player.dart';
import '../../state/auth.dart';
import '../../state/library.dart';
import '../../state/likes.dart';
import '../../state/offline.dart';
import '../nav.dart';
import 'common.dart';
import 'cover.dart';
import 'playlist_picker.dart';

/// Zusätzlicher Menüeintrag (z. B. "Aus dieser Playlist entfernen").
class TrackMenuAction {
  final IconData icon;
  final String label;
  final Future<void> Function() onTap;
  const TrackMenuAction({required this.icon, required this.label, required this.onTap});
}

/// Menü zu einem Titel (wie das "…"-Menü bei Spotify).
Future<void> showTrackMenu(BuildContext context, WidgetRef ref, Track track,
    {List<TrackMenuAction> extraActions = const []}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    builder: (sheetContext) => _TrackMenu(track: track, extraActions: extraActions, parentContext: context),
  );
}

class _TrackMenu extends ConsumerWidget {
  final Track track;
  final List<TrackMenuAction> extraActions;
  final BuildContext parentContext;

  const _TrackMenu({required this.track, required this.extraActions, required this.parentContext});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final liked = ref.watch(isTrackLikedProvider(track.id));
    final downloaded = ref.watch(isDownloadedProvider(track.id));
    final user = ref.watch(currentUserProvider);
    final player = ref.read(playerProvider);

    void close() => Navigator.of(context).pop();
    // Bleibt gültig, wenn das Menü schon geschlossen ist (ref gehört zum Menü und ist dann weg)
    final container = ProviderScope.containerOf(context, listen: false);

    Future<void> run(Future<void> Function() action, {String? done}) async {
      close();
      try {
        await action();
        if (done != null && parentContext.mounted) showMessage(parentContext, done);
      } catch (e) {
        if (parentContext.mounted) showError(parentContext, e);
      }
    }

    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: CoverImage(coverId: track.coverId, size: 48),
              title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.tileTitle),
              subtitle: Text(track.artistDisplay, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.tileSubtitle),
            ),
            const Divider(),
            ListTile(
              leading: Icon(liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                  color: liked ? AppColors.accent : null),
              title: Text(liked ? 'Aus Lieblingssongs entfernen' : 'Zu Lieblingssongs hinzufügen'),
              onTap: () => run(() => ref.read(likesProvider.notifier).toggleTrack(track.id)),
            ),
            ListTile(
              leading: const Icon(Icons.playlist_add_rounded),
              title: const Text('Zu Playlist hinzufügen'),
              onTap: () {
                close();
                showAddToPlaylist(parentContext, ref, [track]);
              },
            ),
            // Videos laufen in der Warteschlange als Ton
            ListTile(
              leading: const Icon(Icons.queue_play_next_rounded),
              title: const Text('Als Nächstes spielen'),
              onTap: () => run(() => player.playNext([track]), done: 'Wird als Nächstes gespielt'),
            ),
            ListTile(
              leading: const Icon(Icons.queue_music_rounded),
              title: const Text('Zur Warteschlange hinzufügen'),
              onTap: () => run(() => player.addToQueue([track]), done: 'Zur Warteschlange hinzugefügt'),
            ),
            if (!track.isVideo) ...[
              ListTile(
                leading: const Icon(Icons.radio_rounded),
                title: const Text('Radio zu diesem Song'),
                onTap: () => run(() => player.startRadio(track)),
              ),
              ListTile(
                leading: Icon(downloaded ? Icons.download_done_rounded : Icons.download_for_offline_outlined,
                    color: downloaded ? AppColors.accent : null),
                title: Text(downloaded ? 'Vom Handy entfernen' : 'Aufs Handy laden (offline)'),
                onTap: () => run(() async {
                  final offline = ref.read(offlineProvider.notifier);
                  downloaded ? await offline.removeTrack(track.id) : offline.downloadTracks([track]);
                }, done: downloaded ? 'Vom Handy entfernt' : 'Wird aufs Handy geladen'),
              ),
            ],
            if (track.album != null)
              ListTile(
                leading: const Icon(Icons.album_rounded),
                title: const Text('Zum Album'),
                onTap: () {
                  close();
                  Nav.album(parentContext, track.album!.id);
                },
              ),
            for (final artist in track.artists)
              ListTile(
                leading: const Icon(Icons.person_rounded),
                title: Text(track.artists.length > 1 ? 'Zu ${artist.name}' : 'Zum Künstler'),
                onTap: () {
                  close();
                  Nav.artist(parentContext, artist.id);
                },
              ),
            for (final action in extraActions)
              ListTile(leading: Icon(action.icon), title: Text(action.label), onTap: () => run(action.onTap)),
            if (user?.isAdmin == true)
              ListTile(
                leading: const Icon(Icons.delete_forever_rounded, color: AppColors.danger),
                title: const Text('Datei vom Server löschen', style: TextStyle(color: AppColors.danger)),
                onTap: () async {
                  close();
                  final ok = await confirm(parentContext,
                      title: '„${track.title}“ löschen?',
                      message: 'Die Datei wird auf dem Server gelöscht und verschwindet für alle.',
                      confirmLabel: 'Löschen',
                      danger: true);
                  if (!ok) return;
                  try {
                    await container.read(apiProvider)!.deleteTrack(track.id, deleteFile: true);
                    container.invalidate(homeProvider);
                    container.invalidate(libraryOverviewProvider);
                    if (parentContext.mounted) showMessage(parentContext, 'Gelöscht');
                  } catch (e) {
                    if (parentContext.mounted) showError(parentContext, e);
                  }
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
