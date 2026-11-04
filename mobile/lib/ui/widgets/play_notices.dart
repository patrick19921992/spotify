import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/links.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../state/app_config.dart';
import 'common.dart';

/// Hinweis des Betreibers ganz oben (Dashboard › App-Einstellungen › Wartungshinweis), z. B. „Heute Abend ist der
/// Server kurz nicht erreichbar.“ Leer = nichts zu sehen.
class MaintenanceBanner extends ConsumerWidget {
  /// Platz für die Statusleiste lassen (Handy: der Hinweis liegt ganz oben am Bildschirmrand).
  final bool padTop;

  const MaintenanceBanner({super.key, this.padTop = true});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final message = ref.watch(appConfigValueProvider.select((c) => c.maintenanceMessage)).trim();
    if (message.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      color: const Color(0xFF4A3B0B),
      padding: EdgeInsets.fromLTRB(14, (padTop ? MediaQuery.paddingOf(context).top : 0) + 6, 14, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline_rounded, size: 18, color: Color(0xFFF1D9A0)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message, style: const TextStyle(fontSize: 13, height: 1.3, color: Color(0xFFF1D9A0))),
          ),
        ],
      ),
    );
  }
}

/// Öffnet die Store-Seite der App. Meldet sich, wenn das nicht geht.
Future<void> openStorePage(BuildContext context, WidgetRef ref, UpdateInfo info) async {
  final opened = await ref.read(linkOpenerProvider)(info.storeUrl);
  if (!opened && context.mounted) showMessage(context, 'Der Play Store lässt sich nicht öffnen. Öffne ihn bitte von Hand.');
}

/// Hinweis „Neue Version im Play Store“ (Stufe „verfügbar“) über dem Mini-Player – mit „Aktualisieren“ und „Später“.
class StoreUpdateBanner extends ConsumerWidget {
  const StoreUpdateBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(storeUpdateNoticeProvider);
    // Ohne Store-Link wäre der Hinweis eine Sackgasse – dann zeigt die App ihn nicht
    if (info == null || info.storeUrl.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      child: Material(
        color: AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
          child: Row(
            children: [
              const Icon(Icons.system_update_rounded, color: AppColors.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Neue App-Version verfügbar', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w700)),
                    Text(
                      info.message.isEmpty ? 'Im Play Store aktualisieren' : info.message,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () => openStorePage(context, ref, info),
                child: const Text('Aktualisieren', maxLines: 1, softWrap: false),
              ),
              IconButton(
                tooltip: 'Später',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close_rounded, size: 20, color: AppColors.textSecondary),
                onPressed: () => ref.read(dismissedStoreUpdateProvider.notifier).dismiss(info.latestBuild),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Liegt der Update-Stand der Play-Version auf „Pflicht“ (Dashboard › Mindestens nötige Build-Nummer), ersetzt
/// dieser Bildschirm die ganze App, bis aktualisiert ist.
class UpdateGate extends ConsumerWidget {
  final Widget child;

  const UpdateGate({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(storeUpdateProvider);
    if (info == null || info.level != UpdateLevel.required) return child;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.system_update_rounded, size: 64, color: AppColors.accent),
                  const SizedBox(height: 20),
                  const Text('Update nötig', style: AppText.pageTitle, textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  Text(
                    info.message.isEmpty
                        ? 'Diese Version von Selfify ist zu alt und läuft nicht mehr. Bitte aktualisiere die App.'
                        : info.message,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppColors.textSecondary, height: 1.4),
                  ),
                  const SizedBox(height: 28),
                  if (info.storeUrl.isNotEmpty)
                    FilledButton.icon(
                      onPressed: () => openStorePage(context, ref, info),
                      icon: const Icon(Icons.open_in_new_rounded),
                      label: const Text('Im Play Store öffnen'),
                    ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => ref.read(appConfigProvider.notifier).refresh(),
                    child: const Text('Schon aktualisiert? Neu prüfen', style: TextStyle(color: AppColors.textSecondary)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
