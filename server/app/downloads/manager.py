"""Download-Warteschlange: Aufträge annehmen, mit yt-dlp herunterladen, taggen, einsortieren, melden."""

import logging
import shutil
import subprocess
import threading
import time
from datetime import datetime
from pathlib import Path
from typing import Any

from sqlalchemy import func, select, update
from sqlalchemy.orm import Session, aliased, sessionmaker

from app.config import Settings
from app.downloads import tagging, ytdlp
from app.downloads.events import EventHub
from app.downloads.youtube import YouTubeError, YouTubeMusic, is_allowed_thumbnail
from app.library.scanner import LibraryScanner
from app.models import ACTIVE_STATES, Category, DownloadJob, Playlist, Track, User, utcnow
from app.schemas.downloads import JobOut
from app.schemas.personal import UserRef

logger = logging.getLogger(__name__)

PROGRESS_EVENT_INTERVAL = 0.5  # Sekunden zwischen zwei Live-Meldungen pro Auftrag
PROGRESS_DB_INTERVAL = 5.0
UPDATE_INTERVAL = 24 * 3600
MEDIA_SUFFIXES = {".opus", ".ogg", ".m4a", ".mp3", ".webm", ".mp4", ".mkv", ".flac", ".wav", ".aac", ".mov"}


def job_out(job: DownloadJob, queue_position: int | None = None) -> JobOut:
    return JobOut(
        id=job.id,
        status=job.status,  # type: ignore[arg-type]
        media_type=job.media_type,  # type: ignore[arg-type]
        video_id=job.video_id,
        title=job.title or job.video_id,
        artists=list(job.artists or []),
        album=job.album,
        thumbnail_url=job.thumbnail_url,
        category_id=job.category_id,
        progress=round(job.progress or 0, 4),
        downloaded_bytes=job.downloaded_bytes or 0,
        total_bytes=job.total_bytes,
        speed=job.speed,
        eta=job.eta,
        queue_position=queue_position,
        error=job.error,
        track_id=job.track_id,
        playlist_id=job.playlist_id,
        user=UserRef(id=job.user.id, display_name=job.user.display_name) if job.user else None,
        created_at=job.created_at,
        started_at=job.started_at,
        finished_at=job.finished_at,
    )


class DownloadManager:
    def __init__(
        self,
        settings: Settings,
        session_factory: sessionmaker[Session],
        scanner: LibraryScanner,
        youtube: YouTubeMusic,
        hub: EventHub,
    ) -> None:
        self.settings = settings
        self.session_factory = session_factory
        self.scanner = scanner
        self.youtube = youtube
        self.hub = hub
        self._wakeup = threading.Condition()
        self._claim_lock = threading.Lock()
        self._stop = threading.Event()
        self._threads: list[threading.Thread] = []
        self._cancel_flags: dict[int, threading.Event] = {}
        self._processes: dict[int, subprocess.Popen[str]] = {}
        self._live: dict[int, dict[str, Any]] = {}
        self._live_lock = threading.Lock()
        self.last_update: datetime | None = None
        self.last_update_result: str | None = None

    # ------------------------------------------------------------ Lebenszyklus

    def start(self) -> None:
        self._stop.clear()
        with self.session_factory() as db:
            # Nach einem Neustart: angefangene Downloads erneut einreihen
            db.execute(
                update(DownloadJob)
                .where(DownloadJob.status.in_(["downloading", "processing"]))
                .values(status="queued", progress=0, speed=None, eta=None)
            )
            db.commit()
        for index in range(self.settings.download_workers):
            thread = threading.Thread(target=self._worker, name=f"download-{index + 1}", daemon=True)
            thread.start()
            self._threads.append(thread)
        if self.settings.ytdl_auto_update:
            thread = threading.Thread(target=self._updater, name="ytdlp-update", daemon=True)
            thread.start()
            self._threads.append(thread)

    def stop(self) -> None:
        self._stop.set()
        for flag in list(self._cancel_flags.values()):
            flag.set()
        for process in list(self._processes.values()):
            if process.poll() is None:
                process.kill()
        with self._wakeup:
            self._wakeup.notify_all()
        for thread in self._threads:
            thread.join(timeout=10)
        self._threads = []

    def notify(self) -> None:
        with self._wakeup:
            self._wakeup.notify_all()

    # ------------------------------------------------------------ Aufträge

    def queue_positions(self, db: Session) -> dict[int, int]:
        queued = db.scalars(
            select(DownloadJob.id)
            .where(DownloadJob.status == "queued")
            .order_by(DownloadJob.created_at, DownloadJob.id)
        ).all()
        return {job_id: index for index, job_id in enumerate(queued)}

    def out(self, db: Session, job: DownloadJob, positions: dict[int, int] | None = None) -> JobOut:
        positions = self.queue_positions(db) if positions is None else positions
        return job_out(job, positions.get(job.id))

    def publish(self, db: Session, job: DownloadJob) -> None:
        self.hub.publish({"type": "job", "job": self.out(db, job).model_dump(mode="json")}, job.user_id)

    def publish_queue(self, db: Session) -> None:
        """Ein Auftrag hat die Warteschlange verlassen: alle wartenden mit ihrem neuen Platz melden."""
        positions = self.queue_positions(db)
        if not positions:
            return
        for job in db.scalars(select(DownloadJob).where(DownloadJob.id.in_(list(positions)))).unique():
            self.hub.publish(
                {"type": "job", "job": self.out(db, job, positions).model_dump(mode="json")}, job.user_id
            )

    def enqueue(
        self,
        db: Session,
        user: User,
        *,
        video_id: str,
        media_type: str,
        category: Category,
        playlist_id: int | None = None,
        title: str | None = None,
        artists: list[str] | None = None,
        album: str | None = None,
        album_artist: str | None = None,
        track_number: int | None = None,
        year: int | None = None,
        thumbnail_url: str | None = None,
    ) -> DownloadJob:
        """Legt einen Auftrag an – oder liefert den eigenen laufenden bzw. sofort fertigen, falls es den Titel gibt.

        Lädt gerade jemand anderes denselben Titel, bekommt der Benutzer trotzdem einen eigenen Auftrag (sichtbar,
        abbrechbar, mit eigener Ziel-Playlist). Der Worker wartet damit, bis der andere fertig ist, und übernimmt
        dann den schon geladenen Titel.
        """
        running = db.scalar(
            select(DownloadJob).where(
                DownloadJob.video_id == video_id,
                DownloadJob.media_type == media_type,
                DownloadJob.user_id == user.id,
                DownloadJob.status.in_(ACTIVE_STATES),
            )
        )
        if running is not None:
            return running

        job = DownloadJob(
            user_id=user.id,
            category_id=category.id,
            media_type=media_type,
            video_id=video_id,
            title=(title or "").strip()[:255],
            artists=[a.strip()[:255] for a in (artists or []) if a.strip()][:20],
            album=(album or None) and album.strip()[:255],
            album_artist=(album_artist or None) and album_artist.strip()[:255],
            track_number=track_number,
            year=year,
            thumbnail_url=thumbnail_url if is_allowed_thumbnail(thumbnail_url) else None,
            playlist_id=playlist_id,
            status="queued",
        )
        existing = db.scalar(
            select(Track).where(Track.source_id == video_id, Track.media_type == media_type).limit(1)
        )
        if existing is not None:  # schon in der Bibliothek -> sofort fertig
            job.status, job.progress, job.track_id = "done", 1.0, existing.id
            job.title = job.title or existing.title
            job.started_at = job.finished_at = utcnow()
            db.add(job)
            db.flush()
            if playlist_id:
                self._add_to_playlist(db, job)
            db.commit()
            self.publish(db, job)
            return job
        db.add(job)
        db.commit()
        self.publish(db, job)
        self.notify()
        return job

    def cancel(self, db: Session, job: DownloadJob) -> None:
        if job.status == "queued":
            job.status, job.finished_at = "cancelled", utcnow()
            db.commit()
            self.publish(db, job)
            self.publish_queue(db)
        elif job.status in ("downloading", "processing"):
            flag = self._cancel_flags.get(job.id)
            if flag is not None:
                flag.set()

    def retry(self, db: Session, job: DownloadJob) -> None:
        if job.status in ("failed", "cancelled"):
            job.status, job.progress, job.error = "queued", 0.0, None
            job.downloaded_bytes, job.total_bytes, job.speed, job.eta = 0, None, None, None
            job.started_at = job.finished_at = None
            job.created_at = utcnow()
            db.commit()
            self.publish(db, job)
            self.notify()

    def live(self, job_id: int) -> dict[str, Any] | None:
        with self._live_lock:
            return dict(self._live[job_id]) if job_id in self._live else None

    # ------------------------------------------------------------ Worker

    def _claim(self) -> int | None:
        with self._claim_lock, self.session_factory() as db:
            # Titel, die gerade schon (für jemand anderen) geladen werden, warten lassen
            busy = aliased(DownloadJob)
            already_loading = (
                select(busy.id)
                .where(
                    busy.video_id == DownloadJob.video_id,
                    busy.media_type == DownloadJob.media_type,
                    busy.status.in_(("downloading", "processing")),
                )
                .exists()
            )
            job = db.scalar(
                select(DownloadJob)
                .where(DownloadJob.status == "queued", ~already_loading)
                .order_by(DownloadJob.created_at, DownloadJob.id)
                .limit(1)
            )
            if job is None:
                return None
            job.status, job.started_at, job.progress = "downloading", utcnow(), 0.0
            # Abbruch-Signal schon jetzt anlegen: Ab dem Commit sieht die App "lädt" und kann "Stoppen" tippen
            self._cancel_flags[job.id] = threading.Event()
            try:
                db.commit()
            except Exception:
                self._cancel_flags.pop(job.id, None)
                raise
            self.publish(db, job)
            self.publish_queue(db)
            return job.id

    def _worker(self) -> None:
        while not self._stop.is_set():
            try:
                job_id = self._claim()
            except Exception:  # noqa: BLE001 – z. B. Datenbank kurz gesperrt: später erneut versuchen
                logger.exception("Download-Warteschlange konnte nicht gelesen werden")
                self._stop.wait(5)
                continue
            if job_id is None:
                with self._wakeup:
                    self._wakeup.wait(timeout=5)
                continue
            try:
                self._process(job_id)
            except Exception:  # noqa: BLE001 – ein Fehler darf den Worker nicht beenden
                logger.exception("Download %s: unerwarteter Fehler", job_id)
                try:
                    self._finish(job_id, "failed", error="Unerwarteter Fehler – Details im Server-Log.")
                except Exception:  # noqa: BLE001
                    logger.exception("Download %s: Status konnte nicht gespeichert werden", job_id)

    def _finish(self, job_id: int, status: str, **values: Any) -> None:
        with self.session_factory() as db:
            job = db.get(DownloadJob, job_id)
            if job is None:
                return
            job.status = status
            job.finished_at = utcnow()
            job.speed, job.eta = None, None
            for key, value in values.items():
                setattr(job, key, value)
            db.commit()
            self.publish(db, job)
        with self._live_lock:
            self._live.pop(job_id, None)

    def _process(self, job_id: int) -> None:
        cancelled = self._cancel_flags.setdefault(job_id, threading.Event())
        try:
            self._run(job_id, cancelled)
        finally:
            self._cancel_flags.pop(job_id, None)

    def _run(self, job_id: int, cancelled: threading.Event) -> None:
        if self._stop.is_set():  # zwischen Übernehmen und Start heruntergefahren: beim nächsten Start weiter
            self._requeue(job_id)
            return
        with self.session_factory() as db:
            job = db.get(DownloadJob, job_id)
            if job is None:
                return
            existing = db.scalar(
                select(Track.id).where(Track.source_id == job.video_id, Track.media_type == job.media_type).limit(1)
            )
            if existing is not None:  # inzwischen (z. B. für jemand anderen) geladen -> übernehmen
                job.track_id = existing
                if job.playlist_id:
                    self._add_to_playlist(db, job)
                db.commit()
            else:
                category = db.get(Category, job.category_id)
                if category is None:
                    self._finish(job_id, "failed", error="Die Rubrik gibt es nicht mehr.")
                    return
                snapshot = {
                    "video_id": job.video_id, "media_type": job.media_type, "title": job.title,
                    "artists": list(job.artists or []), "album": job.album, "album_artist": job.album_artist,
                    "track_number": job.track_number, "year": job.year, "thumbnail_url": job.thumbnail_url,
                    "folder": category.folder, "category_id": category.id, "user_id": job.user_id,
                }
        if existing is not None:
            self._finish(job_id, "done", progress=1.0, track_id=existing, error=None)
            return

        workdir = self.settings.downloads_tmp_dir / f"job-{job_id}"
        shutil.rmtree(workdir, ignore_errors=True)
        workdir.mkdir(parents=True, exist_ok=True)
        if self._stop.is_set():  # Server fährt gerade herunter (stop() hat diesen Auftrag nicht mehr erwischt)
            cancelled.set()
        try:
            if cancelled.is_set():  # schon vor dem Start gestoppt
                raise ytdlp.DownloadCancelledError
            result = self._download(job_id, snapshot, workdir, cancelled)
            if cancelled.is_set():  # zwischen Ende des Downloads und Verarbeitung abgebrochen
                raise ytdlp.DownloadCancelledError
            self._set_processing(job_id)
            final_path = self._finalize_file(snapshot, workdir, result, cancelled)
            track_id = self._ingest(job_id, snapshot, final_path)
            self._finish(job_id, "done", progress=1.0, track_id=track_id, error=None)
            logger.info("Download fertig: %s -> %s", snapshot["video_id"], final_path)
        except ytdlp.DownloadCancelledError:
            if self._stop.is_set():
                # Server wird beendet (Neustart, Update): nicht als abgebrochen werten, sondern neu einreihen
                self._requeue(job_id)
            else:
                self._finish(job_id, "cancelled")
        except (ytdlp.DownloadFailedError, OSError, ValueError) as exc:
            logger.warning("Download %s fehlgeschlagen: %s", snapshot["video_id"], exc)
            self._finish(job_id, "failed", error=str(exc)[:1000])
        finally:
            self._processes.pop(job_id, None)
            shutil.rmtree(workdir, ignore_errors=True)

    def _download(
        self, job_id: int, snapshot: dict[str, Any], workdir: Path, cancelled: threading.Event
    ) -> ytdlp.DownloadResult:
        command = ytdlp.build_download_command(self.settings, snapshot["video_id"], snapshot["media_type"], workdir)
        last_event = [0.0]
        last_db = [time.monotonic()]

        def on_progress(state: ytdlp.ProgressState) -> None:
            values = {
                "progress": round(state.fraction, 4),
                "downloaded_bytes": state.downloaded_bytes,
                "total_bytes": state.total_bytes,
                "speed": state.speed,
                "eta": state.overall_eta,
                "status": "processing" if state.phase == "processing" else "downloading",
            }
            with self._live_lock:
                self._live[job_id] = values
            now = time.monotonic()
            urgent = values["status"] == "processing"
            if not urgent and now - last_event[0] < PROGRESS_EVENT_INTERVAL:
                return
            last_event[0] = now
            with self.session_factory() as db:
                job = db.get(DownloadJob, job_id)
                if job is None:
                    return
                for key, value in values.items():
                    setattr(job, key, value)
                if urgent or now - last_db[0] > PROGRESS_DB_INTERVAL:
                    db.commit()
                    last_db[0] = now
                self.publish(db, job)
                db.rollback()  # Fortschritt nur gelegentlich speichern

        def register(process: subprocess.Popen[str]) -> None:
            self._processes[job_id] = process

        return ytdlp.run_download(command, ytdlp.ytdlp_env(self.settings), on_progress, cancelled, register)

    def _set_processing(self, job_id: int) -> None:
        with self.session_factory() as db:
            job = db.get(DownloadJob, job_id)
            if job is not None and job.status != "processing":
                job.status, job.progress, job.eta = "processing", 1.0, None
                db.commit()
                self.publish(db, job)

    # ------------------------------------------------- Taggen & Einsortieren

    def _requeue(self, job_id: int) -> None:
        with self.session_factory() as db:
            db.execute(
                update(DownloadJob)
                .where(DownloadJob.id == job_id)
                .values(status="queued", progress=0, downloaded_bytes=0, speed=None, eta=None, started_at=None)
            )
            db.commit()
        with self._live_lock:
            self._live.pop(job_id, None)

    def _finalize_file(
        self,
        snapshot: dict[str, Any],
        workdir: Path,
        result: ytdlp.DownloadResult,
        cancelled: threading.Event | None = None,
    ) -> Path:
        media_file = result.filepath if result.filepath and result.filepath.is_file() else None
        if media_file is None:
            candidates = [p for p in workdir.iterdir() if p.suffix.lower() in MEDIA_SUFFIXES and p.is_file()]
            if not candidates:
                raise ValueError("yt-dlp hat keine Datei geliefert.")
            media_file = max(candidates, key=lambda p: p.stat().st_size)
        info = result.info
        media_type = snapshot["media_type"]

        artists = snapshot["artists"] or _info_artists(info)
        meta = tagging.TrackMeta(
            title=snapshot["title"] or info.get("track") or info.get("title") or snapshot["video_id"],
            artists=artists,
            album=snapshot["album"] or (info.get("album") if media_type == "audio" else None),
            album_artist=snapshot["album_artist"] or info.get("album_artist") or (artists[0] if artists else None),
            track_number=snapshot["track_number"],
            year=snapshot["year"] or _info_year(info),
            video_id=snapshot["video_id"],
        )
        if media_type == "video":
            meta.album = None

        cover: bytes | None = None
        thumbnail = next((p for p in workdir.glob(f"{media_file.stem}.jpg")), None)
        if media_type == "audio":
            # Das größere Bild gewinnt: Vorschaubilder von Video-Treffern sind klein (z. B. 400×225), yt-dlp lädt
            # das große mit; Song-Cover von YouTube Music (1200 px) bleiben vorn
            cover = tagging.best_square_jpeg([
                tagging.fetch_image(snapshot["thumbnail_url"]),
                thumbnail.read_bytes() if thumbnail is not None else None,
            ])
        try:
            tagging.write_tags(media_file, meta, cover)
        except Exception as exc:  # noqa: BLE001 – ohne Tags trotzdem weitermachen
            logger.warning("Tags konnten nicht geschrieben werden (%s): %s", media_file.name, exc)

        lyrics = self._lyrics(snapshot, meta, info) if media_type == "audio" else None

        suffix = media_file.suffix.lower()
        target = tagging.unique_path(
            tagging.target_path(self.settings.media_dir, snapshot["folder"], media_type, meta, suffix)
        )
        if cancelled is not None and cancelled.is_set():  # letzte Gelegenheit: danach ist der Titel in der Bibliothek
            raise ytdlp.DownloadCancelledError
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(media_file), target)  # Datenordner und Medien-Share liegen oft auf verschiedenen Laufwerken
        if media_type == "video" and thumbnail is not None and thumbnail.exists():
            shutil.move(str(thumbnail), target.with_suffix(".jpg"))
        if lyrics is not None:
            tagging.write_lrc(target, lyrics)
        return target

    def _lyrics(self, snapshot: dict[str, Any], meta: tagging.TrackMeta, info: dict[str, Any]):  # type: ignore[no-untyped-def]
        if not self.settings.lyrics_enabled:
            return None
        try:
            found = self.youtube.lyrics(snapshot["video_id"])
        except YouTubeError:
            found = None
        except Exception:  # noqa: BLE001
            logger.debug("Songtext von YouTube Music nicht verfügbar", exc_info=True)
            found = None
        if found is None or not found.synced:
            synced = tagging.fetch_lrclib(meta, info.get("duration"))
            if synced is not None and (found is None or synced.synced):
                found = synced
        return found

    def _ingest(self, job_id: int, snapshot: dict[str, Any], final_path: Path) -> int:
        """Neue Datei sofort in die Bibliothek aufnehmen (nicht erst beim nächsten Scan)."""
        self.scanner.scan([snapshot["category_id"]])
        relative = final_path.relative_to(self.settings.media_dir).as_posix()
        with self.session_factory() as db:
            track = db.scalar(select(Track).where(Track.path == relative))
            if track is None:
                raise ValueError("Die Datei wurde heruntergeladen, konnte aber nicht eingelesen werden.")
            track.source, track.source_id = "youtube", snapshot["video_id"]
            job = db.get(DownloadJob, job_id)
            if job is not None:
                job.track_id = track.id
                if job.playlist_id:
                    self._add_to_playlist(db, job)
            db.commit()
            return track.id

    def _add_to_playlist(self, db: Session, job: DownloadJob) -> None:
        from app.services.playlists import add_tracks, can_edit_items

        playlist = db.get(Playlist, job.playlist_id) if job.playlist_id else None
        user = db.get(User, job.user_id) if job.user_id else None
        if playlist is None or user is None or job.track_id is None or not can_edit_items(user, playlist):
            return
        add_tracks(db, playlist, user, [job.track_id], None)

    # ------------------------------------------------------------ yt-dlp aktuell halten

    def _updater(self) -> None:
        if self._stop.wait(60):  # Start nicht verzögern
            return
        while not self._stop.is_set():
            self.update_ytdlp()
            if self._stop.wait(UPDATE_INTERVAL):
                return

    def update_ytdlp(self) -> tuple[bool, str]:
        ok, message = ytdlp.update_ytdlp(self.settings)
        self.last_update = utcnow()
        self.last_update_result = message if ok else f"Fehler: {message}"
        (logger.info if ok else logger.warning)("yt-dlp-Aktualisierung: %s", self.last_update_result)
        return ok, message

    def counts(self, db: Session) -> tuple[int, int]:
        active = db.scalar(
            select(func.count(DownloadJob.id)).where(DownloadJob.status.in_(["downloading", "processing"]))
        )
        queued = db.scalar(select(func.count(DownloadJob.id)).where(DownloadJob.status == "queued"))
        return active or 0, queued or 0


def _info_artists(info: dict[str, Any]) -> list[str]:
    artists = info.get("artists")
    if isinstance(artists, list) and artists:
        return [str(a) for a in artists if a][:20]
    artist = info.get("artist") or info.get("channel")
    if not artist:
        return []
    return [part.strip() for part in str(artist).removesuffix(" - Topic").split(",") if part.strip()][:20]


def _info_year(info: dict[str, Any]) -> int | None:
    year = info.get("release_year")
    if year:
        try:
            return int(year)
        except (TypeError, ValueError):
            return None
    upload = str(info.get("upload_date") or "")
    return int(upload[:4]) if len(upload) >= 4 and upload[:4].isdigit() else None
