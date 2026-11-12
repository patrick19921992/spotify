// Wiedergabe auf anderen Geräten („Selfify Connect“): Geräteliste, Übertragen, Fernsteuern und Live-Anzeige über
// einen WebSocket zum eigenen Server (`/api/connect/ws`, Protokoll Version 1).
//
// Jedes Gerät spielt selbst ab und löst die Quellen selbst auf (Qualität, Offline-Dateien, iPhone-AAC, Medien-Token) –
// der Server reicht nur Steuerbefehle und Titel-Angaben weiter.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show WebSocketException;
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart' show LoopMode;
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/client_info.dart';
import '../core/platform.dart';
import '../data/api.dart';
import '../data/connect_models.dart';
import '../data/models.dart';
import '../player/player.dart';
import '../player/skip_limit.dart';
import '../player/windows_audio.dart' show windowsAudioError;
import 'auth.dart';
import 'connectivity.dart';
import 'offline.dart';
import 'offline_access.dart' show clockProvider;
import 'premium_access.dart';
import 'settings.dart';

export '../data/connect_models.dart';

/// Protokollversion, die diese App spricht.
const connectProtocolVersion = 1;

/// Verbindung zum Server – eine Textnachricht je JSON-Objekt. In Tests ersetzbar (siehe [connectChannelFactoryProvider]).
abstract class ConnectChannel {
  /// Erfüllt, sobald die Verbindung steht; Fehler, wenn der Aufbau scheitert (z. B. HTTP 404 beim Handshake).
  Future<void> get ready;

  /// Eingehende Textnachrichten; endet, wenn die Verbindung zu ist ([closeCode]/[closeReason] sind dann gesetzt).
  Stream<String> get messages;
  void send(String text);
  Future<void> close([int? code, String? reason]);
  int? get closeCode;
  String? get closeReason;
}

class _WebSocketConnectChannel implements ConnectChannel {
  final WebSocketChannel _inner;
  _WebSocketConnectChannel(this._inner);

  @override
  Future<void> get ready => _inner.ready;
  @override
  Stream<String> get messages => _inner.stream.where((event) => event is String).cast<String>();
  @override
  void send(String text) => _inner.sink.add(text);
  @override
  Future<void> close([int? code, String? reason]) => _inner.sink.close(code, reason);
  @override
  int? get closeCode => _inner.closeCode;
  @override
  String? get closeReason => _inner.closeReason;
}

typedef ConnectChannelFactory = ConnectChannel Function(Uri uri, Map<String, String> headers);

/// Baut die Verbindung (Token im Header, nicht im Link). Tests setzen hier eine nachgebaute Verbindung ein.
final connectChannelFactoryProvider = Provider<ConnectChannelFactory>(
  (ref) => (uri, headers) => _WebSocketConnectChannel(
        IOWebSocketChannel.connect(
          uri,
          headers: headers,
          pingInterval: const Duration(seconds: 20),
          // Ohne Grenze wartet der Aufbau ewig, wenn die Leitung steht, aber nichts zurückkommt (Netzwechsel mitten im
          // Handshake, hängender Tunnel) – die Geräte-Funktion bliebe dann bis zum Neustart aus
          connectTimeout: ConnectController.connectTimeout,
        ),
      ),
);

/// Was dieses Gerät ist und kann (für `hello`).
class ConnectDeviceInfo {
  final String kind;
  final String platform;
  final bool canVolume;
  final bool canPlay;

  const ConnectDeviceInfo({required this.kind, required this.platform, required this.canVolume, required this.canPlay});
}

/// Gerätetyp nach Bildschirm: Computer, sonst kürzere Seite ab 600 = Tablet, darunter Handy.
String deviceKindFor({required bool desktop, required Size logicalScreen}) {
  if (desktop) return DeviceKind.computer;
  return logicalScreen.shortestSide >= 600 ? DeviceKind.tablet : DeviceKind.phone;
}

final connectDeviceInfoProvider = Provider<ConnectDeviceInfo>((ref) {
  var screen = Size.zero;
  try {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    screen = view.physicalSize / view.devicePixelRatio;
  } catch (_) {}
  var platform = currentClient?.platform ?? ClientInfo.platformName();
  if (platform.length > 20) platform = platform.substring(0, 20);
  return ConnectDeviceInfo(
    kind: deviceKindFor(desktop: isDesktopPlatform, logicalScreen: screen),
    platform: platform,
    // Lautstärke gibt es nur am PC (Handys regeln sie mit den Tasten)
    canVolume: isDesktopPlatform,
    canPlay: windowsAudioError == null,
  );
});

/// Lebenszyklus der App (Vordergrund/Hintergrund). In Tests direkt setzbar.
class AppLifecycleNotifier extends Notifier<AppLifecycleState?> {
  @override
  AppLifecycleState? build() {
    final listener = AppLifecycleListener(onStateChange: (next) {
      if (ref.mounted) state = next;
    });
    ref.onDispose(listener.dispose);
    return WidgetsBinding.instance.lifecycleState;
  }

  void set(AppLifecycleState next) => state = next;
}

final appLifecycleProvider = NotifierProvider<AppLifecycleNotifier, AppLifecycleState?>(AppLifecycleNotifier.new);

/// Stand der Geräte-Verbindung.
class ConnectState {
  /// Der Server kann „connect“ (`features` in `/api/server`). Alter Server: false – dann bleibt alles unsichtbar.
  final bool supported;

  /// Geräte-Funktion anzeigen: Server kann es, angemeldet, Netz da und nicht abgeschaltet (z. B. Protokoll-Fehler).
  final bool available;

  /// Verbunden und vom Server begrüßt (`welcome`).
  final bool connected;

  /// Darf dieses Konto übertragen und fernsteuern (Premium, wenn der Betreiber es so eingestellt hat)?
  final bool allowed;
  final int? selfId;
  final List<PlaybackDevice> devices;
  final int? activeDeviceId;

  /// Zustand des aktiven Geräts (nur wenn es ein anderes ist).
  final RemoteState? remote;
  final bool transferring;

  /// Ziel der laufenden Übertragung (für den Ladekreis in der Liste).
  final int? transferTarget;

  const ConnectState({
    this.supported = false,
    this.available = false,
    this.connected = false,
    this.allowed = true,
    this.selfId,
    this.devices = const [],
    this.activeDeviceId,
    this.remote,
    this.transferring = false,
    this.transferTarget,
  });

  /// Spielt gerade ein anderes Gerät, das von hier gesteuert wird? Nur, solange es auch verbunden ist: Während der
  /// Gnadenfrist nach einem Abbruch (60 s) steht es nicht in [devices] – Befehle an es scheiterten nur, also bleibt
  /// dieses Gerät so lange selbst bedienbar (Weiterhören vom letzten Stand geht über die Geräteliste).
  bool get isRemote =>
      connected && allowed && activeDeviceId != null && activeDeviceId != selfId && activeDevice != null;

  PlaybackDevice? get activeDevice => _device(activeDeviceId);
  PlaybackDevice? get selfDevice => _device(selfId);

  PlaybackDevice? _device(int? id) {
    if (id == null) return null;
    for (final device in devices) {
      if (device.id == id) return device;
    }
    return null;
  }

  static const _keep = Object();

  ConnectState copyWith({
    bool? supported,
    bool? available,
    bool? connected,
    bool? allowed,
    Object? selfId = _keep,
    List<PlaybackDevice>? devices,
    Object? activeDeviceId = _keep,
    Object? remote = _keep,
    bool? transferring,
    Object? transferTarget = _keep,
  }) =>
      ConnectState(
        supported: supported ?? this.supported,
        available: available ?? this.available,
        connected: connected ?? this.connected,
        allowed: allowed ?? this.allowed,
        selfId: identical(selfId, _keep) ? this.selfId : selfId as int?,
        devices: devices ?? this.devices,
        activeDeviceId: identical(activeDeviceId, _keep) ? this.activeDeviceId : activeDeviceId as int?,
        remote: identical(remote, _keep) ? this.remote : remote as RemoteState?,
        transferring: transferring ?? this.transferring,
        transferTarget: identical(transferTarget, _keep) ? this.transferTarget : transferTarget as int?,
      );
}

/// HTTP-Status eines gescheiterten Handshakes (z. B. 404 = Server ohne Geräte-Funktion), sonst null.
int? handshakeStatus(Object error) {
  Object? current = error;
  for (var depth = 0; current != null && depth < 4; depth++) {
    if (current is WebSocketException) return current.httpStatusCode;
    current = current is WebSocketChannelException ? current.inner : null;
  }
  final match = RegExp(r'status code: (\d{3})').firstMatch(error.toString());
  return match == null ? null : int.tryParse(match.group(1)!);
}

/// Hält die Verbindung zu den anderen Geräten des Kontos, meldet den eigenen Wiedergabe-Zustand und führt Befehle aus.
///
/// Verbunden ist die App nur, solange sie im Vordergrund ist oder selbst spielt (Computer gelten als immer im
/// Vordergrund). Begründung: Android hält den Prozess nur per Foreground-Service vom Typ `mediaPlayback` am Leben,
/// solange gespielt wird (`androidStopForegroundOnPause: true`); iOS friert Sockets ohne laufenden Ton ein
/// (`UIBackgroundModes: audio`). Ein Dauer-Service nur fürs Erreichbarbleiben würde den Akku belasten und bräuchte
/// einen weiteren Foreground-Service-Typ – Spotify macht das ebenfalls nicht. Pausierte Handys im Hintergrund
/// verschwinden deshalb aus der Liste und erscheinen wieder, sobald die App geöffnet wird.
class ConnectController extends Notifier<ConnectState> {
  static const backoffSeconds = [1, 2, 5, 10, 20, 30];
  static const pingEvery = Duration(seconds: 25);
  static const backgroundGrace = Duration(seconds: 10);
  static const stateDebounce = Duration(milliseconds: 300);
  static const stateHeartbeat = Duration(seconds: 15);
  static const commandTimeout = Duration(seconds: 20);
  static const connectTimeout = Duration(seconds: 15);
  static const featureRetrySeconds = [5, 15, 30, 60];
  static const maxQueueIds = 1000;
  static const rememberedExecs = 50;

  final _random = Random();

  ApiClient? _api;
  ConnectChannel? _channel;
  StreamSubscription<String>? _messages;
  final _subscriptions = <StreamSubscription<Object?>>[];
  Timer? _reconnectTimer;
  Timer? _pingTimer;
  Timer? _graceTimer;
  Timer? _stateTimer;
  Timer? _heartbeatTimer;
  Timer? _tokenTimer;
  Timer? _featureTimer;
  int _featureAttempt = 0;

  /// Erhöht sich bei jedem Auf- und Abbau – Rückmeldungen alter Verbindungen werden daran erkannt und verworfen.
  int _generation = 0;
  bool _connecting = false;
  int _attempt = 0;

  /// Server-Fähigkeit, Abschaltung bis zum nächsten Zurückkehren in die App (404, Protokoll-Fehler) und „auf diesem
  /// Gerät neu verbunden“ (4409, dann nicht selbst neu verbinden – sonst Pingpong zweier Instanzen).
  bool _supported = false;
  bool _disabled = false;
  bool _replaced = false;
  bool _authRetried = false;
  bool _forbiddenRetried = false;

  bool _localPlaying = false;
  int _seq = 0;
  int _commands = 0;
  final _pending = <String, Completer<ConnectResult>>{};

  // Ausführen von Befehlen (strikt nacheinander, letzte IDs gemerkt)
  Future<void> _execChain = Future.value();
  final _execResults = <String, Future<Map<String, Object?>>>{};

  // Gesendeter Zustand
  String? _sentSignature;
  bool _sentPlaying = false;
  Duration? _sentPosition;
  DateTime? _sentAt;

  // Optimistische Anzeige (Abspielen/Pause sofort umschalten)
  RemoteState? _optimistic;
  RemoteState? _beforeOptimistic;

  /// Beim Aufbau gemerkt – beim Abbau (onDispose) darf ref nicht mehr benutzt werden.
  SelfifyAudioHandler? _handlerCache;
  SelfifyAudioHandler get _handler {
    final cached = _handlerCache;
    if (cached != null) return cached;
    final handler = ref.read(audioHandlerProvider);
    _handlerCache = handler;
    return handler;
  }
  DateTime _now() => ref.read(clockProvider)();

  @override
  ConnectState build() {
    final api = ref.watch(apiProvider);
    _api = api;
    _generation++;
    _supported = false;
    _disabled = false;
    _replaced = false;
    _attempt = 0;
    ref.onDispose(_dispose);
    if (api == null) return const ConnectState();
    _featureAttempt = 0;
    ref.listen(isOfflineProvider, (previous, next) {
      // Netz wieder da: hat die Abfrage beim Start gefehlt, jetzt nachholen
      if (previous == true && !next && !_supported) loadFeatures();
      _evaluate();
    });
    ref.listen(appLifecycleProvider, (previous, next) => _onLifecycle(previous, next));
    ref.listen(connectivityProvider, (previous, next) {
      final before = previous?.value;
      final after = next.value;
      if (before == after) return;
      if (before != null && after != null && !_sameNetwork(before, after)) _onNetworkChanged();
      if (!_supported) loadFeatures();
      _kick();
    });
    final handler = ref.read(audioHandlerProvider);
    _handlerCache = handler;
    _localPlaying = handler.playbackState.value.playing;
    _subscriptions
      ..add(handler.playbackState.listen(_onLocalPlayback))
      ..add(handler.queue.listen((_) => _localChanged()))
      ..add(handler.mediaItem.listen((_) => _localChanged()))
      ..add(api.tokenChanges.listen(_onTokens));
    if (ref.read(connectDeviceInfoProvider).canVolume) {
      _subscriptions.add(handler.player.volumeStream.listen((_) => _localChanged()));
    }
    Future.microtask(loadFeatures);
    return const ConnectState();
  }

  // ------------------------------------------------------------------ Verfügbarkeit

  /// Fragt den Server, ob er die Geräte-Funktion kann (beim Start und beim Zurückkehren in die App).
  Future<void> loadFeatures() async {
    final api = _api;
    if (api == null || !ref.mounted) return;
    final generation = _generation;
    _featureTimer?.cancel();
    _featureTimer = null;
    try {
      final info = await api.serverInfo();
      if (!ref.mounted || generation != _generation) return;
      _supported = info.supportsConnect;
      _featureAttempt = 0;
    } catch (_) {
      // Server nicht erreichbar (z. B. Start ohne Netz, Server startet neu): beim bisherigen Stand bleiben und – solange
      // die Funktion noch nicht bekannt ist – später erneut fragen (am PC gibt es sonst keinen Anstoß)
      if (!ref.mounted || generation != _generation) return;
      if (!_supported) {
        final seconds = featureRetrySeconds[min(_featureAttempt, featureRetrySeconds.length - 1)];
        _featureAttempt++;
        _featureTimer = Timer(Duration(seconds: seconds), () {
          _featureTimer = null;
          if (ref.mounted && !_supported) loadFeatures();
        });
      }
    }
    if (ref.mounted && generation == _generation) _evaluate();
  }

  static bool _sameNetwork(List<Object?> a, List<Object?> b) => a.length == b.length && a.toSet().containsAll(b);

  /// Anderes Netz (WLAN -> Mobilfunk usw.): Eine bestehende Verbindung läuft noch über das alte und ist oft schon tot,
  /// ohne dass es jemand merkt (bis zu 40 s). Also schließen und gleich über das neue Netz neu verbinden – die alte
  /// Sitzung räumt der Server auf (4409 bzw. Zeitablauf).
  void _onNetworkChanged() {
    if (_channel == null && !_connecting) return;
    _disconnect();
  }

  bool get _noNetwork => ref.read(isOfflineProvider);

  bool get _available => _api != null && _supported && !_disabled && !_noNetwork;

  bool get _foreground => isForeground(ref.read(appLifecycleProvider));

  bool get _shouldConnect => _available && !_replaced && (_foreground || _localPlaying);

  void _evaluate() {
    if (!ref.mounted) return;
    final available = _available;
    if (state.available != available || state.supported != _supported) {
      state = state.copyWith(available: available, supported: _supported);
    }
    if (_shouldConnect) {
      _graceTimer?.cancel();
      _graceTimer = null;
      if (_channel == null && !_connecting && _reconnectTimer == null) _connect();
      return;
    }
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    if (_channel == null && !_connecting) return;
    if (available && !_replaced) {
      // Im Hintergrund ohne Wiedergabe: nach einer Gnadenfrist trennen (kurz zur Benachrichtigung gewechselt …)
      _graceTimer ??= Timer(backgroundGrace, () {
        _graceTimer = null;
        if (!_shouldConnect) _disconnect();
      });
    } else {
      _disconnect();
    }
  }

  void _onLifecycle(AppLifecycleState? previous, AppLifecycleState? next) {
    if (next == AppLifecycleState.resumed && previous != AppLifecycleState.resumed) {
      // Zurück in der App: alles auf Anfang (auch nach Abschaltung oder „auf diesem Gerät neu verbunden“)
      _disabled = false;
      _replaced = false;
      _forbiddenRetried = false;
      _kick();
      loadFeatures();
      return;
    }
    _evaluate();
  }

  /// Wartezeit zurücksetzen und – wenn gewünscht – sofort verbinden.
  void _kick() {
    _attempt = 0;
    if (_reconnectTimer != null) {
      _reconnectTimer!.cancel();
      _reconnectTimer = null;
    }
    _evaluate();
  }

  // ------------------------------------------------------------------ Verbindung

  Future<void> _connect() async {
    final api = _api;
    if (api == null || !ref.mounted) return;
    final generation = ++_generation;
    _connecting = true;
    try {
      if (api.tokens.accessExpiringSoon) await api.refresh();
    } catch (_) {
      if (generation != _generation || !ref.mounted) return;
      _connecting = false;
      _scheduleReconnect();
      return;
    }
    if (generation != _generation || !ref.mounted) return;
    if (!_shouldConnect) {
      _connecting = false;
      return;
    }
    final headers = <String, String>{'Authorization': 'Bearer ${api.tokens.accessToken}', ...?clientHeaders};
    final ConnectChannel channel;
    try {
      channel = ref.read(connectChannelFactoryProvider)(api.connectWebSocketUri(), headers);
    } catch (_) {
      _connecting = false;
      _scheduleReconnect();
      return;
    }
    _channel = channel;
    try {
      // Doppelt abgesichert (die echte Verbindung hat connectTimeout): ein hängender Aufbau blockiert sonst alles
      await channel.ready.timeout(connectTimeout);
    } catch (error) {
      if (generation != _generation || !ref.mounted) return;
      _channel = null;
      _connecting = false;
      if (error is TimeoutException) channel.close(1000).ignore();
      await _onHandshakeFailed(api, error is TimeoutException ? null : handshakeStatus(error));
      return;
    }
    if (generation != _generation || !ref.mounted) {
      channel.close(1000).ignore();
      return;
    }
    _connecting = false;
    _messages = channel.messages.listen(
      (raw) => _onMessage(generation, raw),
      onDone: () => _onClosed(generation, channel),
      onError: (Object _) {},
    );
    final info = ref.read(connectDeviceInfoProvider);
    _send({
      'type': 'hello',
      'v': connectProtocolVersion,
      'kind': info.kind,
      'platform': info.platform,
      'caps': {'volume': info.canVolume, 'play': info.canPlay},
      'playing': _localPlaying,
    });
    _pingTimer = Timer.periodic(pingEvery, (_) => _send({'type': 'ping'}));
  }

  Future<void> _onHandshakeFailed(ApiClient api, int? status) async {
    if (status == 404) {
      // Server ohne Geräte-Funktion (trotz Angabe, z. B. Proxy ohne WebSockets): bis zum nächsten Zurückkehren aus
      _disabled = true;
      _evaluate();
      return;
    }
    if (status == 403 || status == 401) {
      // Der Server lehnt vor dem Aufbau ab (z. B. abgelaufene Anmeldung – uvicorn antwortet dann mit 403). Einmal
      // mit frischem Token versuchen; klappt es dann immer noch nicht, abschalten.
      if (!_forbiddenRetried) {
        _forbiddenRetried = true;
        try {
          await api.refresh();
        } catch (_) {
          // Ungültige Anmeldung: der bestehende Abmelde-Weg greift (onSessionExpired)
          if (ref.mounted) _scheduleReconnect();
          return;
        }
        if (ref.mounted) _evaluate();
        return;
      }
      _disabled = true;
      _evaluate();
      return;
    }
    _scheduleReconnect();
  }

  void _scheduleReconnect({bool slow = false}) {
    if (!ref.mounted) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    if (!_shouldConnect) return;
    if (slow && _attempt < backoffSeconds.length - 1) _attempt = backoffSeconds.length - 1;
    final seconds = backoffSeconds[min(_attempt, backoffSeconds.length - 1)];
    _attempt++;
    // ±20 % Zufall, damit nach einem Server-Neustart nicht alle Geräte im selben Moment kommen
    final delay = Duration(milliseconds: (seconds * 1000 * (0.8 + _random.nextDouble() * 0.4)).round());
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      if (ref.mounted && _shouldConnect && _channel == null && !_connecting) _connect();
    });
  }

  void _onClosed(int generation, ConnectChannel channel) {
    if (generation != _generation || !ref.mounted) return;
    final code = channel.closeCode;
    _dropConnection();
    final api = _api;
    if (api == null) return;
    switch (code) {
      case 4001:
        // Token abgelaufen: erneuern und sofort neu verbinden
        _reconnectWithFreshToken(api);
      case 4400:
        // Ungültige Nachricht / Protokoll nicht unterstützt: bis zum nächsten Zurückkehren abschalten
        _disabled = true;
        _evaluate();
      case 4401:
        if (_authRetried) {
          _scheduleReconnect();
        } else {
          _authRetried = true;
          _reconnectWithFreshToken(api);
        }
      case 4409:
        // Auf diesem Gerät neu verbunden (zweite Instanz): nicht zurückdrängeln
        _replaced = true;
        _evaluate();
      case 4429:
        _scheduleReconnect(slow: true);
      default:
        _scheduleReconnect();
    }
  }

  Future<void> _reconnectWithFreshToken(ApiClient api) async {
    _connecting = true;
    final generation = _generation;
    try {
      await api.refresh();
    } catch (_) {
      // 401: Abmelden über den bestehenden Weg (onSessionExpired) – sonst später erneut
      if (!ref.mounted || generation != _generation) return;
      _connecting = false;
      _scheduleReconnect();
      return;
    }
    if (!ref.mounted || generation != _generation) return;
    _connecting = false;
    _attempt = 0;
    _evaluate();
  }

  /// Verbindung schließen (z. B. App im Hintergrund ohne Wiedergabe).
  void _disconnect([int code = 1000]) {
    final channel = _channel;
    _generation++;
    _connecting = false;
    _dropConnection();
    channel?.close(code).ignore();
  }

  /// Alles zur Verbindung abräumen; offene Befehle scheitern mit `disconnected`.
  void _dropConnection() {
    _messages?.cancel();
    _messages = null;
    _channel = null;
    _pingTimer?.cancel();
    _pingTimer = null;
    _stateTimer?.cancel();
    _stateTimer = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _tokenTimer?.cancel();
    _tokenTimer = null;
    _sentSignature = null;
    _sentPlaying = false;
    // Gemerkte Befehls-IDs gelten nur innerhalb einer Verbindung: Nach einem Server-Neustart könnten IDs wieder
    // auftauchen und würden sonst als „schon ausgeführt“ übergangen. Offene beendet der Server beim Trennen selbst.
    _execResults.clear();
    _optimistic = null;
    _beforeOptimistic = null;
    final pending = Map.of(_pending);
    _pending.clear();
    for (final completer in pending.values) {
      if (!completer.isCompleted) completer.complete(const ConnectResult.failed('disconnected'));
    }
    _handlerCache?.mediaKeyTarget = null;
    if (ref.mounted) {
      state = state.copyWith(
        connected: false,
        devices: const [],
        activeDeviceId: null,
        remote: null,
        transferring: false,
        transferTarget: null,
      );
    }
  }

  void _dispose() {
    _generation++;
    final channel = _channel;
    _messages?.cancel();
    _channel = null;
    channel?.close(1000).ignore();
    for (final timer in [
      _reconnectTimer, _pingTimer, _graceTimer, _stateTimer, _heartbeatTimer, _tokenTimer, _featureTimer, //
    ]) {
      timer?.cancel();
    }
    _reconnectTimer = _pingTimer = _graceTimer = _stateTimer = _heartbeatTimer = _tokenTimer = _featureTimer = null;
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions.clear();
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.complete(const ConnectResult.failed('disconnected'));
    }
    _pending.clear();
    _connecting = false;
    _handlerCache?.mediaKeyTarget = null;
  }

  void _send(Map<String, Object?> message) {
    final channel = _channel;
    if (channel == null) return;
    try {
      channel.send(jsonEncode(message));
    } catch (_) {}
  }

  // ------------------------------------------------------------------ Token

  void _onTokens(Tokens tokens) {
    if (_channel == null || !state.connected) return;
    _send({'type': 'auth', 'token': tokens.accessToken});
    _scheduleTokenRenewal();
  }

  /// Vor Ablauf des Tokens einen neuen holen – der Server bekommt ihn dann in-band (`auth`).
  void _scheduleTokenRenewal() {
    _tokenTimer?.cancel();
    final api = _api;
    if (api == null) return;
    var wait = api.tokens.accessExpiresAt.subtract(const Duration(minutes: 2)).difference(DateTime.now());
    if (wait < const Duration(seconds: 5)) wait = const Duration(seconds: 5);
    _tokenTimer = Timer(wait, () {
      _tokenTimer = null;
      if (_channel != null) api.refresh().ignore();
    });
  }

  // ------------------------------------------------------------------ Nachrichten

  void _onMessage(int generation, String raw) {
    if (generation != _generation || !ref.mounted) return;
    Map<String, dynamic> message;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      message = Map<String, dynamic>.from(decoded);
    } catch (_) {
      return;
    }
    switch (message['type']) {
      case 'welcome':
        _onWelcome(message);
      case 'devices':
        _applyDevices(PlaybackDevice.parseList(message['devices']), _optionalInt(message, 'active_device_id'));
      case 'state':
        _onRemoteState(message);
      case 'exec':
        _onExec(message);
      case 'result':
        final id = message['id'];
        if (id is String) _pending.remove(id)?.complete(ConnectResult.parse(message));
      case 'access':
        final allowed = message['allowed'] != false;
        state = state.copyWith(allowed: allowed, remote: allowed ? state.remote : null);
        _syncMediaKeys();
      // auth_ok, ping und Unbekanntes: nichts zu tun (neue Typen werden ignoriert)
    }
  }

  static int? _optionalInt(Map<String, dynamic> message, String key) {
    final value = message[key];
    return value is num ? value.toInt() : null;
  }

  void _onWelcome(Map<String, dynamic> message) {
    _attempt = 0;
    _authRetried = false;
    _forbiddenRetried = false;
    final selfId = _optionalInt(message, 'device_id');
    final active = _optionalInt(message, 'active_device_id');
    state = state.copyWith(
      connected: true,
      allowed: message['allowed'] != false,
      selfId: selfId,
      devices: PlaybackDevice.parseList(message['devices']),
      activeDeviceId: active,
      remote: active != null && active != selfId ? RemoteState.tryParse(message['state'], _now()) : null,
    );
    _syncMediaKeys();
    _scheduleTokenRenewal();
    // Spielt dieses Gerät, sofort den Stand melden
    if (_localPlaying || (selfId != null && active == selfId)) _sendState();
  }

  void _applyDevices(List<PlaybackDevice> devices, int? active) {
    final changed = active != state.activeDeviceId;
    state = state.copyWith(
      devices: devices,
      activeDeviceId: active,
      remote: changed || active == null || active == state.selfId ? null : state.remote,
    );
    _syncMediaKeys();
    // Dieses Gerät wurde gerade aktiv (z. B. per Übertragung): Stand melden
    if (changed && active != null && active == state.selfId) _scheduleState();
  }

  void _onRemoteState(Map<String, dynamic> message) {
    final deviceId = _optionalInt(message, 'device_id');
    if (deviceId == null || deviceId == state.selfId) return;
    final remote = RemoteState.tryParse(message['state'], _now());
    if (remote == null) return;
    _optimistic = null;
    _beforeOptimistic = null;
    state = state.copyWith(remote: remote, activeDeviceId: state.activeDeviceId ?? deviceId);
  }

  /// Medientasten am PC (Windows-Medienübersicht) steuern im Remote-Modus das andere Gerät.
  void _syncMediaKeys() {
    if (!ref.mounted) return;
    _handler.mediaKeyTarget = state.isRemote ? _RemoteMediaKeys(ref.read(playerProvider)) : null;
  }

  // ------------------------------------------------------------------ Befehle an andere Geräte

  /// Befehl an ein Gerät schicken. Scheitert nie mit einer Ausnahme – Fehler stehen im Ergebnis.
  Future<ConnectResult> command(int target, String action, [Map<String, Object?> args = const {}]) {
    if (_channel == null || !state.connected) return Future.value(const ConnectResult.failed('disconnected'));
    final id = '${_now().microsecondsSinceEpoch.toRadixString(36)}-${++_commands}';
    final completer = Completer<ConnectResult>();
    _pending[id] = completer;
    _send({'type': 'cmd', 'id': id, 'target': target, 'action': action, 'args': args});
    return completer.future.timeout(commandTimeout, onTimeout: () {
      _pending.remove(id);
      return const ConnectResult.failed('timeout');
    });
  }

  /// Befehl an das aktive (andere) Gerät.
  Future<ConnectResult> remoteCommand(String action, [Map<String, Object?> args = const {}]) {
    final target = state.activeDeviceId;
    if (!state.isRemote || target == null) return Future.value(const ConnectResult.failed('disconnected'));
    return command(target, action, args);
  }

  /// Wiedergabe auf [target] übertragen (auch an dieses Gerät = zurückholen).
  Future<ConnectResult> transfer(int target, {bool? play}) async {
    if (state.transferring) return const ConnectResult.failed('busy');
    state = state.copyWith(transferring: true, transferTarget: target);
    try {
      return await command(target, 'transfer', {'play': ?play});
    } finally {
      if (ref.mounted) state = state.copyWith(transferring: false, transferTarget: null);
    }
  }

  /// Anzeige sofort umschalten (Abspielen/Pause); [revert] stellt den vorigen Stand wieder her.
  void showPlaying(bool playing) {
    final remote = state.remote;
    if (remote == null) return;
    final now = _now();
    _beforeOptimistic = remote;
    _optimistic = remote.copyWith(
      playing: playing,
      positionMs: remote.positionAt(now).inMilliseconds,
      receivedAt: now,
    );
    state = state.copyWith(remote: _optimistic);
  }

  void revertPlaying() {
    final before = _beforeOptimistic;
    if (before != null && identical(state.remote, _optimistic)) state = state.copyWith(remote: before);
    _optimistic = null;
    _beforeOptimistic = null;
  }

  /// Aktuelle Position des anderen Geräts (lokal hochgerechnet).
  Duration remotePosition() => state.remote?.positionAt(_now()) ?? Duration.zero;

  // ------------------------------------------------------------------ Eigener Zustand

  void _onLocalPlayback(PlaybackState playback) {
    final playing = playback.playing;
    final started = playing && !_localPlaying;
    _localPlaying = playing;
    if (started) {
      // Lokale Wiedergabe startet: sofort (wieder) verbinden
      _kick();
    } else {
      _evaluate();
    }
    _localChanged();
  }

  /// Etwas am eigenen Player hat sich geändert – entprellt melden, wenn es die anderen etwas angeht.
  void _localChanged() {
    if (_channel == null || !state.connected) return;
    if (!_shouldReport()) return;
    final handler = _handler;
    final signature = _signature(handler);
    var jumped = false;
    final sentPosition = _sentPosition;
    final sentAt = _sentAt;
    if (sentPosition != null && sentAt != null) {
      final expected = _sentPlaying ? sentPosition + DateTime.now().difference(sentAt) * handler.player.speed : sentPosition;
      jumped = (handler.player.position - expected).abs() > const Duration(seconds: 2);
    }
    if (signature == _sentSignature && !jumped) return;
    _scheduleState();
  }

  /// Spielt dieses Gerät, ist es das aktive, oder hat es gerade aufgehört zu spielen (einmal melden)?
  bool _shouldReport() {
    final selfId = state.selfId;
    return _localPlaying || (selfId != null && state.activeDeviceId == selfId) || _sentPlaying;
  }

  void _scheduleState() {
    if (_channel == null) return;
    _stateTimer?.cancel();
    _stateTimer = Timer(stateDebounce, () {
      _stateTimer = null;
      _sendState();
    });
  }

  String _signature(SelfifyAudioHandler handler) {
    final p = handler.player;
    return [
      _localPlaying,
      p.currentIndex,
      handler.tracks.length,
      handler.tracks.isEmpty ? '' : '${handler.tracks.first.id}/${handler.tracks.last.id}',
      p.shuffleModeEnabled,
      p.loopMode.name,
      p.speed,
      if (ref.read(connectDeviceInfoProvider).canVolume) p.volume,
      handler.playContext?.type,
      handler.playContext?.id,
    ].join('|');
  }

  void _sendState() {
    if (_channel == null || !state.connected || !ref.mounted) return;
    if (!_shouldReport()) return;
    final handler = _handler;
    final snapshot =
        localSnapshot(handler, canVolume: ref.read(connectDeviceInfoProvider).canVolume, playing: _localPlaying);
    _send({
      'type': 'state',
      'state': {'seq': ++_seq, ...snapshot},
    });
    _sentSignature = _signature(handler);
    _sentPlaying = _localPlaying;
    _sentPosition = handler.player.position;
    _sentAt = DateTime.now();
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    // Während der Wiedergabe alle 15 s (nie pro Positions-Tick)
    if (_sentPlaying) _heartbeatTimer = Timer(stateHeartbeat, _sendState);
  }

  // ------------------------------------------------------------------ Befehle auf diesem Gerät ausführen

  void _onExec(Map<String, dynamic> message) {
    final id = message['id'];
    if (id is! String || id.isEmpty) return;
    final known = _execResults[id];
    if (known != null) {
      // Schon (oder gerade) ausgeführt: dieselbe Antwort noch einmal, nichts erneut ausführen
      known.then((ack) => _sendAck(id, ack)).ignore();
      return;
    }
    final action = message['action'] is String ? message['action'] as String : '';
    final args = message['args'] is Map ? Map<String, dynamic>.from(message['args'] as Map) : <String, dynamic>{};
    final result = _execChain.then((_) => ConnectExecutor(ref).run(action, args)).catchError(
          (Object e) => ConnectExecutor.failure('failed'),
        );
    _execChain = result.then((_) {});
    _execResults[id] = result;
    while (_execResults.length > rememberedExecs) {
      _execResults.remove(_execResults.keys.first);
    }
    result.then((ack) => _sendAck(id, ack)).ignore();
  }

  void _sendAck(String id, Map<String, Object?> ack) {
    if (!ref.mounted) return;
    _send({'type': 'ack', 'id': id, ...ack});
    // Nach einem Befehl gleich den neuen Stand melden (entprellt)
    _localChanged();
  }
}

/// Medientasten am PC → Fernsteuerung.
class _RemoteMediaKeys implements MediaKeyTarget {
  final PlayerController player;
  _RemoteMediaKeys(this.player);

  @override
  Future<void> play() => player.resume();
  @override
  Future<void> pause() => player.pause();
  @override
  Future<void> next() => player.next();
  @override
  Future<void> previous() => player.previous();
}

/// Beginn eines Ausschnitts von höchstens 1000 Titeln um [index] herum (Warteschlange mit [length] Titeln).
int queueWindowStart(int length, int index) {
  const size = ConnectController.maxQueueIds;
  if (length <= size) return 0;
  return (index - size ~/ 2).clamp(0, length - size);
}

/// Eigener Wiedergabe-Zustand im Protokoll-Format (`State` ohne `seq`). Warteschlangen über 1000 Titel werden um den
/// aktuellen Titel herum abgeschnitten.
Map<String, Object?> localSnapshot(SelfifyAudioHandler handler, {required bool canVolume, bool? playing}) {
  final player = handler.player;
  final tracks = handler.tracks;
  var ids = [for (final t in tracks) t.id];
  final current = player.currentIndex;
  int? index = ids.isEmpty ? null : (current != null && current >= 0 && current < ids.length ? current : 0);
  final shuffle = player.shuffleModeEnabled;
  var order = shuffle ? handler.playOrder.where((i) => i >= 0 && i < ids.length).toList() : <int>[];
  var offset = 0;
  if (ids.length > ConnectController.maxQueueIds && index != null) {
    final start = queueWindowStart(ids.length, index);
    offset = start;
    final end = start + ConnectController.maxQueueIds;
    ids = ids.sublist(start, end);
    index -= start;
    order = [
      for (final i in order)
        if (i >= start && i < end) i - start,
    ];
  }
  final duration = player.duration ?? handler.currentTrack?.length;
  return {
    'playing': playing ?? player.playing,
    'position_ms': player.position.inMilliseconds,
    'duration_ms': duration == null || duration <= Duration.zero ? null : duration.inMilliseconds,
    'speed': player.speed,
    'queue_ids': ids,
    'index': index,
    // Wo der Ausschnitt in der echten Warteschlange beginnt – Befehle mit Index rechnen damit zurück
    if (offset > 0) 'queue_offset': offset,
    'shuffle': shuffle,
    if (shuffle) 'shuffle_order': order,
    'repeat': switch (player.loopMode) {
      LoopMode.off => 'off',
      LoopMode.one => 'one',
      LoopMode.all => 'all',
    },
    'volume': canVolume ? player.volume : null,
    'context': playContextJson(handler.playContext),
  };
}

/// Führt Befehle anderer Geräte (`exec`) auf diesem Gerät aus und liefert die Antwort (`ack` ohne `id`).
class ConnectExecutor {
  final Ref ref;
  ConnectExecutor(this.ref);

  static Map<String, Object?> success([Map<String, Object?>? snapshot]) => {'ok': true, 'snapshot': ?snapshot};

  static Map<String, Object?> failure(String code, [String? message]) =>
      {'ok': false, 'code': code, 'message': connectErrorText(code, message)};

  SelfifyAudioHandler get _handler => ref.read(audioHandlerProvider);
  PlayerController get _player => ref.read(playerProvider);
  bool get _canVolume => ref.read(connectDeviceInfoProvider).canVolume;
  bool get _offlineOnly => ref.read(settingsProvider).offlineMode || ref.read(isOfflineProvider);

  static int? _int(Object? value) => value is num ? value.toInt() : null;

  Future<Map<String, Object?>> run(String action, Map<String, dynamic> args) async {
    final handler = _handler;
    try {
      switch (action) {
        case 'release':
          // Snapshot mit dem Stand vor dem Anhalten; dann aufhören (Verlauf melden), Warteschlange bleibt geladen
          final snapshot = localSnapshot(handler, canVolume: _canVolume);
          if (handler.currentTrack != null) await handler.stop();
          return success(snapshot);
        case 'take_over':
          return await _takeOver(args);
        case 'play':
          final tracks = parseTracks(args['tracks']);
          if (tracks.isEmpty) return failure('bad_request');
          await _player.playLocally(
            tracks,
            index: _int(args['index']) ?? 0,
            context: parsePlayContext(args['context']),
            shuffle: args['shuffle'] == true,
            wait: false,
          );
          return success();
        case 'add_queue' || 'play_next':
          final tracks = parseTracks(args['tracks']);
          if (tracks.isEmpty) return failure('bad_request');
          if (_offlineOnly) {
            final offline = ref.read(offlineProvider);
            if (!tracks.any((t) => offline.isDownloaded(t.id))) return failure('offline_unavailable');
          }
          if (windowsAudioError != null) return failure('cannot_play');
          final list = _offlineOnly ? tracks.where((t) => ref.read(offlineProvider).isDownloaded(t.id)).toList() : tracks;
          action == 'add_queue' ? await _player.addToQueueLocally(list) : await _player.playNextLocally(list);
          return success();
        case 'resume':
          if (windowsAudioError != null) return failure('cannot_play');
          await handler.resume();
          return success();
        case 'pause':
          await handler.pause();
          return success();
        case 'next':
          final blocked = handler.skipsBlocked;
          await handler.skipToNext();
          return handler.skipsBlocked != blocked ? _skipLimit() : success();
        case 'previous':
          await handler.skipToPrevious();
          return success();
        case 'seek':
          final position = _int(args['position_ms']);
          if (position == null || position < 0) return failure('bad_request');
          await handler.seek(Duration(milliseconds: position));
          return success();
        case 'skip_to':
          final index = _queueIndex(handler, args);
          if (index == null) return failure('bad_request');
          if (index < 0) return failure('queue_changed');
          final blocked = handler.skipsBlocked;
          await handler.skipToIndex(index, wait: false);
          return handler.skipsBlocked != blocked ? _skipLimit() : success();
        case 'set_shuffle':
          final enabled = args['enabled'];
          if (enabled is! bool) return failure('bad_request');
          await handler.setShuffleMode(enabled ? AudioServiceShuffleMode.all : AudioServiceShuffleMode.none);
          return success();
        case 'set_repeat':
          final mode = args['mode'];
          if (mode != 'off' && mode != 'one' && mode != 'all') return failure('bad_request');
          await handler.setRepeatMode(parseRepeat(mode));
          return success();
        case 'set_volume':
          if (!_canVolume) return failure('unsupported');
          final volume = args['volume'];
          if (volume is! num || volume < 0 || volume > 1) return failure('bad_request');
          await setPlayerVolume(ref.read(sharedPreferencesProvider), handler, volume.toDouble());
          return success();
        case 'remove_queue':
          final index = _queueIndex(handler, args);
          if (index == null || index == handler.player.currentIndex) return failure('bad_request');
          if (index < 0) return failure('queue_changed');
          await handler.removeQueueItemAt(index);
          return success();
        case 'move_queue':
          final from = _int(args['from']);
          final to = _int(args['to']);
          final count = handler.tracks.length;
          if (from == null || to == null || from < 0 || to < 0 || from >= count || to >= count) {
            return failure('bad_request');
          }
          // Verschieben nur, wenn dort noch der gemeinte Titel steht (kein Raten bei Ziehen und Ablegen)
          final expected = _int(args['track_id']);
          if (expected != null && handler.tracks[from].id != expected) return failure('queue_changed');
          await handler.moveQueueItem(from, to);
          return success();
        case 'clear_upcoming':
          await handler.clearUpcoming();
          return success();
        default:
          return failure('unsupported');
      }
    } on StateError catch (e) {
      return _fromStateError(e);
    } catch (_) {
      return failure('failed');
    }
  }

  /// Index in der eigenen (vollen) Warteschlange für `skip_to`/`remove_queue`. null = ungültig, -1 = der gemeinte Titel
  /// ist nicht mehr da. Mit `track_id` wird geprüft, ob dort noch derselbe Titel steht – sonst gilt das nächstgelegene
  /// Vorkommen (z. B. zweimal schnell hintereinander entfernt: der zweite Index ist inzwischen um eins verrutscht).
  static int? _queueIndex(SelfifyAudioHandler handler, Map<String, dynamic> args) {
    final index = _int(args['index']);
    final tracks = handler.tracks;
    if (index == null || index < 0) return null;
    final expected = _int(args['track_id']);
    if (expected == null) return index < tracks.length ? index : null;
    if (index < tracks.length && tracks[index].id == expected) return index;
    for (var distance = 1; distance < tracks.length; distance++) {
      for (final candidate in [index - distance, index + distance]) {
        if (candidate >= 0 && candidate < tracks.length && tracks[candidate].id == expected) return candidate;
      }
      if (index - distance < 0 && index + distance >= tracks.length) break;
    }
    return -1;
  }

  Map<String, Object?> _skipLimit() =>
      failure('skip_limit', skipLimitMessage(ref.read(premiumAccessProvider).config.freeSkipsPerHour));

  Map<String, Object?> _fromStateError(StateError error) {
    final text = error.message;
    if (text == offlineUnavailableMessage) return failure('offline_unavailable');
    if (text == windowsPlaybackMessage) return failure('cannot_play');
    return failure('failed');
  }

  /// Warteschlange von einem anderen Gerät übernehmen (`take_over`).
  Future<Map<String, Object?>> _takeOver(Map<String, dynamic> args) async {
    var tracks = parseTracks(args['tracks']);
    if (tracks.isEmpty) return failure('bad_request');
    var index = (_int(args['index']) ?? 0).clamp(0, tracks.length - 1);
    var position = Duration(milliseconds: max(0, _int(args['position_ms']) ?? 0));
    final shuffle = args['shuffle'] == true;
    List<int>? order = args['shuffle_order'] is List
        ? [
            for (final i in args['shuffle_order'] as List)
              if (i is num) i.toInt(),
          ]
        : null;
    if (_offlineOnly) {
      // Offline-Modus: nur, was auf diesem Gerät liegt (wie beim Abspielen)
      final offline = ref.read(offlineProvider);
      final keep = [
        for (var i = 0; i < tracks.length; i++)
          if (offline.isDownloaded(tracks[i].id)) i,
      ];
      if (keep.isEmpty) return failure('offline_unavailable');
      if (!keep.contains(index)) position = Duration.zero;
      final before = keep.where((i) => i < index).length;
      final newIndex = {for (var n = 0; n < keep.length; n++) keep[n]: n};
      tracks = [for (final i in keep) tracks[i]];
      index = before < tracks.length ? before : 0;
      order = order == null
          ? null
          : [
              for (final i in order) ?newIndex[i],
            ];
    }
    if (windowsAudioError != null) return failure('cannot_play');
    final handler = _handler;
    await handler.loadQueue(
      tracks,
      index: index,
      position: position,
      playing: args['playing'] != false,
      shuffle: shuffle,
      shuffleOrder: order,
      repeat: parseRepeat(args['repeat']),
      context: parsePlayContext(args['context']),
    );
    final volume = args['volume'];
    if (_canVolume && volume is num && volume >= 0 && volume <= 1) {
      await setPlayerVolume(ref.read(sharedPreferencesProvider), handler, volume.toDouble());
    }
    return success();
  }
}

final connectProvider = NotifierProvider<ConnectController, ConnectState>(ConnectController.new);
