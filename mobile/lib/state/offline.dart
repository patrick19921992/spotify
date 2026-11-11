import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../data/api.dart';
import '../data/models.dart';
import 'auth.dart';
import 'connectivity.dart';
import 'offline_access.dart';
import 'settings.dart';

/// Ein aufs Handy geladener Titel.
class OfflineTrack {
  final Track track;
  final String fileName;
  final int size;
  final DateTime savedAt;

  const OfflineTrack({required this.track, required this.fileName, required this.size, required this.savedAt});

  Json toJson() => {'track': track.toJson(), 'file': fileName, 'size': size, 'saved_at': savedAt.toIso8601String()};

  factory OfflineTrack.fromJson(Json j) => OfflineTrack(
        track: Track.fromJson(j['track'] as Json),
        fileName: j['file'] as String,
        size: (j['size'] as num?)?.toInt() ?? 0,
        savedAt: DateTime.tryParse(j['saved_at']?.toString() ?? '') ?? DateTime.now(),
      );
}

/// Schlüssel für Sammlungen, die offline gehalten werden.
String playlistKey(int id) => 'playlist:$id';
String albumKey(int id) => 'album:$id';
const likedKey = 'liked';

class OfflineState {
  final Map<int, OfflineTrack> tracks;
  /// Sammlung -> Titel-IDs (z. B. "playlist:5" -> [1, 2, 3])
  final Map<String, List<int>> collections;
  /// Anzeigenamen der Sammlungen
  final Map<String, String> collectionNames;
  /// Titel-ID -> Fortschritt 0..1 (läuft gerade)
  final Map<int, double> progress;
  /// Warteschlange (Titel-IDs)
  final List<int> pending;
  final String? lastError;
  final bool loaded;

  const OfflineState({
    this.tracks = const {},
    this.collections = const {},
    this.collectionNames = const {},
    this.progress = const {},
    this.pending = const [],
    this.lastError,
    this.loaded = false,
  });

  int get totalBytes => tracks.values.fold(0, (sum, t) => sum + t.size);
  bool isDownloaded(int trackId) => tracks.containsKey(trackId);
  bool isPending(int trackId) => pending.contains(trackId) || progress.containsKey(trackId);
  bool isCollectionOffline(String key) => collections.containsKey(key);

  /// 0..1 – wie viel einer Sammlung schon auf dem Handy ist.
  double collectionProgress(String key) {
    final ids = collections[key];
    if (ids == null || ids.isEmpty) return 0;
    return ids.where(tracks.containsKey).length / ids.length;
  }

  OfflineState copyWith({
    Map<int, OfflineTrack>? tracks,
    Map<String, List<int>>? collections,
    Map<String, String>? collectionNames,
    Map<int, double>? progress,
    List<int>? pending,
    String? Function()? lastError,
    bool? loaded,
  }) =>
      OfflineState(
        tracks: tracks ?? this.tracks,
        collections: collections ?? this.collections,
        collectionNames: collectionNames ?? this.collectionNames,
        progress: progress ?? this.progress,
        pending: pending ?? this.pending,
        lastError: lastError != null ? lastError() : this.lastError,
        loaded: loaded ?? this.loaded,
      );
}

/// Offline-Modus: Titel, Alben, Playlists und Lieblingssongs aufs Handy laden.
class OfflineController extends Notifier<OfflineState> {
  Directory? _dir;
  final Map<int, Track> _queued = {};
  bool _working = false;
  CancelToken? _cancel;
  Future<void> _saveQueue = Future.value();

  /// Konto (Server und Benutzer), dem die Offline-Musik auf diesem Gerät gehört – null, solange unbekannt
  /// (Bestand von früher, noch niemand angemeldet).
  String? _owner;

  /// Die Musik liegt unter der Sperre „Offline-Hören nur mit Premium“ auf dem Gerät: Sie darf nicht an ein anderes
  /// Konto oder einen anderen Server übergehen, für den die Sperre nicht gilt.
  bool _protected = false;

  /// Beim Löschen ließ sich nicht alles entfernen (z. B. unter Windows eine gerade geöffnete Datei): Der Ordner
  /// wird später noch einmal aufgeräumt – gleich und beim nächsten Start.
  bool _cleanupPending = false;
  Timer? _cleanupTimer;
  int _cleanupAttempts = 0;

  /// Läuft gerade ein Löschen? Dann wird nichts mehr vom Gerät abgespielt.
  int _wiping = 0;

  /// Dateien des laufenden Downloads beginnen so („12.“) – sie werden beim Aufräumen nicht angefasst.
  String? _activePrefix;

  /// Löst die laufende Wiedergabe von den Offline-Dateien, bevor sie gelöscht werden (setzt der Player, siehe
  /// `playbackBridgeProvider`). Bekommt die Titel, die bisher auf dem Gerät lagen.
  Future<void> Function(Set<int> trackIds)? releasePlayback;

  /// Abstand, in dem nicht löschbare Dateien erneut versucht werden (in Tests kürzer).
  @visibleForTesting
  static Duration cleanupRetry = const Duration(seconds: 15);

  /// Löscht eine Datei oder einen Ordner (in Tests ersetzbar, um ein gesperrtes Dateisystem nachzustellen).
  @visibleForTesting
  static Future<void> Function(FileSystemEntity entry) deleteEntry = _deleteEntry;

  static Future<void> _deleteEntry(FileSystemEntity entry) => entry.delete(recursive: true);

  @override
  OfflineState build() {
    ref.onDispose(() => _cleanupTimer?.cancel());
    Future.microtask(_load);
    ref.listen(connectivityProvider, (_, _) => _pump());
    // "Nur im WLAN" ausgeschaltet -> wartende Downloads sofort starten
    ref.listen(settingsProvider.select((s) => s.offlineWifiOnly), (_, _) => _pump());
    // Die Anmeldung wird beim Start oft erst nach dem Index geladen: dann die Warteschlange fortsetzen
    // … und prüfen, wem die Offline-Musik gehört (anderes Konto oder anderer Server)
    ref.listen(apiProvider, (_, api) {
      if (api != null) _applyAccess();
    });
    ref.listen(currentUserProvider.select((u) => u?.id), (_, _) => _applyAccess());
    // „Offline-Hören nur mit Premium“: gesperrt -> Offline-Musik löschen; wieder erlaubt -> Warteschlange fortsetzen
    ref.listen(offlineAccessProvider, (_, _) => _applyAccess());
    return const OfflineState();
  }

  OfflineAccessState get _access => ref.read(offlineAccessProvider);

  /// Das angemeldete Konto (Server und Benutzer) – null, wenn niemand angemeldet ist.
  String? get _account {
    final auth = ref.read(authProvider).value;
    final user = auth?.user;
    final serverUrl = auth?.serverUrl;
    if (auth == null || !auth.isLoggedIn || user == null || serverUrl == null) return null;
    return accountKey(serverUrl, user.id);
  }

  bool get _hasContent => state.tracks.isNotEmpty || state.collections.isNotEmpty || state.pending.isNotEmpty;

  /// Setzt den Stand der Offline-Berechtigung um. Gelöscht wird erst, wenn der Index geladen ist.
  void _applyAccess() {
    if (!state.loaded) return;
    final access = _access;
    final account = _account;
    if (account != null) {
      // Die Musik wurde unter der Sperre von einem anderen Konto (oder an einem anderen Server) geladen: Sie geht
      // nicht auf dieses Konto über – sonst bliebe sie nach dem Ablauf von Premium über einen Wechsel des Kontos
      // oder zu einem Server ohne Sperre spielbar. Ohne Sperre bleibt es wie bisher: Die Dateien gehören zum Gerät.
      final foreign = _owner != null && _owner != account && _protected && _hasContent;
      final protect = access.access != OfflineAccess.free;
      final changed = _owner != account || _protected != protect;
      _owner = account;
      _protected = protect;
      if (foreign) {
        _wipeWithNotice(offlineOtherAccountMessage);
        return;
      }
      if (changed) _save().ignore();
    }
    if (access.access == OfflineAccess.locked) {
      _wipeWithNotice(offlineWipeMessage(access));
    } else {
      _pump();
    }
  }

  void _wipeWithNotice(String message) {
    wipe().then((removed) {
      if (removed && ref.mounted) ref.read(offlineWipeNoticeProvider.notifier).show(message);
    }).ignore();
  }

  Future<Directory> _directory() async {
    final existing = _dir;
    if (existing != null) return existing;
    // Windows: „Dokumente“ wird oft per OneDrive hochgeladen – Musik gehört nach AppData\Local
    final base = Platform.isWindows ? await getApplicationCacheDirectory() : await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/offline');
    await dir.create(recursive: true);
    _dir = dir;
    return dir;
  }

  File _indexFile(Directory dir) => File('${dir.path}/index.json');

  Future<void> _load() async {
    final dir = await _directory();
    final file = _indexFile(dir);
    if (!await file.exists()) {
      state = state.copyWith(loaded: true);
      _applyAccess();
      return;
    }
    try {
      final data = jsonDecode(await file.readAsString()) as Json;
      final tracks = <int, OfflineTrack>{};
      for (final entry in (data['tracks'] as Map? ?? const {}).entries) {
        final item = OfflineTrack.fromJson(entry.value as Json);
        if (await File('${dir.path}/${item.fileName}').exists()) tracks[item.track.id] = item;
      }
      final collections = <String, List<int>>{
        for (final entry in (data['collections'] as Map? ?? const {}).entries)
          entry.key as String: (entry.value as List).map((e) => (e as num).toInt()).toList(),
      };
      final names = <String, String>{
        for (final entry in (data['names'] as Map? ?? const {}).entries) entry.key as String: entry.value as String,
      };
      // Warteschlange vom letzten Mal (App wurde beendet, bevor alles geladen war)
      final pending = <int>[];
      for (final raw in (data['queue'] as List? ?? const [])) {
        final track = Track.fromJson(raw as Json);
        if (tracks.containsKey(track.id) || pending.contains(track.id)) continue;
        _queued[track.id] = track;
        pending.add(track.id);
      }
      _owner = data['owner'] is String ? data['owner'] as String : null;
      _protected = data['protected'] == true;
      _cleanupPending = data['cleanup'] == true;
      state = state.copyWith(
        tracks: tracks,
        collections: collections,
        collectionNames: names,
        pending: pending,
        loaded: true,
      );
    } catch (_) {
      state = state.copyWith(loaded: true);
    }
    // Beim letzten Löschen blieb etwas liegen (Datei war noch geöffnet): jetzt nachholen
    if (_cleanupPending) await _cleanup();
    // Das Aufräumen kann dauern – inzwischen kann der Speicher beendet worden sein (Abmelden, App schließt)
    if (!ref.mounted) return;
    // Gesperrt: löschen; sonst die Warteschlange fortsetzen
    _applyAccess();
  }

  /// Speichert den Index – nacheinander, damit sich zwei Speichervorgänge nicht überholen.
  Future<void> _save() {
    final next = _saveQueue.then((_) => _write());
    _saveQueue = next.catchError((Object _) {});
    return next;
  }

  Future<void> _write() async {
    final dir = await _directory();
    final file = _indexFile(dir);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode({
      'tracks': {for (final t in state.tracks.values) '${t.track.id}': t.toJson()},
      'collections': state.collections,
      'names': state.collectionNames,
      'queue': [
        for (final id in state.pending)
          if (_queued[id] case final track?) track.toJson(),
      ],
      'owner': ?_owner,
      if (_protected) 'protected': true,
      if (_cleanupPending) 'cleanup': true,
    }));
    await tmp.rename(file.path);
  }

  /// Fehlermeldung ausblenden.
  void clearError() {
    if (state.lastError != null) state = state.copyWith(lastError: () => null);
  }

  /// Pfad der Datei auf dem Handy – oder null, wenn nicht heruntergeladen.
  String? localPath(int trackId) {
    // Gesperrt (kein Premium mehr): nichts vom Gerät abspielen, auch wenn die Dateien noch nicht gelöscht sind
    if (_wiping > 0 || !_access.canPlayLocal) return null;
    final item = state.tracks[trackId];
    final dir = _dir;
    if (item == null || dir == null) return null;
    return '${dir.path}/${item.fileName}';
  }

  /// Einzelne Titel herunterladen.
  void downloadTracks(List<Track> tracks) {
    if (!_access.canDownload) return;
    final pending = [...state.pending];
    for (final track in tracks) {
      if (track.isVideo || state.tracks.containsKey(track.id) || pending.contains(track.id)) continue;
      _queued[track.id] = track;
      pending.add(track.id);
    }
    state = state.copyWith(pending: pending, lastError: () => null);
    _save().ignore();
    _pump();
  }

  /// Album/Playlist/Lieblingssongs offline verfügbar halten.
  Future<void> keepCollection(String key, String name, List<Track> tracks) async {
    if (!_access.canDownload) return;
    final audio = tracks.where((t) => !t.isVideo).toList();
    state = state.copyWith(
      collections: {...state.collections, key: audio.map((t) => t.id).toList()},
      collectionNames: {...state.collectionNames, key: name},
    );
    await _save();
    downloadTracks(audio);
  }

  /// Sammlung nicht mehr offline halten – löscht Titel, die sonst nirgends gebraucht werden.
  Future<void> releaseCollection(String key) async {
    final ids = state.collections[key] ?? const [];
    final collections = Map<String, List<int>>.of(state.collections)..remove(key);
    final names = Map<String, String>.of(state.collectionNames)..remove(key);
    final stillNeeded = collections.values.expand((e) => e).toSet();
    state = state.copyWith(collections: collections, collectionNames: names);
    for (final id in ids) {
      if (!stillNeeded.contains(id)) await removeTrack(id, save: false);
    }
    await _save();
  }

  /// Inhalt einer offline gehaltenen Sammlung aktualisieren (neue Titel nachladen, entfernte löschen).
  Future<void> syncCollection(String key, List<Track> tracks) async {
    if (!state.collections.containsKey(key) || !_access.canDownload) return;
    final name = state.collectionNames[key] ?? key;
    final oldIds = state.collections[key]!.toSet();
    final newIds = tracks.where((t) => !t.isVideo).map((t) => t.id).toSet();
    await keepCollection(key, name, tracks);
    final stillNeeded = state.collections.values.expand((e) => e).toSet();
    for (final id in oldIds.difference(newIds)) {
      if (!stillNeeded.contains(id)) await removeTrack(id, save: false);
    }
    await _save();
  }

  Future<void> removeTrack(int trackId, {bool save = true}) async {
    final item = state.tracks[trackId];
    if (item != null) {
      final dir = await _directory();
      try {
        await File('${dir.path}/${item.fileName}').delete();
      } catch (_) {}
    }
    _queued.remove(trackId);
    // Lädt der Titel gerade aufs Handy: abbrechen, er wird nicht mehr gebraucht
    if (state.progress.containsKey(trackId)) _cancel?.cancel();
    state = state.copyWith(
      tracks: Map.of(state.tracks)..remove(trackId),
      pending: [...state.pending]..remove(trackId),
    );
    if (save) await _save();
  }

  Future<void> removeAll() async {
    _cancel?.cancel();
    _queued.clear();
    final dir = await _directory();
    for (final item in state.tracks.values) {
      try {
        await File('${dir.path}/${item.fileName}').delete();
      } catch (_) {}
    }
    state = state.copyWith(tracks: {}, collections: {}, collectionNames: {}, pending: [], progress: {});
    await _save();
  }

  /// Löscht ausnahmslos alles, was offline auf diesem Gerät liegt – wenn Premium abgelaufen ist oder zu lange nicht
  /// geprüft werden konnte. Anders als [removeAll] auch halb geladene und verwaiste Dateien im Ordner.
  /// Liefert true, wenn etwas entfernt wurde. Mehrfaches Auslösen ist unschädlich.
  Future<bool> wipe() async {
    if (!state.loaded) return false;
    _wiping++;
    try {
      _cancel?.cancel();
      _queued.clear();
      var removed = _hasContent;
      final played = state.tracks.keys.toSet();
      state = state.copyWith(
        tracks: {},
        collections: {},
        collectionNames: {},
        pending: [],
        progress: {},
        lastError: () => null,
      );
      // Läuft gerade einer dieser Titel vom Gerät? Erst die Wiedergabe von den Dateien lösen (sie geht als Stream
      // weiter oder endet) – sonst spielte der offene Titel zu Ende, die nächsten zeigten ins Leere, und unter
      // Windows ließe sich die geöffnete Datei gar nicht löschen.
      if (played.isNotEmpty) {
        try {
          await releasePlayback?.call(played).timeout(const Duration(seconds: 5));
        } catch (_) {}
      }
      final dir = await _directory();
      // Erst den laufenden Speichervorgang abwarten, dann aufräumen und einen leeren Index schreiben
      await _saveQueue;
      final sweep = await _sweep(dir, keep: (_) => false);
      if (sweep.removed) removed = true;
      _cleanupPending = sweep.failed;
      await _save();
      if (sweep.failed) {
        _cleanupAttempts = 0;
        _scheduleCleanup();
      }
      return removed;
    } finally {
      _wiping--;
    }
  }

  /// Löscht alles im Offline-Ordner außer dem Index und den Dateien, die [keep] behalten will.
  Future<({bool removed, bool failed})> _sweep(Directory dir, {required bool Function(String name) keep}) async {
    var removed = false;
    var failed = false;
    try {
      await for (final entry in dir.list(followLinks: false)) {
        final name = entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty, orElse: () => '');
        if (name == 'index.json' || name == 'index.json.tmp' || keep(name)) continue;
        try {
          await deleteEntry(entry);
          removed = true;
        } catch (_) {
          failed = true;
        }
      }
    } catch (_) {
      failed = true;
    }
    return (removed: removed, failed: failed);
  }

  /// Räumt Dateien weg, die beim Löschen liegen geblieben sind (alles ohne Eintrag im Index).
  Future<void> _cleanup() async {
    _cleanupTimer = null;
    if (!_cleanupPending || !ref.mounted) return;
    final dir = await _directory();
    final known = {for (final item in state.tracks.values) item.fileName};
    final sweep = await _sweep(dir, keep: (name) {
      final active = _activePrefix;
      return known.contains(name) || (active != null && name.startsWith(active));
    });
    if (!ref.mounted) return;
    if (sweep.failed) {
      // Bleibt vermerkt: spätestens der nächste Start versucht es wieder
      if (++_cleanupAttempts < 4) _scheduleCleanup();
      return;
    }
    _cleanupPending = false;
    await _save();
  }

  void _scheduleCleanup() => _cleanupTimer ??= Timer(cleanupRetry, () => _cleanup().ignore());

  bool get _networkAllowed {
    if (ref.read(isOfflineProvider)) return false;
    final settings = ref.read(settingsProvider);
    return !settings.offlineWifiOnly || ref.read(isOnWifiProvider);
  }

  /// Arbeitet die Warteschlange nacheinander ab.
  Future<void> _pump() async {
    if (_working) return;
    _working = true;
    try {
      // Ohne Berechtigung (kein Premium, Stand unklar) wird nichts geladen – Wartendes bleibt in der Schlange
      while (state.pending.isNotEmpty && _networkAllowed && _access.canDownload) {
        final api = ref.read(apiProvider);
        if (api == null) break;
        final trackId = state.pending.first;
        final track = _queued[trackId];
        if (track == null) {
          state = state.copyWith(pending: [...state.pending]..remove(trackId));
          continue;
        }
        await _downloadOne(api, track);
      }
    } finally {
      _working = false;
    }
  }

  Future<void> _downloadOne(ApiClient api, Track track) async {
    final dir = await _directory();
    final quality = ref.read(settingsProvider).offlineQuality;
    final url = api.streamUrl(track.id, quality: quality, compatible: Platform.isIOS);
    final tmpPath = '${dir.path}/${track.id}.part';
    _activePrefix = '${track.id}.';
    _cancel = CancelToken();
    state = state.copyWith(progress: {...state.progress, track.id: 0});
    try {
      final response = await api.downloadFile(url, tmpPath, cancelToken: _cancel, onProgress: (received, total) {
        if (total > 0) state = state.copyWith(progress: {...state.progress, track.id: received / total});
      });
      final type = response.headers.value('content-type') ?? '';
      final extension = _extensionFor(type);
      final fileName = '${track.id}.$extension';
      final file = await File(tmpPath).rename('${dir.path}/$fileName');
      if (!_queued.containsKey(track.id)) {
        // Während des Ladens entfernt (Titel oder ganze Sammlung): nicht behalten
        try {
          await file.delete();
        } catch (_) {}
        state = state.copyWith(progress: Map.of(state.progress)..remove(track.id));
        return;
      }
      final item = OfflineTrack(track: track, fileName: fileName, size: await file.length(), savedAt: DateTime.now());
      _queued.remove(track.id);
      state = state.copyWith(
        tracks: {...state.tracks, track.id: item},
        progress: Map.of(state.progress)..remove(track.id),
        pending: [...state.pending]..remove(track.id),
      );
      await _save();
    } catch (e) {
      try {
        await File(tmpPath).delete();
      } catch (_) {}
      final message = e is ApiException ? e.message : e.toString();
      final cancelled = e is ApiException && message == 'Abgebrochen.';
      state = state.copyWith(
        progress: Map.of(state.progress)..remove(track.id),
        pending: cancelled ? state.pending : ([...state.pending]..remove(track.id)),
        lastError: () => cancelled ? null : '„${track.title}“ konnte nicht geladen werden: $message',
      );
      if (!cancelled) _queued.remove(track.id);
    } finally {
      _activePrefix = null;
    }
  }

  static String _extensionFor(String contentType) {
    final type = contentType.split(';').first.trim().toLowerCase();
    return switch (type) {
      'audio/mp4' || 'audio/x-m4a' || 'audio/aac' => 'm4a',
      'audio/mpeg' => 'mp3',
      'audio/ogg' || 'audio/opus' => 'opus',
      'audio/flac' || 'audio/x-flac' => 'flac',
      'audio/wav' || 'audio/x-wav' => 'wav',
      'audio/webm' => 'webm',
      'video/mp4' => 'mp4',
      _ => 'bin',
    };
  }
}

final offlineProvider = NotifierProvider<OfflineController, OfflineState>(OfflineController.new);

final isDownloadedProvider = Provider.family<bool, int>((ref, id) => ref.watch(offlineProvider).isDownloaded(id));
