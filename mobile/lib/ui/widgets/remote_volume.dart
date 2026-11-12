// Lautstärke eines ferngesteuerten Geräts (nur PCs lassen sie fernsteuern): Regler mit lokal gehaltenem Wert und
// gedrosselten Befehlen – jedes onChanged als eigener Befehl liefe in die Ratenbegrenzung des Servers (10/s) und der
// Regler spränge, weil die Anzeige erst mit dem nächsten Stand des Ziels nachkommt.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../player/player.dart';
import '../screens/player_widgets.dart' show runPlayerAction;

/// Lautstärke des anderen Geräts, wie sie zuletzt gemeldet wurde (0–1).
final remoteVolumeProvider = Provider<double>((ref) => ref.watch(remoteStateProvider)?.volume ?? 0);

/// Regler für die Lautstärke des ferngesteuerten Geräts.
class RemoteVolumeSlider extends ConsumerStatefulWidget {
  /// Höchstens so oft geht beim Ziehen ein Befehl raus (4/s – weit unter der Grenze des Servers).
  static const sendEvery = Duration(milliseconds: 250);

  /// So lange bleibt nach dem Loslassen der eigene Wert stehen, bis der neue Stand des Ziels da ist.
  static const holdAfterRelease = Duration(milliseconds: 1500);

  const RemoteVolumeSlider({super.key});

  @override
  ConsumerState<RemoteVolumeSlider> createState() => _RemoteVolumeSliderState();
}

class _RemoteVolumeSliderState extends ConsumerState<RemoteVolumeSlider> {
  double? _held;
  double? _unsent;
  Timer? _throttle;
  Timer? _release;

  @override
  void dispose() {
    _throttle?.cancel();
    _release?.cancel();
    super.dispose();
  }

  /// Beim Ziehen: Fehler (z. B. „zu viele Befehle“) nicht anzeigen – der Wert beim Loslassen zählt.
  void _sendQuietly(double value) => ref.read(playerProvider).setVolume(value).catchError((Object _) {});

  void _flush() {
    final value = _unsent;
    if (value == null) {
      _throttle?.cancel();
      _throttle = null;
      return;
    }
    _unsent = null;
    _sendQuietly(value);
  }

  void _onChanged(double value) {
    _release?.cancel();
    _release = null;
    setState(() => _held = value);
    _unsent = value;
    if (_throttle == null) {
      _flush();
      _throttle = Timer.periodic(RemoteVolumeSlider.sendEvery, (_) => _flush());
    }
  }

  void _onChangeEnd(double value) {
    _throttle?.cancel();
    _throttle = null;
    _unsent = null;
    setState(() => _held = value);
    runPlayerAction(context, () => ref.read(playerProvider).setVolume(value));
    _release = Timer(RemoteVolumeSlider.holdAfterRelease, () {
      _release = null;
      if (mounted) setState(() => _held = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final double remote = ref.watch(remoteVolumeProvider);
    final value = (_held ?? remote).clamp(0.0, 1.0);
    return Slider(
      value: value,
      semanticFormatterCallback: (v) => 'Lautstärke ${(v * 100).round()} %',
      onChanged: _onChanged,
      onChangeEnd: _onChangeEnd,
    );
  }
}

/// Zeile im Vollbild-Player am Handy: Lautstärke des ferngesteuerten PCs (nur, wenn er das kann).
class RemoteVolumeRow extends ConsumerWidget {
  const RemoteVolumeRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!(ref.watch(remoteDeviceProvider)?.canVolume ?? false)) return const SizedBox.shrink();
    return Row(
      children: [
        IconButton(
          tooltip: 'Leiser',
          icon: const Icon(Icons.volume_down_rounded),
          onPressed: () => runPlayerAction(
              context, () => ref.read(playerProvider).setVolume((ref.read(remoteVolumeProvider) - 0.1).clamp(0.0, 1.0))),
        ),
        const Expanded(child: RemoteVolumeSlider()),
        IconButton(
          tooltip: 'Lauter',
          icon: const Icon(Icons.volume_up_rounded),
          onPressed: () => runPlayerAction(
              context, () => ref.read(playerProvider).setVolume((ref.read(remoteVolumeProvider) + 0.1).clamp(0.0, 1.0))),
        ),
      ],
    );
  }
}
