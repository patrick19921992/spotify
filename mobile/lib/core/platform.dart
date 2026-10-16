import 'dart:ui' show FlutterView;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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

/// Handy: nur Hochformat (wie Spotify) – quer bliebe zwischen Systemleisten, Mini-Player und unterer Leiste kaum
/// Platz für den Inhalt. Tablets (kürzere Seite ab 600) und Computer drehen weiter frei.
Future<void> lockPortraitOnPhones(FlutterView? view) async {
  if (isDesktopPlatform || view == null || view.devicePixelRatio <= 0) return;
  if (view.physicalSize.shortestSide / view.devicePixelRatio >= 600) return;
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
}
