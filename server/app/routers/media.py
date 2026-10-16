"""Streams und Cover. Erlaubt zusätzlich den Medien-Token im Link (?t=…), damit Player ohne Header auskommen."""

import mimetypes
from pathlib import Path
from typing import Annotated, Literal

from fastapi import APIRouter, HTTPException, Query, Request, status
from fastapi.responses import FileResponse

from app.deps import AppSettings, DbSession, MediaAuth
from app.library.covers import COVER_SIZES
from app.library.transcode import QUALITY_BITRATES, TranscodeUnavailableError, needs_transcode
from app.models import Cover, Track

router = APIRouter(tags=["Streaming"])

MIME_TYPES = {
    ".mp3": "audio/mpeg",
    ".m4a": "audio/mp4",
    ".m4b": "audio/mp4",
    ".aac": "audio/aac",
    ".opus": "audio/ogg",
    ".ogg": "audio/ogg",
    ".oga": "audio/ogg",
    ".flac": "audio/flac",
    ".wav": "audio/wav",
    ".wma": "audio/x-ms-wma",
    ".mp4": "video/mp4",
    ".m4v": "video/mp4",
    ".mkv": "video/x-matroska",
    ".mov": "video/quicktime",
}


def media_type_for(path: Path, kind: str) -> str:
    suffix = path.suffix.lower()
    if suffix == ".webm":
        return "audio/webm" if kind == "audio" else "video/webm"
    return MIME_TYPES.get(suffix) or mimetypes.guess_type(path.name)[0] or "application/octet-stream"


@router.get("/tracks/{track_id}/stream")
def stream_track(
    track_id: int,
    request: Request,
    _: MediaAuth,
    db: DbSession,
    settings: AppSettings,
    quality: Literal["original", "high", "normal", "low"] = "original",
    compatible: Annotated[
        bool, Query(description="true = nur Formate, die auch iPhones abspielen (Opus/Ogg -> AAC)")
    ] = False,
    audio_only: Annotated[
        bool, Query(description="true = bei Videos nur den Ton als AAC (Video in einer Musik-Warteschlange)")
    ] = False,
) -> FileResponse:
    """Liefert die Datei mit Spulen (HTTP Range). Bei Bedarf als AAC umgewandelt (Datensparmodus/iPhone)."""
    track = db.get(Track, track_id)
    if track is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Titel nicht gefunden.")
    media_root = settings.media_dir.resolve()
    path = (settings.media_dir / track.path).resolve()
    if not path.is_relative_to(media_root) or not path.is_file():
        request.app.state.scanner.request_scan([track.category_id])
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Datei nicht mehr vorhanden – die Bibliothek wird aktualisiert.")

    kind, codec, track_bitrate = track.media_type, track.codec, track.bitrate
    version = f"{track.file_size}-{track.file_mtime}"
    # Datenbank-Verbindung sofort freigeben: Sonst bliebe sie bis zum letzten gesendeten Byte belegt –
    # ein paar pausierte Videos oder Hörbücher würden alle Verbindungen blockieren.
    db.close()

    headers = {"Cache-Control": "private, max-age=86400"}
    bitrate: int | None = None
    if kind == "audio":
        bitrate = needs_transcode(codec, path.suffix, track_bitrate, quality, compatible)
    elif audio_only:
        # Video in Lieblingssongs/Playlist: nur die Tonspur – spart gegenüber dem ganzen Video viel Datenvolumen
        bitrate = QUALITY_BITRATES.get(quality, QUALITY_BITRATES["normal"])
    if bitrate is not None:
        try:
            converted = request.app.state.transcoder.get(path, version, bitrate)
        except TranscodeUnavailableError as exc:
            raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, str(exc)) from None
        return FileResponse(converted, media_type="audio/mp4", headers=headers, content_disposition_type="inline")
    return FileResponse(path, media_type=media_type_for(path, kind), headers=headers, content_disposition_type="inline")


@router.get("/covers/{cover_id}")
def get_cover(
    cover_id: str,
    request: Request,
    _: MediaAuth,
    db: DbSession,
    size: Annotated[int, Query(description=f"0 = Original, sonst eine von {COVER_SIZES}")] = 300,
) -> FileResponse:
    if len(cover_id) != 40 or any(c not in "0123456789abcdef" for c in cover_id):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Cover nicht gefunden.")
    if size and size not in COVER_SIZES:
        size = min(COVER_SIZES, key=lambda s: abs(s - size))
    if db.get(Cover, cover_id) is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Cover nicht gefunden.")
    db.close()  # Verbindung nicht bis zum Ende der Übertragung belegen
    path = request.app.state.covers.path_for(cover_id, size or None)
    if path is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Cover nicht gefunden.")
    # Cover-IDs sind Prüfsummen des Inhalts -> dürfen dauerhaft zwischengespeichert werden
    return FileResponse(
        path,
        media_type="image/jpeg",
        headers={"Cache-Control": "private, max-age=31536000, immutable"},
        content_disposition_type="inline",
    )
