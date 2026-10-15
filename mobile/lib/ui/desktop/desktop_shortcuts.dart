import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../player/player.dart';
import '../../player/windows_media_controls.dart' show windowsMediaControlsActive;
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

bool _isSpace(ShortcutActivator activator) =>
    activator is SingleActivator && activator.trigger == LogicalKeyboardKey.space;

/// Windows meldet „Nächster/Vorheriger Titel“ nicht als eigene Flutter-Taste, sondern mit dem
/// Windows-Tastencode (VK_MEDIA_NEXT_TRACK 0xB0 / VK_MEDIA_PREV_TRACK 0xB1) in der Windows-Ebene.
const _windowsPlane = 0x01600000000;
const _windowsMediaNext = LogicalKeyboardKey(_windowsPlane | 0xB0);
const _windowsMediaPrevious = LogicalKeyboardKey(_windowsPlane | 0xB1);

Map<ShortcutActivator, Intent> get desktopShortcuts => <ShortcutActivator, Intent>{
      // Standard-Kürzel ohne „Leertaste = Knopf betätigen“ – das übernimmt PlayPauseIntent (siehe _PlayPauseAction)
      for (final entry in WidgetsApp.defaultShortcuts.entries)
        if (!_isSpace(entry.key)) entry.key: entry.value,
      // Gedrückt halten soll nicht dauernd umschalten
      const SingleActivator(LogicalKeyboardKey.space, includeRepeats: false): const PlayPauseIntent(),
      // Medientasten nur hier, wenn die Windows-Medienübersicht fehlt – sonst kommen sie über Windows
      // (auch ohne Fokus) und würden im Fenster doppelt umschalten
      if (!windowsMediaControlsActive) ...{
        const SingleActivator(LogicalKeyboardKey.mediaPlayPause, includeRepeats: false): const PlayPauseIntent(),
        const SingleActivator(LogicalKeyboardKey.mediaTrackNext): const NextTrackIntent(),
        const SingleActivator(LogicalKeyboardKey.mediaTrackPrevious): const PreviousTrackIntent(),
        const SingleActivator(_windowsMediaNext): const NextTrackIntent(),
        const SingleActivator(_windowsMediaPrevious): const PreviousTrackIntent(),
      },
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

  // Wie die Zurück-Taste am Handy: beachtet PopScope (z. B. „Reihenfolge ändern“ beenden statt Seite schließen)
  void _goBack() => ref.read(routerProvider).routerDelegate.popRoute().ignore();

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
          // Hat ein Knopf/Schalter den Tastaturfokus, betätigt die Leertaste ihn (wie überall unter Windows);
          // sonst Abspielen/Pause, sofern etwas geladen ist
          PlayPauseIntent: _PlayPauseAction(ref, () => _run(player.togglePlay)),
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
          FocusSearchIntent: _WhenNoPopup<FocusSearchIntent>(
            (_) {
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

/// Leertaste/Medientaste: betätigt den fokussierten Knopf – sonst Abspielen/Pause.
class _PlayPauseAction extends Action<PlayPauseIntent> {
  final WidgetRef ref;
  final VoidCallback togglePlay;
  _PlayPauseAction(this.ref, this.togglePlay);

  /// Kontext des Knopfs/Schalters mit Tastaturfokus, der sich per Leertaste betätigen lässt – sonst null.
  BuildContext? _focusedControl() {
    final focus = FocusManager.instance.primaryFocus;
    final context = focus?.context;
    if (focus == null || focus is FocusScopeNode || context == null) return null;
    final action = Actions.maybeFind<ActivateIntent>(context);
    return action != null && action.isActionEnabled ? context : null;
  }

  // Auf der Videoseite gehört die Leertaste dem Video – sonst liefe zusätzlich die Musik los
  bool get _canToggle => ref.read(audioHandlerProvider).currentTrack != null && openVideoPages.value == 0;

  @override
  bool isEnabled(PlayPauseIntent intent) => _focusedControl() != null || _canToggle;

  @override
  Object? invoke(PlayPauseIntent intent) {
    final control = _focusedControl();
    if (control != null) return Actions.invoke(control, const ActivateIntent());
    if (_canToggle) togglePlay();
    return null;
  }
}

/// Nur, wenn kein Dialog/Menü offen ist (sonst landete z. B. getippter Text unsichtbar im Suchfeld dahinter).
class _WhenNoPopup<T extends Intent> extends CallbackAction<T> {
  _WhenNoPopup(Object? Function(T intent) onInvoke) : super(onInvoke: onInvoke);

  @override
  bool isEnabled(T intent) {
    final context = FocusManager.instance.primaryFocus?.context;
    return context == null || ModalRoute.of(context) is! PopupRoute;
  }
}
