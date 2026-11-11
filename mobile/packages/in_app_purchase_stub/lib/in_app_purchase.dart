// Platzhalter für `package:in_app_purchase` – nur die Teile, die Selfify nutzt (lib/billing/play_gateway.dart).
// Alles ist wirkungslos: In Versionen ohne Kauf wird nie etwas davon aufgerufen (purchaseGatewayProvider liefert dort
// null), und es gibt keinen nativen Code. Signaturen wie im echten Paket (in_app_purchase_platform_interface 1.4.1).

enum PurchaseStatus { pending, purchased, error, restored, canceled }

class IAPError {
  IAPError({required this.source, required this.code, required this.message, this.details});

  final String source;
  final String code;
  final String message;
  final dynamic details;

  @override
  String toString() => 'IAPError(code: $code, source: $source, message: $message, details: $details)';
}

class ProductDetails {
  ProductDetails({
    required this.id,
    required this.title,
    required this.description,
    required this.price,
    required this.rawPrice,
    required this.currencyCode,
    this.currencySymbol = '',
  });

  final String id;
  final String title;
  final String description;
  final String price;
  final double rawPrice;
  final String currencyCode;
  final String currencySymbol;
}

class ProductDetailsResponse {
  ProductDetailsResponse({required this.productDetails, required this.notFoundIDs, this.error});

  final List<ProductDetails> productDetails;
  final List<String> notFoundIDs;
  final IAPError? error;
}

class PurchaseParam {
  PurchaseParam({required this.productDetails, this.applicationUserName});

  final ProductDetails productDetails;
  final String? applicationUserName;
}

class PurchaseVerificationData {
  PurchaseVerificationData({
    required this.localVerificationData,
    required this.serverVerificationData,
    required this.source,
  });

  final String localVerificationData;
  final String serverVerificationData;
  final String source;
}

class PurchaseDetails {
  PurchaseDetails({
    this.purchaseID,
    required this.productID,
    required this.verificationData,
    required this.transactionDate,
    required this.status,
  });

  final String? purchaseID;
  final String productID;
  final PurchaseVerificationData verificationData;
  final String? transactionDate;
  PurchaseStatus status;
  IAPError? error;
  bool pendingCompletePurchase = false;
}

class InAppPurchase {
  InAppPurchase._();
  static final InAppPurchase instance = InAppPurchase._();

  Stream<List<PurchaseDetails>> get purchaseStream => const Stream.empty();

  Future<bool> isAvailable() async => false;

  Future<ProductDetailsResponse> queryProductDetails(Set<String> identifiers) async =>
      ProductDetailsResponse(productDetails: [], notFoundIDs: identifiers.toList());

  Future<bool> buyNonConsumable({required PurchaseParam purchaseParam}) async => false;

  Future<void> completePurchase(PurchaseDetails purchase) async {}

  Future<void> restorePurchases({String? applicationUserName}) async {}
}
