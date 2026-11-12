"""Benutzerverwaltung – nur für Admins (z. B. Konten für die Kinder anlegen)."""

from fastapi import APIRouter, HTTPException, Request, Response, status
from sqlalchemy import select

from app.connect.hub import hub_of
from app.deps import AdminUser, DbSession
from app.locks import write_lock
from app.models import Category, User
from app.schemas.user import UserCreateIn, UserOut, UserUpdateIn
from app.security import hash_password
from app.services.auth import other_active_admins as _other_active_admins
from app.services.auth import revoke_all_sessions

router = APIRouter(prefix="/users", tags=["Benutzerverwaltung"])


def _get_user(db: DbSession, user_id: int) -> User:
    user = db.get(User, user_id)
    if user is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Benutzer nicht gefunden.")
    return user


def _categories(db: DbSession, category_ids: list[int]) -> list[Category]:
    """Rubriken zu den IDs – eine unbekannte ID ergibt 404."""
    wanted = set(category_ids)
    categories = list(db.scalars(select(Category).where(Category.id.in_(wanted)))) if wanted else []
    if len(categories) != len(wanted):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Rubrik nicht gefunden.")
    return categories


@router.get("", response_model=list[UserOut])
def list_users(_: AdminUser, db: DbSession) -> list[UserOut]:
    return [UserOut.model_validate(u) for u in db.scalars(select(User).order_by(User.username))]


@router.post("", response_model=UserOut, status_code=status.HTTP_201_CREATED)
def create_user(body: UserCreateIn, _: AdminUser, db: DbSession) -> UserOut:
    if db.scalar(select(User.id).where(User.username == body.username)) is not None:
        raise HTTPException(status.HTTP_409_CONFLICT, f"Der Benutzername \"{body.username}\" ist schon vergeben.")
    categories = _categories(db, body.category_ids)
    user = User(
        username=body.username,
        display_name=body.display_name or body.username.capitalize(),
        password_hash=hash_password(body.password),
        is_admin=body.is_admin,
        can_download=body.can_download,
        all_categories=body.all_categories,
        categories=categories,
    )
    db.add(user)
    db.commit()
    return UserOut.model_validate(user)


@router.get("/{user_id}", response_model=UserOut)
def get_user(user_id: int, _: AdminUser, db: DbSession) -> UserOut:
    return UserOut.model_validate(_get_user(db, user_id))


@router.patch("/{user_id}", response_model=UserOut)
def update_user(user_id: int, body: UserUpdateIn, request: Request, admin: AdminUser, db: DbSession) -> UserOut:
    # Prüfung „bleibt ein Admin übrig?“ und Änderung am Stück – zwei Admins, die sich gleichzeitig herabstufen, würden
    # sonst beide durchgehen und niemanden übrig lassen
    with write_lock:
        user = _get_user(db, user_id)
        losing_admin = (body.is_admin is False and user.is_admin) or (body.is_active is False and user.is_admin)
        if losing_admin and _other_active_admins(db, user.id) == 0:
            raise HTTPException(status.HTTP_409_CONFLICT, "Es muss mindestens ein aktiver Admin bleiben.")
        if user.id == admin.id and body.is_active is False:
            raise HTTPException(status.HTTP_409_CONFLICT, "Du kannst dich nicht selbst deaktivieren.")
        categories = _categories(db, body.category_ids) if body.category_ids is not None else None

        if body.display_name is not None:
            user.display_name = body.display_name
        if body.is_admin is not None:
            user.is_admin = body.is_admin
        if body.can_download is not None:
            user.can_download = body.can_download
        if categories is not None:
            user.categories = categories
        if body.all_categories is not None:
            # Die gespeicherte Auswahl bleibt erhalten, auch wenn das Konto wieder alles sieht
            user.all_categories = body.all_categories
        if body.is_active is not None:
            user.is_active = body.is_active
            if body.is_active:
                # Freischalten: Ein wartendes Konto ist damit freigegeben
                user.approval_pending = False
            else:
                revoke_all_sessions(db, user.id)
        if body.password is not None:
            # Passwort zurückgesetzt -> alle Geräte dieses Benutzers abmelden
            user.password_hash = hash_password(body.password)
            revoke_all_sessions(db, user.id)
        db.commit()
    hub = hub_of(request.app)
    if hub is not None:
        if body.is_active is False or body.password is not None:
            # Konto deaktiviert oder Passwort zurückgesetzt: alle Geräte-Verbindungen sofort trennen
            hub.drop_user(user.id)
        elif body.is_admin is not None or body.all_categories is not None or body.category_ids is not None:
            # Sichtbarkeit geändert: Titelangaben der anderen Geräte neu laden (verborgene Rubriken fallen weg)
            hub.refresh_visibility(user.id)
    return UserOut.model_validate(user)


@router.delete("/{user_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_user(user_id: int, request: Request, admin: AdminUser, db: DbSession) -> Response:
    with write_lock:
        user = _get_user(db, user_id)
        if user.id == admin.id:
            raise HTTPException(status.HTTP_409_CONFLICT, "Du kannst dich nicht selbst löschen.")
        if user.is_admin and _other_active_admins(db, user.id) == 0:
            raise HTTPException(status.HTTP_409_CONFLICT, "Es muss mindestens ein aktiver Admin bleiben.")
        db.delete(user)
        db.commit()
    if hub := hub_of(request.app):
        hub.forget_user(user_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
