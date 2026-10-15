// Warteschlange und Mini-Player mit echter Warteschlange (Player ohne Audio-Gerät).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:selfify/data/api.dart';
import 'package:selfify/data/models.dart';
import 'package:selfify/player/player.dart';
import 'package:selfify/ui/screens/queue_screen.dart';
import 'package:selfify/ui/widgets/mini_player.dart';

import 'support/fakes.dart';

class _Player extends AudioPlayer {
  int? index;

  @override
  int? get currentIndex => index;
  @override
  bool get shuffleModeEnabled => false;
  @override
  bool get playing => false;
}

/// Player mit fester Warteschlange, die sich wie die echte entfernen lässt.
class _QueueHandler extends SelfifyAudioHandler {
  final _Player fake = _Player();
  final List<Track> list = [];

  _QueueHandler(List<Track> tracks, {int index = 0}) {
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

  @override
  Future<void> removeQueueItemAt(int index) async {
    if (index < 0 || index >= list.length || index == fake.index) return;
    list.removeAt(index);
    queue.add(list.map(mediaItemFor).toList());
  }
}

/// Server nicht erreichbar, wenn ein Herz gesetzt wird.
class _OfflineLikeApi extends FakeApi {
  @override
  Future<void> setLiked(int trackId, bool liked) async =>
      throw const ApiException('Server nicht erreichbar. Bist du online?');
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('Warteschlange: Wegwischen einer von zwei gleichen Kopien lässt die andere sichtbar', (tester) async {
    final t = sampleTracks(3);
    // Zweimal „Zur Warteschlange hinzufügen“ – dasselbe Titel-Objekt direkt hintereinander
    final handler = _QueueHandler([t[0], t[1], t[1], t[2]]);
    await pumpScreen(tester, const QueueScreen(), handler: handler);
    expect(find.text(t[1].title), findsNWidgets(2));

    await tester.drag(find.text(t[1].title).first, const Offset(-600, 0));
    await settle(tester);

    expectNoErrors(tester);
    expect(handler.list, [t[0], t[1], t[2]]);
    expect(find.text(t[1].title), findsOneWidget, reason: 'die verbliebene Kopie bleibt sichtbar');
    expect(tester.getSize(find.ancestor(of: find.text(t[1].title), matching: find.byType(ListTile))).height,
        greaterThan(40));

    // Die verbliebene Kopie lässt sich ebenfalls entfernen
    await tester.drag(find.text(t[1].title), const Offset(-600, 0));
    await settle(tester);
    expectNoErrors(tester);
    expect(handler.list, [t[0], t[2]]);
  });

  testWidgets('Mini-Player: Herz ohne Verbindung zeigt einen Hinweis statt still zu scheitern', (tester) async {
    final t = sampleTracks(3);
    await pumpScreen(
      tester,
      const Scaffold(body: Align(alignment: Alignment.bottomCenter, child: MiniPlayer())),
      api: _OfflineLikeApi(),
      handler: _QueueHandler(t, index: 1),
    );
    await tester.tap(find.byIcon(Icons.favorite_border_rounded));
    await settle(tester);

    expectNoErrors(tester);
    expect(find.text('Server nicht erreichbar. Bist du online?'), findsOneWidget);
    expect(find.byIcon(Icons.favorite_border_rounded), findsOneWidget, reason: 'Herz springt zurück');
  });
}
