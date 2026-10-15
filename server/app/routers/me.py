"""Eigenes Konto: Profil, Passwort, angemeldete Geräte."""

from fastapi import APIRouter, HTTPException, Request, Response, status
from sqlalchemy import select

from app.deps import AppSettings, Auth, DbSession
from app.models import UserSession, utcnow
from app.routers.auth import token_out
from app.schemas.user import MeUpdateIn, PasswordChangeIn, SessionOut, TokenOut, UserOut
from app.security import hash_password, verify_password
from app.services.auth import reissue_for_session, revoke_all_sessions, revoke_session

router = APIRouter(prefix="/me", tags=["Mein Konto"])


@router.get("", response_model=UserOut)
def get_me(auth: Auth) -> UserOut:
    return UserOut.model_validate(auth.user)


@router.patch("", response_model=UserOut)
def update_me(body: MeUpdateIn, auth: Auth, db: DbSession) -> UserOut:
    auth.user.display_name = body.display_name
    db.commit()
    return UserOut.model_validate(auth.user)


@router.post("/password", response_model=TokenOut)
def change_password(
    body: PasswordChangeIn, request: Request, auth: Auth, db: DbSession, settings: AppSettings
) -> TokenOut:
    """Ändert das Passwort und meldet alle anderen Geräte ab. Dieses Gerät bekommt neue Token."""
    if not verify_password(auth.user.password_hash, body.current_password):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Das aktuelle Passwort stimmt nicht.")
    auth.user.password_hash = hash_password(body.new_password)
    revoke_all_sessions(db, auth.user.id, except_session_id=auth.session.id)
    issued = reissue_for_session(db, settings, request.app.state.secret_key, auth.session, auth.user)
    db.commit()
    return token_out(issued)


@router.get("/sessions", response_model=list[SessionOut])
def list_sessions(auth: Auth, db: DbSession) -> list[SessionOut]:
    sessions = db.scalars(
        select(UserSession)
        .where(
            UserSession.user_id == auth.user.id,
            UserSession.revoked_at.is_(None),
            UserSession.expires_at > utcnow(),
        )
        .order_by(UserSession.last_used_at.desc())
    )
    return [
        SessionOut(
            id=s.id,
            device_name=s.device_name,
            user_agent=s.user_agent,
            ip_address=s.ip_address,
            created_at=s.created_at,
            last_used_at=s.last_used_at,
            expires_at=s.expires_at,
            current=s.id == auth.session.id,
        )
        for s in sessions
    ]


@router.delete("/sessions/{session_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_session(session_id: int, auth: Auth, db: DbSession) -> Response:
    session = db.get(UserSession, session_id)
    if session is None or session.user_id != auth.user.id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Gerät nicht gefunden.")
    revoke_session(db, session)
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
