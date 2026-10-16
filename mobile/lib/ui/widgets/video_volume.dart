// Lautstärke im Videoplayer der Desktop-App: Regler in der Leiste des Players und Tasten (↑/↓, M) –
// auch im Vollbild. Es gilt dieselbe Lautstärke wie für die Musik (wie bei Spotify); sie bleibt für den
// nächsten Start gespeichert. Am Handy regeln die Lautstärketasten des Geräts, dort gibt es das nicht.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../player/player.dart';
import '../../player/windows_audio.dart' show windowsAudioError;
import '../desktop/desktop_shortcuts.dart' show setDesktopVolume, toggleDesktopMute, volumeProvider;

/// Schrittweite für ↑/↓ (wie Strg+↑/↓ in der übrigen App).
const _step = 0.1;

/// Für Tests: Lautstärke-Kurve der Musik vorgeben (null = wie auf dem Gerät).
@visibleForTesting
bool? debugCubicMusicVolume;

/// Unter Windows spielt libmpv die Musik und rechnet die Lautstärke kubisch um (30 % ≈ −31 dB), der
/// Videoplayer von Windows dagegen linear (30 % ≈ −10 dB).
bool get _cubicMusicVolume => debugCubicMusicVolume ?? (Platform.isWindows && windowsAudioError == null);

/// Lautstärke fürs Video: klingt bei derselben Einstellung so laut wie die Musik.
double videoGain(double volume) {
  final v = volume.clamp(0.0, 1.0);
  return _cubicMusicVolume ? v * v * v : v;
}

double _currentVolume(WidgetRef ref) => ref.read(audioHandlerProvider).player.volume.clamp(0.0, 1.0);

IconData _volumeIcon(double volume) => volume == 0
    ? Icons.volume_off_rounded
    : volume < 0.5
        ? Icons.volume_down_rounded
        : Icons.volume_up_rounded;

/// Breite des Players (für den schmalen Modus der Leiste).
class _PlayerWidth extends InheritedWidget {
  final double width;
  const _PlayerWidth({required this.width, required super.child});

  @override
  bool updateShouldNotify(_PlayerWidth oldWidget) => oldWidget.width != width;
}

/// chewie blendet die Leiste 3 s nach der letzten Mausbewegung aus – Ziehen am Regler zählt dort nicht als
/// Bewegung. Deshalb dasselbe auslösen wie eine Mausbewegung über dem Player: Leiste zeigen, Zeit neu starten.
void _keepBarVisible(BuildContext context) {
  RenderMouseRegion? region;
  context.visitAncestorElements((element) {
    if (element.widget is VideoVolumeKeys) return false;
    final render = element is RenderObjectElement ? element.renderObject : null;
    if (render is RenderMouseRegion && render.onHover != null) {
      region = render;
      return false;
    }
    return true;
  });
  region?.onHover?.call(const PointerHoverEvent());
}

/// Stummschalten und Regler – für die Leiste des Videoplayers (chewie: additionalControls). Ist der Player
/// schmal (Hochkant-Video, kleines Fenster, große Schrift), nur der Lautsprecher-Knopf – sonst läuft die
/// Leiste über; ↑/↓ gehen trotzdem.
class VideoVolumeControl extends ConsumerWidget {
  const VideoVolumeControl({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final volume = (ref.watch(volumeProvider).value ?? _currentVolume(ref)).clamp(0.0, 1.0);
    final playerWidth = context.dependOnInheritedWidgetOfExactType<_PlayerWidth>()?.width ?? double.infinity;
    final showSlider = playerWidth >= 480 + 120 * MediaQuery.textScalerOf(context).scale(1);
    // Nicht per Tab erreichbar: chewie reagiert auf Leertaste und ←/→ auch dann (sonst doppelte Wirkung).
    // Per Tastatur gibt es ↑/↓ und M.
    return ExcludeFocus(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: volume == 0 ? 'Ton an (M)' : 'Stummschalten (M)',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 28),
            iconSize: 24,
            color: Colors.white,
            icon: Icon(_volumeIcon(volume)),
            onPressed: () {
              _keepBarVisible(context);
              toggleDesktopMute(ref).ignore();
            },
          ),
          if (showSlider)
            SizedBox(
              width: 96,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                  activeTrackColor: Colors.white,
                  inactiveTrackColor: Colors.white24,
                  thumbColor: Colors.white,
                  overlayColor: Colors.white24,
                ),
                child: Slider(
                  value: volume,
                  semanticFormatterCallback: (v) => 'Lautstärke ${(v * 100).round()} %',
                  onChangeStart: (_) => _keepBarVisible(context),
                  onChanged: (v) {
                    _keepBarVisible(context);
                    setDesktopVolume(ref, v).ignore();
                  },
                  onChangeEnd: (_) => _keepBarVisible(context),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Tasten im Videoplayer: ↑/↓ lauter/leiser, M stumm – mit kurzer Anzeige im Bild. Leertaste, ←/→, F und
/// Esc übernimmt der Player selbst; Strg+↑/↓ wirkt wie überall in der App.
class VideoVolumeKeys extends ConsumerStatefulWidget {
  final Widget child;
  const VideoVolumeKeys({super.key, required this.child});

  @override
  ConsumerState<VideoVolumeKeys> createState() => _VideoVolumeKeysState();
}

class _VideoVolumeKeysState extends ConsumerState<VideoVolumeKeys> {
  /// Angezeigte Lautstärke (null = Anzeige aus).
  double? _shown;
  Timer? _hide;

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  void _show() {
    _hide?.cancel();
    setState(() => _shown = _currentVolume(ref));
    _hide = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _shown = null);
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    // Mit Strg/Alt/Umschalt gehören die Tasten der übrigen App (z. B. Strg+↑ = lauter, auch hier)
    if (keyboard.isControlPressed || keyboard.isAltPressed || keyboard.isMetaPressed || keyboard.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowUp) {
      setDesktopVolume(ref, _currentVolume(ref) + _step).ignore();
    } else if (key == LogicalKeyboardKey.arrowDown) {
      setDesktopVolume(ref, _currentVolume(ref) - _step).ignore();
    } else if (key == LogicalKeyboardKey.keyM) {
      // Gedrückt halten soll nicht dauernd umschalten
      if (event is! KeyDownEvent) return KeyEventResult.handled;
      toggleDesktopMute(ref).ignore();
    } else {
      return KeyEventResult.ignored;
    }
    // Der Player übernimmt die neue Lautstärke sofort
    _show();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: LayoutBuilder(
        builder: (context, constraints) => _PlayerWidth(
          width: constraints.maxWidth,
          child: Stack(
            fit: StackFit.expand,
            children: [
              widget.child,
              if (shown != null)
                Positioned(
                  top: 16,
                  left: 8,
                  right: 8,
                  child: IgnorePointer(
                    child: Center(
                      // Schmaler Player und große Schrift: lieber kleiner als abgeschnitten
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: DecoratedBox(
                          decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(_volumeIcon(shown), color: Colors.white, size: 20),
                                const SizedBox(width: 8),
                                Text(
                                  shown == 0 ? 'Stumm' : 'Lautstärke ${(shown * 100).round()} %',
                                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
