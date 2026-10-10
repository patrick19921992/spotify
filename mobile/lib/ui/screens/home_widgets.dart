import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../player/player.dart';
import '../../state/auth.dart';
import '../nav.dart';
import '../widgets/common.dart';
import '../widgets/cover.dart';
import '../widgets/track_menu.dart';

// Gemeinsame Bausteine für Startseite, Mix- und Rubrik-Seite.

/// Spielt [tracks] ab [index] ab und zeigt Probleme verständlich an
/// (z. B. "Keiner dieser Titel ist offline verfügbar.").
Future<void> playWithFeedback(
  BuildContext context,
  WidgetRef ref,
  List<Track> tracks, {
  int index = 0,
  PlayContext? playContext,
  bool shuffle = false,
}) async {
  final player = ref.read(playerProvider);
  try {
    await player.play(tracks, index: index, context: playContext, shuffle: shuffle);
  } on StateError catch (e) {
    if (context.mounted) showMessage(context, e.message);
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

/// Video öffnen – Musik wird dafür angehalten (Videos laufen nie über den Audio-Player).
void openVideo(BuildContext context, WidgetRef ref, Track track) {
  ref.read(audioHandlerProvider).pause();
  Nav.video(context, track);
}

/// Läuft gerade etwas aus diesem Kontext (z. B. dieser Mix)?
///
/// Beobachtet Titel, Warteschlange und Wiedergabe, damit sich die Anzeige aktualisiert.
bool watchIsPlayingContext(WidgetRef ref, bool Function(PlayContext context) matches, List<Track> tracks) {
  final current = ref.watch(currentTrackProvider);
  ref.watch(queueProvider);
  final playContext = ref.watch(audioHandlerProvider).playContext;
  if (current == null || playContext == null) return false;
  return matches(playContext) && tracks.contains(current);
}

// ------------------------------------------------------------------ Seitengerüst

/// Detailseite im Spotify-Stil: Farbverlauf beginnt hinter der (durchsichtigen) App-Leiste,
/// beim Scrollen färbt sich die Leiste ein und der Titel wird eingeblendet.
class HomeGradientScaffold extends StatefulWidget {
  final String title;
  final Color color;
  final List<Widget> actions;

  /// Titel immer anzeigen (sonst erst nach dem Scrollen).
  final bool alwaysShowTitle;

  /// Ab dieser Scroll-Position gilt der Kopfbereich als eingeklappt.
  final double collapseOffset;

  /// Baut den Inhalt; [topInset] = Statusleiste + App-Leiste (dort beginnt der sichtbare Bereich).
  final Widget Function(BuildContext context, double topInset) bodyBuilder;

  const HomeGradientScaffold({
    super.key,
    required this.title,
    required this.color,
    required this.bodyBuilder,
    this.actions = const [],
    this.alwaysShowTitle = false,
    this.collapseOffset = 240,
  });

  @override
  State<HomeGradientScaffold> createState() => _HomeGradientScaffoldState();
}

class _HomeGradientScaffoldState extends State<HomeGradientScaffold> {
  bool _collapsed = false;

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0 || notification.metrics.axis != Axis.vertical) return false;
    final collapsed = notification.metrics.pixels > widget.collapseOffset;
    if (collapsed != _collapsed) setState(() => _collapsed = collapsed);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final barColor = darken(widget.color, 0.22);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        scrolledUnderElevation: 0,
        flexibleSpace: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          color: _collapsed ? barColor : Colors.transparent,
        ),
        title: AnimatedOpacity(
          opacity: widget.alwaysShowTitle || _collapsed ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: Text(
            widget.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white),
          ),
        ),
        actions: widget.actions,
      ),
      body: NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: Builder(
          builder: (context) => widget.bodyBuilder(context, MediaQuery.paddingOf(context).top),
        ),
      ),
    );
  }
}

/// Farbverlauf von [color] nach Schwarz (wie [CoverGradient], aber mit fertiger Farbe).
class HeaderGradient extends StatelessWidget {
  final Color color;
  final Widget child;
  final double stop;

  const HeaderGradient({super.key, required this.color, required this.child, this.stop = 1});

  @override
  Widget build(BuildContext context) {
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

/// Kleine Fehlermeldung mitten in einer Seite (z. B. ein Abschnitt konnte nicht geladen werden).
class InlineError extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;

  const InlineError({super.key, required this.message, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded, color: AppColors.textSecondary, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message, maxLines: 3, overflow: TextOverflow.ellipsis, style: AppText.tileSubtitle),
          ),
          if (onRetry != null)
            TextButton(
              onPressed: onRetry,
              child: const Text('Erneut versuchen', style: TextStyle(color: AppColors.accent, fontWeight: FontWeight.w600)),
            ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ Karten

/// Quadratische Song-Karte für horizontale Reihen (Cover, Titel, Künstler).
class HomeTrackCard extends ConsumerWidget {
  final Track track;
  final VoidCallback onTap;
  final double width;

  const HomeTrackCard({super.key, required this.track, required this.onTap, this.width = 148});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isCurrent = ref.watch(isCurrentTrackProvider(track.id));
    final playing = isCurrent && ref.watch(isPlayingProvider);
    return SizedBox(
      width: width,
      child: InkWell(
        onTap: onTap,
        onLongPress: () => showTrackMenu(context, ref, track),
        borderRadius: BorderRadius.circular(6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                CoverImage(
                  coverId: track.coverId,
                  size: width,
                  radius: 6,
                  placeholderIcon: track.isVideo ? Icons.movie_rounded : Icons.music_note_rounded,
                ),
                if (isCurrent || track.isVideo)
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isCurrent ? AppColors.accent : Colors.black54,
                        boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 8)],
                      ),
                      child: Icon(
                        isCurrent
                            ? (playing ? Icons.graphic_eq_rounded : Icons.pause_rounded)
                            : Icons.play_arrow_rounded,
                        size: 20,
                        color: isCurrent ? Colors.black : Colors.white,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              track.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: isCurrent ? AppColors.accent : Colors.white,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              [if (track.isVideo) 'Video', track.artistDisplay].where((s) => s.isNotEmpty).join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.caption,
            ),
          ],
        ),
      ),
    );
  }
}

/// Vorschaubild eines Videos im 16:9-Format (Cover vom Server, zwischengespeichert).
class VideoThumbnail extends ConsumerWidget {
  final String? coverId;
  final double radius;

  const VideoThumbnail({super.key, required this.coverId, this.radius = 6});

  /// Gleiche Größe/Cache-Schlüssel wie [CoverImage] bei großen Covern.
  static const _serverSize = 600;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(apiProvider);
    const placeholder = ColoredBox(
      color: AppColors.surfaceHighest,
      child: Center(child: Icon(Icons.movie_rounded, color: AppColors.textMuted, size: 36)),
    );
    Widget image = placeholder;
    if (coverId != null && api != null) {
      image = CachedNetworkImage(
        imageUrl: api.coverUrl(coverId!, size: _serverSize),
        cacheKey: '$coverId-$_serverSize',
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        fadeInDuration: const Duration(milliseconds: 150),
        placeholder: (_, _) => placeholder,
        errorWidget: (_, _, _) => placeholder,
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: AspectRatio(aspectRatio: 16 / 9, child: image),
    );
  }
}

/// Video-Karte: 16:9-Vorschau mit Abspielsymbol, Titel und Künstler. Tippen öffnet den Video-Player.
class VideoCard extends ConsumerWidget {
  final Track track;

  /// Feste Breite (für horizontale Reihen) – sonst so breit wie der Platz.
  final double? width;
  final bool showDuration;
  final int titleLines;

  const VideoCard({super.key, required this.track, this.width, this.showDuration = true, this.titleLines = 1});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final card = InkWell(
      onTap: () => openVideo(context, ref, track),
      onLongPress: () => showTrackMenu(context, ref, track),
      borderRadius: BorderRadius.circular(6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            children: [
              VideoThumbnail(coverId: track.coverId),
              Positioned.fill(
                child: Center(
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.black54),
                    child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 28),
                  ),
                ),
              ),
              if (showDuration && track.duration > 0)
                Positioned(
                  right: 6,
                  bottom: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(4)),
                    child: Text(
                      formatDuration(track.length),
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            track.title,
            maxLines: titleLines,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: Colors.white),
          ),
          if (track.artistDisplay.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(track.artistDisplay, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption),
          ],
        ],
      ),
    );
    return width == null ? card : SizedBox(width: width, child: card);
  }
}

// ------------------------------------------------------------------ Rubriken

/// Symbol einer Rubrik (Server liefert Material-Symbolnamen wie "music_note").
IconData categoryIcon(String name) => switch (name) {
      'music_note' => Icons.music_note_rounded,
      'music_video' => Icons.music_video_rounded,
      'auto_stories' => Icons.auto_stories_rounded,
      'movie' => Icons.movie_rounded,
      'child_care' => Icons.child_care_rounded,
      'folder' => Icons.folder_rounded,
      'headphones' => Icons.headphones_rounded,
      'mic' => Icons.mic_rounded,
      'piano' => Icons.piano_rounded,
      'nightlife' => Icons.nightlife_rounded,
      'sports_esports' => Icons.sports_esports_rounded,
      'library_music' => Icons.library_music_rounded,
      'album' => Icons.album_rounded,
      'audiotrack' => Icons.audiotrack_rounded,
      'queue_music' => Icons.queue_music_rounded,
      'podcasts' => Icons.podcasts_rounded,
      'radio' => Icons.radio_rounded,
      'theaters' => Icons.theaters_rounded,
      'video_library' => Icons.video_library_rounded,
      'live_tv' => Icons.live_tv_rounded,
      'school' => Icons.school_rounded,
      'favorite' => Icons.favorite_rounded,
      'star' => Icons.star_rounded,
      _ => Icons.folder_rounded,
    };

const _categoryPalette = [
  Color(0xFF1E3264),
  Color(0xFF8D67AB),
  Color(0xFFE8115B),
  Color(0xFF148A08),
  Color(0xFFBA5D07),
  Color(0xFF509BF5),
  Color(0xFFAF2896),
  Color(0xFF27856A),
  Color(0xFFE13300),
  Color(0xFF477D95),
];

/// Feste Farbe pro Rubrik (wie die bunten Kacheln bei Spotify).
Color categoryColor(int categoryId) => _categoryPalette[categoryId.abs() % _categoryPalette.length];
