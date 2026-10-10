"""Persönliches: Lieblingssongs, Bibliothek, Verlauf, Startseite, Mixe, Radio."""

from typing import Annotated

from fastapi import APIRouter, Query, Response, status

from app.deps import CurrentUser, DbSession
from app.schemas.library import Page, TrackOut
from app.schemas.personal import (
    ContextOut,
    HistoryEntryOut,
    HistoryIn,
    HomeOut,
    LibraryOut,
    LikedIdsOut,
    LikedTrackOut,
    MixOut,
)
from app.services import personal as service
from app.services.library import track_out

router = APIRouter(tags=["Persönlich"])

NO_CONTENT = status.HTTP_204_NO_CONTENT


@router.get("/home", response_model=HomeOut)
def home(user: CurrentUser, db: DbSession) -> HomeOut:
    """Alles für die Startseite: Schnellzugriff, Zuletzt gehört, Mixe, Top-Songs, Neues."""
    return service.home(db, user)


@router.get("/me/library", response_model=LibraryOut)
def library(user: CurrentUser, db: DbSession) -> LibraryOut:
    return service.library(db, user)


@router.get("/me/likes", response_model=Page[LikedTrackOut])
def likes(
    user: CurrentUser,
    db: DbSession,
    limit: Annotated[int, Query(ge=1, le=1000)] = 100,
    offset: Annotated[int, Query(ge=0)] = 0,
) -> Page[LikedTrackOut]:
    return service.list_likes(db, user, limit, offset)


@router.get("/me/likes/ids", response_model=LikedIdsOut)
def liked_ids(user: CurrentUser, db: DbSession) -> LikedIdsOut:
    return service.liked_ids(db, user)


@router.put("/me/likes/{track_id}", status_code=NO_CONTENT)
def like(track_id: int, user: CurrentUser, db: DbSession) -> Response:
    service.set_like(db, user, track_id, True)
    db.commit()
    return Response(status_code=NO_CONTENT)


@router.delete("/me/likes/{track_id}", status_code=NO_CONTENT)
def unlike(track_id: int, user: CurrentUser, db: DbSession) -> Response:
    service.set_like(db, user, track_id, False)
    db.commit()
    return Response(status_code=NO_CONTENT)


@router.put("/me/albums/{album_id}", status_code=NO_CONTENT)
def save_album(album_id: int, user: CurrentUser, db: DbSession) -> Response:
    service.set_album_saved(db, user, album_id, True)
    db.commit()
    return Response(status_code=NO_CONTENT)


@router.delete("/me/albums/{album_id}", status_code=NO_CONTENT)
def unsave_album(album_id: int, user: CurrentUser, db: DbSession) -> Response:
    service.set_album_saved(db, user, album_id, False)
    db.commit()
    return Response(status_code=NO_CONTENT)


@router.put("/me/artists/{artist_id}", status_code=NO_CONTENT)
def follow_artist(artist_id: int, user: CurrentUser, db: DbSession) -> Response:
    service.set_artist_followed(db, user, artist_id, True)
    db.commit()
    return Response(status_code=NO_CONTENT)


@router.delete("/me/artists/{artist_id}", status_code=NO_CONTENT)
def unfollow_artist(artist_id: int, user: CurrentUser, db: DbSession) -> Response:
    service.set_artist_followed(db, user, artist_id, False)
    db.commit()
    return Response(status_code=NO_CONTENT)


@router.post("/me/history", status_code=NO_CONTENT)
def add_history(body: HistoryIn, user: CurrentUser, db: DbSession) -> Response:
    """Die App meldet jeden gespielten Titel (mit gehörten Sekunden und Quelle)."""
    service.add_history(db, user, body)
    db.commit()
    return Response(status_code=NO_CONTENT)


@router.get("/me/history", response_model=list[HistoryEntryOut])
def history(
    user: CurrentUser, db: DbSession, limit: Annotated[int, Query(ge=1, le=500)] = 50
) -> list[HistoryEntryOut]:
    return service.recent_history(db, user, limit)


@router.delete("/me/history", status_code=NO_CONTENT)
def clear_history(user: CurrentUser, db: DbSession) -> Response:
    service.clear_history(db, user)
    db.commit()
    return Response(status_code=NO_CONTENT)


@router.get("/me/recent", response_model=list[ContextOut])
def recent(user: CurrentUser, db: DbSession, limit: Annotated[int, Query(ge=1, le=50)] = 20) -> list[ContextOut]:
    return service.recent_contexts(db, user, limit)


@router.get("/me/top-tracks", response_model=list[TrackOut])
def my_top_tracks(
    user: CurrentUser, db: DbSession, limit: Annotated[int, Query(ge=1, le=100)] = 50
) -> list[TrackOut]:
    return [track_out(t) for t in service.top_tracks(db, user, limit)]


@router.get("/mixes/{key:path}", response_model=MixOut)
def mix(key: str, user: CurrentUser, db: DbSession) -> MixOut:
    """Mixe: genre:<Genre>, artist:<ID>, category:<ID>, discover, recent."""
    return service.get_mix(db, user, key)


@router.get("/tracks/{track_id}/radio", response_model=list[TrackOut])
def radio(
    track_id: int, user: CurrentUser, db: DbSession, limit: Annotated[int, Query(ge=2, le=200)] = 50
) -> list[TrackOut]:
    """Endlos weiterhören: der Titel zuerst, danach Passendes (gleiche Künstler, Genre, Album)."""
    return [track_out(t) for t in service.radio(db, user, track_id, limit)]
