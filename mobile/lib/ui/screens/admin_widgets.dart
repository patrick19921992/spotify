import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';

// Gemeinsame Bausteine der Verwaltung (Benutzer, Rubriken, Bibliothek, Downloader).

/// Symbole, die eine Rubrik haben kann (Namen wie auf dem Server gespeichert).
const adminCategoryIcons = <String, IconData>{
  'music_note': Icons.music_note_rounded,
  'music_video': Icons.music_video_rounded,
  'auto_stories': Icons.auto_stories_rounded,
  'movie': Icons.movie_rounded,
  'child_care': Icons.child_care_rounded,
  'headphones': Icons.headphones_rounded,
  'mic': Icons.mic_rounded,
  'piano': Icons.piano_rounded,
  'nightlife': Icons.nightlife_rounded,
  'sports_esports': Icons.sports_esports_rounded,
  'school': Icons.school_rounded,
  'folder': Icons.folder_rounded,
};

/// Beschriftungen der Symbole (Tooltip / Bildschirmleser).
const adminCategoryIconLabels = <String, String>{
  'music_note': 'Musik',
  'music_video': 'Musikvideos',
  'auto_stories': 'Hörbücher',
  'movie': 'Filme',
  'child_care': 'Kinder',
  'headphones': 'Kopfhörer',
  'mic': 'Mikrofon',
  'piano': 'Klavier',
  'nightlife': 'Party',
  'sports_esports': 'Spiele',
  'school': 'Lernen',
  'folder': 'Ordner',
};

IconData adminCategoryIcon(String name) => adminCategoryIcons[name] ?? Icons.folder_rounded;

/// Farbe für Video-Inhalte (Audio nutzt das Grün der App).
const adminVideoColor = Color(0xFF509BF5);

/// Farbe für Hinweise/Warnungen.
const adminWarningColor = Color(0xFFFFA42B);

final _countFormat = NumberFormat.decimalPattern('de_DE');

/// 1.234
String formatCount(int value) => _countFormat.format(value);

/// Neu laden für „Zum Aktualisieren ziehen“ – Fehler zeigt die Ansicht selbst an.
Future<void> adminQuietly(Future<Object?> future) async {
  try {
    await future;
  } catch (_) {
    // Der Fehler erscheint in der Ansicht
  }
}

/// Innenabstand für Listen der Verwaltung – auf Tablets mittig mit begrenzter Breite.
EdgeInsets adminListPadding(BuildContext context, {double top = 16, double bottom = 32, double horizontal = 16}) {
  final width = MediaQuery.sizeOf(context).width;
  final side = math.max(horizontal, (width - 760) / 2);
  return EdgeInsets.fromLTRB(side, top, side, bottom + MediaQuery.paddingOf(context).bottom);
}

/// Kleines Etikett wie „Admin“ oder „Deaktiviert“.
class AdminBadge extends StatelessWidget {
  final String label;
  final Color color;
  final IconData? icon;

  const AdminBadge({super.key, required this.label, this.color = AppColors.textSecondary, this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color, height: 1.2),
          ),
        ],
      ),
    );
  }
}

/// Dunkle Karte mit abgerundeten Ecken.
class AdminCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color color;

  const AdminCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.color = AppColors.surface,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(12)),
      child: child,
    );
  }
}

/// Überschrift über einer Karte.
class AdminSectionLabel extends StatelessWidget {
  final String title;
  const AdminSectionLabel(this.title, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 24, 4, 10),
      child: Text(title, style: AppText.sectionTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}

/// Hinweis-/Fehlerkasten in Formularen und Blättern.
class AdminNotice extends StatelessWidget {
  final String message;
  final bool error;
  final IconData? icon;

  const AdminNotice(this.message, {super.key, this.error = true, this.icon});

  @override
  Widget build(BuildContext context) {
    final color = error ? AppColors.danger : AppColors.accent;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon ?? (error ? Icons.error_outline_rounded : Icons.check_circle_outline_rounded), size: 20, color: color),
          const SizedBox(width: 10),
          Expanded(child: Text(message, style: const TextStyle(fontSize: 13, color: Colors.white, height: 1.35))),
        ],
      ),
    );
  }
}

/// Grüner Knopf mit Ladeanzeige.
class AdminPrimaryButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool busy;
  final VoidCallback? onPressed;

  const AdminPrimaryButton({super.key, required this.label, this.icon, this.busy = false, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final Widget leading = busy
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.black),
          )
        : Icon(icon ?? Icons.check_rounded, size: 20);
    return FilledButton.icon(
      onPressed: busy ? null : onPressed,
      style: FilledButton.styleFrom(
        disabledBackgroundColor: busy ? AppColors.accent : AppColors.surfaceHighest,
        disabledForegroundColor: busy ? Colors.black : AppColors.textMuted,
      ),
      icon: leading,
      label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}

/// Blatt von unten (Formulare der Verwaltung). Liefert das Ergebnis des Blatts.
Future<T?> showAdminSheet<T>(BuildContext context, WidgetBuilder builder) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    useSafeArea: true,
    builder: builder,
  );
}

/// Inhalt eines Blatts: Titel, scrollbarer Inhalt, Platz für die Tastatur.
class AdminSheet extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? leading;
  final List<Widget> children;

  const AdminSheet({super.key, required this.title, this.subtitle, this.leading, required this.children});

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final side = math.max(20.0, (width - 640) / 2);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(side, 0, side, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  if (leading != null) ...[leading!, const SizedBox(width: 14)],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: AppText.sectionTitle, maxLines: 2, overflow: TextOverflow.ellipsis),
                        if (subtitle != null) ...[
                          const SizedBox(height: 4),
                          Text(subtitle!, style: AppText.tileSubtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

/// Auswahl eines Rubrik-Symbols (Raster aus runden Knöpfen).
class AdminIconPicker extends StatelessWidget {
  final String selected;
  final ValueChanged<String>? onChanged;

  const AdminIconPicker({super.key, required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final entry in adminCategoryIcons.entries)
          _IconChoice(
            icon: entry.value,
            label: adminCategoryIconLabels[entry.key] ?? entry.key,
            selected: entry.key == selected,
            onTap: onChanged == null ? null : () => onChanged!(entry.key),
          ),
      ],
    );
  }
}

class _IconChoice extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  const _IconChoice({required this.icon, required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: Semantics(
        selected: selected,
        button: true,
        label: label,
        child: Material(
          color: selected ? AppColors.accent : AppColors.surfaceHighest,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: 48,
              height: 48,
              child: Icon(icon, size: 24, color: selected ? Colors.black : Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}

/// Medientyp-Etikett „Audio“ / „Video“.
class AdminMediaTypeChip extends StatelessWidget {
  final bool isVideo;
  const AdminMediaTypeChip({super.key, required this.isVideo});

  @override
  Widget build(BuildContext context) => AdminBadge(
        label: isVideo ? 'Video' : 'Audio',
        icon: isVideo ? Icons.videocam_rounded : Icons.graphic_eq_rounded,
        color: isVideo ? adminVideoColor : AppColors.accent,
      );
}

/// Schrift für Pfade (Ordner, Dateien).
const adminMonospace = TextStyle(
  fontFamily: 'monospace',
  fontFamilyFallback: ['Menlo', 'Courier New', 'Courier'],
  fontSize: 12,
  color: AppColors.textSecondary,
  height: 1.35,
);
