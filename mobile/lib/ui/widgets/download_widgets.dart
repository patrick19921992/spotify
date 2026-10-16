import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../player/player.dart';
import '../../state/auth.dart';
import '../../state/downloads.dart';
import '../../state/settings.dart';
import 'common.dart';

/// Vorschaubild von YouTube (Google-Server, ohne Token).
class ThumbnailImage extends StatelessWidget {
  final String? url;
  final double size;
  final double radius;
  final bool video;

  const ThumbnailImage({super.key, required this.url, this.size = 48, this.radius = 4, this.video = false});

  @override
  Widget build(BuildContext context) {
    final width = video ? size * 16 / 9 : size;
    final placeholder = Container(
      width: width,
      height: size,
      color: AppColors.surfaceHighest,
      child: Icon(
        video ? Icons.movie_rounded : Icons.music_note_rounded,
        color: AppColors.textMuted,
        size: size * 0.45,
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: url == null
          ? placeholder
          : CachedNetworkImage(
              imageUrl: url!,
              width: width,
              height: size,
              fit: BoxFit.cover,
              placeholder: (_, _) => placeholder,
              errorWidget: (_, _, _) => placeholder,
            ),
    );
  }
}

/// Fortschrittsanzeige eines Downloads: Balken + "45 % · 1,2 MB/s · noch 12 Sek."
class JobProgress extends StatelessWidget {
  final DownloadJob job;
  final bool compact;

  const JobProgress({super.key, required this.job, this.compact = false});

  String get details {
    switch (job.status) {
      case 'downloading':
        final parts = <String>[formatPercent(job.progress)];
        if (job.speed != null) parts.add(formatSpeed(job.speed));
        parts.add(formatEta(job.eta));
        return parts.join(' · ');
      case 'processing':
        return 'Wird verarbeitet …';
      case 'queued':
        return job.statusLabel;
      case 'failed':
        return job.error ?? 'Fehlgeschlagen';
      default:
        return job.statusLabel;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = job.isFailed ? AppColors.danger : AppColors.accent;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (job.isActive)
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: job.status == 'downloading' && job.progress > 0 ? job.progress : null,
              minHeight: compact ? 3 : 4,
              backgroundColor: AppColors.surfaceHighest,
              color: color,
            ),
          ),
        if (!compact || !job.isActive) ...[
          const SizedBox(height: 4),
          Text(
            details,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppText.caption.copyWith(color: job.isFailed ? AppColors.danger : null),
          ),
        ],
      ],
    );
  }
}

/// "Holen"-Knopf für einen YouTube-Treffer – zeigt den Download-Fortschritt live,
/// und wenn der Titel da ist, kann er direkt abgespielt werden.
/// Bei Videos fragt er, ob nur die Musik (der Ton als Song) oder das ganze Video geholt werden soll –
/// außer in den Einstellungen ist „Immer nur Musik“ bzw. „Immer als Video“ festgelegt.
class DownloadButton extends ConsumerWidget {
  final YouTubeItem item;
  final int? playlistId;

  const DownloadButton({super.key, required this.item, this.playlistId});

  Future<void> _start(BuildContext context, WidgetRef ref, {bool audioOnly = false, bool remembered = false}) async {
    try {
      await ref.read(downloadsProvider.notifier).startItem(item, audioOnly: audioOnly, playlistId: playlistId);
      if (context.mounted) {
        final what = audioOnly ? '„${item.title}“ wird als Musik geholt' : '„${item.title}“ wird geholt';
        showMessage(context, remembered ? '$what · Gemerkt, änderbar in den Einstellungen' : what);
      }
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _play(BuildContext context, WidgetRef ref, int trackId) async {
    try {
      final track = await ref.read(apiProvider)!.track(trackId);
      await ref.read(playerProvider).playOne(track, context: const PlayContext('search'));
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  /// Video-Treffer: nur Musik oder ganzes Video – wie in den Einstellungen festgelegt, sonst nachfragen.
  Future<void> _fetchVideo(BuildContext context, WidgetRef ref) async {
    switch (ref.read(settingsProvider).videoFetch) {
      case 'audio':
        return _start(context, ref, audioOnly: true);
      case 'video':
        return _start(context, ref);
    }
    final choice = await showVideoFetchChoice(context, item.title);
    if (choice == null || !context.mounted) return;
    if (choice.remember) {
      await ref
          .read(settingsProvider.notifier)
          .update((s) => s.copyWith(videoFetch: choice.audioOnly ? 'audio' : 'video'));
      if (!context.mounted) return;
    }
    await _start(context, ref, audioOnly: choice.audioOnly, remembered: choice.remember);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final videoId = item.videoId;
    final job = videoId == null ? null : ref.watch(jobForVideoProvider((videoId, item.isVideo ? 'video' : 'audio')));
    // Bei Videos zählt auch eine „Nur Musik“-Kopie (Ton als Song)
    final audioJob = videoId == null || !item.isVideo ? null : ref.watch(jobForVideoProvider((videoId, 'audio')));
    final canDownload = ref.watch(currentUserProvider)?.canDownload ?? false;
    final trackId = job?.trackId ?? item.inLibraryTrackId;
    final audioTrackId = audioJob?.trackId ?? item.inLibraryAudioTrackId;
    final active = job != null && job.isActive ? job : (audioJob != null && audioJob.isActive ? audioJob : null);

    if (active != null) {
      return SizedBox(
        width: 44,
        height: 44,
        child: Stack(
          alignment: Alignment.center,
          children: [
            CircularProgressIndicator(
              value: active.status == 'downloading' && active.progress > 0 ? active.progress : null,
              strokeWidth: 3,
              backgroundColor: AppColors.surfaceHighest,
            ),
            Text(
              active.status == 'downloading' ? '${(active.progress * 100).floor()}' : '',
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      );
    }
    if (trackId != null && !item.isVideo) {
      return IconButton(
        tooltip: 'Abspielen',
        icon: const Icon(Icons.play_circle_fill_rounded, color: AppColors.accent, size: 34),
        onPressed: () => _play(context, ref, trackId),
      );
    }
    if (trackId != null) {
      return const Padding(
        padding: EdgeInsets.all(10),
        child: Icon(Icons.check_circle_rounded, color: AppColors.accent),
      );
    }
    // Vom Video ist schon die Musik da – direkt abspielen (das Video gibt es weiter über das Menü)
    if (audioTrackId != null) {
      return IconButton(
        tooltip: 'Musik abspielen',
        icon: const Icon(Icons.play_circle_fill_rounded, color: AppColors.accent, size: 34),
        onPressed: () => _play(context, ref, audioTrackId),
      );
    }
    // „Erneut versuchen“ nur für das, was „Holen“ auch holen würde: Bei „Immer nur Musik“ führt ein
    // fehlgeschlagenes Video nicht zurück zum Video (stattdessen „Holen“ = Musik), bei „Immer als Video“ umgekehrt
    final fetch = item.isVideo ? ref.watch(settingsProvider.select((s) => s.videoFetch)) : 'ask';
    final failed = [
      if (fetch != 'audio') job, // bei Songs der Song selbst, bei Videos das Video
      if (fetch != 'video') audioJob,
    ].nonNulls.where((j) => j.isFailed).firstOrNull;
    if (failed != null) {
      return IconButton(
        tooltip: failed.error ?? 'Erneut versuchen',
        icon: const Icon(Icons.refresh_rounded, color: AppColors.danger),
        onPressed: canDownload ? () => ref.read(downloadsProvider.notifier).retry(failed.id) : null,
      );
    }
    if (!canDownload) {
      return const Tooltip(
        message: 'Downloads sind für dein Konto nicht freigeschaltet',
        child: Padding(
          padding: EdgeInsets.all(10),
          child: Icon(Icons.lock_outline_rounded, color: AppColors.textMuted),
        ),
      );
    }
    return OutlinedButton.icon(
      onPressed: () => item.isVideo ? _fetchVideo(context, ref) : _start(context, ref),
      icon: const Icon(Icons.download_rounded, size: 18),
      label: const Text('Holen'),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

/// Fragt bei einem Video, was geholt werden soll: audioOnly = nur die Musik (Ton als Song), sonst das ganze Video;
/// remember = „Wahl merken“ angehakt (dann nicht mehr fragen). null = abgebrochen.
/// Musik zuerst – für Kinderlieder & Co. reicht meist der Ton.
Future<({bool audioOnly, bool remember})?> showVideoFetchChoice(BuildContext context, String title) {
  var remember = false;
  return showModalBottomSheet<({bool audioOnly, bool remember})>(
    context: context,
    useRootNavigator: true,
    // Mit großer Schrift höher als die halbe Seite – dann scrollen statt abschneiden
    isScrollControlled: true,
    constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
    builder: (sheetContext) => StatefulBuilder(
      builder: (sheetContext, setSheetState) {
        void pick(bool audioOnly) => Navigator.of(sheetContext).pop((audioOnly: audioOnly, remember: remember));
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.tileTitle),
                  subtitle: const Text('Was möchtest du holen?', style: AppText.tileSubtitle),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.music_note_rounded, color: AppColors.accent),
                  title: const Text('Nur Musik'),
                  subtitle: const Text(
                    'Nur den Ton – als Song bei der Musik, viel kleiner',
                    style: AppText.tileSubtitle,
                  ),
                  onTap: () => pick(true),
                ),
                ListTile(
                  leading: const Icon(Icons.movie_rounded),
                  title: const Text('Video'),
                  subtitle: const Text('Mit Bild – bei den Videos', style: AppText.tileSubtitle),
                  onTap: () => pick(false),
                ),
                const Divider(height: 1),
                // Für Kinder-Handys & Co.: einmal „Nur Musik“ merken, dann holt „Holen“ ohne Nachfrage.
                // Kästchen so breit wie die Symbole darüber, damit die Texte bündig stehen. Wie bei
                // CheckboxListTile ein einziges Bedienziel: Screenreader lesen „Wahl merken“ samt Haken vor.
                MergeSemantics(
                  child: ListTile(
                    leading: SizedBox(
                      width: 24,
                      child: ExcludeFocus(
                        child: Checkbox(
                          value: remember,
                          onChanged: (value) => setSheetState(() => remember = value ?? false),
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                          activeColor: AppColors.accent,
                          checkColor: Colors.black,
                        ),
                      ),
                    ),
                    title: const Text('Wahl merken'),
                    subtitle: const Text(
                      'Nicht mehr fragen – änderbar in den Einstellungen',
                      style: AppText.tileSubtitle,
                    ),
                    onTap: () => setSheetState(() => remember = !remember),
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    ),
  );
}
