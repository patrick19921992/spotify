import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../state/library.dart';

/// Kurze Meldung unten einblenden.
void showMessage(BuildContext context, String text, {SnackBarAction? action}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  messenger?.hideCurrentSnackBar();
  messenger?.showSnackBar(SnackBar(content: Text(text), action: action, duration: const Duration(seconds: 3)));
}

/// Fehler als Meldung anzeigen.
void showError(BuildContext context, Object error) => showMessage(context, errorText(error));

/// Ja/Nein-Abfrage. Liefert true bei Bestätigung.
Future<bool> confirm(BuildContext context, {required String title, String? message, String confirmLabel = 'OK', bool danger = false}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: message == null ? null : Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Abbrechen')),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirmLabel, style: TextStyle(color: danger ? AppColors.danger : AppColors.accent)),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// Texteingabe-Dialog (z. B. Playlist umbenennen).
Future<String?> promptText(BuildContext context,
    {required String title, String initial = '', String hint = '', String confirmLabel = 'Speichern'}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: InputDecoration(hintText: hint),
        onSubmitted: (value) => Navigator.pop(context, value.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Abbrechen')),
        TextButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: Text(confirmLabel)),
      ],
    ),
  );
}

/// Lade-/Fehler-/Daten-Anzeige für FutureProvider-Werte, mit "Erneut versuchen".
class AsyncBody<T> extends StatelessWidget {
  final AsyncValue<T> value;
  final Widget Function(T data) builder;
  final VoidCallback? onRetry;

  const AsyncBody({super.key, required this.value, required this.builder, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return value.when(
      data: builder,
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => ErrorView(message: errorText(error), onRetry: onRetry),
      skipLoadingOnRefresh: true,
      skipLoadingOnReload: true,
    );
  }
}

class ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;
  const ErrorView({super.key, required this.message, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 48, color: AppColors.textSecondary),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.textSecondary)),
            if (onRetry != null) ...[
              const SizedBox(height: 20),
              OutlinedButton(onPressed: onRetry, child: const Text('Erneut versuchen')),
            ],
          ],
        ),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  const EmptyState({super.key, required this.icon, required this.title, this.message, this.action});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: AppColors.textSecondary),
            const SizedBox(height: 16),
            Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            if (message != null) ...[
              const SizedBox(height: 8),
              Text(message!, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.textSecondary)),
            ],
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
    );
  }
}

/// Überschrift eines Abschnitts mit optionalem "Alle anzeigen".
class SectionHeader extends StatelessWidget {
  final String title;
  final VoidCallback? onMore;
  final EdgeInsets padding;

  const SectionHeader(this.title, {super.key, this.onMore, this.padding = const EdgeInsets.fromLTRB(16, 24, 8, 12)});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Expanded(child: Text(title, style: AppText.sectionTitle, maxLines: 1, overflow: TextOverflow.ellipsis)),
          if (onMore != null)
            TextButton(
              onPressed: onMore,
              child: const Text('Alle anzeigen', style: TextStyle(color: AppColors.textSecondary, fontWeight: FontWeight.w600)),
            ),
        ],
      ),
    );
  }
}

/// Großer grüner Abspielknopf (wie bei Spotify).
class PlayButton extends StatelessWidget {
  final bool playing;
  final VoidCallback? onPressed;
  final double size;

  const PlayButton({super.key, required this.playing, required this.onPressed, this.size = 56});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Material(
        color: AppColors.accent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.black, size: size * 0.6),
        ),
      ),
    );
  }
}

/// Zieht beim Herunterziehen neu (für Listen auf Providern).
class RefreshableList extends ConsumerWidget {
  final Future<void> Function() onRefresh;
  final Widget child;
  const RefreshableList({super.key, required this.onRefresh, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      RefreshIndicator(color: AppColors.accent, onRefresh: onRefresh, child: child);
}
