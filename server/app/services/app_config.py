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
}

STORE_URL_PREFIXES = ("https://play.google.com/", "market://")
PRODUCT_ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9_.]{0,39}$")
MAX_PRODUCT_IDS = 5
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


def _normalize_benefits(value: str) -> str:
    """Eine Zeile je Vorteil; leere Zeilen fallen weg."""
    lines = [line.strip() for line in value.splitlines() if line.strip()]
    if len(lines) > MAX_BENEFITS or any(len(line) > MAX_BENEFIT_LENGTH for line in lines):
        raise ConfigError("premium_benefits: höchstens 8 Zeilen mit je 100 Zeichen.")
    return "\n".join(lines)


def product_ids(config: dict[str, Any]) -> list[str]:
    """Die eingestellten Abo-Produkt-IDs als Liste."""
    return [part for part in str(config["billing_product_ids"]).split(",") if part]


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
