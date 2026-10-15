import 'package:audio_service/audio_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../player/player.dart';
import '../../state/auth.dart';
import '../../state/connectivity.dart';
import '../../state/offline.dart';
import '../../state/settings.dart';
import '../nav.dart';
import '../widgets/common.dart';
import '../widgets/track_menu.dart';
import '../widgets/track_tile.dart';

// Gemeinsame Bausteine für die Album- und Künstlerseite.

// ------------------------------------------------------------------ Hilfen

/// Nur heruntergeladene Musik verfügbar? (Offline-Modus an oder kein Netz) – beobachtet.
bool watchDetailRestricted(WidgetRef ref) {
  final noNetwork = ref.watch(isOfflineProvider);
  final offlineMode = ref.watch(settingsProvider.select((s) => s.offlineMode));
  return noNetwork || offlineMode;
}

/// Wie [watchDetailRestricted], aber einmalig gelesen (für Aktionen).
bool readDetailRestricted(WidgetRef ref) => ref.read(isOfflineProvider) || ref.read(settingsProvider).offlineMode;

/// Warum ein Titel gerade nicht abgespielt werden kann (Offline-Modus/kein Netz).
String detailUnavailableMessage(WidgetRef ref, Track track) {
  if (!track.isVideo) return 'Dieser Song ist nicht auf deinem Handy';
  return ref.read(isOfflineProvider)
      ? 'Videos gibt es nur mit Verbindung'
      : 'Im Offline-Modus sind Videos nicht verfügbar';
}

/// Spielt [tracks] ab [index] ab und zeigt Probleme verständlich an
/// (z. B. „Keiner dieser Titel ist offline verfügbar.“).
Future<void> detailPlay(
  BuildContext context,
  WidgetRef ref,
  List<Track> tracks, {
  int index = 0,
  PlayContext? playContext,
  bool shuffle = false,
}) async {
  if (!tracks.any((t) => !t.isVideo)) {
    showMessage(context, 'Hier gibt es nichts zum Abspielen');
    return;
  }
  try {
    await ref.read(playerProvider).play(tracks, index: index, context: playContext, shuffle: shuffle);
  } on StateError catch (e) {
    if (context.mounted) showMessage(context, e.message);
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

/// Songs an die Warteschlange hängen ([next] = direkt nach dem aktuellen Titel).
/// Offline werden nur Songs genommen, die auf dem Handy sind.
Future<void> detailEnqueue(BuildContext context, WidgetRef ref, List<Track> tracks, {bool next = false}) async {
  var audio = tracks.where((t) => !t.isVideo).toList();
  if (audio.isEmpty) {
    showMessage(context, 'Hier gibt es keine Songs für die Warteschlange');
    return;
  }
  if (readDetailRestricted(ref)) {
    final offline = ref.read(offlineProvider);
    audio = audio.where((t) => offline.isDownloaded(t.id)).toList();
    if (audio.isEmpty) {
      showMessage(context, 'Keiner dieser Songs ist auf deinem Handy');
      return;
    }
  }
  final player = ref.read(playerProvider);
  try {
    if (next) {
      await player.playNext(audio);
    } else {
      await player.addToQueue(audio);
    }
    if (!context.mounted) return;
    showMessage(
      context,
      next
          ? (audio.length == 1 ? 'Wird als Nächstes gespielt' : '${pluralSongs(audio.length)} werden als Nächstes gespielt')
          : '${pluralSongs(audio.length)} zur Warteschlange hinzugefügt',
    );
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

/// Video öffnen – Musik wird dafür angehalten (Videos laufen nie über den Audio-Player).
void detailOpenVideo(BuildContext context, WidgetRef ref, Track track) {
  if (readDetailRestricted(ref)) {
    showMessage(context, detailUnavailableMessage(ref, track));
    return;
  }
  ref.read(audioHandlerProvider).pause();
  Nav.video(context, track);
}

/// Läuft gerade etwas aus diesem Kontext (z. B. dieses Album)?
/// Beobachtet Titel und Warteschlange, damit sich die Anzeige aktualisiert.
bool watchDetailContextActive(WidgetRef ref, String type, int id) {
  final current = ref.watch(currentTrackProvider);
  ref.watch(queueProvider);
  final playContext = ref.watch(audioHandlerProvider).playContext;
  if (current == null || playContext == null) return false;
  return playContext.type == type && playContext.id == id;
}

/// Menü als Blatt von unten: Kopfzeile, Trennlinie, Einträge.
Future<void> showDetailSheet(
  BuildContext context, {
  required Widget header,
  required List<Widget> Function(BuildContext sheetContext) builder,
}) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [header, const Divider(), ...builder(sheetContext), const SizedBox(height: 8)],
        ),
      ),
    ),
  );
}

// ------------------------------------------------------------------ Seitengerüst

/// Detailseite im Spotify-Stil: Farbverlauf beginnt hinter der durchsichtigen App-Leiste,
/// beim Scrollen färbt sich die Leiste ein und der Titel wird eingeblendet.
class DetailScaffold extends StatefulWidget {
  final String title;
  final Color color;
  final List<Widget> actions;

  /// Ab dieser Scroll-Position gilt der Kopfbereich als eingeklappt.
  final double collapseOffset;

  /// Baut den Inhalt; [topInset] = Statusleiste + App-Leiste (dort beginnt der sichtbare Bereich).
  final Widget Function(BuildContext context, double topInset) bodyBuilder;

  const DetailScaffold({
    super.key,
    required this.title,
    required this.color,
    required this.bodyBuilder,
    this.actions = const [],
    this.collapseOffset = 280,
  });

  @override
  State<DetailScaffold> createState() => _DetailScaffoldState();
}

class _DetailScaffoldState extends State<DetailScaffold> {
  bool _collapsed = false;

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0 || notification.metrics.axis != Axis.vertical) return false;
    final collapsed = notification.metrics.pixels > widget.collapseOffset;
    if (collapsed != _collapsed) setState(() => _collapsed = collapsed);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        scrolledUnderElevation: 0,
        flexibleSpace: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          color: _collapsed ? darken(widget.color, 0.22) : Colors.transparent,
        ),
        title: AnimatedOpacity(
          opacity: _collapsed ? 1 : 0,
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
        child: Builder(builder: (context) => widget.bodyBuilder(context, MediaQuery.paddingOf(context).top)),
      ),
    );
  }
}

/// Hinweis im Kopfbereich, z. B. „Keine Verbindung – du siehst die heruntergeladene Version.“
class DetailNotice extends StatelessWidget {
  final String text;
  final IconData icon;
  final VoidCallback? onRetry;

  const DetailNotice({super.key, required this.text, this.icon = Icons.cloud_off_rounded, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 14, color: AppColors.textSecondary),
        const SizedBox(width: 6),
        Expanded(child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.caption)),
        if (onRetry != null)
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            child: const Text('Erneut versuchen', style: TextStyle(color: AppColors.accent, fontWeight: FontWeight.w600)),
          ),
      ],
    );
  }
}

/// Kleine Fehlermeldung für einen einzelnen Abschnitt (z. B. „Mehr von …“).
class DetailInlineError extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;

  const DetailInlineError({super.key, required this.message, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded, color: AppColors.textSecondary, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(message, maxLines: 3, overflow: TextOverflow.ellipsis, style: AppText.tileSubtitle)),
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

// ------------------------------------------------------------------ Steuerung

/// Zufallswiedergabe + großer grüner Abspielknopf. Läuft der Kontext schon,
/// wird pausiert/fortgesetzt bzw. die Zufallswiedergabe umgeschaltet.
class DetailPlayControls extends ConsumerWidget {
  final List<Track> tracks;
  final PlayContext playContext;

  const DetailPlayControls({super.key, required this.tracks, required this.playContext});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = playContext.id;
    final active = id != null && watchDetailContextActive(ref, playContext.type, id);
    final playing = active && ref.watch(isPlayingProvider);
    final shuffleOn = active && ref.watch(playbackStateProvider).value?.shuffleMode == AudioServiceShuffleMode.all;
    final player = ref.read(playerProvider);
    final playable = tracks.any((t) => !t.isVideo);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: shuffleOn ? 'Zufallswiedergabe aus' : 'Zufällig abspielen',
          iconSize: 28,
          icon: Icon(Icons.shuffle_rounded, color: shuffleOn ? AppColors.accent : AppColors.textSecondary),
          onPressed: !playable
              ? null
              : () => active
                    ? player.toggleShuffle()
                    : detailPlay(context, ref, tracks, playContext: playContext, shuffle: true),
        ),
        const SizedBox(width: 8),
        PlayButton(
          playing: playing,
          onPressed: !playable
              ? null
              : () => active ? player.togglePlay() : detailPlay(context, ref, tracks, playContext: playContext),
        ),
      ],
    );
  }
}

/// Download-Pfeil für ein Album: hält es offline verfügbar (grün, wenn komplett auf dem Handy)
/// und zeigt den Fortschritt als Ring.
class DetailOfflineButton extends ConsumerWidget {
  final String collectionKey;
  final String name;
  final List<Track> tracks;

  /// Ohne vollständige Titelliste (offline) kann nur entfernt, aber nichts Neues geladen werden.
  final bool canKeep;

  const DetailOfflineButton({
    super.key,
    required this.collectionKey,
    required this.name,
    required this.tracks,
    this.canKeep = true,
  });

  Future<void> _keep(BuildContext context, WidgetRef ref, {bool resume = false}) async {
    final audio = tracks.where((t) => !t.isVideo).toList();
    if (audio.isEmpty) {
      showMessage(
        context,
        tracks.isEmpty ? 'Hier gibt es noch nichts, was aufs Gerät geladen werden kann' : 'Videos können nicht aufs Handy geladen werden',
      );
      return;
    }
    try {
      await ref.read(offlineProvider.notifier).keepCollection(collectionKey, name, audio);
      if (!context.mounted) return;
      final noNetwork = ref.read(isOfflineProvider);
      final wifiOnly = ref.read(settingsProvider).offlineWifiOnly;
      final onWifi = ref.read(isOnWifiProvider);
      final String message;
      if (noNetwork) {
        message = 'Wird geladen, sobald du wieder online bist';
      } else if (wifiOnly && !onWifi) {
        message = 'Wird geladen, sobald du im WLAN bist';
      } else {
        message = resume ? 'Fehlende Songs werden geladen' : '${pluralSongs(audio.length)} werden aufs Handy geladen';
      }
      showMessage(context, message);
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _release(BuildContext context, WidgetRef ref) async {
    final ok = await confirm(
      context,
      title: 'Vom Gerät entfernen?',
      message: '„$name“ ist dann nicht mehr offline verfügbar. '
          'Songs, die auch in anderen Alben oder Playlists auf diesem Gerät sind, bleiben erhalten.',
      confirmLabel: 'Entfernen',
      danger: true,
    );
    if (!ok || !context.mounted) return;
    try {
      await ref.read(offlineProvider.notifier).releaseCollection(collectionKey);
      if (context.mounted) showMessage(context, 'Vom Handy entfernt');
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  void _showProgress(BuildContext context, WidgetRef ref, double progress, bool busy) {
    showDetailSheet(
      context,
      header: ListTile(
        leading: const Icon(Icons.download_for_offline_outlined, color: AppColors.accent),
        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.tileTitle),
        subtitle: Text(
          busy
              ? '${formatPercent(progress)} auf dem Handy – wird geladen …'
              : '${formatPercent(progress)} auf dem Handy – einige Songs fehlen noch',
          style: AppText.tileSubtitle,
        ),
      ),
      builder: (sheetContext) => [
        if (!busy && canKeep)
          ListTile(
            leading: const Icon(Icons.refresh_rounded),
            title: const Text('Fehlende Songs laden'),
            onTap: () {
              Navigator.of(sheetContext).pop();
              _keep(context, ref, resume: true);
            },
          ),
        ListTile(
          leading: const Icon(Icons.delete_outline_rounded, color: AppColors.danger),
          title: Text(
            busy ? 'Laden abbrechen' : 'Vom Gerät entfernen',
            style: const TextStyle(color: AppColors.danger),
          ),
          onTap: () {
            Navigator.of(sheetContext).pop();
            _release(context, ref);
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offline = ref.watch(offlineProvider);
    if (!offline.isCollectionOffline(collectionKey)) {
      return IconButton(
        tooltip: 'Aufs Handy laden',
        iconSize: 28,
        icon: const Icon(Icons.arrow_circle_down_outlined, color: AppColors.textSecondary),
        onPressed: canKeep ? () => _keep(context, ref) : null,
      );
    }
    final ids = offline.collections[collectionKey] ?? const <int>[];
    final done = ids.where(offline.tracks.containsKey).length;
    if (done >= ids.length) {
      return IconButton(
        tooltip: 'Auf dem Handy – tippen zum Entfernen',
        iconSize: 28,
        icon: const Icon(Icons.arrow_circle_down_rounded, color: AppColors.accent),
        onPressed: () => _release(context, ref),
      );
    }
    final running = ids.fold<double>(0, (sum, id) => sum + (offline.progress[id] ?? 0));
    final progress = (offline.collectionProgress(collectionKey) + running / ids.length).clamp(0.0, 1.0);
    final busy = ids.any(offline.isPending);
    final color = busy ? AppColors.accent : AppColors.textSecondary;
    return IconButton(
      tooltip: '${formatPercent(progress)} auf dem Handy',
      onPressed: () => _showProgress(context, ref, progress, busy),
      icon: SizedBox(
        width: 26,
        height: 26,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: CircularProgressIndicator(
                value: progress,
                strokeWidth: 2.5,
                backgroundColor: AppColors.surfaceHighest,
                color: color,
              ),
            ),
            Icon(busy ? Icons.arrow_downward_rounded : Icons.priority_high_rounded, size: 14, color: color),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ Titel

/// [TrackTile] mit Offline-Logik: Im Offline-Modus bzw. ohne Netz werden Titel, die nicht
/// auf dem Handy sind, abgeblendet und erklären beim Antippen, warum sie nicht laufen.
/// Mit [rank] steht davor die Platzierung (für „Beliebt“).
class DetailTrackTile extends ConsumerWidget {
  final Track track;
  final List<Track> queue;
  final PlayContext playContext;
  final bool showNumber;
  final bool showCover;
  final int? rank;

  const DetailTrackTile({
    super.key,
    required this.track,
    required this.queue,
    required this.playContext,
    this.showNumber = false,
    this.showCover = true,
    this.rank,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final restricted = watchDetailRestricted(ref);
    final downloaded = ref.watch(isDownloadedProvider(track.id));
    final available = !restricted || (downloaded && !track.isVideo);

    Widget tile = TrackTile(
      track: track,
      queue: queue,
      context_: playContext,
      showNumber: showNumber,
      showCover: showCover,
      onTap: available ? null : () => showMessage(context, detailUnavailableMessage(ref, track)),
    );

    final position = rank;
    if (position != null) {
      final isCurrent = ref.watch(isCurrentTrackProvider(track.id));
      final playing = isCurrent && ref.watch(isPlayingProvider);
      tile = Row(
        children: [
          SizedBox(
            width: 44,
            child: Center(
              child: playing
                  ? const Icon(Icons.graphic_eq_rounded, color: AppColors.accent, size: 18)
                  : Text(
                      '$position',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: isCurrent ? AppColors.accent : AppColors.textSecondary,
                      ),
                    ),
            ),
          ),
          Expanded(
            child: ListTileTheme.merge(
              contentPadding: const EdgeInsetsDirectional.only(end: 4),
              child: tile,
            ),
          ),
        ],
      );
    }
    return available ? tile : Opacity(opacity: 0.4, child: tile);
  }
}

// ------------------------------------------------------------------ Videos

/// Vorschaubild eines Videos im 16:9-Format (Cover vom Server, zwischengespeichert).
class DetailVideoThumbnail extends ConsumerWidget {
  final String? coverId;
  final double width;
  final double radius;

  const DetailVideoThumbnail({super.key, required this.coverId, required this.width, this.radius = 6});

  /// Gleiche Größe/Cache-Schlüssel wie CoverImage bei großen Covern.
  static const _serverSize = 600;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(apiProvider);
    final height = width * 9 / 16;
    final placeholder = Container(
      width: width,
      height: height,
      color: AppColors.surfaceHighest,
      alignment: Alignment.center,
      child: const Icon(Icons.movie_rounded, color: AppColors.textMuted, size: 36),
    );
    Widget image = placeholder;
    if (coverId != null && api != null) {
      image = CachedNetworkImage(
        imageUrl: api.coverUrl(coverId!, size: _serverSize),
        cacheKey: '$coverId-$_serverSize',
        width: width,
        height: height,
        fit: BoxFit.cover,
        fadeInDuration: const Duration(milliseconds: 150),
        placeholder: (_, _) => placeholder,
        errorWidget: (_, _, _) => placeholder,
      );
    }
    return ClipRRect(borderRadius: BorderRadius.circular(radius), child: image);
  }
}

/// Video-Karte: 16:9-Vorschau mit Abspielsymbol und Dauer, darunter Titel. Tippen öffnet den Video-Player.
class DetailVideoCard extends ConsumerWidget {
  final Track track;
  final double width;

  const DetailVideoCard({super.key, required this.track, this.width = 240});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final restricted = watchDetailRestricted(ref);
    final subtitle = ['Video', if (track.year != null) '${track.year}'].join(' · ');
    final card = SizedBox(
      width: width,
      child: InkWell(
        onTap: () => detailOpenVideo(context, ref, track),
        onLongPress: () => showTrackMenu(context, ref, track),
        borderRadius: BorderRadius.circular(6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                DetailVideoThumbnail(coverId: track.coverId, width: width),
                Positioned.fill(
                  child: Center(
                    child: Container(
                      width: 42,
                      height: 42,
                      decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.black54),
                      child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 30),
                    ),
                  ),
                ),
                if (track.duration > 0)
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
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: Colors.white),
            ),
            const SizedBox(height: 2),
            Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption),
          ],
        ),
      ),
    );
    return restricted ? Opacity(opacity: 0.4, child: card) : card;
  }
}

/// Horizontale Reihe von Video-Karten (Höhe passt sich der Systemschrift an).
class DetailVideoRow extends StatelessWidget {
  final List<Track> videos;
  final double cardWidth;

  const DetailVideoRow({super.key, required this.videos, this.cardWidth = 240});

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final textHeight = scaler.scale(13.5) * 1.4 * 2 + 2 + scaler.scale(12) * 1.45;
    final height = cardWidth * 9 / 16 + 8 + textHeight + 6;
    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: videos.length,
        separatorBuilder: (_, _) => const SizedBox(width: 14),
        itemBuilder: (_, index) => DetailVideoCard(track: videos[index], width: cardWidth),
      ),
    );
  }
}
