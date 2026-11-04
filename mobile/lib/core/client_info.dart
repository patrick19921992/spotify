import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';

import 'flavor.dart';

/// Welche App läuft hier? Wird bei jeder Server-Anfrage als Header `X-Selfify-Client` mitgeschickt – das
/// Dashboard zeigt daraus, welche Versionen im Umlauf sind –, und bei „Fehler melden“ mitgegeben.
class ClientInfo {
  /// android | ios | windows | linux | macos
  final String platform;

  /// full | play
  final String channel;
  final String version;
  final int build;

  const ClientInfo({required this.platform, required this.channel, required this.version, required this.build});

  /// `platform=android; channel=play; version=1.0.0; build=54` (Format siehe server/app/services/clients.py).
  String get header => 'platform=$platform; channel=$channel; version=$version; build=$build';

  /// Liest Version und Build der installierten App.
  static Future<ClientInfo> detect() async {
    final info = await PackageInfo.fromPlatform();
    return ClientInfo(
      platform: platformName(),
      channel: appChannel.id,
      version: _cleanVersion(info.version),
      build: int.tryParse(info.buildNumber) ?? 0,
    );
  }

  static String platformName() => Platform.isAndroid
      ? 'android'
      : Platform.isIOS
          ? 'ios'
          : Platform.isWindows
              ? 'windows'
              : Platform.isMacOS
                  ? 'macos'
                  : 'linux';

  // Der Server nimmt nur Ziffern, Buchstaben und . + - (höchstens 32 Zeichen)
  static String _cleanVersion(String value) {
    final cleaned = value.replaceAll(RegExp(r'[^0-9A-Za-z.+-]'), '');
    if (cleaned.isEmpty) return '0';
    return cleaned.length > 32 ? cleaned.substring(0, 32) : cleaned;
  }
}

/// Kurze Beschreibung des Geräts für „Fehler melden“ (System und Version, höchstens 200 Zeichen).
String describeDevice() {
  final text = '${ClientInfo.platformName()} · ${Platform.operatingSystemVersion}'.replaceAll(RegExp(r'\s+'), ' ');
  return text.length <= 200 ? text : text.substring(0, 200);
}

/// Wird beim Start gesetzt (main.dart). Bis dahin – und in Tests – wird kein Header geschickt.
ClientInfo? currentClient;
