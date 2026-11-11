import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/flavor.dart';
import 'play_gateway.dart';

/// Eine Preisphase eines Abos (Gratis-Zeit, Einführungspreis oder der reguläre Preis), wie der Store sie liefert.
class StorePhase {
  /// Fertig formatiert vom Store („0,99 €“).
  final String formattedPrice;
  final int priceMicros;
  final String currencyCode;

  /// Abrechnungszeitraum nach ISO 8601 (`P1M`, `P6M`, `P1Y`, `P1W`, `P3D`).
  final String billingPeriod;

  /// Anzahl der Zeiträume (bei der regulären, unbegrenzten Phase 0).
  final int cycles;

  /// Reguläre Phase: verlängert sich, bis gekündigt wird.
  final bool infinite;

  /// Einmalige Zahlung für einen Zeitraum.
  final bool once;

  const StorePhase({
    required this.formattedPrice,
    required this.priceMicros,
    required this.currencyCode,
    required this.billingPeriod,
    this.cycles = 0,
    this.infinite = false,
    this.once = false,
  });

  bool get isFree => priceMicros == 0;
}

/// Kaufbarer Eintrag eines Abos: ein Basis-Plan ohne Angebot oder ein Angebot dazu.
class StoreOffer {
  final String productId;
  final String basePlanId;

  /// null = Basis-Plan ohne Angebot.
  final String? offerId;
  final List<String> tags;

  /// Preisphasen in Reihenfolge; die letzte ist die reguläre (unbegrenzte) Phase.
  final List<StorePhase> phases;

  /// Das Objekt des Kauf-Pakets (nur `play_gateway.dart` liest es).
  final Object? raw;

  const StoreOffer({
    required this.productId,
    required this.basePlanId,
    this.offerId,
    this.tags = const [],
    required this.phases,
    this.raw,
  });

  /// Die reguläre Phase.
  StorePhase get regular => phases.last;
}

/// Eine Laufzeit (ein Basis-Plan des Abos) – z. B. monatlich, halbjährlich, jährlich.
class StorePlan {
  final String productId;
  final String basePlanId;
  final String title;

  /// Der Basis-Plan ohne Angebot.
  final StoreOffer base;

  /// Das beste Angebot für diesen Käufer (Gratis-Zeit, Einführungspreis) – null = keins.
  final StoreOffer? offer;

  const StorePlan({
    required this.productId,
    required this.basePlanId,
    required this.title,
    required this.base,
    this.offer,
  });

  StorePhase get regular => base.phases.last;
}

/// Ein Abo, wie es der Store anbietet. [price] ist fertig formatiert („0,99 €“) – den Preis legt der Betreiber in
/// der Play Console fest; die App formatiert nur den Monatspreis längerer Laufzeiten selbst (`plans.dart`).
class StoreProduct {
  final String id;
  final String title;
  final String description;

  /// Regulärer Preis des ersten Plans.
  final String price;

  /// Die Laufzeiten (Basis-Pläne) des Abos.
  final List<StorePlan> plans;

  const StoreProduct({
    required this.id,
    required this.title,
    required this.description,
    required this.price,
    this.plans = const [],
  });
}

/// Der laufende Kauf ist auf diesem Gerät/Google-Konto nicht zu finden (Text auch als `BillingText.changeNotOnDevice`).
const storeChangeNotOnDevice =
    'Dein Abo gehört zu einem anderen Google-Konto. Wechsle die Laufzeit bitte dort in Google Play.';

/// Die eigenen Käufe ließen sich gerade nicht abfragen (Google Play gestört) – später noch einmal versuchen.
const storeChangeUnavailable = 'Google Play ist gerade nicht erreichbar. Versuche den Wechsel bitte gleich noch einmal.';

enum StorePurchaseStatus { purchased, restored, pending, cancelled, failed }

/// Meldung des Stores zu einem Kauf. [token] ist der Kauf-Token, den der Server bei Google prüft.
class StorePurchase {
  final String productId;
  final String token;
  final StorePurchaseStatus status;

  /// Fehlermeldung des Stores (nur bei [StorePurchaseStatus.failed]).
  final String message;

  /// Das Objekt des Kauf-Pakets (zum Abschließen des Kaufs).
  final Object? raw;

  const StorePurchase({
    required this.productId,
    required this.token,
    required this.status,
    this.message = '',
    this.raw,
  });
}

/// Zugang zum Store. Die echte Umsetzung (Google Play Billing) steckt in `play_gateway.dart`; in Tests ein Nachbau.
abstract class PurchaseGateway {
  Future<bool> isAvailable();

  /// Fehlende IDs fehlen einfach in der Liste.
  Future<List<StoreProduct>> loadProducts(Set<String> ids);

  /// Käufe, Wiederherstellungen, Abbrüche und Fehler der laufenden App. Was vorher liegen blieb, kommt nur nach
  /// [restore].
  Stream<StorePurchase> get purchases;

  /// Öffnet den Kaufdialog für eine Laufzeit (mit ihrem Angebot, falls es eines gibt). Das Ergebnis kommt über
  /// [purchases]. [accountId] verknüpft den Kauf mit dem Konto.
  Future<void> buy(StorePlan plan, {required String accountId});

  /// Laufzeit wechseln: ersetzt den laufenden Kauf von [oldProductId] auf diesem Gerät/Google-Konto (Google rechnet
  /// die Restzeit an). Wirft StateError(BillingText.changeNotOnDevice), wenn der Store keinen solchen Kauf kennt.
  Future<void> change(StorePlan plan, {required String accountId, required String oldProductId});

  /// Fragt den Store nach vorhandenen Käufen; sie kommen über [purchases].
  Future<void> restore({required String accountId});

  /// Schließt einen Kauf ab (bestätigt ihn beim Store). Fehler werden geschluckt.
  Future<void> complete(StorePurchase purchase);

  void dispose();
}

/// null = in dieser Ausgabe gibt es keinen Kauf (GitHub-Version, Windows, iPhone). In Tests überschreibbar.
/// Wird erst gelesen, wenn der Kauf wirklich angeboten wird (siehe `billingVisibleProvider`).
final purchaseGatewayProvider = Provider<PurchaseGateway?>((ref) {
  if (!isPlayChannel || defaultTargetPlatform != TargetPlatform.android) return null;
  final gateway = PlayPurchaseGateway();
  ref.onDispose(gateway.dispose);
  return gateway;
});
