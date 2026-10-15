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
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Row(
            children: [
              const Icon(Icons.system_update_rounded, color: AppColors.accent),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Neue App-Version verfügbar', style: TextStyle(fontWeight: FontWeight.w700)),
                    Text(
                      release.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: () => ref.read(dismissedUpdateProvider.notifier).dismiss(release.build),
                child: const Text('Später'),
              ),
              FilledButton(
                onPressed: () => showUpdateDialog(context, release),
                child: const Text('Installieren'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Lädt das Update mit Fortschrittsanzeige und öffnet danach den Android-Installer.
Future<void> showUpdateDialog(BuildContext context, AppRelease release) {
  final download = release.android;
  if (download == null) return Future.value();
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _UpdateDialog(release: release, download: download),
  );
}

class _UpdateDialog extends ConsumerStatefulWidget {
  final AppRelease release;
  final AppDownload download;

  const _UpdateDialog({required this.release, required this.download});

  @override
  ConsumerState<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends ConsumerState<_UpdateDialog> {
  StreamSubscription<UpdateProgress>? _subscription;
  UpdateProgress _progress = const UpdateProgress(UpdateStep.downloading);

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    _subscription?.cancel();
    setState(() => _progress = const UpdateProgress(UpdateStep.downloading));
    _subscription = ref.read(updateInstallerProvider)(widget.download).listen(
      (progress) {
        if (mounted) setState(() => _progress = progress);
      },
      onError: (Object error) {
        if (mounted) {
          setState(() => _progress = UpdateProgress(UpdateStep.failed, message: 'Das Update ist fehlgeschlagen ($error).'));
        }
      },
    );
  }

  @override
  void dispose() {
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
      title: Text(widget.release.label),
      content: content,
      actions: [
        if (progress.step == UpdateStep.failed)
          TextButton(onPressed: _start, child: const Text('Erneut versuchen')),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(progress.step == UpdateStep.downloading ? 'Abbrechen' : 'Schließen'),
        ),
      ],
    );
  }
}
