import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../player/player.dart';
import '../../state/connectivity.dart';
import '../../state/offline.dart';
import '../../state/settings.dart';
import '../widgets/common.dart';
import '../widgets/track_menu.dart';
import '../widgets/track_tile.dart';

// Gemeinsame Bausteine für Bibliothek, Lieblingssongs und Playlist-Seite.

/// Spielt [tracks] ab [index] ab und zeigt Probleme verständlich an
/// (z. B. „Keiner dieser Titel ist offline verfügbar.“).
Future<void> libraryPlay(
  BuildContext context,
  WidgetRef ref,
  List<Track> tracks, {
  int index = 0,
  PlayContext? playContext,
  bool shuffle = false,
}) async {
  try {
    await ref.read(playerProvider).play(tracks, index: index, context: playContext, shuffle: shuffle);
  } on StateError catch (e) {
    if (context.mounted) showMessage(context, e.message);
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

/// Läuft gerade etwas aus diesem Kontext (z. B. diese Playlist)?
/// Beobachtet Titel und Warteschlange, damit sich die Anzeige aktualisiert.
bool watchContextActive(WidgetRef ref, bool Function(PlayContext context) matches, List<Track> tracks) {
  final current = ref.watch(currentTrackProvider);
  ref.watch(queueProvider);
  final playContext = ref.watch(audioHandlerProvider).playContext;
  if (current == null || playContext == null) return false;
  return matches(playContext) && tracks.contains(current);
}

/// Nur heruntergeladene Musik verfügbar? (Offline-Modus an oder kein Netz)
bool watchOfflineRestricted(WidgetRef ref) {
  final noNetwork = ref.watch(isOfflineProvider);
  final offlineMode = ref.watch(settingsProvider.select((s) => s.offlineMode));
  return noNetwork || offlineMode;
}

/// Titel einer offline gehaltenen Sammlung, die schon auf dem Handy sind (in Sammlungs-Reihenfolge).
List<Track> offlineCollectionTracks(OfflineState offline, String key) {
  final ids = offline.collections[key] ?? const <int>[];
  return [
    for (final id in ids)
      if (offline.tracks[id] != null) offline.tracks[id]!.track,
  ];
}

/// Bis zu vier verschiedene Cover aus einer Titelliste – für ein Mosaik ohne Server.
List<String> mosaicFromTracks(List<Track> tracks) {
  final covers = <String>[];
  for (final track in tracks) {
    final cover = track.coverId;
    if (cover != null && !covers.contains(cover)) covers.add(cover);
    if (covers.length == 4) break;
  }
  return covers;
}

/// Kleinschreibung ohne Umlaute – zum Vergleichen und Suchen.
String foldText(String text) =>
    text.toLowerCase().replaceAll('ä', 'a').replaceAll('ö', 'o').replaceAll('ü', 'u').replaceAll('ß', 'ss').trim();

/// Sortierschlüssel wie im Deutschen (Umlaute einsortiert, Artikel wie „The“ ignoriert).
String sortKey(String text) => foldText(text).replaceFirst(RegExp(r'^(the|die|der|das) '), '');

// ------------------------------------------------------------------ Seitengerüst

/// Detailseite im Spotify-Stil: Farbverlauf beginnt hinter der durchsichtigen App-Leiste,
/// beim Scrollen färbt sich die Leiste ein und der Titel wird eingeblendet.
class LibraryGradientScaffold extends StatefulWidget {
  final String title;
  final Color color;
  final List<Widget> actions;
  final double collapseOffset;

  /// Baut den Inhalt; [topInset] = Statusleiste + App-Leiste (dort beginnt der sichtbare Bereich).
  final Widget Function(BuildContext context, double topInset) bodyBuilder;

  const LibraryGradientScaffold({
    super.key,
    required this.title,
    required this.color,
    required this.bodyBuilder,
    this.actions = const [],
    this.collapseOffset = 260,
  });

  @override
  State<LibraryGradientScaffold> createState() => _LibraryGradientScaffoldState();
}

class _LibraryGradientScaffoldState extends State<LibraryGradientScaffold> {
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

/// Farbverlauf von [color] nach Schwarz.
class LibraryHeaderGradient extends StatelessWidget {
  final Color color;
  final Widget child;

  const LibraryHeaderGradient({super.key, required this.color, required this.child});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color, AppColors.background],
          stops: const [0, 0.9],
        ),
      ),
      child: child,
    );
  }
}

/// Großes Cover mit Schatten für Kopfbereiche.
class HeaderCover extends StatelessWidget {
  final Widget child;
  const HeaderCover({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: DecoratedBox(
        decoration: const BoxDecoration(
          boxShadow: [BoxShadow(color: Color(0x99000000), blurRadius: 36, offset: Offset(0, 12))],
        ),
        child: child,
      ),
    );
  }
}

/// Kleine Plakette, z. B. „Gemeinsam“ oder „Privat“.
class InfoBadge extends StatelessWidget {
  final String label;
  final IconData? icon;
  final Color color;

  const InfoBadge({super.key, required this.label, this.icon, this.color = AppColors.textSecondary});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 11, color: color), const SizedBox(width: 4)],
          Text(
            label,
            style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: color, letterSpacing: 0.2),
          ),
        ],
      ),
    );
  }
}

/// Runder Avatar mit dem Anfangsbuchstaben eines Namens.
class InitialAvatar extends StatelessWidget {
  final String name;
  final double size;

  const InitialAvatar({super.key, required this.name, this.size = 32});

  static const _palette = [
    Color(0xFFE8115B),
    Color(0xFF1E3264),
    Color(0xFF8D67AB),
    Color(0xFFE13300),
    Color(0xFF148A08),
    Color(0xFF509BF5),
    Color(0xFFBA5D07),
    Color(0xFF477D95),
  ];

  @override
  Widget build(BuildContext context) {
    final trimmed = name.trim();
    final initial = trimmed.isEmpty ? '?' : trimmed.characters.first.toUpperCase();
    final color = _palette[trimmed.hashCode.abs() % _palette.length];
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: Text(
        initial,
        style: TextStyle(fontSize: size * 0.48, fontWeight: FontWeight.w800, color: Colors.white),
      ),
    );
  }
}

// ------------------------------------------------------------------ Steuerung

/// Zufallswiedergabe + großer grüner Abspielknopf. Läuft der Kontext schon,
/// wird pausiert/fortgesetzt bzw. die Zufallswiedergabe umgeschaltet.
class LibraryPlayControls extends ConsumerWidget {
  final List<Track> tracks;
  final PlayContext playContext;
  final bool Function(PlayContext context) matches;

  const LibraryPlayControls({super.key, required this.tracks, required this.playContext, required this.matches});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = watchContextActive(ref, matches, tracks);
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
                    : libraryPlay(context, ref, tracks, playContext: playContext, shuffle: true),
        ),
        const SizedBox(width: 8),
        PlayButton(
          playing: playing,
          onPressed: !playable
              ? null
              : () => active ? player.togglePlay() : libraryPlay(context, ref, tracks, playContext: playContext),
        ),
      ],
    );
  }
}

/// Download-Pfeil für Playlist/Album/Lieblingssongs: hält die Sammlung offline verfügbar
/// (grün, wenn an) und zeigt den Fortschritt als Ring.
class OfflineCollectionButton extends ConsumerWidget {
  final String collectionKey;
  final String name;
  final List<Track> tracks;

  /// Ohne Titelliste (offline) kann nur entfernt, aber nichts Neues geladen werden.
  final bool canKeep;

  const OfflineCollectionButton({
    super.key,
    required this.collectionKey,
    required this.name,
    required this.tracks,
    this.canKeep = true,
  });

  Future<void> _release(BuildContext context, WidgetRef ref) async {
    final ok = await confirm(
      context,
      title: 'Download entfernen?',
      message:
          '„$name“ ist dann nicht mehr offline verfügbar. '
          'Songs, die auch in anderen heruntergeladenen Playlists oder Alben sind, bleiben auf dem Handy.',
      confirmLabel: 'Entfernen',
      danger: true,
    );
    if (!ok) return;
    try {
      await ref.read(offlineProvider.notifier).releaseCollection(collectionKey);
      if (context.mounted) showMessage(context, 'Vom Handy entfernt');
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _keep(BuildContext context, WidgetRef ref, {bool resume = false}) async {
    final audio = tracks.where((t) => !t.isVideo).toList();
    if (audio.isEmpty) {
      showMessage(
        context,
        tracks.isEmpty
            ? 'Hier gibt es noch nichts zum Herunterladen'
            : 'Videos können nicht offline gespeichert werden',
      );
      return;
    }
    try {
      await ref.read(offlineProvider.notifier).keepCollection(collectionKey, name, audio);
      if (!context.mounted) return;
      final noNetwork = ref.read(isOfflineProvider);
      final wifiOnly = ref.read(settingsProvider).offlineWifiOnly;
      final onWifi = ref.read(isOnWifiProvider);
      if (noNetwork) {
        showMessage(context, 'Wird geladen, sobald du wieder online bist');
      } else if (wifiOnly && !onWifi) {
        showMessage(context, 'Wird geladen, sobald du im WLAN bist');
      } else {
        showMessage(
          context,
          resume ? 'Fehlende Songs werden geladen' : '${pluralSongs(audio.length)} werden aufs Handy geladen',
        );
      }
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  /// Unvollständig und nichts läuft mehr (z. B. nach Fehlern): fortsetzen oder entfernen.
  void _showStalledOptions(BuildContext context, WidgetRef ref, double progress) {
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.tileTitle),
              subtitle: Text(
                '${formatPercent(progress)} auf dem Handy – einige Songs fehlen noch',
                style: AppText.tileSubtitle,
              ),
            ),
            const Divider(),
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
              title: const Text('Download entfernen', style: TextStyle(color: AppColors.danger)),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _release(context, ref);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offline = ref.watch(offlineProvider);
    final kept = offline.isCollectionOffline(collectionKey);
    final ids = offline.collections[collectionKey] ?? const <int>[];
    final done = ids.where(offline.tracks.containsKey).length;
    final running = ids.fold<double>(0, (sum, id) => sum + (offline.progress[id] ?? 0));
    final progress = ids.isEmpty ? 1.0 : ((done + running) / ids.length).clamp(0.0, 1.0);
    final complete = kept && done >= ids.length;
    final busy = kept && !complete && ids.any(offline.isPending);

    Widget icon;
    String tooltip;
    VoidCallback? onPressed;
    if (!kept) {
      icon = const Icon(Icons.arrow_circle_down_outlined, color: AppColors.textSecondary, size: 30);
      tooltip = 'Herunterladen';
      onPressed = canKeep ? () => _keep(context, ref) : null;
    } else if (complete) {
      icon = const Icon(Icons.arrow_circle_down_rounded, color: AppColors.accent, size: 30);
      tooltip = 'Heruntergeladen';
      onPressed = () => _release(context, ref);
    } else {
      icon = SizedBox(
        width: 30,
        height: 30,
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: 27,
              height: 27,
              child: CircularProgressIndicator(
                value: progress,
                strokeWidth: 2.5,
                backgroundColor: AppColors.surfaceHighest,
                color: busy ? AppColors.accent : AppColors.textSecondary,
              ),
            ),
            Icon(Icons.arrow_downward_rounded, size: 16, color: busy ? AppColors.accent : AppColors.textSecondary),
          ],
        ),
      );
      tooltip = busy
          ? 'Wird heruntergeladen · ${formatPercent(progress)}'
          : 'Unvollständig · ${formatPercent(progress)}';
      onPressed = busy || !canKeep ? () => _release(context, ref) : () => _showStalledOptions(context, ref, progress);
    }
    return IconButton(tooltip: tooltip, onPressed: onPressed, icon: icon);
  }
}

// ------------------------------------------------------------------ Titel-Zeile

/// [TrackTile] mit Offline-Logik (nicht heruntergeladene Titel sind im Offline-Modus ausgegraut)
/// und optionaler Zusatzzeile (z. B. „Hinzugefügt von Anna“).
class LibraryTrackRow extends ConsumerWidget {
  final Track track;
  final List<Track> queue;
  final PlayContext? playContext;
  final List<TrackMenuAction> extraActions;
  final String? caption;
  final IconData captionIcon;

  const LibraryTrackRow({
    super.key,
    required this.track,
    required this.queue,
    this.playContext,
    this.extraActions = const [],
    this.caption,
    this.captionIcon = Icons.person_outline_rounded,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final restricted = watchOfflineRestricted(ref);
    final downloaded = ref.watch(isDownloadedProvider(track.id));
    final available = !restricted || (downloaded && !track.isVideo);
    Widget tile = TrackTile(
      track: track,
      queue: queue,
      context_: playContext,
      extraActions: extraActions,
      onTap: available
          ? null
          : () => showMessage(
              context,
              track.isVideo
                  ? 'Videos gibt es nur mit Verbindung zum Server'
                  : 'Dieser Song ist nicht offline verfügbar',
            ),
    );
    if (caption != null) {
      tile = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          tile,
          Transform.translate(
            offset: const Offset(0, -6),
            child: Padding(
              padding: const EdgeInsets.only(left: 80, right: 16),
              child: Row(
                children: [
                  Icon(captionIcon, size: 12, color: AppColors.textMuted),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      caption!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }
    return available ? tile : Opacity(opacity: 0.4, child: tile);
  }
}

/// Suchfeld zum Filtern innerhalb einer Liste (Lieblingssongs, Playlist).
class ListFilterField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onChanged;

  const ListFilterField({super.key, required this.controller, required this.hint, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 38,
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        style: const TextStyle(fontSize: 14, color: Colors.white),
        cursorColor: AppColors.accent,
        decoration: InputDecoration(
          hintText: hint,
          isDense: true,
          filled: true,
          fillColor: const Color(0x26FFFFFF),
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
          prefixIcon: const Icon(Icons.search_rounded, size: 20, color: Colors.white),
          prefixIconConstraints: const BoxConstraints(minWidth: 40),
          suffixIcon: ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) => value.text.isEmpty
                ? const SizedBox.shrink()
                : IconButton(
                    tooltip: 'Leeren',
                    iconSize: 18,
                    icon: const Icon(Icons.close_rounded, color: Colors.white),
                    onPressed: () {
                      controller.clear();
                      onChanged('');
                    },
                  ),
          ),
          hintStyle: const TextStyle(color: Color(0xCCFFFFFF), fontSize: 14),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
        ),
      ),
    );
  }
}

/// Passt ein Titel zum Suchtext (Titel, Künstler, Album)?
bool trackMatches(Track track, String query) {
  final q = foldText(query);
  if (q.isEmpty) return true;
  return foldText(track.title).contains(q) ||
      foldText(track.artistDisplay).contains(q) ||
      (track.album != null && foldText(track.album!.title).contains(q));
}
