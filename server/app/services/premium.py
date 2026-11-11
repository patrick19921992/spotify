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

from sqlalchemy import ColumnElement, or_, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.models import PlayPurchase, PremiumCode, PremiumLicense, User, utcnow

# Ohne leicht verwechselbare Zeichen (0/O, 1/I/L)
CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
CODE_LENGTH = 12
MAX_DURATION_DAYS = 3650
# So weit darf die Kette aus angehängten Lizenzen höchstens in die Zukunft reichen
MAX_CHAIN_DAYS = 3650
# Google nimmt einen Kauf-Token bis 60 Tage nach dem Ablauf an – so lange kann ein Kauf wieder aufleben
PLAY_TOKEN_LIFETIME_AFTER_EXPIRY = timedelta(days=60)


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


def _not_expired(now: datetime) -> ColumnElement[bool]:
    """SQL-Bedingung: unbegrenzt oder noch nicht abgelaufen."""
    return or_(PremiumLicense.expires_at.is_(None), PremiumLicense.expires_at > now)


def _revivable_purchase(now: datetime) -> ColumnElement[bool]:
    """SQL-Bedingung: An der Lizenz hängt ein Kauf über Google Play, der sie wieder verlängern könnte.

    Eine solche Lizenz ist regelmäßig kurz „abgelaufen“, obwohl der Kauf weiterläuft (Zeitraum um und die App war
    noch nicht wieder offen, Zahlung hängt). Der Entzug muss sie trotzdem treffen – sonst käme Premium bei der
    nächsten Prüfung von selbst zurück."""
    return (
        select(PlayPurchase.id)
        .where(
            PlayPurchase.license_id == PremiumLicense.id,
            PlayPurchase.state != "replaced",
            or_(
                PlayPurchase.expires_at.is_(None),
                PlayPurchase.expires_at > now - PLAY_TOKEN_LIFETIME_AFTER_EXPIRY,
            ),
        )
        .exists()
    )


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
    """Zeitlich begrenztes Premium hängt sich hinten an die Kette an: nach der laufenden **und** nach schon
    angehängten (noch nicht begonnenen) befristeten Lizenzen."""
    latest = [lic.expires_at for lic in live_licenses(db, user_id, now) if lic.expires_at is not None]
    return max([now, *latest])


def _expiry(start: datetime, days: int | None, now: datetime) -> datetime | None:
    """Ende einer befristeten Lizenz. Die ganze Kette darf höchstens MAX_CHAIN_DAYS ab jetzt reichen."""
    if days is None:
        return None
    end = start + timedelta(days=days)
    if end > now + timedelta(days=MAX_CHAIN_DAYS):
        raise PremiumError(409, "Die gesamte Premium-Laufzeit darf zehn Jahre nicht überschreiten.")
    return end


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

    start = _start_for_new_license(db, user.id, now) if code.duration_days is not None else now
    license_ = PremiumLicense(
        user_id=user.id,
        code_id=code.id,
        source="code",
        starts_at=start,
        expires_at=_expiry(start, code.duration_days, now),
        note=code.label,
    )
    # Erst die Lizenz anlegen: Die Datenbank erlaubt je Code und Benutzer nur eine – eine gleichzeitige zweite
    # Einlösung desselben Benutzers scheitert hier, ohne einen Platz des Codes zu verbrauchen
    db.add(license_)
    try:
        db.flush()
    except IntegrityError:
        db.rollback()
        raise PremiumError(409, "Du hast diesen Code schon eingelöst.") from None
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
        db.rollback()  # die eben angelegte Lizenz wieder verwerfen
        raise PremiumError(409, "Dieser Code wurde schon so oft eingelöst, wie es erlaubt ist.")
    db.refresh(code)
    return license_


def grant(db: Session, user: User, *, days: int | None, note: str, now: datetime | None = None) -> PremiumLicense:
    """Premium direkt vergeben (ohne Code). days=None = unbegrenzt."""
    now = now or utcnow()
    start = _start_for_new_license(db, user.id, now) if days is not None else now
    license_ = PremiumLicense(
        user_id=user.id, source="admin", starts_at=start, expires_at=_expiry(start, days, now), note=note
    )
    db.add(license_)
    db.flush()
    return license_


def close_gaps(db: Session, user_id: int, now: datetime | None = None) -> None:
    """Zieht angehängte (noch nicht begonnene) befristete Lizenzen vor, wenn vor ihnen eine Lücke entstanden ist.

    Gebraucht, wenn ein Abo über Google Play vor dem Ende des bezahlten Zeitraums endet (Erstattung): Ein dahinter
    gehängter Code begänne sonst erst am ursprünglichen Abo-Ende – bis dahin gäbe es trotz gültiger Lizenz kein
    Premium. Die Laufzeit jeder Lizenz bleibt gleich, es wird nur früher begonnen."""
    now = now or utcnow()
    db.flush()
    licenses = live_licenses(db, user_id, now)
    if any(lic.expires_at is None and lic.starts_at <= now for lic in licenses):
        return  # unbegrenzt: Es gibt keine Lücke
    covered_until = now
    for lic in sorted((lic for lic in licenses if lic.expires_at is not None), key=lambda lic: (lic.starts_at, lic.id)):
        assert lic.expires_at is not None
        if lic.starts_at > covered_until:
            lic.expires_at -= lic.starts_at - covered_until
            lic.starts_at = covered_until
        covered_until = max(covered_until, lic.expires_at)


def revoke_license(db: Session, license_: PremiumLicense, now: datetime | None = None) -> bool:
    """Entzieht eine Lizenz. False, wenn sie schon entzogen oder von selbst abgelaufen war (die Historie bleibt).

    Ausnahme: Eine Lizenz aus einem Kauf über Google Play wird auch dann entzogen, wenn sie gerade abgelaufen ist –
    solange der Kauf sie wieder verlängern könnte."""
    now = now or utcnow()
    if license_.revoked_at is not None:
        return False
    if not _not_over(license_, now):
        revivable = select(PremiumLicense.id).where(PremiumLicense.id == license_.id, _revivable_purchase(now))
        if db.scalar(revivable) is None:
            return False
    license_.revoked_at = now
    return True


def revoke_user(db: Session, user_id: int, now: datetime | None = None) -> int:
    """Entzieht alle Lizenzen eines Benutzers (auch noch nicht begonnene). Gibt die Anzahl zurück.

    Dazu gehören abgelaufene Lizenzen aus Käufen über Google Play, die der Kauf wieder verlängern könnte."""
    now = now or utcnow()
    result = db.execute(
        update(PremiumLicense)
        .where(
            PremiumLicense.user_id == user_id,
            PremiumLicense.revoked_at.is_(None),
            or_(_not_expired(now), _revivable_purchase(now)),
        )
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
        .where(PremiumLicense.code_id == code.id, PremiumLicense.revoked_at.is_(None), _not_expired(now))
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
