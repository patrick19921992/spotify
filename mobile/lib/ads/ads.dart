import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

/// Werbebanner-Kennung aus AdMob. Wird beim Bauen übergeben (`--dart-define=ADMOB_BANNER_ID=ca-app-pub-…/…`).
/// Ohne Angabe gilt die Test-Kennung von Google: Es erscheinen nur als „Test Ad“ markierte Anzeigen.
const _bannerIdDefine = String.fromEnvironment('ADMOB_BANNER_ID');

/// Test-Kennung von Google für Android-Banner.
const adTestBannerUnitId = 'ca-app-pub-3940256099942544/6300978111';

/// Die Kennung, die die App verwendet (leer übergeben = Test-Kennung, damit eine vergessene Variable nie Werbung
/// ohne gültige Kennung bedeutet).
String get adBannerUnitId => _bannerIdDefine.isEmpty ? adTestBannerUnitId : _bannerIdDefine;

/// Werbung in der Play-Version (Google AdMob): erst die Einwilligung abfragen (Pflicht in der EU/UK), dann das
/// SDK starten. Nichts davon läuft, solange keine Werbung angezeigt werden soll.
class AdsService {
  AdsService._();

  static Future<bool>? _ready;

  /// Fragt – falls nötig – die Einwilligung ab und startet das SDK. true = Anzeigen dürfen geladen werden.
  /// Läuft nur einmal; weitere Aufrufe warten auf dasselbe Ergebnis.
  static Future<bool> prepare() => _ready ??= _prepare();

  static Future<bool> _prepare() async {
    try {
      final done = Completer<void>();
      ConsentInformation.instance.requestConsentInfoUpdate(
        ConsentRequestParameters(),
        () => ConsentForm.loadAndShowConsentFormIfRequired((_) {
          if (!done.isCompleted) done.complete();
        }),
        (_) {
          if (!done.isCompleted) done.complete();
        },
      );
      await done.future.timeout(const Duration(seconds: 45));
      if (!await ConsentInformation.instance.canRequestAds()) return false;
      // Inhalte für ein breites Publikum, auch Familien
      await MobileAds.instance.updateRequestConfiguration(
        RequestConfiguration(maxAdContentRating: MaxAdContentRating.pg),
      );
      await MobileAds.instance.initialize();
      return true;
    } catch (e) {
      debugPrint('Werbung nicht verfügbar: $e');
      _ready = null; // beim nächsten Mal noch einmal versuchen
      return false;
    }
  }

  /// Muss die App einen Knopf „Datenschutz-Einstellungen für Werbung“ zeigen? (EU/UK: ja, wenn der Benutzer
  /// seine Einwilligung später ändern können muss.)
  static Future<bool> privacyOptionsRequired() async {
    try {
      return await ConsentInformation.instance.getPrivacyOptionsRequirementStatus() ==
          PrivacyOptionsRequirementStatus.required;
    } catch (_) {
      return false;
    }
  }

  static Future<void> showPrivacyOptions() async {
    try {
      await ConsentForm.showPrivacyOptionsForm((_) {});
    } catch (e) {
      debugPrint('Datenschutz-Einstellungen nicht verfügbar: $e');
    }
  }
}
