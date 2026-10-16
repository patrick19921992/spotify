"""Nach dem Download: Tags + Cover schreiben, Songtexte speichern, Dateinamen und Zielordner bilden."""

import base64
import glob
import io
import json
import logging
import re
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

from mutagen.flac import Picture
from mutagen.id3 import APIC, ID3, TALB, TDRC, TIT2, TPE1, TPE2, TRCK, TXXX, ID3NoHeaderError
from mutagen.mp4 import MP4, MP4Cover, MP4FreeForm
from mutagen.oggopus import OggOpus
from mutagen.oggvorbis import OggVorbis
from PIL import Image, ImageOps, UnidentifiedImageError

from app import __version__
from app.downloads.youtube import LyricsResult, is_allowed_thumbnail
from app.library.lyrics import parse_lrc

logger = logging.getLogger(__name__)

USER_AGENT = f"Selfify/{__version__} (privater Musikserver)"
_UNSAFE = re.compile(r'[\\/:*?"<>|\x00-\x1f]')
YOUTUBE_ID_TAG = "YOUTUBE_ID"
MP4_YOUTUBE_ID = "----:com.selfify:youtube_id"


@dataclass
class TrackMeta:
    title: str
    artists: list[str] = field(default_factory=list)
    album: str | None = None
    album_artist: str | None = None
    track_number: int | None = None
    year: int | None = None
    video_id: str | None = None


# ------------------------------------------------------------------ Dateinamen

def safe_name(value: str, fallback: str = "Unbekannt", limit: int = 120, max_bytes: int = 180) -> str:
    """Erlaubte Datei-/Ordnernamen für Unraid/SMB (keine / \\ : * ? " < > |, keine Punkte am Ende).

    Linux erlaubt höchstens 255 Byte je Name – japanische Titel oder Emojis brauchen 3–4 Byte pro Zeichen.
    Gekürzt wird deshalb auch nach Bytes (mit Platz für "01 - ", " (2)" und die Endung).
    """
    cleaned = (value or "").encode("utf-8", "ignore").decode("utf-8")  # ungültige Zeichen (Surrogates) weg
    cleaned = _UNSAFE.sub("", cleaned).strip()
    cleaned = re.sub(r"\s+", " ", cleaned).strip(" .")[:limit]
    while len(cleaned.encode("utf-8")) > max_bytes:
        cleaned = cleaned[:-1]
    return cleaned.rstrip(" .") or fallback


def target_path(media_dir: Path, folder: str, media_type: str, meta: TrackMeta, extension: str) -> Path:
    """Musik/Künstler/Album/01 - Titel.opus  bzw.  Musikvideos/Künstler/Titel.mp4"""
    artist = safe_name(meta.album_artist or (meta.artists[0] if meta.artists else ""), "Unbekannter Künstler")
    title = safe_name(meta.title, meta.video_id or "Titel")
    base = media_dir / folder / artist
    if media_type == "audio" and meta.album:
        base = base / safe_name(meta.album, "Singles")
        if meta.track_number:
            title = f"{meta.track_number:02d} - {title}"
    return base / f"{title}{extension}"


def _stem_taken(path: Path) -> bool:
    """Gibt es im Ordner schon eine Datei mit diesem Namen – egal welche Endung (Song, .lrc, .jpg)?"""
    return path.exists() or any(path.parent.glob(glob.escape(path.stem) + ".*"))


def unique_path(path: Path) -> Path:
    """Freier Dateiname. Belegt ist ein Name auch durch eine gleichnamige Datei mit anderer Endung –
    sonst würde ein neuer Download z. B. die Songtext-Datei (.lrc) einer vorhandenen FLAC überschreiben."""
    if not _stem_taken(path):
        return path
    for counter in range(2, 1000):
        candidate = path.with_name(f"{path.stem} ({counter}){path.suffix}")
        if not _stem_taken(candidate):
            return candidate
    raise FileExistsError(str(path))


# ------------------------------------------------------------------- Bilder

def fetch_image(url: str | None, timeout: int = 20) -> bytes | None:
    """Lädt ein Coverbild – nur von YouTube-/Google-Servern."""
    if not is_allowed_thumbnail(url):
        return None
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})  # type: ignore[arg-type]
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:  # noqa: S310 – Host geprüft
            return response.read(15 * 1024 * 1024)
    except Exception as exc:  # noqa: BLE001
        logger.info("Cover konnte nicht geladen werden (%s): %s", url, exc)
        return None


def _trim_letterbox(image: Image.Image) -> Image.Image:
    """Schwarze Balken oben/unten entfernen (4:3-Vorschaubild eines 16:9-Videos). Höchstens so viel, wie ein
    16:9-Bild an Balken hätte – dunkler Bildinhalt echter 16:9-Bilder bleibt."""
    gray = image.convert("L")
    width, height = gray.size
    limit = max(0, (height - round(width * 9 / 16)) // 2)

    def dark(row: int) -> bool:
        return gray.crop((0, row, width, row + 1)).getextrema()[1] < 24  # type: ignore[index, operator]

    top, bottom = 0, height
    while top < limit and dark(top):
        top += 1
    while bottom > height - limit and dark(bottom - 1):
        bottom -= 1
    return image.crop((0, top, width, bottom)) if top or bottom < height else image


def _square_image(data: bytes | None, crop: bool, max_size: int) -> Image.Image | None:
    if not data:
        return None
    try:
        with Image.open(io.BytesIO(data)) as raw:
            image = ImageOps.exif_transpose(raw).convert("RGB")
    except (UnidentifiedImageError, OSError, ValueError):
        return None
    if crop and abs(image.width - image.height) > min(image.width, image.height) * 0.05:
        image = _trim_letterbox(image)  # nur bei Vorschaubildern – quadratische Album-Cover bleiben unberührt
        side = min(image.width, image.height)
        image = ImageOps.fit(image, (side, side))
    image.thumbnail((max_size, max_size))
    return image


def _jpeg(image: Image.Image) -> bytes:
    buffer = io.BytesIO()
    image.save(buffer, "JPEG", quality=92)
    return buffer.getvalue()


def square_jpeg(data: bytes | None, crop: bool = True, max_size: int = 1200) -> bytes | None:
    """Cover als JPEG; Video-Vorschaubilder (16:9) werden mittig quadratisch zugeschnitten."""
    image = _square_image(data, crop, max_size)
    return None if image is None else _jpeg(image)


def best_square_jpeg(candidates: list[bytes | None], max_size: int = 1200) -> bytes | None:
    """Das schärfste Cover aus mehreren Quellen – z. B. kleines Vorschaubild aus der Suche (400×225) gegen das
    große, das yt-dlp mitlädt (1280×720)."""
    images = [image for data in candidates if (image := _square_image(data, True, max_size)) is not None]
    return _jpeg(max(images, key=lambda image: image.width)) if images else None


# --------------------------------------------------------------------- Tags

def write_tags(path: Path, meta: TrackMeta, cover: bytes | None) -> None:
    """Schreibt Titel, Künstler, Album, Nummer, Jahr, YouTube-ID und Cover in die Datei."""
    suffix = path.suffix.lower()
    if suffix in (".opus", ".ogg", ".oga"):
        _tag_vorbis(path, meta, cover)
    elif suffix in (".m4a", ".mp4", ".m4v", ".m4b"):
        _tag_mp4(path, meta, cover)
    elif suffix == ".mp3":
        _tag_mp3(path, meta, cover)
    else:
        logger.info("Tags für %s werden nicht unterstützt – Angaben kommen aus dem Dateinamen.", suffix)


def _tag_vorbis(path: Path, meta: TrackMeta, cover: bytes | None) -> None:
    try:
        audio = OggOpus(path)
    except Exception:  # noqa: BLE001 – kein Opus -> Vorbis versuchen
        audio = OggVorbis(path)
    tags = audio.tags
    tags["title"] = meta.title
    if meta.artists:
        tags["artist"] = meta.artists
    if meta.album:
        tags["album"] = meta.album
    if meta.album_artist:
        tags["albumartist"] = meta.album_artist
    if meta.track_number:
        tags["tracknumber"] = str(meta.track_number)
    if meta.year:
        tags["date"] = str(meta.year)
    if meta.video_id:
        tags[YOUTUBE_ID_TAG] = meta.video_id
    if cover:
        picture = Picture()
        picture.type = 3
        picture.mime = "image/jpeg"
        picture.desc = "Cover"
        with Image.open(io.BytesIO(cover)) as image:
            picture.width, picture.height = image.size
        picture.depth = 24
        picture.data = cover
        tags["metadata_block_picture"] = [base64.b64encode(picture.write()).decode("ascii")]
    audio.save()


def _tag_mp4(path: Path, meta: TrackMeta, cover: bytes | None) -> None:
    audio = MP4(path)
    if audio.tags is None:
        audio.add_tags()
    tags = audio.tags
    tags["\xa9nam"] = [meta.title]
    if meta.artists:
        tags["\xa9ART"] = meta.artists
    if meta.album:
        tags["\xa9alb"] = [meta.album]
    if meta.album_artist:
        tags["aART"] = [meta.album_artist]
    if meta.track_number:
        tags["trkn"] = [(meta.track_number, 0)]
    if meta.year:
        tags["\xa9day"] = [str(meta.year)]
    if meta.video_id:
        tags[MP4_YOUTUBE_ID] = [MP4FreeForm(meta.video_id.encode("utf-8"))]
    if cover:
        tags["covr"] = [MP4Cover(cover, imageformat=MP4Cover.FORMAT_JPEG)]
    audio.save()


def _tag_mp3(path: Path, meta: TrackMeta, cover: bytes | None) -> None:
    try:
        tags = ID3(path)
    except ID3NoHeaderError:
        tags = ID3()
    tags.add(TIT2(encoding=3, text=meta.title))
    if meta.artists:
        tags.add(TPE1(encoding=3, text=meta.artists))
    if meta.album:
        tags.add(TALB(encoding=3, text=meta.album))
    if meta.album_artist:
        tags.add(TPE2(encoding=3, text=meta.album_artist))
    if meta.track_number:
        tags.add(TRCK(encoding=3, text=str(meta.track_number)))
    if meta.year:
        tags.add(TDRC(encoding=3, text=str(meta.year)))
    if meta.video_id:
        tags.add(TXXX(encoding=3, desc=YOUTUBE_ID_TAG, text=meta.video_id))
    if cover:
        tags.add(APIC(encoding=3, mime="image/jpeg", type=3, desc="Cover", data=cover))
    tags.save(path)


# --------------------------------------------------------------- Songtexte

def fetch_lrclib(meta: TrackMeta, duration: float | None, timeout: int = 10) -> LyricsResult | None:
    """Freie Songtext-Datenbank LRCLIB (oft mit Zeitstempeln) als Ersatz, wenn YouTube Music keine hat."""
    if not meta.title or not meta.artists:
        return None
    params = {"artist_name": meta.artists[0], "track_name": meta.title}
    if meta.album:
        params["album_name"] = meta.album
    if duration:
        params["duration"] = str(round(duration))
    url = "https://lrclib.net/api/get?" + urllib.parse.urlencode(params)
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:  # noqa: S310 – feste Adresse
            data = json.loads(response.read(2 * 1024 * 1024))
    except Exception as exc:  # noqa: BLE001
        logger.debug("LRCLIB ohne Ergebnis für %s: %s", meta.title, exc)
        return None
    synced = data.get("syncedLyrics")
    if synced:
        lines = parse_lrc(synced)
        if lines:
            return LyricsResult(synced=True, lines=lines, source="LRCLIB")
    plain = data.get("plainLyrics")
    if plain:
        return LyricsResult(synced=False, lines=[(None, line) for line in plain.splitlines()], source="LRCLIB")
    return None


def write_lrc(media_file: Path, lyrics: LyricsResult) -> Path:
    target = media_file.with_suffix(".lrc")
    target.write_text(lyrics.to_lrc(), encoding="utf-8")
    return target
