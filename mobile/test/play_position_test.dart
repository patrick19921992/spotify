// Abspielen ab einer Position: derselbe Titel darf mehrfach in der Liste stehen (Playlist).

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfify/data/models.dart';
import 'package:selfify/player/player.dart';
import 'package:selfify/state/auth.dart';
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
    ]);
    addTearDown(container.dispose);
    final tracks = sampleTracks(2);
    final queue = [tracks[0], tracks[1], tracks[0]];
    await container.read(playerProvider).play(queue, index: 2);
    expect(handler.startIndex, 2);
    // Videos werden übersprungen, die Position bleibt richtig
    final video = Track.fromJson(trackJson(9, mediaType: 'video'));
    await container.read(playerProvider).play([video, ...queue], index: 3);
    expect(handler.played!.length, 3);
    expect(handler.startIndex, 2);
  });
}
