// Geräte-Verbindung („Wiedergabe auf anderen Geräten“) mit nachgebautem Server: Begrüßung, Geräteliste,
// Remote-Modus mit Live-Position, Befehle, Close-Codes, Token-Erneuerung, Hintergrund und Premium.

import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfify/data/api.dart';
import 'package:selfify/data/models.dart';
import 'package:selfify/player/player.dart';
import 'package:selfify/state/connect.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'support/connect_harness.dart';
import 'support/fake_audio.dart';
import 'support/fake_connect.dart';
import 'support/fakes.dart';

void main() {
  setUp(useFakeAudioPlatform);

  group('Verfügbarkeit', () {
    testWidgets('alter Server ohne features: kein Verbindungsversuch, nichts sichtbar', (tester) async {
      final h = await ConnectHarness.start(tester, features: const []);
      expect(h.api.calls, contains('serverInfo'));
      expect(h.server.channels, isEmpty);
      expect(h.state.available, isFalse);
      expect(h.state.supported, isFalse);
      // Auch später (Backoff-Zeiten) nicht
      await h.elapse(const Duration(minutes: 1));
      expect(h.server.channels, isEmpty);
      await h.dispose();
    });

    testWidgets('Handshake 404 trotz Angabe: aus bis zum nächsten Zurückkehren in die App', (tester) async {
      final h = await ConnectHarness.start(tester, features: const []);
      h.server.failNext =
          WebSocketChannelException.from(const WebSocketException('Connection was not upgraded to websocket', 404));
      h.api.serverFeatures = const ['connect'];
      await h.controller.loadFeatures();
      await h.settle();
      expect(h.server.channels, hasLength(1));
      expect(h.state.available, isFalse);
      await h.elapse(const Duration(minutes: 1));
      expect(h.server.channels, hasLength(1), reason: 'kein erneuter Versuch');
      // Zurück in die App: neuer Versuch
      h.setLifecycle(AppLifecycleState.paused);
      h.setLifecycle(AppLifecycleState.resumed);
      await h.settle();
      expect(h.server.channels, hasLength(2));
      expect(h.state.available, isTrue);
      await h.dispose();
    });

    testWidgets('Close 4400 (Protokoll nicht unterstützt): aus bis zum Zurückkehren', (tester) async {
      final h = await ConnectHarness.start(tester);
      h.channel.serverClose(4400, 'Protokoll nicht unterstützt');
      await h.settle();
      expect(h.state.available, isFalse);
      await h.elapse(const Duration(minutes: 1));
      expect(h.server.channels, hasLength(1));
      await h.dispose();
    });
  });

  group('Verbindung', () {
    testWidgets('hello: Typ, Plattform, Fähigkeiten; Token im Header, nicht im Link', (tester) async {
      final h = await ConnectHarness.start(tester);
      final channel = h.channel;
      expect(channel.uri.toString(), 'wss://musik.test/api/connect/ws');
      expect(channel.uri.query, isEmpty);
      expect(channel.headers['Authorization'], 'Bearer acc');
      final hello = channel.ofType('hello').single;
      expect(hello['v'], 1);
      expect(hello['kind'], 'phone');
      expect(hello['platform'], 'android');
      expect(hello['caps'], {'volume': false, 'play': true});
      expect(hello['playing'], isFalse);
      expect(h.state.connected, isFalse, reason: 'erst nach welcome');
      await h.dispose();
    });

    testWidgets('PC meldet sich als Computer mit Lautstärke', (tester) async {
      final h = await ConnectHarness.start(tester, info: computerInfo);
      final hello = h.channel.ofType('hello').single;
      expect(hello['kind'], 'computer');
      expect(hello['caps'], {'volume': true, 'play': true});
      await h.dispose();
    });

    test('Gerätetyp nach Bildschirm', () {
      expect(deviceKindFor(desktop: true, logicalScreen: const Size(400, 800)), 'computer');
      expect(deviceKindFor(desktop: false, logicalScreen: const Size(800, 1280)), 'tablet');
      expect(deviceKindFor(desktop: false, logicalScreen: const Size(411, 891)), 'phone');
    });

    testWidgets('welcome: Geräteliste, eigenes Gerät, nichts ferngesteuert', (tester) async {
      final h = await ConnectHarness.start(tester);
      await h.welcome();
      final state = h.state;
      expect(state.connected, isTrue);
      expect(state.selfId, 1);
      expect(state.devices.map((d) => d.name), ['Android · Pixel', 'Windows · BÜRO-PC']);
      expect(state.selfDevice!.isSelf, isTrue);
      expect(state.devices[1].kind, 'computer');
      expect(state.devices[1].canVolume, isTrue);
      expect(state.isRemote, isFalse);
      expect(h.container.read(isRemoteProvider), isFalse);
      await h.dispose();
    });

    testWidgets('devices + state: Remote-Modus mit Titel, Position läuft lokal weiter', (tester) async {
      final h = await ConnectHarness.start(tester);
      await h.welcome();
      h.channel.receive({'type': 'devices', 'devices': FakeConnectServer.devicesJson(active: 2), 'active_device_id': 2});
      h.channel.receive({'type': 'state', 'device_id': 2, 'state': remoteStateJson(positionMs: 60000)});
      await h.settle();
      expect(h.state.isRemote, isTrue);
      expect(h.container.read(isRemoteProvider), isTrue);
      expect(h.container.read(currentTrackProvider)!.id, 1);
      expect(h.container.read(isPlayingProvider), isTrue);
      expect(h.container.read(remoteDeviceProvider)!.name, 'Windows · BÜRO-PC');
      expect(h.container.read(playContextProvider)!.id, 7);
      expect(h.controller.remotePosition(), const Duration(seconds: 60));
      // 2,5 s später: lokal hochgerechnet (ohne Uhrvergleich mit dem anderen Gerät)
      h.now = h.now.add(const Duration(milliseconds: 2500));
      expect(h.controller.remotePosition(), const Duration(milliseconds: 62500));
      // Pausiert: steht
      h.channel.receive({'type': 'state', 'device_id': 2, 'state': remoteStateJson(playing: false, positionMs: 70000)});
      await h.settle();
      h.now = h.now.add(const Duration(seconds: 10));
      expect(h.controller.remotePosition(), const Duration(seconds: 70));
      expect(h.container.read(isPlayingProvider), isFalse);
      // Nicht über das Ende hinaus
      h.channel.receive({'type': 'state', 'device_id': 2, 'state': remoteStateJson(positionMs: 200000)});
      await h.settle();
      h.now = h.now.add(const Duration(minutes: 5));
      expect(h.controller.remotePosition(), const Duration(milliseconds: 201000));
      await h.dispose();
    });

    testWidgets('kommende Titel bekommen ihren Index in der Warteschlange (unsichtbare fehlen)', (tester) async {
      final remote = RemoteState.tryParse({
        ...remoteStateJson(),
        'queue_ids': [1, 2, 99, 3],
        'index': 0,
        'upcoming': [trackJson(2), trackJson(3)],
      }, DateTime(2026))!;
      expect([for (final e in remote.upcomingEntries) (e.index, e.track.id)], [(1, 2), (3, 3)]);
      final shuffled = RemoteState.tryParse({
        ...remoteStateJson(),
        'queue_ids': [1, 2, 3],
        'index': 2,
        'shuffle': true,
        'shuffle_order': [2, 0, 1],
        'upcoming': [trackJson(1), trackJson(2)],
      }, DateTime(2026))!;
      expect([for (final e in shuffled.upcomingEntries) e.index], [0, 1]);
    });

    testWidgets('Befehl mit Fehler: Text aus der Tabelle, sonst der vom Gerät', (tester) async {
      final h = await ConnectHarness.start(tester);
      await h.welcome();
      final pending = h.controller.command(2, 'set_volume', {'volume': 0.5});
      await h.settle();
      final cmd = h.channel.lastOfType('cmd')!;
      expect(cmd['target'], 2);
      expect(cmd['action'], 'set_volume');
      expect(cmd['args'], {'volume': 0.5});
      h.channel.receive({'type': 'result', 'id': cmd['id'], 'ok': false, 'code': 'unsupported'});
      await h.settle();
      final result = await pending;
      expect(result.ok, isFalse);
      expect(result.text, 'Das kann dieses Gerät nicht.');

      final second = h.controller.command(2, 'next');
      await h.settle();
      h.channel.receive({
        'type': 'result',
        'id': h.channel.lastOfType('cmd')!['id'],
        'ok': false,
        'code': 'skip_limit',
        'message': 'Du hast in dieser Stunde schon 6-mal übersprungen. Mit Premium unbegrenzt.',
      });
      await h.settle();
      expect((await second).text, 'Du hast in dieser Stunde schon 6-mal übersprungen. Mit Premium unbegrenzt.');
      await h.dispose();
    });

    testWidgets('offener Befehl scheitert bei Verbindungsabbruch mit „Keine Verbindung“', (tester) async {
      final h = await ConnectHarness.start(tester);
      await h.welcome();
      final pending = h.controller.command(2, 'pause');
      await h.settle();
      h.channel.serverClose(1001, 'Server fährt herunter');
      await h.settle();
      final result = await pending;
      expect(result.code, 'disconnected');
      expect(result.text, 'Keine Verbindung zu deinen Geräten.');
      expect(h.state.connected, isFalse);
      // Ohne Verbindung gar nicht erst senden
      expect((await h.controller.command(2, 'pause')).code, 'disconnected');
      await h.dispose();
    });
  });

  group('Close-Codes und Wiederverbindung', () {
    testWidgets('1001: Backoff, dann neu verbinden', (tester) async {
      final h = await ConnectHarness.start(tester);
      await h.welcome();
      h.channel.serverClose(1001);
      await h.settle();
      expect(h.server.channels, hasLength(1), reason: 'nicht sofort');
      await h.elapse(const Duration(milliseconds: 1300));
      expect(h.server.channels, hasLength(2));
      // Abbruch vor dem welcome: nächste Stufe (2 s ± 20 %)
      h.channel.serverClose(1006);
      await h.settle();
      await h.elapse(const Duration(milliseconds: 1500));
      expect(h.server.channels, hasLength(2));
      await h.elapse(const Duration(milliseconds: 1000));
      expect(h.server.channels, hasLength(3));
      await h.dispose();
    });

    testWidgets('4409 (auf diesem Gerät neu verbunden): nicht neu verbinden', (tester) async {
      final h = await ConnectHarness.start(tester);
      await h.welcome();
      h.channel.serverClose(4409, 'Auf diesem Gerät neu verbunden');
      await h.settle();
      await h.elapse(const Duration(minutes: 2));
      expect(h.server.channels, hasLength(1));
      await h.dispose();
    });

    testWidgets('4001: Token erneuern und sofort neu verbinden (mit neuem Token)', (tester) async {
      final h = await ConnectHarness.start(tester);
      await h.welcome();
      h.channel.serverClose(4001, 'Anmeldung erneuern');
      await h.settle();
      expect(h.api.refreshes, 1);
      expect(h.server.channels, hasLength(2), reason: 'ohne Backoff');
      expect(h.channel.headers['Authorization'], 'Bearer acc1');
      await h.dispose();
    });

    testWidgets('4401: einmal Token erneuern und neu verbinden, beim zweiten Mal Backoff', (tester) async {
      final h = await ConnectHarness.start(tester);
      h.channel.serverClose(4401, 'Nicht angemeldet');
      await h.settle();
      expect(h.api.refreshes, 1);
      expect(h.server.channels, hasLength(2));
      h.channel.serverClose(4401, 'Nicht angemeldet');
      await h.settle();
      expect(h.api.refreshes, 1);
      expect(h.server.channels, hasLength(2), reason: 'jetzt mit Wartezeit');
      await h.elapse(const Duration(seconds: 2));
      expect(h.server.channels, hasLength(3));
      await h.dispose();
    });

    testWidgets('4429: Backoff ab 30 s', (tester) async {
      final h = await ConnectHarness.start(tester);
      h.channel.serverClose(4429, 'Zu viele Geräte verbunden');
      await h.settle();
      await h.elapse(const Duration(seconds: 23));
      expect(h.server.channels, hasLength(1));
      await h.elapse(const Duration(seconds: 14));
      expect(h.server.channels, hasLength(2));
      await h.dispose();
    });

    testWidgets('Zurück in die App: Wartezeit zurück, sofort verbinden', (tester) async {
      final h = await ConnectHarness.start(tester);
      for (var i = 0; i < 4; i++) {
        h.channel.serverClose(1006);
        await h.settle();
        await h.elapse(const Duration(seconds: 13));
      }
      final before = h.server.channels.length;
      h.channel.serverClose(1006);
      await h.settle();
      h.setLifecycle(AppLifecycleState.inactive);
      h.setLifecycle(AppLifecycleState.resumed);
      await h.settle();
      expect(h.server.channels.length, before + 1);
      await h.dispose();
    });

    testWidgets('Token-Erneuerung während offener Verbindung geht in-band als auth', (tester) async {
      final h = await ConnectHarness.start(tester);
      await h.welcome();
      await h.api.refresh();
      await h.settle();
      expect(h.channel.lastOfType('auth'), {'type': 'auth', 'token': 'acc1'});
      expect(h.server.channels, hasLength(1), reason: 'keine neue Verbindung nötig');
      await h.dispose();
    });

    testWidgets('Herzschlag: ping alle 25 s', (tester) async {
      final h = await ConnectHarness.start(tester);
      await h.welcome();
      await h.elapse(const Duration(seconds: 26));
      expect(h.channel.ofType('ping'), hasLength(1));
      await h.elapse(const Duration(seconds: 25));
      expect(h.channel.ofType('ping'), hasLength(2));
      await h.dispose();
    });
  });

  group('Hintergrund und Akku', () {
    testWidgets('im Hintergrund ohne Wiedergabe: nach 10 s getrennt, beim Öffnen wieder da', (tester) async {
      final h = await ConnectHarness.start(tester);
      await h.welcome();
      h.setLifecycle(AppLifecycleState.paused);
      await h.elapse(const Duration(seconds: 9));
      expect(h.channel.isOpen, isTrue, reason: 'Gnadenfrist');
      await h.elapse(const Duration(seconds: 2));
      expect(h.channel.closedByApp, 1000);
      expect(h.state.connected, isFalse);
      await h.elapse(const Duration(minutes: 1));
      expect(h.server.channels, hasLength(1), reason: 'im Hintergrund nicht neu verbinden');
      h.setLifecycle(AppLifecycleState.resumed);
      await h.settle();
      expect(h.server.channels, hasLength(2));
      await h.dispose();
    });

    testWidgets('im Hintergrund mit Wiedergabe: Verbindung bleibt', (tester) async {
      final h = await ConnectHarness.start(tester);
      await h.welcome();
      h.setLocalPlaying(true);
      await h.settle();
      h.setLifecycle(AppLifecycleState.paused);
      await h.elapse(const Duration(seconds: 30));
      expect(h.channel.isOpen, isTrue);
      // Pause im Hintergrund: Gnadenfrist, dann weg
      h.setLocalPlaying(false);
      await h.elapse(const Duration(seconds: 11));
      expect(h.channel.closedByApp, 1000);
      // Wiedergabe startet (z. B. Kopfhörer-Taste): sofort wieder verbinden
      h.setLocalPlaying(true);
      await h.settle();
      expect(h.server.channels, hasLength(2));
      await h.dispose();
    });

    testWidgets('kurz im Hintergrund (unter 10 s): Verbindung bleibt', (tester) async {
      final h = await ConnectHarness.start(tester);
      await h.welcome();
      h.setLifecycle(AppLifecycleState.paused);
      await h.elapse(const Duration(seconds: 5));
      h.setLifecycle(AppLifecycleState.resumed);
      await h.elapse(const Duration(seconds: 20));
      expect(h.channel.isOpen, isTrue);
      expect(h.server.channels, hasLength(1));
      await h.dispose();
    });
  });

  group('Premium', () {
    testWidgets('allowed=false: kein Remote-Modus, access schaltet frei', (tester) async {
      final h = await ConnectHarness.start(tester);
      await h.welcome(allowed: false, active: 2, state: remoteStateJson());
      expect(h.state.allowed, isFalse);
      expect(h.state.isRemote, isFalse);
      expect(h.container.read(currentTrackProvider), isNull, reason: 'lokal läuft nichts');
      h.channel.receive({'type': 'access', 'allowed': true});
      h.channel.receive({'type': 'state', 'device_id': 2, 'state': remoteStateJson()});
      await h.settle();
      expect(h.state.isRemote, isTrue);
      h.channel.receive({'type': 'access', 'allowed': false});
      await h.settle();
      expect(h.state.isRemote, isFalse);
      await h.dispose();
    });
  });

  group('eigener Zustand', () {
    testWidgets('spielt dieses Gerät: state entprellt, alle 15 s erneut, nie pro Positions-Tick', (tester) async {
      final h = await ConnectHarness.start(tester);
      await h.welcome();
      h.setLocalPlaying(true);
      await h.settle();
      expect(h.channel.ofType('state'), isEmpty, reason: 'erst nach 300 ms');
      await h.elapse(const Duration(milliseconds: 350));
      expect(h.channel.ofType('state'), hasLength(1));
      // Positions-Ticks (gleicher Stand) lösen nichts aus
      for (var i = 0; i < 5; i++) {
        h.setLocalPlaying(true);
        await h.elapse(const Duration(seconds: 1));
      }
      expect(h.channel.ofType('state'), hasLength(1));
      await h.elapse(const Duration(seconds: 11));
      expect(h.channel.ofType('state'), hasLength(2), reason: 'Herzschlag nach 15 s');
      final seqs = [for (final s in h.channel.ofType('state')) (s['state'] as Map)['seq'] as int];
      expect(seqs[1], greaterThan(seqs[0]), reason: 'streng steigend');
      await h.dispose();
    });

    testWidgets('pausiert und nicht aktiv: einmal melden, dann nicht mehr', (tester) async {
      final h = await ConnectHarness.start(tester);
      await h.welcome();
      h.setLocalPlaying(true);
      await h.elapse(const Duration(milliseconds: 350));
      h.setLocalPlaying(false);
      await h.elapse(const Duration(milliseconds: 350));
      final count = h.channel.ofType('state').length;
      expect(count, 2);
      await h.elapse(const Duration(seconds: 40));
      expect(h.channel.ofType('state').length, count);
      await h.dispose();
    });

    testWidgets('nach welcome: spielt es hier, sofort melden', (tester) async {
      final h = await ConnectHarness.start(tester);
      h.setLocalPlaying(true);
      await h.settle();
      await h.welcome();
      expect(h.channel.ofType('state'), hasLength(1));
      await h.dispose();
    });

    test('Stand im Protokoll-Format: Warteschlange, Index, Zufallsreihenfolge, Kontext', () async {
      final h = await ConnectHarness.start(null);
      unawaited(h.container
          .read(playerProvider)
          .playLocally(sampleTracks(4), index: 2, context: const PlayContext('album', id: 7, title: 'Oper'), wait: false));
      await h.waitFor(() => h.handler.player.playing && h.handler.player.currentIndex == 2, 'spielt');
      final snapshot = localSnapshot(h.handler, canVolume: false);
      expect(snapshot['playing'], isTrue);
      expect(snapshot['queue_ids'], [1, 2, 3, 4]);
      expect(snapshot['index'], 2);
      expect(snapshot['shuffle'], isFalse);
      expect(snapshot.containsKey('shuffle_order'), isFalse);
      expect(snapshot['volume'], isNull);
      expect(snapshot['context'], {'type': 'album', 'id': '7', 'name': 'Oper'});
      await h.handler.setShuffleMode(AudioServiceShuffleMode.all);
      final shuffled = localSnapshot(h.handler, canVolume: true);
      expect((shuffled['shuffle_order'] as List).toSet(), {0, 1, 2, 3});
      expect(shuffled['volume'], 1.0);
      await h.dispose();
      await h.handler.player.dispose();
    });

    test('mehr als 1000 Titel: um den aktuellen herum abgeschnitten', () async {
      final h = await ConnectHarness.start(null);
      final many = [for (var i = 1; i <= 1500; i++) Track.fromJson(trackJson(i))];
      unawaited(h.container.read(playerProvider).playLocally(many, index: 1200, wait: false));
      await h.waitFor(() => h.handler.player.currentIndex == 1200, 'geladen');
      final snapshot = localSnapshot(h.handler, canVolume: false);
      final ids = snapshot['queue_ids'] as List;
      expect(ids, hasLength(1000));
      expect(ids[snapshot['index'] as int], 1201);
      await h.dispose();
      await h.handler.player.dispose();
    });
  });

  test('ApiClient: Link der Geräte-Verbindung ohne Token, http → ws', () {
    final api = FakeApi();
    expect(api.connectWebSocketUri().toString(), 'wss://musik.test/api/connect/ws');
    final plain = ApiClient(baseUrl: 'http://nas:8095', tokens: fakeTokens, onTokens: (_) {}, onSessionExpired: () {});
    expect(plain.connectWebSocketUri().toString(), 'ws://nas:8095/api/connect/ws');
  });
}
