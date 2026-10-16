// Lautstärke im Videoplayer der Desktop-App: Regler in der Player-Leiste, ↑/↓ und M, auch im Vollbild –
// dieselbe Lautstärke wie die Musik. Läuft mit nachgebautem Videoplayer.

import 'dart:async';

import 'package:chewie/chewie.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfify/player/player.dart';
import 'package:selfify/state/auth.dart';
import 'package:selfify/ui/desktop/desktop_shortcuts.dart' show debugResetDesktopMute;
import 'package:selfify/ui/screens/video_screen.dart';
import 'package:selfify/ui/widgets/video_volume.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'support/fakes.dart';

/// Videoplayer ohne echtes Video: meldet sich sofort bereit und merkt sich die Lautstärke.
class FakeVideoPlatform extends VideoPlayerPlatform {
  final volumes = <double>[];
  Size videoSize = const Size(1280, 720);
  final _events = <int, StreamController<VideoEvent>>{};
  var _next = 1;

  int _create() {
    final id = _next++;
    late final StreamController<VideoEvent> events;
    events = StreamController<VideoEvent>(
      onListen: () => events.add(VideoEvent(
        eventType: VideoEventType.initialized,
        duration: const Duration(minutes: 3),
        size: videoSize,
      )),
    );
    _events[id] = events;
    return id;
  }

  @override
  Future<void> init() async {}
  @override
  Future<int?> create(DataSource dataSource) async => _create();
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async => _create();
  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _events[playerId]!.stream;
  @override
  Future<void> dispose(int playerId) async => _events.remove(playerId)?.close();
  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> play(int playerId) async {}
  @override
  Future<void> pause(int playerId) async {}
  @override
  Future<void> setVolume(int playerId, double volume) async => volumes.add(volume);
  @override
  Future<void> seekTo(int playerId, Duration position) async {}
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;
  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}
  @override
  Widget buildView(int playerId) => const ColoredBox(color: Colors.black);
  @override
  Widget buildViewWithOptions(VideoViewOptions options) => const ColoredBox(color: Colors.black);
}

final windows = TargetPlatformVariant.only(TargetPlatform.windows);
final android = TargetPlatformVariant.only(TargetPlatform.android);

late FakeVideoPlatform video;
late SelfifyAudioHandler handler;

Future<void> pumpVideo(
  WidgetTester tester, {
  double musicVolume = 0.4,
  Size size = const Size(1280, 800),
  double textScale = 1.0,
}) async {
  handler = SelfifyAudioHandler();
  // Nicht abwarten: der Player meldet die Lautstärke sofort, die Plattform-Antwort kommt im Test nie
  handler.player.setVolume(musicVolume).ignore();
  await pumpScreen(tester, const _AfterLogin(), size: size, textScale: textScale, handler: handler);
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Videoseite erst öffnen, wenn die (nachgebaute) Anmeldung geladen ist – wie in der App.
class _AfterLogin extends ConsumerWidget {
  const _AfterLogin();

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      ref.watch(apiProvider) == null ? const SizedBox() : const VideoScreen(trackId: 2);
}

/// Seite schließen – beendet die Timer von Video und Player.
Future<void> close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
}

Finder get volumeSlider => find.descendant(of: find.byType(VideoVolumeControl), matching: find.byType(Slider));

/// Maus über den Player – er holt sich dann den Tastaturfokus und zeigt die Leiste.
Future<TestGesture> hover(WidgetTester tester) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: tester.getCenter(find.byType(Chewie)));
  await mouse.moveTo(tester.getCenter(find.byType(Chewie)) + const Offset(1, 1));
  await tester.pump(const Duration(milliseconds: 100));
  return mouse;
}

Future<double?> savedVolume() async => (await SharedPreferences.getInstance()).getDouble('desktop.volume');

void main() {
  setUp(() {
    video = FakeVideoPlatform();
    VideoPlayerPlatform.instance = video;
    debugResetDesktopMute();
    debugCubicMusicVolume = null;
  });

  testWidgets('PC: Regler in der Player-Leiste, startet mit der Lautstärke der Musik', (tester) async {
    await pumpVideo(tester);
    expectNoErrors(tester);
    expect(find.byType(VideoVolumeControl), findsOneWidget);
    expect(find.byIcon(Icons.volume_up), findsNothing, reason: 'chewies Stummschalter würde die Lautstärke nicht merken');
    expect(video.volumes.last, closeTo(0.4, 0.001), reason: 'gleiche Lautstärke wie die Musik');
    expect(tester.widget<Slider>(volumeSlider).value, closeTo(0.4, 0.001));

    // Regler bewegen: Video, Musik und gespeicherter Wert folgen
    tester.widget<Slider>(volumeSlider).onChanged!(0.7);
    await tester.pump(const Duration(milliseconds: 100));
    expect(video.volumes.last, closeTo(0.7, 0.001));
    expect(handler.player.volume, closeTo(0.7, 0.001));
    expect(await savedVolume(), closeTo(0.7, 0.001));

    // Stummschalten und wieder an
    await tester.tap(find.byTooltip('Stummschalten (M)'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(video.volumes.last, 0);
    await tester.tap(find.byTooltip('Ton an (M)'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(video.volumes.last, closeTo(0.7, 0.001));
    expectNoErrors(tester);
    await close(tester);
  }, variant: windows, timeout: const Timeout(Duration(seconds: 60)));

  testWidgets('PC: ↑/↓ lauter/leiser, M stumm – mit Anzeige im Bild; mit Umschalt nicht', (tester) async {
    await pumpVideo(tester, musicVolume: 0.5);
    // Der Player holt sich den Tastaturfokus, sobald die Maus darüber ist
    final gesture = await hover(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump(const Duration(milliseconds: 100));
    expect(handler.player.volume, closeTo(0.6, 0.001));
    expect(video.volumes.last, closeTo(0.6, 0.001));
    expect(find.text('Lautstärke 60 %'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump(const Duration(milliseconds: 100));
    expect(handler.player.volume, closeTo(0.4, 0.001));

    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.pump(const Duration(milliseconds: 100));
    expect(handler.player.volume, 0);
    expect(find.text('Stumm'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.pump(const Duration(milliseconds: 100));
    expect(handler.player.volume, closeTo(0.4, 0.001));

    // Anzeige verschwindet wieder
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('Lautstärke '), findsNothing);

    // Umschalt+↑ gehört der übrigen App
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump(const Duration(milliseconds: 100));
    expect(handler.player.volume, closeTo(0.4, 0.001));

    // Bis zum Anschlag: nie über 100 %
    for (var i = 0; i < 8; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    }
    await tester.pump(const Duration(milliseconds: 100));
    expect(handler.player.volume, 1.0);
    expectNoErrors(tester);
    await gesture.removePointer();
    await close(tester);
  }, variant: windows, timeout: const Timeout(Duration(seconds: 60)));

  testWidgets('PC: im Vollbild gibt es Regler und Tasten auch', (tester) async {
    await pumpVideo(tester, musicVolume: 0.5);
    final chewie = tester.widget<Chewie>(find.byType(Chewie)).controller..enterFullScreen();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(VideoVolumeControl), findsWidgets);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: const Offset(640, 300));
    await gesture.moveTo(const Offset(641, 301));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump(const Duration(milliseconds: 100));
    expect(handler.player.volume, closeTo(0.4, 0.001));
    expect(video.volumes.last, closeTo(0.4, 0.001));
    expectNoErrors(tester);
    await gesture.removePointer();
    chewie.exitFullScreen();
    await tester.pump(const Duration(seconds: 1));
    await close(tester);
  }, variant: windows, timeout: const Timeout(Duration(seconds: 60)));

  testWidgets('PC: kleinstes Fenster (480×560) – nur der Lautsprecher-Knopf, die Leiste läuft nicht über', (tester) async {
    await pumpVideo(tester, size: const Size(480, 560));
    expectNoErrors(tester);
    expect(find.byType(VideoVolumeControl), findsOneWidget);
    expect(volumeSlider, findsNothing);
    expect(find.byTooltip('Stummschalten (M)'), findsOneWidget);
    await close(tester);
  }, variant: windows, timeout: const Timeout(Duration(seconds: 60)));

  for (final (name, size, scale) in [
    ('maximiertes Laptop-Fenster', const Size(1280, 650), 1.0),
    ('kleinstes Fenster, große Schrift', const Size(480, 560), 1.5),
  ]) {
    testWidgets('PC: Hochkant-Video, $name – Leiste und Anzeige laufen nicht über, Vollbild-Knopf geht', (tester) async {
      video.videoSize = const Size(720, 1280);
      await pumpVideo(tester, size: size, textScale: scale, musicVolume: 1);
      expectNoErrors(tester);
      expect(volumeSlider, findsNothing, reason: 'Player zu schmal für den Regler');
      final mouse = await hover(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Lautstärke 90 %'), findsOneWidget);
      expectNoErrors(tester);
      await tester.tap(find.byIcon(Icons.fullscreen));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final chewie = tester.widget<Chewie>(find.byType(Chewie, skipOffstage: false)).controller;
      expect(chewie.isFullScreen, isTrue);
      chewie.exitFullScreen();
      await tester.pump(const Duration(seconds: 1));
      await mouse.removePointer();
      await close(tester);
    }, variant: windows, timeout: const Timeout(Duration(seconds: 60)));
  }

  testWidgets('PC: zehnmal leiser ergibt genau 0 („Stumm“), M bringt den Ton zurück', (tester) async {
    await pumpVideo(tester, musicVolume: 1);
    final mouse = await hover(tester);
    for (var i = 0; i < 10; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    }
    await tester.pump(const Duration(milliseconds: 100));
    expect(handler.player.volume, 0, reason: 'kein Gleitkomma-Rest wie 1e-16');
    expect(find.text('Stumm'), findsOneWidget);
    expect(find.byTooltip('Ton an (M)'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.pump(const Duration(milliseconds: 100));
    expect(handler.player.volume, 0.5, reason: 'ohne gemerkten Wert halbe Lautstärke, nicht 100 %');
    await mouse.removePointer();
    await close(tester);
  }, variant: windows, timeout: const Timeout(Duration(seconds: 60)));

  testWidgets('PC: stumm gestartet – „Ton an“ springt nicht auf 100 %', (tester) async {
    await pumpVideo(tester, musicVolume: 0);
    expect(video.volumes.last, 0);
    await tester.tap(find.byTooltip('Ton an (M)'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(handler.player.volume, 0.5);
    expect(video.volumes.last, 0.5);
    await close(tester);
  }, variant: windows, timeout: const Timeout(Duration(seconds: 60)));

  testWidgets('Windows: Video klingt so laut wie die Musik (libmpv rechnet kubisch)', (tester) async {
    debugCubicMusicVolume = true;
    await pumpVideo(tester, musicVolume: 0.5);
    expect(video.volumes.last, closeTo(0.125, 0.0001));
    tester.widget<Slider>(volumeSlider).onChanged!(0.8);
    await tester.pump(const Duration(milliseconds: 100));
    expect(handler.player.volume, closeTo(0.8, 0.0001));
    expect(video.volumes.last, closeTo(0.512, 0.0001));
    await close(tester);
  }, variant: windows, timeout: const Timeout(Duration(seconds: 60)));

  testWidgets('PC: beim langen Ziehen am Regler bleibt die Leiste sichtbar', (tester) async {
    await pumpVideo(tester, musicVolume: 0.5);
    final bar = find.ancestor(of: find.byType(VideoVolumeControl), matching: find.byType(AnimatedOpacity)).first;
    final mouse = await hover(tester);
    await mouse.moveTo(tester.getCenter(volumeSlider));
    await tester.pump(const Duration(milliseconds: 100));
    await mouse.down(tester.getCenter(volumeSlider));
    for (var i = 0; i < 5; i++) {
      await mouse.moveBy(Offset(i.isEven ? 6 : -4, 0));
      await tester.pump(const Duration(seconds: 1));
    }
    expect(tester.widget<AnimatedOpacity>(bar).opacity, 1.0, reason: 'chewie blendet sonst nach 3 s aus');
    await mouse.up();
    await mouse.removePointer();
    await close(tester);
  }, variant: windows, timeout: const Timeout(Duration(seconds: 60)));

  testWidgets('PC: Tab erreicht Lautsprecher und Regler nicht (Leertaste würde sonst auch stummschalten)', (tester) async {
    await pumpVideo(tester, musicVolume: 0.5);
    final mouse = await hover(tester);
    for (var i = 0; i < 15; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final focused = FocusManager.instance.primaryFocus?.context;
      expect(
        focused?.findAncestorWidgetOfExactType<VideoVolumeControl>(),
        isNull,
        reason: 'Tab Nr. ${i + 1} landet auf Lautsprecher oder Regler',
      );
    }
    expect(handler.player.volume, 0.5);
    await mouse.removePointer();
    await close(tester);
  }, variant: windows, timeout: const Timeout(Duration(seconds: 60)));

  testWidgets('Handy: kein eigener Regler (dort regeln die Lautstärketasten)', (tester) async {
    await pumpVideo(tester);
    expectNoErrors(tester);
    expect(find.byType(VideoVolumeControl), findsNothing);
    expect(find.byType(VideoVolumeKeys), findsNothing);
    expect(video.volumes.where((v) => (v - 0.4).abs() < 0.001), isEmpty, reason: 'Musiklautstärke gilt am Handy nicht');
    await close(tester);
  }, variant: android, timeout: const Timeout(Duration(seconds: 60)));
}
