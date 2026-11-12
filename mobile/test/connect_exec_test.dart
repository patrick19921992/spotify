// Befehle anderer Geräte auf diesem Gerät ausführen (`exec` → `ack`) – mit nachgebautem just_audio und Server.


import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:selfify/data/models.dart';
import 'package:selfify/player/player.dart';
import 'package:selfify/state/offline.dart';

import 'support/connect_harness.dart';
import 'support/fake_audio.dart';
import 'support/fake_connect.dart';
import 'support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeJustAudio platform;

  setUp(() => platform = useFakeAudioPlatform());

  Future<ConnectHarness> connected({
    Map<String, Object> prefs = const {},
    AppConfig config = const AppConfig(),
    OfflineState offline = const OfflineState(loaded: true),
  }) async {
    final h = await ConnectHarness.start(null, prefs: prefs, config: config, offline: offline);
    await h.waitFor(() => h.server.channels.isNotEmpty, 'Verbindung');
    await h.welcome();
    return h;
  }

  /// Schickt `exec` und wartet auf das zugehörige `ack` (ohne `type`/`id`).
  Future<Map<String, dynamic>> exec(ConnectHarness h, String id, String action,
      [Map<String, Object?> args = const {}]) async {
    final before = h.channel.ofType('ack').where((a) => a['id'] == id).length;
    h.channel.receive({'type': 'exec', 'id': id, 'from': 2, 'action': action, 'args': args});
    await h.waitFor(() => h.channel.ofType('ack').where((a) => a['id'] == id).length > before, 'ack für $action');
    return Map.of(h.channel.ofType('ack').lastWhere((a) => a['id'] == id))
      ..remove('type')
      ..remove('id');
  }

  Map<String, Object?> takeOver({
    int count = 5,
    int index = 2,
    int positionMs = 30000,
    bool playing = true,
    bool shuffle = false,
    List<int>? order,
    String repeat = 'off',
  }) =>
      {
        'tracks': [for (var i = 1; i <= count; i++) trackJson(i)],
        'index': index,
        'position_ms': positionMs,
        'playing': playing,
        'shuffle': shuffle,
        'shuffle_order': ?order,
        'repeat': repeat,
        'context': {'type': 'album', 'id': '7', 'name': 'A Night at the Opera'},
        'volume': 0.4,
      };

  Future<void> finish(ConnectHarness h) async {
    await h.dispose();
    await h.handler.player.dispose();
  }

  test('take_over lädt Warteschlange mit Index, Position, Zufallsreihenfolge und Wiederholung', () async {
    final h = await connected();
    final ack = await exec(h, '2:a', 'take_over',
        takeOver(shuffle: true, order: [2, 0, 4, 1, 3], repeat: 'all', positionMs: 30000));
    expect(ack, {'ok': true});
    await h.waitFor(() => h.handler.player.playing, 'spielt');
    expect(h.handler.tracks.map((t) => t.id), [1, 2, 3, 4, 5]);
    expect(h.handler.player.currentIndex, 2);
    expect(platform.last!.pos, const Duration(seconds: 30));
    expect(h.handler.player.shuffleModeEnabled, isTrue);
    expect(h.handler.playOrder, [2, 0, 4, 1, 3]);
    expect(h.handler.player.loopMode, LoopMode.all);
    expect(h.handler.playContext!.id, 7);
    expect(h.handler.player.volume, 1.0, reason: 'Handy: Lautstärke nicht übernehmen');
    await finish(h);
  });

  test('take_over mit playing=false startet nicht', () async {
    final h = await connected();
    final ack = await exec(h, '2:a', 'take_over', takeOver(playing: false));
    expect(ack['ok'], isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(h.handler.tracks, hasLength(5));
    expect(h.handler.player.playing, isFalse);
    await finish(h);
  });

  test('release liefert den Stand vor dem Anhalten und stoppt', () async {
    final h = await connected();
    await exec(h, '2:a', 'take_over', takeOver(index: 1, positionMs: 5000));
    await h.waitFor(() => h.handler.player.playing, 'spielt');
    final ack = await exec(h, 'srv-1', 'release');
    expect(ack['ok'], isTrue);
    final snapshot = ack['snapshot'] as Map;
    expect(snapshot['playing'], isTrue);
    expect(snapshot['queue_ids'], [1, 2, 3, 4, 5]);
    expect(snapshot['index'], 1);
    expect(snapshot['position_ms'], inInclusiveRange(5000, 6000));
    expect(h.handler.player.playing, isFalse);
    expect(h.handler.tracks, hasLength(5), reason: 'Warteschlange bleibt geladen');
    await finish(h);
  });

  test('next mit Überspring-Grenze: skip_limit mit dem Text der Grenze', () async {
    final h = await connected(config: const AppConfig(freeSkipsPerHour: 4));
    await exec(h, '2:a', 'take_over', takeOver(index: 0));
    var blocked = 0;
    h.handler.allowSkip = () => false;
    h.handler.onSkipBlocked = () => blocked++;
    final ack = await exec(h, '2:b', 'next');
    expect(ack, {
      'ok': false,
      'code': 'skip_limit',
      'message': 'Du hast in dieser Stunde schon 4-mal übersprungen. Mit Premium unbegrenzt.',
    });
    expect(blocked, 1, reason: 'der Hinweis erscheint auch hier');
    expect(h.handler.player.currentIndex, 0);
    // skip_to auf einen späteren Titel zählt ebenso
    final skip = await exec(h, '2:c', 'skip_to', {'index': 3});
    expect(skip['code'], 'skip_limit');
    // Ohne Grenze geht es weiter
    h.handler.allowSkip = null;
    expect((await exec(h, '2:d', 'next'))['ok'], isTrue);
    await h.waitFor(() => h.handler.player.currentIndex == 1, 'weiter');
    await finish(h);
  });

  test('Offline-Modus: take_over ohne heruntergeladene Titel → offline_unavailable', () async {
    final h = await connected(prefs: {'s.offlineMode': true});
    final ack = await exec(h, '2:a', 'take_over', takeOver());
    expect(ack['ok'], isFalse);
    expect(ack['code'], 'offline_unavailable');
    expect(ack['message'], 'Keiner dieser Titel ist auf dem Gerät offline verfügbar.');
    expect(h.handler.tracks, isEmpty);
    // Auch „play“ geht über den Offline-Filter
    final play = await exec(h, '2:b', 'play', {'tracks': [trackJson(1)], 'index': 0, 'shuffle': false});
    expect(play['code'], 'offline_unavailable');
    await finish(h);
  });

  test('Offline-Modus: nur heruntergeladene Titel werden übernommen', () async {
    final h = await connected(prefs: {'s.offlineMode': true}, offline: offlineWithTracks());
    final ack = await exec(h, '2:a', 'take_over', takeOver(index: 1, positionMs: 9000));
    expect(ack['ok'], isTrue);
    expect(h.handler.tracks.map((t) => t.id), [1, 2]);
    expect(h.handler.player.currentIndex, 1);
    await finish(h);
  });

  test('doppelte exec-ID: einmal ausführen, zweimal dieselbe Antwort', () async {
    final h = await connected();
    await exec(h, '2:a', 'take_over', takeOver(index: 0));
    var skips = 0;
    h.handler.allowSkip = () {
      skips++;
      return true;
    };
    final first = await exec(h, '2:x', 'next');
    final second = await exec(h, '2:x', 'next');
    expect(first, {'ok': true});
    expect(second, first);
    expect(skips, 1);
    expect(h.channel.ofType('ack').where((a) => a['id'] == '2:x'), hasLength(2));
    await finish(h);
  });

  test('set_volume am Handy → unsupported; Unbekanntes → unsupported; kaputte Argumente → bad_request', () async {
    final h = await connected();
    expect(await exec(h, '2:a', 'set_volume', {'volume': 0.5}),
        {'ok': false, 'code': 'unsupported', 'message': 'Das kann dieses Gerät nicht.'});
    expect((await exec(h, '2:b', 'tanzen'))['code'], 'unsupported');
    expect((await exec(h, '2:c', 'seek', {'position_ms': -5}))['code'], 'bad_request');
    expect((await exec(h, '2:d', 'remove_queue', {'index': 99}))['code'], 'bad_request');
    await finish(h);
  });

  test('Fernsteuern: play, pause, resume, seek, Zufall, Wiederholen, Warteschlange', () async {
    final h = await connected();
    expect((await exec(h, '2:p', 'play', {
      'tracks': [trackJson(1), trackJson(2), trackJson(3)],
      'index': 1,
      'shuffle': false,
      'context': {'type': 'playlist', 'id': '5', 'name': 'Roadtrip'},
    }))['ok'], isTrue);
    await h.waitFor(() => h.handler.player.playing, 'spielt');
    expect(h.handler.player.currentIndex, 1);
    expect(h.handler.playContext!.title, 'Roadtrip');

    expect((await exec(h, '2:1', 'pause'))['ok'], isTrue);
    expect(h.handler.player.playing, isFalse);
    expect((await exec(h, '2:2', 'resume'))['ok'], isTrue);
    expect(h.handler.player.playing, isTrue);
    expect((await exec(h, '2:3', 'seek', {'position_ms': 42000}))['ok'], isTrue);
    expect(platform.last!.pos, const Duration(seconds: 42));
    expect((await exec(h, '2:4', 'set_repeat', {'mode': 'one'}))['ok'], isTrue);
    expect(h.handler.player.loopMode, LoopMode.one);
    expect((await exec(h, '2:5', 'set_shuffle', {'enabled': true}))['ok'], isTrue);
    expect(h.handler.player.shuffleModeEnabled, isTrue);
    expect((await exec(h, '2:6', 'set_shuffle', {'enabled': false}))['ok'], isTrue);

    expect((await exec(h, '2:7', 'add_queue', {'tracks': [trackJson(9)]}))['ok'], isTrue);
    expect(h.handler.tracks.last.id, 9);
    expect((await exec(h, '2:8', 'play_next', {'tracks': [trackJson(8)]}))['ok'], isTrue);
    expect(h.handler.tracks[2].id, 8);
    expect((await exec(h, '2:9', 'move_queue', {'from': 4, 'to': 3}))['ok'], isTrue);
    expect(h.handler.tracks.map((t) => t.id), [1, 2, 8, 9, 3]);
    expect((await exec(h, '2:10', 'remove_queue', {'index': 2}))['ok'], isTrue);
    expect(h.handler.tracks.map((t) => t.id), [1, 2, 9, 3]);
    expect((await exec(h, '2:10b', 'remove_queue', {'index': 1}))['code'], 'bad_request',
        reason: 'der laufende Titel bleibt');
    expect((await exec(h, '2:11', 'clear_upcoming'))['ok'], isTrue);
    expect(h.handler.tracks.map((t) => t.id), [1, 2]);
    expect(h.handler.playbackState.value.repeatMode, AudioServiceRepeatMode.one);
    await finish(h);
  });

  test('Befehle laufen strikt nacheinander', () async {
    final h = await connected();
    // Drei Befehle auf einmal – der zweite setzt voraus, dass der erste fertig ist
    h.channel.receive({'type': 'exec', 'id': 'a', 'from': 2, 'action': 'take_over', 'args': takeOver(index: 0)});
    h.channel.receive({'type': 'exec', 'id': 'b', 'from': 2, 'action': 'skip_to', 'args': {'index': 3}});
    h.channel.receive({'type': 'exec', 'id': 'c', 'from': 2, 'action': 'pause', 'args': {}});
    await h.waitFor(() => h.channel.ofType('ack').length == 3, 'drei Antworten');
    expect([for (final a in h.channel.ofType('ack')) a['id']], ['a', 'b', 'c']);
    expect(h.channel.ofType('ack').every((a) => a['ok'] == true), isTrue);
    expect(h.handler.player.currentIndex, 3);
    expect(h.handler.player.playing, isFalse);
    await finish(h);
  });

  test('Übertragen hin und zurück: abgeben (release) → Remote-Modus → zurückholen (take_over)', () async {
    final h = await connected();
    // Hier läuft etwas
    await exec(h, 'srv-0', 'take_over', takeOver(index: 1, positionMs: 12000));
    await h.waitFor(() => h.handler.player.playing, 'spielt hier');

    // Hin: an den PC übertragen
    final there = h.controller.transfer(2);
    await h.settle();
    expect(h.state.transferring, isTrue);
    expect(h.state.transferTarget, 2);
    final cmd = h.channel.lastOfType('cmd')!;
    expect(cmd['action'], 'transfer');
    expect(cmd['target'], 2);
    // Der Server holt den Stand von hier (release) …
    final release = await exec(h, 'srv-1', 'release');
    expect((release['snapshot'] as Map)['index'], 1);
    expect(h.handler.player.playing, isFalse);
    // … und meldet Erfolg; der PC ist jetzt aktiv
    h.channel.receive({'type': 'result', 'id': cmd['id'], 'ok': true});
    h.channel.receive({'type': 'devices', 'devices': FakeConnectServer.devicesJson(active: 2), 'active_device_id': 2});
    h.channel.receive({'type': 'state', 'device_id': 2, 'state': remoteStateJson(trackId: 2, positionMs: 12000)});
    expect((await there).ok, isTrue);
    await h.settle();
    expect(h.state.transferring, isFalse);
    expect(h.state.isRemote, isTrue);
    expect(h.container.read(currentTrackProvider)!.id, 2);

    // Bedienung im Remote-Modus geht als Befehl an den PC – hier spielt nichts los
    final pause = h.container.read(playerProvider).togglePlay();
    await h.settle();
    expect(h.container.read(isPlayingProvider), isFalse, reason: 'sofort umgeschaltet');
    final pauseCmd = h.channel.lastOfType('cmd')!;
    expect(pauseCmd['action'], 'pause');
    h.channel.receive({'type': 'result', 'id': pauseCmd['id'], 'ok': false, 'code': 'timeout'});
    await expectLater(pause, throwsA(isA<StateError>().having((e) => e.message, 'Text', 'Das Gerät antwortet nicht.')));
    expect(h.container.read(isPlayingProvider), isTrue, reason: 'bei Fehler zurück');
    expect(h.handler.player.playing, isFalse);

    // Zurück: an dieses Gerät
    final back = h.controller.transfer(1);
    await h.settle();
    final backCmd = h.channel.lastOfType('cmd')!;
    expect(backCmd['target'], 1);
    final takeAck = await exec(h, 'srv-2', 'take_over', takeOver(index: 1, positionMs: 15000));
    expect(takeAck['ok'], isTrue);
    h.channel.receive({'type': 'result', 'id': backCmd['id'], 'ok': true});
    h.channel.receive({'type': 'devices', 'devices': FakeConnectServer.devicesJson(active: 1), 'active_device_id': 1});
    expect((await back).ok, isTrue);
    await h.settle();
    expect(h.state.isRemote, isFalse);
    await h.waitFor(() => h.handler.player.playing, 'spielt wieder hier');
    expect(h.container.read(currentTrackProvider)!.id, 2);
    await finish(h);
  });
}
