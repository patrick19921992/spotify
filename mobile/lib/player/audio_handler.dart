import 'dart:async';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

import '../data/models.dart';
import 'queue_shuffle_order.dart';

/// Woher die Wiedergabe kommt (für Verlauf und "Zuletzt gehört").
class PlayContext {
  final String type; // album | playlist | artist | liked | mix | radio | search | category | queue
  final int? id;
  final String? title;
  const PlayContext(this.type, {this.id, this.title});
}

/// Liefert die Abspielquelle für einen Titel (Offline-Datei oder Stream-Link).
typedef SourceResolver = AudioSource Function(Track track, MediaItem item);

/// Cover-Link für Sperrbildschirm/Benachrichtigung.
typedef ArtResolver = Uri? Function(Track track);

/// Meldet gespielte Titel an den Server.
typedef HistoryReporter = void Function(Track track, double seconds, PlayContext? context);

/// Liefert passende Titel, wenn die Warteschlange zu Ende ist ("Autoplay").
typedef AutoplayProvider = Future<List<Track>> Function(Track lastTrack);

/// Hintergrund-Wiedergabe mit Sperrbildschirm-/Kopfhörer-/Auto-Steuerung (audio_service + just_audio).
class SelfifyAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final AudioPlayer player = AudioPlayer();

  SourceResolver? resolveSource;
  ArtResolver? resolveArt;
  HistoryReporter? reportHistory;
  AutoplayProvider? autoplay;
  bool autoplayEnabled = true;

  /// Ablauf des Medien-Tokens, der gerade in neue Stream-Links geschrieben wird.
  DateTime? Function()? sourceTokenExpiry;

  /// Holt einen frischen Medien-Token (vor dem Neuaufbau abgelaufener Stream-Links).
  Future<void> Function()? renewMediaToken;

  /// Frühester Ablauf der Links in der Warteschlange – danach antwortet der Server mit 401.
  DateTime? _sourcesExpireAt;

  /// Zufallsreihenfolge (neue Titel landen gezielt statt irgendwo).
  QueueShuffleOrder _order = QueueShuffleOrder();

  /// Während die Stream-Links neu aufgebaut werden, springt der Index kurz – das ist kein Titelwechsel.
  bool _rebuilding = false;

  String? _streamQuality;

  /// Gewählte Stream-Qualität. Ändert sie sich (z. B. WLAN → mobil), bekommen die kommenden Titel neue
  /// Links in der neuen Qualität; der laufende Titel spielt ohne Unterbrechung weiter.
  set streamQuality(String value) {
    final previous = _streamQuality;
    _streamQuality = value;
    if (previous != null && previous != value && _tracks.isNotEmpty) refreshUpcoming().ignore();
  }

  final List<Track> _tracks = [];
  PlayContext? _context;
  int? _lastIndex;
  Duration _lastPosition = Duration.zero;
  Timer? _sleepTimer;
  DateTime? _sleepAt;
  bool _sleepAfterTrack = false;
  bool _fetchingAutoplay = false;

  final _sleepController = StreamController<DateTime?>.broadcast();

  SelfifyAudioHandler() {
    player.playbackEventStream.listen(_broadcastState, onError: (Object e, StackTrace st) {
      playbackState.add(playbackState.value.copyWith(processingState: AudioProcessingState.error));
    });
    player.currentIndexStream.listen(_onIndexChanged);
    player.positionStream.listen((position) {
      if (player.currentIndex == _lastIndex) _lastPosition = position;
    });
    player.processingStateStream.listen((processing) async {
      if (processing == ProcessingState.completed) await _onQueueFinished();
    });
    player.shuffleModeEnabledStream.listen((_) => _broadcastState(player.playbackEvent));
    player.loopModeStream.listen((_) => _broadcastState(player.playbackEvent));
  }

  // ------------------------------------------------------------------ Zustand

  List<Track> get tracks => List.unmodifiable(_tracks);
  PlayContext? get playContext => _context;
  Track? get currentTrack {
    final index = player.currentIndex;
    return index != null && index < _tracks.length ? _tracks[index] : null;
  }

  /// Reihenfolge, in der die Titel gespielt werden (berücksichtigt Zufallswiedergabe).
  List<int> get playOrder => player.shuffleModeEnabled ? player.shuffleIndices : List.generate(_tracks.length, (i) => i);

  /// Schlaf-Timer: Zeitpunkt, an dem pausiert wird (oder null).
  Stream<DateTime?> get sleepTimerStream => _sleepController.stream;
  DateTime? get sleepAt => _sleepAt;
  bool get sleepAfterTrack => _sleepAfterTrack;

  MediaItem mediaItemFor(Track track) => MediaItem(
        id: '${track.id}',
        title: track.title,
        artist: track.artistDisplay,
        album: track.album?.title,
        duration: track.length,
        artUri: resolveArt?.call(track),
        genre: track.genre,
        extras: {'trackId': track.id},
      );

  AudioSource _sourceFor(Track track) {
    final item = mediaItemFor(track);
    final resolver = resolveSource;
    if (resolver == null) throw StateError('Wiedergabe ist noch nicht eingerichtet.');
    final expiry = sourceTokenExpiry?.call();
    if (expiry != null && (_sourcesExpireAt == null || expiry.isBefore(_sourcesExpireAt!))) {
      _sourcesExpireAt = expiry;
    }
    return resolver(track, item);
  }

  /// Läuft der Token in den Links bald ab (z. B. eine Woche pausiert), vor dem Weiterspielen erneuern.
  Future<void> _renewExpiringSources() async {
    final expires = _sourcesExpireAt;
    if (expires == null || _tracks.isEmpty) return;
    if (DateTime.now().isBefore(expires.subtract(const Duration(days: 1)))) return;
    try {
      await renewMediaToken?.call();
      await refreshSources();
    } catch (_) {
      // Ohne Netz bleibt es beim Alten – lokal gespeicherte Titel spielen trotzdem
    }
  }

  void _broadcastState(PlaybackEvent event) {
    final playing = player.playing;
    playbackState.add(playbackState.value.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {MediaAction.seek, MediaAction.seekForward, MediaAction.seekBackward},
      androidCompactActionIndices: const [0, 1, 2],
      processingState: const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[player.processingState]!,
      playing: playing,
      updatePosition: player.position,
      bufferedPosition: player.bufferedPosition,
      speed: player.speed,
      queueIndex: event.currentIndex,
      shuffleMode: player.shuffleModeEnabled ? AudioServiceShuffleMode.all : AudioServiceShuffleMode.none,
      repeatMode: switch (player.loopMode) {
        LoopMode.off => AudioServiceRepeatMode.none,
        LoopMode.one => AudioServiceRepeatMode.one,
        LoopMode.all => AudioServiceRepeatMode.all,
      },
    ));
  }

  void _onIndexChanged(int? index) {
    if (_rebuilding) return;
    final previous = _lastIndex;
    if (previous != null && previous != index && previous < _tracks.length) {
      _report(_tracks[previous], _lastPosition);
      if (_sleepAfterTrack) {
        _sleepAfterTrack = false;
        _sleepController.add(null);
        player.pause();
      }
    }
    _lastIndex = index;
    _lastPosition = Duration.zero;
    if (index != null && index < _tracks.length) mediaItem.add(mediaItemFor(_tracks[index]));
  }

  void _report(Track track, Duration listened) {
    if (listened.inMilliseconds < 1000) return;
    try {
      reportHistory?.call(track, listened.inMilliseconds / 1000, _context);
    } catch (_) {}
  }

  void _publishQueue() => queue.add(_tracks.map(mediaItemFor).toList());

  Future<void> _onQueueFinished() async {
    final last = currentTrack;
    if (last != null) _report(last, _lastPosition);
    _lastPosition = Duration.zero;
    if (_sleepAfterTrack) {
      _sleepAfterTrack = false;
      _sleepController.add(null);
      // Wie am normalen Ende: anhalten und zurück an den Anfang, sonst reagiert der Play-Knopf nicht mehr
      await player.pause();
      await player.seek(Duration.zero, index: 0);
      return;
    }
    final provider = autoplay;
    if (last != null && autoplayEnabled && provider != null && !_fetchingAutoplay && player.loopMode == LoopMode.off) {
      _fetchingAutoplay = true;
      try {
        final more = (await provider(last)).where((t) => !t.isVideo && t.id != last.id).toList();
        if (more.isNotEmpty) {
          final start = _tracks.length;
          await addTracks(more);
          _context = const PlayContext('radio');
          await player.seek(Duration.zero, index: start);
          // play() endet erst beim nächsten Pausieren – nicht darauf warten, sonst bliebe Autoplay gesperrt
          _fetchingAutoplay = false;
          player.play().ignore();
          return;
        }
      } catch (_) {
      } finally {
        _fetchingAutoplay = false;
      }
    }
    await player.pause();
    await player.seek(Duration.zero, index: 0);
  }

  // ------------------------------------------------------------- Steuerung

  /// Neue Wiedergabeliste abspielen (ersetzt die Warteschlange).
  /// Videos laufen als Ton mit (wie Musikvideos bei Spotify) – resolveSource fragt dafür nur die Tonspur an.
  Future<void> playTracks(List<Track> tracks, {int index = 0, PlayContext? context, bool shuffle = false}) async {
    final audio = tracks.toList();
    if (audio.isEmpty) return;
    // Nach Position, nicht nach Gleichheit: derselbe Titel kann mehrfach vorkommen
    final start = index >= 0 && index < tracks.length ? index : 0;
    final current = currentTrack;
    if (current != null) _report(current, _lastPosition);
    _lastIndex = null;
    _tracks
      ..clear()
      ..addAll(audio);
    _context = context;
    _publishQueue();
    // Zufallswiedergabe ohne gewählten Titel: mit einem zufälligen Titel beginnen (shuffle() setzt den
    // aktuellen Titel immer an den Anfang der Reihenfolge)
    final initial = shuffle && index == 0 ? Random().nextInt(audio.length) : (start < 0 ? 0 : start);
    await player.setShuffleModeEnabled(false);
    _sourcesExpireAt = null;
    _order = QueueShuffleOrder();
    await player.setAudioSources(
      audio.map(_sourceFor).toList(),
      initialIndex: initial,
      initialPosition: Duration.zero,
      shuffleOrder: _order,
    );
    if (shuffle) {
      await player.shuffle();
      await player.setShuffleModeEnabled(true);
    }
    await player.play();
  }

  /// Am Ende der Warteschlange anhängen (Videos als Ton).
  Future<void> addTracks(List<Track> tracks) async {
    final audio = tracks.toList();
    if (audio.isEmpty) return;
    if (_tracks.isEmpty) return playTracks(audio, context: const PlayContext('queue'));
    _tracks.addAll(audio);
    _publishQueue();
    await player.addAudioSources(audio.map(_sourceFor).toList());
  }

  /// Direkt nach dem aktuellen Titel einreihen ("Als Nächstes spielen", Videos als Ton).
  Future<void> playNext(List<Track> tracks) async {
    final audio = tracks.toList();
    if (audio.isEmpty) return;
    if (_tracks.isEmpty) return playTracks(audio, context: const PlayContext('queue'));
    final current = player.currentIndex;
    final at = (current ?? -1) + 1;
    _tracks.insertAll(at, audio);
    _publishQueue();
    _order.insertAfter = current; // bei Zufallswiedergabe direkt hinter den aktuellen Titel
    await player.insertAudioSources(at, audio.map(_sourceFor).toList());
  }

  @override
  Future<void> addQueueItem(MediaItem mediaItem) async {}

  @override
  Future<void> removeQueueItemAt(int index) async {
    if (index < 0 || index >= _tracks.length || index == player.currentIndex) return;
    _tracks.removeAt(index);
    if (_lastIndex != null && index < _lastIndex!) _lastIndex = _lastIndex! - 1;
    _publishQueue();
    await player.removeAudioSourceAt(index);
  }

  /// Titel in der Warteschlange verschieben (Indizes der Original-Reihenfolge).
  Future<void> moveQueueItem(int from, int to) async {
    if (from == to || from < 0 || to < 0 || from >= _tracks.length || to >= _tracks.length) return;
    final track = _tracks.removeAt(from);
    _tracks.insert(to, track);
    _publishQueue();
    await player.moveAudioSource(from, to);
    _lastIndex = player.currentIndex;
  }

  /// Alles entfernen, was nach dem aktuellen Titel noch kommt – bei Zufallswiedergabe in
  /// Abspiel-Reihenfolge (dann stehen kommende Titel auch vor dem aktuellen in der Liste).
  Future<void> clearUpcoming() async {
    final current = player.currentIndex;
    if (current == null || current >= _tracks.length) return;
    if (!player.shuffleModeEnabled) {
      if (current >= _tracks.length - 1) return;
      _tracks.removeRange(current + 1, _tracks.length);
      _publishQueue();
      await player.removeAudioSourceRange(current + 1, player.audioSources.length);
      return;
    }
    final order = playOrder.where((i) => i >= 0 && i < _tracks.length).toList();
    final position = order.indexOf(current);
    if (position < 0) return;
    // Von hinten nach vorn entfernen, damit die übrigen Positionen gültig bleiben
    final upcoming = order.sublist(position + 1)..sort((a, b) => b.compareTo(a));
    for (final index in upcoming) {
      await removeQueueItemAt(index);
    }
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (index < 0 || index >= _tracks.length) return;
    await player.seek(Duration.zero, index: index);
    if (!player.playing) await player.play();
  }

  @override
  Future<void> play() async {
    await _renewExpiringSources();
    await player.play();
  }

  @override
  Future<void> pause() => player.pause();

  @override
  Future<void> seek(Duration position) => player.seek(position);

  @override
  Future<void> skipToNext() async {
    if (player.hasNext) {
      await player.seekToNext();
    } else if (_tracks.isNotEmpty) {
      await _onQueueFinished();
    }
  }

  @override
  Future<void> skipToPrevious() async {
    // Wie bei Spotify: nach 3 Sekunden zuerst an den Anfang des Titels
    if (player.position > const Duration(seconds: 3) || !player.hasPrevious) {
      await player.seek(Duration.zero);
    } else {
      await player.seekToPrevious();
    }
  }

  @override
  Future<void> fastForward() => player.seek(player.position + const Duration(seconds: 15));

  @override
  Future<void> rewind() {
    final target = player.position - const Duration(seconds: 15);
    return player.seek(target < Duration.zero ? Duration.zero : target);
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    final enable = shuffleMode != AudioServiceShuffleMode.none;
    if (enable) await player.shuffle();
    await player.setShuffleModeEnabled(enable);
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) => player.setLoopMode(switch (repeatMode) {
        AudioServiceRepeatMode.none => LoopMode.off,
        AudioServiceRepeatMode.one => LoopMode.one,
        _ => LoopMode.all,
      });

  @override
  Future<void> setSpeed(double speed) => player.setSpeed(speed);

  /// Schlaf-Timer: nach [duration] pausieren; null = ausschalten.
  void setSleepTimer(Duration? duration) {
    _sleepTimer?.cancel();
    _sleepAfterTrack = false;
    if (duration == null) {
      _sleepAt = null;
      _sleepController.add(null);
      return;
    }
    _sleepAt = DateTime.now().add(duration);
    _sleepController.add(_sleepAt);
    _sleepTimer = Timer(duration, () {
      _sleepAt = null;
      _sleepController.add(null);
      player.pause();
    });
  }

  /// Schlaf-Timer: am Ende des aktuellen Titels pausieren.
  void sleepAtEndOfTrack() {
    _sleepTimer?.cancel();
    _sleepAt = null;
    _sleepAfterTrack = true;
    _sleepController.add(DateTime.fromMillisecondsSinceEpoch(0));
  }

  /// Quellen neu erzeugen (z. B. nach Wechsel WLAN/mobil oder neu heruntergeladenen Titeln) –
  /// die Wiedergabe läuft an derselben Stelle weiter.
  Future<void> refreshSources() async {
    if (_tracks.isEmpty) return;
    final index = player.currentIndex ?? 0;
    final position = player.position;
    final playing = player.playing;
    final shuffle = player.shuffleModeEnabled;
    _sourcesExpireAt = null;
    _order.restore = List.of(_order.indices); // Zufallsreihenfolge beibehalten
    await player.setAudioSources(
      _tracks.map(_sourceFor).toList(),
      initialIndex: index,
      initialPosition: position,
      shuffleOrder: _order,
    );
    await player.setShuffleModeEnabled(shuffle);
    if (playing) await player.play();
  }

  /// Stream-Links aller Titel außer dem laufenden neu erzeugen (z. B. neue Qualität nach Wechsel WLAN/mobil).
  /// Der laufende Titel spielt ohne Unterbrechung weiter, die Zufallsreihenfolge bleibt erhalten.
  Future<void> refreshUpcoming() async {
    final current = player.currentIndex;
    final count = _tracks.length;
    if (_rebuilding || current == null || current >= count || count <= 1) return;
    _rebuilding = true;
    try {
      final saved = List.of(_order.indices);
      _sourcesExpireAt = null;
      if (current + 1 < count) {
        await player.removeAudioSourceRange(current + 1, count);
        if (current == 0) _order.restore = saved;
        await player.insertAudioSources(current + 1, _tracks.sublist(current + 1).map(_sourceFor).toList());
      }
      if (current > 0) {
        await player.removeAudioSourceRange(0, current);
        _order.restore = saved;
        await player.insertAudioSources(0, _tracks.sublist(0, current).map(_sourceFor).toList());
      }
    } finally {
      _rebuilding = false;
      _lastIndex = player.currentIndex;
    }
  }

  @override
  Future<void> stop() async {
    final current = currentTrack;
    if (current != null) _report(current, _lastPosition);
    _lastIndex = null;
    await player.stop();
    await super.stop();
  }

  /// Wiedergabe beenden und Warteschlange leeren (z. B. beim Abmelden).
  Future<void> reset() async {
    await stop();
    _tracks.clear();
    _sourcesExpireAt = null;
    _context = null;
    _publishQueue();
    mediaItem.add(null);
    await player.clearAudioSources();
  }
}
