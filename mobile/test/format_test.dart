import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:selfify/core/format.dart';
import 'package:selfify/core/theme.dart';

void main() {
  setUpAll(() => initializeDateFormatting('de_DE'));

  test('Dauer wie bei Spotify', () {
    expect(formatDuration(const Duration(seconds: 187)), '3:07');
    expect(formatDuration(const Duration(hours: 1, minutes: 2, seconds: 45)), '1:02:45');
    expect(formatDuration(null), '--:--');
    expect(formatLongDuration(4980), '1 Std. 23 Min.');
    expect(formatLongDuration(240), '4 Min.');
  });

  test('Größen und Restzeiten auf Deutsch', () {
    expect(formatBytes(512), '512 B');
    expect(formatBytes(1536), '1,5 KB');
    expect(formatBytes(4404019), '4,2 MB');
    expect(formatEta(42), 'noch 42 Sek.');
    expect(formatEta(130), 'noch 3 Min.');
    expect(formatEta(null), 'Restzeit wird berechnet …');
    expect(formatPercent(0.456), '45 %');
  });

  test('Begrüßung je nach Tageszeit', () {
    expect(greeting(DateTime(2026, 1, 1, 8)), 'Guten Morgen');
    expect(greeting(DateTime(2026, 1, 1, 14)), 'Guten Tag');
    expect(greeting(DateTime(2026, 1, 1, 21)), 'Guten Abend');
    expect(greeting(DateTime(2026, 1, 1, 2)), 'Guten Abend');
  });

  test('Relative Zeit', () {
    final now = DateTime(2026, 10, 10, 12);
    expect(formatRelative(now.subtract(const Duration(seconds: 20)), now), 'gerade eben');
    expect(formatRelative(now.subtract(const Duration(minutes: 5)), now), 'vor 5 Min.');
    expect(formatRelative(now.subtract(const Duration(days: 1)), now), 'vor 1 Tag');
    expect(pluralSongs(1), '1 Song');
    expect(pluralSongs(4), '4 Songs');
  });

  test('Cover-Farben vom Server', () {
    expect(parseHexColor('#3a6ea5')!.toARGB32(), 0xFF3A6EA5);
    expect(parseHexColor('kaputt'), isNull);
    expect(parseHexColor(null), isNull);
  });
}
