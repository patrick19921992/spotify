// YouTube-Videos auch nur als Musik holen (z. B. Kinderlieder, die es bei YouTube nur als Video gibt):
// Holen-Knopf und Menü fragen bei Videos „Nur Musik“ oder „Video“; ein vorhandener Ton wird erkannt.
// In den Einstellungen lässt sich festlegen, dass „Holen“ immer nur die Musik (oder immer das Video) holt.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfify/data/models.dart';
import 'package:selfify/state/settings.dart';
import 'package:selfify/ui/screens/search_widgets.dart';
import 'package:selfify/ui/screens/search_youtube.dart';
import 'package:selfify/ui/screens/settings_screen.dart';
import 'package:selfify/ui/widgets/download_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

class RecordingApi extends FakeApi {
  final sent = <String>[];
  final cancelled = <int>[];

  @override
  Future<DownloadJob> cancelDownload(int id) async {
    cancelled.add(id);
    return DownloadJob.fromJson({...jobJson(id, 'cancelled'), 'video_id': 'yyyyyyyyy03', 'media_type': 'audio'});
  }

  @override
  Future<DownloadJob> startDownload({
    required String videoId,
    String mediaType = 'audio',
    int? categoryId,
    int? playlistId,
    String? title,
    List<String> artists = const [],
    String? album,
    int? trackNumber,
    int? year,
    String? thumbnailUrl,
  }) async {
    sent.add(mediaType);
    return DownloadJob.fromJson({...jobJson(90 + sent.length, 'queued'), 'video_id': videoId, 'media_type': mediaType});
  }
}

/// Feste Zeit statt pumpAndSettle – nach dem Start dreht sich die Fortschrittsanzeige endlos.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

YouTubeItem video({int id = 3, int? audioTrack}) =>
    YouTubeItem.fromJson({...ytItemJson(id, type: 'video'), 'in_library_audio_track_id': audioTrack});

Future<RecordingApi> pumpButton(WidgetTester tester, YouTubeItem item, {Map<String, Object> prefs = const {}}) async {
  final api = RecordingApi();
  await pumpScreen(tester, Scaffold(body: Center(child: DownloadButton(item: item))), api: api, prefs: prefs);
  return api;
}

/// Gespeicherte Einstellung „YouTube-Videos holen als“ (im laufenden Test).
String videoFetchSetting(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(Scaffold).first)).read(settingsProvider).videoFetch;

void main() {
  testWidgets('Video: „Holen“ fragt – „Nur Musik“ holt nur den Ton', (tester) async {
    final api = await pumpButton(tester, video());
    await tester.tap(find.text('Holen'));
    await tester.pumpAndSettle();
    expect(find.text('Was möchtest du holen?'), findsOneWidget);
    await tester.tap(find.text('Nur Musik'));
    await settle(tester);
    expect(api.sent, ['audio']);
    expect(find.text('„YouTube Song 3“ wird als Musik geholt'), findsOneWidget);
    expectNoErrors(tester);
  });

  testWidgets('Video: „Video“ holt das ganze Video', (tester) async {
    final api = await pumpButton(tester, video());
    await tester.tap(find.text('Holen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Video'));
    await settle(tester);
    expect(api.sent, ['video']);
  });

  testWidgets('Video: Abbrechen holt nichts', (tester) async {
    final api = await pumpButton(tester, video());
    await tester.tap(find.text('Holen'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10)); // neben das Menü tippen
    await tester.pumpAndSettle();
    expect(api.sent, isEmpty);
  });

  testWidgets('Song: „Holen“ holt sofort, ohne zu fragen', (tester) async {
    final api = await pumpButton(tester, YouTubeItem.fromJson(ytItemJson(3)));
    await tester.tap(find.text('Holen'));
    await settle(tester);
    expect(find.text('Was möchtest du holen?'), findsNothing);
    expect(api.sent, ['audio']);
  });

  testWidgets('Video, dessen Musik schon da ist: direkt abspielen statt holen', (tester) async {
    await pumpButton(tester, video(audioTrack: 2));
    expect(find.byTooltip('Musik abspielen'), findsOneWidget);
    expect(find.text('Holen'), findsNothing);
  });

  testWidgets('Menü eines Videos: „Nur Musik holen“ und „Als Video holen“', (tester) async {
    final api = RecordingApi();
    await pumpScreen(tester, Scaffold(body: YouTubeItemTile(item: video())), api: api);
    await tester.longPress(find.text('YouTube Song 3'));
    await tester.pumpAndSettle();
    expect(find.text('Nur Musik holen'), findsOneWidget);
    expect(find.text('Musik holen und zu Playlist hinzufügen'), findsOneWidget);
    expect(find.text('Als Video holen'), findsOneWidget);
    await tester.tap(find.text('Nur Musik holen'));
    await settle(tester);
    expect(api.sent, ['audio']);
    expectNoErrors(tester);
  });

  testWidgets('Menü eines Videos, dessen Musik schon da ist: „Musik abspielen“', (tester) async {
    await pumpScreen(tester, Scaffold(body: YouTubeItemTile(item: video(audioTrack: 2))), api: RecordingApi());
    await tester.longPress(find.text('YouTube Song 3'));
    await tester.pumpAndSettle();
    expect(find.text('Musik abspielen'), findsOneWidget);
    expect(find.text('Nur Musik holen'), findsNothing);
    expect(find.text('Als Video holen'), findsOneWidget, reason: 'das Video selbst fehlt noch');
  });

  testWidgets('Menü: laufender Musik-Download lässt sich abbrechen – und nur er', (tester) async {
    final api = RecordingApi();
    await pumpScreen(tester, Scaffold(body: YouTubeItemTile(item: video())), api: api);
    await tester.longPress(find.text('YouTube Song 3'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nur Musik holen'));
    await settle(tester);
    await tester.longPress(find.text('YouTube Song 3'));
    await settle(tester);
    expect(find.text('Musik wird geholt …'), findsOneWidget);
    await tester.tap(find.text('Musik-Download abbrechen'));
    await settle(tester);
    expect(api.cancelled, [91], reason: 'der Musik-Auftrag, nicht ein Video');
  });

  group('Einstellung „YouTube-Videos holen als“', () {
    testWidgets('„Immer nur Musik“: „Holen“ holt ohne Nachfrage nur den Ton', (tester) async {
      final api = await pumpButton(tester, video(), prefs: {'s.videoFetch': 'audio'});
      await tester.tap(find.text('Holen'));
      await settle(tester);
      expect(find.text('Was möchtest du holen?'), findsNothing);
      expect(api.sent, ['audio']);
      expect(find.text('„YouTube Song 3“ wird als Musik geholt'), findsOneWidget);
      expectNoErrors(tester);
    });

    testWidgets('„Immer als Video“: „Holen“ holt ohne Nachfrage das Video', (tester) async {
      final api = await pumpButton(tester, video(), prefs: {'s.videoFetch': 'video'});
      await tester.tap(find.text('Holen'));
      await settle(tester);
      expect(find.text('Was möchtest du holen?'), findsNothing);
      expect(api.sent, ['video']);
    });

    testWidgets('Songs bleiben Songs – auch bei „Immer als Video“', (tester) async {
      final api = await pumpButton(tester, YouTubeItem.fromJson(ytItemJson(3)), prefs: {'s.videoFetch': 'video'});
      await tester.tap(find.text('Holen'));
      await settle(tester);
      expect(api.sent, ['audio']);
    });

    testWidgets('Unbekannter gespeicherter Wert: wie bisher fragen', (tester) async {
      final api = await pumpButton(tester, video(), prefs: {'s.videoFetch': 'irgendwas'});
      expect(videoFetchSetting(tester), 'ask');
      await tester.tap(find.text('Holen'));
      await tester.pumpAndSettle();
      expect(find.text('Was möchtest du holen?'), findsOneWidget);
      expect(api.sent, isEmpty);
    });

    testWidgets('„Wahl merken“: danach holt „Holen“ ohne Nachfrage', (tester) async {
      final api = RecordingApi();
      await pumpScreen(
        tester,
        Scaffold(body: Column(children: [DownloadButton(item: video()), DownloadButton(item: video(id: 4))])),
        api: api,
      );
      await tester.tap(find.text('Holen').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Wahl merken'));
      await tester.pump();
      await tester.tap(find.text('Nur Musik'));
      await settle(tester);
      expect(api.sent, ['audio']);
      expect(find.text('„YouTube Song 3“ wird als Musik geholt · Gemerkt, änderbar in den Einstellungen'), findsOneWidget);
      expect(videoFetchSetting(tester), 'audio');
      expect((await SharedPreferences.getInstance()).getString('s.videoFetch'), 'audio');

      // Das zweite Video: keine Frage mehr
      await tester.tap(find.text('Holen'));
      await settle(tester);
      expect(find.text('Was möchtest du holen?'), findsNothing);
      expect(api.sent, ['audio', 'audio']);
    });

    testWidgets('Ohne Haken bei „Wahl merken“ wird beim nächsten Mal wieder gefragt', (tester) async {
      final api = await pumpButton(tester, video());
      await tester.tap(find.text('Holen'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Video'));
      await settle(tester);
      expect(api.sent, ['video']);
      expect(find.text('„YouTube Song 3“ wird geholt'), findsOneWidget);
      expect(videoFetchSetting(tester), 'ask');
    });

    testWidgets('Einstellungen: „YouTube-Videos holen als“ umstellen', (tester) async {
      await pumpScreen(tester, const SettingsScreen());
      final tile = find.text('YouTube-Videos holen als');
      await tester.scrollUntilVisible(tile, 200, scrollable: find.byType(Scrollable).first);
      expect(find.text('Jedes Mal fragen'), findsOneWidget);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Immer nur Musik'));
      await tester.pumpAndSettle();
      expect(find.text('Immer nur Musik'), findsOneWidget, reason: 'neue Wahl steht unter der Einstellung');
      expect(videoFetchSetting(tester), 'audio');
      expect((await SharedPreferences.getInstance()).getString('s.videoFetch'), 'audio');
      expectNoErrors(tester);
    });

    testWidgets('Link einfügen: Vorauswahl „Video“ bei „Immer als Video“', (tester) async {
      await pumpScreen(tester, const Scaffold(body: YouTubeLinkTile()), prefs: {'s.videoFetch': 'video'});
      await tester.tap(find.text('YouTube-Link einfügen'));
      await settle(tester);
      expect(find.text('Landet als Video in deiner Bibliothek (mit Bild).'), findsOneWidget);
    });

    testWidgets('Link einfügen: Vorauswahl „Musik“ bei „Immer nur Musik“', (tester) async {
      await pumpScreen(tester, const Scaffold(body: YouTubeLinkTile()), prefs: {'s.videoFetch': 'audio'});
      await tester.tap(find.text('YouTube-Link einfügen'));
      await settle(tester);
      expect(find.text('Landet als Song in deiner Bibliothek (nur Ton).'), findsOneWidget);
    });
  });
}
