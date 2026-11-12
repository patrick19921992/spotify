"""Schemas für Song-Wünsche, Fehlermeldungen, App-Konfiguration und das Dashboard."""

from datetime import datetime
from typing import Annotated, Literal

from pydantic import BaseModel, Field, StringConstraints

from app.schemas.premium import PremiumStatusOut

Title = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=200)]
ShortText = Annotated[str, StringConstraints(strip_whitespace=True, max_length=200)]
LongText = Annotated[str, StringConstraints(strip_whitespace=True, max_length=500)]
RequestStatus = Literal["open", "accepted", "done", "declined"]
BugStatus = Literal["new", "seen", "done"]


class RequestIn(BaseModel):
    title: Title
    artist: ShortText = ""
    note: LongText = ""


class RequestOut(BaseModel):
    id: int
    title: str
    artist: str
    note: str
    status: RequestStatus
    admin_note: str
    created_at: datetime
    updated_at: datetime
    # Zustand des Downloads, falls der Admin den Wunsch angenommen hat (queued, downloading, done, failed …)
    job_status: str | None = None


class UserBrief(BaseModel):
    id: int
    username: str
    display_name: str


class AdminRequestOut(RequestOut):
    user: UserBrief
    job_id: int | None


class RequestPatchIn(BaseModel):
    status: RequestStatus | None = None
    admin_note: LongText | None = None
    # Download, der für diesen Wunsch gestartet wurde (setzt den Status auf „accepted“)
    job_id: int | None = None


class BugReportIn(BaseModel):
    message: Annotated[str, StringConstraints(strip_whitespace=True, min_length=10, max_length=4000)]
    app_version: Annotated[str, StringConstraints(max_length=32)] = ""
    app_build: Annotated[int, Field(ge=0, le=100_000_000)] | None = None
    platform: Annotated[str, StringConstraints(max_length=20)] = ""
    channel: Annotated[str, StringConstraints(max_length=10)] = ""
    device: Annotated[str, StringConstraints(max_length=200)] = ""
    # Letzte Fehlermeldungen der App – nur, wenn der Benutzer sie mitschicken will
    log: Annotated[str, StringConstraints(max_length=20_000)] = ""


class BugReportOut(BaseModel):
    id: int
    user: UserBrief
    message: str
    app_version: str
    app_build: int | None
    platform: str
    channel: str
    device: str
    log: str
    status: BugStatus
    admin_note: str
    created_at: datetime


class BugPatchIn(BaseModel):
    status: BugStatus | None = None
    admin_note: LongText | None = None


class AppConfigOut(BaseModel):
    ads_enabled: bool
    premium_enabled: bool
    wishlist_enabled: bool
    play_latest_build: int
    play_min_build: int
    play_store_url: str
    update_message: str
    maintenance_message: str
    offline_requires_premium: bool
    offline_grace_days: int
    offline_min_client_build: int
    billing_enabled: bool
    billing_product_ids: str
    premium_headline: str
    premium_description: str
    premium_benefits: str
    # Premium-Leistungen (je Leistung „für alle“ = false oder „nur Premium“ = true) und ihre Grenzen
    hq_audio_requires_premium: bool
    free_audio_quality: Literal["normal", "low"]
    video_requires_premium: bool
    lyrics_requires_premium: bool
    requests_requires_premium: bool
    free_requests_per_week: int
    skips_requires_premium: bool
    free_skips_per_hour: int
    remote_requires_premium: bool
    premium_badge_enabled: bool
    # Laufzeiten des Abos (Kennungen der Basis-Abos, Komma) und die empfohlene
    billing_base_plans: str
    billing_recommended_plan: str
    # Selbst-Registrierung: aus, mit Freigabe oder offen; Rubriken für neue Konten (IDs mit Komma)
    registration_mode: Literal["off", "approval", "open"]
    registration_default_categories: str
    # Nur lesbar: ffmpeg ist da (sonst lässt sich die Tonqualität nicht einschränken)
    transcode_available: bool = True


class AppConfigIn(BaseModel):
    """Nur die mitgeschickten Felder werden geändert."""

    ads_enabled: bool | None = None
    premium_enabled: bool | None = None
    wishlist_enabled: bool | None = None
    play_latest_build: int | None = None
    play_min_build: int | None = None
    play_store_url: str | None = None
    update_message: str | None = None
    maintenance_message: str | None = None
    offline_requires_premium: bool | None = None
    offline_grace_days: int | None = None
    offline_min_client_build: int | None = None
    billing_enabled: bool | None = None
    billing_product_ids: str | None = None
    premium_headline: str | None = None
    premium_description: str | None = None
    premium_benefits: str | None = None
    hq_audio_requires_premium: bool | None = None
    free_audio_quality: str | None = None
    video_requires_premium: bool | None = None
    lyrics_requires_premium: bool | None = None
    requests_requires_premium: bool | None = None
    free_requests_per_week: int | None = None
    skips_requires_premium: bool | None = None
    free_skips_per_hour: int | None = None
    remote_requires_premium: bool | None = None
    premium_badge_enabled: bool | None = None
    billing_base_plans: str | None = None
    billing_recommended_plan: str | None = None
    registration_mode: str | None = None
    registration_default_categories: str | None = None


class UpdateInfoOut(BaseModel):
    # none | available | required
    level: Literal["none", "available", "required"]
    latest_build: int
    min_build: int
    store_url: str
    message: str


class PublicConfigOut(BaseModel):
    """Was die App beim Start ohne Anmeldung abfragt."""

    server_name: str
    ads_enabled: bool
    premium_enabled: bool
    wishlist_enabled: bool
    maintenance_message: str
    update: UpdateInfoOut
    privacy_url: str
    deletion_url: str
    # Offline-Hören nur mit Premium (gilt für alle App-Ausgaben; Admins sind ausgenommen)
    offline_requires_premium: bool = False
    offline_grace_days: int = 7
    # Mindest-Build-Nummer der App für Benutzer ohne Premium, solange die Offline-Sperre an ist (0 = aus):
    # Ältere Apps bekommen beim Abspielen und Laden HTTP 426
    offline_min_client_build: int = 0
    # Wirksamer Wert: Schalter an, Play-Version, Kaufprüfung eingerichtet und mindestens eine Produkt-ID
    billing_enabled: bool = False
    billing_product_ids: list[str] = []
    premium_headline: str = ""
    premium_description: str = ""
    premium_benefits: list[str] = []
    # Premium-Leistungen, die der Betreiber nur mit Premium erlaubt (leer = alles für alle, wie bisher)
    premium_only: list[str] = []
    # Höchste Tonqualität ohne Premium (nur wirksam, wenn „hq_audio“ in premium_only steht)
    free_audio_quality: Literal["normal", "low"] = "normal"
    free_requests_per_week: int = 3
    free_skips_per_hour: int = 6
    premium_badge_enabled: bool = False
    # Laufzeiten des Abos in Anzeigereihenfolge (leer = alle, die der Store liefert) – nur bei wirksamem Kauf
    billing_base_plans: list[str] = []
    billing_recommended_plan: str = ""
    # Selbst-Registrierung in der App: aus (Standard), mit Freigabe oder offen
    registration_mode: Literal["off", "approval", "open"] = "off"


class RequestQuotaOut(BaseModel):
    """Wie viele Song-Wünsche diese Woche noch gehen (rollierend 7 Tage)."""

    limited: bool
    limit: int | None
    used: int
    left: int | None
    resets_at: datetime | None


class MyStatusOut(BaseModel):
    premium: PremiumStatusOut


class ClientVersionOut(BaseModel):
    platform: str
    channel: str
    version: str
    build: int | None
    devices: int
    users: int
    last_seen: datetime


class DayCountOut(BaseModel):
    day: str
    count: int


class TopUserOut(BaseModel):
    user_id: int
    display_name: str
    count: int


class StatsOut(BaseModel):
    users_total: int
    users_active: int
    tracks_total: int
    videos_total: int
    downloads_total: int
    downloads_done: int
    downloads_failed: int
    downloads_active: int
    downloads_last_24h: int
    downloads_last_7d: int
    downloads_by_day: list[DayCountOut]
    plays_by_day: list[DayCountOut]
    top_downloaders: list[TopUserOut]
    premium_users: int
    premium_unlimited: int
    codes_available: int
    requests_open: int
    bugs_new: int
    devices_active_7d: int
    # Selbst registrierte Konten, die auf Freischaltung warten
    users_pending: int = 0


class AdminUserOut(BaseModel):
    id: int
    username: str
    display_name: str
    is_admin: bool
    is_active: bool
    can_download: bool
    created_at: datetime
    last_login_at: datetime | None
    # Zuletzt aktiv (jüngste Nutzung eines Geräts) – die App meldet sich nur selten neu an, daher aussagekräftiger
    last_active_at: datetime | None = None
    premium: PremiumStatusOut
    downloads: int
    devices: int
    # Zuletzt gemeldete App dieses Benutzers (z. B. „play 1.0.0 (54)“), falls bekannt
    last_client: str
    # Sichtbarkeit je Rubrik und Selbst-Registrierung
    all_categories: bool = True
    category_ids: list[int] = []
    approval_pending: bool = False
    self_registered: bool = False
