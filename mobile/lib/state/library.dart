import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api.dart';
import '../data/models.dart';
import 'auth.dart';

/// Gemeinsame Daten-Provider. Nach Änderungen mit ref.invalidate(...) neu laden.

final homeProvider = FutureProvider.autoDispose<HomeData>((ref) => requireApi(ref).home());

final libraryOverviewProvider = FutureProvider.autoDispose<LibraryOverview>((ref) => requireApi(ref).library());

final categoriesProvider = FutureProvider<List<Category>>((ref) => requireApi(ref).categories());

final albumProvider = FutureProvider.autoDispose.family<AlbumDetail, int>((ref, id) => requireApi(ref).album(id));

final artistProvider = FutureProvider.autoDispose.family<ArtistDetail, int>((ref, id) => requireApi(ref).artist(id));

final playlistProvider =
    FutureProvider.autoDispose.family<PlaylistDetail, int>((ref, id) => requireApi(ref).playlist(id));

final myPlaylistsProvider = FutureProvider.autoDispose<List<Playlist>>((ref) => requireApi(ref).playlists(scope: 'mine'));

final familyPlaylistsProvider =
    FutureProvider.autoDispose<List<Playlist>>((ref) => requireApi(ref).playlists(scope: 'family'));

final mixProvider = FutureProvider.autoDispose.family<Mix, String>((ref, key) => requireApi(ref).mix(key));

final likedTracksProvider = FutureProvider.autoDispose<List<LikedTrack>>((ref) async {
  final api = requireApi(ref);
  final items = <LikedTrack>[];
  var offset = 0;
  while (true) {
    final page = await api.likes(limit: 500, offset: offset);
    items.addAll(page.items);
    if (!page.hasMore || page.items.isEmpty) break;
    offset += page.items.length;
  }
  return items;
});

final lyricsProvider = FutureProvider.autoDispose.family<Lyrics?, int>((ref, id) => requireApi(ref).lyrics(id));

final recentProvider = FutureProvider.autoDispose<List<ContextItem>>((ref) => requireApi(ref).recent());

final historyProvider = FutureProvider.autoDispose<List<HistoryEntry>>((ref) => requireApi(ref).history(limit: 100));

/// Liefert eine verständliche Fehlermeldung für die Anzeige.
String errorText(Object error) => switch (error) {
      ApiException(:final message) => message,
      // Eigene, verständliche Meldungen (z. B. „Im Offline-Modus ist Radio nicht verfügbar.“)
      StateError(:final message) => message,
      _ => 'Etwas ist schiefgelaufen: $error',
    };
