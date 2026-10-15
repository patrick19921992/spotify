"""Download-Aufträge (YouTube → Bibliothek)."""

from datetime import datetime

from sqlalchemy import JSON, BigInteger, Float, ForeignKey, Integer, String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, UTCDateTime, utcnow
from app.models.user import User

JOB_STATES = ("queued", "downloading", "processing", "done", "failed", "cancelled")
ACTIVE_STATES = ("queued", "downloading", "processing")


class DownloadJob(Base):
    __tablename__ = "download_jobs"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int | None] = mapped_column(ForeignKey("users.id", ondelete="SET NULL"), index=True)
    category_id: Mapped[int] = mapped_column(ForeignKey("categories.id", ondelete="CASCADE"))
    media_type: Mapped[str] = mapped_column(String(10))
    video_id: Mapped[str] = mapped_column(String(32), index=True)

    # Angaben von YouTube Music (für Tags und Ordnernamen)
    title: Mapped[str] = mapped_column(String(255), default="")
    artists: Mapped[list[str]] = mapped_column(JSON, default=list)
    album: Mapped[str | None] = mapped_column(String(255), default=None)
    album_artist: Mapped[str | None] = mapped_column(String(255), default=None)
    track_number: Mapped[int | None] = mapped_column(Integer, default=None)
    year: Mapped[int | None] = mapped_column(Integer, default=None)
    thumbnail_url: Mapped[str | None] = mapped_column(String(1000), default=None)

    status: Mapped[str] = mapped_column(String(16), default="queued", index=True)
    progress: Mapped[float] = mapped_column(Float, default=0)
    downloaded_bytes: Mapped[int] = mapped_column(BigInteger, default=0)
    total_bytes: Mapped[int | None] = mapped_column(BigInteger, default=None)
    speed: Mapped[float | None] = mapped_column(Float, default=None)
    eta: Mapped[int | None] = mapped_column(Integer, default=None)
    error: Mapped[str | None] = mapped_column(String(1000), default=None)

    track_id: Mapped[int | None] = mapped_column(ForeignKey("tracks.id", ondelete="SET NULL"), default=None)
    # Nach dem Download automatisch in diese Playlist legen
    playlist_id: Mapped[int | None] = mapped_column(ForeignKey("playlists.id", ondelete="SET NULL"), default=None)

    created_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow, index=True)
    started_at: Mapped[datetime | None] = mapped_column(UTCDateTime, default=None)
    finished_at: Mapped[datetime | None] = mapped_column(UTCDateTime, default=None)

    user: Mapped[User | None] = relationship(lazy="joined")
