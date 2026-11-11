// Laufzeiten des Abos: Beschriftung, Monatspreis, Ersparnis gegenüber monatlich, Angebote und Reihenfolge.
// Reine Rechnungen ohne Kauf-Paket – die Preise kommen fertig aus dem Store (Play Console), hier wird nichts erfunden.

import 'package:intl/intl.dart';

import '../data/models.dart';
import 'purchase_gateway.dart';

typedef Period = ({int years, int months, int weeks, int days});

final _periodPattern = RegExp(r'^P(?:(\d+)Y)?(?:(\d+)M)?(?:(\d+)W)?(?:(\d+)D)?$');

/// Zeitraum nach ISO 8601 (`P1M`, `P6M`, `P1Y`, `P1W`, `P3D`); null, wenn unlesbar oder leer.
Period? parsePeriod(String iso) {
  final match = _periodPattern.firstMatch(iso.trim().toUpperCase());
  if (match == null) return null;
  int part(int group) => int.parse(match.group(group) ?? '0');
  final period = (years: part(1), months: part(2), weeks: part(3), days: part(4));
  if (period.years == 0 && period.months == 0 && period.weeks == 0 && period.days == 0) return null;
  return period;
}

/// Ganze Monate (nur ohne Wochen und Tage), sonst null.
int? wholeMonths(Period? p) {
  if (p == null || p.weeks != 0 || p.days != 0) return null;
  final months = p.years * 12 + p.months;
  return months > 0 ? months : null;
}

/// Ganze Wochen (nur ohne Jahre und Monate, Tage in Vielfachen von 7), sonst null.
int? _wholeWeeks(Period? p) {
  if (p == null || p.years != 0 || p.months != 0) return null;
  final days = p.weeks * 7 + p.days;
  return days > 0 && days % 7 == 0 ? days ~/ 7 : null;
}

/// Ungefähre Länge in Tagen (Jahr 365, Monat 30, Woche 7) – zum Sortieren und Vergleichen.
int? periodDays(String iso) {
  final p = parsePeriod(iso);
  if (p == null) return null;
  return p.years * 365 + p.months * 30 + p.weeks * 7 + p.days;
}

/// Überschrift der Laufzeit („Monatlich“, „Halbjährlich“, „Jährlich“ …).
String periodLabel(String iso) {
  final p = parsePeriod(iso);
  final months = wholeMonths(p);
  if (months != null) {
    return switch (months) {
      1 => 'Monatlich',
      3 => 'Vierteljährlich',
      6 => 'Halbjährlich',
      12 => 'Jährlich',
      _ => 'Alle $months Monate',
    };
  }
  final weeks = _wholeWeeks(p);
  if (weeks != null) return weeks == 1 ? 'Wöchentlich' : 'Alle $weeks Wochen';
  return 'Abo';
}

/// „pro Monat“, „pro Jahr“, „alle 2 Monate“ … ('' bei unlesbarem Zeitraum).
String perPeriod(String iso) {
  final p = parsePeriod(iso);
  final months = wholeMonths(p);
  if (months != null) {
    return switch (months) {
      1 => 'pro Monat',
      3 => 'pro Quartal',
      6 => 'pro Halbjahr',
      12 => 'pro Jahr',
      _ => 'alle $months Monate',
    };
  }
  final weeks = _wholeWeeks(p);
  if (weeks != null) return weeks == 1 ? 'pro Woche' : 'alle $weeks Wochen';
  return '';
}

/// Dauer einer Phase: Zeitraum × [times] („3 Monate“, „1 Woche“, „3 Tage“, „1 Jahr“).
String durationText(String iso, int times) {
  final p = parsePeriod(iso);
  if (p == null) return '';
  final n = times < 1 ? 1 : times;
  String unit(int value, String one, String many) => '$value ${value == 1 ? one : many}';
  return [
    if (p.years > 0) unit(p.years * n, 'Jahr', 'Jahre'),
    if (p.months > 0) unit(p.months * n, 'Monat', 'Monate'),
    if (p.weeks > 0) unit(p.weeks * n, 'Woche', 'Wochen'),
    if (p.days > 0) unit(p.days * n, 'Tag', 'Tage'),
  ].join(' und ');
}

/// Regulärer Preis einer Laufzeit zum Anzeigen: „0,99 € pro Monat“ (fehlt der Preis: „Preis im Play Store“).
String regularPriceText(StorePlan plan) {
  final r = plan.regular;
  if (r.formattedPrice.trim().isEmpty) return 'Preis im Play Store';
  final per = perPeriod(r.billingPeriod);
  return per.isEmpty ? r.formattedPrice : '${r.formattedPrice} $per';
}

/// Monatspreis und Ersparnis einer Laufzeit.
class PlanPricing {
  /// Preis pro Monat (nur bei Laufzeiten über einem Monat), fertig formatiert.
  final String? perMonth;

  /// Ersparnis gegenüber monatlich in ganzen Prozent (abgerundet); null = nicht vergleichbar.
  final int? savePercent;

  const PlanPricing({this.perMonth, this.savePercent});

  /// Text „entspricht … pro Monat“ oder null.
  String? get perMonthText => perMonth == null ? null : 'entspricht $perMonth pro Monat';

  /// Chip „spare … %“ – nur bei mindestens 1 %.
  String? get saveText => savePercent != null && savePercent! >= 1 ? 'spare $savePercent %' : null;
}

/// Monatspreis und Ersparnis von [plan] gegenüber dem ersten monatlichen Plan aus [shown] (gleiche Währung).
/// Teurer oder gleich teuer: keine Ersparnis (kein „teurer“-Hinweis).
PlanPricing pricingFor(StorePlan plan, List<StorePlan> shown) {
  final r = plan.regular;
  final months = wholeMonths(parsePeriod(r.billingPeriod));
  if (r.priceMicros <= 0 || r.currencyCode.isEmpty || months == null || months == 1) return const PlanPricing();
  final format = NumberFormat.simpleCurrency(locale: 'de_DE', name: r.currencyCode);
  final perMonth = format.format(((r.priceMicros + months ~/ 2) ~/ months) / 1e6);
  StorePlan? reference;
  for (final candidate in shown) {
    final c = candidate.regular;
    if (wholeMonths(parsePeriod(c.billingPeriod)) == 1 && c.currencyCode == r.currencyCode && c.priceMicros > 0) {
      reference = candidate;
      break;
    }
  }
  if (reference == null) return PlanPricing(perMonth: perMonth);
  final full = reference.regular.priceMicros * months;
  return PlanPricing(perMonth: perMonth, savePercent: ((full - r.priceMicros) * 100) ~/ full);
}

/// Phasen vor der regulären (Gratis-Zeit, Einführungspreis).
List<StorePhase> _introPhases(StoreOffer offer) =>
    offer.phases.length > 1 ? offer.phases.sublist(0, offer.phases.length - 1) : const [];

/// Hat das Angebot eine Gratis-Phase?
bool hasFreeTrial(StoreOffer? offer) => offer != null && _introPhases(offer).any((p) => p.isFree);

/// Gratis-Zeit eines Angebots in Tagen (0 = keine).
int _freeDays(StoreOffer offer) {
  var days = 0;
  for (final phase in _introPhases(offer)) {
    if (!phase.isFree) continue;
    days += (periodDays(phase.billingPeriod) ?? 0) * (phase.cycles < 1 ? 1 : phase.cycles);
  }
  return days;
}

/// Bestes Angebot einer Laufzeit: zuerst eines mit Gratis-Zeit (die längste gewinnt), sonst das mit dem niedrigsten
/// Preis der ersten Phase; bei Gleichstand das erste. Google liefert nur Angebote, für die der Käufer berechtigt ist.
StoreOffer? chooseOffer(List<StoreOffer> offers) {
  final candidates = offers.where((o) => o.offerId != null && o.phases.isNotEmpty).toList();
  if (candidates.isEmpty) return null;
  StoreOffer? bestFree;
  var bestDays = 0;
  for (final offer in candidates) {
    if (!hasFreeTrial(offer)) continue;
    final days = _freeDays(offer);
    if (bestFree == null || days > bestDays) {
      bestFree = offer;
      bestDays = days;
    }
  }
  if (bestFree != null) return bestFree;
  var best = candidates.first;
  for (final offer in candidates.skip(1)) {
    if (offer.phases.first.priceMicros < best.phases.first.priceMicros) best = offer;
  }
  return best;
}

/// Beschreibung eines Angebots, z. B. „1 Monat gratis, danach 0,99 € pro Monat“; null ohne Phasen vor der regulären.
String? offerText(StoreOffer? offer) {
  if (offer == null) return null;
  final intro = _introPhases(offer);
  if (intro.isEmpty) return null;
  final parts = [
    for (final phase in intro)
      if (phase.isFree)
        '${durationText(phase.billingPeriod, phase.cycles)} gratis'
      else if (phase.once)
        '${phase.formattedPrice} für ${durationText(phase.billingPeriod, 1)}'
      else
        '${phase.formattedPrice} ${perPeriod(phase.billingPeriod)} für ${durationText(phase.billingPeriod, phase.cycles)}',
  ];
  final regular = offer.regular;
  final per = perPeriod(regular.billingPeriod);
  return '${parts.join(', danach ')}, danach ${regular.formattedPrice}${per.isEmpty ? '' : ' $per'}';
}

/// Die angebotenen Laufzeiten in Anzeigereihenfolge.
///
/// Mit Liste im Dashboard (`billing_base_plans`): genau diese, in dieser Reihenfolge (bei gleicher Kennung in
/// mehreren Produkten nach Produktreihenfolge). Ohne Liste: alle, kürzeste zuerst (unlesbare Zeiträume ans Ende,
/// Gleichstand nach Kennung).
List<StorePlan> shownPlans(List<StoreProduct> products, AppConfig c) {
  final order = c.billingProductIds;
  int rank(StoreProduct p) {
    final i = order.indexOf(p.id);
    return i < 0 ? order.length : i;
  }

  final sortedProducts = [...products];
  // stabil sortieren (Dart sortiert nicht garantiert stabil)
  final indexed = [for (var i = 0; i < sortedProducts.length; i++) (i, sortedProducts[i])]
    ..sort((a, b) {
      final byRank = rank(a.$2).compareTo(rank(b.$2));
      return byRank != 0 ? byRank : a.$1.compareTo(b.$1);
    });
  final all = [for (final entry in indexed) ...entry.$2.plans];
  if (c.billingBasePlans.isNotEmpty) {
    return [
      for (final id in c.billingBasePlans) ...all.where((p) => p.basePlanId == id),
    ];
  }
  final withIndex = [for (var i = 0; i < all.length; i++) (i, all[i])];
  withIndex.sort((a, b) {
    final da = periodDays(a.$2.regular.billingPeriod);
    final db = periodDays(b.$2.regular.billingPeriod);
    if (da != db) {
      if (da == null) return 1;
      if (db == null) return -1;
      return da.compareTo(db);
    }
    final byId = a.$2.basePlanId.compareTo(b.$2.basePlanId);
    return byId != 0 ? byId : a.$1.compareTo(b.$1);
  });
  return [for (final entry in withIndex) entry.$2];
}

/// Die empfohlene Laufzeit, wenn sie angeboten wird – sonst null.
String? recommendedPlan(List<StorePlan> shown, AppConfig c) {
  final id = c.billingRecommendedPlan;
  return id.isNotEmpty && shown.any((p) => p.basePlanId == id) ? id : null;
}
