"""Alle Datenbank-Modelle – hier importieren, damit Alembic sie findet."""

from app.models.base import Base, utcnow
from app.models.category import MEDIA_TYPES, Category
from app.models.library import Album, Artist, Cover, Track, TrackArtist
from app.models.personal import (
    AlbumSave,
    ArtistFollow,
    PlayHistory,
    Playlist,
    PlaylistFollow,
    PlaylistItem,
    TrackLike,
)
from app.models.user import User, UserSession

__all__ = [
    "MEDIA_TYPES",
    "Album",
    "AlbumSave",
    "Artist",
    "ArtistFollow",
    "Base",
    "Category",
    "Cover",
    "PlayHistory",
    "Playlist",
    "PlaylistFollow",
    "PlaylistItem",
    "Track",
    "TrackArtist",
    "TrackLike",
    "User",
    "UserSession",
    "utcnow",
]
