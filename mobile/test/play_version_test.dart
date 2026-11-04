// Play-Version: Flavor, Konfiguration vom Server, Premium, Song-Wünsche, Fehler melden, Konto löschen, Werbe-Regeln,
// Wartungshinweis, Update-Hinweis – und dass die GitHub-Version unverändert bleibt.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:selfify/ads/ad_banner.dart';
import 'package:selfify/core/client_info.dart';
import 'package:selfify/core/error_log.dart';
import 'package:selfify/core/flavor.dart';
import 'package:selfify/core/links.dart';
import 'package:selfify/data/api.dart';
import 'package:selfify/data/models.dart';
import 'package:selfify/state/app_config.dart';
import 'package:selfify/state/auth.dart';
import 'package:selfify/state/connectivity.dart';
import 'package:selfify/ui/screens/admin_screen.dart';
import 'package:selfify/ui/screens/login_screen.dart';
import 'package:selfify/ui/screens/premium_screen.dart';
import 'package:selfify/ui/screens/search_screen.dart';
import 'package:selfify/ui/screens/settings_screen.dart';
import 'package:selfify/ui/screens/wishes_screen.dart';
import 'package:selfify/ui/shell.dart';
import 'package:selfify/ui/widgets/play_notices.dart';

import 'support/fakes.dart';

AppConfig config({
  bool ads = false,
  bool premium = true,
  bool wishlist = true,
  String maintenance = '',
  UpdateInfo update = const UpdateInfo(),
}) =>
    AppConfig(adsEnabled: ads, premiumEnabled: premium, wishlistEnabled: wishlist, maintenanceMessage: maintenance, update: update);

/// Ersatz fürs Öffnen von Links: merkt sich die Adressen und meldet „geklappt“.
Future<bool> Function(String) recordLinks(List<String> sink) => (url) async {
      sink.add(url);
      return true;
    };

/// Container des laufenden Tests (für Provider-Abfragen).
ProviderContainer containerOf(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));

void main() {
  setUpAll(() => initializeDateFormatting('de_DE'));

  group('Flavor und Hilfen', () {
    tearDown(() => channelOverride = null);

    test('ohne Angabe ist es die GitHub-Version mit allen Funktionen', () {
      expect(appChannel, AppChannel.full);
      expect(youtubeFeaturesEnabled, isTrue);
      expect(selfUpdateEnabled, isTrue);
    });

    test('Play-Version: keine YouTube-Funktionen, kein Selbst-Update', () {
      channelOverride = AppChannel.play;
      expect(isPlayChannel, isTrue);
      expect(youtubeFeaturesEnabled, isFalse);
      expect(selfUpdateEnabled, isFalse);
      expect(appChannel.id, 'play');
    });

    test('Client-Header passt zum Format, das der Server liest', () {
      const client = ClientInfo(platform: 'android', channel: 'play', version: '1.0.0', build: 54);
      expect(client.header, 'platform=android; channel=play; version=1.0.0; build=54');
      // dieselben Regeln wie server/app/services/clients.py
      expect(RegExp(r'^platform=[a-z]{2,20}; channel=[a-z]{2,10}; version=[0-9A-Za-z.+-]{1,32}; build=\d{1,9}$').hasMatch(client.header), isTrue);
    });

    test('Premium-Code wird beim Tippen zu XXXX-XXXX-XXXX', () {
      expect(formatPremiumCodeInput('abcd efgh-jkmn'), 'ABCD-EFGH-JKMN');
      expect(formatPremiumCodeInput('abcdefghjkmnxyz'), 'ABCD-EFGH-JKMN'); // mehr als 12 Zeichen: abgeschnitten
      expect(formatPremiumCodeInput('ab'), 'AB');
      expect(formatPremiumCodeInput('  --  '), '');
    });

    test('Fehlerprotokoll: Zugangsdaten werden unkenntlich gemacht, nur die letzten Einträge bleiben', () {
      ErrorLog.clear();
      ErrorLog.add(
        Exception('GET https://musik.example.org/api/tracks/1/stream?t=SECRETMEDIA&quality=original fehlgeschlagen'),
        null,
      );
      ErrorLog.add('Authorization: Bearer abc.def-ghi fehlgeschlagen, {"password": "geheim123", "x": 1}', null);
      final text = ErrorLog.dump();
      expect(text, contains('t=***'));
      expect(text, contains('quality=original'));
      expect(text, isNot(contains('SECRETMEDIA')));
      expect(text, contains('Bearer ***'));
      expect(text, isNot(contains('abc.def-ghi')));
      expect(text, isNot(contains('geheim123')));
      for (var i = 0; i < ErrorLog.maxEntries + 10; i++) {
        ErrorLog.add('Fehler $i', null);
      }
      expect(ErrorLog.dump(), contains('Fehler ${ErrorLog.maxEntries + 9}'));
      expect(ErrorLog.dump(), isNot(contains('Fehler 0\n')));
      expect(ErrorLog.dump().length, lessThanOrEqualTo(ErrorLog.maxChars));
      ErrorLog.clear();
      expect(ErrorLog.isEmpty, isTrue);
    });
  });

  group('Server-Einstellungen lesen', () {
    test('alles Fehlende bekommt sichere Standardwerte (keine Werbung, kein Hinweis, kein Update)', () {
      final c = AppConfig.fromJson({});
      expect(c.adsEnabled, isFalse);
      expect(c.premiumEnabled, isTrue);
      expect(c.wishlistEnabled, isTrue);
      expect(c.maintenanceMessage, '');
      expect(c.update.level, UpdateLevel.none);
      expect(c.privacyUrl, '');
    });

    test('Antwort des Servers wird gelesen, unbekannte Update-Stufe ist „keine“', () {
      final c = AppConfig.fromJson({
        'ads_enabled': true,
        'premium_enabled': false,
        'wishlist_enabled': false,
        'maintenance_message': 'Heute Abend Wartung',
        'update': {'level': 'required', 'latest_build': 60, 'min_build': 55, 'store_url': 'https://play.google.com/store/apps/details?id=x', 'message': 'Bitte aktualisieren'},
        'privacy_url': 'https://musik.example.org/datenschutz',
        'deletion_url': 'https://musik.example.org/konto-loeschen',
      });
      expect(c.adsEnabled, isTrue);
      expect(c.premiumEnabled, isFalse);
      expect(c.wishlistEnabled, isFalse);
      expect(c.maintenanceMessage, 'Heute Abend Wartung');
      expect(c.update.level, UpdateLevel.required);
      expect(c.update.latestBuild, 60);
      expect(c.update.storeUrl, startsWith('https://play.google.com/'));
      expect(c.privacyUrl, endsWith('/datenschutz'));
      expect(UpdateInfo.fromJson({'level': 'irgendwas'}).level, UpdateLevel.none);
      expect(UpdateInfo.fromJson({'level': 'available'}).level, UpdateLevel.available);
    });

    test('Wunsch: Stand und Löschen', () {
      SongWish wish(String status) => SongWish.fromJson({'id': 1, 'title': 'Du hast', 'artist': 'Rammstein', 'status': status, 'created_at': now});
      expect(wish('open').isOpen, isTrue);
      expect(wish('open').canRemove, isTrue);
      expect(wish('accepted').canRemove, isFalse); // wird gerade erfüllt – der Server verweigert das Löschen
      expect(wish('done').canRemove, isTrue);
      expect(wish('declined').isDeclined, isTrue);
    });

    test('Premium-Stand', () {
      final p = PremiumStatus.fromJson({'active': true, 'unlimited': false, 'until': '2026-12-04T11:30:11.080830Z'});
      expect(p.active, isTrue);
      expect(p.until!.year, 2026);
      expect(premiumLabel(p), 'Premium bis 4. Dez. 2026');
      expect(premiumLabel(const PremiumStatus(active: true, unlimited: true)), 'Premium – unbegrenzt');
      expect(premiumLabel(const PremiumStatus()), 'Kein Premium');
    });
  });

  group('Werbung: wann sie gezeigt werden darf', () {
    Future<ProviderContainer> start(WidgetTester tester,
        {AppChannel? channel, AppConfig? cfg, PremiumStatus premium = const PremiumStatus(), bool offline = false}) async {
      final api = FakeApi(admin: false)..premiumStatus = premium;
      await pumpScreen(tester, const Scaffold(body: SizedBox()), api: api, channel: channel, config: cfg, offline: offline, admin: false);
      final container = containerOf(tester);
      // In der App lesen Bildschirme diese Werte von Anfang an – hier abonnieren und laden lassen
      container.listen(appConfigProvider, (_, _) {});
      container.listen(premiumProvider, (_, _) {});
      container.listen(connectivityProvider, (_, _) {});
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      return container;
    }

    testWidgets('Play, vom Admin eingeschaltet, kein Premium: ja', (tester) async {
      final c = await start(tester, channel: AppChannel.play, cfg: config(ads: true));
      expect(c.read(adsVisibleProvider), isTrue);
    });

    testWidgets('mit aktivem Premium: nein', (tester) async {
      final c = await start(tester,
          channel: AppChannel.play, cfg: config(ads: true), premium: const PremiumStatus(active: true, unlimited: true));
      expect(c.read(adsVisibleProvider), isFalse);
    });

    testWidgets('Admin hat Werbung nicht eingeschaltet: nein', (tester) async {
      final c = await start(tester, channel: AppChannel.play, cfg: config(ads: false));
      expect(c.read(adsVisibleProvider), isFalse);
    });

    testWidgets('GitHub-Version: nie – auch wenn der Server Werbung meldet', (tester) async {
      final c = await start(tester, cfg: config(ads: true));
      expect(c.read(adsVisibleProvider), isFalse);
    });

    testWidgets('offline: nein', (tester) async {
      final c = await start(tester, channel: AppChannel.play, cfg: config(ads: true), offline: true);
      expect(c.read(adsVisibleProvider), isFalse);
    });

    testWidgets('solange der Premium-Stand unbekannt ist, gibt es keine Werbung (Premium-Nutzer sehen nie einen Banner)', (tester) async {
      final api = FakeApi(admin: false);
      await pumpScreen(tester, const Scaffold(body: SizedBox()), api: api, channel: AppChannel.play, config: config(ads: true), admin: false);
      final c = containerOf(tester);
      c.listen(appConfigProvider, (_, _) {});
      await tester.pump(const Duration(milliseconds: 50));
      // Premium-Abfrage hat noch nicht geantwortet → unbekannt → keine Werbung
      expect(c.read(adsVisibleProvider), isFalse);
      expect(c.read(premiumProvider).hasValue, isFalse);
    });

    testWidgets('Banner-Widget zeigt ohne Erlaubnis nichts und fasst das Werbe-SDK nicht an', (tester) async {
      await pumpScreen(tester, const Scaffold(body: Column(children: [Text('Inhalt'), AdBanner()])), admin: false);
      expect(find.text('Inhalt'), findsOneWidget);
      expect(find.byType(AdBanner), findsOneWidget);
      expect(find.byType(SizedBox), findsWidgets);
      expectNoErrors(tester);
    });
  });

  group('Einstellungen', () {
    testWidgets('Play: Premium, Wünsche, Fehler melden, Datenschutz, Konto löschen – ohne YouTube-Downloads', (tester) async {
      await pumpScreen(tester, const SettingsScreen(), channel: AppChannel.play, config: config(), admin: false, size: const Size(400, 3000));
      expect(find.text('Premium & Wünsche'), findsOneWidget);
      expect(find.text('Premium'), findsOneWidget);
      expect(find.text('Meine Wünsche'), findsOneWidget);
      expect(find.text('Fehler melden'), findsOneWidget);
      expect(find.text('Datenschutzerklärung'), findsOneWidget);
      expect(find.text('Konto löschen'), findsOneWidget);
      expect(find.text('YouTube-Downloads'), findsNothing);
      expect(find.text('Meine Downloads'), findsNothing);
      expect(find.text('Nach Updates suchen'), findsNothing); // Updates kommen über Google Play
      expectNoErrors(tester);
    });

    testWidgets('Play: Admin hat Premium und Wünsche abgeschaltet → beides verschwindet', (tester) async {
      await pumpScreen(tester, const SettingsScreen(),
          channel: AppChannel.play, config: config(premium: false, wishlist: false), admin: false, size: const Size(400, 3000));
      expect(find.text('Premium & Wünsche'), findsNothing);
      expect(find.text('Meine Wünsche'), findsNothing);
      expect(find.text('Fehler melden'), findsOneWidget);
    });

    testWidgets('GitHub-Version: wie bisher mit YouTube-Downloads; Premium-Code einlösen geht auch hier, Wünsche nicht', (tester) async {
      await pumpScreen(tester, const SettingsScreen(), config: config(), admin: false, size: const Size(400, 3000));
      expect(find.text('YouTube-Downloads'), findsOneWidget);
      expect(find.text('Meine Downloads'), findsOneWidget);
      expect(find.text('Premium & Wünsche'), findsNothing);
      expect(find.text('Premium'), findsWidgets); // Abschnitt und Eintrag
      expect(find.text('Meine Wünsche'), findsNothing);
      expect(find.text('Fehler melden'), findsOneWidget);
      expect(find.text('Konto löschen'), findsOneWidget);
    });

    testWidgets('Datenschutz öffnet die Adresse aus den Server-Einstellungen', (tester) async {
      final opened = <String>[];
      await pumpScreen(tester, const SettingsScreen(),
          channel: AppChannel.play,
          config: const AppConfig(privacyUrl: 'https://musik.example.org/datenschutz'),
          admin: false,
          size: const Size(400, 3000),
          overrides: [linkOpenerProvider.overrideWithValue(recordLinks(opened))]);
      await tester.tap(find.text('Datenschutzerklärung'));
      await tester.pump();
      expect(opened, ['https://musik.example.org/datenschutz']);
    });

    testWidgets('… sonst die Seite des eigenen Servers', (tester) async {
      final opened = <String>[];
      await pumpScreen(tester, const SettingsScreen(),
          channel: AppChannel.play,
          admin: false,
          size: const Size(400, 3000),
          overrides: [linkOpenerProvider.overrideWithValue(recordLinks(opened))]);
      await tester.tap(find.text('Datenschutzerklärung'));
      await tester.pump();
      expect(opened, ['https://musik.test/datenschutz']);
    });
  });

  group('Premium einlösen', () {
    testWidgets('gültiger Code: Eingabe wird formatiert, Stand wird angezeigt', (tester) async {
      final api = await pumpScreen(tester, const PremiumScreen(), channel: AppChannel.play, config: config(), admin: false);
      expect(find.text('Kein Premium'), findsOneWidget);
      expect(find.text('Mit Premium siehst du keine Werbung.'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'abcd efgh jkmn');
      await tester.pump();
      expect(find.text('ABCD-EFGH-JKMN'), findsOneWidget);
      await tester.tap(find.text('Einlösen'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(api.calls, contains('redeem:ABCD-EFGH-JKMN'));
      expect(find.text('Premium bis 10. Dez. 2026'), findsOneWidget);
      expect(find.text('Du siehst keine Werbung.'), findsOneWidget);
      expectNoErrors(tester);
    });

    testWidgets('falscher Code: verständliche Meldung vom Server, Stand bleibt', (tester) async {
      final api = FakeApi(admin: false)..redeemError = const ApiException('Diesen Code gibt es nicht.', statusCode: 404);
      await pumpScreen(tester, const PremiumScreen(), api: api, channel: AppChannel.play, config: config(), admin: false);
      await tester.enterText(find.byType(TextField), 'AAAA-BBBB-CCCC');
      await tester.tap(find.text('Einlösen'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Diesen Code gibt es nicht.'), findsOneWidget);
      expect(find.text('Kein Premium'), findsOneWidget);
    });

    testWidgets('leeres Feld: Hinweis, kein Aufruf', (tester) async {
      final api = await pumpScreen(tester, const PremiumScreen(), channel: AppChannel.play, config: config(), admin: false);
      await tester.tap(find.text('Einlösen'));
      await tester.pump();
      expect(find.text('Bitte gib einen Code ein.'), findsOneWidget);
      expect(api.calls.where((c) => c.startsWith('redeem')), isEmpty);
    });

    testWidgets('unbegrenztes Premium wird als solches angezeigt', (tester) async {
      final api = FakeApi(admin: false)..premiumStatus = const PremiumStatus(active: true, unlimited: true);
      await pumpScreen(tester, const PremiumScreen(), api: api, channel: AppChannel.play, config: config(), admin: false);
      expect(find.text('Premium – unbegrenzt'), findsOneWidget);
    });
  });

  group('Song wünschen', () {
    testWidgets('leere Liste, Wunsch senden, in der Liste sehen, löschen', (tester) async {
      final api = await pumpScreen(tester, const WishesScreen(), channel: AppChannel.play, config: config(), admin: false);
      expect(find.text('Noch keine Wünsche'), findsOneWidget);

      await tester.tap(find.text('Song wünschen'));
      await tester.pumpAndSettle();
      // ohne Titel: Hinweis
      await tester.tap(find.text('Wunsch senden'));
      await tester.pump();
      expect(find.text('Bitte gib den Titel ein.'), findsOneWidget);
      expect(api.calls.where((c) => c.startsWith('createWish')), isEmpty);

      await tester.enterText(find.widgetWithText(TextField, 'Titel'), 'Du hast');
      await tester.enterText(find.widgetWithText(TextField, 'Interpret (optional)'), 'Rammstein');
      await tester.tap(find.text('Wunsch senden'));
      await tester.pumpAndSettle();
      expect(api.calls, contains('createWish:Du hast|Rammstein|'));
      expect(find.text('Du hast – Rammstein'), findsOneWidget);
      expect(find.text('Offen – wartet auf den Betreiber'), findsOneWidget);

      await tester.tap(find.byTooltip('Wunsch löschen'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Löschen').last);
      await tester.pumpAndSettle();
      expect(api.calls, contains('deleteWish:1'));
      expect(find.text('Noch keine Wünsche'), findsOneWidget);
      expectNoErrors(tester);
    });

    testWidgets('Stand der Wünsche: erledigt, abgelehnt mit Nachricht, in Arbeit (ohne Löschen)', (tester) async {
      final api = FakeApi(admin: false);
      SongWish w(int id, String status, {String note = '', String? job}) => SongWish(
          id: id, title: 'Song $id', artist: '', note: '', status: status, adminNote: note, createdAt: DateTime.utc(2026, 10, 10), jobStatus: job);
      api.wishList.addAll([w(1, 'done'), w(2, 'declined', note: 'Gibt es nicht'), w(3, 'accepted', job: 'downloading')]);
      await pumpScreen(tester, const WishesScreen(), api: api, channel: AppChannel.play, config: config(), admin: false);
      expect(find.text('Erledigt – jetzt in der Bibliothek'), findsOneWidget);
      expect(find.text('Abgelehnt'), findsOneWidget);
      expect(find.text('Nachricht: Gibt es nicht'), findsOneWidget);
      expect(find.text('Angenommen – wird geholt'), findsOneWidget);
      // „in Arbeit“ lässt sich nicht löschen (Server verweigert es)
      expect(find.byTooltip('Wunsch löschen'), findsNWidgets(2));
    });

    testWidgets('Suche (Play): kein YouTube, dafür „Wünsch dir den Song“ mit dem Suchbegriff', (tester) async {
      await pumpScreen(tester, const SearchScreen(), channel: AppChannel.play, config: config(), admin: false, size: const Size(400, 1400));
      expect(find.text('YouTube-Link einfügen'), findsNothing);
      expect(find.text('Nicht dabei? Wünsch dir den Song'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'Rammstein Du hast');
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Nicht dabei? Wünsch dir den Song'), findsOneWidget);
      expect(find.textContaining('„Rammstein Du hast“ wünschen'), findsOneWidget);
      expect(find.textContaining('YouTube'), findsNothing);
      await tester.tap(find.text('Nicht dabei? Wünsch dir den Song'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'Titel'), findsOneWidget);
      expect(find.text('Rammstein Du hast'), findsWidgets); // vorausgefüllt
    });

    testWidgets('Suche (GitHub-Version): wie bisher mit YouTube, ohne Wunschkachel', (tester) async {
      await pumpScreen(tester, const SearchScreen(), config: config(), size: const Size(400, 1400));
      expect(find.text('YouTube-Link einfügen'), findsOneWidget);
      expect(find.text('Nicht dabei? Wünsch dir den Song'), findsNothing);
    });

    testWidgets('Wunschliste vom Admin abgeschaltet: keine Kachel', (tester) async {
      await pumpScreen(tester, const SearchScreen(), channel: AppChannel.play, config: config(wishlist: false), admin: false);
      expect(find.text('Nicht dabei? Wünsch dir den Song'), findsNothing);
    });
  });

  group('Fehler melden und Konto löschen', () {
    testWidgets('Fehler melden: zu kurz → Hinweis; sonst mit Version, Kanal und (auf Wunsch) Fehlerprotokoll', (tester) async {
      ErrorLog.clear();
      ErrorLog.add('Beispielfehler im Test', null);
      final api = await pumpScreen(tester, const SettingsScreen(), channel: AppChannel.play, config: config(), admin: false, size: const Size(400, 3000));
      await tester.tap(find.text('Fehler melden'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'kaputt');
      await tester.tap(find.text('Senden'));
      await tester.pump();
      expect(find.text('Bitte beschreibe den Fehler in mindestens 10 Zeichen.'), findsOneWidget);
      expect(api.calls, isNot(contains('bugReport')));

      await tester.enterText(find.byType(TextField), 'Beim Öffnen eines Albums stürzt die App ab');
      await tester.tap(find.text('Senden'));
      await tester.pumpAndSettle();
      expect(api.calls, contains('bugReport'));
      expect(api.lastBugReport!['channel'], 'play');
      expect(api.lastBugReport!['message'], 'Beim Öffnen eines Albums stürzt die App ab');
      expect(api.lastBugReport!['log'], contains('Beispielfehler im Test'));
      expect(find.text('Danke! Deine Meldung ist angekommen.'), findsOneWidget);
      ErrorLog.clear();
    });

    testWidgets('Fehler melden ohne Häkchen: Fehlerprotokoll bleibt zu Hause', (tester) async {
      ErrorLog.clear();
      ErrorLog.add('Geheimer Beispielfehler', null);
      final api = await pumpScreen(tester, const SettingsScreen(), config: config(), admin: false, size: const Size(400, 3000));
      await tester.tap(find.text('Fehler melden'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CheckboxListTile));
      await tester.enterText(find.byType(TextField), 'Der Player bleibt hängen, wenn ich spule');
      await tester.tap(find.text('Senden'));
      await tester.pumpAndSettle();
      expect(api.lastBugReport!['log'], '');
      expect(api.lastBugReport!['channel'], 'full');
      ErrorLog.clear();
    });

    testWidgets('Konto löschen: Passwort nötig, falsches Passwort zeigt die Meldung, richtiges meldet ab', (tester) async {
      final api = FakeApi(admin: false)..deleteAccountError = const ApiException('Das Passwort stimmt nicht.', statusCode: 403);
      await pumpScreen(tester, const SettingsScreen(), api: api, channel: AppChannel.play, config: config(), admin: false, size: const Size(400, 3000));
      await tester.tap(find.text('Konto löschen'));
      await tester.pumpAndSettle();
      expect(find.text('Konto löschen?'), findsOneWidget);
      await tester.tap(find.text('Endgültig löschen'));
      await tester.pump();
      expect(find.text('Bitte gib dein Passwort ein.'), findsOneWidget);
      expect(api.calls.where((c) => c.startsWith('deleteAccount')), isEmpty);

      await tester.enterText(find.byType(TextField), 'falsch');
      await tester.tap(find.text('Endgültig löschen'));
      await tester.pumpAndSettle();
      expect(find.text('Das Passwort stimmt nicht.'), findsOneWidget);
      expect(find.text('Konto löschen?'), findsOneWidget); // Dialog bleibt offen

      api.deleteAccountError = null;
      await tester.enterText(find.byType(TextField), 'richtig');
      await tester.tap(find.text('Endgültig löschen'));
      await tester.pumpAndSettle();
      expect(api.calls, contains('deleteAccount:richtig'));
      expect(find.text('Konto löschen?'), findsNothing);
      final auth = containerOf(tester).read(authProvider).value!;
      expect(auth.isLoggedIn, isFalse);
      expect(auth.message, 'Dein Konto wurde gelöscht.');
    });
  });

  group('Hinweise des Betreibers', () {
    testWidgets('Wartungshinweis wird ganz oben gezeigt', (tester) async {
      await pumpScreen(tester, const Scaffold(body: Column(children: [MaintenanceBanner(), Text('Inhalt')])),
          config: config(maintenance: 'Heute Abend ist der Server kurz nicht erreichbar.'), admin: false);
      expect(find.text('Heute Abend ist der Server kurz nicht erreichbar.'), findsOneWidget);
    });

    testWidgets('Wartungshinweis leer (oder nur Leerzeichen) = nichts zu sehen', (tester) async {
      await pumpScreen(tester, const Scaffold(body: Column(children: [MaintenanceBanner(), Text('Inhalt')])), config: config(maintenance: '   '), admin: false);
      expect(find.byIcon(Icons.info_outline_rounded), findsNothing);
    });

    const store = 'https://play.google.com/store/apps/details?id=de.selfify.selfify.play';

    testWidgets('Update verfügbar: Hinweis mit „Aktualisieren“ (öffnet den Play Store) und „Später“ (merkt sich den Build)', (tester) async {
      final opened = <String>[];
      await pumpScreen(tester, const Scaffold(body: Column(children: [StoreUpdateBanner()])),
          channel: AppChannel.play,
          config: config(update: const UpdateInfo(level: UpdateLevel.available, latestBuild: 60, storeUrl: store, message: 'Neue Lieder-Ansicht')),
          admin: false,
          overrides: [linkOpenerProvider.overrideWithValue(recordLinks(opened))]);
      expect(find.text('Neue App-Version verfügbar'), findsOneWidget);
      expect(find.text('Neue Lieder-Ansicht'), findsOneWidget);
      await tester.tap(find.text('Aktualisieren'));
      await tester.pump();
      expect(opened, [store]);
      await tester.tap(find.byTooltip('Später'));
      await tester.pump();
      expect(find.text('Neue App-Version verfügbar'), findsNothing);
      expect(containerOf(tester).read(dismissedStoreUpdateProvider), 60);
    });

    testWidgets('Update-Hinweis: GitHub-Version zeigt ihn nie', (tester) async {
      const info = UpdateInfo(level: UpdateLevel.available, latestBuild: 60, storeUrl: store);
      await pumpScreen(tester, const Scaffold(body: Column(children: [StoreUpdateBanner()])), config: config(update: info), admin: false);
      expect(find.text('Neue App-Version verfügbar'), findsNothing);
    });

    testWidgets('Update-Hinweis ohne Store-Link bleibt weg (wäre eine Sackgasse)', (tester) async {
      await pumpScreen(tester, const Scaffold(body: Column(children: [StoreUpdateBanner()])),
          channel: AppChannel.play, config: config(update: const UpdateInfo(level: UpdateLevel.available, latestBuild: 60)), admin: false);
      expect(find.text('Neue App-Version verfügbar'), findsNothing);
    });

    testWidgets('Pflicht-Update ersetzt die App durch einen Hinweis mit Link zum Play Store', (tester) async {
      final opened = <String>[];
      await pumpScreen(tester, const UpdateGate(child: Text('Die App')),
          channel: AppChannel.play,
          config: config(update: const UpdateInfo(level: UpdateLevel.required, minBuild: 55, storeUrl: store)),
          admin: false,
          overrides: [linkOpenerProvider.overrideWithValue(recordLinks(opened))]);
      expect(find.text('Die App'), findsNothing);
      expect(find.text('Update nötig'), findsOneWidget);
      await tester.tap(find.text('Im Play Store öffnen'));
      await tester.pump();
      expect(opened, [store]);
    });

    testWidgets('Kein Pflicht-Update: die App läuft normal', (tester) async {
      await pumpScreen(tester, const UpdateGate(child: Text('Die App')), channel: AppChannel.play, config: config(), admin: false);
      expect(find.text('Die App'), findsOneWidget);
    });

    testWidgets('GitHub-Version wird nie gesperrt (auch nicht, wenn der Server „Pflicht“ meldet)', (tester) async {
      await pumpScreen(tester, const UpdateGate(child: Text('Die App')),
          config: config(update: const UpdateInfo(level: UpdateLevel.required, storeUrl: store)), admin: false);
      expect(find.text('Die App'), findsOneWidget);
    });
  });

  group('YouTube-Funktionen sind in der Play-Version weg', () {
    testWidgets('Downloads-Symbol: Play-Version nein', (tester) async {
      await pumpScreen(tester, const Scaffold(body: DownloadsAction()), channel: AppChannel.play, admin: false);
      expect(find.byTooltip('Downloads'), findsNothing);
    });

    testWidgets('Downloads-Symbol: GitHub-Version ja', (tester) async {
      await pumpScreen(tester, const Scaffold(body: DownloadsAction()), admin: false);
      expect(find.byTooltip('Downloads'), findsOneWidget);
    });

    testWidgets('Verwaltung (Play): kein Reiter „Downloader“', (tester) async {
      await pumpScreen(tester, const AdminScreen(), channel: AppChannel.play, config: config());
      expect(find.text('Benutzer'), findsWidgets);
      expect(find.text('Bibliothek'), findsWidgets);
      expect(find.text('Downloader'), findsNothing);
      expectNoErrors(tester);
    });

    testWidgets('Verwaltung (GitHub-Version): Reiter „Downloader“ wie bisher', (tester) async {
      await pumpScreen(tester, const AdminScreen(), config: config());
      expect(find.text('Downloader'), findsWidgets);
      expectNoErrors(tester);
    });
  });

  group('Feste Server-Adresse (Play-Version)', () {
    tearDown(() {
      channelOverride = null;
      serverUrlOverride = null;
    });

    test('ohne eingebaute Adresse fragt auch die Play-Version danach', () {
      channelOverride = AppChannel.play;
      expect(configuredServerUrl, '');
      expect(fixedServerUrl, isNull);
      serverUrlOverride = '   ';
      expect(fixedServerUrl, isNull);
    });

    test('die Adresse wird wie eine eingetippte aufbereitet (https:// ergänzt, Anhängsel gekürzt)', () {
      channelOverride = AppChannel.play;
      serverUrlOverride = ' musik.example.org/ ';
      expect(fixedServerUrl, 'https://musik.example.org');
      serverUrlOverride = 'HTTPS://Musik.example.org/api/';
      expect(fixedServerUrl, 'https://Musik.example.org');
    });

    test('die GitHub-Version ignoriert eine eingebaute Adresse', () {
      serverUrlOverride = 'https://musik.example.org';
      expect(appChannel, AppChannel.full);
      expect(configuredServerUrl, '');
      expect(fixedServerUrl, isNull);
    });

    testWidgets('Anmeldung (Play, feste Adresse): kein Feld „Server-Adresse“, gleich Benutzername und Passwort', (tester) async {
      serverUrlOverride = 'https://musik.example.org';
      await pumpScreen(tester, const LoginScreen(), channel: AppChannel.play);
      expect(find.text('Server-Adresse'), findsNothing);
      expect(find.text('Verbinden'), findsNothing);
      expect(find.byIcon(Icons.dns_rounded), findsNothing);
      expect(find.text('Benutzername'), findsOneWidget);
      expect(find.text('Passwort'), findsOneWidget);
      expect(find.text('Anmelden'), findsOneWidget);
      expect(find.textContaining('Noch kein Konto'), findsOneWidget);
      expect(find.byType(TextField), findsNWidgets(2)); // nur Benutzername und Passwort
      expectNoErrors(tester);
    });

    testWidgets('Anmeldung (Play, feste Adresse): leere Eingaben werden angemahnt, ohne den Server zu fragen', (tester) async {
      serverUrlOverride = 'https://musik.example.org';
      await pumpScreen(tester, const LoginScreen(), channel: AppChannel.play);
      await tester.tap(find.text('Anmelden'));
      await tester.pump();
      expect(find.text('Bitte gib deinen Benutzernamen ein.'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'lena');
      await tester.tap(find.text('Anmelden'));
      await tester.pump();
      expect(find.text('Bitte gib dein Passwort ein.'), findsOneWidget);
      expectNoErrors(tester);
    });

    testWidgets('Anmeldung (Play, ohne feste Adresse): Feld „Server-Adresse“ bleibt', (tester) async {
      await pumpScreen(tester, const LoginScreen(), channel: AppChannel.play);
      expect(find.text('Server-Adresse'), findsOneWidget);
      expect(find.text('Verbinden'), findsOneWidget);
      expect(find.text('Benutzername'), findsNothing);
    });

    testWidgets('Anmeldung (GitHub-Version): Feld „Server-Adresse“ bleibt trotz eingebauter Adresse', (tester) async {
      serverUrlOverride = 'https://musik.example.org';
      await pumpScreen(tester, const LoginScreen());
      expect(find.text('Server-Adresse'), findsOneWidget);
      expect(find.text('Verbinden'), findsOneWidget);
      expect(find.textContaining('Noch kein Konto'), findsNothing);
    });

    testWidgets('Einstellungen (Play, feste Adresse): keine Kachel „Server-Adresse“', (tester) async {
      serverUrlOverride = 'https://musik.example.org';
      await pumpScreen(tester, const SettingsScreen(),
          channel: AppChannel.play, config: config(), admin: false, size: const Size(400, 3000));
      expect(find.text('Server-Adresse'), findsNothing);
      expect(find.text('https://musik.test'), findsNothing);
      expect(find.text('Server'), findsOneWidget); // Name und Version des Servers bleiben sichtbar
      expectNoErrors(tester);
    });

    testWidgets('Einstellungen (Play, ohne feste Adresse und GitHub-Version): Kachel „Server-Adresse“ wie bisher', (tester) async {
      await pumpScreen(tester, const SettingsScreen(),
          channel: AppChannel.play, config: config(), admin: false, size: const Size(400, 3000));
      expect(find.text('Server-Adresse'), findsOneWidget);
      expect(find.text('https://musik.test'), findsOneWidget);
    });

    testWidgets('Einstellungen (GitHub-Version): Kachel „Server-Adresse“ trotz eingebauter Adresse', (tester) async {
      serverUrlOverride = 'https://musik.example.org';
      await pumpScreen(tester, const SettingsScreen(), config: config(), admin: false, size: const Size(400, 3000));
      expect(find.text('Server-Adresse'), findsOneWidget);
    });

    group('gespeicherte Anmeldung', () {
      String session(String server) => jsonEncode({
            'server_url': server,
            'tokens': Tokens(
              accessToken: 'a',
              refreshToken: 'r',
              mediaToken: 'm',
              accessExpiresAt: DateTime(2100),
              mediaExpiresAt: DateTime(2100),
            ).toJson(),
            'user': User.fromJson(userJson()).toJson(),
          });

      Future<AuthState> loadAuth({String? stored, Map<String, Object> prefs = const {}}) async {
        FlutterSecureStorage.setMockInitialValues({'selfify.session': ?stored});
        SharedPreferences.setMockInitialValues(prefs);
        final preferences = await SharedPreferences.getInstance();
        final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(preferences)]);
        addTearDown(container.dispose);
        return container.read(authProvider.future);
      }

      test('gleicher Server: Die Anmeldung bleibt bestehen', () async {
        channelOverride = AppChannel.play;
        serverUrlOverride = 'https://musik.example.org';
        final auth = await loadAuth(stored: session('https://musik.example.org'));
        expect(auth.isLoggedIn, isTrue);
        expect(auth.serverUrl, 'https://musik.example.org');
      });

      test('anderer Server (z. B. Umzug des Betreibers): abgemeldet, mit der festen Adresse zum neuen Anmelden', () async {
        channelOverride = AppChannel.play;
        serverUrlOverride = 'https://neu.example.org';
        final auth = await loadAuth(stored: session('https://alt.example.org'));
        expect(auth.isLoggedIn, isFalse);
        expect(auth.serverUrl, 'https://neu.example.org');
      });

      test('abgemeldet: die feste Adresse gewinnt gegen den zuletzt benutzten Server', () async {
        channelOverride = AppChannel.play;
        serverUrlOverride = 'https://musik.example.org';
        final auth = await loadAuth(prefs: {'selfify.last_server': 'https://irgendwo.example.org'});
        expect(auth.isLoggedIn, isFalse);
        expect(auth.serverUrl, 'https://musik.example.org');
      });

      test('ohne feste Adresse bleibt alles wie bisher: Anmeldung bei beliebigem Server, zuletzt benutzter Server', () async {
        channelOverride = AppChannel.play;
        final auth = await loadAuth(stored: session('https://alt.example.org'));
        expect(auth.isLoggedIn, isTrue);
        expect(auth.serverUrl, 'https://alt.example.org');
        final loggedOut = await loadAuth(prefs: {'selfify.last_server': 'https://irgendwo.example.org'});
        expect(loggedOut.serverUrl, 'https://irgendwo.example.org');
      });

      test('GitHub-Version: eingebaute Adresse zählt nicht', () async {
        serverUrlOverride = 'https://neu.example.org';
        final auth = await loadAuth(stored: session('https://alt.example.org'));
        expect(auth.isLoggedIn, isTrue);
        expect(auth.serverUrl, 'https://alt.example.org');
      });
    });

  });
}
