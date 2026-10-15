"""yt-dlp als eigener Prozess: Befehl bauen, Fortschritt auslesen, Links auflösen, aktualisieren.

Warum ein eigener Prozess? Abbrechen geht sauber (Prozess beenden), Aktualisierungen von yt-dlp
wirken sofort ohne Server-Neustart, und ein Absturz von yt-dlp reißt den Server nicht mit.
"""

import functools
import importlib.metadata
import json
import logging
import os
import re
import shlex
import subprocess
import sys
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path

from app.config import Settings

logger = logging.getLogger(__name__)

DL_PREFIX = "SELFIFY-DL "
PP_PREFIX = "SELFIFY-PP "
PLAN_PREFIX = "SELFIFY-PLAN "
FILE_PREFIX = "SELFIFY-FILE "
INFO_PREFIX = "SELFIFY-INFO "
ENTRY_PREFIX = "SELFIFY-ENTRY "

# Nach so vielen Sekunden ohne jede Ausgabe gilt ein Download als hängengeblieben
STALL_TIMEOUT = 600


class DownloadCancelledError(RuntimeError):
    pass


class DownloadFailedError(RuntimeError):
    pass


def base_command(settings: Settings) -> list[str]:
    if settings.ytdlp_command:
        return shlex.split(settings.ytdlp_command)
    return [sys.executable, "-m", "yt_dlp"]


def _version_key(version: str | None) -> tuple[int, ...]:
    """'2026.08.19' und '2026.8.19' (pip schreibt Versionen ohne führende Nullen) vergleichbar machen."""
    return tuple(int(part) for part in re.findall(r"\d+", version or ""))


@functools.cache
def bundled_version() -> str | None:
    """yt-dlp-Version, die im Docker-Image installiert ist."""
    try:
        return importlib.metadata.version("yt-dlp")
    except importlib.metadata.PackageNotFoundError:
        return None


def updated_version(update_dir: Path) -> str | None:
    """Version der selbst aktualisierten Kopie in DATA_DIR/ytdlp (oder None)."""
    try:
        text = (update_dir / "yt_dlp" / "version.py").read_text(encoding="utf-8")
    except OSError:
        return None
    match = re.search(r"__version__\s*=\s*['\"]([^'\"]+)", text)
    return match.group(1) if match else None


def ytdlp_env(settings: Settings) -> dict[str, str]:
    """Die selbst aktualisierte yt-dlp-Kopie (DATA_DIR/ytdlp) hat nur Vorrang, solange sie neuer ist als die im
    Image – nach einem Container-Update mit neuerem yt-dlp gilt wieder die eingebaute Version."""
    env = dict(os.environ)
    update_dir = settings.ytdlp_update_dir
    updated = updated_version(update_dir)
    if updated and _version_key(updated) > _version_key(bundled_version()):
        env["PYTHONPATH"] = os.pathsep.join(filter(None, [str(update_dir), env.get("PYTHONPATH", "")]))
    env.setdefault("HOME", "/tmp")
    return env


def source_url(video_id: str, media_type: str) -> str:
    # music.youtube.com liefert yt-dlp zusätzlich Titel/Künstler/Album-Angaben
    if media_type == "audio":
        return f"https://music.youtube.com/watch?v={video_id}"
    return f"https://www.youtube.com/watch?v={video_id}"


# Vorschaubild immer mitladen: Ersatz-Cover, wenn kein Album-Cover bekannt ist (z. B. Import per Link)
THUMBNAIL_ARGS = ["--write-thumbnail", "--convert-thumbnails", "jpg"]


def format_args(settings: Settings, media_type: str) -> list[str]:
    if media_type == "audio":
        if settings.ytdl_audio_format == "m4a":
            return ["-f", "bestaudio[ext=m4a]/bestaudio/best", "-x", "--audio-format", "m4a", *THUMBNAIL_ARGS]
        if settings.ytdl_audio_format == "mp3":
            return ["-f", "bestaudio/best", "-x", "--audio-format", "mp3", "--audio-quality", "0", *THUMBNAIL_ARGS]
        # Originalspur ohne Umwandlung: meist Opus (~160 kbit/s), sonst AAC
        return [
            "-f", "bestaudio[acodec=opus]/bestaudio[ext=m4a]/bestaudio/best", "-x", "--audio-format", "best",
            *THUMBNAIL_ARGS,
        ]
    height = settings.ytdl_video_max_height
    if settings.ytdl_video_codec == "best":
        selector = f"bv*[height<={height}]+ba/b[height<={height}]/bv*+ba/b"
        merge = "mkv"
    else:
        # H.264 + AAC in MP4: läuft auf jedem Handy (YouTube bietet H.264 bis 1080p)
        selector = (
            f"bv*[vcodec^=avc1][height<={height}]+ba[ext=m4a]/b[ext=mp4][height<={height}]"
            f"/bv*[height<={height}]+ba/b[height<={height}]/b"
        )
        merge = "mp4"
    return ["-f", selector, "--merge-output-format", merge, *THUMBNAIL_ARGS]


def build_download_command(settings: Settings, video_id: str, media_type: str, workdir: Path) -> list[str]:
    command = [
        *base_command(settings),
        "--ignore-config", "--no-playlist", "--no-simulate", "--newline", "--quiet", "--progress",
        "--retries", "5", "--fragment-retries", "10",
        "-o", str(workdir / "%(id)s.%(ext)s"),
        *format_args(settings, media_type),
        "--progress-template",
        "download:" + DL_PREFIX + "%(progress.status)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|"
        "%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s|%(info.format_id)s",
        "--progress-template", "postprocess:" + PP_PREFIX + "%(progress.status)s|%(progress.postprocessor)s",
        "--print", "video:" + PLAN_PREFIX + "%(requested_formats.:.{format_id,filesize,filesize_approx})j",
        "--print", "after_move:" + FILE_PREFIX + "%(filepath)s",
        "--print",
        "after_move:" + INFO_PREFIX
        + "%(.{id,title,track,artist,artists,album,album_artist,release_year,upload_date,channel,duration})j",
    ]
    if settings.ytdl_cookies_file.is_file():
        command += ["--cookies", str(settings.ytdl_cookies_file)]
    command.append(source_url(video_id, media_type))
    return command


def _number(value: str) -> float | None:
    value = value.strip()
    if not value or value in ("NA", "None", "null"):
        return None
    try:
        return float(value)
    except ValueError:
        return None


@dataclass
class ProgressState:
    """Rechnet die Fortschritte mehrerer Teil-Downloads (Video + Ton) zu einem Gesamtwert zusammen."""

    planned: list[int | None] = field(default_factory=list)
    finished_formats: list[str] = field(default_factory=list)
    finished_bytes: int = 0
    current_format: str | None = None
    current_downloaded: int = 0
    current_total: int | None = None
    speed: float | None = None
    eta: int | None = None
    phase: str = "downloading"

    def set_plan(self, sizes: list[int | None]) -> None:
        self.planned = sizes

    def update(self, status: str, downloaded: float | None, total: float | None, estimate: float | None,
               speed: float | None, eta: float | None, format_id: str) -> None:
        if self.current_format is not None and format_id != self.current_format:
            if self.current_format not in self.finished_formats:
                self.finished_formats.append(self.current_format)
                self.finished_bytes += int(self.current_total or self.current_downloaded)
            self.current_downloaded, self.current_total = 0, None
        self.current_format = format_id
        self.current_downloaded = int(downloaded or 0)
        self.current_total = int(total or estimate) if (total or estimate) else None
        self.speed = speed
        self.eta = int(eta) if eta is not None else None
        if status == "finished":
            self.current_downloaded = self.current_total or self.current_downloaded

    @property
    def streams(self) -> int:
        return max(len(self.planned), len(self.finished_formats) + (1 if self.current_format else 0), 1)

    @property
    def downloaded_bytes(self) -> int:
        return self.finished_bytes + self.current_downloaded

    @property
    def total_bytes(self) -> int | None:
        if self.planned and all(size for size in self.planned):
            return max(sum(int(s or 0) for s in self.planned), self.downloaded_bytes)
        if self.current_total and self.streams == len(self.finished_formats) + 1:
            return self.finished_bytes + self.current_total
        return None

    @property
    def fraction(self) -> float:
        if self.phase != "downloading":
            return 1.0
        total = self.total_bytes
        if total:
            return min(self.downloaded_bytes / total, 0.999)
        current = (self.current_downloaded / self.current_total) if self.current_total else 0.0
        return min((len(self.finished_formats) + current) / self.streams, 0.999)

    @property
    def overall_eta(self) -> int | None:
        total = self.total_bytes
        if total and self.speed:
            return max(0, int((total - self.downloaded_bytes) / self.speed))
        if self.eta is not None and self.streams > len(self.finished_formats) + 1:
            return None  # noch weitere Teile ausstehend – unbekannt
        return self.eta


@dataclass
class DownloadResult:
    filepath: Path | None
    info: dict


def run_download(
    command: list[str],
    env: dict[str, str],
    on_progress: Callable[[ProgressState], None],
    cancelled: threading.Event,
    register: Callable[[subprocess.Popen[str]], None] | None = None,
) -> DownloadResult:
    """Startet yt-dlp und meldet laufend den Fortschritt. Wirft bei Fehler/Abbruch eine Ausnahme."""
    process = subprocess.Popen(  # noqa: S603 – Argumente stammen vollständig vom Server
        command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8",
        errors="replace", env=env, bufsize=1,
    )
    if register:
        register(process)
    stderr_lines: list[str] = []
    last_output = [time.monotonic()]
    state = ProgressState()

    def enter_processing() -> None:
        if state.phase != "processing":
            state.phase = "processing"
            on_progress(state)

    def read_stderr() -> None:
        assert process.stderr is not None
        for line in process.stderr:
            last_output[0] = time.monotonic()
            # yt-dlp schreibt die Nachbearbeitungs-Meldungen (Umwandeln, Zusammenfügen) auf stderr
            if line.strip().startswith(PP_PREFIX):
                enter_processing()
                continue
            stderr_lines.append(line.rstrip())
            del stderr_lines[:-40]

    def watchdog() -> None:
        while process.poll() is None:
            if cancelled.is_set() or time.monotonic() - last_output[0] > STALL_TIMEOUT:
                process.kill()
                return
            time.sleep(0.3)

    threading.Thread(target=read_stderr, daemon=True).start()
    threading.Thread(target=watchdog, daemon=True).start()

    filepath: Path | None = None
    info: dict = {}
    assert process.stdout is not None
    for raw_line in process.stdout:
        last_output[0] = time.monotonic()
        line = raw_line.strip()
        if line.startswith(DL_PREFIX):
            parts = line[len(DL_PREFIX):].split("|")
            if len(parts) >= 7:
                state.update(
                    parts[0], _number(parts[1]), _number(parts[2]), _number(parts[3]),
                    _number(parts[4]), _number(parts[5]), parts[6],
                )
                on_progress(state)
        elif line.startswith(PP_PREFIX):
            enter_processing()
        elif line.startswith(PLAN_PREFIX):
            try:
                plan = json.loads(line[len(PLAN_PREFIX):])
            except json.JSONDecodeError:
                plan = None
            if isinstance(plan, list):
                state.set_plan([(p or {}).get("filesize") or (p or {}).get("filesize_approx") for p in plan])
        elif line.startswith(FILE_PREFIX):
            filepath = Path(line[len(FILE_PREFIX):].strip())
        elif line.startswith(INFO_PREFIX):
            try:
                info = json.loads(line[len(INFO_PREFIX):]) or {}
            except json.JSONDecodeError:
                info = {}
    process.wait()
    if cancelled.is_set():
        raise DownloadCancelledError("Abgebrochen")
    if process.returncode != 0:
        errors = [line for line in stderr_lines if "ERROR" in line] or stderr_lines[-3:]
        message = errors[-1] if errors else f"yt-dlp beendet mit Code {process.returncode}"
        raise DownloadFailedError(message.replace("ERROR: ", "").strip()[:500])
    return DownloadResult(filepath=filepath, info=info if isinstance(info, dict) else {})


@dataclass
class ResolvedEntry:
    video_id: str
    title: str
    artists: list[str]
    duration: float | None


def resolve_url(settings: Settings, url: str, timeout: int = 120) -> list[ResolvedEntry]:
    """Löst einen YouTube-Link (Video oder Playlist) in einzelne Video-IDs auf – ohne herunterzuladen."""
    command = [
        *base_command(settings), "--ignore-config", "--flat-playlist", "--quiet", "--no-warnings",
        "--print", ENTRY_PREFIX + "%(.{id,title,channel,uploader,artist,duration})j", url,
    ]
    try:
        result = subprocess.run(  # noqa: S603
            command, capture_output=True, text=True, timeout=timeout, env=ytdlp_env(settings), check=False
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise DownloadFailedError(f"Link konnte nicht gelesen werden: {exc}") from exc
    entries: list[ResolvedEntry] = []
    for line in result.stdout.splitlines():
        if not line.startswith(ENTRY_PREFIX):
            continue
        try:
            data = json.loads(line[len(ENTRY_PREFIX):])
        except json.JSONDecodeError:
            continue
        video_id = str(data.get("id") or "")
        if len(video_id) != 11:
            continue
        artist = data.get("artist") or data.get("channel") or data.get("uploader")
        entries.append(
            ResolvedEntry(
                video_id=video_id,
                title=str(data.get("title") or video_id),
                artists=[str(artist).removesuffix(" - Topic")] if artist else [],
                duration=data.get("duration"),
            )
        )
    if not entries and result.returncode != 0:
        errors = [line for line in result.stderr.splitlines() if "ERROR" in line]
        raise DownloadFailedError((errors[-1] if errors else "Link konnte nicht gelesen werden.")[:500])
    return entries


def ytdlp_version(settings: Settings) -> str | None:
    try:
        result = subprocess.run(  # noqa: S603
            [*base_command(settings), "--version"], capture_output=True, text=True, timeout=30,
            env=ytdlp_env(settings), check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    return result.stdout.strip() or None


def update_ytdlp(settings: Settings) -> tuple[bool, str]:
    """Installiert die neueste yt-dlp-Version nach DATA_DIR/ytdlp (ohne Root-Rechte, wirkt sofort)."""
    target = settings.ytdlp_update_dir
    target.mkdir(parents=True, exist_ok=True)
    command = [
        sys.executable, "-m", "pip", "install", "--upgrade", "--no-deps", "--no-cache-dir",
        "--disable-pip-version-check", "--target", str(target), "yt-dlp", "yt-dlp-ejs",
    ]
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=600, check=False)  # noqa: S603
    except (OSError, subprocess.TimeoutExpired) as exc:
        return False, str(exc)
    if result.returncode != 0:
        return False, (result.stderr.strip().splitlines() or ["unbekannter Fehler"])[-1]
    return True, ytdlp_version(settings) or "?"
