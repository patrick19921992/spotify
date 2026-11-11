"""Einstellungen, die der Admin im Dashboard ändert und die die App beim Start abfragt.

Gespeichert in der Tabelle app_settings (Schlüssel/Wert). Fehlt ein Schlüssel, gilt der Standardwert.
Damit lassen sich z. B. Werbung abschalten oder ein Pflicht-Update auslösen, ohne den Server neu zu starten.
"""

import re
from dataclasses import dataclass
from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models import AppSetting, utcnow


@dataclass(frozen=True)
class Spec:
    default: Any
    # Obergrenze: Länge bei Text, Wert bei Zahlen
    limit: int = 0
    # Untergrenze bei Zahlen
    minimum: int = 0


SPECS: dict[str, Spec] = {
    # Werbung in der Play-Version: bleibt aus, bis der Admin sie nach dem Einrichten von AdMob einschaltet
    "ads_enabled": Spec(False),
    # Premium-Bereich (Code einlösen) in der App zeigen
    "premium_enabled": Spec(True),
    # „Song wünschen“ in der App anbieten
    "wishlist_enabled": Spec(True),
    # Aktuelle und mindestens nötige Build-Nummer der Play-Version (0 = nicht prüfen)
    "play_latest_build": Spec(0, 10_000_000),
    "play_min_build": Spec(0, 10_000_000),
    # Link zur Store-Seite (öffnet der „Aktualisieren“-Knopf)
    "play_store_url": Spec("", 300),
    "update_message": Spec("", 300),
    # Hinweis ganz oben in der App (z. B. „Wartung heute Abend“); leer = keiner
    "maintenance_message": Spec("", 300),
    # Offline-Hören (Laden aufs Gerät) nur mit Premium – aus, bis der Admin es einschaltet. Admins sind ausgenommen
    "offline_requires_premium": Spec(False),
    # Ältere App-Versionen kennen die Offline-Sperre nicht. Ist der Schalter an und dieser Wert größer als 0,
    # bekommen Benutzer ohne Premium mit einer älteren (oder unbekannten) Build-Nummer keine Musik mehr, bis sie
    # die App aktualisieren (0 = aus). Gilt für alle App-Ausgaben; Premium-Nutzer und Admins sind ausgenommen
    "offline_min_client_build": Spec(0, 10_000_000),
    # Gnadenfrist in Tagen: So lange bleibt Offline-Musik spielbar, wenn die App den Server nicht erreicht
    "offline_grace_days": Spec(7, 30, 1),
    # Kauf in der App (nur Play-Version, Google Play Billing). Der Preis steht in der Play Console, nicht hier
    "billing_enabled": Spec(False),
    # Produkt-IDs der Abos aus der Play Console, durch Komma getrennt
    "billing_product_ids": Spec("", 200),
    # Texte der Premium-Seite in der App (leer = Standardtext der App); Vorteile: eine Zeile je Vorteil
    "premium_headline": Spec("", 80),
    "premium_description": Spec("", 500),
    "premium_benefits": Spec("", 600),
    # Premium-Leistungen (Teil 2): je Leistung „für alle“ (False, Standard = wie bisher) oder „nur mit Premium“.
    # Höhere Tonqualität nur mit Premium – ohne Premium höchstens free_audio_quality (normal oder low)
    "hq_audio_requires_premium": Spec(False),
    "free_audio_quality": Spec("normal", 10),
    # Videos ansehen nur mit Premium (ohne Premium nur der Ton)
    "video_requires_premium": Spec(False),
    # Songtexte nur mit Premium
    "lyrics_requires_premium": Spec(False),
    # Mehr Song-Wünsche nur mit Premium: ohne Premium höchstens so viele je 7 Tage (0 = keine)
    "requests_requires_premium": Spec(False),
    "free_requests_per_week": Spec(3, 100, 0),
    # Überspringen begrenzen (nur in der App durchsetzbar): ohne Premium höchstens so oft je Stunde
    "skips_requires_premium": Spec(False),
    "free_skips_per_hour": Spec(6, 100, 1),
    # Premium-Abzeichen im Profil zeigen
    "premium_badge_enabled": Spec(False),
    # Laufzeiten des Abos: Kennungen der Basis-Abos aus der Play Console in Anzeigereihenfolge (leer = alle, die
    # der Store liefert) und die empfohlene Laufzeit (leer = keine)
    "billing_base_plans": Spec("", 400),
    "billing_recommended_plan": Spec("", 63),
}

STORE_URL_PREFIXES = ("https://play.google.com/", "market://")
PRODUCT_ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9_.]{0,39}$")
MAX_PRODUCT_IDS = 5
BASE_PLAN_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")
MAX_BASE_PLANS = 6
FREE_AUDIO_QUALITIES = ("normal", "low")
MAX_BENEFITS = 8
MAX_BENEFIT_LENGTH = 100


class ConfigError(ValueError):
    pass


def _encode(value: Any) -> str:
    if isinstance(value, bool):
        return "1" if value else "0"
    return str(value)


def _decode(key: str, raw: str) -> Any:
    default = SPECS[key].default
    if isinstance(default, bool):
        return raw == "1"
    if isinstance(default, int):
        try:
            return int(raw)
        except ValueError:
            return default
    return raw


def validate(key: str, value: Any) -> Any:
    spec = SPECS.get(key)
    if spec is None:
        raise ConfigError(f"Unbekannte Einstellung: {key}")
    default = spec.default
    if isinstance(default, bool):
        if not isinstance(value, bool):
            raise ConfigError(f"{key}: Ja/Nein erwartet.")
        return value
    if isinstance(default, int):
        if isinstance(value, bool) or not isinstance(value, int) or not spec.minimum <= value <= spec.limit:
            raise ConfigError(f"{key}: eine Zahl von {spec.minimum} bis {spec.limit} erwartet.")
        return value
    if not isinstance(value, str) or len(value.strip()) > spec.limit:
        raise ConfigError(f"{key}: Text mit höchstens {spec.limit} Zeichen erwartet.")
    value = value.strip()
    if key == "play_store_url" and value and not value.startswith(STORE_URL_PREFIXES):
        raise ConfigError("play_store_url: muss mit https://play.google.com/ oder market:// beginnen.")
    if key == "billing_product_ids":
        return _normalize_product_ids(value)
    if key == "premium_benefits":
        return _normalize_benefits(value)
    if key == "free_audio_quality" and value not in FREE_AUDIO_QUALITIES:
        raise ConfigError("free_audio_quality: „normal“ oder „low“ erwartet.")
    if key == "billing_base_plans":
        return _normalize_base_plans(value)
    return value


def _normalize_product_ids(value: str) -> str:
    """„ a , b “ -> „a,b“. Nur Schreibweisen, die die Play Console für Produkt-IDs zulässt."""
    ids = [part.strip() for part in value.split(",") if part.strip()]
    if len(ids) > MAX_PRODUCT_IDS or len(set(ids)) != len(ids) or not all(PRODUCT_ID_PATTERN.match(i) for i in ids):
        raise ConfigError(
            "billing_product_ids: Produkt-IDs bestehen aus Kleinbuchstaben, Ziffern, Punkt und Unterstrich "
            "(höchstens 5, durch Komma getrennt)."
        )
    return ",".join(ids)


def _normalize_base_plans(value: str) -> str:
    """„ monatlich , jaehrlich “ -> „monatlich,jaehrlich“. Schreibweise wie die Kennungen der Basis-Abos."""
    ids = [part.strip() for part in value.split(",") if part.strip()]
    if len(ids) > MAX_BASE_PLANS or len(set(ids)) != len(ids) or not all(BASE_PLAN_PATTERN.match(i) for i in ids):
        raise ConfigError(
            "billing_base_plans: Kennungen der Basis-Abos bestehen aus Kleinbuchstaben, Ziffern und Bindestrich "
            "(höchstens 6, durch Komma getrennt)."
        )
    return ",".join(ids)


def _normalize_benefits(value: str) -> str:
    """Eine Zeile je Vorteil; leere Zeilen fallen weg."""
    lines = [line.strip() for line in value.splitlines() if line.strip()]
    if len(lines) > MAX_BENEFITS or any(len(line) > MAX_BENEFIT_LENGTH for line in lines):
        raise ConfigError("premium_benefits: höchstens 8 Zeilen mit je 100 Zeichen.")
    return "\n".join(lines)


def product_ids(config: dict[str, Any]) -> list[str]:
    """Die eingestellten Abo-Produkt-IDs als Liste."""
    return [part for part in str(config["billing_product_ids"]).split(",") if part]


def base_plans(config: dict[str, Any]) -> list[str]:
    """Die eingestellten Laufzeiten (Kennungen der Basis-Abos) als Liste."""
    return [part for part in str(config["billing_base_plans"]).split(",") if part]


def benefits(config: dict[str, Any]) -> list[str]:
    return [line for line in str(config["premium_benefits"]).split("\n") if line]


def get_all(db: Session) -> dict[str, Any]:
    values = {key: spec.default for key, spec in SPECS.items()}
    for row in db.scalars(select(AppSetting)):
        if row.key in SPECS:
            values[row.key] = _decode(row.key, row.value)
    return values


def update(db: Session, changes: dict[str, Any]) -> dict[str, Any]:
    """Prüft alle Änderungen zuerst und schreibt erst dann – ein Fehler ändert nichts."""
    checked = {key: validate(key, value) for key, value in changes.items()}
    merged = {**get_all(db), **checked}
    # Zusammenhänge: Ein Pflicht-Update ohne Store-Link wäre für alle Nutzer eine Sackgasse (Vollbild „Update nötig“
    # ohne Knopf), und eine Mindest-Version über der neuesten gibt es noch gar nicht
    if merged["play_min_build"] > 0 and not merged["play_store_url"]:
        raise ConfigError(
            "play_store_url: Für ein Pflicht-Update (mindestens nötige Build-Nummer) fehlt der Link zur Store-Seite."
        )
    if merged["play_latest_build"] > 0 and merged["play_min_build"] > merged["play_latest_build"]:
        raise ConfigError("play_min_build: darf nicht größer sein als die neueste Build-Nummer.")
    # Ein Kauf-Knopf ohne Produkt wäre in der App eine Sackgasse
    if merged["billing_enabled"] and not merged["billing_product_ids"]:
        raise ConfigError("billing_product_ids: Für den Kauf in der App fehlt die Produkt-ID des Abos.")
    if merged["billing_recommended_plan"] and merged["billing_recommended_plan"] not in base_plans(merged):
        raise ConfigError("billing_recommended_plan: Die empfohlene Laufzeit muss in der Liste der Laufzeiten stehen.")
    for key, value in checked.items():
        row = db.get(AppSetting, key)
        if row is None:
            db.add(AppSetting(key=key, value=_encode(value), updated_at=utcnow()))
        else:
            row.value = _encode(value)
    db.flush()
    return get_all(db)


def update_level(config: dict[str, Any], channel: str, build: int | None) -> str:
    """none | available | required – nur für die Play-Version; die GitHub-Version prüft selbst."""
    if channel != "play" or build is None:
        return "none"
    if config["play_min_build"] and build < config["play_min_build"]:
        return "required"
    if config["play_latest_build"] and build < config["play_latest_build"]:
        return "available"
    return "none"


MSG_UPDATE_REQUIRED = "Bitte aktualisiere die App."


def client_too_old(config: dict[str, Any], build: int | None) -> bool:
    """Offline-Sperre an und die App ist älter als die eingestellte Mindest-Build-Nummer (oder nennt keine)?
    Ob der Benutzer ausgenommen ist (Admin, Premium), prüft der Aufrufer."""
    minimum = config["offline_min_client_build"]
    return bool(config["offline_requires_premium"]) and minimum > 0 and (build is None or build < minimum)
