import 'dart:async';

import 'package:flutter/foundation.dart';
// Die einzige Datei, die das Kauf-Paket einbindet. In der GitHub-Version, unter Windows und auf dem iPhone steckt
// dahinter ein Platzhalter ohne nativen Code (mobile/packages/in_app_purchase_stub) – deshalb hier nur die Namen
// verwenden, die es auch dort gibt.
import 'package:in_app_purchase/in_app_purchase.dart';
// Laufzeiten (Basis-Pläne, Angebote) und Wechsel – ebenfalls mit Platzhalter (mobile/packages/in_app_purchase_android_stub)
import 'package:in_app_purchase_android/billing_client_wrappers.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';

import 'plans.dart';
import 'purchase_gateway.dart';

/// Kauf über Google Play Billing (nur Play-Version auf Android). Abos werden wie ein dauerhafter Kauf gestartet;
/// ob sie laufen, entscheidet allein der Server nach der Prüfung bei Google.
class PlayPurchaseGateway implements PurchaseGateway {
  /// Das Paket erst beim ersten Gebrauch anfassen (verbindet sich dann mit Google Play).
  late final InAppPurchase _iap = InAppPurchase.instance;

  final _controller = StreamController<StorePurchase>.broadcast();
  StreamSubscription<List<PurchaseDetails>>? _subscription;

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
      // Zu einem Abo liefert der Store je Basis-Plan und je Angebot einen eigenen Eintrag
      final matching = response.productDetails.where((d) => d.id == id).toList();
      if (matching.isEmpty) continue;
      final plans = _plans(id, matching);
      if (plans.isEmpty) continue;
      final first = matching.first;
      products.add(StoreProduct(
        id: id,
        title: first.title,
        description: first.description,
        price: plans.first.regular.formattedPrice,
        plans: plans,
      ));
    }
    return products;
  }

  /// Laufzeiten eines Abos: je Basis-Plan der Eintrag ohne Angebot, dazu das beste Angebot.
  static List<StorePlan> _plans(String productId, List<ProductDetails> entries) {
    final byPlan = <String, List<StoreOffer>>{};
    String title = '';
    for (final entry in entries) {
      if (entry is! GooglePlayProductDetails) continue;
      final index = entry.subscriptionIndex;
      final details = entry.productDetails.subscriptionOfferDetails;
      if (index == null || details == null || index >= details.length) continue;
      final offer = details[index];
      // Ratenpläne und Prepaid-Pläne (ohne automatische Verlängerung) bietet die App nicht an
      if (offer.installmentPlanDetails != null) continue;
      if (offer.pricingPhases.isEmpty ||
          offer.pricingPhases.last.recurrenceMode != RecurrenceMode.infiniteRecurring) {
        continue;
      }
      title = title.isEmpty ? entry.title : title;
      byPlan.putIfAbsent(offer.basePlanId, () => []).add(StoreOffer(
            productId: productId,
            basePlanId: offer.basePlanId,
            offerId: offer.offerId,
            tags: offer.offerTags,
            phases: [
              for (final phase in offer.pricingPhases)
                StorePhase(
                  formattedPrice: phase.formattedPrice,
                  priceMicros: phase.priceAmountMicros,
                  currencyCode: phase.priceCurrencyCode,
                  billingPeriod: phase.billingPeriod,
                  cycles: phase.recurrenceMode == RecurrenceMode.infiniteRecurring ? 0 : phase.billingCycleCount,
                  infinite: phase.recurrenceMode == RecurrenceMode.infiniteRecurring,
                  once: phase.recurrenceMode == RecurrenceMode.nonRecurring,
                ),
            ],
            raw: entry,
          ));
    }
    final plans = <StorePlan>[];
    byPlan.forEach((basePlanId, offers) {
      final base = offers.where((o) => o.offerId == null).firstOrNull;
      if (base == null) return; // ohne Basis-Eintrag lässt sich der Plan nicht sauber kaufen
      plans.add(StorePlan(
        productId: productId,
        basePlanId: basePlanId,
        title: title,
        base: base,
        offer: chooseOffer(offers),
      ));
    });
    return plans;
  }

  static GooglePlayProductDetails _details(StoreOffer offer) {
    final raw = offer.raw;
    if (raw is! GooglePlayProductDetails) {
      throw StateError('Das Abo wurde im Play Store nicht gefunden (${offer.productId}).');
    }
    return raw;
  }

  @override
  Future<void> buy(StorePlan plan, {required String accountId}) async {
    final details = _details(plan.offer ?? plan.base);
    _listen();
    await _iap.buyNonConsumable(
      purchaseParam: GooglePlayPurchaseParam(
        productDetails: details,
        applicationUserName: accountId,
        offerToken: details.offerToken,
      ),
    );
  }

  @override
  Future<void> change(StorePlan plan, {required String accountId, required String oldProductId}) async {
    final details = _details(plan.offer ?? plan.base);
    _listen();
    final past = await _iap
        .getPlatformAddition<InAppPurchaseAndroidPlatformAddition>()
        .queryPastPurchases(applicationUserName: accountId);
    final old = past.pastPurchases
        .where((p) => p.productID == oldProductId && p.status == PurchaseStatus.purchased)
        .firstOrNull;
    if (old == null) {
      // Abfrage gestört (Dienst nicht erreichbar, Netzfehler): erneut versuchen, nicht aufs Konto schieben
      if (past.error != null) throw StateError(storeChangeUnavailable);
      // Das Abo läuft über ein anderes Google-Konto (oder ein anderes Gerät ohne dieses Konto)
      throw StateError(storeChangeNotOnDevice);
    }
    await _iap.buyNonConsumable(
      purchaseParam: GooglePlayPurchaseParam(
        productDetails: details,
        applicationUserName: accountId,
        offerToken: details.offerToken,
        changeSubscriptionParam: ChangeSubscriptionParam(
          oldPurchaseDetails: old,
          // Sofort wechseln: Die neue Laufzeit wird gleich bezahlt, die bezahlte Restzeit der alten hängt Google
          // anteilig hinten an. Für einen Wechsel zwischen Basis-Abos desselben Abos nennt Google nur diesen Modus
          // und „ohne Anrechnung“ – Zeit-Anrechnung (withTimeProration) gilt dort nicht.
          replacementMode: ReplacementMode.chargeFullPrice,
        ),
      ),
    );
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
      // Bestätigen soll den Kauf der Server (nach seiner Prüfung bei Google); dies hier ist der zweite Weg.
      // Scheitern beide, erstattet Google den Kauf nach 3 Tagen.
      debugPrint('Kauf konnte auf dem Gerät nicht abgeschlossen werden: $e');
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _controller.close();
  }
}
