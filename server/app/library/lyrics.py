"""Songtexte lesen: LRC-Datei neben dem Titel (z. B. "Titel.lrc") oder in die Datei eingebettet."""

import re
from pathlib import Path

import mutagen

_LRC_LINE = re.compile(r"^\s*((?:\[\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?\])+)(.*)$")
_LRC_TIME = re.compile(r"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]")


def parse_lrc(text: str) -> list[tuple[int | None, str]]:
    """LRC-Text -> [(Startzeit in ms, Zeile)], sortiert. Zeilen ohne Zeitstempel ergeben (None, Text)."""
    timed: list[tuple[int | None, str]] = []
    plain: list[tuple[int | None, str]] = []
    for raw in text.splitlines():
        match = _LRC_LINE.match(raw)
        if not match:
            if raw.strip() and not re.match(r"^\s*\[[a-z]+:", raw, re.IGNORECASE):
                plain.append((None, raw.strip()))
            continue
        content = match.group(2).strip()
        for minutes, seconds, fraction in _LRC_TIME.findall(match.group(1)):
            ms = int(minutes) * 60000 + int(seconds) * 1000
            if fraction:
                ms += int(fraction.ljust(3, "0")[:3])
            timed.append((ms, content))
    if timed:
        return sorted(timed, key=lambda line: line[0] or 0)
    return plain


def _embedded(path: Path) -> str | None:
    try:
        audio = mutagen.File(path)
    except Exception:  # noqa: BLE001
        return None
    if audio is None or audio.tags is None:
        return None
    tags = audio.tags
    type_name = type(tags).__name__
    if type_name == "ID3":
        frames = tags.getall("USLT")
        return str(frames[0].text) if frames else None
    if type_name == "MP4Tags":
        values = tags.get("\xa9lyr")
        return str(values[0]) if values else None
    if hasattr(tags, "get"):
        for key in ("lyrics", "unsyncedlyrics", "LYRICS", "UNSYNCEDLYRICS"):
            values = tags.get(key)
            if values:
                return str(values[0])
    return None


def read_lyrics(media_file: Path) -> tuple[bool, list[tuple[int | None, str]], str] | None:
    """(zeitsynchron?, Zeilen, Quelle) – oder None, wenn es keinen Songtext gibt."""
    for candidate in (media_file.with_suffix(".lrc"), media_file.with_suffix(".LRC")):
        if candidate.is_file():
            lines = parse_lrc(candidate.read_text(encoding="utf-8", errors="replace"))
            if lines:
                return any(t is not None for t, _ in lines), lines, "lrc"
    text = _embedded(media_file)
    if text:
        lines = parse_lrc(text)
        if lines:
            return any(t is not None for t, _ in lines), lines, "tags"
    return None
