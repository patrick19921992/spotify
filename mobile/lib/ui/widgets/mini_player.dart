import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../player/player.dart';
import '../../state/likes.dart';
import '../nav.dart';
import 'cover.dart';

/// Mini-Player über der unteren Leiste – Tippen öffnet den Vollbild-Player.
class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(currentTrackProvider);
    if (track == null) return const SizedBox.shrink();
    final playing = ref.watch(isPlayingProvider);
    final liked = ref.watch(isTrackLikedProvider(track.id));
    final position = ref.watch(positionProvider).value ?? Duration.zero;
    final duration = ref.watch(durationProvider).value ?? track.length;
    final progress = duration.inMilliseconds == 0 ? 0.0 : (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
    final color = parseHexColor(track.coverColor) ?? AppColors.surfaceHigh;

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
      child: Material(
        color: darken(color, 0.15),
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Nav.player(context),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 4, 6),
                child: Row(
                  children: [
                    CoverImage(coverId: track.coverId, size: 40),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(track.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5)),
                          Text(track.artistDisplay,
                              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, color: Color(0xFFDDDDDD))),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: Icon(liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                          color: liked ? AppColors.accent : Colors.white),
                      onPressed: () => ref.read(likesProvider.notifier).toggleTrack(track.id),
                    ),
                    IconButton(
                      icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 30),
                      onPressed: () => ref.read(playerProvider).togglePlay(),
                    ),
                  ],
                ),
              ),
              LinearProgressIndicator(
                value: progress,
                minHeight: 2,
                backgroundColor: const Color(0x33FFFFFF),
                color: Colors.white,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
