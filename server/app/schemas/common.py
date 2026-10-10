"""Gemeinsame Bausteine für die API-Schemas."""

from typing import Annotated

from pydantic import BeforeValidator, StringConstraints

USERNAME_PATTERN = r"^[a-z0-9][a-z0-9._-]{2,31}$"


def _normalize_username(value: object) -> object:
    return value.strip().lower() if isinstance(value, str) else value


# Erst normalisieren ("Lena " -> "lena"), dann das Format prüfen
Username = Annotated[str, BeforeValidator(_normalize_username), StringConstraints(pattern=USERNAME_PATTERN)]
# Beim Login nur normalisieren – falsche Formate ergeben einfach "falsches Passwort"
LoginUsername = Annotated[str, BeforeValidator(_normalize_username), StringConstraints(max_length=64)]
Password = Annotated[str, StringConstraints(min_length=8, max_length=128)]
DisplayName = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=64)]
