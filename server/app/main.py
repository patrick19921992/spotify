"""Einstiegspunkt des Servers: baut die FastAPI-App zusammen.

Start: uvicorn app.main:create_app --factory
"""

import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app import __version__
from app.config import Settings, get_settings
from app.database import create_db_engine, create_session_factory, run_migrations
from app.ratelimit import LoginRateLimiter
from app.routers import auth, categories, me, system, users
from app.security import load_or_create_secret_key
from app.services.bootstrap import run_bootstrap

logger = logging.getLogger("app")


def configure_logging(level: str) -> None:
    logging.basicConfig(
        level=level.upper(),
        format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )
    logging.getLogger("app").setLevel(level.upper())


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or get_settings()
    configure_logging(settings.log_level)
    settings.data_dir.mkdir(parents=True, exist_ok=True)

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        logger.info("Selfify %s startet – Daten: %s, Medien: %s", __version__, settings.data_dir, settings.media_dir)
        run_migrations(settings.database_url)
        with app.state.session_factory() as db:
            run_bootstrap(db, settings)
        yield
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
    app.state.login_limiter = LoginRateLimiter(
        max_per_user=settings.login_max_failures_per_user,
        max_per_ip=settings.login_max_failures_per_ip,
        window_seconds=settings.login_window_minutes * 60,
    )

    if settings.cors_origins:
        app.add_middleware(
            CORSMiddleware,
            allow_origins=settings.cors_origins,
            allow_methods=["*"],
            allow_headers=["*"],
        )

    for router in (system.router, auth.router, me.router, users.router, categories.router):
        app.include_router(router, prefix="/api")
    return app
