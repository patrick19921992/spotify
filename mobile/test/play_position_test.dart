// Abspielen ab einer Position (derselbe Titel darf mehrfach in der Liste stehen) und Videos in der
// Musik-Warteschlange: Sie laufen als Ton mit (wie Musikvideos bei Spotify), statt herausgefiltert zu werden.
// Geprüft mit dem echten Audio-Handler und nachgebautem just_audio – ein Ersatz-Handler würde übersehen,
// wenn der Handler selbst noch filtert.

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfify/data/models.dart';
import 'package:selfify/player/player.dart';
import 'package:selfify/state/auth.dart';
import 'package:selfify/state/connectivity.dart';
import 'package:selfify/state/offline.dart';
import 'package:selfify/state/settings.dart';
import 'package:selfify/ui/screens/library_widgets.dart';
import 'package:selfify/ui/widgets/common.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_audio.dart';
import 'support/fakes.dart';

Future<void> settle([int ms = 30]) => Future<void>.delayed(Duration(milliseconds: ms));

final video = Track.fromJson(trackJson(9, mediaType: 'video'));

/// Echter Handler, verbunden wie in der App (Stream-Links vom Server, Offline-Speicher, Netz).
Future<(ProviderContainer, SelfifyAudioHandler)> connectedHandler({OfflineState? offline}) async {
  SharedPreferences.setMockInitialValues({});
  final handler = SelfifyAudioHandler();
  final container = ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWithValue(await SharedPreferences.getInstance()),
    audioHandlerProvider.overrideWithValue(handler),
    authProvider.overrideWith(() => FakeAuth(FakeApi())),
    connectivityProvider.overrideWith((ref) => Stream.value([ConnectivityResult.wifi])),
    offlineProvider.overrideWith(() => FakeOffline(offline ?? const OfflineState(loaded: true))),
  ]);
  addTearDown(container.dispose);
  addTearDown(handler.player.dispose);
  await container.read(authProvider.future);
  container.read(playbackBridgeProvider);
  return (container, handler);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeJustAudio platform;

  setUp(() => platform = useFakeAudioPlatform());

  test('Zweite Kopie eines doppelten Titels startet an ihrer eigenen Stelle – auch mit Video davor', () async {
    final (container, handler) = await connectedHandler();
    final tracks = sampleTracks(2);
    final queue = [tracks[0], tracks[1], tracks[0]];
    unawaited(container.read(playerProvider).play(queue, index: 2));
    await settle();
    expect(handler.player.currentIndex, 2);

    unawaited(container.read(playerProvider).play([video, ...queue], index: 3));
    await settle();
    expect(handler.tracks, [video, ...queue]);
    expect(handler.player.currentIndex, 3);
  });

  test('Song + Video in den Lieblingssongs: das Video läuft danach als Ton (nur die Tonspur)', () async {
    final (container, handler) = await connectedHandler();
    final song = sampleTracks(1).first;
    unawaited(container.read(playerProvider).play([song, video], context: const PlayContext('liked')));
    await settle();
    expect(handler.tracks, [song, video]);
    final links = platform.last!.children;
    expect(links, hasLength(2));
    expect(links[0], isNot(contains('audio_only')));
    expect(links[1], contains('audio_only=true'));
  });

  test('„Zur Warteschlange“ und „Als Nächstes“ nehmen Videos mit', () async {
    final (container, handler) = await connectedHandler();
    final songs = sampleTracks(2);
    unawaited(container.read(playerProvider).play(songs));
    await settle();
    await container.read(playerProvider).addToQueue([video]);
    expect(handler.tracks.last, video);
    final other = Track.fromJson(trackJson(10, mediaType: 'video'));
    await container.read(playerProvider).playNext([other]);
    expect(handler.tracks[1], other);
  });

  test('Offline: Videos (nicht speicherbar) bleiben draußen, die heruntergeladenen Songs laufen', () async {
    final offline = offlineWithTracks(); // Songs 1 und 2 auf dem Gerät
    final (container, handler) = await connectedHandler(offline: offline);
    await container.read(settingsProvider.notifier).update((s) => s.copyWith(offlineMode: true));
    final songs = offline.tracks.values.map((t) => t.track).toList();
    unawaited(container.read(playerProvider).play([songs[0], video, songs[1]], index: 2));
    await settle();
    expect(handler.tracks, songs);
    expect(handler.player.currentIndex, 1);
  });

  test('Playlist nur mit Videos: der echte Player spielt sie als Ton', () async {
    final (container, handler) = await connectedHandler();
    unawaited(container.read(playerProvider).play([video]));
    await settle();
    expect(handler.tracks, [video]);
    expect(platform.last!.children.single, contains('audio_only=true'));
  });

  testWidgets('Playlist nur mit Videos: „Abspielen“ ist aktiv und startet die Wiedergabe', (tester) async {
    final handler = _RecordingHandler();
    await pumpScreen(
      tester,
      Scaffold(
        body: Center(
          child: LibraryPlayControls(
            tracks: [video],
            playContext: const PlayContext('playlist', id: 5),
            matches: (_) => false,
          ),
        ),
      ),
      handler: handler,
    );
    await tester.tap(find.byType(PlayButton));
    await tester.pump();
    expect(handler.played, [video]);
  });
}

/// Zeichnet nur auf, was abgespielt werden soll (für den Knopf-Test ohne Player).
class _RecordingHandler extends SelfifyAudioHandler {
  List<Track>? played;

  @override
  Future<void> playTracks(List<Track> tracks, {int index = 0, PlayContext? context, bool shuffle = false}) async {
    played = tracks;
  }
}
