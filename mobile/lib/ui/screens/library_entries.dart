import 'package:flutter/material.dart';

import '../../core/theme.dart';
import 'library_widgets.dart';

/// Ein Eintrag in „Deine Bibliothek“ (Lieblingssongs, Playlist, Album, Künstler, Download …).
class LibraryEntry {
  /// Eindeutiger Schlüssel wie „playlist:5“ – passt zu den „Zuletzt gehört“-Kontexten.
  final String id;
  final String title;
  final String subtitle;
  final Widget Function(double size) cover;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// Rundes Cover (Künstler).
  final bool circle;

  /// Immer oben (Lieblingssongs).
  final bool pinned;

  /// Grüner Download-Pfeil: offline verfügbar.
  final bool offline;

  /// Plakette „Gemeinsam“.
  final bool collaborative;

  /// Gefolgt (Herz in der Unterzeile, für Playlists der Familie).
  final bool following;

  /// Download-Fortschritt (nur wenn noch nicht fertig).
  final double? progress;

  final Widget? trailing;

  /// Reihenfolge vom Server (für „Zuletzt“ bei Gleichstand).
  final int order;

  const LibraryEntry({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.cover,
    required this.onTap,
    this.onLongPress,
    this.circle = false,
    this.pinned = false,
    this.offline = false,
    this.collaborative = false,
    this.following = false,
    this.progress,
    this.trailing,
    this.order = 0,
  });
}

/// Sortiert Einträge: angeheftete zuerst, dann alphabetisch oder nach „zuletzt gehört“.
List<LibraryEntry> sortLibraryEntries(
  List<LibraryEntry> entries, {
  required bool alphabetical,
  Map<String, int> recentRank = const {},
}) {
  final pinned = entries.where((e) => e.pinned).toList();
  final rest = entries.where((e) => !e.pinned).toList();
  if (alphabetical) {
    rest.sort((a, b) {
      final byTitle = sortKey(a.title).compareTo(sortKey(b.title));
      return byTitle != 0 ? byTitle : a.order.compareTo(b.order);
    });
  } else {
    const never = 1 << 30;
    rest.sort((a, b) {
      final byRecent = (recentRank[a.id] ?? never).compareTo(recentRank[b.id] ?? never);
      return byRecent != 0 ? byRecent : a.order.compareTo(b.order);
    });
  }
  return [...pinned, ...rest];
}

/// Kleine Symbole vor der Unterzeile (angeheftet, offline, gefolgt).
List<Widget> _markers(LibraryEntry entry, {double size = 14}) => [
  if (entry.pinned) ...[
    Icon(Icons.push_pin_rounded, size: size - 1, color: AppColors.accent),
    const SizedBox(width: 4),
  ],
  if (entry.offline) ...[
    Icon(Icons.arrow_circle_down_rounded, size: size, color: AppColors.accent),
    const SizedBox(width: 4),
  ],
  if (entry.following) ...[
    Icon(Icons.favorite_rounded, size: size - 1, color: AppColors.accent),
    const SizedBox(width: 4),
  ],
];

/// Listenzeile mit Cover, Titel und Unterzeile.
class LibraryEntryTile extends StatelessWidget {
  final LibraryEntry entry;
  const LibraryEntryTile({super.key, required this.entry});

  @override
  Widget build(BuildContext context) {
    final progress = entry.progress;
    return InkWell(
      onTap: entry.onTap,
      onLongPress: entry.onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        child: Row(
          children: [
            entry.cover(64),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600, color: Colors.white),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      ..._markers(entry),
                      Flexible(
                        child: Text(
                          entry.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.tileSubtitle,
                        ),
                      ),
                      if (entry.collaborative) ...[
                        const SizedBox(width: 6),
                        const InfoBadge(label: 'Gemeinsam', icon: Icons.group_rounded, color: AppColors.accent),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            if (progress != null)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    value: progress > 0 ? progress : null,
                    strokeWidth: 2.5,
                    backgroundColor: AppColors.surfaceHighest,
                  ),
                ),
              ),
            if (entry.trailing != null) entry.trailing!,
          ],
        ),
      ),
    );
  }
}

/// Rasterzelle (3 Spalten): Cover und Titel.
class LibraryEntryCell extends StatelessWidget {
  final LibraryEntry entry;
  const LibraryEntryCell({super.key, required this.entry});

  @override
  Widget build(BuildContext context) {
    final align = entry.circle ? CrossAxisAlignment.center : CrossAxisAlignment.start;
    final textAlign = entry.circle ? TextAlign.center : TextAlign.start;
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.maxWidth;
        final progress = entry.progress;
        return InkWell(
          onTap: entry.onTap,
          onLongPress: entry.onLongPress,
          borderRadius: BorderRadius.circular(6),
          child: Column(
            crossAxisAlignment: align,
            children: [
              Stack(
                children: [
                  entry.cover(size),
                  if (progress != null)
                    Positioned(
                      right: 6,
                      bottom: 6,
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: const BoxDecoration(color: Color(0xCC000000), shape: BoxShape.circle),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(value: progress > 0 ? progress : null, strokeWidth: 2),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                entry.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: textAlign,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white),
              ),
              const SizedBox(height: 2),
              Row(
                mainAxisAlignment: entry.circle ? MainAxisAlignment.center : MainAxisAlignment.start,
                children: [
                  ..._markers(entry, size: 12),
                  Flexible(
                    child: Text(
                      entry.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: textAlign,
                      style: const TextStyle(fontSize: 11.5, color: AppColors.textSecondary),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Quadratisches Symbol-Cover (z. B. „Alle Titel auf diesem Gerät“, „Playlist erstellen“).
class SymbolCover extends StatelessWidget {
  final IconData icon;
  final double size;
  final List<Color> colors;
  final Color iconColor;

  const SymbolCover({
    super.key,
    required this.icon,
    required this.size,
    this.colors = const [AppColors.surfaceHighest, AppColors.surfaceHighest],
    this.iconColor = AppColors.textSecondary,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors),
      ),
      child: Icon(icon, color: iconColor, size: size * 0.45),
    );
  }
}
