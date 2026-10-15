import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../state/downloads.dart';
import '../../state/library.dart';
import '../../state/settings.dart';
import '../widgets/common.dart';
import '../widgets/download_widgets.dart';

// ---------------------------------------------------------------- Hilfen

/// "Musik" bzw. "Video".
String downloadMediaLabel(String mediaType) => mediaType == 'video' ? 'Video' : 'Musik';

IconData downloadMediaIcon(String mediaType) =>
    mediaType == 'video' ? Icons.movie_rounded : Icons.music_note_rounded;

const _youTubeHosts = {'youtube.com', 'www.youtube.com', 'm.youtube.com', 'music.youtube.com', 'youtu.be'};

/// Macht aus einer Eingabe einen gültigen YouTube-Link (ergänzt "https://"), sonst null.
String? normalizeYouTubeUrl(String input) {
  var text = input.trim();
  if (text.isEmpty) return null;
  if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(text)) text = 'https://$text';
  final uri = Uri.tryParse(text);
  if (uri == null || !_youTubeHosts.contains(uri.host.toLowerCase())) return null;
  return text;
}

/// Link zum Video auf YouTube (Musik → YouTube Music).
String youTubeLink(DownloadJob job) => job.mediaType == 'video'
    ? 'https://www.youtube.com/watch?v=${job.videoId}'
    : 'https://music.youtube.com/watch?v=${job.videoId}';

/// Laufend (lädt oder wird verarbeitet)?
bool isRunningJob(DownloadJob job) => job.status == 'downloading' || job.status == 'processing';

/// Fehlgeschlagen oder abgebrochen?
bool isFailedOrCancelledJob(DownloadJob job) => job.status == 'failed' || job.status == 'cancelled';

/// Alle Aktionen für einen Download – kommen vom Bildschirm, damit sie auch nach
/// dem Schließen eines Menüs sicher weiterlaufen.
class DownloadJobHandlers {
  final void Function(DownloadJob job) onCancel;
  final void Function(DownloadJob job) onRetry;
  final void Function(DownloadJob job) onRemove;
  final void Function(DownloadJob job) onPlay;
  final void Function(DownloadJob job) onShowInLibrary;
  final void Function(int playlistId) onOpenPlaylist;
  final void Function(DownloadJob job) onDetails;
  /// Darf der Benutzer Downloads (erneut) starten?
  final bool canRetry;

  const DownloadJobHandlers({
    required this.onCancel,
    required this.onRetry,
    required this.onRemove,
    required this.onPlay,
    required this.onShowInLibrary,
    required this.onOpenPlaylist,
    required this.onDetails,
    required this.canRetry,
  });
}

// ---------------------------------------------------------------- Kleine Bausteine

/// Kleines Etikett (z. B. "Musik", Rubrik, Benutzer).
class DownloadPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;

  const DownloadPill({super.key, required this.icon, required this.label, this.color});

  @override
  Widget build(BuildContext context) {
    final foreground = color ?? AppColors.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(color: AppColors.surfaceHighest, borderRadius: BorderRadius.circular(4)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: foreground),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: foreground),
            ),
          ),
        ],
      ),
    );
  }
}

/// Fortschrittsbalken, der weich zum neuen Wert gleitet (null = unbestimmt).
class AnimatedJobBar extends StatelessWidget {
  final double? value;
  final Color color;
  final double height;

  const AnimatedJobBar({super.key, required this.value, this.color = AppColors.accent, this.height = 4});

  @override
  Widget build(BuildContext context) {
    Widget bar(double? v) => ClipRRect(
          borderRadius: BorderRadius.circular(height),
          child: LinearProgressIndicator(
            value: v,
            minHeight: height,
            backgroundColor: AppColors.surfaceHighest,
            color: color,
          ),
        );
    final target = value;
    if (target == null) return bar(null);
    return TweenAnimationBuilder<double>(
      tween: Tween(end: target.clamp(0.0, 1.0)),
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOutCubic,
      builder: (_, v, _) => bar(v),
    );
  }
}

/// Status eines Downloads: Balken + "45 % · 1,2 MB/s · noch 12 Sek." bzw. Statuszeile/Fehler.
class DownloadJobStatus extends StatelessWidget {
  final DownloadJob job;
  /// Fehlertexte vollständig zeigen (Details).
  final bool fullError;

  const DownloadJobStatus({super.key, required this.job, this.fullError = false});

  Widget _line(IconData icon, String text, {Color color = AppColors.textSecondary, int maxLines = 1}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 14, color: color)),
        const SizedBox(width: 5),
        Expanded(
          child: Text(
            text,
            maxLines: maxLines,
            overflow: TextOverflow.ellipsis,
            style: AppText.caption.copyWith(color: color),
          ),
        ),
      ],
    );
  }

  Widget _content() {
    // Gleiche Texte wie überall in der App
    final details = JobProgress(job: job).details;
    final when = job.finishedAt ?? job.startedAt ?? job.createdAt;
    switch (job.status) {
      case 'downloading':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedJobBar(value: job.progress > 0 ? job.progress : null),
            const SizedBox(height: 5),
            Text(details, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption),
          ],
        );
      case 'processing':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const AnimatedJobBar(value: null),
            const SizedBox(height: 5),
            Text('$details (Tags und Cover)', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption),
          ],
        );
      case 'queued':
        return _line(Icons.hourglass_top_rounded, details);
      case 'done':
        return _line(
          Icons.check_circle_rounded,
          'In der Bibliothek · ${formatRelative(when)}',
          color: AppColors.accent,
        );
      case 'failed':
        return _line(Icons.error_outline_rounded, details, color: AppColors.danger, maxLines: fullError ? 12 : 2);
      case 'cancelled':
        return _line(Icons.block_rounded, 'Abgebrochen · ${formatRelative(when)}', color: AppColors.textMuted);
      default:
        return _line(Icons.info_outline_rounded, job.statusLabel);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      alignment: Alignment.topLeft,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.topLeft,
          children: [...previous, ?current],
        ),
        child: KeyedSubtree(key: ValueKey(job.status), child: _content()),
      ),
    );
  }
}

/// Überschrift eines Abschnitts mit Anzahl ("Warteschlange  3").
class DownloadSectionHeader extends StatelessWidget {
  final String title;
  final int count;
  final IconData icon;
  final Color iconColor;

  const DownloadSectionHeader({
    super.key,
    required this.title,
    required this.count,
    required this.icon,
    this.iconColor = AppColors.textSecondary,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 22, 16, 6),
      child: Row(
        children: [
          Icon(icon, size: 20, color: iconColor),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(color: AppColors.surfaceHighest, borderRadius: BorderRadius.circular(10)),
            child: Text('$count', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}

/// Schmale Hinweisleiste (z. B. "Live-Verbindung wird hergestellt …").
class DownloadsHintBar extends StatelessWidget {
  final String text;
  final bool spinner;
  final IconData icon;
  final String? actionLabel;
  final VoidCallback? onAction;

  const DownloadsHintBar({
    super.key,
    required this.text,
    this.spinner = true,
    this.icon = Icons.cloud_off_rounded,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: AppColors.surfaceHigh,
      padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
      constraints: const BoxConstraints(minHeight: 40),
      child: Row(
        children: [
          if (spinner)
            const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
          else
            Icon(icon, size: 16, color: AppColors.textSecondary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppText.caption.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          if (actionLabel != null && onAction != null)
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              child: Text(actionLabel!),
            )
          else
            const SizedBox(width: 12),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- Listeneintrag

/// Ein Download in der Liste: Vorschaubild, Titel, Künstler, Etiketten, Fortschritt, Aktionen.
class DownloadJobTile extends StatelessWidget {
  final DownloadJob job;
  final String? categoryName;
  /// Wer den Download gestartet hat (nur in der Ansicht "Alle").
  final String? ownerLabel;
  final bool busy;
  final DownloadJobHandlers handlers;

  const DownloadJobTile({
    super.key,
    required this.job,
    required this.categoryName,
    required this.ownerLabel,
    required this.busy,
    required this.handlers,
  });

  bool get _isVideo => job.mediaType == 'video';

  Widget _trailing() {
    if (busy) {
      return const SizedBox(
        key: ValueKey('busy'),
        width: 48,
        height: 48,
        child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
      );
    }
    if (job.isActive) {
      return IconButton(
        key: const ValueKey('cancel'),
        tooltip: 'Download stoppen',
        icon: const Icon(Icons.close_rounded),
        onPressed: () => handlers.onCancel(job),
      );
    }
    if (isFailedOrCancelledJob(job)) {
      if (!handlers.canRetry) {
        return IconButton(
          key: const ValueKey('remove'),
          tooltip: 'Aus der Liste entfernen',
          icon: const Icon(Icons.delete_outline_rounded),
          onPressed: () => handlers.onRemove(job),
        );
      }
      return IconButton(
        key: const ValueKey('retry'),
        tooltip: 'Erneut versuchen',
        icon: Icon(Icons.refresh_rounded, color: job.isFailed ? AppColors.danger : Colors.white),
        onPressed: () => handlers.onRetry(job),
      );
    }
    return Row(
      key: const ValueKey('done'),
      mainAxisSize: MainAxisSize.min,
      children: [
        if (job.trackId != null)
          IconButton(
            tooltip: _isVideo ? 'Video ansehen' : 'Abspielen',
            icon: const Icon(Icons.play_circle_fill_rounded, color: AppColors.accent, size: 34),
            onPressed: () => handlers.onPlay(job),
          ),
        IconButton(
          tooltip: 'Aus der Liste entfernen',
          icon: const Icon(Icons.close_rounded, color: AppColors.textSecondary),
          onPressed: () => handlers.onRemove(job),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final subtitle = [
      if (job.artistDisplay.isNotEmpty) job.artistDisplay,
      if (job.album != null && job.album!.isNotEmpty) job.album!,
    ].join(' · ');
    return InkWell(
      onTap: () => job.isDone && job.trackId != null ? handlers.onPlay(job) : handlers.onDetails(job),
      onLongPress: () => handlers.onDetails(job),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 6, 10),
        child: Row(
          children: [
            ThumbnailImage(url: job.thumbnailUrl, size: _isVideo ? 46 : 56, video: _isVideo),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(job.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.tileTitle),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.tileSubtitle),
                  ],
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      DownloadPill(icon: downloadMediaIcon(job.mediaType), label: downloadMediaLabel(job.mediaType)),
                      if (categoryName != null) DownloadPill(icon: Icons.folder_rounded, label: categoryName!),
                      if (ownerLabel != null) DownloadPill(icon: Icons.person_rounded, label: ownerLabel!),
                    ],
                  ),
                  const SizedBox(height: 8),
                  DownloadJobStatus(job: job),
                ],
              ),
            ),
            const SizedBox(width: 4),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              transitionBuilder: (child, animation) =>
                  ScaleTransition(scale: animation, child: FadeTransition(opacity: animation, child: child)),
              child: _trailing(),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- Details

/// Alle Angaben zu einem Download als Bottom Sheet – mit Live-Fortschritt und Aktionen.
Future<void> showDownloadDetails(
  BuildContext context, {
  required DownloadJob job,
  required String? categoryName,
  required DownloadJobHandlers handlers,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    builder: (sheetContext) => _DownloadDetailsSheet(
      initial: job,
      categoryName: categoryName,
      handlers: handlers,
      parentContext: context,
    ),
  );
}

class _DownloadDetailsSheet extends ConsumerWidget {
  final DownloadJob initial;
  final String? categoryName;
  final DownloadJobHandlers handlers;
  final BuildContext parentContext;

  const _DownloadDetailsSheet({
    required this.initial,
    required this.categoryName,
    required this.handlers,
    required this.parentContext,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Live-Stand, solange der Auftrag über die Live-Verbindung bekannt ist
    final job = ref.watch(downloadsProvider.select((s) => s.jobs[initial.id])) ?? initial;
    final isVideo = job.mediaType == 'video';
    final maxHeight = MediaQuery.sizeOf(context).height * 0.88;

    void act(void Function() action) {
      Navigator.of(context).pop();
      action();
    }

    Future<void> copy(String text, String done) async {
      await Clipboard.setData(ClipboardData(text: text));
      if (parentContext.mounted) showMessage(parentContext, done);
    }

    final rows = <Widget>[
      _InfoRow(label: 'Status', value: job.statusLabel),
      _InfoRow(label: 'Typ', value: downloadMediaLabel(job.mediaType)),
      _InfoRow(label: 'Rubrik', value: categoryName ?? 'Rubrik ${job.categoryId}'),
      if (job.artists.isNotEmpty) _InfoRow(label: job.artists.length > 1 ? 'Künstler' : 'Künstler/in', value: job.artistDisplay),
      if (job.album != null && job.album!.isNotEmpty) _InfoRow(label: 'Album', value: job.album!),
      if (job.status == 'downloading') ...[
        _InfoRow(
          label: 'Fortschritt',
          value: job.totalBytes != null && job.totalBytes! > 0
              ? '${formatPercent(job.progress)} · ${formatBytes(job.downloadedBytes)} von ${formatBytes(job.totalBytes)}'
              : '${formatPercent(job.progress)} · ${formatBytes(job.downloadedBytes)}',
        ),
        if (job.speed != null) _InfoRow(label: 'Tempo', value: formatSpeed(job.speed)),
        _InfoRow(label: 'Restzeit', value: formatEta(job.eta)),
      ],
      if (!job.isActive && job.totalBytes != null && job.totalBytes! > 0)
        _InfoRow(label: 'Größe', value: formatBytes(job.totalBytes)),
      if (job.status == 'queued' && job.queuePosition != null)
        _InfoRow(
          label: 'Warteschlange',
          value: job.queuePosition == 0 ? 'Als Nächstes dran' : 'Platz ${job.queuePosition! + 1}',
        ),
      if (job.user != null) _InfoRow(label: 'Gestartet von', value: job.user!.displayName),
      _InfoRow(label: 'Erstellt', value: formatDateTime(job.createdAt)),
      if (job.startedAt != null) _InfoRow(label: 'Begonnen', value: formatDateTime(job.startedAt!)),
      if (job.finishedAt != null)
        _InfoRow(label: job.isDone ? 'Fertig' : 'Beendet', value: formatDateTime(job.finishedAt!)),
      if (job.playlistId != null) const _InfoRow(label: 'Playlist', value: 'Wird automatisch hinzugefügt'),
      _InfoRow(
        label: 'Video-ID',
        value: job.videoId,
        selectable: true,
        trailing: IconButton(
          tooltip: 'Video-ID kopieren',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.copy_rounded, size: 18),
          onPressed: () => copy(job.videoId, 'Video-ID kopiert'),
        ),
      ),
    ];

    final error = job.error;
    final buttons = <Widget>[
      if (job.isDone && job.trackId != null) ...[
        FilledButton.icon(
          onPressed: () => act(() => handlers.onPlay(job)),
          icon: Icon(isVideo ? Icons.smart_display_rounded : Icons.play_arrow_rounded),
          label: Text(isVideo ? 'Video ansehen' : 'Abspielen'),
        ),
        OutlinedButton.icon(
          onPressed: () => act(() => handlers.onShowInLibrary(job)),
          icon: Icon(isVideo ? Icons.video_library_rounded : Icons.album_rounded),
          label: Text(isVideo ? 'In der Rubrik zeigen' : 'Zum Album'),
        ),
      ],
      if (job.isActive)
        OutlinedButton.icon(
          onPressed: () => act(() => handlers.onCancel(job)),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.danger,
            side: const BorderSide(color: AppColors.danger),
          ),
          icon: const Icon(Icons.stop_circle_outlined),
          label: const Text('Download stoppen'),
        ),
      if (isFailedOrCancelledJob(job) && handlers.canRetry)
        FilledButton.icon(
          onPressed: () => act(() => handlers.onRetry(job)),
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('Erneut versuchen'),
        ),
      if (job.playlistId != null)
        OutlinedButton.icon(
          onPressed: () => act(() => handlers.onOpenPlaylist(job.playlistId!)),
          icon: const Icon(Icons.queue_music_rounded),
          label: const Text('Zur Playlist'),
        ),
      OutlinedButton.icon(
        onPressed: () => copy(youTubeLink(job), 'YouTube-Link kopiert'),
        icon: const Icon(Icons.link_rounded),
        label: const Text('YouTube-Link kopieren'),
      ),
      if (!job.isActive)
        TextButton.icon(
          onPressed: () => act(() => handlers.onRemove(job)),
          style: TextButton.styleFrom(foregroundColor: AppColors.textSecondary),
          icon: const Icon(Icons.delete_outline_rounded),
          label: const Text('Aus der Liste entfernen'),
        ),
    ];

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  ThumbnailImage(url: job.thumbnailUrl, size: isVideo ? 58 : 72, radius: 6, video: isVideo),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          job.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                        ),
                        if (job.artistDisplay.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            job.artistDisplay,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.tileSubtitle,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(8)),
                child: DownloadJobStatus(job: job, fullError: true),
              ),
              if (job.isFailed && error != null && error.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.danger.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Fehlermeldung',
                        style: TextStyle(color: AppColors.danger, fontWeight: FontWeight.w700, fontSize: 13),
                      ),
                      const SizedBox(height: 4),
                      SelectableText(error, style: const TextStyle(color: AppColors.danger, fontSize: 13)),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 12),
              ...rows,
              const SizedBox(height: 16),
              for (final button in buttons) ...[button, const SizedBox(height: 8)],
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final bool selectable;
  final Widget? trailing;

  const _InfoRow({required this.label, required this.value, this.selectable = false, this.trailing});

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(fontSize: 14, color: Colors.white);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: trailing == null ? CrossAxisAlignment.start : CrossAxisAlignment.center,
        children: [
          SizedBox(width: 118, child: Text(label, style: AppText.tileSubtitle)),
          Expanded(child: selectable ? SelectableText(value, style: style) : Text(value, style: style)),
          ?trailing,
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- Link einfügen

/// Dialog "Link einfügen": YouTube-Link + Musik/Video. Liefert die gestarteten Aufträge.
Future<List<DownloadJob>?> showPasteLinkDialog(BuildContext context) {
  return showDialog<List<DownloadJob>>(context: context, builder: (_) => const _PasteLinkDialog());
}

class _PasteLinkDialog extends ConsumerStatefulWidget {
  const _PasteLinkDialog();

  @override
  ConsumerState<_PasteLinkDialog> createState() => _PasteLinkDialogState();
}

class _PasteLinkDialogState extends ConsumerState<_PasteLinkDialog> {
  final _controller = TextEditingController();
  bool _video = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _detectType(String text) {
    final url = normalizeYouTubeUrl(text);
    if (url == null) return;
    // Links von YouTube Music sind fast immer Songs
    if (Uri.parse(url).host.toLowerCase() == 'music.youtube.com' && _video) setState(() => _video = false);
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      setState(() => _error = 'In der Zwischenablage ist kein Link.');
      return;
    }
    _controller.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
    setState(() => _error = null);
    _detectType(text);
  }

  Future<void> _submit() async {
    if (_busy) return;
    final url = normalizeYouTubeUrl(_controller.text);
    if (url == null) {
      setState(() => _error = _controller.text.trim().isEmpty
          ? 'Füg zuerst einen Link ein.'
          : 'Das ist kein YouTube-Link. Erlaubt sind Links von youtube.com, music.youtube.com und youtu.be.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final jobs = await ref.read(downloadsProvider.notifier).startUrl(url, video: _video);
      if (mounted) Navigator.of(context).pop(jobs);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = errorText(e);
        });
      }
    }
  }

  /// Name der Rubrik, in der der Download landet.
  String? _targetName(List<Category> categories, AppSettings settings) {
    final wanted = _video ? settings.videoCategoryId : settings.audioCategoryId;
    final type = _video ? 'video' : 'audio';
    for (final category in categories) {
      if (category.id == wanted && category.mediaType == type) return category.name;
    }
    final candidates = categories.where((c) => c.mediaType == type).toList()
      ..sort((a, b) {
        if (a.isDefault != b.isDefault) return a.isDefault ? -1 : 1;
        return a.sortOrder.compareTo(b.sortOrder);
      });
    return candidates.firstOrNull?.name;
  }

  @override
  Widget build(BuildContext context) {
    final categories = ref.watch(categoriesProvider).value ?? const <Category>[];
    final settings = ref.watch(settingsProvider);
    final target = _targetName(categories, settings);

    return AlertDialog(
      title: const Text('Link einfügen'),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Füg einen Link von YouTube oder YouTube Music ein – ein Song, ein Video oder eine ganze Playlist.',
            style: AppText.tileSubtitle,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            enabled: !_busy,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.go,
            onChanged: (text) {
              if (_error != null) setState(() => _error = null);
              _detectType(text);
            },
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              hintText: 'https://music.youtube.com/…',
              prefixIcon: const Icon(Icons.link_rounded),
              suffixIcon: IconButton(
                tooltip: 'Aus der Zwischenablage einfügen',
                icon: const Icon(Icons.content_paste_rounded),
                onPressed: _busy ? null : _paste,
              ),
            ),
          ),
          const SizedBox(height: 18),
          const Text('Holen als', style: AppText.caption),
          const SizedBox(height: 8),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Musik'), icon: Icon(Icons.music_note_rounded)),
              ButtonSegment(value: true, label: Text('Video'), icon: Icon(Icons.movie_rounded)),
            ],
            selected: {_video},
            showSelectedIcon: false,
            expandedInsets: EdgeInsets.zero,
            onSelectionChanged: _busy ? null : (value) => setState(() => _video = value.first),
            style: SegmentedButton.styleFrom(
              selectedBackgroundColor: AppColors.accent,
              selectedForegroundColor: Colors.black,
              foregroundColor: Colors.white,
              side: const BorderSide(color: AppColors.surfaceHighest),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            _video
                ? 'Das Video wird mit Bild gespeichert${target == null ? '' : ' und landet in „$target“'}.'
                : 'Nur der Ton wird gespeichert${target == null ? '' : ' – landet in „$target“'}.',
            style: AppText.caption,
          ),
          if (_busy) ...[
            const SizedBox(height: 16),
            const Row(
              children: [
                SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 10),
                Expanded(child: Text('Link wird geprüft …', style: AppText.tileSubtitle)),
              ],
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 14),
            Text(_error!, style: const TextStyle(color: AppColors.danger, fontSize: 13)),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: const Text('Abbrechen')),
        TextButton(
          onPressed: _busy ? null : _submit,
          child: const Text('Holen', style: TextStyle(color: AppColors.accent, fontWeight: FontWeight.w700)),
        ),
      ],
    );
  }
}
