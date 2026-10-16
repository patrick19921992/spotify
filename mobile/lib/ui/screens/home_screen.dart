import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../player/player.dart';
import '../../state/auth.dart';
import '../../state/connectivity.dart';
import '../../state/library.dart';
import '../../state/offline.dart';
import '../../state/settings.dart';
import '../nav.dart';
import '../shell.dart';
import '../widgets/cards.dart';
import '../widgets/common.dart';
import '../widgets/cover.dart';
import '../widgets/track_tile.dart';
import 'home_widgets.dart';

/// Startseite ("Start") wie bei Spotify: Begrüßung, Schnellzugriff und Abschnitte vom Server.
/// Ohne Netz bzw. im Offline-Modus: alles, was aufs Handy geladen wurde.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offlineMode = ref.watch(settingsProvider.select((s) => s.offlineMode));
    final noNetwork = ref.watch(isOfflineProvider);
    return Scaffold(
      body: offlineMode || noNetwork ? _OfflineHome(noNetwork: noNetwork) : const _OnlineHome(),
    );
  }
}

// ------------------------------------------------------------------ Kopfbereich

/// Begrüßung mit Aktionen, dahinter ein dezenter Farbverlauf.
class _HomeTop extends StatelessWidget {
  final Color? tint;
  final bool showHistory;
  final Widget? child;

  const _HomeTop({required this.tint, required this.showHistory, this.child});

  @override
  Widget build(BuildContext context) {
    final base = tint ?? const Color(0xFF2E4A3A);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [darken(base, 0.12).withValues(alpha: 0.6), AppColors.background],
        ),
      ),
      child: Padding(
        padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top + 8, bottom: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 4, 14),
              child: Row(
                children: [
                  Expanded(
                    child: Text(greeting(), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.pageTitle),
                  ),
                  const DownloadsAction(),
                  if (showHistory)
                    IconButton(
                      tooltip: 'Zuletzt gehört',
                      icon: const Icon(Icons.history_rounded),
                      onPressed: () => _showHistory(context),
                    ),
                  IconButton(
                    tooltip: 'Einstellungen',
                    icon: const Icon(Icons.settings_outlined),
                    onPressed: () => Nav.settings(context),
                  ),
                ],
              ),
            ),
            ?child,
          ],
        ),
      ),
    );
  }
}

/// Schnellzugriff: 2 Spalten mit kompakten Kacheln (max. 8).
class _QuickAccess extends StatelessWidget {
  final List<ContextItem> items;
  const _QuickAccess({required this.items});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    // Zwei Zeilen Titel müssen hineinpassen – bei großer Schrift wird die Kachel höher statt abzuschneiden
    final height = math.max(56.0, MediaQuery.textScalerOf(context).scale(13) * 1.3 * 2 + 12);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          for (var i = 0; i < items.length; i += 2)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: SizedBox(
                height: height,
                child: Row(
                  children: [
                    Expanded(child: QuickTile(item: items[i])),
                    const SizedBox(width: 8),
                    Expanded(child: i + 1 < items.length ? QuickTile(item: items[i + 1]) : const SizedBox.shrink()),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ Online

class _OnlineHome extends ConsumerWidget {
  const _OnlineHome();

  Future<void> _refresh(BuildContext context, WidgetRef ref) async {
    ref.invalidate(homeProvider);
    try {
      await ref.read(homeProvider.future);
    } catch (e) {
      if (context.mounted && ref.read(homeProvider).hasValue) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final home = ref.watch(homeProvider);
    final data = home.value;
    final quickAccess = data?.quickAccess.take(8).toList() ?? const <ContextItem>[];

    final slivers = <Widget>[
      SliverToBoxAdapter(
        child: _HomeTop(
          tint: parseHexColor(quickAccess.firstOrNull?.coverColor),
          showHistory: true,
          child: quickAccess.isEmpty ? null : _QuickAccess(items: quickAccess),
        ),
      ),
    ];

    if (data != null) {
      if (data.sections.isEmpty && data.quickAccess.isEmpty) {
        slivers.add(const SliverFillRemaining(hasScrollBody: false, child: _Welcome()));
      } else {
        for (final section in data.sections) {
          slivers.add(SliverToBoxAdapter(child: _HomeSectionView(section: section)));
        }
      }
    } else if (home.hasError) {
      slivers.add(SliverFillRemaining(
        hasScrollBody: false,
        child: ErrorView(message: errorText(home.error!), onRetry: () => ref.invalidate(homeProvider)),
      ));
    } else {
      slivers.add(const SliverFillRemaining(
        hasScrollBody: false,
        child: Center(child: CircularProgressIndicator()),
      ));
    }
    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 32)));

    return RefreshIndicator(
      color: AppColors.accent,
      edgeOffset: MediaQuery.paddingOf(context).top,
      onRefresh: () => _refresh(context, ref),
      child: CustomScrollView(physics: const AlwaysScrollableScrollPhysics(), slivers: slivers),
    );
  }
}

/// Leere Bibliothek – freundlicher Einstieg.
class _Welcome extends StatelessWidget {
  const _Welcome();

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.library_music_rounded,
      title: 'Willkommen bei Selfify',
      message: 'Deine Bibliothek ist noch leer. Such nach Musik und hol sie dir direkt von YouTube – '
          'oder leg Dateien in die Musikordner auf dem Server.',
      action: FilledButton.icon(
        onPressed: () => context.go('/search'),
        icon: const Icon(Icons.search_rounded),
        label: const Text('Musik suchen'),
      ),
    );
  }
}

/// Ein Abschnitt der Startseite (Überschrift + horizontale Reihe).
class _HomeSectionView extends ConsumerWidget {
  final HomeSection section;
  const _HomeSectionView({required this.section});

  Future<void> _playTrack(BuildContext context, WidgetRef ref, int index) async {
    final track = section.tracks[index];
    if (track.isVideo) {
      openVideo(context, ref, track);
      return;
    }
    // Läuft der Titel schon: nur pausieren/fortsetzen
    if (ref.read(isCurrentTrackProvider(track.id))) {
      await ref.read(playerProvider).togglePlay();
      return;
    }
    await playWithFeedback(
      context,
      ref,
      section.tracks,
      index: index,
      playContext: PlayContext('mix', title: section.title),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Widget? content = switch (section.kind) {
      'contexts' when section.contexts.isNotEmpty => CardRow(
          children: [for (final item in section.contexts) MediaCard.context(context, item)],
        ),
      'albums' when section.albums.isNotEmpty => CardRow(
          children: [for (final album in section.albums) MediaCard.album(context, album)],
        ),
      'artists' when section.artists.isNotEmpty => CardRow(
          children: [for (final artist in section.artists) MediaCard.artist(context, artist)],
        ),
      'tracks' when section.tracks.isNotEmpty => CardRow(
          children: [
            for (final (index, track) in section.tracks.indexed)
              HomeTrackCard(track: track, onTap: () => _playTrack(context, ref, index)),
          ],
        ),
      'videos' when section.tracks.isNotEmpty => CardRow(
          height: 180,
          children: [for (final track in section.tracks) VideoCard(track: track, width: 220)],
        ),
      _ => null,
    };
    if (content == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [SectionHeader(section.title), content],
    );
  }
}

// ------------------------------------------------------------------ Verlauf

/// "Zuletzt gehört" als Blatt von unten (im aktuellen Tab, damit Detailseiten darüber öffnen).
Future<void> _showHistory(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (sheetContext, controller) => _HistorySheet(controller: controller),
    ),
  );
}

const _historyContext = PlayContext('queue', title: 'Zuletzt gehört');

class _HistorySheet extends ConsumerWidget {
  final ScrollController controller;
  const _HistorySheet({required this.controller});

  static String _dayLabel(DateTime playedAt) {
    final local = playedAt.toLocal();
    final now = DateTime.now();
    final day = DateTime(local.year, local.month, local.day);
    final today = DateTime(now.year, now.month, now.day);
    if (day == today) return 'Heute';
    if (day == DateTime(now.year, now.month, now.day - 1)) return 'Gestern';
    if (day.isAfter(DateTime(now.year, now.month, now.day - 7))) {
      return DateFormat('EEEE', 'de_DE').format(local);
    }
    return formatDate(local);
  }

  /// Tagesüberschriften (String) und Einträge (HistoryEntry); direkt wiederholte Titel nur einmal.
  static List<Object> _rows(List<HistoryEntry> entries) {
    final rows = <Object>[];
    String? currentDay;
    int? lastTrackId;
    for (final entry in entries) {
      final label = _dayLabel(entry.playedAt);
      if (label != currentDay) {
        rows.add(label);
        currentDay = label;
        lastTrackId = null;
      }
      if (entry.track.id == lastTrackId) continue;
      rows.add(entry);
      lastTrackId = entry.track.id;
    }
    return rows;
  }

  Future<void> _clear(BuildContext context, WidgetRef ref) async {
    final container = ProviderScope.containerOf(context, listen: false);
    final ok = await confirm(
      context,
      title: 'Verlauf löschen?',
      message: 'Deine zuletzt gehörten Titel werden gelöscht. Lieblingssongs und Playlists bleiben erhalten.',
      confirmLabel: 'Löschen',
      danger: true,
    );
    if (!ok) return;
    final api = container.read(apiProvider);
    if (api == null) return;
    try {
      await api.clearHistory();
      container.invalidate(historyProvider);
      container.invalidate(recentProvider);
      container.invalidate(homeProvider);
      if (context.mounted) showMessage(context, 'Verlauf gelöscht');
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(historyProvider);
    final hasEntries = history.value?.isNotEmpty ?? false;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
          child: Row(
            children: [
              const Expanded(child: Text('Zuletzt gehört', style: AppText.sectionTitle)),
              if (hasEntries)
                TextButton(
                  onPressed: () => _clear(context, ref),
                  child: const Text(
                    'Verlauf löschen',
                    style: TextStyle(color: AppColors.textSecondary, fontWeight: FontWeight.w600),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: AsyncBody(
            value: history,
            onRetry: () => ref.invalidate(historyProvider),
            builder: (entries) {
              if (entries.isEmpty) {
                return ListView(
                  controller: controller,
                  children: const [
                    SizedBox(height: 40),
                    EmptyState(
                      icon: Icons.history_rounded,
                      title: 'Noch nichts gehört',
                      message: 'Hier erscheinen die Titel, die du zuletzt gehört hast.',
                    ),
                  ],
                );
              }
              final rows = _rows(entries);
              // Warteschlange ohne doppelte Titel – Tippen spielt ab dem gewählten Titel
              final queue = <Track>[];
              final seen = <int>{};
              for (final entry in entries) {
                if (seen.add(entry.track.id)) queue.add(entry.track);
              }
              // Kein Ziehen-zum-Aktualisieren: das Blatt selbst wird gezogen (wird bei jedem Öffnen neu geladen)
              return ListView.builder(
                controller: controller,
                padding: const EdgeInsets.only(bottom: 24),
                itemCount: rows.length,
                itemBuilder: (context, index) {
                  final row = rows[index];
                  if (row is String) {
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
                      child: Text(
                        row,
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white),
                      ),
                    );
                  }
                  final entry = row as HistoryEntry;
                  return TrackTile(track: entry.track, queue: queue, context_: _historyContext);
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------ Offline

const _downloadedContext = PlayContext('queue', title: 'Auf diesem Gerät');

/// Anzeigename und Titel einer offline gehaltenen Sammlung.
class _Collection {
  final String key;
  final String name;
  final List<Track> tracks;
  final int total;

  const _Collection({required this.key, required this.name, required this.tracks, required this.total});

  bool get isLiked => key == likedKey;
  bool get isPlaylist => key.startsWith('playlist:');
  bool get isAlbum => key.startsWith('album:');
  int? get id => int.tryParse(key.split(':').last);

  String get typeLabel => isLiked ? 'Lieblingssongs' : (isPlaylist ? 'Playlist' : (isAlbum ? 'Album' : 'Sammlung'));

  PlayContext get playContext {
    if (isLiked) return PlayContext('liked', title: name);
    if (isPlaylist) return PlayContext('playlist', id: id, title: name);
    if (isAlbum) return PlayContext('album', id: id, title: name);
    return PlayContext('queue', title: name);
  }

  List<String> get covers {
    final covers = <String>[];
    for (final track in tracks) {
      final cover = track.coverId;
      if (cover != null && !covers.contains(cover)) covers.add(cover);
      if (covers.length == 4) break;
    }
    return covers;
  }

  Widget cover(double size, {double radius = 0}) {
    if (isLiked) return LikedSongsCover(size: size, radius: radius);
    if (isPlaylist) return PlaylistCover(coverId: null, mosaic: covers, size: size, radius: radius);
    return CoverImage(coverId: covers.firstOrNull, size: size, radius: radius, placeholderIcon: Icons.album_rounded);
  }

  static List<_Collection> fromState(OfflineState state) {
    final list = <_Collection>[
      for (final entry in state.collections.entries)
        _Collection(
          key: entry.key,
          name: state.collectionNames[entry.key] ?? (entry.key == likedKey ? 'Lieblingssongs' : entry.key),
          tracks: [
            for (final id in entry.value)
              if (state.tracks[id] != null) state.tracks[id]!.track,
          ],
          total: entry.value.length,
        ),
    ];
    list.sort((a, b) {
      if (a.isLiked != b.isLiked) return a.isLiked ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return list;
  }
}

class _OfflineHome extends ConsumerWidget {
  final bool noNetwork;
  const _OfflineHome({required this.noNetwork});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offline = ref.watch(offlineProvider);
    final downloaded = offline.tracks.values.toList()..sort((a, b) => b.savedAt.compareTo(a.savedAt));
    final tracks = [for (final item in downloaded) item.track];
    final collections = _Collection.fromState(offline);

    final slivers = <Widget>[
      SliverToBoxAdapter(child: _HomeTop(tint: AppColors.accentDark, showHistory: !noNetwork)),
    ];

    if (!offline.loaded) {
      slivers.add(const SliverFillRemaining(hasScrollBody: false, child: Center(child: CircularProgressIndicator())));
    } else if (tracks.isEmpty && collections.isEmpty) {
      slivers.add(SliverFillRemaining(
        hasScrollBody: false,
        child: EmptyState(
          icon: Icons.download_for_offline_outlined,
          title: 'Noch nichts auf diesem Gerät',
          message: noNetwork
              ? 'Ohne Internet kannst du nur Musik hören, die auf deinem Handy gespeichert ist. '
                  'Lade Playlists, Alben oder Lieblingssongs aufs Gerät, sobald du wieder online bist.'
              : 'Lade Playlists, Alben oder Lieblingssongs aufs Handy, um sie ohne Internet zu hören.',
          action: noNetwork
              ? null
              : OutlinedButton(
                  onPressed: () => ref.read(settingsProvider.notifier).update((s) => s.copyWith(offlineMode: false)),
                  child: const Text('Offline-Modus ausschalten'),
                ),
        ),
      ));
    } else {
      slivers.add(SliverToBoxAdapter(child: _DownloadedHeader(tracks: tracks, totalBytes: offline.totalBytes)));
      if (collections.isNotEmpty) {
        slivers.add(SliverToBoxAdapter(child: _CollectionGrid(collections: collections, noNetwork: noNetwork)));
      }
      if (tracks.isNotEmpty) {
        slivers.add(const SliverToBoxAdapter(child: SectionHeader('Alle Songs')));
        slivers.add(SliverList.builder(
          itemCount: tracks.length,
          itemBuilder: (context, index) =>
              TrackTile(track: tracks[index], queue: tracks, context_: _downloadedContext),
        ));
      }
    }
    slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 32)));
    return CustomScrollView(slivers: slivers);
  }
}

/// "Auf diesem Gerät" mit Größe, Verwalten, Zufall und Abspielen.
class _DownloadedHeader extends ConsumerWidget {
  final List<Track> tracks;
  final int totalBytes;

  const _DownloadedHeader({required this.tracks, required this.totalBytes});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = watchIsPlayingContext(
      ref,
      (c) => c.type == _downloadedContext.type && c.title == _downloadedContext.title,
      tracks,
    );
    final playing = active && ref.watch(isPlayingProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Auf diesem Gerät', style: AppText.sectionTitle),
                const SizedBox(height: 4),
                Text(
                  '${pluralSongs(tracks.length)} · ${formatBytes(totalBytes)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.caption,
                ),
                TextButton(
                  onPressed: () => Nav.offline(context),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    foregroundColor: AppColors.accent,
                    textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  child: const Text('Speicher verwalten'),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Zufällig abspielen',
            iconSize: 28,
            color: AppColors.textSecondary,
            icon: const Icon(Icons.shuffle_rounded),
            onPressed: tracks.isEmpty
                ? null
                : () => playWithFeedback(context, ref, tracks, playContext: _downloadedContext, shuffle: true),
          ),
          const SizedBox(width: 4),
          PlayButton(
            size: 52,
            playing: playing,
            onPressed: tracks.isEmpty
                ? null
                : () => active
                    ? ref.read(playerProvider).togglePlay()
                    : playWithFeedback(context, ref, tracks, playContext: _downloadedContext),
          ),
        ],
      ),
    );
  }
}

/// Offline gehaltene Sammlungen als Kacheln (2 Spalten).
class _CollectionGrid extends StatelessWidget {
  final List<_Collection> collections;
  final bool noNetwork;

  const _CollectionGrid({required this.collections, required this.noNetwork});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          for (var i = 0; i < collections.length; i += 2)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: SizedBox(
                height: 56,
                child: Row(
                  children: [
                    Expanded(child: _CollectionTile(collection: collections[i], noNetwork: noNetwork)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: i + 1 < collections.length
                          ? _CollectionTile(collection: collections[i + 1], noNetwork: noNetwork)
                          : const SizedBox.shrink(),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _CollectionTile extends StatelessWidget {
  final _Collection collection;
  final bool noNetwork;

  const _CollectionTile({required this.collection, required this.noNetwork});

  void _open(BuildContext context) {
    // Mit Netz (nur Offline-Modus an): normale Detailseite. Ohne Netz: Titel direkt vom Handy.
    if (!noNetwork) {
      final id = collection.id;
      if (collection.isLiked) {
        Nav.liked(context);
        return;
      }
      if (collection.isPlaylist && id != null) {
        Nav.playlist(context, id);
        return;
      }
      if (collection.isAlbum && id != null) {
        Nav.album(context, id);
        return;
      }
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.8,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (sheetContext, controller) =>
            _OfflineCollectionSheet(collectionKey: collection.key, controller: controller),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final complete = collection.tracks.length >= collection.total;
    return Material(
      color: AppColors.surfaceHigh,
      borderRadius: BorderRadius.circular(4),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _open(context),
        child: Row(
          children: [
            collection.cover(56),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    collection.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.white),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Icon(
                        complete ? Icons.arrow_circle_down_rounded : Icons.downloading_rounded,
                        size: 12,
                        color: AppColors.accent,
                      ),
                      const SizedBox(width: 3),
                      Expanded(
                        child: Text(
                          complete
                              ? collection.typeLabel
                              : '${collection.tracks.length} von ${collection.total}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11.5, color: AppColors.textSecondary),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
          ],
        ),
      ),
    );
  }
}

/// Inhalt einer offline gehaltenen Sammlung – funktioniert ganz ohne Server.
class _OfflineCollectionSheet extends ConsumerWidget {
  final String collectionKey;
  final ScrollController controller;

  const _OfflineCollectionSheet({required this.collectionKey, required this.controller});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(offlineProvider);
    final collection = _Collection.fromState(state).where((c) => c.key == collectionKey).firstOrNull;
    if (collection == null) {
      return ListView(
        controller: controller,
        children: const [
          SizedBox(height: 40),
          EmptyState(icon: Icons.download_for_offline_outlined, title: 'Nicht mehr auf dem Handy'),
        ],
      );
    }
    final tracks = collection.tracks;
    final playContext = collection.playContext;
    final active = watchIsPlayingContext(
      ref,
      (c) => c.type == playContext.type && c.id == playContext.id && c.title == playContext.title,
      tracks,
    );
    final playing = active && ref.watch(isPlayingProvider);
    final duration = tracks.fold<double>(0, (sum, t) => sum + t.duration);

    return ListView.builder(
      controller: controller,
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: tracks.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              children: [
                collection.cover(72, radius: 4),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        collection.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Colors.white),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${collection.typeLabel} · ${pluralSongs(tracks.length)}'
                        '${tracks.isEmpty ? '' : ' · ${formatLongDuration(duration)}'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.caption,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                PlayButton(
                  size: 48,
                  playing: playing,
                  onPressed: tracks.isEmpty
                      ? null
                      : () => active
                          ? ref.read(playerProvider).togglePlay()
                          : playWithFeedback(context, ref, tracks, playContext: playContext),
                ),
              ],
            ),
          );
        }
        final track = tracks[index - 1];
        return TrackTile(track: track, queue: tracks, context_: playContext);
      },
    );
  }
}
