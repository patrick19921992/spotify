import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ota_update/ota_update.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../data/app_update.dart';
import 'auth.dart';

/// Woher die App erfährt, welche Version installiert ist und welche es gibt (in Tests ersetzbar).
abstract class AppUpdateSource {
  /// Nur Android-Builds mit eingebauter Versions-Adresse prüfen auf Updates.
  bool get supported;
  Future<int> installedBuild();
  Future<AppRelease?> latest();
}

class _ReleaseUpdateSource implements AppUpdateSource {
  const _ReleaseUpdateSource();

  @override
  bool get supported => Platform.isAndroid && updateManifestUrl.isNotEmpty;

  @override
  Future<int> installedBuild() async => int.tryParse((await PackageInfo.fromPlatform()).buildNumber) ?? 0;

  @override
  Future<AppRelease?> latest() => fetchLatestRelease();
}

final appUpdateSourceProvider = Provider<AppUpdateSource>((ref) => const _ReleaseUpdateSource());

/// Neuere App-Version zum Installieren – null, wenn die App aktuell ist oder nicht geprüft werden kann.
/// Neu prüfen: `ref.invalidate(availableUpdateProvider)`.
final availableUpdateProvider = FutureProvider<AppRelease?>((ref) async {
  final source = ref.watch(appUpdateSourceProvider);
  if (!source.supported) return null;
  try {
    final latest = await source.latest();
    if (latest == null || latest.android == null) return null;
    return latest.build > await source.installedBuild() ? latest : null;
  } catch (_) {
    return null; // kein Internet, GitHub nicht erreichbar … – beim nächsten Start erneut
  }
});

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

typedef UpdateInstaller = Stream<UpdateProgress> Function(AppDownload download);

/// Lädt die APK und öffnet den Android-Installer (in Tests ersetzbar).
final updateInstallerProvider = Provider<UpdateInstaller>((ref) => _installWithOtaUpdate);

Stream<UpdateProgress> _installWithOtaUpdate(AppDownload download) async* {
  final events = OtaUpdate().execute(
    download.url,
    destinationFilename: 'selfify-update.apk',
    sha256checksum: download.sha256,
  );
  await for (final event in events) {
    final progress = updateProgressFor(event.status, event.value);
    yield progress;
    if (progress.step != UpdateStep.downloading) return;
  }
}

/// Übersetzt die Meldungen des Installations-Plugins.
UpdateProgress updateProgressFor(OtaStatus status, String? value) => switch (status) {
      OtaStatus.DOWNLOADING =>
        UpdateProgress(UpdateStep.downloading, fraction: ((int.tryParse(value ?? '') ?? 0) / 100).clamp(0.0, 1.0)),
      OtaStatus.INSTALLING || OtaStatus.INSTALLATION_DONE => const UpdateProgress(UpdateStep.installing),
      OtaStatus.PERMISSION_NOT_GRANTED_ERROR => const UpdateProgress(
          UpdateStep.failed,
          message: 'Selfify darf noch keine Apps installieren. Erlaube es in den Android-Einstellungen '
              '(„Unbekannte Apps installieren“) und tippe noch einmal auf „Installieren“.',
        ),
      OtaStatus.CHECKSUM_ERROR =>
        const UpdateProgress(UpdateStep.failed, message: 'Die heruntergeladene Datei ist beschädigt. Bitte erneut versuchen.'),
      OtaStatus.ALREADY_RUNNING_ERROR => const UpdateProgress(UpdateStep.failed, message: 'Das Update wird schon geladen.'),
      OtaStatus.CANCELED => const UpdateProgress(UpdateStep.failed, message: 'Abgebrochen.'),
      OtaStatus.DOWNLOAD_ERROR => UpdateProgress(
          UpdateStep.failed,
          message: 'Das Update konnte nicht geladen werden. Bist du online?${value == null ? '' : ' ($value)'}',
        ),
      OtaStatus.INSTALLATION_ERROR => const UpdateProgress(
          UpdateStep.failed,
          message: 'Die Installation hat nicht geklappt. Wurde die App mit einer älteren Version ohne festen '
              'Signaturschlüssel installiert, muss sie einmal deinstalliert und neu installiert werden.',
        ),
      OtaStatus.INTERNAL_ERROR =>
        UpdateProgress(UpdateStep.failed, message: 'Das Update ist fehlgeschlagen.${value == null ? '' : ' ($value)'}'),
    };
