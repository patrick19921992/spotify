"""Gemeinsame Abhängigkeiten der Endpunkte: Einstellungen, Datenbank, angemeldeter Benutzer."""

from dataclasses import dataclass
from typing import Annotated

from fastapi import Depends, HTTPException, Query, Request, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.orm import Session

from app.config import Settings
from app.database import get_db
from app.models import User, UserSession, utcnow
from app.security import decode_access_token, decode_media_token
from app.services.auth import active_session

_bearer = HTTPBearer(auto_error=False)

DbSession = Annotated[Session, Depends(get_db)]


def get_app_settings(request: Request) -> Settings:
    return request.app.state.settings


AppSettings = Annotated[Settings, Depends(get_app_settings)]


def client_ip(request: Request) -> str:
    return request.client.host if request.client else ""


@dataclass
class AuthContext:
    user: User
    session: UserSession


def _unauthorized(detail: str = "Nicht angemeldet.") -> HTTPException:
    return HTTPException(status.HTTP_401_UNAUTHORIZED, detail, headers={"WWW-Authenticate": "Bearer"})


def _auth_from_payload(db: Session, payload: dict[str, object]) -> AuthContext:
    try:
        user_id, session_id = int(str(payload["sub"])), int(str(payload["sid"]))
    except (KeyError, TypeError, ValueError):
        raise _unauthorized("Anmeldung abgelaufen oder ungültig.") from None

    user = db.get(User, user_id)
    if user is None or not user.is_active:
        raise _unauthorized("Konto nicht vorhanden oder deaktiviert.")
    session = active_session(db, session_id, user_id)
    if session is None:
        raise _unauthorized("Dieses Gerät wurde abgemeldet.")
    # "Zuletzt aktiv" höchstens minütlich schreiben
    now = utcnow()
    if (now - session.last_used_at).total_seconds() > 60:
        session.last_used_at = now
        db.commit()
    return AuthContext(user=user, session=session)


def get_auth(
    request: Request,
    db: DbSession,
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(_bearer)],
) -> AuthContext:
    if credentials is None:
        raise _unauthorized()
    payload = decode_access_token(request.app.state.secret_key, credentials.credentials)
    if payload is None:
        raise _unauthorized("Anmeldung abgelaufen oder ungültig.")
    return _auth_from_payload(db, payload)


Auth = Annotated[AuthContext, Depends(get_auth)]


def get_media_auth(
    request: Request,
    db: DbSession,
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(_bearer)],
    t: Annotated[str | None, Query(description="Medien-Token aus dem Login (für Player-Links)")] = None,
) -> AuthContext:
    """Für Streams und Cover: normaler Bearer-Token ODER Medien-Token im Link (?t=…)."""
    secret = request.app.state.secret_key
    if credentials is not None:
        payload = decode_access_token(secret, credentials.credentials)
    elif t:
        payload = decode_media_token(secret, t)
    else:
        raise _unauthorized()
    if payload is None:
        raise _unauthorized("Anmeldung abgelaufen oder ungültig.")
    return _auth_from_payload(db, payload)


MediaAuth = Annotated[AuthContext, Depends(get_media_auth)]


def get_current_user(auth: Auth) -> User:
    return auth.user


CurrentUser = Annotated[User, Depends(get_current_user)]


def get_admin_user(user: CurrentUser) -> User:
    if not user.is_admin:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Nur für Admins.")
    return user


AdminUser = Annotated[User, Depends(get_admin_user)]
