import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/client_info.dart';
import '../../core/error_log.dart';
import '../../core/flavor.dart';
import '../../core/theme.dart';
import '../../state/auth.dart';
import '../../state/library.dart';
import 'account_widgets.dart';

// ------------------------------------------------------------------ Fehler melden

/// Dialog „Fehler melden“. Liefert true, wenn die Meldung gesendet wurde.
Future<bool> showBugReportDialog(BuildContext context) async {
  final sent = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _BugReportDialog(),
  );
  return sent ?? false;
}

class _BugReportDialog extends ConsumerStatefulWidget {
  const _BugReportDialog();

  @override
  ConsumerState<_BugReportDialog> createState() => _BugReportDialogState();
}

class _BugReportDialogState extends ConsumerState<_BugReportDialog> {
  final _message = TextEditingController();
  bool _withLog = true;
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_sending) return;
    final text = _message.text.trim();
    if (text.length < 10) {
      setState(() => _error = 'Bitte beschreibe den Fehler in mindestens 10 Zeichen.');
      return;
    }
    final api = ref.read(apiProvider);
    if (api == null) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final client = currentClient;
      await api.sendBugReport(
        message: text,
        appVersion: client?.version ?? '',
        appBuild: client?.build,
        platform: client?.platform ?? ClientInfo.platformName(),
        channel: appChannel.id,
        device: describeDevice(),
        log: _withLog ? ErrorLog.dump() : '',
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = errorText(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasLog = !ErrorLog.isEmpty;
    return AlertDialog(
      title: const Text('Fehler melden'),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Was ist passiert? Je genauer, desto besser. Mitgeschickt werden App-Version und System.',
            style: AppText.tileSubtitle,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _message,
            enabled: !_sending,
            autofocus: true,
            minLines: 4,
            maxLines: 8,
            maxLength: 4000,
            decoration: const InputDecoration(hintText: 'z. B. „Beim Öffnen eines Albums stürzt die App ab“'),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            activeColor: AppColors.accent,
            checkColor: Colors.black,
            value: hasLog && _withLog,
            onChanged: hasLog && !_sending ? (value) => setState(() => _withLog = value ?? false) : null,
            title: const Text('Letzte Fehlermeldungen der App mitschicken'),
            subtitle: Text(
              hasLog ? 'Hilft bei der Suche. Passwörter und Zugangsdaten sind nicht enthalten.' : 'Es sind keine gespeichert.',
              style: AppText.caption,
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            AccountNotice.error(_error!),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _sending ? null : () => Navigator.pop(context, false),
          child: const Text('Abbrechen', style: TextStyle(color: AppColors.textSecondary)),
        ),
        TextButton(
          onPressed: _sending ? null : _send,
          child: _sending
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Senden', style: TextStyle(color: AppColors.accent, fontWeight: FontWeight.w700)),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------ Konto löschen

/// Dialog „Konto löschen“ (Passwort zur Bestätigung). Liefert true, wenn das Konto gelöscht wurde – die App
/// meldet sich dann ab.
Future<bool> showDeleteAccountDialog(BuildContext context) async {
  final deleted = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _DeleteAccountDialog(),
  );
  return deleted ?? false;
}

class _DeleteAccountDialog extends ConsumerStatefulWidget {
  const _DeleteAccountDialog();

  @override
  ConsumerState<_DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends ConsumerState<_DeleteAccountDialog> {
  final _password = TextEditingController();
  bool _obscure = true;
  bool _deleting = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _delete() async {
    if (_deleting) return;
    if (_password.text.isEmpty) {
      setState(() => _error = 'Bitte gib dein Passwort ein.');
      return;
    }
    final api = ref.read(apiProvider);
    if (api == null) return;
    setState(() {
      _deleting = true;
      _error = null;
    });
    try {
      await api.deleteAccount(_password.text);
      await ref.read(authProvider.notifier).forgetSession(message: 'Dein Konto wurde gelöscht.');
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _deleting = false;
        _error = errorText(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Konto löschen?'),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Dein Konto wird endgültig gelöscht – mit deinen Playlists, Lieblingssongs, dem Hörverlauf, deinen '
            'Wünschen und deinem Premium. Das lässt sich nicht rückgängig machen.',
            style: AppText.tileSubtitle,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _password,
            enabled: !_deleting,
            obscureText: _obscure,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _delete(),
            decoration: InputDecoration(
              labelText: 'Zur Bestätigung: dein Passwort',
              floatingLabelStyle: const TextStyle(color: AppColors.accent),
              suffixIcon: IconButton(
                tooltip: _obscure ? 'Passwort anzeigen' : 'Passwort verbergen',
                icon: Icon(
                  _obscure ? Icons.visibility_rounded : Icons.visibility_off_rounded,
                  color: AppColors.textSecondary,
                ),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            AccountNotice.error(_error!),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _deleting ? null : () => Navigator.pop(context, false),
          child: const Text('Abbrechen', style: TextStyle(color: AppColors.textSecondary)),
        ),
        TextButton(
          onPressed: _deleting ? null : _delete,
          child: _deleting
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Endgültig löschen', style: TextStyle(color: AppColors.danger, fontWeight: FontWeight.w700)),
        ),
      ],
    );
  }
}
