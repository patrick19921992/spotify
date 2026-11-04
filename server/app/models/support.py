"""Rückmeldungen der Benutzer: Song-Wünsche und Fehlermeldungen – plus Server-Einstellungen für die App."""

from datetime import datetime

from sqlalchemy import ForeignKey, Integer, String, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, UTCDateTime, utcnow
from app.models.downloads import DownloadJob
from app.models.user import User

REQUEST_STATES = ("open", "accepted", "done", "declined")
BUG_STATES = ("new", "seen", "done")


class SongRequest(Base):
    """„Song wünschen“: Der Benutzer nennt Titel und Interpret, der Admin entscheidet."""

    __tablename__ = "song_requests"

    id: Mapped[int] = mapped_column(primary_key=True)
    # Mit dem Konto verschwindet auch der Wunsch
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    title: Mapped[str] = mapped_column(String(200))
    artist: Mapped[str] = mapped_column(String(200), default="")
    note: Mapped[str] = mapped_column(String(500), default="")
    status: Mapped[str] = mapped_column(String(10), default="open", index=True)
    admin_note: Mapped[str] = mapped_column(String(500), default="")
    # Läuft ein Download dafür, steht er hier (Status „accepted“, danach „done“)
    job_id: Mapped[int | None] = mapped_column(ForeignKey("download_jobs.id", ondelete="SET NULL"), default=None)
    handled_by_id: Mapped[int | None] = mapped_column(ForeignKey("users.id", ondelete="SET NULL"), default=None)
    created_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow, index=True)
    updated_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow, onupdate=utcnow)

    user: Mapped[User] = relationship(foreign_keys=[user_id], lazy="joined")
    job: Mapped[DownloadJob | None] = relationship(lazy="joined")


class BugReport(Base):
    """„Fehler melden“ aus der App."""

    __tablename__ = "bug_reports"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    message: Mapped[str] = mapped_column(String(4000))
    app_version: Mapped[str] = mapped_column(String(32), default="")
    app_build: Mapped[int | None] = mapped_column(Integer, default=None)
    platform: Mapped[str] = mapped_column(String(20), default="")
    channel: Mapped[str] = mapped_column(String(10), default="")
    device: Mapped[str] = mapped_column(String(200), default="")
    # Letzte Fehlermeldungen der App (optional, vom Benutzer mitgeschickt)
    log: Mapped[str] = mapped_column(Text, default="")
    status: Mapped[str] = mapped_column(String(10), default="new", index=True)
    admin_note: Mapped[str] = mapped_column(String(500), default="")
    created_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow, index=True)

    user: Mapped[User] = relationship(lazy="joined")


class AppSetting(Base):
    """Vom Admin im Dashboard änderbare Einstellungen (Schlüssel/Wert als Text)."""

    __tablename__ = "app_settings"

    key: Mapped[str] = mapped_column(String(64), primary_key=True)
    value: Mapped[str] = mapped_column(Text, default="")
    updated_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow, onupdate=utcnow)
