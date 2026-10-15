import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform.dart';
import '../../state/auth.dart';

export '../../core/platform.dart' show isDesktopPlatform;

/// Ab dieser Fensterbreite zeigt der Computer die Desktop-Ansicht (Seitenleiste + Player-Leiste).
/// Schmaler (z. B. Fenster halb am Bildschirmrand) bleibt es bei der Handy-Ansicht.
const kDesktopBreakpoint = 840.0;

/// Ab dieser Breite ist die Seitenleiste ausgeklappt, darunter nur Symbole.
const kSidebarExpandedBreakpoint = 1100.0;

const kSidebarWidth = 280.0;
const kSidebarRailWidth = 76.0;
/// Mindestens ~362: darunter läuft die Kopfzeile der Warteschlange („Warteschlange leeren“) im Test über.
const kRightPanelWidth = 380.0;
const kPlayerBarHeight = 92.0;
const kDesktopGap = 8.0;

/// Fenster: Startgröße und kleinste Größe (Windows).
const kInitialWindowSize = Size(1280, 800);
const kMinWindowSize = Size(400, 600);


/// Desktop-Ansicht nur auf dem Computer und nur bei breitem Fenster.
bool useDesktopLayout(BuildContext context) =>
    isDesktopPlatform && MediaQuery.sizeOf(context).width >= kDesktopBreakpoint;

/// Rechte Spalte der Desktop-Ansicht.
enum DesktopPanel { none, queue, lyrics }

class DesktopPanelController extends Notifier<DesktopPanel> {
  static const _pref = 'desktop.panel';

  @override
  DesktopPanel build() {
    try {
      final name = ref.read(sharedPreferencesProvider).getString(_pref);
      return DesktopPanel.values.firstWhere((p) => p.name == name, orElse: () => DesktopPanel.none);
    } catch (_) {
      return DesktopPanel.none;
    }
  }

  void toggle(DesktopPanel panel) => _set(state == panel ? DesktopPanel.none : panel);
  void close() => _set(DesktopPanel.none);

  void _set(DesktopPanel panel) {
    state = panel;
    try {
      ref.read(sharedPreferencesProvider).setString(_pref, panel.name);
    } catch (_) {}
  }
}

final desktopPanelProvider = NotifierProvider<DesktopPanelController, DesktopPanel>(DesktopPanelController.new);
