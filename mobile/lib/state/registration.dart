import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/client_info.dart';
import '../core/flavor.dart';
import '../data/api.dart';
import '../data/models.dart';
import 'app_config.dart';
import 'auth.dart';

/// Selbst-Registrierung ohne Anmeldung: Konto erstellen, wartende Registrierung zurückziehen und die Einstellungen
/// des Servers lesen (Modus, Datenschutzerklärung). In Tests ersetzbar.
class RegistrationGateway {
  const RegistrationGateway();

  Future<RegisterResult> register(
    String serverUrl, {
    required String username,
    required String password,
    String? displayName,
  }) =>
      ApiClient.register(serverUrl, username: username, password: password, displayName: displayName);

  Future<void> withdraw(String serverUrl, String username, String password) =>
      ApiClient.withdrawRegistration(serverUrl, username, password);

  Future<AppConfig> config(String serverUrl) =>
      ApiClient.fetchConfig(serverUrl, channel: appChannel.id, build: currentClient?.build ?? 0);
}

final registrationGatewayProvider = Provider<RegistrationGateway>((ref) => const RegistrationGateway());

/// Einstellungen des Servers, bei dem ein Konto erstellt wird. Ist es der Server der App (Play-Version mit fester
/// Adresse oder zuletzt benutzter Server), gelten die schon geladenen Einstellungen – sonst wird nachgefragt.
/// Scheitert das (alter Server, offline), gelten die Standardwerte (Registrierung aus, ohne Datenschutz-Link).
final registrationConfigProvider = FutureProvider.autoDispose.family<AppConfig, String>((ref, serverUrl) async {
  final appServer = ref.watch(authProvider.select((a) => a.value?.serverUrl));
  if (appServer != null && normalizeBaseUrl(appServer) == normalizeBaseUrl(serverUrl)) {
    return ref.watch(appConfigValueProvider);
  }
  try {
    return await ref.read(registrationGatewayProvider).config(serverUrl);
  } catch (_) {
    return const AppConfig();
  }
});
