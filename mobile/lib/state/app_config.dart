import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/client_info.dart';
import '../core/flavor.dart';
import '../data/api.dart';
import '../data/models.dart';
import 'auth.dart';
import 'connectivity.dart';
import 'settings.dart';

/// Einstellungen vom Server (Dashboard › App-Einstellungen): Werbung, Premium, Wünsche, Update, Wartungshinweis.
///
/// Scheitert die Abfrage (offline, alter Server ohne diese Schnittstelle), gilt der letzte bekannte Stand –
/// ganz am Anfang die Standardwerte: keine Werbung, kein Wartungshinweis, kein Update.
class AppConfigController extends AsyncNotifier<AppConfig> {
  @override
  Future<AppConfig> build() async {
    final serverUrl = ref.watch(authProvider.select((a) => a.value?.serverUrl));
    if (serverUrl == null) return const AppConfig();
    return _fetch(serverUrl);
  }

  Future<AppConfig> _fetch(String serverUrl) async {
    try {
      return await ApiClient.fetchConfig(serverUrl, channel: appChannel.id, build: currentClient?.build ?? 0);
    } catch (_) {
      return state.value ?? const AppConfig();
    }
  }

  /// Neu abfragen (beim Zurückkehren in die App und stündlich, siehe [AppConfigWatcher]).
  Future<void> refresh() async {
    final serverUrl = ref.read(authProvider).value?.serverUrl;
    if (serverUrl == null) return;
    state = AsyncData(await _fetch(serverUrl));
  }
}

final appConfigProvider = AsyncNotifierProvider<AppConfigController, AppConfig>(
  AppConfigController.new,
  retry: (_, _) => null,
);

/// Der aktuelle Stand der Einstellungen (bis die Antwort da ist: Standardwerte).
final appConfigValueProvider = Provider<AppConfig>((ref) => ref.watch(appConfigProvider).value ?? const AppConfig());

/// Premium-Stand des angemeldeten Benutzers. Einlösen geht in beiden Versionen; Werbung, die Premium abstellt,
/// gibt es nur in der Play-Version.
class PremiumController extends AsyncNotifier<PremiumStatus> {
  @override
  Future<PremiumStatus> build() async {
    final api = ref.watch(apiProvider);
    if (api == null) return const PremiumStatus();
    return api.premium();
  }

  /// Löst einen Code ein und merkt sich den neuen Stand. Wirft [ApiException] mit verständlicher Meldung
  /// (z. B. „Diesen Code gibt es nicht.“).
  Future<PremiumStatus> redeem(String code) async {
    final api = ref.read(apiProvider);
    if (api == null) throw const ApiException('Nicht angemeldet.', statusCode: 401);
    final status = await api.redeemPremium(code);
    state = AsyncData(status);
    return status;
  }

  /// Übernimmt einen Stand, den der Server gerade geliefert hat (nach einem Kauf über Google Play).
  void set(PremiumStatus status) => state = AsyncData(status);
}

final premiumProvider = AsyncNotifierProvider<PremiumController, PremiumStatus>(
  PremiumController.new,
  retry: (_, _) => null,
);

/// „Premium“ in den Einstellungen zeigen? Wenn der Admin es nicht abgeschaltet hat (Dashboard › App-Einstellungen).
final premiumVisibleProvider = Provider<bool>(
  (ref) => ref.watch(appConfigValueProvider.select((c) => c.premiumEnabled)),
);

/// „Song wünschen“ anbieten? Nur Play-Version (dort gibt es keine YouTube-Suche), und nur wenn eingeschaltet.
final wishlistVisibleProvider = Provider<bool>(
  (ref) => isPlayChannel && ref.watch(appConfigValueProvider.select((c) => c.wishlistEnabled)),
);

/// Meine Song-Wünsche mit Stand (offen, in Arbeit, erledigt, abgelehnt).
final wishesProvider = FutureProvider.autoDispose<List<SongWish>>((ref) => requireApi(ref).wishes());

/// Song-Wünsche dieser Woche – nur abgefragt, wenn „Mehr Song-Wünsche“ nur mit Premium geht (sonst wie bisher:
/// keine Abfrage, null). null auch bei einem älteren Server ohne Wochengrenze.
final wishQuotaProvider = FutureProvider.autoDispose<WishQuota?>((ref) async {
  if (!ref.watch(appConfigValueProvider.select((c) => c.premiumOnly.contains(PremiumFeature.requests)))) return null;
  return requireApi(ref).wishQuota();
});

/// Werbung zeigen? Nur wenn alles stimmt: Android-Play-Version, vom Admin eingeschaltet, Premium **geladen** und
/// nicht aktiv (solange unklar ist, ob jemand Premium hat, gibt es keine Werbung) und eine Verbindung besteht.
/// Werbefrei macht ein Premium, das „Keine Werbung“ freischaltet (alter Server: jedes aktive Premium).
final adsVisibleProvider = Provider<bool>((ref) {
  if (!isPlayChannel || defaultTargetPlatform != TargetPlatform.android) return false;
  if (!ref.watch(appConfigValueProvider.select((c) => c.adsEnabled))) return false;
  if (!(ref.watch(authProvider).value?.isLoggedIn ?? false)) return false;
  if (ref.watch(isOfflineProvider) || ref.watch(settingsProvider.select((s) => s.offlineMode))) return false;
  final premium = ref.watch(premiumProvider);
  return premium.hasValue && !premium.requireValue.has(PremiumFeature.noAds);
});

/// Hinweis „Neue Version im Play Store“ (Stufe „available“) – nach „Später“ erst bei einer noch neueren Version wieder.
class DismissedStoreUpdateController extends Notifier<int> {
  static const _key = 'update.dismissedStoreBuild';

  @override
  int build() => ref.read(sharedPreferencesProvider).getInt(_key) ?? 0;

  void dismiss(int build) {
    state = build;
    ref.read(sharedPreferencesProvider).setInt(_key, build);
  }
}

final dismissedStoreUpdateProvider =
    NotifierProvider<DismissedStoreUpdateController, int>(DismissedStoreUpdateController.new);

/// Update-Stand der Play-Version laut Server; null in allen anderen Versionen.
final storeUpdateProvider = Provider<UpdateInfo?>((ref) {
  if (!isPlayChannel) return null;
  final info = ref.watch(appConfigValueProvider.select((c) => c.update));
  return info.level == UpdateLevel.none ? null : info;
});

/// Hinweis zeigen: Update verfügbar und nicht weggeklickt (ein Pflicht-Update lässt sich nicht wegklicken –
/// das zeigt die App als eigenen Bildschirm).
final storeUpdateNoticeProvider = Provider<UpdateInfo?>((ref) {
  final info = ref.watch(storeUpdateProvider);
  if (info == null || info.level != UpdateLevel.available) return null;
  return info.latestBuild > ref.watch(dismissedStoreUpdateProvider) ? info : null;
});
