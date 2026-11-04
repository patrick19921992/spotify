// Platzhalter für `package:google_mobile_ads` – nur die Teile, die Selfify nutzt (lib/ads/ads.dart, ad_banner.dart).
// Alles ist wirkungslos: In Versionen ohne Werbung wird nie etwas davon aufgerufen (adsVisibleProvider ist dort immer
// false), und es gibt keinen nativen Code.

import 'package:flutter/widgets.dart';

class FormError {
  final int errorCode = 0;
  final String message = '';
}

class ConsentRequestParameters {
  ConsentRequestParameters();
}

typedef OnConsentInfoUpdateSuccessListener = void Function();
typedef OnConsentInfoUpdateFailureListener = void Function(FormError error);
typedef OnConsentFormDismissedListener = void Function(FormError? error);

enum PrivacyOptionsRequirementStatus { unknown, notRequired, required }

class ConsentInformation {
  ConsentInformation._();
  static final ConsentInformation instance = ConsentInformation._();

  void requestConsentInfoUpdate(
    ConsentRequestParameters params,
    OnConsentInfoUpdateSuccessListener successListener,
    OnConsentInfoUpdateFailureListener failureListener,
  ) {}

  Future<bool> canRequestAds() async => false;

  Future<PrivacyOptionsRequirementStatus> getPrivacyOptionsRequirementStatus() async =>
      PrivacyOptionsRequirementStatus.notRequired;
}

class ConsentForm {
  static Future<void> loadAndShowConsentFormIfRequired(OnConsentFormDismissedListener listener) async => listener(null);

  static Future<void> showPrivacyOptionsForm(OnConsentFormDismissedListener listener) async => listener(null);
}

class MaxAdContentRating {
  static final String unspecified = '';
  static final String g = 'G';
  static final String pg = 'PG';
  static final String t = 'T';
  static final String ma = 'MA';
}

class RequestConfiguration {
  final String? maxAdContentRating;
  RequestConfiguration({this.maxAdContentRating});
}

class InitializationStatus {}

class MobileAds {
  MobileAds._();
  static final MobileAds instance = MobileAds._();

  Future<InitializationStatus> initialize() async => InitializationStatus();

  Future<void> updateRequestConfiguration(RequestConfiguration requestConfiguration) async {}
}

class AdRequest {
  const AdRequest();
}

class AdSize {
  final int width;
  final int height;
  const AdSize({required this.width, required this.height});

  static const AdSize banner = AdSize(width: 320, height: 50);
}

class LoadAdError {
  final int code = 0;
  final String message = '';
}

abstract class Ad {
  Future<void> dispose() async {}
}

typedef AdLoadedCallback = void Function(Ad ad);
typedef AdFailedToLoadCallback = void Function(Ad ad, LoadAdError error);

class BannerAdListener {
  final AdLoadedCallback? onAdLoaded;
  final AdFailedToLoadCallback? onAdFailedToLoad;
  const BannerAdListener({this.onAdLoaded, this.onAdFailedToLoad});
}

class BannerAd extends Ad {
  final String adUnitId;
  final AdSize size;
  final AdRequest request;
  final BannerAdListener listener;

  BannerAd({required this.adUnitId, required this.size, required this.request, required this.listener});

  Future<void> load() async {}
}

class AdWidget extends StatelessWidget {
  final Ad ad;
  const AdWidget({super.key, required this.ad});

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
