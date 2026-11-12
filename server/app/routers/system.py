"""Erreichbarkeit und Server-Infos – ohne Login, damit die App die Adresse prüfen kann."""

from typing import Annotated

from fastapi import APIRouter, Query, Request

from app import API_VERSION, __version__
from app.deps import AppSettings, DbSession
from app.schemas.support import PublicConfigOut, UpdateInfoOut
from app.schemas.system import HealthOut, ServerInfoOut
from app.services import app_config, play_billing
from app.services import features as feature_set

router = APIRouter(tags=["System"])

# Fähigkeiten dieses Servers für die App (fehlt ein Eintrag, blendet die App die Funktion aus)
SERVER_FEATURES = ("connect",)


@router.get("/health", response_model=HealthOut)
def health() -> HealthOut:
    return HealthOut(status="ok")


@router.get("/server", response_model=ServerInfoOut)
def server_info(settings: AppSettings, db: DbSession) -> ServerInfoOut:
    return ServerInfoOut(
        name=settings.server_name,
        version=__version__,
        api_version=API_VERSION,
        public_url=settings.public_url,
        registration_mode=app_config.get_all(db)["registration_mode"],
        features=list(SERVER_FEATURES),
    )


@router.get("/app/config", response_model=PublicConfigOut)
def public_config(
    request: Request,
    settings: AppSettings,
    db: DbSession,
    channel: Annotated[str, Query(max_length=10)] = "",
    build: Annotated[int | None, Query(ge=0, le=100_000_000)] = None,
) -> PublicConfigOut:
    """Einstellungen für die App (ohne Login): Werbung, Hinweise, Update-Pflicht, Links zu Datenschutz/Konto löschen."""
    values = app_config.get_all(db)
    base = settings.public_url
    # Kaufen kann man nur in der Play-Version – und nur, wenn der Server Käufe auch prüfen kann
    product_ids = app_config.product_ids(values)
    billing = bool(
        values["billing_enabled"]
        and channel == "play"
        and product_ids
        and play_billing.current_verifier(request.app.state, settings) is not None
    )
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
        offline_requires_premium=values["offline_requires_premium"],
        offline_grace_days=values["offline_grace_days"],
        offline_min_client_build=values["offline_min_client_build"],
        billing_enabled=billing,
        billing_product_ids=product_ids if billing else [],
        premium_headline=values["premium_headline"],
        premium_description=values["premium_description"],
        premium_benefits=app_config.benefits(values),
        premium_only=feature_set.premium_only(values),
        free_audio_quality=values["free_audio_quality"],
        free_requests_per_week=values["free_requests_per_week"],
        free_skips_per_hour=values["free_skips_per_hour"],
        premium_badge_enabled=values["premium_badge_enabled"],
        billing_base_plans=app_config.base_plans(values) if billing else [],
        billing_recommended_plan=values["billing_recommended_plan"] if billing else "",
        registration_mode=values["registration_mode"],
    )
