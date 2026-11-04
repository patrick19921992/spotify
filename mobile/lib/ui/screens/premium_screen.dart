import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
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

/// „Premium“: Stand anzeigen und einen Premium-Code einlösen. Mit Premium gibt es keine Werbung.
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
    return Scaffold(
      appBar: AppBar(title: const Text('Premium')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 32 + MediaQuery.paddingOf(context).bottom),
        children: [
          _StatusCard(premium: premium, onRetry: () => ref.invalidate(premiumProvider)),
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
  final VoidCallback onRetry;

  const _StatusCard({required this.premium, required this.onRetry});

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
                Text(
                  status.active ? 'Du siehst keine Werbung.' : 'Mit Premium siehst du keine Werbung.',
                  style: AppText.tileSubtitle,
                ),
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
