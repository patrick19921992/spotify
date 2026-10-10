import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../state/auth.dart';

/// Cover vom Server (zwischengespeichert). Ohne Cover: Platzhalter mit Symbol.
class CoverImage extends ConsumerWidget {
  final String? coverId;
  final double size;
  final double radius;
  final bool circle;
  final IconData placeholderIcon;
  /// Auflösung, die vom Server angefordert wird (64, 128, 300, 600).
  final int? requestSize;

  const CoverImage({
    super.key,
    required this.coverId,
    this.size = 48,
    this.radius = 4,
    this.circle = false,
    this.placeholderIcon = Icons.music_note_rounded,
    this.requestSize,
  });

  int get _serverSize {
    if (requestSize != null) return requestSize!;
    if (size <= 64) return 128;
    if (size <= 160) return 300;
    return 600;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(apiProvider);
    final placeholder = Container(
      width: size,
      height: size,
      color: AppColors.surfaceHighest,
      alignment: Alignment.center,
      child: Icon(placeholderIcon, color: AppColors.textMuted, size: size * 0.45),
    );
    Widget child = placeholder;
    if (coverId != null && api != null) {
      final serverSize = _serverSize;
      child = CachedNetworkImage(
        imageUrl: api.coverUrl(coverId!, size: serverSize),
        // Token im Link ändert sich – zwischengespeichert wird nach Cover-ID
        cacheKey: '$coverId-$serverSize',
        width: size,
        height: size,
        fit: BoxFit.cover,
        fadeInDuration: const Duration(milliseconds: 150),
        placeholder: (_, _) => placeholder,
        errorWidget: (_, _, _) => placeholder,
      );
    }
    if (circle) return ClipOval(child: SizedBox(width: size, height: size, child: child));
    return ClipRRect(borderRadius: BorderRadius.circular(radius), child: SizedBox(width: size, height: size, child: child));
  }
}

/// Playlist-Cover: eigenes Bild oder 2×2-Mosaik der ersten Alben (wie bei Spotify).
class PlaylistCover extends StatelessWidget {
  final String? coverId;
  final List<String> mosaic;
  final double size;
  final double radius;
  final IconData placeholderIcon;

  const PlaylistCover({
    super.key,
    required this.coverId,
    required this.mosaic,
    this.size = 48,
    this.radius = 4,
    this.placeholderIcon = Icons.queue_music_rounded,
  });

  @override
  Widget build(BuildContext context) {
    if (coverId != null || mosaic.length < 4) {
      return CoverImage(
        coverId: coverId ?? mosaic.firstOrNull,
        size: size,
        radius: radius,
        placeholderIcon: placeholderIcon,
      );
    }
    final half = size / 2;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: size,
        height: size,
        child: Column(
          children: [
            Row(children: [
              CoverImage(coverId: mosaic[0], size: half, radius: 0, requestSize: size > 120 ? 300 : 128),
              CoverImage(coverId: mosaic[1], size: half, radius: 0, requestSize: size > 120 ? 300 : 128),
            ]),
            Row(children: [
              CoverImage(coverId: mosaic[2], size: half, radius: 0, requestSize: size > 120 ? 300 : 128),
              CoverImage(coverId: mosaic[3], size: half, radius: 0, requestSize: size > 120 ? 300 : 128),
            ]),
          ],
        ),
      ),
    );
  }
}

/// Lila Kachel mit Herz für "Lieblingssongs".
class LikedSongsCover extends StatelessWidget {
  final double size;
  final double radius;
  const LikedSongsCover({super.key, this.size = 48, this.radius = 4});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF4B2BD6), Color(0xFF8E8EE5)],
        ),
      ),
      child: Icon(Icons.favorite_rounded, color: Colors.white, size: size * 0.45),
    );
  }
}

/// Farbverlauf von der Cover-Farbe nach Schwarz – Hintergrund für Kopfbereiche.
class CoverGradient extends StatelessWidget {
  final String? colorHex;
  final Widget child;
  final double stop;

  const CoverGradient({super.key, required this.colorHex, required this.child, this.stop = 0.85});

  @override
  Widget build(BuildContext context) {
    final color = parseHexColor(colorHex) ?? AppColors.surfaceHighest;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [darken(color, 0.1), AppColors.background],
          stops: [0, stop],
        ),
      ),
      child: child,
    );
  }
}
