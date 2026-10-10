"""Zentrale Einstellungen – werden aus Umgebungsvariablen gelesen (Unraid-Template / docker-compose)."""

from functools import lru_cache
from pathlib import Path
from typing import Annotated, Literal

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, NoDecode, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    # Anzeigename des Servers in der App
    server_name: str = "Selfify"
    # Öffentliche Adresse hinter dem Reverse Proxy, z. B. https://musik.example.de
    public_url: str = ""

    # Datenordner (Datenbank, Schlüssel, Cover-Cache) -> Unraid: /mnt/user/appdata/selfify
    data_dir: Path = Path("/data")
    # Medienordner mit den Rubrik-Unterordnern -> Unraid: z. B. /mnt/user/selfify
    media_dir: Path = Path("/media")

    # Wird automatisch erzeugt und in data_dir/secret.key gespeichert, wenn leer
    secret_key: str = ""

    # Erster Admin – wird nur angelegt, solange noch kein Benutzer existiert
    admin_username: str = "admin"
    admin_password: str = ""

    access_token_minutes: int = Field(default=30, ge=5, le=24 * 60)
    refresh_token_days: int = Field(default=90, ge=1, le=365)
    # Token in Stream-/Cover-Links (Player brauchen Links, die länger gelten als 30 Minuten)
    media_token_hours: int = Field(default=168, ge=1, le=24 * 90)

    # Bibliothek: beim Start einlesen, regelmäßig nachsehen, Ordner live überwachen
    scan_on_startup: bool = True
    scan_interval_minutes: int = Field(default=30, ge=0)
    library_watch: bool = True

    # Umwandlung (z. B. Opus -> AAC fürs iPhone oder Datensparmodus)
    ffmpeg_path: str = "ffmpeg"
    ffprobe_path: str = "ffprobe"
    transcode_cache_mb: int = Field(default=2048, ge=0)

    # YouTube-Downloader
    download_workers: int = Field(default=2, ge=1, le=8)
    # best = Originalspur ohne Umwandlung (meist Opus, beste Qualität), m4a = AAC (iPhone-nativ), mp3 = MP3 320k
    ytdl_audio_format: Literal["best", "m4a", "mp3"] = "best"
    ytdl_video_max_height: int = Field(default=1080, ge=144, le=4320)
    # compatible = H.264/MP4 (läuft überall), best = höchste Qualität (VP9/AV1, evtl. nicht auf dem iPhone)
    ytdl_video_codec: Literal["compatible", "best"] = "compatible"
    # Täglich die neueste yt-dlp-Version holen (YouTube ändert häufig etwas)
    ytdl_auto_update: bool = True
    # Optional: Cookies (Netscape-Format) z. B. für YouTube-Music-Premium-Qualität
    ytdl_cookies_file: Path = Path("/data/youtube-cookies.txt")
    # Leer = eingebautes yt-dlp ("python -m yt_dlp"); nur für Tests/Sonderfälle
    ytdlp_command: str = ""
    ytmusic_language: str = "de"
    ytmusic_location: str = "DE"
    lyrics_enabled: bool = True

    # Schutz gegen Passwort-Raten (Fehlversuche innerhalb des Zeitfensters)
    login_max_failures_per_user: int = Field(default=10, ge=1)
    login_max_failures_per_ip: int = Field(default=30, ge=1)
    login_window_minutes: int = Field(default=15, ge=1)

    # Swagger-Oberfläche unter /api/docs (praktisch zum Testen, ohne Login nutzlos)
    enable_api_docs: bool = True
    # Nur nötig, falls später ein Web-Client aus einer anderen Domain zugreift
    cors_origins: Annotated[list[str], NoDecode] = []

    log_level: str = "INFO"

    @field_validator("cors_origins", mode="before")
    @classmethod
    def _split_origins(cls, value: object) -> object:
        if isinstance(value, str):
            return [item.strip() for item in value.split(",") if item.strip()]
        return value

    @field_validator("public_url")
    @classmethod
    def _strip_trailing_slash(cls, value: str) -> str:
        return value.rstrip("/")

    @property
    def covers_dir(self) -> Path:
        return self.data_dir / "covers"

    @property
    def transcode_dir(self) -> Path:
        return self.data_dir / "transcode"

    @property
    def downloads_tmp_dir(self) -> Path:
        return self.data_dir / "downloads"

    @property
    def ytdlp_update_dir(self) -> Path:
        """Hierhin installiert die Auto-Aktualisierung neuere yt-dlp-Versionen (beschreibbar für 99:100)."""
        return self.data_dir / "ytdlp"

    @property
    def database_path(self) -> Path:
        return self.data_dir / "selfify.db"

    @property
    def database_url(self) -> str:
        return f"sqlite:///{self.database_path}"


@lru_cache
def get_settings() -> Settings:
    return Settings()
