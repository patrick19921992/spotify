import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ota_update/ota_update.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../data/app_update.dart';
import 'auth.dart';
import 'windows_update.dart';

/// Woher die App erfährt, welche Version installiert ist und welche es gibt (in Tests ersetzbar).
abstract class AppUpdateSource {
  /// Nur Android- und Windows-Builds mit eingebauter Versions-Adresse prüfen auf Updates.
  bool get supported;

  /// Für welche Plattform die Update-Datei gesucht wird.
  UpdatePlatform get platform;
  Future<int> installedBuild();
  Future<AppRelease?> latest();
}

class _ReleaseUpdateSource implements AppUpdateSource {
  const _ReleaseUpdateSource();

  @override
  bool get supported => (Platform.isAndroid || Platform.isWindows) && updateManifestUrl.isNotEmpty;

  @override
  UpdatePlatform get platform => Platform.isWindows ? UpdatePlatform.windows : UpdatePlatform.android;

  @override
  Future<int> installedBuild() async => int.tryParse((await PackageInfo.fromPlatform()).buildNumber) ?? 0;

  @override
  Future<AppRelease?> latest() => fetchLatestRelease();
}

final appUpdateSourceProvider = Provider<AppUpdateSource>((ref) => const _ReleaseUpdateSource());

/// Neuere Version zum Installieren – null, wenn die App aktuell ist oder hier nicht geprüft wird
/// (iPhone, Windows, lokaler Build). Wirft, wenn die Abfrage scheitert (kein Internet …).
Future<AppRelease?> checkForUpdate(AppUpdateSource source) async {
  if (!source.supported) return null;
  final latest = await source.latest();
  if (latest == null || latest.downloadFor(source.platform) == null) return null;
  return latest.build > await source.installedBuild() ? latest : null;
}

/// Neuere App-Version zum Installieren – null, wenn die App aktuell ist oder nicht geprüft werden kann.
/// Scheitert die Prüfung, ist der Zustand ein Fehler: Der Hinweis bleibt dann aus, die Einstellungen sagen es.
class AvailableUpdateController extends AsyncNotifier<AppRelease?> {
  @override
  Future<AppRelease?> build() => checkForUpdate(ref.watch(appUpdateSourceProvider));

  /// Sofort neu prüfen (z. B. direkt vor dem Installieren) – wirft, wenn die Prüfung scheitert.
  Future<AppRelease?> refresh() async {
    final release = await checkForUpdate(ref.read(appUpdateSourceProvider));
    state = AsyncData(release);
    return release;
  }

  /// Nebenbei erneut prüfen, während die App läuft (siehe UpdateWatcher). Scheitert die Prüfung (offline),
  /// bleibt der bisherige Stand – ein schon gezeigter Hinweis verschwindet nicht.
  Future<void> recheck() async {
    if (state.isLoading) return;
    try {
      await refresh();
    } catch (_) {
      // beim nächsten Mal wieder
    }
  }
}

final availableUpdateProvider = AsyncNotifierProvider<AvailableUpdateController, AppRelease?>(
  AvailableUpdateController.new,
  // nicht automatisch wiederholen – ohne Internet wird beim nächsten Start bzw. per „Nach Updates suchen“ geprüft
  retry: (_, _) => null,
);

/// Build, bei dem „Später“ getippt wurde – der Hinweis kommt erst bei einer noch neueren Version wieder.
class DismissedUpdateController extends Notifier<int> {
  static const _key = 'update.dismissedBuild';

  @override
  int build() => ref.read(sharedPreferencesProvider).getInt(_key) ?? 0;

  void dismiss(int build) {
    state = build;
    ref.read(sharedPreferencesProvider).setInt(_key, build);
  }
}

final dismissedUpdateProvider = NotifierProvider<DismissedUpdateController, int>(DismissedUpdateController.new);

/// Hinweis in der App zeigen? (Update vorhanden und nicht weggeklickt)
final updateNoticeProvider = Provider<AppRelease?>((ref) {
  final release = ref.watch(availableUpdateProvider).value;
  if (release == null || release.build <= ref.watch(dismissedUpdateProvider)) return null;
  return release;
});

// ---------------------------------------------------------------- Installieren

enum UpdateStep { downloading, installing, failed }

class UpdateProgress {
  final UpdateStep step;

  /// Anteil des Downloads (0–1), sofern bekannt.
  final double? fraction;

  /// Verständliche Meldung bei einem Fehler.
  final String? message;

  const UpdateProgress(this.step, {this.fraction, this.message});
}

/// Startet Download und Installation. Wird der Stream vor dem Ende abbestellt (Dialog geschlossen),
/// muss auch der Download abgebrochen werden.
typedef UpdateInstaller = Stream<UpdateProgress> Function(AppDownload download);

/// Lädt das Update und installiert es: Android über den Android-Installer, Windows über den Selfify-Installer
/// (in Tests ersetzbar).
final updateInstallerProvider = Provider<UpdateInstaller>(
  (ref) => ref.watch(appUpdateSourceProvider).platform == UpdatePlatform.windows
      ? installWindowsUpdate
      : _installWithOtaUpdate,
);

Stream<UpdateProgress> _installWithOtaUpdate(AppDownload download) {
  final ota = OtaUpdate();
  StreamSubscription<OtaEvent>? events;
  var finished = false;
  late final StreamController<UpdateProgress> controller;

  void finish() {
    if (finished) return;
    finished = true;
    events?.cancel();
    controller.close();
  }

  controller = StreamController<UpdateProgress>(
    onListen: () {
      events = ota
          .execute(download.url, destinationFilename: 'selfify-update.apk', sha256checksum: download.sha256)
          .listen((event) {
            final progress = updateProgressFor(event.status, event.value);
            controller.add(progress);
            if (progress.step != UpdateStep.downloading) finish();
          }, onDone: finish);
    },
    onCancel: () {
      if (finished) return null;
      finished = true;
      events?.cancel();
      // Abbrechen/Zurück während des Downloads: Das Plugin lädt sonst im Hintergrund weiter und
      // öffnet danach ungefragt den Android-Installer.
      return ota.cancel().catchError((Object _) {});
    },
  );
  return controller.stream;
}

/// Übersetzt die Meldungen des Installations-Plugins.
UpdateProgress updateProgressFor(OtaStatus status, String? value) => switch (status) {
  OtaStatus.DOWNLOADING => UpdateProgress(
    UpdateStep.downloading,
    fraction: ((int.tryParse(value ?? '') ?? 0) / 100).clamp(0.0, 1.0),
  ),
  OtaStatus.INSTALLING || OtaStatus.INSTALLATION_DONE => const UpdateProgress(UpdateStep.installing),
  OtaStatus.PERMISSION_NOT_GRANTED_ERROR => const UpdateProgress(
    UpdateStep.failed,
    message:
        'Selfify darf noch keine Apps installieren. Erlaube es in den Android-Einstellungen '
        '(„Unbekannte Apps installieren“) und tippe noch einmal auf „Installieren“.',
  ),
  OtaStatus.CHECKSUM_ERROR => const UpdateProgress(
    UpdateStep.failed,
    message: 'Die heruntergeladene Datei ist beschädigt. Bitte erneut versuchen.',
  ),
  // ota_update 7.1.0 nummeriert diese beiden Meldungen in Java und Dart vertauscht: „Download läuft
  // schon“ kommt als INSTALLATION_ERROR an. Einen echten Installationsfehler meldet das Plugin im
  // verwendeten Modus (Android-Installer) gar nicht – beides bedeutet hier also „läuft schon“.
  OtaStatus.ALREADY_RUNNING_ERROR || OtaStatus.INSTALLATION_ERROR => const UpdateProgress(
    UpdateStep.failed,
    message: 'Es wird gerade schon ein Update geladen. Warte einen Moment und versuche es dann erneut.',
  ),
  OtaStatus.CANCELED => const UpdateProgress(UpdateStep.failed, message: 'Abgebrochen.'),
  OtaStatus.DOWNLOAD_ERROR => UpdateProgress(
    UpdateStep.failed,
    message: 'Das Update konnte nicht geladen werden. Bist du online?${value == null ? '' : ' ($value)'}',
  ),
  OtaStatus.INTERNAL_ERROR => UpdateProgress(
    UpdateStep.failed,
    message: 'Das Update ist fehlgeschlagen.${value == null ? '' : ' ($value)'}',
  ),
};
