"""Umwandeln für Geräte/Datensparmodus mit Zwischenspeicher (DATA_DIR/transcode).

iPhones können Opus/Ogg/WebM nicht abspielen. Solche Dateien werden einmalig in AAC (M4A)
umgewandelt und danach aus dem Zwischenspeicher geliefert – inklusive Spulen.
"""

import hashlib
import logging
import os
import shutil
import subprocess
import threading
from pathlib import Path

logger = logging.getLogger(__name__)

# Qualitätsstufen für AAC in kbit/s
QUALITY_BITRATES = {"high": 256, "normal": 160, "low": 96}
# Diese Codecs spielen Android UND iOS ohne Umwandlung ab
UNIVERSAL_CODECS = {"aac", "mp3", "alac", "flac", "pcm", "pcm_s16le", "pcm_s24le"}
UNIVERSAL_EXTENSIONS = {".mp3", ".m4a", ".m4b", ".aac", ".flac", ".wav"}
# Spielt die Android-App (ExoPlayer) zusätzlich ohne Umwandlung ab – WMA dagegen nicht
ANDROID_CODECS = UNIVERSAL_CODECS | {"opus", "vorbis"}
ANDROID_EXTENSIONS = UNIVERSAL_EXTENSIONS | {".opus", ".ogg", ".oga", ".webm"}


class TranscodeUnavailableError(RuntimeError):
    """ffmpeg fehlt oder die Umwandlung ist fehlgeschlagen."""


def needs_transcode(
    codec: str | None, extension: str, bitrate: int | None, quality: str, compatible: bool
) -> int | None:
    """Gibt die Ziel-Bitrate zurück, falls umgewandelt werden muss – sonst None (Original ausliefern).

    compatible=true: nur Formate, die auch iPhones abspielen; sonst alles, was die Android-App abspielt.
    """
    codec, extension = (codec or "").lower(), extension.lower()
    if compatible:
        playable = codec in UNIVERSAL_CODECS and extension in UNIVERSAL_EXTENSIONS
    else:
        playable = codec in ANDROID_CODECS and extension in ANDROID_EXTENSIONS
    if quality == "original" or quality not in QUALITY_BITRATES:
        return None if playable else QUALITY_BITRATES["high"]
    target = QUALITY_BITRATES[quality]
    if bitrate and bitrate <= target * 1.15 and playable:
        return None
    return target


class TranscodeCache:
    def __init__(self, root: Path, max_bytes: int, ffmpeg: str) -> None:
        self.root = root
        self.max_bytes = max_bytes
        self.ffmpeg = ffmpeg
        self._locks: dict[str, threading.Lock] = {}
        self._guard = threading.Lock()
        self._cleanup_lock = threading.Lock()

    @property
    def available(self) -> bool:
        return shutil.which(self.ffmpeg) is not None

    def _lock_for(self, key: str) -> threading.Lock:
        with self._guard:
            return self._locks.setdefault(key, threading.Lock())

    def get(self, source: Path, source_version: str, bitrate: int) -> Path:
        """Liefert die umgewandelte Datei; wandelt beim ersten Abruf um (eine 4-Minuten-Datei dauert ~1–2 s)."""
        key = hashlib.sha1(f"{source}|{source_version}|aac{bitrate}".encode(), usedforsecurity=False).hexdigest()
        target = self.root / key[:2] / f"{key}.m4a"
        with self._lock_for(key):
            if target.exists():
                os.utime(target)  # zuletzt benutzt -> wird beim Aufräumen zuletzt gelöscht
                return target
            if not self.available:
                raise TranscodeUnavailableError("ffmpeg ist nicht installiert – Umwandlung nicht möglich.")
            target.parent.mkdir(parents=True, exist_ok=True)
            tmp = target.with_suffix(".part")
            command = [
                self.ffmpeg, "-nostdin", "-v", "error", "-y", "-i", str(source),
                "-map", "0:a:0", "-vn", "-c:a", "aac", "-b:a", f"{bitrate}k",
                "-movflags", "+faststart", "-f", "mp4", str(tmp),
            ]
            try:
                result = subprocess.run(command, capture_output=True, timeout=1800, check=False)
            except (OSError, subprocess.TimeoutExpired) as exc:
                tmp.unlink(missing_ok=True)
                raise TranscodeUnavailableError(f"Umwandlung fehlgeschlagen: {exc}") from exc
            if result.returncode != 0 or not tmp.exists():
                tmp.unlink(missing_ok=True)
                message = result.stderr.decode("utf-8", "replace").strip()[-300:]
                raise TranscodeUnavailableError(f"Umwandlung fehlgeschlagen: {message}")
            os.replace(tmp, target)
        self.cleanup(keep=target)
        return target

    def cleanup(self, keep: Path | None = None) -> None:
        """Hält den Zwischenspeicher unter TRANSCODE_CACHE_MB (älteste Dateien zuerst weg)."""
        if not self.root.exists():
            return
        with self._cleanup_lock:  # zwei Aufräumer gleichzeitig würden sich die Dateien wegnehmen
            files: list[tuple[float, int, Path]] = []
            for path in self.root.rglob("*.m4a"):
                try:
                    info = path.stat()
                except FileNotFoundError:
                    continue
                files.append((info.st_mtime, info.st_size, path))
            total = sum(size for _, size, _ in files)
            for _, size, path in sorted(files):
                if total <= self.max_bytes:
                    break
                if path == keep:
                    continue
                path.unlink(missing_ok=True)
                total -= size
