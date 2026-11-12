// Datenmodelle für „Wiedergabe auf anderen Geräten“ (WebSocket /api/connect/ws, Protokoll Version 1).
// Parser sind tolerant: fehlende Felder bekommen Standardwerte, unbekannte werden ignoriert (Vorwärtskompatibilität).

import 'package:audio_service/audio_service.dart';

import '../player/audio_handler.dart' show PlayContext;
import 'models.dart';

/// Gerätetyp: `computer`, `phone` oder `tablet`.
abstract final class DeviceKind {
  static const computer = 'computer', phone = 'phone', tablet = 'tablet';
}

/// Ein verbundenes Gerät desselben Kontos.
class PlaybackDevice {
  /// Geräte-ID = ID der Anmeldung (Sitzung) auf dem Server.
  final int id;
  final String name;
  final String kind;
  final String platform;

  /// Lautstärke lässt sich fernsteuern (nur am PC).
  final bool canVolume;

  /// Kann überhaupt abspielen (z. B. Windows ohne libmpv: nein).
  final bool canPlay;
  final bool isSelf;
  final bool isActive;

  const PlaybackDevice({
    required this.id,
    required this.name,
    this.kind = DeviceKind.phone,
    this.platform = '',
    this.canVolume = false,
    this.canPlay = true,
    this.isSelf = false,
    this.isActive = false,
  });

  /// null, wenn die Angaben unbrauchbar sind (ohne ID).
  static PlaybackDevice? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! num) return null;
    final caps = raw['caps'] is Map ? raw['caps'] as Map : const {};
    final name = raw['name'] is String ? (raw['name'] as String).trim() : '';
    final kind = raw['kind'];
    return PlaybackDevice(
      id: id.toInt(),
      name: name.isEmpty ? 'Unbekanntes Gerät' : name,
      kind: kind == DeviceKind.computer || kind == DeviceKind.tablet ? kind as String : DeviceKind.phone,
      platform: raw['platform'] is String ? raw['platform'] as String : '',
      canVolume: caps['volume'] == true,
      canPlay: caps['play'] != false,
      isSelf: raw['is_self'] == true,
      isActive: raw['is_active'] == true,
    );
  }

  static List<PlaybackDevice> parseList(Object? raw) => raw is List
      ? [
          for (final item in raw)
            ?tryParse(item),
        ]
      : const [];
}

int? _intOrNull(Object? value) => value is num ? value.toInt() : null;

List<int> _ints(Object? value) => value is List
    ? [
        for (final item in value)
          if (item is num) item.toInt(),
      ]
    : const [];

Track? _track(Object? raw) {
  if (raw is! Map) return null;
  try {
    return Track.fromJson(Map<String, dynamic>.from(raw));
  } catch (_) {
    return null;
  }
}

/// Titel-Liste vom Server (TrackOut); kaputte Einträge fallen weg.
List<Track> parseTracks(Object? raw) => raw is List
    ? [
        for (final item in raw)
          ?_track(item),
      ]
    : const [];

/// Kontext („Wird gespielt von …“) im Protokoll: `{"type": "album", "id": "3", "name": "…"}`.
PlayContext? parsePlayContext(Object? raw) {
  if (raw is! Map || raw['type'] is! String) return null;
  final id = raw['id'];
  final name = raw['name'];
  return PlayContext(
    raw['type'] as String,
    id: id is num ? id.toInt() : (id is String ? int.tryParse(id) : null),
    title: name is String && name.isNotEmpty ? name : null,
  );
}

String _cut(String value, [int max = 200]) => value.length <= max ? value : value.substring(0, max);

Map<String, Object?>? playContextJson(PlayContext? context) => context == null
    ? null
    : {
        'type': _cut(context.type),
        'id': context.id?.toString(),
        'name': context.title == null ? null : _cut(context.title!),
      };

AudioServiceRepeatMode parseRepeat(Object? raw) => switch (raw) {
      'one' => AudioServiceRepeatMode.one,
      'all' => AudioServiceRepeatMode.all,
      _ => AudioServiceRepeatMode.none,
    };

String repeatName(AudioServiceRepeatMode mode) => switch (mode) {
      AudioServiceRepeatMode.one => 'one',
      AudioServiceRepeatMode.none => 'off',
      _ => 'all',
    };

/// Zustand des aktiven (anderen) Geräts, wie ihn der Server schickt – mit lokaler Empfangszeit.
class RemoteState {
  final bool playing;
  final int positionMs;
  final int? durationMs;
  final double speed;
  final List<int> queueIds;
  final int? index;

  /// Wo [queueIds] in der echten Warteschlange des Geräts beginnt (> 0 nur bei mehr als 1000 Titeln). Befehle mit
  /// Index rechnen damit in die volle Warteschlange um.
  final int queueOffset;
  final bool shuffle;
  final List<int> shuffleOrder;
  final AudioServiceRepeatMode repeat;
  final double? volume;
  final PlayContext? context;
  final Track? track;

  /// Kommende Titel in Abspielreihenfolge (höchstens 50, unsichtbare weggelassen).
  final List<Track> upcoming;
  final int queueRev;

  /// Wann dieser Stand hier ankam (Uhr dieses Geräts – es werden keine Uhren zwischen Geräten verglichen).
  final DateTime receivedAt;

  const RemoteState({
    required this.receivedAt,
    this.playing = false,
    this.positionMs = 0,
    this.durationMs,
    this.speed = 1,
    this.queueIds = const [],
    this.index,
    this.queueOffset = 0,
    this.shuffle = false,
    this.shuffleOrder = const [],
    this.repeat = AudioServiceRepeatMode.none,
    this.volume,
    this.context,
    this.track,
    this.upcoming = const [],
    this.queueRev = 0,
  });

  static RemoteState? tryParse(Object? raw, DateTime receivedAt) {
    if (raw is! Map) return null;
    final speed = raw['speed'];
    final volume = raw['volume'];
    return RemoteState(
      receivedAt: receivedAt,
      playing: raw['playing'] == true,
      positionMs: (_intOrNull(raw['position_ms']) ?? 0).clamp(0, 1 << 40),
      durationMs: _intOrNull(raw['duration_ms']),
      speed: speed is num && speed > 0 ? speed.toDouble() : 1,
      queueIds: _ints(raw['queue_ids']),
      index: _intOrNull(raw['index']),
      queueOffset: (_intOrNull(raw['queue_offset']) ?? 0).clamp(0, 1 << 30),
      shuffle: raw['shuffle'] == true,
      shuffleOrder: _ints(raw['shuffle_order']),
      repeat: parseRepeat(raw['repeat']),
      volume: volume is num ? volume.toDouble().clamp(0.0, 1.0) : null,
      context: parsePlayContext(raw['context']),
      track: _track(raw['track']),
      upcoming: parseTracks(raw['upcoming']),
      queueRev: _intOrNull(raw['queue_rev']) ?? 0,
    );
  }

  Duration? get duration {
    final ms = durationMs;
    if (ms != null && ms > 0) return Duration(milliseconds: ms);
    return track?.length;
  }

  /// Position zum Zeitpunkt [now], lokal hochgerechnet (spielt es, läuft die Zeit seit dem Empfang weiter).
  Duration positionAt(DateTime now) {
    var ms = positionMs.toDouble();
    if (playing) {
      final elapsed = now.difference(receivedAt).inMilliseconds;
      if (elapsed > 0) ms += elapsed * speed;
    }
    final max = duration?.inMilliseconds;
    if (max != null && ms > max) ms = max.toDouble();
    return Duration(milliseconds: ms.round());
  }

  /// Abspielreihenfolge (Indizes in [queueIds]).
  List<int> get playOrder {
    if (shuffle && shuffleOrder.length == queueIds.length) return shuffleOrder;
    return List.generate(queueIds.length, (i) => i);
  }

  /// Kommende Titel mit ihrem Index in [queueIds] (für „Springen“, „Entfernen“, „Verschieben“).
  List<({int index, Track track})> get upcomingEntries {
    final current = index;
    if (current == null || upcoming.isEmpty) return const [];
    final order = playOrder;
    final position = order.indexOf(current);
    if (position < 0) return const [];
    final entries = <({int index, Track track})>[];
    var next = 0;
    for (final queueIndex in order.skip(position + 1)) {
      if (next >= upcoming.length) break;
      if (queueIndex < 0 || queueIndex >= queueIds.length) continue;
      // Unsichtbare Titel hat der Server weggelassen – nur passende IDs zuordnen
      if (queueIds[queueIndex] == upcoming[next].id) {
        entries.add((index: queueIndex, track: upcoming[next]));
        next++;
      }
    }
    return entries;
  }

  RemoteState copyWith({bool? playing, int? positionMs, DateTime? receivedAt, double? volume}) => RemoteState(
        receivedAt: receivedAt ?? this.receivedAt,
        playing: playing ?? this.playing,
        positionMs: positionMs ?? this.positionMs,
        durationMs: durationMs,
        speed: speed,
        queueIds: queueIds,
        index: index,
        queueOffset: queueOffset,
        shuffle: shuffle,
        shuffleOrder: shuffleOrder,
        repeat: repeat,
        volume: volume ?? this.volume,
        context: context,
        track: track,
        upcoming: upcoming,
        queueRev: queueRev,
      );
}

/// Antwort auf einen Befehl (`result`).
class ConnectResult {
  final bool ok;
  final String? code;
  final String? message;
  final Map<String, dynamic>? data;

  const ConnectResult({required this.ok, this.code, this.message, this.data});
  const ConnectResult.failed(String this.code, {this.message})
      : ok = false,
        data = null;

  static ConnectResult parse(Map<String, dynamic> raw) => ConnectResult(
        ok: raw['ok'] == true,
        code: raw['code'] is String ? raw['code'] as String : null,
        message: raw['message'] is String && (raw['message'] as String).trim().isNotEmpty ? raw['message'] as String : null,
        data: raw['data'] is Map ? Map<String, dynamic>.from(raw['data'] as Map) : null,
      );

  /// Text für die Anzeige: die Meldung des Servers/Zielgeräts, sonst der feste Text zum Code.
  String get text => connectErrorText(code, message);
}

/// Feste Texte zu den Fehlercodes (gleiche Tabelle wie auf dem Server; `disconnected` gibt es nur in der App).
const connectErrorTexts = {
  'bad_request': 'Dieser Befehl wurde nicht verstanden.',
  'unknown_device': 'Dieses Gerät ist nicht mehr verbunden.',
  'offline': 'Dieses Gerät ist nicht mehr verbunden.',
  'unsupported': 'Das kann dieses Gerät nicht.',
  'premium': 'Auf anderen Geräten abspielen gibt es nur mit Premium.',
  'rate_limited': 'Zu viele Befehle auf einmal. Bitte kurz warten.',
  'timeout': 'Das Gerät antwortet nicht.',
  'busy': 'Gerade wird schon übertragen. Bitte kurz warten.',
  'not_found': 'Diese Titel sind nicht verfügbar.',
  'nothing_playing': 'Gerade läuft nichts, das übertragen werden kann.',
  'offline_unavailable': 'Keiner dieser Titel ist auf dem Gerät offline verfügbar.',
  'cannot_play': 'Auf diesem Gerät kann gerade nichts abgespielt werden.',
  'failed': 'Das hat auf dem Gerät nicht geklappt.',
  'queue_changed': 'Die Warteschlange hat sich gerade geändert. Bitte noch einmal versuchen.',
  'disconnected': 'Keine Verbindung zu deinen Geräten.',
};

String connectErrorText(String? code, String? message) {
  final text = message?.trim();
  if (text != null && text.isNotEmpty) return text;
  return connectErrorTexts[code] ?? connectErrorTexts['failed']!;
}
