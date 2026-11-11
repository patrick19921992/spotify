// Offline-Speicher und Rubriken: Wird einem eingeschränkten Konto eine Rubrik entzogen, verschwinden deren Titel vom
// Gerät (der Server gibt sie ohnehin nicht mehr heraus) – mit echtem Dateisystem.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfify/data/api.dart';
import 'package:selfify/data/models.dart';
import 'package:selfify/state/auth.dart';
import 'package:selfify/state/connectivity.dart';
import 'package:selfify/state/offline.dart';
import 'package:selfify/ui/screens/offline_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

/// Angemeldet mit einem Konto, dessen Freigaben der Test ändert (wie nach „Konto neu laden“).
class _SwitchableAuth extends FakeAuth {
  Json user;
  _SwitchableAuth(super.api, this.user);

  @override
  Future<AuthState> build() async =>
      AuthState(serverUrl: 'https://musik.test', user: User.fromJson(user), api: api);

  void setUser(Json next) {
    user = next;
    state = AsyncData(AuthState(serverUrl: 'https://musik.test', user: User.fromJson(next), api: api));
  }
}

/// Die Playlist ist für das Konto nicht mehr sichtbar (oder gelöscht): 404.
class _GoneApi extends FakeApi {
  _GoneApi() : super(admin: false);

  @override
  Future<PlaylistDetail> playlist(int id) async {
    calls.add('playlist');
    throw const ApiException('Playlist nicht gefunden.', statusCode: 404);
  }
}

Json restricted(List<int> categoryIds) =>
    userJson(admin: false, canDownload: false, allCategories: false, categoryIds: categoryIds);

/// Titel [id] in Rubrik [category].
Json track(int id, int category) => {...trackJson(id), 'category_id': category};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late StreamController<List<ConnectivityResult>> net;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('selfify_offline_categories');
    net = StreamController<List<ConnectivityResult>>.broadcast();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => dir.path,
    );
    // Auf dem Gerät: Titel 1 und 2 (Rubrik 1), Titel 3 (Rubrik 5); Album 7 mit 1 und 3, Album 8 nur mit 3
    final offline = Directory('${dir.path}/offline');
    await offline.create();
    for (final id in [1, 2, 3]) {
      await File('${offline.path}/$id.opus').writeAsBytes(List.filled(100, 1));
    }
    await File('${offline.path}/index.json').writeAsString(jsonEncode({
      'tracks': {
        for (final (id, category) in [(1, 1), (2, 1), (3, 5)])
          '$id': {'track': track(id, category), 'file': '$id.opus', 'size': 100, 'saved_at': now},
      },
      'collections': {
        albumKey(7): [1, 3],
        albumKey(8): [3],
      },
      'names': {albumKey(7): 'Gemischt', albumKey(8): 'Hörspiel'},
      'queue': [track(4, 5)],
    }));
  });

  tearDown(() async {
    await net.close();
    await dir.delete(recursive: true);
  });

  Future<(ProviderContainer, _SwitchableAuth)> container(Json user) async {
    SharedPreferences.setMockInitialValues({});
    late _SwitchableAuth auth;
    final api = FakeApi(admin: user['is_admin'] == true);
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(await SharedPreferences.getInstance()),
      authProvider.overrideWith(() => auth = _SwitchableAuth(api, user)),
      // Ohne Netz: die Warteschlange bleibt liegen, der Test sieht nur das Aufräumen
      connectivityProvider.overrideWith((ref) => net.stream),
    ]);
    addTearDown(c.dispose);
    c.listen(connectivityProvider, (_, _) {});
    c.listen(authProvider, (_, _) {});
    c.listen(offlineProvider, (_, _) {});
    net.add([ConnectivityResult.none]);
    return (c, auth);
  }

  Future<void> waitFor(bool Function() condition, String what) async {
    for (var i = 0; i < 300 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(condition(), isTrue, reason: what);
  }

  Set<String> files() =>
      Directory('${dir.path}/offline').listSync().map((f) => f.path.split('/').last).where((n) => n != 'index.json').toSet();

  Map<String, dynamic> index() => jsonDecode(File('${dir.path}/offline/index.json').readAsStringSync()) as Map<String, dynamic>;

  test('Rubrik entzogen: Titel weg vom Gerät, aus Sammlung und Warteschlange; leere Sammlung verschwindet', () async {
    final (c, auth) = await container(restricted([1, 5]));
    await waitFor(() => c.read(offlineProvider).loaded && c.read(authProvider).value?.user != null, 'geladen');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final offline = c.read(offlineProvider.notifier);
    expect(c.read(offlineProvider).tracks.keys, unorderedEquals([1, 2, 3]), reason: 'alles noch freigegeben');
    expect(offline.localPath(3), isNotNull);

    auth.setUser(restricted([1]));
    // Sofort: nichts mehr aus der entzogenen Rubrik vom Gerät abspielen
    expect(offline.localPath(3), isNull);
    expect(offline.localPath(1), isNotNull);
    await waitFor(() => !c.read(offlineProvider).tracks.containsKey(3), 'Titel 3 gelöscht');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final state = c.read(offlineProvider);
    expect(state.tracks.keys, unorderedEquals([1, 2]));
    expect(state.pending, isEmpty, reason: 'Titel 4 (Rubrik 5) nicht mehr laden');
    expect(state.collections, {albumKey(7): [1]});
    expect(state.collectionNames, {albumKey(7): 'Gemischt'});
    expect(files(), {'1.opus', '2.opus'});
    expect(index()['collections'], {albumKey(7): [1]});
    expect((index()['tracks'] as Map).keys, unorderedEquals(['1', '2']));
    expect(index()['queue'], isEmpty);

    // Nichts mehr freigegeben: alles weg
    auth.setUser(restricted([]));
    await waitFor(() => c.read(offlineProvider).tracks.isEmpty, 'alles gelöscht');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(c.read(offlineProvider).collections, isEmpty);
    expect(files(), isEmpty);
  });

  test('Neu herunterladen: Titel aus nicht freigegebenen Rubriken kommen nicht in die Warteschlange', () async {
    final (c, _) = await container(restricted([1]));
    await waitFor(() => c.read(offlineProvider).loaded && !c.read(offlineProvider).tracks.containsKey(3), 'bereinigt');
    c.read(offlineProvider.notifier).downloadTracks([Track.fromJson(track(10, 5)), Track.fromJson(track(11, 1))]);
    expect(c.read(offlineProvider).pending, [11]);
  });

  test('Uneingeschränkte Konten (Admin, alle Rubriken, alter Server) behalten alles wie bisher', () async {
    for (final user in [
      userJson(),
      userJson(admin: false, allCategories: true, categoryIds: const []),
      userJson(admin: false), // alter Server ohne die Felder
      {...userJson(), 'all_categories': false, 'category_ids': <int>[]}, // Admin sieht immer alles
    ]) {
      final (c, _) = await container(user);
      await waitFor(() => c.read(offlineProvider).loaded && c.read(authProvider).value?.user != null, 'geladen');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(c.read(offlineProvider).tracks.keys, unorderedEquals([1, 2, 3]));
      expect(c.read(offlineProvider).collections.keys, unorderedEquals([albumKey(7), albumKey(8)]));
      expect(c.read(offlineProvider.notifier).localPath(3), isNotNull);
      expect(files(), {'1.opus', '2.opus', '3.opus'});
      c.dispose();
    }
  });

  testWidgets('Abgleich einer Sammlung mit 404 (nicht mehr sichtbar): Sammlung wird vom Handy entfernt', (tester) async {
    final api = await pumpScreen(tester, const OfflineScreen(),
        api: _GoneApi(),
        offlineState: OfflineState(
          loaded: true,
          tracks: {
            for (final t in sampleTracks(2))
              t.id: OfflineTrack(track: t, fileName: '${t.id}.opus', size: 1000, savedAt: DateTime(2026, 10, 10)),
          },
          collections: {'playlist:5': [1, 2, 3]},
          collectionNames: {'playlist:5': 'Roadtrip'},
        ));
    expect(find.text('Roadtrip'), findsOneWidget);
    await tester.tap(find.byTooltip('Fehlende Titel laden'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(api.calls, contains('playlist'));
    expect(find.text('„Roadtrip“ gibt es für dich auf dem Server nicht mehr. Die Sammlung wurde vom Handy entfernt.'),
        findsOneWidget);
    expect(find.byTooltip('Fehlende Titel laden'), findsNothing);
    final element = tester.element(find.byType(OfflineScreen));
    expect(ProviderScope.containerOf(element).read(offlineProvider).collections, isEmpty);
  });
}
