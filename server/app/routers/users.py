"""Benutzerverwaltung – nur für Admins (z. B. Konten für die Kinder anlegen)."""

from fastapi import APIRouter, HTTPException, Response, status
from sqlalchemy import func, select

from app.deps import AdminUser, DbSession
from app.models import User
from app.schemas.user import UserCreateIn, UserOut, UserUpdateIn
from app.security import hash_password
from app.services.auth import revoke_all_sessions

router = APIRouter(prefix="/users", tags=["Benutzerverwaltung"])


def _get_user(db: DbSession, user_id: int) -> User:
    user = db.get(User, user_id)
    if user is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Benutzer nicht gefunden.")
    return user


def _other_active_admins(db: DbSession, user_id: int) -> int:
    return db.scalar(
        select(func.count(User.id)).where(User.is_admin.is_(True), User.is_active.is_(True), User.id != user_id)
    ) or 0


@router.get("", response_model=list[UserOut])
def list_users(_: AdminUser, db: DbSession) -> list[UserOut]:
    return [UserOut.model_validate(u) for u in db.scalars(select(User).order_by(User.username))]


@router.post("", response_model=UserOut, status_code=status.HTTP_201_CREATED)
def create_user(body: UserCreateIn, _: AdminUser, db: DbSession) -> UserOut:
    if db.scalar(select(User.id).where(User.username == body.username)) is not None:
        raise HTTPException(status.HTTP_409_CONFLICT, f"Der Benutzername \"{body.username}\" ist schon vergeben.")
    user = User(
        username=body.username,
        display_name=body.display_name or body.username.capitalize(),
        password_hash=hash_password(body.password),
        is_admin=body.is_admin,
        can_download=body.can_download,
    )
    db.add(user)
    db.commit()
    return UserOut.model_validate(user)


@router.get("/{user_id}", response_model=UserOut)
def get_user(user_id: int, _: AdminUser, db: DbSession) -> UserOut:
    return UserOut.model_validate(_get_user(db, user_id))


@router.patch("/{user_id}", response_model=UserOut)
def update_user(user_id: int, body: UserUpdateIn, admin: AdminUser, db: DbSession) -> UserOut:
    user = _get_user(db, user_id)
    losing_admin = (body.is_admin is False and user.is_admin) or (body.is_active is False and user.is_admin)
    if losing_admin and _other_active_admins(db, user.id) == 0:
        raise HTTPException(status.HTTP_409_CONFLICT, "Es muss mindestens ein aktiver Admin bleiben.")
    if user.id == admin.id and body.is_active is False:
        raise HTTPException(status.HTTP_409_CONFLICT, "Du kannst dich nicht selbst deaktivieren.")

    if body.display_name is not None:
        user.display_name = body.display_name
    if body.is_admin is not None:
        user.is_admin = body.is_admin
    if body.can_download is not None:
        user.can_download = body.can_download
    if body.is_active is not None:
        user.is_active = body.is_active
        if not body.is_active:
            revoke_all_sessions(db, user.id)
    if body.password is not None:
        # Passwort zurückgesetzt -> alle Geräte dieses Benutzers abmelden
        user.password_hash = hash_password(body.password)
        revoke_all_sessions(db, user.id)
    db.commit()
    return UserOut.model_validate(user)


@router.delete("/{user_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_user(user_id: int, admin: AdminUser, db: DbSession) -> Response:
    user = _get_user(db, user_id)
    if user.id == admin.id:
        raise HTTPException(status.HTTP_409_CONFLICT, "Du kannst dich nicht selbst löschen.")
    if user.is_admin and _other_active_admins(db, user.id) == 0:
        raise HTTPException(status.HTTP_409_CONFLICT, "Es muss mindestens ein aktiver Admin bleiben.")
    db.delete(user)
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
