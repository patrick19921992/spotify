"""Alle Datenbank-Modelle – hier importieren, damit Alembic sie findet."""

from app.models.base import Base, utcnow
from app.models.category import MEDIA_TYPES, Category
from app.models.downloads import ACTIVE_STATES, JOB_STATES, DownloadJob
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
from app.models.premium import PURCHASE_STATES, PlayPurchase, PremiumCode, PremiumLicense
from app.models.support import BUG_STATES, REQUEST_STATES, AppSetting, BugReport, SongRequest
from app.models.user import User, UserSession, user_categories

__all__ = [
    "ACTIVE_STATES",
    "BUG_STATES",
    "JOB_STATES",
    "MEDIA_TYPES",
    "PURCHASE_STATES",
    "REQUEST_STATES",
    "Album",
    "AlbumSave",
    "AppSetting",
    "Artist",
    "ArtistFollow",
    "Base",
    "BugReport",
    "Category",
    "Cover",
    "DownloadJob",
    "PlayHistory",
    "PlayPurchase",
    "Playlist",
    "PlaylistFollow",
    "PlaylistItem",
    "PremiumCode",
    "PremiumLicense",
    "SongRequest",
    "Track",
    "TrackArtist",
    "TrackLike",
    "User",
    "UserSession",
    "user_categories",
    "utcnow",
]
