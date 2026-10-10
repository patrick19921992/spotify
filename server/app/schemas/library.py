"""Schemas für Bibliothek, Suche und Scan."""

from datetime import datetime
from typing import Literal

from pydantic import BaseModel


class Page[T](BaseModel):
    items: list[T]
    total: int
    limit: int
    offset: int


class ArtistRef(BaseModel):
    id: int
    name: str


class AlbumRef(BaseModel):
    id: int
    title: str


class TrackOut(BaseModel):
    id: int
    title: str
    artist_display: str
    artists: list[ArtistRef]
    album: AlbumRef | None
    category_id: int
    media_type: Literal["audio", "video"]
    duration: float
    track_number: int | None
    disc_number: int | None
    year: int | None
    genre: str | None
    codec: str | None
    bitrate: int | None
    width: int | None
    height: int | None
    file_size: int
    cover_id: str | None
    cover_color: str | None
    source: str
    added_at: datetime


class AlbumOut(BaseModel):
    id: int
    title: str
    artist: ArtistRef
    year: int | None
    genre: str | None
    track_count: int
    duration: float
    cover_id: str | None
    cover_color: str | None
    added_at: datetime


class AlbumDetailOut(AlbumOut):
    tracks: list[TrackOut]


class ArtistOut(BaseModel):
    id: int
    name: str
    track_count: int
    album_count: int
    cover_id: str | None
    cover_color: str | None


class ArtistDetailOut(ArtistOut):
    # Wie bei Spotify: beliebte Titel, eigene Alben, "Enthalten auf", Videos
    top_tracks: list[TrackOut]
    albums: list[AlbumOut]
    appears_on: list[AlbumOut]
    videos: list[TrackOut]


class TopResult(BaseModel):
    type: Literal["artist", "album", "track", "video"]
    artist: ArtistOut | None = None
    album: AlbumOut | None = None
    track: TrackOut | None = None


class SearchOut(BaseModel):
    query: str
    top_result: TopResult | None
    tracks: list[TrackOut]
    artists: list[ArtistOut]
    albums: list[AlbumOut]
    videos: list[TrackOut]


class ScanStatusOut(BaseModel):
    running: bool
    started_at: datetime | None
    finished_at: datetime | None
    files_seen: int
    added: int
    updated: int
    removed: int
    errors: int
    last_error: str | None
    error_files: list[str]


class LibraryStatsOut(BaseModel):
    tracks: int
    videos: int
    artists: int
    albums: int
    total_duration: float
    total_size: int
    scan: ScanStatusOut


class ScanRequestIn(BaseModel):
    category_id: int | None = None
    # true = Antwort erst nach Ende des Scans (für Skripte/Tests)
    wait: bool = False
