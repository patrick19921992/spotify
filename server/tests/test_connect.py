"""Wiedergabe auf anderen Geräten („Selfify Connect“): WebSocket /api/connect/ws, Hub, Premium-Schalter „remote“.

Die Tests sprechen das Protokoll direkt (TestClient.websocket_connect). Ein „Gerät“ ist eine Anmeldung (Sitzung).
Um sicher zu sein, dass etwas *nicht* ankommt, schickt ein Test einen ungültigen Befehl als Schranke: Dessen
Antwort kommt sofort, alles Ältere steht davor in der Leitung.
"""

import time
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from datetime import timedelta
from typing import Any

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from app.connect import hub as hub_module
from app.models import UserSession, utcnow
from app.routers import connect as connect_router
from app.security import _create_token

from .conftest import ADMIN_PASSWORD, Library, bearer, login

URL = "/api/connect/ws"


# ----------------------------------------------------------------------------------------------- Hilfen


@contextmanager
def device(client: TestClient, tokens: dict, *, query: bool = False) -> Iterator[Any]:
    if query:
        with client.websocket_connect(f"{URL}?token={tokens['access_token']}") as ws:
            yield ws
    else:
        with client.websocket_connect(URL, headers=bearer(tokens)) as ws:
            yield ws


def hello(ws: Any, kind: str = "phone", playing: bool = False, volume: bool = False, play: bool = True) -> dict:
    ws.send_json({"type": "hello", "v": 1, "kind": kind, "platform": "android",
                  "caps": {"volume": volume, "play": play}, "playing": playing})  # fmt: skip
    return recv(ws, "welcome")


def recv(ws: Any, kind: str, seen: list[dict] | None = None) -> dict:
    """Nächste Nachricht dieses Typs (andere werden übersprungen bzw. in `seen` gesammelt)."""
    while True:
        message = ws.receive_json()
        if message["type"] == kind:
            return message
        if seen is not None:
            seen.append(message)


_barrier = iter(range(10**9))


def drain(ws: Any) -> list[dict]:
    """Alle Nachrichten bis zur Schranke (die Schranke selbst nicht)."""
    marker = f"sync-{next(_barrier)}"
    ws.send_json({"type": "cmd", "id": marker, "target": "kein-gerät", "action": "pause"})
    seen: list[dict] = []
    while True:
        message = ws.receive_json()
        if message["type"] == "result" and message["id"] == marker:
            assert message["code"] == "bad_request"
            return seen
        seen.append(message)


def cmd(ws: Any, cmd_id: str, target: int, action: str, **args: object) -> None:
    ws.send_json({"type": "cmd", "id": cmd_id, "target": target, "action": action, "args": args})


def result(ws: Any, cmd_id: str, seen: list[dict] | None = None) -> dict:
    while True:
        message = recv(ws, "result", seen)
        if message["id"] == cmd_id:
            return message


def state(
    seq: int, playing: bool = True, queue: list[int] | None = None, index: int | None = 0, **extra: object
) -> dict:
    queue = [1, 2, 3] if queue is None else queue
    body = {"seq": seq, "playing": playing, "position_ms": 1000, "duration_ms": 200_000, "speed": 1.0,
            "queue_ids": queue, "index": index if queue else None, "shuffle": False, "repeat": "off",
            "volume": None, "context": {"type": "album", "id": "3", "name": "Album"}}  # fmt: skip
    body.update(extra)
    return {"type": "state", "state": body}


def closed_with(ws: Any) -> int:
    with pytest.raises(WebSocketDisconnect) as info:
        while True:
            ws.receive_json()
    return info.value.code


def user_tokens(client: TestClient, make_user: Callable, name: str, device_name: str = "Handy") -> dict:
    make_user(name)
    return login(client, name, "kinder-passwort", device=device_name)


def admin_tokens(client: TestClient, device_name: str) -> dict:
    return login(client, "admin", ADMIN_PASSWORD, device=device_name)


def configure(client: TestClient, headers: dict[str, str], **values: object) -> dict:
    response = client.put("/api/admin/config", headers=headers, json=values)
    assert response.status_code == 200, response.text
    return response.json()


@pytest.fixture
def fast(monkeypatch: pytest.MonkeyPatch) -> None:
    """Kurze Wartezeiten auf Antworten der Geräte."""
    monkeypatch.setattr(hub_module, "ACK_TIMEOUT", 0.3)
    monkeypatch.setattr(hub_module, "RELEASE_TIMEOUT", 0.2)


# ----------------------------------------------------------------------------------------------- Anmeldung


def test_requires_valid_login(client: TestClient, admin_headers: dict[str, str]) -> None:
    with client.websocket_connect(URL) as ws:
        assert closed_with(ws) == 4401
    with client.websocket_connect(URL, headers={"Authorization": "Bearer kaputt"}) as ws:
        assert closed_with(ws) == 4401
    # Medien-Token gilt hier nicht
    tokens = admin_tokens(client, "PC")
    with client.websocket_connect(f"{URL}?token={tokens['media_token']}") as ws:
        assert closed_with(ws) == 4401
    # abgemeldetes Gerät
    client.post("/api/auth/logout", headers=bearer(tokens))
    with device(client, tokens) as ws:
        assert closed_with(ws) == 4401


def test_hello_welcome_and_own_device(client: TestClient) -> None:
    tokens = admin_tokens(client, "Windows · BÜRO-PC")
    with device(client, tokens, query=True) as ws:
        welcome = hello(ws, kind="computer", volume=True)
    assert welcome["protocol"] == 1 and welcome["allowed"] is True
    assert welcome["active_device_id"] is None and welcome["state"] is None
    me = client.get("/api/me/sessions", headers=bearer(tokens)).json()
    sid = next(s["id"] for s in me if s["current"])
    assert welcome["device_id"] == sid
    assert welcome["devices"] == [
        {"id": sid, "name": "Windows · BÜRO-PC", "kind": "computer", "platform": "android",
         "caps": {"volume": True, "play": True}, "is_self": True, "is_active": False}
    ]  # fmt: skip


def test_hello_must_come_first_and_in_time(client: TestClient, monkeypatch: pytest.MonkeyPatch) -> None:
    tokens = admin_tokens(client, "PC")
    with device(client, tokens) as ws:
        ws.send_json({"type": "hello", "v": 2, "kind": "phone"})
        with pytest.raises(WebSocketDisconnect) as info:
            ws.receive_json()
        assert (info.value.code, info.value.reason) == (4400, "Protokoll nicht unterstützt")
    with device(client, tokens) as ws:
        ws.send_json({"type": "hello", "v": 1, "kind": "toaster"})
        assert closed_with(ws) == 4400
    with device(client, tokens) as ws:
        ws.send_text("kein json")
        assert closed_with(ws) == 4400
    with device(client, tokens) as ws:
        ws.send_text("x" * (256 * 1024 + 1))
        assert closed_with(ws) == 4400
    monkeypatch.setattr(connect_router, "HELLO_TIMEOUT", 0.2)
    with device(client, tokens) as ws:
        ws.send_json({"type": "ping"})  # zählt nicht als hello
        assert closed_with(ws) == 4400


def test_devices_of_the_same_account_only(client: TestClient, make_user: Callable) -> None:
    pc, phone = admin_tokens(client, "PC"), admin_tokens(client, "Handy")
    lena = user_tokens(client, make_user, "lena", "Lenas Tablet")
    with device(client, pc) as a, device(client, phone) as b, device(client, lena) as other:
        a_id = hello(a, kind="computer")["device_id"]
        welcome_b = hello(b)
        b_id = welcome_b["device_id"]
        other_welcome = hello(other, kind="tablet")
        other_id = other_welcome["device_id"]
        assert {d["id"] for d in welcome_b["devices"]} == {a_id, b_id}
        # A erfährt von B
        update = recv(a, "devices")
        assert {d["id"] for d in update["devices"]} == {a_id, b_id}
        assert [d["is_self"] for d in update["devices"]] == [True, False]  # eigenes zuerst
        # Das fremde Konto sieht nur sich – auch der Admin sieht keine fremden Geräte
        assert [d["id"] for d in other_welcome["devices"]] == [other_id]
        assert all(m.get("type") != "devices" or len(m["devices"]) == 2 for m in drain(a))
        # Befehl an ein fremdes Gerät: gleiche Antwort wie für eine unbekannte ID
        cmd(a, "c1", other_id, "pause")
        foreign = result(a, "c1")
        cmd(a, "c2", 999_999, "pause")
        unknown = result(a, "c2")
        expected = {"ok": False, "code": "unknown_device", "message": "Dieses Gerät ist nicht mehr verbunden."}
        assert {k: foreign[k] for k in expected} == expected == {k: unknown[k] for k in expected}
        cmd(other, "c3", a_id, "pause")
        assert result(other, "c3")["code"] == "unknown_device"
        assert not [m for m in drain(other) if m["type"] == "exec"]
        # Befehl an das eigene Gerät (außer transfer) ist ein Fehler
        cmd(a, "c4", a_id, "pause")
        assert result(a, "c4")["code"] == "bad_request"


# ----------------------------------------------------------------------------------------------- Befehle


def test_remote_command_ack_and_timeout(client: TestClient, fast: None) -> None:
    pc, phone = admin_tokens(client, "PC"), admin_tokens(client, "Handy")
    with device(client, pc) as a, device(client, phone) as b:
        hello(a, kind="computer")
        b_id = hello(b)["device_id"]
        cmd(a, "p1", b_id, "pause")
        exec_ = recv(b, "exec")
        assert exec_["action"] == "pause" and exec_["args"] == {} and exec_["id"].endswith(":p1")
        assert exec_["from"] == hello_id(client, pc)
        b.send_json({"type": "ack", "id": exec_["id"], "ok": True})
        assert result(a, "p1") == {"type": "result", "id": "p1", "ok": True}
        # Fehler des Ziels werden unverändert weitergereicht
        cmd(a, "p2", b_id, "next")
        exec_ = recv(b, "exec")
        b.send_json({"type": "ack", "id": exec_["id"], "ok": False, "code": "skip_limit", "message": "Grenze erreicht"})
        assert result(a, "p2") == {"type": "result", "id": "p2", "ok": False, "code": "skip_limit",
                                   "message": "Grenze erreicht"}  # fmt: skip
        # ohne Antwort -> timeout
        cmd(a, "p3", b_id, "seek", position_ms=5000)
        assert recv(b, "exec")["args"] == {"position_ms": 5000}
        assert result(a, "p3")["code"] == "timeout"
        # ungültige Argumente
        cmd(a, "p4", b_id, "seek", position_ms=-1)
        assert result(a, "p4")["code"] == "bad_request"
        cmd(a, "p5", b_id, "fly")
        assert result(a, "p5")["code"] == "bad_request"


def hello_id(client: TestClient, tokens: dict) -> int:
    sessions = client.get("/api/me/sessions", headers=bearer(tokens)).json()
    return next(s["id"] for s in sessions if s["current"])


def test_duplicate_command_id_runs_once(client: TestClient) -> None:
    pc, phone = admin_tokens(client, "PC"), admin_tokens(client, "Handy")
    with device(client, pc) as a, device(client, phone) as b:
        hello(a, kind="computer")
        b_id = hello(b)["device_id"]
        cmd(a, "same", b_id, "resume")
        cmd(a, "same", b_id, "resume")  # läuft noch -> ignoriert
        exec_ = recv(b, "exec")
        b.send_json({"type": "ack", "id": exec_["id"], "ok": True})
        first = result(a, "same")
        cmd(a, "same", b_id, "resume")  # schon beantwortet -> gleiches Ergebnis, nicht erneut ausführen
        second = result(a, "same")
        assert first == second == {"type": "result", "id": "same", "ok": True}
        assert not [m for m in drain(b) if m["type"] == "exec"]
        assert not [m for m in drain(a) if m["type"] == "result"]


def test_unsupported_volume_and_device_without_playback(client: TestClient) -> None:
    pc, phone, broken = admin_tokens(client, "PC"), admin_tokens(client, "Handy"), admin_tokens(client, "Alter PC")
    with device(client, pc) as a, device(client, phone) as b, device(client, broken) as c:
        a_id = hello(a, kind="computer", volume=True)["device_id"]
        b_id = hello(b)["device_id"]
        c_id = hello(c, kind="computer", play=False)["device_id"]
        cmd(a, "v1", b_id, "set_volume", volume=0.5)
        assert result(a, "v1") == {"type": "result", "id": "v1", "ok": False, "code": "unsupported",
                                   "message": "Das kann dieses Gerät nicht."}  # fmt: skip
        cmd(b, "v2", a_id, "set_volume", volume=0.5)
        exec_ = recv(a, "exec")
        assert exec_["args"] == {"volume": 0.5}
        cmd(b, "v3", c_id, "resume")
        assert result(b, "v3")["code"] == "unsupported"
        cmd(b, "v4", c_id, "transfer")
        assert result(b, "v4")["code"] == "unsupported"
        cmd(b, "v5", a_id, "set_volume", volume=1.5)
        assert result(b, "v5")["code"] == "bad_request"


def test_play_filters_tracks_by_visibility(lib: Library) -> None:
    client = lib.client
    categories = {c["name"]: c["id"] for c in lib.get("/api/categories")}
    tracks = {t["title"]: t["id"] for t in lib.get("/api/tracks", limit=500)["items"]}
    created = client.post("/api/users", headers=lib.headers, json={
        "username": "kim", "password": "kinder-passwort", "all_categories": False,
        "category_ids": [categories["Musik"]],
    })  # fmt: skip
    assert created.status_code == 201, created.text
    tablet, phone = login(client, "kim", "kinder-passwort", "Tablet"), login(client, "kim", "kinder-passwort", "Handy")
    hidden, lucky, love = tracks["Kapitel 1"], tracks["Get Lucky"], tracks["Love of My Life"]
    with device(client, tablet) as a, device(client, phone) as b:
        hello(a, kind="tablet")
        b_id = hello(b)["device_id"]
        # gewählter Titel unsichtbar -> erster verbleibender; Reihenfolge bleibt
        cmd(a, "pl1", b_id, "play", track_ids=[love, hidden, lucky, 999_999], index=1, shuffle=True,
            context={"type": "album", "id": "7", "name": "Mix"})  # fmt: skip
        exec_ = recv(b, "exec")
        assert exec_["action"] == "play"
        assert [t["id"] for t in exec_["args"]["tracks"]] == [love, lucky]
        assert exec_["args"]["index"] == 0 and exec_["args"]["shuffle"] is True
        assert exec_["args"]["context"] == {"type": "album", "id": "7", "name": "Mix"}
        assert exec_["args"]["tracks"][1]["title"] == "Get Lucky"
        b.send_json({"type": "ack", "id": exec_["id"], "ok": True})
        assert result(a, "pl1")["ok"] is True
        cmd(a, "pl2", b_id, "play", track_ids=[love, lucky], index=1)
        assert recv(b, "exec")["args"]["index"] == 1
        # nur unsichtbare -> not_found, nichts erreicht das Ziel
        cmd(a, "pl3", b_id, "add_queue", track_ids=[hidden])
        assert result(a, "pl3") == {"type": "result", "id": "pl3", "ok": False, "code": "not_found",
                                    "message": "Diese Titel sind nicht verfügbar."}  # fmt: skip
        cmd(a, "pl4", b_id, "play_next", track_ids=[hidden, lucky])
        assert [t["id"] for t in recv(b, "exec")["args"]["tracks"]] == [lucky]


def test_remote_state_lists_only_visible_tracks(lib: Library) -> None:
    client = lib.client
    categories = {c["name"]: c["id"] for c in lib.get("/api/categories")}
    tracks = {t["title"]: t["id"] for t in lib.get("/api/tracks", limit=500)["items"]}
    client.post("/api/users", headers=lib.headers, json={
        "username": "kim", "password": "kinder-passwort", "all_categories": False,
        "category_ids": [categories["Musik"]],
    })  # fmt: skip
    tablet, phone = login(client, "kim", "kinder-passwort", "Tablet"), login(client, "kim", "kinder-passwort", "Handy")
    queue = [tracks["Get Lucky"], tracks["Kapitel 1"], tracks["Love of My Life"]]
    with device(client, tablet) as a, device(client, phone) as b:
        a_id = hello(a, kind="tablet")["device_id"]
        hello(b)
        a.send_json(state(1, queue=queue))
        message = recv(b, "state")
        assert message["device_id"] == a_id
        remote = message["state"]
        assert "seq" not in remote and remote["queue_rev"] >= 1
        assert remote["track"]["title"] == "Get Lucky"
        assert [t["title"] for t in remote["upcoming"]] == ["Love of My Life"]
        assert remote["queue_ids"] == queue and remote["position_ms"] >= 1000
        # gleiche Warteschlange -> gleiche queue_rev; anderer Titel -> neue
        a.send_json(state(2, queue=queue, position_ms=5000))
        again = recv(b, "state")["state"]
        assert again["queue_rev"] == remote["queue_rev"] and again["position_ms"] >= 5000
        a.send_json(state(3, queue=queue, index=1))
        hidden_now = recv(b, "state")["state"]
        assert hidden_now["queue_rev"] > remote["queue_rev"] and hidden_now["track"] is None


# ----------------------------------------------------------------------------------------------- Aktives Gerät


def test_state_makes_device_active_and_newest_play_wins(client: TestClient) -> None:
    pc, phone = admin_tokens(client, "PC"), admin_tokens(client, "Handy")
    with device(client, pc) as a, device(client, phone) as b:
        a_id = hello(a, kind="computer")["device_id"]
        b_id = hello(b)["device_id"]
        # alte und gleiche seq werden verworfen, ungültige Zustände auch (ohne Close)
        a.send_json(state(5))
        devices = recv(b, "devices")
        assert devices["active_device_id"] == a_id and devices["devices"][0]["id"] == a_id
        assert devices["devices"][0]["is_active"] is True
        first = recv(b, "state")
        assert first["device_id"] == a_id and first["state"]["playing"] is True
        a.send_json(state(5, position_ms=9000))
        a.send_json(state(6, speed="schnell"))
        assert not [m for m in drain(a) if m["type"] == "state"]  # nie an sich selbst
        assert not [m for m in drain(b) if m["type"] == "state"]
        # B drückt Play -> A wird pausiert, B ist aktiv
        b.send_json(state(1, queue=[4, 5]))
        pause = recv(a, "exec")
        assert pause["action"] == "pause" and pause["from"] is None and pause["id"].startswith("srv-")
        a.send_json({"type": "ack", "id": pause["id"], "ok": True})
        assert recv(a, "devices")["active_device_id"] == b_id
        assert recv(a, "state")["device_id"] == b_id
        # A meldet sich pausiert -> nicht aktiv, wird nicht weitergegeben
        a.send_json(state(7, playing=False))
        assert not [m for m in drain(b) if m["type"] in ("state", "exec")]


def test_hello_playing_takes_over(client: TestClient) -> None:
    pc, phone = admin_tokens(client, "PC"), admin_tokens(client, "Handy")
    with device(client, pc) as a:
        a_id = hello(a, kind="computer")["device_id"]
        a.send_json(state(1))
        drain(a)
        with device(client, phone) as b:
            welcome = hello(b, playing=True)
            assert welcome["active_device_id"] == welcome["device_id"]
            assert recv(a, "exec")["action"] == "pause"
            assert recv(a, "devices")["active_device_id"] == welcome["device_id"] != a_id


# ----------------------------------------------------------------------------------------------- Übertragen


@pytest.fixture
def media(lib: Library) -> dict[str, int]:
    return {t["title"]: t["id"] for t in lib.get("/api/tracks", limit=500)["items"]}


def test_transfer_with_release_snapshot(lib: Library, media: dict[str, int], fast: None) -> None:
    client = lib.client
    pc, phone = admin_tokens(client, "PC"), admin_tokens(client, "Handy")
    queue = [media["Get Lucky"], media["Love of My Life"], media["Bohemian Rhapsody"]]
    with device(client, pc) as a, device(client, phone) as b:
        a_id = hello(a, kind="computer")["device_id"]
        b_id = hello(b)["device_id"]
        a.send_json(state(1, queue=queue, index=0))
        recv(b, "state")
        # B holt die Wiedergabe zu sich
        cmd(b, "t1", b_id, "transfer")
        release = recv(a, "exec")
        assert release["action"] == "release" and release["from"] == b_id
        snapshot = state(9, queue=queue, index=2, position_ms=42_000, shuffle=True, shuffle_order=[2, 0, 1],
                         repeat="all", volume=0.4)["state"]  # fmt: skip
        a.send_json({"type": "ack", "id": release["id"], "ok": True, "snapshot": snapshot})
        take = recv(b, "exec")
        assert take["action"] == "take_over" and take["from"] == b_id
        args = take["args"]
        assert (args["index"], args["position_ms"], args["playing"], args["shuffle"]) == (2, 42_000, True, True)
        assert args["shuffle_order"] == [2, 0, 1] and args["repeat"] == "all" and args["volume"] == 0.4
        assert args["context"] == {"type": "album", "id": "3", "name": "Album"}
        assert [t["id"] for t in args["tracks"]] == queue
        b.send_json({"type": "ack", "id": take["id"], "ok": True})
        assert result(b, "t1") == {"type": "result", "id": "t1", "ok": True}
        assert recv(a, "devices")["active_device_id"] == b_id
        assert a_id != b_id


def test_transfer_real_tracks_fallbacks_and_busy(lib: Library, media: dict[str, int], fast: None) -> None:
    client = lib.client
    pc, phone, tablet = admin_tokens(client, "PC"), admin_tokens(client, "Handy"), admin_tokens(client, "Tablet")
    queue = [media["Get Lucky"], media["Love of My Life"], media["Bohemian Rhapsody"]]
    with device(client, pc) as a, device(client, phone) as b, device(client, tablet) as c:
        a_id = hello(a, kind="computer")["device_id"]
        b_id = hello(b)["device_id"]
        c_id = hello(c, kind="tablet")["device_id"]
        a.send_json(state(1, queue=queue, index=1, position_ms=30_000))
        recv(b, "state")
        # A -> B, A antwortet mit Stand
        cmd(c, "t1", b_id, "transfer", play=False)
        release = recv(a, "exec")
        a.send_json({"type": "ack", "id": release["id"], "ok": True,
                     "snapshot": state(2, queue=queue, index=1, position_ms=31_000)["state"]})  # fmt: skip
        take = recv(b, "exec")
        assert [t["id"] for t in take["args"]["tracks"]] == queue
        assert (take["args"]["index"], take["args"]["position_ms"], take["args"]["playing"]) == (1, 31_000, False)
        # Zweite Übertragung, während die erste läuft -> busy
        cmd(a, "t2", c_id, "transfer")
        assert result(a, "t2")["code"] == "busy"
        b.send_json({"type": "ack", "id": take["id"], "ok": True})
        seen: list[dict] = []
        assert result(c, "t1", seen)["ok"] is True
        assert [m for m in seen if m["type"] == "devices"][-1]["active_device_id"] == b_id

        # B -> C: B antwortet nicht -> letzter bekannter Stand (vorläufig aus dem Snapshot)
        cmd(a, "t3", c_id, "transfer")
        assert recv(b, "exec")["action"] == "release"
        take = recv(c, "exec")
        assert take["action"] == "take_over" and take["args"]["index"] == 1
        assert take["args"]["position_ms"] == 31_000 and take["args"]["playing"] is False
        # Ziel scheitert -> Fehler des Ziels an den Absender; die Quelle spielte nicht -> kein resume
        c.send_json({"type": "ack", "id": take["id"], "ok": False, "code": "offline_unavailable"})
        failed = result(a, "t3")
        assert failed["code"] == "offline_unavailable" and failed["ok"] is False
        assert not [m for m in drain(b) if m["type"] == "exec"]

        # Ziel scheitert, Quelle spielte vorher -> Quelle bekommt resume
        b.send_json(state(1, queue=queue, index=0))
        cmd(a, "t4", c_id, "transfer")
        release = recv(b, "exec")
        b.send_json({"type": "ack", "id": release["id"], "ok": True,
                     "snapshot": state(2, queue=queue, index=0)["state"]})  # fmt: skip
        take = recv(c, "exec")
        c.send_json({"type": "ack", "id": take["id"], "ok": False, "code": "cannot_play"})
        assert result(a, "t4")["code"] == "cannot_play"
        resume = recv(b, "exec")
        assert resume["action"] == "resume" and resume["from"] is None

        # Ziel ist schon aktiv -> ok ohne Umweg
        cmd(a, "t5", b_id, "transfer")
        assert result(a, "t5")["ok"] is True
        assert a_id


def test_transfer_without_source_uses_last_state_or_reports_nothing(
    lib: Library, media: dict[str, int], fast: None, monkeypatch: pytest.MonkeyPatch
) -> None:
    client = lib.client
    pc, phone = admin_tokens(client, "PC"), admin_tokens(client, "Handy")
    queue = [media["Get Lucky"], media["Kapitel 1"]]
    with device(client, phone) as b:
        b_id = hello(b)["device_id"]
        # nichts läuft, keine Quelle -> nothing_playing
        with device(client, pc) as a:
            hello(a, kind="computer")
            cmd(a, "n1", b_id, "transfer")
            assert result(a, "n1") == {"type": "result", "id": "n1", "ok": False, "code": "nothing_playing",
                                       "message": "Gerade läuft nichts, das übertragen werden kann."}  # fmt: skip
            a.send_json(state(1, queue=queue, index=1, position_ms=10_000))
            recv(b, "state")
        # A ist weg (Gnadenfrist läuft) -> B holt den letzten Stand zu sich, Position hochgerechnet
        assert recv(b, "devices")["active_device_id"] is not None
        cmd(b, "n2", b_id, "transfer")
        take = recv(b, "exec")
        assert take["action"] == "take_over" and take["from"] == b_id
        assert take["args"]["index"] == 1 and take["args"]["position_ms"] >= 10_000
        b.send_json({"type": "ack", "id": take["id"], "ok": True})
        seen: list[dict] = []
        assert result(b, "n2", seen)["ok"] is True
        assert [m for m in seen if m["type"] == "devices"][-1]["active_device_id"] == b_id


def test_grace_period_ends_and_keeps_paused_state(client: TestClient, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(hub_module, "ACTIVE_GRACE_SECONDS", 0.1)
    pc, phone = admin_tokens(client, "PC"), admin_tokens(client, "Handy")
    with device(client, phone) as b:
        hello(b)
        with device(client, pc) as a:
            hello(a, kind="computer")
            a.send_json(state(1))
            recv(b, "state")
        while recv(b, "devices")["active_device_id"] is not None:
            pass
        time.sleep(0.05)
    # neues Gerät: kein aktives, aber der letzte Stand (pausiert) zum Weiterhören
    with device(client, admin_tokens(client, "Tablet")) as c:
        welcome = hello(c, kind="tablet")
        assert welcome["active_device_id"] is None
        assert welcome["state"]["playing"] is False and welcome["state"]["position_ms"] >= 1000


# ----------------------------------------------------------------------------------------------- Rauswurf


def test_revoking_sessions_closes_connections_immediately(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable
) -> None:
    lena_phone = user_tokens(client, make_user, "lena", "Handy")
    lena_pc = login(client, "lena", "kinder-passwort", device="PC")
    lena_tablet = login(client, "lena", "kinder-passwort", device="Tablet")
    with device(client, lena_phone) as a, device(client, lena_pc) as b, device(client, lena_tablet) as c:
        hello(a)
        b_id = hello(b, kind="computer")["device_id"]
        hello(c, kind="tablet")
        # Gerät abmelden (aus einem anderen Gerät) -> B sofort 4401, die anderen bleiben
        assert client.delete(f"/api/me/sessions/{b_id}", headers=bearer(lena_phone)).status_code == 204
        assert closed_with(b) == 4401
        while b_id in {d["id"] for d in recv(a, "devices")["devices"]}:
            pass  # ältere Listen (B und C kamen dazu) überspringen
        # Abmelden -> 4401
        assert client.post("/api/auth/logout", headers=bearer(lena_tablet)).status_code == 204
        assert closed_with(c) == 4401
    lena_id = next(u["id"] for u in client.get("/api/users", headers=admin_headers).json() if u["username"] == "lena")
    second = login(client, "lena", "kinder-passwort", device="PC")
    with device(client, lena_phone) as a, device(client, second) as b:
        hello(a)
        hello(b, kind="computer")
        # Admin deaktiviert das Konto -> alle Verbindungen 4401
        response = client.patch(f"/api/users/{lena_id}", headers=admin_headers, json={"is_active": False})
        assert response.status_code == 200
        assert closed_with(a) == 4401 and closed_with(b) == 4401


def test_password_change_drops_other_devices(client: TestClient, make_user: Callable) -> None:
    phone = user_tokens(client, make_user, "lena", "Handy")
    pc = login(client, "lena", "kinder-passwort", device="PC")
    with device(client, phone) as a, device(client, pc) as b:
        hello(a)
        hello(b, kind="computer")
        response = client.post("/api/me/password", headers=bearer(phone),
                               json={"current_password": "kinder-passwort",
                                     "new_password": "neues-passwort-1"})  # fmt: skip
        assert response.status_code == 200
        assert closed_with(b) == 4401
        assert not [m for m in drain(a) if m["type"] == "exec"]  # A bleibt verbunden


def test_recheck_detects_revocation_and_expiry(client: TestClient, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(connect_router, "ACCESS_CHECK_SECONDS", 0)
    tokens = admin_tokens(client, "PC")
    sid = hello_id(client, tokens)
    with device(client, tokens) as ws:
        hello(ws, kind="computer")
        # Widerruf ohne Hub-Aufruf (wie beim Refresh-Token-Diebstahl) -> spätestens bei der nächsten Prüfung
        with client.app.state.session_factory() as db:  # type: ignore[attr-defined]
            db.get(UserSession, sid).revoked_at = utcnow()
            db.commit()
        ws.send_json({"type": "ping"})
        assert closed_with(ws) == 4401

    # Token läuft ab, ohne dass `auth` kam -> 4001
    tokens = admin_tokens(client, "Handy")
    sid = hello_id(client, tokens)
    secret = client.app.state.secret_key  # type: ignore[attr-defined]
    user_id = int(client.get("/api/me", headers=bearer(tokens)).json()["id"])
    short = _create_token(secret, "access", user_id, sid, timedelta(seconds=1))
    with client.websocket_connect(URL, headers={"Authorization": f"Bearer {short}"}) as ws:
        hello(ws)
        time.sleep(1.1)
        ws.send_json({"type": "ping"})
        with pytest.raises(WebSocketDisconnect) as info:
            ws.receive_json()
        assert (info.value.code, info.value.reason) == (4001, "Anmeldung erneuern")


def test_token_renewal_in_band(client: TestClient) -> None:
    tokens = admin_tokens(client, "PC")
    other = admin_tokens(client, "Handy")
    sid = hello_id(client, tokens)
    secret = client.app.state.secret_key  # type: ignore[attr-defined]
    user_id = int(client.get("/api/me", headers=bearer(tokens)).json()["id"])
    old = _create_token(secret, "access", user_id, sid, timedelta(minutes=1))
    with client.websocket_connect(URL, headers={"Authorization": f"Bearer {old}"}) as ws:
        hello(ws, kind="computer")
        newer = _create_token(secret, "access", user_id, sid, timedelta(minutes=10))
        ws.send_json({"type": "auth", "token": newer})
        assert recv(ws, "auth_ok") == {"type": "auth_ok"}
        # Token eines anderen Geräts -> 4401
        ws.send_json({"type": "auth", "token": other["access_token"]})
        assert closed_with(ws) == 4401
    with client.websocket_connect(URL, headers={"Authorization": f"Bearer {newer}"}) as ws:
        hello(ws, kind="computer")
        ws.send_json({"type": "auth", "token": old})  # älter -> abgelehnt
        assert closed_with(ws) == 4401


def test_second_connection_of_the_same_device_replaces_the_first(client: TestClient) -> None:
    tokens = admin_tokens(client, "PC")
    with device(client, tokens) as first:
        hello(first, kind="computer")
        with device(client, tokens) as second:
            with pytest.raises(WebSocketDisconnect) as info:
                while True:
                    first.receive_json()
            assert (info.value.code, info.value.reason) == (4409, "Auf diesem Gerät neu verbunden")
            welcome = hello(second, kind="computer")
            assert len(welcome["devices"]) == 1


def test_device_limit_per_account(client: TestClient, monkeypatch: pytest.MonkeyPatch) -> None:
    from app.connect import protocol

    monkeypatch.setattr(protocol, "MAX_DEVICES", 2)
    one, two, three = (admin_tokens(client, f"Gerät {i}") for i in range(3))
    with device(client, one) as a, device(client, two) as b, device(client, three) as c:
        hello(a)
        hello(b)
        with pytest.raises(WebSocketDisconnect) as info:
            c.receive_json()
        assert (info.value.code, info.value.reason) == (4429, "Zu viele Geräte verbunden")


# ----------------------------------------------------------------------------------------------- Ratenbegrenzung


def test_rate_limits(client: TestClient, fast: None) -> None:
    pc, phone = admin_tokens(client, "PC"), admin_tokens(client, "Handy")
    with device(client, pc) as a, device(client, phone) as b:
        hello(a, kind="computer")
        b_id = hello(b)["device_id"]
        for i in range(30):
            cmd(a, f"r{i}", b_id, "pause")
        answers: dict[str, dict] = {}
        while len(answers) < 30:
            message = recv(a, "result")
            answers[message["id"]] = message
        codes = [answers[f"r{i}"].get("code") for i in range(30)]
        assert "rate_limited" in codes
        # die ersten 20 gehen durch (Spitze), danach greift die Grenze
        assert "rate_limited" not in codes[:20]
    with device(client, pc) as a:
        hello(a, kind="computer")
        with pytest.raises(WebSocketDisconnect) as info:
            for _ in range(250):
                a.send_json({"type": "ping"})
            while True:
                a.receive_json()
        assert (info.value.code, info.value.reason) == (4429, "Zu viele Nachrichten")


def test_state_throttle_drops_bursts(client: TestClient) -> None:
    pc, phone = admin_tokens(client, "PC"), admin_tokens(client, "Handy")
    with device(client, pc) as a, device(client, phone) as b:
        hello(a, kind="computer")
        hello(b)
        for seq in range(1, 11):
            a.send_json(state(seq, position_ms=seq * 1000))
        drain(a)
        forwarded = [m for m in drain(b) if m["type"] == "state"]
        assert 1 <= len(forwarded) <= 5


# ----------------------------------------------------------------------------------------------- Premium


def test_premium_switch(client: TestClient, admin_headers: dict[str, str], make_user: Callable) -> None:
    # Standard: für alle – nichts ändert sich
    assert client.get("/api/app/config").json()["premium_only"] == []
    assert client.get("/api/admin/config", headers=admin_headers).json()["remote_requires_premium"] is False
    lena_phone = user_tokens(client, make_user, "lena", "Handy")
    lena_pc = login(client, "lena", "kinder-passwort", device="PC")
    with device(client, lena_phone) as a:
        assert hello(a)["allowed"] is True

    saved = configure(client, admin_headers, remote_requires_premium=True)
    assert saved["remote_requires_premium"] is True
    assert client.get("/api/app/config").json()["premium_only"] == ["remote"]
    assert "remote" in client.get("/api/premium", headers=bearer(lena_phone)).json()["locked"]
    with device(client, lena_phone) as a, device(client, lena_pc) as b:
        welcome = hello(a)
        assert welcome["allowed"] is False and welcome["state"] is None
        b_id = hello(b, kind="computer")["device_id"]
        cmd(a, "x1", b_id, "pause")
        assert result(a, "x1") == {"type": "result", "id": "x1", "ok": False, "code": "premium",
                                   "message": "Auf anderen Geräten abspielen gibt es nur mit Premium."}  # fmt: skip
        # kein aktives Gerät, keine Weitergabe, nichts wird pausiert
        b.send_json(state(1))
        a.send_json(state(1))
        assert not [m for m in drain(b) if m["type"] in ("state", "exec")]
        assert not [m for m in drain(a) if m["type"] in ("state", "exec")]
        # Premium vergeben -> `access` ohne Neuverbindung
        lena_id = next(u["id"] for u in client.get("/api/users", headers=admin_headers).json()
                       if u["username"] == "lena")  # fmt: skip
        granted = client.post(f"/api/admin/users/{lena_id}/premium", headers=admin_headers, json={"unlimited": True})
        assert granted.status_code == 201, granted.text
        assert recv(a, "access") == {"type": "access", "allowed": True}
        assert recv(b, "access") == {"type": "access", "allowed": True}
        a.send_json(state(2))
        assert recv(b, "state")["state"]["playing"] is True
        # Schalter wieder aus -> bleibt erlaubt (keine Nachricht nötig)
        configure(client, admin_headers, remote_requires_premium=False)
        assert not [m for m in drain(a) if m["type"] == "access"]

    # Admins sind nie eingeschränkt
    configure(client, admin_headers, remote_requires_premium=True)
    with device(client, admin_tokens(client, "PC")) as ws:
        assert hello(ws, kind="computer")["allowed"] is True


def test_access_change_seen_by_recheck(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(connect_router, "ACCESS_CHECK_SECONDS", 0)
    phone = user_tokens(client, make_user, "lena", "Handy")
    with device(client, phone) as ws:
        assert hello(ws)["allowed"] is True
        # Einstellung direkt in der Datenbank (ohne Hub-Anstoß) -> Neuprüfung bei der nächsten Nachricht
        from app.services import app_config

        with client.app.state.session_factory() as db:  # type: ignore[attr-defined]
            app_config.update(db, {"remote_requires_premium": True})
            db.commit()
        ws.send_json({"type": "ping"})
        assert recv(ws, "access") == {"type": "access", "allowed": False}


def test_partial_codes_do_not_include_remote(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable
) -> None:
    from .test_premium import new_codes, redeem

    configure(client, admin_headers, remote_requires_premium=True)
    phone = user_tokens(client, make_user, "lena", "Handy")
    (code,) = new_codes(client, admin_headers, features=["offline", "video"])
    assert redeem(client, bearer(phone), code["code"]).status_code == 200
    with device(client, phone) as ws:
        assert hello(ws)["allowed"] is False
    (full,) = new_codes(client, admin_headers)
    assert redeem(client, bearer(phone), full["code"]).status_code == 200
    with device(client, phone) as ws:
        assert hello(ws)["allowed"] is True


# ----------------------------------------------------------------------------------------------- REST


def test_rename_session(client: TestClient, make_user: Callable) -> None:
    phone = user_tokens(client, make_user, "lena", "Handy")
    pc = login(client, "lena", "kinder-passwort", device="PC")
    pc_id = hello_id(client, pc)
    with device(client, phone) as a, device(client, pc) as b:
        hello(a)
        hello(b, kind="computer")
        drain(a)
        response = client.patch(f"/api/me/sessions/{pc_id}", headers=bearer(phone),
                                json={"device_name": "  Büro\x07-PC  "})  # fmt: skip
        assert response.status_code == 200, response.text
        body = response.json()
        assert body["device_name"] == "Büro-PC" and body["current"] is False and body["id"] == pc_id
        update = recv(a, "devices")
        assert {d["id"]: d["name"] for d in update["devices"]}[pc_id] == "Büro-PC"
    sessions = client.get("/api/me/sessions", headers=bearer(phone)).json()
    assert {s["id"]: s["device_name"] for s in sessions}[pc_id] == "Büro-PC"
    for bad in ("", "   ", "\x00\x01", "x" * 101):
        response = client.patch(f"/api/me/sessions/{pc_id}", headers=bearer(phone), json={"device_name": bad})
        assert response.status_code == 422, bad
    # fremdes oder abgemeldetes Gerät -> 404
    admin_sid = hello_id(client, admin_tokens(client, "Admin-PC"))
    response = client.patch(f"/api/me/sessions/{admin_sid}", headers=bearer(phone), json={"device_name": "Meins"})
    assert (response.status_code, response.json()["detail"]) == (404, "Gerät nicht gefunden.")
    client.delete(f"/api/me/sessions/{pc_id}", headers=bearer(phone))
    response = client.patch(f"/api/me/sessions/{pc_id}", headers=bearer(phone), json={"device_name": "Wieder da"})
    assert response.status_code == 404


def test_server_info_lists_connect_feature(client: TestClient) -> None:
    info = client.get("/api/server").json()
    assert info["features"] == ["connect"] and info["api_version"] == 1


def test_dashboard_has_remote_switch(client: TestClient) -> None:
    script = client.get("/web/dashboard.js").text
    assert 'remote: "Auf anderen Geräten abspielen"' in script
    assert 'whoSelect("remote_requires_premium")' in script
    assert '"skips", "remote", "badge"' in script


def test_shutdown_closes_connections(settings: Any) -> None:
    from app.main import create_app

    with TestClient(create_app(settings)) as client:
        tokens = admin_tokens(client, "PC")
        ws_cm = device(client, tokens)
        ws = ws_cm.__enter__()
        hello(ws, kind="computer")
        hub = client.app.state.connect_hub  # type: ignore[attr-defined]
        assert hub.connection_count == 1
        client.portal.call(hub.close_all, 1001)  # type: ignore[union-attr]
        assert closed_with(ws) == 1001
        ws_cm.__exit__(None, None, None)


# ----------------------------------------------------------------------------------------------- Nachprüfung (Funde)


def test_deleted_account_leaves_nothing_for_a_new_account_with_the_same_id(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable
) -> None:
    lena = make_user("lena")
    phone = login(client, "lena", "kinder-passwort", device="Handy")
    with device(client, phone) as ws:
        hello(ws)
        ws.send_json(state(1, context={"type": "playlist", "id": "9", "name": "Geheime Liste"}))
        drain(ws)
        assert client.delete(f"/api/users/{lena['id']}", headers=admin_headers).status_code == 204
        assert closed_with(ws) == 4401
    hub = client.app.state.connect_hub  # type: ignore[attr-defined]
    assert hub.account(lena["id"]) is None
    # SQLite vergibt die höchste freie ID neu – das neue Konto bekommt dieselbe Nummer
    max_ = make_user("max")
    assert max_["id"] == lena["id"]
    tokens = login(client, "max", "kinder-passwort", device="Handy")
    with device(client, tokens) as ws:
        welcome = hello(ws)
        assert welcome["state"] is None and welcome["active_device_id"] is None
        cmd(ws, "t1", welcome["device_id"], "transfer")
        assert result(ws, "t1")["code"] == "nothing_playing"


def test_deleting_own_account_forgets_the_state(client: TestClient, make_user: Callable) -> None:
    make_user("lena")
    phone = login(client, "lena", "kinder-passwort", device="Handy")
    me = client.get("/api/me", headers=bearer(phone)).json()
    with device(client, phone) as ws:
        hello(ws)
        ws.send_json(state(1))
        drain(ws)
        response = client.post("/api/me/delete", headers=bearer(phone), json={"password": "kinder-passwort"})
        assert response.status_code == 204, response.text
        assert closed_with(ws) == 4401
    assert client.app.state.connect_hub.account(me["id"]) is None  # type: ignore[attr-defined]


def test_account_with_other_creation_time_does_not_inherit_the_hub_entry() -> None:
    import asyncio
    from datetime import datetime

    from app.connect.hub import ConnectHub, Connection

    async def run() -> None:
        hub = ConnectHub()
        old = Connection(user_id=2, session_id=5, name="Handy", allowed=True, user_created=datetime(2026, 1, 1))
        assert hub.attach(old)
        await hub.hello(old, {"kind": "phone", "platform": "android", "caps": {"volume": False, "play": True},
                              "playing": True})  # fmt: skip
        account = hub.account(2)
        assert account is not None and account.active_id == 5
        account.last_state = {"playing": True}
        new = Connection(user_id=2, session_id=5, name="Handy", allowed=True, user_created=datetime(2026, 2, 1))
        assert hub.attach(new)
        fresh = hub.account(2)
        assert fresh is not account and fresh is not None
        assert fresh.active_id is None and fresh.last_state is None
        assert old.close_code == 4401
        for conn in (old, new):
            if conn.worker is not None:
                conn.worker.cancel()

    asyncio.run(run())


def test_hidden_category_removes_cached_track_details(lib: Library) -> None:
    client = lib.client
    categories = {c["name"]: c["id"] for c in lib.get("/api/categories")}
    tracks = {t["title"]: t["id"] for t in lib.get("/api/tracks", limit=500)["items"]}
    created = client.post("/api/users", headers=lib.headers, json={"username": "kim", "password": "kinder-passwort"})
    assert created.status_code == 201, created.text
    kim_id = created.json()["id"]
    pc, phone = login(client, "kim", "kinder-passwort", "PC"), login(client, "kim", "kinder-passwort", "Handy")
    queue = [tracks["Kapitel 1"], tracks["Get Lucky"]]
    with device(client, pc) as a, device(client, phone) as b:
        hello(a, kind="computer")
        hello(b)
        a.send_json(state(1, queue=queue))
        before = recv(b, "state")["state"]
        assert before["track"]["title"] == "Kapitel 1"
        # Admin nimmt die Rubrik weg -> neuer Stand sofort, ohne den verborgenen Titel
        response = client.patch(f"/api/users/{kim_id}", headers=lib.headers,
                                json={"all_categories": False, "category_ids": [categories["Musik"]]})  # fmt: skip
        assert response.status_code == 200, response.text
        after = recv(b, "state")["state"]
        assert after["track"] is None and after["queue_rev"] > before["queue_rev"]
        assert [t["title"] for t in after["upcoming"]] == ["Get Lucky"]
        # gleiche Warteschlange, neue Position: weiterhin ohne den verborgenen Titel
        a.send_json(state(2, queue=queue, position_ms=9000))
        again = recv(b, "state")["state"]
        assert again["track"] is None and again["position_ms"] >= 9000


def test_query_token_is_not_logged() -> None:
    import logging

    from app.main import RedactTokens, configure_logging

    record = logging.LogRecord("uvicorn.error", logging.INFO, __file__, 1, '%s - "WebSocket %s" [accepted]',
                               ("1.2.3.4:0", "/api/connect/ws?token=eyJ.geheim.x&scope=mine"), None)  # fmt: skip
    assert RedactTokens().filter(record) is True
    text = record.getMessage()
    assert "geheim" not in text and "token=***" in text and "scope=mine" in text
    plain = logging.LogRecord("uvicorn.access", logging.INFO, __file__, 1, "GET %s", ("/api/tracks",), None)
    RedactTokens().filter(plain)
    assert plain.getMessage() == "GET /api/tracks"
    configure_logging("INFO")
    for name in ("uvicorn.error", "uvicorn.access"):
        assert any(isinstance(f, RedactTokens) for f in logging.getLogger(name).filters)


def test_server_command_ids_are_unique_per_process(client: TestClient) -> None:
    from app.connect.hub import ConnectHub

    assert ConnectHub()._server_prefix != ConnectHub()._server_prefix
    pc, phone = admin_tokens(client, "PC"), admin_tokens(client, "Handy")
    with device(client, pc) as a, device(client, phone) as b:
        hello(a, kind="computer")
        hello(b)
        a.send_json(state(1))
        drain(a)
        b.send_json(state(1))
        pause = recv(a, "exec")
        prefix = client.app.state.connect_hub._server_prefix  # type: ignore[attr-defined]
        assert pause["id"] == f"{prefix}-1" and pause["id"] != "srv-1"


def test_stale_playing_state_does_not_take_playback_back(client: TestClient) -> None:
    pc, phone = admin_tokens(client, "PC"), admin_tokens(client, "Handy")
    with device(client, pc) as a, device(client, phone) as b:
        hello(a, kind="computer")
        b_id = hello(b)["device_id"]
        a.send_json(state(1))
        drain(a)
        # B drückt Play -> A bekommt pause; A's Herzschlag (playing=true) war schon unterwegs
        b.send_json(state(1, queue=[4, 5]))
        pause = recv(a, "exec")
        a.send_json(state(2))
        assert not [m for m in drain(b) if m["type"] == "exec"], "B darf nicht pausiert werden"
        a.send_json({"type": "ack", "id": pause["id"], "ok": True})
        a.send_json(state(3, playing=False))
        drain(a)
        seen = drain(b)
        assert not [m for m in seen if m["type"] == "exec"]
        assert all(m["active_device_id"] == b_id for m in seen if m["type"] == "devices")
        # Danach ist Play am PC wieder ein echter Play-Druck
        a.send_json(state(4))
        assert recv(b, "exec")["action"] == "pause"


def test_late_release_ack_and_stale_state_after_transfer(lib: Library, media: dict[str, int], fast: None) -> None:
    client = lib.client
    pc, phone = admin_tokens(client, "PC"), admin_tokens(client, "Handy")
    queue = [media["Get Lucky"], media["Love of My Life"]]
    with device(client, pc) as a, device(client, phone) as b:
        hello(a, kind="computer")
        b_id = hello(b)["device_id"]
        a.send_json(state(1, queue=queue))
        recv(b, "state")
        # Quelle antwortet nicht rechtzeitig -> Ziel übernimmt aus dem letzten Stand
        cmd(b, "t1", b_id, "transfer")
        release = recv(a, "exec")
        take = recv(b, "exec")
        b.send_json({"type": "ack", "id": take["id"], "ok": True})
        assert result(b, "t1")["ok"] is True
        b.send_json(state(1, queue=queue))
        # A meldet noch „spielt“ (vor dem verspäteten release) -> holt die Wiedergabe nicht zurück
        a.send_json(state(2, queue=queue))
        assert not [m for m in drain(b) if m["type"] == "exec"]
        a.send_json({"type": "ack", "id": release["id"], "ok": True,
                     "snapshot": state(3, queue=queue)["state"]})  # fmt: skip
        a.send_json(state(4, queue=queue, playing=False))
        assert not [m for m in drain(b) if m["type"] == "exec"]


def test_transfer_sends_state_to_the_giving_device_right_away(lib: Library, media: dict[str, int], fast: None) -> None:
    client = lib.client
    pc, phone = admin_tokens(client, "PC"), admin_tokens(client, "Handy")
    queue = [media["Get Lucky"], media["Love of My Life"]]
    with device(client, pc) as a, device(client, phone) as b:
        hello(a, kind="computer")
        b_id = hello(b)["device_id"]
        b.send_json(state(1, queue=queue, playing=False))
        b.send_json(state(2, queue=queue))
        drain(b)
        # Handy gibt an den PC ab (pausiert übertragen) – ohne dass der PC schon einen Stand gemeldet hat
        a_id = hello_id(client, pc)
        cmd(b, "t1", a_id, "transfer", play=False)
        release = recv(b, "exec")
        b.send_json({"type": "ack", "id": release["id"], "ok": True, "snapshot": state(3, queue=queue)["state"]})
        take = recv(a, "exec")
        a.send_json({"type": "ack", "id": take["id"], "ok": True})
        seen: list[dict] = []
        assert result(b, "t1", seen)["ok"] is True
        states = [m for m in seen if m["type"] == "state"]
        assert states and states[-1]["device_id"] == a_id
        assert states[-1]["state"]["track"]["title"] == "Get Lucky" and states[-1]["state"]["playing"] is False
        assert not [m for m in drain(a) if m["type"] == "state"], "nicht an das Ziel selbst"
        assert b_id != a_id


def test_queue_offset_and_expected_track_are_passed_through(client: TestClient) -> None:
    pc, phone = admin_tokens(client, "PC"), admin_tokens(client, "Handy")
    with device(client, pc) as a, device(client, phone) as b:
        hello(a, kind="computer")
        b_id = hello(b)["device_id"]
        # Ausschnitt einer langen Warteschlange: beginnt bei 1500
        b.send_json(state(1, queue=list(range(1, 1001)), index=500, queue_offset=1500))
        assert recv(a, "state")["state"]["queue_offset"] == 1500
        # Indizes in der vollen Warteschlange (über 1000) mit erwartetem Titel
        cmd(a, "q1", b_id, "skip_to", index=2001, track_id=502)
        assert recv(b, "exec")["args"] == {"index": 2001, "track_id": 502}
        cmd(a, "q2", b_id, "remove_queue", index=2002)
        assert recv(b, "exec")["args"] == {"index": 2002}
        cmd(a, "q3", b_id, "move_queue", **{"from": 2003, "to": 2005, "track_id": 504})
        assert recv(b, "exec")["args"] == {"from": 2003, "to": 2005, "track_id": 504}
        cmd(a, "q4", b_id, "remove_queue", index=1, track_id=0)
        assert result(a, "q4")["code"] == "bad_request"
        # ohne Angabe: 0
        b.send_json(state(2, queue=[1, 2]))
        assert recv(a, "state")["state"]["queue_offset"] == 0
