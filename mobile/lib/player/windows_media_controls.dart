// Windows: Medientasten (Tastatur, Headset – auch wenn Selfify nicht im Vordergrund ist) und die
// Medienübersicht von Windows (Titel, Cover, Abspielen/Pause/Weiter/Zurück) über
// SystemMediaTransportControls (smtc_windows). Android und iOS nutzen das nicht.

import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:smtc_windows/smtc_windows.dart';

import 'audio_handler.dart';

/// Ist die Windows-Medienübersicht aktiv? Dann kommen die Medientasten über Windows – die Tastenkürzel
/// in der App lassen sie weg, damit nichts doppelt umschaltet.
bool windowsMediaControlsActive = false;

/// Unter Windows Medientasten und Medienübersicht einrichten (nach AudioService.init). Sonst: nichts.
/// Klappt es nicht (z. B. ältere Windows-Version), bleibt es bei den Medientasten im Selfify-Fenster.
Future<void> setupWindowsMediaControls(SelfifyAudioHandler handler) async {
  if (!Platform.isWindows) return;
  try {
    await SMTCWindows.initialize().timeout(const Duration(seconds: 5));
    final smtc = SMTCWindows(
      config: const SMTCConfig(
        playEnabled: true,
        pauseEnabled: true,
        nextEnabled: true,
        prevEnabled: true,
        stopEnabled: false,
        fastForwardEnabled: false,
        rewindEnabled: false,
      ),
    );
    WindowsMediaControls(handler, SmtcBackend(smtc)).start();
    windowsMediaControlsActive = true;
  } catch (e) {
    debugPrint('Windows-Medienübersicht nicht verfügbar: $e');
  }
}

/// Was die Brücke von der Windows-Medienübersicht braucht (in Tests ersetzbar).
abstract class MediaControlsBackend {
  /// Gedrückte Knöpfe/Medientasten.
  Stream<PressedButton> get buttons;

  Future<void> showTrack({required String title, String? artist, String? album, String? cover});
  Future<void> clear();
  Future<void> setStatus(PlaybackStatus status);
  Future<void> setTimeline(Duration position, Duration duration);
}

/// Echte Medienübersicht über smtc_windows.
class SmtcBackend implements MediaControlsBackend {
  final SMTCWindows smtc;
  SmtcBackend(this.smtc);

  @override
  Stream<PressedButton> get buttons => smtc.buttonPressStream;

  @override
  Future<void> showTrack({required String title, String? artist, String? album, String? cover}) =>
      smtc.updateMetadata(MusicMetadata(title: title, artist: artist, album: album, albumArtist: artist, thumbnail: cover));

  @override
  Future<void> clear() => smtc.clearMetadata();

  @override
  Future<void> setStatus(PlaybackStatus status) => smtc.setPlaybackStatus(status);

  @override
  Future<void> setTimeline(Duration position, Duration duration) => smtc.updateTimeline(PlaybackTimeline(
        startTimeMs: 0,
        endTimeMs: duration.inMilliseconds,
        positionMs: position.inMilliseconds,
        minSeekTimeMs: 0,
        maxSeekTimeMs: duration.inMilliseconds,
      ));
}

/// Verbindet den Player mit der Windows-Medienübersicht – in beide Richtungen.
class WindowsMediaControls {
  final BaseAudioHandler handler;
  final MediaControlsBackend backend;
  final _subscriptions = <StreamSubscription<Object?>>[];

  WindowsMediaControls(this.handler, this.backend);

  String? _itemId;
  PlaybackStatus? _status;
  Duration? _sentPosition;
  DateTime? _sentAt;

  void start() {
    _subscriptions
      ..add(backend.buttons.listen(_onButton, onError: (Object _) {}))
      ..add(handler.mediaItem.listen(_onItem))
      ..add(handler.playbackState.listen(_onState));
  }

  Future<void> stop() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
  }

  void _onButton(PressedButton button) {
    final Future<void>? action = switch (button) {
      PressedButton.play => handler.play(),
      PressedButton.pause => handler.pause(),
      PressedButton.next => handler.skipToNext(),
      PressedButton.previous => handler.skipToPrevious(),
      PressedButton.stop => handler.pause(),
      _ => null,
    };
    // z. B. „Weiter“ am Ende der Warteschlange – kein Grund, die App zu stören
    action?.catchError((Object _) {});
  }

  void _onItem(MediaItem? item) {
    if (item == null) {
      _itemId = null;
      _ignore(backend.clear());
      return;
    }
    final art = item.artUri;
    // Windows lädt das Cover selbst – das geht nur mit http(s)-Adressen
    final cover = art != null && (art.scheme == 'http' || art.scheme == 'https') ? art.toString() : null;
    _ignore(backend.showTrack(title: item.title, artist: item.artist, album: item.album, cover: cover));
    if (_itemId != item.id) {
      _itemId = item.id;
      _sentPosition = null; // neuer Titel: Zeitleiste sofort neu
    }
    _sendTimeline(handler.playbackState.value, force: true);
  }

  void _onState(PlaybackState state) {
    final status = switch (state) {
      PlaybackState(playing: true) => PlaybackStatus.playing,
      PlaybackState(processingState: AudioProcessingState.idle) when handler.mediaItem.value == null =>
        PlaybackStatus.stopped,
      _ => PlaybackStatus.paused,
    };
    final changed = status != _status;
    if (changed) {
      _status = status;
      _ignore(backend.setStatus(status));
    }
    _sendTimeline(state, force: changed);
  }

  /// Zeitleiste nur bei Sprüngen (Spulen, Titelwechsel, Pause) senden – Windows rechnet sonst selbst weiter.
  void _sendTimeline(PlaybackState state, {bool force = false}) {
    final duration = handler.mediaItem.value?.duration;
    if (duration == null || duration <= Duration.zero) return;
    final position = state.position;
    final sent = _sentPosition;
    final at = _sentAt;
    if (!force && sent != null && at != null) {
      final expected = state.playing ? sent + DateTime.now().difference(at) : sent;
      if ((position - expected).abs() < const Duration(seconds: 2)) return;
    }
    _sentPosition = position;
    _sentAt = DateTime.now();
    _ignore(backend.setTimeline(position > duration ? duration : position, duration));
  }

  void _ignore(Future<void> future) => future.catchError((Object e) => debugPrint('Medienübersicht: $e'));
}
