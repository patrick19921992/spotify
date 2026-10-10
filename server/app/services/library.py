"""Abfragen auf die Bibliothek: Listen, Detailseiten und Suche."""

from collections.abc import Sequence
from typing import Literal

from sqlalchemy import Select, and_, func, select
from sqlalchemy.orm import Session

from app.library.text import match_key, search_terms
from app.models import Album, Artist, Track, TrackArtist
from app.schemas.library import (
    AlbumDetailOut,
    AlbumOut,
    AlbumRef,
    ArtistDetailOut,
    ArtistOut,
    ArtistRef,
    Page,
    SearchOut,
    TopResult,
    TrackOut,
)

TrackSort = Literal["title", "recent", "artist", "album", "duration"]
AlbumSort = Literal["title", "recent", "year", "artist"]
ArtistSort = Literal["name", "recent", "tracks"]


# ----------------------------------------------------------------- Umwandeln

def track_out(track: Track) -> TrackOut:
    return TrackOut(
        id=track.id,
        title=track.title,
        artist_display=track.artist_display,
        artists=[ArtistRef(id=link.artist.id, name=link.artist.name) for link in track.artist_links],
        album=AlbumRef(id=track.album.id, title=track.album.title) if track.album else None,
        category_id=track.category_id,
        media_type=track.media_type,  # type: ignore[arg-type]
        duration=track.duration,
        track_number=track.track_number,
        disc_number=track.disc_number,
        year=track.year,
        genre=track.genre,
        codec=track.codec,
        bitrate=track.bitrate,
        width=track.width,
        height=track.height,
        file_size=track.file_size,
        cover_id=track.cover_id,
        cover_color=track.cover.color if track.cover else None,
        source=track.source,
        added_at=track.added_at,
    )


def album_out(album: Album) -> AlbumOut:
    return AlbumOut(
        id=album.id,
        title=album.title,
        artist=ArtistRef(id=album.artist.id, name=album.artist.name),
        year=album.year,
        genre=album.genre,
        track_count=album.track_count,
        duration=album.duration,
        cover_id=album.cover_id,
        cover_color=album.cover.color if album.cover else None,
        added_at=album.created_at,
    )


def artist_out(artist: Artist) -> ArtistOut:
    return ArtistOut(
        id=artist.id,
        name=artist.name,
        track_count=artist.track_count,
        album_count=artist.album_count,
        cover_id=artist.cover_id,
        cover_color=artist.cover.color if artist.cover else None,
    )


def _page(db: Session, query: Select, limit: int, offset: int, convert) -> Page:  # type: ignore[no-untyped-def,type-arg]
    total = db.scalar(select(func.count()).select_from(query.order_by(None).subquery())) or 0
    items = db.scalars(query.limit(limit).offset(offset)).unique().all()
    return Page(items=[convert(item) for item in items], total=total, limit=limit, offset=offset)


def _text_filter(column, query: str | None):  # type: ignore[no-untyped-def]
    terms = search_terms(query or "")
    return and_(*(column.like(f"%{term}%") for term in terms)) if terms else None


# --------------------------------------------------------------------- Listen

def list_tracks(
    db: Session,
    *,
    limit: int,
    offset: int,
    sort: TrackSort = "title",
    category_id: int | None = None,
    media_type: str | None = None,
    artist_id: int | None = None,
    album_id: int | None = None,
    q: str | None = None,
) -> Page[TrackOut]:
    query = select(Track)
    if category_id is not None:
        query = query.where(Track.category_id == category_id)
    if media_type is not None:
        query = query.where(Track.media_type == media_type)
    if album_id is not None:
        query = query.where(Track.album_id == album_id)
    if artist_id is not None:
        query = query.where(Track.id.in_(select(TrackArtist.track_id).where(TrackArtist.artist_id == artist_id)))
    text_filter = _text_filter(Track.search_text, q)
    if text_filter is not None:
        query = query.where(text_filter)
    order = {
        "title": (Track.sort_title, Track.id),
        "recent": (Track.added_at.desc(), Track.id.desc()),
        "artist": (func.lower(Track.artist_display), Track.sort_title),
        "album": (Track.album_id, Track.disc_number, Track.track_number, Track.sort_title),
        "duration": (Track.duration.desc(), Track.id),
    }[sort]
    return _page(db, query.order_by(*order), limit, offset, track_out)


def list_albums(
    db: Session,
    *,
    limit: int,
    offset: int,
    sort: AlbumSort = "title",
    category_id: int | None = None,
    artist_id: int | None = None,
    q: str | None = None,
) -> Page[AlbumOut]:
    query = select(Album).join(Album.artist)
    if artist_id is not None:
        query = query.where(Album.artist_id == artist_id)
    if category_id is not None:
        query = query.where(Album.id.in_(select(Track.album_id).where(Track.category_id == category_id)))
    text_filter = _text_filter(Album.search_text, q)
    if text_filter is not None:
        query = query.where(text_filter)
    order = {
        "title": (Album.sort_title, Album.id),
        "recent": (Album.created_at.desc(), Album.id.desc()),
        "year": (Album.year.desc().nulls_last(), Album.sort_title),
        "artist": (Artist.sort_name, Album.year, Album.sort_title),
    }[sort]
    return _page(db, query.order_by(*order), limit, offset, album_out)


def list_artists(
    db: Session,
    *,
    limit: int,
    offset: int,
    sort: ArtistSort = "name",
    category_id: int | None = None,
    q: str | None = None,
) -> Page[ArtistOut]:
    query = select(Artist).where(Artist.track_count > 0)
    if category_id is not None:
        query = query.where(
            Artist.id.in_(
                select(TrackArtist.artist_id).join(Track, Track.id == TrackArtist.track_id)
                .where(Track.category_id == category_id)
            )
        )
    text_filter = _text_filter(Artist.search_text, q)
    if text_filter is not None:
        query = query.where(text_filter)
    order = {
        "name": (Artist.sort_name, Artist.id),
        "recent": (Artist.created_at.desc(), Artist.id.desc()),
        "tracks": (Artist.track_count.desc(), Artist.sort_name),
    }[sort]
    return _page(db, query.order_by(*order), limit, offset, artist_out)


# ------------------------------------------------------------- Detailseiten

def album_detail(db: Session, album: Album) -> AlbumDetailOut:
    tracks = db.scalars(
        select(Track)
        .where(Track.album_id == album.id)
        .order_by(func.coalesce(Track.disc_number, 1), func.coalesce(Track.track_number, 9999), Track.sort_title)
    ).unique().all()
    return AlbumDetailOut(**album_out(album).model_dump(), tracks=[track_out(t) for t in tracks])


def artist_detail(db: Session, artist: Artist, top_limit: int = 10) -> ArtistDetailOut:
    own_tracks = select(TrackArtist.track_id).where(TrackArtist.artist_id == artist.id)
    top_tracks = db.scalars(
        select(Track)
        .where(Track.id.in_(own_tracks), Track.media_type == "audio")
        .order_by(Track.year.desc().nulls_last(), Track.added_at.desc())
        .limit(top_limit)
    ).unique().all()
    albums = db.scalars(
        select(Album).where(Album.artist_id == artist.id).order_by(Album.year.desc().nulls_last(), Album.sort_title)
    ).unique().all()
    appears_on = db.scalars(
        select(Album)
        .where(Album.artist_id != artist.id, Album.id.in_(select(Track.album_id).where(Track.id.in_(own_tracks))))
        .order_by(Album.year.desc().nulls_last(), Album.sort_title)
    ).unique().all()
    videos = db.scalars(
        select(Track)
        .where(Track.id.in_(own_tracks), Track.media_type == "video")
        .order_by(Track.added_at.desc())
    ).unique().all()
    return ArtistDetailOut(
        **artist_out(artist).model_dump(),
        top_tracks=[track_out(t) for t in top_tracks],
        albums=[album_out(a) for a in albums],
        appears_on=[album_out(a) for a in appears_on],
        videos=[track_out(t) for t in videos],
    )


# ----------------------------------------------------------------------- Suche

def _score(primary: str, query_key: str, popularity: int = 0) -> float:
    """Wie gut passt der Name zur Suche? Genauer Treffer > Anfang > Wortanfang > irgendwo."""
    key = match_key(primary)
    if key == query_key:
        base = 100.0
    elif key.startswith(query_key):
        base = 60.0
    elif f" {query_key}" in f" {key}":
        base = 40.0
    elif query_key in key:
        base = 25.0
    else:
        base = 10.0  # Treffer nur über Künstler/Album
    return base + min(popularity, 50) / 10


def _ranked(items: Sequence, primary, query_key: str, popularity=lambda _: 0) -> list:  # type: ignore[no-untyped-def,type-arg]
    return sorted(items, key=lambda item: -_score(primary(item), query_key, popularity(item)))


def search(db: Session, query: str, limit: int = 10, category_id: int | None = None) -> SearchOut:
    terms = search_terms(query)
    if not terms:
        return SearchOut(query=query, top_result=None, tracks=[], artists=[], albums=[], videos=[])
    query_key = " ".join(terms)
    pool = limit * 4

    def track_query(media_type: str) -> list[Track]:
        q = select(Track).where(_text_filter(Track.search_text, query), Track.media_type == media_type)
        if category_id is not None:
            q = q.where(Track.category_id == category_id)
        return list(db.scalars(q.order_by(Track.sort_title).limit(pool)).unique().all())

    tracks = _ranked(track_query("audio"), lambda t: t.title, query_key)[:limit]
    videos = _ranked(track_query("video"), lambda t: t.title, query_key)[:limit]

    artist_query = select(Artist).where(_text_filter(Artist.search_text, query), Artist.track_count > 0)
    album_query = select(Album).where(_text_filter(Album.search_text, query))
    if category_id is not None:
        in_category = select(Track.id).where(Track.category_id == category_id)
        artist_query = artist_query.where(
            Artist.id.in_(select(TrackArtist.artist_id).where(TrackArtist.track_id.in_(in_category)))
        )
        album_query = album_query.where(Album.id.in_(select(Track.album_id).where(Track.category_id == category_id)))
    artists = _ranked(
        list(db.scalars(artist_query.order_by(Artist.sort_name).limit(pool)).unique().all()),
        lambda a: a.name,
        query_key,
        lambda a: a.track_count,
    )[:limit]
    albums = _ranked(
        list(db.scalars(album_query.order_by(Album.sort_title).limit(pool)).unique().all()),
        lambda a: a.title,
        query_key,
    )[:limit]

    candidates: list[tuple[float, TopResult]] = []
    if artists:
        candidates.append(
            (_score(artists[0].name, query_key, artists[0].track_count) + 5,
             TopResult(type="artist", artist=artist_out(artists[0])))
        )
    if albums:
        candidates.append((_score(albums[0].title, query_key) + 2, TopResult(type="album", album=album_out(albums[0]))))
    if tracks:
        candidates.append((_score(tracks[0].title, query_key), TopResult(type="track", track=track_out(tracks[0]))))
    if videos:
        candidates.append((_score(videos[0].title, query_key) - 1, TopResult(type="video", track=track_out(videos[0]))))
    top = max(candidates, key=lambda c: c[0])[1] if candidates else None

    return SearchOut(
        query=query,
        top_result=top,
        tracks=[track_out(t) for t in tracks],
        artists=[artist_out(a) for a in artists],
        albums=[album_out(a) for a in albums],
        videos=[track_out(t) for t in videos],
    )


def library_counts(db: Session) -> dict[str, float | int]:
    row = db.execute(
        select(
            func.count(Track.id).filter(Track.media_type == "audio"),
            func.count(Track.id).filter(Track.media_type == "video"),
            func.coalesce(func.sum(Track.duration), 0),
            func.coalesce(func.sum(Track.file_size), 0),
        )
    ).one()
    return {
        "tracks": row[0],
        "videos": row[1],
        "total_duration": float(row[2]),
        "total_size": int(row[3]),
        "artists": db.scalar(select(func.count(Artist.id)).where(Artist.track_count > 0)) or 0,
        "albums": db.scalar(select(func.count(Album.id))) or 0,
    }


def category_counts(db: Session) -> dict[int, int]:
    return dict(db.execute(select(Track.category_id, func.count(Track.id)).group_by(Track.category_id)).all())

