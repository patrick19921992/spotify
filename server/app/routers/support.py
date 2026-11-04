"""Song-Wünsche und Fehlermeldungen: Benutzer schicken sie ab, der Admin bearbeitet sie im Dashboard."""

from typing import Literal

from fastapi import APIRouter, HTTPException, Response, status
from sqlalchemy import select

from app.deps import AdminUser, CurrentUser, DbSession
from app.locks import write_lock
from app.models import BugReport, DownloadJob, SongRequest, utcnow
from app.schemas.support import (
    AdminRequestOut,
    BugPatchIn,
    BugReportIn,
    BugReportOut,
    RequestIn,
    RequestOut,
    RequestPatchIn,
    UserBrief,
)
from app.services import support as service

router = APIRouter(tags=["Wünsche & Fehlermeldungen"])
admin_router = APIRouter(prefix="/admin", tags=["Dashboard – Wünsche & Fehlermeldungen"])


def _request_out(item: SongRequest) -> RequestOut:
    return RequestOut(
        id=item.id,
        title=item.title,
        artist=item.artist,
        note=item.note,
        status=item.status,  # type: ignore[arg-type]
        admin_note=item.admin_note,
        created_at=item.created_at,
        updated_at=item.updated_at,
        job_status=item.job.status if item.job else None,
    )


def _brief(user) -> UserBrief:  # type: ignore[no-untyped-def]
    return UserBrief(id=user.id, username=user.username, display_name=user.display_name)


def _admin_request_out(item: SongRequest) -> AdminRequestOut:
    return AdminRequestOut(**_request_out(item).model_dump(), user=_brief(item.user), job_id=item.job_id)


def _bug_out(item: BugReport) -> BugReportOut:
    return BugReportOut(
        id=item.id,
        user=_brief(item.user),
        message=item.message,
        app_version=item.app_version,
        app_build=item.app_build,
        platform=item.platform,
        channel=item.channel,
        device=item.device,
        log=item.log,
        status=item.status,  # type: ignore[arg-type]
        admin_note=item.admin_note,
        created_at=item.created_at,
    )


# ------------------------------------------------------------------ Benutzer


@router.post("/requests", response_model=RequestOut, status_code=status.HTTP_201_CREATED)
def create_request(body: RequestIn, user: CurrentUser, db: DbSession) -> RequestOut:
    """„Song wünschen“. Der Admin sieht den Wunsch im Dashboard und entscheidet."""
    # Zählen, einfügen und speichern am Stück – sonst umgehen gleichzeitige Anfragen die Grenzen
    with write_lock:
        try:
            item = service.create_request(db, user, title=body.title, artist=body.artist, note=body.note)
        except service.SupportError as exc:
            raise HTTPException(exc.status_code, exc.message) from None
        db.commit()
    return _request_out(item)


@router.get("/requests", response_model=list[RequestOut])
def my_requests(user: CurrentUser, db: DbSession) -> list[RequestOut]:
    service.sync_request_states(db)
    db.commit()
    items = db.scalars(
        select(SongRequest)
        .where(SongRequest.user_id == user.id)
        .order_by(SongRequest.created_at.desc(), SongRequest.id.desc())
        .limit(200)
    ).unique()
    return [_request_out(item) for item in items]


@router.delete("/requests/{request_id}", status_code=status.HTTP_204_NO_CONTENT)
def withdraw_request(request_id: int, user: CurrentUser, db: DbSession) -> Response:
    """Eigenen Wunsch zurückziehen (nur solange er noch offen ist) bzw. aus der Liste entfernen."""
    item = db.get(SongRequest, request_id)
    if item is None or item.user_id != user.id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Wunsch nicht gefunden.")
    if item.status == "accepted":
        # Erst nachführen: Ein gescheiterter oder verschwundener Download macht den Wunsch wieder offen
        service.sync_request_states(db)
        db.refresh(item)
    if item.status == "accepted":
        raise HTTPException(status.HTTP_409_CONFLICT, "Dieser Wunsch wird gerade erfüllt.")
    db.delete(item)
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post("/bugreports", status_code=status.HTTP_201_CREATED)
def create_bug_report(body: BugReportIn, user: CurrentUser, db: DbSession) -> dict[str, int]:
    with write_lock:
        try:
            report = service.create_bug_report(
                db,
                user,
                message=body.message,
                app_version=body.app_version,
                app_build=body.app_build,
                platform=body.platform,
                channel=body.channel,
                device=body.device,
                log=body.log,
            )
        except service.SupportError as exc:
            raise HTTPException(exc.status_code, exc.message) from None
        db.commit()
    return {"id": report.id}


# --------------------------------------------------------------------- Admin


@admin_router.get("/requests", response_model=list[AdminRequestOut])
def admin_requests(
    _: AdminUser,
    db: DbSession,
    state: Literal["open", "accepted", "done", "declined", "all"] = "all",
) -> list[AdminRequestOut]:
    service.sync_request_states(db)
    db.commit()
    query = select(SongRequest)
    if state != "all":
        query = query.where(SongRequest.status == state)
    items = db.scalars(query.order_by(SongRequest.created_at.desc(), SongRequest.id.desc()).limit(500)).unique()
    return [_admin_request_out(item) for item in items]


@admin_router.patch("/requests/{request_id}", response_model=AdminRequestOut)
def admin_update_request(request_id: int, body: RequestPatchIn, admin: AdminUser, db: DbSession) -> AdminRequestOut:
    item = db.get(SongRequest, request_id)
    if item is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Wunsch nicht gefunden.")
    if body.job_id is not None:
        job = db.get(DownloadJob, body.job_id)
        if job is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Download nicht gefunden.")
        item.job = job  # Beziehung setzen, damit die Antwort den Download-Zustand gleich mitliefert
        item.status = "accepted"
    if body.status is not None:
        item.status = body.status
    if body.admin_note is not None:
        item.admin_note = body.admin_note
    item.handled_by_id = admin.id
    item.updated_at = utcnow()
    service.sync_request_states(db)
    db.commit()
    return _admin_request_out(item)


@admin_router.delete("/requests/{request_id}", status_code=status.HTTP_204_NO_CONTENT)
def admin_delete_request(request_id: int, _: AdminUser, db: DbSession) -> Response:
    item = db.get(SongRequest, request_id)
    if item is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Wunsch nicht gefunden.")
    db.delete(item)
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@admin_router.get("/bugreports", response_model=list[BugReportOut])
def admin_bug_reports(
    _: AdminUser, db: DbSession, state: Literal["new", "seen", "done", "all"] = "all"
) -> list[BugReportOut]:
    query = select(BugReport)
    if state != "all":
        query = query.where(BugReport.status == state)
    items = db.scalars(query.order_by(BugReport.created_at.desc(), BugReport.id.desc()).limit(500)).unique()
    return [_bug_out(item) for item in items]


@admin_router.patch("/bugreports/{report_id}", response_model=BugReportOut)
def admin_update_bug(report_id: int, body: BugPatchIn, _: AdminUser, db: DbSession) -> BugReportOut:
    item = db.get(BugReport, report_id)
    if item is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Fehlermeldung nicht gefunden.")
    if body.status is not None:
        item.status = body.status
    if body.admin_note is not None:
        item.admin_note = body.admin_note
    db.commit()
    return _bug_out(item)


@admin_router.delete("/bugreports/{report_id}", status_code=status.HTTP_204_NO_CONTENT)
def admin_delete_bug(report_id: int, _: AdminUser, db: DbSession) -> Response:
    item = db.get(BugReport, report_id)
    if item is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Fehlermeldung nicht gefunden.")
    db.delete(item)
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
