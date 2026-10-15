"""Bibliothek: Cover, Künstler, Alben und Titel (Songs, Hörspiele, Videos)."""

from datetime import datetime

from sqlalchemy import BigInteger, Float, ForeignKey, Integer, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, UTCDateTime, utcnow
from app.models.category import Category


class Cover(Base):
    """Ein Coverbild – gespeichert unter DATA_DIR/covers, Name = SHA1 des Bildinhalts."""

    __tablename__ = "covers"

    id: Mapped[str] = mapped_column(String(40), primary_key=True)
    width: Mapped[int] = mapped_column(Integer)
    height: Mapped[int] = mapped_column(Integer)
    # Hauptfarbe für Spotify-artige Farbverläufe in der App, z. B. "#3a6ea5"
    color: Mapped[str] = mapped_column(String(7))
    created_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)


class Artist(Base):
    __tablename__ = "artists"

    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(255))
    # Vergleichsschlüssel ("Die Ärzte" == "die ärzte")
    name_key: Mapped[str] = mapped_column(String(255), unique=True, index=True)
    sort_name: Mapped[str] = mapped_column(String(255), index=True)
    search_text: Mapped[str] = mapped_column(String(600), default="")
    cover_id: Mapped[str | None] = mapped_column(ForeignKey("covers.id", ondelete="SET NULL"), default=None)
    track_count: Mapped[int] = mapped_column(Integer, default=0, server_default="0")
    album_count: Mapped[int] = mapped_column(Integer, default=0, server_default="0")
    created_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)

    cover: Mapped[Cover | None] = relationship(lazy="joined")


class Album(Base):
    __tablename__ = "albums"
    __table_args__ = (UniqueConstraint("artist_id", "title_key", name="artist_title"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    title: Mapped[str] = mapped_column(String(255))
    title_key: Mapped[str] = mapped_column(String(255))
    sort_title: Mapped[str] = mapped_column(String(255), index=True)
    # Album-Künstler (bei Samplern z. B. "Various Artists")
    artist_id: Mapped[int] = mapped_column(ForeignKey("artists.id", ondelete="CASCADE"), index=True)
    year: Mapped[int | None] = mapped_column(Integer, default=None)
    genre: Mapped[str | None] = mapped_column(String(100), default=None)
    search_text: Mapped[str] = mapped_column(String(800), default="")
    cover_id: Mapped[str | None] = mapped_column(ForeignKey("covers.id", ondelete="SET NULL"), default=None)
    track_count: Mapped[int] = mapped_column(Integer, default=0, server_default="0")
    duration: Mapped[float] = mapped_column(Float, default=0, server_default="0")
    created_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow, index=True)

    artist: Mapped[Artist] = relationship(lazy="joined")
    cover: Mapped[Cover | None] = relationship(lazy="joined")


class Track(Base):
    """Eine Datei im Medienordner: Song, Hörspiel-Kapitel oder Video."""

    __tablename__ = "tracks"

    id: Mapped[int] = mapped_column(primary_key=True)
    category_id: Mapped[int] = mapped_column(ForeignKey("categories.id", ondelete="CASCADE"), index=True)
    # Pfad relativ zu MEDIA_DIR, z. B. "Musik/Queen/A Night at the Opera/01 Bohemian Rhapsody.opus"
    path: Mapped[str] = mapped_column(String(1024), unique=True)
    media_type: Mapped[str] = mapped_column(String(10), index=True)

    title: Mapped[str] = mapped_column(String(255))
    sort_title: Mapped[str] = mapped_column(String(255), index=True)
    # Anzeige wie in den Tags, z. B. "Daft Punk feat. Pharrell Williams"
    artist_display: Mapped[str] = mapped_column(String(512))
    album_id: Mapped[int | None] = mapped_column(ForeignKey("albums.id", ondelete="SET NULL"), index=True)
    track_number: Mapped[int | None] = mapped_column(Integer, default=None)
    disc_number: Mapped[int | None] = mapped_column(Integer, default=None)
    year: Mapped[int | None] = mapped_column(Integer, default=None)
    genre: Mapped[str | None] = mapped_column(String(100), default=None)
    search_text: Mapped[str] = mapped_column(String(1500), default="")

    duration: Mapped[float] = mapped_column(Float, default=0)
    bitrate: Mapped[int | None] = mapped_column(Integer, default=None)  # kbit/s
    sample_rate: Mapped[int | None] = mapped_column(Integer, default=None)
    codec: Mapped[str | None] = mapped_column(String(32), default=None)
    width: Mapped[int | None] = mapped_column(Integer, default=None)
    height: Mapped[int | None] = mapped_column(Integer, default=None)
    file_size: Mapped[int] = mapped_column(BigInteger)
    file_mtime: Mapped[float] = mapped_column(Float)
    cover_id: Mapped[str | None] = mapped_column(ForeignKey("covers.id", ondelete="SET NULL"), default=None)

    # Herkunft – "local" oder später "youtube" (mit YouTube-ID)
    source: Mapped[str] = mapped_column(String(16), default="local", server_default="local")
    source_id: Mapped[str | None] = mapped_column(String(64), default=None, index=True)

    added_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow, index=True)
    updated_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow, onupdate=utcnow)

    category: Mapped[Category] = relationship(lazy="joined")
    album: Mapped[Album | None] = relationship(lazy="joined")
    cover: Mapped[Cover | None] = relationship(lazy="joined")
    artist_links: Mapped[list["TrackArtist"]] = relationship(
        lazy="selectin",
        cascade="all, delete-orphan",
        passive_deletes=True,
        order_by="TrackArtist.position",
    )


class TrackArtist(Base):
    """Alle beteiligten Künstler eines Titels (Hauptkünstler + "feat.")."""

    __tablename__ = "track_artists"

    track_id: Mapped[int] = mapped_column(ForeignKey("tracks.id", ondelete="CASCADE"), primary_key=True)
    artist_id: Mapped[int] = mapped_column(ForeignKey("artists.id", ondelete="CASCADE"), primary_key=True, index=True)
    position: Mapped[int] = mapped_column(Integer, default=0)

    artist: Mapped[Artist] = relationship(lazy="joined")
