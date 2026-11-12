"""Einstiegspunkt des Servers: baut die FastAPI-App zusammen.

Start: uvicorn app.main:create_app --factory
"""

import logging
import re
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app import __version__
from app.config import Settings, get_settings
from app.connect.hub import ConnectHub
from app.database import create_db_engine, create_session_factory, run_migrations
from app.downloads.events import EventHub
from app.downloads.manager import DownloadManager
from app.downloads.youtube import YouTubeMusic
from app.library.covers import CoverStore
from app.library.scanner import LibraryScanner
from app.library.transcode import TranscodeCache
from app.ratelimit import LoginRateLimiter
from app.routers import (
    admin,
    auth,
    categories,
    connect,
    downloads,
    library,
    me,
    media,
    personal,
    playlists,
    premium,
    support,
    system,
    users,
    web,
)
from app.security import load_or_create_secret_key
from app.services.bootstrap import run_bootstrap
from app.services.play_billing import PurchaseVerifier, build_verifier

logger = logging.getLogger("app")

# Selbst-Registrierung: höchstens so viele Versuche je IP-Adresse und Zeitraum (jeder Versuch zählt, auch ein
# erfolgreicher). Liegt nur im Speicher – nach einem Neustart beginnt die Zählung neu, wie beim Login
REGISTER_MAX_PER_IP = 5
REGISTER_WINDOW_SECONDS = 60 * 60


_TOKEN_IN_URL = re.compile(r"((?:^|[?&\s])(?:access_)?token=)[^&\s\"']+", re.IGNORECASE)


class RedactTokens(logging.Filter):
    """Entfernt Tokens aus Links im Log (`?token=…` bei WebSockets und Downloads-Ereignissen).

    uvicorn schreibt jede WebSocket-Verbindung mit vollem Query-String ins Log („WebSocket /api/connect/ws?token=…“).
    Wer das Container-Log lesen kann, könnte sich sonst bis zum Ablauf des Tokens als dieses Gerät anmelden."""

    def filter(self, record: logging.LogRecord) -> bool:
        try:
            text = record.getMessage()
        except Exception:  # noqa: BLE001 – kaputte Log-Argumente nicht hier scheitern lassen
            return True
        if "token=" not in text.lower():
            return True
        record.msg = _TOKEN_IN_URL.sub(r"\1***", text)
        record.args = ()
        return True


def configure_logging(level: str) -> None:
    logging.basicConfig(
        level=level.upper(),
        format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )
    logging.getLogger("app").setLevel(level.upper())
    # Filter am Logger (nicht am Handler): greift auch, wenn uvicorn seine Handler selbst einrichtet
    for name in ("uvicorn.error", "uvicorn.access", "uvicorn"):
        target = logging.getLogger(name)
        if not any(isinstance(f, RedactTokens) for f in target.filters):
            target.addFilter(RedactTokens())


def create_app(settings: Settings | None = None, purchase_verifier: PurchaseVerifier | None = None) -> FastAPI:
    settings = settings or get_settings()
    configure_logging(settings.log_level)
    settings.data_dir.mkdir(parents=True, exist_ok=True)

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        logger.info("Selfify %s startet – Daten: %s, Medien: %s", __version__, settings.data_dir, settings.media_dir)
        run_migrations(settings.database_url)
        with app.state.session_factory() as db:
            run_bootstrap(db, settings)
        if not app.state.transcoder.available:
            logger.warning(
                "ffmpeg nicht gefunden – Umwandlung (iPhone/Datensparmodus) und Video-Vorschaubilder sind aus."
            )
        app.state.scanner.start()
        app.state.downloads.start()
        yield
        # Geräte-Verbindungen sauber beenden: die Apps verbinden sich nach dem Neustart wieder
        app.state.connect_hub.close_all(1001)
        app.state.downloads.stop()
        app.state.scanner.stop()
        app.state.engine.dispose()

    docs = settings.enable_api_docs
    app = FastAPI(
        title=settings.server_name,
        version=__version__,
        lifespan=lifespan,
        docs_url="/api/docs" if docs else None,
        redoc_url=None,
        openapi_url="/api/openapi.json" if docs else None,
    )

    engine = create_db_engine(settings.database_url)
    app.state.settings = settings
    app.state.engine = engine
    app.state.session_factory = create_session_factory(engine)
    app.state.secret_key = load_or_create_secret_key(settings.secret_key, settings.data_dir)
    app.state.covers = CoverStore(settings.covers_dir)
    app.state.transcoder = TranscodeCache(
        settings.transcode_dir, settings.transcode_cache_mb * 1024 * 1024, settings.ffmpeg_path
    )
    app.state.scanner = LibraryScanner(settings, app.state.session_factory, app.state.covers)
    app.state.youtube = YouTubeMusic(settings.ytmusic_language, settings.ytmusic_location)
    app.state.download_events = EventHub()
    # Wiedergabe auf anderen Geräten: nur im Speicher dieses einen Prozesses (kein --workers)
    app.state.connect_hub = ConnectHub(app.state.session_factory)
    app.state.downloads = DownloadManager(
        settings, app.state.session_factory, app.state.scanner, app.state.youtube, app.state.download_events
    )
    app.state.login_limiter = LoginRateLimiter(
        max_per_user=settings.login_max_failures_per_user,
        max_per_ip=settings.login_max_failures_per_ip,
        window_seconds=settings.login_window_minutes * 60,
    )
    # Premium-Codes einlösen: gleiche Grenzen wie beim Login (falsche Codes zählen als Raten)
    app.state.redeem_limiter = LoginRateLimiter(
        max_per_user=settings.login_max_failures_per_user,
        max_per_ip=settings.login_max_failures_per_ip,
        window_seconds=settings.login_window_minutes * 60,
    )
    # Kauf über Google Play: Prüfung bei Google (None = Schlüsseldatei fehlt – „nicht eingerichtet“). Die Bremse zählt
    # erfundene Kauf-Token nur je Benutzer, wie beim Einlösen
    app.state.purchase_verifier = purchase_verifier or build_verifier(settings)
    app.state.billing_limiter = LoginRateLimiter(20, 10**9, 15 * 60)
    app.state.register_limiter = LoginRateLimiter(10**9, REGISTER_MAX_PER_IP, REGISTER_WINDOW_SECONDS)
    # Nach einer Störung bei Google nicht bei jeder Premium-Abfrage erneut anfragen (Kauf-Nummer -> Zeitpunkt)
    app.state.billing_backoff = {}

    if settings.cors_origins:
        app.add_middleware(
            CORSMiddleware,
            allow_origins=settings.cors_origins,
            allow_methods=["*"],
            allow_headers=["*"],
        )

    for router in (
        system.router,
        auth.router,
        me.router,
        users.router,
        categories.router,
        library.router,
        media.router,
        playlists.router,
        personal.router,
        downloads.router,
        connect.router,
        premium.router,
        premium.admin_router,
        support.router,
        support.admin_router,
        admin.router,
    ):
        app.include_router(router, prefix="/api")
    # Web-Seiten (Dashboard, Datenschutz, Impressum, Konto löschen) liegen bewusst außerhalb von /api
    app.include_router(web.router)
    return app
