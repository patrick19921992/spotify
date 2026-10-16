import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme.dart';
import 'player/player.dart';
import 'state/auth.dart';
import 'ui/desktop/desktop_layout.dart';
import 'ui/desktop/desktop_shortcuts.dart';
import 'ui/router.dart';
import 'ui/widgets/orientation_lock.dart';

class SelfifyApp extends ConsumerWidget {
  const SelfifyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Player mit Server/Offline/Einstellungen verbinden
    ref.watch(playbackBridgeProvider);
    // Beim Abmelden Wiedergabe beenden
    ref.listen(authProvider, (previous, next) {
      final wasLoggedIn = previous?.value?.isLoggedIn ?? false;
      final isLoggedIn = next.value?.isLoggedIn ?? false;
      if (wasLoggedIn && !isLoggedIn) ref.read(audioHandlerProvider).reset();
    });
    final router = ref.watch(routerProvider);
    // Handy: nur Hochformat (Tablet und Computer frei)
    return OrientationLock(
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
        builder: isDesktopPlatform ? (context, child) => DesktopActions(child: child ?? const SizedBox.shrink()) : null,
        locale: const Locale('de'),
        supportedLocales: const [Locale('de'), Locale('en')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
      ),
    );
  }
}
