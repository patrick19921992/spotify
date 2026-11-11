import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import 'app_config.dart';
import 'auth.dart';
import 'connectivity.dart';

/// Uhr des Geräts (in Tests ersetzbar).
final clockProvider = Provider<DateTime Function()>((_) => DateTime.now);

/// Zuletzt vom Server bestätigter Stand „Darf dieser Benutzer offline hören?“ – liegt auf dem Gerät, damit die
/// Antwort auch ohne Netz gilt (höchstens die Gnadenfrist lang).
class AccessRecord {
  /// „Offline-Hören nur mit Premium“ war eingeschaltet.
  final bool required;

  /// Der Server hat Offline-Hören erlaubt.
  final bool allowed;

  /// Gerätezeit beim Empfang der Antwort.
  final DateTime verifiedAt;
  final int graceDays;

  /// Größte je gesehene Gerätezeit: Zurückstellen der Uhr verlängert die Frist nicht.
  final DateTime lastSeenAt;

  const AccessRecord({
    required this.required,
    required this.allowed,
    required this.verifiedAt,
    required this.graceDays,
    required this.lastSeenAt,
  });

  AccessRecord seenAt(DateTime time) => AccessRecord(
        required: required,
        allowed: allowed,
        verifiedAt: verifiedAt,
        graceDays: graceDays,
        lastSeenAt: time,
      );

  Json toJson() => {
        'required': required,
        'allowed': allowed,
        'verified_at': verifiedAt.toUtc().toIso8601String(),
        'grace_days': graceDays,
        'last_seen_at': lastSeenAt.toUtc().toIso8601String(),
      };

  /// null, wenn der Eintrag unlesbar ist – dann gilt „noch nie geprüft“.
  static AccessRecord? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final j = jsonDecode(raw) as Json;
      final verifiedAt = DateTime.tryParse(j['verified_at']?.toString() ?? '');
      if (verifiedAt == null || j['required'] is! bool || j['allowed'] is! bool) return null;
      final days = j['grace_days'] is num ? (j['grace_days'] as num).toInt() : 0;
      return AccessRecord(
        required: j['required'] as bool,
        allowed: j['allowed'] as bool,
        verifiedAt: verifiedAt,
        graceDays: days <= 0 ? 7 : days,
        lastSeenAt: DateTime.tryParse(j['last_seen_at']?.toString() ?? '') ?? verifiedAt,
      );
    } catch (_) {
      return null;
    }
  }
}

/// * `free` – keine Sperre (Schalter aus, alter Server, Admin, abgemeldet)
/// * `checking` – Sperre ist an, der Premium-Stand ist aber noch unbekannt: nichts laden, nichts löschen
/// * `allowed` – Premium bestätigt (oder letzte Bestätigung innerhalb der Gnadenfrist)
/// * `locked` – kein Offline-Hören: nichts laden, nichts lokal abspielen, Offline-Musik wird gelöscht
enum OfflineAccess { free, checking, allowed, locked }

class OfflineAccessState {
  final OfflineAccess access;

  /// Bei `allowed`: so viele Tage gilt die letzte Bestätigung noch (aufgerundet).
  final int? daysLeft;

  /// Bei `locked`: nicht vom Server bestätigt, sondern die Gnadenfrist ist ohne Prüfung abgelaufen.
  final bool graceExpired;

  /// Länge der Gnadenfrist in Tagen (für den Hinweis nach dem Löschen).
  final int graceDays;

  const OfflineAccessState(this.access, {this.daysLeft, this.graceExpired = false, this.graceDays = 7});

  /// Darf Neues aufs Gerät geladen werden?
  bool get canDownload => access == OfflineAccess.free || access == OfflineAccess.allowed;

  /// Dürfen Dateien vom Gerät abgespielt werden?
  bool get canPlayLocal => access != OfflineAccess.locked;

  @override
  bool operator ==(Object other) =>
      other is OfflineAccessState &&
      other.access == access &&
      other.daysLeft == daysLeft &&
      other.graceExpired == graceExpired &&
      other.graceDays == graceDays;

  @override
  int get hashCode => Object.hash(access, daysLeft, graceExpired, graceDays);

  @override
  String toString() => 'OfflineAccessState($access, daysLeft: $daysLeft, graceExpired: $graceExpired)';
}

/// Der Zustandsautomat als reine Funktion.
///
/// Gelöscht wird nur im Zustand `locked` – also wenn der Server „nicht erlaubt“ bestätigt hat oder die letzte
/// Bestätigung älter ist als die Gnadenfrist. Ein unbekannter Stand (noch nie geprüft, Ladefehler) sperrt höchstens
/// das Laden.
OfflineAccessState evaluateOfflineAccess({
  required bool isAdmin,
  required bool configRequires,
  AccessRecord? record,
  required DateTime now,
}) {
  // 1: Admins sind ausgenommen
  if (isAdmin) return const OfflineAccessState(OfflineAccess.free);
  if (record == null) {
    // 3/4: noch nie geprüft – laut /app/config gesperrt? Dann warten, sonst frei
    return OfflineAccessState(configRequires ? OfflineAccess.checking : OfflineAccess.free);
  }
  // 2: Schalter aus (oder alter Server)
  if (!record.required) return const OfflineAccessState(OfflineAccess.free);
  // 8: vom Server bestätigt – kein Premium
  if (!record.allowed) return OfflineAccessState(OfflineAccess.locked, graceDays: record.graceDays);
  final reference = now.isAfter(record.lastSeenAt) ? now : record.lastSeenAt;
  final age = reference.difference(record.verifiedAt);
  final grace = Duration(days: record.graceDays);
  // 7: Frist ohne Prüfung abgelaufen
  if (age > grace) return OfflineAccessState(OfflineAccess.locked, graceExpired: true, graceDays: record.graceDays);
  // 5/6: bestätigt und innerhalb der Frist
  final left = grace - age;
  final daysLeft = (left.inMicroseconds / Duration.microsecondsPerDay).ceil();
  return OfflineAccessState(OfflineAccess.allowed, daysLeft: daysLeft, graceDays: record.graceDays);
}

/// Schlüssel des gespeicherten Stands – je Server und Benutzer.
String offlineAccessKey(String serverUrl, int userId) => 'offline.access.$serverUrl|$userId';

/// Entscheidet, ob dieses Gerät Musik laden und lokal abspielen darf („Offline-Hören nur mit Premium“).
///
/// Der Stand wird nur nach einer echten Antwort des Servers geschrieben (Premium abfragen, Code einlösen, Kauf
/// melden). Ein Ladefehler, ein 503 oder fehlendes Netz ändert nichts – dann gilt der letzte Stand bis zum Ende der
/// Gnadenfrist. Das Löschen selbst macht der Offline-Speicher (`OfflineController.wipe`), sobald hier `locked` steht.
class OfflineAccessController extends Notifier<OfflineAccessState> {
  /// So lange wartet die App vor dem Löschen höchstens auf eine letzte Prüfung (Frist abgelaufen, Netz da).
  static const lastCheckTimeout = Duration(seconds: 20);

  String? _key;
  bool _isAdmin = false;
  bool _configRequires = false;

  /// Schlüssel, für den die letzte Prüfung vor dem Löschen schon versucht wurde.
  String? _lastCheckFailedFor;
  bool _lastCheckRunning = false;

  @override
  OfflineAccessState build() {
    final userId = ref.watch(currentUserProvider.select((u) => u?.id));
    final serverUrl = ref.watch(authProvider.select((a) => a.value?.serverUrl));
    _isAdmin = ref.watch(currentUserProvider.select((u) => u?.isAdmin ?? false));
    _configRequires = ref.watch(appConfigValueProvider.select((c) => c.offlineRequiresPremium));
    // Abgemeldet: keine Auswertung, nichts wird gelöscht
    if (userId == null || serverUrl == null) {
      _key = null;
      return const OfflineAccessState(OfflineAccess.free);
    }
    _key = offlineAccessKey(serverUrl, userId);
    // Den Premium-Stand nur dann selbst abfragen, wenn die Sperre eine Rolle spielt – mit Schalter aus (und für
    // Admins) fragt die App genau so viel ab wie bisher.
    if (!_isAdmin && (_configRequires || (_read()?.required ?? false))) {
      ref.listen(premiumProvider, (_, next) => _onPremium(next));
      // Liegt schon ein Stand im Speicher, ist unklar, wie alt er ist – er zählt nicht als „gerade geprüft“,
      // sondern wird neu geholt.
      final current = ref.read(premiumProvider);
      if (current.hasValue && !current.isLoading) Future.microtask(() => ref.invalidate(premiumProvider));
      ref.listen(isOfflineProvider, (_, _) => recheck());
    }
    return _evaluate();
  }

  AccessRecord? _read() {
    final key = _key;
    return key == null ? null : AccessRecord.tryParse(ref.read(sharedPreferencesProvider).getString(key));
  }

  void _write(AccessRecord record) {
    final key = _key;
    if (key != null) ref.read(sharedPreferencesProvider).setString(key, jsonEncode(record.toJson())).ignore();
  }

  /// R1: Antwort des Servers übernehmen. false = kein Stand vom Server (abgemeldet, Platzhalter).
  bool _apply(PremiumStatus status) {
    if (_key == null || status.checkedAt == null) return false;
    final now = ref.read(clockProvider)();
    _write(AccessRecord(
      required: status.offlineRequiresPremium,
      allowed: status.offlineAllowed,
      verifiedAt: now,
      graceDays: status.offlineGraceDays,
      lastSeenAt: now,
    ));
    _lastCheckFailedFor = null;
    return true;
  }

  void _onPremium(AsyncValue<PremiumStatus> next) {
    // R2: Fehler und laufende Abfragen ändern nichts
    if (next is! AsyncData<PremiumStatus> || next.isLoading) return;
    if (_apply(next.value)) state = _evaluate();
  }

  OfflineAccessState _evaluate() {
    final key = _key;
    if (key == null) return const OfflineAccessState(OfflineAccess.free);
    final now = ref.read(clockProvider)();
    var record = _read();
    // Größte gesehene Gerätezeit fortschreiben (nicht bei jeder Kleinigkeit speichern: ab einer Minute Abstand)
    if (record != null && now.difference(record.lastSeenAt) >= const Duration(minutes: 1)) {
      record = record.seenAt(now);
      _write(record);
    }
    final result = evaluateOfflineAccess(isAdmin: _isAdmin, configRequires: _configRequires, record: record, now: now);
    if (result.access != OfflineAccess.locked || !result.graceExpired || _lastCheckFailedFor == key) return result;
    // R3: Frist um – vor dem Löschen einmal versuchen, den Stand zu holen, wenn eine Verbindung besteht
    if (ref.read(isOfflineProvider) || ref.read(apiProvider) == null) return result;
    if (!_lastCheckRunning) {
      _lastCheckRunning = true;
      Future.microtask(() => _lastCheck(key));
    }
    return const OfflineAccessState(OfflineAccess.checking);
  }

  Future<void> _lastCheck(String key) async {
    try {
      await ref.refresh(premiumProvider.future).timeout(lastCheckTimeout);
    } catch (_) {
      // kein Netz, Zeitlimit, Fehler des Servers: unten wird gesperrt
    }
    _lastCheckRunning = false;
    if (!ref.mounted) return;
    // Bei Erfolg hat _onPremium den neuen Stand schon gespeichert; sonst bleibt es bei „Frist abgelaufen“
    if (_key == key) {
      final record = _read();
      final stillExpired = record != null &&
          evaluateOfflineAccess(isAdmin: _isAdmin, configRequires: _configRequires, record: record, now: ref.read(clockProvider)())
              .graceExpired;
      if (stillExpired) _lastCheckFailedFor = key;
    }
    state = _evaluate();
  }

  /// R5: neu auswerten (Zurückkehren in die App, stündlich, Verbindungswechsel). Die Uhr kann weitergelaufen sein.
  void recheck() {
    if (!ref.mounted) return;
    final before = state;
    final next = _evaluate();
    if (next != before) state = next;
    // Gesperrt, weil lange nicht geprüft werden konnte, und jetzt wieder online: gleich nachfragen
    if (next.access == OfflineAccess.locked && next.graceExpired && !ref.read(isOfflineProvider)) {
      ref.invalidate(premiumProvider);
    }
  }
}

final offlineAccessProvider =
    NotifierProvider<OfflineAccessController, OfflineAccessState>(OfflineAccessController.new);

/// Hinweis nach dem Löschen der Offline-Musik (einmalig; die Oberfläche zeigt ihn und räumt ihn weg).
class OfflineWipeNotice extends Notifier<String?> {
  @override
  String? build() => null;

  void show(String text) => state = text;
  void clear() => state = null;
}

final offlineWipeNoticeProvider = NotifierProvider<OfflineWipeNotice, String?>(OfflineWipeNotice.new);

/// Text des Hinweises nach dem Löschen.
String offlineWipeMessage(OfflineAccessState access) => access.graceExpired
    ? 'Dein Premium konnte ${access.graceDays} Tage lang nicht geprüft werden – die Offline-Musik wurde von diesem '
        'Gerät entfernt.'
    : 'Dein Premium ist abgelaufen – die Offline-Musik wurde von diesem Gerät entfernt.';
