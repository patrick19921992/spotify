"""Premium-Leistungen: was ein Premium freischaltet und was der Betreiber nur Premium-Nutzern erlaubt.

- Jede Lizenz hat einen Umfang (`features`, kommagetrennt). NULL = alle Leistungen – so sind alle bestehenden
  Lizenzen, Admin-Vergaben und Abos über Google Play („ein Abo schaltet immer alle frei“).
- Der Betreiber stellt im Dashboard je Leistung ein, ob sie „für alle“ oder „nur mit Premium“ gilt (Schalter in
  app_config). Standard: alles für alle – so wie vor Teil 2. Werbefreiheit ist immer ein Premium-Vorteil, das
  Abzeichen ein eigener Ein/Aus-Schalter.
- Admins sind nie eingeschränkt.
"""

from collections.abc import Iterable
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

from sqlalchemy.orm import Session

from app.models import User

# Feste Reihenfolge – überall (JSON, Speicherung, Dashboard) in genau dieser Reihenfolge
FEATURES: tuple[str, ...] = ("offline", "no_ads", "hq_audio", "video", "lyrics", "requests", "skips", "badge")
ALL: frozenset[str] = frozenset(FEATURES)

LABELS = {
    "offline": "Offline-Hören",
    "no_ads": "Keine Werbung",
    "hq_audio": "Höhere Tonqualität",
    "video": "Videos ansehen",
    "lyrics": "Songtexte",
    "requests": "Mehr Song-Wünsche",
    "skips": "Unbegrenzt überspringen",
    "badge": "Premium-Abzeichen",
}

# Schaltbare Leistungen -> Schlüssel in app_config (True = „nur Premium“)
SWITCHES = {
    "offline": "offline_requires_premium",  # bestehender Schalter, Verhalten unverändert
    "hq_audio": "hq_audio_requires_premium",
    "video": "video_requires_premium",
    "lyrics": "lyrics_requires_premium",
    "requests": "requests_requires_premium",
    "skips": "skips_requires_premium",
}

MSG_VIDEO = "Videos ansehen gibt es nur mit Premium. Als Ton kannst du sie weiter abspielen."
MSG_LYRICS = "Songtexte gibt es nur mit Premium."
MSG_REQUESTS_NONE = "Song-Wünsche gibt es nur mit Premium."
MSG_REQUESTS_WEEK = "Du hast diese Woche schon {limit} Wünsche geschickt. Mit Premium kannst du unbegrenzt wünschen."
MSG_REQUESTS_WEEK_ONE = "Du hast diese Woche schon 1 Wunsch geschickt. Mit Premium kannst du unbegrenzt wünschen."
MSG_HQ_NEEDS_FFMPEG = (
    "hq_audio_requires_premium: Dafür muss ffmpeg auf dem Server installiert sein (Umwandlung in niedrigere Qualität)."
)

# Rangfolge der Stream-Qualitäten (höher = besser)
QUALITY_RANK = {"low": 0, "normal": 1, "high": 2, "original": 3}


def requests_week_message(limit: int) -> str:
    return MSG_REQUESTS_WEEK_ONE if limit == 1 else MSG_REQUESTS_WEEK.format(limit=limit)


def ordered(features: Iterable[str]) -> list[str]:
    """In FEATURES-Reihenfolge, ohne Doppelte und ohne unbekannte Schlüssel."""
    wanted = set(features)
    return [key for key in FEATURES if key in wanted]


def encode(features: Iterable[str] | None) -> str | None:
    """None oder alle 8 -> None (= alle). Sonst kommagetrennt in FEATURES-Reihenfolge, ohne Doppelte.
    Leere Menge -> ValueError (eine Lizenz/ein Code schaltet mindestens eine Leistung frei)."""
    if features is None:
        return None
    items = list(features)
    unknown = [key for key in items if key not in ALL]
    if unknown:
        raise ValueError(f"Unbekannte Leistung: {unknown[0]}")
    keys = ordered(items)
    if not keys:
        raise ValueError("Bitte mindestens eine Leistung wählen.")
    if len(keys) == len(FEATURES):
        return None
    return ",".join(keys)


def decode(raw: str | None) -> frozenset[str]:
    """None -> ALL. Unbekannte Schlüssel fallen weg (vorwärtskompatibel)."""
    if raw is None:
        return ALL
    return frozenset(part for part in raw.split(",") if part in ALL)


def as_list(raw: str | None) -> list[str] | None:
    """Für Antworten: None = alle, sonst die Liste in FEATURES-Reihenfolge."""
    if raw is None:
        return None
    return ordered(decode(raw))


def premium_only(config: dict[str, Any]) -> list[str]:
    """Schaltbare Leistungen, die auf „nur Premium“ stehen, in FEATURES-Reihenfolge (ohne no_ads und badge)."""
    return [key for key in FEATURES if key in SWITCHES and bool(config.get(SWITCHES[key]))]


@dataclass(frozen=True)
class Access:
    is_admin: bool
    # was das Premium des Benutzers freischaltet (leer ohne Premium)
    features: frozenset[str]
    premium_only: tuple[str, ...]

    def allows(self, key: str) -> bool:
        """Admin, nicht „nur Premium“, oder im Umfang des laufenden Premiums."""
        return self.is_admin or key not in self.premium_only or key in self.features

    @property
    def locked(self) -> list[str]:
        """Was dieser Benutzer gerade nicht darf ([] für Admins)."""
        if self.is_admin:
            return []
        return [key for key in self.premium_only if key not in self.features]


def access_for(db: Session, user: User, config: dict[str, Any], now: datetime | None = None) -> Access:
    """Fragt die Lizenzen nur ab, wenn premium_only nicht leer ist und der Benutzer kein Admin ist
    (Schalter aus = keine zusätzliche Datenbankabfrage, Verhalten wie bisher)."""
    only = tuple(premium_only(config))
    if not only or user.is_admin:
        return Access(is_admin=user.is_admin, features=frozenset(), premium_only=only)
    # erst hier importieren: premium.py importiert dieses Modul
    from app.services import play_billing
    from app.services.premium import premium_status

    moment = now or datetime.now(UTC)
    features = premium_status(db, user, moment).features
    # Abo-Zeitraum gerade um, die Verlängerung aber noch nicht nachgeprüft (die App hat /premium noch nicht neu
    # gefragt): wie bei der 426-Regel nicht sperren – ein Abo schaltet ohnehin alles frei.
    if not features >= ALL and play_billing.premium_unsettled(db, user.id, moment):
        features = ALL
    return Access(is_admin=False, features=features, premium_only=only)


def clamp_quality(quality: str, cap: str) -> str:
    """Rangfolge original > high > normal > low. Liegt quality über cap, wird cap zurückgegeben."""
    if QUALITY_RANK.get(quality, QUALITY_RANK["original"]) > QUALITY_RANK.get(cap, QUALITY_RANK["normal"]):
        return cap
    return quality
