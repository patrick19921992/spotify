"""Premium: Status, Code einlösen (Benutzer) und Codes/Lizenzen verwalten (Admin)."""

from fastapi import APIRouter, HTTPException, Request, Response, status
from sqlalchemy import or_, select

from app.deps import AdminUser, CurrentUser, DbSession
from app.locks import write_lock
from app.models import PremiumCode, PremiumLicense, User, utcnow
from app.schemas.premium import (
    CodeCreateIn,
    CodeOut,
    CodeRevokeIn,
    GrantIn,
    LicenseOut,
    PremiumStatusOut,
    RedeemIn,
    RedemptionOut,
    RevokedOut,
    UserPremiumOut,
)
from app.services import premium as service

router = APIRouter(tags=["Premium"])
admin_router = APIRouter(prefix="/admin", tags=["Dashboard – Premium"])


def _status_out(status_: service.PremiumStatus) -> PremiumStatusOut:
    return PremiumStatusOut(active=status_.active, unlimited=status_.unlimited, until=status_.until)


def _license_out(lic: PremiumLicense, now) -> LicenseOut:  # type: ignore[no-untyped-def]
    running = lic.revoked_at is None and lic.starts_at <= now and (lic.expires_at is None or lic.expires_at > now)
    return LicenseOut(
        id=lic.id,
        user_id=lic.user_id,
        username=lic.user.username,
        display_name=lic.user.display_name,
        source=lic.source,  # type: ignore[arg-type]
        code=service.format_code(lic.code.code) if lic.code else None,
        starts_at=lic.starts_at,
        expires_at=lic.expires_at,
        revoked_at=lic.revoked_at,
        note=lic.note,
        running=running,
    )


def _code_out(code: PremiumCode, now) -> CodeOut:  # type: ignore[no-untyped-def]
    redemptions = sorted(code.licenses, key=lambda lic: lic.created_at)
    return CodeOut(
        id=code.id,
        code=service.format_code(code.code),
        label=code.label,
        duration_days=code.duration_days,
        unlimited=code.duration_days is None,
        max_redemptions=code.max_redemptions,
        redeemed_count=code.redeemed_count,
        valid_until=code.valid_until,
        revoked_at=code.revoked_at,
        created_at=code.created_at,
        state=service.code_state(code, now),  # type: ignore[arg-type]
        redemptions=[
            RedemptionOut(
                license_id=lic.id,
                user_id=lic.user_id,
                username=lic.user.username,
                display_name=lic.user.display_name,
                starts_at=lic.starts_at,
                expires_at=lic.expires_at,
                revoked_at=lic.revoked_at,
            )
            for lic in redemptions
        ],
    )


def _get_code(db: DbSession, code_id: int) -> PremiumCode:
    code = db.get(PremiumCode, code_id)
    if code is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Code nicht gefunden.")
    return code


def _get_user(db: DbSession, user_id: int) -> User:
    user = db.get(User, user_id)
    if user is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Benutzer nicht gefunden.")
    return user


def _user_premium_out(db: DbSession, user: User) -> UserPremiumOut:
    now = utcnow()
    licenses = db.scalars(
        select(PremiumLicense).where(PremiumLicense.user_id == user.id).order_by(PremiumLicense.created_at.desc())
    ).unique()
    state = service.premium_status(db, user, now)
    return UserPremiumOut(
        active=state.active,
        unlimited=state.unlimited,
        until=state.until,
        user_id=user.id,
        licenses=[_license_out(lic, now) for lic in licenses],
    )


# ------------------------------------------------------------------ Benutzer


@router.get("/premium", response_model=PremiumStatusOut)
def my_premium(user: CurrentUser, db: DbSession) -> PremiumStatusOut:
    return _status_out(service.premium_status(db, user))


@router.post("/premium/redeem", response_model=PremiumStatusOut)
def redeem_code(body: RedeemIn, request: Request, user: CurrentUser, db: DbSession) -> PremiumStatusOut:
    """Löst einen Premium-Code ein. Falsche Codes werden gezählt – nach zu vielen Fehlversuchen gibt es eine Pause."""
    limiter = request.app.state.redeem_limiter
    # Eingeloggte Benutzer werden nur je Benutzer gebremst, nicht je IP: Eine vorgetäuschte Adresse (X-Forwarded-For)
    # würde sonst jede Sperre aushebeln
    ip = ""
    key = f"redeem:{user.id}"
    retry_after = limiter.retry_after(key, ip)
    if retry_after is not None:
        raise HTTPException(
            status.HTTP_429_TOO_MANY_REQUESTS,
            f"Zu viele Versuche. Bitte in {max(1, retry_after // 60)} Minute(n) erneut versuchen.",
            headers={"Retry-After": str(retry_after)},
        )
    # Prüfen, einfügen und speichern am Stück: Gleichzeitige Einlösungen laufen nacheinander
    with write_lock:
        try:
            service.redeem(db, user, body.code)
        except service.PremiumError as exc:
            # Nur „gibt es nicht“ zählt als Raten; ein bekannter, aber verbrauchter Code ist kein Ratversuch
            if exc.status_code == status.HTTP_404_NOT_FOUND:
                limiter.record_failure(key, ip)
            db.rollback()
            raise HTTPException(exc.status_code, exc.message) from None
        limiter.reset_user(key, ip)
        db.commit()
    return _status_out(service.premium_status(db, user))


# --------------------------------------------------------------------- Admin


@admin_router.get("/premium/codes", response_model=list[CodeOut])
def list_codes(_: AdminUser, db: DbSession) -> list[CodeOut]:
    now = utcnow()
    codes = db.scalars(select(PremiumCode).order_by(PremiumCode.created_at.desc(), PremiumCode.id.desc())).unique()
    return [_code_out(code, now) for code in codes]


@admin_router.post("/premium/codes", response_model=list[CodeOut], status_code=status.HTTP_201_CREATED)
def create_codes(body: CodeCreateIn, admin: AdminUser, db: DbSession) -> list[CodeOut]:
    now = utcnow()
    if body.valid_until is not None and body.valid_until <= now:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "„Einlösbar bis“ muss in der Zukunft liegen.")
    codes = service.create_codes(
        db,
        count=body.count,
        duration_days=None if body.unlimited else body.duration_days,
        max_redemptions=body.max_redemptions,
        valid_until=body.valid_until,
        label=body.label,
        created_by=admin,
    )
    db.commit()
    return [_code_out(code, now) for code in codes]


@admin_router.post("/premium/codes/{code_id}/revoke", response_model=RevokedOut)
def revoke_code(code_id: int, body: CodeRevokeIn, _: AdminUser, db: DbSession) -> RevokedOut:
    """Sperrt den Code. Mit `revoke_licenses` verlieren auch alle, die ihn schon eingelöst haben, ihr Premium."""
    code = _get_code(db, code_id)
    revoked = service.revoke_code(db, code, revoke_licenses=body.revoke_licenses)
    db.commit()
    return RevokedOut(revoked=revoked)


@admin_router.delete("/premium/codes/{code_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_code(code_id: int, _: AdminUser, db: DbSession) -> Response:
    """Löscht einen Code, der nie eingelöst wurde. Eingelöste Codes bitte sperren (dann bleibt die Spur erhalten)."""
    code = _get_code(db, code_id)
    if code.redeemed_count > 0 or code.licenses:
        raise HTTPException(
            status.HTTP_409_CONFLICT, "Dieser Code wurde schon eingelöst – bitte sperren statt löschen."
        )
    db.delete(code)
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@admin_router.get("/premium/licenses", response_model=list[LicenseOut])
def list_licenses(_: AdminUser, db: DbSession, only_running: bool = False) -> list[LicenseOut]:
    now = utcnow()
    query = select(PremiumLicense)
    if only_running:
        # Schon in der Abfrage filtern: Sonst fehlen laufende Lizenzen, sobald es mehr als 1000 gibt
        query = query.where(
            PremiumLicense.revoked_at.is_(None),
            PremiumLicense.starts_at <= now,
            or_(PremiumLicense.expires_at.is_(None), PremiumLicense.expires_at > now),
        )
    licenses = db.scalars(
        query.order_by(PremiumLicense.created_at.desc(), PremiumLicense.id.desc()).limit(1000)
    ).unique()
    return [_license_out(lic, now) for lic in licenses]


@admin_router.post("/premium/licenses/{license_id}/revoke", response_model=RevokedOut)
def revoke_one_license(license_id: int, _: AdminUser, db: DbSession) -> RevokedOut:
    lic = db.get(PremiumLicense, license_id)
    if lic is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Lizenz nicht gefunden.")
    revoked = service.revoke_license(db, lic)
    db.commit()
    return RevokedOut(revoked=int(revoked))


@admin_router.get("/users/{user_id}/premium", response_model=UserPremiumOut)
def get_user_premium(user_id: int, _: AdminUser, db: DbSession) -> UserPremiumOut:
    return _user_premium_out(db, _get_user(db, user_id))


@admin_router.post("/users/{user_id}/premium", response_model=UserPremiumOut, status_code=status.HTTP_201_CREATED)
def grant_user_premium(user_id: int, body: GrantIn, _: AdminUser, db: DbSession) -> UserPremiumOut:
    """Premium direkt vergeben (ohne Code). Zeitlich begrenztes Premium verlängert ein laufendes."""
    user = _get_user(db, user_id)
    with write_lock:
        try:
            service.grant(db, user, days=None if body.unlimited else body.duration_days, note=body.note)
        except service.PremiumError as exc:
            db.rollback()
            raise HTTPException(exc.status_code, exc.message) from None
        db.commit()
    return _user_premium_out(db, user)


@admin_router.delete("/users/{user_id}/premium", response_model=RevokedOut)
def revoke_user_premium(user_id: int, _: AdminUser, db: DbSession) -> RevokedOut:
    """Entzieht dem Benutzer jedes Premium (alle Lizenzen)."""
    user = _get_user(db, user_id)
    revoked = service.revoke_user(db, user.id)
    db.commit()
    return RevokedOut(revoked=revoked)
