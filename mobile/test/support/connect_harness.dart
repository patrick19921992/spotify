// Gerüst für Tests der Geräte-Verbindung ohne Oberfläche: ProviderContainer mit nachgebautem Server, Player und
// Konto. Läuft in testWidgets, damit Zeitgeber (Backoff, Gnadenfrist, Entprellung) per tester.pump vorspulbar sind.

import 'package:audio_service/audio_service.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:selfify/data/models.dart';
import 'package:selfify/player/player.dart';
import 'package:selfify/state/app_config.dart';
import 'package:selfify/state/auth.dart';
import 'package:selfify/state/connect.dart';
import 'package:selfify/state/connectivity.dart';
import 'package:selfify/state/offline.dart';
import 'package:selfify/state/offline_access.dart' show clockProvider;
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_connect.dart';
import 'fakes.dart';

const phoneInfo = ConnectDeviceInfo(kind: 'phone', platform: 'android', canVolume: false, canPlay: true);
const computerInfo = ConnectDeviceInfo(kind: 'computer', platform: 'windows', canVolume: true, canPlay: true);

class ConnectHarness {
  /// null = echte Zeit (für Tests mit dem nachgebauten just_audio, das echte Zeitgeber braucht).
  final WidgetTester? tester;
  final ProviderContainer container;
  final FakeApi api;
  final FakeConnectServer server;
  final SelfifyAudioHandler handler;
  DateTime now;
  bool _disposed = false;

  ConnectHarness._(this.tester, this.container, this.api, this.server, this.handler, this.now);

  ConnectState get state => container.read(connectProvider);
  ConnectController get controller => container.read(connectProvider.notifier);
  FakeConnectChannel get channel => server.last;

  static Future<ConnectHarness> start(
    WidgetTester? tester, {
    List<String> features = const ['connect'],
    AppLifecycleState lifecycle = AppLifecycleState.resumed,
    AppConfig config = const AppConfig(),
    Map<String, Object> prefs = const {},
    bool admin = true,
    ConnectDeviceInfo info = phoneInfo,
    OfflineState offline = const OfflineState(loaded: true),
    List<Override> overrides = const [],
    Stream<List<ConnectivityResult>>? connectivity,
    bool serverInfoFails = false,
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    final preferences = await SharedPreferences.getInstance();
    final api = FakeApi(admin: admin)
      ..serverFeatures = features
      ..serverInfoFails = serverInfoFails;
    final server = FakeConnectServer();
    final handler = SelfifyAudioHandler()
      ..resolveSource = (track, item) => AudioSource.uri(Uri.parse('https://musik.test/${track.id}'), tag: item);
    late ConnectHarness harness;
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(preferences),
      audioHandlerProvider.overrideWithValue(handler),
      authProvider.overrideWith(() => FakeAuth(api)),
      connectivityProvider.overrideWith((ref) => connectivity ?? Stream.value([ConnectivityResult.wifi])),
      offlineProvider.overrideWith(() => FakeOffline(offline)),
      appConfigProvider.overrideWith(() => FakeAppConfig(config)),
      connectChannelFactoryProvider.overrideWithValue(server.factory),
      connectDeviceInfoProvider.overrideWithValue(info),
      clockProvider.overrideWithValue(() => harness.now),
      ...overrides,
    ]);
    harness = ConnectHarness._(tester, container, api, server, handler, DateTime(2026, 11, 12, 10));
    container.listen(connectProvider, (_, _) {});
    container.listen(appConfigProvider, (_, _) {});
    container.read(appLifecycleProvider.notifier).set(lifecycle);
    await harness.settle(20);
    return harness;
  }

  /// Ausstehende Arbeit erledigen lassen (Mikrotasks, Antworten des nachgebauten Servers).
  Future<void> settle([int rounds = 8]) async {
    for (var i = 0; i < rounds; i++) {
      // Lesen stößt den Neuaufbau an (z. B. nach der Anmeldung), Pumpen erledigt Mikrotasks
      if (!_disposed) container.read(connectProvider);
      await _pump();
    }
  }

  Future<void> _pump() {
    final tester = this.tester;
    return tester == null ? Future<void>.delayed(const Duration(milliseconds: 2)) : tester.pump();
  }

  /// Wartet (echte Zeit) bis [condition] stimmt.
  Future<void> waitFor(bool Function() condition, [String what = 'Bedingung']) async {
    for (var i = 0; i < 300; i++) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    throw StateError('Zeitüberschreitung: $what');
  }

  /// Zeit vorspulen (Zeitgeber) – die Uhr der Anzeige läuft mit.
  Future<void> elapse(Duration duration) async {
    now = now.add(duration);
    final tester = this.tester;
    if (tester == null) {
      await Future<void>.delayed(duration);
    } else {
      await tester.pump(duration);
    }
    await settle();
  }

  void setLifecycle(AppLifecycleState state) => container.read(appLifecycleProvider.notifier).set(state);

  /// Lokale Wiedergabe melden (wie der Player es tut).
  void setLocalPlaying(bool playing) =>
      handler.playbackState.add(handler.playbackState.value.copyWith(playing: playing));

  /// Begrüßen und auf die Verarbeitung warten.
  Future<void> welcome({int selfId = 1, bool allowed = true, Map<int, String>? others, int? active, Map<String, Object?>? state}) async {
    server.welcome(channel,
        selfId: selfId, allowed: allowed, others: others ?? const {2: 'Windows · BÜRO-PC'}, active: active, state: state);
    await settle();
  }

  /// Alles abbauen (Zeitgeber müssen am Testende weg sein).
  Future<void> dispose() async {
    container.dispose();
    _disposed = true;
    for (var i = 0; i < 4; i++) {
      await _pump();
    }
  }
}

/// Zustand des aktiven Geräts, wie ihn der Server schickt.
Map<String, Object?> remoteStateJson({
  bool playing = true,
  int positionMs = 60000,
  int durationMs = 201000,
  bool shuffle = false,
  String repeat = 'off',
  double? volume = 0.8,
  int trackId = 1,
}) =>
    {
      'playing': playing,
      'position_ms': positionMs,
      'duration_ms': durationMs,
      'speed': 1.0,
      'queue_ids': [1, 2, 3],
      'index': 0,
      'shuffle': shuffle,
      'repeat': repeat,
      'volume': volume,
      'context': {'type': 'album', 'id': '7', 'name': 'A Night at the Opera'},
      'track': trackJson(trackId),
      'upcoming': [trackJson(2), trackJson(3)],
      'queue_rev': 1,
    };

/// Shuffle-Modus des Handlers (für Prüfungen).
bool shuffleOn(SelfifyAudioHandler handler) =>
    handler.playbackState.value.shuffleMode != AudioServiceShuffleMode.none || handler.player.shuffleModeEnabled;
