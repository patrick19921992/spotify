"""Premium: Einlösecodes und Lizenzen (wer hat wie lange Premium)."""

from datetime import datetime

from sqlalchemy import ForeignKey, Integer, String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.models.base import Base, UTCDateTime, utcnow
from app.models.user import User


class PremiumCode(Base):
    """Ein vom Admin erzeugter Code, den Benutzer in der App einlösen."""

    __tablename__ = "premium_codes"

    id: Mapped[int] = mapped_column(primary_key=True)
    # Ohne Bindestriche, Großbuchstaben (angezeigt wird XXXX-XXXX-XXXX)
    code: Mapped[str] = mapped_column(String(32), unique=True, index=True)
    label: Mapped[str] = mapped_column(String(100), default="")
    # Laufzeit ab dem Einlösen in Tagen; None = unbegrenzt
    duration_days: Mapped[int | None] = mapped_column(Integer, default=None)
    # Wie oft der Code insgesamt eingelöst werden darf (jeder Benutzer höchstens einmal)
    max_redemptions: Mapped[int] = mapped_column(Integer, default=1)
    redeemed_count: Mapped[int] = mapped_column(Integer, default=0)
    # Einlösbar bis (None = beliebig lange)
    valid_until: Mapped[datetime | None] = mapped_column(UTCDateTime, default=None)
    revoked_at: Mapped[datetime | None] = mapped_column(UTCDateTime, default=None)
    created_by_id: Mapped[int | None] = mapped_column(ForeignKey("users.id", ondelete="SET NULL"), default=None)
    created_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)

    licenses: Mapped[list["PremiumLicense"]] = relationship(back_populates="code", passive_deletes=True)


class PremiumLicense(Base):
    """Premium eines Benutzers – durch einen Code oder direkt vom Admin vergeben."""

    __tablename__ = "premium_licenses"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    code_id: Mapped[int | None] = mapped_column(ForeignKey("premium_codes.id", ondelete="SET NULL"), default=None)
    # "code" = eingelöst, "admin" = direkt vom Admin vergeben
    source: Mapped[str] = mapped_column(String(10), default="code")
    starts_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)
    # None = unbegrenzt
    expires_at: Mapped[datetime | None] = mapped_column(UTCDateTime, default=None)
    revoked_at: Mapped[datetime | None] = mapped_column(UTCDateTime, default=None)
    note: Mapped[str] = mapped_column(String(200), default="")
    created_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)

    user: Mapped[User] = relationship(lazy="joined")
    code: Mapped[PremiumCode | None] = relationship(back_populates="licenses")
