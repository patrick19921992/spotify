import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../state/app_config.dart';
import '../../state/offline_access.dart';
import '../nav.dart';

/// Vor jedem „Aufs Gerät laden“: true, wenn geladen werden darf. Sonst erklärt ein Dialog, warum nicht, und führt
/// zur Premium-Seite („Offline-Hören nur mit Premium“, Dashboard › App-Einstellungen).
Future<bool> requireOfflineAccess(BuildContext context, WidgetRef ref) async {
  final access = ref.read(offlineAccessProvider);
  if (access.canDownload) return true;
  if (access.access == OfflineAccess.checking) {
    await showDialog<void>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Einen Moment'),
        content: const Text('Dein Premium-Stand wird noch geprüft. Bitte versuch es gleich noch einmal.'),
        actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('OK'))],
      ),
    );
    return false;
  }
  final premiumVisible = ref.read(premiumVisibleProvider);
  final open = await showDialog<bool>(
    context: context,
    useRootNavigator: true,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Offline-Hören mit Premium'),
      content: Text(
        'Musik aufs Gerät laden und ohne Internet hören gibt es mit Premium.'
        '${premiumVisible ? '' : ' Frag den Betreiber deines Servers.'}',
      ),
      actions: premiumVisible
          ? [
              TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Später')),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Premium ansehen', style: TextStyle(color: AppColors.accent)),
              ),
            ]
          : [TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('OK'))],
    ),
  );
  if (open == true && context.mounted) Nav.premium(context);
  return false;
}

/// Hinweisband auf der Offline-Seite und in den Einstellungen: gesperrt, wird geprüft oder bald abgelaufen.
/// Ohne Sperre (Schalter aus, Premium frisch bestätigt) ist nichts zu sehen.
class OfflineAccessBanner extends ConsumerWidget {
  final EdgeInsetsGeometry padding;

  const OfflineAccessBanner({super.key, this.padding = const EdgeInsets.fromLTRB(16, 8, 16, 8)});

  /// Text des Hinweises – null, wenn es nichts zu sagen gibt.
  static String? textFor(OfflineAccessState access) {
    switch (access.access) {
      case OfflineAccess.free:
        return null;
      case OfflineAccess.checking:
        return 'Dein Premium-Stand wird noch geprüft. Bis dahin kann nichts Neues aufs Gerät geladen werden.';
      case OfflineAccess.locked:
        return 'Offline-Hören gibt es mit Premium.';
      case OfflineAccess.allowed:
        final days = access.daysLeft;
        if (days == null || days > 2) return null;
        final span = days <= 0 ? 'nur noch heute' : (days == 1 ? 'noch 1 Tag' : 'noch $days Tage');
        return 'Offline-Musik ist $span verfügbar. Bitte geh einmal online, damit dein Premium geprüft werden kann.';
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final access = ref.watch(offlineAccessProvider);
    final text = textFor(access);
    if (text == null) return const SizedBox.shrink();
    final locked = access.access == OfflineAccess.locked;
    final showButton = locked && ref.watch(premiumVisibleProvider);
    return Padding(
      padding: padding,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        decoration: BoxDecoration(
          color: AppColors.surfaceHigh,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: locked ? AppColors.accent : AppColors.surfaceHighest),
        ),
        child: Row(
          children: [
            Icon(
              locked ? Icons.workspace_premium_rounded : Icons.info_outline_rounded,
              size: 20,
              color: locked ? AppColors.accent : Colors.white,
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(text, style: const TextStyle(fontSize: 14, height: 1.35))),
            if (showButton)
              TextButton(
                onPressed: () => Nav.premium(context),
                child: const Text('Premium ansehen', style: TextStyle(color: AppColors.accent)),
              )
            else
              const SizedBox(width: 6),
          ],
        ),
      ),
    );
  }
}

/// Zeigt den Hinweis nach dem Löschen der Offline-Musik (Premium abgelaufen oder zu lange nicht geprüft) – einmal,
/// als Dialog, damit er nicht übersehen wird.
class OfflineWipeNoticeListener extends ConsumerStatefulWidget {
  final Widget child;

  const OfflineWipeNoticeListener({super.key, required this.child});

  @override
  ConsumerState<OfflineWipeNoticeListener> createState() => _OfflineWipeNoticeListenerState();
}

class _OfflineWipeNoticeListenerState extends ConsumerState<OfflineWipeNoticeListener> {
  bool _showing = false;

  Future<void> _show(String text) async {
    if (_showing || !mounted) return;
    _showing = true;
    ref.read(offlineWipeNoticeProvider.notifier).clear();
    final premiumVisible = ref.read(premiumVisibleProvider);
    final open = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Offline-Musik entfernt'),
        content: Text(text),
        actions: [
          if (premiumVisible)
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Premium ansehen', style: TextStyle(color: AppColors.accent)),
            ),
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('OK')),
        ],
      ),
    );
    _showing = false;
    if (open == true && mounted) Nav.premium(context);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(offlineWipeNoticeProvider, (_, text) {
      if (text != null) _show(text);
    });
    // Schon vor dem Aufbau gelöscht (beim Start): gleich nach dem ersten Bild zeigen
    final pending = ref.read(offlineWipeNoticeProvider);
    if (pending != null) WidgetsBinding.instance.addPostFrameCallback((_) => _show(pending));
    return widget.child;
  }
}
