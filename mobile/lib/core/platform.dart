import 'dart:collection';

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

/// Während ein Video im Vollbild läuft: dessen Ausrichtungen (z. B. quer). Die App-Sperre darf sie dann nicht
/// überschreiben (etwa beim Zurückkehren nach der Benachrichtigungsleiste). null = kein Vollbild.
List<DeviceOrientation>? fullScreenOrientations;

/// [appOrientations] zum Zeitpunkt des Lesens – für den Videoplayer, der die Liste erst beim Verlassen des
/// Vollbilds liest (Foldable dazwischen auf- oder zugeklappt).
class LiveAppOrientations extends ListBase<DeviceOrientation> {
  const LiveAppOrientations();

  @override
  int get length => appOrientations.length;

  @override
  set length(int value) => throw UnsupportedError('nur lesen');

  @override
  DeviceOrientation operator [](int index) => appOrientations[index];

  @override
  void operator []=(int index, DeviceOrientation value) => throw UnsupportedError('nur lesen');
}

/// Handy (kürzere Bildschirmseite unter 600): nur Hochformat, wie Spotify – quer bliebe zwischen Systemleisten,
/// Mini-Player und unterer Leiste kaum Platz. Tablets drehen frei. null = Größe noch unbekannt (beim Start).
List<DeviceOrientation>? orientationsForScreen(Size logicalScreen) {
  if (logicalScreen.isEmpty) return null;
  return logicalScreen.shortestSide < 600 ? const [DeviceOrientation.portraitUp] : DeviceOrientation.values;
}
