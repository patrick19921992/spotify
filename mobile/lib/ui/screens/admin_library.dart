import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../state/auth.dart';
import '../../state/library.dart';
import '../widgets/common.dart';
import 'admin_categories.dart';
import 'admin_widgets.dart';

// Verwaltung › Bibliothek: Statistik und Einlesen der Ordner.

/// Statistik der Bibliothek inkl. Scan-Status.
final adminLibraryStatsProvider = FutureProvider.autoDispose<LibraryStats>((ref) => requireApi(ref).libraryStats());

String _scanSummary(ScanStatus scan) {
  final parts = [
    if (scan.added > 0) '${formatCount(scan.added)} neu',
    if (scan.updated > 0) '${formatCount(scan.updated)} aktualisiert',
    if (scan.removed > 0) '${formatCount(scan.removed)} entfernt',
    if (scan.errors > 0) '${formatCount(scan.errors)} mit Fehlern',
  ];
  return parts.isEmpty ? 'Einlesen fertig – keine Änderungen.' : 'Einlesen fertig: ${parts.join(', ')}.';
}

String _filesLabel(int count) => count == 1 ? '1 Datei' : '${formatCount(count)} Dateien';

/// Tab „Bibliothek“.
class AdminLibraryTab extends ConsumerStatefulWidget {
  const AdminLibraryTab({super.key});

  @override
  ConsumerState<AdminLibraryTab> createState() => _AdminLibraryTabState();
}

class _AdminLibraryTabState extends ConsumerState<AdminLibraryTab> with AutomaticKeepAliveClientMixin {
  static const _pollInterval = Duration(seconds: 2);

  Timer? _timer;
  bool _polling = false;
  bool _starting = false;

  /// Aktueller Scan-Status aus der Abfrage alle 2 Sekunden (vorrangig vor der Statistik).
  ScanStatus? _live;

  /// Wurde während der Beobachtung ein laufender Scan gesehen?
  bool _sawRunning = false;

  /// Ende des vorigen Scans – ändert es sich, ist der neue Scan fertig.
  DateTime? _baselineFinished;

  /// So lange auf den Start eines angeforderten Scans warten.
  DateTime? _waitUntil;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    ref.listenManual<AsyncValue<LibraryStats>>(adminLibraryStatsProvider, _onStats, fireImmediately: true);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _onStats(AsyncValue<LibraryStats>? previous, AsyncValue<LibraryStats> next) {
    final stats = next.value;
    if (stats == null || next.isLoading) return;
    if (_timer == null && _live != null && mounted) setState(() => _live = null);
    if (stats.scan.running && _timer == null) {
      // Scan läuft schon (automatisch oder von einem anderen Gerät) -> mitverfolgen
      _sawRunning = true;
      _baselineFinished = stats.scan.finishedAt;
      _waitUntil = null;
      _startPolling();
    }
  }

  void _startPolling() {
    _timer ??= Timer.periodic(_pollInterval, (_) => _poll());
  }

  void _stopPolling() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _poll() async {
    if (_polling) return;
    final api = ref.read(apiProvider);
    if (api == null) {
      _stopPolling();
      return;
    }
    _polling = true;
    try {
      final status = await api.scanStatus();
      if (!mounted || _timer == null) return;
      if (status.running) {
        _sawRunning = true;
        setState(() => _live = status);
        return;
      }
      final finishedNew = status.finishedAt != null && status.finishedAt != _baselineFinished;
      if (_sawRunning || finishedNew) {
        _stopPolling();
        setState(() => _live = status);
        _onFinished(status);
      } else if (_waitUntil == null || DateTime.now().isAfter(_waitUntil!)) {
        // Der Scan ist nicht angelaufen (z. B. schon erledigt) – nicht ewig weiterfragen
        _stopPolling();
        setState(() => _live = status);
      }
    } catch (_) {
      // Server kurz nicht erreichbar – beim nächsten Durchlauf erneut versuchen
    } finally {
      _polling = false;
    }
  }

  void _onFinished(ScanStatus status) {
    ref.invalidate(adminLibraryStatsProvider);
    ref.invalidate(homeProvider);
    ref.invalidate(categoriesProvider);
    ref.invalidate(libraryOverviewProvider);
    showMessage(context, _scanSummary(status));
  }

  Future<void> _startScan({Category? category}) async {
    final api = ref.read(apiProvider);
    if (api == null || _starting) return;
    final before = _live ?? ref.read(adminLibraryStatsProvider).value?.scan;
    setState(() => _starting = true);
    try {
      final status = await api.startScan(categoryId: category?.id);
      if (!mounted) return;
      _baselineFinished = before?.finishedAt;
      _sawRunning = status.running;
      _waitUntil = DateTime.now().add(const Duration(seconds: 12));
      setState(() {
        _starting = false;
        _live = status;
      });
      showMessage(
        context,
        category == null ? 'Die Bibliothek wird neu eingelesen …' : '„${category.name}“ wird neu eingelesen …',
      );
      _startPolling();
    } catch (e) {
      if (!mounted) return;
      setState(() => _starting = false);
      showError(context, e);
    }
  }

  Future<void> _scanCategory() async {
    final category = await pickAdminCategory(
      context,
      title: 'Welche Rubrik einlesen?',
      subtitle: 'Nur der Ordner dieser Rubrik wird neu eingelesen.',
    );
    if (category != null && mounted) await _startScan(category: category);
  }

  Future<void> _refresh() => adminQuietly(ref.refresh(adminLibraryStatsProvider.future));

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final value = ref.watch(adminLibraryStatsProvider);
    return AsyncBody<LibraryStats>(
      value: value,
      onRetry: () => ref.invalidate(adminLibraryStatsProvider),
      builder: (stats) {
        final scan = _live ?? stats.scan;
        final busy = _starting || scan.running;
        return RefreshIndicator(
          color: AppColors.accent,
          onRefresh: _refresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: adminListPadding(context, top: 8),
            children: [
              const AdminSectionLabel('Deine Bibliothek'),
              _StatsGrid(stats: stats),
              const AdminSectionLabel('Einlesen'),
              _ScanCard(scan: scan),
              const SizedBox(height: 16),
              AdminPrimaryButton(
                label: scan.running ? 'Wird gerade eingelesen …' : 'Jetzt neu einlesen',
                icon: Icons.refresh_rounded,
                busy: busy,
                onPressed: () => _startScan(),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: busy ? null : _scanCategory,
                style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14)),
                icon: const Icon(Icons.folder_open_rounded, size: 20),
                label: const Text('Nur eine Rubrik einlesen …', style: TextStyle(fontWeight: FontWeight.w700)),
              ),
              const SizedBox(height: 16),
              const Text(
                'Neue, geänderte und gelöschte Dateien erkennt der Server von selbst – nach wenigen Sekunden '
                'und zur Sicherheit alle 30 Minuten. Neu einlesen musst du nur, wenn etwas fehlt.',
                style: AppText.caption,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _StatsGrid extends StatelessWidget {
  final LibraryStats stats;
  const _StatsGrid({required this.stats});

  @override
  Widget build(BuildContext context) {
    final tiles = [
      _StatTile(icon: Icons.music_note_rounded, label: 'Titel', value: formatCount(stats.tracks)),
      _StatTile(icon: Icons.movie_rounded, label: 'Videos', value: formatCount(stats.videos), color: adminVideoColor),
      _StatTile(icon: Icons.person_rounded, label: 'Künstler', value: formatCount(stats.artists)),
      _StatTile(icon: Icons.album_rounded, label: 'Alben', value: formatCount(stats.albums)),
      _StatTile(icon: Icons.schedule_rounded, label: 'Gesamtdauer', value: formatLongDuration(stats.totalDuration)),
      _StatTile(icon: Icons.sd_storage_rounded, label: 'Speicher', value: formatBytes(stats.totalSize)),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = 12.0;
        final columns = constraints.maxWidth >= 560 ? 3 : 2;
        final width = (constraints.maxWidth - spacing * (columns - 1)) / columns;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [for (final tile in tiles) SizedBox(width: width, child: tile)],
        );
      },
    );
  }
}

class _StatTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _StatTile({required this.icon, required this.label, required this.value, this.color = AppColors.accent});

  @override
  Widget build(BuildContext context) {
    return AdminCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(height: 12),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value, maxLines: 1, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
          ),
          const SizedBox(height: 2),
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption),
        ],
      ),
    );
  }
}

class _ScanCard extends StatelessWidget {
  final ScanStatus scan;
  const _ScanCard({required this.scan});

  @override
  Widget build(BuildContext context) {
    final started = scan.startedAt;
    final finished = scan.finishedAt;
    final children = <Widget>[];

    if (scan.running) {
      children.addAll([
        Row(
          children: [
            const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                'Wird eingelesen … ${_filesLabel(scan.filesSeen)}',
                style: AppText.tileTitle.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        if (started != null) ...[
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(left: 36),
            child: Text('Gestartet ${formatRelative(started)}', style: AppText.caption),
          ),
        ],
        const SizedBox(height: 14),
        const ClipRRect(
          borderRadius: BorderRadius.all(Radius.circular(2)),
          child: LinearProgressIndicator(minHeight: 3, backgroundColor: AppColors.surfaceHighest),
        ),
        if (scan.added + scan.updated + scan.removed + scan.errors > 0) ...[
          const SizedBox(height: 16),
          _ScanCounters(scan: scan),
        ],
      ]);
    } else if (finished != null) {
      final hasErrors = scan.errors > 0 || scan.lastError != null;
      final duration = started == null ? null : finished.difference(started);
      children.addAll([
        Row(
          children: [
            Icon(
              hasErrors ? Icons.warning_amber_rounded : Icons.check_circle_rounded,
              color: hasErrors ? adminWarningColor : AppColors.accent,
              size: 24,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Zuletzt eingelesen', style: AppText.tileTitle.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(
                    [
                      formatDateTime(finished),
                      if (duration != null && !duration.isNegative) 'Dauer ${formatLongDuration(duration.inSeconds)}',
                      '${_filesLabel(scan.filesSeen)} geprüft',
                    ].join(' · '),
                    style: AppText.caption,
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _ScanCounters(scan: scan),
      ]);
    } else {
      children.add(
        const Row(
          children: [
            Icon(Icons.info_outline_rounded, color: AppColors.textSecondary, size: 24),
            SizedBox(width: 12),
            Expanded(child: Text('Seit dem Serverstart wurde noch nicht eingelesen.', style: AppText.tileSubtitle)),
          ],
        ),
      );
    }

    final lastError = scan.lastError;
    if (lastError != null && lastError.trim().isNotEmpty) {
      children.addAll([const SizedBox(height: 14), AdminNotice(lastError)]);
    }
    if (scan.errorFiles.isNotEmpty) {
      children.addAll([const SizedBox(height: 8), _ErrorFiles(files: scan.errorFiles)]);
    }

    return AdminCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    );
  }
}

class _ScanCounters extends StatelessWidget {
  final ScanStatus scan;
  const _ScanCounters({required this.scan});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _Counter(value: scan.added, label: 'Neu', color: AppColors.accent),
        _Counter(value: scan.updated, label: 'Aktualisiert'),
        _Counter(value: scan.removed, label: 'Entfernt'),
        _Counter(value: scan.errors, label: 'Fehler', color: scan.errors > 0 ? AppColors.danger : null),
      ],
    );
  }
}

class _Counter extends StatelessWidget {
  final int value;
  final String label;
  final Color? color;

  const _Counter({required this.value, required this.label, this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              formatCount(value),
              maxLines: 1,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: value > 0 ? (color ?? Colors.white) : AppColors.textMuted,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption),
        ],
      ),
    );
  }
}

class _ErrorFiles extends StatelessWidget {
  final List<String> files;
  const _ErrorFiles({required this.files});

  static const _maxShown = 200;

  @override
  Widget build(BuildContext context) {
    final shown = files.take(_maxShown).toList();
    // Eigenes Material: die Karte darunter hat eine Hintergrundfarbe, sonst wäre der Tipp-Effekt unsichtbar
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: Material(
        type: MaterialType.transparency,
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 4),
          expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
          iconColor: AppColors.textSecondary,
          collapsedIconColor: AppColors.textSecondary,
          leading: const Icon(Icons.description_outlined, color: AppColors.danger),
          title: Text(
            files.length == 1
                ? '1 Datei konnte nicht gelesen werden'
                : '${formatCount(files.length)} Dateien konnten nicht gelesen werden',
            style: AppText.tileTitle,
          ),
          subtitle: const Text('Antippen für die Liste', style: AppText.caption),
          children: [
            for (final file in shown)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: SelectableText(file, style: adminMonospace),
              ),
            if (files.length > shown.length)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('… und ${formatCount(files.length - shown.length)} weitere', style: AppText.caption),
              ),
          ],
        ),
      ),
    );
  }
}
