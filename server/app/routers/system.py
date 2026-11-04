"""Erreichbarkeit und Server-Infos – ohne Login, damit die App die Adresse prüfen kann."""

from typing import Annotated

from fastapi import APIRouter, Query

from app import API_VERSION, __version__
from app.deps import AppSettings, DbSession
from app.schemas.support import PublicConfigOut, UpdateInfoOut
from app.schemas.system import HealthOut, ServerInfoOut
from app.services import app_config

router = APIRouter(tags=["System"])


@router.get("/health", response_model=HealthOut)
def health() -> HealthOut:
    return HealthOut(status="ok")


@router.get("/server", response_model=ServerInfoOut)
def server_info(settings: AppSettings) -> ServerInfoOut:
    return ServerInfoOut(
        name=settings.server_name,
        version=__version__,
        api_version=API_VERSION,
        public_url=settings.public_url,
    )


@router.get("/app/config", response_model=PublicConfigOut)
def public_config(
    settings: AppSettings,
    db: DbSession,
    channel: Annotated[str, Query(max_length=10)] = "",
    build: Annotated[int | None, Query(ge=0, le=100_000_000)] = None,
) -> PublicConfigOut:
    """Einstellungen für die App (ohne Login): Werbung, Hinweise, Update-Pflicht, Links zu Datenschutz/Konto löschen."""
    values = app_config.get_all(db)
    base = settings.public_url
    return PublicConfigOut(
        server_name=settings.server_name,
        ads_enabled=values["ads_enabled"],
        premium_enabled=values["premium_enabled"],
        wishlist_enabled=values["wishlist_enabled"],
        maintenance_message=values["maintenance_message"],
        update=UpdateInfoOut(
            level=app_config.update_level(values, channel, build),  # type: ignore[arg-type]
            latest_build=values["play_latest_build"],
            min_build=values["play_min_build"],
            store_url=values["play_store_url"],
            message=values["update_message"],
        ),
        privacy_url=f"{base}/datenschutz" if base else "",
        deletion_url=f"{base}/konto-loeschen" if base else "",
    )
