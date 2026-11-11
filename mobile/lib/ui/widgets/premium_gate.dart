import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../player/player.dart';
import '../../player/skip_limit.dart';
import '../../state/app_config.dart';
import '../../state/offline_access.dart';
import '../nav.dart';
import 'common.dart';

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
        if (access.clockSuspect) {
          return 'Die Uhr dieses Geräts wurde zurückgestellt. Bitte geh einmal online, damit dein Premium neu '
              'geprüft werden kann – bis dahin ist die Offline-Musik nicht verfügbar.';
        }
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
/// als Dialog, damit er nicht übersehen wird. Ebenso „Bitte aktualisiere die App.“, wenn der Server das Abspielen
/// wegen einer zu alten App abweist, und (als SnackBar) den Hinweis zur Überspring-Grenze ohne Premium.
class OfflineWipeNoticeListener extends ConsumerStatefulWidget {
  final Widget child;

  const OfflineWipeNoticeListener({super.key, required this.child});

  @override
  ConsumerState<OfflineWipeNoticeListener> createState() => _OfflineWipeNoticeListenerState();
}

class _OfflineWipeNoticeListenerState extends ConsumerState<OfflineWipeNoticeListener> {
  bool _showing = false;
  bool _showingUpdate = false;

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

  /// „Bitte aktualisiere die App.“ – der Server spielt dieser App-Version ohne Premium nichts mehr ab (HTTP 426).
  Future<void> _showUpdateRequired() async {
    if (_showingUpdate || !mounted) return;
    _showingUpdate = true;
    ref.read(updateRequiredNoticeProvider.notifier).clear();
    await showDialog<void>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Update nötig'),
        content: const Text(updateRequiredMessage),
        actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('OK'))],
      ),
    );
    _showingUpdate = false;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(offlineWipeNoticeProvider, (_, text) {
      if (text != null) _show(text);
    });
    ref.listen(updateRequiredNoticeProvider, (_, show) {
      if (show) _showUpdateRequired();
    });
    // Überspring-Grenze ohne Premium erreicht (nur wenn der Betreiber sie eingeschaltet hat)
    ref.listen(skipLimitNoticeProvider, (_, text) {
      if (text == null) return;
      ref.read(skipLimitNoticeProvider.notifier).clear();
      showMessage(
        context,
        text,
        action: ref.read(premiumVisibleProvider)
            ? SnackBarAction(label: 'Premium', textColor: AppColors.accent, onPressed: () => Nav.premium(context))
            : null,
      );
    });
    // Schon vor dem Aufbau gelöscht (beim Start): gleich nach dem ersten Bild zeigen
    final pending = ref.read(offlineWipeNoticeProvider);
    if (pending != null) WidgetsBinding.instance.addPostFrameCallback((_) => _show(pending));
    return widget.child;
  }
}

/// Eine Leistung ist gesperrt (nur mit Premium): zur Premium-Seite – oder, wenn der Premium-Bereich abgeschaltet ist,
/// nur [message] zeigen.
void openPremiumOrExplain(BuildContext context, WidgetRef ref, String message) {
  if (ref.read(premiumVisibleProvider)) {
    Nav.premium(context);
  } else {
    showMessage(context, message);
  }
}

/// Sperransicht einer Premium-Leistung (Videos, Songtexte): Schloss, Text und „Zu Premium“ (wenn der Premium-Bereich
/// sichtbar ist), optional eine weitere Aktion (z. B. „Als Ton abspielen“).
class PremiumLockedView extends ConsumerWidget {
  final String text;
  final String? actionLabel;
  final IconData? actionIcon;
  final VoidCallback? onAction;

  /// Kompakte Darstellung (Karte im Player) statt Vollbild.
  final bool compact;

  const PremiumLockedView({
    super.key,
    required this.text,
    this.actionLabel,
    this.actionIcon,
    this.onAction,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final premiumVisible = ref.watch(premiumVisibleProvider);
    return Padding(
      padding: EdgeInsets.all(compact ? 16 : 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lock_rounded, size: compact ? 32 : 48, color: AppColors.textSecondary),
          const SizedBox(height: 12),
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white),
          ),
          const SizedBox(height: 16),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 12,
            runSpacing: 8,
            children: [
              if (actionLabel != null && onAction != null)
                OutlinedButton.icon(
                  onPressed: onAction,
                  icon: Icon(actionIcon ?? Icons.play_arrow_rounded),
                  label: Text(actionLabel!),
                ),
              if (premiumVisible)
                FilledButton.icon(
                  onPressed: () => Nav.premium(context),
                  icon: const Icon(Icons.workspace_premium_rounded),
                  label: const Text('Zu Premium'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
