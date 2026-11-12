"""Protokoll der Geräte-Steuerung („Selfify Connect“, Version 1): Konstanten, Texte und Prüfung der Nachrichten.

Alle Nachrichten sind JSON-Objekte, eines je Textframe. Unbekannte Typen und Felder werden ignoriert
(Vorwärtskompatibilität). Was hier nicht durchgeht, wird verworfen bzw. mit `bad_request` beantwortet.
"""

import math
from typing import Any

PROTOCOL_VERSION = 1

# Größe einer Nachricht (Bytes); größer -> Close 4400
MAX_MESSAGE_BYTES = 256 * 1024
# Speichergrenzen je Konto bzw. Verbindung
MAX_QUEUE = 1000
# Indizes in Warteschlangen-Befehlen zählen in der vollen Warteschlange des Zielgeräts (die kann länger sein als der
# gemeldete Ausschnitt von höchstens MAX_QUEUE Titeln, siehe `queue_offset`)
MAX_QUEUE_INDEX = 1_000_000
MAX_UPCOMING = 50
MAX_DEVICES = 20
MAX_REMEMBERED_RESULTS = 100
MAX_OPEN_COMMANDS = 20
MAX_TEXT = 200
MAX_PLATFORM = 20
MAX_ID = 64

KINDS = ("phone", "tablet", "computer")
REPEAT_MODES = ("off", "one", "all")

# --------------------------------------------------------------------------- Close-Codes (verbindlich)

CLOSE_NORMAL = 1000
CLOSE_SHUTDOWN = 1001
CLOSE_RENEW = 4001
CLOSE_INVALID = 4400
CLOSE_UNAUTHORIZED = 4401
CLOSE_IDLE = 4408
CLOSE_REPLACED = 4409
CLOSE_TOO_MANY = 4429

REASON_SHUTDOWN = "Server fährt herunter"
REASON_RENEW = "Anmeldung erneuern"
REASON_INVALID = "Ungültige Nachricht"
REASON_VERSION = "Protokoll nicht unterstützt"
REASON_UNAUTHORIZED = "Nicht angemeldet"
REASON_IDLE = "Keine Antwort"
REASON_REPLACED = "Auf diesem Gerät neu verbunden"
REASON_TOO_MANY_MESSAGES = "Zu viele Nachrichten"
REASON_TOO_MANY_DEVICES = "Zu viele Geräte verbunden"

CLOSE_REASONS = {
    CLOSE_NORMAL: "",
    CLOSE_SHUTDOWN: REASON_SHUTDOWN,
    CLOSE_RENEW: REASON_RENEW,
    CLOSE_INVALID: REASON_INVALID,
    CLOSE_UNAUTHORIZED: REASON_UNAUTHORIZED,
    CLOSE_IDLE: REASON_IDLE,
    CLOSE_REPLACED: REASON_REPLACED,
    CLOSE_TOO_MANY: REASON_TOO_MANY_MESSAGES,
}

# --------------------------------------------------------------------------- Fehlercodes in result/ack

MESSAGES = {
    "bad_request": "Dieser Befehl wurde nicht verstanden.",
    "unknown_device": "Dieses Gerät ist nicht mehr verbunden.",
    "offline": "Dieses Gerät ist nicht mehr verbunden.",
    "unsupported": "Das kann dieses Gerät nicht.",
    "premium": "Auf anderen Geräten abspielen gibt es nur mit Premium.",
    "rate_limited": "Zu viele Befehle auf einmal. Bitte kurz warten.",
    "timeout": "Das Gerät antwortet nicht.",
    "busy": "Gerade wird schon übertragen. Bitte kurz warten.",
    "not_found": "Diese Titel sind nicht verfügbar.",
    "nothing_playing": "Gerade läuft nichts, das übertragen werden kann.",
    "offline_unavailable": "Keiner dieser Titel ist auf dem Gerät offline verfügbar.",
    "cannot_play": "Auf diesem Gerät kann gerade nichts abgespielt werden.",
    "failed": "Das hat auf dem Gerät nicht geklappt.",
    "queue_changed": "Die Warteschlange hat sich gerade geändert. Bitte noch einmal versuchen.",
}

# Aktionen und ob der Server die Titel-IDs prüfen muss
ACTIONS = (
    "transfer", "play", "add_queue", "play_next", "resume", "pause", "next", "previous", "seek", "skip_to",
    "set_shuffle", "set_repeat", "set_volume", "remove_queue", "move_queue", "clear_upcoming",
)  # fmt: skip
TRACK_ACTIONS = ("play", "add_queue", "play_next")


class Invalid(ValueError):
    """Nachricht oder Befehl ungültig."""


def error(code: str, message: str | None = None) -> dict[str, Any]:
    return {"ok": False, "code": code, "message": message if message is not None else MESSAGES.get(code, "")}


# --------------------------------------------------------------------------- Bausteine


def is_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def is_number(value: Any) -> bool:
    return (isinstance(value, int | float) and not isinstance(value, bool)) and math.isfinite(value)


def _int(value: Any, minimum: int = 0, maximum: int | None = None) -> int:
    if not is_int(value) or value < minimum or (maximum is not None and value > maximum):
        raise Invalid
    return value


def _bool(value: Any) -> bool:
    if not isinstance(value, bool):
        raise Invalid
    return value


def _text(value: Any, limit: int = MAX_TEXT) -> str:
    if not isinstance(value, str) or len(value) > limit:
        raise Invalid
    return value


def command_id(value: Any) -> str:
    if not isinstance(value, str) or not 1 <= len(value) <= MAX_ID:
        raise Invalid
    return value


def context(value: Any) -> dict[str, str] | None:
    """PlayContext oder None. Nur type/id/name, Texte höchstens 200 Zeichen."""
    if value is None:
        return None
    if not isinstance(value, dict):
        raise Invalid
    out = {"type": _text(value.get("type"))}
    for key in ("id", "name"):
        raw = value.get(key)
        out[key] = "" if raw is None else _text(raw)
    return out


def track_ids(value: Any) -> list[int]:
    if not isinstance(value, list) or not 1 <= len(value) <= MAX_QUEUE:
        raise Invalid
    return [_int(item, 1) for item in value]


# --------------------------------------------------------------------------- Nachrichten der App


def hello(message: dict[str, Any]) -> dict[str, Any]:
    """Prüft `hello`. Falsche Version -> Invalid mit REASON_VERSION."""
    if message.get("v") != PROTOCOL_VERSION or isinstance(message.get("v"), bool):
        raise Invalid(REASON_VERSION)
    kind = message.get("kind")
    if kind not in KINDS:
        raise Invalid(REASON_INVALID)
    platform = message.get("platform", "")
    if not isinstance(platform, str) or len(platform) > MAX_PLATFORM:
        raise Invalid(REASON_INVALID)
    caps = message.get("caps") or {}
    if not isinstance(caps, dict):
        raise Invalid(REASON_INVALID)
    volume, play = caps.get("volume", False), caps.get("play", True)
    playing = message.get("playing", False)
    if not isinstance(volume, bool) or not isinstance(play, bool) or not isinstance(playing, bool):
        raise Invalid(REASON_INVALID)
    return {"kind": kind, "platform": platform, "caps": {"volume": volume, "play": play}, "playing": playing}


def state(value: Any, need_seq: bool = True) -> dict[str, Any]:
    """Prüft einen `State` und gibt ihn bereinigt zurück (nur bekannte Felder). Ungültig -> Invalid."""
    if not isinstance(value, dict):
        raise Invalid
    out: dict[str, Any] = {}
    if need_seq or value.get("seq") is not None:
        out["seq"] = _int(value.get("seq"))
    out["playing"] = _bool(value.get("playing"))
    out["position_ms"] = _int(value.get("position_ms"))
    duration = value.get("duration_ms")
    out["duration_ms"] = None if duration is None else _int(duration)
    speed = value.get("speed", 1.0)
    if not is_number(speed) or not 0 < speed <= 4:
        raise Invalid
    out["speed"] = float(speed)
    queue = value.get("queue_ids")
    if not isinstance(queue, list) or len(queue) > MAX_QUEUE:
        raise Invalid
    out["queue_ids"] = [_int(item, 1) for item in queue]
    index = value.get("index")
    if index is None:
        if queue:
            raise Invalid
        out["index"] = None
    else:
        out["index"] = _int(index, 0, len(queue) - 1)
    # Beginn des Ausschnitts in der echten Warteschlange (nur bei mehr als MAX_QUEUE Titeln > 0)
    offset = value.get("queue_offset", 0)
    out["queue_offset"] = 0 if offset is None else _int(offset, 0, MAX_QUEUE_INDEX)
    out["shuffle"] = _bool(value.get("shuffle", False))
    order = value.get("shuffle_order")
    if order is None or not out["shuffle"]:
        out["shuffle_order"] = None
    else:
        if not isinstance(order, list) or len(order) != len(queue):
            raise Invalid
        items = [_int(item, 0, max(len(queue) - 1, 0)) for item in order]
        if len(set(items)) != len(items):
            raise Invalid
        out["shuffle_order"] = items
    repeat = value.get("repeat", "off")
    if repeat not in REPEAT_MODES:
        raise Invalid
    out["repeat"] = repeat
    volume = value.get("volume")
    if volume is not None and (not is_number(volume) or not 0 <= volume <= 1):
        raise Invalid
    out["volume"] = None if volume is None else float(volume)
    out["context"] = context(value.get("context"))
    return out


def play_order(st: dict[str, Any]) -> list[int]:
    """Indizes in queue_ids in Abspielreihenfolge."""
    order = st.get("shuffle_order")
    if st.get("shuffle") and order:
        return list(order)
    return list(range(len(st["queue_ids"])))


def upcoming_ids(st: dict[str, Any]) -> list[int]:
    """Track-IDs nach dem aktuellen Titel in Abspielreihenfolge (ohne Wiederholung von vorn)."""
    index = st.get("index")
    if index is None:
        return []
    order = play_order(st)
    try:
        position = order.index(index)
    except ValueError:
        return []
    return [st["queue_ids"][i] for i in order[position + 1 :]]


def _expected_track(args: dict[str, Any]) -> dict[str, int]:
    """Optional `track_id`: welcher Titel an diesem Index erwartet wird (das Ziel prüft es)."""
    track_id = args.get("track_id")
    return {} if track_id is None else {"track_id": _int(track_id, 1)}


def command_args(action: str, args: Any) -> dict[str, Any]:
    """Prüft die Argumente eines Befehls und gibt sie bereinigt zurück. Ungültig -> Invalid."""
    if args is None:
        args = {}
    if not isinstance(args, dict):
        raise Invalid
    if action == "transfer":
        play = args.get("play")
        return {} if play is None else {"play": _bool(play)}
    if action == "play":
        ids = track_ids(args.get("track_ids"))
        out: dict[str, Any] = {"track_ids": ids, "index": _int(args.get("index", 0), 0, len(ids) - 1)}
        out["shuffle"] = _bool(args.get("shuffle", False))
        out["context"] = context(args.get("context"))
        return out
    if action in ("add_queue", "play_next"):
        return {"track_ids": track_ids(args.get("track_ids"))}
    if action in ("resume", "pause", "next", "previous", "clear_upcoming"):
        return {}
    if action == "seek":
        return {"position_ms": _int(args.get("position_ms"))}
    if action in ("skip_to", "remove_queue"):
        return {"index": _int(args.get("index"), 0, MAX_QUEUE_INDEX), **_expected_track(args)}
    if action == "set_shuffle":
        return {"enabled": _bool(args.get("enabled"))}
    if action == "set_repeat":
        mode = args.get("mode")
        if mode not in REPEAT_MODES:
            raise Invalid
        return {"mode": mode}
    if action == "set_volume":
        volume = args.get("volume")
        if not is_number(volume) or not 0 <= volume <= 1:
            raise Invalid
        return {"volume": float(volume)}
    if action == "move_queue":
        return {"from": _int(args.get("from"), 0, MAX_QUEUE_INDEX), "to": _int(args.get("to"), 0, MAX_QUEUE_INDEX),
                **_expected_track(args)}  # fmt: skip
    raise Invalid


def filter_queue(
    st: dict[str, Any], visible: set[int]
) -> tuple[list[int], int | None, list[int] | None, bool]:
    """Unsichtbare Titel aus einer Warteschlange nehmen.

    Gibt (queue_ids, index, shuffle_order, aktueller Titel erhalten) zurück. Fehlt der aktuelle Titel, wird der
    nächste verbleibende (in Listenreihenfolge) gewählt, sonst der erste."""
    kept = [(pos, tid) for pos, tid in enumerate(st["queue_ids"]) if tid in visible]
    if not kept:
        return [], None, None, False
    new_pos = {old: new for new, (old, _) in enumerate(kept)}
    index = st.get("index")
    kept_current = index is not None and index in new_pos
    if kept_current:
        new_index = new_pos[index]
    else:
        later = [new for old, new in new_pos.items() if index is not None and old > index]
        new_index = min(later) if later else 0
    order = st.get("shuffle_order")
    new_order = [new_pos[i] for i in order if i in new_pos] if order else None
    return [tid for _, tid in kept], new_index, new_order, kept_current
