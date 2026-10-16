import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/models.dart';
import '../nav.dart';
import 'cover.dart';
import 'fit_text.dart';

/// Quadratische Karte (Album, Playlist, Mix) bzw. runde (Künstler) für horizontale Reihen.
class MediaCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget cover;
  final VoidCallback onTap;
  final double width;
  final bool centered;

  const MediaCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.cover,
    required this.onTap,
    this.width = 148,
    this.centered = false,
  });

  factory MediaCard.album(BuildContext context, Album album, {double width = 148}) => MediaCard(
        width: width,
        title: album.title,
        subtitle: [if (album.year != null) '${album.year}', album.artist.name].join(' · '),
        cover: CoverImage(coverId: album.coverId, size: width, radius: 6, placeholderIcon: Icons.album_rounded),
        onTap: () => Nav.album(context, album.id),
      );

  factory MediaCard.artist(BuildContext context, Artist artist, {double width = 148}) => MediaCard(
        width: width,
        centered: true,
        title: artist.name,
        subtitle: 'Künstler',
        cover: CoverImage(coverId: artist.coverId, size: width, circle: true, placeholderIcon: Icons.person_rounded),
        onTap: () => Nav.artist(context, artist.id),
      );

  factory MediaCard.playlist(BuildContext context, Playlist playlist, {double width = 148}) => MediaCard(
        width: width,
        title: playlist.name,
        subtitle: 'Von ${playlist.owner.displayName}',
        cover: PlaylistCover(coverId: playlist.coverId, mosaic: playlist.mosaic, size: width, radius: 6),
        onTap: () => Nav.playlist(context, playlist.id),
      );

  factory MediaCard.context(BuildContext context, ContextItem item, {double width = 148}) => MediaCard(
        width: width,
        centered: item.type == 'artist',
        title: item.title,
        subtitle: item.subtitle,
        cover: contextCover(item, width, radius: 6),
        onTap: () => Nav.context_(context, item),
      );

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Column(
          crossAxisAlignment: centered ? CrossAxisAlignment.center : CrossAxisAlignment.start,
          children: [
            cover,
            const SizedBox(height: 8),
            Text(title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: centered ? TextAlign.center : TextAlign.start,
                style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: Colors.white)),
            const SizedBox(height: 2),
            Text(subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: centered ? TextAlign.center : TextAlign.start,
                style: AppText.caption),
          ],
        ),
      ),
    );
  }
}

/// Passendes Cover für eine Startseiten-Kachel.
Widget contextCover(ContextItem item, double size, {double radius = 4}) {
  return switch (item.type) {
    'liked' => LikedSongsCover(size: size, radius: radius),
    'artist' => CoverImage(coverId: item.coverId, size: size, circle: true, placeholderIcon: Icons.person_rounded),
    'playlist' || 'mix' => PlaylistCover(coverId: item.coverId, mosaic: item.mosaic, size: size, radius: radius),
    _ => CoverImage(coverId: item.coverId, size: size, radius: radius, placeholderIcon: Icons.album_rounded),
  };
}

/// Horizontale Reihe von Karten.
///
/// Ohne [height] wird die Höhe aus [cardWidth] und der Schriftgröße berechnet
/// (Cover + 2 Zeilen Titel + Untertitel), sodass nichts überläuft – auch nicht bei großer Systemschrift.
class CardRow extends StatelessWidget {
  final List<Widget> children;
  final double? height;
  final double cardWidth;

  const CardRow({super.key, required this.children, this.height, this.cardWidth = 148});

  /// Benötigte Höhe für [MediaCard]s der Breite [cardWidth].
  static double heightFor(BuildContext context, double cardWidth) {
    final scaler = MediaQuery.textScalerOf(context);
    // Zeilenhöhe der Standard-Textstile ≈ 1,45 × Schriftgröße
    return cardWidth + 8 + 2 + scaler.scale(13.5) * 1.45 * 2 + scaler.scale(12) * 1.45 + 6;
  }

  @override
  Widget build(BuildContext context) {
    final double rowHeight;
    if (height == null) {
      rowHeight = heightFor(context, cardWidth);
    } else {
      // Feste Höhe: bei größerer Systemschrift entsprechend zulegen
      final scaler = MediaQuery.textScalerOf(context);
      final extra = (scaler.scale(13.5) - 13.5) * 2.9 + (scaler.scale(12) - 12) * 1.45;
      rowHeight = height! + extra.clamp(0, 140);
    }
    return SizedBox(
      height: rowHeight,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: children.length,
        separatorBuilder: (_, _) => const SizedBox(width: 14),
        itemBuilder: (_, index) => children[index],
      ),
    );
  }
}

/// Kompakte Kachel für den Schnellzugriff oben auf der Startseite (2 Spalten).
class QuickTile extends StatelessWidget {
  final ContextItem item;
  const QuickTile({super.key, required this.item});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surfaceHigh,
      borderRadius: BorderRadius.circular(4),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Nav.context_(context, item),
        // Cover so hoch wie die Kachel (die wächst mit großer Schrift mit), aber nur 56 breit – sonst bliebe
        // gerade bei großer Schrift weniger Platz für den Titel
        child: LayoutBuilder(
          builder: (context, constraints) {
            final height = constraints.maxHeight.isFinite ? constraints.maxHeight : 56.0;
            return Row(
              children: [
                SizedBox(
                  width: 56,
                  height: height,
                  child: FittedBox(
                    fit: BoxFit.cover,
                    clipBehavior: Clip.hardEdge,
                    child: contextCover(item, height, radius: 0),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: WordSafeText(
                    item.title,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.white),
                  ),
                ),
                const SizedBox(width: 6),
              ],
            );
          },
        ),
      ),
    );
  }
}
