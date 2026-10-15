// Update-Hinweis: Versionsdatei lesen, neuere Version erkennen, „Später“ merken, Installation mit Fortschritt.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ota_update/ota_update.dart';
import 'package:selfify/core/theme.dart';
import 'package:selfify/data/app_update.dart';
import 'package:selfify/state/app_update.dart';
import 'package:selfify/state/auth.dart';
import 'package:selfify/ui/widgets/app_update.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> manifest(int build) => {
      'build': build,
      'version': '1.0.0',
      'commit': 'abc1234',
      'date': '2026-10-15T16:00:00Z',
      'android': {
        'url': 'https://github.com/patrick19921992/spotify/releases/download/app-latest/selfify.apk',
        'sha256': 'a' * 64,
      },
    };

class _FakeSource implements AppUpdateSource {
  final int installed;
  final Object? available; // AppRelease oder Fehler
  @override
  final bool supported;

  _FakeSource({required this.installed, Object? latest, this.supported = true}) : available = latest;

  @override
  Future<int> installedBuild() async => installed;

  @override
  Future<AppRelease?> latest() async {
    final value = available;
    if (value is Exception) throw value;
    return value as AppRelease?;
  }
}

Future<ProviderContainer> containerWith(AppUpdateSource source) async {
  SharedPreferences.setMockInitialValues({});
  final container = ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWithValue(await SharedPreferences.getInstance()),
    appUpdateSourceProvider.overrideWithValue(source),
  ]);
  addTearDown(container.dispose);
  return container;
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

  test('Kein Internet, iPhone/Windows oder lokaler Build: kein Hinweis, kein Fehler', () async {
    var container = await containerWith(_FakeSource(installed: 1, latest: Exception('offline')));
    expect(await container.read(availableUpdateProvider.future), isNull);

    container = await containerWith(_FakeSource(installed: 1, latest: AppRelease.fromJson(manifest(9)), supported: false));
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
    expect(updateProgressFor(OtaStatus.PERMISSION_NOT_GRANTED_ERROR, null).message, contains('Unbekannte Apps installieren'));
    expect(updateProgressFor(OtaStatus.CHECKSUM_ERROR, null).step, UpdateStep.failed);
  });

  testWidgets('Hinweis zeigt die neue Version, „Installieren“ lädt mit Fortschritt und öffnet den Installer',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final progress = StreamController<UpdateProgress>();
    AppDownload? started;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        appUpdateSourceProvider.overrideWithValue(_FakeSource(installed: 41, latest: AppRelease.fromJson(manifest(42)))),
        updateInstallerProvider.overrideWithValue((download) {
          started = download;
          return progress.stream;
        }),
      ],
      child: MaterialApp(theme: buildTheme(), home: const Scaffold(body: Align(alignment: Alignment.bottomCenter, child: UpdateBanner()))),
    ));
    await tester.pump();
    await tester.pump();
    expect(find.text('Neue App-Version verfügbar'), findsOneWidget);
    expect(find.text('Version 1.0.0 (Build 42)'), findsOneWidget);

    await tester.tap(find.text('Installieren'));
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

  testWidgets('Fehler beim Update: Meldung und „Erneut versuchen“', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    var attempts = 0;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        appUpdateSourceProvider.overrideWithValue(_FakeSource(installed: 41, latest: AppRelease.fromJson(manifest(42)))),
        updateInstallerProvider.overrideWithValue((download) {
          attempts++;
          return Stream.value(const UpdateProgress(UpdateStep.failed, message: 'Das Update konnte nicht geladen werden.'));
        }),
      ],
      child: MaterialApp(theme: buildTheme(), home: const Scaffold(body: UpdateBanner())),
    ));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text('Installieren'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Das Update konnte nicht geladen werden.'), findsOneWidget);
    await tester.tap(find.text('Erneut versuchen'));
    await tester.pump();
    await tester.pump();
    expect(attempts, 2);
  });
}
