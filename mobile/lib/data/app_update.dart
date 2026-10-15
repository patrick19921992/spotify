import 'dart:convert';

import 'package:dio/dio.dart';

import 'models.dart';

/// Adresse der Versionsdatei (version.json im GitHub-Release „app-latest“). Wird beim Bauen
/// übergeben (`--dart-define=UPDATE_MANIFEST_URL=…`) – leer bei lokalen Builds: dann keine Update-Prüfung.
const updateManifestUrl = String.fromEnvironment('UPDATE_MANIFEST_URL');

/// Download einer veröffentlichten App-Datei für eine Plattform.
class AppDownload {
  final String url;
  final String? sha256;

  const AppDownload({required this.url, this.sha256});

  static AppDownload? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final url = raw['url'];
    if (url is! String || !url.startsWith('https://')) return null;
    final sha = raw['sha256'];
    return AppDownload(url: url, sha256: sha is String && sha.length == 64 ? sha : null);
  }
}

/// Neueste veröffentlichte App-Version laut version.json.
class AppRelease {
  /// Fortlaufende Build-Nummer – dieselbe Zahl wie die Build-Nummer der installierten App.
  final int build;
  final String version;
  final String? commit;
  final DateTime? date;
  final AppDownload? android;

  const AppRelease({required this.build, required this.version, this.commit, this.date, this.android});

  factory AppRelease.fromJson(Json j) => AppRelease(
        build: (j['build'] as num?)?.toInt() ?? 0,
        version: j['version'] as String? ?? '',
        commit: j['commit'] as String?,
        date: DateTime.tryParse(j['date'] as String? ?? ''),
        android: AppDownload.fromJson(j['android']),
      );

  /// Anzeige wie in den Einstellungen: „Version 1.0.0 (Build 42)“.
  String get label => version.isEmpty ? 'Build $build' : 'Version $version (Build $build)';
}

/// Holt die Versionsdatei. Liefert null, wenn keine Adresse eingebaut ist.
Future<AppRelease?> fetchLatestRelease({String url = updateManifestUrl, Dio? dio}) async {
  if (url.isEmpty) return null;
  final client = dio ??
      Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
        responseType: ResponseType.plain,
      ));
  final response = await client.get<String>(url);
  final body = response.data;
  if (body == null || body.isEmpty) return null;
  // GitHub liefert die Datei als application/octet-stream – deshalb selbst auswerten
  final data = jsonDecode(body);
  if (data is! Map) return null;
  return AppRelease.fromJson(Map<String, dynamic>.from(data));
}
