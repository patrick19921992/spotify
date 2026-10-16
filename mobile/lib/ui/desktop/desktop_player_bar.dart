import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/models.dart';
import '../../player/player.dart';
import '../nav.dart';
import '../screens/player_widgets.dart';
import '../widgets/cover.dart';
import 'desktop_layout.dart';
import 'desktop_shell.dart';
import 'desktop_shortcuts.dart';

/// Player-Leiste über die ganze Fensterbreite (Desktop): Titel · Steuerung mit Fortschritt · Extras.
class DesktopPlayerBar extends ConsumerWidget {
  const DesktopPlayerBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(currentTrackProvider);
    // Größere Schrift (Windows: Einstellungen → Barrierefreiheit → Textgröße) macht die Zeitangaben höher
    final textExtra = (MediaQuery.textScalerOf(context).scale(17) - 17).clamp(0.0, 40.0);
    return Material(
      color: Colors.black,
      child: SizedBox(
        height: kPlayerBarHeight + textExtra,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(flex: 3, child: track == null ? const SizedBox.shrink() : _TrackInfo(track: track)),
              Expanded(
                flex: 4,
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 720),
                    child: _Controls(track: track),
                  ),
                ),
              ),
              const Expanded(flex: 3, child: _Extras()),
            ],
          ),
        ),
      ),
    );
  }
}

class _TrackInfo extends StatelessWidget {
  final Track track;
  const _TrackInfo({required this.track});

  @override
  Widget build(BuildContext context) {
    final album = track.album;
    return Row(
      children: [
        Tooltip(
          message: 'Jetzt läuft (Vollbild)',
          child: InkWell(
            onTap: () => Nav.player(context),
            borderRadius: BorderRadius.circular(4),
            child: CoverImage(coverId: track.coverId, size: 56),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InkWell(
                onTap: album == null ? null : () => Nav.album(context, album.id),
                child: Text(
                  track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                ),
              ),
              const SizedBox(height: 2),
              InkWell(
                onTap: track.artists.isEmpty ? null : () => Nav.artist(context, track.artists.first.id),
                child: Text(
                  track.artistDisplay,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.caption,
                ),
              ),
            ],
          ),
        ),
        PlayerLikeButton(track: track, size: 22),
      ],
    );
  }
}

class _Controls extends ConsumerWidget {
  final Track? track;
  const _Controls({required this.track});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = track;
    final player = ref.read(playerProvider);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IgnorePointer(
          ignoring: current == null,
          child: Opacity(
            opacity: current == null ? 0.4 : 1,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const PlayerShuffleButton(size: 20),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Zurück',
                  iconSize: 28,
                  icon: const Icon(Icons.skip_previous_rounded),
                  onPressed: () => runPlayerAction(context, player.previous),
                ),
                const SizedBox(width: 8),
                const PlayerPlayPauseButton(size: 38),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Weiter',
                  iconSize: 28,
                  icon: const Icon(Icons.skip_next_rounded),
                  onPressed: () => runPlayerAction(context, player.next),
                ),
                const SizedBox(width: 8),
                const PlayerRepeatButton(size: 20),
              ],
            ),
          ),
        ),
        if (current != null) PlayerSeekBar(fallbackDuration: current.length, inset: 14) else const SizedBox(height: 44),
      ],
    );
  }
}

/// Songtext, Warteschlange, Lautstärke, Vollbild.
class _Extras extends ConsumerWidget {
  const _Extras();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final panel = ref.watch(desktopPanelProvider);
    final panels = ref.read(desktopPanelProvider.notifier);
    // Die rechte Spalte gibt es nur in der Hauptansicht – auf Vollbildseiten (z. B. Downloads) nicht
    final inShell = context.findAncestorWidgetOfExactType<DesktopShell>() != null;
    Color colorFor(DesktopPanel p) => panel == p ? AppColors.accent : Colors.white;
    return LayoutBuilder(
      builder: (context, constraints) => Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (inShell) ...[
            IconButton(
              tooltip: 'Songtext',
              icon: Icon(Icons.lyrics_outlined, color: colorFor(DesktopPanel.lyrics)),
              onPressed: () => panels.toggle(DesktopPanel.lyrics),
            ),
            IconButton(
              tooltip: 'Warteschlange',
              icon: Icon(Icons.queue_music_rounded, color: colorFor(DesktopPanel.queue)),
              onPressed: () => panels.toggle(DesktopPanel.queue),
            ),
          ],
          _Volume(showSlider: constraints.maxWidth >= 290),
          IconButton(
            tooltip: 'Vollbild',
            icon: const Icon(Icons.open_in_full_rounded, size: 20),
            onPressed: () => Nav.player(context),
          ),
        ],
      ),
    );
  }
}

class _Volume extends ConsumerStatefulWidget {
  final bool showSlider;
  const _Volume({required this.showSlider});

  @override
  ConsumerState<_Volume> createState() => _VolumeState();
}

class _VolumeState extends ConsumerState<_Volume> {
  @override
  Widget build(BuildContext context) {
    final volume = ref.watch(volumeProvider).value ?? ref.read(audioHandlerProvider).player.volume;
    final icon = volume == 0
        ? Icons.volume_off_rounded
        : volume < 0.5
            ? Icons.volume_down_rounded
            : Icons.volume_up_rounded;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: volume == 0 ? 'Ton an' : 'Stummschalten',
          icon: Icon(icon),
          onPressed: () => toggleDesktopMute(ref),
        ),
        if (widget.showSlider)
          SizedBox(
            width: 110,
            child: Slider(
              value: volume.clamp(0.0, 1.0),
              semanticFormatterCallback: (v) => 'Lautstärke ${(v * 100).round()} %',
              onChanged: (v) => setDesktopVolume(ref, v),
            ),
          ),
      ],
    );
  }
}
