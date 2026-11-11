import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../billing/billing.dart';
import '../../state/app_config.dart';
import '../../state/auth.dart';
import '../../state/offline_access.dart';

/// Holt die Einstellungen vom Server (Werbung, Premium, Update, Wartungshinweis) auch bei laufender App neu:
/// stündlich und beim Zurückkehren in die App (höchstens alle 10 Minuten). Auch der Premium-Stand wird dann neu
/// geladen – eine Laufzeit kann abgelaufen oder vom Admin entzogen worden sein. Daran hängt auch die
/// Offline-Berechtigung („Offline-Hören nur mit Premium“): Sie wird bei jedem Zurückkehren neu ausgewertet, weil
/// inzwischen die Gnadenfrist abgelaufen sein kann.
class AppConfigWatcher extends ConsumerStatefulWidget {
  final Widget child;

  const AppConfigWatcher({super.key, required this.child});

  static const every = Duration(hours: 1);
  static const resumeCooldown = Duration(minutes: 10);

  @override
  ConsumerState<AppConfigWatcher> createState() => _AppConfigWatcherState();
}

class _AppConfigWatcherState extends ConsumerState<AppConfigWatcher> with WidgetsBindingObserver {
  Timer? _hourly;
  Timer? _cooldown;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _hourly = Timer.periodic(AppConfigWatcher.every, (_) {
      _refresh();
      _recheckAccess();
    });
    _cooldown = Timer(AppConfigWatcher.resumeCooldown, () {}); // der erste Abruf läuft gerade
  }

  void _refresh() {
    _cooldown?.cancel();
    _cooldown = Timer(AppConfigWatcher.resumeCooldown, () {});
    if (!(ref.read(authProvider).value?.isLoggedIn ?? false)) return;
    unawaited(ref.read(appConfigProvider.notifier).refresh());
    ref.invalidate(premiumProvider);
    // Käufe nachholen (nur wenn der Kauf angeboten wird): gemerkte erneut melden und den Store nach Käufen fragen,
    // die er der App nicht gemeldet hat (App während der Zahlung beendet, Zahlung erst später bestätigt)
    if (ref.read(billingVisibleProvider)) unawaited(ref.read(billingProvider.notifier).catchUp());
  }

  /// Offline-Berechtigung neu auswerten – ohne Netzabfrage, nur mit der Uhr und dem gespeicherten Stand.
  void _recheckAccess() {
    if (!(ref.read(authProvider).value?.isLoggedIn ?? false)) return;
    ref.read(offlineAccessProvider.notifier).recheck();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (!(_cooldown?.isActive ?? true)) _refresh();
    _recheckAccess();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hourly?.cancel();
    _cooldown?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
