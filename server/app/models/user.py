"""Benutzerkonten und angemeldete Geräte (Sitzungen)."""

from datetime import datetime

from sqlalchemy import Boolean, Column, ForeignKey, Integer, String, Table
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, UTCDateTime, utcnow
from app.models.category import Category

# Freigegebene Rubriken je Konto. Zählt nur bei eingeschränkten Konten (kein Admin, all_categories = false).
# Wird eine Rubrik oder ein Konto gelöscht, verschwinden die Zeilen per CASCADE
user_categories = Table(
    "user_categories",
    Base.metadata,
    Column("user_id", ForeignKey("users.id", ondelete="CASCADE"), primary_key=True),
    Column("category_id", ForeignKey("categories.id", ondelete="CASCADE"), primary_key=True, index=True),
)


class User(Base):
    __tablename__ = "users"

    id: Mapped[int] = mapped_column(primary_key=True)
    # Immer klein geschrieben gespeichert ("Lena" -> "lena")
    username: Mapped[str] = mapped_column(String(32), unique=True, index=True)
    display_name: Mapped[str] = mapped_column(String(64))
    password_hash: Mapped[str] = mapped_column(String(255))
    is_admin: Mapped[bool] = mapped_column(Boolean, default=False, server_default="0")
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, server_default="1")
    # Darf fehlende Songs/Videos von YouTube holen lassen
    can_download: Mapped[bool] = mapped_column(Boolean, default=True, server_default="1")
    created_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)
    updated_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow, onupdate=utcnow)
    last_login_at: Mapped[datetime | None] = mapped_column(UTCDateTime, default=None)
    # Sieht alle Rubriken (auch künftige). Bestandskonten und vom Admin angelegte Konten: ja; selbst registrierte:
    # nein – sie sehen nur die Rubriken in user_categories. Für Admins zählt das Feld nie, sie sehen immer alles
    all_categories: Mapped[bool] = mapped_column(Boolean, default=True, server_default="1")
    # Selbst registriert und noch nicht freigeschaltet (dann immer auch is_active = false)
    approval_pending: Mapped[bool] = mapped_column(Boolean, default=False, server_default="0")
    # Hat sich selbst in der App registriert (statt vom Admin angelegt)
    self_registered: Mapped[bool] = mapped_column(Boolean, default=False, server_default="0")

    # Freigegebene Rubriken (nur wirksam bei all_categories = false)
    categories: Mapped[list[Category]] = relationship(
        secondary=user_categories, passive_deletes=True, order_by=Category.id
    )
    sessions: Mapped[list["UserSession"]] = relationship(
        back_populates="user", cascade="all, delete-orphan", passive_deletes=True
    )

    @property
    def category_ids(self) -> list[int]:
        """IDs der freigegebenen Rubriken, aufsteigend."""
        return sorted(category.id for category in self.categories)


class UserSession(Base):
    """Ein angemeldetes Gerät. Hält den (gehashten) Refresh-Token."""

    __tablename__ = "user_sessions"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    token_hash: Mapped[str] = mapped_column(String(64), unique=True, index=True)
    # Vorheriger Token – kurz nach dem Erneuern noch gültig (Netzabbruch am Handy)
    previous_token_hash: Mapped[str | None] = mapped_column(String(64), index=True, default=None)
    rotated_at: Mapped[datetime | None] = mapped_column(UTCDateTime, default=None)
    device_name: Mapped[str] = mapped_column(String(100), default="")
    user_agent: Mapped[str] = mapped_column(String(255), default="")
    ip_address: Mapped[str] = mapped_column(String(64), default="")
    # Welche App-Version das Gerät zuletzt gemeldet hat (Header X-Selfify-Client) – für das Dashboard
    client_platform: Mapped[str] = mapped_column(String(20), default="", server_default="")
    client_channel: Mapped[str] = mapped_column(String(10), default="", server_default="")
    client_version: Mapped[str] = mapped_column(String(32), default="", server_default="")
    client_build: Mapped[int | None] = mapped_column(Integer, default=None)
    created_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)
    last_used_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)
    expires_at: Mapped[datetime] = mapped_column(UTCDateTime)
    revoked_at: Mapped[datetime | None] = mapped_column(UTCDateTime, default=None)

    user: Mapped[User] = relationship(back_populates="sessions")
