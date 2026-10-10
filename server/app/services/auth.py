"""Anmelden, Token erneuern und Geräte abmelden."""

from dataclasses import dataclass
from datetime import timedelta

from sqlalchemy import or_, select, update
from sqlalchemy.orm import Session

from app.config import Settings
from app.models import User, UserSession, utcnow
from app.security import create_access_token, create_media_token, hash_token, new_refresh_token

# So lange gilt der vorherige Refresh-Token nach dem Erneuern noch (Antwort ging verloren)
REFRESH_GRACE = timedelta(seconds=60)


@dataclass
class IssuedTokens:
    access_token: str
    refresh_token: str
    expires_in: int
    media_token: str
    media_expires_in: int
    user: User
    session: UserSession


def _issue(settings: Settings, secret: str, session: UserSession, user: User) -> IssuedTokens:
    refresh_token = new_refresh_token()
    now = utcnow()
    if session.token_hash:
        session.previous_token_hash = session.token_hash
        session.rotated_at = now
    session.token_hash = hash_token(refresh_token)
    session.last_used_at = now
    session.expires_at = now + timedelta(days=settings.refresh_token_days)
    access_token = create_access_token(secret, user.id, session.id, settings.access_token_minutes)
    media_token = create_media_token(secret, user.id, session.id, settings.media_token_hours)
    return IssuedTokens(
        access_token=access_token,
        refresh_token=refresh_token,
        expires_in=settings.access_token_minutes * 60,
        media_token=media_token,
        media_expires_in=settings.media_token_hours * 3600,
        user=user,
        session=session,
    )


def start_session(
    db: Session,
    settings: Settings,
    secret: str,
    user: User,
    *,
    device_name: str,
    user_agent: str,
    ip_address: str,
) -> IssuedTokens:
    now = utcnow()
    session = UserSession(
        user_id=user.id,
        token_hash="",
        device_name=device_name[:100],
        user_agent=user_agent[:255],
        ip_address=ip_address[:64],
        created_at=now,
        last_used_at=now,
        expires_at=now + timedelta(days=settings.refresh_token_days),
    )
    db.add(session)
    db.flush()
    issued = _issue(settings, secret, session, user)
    user.last_login_at = now
    return issued


def refresh_session(
    db: Session, settings: Settings, secret: str, refresh_token: str, ip_address: str
) -> IssuedTokens | None:
    """Tauscht einen Refresh-Token gegen ein neues Paar. None = abgelaufen/ungültig."""
    token_hash = hash_token(refresh_token)
    now = utcnow()
    session = db.scalar(
        select(UserSession).where(
            or_(UserSession.token_hash == token_hash, UserSession.previous_token_hash == token_hash)
        )
    )
    if session is None or session.revoked_at is not None or session.expires_at <= now:
        return None

    # Alter Token: nur kurz nach dem Erneuern erlaubt, sonst wurde er evtl. gestohlen
    reused_old_token = session.token_hash != token_hash
    if reused_old_token and (session.rotated_at is None or now - session.rotated_at > REFRESH_GRACE):
        session.revoked_at = now
        db.commit()
        return None

    user = db.get(User, session.user_id)
    if user is None or not user.is_active:
        return None
    if ip_address:
        session.ip_address = ip_address[:64]
    return _issue(settings, secret, session, user)


def revoke_session(db: Session, session: UserSession) -> None:
    if session.revoked_at is None:
        session.revoked_at = utcnow()


def revoke_all_sessions(db: Session, user_id: int, except_session_id: int | None = None) -> None:
    query = update(UserSession).where(UserSession.user_id == user_id, UserSession.revoked_at.is_(None))
    if except_session_id is not None:
        query = query.where(UserSession.id != except_session_id)
    db.execute(query.values(revoked_at=utcnow()))


def active_session(db: Session, session_id: int, user_id: int) -> UserSession | None:
    session = db.get(UserSession, session_id)
    if session is None or session.user_id != user_id:
        return None
    if session.revoked_at is not None or session.expires_at <= utcnow():
        return None
    return session


def reissue_for_session(db: Session, settings: Settings, secret: str, session: UserSession, user: User) -> IssuedTokens:
    """Neues Token-Paar für dieses Gerät, z. B. nach einer Passwortänderung."""
    return _issue(settings, secret, session, user)
