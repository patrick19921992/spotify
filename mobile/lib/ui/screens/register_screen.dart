import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/links.dart';
import '../../data/api.dart' show normalizeBaseUrl;
import '../../core/theme.dart';
import '../../state/auth.dart';
import '../../state/library.dart';
import '../../state/registration.dart';
import '../widgets/common.dart';
import 'account_widgets.dart';

/// Gleiche Regeln wie auf dem Server (schemas/user.py: Username, Password, DisplayName).
final _usernamePattern = RegExp(r'^[a-z0-9][a-z0-9._-]{2,31}$');
const _passwordMin = 8;
const _passwordMax = 128;
const _displayNameMax = 64;

/// Benutzername so, wie ihn der Server speichert: ohne Leerzeichen am Rand, klein geschrieben.
String normalizeUsername(String input) => input.trim().toLowerCase();

/// Fehlertexte der Prüfung in der App (null = in Ordnung).
String? usernameError(String input) => _usernamePattern.hasMatch(normalizeUsername(input))
    ? null
    : 'Der Benutzername muss 3–32 Zeichen lang sein und darf nur Kleinbuchstaben, Ziffern, Punkt, Bindestrich und '
        'Unterstrich enthalten.';

/// Länge wie auf dem Server (pydantic zählt Unicode-Zeichen, nicht UTF-16-Einheiten): „abcdef😀“ hat 7 Zeichen.
String? passwordError(String input) {
  final length = input.runes.length;
  if (length < _passwordMin) return 'Das Passwort muss mindestens 8 Zeichen lang sein.';
  if (length > _passwordMax) return 'Das Passwort darf höchstens 128 Zeichen lang sein.';
  return null;
}

String? repeatError(String password, String repeat) =>
    password == repeat ? null : 'Die Passwörter stimmen nicht überein.';

/// „Konto erstellen“ – nur erreichbar, wenn der Server die Registrierung anbietet (Login-Seite).
///
/// [serverUrl]: Server, bei dem das Konto entsteht (Play-Version: immer die feste Adresse).
/// [mode]: Registrierungs-Modus, den der Server beim Verbinden gemeldet hat ('approval' oder 'open').
class RegisterScreen extends ConsumerStatefulWidget {
  final String serverUrl;
  final String mode;

  const RegisterScreen({super.key, required this.serverUrl, this.mode = 'approval'});

  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final _username = TextEditingController();
  final _displayName = TextEditingController();
  final _password = TextEditingController();
  final _repeat = TextEditingController();
  final _usernameFocus = FocusNode();
  final _displayNameFocus = FocusNode();
  final _passwordFocus = FocusNode();
  final _repeatFocus = FocusNode();

  bool _busy = false;
  bool _obscure = true;
  bool _checked = false;
  String? _error;

  String get _server => fixedServerUrl ?? widget.serverUrl;

  @override
  void dispose() {
    _username.dispose();
    _displayName.dispose();
    _password.dispose();
    _repeat.dispose();
    _usernameFocus.dispose();
    _displayNameFocus.dispose();
    _passwordFocus.dispose();
    _repeatFocus.dispose();
    super.dispose();
  }

  String? get _usernameError => _checked ? usernameError(_username.text) : null;
  String? get _passwordError => _checked ? passwordError(_password.text) : null;
  String? get _repeatError =>
      _checked && passwordError(_password.text) == null ? repeatError(_password.text, _repeat.text) : null;

  void _changed() {
    if (_checked || _error != null) setState(() => _error = null);
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _checked = true;
      _error = null;
    });
    if (usernameError(_username.text) != null) {
      _usernameFocus.requestFocus();
      return;
    }
    if (passwordError(_password.text) != null) {
      _passwordFocus.requestFocus();
      return;
    }
    if (repeatError(_password.text, _repeat.text) != null) {
      _repeatFocus.requestFocus();
      return;
    }
    FocusScope.of(context).unfocus();
    final username = normalizeUsername(_username.text);
    final displayName = _displayName.text.trim();
    setState(() => _busy = true);
    try {
      final result = await ref.read(registrationGatewayProvider).register(
            _server,
            username: username,
            password: _password.text,
            displayName: displayName.isEmpty ? null : displayName,
          );
      if (!mounted) return;
      final auth = ref.read(authProvider.notifier);
      final login = result.login;
      if (!result.pending && login != null) {
        // Sofort nutzbar: angemeldet wie nach „Anmelden“ – dann zur Startseite
        await auth.adoptLogin(_server, login);
        if (mounted) context.go('/home');
        return;
      }
      // Wartet auf Freischaltung: zurück zur Anmeldung, dort steht der Hinweis des Servers
      await auth.registrationPending(_server, username, result.message);
      if (!mounted) return;
      if (context.canPop()) {
        context.pop(username);
      } else {
        context.go('/login');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = errorText(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(registrationConfigProvider(_server)).value;
    // Der Modus aus den Einstellungen des Servers gilt, sobald er da ist – bis dahin der beim Verbinden gemeldete
    final mode = config != null && config.registrationOpen ? config.registrationMode : widget.mode;
    // Ohne PUBLIC_URL meldet der Server keine Adresse – die Seite gibt es trotzdem unter /datenschutz (wie in den
    // Einstellungen)
    final configured = config?.privacyUrl.trim() ?? '';
    final base = normalizeBaseUrl(_server);
    final privacyUrl = configured.isNotEmpty ? configured : (base.isEmpty ? '' : '$base/datenschutz');

    return Scaffold(
      appBar: AppBar(title: const Text('Konto erstellen')),
      body: SafeArea(
        child: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: AutofillGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _username,
                      focusNode: _usernameFocus,
                      enabled: !_busy,
                      autocorrect: false,
                      enableSuggestions: false,
                      textCapitalization: TextCapitalization.none,
                      autofillHints: const [AutofillHints.newUsername],
                      textInputAction: TextInputAction.next,
                      onChanged: (_) => _changed(),
                      onSubmitted: (_) => _displayNameFocus.requestFocus(),
                      decoration: InputDecoration(
                        labelText: 'Benutzername',
                        helperText: '3–32 Zeichen: Kleinbuchstaben, Ziffern, Punkt, Bindestrich, Unterstrich',
                        helperMaxLines: 2,
                        errorText: _usernameError,
                        errorMaxLines: 3,
                        prefixIcon: const Icon(Icons.person_rounded, color: AppColors.textSecondary),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _displayName,
                      focusNode: _displayNameFocus,
                      enabled: !_busy,
                      textCapitalization: TextCapitalization.words,
                      autofillHints: const [AutofillHints.nickname],
                      textInputAction: TextInputAction.next,
                      inputFormatters: [LengthLimitingTextInputFormatter(_displayNameMax)],
                      onChanged: (_) => _changed(),
                      onSubmitted: (_) => _passwordFocus.requestFocus(),
                      decoration: const InputDecoration(
                        labelText: 'Anzeigename (optional)',
                        prefixIcon: Icon(Icons.badge_outlined, color: AppColors.textSecondary),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _password,
                      focusNode: _passwordFocus,
                      enabled: !_busy,
                      obscureText: _obscure,
                      autocorrect: false,
                      enableSuggestions: false,
                      autofillHints: const [AutofillHints.newPassword],
                      textInputAction: TextInputAction.next,
                      onChanged: (_) => _changed(),
                      onSubmitted: (_) => _repeatFocus.requestFocus(),
                      decoration: InputDecoration(
                        labelText: 'Passwort',
                        helperText: 'Mindestens 8 Zeichen',
                        errorText: _passwordError,
                        errorMaxLines: 2,
                        prefixIcon: const Icon(Icons.lock_rounded, color: AppColors.textSecondary),
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
                    const SizedBox(height: 16),
                    TextField(
                      controller: _repeat,
                      focusNode: _repeatFocus,
                      enabled: !_busy,
                      obscureText: _obscure,
                      autocorrect: false,
                      enableSuggestions: false,
                      autofillHints: const [AutofillHints.newPassword],
                      textInputAction: TextInputAction.done,
                      onChanged: (_) => _changed(),
                      onSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        labelText: 'Passwort wiederholen',
                        errorText: _repeatError,
                        errorMaxLines: 2,
                        prefixIcon: const Icon(Icons.lock_outline_rounded, color: AppColors.textSecondary),
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      AccountNotice.error(_error!),
                    ],
                    const SizedBox(height: 24),
                    if (mode == 'approval') ...[
                      const Text(
                        'Nach dem Erstellen muss der Betreiber dein Konto erst freischalten.',
                        style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
                      ),
                      const SizedBox(height: 8),
                    ],
                    const Text(
                      'Mit dem Erstellen akzeptierst du die Datenschutzerklärung.',
                      style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
                    ),
                    if (privacyUrl.isNotEmpty)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          style: TextButton.styleFrom(padding: EdgeInsets.zero),
                          onPressed: () => _openPrivacy(privacyUrl),
                          child: const Text('Datenschutzerklärung'),
                        ),
                      ),
                    const SizedBox(height: 16),
                    AccountButton(label: 'Konto erstellen', loading: _busy, onPressed: _submit),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openPrivacy(String url) async {
    final opened = await ref.read(linkOpenerProvider)(url);
    if (!opened && mounted) showMessage(context, 'Die Seite lässt sich nicht öffnen. Adresse: $url');
  }
}
