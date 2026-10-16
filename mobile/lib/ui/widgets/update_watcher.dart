import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_update.dart';

/// Sucht auch bei laufender App nach Updates. Bisher wurde nur beim Start geprüft – am PC bleibt Selfify aber
/// oft tagelang offen, und auf dem Handy liegt die App meist nur im Hintergrund. Geprüft wird daher stündlich und
/// beim Zurückkehren in die App (am PC: Fenster wieder im Vordergrund), höchstens alle 30 Minuten.
class UpdateWatcher extends ConsumerStatefulWidget {
  final Widget child;

  const UpdateWatcher({super.key, required this.child});

  /// Abstand der regelmäßigen Prüfung.
  static const every = Duration(hours: 1);

  /// So lange nach einer Prüfung löst das Zurückkehren in die App keine neue aus.
  static const resumeCooldown = Duration(minutes: 30);

  @override
  ConsumerState<UpdateWatcher> createState() => _UpdateWatcherState();
}

class _UpdateWatcherState extends ConsumerState<UpdateWatcher> with WidgetsBindingObserver {
  Timer? _hourly;

  /// Läuft nach jeder Prüfung (auch der beim Start) – solange zählt das Zurückkehren in die App nicht.
  Timer? _cooldown;

  @override
  void initState() {
    super.initState();
    // iPhone, lokale Builds: es gibt nichts zu prüfen
    if (!ref.read(appUpdateSourceProvider).supported) return;
    WidgetsBinding.instance.addObserver(this);
    _hourly = Timer.periodic(UpdateWatcher.every, (_) => _check());
    _cooldown = Timer(UpdateWatcher.resumeCooldown, () {}); // die Prüfung beim Start läuft gerade
  }

  void _check() {
    _cooldown?.cancel();
    _cooldown = Timer(UpdateWatcher.resumeCooldown, () {});
    unawaited(ref.read(availableUpdateProvider.notifier).recheck());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !(_cooldown?.isActive ?? true)) _check();
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
