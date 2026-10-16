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
import '../../state/settings.dart';
import '../nav.dart';
import '../shell.dart';
import '../widgets/common.dart';
import '../widgets/cover.dart';
import 'library_entries.dart';
import 'library_widgets.dart';

enum _Filter {
  playlists('Playlists'),
  albums('Alben'),
  artists('Künstler'),
  downloaded('Auf diesem Gerät'),
  family('Familie');

  const _Filter(this.label);
  final String label;
}

/// „Deine Bibliothek“: Lieblingssongs, Playlists, gespeicherte Alben, gefolgte Künstler,
/// Heruntergeladenes und die Playlists der Familie.
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  static const _prefSort = 'library.sort';
  static const _prefGrid = 'library.grid';
  static const _downloadsContext = PlayContext('queue', title: 'Titel auf diesem Gerät');

  _Filter? _filter;
  bool _alphabetical = false;
  bool _grid = false;
  bool _showAllDownloaded = false;

  @override
  void initState() {
    super.initState();
    try {
      final prefs = ref.read(sharedPreferencesProvider);
      _alphabetical = prefs.getString(_prefSort) == 'alpha';
      _grid = prefs.getBool(_prefGrid) ?? false;
    } catch (_) {
      // Ansicht ist nur Komfort – Standardwerte reichen
    }
    if (ref.read(settingsProvider).offlineMode) _filter = _Filter.downloaded;
    // Offline-Modus eingeschaltet -> automatisch „Auf diesem Gerät“ zeigen
    ref.listenManual(settingsProvider.select((s) => s.offlineMode), (previous, now) {
      if (now && previous != true && mounted) setState(() => _filter = _Filter.downloaded);
    });
    // Wieder online -> Bibliothek neu laden
    ref.listenManual(isOfflineProvider, (previous, now) {
      if (previous == true && !now) {
        ref.invalidate(libraryOverviewProvider);
        ref.invalidate(recentProvider);
      }
    });
  }

  void _savePrefs() {
    try {
      final prefs = ref.read(sharedPreferencesProvider);
      prefs.setString(_prefSort, _alphabetical ? 'alpha' : 'recent');
      prefs.setBool(_prefGrid, _grid);
    } catch (_) {}
  }

  // ------------------------------------------------------------------ Aktionen

  Future<void> _createPlaylist() async {
    final name = await promptText(
      context,
      title: 'Neue Playlist',
      hint: 'Name der Playlist',
      confirmLabel: 'Erstellen',
    );
    if (name == null || name.isEmpty || !mounted) return;
    try {
      final created = await ref.read(apiProvider)!.createPlaylist(name: name);
      ref.invalidate(libraryOverviewProvider);
      ref.invalidate(myPlaylistsProvider);
      if (mounted) Nav.playlist(context, created.playlist.id);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _refreshOverview() async {
    if (ref.read(isOfflineProvider)) {
      showMessage(context, 'Du bist offline');
      return;
    }
    ref.invalidate(libraryOverviewProvider);
    ref.invalidate(recentProvider);
    try {
      await ref.read(libraryOverviewProvider.future);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _refreshFamily() async {
    if (ref.read(isOfflineProvider)) {
      showMessage(context, 'Du bist offline');
      return;
    }
    ref.invalidate(familyPlaylistsProvider);
    try {
      await ref.read(familyPlaylistsProvider.future);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _refreshDownloaded() async {
    if (ref.read(isOfflineProvider)) return;
    ref.invalidate(libraryOverviewProvider);
    try {
      await ref.read(libraryOverviewProvider.future);
    } catch (_) {
      // Downloads funktionieren auch ohne Server
    }
  }

  /// Sammlung herunterladen – die Titel werden dafür kurz vom Server geholt.
  Future<void> _keepOffline(String key, String name, Future<List<Track>> Function() load) async {
    try {
      final tracks = (await load()).where((t) => !t.isVideo).toList();
      if (tracks.isEmpty) {
        if (mounted) showMessage(context, 'Hier gibt es noch nichts, was aufs Gerät geladen werden kann');
        return;
      }
      await ref.read(offlineProvider.notifier).keepCollection(key, name, tracks);
      if (mounted) showMessage(context, '„$name“ wird aufs Handy geladen');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _releaseOffline(String key, String name) async {
    final ok = await confirm(
      context,
      title: 'Vom Gerät entfernen?',
      message: '„$name“ ist dann nicht mehr offline verfügbar.',
      confirmLabel: 'Entfernen',
      danger: true,
    );
    if (!ok) return;
    try {
      await ref.read(offlineProvider.notifier).releaseCollection(key);
      if (mounted) showMessage(context, 'Vom Handy entfernt');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _run(Future<void> Function() action, {String? done}) async {
    try {
      await action();
      if (done != null && mounted) showMessage(context, done);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _deletePlaylist(Playlist playlist) async {
    final ok = await confirm(
      context,
      title: 'Playlist löschen?',
      message: '„${playlist.name}“ wird gelöscht – auch für alle, die ihr folgen.',
      confirmLabel: 'Löschen',
      danger: true,
    );
    if (!ok || !mounted) return;
    await _run(() async {
      await ref.read(apiProvider)!.deletePlaylist(playlist.id);
      if (ref.read(offlineProvider).isCollectionOffline(playlistKey(playlist.id))) {
        await ref.read(offlineProvider.notifier).releaseCollection(playlistKey(playlist.id));
      }
      ref.invalidate(libraryOverviewProvider);
      ref.invalidate(myPlaylistsProvider);
      ref.invalidate(homeProvider);
    }, done: 'Playlist „${playlist.name}“ gelöscht');
  }

  /// Menü beim langen Drücken auf einen Eintrag.
  void _showEntryMenu({
    required Widget cover,
    required String title,
    required String subtitle,
    required List<({IconData icon, String label, VoidCallback onTap, bool danger})> actions,
  }) {
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: cover,
              title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.tileTitle),
              subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.tileSubtitle),
            ),
            const Divider(),
            for (final action in actions)
              ListTile(
                leading: Icon(action.icon, color: action.danger ? AppColors.danger : null),
                title: Text(action.label, style: action.danger ? const TextStyle(color: AppColors.danger) : null),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  action.onTap();
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  ({IconData icon, String label, VoidCallback onTap, bool danger}) _offlineAction(
    String key,
    String name,
    Future<List<Track>> Function() load,
  ) {
    final kept = ref.read(offlineProvider).isCollectionOffline(key);
    return kept
        ? (
            icon: Icons.download_done_rounded,
            label: 'Vom Gerät entfernen',
            onTap: () => _releaseOffline(key, name),
            danger: false,
          )
        : (
            icon: Icons.download_for_offline_outlined,
            label: 'Aufs Gerät laden',
            onTap: () => _keepOffline(key, name, load),
            danger: false,
          );
  }

  // ------------------------------------------------------------------ Einträge

  LibraryEntry _likedEntry(int count, {required bool offline, double? progress}) {
    const title = 'Lieblingssongs';
    final subtitle = 'Playlist · ${pluralSongs(count)}';
    return LibraryEntry(
      id: 'liked:',
      title: title,
      subtitle: progress == null ? subtitle : '$subtitle · ${formatPercent(progress)}',
      pinned: true,
      offline: offline && progress == null,
      progress: progress,
      cover: (size) => LikedSongsCover(size: size, radius: 4),
      onTap: () => Nav.liked(context),
      onLongPress: ref.read(isOfflineProvider)
          ? null
          : () => _showEntryMenu(
              cover: const LikedSongsCover(size: 48),
              title: title,
              subtitle: subtitle,
              actions: [_offlineAction(likedKey, title, _loadLikedTracks)],
            ),
    );
  }

  /// Alle Lieblingssongs vom Server (seitenweise), die neuesten zuerst.
  Future<List<Track>> _loadLikedTracks() async {
    final api = ref.read(apiProvider)!;
    final tracks = <Track>[];
    var offset = 0;
    while (true) {
      final page = await api.likes(limit: 500, offset: offset);
      tracks.addAll(page.items.map((e) => e.track));
      if (!page.hasMore || page.items.isEmpty) break;
      offset += page.items.length;
    }
    return tracks;
  }

  double? _progressOf(OfflineState offline, String key) {
    if (!offline.isCollectionOffline(key)) return null;
    final ids = offline.collections[key] ?? const <int>[];
    final progress = offline.collectionProgress(key);
    return ids.isEmpty || progress >= 1 ? null : progress;
  }

  LibraryEntry _playlistEntry(Playlist playlist, int order, OfflineState offline) {
    final key = playlistKey(playlist.id);
    final progress = _progressOf(offline, key);
    final subtitle = 'Playlist · ${playlist.owner.displayName}';
    final user = ref.read(currentUserProvider);
    final manage = playlist.isOwner || (user?.isAdmin ?? false);
    return LibraryEntry(
      id: 'playlist:${playlist.id}',
      title: playlist.name,
      subtitle: progress == null ? subtitle : '$subtitle · ${formatPercent(progress)}',
      order: order,
      offline: offline.isCollectionOffline(key) && progress == null,
      progress: progress,
      collaborative: playlist.isCollaborative,
      cover: (size) => PlaylistCover(coverId: playlist.coverId, mosaic: playlist.mosaic, size: size, radius: 4),
      onTap: () => Nav.playlist(context, playlist.id),
      onLongPress: () => _showEntryMenu(
        cover: PlaylistCover(coverId: playlist.coverId, mosaic: playlist.mosaic, size: 48),
        title: playlist.name,
        subtitle: subtitle,
        actions: [
          _offlineAction(key, playlist.name, () async => (await ref.read(apiProvider)!.playlist(playlist.id)).tracks),
          if (!playlist.isOwner)
            (
              icon: Icons.favorite_rounded,
              label: 'Aus deiner Bibliothek entfernen',
              onTap: () => _run(
                () => ref.read(likesProvider.notifier).togglePlaylistFollow(playlist.id),
                done: 'Aus deiner Bibliothek entfernt',
              ),
              danger: false,
            ),
          if (manage)
            (
              icon: Icons.delete_outline_rounded,
              label: 'Playlist löschen',
              onTap: () => _deletePlaylist(playlist),
              danger: true,
            ),
        ],
      ),
    );
  }

  LibraryEntry _albumEntry(Album album, int order, OfflineState offline) {
    final key = albumKey(album.id);
    final progress = _progressOf(offline, key);
    final subtitle = 'Album · ${album.artist.name}';
    return LibraryEntry(
      id: 'album:${album.id}',
      title: album.title,
      subtitle: progress == null ? subtitle : '$subtitle · ${formatPercent(progress)}',
      order: order,
      offline: offline.isCollectionOffline(key) && progress == null,
      progress: progress,
      cover: (size) => CoverImage(coverId: album.coverId, size: size, radius: 4, placeholderIcon: Icons.album_rounded),
      onTap: () => Nav.album(context, album.id),
      onLongPress: () => _showEntryMenu(
        cover: CoverImage(coverId: album.coverId, size: 48, placeholderIcon: Icons.album_rounded),
        title: album.title,
        subtitle: subtitle,
        actions: [
          _offlineAction(key, album.title, () async => (await ref.read(apiProvider)!.album(album.id)).tracks),
          (
            icon: Icons.remove_circle_outline_rounded,
            label: 'Aus deiner Bibliothek entfernen',
            onTap: () => _run(
              () => ref.read(likesProvider.notifier).toggleAlbum(album.id),
              done: 'Aus deiner Bibliothek entfernt',
            ),
            danger: false,
          ),
        ],
      ),
    );
  }

  LibraryEntry _artistEntry(Artist artist, int order) {
    return LibraryEntry(
      id: 'artist:${artist.id}',
      title: artist.name,
      subtitle: 'Künstler',
      order: order,
      circle: true,
      cover: (size) =>
          CoverImage(coverId: artist.coverId, size: size, circle: true, placeholderIcon: Icons.person_rounded),
      onTap: () => Nav.artist(context, artist.id),
      onLongPress: () => _showEntryMenu(
        cover: CoverImage(coverId: artist.coverId, size: 48, circle: true, placeholderIcon: Icons.person_rounded),
        title: artist.name,
        subtitle: 'Künstler',
        actions: [
          (
            icon: Icons.person_remove_outlined,
            label: 'Nicht mehr folgen',
            onTap: () => _run(
              () => ref.read(likesProvider.notifier).toggleArtist(artist.id),
              done: 'Du folgst ${artist.name} nicht mehr',
            ),
            danger: false,
          ),
        ],
      ),
    );
  }

  LibraryEntry _createEntry() => LibraryEntry(
    id: 'create:',
    title: 'Playlist erstellen',
    subtitle: 'Für dich oder die ganze Familie',
    order: 1 << 29,
    cover: (size) => SymbolCover(icon: Icons.add_rounded, size: size),
    onTap: _createPlaylist,
  );

  // ------------------------------------------------------------------ Aufbau

  @override
  Widget build(BuildContext context) {
    final noNetwork = ref.watch(isOfflineProvider);
    final user = ref.watch(currentUserProvider);
    // Immer beobachten, damit die Daten beim Filterwechsel nicht neu geladen werden
    final overview = ref.watch(libraryOverviewProvider);
    final filter = noNetwork ? _Filter.downloaded : _filter;

    return Scaffold(
      appBar: AppBar(
        leadingWidth: 60,
        leading: Padding(
          padding: const EdgeInsets.only(left: 16),
          child: Center(
            child: Tooltip(
              message: 'Einstellungen',
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => Nav.settings(context),
                child: InitialAvatar(name: user?.displayName ?? '', size: 34),
              ),
            ),
          ),
        ),
        titleSpacing: 12,
        title: const Text('Deine Bibliothek', maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          const DownloadsAction(),
          IconButton(
            tooltip: 'Playlist erstellen',
            icon: const Icon(Icons.add_rounded, size: 28),
            onPressed: noNetwork ? null : _createPlaylist,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          _filterChips(filter, noNetwork),
          Expanded(
            child: switch (filter) {
              _Filter.downloaded => _downloadedView(noNetwork),
              _Filter.family => _familyView(),
              _ => _overviewView(overview, filter),
            },
          ),
        ],
      ),
    );
  }

  Widget _filterChips(_Filter? filter, bool noNetwork) {
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
        children: [
          if (filter != null && !noNetwork) ...[
            SizedBox(
              width: 36,
              height: 36,
              child: Material(
                color: AppColors.surfaceHigh,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => setState(() => _filter = null),
                  child: const Icon(Icons.close_rounded, size: 18, color: Colors.white),
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          for (final option in _Filter.values) ...[
            ChoiceChip(
              label: Text(option.label),
              selected: filter == option,
              showCheckmark: false,
              visualDensity: VisualDensity.compact,
              labelStyle: TextStyle(
                color: filter == option ? Colors.black : (noNetwork ? AppColors.textMuted : Colors.white),
                fontWeight: FontWeight.w600,
                fontSize: 13.5,
              ),
              onSelected: noNetwork && option != _Filter.downloaded
                  ? null
                  : (_) => setState(() {
                      _filter = _filter == option ? null : option;
                      _showAllDownloaded = false;
                    }),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  /// „Zuletzt“/„Alphabetisch“ und Liste/Raster.
  Widget _sortBar({String? info}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 8, 4),
      child: Row(
        children: [
          TextButton.icon(
            onPressed: () {
              setState(() => _alphabetical = !_alphabetical);
              _savePrefs();
            },
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            icon: const Icon(Icons.swap_vert_rounded, size: 20),
            label: Text(
              _alphabetical ? 'Alphabetisch' : 'Zuletzt',
              style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
            ),
          ),
          if (info != null)
            Expanded(
              child: Text(info, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption),
            )
          else
            const Spacer(),
          IconButton(
            tooltip: _grid ? 'Als Liste anzeigen' : 'Als Raster anzeigen',
            icon: Icon(_grid ? Icons.view_list_rounded : Icons.grid_view_rounded, size: 20),
            color: Colors.white,
            onPressed: () {
              setState(() => _grid = !_grid);
              _savePrefs();
            },
          ),
        ],
      ),
    );
  }

  /// Einträge als Liste oder 3-spaltiges Raster.
  Widget _entriesSliver(List<LibraryEntry> entries) {
    if (!_grid) {
      return SliverList.builder(
        itemCount: entries.length,
        itemBuilder: (context, index) => LibraryEntryTile(key: ValueKey(entries[index].id), entry: entries[index]),
      );
    }
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        const spacing = 12.0;
        final cell = (constraints.crossAxisExtent - 32 - 2 * spacing) / 3;
        final textHeight = MediaQuery.textScalerOf(context).scale(36);
        return SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          sliver: SliverGrid.builder(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: spacing,
              mainAxisSpacing: 16,
              mainAxisExtent: cell + 8 + textHeight,
            ),
            itemCount: entries.length,
            itemBuilder: (context, index) => LibraryEntryCell(key: ValueKey(entries[index].id), entry: entries[index]),
          ),
        );
      },
    );
  }

  Widget _scroll({required Future<void> Function() onRefresh, required List<Widget> slivers}) {
    return RefreshIndicator(
      color: AppColors.accent,
      onRefresh: onRefresh,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          ...slivers,
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }

  Widget _emptySliver(Widget child) => SliverToBoxAdapter(
    child: Padding(padding: const EdgeInsets.only(top: 32), child: child),
  );

  // ------------------------------------------------------------------ Alles / Playlists / Alben / Künstler

  Widget _overviewView(AsyncValue<LibraryOverview> overview, _Filter? filter) {
    final data = overview.value;
    if (data == null) {
      if (overview.hasError) {
        return ErrorView(message: errorText(overview.error!), onRetry: () => ref.invalidate(libraryOverviewProvider));
      }
      return const Center(child: CircularProgressIndicator());
    }
    final offline = ref.watch(offlineProvider);
    final recent = ref.watch(recentProvider).value ?? const <ContextItem>[];
    final recentRank = <String, int>{};
    for (final (index, item) in recent.indexed) {
      recentRank.putIfAbsent('${item.type}:${item.id}', () => index);
    }

    final isNewUser = data.likedCount == 0 && data.playlists.isEmpty && data.albums.isEmpty && data.artists.isEmpty;
    if (isNewUser && (filter == null || filter == _Filter.playlists)) {
      return _scroll(
        onRefresh: _refreshOverview,
        slivers: [
          _emptySliver(
            EmptyState(
              icon: Icons.library_music_rounded,
              title: 'Erstelle deine erste Playlist',
              message:
                  'Sammle deine Lieblingsmusik in Playlists – nur für dich oder für die ganze Familie. '
                  'Songs mit Herz landen automatisch in deinen Lieblingssongs.',
              action: Column(
                children: [
                  FilledButton(onPressed: _createPlaylist, child: const Text('Playlist erstellen')),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: () => setState(() => _filter = _Filter.family),
                    child: const Text('Playlists der Familie entdecken', style: TextStyle(color: Colors.white)),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    final likedProgress = _progressOf(offline, likedKey);
    final entries = <LibraryEntry>[
      if (filter == null || filter == _Filter.playlists)
        _likedEntry(data.likedCount, offline: offline.isCollectionOffline(likedKey), progress: likedProgress),
      if (filter == null || filter == _Filter.playlists)
        for (final (index, playlist) in data.playlists.indexed) _playlistEntry(playlist, index, offline),
      if (filter == null || filter == _Filter.albums)
        for (final (index, album) in data.albums.indexed) _albumEntry(album, 1000 + index, offline),
      if (filter == null || filter == _Filter.artists)
        for (final (index, artist) in data.artists.indexed) _artistEntry(artist, 2000 + index),
    ];
    final sorted = sortLibraryEntries(entries, alphabetical: _alphabetical, recentRank: recentRank);
    if (filter == null || filter == _Filter.playlists) sorted.add(_createEntry());

    final slivers = <Widget>[SliverToBoxAdapter(child: _sortBar())];
    if (filter == _Filter.albums && data.albums.isEmpty) {
      slivers.add(
        _emptySliver(
          EmptyState(
            icon: Icons.album_rounded,
            title: 'Noch keine Alben gespeichert',
            message: 'Speichere Alben, die du magst – dann findest du sie hier schnell wieder.',
            action: OutlinedButton(onPressed: () => context.go('/search'), child: const Text('Musik entdecken')),
          ),
        ),
      );
    } else if (filter == _Filter.artists && data.artists.isEmpty) {
      slivers.add(
        _emptySliver(
          EmptyState(
            icon: Icons.person_search_rounded,
            title: 'Du folgst noch keinen Künstlern',
            message: 'Folge Künstlern, die du magst – dann findest du sie hier schnell wieder.',
            action: OutlinedButton(onPressed: () => context.go('/search'), child: const Text('Künstler finden')),
          ),
        ),
      );
    } else {
      slivers.add(_entriesSliver(sorted));
    }
    return _scroll(onRefresh: _refreshOverview, slivers: slivers);
  }

  // ------------------------------------------------------------------ Familie

  Widget _familyView() {
    final family = ref.watch(familyPlaylistsProvider);
    final data = family.value;
    if (data == null) {
      if (family.hasError) {
        return ErrorView(message: errorText(family.error!), onRetry: () => ref.invalidate(familyPlaylistsProvider));
      }
      return const Center(child: CircularProgressIndicator());
    }
    if (data.isEmpty) {
      return _scroll(
        onRefresh: _refreshFamily,
        slivers: [
          _emptySliver(
            const EmptyState(
              icon: Icons.groups_rounded,
              title: 'Noch nichts von der Familie',
              message: 'Wenn andere ihre Playlists für die Familie sichtbar machen, findest du sie hier.',
            ),
          ),
        ],
      );
    }
    final followed = ref.watch(likesProvider).value?.playlists;
    final offline = ref.watch(offlineProvider);
    final entries = [for (final (index, playlist) in data.indexed) _familyEntry(playlist, index, offline, followed)];
    return _scroll(
      onRefresh: _refreshFamily,
      slivers: [
        SliverToBoxAdapter(child: _sortBar(info: 'Öffentliche Playlists der anderen')),
        _entriesSliver(sortLibraryEntries(entries, alphabetical: _alphabetical)),
      ],
    );
  }

  LibraryEntry _familyEntry(Playlist playlist, int order, OfflineState offline, Set<int>? followed) {
    final following = followed?.contains(playlist.id) ?? playlist.isFollowing;
    final key = playlistKey(playlist.id);
    final progress = _progressOf(offline, key);
    final subtitle = 'Von ${playlist.owner.displayName}';
    Future<void> toggle() => _run(
      () => ref.read(likesProvider.notifier).togglePlaylistFollow(playlist.id),
      done: following ? 'Aus deiner Bibliothek entfernt' : 'Zu deiner Bibliothek hinzugefügt',
    );
    return LibraryEntry(
      id: 'playlist:${playlist.id}',
      title: playlist.name,
      subtitle: subtitle,
      order: order,
      collaborative: playlist.isCollaborative,
      following: _grid && following,
      offline: offline.isCollectionOffline(key) && progress == null,
      progress: progress,
      cover: (size) => PlaylistCover(coverId: playlist.coverId, mosaic: playlist.mosaic, size: size, radius: 4),
      onTap: () => Nav.playlist(context, playlist.id),
      onLongPress: () => _showEntryMenu(
        cover: PlaylistCover(coverId: playlist.coverId, mosaic: playlist.mosaic, size: 48),
        title: playlist.name,
        subtitle: subtitle,
        actions: [
          (
            icon: following ? Icons.favorite_rounded : Icons.favorite_border_rounded,
            label: following ? 'Aus deiner Bibliothek entfernen' : 'Zu deiner Bibliothek hinzufügen',
            onTap: toggle,
            danger: false,
          ),
          _offlineAction(key, playlist.name, () async => (await ref.read(apiProvider)!.playlist(playlist.id)).tracks),
        ],
      ),
      trailing: IconButton(
        tooltip: following ? 'Nicht mehr folgen' : 'Folgen',
        icon: Icon(
          following ? Icons.favorite_rounded : Icons.favorite_border_rounded,
          color: following ? AppColors.accent : AppColors.textSecondary,
        ),
        onPressed: toggle,
      ),
    );
  }

  // ------------------------------------------------------------------ Heruntergeladen

  Widget _downloadedView(bool noNetwork) {
    final offline = ref.watch(offlineProvider);
    if (!offline.loaded) return const Center(child: CircularProgressIndicator());
    final overview = ref.watch(libraryOverviewProvider).value;
    final settings = ref.watch(settingsProvider);
    final onWifi = ref.watch(isOnWifiProvider);

    final entries = <LibraryEntry>[];
    final keys = offline.collections.keys.toList().reversed.toList(); // zuletzt geladen zuerst
    for (final (index, key) in keys.indexed) {
      final entry = _downloadedEntry(key, index, offline, overview);
      if (entry != null) entries.add(entry);
    }
    final sorted = sortLibraryEntries(entries, alphabetical: _alphabetical);

    final allTracks = offline.tracks.values.toList()
      ..sort(
        _alphabetical
            ? (a, b) => sortKey(a.track.title).compareTo(sortKey(b.track.title))
            : (a, b) => b.savedAt.compareTo(a.savedAt),
      );
    final queue = allTracks.map((o) => o.track).toList();

    final pendingCount = offline.pending.length;
    final waitingForWifi = pendingCount > 0 && settings.offlineWifiOnly && !onWifi && !noNetwork;

    if (sorted.isEmpty && queue.isEmpty && pendingCount == 0) {
      return _scroll(
        onRefresh: _refreshDownloaded,
        slivers: [
          _emptySliver(
            EmptyState(
              icon: Icons.download_for_offline_outlined,
              title: 'Noch nichts auf diesem Gerät',
              message: noNetwork
                  ? 'Ohne Verbindung kannst du nur Musik hören, die auf deinem Handy ist. '
                        'Tippe beim nächsten Mal bei Playlists, Alben oder Lieblingssongs auf den Pfeil nach unten.'
                  : 'Tippe bei Playlists, Alben oder deinen Lieblingssongs auf den Pfeil nach unten, '
                        'um sie ohne Internet zu hören.',
            ),
          ),
        ],
      );
    }

    final slivers = <Widget>[
      SliverToBoxAdapter(child: _sortBar(info: '${formatBytes(offline.totalBytes)} auf diesem Gerät')),
      if (pendingCount > 0)
        SliverToBoxAdapter(
          child: _pendingCard(offline, pendingCount, waitingForWifi: waitingForWifi, noNetwork: noNetwork),
        ),
      if (queue.isNotEmpty) SliverToBoxAdapter(child: _allDownloadedTile(queue, offline.totalBytes)),
      if (_showAllDownloaded && queue.isNotEmpty)
        SliverList.builder(
          itemCount: queue.length,
          itemBuilder: (context, index) => LibraryTrackRow(
            key: ValueKey('offline-${queue[index].id}'),
            track: queue[index],
            queue: queue,
            playContext: _downloadsContext,
          ),
        ),
      if (_showAllDownloaded && queue.isNotEmpty && sorted.isNotEmpty)
        const SliverToBoxAdapter(child: Divider(indent: 16, endIndent: 16, height: 24)),
      _entriesSliver(sorted),
    ];
    return _scroll(onRefresh: _refreshDownloaded, slivers: slivers);
  }

  LibraryEntry? _downloadedEntry(String key, int order, OfflineState offline, LibraryOverview? overview) {
    final ids = offline.collections[key] ?? const <int>[];
    final tracks = offlineCollectionTracks(offline, key);
    final progress = _progressOf(offline, key);
    final name = offline.collectionNames[key];
    String withProgress(String text) => progress == null ? text : '$text · ${formatPercent(progress)}';
    VoidCallback release(String title) =>
        () => _showEntryMenu(
          cover: SymbolCover(icon: Icons.download_done_rounded, size: 48, iconColor: AppColors.accent),
          title: title,
          subtitle: pluralSongs(ids.length),
          actions: [
            (
              icon: Icons.download_done_rounded,
              label: 'Vom Gerät entfernen',
              onTap: () => _releaseOffline(key, title),
              danger: false,
            ),
          ],
        );

    if (key == likedKey) {
      const title = 'Lieblingssongs';
      return LibraryEntry(
        id: 'liked:',
        title: title,
        subtitle: withProgress('Playlist · ${pluralSongs(ids.length)}'),
        pinned: true,
        offline: progress == null,
        progress: progress,
        cover: (size) => LikedSongsCover(size: size, radius: 4),
        onTap: () => Nav.liked(context),
        onLongPress: release(title),
      );
    }
    final separator = key.indexOf(':');
    if (separator < 0) return null;
    final type = key.substring(0, separator);
    final id = int.tryParse(key.substring(separator + 1));
    if (id == null) return null;

    if (type == 'playlist') {
      final playlist = overview?.playlists.where((p) => p.id == id).firstOrNull;
      final title = name ?? playlist?.name ?? 'Playlist';
      final mosaic = playlist?.mosaic ?? mosaicFromTracks(tracks);
      final coverId = playlist?.coverId;
      return LibraryEntry(
        id: key,
        title: title,
        subtitle: withProgress('Playlist · ${pluralSongs(ids.length)}'),
        order: order,
        offline: progress == null,
        progress: progress,
        collaborative: playlist?.isCollaborative ?? false,
        cover: (size) => PlaylistCover(coverId: coverId, mosaic: mosaic, size: size, radius: 4),
        onTap: () => Nav.playlist(context, id),
        onLongPress: release(title),
      );
    }
    if (type == 'album') {
      final album = overview?.albums.where((a) => a.id == id).firstOrNull;
      final title = name ?? album?.title ?? 'Album';
      final artist = album?.artist.name ?? (tracks.isEmpty ? '' : tracks.first.artistDisplay);
      final coverId = album?.coverId ?? tracks.where((t) => t.coverId != null).firstOrNull?.coverId;
      return LibraryEntry(
        id: key,
        title: title,
        subtitle: withProgress(artist.isEmpty ? 'Album' : 'Album · $artist'),
        order: order,
        offline: progress == null,
        progress: progress,
        cover: (size) => CoverImage(coverId: coverId, size: size, radius: 4, placeholderIcon: Icons.album_rounded),
        onTap: () => Nav.album(context, id),
        onLongPress: release(title),
      );
    }
    return null;
  }

  Widget _allDownloadedTile(List<Track> tracks, int totalBytes) {
    return LibraryEntryTile(
      entry: LibraryEntry(
        id: 'offline:all',
        title: 'Alle Titel auf diesem Gerät',
        subtitle: '${pluralSongs(tracks.length)} · ${formatBytes(totalBytes)}',
        offline: true,
        cover: (size) => SymbolCover(
          icon: Icons.download_done_rounded,
          size: size,
          colors: const [Color(0xFF1E8C4A), Color(0xFF0D3B20)],
          iconColor: Colors.white,
        ),
        onTap: () => setState(() => _showAllDownloaded = !_showAllDownloaded),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Alle abspielen',
              icon: const Icon(Icons.play_circle_fill_rounded, color: AppColors.accent, size: 32),
              onPressed: () => libraryPlay(context, ref, tracks, playContext: _downloadsContext),
            ),
            Icon(
              _showAllDownloaded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
              color: AppColors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }

  Widget _pendingCard(OfflineState offline, int pendingCount, {required bool waitingForWifi, required bool noNetwork}) {
    final running = offline.progress.values.firstOrNull;
    final text = noNetwork
        ? '${pluralSongs(pendingCount)} warten auf eine Verbindung'
        : waitingForWifi
        ? '${pluralSongs(pendingCount)} warten auf WLAN'
        : '${pluralSongs(pendingCount)} werden aufs Handy geladen';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Material(
        color: AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Nav.offline(context),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      waitingForWifi || noNetwork ? Icons.wifi_off_rounded : Icons.downloading_rounded,
                      size: 20,
                      color: AppColors.accent,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.tileTitle),
                    ),
                    const Text('Verwalten', style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
                    const Icon(Icons.chevron_right_rounded, color: AppColors.textSecondary),
                  ],
                ),
                if (!waitingForWifi && !noNetwork) ...[
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: running != null && running > 0 ? running : null,
                      minHeight: 3,
                      backgroundColor: AppColors.surfaceHighest,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
