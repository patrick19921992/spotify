"""Dashboard-Daten für den Admin: Zahlen, Benutzer mit Premium, App-Versionen und App-Einstellungen."""

from fastapi import APIRouter, HTTPException, status
from sqlalchemy import func, select

from app.deps import AdminUser, DbSession
from app.models import DownloadJob, User, UserSession, utcnow
from app.schemas.premium import PremiumStatusOut
from app.schemas.support import AdminUserOut, AppConfigIn, AppConfigOut, ClientVersionOut, StatsOut
from app.services import app_config, premium, stats

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
                premium=PremiumStatusOut(active=state.active, unlimited=state.unlimited, until=state.until),
                downloads=int(downloads.get(user.id, 0)),
                devices=int(devices.get(user.id, 0)),
                last_client=_client_text(last),
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


@router.get("/config", response_model=AppConfigOut)
def get_config(_: AdminUser, db: DbSession) -> AppConfigOut:
    return AppConfigOut(**app_config.get_all(db))


@router.put("/config", response_model=AppConfigOut)
def update_config(body: AppConfigIn, _: AdminUser, db: DbSession) -> AppConfigOut:
    changes = body.model_dump(exclude_none=True)
    try:
        values = app_config.update(db, changes)
    except app_config.ConfigError as exc:
        db.rollback()
        raise HTTPException(status.HTTP_400_BAD_REQUEST, str(exc)) from None
    db.commit()
    return AppConfigOut(**values)
