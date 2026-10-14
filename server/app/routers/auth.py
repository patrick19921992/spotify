"""Anmelden, Token erneuern, Abmelden."""

from fastapi import APIRouter, HTTPException, Request, Response, status
from sqlalchemy import select

from app.deps import AppSettings, Auth, DbSession, client_ip
from app.models import User
from app.schemas.user import LoginIn, RefreshIn, TokenOut, UserOut
from app.security import hash_password, password_needs_rehash, verify_password
from app.services.auth import IssuedTokens, refresh_session, revoke_session, start_session

router = APIRouter(prefix="/auth", tags=["Anmeldung"])


def token_out(issued: IssuedTokens) -> TokenOut:
    return TokenOut(
        access_token=issued.access_token,
        refresh_token=issued.refresh_token,
        expires_in=issued.expires_in,
        media_token=issued.media_token,
        media_expires_in=issued.media_expires_in,
        user=UserOut.model_validate(issued.user),
    )


@router.post("/login", response_model=TokenOut)
def login(body: LoginIn, request: Request, db: DbSession, settings: AppSettings) -> TokenOut:
    limiter = request.app.state.login_limiter
    ip = client_ip(request)
    retry_after = limiter.retry_after(body.username, ip)
    if retry_after is not None:
        raise HTTPException(
            status.HTTP_429_TOO_MANY_REQUESTS,
            f"Zu viele Fehlversuche. Bitte in {max(1, retry_after // 60)} Minute(n) erneut versuchen.",
            headers={"Retry-After": str(retry_after)},
        )

    user = db.scalar(select(User).where(User.username == body.username))
    if not verify_password(user.password_hash if user else None, body.password) or user is None:
        limiter.record_failure(body.username, ip)
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Benutzername oder Passwort falsch.")
    if not user.is_active:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Dieses Konto ist deaktiviert.")

    limiter.reset_user(body.username, ip)
    if password_needs_rehash(user.password_hash):
        user.password_hash = hash_password(body.password)
    issued = start_session(
        db,
        settings,
        request.app.state.secret_key,
        user,
        device_name=body.device_name,
        user_agent=request.headers.get("user-agent", ""),
        ip_address=ip,
    )
    db.commit()
    return token_out(issued)


@router.post("/refresh", response_model=TokenOut)
def refresh(body: RefreshIn, request: Request, db: DbSession, settings: AppSettings) -> TokenOut:
    issued = refresh_session(db, settings, request.app.state.secret_key, body.refresh_token, client_ip(request))
    if issued is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Anmeldung abgelaufen. Bitte neu anmelden.")
    db.commit()
    return token_out(issued)


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
def logout(auth: Auth, db: DbSession) -> Response:
    revoke_session(db, auth.session)
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
