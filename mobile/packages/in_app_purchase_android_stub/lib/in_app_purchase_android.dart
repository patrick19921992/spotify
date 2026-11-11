// Platzhalter für `package:in_app_purchase_android` – nur die Teile, die Selfify nutzt (lib/billing/play_gateway.dart).
// Alles ist wirkungslos: In Versionen ohne Kauf wird nie etwas davon aufgerufen (purchaseGatewayProvider liefert dort
// null), und es gibt keinen nativen Code. Signaturen wie im echten Paket (in_app_purchase_android 0.5.5).

import 'package:in_app_purchase/in_app_purchase.dart';

import 'billing_client_wrappers.dart';

class GooglePlayProductDetails extends ProductDetails {
  GooglePlayProductDetails._({
    required super.id,
    required super.title,
    required super.description,
    required super.price,
    required super.rawPrice,
    required super.currencyCode,
    required this.productDetails,
    required super.currencySymbol,
    this.subscriptionIndex,
  });

  static List<GooglePlayProductDetails> fromProductDetails(ProductDetailsWrapper productDetails) => [
        for (var i = 0; i < (productDetails.subscriptionOfferDetails?.length ?? 0); i++)
          GooglePlayProductDetails._(
            id: productDetails.productId,
            title: productDetails.title,
            description: productDetails.description,
            price: '',
            rawPrice: 0,
            currencyCode: '',
            currencySymbol: '',
            productDetails: productDetails,
            subscriptionIndex: i,
          ),
      ];

  final ProductDetailsWrapper productDetails;
  final int? subscriptionIndex;

  String? get offerToken => subscriptionIndex != null && productDetails.subscriptionOfferDetails != null
      ? productDetails.subscriptionOfferDetails![subscriptionIndex!].offerIdToken
      : null;
}

class GooglePlayPurchaseDetails extends PurchaseDetails {
  GooglePlayPurchaseDetails({
    super.purchaseID,
    required super.productID,
    required super.verificationData,
    required super.transactionDate,
    required super.status,
  });
}

class ChangeSubscriptionParam {
  ChangeSubscriptionParam({required this.oldPurchaseDetails, this.replacementMode});

  final GooglePlayPurchaseDetails oldPurchaseDetails;
  final ReplacementMode? replacementMode;
}

class GooglePlayPurchaseParam extends PurchaseParam {
  GooglePlayPurchaseParam({
    required super.productDetails,
    super.applicationUserName,
    this.changeSubscriptionParam,
    this.offerToken,
    this.obfuscatedProfileId,
  });

  final ChangeSubscriptionParam? changeSubscriptionParam;
  final String? offerToken;
  final String? obfuscatedProfileId;
}

class QueryPurchaseDetailsResponse {
  QueryPurchaseDetailsResponse({required this.pastPurchases, this.error});

  final List<GooglePlayPurchaseDetails> pastPurchases;
  final IAPError? error;
}

class InAppPurchaseAndroidPlatformAddition {
  Future<QueryPurchaseDetailsResponse> queryPastPurchases({String? applicationUserName}) async =>
      QueryPurchaseDetailsResponse(pastPurchases: []);
}
