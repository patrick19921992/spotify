// Handy-Ansicht: Funde aus den Bildschirmfotos mit echten Systemleisten – Hochformat-Sperre, flacher
// Update-Hinweis, kein Umbruch mitten im Wort, Knöpfe nicht versetzt, Songtext-Karte nicht unter der
// Navigationsleiste des Handys.

import 'package:chewie/chewie.dart';
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
import 'package:selfify/ui/screens/home_screen.dart';
import 'package:selfify/ui/screens/offline_screen.dart';
import 'package:selfify/ui/screens/player_screen.dart';
import 'package:selfify/ui/widgets/app_update.dart';
import 'package:selfify/ui/widgets/cards.dart';
import 'package:selfify/ui/widgets/cover.dart';
import 'package:selfify/ui/widgets/fit_text.dart';
import 'package:selfify/ui/widgets/orientation_lock.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'desktop_sizes_test.dart' show QueueHandlerX;
import 'support/fakes.dart';
import 'video_volume_test.dart' as v;

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
    late List<List<String>> calls;
    setUp(() {
      calls = [];
      appOrientations = DeviceOrientation.values;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'SystemChrome.setPreferredOrientations') {
            calls.add([for (final o in call.arguments as List) '$o'.replaceFirst('DeviceOrientation.', '')]);
          }
          return null;
        },
      );
    });
    tearDown(() => appOrientations = DeviceOrientation.values);

    /// Bildschirm (logisch) und Fenster festlegen, dann die Sperre aufbauen.
    Future<void> pumpLock(WidgetTester tester, {required Size screen, Size? window, double dpr = 2.625}) async {
      tester.view.devicePixelRatio = dpr;
      tester.view.display.devicePixelRatio = dpr;
      tester.view.display.size = screen * dpr;
      tester.view.physicalSize = (window ?? screen) * dpr;
      addTearDown(tester.view.reset);
      addTearDown(tester.view.display.reset);
      await tester.pumpWidget(const OrientationLock(child: SizedBox()));
      await tester.pump();
    }

    testWidgets('Handy: nur Hochformat (auch für den Videoplayer nach dem Vollbild)', (tester) async {
      await pumpLock(tester, screen: const Size(412, 915));
      expect(calls, [
        ['portraitUp'],
      ]);
      expect(appOrientations, [DeviceOrientation.portraitUp]);
    });

    testWidgets('Handy quer gehalten: trotzdem Handy', (tester) async {
      await pumpLock(tester, screen: const Size(915, 412));
      expect(calls.last, ['portraitUp']);
    });

    testWidgets('Tablet: dreht frei – auch im geteilten Bildschirm (schmales Fenster)', (tester) async {
      await pumpLock(tester, screen: const Size(800, 1280), window: const Size(400, 1280));
      expect(calls.last, hasLength(4));
      expect(appOrientations, DeviceOrientation.values);
    });

    testWidgets('Start mit unbekannter Größe (0×0): erst sperren, wenn die echte Größe da ist', (tester) async {
      await pumpLock(tester, screen: Size.zero, dpr: 1.0);
      expect(calls, isEmpty, reason: 'bei 0×0 nicht raten – sonst würden auch Tablets gesperrt');
      // Wie Android: Pixeldichte und Größe kommen zusammen
      tester.view.display.devicePixelRatio = 2.625;
      tester.view.devicePixelRatio = 2.625;
      tester.view.display.size = const Size(412, 915) * 2.625;
      tester.view.physicalSize = const Size(412, 915) * 2.625;
      await tester.pump();
      expect(calls, [
        ['portraitUp'],
      ]);
    });

    testWidgets('Zurück in die App (neues Android-Fenster): Sperre wird erneut gesetzt', (tester) async {
      await pumpLock(tester, screen: const Size(412, 915));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(calls, hasLength(2));
      expect(calls.last, ['portraitUp']);
    });

    testWidgets('Video im Vollbild: Zurückkehren (z. B. nach der Benachrichtigungsleiste) kippt es nicht hochkant',
        (tester) async {
      await pumpLock(tester, screen: const Size(412, 915));
      fullScreenOrientations = const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight];
      addTearDown(() => fullScreenOrientations = null);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(calls.last, ['landscapeLeft', 'landscapeRight']);
      expect(appOrientations, [DeviceOrientation.portraitUp], reason: 'die App selbst bleibt Hochformat');
    });

    testWidgets('Computer: nichts sperren', (tester) async {
      await pumpLock(tester, screen: const Size(500, 400));
      expect(calls, isEmpty);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('Video-Vollbild: danach wieder Hochformat statt frei drehen', (tester) async {
      appOrientations = const [DeviceOrientation.portraitUp];
      v.video = v.FakeVideoPlatform();
      VideoPlayerPlatform.instance = v.video;
      await v.pumpVideo(tester);
      final chewie = tester.widget<Chewie>(find.byType(Chewie)).controller..enterFullScreen();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(fullScreenOrientations, [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
      chewie.exitFullScreen();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(calls.last, ['portraitUp'], reason: 'chewie würde sonst alle Ausrichtungen freigeben');
      expect(fullScreenOrientations, isNull);
      await v.close(tester);
    }, timeout: const Timeout(Duration(seconds: 60)));

    testWidgets('Foldable während des Videos aufgeklappt: nach dem Vollbild gilt die neue Ausrichtung', (tester) async {
      appOrientations = const [DeviceOrientation.portraitUp];
      v.video = v.FakeVideoPlatform();
      VideoPlayerPlatform.instance = v.video;
      await v.pumpVideo(tester);
      final chewie = tester.widget<Chewie>(find.byType(Chewie)).controller..enterFullScreen();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      appOrientations = DeviceOrientation.values; // aufgeklappt: jetzt ein Tablet
      chewie.exitFullScreen();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(calls.last, hasLength(4));
      await v.close(tester);
    }, timeout: const Timeout(Duration(seconds: 60)));
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

    testWidgets('normales Handy mit großer Schrift: lieber zwei Zeilen als ein paar Buchstaben', (tester) async {
      await pumpBanner(tester, size: const Size(393, 852), scale: 1.6);
      expectNoErrors(tester);
      expect(find.text('Später'), findsOneWidget);
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

    testWidgets('Android 14+ (Schrift nicht linear vergrößert): Wort passt trotzdem in eine Zeile', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: _CurvedScaler()),
          child: Center(
            child: SizedBox(
              width: 300,
              child: WordSafeText('Lieblingssongs', style: const TextStyle(fontSize: 13)),
            ),
          ),
        ),
      ));
      final text = tester.widget<Text>(find.text('Lieblingssongs'));
      final paragraph = tester.renderObject<RenderParagraph>(find.text('Lieblingssongs'));
      expect(text.maxLines, 2, reason: 'passt verkleinert – kein Notfall-Kürzen');
      expect(paragraph.size.width, lessThanOrEqualTo(300));
      expect(paragraph.size.height, lessThan(text.style!.fontSize! * 1.5), reason: 'eine Zeile');
    });

    testWidgets('passt auch verkleinert nicht: eine Zeile mit „…“ statt Umbruch im Wort', (tester) async {
      await pumpTile(tester, 'Lieblingssongs', 60);
      expect(tester.widget<Text>(find.text('Lieblingssongs')).maxLines, 1);
    });

    testWidgets('Bindestrich: dort darf umbrochen werden – keine unnötige Verkleinerung', (tester) async {
      // „Hip-Hop-Klassiker“ (17 Zeichen) passt nicht in 140 px, „Klassiker“ (9 Zeichen = 117 px) schon
      await pumpTile(tester, 'Hip-Hop-Klassiker', 140);
      expect(tester.widget<Text>(find.text('Hip-Hop-Klassiker')).style!.fontSize, 13);
    });

    testWidgets('mehrere kurze Wörter: normale Größe, Umbruch zwischen den Wörtern', (tester) async {
      await pumpTile(tester, 'A Night at the Opera', 140);
      expect(tester.widget<Text>(find.text('A Night at the Opera')).style!.fontSize, 13);
    });
  });

  testWidgets('Schnellzugriff mit großer Schrift: Künstler bleibt rund (keine Tonnenform)', (tester) async {
    await pumpScreen(tester, const HomeScreen(), size: const Size(360, 780), textScale: 2.0);
    expectNoErrors(tester);
    final artist = find.descendant(of: find.byType(QuickTile), matching: find.byWidgetPredicate((w) => w is CoverImage && w.circle));
    expect(artist, findsWidgets);
    expect(tester.getSize(artist.first), const Size(56, 56));
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

/// Vergrößert kleine Schriften stärker als große – wie Android 14+ (13 → 26, 10 → 23).
class _CurvedScaler extends TextScaler {
  const _CurvedScaler();

  @override
  double scale(double fontSize) => fontSize + 13;

  @override
  double get textScaleFactor => 2;
}
