import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import '../../state/connectivity.dart';
import '../../state/settings.dart';
import '../widgets/app_update.dart';
import 'desktop_layout.dart';
import 'desktop_player_bar.dart';
import 'desktop_right_panel.dart';
import 'desktop_sidebar.dart';

/// Desktop-Grundgerüst wie die Spotify-App: Seitenleiste | Inhalt (die Tabs) | rechte Spalte,
/// darunter die Player-Leiste über die ganze Breite.
///
/// Ist selbst ein Scaffold: so zeigen alle Seiten darin Meldungen (SnackBars) nur einmal an.
class DesktopShell extends ConsumerWidget {
  final StatefulNavigationShell shell;
  const DesktopShell({super.key, required this.shell});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final width = MediaQuery.sizeOf(context).width;
    final panel = ref.watch(desktopPanelProvider);
    final offline = ref.watch(isOfflineProvider);
    final offlineMode = ref.watch(settingsProvider.select((s) => s.offlineMode));
    final expanded = width >= kSidebarExpandedBreakpoint;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(kDesktopGap, kDesktopGap, kDesktopGap, 0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: expanded ? kSidebarWidth : kSidebarRailWidth,
              child: DesktopSidebar(shell: shell, expanded: expanded),
            ),
            const SizedBox(width: kDesktopGap),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Column(
                  children: [
                    if (offline || offlineMode)
                      Container(
                        width: double.infinity,
                        color: AppColors.surfaceHighest,
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Text(
                          offline ? 'Keine Verbindung – nur heruntergeladene Musik' : 'Offline-Modus ist an',
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                      ),
                    Expanded(child: shell),
                    const UpdateBanner(),
                  ],
                ),
              ),
            ),
            if (panel != DesktopPanel.none) ...[
              const SizedBox(width: kDesktopGap),
              SizedBox(width: kRightPanelWidth, child: DesktopRightPanel(panel: panel)),
            ],
          ],
        ),
      ),
      bottomNavigationBar: const DesktopPlayerBar(),
    );
  }
}
