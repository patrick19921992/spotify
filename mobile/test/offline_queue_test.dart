// Offline-Speicher mit echtem Dateisystem: Warteschlange nach dem Neustart, Entfernen während des Ladens.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfify/data/api.dart';
import 'package:selfify/data/models.dart';
import 'package:selfify/state/auth.dart';
import 'package:selfify/state/connectivity.dart';
import 'package:selfify/state/offline.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

/// Lädt „Dateien“ herunter; Titel in [held] warten, bis der Test sie freigibt.
class _FileApi extends FakeApi {
  final held = <int, Completer<void>>{};
  final started = <int>[];

  /// Download wird fertig, obwohl er gerade abgebrochen wurde (letztes Byte war schon unterwegs).
  bool finishDespiteCancel = false;

  @override
  Future<Response<dynamic>> downloadFile(String url, String savePath,
      {void Function(int received, int total)? onProgress, CancelToken? cancelToken}) async {
    final id = int.parse(RegExp(r'tracks/(\d+)/').firstMatch(url)!.group(1)!);
    started.add(id);
    final gate = held[id];
    if (gate != null) {
      await Future.any([gate.future, if (!finishDespiteCancel && cancelToken != null) cancelToken.whenCancel]);
    }
    if (!finishDespiteCancel && (cancelToken?.isCancelled ?? false)) throw const ApiException('Abgebrochen.');
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

/// Anmeldung, die wie beim Kaltstart (Schlüsselbund) erst etwas später fertig ist.
class _SlowAuth extends FakeAuth {
  _SlowAuth(super.api);

  @override
  Future<AuthState> build() async {
    await Future<void>.delayed(const Duration(milliseconds: 150));
    return super.build();
  }
}

List<Track> tracks(List<int> ids) => [for (final id in ids) Track.fromJson(trackJson(id))];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late StreamController<List<ConnectivityResult>> net;
  late _FileApi api;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('selfify_offline');
    net = StreamController<List<ConnectivityResult>>.broadcast();
    api = _FileApi();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => dir.path,
    );
  });

  tearDown(() async {
    await net.close();
    await dir.delete(recursive: true);
  });

  Future<ProviderContainer> container({bool slowAuth = false}) async {
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(await SharedPreferences.getInstance()),
      authProvider.overrideWith(() => slowAuth ? _SlowAuth(api) : FakeAuth(api)),
      connectivityProvider.overrideWith((ref) => net.stream),
    ]);
    addTearDown(c.dispose);
    c.listen(connectivityProvider, (_, _) {});
    c.listen(authProvider, (_, _) {});
    c.listen(offlineProvider, (_, _) {});
    net.add([ConnectivityResult.wifi]);
    return c;
  }

  Future<void> waitFor(bool Function() condition, String what) async {
    for (var i = 0; i < 300 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(condition(), isTrue, reason: what);
  }

  List<String> files() => Directory('${dir.path}/offline').listSync().map((f) => f.path.split('/').last).toList()
    ..sort();

  test('Warteschlange läuft nach dem Neustart weiter, auch wenn die Anmeldung später geladen wird', () async {
    await Directory('${dir.path}/offline').create();
    await File('${dir.path}/offline/index.json').writeAsString(jsonEncode({
      'tracks': {},
      'collections': {},
      'names': {},
      'queue': [for (final id in [1, 2, 3]) trackJson(id)],
    }));
    final c = await container(slowAuth: true);

    await waitFor(() => c.read(offlineProvider).tracks.length == 3, 'alle drei Titel geladen');
    expect(c.read(offlineProvider).pending, isEmpty);
    expect(files(), ['1.opus', '2.opus', '3.opus', 'index.json']);
  });

  test('Album wieder abgewählt, während ein Titel lädt: nichts bleibt auf dem Handy', () async {
    final c = await container();
    await c.read(authProvider.future);
    api.held[1] = Completer<void>();
    final offline = c.read(offlineProvider.notifier);
    await waitFor(() => c.read(offlineProvider).loaded, 'Index geladen');

    await offline.keepCollection('album:7', 'Hot Fuss', tracks([1, 2, 3]));
    await waitFor(() => c.read(offlineProvider).progress.containsKey(1), 'Titel 1 lädt');
    await offline.releaseCollection('album:7');
    api.held[1]!.complete();
    await Future<void>.delayed(const Duration(milliseconds: 200));

    final state = c.read(offlineProvider);
    expect(state.tracks, isEmpty);
    expect(state.progress, isEmpty);
    expect(files(), ['index.json']);
    expect(api.started, [1], reason: 'die übrigen Titel werden gar nicht erst geladen');
  });

  test('„Vom Handy entfernen“, als der Download gerade fertig wurde: Datei wird nicht behalten', () async {
    final c = await container();
    await c.read(authProvider.future);
    api
      ..held[1] = Completer<void>()
      ..finishDespiteCancel = true;
    final offline = c.read(offlineProvider.notifier);
    await waitFor(() => c.read(offlineProvider).loaded, 'Index geladen');

    offline.downloadTracks(tracks([1, 2]));
    await waitFor(() => c.read(offlineProvider).progress.containsKey(1), 'Titel 1 lädt');
    await offline.removeTrack(1);
    api.held[1]!.complete();
    await waitFor(() => c.read(offlineProvider).tracks.containsKey(2), 'Titel 2 wird danach geladen');

    expect(c.read(offlineProvider).tracks.keys, [2]);
    expect(files(), ['2.opus', 'index.json']);
  });
}
