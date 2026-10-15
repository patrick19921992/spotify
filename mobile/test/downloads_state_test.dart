// Download-Zustand der App: Ziel-Rubrik, Fertig-Meldungen nach Neuaufbau, Song vs. Video.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfify/data/api.dart';
import 'package:selfify/data/models.dart';
import 'package:selfify/state/auth.dart';
import 'package:selfify/state/downloads.dart';
import 'package:selfify/state/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

class _RecordingApi extends FakeApi {
  int? sentCategory = -1;

  @override
  Future<DownloadJob> downloadItem(YouTubeItem item, {int? categoryId, int? playlistId}) async {
    sentCategory = categoryId;
    return DownloadJob.fromJson(jobJson(7, 'queued'));
  }

  @override
  Future<List<DownloadJob>> downloads({String scope = 'mine', String state = 'all', int limit = 100}) async => [];
}

Future<ProviderContainer> _container(ApiClient api, Map<String, Object> prefs) async {
  SharedPreferences.setMockInitialValues(prefs);
  final container = ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWithValue(await SharedPreferences.getInstance()),
    authProvider.overrideWith(() => FakeAuth(api as FakeApi)),
  ]);
  await container.read(authProvider.future);
  return container;
}

void main() {
  test('Gelöschte Ziel-Rubrik: Download geht an die Standard-Rubrik, Einstellung wird zurückgesetzt', () async {
    final api = _RecordingApi();
    final container = await _container(api, {'s.audioCategoryId': 99});
    addTearDown(container.dispose);
    container.listen(downloadsProvider, (_, _) {});
    expect(container.read(settingsProvider).audioCategoryId, 99);
    await container.read(downloadsProvider.notifier).startItem(YouTubeItem.fromJson(ytItemJson(3)));
    expect(api.sentCategory, isNull);
    expect(container.read(settingsProvider).audioCategoryId, isNull);
  });

  test('Vorhandene Ziel-Rubrik wird mitgeschickt', () async {
    final api = _RecordingApi();
    final container = await _container(api, {'s.audioCategoryId': 1});
    addTearDown(container.dispose);
    container.listen(downloadsProvider, (_, _) {});
    await container.read(downloadsProvider.notifier).startItem(YouTubeItem.fromJson(ytItemJson(3)));
    expect(api.sentCategory, 1);
  });

  test('Fertig-Meldungen funktionieren auch nach einem Neuaufbau (z. B. erneute Anmeldung)', () async {
    final container = await _container(_RecordingApi(), {});
    addTearDown(container.dispose);
    container.listen(downloadsProvider, (_, _) {});
    final controller = container.read(downloadsProvider.notifier);
    container.invalidate(downloadsProvider);
    container.read(downloadsProvider);
    var closed = false;
    final subscription = controller.finished.listen((_) {}, onDone: () => closed = true);
    addTearDown(subscription.cancel);
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse);
  });

  test('Song und Video mit derselben YouTube-ID sind getrennte Downloads', () {
    final audioJob = DownloadJob.fromJson({...jobJson(1, 'done'), 'video_id': 'XYZxyz12345', 'media_type': 'audio'});
    final state = DownloadsState(jobs: {1: audioJob});
    expect(state.forVideo('XYZxyz12345', mediaType: 'audio')?.id, 1);
    expect(state.forVideo('XYZxyz12345', mediaType: 'video'), isNull);
  });
}
