// Platzhalter für `package:in_app_purchase_android/billing_client_wrappers.dart` – nur die Typen, die Selfify liest
// (lib/billing/play_gateway.dart). Signaturen wie im echten Paket (in_app_purchase_android 0.5.5).

enum ProductType { inapp, subs }

enum RecurrenceMode { finiteRecurring, infiniteRecurring, nonRecurring }

enum ReplacementMode {
  unknownReplacementMode,
  withTimeProration,
  chargeProratedPrice,
  withoutProration,
  deferred,
  chargeFullPrice,
}

class ProductDetailsWrapper {
  const ProductDetailsWrapper({
    required this.description,
    required this.name,
    required this.productId,
    required this.productType,
    required this.title,
    this.subscriptionOfferDetails,
  });

  final String description;
  final String name;
  final String productId;
  final ProductType productType;
  final List<SubscriptionOfferDetailsWrapper>? subscriptionOfferDetails;
  final String title;
}

class SubscriptionOfferDetailsWrapper {
  const SubscriptionOfferDetailsWrapper({
    required this.basePlanId,
    this.offerId,
    required this.offerTags,
    required this.offerIdToken,
    required this.pricingPhases,
    this.installmentPlanDetails,
  });

  final String basePlanId;
  final String? offerId;
  final List<String> offerTags;
  final String offerIdToken;
  final List<PricingPhaseWrapper> pricingPhases;
  final InstallmentPlanDetailsWrapper? installmentPlanDetails;
}

class PricingPhaseWrapper {
  const PricingPhaseWrapper({
    required this.billingCycleCount,
    required this.billingPeriod,
    required this.formattedPrice,
    required this.priceAmountMicros,
    required this.priceCurrencyCode,
    required this.recurrenceMode,
  });

  final int billingCycleCount;
  final String billingPeriod;
  final String formattedPrice;
  final int priceAmountMicros;
  final String priceCurrencyCode;
  final RecurrenceMode recurrenceMode;
}

class InstallmentPlanDetailsWrapper {
  const InstallmentPlanDetailsWrapper({
    required this.commitmentPaymentsCount,
    required this.subsequentCommitmentPaymentsCount,
  });

  final int commitmentPaymentsCount;
  final int subsequentCommitmentPaymentsCount;
}
