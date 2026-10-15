import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../player/player.dart';
import '../../state/offline.dart';
import '../nav.dart';
import 'common.dart';
import 'cover.dart';
import 'track_menu.dart';

/// Eine Titel-Zeile wie bei Spotify: Cover, Titel (grün, wenn er läuft), Künstler, Menü.
class TrackTile extends ConsumerWidget {
  final Track track;
  /// Alle Titel der Liste – Tippen spielt die Liste ab diesem Titel.
  final List<Track> queue;
  final PlayContext? context_;
  final bool showCover;
  /// Statt Cover die Tracknummer zeigen (Albumansicht).
  final bool showNumber;
  final Widget? trailing;
  final VoidCallback? onTap;
  /// Zusätzliche Einträge im Menü (z. B. "Aus Playlist entfernen").
  final List<TrackMenuAction> extraActions;
  /// Position in [queue] – nötig, wenn derselbe Titel mehrfach vorkommt (Playlist).
  final int? queueIndex;

  const TrackTile({
    super.key,
    required this.track,
    this.queue = const [],
    this.context_,
    this.showCover = true,
    this.showNumber = false,
    this.trailing,
    this.onTap,
    this.extraActions = const [],
    this.queueIndex,
  });

  Future<void> _play(BuildContext context, WidgetRef ref) async {
    if (track.isVideo) {
      ref.read(audioHandlerProvider).pause();
      Nav.video(context, track);
      return;
    }
    final list = queue.isEmpty ? [track] : queue;
    final position = queueIndex;
    final index = position != null && position < list.length ? position : list.indexOf(track);
    try {
      await ref.read(playerProvider).play(list, index: index < 0 ? 0 : index, context: context_);
    } catch (e) {
      if (context.mounted) showMessage(context, e is StateError ? e.message : 'Abspielen nicht möglich: $e');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isCurrent = ref.watch(isCurrentTrackProvider(track.id));
    final downloaded = ref.watch(isDownloadedProvider(track.id));
    final titleColor = isCurrent ? AppColors.accent : Colors.white;
    Widget? leading;
    if (showNumber) {
      leading = SizedBox(
        width: 28,
        child: isCurrent
            ? const Icon(Icons.graphic_eq_rounded, color: AppColors.accent, size: 20)
            : Text('${track.trackNumber ?? ''}', textAlign: TextAlign.center, style: AppText.tileSubtitle),
      );
    } else if (showCover) {
      leading = Stack(
        children: [
          CoverImage(
            coverId: track.coverId,
            size: 48,
            placeholderIcon: track.isVideo ? Icons.movie_rounded : Icons.music_note_rounded,
          ),
          if (track.isVideo)
            const Positioned(
              right: 2,
              bottom: 2,
              child: Icon(Icons.play_circle_fill_rounded, size: 16, color: Colors.white),
            ),
        ],
      );
    }
    return ListTile(
      onTap: onTap ?? () => _play(context, ref),
      onLongPress: () => showTrackMenu(context, ref, track, extraActions: extraActions),
      leading: leading,
      minLeadingWidth: 0,
      title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.tileTitle.copyWith(color: titleColor)),
      subtitle: Row(
        children: [
          if (downloaded)
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Icon(Icons.arrow_circle_down_rounded, size: 14, color: AppColors.accent),
            ),
          if (track.isVideo)
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Text('Video · ', style: AppText.tileSubtitle),
            ),
          Expanded(
            child: Text(track.artistDisplay, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.tileSubtitle),
          ),
        ],
      ),
      trailing: trailing ??
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showNumber) Text(formatDuration(track.length), style: AppText.caption),
              IconButton(
                icon: const Icon(Icons.more_vert_rounded),
                onPressed: () => showTrackMenu(context, ref, track, extraActions: extraActions),
              ),
            ],
          ),
    );
  }
}
