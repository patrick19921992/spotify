import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/api.dart';
import '../../data/models.dart';
import '../../player/player.dart';
import '../../state/auth.dart';
import '../../state/connectivity.dart';
import '../../state/offline.dart';
import '../../state/settings.dart';
import '../nav.dart';
import '../widgets/common.dart';
import '../widgets/cover.dart';
import '../widgets/mini_player.dart';
import '../widgets/track_tile.dart';
import 'downloads_widgets.dart';

/// Wiedergabe-Quelle für "Alle Titel" auf dem Handy.
const _offlineContext = PlayContext('queue', title: 'Auf diesem Gerät');

/// Qualitätsstufen, die für Offline-Downloads angeboten werden.
const _offlineQualities = ['original', 'high', 'normal'];

/// Art und ID einer gespeicherten Sammlung ("playlist:5", "album:3", "liked").
typedef _CollectionRef = ({String kind, int? id});

_CollectionRef _parseKey(String key) {
  if (key == likedKey) return (kind: 'liked', id: null);
  final separator = key.indexOf(':');
  if (separator < 0) return (kind: key, id: null);
  return (kind: key.substring(0, separator), id: int.tryParse(key.substring(separator + 1)));
}

String _kindLabel(String kind) => switch (kind) {
      'liked' => 'Lieblingssongs',
      'album' => 'Album',
      'playlist' => 'Playlist',
      _ => 'Sammlung',
    };

/// "Auf diesem Gerät": alles, was auf diesem Gerät gespeichert ist.
class OfflineScreen extends ConsumerStatefulWidget {
  const OfflineScreen({super.key});

  @override
  ConsumerState<OfflineScreen> createState() => _OfflineScreenState();
}

class _OfflineScreenState extends ConsumerState<OfflineScreen> {
  /// Weggeklickte Fehlermeldung (erscheint erst bei einem neuen Fehler wieder).

  /// Sammlungen, die gerade mit dem Server abgeglichen werden.
  final Set<String> _syncing = {};

  // ---------------------------------------------------------------- Abgleich

  /// Aktuelle Titel (und Name) einer Sammlung vom Server.
  Future<(String?, List<Track>)> _fetchCollection(ApiClient api, String key) async {
    switch (_parseKey(key)) {
      case (kind: 'playlist', id: final int id):
        final detail = await api.playlist(id);
        return (detail.playlist.name, detail.tracks);
      case (kind: 'album', id: final int id):
        final detail = await api.album(id);
        return (detail.album.title, detail.tracks);
      case (kind: 'liked', id: _):
        final tracks = <Track>[];
        var offset = 0;
        while (true) {
          final page = await api.likes(limit: 500, offset: offset);
          tracks.addAll(page.items.map((item) => item.track));
          if (!page.hasMore || page.items.isEmpty) break;
          offset += page.items.length;
        }
        return (null, tracks);
      default:
        throw const ApiException('Diese Sammlung kann nicht abgeglichen werden.');
    }
  }

  /// Lädt fehlende/neue Titel einer Sammlung nach und entfernt Titel, die nicht mehr dazugehören.
  Future<void> _syncCollection(String key) async {
    final api = ref.read(apiProvider);
    if (api == null || _syncing.contains(key)) return;
    setState(() => _syncing.add(key));
    try {
      final (name, tracks) = await _fetchCollection(api, key);
      final notifier = ref.read(offlineProvider.notifier);
      await notifier.syncCollection(key, tracks);
      final current = ref.read(offlineProvider);
      if (name != null && current.isCollectionOffline(key) && current.collectionNames[key] != name) {
        await notifier.keepCollection(key, name, tracks);
      }
    } finally {
      if (mounted) setState(() => _syncing.remove(key));
    }
  }

  Future<void> _syncOne(String key, String name) async {
    if (ref.read(isOfflineProvider)) {
      showMessage(context, 'Keine Internetverbindung');
      return;
    }
    try {
      await _syncCollection(key);
      if (!mounted) return;
      final offline = ref.read(offlineProvider);
      final missing = (offline.collections[key] ?? const <int>[]).where((id) => !offline.isDownloaded(id)).length;
      showMessage(context, missing == 0 ? '„$name“ ist vollständig' : '$missing Titel von „$name“ werden geladen');
    } catch (e) {
      if (mounted) showError(context, _describeSyncError(e, name));
    }
  }

  /// Zum Aktualisieren ziehen: alle gespeicherten Sammlungen abgleichen.
  Future<void> _syncAll() async {
    final keys = ref.read(offlineProvider).collections.keys.toList();
    if (keys.isEmpty) return;
    if (ref.read(isOfflineProvider)) {
      showMessage(context, 'Keine Internetverbindung – Abgleich nicht möglich');
      return;
    }
    var failed = 0;
    for (final key in keys) {
      try {
        await _syncCollection(key);
      } catch (_) {
        failed++;
      }
    }
    if (!mounted) return;
    showMessage(
      context,
      failed == 0
          ? 'Gespeicherte Sammlungen sind auf dem neuesten Stand'
          : failed == 1
              ? 'Eine Sammlung konnte nicht abgeglichen werden'
              : '$failed Sammlungen konnten nicht abgeglichen werden',
    );
  }

  Object _describeSyncError(Object error, String name) {
    if (error is ApiException && error.statusCode == 404) {
      return ApiException('„$name“ gibt es auf dem Server nicht mehr. Du kannst die Sammlung vom Handy entfernen.');
    }
    return error;
  }

  // ---------------------------------------------------------------- Aktionen

  Future<void> _release(String key, String name) async {
    final ok = await confirm(
      context,
      title: '„$name“ vom Handy entfernen?',
      message: 'Die Titel werden vom Handy gelöscht, sofern sie nicht zu einer anderen gespeicherten Sammlung '
          'gehören. In deiner Bibliothek bleibt alles erhalten.',
      confirmLabel: 'Entfernen',
      danger: true,
    );
    if (!ok) return;
    try {
      await ref.read(offlineProvider.notifier).releaseCollection(key);
      if (mounted) showMessage(context, '„$name“ wurde vom Handy entfernt');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _removeTrack(OfflineTrack item) async {
    try {
      await ref.read(offlineProvider.notifier).removeTrack(item.track.id);
      if (mounted) showMessage(context, '„${item.track.title}“ vom Handy gelöscht');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _removeAll(OfflineState offline) async {
    final count = offline.tracks.length;
    final ok = await confirm(
      context,
      title: 'Alle Musik von diesem Gerät löschen?',
      message: count == 0
          ? 'Alle gespeicherten Sammlungen und Titel, die noch aufs Gerät geladen werden sollten, werden entfernt.'
          : '${pluralSongs(count)} (${formatBytes(offline.totalBytes)}) werden vom Handy gelöscht. '
              'Gespeicherte Sammlungen werden nicht mehr offline gehalten.',
      confirmLabel: 'Alles löschen',
      danger: true,
    );
    if (!ok) return;
    try {
      await ref.read(offlineProvider.notifier).removeAll();
      if (mounted) showMessage(context, 'Alle Musik wurde von diesem Gerät gelöscht');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _playAll(List<Track> tracks, {bool shuffle = false}) async {
    if (tracks.isEmpty) return;
    try {
      await ref.read(playerProvider).play(tracks, context: _offlineContext, shuffle: shuffle);
    } on StateError catch (e) {
      if (mounted) showMessage(context, e.message);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  void _openCollection(String key) {
    switch (_parseKey(key)) {
      case (kind: 'playlist', id: final int id):
        Nav.playlist(context, id);
      case (kind: 'album', id: final int id):
        Nav.album(context, id);
      case (kind: 'liked', id: _):
        Nav.liked(context);
      default:
        break;
    }
  }

  Future<void> _pickQuality(String current) async {
    final selected = _offlineQualities.contains(current) ? current : 'original';
    final value = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text('Qualität auf diesem Gerät', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                'Gilt für Titel, die neu aufs Gerät geladen werden. Titel, die schon auf diesem Gerät sind, bleiben, wie sie sind. '
                'Höhere Qualität braucht mehr Speicherplatz.',
                style: AppText.caption,
              ),
            ),
            for (final key in _offlineQualities)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                title: Text(
                  qualityLabels[key] ?? key,
                  style: AppText.tileTitle.copyWith(color: key == selected ? AppColors.accent : Colors.white),
                ),
                trailing: key == selected ? const Icon(Icons.check_rounded, color: AppColors.accent) : null,
                onTap: () => Navigator.of(sheetContext).pop(key),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (value == null || value == selected) return;
    await ref.read(settingsProvider.notifier).update((s) => s.copyWith(offlineQuality: value));
  }

  // ---------------------------------------------------------------- Oberfläche

  @override
  Widget build(BuildContext context) {
    final offline = ref.watch(offlineProvider);
    final settings = ref.watch(settingsProvider);
    final noNetwork = ref.watch(isOfflineProvider);
    final onWifi = ref.watch(isOnWifiProvider);

    final items = offline.tracks.values.toList()..sort((a, b) => b.savedAt.compareTo(a.savedAt));
    final tracks = [for (final item in items) item.track];
    final loadingIds = {...offline.pending, ...offline.progress.keys};
    final isEmpty = items.isEmpty && offline.collections.isEmpty && loadingIds.isEmpty;
    final error = offline.lastError;

    final appBar = AppBar(
      title: const Text('Auf diesem Gerät'),
      actions: [
        if (offline.loaded)
          PopupMenuButton<String>(
            tooltip: 'Mehr',
            icon: const Icon(Icons.more_vert_rounded),
            color: AppColors.surfaceHigh,
            onSelected: (value) {
              if (value == 'delete') _removeAll(offline);
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'delete',
                enabled: !isEmpty,
                child: const Row(
                  children: [
                    Icon(Icons.delete_sweep_rounded, size: 20, color: AppColors.danger),
                    SizedBox(width: 12),
                    Text('Alles löschen'),
                  ],
                ),
              ),
            ],
          ),
      ],
    );

    if (!offline.loaded) {
      return Scaffold(appBar: appBar, body: const Center(child: CircularProgressIndicator()));
    }

    String? waitingReason;
    if (loadingIds.isNotEmpty && offline.progress.isEmpty) {
      if (noNetwork) {
        waitingReason = 'Wartet auf eine Internetverbindung';
      } else if (settings.offlineWifiOnly && !onWifi) {
        waitingReason = 'Wartet auf WLAN – oder schalte unten „Nur im WLAN aufs Gerät laden“ aus.';
      } else {
        waitingReason = 'Startet gleich …';
      }
    }

    final collectionKeys = offline.collections.keys.toList()
      ..sort((a, b) {
        int rank(String key) => switch (_parseKey(key).kind) { 'liked' => 0, 'playlist' => 1, 'album' => 2, _ => 3 };
        final byRank = rank(a).compareTo(rank(b));
        if (byRank != 0) return byRank;
        final nameA = offline.collectionNames[a] ?? a;
        final nameB = offline.collectionNames[b] ?? b;
        return nameA.toLowerCase().compareTo(nameB.toLowerCase());
      });

    final handler = ref.read(audioHandlerProvider);
    ref.watch(currentTrackProvider);
    final playingHere = ref.watch(isPlayingProvider) &&
        handler.playContext?.type == _offlineContext.type &&
        handler.playContext?.title == _offlineContext.title;

    return Scaffold(
      appBar: appBar,
      bottomNavigationBar: const SafeArea(top: false, child: MiniPlayer()),
      body: RefreshIndicator(
        color: AppColors.accent,
        onRefresh: _syncAll,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            if (!isEmpty)
              SliverToBoxAdapter(
                child: _SummaryCard(
                  offline: offline,
                  loadingCount: loadingIds.length,
                  waitingReason: waitingReason,
                ),
              ),
            if (error != null)
              SliverToBoxAdapter(
                child: _ErrorBanner(text: error, onDismiss: ref.read(offlineProvider.notifier).clearError),
              ),
            if (isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(top: 24),
                  child: EmptyState(
                    icon: Icons.download_for_offline_outlined,
                    title: 'Noch nichts auf diesem Gerät',
                    message: 'Tippe auf einer Playlist, einem Album oder bei deinen Lieblingssongs auf den '
                        'Pfeil nach unten. Die Musik wird dann aufs Gerät geladen und spielt auch ohne Internet.',
                    action: OutlinedButton.icon(
                      onPressed: () => context.go('/library'),
                      icon: const Icon(Icons.library_music_rounded),
                      label: const Text('Zur Bibliothek'),
                    ),
                  ),
                ),
              ),

            // ------------------------------------------------ Einstellungen
            const SliverToBoxAdapter(child: _Heading('Einstellungen')),
            SliverToBoxAdapter(
              child: Column(
                children: [
                  SwitchListTile(
                    secondary: const Icon(Icons.cloud_off_rounded, color: AppColors.textSecondary),
                    title: const Text('Offline-Modus', style: AppText.tileTitle),
                    subtitle: const Text(
                      'Nur Musik auf diesem Gerät anzeigen und abspielen',
                      style: AppText.tileSubtitle,
                    ),
                    value: settings.offlineMode,
                    onChanged: (value) =>
                        ref.read(settingsProvider.notifier).update((s) => s.copyWith(offlineMode: value)),
                  ),
                  SwitchListTile(
                    secondary: const Icon(Icons.network_wifi_rounded, color: AppColors.textSecondary),
                    title: const Text('Nur im WLAN aufs Gerät laden', style: AppText.tileTitle),
                    subtitle: const Text('Spart dein mobiles Datenvolumen', style: AppText.tileSubtitle),
                    value: settings.offlineWifiOnly,
                    onChanged: (value) =>
                        ref.read(settingsProvider.notifier).update((s) => s.copyWith(offlineWifiOnly: value)),
                  ),
                  ListTile(
                    leading: const Icon(Icons.high_quality_rounded, color: AppColors.textSecondary),
                    title: const Text('Qualität auf diesem Gerät', style: AppText.tileTitle),
                    subtitle: Text(
                      qualityLabels[settings.offlineQuality] ?? settings.offlineQuality,
                      style: AppText.tileSubtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => _pickQuality(settings.offlineQuality),
                  ),
                ],
              ),
            ),

            // ------------------------------------------------ Sammlungen
            if (collectionKeys.isNotEmpty) ...[
              SliverToBoxAdapter(child: _Heading('Gespeicherte Sammlungen', count: collectionKeys.length)),
              SliverList.builder(
                itemCount: collectionKeys.length,
                itemBuilder: (context, index) {
                  final key = collectionKeys[index];
                  final kind = _parseKey(key).kind;
                  final name = offline.collectionNames[key] ?? _kindLabel(kind);
                  return _CollectionTile(
                    key: ValueKey(key),
                    collectionKey: key,
                    name: name,
                    offline: offline,
                    syncing: _syncing.contains(key),
                    canSync: !noNetwork,
                    onOpen: () => _openCollection(key),
                    onSync: () => _syncOne(key, name),
                    onRemove: () => _release(key, name),
                  );
                },
              ),
            ],

            // ------------------------------------------------ Alle Titel
            if (items.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: _Heading(
                  'Alle Titel',
                  count: items.length,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Zufallswiedergabe',
                        icon: const Icon(Icons.shuffle_rounded, color: AppColors.textSecondary),
                        onPressed: () => _playAll(tracks, shuffle: true),
                      ),
                      const SizedBox(width: 4),
                      PlayButton(
                        size: 44,
                        playing: playingHere,
                        onPressed: playingHere ? () => ref.read(playerProvider).togglePlay() : () => _playAll(tracks),
                      ),
                    ],
                  ),
                ),
              ),
              SliverList.builder(
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final item = items[index];
                  return TrackTile(
                    key: ValueKey(item.track.id),
                    track: item.track,
                    queue: tracks,
                    context_: _offlineContext,
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(formatBytes(item.size), style: AppText.caption),
                        IconButton(
                          tooltip: 'Vom Handy löschen',
                          icon: const Icon(Icons.delete_outline_rounded, color: AppColors.textSecondary),
                          onPressed: () => _removeTrack(item),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ],
            const SliverPadding(padding: EdgeInsets.only(bottom: 32)),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- Bausteine

class _Heading extends StatelessWidget {
  final String title;
  final int? count;
  final Widget? trailing;

  const _Heading(this.title, {this.count, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 24, trailing == null ? 16 : 12, 8),
      child: Row(
        children: [
          Flexible(
            child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.sectionTitle),
          ),
          if (count != null) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: AppColors.surfaceHighest, borderRadius: BorderRadius.circular(10)),
              child: Text('$count', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            ),
          ],
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}

/// Speicherplatz, Anzahl und laufende Downloads aufs Handy.
class _SummaryCard extends StatelessWidget {
  final OfflineState offline;
  final int loadingCount;
  final String? waitingReason;

  const _SummaryCard({required this.offline, required this.loadingCount, required this.waitingReason});

  @override
  Widget build(BuildContext context) {
    final trackCount = offline.tracks.length;
    final collectionCount = offline.collections.length;
    final current = offline.progress.entries.firstOrNull;
    final details = [
      pluralSongs(trackCount),
      if (collectionCount > 0) collectionCount == 1 ? '1 Sammlung' : '$collectionCount Sammlungen',
    ].join(' · ');

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [darken(AppColors.accentDark, 0.22), AppColors.surfaceHigh],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: const BoxDecoration(color: Color(0x33000000), shape: BoxShape.circle),
                child: const Icon(Icons.download_for_offline_rounded, color: AppColors.accent, size: 32),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      formatBytes(offline.totalBytes),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: Colors.white),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$details auf diesem Handy',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, color: Color(0xFFDDDDDD)),
                    ),
                  ],
                ),
              ),
            ],
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: loadingCount == 0
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              current != null ? Icons.downloading_rounded : Icons.hourglass_top_rounded,
                              size: 18,
                              color: Colors.white,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Lädt: ${loadingCount == 1 ? '1 Titel' : '$loadingCount Titel'}',
                                style: const TextStyle(fontWeight: FontWeight.w700),
                              ),
                            ),
                            if (current != null)
                              Text(formatPercent(current.value), style: AppText.caption.copyWith(color: Colors.white)),
                          ],
                        ),
                        const SizedBox(height: 8),
                        AnimatedJobBar(
                          value: current != null && current.value > 0 ? current.value : null,
                          color: waitingReason == null ? AppColors.accent : AppColors.textMuted,
                        ),
                        if (waitingReason != null) ...[
                          const SizedBox(height: 6),
                          Text(waitingReason!, style: AppText.caption),
                        ],
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String text;
  final VoidCallback onDismiss;

  const _ErrorBanner({required this.text, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded, color: AppColors.danger, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(text, style: const TextStyle(color: AppColors.danger, fontSize: 13)),
            ),
          ),
          IconButton(
            tooltip: 'Ausblenden',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close_rounded, color: AppColors.danger, size: 18),
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}

/// Eine gespeicherte Sammlung (Playlist, Album, Lieblingssongs) mit Fortschritt.
class _CollectionTile extends StatelessWidget {
  final String collectionKey;
  final String name;
  final OfflineState offline;
  final bool syncing;
  final bool canSync;
  final VoidCallback onOpen;
  final VoidCallback onSync;
  final VoidCallback onRemove;

  const _CollectionTile({
    super.key,
    required this.collectionKey,
    required this.name,
    required this.offline,
    required this.syncing,
    required this.canSync,
    required this.onOpen,
    required this.onSync,
    required this.onRemove,
  });

  Widget _cover(String kind, List<int> ids) {
    const size = 52.0;
    if (kind == 'liked') return const LikedSongsCover(size: size);
    final covers = <String>[];
    for (final id in ids) {
      final coverId = offline.tracks[id]?.track.coverId;
      if (coverId != null && !covers.contains(coverId)) covers.add(coverId);
      if (covers.length == 4) break;
    }
    if (kind == 'album') {
      return CoverImage(coverId: covers.firstOrNull, size: size, placeholderIcon: Icons.album_rounded);
    }
    return PlaylistCover(coverId: null, mosaic: covers, size: size);
  }

  @override
  Widget build(BuildContext context) {
    final kind = _parseKey(collectionKey).kind;
    final ids = offline.collections[collectionKey] ?? const <int>[];
    final done = ids.where(offline.isDownloaded).length;
    final total = ids.length;
    final fraction = offline.collectionProgress(collectionKey);
    final loading = ids.any(offline.isPending);
    final complete = total > 0 && done == total;
    final bytes = ids.fold<int>(0, (sum, id) => sum + (offline.tracks[id]?.size ?? 0));

    final String status;
    if (total == 0) {
      status = 'Keine Titel';
    } else {
      status = '$done von $total ${total == 1 ? 'Titel' : 'Titeln'} (${formatPercent(fraction)})';
    }
    final subtitle = [
      _kindLabel(kind),
      status,
      if (bytes > 0) formatBytes(bytes),
    ].join(' · ');

    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
        child: Row(
          children: [
            _cover(kind, ids),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.tileTitle),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      if (complete)
                        const Padding(
                          padding: EdgeInsets.only(right: 4),
                          child: Icon(Icons.arrow_circle_down_rounded, size: 14, color: AppColors.accent),
                        ),
                      Expanded(
                        child: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.tileSubtitle),
                      ),
                    ],
                  ),
                  if (!complete && total > 0) ...[
                    const SizedBox(height: 6),
                    AnimatedJobBar(
                      value: fraction,
                      height: 3,
                      color: loading ? AppColors.accent : AppColors.textMuted,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 4),
            if (syncing || loading)
              const SizedBox(
                width: 48,
                height: 48,
                child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
              )
            else if (!complete && canSync)
              IconButton(
                tooltip: 'Fehlende Titel laden',
                icon: const Icon(Icons.download_rounded, color: AppColors.textSecondary),
                onPressed: onSync,
              ),
            IconButton(
              tooltip: 'Vom Handy entfernen',
              icon: const Icon(Icons.remove_circle_outline_rounded, color: AppColors.textSecondary),
              onPressed: onRemove,
            ),
          ],
        ),
      ),
    );
  }
}
