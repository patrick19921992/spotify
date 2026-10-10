import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/models.dart';
import '../nav.dart';
import 'cover.dart';

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
class CardRow extends StatelessWidget {
  final List<Widget> children;
  final double height;

  const CardRow({super.key, required this.children, this.height = 210});

  @override
  Widget build(BuildContext context) {
    // Größere Systemschrift: Reihe entsprechend höher machen (Titel 2 Zeilen + Untertitel)
    final textScaler = MediaQuery.textScalerOf(context);
    final extra = (textScaler.scale(13.5) - 13.5) * 2.7 + (textScaler.scale(12) - 12) * 1.35;
    return SizedBox(
      height: height + extra.clamp(0, 120),
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
        child: Row(
          children: [
            contextCover(item, 56, radius: 0),
            const SizedBox(width: 8),
            Expanded(
              child: Text(item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.white)),
            ),
            const SizedBox(width: 6),
          ],
        ),
      ),
    );
  }
}
