import 'dart:async';

import 'package:flutter/foundation.dart';
// Die einzige Datei, die das Kauf-Paket einbindet. In der GitHub-Version, unter Windows und auf dem iPhone steckt
// dahinter ein Platzhalter ohne nativen Code (mobile/packages/in_app_purchase_stub) – deshalb hier nur die Namen
// verwenden, die es auch dort gibt.
import 'package:in_app_purchase/in_app_purchase.dart';

import 'purchase_gateway.dart';

/// Kauf über Google Play Billing (nur Play-Version auf Android). Abos werden wie ein dauerhafter Kauf gestartet;
/// ob sie laufen, entscheidet allein der Server nach der Prüfung bei Google.
class PlayPurchaseGateway implements PurchaseGateway {
  /// Das Paket erst beim ersten Gebrauch anfassen (verbindet sich dann mit Google Play).
  late final InAppPurchase _iap = InAppPurchase.instance;

  final _controller = StreamController<StorePurchase>.broadcast();
  StreamSubscription<List<PurchaseDetails>>? _subscription;

  /// Vom Store geladene Produkte (für den Kaufdialog).
  final _details = <String, ProductDetails>{};

  void _listen() {
    _subscription ??= _iap.purchaseStream.listen(
      (purchases) {
        for (final purchase in purchases) {
          _controller.add(_convert(purchase));
        }
      },
      onError: (Object error) => debugPrint('Kauf-Strom gestört: $error'),
    );
  }

  StorePurchase _convert(PurchaseDetails purchase) {
    final error = purchase.error;
    return StorePurchase(
      productId: purchase.productID,
      token: purchase.verificationData.serverVerificationData,
      status: switch (purchase.status) {
        PurchaseStatus.pending => StorePurchaseStatus.pending,
        PurchaseStatus.purchased => StorePurchaseStatus.purchased,
        PurchaseStatus.restored => StorePurchaseStatus.restored,
        PurchaseStatus.canceled => StorePurchaseStatus.cancelled,
        PurchaseStatus.error => StorePurchaseStatus.failed,
      },
      message: error == null ? '' : (error.message.isEmpty ? error.code : error.message),
      raw: purchase,
    );
  }

  @override
  Stream<StorePurchase> get purchases {
    _listen();
    return _controller.stream;
  }

  @override
  Future<bool> isAvailable() async {
    _listen();
    return _iap.isAvailable();
  }

  @override
  Future<List<StoreProduct>> loadProducts(Set<String> ids) async {
    final response = await _iap.queryProductDetails(ids);
    final error = response.error;
    if (error != null && response.productDetails.isEmpty) {
      throw StateError(error.message.isEmpty ? error.code : error.message);
    }
    final products = <StoreProduct>[];
    for (final id in ids) {
      // Zu einer ID kann der Store mehrere Einträge liefern (Angebote): es gilt der erste mit einem echten Preis
      final matching = response.productDetails.where((d) => d.id == id).toList();
      if (matching.isEmpty) continue;
      final chosen = matching.firstWhere((d) => d.rawPrice > 0, orElse: () => matching.first);
      _details[id] = chosen;
      products.add(StoreProduct(id: id, title: chosen.title, description: chosen.description, price: chosen.price));
    }
    return products;
  }

  @override
  Future<void> buy(StoreProduct product, {required String accountId}) async {
    final details = _details[product.id];
    if (details == null) throw StateError('Das Abo wurde im Play Store nicht gefunden (${product.id}).');
    _listen();
    await _iap.buyNonConsumable(purchaseParam: PurchaseParam(productDetails: details, applicationUserName: accountId));
  }

  @override
  Future<void> restore({required String accountId}) async {
    _listen();
    await _iap.restorePurchases(applicationUserName: accountId);
  }

  @override
  Future<void> complete(StorePurchase purchase) async {
    final raw = purchase.raw;
    if (raw is! PurchaseDetails || !raw.pendingCompletePurchase) return;
    try {
      await _iap.completePurchase(raw);
    } catch (e) {
      // Der Server hat den Kauf schon bei Google bestätigt – ein Fehler hier ändert nichts
      debugPrint('Kauf konnte auf dem Gerät nicht abgeschlossen werden: $e');
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _controller.close();
  }
}
