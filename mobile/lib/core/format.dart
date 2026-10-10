import 'package:intl/intl.dart';

/// 3:07 bzw. 1:02:45
String formatDuration(Duration? duration) {
  if (duration == null) return '--:--';
  final total = duration.inSeconds.abs();
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = total % 60;
  final ss = seconds.toString().padLeft(2, '0');
  if (hours > 0) return '$hours:${minutes.toString().padLeft(2, '0')}:$ss';
  return '$minutes:$ss';
}

Duration secondsToDuration(num seconds) => Duration(milliseconds: (seconds * 1000).round());

/// "1 Std. 23 Min." – für Album-/Playlist-Längen.
String formatLongDuration(num seconds) {
  final total = seconds.round();
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  if (hours > 0) return '$hours Std. $minutes Min.';
  if (minutes > 0) return '$minutes Min.';
  return '$total Sek.';
}

/// 4,2 MB
String formatBytes(num? bytes) {
  if (bytes == null) return '–';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = value >= 100 || unit == 0 ? 0 : 1;
  return '${NumberFormat.decimalPatternDigits(locale: 'de_DE', decimalDigits: digits).format(value)} ${units[unit]}';
}

/// "noch 1:23" / "noch 2 Min." – Restzeit von Downloads.
String formatEta(int? seconds) {
  if (seconds == null) return 'Restzeit wird berechnet …';
  if (seconds < 60) return 'noch $seconds Sek.';
  if (seconds < 3600) return 'noch ${(seconds / 60).ceil()} Min.';
  return 'noch ${formatDuration(Duration(seconds: seconds))}';
}

String formatSpeed(double? bytesPerSecond) => bytesPerSecond == null ? '' : '${formatBytes(bytesPerSecond)}/s';

String formatPercent(double fraction) => '${(fraction * 100).clamp(0, 100).floor()} %';

/// "Guten Morgen" / "Guten Tag" / "Guten Abend" – wie bei Spotify.
String greeting([DateTime? now]) {
  final hour = (now ?? DateTime.now()).hour;
  if (hour >= 5 && hour < 11) return 'Guten Morgen';
  if (hour >= 11 && hour < 18) return 'Guten Tag';
  return 'Guten Abend';
}

String formatDate(DateTime date) => DateFormat('d. MMM y', 'de_DE').format(date.toLocal());

String formatDateTime(DateTime date) => DateFormat('d. MMM y, HH:mm', 'de_DE').format(date.toLocal());

/// "vor 5 Min." usw.
String formatRelative(DateTime date, [DateTime? now]) {
  final diff = (now ?? DateTime.now()).difference(date.toLocal());
  if (diff.inMinutes < 1) return 'gerade eben';
  if (diff.inMinutes < 60) return 'vor ${diff.inMinutes} Min.';
  if (diff.inHours < 24) return 'vor ${diff.inHours} Std.';
  if (diff.inDays < 7) return 'vor ${diff.inDays} ${diff.inDays == 1 ? 'Tag' : 'Tagen'}';
  return formatDate(date);
}

String pluralSongs(int count) => count == 1 ? '1 Song' : '$count Songs';
