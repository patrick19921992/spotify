import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/theme.dart';
import '../data/models.dart';
import '../player/player.dart';
import '../state/auth.dart';
import '../state/connectivity.dart';
import '../state/downloads.dart';
import '../state/settings.dart';
import 'widgets/app_update.dart';
import 'widgets/common.dart';
import 'widgets/mini_player.dart';

/// Grundgerüst mit unterer Leiste (Start, Suche, Bibliothek) und Mini-Player.
class AppShell extends ConsumerStatefulWidget {
  final StatefulNavigationShell shell;
  const AppShell({super.key, required this.shell});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  StreamSubscription<DownloadJob>? _finished;

  @override
  void initState() {
    super.initState();
    // Meldung, wenn ein YouTube-Download fertig ist – mit "Abspielen"
    _finished = ref.read(downloadsProvider.notifier).finished.listen(_onDownloadFinished);
  }

  @override
  void dispose() {
    _finished?.cancel();
    super.dispose();
  }

  Future<void> _onDownloadFinished(DownloadJob job) async {
    if (!mounted) return;
    if (job.isFailed) {
      showMessage(context, 'Download fehlgeschlagen: ${job.title}');
      return;
    }
    if (!job.isDone || job.trackId == null) return;
    showMessage(
      context,
      '„${job.title}“ ist jetzt in deiner Bibliothek',
      action: job.mediaType == 'audio'
          ? SnackBarAction(
              label: 'Abspielen',
              textColor: AppColors.accentDark,
              onPressed: () async {
                final api = ref.read(apiProvider);
                if (api == null) return;
                try {
                  final track = await api.track(job.trackId!);
                  await ref.read(playerProvider).playOne(track);
                } catch (_) {}
              },
            )
          : null,
    );
  }

  void _onTab(int index) => widget.shell.goBranch(index, initialLocation: index == widget.shell.currentIndex);

  @override
  Widget build(BuildContext context) {
    final offline = ref.watch(isOfflineProvider);
    final offlineMode = ref.watch(settingsProvider.select((s) => s.offlineMode));
    return Scaffold(
      body: Column(
        children: [
          if (offline || offlineMode)
            Container(
              width: double.infinity,
              color: AppColors.surfaceHighest,
              padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top + 4, bottom: 6),
              child: Text(
                offline ? 'Keine Verbindung – nur heruntergeladene Musik' : 'Offline-Modus ist an',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ),
          Expanded(
            child: MediaQuery.removePadding(
              context: context,
              removeTop: offline || offlineMode,
              child: widget.shell,
            ),
          ),
          const UpdateBanner(),
          const MiniPlayer(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: widget.shell.currentIndex,
        onDestinationSelected: _onTab,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home_rounded), label: 'Start'),
          NavigationDestination(icon: Icon(Icons.search_rounded), selectedIcon: Icon(Icons.manage_search_rounded), label: 'Suche'),
          NavigationDestination(
            icon: Icon(Icons.library_music_outlined),
            selectedIcon: Icon(Icons.library_music_rounded),
            label: 'Bibliothek',
          ),
        ],
      ),
    );
  }
}

/// Symbol "Downloads" mit Zähler der laufenden YouTube-Downloads (für App-Leisten).
class DownloadsAction extends ConsumerWidget {
  const DownloadsAction({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(activeDownloadCountProvider);
    return IconButton(
      tooltip: 'Downloads',
      onPressed: () => context.push('/downloads'),
      icon: Badge(
        isLabelVisible: count > 0,
        label: Text('$count'),
        backgroundColor: AppColors.accent,
        textColor: Colors.black,
        child: const Icon(Icons.downloading_rounded),
      ),
    );
  }
}
