// Update-Hinweis: Versionsdatei lesen, neuere Version erkennen, „Später“ merken, Installation mit Fortschritt.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ota_update/ota_update.dart';
import 'package:selfify/core/theme.dart';
import 'package:selfify/data/app_update.dart';
import 'package:selfify/state/app_update.dart';
import 'package:selfify/state/auth.dart';
import 'package:selfify/ui/screens/login_screen.dart';
import 'package:selfify/ui/screens/settings_screen.dart';
import 'package:selfify/ui/widgets/app_update.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

Map<String, dynamic> manifest(int build, {String sha = ''}) => {
  'build': build,
  'version': '1.0.0',
  'commit': 'abc1234',
  'date': '2026-10-15T16:00:00Z',
  'android': {
    'url': 'https://github.com/patrick19921992/spotify/releases/download/app-latest/selfify.apk',
    'sha256': sha.isEmpty ? 'a' * 64 : sha,
  },
};

class _FakeSource implements AppUpdateSource {
  final int installed;
  Object? available; // AppRelease oder Fehler – im Test änderbar („neue Version erschienen“)
  int calls = 0;
  @override
  final bool supported;

  _FakeSource({required this.installed, Object? latest, this.supported = true}) : available = latest;

  @override
  Future<int> installedBuild() async => installed;

  @override
  Future<AppRelease?> latest() async {
    calls++;
    final value = available;
    if (value is Exception) throw value;
    return value as AppRelease?;
  }
}

Future<ProviderContainer> containerWith(AppUpdateSource source) async {
  SharedPreferences.setMockInitialValues({});
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(await SharedPreferences.getInstance()),
      appUpdateSourceProvider.overrideWithValue(source),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Hinweis allein auf einer Seite – optional mit eigenem Installer (sonst das echte Plugin).
Future<void> pumpBanner(WidgetTester tester, AppUpdateSource source, {UpdateInstaller? installer}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        appUpdateSourceProvider.overrideWithValue(source),
        if (installer != null) updateInstallerProvider.overrideWithValue(installer),
      ],
      child: MaterialApp(
        theme: buildTheme(),
        home: const Scaffold(
          body: Align(alignment: Alignment.bottomCenter, child: UpdateBanner()),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

/// Ersetzt die Android-Seite des Plugins: zeichnet Methodenaufrufe auf, liefert Zugriff auf den Ereignis-Stream.
class _NativeOta {
  final calls = <String>[];
  MockStreamHandlerEventSink? events;

  _NativeOta(WidgetTester tester) {
    const method = MethodChannel('sk.fourq.ota_update/method');
    const stream = EventChannel('sk.fourq.ota_update/stream');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(method, (call) async {
      calls.add(call.method);
      return null;
    });
    messenger.setMockStreamHandler(
      stream,
      MockStreamHandler.inline(
        onListen: (_, sink) {
          events = sink;
        },
      ),
    );
    addTearDown(() {
      messenger.setMockMethodCallHandler(method, null);
      messenger.setMockStreamHandler(stream, null);
    });
  }
}

void main() {
  // flutter_test ersetzt den HTTP-Client durch eine Attrappe – für den Abruf der Versionsdatei echt anfragen
  setUp(() => HttpOverrides.global = null);

  test('Versionsdatei wird gelesen, unsichere oder kaputte Angaben werden ignoriert', () {
    final release = AppRelease.fromJson(manifest(42));
    expect(release.build, 42);
    expect(release.label, 'Version 1.0.0 (Build 42)');
    expect(release.android?.sha256, 'a' * 64);

    final insecure = AppRelease.fromJson({
      ...manifest(43),
      'android': {'url': 'http://example.de/selfify.apk', 'sha256': 'kurz'},
    });
    expect(insecure.android, isNull);
    final noSha = AppRelease.fromJson({
      ...manifest(44),
      'android': {'url': 'https://example.de/selfify.apk', 'sha256': 'kurz'},
    });
    expect(noSha.android?.sha256, isNull);
  });

  test('Versionsdatei von GitHub (als application/octet-stream) wird geladen', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) {
      request.response.headers.contentType = ContentType.binary;
      request.response.write(jsonEncode(manifest(77)));
      request.response.close();
    });
    final release = await fetchLatestRelease(url: 'http://127.0.0.1:${server.port}/version.json');
    expect(release?.build, 77);
    expect(await fetchLatestRelease(url: ''), isNull, reason: 'ohne eingebaute Adresse keine Prüfung');
  });

  test('Neuere Version wird angeboten, gleiche oder ältere nicht', () async {
    var container = await containerWith(_FakeSource(installed: 41, latest: AppRelease.fromJson(manifest(42))));
    expect((await container.read(availableUpdateProvider.future))?.build, 42);

    container = await containerWith(_FakeSource(installed: 42, latest: AppRelease.fromJson(manifest(42))));
    expect(await container.read(availableUpdateProvider.future), isNull);

    container = await containerWith(_FakeSource(installed: 50, latest: AppRelease.fromJson(manifest(42))));
    expect(await container.read(availableUpdateProvider.future), isNull);
  });

  test('Kein Internet: Prüfung gilt als gescheitert (nicht als „aktuell“), aber kein Hinweis', () async {
    var container = await containerWith(_FakeSource(installed: 1, latest: Exception('offline')));
    await expectLater(container.read(availableUpdateProvider.future), throwsException);
    expect(container.read(availableUpdateProvider).hasError, isTrue);
    expect(container.read(updateNoticeProvider), isNull);

    // iPhone/Windows oder lokaler Build: gar nicht prüfen
    container = await containerWith(
      _FakeSource(installed: 1, latest: AppRelease.fromJson(manifest(9)), supported: false),
    );
    expect(await container.read(availableUpdateProvider.future), isNull);
  });

  test('„Später“ blendet den Hinweis aus – bis eine noch neuere Version erscheint', () async {
    final container = await containerWith(_FakeSource(installed: 41, latest: AppRelease.fromJson(manifest(42))));
    await container.read(availableUpdateProvider.future);
    expect(container.read(updateNoticeProvider)?.build, 42);

    container.read(dismissedUpdateProvider.notifier).dismiss(42);
    expect(container.read(updateNoticeProvider), isNull);
    expect(container.read(sharedPreferencesProvider).getInt('update.dismissedBuild'), 42);

    container.updateOverrides([
      sharedPreferencesProvider.overrideWithValue(container.read(sharedPreferencesProvider)),
      appUpdateSourceProvider.overrideWithValue(_FakeSource(installed: 41, latest: AppRelease.fromJson(manifest(43)))),
    ]);
    container.invalidate(availableUpdateProvider);
    await container.read(availableUpdateProvider.future);
    expect(container.read(updateNoticeProvider)?.build, 43);
  });

  test('Meldungen des Installations-Plugins werden verständlich übersetzt', () {
    expect(updateProgressFor(OtaStatus.DOWNLOADING, '37').fraction, closeTo(0.37, 0.001));
    expect(updateProgressFor(OtaStatus.INSTALLING, null).step, UpdateStep.installing);
    expect(
      updateProgressFor(OtaStatus.PERMISSION_NOT_GRANTED_ERROR, null).message,
      contains('Unbekannte Apps installieren'),
    );
    expect(updateProgressFor(OtaStatus.CHECKSUM_ERROR, null).step, UpdateStep.failed);
    // ota_update 7.1.0 vertauscht diese beiden Nummern – keine der Meldungen darf zum Deinstallieren raten
    for (final status in [OtaStatus.INSTALLATION_ERROR, OtaStatus.ALREADY_RUNNING_ERROR]) {
      final message = updateProgressFor(status, null).message!;
      expect(message, contains('schon ein Update'));
      expect(message, isNot(contains('deinstall')));
    }
  });

  testWidgets('Hinweis zeigt die neue Version, „Installieren“ lädt mit Fortschritt und öffnet den Installer', (
    tester,
  ) async {
    final progress = StreamController<UpdateProgress>();
    AppDownload? started;
    await pumpBanner(
      tester,
      _FakeSource(installed: 41, latest: AppRelease.fromJson(manifest(42))),
      installer: (download) {
        started = download;
        return progress.stream;
      },
    );
    expect(find.text('Neue App-Version verfügbar'), findsOneWidget);
    expect(find.text('Version 1.0.0 (Build 42)'), findsOneWidget);

    await tester.tap(find.text('Installieren'));
    await tester.pump();
    await tester.pump();
    expect(started?.sha256, 'a' * 64);
    progress.add(const UpdateProgress(UpdateStep.downloading, fraction: 0.5));
    await tester.pump();
    expect(find.text('Update wird geladen … 50 %'), findsOneWidget);
    progress.add(const UpdateProgress(UpdateStep.installing));
    await tester.pump();
    expect(find.textContaining('Android fragt jetzt'), findsOneWidget);
    await tester.tap(find.text('Schließen'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(AlertDialog), findsNothing);
    unawaited(progress.close());
  });

  testWidgets('Doppeltipp auf „Installieren“ öffnet nur einen Dialog', (tester) async {
    var starts = 0;
    await pumpBanner(
      tester,
      _FakeSource(installed: 41, latest: AppRelease.fromJson(manifest(42))),
      installer: (download) {
        starts++;
        return const Stream.empty();
      },
    );
    await tester.tap(find.text('Installieren'));
    await tester.tap(find.text('Installieren'), warnIfMissed: false);
    await tester.pump();
    await tester.pump();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(starts, 1);

    // nach dem Schließen geht es wieder
    await tester.tap(find.text('Abbrechen'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Installieren'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(AlertDialog), findsOneWidget);
  });

  testWidgets('Fehler beim Update: Meldung und „Erneut versuchen“', (tester) async {
    var attempts = 0;
    await pumpBanner(
      tester,
      _FakeSource(installed: 41, latest: AppRelease.fromJson(manifest(42))),
      installer: (download) {
        attempts++;
        return Stream.value(
          const UpdateProgress(UpdateStep.failed, message: 'Das Update konnte nicht geladen werden.'),
        );
      },
    );
    await tester.tap(find.text('Installieren'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Das Update konnte nicht geladen werden.'), findsOneWidget);
    await tester.tap(find.text('Erneut versuchen'));
    await tester.pump();
    await tester.pump();
    expect(attempts, 2);
  });

  testWidgets('Vor dem Installieren wird neu geprüft – inzwischen erschienene Version samt Prüfsumme wird geladen', (
    tester,
  ) async {
    final source = _FakeSource(installed: 41, latest: AppRelease.fromJson(manifest(42)));
    final started = <AppDownload>[];
    await pumpBanner(
      tester,
      source,
      installer: (download) {
        started.add(download);
        return Stream.value(const UpdateProgress(UpdateStep.failed, message: 'Abgebrochen.'));
      },
    );
    expect(find.text('Version 1.0.0 (Build 42)'), findsOneWidget);

    // Auf GitHub liegt jetzt Build 43 unter derselben Adresse – mit anderer Prüfsumme
    source.available = AppRelease.fromJson(manifest(43, sha: 'b' * 64));
    await tester.tap(find.text('Installieren'));
    await tester.pump();
    await tester.pump();
    expect(started.single.sha256, 'b' * 64);
    expect(
      find.descendant(of: find.byType(AlertDialog), matching: find.text('Version 1.0.0 (Build 43)')),
      findsOneWidget,
    );

    // „Erneut versuchen“ prüft ebenfalls neu
    source.available = AppRelease.fromJson(manifest(44, sha: 'c' * 64));
    await tester.tap(find.text('Erneut versuchen'));
    await tester.pump();
    await tester.pump();
    expect(started.last.sha256, 'c' * 64);
  });

  testWidgets('Abbrechen stoppt den Download auch im Plugin (sonst öffnet sich später doch der Installer)', (
    tester,
  ) async {
    final native = _NativeOta(tester);
    await pumpBanner(tester, _FakeSource(installed: 41, latest: AppRelease.fromJson(manifest(42))));
    await tester.tap(find.text('Installieren'));
    await tester.pump();
    await tester.pump();
    native.events!.success(['0', '30']);
    await tester.pump();
    expect(find.text('Update wird geladen … 30 %'), findsOneWidget);

    await tester.tap(find.text('Abbrechen'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(AlertDialog), findsNothing);
    expect(native.calls, ['cancel']);
  });

  testWidgets('Plugin meldet „läuft schon“: Hinweis zum Warten, kein Rat zum Deinstallieren', (tester) async {
    final native = _NativeOta(tester);
    await pumpBanner(tester, _FakeSource(installed: 41, latest: AppRelease.fromJson(manifest(42))));
    await tester.tap(find.text('Installieren'));
    await tester.pump();
    await tester.pump();
    // so schickt die Android-Seite „Another download (call) is already running“ (Java-Nummer 4)
    native.events!.error(code: '4', message: 'Another download (call) is already running');
    await tester.pump();
    expect(find.textContaining('schon ein Update'), findsOneWidget);
    expect(find.textContaining('deinstall'), findsNothing);

    await tester.tap(find.text('Schließen'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(native.calls, isEmpty, reason: 'den anderen, noch laufenden Download nicht abbrechen');
  });

  testWidgets('Hinweis passt auch auf schmale Handys mit großer Schrift', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 568));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          appUpdateSourceProvider.overrideWithValue(
            _FakeSource(installed: 41, latest: AppRelease.fromJson(manifest(42))),
          ),
        ],
        child: MaterialApp(
          theme: buildTheme(),
          home: MediaQuery(
            data: const MediaQueryData(size: Size(320, 568), textScaler: TextScaler.linear(1.6)),
            child: Scaffold(
              body: Column(
                children: const [
                  Expanded(child: SizedBox()),
                  UpdateBanner(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Neue App-Version verfügbar'), findsOneWidget);
    expectNoErrors(tester);
    expect(tester.getSize(find.byType(UpdateBanner)).height, lessThan(568 / 2));
    expect(tester.getSize(find.text('Neue App-Version verfügbar')).width, greaterThan(150));
  });

  testWidgets('Einstellungen: gescheiterte Prüfung heißt nicht „neueste Version“', (tester) async {
    final source = _FakeSource(installed: 41, latest: Exception('offline'));
    await pumpScreen(tester, const SettingsScreen(), updates: source);
    await tester.scrollUntilVisible(find.text('Nach Updates suchen'), 300, scrollable: find.byType(Scrollable).first);
    expect(find.text('Prüfung fehlgeschlagen – tippen, um es erneut zu versuchen'), findsOneWidget);
    expect(find.text('Du hast die neueste Version'), findsNothing);

    await tester.tap(find.text('Nach Updates suchen'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Prüfung fehlgeschlagen – bist du online?'), findsOneWidget);
    expectNoErrors(tester);
  });

  testWidgets('Update-Hinweis auch auf dem Anmeldebildschirm (falls die Anmeldung erst mit der neuen Version klappt)', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      const LoginScreen(),
      updates: _FakeSource(installed: 41, latest: AppRelease.fromJson(manifest(42))),
    );
    expect(find.text('Neue App-Version verfügbar'), findsOneWidget);
    expectNoErrors(tester);
  });
}
