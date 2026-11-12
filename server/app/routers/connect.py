"""Wiedergabe auf anderen Geräten („Selfify Connect“): eine WebSocket-Verbindung je App-Gerät.

Ablauf und Nachrichten: siehe app/connect/protocol.py und app/connect/hub.py. Kurz:
Anmeldung über den Header `Authorization: Bearer <access_token>` (ersatzweise `?token=`), danach `hello` innerhalb
von 10 s. Die Anmeldung wird alle 25 s neu geprüft; ein abgemeldetes Gerät fliegt sofort hinaus (Hub).
"""

import asyncio
import json
import logging
import time
from typing import Any

from fastapi import APIRouter, WebSocket
from fastapi.concurrency import run_in_threadpool
from starlette.websockets import WebSocketDisconnect

from app.connect import protocol as p
from app.connect.data import check_login
from app.connect.hub import CHECK, CLOSE, ConnectHub, Connection
from app.security import decode_access_token
from app.services.clients import CLIENT_HEADER, parse_client

logger = logging.getLogger(__name__)

router = APIRouter(tags=["Geräte"])

ACCESS_CHECK_SECONDS = 25.0  # Anmeldung und Premium-Zugang neu prüfen (Tests: 0 = bei jeder Nachricht)
HELLO_TIMEOUT = 10.0  # so lange wartet der Server nach dem Verbinden auf `hello`
PING_SECONDS = 25.0  # Server schickt `ping`, wenn er so lange nichts gesendet hat
IDLE_SECONDS = 70.0  # kommt so lange nichts von der App, wird geschlossen (4408)


def _token(websocket: WebSocket) -> str:
    header = websocket.headers.get("authorization", "")
    if header.lower().startswith("bearer "):
        return header[7:].strip()
    return websocket.query_params.get("token", "")


class _Session:
    """Eine laufende Verbindung: Empfang, Senden, Zeitgrenzen und Neuprüfung."""

    def __init__(self, websocket: WebSocket, hub: ConnectHub, conn: Connection, payload: dict[str, Any]) -> None:
        self.ws = websocket
        self.hub = hub
        self.conn = conn
        self.payload = payload
        self.client = parse_client(websocket.headers.get(CLIENT_HEADER))
        now = time.monotonic()
        self.started = now
        self.last_received = now
        self.last_sent = now
        self.last_check = now

    @property
    def expires_at(self) -> float:
        try:
            return float(self.payload.get("exp", 0))
        except (TypeError, ValueError):
            return 0.0

    async def check(self) -> None:
        """Anmeldung (Gerät, Konto) und Premium-Zugang neu prüfen."""
        self.last_check = time.monotonic()
        login = await run_in_threadpool(check_login, self.hub.session_factory, self.payload, self.client)
        if login is None or login.session_id != self.conn.session_id:
            self.conn.close(p.CLOSE_UNAUTHORIZED)
            return
        self.hub.set_allowed(self.conn, login.allowed)

    async def renew(self, message: dict[str, Any]) -> None:
        """Token-Erneuerung in der Verbindung: gleiches Konto, gleiches Gerät, später ablaufend."""
        token = message.get("token")
        payload = decode_access_token(self.ws.app.state.secret_key, token) if isinstance(token, str) else None
        if (
            payload is None
            or str(payload.get("sub")) != str(self.payload.get("sub"))
            or str(payload.get("sid")) != str(self.payload.get("sid"))
            or float(payload.get("exp", 0)) <= self.expires_at
        ):
            self.conn.close(p.CLOSE_UNAUTHORIZED)
            return
        previous = self.payload
        self.payload = payload
        await self.check()
        if self.conn.closing:
            self.payload = previous
            return
        self.conn.send({"type": "auth_ok"})

    def deadline(self) -> float:
        """Sekunden bis zur nächsten fälligen Zeitprüfung."""
        now = time.monotonic()
        moments = [
            self.last_sent + PING_SECONDS,
            self.last_received + IDLE_SECONDS,
            self.last_check + max(ACCESS_CHECK_SECONDS, 1.0),
            now + max(0.0, self.expires_at - time.time()),
        ]
        if not self.conn.ready:
            moments.append(self.started + HELLO_TIMEOUT)
        return max(0.0, min(moments) - now) + 0.01

    async def on_timer(self) -> None:
        now = time.monotonic()
        if not self.conn.ready and now - self.started >= HELLO_TIMEOUT:
            self.conn.close(p.CLOSE_INVALID, p.REASON_INVALID)
        elif now - self.last_received >= IDLE_SECONDS:
            self.conn.close(p.CLOSE_IDLE)
        elif time.time() >= self.expires_at:
            self.conn.close(p.CLOSE_RENEW)
        elif now - self.last_check >= ACCESS_CHECK_SECONDS:
            await self.check()
        if not self.conn.closing and time.monotonic() - self.last_sent >= PING_SECONDS:
            self.conn.send({"type": "ping"})

    async def on_text(self, text: str) -> None:
        conn = self.conn
        self.last_received = time.monotonic()
        if not conn.window.hit():
            conn.close(p.CLOSE_TOO_MANY, p.REASON_TOO_MANY_MESSAGES)
            return
        if len(text) > p.MAX_MESSAGE_BYTES or len(text.encode("utf-8", "surrogatepass")) > p.MAX_MESSAGE_BYTES:
            conn.close(p.CLOSE_INVALID, p.REASON_INVALID)
            return
        try:
            message = json.loads(text)
        except ValueError:
            message = None
        if not isinstance(message, dict):
            conn.close(p.CLOSE_INVALID, p.REASON_INVALID)
            return
        # Abgelaufene Anmeldung und fällige Neuprüfung vor jeder Nachricht (auch `ping` stößt sie an)
        kind = message.get("type")
        if kind != "auth":
            if time.time() >= self.expires_at:
                conn.close(p.CLOSE_RENEW)
                return
            if time.monotonic() - self.last_check >= ACCESS_CHECK_SECONDS:
                await self.check()
                if conn.closing:
                    return
        if not conn.ready:
            if kind == "hello":
                try:
                    info = p.hello(message)
                except p.Invalid as exc:
                    conn.close(p.CLOSE_INVALID, str(exc) or p.REASON_INVALID)
                    return
                await self.hub.hello(conn, info)
            elif kind == "auth":
                await self.renew(message)
            # alles andere vor `hello` wird ignoriert
            return
        if kind == "state":
            try:
                st = p.state(message.get("state"))
            except p.Invalid:
                return  # verwerfen, kein Close
            if conn.state_bucket.take():
                await self.hub.state(conn, st)
        elif kind == "cmd":
            self.hub.command(conn, message)
        elif kind == "ack":
            self.hub.ack(conn, message)
        elif kind == "auth":
            await self.renew(message)
        # ping, ein zweites hello und unbekannte Typen: ignorieren

    async def run(self) -> None:
        receiver: asyncio.Task[Any] = asyncio.create_task(self.ws.receive())
        getter: asyncio.Task[Any] | None = None
        try:
            while True:
                if getter is None:
                    getter = asyncio.create_task(self.conn.outbox.get())
                done, _ = await asyncio.wait({receiver, getter}, timeout=self.deadline(),
                                             return_when=asyncio.FIRST_COMPLETED)  # fmt: skip
                if getter in done:
                    item = getter.result()
                    getter = None
                    if item is CLOSE:
                        await self.ws.close(code=self.conn.close_code or p.CLOSE_NORMAL, reason=self.conn.close_reason)
                        return
                    if item is CHECK:
                        await self.check()
                        continue
                    await self.ws.send_text(json.dumps(item, ensure_ascii=False, separators=(",", ":")))
                    self.last_sent = time.monotonic()
                    continue
                if receiver in done:
                    message = receiver.result()
                    if message["type"] == "websocket.disconnect":
                        return
                    receiver = asyncio.create_task(self.ws.receive())
                    if message.get("text") is not None:
                        await self.on_text(message["text"])
                    else:
                        self.conn.close(p.CLOSE_INVALID, p.REASON_INVALID)  # Binärdaten gibt es im Protokoll nicht
                    continue
                await self.on_timer()
        finally:
            receiver.cancel()
            if getter is not None:
                getter.cancel()


@router.websocket("/connect/ws")
async def connect_ws(websocket: WebSocket) -> None:
    app = websocket.app
    hub: ConnectHub = app.state.connect_hub
    raw = _token(websocket)
    payload = decode_access_token(app.state.secret_key, raw) if raw else None
    login = None
    if payload is not None:
        client = parse_client(websocket.headers.get(CLIENT_HEADER))
        login = await run_in_threadpool(check_login, hub.session_factory, payload, client)
    # Erst annehmen, dann schließen: Ein Schließen vor dem Annehmen kommt bei der App als HTTP 403 an statt als 4401
    await websocket.accept()
    if payload is None or login is None:
        await websocket.close(code=p.CLOSE_UNAUTHORIZED, reason=p.REASON_UNAUTHORIZED)
        return
    conn = Connection(user_id=login.user_id, session_id=login.session_id, name=login.device_name, allowed=login.allowed,
                      user_created=login.user_created)  # fmt: skip
    if not hub.attach(conn):
        await websocket.close(code=p.CLOSE_TOO_MANY, reason=p.REASON_TOO_MANY_DEVICES)
        return
    session = _Session(websocket, hub, conn, payload)
    try:
        await session.run()
    except (WebSocketDisconnect, RuntimeError, OSError):
        pass  # Verbindung weg (z. B. beim Senden)
    except Exception:
        logger.exception("Geräte-Verbindung abgebrochen")
    finally:
        hub.detach(conn)
