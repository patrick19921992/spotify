"""Selbst-Registrierung: wartende Konten, die niemand freischaltet, werden nach einer Frist gelöscht.

Ein Konto „mit Freigabe“ wartet, bis der Admin es freischaltet oder ablehnt. Bleibt es liegen, löscht der Server es
nach PENDING_MAX_DAYS Tagen von selbst (stündlich im Hintergrund und bei jeder neuen Registrierung). So sammeln sich
keine vergessenen Konten samt Passwort-Hash an, und sie blockieren die Obergrenze für wartende Konten nicht.
"""

import logging
from datetime import datetime, timedelta

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.locks import write_lock
from app.models import User, utcnow

logger = logging.getLogger(__name__)

# Nach so vielen Tagen ohne Freischaltung wird ein wartendes Konto gelöscht
PENDING_MAX_DAYS = 14
PENDING_MAX_AGE = timedelta(days=PENDING_MAX_DAYS)


def pending_deadline(created_at: datetime) -> datetime:
    """Bis wann ein wartendes Konto bestehen bleibt."""
    return created_at + PENDING_MAX_AGE


def purge_expired_pending(db: Session, now: datetime | None = None) -> int:
    """Löscht wartende Konten, die älter als die Frist sind. Gibt die Anzahl gelöschter Konten zurück.

    Nur Konten, die noch auf Freischaltung warten (approval_pending) – freigeschaltete, gesperrte oder vom Admin
    angelegte Konten bleiben unberührt. Gelöscht wird wie beim Ablehnen (samt allem, was am Konto hängt)."""
    cutoff = (now or utcnow()) - PENDING_MAX_AGE
    with write_lock:
        expired = list(
            db.scalars(select(User).where(User.approval_pending.is_(True), User.created_at < cutoff))
        )
        for user in expired:
            db.delete(user)
        if expired:
            db.commit()
    if expired:
        logger.info(
            "%d wartende Registrierung(en) nach %d Tagen ohne Freischaltung gelöscht.", len(expired), PENDING_MAX_DAYS
        )
    return len(expired)
