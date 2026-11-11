import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/models.dart';
import '../state/offline_access.dart' show accountKey;
import '../state/premium_access.dart';

/// Überspring-Grenze ohne Premium („Unbegrenzt überspringen“ nur mit Premium).
///
/// Nur in der App durchsetzbar – der Server sieht nicht, wann jemand überspringt. Ältere App-Versionen zählen nicht
/// mit, und wer die App-Daten löscht oder neu installiert, fängt von vorn an.
class SkipLimiter {
  /// Höchstens so viele Zeitpunkte werden gespeichert (mehr als 100 pro Stunde lässt das Dashboard nicht zu).
  static const maxEntries = 100;

  final SharedPreferences prefs;

  /// `skips.<Server>|<Benutzer>`.
  final String key;
  final PremiumAccess access;

  const SkipLimiter({required this.prefs, required this.key, required this.access});

  static String keyFor(String serverUrl, int userId) => 'skips.${accountKey(serverUrl, userId)}';

  /// Zeitpunkte erlaubter Sprünge der letzten Stunde vor [now].
  List<int> _recent(DateTime now) {
    final since = now.subtract(const Duration(hours: 1)).millisecondsSinceEpoch;
    try {
      final raw = prefs.getString(key);
      if (raw == null) return [];
      final list = jsonDecode(raw);
      if (list is! List) return [];
      return [
        for (final item in list)
          if (item is num && item.toInt() > since && item.toInt() <= now.millisecondsSinceEpoch) item.toInt(),
      ];
    } catch (_) {
      return [];
    }
  }

  /// So oft wurde in der letzten Stunde übersprungen.
  int used(DateTime now) => _recent(now).length;

  /// Darf jetzt übersprungen werden? Wenn ja, wird der Sprung gezählt (mit Premium nicht).
  bool tryConsume(DateTime now) {
    if (access.allows(PremiumFeature.skips)) return true;
    final recent = _recent(now);
    if (recent.length >= access.config.freeSkipsPerHour) return false;
    final next = [...recent, now.millisecondsSinceEpoch];
    prefs
        .setString(key, jsonEncode(next.length > maxEntries ? next.sublist(next.length - maxEntries) : next))
        .ignore();
    return true;
  }
}

/// Text, wenn die Grenze erreicht ist.
String skipLimitMessage(int perHour) =>
    'Du hast in dieser Stunde schon $perHour-mal übersprungen. Mit Premium unbegrenzt.';

/// Hinweis „Grenze erreicht“ – die Oberfläche zeigt ihn einmal und räumt ihn weg.
class SkipLimitNotice extends Notifier<String?> {
  @override
  String? build() => null;

  void show(String text) => state = text;
  void clear() => state = null;
}

final skipLimitNoticeProvider = NotifierProvider<SkipLimitNotice, String?>(SkipLimitNotice.new);
