"""Erster Start: Ordner, Standard-Rubriken und erster Admin."""

import logging
import re

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.config import Settings
from app.models import User
from app.schemas.common import USERNAME_PATTERN
from app.security import generate_password, hash_password
from app.services.categories import ensure_all_folders, seed_default_categories

logger = logging.getLogger(__name__)


def ensure_admin(db: Session, settings: Settings) -> None:
    if db.scalar(select(func.count(User.id))):
        return
    username = settings.admin_username.strip().lower() or "admin"
    if not re.fullmatch(USERNAME_PATTERN, username):
        logger.warning("ADMIN_USERNAME '%s' ist ungültig – verwende 'admin'.", settings.admin_username)
        username = "admin"
    password = settings.admin_password
    generated = not password
    if generated:
        password = generate_password()
    elif len(password) < 8:
        logger.warning("ADMIN_PASSWORD ist kürzer als 8 Zeichen – bitte nach dem ersten Login ändern.")

    db.add(
        User(
            username=username,
            display_name=username.capitalize(),
            password_hash=hash_password(password),
            is_admin=True,
            can_download=True,
        )
    )
    if generated:
        logger.warning(
            "\n%s\n  Erster Admin angelegt\n  Benutzer: %s\n  Passwort: %s\n  Bitte nach dem ersten Login ändern!\n%s",
            "=" * 60,
            username,
            password,
            "=" * 60,
        )
    else:
        logger.info("Erster Admin '%s' angelegt (Passwort aus ADMIN_PASSWORD).", username)


def run_bootstrap(db: Session, settings: Settings) -> None:
    try:
        settings.media_dir.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        logger.error("Medienordner %s nicht beschreibbar: %s", settings.media_dir, exc)
    seed_default_categories(db, settings.media_dir)
    ensure_all_folders(db, settings.media_dir)
    ensure_admin(db, settings)
    db.commit()
