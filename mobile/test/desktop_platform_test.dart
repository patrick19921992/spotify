// Computer-Besonderheiten, die auch ohne Windows prüfbar sind (Plattform per Override umgestellt).

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfify/core/platform.dart';
import 'package:selfify/state/connectivity.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  Future<ProviderContainer> withConnection(List<ConnectivityResult> results) async {
    final c = ProviderContainer(overrides: [connectivityProvider.overrideWith((ref) => Stream.value(results))]);
    addTearDown(c.dispose);
    c.listen(connectivityProvider, (_, _) {});
    await c.read(connectivityProvider.future);
    return c;
  }

  Future<bool> onWifi(List<ConnectivityResult> results) async => (await withConnection(results)).read(isOnWifiProvider);
  Future<bool> offline(List<ConnectivityResult> results) async =>
      (await withConnection(results)).read(isOfflineProvider);

  test('Fenster ohne Fokus zählt am Computer als Vordergrund, am Handy nicht', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(isForeground(AppLifecycleState.inactive), isFalse);
    expect(isForeground(AppLifecycleState.resumed), isTrue);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(isForeground(AppLifecycleState.inactive), isTrue);
    expect(isForeground(AppLifecycleState.hidden), isFalse);
  });

  test('Computer: VPN/andere Verbindung zählt wie WLAN; Handy unverändert', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(await onWifi(const [ConnectivityResult.vpn]), isFalse);
    expect(await onWifi(const [ConnectivityResult.ethernet]), isTrue);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(await onWifi(const [ConnectivityResult.vpn]), isTrue);
  });

  test('Computer: „keine Verbindung“ von Windows (Internet-Test gescheitert) gilt nicht als offline', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(await offline(const [ConnectivityResult.none]), isTrue);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(await offline(const [ConnectivityResult.none]), isFalse);
    expect(await onWifi(const [ConnectivityResult.none]), isTrue);
  });
}
