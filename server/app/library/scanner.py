"""Liest die Rubrik-Ordner ein und hält die Bibliothek aktuell.

- Vollständiger Scan beim Start, danach regelmäßig (SCAN_INTERVAL_MINUTES)
- Live-Überwachung der Ordner (LIBRARY_WATCH): neue/gelöschte Dateien erscheinen nach wenigen Sekunden
- Unveränderte Dateien (gleiche Größe + Änderungszeit) werden übersprungen – ein erneuter Scan ist schnell
"""

import logging
import os
import threading
import time
from collections.abc import Iterable, Iterator
from dataclasses import dataclass, field, replace
from datetime import datetime
from pathlib import Path, PurePosixPath

from sqlalchemy import delete, select, text, update
from sqlalchemy.orm import Session, sessionmaker

from app.config import Settings
from app.library.covers import CoverStore, find_folder_image, find_sidecar_image
from app.library.metadata import (
    AUDIO_EXTENSIONS,
    IGNORED_SUFFIXES,
    VIDEO_EXTENSIONS,
    MediaInfo,
    apply_path_fallbacks,
    extract_video_frame,
    read_media_info,
)
from app.library.text import match_key, search_text, sort_key
from app.models import Album, Artist, Category, Cover, Track, TrackArtist, utcnow

logger = logging.getLogger(__name__)

UNKNOWN_ARTIST = "Unbekannter Künstler"
COMMIT_EVERY = 100
# Spätestens nach dieser Zeit wird gespeichert: Solange der Scan schreibt, müssen alle anderen
# (Anmelden, Likes, Downloads) auf die Datenbank warten.
COMMIT_SECONDS = 0.5
SKIPPED_DIRS = {"@eadir", "#recycle", "lost+found", "$recycle.bin"}


@dataclass
class ScanStatus:
    running: bool = False
    started_at: datetime | None = None
    finished_at: datetime | None = None
    files_seen: int = 0
    added: int = 0
    updated: int = 0
    removed: int = 0
    errors: int = 0
    last_error: str | None = None
    error_files: list[str] = field(default_factory=list)


class LibraryScanner:
    def __init__(self, settings: Settings, session_factory: sessionmaker[Session], covers: CoverStore) -> None:
        self.settings = settings
        self.session_factory = session_factory
        self.covers = covers
        self._status = ScanStatus()
        self._status_lock = threading.Lock()
        self._scan_lock = threading.Lock()
        self._wakeup = threading.Condition()
        self._pending_all = False
        self._pending_ids: set[int] = set()
        self._stop = threading.Event()
        self._threads: list[threading.Thread] = []
        # Defekte Dateien nur einmal melden, solange sie sich nicht ändern
        self._known_failures: dict[str, tuple[int, float]] = {}

    # ------------------------------------------------------------------ Status

    @property
    def status(self) -> ScanStatus:
        with self._status_lock:
            return replace(self._status, error_files=list(self._status.error_files))

    def _update_status(self, **changes: object) -> None:
        with self._status_lock:
            for key, value in changes.items():
                setattr(self._status, key, value)

    def _count(self, key: str, amount: int = 1) -> None:
        with self._status_lock:
            setattr(self._status, key, getattr(self._status, key) + amount)

    # ------------------------------------------------------------ Hintergrund

    @property
    def background_active(self) -> bool:
        return any(thread.is_alive() for thread in self._threads)

    def start(self) -> None:
        self._stop.clear()
        self._threads = [threading.Thread(target=self._worker, name="library-scan", daemon=True)]
        if self.settings.library_watch:
            self._threads.append(threading.Thread(target=self._watcher, name="library-watch", daemon=True))
        for thread in self._threads:
            thread.start()
        if self.settings.scan_on_startup:
            self.request_scan()

    def stop(self) -> None:
        self._stop.set()
        with self._wakeup:
            self._wakeup.notify_all()
        for thread in self._threads:
            thread.join(timeout=10)
        self._threads = []

    def request_scan(self, category_ids: Iterable[int] | None = None) -> None:
        """Plant einen Scan im Hintergrund (None = alle Rubriken)."""
        with self._wakeup:
            if category_ids is None:
                self._pending_all = True
            else:
                self._pending_ids.update(category_ids)
            self._wakeup.notify_all()

    def _worker(self) -> None:
        interval = self.settings.scan_interval_minutes * 60 or None
        while not self._stop.is_set():
            with self._wakeup:
                if not self._pending_all and not self._pending_ids:
                    notified = self._wakeup.wait(timeout=interval)
                    if self._stop.is_set():
                        return
                    if not notified and interval:
                        self._pending_all = True
                pending_all, pending_ids = self._pending_all, set(self._pending_ids)
                self._pending_all, self._pending_ids = False, set()
            if not pending_all and not pending_ids:
                continue
            try:
                self.scan(None if pending_all else pending_ids)
            except Exception:  # noqa: BLE001 – der Hintergrund-Scan darf nie dauerhaft ausfallen
                logger.exception("Bibliotheks-Scan fehlgeschlagen")

    def _watcher(self) -> None:
        try:
            from watchfiles import watch
        except ImportError:
            logger.warning("watchfiles fehlt – Live-Überwachung der Ordner ist aus.")
            return
        media_dir = self.settings.media_dir
        while not self._stop.is_set():
            if not media_dir.is_dir():
                self._stop.wait(60)
                continue
            try:
                for changes in watch(media_dir, stop_event=self._stop, debounce=3000, raise_interrupt=False):
                    paths = [Path(p) for _, p in changes if Path(p).suffix.lower() not in IGNORED_SUFFIXES]
                    ids = self._categories_for_paths(paths)
                    if ids:
                        logger.info("Änderungen im Medienordner erkannt – Rubriken %s werden neu eingelesen.", ids)
                        self.request_scan(ids)
            except Exception as exc:  # noqa: BLE001
                logger.warning("Ordner-Überwachung unterbrochen (%s) – neuer Versuch in 60 s.", exc)
                self._stop.wait(60)

    def _categories_for_paths(self, paths: list[Path]) -> set[int]:
        with self.session_factory() as db:
            categories = [(c.id, c.folder) for c in db.scalars(select(Category))]
        media_dir = self.settings.media_dir.resolve()
        ids: set[int] = set()
        for path in paths:
            try:
                relative = PurePosixPath(path.resolve().relative_to(media_dir).as_posix())
            except ValueError:
                continue
            best: tuple[int, int] | None = None
            for category_id, folder in categories:
                folder_path = PurePosixPath(folder)
                if relative == folder_path or folder_path in relative.parents:
                    depth = len(folder_path.parts)
                    if best is None or depth > best[1]:
                        best = (category_id, depth)
            if best:
                ids.add(best[0])
        return ids

    # -------------------------------------------------------------------- Scan

    def scan(self, category_ids: Iterable[int] | None = None) -> ScanStatus:
        """Liest die angegebenen Rubriken (oder alle) ein. Blockiert, bis der Scan fertig ist."""
        with self._scan_lock:
            self._update_status(
                running=True, started_at=utcnow(), finished_at=None, files_seen=0, added=0,
                updated=0, removed=0, errors=0, last_error=None, error_files=[],
            )
            try:
                with self.session_factory() as db:
                    self._scan(db, set(category_ids) if category_ids is not None else None)
            except Exception as exc:
                self._update_status(last_error=str(exc))
                raise
            finally:
                self._update_status(running=False, finished_at=utcnow())
            status = self.status
            logger.info(
                "Scan fertig: %d Dateien, %d neu, %d geändert, %d entfernt, %d Fehler",
                status.files_seen, status.added, status.updated, status.removed, status.errors,
            )
            return status

    def _scan(self, db: Session, category_ids: set[int] | None) -> None:
        media_dir = self.settings.media_dir
        all_categories = list(db.scalars(select(Category)))
        categories = [c for c in all_categories if category_ids is None or c.id in category_ids]
        if not categories:
            return
        scanned_ids = {c.id for c in categories}
        all_folders = {c.folder for c in all_categories}

        existing: dict[str, tuple[int, int, float, int, str | None]] = {
            row.path: (row.id, row.file_size, row.file_mtime, row.category_id, row.cover_id)
            for row in db.execute(
                select(Track.path, Track.id, Track.file_size, Track.file_mtime, Track.category_id, Track.cover_id)
            )
        }
        seen: set[str] = set()
        caches = _ScanCaches()
        pending = 0
        last_commit = time.monotonic()
        # Rubriken, deren Ordner fehlt oder plötzlich leer ist (Share nicht eingehängt, Ordner umbenannt):
        # Ihre Titel bleiben erhalten – sonst wären Playlists, Likes und Verlauf dazu für immer weg.
        unavailable: set[int] = set()
        known_categories = {values[3] for values in existing.values()}

        for category in categories:
            root = media_dir / category.folder
            if not root.is_dir():
                unavailable.add(category.id)
                self._warn_unavailable(category, f"Der Ordner {root} fehlt")
                continue
            nested = {
                media_dir / folder for folder in all_folders if folder.startswith(category.folder + "/")
            }
            extensions = AUDIO_EXTENSIONS if category.media_type == "audio" else VIDEO_EXTENSIONS
            found = 0
            for path in _walk(root, extensions, nested):
                if self._stop.is_set():
                    db.commit()
                    return
                found += 1
                relative = path.relative_to(media_dir).as_posix()
                seen.add(relative)
                self._count("files_seen")
                try:
                    stat = path.stat()
                except OSError:
                    continue
                known = existing.get(relative)
                if known and known[1] == stat.st_size and known[2] == stat.st_mtime and known[3] == category.id:
                    if known[4] is None and category.media_type == "audio" and self._late_cover(
                        db, known[0], path, caches
                    ):
                        pending += 1
                        if time.monotonic() - last_commit >= COMMIT_SECONDS:
                            db.commit()
                            pending = 0
                            last_commit = time.monotonic()
                    continue
                fingerprint = (stat.st_size, stat.st_mtime)
                if self._known_failures.get(relative) == fingerprint:
                    self._record_error(relative, None)
                    continue
                try:
                    info = self._read(category, path)
                except Exception as exc:  # noqa: BLE001 – eine defekte Datei darf den Scan nicht stoppen
                    self._known_failures[relative] = fingerprint
                    self._record_error(relative, exc)
                    continue
                self._known_failures.pop(relative, None)
                try:
                    self._store(db, category, path, relative, stat, known[0] if known else None, info, caches)
                except Exception as exc:  # noqa: BLE001
                    db.rollback()
                    caches.clear()
                    self._record_error(relative, exc)
                    continue
                self._count("added" if known is None else "updated")
                pending += 1
                if pending >= COMMIT_EVERY or time.monotonic() - last_commit >= COMMIT_SECONDS:
                    db.commit()
                    pending = 0
                    last_commit = time.monotonic()
            if found == 0 and category.id in known_categories:
                unavailable.add(category.id)
                self._warn_unavailable(category, f"Der Ordner {root} ist leer")

        removed_ids = [
            track_id
            for path, (track_id, _, _, cat_id, _) in existing.items()
            if cat_id in scanned_ids and cat_id not in unavailable and path not in seen
        ]
        for start in range(0, len(removed_ids), 500):
            db.execute(delete(Track).where(Track.id.in_(removed_ids[start : start + 500])))
        self._count("removed", len(removed_ids))
        db.commit()
        self.finalize(db)

    def _warn_unavailable(self, category: Category, reason: str) -> None:
        message = (
            f"Rubrik „{category.name}“: {reason} – die Titel bleiben vorerst erhalten. "
            "Ist das Unraid-Share eingehängt? Sollen die Titel wirklich weg, die Rubrik in der Verwaltung löschen."
        )
        logger.warning(message)
        with self._status_lock:
            self._status.last_error = message

    def _record_error(self, relative: str, exc: Exception | None) -> None:
        """exc=None: schon bekannter Fehler – zählen, aber nicht erneut ins Log schreiben."""
        if exc is not None:
            logger.warning("Datei konnte nicht eingelesen werden: %s (%s)", relative, exc)
        with self._status_lock:
            self._status.errors += 1
            if exc is not None:
                self._status.last_error = f"{relative}: {exc}"
            if len(self._status.error_files) < 50:
                self._status.error_files.append(relative)

    def _read(self, category: Category, path: Path) -> MediaInfo:
        """Liest Tags und technische Daten (ohne Datenbank – Fehler hier betreffen nur diese Datei)."""
        info = read_media_info(path, category.media_type, self.settings.ffprobe_path)
        if info is None or info.duration <= 0:
            raise ValueError("keine abspielbare Audio-/Videospur gefunden")
        in_category = PurePosixPath(path.relative_to(self.settings.media_dir / category.folder).as_posix())
        return apply_path_fallbacks(info, in_category, category.media_type)

    def _store(
        self,
        db: Session,
        category: Category,
        path: Path,
        relative: str,
        stat: os.stat_result,
        track_id: int | None,
        info: MediaInfo,
        caches: "_ScanCaches",
    ) -> None:
        artist_names = info.artists or [UNKNOWN_ARTIST]
        artists = [self._artist(db, name, caches) for name in artist_names]
        album: Album | None = None
        if info.album and category.media_type == "audio":
            album_artist = self._artist(db, info.album_artist or artist_names[0], caches)
            album = self._album(db, album_artist, info.album, caches)

        track = db.get(Track, track_id) if track_id else None
        if track is None:
            track = Track(path=relative, added_at=utcnow())
            db.add(track)
        track.category_id = category.id
        track.media_type = category.media_type
        track.title = (info.title or path.stem)[:255]
        track.sort_title = sort_key(track.title)
        track.artist_display = (info.artist_display or ", ".join(artist_names))[:512]
        track.album_id = album.id if album else None
        track.track_number = info.track_number
        track.disc_number = info.disc_number
        track.year = info.year
        track.genre = info.genre[:100] if info.genre else None
        track.search_text = search_text(track.title, track.artist_display, *artist_names, info.album)
        track.duration = round(info.duration, 3)
        track.bitrate = info.bitrate
        track.sample_rate = info.sample_rate
        track.codec = info.codec
        track.width = info.width
        track.height = info.height
        track.file_size = stat.st_size
        track.file_mtime = stat.st_mtime
        track.cover_id = self._cover_for(db, path, info, category.media_type, caches)
        if info.source_id:
            track.source, track.source_id = "youtube", info.source_id
        db.flush()

        wanted = {artist.id: position for position, artist in enumerate(artists)}
        for link in list(track.artist_links):
            if link.artist_id not in wanted:
                track.artist_links.remove(link)
            else:
                link.position = wanted.pop(link.artist_id)
        for artist_id, position in wanted.items():
            track.artist_links.append(TrackArtist(artist_id=artist_id, position=position))
        db.flush()

    def _late_cover(self, db: Session, track_id: int, path: Path, caches: "_ScanCaches") -> bool:
        """Unveränderte Datei ohne Cover: später dazugelegtes Bild (Titel.jpg, cover.jpg, folder.jpg) übernehmen."""
        image = find_sidecar_image(path) or find_folder_image(path.parent, caches.folder_images)
        if image is None:
            return False
        if image not in caches.folder_covers:
            caches.folder_covers[image] = self.covers.add_file(db, image)
        cover_id = caches.folder_covers[image]
        if cover_id is None:
            return False
        db.execute(update(Track).where(Track.id == track_id).values(cover_id=cover_id))
        return True

    def _cover_for(
        self, db: Session, path: Path, info: MediaInfo, media_type: str, caches: "_ScanCaches"
    ) -> str | None:
        cover_id: str | None = None
        sidecar = find_sidecar_image(path)
        if media_type == "video":
            if sidecar:
                cover_id = self.covers.add_file(db, sidecar)
            if not cover_id and info.cover:
                cover_id = self.covers.add(db, info.cover)
            if not cover_id:
                frame = extract_video_frame(self.settings.ffmpeg_path, path, info.duration)
                cover_id = self.covers.add(db, frame) if frame else None
            return cover_id
        if info.cover:
            cover_id = self.covers.add(db, info.cover)
        if not cover_id and sidecar:
            cover_id = self.covers.add_file(db, sidecar)
        if not cover_id:
            folder_image = find_folder_image(path.parent, caches.folder_images)
            if folder_image is not None:
                if folder_image not in caches.folder_covers:
                    caches.folder_covers[folder_image] = self.covers.add_file(db, folder_image)
                cover_id = caches.folder_covers[folder_image]
        return cover_id

    def _artist(self, db: Session, name: str, caches: "_ScanCaches") -> Artist:
        name = name.strip()[:255] or UNKNOWN_ARTIST
        key = match_key(name) or match_key(UNKNOWN_ARTIST)
        artist = caches.artists.get(key)
        if artist is None:
            artist = db.scalar(select(Artist).where(Artist.name_key == key))
        if artist is None:
            artist = Artist(name=name, name_key=key, sort_name=sort_key(name), search_text=search_text(name))
            db.add(artist)
            db.flush()
        caches.artists[key] = artist
        return artist

    def _album(self, db: Session, artist: Artist, title: str, caches: "_ScanCaches") -> Album:
        title = title.strip()[:255]
        key = match_key(title) or title.casefold()
        album = caches.albums.get((artist.id, key))
        if album is None:
            album = db.scalar(select(Album).where(Album.artist_id == artist.id, Album.title_key == key))
        if album is None:
            album = Album(
                title=title,
                title_key=key,
                sort_title=sort_key(title),
                artist_id=artist.id,
                search_text=search_text(title, artist.name),
            )
            db.add(album)
            db.flush()
        caches.albums[(artist.id, key)] = album
        return album

    # --------------------------------------------------------------- Aufräumen

    def finalize_now(self, db: Session) -> None:
        """Aufräumen außerhalb eines Scans (z. B. nach dem Löschen einer Rubrik)."""
        if self._scan_lock.acquire(blocking=False):
            try:
                self.finalize(db)
            finally:
                self._scan_lock.release()
        # Sonst läuft gerade ein Scan – der räumt am Ende ohnehin auf

    def finalize(self, db: Session) -> None:
        """Entfernt leere Alben/Künstler/Cover und aktualisiert Zähler, Jahr, Genre und Cover."""
        db.execute(text("DELETE FROM albums WHERE id NOT IN (SELECT album_id FROM tracks WHERE album_id IS NOT NULL)"))
        db.execute(
            text(
                "DELETE FROM artists WHERE id NOT IN (SELECT artist_id FROM track_artists) "
                "AND id NOT IN (SELECT artist_id FROM albums)"
            )
        )
        db.execute(
            text(
                """
                UPDATE albums SET
                  track_count = (SELECT COUNT(*) FROM tracks t WHERE t.album_id = albums.id),
                  duration = (SELECT COALESCE(SUM(t.duration), 0) FROM tracks t WHERE t.album_id = albums.id),
                  year = (SELECT MAX(t.year) FROM tracks t WHERE t.album_id = albums.id),
                  genre = (SELECT t.genre FROM tracks t WHERE t.album_id = albums.id AND t.genre IS NOT NULL
                           GROUP BY t.genre ORDER BY COUNT(*) DESC LIMIT 1),
                  cover_id = (SELECT t.cover_id FROM tracks t WHERE t.album_id = albums.id AND t.cover_id IS NOT NULL
                              GROUP BY t.cover_id
                              ORDER BY COUNT(*) DESC, MIN(COALESCE(t.disc_number, 0)), MIN(COALESCE(t.track_number, 0))
                              LIMIT 1)
                """
            )
        )
        db.execute(
            text(
                """
                UPDATE artists SET
                  track_count = (SELECT COUNT(*) FROM track_artists ta WHERE ta.artist_id = artists.id),
                  album_count = (SELECT COUNT(*) FROM albums a WHERE a.artist_id = artists.id),
                  cover_id = COALESCE(
                    (SELECT a.cover_id FROM albums a WHERE a.artist_id = artists.id AND a.cover_id IS NOT NULL
                     ORDER BY COALESCE(a.year, 0) DESC, a.id DESC LIMIT 1),
                    (SELECT t.cover_id FROM tracks t JOIN track_artists ta ON ta.track_id = t.id
                     WHERE ta.artist_id = artists.id AND t.cover_id IS NOT NULL AND t.media_type = 'audio'
                     ORDER BY t.added_at DESC LIMIT 1),
                    (SELECT t.cover_id FROM tracks t JOIN track_artists ta ON ta.track_id = t.id
                     WHERE ta.artist_id = artists.id AND t.cover_id IS NOT NULL
                     ORDER BY t.added_at DESC LIMIT 1))
                """
            )
        )
        # Playlists: Zähler und Positionen nach entfernten Titeln korrigieren
        from app.services.playlists import refresh_all_stats

        refresh_all_stats(db)
        orphaned = list(
            db.scalars(
                text(
                    "SELECT id FROM covers WHERE id NOT IN (SELECT cover_id FROM tracks WHERE cover_id IS NOT NULL) "
                    "AND id NOT IN (SELECT cover_id FROM albums WHERE cover_id IS NOT NULL) "
                    "AND id NOT IN (SELECT cover_id FROM artists WHERE cover_id IS NOT NULL) "
                    "AND id NOT IN (SELECT cover_id FROM playlists WHERE cover_id IS NOT NULL)"
                )
            )
        )
        if orphaned:
            db.execute(delete(Cover).where(Cover.id.in_(orphaned)))
        db.commit()
        for cover_id in orphaned:
            self.covers.delete(cover_id)


@dataclass
class _ScanCaches:
    artists: dict[str, Artist] = field(default_factory=dict)
    albums: dict[tuple[int, str], Album] = field(default_factory=dict)
    folder_images: dict[Path, Path | None] = field(default_factory=dict)
    folder_covers: dict[Path, str | None] = field(default_factory=dict)

    def clear(self) -> None:
        self.artists.clear()
        self.albums.clear()
        self.folder_covers.clear()


def _walk(root: Path, extensions: set[str], skip_dirs: set[Path]) -> Iterator[Path]:
    """Alle Mediendateien unterhalb von root – ohne versteckte Ordner und ohne verschachtelte Rubriken."""
    for current, dirs, files in os.walk(root, followlinks=False):
        current_path = Path(current)
        dirs[:] = sorted(
            d for d in dirs
            if not d.startswith(".") and d.lower() not in SKIPPED_DIRS and current_path / d not in skip_dirs
        )
        for name in sorted(files):
            if name.startswith("."):
                continue
            suffix = Path(name).suffix.lower()
            if suffix in extensions and suffix not in IGNORED_SUFFIXES:
                yield current_path / name
