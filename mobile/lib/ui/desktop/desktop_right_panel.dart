import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../player/player.dart';
import '../../state/connectivity.dart';
import '../../state/library.dart';
import '../../state/settings.dart';
import '../screens/player_lyrics.dart';
import '../screens/queue_screen.dart';
import '../widgets/common.dart';
import 'desktop_layout.dart';

/// Rechte Spalte: Warteschlange oder Songtext.
class DesktopRightPanel extends ConsumerWidget {
  final DesktopPanel panel;
  const DesktopRightPanel({super.key, required this.panel});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final panels = ref.read(desktopPanelProvider.notifier);
    Widget tab(DesktopPanel p, String label) => Flexible(
          child: TextButton(
            onPressed: () => panels.toggle(p),
            style: TextButton.styleFrom(foregroundColor: panel == p ? Colors.white : AppColors.textSecondary),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontWeight: panel == p ? FontWeight.w800 : FontWeight.w600),
            ),
          ),
        );
    return Material(
      color: AppColors.background,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 4, 0),
            child: Row(
              children: [
                Expanded(
                  child: Row(children: [tab(DesktopPanel.queue, 'Warteschlange'), tab(DesktopPanel.lyrics, 'Songtext')]),
                ),
                IconButton(tooltip: 'Schließen', icon: const Icon(Icons.close_rounded), onPressed: panels.close),
              ],
            ),
          ),
          Expanded(
            child: switch (panel) {
              DesktopPanel.queue => const QueueScreen(embedded: true),
              DesktopPanel.lyrics => const DesktopLyricsPanel(),
              DesktopPanel.none => const SizedBox.shrink(),
            },
          ),
        ],
      ),
    );
  }
}

/// Songtext des laufenden Titels (zeitsynchron, Tippen spult) – nutzt [PlayerLyricsView].
class DesktopLyricsPanel extends ConsumerWidget {
  const DesktopLyricsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(currentTrackProvider);
    if (track == null) {
      return const EmptyState(
        icon: Icons.lyrics_outlined,
        title: 'Gerade läuft nichts',
        message: 'Spiel einen Song ab – hier erscheint dann sein Songtext.',
      );
    }
    final offline = ref.watch(isOfflineProvider) || ref.watch(settingsProvider.select((s) => s.offlineMode));
    if (offline) {
      return const EmptyState(
        icon: Icons.cloud_off_rounded,
        title: 'Kein Songtext offline',
        message: 'Songtexte gibt es nur mit Verbindung zum Server.',
      );
    }
    final value = ref.watch(lyricsProvider(track.id));
    final lyrics = value.value;
    if (lyrics == null) {
      if (value.hasError && !value.isLoading) {
        return ErrorView(message: errorText(value.error!), onRetry: () => ref.invalidate(lyricsProvider(track.id)));
      }
      return const Center(child: CircularProgressIndicator());
    }
    if (!lyrics.lines.any((line) => line.text.trim().isNotEmpty)) {
      return const EmptyState(
        icon: Icons.lyrics_outlined,
        title: 'Kein Songtext',
        message: 'Für diesen Song gibt es keinen Songtext.',
      );
    }
    return AnimatedContainer(
      duration: const Duration(milliseconds: 500),
      color: lyricsColorFor(track),
      child: PlayerLyricsView(
        key: ValueKey(track.id),
        lyrics: lyrics,
        fontSize: 22,
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 60),
      ),
    );
  }
}
