// Abspielen ab einer Position: derselbe Titel darf mehrfach in der Liste stehen (Playlist).

import 'package:audio_service/audio_service.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:selfify/data/models.dart';
import 'package:selfify/player/player.dart';
import 'package:selfify/state/auth.dart';
import 'package:selfify/state/connectivity.dart';
import 'package:selfify/state/offline.dart';
import 'package:selfify/ui/screens/library_widgets.dart';
import 'package:selfify/ui/widgets/common.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

class _RecordingHandler extends SelfifyAudioHandler {
  List<Track>? played;
  int? startIndex;

  @override
  Future<void> playTracks(List<Track> tracks, {int index = 0, PlayContext? context, bool shuffle = false}) async {
    played = tracks;
    startIndex = index;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Zweite Kopie eines doppelten Titels startet an ihrer eigenen Stelle', () async {
    SharedPreferences.setMockInitialValues({});
    final handler = _RecordingHandler();
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(await SharedPreferences.getInstance()),
      audioHandlerProvider.overrideWithValue(handler),
      // ohne Ersatz fragt der Test die echte Netzwerk-Erkennung (gibt es im Test nicht)
      connectivityProvider.overrideWith((ref) => Stream.value([ConnectivityResult.wifi])),
    ]);
    addTearDown(container.dispose);
    final tracks = sampleTracks(2);
    final queue = [tracks[0], tracks[1], tracks[0]];
    await container.read(playerProvider).play(queue, index: 2);
    expect(handler.startIndex, 2);
    // Videos laufen als Ton mit (wie bei Spotify) – sie werden nicht mehr übersprungen
    final video = Track.fromJson(trackJson(9, mediaType: 'video'));
    await container.read(playerProvider).play([video, ...queue], index: 3);
    expect(handler.played, [video, ...queue]);
    expect(handler.startIndex, 3);
  });

  test('Video in der Warteschlange: der Server liefert nur den Ton, Songs bleiben unverändert', () async {
    SharedPreferences.setMockInitialValues({});
    final handler = SelfifyAudioHandler();
    final api = FakeApi();
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(await SharedPreferences.getInstance()),
      audioHandlerProvider.overrideWithValue(handler),
      authProvider.overrideWith(() => FakeAuth(api)),
      connectivityProvider.overrideWith((ref) => Stream.value([ConnectivityResult.wifi])),
      offlineProvider.overrideWith(() => FakeOffline(const OfflineState(loaded: true))),
    ]);
    addTearDown(container.dispose);
    await container.read(authProvider.future);
    container.read(playbackBridgeProvider);
    String url(Track track) =>
        (handler.resolveSource!(track, MediaItem(id: '${track.id}', title: track.title)) as UriAudioSource).uri.toString();

    expect(url(Track.fromJson(trackJson(9, mediaType: 'video'))), contains('audio_only=true'));
    expect(url(sampleTracks(1).first), isNot(contains('audio_only')));
  });

  testWidgets('Playlist nur mit Videos: „Abspielen“ geht (als Ton)', (tester) async {
    final handler = _RecordingHandler();
    final video = Track.fromJson(trackJson(9, mediaType: 'video'));
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
