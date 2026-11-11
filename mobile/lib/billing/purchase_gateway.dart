import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/flavor.dart';
import 'play_gateway.dart';

/// Ein Abo, wie es der Store anbietet. [price] ist fertig formatiert („0,99 €“) – den Preis legt der Betreiber in
/// der Play Console fest, die App rechnet und formatiert nichts selbst.
class StoreProduct {
  final String id;
  final String title;
  final String description;
  final String price;

  const StoreProduct({required this.id, required this.title, required this.description, required this.price});
}

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

  /// Öffnet den Kaufdialog. Das Ergebnis kommt über [purchases]. [accountId] verknüpft den Kauf mit dem Konto.
  Future<void> buy(StoreProduct product, {required String accountId});

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
