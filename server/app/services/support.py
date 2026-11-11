"""Song-Wünsche und Fehlermeldungen: Grenzen gegen Missbrauch und Status-Nachführung."""

from datetime import datetime, timedelta

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.models import BugReport, SongRequest, User, utcnow
from app.services import features as feature_set

MAX_OPEN_REQUESTS = 20
MAX_REQUESTS_PER_DAY = 15
MAX_BUG_REPORTS_PER_HOUR = 10
# Gratis-Grenze für Wünsche: rollierend über die letzten 7 Tage
REQUEST_WEEK = timedelta(days=7)


class SupportError(Exception):
    def __init__(self, status_code: int, message: str) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.message = message


def _same(a: str, b: str) -> bool:
    return " ".join(a.lower().split()) == " ".join(b.lower().split())


def week_requests(db: Session, user: User, now: datetime | None = None) -> list[datetime]:
    """Zeitpunkte der eigenen Wünsche der letzten 7 Tage (alle Zustände; zurückgezogene sind gelöscht), älteste
    zuerst."""
    now = now or utcnow()
    return sorted(
        db.scalars(
            select(SongRequest.created_at).where(
                SongRequest.user_id == user.id, SongRequest.created_at > now - REQUEST_WEEK
            )
        )
    )


def create_request(
    db: Session, user: User, *, title: str, artist: str, note: str, weekly_limit: int | None = None
) -> SongRequest:
    """weekly_limit: Gratis-Grenze je 7 Tage (None = keine, wie vor Teil 2; 0 = gar keine Wünsche)."""
    now = utcnow()
    mine = db.scalars(select(SongRequest).where(SongRequest.user_id == user.id)).unique().all()
    open_ones = [r for r in mine if r.status in ("open", "accepted")]
    if len(open_ones) >= MAX_OPEN_REQUESTS:
        raise SupportError(429, f"Du hast schon {MAX_OPEN_REQUESTS} offene Wünsche. Warte, bis einige erledigt sind.")
    if sum(1 for r in mine if r.created_at > now - timedelta(days=1)) >= MAX_REQUESTS_PER_DAY:
        raise SupportError(429, "Du hast heute schon sehr viele Wünsche geschickt. Versuche es morgen wieder.")
    if any(_same(r.title, title) and _same(r.artist, artist) for r in open_ones):
        raise SupportError(409, "Diesen Wunsch hast du schon geschickt.")
    if weekly_limit is not None:
        if weekly_limit == 0:
            raise SupportError(403, feature_set.MSG_REQUESTS_NONE)
        if len(week_requests(db, user, now)) >= weekly_limit:
            raise SupportError(429, feature_set.requests_week_message(weekly_limit))
    request = SongRequest(user_id=user.id, title=title, artist=artist, note=note)
    db.add(request)
    db.flush()
    return request


def sync_request_states(db: Session) -> None:
    """Wunsch mit laufendem Download nachführen: fertig -> erledigt. Scheitert oder fehlt der Download, wartet der
    Wunsch nicht ewig als „in Arbeit“ (der Benutzer könnte ihn sonst nie zurückziehen und käme ans Offen-Limit),
    sondern ist wieder offen – der Admin sieht ihn im Dashboard erneut."""
    pending = db.scalars(select(SongRequest).where(SongRequest.status == "accepted")).unique().all()
    for request in pending:
        job = request.job
        if job is not None and job.status == "done":
            request.status = "done"
        elif job is None or job.status in ("failed", "cancelled"):
            request.status = "open"
    db.flush()


def create_bug_report(
    db: Session,
    user: User,
    *,
    message: str,
    app_version: str,
    app_build: int | None,
    platform: str,
    channel: str,
    device: str,
    log: str,
) -> BugReport:
    since = utcnow() - timedelta(hours=1)
    recent = db.scalar(
        select(func.count(BugReport.id)).where(BugReport.user_id == user.id, BugReport.created_at > since)
    )
    if (recent or 0) >= MAX_BUG_REPORTS_PER_HOUR:
        raise SupportError(429, "Du hast gerade schon mehrere Fehler gemeldet. Bitte versuche es später wieder.")
    report = BugReport(
        user_id=user.id,
        message=message,
        app_version=app_version,
        app_build=app_build,
        platform=platform,
        channel=channel,
        device=device,
        log=log,
    )
    db.add(report)
    db.flush()
    return report
