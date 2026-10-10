"""Erreichbarkeit und Server-Infos – ohne Login, damit die App die Adresse prüfen kann."""

from fastapi import APIRouter

from app import API_VERSION, __version__
from app.deps import AppSettings
from app.schemas.system import HealthOut, ServerInfoOut

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
