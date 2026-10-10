"""YouTube-Suche, Downloads und Live-Fortschritt (WebSocket)."""

import asyncio
import shutil
from typing import Annotated, Literal

from fastapi import APIRouter, HTTPException, Query, Request, Response, WebSocket, WebSocketDisconnect, status
from fastapi.concurrency import run_in_threadpool
from sqlalchemy import delete, select

from app.deps import AdminUser, CurrentUser, DbSession, auth_from_payload
from app.downloads import ytdlp
from app.downloads.youtube import YouTubeError, YouTubeItem, is_youtube_url
from app.models import ACTIVE_STATES, Category, DownloadJob, Playlist, Track, User
from app.schemas.downloads import (
    AlbumDownloadIn,
    BrowseId,
    DownloaderStatusOut,
    DownloadIn,
    JobOut,
    UrlDownloadIn,
    YouTubeAlbumOut,
    YouTubeItemOut,
    YouTubeSearchOut,
)
from app.security import decode_access_token
from app.services.playlists import can_edit_items

router = APIRouter(tags=["YouTube & Downloads"])


def _manager(request: Request):  # type: ignore[no-untyped-def]
    return request.app.state.downloads


def _item_out(db: DbSession, item: YouTubeItem) -> YouTubeItemOut:
    out = YouTubeItemOut(**item.__dict__)
    if item.video_id:
        media_type = "video" if item.type == "video" else "audio"
        out.in_library_track_id = db.scalar(
            select(Track.id).where(Track.source_id == item.video_id, Track.media_type == media_type).limit(1)
        )
        out.active_job_id = db.scalar(
            select(DownloadJob.id)
            .where(DownloadJob.video_id == item.video_id, DownloadJob.status.in_(ACTIVE_STATES))
            .limit(1)
        )
    return out


def _youtube_call(func, *args):  # type: ignore[no-untyped-def]
    try:
        return func(*args)
    except YouTubeError as exc:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(exc)) from None


# ------------------------------------------------------------------ Suche


@router.get("/youtube/search", response_model=YouTubeSearchOut)
def youtube_search(
    request: Request,
    _: CurrentUser,
    db: DbSession,
    q: Annotated[str, Query(min_length=1, max_length=200)],
    type: Literal["songs", "videos", "albums"] = "songs",  # noqa: A002
    limit: Annotated[int, Query(ge=1, le=50)] = 20,
) -> YouTubeSearchOut:
    """Sucht bei YouTube Music. Treffer, die es schon gibt, haben `in_library_track_id`."""
    items = _youtube_call(request.app.state.youtube.search, q, type, limit)
    return YouTubeSearchOut(query=q, type=type, results=[_item_out(db, item) for item in items])


@router.get("/youtube/albums/{browse_id}", response_model=YouTubeAlbumOut)
def youtube_album(browse_id: BrowseId, request: Request, _: CurrentUser, db: DbSession) -> YouTubeAlbumOut:
    album = _youtube_call(request.app.state.youtube.album, browse_id)
    return YouTubeAlbumOut(
        browse_id=album.browse_id,
        title=album.title,
        artists=album.artists,
        year=album.year,
        thumbnail_url=album.thumbnail_url,
        tracks=[_item_out(db, t) for t in album.tracks],
    )


# ------------------------------------------------------------- Aufträge


def _require_download_right(user: User) -> None:
    if not user.can_download:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Du darfst keine Downloads starten – frag einen Admin.")


def _target_category(db: DbSession, category_id: int | None, media_type: str) -> Category:
    if category_id is not None:
        category = db.get(Category, category_id)
        if category is None:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Rubrik nicht gefunden.")
        if category.media_type != media_type:
            kind = "Audio" if media_type == "audio" else "Video"
            raise HTTPException(status.HTTP_400_BAD_REQUEST, f"Die Rubrik \"{category.name}\" ist keine {kind}-Rubrik.")
        return category
    category = db.scalar(
        select(Category).where(Category.media_type == media_type).order_by(
            Category.is_default.desc(), Category.sort_order
        )
    )
    if category is None:
        raise HTTPException(status.HTTP_409_CONFLICT, "Es gibt keine passende Rubrik – bitte zuerst eine anlegen.")
    return category


def _check_playlist(db: DbSession, user: User, playlist_id: int | None) -> None:
    if playlist_id is None:
        return
    playlist = db.get(Playlist, playlist_id)
    if playlist is None or not can_edit_items(user, playlist):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "In diese Playlist darfst du nichts hinzufügen.")


def _visible_job(db: DbSession, user: User, job_id: int) -> DownloadJob:
    job = db.get(DownloadJob, job_id)
    if job is None or (job.user_id != user.id and not user.is_admin):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Download nicht gefunden.")
    return job


@router.post("/downloads", response_model=JobOut, status_code=status.HTTP_201_CREATED)
def create_download(body: DownloadIn, request: Request, user: CurrentUser, db: DbSession) -> JobOut:
    """Song oder Video holen. Gibt es den Titel schon, ist der Auftrag sofort fertig (`track_id`)."""
    _require_download_right(user)
    category = _target_category(db, body.category_id, body.media_type)
    _check_playlist(db, user, body.playlist_id)
    manager = _manager(request)
    job = manager.enqueue(
        db,
        user,
        video_id=body.video_id,
        media_type=body.media_type,
        category=category,
        playlist_id=body.playlist_id,
        title=body.title,
        artists=body.artists,
        album=body.album,
        track_number=body.track_number,
        year=body.year,
        thumbnail_url=body.thumbnail_url,
    )
    return manager.out(db, job)


@router.post("/downloads/album", response_model=list[JobOut], status_code=status.HTTP_201_CREATED)
def download_album(body: AlbumDownloadIn, request: Request, user: CurrentUser, db: DbSession) -> list[JobOut]:
    """Ganzes Album von YouTube Music holen – mit Tracknummern und Album-Cover."""
    _require_download_right(user)
    category = _target_category(db, body.category_id, "audio")
    _check_playlist(db, user, body.playlist_id)
    album = _youtube_call(request.app.state.youtube.album, body.browse_id)
    if not album.tracks:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Dieses Album hat keine verfügbaren Titel.")
    manager = _manager(request)
    jobs = [
        manager.enqueue(
            db,
            user,
            video_id=track.video_id,
            media_type="audio",
            category=category,
            playlist_id=body.playlist_id,
            title=track.title,
            artists=track.artists,
            album=album.title,
            album_artist=album.artists[0] if album.artists else None,
            track_number=track.track_number,
            year=album.year,
            thumbnail_url=album.thumbnail_url,
        )
        for track in album.tracks
        if track.video_id
    ]
    positions = manager.queue_positions(db)
    return [manager.out(db, job, positions) for job in jobs]


@router.post("/downloads/url", response_model=list[JobOut], status_code=status.HTTP_201_CREATED)
async def download_url(body: UrlDownloadIn, request: Request, user: CurrentUser, db: DbSession) -> list[JobOut]:
    """YouTube-Link einfügen (Video oder ganze Playlist)."""
    _require_download_right(user)
    if not is_youtube_url(body.url):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Bitte einen Link von youtube.com oder music.youtube.com.")
    category = _target_category(db, body.category_id, body.media_type)
    _check_playlist(db, user, body.playlist_id)
    settings = request.app.state.settings
    try:
        entries = await run_in_threadpool(ytdlp.resolve_url, settings, body.url)
    except ytdlp.DownloadFailedError as exc:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, str(exc)) from None
    if not entries:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Unter diesem Link wurde nichts gefunden.")
    manager = _manager(request)
    jobs = [
        manager.enqueue(
            db,
            user,
            video_id=entry.video_id,
            media_type=body.media_type,
            category=category,
            playlist_id=body.playlist_id,
            title=entry.title,
            artists=entry.artists,
        )
        for entry in entries[:500]
    ]
    positions = manager.queue_positions(db)
    return [manager.out(db, job, positions) for job in jobs]


@router.get("/downloads", response_model=list[JobOut])
def list_downloads(
    request: Request,
    user: CurrentUser,
    db: DbSession,
    scope: Literal["mine", "all"] = "mine",
    state: Literal["active", "finished", "all"] = "all",
    limit: Annotated[int, Query(ge=1, le=500)] = 100,
) -> list[JobOut]:
    """Eigene Downloads (Admins mit scope=all: alle). Aktive zuerst."""
    query = select(DownloadJob)
    if scope == "mine" or not user.is_admin:
        query = query.where(DownloadJob.user_id == user.id)
    if state == "active":
        query = query.where(DownloadJob.status.in_(ACTIVE_STATES))
    elif state == "finished":
        query = query.where(DownloadJob.status.not_in(ACTIVE_STATES))
    jobs = db.scalars(query.order_by(DownloadJob.created_at.desc(), DownloadJob.id.desc()).limit(limit)).unique().all()
    manager = _manager(request)
    positions = manager.queue_positions(db)
    order = {"downloading": 0, "processing": 0, "queued": 1}
    jobs = sorted(jobs, key=lambda j: (order.get(j.status, 2), positions.get(j.id, 0)))
    return [manager.out(db, job, positions) for job in jobs]


@router.get("/downloads/{job_id}", response_model=JobOut)
def get_download(job_id: int, request: Request, user: CurrentUser, db: DbSession) -> JobOut:
    return _manager(request).out(db, _visible_job(db, user, job_id))


@router.post("/downloads/{job_id}/cancel", response_model=JobOut)
def cancel_download(job_id: int, request: Request, user: CurrentUser, db: DbSession) -> JobOut:
    job = _visible_job(db, user, job_id)
    manager = _manager(request)
    manager.cancel(db, job)
    db.refresh(job)
    return manager.out(db, job)


@router.post("/downloads/{job_id}/retry", response_model=JobOut)
def retry_download(job_id: int, request: Request, user: CurrentUser, db: DbSession) -> JobOut:
    _require_download_right(user)
    job = _visible_job(db, user, job_id)
    manager = _manager(request)
    manager.retry(db, job)
    return manager.out(db, job)


@router.delete("/downloads/{job_id}", status_code=status.HTTP_204_NO_CONTENT)
def remove_download(job_id: int, user: CurrentUser, db: DbSession) -> Response:
    """Eintrag aus der Liste entfernen (nur fertige/abgebrochene; die Datei bleibt)."""
    job = _visible_job(db, user, job_id)
    if job.status in ACTIVE_STATES:
        raise HTTPException(status.HTTP_409_CONFLICT, "Laufende Downloads bitte zuerst abbrechen.")
    db.delete(job)
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.delete("/downloads", status_code=status.HTTP_204_NO_CONTENT)
def clear_finished(user: CurrentUser, db: DbSession) -> Response:
    """Alle eigenen fertigen/fehlgeschlagenen Einträge aus der Liste entfernen."""
    db.execute(delete(DownloadJob).where(DownloadJob.user_id == user.id, DownloadJob.status.not_in(ACTIVE_STATES)))
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


# ------------------------------------------------------------- Live-Fortschritt


@router.websocket("/downloads/ws")
async def downloads_ws(websocket: WebSocket, token: str | None = None) -> None:
    """Live-Fortschritt: Erst eine Liste aller aktiven Downloads ("snapshot"), danach jede Änderung ("job").

    Anmeldung über `?token=<access_token>` oder den Header `Authorization: Bearer …`.
    """
    app = websocket.app
    raw = token or websocket.headers.get("authorization", "").removeprefix("Bearer ").strip()
    payload = decode_access_token(app.state.secret_key, raw) if raw else None

    def authenticate() -> tuple[int, bool, list[dict]] | None:
        with app.state.session_factory() as db:
            try:
                auth = auth_from_payload(db, payload or {})
            except HTTPException:
                return None
            query = select(DownloadJob).where(DownloadJob.status.in_(ACTIVE_STATES))
            if not auth.user.is_admin:
                query = query.where(DownloadJob.user_id == auth.user.id)
            manager = app.state.downloads
            positions = manager.queue_positions(db)
            jobs = [manager.out(db, j, positions).model_dump(mode="json") for j in db.scalars(query).unique()]
            return auth.user.id, auth.user.is_admin, jobs

    result = await run_in_threadpool(authenticate) if payload else None
    if result is None:
        await websocket.close(code=4401, reason="Nicht angemeldet")
        return
    user_id, is_admin, jobs = result
    await websocket.accept()
    hub = app.state.download_events
    subscriber = hub.subscribe(user_id, is_admin)
    try:
        await websocket.send_json({"type": "snapshot", "jobs": jobs})
        receiver = asyncio.create_task(websocket.receive_text())
        while True:
            getter = asyncio.create_task(subscriber.queue.get())
            done, _ = await asyncio.wait({getter, receiver}, timeout=25, return_when=asyncio.FIRST_COMPLETED)
            if receiver in done:
                getter.cancel()
                receiver.result()  # wirft WebSocketDisconnect, wenn die App geschlossen wurde
                receiver = asyncio.create_task(websocket.receive_text())  # "ping" vom Client ignorieren
                continue
            if getter in done:
                await websocket.send_json(getter.result())
            else:
                getter.cancel()
                await websocket.send_json({"type": "ping"})  # hält Proxy-Verbindungen offen
    except (WebSocketDisconnect, RuntimeError):
        pass
    finally:
        hub.unsubscribe(subscriber)


# ------------------------------------------------------------------- Admin


@router.get("/downloads-system", response_model=DownloaderStatusOut)
async def downloader_status(request: Request, _: AdminUser, db: DbSession) -> DownloaderStatusOut:
    settings = request.app.state.settings
    manager = _manager(request)
    version = await run_in_threadpool(ytdlp.ytdlp_version, settings)
    active, queued = manager.counts(db)
    return DownloaderStatusOut(
        ytdlp_version=version,
        deno_available=shutil.which("deno") is not None,
        ffmpeg_available=shutil.which(settings.ffmpeg_path) is not None,
        cookies_configured=settings.ytdl_cookies_file.is_file(),
        auto_update=settings.ytdl_auto_update,
        last_update=manager.last_update,
        last_update_result=manager.last_update_result,
        workers=settings.download_workers,
        audio_format=settings.ytdl_audio_format,
        video_codec=settings.ytdl_video_codec,
        video_max_height=settings.ytdl_video_max_height,
        active_jobs=active,
        queued_jobs=queued,
    )


@router.post("/downloads-system/update", response_model=DownloaderStatusOut)
async def update_ytdlp(request: Request, admin: AdminUser, db: DbSession) -> DownloaderStatusOut:
    """yt-dlp sofort aktualisieren (passiert sonst automatisch einmal am Tag)."""
    ok, message = await run_in_threadpool(_manager(request).update_ytdlp)
    if not ok:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, f"Aktualisierung fehlgeschlagen: {message}")
    return await downloader_status(request, admin, db)
