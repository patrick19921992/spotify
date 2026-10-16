// Formulare der Verwaltung (Benutzer/Rubrik anlegen und bearbeiten) auf breiten Fenstern:
// Das Blatt ist dort auf 640 px begrenzt. Der Rand wurde aber aus der Fensterbreite berechnet –
// am Windows-PC blieben so nur ~20 px für den Inhalt, die Texte standen Buchstabe für Buchstabe untereinander.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfify/ui/screens/admin_screen.dart';

import 'support/fakes.dart';

/// Feste Zeit statt pumpAndSettle – Ladekreise drehen sich endlos.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Breite eines Eingabefelds im Blatt.
double fieldWidth(WidgetTester tester, String label) =>
    tester.getSize(find.widgetWithText(TextField, label).last).width;

/// Erwartete Breite des Inhalts: Blatt (höchstens 640 px) minus 20 px Rand links und rechts.
double expectedWidth(Size window) => (window.width < 640 ? window.width : 640) - 40;

void main() {
  const windows = {
    'Handy': Size(400, 860),
    'Windows-Fenster': Size(1260, 800),
    'großer Bildschirm': Size(2560, 1400),
  };

  for (final MapEntry(key: name, value: size) in windows.entries) {
    testWidgets('$name: „Benutzer anlegen“ nutzt die ganze Breite des Blatts', (tester) async {
      await pumpScreen(tester, const AdminScreen(), size: size);
      await tester.tap(find.byKey(const ValueKey('admin-fab-users')));
      await settle(tester);
      expect(find.text('Mindestens 8 Zeichen'), findsOneWidget);
      expect(fieldWidth(tester, 'Benutzername'), moreOrLessEquals(expectedWidth(size), epsilon: 1));
      expect(fieldWidth(tester, 'Passwort'), moreOrLessEquals(expectedWidth(size), epsilon: 1));
      expectNoErrors(tester);
    });
  }

  testWidgets('Windows-Fenster: „Rubrik anlegen“ nutzt die ganze Breite des Blatts', (tester) async {
    const size = Size(1260, 800);
    await pumpScreen(tester, const AdminScreen(), size: size);
    await tester.tap(find.text('Rubriken').first);
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('admin-fab-categories')));
    await settle(tester);
    expect(fieldWidth(tester, 'Name'), moreOrLessEquals(expectedWidth(size), epsilon: 1));
    expectNoErrors(tester);
  });

  testWidgets('Windows-Fenster: „Benutzer bearbeiten“ nutzt die ganze Breite des Blatts', (tester) async {
    const size = Size(1260, 800);
    await pumpScreen(tester, const AdminScreen(), size: size);
    await tester.tap(find.text('@lena').first);
    await settle(tester);
    final sheet = find.byType(BottomSheet);
    expect(sheet, findsOneWidget);
    // Breitestes Element im Blatt: so breit wie das Blatt minus Rand
    final widest = find
        .descendant(of: sheet, matching: find.byType(ListTile))
        .evaluate()
        .map((e) => e.size!.width)
        .fold<double>(0, (a, b) => a > b ? a : b);
    expect(widest, moreOrLessEquals(expectedWidth(size), epsilon: 1));
    expectNoErrors(tester);
  });
}
