"""Persönliches: Playlists, Lieblingssongs, gespeicherte Alben/Künstler und Hörverlauf."""

from datetime import datetime

from sqlalchemy import Boolean, Float, ForeignKey, Index, Integer, String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, UTCDateTime, utcnow
from app.models.library import Album, Artist, Cover, Track
from app.models.user import User


class Playlist(Base):
    __tablename__ = "playlists"

    id: Mapped[int] = mapped_column(primary_key=True)
    owner_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    name: Mapped[str] = mapped_column(String(100))
    description: Mapped[str] = mapped_column(String(500), default="")
    # Eigenes hochgeladenes Cover – sonst zeigt die App ein 2×2-Mosaik der ersten Alben
    cover_id: Mapped[str | None] = mapped_column(ForeignKey("covers.id", ondelete="SET NULL"), default=None)
    # Für die Familie sichtbar (andere können sie hören und folgen)
    is_public: Mapped[bool] = mapped_column(Boolean, default=False, server_default="0")
    # Gemeinsame Playlist: alle dürfen Titel hinzufügen/entfernen
    is_collaborative: Mapped[bool] = mapped_column(Boolean, default=False, server_default="0")
    track_count: Mapped[int] = mapped_column(Integer, default=0, server_default="0")
    duration: Mapped[float] = mapped_column(Float, default=0, server_default="0")
    created_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)
    updated_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow, onupdate=utcnow)

    owner: Mapped[User] = relationship(lazy="joined")
    cover: Mapped[Cover | None] = relationship(lazy="joined")


class PlaylistItem(Base):
    __tablename__ = "playlist_items"
    __table_args__ = (Index("ix_playlist_items_playlist_position", "playlist_id", "position"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    playlist_id: Mapped[int] = mapped_column(ForeignKey("playlists.id", ondelete="CASCADE"))
    track_id: Mapped[int] = mapped_column(ForeignKey("tracks.id", ondelete="CASCADE"), index=True)
    position: Mapped[int] = mapped_column(Integer)
    added_by_id: Mapped[int | None] = mapped_column(ForeignKey("users.id", ondelete="SET NULL"), default=None)
    added_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)

    track: Mapped[Track] = relationship(lazy="joined")
    added_by: Mapped[User | None] = relationship(lazy="joined")


class PlaylistFollow(Base):
    """Playlists anderer Familienmitglieder in der eigenen Bibliothek."""

    __tablename__ = "playlist_follows"

    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    playlist_id: Mapped[int] = mapped_column(ForeignKey("playlists.id", ondelete="CASCADE"), primary_key=True)
    created_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)


class TrackLike(Base):
    """Lieblingssongs (Herz)."""

    __tablename__ = "track_likes"

    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    track_id: Mapped[int] = mapped_column(ForeignKey("tracks.id", ondelete="CASCADE"), primary_key=True, index=True)
    created_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow, index=True)

    track: Mapped[Track] = relationship(lazy="joined")


class AlbumSave(Base):
    __tablename__ = "album_saves"

    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    album_id: Mapped[int] = mapped_column(ForeignKey("albums.id", ondelete="CASCADE"), primary_key=True, index=True)
    created_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)

    album: Mapped[Album] = relationship(lazy="joined")


class ArtistFollow(Base):
    __tablename__ = "artist_follows"

    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    artist_id: Mapped[int] = mapped_column(ForeignKey("artists.id", ondelete="CASCADE"), primary_key=True, index=True)
    created_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)

    artist: Mapped[Artist] = relationship(lazy="joined")


class PlayHistory(Base):
    """Ein abgespielter Titel. Grundlage für "Zuletzt gehört", Top-Songs und "Beliebt in der Familie"."""

    __tablename__ = "play_history"
    __table_args__ = (
        Index("ix_play_history_user_played", "user_id", "played_at"),
        Index("ix_play_history_track_played", "track_id", "played_at"),
    )

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    track_id: Mapped[int] = mapped_column(ForeignKey("tracks.id", ondelete="CASCADE"))
    played_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)
    seconds: Mapped[float] = mapped_column(Float, default=0)
    # Woher wurde abgespielt? z. B. "album" + Album-ID, "playlist" + Playlist-ID, "liked"
    context_type: Mapped[str | None] = mapped_column(String(16), default=None)
    context_id: Mapped[int | None] = mapped_column(Integer, default=None)
