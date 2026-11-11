"""Anmelden, Token erneuern, Abmelden – und die Selbst-Registrierung (wenn der Betreiber sie eingeschaltet hat)."""

import ipaddress
from datetime import timedelta

from fastapi import APIRouter, HTTPException, Request, Response, status
from fastapi.concurrency import run_in_threadpool
from fastapi.exceptions import RequestValidationError
from pydantic import TypeAdapter, ValidationError
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError

from app.deps import AppSettings, Auth, DbSession, client_ip
from app.locks import write_lock
from app.models import Category, User, utcnow
from app.schemas.user import LoginIn, RefreshIn, RegisterIn, RegisterOut, TokenOut, UserOut, WithdrawIn
from app.security import hash_password, password_needs_rehash, verify_password
from app.services import app_config
from app.services.auth import IssuedTokens, refresh_session, revoke_session, start_session
from app.services.clients import CLIENT_HEADER, parse_client

router = APIRouter(prefix="/auth", tags=["Anmeldung"])

# Header bei 403 für wartende Konten – daran erkennt die App, dass sie „Registrierung zurückziehen“ anbieten kann
ACCOUNT_STATE_HEADER = "X-Selfify-Account-State"
# Namen, die sich niemand selbst geben darf (könnten wie der Betreiber aussehen)
RESERVED_USERNAMES = frozenset(
    {
        "admin", "administrator", "root", "system", "selfify", "support", "owner", "betreiber", "moderator", "null",
        "undefined",
    }
)
# Mehr wartende Konten nimmt der Server nicht an (Schutz gegen massenhaftes Anlegen)
MAX_PENDING_ACCOUNTS = 50
# Obergrenze für selbst registrierte Konten je Stunde über alle Anschlüsse – auch im Modus „open“, wo es sonst keine
# Grenze gäbe (wechselnde Adressen umgehen die Sperre je Anschluss)
MAX_REGISTRATIONS_PER_HOUR = 20

MSG_REGISTRATION_OFF = "Auf diesem Server kann man sich nicht selbst registrieren."
MSG_NAME_TAKEN = "Dieser Benutzername ist nicht verfügbar. Bitte wähle einen anderen."
MSG_TOO_MANY_PENDING = "Gerade warten zu viele neue Konten auf Freischaltung. Bitte versuche es später noch einmal."
MSG_TOO_MANY_NEW = "Gerade werden sehr viele neue Konten angelegt. Bitte versuche es später noch einmal."
MSG_REGISTERED_PENDING = (
    "Dein Konto wurde angelegt und wartet auf Freischaltung durch den Betreiber. "
    "Du kannst dich anmelden, sobald es freigeschaltet ist."
)
MSG_REGISTERED_ACTIVE = "Dein Konto ist eingerichtet."
MSG_ACCOUNT_PENDING = "Dein Konto wartet noch auf Freischaltung durch den Betreiber."
MSG_ACCOUNT_DISABLED = "Dieses Konto ist deaktiviert."
MSG_WRONG_LOGIN = "Benutzername oder Passwort falsch."
MSG_ALREADY_ACTIVE = (
    "Dieses Konto ist schon freigeschaltet. Melde dich an und lösche es unter „Einstellungen“ → „Konto löschen“."
)

_register_adapter = TypeAdapter(RegisterIn)


def token_out(issued: IssuedTokens) -> TokenOut:
    return TokenOut(
        access_token=issued.access_token,
        refresh_token=issued.refresh_token,
        expires_in=issued.expires_in,
        media_token=issued.media_token,
        media_expires_in=issued.media_expires_in,
        user=UserOut.model_validate(issued.user),
    )


def _too_many_failures(retry_after: int) -> HTTPException:
    return HTTPException(
        status.HTTP_429_TOO_MANY_REQUESTS,
        f"Zu viele Fehlversuche. Bitte in {max(1, retry_after // 60)} Minute(n) erneut versuchen.",
        headers={"Retry-After": str(retry_after)},
    )


def _check_password(request: Request, db: DbSession, username: str, password: str) -> User:
    """Benutzer mit Passwort prüfen – mit derselben Bremse gegen Passwort-Raten wie beim Login."""
    limiter = request.app.state.login_limiter
    ip = client_ip(request)
    retry_after = limiter.retry_after(username, ip)
    if retry_after is not None:
        raise _too_many_failures(retry_after)
    user = db.scalar(select(User).where(User.username == username))
    if not verify_password(user.password_hash if user else None, password) or user is None:
        limiter.record_failure(username, ip)
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, MSG_WRONG_LOGIN)
    return user


@router.post("/login", response_model=TokenOut)
def login(body: LoginIn, request: Request, db: DbSession, settings: AppSettings) -> TokenOut:
    limiter = request.app.state.login_limiter
    ip = client_ip(request)
    user = _check_password(request, db, body.username, body.password)
    # Erst nach dem richtigen Passwort verraten, dass das Konto wartet oder gesperrt ist
    if user.approval_pending:
        raise HTTPException(status.HTTP_403_FORBIDDEN, MSG_ACCOUNT_PENDING, headers={ACCOUNT_STATE_HEADER: "pending"})
    if not user.is_active:
        raise HTTPException(status.HTTP_403_FORBIDDEN, MSG_ACCOUNT_DISABLED)

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
        client=parse_client(request.headers.get(CLIENT_HEADER)),
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


# ----------------------------------------------------------- Selbst-Registrierung


def register_key(ip: str) -> str:
    """Schlüssel für die Sperre je Anschluss: IPv6 auf das /64-Netz gekürzt – ein Anschluss hat meist ein ganzes /64
    und damit praktisch beliebig viele Adressen. IPv4 (auch als ::ffff:a.b.c.d) bleibt die einzelne Adresse."""
    try:
        address = ipaddress.ip_address(ip)
    except ValueError:
        return ip
    if isinstance(address, ipaddress.IPv6Address):
        if address.ipv4_mapped is not None:
            return str(address.ipv4_mapped)
        return str(ipaddress.ip_network(f"{address}/64", strict=False))
    return str(address)


def _parse_register(raw: bytes) -> RegisterIn:
    """Prüft den Körper erst hier (nicht schon in FastAPI), damit auch ungültige Versuche gezählt sind.
    Fehler haben die gewohnte 422-Form."""
    try:
        return _register_adapter.validate_json(raw or b"null")
    except ValidationError as exc:
        errors = [{**error, "loc": ("body", *error["loc"])} for error in exc.errors(include_url=False)]
        raise RequestValidationError(errors) from None


def _register(request: Request, response: Response, db: DbSession, settings: AppSettings, raw: bytes) -> RegisterOut:
    values = app_config.get_all(db)
    mode = values["registration_mode"]
    if mode == "off":
        raise HTTPException(status.HTTP_404_NOT_FOUND, MSG_REGISTRATION_OFF)
    limiter = request.app.state.register_limiter
    ip = client_ip(request)
    key = register_key(ip)
    retry_after = limiter.retry_after("*", key)
    if retry_after is not None:
        raise HTTPException(
            status.HTTP_429_TOO_MANY_REQUESTS,
            "Zu viele Registrierungen von diesem Anschluss. "
            f"Bitte in {max(1, retry_after // 60)} Minute(n) erneut versuchen.",
            headers={"Retry-After": str(retry_after)},
        )
    # Jeder Versuch, der bis hier kommt, zählt – auch Erfolg, Namenskonflikt und ungültige Eingaben
    limiter.record_failure("*", key)
    body = _parse_register(raw)
    since = utcnow() - timedelta(hours=1)
    recent = db.scalar(
        select(func.count(User.id)).where(User.self_registered.is_(True), User.created_at >= since)
    ) or 0
    if recent >= MAX_REGISTRATIONS_PER_HOUR:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, MSG_TOO_MANY_NEW)

    taken = body.username in RESERVED_USERNAMES or (
        db.scalar(select(User.id).where(User.username == body.username)) is not None
    )
    if taken:
        hash_password(body.password)  # gleiche Laufzeit wie beim Anlegen: verrät nicht, ob es den Namen gibt
        raise HTTPException(status.HTTP_409_CONFLICT, MSG_NAME_TAKEN)
    if mode == "approval":
        pending = db.scalar(select(func.count(User.id)).where(User.approval_pending.is_(True))) or 0
        if pending >= MAX_PENDING_ACCOUNTS:
            raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, MSG_TOO_MANY_PENDING)

    password_hash = hash_password(body.password)
    category_ids = app_config.default_category_ids(db, values)
    active = mode == "open"
    with write_lock:
        user = User(
            username=body.username,
            display_name=body.display_name or body.username.capitalize(),
            password_hash=password_hash,
            is_admin=False,
            can_download=False,
            all_categories=False,
            self_registered=True,
            is_active=active,
            approval_pending=not active,
            categories=list(db.scalars(select(Category).where(Category.id.in_(category_ids)))) if category_ids else [],
        )
        db.add(user)
        try:
            db.flush()
            issued = None
            if active:
                issued = start_session(
                    db,
                    settings,
                    request.app.state.secret_key,
                    user,
                    device_name=body.device_name,
                    user_agent=request.headers.get("user-agent", ""),
                    ip_address=ip,
                    client=parse_client(request.headers.get(CLIENT_HEADER)),
                )
            db.commit()
        except IntegrityError:
            # Zwei gleichzeitige Registrierungen mit demselben Namen: die Datenbank lässt nur eine zu
            db.rollback()
            raise HTTPException(status.HTTP_409_CONFLICT, MSG_NAME_TAKEN) from None
    if issued is None:
        response.status_code = status.HTTP_202_ACCEPTED
        return RegisterOut(status="pending", message=MSG_REGISTERED_PENDING, tokens=None)
    return RegisterOut(status="active", message=MSG_REGISTERED_ACTIVE, tokens=token_out(issued))


@router.post(
    "/register",
    response_model=RegisterOut,
    status_code=status.HTTP_201_CREATED,
    responses={status.HTTP_202_ACCEPTED: {"model": RegisterOut, "description": "Konto wartet auf Freischaltung"}},
)
async def register(request: Request, response: Response, db: DbSession, settings: AppSettings) -> RegisterOut:
    """Konto selbst anlegen. Modus „approval“: 202, das Konto wartet auf Freischaltung. Modus „open“: 201 mit
    Token wie beim Login. Modus „off“ (Standard): 404. Körper wie RegisterIn."""
    raw = await request.body()
    # Datenbank und Passwort-Hash blockieren – deshalb in einem Hilfs-Thread
    return await run_in_threadpool(_register, request, response, db, settings, raw)


@router.post("/withdraw", status_code=status.HTTP_204_NO_CONTENT)
def withdraw(body: WithdrawIn, request: Request, db: DbSession) -> Response:
    """Registrierung zurückziehen: löscht ein noch nicht freigeschaltetes Konto (ohne Anmeldung, mit Passwort).
    Freigeschaltete Konten löscht man in der App unter „Einstellungen“ → „Konto löschen“."""
    user = _check_password(request, db, body.username, body.password)
    if not user.approval_pending:
        raise HTTPException(status.HTTP_409_CONFLICT, MSG_ALREADY_ACTIVE)
    with write_lock:
        # Stand unter der Sperre neu lesen: Der Admin könnte das Konto gerade freigeschaltet oder gelöscht haben
        current = db.get(User, user.id, populate_existing=True)
        if current is not None:
            if not current.approval_pending:
                raise HTTPException(status.HTTP_409_CONFLICT, MSG_ALREADY_ACTIVE)
            db.delete(current)
            db.commit()
    request.app.state.login_limiter.reset_user(body.username, client_ip(request))
    return Response(status_code=status.HTTP_204_NO_CONTENT)
