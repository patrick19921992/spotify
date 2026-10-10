import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/api.dart';
import '../data/models.dart';

/// Wird in main.dart mit der geladenen Instanz überschrieben.
final sharedPreferencesProvider = Provider<SharedPreferences>((ref) => throw UnimplementedError());

const _sessionKey = 'selfify.session';
const _lastServerKey = 'selfify.last_server';
const _lastUserKey = 'selfify.last_user';

class AuthState {
  final String? serverUrl;
  final User? user;
  final ApiClient? api;
  /// Grund für eine automatische Abmeldung (z. B. Gerät wurde abgemeldet).
  final String? message;

  const AuthState({this.serverUrl, this.user, this.api, this.message});

  bool get isLoggedIn => api != null && user != null;
}

/// Anmeldung: speichert Server-Adresse und Token sicher (Keychain/Keystore).
class AuthController extends AsyncNotifier<AuthState> {
  static const _storage = FlutterSecureStorage();

  SharedPreferences get _prefs => ref.read(sharedPreferencesProvider);

  String? get lastServerUrl => _prefs.getString(_lastServerKey);
  String? get lastUsername => _prefs.getString(_lastUserKey);

  @override
  Future<AuthState> build() async {
    String? raw;
    try {
      raw = await _storage.read(key: _sessionKey);
    } catch (_) {
      raw = null; // z. B. Keystore nach Neuinstallation nicht lesbar
    }
    if (raw == null) return AuthState(serverUrl: lastServerUrl);
    try {
      final data = jsonDecode(raw) as Json;
      final serverUrl = data['server_url'] as String;
      final tokens = Tokens.fromJson(data['tokens'] as Json);
      final user = User.fromJson(data['user'] as Json);
      return AuthState(serverUrl: serverUrl, user: user, api: _client(serverUrl, tokens, user));
    } catch (_) {
      await _storage.delete(key: _sessionKey);
      return AuthState(serverUrl: lastServerUrl);
    }
  }

  ApiClient _client(String serverUrl, Tokens tokens, User user) => ApiClient(
        baseUrl: serverUrl,
        tokens: tokens,
        onTokens: (fresh) => _persist(serverUrl, fresh, state.value?.user ?? user),
        onSessionExpired: () => _expire('Deine Anmeldung ist abgelaufen oder dieses Gerät wurde abgemeldet.'),
      );

  Future<void> _persist(String serverUrl, Tokens tokens, User user) async {
    try {
      await _storage.write(
        key: _sessionKey,
        value: jsonEncode({'server_url': serverUrl, 'tokens': tokens.toJson(), 'user': user.toJson()}),
      );
    } catch (_) {}
  }

  Future<void> login(String serverInput, String username, String password) async {
    final serverUrl = normalizeBaseUrl(serverInput);
    final result = await ApiClient.login(serverUrl, username.trim(), password);
    await _persist(serverUrl, result.tokens, result.user);
    await _prefs.setString(_lastServerKey, serverUrl);
    await _prefs.setString(_lastUserKey, username.trim());
    state = AsyncData(AuthState(serverUrl: serverUrl, user: result.user, api: _client(serverUrl, result.tokens, result.user)));
  }

  /// Abmelden – meldet das Gerät auch beim Server ab (wenn erreichbar).
  Future<void> logout() async {
    final current = state.value;
    try {
      await current?.api?.logout();
    } catch (_) {}
    await _storage.delete(key: _sessionKey);
    state = AsyncData(AuthState(serverUrl: current?.serverUrl ?? lastServerUrl));
  }

  void _expire(String message) {
    final current = state.value;
    if (current == null || !current.isLoggedIn) return;
    _storage.delete(key: _sessionKey);
    state = AsyncData(AuthState(serverUrl: current.serverUrl, message: message));
  }

  /// Nach Profiländerungen (Name) oder beim App-Start aktualisierte Benutzerdaten übernehmen.
  Future<void> refreshUser() async {
    final current = state.value;
    final api = current?.api;
    if (current == null || api == null) return;
    try {
      final user = await api.me();
      await _persist(current.serverUrl!, api.tokens, user);
      state = AsyncData(AuthState(serverUrl: current.serverUrl, user: user, api: api));
    } on ApiException catch (e) {
      if (e.isUnauthorized) _expire('Bitte neu anmelden.');
    }
  }

  void replaceUser(User user) {
    final current = state.value;
    if (current?.api == null) return;
    _persist(current!.serverUrl!, current.api!.tokens, user);
    state = AsyncData(AuthState(serverUrl: current.serverUrl, user: user, api: current.api));
  }
}

final authProvider = AsyncNotifierProvider<AuthController, AuthState>(AuthController.new);

/// Der Server-Client des angemeldeten Benutzers (null = abgemeldet).
final apiProvider = Provider<ApiClient?>((ref) => ref.watch(authProvider).value?.api);

/// Für Provider/Screens, die nur angemeldet erreichbar sind.
ApiClient requireApi(Ref ref) {
  final api = ref.watch(apiProvider);
  if (api == null) throw const ApiException('Nicht angemeldet.', statusCode: 401);
  return api;
}

final currentUserProvider = Provider<User?>((ref) => ref.watch(authProvider).value?.user);
