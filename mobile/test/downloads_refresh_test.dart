// Download-Liste: Aktualisieren vom Server und Live-Meldungen (echter WebSocket) dürfen sich nicht
// gegenseitig überschreiben; was während einer Verbindungspause fertig wurde, meldet sich trotzdem.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfify/data/models.dart';
import 'package:selfify/state/auth.dart';
import 'package:selfify/state/downloads.dart';
import 'package:selfify/state/library.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

Json raw(int id, String status, {String created = now}) => {...jobJson(id, status), 'created_at': created};

DownloadJob job(int id, String status, {String created = now}) => DownloadJob.fromJson(raw(id, status, created: created));

/// Fake-API, deren Download-Liste der Test von Hand beantwortet, mit lokalem WebSocket-Server.
class _LiveApi extends FakeApi {
  final HttpServer server;
  final sockets = <WebSocket>[];
  final requests = <Completer<List<DownloadJob>>>[];
  int homeLoads = 0;

  _LiveApi(this.server) {
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.add(jsonEncode({'type': 'snapshot', 'jobs': []}));
      socket.listen((_) {});
    });
  }

  @override
  Uri downloadsWebSocketUri() => Uri.parse('ws://127.0.0.1:${server.port}/api/downloads/ws');

  @override
  Future<List<DownloadJob>> downloads({String scope = 'mine', String state = 'all', int limit = 100}) {
    final request = Completer<List<DownloadJob>>();
    requests.add(request);
    return request.future;
  }

  @override
  Future<HomeData> home() {
    homeLoads++;
    return super.home();
  }

  @override
  Future<void> removeDownload(int id) async {}

  void send(Json job) => sockets.last.add(jsonEncode({'type': 'job', 'job': job}));

  /// Wartet auf die nächste Abfrage der Download-Liste.
  Future<Completer<List<DownloadJob>>> nextRequest(int count) async {
    for (var i = 0; i < 400 && requests.length < count; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(requests.length, greaterThanOrEqualTo(count), reason: 'Abfrage Nr. $count kam nicht');
    return requests[count - 1];
  }
}

void main() {
  late _LiveApi api;
  late ProviderContainer container;
  late DownloadsController controller;
  late List<String> finished;

  Future<void> waitFor(bool Function() condition, String what) async {
    for (var i = 0; i < 400 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(condition(), isTrue, reason: what);
  }

  setUp(() async {
    api = _LiveApi(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    SharedPreferences.setMockInitialValues({});
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(await SharedPreferences.getInstance()),
      authProvider.overrideWith(() => FakeAuth(api)),
    ]);
    await container.read(authProvider.future);
    container.listen(downloadsProvider, (_, _) {});
    container.listen(homeProvider, (_, _) {});
    controller = container.read(downloadsProvider.notifier);
    finished = [];
    final subscription = controller.finished.listen((j) => finished.add('${j.id}:${j.status}'));
    addTearDown(subscription.cancel);
  });

  tearDown(() async {
    container.dispose();
    for (final socket in api.sockets) {
      await socket.close();
    }
    await api.server.close(force: true);
  });

  DownloadJob? stateOf(int id) => container.read(downloadsProvider).jobs[id];

  /// Startet die App-Seite: erste Liste vom Server, dann Live-Verbindung.
  Future<void> start(List<DownloadJob> jobs) async {
    (await api.nextRequest(1)).complete(jobs);
    await waitFor(() => container.read(downloadsProvider).connected, 'Live-Verbindung steht');
  }

  test('Live-Meldung während des Aktualisierens bleibt: fertiger Download steht nicht wieder auf „lädt“', () async {
    await start([job(5, 'downloading'), job(6, 'queued')]);

    final refreshing = controller.refresh();
    final request = await api.nextRequest(2);
    api.send(raw(5, 'done'));
    await waitFor(() => stateOf(5)?.status == 'done', 'Live-Meldung kommt an');

    request.complete([job(5, 'downloading'), job(6, 'queued')]); // Antwort von vor der Meldung
    await refreshing;

    expect(stateOf(5)?.status, 'done');
    expect(container.read(activeDownloadCountProvider), 1);
    expect(finished, ['5:done'], reason: 'genau eine Fertig-Meldung');
  });

  test('Fertig während die Verbindung weg war: Hinweis kommt, Startseite lädt neu', () async {
    await start([job(5, 'downloading')]);
    final loadsBefore = api.homeLoads;

    await api.sockets.last.close(); // z. B. App im Hintergrund
    final request = await api.nextRequest(2); // Neuverbindung holt zuerst die Liste
    request.complete([job(5, 'done')]);
    await waitFor(() => stateOf(5)?.status == 'done', 'Liste nach Neuverbindung übernommen');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(finished, ['5:done']);
    expect(api.homeLoads, greaterThan(loadsBefore), reason: 'Startseite zeigt den neuen Titel');
  });

  test('Ältere Antwort stuft nicht zurück, „Erneut versuchen“ von einem anderen Gerät kommt aber an', () async {
    await start([job(5, 'failed'), job(7, 'done')]);

    var refreshing = controller.refresh();
    (await api.nextRequest(2)).complete([job(5, 'failed'), job(7, 'downloading')]);
    await refreshing;
    expect(stateOf(7)?.status, 'done');

    refreshing = controller.refresh();
    (await api.nextRequest(3)).complete([job(5, 'queued', created: '2026-10-10T12:00:00Z'), job(7, 'done')]);
    await refreshing;
    expect(stateOf(5)?.status, 'queued');
  });

  test('Während des Aktualisierens entfernter Eintrag taucht nicht wieder auf', () async {
    await start([job(5, 'done'), job(6, 'failed')]);

    final refreshing = controller.refresh();
    final request = await api.nextRequest(2);
    await controller.remove(6);
    request.complete([job(5, 'done'), job(6, 'failed')]);
    await refreshing;

    expect(stateOf(6), isNull);
    expect(stateOf(5)?.status, 'done');
  });
}
