"""Rubriken – jede Rubrik ist ein eigener Ordner im Medienverzeichnis auf dem Unraid."""

from datetime import datetime

from sqlalchemy import Boolean, CheckConstraint, Integer, String
from sqlalchemy.orm import Mapped, mapped_column

from app.models.base import Base, UTCDateTime, utcnow

MEDIA_TYPES = ("audio", "video")


class Category(Base):
    __tablename__ = "categories"
    __table_args__ = (CheckConstraint("media_type IN ('audio', 'video')", name="media_type"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(64), unique=True)
    slug: Mapped[str] = mapped_column(String(64), unique=True, index=True)
    # Relativer Pfad unterhalb von MEDIA_DIR, z. B. "Musik" oder "Hoerspiele"
    folder: Mapped[str] = mapped_column(String(255), unique=True)
    media_type: Mapped[str] = mapped_column(String(10))
    # Material-Icon-Name für die App, z. B. "music_note"
    icon: Mapped[str] = mapped_column(String(32), default="folder")
    sort_order: Mapped[int] = mapped_column(Integer, default=0, server_default="0")
    # Standard-Ziel für neue Downloads dieses Medientyps (je Typ genau eine)
    is_default: Mapped[bool] = mapped_column(Boolean, default=False, server_default="0")
    created_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)
