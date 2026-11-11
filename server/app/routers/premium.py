"""Premium: Status, Code einlösen, Kauf über Google Play melden (Benutzer); Codes, Lizenzen, Käufe verwalten (Admin)."""

from datetime import datetime
from typing import Any

from fastapi import APIRouter, HTTPException, Request, Response, status
from sqlalchemy import or_, select
from sqlalchemy.exc import IntegrityError

from app.deps import AdminUser, AppSettings, CurrentUser, DbSession
from app.locks import write_lock
from app.models import PlayPurchase, PremiumCode, PremiumLicense, User, utcnow
from app.schemas.premium import (
    CodeCreateIn,
    CodeOut,
    CodeRevokeIn,
    GrantIn,
    LicenseOut,
    MyPremiumOut,
    PlaySubscriptionOut,
    PlayVerifyIn,
    PlayVerifyOut,
    PurchaseOut,
    RedeemIn,
    RedemptionOut,
    RevokedOut,
    UserPremiumOut,
)
from app.services import app_config, play_billing
from app.services import features as feature_set
from app.services import premium as service

router = APIRouter(tags=["Premium"])
admin_router = APIRouter(prefix="/admin", tags=["Dashboard – Premium"])


def _my_premium_out(db: DbSession, user: User, config: dict[str, Any], now: datetime) -> MyPremiumOut:
    """Premium-Stand für die App. Admins dürfen immer offline hören – sie brauchen dafür kein Premium.
    Dazu, was der Betreiber nur mit Premium erlaubt und was davon diesem Benutzer gerade fehlt."""
    state = service.premium_status(db, user, now)
    required = bool(config["offline_requires_premium"])
    subscription = play_billing.current_subscription(db, user.id)
    only = feature_set.premium_only(config)
    access = feature_set.Access(is_admin=user.is_admin, features=state.features, premium_only=tuple(only))
    return MyPremiumOut(
        active=state.active,
        unlimited=state.unlimited,
        until=state.until,
        features=feature_set.ordered(state.features),
        offline_requires_premium=required,
        offline_allowed=not required or user.is_admin or "offline" in state.features,
        offline_grace_days=config["offline_grace_days"],
        checked_at=now,
        play=PlaySubscriptionOut(
            product_id=subscription.product_id,
            state=subscription.state,  # type: ignore[arg-type]
            expires_at=subscription.expires_at,
            auto_renewing=subscription.auto_renewing,
            base_plan_id=subscription.base_plan_id,
            offer_id=subscription.offer_id,
        )
        if subscription
        else None,
        premium_only=only,
        locked=access.locked,
        badge=bool(config["premium_badge_enabled"]) and "badge" in state.features,
    )


def _purchase_out(purchase: PlayPurchase) -> PurchaseOut:
    return PurchaseOut(
        id=purchase.id,
        user_id=purchase.user_id,
        username=purchase.user.username,
        display_name=purchase.user.display_name,
        product_id=purchase.product_id,
        order_id=purchase.order_id,
        state=purchase.state,  # type: ignore[arg-type]
        expires_at=purchase.expires_at,
        auto_renewing=purchase.auto_renewing,
        acknowledged=purchase.acknowledged,
        is_test=purchase.is_test,
        license_id=purchase.license_id,
        license_revoked=purchase.license is not None and purchase.license.revoked_at is not None,
        last_checked_at=purchase.last_checked_at,
        last_error=purchase.last_error,
        created_at=purchase.created_at,
        base_plan_id=purchase.base_plan_id,
        offer_id=purchase.offer_id,
    )


def _too_many(retry_after: int) -> HTTPException:
    return HTTPException(
        status.HTTP_429_TOO_MANY_REQUESTS,
        f"Zu viele Versuche. Bitte in {max(1, retry_after // 60)} Minute(n) erneut versuchen.",
        headers={"Retry-After": str(retry_after)},
    )


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
        features=feature_set.as_list(lic.features),
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
        features=feature_set.as_list(code.features),
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
        features=feature_set.ordered(state.features),
        user_id=user.id,
        licenses=[_license_out(lic, now) for lic in licenses],
    )


# ------------------------------------------------------------------ Benutzer


@router.get("/premium", response_model=MyPremiumOut)
def my_premium(request: Request, user: CurrentUser, db: DbSession, settings: AppSettings) -> MyPremiumOut:
    """Premium-Stand – samt der Frage, ob Offline-Hören erlaubt ist. Laufende Käufe über Google Play werden dabei
    erneut geprüft (gedrosselt). Kann der Stand gerade nicht geprüft werden, gibt es 503 statt „kein Premium“:
    Die App behandelt das als „unbekannt“ und löscht nichts."""
    now = utcnow()
    clear = play_billing.refresh_user(
        db,
        user,
        play_billing.current_verifier(request.app.state, settings),
        now,
        recheck_hours=settings.play_recheck_hours,
        backoff=request.app.state.billing_backoff,
    )
    if not clear:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, play_billing.MSG_STATUS_UNKNOWN)
    return _my_premium_out(db, user, app_config.get_all(db), now)


@router.post("/premium/redeem", response_model=MyPremiumOut)
def redeem_code(body: RedeemIn, request: Request, user: CurrentUser, db: DbSession) -> MyPremiumOut:
    """Löst einen Premium-Code ein. Falsche Codes werden gezählt – nach zu vielen Fehlversuchen gibt es eine Pause."""
    limiter = request.app.state.redeem_limiter
    # Eingeloggte Benutzer werden nur je Benutzer gebremst, nicht je IP: Eine vorgetäuschte Adresse (X-Forwarded-For)
    # würde sonst jede Sperre aushebeln
    ip = ""
    key = f"redeem:{user.id}"
    retry_after = limiter.retry_after(key, ip)
    if retry_after is not None:
        raise _too_many(retry_after)
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
    return _my_premium_out(db, user, app_config.get_all(db), utcnow())


@router.post("/premium/play/verify", response_model=PlayVerifyOut)
def verify_play_purchase(
    body: PlayVerifyIn, request: Request, user: CurrentUser, db: DbSession, settings: AppSettings
) -> PlayVerifyOut:
    """Die Play-Version meldet einen Kauf (oder stellt einen wieder her). Der Server fragt Google, ob der Kauf echt
    ist, und verbindet ihn mit diesem Konto. Ein Kauf gehört genau einem Konto."""
    limiter = request.app.state.billing_limiter
    ip = ""  # wie beim Einlösen: nur je Benutzer bremsen
    key = f"billing:{user.id}"
    retry_after = limiter.retry_after(key, ip)
    if retry_after is not None:
        raise _too_many(retry_after)
    config = app_config.get_all(db)
    if not config["billing_enabled"]:
        raise HTTPException(status.HTTP_409_CONFLICT, "Der Kauf in der App ist auf diesem Server nicht eingeschaltet.")
    if body.product_id not in app_config.product_ids(config):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, play_billing.MSG_UNKNOWN_PRODUCT)
    verifier = play_billing.current_verifier(request.app.state, settings)
    if verifier is None:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, play_billing.MSG_NOT_CONFIGURED)
    # Google ohne Sperre fragen (Netz) – der Token erscheint dabei in keinem Protokoll
    try:
        info = verifier.get_subscription(body.purchase_token)
    except play_billing.PurchaseNotFound:
        limiter.record_failure(key, ip)  # erfundene Token zählen als Raten
        raise HTTPException(status.HTTP_404_NOT_FOUND, play_billing.MSG_NOT_FOUND) from None
    except play_billing.VerifierUnavailable:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, play_billing.MSG_UNAVAILABLE) from None
    now = utcnow()
    # Prüfen, zuordnen und speichern am Stück: Reichen zwei Konten denselben Kauf gleichzeitig ein, bekommt ihn eines
    with write_lock:
        try:
            purchase = play_billing.register_purchase(db, user, body.product_id, body.purchase_token, info, now)
            db.commit()
        except service.PremiumError as exc:
            db.rollback()
            raise HTTPException(exc.status_code, exc.message) from None
        except IntegrityError:
            db.rollback()
            raise HTTPException(status.HTTP_409_CONFLICT, play_billing.MSG_OTHER_ACCOUNT) from None
    # Erst nach dem Zuordnen bei Google bestätigen: Einen abgelehnten Kauf erstattet Google dann von selbst
    play_billing.acknowledge(db, purchase, verifier, now)
    if (
        play_billing.awaiting_renewal(purchase, now)
        and service.premium_status(db, user, now).features != feature_set.ALL
    ):
        # Zeitraum gerade um, Verlängerung bei Google noch nicht verbucht: „unbekannt“ – die App löscht nichts
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, play_billing.MSG_STATUS_UNKNOWN)
    if play_billing.has_access(purchase.state, purchase.expires_at, now):
        result = "active"
    elif purchase.state == "pending":
        result = "pending"
    else:
        result = "inactive"
    return PlayVerifyOut(result=result, premium=_my_premium_out(db, user, config, now))  # type: ignore[arg-type]


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
        features=body.features,
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


@admin_router.get("/premium/purchases", response_model=list[PurchaseOut])
def list_purchases(_: AdminUser, db: DbSession) -> list[PurchaseOut]:
    """Käufe über Google Play, neueste zuerst. Der Kauf-Token wird nie ausgegeben."""
    purchases = db.scalars(
        select(PlayPurchase).order_by(PlayPurchase.created_at.desc(), PlayPurchase.id.desc()).limit(1000)
    ).unique()
    return [_purchase_out(purchase) for purchase in purchases]


@admin_router.post("/premium/purchases/{purchase_id}/recheck", response_model=PurchaseOut)
def recheck_purchase(
    purchase_id: int, request: Request, _: AdminUser, db: DbSession, settings: AppSettings
) -> PurchaseOut:
    """Fragt Google sofort nach dem Stand dieses Kaufs (ohne Drosselung)."""
    purchase = db.get(PlayPurchase, purchase_id)
    if purchase is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Kauf nicht gefunden.")
    verifier = play_billing.current_verifier(request.app.state, settings)
    if verifier is None:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, play_billing.MSG_NOT_CONFIGURED)
    try:
        play_billing.recheck_purchase(db, purchase, verifier, utcnow())
    except play_billing.UnclearNotFound as exc:
        # Kein Ausfall von Google, sondern vermutlich eine falsche Einstellung: Der Admin braucht diesen Hinweis,
        # nicht den Text für Benutzer („Käufe wiederherstellen“)
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, str(exc)) from None
    except play_billing.VerifierUnavailable:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, play_billing.MSG_UNAVAILABLE) from None
    request.app.state.billing_backoff.pop(purchase.id, None)
    return _purchase_out(purchase)
