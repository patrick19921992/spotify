import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../player/player.dart';
import '../../state/auth.dart';
import '../router.dart';
import '../screens/video_screen.dart' show openVideoPages;
import '../widgets/common.dart';
import 'search_focus.dart';

// Tastenkürzel der Desktop-App (wie bei Spotify).
//
// Sie stehen in MaterialApp.shortcuts – also OBERHALB der Textfeld-Kürzel. Tippt man im Suchfeld
// ein Leerzeichen, nimmt das Textfeld die Taste zuerst; nur außerhalb von Textfeldern startet/pausiert sie.

class PlayPauseIntent extends Intent {
  const PlayPauseIntent();
}

class NextTrackIntent extends Intent {
  const NextTrackIntent();
}

class PreviousTrackIntent extends Intent {
  const PreviousTrackIntent();
}

class FocusSearchIntent extends Intent {
  const FocusSearchIntent();
}

class SeekByIntent extends Intent {
  final Duration offset;
  const SeekByIntent(this.offset);
}

class VolumeByIntent extends Intent {
  final double delta;
  const VolumeByIntent(this.delta);
}

class GoBackIntent extends Intent {
  const GoBackIntent();
}

/// Windows meldet „Nächster/Vorheriger Titel“ nicht als eigene Flutter-Taste, sondern mit dem
/// Windows-Tastencode (VK_MEDIA_NEXT_TRACK 0xB0 / VK_MEDIA_PREV_TRACK 0xB1) in der Windows-Ebene.
const _windowsPlane = 0x01600000000;
const _windowsMediaNext = LogicalKeyboardKey(_windowsPlane | 0xB0);
const _windowsMediaPrevious = LogicalKeyboardKey(_windowsPlane | 0xB1);

Map<ShortcutActivator, Intent> get desktopShortcuts => <ShortcutActivator, Intent>{
      ...WidgetsApp.defaultShortcuts,
      const SingleActivator(LogicalKeyboardKey.space): const PlayPauseIntent(),
      const SingleActivator(LogicalKeyboardKey.mediaPlayPause): const PlayPauseIntent(),
      const SingleActivator(LogicalKeyboardKey.mediaTrackNext): const NextTrackIntent(),
      const SingleActivator(LogicalKeyboardKey.mediaTrackPrevious): const PreviousTrackIntent(),
      const SingleActivator(_windowsMediaNext): const NextTrackIntent(),
      const SingleActivator(_windowsMediaPrevious): const PreviousTrackIntent(),
      const SingleActivator(LogicalKeyboardKey.keyF, control: true): const FocusSearchIntent(),
      const SingleActivator(LogicalKeyboardKey.keyL, control: true): const FocusSearchIntent(),
      const SingleActivator(LogicalKeyboardKey.arrowRight, control: true): const NextTrackIntent(),
      const SingleActivator(LogicalKeyboardKey.arrowLeft, control: true): const PreviousTrackIntent(),
      const SingleActivator(LogicalKeyboardKey.arrowRight, shift: true): const SeekByIntent(Duration(seconds: 5)),
      const SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true): const SeekByIntent(Duration(seconds: -5)),
      const SingleActivator(LogicalKeyboardKey.arrowUp, control: true): const VolumeByIntent(0.1),
      const SingleActivator(LogicalKeyboardKey.arrowDown, control: true): const VolumeByIntent(-0.1),
      const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): const GoBackIntent(),
    };

/// Lautstärke (0–1) des Players.
final volumeProvider = StreamProvider<double>((ref) => ref.watch(audioHandlerProvider).player.volumeStream);

const _prefVolume = 'desktop.volume';

/// Lautstärke setzen und für den nächsten Start merken.
Future<void> setDesktopVolume(WidgetRef ref, double volume) async {
  final value = volume.clamp(0.0, 1.0);
  try {
    ref.read(sharedPreferencesProvider).setDouble(_prefVolume, value);
  } catch (_) {}
  await ref.read(audioHandlerProvider).player.setVolume(value);
}

/// Hängt die Desktop-Aktionen über alle Seiten (MaterialApp.builder): Tastenkürzel, Maus-Zurück-Taste,
/// gespeicherte Lautstärke, Fenstertitel mit dem laufenden Song.
class DesktopActions extends ConsumerStatefulWidget {
  final Widget child;
  const DesktopActions({super.key, required this.child});

  @override
  ConsumerState<DesktopActions> createState() => _DesktopActionsState();
}

class _DesktopActionsState extends ConsumerState<DesktopActions> {
  @override
  void initState() {
    super.initState();
    try {
      final saved = ref.read(sharedPreferencesProvider).getDouble(_prefVolume);
      if (saved != null) ref.read(audioHandlerProvider).player.setVolume(saved);
    } catch (_) {}
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) showMessage(context, e is StateError ? e.message : 'Etwas ist schiefgelaufen: $e');
    }
  }

  void _goBack() {
    final router = ref.read(routerProvider);
    if (router.canPop()) router.pop();
  }

  @override
  Widget build(BuildContext context) {
    final player = ref.read(playerProvider);
    return Listener(
      // Seitliche Maustaste „Zurück“
      onPointerDown: (event) {
        if (event.buttons & kBackMouseButton != 0) _goBack();
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          // Nur wenn etwas geladen ist – sonst geht die Taste normal weiter
          PlayPauseIntent: _WhenTrackLoaded<PlayPauseIntent>(ref, (_) => _run(player.togglePlay)),
          NextTrackIntent: CallbackAction<NextTrackIntent>(onInvoke: (_) => _run(player.next)),
          PreviousTrackIntent: CallbackAction<PreviousTrackIntent>(onInvoke: (_) => _run(player.previous)),
          SeekByIntent: CallbackAction<SeekByIntent>(
            onInvoke: (intent) => _run(() {
              final handler = ref.read(audioHandlerProvider);
              if (handler.currentTrack == null) return Future.value();
              final target = handler.player.position + intent.offset;
              return player.seek(target < Duration.zero ? Duration.zero : target);
            }),
          ),
          VolumeByIntent: CallbackAction<VolumeByIntent>(
            onInvoke: (intent) => setDesktopVolume(ref, ref.read(audioHandlerProvider).player.volume + intent.delta),
          ),
          FocusSearchIntent: CallbackAction<FocusSearchIntent>(
            onInvoke: (_) {
              ref.read(routerProvider).go('/search');
              // Erst nach dem Umschalten existiert das Suchfeld sicher
              WidgetsBinding.instance.addPostFrameCallback((_) => searchFocusRequests.value++);
              return null;
            },
          ),
          GoBackIntent: CallbackAction<GoBackIntent>(onInvoke: (_) => _goBack()),
        },
        child: widget.child,
      ),
    );
  }
}

class _WhenTrackLoaded<T extends Intent> extends CallbackAction<T> {
  final WidgetRef ref;
  _WhenTrackLoaded(this.ref, Object? Function(T intent) onInvoke) : super(onInvoke: onInvoke);

  // Auf der Videoseite gehört die Leertaste dem Video – sonst liefe zusätzlich die Musik los
  @override
  bool isEnabled(T intent) => ref.read(audioHandlerProvider).currentTrack != null && openVideoPages.value == 0;
}

/// Auf dem Computer lassen sich Listen (z. B. die Kartenreihen der Startseite) auch mit gedrückter Maus ziehen.
class DesktopScrollBehavior extends MaterialScrollBehavior {
  const DesktopScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {...super.dragDevices, PointerDeviceKind.mouse};
}
