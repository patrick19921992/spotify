"""Erzeugt kleine, echte Mediendateien mit Tags und Covern für die Tests (braucht ffmpeg)."""

import base64
import io
import shutil
import subprocess
from pathlib import Path

from mutagen.flac import FLAC, Picture
from mutagen.id3 import APIC, ID3, TALB, TCON, TDRC, TIT2, TPE1, TPE2, TRCK
from mutagen.mp4 import MP4, MP4Cover
from mutagen.oggopus import OggOpus
from PIL import Image

FFMPEG = shutil.which("ffmpeg")


def cover_bytes(color: tuple[int, int, int], size: int = 400, fmt: str = "JPEG") -> bytes:
    image = Image.new("RGB", (size, size), color)
    for x in range(size // 4):  # etwas Struktur, damit es kein reines Einfarbbild ist
        image.putpixel((x, x), (255, 255, 255))
    buffer = io.BytesIO()
    image.save(buffer, fmt)
    return buffer.getvalue()


def _ffmpeg(*args: str) -> None:
    assert FFMPEG, "ffmpeg fehlt"
    subprocess.run([FFMPEG, "-nostdin", "-v", "error", "-y", *args], check=True)


def make_audio(path: Path, codec: str, seconds: float = 2.0, bitrate: str = "128k", freq: int = 440) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    codec_args = {
        "mp3": ["-c:a", "libmp3lame", "-b:a", bitrate],
        "aac": ["-c:a", "aac", "-b:a", bitrate],
        "opus": ["-c:a", "libopus", "-b:a", bitrate],
        "flac": ["-c:a", "flac"],
    }[codec]
    _ffmpeg("-f", "lavfi", "-i", f"sine=frequency={freq}:duration={seconds}", *codec_args, str(path))
    return path


def make_video(path: Path, seconds: float = 2.0) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    _ffmpeg(
        "-f", "lavfi", "-i", f"testsrc=duration={seconds}:size=320x180:rate=15",
        "-f", "lavfi", "-i", f"sine=frequency=660:duration={seconds}",
        "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", str(path),
    )
    return path


def tag_mp3(path: Path, *, title: str, artist: str, album: str | None = None, album_artist: str | None = None,
            track: str | None = None, year: str | None = None, genre: str | None = None,
            cover: bytes | None = None) -> None:
    tags = ID3()
    tags.add(TIT2(encoding=3, text=title))
    tags.add(TPE1(encoding=3, text=artist))
    if album:
        tags.add(TALB(encoding=3, text=album))
    if album_artist:
        tags.add(TPE2(encoding=3, text=album_artist))
    if track:
        tags.add(TRCK(encoding=3, text=track))
    if year:
        tags.add(TDRC(encoding=3, text=year))
    if genre:
        tags.add(TCON(encoding=3, text=genre))
    if cover:
        tags.add(APIC(encoding=3, mime="image/jpeg", type=3, desc="Cover", data=cover))
    tags.save(path)


def tag_m4a(path: Path, *, title: str, artist: str, album: str, track: int, year: str, cover: bytes) -> None:
    audio = MP4(path)
    audio["\xa9nam"] = title
    audio["\xa9ART"] = artist
    audio["\xa9alb"] = album
    audio["trkn"] = [(track, 12)]
    audio["\xa9day"] = year
    audio["covr"] = [MP4Cover(cover, imageformat=MP4Cover.FORMAT_JPEG)]
    audio.save()


def tag_opus(path: Path, *, title: str, artist: str, album: str, cover: bytes) -> None:
    audio = OggOpus(path)
    audio["title"] = title
    audio["artist"] = artist
    audio["album"] = album
    picture = Picture()
    picture.type = 3
    picture.mime = "image/jpeg"
    picture.data = cover
    audio["metadata_block_picture"] = [base64.b64encode(picture.write()).decode("ascii")]
    audio.save()


def tag_flac(path: Path, **tags: str) -> None:
    audio = FLAC(path)
    for key, value in tags.items():
        audio[key] = value
    audio.save()


def build_library(root: Path) -> dict[str, str]:
    """Baut eine kleine Beispiel-Bibliothek. Gibt die wichtigsten relativen Pfade zurück."""
    queen_cover = cover_bytes((180, 30, 40))
    daft_cover = cover_bytes((20, 60, 200))
    paths: dict[str, str] = {}

    opera = root / "Musik" / "Queen" / "A Night at the Opera"
    mp3 = make_audio(opera / "01 - Bohemian Rhapsody.mp3", "mp3", bitrate="320k")
    tag_mp3(mp3, title="Bohemian Rhapsody", artist="Queen", album="A Night at the Opera", track="11/12",
            year="1975-10-31", genre="Rock", cover=queen_cover)
    m4a = make_audio(opera / "02 - Love of My Life.m4a", "aac", freq=330)
    tag_m4a(m4a, title="Love of My Life", artist="Queen", album="A Night at the Opera", track=9, year="1975",
            cover=queen_cover)
    paths["mp3"] = mp3.relative_to(root).as_posix()
    paths["m4a"] = m4a.relative_to(root).as_posix()

    opus = make_audio(root / "Musik" / "Get Lucky.opus", "opus", freq=550)
    tag_opus(opus, title="Get Lucky", artist="Daft Punk feat. Pharrell Williams", album="Random Access Memories",
             cover=daft_cover)
    paths["opus"] = opus.relative_to(root).as_posix()

    # Ohne Tags: Angaben kommen aus Ordnern/Dateinamen, Cover aus cover.jpg im Ordner
    untagged_dir = root / "Musik" / "Die Ärzte" / "Die Bestie in Menschengestalt"
    flac = make_audio(untagged_dir / "03 Schrei nach Liebe.flac", "flac", freq=220)
    (untagged_dir / "cover.jpg").write_bytes(cover_bytes((240, 200, 20)))
    paths["flac"] = flac.relative_to(root).as_posix()

    hoerspiel = make_audio(root / "Hoerspiele" / "Die drei Fragezeichen" / "Folge 1" / "01 Kapitel 1.mp3", "mp3")
    tag_mp3(hoerspiel, title="Kapitel 1", artist="Die drei ???", album="Folge 1: und der Super-Papagei", track="1",
            genre="Hörspiel")
    paths["hoerspiel"] = hoerspiel.relative_to(root).as_posix()

    video = make_video(root / "Musikvideos" / "Queen - Bohemian Rhapsody (Official Video).mp4")
    (video.with_suffix(".jpg")).write_bytes(cover_bytes((90, 90, 90), size=320))
    paths["video"] = video.relative_to(root).as_posix()

    # Müll, der ignoriert werden muss
    (root / "Musik" / "Unfertig.mp3.part").write_bytes(b"halb fertig")
    (root / "Musik" / ".versteckt.mp3").write_bytes(b"versteckt")
    (root / "Musik" / "kaputt.mp3").write_bytes(b"das ist kein mp3")
    return paths
