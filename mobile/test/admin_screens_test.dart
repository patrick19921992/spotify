// Verwaltung: Rubrik entfernen (ehrliche Abfrage) und Downloads aller Familienmitglieder.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfify/data/models.dart';
import 'package:selfify/state/downloads.dart';
import 'package:selfify/ui/screens/admin_screen.dart';
import 'package:selfify/ui/screens/downloads_screen.dart';
import 'package:selfify/ui/screens/downloads_widgets.dart';

import 'support/fakes.dart';

/// Lenas Download (anderes Familienmitglied).
Json lenaJob(String status) => {
      ...jobJson(50, status),
      'title': 'Lenas Lied',
      'user': {'id': 2, 'display_name': 'Lena'},
    };

class _FamilyApi extends FakeApi {
  final deleted = <int>[];
  var lenaStatus = 'failed';

  List<DownloadJob> get _own => [for (final id in [1, 2, 3, 4]) DownloadJob.fromJson(FakeDownloadsJobs.byId[id]!)];

  @override
  Future<List<DownloadJob>> downloads({String scope = 'mine', String state = 'all', int limit = 100}) async {
    calls.add('downloads:$scope');
    return scope == 'all' ? [..._own, DownloadJob.fromJson(lenaJob(lenaStatus))] : _own;
  }

  @override
  Future<DownloadJob> retryDownload(int id) async {
    lenaStatus = 'downloading'; // läuft auf dem Server sofort los
    return DownloadJob.fromJson(lenaJob('queued'));
  }

  @override
  Future<void> deleteCategory(int id) async => deleted.add(id);
}

/// Dieselben eigenen Aufträge wie in [FakeDownloads].
abstract final class FakeDownloadsJobs {
  static final byId = {
    for (final j in [jobJson(1, 'downloading'), jobJson(2, 'queued'), jobJson(3, 'done'), jobJson(4, 'failed')])
      j['id'] as int: j,
  };
}

Future<void> settle(WidgetTester tester, {int steps = 10}) async {
  for (var i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

ProviderContainer containerOf(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(DownloadsScreen)), listen: false);

void main() {
  testWidgets('Rubrik entfernen: Abfrage nennt die Folgen und verlangt den Namen', (tester) async {
    final api = _FamilyApi();
    await pumpScreen(tester, const AdminScreen(), api: api);
    await tester.ensureVisible(find.text('Rubriken').first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Rubriken').first);
    await settle(tester);
    await tester.tap(find.text('Musik').first);
    await settle(tester);

    expect(find.textContaining('Lieblingssongs'), findsWidgets, reason: 'Hinweis unter dem Knopf sagt die Wahrheit');
    await tester.ensureVisible(find.text('Rubrik entfernen'));
    await tester.tap(find.text('Rubrik entfernen'));
    await settle(tester);

    expect(find.textContaining('„Musik“ enthält 42 Titel'), findsOneWidget);
    expect(find.textContaining('Playlists, Lieblingssongs und Verlauf'), findsOneWidget);
    final button = find.widgetWithText(TextButton, 'Endgültig entfernen');
    expect(tester.widget<TextButton>(button).onPressed, isNull, reason: 'erst nach Eingabe des Namens');

    await tester.enterText(find.byType(TextField).last, 'musik');
    await tester.pump();
    expect(tester.widget<TextButton>(button).onPressed, isNotNull);
    await tester.tap(button);
    await settle(tester);

    expectNoErrors(tester);
    expect(api.deleted, [1]);
  });

  testWidgets('Verwaltung › Downloader: „Alle Downloads ansehen“ öffnet die Ansicht „Alle“', (tester) async {
    await pumpScreen(tester, const AdminScreen());
    await tester.ensureVisible(find.text('Downloader').first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Downloader').first);
    await settle(tester);
    // Der Knopf steht unten in der Liste und wird erst beim Scrollen aufgebaut
    await tester.dragUntilVisible(find.text('Alle Downloads ansehen'), find.byType(ListView).last, const Offset(0, -300));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Alle Downloads ansehen'));
    await settle(tester);
    expect(find.text('Navigiert: /downloads?scope=all'), findsOneWidget);
  });

  testWidgets('„Alle Downloads ansehen“: fremder wiederholter Auftrag bleibt aktuell und zählt nicht als eigener',
      (tester) async {
    final api = _FamilyApi();
    await pumpScreen(tester, const DownloadsScreen(showAll: true), api: api);
    await settle(tester);

    // Direkt „Alle“: Lenas Download ist sichtbar, ohne umzuschalten
    final lena = find.ancestor(of: find.text('Lenas Lied'), matching: find.byType(DownloadJobTile));
    expect(lena, findsOneWidget);
    final container = containerOf(tester);
    final activeBefore = container.read(activeDownloadCountProvider);

    await tester.tap(find.descendant(of: lena, matching: find.byTooltip('Erneut versuchen')));
    await settle(tester);
    expect(container.read(activeDownloadCountProvider), activeBefore, reason: 'Lenas Auftrag ist nicht meiner');

    api.lenaStatus = 'done'; // auf dem Server fertig geworden
    await settle(tester, steps: 40); // nächste Abfrage (alle 3 s)

    expectNoErrors(tester);
    expect(tester.widget<DownloadJobTile>(lena).job.status, 'done');
    expect(container.read(downloadsProvider).jobs.containsKey(50), isFalse);
  });
}
