"""Rubriken (eigene Ordner auf dem Unraid) – lesen für alle, ändern nur für Admins."""

from fastapi import APIRouter, HTTPException, Response, status
from sqlalchemy import func, select

from app.deps import AdminUser, AppSettings, CurrentUser, DbSession
from app.models import Category
from app.schemas.category import CategoryCreateIn, CategoryOut, CategoryUpdateIn
from app.services.categories import (
    CategoryConflictError,
    CategoryError,
    create_category,
    delete_category,
    set_default,
    unique_slug,
)

router = APIRouter(prefix="/categories", tags=["Rubriken"])


def _get_category(db: DbSession, category_id: int) -> Category:
    category = db.get(Category, category_id)
    if category is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Rubrik nicht gefunden.")
    return category


@router.get("", response_model=list[CategoryOut])
def list_categories(_: CurrentUser, db: DbSession) -> list[CategoryOut]:
    categories = db.scalars(select(Category).order_by(Category.sort_order, Category.name))
    return [CategoryOut.model_validate(c) for c in categories]


@router.post("", response_model=CategoryOut, status_code=status.HTTP_201_CREATED)
def add_category(body: CategoryCreateIn, _: AdminUser, db: DbSession, settings: AppSettings) -> CategoryOut:
    try:
        category = create_category(
            db,
            settings.media_dir,
            name=body.name,
            media_type=body.media_type,
            folder=body.folder,
            icon=body.icon,
            sort_order=body.sort_order,
            is_default=body.is_default,
        )
    except CategoryError as exc:
        db.rollback()
        code = status.HTTP_409_CONFLICT if isinstance(exc, CategoryConflictError) else status.HTTP_400_BAD_REQUEST
        raise HTTPException(code, str(exc)) from None
    db.commit()
    return CategoryOut.model_validate(category)


@router.patch("/{category_id}", response_model=CategoryOut)
def update_category(category_id: int, body: CategoryUpdateIn, _: AdminUser, db: DbSession) -> CategoryOut:
    category = _get_category(db, category_id)
    if body.name is not None and body.name != category.name:
        clash = db.scalar(
            select(Category.id).where(func.lower(Category.name) == body.name.lower(), Category.id != category.id)
        )
        if clash is not None:
            raise HTTPException(status.HTTP_409_CONFLICT, f"Eine Rubrik mit dem Namen \"{body.name}\" gibt es schon.")
        category.name = body.name
        category.slug = unique_slug(db, body.name, exclude_id=category.id)
    if body.icon is not None:
        category.icon = body.icon
    if body.sort_order is not None:
        category.sort_order = body.sort_order
    if body.is_default:
        set_default(db, category)
    db.commit()
    return CategoryOut.model_validate(category)


@router.delete("/{category_id}", status_code=status.HTTP_204_NO_CONTENT)
def remove_category(category_id: int, _: AdminUser, db: DbSession) -> Response:
    """Entfernt nur die Rubrik aus der App. Der Ordner und alle Dateien bleiben auf dem Unraid."""
    delete_category(db, _get_category(db, category_id))
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
