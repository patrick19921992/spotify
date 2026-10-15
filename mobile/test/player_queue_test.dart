// Warteschlange des Players mit nachgebautem just_audio: Zufallswiedergabe, Qualitätswechsel,
// Schlaf-Timer und Autoplay.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:selfify/data/models.dart';
import 'package:selfify/player/audio_handler.dart';

import 'support/fake_audio.dart';
import 'support/fakes.dart';

List<Track> tracks(int count, {int from = 1}) =>
    [for (var i = from; i < from + count; i++) Track.fromJson(trackJson(i))];

Future<void> settle([int ms = 30]) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeJustAudio platform;
  var quality = 'original';

  setUp(() {
    platform = useFakeAudioPlatform();
    quality = 'original';
  });

  SelfifyAudioHandler handler() {
    final h = SelfifyAudioHandler();
    h.resolveSource = (track, item) => AudioSource.uri(Uri.parse('https://x/${track.id}?q=$quality'), tag: item);
    return h;
  }

  Future<void> finishQueue(SelfifyAudioHandler h) async {
    final player = platform.last!;
    player.proc = ProcessingStateMessage.completed;
    player.pos = const Duration(minutes: 3);
    player.emit();
    await settle(300);
  }

  test('Zufallswiedergabe: „Als Nächstes spielen“ kommt wirklich als Nächstes', () async {
    for (var run = 0; run < 10; run++) {
      final h = handler();
      unawaited(h.playTracks(tracks(20), shuffle: true));
      await settle();
      for (var skip = 0; skip < 5; skip++) {
        await h.skipToNext();
        await settle();
      }
      await h.playNext([Track.fromJson(trackJson(99))]);
      await settle();
      expect(h.tracks[h.player.nextIndex!].id, 99, reason: 'Durchlauf $run');
      await h.player.dispose();
    }
  });

  test('Zufallswiedergabe: „Zur Warteschlange“ landet am Ende, nicht vor dem aktuellen Titel', () async {
    for (var run = 0; run < 10; run++) {
      final h = handler();
      unawaited(h.playTracks(tracks(20), shuffle: true));
      await settle();
      for (var skip = 0; skip < 10; skip++) {
        await h.skipToNext();
        await settle();
      }
      await h.addTracks([Track.fromJson(trackJson(99))]);
      await settle();
      final order = h.playOrder;
      expect(order.last, h.tracks.indexWhere((t) => t.id == 99), reason: 'Durchlauf $run');
      await h.player.dispose();
    }
  });

  test('Zufallswiedergabe beginnt nicht immer mit dem ersten Titel', () async {
    final starts = <int?>{};
    for (var run = 0; run < 15; run++) {
      final h = handler();
      unawaited(h.playTracks(tracks(20), shuffle: true));
      await settle();
      starts.add(h.currentTrack?.id);
      await h.player.dispose();
    }
    expect(starts.length, greaterThan(1));
  });

  test('Wechsel WLAN → mobil: kommende Titel in neuer Qualität, laufender Titel unverändert', () async {
    final h = handler();
    h.streamQuality = 'original';
    unawaited(h.playTracks(tracks(6), shuffle: true));
    await settle();
    await h.skipToNext();
    await settle();
    final current = h.player.currentIndex!;
    final orderBefore = List.of(h.playOrder);
    final reports = <int>[];
    h.reportHistory = (track, seconds, context) => reports.add(track.id);

    quality = 'low';
    h.streamQuality = 'low';
    await settle(200);

    final children = platform.last!.children;
    expect(h.player.currentIndex, current);
    expect(h.playOrder, orderBefore, reason: 'Zufallsreihenfolge bleibt');
    for (var i = 0; i < children.length; i++) {
      expect(children[i].endsWith(i == current ? 'q=original' : 'q=low'), isTrue, reason: 'Titel $i: ${children[i]}');
    }
    expect(reports, isEmpty, reason: 'Kein Titelwechsel durch den Neuaufbau');
    await h.player.dispose();
  });

  test('Schlaf-Timer „Ende des Titels“ beim letzten Titel: Player hält an und lässt sich wieder starten', () async {
    final h = handler();
    h.autoplayEnabled = false;
    unawaited(h.playTracks(tracks(2)));
    await settle();
    await h.player.seek(Duration.zero, index: 1);
    await settle();
    h.sleepAtEndOfTrack();
    await finishQueue(h);
    expect(h.player.playing, isFalse);
    expect(h.player.currentIndex, 0);
    await h.player.dispose();
  });

  test('Autoplay läuft weiter, auch wenn die erste Runde per „Weiter“ im Pausenzustand kam', () async {
    final h = handler();
    var next = 100;
    h.autoplay = (last) async => [for (var i = 0; i < 2; i++) Track.fromJson(trackJson(next++))];
    unawaited(h.playTracks(tracks(2)));
    await settle();
    await h.player.seek(Duration.zero, index: 1);
    await settle();
    await h.pause();
    await settle();
    // „Weiter“ auf dem letzten Titel im Pausenzustand: play() kehrt erst beim nächsten Pausieren zurück
    unawaited(h.skipToNext());
    await settle(300);
    expect(h.tracks.length, 4, reason: 'erste Runde Autoplay');
    expect(h.player.playing, isTrue);
    await h.player.seek(Duration.zero, index: 3);
    await settle();
    await finishQueue(h);
    expect(h.tracks.length, 6, reason: 'zweite Runde Autoplay');
    await h.player.dispose();
  });
}
