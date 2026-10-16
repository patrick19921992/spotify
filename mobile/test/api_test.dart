import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfify/data/api.dart';
import 'package:selfify/data/models.dart';

ApiClient client() => ApiClient(
      baseUrl: 'https://musik.example.de',
      tokens: Tokens(
        accessToken: 'acc',
        refreshToken: 'ref',
        mediaToken: 'med',
        accessExpiresAt: DateTime.now().add(const Duration(minutes: 30)),
        mediaExpiresAt: DateTime.now().add(const Duration(days: 7)),
      ),
      onTokens: (_) {},
      onSessionExpired: () {},
    );

void main() {
  test('Server-Adressen werden vereinheitlicht', () {
    expect(normalizeBaseUrl('musik.example.de'), 'https://musik.example.de');
    expect(normalizeBaseUrl(' https://musik.example.de/ '), 'https://musik.example.de');
    expect(normalizeBaseUrl('http://192.168.1.10:8080/api'), 'http://192.168.1.10:8080');
    expect(normalizeBaseUrl('HTTP://192.168.1.10:8080'), 'http://192.168.1.10:8080');
    expect(normalizeBaseUrl('Https://Musik.example.de'), 'https://Musik.example.de');
  });

  test('Stream- und Cover-Links enthalten den Medien-Token', () {
    final api = client();
    expect(api.streamUrl(5), 'https://musik.example.de/api/tracks/5/stream?t=med');
    expect(api.streamUrl(5, quality: 'low', compatible: true),
        'https://musik.example.de/api/tracks/5/stream?t=med&quality=low&compatible=true');
    // Video in einer Musik-Warteschlange: nur der Ton
    expect(api.streamUrl(5, audioOnly: true), 'https://musik.example.de/api/tracks/5/stream?t=med&audio_only=true');
    expect(api.coverUrl('abc', size: 64), 'https://musik.example.de/api/covers/abc?size=64&t=med');
  });

  test('WebSocket-Adresse für den Live-Fortschritt', () {
    expect(client().downloadsWebSocketUri().toString(), 'wss://musik.example.de/api/downloads/ws?token=acc');
    final local = ApiClient(
      baseUrl: 'http://192.168.1.10:8080',
      tokens: client().tokens,
      onTokens: (_) {},
      onSessionExpired: () {},
    );
    expect(local.downloadsWebSocketUri().scheme, 'ws');
  });

  test('Fehlermeldungen vom Server werden übernommen', () {
    final options = RequestOptions(path: '/x');
    final error = DioException(
      requestOptions: options,
      response: Response(requestOptions: options, statusCode: 409, data: {'detail': 'Gibt es schon.'}),
    );
    final api = toApiException(error);
    expect(api.message, 'Gibt es schon.');
    expect(api.statusCode, 409);
    final offline = toApiException(DioException(requestOptions: options, type: DioExceptionType.connectionError));
    expect(offline.isNetwork, isTrue);
    expect(offline.message, contains('nicht erreichbar'));
  });
}
