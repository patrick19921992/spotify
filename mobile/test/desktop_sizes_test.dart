// Scratch verification: existing screens rendered at desktop content-area sizes.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:selfify/data/models.dart';
import 'package:selfify/player/player.dart';
import 'package:selfify/ui/screens/player_screen.dart';
import 'package:selfify/ui/screens/queue_screen.dart';
import 'package:selfify/ui/widgets/mini_player.dart';

import 'screens_test.dart' show cases;
import 'support/fakes.dart';

class FakeQueuePlayer extends AudioPlayer {
  int? index;
  @override
  int? get currentIndex => index;
  @override
  bool get shuffleModeEnabled => false;
  @override
  bool get playing => false;
}

class QueueHandlerX extends SelfifyAudioHandler {
  final FakeQueuePlayer fake = FakeQueuePlayer();
  final List<Track> list = [];
  QueueHandlerX(List<Track> tracks, {int index = 0}) {
    list.addAll(tracks);
    fake.index = index;
    mediaItem.add(mediaItemFor(tracks[index]));
    queue.add(tracks.map(mediaItemFor).toList());
  }
  @override
  AudioPlayer get player => fake;
  @override
  List<Track> get tracks => List.unmodifiable(list);
  @override
  Track? get currentTrack {
    final i = fake.index;
    return i != null && i < list.length ? list[i] : null;
  }

  @override
  List<int> get playOrder => List.generate(list.length, (i) => i);
}

const sizes = <String, Size>{
  'content-min 448x512': Size(448, 512),
  'content 660x712': Size(660, 712),
  'window 1280x800': Size(1280, 800),
  'window 1920x1080': Size(1920, 1080),
};

void main() {
  for (final screen in cases) {
    group('desktop ${screen.name}', () {
      for (final entry in sizes.entries) {
        testWidgets(entry.key, (tester) async {
          await pumpScreen(tester, screen.build(), size: entry.value);
          expectNoErrors(tester);
        });
      }
    });
  }

  for (final entry in sizes.entries) {
    testWidgets('Player playing ${entry.key}', (tester) async {
      final t = sampleTracks(4);
      await pumpScreen(tester, const PlayerScreen(), handler: QueueHandlerX(t, index: 1), size: entry.value);
      expectNoErrors(tester);
      expect(find.text(t[1].title), findsWidgets);
    });
    testWidgets('Queue with items ${entry.key}', (tester) async {
      final t = sampleTracks(6);
      await pumpScreen(tester, const QueueScreen(), handler: QueueHandlerX(t, index: 1), size: entry.value);
      expectNoErrors(tester);
      expect(find.text(t[3].title), findsWidgets);
    });
    testWidgets('MiniPlayer ${entry.key}', (tester) async {
      final t = sampleTracks(3);
      await pumpScreen(
        tester,
        const Scaffold(body: Align(alignment: Alignment.bottomCenter, child: MiniPlayer())),
        handler: QueueHandlerX(t, index: 1),
        size: entry.value,
      );
      expectNoErrors(tester);
    });
  }
}
