"""Schemas für Premium: Status, Einlösen, Codes und Lizenzen."""

from datetime import UTC, datetime
from typing import Annotated, Literal

from pydantic import BaseModel, Field, StringConstraints, field_validator, model_validator

from app.services.premium import MAX_DURATION_DAYS

CodeText = Annotated[str, StringConstraints(strip_whitespace=True, min_length=4, max_length=64)]
Label = Annotated[str, StringConstraints(strip_whitespace=True, max_length=100)]
Note = Annotated[str, StringConstraints(strip_whitespace=True, max_length=200)]


class PremiumStatusOut(BaseModel):
    active: bool
    # Gilt ohne Ablaufdatum
    unlimited: bool
    # Bis wann Premium läuft (nur bei begrenztem Premium)
    until: datetime | None


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


class LicenseOut(BaseModel):
    id: int
    user_id: int
    username: str
    display_name: str
    source: Literal["code", "admin"]
    code: str | None
    starts_at: datetime
    expires_at: datetime | None
    revoked_at: datetime | None
    note: str
    running: bool


class UserPremiumOut(PremiumStatusOut):
    user_id: int
    licenses: list[LicenseOut]


class RevokedOut(BaseModel):
    revoked: int
