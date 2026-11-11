// Premium Teil 2: Laufzeiten mit Ersparnis und Angeboten, Wechsel der Laufzeit, einzeln schaltbare
// Premium-Leistungen (Tonqualität, Videos, Songtexte, Wünsche, Überspringen, Abzeichen, Werbung) – und dass ohne
// eingeschaltete Schalter (und in der GitHub-Version) alles wie bisher bleibt.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:selfify/billing/billing.dart';
import 'package:selfify/core/flavor.dart';
import 'package:selfify/data/api.dart';
import 'package:selfify/data/models.dart';
import 'package:selfify/player/player.dart';
import 'package:selfify/player/skip_limit.dart';
import 'package:selfify/state/app_config.dart';
import 'package:selfify/state/auth.dart';
import 'package:selfify/state/connectivity.dart';
import 'package:selfify/state/offline.dart';
import 'package:selfify/state/offline_access.dart';
import 'package:selfify/state/premium_access.dart';
import 'package:selfify/state/settings.dart';
import 'package:selfify/ui/screens/player_lyrics.dart';
import 'package:selfify/ui/screens/premium_screen.dart';
import 'package:selfify/ui/screens/settings_screen.dart';
import 'package:selfify/ui/screens/video_screen.dart';
import 'package:selfify/ui/screens/wishes_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'support/fake_audio.dart';
import 'support/fakes.dart';

const _server = 'https://musik.test';
final _now = DateTime.utc(2026, 11, 11, 12);

/// Vergleich ohne geschützte Leerzeichen (intl setzt „0,75 €“ mit U+00A0).
String _plain(String? text) => (text ?? '').replaceAll(' ', ' ');

Finder _text(String text) => find.byWidgetPredicate((w) => w is Text && _plain(w.data) == text);

/// Premium-Stand vom Server (neuer Server: mit Umfang und Sperren).
PremiumStatus status({
  bool active = false,
  bool unlimited = false,
  List<String>? features,
  List<String>? locked,
  List<String> premiumOnly = const [],
  bool badge = false,
  PlaySubscription? play,
}) =>
    PremiumStatus(
      active: active,
      unlimited: unlimited,
      until: active && !unlimited ? DateTime.utc(2026, 12, 11) : null,
      checkedAt: _now,
      features: features,
      locked: locked,
      premiumOnly: premiumOnly,
      badge: badge,
      play: play,
    );

PlaySubscription sub(String basePlanId, {String state = 'active'}) => PlaySubscription(
      productId: 'premium',
      state: state,
      expiresAt: DateTime.utc(2026, 12, 11),
      autoRenewing: state == 'active',
      basePlanId: basePlanId,
    );

Future<void> settle([int ms = 60]) => Future<void>.delayed(Duration(milliseconds: ms));

Future<void> waitFor(bool Function() condition, String what) async {
  for (var i = 0; i < 300; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue, reason: what);
}

/// Container wie in der App (ohne Oberfläche).
Future<ProviderContainer> container({
  required FakeApi api,
  AppConfig config = const AppConfig(),
  Map<String, Object> prefs = const {},
  DateTime Function()? clock,
  FakeAppConfig? appConfig,
  List<Override> more = const [],
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final c = ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWithValue(await SharedPreferences.getInstance()),
    authProvider.overrideWith(() => FakeAuth(api)),
    appConfigProvider.overrideWith(() => appConfig ?? FakeAppConfig(config)),
    connectivityProvider.overrideWith((ref) => Stream.value([ConnectivityResult.wifi])),
    clockProvider.overrideWithValue(clock ?? () => _now),
    ...more,
  ]);
  addTearDown(c.dispose);
  c.listen(authProvider, (_, _) {});
  c.listen(appConfigProvider, (_, _) {});
  c.listen(connectivityProvider, (_, _) {});
  await c.read(authProvider.future);
  await c.read(appConfigProvider.future);
  await settle();
  return c;
}

// ---------------------------------------------------------------- Hilfsklassen

/// Videoplayer, der jedes Video ablehnt (der Server antwortet z. B. mit 403).
class _FailingVideoPlatform extends VideoPlayerPlatform {
  @override
  Future<void> init() async {}
  @override
  Future<int?> create(DataSource dataSource) async => throw PlatformException(code: 'Source error');
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async => throw PlatformException(code: 'Source error');
  @override
  Future<void> dispose(int playerId) async {}
}

/// Videoseite erst öffnen, wenn Anmeldung und Premium-Stand geladen sind.
class _VideoAfterLogin extends ConsumerWidget {
  final Track track;
  const _VideoAfterLogin(this.track);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(apiProvider) == null ||
        !ref.watch(premiumProvider).hasValue ||
        !ref.watch(appConfigProvider).hasValue) {
      return const SizedBox();
    }
    return VideoScreen(trackId: track.id, track: track);
  }
}

/// Erst zeigen, wenn Anmeldung, Einstellungen und Premium-Stand geladen sind (wie nach dem App-Start).
class _AfterPremium extends ConsumerWidget {
  final Widget child;
  const _AfterPremium(this.child);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(apiProvider) == null || !ref.watch(premiumProvider).hasValue || !ref.watch(appConfigProvider).hasValue) {
      return const SizedBox();
    }
    return child;
  }
}

/// Lädt „Dateien“ herunter und merkt sich die Links.
class _DownloadApi extends FakeApi {
  final urls = <String>[];
  _DownloadApi() : super(admin: false);

  @override
  Future<Response<dynamic>> downloadFile(String url, String savePath,
      {void Function(int received, int total)? onProgress, CancelToken? cancelToken}) async {
    urls.add(url);
    await File(savePath).writeAsBytes(List.filled(100, 1));
    return Response(
      requestOptions: RequestOptions(path: url),
      statusCode: 200,
      headers: Headers.fromMap({
        'content-type': ['audio/ogg'],
      }),
    );
  }
}

// ---------------------------------------------------------------- Tests

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => channelOverride = null);

  group('Laufzeiten rechnen (plans.dart)', () {
    test('parsePeriod / wholeMonths', () {
      expect(parsePeriod('P1M'), (years: 0, months: 1, weeks: 0, days: 0));
      expect(parsePeriod('P1Y'), (years: 1, months: 0, weeks: 0, days: 0));
      expect(parsePeriod('P3D'), (years: 0, months: 0, weeks: 0, days: 3));
      expect(parsePeriod('P'), isNull);
      expect(parsePeriod(''), isNull);
      expect(parsePeriod('1M'), isNull);
      expect(parsePeriod('PXM'), isNull);
      expect(wholeMonths(parsePeriod('P6M')), 6);
      expect(wholeMonths(parsePeriod('P1Y')), 12);
      expect(wholeMonths(parsePeriod('P12M')), 12);
      expect(wholeMonths(parsePeriod('P1W')), isNull);
      expect(wholeMonths(parsePeriod('P1M3D')), isNull);
      expect(wholeMonths(null), isNull);
    });

    test('periodLabel / perPeriod (Tabelle)', () {
      const table = {
        'P1W': ('Wöchentlich', 'pro Woche'),
        'P7D': ('Wöchentlich', 'pro Woche'),
        'P4W': ('Alle 4 Wochen', 'alle 4 Wochen'),
        'P1M': ('Monatlich', 'pro Monat'),
        'P2M': ('Alle 2 Monate', 'alle 2 Monate'),
        'P3M': ('Vierteljährlich', 'pro Quartal'),
        'P6M': ('Halbjährlich', 'pro Halbjahr'),
        'P1Y': ('Jährlich', 'pro Jahr'),
        'P12M': ('Jährlich', 'pro Jahr'),
        'P9M': ('Alle 9 Monate', 'alle 9 Monate'),
        'P3D': ('Abo', ''),
        'quatsch': ('Abo', ''),
      };
      table.forEach((iso, expected) {
        expect(periodLabel(iso), expected.$1, reason: iso);
        expect(perPeriod(iso), expected.$2, reason: iso);
      });
    });

    test('durationText', () {
      expect(durationText('P1M', 3), '3 Monate');
      expect(durationText('P1M', 1), '1 Monat');
      expect(durationText('P1W', 1), '1 Woche');
      expect(durationText('P1W', 2), '2 Wochen');
      expect(durationText('P3D', 1), '3 Tage');
      expect(durationText('P1D', 1), '1 Tag');
      expect(durationText('P1Y', 1), '1 Jahr');
      expect(durationText('P1Y', 2), '2 Jahre');
      expect(durationText('P1M', 0), '1 Monat', reason: 'mindestens einmal');
    });

    test('pricingFor: Prüfwerte (Monatspreis, Ersparnis abgerundet, fehlende Preise)', () {
      final monthly = storePlan();
      PlanPricing p(StorePlan plan, [List<StorePlan>? shown]) => pricingFor(plan, shown ?? [monthly, plan]);

      final half = p(storePlan(id: 'halbjaehrlich', period: 'P6M', micros: 4990000, price: '4,99 €'));
      expect(_plain(half.perMonth), '0,83 €');
      expect(half.savePercent, 15);
      expect(half.saveText, 'spare 15 %');
      expect(_plain(half.perMonthText), 'entspricht 0,83 € pro Monat');

      final year = p(storePlan(id: 'jaehrlich', period: 'P1Y', micros: 8990000, price: '8,99 €'));
      expect(_plain(year.perMonth), '0,75 €');
      expect(year.savePercent, 24);

      final same = p(storePlan(id: 'jaehrlich', period: 'P1Y', micros: 11880000, price: '11,88 €'));
      expect(_plain(same.perMonth), '0,99 €');
      expect(same.savePercent, 0);
      expect(same.saveText, isNull, reason: '0 % → kein Chip');

      final dearer = p(storePlan(id: 'jaehrlich', period: 'P1Y', micros: 12990000, price: '12,99 €'));
      expect(_plain(dearer.perMonth), '1,08 €');
      expect(dearer.savePercent, lessThan(0));
      expect(dearer.saveText, isNull, reason: 'teurer → kein Chip, kein Hinweis');

      final yearOnly = storePlan(id: 'jaehrlich', period: 'P1Y', micros: 8990000, price: '8,99 €');
      final alone = pricingFor(yearOnly, [yearOnly]);
      expect(_plain(alone.perMonth), '0,75 €');
      expect(alone.savePercent, isNull, reason: 'kein monatlicher Plan zum Vergleich');

      final usd = p(storePlan(id: 'jaehrlich', period: 'P1Y', micros: 8990000, price: r'$8.99', currency: 'USD'));
      expect(_plain(usd.perMonth), contains('0,75'));
      expect(usd.savePercent, isNull, reason: 'andere Währung');

      final free = p(storePlan(id: 'jaehrlich', period: 'P1Y', micros: 0, price: '8,99 €'));
      expect(free.perMonth, isNull);
      expect(free.savePercent, isNull);

      expect(pricingFor(monthly, [monthly]).perMonth, isNull, reason: 'monatlich selbst: kein Monatspreis');
      expect(pricingFor(monthly, [monthly]).savePercent, isNull);

      // Monatlicher Plan ohne Preis taugt nicht als Vergleich
      final monthlyZero = storePlan(micros: 0);
      expect(pricingFor(yearOnly, [monthlyZero, yearOnly]).savePercent, isNull);
      // Unlesbarer Zeitraum
      expect(pricingFor(storePlan(id: 'x', period: 'P3D'), [monthly]).perMonth, isNull);
    });

    test('regularPriceText: fehlender Preis → „Preis im Play Store“', () {
      expect(regularPriceText(storePlan()), '0,99 € pro Monat');
      expect(regularPriceText(storePlan(price: '')), 'Preis im Play Store');
      expect(regularPriceText(storePlan(period: 'P3D', price: '1 €')), '1 €');
    });

    StoreOffer offer(String id, List<StorePhase> intro) => StoreOffer(
          productId: 'premium',
          basePlanId: 'monatlich',
          offerId: id,
          phases: [
            ...intro,
            const StorePhase(
                formattedPrice: '0,99 €', priceMicros: 990000, currencyCode: 'EUR', billingPeriod: 'P1M', infinite: true),
          ],
        );
    const freeWeek = StorePhase(formattedPrice: 'Kostenlos', priceMicros: 0, currencyCode: 'EUR', billingPeriod: 'P1W', cycles: 1);
    const freeMonth = StorePhase(formattedPrice: 'Kostenlos', priceMicros: 0, currencyCode: 'EUR', billingPeriod: 'P1M', cycles: 1);
    const intro49 =
        StorePhase(formattedPrice: '0,49 €', priceMicros: 490000, currencyCode: 'EUR', billingPeriod: 'P1M', cycles: 3);
    const intro29 =
        StorePhase(formattedPrice: '0,29 €', priceMicros: 290000, currencyCode: 'EUR', billingPeriod: 'P1M', cycles: 3);
    const once = StorePhase(
        formattedPrice: '1,99 €', priceMicros: 1990000, currencyCode: 'EUR', billingPeriod: 'P3M', cycles: 1, once: true);

    test('chooseOffer: Gratis vor Rabatt, längste Gratiszeit, sonst günstigster, Gleichstand → erstes', () {
      final base = storePlan().base;
      expect(chooseOffer([base]), isNull, reason: 'nur der Basis-Plan');
      expect(chooseOffer([]), isNull);
      expect(chooseOffer([base, offer('rabatt', [intro49]), offer('woche', [freeWeek])])!.offerId, 'woche');
      expect(chooseOffer([offer('woche', [freeWeek]), offer('monat', [freeMonth])])!.offerId, 'monat');
      expect(chooseOffer([offer('a', [intro49]), offer('b', [intro29])])!.offerId, 'b');
      expect(chooseOffer([offer('a', [intro49]), offer('b', [intro49])])!.offerId, 'a');
      expect(chooseOffer([offer('a', [freeMonth]), offer('b', [freeMonth])])!.offerId, 'a');
    });

    test('offerText: Beispiele', () {
      expect(_plain(offerText(offer('monat', [freeMonth]))), '1 Monat gratis, danach 0,99 € pro Monat');
      expect(_plain(offerText(offer('rabatt', [intro49]))), '0,49 € pro Monat für 3 Monate, danach 0,99 € pro Monat');
      expect(_plain(offerText(offer('beides', [freeWeek, intro49]))),
          '1 Woche gratis, danach 0,49 € pro Monat für 3 Monate, danach 0,99 € pro Monat');
      expect(_plain(offerText(offer('einmal', [once]))), '1,99 € für 3 Monate, danach 0,99 € pro Monat');
      expect(offerText(storePlan().base), isNull, reason: 'keine Phase vor der regulären');
      expect(offerText(null), isNull);
      expect(hasFreeTrial(offer('monat', [freeMonth])), isTrue);
      expect(hasFreeTrial(offer('rabatt', [intro49])), isFalse);
      expect(hasFreeTrial(null), isFalse);
    });

    test('shownPlans: Reihenfolge und Auswahl aus dem Dashboard, sonst natürlich; Empfehlung', () {
      final products = [
        storeProduct([
          storePlan(id: 'jaehrlich', period: 'P1Y', micros: 8990000),
          storePlan(id: 'woche', period: 'P1W', micros: 290000),
          storePlan(id: 'monatlich'),
          storePlan(id: 'komisch', period: 'P3X'),
          storePlan(id: 'halbjaehrlich', period: 'P6M', micros: 4990000),
        ]),
      ];
      List<String> ids(AppConfig c) => [for (final p in shownPlans(products, c)) p.basePlanId];

      expect(ids(const AppConfig(billingProductIds: ['premium'])),
          ['woche', 'monatlich', 'halbjaehrlich', 'jaehrlich', 'komisch'],
          reason: 'leer = alle, kürzeste zuerst, unlesbare ans Ende');
      expect(ids(const AppConfig(billingProductIds: ['premium'], billingBasePlans: ['jaehrlich', 'monatlich'])),
          ['jaehrlich', 'monatlich'],
          reason: 'genau die eingestellten, in dieser Reihenfolge');
      expect(ids(const AppConfig(billingProductIds: ['premium'], billingBasePlans: ['gibtsnicht'])), isEmpty);
      expect(BillingText.plansMissing('gibtsnicht'),
          'Die eingestellten Laufzeiten wurden im Play Store nicht gefunden (gibtsnicht).');

      // Gleiche Kennung in zwei Produkten: Produktreihenfolge aus billingProductIds
      final two = [
        storeProduct([storePlan(id: 'monatlich', productId: 'b')], id: 'b'),
        storeProduct([storePlan(id: 'monatlich', productId: 'a')], id: 'a'),
      ];
      expect([for (final p in shownPlans(two, const AppConfig(billingProductIds: ['a', 'b'], billingBasePlans: ['monatlich']))) p.productId],
          ['a', 'b']);

      final shown = shownPlans(products, const AppConfig(billingProductIds: ['premium']));
      expect(recommendedPlan(shown, const AppConfig(billingRecommendedPlan: 'jaehrlich')), 'jaehrlich');
      expect(recommendedPlan(shown, const AppConfig(billingRecommendedPlan: 'fehlt')), isNull);
      expect(recommendedPlan(shown, const AppConfig()), isNull);
    });
  });

  group('Modelle: alter Server = heutiges Verhalten', () {
    test('AppConfig ohne neue Felder: Standardwerte', () {
      final c = AppConfig.fromJson({'ads_enabled': true, 'offline_requires_premium': true});
      expect(c.premiumOnly, isEmpty);
      expect(c.freeAudioQuality, 'normal');
      expect(c.freeRequestsPerWeek, 3);
      expect(c.freeSkipsPerHour, 6);
      expect(c.premiumBadgeEnabled, isFalse);
      expect(c.billingBasePlans, isEmpty);
      expect(c.billingRecommendedPlan, '');
    });

    test('AppConfig mit neuen Feldern; Ungültiges fällt auf Standard zurück', () {
      final c = AppConfig.fromJson({
        'premium_only': ['offline', 'video', 7, ''],
        'free_audio_quality': 'low',
        'free_requests_per_week': 0,
        'free_skips_per_hour': 2,
        'premium_badge_enabled': true,
        'billing_base_plans': ['monatlich', 'jaehrlich'],
        'billing_recommended_plan': 'jaehrlich',
      });
      expect(c.premiumOnly, ['offline', 'video']);
      expect(c.freeAudioQuality, 'low');
      expect(c.freeRequestsPerWeek, 0);
      expect(c.freeSkipsPerHour, 2);
      expect(c.premiumBadgeEnabled, isTrue);
      expect(c.billingBasePlans, ['monatlich', 'jaehrlich']);
      expect(c.billingRecommendedPlan, 'jaehrlich');
      final bad = AppConfig.fromJson({
        'free_audio_quality': 'original',
        'free_requests_per_week': -1,
        'free_skips_per_hour': 0,
        'billing_recommended_plan': 5,
      });
      expect(bad.freeAudioQuality, 'normal');
      expect(bad.freeRequestsPerWeek, 3);
      expect(bad.freeSkipsPerHour, 6);
      expect(bad.billingRecommendedPlan, '');
    });

    test('PremiumStatus: ohne features → aktiv heißt alles; mit features genau diese', () {
      final old = PremiumStatus.fromJson({'active': true});
      expect(old.features, isNull);
      expect(old.locked, isNull);
      expect(old.badge, isFalse);
      expect(PremiumFeature.all.every(old.has), isTrue);
      expect(old.hasAll, isTrue);
      final none = PremiumStatus.fromJson({'active': false});
      expect(PremiumFeature.all.any(none.has), isFalse);

      final part = PremiumStatus.fromJson({
        'active': true,
        'features': ['video', 'lyrics'],
        'premium_only': ['offline', 'video', 'lyrics'],
        'locked': ['offline'],
        'badge': true,
        'play': {'product_id': 'premium', 'state': 'active', 'base_plan_id': 'jaehrlich', 'offer_id': 'gratis'},
      });
      expect(part.has('video'), isTrue);
      expect(part.has('offline'), isFalse);
      expect(part.hasAll, isFalse);
      expect(part.locked, ['offline']);
      expect(part.premiumOnly, ['offline', 'video', 'lyrics']);
      expect(part.badge, isTrue);
      expect(part.play!.basePlanId, 'jaehrlich');
      expect(part.play!.offerId, 'gratis');
      expect(PlaySubscription.fromJson({'product_id': 'x', 'state': 'active'}).basePlanId, '');
    });

    test('WishQuota', () {
      final q = WishQuota.fromJson({'limited': true, 'limit': 3, 'used': 1, 'left': 2, 'resets_at': '2026-11-15T10:00:00Z'});
      expect(q.limited, isTrue);
      expect(q.limit, 3);
      expect(q.left, 2);
      expect(q.resetsAt, DateTime.utc(2026, 11, 15, 10));
      final open = WishQuota.fromJson({'limited': false, 'limit': null, 'used': 4, 'left': null, 'resets_at': null});
      expect(open.limited, isFalse);
      expect(open.limit, isNull);
      expect(open.used, 4);
      expect(wishQuotaText(open), isNull);
      expect(wishQuotaText(null), isNull);
      expect(wishQuotaText(q), 'Noch 2 von 3 Wünschen diese Woche');
      expect(wishQuotaText(const WishQuota(limited: true, limit: 0, left: 0)), 'Song-Wünsche gibt es mit Premium.');
      expect(wishQuotaBlocked(q), isFalse);
      expect(wishQuotaBlocked(const WishQuota(limited: true, limit: 3, used: 3, left: 0)), isTrue);
      expect(wishQuotaBlocked(open), isFalse);
    });
  });

  group('Wer darf was (premiumAccessProvider)', () {
    const all = AppConfig(premiumOnly: ['offline', 'hq_audio', 'video', 'lyrics', 'requests', 'skips']);

    test('Admins sind nie eingeschränkt', () {
      final access = PremiumAccess(isAdmin: true, config: all, status: status(locked: ['video', 'lyrics']));
      expect(PremiumFeature.all.every(access.allows), isTrue);
      expect(access.qualityCap, 'original');
    });

    test('Server sagt, was gesperrt ist (locked)', () {
      final access = PremiumAccess(isAdmin: false, config: all, status: status(locked: ['offline', 'hq_audio']));
      expect(access.allows('offline'), isFalse);
      expect(access.allows('hq_audio'), isFalse);
      expect(access.allows('video'), isTrue);
    });

    test('alter Server ohne features/locked: aktiv → alles, nicht aktiv → nur „für alle“', () {
      const config = AppConfig(premiumOnly: ['video']);
      final active = PremiumAccess(isAdmin: false, config: config, status: PremiumStatus(active: true, checkedAt: _now));
      expect(active.allows('video'), isTrue);
      final inactive = PremiumAccess(isAdmin: false, config: config, status: PremiumStatus(checkedAt: _now));
      expect(inactive.allows('video'), isFalse);
      expect(inactive.allows('lyrics'), isTrue, reason: 'nicht „nur Premium“');
    });

    test('Stand unbekannt (lädt, Fehler, abgemeldet): großzügig erlaubt', () {
      expect(const PremiumAccess(isAdmin: false, config: all).allows('video'), isTrue);
      expect(const PremiumAccess(isAdmin: false, config: all, status: PremiumStatus()).allows('video'), isTrue,
          reason: 'Platzhalter ohne checkedAt');
    });

    test('Qualitätsdeckel: original > high > normal > low', () {
      const config = AppConfig(premiumOnly: ['hq_audio']);
      final normal = PremiumAccess(isAdmin: false, config: config, status: status(features: []));
      expect(normal.qualityCap, 'normal');
      expect(normal.capQuality('original'), 'normal');
      expect(normal.capQuality('high'), 'normal');
      expect(normal.capQuality('normal'), 'normal');
      expect(normal.capQuality('low'), 'low');
      expect(normal.isCapped('original'), isTrue);
      expect(normal.isCapped('low'), isFalse);
      final low = PremiumAccess(
          isAdmin: false, config: const AppConfig(premiumOnly: ['hq_audio'], freeAudioQuality: 'low'), status: status());
      expect(low.capQuality('original'), 'low');
      expect(low.capQuality('normal'), 'low');
      final premium = PremiumAccess(isAdmin: false, config: config, status: status(active: true, features: ['hq_audio']));
      expect(premium.capQuality('original'), 'original');
      expect(effectiveQualityLabel('original', normal), 'Normal (AAC 160 kbit/s) – mehr mit Premium');
      expect(effectiveQualityLabel('low', normal), 'Datensparend (AAC 96 kbit/s)');
      expect(effectiveQualityLabel('original', premium), 'Original (beste Qualität)');
    });

    test('Schalter aus: der Premium-Stand wird dafür nicht abgefragt (wie bisher)', () async {
      final api = FakeApi(admin: false);
      final c = await container(api: api);
      c.listen(premiumAccessProvider, (_, _) {});
      await settle();
      expect(c.read(premiumAccessProvider).allows('video'), isTrue);
      expect(api.calls, isNot(contains('premium')));
    });

    test('Schalter an: Premium-Stand wird geladen und gilt', () async {
      final api = FakeApi(admin: false)..premiumStatus = status(features: [], locked: ['video'], premiumOnly: ['video']);
      final c = await container(api: api, config: const AppConfig(premiumOnly: ['video']));
      c.listen(premiumAccessProvider, (_, _) {});
      await waitFor(() => c.read(premiumAccessProvider).status != null, 'Stand geladen');
      expect(c.read(premiumAccessProvider).allows('video'), isFalse);
      expect(c.read(premiumAccessProvider).allows('lyrics'), isTrue);
    });
  });

  group('Tonqualität (hq_audio)', () {
    Future<(ProviderContainer, SelfifyAudioHandler)> bridge(FakeApi api, AppConfig config) async {
      useFakeAudioPlatform();
      final handler = SelfifyAudioHandler();
      addTearDown(handler.player.dispose);
      final c = await container(api: api, config: config, more: [
        audioHandlerProvider.overrideWithValue(handler),
        offlineProvider.overrideWith(() => FakeOffline()),
      ]);
      c.listen(playbackBridgeProvider, (_, _) {});
      c.listen(premiumAccessProvider, (_, _) {});
      await settle(100);
      return (c, handler);
    }

    String link(SelfifyAudioHandler handler) {
      final source = handler.resolveSource!(Track.fromJson(trackJson(1)), const MediaItem(id: '1', title: 'x'));
      return (source as UriAudioSource).uri.toString();
    }

    test('ohne Premium: Stream-Link gedeckelt (quality=normal), Einstellung bleibt gespeichert', () async {
      final api = FakeApi(admin: false)..premiumStatus = status(features: [], locked: ['hq_audio']);
      final (c, handler) = await bridge(api, const AppConfig(premiumOnly: ['hq_audio']));
      await waitFor(() => c.read(premiumAccessProvider).status != null, 'Stand geladen');
      expect(link(handler), contains('quality=normal'));
      expect(c.read(settingsProvider).wifiQuality, 'original', reason: 'nicht überschrieben');
    });

    test('Grenze „Datensparend“: quality=low', () async {
      final api = FakeApi(admin: false)..premiumStatus = status(features: [], locked: ['hq_audio']);
      final (c, handler) = await bridge(api, const AppConfig(premiumOnly: ['hq_audio'], freeAudioQuality: 'low'));
      await waitFor(() => c.read(premiumAccessProvider).status != null, 'Stand geladen');
      expect(link(handler), contains('quality=low'));
    });

    test('mit Premium, als Admin oder Schalter aus: Original (kein quality-Parameter)', () async {
      for (final (api, config) in [
        (FakeApi(admin: false)..premiumStatus = status(active: true, features: ['hq_audio']), const AppConfig(premiumOnly: ['hq_audio'])),
        (FakeApi(admin: true)..premiumStatus = status(), const AppConfig(premiumOnly: ['hq_audio'])),
        (FakeApi(admin: false), const AppConfig()),
      ]) {
        final (c, handler) = await bridge(api, config);
        await settle(100);
        expect(link(handler), isNot(contains('quality=')), reason: 'admin=${api.admin} ${config.premiumOnly}');
        c.dispose();
      }
    });

    test('Offline-Laden ohne Premium: quality=normal', () async {
      final dir = await Directory.systemTemp.createTemp('selfify_part2');
      addTearDown(() => dir.delete(recursive: true));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => dir.path,
      );
      final api = _DownloadApi()..premiumStatus = status(features: [], locked: ['hq_audio']);
      final c = await container(api: api, config: const AppConfig(premiumOnly: ['hq_audio']));
      c.listen(offlineProvider, (_, _) {});
      c.listen(offlineAccessProvider, (_, _) {});
      c.listen(premiumAccessProvider, (_, _) {});
      await waitFor(() => c.read(offlineProvider).loaded, 'Index geladen');
      await waitFor(() => c.read(premiumAccessProvider).status != null, 'Stand geladen');
      c.read(offlineProvider.notifier).downloadTracks([Track.fromJson(trackJson(3))]);
      await waitFor(() => api.urls.isNotEmpty, 'geladen');
      expect(api.urls.single, contains('quality=normal'));
      expect(c.read(settingsProvider).offlineQuality, 'original');
      // Fertig laden lassen, bevor der Container geschlossen wird
      await waitFor(() => c.read(offlineProvider).isDownloaded(3), 'gespeichert');
      await settle(200);
    });

    testWidgets('Einstellungen: wirksame Stufe mit „– mehr mit Premium“', (tester) async {
      final api = FakeApi(admin: false)..premiumStatus = status(features: [], locked: ['hq_audio'], premiumOnly: ['hq_audio']);
      await pumpScreen(tester, const SettingsScreen(),
          api: api, admin: false, config: const AppConfig(premiumOnly: ['hq_audio']), size: const Size(400, 3000));
      expect(find.text('Normal (AAC 160 kbit/s) – mehr mit Premium'), findsWidgets);
      expect(find.text('Original (beste Qualität)'), findsNothing);
      expectNoErrors(tester);
    });
  });

  group('Videos (video)', () {
    final videoTrack = Track.fromJson(trackJson(2, mediaType: 'video'));

    setUp(() => VideoPlayerPlatform.instance = _FailingVideoPlatform());

    testWidgets('ohne Premium: Sperransicht statt Player, „Als Ton abspielen“ spielt den Titel als Ton', (tester) async {
      useFakeAudioPlatform();
      final handler = SelfifyAudioHandler()
        ..resolveSource = (track, item) => AudioSource.uri(Uri.parse('https://x/${track.id}'), tag: item);
      final api = FakeApi(admin: false)..premiumStatus = status(features: [], locked: ['video'], premiumOnly: ['video']);
      await pumpScreen(tester, _VideoAfterLogin(videoTrack),
          api: api, admin: false, handler: handler, config: const AppConfig(premiumOnly: ['video']));
      expect(find.text(videoLockedMessage), findsOneWidget);
      expect(find.text('Als Ton abspielen'), findsOneWidget);
      expect(find.text('Zu Premium'), findsOneWidget);
      expect(api.calls, isNot(contains('streamStatus')), reason: 'gar nicht erst geladen');
      await tester.tap(find.text('Als Ton abspielen'));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(handler.tracks.map((t) => t.id), [2]);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('Server antwortet mit 403: dieselbe Sperransicht', (tester) async {
      // Stand noch „erlaubt“ (alter Stand), der Server sperrt aber
      final api = FakeApi(admin: false)
        ..premiumStatus = status(features: [])
        ..streamStatusCode = 403;
      await pumpScreen(tester, _VideoAfterLogin(videoTrack),
          api: api, admin: false, config: const AppConfig(premiumOnly: ['lyrics', 'video']));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // Ohne locked-Liste entscheidet der Umfang: Premium fehlt → gesperrt, also gar nicht geladen
      expect(find.text(videoLockedMessage), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('Server antwortet mit 403, obwohl die App „erlaubt“ glaubt: Sperransicht nach der Rückfrage', (tester) async {
      final api = FakeApi(admin: false)
        ..premiumStatus = status(active: true, features: ['video'], locked: [], premiumOnly: ['video'])
        ..streamStatusCode = 403;
      await pumpScreen(tester, _VideoAfterLogin(videoTrack),
          api: api, admin: false, config: const AppConfig(premiumOnly: ['video']));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(api.calls, contains('streamStatus'));
      expect(find.text(videoLockedMessage), findsOneWidget);
      expect(find.text('Als Ton abspielen'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('Schalter aus: kein Sperrtext, keine Rückfrage beim Server (wie bisher)', (tester) async {
      final api = FakeApi(admin: false);
      await pumpScreen(tester, _VideoAfterLogin(videoTrack), api: api, admin: false);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text(videoLockedMessage), findsNothing);
      expect(api.calls, isNot(contains('streamStatus')));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });
  });

  group('Songtexte (lyrics)', () {
    final track = Track.fromJson(trackJson(1));
    Widget card() => _AfterPremium(Scaffold(body: SingleChildScrollView(child: PlayerLyricsCard(track: track))));

    testWidgets('gesperrt: Sperrkarte, Songtext wird gar nicht abgerufen', (tester) async {
      final api = FakeApi(admin: false)..premiumStatus = status(features: [], locked: ['lyrics'], premiumOnly: ['lyrics']);
      await pumpScreen(tester, card(), api: api, admin: false, config: const AppConfig(premiumOnly: ['lyrics']));
      expect(find.text(lyricsLockedMessage), findsOneWidget);
      expect(find.text('Zu Premium'), findsOneWidget);
      expect(api.calls, isNot(contains('lyrics')));
      expectNoErrors(tester);
    });

    testWidgets('Server antwortet 403: Sperrkarte', (tester) async {
      final api = FakeApi(admin: false)
        ..lyricsError = const ApiException('Songtexte gibt es nur mit Premium.', statusCode: 403);
      await pumpScreen(tester, card(), api: api, admin: false);
      expect(find.text(lyricsLockedMessage), findsOneWidget);
      expect(find.textContaining('konnte nicht geladen werden'), findsNothing);
      expectNoErrors(tester);
    });

    testWidgets('frei (Premium oder Schalter aus): Songtext wie bisher', (tester) async {
      for (final (api, config) in [
        (FakeApi(admin: false)..premiumStatus = status(active: true, features: ['lyrics'], locked: []), const AppConfig(premiumOnly: ['lyrics'])),
        (FakeApi(admin: false), const AppConfig()),
      ]) {
        await pumpScreen(tester, card(), api: api, admin: false, config: config);
        expect(find.text(lyricsLockedMessage), findsNothing);
        expect(find.text('Is this the real life?'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('Premium-Bereich abgeschaltet: Sperrkarte ohne „Zu Premium“', (tester) async {
      final api = FakeApi(admin: false)..premiumStatus = status(features: [], locked: ['lyrics']);
      await pumpScreen(tester, card(),
          api: api, admin: false, config: const AppConfig(premiumOnly: ['lyrics'], premiumEnabled: false));
      expect(find.text(lyricsLockedMessage), findsOneWidget);
      expect(find.text('Zu Premium'), findsNothing);
    });
  });

  group('Song-Wünsche (requests)', () {
    const config = AppConfig(premiumOnly: ['requests']);

    FloatingActionButton fab(WidgetTester tester) => tester.widget<FloatingActionButton>(find.byType(FloatingActionButton));

    testWidgets('Kopfzeile „Noch 2 von 3“, Knopf frei', (tester) async {
      final api = FakeApi(admin: false)..quota = const WishQuota(limited: true, limit: 3, used: 1, left: 2);
      await pumpScreen(tester, const WishesScreen(), api: api, admin: false, channel: AppChannel.play, config: config);
      expect(find.text('Noch 2 von 3 Wünschen diese Woche'), findsOneWidget);
      expect(fab(tester).onPressed, isNotNull);
      expectNoErrors(tester);
    });

    testWidgets('nichts mehr frei: Knopf gesperrt, Hinweis mit Datum und Weg zu Premium', (tester) async {
      final api = FakeApi(admin: false)
        ..quota = WishQuota(limited: true, limit: 3, used: 3, left: 0, resetsAt: DateTime.utc(2026, 11, 15, 10));
      await pumpScreen(tester, const WishesScreen(), api: api, admin: false, channel: AppChannel.play, config: config);
      expect(find.text('Diese Woche sind keine Wünsche mehr frei – ab 15. Nov. 2026 wieder. Mit Premium unbegrenzt.'),
          findsOneWidget);
      expect(fab(tester).onPressed, isNull);
      expect(find.text('Premium'), findsOneWidget);
      expectNoErrors(tester);
    });

    testWidgets('Grenze 0: „Song-Wünsche gibt es mit Premium.“', (tester) async {
      final api = FakeApi(admin: false)..quota = const WishQuota(limited: true, limit: 0, used: 0, left: 0);
      await pumpScreen(tester, const WishesScreen(), api: api, admin: false, channel: AppChannel.play, config: config);
      expect(find.text('Song-Wünsche gibt es mit Premium.'), findsOneWidget);
      expect(fab(tester).onPressed, isNull);
    });

    testWidgets('alter Server (null) oder ohne Grenze (Premium): keine Kopfzeile', (tester) async {
      for (final quota in [null, const WishQuota(limited: false, used: 7)]) {
        final api = FakeApi(admin: false)..quota = quota;
        await pumpScreen(tester, const WishesScreen(), api: api, admin: false, channel: AppChannel.play, config: config);
        expect(find.textContaining('diese Woche'), findsNothing);
        expect(find.textContaining('Wünsche mehr frei'), findsNothing);
        expect(fab(tester).onPressed, isNotNull);
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('Schalter aus: keine Abfrage der Wochengrenze (wie bisher)', (tester) async {
      final api = FakeApi(admin: false)..quota = const WishQuota(limited: true, limit: 3, left: 0);
      await pumpScreen(tester, const WishesScreen(), api: api, admin: false, channel: AppChannel.play);
      expect(api.calls, isNot(contains('wishQuota')));
      expect(find.textContaining('Wünsche mehr frei'), findsNothing);
    });

    testWidgets('Senden: Grenze neu geladen; 429 vom Server zeigt dessen Meldung', (tester) async {
      final api = FakeApi(admin: false)..quota = const WishQuota(limited: true, limit: 3, used: 1, left: 2);
      await pumpScreen(tester, const WishesScreen(), api: api, admin: false, channel: AppChannel.play, config: config);
      final before = api.calls.where((c) => c == 'wishQuota').length;
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Hey Jude');
      api.quota = const WishQuota(limited: true, limit: 3, used: 2, left: 1);
      await tester.tap(find.text('Wunsch senden'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(api.calls.where((c) => c == 'wishQuota').length, greaterThan(before));
      expect(find.text('Noch 1 von 3 Wünschen diese Woche'), findsOneWidget);

      api.createWishError = const ApiException(
          'Du hast diese Woche schon 3 Wünsche geschickt. Mit Premium kannst du unbegrenzt wünschen.',
          statusCode: 429);
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Let It Be');
      await tester.tap(find.text('Wunsch senden'));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('Du hast diese Woche schon 3 Wünsche geschickt. Mit Premium kannst du unbegrenzt wünschen.'),
          findsOneWidget);
    });
  });

  group('Überspringen (skips, nur in der App)', () {
    late DateTime clock;

    setUp(() => clock = _now);

    Future<(ProviderContainer, SelfifyAudioHandler)> start(FakeApi api, AppConfig config) async {
      useFakeAudioPlatform();
      final handler = SelfifyAudioHandler();
      addTearDown(handler.player.dispose);
      final c = await container(api: api, config: config, clock: () => clock, more: [
        audioHandlerProvider.overrideWithValue(handler),
        offlineProvider.overrideWith(() => FakeOffline()),
      ]);
      c.listen(playbackBridgeProvider, (_, _) {});
      c.listen(skipLimitNoticeProvider, (_, _) {});
      await settle(100);
      unawaited(handler.playTracks([for (var i = 1; i <= 8; i++) Track.fromJson(trackJson(i))]));
      await settle();
      return (c, handler);
    }

    const limited = AppConfig(premiumOnly: ['skips'], freeSkipsPerHour: 2);

    test('Grenze 2: der dritte Sprung bleibt ohne Wirkung und zeigt den Hinweis; nach 1 h wieder frei', () async {
      final api = FakeApi(admin: false)..premiumStatus = status(features: [], locked: ['skips']);
      final (c, handler) = await start(api, limited);
      await waitFor(() => c.read(premiumAccessProvider).status != null, 'Stand geladen');
      expect(handler.allowSkip, isNotNull);

      await handler.skipToNext();
      await settle();
      await handler.skipToNext();
      await settle();
      expect(handler.player.currentIndex, 2);
      await handler.skipToNext();
      await settle();
      expect(handler.player.currentIndex, 2, reason: 'gesperrt');
      expect(c.read(skipLimitNoticeProvider), 'Du hast in dieser Stunde schon 2-mal übersprungen. Mit Premium unbegrenzt.');

      // Wahl eines späteren Titels in der Warteschlange zählt ebenso
      await handler.skipToQueueItem(5);
      await settle();
      expect(handler.player.currentIndex, 2);
      // Zurück ist frei – auch die Wahl eines früheren Titels
      await handler.skipToQueueItem(0);
      await settle();
      expect(handler.player.currentIndex, 0);
      await handler.skipToPrevious();
      await settle();

      // Eine Stunde später ist wieder frei
      clock = _now.add(const Duration(hours: 1, seconds: 1));
      await handler.skipToNext();
      await settle();
      expect(handler.player.currentIndex, 1);
    });

    test('Weiterspielen am Titelende zählt nicht', () async {
      final api = FakeApi(admin: false)..premiumStatus = status(features: [], locked: ['skips']);
      final (c, handler) = await start(api, limited);
      await waitFor(() => c.read(premiumAccessProvider).status != null, 'Stand geladen');
      final prefs = c.read(sharedPreferencesProvider);
      final limiter = SkipLimiter(
          prefs: prefs, key: SkipLimiter.keyFor(_server, 1), access: c.read(premiumAccessProvider));
      // Der Player wechselt von selbst zum nächsten Titel
      await handler.player.seek(Duration.zero, index: 1);
      await settle();
      expect(limiter.used(clock), 0);
      await handler.skipToNext();
      await settle();
      expect(limiter.used(clock), 1);
      expect(prefs.getString('skips.$_server|1'), isNotNull);
    });

    test('mit Premium oder als Admin: unbegrenzt', () async {
      for (final api in [
        FakeApi(admin: false)..premiumStatus = status(active: true, features: ['skips'], locked: []),
        FakeApi(admin: true),
      ]) {
        final (c, handler) = await start(api, limited);
        await settle(100);
        for (var i = 0; i < 5; i++) {
          await handler.skipToNext();
          await settle(20);
        }
        expect(handler.player.currentIndex, 5, reason: 'admin=${api.admin}');
        expect(c.read(skipLimitNoticeProvider), isNull);
        c.dispose();
      }
    });

    test('Schalter aus: keine Grenze (allowSkip == null, wie bisher)', () async {
      final (_, handler) = await start(FakeApi(admin: false), const AppConfig());
      expect(handler.allowSkip, isNull);
      expect(handler.onSkipBlocked, isNull);
    });

    test('SkipLimiter: höchstens 100 Einträge, ältere als 1 h fallen weg', () async {
      SharedPreferences.setMockInitialValues({
        'skips.k': jsonEncode([_now.subtract(const Duration(hours: 2)).millisecondsSinceEpoch]),
      });
      final prefs = await SharedPreferences.getInstance();
      final limiter = SkipLimiter(
        prefs: prefs,
        key: 'skips.k',
        access: PremiumAccess(
            isAdmin: false, config: const AppConfig(premiumOnly: ['skips'], freeSkipsPerHour: 100), status: status()),
      );
      expect(limiter.used(_now), 0);
      for (var i = 0; i < 100; i++) {
        expect(limiter.tryConsume(_now.add(Duration(seconds: i))), isTrue);
      }
      expect(limiter.tryConsume(_now.add(const Duration(seconds: 200))), isFalse);
      expect((jsonDecode(prefs.getString('skips.k')!) as List).length, 100);
    });
  });

  group('Abzeichen (badge)', () {
    testWidgets('nur bei badge == true sichtbar', (tester) async {
      for (final (badge, expected) in [(true, findsOneWidget), (false, findsNothing)]) {
        final api = FakeApi(admin: false)
          ..premiumStatus = status(active: true, badge: badge, features: PremiumFeature.all);
        await pumpScreen(tester, const SettingsScreen(),
            api: api, admin: false, config: const AppConfig(premiumBadgeEnabled: true), size: const Size(400, 3000));
        expect(find.byKey(const ValueKey('premium-badge')), expected, reason: 'badge=$badge');
        expectNoErrors(tester);
        await tester.pumpWidget(const SizedBox());
      }
    });
  });

  group('Werbung (no_ads)', () {
    Future<bool> adsVisible(PremiumStatus premium) async {
      channelOverride = AppChannel.play;
      final api = FakeApi(admin: false)..premiumStatus = premium;
      final c = await container(api: api, config: const AppConfig(adsEnabled: true));
      c.listen(adsVisibleProvider, (_, _) {});
      await waitFor(() => c.read(premiumProvider).hasValue, 'Premium geladen');
      await settle();
      return c.read(adsVisibleProvider);
    }

    test('Premium ohne „Keine Werbung“ im Umfang: Werbung sichtbar', () async {
      expect(await adsVisible(status(active: true, features: ['video', 'lyrics'])), isTrue);
    });

    test('Premium mit vollem Umfang, Abo oder alter Server: keine Werbung; ohne Premium: Werbung', () async {
      expect(await adsVisible(status(active: true, features: PremiumFeature.all)), isFalse);
      expect(await adsVisible(PremiumStatus(active: true, checkedAt: _now)), isFalse, reason: 'alter Server');
      expect(await adsVisible(status()), isTrue);
    });
  });

  group('Texte der Premium-Seite passen sich an', () {
    test('premiumBenefitsFor je Schalter', () {
      expect(premiumBenefitsFor(const AppConfig()), isEmpty, reason: 'Standard wie bisher');
      expect(premiumBenefitsFor(const AppConfig(offlineRequiresPremium: true, premiumOnly: ['offline'])),
          ['Musik aufs Gerät laden und offline hören']);
      expect(premiumBenefitsFor(const AppConfig(premiumOnly: ['hq_audio'])),
          ['Beste Tonqualität – ohne Premium höchstens 160 kbit/s']);
      expect(premiumBenefitsFor(const AppConfig(premiumOnly: ['hq_audio'], freeAudioQuality: 'low')),
          ['Beste Tonqualität – ohne Premium höchstens 96 kbit/s']);
      expect(premiumBenefitsFor(const AppConfig(premiumOnly: ['video'])), ['Videos ansehen – ohne Premium nur als Ton']);
      expect(premiumBenefitsFor(const AppConfig(premiumOnly: ['lyrics'])), ['Songtexte mitlesen']);
      expect(premiumBenefitsFor(const AppConfig(premiumOnly: ['requests'])), isEmpty, reason: 'Wünsche nicht sichtbar');
      expect(premiumBenefitsFor(const AppConfig(premiumOnly: ['requests']), wishlistVisible: true),
          ['Unbegrenzt Songs wünschen – ohne Premium 3 pro Woche']);
      expect(premiumBenefitsFor(const AppConfig(premiumOnly: ['requests'], freeRequestsPerWeek: 0), wishlistVisible: true),
          ['Songs wünschen']);
      expect(premiumBenefitsFor(const AppConfig(premiumOnly: ['skips'], freeSkipsPerHour: 4)),
          ['Unbegrenzt überspringen – ohne Premium 4-mal pro Stunde']);
      expect(premiumBenefitsFor(const AppConfig(premiumBadgeEnabled: true)), ['Premium-Abzeichen im Profil']);
      expect(
          premiumBenefitsFor(const AppConfig(
              premiumOnly: ['video', 'lyrics'], premiumBenefits: ['Eigene Zeile vom Betreiber'])),
          ['Eigene Zeile vom Betreiber'],
          reason: 'Betreiberzeilen haben Vorrang');
      channelOverride = AppChannel.play;
      expect(premiumBenefitsFor(const AppConfig(adsEnabled: true, premiumOnly: ['offline', 'video'], offlineRequiresPremium: true)),
          ['Musik aufs Gerät laden und offline hören', 'Keine Werbung', 'Videos ansehen – ohne Premium nur als Ton']);
    });

    testWidgets('Statuskarte: nur der Offline-Schalter → wörtlich wie bisher', (tester) async {
      final api = FakeApi(admin: false)
        ..premiumStatus = status(active: true, features: PremiumFeature.all, premiumOnly: ['offline']);
      await pumpScreen(tester, const PremiumScreen(),
          api: api, admin: false, config: const AppConfig(offlineRequiresPremium: true, premiumOnly: ['offline']));
      expect(find.text('Offline-Hören ist freigeschaltet.'), findsOneWidget);
      expectNoErrors(tester);
    });

    testWidgets('Statuskarte: nur der Offline-Schalter, Teil-Code ohne Offline → nicht „freigeschaltet“', (tester) async {
      final api = FakeApi(admin: false)
        ..premiumStatus = status(active: true, features: ['no_ads'], locked: ['offline'], premiumOnly: ['offline']);
      await pumpScreen(tester, const PremiumScreen(),
          api: api, admin: false, config: const AppConfig(offlineRequiresPremium: true, premiumOnly: ['offline']));
      expect(find.text('Offline-Hören ist freigeschaltet.'), findsNothing);
      expect(find.text('Freigeschaltet: ${PremiumFeature.names(const ['no_ads'])}'), findsOneWidget);
      expectNoErrors(tester);
    });

    test('Auswahl der Laufzeit merkt sich das Produkt (gleiche Kennung in zwei Produkten)', () {
      StorePlan plan(String product) {
        final offer = StoreOffer(productId: product, basePlanId: 'monatlich', phases: const [
          StorePhase(formattedPrice: '0,99 €', priceMicros: 990000, currencyCode: 'EUR', billingPeriod: 'P1M', infinite: true),
        ]);
        return StorePlan(productId: product, basePlanId: 'monatlich', title: 'Premium', base: offer);
      }

      final plans = [plan('premium'), plan('premium_neu')];
      expect(BillingState(plans: plans, selectedPlan: 'monatlich', selectedProduct: 'premium_neu').selected?.productId,
          'premium_neu');
      expect(BillingState(plans: plans, selectedPlan: 'monatlich').selected?.productId, 'premium');
    });

    testWidgets('Statuskarte mit weiteren Leistungen: voll, Teilumfang, ohne Premium', (tester) async {
      const config = AppConfig(premiumOnly: ['offline', 'video', 'lyrics'], offlineRequiresPremium: true);
      for (final (premium, text) in [
        (status(active: true, features: PremiumFeature.all), 'Alle Premium-Vorteile sind freigeschaltet.'),
        (status(active: true, features: ['video', 'lyrics']), 'Freigeschaltet: Videos ansehen, Songtexte'),
        (status(), 'Mit Premium: Offline-Hören, Videos ansehen, Songtexte'),
      ]) {
        final api = FakeApi(admin: false)..premiumStatus = premium;
        await pumpScreen(tester, const PremiumScreen(), api: api, admin: false, config: config);
        expect(find.text(text), findsOneWidget);
        expectNoErrors(tester);
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('Einstellungen › Premium: „Mehr Funktionen mit Premium“ nur mit weiteren Leistungen', (tester) async {
      // Stand nicht ladbar → Untertitel aus der Konfiguration
      for (final (config, text) in [
        (const AppConfig(premiumOnly: ['video']), 'Mehr Funktionen mit Premium'),
        (const AppConfig(premiumOnly: ['offline'], offlineRequiresPremium: true), 'Code einlösen, Werbung abschalten'),
        (const AppConfig(), 'Code einlösen, Werbung abschalten'),
      ]) {
        final api = FakeApi(admin: false)..premiumError = const ApiException('kein Netz');
        await pumpScreen(tester, const SettingsScreen(), api: api, admin: false, config: config, size: const Size(400, 3000));
        expect(find.text(text), findsOneWidget, reason: '${config.premiumOnly}');
        await tester.pumpWidget(const SizedBox());
      }
    });
  });

  group('Premium-Seite: Laufzeiten, Ersparnis, Angebote, Wechsel', () {
    const config = AppConfig(billingEnabled: true, billingProductIds: ['premium']);
    const big = Size(400, 2400);

    Future<FakeApi> pump(
      WidgetTester tester,
      FakePurchaseGateway gateway, {
      AppConfig cfg = config,
      PremiumStatus? premium,
      FakeApi? api,
    }) async {
      BillingController.restoreTimeout = const Duration(milliseconds: 120);
      addTearDown(() => BillingController.restoreTimeout = const Duration(seconds: 10));
      final fake = api ?? FakeApi(admin: false);
      fake.premiumStatus = premium ?? status();
      return pumpScreen(tester, const PremiumScreen(),
          api: fake,
          admin: false,
          channel: AppChannel.play,
          config: cfg,
          size: big,
          overrides: [purchaseGatewayProvider.overrideWithValue(gateway)]);
    }

    testWidgets('drei Laufzeiten: drei Karten, Ersparnis, Monatspreis, Empfohlen vorausgewählt, Kauf', (tester) async {
      final gateway = FakePurchaseGateway()..products = threePlanProducts();
      await pump(tester, gateway, cfg: const AppConfig(
          billingEnabled: true, billingProductIds: ['premium'], billingRecommendedPlan: 'jaehrlich'));
      expect(find.text('Monatlich'), findsOneWidget);
      expect(find.text('Halbjährlich'), findsOneWidget);
      expect(find.text('Jährlich'), findsOneWidget);
      expect(find.text('0,99 € pro Monat'), findsOneWidget);
      expect(find.text('4,99 € pro Halbjahr'), findsOneWidget);
      expect(find.text('8,99 € pro Jahr'), findsOneWidget);
      expect(find.text('spare 24 %'), findsOneWidget);
      expect(find.text('spare 15 %'), findsOneWidget);
      expect(_text('entspricht 0,83 € pro Monat'), findsOneWidget);
      expect(_text('entspricht 0,75 € pro Monat'), findsOneWidget);
      expect(find.text('Empfohlen'), findsOneWidget);
      expect(
        find.text('Abo über Google Play. Verlängert sich automatisch, bis du kündigst. Kündigen und Zahlungsart ändern '
            'kannst du jederzeit in Google Play. Beim Wechsel der Laufzeit rechnet Google die restliche Zeit an.'),
        findsOneWidget,
      );
      // Reihenfolge: kürzeste zuerst
      final y = [for (final t in ['Monatlich', 'Halbjährlich', 'Jährlich']) tester.getTopLeft(find.text(t)).dy];
      expect(y[0] < y[1] && y[1] < y[2], isTrue);

      expect(find.text('Jährlich abonnieren'), findsOneWidget, reason: 'empfohlene Laufzeit vorausgewählt');
      await tester.tap(find.text('Jährlich abonnieren'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(gateway.log, contains('buy:jaehrlich:1'));
      expectNoErrors(tester);
    });

    testWidgets('Laufzeit wählen: Antippen wählt aus, Knopf folgt', (tester) async {
      final gateway = FakePurchaseGateway()..products = threePlanProducts();
      await pump(tester, gateway);
      expect(find.text('Monatlich abonnieren'), findsOneWidget, reason: 'ohne Empfehlung die erste');
      await tester.tap(find.text('Halbjährlich'));
      await tester.pump();
      expect(find.text('Halbjährlich abonnieren'), findsOneWidget);
      await tester.tap(find.text('Halbjährlich abonnieren'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(gateway.log, contains('buy:halbjaehrlich:1'));
    });

    testWidgets('Dashboard-Auswahl: nur die eingestellten, in dieser Reihenfolge; fehlen alle → Meldung', (tester) async {
      final gateway = FakePurchaseGateway()..products = threePlanProducts();
      await pump(tester, gateway,
          cfg: const AppConfig(billingEnabled: true, billingProductIds: ['premium'], billingBasePlans: ['jaehrlich', 'monatlich']));
      expect(find.text('Halbjährlich'), findsNothing);
      expect(tester.getTopLeft(find.text('Jährlich')).dy, lessThan(tester.getTopLeft(find.text('Monatlich')).dy));
      await tester.pumpWidget(const SizedBox());

      await pump(tester, FakePurchaseGateway()..products = threePlanProducts(),
          cfg: const AppConfig(billingEnabled: true, billingProductIds: ['premium'], billingBasePlans: ['zweijaehrlich']));
      expect(find.text('Die eingestellten Laufzeiten wurden im Play Store nicht gefunden (zweijaehrlich).'), findsOneWidget);
      expect(find.textContaining('abonnieren'), findsOneWidget, reason: 'nur die Überschrift');
    });

    testWidgets('nur ein Plan: keine Ersparnis; Preis 0 → nur der formatierte Preis', (tester) async {
      final gateway = FakePurchaseGateway()
        ..products = [
          storeProduct([storePlan(id: 'jaehrlich', period: 'P1Y', micros: 8990000, price: '8,99 €')]),
        ];
      await pump(tester, gateway);
      expect(find.text('Jährlich'), findsOneWidget);
      expect(_text('entspricht 0,75 € pro Monat'), findsOneWidget);
      expect(find.textContaining('spare'), findsNothing);
      await tester.pumpWidget(const SizedBox());

      await pump(tester, FakePurchaseGateway()
        ..products = [
          storeProduct([
            storePlan(),
            storePlan(id: 'jaehrlich', period: 'P1Y', micros: 0, price: '8,99 €'),
          ]),
        ]);
      expect(find.text('8,99 € pro Jahr'), findsOneWidget);
      expect(find.textContaining('entspricht'), findsNothing);
      expect(find.textContaining('spare'), findsNothing);
    });

    testWidgets('Gratis-Angebot: Angebotszeile und „Gratis testen“; gekauft wird das Angebot', (tester) async {
      final gateway = FakePurchaseGateway()..products = threePlanProducts(monthlyOffer: freeTrial('monatlich'));
      await pump(tester, gateway);
      expect(find.text('1 Monat gratis, danach 0,99 € pro Monat'), findsOneWidget);
      expect(find.text('Gratis testen'), findsOneWidget);
      // Ohne Angebot der normale Knopf
      await tester.tap(find.text('Jährlich'));
      await tester.pump();
      expect(find.text('Jährlich abonnieren'), findsOneWidget);
      expect(find.text('Gratis testen'), findsNothing);
      await tester.tap(find.text('Monatlich'));
      await tester.pump();
      await tester.tap(find.text('Gratis testen'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(gateway.log, contains('buy:monatlich:1'));
    });

    testWidgets('mit Abo „monatlich“: „Dein Abo“, Wechsel zu jährlich über Google, Server bestätigt → Hinweis', (tester) async {
      final gateway = FakePurchaseGateway()..products = threePlanProducts();
      final api = FakeApi(admin: false);
      await pump(tester, gateway, api: api, premium: status(active: true, features: PremiumFeature.all, play: sub('monatlich')));
      expect(find.text('Dein Abo'), findsOneWidget);
      expect(find.textContaining('wechseln'), findsNothing, reason: 'eigene Laufzeit ausgewählt');
      expect(find.text('Monatlich abonnieren'), findsNothing, reason: 'mit Abo nichts zu kaufen');

      api.verifyResult = PlayVerifyResult(
          result: 'active', premium: status(active: true, features: PremiumFeature.all, play: sub('jaehrlich')));
      gateway.onBuy = (plan) =>
          const StorePurchase(productId: 'premium', token: 'token-wechsel-01', status: StorePurchaseStatus.purchased);
      await tester.tap(find.text('Jährlich'));
      await tester.pump();
      expect(find.text('Zu Jährlich wechseln'), findsOneWidget);
      await tester.tap(find.text('Zu Jährlich wechseln'));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(gateway.log, contains('change:jaehrlich:premium:1'));
      expect(api.calls, contains('verify:premium:token-wechsel-01'));
      expect(find.text(BillingText.changed), findsOneWidget);
      expect(find.text('Laufzeit gewechselt. Google rechnet die restliche Zeit deines bisherigen Abos an.'), findsOneWidget);
      expectNoErrors(tester);
    });

    testWidgets('Wechsel: Abo gehört zu einem anderen Google-Konto → verständliche Meldung', (tester) async {
      final gateway = FakePurchaseGateway()
        ..products = threePlanProducts()
        ..changeError = StateError(BillingText.changeNotOnDevice);
      await pump(tester, gateway, premium: status(active: true, features: PremiumFeature.all, play: sub('monatlich')));
      await tester.tap(find.text('Jährlich'));
      await tester.pump();
      await tester.tap(find.text('Zu Jährlich wechseln'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Dein Abo gehört zu einem anderen Google-Konto. Wechsle die Laufzeit bitte dort in Google Play.'),
          findsOneWidget);
    });

    testWidgets('Abo mit Zahlungsproblem (on_hold) oder unbekannter Laufzeit: keine Wechsel-Knöpfe', (tester) async {
      for (final play in [sub('monatlich', state: 'on_hold'), sub('')]) {
        final gateway = FakePurchaseGateway()..products = threePlanProducts();
        await pump(tester, gateway, premium: status(active: true, features: PremiumFeature.all, play: play));
        if (find.text('Jährlich').evaluate().isNotEmpty) {
          await tester.tap(find.text('Jährlich'));
          await tester.pump();
        }
        expect(find.textContaining('wechseln'), findsNothing, reason: play.state);
        expect(find.text('Abo verwalten'), findsWidgets, reason: 'Verwaltung in Google Play bleibt');
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('unbegrenztes volles Premium: nichts zu kaufen; unbegrenzter Teil-Code: Abo möglich', (tester) async {
      await pump(tester, FakePurchaseGateway()..products = threePlanProducts(),
          premium: status(active: true, unlimited: true, features: PremiumFeature.all));
      expect(find.text('Monatlich abonnieren'), findsNothing);
      await tester.pumpWidget(const SizedBox());

      await pump(tester, FakePurchaseGateway()..products = threePlanProducts(),
          premium: status(active: true, unlimited: true, features: ['video']));
      expect(find.text('Monatlich abonnieren'), findsOneWidget);
    });

    test('BillingController: Laufzeiten, Vorauswahl, Neuladen bei geänderter Auswahl im Dashboard', () async {
      channelOverride = AppChannel.play;
      final gateway = FakePurchaseGateway()..products = threePlanProducts();
      final api = FakeApi(admin: false)..premiumStatus = status();
      final appConfig = FakeAppConfig(
          const AppConfig(billingEnabled: true, billingProductIds: ['premium'], billingRecommendedPlan: 'halbjaehrlich'));
      final c = await container(api: api, appConfig: appConfig, more: [
        purchaseGatewayProvider.overrideWithValue(gateway),
      ]);
      c.listen(billingProvider, (_, _) {});
      await waitFor(() => c.read(billingProvider).plans.length == 3, 'geladen');
      expect(c.read(billingProvider).selectedPlan, 'halbjaehrlich');
      expect(c.read(billingProvider).selected!.basePlanId, 'halbjaehrlich');
      c.read(billingProvider.notifier).select(c.read(billingProvider).plans.first);
      expect(c.read(billingProvider).selectedPlan, 'monatlich');

      final loads = gateway.log.where((l) => l.startsWith('load:')).length;
      appConfig.config = const AppConfig(
          billingEnabled: true, billingProductIds: ['premium'], billingBasePlans: ['jaehrlich']);
      await c.read(appConfigProvider.notifier).refresh();
      await waitFor(() => c.read(billingProvider).plans.length == 1, 'neu geladen');
      expect(gateway.log.where((l) => l.startsWith('load:')).length, greaterThan(loads));
      expect(c.read(billingProvider).selectedPlan, 'jaehrlich');
    });
  });

  group('Offline nach einem Laufzeitwechsel', () {
    const requires = AppConfig(offlineRequiresPremium: true);

    test('gemerkter, unbestätigter Kauf + Server „nicht erlaubt“: unbekannt statt gesperrt (kein Löschen)', () async {
      final api = FakeApi(admin: false)
        ..premiumStatus = PremiumStatus(offlineRequiresPremium: true, offlineAllowed: false, checkedAt: _now);
      final c = await container(api: api, config: requires, prefs: {
        BillingController.unverifiedKey: jsonEncode([
          {'product_id': 'premium', 'token': 'token-neu', 'account': '$_server|1'},
        ]),
      });
      c.listen(offlineAccessProvider, (_, _) {});
      await waitFor(() => c.read(premiumProvider).hasValue, 'Premium geladen');
      await settle();
      expect(c.read(offlineAccessProvider).access, OfflineAccess.checking);
    });

    test('gemerkter Kauf eines anderen Kontos zählt nicht; ohne gemerkten Kauf wie bisher gesperrt', () async {
      for (final prefs in <Map<String, Object>>[
        {
          BillingController.unverifiedKey: jsonEncode([
            {'product_id': 'premium', 'token': 'token-fremd', 'account': '$_server|99'},
          ]),
        },
        {},
      ]) {
        final api = FakeApi(admin: false)
          ..premiumStatus = PremiumStatus(offlineRequiresPremium: true, offlineAllowed: false, checkedAt: _now);
        final c = await container(api: api, config: requires, prefs: prefs);
        c.listen(offlineAccessProvider, (_, _) {});
        await waitFor(() => c.read(offlineAccessProvider).access == OfflineAccess.locked, 'gesperrt');
        c.dispose();
      }
    });
  });

  group('Standard = wie bisher, GitHub-Version unverändert', () {
    test('ohne neue Schalter: alles erlaubt, keine Grenze, kein Abzeichen', () {
      const access = PremiumAccess(isAdmin: false, config: AppConfig(), status: PremiumStatus(checkedAt: null));
      expect(PremiumFeature.all.every(access.allows), isTrue);
      expect(access.capQuality('original'), 'original');
      expect(PremiumAccess(isAdmin: false, config: const AppConfig(), status: status()).allows('video'), isTrue);
    });

    testWidgets('GitHub-Version: Premium-Seite ohne Kaufkarte und Laufzeiten, auch mit Laufzeiten im Dashboard', (tester) async {
      var created = 0;
      await pumpScreen(tester, const PremiumScreen(),
          admin: false,
          channel: AppChannel.full,
          config: const AppConfig(
              billingEnabled: true,
              billingProductIds: ['premium'],
              billingBasePlans: ['monatlich', 'jaehrlich'],
              billingRecommendedPlan: 'jaehrlich'),
          overrides: [
            purchaseGatewayProvider.overrideWith((ref) {
              created++;
              return FakePurchaseGateway()..products = threePlanProducts();
            }),
          ]);
      expect(find.text('Premium abonnieren'), findsNothing);
      expect(find.text('Monatlich'), findsNothing);
      expect(find.text('Code einlösen'), findsOneWidget);
      expect(created, 0);
      expectNoErrors(tester);
    });

    testWidgets('GitHub-Version, Schalter aus: Einstellungen wie bisher (Qualität, kein Abzeichen, Untertitel)', (tester) async {
      final api = FakeApi(admin: false)..premiumError = const ApiException('kein Netz');
      await pumpScreen(tester, const SettingsScreen(), api: api, admin: false, size: const Size(400, 3000));
      expect(find.text('Original (beste Qualität)'), findsWidgets);
      expect(find.textContaining('mehr mit Premium'), findsNothing);
      expect(find.byKey(const ValueKey('premium-badge')), findsNothing);
      expect(find.text('Code einlösen, Werbung abschalten'), findsOneWidget);
      expectNoErrors(tester);
    });
  });
}
