import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/api.dart';
import '../data/models.dart';
import '../state/app_config.dart';
import '../state/auth.dart';
import '../state/connect.dart';
import '../state/connectivity.dart';
import '../state/offline.dart';
import '../state/offline_access.dart' show clockProvider;
import '../state/premium_access.dart';
import '../state/settings.dart';
import 'audio_handler.dart';
import 'skip_limit.dart';
import 'windows_audio.dart' show windowsAudioError;

export 'audio_handler.dart' show MediaKeyTarget, PlayContext, SelfifyAudioHandler;

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
  final access = ref.watch(premiumAccessProvider);
  // „Höhere Tonqualität nur mit Premium“: höchstens die Stufe ohne Premium (der Server deckelt ebenso). Die
  // gespeicherte Einstellung bleibt – mit Premium gilt sie wieder.
  final quality = access.capQuality(onWifi ? settings.wifiQuality : settings.mobileQuality);

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
  // Verlangt der Server eine Mindest-Version fürs Hören ohne Premium, muss er auch beim Abspielen erfahren, welche
  // App fragt – nur dann bekommen die Stream-Links den Header mit (sonst bleibt alles wie bisher).
  final streamHeaders = ref.watch(streamHeadersProvider);
  handler.resolveSource = (track, item) {
    final local = offline.localPath(track.id);
    if (local != null) return AudioSource.file(local, tag: item);
    if (api == null) throw StateError('Nicht angemeldet und Titel nicht offline verfügbar.');
    // iPhones können kein Opus/Ogg -> der Server liefert dann AAC. Videos (z. B. in den Lieblingssongs) laufen
    // hier als Ton mit – der Server schickt dafür nur die Tonspur statt des ganzen Videos.
    return AudioSource.uri(
      Uri.parse(api.streamUrl(track.id, quality: quality, compatible: Platform.isIOS, audioOnly: track.isVideo)),
      headers: streamHeaders,
      tag: item,
    );
  };
  // Der Server weist das Abspielen ab: Liegt es an einer zu alten App (HTTP 426), sagt die App das – auch wenn sie
  // die Mindest-Version noch gar nicht kennt (Einstellungen nicht geladen oder vom Betreiber gerade erst gesetzt;
  // eine zu alte App erfährt davon sonst nur, dass nichts mehr spielt).
  handler.onPlaybackError = () {
    final track = handler.currentTrack;
    if (api == null || track == null || offline.localPath(track.id) != null) return;
    if (!ref.mounted) return;
    final notice = ref.read(updateRequiredNoticeProvider.notifier);
    final config = ref.read(appConfigProvider.notifier);
    final url = api.streamUrl(track.id, quality: quality, compatible: Platform.isIOS, audioOnly: track.isVideo);
    api.streamStatus(url).then((status) {
      if (status == 426) notice.show();
      // Die Einstellung war hier noch unbekannt, der Server antwortet aber: neu holen – verlangt er inzwischen
      // eine Mindest-Version, geben sich die Stream-Links ab dann zu erkennen (siehe [streamHeadersProvider]).
      if (status != null && streamHeaders == null && ref.mounted) config.refresh().ignore();
    }).ignore();
  };
  // Offline-Musik wird gelöscht (Premium abgelaufen): Die Warteschlange zeigt noch auf die Dateien. Mit Netz geht
  // die Wiedergabe an derselben Stelle als Stream weiter, sonst endet sie.
  offline.releasePlayback = (trackIds) async {
    if (!handler.tracks.any((t) => trackIds.contains(t.id))) return;
    if (api == null || noNetwork || settings.offlineMode) {
      await handler.reset();
      return;
    }
    try {
      await handler.refreshSources();
    } catch (_) {
      await handler.reset();
    }
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
  // Überspring-Grenze ohne Premium – nur wenn der Betreiber sie eingeschaltet hat; sonst exakt wie bisher
  final serverUrl = ref.watch(authProvider.select((a) => a.value?.serverUrl));
  final userId = ref.watch(currentUserProvider.select((u) => u?.id));
  if (access.config.premiumOnly.contains(PremiumFeature.skips) && serverUrl != null && userId != null) {
    final limiter =
        SkipLimiter(prefs: ref.read(sharedPreferencesProvider), key: SkipLimiter.keyFor(serverUrl, userId), access: access);
    final clock = ref.read(clockProvider);
    final notice = ref.read(skipLimitNoticeProvider.notifier);
    handler.allowSkip = () => limiter.tryConsume(clock());
    handler.onSkipBlocked = () => notice.show(skipLimitMessage(access.config.freeSkipsPerHour));
  } else {
    handler.allowSkip = null;
    handler.onSkipBlocked = null;
  }
  // Zuletzt: neue Qualität (WLAN ↔ mobil) gilt sofort für die kommenden Titel
  handler.streamQuality = quality;
  handler.streamHeaders = streamHeaders;
});

/// Kopfzeilen für Stream-Links (Abspielen, Videos) – null, solange der Server keine Mindest-Version verlangt.
///
/// „Offline-Hören nur mit Premium“ mit Mindest-Version (`offline_min_client_build`): Der Server weist beim Stream
/// alle ohne Premium ab, deren App zu alt ist **oder sich nicht zu erkennen gibt** (HTTP 426). Ohne diese Kopfzeile
/// träfe das auch die aktuelle App.
final streamHeadersProvider = Provider<Map<String, String>?>((ref) {
  final active =
      ref.watch(appConfigValueProvider.select((c) => c.offlineRequiresPremium && c.offlineMinClientBuild > 0));
  return active ? clientHeaders : null;
});

/// Meldung des Servers bei HTTP 426 (App zu alt für „Offline-Hören nur mit Premium“).
const updateRequiredMessage = 'Bitte aktualisiere die App.';

/// Hinweis „Bitte aktualisiere die App.“ – die Oberfläche zeigt ihn einmal und räumt ihn weg.
class UpdateRequiredNotice extends Notifier<bool> {
  @override
  bool build() => false;

  void show() => state = true;
  void clear() => state = false;
}

final updateRequiredNoticeProvider = NotifierProvider<UpdateRequiredNotice, bool>(UpdateRequiredNotice.new);

final mediaItemProvider = StreamProvider<MediaItem?>((ref) => ref.watch(audioHandlerProvider).mediaItem);

final playbackStateProvider = StreamProvider<PlaybackState>((ref) => ref.watch(audioHandlerProvider).playbackState);

final queueProvider = StreamProvider<List<MediaItem>>((ref) => ref.watch(audioHandlerProvider).queue);

// ------------------------------------------------------------------ Anzeige (lokal oder ferngesteuert)
//
// Spielt ein anderes Gerät (Remote-Modus, siehe state/connect.dart), zeigen diese Provider dessen Stand – sonst den
// des eigenen Players. Die Oberfläche liest nur hier, damit beides gleich aussieht.

/// Wird gerade ein anderes Gerät ferngesteuert?
final isRemoteProvider = Provider<bool>((ref) => ref.watch(connectProvider.select((s) => s.isRemote)));

/// Stand des ferngesteuerten Geräts (null, wenn hier gespielt wird).
final remoteStateProvider = Provider<RemoteState?>(
  (ref) => ref.watch(isRemoteProvider) ? ref.watch(connectProvider.select((s) => s.remote)) : null,
);

/// Das ferngesteuerte Gerät (null, wenn hier gespielt wird).
final remoteDeviceProvider = Provider<PlaybackDevice?>(
  (ref) => ref.watch(isRemoteProvider) ? ref.watch(connectProvider.select((s) => s.activeDevice)) : null,
);

/// Position – im Remote-Modus lokal hochgerechnet (alle 500 ms neu, ohne Uhrvergleich zwischen Geräten).
final positionProvider = StreamProvider<Duration>((ref) {
  if (ref.watch(isRemoteProvider)) {
    final remote = ref.watch(remoteStateProvider);
    final clock = ref.read(clockProvider);
    if (remote == null) return Stream.value(Duration.zero);
    if (!remote.playing) return Stream.value(remote.positionAt(clock()));
    return _ticking(() => remote.positionAt(clock()));
  }
  return ref.watch(audioHandlerProvider).player.positionStream;
});

Stream<Duration> _ticking(Duration Function() position) async* {
  yield position();
  yield* Stream.periodic(const Duration(milliseconds: 500), (_) => position());
}

final bufferedPositionProvider = StreamProvider<Duration>((ref) {
  if (ref.watch(isRemoteProvider)) return Stream.value(Duration.zero);
  return ref.watch(audioHandlerProvider).player.bufferedPositionStream;
});

final durationProvider = StreamProvider<Duration?>((ref) {
  if (ref.watch(isRemoteProvider)) return Stream.value(ref.watch(remoteStateProvider)?.duration);
  return ref.watch(audioHandlerProvider).player.durationStream;
});

/// Schlaf-Timer: Zeitpunkt der Pause, Epoche 0 = „Ende des Titels“, null = aus.
/// Startet mit dem aktuellen Wert, damit später geöffnete Bildschirme einen laufenden Timer sehen.
final sleepTimerProvider = StreamProvider<DateTime?>((ref) async* {
  final handler = ref.watch(audioHandlerProvider);
  yield handler.sleepAfterTrack ? DateTime.fromMillisecondsSinceEpoch(0) : handler.sleepAt;
  yield* handler.sleepTimerStream;
});

/// Der gerade gespielte Titel (mit allen Angaben) – im Remote-Modus der des anderen Geräts.
final currentTrackProvider = Provider<Track?>((ref) {
  if (ref.watch(isRemoteProvider)) return ref.watch(remoteStateProvider)?.track;
  ref.watch(mediaItemProvider);
  return ref.watch(audioHandlerProvider).currentTrack;
});

final isPlayingProvider = Provider<bool>((ref) {
  if (ref.watch(isRemoteProvider)) return ref.watch(remoteStateProvider)?.playing ?? false;
  return ref.watch(playbackStateProvider).value?.playing ?? false;
});

/// Lädt/puffert der Player gerade (Ladekreis im Abspielknopf)? Im Remote-Modus nie.
final isBufferingProvider = Provider<bool>((ref) {
  if (ref.watch(isRemoteProvider)) return false;
  final processing = ref.watch(playbackStateProvider).value?.processingState;
  return processing == AudioProcessingState.loading || processing == AudioProcessingState.buffering;
});

/// Zufallswiedergabe an?
final shuffleEnabledProvider = Provider<bool>((ref) {
  if (ref.watch(isRemoteProvider)) return ref.watch(remoteStateProvider)?.shuffle ?? false;
  return (ref.watch(playbackStateProvider).value?.shuffleMode ?? AudioServiceShuffleMode.none) !=
      AudioServiceShuffleMode.none;
});

final repeatModeProvider = Provider<AudioServiceRepeatMode>((ref) {
  if (ref.watch(isRemoteProvider)) return ref.watch(remoteStateProvider)?.repeat ?? AudioServiceRepeatMode.none;
  return ref.watch(playbackStateProvider).value?.repeatMode ?? AudioServiceRepeatMode.none;
});

/// Woher die Wiedergabe kommt („Wird gespielt von …“).
final playContextProvider = Provider<PlayContext?>((ref) {
  if (ref.watch(isRemoteProvider)) return ref.watch(remoteStateProvider)?.context;
  ref.watch(queueProvider);
  ref.watch(mediaItemProvider);
  return ref.watch(audioHandlerProvider).playContext;
});

/// Läuft gerade genau dieser Titel?
final isCurrentTrackProvider =
    Provider.family<bool, int>((ref, trackId) => ref.watch(currentTrackProvider)?.id == trackId);

/// Meldung, wenn im Offline-Modus keiner der Titel auf dem Gerät liegt.
const offlineUnavailableMessage = 'Keiner dieser Titel ist offline verfügbar.';

/// Meldung, wenn die Windows-Wiedergabe nicht starten kann.
const windowsPlaybackMessage = 'Die Wiedergabe unter Windows konnte nicht gestartet werden (libmpv-2.dll fehlt oder '
    'wird vom Virenschutz blockiert). Bitte Selfify neu installieren.';

/// Gespeicherte Lautstärke am PC.
const desktopVolumeKey = 'desktop.volume';

/// Lautstärke setzen und für den nächsten Start merken. Auf ganze Prozent gerundet – sonst bleibt nach
/// mehrmals „leiser“ ein winziger Rest (z. B. 1e-16) statt 0, und „Stumm“/„Ton an“ stimmt nicht mehr.
Future<void> setPlayerVolume(SharedPreferences? prefs, SelfifyAudioHandler handler, double volume) async {
  final value = (volume.clamp(0.0, 1.0) * 100).round() / 100;
  try {
    prefs?.setDouble(desktopVolumeKey, value).ignore();
  } catch (_) {}
  await handler.player.setVolume(value);
}

/// Einfache Steuerung für die Oberfläche. Im Remote-Modus gehen die Befehle an das aktive andere Gerät.
class PlayerController {
  final Ref _ref;
  PlayerController(this._ref);

  SelfifyAudioHandler get handler => _ref.read(audioHandlerProvider);

  bool get _remote => _ref.read(connectProvider).isRemote;

  /// Befehl an das ferngesteuerte Gerät; Fehler kommen als [StateError] mit verständlichem Text.
  Future<void> _command(String action, [Map<String, Object?> args = const {}]) async {
    final result = await _ref.read(connectProvider.notifier).remoteCommand(action, args);
    if (!result.ok) throw StateError(result.text);
  }

  /// Spielt [tracks] ab Position [index]. Im Offline-Modus nur heruntergeladene Titel.
  Future<void> play(List<Track> tracks, {int index = 0, PlayContext? context, bool shuffle = false}) async {
    if (_remote) {
      if (tracks.isEmpty) return;
      // Höchstens 1000 Titel – bei längeren Listen ein Ausschnitt um den gewählten Titel (sonst startete z. B. Titel
      // 1201 einer Playlist auf dem anderen Gerät beim ersten Titel)
      final chosen = index >= 0 && index < tracks.length ? index : 0;
      final start = queueWindowStart(tracks.length, chosen);
      return _command('play', {
        'track_ids': [for (final t in tracks.skip(start).take(ConnectController.maxQueueIds)) t.id],
        'index': chosen - start,
        'shuffle': shuffle,
        'context': playContextJson(context),
      });
    }
    await playLocally(tracks, index: index, context: context, shuffle: shuffle);
  }

  /// Auf diesem Gerät abspielen (auch wenn gerade ein anderes ferngesteuert wird – z. B. als Ziel eines Befehls).
  /// Mit [wait] = false endet der Aufruf, sobald die Wiedergabe gestartet ist.
  Future<void> playLocally(List<Track> tracks,
      {int index = 0, PlayContext? context, bool shuffle = false, bool wait = true}) async {
    if (windowsAudioError != null) throw StateError(windowsPlaybackMessage);
    // Videos laufen als Ton mit (wie Musikvideos bei Spotify) – sonst hielte z. B. eine Playlist mit
    // Song und Video nach dem Song einfach an. Ansehen lässt sich ein Video weiterhin per Antippen.
    var list = tracks.toList();
    // Nach Position, nicht nach Gleichheit: derselbe Titel kann mehrfach vorkommen (Playlist)
    var start = index >= 0 && index < tracks.length ? index : 0;
    if (_ref.read(settingsProvider).offlineMode || _ref.read(isOfflineProvider)) {
      final offline = _ref.read(offlineProvider);
      // Fehlt der gewählte Titel offline, geht es mit dem nächsten heruntergeladenen weiter
      final before = list.take(start).where((t) => offline.isDownloaded(t.id)).length;
      list = list.where((t) => offline.isDownloaded(t.id)).toList();
      if (list.isEmpty) throw StateError(offlineUnavailableMessage);
      start = before < list.length ? before : 0;
    }
    await handler.playTracks(list, index: start < 0 ? 0 : start, context: context, shuffle: shuffle, wait: wait);
  }

  Future<void> playOne(Track track, {PlayContext? context}) => play([track], context: context);

  Future<void> togglePlay() async {
    if (_remote) {
      final playing = _ref.read(connectProvider).remote?.playing ?? false;
      return playing ? pause() : resume();
    }
    final handler = this.handler;
    handler.player.playing ? await handler.pause() : await handler.play();
  }

  /// Weiterspielen (im Remote-Modus mit sofortiger Anzeige, bei Fehler zurück).
  Future<void> resume() => _remote ? _optimistic(true) : handler.play();

  Future<void> pause() => _remote ? _optimistic(false) : handler.pause();

  Future<void> _optimistic(bool playing) async {
    final connect = _ref.read(connectProvider.notifier);
    connect.showPlaying(playing);
    final result = await connect.remoteCommand(playing ? 'resume' : 'pause');
    if (!result.ok) {
      connect.revertPlaying();
      throw StateError(result.text);
    }
  }

  Future<void> next() => _remote ? _command('next') : handler.skipToNext();
  Future<void> previous() => _remote ? _command('previous') : handler.skipToPrevious();

  Future<void> seek(Duration position) => _remote
      ? _command('seek', {'position_ms': position.inMilliseconds < 0 ? 0 : position.inMilliseconds})
      : handler.seek(position);

  Future<void> addToQueue(List<Track> tracks) => _remote
      ? _command('add_queue', {'track_ids': [for (final t in tracks.take(1000)) t.id]})
      : addToQueueLocally(tracks);

  Future<void> playNext(List<Track> tracks) => _remote
      ? _command('play_next', {'track_ids': [for (final t in tracks.take(1000)) t.id]})
      : playNextLocally(tracks);

  Future<void> addToQueueLocally(List<Track> tracks) => handler.addTracks(tracks);
  Future<void> playNextLocally(List<Track> tracks) => handler.playNext(tracks);

  /// Index für einen Befehl an das andere Gerät: [index] zählt im gemeldeten Ausschnitt (`queue_ids`), das Ziel
  /// rechnet in seiner vollen Warteschlange – also den Versatz dazu. `track_id` sagt, welcher Titel dort erwartet wird
  /// (hat sich die Warteschlange inzwischen verschoben, trifft der Befehl so trotzdem den gemeinten oder gar keinen).
  Map<String, Object?> _queueArgs(String key, int index) {
    final remote = _ref.read(connectProvider).remote;
    final ids = remote?.queueIds ?? const <int>[];
    return {
      key: index + (remote?.queueOffset ?? 0),
      if (index >= 0 && index < ids.length) 'track_id': ids[index],
    };
  }

  /// Zu einem Titel der Warteschlange springen ([index] in der Original-Reihenfolge).
  Future<void> skipToQueueItem(int index) =>
      _remote ? _command('skip_to', _queueArgs('index', index)) : handler.skipToQueueItem(index);

  Future<void> removeFromQueue(int index) =>
      _remote ? _command('remove_queue', _queueArgs('index', index)) : handler.removeQueueItemAt(index);

  Future<void> moveInQueue(int from, int to) => _remote
      ? _command('move_queue', {
          ..._queueArgs('from', from),
          'to': to + (_ref.read(connectProvider).remote?.queueOffset ?? 0),
        })
      : handler.moveQueueItem(from, to);

  Future<void> clearUpcoming() => _remote ? _command('clear_upcoming') : handler.clearUpcoming();

  Future<void> toggleShuffle() {
    if (_remote) {
      return _command('set_shuffle', {'enabled': !(_ref.read(connectProvider).remote?.shuffle ?? false)});
    }
    return handler.setShuffleMode(
        handler.player.shuffleModeEnabled ? AudioServiceShuffleMode.none : AudioServiceShuffleMode.all);
  }

  /// Aus -> alle wiederholen -> diesen Titel wiederholen -> aus
  Future<void> cycleRepeat() {
    if (_remote) {
      final next = switch (_ref.read(connectProvider).remote?.repeat ?? AudioServiceRepeatMode.none) {
        AudioServiceRepeatMode.none => 'all',
        AudioServiceRepeatMode.one => 'off',
        _ => 'one',
      };
      return _command('set_repeat', {'mode': next});
    }
    return handler.setRepeatMode(switch (handler.player.loopMode) {
      LoopMode.off => AudioServiceRepeatMode.all,
      LoopMode.all => AudioServiceRepeatMode.one,
      LoopMode.one => AudioServiceRepeatMode.none,
    });
  }

  /// Lautstärke (0–1): am PC die eigene (gemerkt), im Remote-Modus die des anderen Geräts (nur wenn es das kann).
  Future<void> setVolume(double volume) {
    if (_remote) return _command('set_volume', {'volume': (volume.clamp(0.0, 1.0) * 100).round() / 100});
    SharedPreferences? prefs;
    try {
      prefs = _ref.read(sharedPreferencesProvider);
    } catch (_) {}
    return setPlayerVolume(prefs, handler, volume);
  }

  Future<void> setSpeed(double speed) => handler.setSpeed(speed);

  /// Radio ab diesem Titel (Titel zuerst, dann Passendes).
  Future<void> startRadio(Track track) async {
    final api = _ref.read(apiProvider);
    if (api == null) return;
    final remote = _remote;
    if (!remote && (_ref.read(settingsProvider).offlineMode || _ref.read(isOfflineProvider))) {
      throw StateError('Im Offline-Modus ist Radio nicht verfügbar.');
    }
    // Radio bleibt reine Musik (wie Autoplay) – Videos laufen nur mit, wenn man sie selbst in die Liste nimmt
    final tracks = (await api.radio(track.id)).where((t) => !t.isVideo).toList();
    final context = PlayContext('radio', id: track.id, title: '${track.title}-Radio');
    if (remote) return play(tracks, context: context);
    await handler.playTracks(tracks, context: context);
  }
}

final playerProvider = Provider<PlayerController>((ref) => PlayerController(ref));
