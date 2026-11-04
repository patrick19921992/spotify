import 'package:flutter/services.dart';

/// Über welchen Weg die App verteilt wird.
///
/// * `full` – GitHub-Version (APK, Windows, iPhone): alles, auch YouTube-Downloads und Selbst-Update.
/// * `play` – Google-Play-Version: ohne YouTube-Funktionen und ohne Selbst-Update (Play-Richtlinien),
///   dafür mit „Song wünschen“, Premium und Werbung.
enum AppChannel {
  full,
  play;

  /// Kennung, die der Server im Header `X-Selfify-Client` bekommt.
  String get id => name;
}

/// Wird beim Bauen gesetzt: `flutter build --flavor play` (Android) oder `--dart-define=CHANNEL=play`
/// (überall, auch Tests und Windows). Ohne Angabe ist es die GitHub-Version.
const _channelDefine = String.fromEnvironment('CHANNEL');

/// In Tests ersetzbar (null = wie gebaut).
AppChannel? channelOverride;

AppChannel get appChannel {
  final forced = channelOverride;
  if (forced != null) return forced;
  return _channelDefine == 'play' || appFlavor == 'play' ? AppChannel.play : AppChannel.full;
}

bool get isPlayChannel => appChannel == AppChannel.play;

/// Fest eingebaute Server-Adresse der Play-Version, gesetzt beim Bauen: `--dart-define=SERVER_URL=https://…`
/// (die CI nimmt sie aus der GitHub-Variable `PLAY_SERVER_URL`). Ohne Angabe fragt die App wie bisher danach.
const _serverUrlDefine = String.fromEnvironment('SERVER_URL');

/// In Tests ersetzbar (null = wie gebaut).
String? serverUrlOverride;

/// Die eingebaute Adresse, so wie angegeben – leer, wenn es keine gibt. Nur die Play-Version hat eine feste Adresse;
/// die GitHub-Version (und Windows/iPhone) lässt immer eintragen, mit welchem Server sie sich verbindet.
/// Aufbereitet (`https://` ergänzt, Anhängsel gekürzt) wird sie in `fixedServerUrl` (state/auth.dart).
String get configuredServerUrl {
  if (!isPlayChannel) return '';
  return (serverUrlOverride ?? _serverUrlDefine).trim();
}

/// YouTube-Suche, Link einfügen, Downloads und Downloader-Verwaltung. In der Play-Version aus.
bool get youtubeFeaturesEnabled => !isPlayChannel;

/// App-Datei selbst laden und installieren („Update installieren“). In der Play-Version macht das Google Play.
bool get selfUpdateEnabled => !isPlayChannel;
