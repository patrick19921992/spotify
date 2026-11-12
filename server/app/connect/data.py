"""Datenbankzugriffe der Geräte-Steuerung. Alles hier ist synchron und läuft im Threadpool, jeweils mit einer
kurzen eigenen Sitzung – über die Dauer einer Verbindung wird keine Datenbank-Sitzung gehalten."""

from collections.abc import Callable, Iterable
from dataclasses import dataclass
from datetime import datetime
from typing import Any

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.deps import auth_from_payload
from app.models import Track, User
from app.services import app_config
from app.services import features as feature_set
from app.services.clients import ClientInfo
from app.services.library import track_out
from app.services.visibility import filter_tracks, visibility_for

SessionFactory = Callable[[], Session]


@dataclass(frozen=True)
class Login:
    user_id: int
    session_id: int
    device_name: str
    allowed: bool
    user_created: datetime | None = None


def remote_allowed(db: Session, user: User) -> bool:
    """Darf dieses Konto auf anderen Geräten abspielen (Premium-Schalter „remote“)?"""
    return feature_set.access_for(db, user, app_config.get_all(db)).allows("remote")


def check_login(factory: SessionFactory, payload: dict[str, Any], client: ClientInfo | None = None) -> Login | None:
    """Gilt die Anmeldung (Konto aktiv, Gerät nicht abgemeldet)? None = nein."""
    with factory() as db:
        try:
            auth = auth_from_payload(db, payload, client)
        except HTTPException:
            return None
        return Login(
            user_id=auth.user.id,
            session_id=auth.session.id,
            device_name=auth.session.device_name,
            allowed=remote_allowed(db, auth.user),
            user_created=auth.user.created_at,
        )


def visible_tracks(factory: SessionFactory, user_id: int, ids: Iterable[int]) -> dict[int, dict[str, Any]]:
    """Sichtbare Titel (frisch aus der Datenbank, Sichtbarkeit des Kontos) als TrackOut-JSON je ID."""
    wanted = sorted(set(ids))
    if not wanted:
        return {}
    with factory() as db:
        user = db.get(User, user_id)
        if user is None:
            return {}
        v = visibility_for(db, user)
        tracks = db.scalars(filter_tracks(select(Track).where(Track.id.in_(wanted)), v))
        return {track.id: track_out(track).model_dump(mode="json") for track in tracks}
