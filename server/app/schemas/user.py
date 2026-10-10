"""Schemas für Login, Benutzer und Geräte."""

from datetime import datetime
from typing import Annotated

from pydantic import BaseModel, ConfigDict, StringConstraints

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


class UserUpdateIn(BaseModel):
    display_name: DisplayName | None = None
    password: Password | None = None
    is_admin: bool | None = None
    is_active: bool | None = None
    can_download: bool | None = None
