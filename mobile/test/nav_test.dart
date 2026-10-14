// Navigation: Detailseiten aus Vollbild-Seiten (Player, Downloads …) heraus öffnen.
// go_router stürzt ab, wenn eine Tab-Seite über eine Vollbild-Seite gelegt wird – Nav schließt
// die Vollbild-Seite deshalb vorher.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:selfify/ui/nav.dart';

Widget _button(String label, void Function(BuildContext context) onTap) =>
    Builder(builder: (context) => TextButton(onPressed: () => onTap(context), child: Text(label)));

GoRouter _router() => GoRouter(initialLocation: '/home', routes: [
      StatefulShellRoute.indexedStack(
        builder: (_, _, shell) => Scaffold(body: shell),
        branches: [
          for (final tab in ['home', 'search'])
            StatefulShellBranch(routes: [
              GoRoute(
                path: '/$tab',
                builder: (_, _) => Column(children: [Text('tab $tab'), _button('Player', Nav.player)]),
                routes: [
                  GoRoute(path: 'album/:id', builder: (_, s) => Text('$tab album ${s.pathParameters['id']}')),
                  GoRoute(path: 'artist/:id', builder: (_, s) => Text('$tab artist ${s.pathParameters['id']}')),
                ],
              ),
            ]),
        ],
      ),
      GoRoute(
        path: '/player',
        builder: (_, _) => Scaffold(
          body: Column(children: [
            const Text('player'),
            _button('Album', (c) => Nav.album(c, 7)),
            _button('Warteschlange', Nav.queue),
          ]),
        ),
      ),
      GoRoute(
        path: '/queue',
        builder: (_, _) => Scaffold(body: _button('Künstler', (c) => Nav.artist(c, 3))),
      ),
      GoRoute(
        path: '/downloads',
        builder: (_, _) => Scaffold(body: _button('Album', (c) => Nav.album(c, 9))),
      ),
    ]);

void main() {
  testWidgets('Album aus dem Player öffnen', (tester) async {
    final router = _router();
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.tap(find.text('Player'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Album'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('home album 7'), findsOneWidget);
    // Zurück landet im Tab, nicht wieder im Player
    router.pop();
    await tester.pumpAndSettle();
    expect(find.text('tab home'), findsOneWidget);
  });

  testWidgets('Künstler aus der Warteschlange über dem Player öffnen (Such-Tab)', (tester) async {
    final router = _router();
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    router.go('/search');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Player'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Warteschlange'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Künstler'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('search artist 3'), findsOneWidget);
  });

  testWidgets('Album aus den Downloads öffnen', (tester) async {
    final router = _router();
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    router.push('/downloads');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Album'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('home album 9'), findsOneWidget);
  });

  testWidgets('Detailseite im Tab öffnet sich im selben Tab', (tester) async {
    final router = _router();
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    router.go('/search');
    await tester.pumpAndSettle();
    final context = tester.element(find.text('tab search'));
    Nav.album(context, 1);
    await tester.pumpAndSettle();
    expect(find.text('search album 1'), findsOneWidget);
  });
}
