import 'package:flutter/foundation.dart';

/// Merkt sich die letzten Fehler der App, damit „Fehler melden“ sie auf Wunsch mitschicken kann.
///
/// Nur im Arbeitsspeicher (nichts wird gespeichert). Zugangsdaten werden vorher unkenntlich gemacht.
class ErrorLog {
  ErrorLog._();

  static const maxEntries = 30;
  static const maxChars = 15000;
  static final List<String> _entries = [];

  /// Haken in Flutter und die Dart-Fehlerbehandlung setzen (einmal beim Start).
  static void install() {
    final previousFlutter = FlutterError.onError;
    FlutterError.onError = (details) {
      add(details.exception, details.stack);
      previousFlutter?.call(details);
    };
    final previousDispatcher = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      add(error, stack);
      return previousDispatcher?.call(error, stack) ?? false;
    };
  }

  static void add(Object error, StackTrace? stack, {DateTime? now}) {
    final stackText = stack == null ? '' : '\n${_firstLines(stack.toString(), 8)}';
    _entries.add('[${(now ?? DateTime.now()).toIso8601String()}] ${redact('$error')}${redact(stackText)}');
    while (_entries.length > maxEntries) {
      _entries.removeAt(0);
    }
  }

  /// Alle gemerkten Fehler als Text (der neueste zuletzt, höchstens [maxChars] Zeichen).
  static String dump() {
    final text = _entries.join('\n\n');
    return text.length <= maxChars ? text : text.substring(text.length - maxChars);
  }

  static bool get isEmpty => _entries.isEmpty;

  static void clear() => _entries.clear();

  /// Entfernt Zugangsdaten aus Texten: Medien-Token in Links (`?t=…`), Bearer-Token, Passwörter.
  static String redact(String text) => text
      .replaceAllMapped(RegExp(r'([?&])(t|token|access_token|refresh_token)=[^&\s)"]+', caseSensitive: false),
          (m) => '${m[1]}${m[2]}=***')
      .replaceAll(RegExp(r'Bearer\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false), 'Bearer ***')
      .replaceAllMapped(RegExp(r'("?(?:password|refresh_token|access_token)"?\s*[:=]\s*)"?[^",}\s]+"?', caseSensitive: false),
          (m) => '${m[1]}***');

  static String _firstLines(String text, int count) => text.split('\n').take(count).join('\n');
}
