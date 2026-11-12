import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../billing/billing.dart';
import '../../core/flavor.dart';
import '../../core/format.dart';
import '../../core/links.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../state/app_config.dart';
import '../../state/library.dart';
import '../widgets/common.dart';
import 'account_widgets.dart';

/// Text zum Premium-Stand („Premium bis 4. Dez. 2026“, „Premium – unbegrenzt“, „Kein Premium“).
String premiumLabel(PremiumStatus status) {
  if (!status.active) return 'Kein Premium';
  if (status.unlimited) return 'Premium – unbegrenzt';
  final until = status.until;
  return until == null ? 'Premium' : 'Premium bis ${formatDate(until)}';
}

/// Verwaltung des Abos in Google Play (Kündigen, Zahlungsart).
String playSubscriptionUrl(String productId) =>
    'https://play.google.com/store/account/subscriptions?sku=${Uri.encodeQueryComponent(productId)}'
    '&package=de.selfify.selfify.play';

/// Zeile zum Abo über Google Play – null, wenn der Stand nichts Erwähnenswertes hat.
String? playSubscriptionLabel(PlaySubscription play) {
  final until = play.expiresAt;
  return switch (play.state) {
    'active' => play.autoRenewing
        ? (until == null ? 'Abo über Google Play' : 'Abo über Google Play – verlängert sich am ${formatDate(until)}')
        : (until == null ? 'Abo über Google Play' : 'Abo über Google Play – läuft bis ${formatDate(until)}'),
    'canceled' => until == null ? 'Abo gekündigt' : 'Abo gekündigt – Premium bis ${formatDate(until)}',
    'grace' || 'on_hold' => 'Zahlungsproblem – bitte in Google Play prüfen',
    'paused' => 'Abo pausiert',
    'pending' => 'Zahlung noch offen',
    _ => null,
  };
}

/// Vorteile, die die Premium-Seite aufzählt: die Zeilen des Betreibers (Dashboard) – oder, wenn er keine
/// eingetragen hat, was sich aus den Schaltern ergibt (nur Leistungen, die wirklich auf „nur Premium“ stehen).
List<String> premiumBenefitsFor(AppConfig config, {bool wishlistVisible = false}) {
  if (config.premiumBenefits.isNotEmpty) return config.premiumBenefits;
  final only = config.premiumOnly;
  return [
    if (config.offlineRequiresPremium || only.contains(PremiumFeature.offline)) 'Musik aufs Gerät laden und offline hören',
    if (config.adsEnabled && isPlayChannel) 'Keine Werbung',
    if (only.contains(PremiumFeature.hqAudio))
      'Beste Tonqualität – ohne Premium höchstens ${config.freeAudioQuality == 'low' ? 96 : 160} kbit/s',
    if (only.contains(PremiumFeature.video)) 'Videos ansehen – ohne Premium nur als Ton',
    if (only.contains(PremiumFeature.lyrics)) 'Songtexte mitlesen',
    if (only.contains(PremiumFeature.requests) && wishlistVisible)
      config.freeRequestsPerWeek == 0
          ? 'Songs wünschen'
          : 'Unbegrenzt Songs wünschen – ohne Premium ${config.freeRequestsPerWeek} pro Woche',
    if (only.contains(PremiumFeature.skips))
      'Unbegrenzt überspringen – ohne Premium ${config.freeSkipsPerHour}-mal pro Stunde',
    if (only.contains(PremiumFeature.remote)) 'Auf anderen Geräten abspielen und fernsteuern',
    if (config.premiumBadgeEnabled) 'Premium-Abzeichen im Profil',
  ];
}

/// Leistungen, die gerade „nur Premium“ sind – laut App-Konfiguration oder Premium-Antwort.
List<String> premiumOnlyFeatures(AppConfig config, PremiumStatus? status) => [
      for (final f in PremiumFeature.all)
        if (config.premiumOnly.contains(f) || (status?.premiumOnly.contains(f) ?? false)) f,
    ];

/// „Premium“: Stand anzeigen, in der Play-Version (wenn eingeschaltet) ein Abo über Google Play abschließen und
/// einen Premium-Code einlösen. Was Premium bringt, legt der Betreiber im Dashboard fest.
class PremiumScreen extends ConsumerStatefulWidget {
  const PremiumScreen({super.key});

  @override
  ConsumerState<PremiumScreen> createState() => _PremiumScreenState();
}

class _PremiumScreenState extends ConsumerState<PremiumScreen> {
  final _code = TextEditingController();
  bool _redeeming = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _redeem() async {
    if (_redeeming) return;
    final text = _code.text.trim();
    if (text.isEmpty) {
      setState(() => _error = 'Bitte gib einen Code ein.');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _redeeming = true;
      _error = null;
    });
    try {
      final status = await ref.read(premiumProvider.notifier).redeem(text);
      if (!mounted) return;
      _code.clear();
      setState(() => _redeeming = false);
      showMessage(context, 'Code eingelöst: ${premiumLabel(status)}');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _redeeming = false;
        _error = errorText(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final premium = ref.watch(premiumProvider);
    final config = ref.watch(appConfigValueProvider);
    final offlineLocked = config.offlineRequiresPremium || (premium.value?.offlineRequiresPremium ?? false);
    final benefits = premiumBenefitsFor(config, wishlistVisible: ref.watch(wishlistVisibleProvider));
    final showIntro =
        config.premiumHeadline.isNotEmpty || config.premiumDescription.isNotEmpty || benefits.isNotEmpty;
    final billingVisible = ref.watch(billingVisibleProvider);
    final play = premium.value?.play;
    return Scaffold(
      appBar: AppBar(title: const Text('Premium')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 32 + MediaQuery.paddingOf(context).bottom),
        children: [
          _StatusCard(
            premium: premium,
            offlineLocked: offlineLocked,
            premiumOnly: premiumOnlyFeatures(config, premium.value),
            onRetry: () => ref.invalidate(premiumProvider),
          ),
          if (play != null && playSubscriptionLabel(play) != null) ...[
            const SizedBox(height: 12),
            _SubscriptionRow(play: play),
          ],
          if (showIntro) ...[
            const SizedBox(height: 24),
            Text(
              config.premiumHeadline.isEmpty ? 'Selfify Premium' : config.premiumHeadline,
              style: AppText.sectionTitle,
            ),
            if (config.premiumDescription.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(config.premiumDescription, style: AppText.tileSubtitle.copyWith(height: 1.4)),
            ],
            if (benefits.isNotEmpty) const SizedBox(height: 10),
            for (final benefit in benefits)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.check_circle_rounded, size: 20, color: AppColors.accent),
                    const SizedBox(width: 10),
                    Expanded(child: Text(benefit, style: const TextStyle(fontSize: 15, height: 1.3))),
                  ],
                ),
              ),
          ],
          // Kauf über Google Play: nur Play-Version auf Android, und nur wenn der Betreiber ihn eingeschaltet hat
          if (billingVisible) ...[
            const SizedBox(height: 24),
            _PurchaseCard(status: premium.value),
          ],
          const SizedBox(height: 24),
          const Text('Code einlösen', style: AppText.sectionTitle),
          const SizedBox(height: 4),
          const Text(
            'Hast du einen Premium-Code bekommen? Gib ihn hier ein. Eine neue Laufzeit wird an eine laufende '
            'angehängt.',
            style: AppText.tileSubtitle,
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _code,
            enabled: !_redeeming,
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: TextCapitalization.characters,
            textInputAction: TextInputAction.done,
            inputFormatters: [_CodeFormatter()],
            onSubmitted: (_) => _redeem(),
            decoration: const InputDecoration(
              labelText: 'Premium-Code',
              hintText: 'XXXX-XXXX-XXXX',
              floatingLabelStyle: TextStyle(color: AppColors.accent),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            AccountNotice.error(_error!),
          ],
          const SizedBox(height: 16),
          AccountButton(label: 'Einlösen', loading: _redeeming, onPressed: _redeem),
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  final AsyncValue<PremiumStatus> premium;

  /// „Offline-Hören nur mit Premium“ ist eingeschaltet – dann nennt die Karte das statt der Werbung.
  final bool offlineLocked;

  /// Leistungen, die nur mit Premium gehen.
  final List<String> premiumOnly;
  final VoidCallback onRetry;

  const _StatusCard({
    required this.premium,
    required this.offlineLocked,
    required this.premiumOnly,
    required this.onRetry,
  });

  String _benefit(PremiumStatus status) {
    // Mehr als das Offline-Hören ist eingeschränkt: die Leistungen nennen
    if (premiumOnly.any((f) => f != PremiumFeature.offline)) {
      if (!status.active) return 'Mit Premium: ${PremiumFeature.names(premiumOnly)}';
      if (status.hasAll) return 'Alle Premium-Vorteile sind freigeschaltet.';
      return 'Freigeschaltet: ${PremiumFeature.names(status.features ?? const [])}';
    }
    if (offlineLocked) {
      // Teil-Code ohne Offline: Premium läuft, Offline aber nicht (alter Server ohne Umfang: wie bisher nach active)
      if (status.has(PremiumFeature.offline)) return 'Offline-Hören ist freigeschaltet.';
      if (status.active) return 'Freigeschaltet: ${PremiumFeature.names(status.features ?? const [])}';
      return 'Mit Premium kannst du Musik aufs Gerät laden.';
    }
    return status.active ? 'Du siehst keine Werbung.' : 'Mit Premium siehst du keine Werbung.';
  }

  @override
  Widget build(BuildContext context) {
    final status = premium.value;
    final Widget content;
    if (status == null) {
      content = premium.hasError
          ? Row(
              children: [
                const Expanded(child: Text('Dein Premium-Stand konnte nicht geladen werden.')),
                TextButton(onPressed: onRetry, child: const Text('Nochmal')),
              ],
            )
          : const Center(child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator()));
    } else {
      content = Row(
        children: [
          Icon(
            status.active ? Icons.workspace_premium_rounded : Icons.block_flipped,
            size: 36,
            color: status.active ? AppColors.accent : AppColors.textSecondary,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  premiumLabel(status),
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Colors.white),
                ),
                const SizedBox(height: 2),
                Text(_benefit(status), style: AppText.tileSubtitle),
              ],
            ),
          ),
        ],
      );
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: (status?.active ?? false) ? AppColors.accent : AppColors.surfaceHighest),
      ),
      child: content,
    );
  }
}

/// Stand des Abos über Google Play mit dem Weg zur Verwaltung (Kündigen, Zahlungsart) in Google Play.
class _SubscriptionRow extends ConsumerWidget {
  final PlaySubscription play;

  const _SubscriptionRow({required this.play});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final problem = play.state == 'grace' || play.state == 'on_hold';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
      decoration: BoxDecoration(color: AppColors.surfaceHigh, borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          Icon(
            problem ? Icons.error_outline_rounded : Icons.autorenew_rounded,
            size: 20,
            color: problem ? AppColors.danger : AppColors.textSecondary,
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(playSubscriptionLabel(play) ?? '', style: const TextStyle(fontSize: 14, height: 1.3))),
          TextButton(
            onPressed: () async {
              final opened = await ref.read(linkOpenerProvider)(playSubscriptionUrl(play.productId));
              if (!opened && context.mounted) {
                showMessage(context, 'Google Play lässt sich nicht öffnen. Öffne dort bitte „Zahlungen und Abos“.');
              }
            },
            child: const Text('Abo verwalten', style: TextStyle(color: AppColors.accent)),
          ),
        ],
      ),
    );
  }
}

/// Kaufkarte: Laufzeit wählen und ein Abo über Google Play abschließen, die Laufzeit wechseln oder einen vorhandenen
/// Kauf wiederherstellen. Die Preise liefert der Store (der Betreiber legt sie in der Play Console fest); die App
/// rechnet daraus nur den Monatspreis und die Ersparnis gegenüber monatlich aus.
class _PurchaseCard extends ConsumerWidget {
  final PremiumStatus? status;

  const _PurchaseCard({required this.status});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final billing = ref.watch(billingProvider);
    final controller = ref.read(billingProvider.notifier);
    final config = ref.watch(appConfigValueProvider);
    final status = this.status;
    final play = status?.play;
    // Ohne laufendes Abo und ohne volles unbegrenztes Premium gibt es etwas zu kaufen (mit unbegrenztem Teil-Code
    // darf man abonnieren – das Abo schaltet alles frei)
    final canBuy = status != null && play == null && !(status.unlimited && status.hasAll);
    // Laufzeit wechseln: nur bei laufendem Abo, dessen Laufzeit bekannt ist
    final canChange = play != null && (play.state == 'active' || play.state == 'canceled') && play.basePlanId.isNotEmpty;
    final plans = billing.plans;
    final selected = billing.selected;
    final recommended = recommendedPlan(plans, config);
    bool isOwn(StorePlan plan) =>
        play != null && play.basePlanId == plan.basePlanId && play.productId == plan.productId;
    final notice = billing.notice;
    final error = billing.error;
    final Widget? action;
    if (selected == null || billing.loading) {
      action = null;
    } else if (canBuy) {
      action = AccountButton(
        label: hasFreeTrial(selected.offer) ? 'Gratis testen' : '${periodLabel(selected.regular.billingPeriod)} abonnieren',
        loading: billing.busy,
        onPressed: () => controller.buy(selected),
      );
    } else if (canChange && !isOwn(selected)) {
      action = AccountButton(
        label: 'Zu ${periodLabel(selected.regular.billingPeriod)} wechseln',
        loading: billing.busy,
        onPressed: () => controller.change(selected),
      );
    } else {
      action = null;
    }
    // Karten nur, wenn es etwas zu kaufen oder zu wechseln gibt – oder zur Anzeige des eigenen Abos
    final showPlans = canBuy || (play != null && play.basePlanId.isNotEmpty);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Premium abonnieren', style: AppText.sectionTitle),
        const SizedBox(height: 12),
        if (billing.loading && plans.isEmpty)
          const Center(child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator()))
        else if (showPlans) ...[
          for (final plan in plans) ...[
            _PlanCard(
              plan: plan,
              pricing: pricingFor(plan, plans),
              selected: plans.length > 1 && plan.basePlanId == selected?.basePlanId && plan.productId == selected?.productId,
              recommended: plan.basePlanId == recommended,
              own: isOwn(plan),
              onTap: plans.length > 1 && !billing.busy ? () => controller.select(plan) : null,
            ),
            const SizedBox(height: 10),
          ],
          if (action != null) ...[
            action,
            const SizedBox(height: 10),
          ],
        ],
        if (notice != null) ...[
          AccountNotice(text: notice),
          const SizedBox(height: 10),
        ],
        if (error != null) ...[
          AccountNotice.error(error),
          const SizedBox(height: 10),
        ],
        const Text(
          'Abo über Google Play. Verlängert sich automatisch, bis du kündigst. Kündigen und Zahlungsart ändern kannst '
          'du jederzeit in Google Play. Beim Wechsel der Laufzeit rechnet Google die restliche Zeit an.',
          style: AppText.caption,
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: billing.busy ? null : controller.restore,
            style: TextButton.styleFrom(padding: EdgeInsets.zero),
            child: const Text('Käufe wiederherstellen', style: TextStyle(color: AppColors.accent)),
          ),
        ),
        if (billing.error != null && plans.isEmpty && !billing.loading)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: controller.load,
              style: TextButton.styleFrom(padding: EdgeInsets.zero),
              child: const Text('Nochmal versuchen', style: TextStyle(color: AppColors.textSecondary)),
            ),
          ),
      ],
    );
  }
}

/// Eine Laufzeit: Überschrift, Preis, Monatspreis, Ersparnis und Angebot.
class _PlanCard extends StatelessWidget {
  final StorePlan plan;
  final PlanPricing pricing;
  final bool selected;
  final bool recommended;
  final bool own;
  final VoidCallback? onTap;

  const _PlanCard({
    required this.plan,
    required this.pricing,
    required this.selected,
    required this.recommended,
    required this.own,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final perMonth = pricing.perMonthText;
    final save = pricing.saveText;
    final offer = offerText(plan.offer);
    return Material(
      color: AppColors.surfaceHigh,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: selected ? AppColors.accent : AppColors.surfaceHighest, width: selected ? 2 : 1),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      periodLabel(plan.regular.billingPeriod),
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Colors.white),
                    ),
                  ),
                  if (recommended) const _PlanChip('Empfohlen', accent: true),
                  if (save != null) _PlanChip(save),
                  if (own) const _PlanChip('Dein Abo'),
                ],
              ),
              const SizedBox(height: 4),
              Text(regularPriceText(plan), style: const TextStyle(fontSize: 15)),
              if (perMonth != null) ...[
                const SizedBox(height: 2),
                Text(perMonth, style: AppText.tileSubtitle),
              ],
              if (offer != null) ...[
                const SizedBox(height: 4),
                Text(offer, style: const TextStyle(fontSize: 14, color: AppColors.accent, fontWeight: FontWeight.w600)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _PlanChip extends StatelessWidget {
  final String text;
  final bool accent;

  const _PlanChip(this.text, {this.accent = false});

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(left: 6),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: accent ? AppColors.accent : AppColors.surfaceHighest,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: accent ? Colors.black : Colors.white,
          ),
        ),
      );
}

/// Macht aus der Eingabe `XXXX-XXXX-XXXX`: Großbuchstaben, nur erlaubte Zeichen, Bindestriche nach je 4 Zeichen.
/// Eingefügte Codes mit Leerzeichen oder anderen Trennern werden dabei richtig zusammengesetzt.
class _CodeFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final raw = newValue.text.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    final clipped = raw.length > 12 ? raw.substring(0, 12) : raw;
    final buffer = StringBuffer();
    for (var i = 0; i < clipped.length; i++) {
      if (i > 0 && i % 4 == 0) buffer.write('-');
      buffer.write(clipped[i]);
    }
    final text = buffer.toString();
    return TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
  }
}

/// Für Tests: dieselbe Aufbereitung wie im Eingabefeld.
String formatPremiumCodeInput(String input) =>
    _CodeFormatter().formatEditUpdate(TextEditingValue.empty, TextEditingValue(text: input)).text;
