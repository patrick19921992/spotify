// Windows-Installer und Projektdateien: Dinge, die sich ohne Windows-Rechner nur am Text prüfen lassen.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Abschnitt `[name]` einer Inno-Setup-Datei ohne Kommentarzeilen.
List<String> section(String script, String name) {
  final lines = <String>[];
  var inside = false;
  for (final raw in script.split('\n')) {
    final line = raw.trim();
    if (line.startsWith('[') && line.endsWith(']')) {
      inside = line == '[$name]';
      continue;
    }
    if (inside && line.isNotEmpty && !line.startsWith(';')) lines.add(line);
  }
  return lines;
}

void main() {
  test('Windows: die Deinstallation löscht den Offline-Ordner (Musik muss mit der App vom Rechner)', () {
    final script = File('windows/installer/selfify.iss').readAsStringSync();
    // Der Ordner ergibt sich aus Firmen- und Produktname der Windows-App (getApplicationCacheDirectory)
    final rc = File('windows/runner/Runner.rc').readAsStringSync();
    String value(String key) => RegExp('VALUE "$key", "([^"]+)"').firstMatch(rc)!.group(1)!;
    final folder = '{localappdata}\\${value('CompanyName')}\\${value('ProductName')}\\offline';

    expect(section(script, 'UninstallDelete'), ['Type: filesandordirs; Name: "$folder"']);
    // Bei einem Update darf die Musik nicht verschwinden: dort wird nur der Programmordner aufgeräumt
    expect(section(script, 'InstallDelete').join('\n'), isNot(contains('offline')));
    // … und der Ordner ist wirklich der, in den die App lädt
    final offline = File('lib/state/offline.dart').readAsStringSync();
    expect(offline, contains('Platform.isWindows ? await getApplicationCacheDirectory()'));
    expect(offline, contains(r"Directory('${base.path}/offline')"));
  });

  test('pubspec_overrides.yaml (Platzhalter-Pakete für lokale Läufe) wird nie eingecheckt', () {
    final ignored = File('.gitignore').readAsLinesSync().map((line) => line.trim());
    expect(ignored, contains('pubspec_overrides.yaml'));
  });
}
