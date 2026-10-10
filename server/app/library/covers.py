"""Cover speichern (DATA_DIR/covers), verkleinerte Fassungen erzeugen und die Hauptfarbe bestimmen."""

import colorsys
import hashlib
import io
import logging
import os
import threading
from pathlib import Path

from PIL import Image, ImageOps, UnidentifiedImageError
from sqlalchemy.orm import Session

from app.models import Cover

logger = logging.getLogger(__name__)

COVER_SIZES = (64, 128, 300, 600)
MAX_ORIGINAL = 1200
FOLDER_IMAGE_NAMES = ("cover", "folder", "front", "album", "albumart", "thumb")
IMAGE_EXTENSIONS = (".jpg", ".jpeg", ".png", ".webp")

Image.MAX_IMAGE_PIXELS = 50_000_000  # Schutz vor absichtlich riesigen Bildern


def dominant_color(image: Image.Image) -> str:
    """Kräftigste häufige Farbe – ähnlich wie Spotify den Hintergrund einfärbt."""
    small = image.convert("RGB").resize((64, 64))
    quantized = small.quantize(colors=6, method=Image.Quantize.MEDIANCUT)
    palette = quantized.getpalette() or []
    counts = sorted(quantized.getcolors() or [], reverse=True)
    best: tuple[float, tuple[int, int, int]] | None = None
    for count, index in counts:
        r, g, b = palette[index * 3 : index * 3 + 3]
        _, lightness, saturation = colorsys.rgb_to_hls(r / 255, g / 255, b / 255)
        # Fast schwarze/weiße/graue Töne abwerten
        score = count * (0.25 + saturation) * (1.0 if 0.12 < lightness < 0.88 else 0.2)
        if best is None or score > best[0]:
            best = (score, (r, g, b))
    r, g, b = best[1] if best else (64, 64, 64)
    return f"#{r:02x}{g:02x}{b:02x}"


class CoverStore:
    def __init__(self, root: Path) -> None:
        self.root = root
        self._lock = threading.Lock()

    def _file(self, cover_id: str, size: int | None = None) -> Path:
        name = f"{cover_id}.jpg" if not size else f"{cover_id}_{size}.jpg"
        return self.root / cover_id[:2] / name

    def add(self, db: Session, data: bytes) -> str | None:
        """Speichert ein Bild (falls neu) und liefert seine ID. None = kein gültiges Bild."""
        if not data:
            return None
        cover_id = hashlib.sha1(data, usedforsecurity=False).hexdigest()
        if db.get(Cover, cover_id) is not None and self._file(cover_id).exists():
            return cover_id
        try:
            with Image.open(io.BytesIO(data)) as raw:
                image = ImageOps.exif_transpose(raw).convert("RGB")
        except (UnidentifiedImageError, OSError, ValueError, Image.DecompressionBombError) as exc:
            logger.debug("Ungültiges Coverbild ignoriert: %s", exc)
            return None
        image.thumbnail((MAX_ORIGINAL, MAX_ORIGINAL))
        target = self._file(cover_id)
        target.parent.mkdir(parents=True, exist_ok=True)
        tmp = target.with_suffix(".tmp")
        image.save(tmp, "JPEG", quality=90, optimize=True)
        os.replace(tmp, target)

        cover = db.get(Cover, cover_id)
        if cover is None:
            db.add(Cover(id=cover_id, width=image.width, height=image.height, color=dominant_color(image)))
            db.flush()
        return cover_id

    def add_file(self, db: Session, path: Path) -> str | None:
        try:
            return self.add(db, path.read_bytes())
        except OSError:
            return None

    def path_for(self, cover_id: str, size: int | None) -> Path | None:
        """Pfad zur gewünschten Größe – kleinere Fassungen werden beim ersten Abruf erzeugt."""
        original = self._file(cover_id)
        if not original.exists():
            return None
        if not size:
            return original
        target = self._file(cover_id, size)
        if target.exists():
            return target
        with self._lock:
            if not target.exists():
                with Image.open(original) as image:
                    resized = ImageOps.fit(image.convert("RGB"), (size, size)) if size <= 128 else image.copy()
                    resized.thumbnail((size, size))
                    tmp = target.with_suffix(".tmp")
                    resized.save(tmp, "JPEG", quality=85, optimize=True)
                    os.replace(tmp, target)
        return target

    def delete(self, cover_id: str) -> None:
        for size in (None, *COVER_SIZES):
            self._file(cover_id, size).unlink(missing_ok=True)


def find_folder_image(directory: Path, cache: dict[Path, Path | None]) -> Path | None:
    """Sucht cover.jpg, folder.jpg … im Ordner (Groß-/Kleinschreibung egal)."""
    if directory in cache:
        return cache[directory]
    found: Path | None = None
    try:
        candidates = {p.name.lower(): p for p in directory.iterdir() if p.is_file()}
    except OSError:
        candidates = {}
    for name in FOLDER_IMAGE_NAMES:
        for ext in IMAGE_EXTENSIONS:
            if f"{name}{ext}" in candidates:
                found = candidates[f"{name}{ext}"]
                break
        if found:
            break
    cache[directory] = found
    return found


def find_sidecar_image(media_file: Path) -> Path | None:
    """Vorschaubild mit gleichem Namen, z. B. "Video.mp4" + "Video.jpg" (so speichert es yt-dlp)."""
    for ext in IMAGE_EXTENSIONS:
        for candidate in (media_file.with_suffix(ext), media_file.with_suffix(ext.upper())):
            if candidate.is_file():
                return candidate
    return None
