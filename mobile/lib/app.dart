import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme.dart';
import 'player/player.dart';
import 'state/auth.dart';
import 'ui/router.dart';

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
    return MaterialApp.router(
      title: 'Selfify',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      darkTheme: buildTheme(),
      themeMode: ThemeMode.dark,
      routerConfig: router,
      locale: const Locale('de'),
      supportedLocales: const [Locale('de'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
    );
  }
}
