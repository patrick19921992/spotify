import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../player/player.dart';
import '../../state/auth.dart';
import '../../state/connectivity.dart';
import '../../state/library.dart';
import '../../state/likes.dart';
import '../../state/offline.dart';
import '../widgets/common.dart';
import '../widgets/cover.dart';
import '../widgets/playlist_picker.dart';
import '../widgets/track_menu.dart';
import 'library_playlist_sheets.dart';
import 'library_widgets.dart';

/// Eine Playlist: eigene, gemeinsame oder die eines anderen Familienmitglieds.
class PlaylistScreen extends ConsumerStatefulWidget {
  final int playlistId;
  const PlaylistScreen({super.key, required this.playlistId});

  @override
  ConsumerState<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends ConsumerState<PlaylistScreen> {
  int get _id => widget.playlistId;
  String get _key => playlistKey(_id);

  PlaylistDetail? _synced;
  bool _coverBusy = false;

  // Umsortieren
  bool _reorder = false;
  bool _finishingReorder = false;
  List<PlaylistItem>? _order;
  Future<void> _moves = Future.value();
  int _pendingMoves = 0;
  int _moveGeneration = 0;

  @override
  void initState() {
    super.initState();
    // Offline gehaltene Playlist nach jedem Laden abgleichen (neue Songs nachladen, entfernte löschen)
    ref.listenManual(playlistProvider(_id), (_, next) => _maybeSync(next), fireImmediately: true);
    ref.listenManual(offlineProvider.select((s) => s.loaded), (_, loaded) {
      if (loaded) _maybeSync(ref.read(playlistProvider(_id)));
    });
  }

  void _maybeSync(AsyncValue<PlaylistDetail> value) {
    final detail = value.value;
    if (detail == null || value.isLoading || value.hasError || identical(detail, _synced)) return;
    final offline = ref.read(offlineProvider);
    if (!offline.loaded) return;
    _synced = detail;
    if (!offline.isCollectionOffline(_key)) return;
    final tracks = detail.tracks;
    final name = detail.playlist.name;
    final renamed = offline.collectionNames[_key] != name;
    Future.microtask(() async {
      final notifier = ref.read(offlineProvider.notifier);
      await notifier.syncCollection(_key, tracks);
      if (renamed) await notifier.keepCollection(_key, name, tracks);
    });
  }

  void _invalidateLists() {
    ref.invalidate(libraryOverviewProvider);
    ref.invalidate(myPlaylistsProvider);
    ref.invalidate(familyPlaylistsProvider);
  }

  Future<void> _refresh() async {
    if (ref.read(isOfflineProvider)) {
      showMessage(context, 'Du bist offline');
      return;
    }
    ref.invalidate(playlistProvider(_id));
    try {
      await ref.read(playlistProvider(_id).future);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  bool _canManage(Playlist playlist) => playlist.isOwner || (ref.read(currentUserProvider)?.isAdmin ?? false);

  // ------------------------------------------------------------------ Aktionen

  Future<void> _edit(Playlist playlist, List<Track> tracks) async {
    final result = await showEditPlaylistDialog(context, playlist);
    if (result == null || !mounted) return;
    try {
      await ref
          .read(apiProvider)!
          .updatePlaylist(
            _id,
            name: result.name,
            description: result.description,
            isPublic: result.isPublic,
            isCollaborative: result.isCollaborative,
          );
      final offline = ref.read(offlineProvider);
      if (offline.isCollectionOffline(_key) && offline.collectionNames[_key] != result.name) {
        await ref.read(offlineProvider.notifier).keepCollection(_key, result.name, tracks);
      }
      ref.invalidate(playlistProvider(_id));
      _invalidateLists();
      if (mounted) showMessage(context, 'Änderungen gespeichert');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _changeCover() async {
    XFile? picked;
    try {
      picked = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1600);
    } on PlatformException catch (e) {
      if (mounted) {
        showMessage(
          context,
          e.code.contains('denied')
              ? 'Kein Zugriff auf deine Fotos – bitte in den Einstellungen erlauben'
              : 'Bild konnte nicht geöffnet werden',
        );
      }
      return;
    }
    if (picked == null || !mounted) return;
    setState(() => _coverBusy = true);
    try {
      await ref.read(apiProvider)!.uploadPlaylistCover(_id, picked.path);
      ref.invalidate(playlistProvider(_id));
      _invalidateLists();
      if (mounted) showMessage(context, 'Cover geändert');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _coverBusy = false);
    }
  }

  Future<void> _removeCover() async {
    setState(() => _coverBusy = true);
    try {
      await ref.read(apiProvider)!.removePlaylistCover(_id);
      ref.invalidate(playlistProvider(_id));
      _invalidateLists();
      if (mounted) showMessage(context, 'Cover entfernt');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _coverBusy = false);
    }
  }

  Future<void> _delete(Playlist playlist) async {
    final ok = await confirm(
      context,
      title: 'Playlist löschen?',
      message:
          '„${playlist.name}“ wird gelöscht – auch für alle, die ihr folgen. Das kann nicht rückgängig gemacht werden.',
      confirmLabel: 'Löschen',
      danger: true,
    );
    if (!ok || !mounted) return;
    try {
      await ref.read(apiProvider)!.deletePlaylist(_id);
      if (ref.read(offlineProvider).isCollectionOffline(_key)) {
        await ref.read(offlineProvider.notifier).releaseCollection(_key);
      }
      _invalidateLists();
      ref.invalidate(homeProvider);
      if (!mounted) return;
      showMessage(context, 'Playlist „${playlist.name}“ gelöscht');
      if (context.canPop()) {
        context.pop();
      } else {
        context.go('/library');
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _toggleFollow(Playlist playlist, bool following) async {
    try {
      await ref.read(likesProvider.notifier).togglePlaylistFollow(_id);
      ref.invalidate(familyPlaylistsProvider);
      if (mounted) {
        showMessage(context, following ? 'Aus deiner Bibliothek entfernt' : 'Zu deiner Bibliothek hinzugefügt');
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _removeItem(PlaylistItem item, String name) async {
    await ref.read(apiProvider)!.removeFromPlaylist(_id, [item.itemId]);
    ref.invalidate(playlistProvider(_id));
    ref.invalidate(libraryOverviewProvider);
    if (mounted) showMessage(context, '„${item.track.title}“ aus „$name“ entfernt');
  }

  void _addSongs(PlaylistDetail detail) {
    showAddSongsSheet(
      context,
      playlistId: _id,
      playlistName: detail.playlist.name,
      existingTrackIds: detail.tracks.map((t) => t.id).toSet(),
      onOpenSearch: () {
        if (mounted) context.go('/search');
      },
    );
  }

  Future<void> _addToQueue(List<Track> tracks) async {
    try {
      await ref.read(playerProvider).addToQueue(tracks);
      if (mounted) showMessage(context, '${pluralSongs(tracks.length)} zur Warteschlange hinzugefügt');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  void _showCollaborativeInfo(PlaylistDetail detail) {
    final playlist = detail.playlist;
    showDialog<void>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.group_rounded, color: AppColors.accent, size: 36),
        title: const Text('Gemeinsame Playlist'),
        content: Text(
          'Alle in der Familie können Songs zu „${playlist.name}“ hinzufügen, entfernen und umsortieren.'
          '${playlist.isOwner ? '\n\nDu kannst das jederzeit unter „Bearbeiten“ ausschalten.' : ''}',
        ),
        actions: [
          if (playlist.canEdit)
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                _addSongs(detail);
              },
              child: const Text('Songs hinzufügen'),
            ),
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('OK')),
        ],
      ),
    );
  }

  void _showMenu(PlaylistDetail detail) {
    final playlist = detail.playlist;
    final tracks = detail.tracks;
    final manage = _canManage(playlist);
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        void close() => Navigator.of(sheetContext).pop();
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: PlaylistCover(coverId: playlist.coverId, mosaic: playlist.mosaic, size: 48),
                  title: Text(playlist.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.tileTitle),
                  subtitle: Text(
                    'Von ${playlist.owner.displayName} · ${pluralSongs(tracks.length)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.tileSubtitle,
                  ),
                ),
                const Divider(),
                if (manage) ...[
                  ListTile(
                    leading: const Icon(Icons.edit_rounded),
                    title: const Text('Bearbeiten'),
                    onTap: () {
                      close();
                      _edit(playlist, tracks);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.image_rounded),
                    title: const Text('Cover ändern'),
                    onTap: () {
                      close();
                      _changeCover();
                    },
                  ),
                  if (playlist.coverId != null)
                    ListTile(
                      leading: const Icon(Icons.hide_image_outlined),
                      title: const Text('Cover entfernen'),
                      onTap: () {
                        close();
                        _removeCover();
                      },
                    ),
                ],
                if (playlist.canEdit) ...[
                  ListTile(
                    leading: const Icon(Icons.add_rounded),
                    title: const Text('Songs hinzufügen'),
                    onTap: () {
                      close();
                      _addSongs(detail);
                    },
                  ),
                  if (detail.items.length > 1)
                    ListTile(
                      leading: const Icon(Icons.swap_vert_rounded),
                      title: const Text('Reihenfolge ändern'),
                      onTap: () {
                        close();
                        setState(() {
                          _reorder = true;
                          _order = null;
                        });
                      },
                    ),
                ],
                if (tracks.isNotEmpty)
                  ListTile(
                    leading: const Icon(Icons.queue_music_rounded),
                    title: const Text('Zur Warteschlange hinzufügen'),
                    onTap: () {
                      close();
                      _addToQueue(tracks);
                    },
                  ),
                if (tracks.isNotEmpty)
                  ListTile(
                    leading: const Icon(Icons.playlist_add_rounded),
                    title: const Text('Zu anderer Playlist hinzufügen'),
                    onTap: () {
                      close();
                      showAddToPlaylist(context, ref, tracks);
                    },
                  ),
                if (manage)
                  ListTile(
                    leading: const Icon(Icons.delete_outline_rounded, color: AppColors.danger),
                    title: const Text('Playlist löschen', style: TextStyle(color: AppColors.danger)),
                    onTap: () {
                      close();
                      _delete(playlist);
                    },
                  ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  // ------------------------------------------------------------------ Umsortieren

  void _move(List<PlaylistItem> items, int from, int to) {
    if (from == to) return;
    final updated = [...items];
    final item = updated.removeAt(from);
    updated.insert(to, item);
    final generation = _moveGeneration;
    setState(() {
      _order = updated;
      _pendingMoves++;
    });
    // Nacheinander an den Server schicken, damit die Positionen stimmen.
    // onReorderItem liefert die Zielposition schon ohne den verschobenen Eintrag.
    _moves = _moves.then((_) async {
      try {
        // Nach einem Fehler werden die restlichen (veralteten) Verschiebungen verworfen
        if (generation != _moveGeneration) return;
        final result = await ref.read(apiProvider)!.movePlaylistItem(_id, item.itemId, to);
        if (mounted && _pendingMoves == 1 && generation == _moveGeneration) {
          setState(() => _order = result.items);
        }
      } catch (e) {
        _moveGeneration++;
        if (mounted) {
          showError(context, e);
          ref.invalidate(playlistProvider(_id));
          setState(() => _order = null);
        }
      } finally {
        _pendingMoves--;
        if (mounted) setState(() {});
      }
    });
  }

  Future<void> _finishReorder() async {
    if (_finishingReorder) return;
    setState(() => _finishingReorder = true);
    await _moves;
    ref.invalidate(playlistProvider(_id));
    try {
      await ref.read(playlistProvider(_id).future);
    } catch (_) {
      // Fehler zeigt die Seite selbst an
    }
    ref.invalidate(libraryOverviewProvider);
    if (!mounted) return;
    setState(() {
      _reorder = false;
      _finishingReorder = false;
      _order = null;
    });
  }

  Widget _buildReorder(PlaylistDetail detail) {
    final items = _order ?? detail.items;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _finishReorder();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(tooltip: 'Fertig', icon: const Icon(Icons.close_rounded), onPressed: _finishReorder),
          title: const Text('Reihenfolge ändern', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          actions: [
            if (_pendingMoves > 0 || _finishingReorder)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            TextButton(
              onPressed: _finishingReorder ? null : _finishReorder,
              child: const Text(
                'Fertig',
                style: TextStyle(color: AppColors.accent, fontWeight: FontWeight.w700, fontSize: 15),
              ),
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: ReorderableListView.builder(
          buildDefaultDragHandles: false,
          padding: const EdgeInsets.only(bottom: 32),
          header: const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Text('Zieh die Songs am Griff rechts an die gewünschte Stelle.', style: AppText.caption),
          ),
          itemCount: items.length,
          onReorderItem: (from, to) => _move(items, from, to),
          proxyDecorator: (child, index, animation) => Material(
            color: AppColors.surfaceHigh,
            elevation: 8,
            borderRadius: BorderRadius.circular(6),
            child: child,
          ),
          itemBuilder: (context, index) {
            final item = items[index];
            return ReorderableDelayedDragStartListener(
              key: ValueKey(item.itemId),
              index: index,
              child: ListTile(
                leading: CoverImage(
                  coverId: item.track.coverId,
                  size: 44,
                  placeholderIcon: item.track.isVideo ? Icons.movie_rounded : Icons.music_note_rounded,
                ),
                title: Text(item.track.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.tileTitle),
                subtitle: Text(
                  item.track.artistDisplay,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.tileSubtitle,
                ),
                trailing: ReorderableDragStartListener(
                  index: index,
                  child: const Padding(
                    padding: EdgeInsets.all(8),
                    child: Icon(Icons.drag_handle_rounded, color: AppColors.textSecondary),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ Aufbau

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(playlistProvider(_id));
    final noNetwork = ref.watch(isOfflineProvider);
    final offline = ref.watch(offlineProvider);
    final detail = async.value;

    if (detail != null) {
      if (_reorder && detail.playlist.canEdit) return _buildReorder(detail);
      return _buildOnline(detail);
    }
    final kept = offline.isCollectionOffline(_key);
    if (noNetwork || (async.hasError && kept)) {
      return _buildOffline(
        offline,
        kept: kept,
        onRetry: noNetwork ? null : () => ref.invalidate(playlistProvider(_id)),
      );
    }
    return Scaffold(
      appBar: AppBar(),
      body: async.hasError
          ? ErrorView(message: errorText(async.error!), onRetry: () => ref.invalidate(playlistProvider(_id)))
          : const Center(child: CircularProgressIndicator()),
    );
  }

  Widget _buildOnline(PlaylistDetail detail) {
    final playlist = detail.playlist;
    final items = detail.items;
    final tracks = detail.tracks;
    final playContext = PlayContext('playlist', id: _id, title: playlist.name);
    final duration = tracks.fold<double>(0, (sum, t) => sum + t.duration);
    final likes = ref.watch(likesProvider).value;
    final following = likes?.playlists.contains(_id) ?? playlist.isFollowing;
    final color = parseHexColor(playlist.coverColor) ?? AppColors.surfaceHighest;

    final (badgeLabel, badgeIcon) = playlist.isCollaborative
        ? ('Gemeinsam', Icons.group_rounded)
        : playlist.isPublic
        ? ('Öffentlich', Icons.public_rounded)
        : ('Privat', Icons.lock_outline_rounded);

    Widget header(double topInset) => _PlaylistHeader(
      topInset: topInset,
      coverColor: playlist.coverColor,
      cover: Stack(
        alignment: Alignment.center,
        children: [
          PlaylistCover(coverId: playlist.coverId, mosaic: playlist.mosaic, size: 220, radius: 4),
          if (_coverBusy)
            Container(
              width: 220,
              height: 220,
              color: const Color(0x88000000),
              alignment: Alignment.center,
              child: const CircularProgressIndicator(),
            ),
        ],
      ),
      name: playlist.name,
      description: playlist.description,
      ownerName: playlist.owner.displayName,
      badge: InfoBadge(
        label: badgeLabel,
        icon: badgeIcon,
        color: playlist.isCollaborative ? AppColors.accent : AppColors.textSecondary,
      ),
      meta: tracks.isEmpty ? 'Noch keine Songs' : '${pluralSongs(tracks.length)} · ${formatLongDuration(duration)}',
      actions: [
        OfflineCollectionButton(collectionKey: _key, name: playlist.name, tracks: tracks),
        if (!playlist.isOwner)
          IconButton(
            tooltip: following ? 'Aus deiner Bibliothek entfernen' : 'Zu deiner Bibliothek hinzufügen',
            icon: Icon(
              following ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              color: following ? AppColors.accent : AppColors.textSecondary,
              size: 28,
            ),
            onPressed: () => _toggleFollow(playlist, following),
          ),
        if (playlist.isCollaborative)
          IconButton(
            tooltip: 'Gemeinsame Playlist',
            icon: const Icon(Icons.person_add_alt_1_rounded, color: AppColors.textSecondary, size: 26),
            onPressed: () => _showCollaborativeInfo(detail),
          ),
        IconButton(
          tooltip: 'Mehr',
          icon: const Icon(Icons.more_vert_rounded, color: AppColors.textSecondary, size: 26),
          onPressed: () => _showMenu(detail),
        ),
      ],
      tracks: tracks,
      playContext: playContext,
      playlistId: _id,
    );

    return LibraryGradientScaffold(
      title: playlist.name,
      color: color,
      bodyBuilder: (context, topInset) => RefreshIndicator(
        color: AppColors.accent,
        edgeOffset: topInset,
        onRefresh: _refresh,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(child: header(topInset)),
            if (items.isEmpty)
              SliverToBoxAdapter(
                child: EmptyState(
                  icon: Icons.queue_music_rounded,
                  title: 'Diese Playlist ist noch leer',
                  message: playlist.canEdit
                      ? 'Such dir Songs aus deiner Bibliothek aus und leg los.'
                      : 'Sobald Songs hinzugefügt werden, findest du sie hier.',
                  action: playlist.canEdit
                      ? FilledButton.icon(
                          onPressed: () => _addSongs(detail),
                          icon: const Icon(Icons.add_rounded),
                          label: const Text('Songs hinzufügen'),
                        )
                      : null,
                ),
              )
            else
              SliverList.builder(
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final item = items[index];
                  final addedBy = item.addedBy?.displayName;
                  return LibraryTrackRow(
                    key: ValueKey(item.itemId),
                    track: item.track,
                    queue: tracks,
                    queueIndex: index,
                    playContext: playContext,
                    caption: playlist.isCollaborative
                        ? [
                            'Hinzugefügt von ${addedBy == null || addedBy.isEmpty ? 'Unbekannt' : addedBy}',
                            formatRelative(item.addedAt),
                          ].join(' · ')
                        : null,
                    extraActions: playlist.canEdit
                        ? [
                            TrackMenuAction(
                              icon: Icons.remove_circle_outline_rounded,
                              label: 'Aus dieser Playlist entfernen',
                              onTap: () => _removeItem(item, playlist.name),
                            ),
                          ]
                        : const [],
                  );
                },
              ),
            if (items.isNotEmpty && playlist.canEdit)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Center(
                    child: OutlinedButton.icon(
                      onPressed: () => _addSongs(detail),
                      icon: const Icon(Icons.add_rounded, size: 20),
                      label: const Text('Songs hinzufügen'),
                    ),
                  ),
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 40)),
          ],
        ),
      ),
    );
  }

  /// Ohne Verbindung: die heruntergeladene Version der Playlist.
  Widget _buildOffline(OfflineState offline, {required bool kept, VoidCallback? onRetry}) {
    final name = offline.collectionNames[_key] ?? 'Playlist';
    if (!kept) {
      return Scaffold(
        appBar: AppBar(),
        body: EmptyState(
          icon: Icons.cloud_off_rounded,
          title: 'Du bist offline',
          message:
              'Diese Playlist ist nicht auf diesem Gerät. Ohne Verbindung kannst du nur Musik hören, '
              'die auf deinem Handy ist.',
          action: OutlinedButton(onPressed: () => context.go('/library'), child: const Text('Zur Bibliothek')),
        ),
      );
    }
    final tracks = offlineCollectionTracks(offline, _key);
    final total = offline.collections[_key]?.length ?? tracks.length;
    final playContext = PlayContext('playlist', id: _id, title: name);
    final coverColor = tracks.where((t) => t.coverColor != null).firstOrNull?.coverColor;
    final duration = tracks.fold<double>(0, (sum, t) => sum + t.duration);

    Widget header(double topInset) => _PlaylistHeader(
      topInset: topInset,
      coverColor: coverColor,
      cover: PlaylistCover(coverId: null, mosaic: mosaicFromTracks(tracks), size: 220, radius: 4),
      name: name,
      description: '',
      ownerName: null,
      badge: const InfoBadge(label: 'Offline', icon: Icons.cloud_off_rounded),
      meta: tracks.length < total
          ? '${tracks.length} von ${pluralSongs(total)} auf dem Handy'
          : '${pluralSongs(tracks.length)} · ${formatLongDuration(duration)}',
      notice: Row(
        children: [
          Expanded(
            child: Text(
              onRetry == null
                  ? 'Keine Verbindung – du siehst die Version auf diesem Gerät.'
                  : 'Server nicht erreichbar – du siehst die Version auf diesem Gerät.',
              style: AppText.caption,
            ),
          ),
          if (onRetry != null)
            TextButton(
              onPressed: onRetry,
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              child: const Text('Erneut versuchen', style: TextStyle(color: AppColors.accent)),
            ),
        ],
      ),
      actions: [
        OfflineCollectionButton(collectionKey: _key, name: name, tracks: tracks, canKeep: false),
        if (tracks.isNotEmpty)
          IconButton(
            tooltip: 'Zur Warteschlange hinzufügen',
            icon: const Icon(Icons.queue_music_rounded, color: AppColors.textSecondary, size: 26),
            onPressed: () => _addToQueue(tracks),
          ),
      ],
      tracks: tracks,
      playContext: playContext,
      playlistId: _id,
    );

    return LibraryGradientScaffold(
      title: name,
      color: parseHexColor(coverColor) ?? AppColors.surfaceHighest,
      bodyBuilder: (context, topInset) => RefreshIndicator(
        color: AppColors.accent,
        edgeOffset: topInset,
        onRefresh: _refresh,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(child: header(topInset)),
            if (tracks.isEmpty)
              const SliverToBoxAdapter(
                child: EmptyState(
                  icon: Icons.downloading_rounded,
                  title: 'Noch nichts auf dem Handy',
                  message: 'Die Songs dieser Playlist werden geladen, sobald du wieder online bist.',
                ),
              )
            else
              SliverList.builder(
                itemCount: tracks.length,
                itemBuilder: (context, index) => LibraryTrackRow(
                  key: ValueKey(tracks[index].id),
                  track: tracks[index],
                  queue: tracks,
                  playContext: playContext,
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 40)),
          ],
        ),
      ),
    );
  }
}

/// Kopfbereich: großes Cover, Name, Beschreibung, Ersteller, Infos und Aktionen.
class _PlaylistHeader extends StatelessWidget {
  final double topInset;
  final String? coverColor;
  final Widget cover;
  final String name;
  final String description;
  final String? ownerName;
  final Widget badge;
  final String meta;
  final Widget? notice;
  final List<Widget> actions;
  final List<Track> tracks;
  final PlayContext playContext;
  final int playlistId;

  const _PlaylistHeader({
    required this.topInset,
    required this.coverColor,
    required this.cover,
    required this.name,
    required this.description,
    required this.ownerName,
    required this.badge,
    required this.meta,
    this.notice,
    required this.actions,
    required this.tracks,
    required this.playContext,
    required this.playlistId,
  });

  @override
  Widget build(BuildContext context) {
    return CoverGradient(
      colorHex: coverColor,
      stop: 0.95,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, topInset + 12, 16, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            HeaderCover(child: cover),
            const SizedBox(height: 22),
            Text(
              name,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: Colors.white, height: 1.15),
            ),
            if (description.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(description, maxLines: 3, overflow: TextOverflow.ellipsis, style: AppText.tileSubtitle),
            ],
            if (ownerName != null) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  InitialAvatar(name: ownerName!, size: 22),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      'Von $ownerName',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.white),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                badge,
                const SizedBox(width: 8),
                Expanded(
                  child: Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption),
                ),
              ],
            ),
            if (notice != null) ...[const SizedBox(height: 6), notice!],
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(children: actions),
                  ),
                ),
                LibraryPlayControls(
                  tracks: tracks,
                  playContext: playContext,
                  matches: (c) => c.type == 'playlist' && c.id == playlistId,
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
