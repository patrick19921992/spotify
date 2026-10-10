import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../data/api.dart';
import '../data/models.dart';
import 'auth.dart';
import 'connectivity.dart';
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

  @override
  OfflineState build() {
    Future.microtask(_load);
    ref.listen(connectivityProvider, (_, _) => _pump());
    return const OfflineState();
  }

  Future<Directory> _directory() async {
    final existing = _dir;
    if (existing != null) return existing;
    final base = await getApplicationDocumentsDirectory();
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
      state = state.copyWith(tracks: tracks, collections: collections, collectionNames: names, loaded: true);
    } catch (_) {
      state = state.copyWith(loaded: true);
    }
  }

  Future<void> _save() async {
    final dir = await _directory();
    final file = _indexFile(dir);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode({
      'tracks': {for (final t in state.tracks.values) '${t.track.id}': t.toJson()},
      'collections': state.collections,
      'names': state.collectionNames,
    }));
    await tmp.rename(file.path);
  }

  /// Pfad der Datei auf dem Handy – oder null, wenn nicht heruntergeladen.
  String? localPath(int trackId) {
    final item = state.tracks[trackId];
    final dir = _dir;
    if (item == null || dir == null) return null;
    return '${dir.path}/${item.fileName}';
  }

  /// Einzelne Titel herunterladen.
  void downloadTracks(List<Track> tracks) {
    final pending = [...state.pending];
    for (final track in tracks) {
      if (track.isVideo || state.tracks.containsKey(track.id) || pending.contains(track.id)) continue;
      _queued[track.id] = track;
      pending.add(track.id);
    }
    state = state.copyWith(pending: pending, lastError: () => null);
    _pump();
  }

  /// Album/Playlist/Lieblingssongs offline verfügbar halten.
  Future<void> keepCollection(String key, String name, List<Track> tracks) async {
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
    if (!state.collections.containsKey(key)) return;
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
      while (state.pending.isNotEmpty && _networkAllowed) {
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
