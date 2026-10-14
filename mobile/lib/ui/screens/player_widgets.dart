import 'dart:async';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../player/player.dart';
import '../../state/library.dart';
import '../../state/likes.dart';
import '../widgets/common.dart';

// Gemeinsame Bausteine für Player, Warteschlange und Video.

/// Anzeigename der Quelle („Wird gespielt von …“).
String playContextLabel(PlayContext? context) {
  final title = context?.title?.trim();
  if (title != null && title.isNotEmpty) return title;
  return switch (context?.type) {
    'album' => 'Album',
    'playlist' => 'Playlist',
    'liked' => 'Lieblingssongs',
    'radio' => 'Radio',
    'search' => 'Suche',
    'mix' => 'Mix',
    'queue' => 'Warteschlange',
    'artist' => 'Künstler',
    'category' => 'Rubrik',
    _ => 'Deiner Bibliothek',
  };
}

/// „1×“, „1,25×“ …
String speedLabel(double speed) {
  final rounded = (speed * 100).round() / 100;
  final text = rounded == rounded.roundToDouble() ? '${rounded.toInt()}' : '$rounded'.replaceAll('.', ',');
  return '$text×';
}

/// Vollbild-Seite (Player, Warteschlange, Video) schließen.
void closeFullScreen(BuildContext context) {
  if (context.canPop()) {
    context.pop();
  } else {
    context.go('/home');
  }
}

/// Schließt die Vollbild-Seite und öffnet danach eine Detailseite im aktuellen Tab.
///
/// Detailseiten gehören zu den Tabs (mit unterer Leiste) – sie dürfen nicht über
/// einer Vollbild-Seite geöffnet werden, deshalb zuerst schließen.
void openAfterPop(BuildContext context, void Function(BuildContext context) open) {
  final router = GoRouter.of(context);
  final rootContext = router.routerDelegate.navigatorKey.currentContext;
  if (router.canPop()) router.pop();
  final target = rootContext != null && rootContext.mounted ? rootContext : context;
  if (target.mounted) open(target);
}

/// Führt eine Player-Aktion aus und zeigt Fehler als Meldung an.
Future<void> runPlayerAction(BuildContext context, Future<void> Function() action) async {
  try {
    await action();
  } catch (e) {
    if (!context.mounted) return;
    showMessage(context, e is StateError ? e.message : errorText(e));
  }
}

/// Herz zum Liken des Titels.
class PlayerLikeButton extends ConsumerWidget {
  final Track track;
  final double size;

  const PlayerLikeButton({super.key, required this.track, this.size = 28});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final liked = ref.watch(isTrackLikedProvider(track.id));
    return IconButton(
      iconSize: size,
      tooltip: liked ? 'Aus Lieblingssongs entfernen' : 'Zu Lieblingssongs hinzufügen',
      onPressed: () async {
        try {
          await ref.read(likesProvider.notifier).toggleTrack(track.id);
        } catch (e) {
          if (context.mounted) showError(context, e);
        }
      },
      icon: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        transitionBuilder: (child, animation) => ScaleTransition(scale: animation, child: child),
        child: Icon(
          liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
          key: ValueKey(liked),
          color: liked ? AppColors.accent : Colors.white,
        ),
      ),
    );
  }
}

/// Symbol mit grünem Punkt darunter, wenn aktiv (Zufall/Wiederholen).
class _ToggleIconButton extends StatelessWidget {
  final IconData icon;
  final bool active;
  final double size;
  final String tooltip;
  final VoidCallback onPressed;

  const _ToggleIconButton({
    required this.icon,
    required this.active,
    required this.size,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        toggled: active,
        child: InkResponse(
          onTap: onPressed,
          radius: size + 2,
          child: SizedBox(
            width: size + 22,
            height: size + 22,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: size, color: active ? AppColors.accent : Colors.white),
                const SizedBox(height: 3),
                AnimatedOpacity(
                  opacity: active ? 1 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: Container(
                    width: 4,
                    height: 4,
                    decoration: const BoxDecoration(color: AppColors.accent, shape: BoxShape.circle),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class PlayerShuffleButton extends ConsumerWidget {
  final double size;
  const PlayerShuffleButton({super.key, this.size = 26});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(playbackStateProvider).value?.shuffleMode ?? AudioServiceShuffleMode.none;
    final active = mode != AudioServiceShuffleMode.none;
    return _ToggleIconButton(
      icon: Icons.shuffle_rounded,
      active: active,
      size: size,
      tooltip: active ? 'Zufallswiedergabe ausschalten' : 'Zufallswiedergabe einschalten',
      onPressed: () => runPlayerAction(context, () => ref.read(playerProvider).toggleShuffle()),
    );
  }
}

class PlayerRepeatButton extends ConsumerWidget {
  final double size;
  const PlayerRepeatButton({super.key, this.size = 26});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(playbackStateProvider).value?.repeatMode ?? AudioServiceRepeatMode.none;
    return _ToggleIconButton(
      icon: mode == AudioServiceRepeatMode.one ? Icons.repeat_one_rounded : Icons.repeat_rounded,
      active: mode != AudioServiceRepeatMode.none,
      size: size,
      tooltip: switch (mode) {
        AudioServiceRepeatMode.none => 'Alle wiederholen',
        AudioServiceRepeatMode.one => 'Wiederholen ausschalten',
        _ => 'Diesen Song wiederholen',
      },
      onPressed: () => runPlayerAction(context, () => ref.read(playerProvider).cycleRepeat()),
    );
  }
}

/// Großer weißer Abspielknopf (schwarzes Symbol, Lade-Kreis beim Puffern).
class PlayerPlayPauseButton extends ConsumerWidget {
  final double size;
  const PlayerPlayPauseButton({super.key, this.size = 66});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(playbackStateProvider).value;
    final playing = state?.playing ?? false;
    final processing = state?.processingState;
    final loading = processing == AudioProcessingState.loading || processing == AudioProcessingState.buffering;
    return SizedBox(
      width: size,
      height: size,
      child: Material(
        color: Colors.white,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => runPlayerAction(context, () => ref.read(playerProvider).togglePlay()),
          child: Tooltip(
            message: playing ? 'Pause' : 'Abspielen',
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.black, size: size * 0.56),
                if (loading)
                  SizedBox(
                    width: size * 0.84,
                    height: size * 0.84,
                    child: const CircularProgressIndicator(strokeWidth: 2.5, color: Color(0x99000000)),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Zufall · Zurück · Abspielen · Weiter · Wiederholen
class PlayerTransportControls extends ConsumerWidget {
  final bool compact;
  const PlayerTransportControls({super.key, this.compact = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final toggleSize = compact ? 22.0 : 26.0;
    final skipSize = compact ? 34.0 : 44.0;
    final playSize = compact ? 54.0 : 68.0;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        PlayerShuffleButton(size: toggleSize),
        IconButton(
          tooltip: 'Zurück',
          iconSize: skipSize,
          color: Colors.white,
          icon: const Icon(Icons.skip_previous_rounded),
          onPressed: () => runPlayerAction(context, () => ref.read(playerProvider).previous()),
        ),
        PlayerPlayPauseButton(size: playSize),
        IconButton(
          tooltip: 'Weiter',
          iconSize: skipSize,
          color: Colors.white,
          icon: const Icon(Icons.skip_next_rounded),
          onPressed: () => runPlayerAction(context, () => ref.read(playerProvider).next()),
        ),
        PlayerRepeatButton(size: toggleSize),
      ],
    );
  }
}

/// Fortschrittsbalken zum Spulen mit Zeitangaben. Beim Ziehen springt er nicht zurück.
class PlayerSeekBar extends ConsumerStatefulWidget {
  /// Länge laut Server, falls der Player sie (noch) nicht kennt.
  final Duration fallbackDuration;

  /// Abstand der Balken-Enden zum Rand.
  final double inset;

  const PlayerSeekBar({super.key, required this.fallbackDuration, this.inset = 24});

  @override
  ConsumerState<PlayerSeekBar> createState() => _PlayerSeekBarState();
}

class _PlayerSeekBarState extends ConsumerState<PlayerSeekBar> {
  static const _overlayRadius = 14.0;

  /// Angezeigter Wert während des Ziehens bzw. bis der Player die neue Stelle meldet.
  double? _held;
  bool _dragging = false;
  Timer? _release;

  @override
  void dispose() {
    _release?.cancel();
    super.dispose();
  }

  Future<void> _seek(double value) async {
    _release?.cancel();
    setState(() {
      _dragging = false;
      _held = value;
    });
    await runPlayerAction(context, () => ref.read(playerProvider).seek(Duration(milliseconds: value.round())));
    // Spätestens nach kurzer Zeit wieder der echten Position folgen
    _release = Timer(const Duration(milliseconds: 1200), () {
      if (mounted && !_dragging) setState(() => _held = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final position = ref.watch(positionProvider).value ?? Duration.zero;
    var duration = ref.watch(durationProvider).value ?? widget.fallbackDuration;
    if (duration <= Duration.zero) duration = widget.fallbackDuration;
    final buffered = ref.watch(bufferedPositionProvider).value ?? Duration.zero;
    final max = math.max(duration.inMilliseconds.toDouble(), 1.0);

    // Nach dem Spulen: sobald der Player die neue Stelle meldet, wieder der Position folgen
    final held = _held;
    if (held != null && !_dragging && (position.inMilliseconds - held).abs() < 1500) {
      _held = null;
    }
    final value = (_held ?? position.inMilliseconds.toDouble()).clamp(0.0, max);
    final shown = Duration(milliseconds: value.round());

    final theme = SliderTheme.of(context).copyWith(
      trackHeight: 4,
      activeTrackColor: Colors.white,
      inactiveTrackColor: Colors.white.withValues(alpha: 0.22),
      secondaryActiveTrackColor: Colors.white.withValues(alpha: 0.42),
      thumbColor: Colors.white,
      overlayColor: Colors.white.withValues(alpha: 0.12),
      trackShape: const RoundedRectSliderTrackShape(),
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: _dragging ? 8 : 6),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: _overlayRadius),
    );
    final timeStyle = AppText.caption.copyWith(
      color: Colors.white.withValues(alpha: 0.7),
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: math.max(widget.inset - _overlayRadius, 0)),
          child: SliderTheme(
            data: theme,
            child: Slider(
              value: value,
              max: max,
              secondaryTrackValue: buffered.inMilliseconds.toDouble().clamp(0.0, max),
              semanticFormatterCallback: (v) => formatDuration(Duration(milliseconds: v.round())),
              onChangeStart: (v) {
                _release?.cancel();
                setState(() {
                  _dragging = true;
                  _held = v;
                });
              },
              onChanged: (v) => setState(() => _held = v),
              onChangeEnd: _seek,
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: widget.inset),
          child: Row(
            children: [
              Text(formatDuration(shown), style: timeStyle),
              const Spacer(),
              Text(formatDuration(duration), style: timeStyle),
            ],
          ),
        ),
      ],
    );
  }
}
