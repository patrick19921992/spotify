// YouTube-Videos auch nur als Musik holen (z. B. Kinderlieder, die es bei YouTube nur als Video gibt):
// Holen-Knopf und Menü fragen bei Videos „Nur Musik“ oder „Video“; ein vorhandener Ton wird erkannt.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfify/data/models.dart';
import 'package:selfify/ui/screens/search_youtube.dart';
import 'package:selfify/ui/widgets/download_widgets.dart';

import 'support/fakes.dart';

class RecordingApi extends FakeApi {
  final sent = <String>[];

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

YouTubeItem video({int? audioTrack}) =>
    YouTubeItem.fromJson({...ytItemJson(3, type: 'video'), 'in_library_audio_track_id': audioTrack});

Future<RecordingApi> pumpButton(WidgetTester tester, YouTubeItem item) async {
  final api = RecordingApi();
  await pumpScreen(tester, Scaffold(body: Center(child: DownloadButton(item: item))), api: api);
  return api;
}

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
}
