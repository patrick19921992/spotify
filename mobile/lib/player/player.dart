import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../data/models.dart';
import '../state/auth.dart';
import '../state/connectivity.dart';
import '../state/offline.dart';
import '../state/settings.dart';
import 'audio_handler.dart';
import 'windows_audio.dart' show windowsAudioError;

export 'audio_handler.dart' show PlayContext, SelfifyAudioHandler;

/// Wird in main.dart mit dem gestarteten Handler überschrieben.
final audioHandlerProvider = Provider<SelfifyAudioHandler>((ref) => throw UnimplementedError());

/// Verbindet den Handler mit Server, Offline-Speicher und Einstellungen. Wird in der App beobachtet.
final playbackBridgeProvider = Provider<void>((ref) {
  final handler = ref.watch(audioHandlerProvider);
  final api = ref.watch(apiProvider);
  final settings = ref.watch(settingsProvider);
  final onWifi = ref.watch(isOnWifiProvider);
  final noNetwork = ref.watch(isOfflineProvider);
  final offline = ref.read(offlineProvider.notifier);
  final quality = onWifi ? settings.wifiQuality : settings.mobileQuality;

  handler.autoplayEnabled = settings.autoplay;
  handler.sourceTokenExpiry = () => api?.tokens.mediaExpiresAt;
  handler.renewMediaToken = () async {
    final client = api;
    if (client == null) return;
    // Der Medien-Token im Link gilt einige Tage; nur erneuern, wenn auch der aktuelle bald abläuft
    if (DateTime.now().isAfter(client.tokens.mediaExpiresAt.subtract(const Duration(days: 1)))) {
      await client.refresh();
    }
  };
  handler.resolveArt = (track) =>
      api == null || track.coverId == null ? null : Uri.parse(api.coverUrl(track.coverId!, size: 600));
  handler.resolveSource = (track, item) {
    final local = offline.localPath(track.id);
    if (local != null) return AudioSource.file(local, tag: item);
    if (api == null) throw StateError('Nicht angemeldet und Titel nicht offline verfügbar.');
    // iPhones können kein Opus/Ogg -> der Server liefert dann AAC
    return AudioSource.uri(
      Uri.parse(api.streamUrl(track.id, quality: quality, compatible: Platform.isIOS)),
      tag: item,
    );
  };
  handler.reportHistory = (track, seconds, context) {
    api?.addHistory(track.id, seconds, contextType: context?.type, contextId: context?.id).ignore();
  };
  handler.autoplay = (last) async {
    if (api == null) return <Track>[];
    final tracks = await api.radio(last.id, limit: 30);
    // Offline-Modus: nur weiterspielen, was auf dem Handy liegt
    if (settings.offlineMode || noNetwork) return tracks.where((t) => offline.localPath(t.id) != null).toList();
    return tracks;
  };
  // Zuletzt: neue Qualität (WLAN ↔ mobil) gilt sofort für die kommenden Titel
  handler.streamQuality = quality;
});

final mediaItemProvider = StreamProvider<MediaItem?>((ref) => ref.watch(audioHandlerProvider).mediaItem);

final playbackStateProvider = StreamProvider<PlaybackState>((ref) => ref.watch(audioHandlerProvider).playbackState);

final queueProvider = StreamProvider<List<MediaItem>>((ref) => ref.watch(audioHandlerProvider).queue);

final positionProvider = StreamProvider<Duration>((ref) => ref.watch(audioHandlerProvider).player.positionStream);

final bufferedPositionProvider =
    StreamProvider<Duration>((ref) => ref.watch(audioHandlerProvider).player.bufferedPositionStream);

final durationProvider = StreamProvider<Duration?>((ref) => ref.watch(audioHandlerProvider).player.durationStream);

/// Schlaf-Timer: Zeitpunkt der Pause, Epoche 0 = „Ende des Titels“, null = aus.
/// Startet mit dem aktuellen Wert, damit später geöffnete Bildschirme einen laufenden Timer sehen.
final sleepTimerProvider = StreamProvider<DateTime?>((ref) async* {
  final handler = ref.watch(audioHandlerProvider);
  yield handler.sleepAfterTrack ? DateTime.fromMillisecondsSinceEpoch(0) : handler.sleepAt;
  yield* handler.sleepTimerStream;
});

/// Der gerade gespielte Titel (mit allen Angaben).
final currentTrackProvider = Provider<Track?>((ref) {
  ref.watch(mediaItemProvider);
  return ref.watch(audioHandlerProvider).currentTrack;
});

final isPlayingProvider = Provider<bool>((ref) => ref.watch(playbackStateProvider).value?.playing ?? false);

/// Läuft gerade genau dieser Titel?
final isCurrentTrackProvider =
    Provider.family<bool, int>((ref, trackId) => ref.watch(currentTrackProvider)?.id == trackId);

/// Einfache Steuerung für die Oberfläche.
class PlayerController {
  final Ref _ref;
  PlayerController(this._ref);

  SelfifyAudioHandler get handler => _ref.read(audioHandlerProvider);

  /// Spielt [tracks] ab Position [index]. Im Offline-Modus nur heruntergeladene Titel.
  Future<void> play(List<Track> tracks, {int index = 0, PlayContext? context, bool shuffle = false}) async {
    if (windowsAudioError != null) {
      throw StateError('Die Wiedergabe unter Windows konnte nicht gestartet werden (libmpv-2.dll fehlt oder wird '
          'vom Virenschutz blockiert). Bitte Selfify neu installieren.');
    }
    var list = tracks.where((t) => !t.isVideo).toList();
    // Nach Position, nicht nach Gleichheit: derselbe Titel kann mehrfach vorkommen (Playlist)
    var start = index >= 0 && index < tracks.length && !tracks[index].isVideo
        ? tracks.take(index).where((t) => !t.isVideo).length
        : 0;
    if (_ref.read(settingsProvider).offlineMode || _ref.read(isOfflineProvider)) {
      final offline = _ref.read(offlineProvider);
      // Fehlt der gewählte Titel offline, geht es mit dem nächsten heruntergeladenen weiter
      final before = list.take(start).where((t) => offline.isDownloaded(t.id)).length;
      list = list.where((t) => offline.isDownloaded(t.id)).toList();
      if (list.isEmpty) throw StateError('Keiner dieser Titel ist offline verfügbar.');
      start = before < list.length ? before : 0;
    }
    await handler.playTracks(list, index: start < 0 ? 0 : start, context: context, shuffle: shuffle);
  }

  Future<void> playOne(Track track, {PlayContext? context}) => play([track], context: context);

  Future<void> togglePlay() async {
    final handler = this.handler;
    handler.player.playing ? await handler.pause() : await handler.play();
  }

  Future<void> next() => handler.skipToNext();
  Future<void> previous() => handler.skipToPrevious();
  Future<void> seek(Duration position) => handler.seek(position);
  Future<void> addToQueue(List<Track> tracks) => handler.addTracks(tracks);
  Future<void> playNext(List<Track> tracks) => handler.playNext(tracks);

  Future<void> toggleShuffle() => handler.setShuffleMode(
      handler.player.shuffleModeEnabled ? AudioServiceShuffleMode.none : AudioServiceShuffleMode.all);

  /// Aus -> alle wiederholen -> diesen Titel wiederholen -> aus
  Future<void> cycleRepeat() => handler.setRepeatMode(switch (handler.player.loopMode) {
        LoopMode.off => AudioServiceRepeatMode.all,
        LoopMode.all => AudioServiceRepeatMode.one,
        LoopMode.one => AudioServiceRepeatMode.none,
      });

  Future<void> setSpeed(double speed) => handler.setSpeed(speed);

  /// Radio ab diesem Titel (Titel zuerst, dann Passendes).
  Future<void> startRadio(Track track) async {
    final api = _ref.read(apiProvider);
    if (api == null) return;
    if (_ref.read(settingsProvider).offlineMode || _ref.read(isOfflineProvider)) {
      throw StateError('Im Offline-Modus ist Radio nicht verfügbar.');
    }
    final tracks = await api.radio(track.id);
    await handler.playTracks(tracks, context: PlayContext('radio', id: track.id, title: '${track.title}-Radio'));
  }
}

final playerProvider = Provider<PlayerController>((ref) => PlayerController(ref));
