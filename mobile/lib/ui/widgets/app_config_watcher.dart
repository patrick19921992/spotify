import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_config.dart';
import '../../state/auth.dart';

/// Holt die Einstellungen vom Server (Werbung, Premium, Update, Wartungshinweis) auch bei laufender App neu:
/// stündlich und beim Zurückkehren in die App (höchstens alle 10 Minuten). Auch der Premium-Stand wird dann neu
/// geladen – eine Laufzeit kann abgelaufen oder vom Admin entzogen worden sein.
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
    _hourly = Timer.periodic(AppConfigWatcher.every, (_) => _refresh());
    _cooldown = Timer(AppConfigWatcher.resumeCooldown, () {}); // der erste Abruf läuft gerade
  }

  void _refresh() {
    _cooldown?.cancel();
    _cooldown = Timer(AppConfigWatcher.resumeCooldown, () {});
    if (!(ref.read(authProvider).value?.isLoggedIn ?? false)) return;
    unawaited(ref.read(appConfigProvider.notifier).refresh());
    ref.invalidate(premiumProvider);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !(_cooldown?.isActive ?? true)) _refresh();
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
