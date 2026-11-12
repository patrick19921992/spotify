// Nachprüfung „Wiedergabe auf anderen Geräten“: Regressionstests zu den bestätigten Funden (Verbindungsaufbau,
// Netzwechsel, Server-Neustart, Gnadenfrist, lange Warteschlangen, Lautstärke am Handy, Fehlermeldungen).

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfify/data/models.dart';
import 'package:selfify/player/player.dart';
import 'package:selfify/state/connect.dart';
import 'package:selfify/state/offline_access.dart' show clockProvider;
import 'package:selfify/ui/screens/detail_widgets.dart';
import 'package:selfify/ui/screens/player_screen.dart';
import 'package:selfify/ui/widgets/connect_sheet.dart';
import 'package:selfify/ui/widgets/remote_volume.dart';

import 'support/connect_harness.dart';
import 'support/fake_audio.dart';
import 'support/fake_connect.dart';
import 'support/fakes.dart';

void main() {
  setUp(useFakeAudioPlatform);

  Map<String, Object?> devices(Map<int, String> others, int? active) =>
      {'type': 'devices', 'devices': FakeConnectServer.devicesJson(others: others, active: active), 'active_device_id': active};

  group('Verbindung', () {
    testWidgets('hängender Handshake: nach 15 s verworfen, dann neuer Versuch', (tester) async {
      final h = await ConnectHarness.start(tester);
      expect(h.server.channels, hasLength(1));
      // Netzwechsel o. Ä.: der nächste Aufbau bekommt nie eine Antwort
      h.server.hangNext = true;
      h.channel.serverClose(1006);
      await h.settle();
      await h.elapse(const Duration(milliseconds: 1300));
      expect(h.server.channels, hasLength(2));
      final hanging = h.channel;
      await h.elapse(const Duration(seconds: 14));
      expect(h.server.channels, hasLength(2), reason: 'noch in der Frist');
      await h.elapse(const Duration(seconds: 2));
      expect(hanging.closedByApp, isNotNull, reason: 'hängender Aufbau wird geschlossen');
      await h.elapse(const Duration(seconds: 3));
      expect(h.server.channels, hasLength(3), reason: 'neuer Versuch nach Backoff');
      await h.dispose();
    });

    testWidgets('Netzwechsel (WLAN -> Mobilfunk): bestehende Verbindung wird ersetzt', (tester) async {
      final network = StreamController<List<ConnectivityResult>>();
      final h = await ConnectHarness.start(tester, connectivity: network.stream);
      network.add([ConnectivityResult.wifi]);
      await h.settle();
      await h.welcome();
      final first = h.channel;
      expect(h.server.channels, hasLength(1));
      // Gleicher Stand noch einmal gemeldet (neue Liste): nichts tun
      network.add([ConnectivityResult.wifi]);
      await h.settle();
      expect(first.isOpen, isTrue);
      expect(h.server.channels, hasLength(1));
      network.add([ConnectivityResult.mobile]);
      await h.settle();
      expect(first.closedByApp, 1000);
      expect(h.server.channels, hasLength(2), reason: 'sofort über das neue Netz, ohne Backoff');
      expect(h.channel.ofType('hello'), hasLength(1));
      await h.dispose();
      network.close().ignore();
    });

    testWidgets('/api/server scheitert beim Start: später erneut gefragt (auch ohne Lebenszyklus-Wechsel)',
        (tester) async {
      final network = StreamController<List<ConnectivityResult>>();
      final h = await _startFailing(tester, network.stream);
      expect(h.state.available, isFalse);
      expect(h.server.channels, isEmpty);
      // Netz kommt zurück -> sofort nachfragen
      h.api.serverInfoFails = false;
      network.add([ConnectivityResult.wifi]);
      await h.settle();
      network.add([ConnectivityResult.mobile]);
      await h.settle();
      expect(h.state.available, isTrue);
      expect(h.server.channels, isNotEmpty);
      expect(h.channel.isOpen, isTrue);
      await h.dispose();
      network.close().ignore();
    });

    testWidgets('/api/server scheitert: Wiederholung mit Wartezeit (PC ohne Netz-Meldungen)', (tester) async {
      final h = await _startFailing(tester, null);
      final calls = h.api.calls.where((c) => c == 'serverInfo').length;
      await h.elapse(const Duration(seconds: 6));
      expect(h.api.calls.where((c) => c == 'serverInfo').length, calls + 1);
      h.api.serverInfoFails = false;
      await h.elapse(const Duration(seconds: 16));
      expect(h.state.available, isTrue);
      expect(h.server.channels, hasLength(1));
      // Danach keine weiteren Abfragen
      final after = h.api.calls.where((c) => c == 'serverInfo').length;
      await h.elapse(const Duration(minutes: 2));
      expect(h.api.calls.where((c) => c == 'serverInfo').length, after);
      await h.dispose();
    });
  });

  group('Gnadenfrist des aktiven Geräts', () {
    testWidgets('aktives Gerät fehlt in der Liste: kein Remote-Modus, dieses Gerät bleibt bedienbar', (tester) async {
      final h = await ConnectHarness.start(tester);
      await h.welcome(active: 2, state: remoteStateJson());
      expect(h.state.isRemote, isTrue);
      // Handy ist weg (Gnadenfrist auf dem Server): active_device_id bleibt, die Liste hat es nicht mehr
      h.channel.receive(devices(const {}, 2));
      await h.settle();
      expect(h.state.activeDeviceId, 2);
      expect(h.state.isRemote, isFalse);
      expect(h.container.read(isRemoteProvider), isFalse);
      expect(h.container.read(remoteDeviceProvider), isNull);
      // Befehle gehen nicht an das verschwundene Gerät
      expect((await h.controller.remoteCommand('pause')).code, 'disconnected');
      expect(h.channel.ofType('cmd'), isEmpty);
      // Kommt es zurück, ist der Remote-Modus wieder da
      h.channel.receive(devices(const {2: 'Windows · BÜRO-PC'}, 2));
      h.channel.receive({'type': 'state', 'device_id': 2, 'state': remoteStateJson()});
      await h.settle();
      expect(h.state.isRemote, isTrue);
      await h.dispose();
    });
  });

  group('lange Warteschlangen', () {
    testWidgets('Befehle mit Index rechnen den Versatz des Ausschnitts dazu und nennen den Titel', (tester) async {
      final h = await ConnectHarness.start(tester);
      await h.welcome(active: 2, state: {
        ...remoteStateJson(),
        'queue_ids': [for (var i = 1501; i <= 2500; i++) i],
        'index': 500,
        'queue_offset': 1500,
      });
      expect(h.state.remote!.queueOffset, 1500);
      final player = h.container.read(playerProvider);
      player.skipToQueueItem(501).ignore();
      await h.settle();
      expect(h.channel.lastOfType('cmd')!['args'], {'index': 2001, 'track_id': 2002});
      player.removeFromQueue(502).ignore();
      await h.settle();
      expect(h.channel.lastOfType('cmd')!['args'], {'index': 2002, 'track_id': 2003});
      player.moveInQueue(503, 510).ignore();
      await h.settle();
      expect(h.channel.lastOfType('cmd')!['args'], {'from': 2003, 'to': 2010, 'track_id': 2004});
      await h.dispose();
    });

    testWidgets('Abspielen ab Titel 1201 einer langen Liste: Ausschnitt um den gewählten Titel', (tester) async {
      final h = await ConnectHarness.start(tester);
      await h.welcome(active: 2, state: remoteStateJson());
      final many = [for (var i = 1; i <= 1500; i++) Track.fromJson(trackJson(i))];
      h.container.read(playerProvider).play(many, index: 1200).ignore();
      await h.settle();
      final args = h.channel.lastOfType('cmd')!['args'] as Map;
      final ids = args['track_ids'] as List;
      expect(ids, hasLength(1000));
      expect(ids[args['index'] as int], 1201, reason: 'nicht Titel 1');
      // Kurze Liste: unverändert
      h.container.read(playerProvider).play(sampleTracks(3), index: 2).ignore();
      await h.settle();
      expect((h.channel.lastOfType('cmd')!['args'] as Map)['index'], 2);
      await h.dispose();
    });
  });

  group('Server-Neustart', () {
    test('gleiche exec-ID nach Neuverbindung wird wieder ausgeführt (Server zählt neu)', () async {
      final h = await ConnectHarness.start(null);
      await h.waitFor(() => h.server.channels.isNotEmpty, 'Verbindung');
      await h.welcome();
      Future<Map<String, dynamic>> exec(String id, String action, [Map<String, Object?> args = const {}]) async {
        final before = h.channel.ofType('ack').where((a) => a['id'] == id).length;
        h.channel.receive({'type': 'exec', 'id': id, 'from': null, 'action': action, 'args': args});
        await h.waitFor(() => h.channel.ofType('ack').where((a) => a['id'] == id).length > before, 'ack $action');
        return h.channel.ofType('ack').lastWhere((a) => a['id'] == id);
      }

      await exec('srv-1', 'take_over', {
        'tracks': [for (var i = 1; i <= 3; i++) trackJson(i)],
        'index': 0,
        'position_ms': 0,
        'playing': true,
        'shuffle': false,
        'repeat': 'off',
      });
      await h.waitFor(() => h.handler.player.playing, 'spielt');
      // Server startet neu (uvicorn schließt mit 1012), die App verbindet sich neu
      h.channel.serverClose(1012);
      await h.waitFor(() => h.server.channels.length == 2 && h.channel.ofType('hello').isNotEmpty, 'neu verbunden');
      await h.welcome();
      final ack = await exec('srv-1', 'pause');
      expect(ack['ok'], isTrue);
      await h.waitFor(() => !h.handler.player.playing, 'pausiert');
      await h.dispose();
      await h.handler.player.dispose();
    });
  });

  group('Warteschlange auf diesem Gerät (exec)', () {
    late ConnectHarness h;

    Future<Map<String, dynamic>> exec(String id, String action, Map<String, Object?> args) async {
      h.channel.receive({'type': 'exec', 'id': id, 'from': 2, 'action': action, 'args': args});
      await h.waitFor(() => h.channel.ofType('ack').any((a) => a['id'] == id), 'ack $action');
      return h.channel.ofType('ack').lastWhere((a) => a['id'] == id);
    }

    test('zweimal schnell entfernt (alte Indizes): der gemeinte Titel geht, kein falscher', () async {
      h = await ConnectHarness.start(null);
      await h.waitFor(() => h.server.channels.isNotEmpty, 'Verbindung');
      await h.welcome();
      await exec('2:t', 'take_over', {
        'tracks': [for (var i = 1; i <= 6; i++) trackJson(i)],
        'index': 0,
        'position_ms': 0,
        'playing': false,
      });
      // Das steuernde Gerät sah [1..6] und entfernt Index 2 (Titel 3), dann Index 4 (Titel 5)
      expect((await exec('2:r1', 'remove_queue', {'index': 2, 'track_id': 3}))['ok'], isTrue);
      expect((await exec('2:r2', 'remove_queue', {'index': 4, 'track_id': 5}))['ok'], isTrue);
      expect(h.handler.tracks.map((t) => t.id), [1, 2, 4, 6]);
      // Titel nicht mehr da -> Fehler statt eines anderen Titels
      final gone = await exec('2:r3', 'remove_queue', {'index': 2, 'track_id': 5});
      expect(gone['code'], 'queue_changed');
      expect(gone['message'], 'Die Warteschlange hat sich gerade geändert. Bitte noch einmal versuchen.');
      expect(h.handler.tracks.map((t) => t.id), [1, 2, 4, 6]);
      // Verschieben nur mit passendem Titel
      expect((await exec('2:m1', 'move_queue', {'from': 2, 'to': 3, 'track_id': 2}))['code'], 'queue_changed');
      expect((await exec('2:m2', 'move_queue', {'from': 2, 'to': 3, 'track_id': 4}))['ok'], isTrue);
      expect(h.handler.tracks.map((t) => t.id), [1, 2, 6, 4]);
      // Springen zum gemeinten Titel, auch wenn der Index verrutscht ist; ohne track_id wie bisher
      expect((await exec('2:s1', 'skip_to', {'index': 2, 'track_id': 4}))['ok'], isTrue);
      expect(h.handler.player.currentIndex, 3);
      expect((await exec('2:s2', 'skip_to', {'index': 1}))['ok'], isTrue);
      expect(h.handler.player.currentIndex, 1);
      await h.dispose();
      await h.handler.player.dispose();
    });

    test('Stand einer langen Warteschlange nennt den Beginn des Ausschnitts', () async {
      h = await ConnectHarness.start(null);
      final many = [for (var i = 1; i <= 1500; i++) Track.fromJson(trackJson(i))];
      unawaited(h.container.read(playerProvider).playLocally(many, index: 1200, wait: false));
      await h.waitFor(() => h.handler.player.currentIndex == 1200, 'geladen');
      final snapshot = localSnapshot(h.handler, canVolume: false);
      expect(snapshot['queue_offset'], 500);
      expect((snapshot['queue_ids'] as List).first, 501);
      expect(localSnapshot(h.handler, canVolume: false)['index'], 700);
      await h.dispose();
      await h.handler.player.dispose();
    });
  });

  group('Oberfläche', () {
    Future<FakeConnectServer> pump(WidgetTester tester, Widget screen, {DateTime Function()? clock}) async {
      final server = FakeConnectServer();
      await pumpScreen(
        tester,
        screen,
        api: FakeApi()..serverFeatures = const ['connect'],
        overrides: [
          connectChannelFactoryProvider.overrideWithValue(server.factory),
          connectDeviceInfoProvider.overrideWithValue(phoneInfo),
          if (clock != null) clockProvider.overrideWithValue(clock),
        ],
      );
      return server;
    }

    Future<void> receive(WidgetTester tester, FakeConnectChannel channel, Map<String, Object?> message) async {
      channel.receive(message);
      await tester.pump();
      await tester.pump();
    }

    Future<void> remoteMode(WidgetTester tester, FakeConnectServer server, {Map<int, String>? others}) async {
      final devicesOf = others ?? const {2: 'Windows · BÜRO-PC'};
      server.welcome(server.last, others: devicesOf);
      await tester.pump();
      await receive(tester, server.last, devices(devicesOf, 2));
      await receive(tester, server.last, {'type': 'state', 'device_id': 2, 'state': remoteStateJson(volume: 0.8)});
    }

    Future<void> openPlayer(WidgetTester tester) async {
      Navigator.of(tester.element(find.byType(ConnectButton)))
          .push(MaterialPageRoute<void>(builder: (_) => const PlayerScreen()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    Future<void> teardown(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    }

    const button = Scaffold(body: Center(child: ConnectButton()));

    testWidgets('Vollbild-Player am Handy: Lautstärke des PCs mit gedrosselten Befehlen', (tester) async {
      final server = await pump(tester, button);
      await remoteMode(tester, server);
      await openPlayer(tester);
      expect(find.byType(RemoteVolumeSlider), findsOneWidget);
      expect(find.byTooltip('Lauter'), findsOneWidget);
      await tester.timedDrag(find.byType(RemoteVolumeSlider), const Offset(-200, 0), const Duration(milliseconds: 600));
      await tester.pump();
      final volumes = [
        for (final c in server.last.ofType('cmd'))
          if (c['action'] == 'set_volume') (c['args'] as Map)['volume'] as num,
      ];
      expect(volumes.length, inInclusiveRange(2, 6), reason: 'höchstens 4 je Sekunde plus Endwert, nicht je Bewegung');
      expect(volumes.last, lessThan(0.8));
      // Der Regler bleibt beim gezogenen Wert, auch wenn der alte Stand noch einmal kommt
      final slider = tester.widget<Slider>(find.descendant(of: find.byType(RemoteVolumeSlider), matching: find.byType(Slider)));
      expect(slider.value, closeTo(volumes.last.toDouble(), 0.01));
      // Tasten: ein Befehl je Druck
      await tester.tap(find.byTooltip('Lauter'));
      await tester.pump();
      expect((server.last.lastOfType('cmd')!['args'] as Map)['volume'], closeTo(0.9, 0.001));
      await teardown(tester);
    });

    testWidgets('Handy als Ziel (ohne Lautstärke): kein Regler', (tester) async {
      final server = await pump(tester, button);
      server.welcome(server.last);
      await tester.pump();
      final phones = FakeConnectServer.devicesJson(active: 2)
        ..[1] = {...FakeConnectServer.devicesJson(active: 2)[1], 'caps': {'volume': false, 'play': true}};
      await receive(tester, server.last, {'type': 'devices', 'devices': phones, 'active_device_id': 2});
      await receive(tester, server.last, {'type': 'state', 'device_id': 2, 'state': remoteStateJson()});
      await openPlayer(tester);
      expect(find.text('Bohemian Rhapsody 1'), findsOneWidget);
      expect(find.byType(RemoteVolumeSlider), findsNothing);
      await teardown(tester);
    });

    testWidgets('Vollbild-Player bleibt offen, bis der erste Stand des neuen Geräts da ist', (tester) async {
      final server = await pump(tester, button);
      await remoteMode(tester, server, others: const {2: 'Windows · BÜRO-PC', 3: 'Laptop'});
      await openPlayer(tester);
      expect(find.byType(PlayerScreen), findsOneWidget);
      // An den Laptop übertragen: Geräteliste kommt, Stand noch nicht
      await receive(tester, server.last, devices(const {2: 'Windows · BÜRO-PC', 3: 'Laptop'}, 3));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(PlayerScreen), findsOneWidget, reason: 'nicht von selbst schließen');
      expect(find.text('Bohemian Rhapsody 1'), findsWidgets, reason: 'letzter Titel bleibt sichtbar');
      await receive(tester, server.last,
          {'type': 'state', 'device_id': 3, 'state': remoteStateJson(trackId: 2)});
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Bohemian Rhapsody 2'), findsWidgets);
      await teardown(tester);
    });

    testWidgets('Play-Knopf auf der Albumseite: Fehler des anderen Geräts als Meldung', (tester) async {
      final server = await pump(
        tester,
        Scaffold(
          body: Column(children: [
            const ConnectButton(),
            DetailPlayControls(tracks: sampleTracks(3), playContext: const PlayContext('album', id: 7)),
          ]),
        ),
      );
      await remoteMode(tester, server);
      await tester.tap(find.byIcon(Icons.pause_rounded).last);
      await tester.pump();
      final cmd = server.last.lastOfType('cmd')!;
      expect(cmd['action'], 'pause');
      await receive(tester, server.last, {'type': 'result', 'id': cmd['id'], 'ok': false, 'code': 'timeout'});
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Das Gerät antwortet nicht.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await teardown(tester);
    });
  });
}

/// Start, bei dem `/api/server` scheitert (z. B. ohne Netz).
Future<ConnectHarness> _startFailing(WidgetTester tester, Stream<List<ConnectivityResult>>? network) =>
    ConnectHarness.start(tester, connectivity: network, serverInfoFails: true);
