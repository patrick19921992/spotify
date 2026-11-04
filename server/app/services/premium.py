"""Premium: Codes erzeugen und einlösen, Lizenzen vergeben und entziehen.

Regeln:
- Ein Code hat eine Laufzeit in Tagen (ab dem Einlösen) oder ist unbegrenzt, darf einmal oder mehrfach eingelöst
  werden (jeder Benutzer höchstens einmal) und kann zusätzlich eine „einlösbar bis“-Frist haben.
- Eine Lizenz gilt, solange sie nicht entzogen und nicht abgelaufen ist. Hat jemand mehrere, zählt die längste:
  zeitlich begrenzte Lizenzen werden aneinandergehängt (ein neuer Code verlängert), eine unbegrenzte gilt immer.
- Entzogen wird entweder ein ganzer Code (keine weiteren Einlösungen, auf Wunsch auch alle daraus entstandenen
  Lizenzen) oder das Premium eines einzelnen Benutzers.
"""

import re
import secrets
from dataclasses import dataclass
from datetime import datetime, timedelta

from sqlalchemy import select, update
from sqlalchemy.orm import Session

from app.models import PremiumCode, PremiumLicense, User, utcnow

# Ohne leicht verwechselbare Zeichen (0/O, 1/I/L)
CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
CODE_LENGTH = 12
MAX_DURATION_DAYS = 3650


class PremiumError(Exception):
    """Fehler mit passender HTTP-Antwort für die Endpunkte."""

    def __init__(self, status_code: int, message: str) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.message = message


@dataclass
class PremiumStatus:
    active: bool
    unlimited: bool
    until: datetime | None


def normalize_code(raw: str) -> str:
    """„abcd-efgh ijkl“ -> „ABCDEFGHIJKL“ (Groß-/Kleinschreibung, Bindestriche und Leerzeichen sind egal)."""
    return re.sub(r"[^A-Za-z0-9]", "", raw).upper()


def format_code(code: str) -> str:
    return "-".join(code[i : i + 4] for i in range(0, len(code), 4))


def generate_code() -> str:
    return "".join(secrets.choice(CODE_ALPHABET) for _ in range(CODE_LENGTH))


def _not_over(license_: PremiumLicense, now: datetime) -> bool:
    """Nicht entzogen und noch nicht abgelaufen (kann aber erst später beginnen, wenn sie angehängt wurde)."""
    return license_.revoked_at is None and (license_.expires_at is None or license_.expires_at > now)


def _is_running(license_: PremiumLicense, now: datetime) -> bool:
    return _not_over(license_, now) and license_.starts_at <= now


def live_licenses(db: Session, user_id: int, now: datetime | None = None) -> list[PremiumLicense]:
    """Laufende und angehängte (noch nicht begonnene) Lizenzen."""
    now = now or utcnow()
    licenses = db.scalars(
        select(PremiumLicense).where(PremiumLicense.user_id == user_id, PremiumLicense.revoked_at.is_(None))
    ).unique()
    return [lic for lic in licenses if _not_over(lic, now)]


def running_licenses(db: Session, user_id: int, now: datetime | None = None) -> list[PremiumLicense]:
    now = now or utcnow()
    return [lic for lic in live_licenses(db, user_id, now) if _is_running(lic, now)]


def status_of(licenses: list[PremiumLicense], now: datetime) -> PremiumStatus:
    """Premium gilt, solange eine Lizenz läuft. „Bis“ zählt auch angehängte Lizenzen mit (Stapeln)."""
    if not any(_is_running(lic, now) for lic in licenses):
        return PremiumStatus(active=False, unlimited=False, until=None)
    if any(lic.expires_at is None and _is_running(lic, now) for lic in licenses):
        return PremiumStatus(active=True, unlimited=True, until=None)
    return PremiumStatus(active=True, unlimited=False, until=max(lic.expires_at for lic in licenses if lic.expires_at))


def premium_status(db: Session, user: User, now: datetime | None = None) -> PremiumStatus:
    now = now or utcnow()
    return status_of(live_licenses(db, user.id, now), now)


def premium_statuses(db: Session, user_ids: list[int], now: datetime | None = None) -> dict[int, PremiumStatus]:
    """Für Listen (Dashboard): ein Abruf statt einer je Benutzer."""
    now = now or utcnow()
    per_user: dict[int, list[PremiumLicense]] = {uid: [] for uid in user_ids}
    if user_ids:
        rows = db.scalars(
            select(PremiumLicense).where(PremiumLicense.user_id.in_(user_ids), PremiumLicense.revoked_at.is_(None))
        ).unique()
        for lic in rows:
            if _not_over(lic, now):
                per_user[lic.user_id].append(lic)
    return {uid: status_of(items, now) for uid, items in per_user.items()}


def _start_for_new_license(db: Session, user_id: int, now: datetime) -> datetime:
    """Zeitlich begrenztes Premium hängt sich hinten an eine laufende begrenzte Lizenz an."""
    latest = [lic.expires_at for lic in running_licenses(db, user_id, now) if lic.expires_at is not None]
    return max([now, *latest])


def _expiry(start: datetime, days: int | None) -> datetime | None:
    return None if days is None else start + timedelta(days=days)


def create_codes(
    db: Session,
    *,
    count: int,
    duration_days: int | None,
    max_redemptions: int,
    valid_until: datetime | None,
    label: str,
    created_by: User | None,
) -> list[PremiumCode]:
    codes: list[PremiumCode] = []
    taken = set(db.scalars(select(PremiumCode.code)))
    while len(codes) < count:
        value = generate_code()
        if value in taken:
            continue
        taken.add(value)
        code = PremiumCode(
            code=value,
            label=label,
            duration_days=duration_days,
            max_redemptions=max_redemptions,
            valid_until=valid_until,
            created_by_id=created_by.id if created_by else None,
        )
        db.add(code)
        codes.append(code)
    db.flush()
    return codes


def redeem(db: Session, user: User, raw_code: str, now: datetime | None = None) -> PremiumLicense:
    """Löst einen Code ein. Wirft PremiumError mit verständlicher Meldung."""
    now = now or utcnow()
    normalized = normalize_code(raw_code)
    code = db.scalar(select(PremiumCode).where(PremiumCode.code == normalized)) if normalized else None
    if code is None:
        raise PremiumError(404, "Diesen Code gibt es nicht. Bitte prüfe die Schreibweise.")
    if code.revoked_at is not None:
        raise PremiumError(410, "Dieser Code ist nicht mehr gültig.")
    if code.valid_until is not None and code.valid_until <= now:
        raise PremiumError(410, "Dieser Code ist abgelaufen.")
    if code.redeemed_count >= code.max_redemptions:
        raise PremiumError(409, "Dieser Code wurde schon so oft eingelöst, wie es erlaubt ist.")
    already = db.scalar(
        select(PremiumLicense.id).where(PremiumLicense.code_id == code.id, PremiumLicense.user_id == user.id)
    )
    if already is not None:
        raise PremiumError(409, "Du hast diesen Code schon eingelöst.")
    current = running_licenses(db, user.id, now)
    if code.duration_days is not None and any(lic.expires_at is None for lic in current):
        raise PremiumError(409, "Du hast schon unbegrenzt Premium – der Code bleibt unverbraucht.")

    # Zähler atomar erhöhen: Zwei gleichzeitige Einlösungen dürfen einen Einmal-Code nicht beide bekommen
    claimed = db.execute(
        update(PremiumCode)
        .where(
            PremiumCode.id == code.id,
            PremiumCode.revoked_at.is_(None),
            PremiumCode.redeemed_count < PremiumCode.max_redemptions,
        )
        .values(redeemed_count=PremiumCode.redeemed_count + 1)
    )
    if claimed.rowcount != 1:
        raise PremiumError(409, "Dieser Code wurde schon so oft eingelöst, wie es erlaubt ist.")
    db.refresh(code)

    start = _start_for_new_license(db, user.id, now) if code.duration_days is not None else now
    license_ = PremiumLicense(
        user_id=user.id,
        code_id=code.id,
        source="code",
        starts_at=start,
        expires_at=_expiry(start, code.duration_days),
        note=code.label,
    )
    db.add(license_)
    db.flush()
    return license_


def grant(db: Session, user: User, *, days: int | None, note: str, now: datetime | None = None) -> PremiumLicense:
    """Premium direkt vergeben (ohne Code). days=None = unbegrenzt."""
    now = now or utcnow()
    start = _start_for_new_license(db, user.id, now) if days is not None else now
    license_ = PremiumLicense(
        user_id=user.id, source="admin", starts_at=start, expires_at=_expiry(start, days), note=note
    )
    db.add(license_)
    db.flush()
    return license_


def revoke_license(db: Session, license_: PremiumLicense, now: datetime | None = None) -> bool:
    if license_.revoked_at is not None:
        return False
    license_.revoked_at = now or utcnow()
    return True


def revoke_user(db: Session, user_id: int, now: datetime | None = None) -> int:
    """Entzieht alle Lizenzen eines Benutzers (auch noch nicht begonnene). Gibt die Anzahl zurück."""
    now = now or utcnow()
    result = db.execute(
        update(PremiumLicense)
        .where(PremiumLicense.user_id == user_id, PremiumLicense.revoked_at.is_(None))
        .values(revoked_at=now)
    )
    return int(result.rowcount or 0)


def revoke_code(db: Session, code: PremiumCode, *, revoke_licenses: bool, now: datetime | None = None) -> int:
    """Sperrt den Code. Mit revoke_licenses werden auch alle daraus entstandenen Lizenzen entzogen."""
    now = now or utcnow()
    if code.revoked_at is None:
        code.revoked_at = now
    if not revoke_licenses:
        return 0
    result = db.execute(
        update(PremiumLicense)
        .where(PremiumLicense.code_id == code.id, PremiumLicense.revoked_at.is_(None))
        .values(revoked_at=now)
    )
    return int(result.rowcount or 0)


def code_state(code: PremiumCode, now: datetime | None = None) -> str:
    """revoked | expired | used_up | available"""
    now = now or utcnow()
    if code.revoked_at is not None:
        return "revoked"
    if code.valid_until is not None and code.valid_until <= now:
        return "expired"
    if code.redeemed_count >= code.max_redemptions:
        return "used_up"
    return "available"
