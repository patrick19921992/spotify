import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'billing/billing.dart';
import 'core/theme.dart';
import 'player/player.dart';
import 'state/auth.dart';
import 'state/connect.dart';
import 'ui/desktop/desktop_layout.dart';
import 'ui/desktop/desktop_shortcuts.dart';
import 'ui/router.dart';
import 'ui/widgets/app_config_watcher.dart';
import 'ui/widgets/orientation_lock.dart';
import 'ui/widgets/play_notices.dart';
import 'ui/widgets/update_watcher.dart';

class SelfifyApp extends ConsumerWidget {
  const SelfifyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Player mit Server/Offline/Einstellungen verbinden
    ref.watch(playbackBridgeProvider);
    // Kauf in der App (nur Play-Version, wenn eingeschaltet): Die Steuerung läuft ab dem Start – sie hört auf den
    // Kauf-Strom und fragt den Store selbst nach Käufen, die beim letzten Mal nicht fertig wurden (von sich aus
    // meldet Google Play sie nicht). In allen anderen Fällen wird das Kauf-Paket nie angefasst.
    if (ref.watch(billingVisibleProvider)) ref.listen(billingProvider, (_, _) {});
    // Wiedergabe auf anderen Geräten: Verbindung halten, sobald der Server es kann (sonst passiert nichts)
    ref.listen(connectProvider, (_, _) {});
    // Beim Abmelden Wiedergabe beenden
    ref.listen(authProvider, (previous, next) {
      final wasLoggedIn = previous?.value?.isLoggedIn ?? false;
      final isLoggedIn = next.value?.isLoggedIn ?? false;
      if (wasLoggedIn && !isLoggedIn) ref.read(audioHandlerProvider).reset();
    });
    final router = ref.watch(routerProvider);
    // Handy: nur Hochformat (Tablet und Computer frei). Updates auch bei laufender App suchen.
    return OrientationLock(
      child: UpdateWatcher(
        child: AppConfigWatcher(
          child: MaterialApp.router(
            title: 'Selfify',
            debugShowCheckedModeBanner: false,
            theme: buildTheme(),
            darkTheme: buildTheme(),
            themeMode: ThemeMode.dark,
            routerConfig: router,
            // Computer: Tastenkürzel und Desktop-Aktionen (Handy: unverändert). Scrollen per Mausrad/Scrollleiste –
            // Ziehen mit der Maus würde Klicks verschlucken, sobald sich die Maus dabei 1–2 Pixel bewegt.
            shortcuts: isDesktopPlatform ? desktopShortcuts : null,
            // Computer: Tastenkürzel. Alle: Pflicht-Update der Play-Version ersetzt die App durch einen Hinweis.
            builder: (context, child) {
              final content = UpdateGate(
                child: child ?? const SizedBox.shrink(),
              );
              return isDesktopPlatform
                  ? DesktopActions(child: content)
                  : content;
            },
            locale: const Locale('de'),
            supportedLocales: const [Locale('de'), Locale('en')],
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
          ),
        ),
      ),
    );
  }
}
