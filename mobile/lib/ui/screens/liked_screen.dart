import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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
import 'library_widgets.dart';

/// „Lieblingssongs“ – alle Songs mit Herz, die neuesten zuerst.
class LikedSongsScreen extends ConsumerStatefulWidget {
  const LikedSongsScreen({super.key});

  @override
  ConsumerState<LikedSongsScreen> createState() => _LikedSongsScreenState();
}

class _LikedSongsScreenState extends ConsumerState<LikedSongsScreen> {
  static const _title = 'Lieblingssongs';
  static const _playContext = PlayContext('liked', title: _title);

  final _filter = TextEditingController();
  String _query = '';
  List<LikedTrack>? _synced;

  @override
  void initState() {
    super.initState();
    // Offline gehaltene Lieblingssongs aktuell halten (neue Herzen nachladen, entfernte löschen)
    ref.listenManual(likedTracksProvider, (_, next) => _maybeSync(next), fireImmediately: true);
    ref.listenManual(offlineProvider.select((s) => s.loaded), (_, loaded) {
      if (loaded) _maybeSync(ref.read(likedTracksProvider));
    });
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  void _maybeSync(AsyncValue<List<LikedTrack>> value) {
    final items = value.value;
    if (items == null || value.isLoading || value.hasError || identical(items, _synced)) return;
    final offline = ref.read(offlineProvider);
    if (!offline.loaded) return;
    _synced = items;
    if (!offline.isCollectionOffline(likedKey)) return;
    final tracks = items.map((e) => e.track).toList();
    Future.microtask(() => ref.read(offlineProvider.notifier).syncCollection(likedKey, tracks));
  }

  Future<void> _refresh() async {
    if (ref.read(isOfflineProvider)) {
      showMessage(context, 'Du bist offline – hier sind deine Songs auf diesem Gerät');
      return;
    }
    ref.invalidate(likedTracksProvider);
    try {
      await ref.read(likedTracksProvider.future);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// Heruntergeladene Lieblingssongs (ohne Server).
  List<Track> _offlineTracks(OfflineState offline, Set<int> likedIds) {
    final fromCollection = offlineCollectionTracks(offline, likedKey);
    final seen = fromCollection.map((t) => t.id).toSet();
    final extra =
        offline.tracks.values.where((o) => likedIds.contains(o.track.id) && !seen.contains(o.track.id)).toList()
          ..sort((a, b) => b.savedAt.compareTo(a.savedAt));
    return [...fromCollection, ...extra.map((o) => o.track)];
  }

  void _showMenu(List<Track> tracks) {
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const LikedSongsCover(size: 48),
              title: const Text(_title, style: AppText.tileTitle),
              subtitle: Text(pluralSongs(tracks.length), style: AppText.tileSubtitle),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.queue_music_rounded),
              title: const Text('Zur Warteschlange hinzufügen'),
              onTap: () async {
                Navigator.of(sheetContext).pop();
                try {
                  await ref.read(playerProvider).addToQueue(tracks);
                  if (mounted) showMessage(context, '${pluralSongs(tracks.length)} zur Warteschlange hinzugefügt');
                } catch (e) {
                  if (mounted) showError(context, e);
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.playlist_add_rounded),
              title: const Text('Zu Playlist hinzufügen'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                showAddToPlaylist(context, ref, tracks);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final liked = ref.watch(likedTracksProvider);
    final noNetwork = ref.watch(isOfflineProvider);
    final offline = ref.watch(offlineProvider);
    final likedIds = ref.watch(likesProvider).value?.tracks ?? const <int>{};
    final userName = ref.watch(currentUserProvider)?.displayName ?? '';

    final serverItems = liked.value;
    final offlineTracks = serverItems == null ? _offlineTracks(offline, likedIds) : const <Track>[];
    // Ohne Netz (oder wenn der Server nicht antwortet) die heruntergeladenen Songs zeigen
    final useOffline = serverItems == null && (noNetwork || (liked.hasError && offlineTracks.isNotEmpty));

    return LibraryGradientScaffold(
      title: _title,
      color: AppColors.liked,
      bodyBuilder: (context, topInset) {
        if (useOffline) {
          return _buildContent(
            context,
            topInset,
            offlineTracks,
            userName: userName,
            fromOffline: true,
            onRetry: noNetwork ? null : () => ref.invalidate(likedTracksProvider),
          );
        }
        if (serverItems == null) {
          if (liked.hasError) {
            return ErrorView(message: errorText(liked.error!), onRetry: () => ref.invalidate(likedTracksProvider));
          }
          return const Center(child: CircularProgressIndicator());
        }
        return _buildContent(
          context,
          topInset,
          serverItems.map((e) => e.track).toList(),
          userName: userName,
          fromOffline: false,
        );
      },
    );
  }

  Widget _buildContent(
    BuildContext context,
    double topInset,
    List<Track> tracks, {
    required String userName,
    required bool fromOffline,
    VoidCallback? onRetry,
  }) {
    final filtered = _query.isEmpty ? tracks : tracks.where((t) => trackMatches(t, _query)).toList();
    final slivers = <Widget>[
      SliverToBoxAdapter(
        child: _header(topInset, tracks, name: userName, fromOffline: fromOffline, onRetry: onRetry),
      ),
    ];

    if (tracks.isEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: fromOffline
                ? const EmptyState(
                    icon: Icons.cloud_off_rounded,
                    title: 'Keine Lieblingssongs auf dem Handy',
                    message: 'Tippe auf den Pfeil nach unten, damit du deine Lieblingssongs auch ohne Verbindung hören kannst.',
                  )
                : EmptyState(
                    icon: Icons.favorite_border_rounded,
                    title: 'Songs, die dir gefallen, landen hier.',
                    message: 'Tippe bei einem Song auf das Herz, um ihn hier zu speichern.',
                    action: OutlinedButton(onPressed: () => context.go('/search'), child: const Text('Songs suchen')),
                  ),
          ),
        ),
      );
    } else if (filtered.isEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: EmptyState(
            icon: Icons.search_off_rounded,
            title: 'Keine Treffer für „$_query“',
            message: 'Versuch es mit einem anderen Titel oder Künstler.',
          ),
        ),
      );
    } else {
      slivers.add(
        SliverList.builder(
          itemCount: filtered.length,
          itemBuilder: (context, index) => LibraryTrackRow(
            key: ValueKey(filtered[index].id),
            track: filtered[index],
            queue: tracks,
            playContext: _playContext,
          ),
        ),
      );
    }
    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 32)));

    return RefreshIndicator(
      color: AppColors.accent,
      edgeOffset: topInset,
      onRefresh: _refresh,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: slivers,
      ),
    );
  }

  Widget _header(
    double topInset,
    List<Track> tracks, {
    required String name,
    required bool fromOffline,
    VoidCallback? onRetry,
  }) {
    return LibraryHeaderGradient(
      color: AppColors.liked,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, topInset + 8, 16, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (tracks.isNotEmpty) ...[
              ListFilterField(
                controller: _filter,
                hint: 'In Lieblingssongs suchen',
                onChanged: (value) => setState(() => _query = value.trim()),
              ),
              const SizedBox(height: 20),
            ] else
              const SizedBox(height: 12),
            const HeaderCover(child: LikedSongsCover(size: 200, radius: 6)),
            const SizedBox(height: 22),
            const Text(
              _title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: Colors.white),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                if (name.isNotEmpty) ...[InitialAvatar(name: name, size: 22), const SizedBox(width: 8)],
                Expanded(
                  child: Text(
                    [if (name.isNotEmpty) name, pluralSongs(tracks.length)].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white),
                  ),
                ),
              ],
            ),
            if (fromOffline) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  const Icon(Icons.cloud_off_rounded, size: 14, color: AppColors.textSecondary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      onRetry == null
                          ? 'Offline – nur Songs auf diesem Gerät'
                          : 'Server nicht erreichbar – Songs auf diesem Gerät',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
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
            ],
            const SizedBox(height: 4),
            Row(
              children: [
                OfflineCollectionButton(collectionKey: likedKey, name: _title, tracks: tracks, canKeep: !fromOffline),
                IconButton(
                  tooltip: 'Mehr',
                  color: AppColors.textSecondary,
                  icon: const Icon(Icons.more_vert_rounded),
                  onPressed: tracks.isEmpty ? null : () => _showMenu(tracks),
                ),
                const Spacer(),
                LibraryPlayControls(tracks: tracks, playContext: _playContext, matches: (c) => c.type == 'liked'),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
