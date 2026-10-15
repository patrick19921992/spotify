// Windows-Wiedergabe: Warteschlange in QueueingAudioPlayer über einem Player, der – wie
// just_audio_media_kit/libmpv – nur einzelne Titel bekommt. Läuft unter Linux ohne libmpv.

import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:selfify/data/models.dart';
import 'package:selfify/player/audio_handler.dart';
import 'package:selfify/player/windows_audio.dart';

import 'support/fakes.dart';

/// Wie MediaKitPlayer: lädt genau einen Titel, meldet „fertig“ am Titelende, kennt keine Warteschlange.
class SingleTrackPlayer extends AudioPlayerPlatform {
  SingleTrackPlayer(super.id, this.failing);
  final Set<String> failing;
  final _events = StreamController<PlaybackEventMessage>.broadcast();
  final _data = StreamController<PlayerDataMessage>.broadcast();
  final loads = <String>[];
  String? uri;
  Duration pos = Duration.zero;
  ProcessingStateMessage proc = ProcessingStateMessage.idle;
  LoopModeMessage loop = LoopModeMessage.off;
  /// Zustand von libmpv (spielt wirklich?)
  bool playing = false;
  /// MediaKitPlayer._playing: gewünschter Zustand; wirkt erst, wenn die Datei offen ist
  bool requested = false;
  bool opened = false;
  int? errorCode;

  /// So lange braucht libmpv, um eine Datei zu öffnen (beim ersten Umwandeln am Server auch mal Sekunden).
  Duration openDelay = const Duration(milliseconds: 5);

  /// Wie MediaKitPlayer._loadCompleter: Startet ein neuer Ladevorgang, endet der alte nie mehr.
  Completer<void>? _current;

  void emit() => _events.add(PlaybackEventMessage(
        processingState: proc,
        updateTime: DateTime.now(),
        updatePosition: pos,
        bufferedPosition: pos,
        duration: const Duration(minutes: 3),
        icyMetadata: null,
        currentIndex: 0,
        androidAudioSessionId: null,
        errorCode: errorCode,
        errorMessage: errorCode == null ? null : 'Failed to open $uri.',
      ));

  /// Titelende erreicht (libmpv: eof-reached). Bei „Titel wiederholen“ spielt libmpv von vorn.
  void finish() {
    if (loop == LoopModeMessage.one) {
      pos = Duration.zero;
    } else {
      proc = ProcessingStateMessage.completed;
      pos = const Duration(minutes: 3);
    }
    emit();
  }

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;
  @override
  Stream<PlayerDataMessage> get playerDataMessageStream => _data.stream;

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    final source = request.audioSourceMessage;
    if (source is! UriAudioSourceMessage) throw StateError('Nur einzelne Titel: ${source.runtimeType}');
    uri = source.uri;
    loads.add(source.uri);
    errorCode = null;
    opened = false;
    final playOnOpen = requested; // _player.open(playable, play: _playing)
    pos = request.initialPosition ?? Duration.zero;
    proc = ProcessingStateMessage.loading;
    emit();
    final mine = _current = Completer<void>();
    await Future<void>.delayed(openDelay);
    if (!identical(mine, _current)) return Completer<LoadResponse>().future; // überholt: endet nie
    playing = playOnOpen;
    opened = true;
    if (failing.contains(source.uri)) {
      proc = ProcessingStateMessage.idle;
      errorCode = 1;
      emit();
      return Completer<LoadResponse>().future; // wie just_audio_media_kit: load() endet bei Fehlern nie
    }
    proc = ProcessingStateMessage.ready;
    emit();
    return LoadResponse(duration: const Duration(minutes: 3));
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    requested = true;
    if (opened) playing = true;
    return PlayResponse();
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    requested = false;
    if (opened) playing = false;
    return PauseResponse();
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    if (request.index != null) throw StateError('Kein Index an den inneren Player');
    pos = request.position ?? Duration.zero;
    if (proc == ProcessingStateMessage.completed) proc = ProcessingStateMessage.ready;
    emit();
    return SeekResponse();
  }

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async {
    loop = request.loopMode;
    _data.add(PlayerDataMessage(loopMode: loop)); // wie media_kit (playlistMode-Stream)
    return SetLoopModeResponse();
  }

  @override
  Future<SetShuffleModeResponse> setShuffleMode(SetShuffleModeRequest request) =>
      throw StateError('Zufall darf nicht an libmpv gehen');
  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async {
    _data.add(PlayerDataMessage(volume: request.volume));
    return SetVolumeResponse();
  }

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async => SetSpeedResponse();
  @override
  Future<DisposeResponse> dispose(DisposeRequest request) async => DisposeResponse();
}

class SingleTrackPlatform extends JustAudioPlatform {
  SingleTrackPlayer? last;
  final failing = <String>{};
  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async => last = SingleTrackPlayer(request.id, failing);
  @override
  Future<DisposePlayerResponse> disposePlayer(DisposePlayerRequest request) async => DisposePlayerResponse();
  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(DisposeAllPlayersRequest request) async =>
      DisposeAllPlayersResponse();
}

List<Track> tracks(int count, {int from = 1}) =>
    [for (var i = from; i < from + count; i++) Track.fromJson(trackJson(i))];

Future<void> settle([int ms = 40]) => Future<void>.delayed(Duration(milliseconds: ms));

/// Wartet (höchstens 3 s), bis [done] stimmt – robuster als eine feste Wartezeit, z. B. beim ersten, „kalten“ Test.
Future<void> until(bool Function() done) async {
  for (var i = 0; i < 300 && !done(); i++) {
    await settle(10);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SingleTrackPlatform inner;
  var quality = 'original';

  setUp(() {
    inner = SingleTrackPlatform();
    JustAudioPlatform.instance = QueueingAudioPlatform(inner);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('com.ryanheise.audio_session'), (call) async => null);
    quality = 'original';
  });

  SelfifyAudioHandler handler() {
    final h = SelfifyAudioHandler();
    h.autoplayEnabled = false;
    h.resolveSource = (track, item) => AudioSource.uri(Uri.parse('https://x/${track.id}?q=$quality'), tag: item);
    return h;
  }

  int? playingId() {
    final uri = inner.last!.uri;
    return uri == null ? null : int.parse(Uri.parse(uri).pathSegments.last);
  }

  Future<void> finishTrack() async {
    inner.last!.finish();
    await settle();
  }

  test('Titelende: nächster Titel spielt, Index und gespielter Titel stimmen überein', () async {
    final h = handler();
    unawaited(h.playTracks(tracks(4)));
    await until(() => h.player.processingState == ProcessingState.ready && h.player.playing);
    await settle();
    expect(h.currentTrack!.id, 1);
    expect(playingId(), 1);
    await finishTrack();
    expect(h.currentTrack!.id, 2);
    expect(playingId(), 2);
    expect(h.player.processingState, isNot(ProcessingState.completed));
    expect(inner.last!.playing, isTrue);
    await h.player.dispose();
  });

  test('Zufallswiedergabe: kein Fehler, Reihenfolge folgt playOrder, Zufall bleibt an', () async {
    for (var run = 0; run < 5; run++) {
      final h = handler();
      await expectLater(h.playTracks(tracks(12), shuffle: true), completes);
      await settle();
      expect(h.player.shuffleModeEnabled, isTrue);
      final order = h.playOrder;
      expect(order.first, h.player.currentIndex);
      for (var step = 1; step < 6; step++) {
        await finishTrack();
        expect(h.player.currentIndex, order[step], reason: 'Durchlauf $run, Schritt $step');
        expect(playingId(), h.tracks[order[step]].id);
        expect(h.player.shuffleModeEnabled, isTrue);
      }
      await h.player.dispose();
    }
  });

  test('Zufall per Knopf einschalten (setShuffleMode) wirft nicht und mischt libmpv nicht um', () async {
    final h = handler();
    unawaited(h.playTracks(tracks(8)));
    await settle();
    await h.setShuffleMode(AudioServiceShuffleMode.all);
    await settle();
    expect(h.player.shuffleModeEnabled, isTrue);
    final order = h.playOrder;
    final position = order.indexOf(h.player.currentIndex!);
    await finishTrack();
    expect(h.player.currentIndex, order[position + 1]);
    await h.player.dispose();
  });

  test('„Als Nächstes spielen“ in der Mitte kommt wirklich als Nächstes (mit und ohne Zufall)', () async {
    for (final shuffle in [false, true]) {
      final h = handler();
      unawaited(h.playTracks(tracks(10), shuffle: shuffle));
      await settle();
      await h.skipToNext();
      await settle();
      await h.skipToNext();
      await settle();
      final before = h.currentTrack!.id;
      await h.playNext([Track.fromJson(trackJson(99))]);
      await settle();
      expect(h.currentTrack!.id, before, reason: 'aktueller Titel bleibt (shuffle=$shuffle)');
      expect(playingId(), before);
      await finishTrack();
      expect(h.currentTrack!.id, 99, reason: 'shuffle=$shuffle');
      expect(playingId(), 99);
      await h.player.dispose();
    }
  });

  test('Qualitätswechsel: kommende Titel neu, laufender Titel wird nicht neu geladen', () async {
    final h = handler();
    h.streamQuality = 'original';
    unawaited(h.playTracks(tracks(6), shuffle: true));
    await settle();
    await h.skipToNext();
    await settle();
    final current = h.player.currentIndex!;
    final orderBefore = List.of(h.playOrder);
    final loadsBefore = inner.last!.loads.length;
    quality = 'low';
    h.streamQuality = 'low';
    await settle(200);
    expect(h.player.currentIndex, current);
    expect(h.playOrder, orderBefore);
    expect(inner.last!.loads.length, loadsBefore, reason: 'kein Neuladen des laufenden Titels');
    await finishTrack();
    expect(inner.last!.uri, endsWith('q=low'));
    expect(h.player.currentIndex, orderBefore[orderBefore.indexOf(current) + 1]);
    await h.player.dispose();
  });

  test('Wiederholen: „alle“ springt an den Anfang, „Titel“ bleibt, Anzeige wird nicht zurückgesetzt', () async {
    final h = handler();
    unawaited(h.playTracks(tracks(2)));
    await settle();
    await h.setRepeatMode(AudioServiceRepeatMode.all);
    await settle();
    expect(h.player.loopMode, LoopMode.all, reason: 'Meldung „aus“ des inneren Players darf nicht durchkommen');
    await finishTrack();
    await finishTrack();
    expect(h.player.currentIndex, 0);
    expect(playingId(), 1);
    await h.setRepeatMode(AudioServiceRepeatMode.one);
    await settle();
    expect(inner.last!.loop, LoopModeMessage.one);
    final loads = inner.last!.loads.length;
    await finishTrack();
    expect(h.player.currentIndex, 0);
    expect(inner.last!.loads.length, loads, reason: 'libmpv wiederholt selbst');
    await h.player.dispose();
  });

  test('Ende der Warteschlange: „fertig“ kommt an, danach zurück zum ersten Titel', () async {
    final h = handler();
    unawaited(h.playTracks(tracks(2)));
    await settle();
    await finishTrack();
    await finishTrack();
    await settle(100);
    expect(h.player.playing, isFalse);
    expect(h.player.currentIndex, 0);
    expect(playingId(), 1);
    await h.player.dispose();
  });

  test('Entfernen und Verschieben halten Index und gespielten Titel zusammen', () async {
    final h = handler();
    unawaited(h.playTracks(tracks(6), index: 3));
    await settle();
    expect(h.currentTrack!.id, 4);
    await h.removeQueueItemAt(0);
    await settle();
    expect(h.player.currentIndex, 2);
    expect(h.currentTrack!.id, 4);
    await h.moveQueueItem(5 - 1, 0); // Titel 6 an den Anfang
    await settle();
    expect(h.currentTrack!.id, 4);
    expect(playingId(), 4);
    await finishTrack();
    expect(h.currentTrack!.id, 5);
    expect(playingId(), 5);
    await h.player.dispose();
  });

  test('Weiter/Zurück springen über den Index', () async {
    final h = handler();
    unawaited(h.playTracks(tracks(3)));
    await settle();
    await h.skipToNext();
    await settle();
    expect(playingId(), 2);
    await h.skipToPrevious();
    await settle();
    expect(playingId(), 1);
    await h.player.dispose();
  });

  test('Titel lässt sich nicht laden: playTracks endet mit Fehler statt zu hängen', () async {
    inner.failing.add('https://x/1?q=original');
    final h = handler();
    await expectLater(h.playTracks(tracks(2)).timeout(const Duration(seconds: 2)), throwsA(isA<PlayerException>()));
    await h.player.dispose();
  });

  test('Schlaf-Timer „Ende des Titels“: libmpv spielt den nächsten Titel nicht heimlich weiter', () async {
    final h = handler();
    unawaited(h.playTracks(tracks(3)));
    await settle();
    h.sleepAtEndOfTrack();
    await finishTrack();
    await settle();
    expect(h.player.playing, isFalse);
    expect(inner.last!.playing, isFalse, reason: 'Pause während des Ladens muss nachträglich greifen');
    expect(h.currentTrack!.id, 2);
    await h.player.dispose();
  });

  test('Weiterschalten, während der erste Titel noch öffnet: nichts hängt, der neue Titel spielt', () async {
    final h = handler();
    unawaited(Future<void>.delayed(Duration.zero, () => inner.last!.openDelay = const Duration(milliseconds: 80)));
    final started = h.playTracks(tracks(4));
    await settle(20); // Titel 1 öffnet noch
    await h.skipToNext().timeout(const Duration(seconds: 2));
    await expectLater(started.timeout(const Duration(seconds: 2)), completes);
    await settle(200);
    expect(h.currentTrack!.id, 2);
    expect(playingId(), 2);
    expect(inner.last!.playing, isTrue);
    await h.player.dispose();
  });

  test('Weiter, Warteschlangen-Klick und Spulen, während der nächste Titel noch öffnet, gehen nicht verloren', () async {
    final h = handler();
    unawaited(h.playTracks(tracks(6)));
    await settle();
    inner.last!.openDelay = const Duration(milliseconds: 300);

    // Doppeltes „Weiter“: landet bei Titel 3
    unawaited(h.skipToNext());
    await settle(30);
    await h.skipToNext().timeout(const Duration(seconds: 2));
    await settle(700);
    expect(h.currentTrack!.id, 3);
    expect(playingId(), 3);

    // Klick in die Warteschlange, während der nächste Titel öffnet
    unawaited(h.skipToNext());
    await settle(30);
    await h.skipToQueueItem(5).timeout(const Duration(seconds: 2));
    await settle(700);
    expect(h.currentTrack!.id, 6);
    expect(playingId(), 6);

    // Spulen, während der Titel öffnet: wirkt, sobald er offen ist
    unawaited(h.skipToPrevious());
    await settle(30);
    await h.seek(const Duration(seconds: 30)).timeout(const Duration(seconds: 2));
    await settle(700);
    expect(playingId(), 5);
    expect(inner.last!.pos, const Duration(seconds: 30));
    await h.player.dispose();
  });

  test('Pause/Play während ein Titel lädt: libmpv folgt dem letzten Wunsch', () async {
    final h = handler();
    unawaited(h.playTracks(tracks(3)));
    await settle();
    unawaited(h.skipToNext());
    await h.pause();
    await settle();
    expect(inner.last!.playing, isFalse);
    unawaited(h.skipToNext());
    unawaited(h.play());
    await settle();
    expect(inner.last!.playing, isTrue);
    await h.player.dispose();
  });
}
