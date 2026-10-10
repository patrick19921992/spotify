"""Schemas für Playlists, Lieblingssongs, Bibliothek, Verlauf und Startseite."""

from datetime import datetime
from typing import Annotated, Literal

from pydantic import BaseModel, Field, StringConstraints

from app.schemas.library import AlbumOut, ArtistOut, TrackOut

PlaylistName = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=100)]
Description = Annotated[str, StringConstraints(strip_whitespace=True, max_length=500)]
ContextType = Literal["album", "playlist", "artist", "liked", "mix", "radio", "search", "category", "queue"]


class UserRef(BaseModel):
    id: int
    display_name: str


class PlaylistOut(BaseModel):
    id: int
    name: str
    description: str
    owner: UserRef
    is_public: bool
    is_collaborative: bool
    track_count: int
    duration: float
    # Eigenes Cover (falls hochgeladen) – sonst Mosaik aus bis zu 4 Album-Covern
    cover_id: str | None
    mosaic: list[str]
    cover_color: str | None
    created_at: datetime
    updated_at: datetime
    is_owner: bool
    is_following: bool
    can_edit: bool


class PlaylistItemOut(BaseModel):
    item_id: int
    position: int
    added_at: datetime
    added_by: UserRef | None
    track: TrackOut


class PlaylistDetailOut(PlaylistOut):
    items: list[PlaylistItemOut]


class PlaylistCreateIn(BaseModel):
    name: PlaylistName
    description: Description = ""
    is_public: bool = False
    is_collaborative: bool = False
    track_ids: list[int] = Field(default_factory=list, max_length=1000)


class PlaylistUpdateIn(BaseModel):
    name: PlaylistName | None = None
    description: Description | None = None
    is_public: bool | None = None
    is_collaborative: bool | None = None


class PlaylistAddIn(BaseModel):
    track_ids: list[int] = Field(min_length=1, max_length=1000)
    # None = ans Ende
    position: int | None = Field(default=None, ge=0)


class PlaylistRemoveIn(BaseModel):
    item_ids: list[int] = Field(min_length=1, max_length=1000)


class PlaylistMoveIn(BaseModel):
    item_id: int
    position: int = Field(ge=0)


class LikedTrackOut(BaseModel):
    liked_at: datetime
    track: TrackOut


class LikedIdsOut(BaseModel):
    """Alles, was der Benutzer gespeichert hat – damit die App Herzen/Häkchen sofort richtig anzeigt."""

    tracks: list[int]
    albums: list[int]
    artists: list[int]
    playlists: list[int]


class LibraryOut(BaseModel):
    """Die Bibliothek wie bei Spotify: Lieblingssongs, Playlists, Alben, Künstler."""

    liked_count: int
    playlists: list[PlaylistOut]
    albums: list[AlbumOut]
    artists: list[ArtistOut]


class HistoryIn(BaseModel):
    track_id: int
    # Wie lange wirklich gehört wurde – ab 30 s zählt es für Statistiken (wie bei Spotify)
    seconds: float = Field(ge=0, le=24 * 3600)
    context_type: ContextType | None = None
    context_id: int | None = None


class HistoryEntryOut(BaseModel):
    played_at: datetime
    seconds: float
    context_type: str | None
    context_id: int | None
    track: TrackOut


class ContextOut(BaseModel):
    """Ein Kachel-Eintrag auf der Startseite (Album, Playlist, Künstler, Lieblingssongs, Mix)."""

    type: Literal["album", "playlist", "artist", "liked", "mix"]
    id: str
    title: str
    subtitle: str
    cover_id: str | None
    mosaic: list[str] = []
    cover_color: str | None = None


class MixOut(BaseModel):
    key: str
    title: str
    subtitle: str
    cover_id: str | None
    mosaic: list[str]
    cover_color: str | None
    tracks: list[TrackOut]


class HomeSection(BaseModel):
    key: str
    title: str
    kind: Literal["contexts", "tracks", "albums", "artists", "videos"]
    contexts: list[ContextOut] = []
    tracks: list[TrackOut] = []
    albums: list[AlbumOut] = []
    artists: list[ArtistOut] = []


class HomeOut(BaseModel):
    quick_access: list[ContextOut]
    sections: list[HomeSection]
