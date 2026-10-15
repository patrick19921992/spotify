import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import '../../data/models.dart';
import '../../player/player.dart';
import '../../state/auth.dart';
import '../../state/connectivity.dart';
import '../../state/downloads.dart';
import '../../state/library.dart';
import '../nav.dart';
import '../widgets/common.dart';
import '../widgets/mini_player.dart';
import 'downloads_widgets.dart';

/// YouTube-Downloads auf dem Server – mit Live-Fortschritt.
/// Admins können zwischen den eigenen und allen Downloads der Familie umschalten.
class DownloadsScreen extends ConsumerStatefulWidget {
  const DownloadsScreen({super.key});

  @override
  ConsumerState<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends ConsumerState<DownloadsScreen> {
  static const _pollInterval = Duration(seconds: 3);

  /// Ansicht "Alle" (nur Admins).
  bool _showAll = false;
  Timer? _poll;
  List<DownloadJob>? _allJobs;
  Object? _allError;
  Future<void>? _allRequest;

  /// Erste Liste vom Server ist da (vorher Ladeanzeige statt "Noch keine Downloads").
  bool _loaded = false;

  /// Wenn ein Auftrag die Warteschlange verlässt, rücken alle anderen auf –
  /// die Plätze kommen dann frisch vom Server.
  Timer? _queueRefresh;

  /// Aufträge, für die gerade eine Aktion läuft.
  final Set<int> _busy = {};

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      await ref.read(downloadsProvider.notifier).refresh();
      if (mounted) setState(() => _loaded = true);
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _queueRefresh?.cancel();
    super.dispose();
  }

  // ---------------------------------------------------------------- Laden

  void _setShowAll(bool all) {
    if (all == _showAll) return;
    setState(() => _showAll = all);
    _poll?.cancel();
    _poll = null;
    if (all) {
      _loadAll();
      _poll = Timer.periodic(_pollInterval, (_) => _tick());
    }
  }

  void _tick() {
    // Im Hintergrund nicht ständig beim Server nachfragen
    if (!mounted) return;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
    // Liegt eine andere Seite darüber (z. B. ein Album), reicht der nächste Takt danach.
    // Offene Details bleiben trotzdem live – sie hängen an der Live-Verbindung.
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;
    _loadAll();
  }

  /// Alle Downloads aller Benutzer (nur Admins). Läuft schon eine Abfrage, wird auf diese gewartet.
  Future<void> _loadAll() => _allRequest ??= _fetchAll().whenComplete(() => _allRequest = null);

  Future<void> _fetchAll() async {
    final api = ref.read(apiProvider);
    if (api == null) return;
    try {
      final jobs = await api.downloads(scope: 'all', limit: 200);
      if (!mounted || !_showAll) return;
      setState(() {
        _allJobs = jobs;
        _allError = null;
      });
    } catch (e) {
      if (!mounted || !_showAll) return;
      setState(() => _allError = e);
    }
  }

  Future<void> _refresh() async {
    if (ref.read(categoriesProvider).hasError) ref.invalidate(categoriesProvider);
    await Future.wait([
      ref.read(downloadsProvider.notifier).refresh(),
      if (_showAll) _loadAll(),
    ]);
  }

  void _onJobsChanged(DownloadsState? previous, DownloadsState next) {
    if (previous == null) return;
    final leftQueue = previous.jobs.values.any((job) {
      if (job.status != 'queued') return false;
      final now = next.jobs[job.id];
      return now != null && now.status != 'queued';
    });
    if (!leftQueue || !next.jobs.values.any((job) => job.status == 'queued')) return;
    _queueRefresh?.cancel();
    _queueRefresh = Timer(const Duration(milliseconds: 700), () {
      if (mounted) ref.read(downloadsProvider.notifier).refresh();
    });
  }

  // ---------------------------------------------------------------- Listen

  /// Eigene Aufträge. Admins bekommen über die Live-Verbindung auch fremde – die gehören nach "Alle".
  List<DownloadJob> _mine(DownloadsState state, User? user) {
    final jobs = state.jobs.values;
    if (user == null || !user.isAdmin) return jobs.toList();
    return jobs.where((job) => job.user == null || job.user!.id == user.id).toList();
  }

  /// Abgefragte Liste aller Benutzer, ergänzt um den Live-Stand.
  List<DownloadJob> _everyone(DownloadsState state) {
    final byId = <int, DownloadJob>{for (final job in _allJobs ?? const <DownloadJob>[]) job.id: job};
    for (final job in state.jobs.values) {
      // Live-Werte sind aktueller – solange die Verbindung steht
      if (!byId.containsKey(job.id) || state.connected) byId[job.id] = job;
    }
    return byId.values.toList();
  }

  static int _byStart(DownloadJob a, DownloadJob b) =>
      (a.startedAt ?? a.createdAt).compareTo(b.startedAt ?? b.createdAt);

  static int _byQueue(DownloadJob a, DownloadJob b) {
    final byPosition = (a.queuePosition ?? 1 << 30).compareTo(b.queuePosition ?? 1 << 30);
    if (byPosition != 0) return byPosition;
    final byCreated = a.createdAt.compareTo(b.createdAt);
    return byCreated != 0 ? byCreated : a.id.compareTo(b.id);
  }

  static int _byFinished(DownloadJob a, DownloadJob b) {
    final byTime = (b.finishedAt ?? b.createdAt).compareTo(a.finishedAt ?? a.createdAt);
    return byTime != 0 ? byTime : b.id.compareTo(a.id);
  }

  // ---------------------------------------------------------------- Aktionen

  Future<void> _run(DownloadJob job, Future<void> Function() action) async {
    if (_busy.contains(job.id)) return;
    setState(() => _busy.add(job.id));
    try {
      await action();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy.remove(job.id));
    }
  }

  void _replaceInAll(DownloadJob job) {
    final all = _allJobs;
    if (all == null) return;
    setState(() => _allJobs = [for (final j in all) j.id == job.id ? job : j]);
  }

  Future<void> _cancel(DownloadJob job) async {
    final queued = job.status == 'queued';
    final ok = await confirm(
      context,
      title: queued ? 'Aus der Warteschlange nehmen?' : 'Download stoppen?',
      message: queued
          ? '„${job.title}“ wird nicht geladen. Du kannst es später erneut versuchen.'
          : '„${job.title}“ wird nicht weiter geladen. Du kannst es später erneut versuchen.',
      confirmLabel: 'Stoppen',
      danger: true,
    );
    if (!ok || !mounted) return;
    await _run(job, () async {
      await ref.read(downloadsProvider.notifier).cancel(job.id);
      final updated = ref.read(downloadsProvider).jobs[job.id];
      if (updated != null) _replaceInAll(updated);
      if (_showAll) unawaited(_loadAll());
    });
  }

  Future<void> _retry(DownloadJob job) async {
    await _run(job, () async {
      await ref.read(downloadsProvider.notifier).retry(job.id);
      final updated = ref.read(downloadsProvider).jobs[job.id];
      if (updated != null) _replaceInAll(updated);
      if (mounted) showMessage(context, '„${job.title}“ wird erneut geladen');
      if (_showAll) unawaited(_loadAll());
    });
  }

  Future<void> _remove(DownloadJob job) async {
    await _run(job, () async {
      await ref.read(downloadsProvider.notifier).remove(job.id);
      final all = _allJobs;
      if (all != null && mounted) setState(() => _allJobs = all.where((j) => j.id != job.id).toList());
      if (!mounted) return;
      showMessage(
        context,
        job.isDone ? 'Aus der Liste entfernt – der Titel bleibt in der Bibliothek' : 'Aus der Liste entfernt',
      );
    });
  }

  Future<void> _play(DownloadJob job) async {
    final trackId = job.trackId;
    if (trackId == null) return;
    await _run(job, () async {
      final track = await ref.read(apiProvider)!.track(trackId);
      if (!mounted) return;
      if (track.isVideo) {
        ref.read(audioHandlerProvider).pause();
        Nav.video(context, track);
        return;
      }
      final album = track.album;
      final playContext = album != null
          ? PlayContext('album', id: album.id, title: album.title)
          : PlayContext('category', id: track.categoryId);
      try {
        await ref.read(playerProvider).playOne(track, context: playContext);
      } on StateError catch (e) {
        if (mounted) showMessage(context, e.message);
      }
    });
  }

  Future<void> _showInLibrary(DownloadJob job) async {
    if (job.mediaType == 'video') {
      Nav.category(context, job.categoryId);
      return;
    }
    final trackId = job.trackId;
    if (trackId == null) {
      Nav.category(context, job.categoryId);
      return;
    }
    await _run(job, () async {
      final track = await ref.read(apiProvider)!.track(trackId);
      if (!mounted) return;
      final album = track.album;
      if (album != null) {
        Nav.album(context, album.id);
      } else {
        Nav.category(context, track.categoryId);
      }
    });
  }

  Future<void> _pasteLink() async {
    final jobs = await showPasteLinkDialog(context);
    if (jobs == null || !mounted) return;
    if (_showAll) unawaited(_loadAll());
    if (jobs.isEmpty) {
      showMessage(context, 'Unter diesem Link wurde nichts gefunden');
      return;
    }
    if (jobs.length == 1) {
      final job = jobs.first;
      showMessage(context, job.isDone ? '„${job.title}“ ist schon in deiner Bibliothek' : '„${job.title}“ wird geholt');
      return;
    }
    final fresh = jobs.where((job) => !job.isDone).length;
    final total = jobs.length;
    showMessage(
      context,
      fresh == total
          ? '$total Titel werden geholt'
          : fresh == 0
              ? 'Alle $total Titel sind schon in deiner Bibliothek'
              : '$fresh Titel werden geholt, ${total - fresh} sind schon da',
    );
  }

  Future<void> _clearFinished() async {
    try {
      await ref.read(downloadsProvider.notifier).clearFinished();
      if (_showAll) await _loadAll();
      if (mounted) showMessage(context, 'Fertige Downloads aus der Liste entfernt');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  // ---------------------------------------------------------------- Oberfläche

  @override
  Widget build(BuildContext context) {
    ref.listen(downloadsProvider, _onJobsChanged);

    final state = ref.watch(downloadsProvider);
    final user = ref.watch(currentUserProvider);
    final isAdmin = user?.isAdmin ?? false;
    final canDownload = user?.canDownload ?? false;
    final noNetwork = ref.watch(isOfflineProvider);
    final categories = ref.watch(categoriesProvider).value ?? const <Category>[];
    final categoryNames = {for (final category in categories) category.id: category.name};
    final showAll = isAdmin && _showAll;

    final mine = _mine(state, user);
    final jobs = showAll ? _everyone(state) : mine;
    final hasOwnFinished = mine.any((job) => !job.isActive);

    late final DownloadJobHandlers handlers;
    handlers = DownloadJobHandlers(
      onCancel: _cancel,
      onRetry: _retry,
      onRemove: _remove,
      onPlay: _play,
      onShowInLibrary: _showInLibrary,
      onOpenPlaylist: (id) => Nav.playlist(context, id),
      onDetails: (job) => showDownloadDetails(
        context,
        job: job,
        categoryName: categoryNames[job.categoryId],
        handlers: handlers,
      ),
      canRetry: canDownload,
    );

    Widget? hint;
    if (noNetwork) {
      hint = const DownloadsHintBar(
        key: ValueKey('offline'),
        text: 'Keine Internetverbindung – der Stand wird aktualisiert, sobald du wieder online bist.',
        spinner: false,
      );
    } else if (!state.connected) {
      hint = const DownloadsHintBar(key: ValueKey('connecting'), text: 'Live-Verbindung wird hergestellt …');
    } else if (showAll && _allError != null && _allJobs != null) {
      hint = DownloadsHintBar(
        key: const ValueKey('poll-error'),
        text: 'Liste konnte nicht aktualisiert werden',
        spinner: false,
        icon: Icons.sync_problem_rounded,
        actionLabel: 'Erneut',
        onAction: _loadAll,
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Downloads'),
        actions: [
          if (canDownload)
            IconButton(
              tooltip: 'Link einfügen',
              icon: const Icon(Icons.add_link_rounded),
              onPressed: noNetwork ? null : _pasteLink,
            ),
          PopupMenuButton<String>(
            tooltip: 'Mehr',
            icon: const Icon(Icons.more_vert_rounded),
            color: AppColors.surfaceHigh,
            onSelected: (value) {
              switch (value) {
                case 'clear':
                  _clearFinished();
                case 'refresh':
                  _refresh();
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'clear',
                enabled: hasOwnFinished,
                child: _MenuRow(
                  icon: Icons.clear_all_rounded,
                  label: showAll ? 'Meine fertigen aus der Liste entfernen' : 'Fertige aus der Liste entfernen',
                ),
              ),
              const PopupMenuItem(
                value: 'refresh',
                child: _MenuRow(icon: Icons.refresh_rounded, label: 'Aktualisieren'),
              ),
            ],
          ),
        ],
        bottom: isAdmin
            ? PreferredSize(
                preferredSize: const Size.fromHeight(56),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 2, 16, 12),
                  child: SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('Meine'), icon: Icon(Icons.person_rounded)),
                      ButtonSegment(value: true, label: Text('Alle'), icon: Icon(Icons.groups_rounded)),
                    ],
                    selected: {_showAll},
                    showSelectedIcon: false,
                    expandedInsets: EdgeInsets.zero,
                    onSelectionChanged: (value) => _setShowAll(value.first),
                    style: SegmentedButton.styleFrom(
                      selectedBackgroundColor: AppColors.accent,
                      selectedForegroundColor: Colors.black,
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: AppColors.surfaceHighest),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ),
              )
            : null,
      ),
      bottomNavigationBar: const SafeArea(top: false, child: MiniPlayer()),
      body: Column(
        children: [
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: hint ?? const SizedBox(key: ValueKey('none'), width: double.infinity),
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              color: AppColors.accent,
              onRefresh: _refresh,
              child: _body(
                jobs: jobs,
                showAll: showAll,
                user: user,
                canDownload: canDownload,
                noNetwork: noNetwork,
                categoryNames: categoryNames,
                handlers: handlers,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body({
    required List<DownloadJob> jobs,
    required bool showAll,
    required User? user,
    required bool canDownload,
    required bool noNetwork,
    required Map<int, String> categoryNames,
    required DownloadJobHandlers handlers,
  }) {
    if (showAll && _allJobs == null) {
      final error = _allError;
      if (error != null) return _Fill(child: ErrorView(message: errorText(error), onRetry: _loadAll));
      return const _Fill(child: CircularProgressIndicator());
    }
    if (jobs.isEmpty) {
      if (!showAll && !_loaded) return const _Fill(child: CircularProgressIndicator());
      return _Fill(child: _empty(showAll: showAll, canDownload: canDownload, noNetwork: noNetwork));
    }

    final running = jobs.where(isRunningJob).toList()..sort(_byStart);
    final queued = jobs.where((job) => job.status == 'queued').toList()..sort(_byQueue);
    final done = jobs.where((job) => job.isDone).toList()..sort(_byFinished);
    final failed = jobs.where(isFailedOrCancelledJob).toList()..sort(_byFinished);

    String? owner(DownloadJob job) {
      if (!showAll) return null;
      final jobUser = job.user;
      if (jobUser == null) return 'Unbekannt';
      return jobUser.displayName.isEmpty ? 'Benutzer ${jobUser.id}' : jobUser.displayName;
    }

    List<Widget> section(String title, IconData icon, Color color, List<DownloadJob> list) {
      if (list.isEmpty) return const [];
      return [
        SliverToBoxAdapter(
          child: DownloadSectionHeader(title: title, count: list.length, icon: icon, iconColor: color),
        ),
        SliverList.builder(
          itemCount: list.length,
          itemBuilder: (context, index) {
            final job = list[index];
            return DownloadJobTile(
              key: ValueKey(job.id),
              job: job,
              categoryName: categoryNames[job.categoryId],
              ownerLabel: owner(job),
              busy: _busy.contains(job.id),
              handlers: handlers,
            );
          },
        ),
      ];
    }

    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        ...section('Läuft gerade', Icons.downloading_rounded, AppColors.accent, running),
        ...section('Warteschlange', Icons.hourglass_top_rounded, AppColors.textSecondary, queued),
        ...section('Fertig', Icons.check_circle_rounded, AppColors.accent, done),
        ...section('Fehlgeschlagen', Icons.error_outline_rounded, AppColors.danger, failed),
        const SliverPadding(padding: EdgeInsets.only(bottom: 32)),
      ],
    );
  }

  Widget _empty({required bool showAll, required bool canDownload, required bool noNetwork}) {
    if (noNetwork) {
      return const EmptyState(
        icon: Icons.cloud_off_rounded,
        title: 'Keine Verbindung',
        message: 'Downloads laufen auf deinem Server. Sobald du wieder online bist, siehst du sie hier.',
      );
    }
    if (showAll) {
      return const EmptyState(
        icon: Icons.download_rounded,
        title: 'Noch keine Downloads',
        message: 'Bisher hat noch niemand in der Familie etwas von YouTube geholt.',
      );
    }
    if (!canDownload) {
      return const EmptyState(
        icon: Icons.lock_outline_rounded,
        title: 'Noch keine Downloads',
        message: 'Downloads von YouTube sind für dein Konto nicht freigeschaltet. Frag einen Admin, ob er sie für dich aktiviert.',
      );
    }
    return EmptyState(
      icon: Icons.download_rounded,
      title: 'Noch keine Downloads',
      message: 'Such einen Song und tippe auf „Holen“ – er landet dann automatisch in deiner Bibliothek.',
      action: FilledButton.icon(
        onPressed: () => context.go('/search'),
        icon: const Icon(Icons.search_rounded),
        label: const Text('Zur Suche'),
      ),
    );
  }
}

/// Füllt den sichtbaren Bereich und bleibt scrollbar (damit "Zum Aktualisieren ziehen" funktioniert).
class _Fill extends StatelessWidget {
  final Widget child;
  const _Fill({required this.child});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight, minWidth: constraints.maxWidth),
          child: Center(child: child),
        ),
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  final IconData icon;
  final String label;
  const _MenuRow({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 12),
        Flexible(child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis)),
      ],
    );
  }
}
