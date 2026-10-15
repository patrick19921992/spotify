import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/platform.dart';

/// Aktuelle Netzverbindung (WLAN, mobil, keine).
final connectivityProvider = StreamProvider<List<ConnectivityResult>>((ref) async* {
  final connectivity = Connectivity();
  yield await connectivity.checkConnectivity();
  yield* connectivity.onConnectivityChanged;
});

bool _has(List<ConnectivityResult>? results, ConnectivityResult kind) => results?.contains(kind) ?? false;

/// Ohne Netz?
final isOfflineProvider = Provider<bool>((ref) {
  // Computer: Windows meldet „keine Verbindung“, sobald der Internet-Test von Microsoft scheitert – auch wenn
  // der Server im Heimnetz erreichbar ist (Netz ohne Internet, VPN, Proxy). Lieber nie „offline“ anzeigen;
  // ist der Server wirklich weg, kommen ohnehin Fehlermeldungen.
  if (isDesktopPlatform) return false;
  final results = ref.watch(connectivityProvider).value;
  if (results == null) return false;
  return results.isEmpty || results.every((r) => r == ConnectivityResult.none);
});

/// Im WLAN (oder per Kabel) – dann wird in voller Qualität gestreamt.
final isOnWifiProvider = Provider<bool>((ref) {
  // Computer: jede Verbindung wie WLAN (Kabel, VPN, „andere“)
  if (isDesktopPlatform) return true;
  final results = ref.watch(connectivityProvider).value;
  return _has(results, ConnectivityResult.wifi) || _has(results, ConnectivityResult.ethernet);
});
