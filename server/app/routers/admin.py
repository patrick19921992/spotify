"""Dashboard-Daten für den Admin: Zahlen, Benutzer mit Premium, App-Versionen und App-Einstellungen."""

from fastapi import APIRouter, HTTPException, Request, status
from sqlalchemy import func, select

from app.connect.hub import hub_of
from app.deps import AdminUser, AppSettings, DbSession
from app.models import DownloadJob, User, UserSession, utcnow
from app.schemas.premium import BillingStatusOut, BillingTestOut, PremiumStatusOut
from app.schemas.support import AdminUserOut, AppConfigIn, AppConfigOut, ClientVersionOut, StatsOut
from app.services import app_config, play_billing, premium, stats
from app.services import features as feature_set

router = APIRouter(prefix="/admin", tags=["Dashboard"])


def _client_text(session: UserSession | None) -> str:
    """z. B. „play 1.0.0 (54)“"""
    if session is None:
        return ""
    build = f" ({session.client_build})" if session.client_build else ""
    return f"{session.client_channel} {session.client_version}{build}"


@router.get("/stats", response_model=StatsOut)
def get_stats(_: AdminUser, db: DbSession) -> StatsOut:
    return stats.collect(db)


@router.get("/users", response_model=list[AdminUserOut])
def list_users(_: AdminUser, db: DbSession) -> list[AdminUserOut]:
    """Alle Benutzer mit Premium-Status, Anzahl Downloads und Geräten (für das Dashboard)."""
    users = db.scalars(select(User).order_by(User.username)).all()
    now = utcnow()
    states = premium.premium_statuses(db, [u.id for u in users], now)
    downloads = dict(db.execute(select(DownloadJob.user_id, func.count()).group_by(DownloadJob.user_id)).all())
    devices = dict(
        db.execute(
            select(UserSession.user_id, func.count())
            .where(UserSession.revoked_at.is_(None), UserSession.expires_at > now)
            .group_by(UserSession.user_id)
        ).all()
    )
    last_active = dict(
        db.execute(select(UserSession.user_id, func.max(UserSession.last_used_at)).group_by(UserSession.user_id)).all()
    )
    last_sessions: dict[int, UserSession] = {}
    for session in db.scalars(
        select(UserSession).where(UserSession.client_version != "").order_by(UserSession.last_used_at)
    ):
        last_sessions[session.user_id] = session  # später Geräte überschreiben frühere
    out = []
    for user in users:
        state = states[user.id]
        last = last_sessions.get(user.id)
        out.append(
            AdminUserOut(
                id=user.id,
                username=user.username,
                display_name=user.display_name,
                is_admin=user.is_admin,
                is_active=user.is_active,
                can_download=user.can_download,
                created_at=user.created_at,
                last_login_at=user.last_login_at,
                last_active_at=last_active.get(user.id),
                premium=PremiumStatusOut(
                    active=state.active,
                    unlimited=state.unlimited,
                    until=state.until,
                    features=feature_set.ordered(state.features),
                ),
                downloads=int(downloads.get(user.id, 0)),
                devices=int(devices.get(user.id, 0)),
                last_client=_client_text(last),
                all_categories=user.all_categories,
                category_ids=user.category_ids,
                approval_pending=user.approval_pending,
                self_registered=user.self_registered,
            )
        )
    return out


@router.get("/clients", response_model=list[ClientVersionOut])
def client_versions(_: AdminUser, db: DbSession) -> list[ClientVersionOut]:
    """Welche App-Versionen sind auf den angemeldeten Geräten – damit man sieht, wer noch ein Update braucht."""
    rows = db.execute(
        select(
            UserSession.client_platform,
            UserSession.client_channel,
            UserSession.client_version,
            UserSession.client_build,
            func.count(UserSession.id),
            func.count(func.distinct(UserSession.user_id)),
            func.max(UserSession.last_used_at),
        )
        .where(UserSession.revoked_at.is_(None), UserSession.expires_at > utcnow(), UserSession.client_version != "")
        .group_by(
            UserSession.client_platform,
            UserSession.client_channel,
            UserSession.client_version,
            UserSession.client_build,
        )
        .order_by(func.max(UserSession.last_used_at).desc())
    ).all()
    return [
        ClientVersionOut(
            platform=platform, channel=channel, version=version, build=build, devices=int(devices),
            users=int(users), last_seen=last_seen,
        )
        for platform, channel, version, build, devices, users, last_seen in rows
    ]


def _transcode_available(request: Request) -> bool:
    return bool(request.app.state.transcoder.available)


@router.get("/config", response_model=AppConfigOut)
def get_config(request: Request, _: AdminUser, db: DbSession) -> AppConfigOut:
    return AppConfigOut(**app_config.get_all(db), transcode_available=_transcode_available(request))


@router.put("/config", response_model=AppConfigOut)
def update_config(request: Request, body: AppConfigIn, _: AdminUser, db: DbSession) -> AppConfigOut:
    changes = body.model_dump(exclude_none=True)
    available = _transcode_available(request)
    # Tonqualität einschränken heißt umwandeln: ohne ffmpeg bekämen Benutzer ohne Premium gar keinen Ton
    if (
        changes.get("hq_audio_requires_premium") is True
        and not app_config.get_all(db)["hq_audio_requires_premium"]
        and not available
    ):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, feature_set.MSG_HQ_NEEDS_FFMPEG)
    try:
        values = app_config.update(db, changes)
    except app_config.ConfigError as exc:
        db.rollback()
        raise HTTPException(status.HTTP_400_BAD_REQUEST, str(exc)) from None
    db.commit()
    # Premium-Schalter können sich geändert haben: offene Geräte-Verbindungen gleich neu prüfen
    if hub := hub_of(request.app):
        hub.refresh_all()
    return AppConfigOut(**values, transcode_available=available)


@router.get("/billing/status", response_model=BillingStatusOut)
def billing_status(request: Request, _: AdminUser, db: DbSession, settings: AppSettings) -> BillingStatusOut:
    """Ist die Kaufprüfung für Google Play eingerichtet? Gibt nur den Pfad der Schlüsseldatei aus, nie den Inhalt."""
    values = app_config.get_all(db)
    return BillingStatusOut(
        configured=play_billing.current_verifier(request.app.state, settings) is not None,
        package_name=settings.play_package_name,
        key_file=str(settings.play_service_account_file),
        product_ids=app_config.product_ids(values),
        enabled=values["billing_enabled"],
    )


@router.post("/billing/test", response_model=BillingTestOut)
def billing_test(request: Request, _: AdminUser, settings: AppSettings) -> BillingTestOut:
    """„Verbindung testen“: holt mit dem Dienstkonto ein Zugriffstoken bei Google. Antwortet immer mit 200."""
    verifier = play_billing.current_verifier(request.app.state, settings)
    try:
        if verifier is None:
            # Sagt genau, woran es liegt: Datei fehlt oder ist ungültig
            play_billing.load_service_account(settings.play_service_account_file)
            return BillingTestOut(ok=False, message=play_billing.MSG_KEY_INVALID)
        verifier.check_access()
    except play_billing.VerifierUnavailable as exc:
        return BillingTestOut(ok=False, message=str(exc))
    return BillingTestOut(ok=True, message="Verbindung zu Google Play steht.")
