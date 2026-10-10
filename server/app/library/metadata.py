"""Liest Tags, Dauer, Qualität und Cover aus Audio- und Videodateien.

Audio: mutagen (MP3, M4A/M4B, Opus, Ogg, FLAC, WAV, WMA). Videos und alles, was mutagen
nicht kennt: ffprobe. Fehlende Angaben werden aus Ordner- und Dateinamen ergänzt.
"""

import base64
import json
import logging
import re
import subprocess
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath

import mutagen
from mutagen.flac import Picture

logger = logging.getLogger(__name__)

AUDIO_EXTENSIONS = {".mp3", ".m4a", ".m4b", ".aac", ".opus", ".ogg", ".oga", ".flac", ".wav", ".wma", ".webm"}
VIDEO_EXTENSIONS = {".mp4", ".m4v", ".mkv", ".webm", ".mov"}
# Unfertige Downloads und Systemdateien nie einlesen
IGNORED_SUFFIXES = {".part", ".ytdl", ".tmp", ".temp", ".crdownload"}

_FEAT_SPLIT = re.compile(r"\s+(?:feat\.?|ft\.?|featuring)\s+", re.IGNORECASE)
_TRACK_PREFIX = re.compile(r"^(?P<num>\d{1,3})\s*(?:[-._)]\s*|\s+)(?P<rest>.+)$")


@dataclass
class MediaInfo:
    title: str | None = None
    artists: list[str] = field(default_factory=list)
    artist_display: str | None = None
    album: str | None = None
    album_artist: str | None = None
    track_number: int | None = None
    disc_number: int | None = None
    year: int | None = None
    genre: str | None = None
    duration: float = 0.0
    bitrate: int | None = None
    sample_rate: int | None = None
    codec: str | None = None
    width: int | None = None
    height: int | None = None
    cover: bytes | None = None
    # YouTube-ID (schreibt der Downloader in die Tags) – damit bleibt die Herkunft auch nach einem Neuaufbau erhalten
    source_id: str | None = None


def split_artists(values: list[str]) -> list[str]:
    """ "A feat. B" -> ["A", "B"]; mehrere Tag-Werte und ";" ebenfalls. "AC/DC" und "Simon & Garfunkel" bleiben ganz."""
    result: list[str] = []
    for value in values:
        for part in value.split(";"):
            for name in _FEAT_SPLIT.split(part):
                name = name.strip().strip("()[]").strip()
                if name and name.casefold() not in (n.casefold() for n in result):
                    result.append(name)
    return result


def _first_int(value: object) -> int | None:
    if value is None:
        return None
    match = re.search(r"\d+", str(value))
    return int(match.group()) if match else None


def _year(value: object) -> int | None:
    if value is None:
        return None
    match = re.search(r"(1[89]\d{2}|20\d{2})", str(value))
    return int(match.group()) if match else None


def _clean(value: object) -> str | None:
    if value is None:
        return None
    if isinstance(value, list):
        value = value[0] if value else None
        if value is None:
            return None
    text = str(value).replace("\x00", "").strip()
    return text[:255] or None


def _all(tags: dict[str, list[str]], *keys: str) -> list[str]:
    for key in keys:
        values = [str(v).strip() for v in tags.get(key, []) if str(v).strip()]
        if values:
            return values
    return []


# ---------------------------------------------------------------------------
# mutagen (Audio)
# ---------------------------------------------------------------------------

def _mutagen_tags(audio: mutagen.FileType) -> dict[str, list[str]]:
    """Vereinheitlicht die Tag-Namen der verschiedenen Formate."""
    tags: dict[str, list[str]] = {}
    raw = audio.tags
    if raw is None:
        return tags
    type_name = type(raw).__name__

    def add(key: str, values: object) -> None:
        if values is None:
            return
        items = values if isinstance(values, list) else [values]
        texts: list[str] = []
        for item in items:
            text = getattr(item, "text", item)
            if isinstance(text, list):
                texts.extend(str(t) for t in text)
            elif isinstance(text, tuple):  # MP4 trkn/disk: (nummer, gesamt)
                texts.append(str(text[0]))
            else:
                texts.append(str(text))
        if texts:
            tags.setdefault(key, []).extend(texts)

    if type_name == "ID3":
        mapping = {
            "TIT2": "title", "TPE1": "artist", "TPE2": "albumartist", "TALB": "album",
            "TRCK": "tracknumber", "TPOS": "discnumber", "TDRC": "date", "TYER": "date", "TCON": "genre",
        }
        for frame_id, key in mapping.items():
            for frame in raw.getall(frame_id):
                add(key, frame)
        for frame in raw.getall("TXXX"):
            if str(getattr(frame, "desc", "")).upper() == "YOUTUBE_ID":
                add("youtube_id", frame)
    elif type_name == "MP4Tags":
        mapping = {
            "\xa9nam": "title", "\xa9ART": "artist", "aART": "albumartist", "\xa9alb": "album",
            "trkn": "tracknumber", "disk": "discnumber", "\xa9day": "date", "\xa9gen": "genre",
        }
        for atom, key in mapping.items():
            add(key, raw.get(atom))
        for value in raw.get("----:com.selfify:youtube_id", []):
            add("youtube_id", bytes(value).decode("utf-8", "replace"))
    elif type_name == "ASFTags":
        mapping = {
            "Title": "title", "Author": "artist", "WM/AlbumArtist": "albumartist", "WM/AlbumTitle": "album",
            "WM/TrackNumber": "tracknumber", "WM/PartOfSet": "discnumber", "WM/Year": "date", "WM/Genre": "genre",
        }
        for atom, key in mapping.items():
            add(key, [getattr(v, "value", v) for v in raw.get(atom, [])])
    else:  # Vorbis-Kommentare (FLAC, Ogg, Opus)
        for key, value in raw.items() if hasattr(raw, "items") else []:
            add(key.lower(), value)
        if "album artist" in tags and "albumartist" not in tags:
            tags["albumartist"] = tags["album artist"]
        if "year" in tags and "date" not in tags:
            tags["date"] = tags["year"]
    return tags


def _mutagen_cover(audio: mutagen.FileType) -> bytes | None:
    raw = audio.tags
    pictures = getattr(audio, "pictures", None)  # FLAC
    if pictures:
        front = [p for p in pictures if p.type == 3] or list(pictures)
        return bytes(front[0].data)
    if raw is None:
        return None
    type_name = type(raw).__name__
    if type_name == "ID3":
        frames = raw.getall("APIC")
        front = [f for f in frames if f.type == 3] or frames
        return bytes(front[0].data) if front else None
    if type_name == "MP4Tags":
        covers = raw.get("covr")
        return bytes(covers[0]) if covers else None
    if type_name == "ASFTags":
        return None
    for encoded in raw.get("metadata_block_picture", []) if hasattr(raw, "get") else []:
        try:
            return bytes(Picture(base64.b64decode(encoded)).data)
        except Exception:  # noqa: BLE001 – kaputte Bilddaten ignorieren
            continue
    return None


def _codec_name(audio: mutagen.FileType) -> str | None:
    info = audio.info
    type_name = type(audio).__name__
    codec = getattr(info, "codec", None)
    if type_name == "MP4":
        if codec and str(codec).startswith("mp4a"):
            return "aac"
        return str(codec) if codec else "aac"
    names = {
        "MP3": "mp3", "EasyMP3": "mp3", "OggOpus": "opus", "OggVorbis": "vorbis", "FLAC": "flac",
        "OggFLAC": "flac", "WAVE": "pcm", "ASF": "wma", "AAC": "aac", "AIFF": "pcm",
    }
    return names.get(type_name, str(codec).lower() if codec else None)


def _youtube_id(value: str | None) -> str | None:
    return value if value and re.fullmatch(r"[A-Za-z0-9_-]{11}", value) else None


def read_with_mutagen(path: Path) -> MediaInfo | None:
    try:
        audio = mutagen.File(path)
    except Exception as exc:  # noqa: BLE001 – defekte Dateien sollen den Scan nicht abbrechen
        logger.debug("mutagen konnte %s nicht lesen: %s", path, exc)
        return None
    if audio is None:
        return None
    tags = _mutagen_tags(audio)
    artists = _all(tags, "artists", "artist")
    info = MediaInfo(
        title=_clean(_all(tags, "title")),
        artists=split_artists(artists),
        artist_display=", ".join(artists) if len(artists) > 1 else _clean(artists),
        album=_clean(_all(tags, "album")),
        album_artist=_clean(_all(tags, "albumartist")),
        track_number=_first_int(_clean(_all(tags, "tracknumber"))),
        disc_number=_first_int(_clean(_all(tags, "discnumber"))),
        year=_year(_clean(_all(tags, "date", "originaldate"))),
        genre=_clean(_all(tags, "genre")),
        duration=float(getattr(audio.info, "length", 0) or 0),
        sample_rate=getattr(audio.info, "sample_rate", None),
        codec=_codec_name(audio),
        cover=_mutagen_cover(audio),
        source_id=_youtube_id(_clean(_all(tags, "youtube_id"))),
    )
    bitrate = getattr(audio.info, "bitrate", None)
    if bitrate:
        info.bitrate = int(bitrate // 1000)
    elif info.duration > 0:
        info.bitrate = int(path.stat().st_size * 8 / info.duration / 1000)
    return info


# ---------------------------------------------------------------------------
# ffprobe (Videos und Formate, die mutagen nicht kennt)
# ---------------------------------------------------------------------------

def run_ffprobe(ffprobe: str, path: Path) -> dict | None:
    try:
        result = subprocess.run(
            [ffprobe, "-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", str(path)],
            capture_output=True,
            timeout=60,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        logger.debug("ffprobe nicht verfügbar oder Zeitüberschreitung bei %s: %s", path, exc)
        return None
    if result.returncode != 0:
        return None
    try:
        return json.loads(result.stdout or b"{}")
    except json.JSONDecodeError:
        return None


def read_with_ffprobe(ffprobe: str, path: Path) -> MediaInfo | None:
    data = run_ffprobe(ffprobe, path)
    if not data:
        return None
    fmt = data.get("format", {})
    streams = data.get("streams", [])
    tags = {str(k).lower(): [str(v)] for k, v in (fmt.get("tags") or {}).items()}
    for stream in streams:  # Ogg/Opus speichern Tags im Stream
        for key, value in (stream.get("tags") or {}).items():
            tags.setdefault(str(key).lower(), [str(value)])

    video = next(
        (s for s in streams if s.get("codec_type") == "video" and not (s.get("disposition") or {}).get("attached_pic")),
        None,
    )
    audio = next((s for s in streams if s.get("codec_type") == "audio"), None)
    artists = _all(tags, "artists", "artist")
    info = MediaInfo(
        title=_clean(_all(tags, "title")),
        artists=split_artists(artists),
        artist_display=_clean(artists),
        album=_clean(_all(tags, "album")),
        album_artist=_clean(_all(tags, "album_artist", "albumartist")),
        track_number=_first_int(_clean(_all(tags, "track", "tracknumber"))),
        disc_number=_first_int(_clean(_all(tags, "disc", "discnumber"))),
        year=_year(_clean(_all(tags, "date", "year"))),
        genre=_clean(_all(tags, "genre")),
        duration=float(fmt.get("duration") or 0),
    )
    if fmt.get("bit_rate"):
        info.bitrate = int(int(fmt["bit_rate"]) // 1000)
    if audio:
        info.codec = audio.get("codec_name")
        info.sample_rate = _first_int(audio.get("sample_rate"))
        if audio.get("bit_rate") and not video:
            info.bitrate = int(int(audio["bit_rate"]) // 1000)
    if video:
        info.codec = video.get("codec_name")
        info.width = video.get("width")
        info.height = video.get("height")
    return info


def extract_video_frame(ffmpeg: str, path: Path, duration: float) -> bytes | None:
    """Standbild bei 10 % der Laufzeit als Vorschaubild."""
    position = max(0.0, min(duration * 0.1, 30.0)) if duration else 1.0
    try:
        result = subprocess.run(
            [ffmpeg, "-nostdin", "-v", "error", "-ss", f"{position:.2f}", "-i", str(path),
             "-frames:v", "1", "-f", "image2", "-c:v", "mjpeg", "pipe:1"],
            capture_output=True,
            timeout=60,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    return result.stdout if result.returncode == 0 and result.stdout else None


# ---------------------------------------------------------------------------
# Ergänzungen aus Ordner- und Dateinamen
# ---------------------------------------------------------------------------

def apply_path_fallbacks(info: MediaInfo, relative_in_category: PurePosixPath, media_type: str) -> MediaInfo:
    """Ergänzt fehlende Angaben, z. B. "Künstler/Album/01 - Titel.mp3" oder "Künstler - Titel.mp4"."""
    stem = relative_in_category.stem.strip()
    folders = list(relative_in_category.parent.parts)

    if not info.title:
        title = stem
        match = _TRACK_PREFIX.match(title)
        if match and media_type == "audio":
            info.track_number = info.track_number or int(match.group("num"))
            title = match.group("rest").strip()
        if not info.artists and " - " in title:
            artist_part, title_part = title.split(" - ", 1)
            info.artists = split_artists([artist_part])
            info.artist_display = artist_part.strip()
            title = title_part
        info.title = title.strip() or stem

    if not info.artists and folders:
        info.artists = [folders[0]]
        info.artist_display = folders[0]
    if not info.album and media_type == "audio" and len(folders) >= 2:
        info.album = folders[-1]

    if not info.artist_display and info.artists:
        info.artist_display = ", ".join(info.artists)
    return info


def read_media_info(path: Path, media_type: str, ffprobe: str) -> MediaInfo | None:
    """Liest alle verfügbaren Angaben. None = Datei ist nicht abspielbar/lesbar."""
    info: MediaInfo | None = None
    if media_type == "audio" and path.suffix.lower() != ".webm":
        info = read_with_mutagen(path)
    if info is None or info.duration <= 0:
        probed = read_with_ffprobe(ffprobe, path)
        if probed is not None:
            if info is not None:  # Tags von mutagen behalten, technische Daten von ffprobe
                probed.cover = info.cover
                probed.source_id = info.source_id
            info = probed
            if media_type == "video" and path.suffix.lower() in {".mp4", ".m4v", ".mov"}:
                tagged = read_with_mutagen(path)
                if tagged is not None:
                    info.cover = info.cover or tagged.cover
                    info.source_id = tagged.source_id
                    # Eigene Tags (vom Downloader) haben Vorrang vor den ffprobe-Angaben
                    if tagged.artists:
                        info.artists, info.artist_display = tagged.artists, tagged.artist_display
                    info.title = tagged.title or info.title
    return info
