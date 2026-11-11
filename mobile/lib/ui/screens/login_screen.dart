import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import '../../data/api.dart';
import '../../data/models.dart';
import '../../state/app_config.dart';
import '../../state/auth.dart';
import '../../state/library.dart';
import '../../state/registration.dart';
import '../widgets/app_update.dart';
import '../widgets/common.dart';
import 'account_widgets.dart';

/// Willkommen: Server verbinden, dann anmelden. Nach der Anmeldung leitet der Router weiter.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  late final TextEditingController _server;
  late final TextEditingController _username;
  final _password = TextEditingController();
  final _serverFocus = FocusNode();
  final _usernameFocus = FocusNode();
  final _passwordFocus = FocusNode();

  ServerInfo? _info;
  String? _connectedUrl;
  bool _probing = false;
  bool _loggingIn = false;
  bool _obscure = true;
  String? _serverError;

  /// Technische Angaben zur fehlgeschlagenen Prüfung (wer hat geantwortet, mit welchem Inhalt).
  String? _serverDetails;
  String? _loginError;

  /// Die Anmeldung scheiterte, weil das Konto noch auf Freischaltung wartet – dann „Registrierung zurückziehen“.
  bool _loginPending = false;
  bool _withdrawing = false;

  /// Hinweis nach erfolgreichem Zurückziehen.
  String? _withdrawn;

  /// Zählt Verbindungsversuche – veraltete Antworten werden ignoriert.
  int _probeRun = 0;

  @override
  void initState() {
    super.initState();
    final auth = ref.read(authProvider.notifier);
    final lastServer = auth.lastServerUrl ?? ref.read(authProvider).value?.serverUrl ?? '';
    _server = TextEditingController(text: lastServer);
    _username = TextEditingController(text: auth.lastUsername ?? '');
    final fixed = fixedServerUrl;
    if (fixed != null) {
      // Play-Version: Die Adresse ist eingebaut – keine Eingabe, keine Vorab-Prüfung. Ob der Server erreichbar ist,
      // zeigt die Anmeldung selbst mit ihrer Fehlermeldung.
      _connectedUrl = fixed;
    } else if (lastServer.isNotEmpty) {
      // Bekannten Server gleich prüfen – dann reicht nach einer Abmeldung das Passwort
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _connect(automatic: true);
      });
    }
  }

  @override
  void dispose() {
    _server.dispose();
    _username.dispose();
    _password.dispose();
    _serverFocus.dispose();
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  /// Mögliche Adressen für die Eingabe. Ohne "http(s)://" erst HTTPS, dann HTTP versuchen.
  List<String> _candidates(String input) {
    final match = RegExp(r'^(https?)://', caseSensitive: false).firstMatch(input);
    if (match != null) {
      return [normalizeBaseUrl('${match.group(1)!.toLowerCase()}://${input.substring(match.end)}')];
    }
    return [normalizeBaseUrl('https://$input'), normalizeBaseUrl('http://$input')];
  }

  Future<void> _connect({bool automatic = false}) async {
    final input = _server.text.trim();
    if (input.isEmpty) {
      setState(() => _serverError = 'Bitte gib die Adresse deines Servers ein.');
      _serverFocus.requestFocus();
      return;
    }
    if (!automatic) FocusScope.of(context).unfocus();
    final run = ++_probeRun;
    setState(() {
      _probing = true;
      _serverError = null;
      _serverDetails = null;
      _loginError = null;
      _loginPending = false;
    });

    Object? error;
    for (final url in _candidates(input)) {
      try {
        final info = await ApiClient.probe(url);
        if (!mounted || run != _probeRun) return;
        _server.text = url;
        setState(() {
          _info = info;
          _connectedUrl = url;
          _probing = false;
        });
        if (!automatic) {
          // Erst nach dem Aufbau des Formulars fokussieren
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) (_username.text.trim().isEmpty ? _usernameFocus : _passwordFocus).requestFocus();
          });
        }
        return;
      } catch (e) {
        error ??= e;
        // Ein Server hat geantwortet (aber kein Selfify) – kein weiterer Versuch nötig
        if (e is ApiException && !e.isNetwork) {
          error = e;
          break;
        }
      }
    }
    if (!mounted || run != _probeRun) return;
    setState(() {
      _probing = false;
      if (!automatic) {
        _serverError = error == null ? null : errorText(error);
        _serverDetails = error is ServerProbeException && error.details.isNotEmpty ? error.details : null;
      }
    });
  }

  void _onServerChanged(String value) {
    final changed = _connectedUrl != null && !_candidates(value.trim()).contains(_connectedUrl);
    if (!changed && _serverError == null && !_probing) return;
    setState(() {
      _serverError = null;
      _serverDetails = null;
      if (changed) {
        _info = null;
        _connectedUrl = null;
        _loginError = null;
        _loginPending = false;
      }
      if (_probing) {
        _probeRun++;
        _probing = false;
      }
    });
  }

  Future<void> _login() async {
    if (_loggingIn) return;
    final server = _connectedUrl;
    if (server == null) {
      await _connect();
      return;
    }
    final username = _username.text.trim();
    final password = _password.text;
    if (username.isEmpty) {
      setState(() => _loginError = 'Bitte gib deinen Benutzernamen ein.');
      _usernameFocus.requestFocus();
      return;
    }
    if (password.isEmpty) {
      setState(() => _loginError = 'Bitte gib dein Passwort ein.');
      _passwordFocus.requestFocus();
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _loggingIn = true;
      _loginError = null;
      _loginPending = false;
      _withdrawn = null;
    });
    try {
      await ref.read(authProvider.notifier).login(server, username, password);
      // Der Router leitet jetzt automatisch zur Startseite weiter.
      if (mounted) setState(() => _loggingIn = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loggingIn = false;
        _loginError = errorText(e);
        _loginPending = e is ApiException && e.accountPending;
      });
      _password.selection = TextSelection(baseOffset: 0, extentOffset: _password.text.length);
      _passwordFocus.requestFocus();
    }
  }

  void _clearLoginError() {
    if (_loginError == null && _withdrawn == null) return;
    setState(() {
      _loginError = null;
      _loginPending = false;
      _withdrawn = null;
    });
  }

  /// Bietet der verbundene Server „Konto erstellen“ an? Play-Version (feste Adresse): laut Einstellungen des
  /// Servers, die schon abgemeldet geladen werden. Sonst: laut Prüfung der eingegebenen Adresse. Alter Server
  /// ohne Angabe, Fehler beim Laden oder unbekannter Wert: nein.
  bool _registrationOpen({required bool fixedServer}) => fixedServer
      ? ref.watch(appConfigValueProvider.select((c) => c.registrationOpen))
      : (_info?.registrationOpen ?? false);

  String get _registrationMode =>
      fixedServerUrl != null ? ref.read(appConfigValueProvider).registrationMode : (_info?.registrationMode ?? 'off');

  Future<void> _openRegister() async {
    final server = _connectedUrl;
    if (server == null) return;
    final query = Uri(queryParameters: {'server': server, 'mode': _registrationMode}).query;
    final username = await context.push<String>('/register?$query');
    // Konto wartet auf Freischaltung: Benutzername schon eintragen, der Hinweis kommt über die Anmeldung
    if (!mounted || username == null) return;
    _username.text = username;
    _password.clear();
    setState(() {
      _loginError = null;
      _loginPending = false;
      _withdrawn = null;
    });
  }

  /// Wartendes Konto ohne Anmeldung löschen (Play-Pflicht: „Konto löschen“ in den Einstellungen ist so nicht
  /// erreichbar).
  Future<void> _withdraw() async {
    final server = _connectedUrl;
    if (server == null || _withdrawing) return;
    final ok = await confirm(
      context,
      title: 'Registrierung zurückziehen?',
      message: 'Dein noch nicht freigeschaltetes Konto wird endgültig gelöscht.',
      confirmLabel: 'Löschen',
      danger: true,
    );
    if (!ok || !mounted) return;
    setState(() => _withdrawing = true);
    try {
      await ref.read(registrationGatewayProvider).withdraw(server, _username.text.trim(), _password.text);
      if (!mounted) return;
      ref.read(authProvider.notifier).clearMessage();
      _password.clear();
      setState(() {
        _withdrawing = false;
        _loginError = null;
        _loginPending = false;
        _withdrawn = 'Deine Registrierung wurde zurückgezogen.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _withdrawing = false;
        _loginError = errorText(e);
        _loginPending = e is ApiException && e.accountPending;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final notice = ref.watch(authProvider).value?.message;
    final connected = _info != null;
    final fixedServer = fixedServerUrl != null;

    return Scaffold(
      // Auch abgemeldet sichtbar: Klappt die Anmeldung mit dieser Version nicht, hilft oft die neue
      bottomNavigationBar: const SafeArea(top: false, child: UpdateBanner()),
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF1A5B34), AppColors.background],
            stops: [0, 0.5],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight > 48 ? constraints.maxHeight - 48 : 0),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: AutofillGroup(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const _Logo(),
                          const SizedBox(height: 40),
                          if (notice != null) ...[
                            AccountNotice(text: notice, icon: Icons.lock_clock_rounded),
                            const SizedBox(height: 20),
                          ],
                          if (fixedServer)
                            // Play-Version: gleich Benutzername und Passwort – die Server-Adresse ist eingebaut
                            _loginForm(topGap: 0, fixedServer: true)
                          else ...[
                            const _FieldLabel('Server-Adresse'),
                            TextField(
                              controller: _server,
                              focusNode: _serverFocus,
                              enabled: !_loggingIn,
                              keyboardType: TextInputType.url,
                              autocorrect: false,
                              enableSuggestions: false,
                              autofillHints: const [AutofillHints.url],
                              textInputAction: TextInputAction.go,
                              onChanged: _onServerChanged,
                              onSubmitted: (_) => _connect(),
                              decoration: InputDecoration(
                                hintText: 'https://musik.example.de oder http://192.168.1.10:8080',
                                hintMaxLines: 2,
                                prefixIcon: const Icon(Icons.dns_rounded, color: AppColors.textSecondary),
                                suffixIcon: connected
                                    ? const Icon(Icons.check_circle_rounded, color: AppColors.accent)
                                    : null,
                              ),
                            ),
                            const SizedBox(height: 10),
                            _ServerStatus(info: _info, error: _serverError, details: _serverDetails, probing: _probing),
                            AnimatedSize(
                              duration: const Duration(milliseconds: 220),
                              curve: Curves.easeOutCubic,
                              alignment: Alignment.topCenter,
                              child: connected ? _loginForm() : _connectButton(),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _connectButton() {
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: AccountButton(label: 'Verbinden', loading: _probing, onPressed: _connect),
    );
  }

  Widget _loginForm({double topGap = 24, bool fixedServer = false}) {
    final registration = _registrationOpen(fixedServer: fixedServer);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: topGap),
        const _FieldLabel('Benutzername'),
        TextField(
          controller: _username,
          focusNode: _usernameFocus,
          enabled: !_loggingIn,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.text,
          textCapitalization: TextCapitalization.none,
          autofillHints: const [AutofillHints.username],
          textInputAction: TextInputAction.next,
          onChanged: (_) => _clearLoginError(),
          onSubmitted: (_) => _passwordFocus.requestFocus(),
          decoration: const InputDecoration(
            hintText: 'z. B. lena',
            prefixIcon: Icon(Icons.person_rounded, color: AppColors.textSecondary),
          ),
        ),
        const SizedBox(height: 18),
        const _FieldLabel('Passwort'),
        TextField(
          controller: _password,
          focusNode: _passwordFocus,
          enabled: !_loggingIn,
          obscureText: _obscure,
          autocorrect: false,
          enableSuggestions: false,
          autofillHints: const [AutofillHints.password],
          textInputAction: TextInputAction.done,
          onChanged: (_) => _clearLoginError(),
          onSubmitted: (_) => _login(),
          decoration: InputDecoration(
            hintText: 'Dein Passwort',
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
        if (_loginError != null) ...[
          const SizedBox(height: 16),
          AccountNotice.error(_loginError!),
          if (_loginPending)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _withdrawing || _loggingIn ? null : _withdraw,
                style: TextButton.styleFrom(foregroundColor: AppColors.danger),
                icon: const Icon(Icons.person_remove_outlined),
                label: const Text('Registrierung zurückziehen'),
              ),
            ),
        ],
        if (_withdrawn != null) ...[
          const SizedBox(height: 16),
          AccountNotice(text: _withdrawn!, icon: Icons.check_circle_outline_rounded),
        ],
        const SizedBox(height: 28),
        AccountButton(label: 'Anmelden', loading: _loggingIn, onPressed: _login),
        if (registration) ...[
          const SizedBox(height: 12),
          SizedBox(
            height: 48,
            child: OutlinedButton(
              onPressed: _loggingIn || _withdrawing ? null : _openRegister,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: AppColors.textMuted),
              ),
              child: const Text('Konto erstellen', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            ),
          ),
        ],
        const SizedBox(height: 20),
        Text(
          // Ein Konto legt der Betreiber an – selbst erstellen lässt es sich nur, wenn der Server die Registrierung
          // anbietet (Dashboard). Dann entfällt in der Play-Version der Hinweis „Noch kein Konto“.
          fixedServer && !registration
              ? 'Noch kein Konto oder Passwort vergessen? Frag die Person, die euren Selfify-Server verwaltet.'
              : 'Passwort vergessen? Frag die Person, die euren Selfify-Server verwaltet.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
        ),
      ],
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 96,
          height: 96,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.accent,
            boxShadow: [BoxShadow(color: Color(0x551ED760), blurRadius: 32, spreadRadius: 2)],
          ),
          child: const Icon(Icons.graphic_eq_rounded, size: 54, color: Colors.black),
        ),
        const SizedBox(height: 22),
        const Text(
          'Selfify',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 42, fontWeight: FontWeight.w900, letterSpacing: -1.2, color: Colors.white),
        ),
        const SizedBox(height: 6),
        const Text(
          'Deine Musik. Dein Server.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: AppColors.textSecondary),
        ),
      ],
    );
  }
}

class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 8),
      child: Text(text, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Colors.white)),
    );
  }
}

/// Zeile unter der Server-Adresse: Hinweis, Fehler oder "Verbunden mit …".
class _ServerStatus extends StatelessWidget {
  final ServerInfo? info;
  final String? error;
  final String? details;
  final bool probing;

  const _ServerStatus({required this.info, required this.error, required this.details, required this.probing});

  @override
  Widget build(BuildContext context) {
    final Widget child;
    if (error != null) {
      child = Column(
        key: ValueKey('error:$error'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AccountNotice.error(error!),
          if (details != null) _ProbeDetails(details: details!),
        ],
      );
    } else if (info != null) {
      child = Row(
        key: const ValueKey('connected'),
        children: [
          const Icon(Icons.check_circle_rounded, size: 18, color: AppColors.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Verbunden mit ${info!.name} (Version ${info!.version})',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.accent, fontWeight: FontWeight.w700, fontSize: 14),
            ),
          ),
        ],
      );
    } else {
      child = Text(
        probing
            ? 'Suche nach deinem Selfify-Server …'
            : 'Die Adresse bekommst du von der Person, die Selfify bei euch eingerichtet hat.',
        key: ValueKey(probing),
        style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
      );
    }
    return AnimatedSwitcher(duration: const Duration(milliseconds: 180), child: child);
  }
}

/// Aufklappbare technische Angaben zu einer fehlgeschlagenen Server-Prüfung – zum Kopieren und Weitergeben.
class _ProbeDetails extends StatelessWidget {
  final String details;

  const _ProbeDetails({required this.details});

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        title: const Text('Technische Details', style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(
            details,
            style: const TextStyle(color: AppColors.textSecondary, fontSize: 12, fontFamily: 'monospace', height: 1.4),
          ),
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: details));
              showMessage(context, 'Details kopiert');
            },
            icon: const Icon(Icons.copy_rounded, size: 18),
            label: const Text('Details kopieren'),
          ),
        ],
      ),
    );
  }
}
