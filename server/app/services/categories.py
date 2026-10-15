"""Rubriken anlegen und ihre Ordner auf dem Unraid erzeugen."""

import logging
import re
import unicodedata
from pathlib import Path, PurePosixPath

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.models import Category

logger = logging.getLogger(__name__)

# Werden beim allerersten Start angelegt – danach frei änderbar
DEFAULT_CATEGORIES: list[dict[str, object]] = [
    {"name": "Musik", "folder": "Musik", "media_type": "audio", "icon": "music_note", "is_default": True},
    {"name": "Musikvideos", "folder": "Musikvideos", "media_type": "video", "icon": "music_video", "is_default": True},
    {"name": "Hörspiele & Hörbücher", "folder": "Hoerspiele", "media_type": "audio", "icon": "auto_stories"},
    {"name": "Videos", "folder": "Videos", "media_type": "video", "icon": "movie"},
]

_UMLAUTS = str.maketrans({"ä": "ae", "ö": "oe", "ü": "ue", "Ä": "Ae", "Ö": "Oe", "Ü": "Ue", "ß": "ss"})


class CategoryError(ValueError):
    """Ungültige Eingabe für eine Rubrik (HTTP 400)."""


class CategoryConflictError(CategoryError):
    """Name oder Ordner ist schon vergeben (HTTP 409)."""


def _ascii(value: str) -> str:
    value = value.translate(_UMLAUTS)
    return unicodedata.normalize("NFKD", value).encode("ascii", "ignore").decode("ascii")


def make_slug(name: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", _ascii(name).lower()).strip("-")
    return slug[:64] or "rubrik"


def folder_from_name(name: str) -> str:
    folder = re.sub(r"[^A-Za-z0-9 _-]+", "", _ascii(name).replace("&", "und"))
    folder = re.sub(r"\s+", " ", folder).strip(" .")
    return folder[:100] or "Rubrik"


def validate_folder(folder: str, media_dir: Path) -> str:
    """Erlaubt nur relative Unterordner von MEDIA_DIR – kein "..", keine absoluten Pfade."""
    folder = folder.strip().replace("\\", "/")
    if folder.startswith("/"):
        raise CategoryError("Bitte den Ordner relativ zum Medienordner angeben, z. B. \"Hoerspiele\".")
    folder = folder.rstrip("/")
    if not folder:
        raise CategoryError("Ordnername darf nicht leer sein.")
    parts = PurePosixPath(folder).parts
    if any(part in ("", ".", "..") or part.startswith(".") for part in parts):
        raise CategoryError("Ungültiger Ordnername.")
    if any(ord(char) < 32 or char in ':*?"<>|' for char in folder):
        raise CategoryError("Der Ordnername enthält unerlaubte Zeichen.")
    target = (media_dir / folder).resolve()
    if not target.is_relative_to(media_dir.resolve()):
        raise CategoryError("Der Ordner muss innerhalb des Medienordners liegen.")
    return "/".join(parts)


def ensure_folder(media_dir: Path, folder: str) -> bool:
    try:
        (media_dir / folder).mkdir(parents=True, exist_ok=True)
        return True
    except OSError as exc:
        logger.error("Ordner %s konnte nicht angelegt werden: %s", media_dir / folder, exc)
        return False


def set_default(db: Session, category: Category) -> None:
    """Macht die Rubrik zum Standard-Downloadziel ihres Medientyps."""
    for other in db.scalars(select(Category).where(Category.media_type == category.media_type)):
        other.is_default = other.id == category.id
    category.is_default = True


def unique_slug(db: Session, name: str, exclude_id: int | None = None) -> str:
    base = make_slug(name)
    slug, counter = base, 2
    while True:
        query = select(Category.id).where(Category.slug == slug)
        if exclude_id is not None:
            query = query.where(Category.id != exclude_id)
        if db.scalar(query) is None:
            return slug
        slug = f"{base[:60]}-{counter}"
        counter += 1


def next_sort_order(db: Session) -> int:
    return (db.scalar(select(func.max(Category.sort_order))) or 0) + 10


def create_category(
    db: Session,
    media_dir: Path,
    *,
    name: str,
    media_type: str,
    folder: str | None = None,
    icon: str | None = None,
    sort_order: int | None = None,
    is_default: bool = False,
) -> Category:
    if db.scalar(select(Category.id).where(func.lower(Category.name) == name.lower())) is not None:
        raise CategoryConflictError(f"Eine Rubrik mit dem Namen \"{name}\" gibt es schon.")
    folder = validate_folder(folder or folder_from_name(name), media_dir)
    if db.scalar(select(Category.id).where(func.lower(Category.folder) == folder.lower())) is not None:
        raise CategoryConflictError(f"Der Ordner \"{folder}\" gehört schon zu einer anderen Rubrik.")

    category = Category(
        name=name,
        slug=unique_slug(db, name),
        folder=folder,
        media_type=media_type,
        icon=icon or ("music_note" if media_type == "audio" else "movie"),
        sort_order=sort_order if sort_order is not None else next_sort_order(db),
        is_default=False,
    )
    db.add(category)
    db.flush()
    has_default = db.scalar(
        select(Category.id).where(Category.media_type == media_type, Category.is_default.is_(True))
    )
    if is_default or has_default is None:
        set_default(db, category)
    ensure_folder(media_dir, folder)
    return category


def delete_category(db: Session, category: Category) -> None:
    """Entfernt nur den Eintrag – die Dateien im Ordner bleiben auf dem Unraid erhalten."""
    was_default, media_type = category.is_default, category.media_type
    db.delete(category)
    db.flush()
    if was_default:
        replacement = db.scalar(
            select(Category).where(Category.media_type == media_type).order_by(Category.sort_order, Category.id)
        )
        if replacement is not None:
            set_default(db, replacement)


def seed_default_categories(db: Session, media_dir: Path) -> None:
    if db.scalar(select(func.count(Category.id))):
        return
    for index, entry in enumerate(DEFAULT_CATEGORIES):
        create_category(
            db,
            media_dir,
            name=str(entry["name"]),
            media_type=str(entry["media_type"]),
            folder=str(entry["folder"]),
            icon=str(entry["icon"]),
            sort_order=(index + 1) * 10,
            is_default=bool(entry.get("is_default", False)),
        )
    logger.info("Standard-Rubriken angelegt: %s", ", ".join(str(e["name"]) for e in DEFAULT_CATEGORIES))


def ensure_all_folders(db: Session, media_dir: Path) -> None:
    for category in db.scalars(select(Category)):
        ensure_folder(media_dir, category.folder)
