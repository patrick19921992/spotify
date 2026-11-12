// Oberfläche von „Wiedergabe auf anderen Geräten“: Geräte-Knopf, Geräte-Liste, „Spielt auf …“, Fernsteuern.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfify/data/models.dart';
import 'package:selfify/player/player.dart';
import 'package:selfify/state/connect.dart';
import 'package:selfify/state/offline_access.dart' show clockProvider;
import 'package:selfify/ui/screens/devices_screen.dart';
import 'package:selfify/ui/screens/player_screen.dart';
import 'package:selfify/ui/screens/premium_screen.dart';
import 'package:selfify/ui/screens/queue_screen.dart';
import 'package:selfify/ui/widgets/connect_sheet.dart';
import 'package:selfify/ui/widgets/mini_player.dart';

import 'support/connect_harness.dart' show phoneInfo, remoteStateJson;
import 'support/fake_audio.dart';
import 'support/fake_connect.dart';
import 'support/fakes.dart';

void main() {
  setUp(useFakeAudioPlatform);

  Future<(FakeApi, FakeConnectServer)> pump(
    WidgetTester tester,
    Widget screen, {
    List<String> features = const ['connect'],
    AppConfig config = const AppConfig(),
    bool admin = true,
    DateTime Function()? clock,
  }) async {
    final server = FakeConnectServer();
    final api = FakeApi(admin: admin)..serverFeatures = features;
    await pumpScreen(
      tester,
      screen,
      api: api,
      config: config,
      overrides: [
        connectChannelFactoryProvider.overrideWithValue(server.factory),
        connectDeviceInfoProvider.overrideWithValue(phoneInfo),
        if (clock != null) clockProvider.overrideWithValue(clock),
      ],
    );
    return (api, server);
  }

  /// Abbauen – Zeitgeber (Herzschlag, Positionsanzeige) müssen am Testende weg sein.
  Future<void> teardown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> receive(WidgetTester tester, FakeConnectChannel channel, Map<String, Object?> message) async {
    channel.receive(message);
    await tester.pump();
    await tester.pump();
  }

  Future<void> remoteMode(WidgetTester tester, FakeConnectServer server) async {
    server.welcome(server.last);
    await tester.pump();
    await receive(tester, server.last,
        {'type': 'devices', 'devices': FakeConnectServer.devicesJson(active: 2), 'active_device_id': 2});
    await receive(tester, server.last, {'type': 'state', 'device_id': 2, 'state': remoteStateJson()});
  }

  const button = Scaffold(body: Center(child: ConnectButton()));

  testWidgets('alter Server ohne features: kein Geräte-Knopf, keine Verbindung', (tester) async {
    final (_, server) = await pump(tester, button, features: const []);
    expect(find.byTooltip('Geräte'), findsNothing);
    expect(server.channels, isEmpty);
    await teardown(tester);
  });

  testWidgets('Geräte-Liste: verbindet sich, dann leer mit Hinweis', (tester) async {
    final (_, server) = await pump(tester, button);
    expect(find.byTooltip('Geräte'), findsOneWidget);
    await tester.tap(find.byTooltip('Geräte'));
    await tester.pumpAndSettle();
    expect(find.text('Geräte'), findsOneWidget);
    expect(find.text('Verbindung zu deinen Geräten wird hergestellt …'), findsOneWidget);
    server.welcome(server.last, others: const {});
    await tester.pump();
    await tester.pump();
    expect(find.text('Aktuelles Gerät'), findsOneWidget);
    expect(find.text('Android · Pixel'), findsOneWidget);
    expect(find.text('Dieses Gerät'), findsOneWidget);
    expect(find.text('Weitere Geräte'), findsOneWidget);
    expect(
      find.text('Keine weiteren Geräte gefunden. Öffne Selfify auf deinem PC, Handy oder Tablet und melde dich mit '
          'demselben Konto an.'),
      findsOneWidget,
    );
    expect(find.text('Handys und Tablets erscheinen, solange die App geöffnet ist oder Musik spielt.'), findsOneWidget);
    expectNoErrors(tester);
    await teardown(tester);
  });

  testWidgets('Geräte-Liste: auf den PC übertragen, mit Ladekreis und Meldung', (tester) async {
    final (_, server) = await pump(tester, button);
    server.welcome(server.last);
    await tester.pump();
    await tester.tap(find.byTooltip('Geräte'));
    await tester.pumpAndSettle();
    expect(find.text('Windows · BÜRO-PC'), findsOneWidget);
    expect(find.byIcon(Icons.computer_rounded), findsOneWidget);
    expect(find.byIcon(Icons.smartphone_rounded), findsOneWidget);
    await tester.tap(find.text('Windows · BÜRO-PC'));
    await tester.pump();
    expect(find.text('Wird übertragen …'), findsOneWidget);
    final cmd = server.last.lastOfType('cmd')!;
    expect(cmd['action'], 'transfer');
    expect(cmd['target'], 2);
    await receive(tester, server.last, {'type': 'result', 'id': cmd['id'], 'ok': true});
    await tester.pumpAndSettle();
    expect(find.text('Spielt jetzt auf Windows · BÜRO-PC'), findsOneWidget);
    expect(find.text('Weitere Geräte'), findsNothing, reason: 'Liste geschlossen');
    await teardown(tester);
  });

  testWidgets('Geräte-Liste: Fehler beim Übertragen zeigt den Text', (tester) async {
    final (_, server) = await pump(tester, button);
    server.welcome(server.last);
    await tester.pump();
    await tester.tap(find.byTooltip('Geräte'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Windows · BÜRO-PC'));
    await tester.pump();
    final cmd = server.last.lastOfType('cmd')!;
    await receive(tester, server.last, {'type': 'result', 'id': cmd['id'], 'ok': false, 'code': 'nothing_playing'});
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Gerade läuft nichts, das übertragen werden kann.'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('Gerät ohne Wiedergabe: ausgegraut mit Hinweis', (tester) async {
    final (_, server) = await pump(tester, button);
    server.last.receive({
      'type': 'welcome',
      'device_id': 1,
      'allowed': true,
      'devices': FakeConnectServer.devicesJson(otherCanPlay: false),
      'active_device_id': null,
    });
    await tester.pump();
    await tester.tap(find.byTooltip('Geräte'));
    await tester.pumpAndSettle();
    expect(find.text('Kann gerade nicht abspielen'), findsOneWidget);
    await tester.tap(find.text('Windows · BÜRO-PC'));
    await tester.pump();
    expect(server.last.ofType('cmd'), isEmpty);
    await teardown(tester);
  });

  testWidgets('Premium gesperrt: Hinweis, Knopf „Premium ansehen“, Liste nicht antippbar', (tester) async {
    final (_, server) = await pump(tester, button, config: const AppConfig(premiumEnabled: true), admin: false);
    server.welcome(server.last, allowed: false);
    await tester.pump();
    await tester.tap(find.byTooltip('Geräte'));
    await tester.pumpAndSettle();
    expect(find.text('Auf anderen Geräten abspielen gibt es nur mit Premium.'), findsOneWidget);
    expect(find.text('Premium ansehen'), findsOneWidget);
    await tester.tap(find.text('Windows · BÜRO-PC'));
    await tester.pump();
    expect(server.last.ofType('cmd'), isEmpty);
    await teardown(tester);
  });

  testWidgets('Umbenennen: leerer Name wird abgelehnt, sonst geht er an den Server', (tester) async {
    final (api, server) = await pump(tester, button);
    server.welcome(server.last);
    await tester.pump();
    await tester.tap(find.byTooltip('Geräte'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Umbenennen'));
    await tester.pumpAndSettle();
    expect(find.text('Gerät umbenennen'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.text('Speichern'));
    await tester.pump();
    expect(find.text('Bitte gib einen Namen ein.'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '  Küche ');
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('renameSession:1:Küche'));
    await teardown(tester);
  });

  testWidgets('Remote-Modus: Mini-Player zeigt den Titel des PCs und „Spielt auf …“', (tester) async {
    final (_, server) = await pump(tester, const Scaffold(body: SizedBox.expand(), bottomNavigationBar: MiniPlayer()));
    expect(find.byType(MiniPlayer), findsOneWidget);
    expect(find.text('Bohemian Rhapsody 1'), findsNothing);
    await remoteMode(tester, server);
    expect(find.text('Bohemian Rhapsody 1'), findsOneWidget);
    expect(find.text('Spielt auf Windows · BÜRO-PC'), findsOneWidget);
    final devices = tester.widget<Icon>(find.byIcon(Icons.devices_rounded));
    expect(devices.color, isNot(Colors.white), reason: 'Akzentfarbe im Remote-Modus');
    // Pause im Mini-Player geht als Befehl an den PC
    await tester.tap(find.byIcon(Icons.pause_rounded));
    await tester.pump();
    expect(server.last.lastOfType('cmd')!['action'], 'pause');
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget, reason: 'sofort umgeschaltet');
    expectNoErrors(tester);
    await teardown(tester);
  });

  testWidgets('Remote-Modus: PlayerController.play schickt „play“ an den PC statt hier zu spielen', (tester) async {
    final handler = SelfifyAudioHandler();
    final server = FakeConnectServer();
    final api = FakeApi()..serverFeatures = const ['connect'];
    await pumpScreen(
      tester,
      const Scaffold(body: SizedBox.expand(), bottomNavigationBar: MiniPlayer()),
      api: api,
      handler: handler,
      overrides: [
        connectChannelFactoryProvider.overrideWithValue(server.factory),
        connectDeviceInfoProvider.overrideWithValue(phoneInfo),
      ],
    );
    await remoteMode(tester, server);
    final element = tester.element(find.byType(MiniPlayer));
    final player = ProviderScope.containerOf(element).read(playerProvider);
    final played = player.play(sampleTracks(3), index: 2, context: const PlayContext('playlist', id: 5, title: 'Roadtrip'));
    await tester.pump();
    final cmd = server.last.lastOfType('cmd')!;
    expect(cmd['action'], 'play');
    expect(cmd['target'], 2);
    expect(cmd['args'], {
      'track_ids': [1, 2, 3],
      'index': 2,
      'shuffle': false,
      'context': {'type': 'playlist', 'id': '5', 'name': 'Roadtrip'},
    });
    await receive(tester, server.last, {'type': 'result', 'id': cmd['id'], 'ok': true});
    await played;
    expect(handler.tracks, isEmpty, reason: 'hier spielt nichts');
    // Auch Warteschlange und Weiter gehen an den PC
    player.addToQueue(sampleTracks(1)).ignore();
    await tester.pump();
    expect(server.last.lastOfType('cmd')!['action'], 'add_queue');
    player.next().ignore();
    await tester.pump();
    expect(server.last.lastOfType('cmd')!['action'], 'next');
    await teardown(tester);
  });

  testWidgets('Remote-Modus im Vollbild-Player: ohne Geschwindigkeit und Schlaf-Timer, mit „Spielt auf …“',
      (tester) async {
    var now = DateTime(2026, 11, 12, 10);
    final (_, server) = await pump(tester, button, clock: () => now);
    await remoteMode(tester, server);
    // Öffnen, wenn der Titel des PCs schon da ist (ohne Titel schließt sich der Player von selbst)
    Navigator.of(tester.element(find.byType(ConnectButton)))
        .push(MaterialPageRoute<void>(builder: (_) => const PlayerScreen()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Bohemian Rhapsody 1'), findsOneWidget);
    expect(find.text('Spielt auf Windows · BÜRO-PC'), findsOneWidget);
    expect(find.byTooltip('Wiedergabegeschwindigkeit'), findsNothing);
    expect(find.byTooltip('Schlaf-Timer'), findsNothing);
    expect(find.byTooltip('Geräte'), findsOneWidget);
    expect(find.text('A Night at the Opera'), findsWidgets, reason: '„Wird gespielt von“ des PCs');
    // Die Zeit läuft lokal weiter (1:00 → 1:02)
    expect(find.text('1:00'), findsOneWidget);
    now = now.add(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('1:02'), findsOneWidget);
    expectNoErrors(tester);
    await teardown(tester);
  });

  testWidgets('Remote-Modus: Warteschlange des PCs – springen und entfernen gehen als Befehl', (tester) async {
    final (_, server) = await pump(tester, const QueueScreen());
    await remoteMode(tester, server);
    expect(find.text('Wird gerade gespielt'), findsOneWidget);
    expect(find.text('Bohemian Rhapsody 1'), findsOneWidget);
    expect(find.text('Bohemian Rhapsody 2'), findsOneWidget);
    expect(find.text('Bohemian Rhapsody 3'), findsOneWidget);
    expect(find.text('Als Nächstes aus: A Night at the Opera'), findsOneWidget);
    await tester.tap(find.text('Bohemian Rhapsody 3'));
    await tester.pump();
    expect(server.last.lastOfType('cmd')!['action'], 'skip_to');
    expect(server.last.lastOfType('cmd')!['args'], {'index': 2, 'track_id': 3}, reason: 'mit erwartetem Titel');
    await tester.tap(find.byTooltip('Aus der Warteschlange entfernen').first);
    await tester.pump();
    expect(server.last.lastOfType('cmd')!['action'], 'remove_queue');
    expect(server.last.lastOfType('cmd')!['args'], {'index': 1, 'track_id': 2});
    expect(find.text('Bohemian Rhapsody 2'), findsNothing, reason: 'sofort weg, bis der neue Stand kommt');
    expectNoErrors(tester);
    await teardown(tester);
  });

  testWidgets('Sitzungsverwaltung: „Umbenennen“ nur, wenn der Server die Geräte-Funktion hat', (tester) async {
    await pump(tester, const DevicesScreen(), features: const []);
    expect(find.byTooltip('Mehr'), findsNothing);
    await teardown(tester);

    final (api, _) = await pump(tester, const DevicesScreen());
    expect(find.byTooltip('Mehr'), findsNWidgets(2));
    await tester.tap(find.byTooltip('Mehr').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Umbenennen'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Papas Handy');
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('renameSession:1:Papas Handy'));
    await teardown(tester);
  });

  test('Premium-Leistung „Auf anderen Geräten abspielen“', () {
    expect(PremiumFeature.all, contains('remote'));
    expect(PremiumFeature.all.indexOf('remote'), PremiumFeature.all.indexOf('badge') - 1);
    expect(PremiumFeature.labels['remote'], 'Auf anderen Geräten abspielen');
    expect(premiumBenefitsFor(const AppConfig(premiumOnly: ['remote'])),
        contains('Auf anderen Geräten abspielen und fernsteuern'));
    expect(premiumBenefitsFor(const AppConfig()), isNot(contains('Auf anderen Geräten abspielen und fernsteuern')));
  });

  test('ServerInfo: features tolerant gelesen', () {
    expect(ServerInfo.fromJson({'name': 'S', 'version': '1', 'api_version': 1}).supportsConnect, isFalse);
    expect(ServerInfo.fromJson({'api_version': 1, 'features': ['connect', 'neu']}).supportsConnect, isTrue);
    expect(ServerInfo.fromJson({'api_version': 1, 'features': 'connect'}).features, isEmpty);
  });
}
