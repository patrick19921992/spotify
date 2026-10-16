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

/// Ausrichtungen, die die App gerade erlaubt (Handy: nur Hochformat). Der Videoplayer stellt sie nach dem
/// Vollbild wieder her – sonst hebt das erste Vollbild-Video die Sperre auf.
List<DeviceOrientation> appOrientations = DeviceOrientation.values;

/// Handy (kürzere Bildschirmseite unter 600): nur Hochformat, wie Spotify – quer bliebe zwischen Systemleisten,
/// Mini-Player und unterer Leiste kaum Platz. Tablets drehen frei. null = Größe noch unbekannt (beim Start).
List<DeviceOrientation>? orientationsForScreen(Size logicalScreen) {
  if (logicalScreen.isEmpty) return null;
  return logicalScreen.shortestSide < 600 ? const [DeviceOrientation.portraitUp] : DeviceOrientation.values;
}
