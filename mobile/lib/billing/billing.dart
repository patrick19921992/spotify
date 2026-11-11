import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/flavor.dart';
import '../data/api.dart';
import '../data/models.dart';
import '../state/app_config.dart';
import '../state/auth.dart';
import '../state/offline_access.dart' show accountKey;
import 'purchase_gateway.dart';

export 'purchase_gateway.dart';

/// Texte des Kaufs (auch in Tests benutzt).
abstract final class BillingText {
  static const purchased = 'Premium ist freigeschaltet. Danke!';
  static const restored = 'Premium wiederhergestellt.';
  static const pending = 'Die Zahlung ist noch offen. Sobald Google sie bestätigt, wird Premium freigeschaltet.';
  static const unverified = 'Der Kauf ist bei Google angekommen, konnte aber noch nicht bestätigt werden. '
      'Die App versucht es automatisch erneut.';
  static const storeUnavailable = 'Google Play ist auf diesem Gerät gerade nicht verfügbar.';
  static const nothingToRestore = 'Für dieses Google-Konto wurde kein Kauf gefunden.';
  static const noRunningSubscription = 'Kein laufendes Abo gefunden.';

  static String failed(String message) => 'Der Kauf hat nicht geklappt: $message';
  static String productMissing(String ids) => 'Das Abo wurde im Play Store nicht gefunden ($ids).';
}

class BillingState {
  /// Die Produkte werden gerade vom Store geladen.
  final bool loading;

  /// Der Store ist erreichbar.
  final bool available;
  final List<StoreProduct> products;

  /// Ein Kauf oder eine Wiederherstellung läuft.
  final bool busy;

  /// Erfolgs- oder Hinweistext (z. B. „Zahlung offen“).
  final String? notice;
  final String? error;

  const BillingState({
    this.loading = false,
    this.available = false,
    this.products = const [],
    this.busy = false,
    this.notice,
    this.error,
  });

  BillingState copyWith({
    bool? loading,
    bool? available,
    List<StoreProduct>? products,
    bool? busy,
    String? Function()? notice,
    String? Function()? error,
  }) =>
      BillingState(
        loading: loading ?? this.loading,
        available: available ?? this.available,
        products: products ?? this.products,
        busy: busy ?? this.busy,
        notice: notice != null ? notice() : this.notice,
        error: error != null ? error() : this.error,
      );
}

/// Kauf anbieten? Nur wenn alles stimmt: Play-Version auf Android, vom Betreiber eingeschaltet (der Server meldet
/// „an“ nur mit eingerichteter Kaufprüfung und Produkt-ID), Premium-Bereich sichtbar und angemeldet.
/// Solange das nicht gilt, wird das Kauf-Paket nie angefasst.
final billingVisibleProvider = Provider<bool>((ref) {
  if (!isPlayChannel || defaultTargetPlatform != TargetPlatform.android) return false;
  final enabled = ref.watch(appConfigValueProvider.select((c) => c.billingEnabled && c.billingProductIds.isNotEmpty));
  if (!enabled || !ref.watch(premiumVisibleProvider)) return false;
  return ref.watch(authProvider.select((a) => a.value?.isLoggedIn ?? false));
});

/// Premium über Google Play kaufen und wiederherstellen.
///
/// Die App schaltet nie selbst frei: Jeder Kauf geht mit seinem Token an den Server, der bei Google prüft. Erst
/// nach dessen „aktiv“ wird der Kauf auf dem Gerät abgeschlossen.
class BillingController extends Notifier<BillingState> {
  /// Käufe, die der Server noch nicht bestätigen konnte (kein Netz, Server nicht erreichbar, abgemeldet) – jeder
  /// mit dem Konto (Server und Benutzer), das gekauft hat: Nur dieses Konto reicht ihn später nach.
  static const unverifiedKey = 'billing.unverified';

  /// So lange wartet „Käufe wiederherstellen“ auf eine Antwort des Stores (in Tests kürzer).
  static Duration restoreTimeout = const Duration(seconds: 10);

  PurchaseGateway? _gateway;
  Timer? _restoreTimer;
  bool _restoring = false;
  bool _retrying = false;
  bool _askingStore = false;

  /// Konto, das zuletzt angemeldet war, während der Kauf sichtbar war (für Käufe, deren Meldung erst nach dem
  /// Abmelden eintrifft).
  String? _lastAccount;

  /// Käufe aus dem Store, die der Server für dieses Konto endgültig abgelehnt hat („Konto|Token“): Die stille
  /// Abfrage meldet sie in dieser Sitzung nicht noch einmal.
  final _declined = <String>{};

  @override
  BillingState build() {
    _gateway = null;
    _restoreTimer?.cancel();
    _restoring = false;
    if (!ref.watch(billingVisibleProvider)) return const BillingState();
    final gateway = ref.watch(purchaseGatewayProvider);
    if (gateway == null) return const BillingState();
    _gateway = gateway;
    // Wechselt das Konto, beginnt alles neu (gemerkte Käufe gelten je Konto)
    ref.watch(currentUserProvider.select((u) => u?.id));
    _lastAccount = _account ?? _lastAccount;
    // Neu laden, wenn der Betreiber andere Produkte einträgt
    ref.watch(appConfigValueProvider.select((c) => c.billingProductIds.join(',')));
    // Der Strom liefert nur, was während der laufenden App passiert (und was die App selbst abfragt): Käufe, die
    // beim letzten Mal nicht fertig wurden, meldet Google Play nicht von selbst – dafür unten [catchUp].
    final subscription = gateway.purchases.listen(_onPurchase);
    ref.onDispose(() {
      subscription.cancel();
      _restoreTimer?.cancel();
    });
    Future.microtask(() async {
      await load();
      await catchUp();
    });
    return const BillingState(loading: true);
  }

  String? get _accountId {
    final user = ref.read(currentUserProvider);
    return user == null ? null : '${user.id}';
  }

  /// Das angemeldete Konto (Server und Benutzer) – null, wenn niemand angemeldet ist.
  String? get _account {
    final auth = ref.read(authProvider).value;
    final user = auth?.user;
    final serverUrl = auth?.serverUrl;
    return user == null || serverUrl == null ? null : accountKey(serverUrl, user.id);
  }

  /// Holt nach, was liegen geblieben ist – beim Start und beim Zurückkehren in die App, ohne Meldungen:
  /// gemerkte Käufe erneut an den Server, und den Store nach Käufen fragen, von denen der Server nichts weiß.
  Future<void> catchUp() async {
    await retryUnverified();
    await _askStoreSilently();
  }

  /// Fragt Google Play still nach vorhandenen Käufen (ein Abruf auf dem Gerät). Nötig, weil der Store einen Kauf
  /// nur der laufenden App meldet: Wurde sie während der Zahlung beendet (Bank-App, 3-D-Secure) oder die Zahlung
  /// erst später bestätigt, erführe sonst niemand davon – und Google erstattet unbestätigte Käufe nach 3 Tagen.
  /// Nur wenn der Server für dieses Konto keinen laufenden Kauf kennt.
  Future<void> _askStoreSilently() async {
    final gateway = _gateway;
    final accountId = _accountId;
    if (gateway == null || accountId == null || _askingStore || _restoring || state.busy) return;
    _askingStore = true;
    try {
      final PremiumStatus premium;
      try {
        premium = await ref.read(premiumProvider.future);
      } catch (_) {
        return; // Stand unbekannt: beim nächsten Mal
      }
      if (!ref.mounted || _gateway != gateway || _restoring || state.busy) return;
      if (premium.checkedAt == null || premium.play != null) return;
      await gateway.restore(accountId: accountId);
    } catch (e) {
      debugPrint('Stille Abfrage der Käufe gescheitert: $e');
    } finally {
      _askingStore = false;
    }
  }

  /// Fragt den Store nach den Abos (Titel und Preis).
  Future<void> load() async {
    final gateway = _gateway;
    if (gateway == null) return;
    final ids = ref.read(appConfigValueProvider).billingProductIds.toSet();
    state = state.copyWith(loading: true, error: () => null);
    try {
      if (!await gateway.isAvailable()) {
        if (!ref.mounted) return;
        state = state.copyWith(loading: false, available: false, products: [], error: () => BillingText.storeUnavailable);
        return;
      }
      final products = await gateway.loadProducts(ids);
      if (!ref.mounted) return;
      state = state.copyWith(
        loading: false,
        available: true,
        products: products,
        error: () => products.isEmpty ? BillingText.productMissing(ids.join(', ')) : null,
      );
    } catch (e) {
      if (!ref.mounted) return;
      debugPrint('Abos konnten nicht geladen werden: $e');
      state = state.copyWith(loading: false, available: false, products: [], error: () => BillingText.storeUnavailable);
    }
  }

  /// Öffnet den Kaufdialog von Google Play. Das Ergebnis kommt über den Kauf-Strom.
  Future<void> buy(StoreProduct product) async {
    final gateway = _gateway;
    final accountId = _accountId;
    if (gateway == null || accountId == null || state.busy) return;
    _restoring = false;
    state = state.copyWith(busy: true, notice: () => null, error: () => null);
    try {
      await gateway.buy(product, accountId: accountId);
    } catch (e) {
      if (!ref.mounted) return;
      state = state.copyWith(busy: false, error: () => BillingText.failed(_text(e)));
    }
  }

  /// „Käufe wiederherstellen“: fragt den Store nach vorhandenen Käufen und prüft gemerkte Käufe erneut.
  Future<void> restore() async {
    final gateway = _gateway;
    final accountId = _accountId;
    if (gateway == null || accountId == null || state.busy) return;
    state = state.copyWith(busy: true, notice: () => null, error: () => null);
    final recovered = await retryUnverified();
    if (!ref.mounted) return;
    if (recovered) {
      state = state.copyWith(busy: false, notice: () => BillingText.restored);
      return;
    }
    _restoring = true;
    _restoreTimer?.cancel();
    // Der Store antwortet nur, wenn es Käufe gibt – kommt nichts, gibt es keinen
    _restoreTimer = Timer(restoreTimeout, () {
      if (!_restoring || !ref.mounted) return;
      _restoring = false;
      state = state.copyWith(busy: false, notice: () => BillingText.nothingToRestore);
    });
    try {
      await gateway.restore(accountId: accountId);
    } catch (e) {
      _restoreTimer?.cancel();
      _restoring = false;
      if (!ref.mounted) return;
      state = state.copyWith(busy: false, error: () => BillingText.failed(_text(e)));
    }
  }

  /// Meldungen ausblenden.
  void clearMessages() {
    if (state.notice != null || state.error != null) state = state.copyWith(notice: () => null, error: () => null);
  }

  static String _text(Object error) => error is StateError ? error.message : error.toString();

  static bool _alreadyOwned(String message) {
    final text = message.toLowerCase().replaceAll(RegExp(r'[\s_-]'), '');
    return text.contains('alreadyowned');
  }

  Future<void> _onPurchase(StorePurchase purchase) async {
    if (!ref.mounted) return;
    final restoring = _restoring || purchase.status == StorePurchaseStatus.restored;
    // Antwort auf die stille Abfrage (niemand hat „Käufe wiederherstellen“ angetippt): keine Meldungen, außer
    // wenn dabei Premium freigeschaltet wird
    final silent = purchase.status == StorePurchaseStatus.restored && !_restoring;
    switch (purchase.status) {
      case StorePurchaseStatus.pending:
        _endRestore();
        state = state.copyWith(busy: false, notice: () => BillingText.pending, error: () => null);
        // Dem Server schon jetzt melden: Er prüft offene Zahlungen selbst weiter und bestätigt den Kauf bei
        // Google, sobald bezahlt ist – auch wenn die App dann nicht läuft.
        if (purchase.token.isNotEmpty) await _verify(purchase, restoring: false, storePending: true);
      case StorePurchaseStatus.cancelled:
        state = state.copyWith(busy: false);
      case StorePurchaseStatus.failed:
        if (_alreadyOwned(purchase.message)) {
          // Das Abo gibt es schon (z. B. auf einem anderen Gerät gekauft): stattdessen wiederherstellen
          state = state.copyWith(busy: false);
          await restore();
          return;
        }
        _endRestore();
        state = state.copyWith(
          busy: false,
          error: () => BillingText.failed(purchase.message.isEmpty ? 'unbekannter Fehler' : purchase.message),
        );
      case StorePurchaseStatus.purchased:
      case StorePurchaseStatus.restored:
        _endRestore();
        await _verify(purchase, restoring: restoring, silent: silent);
    }
  }

  void _endRestore() {
    _restoreTimer?.cancel();
    _restoring = false;
  }

  /// Lässt den Server den Kauf prüfen und setzt das Ergebnis um.
  ///
  /// [silent]: Der Kauf kam aus der stillen Abfrage – Hinweise gibt es nur, wenn dabei Premium freigeschaltet wird.
  /// [storePending]: Die Zahlung ist laut Store noch offen – der Hinweis dazu steht schon da und bleibt stehen.
  Future<void> _verify(
    StorePurchase purchase, {
    required bool restoring,
    bool silent = false,
    bool storePending = false,
  }) async {
    final gateway = _gateway;
    final api = ref.read(apiProvider);
    final quiet = silent || storePending;
    if (purchase.token.isEmpty) {
      if (!quiet) {
        state = state.copyWith(busy: false, error: () => BillingText.failed('Google Play hat keinen Kaufbeleg geliefert.'));
      }
      return;
    }
    final account = _account ?? _lastAccount;
    if (api == null) {
      // Abgemeldet während des Kaufs: merken und nach der Anmeldung prüfen
      _remember(purchase.productId, purchase.token, account);
      if (!quiet) state = state.copyWith(busy: false);
      return;
    }
    if (silent && _declined.contains('$account|${purchase.token}')) return;
    if (!quiet) state = state.copyWith(busy: true, error: () => null);
    try {
      final result = await api.verifyPlayPurchase(productId: purchase.productId, token: purchase.token);
      if (!ref.mounted) return;
      _forget(purchase.token);
      // Jede Antwort trägt den aktuellen Premium-Stand
      ref.read(premiumProvider.notifier).set(result.premium);
      switch (result.result) {
        case 'active':
          await gateway?.complete(purchase);
          if (!ref.mounted) return;
          state = state.copyWith(
            busy: silent ? null : false,
            notice: () => restoring ? BillingText.restored : BillingText.purchased,
            error: () => null,
          );
        case 'pending':
          // Nicht abschließen: Google hat die Zahlung noch nicht bestätigt. Der Server kennt den Kauf jetzt und
          // prüft ihn selbst weiter.
          if (!silent) state = state.copyWith(busy: false, notice: () => BillingText.pending);
        default:
          if (storePending) return; // ein offener Kauf lässt sich nicht abschließen
          await gateway?.complete(purchase);
          if (!ref.mounted || silent) return;
          state = state.copyWith(busy: false, notice: () => BillingText.noRunningSubscription);
      }
    } catch (e) {
      if (!ref.mounted) return;
      final error = toApiException(e);
      if (_isTemporary(error)) {
        _remember(purchase.productId, purchase.token, account);
        if (!quiet) state = state.copyWith(busy: false, notice: () => BillingText.unverified);
      } else {
        // Der Server lehnt ab (anderes Konto, gesperrt, unbekannt): nicht abschließen – einen falsch zugeordneten
        // Neukauf erstattet Google dann von selbst.
        _forget(purchase.token);
        if (silent) {
          _declined.add('$account|${purchase.token}');
        } else {
          state = state.copyWith(busy: false, notice: storePending ? () => null : null, error: () => error.message);
        }
      }
    }
  }

  /// Netzfehler, Server nicht erreichbar oder überlastet, Bremse, Anmeldung abgelaufen: später noch einmal.
  static bool _isTemporary(ApiException error) {
    final status = error.statusCode;
    return status == null || status == 401 || status == 429 || status >= 500;
  }

  // ---------------------------------------------------------------- gemerkte Käufe

  List<_Unverified> _unverified() {
    try {
      final raw = ref.read(sharedPreferencesProvider).getString(unverifiedKey);
      if (raw == null) return [];
      return [
        for (final item in jsonDecode(raw) as List)
          if (item is Map && item['product_id'] is String && item['token'] is String)
            (
              productId: item['product_id'] as String,
              token: item['token'] as String,
              // Einträge ohne Konto (Stand vor dieser Angabe) gelten für das angemeldete Konto
              account: item['account'] is String ? item['account'] as String : null,
            ),
      ];
    } catch (_) {
      return [];
    }
  }

  void _store(List<_Unverified> items) {
    final prefs = ref.read(sharedPreferencesProvider);
    if (items.isEmpty) {
      prefs.remove(unverifiedKey).ignore();
    } else {
      prefs
          .setString(
            unverifiedKey,
            jsonEncode([
              for (final i in items) {'product_id': i.productId, 'token': i.token, 'account': ?i.account},
            ]),
          )
          .ignore();
    }
  }

  void _remember(String productId, String token, String? account) {
    final items = _unverified();
    if (items.any((i) => i.token == token)) return;
    // Höchstens die letzten 5 – mehr offene Käufe gibt es praktisch nie
    final next = [...items, (productId: productId, token: token, account: account)];
    _store(next.length > 5 ? next.sublist(next.length - 5) : next);
  }

  void _forget(String token) {
    final items = _unverified();
    if (items.any((i) => i.token == token)) _store(items.where((i) => i.token != token).toList());
  }

  /// Prüft gemerkte Käufe erneut (beim Start, beim Zurückkehren in die App, bei „Käufe wiederherstellen“) – nur
  /// die des angemeldeten Kontos: Der Kauf eines anderen Kontos (oder an einem anderen Server) bleibt liegen, bis
  /// dessen Besitzer wieder angemeldet ist. Der Server würde ihn hier ablehnen, und er wäre verloren.
  /// Liefert true, wenn dabei Premium freigeschaltet wurde.
  Future<bool> retryUnverified() async {
    if (_retrying || _gateway == null) return false;
    final api = ref.read(apiProvider);
    final account = _account;
    if (api == null || account == null) return false;
    final items = _unverified().where((i) => i.account == null || i.account == account).toList();
    if (items.isEmpty) return false;
    _retrying = true;
    var activated = false;
    try {
      for (final item in items) {
        try {
          final result = await api.verifyPlayPurchase(productId: item.productId, token: item.token);
          if (!ref.mounted) return activated;
          _forget(item.token);
          ref.read(premiumProvider.notifier).set(result.premium);
          if (result.result == 'active') {
            activated = true;
            state = state.copyWith(notice: () => BillingText.purchased, error: () => null);
          }
          // „pending“/„inactive“: Der Server kennt den Kauf jetzt und prüft ihn selbst weiter
        } catch (e) {
          if (!ref.mounted) return activated;
          // Endgültig abgelehnt: streichen. Sonst bleibt der Kauf gemerkt.
          if (!_isTemporary(toApiException(e))) _forget(item.token);
        }
      }
    } finally {
      _retrying = false;
    }
    return activated;
  }
}

/// Gemerkter Kauf: Produkt, Kauf-Token und das Konto („Server|Benutzer-Nummer“), das gekauft hat.
typedef _Unverified = ({String productId, String token, String? account});

final billingProvider = NotifierProvider<BillingController, BillingState>(BillingController.new);
