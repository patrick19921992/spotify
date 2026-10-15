// Nachgebauter just_audio-Player für Tests: verhält sich wie die echte Plattform (Warteschlange,
// Zufallsreihenfolge, Index-Verschiebungen), spielt aber nichts ab.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

class FakePlayer extends AudioPlayerPlatform {
  FakePlayer(super.id);
  final _events = StreamController<PlaybackEventMessage>.broadcast();
  final _data = StreamController<PlayerDataMessage>.broadcast();
  List<String> children = [];
  List<int> order = [];
  int? current;
  Duration pos = Duration.zero;
  ProcessingStateMessage proc = ProcessingStateMessage.idle;
  bool shuffle = false;
  LoopModeMessage loop = LoopModeMessage.off;
  Completer<PlayResponse>? playing;

  void emit() => _events.add(PlaybackEventMessage(
        processingState: proc,
        updateTime: DateTime.now(),
        updatePosition: pos,
        bufferedPosition: pos,
        duration: const Duration(minutes: 3),
        icyMetadata: null,
        currentIndex: current,
        androidAudioSessionId: null,
      ));

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;
  @override
  Stream<PlayerDataMessage> get playerDataMessageStream => _data.stream;

  void _readSource(AudioSourceMessage m) {
    final c = m as ConcatenatingAudioSourceMessage;
    children = [for (final ch in c.children) (ch as UriAudioSourceMessage).uri];
    order = List.of(c.shuffleOrder);
  }

  Duration loadDelay = Duration.zero;
  @override
  Future<LoadResponse> load(LoadRequest request) async {
    await Future<void>.delayed(loadDelay);
    _readSource(request.audioSourceMessage);
    current = request.initialIndex ?? 0;
    pos = request.initialPosition ?? Duration.zero;
    proc = ProcessingStateMessage.ready;
    emit();
    return LoadResponse(duration: const Duration(minutes: 3));
  }

  @override
  Future<PlayResponse> play(PlayRequest request) {
    playing ??= Completer<PlayResponse>();
    return playing!.future;
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    playing?.complete(PlayResponse());
    playing = null;
    emit();
    return PauseResponse();
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    if (request.index != null) current = request.index;
    pos = request.position ?? Duration.zero;
    proc = ProcessingStateMessage.ready;
    emit();
    return SeekResponse();
  }

  @override
  Future<SetShuffleModeResponse> setShuffleMode(SetShuffleModeRequest request) async {
    shuffle = request.shuffleMode == ShuffleModeMessage.all;
    return SetShuffleModeResponse();
  }

  @override
  Future<SetShuffleOrderResponse> setShuffleOrder(SetShuffleOrderRequest request) async {
    order = List.of((request.audioSourceMessage as ConcatenatingAudioSourceMessage).shuffleOrder);
    return SetShuffleOrderResponse();
  }

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async {
    loop = request.loopMode;
    return SetLoopModeResponse();
  }

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async => SetSpeedResponse();
  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async => SetVolumeResponse();

  @override
  Future<ConcatenatingInsertAllResponse> concatenatingInsertAll(ConcatenatingInsertAllRequest r) async {
    children.insertAll(r.index, [for (final c in r.children) (c as UriAudioSourceMessage).uri]);
    order = List.of(r.shuffleOrder);
    if (current != null && r.index <= current!) current = current! + r.children.length;
    emit();
    return ConcatenatingInsertAllResponse();
  }

  @override
  Future<ConcatenatingRemoveRangeResponse> concatenatingRemoveRange(ConcatenatingRemoveRangeRequest r) async {
    final count = r.endIndex - r.startIndex;
    children.removeRange(r.startIndex, r.endIndex);
    order = List.of(r.shuffleOrder);
    if (current != null) {
      if (current! >= r.endIndex) {
        current = current! - count;
      } else if (current! >= r.startIndex) {
        current = r.startIndex < children.length ? r.startIndex : null;
      }
    }
    emit();
    return ConcatenatingRemoveRangeResponse();
  }

  @override
  Future<ConcatenatingMoveResponse> concatenatingMove(ConcatenatingMoveRequest r) async {
    final item = children.removeAt(r.currentIndex);
    children.insert(r.newIndex, item);
    order = List.of(r.shuffleOrder);
    emit();
    return ConcatenatingMoveResponse();
  }

  @override
  Future<DisposeResponse> dispose(DisposeRequest request) async => DisposeResponse();
}

class FakeJustAudio extends JustAudioPlatform {
  FakePlayer? last;
  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async => last = FakePlayer(request.id);
  @override
  Future<DisposePlayerResponse> disposePlayer(DisposePlayerRequest request) async => DisposePlayerResponse();
  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(DisposeAllPlayersRequest request) async =>
      DisposeAllPlayersResponse();
}

/// Nachgebauten Player aktivieren (in setUp aufrufen).
FakeJustAudio useFakeAudioPlatform() {
  final platform = FakeJustAudio();
  JustAudioPlatform.instance = platform;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('com.ryanheise.audio_session'), (call) async => null);
  return platform;
}
