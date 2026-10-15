import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Aktuelle Netzverbindung (WLAN, mobil, keine).
final connectivityProvider = StreamProvider<List<ConnectivityResult>>((ref) async* {
  final connectivity = Connectivity();
  yield await connectivity.checkConnectivity();
  yield* connectivity.onConnectivityChanged;
});

bool _has(List<ConnectivityResult>? results, ConnectivityResult kind) => results?.contains(kind) ?? false;

/// Ohne Netz?
final isOfflineProvider = Provider<bool>((ref) {
  final results = ref.watch(connectivityProvider).value;
  if (results == null) return false;
  return results.isEmpty || results.every((r) => r == ConnectivityResult.none);
});

/// Im WLAN (oder per Kabel) – dann wird in voller Qualität gestreamt.
final isOnWifiProvider = Provider<bool>((ref) {
  final results = ref.watch(connectivityProvider).value;
  return _has(results, ConnectivityResult.wifi) || _has(results, ConnectivityResult.ethernet);
});
