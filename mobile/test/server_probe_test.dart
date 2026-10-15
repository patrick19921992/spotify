// Prüfung der Server-Adresse beim Anmelden: verständliche Meldung plus technische Angaben, wer geantwortet hat.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfify/data/api.dart';
import 'package:selfify/ui/screens/login_screen.dart';

import 'support/fakes.dart';

/// Lokaler Server, der auf /api/server wie im Test gewünscht antwortet.
Future<HttpServer> serve(int status, String body, {String type = 'application/json', Map<String, String>? headers}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.parse(type);
    headers?.forEach(request.response.headers.set);
    request.response.write(body);
    request.response.close();
  });
  addTearDown(() => server.close(force: true));
  return server;
}

String base(HttpServer server) => 'http://127.0.0.1:${server.port}';

Future<ServerProbeException> probeFails(String url) async {
  try {
    await ApiClient.probe(url);
  } on ServerProbeException catch (e) {
    return e;
  }
  fail('Prüfung hätte fehlschlagen müssen');
}

void main() {
  // flutter_test ersetzt den HTTP-Client durch eine Attrappe (immer 400) – hier soll echt angefragt werden
  setUp(() => HttpOverrides.global = null);

  test('Selfify antwortet: Prüfung klappt', () async {
    final server = await serve(200, jsonEncode({'name': 'Selfify', 'version': '1.0', 'api_version': 1, 'public_url': ''}));
    final info = await ApiClient.probe(base(server));
    expect(info.name, 'Selfify');
  });

  test('Anderer Server (404): Meldung plus Angaben, wer was geantwortet hat', () async {
    final server = await serve(404, '{"detail":"Not Found"}', headers: {'server': 'uvicorn'});
    final error = await probeFails(base(server));
    expect(error.message, 'Unter dieser Adresse läuft kein Selfify-Server.');
    expect(error.isNetwork, isFalse);
    expect(error.details, contains('Abgefragt: ${base(server)}/api/server'));
    expect(error.details, contains('Aufgelöst zu: 127.0.0.1'));
    expect(error.details, contains('Antwort: HTTP 404'));
    expect(error.details, contains('server: uvicorn'));
    expect(error.details, contains('Inhalt: {"detail":"Not Found"}'));
  });

  test('Webseite statt Selfify (HTTP 200): kein Selfify-Server, Inhalt gekürzt sichtbar', () async {
    final server = await serve(200, '<html>\n  <title>Welcome to nginx!</title>\n${'x' * 500}</html>', type: 'text/html');
    final error = await probeFails(base(server));
    expect(error.message, 'Unter dieser Adresse läuft kein Selfify-Server.');
    expect(error.details, contains('content-type: text/html'));
    expect(error.details, contains('<html> <title>Welcome to nginx!</title>'));
    expect(error.details.length, lessThan(600));
  });

  test('Cloudflare-Bot-Schutz: Meldung sagt, was im Dashboard umzustellen ist', () async {
    final server = await serve(403, '<html>Just a moment...</html>', type: 'text/html', headers: {'cf-mitigated': 'challenge'});
    final error = await probeFails(base(server));
    expect(error.message, contains('Bot fight mode'));
    expect(error.details, contains('cf-mitigated: challenge'));
  });

  test('https:// auf einen reinen HTTP-Port: Hinweis auf http:// statt angeblichem Zertifikatsfehler', () async {
    final server = await serve(200, jsonEncode({'name': 'Selfify', 'api_version': 1}));
    final error = await probeFails('https://127.0.0.1:${server.port}');
    expect(error.message, contains('http://'));
    expect(error.message, isNot(contains('Zertifikat')));
  });

  test('Server aus: Netzwerkfehler (die Anmeldung probiert dann die nächste Variante)', () async {
    final server = await serve(200, '');
    final url = base(server);
    await server.close(force: true);
    final error = await probeFails(url);
    expect(error.isNetwork, isTrue);
    expect(error.details, contains('Fehler: '));
  });

  test('Aus dem Browser kopierte Adressen werden gekürzt', () {
    expect(normalizeBaseUrl('musik.example.de/api/server'), 'https://musik.example.de');
    expect(normalizeBaseUrl('https://musik.example.de/api/health?x=1'), 'https://musik.example.de');
    expect(normalizeBaseUrl('https://musik.example.de/api/docs#/'), 'https://musik.example.de');
    expect(normalizeBaseUrl('https://example.de/selfify/api/'), 'https://example.de/selfify');
    expect(normalizeBaseUrl('https://api.example.de'), 'https://api.example.de');
    expect(normalizeBaseUrl('https://example.de/apis'), 'https://example.de/apis');
  });

  testWidgets('Anmeldung zeigt die technischen Details unter der Fehlermeldung', (tester) async {
    final server = await tester.runAsync(() => serve(404, '{"detail":"Not Found"}'));
    await pumpScreen(tester, const LoginScreen());
    await tester.enterText(find.byType(TextField).first, base(server!));
    await tester.runAsync(() async {
      await tester.tap(find.text('Verbinden'));
      await Future<void>.delayed(const Duration(seconds: 2));
    });
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Unter dieser Adresse läuft kein Selfify-Server.'), findsOneWidget);
    await tester.tap(find.text('Technische Details'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('Antwort: HTTP 404'), findsOneWidget);
    expectNoErrors(tester);
  });
}
