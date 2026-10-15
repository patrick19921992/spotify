// Windows-Update: neuen Installer laden, Prüfsumme kontrollieren, starten – Selfify beendet sich dann, der
// Installer ersetzt die Programmdateien und startet Selfify neu. Anmeldung, Einstellungen und Offline-Musik
// liegen in AppData und bleiben erhalten.

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../data/app_update.dart';
import 'app_update.dart';

/// Startet den Installer (in Tests ersetzbar).
typedef InstallerLauncher = Future<void> Function(String path, List<String> arguments);

/// Installiert mit dem Selfify-Installer (unins000.exe liegt neben selfify.exe)? Sonst ist es die ZIP-Variante.
bool get isInstalledWindowsApp =>
    File('${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}unins000.exe').existsSync();

/// Argumente für den Installer. Installiert: still im Hintergrund, schließt Selfify und startet es danach
/// wieder (/autoupdate=1, siehe windows/installer/selfify.iss). ZIP-Variante: normaler Assistent – danach gibt es
/// Selfify im Startmenü, und künftige Updates laufen still.
List<String> windowsInstallerArguments({required bool installed}) => installed
    ? const ['/SILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CLOSEAPPLICATIONS', '/autoupdate=1']
    : const <String>[];

Future<void> _launchDetached(String path, List<String> arguments) async {
  await Process.start(path, arguments, mode: ProcessStartMode.detached);
}

/// Lädt den Installer mit Fortschritt, prüft die SHA-256-Prüfsumme, startet ihn und beendet Selfify.
/// Wird der Stream vorher abbestellt (Dialog geschlossen), wird der Download abgebrochen.
Stream<UpdateProgress> installWindowsUpdate(
  AppDownload download, {
  Dio? dio,
  Directory? directory,
  InstallerLauncher? launch,
  bool? installed,
  void Function()? quit,
}) {
  final cancel = CancelToken();
  var finished = false;
  late final StreamController<UpdateProgress> controller;

  void fail(String message) {
    if (finished) return;
    finished = true;
    controller
      ..add(UpdateProgress(UpdateStep.failed, message: message))
      ..close();
  }

  Future<void> run() async {
    final client = dio ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 15)));
    final file = File('${(directory ?? Directory.systemTemp).path}${Platform.pathSeparator}selfify-update-setup.exe');
    try {
      await client.download(
        download.url,
        file.path,
        cancelToken: cancel,
        onReceiveProgress: (received, total) {
          if (finished || total <= 0) return;
          controller.add(UpdateProgress(UpdateStep.downloading, fraction: (received / total).clamp(0.0, 1.0)));
        },
      );
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) return; // Dialog geschlossen
      fail('Das Update konnte nicht geladen werden. Bist du online?');
      return;
    } on FileSystemException {
      fail('Das Update konnte nicht gespeichert werden (Speicher voll?).');
      return;
    }
    if (finished) return;

    final expected = download.sha256;
    if (expected != null) {
      final actual = (await sha256.bind(file.openRead()).first).toString();
      if (actual != expected.toLowerCase()) {
        await file.delete().catchError((Object _) => file);
        fail('Die heruntergeladene Datei ist beschädigt. Bitte erneut versuchen.');
        return;
      }
    }
    if (finished) return;

    final withSetup = installed ?? isInstalledWindowsApp;
    try {
      await (launch ?? _launchDetached)(file.path, windowsInstallerArguments(installed: withSetup));
    } catch (e) {
      fail('Der Installer ließ sich nicht starten ($e).');
      return;
    }
    finished = true;
    controller.add(
      UpdateProgress(
        UpdateStep.installing,
        message: withSetup
            ? null
            // ZIP-Variante: Der Assistent installiert Selfify fest – die alte ZIP-Kopie würde sonst immer wieder
            // dasselbe Update anbieten
            : 'Der Installations-Assistent öffnet sich. Danach Selfify über das Startmenü starten und den alten '
                  'ZIP-Ordner löschen (Anmeldung, Einstellungen und Offline-Musik bleiben erhalten).',
      ),
    );
    await controller.close();
    // Kurz Zeit für die Meldung lassen, dann Platz machen – der Installer ersetzt die Programmdateien
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    (quit ?? () => exit(0))();
  }

  controller = StreamController<UpdateProgress>(
    onListen: () => unawaited(
      run().catchError((Object e) {
        debugPrint('Windows-Update: $e');
        fail('Das Update ist fehlgeschlagen.');
      }),
    ),
    onCancel: () {
      if (!finished) {
        finished = true;
        cancel.cancel('Abgebrochen');
      }
    },
  );
  return controller.stream;
}
