// Desktop-Ansicht der ganzen App (echter Router, nachgebauter Server und Player).
import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:selfify/app.dart';
import 'package:selfify/player/player.dart';
import 'package:selfify/state/auth.dart';
import 'package:selfify/state/connectivity.dart';
import 'package:selfify/state/downloads.dart';
import 'package:selfify/state/offline.dart';
import 'package:selfify/ui/desktop/desktop_player_bar.dart';
import 'package:selfify/ui/desktop/desktop_right_panel.dart';
import 'package:selfify/ui/desktop/desktop_shell.dart';
import 'package:selfify/ui/router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';
import 'desktop_sizes_test.dart' show QueueHandlerX;

class CountingHandler extends QueueHandlerX {
  int plays = 0;
  int pauses = 0;
  int nexts = 0;
  CountingHandler(super.tracks, {super.index});
  @override
  Future<void> play() async => plays++;
  @override
  Future<void> pause() async => pauses++;
  @override
  Future<void> skipToNext() async => nexts++;
}

final windows = TargetPlatformVariant.only(TargetPlatform.windows);
final android = TargetPlatformVariant.only(TargetPlatform.android);

Future<FakeApi> pumpApp(WidgetTester tester, Size size, {SelfifyAudioHandler? handler, Map<String, Object> prefs = const {}}) async {
  final api = FakeApi();
  await initializeDateFormatting('de_DE');
  SharedPreferences.setMockInitialValues({'search.recent': <String>['queen'], ...prefs});
  final sp = await SharedPreferences.getInstance();
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => '/tmp/selfify-test',
  );
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(sp),
      audioHandlerProvider.overrideWithValue(handler ?? SelfifyAudioHandler()),
      authProvider.overrideWith(() => FakeAuth(api)),
      connectivityProvider.overrideWith((ref) => Stream.value([ConnectivityResult.wifi])),
      offlineProvider.overrideWith(() => FakeOffline(const OfflineState(loaded: true))),
      downloadsProvider.overrideWith(FakeDownloads.new),
    ],
    child: const SelfifyApp(),
  ));
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  return api;
}

Future<void> resize(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('Windows 1280x800: sidebar, player bar, no bottom nav', (tester) async {
    final t = sampleTracks(4);
    await pumpApp(tester, const Size(1280, 800), handler: QueueHandlerX(t, index: 1));
    expectNoErrors(tester);
    expect(find.byType(DesktopShell), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byType(DesktopPlayerBar), findsOneWidget);
    for (final text in ['Start', 'Suchen', 'Bibliothek', 'Lieblingssongs', 'Roadtrip 5', 'Roadtrip 6']) {
      expect(find.text(text), findsWidgets, reason: text);
    }
    expect(find.text(t[1].title), findsWidgets);
  }, variant: windows);

  testWidgets('Windows narrow desktop 900x600 uses icon rail', (tester) async {
    await pumpApp(tester, const Size(900, 600), handler: QueueHandlerX(sampleTracks(3), index: 0));
    expectNoErrors(tester);
    expect(find.byType(DesktopShell), findsOneWidget);
    expect(find.text('Suchen'), findsNothing); // only tooltip
  }, variant: windows);

  testWidgets('Windows 700 wide: phone layout', (tester) async {
    await pumpApp(tester, const Size(700, 800));
    expectNoErrors(tester);
    expect(find.byType(DesktopShell), findsNothing);
    expect(find.byType(NavigationBar), findsOneWidget);
  }, variant: windows);

  testWidgets('Android tablet 1280x800: unchanged phone layout', (tester) async {
    await pumpApp(tester, const Size(1280, 800));
    expectNoErrors(tester);
    expect(find.byType(DesktopShell), findsNothing);
    expect(find.byType(NavigationBar), findsOneWidget);
  }, variant: android);

  testWidgets('Sidebar playlist opens in content; resize keeps page', (tester) async {
    await pumpApp(tester, const Size(1280, 800), handler: QueueHandlerX(sampleTracks(3), index: 0));
    await tester.tap(find.text('Roadtrip 5').first);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expectNoErrors(tester);
    expect(find.text('Roadtrip 5'), findsWidgets);
    expect(find.text('Noch keine Songs'), findsNothing);
    final before = find.textContaining('3 Songs').evaluate().length;
    expect(before, greaterThan(0));
    await resize(tester, const Size(700, 800));
    expectNoErrors(tester);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.textContaining('3 Songs'), findsWidgets, reason: 'playlist page survives switching to phone layout');
    await resize(tester, const Size(1280, 800));
    expectNoErrors(tester);
    expect(find.byType(DesktopShell), findsOneWidget);
    expect(find.textContaining('3 Songs'), findsWidgets, reason: 'and back');
  }, variant: windows);

  testWidgets('Space toggles play, but not while typing in search; Ctrl+F focuses search', (tester) async {
    final handler = CountingHandler(sampleTracks(3), index: 0);
    await pumpApp(tester, const Size(1280, 800), handler: handler);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(handler.plays, 1, reason: 'space outside text field plays');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final focusedContext = FocusManager.instance.primaryFocus?.context;
    expect(focusedContext?.findAncestorWidgetOfExactType<EditableText>(), isNotNull,
        reason: 'search field has focus, got ${focusedContext?.widget}');

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(handler.plays, 1, reason: 'space typed into search field must not toggle playback');
    expectNoErrors(tester);
  }, variant: windows);

  testWidgets('Space on the video page belongs to the video, not to the music', (tester) async {
    final handler = CountingHandler(sampleTracks(3), index: 0);
    await pumpApp(tester, const Size(1280, 800), handler: handler);
    final container = ProviderScope.containerOf(tester.element(find.byType(DesktopShell)));
    container.read(routerProvider).push('/video/1');
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Video'), findsWidgets);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(handler.plays, 0, reason: 'space on the video page must not start the music');
    expect(handler.pauses, 0);
  }, variant: windows);

  testWidgets('Space on a keyboard-focused button presses the button instead of toggling playback', (tester) async {
    final handler = CountingHandler(sampleTracks(3), index: 0);
    await pumpApp(tester, const Size(1280, 800), handler: handler);
    final next = find.descendant(of: find.byTooltip('Weiter'), matching: find.byIcon(Icons.skip_next_rounded));
    Focus.of(tester.element(next)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(handler.nexts, 1, reason: 'the focused "Weiter" button is pressed');
    expect(handler.plays + handler.pauses, 0, reason: 'playback is not toggled as well');
  }, variant: windows);

  testWidgets('Ctrl+F while a dialog is open keeps the focus in the dialog', (tester) async {
    final handler = CountingHandler(sampleTracks(3), index: 0);
    await pumpApp(tester, const Size(1280, 800), handler: handler);
    final context = tester.element(find.byType(DesktopShell));
    unawaited(showDialog<void>(
      context: context,
      builder: (_) => const AlertDialog(content: TextField(autofocus: true)),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final focused = FocusManager.instance.primaryFocus?.context;
    expect(focused?.findAncestorWidgetOfExactType<AlertDialog>(), isNotNull, reason: 'focus stays in the dialog');
  }, variant: windows);

  testWidgets('Holding Space toggles playback only once', (tester) async {
    final handler = CountingHandler(sampleTracks(3), index: 0);
    await pumpApp(tester, const Size(1280, 800), handler: handler);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
    for (var i = 0; i < 5; i++) {
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.space);
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(handler.plays + handler.pauses, 1);
  }, variant: windows);

  testWidgets('Space without loaded track does nothing', (tester) async {
    final handler = CountingHandler(sampleTracks(1), index: 0)..fake.index = null;
    await pumpApp(tester, const Size(1280, 800), handler: handler);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(handler.plays, 0);
    expectNoErrors(tester);
  }, variant: windows);

  testWidgets('Media key play/pause', (tester) async {
    final handler = CountingHandler(sampleTracks(3), index: 0);
    await pumpApp(tester, const Size(1280, 800), handler: handler);
    await tester.sendKeyEvent(LogicalKeyboardKey.mediaPlayPause);
    await tester.pump();
    expect(handler.plays, 1);
  }, variant: windows);

  for (final size in const [Size(840, 600), Size(1100, 700), Size(1280, 800), Size(1920, 1080)]) {
    testWidgets('Panels at $size', (tester) async {
      final t = sampleTracks(6);
      await pumpApp(tester, size, handler: QueueHandlerX(t, index: 1));
      expectNoErrors(tester);
      await tester.tap(find.byTooltip('Warteschlange').first);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expectNoErrors(tester);
      expect(find.byType(DesktopRightPanel), findsOneWidget);
      expect(find.text(t[3].title), findsWidgets);
      await tester.tap(find.byTooltip('Songtext').first);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expectNoErrors(tester);
      expect(find.byType(DesktopLyricsPanel), findsOneWidget);
    }, variant: windows);
  }

  testWidgets('Snackbar from queue panel shows once', (tester) async {
    final t = sampleTracks(6);
    await pumpApp(tester, const Size(1280, 800), handler: QueueHandlerX(t, index: 1), prefs: {'desktop.panel': 'queue'});
    expect(find.byType(DesktopRightPanel), findsOneWidget);
    await tester.tap(find.text('Warteschlange leeren'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final e = tester.takeException();
    // clearUpcoming on the fake handler may fail – either message must show exactly once
    final shown = find.byType(SnackBar);
    expect(shown, findsOneWidget, reason: 'exception: $e');
  }, variant: windows);
}
