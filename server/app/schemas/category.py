"""Schemas für Rubriken (eigene Ordner auf dem Unraid)."""

from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, StringConstraints

CategoryName = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=64)]
IconName = Annotated[str, StringConstraints(strip_whitespace=True, pattern=r"^[a-z0-9_]{1,32}$")]
MediaType = Literal["audio", "video"]


class CategoryOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    name: str
    slug: str
    folder: str
    media_type: MediaType
    icon: str
    sort_order: int
    is_default: bool


class CategoryCreateIn(BaseModel):
    name: CategoryName
    media_type: MediaType
    # Leer = wird aus dem Namen gebildet ("Hörspiele" -> "Hoerspiele")
    folder: Annotated[str, StringConstraints(strip_whitespace=True, max_length=255)] | None = None
    icon: IconName | None = None
    sort_order: int | None = None
    is_default: bool = False


class CategoryUpdateIn(BaseModel):
    """Der Ordner ist absichtlich nicht änderbar – sonst müssten Dateien verschoben werden."""

    name: CategoryName | None = None
    icon: IconName | None = None
    sort_order: int | None = None
    is_default: bool | None = None
