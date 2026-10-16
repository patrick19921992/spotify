// Lautstärke im Videoplayer der Desktop-App: Regler in der Leiste des Players und Tasten (↑/↓, M) –
// auch im Vollbild. Es gilt dieselbe Lautstärke wie für die Musik (wie bei Spotify); sie bleibt für den
// nächsten Start gespeichert. Am Handy regeln die Lautstärketasten des Geräts, dort gibt es das nicht.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../player/player.dart';
import '../desktop/desktop_shortcuts.dart' show setDesktopVolume, volumeProvider;

/// Schrittweite für ↑/↓ (wie Strg+↑/↓ in der übrigen App).
const _step = 0.1;

/// Lautstärke vor dem Stummschalten – für „Ton an“.
double _beforeMute = 1;

double _currentVolume(WidgetRef ref) => ref.read(audioHandlerProvider).player.volume.clamp(0.0, 1.0);

void _toggleMute(WidgetRef ref) {
  final volume = _currentVolume(ref);
  if (volume > 0) _beforeMute = volume;
  setDesktopVolume(ref, volume > 0 ? 0 : _beforeMute).ignore();
}

IconData _volumeIcon(double volume) => volume == 0
    ? Icons.volume_off_rounded
    : volume < 0.5
        ? Icons.volume_down_rounded
        : Icons.volume_up_rounded;

/// Stummschalten und Regler – für die Leiste des Videoplayers (chewie: additionalControls).
class VideoVolumeControl extends ConsumerWidget {
  const VideoVolumeControl({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final volume = (ref.watch(volumeProvider).value ?? _currentVolume(ref)).clamp(0.0, 1.0);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: volume == 0 ? 'Ton an (M)' : 'Stummschalten (M)',
          padding: EdgeInsets.zero,
          iconSize: 24,
          color: Colors.white,
          icon: Icon(_volumeIcon(volume)),
          onPressed: () => _toggleMute(ref),
        ),
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
              onChanged: (v) => setDesktopVolume(ref, v).ignore(),
            ),
          ),
        ),
      ],
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

  void _set(double volume) {
    final value = volume.clamp(0.0, 1.0);
    setDesktopVolume(ref, value).ignore();
    _show(value);
  }

  void _show(double volume) {
    _hide?.cancel();
    setState(() => _shown = volume);
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
      _set(_currentVolume(ref) + _step);
    } else if (key == LogicalKeyboardKey.arrowDown) {
      _set(_currentVolume(ref) - _step);
    } else if (key == LogicalKeyboardKey.keyM) {
      // Gedrückt halten soll nicht dauernd umschalten
      if (event is KeyDownEvent) {
        final wasOn = _currentVolume(ref) > 0;
        _toggleMute(ref);
        _show(wasOn ? 0 : _beforeMute);
      }
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (shown != null)
            Positioned(
              top: 16,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: Center(
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
        ],
      ),
    );
  }
}
