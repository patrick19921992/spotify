import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

/// Öffnet einen Link im Browser (oder im Play Store bei `market://`). Liefert false, wenn das nicht geht.
/// Erlaubt sind nur http, https und market – nichts, was der Server oder ein Text unterschieben könnte.
Future<bool> openLink(String url) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !const {'https', 'http', 'market'}.contains(uri.scheme)) return false;
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

/// Wie Links geöffnet werden (in Tests ersetzbar).
final linkOpenerProvider = Provider<Future<bool> Function(String url)>((ref) => openLink);
