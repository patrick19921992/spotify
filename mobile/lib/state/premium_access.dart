import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import 'app_config.dart';
import 'auth.dart';
import 'settings.dart';

/// Rangfolge der Tonqualität (höher = besser), wie auf dem Server (`clamp_quality`).
const _qualityRank = {'low': 0, 'normal': 1, 'high': 2, 'original': 3};

/// Wer darf was? Die Premium-Leistungen schaltet der Betreiber im Dashboard einzeln auf „nur Premium“.
///
/// Durchgesetzt wird, wo es geht, auf dem Server (Tonqualität, Videos, Songtexte, Wünsche) – die App zeigt hier nur
/// passend an und deckelt mit. Das Offline-Hören hat seine eigene Logik (`offline_access.dart`) und nutzt [allows]
/// nicht.
class PremiumAccess {
  final bool isAdmin;
  final AppConfig config;

  /// null = noch nicht geladen / Fehler.
  final PremiumStatus? status;

  const PremiumAccess({required this.isAdmin, required this.config, this.status});

  /// Darf der Benutzer diese Leistung nutzen?
  bool allows(String feature) {
    // 1. Admins sind nie eingeschränkt
    if (isAdmin) return true;
    final status = this.status;
    // 2. Der Server sagt genau, was gesperrt ist
    final locked = status?.locked;
    if (locked != null) return !locked.contains(feature);
    // 3. Für alle freigegeben (Standard, alter Server)
    if (!config.premiumOnly.contains(feature)) return true;
    // 4. Stand vom Server da: gehört die Leistung zum Premium?
    if (status != null && status.checkedAt != null) return status.has(feature);
    // 5. Stand unbekannt: großzügig – der Server setzt die wichtigen Sperren ohnehin selbst durch
    return true;
  }

  /// Höchste erlaubte Stufe: 'original' oder die Grenze ohne Premium.
  String get qualityCap => allows(PremiumFeature.hqAudio) ? 'original' : config.freeAudioQuality;

  /// Gewünschte Stufe, höchstens [qualityCap].
  String capQuality(String wanted) => capQualityTo(wanted, qualityCap);

  /// Liegt [wanted] über der Grenze?
  bool isCapped(String wanted) => capQuality(wanted) != wanted;
}

/// [wanted], höchstens [cap] (Rangfolge original > high > normal > low; Unbekanntes bleibt, wie es ist).
String capQualityTo(String wanted, String cap) {
  final w = _qualityRank[wanted];
  final c = _qualityRank[cap];
  if (w == null || c == null) return wanted;
  return w > c ? cap : wanted;
}

final premiumAccessProvider = Provider<PremiumAccess>((ref) {
  final isAdmin = ref.watch(currentUserProvider.select((u) => u?.isAdmin ?? false));
  final config = ref.watch(appConfigValueProvider);
  // Solange niemand eine Leistung einschränkt, braucht es den Premium-Stand nicht – mit Schaltern aus fragt die App
  // genau so viel ab wie bisher.
  if (isAdmin || config.premiumOnly.isEmpty) return PremiumAccess(isAdmin: isAdmin, config: config);
  final loggedIn = ref.watch(currentUserProvider.select((u) => u != null));
  final premium = loggedIn ? ref.watch(premiumProvider).value : null;
  return PremiumAccess(isAdmin: isAdmin, config: config, status: premium);
});

/// Hinweis, wenn eine gesperrte Qualität gewählt wird und es keine Premium-Seite gibt.
const qualityLockedMessage = 'Diese Qualität gibt es nur mit Premium.';

/// Untertitel einer Qualitäts-Einstellung: die wirksame Stufe – gedeckelt mit Zusatz „– mehr mit Premium“
/// (die gespeicherte Einstellung bleibt; mit Premium gilt sie wieder).
String effectiveQualityLabel(String setting, PremiumAccess access) {
  final effective = access.capQuality(setting);
  final label = qualityLabels[effective] ?? effective;
  return effective == setting ? label : '$label – mehr mit Premium';
}
