from typing import Literal

from pydantic import BaseModel


class HealthOut(BaseModel):
    status: str


class ServerInfoOut(BaseModel):
    name: str
    version: str
    api_version: int
    public_url: str
    # Selbst-Registrierung in der App: aus (Standard), mit Freigabe oder offen
    registration_mode: Literal["off", "approval", "open"] = "off"
