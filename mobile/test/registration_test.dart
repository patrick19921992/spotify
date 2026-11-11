// Selbst-Registrierung: Schnittstelle (register, withdraw, wartendes Konto), „Konto erstellen“ auf der
// Anmeldeseite (Play mit fester Adresse, GitHub über die Prüfung, alter Server), das Formular und die leeren
// Seiten für Konten, für die noch nichts freigeschaltet ist.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:selfify/core/flavor.dart';
import 'package:selfify/core/links.dart';
import 'package:selfify/core/theme.dart';
import 'package:selfify/data/api.dart';
import 'package:selfify/data/models.dart';
import 'package:selfify/state/app_config.dart';
import 'package:selfify/state/auth.dart';
import 'package:selfify/state/registration.dart';
import 'package:selfify/ui/router.dart';
import 'package:selfify/ui/screens/admin_screen.dart';
import 'package:selfify/ui/screens/home_screen.dart';
import 'package:selfify/ui/screens/login_screen.dart';
import 'package:selfify/ui/screens/register_screen.dart';
import 'package:selfify/ui/screens/search_screen.dart';
import 'package:selfify/ui/screens/search_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

// ------------------------------------------------------------------ Hilfen

/// Mitschnitt einer Anfrage an den Test-Server.
typedef Seen = ({String method, String path, Map<String, dynamic> body});

/// Lokaler Server: [answer] bekommt Pfad und Körper und liefert Status, Inhalt und Kopfzeilen.
Future<(HttpServer, List<Seen>)> serveApi(
  (int, Object?, Map<String, String>) Function(String path, Map<String, dynamic> body) answer,
) async {
  final seen = <Seen>[];
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final raw = await utf8.decodeStream(request);
    final body = raw.isEmpty ? <String, dynamic>{} : Map<String, dynamic>.from(jsonDecode(raw) as Map);
    seen.add((method: request.method, path: request.uri.path, body: body));
    final (status, data, headers) = answer(request.uri.path, body);
    request.response.statusCode = status;
    headers.forEach(request.response.headers.set);
    if (data != null) {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(data));
    }
    await request.response.close();
  });
  addTearDown(() => server.close(force: true));
  return (server, seen);
}

String base(HttpServer server) => 'http://127.0.0.1:${server.port}';

Json tokensJson(Json user) => {
      'access_token': 'acc',
      'refresh_token': 'ref',
      'token_type': 'bearer',
      'expires_in': 900,
      'media_token': 'med',
      'media_expires_in': 86400,
      'user': user,
    };

/// Selbst registriertes Konto ohne Freigabe.
Json newcomerJson({List<int> categoryIds = const []}) => {
      ...userJson(id: 9, admin: false, canDownload: false, allCategories: false, categoryIds: categoryIds),
      'username': 'neu',
      'display_name': 'Neu',
      'self_registered': true,
    };

const pendingMessage = 'Dein Konto wurde angelegt und wartet auf Freischaltung durch den Betreiber. '
    'Du kannst dich anmelden, sobald es freigeschaltet ist.';
const loginPendingMessage = 'Dein Konto wartet noch auf Freischaltung durch den Betreiber.';
const conflictMessage = 'Dieser Benutzername ist nicht verfügbar. Bitte wähle einen anderen.';

/// Abgemeldet bei [server]. [loginError]: so scheitert „Anmelden“ (null = wie echt).
class LoggedOutAuth extends FakeAuth {
  final String? server;
  final Object? loginError;
  final logins = <String>[];

  LoggedOutAuth(super.api, {this.server = 'https://musik.test', this.loginError});

  @override
  Future<AuthState> build() async => AuthState(serverUrl: server);

  @override
  Future<void> login(String serverInput, String username, String password) async {
    logins.add('$serverInput|$username|$password');
    final error = loginError;
    if (error != null) throw error;
  }
}

/// Angemeldet mit einem bestimmten Konto (z. B. ohne Freigaben).
class UserAuth extends FakeAuth {
  final Json user;
  UserAuth(super.api, this.user);

  @override
  Future<AuthState> build() async => AuthState(serverUrl: 'https://musik.test', user: User.fromJson(user), api: api);
}

/// Suche ohne Treffer in der Bibliothek.
class NoHitsApi extends EmptyApi {
  NoHitsApi(super.user);

  @override
  Future<SearchResult> search(String q, {int limit = 10, int? categoryId}) async {
    calls.add('search');
    return SearchResult.fromJson(
        {'query': q, 'top_result': null, 'tracks': [], 'artists': [], 'albums': [], 'videos': []});
  }
}

/// Server ohne Inhalte für das angemeldete Konto (eingeschränkt: Startseite und Rubriken leer).
class EmptyApi extends FakeApi {
  final Json user;
  EmptyApi(this.user) : super(admin: user['is_admin'] == true);

  @override
  Future<User> me() async {
    calls.add('me');
    return User.fromJson(user);
  }
  @override
  Future<HomeData> home() async {
    calls.add('home');
    return HomeData.fromJson({'quick_access': [], 'sections': []});
  }

  @override
  Future<List<Category>> categories() async {
    calls.add('categories');
    return [];
  }
}

/// Registrierung ohne Netz: merkt sich Aufrufe, antwortet wie eingestellt.
class FakeGateway extends RegistrationGateway {
  final calls = <String>[];
  RegisterResult Function(String username)? onRegister;
  Object? registerError;
  Object? withdrawError;
  AppConfig appConfig;

  FakeGateway({this.onRegister, this.registerError, this.appConfig = const AppConfig()});

  @override
  Future<RegisterResult> register(String serverUrl,
      {required String username, required String password, String? displayName}) async {
    calls.add('register:$serverUrl|$username|$password|${displayName ?? '-'}');
    final error = registerError;
    if (error != null) throw error;
    return (onRegister ?? (_) => const RegisterResult(pending: true, message: pendingMessage))(username);
  }

  @override
  Future<void> withdraw(String serverUrl, String username, String password) async {
    calls.add('withdraw:$serverUrl|$username|$password');
    final error = withdrawError;
    if (error != null) throw error;
  }

  @override
  Future<AppConfig> config(String serverUrl) async {
    calls.add('config:$serverUrl');
    return appConfig;
  }
}

/// Anmeldung und „Konto erstellen“ als echte Routen (wie in lib/ui/router.dart), Startseite als Platzhalter.
List<RouteBase> authRoutes() => [
      GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
      GoRoute(
        path: '/register',
        builder: (_, s) => RegisterScreen(
          serverUrl: fixedServerUrl ?? s.uri.queryParameters['server'] ?? '',
          mode: s.uri.queryParameters['mode'] == 'open' ? 'open' : 'approval',
        ),
      ),
      GoRoute(path: '/home', builder: (_, _) => const Scaffold(body: Text('Startseite'))),
    ];

Future<FakeApi> pumpAuth(
  WidgetTester tester, {
  required FakeGateway gateway,
  AuthController Function(FakeApi api)? auth,
  String initialLocation = '/login',
  AppChannel? channel,
  AppConfig? config,
  Map<String, Object> prefs = const {},
  List<String>? opened,
}) async {
  // Neuer ProviderScope (sonst behält ein zweiter Aufbau im selben Test den alten Zustand)
  await tester.pumpWidget(const SizedBox());
  // Schlüsselspeicher ohne Gerät (Anmeldung übernehmen speichert die Sitzung)
  FlutterSecureStorage.setMockInitialValues({});
  return pumpScreen(
      tester,
      const SizedBox(),
      routes: authRoutes(),
      initialLocation: initialLocation,
      channel: channel,
      config: config,
      prefs: prefs,
      auth: auth ?? (api) => LoggedOutAuth(api),
      overrides: [
        registrationGatewayProvider.overrideWithValue(gateway),
        linkOpenerProvider.overrideWithValue((url) async {
          opened?.add(url);
          return true;
        }),
      ],
    );
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Finder get createButton => find.widgetWithText(OutlinedButton, 'Konto erstellen');
Finder get submitButton => find.widgetWithText(FilledButton, 'Konto erstellen');
Finder field(String label) => find.widgetWithText(TextField, label);

Future<void> fillForm(WidgetTester tester,
    {String username = 'lena', String password = 'geheim123', String? repeat, String displayName = ''}) async {
  await tester.enterText(field('Benutzername'), username);
  await tester.enterText(field('Anzeigename (optional)'), displayName);
  await tester.enterText(field('Passwort'), password);
  await tester.enterText(field('Passwort wiederholen'), repeat ?? password);
  await tester.pump();
}

Future<void> submit(WidgetTester tester) async {
  await tester.ensureVisible(submitButton);
  await tester.tap(submitButton);
  await settle(tester);
}

void main() {
  tearDown(() {
    channelOverride = null;
    serverUrlOverride = null;
  });

  // ------------------------------------------------------------------ Modelle

  group('Modelle', () {
    test('Konto ohne neue Felder (alter Server): alle Rubriken, nicht wartend, nichts gesperrt', () {
      final user = User.fromJson(userJson(admin: false));
      expect(user.allCategories, isTrue);
      expect(user.categoryIds, isEmpty);
      expect(user.approvalPending, isFalse);
      expect(user.selfRegistered, isFalse);
      expect(user.nothingUnlocked, isFalse);
    });

    test('nothingUnlocked: nur eingeschränkte Nicht-Admins ohne freigegebene Rubrik', () {
      expect(User.fromJson(newcomerJson()).nothingUnlocked, isTrue);
      expect(User.fromJson(newcomerJson(categoryIds: [3])).nothingUnlocked, isFalse);
      expect(User.fromJson(userJson(allCategories: false, categoryIds: [])).nothingUnlocked, isFalse,
          reason: 'Admins sehen immer alles');
      final restored = User.fromJson(User.fromJson(newcomerJson(categoryIds: [1, 3])).toJson());
      expect(restored.categoryIds, [1, 3]);
      expect(restored.allCategories, isFalse);
      expect(restored.selfRegistered, isTrue);
    });

    test('Registrierungs-Modus: fehlt oder unbekannt = aus', () {
      expect(ServerInfo.fromJson({'api_version': 1}).registrationMode, 'off');
      expect(ServerInfo.fromJson({'api_version': 1}).registrationOpen, isFalse);
      expect(ServerInfo.fromJson({'api_version': 1, 'registration_mode': 'approval'}).registrationOpen, isTrue);
      expect(ServerInfo.fromJson({'api_version': 1, 'registration_mode': 'open'}).registrationOpen, isTrue);
      expect(ServerInfo.fromJson({'api_version': 1, 'registration_mode': 'jeder'}).registrationMode, 'off');
      expect(AppConfig.fromJson({}).registrationMode, 'off');
      expect(AppConfig.fromJson({'registration_mode': 'open'}).registrationOpen, isTrue);
      expect(AppConfig.fromJson({'registration_mode': 42}).registrationOpen, isFalse);
    });
  });

  // ------------------------------------------------------------------ Schnittstelle

  group('Schnittstelle', () {
    setUp(() => HttpOverrides.global = null);

    test('register 202: wartet auf Freischaltung, ohne Anmeldung', () async {
      final (server, seen) = await serveApi((path, body) =>
          (202, {'status': 'pending', 'message': pendingMessage, 'tokens': null}, const {}));
      final result = await ApiClient.register(base(server),
          username: 'lena', password: 'geheim123', displayName: ' Lena ', deviceName: 'Test');
      expect(result.pending, isTrue);
      expect(result.message, pendingMessage);
      expect(result.login, isNull);
      expect(seen.single.path, '/api/auth/register');
      expect(seen.single.body, {'username': 'lena', 'password': 'geheim123', 'display_name': 'Lena', 'device_name': 'Test'});
    });

    test('register 201: sofort angemeldet, Token und Konto aus der Antwort', () async {
      final (server, seen) = await serveApi((path, body) => (
            201,
            {'status': 'active', 'message': 'Dein Konto ist eingerichtet.', 'tokens': tokensJson(newcomerJson())},
            const {},
          ));
      final result = await ApiClient.register(base(server), username: 'neu', password: 'geheim123', deviceName: 'Test');
      expect(result.pending, isFalse);
      expect(result.message, 'Dein Konto ist eingerichtet.');
      expect(result.login!.tokens.accessToken, 'acc');
      expect(result.login!.user.username, 'neu');
      expect(result.login!.user.nothingUnlocked, isTrue);
      expect(seen.single.body.containsKey('display_name'), isFalse, reason: 'ohne Anzeigename nicht mitschicken');
    });

    test('register 409: Text des Servers wörtlich', () async {
      final (server, _) = await serveApi((path, body) => (409, {'detail': conflictMessage}, const {}));
      await expectLater(
        ApiClient.register(base(server), username: 'admin', password: 'geheim123', deviceName: 'Test'),
        throwsA(isA<ApiException>()
            .having((e) => e.message, 'message', conflictMessage)
            .having((e) => e.statusCode, 'statusCode', 409)
            .having((e) => e.accountPending, 'accountPending', isFalse)),
      );
    });

    test('Registrierung aus (alter Server oder Modus „aus“): 404 mit Text', () async {
      const off = 'Auf diesem Server kann man sich nicht selbst registrieren.';
      final (server, _) = await serveApi((path, body) => (404, {'detail': off}, const {}));
      await expectLater(
        ApiClient.register(base(server), username: 'lena', password: 'geheim123', deviceName: 'Test'),
        throwsA(isA<ApiException>().having((e) => e.message, 'message', off)),
      );
    });

    test('Anmeldung 403 mit X-Selfify-Account-State: pending → accountPending', () async {
      final (server, _) = await serveApi((path, body) =>
          (403, {'detail': loginPendingMessage}, {'X-Selfify-Account-State': 'pending'}));
      await expectLater(
        ApiClient.login(base(server), 'lena', 'geheim123', deviceName: 'Test'),
        throwsA(isA<ApiException>()
            .having((e) => e.message, 'message', loginPendingMessage)
            .having((e) => e.accountPending, 'accountPending', isTrue)),
      );
    });

    test('Anmeldung 403 ohne Kopfzeile (deaktiviert): kein accountPending', () async {
      final (server, _) = await serveApi((path, body) => (403, {'detail': 'Dieses Konto ist deaktiviert.'}, const {}));
      await expectLater(
        ApiClient.login(base(server), 'lena', 'geheim123', deviceName: 'Test'),
        throwsA(isA<ApiException>().having((e) => e.accountPending, 'accountPending', isFalse)),
      );
    });

    test('withdrawRegistration: 204, Fehler mit Text des Servers', () async {
      var status = 204;
      final (server, seen) = await serveApi((path, body) => (
            status,
            status == 204 ? null : {'detail': 'Benutzername oder Passwort falsch.'},
            const <String, String>{},
          ));
      await ApiClient.withdrawRegistration(base(server), 'lena', 'geheim123');
      expect(seen.single.path, '/api/auth/withdraw');
      expect(seen.single.body, {'username': 'lena', 'password': 'geheim123'});
      status = 401;
      await expectLater(
        ApiClient.withdrawRegistration(base(server), 'lena', 'falsch123'),
        throwsA(isA<ApiException>().having((e) => e.message, 'message', 'Benutzername oder Passwort falsch.')),
      );
    });
  });

  // ------------------------------------------------------------------ Anmeldeseite

  group('Anmeldeseite: „Konto erstellen“', () {
    const fixed = 'https://musik.example.org';

    testWidgets('Play, feste Adresse, Modus approval: Knopf da, Hinweis ohne „Noch kein Konto“', (tester) async {
      serverUrlOverride = fixed;
      await pumpAuth(tester,
          gateway: FakeGateway(), channel: AppChannel.play, config: const AppConfig(registrationMode: 'approval'));
      expect(createButton, findsOneWidget);
      expect(find.text('Passwort vergessen? Frag die Person, die euren Selfify-Server verwaltet.'), findsOneWidget);
      expect(find.textContaining('Noch kein Konto'), findsNothing);
      expectNoErrors(tester);
    });

    testWidgets('Play, feste Adresse, Modus open: Knopf da', (tester) async {
      serverUrlOverride = fixed;
      await pumpAuth(tester,
          gateway: FakeGateway(), channel: AppChannel.play, config: const AppConfig(registrationMode: 'open'));
      expect(createButton, findsOneWidget);
    });

    testWidgets('Play, Modus aus, alter Server (Feld fehlt) oder unbekannter Wert: kein Knopf, alte Texte',
        (tester) async {
      serverUrlOverride = fixed;
      for (final config in [
        const AppConfig(),
        AppConfig.fromJson({'ads_enabled': false}),
        AppConfig.fromJson({'registration_mode': 'irgendwas'}),
      ]) {
        await pumpAuth(tester, gateway: FakeGateway(), channel: AppChannel.play, config: config);
        expect(createButton, findsNothing);
        expect(find.text('Noch kein Konto oder Passwort vergessen? Frag die Person, die euren Selfify-Server verwaltet.'),
            findsOneWidget);
      }
    });

    testWidgets('GitHub: Knopf nur, wenn die Prüfung der Adresse die Registrierung meldet', (tester) async {
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = null);
      Future<void> connect(Map<String, Object?> info) async {
        final (server, _) = (await tester.runAsync(() => serveApi((path, body) => (200, info, const {}))))!;
        // Ohne zuletzt benutzten Server: keine automatische Prüfung
        await pumpAuth(tester, gateway: FakeGateway(), auth: (api) => LoggedOutAuth(api, server: null));
        await tester.enterText(find.byType(TextField).first, base(server));
        await tester.runAsync(() async {
          await tester.tap(find.text('Verbinden'));
          await Future<void>.delayed(const Duration(seconds: 1));
        });
        await settle(tester);
        expect(find.textContaining('Verbunden mit'), findsOneWidget);
      }

      // Alter Server ohne Feld
      await connect({'name': 'Selfify', 'version': '1.0', 'api_version': 1, 'public_url': ''});
      expect(createButton, findsNothing);
      expect(find.text('Passwort vergessen? Frag die Person, die euren Selfify-Server verwaltet.'), findsOneWidget);

      // Registrierung aus
      await connect({'name': 'Selfify', 'version': '1.0', 'api_version': 1, 'registration_mode': 'off'});
      expect(createButton, findsNothing);

      // Registrierung mit Freigabe: Knopf, Text wie bisher; der Knopf öffnet das Formular für genau diesen Server
      await connect({'name': 'Selfify', 'version': '1.0', 'api_version': 1, 'registration_mode': 'open'});
      expect(createButton, findsOneWidget);
      expect(find.text('Passwort vergessen? Frag die Person, die euren Selfify-Server verwaltet.'), findsOneWidget);
      await tester.ensureVisible(createButton);
      await tester.tap(createButton);
      await settle(tester);
      expect(submitButton, findsOneWidget);
      expect(find.text('Nach dem Erstellen muss der Betreiber dein Konto erst freischalten.'), findsNothing,
          reason: 'Modus open: kein Hinweis auf die Freischaltung');
      expectNoErrors(tester);
    });

    testWidgets('Ohne Netz zum Server (Einstellungen nicht geladen): kein Knopf', (tester) async {
      serverUrlOverride = fixed;
      // FakeAppConfig mit Standardwerten = Stand vor der ersten Antwort bzw. nach einem Fehler
      await pumpAuth(tester, gateway: FakeGateway(), channel: AppChannel.play);
      expect(createButton, findsNothing);
    });
  });

  // ------------------------------------------------------------------ Formular

  group('Formular „Konto erstellen“', () {
    const registerUrl = '/register?server=https%3A%2F%2Fmusik.test&mode=approval';

    testWidgets('Felder, Hilfetexte und Hinweise (Modus approval, mit Datenschutz-Link)', (tester) async {
      final opened = <String>[];
      await pumpAuth(tester,
          gateway: FakeGateway(),
          initialLocation: registerUrl,
          config: const AppConfig(registrationMode: 'approval', privacyUrl: 'https://musik.test/datenschutz'),
          opened: opened);
      expect(find.text('Konto erstellen'), findsNWidgets(2)); // Titel und Knopf
      expect(field('Benutzername'), findsOneWidget);
      expect(find.text('3–32 Zeichen: Kleinbuchstaben, Ziffern, Punkt, Bindestrich, Unterstrich'), findsOneWidget);
      expect(field('Anzeigename (optional)'), findsOneWidget);
      expect(field('Passwort'), findsOneWidget);
      expect(find.text('Mindestens 8 Zeichen'), findsOneWidget);
      expect(field('Passwort wiederholen'), findsOneWidget);
      expect(find.text('Nach dem Erstellen muss der Betreiber dein Konto erst freischalten.'), findsOneWidget);
      expect(find.text('Mit dem Erstellen akzeptierst du die Datenschutzerklärung.'), findsOneWidget);
      await tester.ensureVisible(find.widgetWithText(TextButton, 'Datenschutzerklärung'));
      await tester.tap(find.widgetWithText(TextButton, 'Datenschutzerklärung'));
      await tester.pump();
      expect(opened, ['https://musik.test/datenschutz']);
      expectNoErrors(tester);
    });

    testWidgets('Modus open: kein Freischalt-Hinweis; ohne Datenschutz-Adresse Link auf /datenschutz des Servers',
        (tester) async {
      final opened = <String>[];
      await pumpAuth(tester,
          gateway: FakeGateway(),
          initialLocation: '/register?server=https%3A%2F%2Fmusik.test&mode=open',
          config: const AppConfig(registrationMode: 'open'),
          opened: opened);
      expect(find.text('Nach dem Erstellen muss der Betreiber dein Konto erst freischalten.'), findsNothing);
      expect(find.text('Mit dem Erstellen akzeptierst du die Datenschutzerklärung.'), findsOneWidget);
      // Server ohne PUBLIC_URL meldet keine Adresse – der Link führt trotzdem zur Seite des Servers
      await tester.ensureVisible(find.widgetWithText(TextButton, 'Datenschutzerklärung'));
      await tester.tap(find.widgetWithText(TextButton, 'Datenschutzerklärung'));
      await tester.pump();
      expect(opened, ['https://musik.test/datenschutz']);
    });

    test('Passwortlänge zählt Zeichen wie der Server (nicht UTF-16-Einheiten)', () {
      expect(passwordError('abcdef😀'), 'Das Passwort muss mindestens 8 Zeichen lang sein.'); // 7 Zeichen
      expect(passwordError('abcdefg😀'), isNull); // 8 Zeichen
      expect(passwordError('😀' * 128), isNull);
      expect(passwordError('😀' * 129), 'Das Passwort darf höchstens 128 Zeichen lang sein.');
      expect(passwordError('a' * 129), 'Das Passwort darf höchstens 128 Zeichen lang sein.');
    });

    testWidgets('Prüfungen in der App mit den Texten des Vertrags – ohne den Server zu fragen', (tester) async {
      final gateway = FakeGateway();
      await pumpAuth(tester, gateway: gateway, initialLocation: registerUrl);
      const nameError = 'Der Benutzername muss 3–32 Zeichen lang sein und darf nur Kleinbuchstaben, Ziffern, Punkt, '
          'Bindestrich und Unterstrich enthalten.';

      await submit(tester);
      expect(find.text(nameError), findsOneWidget);

      for (final bad in ['ab', '_lena', 'lena maier', 'lena!', 'x' * 33]) {
        await fillForm(tester, username: bad);
        await submit(tester);
        expect(find.text(nameError), findsOneWidget, reason: bad);
      }

      await fillForm(tester, password: 'kurz');
      await submit(tester);
      expect(find.text(nameError), findsNothing);
      expect(find.text('Das Passwort muss mindestens 8 Zeichen lang sein.'), findsOneWidget);

      await fillForm(tester, password: 'geheim123', repeat: 'geheim124');
      await submit(tester);
      expect(find.text('Das Passwort muss mindestens 8 Zeichen lang sein.'), findsNothing);
      expect(find.text('Die Passwörter stimmen nicht überein.'), findsOneWidget);
      expect(gateway.calls.where((c) => c.startsWith('register')), isEmpty);
      expectNoErrors(tester);
    });

    testWidgets('Benutzername wird wie auf dem Server normalisiert (trim + klein)', (tester) async {
      final gateway = FakeGateway(registerError: const ApiException(conflictMessage, statusCode: 409));
      await pumpAuth(tester, gateway: gateway, initialLocation: registerUrl);
      await fillForm(tester, username: '  Lena.M_1 ', displayName: ' Lena ');
      await submit(tester);
      expect(gateway.calls, contains('register:https://musik.test|lena.m_1|geheim123|Lena'));
    });

    testWidgets('Fehler des Servers (409, 429, 503 …) erscheinen wörtlich', (tester) async {
      final gateway = FakeGateway(registerError: const ApiException(conflictMessage, statusCode: 409));
      await pumpAuth(tester, gateway: gateway, initialLocation: registerUrl);
      await fillForm(tester);
      await submit(tester);
      expect(find.text(conflictMessage), findsOneWidget);
      expect(submitButton, findsOneWidget, reason: 'bleibt auf dem Formular');

      gateway.registerError = const ApiException(
          'Gerade warten zu viele neue Konten auf Freischaltung. Bitte versuche es später noch einmal.',
          statusCode: 503);
      await submit(tester);
      expect(find.textContaining('Gerade warten zu viele neue Konten'), findsOneWidget);
      expectNoErrors(tester);
    });

    testWidgets('Modus approval (Play): zurück zur Anmeldung mit Hinweis des Servers, Benutzername vorausgefüllt',
        (tester) async {
      serverUrlOverride = 'https://musik.example.org';
      final gateway = FakeGateway();
      await pumpAuth(tester,
          gateway: gateway,
          channel: AppChannel.play,
          config: const AppConfig(registrationMode: 'approval'),
          auth: (api) => LoggedOutAuth(api, server: 'https://musik.example.org'));
      await tester.ensureVisible(createButton);
      await tester.tap(createButton);
      await settle(tester);
      expect(find.text('Nach dem Erstellen muss der Betreiber dein Konto erst freischalten.'), findsOneWidget);

      await fillForm(tester, username: 'Lena');
      await submit(tester);
      // Play: immer die feste Adresse
      expect(gateway.calls, contains('register:https://musik.example.org|lena|geheim123|-'));
      expect(submitButton, findsNothing);
      expect(find.text('Anmelden'), findsOneWidget);
      expect(find.text(pendingMessage), findsOneWidget);
      final username = tester.widget<TextField>(find.byType(TextField).first).controller!.text;
      expect(username, 'lena');
      expectNoErrors(tester);
    });

    testWidgets('Modus approval ohne Anmeldeseite darunter (Play): weiter zur Anmeldung', (tester) async {
      serverUrlOverride = 'https://musik.example.org';
      final gateway = FakeGateway();
      await pumpAuth(tester,
          gateway: gateway,
          channel: AppChannel.play,
          initialLocation: registerUrl,
          auth: (api) => LoggedOutAuth(api, server: 'https://musik.example.org'));
      await fillForm(tester);
      await submit(tester);
      // Die Adresse aus dem Link zählt in der Play-Version nicht
      expect(gateway.calls, contains('register:https://musik.example.org|lena|geheim123|-'));
      expect(find.text('Anmelden'), findsOneWidget);
      expect(find.text(pendingMessage), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField).first).controller!.text, 'lena');
    });

    testWidgets('Modus open: angemeldet wie nach „Anmelden“, dann Startseite', (tester) async {
      LoggedOutAuth? auth;
      final gateway = FakeGateway(
        onRegister: (username) => RegisterResult(
          pending: false,
          message: 'Dein Konto ist eingerichtet.',
          login: LoginResult(fakeTokens, User.fromJson(newcomerJson())),
        ),
      );
      await pumpAuth(tester,
          gateway: gateway,
          initialLocation: '/register?server=https%3A%2F%2Fmusik.test&mode=open',
          auth: (api) => auth = LoggedOutAuth(api));
      await fillForm(tester, username: 'neu');
      await submit(tester);
      expect(find.text('Startseite'), findsOneWidget);
      final state = auth!.state.value!;
      expect(state.isLoggedIn, isTrue);
      expect(state.serverUrl, 'https://musik.test');
      expect(state.user!.username, 'neu');
      expect(state.api!.tokens.accessToken, 'acc');
      expect(auth!.lastUsername, 'neu');
      expectNoErrors(tester);
    });
  });

  // ------------------------------------------------------------------ Wartendes Konto

  group('Anmeldung eines wartenden Kontos', () {
    const fixed = 'https://musik.example.org';
    const pendingError = ApiException(loginPendingMessage, statusCode: 403, accountPending: true);

    Future<void> loginAs(WidgetTester tester) async {
      // Play: nur Benutzername und Passwort
      await tester.enterText(find.byType(TextField).at(0), 'lena');
      await tester.enterText(find.byType(TextField).at(1), 'geheim123');
      await tester.tap(find.text('Anmelden'));
      await settle(tester);
    }

    testWidgets('Meldung des Servers plus „Registrierung zurückziehen“ – löscht nach Bestätigung', (tester) async {
      serverUrlOverride = fixed;
      final gateway = FakeGateway();
      await pumpAuth(tester,
          gateway: gateway,
          channel: AppChannel.play,
          auth: (api) => LoggedOutAuth(api, server: fixed, loginError: pendingError));
      await loginAs(tester);
      expect(find.text(loginPendingMessage), findsOneWidget);
      final withdraw = find.text('Registrierung zurückziehen');
      expect(withdraw, findsOneWidget);

      // Abbrechen ändert nichts
      await tester.ensureVisible(withdraw);
      await tester.tap(withdraw);
      await settle(tester);
      expect(find.text('Registrierung zurückziehen?'), findsOneWidget);
      expect(find.text('Dein noch nicht freigeschaltetes Konto wird endgültig gelöscht.'), findsOneWidget);
      await tester.tap(find.text('Abbrechen'));
      await settle(tester);
      expect(gateway.calls.where((c) => c.startsWith('withdraw')), isEmpty);

      await tester.tap(withdraw);
      await settle(tester);
      await tester.tap(find.text('Löschen'));
      await settle(tester);
      expect(gateway.calls, contains('withdraw:$fixed|lena|geheim123'));
      expect(find.text('Deine Registrierung wurde zurückgezogen.'), findsOneWidget);
      expect(find.text('Registrierung zurückziehen'), findsNothing);
      expect(find.text(loginPendingMessage), findsNothing);
      expectNoErrors(tester);
    });

    testWidgets('Zurückziehen scheitert: Text des Servers', (tester) async {
      serverUrlOverride = fixed;
      final gateway = FakeGateway()..withdrawError = const ApiException('Benutzername oder Passwort falsch.', statusCode: 401);
      await pumpAuth(tester,
          gateway: gateway,
          channel: AppChannel.play,
          auth: (api) => LoggedOutAuth(api, server: fixed, loginError: pendingError));
      await loginAs(tester);
      await tester.ensureVisible(find.text('Registrierung zurückziehen'));
      await tester.tap(find.text('Registrierung zurückziehen'));
      await settle(tester);
      await tester.tap(find.text('Löschen'));
      await settle(tester);
      expect(find.text('Benutzername oder Passwort falsch.'), findsOneWidget);
      expect(find.text('Deine Registrierung wurde zurückgezogen.'), findsNothing);
    });

    testWidgets('Andere Fehler (z. B. deaktiviert): kein „Registrierung zurückziehen“', (tester) async {
      serverUrlOverride = fixed;
      await pumpAuth(tester,
          gateway: FakeGateway(),
          channel: AppChannel.play,
          auth: (api) => LoggedOutAuth(api,
              server: fixed, loginError: const ApiException('Dieses Konto ist deaktiviert.', statusCode: 403)));
      await loginAs(tester);
      expect(find.text('Dieses Konto ist deaktiviert.'), findsOneWidget);
      expect(find.text('Registrierung zurückziehen'), findsNothing);
    });
  });

  // ------------------------------------------------------------------ Router

  group('Router', () {
    testWidgets('/register ist abgemeldet erreichbar, andere Seiten führen zur Anmeldung', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      late GoRouter router;
      await tester.pumpWidget(ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          // Ohne zuletzt benutzten Server: keine automatische Prüfung auf der Anmeldeseite
          authProvider.overrideWith(() => LoggedOutAuth(FakeApi(), server: null)),
          appConfigProvider.overrideWith(() => FakeAppConfig(const AppConfig(registrationMode: 'approval'))),
          registrationGatewayProvider.overrideWithValue(FakeGateway()),
        ],
        child: Consumer(builder: (context, ref, _) {
          router = ref.watch(routerProvider);
          return MaterialApp.router(theme: buildTheme(), routerConfig: router);
        }),
      ));
      await settle(tester);
      router.go('/register?server=https%3A%2F%2Fmusik.test&mode=approval');
      await settle(tester);
      expect(router.routerDelegate.currentConfiguration.uri.path, '/register');
      expect(submitButton, findsOneWidget);
      router.go('/library');
      await settle(tester);
      expect(router.routerDelegate.currentConfiguration.uri.path, '/login');
    });
  });

  // ------------------------------------------------------------------ Nichts freigeschaltet

  group('Leere Bibliothek ohne Freigabe', () {
    testWidgets('Startseite: „Noch nichts freigeschaltet“, kein „Musik suchen“', (tester) async {
      final user = newcomerJson();
      await pumpScreen(tester, const HomeScreen(), api: EmptyApi(user), auth: (api) => UserAuth(api, user));
      expect(find.text('Noch nichts freigeschaltet'), findsOneWidget);
      expect(
        find.text('Für dein Konto ist noch keine Rubrik freigeschaltet. Sobald der Betreiber dir Rubriken freigibt, '
            'findest du hier deine Musik.'),
        findsOneWidget,
      );
      expect(find.text('Musik suchen'), findsNothing);
      expect(find.text('Willkommen bei Selfify'), findsNothing);
      expectNoErrors(tester);
    });

    testWidgets('Startseite: mit Freigabe (oder alter Server) wie bisher', (tester) async {
      for (final user in [newcomerJson(categoryIds: [1]), userJson(admin: false)]) {
        await pumpScreen(tester, const HomeScreen(), api: EmptyApi(user), auth: (api) => UserAuth(api, user));
        expect(find.text('Willkommen bei Selfify'), findsOneWidget);
        expect(find.text('Musik suchen'), findsOneWidget);
        expect(find.text('Noch nichts freigeschaltet'), findsNothing);
      }
    });

    testWidgets('Ziehen zum Aktualisieren lädt Konto und Rubriken neu', (tester) async {
      final user = newcomerJson();
      final api = await pumpScreen(tester, const HomeScreen(), api: EmptyApi(user), auth: (api) => UserAuth(api, user));
      api.calls.clear();
      await tester.fling(find.text('Noch nichts freigeschaltet'), const Offset(0, 400), 1000);
      await settle(tester);
      expect(api.calls, containsAll(['home', 'me']));
    });

    Widget grid() => const Scaffold(body: CustomScrollView(slivers: [CategoryGridSliver()]));

    testWidgets('Rubriken-Raster: „Noch keine Rubrik freigeschaltet“', (tester) async {
      final user = newcomerJson();
      await pumpScreen(tester, grid(), api: EmptyApi(user), auth: (api) => UserAuth(api, user));
      expect(find.text('Noch keine Rubrik freigeschaltet'), findsOneWidget);
      expect(find.text('Der Betreiber kann dir Rubriken freigeben.'), findsOneWidget);
      expect(find.text('Noch keine Rubriken'), findsNothing);
      expectNoErrors(tester);
    });

    testWidgets('Rubriken-Raster leer bei Admins und anderen Konten: Text wie bisher', (tester) async {
      for (final user in [userJson(), userJson(admin: false), newcomerJson(categoryIds: [2])]) {
        await pumpScreen(tester, grid(), api: EmptyApi(user), auth: (api) => UserAuth(api, user));
        expect(find.text('Noch keine Rubriken'), findsOneWidget);
        expect(find.text('Noch keine Rubrik freigeschaltet'), findsNothing);
      }
    });
  });

  // ------------------------------------------------------------------ YouTube-Suche

  group('Suche (GitHub-Version) für eingeschränkte Konten', () {
    Future<FakeApi> searchFor(WidgetTester tester, Json user, {FakeApi? api}) async {
      final fakeApi = await pumpScreen(tester, const SearchScreen(),
          api: api ?? NoHitsApi(user), auth: (api) => UserAuth(api, user), size: const Size(400, 1400));
      await tester.enterText(find.byType(TextField).first, 'abba');
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 500));
      return fakeApi;
    }

    testWidgets('ohne Download-Recht: kein YouTube-Bereich, kein Hinweis darauf, keine Anfrage', (tester) async {
      final user = newcomerJson(categoryIds: [1]);
      final api = await searchFor(tester, user);
      expect(api.calls, contains('search'));
      expect(api.calls, isNot(contains('youtubeSearch')));
      expect(find.text('Prüf die Schreibweise oder versuch es mit einem anderen Suchbegriff.'), findsOneWidget);
      expect(find.textContaining('YouTube'), findsNothing);
      expect(find.text('Erneut versuchen'), findsNothing);
      expectNoErrors(tester);
    });

    // Je Konto ein eigener Test: Ein neuer pumpScreen im selben Test behielte den Zustand der Suche
    for (final (label, user) in [
      ('eingeschränkt mit Download-Recht', {...newcomerJson(categoryIds: [1]), 'can_download': true}),
      ('Bestandskonto ohne Download-Recht', userJson(admin: false, canDownload: false)),
      ('Admin', userJson()),
    ]) {
      testWidgets('$label: YouTube wie bisher', (tester) async {
        final api = await searchFor(tester, user);
        expect(find.text('In deiner Bibliothek ist dazu noch nichts. Schau unten bei YouTube Music.'), findsOneWidget);
        expect(api.calls, contains('youtubeSearch'));
      });
    }
  });

  // ------------------------------------------------------------------ Verwaltung in der App

  group('Verwaltung › Benutzer', () {
    testWidgets('Wartendes Konto: Abzeichen „Wartet auf Freigabe“, „Konto aktiv“ schaltet frei', (tester) async {
      final api = PendingUsersApi();
      await pumpScreen(tester, const AdminScreen(), api: api, size: const Size(400, 1200));
      await settle(tester);
      expect(find.text('Wartet auf Freigabe'), findsOneWidget);
      expect(find.text('Deaktiviert'), findsNothing, reason: 'nicht zusätzlich „Deaktiviert“');

      await tester.tap(find.text('Neu'));
      await settle(tester);
      expect(find.text('Rubriken-Freigaben stellst du im Dashboard ein.'), findsOneWidget);
      expect(find.text('Wartet auf Freigabe – einschalten schaltet das Konto frei'), findsOneWidget);
      await tester.tap(find.widgetWithText(SwitchListTile, 'Konto aktiv'));
      await settle(tester);
      expect(api.updates, ['9:isActive=true']);
      expect(find.text('Freigeschaltet.'), findsOneWidget);
      expectNoErrors(tester);
    });
  });
}

/// Server mit einem selbst registrierten, wartenden Konto.
class PendingUsersApi extends FakeApi {
  final updates = <String>[];
  bool activated = false;

  Json get _newcomer => {
        ...newcomerJson(),
        'is_active': activated,
        'approval_pending': !activated,
      };

  @override
  Future<List<User>> users() async => [User.fromJson(userJson()), User.fromJson(_newcomer)];

  @override
  Future<User> updateUser(int id,
      {String? displayName,
      String? password,
      bool? isAdmin,
      bool? isActive,
      bool? canDownload,
      bool? allCategories,
      List<int>? categoryIds}) async {
    updates.add('$id:isActive=$isActive');
    if (isActive == true) activated = true;
    return User.fromJson(_newcomer);
  }
}
