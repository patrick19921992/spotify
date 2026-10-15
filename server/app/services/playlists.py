"""Playlists: anlegen, Titel hinzufügen/entfernen/verschieben, Rechte, Mosaik-Cover."""

from fastapi import HTTPException, status
from sqlalchemy import func, select, text, update
from sqlalchemy.orm import Session

from app.models import Playlist, PlaylistFollow, PlaylistItem, Track, User, utcnow
from app.schemas.personal import PlaylistDetailOut, PlaylistItemOut, PlaylistOut, UserRef
from app.services.library import track_out

MAX_ITEMS = 10_000


# ------------------------------------------------------------------- Rechte

def can_view(user: User, playlist: Playlist) -> bool:
    return playlist.owner_id == user.id or playlist.is_public


def can_edit_items(user: User, playlist: Playlist) -> bool:
    """Eigentümer – oder alle, wenn die Playlist gemeinsam (und sichtbar) ist."""
    return playlist.owner_id == user.id or (playlist.is_public and playlist.is_collaborative)


def can_manage(user: User, playlist: Playlist) -> bool:
    """Umbenennen, Cover, Sichtbarkeit, Löschen: nur Eigentümer (oder Admin)."""
    return playlist.owner_id == user.id or user.is_admin


def get_visible(db: Session, user: User, playlist_id: int) -> Playlist:
    playlist = db.get(Playlist, playlist_id)
    if playlist is None or not (can_view(user, playlist) or user.is_admin):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Playlist nicht gefunden.")
    return playlist


# --------------------------------------------------------------- Ausgabe

def mosaic_for(db: Session, playlist_id: int) -> list[str]:
    """Bis zu 4 verschiedene Cover in Playlist-Reihenfolge – für das 2×2-Mosaik."""
    cover_ids = db.scalars(
        select(Track.cover_id)
        .join(PlaylistItem, PlaylistItem.track_id == Track.id)
        .where(PlaylistItem.playlist_id == playlist_id, Track.cover_id.is_not(None))
        .order_by(PlaylistItem.position)
        .limit(60)
    ).all()
    mosaic: list[str] = []
    for cover_id in cover_ids:
        if cover_id not in mosaic:
            mosaic.append(cover_id)
        if len(mosaic) == 4:
            break
    return mosaic


def _cover_color(db: Session, playlist: Playlist, mosaic: list[str]) -> str | None:
    if playlist.cover is not None:
        return playlist.cover.color
    if mosaic:
        from app.models import Cover

        cover = db.get(Cover, mosaic[0])
        return cover.color if cover else None
    return None


def playlist_out(db: Session, playlist: Playlist, user: User, following: set[int] | None = None) -> PlaylistOut:
    if following is None:
        following = followed_ids(db, user.id)
    mosaic = mosaic_for(db, playlist.id)
    return PlaylistOut(
        id=playlist.id,
        name=playlist.name,
        description=playlist.description,
        owner=UserRef(id=playlist.owner.id, display_name=playlist.owner.display_name),
        is_public=playlist.is_public,
        is_collaborative=playlist.is_collaborative,
        track_count=playlist.track_count,
        duration=playlist.duration,
        cover_id=playlist.cover_id,
        mosaic=mosaic,
        cover_color=_cover_color(db, playlist, mosaic),
        created_at=playlist.created_at,
        updated_at=playlist.updated_at,
        is_owner=playlist.owner_id == user.id,
        is_following=playlist.id in following,
        can_edit=can_edit_items(user, playlist),
    )


def playlist_detail(db: Session, playlist: Playlist, user: User) -> PlaylistDetailOut:
    items = db.scalars(
        select(PlaylistItem).where(PlaylistItem.playlist_id == playlist.id).order_by(PlaylistItem.position)
    ).unique().all()
    return PlaylistDetailOut(
        **playlist_out(db, playlist, user).model_dump(),
        items=[
            PlaylistItemOut(
                item_id=item.id,
                position=item.position,
                added_at=item.added_at,
                added_by=UserRef(id=item.added_by.id, display_name=item.added_by.display_name)
                if item.added_by
                else None,
                track=track_out(item.track),
            )
            for item in items
        ],
    )


def followed_ids(db: Session, user_id: int) -> set[int]:
    return set(db.scalars(select(PlaylistFollow.playlist_id).where(PlaylistFollow.user_id == user_id)))


def list_playlists(db: Session, user: User, scope: str) -> list[PlaylistOut]:
    """scope: "library" = eigene + gefolgte, "mine" = nur eigene, "family" = öffentliche der anderen."""
    following = followed_ids(db, user.id)
    query = select(Playlist)
    if scope == "mine":
        query = query.where(Playlist.owner_id == user.id)
    elif scope == "family":
        query = query.where(Playlist.owner_id != user.id, Playlist.is_public.is_(True))
    else:
        query = query.where(
            (Playlist.owner_id == user.id) | (Playlist.id.in_(following) & Playlist.is_public.is_(True))
        )
    playlists = db.scalars(query.order_by(Playlist.updated_at.desc())).unique().all()
    return [playlist_out(db, p, user, following) for p in playlists]


# ------------------------------------------------------------- Ändern

def refresh_stats(db: Session, playlist: Playlist) -> None:
    playlist.track_count = db.scalar(
        select(func.count(PlaylistItem.id)).where(PlaylistItem.playlist_id == playlist.id)
    ) or 0
    playlist.duration = float(
        db.scalar(
            select(func.coalesce(func.sum(Track.duration), 0))
            .join(PlaylistItem, PlaylistItem.track_id == Track.id)
            .where(PlaylistItem.playlist_id == playlist.id)
        )
        or 0
    )
    playlist.updated_at = utcnow()


def _renumber(db: Session, playlist_id: int, ordered_ids: list[int] | None = None) -> None:
    if ordered_ids is None:
        ordered_ids = list(
            db.scalars(
                select(PlaylistItem.id)
                .where(PlaylistItem.playlist_id == playlist_id)
                .order_by(PlaylistItem.position, PlaylistItem.id)
            )
        )
    for position, item_id in enumerate(ordered_ids):
        db.execute(update(PlaylistItem).where(PlaylistItem.id == item_id).values(position=position))


def add_tracks(db: Session, playlist: Playlist, user: User, track_ids: list[int], position: int | None) -> int:
    existing = set(db.scalars(select(Track.id).where(Track.id.in_(set(track_ids)))))
    missing = [track_id for track_id in track_ids if track_id not in existing]
    if missing:
        raise HTTPException(status.HTTP_404_NOT_FOUND, f"Titel nicht gefunden: {missing[:5]}")
    count = playlist.track_count
    if count + len(track_ids) > MAX_ITEMS:
        raise HTTPException(status.HTTP_409_CONFLICT, f"Eine Playlist kann höchstens {MAX_ITEMS} Titel haben.")
    if position is None or position >= count:
        position = count
    else:
        db.execute(
            update(PlaylistItem)
            .where(PlaylistItem.playlist_id == playlist.id, PlaylistItem.position >= position)
            .values(position=PlaylistItem.position + len(track_ids))
        )
    now = utcnow()
    for offset, track_id in enumerate(track_ids):
        db.add(
            PlaylistItem(
                playlist_id=playlist.id,
                track_id=track_id,
                position=position + offset,
                added_by_id=user.id,
                added_at=now,
            )
        )
    db.flush()
    refresh_stats(db, playlist)
    return len(track_ids)


def remove_items(db: Session, playlist: Playlist, item_ids: list[int]) -> int:
    items = db.scalars(
        select(PlaylistItem).where(PlaylistItem.playlist_id == playlist.id, PlaylistItem.id.in_(set(item_ids)))
    ).all()
    for item in items:
        db.delete(item)
    db.flush()
    _renumber(db, playlist.id)
    refresh_stats(db, playlist)
    return len(items)


def move_item(db: Session, playlist: Playlist, item_id: int, position: int) -> None:
    ordered = list(
        db.scalars(
            select(PlaylistItem.id)
            .where(PlaylistItem.playlist_id == playlist.id)
            .order_by(PlaylistItem.position, PlaylistItem.id)
        )
    )
    if item_id not in ordered:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Eintrag nicht in dieser Playlist.")
    ordered.remove(item_id)
    ordered.insert(min(position, len(ordered)), item_id)
    _renumber(db, playlist.id, ordered)
    playlist.updated_at = utcnow()


def refresh_all_stats(db: Session) -> None:
    """Nach dem Entfernen von Titeln (Scan) Zähler aller Playlists korrigieren und Lücken schließen."""
    db.execute(
        text(
            """
            UPDATE playlists SET
              track_count = (SELECT COUNT(*) FROM playlist_items i WHERE i.playlist_id = playlists.id),
              duration = (SELECT COALESCE(SUM(t.duration), 0) FROM playlist_items i
                          JOIN tracks t ON t.id = i.track_id WHERE i.playlist_id = playlists.id)
            """
        )
    )
    # Lücken schließen: Reihenfolge erst vollständig berechnen (Fensterfunktion), dann schreiben –
    # eine Unterabfrage je Zeile würde schon umnummerierte Zeilen sehen und die Reihenfolge verwürfeln.
    db.execute(
        text(
            """
            UPDATE playlist_items SET position = ranked.rn
            FROM (
              SELECT id, ROW_NUMBER() OVER (PARTITION BY playlist_id ORDER BY position, id) - 1 AS rn
              FROM playlist_items
            ) AS ranked
            WHERE ranked.id = playlist_items.id AND playlist_items.position <> ranked.rn
            """
        )
    )
