"""Schemas für Premium: Status, Einlösen, Codes und Lizenzen."""

from datetime import UTC, datetime
from typing import Annotated, Literal

from pydantic import BaseModel, Field, StringConstraints, field_validator, model_validator

from app.services.features import FEATURES, ordered
from app.services.premium import MAX_DURATION_DAYS

CodeText = Annotated[str, StringConstraints(strip_whitespace=True, min_length=4, max_length=64)]
Label = Annotated[str, StringConstraints(strip_whitespace=True, max_length=100)]
Note = Annotated[str, StringConstraints(strip_whitespace=True, max_length=200)]
# Schlüssel der Premium-Leistungen (siehe services/features.py)
FeatureKey = Literal["offline", "no_ads", "hq_audio", "video", "lyrics", "requests", "skips", "badge"]
assert tuple(FeatureKey.__args__) == FEATURES  # type: ignore[attr-defined]


class PremiumStatusOut(BaseModel):
    active: bool
    # Gilt ohne Ablaufdatum
    unlimited: bool
    # Bis wann Premium läuft (nur bei begrenztem Premium)
    until: datetime | None
    # Welche Leistungen das laufende Premium freischaltet (FEATURES-Reihenfolge; leer ohne Premium)
    features: list[str] = []


PurchaseState = Literal["active", "canceled", "grace", "on_hold", "paused", "pending", "expired", "replaced"]


class PlaySubscriptionOut(BaseModel):
    """Das laufende Abo über Google Play (ohne Kauf-Token)."""

    product_id: str
    state: Literal["active", "canceled", "grace", "on_hold", "paused", "pending"]
    expires_at: datetime | None
    auto_renewing: bool
    # Laufzeit (Kennung des Basis-Abos) und Angebot laut Google; "" = unbekannt bzw. keins
    base_plan_id: str = ""
    offer_id: str = ""


class MyPremiumOut(PremiumStatusOut):
    """Premium-Stand für die App – samt der Frage, ob Offline-Hören erlaubt ist."""

    offline_requires_premium: bool
    # Schalter aus, Admin oder Premium aktiv
    offline_allowed: bool
    offline_grace_days: int
    # Serverzeit dieser Antwort
    checked_at: datetime
    play: PlaySubscriptionOut | None = None
    # Leistungen, die der Betreiber nur mit Premium erlaubt (wie in /app/config)
    premium_only: list[str] = []
    # Was dieser Benutzer gerade nicht darf ([] für Admins)
    locked: list[str] = []
    # Premium-Abzeichen zeigen (Schalter an und „badge“ im Umfang)
    badge: bool = False


class PlayVerifyIn(BaseModel):
    product_id: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=100)]
    purchase_token: Annotated[str, StringConstraints(strip_whitespace=True, min_length=10, max_length=4000)]


class PlayVerifyOut(BaseModel):
    # active = Premium läuft, pending = Zahlung bei Google noch offen, inactive = Kauf gültig, aber kein Zugang
    result: Literal["active", "pending", "inactive"]
    premium: MyPremiumOut


class PurchaseOut(BaseModel):
    """Ein Kauf für das Dashboard – bewusst ohne Kauf-Token."""

    id: int
    user_id: int
    username: str
    display_name: str
    product_id: str
    order_id: str
    state: PurchaseState
    expires_at: datetime | None
    auto_renewing: bool
    acknowledged: bool
    is_test: bool
    license_id: int | None
    license_revoked: bool
    last_checked_at: datetime
    last_error: str
    created_at: datetime
    base_plan_id: str = ""
    offer_id: str = ""


class BillingStatusOut(BaseModel):
    # Schlüsseldatei vorhanden und lesbar
    configured: bool
    package_name: str
    # Nur der Pfad – der Inhalt verlässt den Server nie
    key_file: str
    product_ids: list[str]
    enabled: bool


class BillingTestOut(BaseModel):
    ok: bool
    message: str


PurchaseState = Literal["active", "canceled", "grace", "on_hold", "paused", "pending", "expired", "replaced"]


class PlaySubscriptionOut(BaseModel):
    """Das laufende Abo über Google Play (ohne Kauf-Token)."""

    product_id: str
    state: Literal["active", "canceled", "grace", "on_hold", "paused", "pending"]
    expires_at: datetime | None
    auto_renewing: bool


class MyPremiumOut(PremiumStatusOut):
    """Premium-Stand für die App – samt der Frage, ob Offline-Hören erlaubt ist."""

    offline_requires_premium: bool
    # Schalter aus, Admin oder Premium aktiv
    offline_allowed: bool
    offline_grace_days: int
    # Serverzeit dieser Antwort
    checked_at: datetime
    play: PlaySubscriptionOut | None = None


class PlayVerifyIn(BaseModel):
    product_id: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=100)]
    purchase_token: Annotated[str, StringConstraints(strip_whitespace=True, min_length=10, max_length=4000)]


class PlayVerifyOut(BaseModel):
    # active = Premium läuft, pending = Zahlung bei Google noch offen, inactive = Kauf gültig, aber kein Zugang
    result: Literal["active", "pending", "inactive"]
    premium: MyPremiumOut


class PurchaseOut(BaseModel):
    """Ein Kauf für das Dashboard – bewusst ohne Kauf-Token."""

    id: int
    user_id: int
    username: str
    display_name: str
    product_id: str
    order_id: str
    state: PurchaseState
    expires_at: datetime | None
    auto_renewing: bool
    acknowledged: bool
    is_test: bool
    license_id: int | None
    license_revoked: bool
    last_checked_at: datetime
    last_error: str
    created_at: datetime


class BillingStatusOut(BaseModel):
    # Schlüsseldatei vorhanden und lesbar
    configured: bool
    package_name: str
    # Nur der Pfad – der Inhalt verlässt den Server nie
    key_file: str
    product_ids: list[str]
    enabled: bool


class BillingTestOut(BaseModel):
    ok: bool
    message: str


class RedeemIn(BaseModel):
    code: CodeText


class _Duration(BaseModel):
    """Laufzeit in Tagen ODER unbegrenzt – genau eins von beiden, damit „unbegrenzt“ nie aus Versehen entsteht."""

    duration_days: Annotated[int, Field(ge=1, le=MAX_DURATION_DAYS)] | None = None
    unlimited: bool = False

    @model_validator(mode="after")
    def _exactly_one(self) -> "_Duration":
        if self.unlimited == (self.duration_days is not None):
            raise ValueError("Bitte entweder eine Laufzeit in Tagen angeben oder „unbegrenzt“ wählen.")
        return self


class CodeCreateIn(_Duration):
    count: Annotated[int, Field(ge=1, le=200)] = 1
    max_redemptions: Annotated[int, Field(ge=1, le=100_000)] = 1
    # Bis wann der Code eingelöst werden kann (leer = beliebig lange)
    valid_until: datetime | None = None
    label: Label = ""
    # Welche Leistungen die Codes freischalten (None = alle). Doppelte werden zusammengefasst, alle 8 = None
    features: list[FeatureKey] | None = None

    @field_validator("features")
    @classmethod
    def _features(cls, value: list[str] | None) -> list[str] | None:
        if value is None:
            return None
        if not value:
            raise ValueError("Bitte mindestens eine Leistung wählen.")
        keys = ordered(value)
        return None if len(keys) == len(FEATURES) else keys

    @field_validator("valid_until")
    @classmethod
    def _utc(cls, value: datetime | None) -> datetime | None:
        """Ohne Zeitzone gilt UTC; alles wird nach UTC umgerechnet. Unsinnige Jahre werden abgelehnt (statt 500)."""
        if value is None:
            return None
        try:
            value = value.replace(tzinfo=UTC) if value.tzinfo is None else value.astimezone(UTC)
        except (OverflowError, ValueError):
            raise ValueError("„Einlösbar bis“ ist kein gültiger Zeitpunkt.") from None
        if value.year > 2100:
            raise ValueError("„Einlösbar bis“ darf höchstens im Jahr 2100 liegen.")
        return value


class GrantIn(_Duration):
    note: Note = ""


class CodeRevokeIn(BaseModel):
    # Auch das Premium entziehen, das schon durch diesen Code entstanden ist
    revoke_licenses: bool = False


class RedemptionOut(BaseModel):
    license_id: int
    user_id: int
    username: str
    display_name: str
    starts_at: datetime
    expires_at: datetime | None
    revoked_at: datetime | None


class CodeOut(BaseModel):
    id: int
    code: str
    label: str
    duration_days: int | None
    unlimited: bool
    max_redemptions: int
    redeemed_count: int
    valid_until: datetime | None
    revoked_at: datetime | None
    created_at: datetime
    state: Literal["available", "used_up", "expired", "revoked"]
    redemptions: list[RedemptionOut]
    # Umfang: None = alle Leistungen
    features: list[str] | None = None


class LicenseOut(BaseModel):
    id: int
    user_id: int
    username: str
    display_name: str
    source: Literal["code", "admin", "play"]
    code: str | None
    starts_at: datetime
    expires_at: datetime | None
    revoked_at: datetime | None
    note: str
    running: bool
    # Umfang: None = alle Leistungen
    features: list[str] | None = None


class UserPremiumOut(PremiumStatusOut):
    user_id: int
    licenses: list[LicenseOut]


class RevokedOut(BaseModel):
    revoked: int
