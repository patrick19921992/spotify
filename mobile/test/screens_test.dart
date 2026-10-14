// Bildschirm-Tests: jeder Bildschirm wird mit Testdaten aufgebaut – in normaler Größe,
// schmal (kleines Handy) und mit großer Systemschrift. Fehler wie Layout-Überläufe schlagen an.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfify/ui/screens/album_screen.dart';
import 'package:selfify/ui/screens/artist_screen.dart';
import 'package:selfify/ui/screens/category_screen.dart';
import 'package:selfify/ui/screens/devices_screen.dart';
import 'package:selfify/ui/screens/home_screen.dart';
import 'package:selfify/ui/screens/library_screen.dart';
import 'package:selfify/ui/screens/liked_screen.dart';
import 'package:selfify/ui/screens/login_screen.dart';
import 'package:selfify/ui/screens/mix_screen.dart';
import 'package:selfify/ui/screens/playlist_screen.dart';
import 'package:selfify/ui/screens/search_screen.dart';
import 'package:selfify/ui/screens/settings_screen.dart';
import 'package:selfify/ui/screens/youtube_album_screen.dart';

import 'support/fakes.dart';

typedef ScreenCase = ({String name, Widget Function() build, List<String> expectTexts});

final cases = <ScreenCase>[
  (name: 'Anmeldung', build: () => const LoginScreen(), expectTexts: ['Selfify']),
  (name: 'Einstellungen', build: () => const SettingsScreen(), expectTexts: ['Einstellungen']),
  (name: 'Geräte', build: () => const DevicesScreen(), expectTexts: ['Dieses Gerät']),
  (name: 'Startseite', build: () => const HomeScreen(), expectTexts: ['Deine Top-Songs']),
  (name: 'Mix', build: () => const MixScreen(mixKey: 'genre:Rock'), expectTexts: ['Rock-Mix']),
  (name: 'Rubrik Audio', build: () => const CategoryScreen(categoryId: 1), expectTexts: ['Musik']),
  (name: 'Rubrik Video', build: () => const CategoryScreen(categoryId: 4), expectTexts: ['Videos']),
  (name: 'Suche', build: () => const SearchScreen(), expectTexts: ['Suche']),
  (name: 'YouTube-Album', build: () => const YouTubeAlbumScreen(browseId: 'MPREb_test1'), expectTexts: ['Hot Fuss']),
  (name: 'Bibliothek', build: () => const LibraryScreen(), expectTexts: ['Lieblingssongs']),
  (name: 'Lieblingssongs', build: () => const LikedSongsScreen(), expectTexts: ['Lieblingssongs']),
  (name: 'Eigene Playlist', build: () => const PlaylistScreen(playlistId: 5), expectTexts: ['Roadtrip 5']),
  (name: 'Gemeinsame Playlist', build: () => const PlaylistScreen(playlistId: 6), expectTexts: ['Roadtrip 6']),
  (name: 'Album', build: () => const AlbumScreen(albumId: 7), expectTexts: ['A Night at the Opera']),
  (name: 'Künstler', build: () => const ArtistScreen(artistId: 3), expectTexts: ['Queen']),
];

void main() {
  for (final screen in cases) {
    group(screen.name, () {
      testWidgets('normal', (tester) async {
        await pumpScreen(tester, screen.build());
        expectNoErrors(tester);
        for (final text in screen.expectTexts) {
          expect(find.textContaining(text), findsWidgets, reason: '„$text“ fehlt auf ${screen.name}');
        }
      });
      testWidgets('kleines Handy', (tester) async {
        await pumpScreen(tester, screen.build(), size: const Size(320, 640));
        expectNoErrors(tester);
      });
      testWidgets('große Schrift', (tester) async {
        await pumpScreen(tester, screen.build(), textScale: 1.6);
        expectNoErrors(tester);
      });
      testWidgets('ohne Netz', (tester) async {
        await pumpScreen(tester, screen.build(), offline: true, offlineState: offlineWithTracks());
        expectNoErrors(tester);
      });
    });
  }
}
