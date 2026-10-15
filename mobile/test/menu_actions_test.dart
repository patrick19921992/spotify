// Aktionen aus Menüs/Blättern, die sich vor dem Ende der Server-Anfrage schließen.
// Vorher: Fehlermeldung statt Löschen bzw. Fehler + veraltete Ansicht bei langsamer Antwort.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfify/ui/screens/album_screen.dart';
import 'package:selfify/ui/widgets/track_tile.dart';

import 'support/fakes.dart';

/// Menü-Eintrag sichtbar machen (das Blatt scrollt) und antippen.
Future<void> tapEntry(WidgetTester tester, String text) async {
  await tester.ensureVisible(find.text(text));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tap(find.text(text));
}

Future<void> settle(WidgetTester tester, {int steps = 10}) async {
  for (var i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('Admin löscht einen Titel über das Song-Menü', (tester) async {
    final api = await pumpScreen(tester, const AlbumScreen(albumId: 7));
    await tester.tap(find.descendant(of: find.byType(TrackTile).first, matching: find.byIcon(Icons.more_vert_rounded)));
    await settle(tester);
    await tapEntry(tester, 'Datei vom Server löschen');
    await settle(tester);
    await tester.tap(find.text('Löschen'));
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(api.calls.where((c) => c.startsWith('deleteTrack')), isNotEmpty);
    expect(find.text('Gelöscht'), findsOneWidget);
  });

  testWidgets('Zu Playlist hinzufügen bei langsamem Server', (tester) async {
    final api = await pumpScreen(tester, const AlbumScreen(albumId: 7));
    api.writeDelay = const Duration(milliseconds: 600);
    await tester.tap(find.descendant(of: find.byType(TrackTile).first, matching: find.byIcon(Icons.more_vert_rounded)));
    await settle(tester);
    await tapEntry(tester, 'Zu Playlist hinzufügen');
    await settle(tester);
    await tester.tap(find.textContaining('Roadtrip').first);
    await settle(tester, steps: 12);
    expect(tester.takeException(), isNull);
    expect(api.calls.where((c) => c.startsWith('addToPlaylist')), isNotEmpty);
    expect(find.textContaining('hinzugefügt'), findsOneWidget);
  });
}
