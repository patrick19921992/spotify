"""Schemas für Login, Benutzer und Geräte."""

import unicodedata
from datetime import datetime
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, StringConstraints, field_validator

from app.schemas.common import DisplayName, LoginUsername, Password, Username


class UserOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    username: str
    display_name: str
    is_admin: bool
    is_active: bool
    can_download: bool
    created_at: datetime
    last_login_at: datetime | None
    # Sichtbarkeit je Rubrik: all_categories = alle Rubriken (auch künftige), sonst nur category_ids.
    # Für Admins zählt das nie (sie sehen alles)
    all_categories: bool = True
    category_ids: list[int] = []
    # Selbst registriert und wartet noch auf Freischaltung durch den Betreiber
    approval_pending: bool = False
    self_registered: bool = False


class LoginIn(BaseModel):
    username: LoginUsername
    password: Annotated[str, StringConstraints(max_length=128)]
    device_name: Annotated[str, StringConstraints(strip_whitespace=True, max_length=100)] = ""


class RefreshIn(BaseModel):
    refresh_token: Annotated[str, StringConstraints(min_length=1, max_length=256)]


class TokenOut(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    expires_in: int
    # Für Stream- und Cover-Links: …/stream?t=<media_token>
    media_token: str
    media_expires_in: int
    user: UserOut


class MeUpdateIn(BaseModel):
    display_name: DisplayName


class PasswordChangeIn(BaseModel):
    current_password: Annotated[str, StringConstraints(max_length=128)]
    new_password: Password


class SessionRenameIn(BaseModel):
    """Gerät umbenennen: getrimmt, ohne Steuerzeichen, 1–100 Zeichen."""

    device_name: str

    @field_validator("device_name")
    @classmethod
    def _clean_name(cls, value: str) -> str:
        cleaned = "".join(ch for ch in value if unicodedata.category(ch) != "Cc").strip()
        if not cleaned:
            raise ValueError("Bitte gib einen Namen ein.")
        if len(cleaned) > 100:
            raise ValueError("Der Name darf höchstens 100 Zeichen lang sein.")
        return cleaned


class SessionOut(BaseModel):
    id: int
    device_name: str
    user_agent: str
    ip_address: str
    created_at: datetime
    last_used_at: datetime
    expires_at: datetime
    current: bool


class UserCreateIn(BaseModel):
    username: Username
    password: Password
    display_name: DisplayName | None = None
    is_admin: bool = False
    can_download: bool = True
    # Standard wie bisher: alle Rubriken
    all_categories: bool = True
    category_ids: list[int] = Field(default_factory=list, max_length=500)


class UserUpdateIn(BaseModel):
    display_name: DisplayName | None = None
    password: Password | None = None
    is_admin: bool | None = None
    # true schaltet ein wartendes Konto frei
    is_active: bool | None = None
    can_download: bool | None = None
    all_categories: bool | None = None
    # ersetzt die Menge der freigegebenen Rubriken vollständig
    category_ids: list[int] | None = Field(default=None, max_length=500)


class AccountDeleteIn(BaseModel):
    password: Annotated[str, StringConstraints(max_length=128)]


class RegisterIn(BaseModel):
    """Selbst-Registrierung in der App (nur, wenn der Betreiber sie eingeschaltet hat)."""

    username: Username
    password: Password
    display_name: DisplayName | None = None
    device_name: Annotated[str, StringConstraints(strip_whitespace=True, max_length=100)] = ""


class RegisterOut(BaseModel):
    status: Literal["pending", "active"]
    message: str
    # nur bei status == "active"
    tokens: TokenOut | None = None


class WithdrawIn(BaseModel):
    """Noch nicht freigeschaltete Registrierung zurückziehen (ohne Anmeldung, mit Passwort)."""

    username: LoginUsername
    password: Annotated[str, StringConstraints(max_length=128)]
