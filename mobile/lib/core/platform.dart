import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Läuft die App auf einem Computer (Windows/macOS/Linux)? Nie auf Handy oder Tablet.
///
/// Über defaultTargetPlatform statt dart:io, damit Tests die Plattform umstellen können.
bool get isDesktopPlatform =>
    !kIsWeb &&
    switch (defaultTargetPlatform) {
      TargetPlatform.windows || TargetPlatform.linux || TargetPlatform.macOS => true,
      _ => false,
    };

/// Ist die App gerade im Vordergrund? Am Computer zählt auch ein Fenster ohne Fokus (inactive) –
/// es ist ja weiter sichtbar. Minimiert (hidden) oder im Hintergrund am Handy: nein.
bool isForeground(AppLifecycleState? state) =>
    state == null ||
    state == AppLifecycleState.resumed ||
    (isDesktopPlatform && state == AppLifecycleState.inactive);
