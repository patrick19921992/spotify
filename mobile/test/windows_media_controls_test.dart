// Windows-Medienübersicht (SMTC): Titel/Status/Zeitleiste gehen an Windows, Medientasten an den Player.
// Läuft unter Linux mit nachgebauter Medienübersicht.

import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smtc_windows/smtc_windows.dart';
import 'package:selfify/player/windows_media_controls.dart';
import 'package:selfify/ui/desktop/desktop_shortcuts.dart';

class FakeBackend implements MediaControlsBackend {
  final buttonsController = StreamController<PressedButton>.broadcast();
  final tracks = <Map<String, String?>>[];
  final statuses = <PlaybackStatus>[];
  final timelines = <(Duration, Duration)>[];
  int clears = 0;

  @override
  Stream<PressedButton> get buttons => buttonsController.stream;

  @override
  Future<void> showTrack({required String title, String? artist, String? album, String? cover}) async =>
      tracks.add({'title': title, 'artist': artist, 'album': album, 'cover': cover});

  @override
  Future<void> clear() async => clears++;

  @override
  Future<void> setStatus(PlaybackStatus status) async => statuses.add(status);

  @override
  Future<void> setTimeline(Duration position, Duration duration) async => timelines.add((position, duration));
}

/// Zeichnet die Reihenfolge auf; jeder Aufruf dauert unterschiedlich lange (wie parallele Rust-Aufgaben).
class _OrderBackend implements MediaControlsBackend {
  final List<String> order;
  _OrderBackend(this.order);
  var _delay = 12;

  Future<void> _record(String what) async {
    _delay = _delay == 12 ? 1 : 12;
    await Future<void>.delayed(Duration(milliseconds: _delay));
    order.add(what);
  }

  @override
  Stream<PressedButton> get buttons => const Stream.empty();
  @override
  Future<void> showTrack({required String title, String? artist, String? album, String? cover}) =>
      _record('track:$title');
  @override
  Future<void> clear() => _record('clear');
  @override
  Future<void> setStatus(PlaybackStatus status) async {}
  @override
  Future<void> setTimeline(Duration position, Duration duration) => _record('timeline');
}

class FakeHandler extends BaseAudioHandler {
  final calls = <String>[];
  bool failNext = false;

  @override
  Future<void> play() async => calls.add('play');
  @override
  Future<void> pause() async => calls.add('pause');
  @override
  Future<void> skipToNext() async {
    calls.add('next');
    if (failNext) throw StateError('Ende der Warteschlange');
  }

  @override
  Future<void> skipToPrevious() async => calls.add('previous');
}

MediaItem item(String id, {String? art}) => MediaItem(
      id: id,
      title: 'Titel $id',
      artist: 'Band',
      album: 'Album',
      duration: const Duration(minutes: 3),
      artUri: art == null ? null : Uri.parse(art),
    );

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 120));

void main() {
  late FakeBackend backend;
  late FakeHandler handler;
  late WindowsMediaControls controls;

  setUp(() {
    backend = FakeBackend();
    handler = FakeHandler();
    controls = WindowsMediaControls(handler, backend)..start();
  });
  tearDown(() => controls.stop());

  test('Medientasten und Knöpfe der Medienübersicht steuern den Player', () async {
    handler.mediaItem.add(item('1'));
    for (final button in [PressedButton.play, PressedButton.pause, PressedButton.next, PressedButton.previous]) {
      backend.buttonsController.add(button);
    }
    await settle();
    expect(handler.calls, ['play', 'pause', 'next', 'previous']);
  });

  test('Abspielen ohne Titel (z. B. nach dem Abmelden) wird ignoriert', () async {
    backend.buttonsController.add(PressedButton.play);
    await settle();
    expect(handler.calls, isEmpty);
  });

  test('Titelwechsel: erst leeren, dann neu setzen (kein Cover/Album des vorigen Titels) – in dieser Reihenfolge',
      () async {
    final order = <String>[];
    final ordered = _OrderBackend(order);
    final h = FakeHandler();
    final c = WindowsMediaControls(h, ordered)..start();
    addTearDown(c.stop);
    await settle();
    order.clear();
    h.mediaItem.add(item('1', art: 'https://x/cover1'));
    h.mediaItem.add(item('2'));
    await settle();
    expect(order, ['clear', 'track:Titel 1', 'timeline', 'clear', 'track:Titel 2', 'timeline']);
  });

  test('Fehler beim Weiterschalten (Ende der Warteschlange) bleiben still', () async {
    handler.failNext = true;
    backend.buttonsController.add(PressedButton.next);
    await settle();
    expect(handler.calls, ['next']);
  });

  test('Titel mit Cover (nur http/https) und Zeitleiste gehen an Windows', () async {
    handler.mediaItem.add(item('1', art: 'https://musik.example.de/api/covers/abc?size=600&t=x'));
    await settle();
    expect(backend.tracks.last, {
      'title': 'Titel 1',
      'artist': 'Band',
      'album': 'Album',
      'cover': 'https://musik.example.de/api/covers/abc?size=600&t=x',
    });
    expect(backend.timelines.last, (Duration.zero, const Duration(minutes: 3)));

    handler.mediaItem.add(item('2', art: 'file:///C:/Users/x/cover.jpg'));
    await settle();
    expect(backend.tracks.last['cover'], isNull, reason: 'lokale Dateien kann Windows hier nicht laden');

    final clearsBefore = backend.clears; // beim Start (noch kein Titel) wurde schon einmal geleert
    handler.mediaItem.add(null);
    await settle();
    expect(backend.clears, clearsBefore + 1);
  });

  test('Status: gestoppt ohne Titel, dann spielt / pausiert – und nur bei Änderungen', () async {
    handler.mediaItem.add(item('1'));
    handler.playbackState.add(PlaybackState(playing: true, processingState: AudioProcessingState.ready));
    await settle();
    handler.playbackState.add(PlaybackState(playing: true, processingState: AudioProcessingState.buffering));
    await settle();
    handler.playbackState.add(PlaybackState(playing: false, processingState: AudioProcessingState.ready));
    await settle();
    expect(backend.statuses, [PlaybackStatus.stopped, PlaybackStatus.playing, PlaybackStatus.paused]);
  });

  test('Zeitleiste nur bei Sprüngen (Spulen), nicht bei jedem Ereignis', () async {
    handler.mediaItem.add(item('1'));
    handler.playbackState.add(PlaybackState(
      playing: true,
      processingState: AudioProcessingState.ready,
      updatePosition: const Duration(seconds: 10),
    ));
    await settle();
    final before = backend.timelines.length;
    // gleiches Ereignis kurz danach (z. B. Puffer-Meldung): keine neue Zeitleiste
    handler.playbackState.add(PlaybackState(
      playing: true,
      processingState: AudioProcessingState.ready,
      updatePosition: const Duration(seconds: 10),
    ));
    await settle();
    expect(backend.timelines.length, before);
    // Spulen auf 2:00
    handler.playbackState.add(PlaybackState(
      playing: true,
      processingState: AudioProcessingState.ready,
      updatePosition: const Duration(minutes: 2),
    ));
    await settle();
    expect(backend.timelines.last.$1.inSeconds, inInclusiveRange(119, 121));
  });

  test('Medienübersicht aktiv: Medientasten nicht zusätzlich als Tastenkürzel im Fenster (sonst doppelt)', () {
    bool hasMediaKey() => desktopShortcuts.keys
        .any((a) => a is SingleActivator && a.trigger == LogicalKeyboardKey.mediaPlayPause);
    expect(hasMediaKey(), isTrue, reason: 'ohne Medienübersicht bleiben sie im Fenster');
    windowsMediaControlsActive = true;
    addTearDown(() => windowsMediaControlsActive = false);
    expect(hasMediaKey(), isFalse);
    expect(desktopShortcuts.keys.any((a) => a is SingleActivator && a.trigger == LogicalKeyboardKey.space), isTrue);
  });
}
