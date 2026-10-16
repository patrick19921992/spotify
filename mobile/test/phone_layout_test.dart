// Handy-Ansicht: Funde aus den Bildschirmfotos mit echten Systemleisten – Hochformat-Sperre, flacher
// Update-Hinweis, kein Umbruch mitten im Wort, Knöpfe nicht versetzt, Songtext-Karte nicht unter der
// Navigationsleiste des Handys.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfify/core/platform.dart';
import 'package:selfify/core/theme.dart';
import 'package:selfify/data/app_update.dart';
import 'package:selfify/state/app_update.dart';
import 'package:selfify/state/auth.dart';
import 'package:selfify/ui/screens/category_screen.dart';
import 'package:selfify/ui/screens/offline_screen.dart';
import 'package:selfify/ui/screens/player_screen.dart';
import 'package:selfify/ui/widgets/app_update.dart';
import 'package:selfify/ui/widgets/fit_text.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'desktop_sizes_test.dart' show QueueHandlerX;
import 'support/fakes.dart';

class _Update implements AppUpdateSource {
  @override
  bool get supported => true;
  @override
  UpdatePlatform get platform => UpdatePlatform.android;
  @override
  Future<int> installedBuild() async => 30;
  @override
  Future<AppRelease?> latest() async => AppRelease.fromJson({
        'build': 38,
        'version': '1.0.0',
        'android': {'url': 'https://x/selfify.apk', 'sha256': 'a' * 64},
      });
}

Future<void> pumpBanner(WidgetTester tester, {required Size size, double scale = 1.0}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      appUpdateSourceProvider.overrideWithValue(_Update()),
    ],
    child: MaterialApp(
      theme: buildTheme(),
      home: MediaQuery(
        data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale)),
        child: const Scaffold(body: Column(children: [Expanded(child: SizedBox()), UpdateBanner()])),
      ),
    ),
  ));
  await tester.pump();
  await tester.pump();
}

void main() {
  group('Hochformat auf dem Handy', () {
    late List<Object?> calls;
    setUp(() {
      calls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'SystemChrome.setPreferredOrientations') calls.add(call.arguments);
          return null;
        },
      );
    });

    Future<void> lockWith(WidgetTester tester, Size logical) async {
      tester.view.devicePixelRatio = 2.625;
      tester.view.physicalSize = logical * 2.625;
      addTearDown(tester.view.reset);
      await lockPortraitOnPhones(tester.view);
    }

    testWidgets('Handy (auch quer gestartet): nur Hochformat', (tester) async {
      await lockWith(tester, const Size(915, 412));
      expect(calls, [
        ['DeviceOrientation.portraitUp'],
      ]);
    });

    testWidgets('Tablet: dreht frei', (tester) async {
      await lockWith(tester, const Size(800, 1280));
      expect(calls, isEmpty);
    });

    testWidgets('Computer: dreht frei (Fenster)', (tester) async {
      await lockWith(tester, const Size(500, 400));
      expect(calls, isEmpty);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  });

  group('Update-Hinweis', () {
    testWidgets('mit Platz: eine flache Zeile (× statt „Später“), damit der Inhalt Platz behält', (tester) async {
      await pumpBanner(tester, size: const Size(600, 800));
      expectNoErrors(tester);
      expect(tester.getSize(find.byType(UpdateBanner)).height, lessThan(72));
      expect(find.byTooltip('Später'), findsOneWidget);
      expect(find.text('Installieren'), findsOneWidget);
    });

    testWidgets('schmal mit großer Schrift: Knöpfe darunter, Text bleibt lesbar', (tester) async {
      await pumpBanner(tester, size: const Size(320, 568), scale: 1.6);
      expectNoErrors(tester);
      expect(find.text('Später'), findsOneWidget);
      expect(tester.getSize(find.text('Neue App-Version verfügbar')).width, greaterThan(150));
    });

    testWidgets('„×“ blendet den Hinweis aus', (tester) async {
      await pumpBanner(tester, size: const Size(600, 800));
      await tester.tap(find.byTooltip('Später'));
      await tester.pump();
      expect(find.text('Neue App-Version verfügbar'), findsNothing);
    });
  });

  group('Kein Umbruch mitten im Wort', () {
    Future<RenderParagraph> pumpTile(WidgetTester tester, String text, double width) async {
      await tester.pumpWidget(MaterialApp(
        home: Center(
          child: SizedBox(width: width, child: WordSafeText(text, style: const TextStyle(fontSize: 13))),
        ),
      ));
      return tester.renderObject<RenderParagraph>(find.text(text));
    }

    testWidgets('langes Einzelwort wird kleiner statt umzubrechen', (tester) async {
      // Testschrift: jedes Zeichen 1 em breit – „Lieblingssongs“ (14 Zeichen) braucht bei 13 px 182 px
      final paragraph = await pumpTile(tester, 'Lieblingssongs', 140);
      final style = tester.widget<Text>(find.text('Lieblingssongs')).style!;
      expect(style.fontSize, lessThan(13));
      expect(paragraph.size.height, lessThan(style.fontSize! * 1.5), reason: 'eine Zeile, nicht „Lieblingssong“ / „s“');
    });

    testWidgets('mehrere kurze Wörter: normale Größe, Umbruch zwischen den Wörtern', (tester) async {
      await pumpTile(tester, 'A Night at the Opera', 140);
      expect(tester.widget<Text>(find.text('A Night at the Opera')).style!.fontSize, 13);
    });
  });

  testWidgets('Rubrik: „Zufallsmix“ ganz lesbar, Abspielknopf rechtsbündig', (tester) async {
    await pumpScreen(tester, const CategoryScreen(categoryId: 1), size: const Size(360, 780));
    expectNoErrors(tester);
    expect(tester.renderObject<RenderParagraph>(find.text('Zufallsmix')).didExceedMaxLines, isFalse);
    final shuffle = tester.getRect(find.ancestor(of: find.text('Zufallsmix'), matching: find.byType(OutlinedButton)));
    expect(shuffle.left, 16);
  });

  testWidgets('Gerätespeicher: Abschnittstitel bekommt die ganze Breite', (tester) async {
    await pumpScreen(tester, const OfflineScreen(), size: const Size(360, 780));
    await tester.scrollUntilVisible(find.text('Einstellungen'), 200, scrollable: find.byType(Scrollable).first);
    expect(tester.renderObject<RenderParagraph>(find.text('Einstellungen')).didExceedMaxLines, isFalse);
  });

  testWidgets('Player: Songtext-Karte liegt über der Navigationsleiste des Handys, nicht darunter', (tester) async {
    await pumpScreen(
      tester,
      const PlayerScreen(),
      size: const Size(360, 780),
      padding: const EdgeInsets.only(top: 24, bottom: 48),
      handler: QueueHandlerX(sampleTracks(3)),
    );
    expectNoErrors(tester);
    expect(tester.getRect(find.text('Songtext')).bottom, lessThanOrEqualTo(780 - 48));
  });
}
