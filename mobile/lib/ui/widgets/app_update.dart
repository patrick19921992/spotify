import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/app_update.dart';
import '../../state/app_update.dart';

/// Hinweis „Neue Version verfügbar“ über dem Mini-Player – mit „Installieren“ und „Später“.
class UpdateBanner extends ConsumerWidget {
  const UpdateBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final release = ref.watch(updateNoticeProvider);
    if (release == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      child: Material(
        color: AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.system_update_rounded, color: AppColors.accent),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'Neue App-Version verfügbar',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                        Text(
                          release.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              // Knöpfe in eigener Zeile: So bleibt der Text auch auf schmalen Handys und mit großer Schrift lesbar
              OverflowBar(
                alignment: MainAxisAlignment.end,
                overflowAlignment: OverflowBarAlignment.end,
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: () => ref.read(dismissedUpdateProvider.notifier).dismiss(release.build),
                    child: const Text('Später'),
                  ),
                  FilledButton(onPressed: () => showUpdateDialog(context, release), child: const Text('Installieren')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Ist gerade ein Update-Dialog offen? Ein zweiter (Doppeltipp) würde den laufenden Download stören.
bool _updateDialogOpen = false;

/// Lädt das Update mit Fortschrittsanzeige und öffnet danach den Android-Installer.
Future<void> showUpdateDialog(BuildContext context, AppRelease release) async {
  if (release.android == null || _updateDialogOpen) return;
  _updateDialogOpen = true;
  try {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _UpdateDialog(release: release),
    );
  } finally {
    _updateDialogOpen = false;
  }
}

class _UpdateDialog extends ConsumerStatefulWidget {
  final AppRelease release;

  const _UpdateDialog({required this.release});

  @override
  ConsumerState<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends ConsumerState<_UpdateDialog> {
  StreamSubscription<UpdateProgress>? _subscription;
  UpdateProgress _progress = const UpdateProgress(UpdateStep.downloading);
  late AppRelease _release = widget.release;

  /// Zählt die Versuche – eine verspätete Antwort eines älteren Versuchs wird ignoriert.
  int _attempt = 0;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final attempt = ++_attempt;
    unawaited(_subscription?.cancel());
    _subscription = null;
    setState(() => _progress = const UpdateProgress(UpdateStep.downloading));

    // Versionsdatei frisch holen: Auf GitHub liegt immer nur die neueste APK. Eine gemerkte Prüfsumme passt
    // nicht mehr, sobald inzwischen eine neuere Version erschienen ist – der Download wäre dann „beschädigt“.
    final AppRelease? release;
    try {
      release = await ref.read(availableUpdateProvider.notifier).refresh();
    } catch (_) {
      if (mounted && attempt == _attempt) {
        setState(
          () => _progress = const UpdateProgress(
            UpdateStep.failed,
            message: 'Die Versionsinfo konnte nicht geladen werden. Bist du online?',
          ),
        );
      }
      return;
    }
    if (!mounted || attempt != _attempt) return;
    final fresh = release;
    final download = fresh?.android;
    if (fresh == null || download == null) {
      setState(
        () => _progress = const UpdateProgress(UpdateStep.failed, message: 'Du hast schon die neueste Version.'),
      );
      return;
    }
    setState(() => _release = fresh);
    _subscription = ref
        .read(updateInstallerProvider)(download)
        .listen(
          (progress) {
            if (mounted && attempt == _attempt) setState(() => _progress = progress);
          },
          onError: (Object error) {
            if (mounted && attempt == _attempt) {
              setState(
                () => _progress = UpdateProgress(UpdateStep.failed, message: 'Das Update ist fehlgeschlagen ($error).'),
              );
            }
          },
        );
  }

  @override
  void dispose() {
    _updateDialogOpen = false; // auch wenn der Dialog ohne „Schließen“ verschwindet
    // bricht auch einen laufenden Download ab (siehe updateInstallerProvider)
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = _progress;
    final percent = progress.fraction == null ? null : (progress.fraction! * 100).round();
    final Widget content = switch (progress.step) {
      UpdateStep.downloading => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(percent == null ? 'Update wird geladen …' : 'Update wird geladen … $percent %'),
          const SizedBox(height: 12),
          LinearProgressIndicator(value: progress.fraction),
        ],
      ),
      UpdateStep.installing => const Text(
        'Android fragt jetzt, ob Selfify aktualisiert werden soll – bitte „Aktualisieren“ bzw. „Installieren“ '
        'tippen. Deine Musik und Anmeldung bleiben erhalten.',
      ),
      UpdateStep.failed => Text(progress.message ?? 'Das Update ist fehlgeschlagen.'),
    };
    return AlertDialog(
      title: Text(_release.label),
      content: content,
      actions: [
        if (progress.step == UpdateStep.failed) TextButton(onPressed: _start, child: const Text('Erneut versuchen')),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(progress.step == UpdateStep.downloading ? 'Abbrechen' : 'Schließen'),
        ),
      ],
    );
  }
}
