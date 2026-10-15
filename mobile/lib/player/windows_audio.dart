// Wiedergabe unter Windows: just_audio über libmpv (just_audio_media_kit) – mit eigener Warteschlange.
//
// just_audio_media_kit 2.1.0 beherrscht die Warteschlange nicht vollständig: setShuffleOrder fehlt (shuffle()
// wirft), die Zufallswiedergabe mischt die mpv-Liste selbst um, und Einfügen in der Mitte landet am Ende.
// Deshalb verwaltet [QueueingAudioPlayer] Liste, Zufallsreihenfolge und Wiederholen selbst und gibt dem
// eigentlichen Player immer nur den aktuellen Titel. Android und iOS nutzen das nicht.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

/// Warum die Windows-Wiedergabe nicht eingerichtet werden konnte (z. B. libmpv-2.dll fehlt) – sonst null.
Object? windowsAudioError;

/// Unter Windows just_audio auf libmpv umstellen (vor dem ersten AudioPlayer aufrufen). Sonst: nichts.
void setupWindowsAudio() {
  if (!Platform.isWindows) return;
  try {
    JustAudioMediaKit.title = 'Selfify'; // Name im Lautstärkemixer von Windows
    JustAudioMediaKit.ensureInitialized(linux: false, windows: true);
    JustAudioPlatform.instance = QueueingAudioPlatform(JustAudioPlatform.instance);
  } catch (e) {
    // Die App soll trotzdem starten (Bibliothek, Playlists, Downloads gehen) – nur Abspielen klappt dann nicht
    windowsAudioError = e;
    debugPrint('Windows-Wiedergabe nicht verfügbar: $e');
  }
}

/// Hüllt eine just_audio-Plattform ein, die nur einzelne Titel zuverlässig abspielt.
class QueueingAudioPlatform extends JustAudioPlatform {
  final JustAudioPlatform inner;
  final _players = <String, QueueingAudioPlayer>{};

  QueueingAudioPlatform(this.inner);

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    final player = QueueingAudioPlayer(await inner.init(request));
    _players[request.id] = player;
    return player;
  }

  @override
  Future<DisposePlayerResponse> disposePlayer(DisposePlayerRequest request) async {
    await _players.remove(request.id)?._close();
    return inner.disposePlayer(request);
  }

  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(DisposeAllPlayersRequest request) async {
    final players = List.of(_players.values);
    _players.clear();
    for (final player in players) {
      await player._close();
    }
    return inner.disposeAllPlayers(request);
  }
}

/// Warteschlange (Reihenfolge, Zufall, Wiederholen) in Dart; [inner] spielt immer nur einen Titel.
class QueueingAudioPlayer extends AudioPlayerPlatform {
  final AudioPlayerPlatform inner;

  QueueingAudioPlayer(this.inner) : super(inner.id) {
    _subscriptions = [
      inner.playbackEventMessageStream.listen(_onInnerEvent, onError: _events.addError),
      // Wiederholen/Zufall kennt nur diese Hülle – die Meldungen des inneren Players würden sie überschreiben
      inner.playerDataMessageStream.listen((m) {
        if (m.playing == null && m.volume == null && m.speed == null && m.pitch == null) return;
        _data.add(PlayerDataMessage(playing: m.playing, volume: m.volume, speed: m.speed, pitch: m.pitch));
      }, onError: _data.addError),
    ];
  }

  final _events = StreamController<PlaybackEventMessage>.broadcast();
  final _data = StreamController<PlayerDataMessage>.broadcast();
  late final List<StreamSubscription<Object?>> _subscriptions;

  List<AudioSourceMessage> _children = [];
  List<int> _shuffleOrder = [];
  bool _shuffle = false;
  LoopModeMessage _loop = LoopModeMessage.off;
  int? _index;

  /// Soll gespielt werden? (letzter play/pause-Wunsch von just_audio)
  bool _wantPlaying = false;

  /// Zählt Ladevorgänge – Meldungen eines überholten Titels werden ignoriert.
  int _generation = 0;
  bool _loading = false;

  /// Wird erfüllt, sobald ein neuerer Ladevorgang beginnt: just_audio_media_kit beendet den älteren dann nie.
  Completer<void>? _superseded;
  PlaybackEventMessage? _last;

  List<AudioSourceMessage> get children => List.unmodifiable(_children);
  int? get currentIndex => _index;

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  @override
  Stream<PlayerDataMessage> get playerDataMessageStream => _data.stream;

  // ---------------------------------------------------------------- Meldungen

  void _onInnerEvent(PlaybackEventMessage event) {
    _last = event;
    if (event.processingState == ProcessingStateMessage.completed) {
      // Während ein neuer Titel lädt, gehört „fertig“ zum alten Titel
      if (_loading) return;
      final next = _nextIndex();
      if (next != null) {
        _advanceTo(next);
        return;
      }
    }
    _emit(event);
  }

  void _emit(PlaybackEventMessage event) {
    if (_events.isClosed) return;
    _events.add(PlaybackEventMessage(
      processingState: event.processingState,
      updateTime: event.updateTime,
      updatePosition: event.updatePosition,
      bufferedPosition: event.bufferedPosition,
      duration: event.duration,
      icyMetadata: event.icyMetadata,
      currentIndex: _index,
      androidAudioSessionId: event.androidAudioSessionId,
      errorCode: event.errorCode,
      errorMessage: event.errorMessage,
    ));
  }

  /// Letzten Zustand mit neuem Index melden (nach Einfügen/Entfernen/Verschieben).
  void _emitIndex() {
    final last = _last;
    _emit(last ??
        PlaybackEventMessage(
          processingState: ProcessingStateMessage.idle,
          updateTime: DateTime.now(),
          updatePosition: Duration.zero,
          bufferedPosition: Duration.zero,
          duration: null,
          icyMetadata: null,
          currentIndex: _index,
          androidAudioSessionId: null,
        ));
  }

  /// Nächster Titel wie bei just_audio (Zufallsreihenfolge, Wiederholen) – null am Ende.
  int? _nextIndex() {
    final index = _index;
    if (index == null || _children.isEmpty) return null;
    if (_loop == LoopModeMessage.one) return index;
    final order = _shuffle && _shuffleOrder.length == _children.length
        ? _shuffleOrder
        : List.generate(_children.length, (i) => i);
    final position = order.indexOf(index);
    if (position < 0) return null;
    if (position + 1 < order.length) return order[position + 1];
    return _loop == LoopModeMessage.all ? order.first : null;
  }

  void _advanceTo(int index) {
    _index = index;
    _loadCurrent(Duration.zero).then((_) {}, onError: (Object _) {
      // Fehler kommt zusätzlich als Meldung mit errorCode – wie bei einem Titelwechsel unter Android
    });
  }

  /// Den aktuellen Titel in den inneren Player laden. Spielt weiter, wenn vorher gespielt wurde.
  Future<Duration?> _loadCurrent(Duration? position) async {
    final index = _index;
    if (index == null || index >= _children.length) return null;
    final generation = ++_generation;
    _loading = true;
    _supersede();
    final superseded = _superseded = Completer<void>();
    final failed = Completer<Duration?>();
    // libmpv meldet einen Ladefehler nur als Ereignis – ohne das würde load() nie fertig
    final errors = inner.playbackEventMessageStream.listen((event) {
      if (event.errorCode != null && !failed.isCompleted) {
        failed.completeError(PlatformException(code: '${event.errorCode}', message: event.errorMessage));
      }
    });
    try {
      final load = inner
          .load(LoadRequest(audioSourceMessage: _children[index], initialPosition: position))
          .then((response) => response.duration);
      // Überholt (z. B. „Weiter“, während die Datei noch öffnet): nicht auf den alten Titel warten
      final duration = await Future.any([load, failed.future, superseded.future.then((_) => null)]);
      // just_audio_media_kit übergeht play/pause, solange die Datei noch geöffnet wird – nachholen
      if (generation == _generation) {
        await (_wantPlaying ? inner.play(PlayRequest()) : inner.pause(PauseRequest()));
      }
      return duration;
    } finally {
      await errors.cancel();
      if (generation == _generation) _loading = false;
    }
  }

  void _supersede() {
    final previous = _superseded;
    if (previous != null && !previous.isCompleted) previous.complete();
  }

  // ---------------------------------------------------------------- Laden und Springen

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    final source = request.audioSourceMessage;
    if (source is ConcatenatingAudioSourceMessage) {
      if (source.children.any((c) => c is ConcatenatingAudioSourceMessage)) {
        throw UnsupportedError('Verschachtelte Wiedergabelisten werden unter Windows nicht unterstützt.');
      }
      _children = List.of(source.children);
      _shuffleOrder = List.of(source.shuffleOrder);
    } else {
      _children = [source];
      _shuffleOrder = [0];
    }
    _index = _children.isEmpty ? null : (request.initialIndex ?? 0).clamp(0, _children.length - 1);
    if (_index == null) {
      _last = null;
      _emitIndex();
      return LoadResponse(duration: null);
    }
    return LoadResponse(duration: await _loadCurrent(request.initialPosition));
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    final index = request.index;
    final finished = _last?.processingState == ProcessingStateMessage.completed;
    if (index != null && index < _children.length && (index != _index || finished)) {
      _index = index;
      await _loadCurrent(request.position);
      return SeekResponse();
    }
    return inner.seek(SeekRequest(position: request.position));
  }

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async {
    _loop = request.loopMode;
    // Einen Titel wiederholen kann libmpv selbst (ohne Pause); alles andere steuert die Warteschlange
    await inner.setLoopMode(SetLoopModeRequest(
      loopMode: _loop == LoopModeMessage.one ? LoopModeMessage.one : LoopModeMessage.off,
    ));
    return SetLoopModeResponse();
  }

  @override
  Future<SetShuffleModeResponse> setShuffleMode(SetShuffleModeRequest request) async {
    _shuffle = request.shuffleMode != ShuffleModeMessage.none;
    return SetShuffleModeResponse();
  }

  @override
  Future<SetShuffleOrderResponse> setShuffleOrder(SetShuffleOrderRequest request) async {
    final source = request.audioSourceMessage;
    if (source is ConcatenatingAudioSourceMessage) _shuffleOrder = List.of(source.shuffleOrder);
    return SetShuffleOrderResponse();
  }

  // ---------------------------------------------------------------- Warteschlange ändern

  @override
  Future<ConcatenatingInsertAllResponse> concatenatingInsertAll(ConcatenatingInsertAllRequest request) async {
    final at = request.index.clamp(0, _children.length);
    _children.insertAll(at, request.children);
    _shuffleOrder = List.of(request.shuffleOrder);
    final index = _index;
    if (index != null && at <= index) _index = index + request.children.length;
    _emitIndex();
    return ConcatenatingInsertAllResponse();
  }

  @override
  Future<ConcatenatingRemoveRangeResponse> concatenatingRemoveRange(ConcatenatingRemoveRangeRequest request) async {
    final start = request.startIndex.clamp(0, _children.length);
    final end = request.endIndex.clamp(start, _children.length);
    _children.removeRange(start, end);
    _shuffleOrder = List.of(request.shuffleOrder);
    final index = _index;
    if (index == null || index < start) {
      _emitIndex();
    } else if (index >= end) {
      _index = index - (end - start);
      _emitIndex();
    } else if (_children.isEmpty) {
      // Der laufende Titel ist weg und nichts mehr da: anhalten
      _index = null;
      await inner.pause(PauseRequest());
      _last = null;
      _emitIndex();
    } else {
      // Der laufende Titel ist weg: mit dem Titel an seiner Stelle weiter (wie ExoPlayer)
      _index = start < _children.length ? start : _children.length - 1;
      await _loadCurrent(Duration.zero);
    }
    return ConcatenatingRemoveRangeResponse();
  }

  @override
  Future<ConcatenatingMoveResponse> concatenatingMove(ConcatenatingMoveRequest request) async {
    final from = request.currentIndex;
    final to = request.newIndex;
    if (from >= 0 && from < _children.length && to >= 0 && to < _children.length) {
      _children.insert(to, _children.removeAt(from));
      final index = _index;
      if (index != null) {
        if (index == from) {
          _index = to;
        } else if (from < index && to >= index) {
          _index = index - 1;
        } else if (from > index && to <= index) {
          _index = index + 1;
        }
      }
    }
    _shuffleOrder = List.of(request.shuffleOrder);
    _emitIndex();
    return ConcatenatingMoveResponse();
  }

  // ---------------------------------------------------------------- Unverändert weiterreichen

  @override
  Future<PlayResponse> play(PlayRequest request) {
    _wantPlaying = true;
    return inner.play(request);
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) {
    _wantPlaying = false;
    return inner.pause(request);
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) => inner.setVolume(request);

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) => inner.setSpeed(request);

  @override
  Future<SetPitchResponse> setPitch(SetPitchRequest request) => inner.setPitch(request);

  @override
  Future<SetSkipSilenceResponse> setSkipSilence(SetSkipSilenceRequest request) => inner.setSkipSilence(request);

  @override
  Future<SetAutomaticallyWaitsToMinimizeStallingResponse> setAutomaticallyWaitsToMinimizeStalling(
          SetAutomaticallyWaitsToMinimizeStallingRequest request) =>
      inner.setAutomaticallyWaitsToMinimizeStalling(request);

  @override
  Future<SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse>
      setCanUseNetworkResourcesForLiveStreamingWhilePaused(
              SetCanUseNetworkResourcesForLiveStreamingWhilePausedRequest request) =>
          inner.setCanUseNetworkResourcesForLiveStreamingWhilePaused(request);

  @override
  Future<SetPreferredPeakBitRateResponse> setPreferredPeakBitRate(SetPreferredPeakBitRateRequest request) =>
      inner.setPreferredPeakBitRate(request);

  @override
  Future<SetAllowsExternalPlaybackResponse> setAllowsExternalPlayback(SetAllowsExternalPlaybackRequest request) =>
      inner.setAllowsExternalPlayback(request);

  @override
  Future<SetAndroidAudioAttributesResponse> setAndroidAudioAttributes(SetAndroidAudioAttributesRequest request) =>
      inner.setAndroidAudioAttributes(request);

  @override
  Future<DisposeResponse> dispose(DisposeRequest request) async {
    await _close();
    return inner.dispose(request);
  }

  Future<void> _close() async {
    _supersede(); // offene Ladevorgänge beenden
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _events.close();
    await _data.close();
  }
}
