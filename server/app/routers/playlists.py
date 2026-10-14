"""Playlists – eigene, gemeinsame und die der Familie."""

from typing import Literal

from fastapi import APIRouter, HTTPException, Request, Response, UploadFile, status

from app.deps import CurrentUser, DbSession
from app.models import Playlist, PlaylistFollow
from app.schemas.personal import (
    PlaylistAddIn,
    PlaylistCreateIn,
    PlaylistDetailOut,
    PlaylistMoveIn,
    PlaylistOut,
    PlaylistRemoveIn,
    PlaylistUpdateIn,
)
from app.services import playlists as service

router = APIRouter(prefix="/playlists", tags=["Playlists"])

MAX_COVER_BYTES = 10 * 1024 * 1024


def _editable(db: DbSession, user: CurrentUser, playlist_id: int) -> Playlist:
    playlist = service.get_visible(db, user, playlist_id)
    if not service.can_edit_items(user, playlist):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Du darfst diese Playlist nicht bearbeiten.")
    return playlist


def _managed(db: DbSession, user: CurrentUser, playlist_id: int) -> Playlist:
    playlist = service.get_visible(db, user, playlist_id)
    if not service.can_manage(user, playlist):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Nur der Ersteller kann das ändern.")
    return playlist


@router.get("", response_model=list[PlaylistOut])
def list_playlists(
    user: CurrentUser, db: DbSession, scope: Literal["library", "mine", "family"] = "library"
) -> list[PlaylistOut]:
    """library = eigene + gefolgte, mine = nur eigene, family = öffentliche Playlists der anderen."""
    return service.list_playlists(db, user, scope)


@router.post("", response_model=PlaylistDetailOut, status_code=status.HTTP_201_CREATED)
def create_playlist(body: PlaylistCreateIn, user: CurrentUser, db: DbSession) -> PlaylistDetailOut:
    playlist = Playlist(
        owner_id=user.id,
        name=body.name,
        description=body.description,
        is_public=body.is_public or body.is_collaborative,
        is_collaborative=body.is_collaborative,
    )
    db.add(playlist)
    db.flush()
    if body.track_ids:
        service.add_tracks(db, playlist, user, body.track_ids, None)
    db.commit()
    return service.playlist_detail(db, playlist, user)


@router.get("/{playlist_id}", response_model=PlaylistDetailOut)
def get_playlist(playlist_id: int, user: CurrentUser, db: DbSession) -> PlaylistDetailOut:
    return service.playlist_detail(db, service.get_visible(db, user, playlist_id), user)


@router.patch("/{playlist_id}", response_model=PlaylistOut)
def update_playlist(playlist_id: int, body: PlaylistUpdateIn, user: CurrentUser, db: DbSession) -> PlaylistOut:
    playlist = _managed(db, user, playlist_id)
    if body.name is not None:
        playlist.name = body.name
    if body.description is not None:
        playlist.description = body.description
    if body.is_public is not None:
        playlist.is_public = body.is_public
    if body.is_collaborative is not None:
        playlist.is_collaborative = body.is_collaborative
    if playlist.is_collaborative:
        playlist.is_public = True  # gemeinsame Playlists müssen für alle sichtbar sein
    db.commit()
    return service.playlist_out(db, playlist, user)


@router.delete("/{playlist_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_playlist(playlist_id: int, user: CurrentUser, db: DbSession) -> Response:
    db.delete(_managed(db, user, playlist_id))
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post("/{playlist_id}/items", response_model=PlaylistDetailOut)
def add_items(playlist_id: int, body: PlaylistAddIn, user: CurrentUser, db: DbSession) -> PlaylistDetailOut:
    playlist = _editable(db, user, playlist_id)
    service.add_tracks(db, playlist, user, body.track_ids, body.position)
    db.commit()
    return service.playlist_detail(db, playlist, user)


@router.post("/{playlist_id}/items/remove", response_model=PlaylistDetailOut)
def remove_items(playlist_id: int, body: PlaylistRemoveIn, user: CurrentUser, db: DbSession) -> PlaylistDetailOut:
    playlist = _editable(db, user, playlist_id)
    service.remove_items(db, playlist, body.item_ids)
    db.commit()
    return service.playlist_detail(db, playlist, user)


@router.post("/{playlist_id}/items/move", response_model=PlaylistDetailOut)
def move_item(playlist_id: int, body: PlaylistMoveIn, user: CurrentUser, db: DbSession) -> PlaylistDetailOut:
    playlist = _editable(db, user, playlist_id)
    service.move_item(db, playlist, body.item_id, body.position)
    db.commit()
    return service.playlist_detail(db, playlist, user)


@router.put("/{playlist_id}/cover", response_model=PlaylistOut)
def upload_cover(
    playlist_id: int, file: UploadFile, request: Request, user: CurrentUser, db: DbSession
) -> PlaylistOut:
    """Eigenes Coverbild hochladen (JPG/PNG/WebP, max. 10 MB).

    Bewusst ohne async: Das Umrechnen des Bildes läuft so in einem Hilfs-Thread und hält den Server nicht an.
    """
    playlist = _managed(db, user, playlist_id)
    data = file.file.read(MAX_COVER_BYTES + 1)
    if len(data) > MAX_COVER_BYTES:
        raise HTTPException(status.HTTP_413_CONTENT_TOO_LARGE, "Das Bild ist größer als 10 MB.")
    cover_id = request.app.state.covers.add(db, data)
    if cover_id is None:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Das ist kein gültiges Bild.")
    playlist.cover_id = cover_id
    db.commit()
    return service.playlist_out(db, playlist, user)


@router.delete("/{playlist_id}/cover", response_model=PlaylistOut)
def remove_cover(playlist_id: int, user: CurrentUser, db: DbSession) -> PlaylistOut:
    playlist = _managed(db, user, playlist_id)
    playlist.cover_id = None
    db.commit()
    return service.playlist_out(db, playlist, user)


@router.put("/{playlist_id}/follow", status_code=status.HTTP_204_NO_CONTENT)
def follow(playlist_id: int, user: CurrentUser, db: DbSession) -> Response:
    playlist = service.get_visible(db, user, playlist_id)
    if playlist.owner_id != user.id and db.get(PlaylistFollow, (user.id, playlist.id)) is None:
        db.add(PlaylistFollow(user_id=user.id, playlist_id=playlist.id))
        db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.delete("/{playlist_id}/follow", status_code=status.HTTP_204_NO_CONTENT)
def unfollow(playlist_id: int, user: CurrentUser, db: DbSession) -> Response:
    existing = db.get(PlaylistFollow, (user.id, playlist_id))
    if existing is not None:
        db.delete(existing)
        db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


