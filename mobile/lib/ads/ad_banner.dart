import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../state/app_config.dart';
import 'ads.dart';

/// Werbebanner über der unteren Leiste. Zeigt nur dann etwas (und fasst das Werbe-SDK nur dann an), wenn
/// [adsVisibleProvider] es erlaubt: Play-Version auf Android, vom Admin eingeschaltet, ohne Premium, online.
class AdBanner extends ConsumerStatefulWidget {
  const AdBanner({super.key});

  @override
  ConsumerState<AdBanner> createState() => _AdBannerState();
}

class _AdBannerState extends ConsumerState<AdBanner> {
  BannerAd? _ad;
  bool _loading = false;
  int _failures = 0;
  Timer? _retry;

  @override
  void initState() {
    super.initState();
    // Anzeige schon beim ersten Aufbau starten, wenn sie erlaubt ist (listen feuert nur bei Änderungen)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ref.read(adsVisibleProvider)) _load();
    });
  }

  @override
  void dispose() {
    _retry?.cancel();
    _ad?.dispose();
    super.dispose();
  }

  /// Anzeige wegnehmen. Freigegeben wird sie erst nach dem nächsten Bild, wenn der AdWidget nicht mehr im
  /// Baum hängt.
  void _drop() {
    _retry?.cancel();
    final old = _ad;
    _ad = null;
    _failures = 0;
    if (old != null) WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  Future<void> _load() async {
    if (_loading || _ad != null) return;
    _loading = true;
    try {
      if (!await AdsService.prepare() || !mounted || !ref.read(adsVisibleProvider)) return;
      final ad = BannerAd(
        adUnitId: adBannerUnitId,
        size: AdSize.banner,
        request: const AdRequest(),
        listener: BannerAdListener(
          onAdLoaded: (loaded) {
            if (!mounted || !ref.read(adsVisibleProvider)) {
              loaded.dispose();
              return;
            }
            _failures = 0;
            setState(() => _ad = loaded as BannerAd);
          },
          onAdFailedToLoad: (failed, error) {
            failed.dispose();
            // höchstens dreimal nachladen (2, 4, 8 Minuten später), danach erst beim nächsten Start
            if (++_failures <= 3 && mounted) {
              _retry?.cancel();
              _retry = Timer(Duration(minutes: 1 << _failures), () {
                if (mounted && ref.read(adsVisibleProvider)) _load();
              });
            }
          },
        ),
      );
      await ad.load();
    } finally {
      _loading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(adsVisibleProvider, (_, visible) {
      if (visible) {
        _load();
      } else if (_ad != null) {
        setState(_drop);
      } else {
        _drop();
      }
    });
    final ad = _ad;
    if (ad == null || !ref.watch(adsVisibleProvider)) return const SizedBox.shrink();
    return SizedBox(
      width: double.infinity,
      height: ad.size.height.toDouble(),
      child: Center(child: SizedBox(width: ad.size.width.toDouble(), height: ad.size.height.toDouble(), child: AdWidget(ad: ad))),
    );
  }
}
