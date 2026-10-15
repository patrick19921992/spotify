// Token-Erneuerung gegen einen echten kleinen HTTP-Server: Schlägt die wiederholte Anfrage fehl,
// muss der Fehler ankommen – die App darf nicht für immer hängen.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:selfify/data/api.dart';
import 'package:selfify/data/models.dart';

void main() {
  late HttpServer server;
  var refreshes = 0;

  setUp(() async {
    refreshes = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final response = request.response..headers.contentType = ContentType.json;
      final auth = request.headers.value('authorization');
      if (request.uri.path == '/api/auth/refresh') {
        refreshes++;
        response.write(jsonEncode({
          'access_token': 'neu', 'refresh_token': 'r2', 'expires_in': 1800,
          'media_token': 'm2', 'media_expires_in': 604800,
        }));
      } else if (auth != 'Bearer neu') {
        response
          ..statusCode = 401
          ..write(jsonEncode({'detail': 'Anmeldung abgelaufen.'}));
      } else {
        response
          ..statusCode = 404
          ..write(jsonEncode({'detail': 'Titel nicht gefunden.'}));
      }
      await response.close();
    });
  });

  tearDown(() => server.close(force: true));

  ApiClient client() => ApiClient(
        baseUrl: 'http://127.0.0.1:${server.port}',
        tokens: Tokens(
          accessToken: 'alt',
          refreshToken: 'r1',
          mediaToken: 'm1',
          accessExpiresAt: DateTime.now().add(const Duration(hours: 1)),
          mediaExpiresAt: DateTime.now().add(const Duration(days: 7)),
        ),
        onTokens: (_) {},
        onSessionExpired: () {},
      );

  test('Fehler nach erneuerter Anmeldung kommt an, spätere Anfragen auch', () async {
    final api = client();
    Future<Object?> outcome(Future<Object?> call) =>
        call.then<Object?>((v) => v, onError: (Object e) => e).timeout(const Duration(seconds: 5),
            onTimeout: () => 'HÄNGT');
    final first = await outcome(api.track(1));
    expect(first, isA<ApiException>());
    expect((first as ApiException).message, 'Titel nicht gefunden.');
    expect(refreshes, 1);
    final second = await outcome(api.track(2));
    expect(second, isA<ApiException>());
  });
}
