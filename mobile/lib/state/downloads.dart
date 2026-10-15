import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../data/api.dart';
import '../data/models.dart';
import 'auth.dart';
import 'library.dart';
import 'settings.dart';

/// YouTube-Downloads auf dem Server mit Live-Fortschritt (WebSocket).
class DownloadsState {
  final Map<int, DownloadJob> jobs;
  final bool connected;

  const DownloadsState({this.jobs = const {}, this.connected = false});

  /// Aktive zuerst (in Warteschlangen-Reihenfolge), danach die neuesten fertigen.
  List<DownloadJob> get sorted {
    final list = jobs.values.toList();
    int rank(DownloadJob j) => switch (j.status) {
      'downloading' || 'processing' => 0,
      'queued' => 1,
      _ => 2,
    };
    list.sort((a, b) {
      final byRank = rank(a).compareTo(rank(b));
      if (byRank != 0) return byRank;
      if (a.status == 'queued') return (a.queuePosition ?? 0).compareTo(b.queuePosition ?? 0);
      return b.createdAt.compareTo(a.createdAt);
    });
    return list;
  }

  List<DownloadJob> get active => sorted.where((j) => j.isActive).toList();

  /// Download eines YouTube-Treffers – Song und Video mit derselben ID sind getrennte Aufträge.
  DownloadJob? forVideo(String videoId, {required String mediaType}) {
    DownloadJob? best;
    for (final job in jobs.values) {
      if (job.videoId != videoId || job.mediaType != mediaType) continue;
      if (best == null || job.isActive || job.createdAt.isAfter(best.createdAt)) best = job;
    }
    return best;
  }

  DownloadsState copyWith({Map<int, DownloadJob>? jobs, bool? connected}) =>
      DownloadsState(jobs: jobs ?? this.jobs, connected: connected ?? this.connected);
}

class DownloadsController extends Notifier<DownloadsState> {
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _reconnect;
  int _attempt = 0;
  bool _disposed = false;
  final _finished = StreamController<DownloadJob>.broadcast();

  /// Zähler der lokalen Änderungen (Live-Meldung, Start, Entfernen) je Auftrag: refresh() erkennt daran,
  /// welche Einträge während der Abfrage neuer geworden sind als die Antwort des Servers.
  int _sequence = 0;
  final Map<int, int> _changed = {};

  void _touch(int id) => _changed[id] = ++_sequence;

  /// Meldet jeden Download, der gerade fertig geworden (oder fehlgeschlagen) ist.
  Stream<DownloadJob> get finished => _finished.stream;

  @override
  DownloadsState build() {
    final api = ref.watch(apiProvider);
    _disposed = false;
    // _finished bleibt offen: Riverpod behält dieses Objekt bei einem Neuaufbau (z. B. nach erneuter
    // Anmeldung) – ein geschlossener Stream würde danach keine Fertig-Meldungen mehr liefern.
    ref.onDispose(() {
      _disposed = true;
      _close();
    });
    if (api == null) return const DownloadsState();
    Future.microtask(() => _start(api));
    return const DownloadsState();
  }

  Future<void> _start(ApiClient api) async {
    await refresh();
    _connect(api);
  }

  /// Vollständige Liste vom Server (auch fertige/fehlgeschlagene).
  ///
  /// Die Antwort wird mit dem aktuellen Stand zusammengeführt: Live-Meldungen, die während der Abfrage
  /// kamen, sind neuer und bleiben; fertige Aufträge werden nicht auf „lädt“ zurückgestuft. Was während
  /// einer Verbindungspause fertig wurde, meldet sich wie eine Live-Meldung (Hinweis, Bibliothek neu laden).
  Future<void> refresh() async {
    final api = ref.read(apiProvider);
    if (api == null) return;
    final since = _sequence;
    try {
      final listed = await api.downloads(limit: 200);
      if (_disposed) return;
      bool changedMeanwhile(int id) => (_changed[id] ?? 0) > since;
      final current = state.jobs;
      final jobs = <int, DownloadJob>{
        for (final entry in current.entries)
          if (changedMeanwhile(entry.key)) entry.key: entry.value,
      };
      final finished = <DownloadJob>[];
      for (final job in listed) {
        if (changedMeanwhile(job.id)) continue;
        final previous = current[job.id];
        // Eine ältere Antwort darf einen fertigen Auftrag nicht wiederbeleben – „Erneut versuchen“ (auch
        // von einem anderen Gerät) setzt dagegen eine neue Startzeit.
        if (previous != null && !previous.isActive && job.isActive && !job.createdAt.isAfter(previous.createdAt)) {
          jobs[job.id] = previous;
          continue;
        }
        jobs[job.id] = job;
        if (previous != null && previous.isActive && !job.isActive) finished.add(job);
      }
      state = state.copyWith(jobs: jobs);
      finished.forEach(_announce);
    } catch (_) {}
  }

  void _close() {
    _reconnect?.cancel();
    _subscription?.cancel();
    _channel?.sink.close();
    _channel = null;
  }

  Future<void> _connect(ApiClient api) async {
    if (_disposed) return;
    _close();
    try {
      if (api.tokens.accessExpiringSoon) await api.refresh();
      final channel = IOWebSocketChannel.connect(
        api.downloadsWebSocketUri(),
        pingInterval: const Duration(seconds: 20),
      );
      _channel = channel;
      await channel.ready;
      _attempt = 0;
      state = state.copyWith(connected: true);
      _subscription = channel.stream.listen(
        _onMessage,
        onDone: () => _scheduleReconnect(api),
        onError: (_) => _scheduleReconnect(api),
        cancelOnError: true,
      );
    } catch (_) {
      _scheduleReconnect(api);
    }
  }

  void _scheduleReconnect(ApiClient api) {
    if (_disposed) return;
    state = state.copyWith(connected: false);
    _reconnect?.cancel();
    final seconds = [1, 2, 5, 10, 20, 30][_attempt.clamp(0, 5)];
    _attempt++;
    _reconnect = Timer(Duration(seconds: seconds), () async {
      await refresh();
      _connect(api);
    });
  }

  void _onMessage(dynamic raw) {
    if (_disposed) return;
    final event = jsonDecode(raw as String) as Json;
    switch (event['type']) {
      case 'snapshot':
        final jobs = Map<int, DownloadJob>.of(state.jobs);
        for (final j in (event['jobs'] as List)) {
          final job = DownloadJob.fromJson(j as Json);
          jobs[job.id] = job;
          _touch(job.id);
        }
        state = state.copyWith(jobs: jobs);
      case 'job':
        _upsert(DownloadJob.fromJson(event['job'] as Json));
    }
  }

  void _upsert(DownloadJob job) {
    final previous = state.jobs[job.id];
    _touch(job.id);
    state = state.copyWith(jobs: {...state.jobs, job.id: job});
    final justFinished = (previous == null || previous.isActive) && !job.isActive;
    if (justFinished) _announce(job);
  }

  /// Fertig (oder fehlgeschlagen): Hinweis auslösen und neue Titel überall sichtbar machen.
  void _announce(DownloadJob job) {
    if (!_finished.isClosed) _finished.add(job);
    if (job.isDone) {
      // Neue Titel sollen sofort in Startseite/Bibliothek/Suche auftauchen
      ref.invalidate(homeProvider);
      ref.invalidate(libraryOverviewProvider);
      ref.invalidate(categoriesProvider);
      if (job.playlistId != null) ref.invalidate(playlistProvider(job.playlistId!));
    }
  }

  ApiClient get _api {
    final api = ref.read(apiProvider);
    if (api == null) throw const ApiException('Nicht angemeldet.', statusCode: 401);
    return api;
  }

  /// Gewählte Ziel-Rubrik – gibt es sie nicht mehr, nimmt der Server seine Standard-Rubrik.
  Future<int?> _categoryFor(bool video) async {
    final settings = ref.read(settingsProvider);
    final id = video ? settings.videoCategoryId : settings.audioCategoryId;
    if (id == null) return null;
    List<Category> categories;
    try {
      categories = await ref.read(categoriesProvider.future);
    } catch (_) {
      return id; // Liste gerade nicht ladbar: Auswahl unverändert schicken
    }
    final mediaType = video ? 'video' : 'audio';
    if (categories.any((c) => c.id == id && c.mediaType == mediaType)) return id;
    // Rubrik wurde gelöscht: Einstellung zurücksetzen, sonst schlägt jeder Download fehl
    await ref
        .read(settingsProvider.notifier)
        .update((s) => video ? s.copyWith(videoCategoryId: () => null) : s.copyWith(audioCategoryId: () => null));
    return null;
  }

  /// Song oder Video aus der YouTube-Suche holen.
  Future<DownloadJob> startItem(YouTubeItem item, {int? categoryId, int? playlistId}) async {
    final job = await _api.downloadItem(
      item,
      categoryId: categoryId ?? await _categoryFor(item.isVideo),
      playlistId: playlistId,
    );
    _upsert(job);
    return job;
  }

  Future<List<DownloadJob>> startAlbum(String browseId, {int? categoryId, int? playlistId}) async {
    final jobs = await _api.downloadAlbum(
      browseId,
      categoryId: categoryId ?? await _categoryFor(false),
      playlistId: playlistId,
    );
    jobs.forEach(_upsert);
    return jobs;
  }

  Future<List<DownloadJob>> startUrl(String url, {bool video = false, int? categoryId, int? playlistId}) async {
    final jobs = await _api.downloadUrl(
      url,
      mediaType: video ? 'video' : 'audio',
      categoryId: categoryId ?? await _categoryFor(video),
      playlistId: playlistId,
    );
    jobs.forEach(_upsert);
    return jobs;
  }

  Future<void> cancel(int id) async => _upsert(await _api.cancelDownload(id));
  Future<void> retry(int id) async => _upsert(await _api.retryDownload(id));

  Future<void> remove(int id) async {
    await _api.removeDownload(id);
    _touch(id);
    state = state.copyWith(jobs: Map.of(state.jobs)..remove(id));
  }

  Future<void> clearFinished() async {
    await _api.clearFinishedDownloads();
    final jobs = Map.of(state.jobs);
    for (final job in jobs.values.where((j) => !j.isActive)) {
      _touch(job.id);
    }
    state = state.copyWith(jobs: jobs..removeWhere((_, j) => !j.isActive));
  }
}

final downloadsProvider = NotifierProvider<DownloadsController, DownloadsState>(DownloadsController.new);

final activeDownloadCountProvider = Provider<int>((ref) => ref.watch(downloadsProvider).active.length);

/// Laufender/letzter Download für eine YouTube-ID (für Fortschrittsbalken in Suchergebnissen).
/// Download zu einem YouTube-Treffer: Schlüssel ist (YouTube-ID, 'audio' oder 'video').
final jobForVideoProvider = Provider.family<DownloadJob?, (String, String)>(
  (ref, key) => ref.watch(downloadsProvider).forVideo(key.$1, mediaType: key.$2),
);
