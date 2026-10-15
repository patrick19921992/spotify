import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../player/player.dart';
import '../../state/settings.dart';
import '../widgets/common.dart';
import '../widgets/cover.dart';
import 'player_widgets.dart';

/// Ein kommender Titel: Position in der Original-Reihenfolge + stabiler Schlüssel.
class _Entry {
  final int index;
  final Track track;
  final Key key;
  const _Entry(this.index, this.track, this.key);
}

/// Warteschlange: was gerade läuft und was als Nächstes kommt (sortieren, entfernen, leeren).
class QueueScreen extends ConsumerStatefulWidget {
  const QueueScreen({super.key});

  @override
  ConsumerState<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends ConsumerState<QueueScreen> {
  /// Zuletzt gültiger Titel – überbrückt den Moment, in dem der Player nach dem Entfernen umsortiert.
  Track? _lastCurrent;

  /// Zählt das Entfernen mit: Neue Schlüssel danach verhindern, dass eine weggewischte Zeile ihren Zustand
  /// an eine gleiche Kopie desselben Songs vererbt (die wäre sonst unsichtbar, spielt aber trotzdem).
  int _removals = 0;

  SelfifyAudioHandler get _handler => ref.read(audioHandlerProvider);

  /// Kommende Titel in Abspiel-Reihenfolge (berücksichtigt die Zufallswiedergabe).
  List<_Entry> _upcoming(SelfifyAudioHandler handler) {
    final tracks = handler.tracks;
    final current = handler.player.currentIndex;
    if (current == null || current >= tracks.length) return const [];
    final order = handler.playOrder.where((i) => i >= 0 && i < tracks.length).toList();
    final position = order.indexOf(current);
    if (position < 0) return const [];
    // Schlüssel nach Objekt-Identität (+ Zähler, falls derselbe Titel mehrfach eingereiht ist)
    final seen = <int, int>{};
    final entries = <_Entry>[];
    for (final index in order.skip(position + 1)) {
      final identity = identityHashCode(tracks[index]);
      final occurrence = seen[identity] = (seen[identity] ?? -1) + 1;
      entries.add(_Entry(index, tracks[index], ValueKey('queue-$_removals-$identity-$occurrence')));
    }
    return entries;
  }

  /// Änderung am Handler ausführen: sofort neu zeichnen (die Liste ist schon geändert),
  /// nach Abschluss noch einmal (Zufallsreihenfolge des Players ist dann aktuell).
  Future<void> _apply(Future<void> operation) async {
    setState(() {});
    try {
      await operation;
    } catch (e) {
      if (mounted) showError(context, e);
    }
    if (mounted) setState(() {});
  }

  void _remove(_Entry entry) {
    _removals++;
    _apply(_handler.removeQueueItemAt(entry.index));
  }

  void _move(List<_Entry> upcoming, int from, int to) {
    if (from == to || from < 0 || to < 0 || from >= upcoming.length || to >= upcoming.length) return;
    _apply(_handler.moveQueueItem(upcoming[from].index, upcoming[to].index));
  }

  Future<void> _clear() async {
    try {
      // Berücksichtigt auch die Zufallswiedergabe (kommende Titel vor dem aktuellen)
      await _handler.clearUpcoming();
      if (mounted) showMessage(context, 'Warteschlange geleert');
    } catch (e) {
      if (mounted) showError(context, e);
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final handler = ref.watch(audioHandlerProvider);
    ref.watch(queueProvider);
    ref.watch(mediaItemProvider);
    ref.watch(playbackStateProvider);
    final autoplay = ref.watch(settingsProvider.select((s) => s.autoplay));

    final tracks = handler.tracks;
    final live = handler.currentTrack;
    if (live != null) _lastCurrent = live;
    final current = live ?? (tracks.isNotEmpty ? _lastCurrent : null);
    final shuffle = handler.player.shuffleModeEnabled;
    final upcoming = _upcoming(handler);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Schließen',
          icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 32),
          onPressed: () => closeFullScreen(context),
        ),
        centerTitle: true,
        title: const Text('Warteschlange', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
      ),
      body: current == null
          ? const EmptyState(
              icon: Icons.queue_music_rounded,
              title: 'Die Warteschlange ist leer',
              message: 'Spiel einen Song, ein Album oder eine Playlist ab – hier siehst du dann, was als Nächstes kommt.',
            )
          : Column(
              children: [
                Expanded(
                  child: CustomScrollView(
                    slivers: [
                      const SliverToBoxAdapter(child: _SectionTitle('Wird gerade gespielt')),
                      SliverToBoxAdapter(child: _NowPlayingRow(track: current)),
                      SliverToBoxAdapter(
                        child: _UpcomingHeader(
                          source: playContextLabel(handler.playContext),
                          upcoming: upcoming,
                          shuffle: shuffle,
                          onClear: upcoming.isEmpty ? null : _clear,
                        ),
                      ),
                      if (upcoming.isEmpty)
                        SliverToBoxAdapter(child: _EmptyUpcoming(autoplay: autoplay))
                      else if (shuffle)
                        SliverList.builder(
                          itemCount: upcoming.length,
                          itemBuilder: (context, i) => _row(upcoming[i], i, reorderable: false),
                        )
                      else
                        SliverReorderableList(
                          itemCount: upcoming.length,
                          onReorderItem: (from, to) => _move(upcoming, from, to),
                          proxyDecorator: (child, index, animation) => Material(
                            color: AppColors.surfaceHigh,
                            elevation: 8,
                            shadowColor: Colors.black,
                            borderRadius: BorderRadius.circular(6),
                            child: child,
                          ),
                          itemBuilder: (context, i) => _row(upcoming[i], i, reorderable: true),
                        ),
                      const SliverToBoxAdapter(child: SizedBox(height: 24)),
                    ],
                  ),
                ),
                const _BottomControls(),
              ],
            ),
    );
  }

  Widget _row(_Entry entry, int position, {required bool reorderable}) {
    final track = entry.track;
    return Dismissible(
      key: entry.key,
      direction: DismissDirection.endToStart,
      background: Container(
        color: AppColors.danger,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Entfernen', style: TextStyle(fontWeight: FontWeight.w700)),
            SizedBox(width: 8),
            Icon(Icons.delete_outline_rounded, color: Colors.white),
          ],
        ),
      ),
      onDismissed: (_) => _remove(entry),
      child: Material(
        type: MaterialType.transparency,
        child: ListTile(
          contentPadding: EdgeInsets.only(left: 16, right: reorderable ? 0 : 8),
          minLeadingWidth: 0,
          onTap: () => _apply(_handler.skipToQueueItem(entry.index)),
          leading: CoverImage(coverId: track.coverId, size: 48),
          title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.tileTitle),
          subtitle: Text(track.artistDisplay, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.tileSubtitle),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Aus der Warteschlange entfernen',
                icon: const Icon(Icons.remove_circle_outline_rounded, color: AppColors.textSecondary),
                onPressed: () => _remove(entry),
              ),
              if (reorderable)
                ReorderableDragStartListener(
                  index: position,
                  child: const Padding(
                    padding: EdgeInsets.fromLTRB(4, 12, 16, 12),
                    child: Icon(Icons.drag_handle_rounded, color: AppColors.textSecondary),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(text, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
    );
  }
}

class _NowPlayingRow extends ConsumerWidget {
  final Track track;
  const _NowPlayingRow({required this.track});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playing = ref.watch(isPlayingProvider);
    return ListTile(
      minLeadingWidth: 0,
      contentPadding: const EdgeInsets.only(left: 16, right: 4),
      leading: Stack(
        alignment: Alignment.center,
        children: [
          CoverImage(coverId: track.coverId, size: 48),
          if (playing)
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(4)),
              child: const Icon(Icons.graphic_eq_rounded, color: AppColors.accent, size: 24),
            ),
        ],
      ),
      title: Text(
        track.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppText.tileTitle.copyWith(color: AppColors.accent, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(track.artistDisplay, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.tileSubtitle),
      trailing: PlayerLikeButton(track: track, size: 24),
    );
  }
}

class _UpcomingHeader extends StatelessWidget {
  final String source;
  final List<_Entry> upcoming;
  final bool shuffle;
  final VoidCallback? onClear;

  const _UpcomingHeader({required this.source, required this.upcoming, required this.shuffle, required this.onClear});

  @override
  Widget build(BuildContext context) {
    final seconds = upcoming.fold<double>(0, (sum, e) => sum + e.track.duration);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 8, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              'Als Nächstes aus: $source',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: Text(
                  upcoming.isEmpty ? 'Keine weiteren Songs' : '${pluralSongs(upcoming.length)} · ${formatLongDuration(seconds)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.tileSubtitle,
                ),
              ),
              if (onClear != null)
                TextButton.icon(
                  onPressed: onClear,
                  style: TextButton.styleFrom(foregroundColor: Colors.white),
                  icon: const Icon(Icons.clear_all_rounded, size: 20),
                  label: const Text('Warteschlange leeren', style: TextStyle(fontWeight: FontWeight.w700)),
                ),
            ],
          ),
          if (shuffle && upcoming.length > 1)
            const Padding(
              padding: EdgeInsets.only(top: 2, bottom: 4),
              child: Row(
                children: [
                  Icon(Icons.shuffle_rounded, size: 16, color: AppColors.accent),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Zum Sortieren Zufallswiedergabe ausschalten',
                      style: AppText.caption,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _EmptyUpcoming extends StatelessWidget {
  final bool autoplay;
  const _EmptyUpcoming({required this.autoplay});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 32, 32, 16),
      child: Column(
        children: [
          const Icon(Icons.queue_music_rounded, size: 48, color: AppColors.textSecondary),
          const SizedBox(height: 12),
          const Text(
            'Die Warteschlange ist leer',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            autoplay
                ? 'Nach diesem Song geht es mit passender Musik weiter (Autoplay).'
                : 'Füge Songs über das Menü „…“ mit „Zur Warteschlange hinzufügen“ hinzu.',
            textAlign: TextAlign.center,
            style: AppText.tileSubtitle,
          ),
        ],
      ),
    );
  }
}

/// Kompakte Steuerung mit Fortschritt am unteren Rand.
class _BottomControls extends ConsumerWidget {
  const _BottomControls();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(currentTrackProvider);
    final position = ref.watch(positionProvider).value ?? Duration.zero;
    var duration = ref.watch(durationProvider).value ?? track?.length ?? Duration.zero;
    if (duration <= Duration.zero) duration = track?.length ?? Duration.zero;
    final progress =
        duration.inMilliseconds == 0 ? 0.0 : (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.surfaceHighest)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(
              value: progress,
              minHeight: 2,
              backgroundColor: Colors.white.withValues(alpha: 0.15),
              color: Colors.white,
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: PlayerTransportControls(compact: true),
            ),
          ],
        ),
      ),
    );
  }
}
