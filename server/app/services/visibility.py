"""Sichtbarkeit je Rubrik: Was darf ein Konto von der Bibliothek sehen?

Eingeschränkt ist nur ein Konto ohne Admin-Rechte mit all_categories = false (z. B. selbst registriert). Es sieht nur
Titel aus seinen freigegebenen Rubriken, dazu Alben und Künstler mit mindestens einem solchen Titel.

Alle anderen Konten (Admins, Bestandskonten, vom Admin angelegte Konten) sind uneingeschränkt. Für sie hängen die
Funktionen hier nichts an die Abfragen an (Kurzschluss) – SQL und Antworten bleiben genau wie bisher.

Die Sichtbarkeit wird bei jeder Anfrage neu bestimmt: Freigaben und Entzüge wirken sofort, auch für laufende Token.
"""

from collections.abc import Iterable
from dataclasses import dataclass

from fastapi import HTTPException, status
from sqlalchemy import ColumnElement, Select, false, func, or_, select
from sqlalchemy.orm import Session

from app.models import Album, Artist, Playlist, Track, TrackArtist, User, user_categories

MSG_TRACK_NOT_FOUND = "Titel nicht gefunden."
MSG_ALBUM_NOT_FOUND = "Album nicht gefunden."
MSG_ARTIST_NOT_FOUND = "Künstler nicht gefunden."


@dataclass(frozen=True)
class Visibility:
    # None = alles sichtbar (Admin oder all_categories). Sonst die freigegebenen Rubriken (auch leer)
    category_ids: frozenset[int] | None

    @property
    def restricted(self) -> bool:
        return self.category_ids is not None

    def allows_category(self, category_id: int | None) -> bool:
        return self.category_ids is None or category_id in self.category_ids


UNRESTRICTED = Visibility(None)


def visibility_for(db: Session, user: User) -> Visibility:
    if user.is_admin or user.all_categories:
        return UNRESTRICTED
    ids = db.scalars(select(user_categories.c.category_id).where(user_categories.c.user_id == user.id))
    return Visibility(frozenset(ids))


# ------------------------------------------------------------------ Klauseln

def track_clause(v: Visibility) -> ColumnElement[bool] | None:
    """Bedingung „Titel sichtbar“ – None = nichts anhängen. Eine leere Menge ergibt „nichts sichtbar“."""
    if v.category_ids is None:
        return None
    if not v.category_ids:
        return false()
    return Track.category_id.in_(sorted(v.category_ids))


def album_clause(v: Visibility) -> ColumnElement[bool] | None:
    """Album mit mindestens einem sichtbaren Titel."""
    clause = track_clause(v)
    if clause is None:
        return None
    return Album.id.in_(select(Track.album_id).where(clause, Track.album_id.is_not(None)))


def artist_clause(v: Visibility) -> ColumnElement[bool] | None:
    """Künstler mit mindestens einem sichtbaren Titel (über TrackArtist)."""
    clause = track_clause(v)
    if clause is None:
        return None
    return Artist.id.in_(select(TrackArtist.artist_id).join(Track, Track.id == TrackArtist.track_id).where(clause))


def _filter[S: Select](stmt: S, clause: ColumnElement[bool] | None) -> S:
    return stmt if clause is None else stmt.where(clause)


def filter_tracks[S: Select](stmt: S, v: Visibility) -> S:
    return _filter(stmt, track_clause(v))


def filter_albums[S: Select](stmt: S, v: Visibility) -> S:
    return _filter(stmt, album_clause(v))


def filter_artists[S: Select](stmt: S, v: Visibility) -> S:
    return _filter(stmt, artist_clause(v))


# ------------------------------------------------------------- Einzelabruf

def track_visible(db: Session, v: Visibility, track_id: int) -> bool:
    if not v.restricted:
        return db.get(Track, track_id) is not None
    track = db.get(Track, track_id)
    return track is not None and v.allows_category(track.category_id)


def album_visible(db: Session, v: Visibility, album_id: int) -> bool:
    clause = track_clause(v)
    if clause is None:
        return db.get(Album, album_id) is not None
    return db.scalar(select(Track.id).where(Track.album_id == album_id, clause).limit(1)) is not None


def artist_visible(db: Session, v: Visibility, artist_id: int) -> bool:
    clause = track_clause(v)
    if clause is None:
        return db.get(Artist, artist_id) is not None
    return (
        db.scalar(
            select(TrackArtist.track_id)
            .join(Track, Track.id == TrackArtist.track_id)
            .where(TrackArtist.artist_id == artist_id, clause)
            .limit(1)
        )
        is not None
    )


def _not_found(detail: str) -> HTTPException:
    return HTTPException(status.HTTP_404_NOT_FOUND, detail)


def get_track_or_404(db: Session, v: Visibility, track_id: int, detail: str = MSG_TRACK_NOT_FOUND) -> Track:
    """Unsichtbar und nicht vorhanden ergeben dieselbe Antwort."""
    track = db.get(Track, track_id)
    if track is None or not v.allows_category(track.category_id):
        raise _not_found(detail)
    return track


def get_album_or_404(db: Session, v: Visibility, album_id: int, detail: str = MSG_ALBUM_NOT_FOUND) -> Album:
    album = db.get(Album, album_id)
    if album is None or (v.restricted and not album_visible(db, v, album_id)):
        raise _not_found(detail)
    return album


def get_artist_or_404(db: Session, v: Visibility, artist_id: int, detail: str = MSG_ARTIST_NOT_FOUND) -> Artist:
    artist = db.get(Artist, artist_id)
    if artist is None or (v.restricted and not artist_visible(db, v, artist_id)):
        raise _not_found(detail)
    return artist


def cover_visible(db: Session, v: Visibility, cover_id: str, user: User | None = None) -> bool:
    """Eingeschränkt sichtbar, wenn ein sichtbarer Titel, ein sichtbares Album, ein sichtbarer Künstler oder eine
    Playlist, die der Benutzer sehen darf, dieses Cover hat.

    Läuft bei jedem Cover-Abruf: deshalb Prüfungen nacheinander (die häufigste zuerst, Abbruch beim ersten Treffer),
    über die Indizes auf cover_id und mit direktem Join statt einer Liste aller sichtbaren Alben bzw. Künstler."""
    clause = track_clause(v)
    if clause is None:
        return True
    checks = [
        select(Track.id).where(Track.cover_id == cover_id, clause),
        select(Album.id).join(Track, Track.album_id == Album.id).where(Album.cover_id == cover_id, clause),
        select(Artist.id)
        .join(TrackArtist, TrackArtist.artist_id == Artist.id)
        .join(Track, Track.id == TrackArtist.track_id)
        .where(Artist.cover_id == cover_id, clause),
    ]
    if user is not None:
        checks.append(
            select(Playlist.id).where(
                Playlist.cover_id == cover_id, or_(Playlist.owner_id == user.id, Playlist.is_public.is_(True))
            )
        )
    return any(db.scalar(check.limit(1)) is not None for check in checks)


# ------------------------------------------------------- Zähler je Betrachter

def album_counts(db: Session, v: Visibility, album_ids: Iterable[int]) -> dict[int, tuple[int, float]]:
    """track_count und duration je Album, nur über sichtbare Titel (nur für eingeschränkte Konten gedacht)."""
    ids = sorted(set(album_ids))
    if not ids:
        return {}
    query = filter_tracks(
        select(Track.album_id, func.count(Track.id), func.coalesce(func.sum(Track.duration), 0))
        .where(Track.album_id.in_(ids))
        .group_by(Track.album_id),
        v,
    )
    return {album_id: (int(count), float(duration)) for album_id, count, duration in db.execute(query).all()}


def artist_counts(db: Session, v: Visibility, artist_ids: Iterable[int]) -> dict[int, tuple[int, int]]:
    """track_count und album_count je Künstler, nur über sichtbare Titel bzw. Alben."""
    ids = sorted(set(artist_ids))
    if not ids:
        return {}
    tracks = dict(
        db.execute(
            filter_tracks(
                select(TrackArtist.artist_id, func.count(TrackArtist.track_id))
                .join(Track, Track.id == TrackArtist.track_id)
                .where(TrackArtist.artist_id.in_(ids))
                .group_by(TrackArtist.artist_id),
                v,
            )
        ).all()
    )
    albums = dict(
        db.execute(
            filter_albums(
                select(Album.artist_id, func.count(Album.id)).where(Album.artist_id.in_(ids)).group_by(Album.artist_id),
                v,
            )
        ).all()
    )
    return {i: (int(tracks.get(i, 0)), int(albums.get(i, 0))) for i in ids}
