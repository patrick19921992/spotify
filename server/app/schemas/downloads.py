"""Schemas für YouTube-Suche und Downloads."""

from datetime import datetime
from typing import Annotated, Literal

from pydantic import BaseModel, Field, StringConstraints

from app.schemas.personal import UserRef

VideoId = Annotated[str, StringConstraints(pattern=r"^[A-Za-z0-9_-]{11}$")]
BrowseId = Annotated[str, StringConstraints(pattern=r"^[A-Za-z0-9_-]{5,64}$")]
JobStatus = Literal["queued", "downloading", "processing", "done", "failed", "cancelled"]
MediaType = Literal["audio", "video"]


class YouTubeItemOut(BaseModel):
    type: Literal["song", "video", "album"]
    title: str
    artists: list[str]
    video_id: str | None
    browse_id: str | None
    album: str | None
    album_browse_id: str | None
    duration: float | None
    year: int | None
    thumbnail_url: str | None
    explicit: bool
    track_number: int | None = None
    # Schon in der Bibliothek? Dann direkt abspielen statt herunterladen
    in_library_track_id: int | None = None
    # Läuft gerade ein Download dafür?
    active_job_id: int | None = None


class YouTubeSearchOut(BaseModel):
    query: str
    type: str
    results: list[YouTubeItemOut]


class YouTubeAlbumOut(BaseModel):
    browse_id: str
    title: str
    artists: list[str]
    year: int | None
    thumbnail_url: str | None
    tracks: list[YouTubeItemOut]


class JobOut(BaseModel):
    id: int
    status: JobStatus
    media_type: MediaType
    video_id: str
    title: str
    artists: list[str]
    album: str | None
    thumbnail_url: str | None
    category_id: int
    # 0.0 – 1.0
    progress: float
    downloaded_bytes: int
    total_bytes: int | None
    # Bytes pro Sekunde
    speed: float | None
    # Restzeit in Sekunden
    eta: int | None
    # Wie viele Aufträge noch davor warten
    queue_position: int | None
    error: str | None
    track_id: int | None
    playlist_id: int | None
    user: UserRef | None
    created_at: datetime
    started_at: datetime | None
    finished_at: datetime | None


class DownloadIn(BaseModel):
    video_id: VideoId
    media_type: MediaType = "audio"
    # Leer = Standard-Rubrik des Medientyps
    category_id: int | None = None
    playlist_id: int | None = None
    # Angaben aus der YouTube-Music-Suche (optional; sonst liefert yt-dlp sie)
    title: Annotated[str, StringConstraints(max_length=255)] | None = None
    artists: list[Annotated[str, StringConstraints(max_length=255)]] = Field(default_factory=list, max_length=20)
    album: Annotated[str, StringConstraints(max_length=255)] | None = None
    track_number: int | None = Field(default=None, ge=1, le=999)
    year: int | None = Field(default=None, ge=1800, le=2100)
    thumbnail_url: Annotated[str, StringConstraints(max_length=1000)] | None = None


class AlbumDownloadIn(BaseModel):
    browse_id: BrowseId
    category_id: int | None = None
    playlist_id: int | None = None


class UrlDownloadIn(BaseModel):
    url: Annotated[str, StringConstraints(strip_whitespace=True, max_length=1000)]
    media_type: MediaType = "audio"
    category_id: int | None = None
    playlist_id: int | None = None


class DownloaderStatusOut(BaseModel):
    ytdlp_version: str | None
    deno_available: bool
    ffmpeg_available: bool
    cookies_configured: bool
    auto_update: bool
    last_update: datetime | None
    last_update_result: str | None
    workers: int
    audio_format: str
    video_codec: str
    video_max_height: int
    active_jobs: int
    queued_jobs: int


class LyricsLineOut(BaseModel):
    time_ms: int | None
    text: str


class LyricsOut(BaseModel):
    synced: bool
    source: str | None
    lines: list[LyricsLineOut]
