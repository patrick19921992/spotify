"""Bibliothek: Künstler, Alben, Titel, Suche und Scan."""

import threading
from dataclasses import asdict
from typing import Annotated

from fastapi import APIRouter, HTTPException, Query, Request, status

from app.deps import AdminUser, CurrentUser, DbSession
from app.models import Album, Artist, Category, Track
from app.schemas.library import (
    AlbumDetailOut,
    AlbumOut,
    ArtistDetailOut,
    ArtistOut,
    LibraryStatsOut,
    Page,
    ScanRequestIn,
    ScanStatusOut,
    SearchOut,
    TrackOut,
)
from app.services import library as service

router = APIRouter(tags=["Bibliothek"])

Limit = Annotated[int, Query(ge=1, le=500)]
Offset = Annotated[int, Query(ge=0)]
MediaTypeFilter = Annotated[str | None, Query(pattern="^(audio|video)$")]


def _not_found(what: str) -> HTTPException:
    return HTTPException(status.HTTP_404_NOT_FOUND, f"{what} nicht gefunden.")


@router.get("/artists", response_model=Page[ArtistOut])
def list_artists(
    _: CurrentUser,
    db: DbSession,
    limit: Limit = 50,
    offset: Offset = 0,
    sort: service.ArtistSort = "name",
    category_id: int | None = None,
    q: str | None = None,
) -> Page[ArtistOut]:
    return service.list_artists(db, limit=limit, offset=offset, sort=sort, category_id=category_id, q=q)


@router.get("/artists/{artist_id}", response_model=ArtistDetailOut)
def get_artist(artist_id: int, _: CurrentUser, db: DbSession) -> ArtistDetailOut:
    artist = db.get(Artist, artist_id)
    if artist is None:
        raise _not_found("Künstler")
    return service.artist_detail(db, artist)


@router.get("/albums", response_model=Page[AlbumOut])
def list_albums(
    _: CurrentUser,
    db: DbSession,
    limit: Limit = 50,
    offset: Offset = 0,
    sort: service.AlbumSort = "title",
    category_id: int | None = None,
    artist_id: int | None = None,
    q: str | None = None,
) -> Page[AlbumOut]:
    return service.list_albums(
        db, limit=limit, offset=offset, sort=sort, category_id=category_id, artist_id=artist_id, q=q
    )


@router.get("/albums/{album_id}", response_model=AlbumDetailOut)
def get_album(album_id: int, _: CurrentUser, db: DbSession) -> AlbumDetailOut:
    album = db.get(Album, album_id)
    if album is None:
        raise _not_found("Album")
    return service.album_detail(db, album)


@router.get("/tracks", response_model=Page[TrackOut])
def list_tracks(
    _: CurrentUser,
    db: DbSession,
    limit: Limit = 50,
    offset: Offset = 0,
    sort: service.TrackSort = "title",
    category_id: int | None = None,
    media_type: MediaTypeFilter = None,
    artist_id: int | None = None,
    album_id: int | None = None,
    q: str | None = None,
) -> Page[TrackOut]:
    return service.list_tracks(
        db,
        limit=limit,
        offset=offset,
        sort=sort,
        category_id=category_id,
        media_type=media_type,
        artist_id=artist_id,
        album_id=album_id,
        q=q,
    )


@router.get("/tracks/{track_id}", response_model=TrackOut)
def get_track(track_id: int, _: CurrentUser, db: DbSession) -> TrackOut:
    track = db.get(Track, track_id)
    if track is None:
        raise _not_found("Titel")
    return service.track_out(track)


@router.get("/search", response_model=SearchOut)
def search(
    _: CurrentUser,
    db: DbSession,
    q: Annotated[str, Query(min_length=1, max_length=200)],
    limit: Annotated[int, Query(ge=1, le=50)] = 10,
    category_id: int | None = None,
) -> SearchOut:
    return service.search(db, q, limit=limit, category_id=category_id)


@router.get("/library", response_model=LibraryStatsOut)
def library_stats(request: Request, _: CurrentUser, db: DbSession) -> LibraryStatsOut:
    counts = service.library_counts(db)
    return LibraryStatsOut(**counts, scan=ScanStatusOut(**asdict(request.app.state.scanner.status)))


@router.get("/library/scan", response_model=ScanStatusOut)
def scan_status(request: Request, _: CurrentUser) -> ScanStatusOut:
    return ScanStatusOut(**asdict(request.app.state.scanner.status))


@router.post("/library/scan", response_model=ScanStatusOut, status_code=status.HTTP_202_ACCEPTED)
def start_scan(body: ScanRequestIn, request: Request, _: AdminUser, db: DbSession) -> ScanStatusOut:
    """Bibliothek neu einlesen (nur Admins). Normalerweise passiert das automatisch."""
    scanner = request.app.state.scanner
    ids = None
    if body.category_id is not None:
        if db.get(Category, body.category_id) is None:
            raise _not_found("Rubrik")
        ids = [body.category_id]
    if body.wait:
        return ScanStatusOut(**asdict(scanner.scan(ids)))
    if scanner.background_active:
        scanner.request_scan(ids)
    else:
        threading.Thread(target=scanner.scan, args=(ids,), daemon=True).start()
    return ScanStatusOut(**asdict(scanner.status))
