"""Zahlen für das Dashboard: Benutzer, Downloads, Wiedergaben, Premium, Geräte."""

from datetime import datetime, timedelta

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.models import (
    ACTIVE_STATES,
    BugReport,
    DownloadJob,
    PlayHistory,
    PremiumCode,
    PremiumLicense,
    SongRequest,
    Track,
    User,
    UserSession,
    utcnow,
)
from app.schemas.support import DayCountOut, StatsOut, TopUserOut
from app.services.premium import code_state, premium_statuses

DAYS = 14


def _per_day(db: Session, column, since: datetime, now: datetime) -> list[DayCountOut]:  # type: ignore[no-untyped-def]
    rows = db.execute(
        select(func.date(column), func.count()).where(column >= since).group_by(func.date(column))
    ).all()
    counts = {str(day): int(count) for day, count in rows}
    start = since.date()
    days = [(start + timedelta(days=i)).isoformat() for i in range((now.date() - start).days + 1)]
    return [DayCountOut(day=day, count=counts.get(day, 0)) for day in days]


def collect(db: Session, now: datetime | None = None) -> StatsOut:
    now = now or utcnow()
    since_days = (now - timedelta(days=DAYS - 1)).replace(hour=0, minute=0, second=0, microsecond=0)

    def count(query) -> int:  # type: ignore[no-untyped-def]
        return int(db.scalar(query) or 0)

    user_ids = list(db.scalars(select(User.id)))
    premium = premium_statuses(db, user_ids, now)
    top = db.execute(
        select(DownloadJob.user_id, func.count(DownloadJob.id).label("n"))
        .where(DownloadJob.user_id.is_not(None))
        .group_by(DownloadJob.user_id)
        .order_by(func.count(DownloadJob.id).desc())
        .limit(5)
    ).all()
    names = {u.id: u.display_name for u in db.scalars(select(User).where(User.id.in_([row[0] for row in top])))}
    codes = db.scalars(select(PremiumCode)).unique().all()

    return StatsOut(
        users_total=len(user_ids),
        users_active=count(select(func.count(User.id)).where(User.is_active.is_(True))),
        tracks_total=count(select(func.count(Track.id)).where(Track.media_type == "audio")),
        videos_total=count(select(func.count(Track.id)).where(Track.media_type == "video")),
        downloads_total=count(select(func.count(DownloadJob.id))),
        downloads_done=count(select(func.count(DownloadJob.id)).where(DownloadJob.status == "done")),
        downloads_failed=count(select(func.count(DownloadJob.id)).where(DownloadJob.status == "failed")),
        downloads_active=count(select(func.count(DownloadJob.id)).where(DownloadJob.status.in_(ACTIVE_STATES))),
        downloads_last_24h=count(
            select(func.count(DownloadJob.id)).where(DownloadJob.created_at >= now - timedelta(hours=24))
        ),
        downloads_last_7d=count(
            select(func.count(DownloadJob.id)).where(DownloadJob.created_at >= now - timedelta(days=7))
        ),
        downloads_by_day=_per_day(db, DownloadJob.created_at, since_days, now),
        plays_by_day=_per_day(db, PlayHistory.played_at, since_days, now),
        top_downloaders=[
            TopUserOut(user_id=int(uid), display_name=names.get(uid, "?"), count=int(n)) for uid, n in top
        ],
        premium_users=sum(1 for s in premium.values() if s.active),
        premium_unlimited=sum(1 for s in premium.values() if s.unlimited),
        codes_available=sum(1 for c in codes if code_state(c, now) == "available"),
        requests_open=count(select(func.count(SongRequest.id)).where(SongRequest.status == "open")),
        bugs_new=count(select(func.count(BugReport.id)).where(BugReport.status == "new")),
        devices_active_7d=count(
            select(func.count(UserSession.id)).where(
                UserSession.revoked_at.is_(None), UserSession.last_used_at >= now - timedelta(days=7)
            )
        ),
    )


def licenses_count(db: Session) -> int:
    return int(db.scalar(select(func.count(PremiumLicense.id))) or 0)
