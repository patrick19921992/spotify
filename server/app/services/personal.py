"""Lieblingssongs, gespeicherte Alben/Künstler, Hörverlauf, Startseite, Mixe und Radio."""

import random
from datetime import UTC, date, datetime, timedelta

from fastapi import HTTPException, status
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.models import (
    Album,
    AlbumSave,
    Artist,
    ArtistFollow,
    Category,
    Cover,
    PlayHistory,
    Playlist,
    Track,
    TrackArtist,
    TrackLike,
    User,
    utcnow,
)
from app.schemas.library import Page
from app.schemas.personal import (
    ContextOut,
    HistoryEntryOut,
    HistoryIn,
    HomeOut,
    HomeSection,
    LibraryOut,
    LikedIdsOut,
    LikedTrackOut,
    MixOut,
)
from app.services.library import album_out, artist_out, track_out
from app.services.playlists import can_view, list_playlists, mosaic_for

# Ab so vielen Sekunden zählt ein Titel als "gehört" (wie bei Spotify)
COUNTED_PLAY_SECONDS = 30
TOP_WINDOW = timedelta(days=30)
MIX_SIZE = 50


# ----------------------------------------------------------- Lieblingssongs

def list_likes(db: Session, user: User, limit: int, offset: int) -> Page[LikedTrackOut]:
    total = db.scalar(select(func.count()).select_from(TrackLike).where(TrackLike.user_id == user.id)) or 0
    likes = db.scalars(
        select(TrackLike)
        .where(TrackLike.user_id == user.id)
        .order_by(TrackLike.created_at.desc(), TrackLike.track_id.desc())
        .limit(limit)
        .offset(offset)
    ).unique().all()
    return Page(
        items=[LikedTrackOut(liked_at=like.created_at, track=track_out(like.track)) for like in likes],
        total=total,
        limit=limit,
        offset=offset,
    )


def _require(db: Session, model: type, object_id: int, what: str) -> None:
    if db.get(model, object_id) is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, f"{what} nicht gefunden.")


def set_like(db: Session, user: User, track_id: int, liked: bool) -> None:
    _require(db, Track, track_id, "Titel")
    existing = db.get(TrackLike, (user.id, track_id))
    if liked and existing is None:
        db.add(TrackLike(user_id=user.id, track_id=track_id))
    elif not liked and existing is not None:
        db.delete(existing)


def set_album_saved(db: Session, user: User, album_id: int, saved: bool) -> None:
    _require(db, Album, album_id, "Album")
    existing = db.get(AlbumSave, (user.id, album_id))
    if saved and existing is None:
        db.add(AlbumSave(user_id=user.id, album_id=album_id))
    elif not saved and existing is not None:
        db.delete(existing)


def set_artist_followed(db: Session, user: User, artist_id: int, followed: bool) -> None:
    _require(db, Artist, artist_id, "Künstler")
    existing = db.get(ArtistFollow, (user.id, artist_id))
    if followed and existing is None:
        db.add(ArtistFollow(user_id=user.id, artist_id=artist_id))
    elif not followed and existing is not None:
        db.delete(existing)


def liked_ids(db: Session, user: User) -> LikedIdsOut:
    from app.models import PlaylistFollow

    return LikedIdsOut(
        tracks=list(db.scalars(select(TrackLike.track_id).where(TrackLike.user_id == user.id))),
        albums=list(db.scalars(select(AlbumSave.album_id).where(AlbumSave.user_id == user.id))),
        artists=list(db.scalars(select(ArtistFollow.artist_id).where(ArtistFollow.user_id == user.id))),
        playlists=list(db.scalars(select(PlaylistFollow.playlist_id).where(PlaylistFollow.user_id == user.id))),
    )


def library(db: Session, user: User) -> LibraryOut:
    albums = db.scalars(
        select(Album)
        .join(AlbumSave, AlbumSave.album_id == Album.id)
        .where(AlbumSave.user_id == user.id)
        .order_by(AlbumSave.created_at.desc())
    ).unique().all()
    artists = db.scalars(
        select(Artist)
        .join(ArtistFollow, ArtistFollow.artist_id == Artist.id)
        .where(ArtistFollow.user_id == user.id)
        .order_by(ArtistFollow.created_at.desc())
    ).unique().all()
    return LibraryOut(
        liked_count=db.scalar(select(func.count()).select_from(TrackLike).where(TrackLike.user_id == user.id)) or 0,
        playlists=list_playlists(db, user, "library"),
        albums=[album_out(a) for a in albums],
        artists=[artist_out(a) for a in artists],
    )


# ------------------------------------------------------------- Hörverlauf

def add_history(db: Session, user: User, entry: HistoryIn) -> None:
    _require(db, Track, entry.track_id, "Titel")
    db.add(
        PlayHistory(
            user_id=user.id,
            track_id=entry.track_id,
            seconds=entry.seconds,
            context_type=entry.context_type,
            context_id=entry.context_id,
            played_at=utcnow(),
        )
    )


def recent_history(db: Session, user: User, limit: int) -> list[HistoryEntryOut]:
    rows = db.execute(
        select(PlayHistory, Track)
        .join(Track, Track.id == PlayHistory.track_id)
        .where(PlayHistory.user_id == user.id)
        .order_by(PlayHistory.played_at.desc(), PlayHistory.id.desc())
        .limit(limit * 3)
    ).unique().all()
    result: list[HistoryEntryOut] = []
    last_track: int | None = None
    for entry, track in rows:
        if track.id == last_track:  # gleicher Titel direkt hintereinander -> nur einmal
            continue
        last_track = track.id
        result.append(
            HistoryEntryOut(
                played_at=entry.played_at,
                seconds=entry.seconds,
                context_type=entry.context_type,
                context_id=entry.context_id,
                track=track_out(track),
            )
        )
        if len(result) >= limit:
            break
    return result


def clear_history(db: Session, user: User) -> None:
    from sqlalchemy import delete

    db.execute(delete(PlayHistory).where(PlayHistory.user_id == user.id))


def _counted():  # type: ignore[no-untyped-def]
    return PlayHistory.seconds >= COUNTED_PLAY_SECONDS


def top_tracks(db: Session, user: User | None, limit: int, since: datetime | None = None) -> list[Track]:
    """Meistgehörte Titel – eines Benutzers oder (user=None) der ganzen Familie."""
    since = since or utcnow() - TOP_WINDOW
    plays = (
        select(PlayHistory.track_id, func.count().label("plays"))
        .where(_counted(), PlayHistory.played_at >= since)
        .group_by(PlayHistory.track_id)
    )
    if user is not None:
        plays = plays.where(PlayHistory.user_id == user.id)
    plays_sub = plays.subquery()
    return list(
        db.scalars(
            select(Track)
            .join(plays_sub, plays_sub.c.track_id == Track.id)
            .order_by(plays_sub.c.plays.desc(), Track.sort_title)
            .limit(limit)
        ).unique().all()
    )


def top_artists(db: Session, user: User, limit: int) -> list[Artist]:
    since = utcnow() - TOP_WINDOW
    plays = (
        select(TrackArtist.artist_id, func.count().label("plays"))
        .join(PlayHistory, PlayHistory.track_id == TrackArtist.track_id)
        .where(PlayHistory.user_id == user.id, _counted(), PlayHistory.played_at >= since)
        .group_by(TrackArtist.artist_id)
        .subquery()
    )
    return list(
        db.scalars(
            select(Artist).join(plays, plays.c.artist_id == Artist.id).order_by(plays.c.plays.desc()).limit(limit)
        ).unique().all()
    )


# --------------------------------------------------------- Kontexte/Kacheln

def _cover_color(db: Session, cover_id: str | None) -> str | None:
    if not cover_id:
        return None
    cover = db.get(Cover, cover_id)
    return cover.color if cover else None


def liked_context(db: Session, user: User) -> ContextOut:
    count = db.scalar(select(func.count()).select_from(TrackLike).where(TrackLike.user_id == user.id)) or 0
    return ContextOut(
        type="liked", id="liked", title="Lieblingssongs", subtitle=f"{count} Songs", cover_id=None,
        cover_color="#4b2bd6",
    )


def context_for(db: Session, user: User, context_type: str, context_id: int | str | None) -> ContextOut | None:
    if context_type == "liked":
        return liked_context(db, user)
    if context_type == "album" and context_id is not None:
        album = db.get(Album, int(context_id))
        if album is None:
            return None
        return ContextOut(
            type="album", id=str(album.id), title=album.title, subtitle=album.artist.name,
            cover_id=album.cover_id, cover_color=album.cover.color if album.cover else None,
        )
    if context_type == "artist" and context_id is not None:
        artist = db.get(Artist, int(context_id))
        if artist is None:
            return None
        return ContextOut(
            type="artist", id=str(artist.id), title=artist.name, subtitle="Künstler",
            cover_id=artist.cover_id, cover_color=artist.cover.color if artist.cover else None,
        )
    if context_type == "playlist" and context_id is not None:
        playlist = db.get(Playlist, int(context_id))
        if playlist is None or not can_view(user, playlist):
            return None
        mosaic = mosaic_for(db, playlist.id)
        return ContextOut(
            type="playlist", id=str(playlist.id), title=playlist.name,
            subtitle=f"Playlist · {playlist.owner.display_name}", cover_id=playlist.cover_id, mosaic=mosaic,
            cover_color=playlist.cover.color if playlist.cover else _cover_color(db, mosaic[0] if mosaic else None),
        )
    return None


def recent_contexts(db: Session, user: User, limit: int) -> list[ContextOut]:
    """Zuletzt gehörte Alben, Playlists, Künstler (jede Quelle nur einmal)."""
    rows = db.execute(
        select(PlayHistory.context_type, PlayHistory.context_id, func.max(PlayHistory.played_at).label("last"))
        .where(
            PlayHistory.user_id == user.id,
            PlayHistory.context_type.in_(["album", "playlist", "artist", "liked"]),
        )
        .group_by(PlayHistory.context_type, PlayHistory.context_id)
        .order_by(func.max(PlayHistory.played_at).desc())
        .limit(limit * 2)
    ).all()
    contexts: list[ContextOut] = []
    for context_type, context_id, _ in rows:
        context = context_for(db, user, context_type, context_id)
        if context is not None:
            contexts.append(context)
        if len(contexts) >= limit:
            break
    return contexts


# ------------------------------------------------------------------ Mixe

def _seeded(key: str, user: User) -> random.Random:
    """Mixe ändern sich täglich, sind aber über den Tag stabil (wie "Daily Mix")."""
    return random.Random(f"{date.today().isoformat()}|{user.id}|{key}")


def _mix_meta(db: Session, key: str) -> tuple[str, str] | None:
    kind, _, value = key.partition(":")
    if kind == "genre" and value:
        return f"{value}-Mix", f"{value} aus deiner Bibliothek"
    if kind == "discover":
        return "Entdecken", "Titel, die du noch nie gehört hast"
    if kind == "artist" and value.isdigit():
        artist = db.get(Artist, int(value))
        return (f"{artist.name}-Mix", f"{artist.name} und Ähnliches") if artist else None
    if kind == "category" and value.isdigit():
        category = db.get(Category, int(value))
        return (f"{category.name}-Mix", f"Zufällig aus {category.name}") if category else None
    if kind == "recent":
        return "Neu hinzugefügt", "Die neuesten Titel"
    return None


def mix_tracks(db: Session, user: User, key: str, limit: int = MIX_SIZE) -> list[Track]:
    kind, _, value = key.partition(":")
    query = select(Track).where(Track.media_type == "audio")
    if kind == "genre":
        query = query.where(Track.genre == value)
    elif kind == "discover":
        heard = select(PlayHistory.track_id).where(PlayHistory.user_id == user.id)
        query = query.where(Track.id.not_in(heard))
    elif kind == "artist" and value.isdigit():
        artist_id = int(value)
        genres = select(Track.genre).join(TrackArtist, TrackArtist.track_id == Track.id).where(
            TrackArtist.artist_id == artist_id, Track.genre.is_not(None)
        )
        query = query.where(
            Track.id.in_(select(TrackArtist.track_id).where(TrackArtist.artist_id == artist_id))
            | Track.genre.in_(genres)
        )
    elif kind == "category" and value.isdigit():
        query = query.where(Track.category_id == int(value))
    elif kind == "recent":
        return list(db.scalars(query.order_by(Track.added_at.desc()).limit(limit)).unique().all())
    candidates = list(db.scalars(query.order_by(Track.id).limit(2000)).unique().all())
    rng = _seeded(key, user)
    rng.shuffle(candidates)
    return candidates[:limit]


def get_mix(db: Session, user: User, key: str) -> MixOut:
    meta = _mix_meta(db, key)
    if meta is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Mix nicht gefunden.")
    tracks = mix_tracks(db, user, key)
    mosaic: list[str] = []
    for track in tracks:
        if track.cover_id and track.cover_id not in mosaic:
            mosaic.append(track.cover_id)
        if len(mosaic) == 4:
            break
    return MixOut(
        key=key, title=meta[0], subtitle=meta[1], cover_id=None, mosaic=mosaic,
        cover_color=_cover_color(db, mosaic[0] if mosaic else None), tracks=[track_out(t) for t in tracks],
    )


def mix_contexts(db: Session, user: User, limit: int = 6) -> list[ContextOut]:
    """Mixe für die Startseite: Lieblings-Genres des Benutzers, sonst die größten Genres der Bibliothek."""
    since = utcnow() - TOP_WINDOW * 3
    favourite_genres = db.execute(
        select(Track.genre, func.count())
        .join(PlayHistory, PlayHistory.track_id == Track.id)
        .where(PlayHistory.user_id == user.id, Track.genre.is_not(None), PlayHistory.played_at >= since)
        .group_by(Track.genre)
        .order_by(func.count().desc())
        .limit(limit)
    ).all()
    library_genres = db.execute(
        select(Track.genre, func.count())
        .where(Track.genre.is_not(None), Track.media_type == "audio")
        .group_by(Track.genre)
        .having(func.count() >= 3)
        .order_by(func.count().desc())
        .limit(limit)
    ).all()
    keys: list[str] = []
    for genre, _ in [*favourite_genres, *library_genres]:
        key = f"genre:{genre}"
        if key not in keys:
            keys.append(key)
    keys = keys[: limit - 1]
    keys.append("discover")
    contexts: list[ContextOut] = []
    for key in keys:
        tracks = mix_tracks(db, user, key, limit=12)
        if not tracks:
            continue
        meta = _mix_meta(db, key)
        if meta is None:
            continue
        mosaic: list[str] = []
        for track in tracks:
            if track.cover_id and track.cover_id not in mosaic:
                mosaic.append(track.cover_id)
            if len(mosaic) == 4:
                break
        contexts.append(
            ContextOut(
                type="mix", id=key, title=meta[0], subtitle=meta[1], cover_id=None, mosaic=mosaic,
                cover_color=_cover_color(db, mosaic[0] if mosaic else None),
            )
        )
    return contexts


def radio(db: Session, user: User, track_id: int, limit: int = MIX_SIZE) -> list[Track]:
    """Endlos-Wiedergabe nach einem Titel: gleiche Künstler, gleiches Genre, gleiches Album."""
    seed = db.get(Track, track_id)
    if seed is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Titel nicht gefunden.")
    artist_ids = [link.artist_id for link in seed.artist_links]
    condition = Track.id.in_(select(TrackArtist.track_id).where(TrackArtist.artist_id.in_(artist_ids)))
    if seed.genre:
        condition = condition | (Track.genre == seed.genre)
    if seed.album_id:
        condition = condition | (Track.album_id == seed.album_id)
    candidates = list(
        db.scalars(
            select(Track).where(condition, Track.id != seed.id, Track.media_type == seed.media_type).limit(1000)
        ).unique().all()
    )
    rng = random.Random(f"{datetime.now(UTC).isoformat(timespec='hours')}|{user.id}|radio|{track_id}")
    rng.shuffle(candidates)
    return [seed, *candidates[: limit - 1]]


# -------------------------------------------------------------- Startseite

def home(db: Session, user: User) -> HomeOut:
    recent = recent_contexts(db, user, 12)
    has_likes = db.scalar(select(TrackLike.track_id).where(TrackLike.user_id == user.id).limit(1)) is not None

    quick: list[ContextOut] = []
    if has_likes:
        quick.append(liked_context(db, user))
    quick.extend(c for c in recent if c.type != "liked")
    if len(quick) < 8:  # Neue Benutzer: mit eigenen Playlists und neuen Alben auffüllen
        seen = {(c.type, c.id) for c in quick}
        for playlist in db.scalars(
            select(Playlist).where(Playlist.owner_id == user.id).order_by(Playlist.updated_at.desc()).limit(8)
        ).unique():
            context = context_for(db, user, "playlist", playlist.id)
            if context and (context.type, context.id) not in seen:
                quick.append(context)
                seen.add((context.type, context.id))
        for album in db.scalars(select(Album).order_by(Album.created_at.desc()).limit(8)).unique():
            context = context_for(db, user, "album", album.id)
            if context and (context.type, context.id) not in seen:
                quick.append(context)
                seen.add((context.type, context.id))
    quick = quick[:8]

    sections: list[HomeSection] = []
    if recent:
        sections.append(HomeSection(key="recent", title="Zuletzt gehört", kind="contexts", contexts=recent))
    mixes = mix_contexts(db, user)
    if mixes:
        sections.append(HomeSection(key="mixes", title="Deine Mixe", kind="contexts", contexts=mixes))
    mine = top_tracks(db, user, 10)
    if mine:
        sections.append(
            HomeSection(key="top_tracks", title="Deine Top-Songs", kind="tracks", tracks=[track_out(t) for t in mine])
        )
    family = top_tracks(db, None, 10)
    if family:
        sections.append(
            HomeSection(
                key="family", title="Beliebt in der Familie", kind="tracks", tracks=[track_out(t) for t in family]
            )
        )
    downloads = db.scalars(
        select(Track).where(Track.source == "youtube").order_by(Track.added_at.desc()).limit(12)
    ).unique().all()
    if downloads:
        sections.append(
            HomeSection(
                key="downloads", title="Neu heruntergeladen", kind="tracks", tracks=[track_out(t) for t in downloads]
            )
        )
    new_albums = db.scalars(select(Album).order_by(Album.created_at.desc()).limit(12)).unique().all()
    if new_albums:
        sections.append(
            HomeSection(
                key="new_albums", title="Neu in der Bibliothek", kind="albums",
                albums=[album_out(a) for a in new_albums],
            )
        )
    artists = top_artists(db, user, 10) or list(
        db.scalars(
            select(Artist)
            .join(ArtistFollow, ArtistFollow.artist_id == Artist.id)
            .where(ArtistFollow.user_id == user.id)
            .limit(10)
        ).unique()
    )
    if artists:
        sections.append(
            HomeSection(
                key="artists", title="Deine Künstler", kind="artists", artists=[artist_out(a) for a in artists]
            )
        )
    videos = db.scalars(
        select(Track).where(Track.media_type == "video").order_by(Track.added_at.desc()).limit(12)
    ).unique().all()
    if videos:
        sections.append(
            HomeSection(key="videos", title="Neue Videos", kind="videos", tracks=[track_out(t) for t in videos])
        )
    return HomeOut(quick_access=quick, sections=sections)
