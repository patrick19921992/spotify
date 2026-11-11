"""Premium: Einlösecodes, Lizenzen (wer hat wie lange Premium) und Käufe über Google Play."""

from datetime import datetime

from sqlalchemy import Boolean, ForeignKey, Integer, String, Text, UniqueConstraint
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
    # Jeder Benutzer löst einen Code höchstens einmal ein – auch bei gleichzeitigen Anfragen (code_id NULL = vom Admin
    # vergeben oder Code gelöscht: davon darf es viele geben)
    __table_args__ = (UniqueConstraint("code_id", "user_id", name="uq_premium_licenses_code_id_user_id"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    code_id: Mapped[int | None] = mapped_column(ForeignKey("premium_codes.id", ondelete="SET NULL"), default=None)
    # "code" = eingelöst, "admin" = direkt vom Admin vergeben, "play" = Abo über Google Play (siehe PlayPurchase)
    source: Mapped[str] = mapped_column(String(10), default="code")
    starts_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)
    # None = unbegrenzt
    expires_at: Mapped[datetime | None] = mapped_column(UTCDateTime, default=None)
    revoked_at: Mapped[datetime | None] = mapped_column(UTCDateTime, default=None)
    note: Mapped[str] = mapped_column(String(200), default="")
    created_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)

    user: Mapped[User] = relationship(lazy="joined")
    code: Mapped[PremiumCode | None] = relationship(back_populates="licenses")


# Zustände eines Kaufs. Zugang gibt es nur in ENTITLED_STATES und nur, solange expires_at in der Zukunft liegt
PURCHASE_STATES = ("active", "canceled", "grace", "on_hold", "paused", "pending", "expired", "replaced")


class PlayPurchase(Base):
    """Ein Abo-Kauf über Google Play. Steuert genau eine Lizenz (source="play") des Benutzers."""

    __tablename__ = "play_purchases"
    # Ein Kauf = ein Konto – auch bei gleichzeitigen Anfragen
    __table_args__ = (UniqueConstraint("token_hash", name="uq_play_purchases_token_hash"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    product_id: Mapped[str] = mapped_column(String(100))
    # Kauf-Token von Google: wird für die erneute Prüfung gebraucht und nie an Clients zurückgegeben
    purchase_token: Mapped[str] = mapped_column(Text)
    # SHA-256 (hex) des Tokens
    token_hash: Mapped[str] = mapped_column(String(64))
    # Hash des Vorgänger-Kaufs (Google: linkedPurchaseToken), z. B. nach erneutem Abschluss
    linked_token_hash: Mapped[str | None] = mapped_column(String(64), default=None)
    order_id: Mapped[str] = mapped_column(String(100), default="")
    state: Mapped[str] = mapped_column(String(12), index=True)
    expires_at: Mapped[datetime | None] = mapped_column(UTCDateTime, default=None)
    auto_renewing: Mapped[bool] = mapped_column(Boolean, default=False)
    # Bei Google bestätigt (unbestätigte Käufe erstattet Google nach drei Tagen von selbst)
    acknowledged: Mapped[bool] = mapped_column(Boolean, default=False)
    # Kauf eines Lizenztesters
    is_test: Mapped[bool] = mapped_column(Boolean, default=False)
    license_id: Mapped[int | None] = mapped_column(ForeignKey("premium_licenses.id", ondelete="SET NULL"), default=None)
    # Letzte erfolgreiche Abfrage bei Google
    last_checked_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)
    # Letzte Störung beim Prüfen (ohne Geheimnisse)
    last_error: Mapped[str] = mapped_column(String(300), default="")
    created_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow)
    updated_at: Mapped[datetime] = mapped_column(UTCDateTime, default=utcnow, onupdate=utcnow)

    user: Mapped[User] = relationship(lazy="joined")
    license: Mapped[PremiumLicense | None] = relationship(lazy="joined")
