// Nachgebaute Geräte-Verbindung („Wiedergabe auf anderen Geräten“): Der Test spielt den Server – er schickt
// Nachrichten, schließt mit Close-Codes und liest, was die App gesendet hat.

import 'dart:async';
import 'dart:convert';

import 'package:selfify/state/connect.dart';

class FakeConnectChannel implements ConnectChannel {
  final Uri uri;
  final Map<String, String> headers;
  final _incoming = StreamController<String>();
  final _ready = Completer<void>();

  /// Alles, was die App geschickt hat (dekodiert).
  final sent = <Map<String, dynamic>>[];

  /// Close-Code, mit dem die App selbst geschlossen hat (null = nicht von der App geschlossen).
  int? closedByApp;

  @override
  int? closeCode;
  @override
  String? closeReason;

  FakeConnectChannel(this.uri, this.headers, {Object? failWith, bool hang = false}) {
    if (hang) {
      // Handshake kommt nie zurück
    } else if (failWith == null) {
      _ready.complete();
    } else {
      _ready.completeError(failWith);
    }
  }

  bool get isOpen => closeCode == null && closedByApp == null;

  @override
  Future<void> get ready => _ready.future;

  @override
  Stream<String> get messages => _incoming.stream;

  @override
  void send(String text) => sent.add(Map<String, dynamic>.from(jsonDecode(text) as Map));

  @override
  Future<void> close([int? code, String? reason]) async {
    closedByApp ??= code ?? 1005;
    closeCode ??= code;
    if (!_incoming.isClosed) await _incoming.close();
  }

  // ---------------------------------------------------------------- Server-Seite

  void receive(Map<String, Object?> message) => _incoming.add(jsonEncode(message));

  void serverClose(int code, [String reason = '']) {
    closeCode = code;
    closeReason = reason;
    _incoming.close();
  }

  List<Map<String, dynamic>> ofType(String type) => [
        for (final m in sent)
          if (m['type'] == type) m,
      ];

  Map<String, dynamic>? lastOfType(String type) {
    final list = ofType(type);
    return list.isEmpty ? null : list.last;
  }
}

class FakeConnectServer {
  final channels = <FakeConnectChannel>[];

  /// Fehler für den nächsten Verbindungsaufbau (z. B. HTTP 404 beim Handshake).
  Object? failNext;

  /// Der nächste Verbindungsaufbau hängt (keine Antwort auf den Handshake).
  bool hangNext = false;

  ConnectChannelFactory get factory => (uri, headers) {
        final error = failNext;
        final hang = hangNext;
        failNext = null;
        hangNext = false;
        final channel = FakeConnectChannel(uri, headers, failWith: error, hang: hang);
        channels.add(channel);
        return channel;
      };

  FakeConnectChannel get last => channels.last;

  /// Begrüßung wie vom Server: dieses Gerät [selfId], dazu [others] (id → Name, Typ Computer mit Lautstärke).
  void welcome(
    FakeConnectChannel channel, {
    int selfId = 1,
    bool allowed = true,
    Map<int, String> others = const {2: 'Windows · BÜRO-PC'},
    int? active,
    Map<String, Object?>? state,
  }) {
    channel.receive({
      'type': 'welcome',
      'protocol': 1,
      'device_id': selfId,
      'allowed': allowed,
      'devices': devicesJson(selfId: selfId, others: others, active: active),
      'active_device_id': active,
      'state': state,
    });
  }

  static List<Map<String, Object?>> devicesJson({
    int selfId = 1,
    Map<int, String> others = const {2: 'Windows · BÜRO-PC'},
    int? active,
    bool otherCanPlay = true,
  }) =>
      [
        {
          'id': selfId,
          'name': 'Android · Pixel',
          'kind': 'phone',
          'platform': 'android',
          'caps': {'volume': false, 'play': true},
          'is_self': true,
          'is_active': active == selfId,
        },
        for (final entry in others.entries)
          {
            'id': entry.key,
            'name': entry.value,
            'kind': 'computer',
            'platform': 'windows',
            'caps': {'volume': true, 'play': otherCanPlay},
            'is_self': false,
            'is_active': active == entry.key,
          },
      ];
}
