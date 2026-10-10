"""Suche und Metadaten über YouTube Music (ytmusicapi) – liefert saubere Titel, Künstler, Alben und Cover."""

import logging
import re
import threading
from dataclasses import dataclass, field
from typing import Any
from urllib.parse import urlparse

logger = logging.getLogger(__name__)

VIDEO_ID = re.compile(r"^[A-Za-z0-9_-]{11}$")
BROWSE_ID = re.compile(r"^[A-Za-z0-9_-]{5,64}$")
# Nur Bilder von YouTube-/Google-Servern laden (kein Zugriff auf beliebige Adressen)
THUMBNAIL_HOSTS = ("ytimg.com", "ggpht.com", "googleusercontent.com")
YOUTUBE_HOSTS = {"youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be"}


class YouTubeError(RuntimeError):
    """YouTube Music nicht erreichbar oder unerwartete Antwort."""


def is_allowed_thumbnail(url: str | None) -> bool:
    if not url:
        return False
    parsed = urlparse(url)
    host = (parsed.hostname or "").lower()
    return parsed.scheme == "https" and any(host == h or host.endswith("." + h) for h in THUMBNAIL_HOSTS)


def is_youtube_url(url: str) -> bool:
    parsed = urlparse(url.strip())
    return parsed.scheme in ("http", "https") and (parsed.hostname or "").lower() in YOUTUBE_HOSTS


def best_thumbnail(thumbnails: list[dict[str, Any]] | None, square_size: int = 1200) -> str | None:
    """Größtes Vorschaubild; Google-Cover in hoher Auflösung anfordern (=w1200-h1200)."""
    if not thumbnails:
        return None
    best = max(thumbnails, key=lambda t: (t.get("width") or 0) * (t.get("height") or 0))
    url = best.get("url")
    if not url:
        return None
    if "googleusercontent.com" in url or "ggpht.com" in url:
        url = re.sub(r"=w\d+-h\d+", f"=w{square_size}-h{square_size}", url)
    return url if is_allowed_thumbnail(url) else None


def _artist_names(item: dict[str, Any]) -> list[str]:
    names = [a.get("name", "").strip() for a in item.get("artists") or [] if a.get("name")]
    return [n for n in names if n and not re.fullmatch(r"[\d.,]+\s*(Mio\.|K|M|views|Aufrufe).*", n)]


def _year(value: Any) -> int | None:
    match = re.search(r"(19|20)\d{2}", str(value or ""))
    return int(match.group()) if match else None


@dataclass
class YouTubeItem:
    type: str  # "song" | "video" | "album"
    title: str
    artists: list[str] = field(default_factory=list)
    video_id: str | None = None
    browse_id: str | None = None
    album: str | None = None
    album_browse_id: str | None = None
    duration: float | None = None
    year: int | None = None
    thumbnail_url: str | None = None
    explicit: bool = False
    track_number: int | None = None


@dataclass
class YouTubeAlbum:
    browse_id: str
    title: str
    artists: list[str]
    year: int | None
    thumbnail_url: str | None
    tracks: list[YouTubeItem]


@dataclass
class LyricsResult:
    synced: bool
    lines: list[tuple[int | None, str]]  # (Startzeit in ms oder None, Text)
    source: str | None = None

    def to_lrc(self) -> str:
        if not self.synced:
            return "\n".join(text for _, text in self.lines) + "\n"
        out = []
        for start, text in self.lines:
            ms = start or 0
            out.append(f"[{ms // 60000:02d}:{(ms // 1000) % 60:02d}.{(ms % 1000) // 10:02d}]{text}")
        return "\n".join(out) + "\n"


def parse_item(raw: dict[str, Any]) -> YouTubeItem | None:
    result_type = raw.get("resultType") or ("album" if raw.get("browseId") and not raw.get("videoId") else "song")
    if result_type not in ("song", "video", "album"):
        return None
    album = raw.get("album") or {}
    item = YouTubeItem(
        type=result_type,
        title=(raw.get("title") or "").strip(),
        artists=_artist_names(raw),
        video_id=raw.get("videoId"),
        browse_id=raw.get("browseId"),
        album=(album.get("name") if isinstance(album, dict) else None) or None,
        album_browse_id=album.get("id") if isinstance(album, dict) else None,
        duration=raw.get("duration_seconds"),
        year=_year(raw.get("year")),
        thumbnail_url=best_thumbnail(raw.get("thumbnails")),
        explicit=bool(raw.get("isExplicit")),
        track_number=raw.get("trackNumber"),
    )
    if not item.title:
        return None
    if item.type in ("song", "video") and not (item.video_id and VIDEO_ID.match(item.video_id)):
        return None
    if item.type == "album" and not (item.browse_id and BROWSE_ID.match(item.browse_id)):
        return None
    return item


class YouTubeMusic:
    """Dünne Hülle um ytmusicapi (wird in Tests durch eine Attrappe ersetzt)."""

    def __init__(self, language: str = "de", location: str = "DE") -> None:
        self.language = language
        self.location = location
        self._client: Any = None
        self._lock = threading.Lock()

    def _api(self) -> Any:
        if self._client is None:
            from ytmusicapi import YTMusic

            try:
                self._client = YTMusic(language=self.language, location=self.location)
            except Exception:  # noqa: BLE001 – unbekannte Sprache -> Standard
                self._client = YTMusic()
        return self._client

    def _call(self, method: str, *args: Any, **kwargs: Any) -> Any:
        with self._lock:
            try:
                return getattr(self._api(), method)(*args, **kwargs)
            except Exception as exc:  # noqa: BLE001
                logger.warning("YouTube Music: %s fehlgeschlagen: %s", method, exc)
                raise YouTubeError(f"YouTube Music ist gerade nicht erreichbar ({exc.__class__.__name__}).") from exc

    def search(self, query: str, kind: str, limit: int) -> list[YouTubeItem]:
        raw = self._call("search", query, filter=kind, limit=limit) or []
        items = [parse_item(r) for r in raw]
        return [i for i in items if i is not None][:limit]

    def album(self, browse_id: str) -> YouTubeAlbum:
        raw = self._call("get_album", browse_id) or {}
        artists = _artist_names(raw)
        thumbnail = best_thumbnail(raw.get("thumbnails"))
        tracks: list[YouTubeItem] = []
        for index, track in enumerate(raw.get("tracks") or [], start=1):
            if track.get("isAvailable") is False or not track.get("videoId"):
                continue
            item = parse_item({**track, "resultType": "song"})
            if item is None:
                continue
            item.album = raw.get("title")
            item.album_browse_id = browse_id
            item.artists = item.artists or artists
            item.track_number = track.get("trackNumber") or index
            item.thumbnail_url = thumbnail or item.thumbnail_url
            item.year = _year(raw.get("year"))
            tracks.append(item)
        return YouTubeAlbum(
            browse_id=browse_id,
            title=(raw.get("title") or "").strip(),
            artists=artists,
            year=_year(raw.get("year")),
            thumbnail_url=thumbnail,
            tracks=tracks,
        )

    def lyrics(self, video_id: str) -> LyricsResult | None:
        watch = self._call("get_watch_playlist", video_id, limit=1) or {}
        browse_id = watch.get("lyrics")
        if not browse_id:
            return None
        raw = self._call("get_lyrics", browse_id, True)
        if not raw or not raw.get("lyrics"):
            return None
        if raw.get("hasTimestamps"):
            lines = [(int(getattr(line, "start_time", 0)), str(getattr(line, "text", ""))) for line in raw["lyrics"]]
            return LyricsResult(synced=True, lines=lines, source=raw.get("source"))
        text = str(raw["lyrics"])
        return LyricsResult(synced=False, lines=[(None, line) for line in text.splitlines()], source=raw.get("source"))
