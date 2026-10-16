import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../core/platform.dart';

/// Hält die Ausrichtung passend zum Gerät: Handy nur Hochformat, Tablet frei (Computer: nichts).
///
/// Entschieden wird erst im Widget-Baum – beim Start kennt Android die Bildschirmgröße oft noch nicht (0×0),
/// und ein Warten in main() könnte den Start im Hintergrund (Wiedergabe ohne Fenster) blockieren. Gemessen wird
/// der ganze Bildschirm, nicht das Fenster (Tablet im geteilten Bildschirm bleibt ein Tablet). Neu gesetzt wird
/// bei Größenänderungen (Foldable auf-/zuklappen) und beim Zurückkehren in die App (neues Android-Fenster
/// vergisst die Sperre).
class OrientationLock extends StatefulWidget {
  final Widget child;
  const OrientationLock({super.key, required this.child});

  @override
  State<OrientationLock> createState() => _OrientationLockState();
}

class _OrientationLockState extends State<OrientationLock> with WidgetsBindingObserver {
  /// Zuletzt an das System geschickt (null = noch nichts).
  List<DeviceOrientation>? _sent;

  @override
  void initState() {
    super.initState();
    if (isDesktopPlatform) return;
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _apply());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() => _apply();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _apply(force: true);
  }

  Size _screenSize() {
    final view = View.maybeOf(context);
    if (view == null) return Size.zero;
    try {
      final display = view.display;
      if (display.devicePixelRatio > 0 && !display.size.isEmpty) return display.size / display.devicePixelRatio;
    } catch (_) {
      // Ältere Systeme melden keinen Bildschirm – dann zählt das Fenster
    }
    return view.devicePixelRatio > 0 ? view.physicalSize / view.devicePixelRatio : Size.zero;
  }

  void _apply({bool force = false}) {
    if (!mounted || isDesktopPlatform) return;
    final wanted = orientationsForScreen(_screenSize());
    if (wanted == null) return; // Größe noch unbekannt – didChangeMetrics kommt
    appOrientations = wanted;
    // Läuft ein Video im Vollbild, gilt dessen Ausrichtung (sonst kippt es beim Zurückkehren ins Hochformat)
    final target = fullScreenOrientations ?? wanted;
    if (!force && _sent != null && listEquals(_sent, target)) return;
    _sent = target;
    // Nicht abwarten: ohne Fenster antwortet Android nie
    unawaited(SystemChrome.setPreferredOrientations(target).catchError((Object _) {}));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
