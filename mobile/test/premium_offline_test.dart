// Premium = Offline-Hören: Modelle, Zustandsautomat der Offline-Berechtigung, Sperre und Löschen mit echtem
// Dateisystem, Hinweise in der Oberfläche, Premium-Seite und Kauf über Google Play (mit nachgebautem Store) –
// und dass sich ohne die neuen Schalter nichts ändert (GitHub- wie Play-Version).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:just_audio/just_audio.dart';
import 'package:selfify/billing/billing.dart';
import 'package:selfify/core/client_info.dart';
import 'package:selfify/core/flavor.dart';
import 'package:selfify/core/links.dart';
import 'package:selfify/data/api.dart';
import 'package:selfify/data/models.dart';
import 'package:selfify/player/player.dart';
import 'package:selfify/state/app_config.dart';
import 'package:selfify/state/auth.dart';
import 'package:selfify/state/connectivity.dart';
import 'package:selfify/state/offline.dart';
import 'package:selfify/state/offline_access.dart';
import 'package:selfify/ui/screens/detail_widgets.dart';
import 'package:selfify/ui/screens/mix_screen.dart';
import 'package:selfify/ui/screens/offline_screen.dart';
import 'package:selfify/ui/screens/premium_screen.dart';
import 'package:selfify/ui/screens/settings_screen.dart';
import 'package:selfify/ui/widgets/premium_gate.dart';
import 'package:selfify/ui/widgets/track_menu.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_audio.dart';
import 'support/fakes.dart';

const _server = 'https://musik.test';
final _accessKey = offlineAccessKey(_server, 1);

/// Gerätezeit der Tests.
final _now = DateTime.utc(2026, 11, 11, 12);

const _locked = OfflineAccessState(OfflineAccess.locked);
const _checking = OfflineAccessState(OfflineAccess.checking);

/// Server-Antwort auf die Premium-Abfrage mit eingeschalteter Sperre.
PremiumStatus premium({bool allowed = true, bool required = true, int grace = 7, DateTime? until}) => PremiumStatus(
      active: allowed && required,
      until: until,
      offlineRequiresPremium: required,
      offlineAllowed: allowed,
      offlineGraceDays: grace,
      checkedAt: _now,
    );

/// Gespeicherter Stand, wie ihn die App nach einer Prüfung ablegt.
String record({bool required = true, bool allowed = true, required DateTime verified, int grace = 7, DateTime? seen}) =>
    jsonEncode(AccessRecord(
      required: required,
      allowed: allowed,
      verifiedAt: verified,
      graceDays: grace,
      lastSeenAt: seen ?? verified,
    ).toJson());

/// Lädt „Dateien“ herunter; die Premium-Abfrage kann der Test aufhalten.
class _Api extends FakeApi {
  final started = <int>[];
  Completer<void>? premiumGate;

  _Api({super.admin = false});

  @override
  Future<PremiumStatus> premium() async {
    final gate = premiumGate;
    if (gate != null) await gate.future;
    return super.premium();
  }

  @override
  Future<Response<dynamic>> downloadFile(String url, String savePath,
      {void Function(int received, int total)? onProgress, CancelToken? cancelToken}) async {
    final id = int.parse(RegExp(r'tracks/(\d+)/').firstMatch(url)!.group(1)!);
    started.add(id);
    await File(savePath).writeAsBytes(List.filled(1000, 1));
    return Response(
      requestOptions: RequestOptions(path: url),
      statusCode: 200,
      headers: Headers.fromMap({
        'content-type': ['audio/ogg'],
      }),
    );
  }
}

/// Anmeldung, die wie beim Kaltstart erst etwas später fertig ist (die Server-Einstellungen sind dann schon da).
class _SlowAuth extends FakeAuth {
  _SlowAuth(super.api);

  @override
  Future<AuthState> build() async {
    await Future<void>.delayed(const Duration(milliseconds: 120));
    return super.build();
  }
}

/// Der Server weist den Stream ab, weil die App zu alt ist.
class _Failing426 extends _Api {
  @override
  Future<Response<dynamic>> downloadFile(String url, String savePath,
      {void Function(int received, int total)? onProgress, CancelToken? cancelToken}) async {
    final request = RequestOptions(path: url);
    throw toApiException(
        DioException(requestOptions: request, response: Response(requestOptions: request, statusCode: 426)));
  }
}

/// Der Server beantwortet „Kauf melden“ je Kauf-Token anders (mehrere Käufe im selben Google-Konto).
class _PerTokenApi extends FakeApi {
  /// Token -> Fehler ([ApiException]) oder Ergebnis ('active', 'inactive', 'pending').
  final Map<String, Object> answers;

  _PerTokenApi(this.answers) : super(admin: false);

  @override
  Future<PlayVerifyResult> verifyPlayPurchase({required String productId, required String token}) async {
    calls.add('verify:$productId:$token');
    // wie beim echten Server vergeht etwas Zeit – die Meldungen des Stores überholen sich dabei
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final answer = answers[token];
    if (answer is ApiException) throw answer;
    final result = PlayVerifyResult(
      result: answer as String,
      premium: answer == 'active' ? premium() : (premiumStatus.active ? premiumStatus : premium(allowed: false)),
    );
    premiumStatus = result.premium;
    return result;
  }
}

class _LoggedOut extends FakeAuth {
  _LoggedOut(super.api);

  @override
  Future<AuthState> build() async => const AuthState(serverUrl: _server);
}

List<Track> tracks(List<int> ids) => [for (final id in ids) Track.fromJson(trackJson(id))];

Future<void> waitFor(bool Function() condition, String what) async {
  for (var i = 0; i < 400; i++) {
    // Einmal erfüllt genügt: Ein zweiter Blick (z. B. in den Ordner, während gerade gespeichert wird) kann anders
    // ausfallen
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue, reason: what);
}

Future<void> settle([int ms = 150]) => Future<void>.delayed(Duration(milliseconds: ms));

StorePurchase bought(String token, {StorePurchaseStatus status = StorePurchaseStatus.purchased, String message = ''}) =>
    StorePurchase(productId: 'premium_monat', token: token, status: status, message: message);

void main() {
  setUpAll(() => initializeDateFormatting('de_DE'));

  group('Modelle', () {
    test('alter Server (Felder fehlen): Standardwerte = Verhalten wie bisher', () {
      final c = AppConfig.fromJson({'ads_enabled': true});
      expect(c.offlineRequiresPremium, isFalse);
      expect(c.offlineGraceDays, 7);
      expect(c.billingEnabled, isFalse);
      expect(c.billingProductIds, isEmpty);
      expect(c.premiumHeadline, '');
      expect(c.premiumDescription, '');
      expect(c.premiumBenefits, isEmpty);

      final p = PremiumStatus.fromJson({'active': false, 'unlimited': false, 'until': null});
      expect(p.offlineRequiresPremium, isFalse);
      expect(p.offlineAllowed, isTrue, reason: 'alter Server: jeder darf offline hören');
      expect(p.offlineGraceDays, 7);
      expect(p.checkedAt, isNotNull, reason: 'eine echte Antwort hat immer einen Zeitpunkt');
      expect(p.play, isNull);
      expect(const PremiumStatus().checkedAt, isNull, reason: 'abgemeldet: kein Stand vom Server');
      expect(const PremiumStatus().offlineAllowed, isTrue);
    });

    test('neue Antworten werden vollständig gelesen', () {
      final c = AppConfig.fromJson({
        'offline_requires_premium': true,
        'offline_grace_days': 3,
        'billing_enabled': true,
        'billing_product_ids': ['premium_monat', 'premium_jahr'],
        'premium_headline': 'Familien-Premium',
        'premium_description': 'Für alle, die unterwegs hören.',
        'premium_benefits': ['Offline hören', '', 'Keine Werbung'],
      });
      expect(c.offlineRequiresPremium, isTrue);
      expect(c.offlineGraceDays, 3);
      expect(c.billingEnabled, isTrue);
      expect(c.billingProductIds, ['premium_monat', 'premium_jahr']);
      expect(c.premiumHeadline, 'Familien-Premium');
      expect(c.premiumDescription, 'Für alle, die unterwegs hören.');
      expect(c.premiumBenefits, ['Offline hören', 'Keine Werbung']);
      expect(AppConfig.fromJson({'offline_grace_days': 0}).offlineGraceDays, 7);

      final p = PremiumStatus.fromJson({
        'active': true,
        'unlimited': false,
        'until': '2026-12-11T09:00:00Z',
        'offline_requires_premium': true,
        'offline_allowed': false,
        'offline_grace_days': 10,
        'checked_at': '2026-11-11T09:00:00Z',
        'play': {'product_id': 'premium_monat', 'state': 'canceled', 'expires_at': '2026-12-11T09:00:00Z', 'auto_renewing': false},
      });
      expect(p.offlineRequiresPremium, isTrue);
      expect(p.offlineAllowed, isFalse);
      expect(p.offlineGraceDays, 10);
      expect(p.checkedAt, DateTime.utc(2026, 11, 11, 9));
      expect(p.play!.productId, 'premium_monat');
      expect(p.play!.state, 'canceled');
      expect(p.play!.expiresAt, DateTime.utc(2026, 12, 11, 9));
      expect(p.play!.autoRenewing, isFalse);

      final v = PlayVerifyResult.fromJson({
        'result': 'pending',
        'premium': {'active': false, 'offline_requires_premium': true, 'offline_allowed': false},
      });
      expect(v.result, 'pending');
      expect(v.premium.offlineAllowed, isFalse);
      expect(v.premium.checkedAt, isNotNull);
    });

    test('gespeicherter Stand: lesen, schreiben, Unlesbares gilt als „noch nie geprüft“', () {
      final parsed = AccessRecord.tryParse(record(verified: _now, grace: 5, seen: _now.add(const Duration(hours: 2))))!;
      expect(parsed.required, isTrue);
      expect(parsed.allowed, isTrue);
      expect(parsed.verifiedAt, _now);
      expect(parsed.graceDays, 5);
      expect(parsed.lastSeenAt, _now.add(const Duration(hours: 2)));
      expect(AccessRecord.tryParse(null), isNull);
      expect(AccessRecord.tryParse('kaputt'), isNull);
      expect(AccessRecord.tryParse('{"required": true}'), isNull);
    });
  });

  group('Android-Manifest', () {
    test('Backup-Regeln sind gesetzt – und stehen nicht bloß in einem Kommentar', () {
      final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      final comments = RegExp(r'<!--.*?-->', dotAll: true).allMatches(manifest).map((m) => m.group(0)!).join('\n');
      final code = manifest.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
      expect(code, contains('android:dataExtractionRules="@xml/data_extraction_rules"'));
      expect(code, contains('android:fullBackupContent="@xml/backup_rules"'));
      // Die Prüfung im Build sucht nach den Attributen: Ein Kommentar, der sie nennt, könnte sie vortäuschen
      expect(comments, isNot(contains('dataExtractionRules')));
      expect(comments, isNot(contains('fullBackupContent')));
      expect(comments, contains('Sicherung'), reason: 'die Erklärung bleibt');
      expect(File('android/app/src/main/res/xml/data_extraction_rules.xml').existsSync(), isTrue);
      expect(File('android/app/src/main/res/xml/backup_rules.xml').existsSync(), isTrue);
    });
  });

  group('Mindest-Version fürs Hören ohne Premium (HTTP 426)', () {
    tearDown(() => currentClient = null);

    test('Einstellung: fehlt beim alten Server (0 = aus), wird sonst gelesen; Unsinn zählt als aus', () {
      expect(AppConfig.fromJson({'ads_enabled': true}).offlineMinClientBuild, 0);
      expect(AppConfig.fromJson({'offline_min_client_build': 61}).offlineMinClientBuild, 61);
      expect(AppConfig.fromJson({'offline_min_client_build': -3}).offlineMinClientBuild, 0);
      expect(AppConfig.fromJson({'offline_min_client_build': '61'}).offlineMinClientBuild, 0);
    });

    test('426 ohne Text vom Server (z. B. beim Laden einer Datei): „Bitte aktualisiere die App.“', () {
      final request = RequestOptions(path: '/tracks/1/stream');
      final bare = toApiException(DioException(
        requestOptions: request,
        response: Response(requestOptions: request, statusCode: 426),
      ));
      expect(bare.statusCode, 426);
      expect(bare.message, 'Bitte aktualisiere die App.');
      final withDetail = toApiException(DioException(
        requestOptions: request,
        response: Response(requestOptions: request, statusCode: 426, data: {'detail': 'Bitte aktualisiere die App.'}),
      ));
      expect(withDetail.message, 'Bitte aktualisiere die App.');
    });

    test('Stream-Links tragen die App-Kennung nur, wenn der Server eine Mindest-Version verlangt', () async {
      currentClient = const ClientInfo(platform: 'android', channel: 'full', version: '1.4.0', build: 60);
      Future<Map<String, String>?> headers(AppConfig config) async {
        SharedPreferences.setMockInitialValues({});
        final c = ProviderContainer(overrides: [
          sharedPreferencesProvider.overrideWithValue(await SharedPreferences.getInstance()),
          authProvider.overrideWith(() => FakeAuth(FakeApi(admin: false))),
          appConfigProvider.overrideWith(() => FakeAppConfig(config)),
        ]);
        addTearDown(c.dispose);
        await c.read(appConfigProvider.future);
        return c.read(streamHeadersProvider);
      }

      expect(await headers(const AppConfig()), isNull, reason: 'Schalter aus: Abspielen wie bisher');
      expect(await headers(const AppConfig(offlineRequiresPremium: true)), isNull);
      expect(await headers(const AppConfig(offlineMinClientBuild: 61)), isNull, reason: 'ohne Sperre wirkungslos');
      expect(await headers(const AppConfig(offlineRequiresPremium: true, offlineMinClientBuild: 61)),
          {'X-Selfify-Client': 'platform=android; channel=full; version=1.4.0; build=60'});
    });
  });

  group('Zustandsautomat (evaluateOfflineAccess)', () {
    AccessRecord rec({bool required = true, bool allowed = true, Duration age = Duration.zero, int grace = 7, DateTime? seen}) {
      final verified = _now.subtract(age);
      return AccessRecord(required: required, allowed: allowed, verifiedAt: verified, graceDays: grace, lastSeenAt: seen ?? verified);
    }

    OfflineAccessState eval({bool admin = false, bool config = false, AccessRecord? record, DateTime? now}) =>
        evaluateOfflineAccess(isAdmin: admin, configRequires: config, record: record, now: now ?? _now);

    test('1: Admin ist immer frei – auch mit Sperre und bestätigtem „nicht erlaubt“', () {
      final s = eval(admin: true, config: true, record: rec(allowed: false));
      expect(s.access, OfflineAccess.free);
      expect(s.canDownload, isTrue);
      expect(s.canPlayLocal, isTrue);
    });

    test('2: Schalter aus (oder alter Server): frei', () {
      expect(eval(record: rec(required: false)).access, OfflineAccess.free);
      // auch wenn der Stand uralt ist: ohne Sperre gibt es keine Frist
      expect(eval(record: rec(required: false, age: const Duration(days: 400))).access, OfflineAccess.free);
      expect(eval(record: rec(required: false, allowed: false)).access, OfflineAccess.free);
    });

    test('3: noch nie geprüft, Schalter laut Einstellungen aus oder unbekannt: frei', () {
      final s = eval();
      expect(s.access, OfflineAccess.free);
      expect(s.canDownload, isTrue);
    });

    test('4: noch nie geprüft, Schalter an: „wird geprüft“ – nicht laden, aber abspielen, nichts löschen', () {
      final s = eval(config: true);
      expect(s.access, OfflineAccess.checking);
      expect(s.canDownload, isFalse);
      expect(s.canPlayLocal, isTrue);
    });

    test('5: Premium bestätigt: erlaubt, volle Frist', () {
      final s = eval(config: true, record: rec());
      expect(s.access, OfflineAccess.allowed);
      expect(s.daysLeft, 7);
      expect(s.canDownload, isTrue);
      expect(s.canPlayLocal, isTrue);
    });

    test('6: ohne neue Prüfung innerhalb der Frist: weiter erlaubt, Resttage zählen herunter', () {
      expect(eval(record: rec(age: const Duration(days: 3))).daysLeft, 4);
      expect(eval(record: rec(age: const Duration(days: 5, hours: 1))).daysLeft, 2);
      expect(eval(record: rec(age: const Duration(days: 6, hours: 23))).daysLeft, 1);
      final edge = eval(record: rec(age: const Duration(days: 7)));
      expect(edge.access, OfflineAccess.allowed, reason: 'genau die Frist gilt noch');
      expect(edge.daysLeft, 0);
    });

    test('7: Frist ohne Prüfung abgelaufen: gesperrt (Löschen erst nach einem letzten Prüfversuch)', () {
      final s = eval(record: rec(age: const Duration(days: 7, seconds: 1)));
      expect(s.access, OfflineAccess.locked);
      expect(s.graceExpired, isTrue);
      expect(s.graceDays, 7);
      expect(s.canDownload, isFalse);
      expect(s.canPlayLocal, isFalse);
      // die Frist kommt vom Server
      expect(eval(record: rec(age: const Duration(days: 3), grace: 2)).access, OfflineAccess.locked);
      expect(eval(record: rec(age: const Duration(days: 20), grace: 30)).access, OfflineAccess.allowed);
    });

    test('8: vom Server bestätigt „nicht erlaubt“: gesperrt, sofort', () {
      final s = eval(config: true, record: rec(allowed: false));
      expect(s.access, OfflineAccess.locked);
      expect(s.graceExpired, isFalse);
      expect(s.canDownload, isFalse);
      expect(s.canPlayLocal, isFalse);
    });

    test('Uhr zurückgestellt: die größte je gesehene Zeit zählt, die Frist verlängert sich nicht', () {
      final seen = _now.add(const Duration(days: 8));
      final r = AccessRecord(required: true, allowed: true, verifiedAt: _now, graceDays: 7, lastSeenAt: seen);
      // Die Uhr steht wieder auf „gerade geprüft“ – trotzdem abgelaufen
      expect(eval(record: r, now: _now).access, OfflineAccess.locked);
      expect(eval(record: r, now: _now.subtract(const Duration(days: 30))).access, OfflineAccess.locked);
      final r2 = AccessRecord(required: true, allowed: true, verifiedAt: _now, graceDays: 7, lastSeenAt: _now.add(const Duration(days: 5)));
      expect(eval(record: r2, now: _now).daysLeft, 2);
    });

    test('Uhr bei der Prüfung vorgestellt und danach zurückgestellt: der Stand gilt nicht mehr als bestätigt', () {
      // geprüft mit einer Uhr, die zehn Jahre vorging
      final future = _now.add(const Duration(days: 3650));
      final r = AccessRecord(required: true, allowed: true, verifiedAt: future, graceDays: 7, lastSeenAt: future);
      for (final now in [_now, _now.add(const Duration(days: 1000))]) {
        final s = eval(record: r, now: now);
        expect(s.access, OfflineAccess.checking, reason: 'nicht „erlaubt“, solange der Server nicht neu bestätigt hat');
        expect(s.clockSuspect, isTrue);
        expect(s.canPlayLocal, isFalse);
        expect(s.canDownload, isFalse);
        expect(s.graceExpired, isFalse, reason: 'gelöscht wird auf Verdacht nichts');
      }
      // mit der vorgestellten Uhr selbst läuft die Frist normal
      expect(eval(record: r, now: future.add(const Duration(days: 2))).access, OfflineAccess.allowed);
      expect(eval(record: r, now: future.add(const Duration(days: 8))).access, OfflineAccess.locked);
    });

    test('Uhr nach der Prüfung zurückgestellt: nicht mehr „erlaubt“ – kleine Korrekturen der Uhr schaden nicht', () {
      final r = AccessRecord(
          required: true, allowed: true, verifiedAt: _now, graceDays: 7, lastSeenAt: _now.add(const Duration(days: 5)));
      final back = eval(record: r, now: _now.add(const Duration(days: 1)));
      expect(back.access, OfflineAccess.checking);
      expect(back.clockSuspect, isTrue);
      expect(back.canPlayLocal, isFalse);
      final slightly = eval(record: r, now: _now.add(const Duration(days: 5)).subtract(const Duration(minutes: 5)));
      expect(slightly.access, OfflineAccess.allowed);
      expect(slightly.clockSuspect, isFalse);
      expect(OfflineAccessBanner.textFor(back), contains('Uhr dieses Geräts wurde zurückgestellt'));
    });

    test('der Stand der Einstellungen ändert nichts an einem vorhandenen Stand', () {
      expect(eval(config: false, record: rec(allowed: false)).access, OfflineAccess.locked);
      expect(eval(config: true, record: rec(required: false)).access, OfflineAccess.free);
    });

    test('Hinweistexte nach dem Löschen', () {
      expect(offlineWipeMessage(_locked),
          'Dein Premium ist abgelaufen – die Offline-Musik wurde von diesem Gerät entfernt.');
      expect(
        offlineWipeMessage(const OfflineAccessState(OfflineAccess.locked, graceExpired: true, graceDays: 7)),
        'Dein Premium konnte 7 Tage lang nicht geprüft werden – die Offline-Musik wurde von diesem Gerät entfernt.',
      );
    });
  });

  group('Sperre und Löschen mit echtem Dateisystem', () {
    late Directory dir;
    late StreamController<List<ConnectivityResult>> net;
    late _Api api;
    late DateTime clock;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('selfify_premium');
      net = StreamController<List<ConnectivityResult>>.broadcast();
      api = _Api();
      clock = _now;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => dir.path,
      );
    });

    tearDown(() async {
      channelOverride = null;
      await net.close();
      await dir.delete(recursive: true);
    });

    /// Zwei geladene Titel in einem Album, dazu eine halb geladene und eine verwaiste Datei.
    /// [extra]: weitere Angaben im Index (Besitzer, Sperre, offenes Aufräumen).
    Future<void> seedFiles({List<int> queue = const [], Map<String, Object> extra = const {}}) async {
      final offline = Directory('${dir.path}/offline');
      await offline.create();
      for (final name in ['1.opus', '2.opus', '7.part', 'verwaist.bin']) {
        await File('${offline.path}/$name').writeAsBytes(List.filled(500, 1));
      }
      await File('${offline.path}/index.json').writeAsString(jsonEncode({
        'tracks': {
          for (final id in [1, 2])
            '$id': {'track': trackJson(id), 'file': '$id.opus', 'size': 500, 'saved_at': '2026-11-01T10:00:00Z'},
        },
        'collections': {
          'album:7': [1, 2],
        },
        'names': {'album:7': 'A Night at the Opera'},
        'queue': [for (final id in queue) trackJson(id)],
        ...extra,
      }));
    }

    Json index() => jsonDecode(File('${dir.path}/offline/index.json').readAsStringSync()) as Json;

    List<String> files() => Directory('${dir.path}/offline').listSync().map((f) => f.path.split('/').last).toList()..sort();

    Future<ProviderContainer> container({
      AppConfig config = const AppConfig(),
      Map<String, Object> prefs = const {},
      bool online = true,
      bool slowAuth = false,
      bool loggedOut = false,
      List<Override> more = const [],
    }) async {
      SharedPreferences.setMockInitialValues(prefs);
      final c = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(await SharedPreferences.getInstance()),
        authProvider.overrideWith(() => loggedOut ? _LoggedOut(api) : (slowAuth ? _SlowAuth(api) : FakeAuth(api))),
        appConfigProvider.overrideWith(() => FakeAppConfig(config)),
        connectivityProvider.overrideWith((ref) => net.stream),
        clockProvider.overrideWithValue(() => clock),
        ...more,
      ]);
      addTearDown(c.dispose);
      c.listen(connectivityProvider, (_, _) {});
      c.listen(appConfigProvider, (_, _) {});
      c.listen(authProvider, (_, _) {});
      c.listen(offlineAccessProvider, (_, _) {});
      c.listen(offlineProvider, (_, _) {});
      net.add([online ? ConnectivityResult.wifi : ConnectivityResult.none]);
      await c.read(authProvider.future);
      await waitFor(() => c.read(offlineProvider).loaded, 'Index geladen');
      return c;
    }

    /// Wartet, bis das Löschen ganz fertig ist: Ordner leer **und** Hinweis gesetzt. Der Hinweis kommt erst nach
    /// dem Speichern des leeren Index – wer nur auf den leeren Ordner wartet, liest den Hinweis zu früh, und beim
    /// Aufräumen nach dem Test schreibt die App noch in den Ordner („Directory not empty“).
    Future<void> wiped(ProviderContainer c) =>
        waitFor(() => files().length == 1 && c.read(offlineWipeNoticeProvider) != null, 'gelöscht');

    AccessRecord? saved(ProviderContainer c) =>
        AccessRecord.tryParse(c.read(sharedPreferencesProvider).getString(_accessKey));

    const requires = AppConfig(offlineRequiresPremium: true);

    for (final channel in AppChannel.values) {
      test('Schalter aus (${channel.id}): alles wie bisher – laden geht, nichts wird gelöscht, keine Premium-Abfrage', () async {
        channelOverride = channel;
        await seedFiles();
        final c = await container();
        await settle();
        expect(c.read(offlineAccessProvider).access, OfflineAccess.free);
        expect(api.calls, isNot(contains('premium')), reason: 'ohne Sperre fragt die App nicht öfter ab als bisher');

        final offline = c.read(offlineProvider.notifier);
        expect(offline.localPath(1), endsWith('/offline/1.opus'));
        offline.downloadTracks(tracks([3]));
        await waitFor(() => c.read(offlineProvider).tracks.containsKey(3), 'Titel 3 geladen');
        await offline.keepCollection('album:9', 'Jazz', tracks([4]));
        await waitFor(() => c.read(offlineProvider).tracks.containsKey(4), 'Titel 4 geladen');
        await settle();

        expect(c.read(offlineProvider).tracks.keys, containsAll([1, 2, 3, 4]));
        expect(files(), containsAll(['1.opus', '2.opus', '3.opus', '4.opus', '7.part', 'verwaist.bin']));
        expect(c.read(offlineWipeNoticeProvider), isNull);
        expect(saved(c), isNull, reason: 'ohne Sperre wird kein Stand angelegt');
      });
    }

    test('alter Server meldet „keine Sperre“, obwohl ein alter Stand sie kannte: frei, nichts gelöscht', () async {
      await seedFiles();
      api.premiumStatus = PremiumStatus.fromJson({'active': false, 'unlimited': false, 'until': null});
      final c = await container(prefs: {_accessKey: record(verified: _now.subtract(const Duration(days: 2)))});
      await waitFor(() => c.read(offlineAccessProvider).access == OfflineAccess.free, 'Sperre aufgehoben');
      await settle();
      expect(saved(c)!.required, isFalse);
      expect(files(), containsAll(['1.opus', '2.opus']));
    });

    test('Admin: trotz Sperre frei, nichts wird gelöscht, keine Premium-Abfrage', () async {
      api = _Api(admin: true)..premiumStatus = premium(allowed: false);
      await seedFiles();
      final c = await container(config: requires);
      await settle();
      expect(c.read(offlineAccessProvider).access, OfflineAccess.free);
      expect(api.calls, isNot(contains('premium')));
      expect(files(), containsAll(['1.opus', '2.opus']));
      c.read(offlineProvider.notifier).downloadTracks(tracks([3]));
      await waitFor(() => c.read(offlineProvider).tracks.containsKey(3), 'Admin darf laden');
      await settle();
    });

    test('Premium bestätigt: erlaubt, Stand mit Zeitpunkt der Prüfung gespeichert, laden geht', () async {
      await seedFiles();
      api.premiumStatus = premium();
      final c = await container(config: requires);
      await waitFor(() => c.read(offlineAccessProvider).access == OfflineAccess.allowed, 'erlaubt');
      expect(c.read(offlineAccessProvider).daysLeft, 7);
      final r = saved(c)!;
      expect(r.required, isTrue);
      expect(r.allowed, isTrue);
      expect(r.verifiedAt, _now, reason: 'Gerätezeit beim Empfang');
      expect(r.graceDays, 7);

      c.read(offlineProvider.notifier).downloadTracks(tracks([3]));
      await waitFor(() => c.read(offlineProvider).tracks.containsKey(3), 'Titel 3 geladen');
      await settle();
      expect(files(), containsAll(['1.opus', '2.opus', '3.opus']));
      expect(c.read(offlineWipeNoticeProvider), isNull);
    });

    test('Server bestätigt „kein Premium“: alles wird gelöscht (auch halb Geladenes und Verwaistes), danach lädt nichts mehr',
        () async {
      await seedFiles();
      api.premiumStatus = premium(allowed: false);
      final c = await container(config: requires);
      await waitFor(() => c.read(offlineAccessProvider).access == OfflineAccess.locked, 'gesperrt');
      await waitFor(() => files().length == 1 && c.read(offlineWipeNoticeProvider) != null, 'Ordner geleert');

      expect(files(), ['index.json']);
      final state = c.read(offlineProvider);
      expect(state.tracks, isEmpty);
      expect(state.collections, isEmpty);
      expect(state.pending, isEmpty);
      final index = jsonDecode(File('${dir.path}/offline/index.json').readAsStringSync()) as Map;
      expect(index['tracks'], isEmpty);
      expect(index['collections'], isEmpty);
      expect(c.read(offlineWipeNoticeProvider),
          'Dein Premium ist abgelaufen – die Offline-Musik wurde von diesem Gerät entfernt.');
      expect(saved(c)!.allowed, isFalse);

      // Sicherheitsnetz der Steuerung: nichts davon lädt
      final offline = c.read(offlineProvider.notifier);
      offline.downloadTracks(tracks([3]));
      await offline.keepCollection('album:9', 'Jazz', tracks([4]));
      await offline.syncCollection('album:7', tracks([1, 2, 5]));
      await settle();
      expect(api.started, isEmpty);
      expect(c.read(offlineProvider).pending, isEmpty);
      expect(c.read(offlineProvider).collections, isEmpty);
      expect(offline.localPath(1), isNull);
      expect(files(), ['index.json']);
    });

    test('Premium kommt zurück: wieder erlaubt, aber nichts lädt von selbst nach', () async {
      await seedFiles();
      api.premiumStatus = premium(allowed: false);
      final c = await container(config: requires);
      await waitFor(() => files().length == 1 && c.read(offlineWipeNoticeProvider) != null, 'gelöscht');
      c.read(offlineWipeNoticeProvider.notifier).clear();

      // Code eingelöst: Der Server meldet Premium
      api.premiumStatus = premium();
      c.invalidate(premiumProvider);
      await waitFor(() => c.read(offlineAccessProvider).access == OfflineAccess.allowed, 'wieder erlaubt');
      await settle();
      expect(api.started, isEmpty);
      expect(c.read(offlineProvider).tracks, isEmpty);
      c.read(offlineProvider.notifier).downloadTracks(tracks([1]));
      await waitFor(() => c.read(offlineProvider).tracks.containsKey(1), 'neu geladen');
      await settle();
      expect(c.read(offlineWipeNoticeProvider), isNull);
    });

    test('Code einlösen schreibt den neuen Stand sofort', () async {
      api.premiumStatus = premium(allowed: false);
      final c = await container(config: requires);
      await waitFor(() => c.read(offlineAccessProvider).access == OfflineAccess.locked, 'gesperrt');
      api.premiumStatus = premium();
      c.read(premiumProvider.notifier).set(premium());
      await waitFor(() => c.read(offlineAccessProvider).access == OfflineAccess.allowed, 'erlaubt');
      expect(saved(c)!.allowed, isTrue);
      await settle();
    });

    for (final (name, error) in [
      ('503 „kann gerade nicht geprüft werden“', const ApiException('Dein Premium-Stand kann gerade nicht geprüft werden.', statusCode: 503)),
      ('Ladefehler ohne Netz', const ApiException('Keine Verbindung zum Server.')),
    ]) {
      test('$name innerhalb der Frist: nichts wird gelöscht, der alte Stand gilt weiter', () async {
        await seedFiles();
        api.premiumError = error;
        final verified = _now.subtract(const Duration(days: 3));
        final c = await container(config: requires, prefs: {_accessKey: record(verified: verified)});
        await waitFor(() => api.calls.contains('premium'), 'Premium wurde abgefragt');
        await settle();

        final access = c.read(offlineAccessProvider);
        expect(access.access, OfflineAccess.allowed);
        expect(access.daysLeft, 4);
        expect(saved(c)!.verifiedAt, verified, reason: 'ein Fehler schreibt keinen neuen Stand');
        expect(files(), containsAll(['1.opus', '2.opus', '7.part', 'verwaist.bin']));
        expect(c.read(offlineProvider).tracks.keys, [1, 2]);
        expect(c.read(offlineProvider.notifier).localPath(1), isNotNull);
        expect(c.read(offlineWipeNoticeProvider), isNull);
      });
    }

    test('bekanntes Ablaufdatum ist vorbei, der Server hat aber nichts bestätigt: nichts wird gelöscht', () async {
      await seedFiles();
      // Letzte Antwort: erlaubt. Seither kein Kontakt; das Abo wäre laut „until“ gestern abgelaufen.
      api.premiumError = const ApiException('Keine Verbindung zum Server.');
      final c = await container(
        config: requires,
        online: false,
        prefs: {_accessKey: record(verified: _now.subtract(const Duration(days: 6)))},
      );
      await settle();
      expect(c.read(offlineAccessProvider).access, OfflineAccess.allowed);
      expect(c.read(offlineAccessProvider).daysLeft, 1);
      expect(files(), containsAll(['1.opus', '2.opus']));
    });

    test('Frist um und kein Netz: gesperrt und gelöscht, Hinweis nennt die Tage', () async {
      await seedFiles();
      api.premiumError = const ApiException('Keine Verbindung zum Server.');
      final c = await container(
        config: requires,
        online: false,
        prefs: {_accessKey: record(verified: _now.subtract(const Duration(days: 8)))},
      );
      await waitFor(() => files().length == 1 && c.read(offlineWipeNoticeProvider) != null, 'gelöscht');
      final access = c.read(offlineAccessProvider);
      expect(access.access, OfflineAccess.locked);
      expect(access.graceExpired, isTrue);
      expect(c.read(offlineProvider).tracks, isEmpty);
      expect(c.read(offlineWipeNoticeProvider),
          'Dein Premium konnte 7 Tage lang nicht geprüft werden – die Offline-Musik wurde von diesem Gerät entfernt.');
    });

    test('Frist um, Netz da, Prüfung erfolgreich: nichts wird gelöscht, die Frist beginnt neu', () async {
      await seedFiles();
      api
        ..premiumStatus = premium()
        ..premiumGate = Completer<void>();
      final c = await container(
        config: requires,
        prefs: {_accessKey: record(verified: _now.subtract(const Duration(days: 30)))},
      );
      // Solange die letzte Prüfung läuft: nicht laden, nicht löschen
      await settle();
      expect(c.read(offlineAccessProvider).access, OfflineAccess.checking);
      expect(files(), containsAll(['1.opus', '2.opus']));
      api.premiumGate!.complete();
      await waitFor(() => c.read(offlineAccessProvider).access == OfflineAccess.allowed, 'erlaubt');
      await settle();
      expect(c.read(offlineAccessProvider).daysLeft, 7);
      expect(saved(c)!.verifiedAt, _now);
      expect(files(), containsAll(['1.opus', '2.opus', '7.part', 'verwaist.bin']));
      expect(c.read(offlineProvider).tracks.keys, [1, 2]);
      expect(c.read(offlineWipeNoticeProvider), isNull);
    });

    test('Frist um, Netz da, Prüfung ergibt „kein Premium“: gelöscht mit dem Hinweis „abgelaufen“', () async {
      await seedFiles();
      api.premiumStatus = premium(allowed: false);
      final c = await container(
        config: requires,
        prefs: {_accessKey: record(verified: _now.subtract(const Duration(days: 30)))},
      );
      await waitFor(() => files().length == 1 && c.read(offlineWipeNoticeProvider) != null, 'gelöscht');
      expect(c.read(offlineAccessProvider).graceExpired, isFalse);
      expect(c.read(offlineWipeNoticeProvider), startsWith('Dein Premium ist abgelaufen'));
    });

    test('Frist um, Netz da, Prüfung scheitert: erst nach dem Versuch gesperrt und gelöscht', () async {
      await seedFiles();
      api
        ..premiumError = const ApiException('Dein Premium-Stand kann gerade nicht geprüft werden.', statusCode: 503)
        ..premiumGate = Completer<void>();
      final c = await container(
        config: requires,
        prefs: {_accessKey: record(verified: _now.subtract(const Duration(days: 8)))},
      );
      await settle();
      expect(c.read(offlineAccessProvider).access, OfflineAccess.checking, reason: 'der Versuch läuft noch');
      expect(files(), containsAll(['1.opus', '2.opus']), reason: 'vor dem Versuch wird nichts gelöscht');
      api.premiumGate!.complete();
      await waitFor(() => files().length == 1 && c.read(offlineWipeNoticeProvider) != null, 'gelöscht');
      expect(c.read(offlineAccessProvider).graceExpired, isTrue);
      expect(api.calls.where((call) => call == 'premium'), isNotEmpty);
    });

    test('Uhr des Geräts zurückgestellt: die Frist läuft trotzdem ab', () async {
      await seedFiles();
      api.premiumError = const ApiException('Keine Verbindung zum Server.');
      // geprüft „heute“, aber das Gerät hat schon den 20. gesehen – jetzt steht die Uhr wieder auf heute
      final c = await container(
        config: requires,
        online: false,
        prefs: {_accessKey: record(verified: _now, seen: _now.add(const Duration(days: 9)))},
      );
      await wiped(c);
      expect(c.read(offlineAccessProvider).graceExpired, isTrue);
    });

    test('die Zeit läuft bei offener App weiter: beim erneuten Auswerten greift die Frist', () async {
      await seedFiles();
      api.premiumError = const ApiException('Keine Verbindung zum Server.');
      final c = await container(
        config: requires,
        online: false,
        prefs: {_accessKey: record(verified: _now.subtract(const Duration(days: 5)))},
      );
      await settle();
      expect(c.read(offlineAccessProvider).daysLeft, 2);
      expect(files(), containsAll(['1.opus', '2.opus']));
      clock = _now.add(const Duration(days: 3));
      c.read(offlineAccessProvider.notifier).recheck(); // stündlich und beim Zurückkehren in die App
      await wiped(c);
      expect(saved(c)!.lastSeenAt, clock);
    });

    test('noch nie geprüft, Sperre an, Premium-Abfrage scheitert: nichts löschen, nichts laden, Abspielen geht', () async {
      await seedFiles(queue: [5]);
      api.premiumError = const ApiException('Keine Verbindung zum Server.');
      final c = await container(config: requires, slowAuth: true);
      await waitFor(() => api.calls.contains('premium'), 'Premium wurde abgefragt');
      await settle();

      expect(c.read(offlineAccessProvider).access, OfflineAccess.checking);
      expect(saved(c), isNull);
      expect(files(), containsAll(['1.opus', '2.opus', '7.part', 'verwaist.bin']));
      final offline = c.read(offlineProvider.notifier);
      expect(offline.localPath(1), isNotNull);
      offline.downloadTracks(tracks([3]));
      await offline.keepCollection('album:9', 'Jazz', tracks([4]));
      await settle();
      expect(api.started, isEmpty, reason: 'auch die Warteschlange vom letzten Mal wartet');
      expect(c.read(offlineProvider).pending, [5]);
      expect(c.read(offlineProvider).collections.keys, ['album:7']);
      expect(c.read(offlineWipeNoticeProvider), isNull);
    });

    test('Warteschlange hält an, solange der Stand unklar ist, und läuft nach der Bestätigung weiter', () async {
      await seedFiles(queue: [5, 6]);
      api
        ..premiumStatus = premium()
        ..premiumGate = Completer<void>();
      final c = await container(config: requires, slowAuth: true);
      await settle(250);
      expect(c.read(offlineAccessProvider).access, OfflineAccess.checking);
      expect(api.started, isEmpty);
      expect(c.read(offlineProvider).pending, [5, 6]);

      api.premiumGate!.complete();
      await waitFor(() => c.read(offlineProvider).tracks.length == 4, 'Warteschlange abgearbeitet');
      await settle();
      expect(api.started, [5, 6]);
      expect(files(), containsAll(['1.opus', '2.opus', '5.opus', '6.opus']));
    });

    test('abgemeldet: keine Auswertung, nichts wird gelöscht – auch wenn ein gesperrter Stand auf dem Gerät liegt', () async {
      await seedFiles();
      final c = await container(
        config: requires,
        loggedOut: true,
        prefs: {_accessKey: record(allowed: false, verified: _now)},
      );
      await settle();
      expect(c.read(offlineAccessProvider).access, OfflineAccess.free);
      expect(files(), containsAll(['1.opus', '2.opus', '7.part', 'verwaist.bin']));
      expect(api.calls, isNot(contains('premium')));
    });

    test('mehrfaches Löschen ist unschädlich; ohne Dateien gibt es keinen Hinweis', () async {
      api.premiumStatus = premium(allowed: false);
      final c = await container(config: requires);
      await waitFor(() => c.read(offlineAccessProvider).access == OfflineAccess.locked, 'gesperrt');
      await settle();
      expect(c.read(offlineWipeNoticeProvider), isNull, reason: 'es lag nichts auf dem Gerät');
      final offline = c.read(offlineProvider.notifier);
      expect(await offline.wipe(), isFalse);
      expect(await offline.wipe(), isFalse);
      expect(files(), ['index.json']);
    });

    // ---- Uhr des Geräts bei der Prüfung vorgestellt (Gnadenfrist ließ sich so beliebig verlängern)

    test('Uhr war bei der Prüfung vorgestellt, jetzt zurückgestellt und kein Netz: nichts vom Gerät abspielen, nichts laden, nichts löschen',
        () async {
      await seedFiles();
      api.premiumError = const ApiException('Keine Verbindung zum Server.');
      final future = _now.add(const Duration(days: 3650));
      final c = await container(config: requires, online: false, prefs: {_accessKey: record(verified: future)});
      await settle();
      final access = c.read(offlineAccessProvider);
      expect(access.access, OfflineAccess.checking);
      expect(access.clockSuspect, isTrue);
      final offline = c.read(offlineProvider.notifier);
      expect(offline.localPath(1), isNull, reason: 'die Frist stünde sonst still, bis das vorgestellte Datum erreicht ist');
      offline.downloadTracks(tracks([3]));
      await settle();
      expect(api.started, isEmpty);
      expect(files(), containsAll(['1.opus', '2.opus']), reason: 'auf Verdacht wird nichts gelöscht');
      expect(c.read(offlineWipeNoticeProvider), isNull);

      // auch 1000 Tage später (immer noch vor dem vorgestellten Datum) bleibt es dabei
      clock = _now.add(const Duration(days: 1000));
      c.read(offlineAccessProvider.notifier).recheck();
      await settle();
      expect(c.read(offlineAccessProvider).canPlayLocal, isFalse);
      expect(saved(c)!.verifiedAt, future, reason: 'ohne Antwort des Servers ändert sich der Stand nicht');
    });

    test('Uhr zurückgestellt, Netz da: der Server bestätigt neu – wieder erlaubt, die Frist zählt ab jetzt', () async {
      await seedFiles();
      api.premiumStatus = premium();
      final c = await container(
          config: requires, prefs: {_accessKey: record(verified: _now.add(const Duration(days: 3650)))});
      await waitFor(() => c.read(offlineAccessProvider).access == OfflineAccess.allowed, 'neu bestätigt');
      expect(saved(c)!.verifiedAt, _now);
      expect(c.read(offlineProvider.notifier).localPath(1), isNotNull);
      expect(files(), containsAll(['1.opus', '2.opus']));
    });

    test('Uhr zurückgestellt, Netz da: der Server meldet „kein Premium“ – gelöscht', () async {
      await seedFiles();
      api.premiumStatus = premium(allowed: false);
      final c = await container(
          config: requires, prefs: {_accessKey: record(verified: _now.add(const Duration(days: 3650)))});
      await wiped(c);
      expect(c.read(offlineAccessProvider).access, OfflineAccess.locked);
    });

    // ---- Offline-Musik gehört zu einem Konto (anderer Server / anderes Konto)

    test('unter der Sperre geladene Musik merkt sich Konto und Server', () async {
      await seedFiles();
      api.premiumStatus = premium();
      final c = await container(config: requires);
      await waitFor(() => c.read(offlineAccessProvider).access == OfflineAccess.allowed, 'erlaubt');
      await waitFor(() => index()['owner'] == 'https://musik.test|1' && index()['protected'] == true, 'Besitzer vermerkt');
      expect(files(), containsAll(['1.opus', '2.opus']));
    });

    test('Musik eines anderen Servers, dort unter der Sperre geladen: wird bei der Anmeldung hier entfernt – auch ohne Sperre', () async {
      await seedFiles(extra: {'owner': 'https://premium.example|1', 'protected': true});
      // dieser Server kennt keine Sperre: ohne den Vermerk blieben die Dateien dauerhaft spielbar
      final c = await container();
      await wiped(c);
      expect(c.read(offlineAccessProvider).access, OfflineAccess.free);
      expect(c.read(offlineWipeNoticeProvider),
          'Die Offline-Musik gehörte zu einem anderen Konto und wurde von diesem Gerät entfernt.');
      expect(c.read(offlineProvider).tracks, isEmpty);
      await waitFor(() => index()['owner'] == 'https://musik.test|1', 'gehört jetzt diesem Konto');
      expect(index()['protected'], isNull);
      // danach lädt dieses Konto wie gewohnt
      c.read(offlineProvider.notifier).downloadTracks(tracks([3]));
      await waitFor(() => c.read(offlineProvider).tracks.containsKey(3), 'Titel 3 geladen');
      await settle();
    });

    test('Musik eines anderen Kontos am selben Server (unter der Sperre geladen): auch ein Admin übernimmt sie nicht', () async {
      api = _Api(admin: true);
      await seedFiles(extra: {'owner': 'https://musik.test|2', 'protected': true});
      final c = await container(config: requires);
      await wiped(c);
      expect(c.read(offlineAccessProvider).access, OfflineAccess.free);
      expect(c.read(offlineWipeNoticeProvider), offlineOtherAccountMessage);
    });

    test('ohne Sperre geladen: die Musik gehört wie bisher zum Gerät und bleibt beim Kontowechsel', () async {
      await seedFiles(extra: {'owner': 'https://musik.test|2'});
      final c = await container();
      await waitFor(() => index()['owner'] == 'https://musik.test|1', 'übernommen');
      await settle();
      expect(files(), containsAll(['1.opus', '2.opus', '7.part', 'verwaist.bin']));
      expect(c.read(offlineProvider).tracks.keys, [1, 2]);
      expect(c.read(offlineWipeNoticeProvider), isNull);
    });

    test('dasselbe Konto meldet sich wieder an: nichts wird gelöscht', () async {
      await seedFiles(extra: {'owner': 'https://musik.test|1', 'protected': true});
      api.premiumStatus = premium();
      final c = await container(config: requires);
      await waitFor(() => c.read(offlineAccessProvider).access == OfflineAccess.allowed, 'erlaubt');
      await settle();
      expect(files(), containsAll(['1.opus', '2.opus']));
      expect(c.read(offlineWipeNoticeProvider), isNull);
    });

    // ---- Laufende Wiedergabe beim Sperren, liegen gebliebene Dateien

    test('vor dem Löschen wird die Wiedergabe von den Dateien gelöst – da sind sie noch da, aber nicht mehr abspielbar', () async {
      await seedFiles();
      api
        ..premiumStatus = premium(allowed: false)
        ..premiumGate = Completer<void>();
      final c = await container(config: requires, slowAuth: true);
      final offline = c.read(offlineProvider.notifier);
      final seen = <String>[];
      offline.releasePlayback = (ids) async {
        seen.add('Titel ${ids.toList()..sort()}, Dateien ${files().where((f) => f.endsWith('.opus')).toList()}, '
            'lokal ${offline.localPath(1)}');
      };
      api.premiumGate!.complete();
      await wiped(c);
      expect(seen, ['Titel [1, 2], Dateien [1.opus, 2.opus], lokal null']);
    });

    test('Premium läuft während der Wiedergabe vom Gerät ab: es geht als Stream weiter, die Dateien sind weg', () async {
      final platform = useFakeAudioPlatform();
      final handler = SelfifyAudioHandler();
      await seedFiles();
      api.premiumStatus = premium();
      final c = await container(config: requires, more: [audioHandlerProvider.overrideWithValue(handler)]);
      c.listen(playbackBridgeProvider, (_, _) {});
      await waitFor(() => c.read(offlineAccessProvider).access == OfflineAccess.allowed, 'erlaubt');
      unawaited(handler.playTracks(tracks([1, 2])));
      await waitFor(() => platform.last?.children.length == 2, 'Warteschlange steht');
      expect(platform.last!.children, everyElement(startsWith('file://')), reason: 'spielt vom Gerät');

      api.premiumStatus = premium(allowed: false);
      c.invalidate(premiumProvider);
      await wiped(c);
      expect(platform.last!.children, everyElement(startsWith('https://musik.test/api/tracks/')),
          reason: 'die Warteschlange zeigt nicht mehr auf gelöschte Dateien');
      expect(handler.tracks.map((t) => t.id), [1, 2]);
      await handler.player.dispose();
    });

    test('ohne Netz endet die Wiedergabe beim Sperren (nichts zeigt mehr auf gelöschte Dateien)', () async {
      final platform = useFakeAudioPlatform();
      final handler = SelfifyAudioHandler();
      await seedFiles();
      api.premiumError = const ApiException('Keine Verbindung zum Server.');
      final c = await container(
        config: requires,
        online: false,
        prefs: {_accessKey: record(verified: _now.subtract(const Duration(days: 5)))},
        more: [audioHandlerProvider.overrideWithValue(handler)],
      );
      c.listen(playbackBridgeProvider, (_, _) {});
      await settle();
      unawaited(handler.playTracks(tracks([1, 2])));
      await waitFor(() => platform.last?.children.length == 2, 'Warteschlange steht');
      clock = _now.add(const Duration(days: 3));
      c.read(offlineAccessProvider.notifier).recheck();
      await wiped(c);
      expect(handler.tracks, isEmpty);
      await handler.player.dispose();
    });

    test('Datei lässt sich beim Löschen nicht entfernen (unter Windows noch geöffnet): wird vermerkt und nachgeholt', () async {
      OfflineController.cleanupRetry = const Duration(milliseconds: 80);
      var blocked = true;
      OfflineController.deleteEntry = (entry) async {
        if (blocked && entry.path.endsWith('1.opus')) throw const FileSystemException('Datei wird verwendet');
        await entry.delete(recursive: true);
      };
      addTearDown(() {
        OfflineController.cleanupRetry = const Duration(seconds: 15);
        OfflineController.deleteEntry = (entry) => entry.delete(recursive: true);
      });
      await seedFiles();
      api.premiumStatus = premium(allowed: false);
      final c = await container(config: requires);
      await waitFor(() => !files().contains('2.opus'), 'gelöscht, was ging');
      await waitFor(() => index()['cleanup'] == true, 'Rest vermerkt');
      expect(files(), ['1.opus', 'index.json']);
      expect(c.read(offlineProvider).tracks, isEmpty);

      blocked = false; // die Datei ist wieder frei
      await waitFor(() => files().length == 1, 'nachgeholt');
      await waitFor(() => index()['cleanup'] == null, 'Vermerk gelöscht');
    });

    test('liegen gebliebene Dateien vom letzten Löschen werden beim nächsten Start entfernt – auch wenn inzwischen wieder Premium läuft',
        () async {
      final offline = Directory('${dir.path}/offline');
      await offline.create();
      for (final name in ['1.opus', '9.opus', '4.part']) {
        await File('${offline.path}/$name').writeAsBytes(List.filled(500, 1));
      }
      await File('${offline.path}/index.json').writeAsString(jsonEncode({
        'tracks': {
          '9': {'track': trackJson(9), 'file': '9.opus', 'size': 500, 'saved_at': '2026-11-10T10:00:00Z'},
        },
        'collections': <String, Object>{},
        'names': <String, Object>{},
        'queue': <Object>[],
        'owner': 'https://musik.test|1',
        'protected': true,
        'cleanup': true,
      }));
      api.premiumStatus = premium();
      final c = await container(config: requires);
      await waitFor(() => c.read(offlineAccessProvider).access == OfflineAccess.allowed, 'erlaubt');
      await waitFor(() => index()['cleanup'] == null, 'aufgeräumt');
      expect(files(), ['9.opus', 'index.json'], reason: 'nur was im Index steht, bleibt');
      expect(c.read(offlineProvider).tracks.keys, [9]);
    });

    test('App wird beendet, während liegen gebliebene Dateien aufgeräumt werden: kein Fehler danach', () async {
      final gate = Completer<void>();
      OfflineController.deleteEntry = (entry) async {
        await gate.future;
        await entry.delete(recursive: true);
      };
      addTearDown(() => OfflineController.deleteEntry = (entry) => entry.delete(recursive: true));
      final offline = Directory('${dir.path}/offline');
      await offline.create();
      await File('${offline.path}/1.opus').writeAsBytes(List.filled(500, 1));
      await File('${offline.path}/index.json').writeAsString(jsonEncode({
        'tracks': <String, Object>{},
        'collections': <String, Object>{},
        'names': <String, Object>{},
        'queue': <Object>[],
        'cleanup': true,
      }));
      final c = await container(); // der Index ist geladen, das Aufräumen hängt an der Datei
      c.dispose();
      gate.complete();
      // Ein Zugriff auf den beendeten Speicher schlüge hier als Fehler des Tests auf
      await waitFor(() => !files().contains('1.opus'), 'Datei entfernt');
      await settle();
    });

    // ---- Server weist das Abspielen ab, weil die App zu alt ist (HTTP 426)

    test('Player-Fehler und der Server antwortet mit 426: Hinweis „Bitte aktualisiere die App.“', () async {
      currentClient = const ClientInfo(platform: 'android', channel: 'full', version: '1.4.0', build: 60);
      addTearDown(() => currentClient = null);
      final platform = useFakeAudioPlatform();
      final handler = SelfifyAudioHandler();
      api.premiumStatus = premium(allowed: false);
      final c = await container(
        config: const AppConfig(offlineRequiresPremium: true, offlineMinClientBuild: 61),
        more: [audioHandlerProvider.overrideWithValue(handler)],
      );
      c.listen(playbackBridgeProvider, (_, _) {});
      c.listen(updateRequiredNoticeProvider, (_, _) {});
      await settle();
      final source = handler.resolveSource!(tracks([5]).single, handler.mediaItemFor(tracks([5]).single));
      expect((source as UriAudioSource).headers, {'X-Selfify-Client': 'platform=android; channel=full; version=1.4.0; build=60'},
          reason: 'sonst hielte der Server auch die aktuelle App für zu alt');

      unawaited(handler.playTracks(tracks([5, 6])));
      await waitFor(() => platform.last?.children.length == 2, 'Warteschlange steht');
      // anderer Fehler (Server antwortet normal): kein Hinweis
      platform.last!.fail(2004, 'Source error');
      await waitFor(() => api.calls.contains('streamStatus'), 'Status nachgefragt');
      await settle(50);
      expect(c.read(updateRequiredNoticeProvider), isFalse);

      // neuer Versuch (nach einem Fehler gibt just_audio den Player frei und baut ihn beim Abspielen neu auf)
      api.streamStatusCode = 426;
      final before = platform.last;
      unawaited(handler.playTracks(tracks([5, 6])));
      await waitFor(() => platform.last != before && platform.last!.children.length == 2, 'neu geladen');
      platform.last!.fail(2004, 'Source error');
      await waitFor(() => c.read(updateRequiredNoticeProvider), 'Hinweis');
      await handler.player.dispose();
    });

    test('426, obwohl die App die Mindest-Version noch nicht kennt (Einstellungen alt oder nicht geladen): Hinweis kommt trotzdem',
        () async {
      currentClient = const ClientInfo(platform: 'android', channel: 'full', version: '1.4.0', build: 60);
      addTearDown(() => currentClient = null);
      final platform = useFakeAudioPlatform();
      final handler = SelfifyAudioHandler();
      api.streamStatusCode = 426;
      // Stand der App: keine Sperre, keine Mindest-Version – der Betreiber hat sie inzwischen eingeschaltet
      final c = await container(more: [audioHandlerProvider.overrideWithValue(handler)]);
      c.listen(playbackBridgeProvider, (_, _) {});
      c.listen(updateRequiredNoticeProvider, (_, _) {});
      await settle();
      expect(c.read(streamHeadersProvider), isNull, reason: 'die App weiß von nichts');

      unawaited(handler.playTracks(tracks([5, 6])));
      await waitFor(() => platform.last?.children.length == 2, 'Warteschlange steht');
      platform.last!.fail(2004, 'Source error');
      await waitFor(() => c.read(updateRequiredNoticeProvider), 'Hinweis „Bitte aktualisiere die App.“');
      expect(api.calls, contains('streamStatus'));
      await handler.player.dispose();
    });

    test('Player-Fehler bei unbekannter Einstellung, der Server antwortet normal: kein Hinweis, die Einstellungen werden neu geholt',
        () async {
      currentClient = const ClientInfo(platform: 'android', channel: 'full', version: '1.4.0', build: 61);
      addTearDown(() => currentClient = null);
      final platform = useFakeAudioPlatform();
      final handler = SelfifyAudioHandler();
      final c = await container(more: [audioHandlerProvider.overrideWithValue(handler)]);
      c.listen(playbackBridgeProvider, (_, _) {});
      c.listen(updateRequiredNoticeProvider, (_, _) {});
      c.listen(streamHeadersProvider, (_, _) {});
      await settle();
      // der Betreiber verlangt inzwischen eine Mindest-Version – die App erfährt es beim nächsten Abruf
      (c.read(appConfigProvider.notifier) as FakeAppConfig).config =
          const AppConfig(offlineRequiresPremium: true, offlineMinClientBuild: 61);

      unawaited(handler.playTracks(tracks([5, 6])));
      await waitFor(() => platform.last?.children.length == 2, 'Warteschlange steht');
      expect(platform.last!.children, everyElement(startsWith('https://')));
      platform.last!.fail(2004, 'Source error');
      await waitFor(() => c.read(streamHeadersProvider) != null, 'Einstellungen neu geholt');
      expect(c.read(streamHeadersProvider), {'X-Selfify-Client': 'platform=android; channel=full; version=1.4.0; build=61'});
      expect(c.read(updateRequiredNoticeProvider), isFalse, reason: 'die App ist aktuell');
      await settle(50);
      await handler.player.dispose();
    });

    test('Player-Fehler bei einem Titel vom Gerät: der Server wird nicht gefragt', () async {
      final platform = useFakeAudioPlatform();
      final handler = SelfifyAudioHandler();
      await seedFiles();
      api.streamStatusCode = 426;
      final c = await container(more: [audioHandlerProvider.overrideWithValue(handler)]);
      c.listen(playbackBridgeProvider, (_, _) {});
      c.listen(updateRequiredNoticeProvider, (_, _) {});
      await settle();
      unawaited(handler.playTracks(tracks([1, 2])));
      await waitFor(() => platform.last?.children.length == 2, 'Warteschlange steht');
      expect(platform.last!.children, everyElement(startsWith('file://')));
      platform.last!.fail(2004, 'Source error');
      await settle();
      expect(api.calls, isNot(contains('streamStatus')));
      expect(c.read(updateRequiredNoticeProvider), isFalse);
      await handler.player.dispose();
    });

    test('Laden aufs Gerät mit 426: die Meldung des Servers steht beim Titel', () async {
      api = _Failing426();
      final c = await container();
      c.read(offlineProvider.notifier).downloadTracks(tracks([3]));
      await waitFor(() => c.read(offlineProvider).lastError != null, 'Fehler');
      expect(c.read(offlineProvider).lastError, endsWith('konnte nicht geladen werden: Bitte aktualisiere die App.'));
    });
  });

  group('Hinweise in der Oberfläche', () {
    Override access(OfflineAccessState state) => offlineAccessProvider.overrideWith(() => FakeOfflineAccess(state));

    Widget button() => Scaffold(
          body: Center(
            child: DetailOfflineButton(collectionKey: 'album:7', name: 'A Night at the Opera', tracks: sampleTracks(2)),
          ),
        );

    ProviderContainer containerOf(WidgetTester tester) =>
        ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));

    testWidgets('gesperrt: Download-Knopf erklärt die Sperre, „Premium ansehen“ führt zur Premium-Seite', (tester) async {
      await pumpScreen(tester, button(), admin: false, overrides: [access(_locked)]);
      await tester.tap(find.byTooltip('Aufs Gerät laden'));
      await tester.pumpAndSettle();
      expect(find.text('Offline-Hören mit Premium'), findsOneWidget);
      expect(find.text('Musik aufs Gerät laden und ohne Internet hören gibt es mit Premium.'), findsOneWidget);
      expect(find.text('Später'), findsOneWidget);
      expect(containerOf(tester).read(offlineProvider).collections, isEmpty);
      await tester.tap(find.text('Premium ansehen'));
      await tester.pumpAndSettle();
      expect(find.text('Navigiert: /settings/premium'), findsOneWidget);
      expectNoErrors(tester);
    });

    testWidgets('gesperrt, „Später“: nichts passiert', (tester) async {
      await pumpScreen(tester, button(), admin: false, overrides: [access(_locked)]);
      await tester.tap(find.byTooltip('Aufs Gerät laden'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Später'));
      await tester.pumpAndSettle();
      expect(find.text('Offline-Hören mit Premium'), findsNothing);
      expect(find.byTooltip('Aufs Gerät laden'), findsOneWidget);
      expect(containerOf(tester).read(offlineProvider).collections, isEmpty);
    });

    testWidgets('gesperrt und der Premium-Bereich ist abgeschaltet: nur „OK“ und der Verweis auf den Betreiber', (tester) async {
      await pumpScreen(tester, button(),
          admin: false, config: const AppConfig(premiumEnabled: false), overrides: [access(_locked)]);
      // In der App sind die Einstellungen längst geladen (die Startseite liest sie)
      containerOf(tester).listen(appConfigProvider, (_, _) {});
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byTooltip('Aufs Gerät laden'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Frag den Betreiber deines Servers.'), findsOneWidget);
      expect(find.text('Premium ansehen'), findsNothing);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.text('Offline-Hören mit Premium'), findsNothing);
    });

    testWidgets('Stand wird noch geprüft: „Einen Moment“', (tester) async {
      await pumpScreen(tester, button(), admin: false, overrides: [access(_checking)]);
      await tester.tap(find.byTooltip('Aufs Gerät laden'));
      await tester.pumpAndSettle();
      expect(find.text('Einen Moment'), findsOneWidget);
      expect(find.text('Dein Premium-Stand wird noch geprüft. Bitte versuch es gleich noch einmal.'), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(containerOf(tester).read(offlineProvider).collections, isEmpty);
    });

    for (final channel in AppChannel.values) {
      testWidgets('Schalter aus (${channel.id}): kein Dialog, der Download startet wie bisher', (tester) async {
        final api = await pumpScreen(tester, button(), admin: false, channel: channel);
        await tester.tap(find.byTooltip('Aufs Gerät laden'));
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(find.text('Offline-Hören mit Premium'), findsNothing);
        expect(find.text('Einen Moment'), findsNothing);
        expect(containerOf(tester).read(offlineProvider).collections.keys, ['album:7']);
        // Meldung wie bisher (je nach Verbindung „… werden aufs Handy geladen“ oder „… sobald du im WLAN bist“)
        expect(find.descendant(of: find.byType(SnackBar), matching: find.textContaining('geladen')), findsOneWidget);
        expect(api.calls, isNot(contains('premium')));
        expectNoErrors(tester);
      });
    }

    testWidgets('mit bestätigtem Premium: kein Dialog', (tester) async {
      await pumpScreen(tester, button(),
          admin: false, overrides: [access(const OfflineAccessState(OfflineAccess.allowed, daysLeft: 7))]);
      await tester.tap(find.byTooltip('Aufs Gerät laden'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Offline-Hören mit Premium'), findsNothing);
      expect(containerOf(tester).read(offlineProvider).collections.keys, ['album:7']);
    });

    testWidgets('Titel-Menü: „Aufs Handy laden“ zeigt gesperrt den Dialog statt zu laden', (tester) async {
      final track = sampleTracks(1).single;
      await pumpScreen(
        tester,
        Scaffold(
          body: Consumer(
            builder: (context, ref, _) =>
                TextButton(onPressed: () => showTrackMenu(context, ref, track), child: const Text('Menü')),
          ),
        ),
        admin: false,
        overrides: [access(_locked)],
      );
      await tester.tap(find.text('Menü'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Aufs Handy laden (offline)'));
      await tester.tap(find.text('Aufs Handy laden (offline)'));
      await tester.pumpAndSettle();
      expect(find.text('Offline-Hören mit Premium'), findsOneWidget);
      expect(find.text('Wird aufs Handy geladen'), findsNothing);
      await tester.tap(find.text('Premium ansehen'));
      await tester.pumpAndSettle();
      expect(find.text('Navigiert: /settings/premium'), findsOneWidget);
      expectNoErrors(tester);
    });

    testWidgets('Titel-Menü ohne Sperre: lädt wie bisher', (tester) async {
      final track = sampleTracks(1).single;
      await pumpScreen(
        tester,
        Scaffold(
          body: Consumer(
            builder: (context, ref, _) =>
                TextButton(onPressed: () => showTrackMenu(context, ref, track), child: const Text('Menü')),
          ),
        ),
        admin: false,
      );
      await tester.tap(find.text('Menü'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Aufs Handy laden (offline)'));
      await tester.tap(find.text('Aufs Handy laden (offline)'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Offline-Hören mit Premium'), findsNothing);
      expect(find.text('Wird aufs Handy geladen'), findsOneWidget);
      expectNoErrors(tester);
    });

    testWidgets('Mix: der Pfeil „Aufs Handy laden“ zeigt gesperrt den Dialog', (tester) async {
      await pumpScreen(tester, const MixScreen(mixKey: 'genre:Rock'), admin: false, overrides: [access(_locked)]);
      await tester.tap(find.byTooltip('Aufs Handy laden'));
      await tester.pumpAndSettle();
      expect(find.text('Offline-Hören mit Premium'), findsOneWidget);
      expect(find.text('Wird aufs Handy geladen'), findsNothing);
    });

    testWidgets('„Auf diesem Gerät“: Hinweisband gesperrt mit „Premium ansehen“', (tester) async {
      await pumpScreen(tester, const OfflineScreen(), admin: false, overrides: [access(_locked)]);
      expect(find.text('Offline-Hören gibt es mit Premium.'), findsOneWidget);
      await tester.tap(find.text('Premium ansehen'));
      await tester.pumpAndSettle();
      expect(find.text('Navigiert: /settings/premium'), findsOneWidget);
      expectNoErrors(tester);
    });

    testWidgets('„Auf diesem Gerät“: „Aktualisieren“ einer Sammlung zeigt bei unklarem Stand den Dialog', (tester) async {
      final api = await pumpScreen(tester, const OfflineScreen(),
          admin: false, offlineState: offlineWithTracks(), overrides: [access(_checking)]);
      expect(find.textContaining('Dein Premium-Stand wird noch geprüft.'), findsOneWidget);
      api.calls.clear();
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 400));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100)); // Ladekreise drehen sich endlos
      }
      expect(find.text('Einen Moment'), findsOneWidget);
      expect(api.calls, isNot(contains('playlist')), reason: 'ohne Berechtigung wird nichts abgeglichen');
    });

    testWidgets('Hinweisband: bald abgelaufen (≤ 2 Tage) bittet darum, online zu gehen; sonst ist nichts zu sehen', (tester) async {
      await pumpScreen(tester, const OfflineScreen(),
          admin: false, overrides: [access(const OfflineAccessState(OfflineAccess.allowed, daysLeft: 2))]);
      expect(
        find.text('Offline-Musik ist noch 2 Tage verfügbar. Bitte geh einmal online, damit dein Premium geprüft werden kann.'),
        findsOneWidget,
      );
      expect(OfflineAccessBanner.textFor(const OfflineAccessState(OfflineAccess.allowed, daysLeft: 1)),
          startsWith('Offline-Musik ist noch 1 Tag verfügbar.'));
      expect(OfflineAccessBanner.textFor(const OfflineAccessState(OfflineAccess.allowed, daysLeft: 3)), isNull);
      expect(OfflineAccessBanner.textFor(const OfflineAccessState(OfflineAccess.free)), isNull);
    });

    for (final channel in AppChannel.values) {
      testWidgets('Schalter aus (${channel.id}): „Auf diesem Gerät“ und Einstellungen ohne Hinweisband', (tester) async {
        await pumpScreen(tester, const OfflineScreen(), admin: false, channel: channel, offlineState: offlineWithTracks());
        expect(find.byType(OfflineAccessBanner, skipOffstage: false), findsOneWidget);
        expect(find.textContaining('Premium'), findsNothing);
        expectNoErrors(tester);
      });
    }

    testWidgets('Einstellungen: Hinweis unter „Offline“, wenn gesperrt', (tester) async {
      await pumpScreen(tester, const SettingsScreen(), admin: false, overrides: [access(_locked)]);
      await tester.scrollUntilVisible(find.text('Offline-Hören gibt es mit Premium.'), 300,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('Offline-Hören gibt es mit Premium.'), findsOneWidget);
      expectNoErrors(tester);
    });

    testWidgets('nach dem Löschen erscheint der Hinweis einmal', (tester) async {
      await pumpScreen(
        tester,
        const OfflineWipeNoticeListener(child: Scaffold(body: Text('Start'))),
        admin: false,
      );
      final c = containerOf(tester);
      c.read(offlineWipeNoticeProvider.notifier).show(offlineWipeMessage(_locked));
      await tester.pumpAndSettle();
      expect(find.text('Offline-Musik entfernt'), findsOneWidget);
      expect(find.text('Dein Premium ist abgelaufen – die Offline-Musik wurde von diesem Gerät entfernt.'), findsOneWidget);
      expect(c.read(offlineWipeNoticeProvider), isNull, reason: 'einmalig');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.text('Offline-Musik entfernt'), findsNothing);
      expectNoErrors(tester);
    });

    testWidgets('Server weist das Abspielen mit 426 ab: Dialog „Bitte aktualisiere die App.“, einmal', (tester) async {
      await pumpScreen(
        tester,
        const OfflineWipeNoticeListener(child: Scaffold(body: Text('Start'))),
        admin: false,
      );
      final c = containerOf(tester);
      c.read(updateRequiredNoticeProvider.notifier).show();
      await tester.pumpAndSettle();
      expect(find.text('Bitte aktualisiere die App.'), findsOneWidget);
      expect(c.read(updateRequiredNoticeProvider), isFalse, reason: 'einmalig');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.text('Bitte aktualisiere die App.'), findsNothing);
      expectNoErrors(tester);
    });
  });

  group('Premium-Seite', () {
    const billingConfig = AppConfig(
      offlineRequiresPremium: true,
      billingEnabled: true,
      billingProductIds: ['premium_monat'],
    );

    testWidgets('ohne neue Schalter (GitHub und Play): Seite wie bisher – Stand, Werbe-Satz, Code einlösen', (tester) async {
      for (final channel in AppChannel.values) {
        var created = 0;
        await pumpScreen(tester, const PremiumScreen(), admin: false, channel: channel, overrides: [
          purchaseGatewayProvider.overrideWith((ref) {
            created++;
            return FakePurchaseGateway();
          }),
        ]);
        expect(find.text('Kein Premium'), findsOneWidget);
        expect(find.text('Mit Premium siehst du keine Werbung.'), findsOneWidget);
        expect(find.text('Code einlösen'), findsOneWidget);
        expect(find.text('Selfify Premium'), findsNothing);
        expect(find.text('Premium abonnieren'), findsNothing);
        expect(find.text('Käufe wiederherstellen'), findsNothing);
        expect(created, 0, reason: 'das Kauf-Paket wird nie angefasst');
        expectNoErrors(tester);
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('Texte des Betreibers: Überschrift, Beschreibung und Vorteile', (tester) async {
      await pumpScreen(
        tester,
        const PremiumScreen(),
        admin: false,
        config: const AppConfig(
          offlineRequiresPremium: true,
          premiumHeadline: 'Familien-Premium',
          premiumDescription: 'Für alle, die unterwegs hören. 0,99 € im Monat.',
          premiumBenefits: ['Musik fürs Auto', 'Hören im Funkloch'],
        ),
      );
      expect(find.text('Familien-Premium'), findsOneWidget);
      expect(find.text('Für alle, die unterwegs hören. 0,99 € im Monat.'), findsOneWidget);
      expect(find.text('Musik fürs Auto'), findsOneWidget);
      expect(find.text('Hören im Funkloch'), findsOneWidget);
      expect(find.text('Mit Premium kannst du Musik aufs Gerät laden.'), findsOneWidget);
      expect(find.text('Mit Premium siehst du keine Werbung.'), findsNothing);
      expectNoErrors(tester);
    });

    testWidgets('ohne Texte: Vorteile ergeben sich aus den Schaltern', (tester) async {
      final api = FakeApi(admin: false)..premiumStatus = premium();
      await pumpScreen(tester, const PremiumScreen(),
          api: api,
          admin: false,
          channel: AppChannel.play,
          config: const AppConfig(offlineRequiresPremium: true, adsEnabled: true));
      expect(find.text('Selfify Premium'), findsOneWidget);
      expect(find.text('Musik aufs Gerät laden und offline hören'), findsOneWidget);
      expect(find.text('Keine Werbung'), findsOneWidget);
      expect(find.text('Offline-Hören ist freigeschaltet.'), findsOneWidget);
      channelOverride = AppChannel.full;
      expect(premiumBenefitsFor(const AppConfig(offlineRequiresPremium: true, adsEnabled: true)),
          ['Musik aufs Gerät laden und offline hören'], reason: 'Werbung gibt es nur in der Play-Version');
      expect(premiumBenefitsFor(const AppConfig()), isEmpty);
    });

    test('Abo-Zeile je Zustand', () {
      final until = DateTime.utc(2026, 12, 11, 9);
      String? label(String state, {bool renew = false}) =>
          playSubscriptionLabel(PlaySubscription(productId: 'premium_monat', state: state, expiresAt: until, autoRenewing: renew));
      expect(label('active', renew: true), 'Abo über Google Play – verlängert sich am 11. Dez. 2026');
      expect(label('canceled'), 'Abo gekündigt – Premium bis 11. Dez. 2026');
      expect(label('grace'), 'Zahlungsproblem – bitte in Google Play prüfen');
      expect(label('on_hold'), 'Zahlungsproblem – bitte in Google Play prüfen');
      expect(label('paused'), 'Abo pausiert');
      expect(label('pending'), 'Zahlung noch offen');
      expect(label('irgendwas'), isNull);
      expect(playSubscriptionUrl('premium_monat'),
          'https://play.google.com/store/account/subscriptions?sku=premium_monat&package=de.selfify.selfify.play');
    });

    testWidgets('laufendes Abo: Zeile mit „Abo verwalten“ (öffnet Google Play), kein Kaufknopf', (tester) async {
      final links = <String>[];
      final gateway = FakePurchaseGateway();
      final api = FakeApi(admin: false)
        ..premiumStatus = PremiumStatus(
          active: true,
          until: DateTime.utc(2026, 12, 11, 9),
          offlineRequiresPremium: true,
          checkedAt: _now,
          play: PlaySubscription(
              productId: 'premium_monat', state: 'active', expiresAt: DateTime.utc(2026, 12, 11, 9), autoRenewing: true),
        );
      await pumpScreen(tester, const PremiumScreen(), api: api, admin: false, channel: AppChannel.play, config: billingConfig, overrides: [
        purchaseGatewayProvider.overrideWithValue(gateway),
        linkOpenerProvider.overrideWithValue((url) async {
          links.add(url);
          return true;
        }),
      ]);
      expect(find.text('Abo über Google Play – verlängert sich am 11. Dez. 2026'), findsOneWidget);
      expect(find.textContaining('abonnieren'), findsOneWidget, reason: 'nur die Überschrift der Kaufkarte');
      expect(find.text('Monatlich abonnieren'), findsNothing);
      expect(find.text('Käufe wiederherstellen'), findsOneWidget);
      await tester.tap(find.text('Abo verwalten'));
      await tester.pump();
      expect(links.single, contains('sku=premium_monat'));
      expectNoErrors(tester);
    });

    testWidgets('Play-Version, Kauf eingeschaltet: Preis aus dem Store, Kaufen geht an den Store mit der Benutzer-ID', (tester) async {
      final gateway = FakePurchaseGateway();
      final api = FakeApi(admin: false)..premiumStatus = premium(allowed: false);
      await pumpScreen(tester, const PremiumScreen(),
          api: api,
          admin: false,
          channel: AppChannel.play,
          config: billingConfig,
          overrides: [purchaseGatewayProvider.overrideWithValue(gateway)]);
      expect(find.text('Monatlich abonnieren'), findsOneWidget);
      expect(
        find.text('Abo über Google Play. Verlängert sich automatisch, bis du kündigst. Kündigen und Zahlungsart ändern kannst '
            'du jederzeit in Google Play. Beim Wechsel der Laufzeit rechnet Google die restliche Zeit an.'),
        findsOneWidget,
      );
      expect(find.text('Code einlösen'), findsOneWidget, reason: 'Codes gehen weiterhin');
      gateway.onBuy = (product) => bought('token-kauf-0001');
      await tester.tap(find.text('Monatlich abonnieren'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(gateway.log, contains('buy:monatlich:1'));
      expect(api.calls, contains('verify:premium_monat:token-kauf-0001'));
      expect(find.text('Premium ist freigeschaltet. Danke!'), findsOneWidget);
      expect(find.text('Premium bis 10. Dez. 2026'), findsOneWidget);
      expect(find.text('Monatlich abonnieren'), findsNothing, reason: 'mit laufendem Abo gibt es nichts zu kaufen');
      expectNoErrors(tester);
    });

    testWidgets('GitHub-Version: kein Kaufknopf, auch wenn der Server den Kauf meldet – das Kauf-Paket bleibt unberührt', (tester) async {
      var created = 0;
      await pumpScreen(tester, const PremiumScreen(), admin: false, channel: AppChannel.full, config: billingConfig, overrides: [
        purchaseGatewayProvider.overrideWith((ref) {
          created++;
          return FakePurchaseGateway();
        }),
      ]);
      expect(find.text('Premium abonnieren'), findsNothing);
      expect(find.textContaining('abonnieren'), findsNothing);
      expect(find.text('Käufe wiederherstellen'), findsNothing);
      expect(find.text('Code einlösen'), findsOneWidget);
      expect(created, 0);
      expect(containerOfScaffold(tester).read(billingVisibleProvider), isFalse);
      expectNoErrors(tester);
    });

    testWidgets('Play-Version, aber Kauf ausgeschaltet oder Premium-Bereich abgeschaltet: keine Kaufkarte', (tester) async {
      for (final config in const [
        AppConfig(offlineRequiresPremium: true),
        AppConfig(billingEnabled: true), // ohne Produkt-ID
        AppConfig(billingEnabled: true, billingProductIds: ['premium_monat'], premiumEnabled: false),
      ]) {
        var created = 0;
        await pumpScreen(tester, const PremiumScreen(), admin: false, channel: AppChannel.play, config: config, overrides: [
          purchaseGatewayProvider.overrideWith((ref) {
            created++;
            return FakePurchaseGateway();
          }),
        ]);
        expect(find.text('Premium abonnieren'), findsNothing);
        expect(created, 0);
        await tester.pumpWidget(const SizedBox());
      }
    });

    test('Kauf-Zugang: nur Play-Version auf Android', () {
      addTearDown(() {
        channelOverride = null;
        debugDefaultTargetPlatformOverride = null;
      });
      channelOverride = AppChannel.full;
      final github = ProviderContainer();
      expect(github.read(purchaseGatewayProvider), isNull);
      github.dispose();
      channelOverride = AppChannel.play;
      for (final platform in [TargetPlatform.windows, TargetPlatform.iOS]) {
        debugDefaultTargetPlatformOverride = platform;
        final c = ProviderContainer();
        expect(c.read(purchaseGatewayProvider), isNull, reason: '$platform');
        c.dispose();
      }
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('Kauf über Google Play (nachgebauter Store)', () {
    late FakePurchaseGateway gateway;
    late FakeApi api;

    const config = AppConfig(offlineRequiresPremium: true, billingEnabled: true, billingProductIds: ['premium_monat']);

    setUp(() {
      channelOverride = AppChannel.play;
      BillingController.restoreTimeout = const Duration(milliseconds: 120);
      gateway = FakePurchaseGateway();
      api = FakeApi(admin: false)..premiumStatus = premium(allowed: false);
    });

    tearDown(() {
      channelOverride = null;
      BillingController.restoreTimeout = const Duration(seconds: 10);
    });

    Future<ProviderContainer> start({Map<String, Object> prefs = const {}, AppConfig cfg = config, bool loggedOut = false}) async {
      SharedPreferences.setMockInitialValues(prefs);
      final c = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(await SharedPreferences.getInstance()),
        authProvider.overrideWith(() => loggedOut ? _LoggedOut(api) : FakeAuth(api)),
        appConfigProvider.overrideWith(() => FakeAppConfig(cfg)),
        connectivityProvider.overrideWith((ref) => Stream.value([ConnectivityResult.wifi])),
        clockProvider.overrideWithValue(() => _now),
        purchaseGatewayProvider.overrideWithValue(gateway),
      ]);
      addTearDown(c.dispose);
      c.listen(authProvider, (_, _) {});
      c.listen(appConfigProvider, (_, _) {});
      c.listen(premiumProvider, (_, _) {});
      c.listen(offlineAccessProvider, (_, _) {});
      c.listen(billingProvider, (_, _) {});
      await c.read(authProvider.future);
      await c.read(appConfigProvider.future);
      await settle(60);
      return c;
    }

    List<dynamic> remembered(ProviderContainer c) =>
        jsonDecode(c.read(sharedPreferencesProvider).getString(BillingController.unverifiedKey) ?? '[]') as List;

    test('Laden: Produkte mit Preis aus dem Store', () async {
      final c = await start();
      final state = c.read(billingProvider);
      expect(c.read(billingVisibleProvider), isTrue);
      expect(state.loading, isFalse);
      expect(state.available, isTrue);
      expect(state.products.single.price, '0,99 €');
      expect(state.error, isNull);
      expect(gateway.log, containsAllInOrder(['isAvailable', 'load:premium_monat']));
    });

    test('Store nicht verfügbar / Produkt fehlt: verständliche Meldung', () async {
      gateway.available = false;
      var c = await start();
      expect(c.read(billingProvider).error, 'Google Play ist auf diesem Gerät gerade nicht verfügbar.');
      expect(c.read(billingProvider).products, isEmpty);
      c.dispose();

      gateway = FakePurchaseGateway()..products = const [];
      c = await start();
      expect(c.read(billingProvider).error, 'Das Abo wurde im Play Store nicht gefunden (premium_monat).');
    });

    test('Kauf erfolgreich: Server prüft, Premium ist da, Kauf wird abgeschlossen, Offline-Hören ist frei', () async {
      final c = await start();
      await waitFor(() => c.read(offlineAccessProvider).access == OfflineAccess.locked, 'vorher gesperrt');
      api.verifyResult = PlayVerifyResult(result: 'active', premium: premium());
      gateway.onBuy = (product) => bought('token-kauf-0001');

      await c.read(billingProvider.notifier).buy(c.read(billingProvider).plans.single);
      await waitFor(() => c.read(billingProvider).notice != null, 'Rückmeldung');

      expect(gateway.log, contains('buy:monatlich:1'), reason: 'accountId = Benutzer-ID');
      expect(api.calls, contains('verify:premium_monat:token-kauf-0001'));
      expect(c.read(billingProvider).notice, 'Premium ist freigeschaltet. Danke!');
      expect(c.read(billingProvider).busy, isFalse);
      expect(c.read(billingProvider).error, isNull);
      expect(c.read(premiumProvider).value!.active, isTrue);
      expect(gateway.completed.single.token, 'token-kauf-0001');
      expect(remembered(c), isEmpty);
      await waitFor(() => c.read(offlineAccessProvider).access == OfflineAccess.allowed, 'Offline-Hören frei');
    });

    test('Kauf abgebrochen: nichts passiert, kein Aufruf beim Server', () async {
      final c = await start();
      gateway.onBuy = (product) => bought('', status: StorePurchaseStatus.cancelled);
      await c.read(billingProvider.notifier).buy(c.read(billingProvider).plans.single);
      await settle(60);
      final state = c.read(billingProvider);
      expect(state.busy, isFalse);
      expect(state.notice, isNull);
      expect(state.error, isNull);
      expect(api.calls.where((call) => call.startsWith('verify')), isEmpty);
      expect(c.read(premiumProvider).value!.active, isFalse);
      expect(gateway.completed, isEmpty);
    });

    test('Fehler im Store: Meldung, kein Premium', () async {
      final c = await start();
      gateway.onBuy = (product) => bought('', status: StorePurchaseStatus.failed, message: 'BillingResponse.billingUnavailable');
      await c.read(billingProvider.notifier).buy(c.read(billingProvider).plans.single);
      await settle(60);
      expect(c.read(billingProvider).error, 'Der Kauf hat nicht geklappt: BillingResponse.billingUnavailable');
      expect(c.read(billingProvider).busy, isFalse);
      expect(api.calls.where((call) => call.startsWith('verify')), isEmpty);
      expect(c.read(premiumProvider).value!.active, isFalse);
    });

    test('Kaufdialog lässt sich nicht öffnen: Meldung', () async {
      final c = await start();
      gateway.buyError = StateError('Kein Google-Konto');
      await c.read(billingProvider.notifier).buy(c.read(billingProvider).plans.single);
      expect(c.read(billingProvider).error, 'Der Kauf hat nicht geklappt: Kein Google-Konto');
      expect(c.read(billingProvider).busy, isFalse);
    });

    test('„schon gekauft“: stattdessen wird wiederhergestellt', () async {
      final c = await start();
      gateway
        ..onBuy = ((product) => bought('', status: StorePurchaseStatus.failed, message: 'BillingResponse.itemAlreadyOwned'))
        ..restorable = [bought('token-alt-00001', status: StorePurchaseStatus.restored)];
      await c.read(billingProvider.notifier).buy(c.read(billingProvider).plans.single);
      await waitFor(() => c.read(billingProvider).notice != null, 'Rückmeldung');
      expect(gateway.log, contains('restore:1'));
      expect(api.calls, contains('verify:premium_monat:token-alt-00001'));
      expect(c.read(billingProvider).notice, 'Premium wiederhergestellt.');
      expect(c.read(billingProvider).error, isNull);
      expect(c.read(premiumProvider).value!.active, isTrue);
    });

    test('Zahlung im Store noch offen: Hinweis – und der Server erfährt vom Kauf, damit er ihn selbst weiter prüft', () async {
      final c = await start();
      api.verifyResult = PlayVerifyResult(result: 'pending', premium: premium(allowed: false));
      gateway.onBuy = (product) => bought('token-offen-001', status: StorePurchaseStatus.pending);
      await c.read(billingProvider.notifier).buy(c.read(billingProvider).plans.single);
      await waitFor(() => api.calls.contains('verify:premium_monat:token-offen-001'), 'dem Server gemeldet');
      await settle(60);
      expect(c.read(billingProvider).notice,
          'Die Zahlung ist noch offen. Sobald Google sie bestätigt, wird Premium freigeschaltet.');
      expect(c.read(billingProvider).busy, isFalse);
      expect(c.read(billingProvider).error, isNull);
      expect(gateway.completed, isEmpty, reason: 'ein offener Kauf wird nicht abgeschlossen');
      expect(c.read(premiumProvider).value!.active, isFalse);
    });

    test('Zahlung offen und der Server ist nicht erreichbar: der Kauf wird gemerkt, der Hinweis bleibt', () async {
      final c = await start();
      api.verifyError = const ApiException('Keine Verbindung zum Server.');
      gateway.onBuy = (product) => bought('token-offen-003', status: StorePurchaseStatus.pending);
      await c.read(billingProvider.notifier).buy(c.read(billingProvider).plans.single);
      await waitFor(() => remembered(c).isNotEmpty, 'gemerkt');
      expect(c.read(billingProvider).notice, startsWith('Die Zahlung ist noch offen.'));
      expect(c.read(billingProvider).error, isNull);
    });

    test('App-Start: ein bezahlter Kauf, den der Store der App nie gemeldet hat, wird still nachgeholt', () async {
      // z. B. App während der Zahlung beendet (Bank-App): Google Play liefert den Kauf nur auf Nachfrage
      gateway.restorable = [bought('token-liegen-01', status: StorePurchaseStatus.restored)];
      final c = await start();
      await waitFor(() => c.read(premiumProvider).value?.active ?? false, 'Premium nachgeholt');
      expect(gateway.log, contains('restore:1'), reason: 'die App fragt den Store selbst');
      expect(api.calls, contains('verify:premium_monat:token-liegen-01'));
      expect(gateway.completed.single.token, 'token-liegen-01');
      expect(c.read(billingProvider).busy, isFalse);
      expect(c.read(billingProvider).error, isNull);
    });

    test('App-Start ohne Käufe im Store: keine Meldung, kein Warten', () async {
      final c = await start();
      await settle(250); // länger als die Wartezeit von „Käufe wiederherstellen“
      expect(gateway.log, contains('restore:1'));
      final state = c.read(billingProvider);
      expect(state.notice, isNull, reason: 'kein „kein Kauf gefunden“ ohne Zutun');
      expect(state.error, isNull);
      expect(state.busy, isFalse);
    });

    test('stille Abfrage: Kauf eines anderen Kontos – keine Fehlermeldung, und er wird nicht immer wieder gemeldet', () async {
      api.verifyError = const ApiException('Dieser Kauf ist schon mit einem anderen Konto verbunden.', statusCode: 409);
      gateway.restorable = [bought('token-fremd-003', status: StorePurchaseStatus.restored)];
      final c = await start();
      await waitFor(() => api.calls.contains('verify:premium_monat:token-fremd-003'), 'einmal gemeldet');
      await settle(60);
      expect(c.read(billingProvider).error, isNull);
      expect(c.read(billingProvider).notice, isNull);
      expect(gateway.completed, isEmpty);
      await c.read(billingProvider.notifier).catchUp(); // Zurückkehren in die App
      await settle(60);
      expect(api.calls.where((call) => call == 'verify:premium_monat:token-fremd-003'), hasLength(1));
      // ausdrücklich „Käufe wiederherstellen“: dann erfährt der Benutzer den Grund
      await c.read(billingProvider.notifier).restore();
      await waitFor(() => c.read(billingProvider).error != null, 'Fehlermeldung');
      expect(c.read(billingProvider).error, 'Dieser Kauf ist schon mit einem anderen Konto verbunden.');
    });

    test('stille Abfrage: Abo abgelaufen oder Zahlung offen – keine Meldung', () async {
      api.verifyResult = PlayVerifyResult(result: 'inactive', premium: premium(allowed: false));
      gateway.restorable = [bought('token-alt-00009', status: StorePurchaseStatus.restored)];
      final c = await start();
      await waitFor(() => api.calls.contains('verify:premium_monat:token-alt-00009'), 'gemeldet');
      await settle(60);
      expect(c.read(billingProvider).notice, isNull);
      expect(c.read(billingProvider).error, isNull);
    });

    test('der Server kennt schon einen laufenden Kauf: der Store wird nicht bei jedem Start gefragt', () async {
      api.premiumStatus = PremiumStatus(
        active: true,
        offlineRequiresPremium: true,
        checkedAt: _now,
        play: PlaySubscription(
            productId: 'premium_monat', state: 'active', expiresAt: DateTime.utc(2026, 12, 10), autoRenewing: true),
      );
      gateway.restorable = [bought('token-laeuft-01', status: StorePurchaseStatus.restored)];
      final c = await start();
      await settle(100);
      expect(gateway.log.where((entry) => entry.startsWith('restore')), isEmpty);
      expect(api.calls.where((call) => call.startsWith('verify')), isEmpty);
      expect(c.read(billingProvider).products, isNotEmpty);
    });

    test('gemerkter Kauf eines anderen Kontos (oder Servers) bleibt liegen, bis dessen Besitzer wieder angemeldet ist', () async {
      // Benutzer 2 hat gekauft, der Server war nicht erreichbar; jetzt ist Benutzer 1 angemeldet
      api.verifyError = const ApiException('Dieser Kauf ist schon mit einem anderen Konto verbunden.', statusCode: 409);
      final foreign = [
        {'product_id': 'premium_monat', 'token': 'token-von-zwei', 'account': 'https://musik.test|2'},
        {'product_id': 'premium_monat', 'token': 'token-woanders', 'account': 'https://anderer.test|1'},
      ];
      var c = await start(prefs: {BillingController.unverifiedKey: jsonEncode(foreign)});
      await c.read(billingProvider.notifier).catchUp();
      await settle(60);
      expect(api.calls.where((call) => call.startsWith('verify')), isEmpty, reason: 'als falsches Konto nicht melden');
      expect(remembered(c), foreign, reason: 'sonst wäre der Kauf verloren und Google erstattete ihn nach 3 Tagen');
      c.dispose();

      // der Besitzer ist wieder da: sein Kauf wird nachgereicht, der fremde bleibt
      api.verifyError = null;
      gateway = FakePurchaseGateway();
      final own = [
        {'product_id': 'premium_monat', 'token': 'token-von-eins', 'account': 'https://musik.test|1'},
        foreign[1],
      ];
      c = await start(prefs: {BillingController.unverifiedKey: jsonEncode(own)});
      await waitFor(() => c.read(premiumProvider).value?.active ?? false, 'Premium nachgeholt');
      expect(api.calls, contains('verify:premium_monat:token-von-eins'));
      expect(remembered(c), [foreign[1]]);
    });

    test('stille Abfrage meldet den gemerkten Kauf eines anderen Kontos und der Server lehnt ab: der Eintrag bleibt liegen',
        () async {
      // Benutzer 2 (und dieser Benutzer an einem anderen Server) haben mit demselben Google-Konto gekauft, der
      // Server war nicht erreichbar. Jetzt ist Benutzer 1 angemeldet; der Store meldet die Käufe des Google-Kontos.
      api.verifyError = const ApiException('Dieser Kauf ist schon mit einem anderen Konto verbunden.', statusCode: 409);
      final foreign = [
        {'product_id': 'premium_monat', 'token': 'token-von-zwei', 'account': 'https://musik.test|2'},
        {'product_id': 'premium_monat', 'token': 'token-woanders', 'account': 'https://anderer.test|1'},
      ];
      gateway.restorable = [
        bought('token-von-zwei', status: StorePurchaseStatus.restored),
        bought('token-woanders', status: StorePurchaseStatus.restored),
      ];
      final c = await start(prefs: {BillingController.unverifiedKey: jsonEncode(foreign)});
      await waitFor(
          () => api.calls.where((call) => call.startsWith('verify')).length == 2, 'beide vom Store gemeldet und abgelehnt');
      await settle(60);
      expect(remembered(c), foreign, reason: 'sonst wäre der Kauf für seinen Besitzer verloren (Erstattung nach 3 Tagen)');
      expect(c.read(billingProvider).error, isNull);
      expect(gateway.completed, isEmpty);
    });

    test('stille Abfrage, der Server lehnt ab: der eigene gemerkte Kauf (auch einer ohne Konto-Angabe) wird gestrichen', () async {
      // Der Server ist erst beim Nachreichen nicht erreichbar (Einträge bleiben), lehnt bei der stillen Abfrage dann ab
      api.verifyError = const ApiException('Keine Verbindung zum Server.');
      gateway.restorable = [
        bought('token-eigen-01', status: StorePurchaseStatus.restored),
        bought('token-alt-ohne', status: StorePurchaseStatus.restored),
        bought('token-von-zwei', status: StorePurchaseStatus.restored),
      ];
      final foreign = {'product_id': 'premium_monat', 'token': 'token-von-zwei', 'account': 'https://musik.test|2'};
      final c = await start(prefs: {
        BillingController.unverifiedKey: jsonEncode([
          {'product_id': 'premium_monat', 'token': 'token-eigen-01', 'account': 'https://musik.test|1'},
          {'product_id': 'premium_monat', 'token': 'token-alt-ohne'},
          foreign,
        ]),
      });
      await settle(60);
      expect(remembered(c), hasLength(3), reason: 'Netzfehler: nichts wird gestrichen');
      api.verifyError = const ApiException('Dieser Kauf wurde bei Google Play nicht gefunden.', statusCode: 404);
      gateway.restorable = [];
      // der Store meldet die drei Käufe (Antwort auf eine stille Abfrage)
      for (final token in ['token-eigen-01', 'token-alt-ohne', 'token-von-zwei']) {
        gateway.emit(bought(token, status: StorePurchaseStatus.restored));
      }
      await waitFor(() => remembered(c).length == 1, 'eigene gestrichen');
      await settle(60);
      expect(remembered(c), [foreign]);
    });

    test('„Käufe wiederherstellen“ mit mehreren Käufen: jeder bekommt eine Rückmeldung, nicht nur der erste', () async {
      api = _PerTokenApi({
        'token-abgelaufen': 'inactive',
        'token-fremd-004': const ApiException('Dieser Kauf ist schon mit einem anderen Konto verbunden.', statusCode: 409),
      })
        ..premiumStatus = PremiumStatus(
          offlineRequiresPremium: true,
          offlineAllowed: false,
          checkedAt: _now,
          // der Server kennt schon einen (abgelaufenen) Kauf: Die App fragt den Store nicht von sich aus
          play: PlaySubscription(productId: 'premium_monat', state: 'expired', expiresAt: DateTime.utc(2026, 10, 1), autoRenewing: false),
        );
      final c = await start();
      expect(gateway.log.where((entry) => entry.startsWith('restore')), isEmpty);
      gateway.restorable = [
        bought('token-abgelaufen', status: StorePurchaseStatus.restored),
        bought('token-fremd-004', status: StorePurchaseStatus.restored),
      ];
      await c.read(billingProvider.notifier).restore();
      await waitFor(() => c.read(billingProvider).error != null, 'auch der zweite Kauf meldet sich');
      await settle(60);
      expect(c.read(billingProvider).error, 'Dieser Kauf ist schon mit einem anderen Konto verbunden.');
      expect(c.read(billingProvider).notice, 'Kein laufendes Abo gefunden.');
      expect(c.read(billingProvider).busy, isFalse);
      expect(gateway.completed.map((p) => p.token), ['token-abgelaufen']);
    });

    for (final order in [
      ['token-fremd-005', 'token-laeuft-02'],
      ['token-laeuft-02', 'token-fremd-005'],
      ['token-abgelaufen', 'token-laeuft-02', 'token-fremd-005'],
    ]) {
      test('„Käufe wiederherstellen“, einer von mehreren läuft (${order.join(', ')}): „wiederhergestellt“, kein Fehler', () async {
        api = _PerTokenApi({
          'token-abgelaufen': 'inactive',
          'token-laeuft-02': 'active',
          'token-fremd-005': const ApiException('Dieser Kauf ist schon mit einem anderen Konto verbunden.', statusCode: 409),
        })
          ..premiumStatus = premium(allowed: false);
        final c = await start();
        await settle(60); // die stille Abfrage beim Start ist durch (der Store kannte da noch nichts)
        gateway.restorable = [for (final token in order) bought(token, status: StorePurchaseStatus.restored)];
        await c.read(billingProvider.notifier).restore();
        await waitFor(
            () => api.calls.where((call) => call.startsWith('verify')).length == order.length &&
                c.read(billingProvider).notice == 'Premium wiederhergestellt.',
            'alle geprüft');
        await settle(200); // auch die Wartezeit von „Käufe wiederherstellen“ ändert nichts mehr
        final state = c.read(billingProvider);
        expect(state.notice, 'Premium wiederhergestellt.');
        expect(state.error, isNull, reason: 'der fremde Kauf überschreibt den Erfolg nicht');
        expect(state.busy, isFalse);
        expect(c.read(premiumProvider).value!.active, isTrue);
        expect(gateway.completed.map((p) => p.token), contains('token-laeuft-02'));
        expect(gateway.completed.map((p) => p.token), isNot(contains('token-fremd-005')));
      });
    }

    test('nach „Käufe wiederherstellen“ fragt die App den Store wieder still: dann gibt es keine Meldungen mehr', () async {
      api = _PerTokenApi({
        'token-fremd-006': const ApiException('Dieser Kauf ist schon mit einem anderen Konto verbunden.', statusCode: 409),
      })
        ..premiumStatus = premium(allowed: false);
      final c = await start();
      await settle(60);
      gateway.restorable = [bought('token-fremd-006', status: StorePurchaseStatus.restored)];
      await c.read(billingProvider.notifier).restore();
      await waitFor(() => c.read(billingProvider).error != null, 'Fehlermeldung');
      c.read(billingProvider.notifier).clearMessages();
      gateway.restorable = [bought('token-fremd-007', status: StorePurchaseStatus.restored)];
      (api as _PerTokenApi).answers['token-fremd-007'] =
          const ApiException('Dieser Kauf ist schon mit einem anderen Konto verbunden.', statusCode: 409);
      await c.read(billingProvider.notifier).catchUp(); // Zurückkehren in die App
      await waitFor(() => api.calls.contains('verify:premium_monat:token-fremd-007'), 'still gemeldet');
      await settle(60);
      expect(c.read(billingProvider).error, isNull);
      expect(c.read(billingProvider).notice, isNull);
    });

    test('Server meldet „Zahlung offen“: Hinweis, kein Premium, Kauf wird nicht abgeschlossen', () async {
      final c = await start();
      api.verifyResult = PlayVerifyResult(result: 'pending', premium: premium(allowed: false));
      gateway.onBuy = (product) => bought('token-offen-002');
      await c.read(billingProvider.notifier).buy(c.read(billingProvider).plans.single);
      await waitFor(() => c.read(billingProvider).notice != null, 'Rückmeldung');
      expect(c.read(billingProvider).notice, startsWith('Die Zahlung ist noch offen.'));
      expect(gateway.completed, isEmpty);
      expect(c.read(premiumProvider).value!.active, isFalse);
      expect(c.read(offlineAccessProvider).access, OfflineAccess.locked);
    });

    for (final (status, message) in [
      (409, 'Dieser Kauf ist schon mit einem anderen Konto verbunden.'),
      (409, 'Dieser Kauf wurde vom Betreiber gesperrt.'),
      (404, 'Dieser Kauf wurde bei Google Play nicht gefunden.'),
      (400, 'Dieses Produkt gibt es hier nicht.'),
    ]) {
      test('Server lehnt ab ($status „$message“): Meldung des Servers, kein Premium, nicht abgeschlossen, nicht gemerkt', () async {
        final c = await start();
        api.verifyError = ApiException(message, statusCode: status);
        gateway.onBuy = (product) => bought('token-fremd-001');
        await c.read(billingProvider.notifier).buy(c.read(billingProvider).plans.single);
        await waitFor(() => c.read(billingProvider).error != null, 'Fehlermeldung');
        expect(c.read(billingProvider).error, message);
        expect(c.read(billingProvider).busy, isFalse);
        expect(gateway.completed, isEmpty);
        expect(remembered(c), isEmpty);
        expect(c.read(premiumProvider).value!.active, isFalse);
        expect(c.read(offlineAccessProvider).access, OfflineAccess.locked);
      });
    }

    for (final (name, error) in [
      ('Netzfehler', const ApiException('Keine Verbindung zum Server.')),
      ('503 von Google', const ApiException('Google Play ist gerade nicht erreichbar.', statusCode: 503)),
      ('Bremse (429)', const ApiException('Zu viele Versuche.', statusCode: 429)),
    ]) {
      test('$name beim Bestätigen: Kauf wird gemerkt und beim nächsten Start nachgeholt', () async {
        var c = await start();
        api.verifyError = error;
        gateway.onBuy = (product) => bought('token-spaeter-01');
        await c.read(billingProvider.notifier).buy(c.read(billingProvider).plans.single);
        await waitFor(() => c.read(billingProvider).notice != null, 'Rückmeldung');
        expect(c.read(billingProvider).notice, BillingText.unverified);
        expect(c.read(billingProvider).error, isNull);
        expect(gateway.completed, isEmpty);
        expect(remembered(c), [
          {'product_id': 'premium_monat', 'token': 'token-spaeter-01', 'account': 'https://musik.test|1'},
        ]);
        expect(c.read(premiumProvider).value!.active, isFalse);
        final stored = c.read(sharedPreferencesProvider).getString(BillingController.unverifiedKey)!;
        c.dispose();

        // Nächster Start: Der Server ist wieder erreichbar
        api
          ..verifyError = null
          ..calls.clear();
        gateway = FakePurchaseGateway();
        c = await start(prefs: {BillingController.unverifiedKey: stored});
        await waitFor(() => c.read(premiumProvider).value?.active ?? false, 'Premium nachgeholt');
        expect(api.calls, contains('verify:premium_monat:token-spaeter-01'));
        expect(remembered(c), isEmpty);
        expect(c.read(billingProvider).notice, 'Premium ist freigeschaltet. Danke!');
      });
    }

    test('gemerkter Kauf, den der Server endgültig ablehnt, wird gestrichen', () async {
      api.verifyError = const ApiException('Dieser Kauf ist schon mit einem anderen Konto verbunden.', statusCode: 409);
      final c = await start(prefs: {
        BillingController.unverifiedKey: jsonEncode([
          {'product_id': 'premium_monat', 'token': 'token-fremd-002'},
        ]),
      });
      await waitFor(() => api.calls.contains('verify:premium_monat:token-fremd-002'), 'erneut gemeldet');
      await settle(60);
      expect(remembered(c), isEmpty);
      expect(c.read(premiumProvider).value!.active, isFalse);
    });

    test('Wiederherstellen erfolgreich', () async {
      final c = await start();
      gateway.restorable = [bought('token-alt-00002', status: StorePurchaseStatus.restored)];
      await c.read(billingProvider.notifier).restore();
      await waitFor(() => c.read(billingProvider).notice != null, 'Rückmeldung');
      expect(gateway.log, contains('restore:1'));
      expect(c.read(billingProvider).notice, 'Premium wiederhergestellt.');
      expect(c.read(billingProvider).busy, isFalse);
      expect(c.read(premiumProvider).value!.active, isTrue);
      expect(gateway.completed.single.token, 'token-alt-00002');
      await settle(200); // die Wartezeit ändert danach nichts mehr
      expect(c.read(billingProvider).notice, 'Premium wiederhergestellt.');
    });

    test('Wiederherstellen ohne Treffer: nach der Wartezeit „kein Kauf gefunden“', () async {
      final c = await start();
      await c.read(billingProvider.notifier).restore();
      expect(c.read(billingProvider).busy, isTrue);
      await waitFor(() => !c.read(billingProvider).busy, 'Wartezeit um');
      expect(c.read(billingProvider).notice, 'Für dieses Google-Konto wurde kein Kauf gefunden.');
      expect(api.calls.where((call) => call.startsWith('verify')), isEmpty);
    });

    test('Wiederherstellen: Kauf gefunden, aber das Abo läuft nicht mehr', () async {
      final c = await start();
      api.verifyResult = PlayVerifyResult(result: 'inactive', premium: premium(allowed: false));
      gateway.restorable = [bought('token-alt-00003', status: StorePurchaseStatus.restored)];
      await c.read(billingProvider.notifier).restore();
      await waitFor(() => c.read(billingProvider).notice != null, 'Rückmeldung');
      expect(c.read(billingProvider).notice, 'Kein laufendes Abo gefunden.');
      expect(c.read(billingProvider).error, isNull);
      expect(c.read(premiumProvider).value!.active, isFalse);
      expect(gateway.completed.single.token, 'token-alt-00003');
    });

    test('Kauf, der unaufgefordert beim Start gemeldet wird, wird nachgeholt', () async {
      final c = await start();
      gateway.emit(bought('token-nachgeholt'));
      await waitFor(() => c.read(premiumProvider).value?.active ?? false, 'Premium da');
      expect(api.calls, contains('verify:premium_monat:token-nachgeholt'));
      expect(gateway.completed.single.token, 'token-nachgeholt');
    });

    test('GitHub-Version: nichts sichtbar, der Store wird nie angesprochen – auch wenn der Server den Kauf meldet', () async {
      channelOverride = AppChannel.full;
      final c = await start();
      expect(c.read(billingVisibleProvider), isFalse);
      final state = c.read(billingProvider);
      expect(state.loading, isFalse);
      expect(state.products, isEmpty);
      await c.read(billingProvider.notifier).restore();
      await c.read(billingProvider.notifier).load();
      expect(gateway.log, isEmpty);
      expect(api.calls.where((call) => call.startsWith('verify')), isEmpty);
    });

    test('Schalter „Kauf in der App“ aus oder abgemeldet: nichts sichtbar, der Store wird nie angesprochen', () async {
      var c = await start(cfg: const AppConfig(offlineRequiresPremium: true));
      expect(c.read(billingVisibleProvider), isFalse);
      expect(gateway.log, isEmpty);
      c.dispose();
      c = await start(loggedOut: true);
      expect(c.read(billingVisibleProvider), isFalse);
      expect(gateway.log, isEmpty);
    });
  });
}

ProviderContainer containerOfScaffold(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));
