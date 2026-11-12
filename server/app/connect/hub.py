"""Vermittlung zwischen den Geräten eines Kontos („Selfify Connect“).

Liegt nur im Speicher eines Prozesses: Der Server muss mit genau einem uvicorn-Prozess laufen (kein `--workers`),
sonst sähen sich Geräte in verschiedenen Prozessen nicht. Nach einem Neustart ist alles weg; die Geräte verbinden
sich neu und melden ihren Zustand wieder.

Alle Daten des Hubs werden nur in der Event-Loop verändert. Aus synchronen Routen (Threadpool) geht es über die
thread-sicheren Methoden `drop_session`, `drop_user`, `forget_user`, `rename`, `refresh_access`,
`refresh_visibility` (intern `call_soon_threadsafe`).

Der Server spielt nichts selbst ab: Er reicht Titel-Metadaten und Steuerbefehle weiter, das Zielgerät löst die
Quellen über die gewohnten Wege auf (Qualitätsdeckel, Offline-Dateien, Medien-Token usw. gelten dort automatisch).
"""

import asyncio
import contextlib
import itertools
import logging
import time
import uuid
from collections import OrderedDict, deque
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any

from fastapi.concurrency import run_in_threadpool

from app.connect import protocol as p
from app.connect.data import SessionFactory, visible_tracks

logger = logging.getLogger(__name__)

# Zeiten in Sekunden (Tests verkürzen sie per monkeypatch)
ACK_TIMEOUT = 8.0  # so lange wartet ein Befehl auf die Antwort des Zielgeräts
RELEASE_TIMEOUT = 3.0  # so lange wartet eine Übertragung auf den Stand der Quelle
ACTIVE_GRACE_SECONDS = 60.0  # das aktive Gerät bleibt nach einem Abbruch so lange aktiv (Netzwechsel)
LAST_STATE_KEEP_SECONDS = 30 * 60.0  # „Auf PC weiterhören“ geht auch nach einem Abbruch noch so lange
RESULT_KEEP_SECONDS = 60.0  # beantwortete Befehls-IDs: doppelte bekommen das gespeicherte Ergebnis
STOP_ACTIONS = ("pause", "release")  # nach der Bestätigung spielt das Gerät nicht mehr
MAX_STOP_IDS = 50  # so viele offene „pause“/„release“ je Verbindung werden gemerkt

# Ratenbegrenzung je Verbindung
CMD_RATE, CMD_BURST = 10.0, 20
STATE_RATE, STATE_BURST = 4.0, 4
MESSAGE_LIMIT, MESSAGE_WINDOW = 200, 10.0
OUTBOX_LIMIT = 500

UNNAMED_DEVICE = "Unbenanntes Gerät"


class TokenBucket:
    """Einfacher Token-Bucket mit monotoner Uhr."""

    def __init__(self, rate: float, burst: int) -> None:
        self.rate = rate
        self.burst = float(burst)
        self.tokens = float(burst)
        self.stamp = time.monotonic()

    def take(self) -> bool:
        now = time.monotonic()
        self.tokens = min(self.burst, self.tokens + (now - self.stamp) * self.rate)
        self.stamp = now
        if self.tokens >= 1:
            self.tokens -= 1
            return True
        return False


class SlidingWindow:
    """Zählt Ereignisse der letzten `seconds` Sekunden; False, sobald mehr als `limit` darin liegen."""

    def __init__(self, limit: int, seconds: float) -> None:
        self.limit = limit
        self.seconds = seconds
        self.hits: deque[float] = deque()

    def hit(self) -> bool:
        now = time.monotonic()
        while self.hits and now - self.hits[0] > self.seconds:
            self.hits.popleft()
        self.hits.append(now)
        return len(self.hits) <= self.limit


# Sonderzeichen in der Ausgangs-Warteschlange einer Verbindung
CLOSE = object()  # Verbindung schließen (Code und Grund stehen an der Verbindung)
CHECK = object()  # Anmeldung und Premium sofort neu prüfen


@dataclass(eq=False)
class Connection:
    """Eine WebSocket-Verbindung = ein Gerät (eine Sitzung)."""

    user_id: int
    session_id: int
    name: str
    allowed: bool
    # Wann das Konto angelegt wurde – unterscheidet ein neues Konto mit wiederverwendeter Benutzer-ID vom alten
    user_created: Any = None
    outbox: asyncio.Queue[Any] = field(default_factory=lambda: asyncio.Queue(maxsize=OUTBOX_LIMIT + 1))
    ready: bool = False  # `hello` abgeschlossen
    kind: str = "phone"
    platform: str = ""
    caps: dict[str, bool] = field(default_factory=lambda: {"volume": False, "play": True})
    seq: int = -1
    # Zuletzt gemeldet: spielt das Gerät? Nur der Wechsel „pausiert -> spielt“ zählt als Play-Druck (siehe `state`)
    playing: bool = False
    # IDs der an dieses Gerät geschickten „pause“/„release“, deren Bestätigung noch aussteht
    stop_ids: OrderedDict[str, None] = field(default_factory=OrderedDict)
    close_code: int | None = None
    close_reason: str = ""
    cmd_bucket: TokenBucket = field(default_factory=lambda: TokenBucket(CMD_RATE, CMD_BURST))
    state_bucket: TokenBucket = field(default_factory=lambda: TokenBucket(STATE_RATE, STATE_BURST))
    window: SlidingWindow = field(default_factory=lambda: SlidingWindow(MESSAGE_LIMIT, MESSAGE_WINDOW))
    running: set[str] = field(default_factory=set)
    answered: OrderedDict[str, tuple[float, dict[str, Any]]] = field(default_factory=OrderedDict)
    commands: asyncio.Queue[tuple[str, "Connection", str, dict[str, Any]]] = field(default_factory=asyncio.Queue)
    worker: asyncio.Task[None] | None = None

    @property
    def closing(self) -> bool:
        return self.close_code is not None

    def send(self, message: Any) -> None:
        if self.closing:
            return
        if self.outbox.qsize() >= OUTBOX_LIMIT and message is not CLOSE:
            # Gerät liest nicht mehr mit – lieber neu verbinden lassen als Nachrichten still zu verlieren
            logger.warning("Gerät %s liest nicht mehr mit – Verbindung wird geschlossen", self.session_id)
            self.close(p.CLOSE_IDLE)
            return
        self.outbox.put_nowait(message)

    def close(self, code: int, reason: str | None = None) -> None:
        if self.closing:
            return
        self.close_code = code
        self.close_reason = reason if reason is not None else p.CLOSE_REASONS.get(code, "")
        while not self.outbox.empty():
            self.outbox.get_nowait()
        self.outbox.put_nowait(CLOSE)


@dataclass(eq=False)
class Account:
    """Was der Hub je Konto führt: verbundene Geräte, aktives Gerät, letzter Stand."""

    user_id: int
    user_created: Any = None
    devices: dict[int, Connection] = field(default_factory=dict)
    active_id: int | None = None
    last_state: dict[str, Any] | None = None
    last_state_at: float = 0.0
    queue_key: tuple[Any, ...] | None = None
    queue_rev: int = 0
    # (queue_rev, track, upcoming) – nur bei geänderter Warteschlange neu aus der Datenbank
    cache: tuple[int, dict[str, Any] | None, list[dict[str, Any]]] | None = None
    transfer_lock: asyncio.Lock = field(default_factory=asyncio.Lock)
    grace: asyncio.TimerHandle | None = None
    expiry: asyncio.TimerHandle | None = None

    def ready(self) -> list[Connection]:
        return [c for c in self.devices.values() if c.ready and not c.closing]

    def device(self, session_id: int | None) -> Connection | None:
        conn = self.devices.get(session_id) if session_id is not None else None
        return conn if conn is not None and conn.ready and not conn.closing else None


def _extrapolated(st: dict[str, Any], received_at: float, now: float | None = None) -> int:
    """Position auf jetzt hochgerechnet (nur während der Wiedergabe)."""
    position = int(st["position_ms"])
    if st.get("playing"):
        elapsed = max(0.0, (now if now is not None else time.monotonic()) - received_at)
        position += int(elapsed * 1000 * float(st.get("speed") or 1.0))
        if st.get("duration_ms"):
            position = min(position, int(st["duration_ms"]))
    return position


def _ack(message: dict[str, Any]) -> dict[str, Any]:
    """Antwort eines Zielgeräts bereinigen (unbekannte Felder fallen weg)."""
    ok = message.get("ok")
    if not isinstance(ok, bool):
        return p.error("failed")
    out: dict[str, Any] = {"ok": ok}
    code, text = message.get("code"), message.get("message")
    if isinstance(code, str) and code:
        out["code"] = code[:64]
    if isinstance(text, str) and text:
        out["message"] = text[:500]
    if not ok and "code" not in out:
        out["code"] = "failed"
    if "snapshot" in message:
        out["snapshot"] = message["snapshot"]
    return out


class ConnectHub:
    def __init__(self, session_factory: SessionFactory | None = None) -> None:
        self.session_factory = session_factory
        self._accounts: dict[int, Account] = {}
        self._loop: asyncio.AbstractEventLoop | None = None
        self._pending: dict[tuple[Connection, str], asyncio.Future[dict[str, Any]]] = {}
        # Server-Befehle heißen „srv-<Prozess>-<n>“: Die Apps merken sich ausgeführte IDs, nach einem Neustart darf
        # „srv-1“ deshalb nicht wieder auftauchen (sonst hielten sie den neuen Befehl für einen doppelten)
        self._server_prefix = f"srv-{uuid.uuid4().hex[:8]}"
        self._server_ids = itertools.count(1)
        self._tasks: set[asyncio.Task[Any]] = set()

    # ------------------------------------------------------------------ thread-sichere Schnittstelle

    def _call(self, fn: Callable[..., None], *args: Any) -> None:
        loop = self._loop
        if loop is None or loop.is_closed():
            return
        with contextlib.suppress(RuntimeError):  # Event-Loop beendet
            loop.call_soon_threadsafe(fn, *args)

    def drop_session(self, session_id: int, code: int = p.CLOSE_UNAUTHORIZED) -> None:
        """Verbindung dieses Geräts sofort schließen (z. B. nach Abmelden)."""
        self._call(self._drop_session, session_id, code)

    def drop_user(self, user_id: int, code: int = p.CLOSE_UNAUTHORIZED, except_session_id: int | None = None) -> None:
        """Alle Verbindungen eines Kontos sofort schließen (außer except_session_id)."""
        self._call(self._drop_user, user_id, code, except_session_id)

    def forget_user(self, user_id: int) -> None:
        """Konto gelöscht: Verbindungen schließen und alles vergessen (aktives Gerät, letzter Stand).

        SQLite vergibt freie IDs neu – ein später angelegtes Konto darf den Stand des gelöschten nie sehen."""
        self._call(self._forget_user, user_id)

    def rename(self, user_id: int, session_id: int, name: str) -> None:
        """Neuer Gerätename – verteilt die neue Geräteliste."""
        self._call(self._rename, user_id, session_id, name)

    def refresh_access(self, user_id: int) -> None:
        """Premium-Zugang der Verbindungen dieses Kontos sofort neu prüfen."""
        self._call(self._refresh, user_id)

    def refresh_visibility(self, user_id: int) -> None:
        """Sichtbarkeit des Kontos geändert (Rubriken, Admin): Titelangaben neu laden und verteilen, Zugang prüfen."""
        self._call(self._refresh_visibility, user_id)

    def refresh_all(self) -> None:
        """Premium-Zugang aller Verbindungen neu prüfen (z. B. nach Änderung der Einstellungen)."""
        self._call(self._refresh, None)

    def close_all(self, code: int = p.CLOSE_SHUTDOWN) -> None:
        """Beim Herunterfahren (in der Event-Loop aufgerufen)."""
        for account in list(self._accounts.values()):
            for conn in list(account.devices.values()):
                conn.close(code)

    @property
    def connection_count(self) -> int:
        return sum(len(a.devices) for a in self._accounts.values())

    def _drop_session(self, session_id: int, code: int) -> None:
        for account in self._accounts.values():
            conn = account.devices.get(session_id)
            if conn is not None:
                conn.close(code)

    def _drop_user(self, user_id: int, code: int, except_session_id: int | None) -> None:
        account = self._accounts.get(user_id)
        if account is None:
            return
        for conn in list(account.devices.values()):
            if conn.session_id != except_session_id:
                conn.close(code)

    def _forget_user(self, user_id: int) -> None:
        account = self._accounts.get(user_id)
        if account is not None:
            self._discard(account)

    def _discard(self, account: Account) -> None:
        """Konto-Eintrag ganz entfernen: Verbindungen zu, Zeitgeber aus, Stand weg."""
        for conn in list(account.devices.values()):
            conn.close(p.CLOSE_UNAUTHORIZED)
            self._forget(account, conn)
        for timer in (account.grace, account.expiry):
            if timer is not None:
                timer.cancel()
        account.grace = account.expiry = None
        account.active_id = None
        account.last_state = None
        account.cache = None
        if self._accounts.get(account.user_id) is account:
            del self._accounts[account.user_id]

    def _rename(self, user_id: int, session_id: int, name: str) -> None:
        account = self._accounts.get(user_id)
        conn = account.devices.get(session_id) if account else None
        if account is None or conn is None:
            return
        conn.name = name
        self._broadcast_devices(account)

    def _refresh(self, user_id: int | None) -> None:
        accounts = self._accounts.values() if user_id is None else [self._accounts.get(user_id)]
        for account in accounts:
            for conn in account.devices.values() if account else ():
                conn.send(CHECK)

    def _refresh_visibility(self, user_id: int) -> None:
        account = self._accounts.get(user_id)
        if account is None:
            return
        # Zwischengespeicherte Titel (aktueller, kommende) gelten nicht mehr – neu aus der Datenbank, neue queue_rev
        account.cache = None
        account.queue_rev += 1
        self._refresh(user_id)
        if account.active_id is not None:
            self._spawn(self._broadcast_state(account, account.device(account.active_id)))

    # ------------------------------------------------------------------ An- und Abmelden von Verbindungen

    def attach(self, conn: Connection) -> bool:
        """Neue Verbindung eintragen. False = zu viele Geräte verbunden (Aufrufer schließt mit 4429)."""
        self._loop = asyncio.get_running_loop()
        account = self._accounts.get(conn.user_id)
        if account is not None and account.user_created != conn.user_created:
            # Gleiche Benutzer-ID, anderes Konto (gelöscht und neu angelegt): nichts vom alten übernehmen
            self._discard(account)
            account = None
        if account is None:
            account = Account(conn.user_id, user_created=conn.user_created)
            self._accounts[conn.user_id] = account
        old = account.devices.get(conn.session_id)
        others = [c for c in account.devices.values() if c is not old]
        if len(others) >= p.MAX_DEVICES:
            return False
        if old is not None:
            # Eine Verbindung je Gerät: die neue ersetzt die alte
            old.close(p.CLOSE_REPLACED)
            self._forget(account, old)
        account.devices[conn.session_id] = conn
        if account.grace is not None and account.active_id == conn.session_id:
            account.grace.cancel()
            account.grace = None
        if account.expiry is not None:
            account.expiry.cancel()
            account.expiry = None
        return True

    def detach(self, conn: Connection) -> None:
        """Verbindung beendet (aus dem finally des Endpunkts)."""
        account = self._accounts.get(conn.user_id)
        if account is None or account.devices.get(conn.session_id) is not conn:
            # schon ersetzt – offene Befehle an diese Verbindung trotzdem beenden
            self._fail_pending(conn)
            if conn.worker is not None:
                conn.worker.cancel()
            return
        was_ready = conn.ready
        self._forget(account, conn)
        if was_ready and account.active_id == conn.session_id and self._loop is not None:
            account.grace = self._loop.call_later(ACTIVE_GRACE_SECONDS, self._grace_over, account, conn.session_id)
        if was_ready:
            self._broadcast_devices(account)
        self._maybe_drop_account(account)

    def _forget(self, account: Account, conn: Connection) -> None:
        if account.devices.get(conn.session_id) is conn:
            del account.devices[conn.session_id]
        self._fail_pending(conn)
        if conn.worker is not None:
            conn.worker.cancel()
            conn.worker = None

    def _fail_pending(self, conn: Connection) -> None:
        for key in [k for k in self._pending if k[0] is conn]:
            future = self._pending.pop(key)
            if not future.done():
                future.set_result(p.error("offline"))

    def _grace_over(self, account: Account, session_id: int) -> None:
        account.grace = None
        if account.active_id != session_id or account.device(session_id) is not None:
            return
        account.active_id = None
        if account.last_state is not None:
            # Stand behalten (pausiert), damit „Auf diesem Gerät weiterhören“ noch geht
            now = time.monotonic()
            frozen = dict(account.last_state)
            frozen["position_ms"] = _extrapolated(account.last_state, account.last_state_at, now)
            frozen["playing"] = False
            account.last_state, account.last_state_at = frozen, now
        self._broadcast_devices(account)
        self._maybe_drop_account(account)

    def _maybe_drop_account(self, account: Account) -> None:
        if account.devices or account.grace is not None:
            return
        if account.last_state is not None and self._loop is not None:
            if account.expiry is None:
                account.expiry = self._loop.call_later(LAST_STATE_KEEP_SECONDS, self._expire, account)
            return
        if self._accounts.get(account.user_id) is account:
            del self._accounts[account.user_id]

    def _expire(self, account: Account) -> None:
        account.expiry = None
        if account.devices:
            return
        account.last_state = None
        self._maybe_drop_account(account)

    def account(self, user_id: int) -> Account | None:
        return self._accounts.get(user_id)

    # ------------------------------------------------------------------ Geräteliste und Zustand

    def _device_list(self, account: Account, viewer: Connection) -> list[dict[str, Any]]:
        items = [
            {
                "id": c.session_id,
                "name": c.name or UNNAMED_DEVICE,
                "kind": c.kind,
                "platform": c.platform,
                "caps": dict(c.caps),
                "is_self": c is viewer,
                "is_active": c.session_id == account.active_id,
            }
            for c in account.ready()
        ]
        items.sort(key=lambda d: (not d["is_active"], not d["is_self"], str(d["name"]).casefold(), d["id"]))
        return items

    def _devices_message(self, account: Account, viewer: Connection) -> dict[str, Any]:
        return {
            "type": "devices",
            "devices": self._device_list(account, viewer),
            "active_device_id": account.active_id,
        }

    def _broadcast_devices(self, account: Account) -> None:
        for conn in account.ready():
            conn.send(self._devices_message(account, conn))

    def _current_state(self, account: Account) -> dict[str, Any] | None:
        if account.last_state is None:
            return None
        if account.active_id is None and time.monotonic() - account.last_state_at > LAST_STATE_KEEP_SECONDS:
            account.last_state = None
            return None
        return account.last_state

    def _set_last_state(self, account: Account, st: dict[str, Any]) -> None:
        st = {k: v for k, v in st.items() if k != "seq"}
        key = (account.active_id, tuple(st["queue_ids"]), st["index"], st["shuffle"], tuple(st["shuffle_order"] or ()))
        if key != account.queue_key:
            account.queue_key = key
            account.queue_rev += 1
            account.cache = None
        account.last_state = st
        account.last_state_at = time.monotonic()

    async def remote_state(self, account: Account) -> dict[str, Any] | None:
        """`RemoteState` des aktiven (bzw. zuletzt aktiven) Geräts für die steuernden Geräte."""
        st = self._current_state(account)
        if st is None:
            return None
        received_at = account.last_state_at
        rev = account.queue_rev
        cache = account.cache
        if cache is None or cache[0] != rev:
            index = st["index"]
            current = st["queue_ids"][index] if index is not None else None
            upcoming = p.upcoming_ids(st)
            wanted = ([current] if current is not None else []) + upcoming
            tracks = await run_in_threadpool(visible_tracks, self.session_factory, account.user_id, wanted)
            visible_upcoming = [tracks[i] for i in upcoming if i in tracks][: p.MAX_UPCOMING]
            cache = (rev, tracks.get(current) if current is not None else None, visible_upcoming)
            if account.queue_rev == rev:
                account.cache = cache
        out = dict(st)
        out["position_ms"] = _extrapolated(st, received_at)
        out["track"] = cache[1]
        out["upcoming"] = cache[2]
        out["queue_rev"] = rev
        return out

    async def _broadcast_state(self, account: Account, exclude: Connection | None) -> None:
        targets = [c for c in account.ready() if c is not exclude and c.allowed]
        if not targets or account.active_id is None:
            return
        remote = await self.remote_state(account)
        if remote is None:
            return
        message = {"type": "state", "device_id": account.active_id, "state": remote}
        for conn in targets:
            conn.send(message)

    def _make_active(self, account: Account, conn: Connection) -> None:
        """`conn` wird aktives Gerät. Spielte das bisherige, bekommt es „pause“ („wer zuletzt Play drückt, gewinnt“)."""
        previous = account.device(account.active_id)
        if previous is not None and previous is not conn and account.last_state and account.last_state["playing"]:
            self._server_exec(previous, "pause")
        account.active_id = conn.session_id
        if account.grace is not None:
            account.grace.cancel()
            account.grace = None
        account.last_state = None
        account.queue_key = None

    def _server_exec(self, target: Connection, action: str) -> None:
        """Befehl vom Server selbst (from = null). Die Antwort wird nur geloggt."""
        exec_id = f"{self._server_prefix}-{next(self._server_ids)}"
        future = self._send_exec(target, exec_id, None, action, {})
        self._spawn(self._log_server_ack(target, exec_id, future))

    async def _log_server_ack(self, target: Connection, exec_id: str, future: asyncio.Future[dict[str, Any]]) -> None:
        try:
            ack = await asyncio.wait_for(future, ACK_TIMEOUT)
            if not ack.get("ok"):
                logger.info("Gerät %s: Server-Befehl %s abgelehnt (%s)", target.session_id, exec_id, ack.get("code"))
        except TimeoutError:
            logger.info("Gerät %s: keine Antwort auf Server-Befehl %s", target.session_id, exec_id)
        finally:
            self._pending.pop((target, exec_id), None)

    def _spawn(self, coro: Any) -> None:
        task = asyncio.get_running_loop().create_task(coro)
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    # ------------------------------------------------------------------ Nachrichten der App

    async def hello(self, conn: Connection, info: dict[str, Any]) -> None:
        account = self._accounts.get(conn.user_id)
        if account is None or account.devices.get(conn.session_id) is not conn:
            return
        conn.kind, conn.platform, conn.caps = info["kind"], info["platform"], info["caps"]
        conn.playing = info["playing"]
        conn.ready = True
        conn.worker = asyncio.get_running_loop().create_task(self._command_worker(conn))
        if info["playing"] and conn.allowed and account.active_id != conn.session_id:
            self._make_active(account, conn)
        remote = await self.remote_state(account) if conn.allowed else None
        conn.send(
            {
                "type": "welcome",
                "protocol": p.PROTOCOL_VERSION,
                "device_id": conn.session_id,
                "allowed": conn.allowed,
                "devices": self._device_list(account, conn),
                "active_device_id": account.active_id,
                "state": remote,
            }
        )
        for other in account.ready():
            if other is not conn:
                other.send(self._devices_message(account, other))

    async def state(self, conn: Connection, st: dict[str, Any]) -> None:
        """Zustand eines Geräts (schon geprüft und gedrosselt)."""
        if not conn.ready or st["seq"] <= conn.seq:
            return
        conn.seq = st["seq"]
        # Play-Druck ist nur der Wechsel „pausiert -> spielt“. Ein Stand mit playing=true, der schon unterwegs war,
        # als der Server dieses Gerät angehalten hat (Herzschlag, entprellter Stand), holt die Wiedergabe sonst
        # zurück – und am Ende spielt keines. Bis zur Bestätigung von „pause“/„release“ gilt das Gerät als spielend.
        claim = st["playing"] and not conn.playing
        conn.playing = st["playing"]
        account = self._accounts.get(conn.user_id)
        # Ohne Premium-Zugang führt der Server kein aktives Gerät: jedes Gerät spielt für sich
        if account is None or not conn.allowed:
            return
        became_active = False
        if claim and account.active_id != conn.session_id:
            self._make_active(account, conn)
            became_active = True
        if account.active_id != conn.session_id:
            return
        self._set_last_state(account, st)
        if became_active:
            self._broadcast_devices(account)
        await self._broadcast_state(account, conn)

    def ack(self, conn: Connection, message: dict[str, Any]) -> None:
        exec_id = message.get("id")
        if not isinstance(exec_id, str):
            return
        if exec_id in conn.stop_ids:
            # „pause“/„release“ ausgeführt (auch verspätet): Ab jetzt ist ein playing=true wieder ein Play-Druck
            del conn.stop_ids[exec_id]
            if message.get("ok") is True:
                conn.playing = False
        future = self._pending.pop((conn, exec_id), None)
        if future is not None and not future.done():
            future.set_result(_ack(message))

    def set_allowed(self, conn: Connection, allowed: bool) -> None:
        if conn.allowed != allowed:
            conn.allowed = allowed
            if allowed:
                # Was vorher ohne Zugang lief, zählt beim nächsten Stand als Play-Druck
                conn.playing = False
            if conn.ready:
                conn.send({"type": "access", "allowed": allowed})

    # ------------------------------------------------------------------ Befehle

    def _reply(self, conn: Connection, cmd_id: str, result: dict[str, Any], remember: bool = True) -> None:
        message = {"type": "result", "id": cmd_id, **{k: v for k, v in result.items() if k != "snapshot"}}
        conn.running.discard(cmd_id)
        if remember:
            conn.answered[cmd_id] = (time.monotonic(), message)
            conn.answered.move_to_end(cmd_id)
            while len(conn.answered) > p.MAX_REMEMBERED_RESULTS:
                conn.answered.popitem(last=False)
        conn.send(message)

    def command(self, conn: Connection, message: dict[str, Any]) -> None:
        """`cmd` annehmen: Prüfungen in fester Reihenfolge, dann an den Arbeiter der Verbindung (Reihenfolge bleibt)."""
        raw_id = message.get("id")
        try:
            cmd_id = p.command_id(raw_id)
        except p.Invalid:
            conn.send({"type": "result", "id": raw_id[: p.MAX_ID] if isinstance(raw_id, str) else "",
                       **p.error("bad_request")})  # fmt: skip
            return
        # Doppelte ID: läuft noch -> ignorieren; schon beantwortet -> gleiches Ergebnis erneut, nicht neu ausführen
        if cmd_id in conn.running:
            return
        stored = conn.answered.get(cmd_id)
        if stored is not None:
            if time.monotonic() - stored[0] <= RESULT_KEEP_SECONDS:
                conn.send(stored[1])
                return
            del conn.answered[cmd_id]
        target_id, action = message.get("target"), message.get("action")
        try:
            if not p.is_int(target_id) or action not in p.ACTIONS:
                raise p.Invalid
            args = p.command_args(action, message.get("args"))
        except p.Invalid:
            self._reply(conn, cmd_id, p.error("bad_request"))
            return
        if not conn.cmd_bucket.take():
            self._reply(conn, cmd_id, p.error("rate_limited"), remember=False)
            return
        if len(conn.running) >= p.MAX_OPEN_COMMANDS:
            self._reply(conn, cmd_id, p.error("busy"), remember=False)
            return
        if not conn.allowed:
            self._reply(conn, cmd_id, p.error("premium"))
            return
        account = self._accounts.get(conn.user_id)
        # Nur Geräte desselben Kontos; fremde und unbekannte IDs bekommen dieselbe Antwort
        target = account.device(target_id) if account is not None else None
        if account is None or target is None:
            self._reply(conn, cmd_id, p.error("unknown_device"))
            return
        if target is conn and action != "transfer":
            # eigene Befehle führt die App selbst aus
            self._reply(conn, cmd_id, p.error("bad_request"))
            return
        if not target.caps["play"] or (action == "set_volume" and not target.caps["volume"]):
            self._reply(conn, cmd_id, p.error("unsupported"))
            return
        conn.running.add(cmd_id)
        if action == "transfer":
            self._spawn(self._transfer(account, conn, cmd_id, target, args))
        else:
            conn.commands.put_nowait((cmd_id, target, action, args))

    async def _command_worker(self, conn: Connection) -> None:
        """Leitet die Befehle eines Absenders in Eingangsreihenfolge weiter (Titel-Prüfung im Threadpool)."""
        while True:
            cmd_id, target, action, args = await conn.commands.get()
            try:
                exec_args = args
                if action in p.TRACK_ACTIONS:
                    visible = await run_in_threadpool(
                        visible_tracks, self.session_factory, conn.user_id, args["track_ids"]
                    )
                    kept = [(pos, tid) for pos, tid in enumerate(args["track_ids"]) if tid in visible]
                    if not kept:
                        self._reply(conn, cmd_id, p.error("not_found"))
                        continue
                    tracks = [visible[tid] for _, tid in kept]
                    if action == "play":
                        positions = [pos for pos, _ in kept]
                        index = positions.index(args["index"]) if args["index"] in positions else 0
                        exec_args = {"tracks": tracks, "index": index, "shuffle": args["shuffle"],
                                     "context": args["context"]}  # fmt: skip
                    else:
                        exec_args = {"tracks": tracks}
                if not self._attached(target):
                    self._reply(conn, cmd_id, p.error("offline"))
                    continue
                exec_id = f"{conn.session_id}:{cmd_id}"
                future = self._send_exec(target, exec_id, conn.session_id, action, exec_args)
                self._spawn(self._await_result(conn, cmd_id, target, exec_id, future))
            except Exception:
                logger.exception("Befehl %s konnte nicht weitergeleitet werden", action)
                self._reply(conn, cmd_id, p.error("failed"))

    def _attached(self, conn: Connection) -> bool:
        account = self._accounts.get(conn.user_id)
        return account is not None and account.device(conn.session_id) is conn

    def _send_exec(
        self, target: Connection, exec_id: str, sender: int | None, action: str, args: dict[str, Any]
    ) -> asyncio.Future[dict[str, Any]]:
        future: asyncio.Future[dict[str, Any]] = asyncio.get_running_loop().create_future()
        previous = self._pending.pop((target, exec_id), None)
        if previous is not None and not previous.done():
            previous.set_result(p.error("failed"))
        self._pending[(target, exec_id)] = future
        if action in STOP_ACTIONS:
            target.stop_ids[exec_id] = None
            while len(target.stop_ids) > MAX_STOP_IDS:
                target.stop_ids.popitem(last=False)
        target.send({"type": "exec", "id": exec_id, "from": sender, "action": action, "args": args})
        return future

    async def _wait_ack(
        self, target: Connection, exec_id: str, future: asyncio.Future[dict[str, Any]], timeout: float
    ) -> dict[str, Any] | None:
        """Antwort des Zielgeräts oder None nach Ablauf der Zeit."""
        try:
            return await asyncio.wait_for(future, timeout)
        except TimeoutError:
            return None
        finally:
            if self._pending.get((target, exec_id)) is future:
                del self._pending[(target, exec_id)]

    async def _await_result(
        self, conn: Connection, cmd_id: str, target: Connection, exec_id: str, future: asyncio.Future[dict[str, Any]]
    ) -> None:
        ack = await self._wait_ack(target, exec_id, future, ACK_TIMEOUT)
        self._reply(conn, cmd_id, ack if ack is not None else p.error("timeout"))

    # ------------------------------------------------------------------ Übertragen

    async def _transfer(
        self, account: Account, conn: Connection, cmd_id: str, target: Connection, args: dict[str, Any]
    ) -> None:
        if account.transfer_lock.locked():
            self._reply(conn, cmd_id, p.error("busy"), remember=False)
            return
        async with account.transfer_lock:
            try:
                result = await self._do_transfer(account, conn, cmd_id, target, args)
            except Exception:
                logger.exception("Übertragung fehlgeschlagen")
                result = p.error("failed")
        self._reply(conn, cmd_id, result)

    async def _do_transfer(
        self, account: Account, conn: Connection, cmd_id: str, target: Connection, args: dict[str, Any]
    ) -> dict[str, Any]:
        if account.active_id == target.session_id:
            return {"ok": True}
        source = account.device(account.active_id)
        snapshot: dict[str, Any] | None = None
        released = False
        source_playing = False
        if source is not None:
            # 1. Quelle anhalten und ihren genauen Stand holen
            exec_id = f"{conn.session_id}:{cmd_id}:release"
            future = self._send_exec(source, exec_id, conn.session_id, "release", {})
            ack = await self._wait_ack(source, exec_id, future, RELEASE_TIMEOUT)
            if ack is not None and ack.get("ok"):
                released = True
                try:
                    snapshot = p.state(ack.get("snapshot"), need_seq=False)
                except p.Invalid:
                    snapshot = None
        last = self._current_state(account)
        if snapshot is None and last is not None:
            # keine (brauchbare) Antwort: letzter bekannter Stand, Position hochgerechnet
            snapshot = dict(last)
            snapshot["position_ms"] = _extrapolated(last, account.last_state_at)
        if snapshot is None:
            return p.error("nothing_playing")
        source_playing = bool(snapshot["playing"])

        def fall_back() -> None:
            # Quelle spielte vorher -> sie spielt weiter (Rückfall)
            if released and source_playing and source is not None and self._attached(source):
                self._server_exec(source, "resume")

        # 2. Titel auf Sichtbarkeit prüfen (frisch aus der Datenbank)
        visible = await run_in_threadpool(
            visible_tracks, self.session_factory, conn.user_id, snapshot["queue_ids"]
        )
        ids, index, order, kept_current = p.filter_queue(snapshot, set(visible))
        if not ids:
            fall_back()
            return p.error("not_found")
        playing = args.get("play", source_playing)
        take_over = {
            "tracks": [visible[i] for i in ids],
            "index": index,
            "position_ms": snapshot["position_ms"] if kept_current else 0,
            "playing": playing,
            "shuffle": snapshot["shuffle"],
            "shuffle_order": order,
            "repeat": snapshot["repeat"],
            "context": snapshot["context"],
            "volume": snapshot["volume"],
        }
        if not self._attached(target):
            fall_back()
            return p.error("offline")
        # 3. Ziel übernimmt
        exec_id = f"{conn.session_id}:{cmd_id}"
        future = self._send_exec(target, exec_id, conn.session_id, "take_over", take_over)
        ack = await self._wait_ack(target, exec_id, future, ACK_TIMEOUT)
        if ack is None:
            fall_back()
            return p.error("timeout")
        if not ack.get("ok"):
            fall_back()
            return ack
        # 4. Ziel ist jetzt aktiv; es meldet seinen Zustand anschließend selbst
        account.active_id = target.session_id
        if account.grace is not None:
            account.grace.cancel()
            account.grace = None
        self._set_last_state(
            account,
            {**snapshot, "queue_ids": ids, "index": index, "shuffle_order": order, "playing": playing,
             "position_ms": take_over["position_ms"], "queue_offset": 0},
        )  # fmt: skip
        self._broadcast_devices(account)
        # Vorläufigen Stand gleich mitschicken – sonst stünde das abgebende Gerät ohne Titel da (Mini-Player weg,
        # Vollbild-Player schließt sich), bis das Ziel seinen ersten Stand meldet
        await self._broadcast_state(account, target)
        return {"ok": True}


def hub_of(app: Any) -> ConnectHub | None:
    """Der Hub der App – fehlt er (z. B. in Tests ohne lifespan), passiert nichts."""
    return getattr(getattr(app, "state", None), "connect_hub", None)
