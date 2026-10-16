import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth.dart';

/// Einstellungen der App (auf dem Gerät gespeichert).
class AppSettings {
  /// Qualität beim Streamen im WLAN: original | high | normal | low
  final String wifiQuality;
  /// Qualität beim Streamen über mobile Daten (Datensparmodus).
  final String mobileQuality;
  /// Qualität für Offline-Downloads: original | high | normal
  final String offlineQuality;
  /// Offline-Downloads nur im WLAN.
  final bool offlineWifiOnly;
  /// Nur heruntergeladene Titel anzeigen/abspielen.
  final bool offlineMode;
  /// Wenn die Warteschlange endet, passende Titel weiterspielen (wie "Autoplay").
  final bool autoplay;
  /// Standard-Rubrik für neue YouTube-Downloads (null = Server-Standard).
  final int? audioCategoryId;
  final int? videoCategoryId;
  /// Was der „Holen“-Knopf bei YouTube-Videos holt: ask (jedes Mal fragen) | audio (nur die Musik) | video
  final String videoFetch;

  const AppSettings({
    this.wifiQuality = 'original',
    this.mobileQuality = 'normal',
    this.offlineQuality = 'original',
    this.offlineWifiOnly = true,
    this.offlineMode = false,
    this.autoplay = true,
    this.audioCategoryId,
    this.videoCategoryId,
    this.videoFetch = 'ask',
  });

  AppSettings copyWith({
    String? wifiQuality,
    String? mobileQuality,
    String? offlineQuality,
    bool? offlineWifiOnly,
    bool? offlineMode,
    bool? autoplay,
    int? Function()? audioCategoryId,
    int? Function()? videoCategoryId,
    String? videoFetch,
  }) =>
      AppSettings(
        wifiQuality: wifiQuality ?? this.wifiQuality,
        mobileQuality: mobileQuality ?? this.mobileQuality,
        offlineQuality: offlineQuality ?? this.offlineQuality,
        offlineWifiOnly: offlineWifiOnly ?? this.offlineWifiOnly,
        offlineMode: offlineMode ?? this.offlineMode,
        autoplay: autoplay ?? this.autoplay,
        audioCategoryId: audioCategoryId != null ? audioCategoryId() : this.audioCategoryId,
        videoCategoryId: videoCategoryId != null ? videoCategoryId() : this.videoCategoryId,
        videoFetch: videoFetch ?? this.videoFetch,
      );
}

/// Beschriftungen für die Qualitätsstufen.
const qualityLabels = {
  'original': 'Original (beste Qualität)',
  'high': 'Hoch (AAC 256 kbit/s)',
  'normal': 'Normal (AAC 160 kbit/s)',
  'low': 'Datensparend (AAC 96 kbit/s)',
};

/// Beschriftungen für [AppSettings.videoFetch].
const videoFetchLabels = {
  'ask': 'Jedes Mal fragen',
  'audio': 'Immer nur Musik',
  'video': 'Immer als Video',
};

class SettingsController extends Notifier<AppSettings> {
  @override
  AppSettings build() {
    final p = ref.read(sharedPreferencesProvider);
    return AppSettings(
      wifiQuality: p.getString('s.wifiQuality') ?? 'original',
      mobileQuality: p.getString('s.mobileQuality') ?? 'normal',
      offlineQuality: p.getString('s.offlineQuality') ?? 'original',
      offlineWifiOnly: p.getBool('s.offlineWifiOnly') ?? true,
      offlineMode: p.getBool('s.offlineMode') ?? false,
      autoplay: p.getBool('s.autoplay') ?? true,
      audioCategoryId: p.getInt('s.audioCategoryId'),
      videoCategoryId: p.getInt('s.videoCategoryId'),
      // Unbekannter Wert (z. B. von einer neueren App-Version) -> wie bisher fragen
      videoFetch: videoFetchLabels.containsKey(p.getString('s.videoFetch')) ? p.getString('s.videoFetch')! : 'ask',
    );
  }

  Future<void> update(AppSettings Function(AppSettings current) change) async {
    final next = change(state);
    state = next;
    final p = ref.read(sharedPreferencesProvider);
    await p.setString('s.wifiQuality', next.wifiQuality);
    await p.setString('s.mobileQuality', next.mobileQuality);
    await p.setString('s.offlineQuality', next.offlineQuality);
    await p.setBool('s.offlineWifiOnly', next.offlineWifiOnly);
    await p.setBool('s.offlineMode', next.offlineMode);
    await p.setBool('s.autoplay', next.autoplay);
    await p.setString('s.videoFetch', next.videoFetch);
    if (next.audioCategoryId == null) {
      await p.remove('s.audioCategoryId');
    } else {
      await p.setInt('s.audioCategoryId', next.audioCategoryId!);
    }
    if (next.videoCategoryId == null) {
      await p.remove('s.videoCategoryId');
    } else {
      await p.setInt('s.videoCategoryId', next.videoCategoryId!);
    }
  }
}

final settingsProvider = NotifierProvider<SettingsController, AppSettings>(SettingsController.new);
