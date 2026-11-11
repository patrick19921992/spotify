"""Kauf über Google Play: Käufe prüfen, einem Konto zuordnen und laufend nachsehen, ob noch bezahlt wird.

Regeln:
- Die App schickt nach dem Kauf den Kauf-Token. Der Server fragt Google (Play Developer API, `subscriptionsv2`),
  ob der Kauf echt ist – dem Gerät wird nichts geglaubt.
- Ein Kauf-Token gehört genau einem Konto (Hash des Tokens ist in der Datenbank eindeutig).
- Jeder Kauf steuert eine Lizenz (`source="play"`): Solange Google Zugang meldet, läuft sie bis zum Ablauf des
  Abos; bei Kündigung zum Laufzeitende, Erstattung, Zahlungsausfall oder Ablauf endet sie.
- Ohne Echtzeit-Benachrichtigungen von Google: Laufende Käufe werden bei der Premium-Abfrage der App erneut
  geprüft (gedrosselt). Ist Google gerade nicht erreichbar, wird nichts beendet – der Stand gilt als „unbekannt“.
- Der Schlüssel des Dienstkontos liegt nur als Datei auf dem Server. Weder sein Inhalt noch ein Kauf-Token
  erscheinen in Protokollen, Fehlermeldungen oder Antworten.

Die Verbindung zu Google steckt hinter `PurchaseVerifier`, damit Tests eine Attrappe einsetzen können.
"""

import hashlib
import json
import logging
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any, Protocol

import jwt
from sqlalchemy import select
from sqlalchemy.orm import Session, object_session

from app.config import Settings
from app.locks import write_lock
from app.models import PlayPurchase, PremiumLicense, User
from app.services.features import ALL as ALL_FEATURES
from app.services.premium import (
    PLAY_TOKEN_LIFETIME_AFTER_EXPIRY,
    PremiumError,
    close_gaps,
    live_licenses,
    status_of,
)

logger = logging.getLogger("app.billing")

SCOPE = "https://www.googleapis.com/auth/androidpublisher"
API_BASE = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications"

# Zustände, in denen Google Zugang gewährt (zusätzlich muss expires_at in der Zukunft liegen)
ENTITLED = {"active", "canceled", "grace"}
# Zustände, die sich noch ändern können und deshalb nachgeprüft werden
OPEN_STATES = ("active", "canceled", "grace", "on_hold", "paused", "pending")
GOOGLE_STATES = {
    "SUBSCRIPTION_STATE_ACTIVE": "active",
    "SUBSCRIPTION_STATE_CANCELED": "canceled",
    "SUBSCRIPTION_STATE_IN_GRACE_PERIOD": "grace",
    "SUBSCRIPTION_STATE_ON_HOLD": "on_hold",
    "SUBSCRIPTION_STATE_PAUSED": "paused",
    "SUBSCRIPTION_STATE_PENDING": "pending",
}
# Google nimmt einen Kauf-Token bis 60 Tage nach dem Ablauf an – danach lohnt keine Abfrage mehr
TOKEN_LIFETIME_AFTER_EXPIRY = PLAY_TOKEN_LIFETIME_AFTER_EXPIRY
# Rund um die Verlängerung zügig nachsehen
RENEWAL_WINDOW = timedelta(hours=1)
RENEWAL_RECHECK = timedelta(minutes=5)
# Zeitraum um, Google meldet das Abo aber noch als laufend (die Verlängerung ist noch nicht verbucht): So lange gilt
# der Stand als „unbekannt“ statt „kein Premium“ – und es wird höchstens so oft nachgefragt
RENEWAL_TOLERANCE = timedelta(hours=1)
OVERDUE_RECHECK = timedelta(minutes=1)
# Zustände, in denen Google von sich aus verlängert bzw. das Ende verschiebt
RENEWING_STATES = ("active", "grace")
# Google antwortet bei der erneuten Prüfung mit 400/404: Das kann ein toter Token sein – oder ein falsch
# eingestellter Paketname. So lange über das bezahlte Ende hinaus gilt der Stand als „unbekannt“, erst dann als beendet
NOT_FOUND_TOLERANCE = timedelta(days=3)
# Unbestätigte Käufe erstattet Google nach drei Tagen – das Bestätigen deshalb bald erneut versuchen
UNACKNOWLEDGED_RECHECK = timedelta(minutes=10)
# Nach einer Störung (Google nicht erreichbar, Schlüssel abgelehnt) frühestens dann wieder anfragen: Sonst hinge
# jede Premium-Abfrage der App am Zeitlimit der Verbindung zu Google
FAILURE_BACKOFF = timedelta(minutes=5)

MSG_NOT_CONFIGURED = "Die Kaufprüfung ist auf dem Server nicht eingerichtet."
MSG_UNAVAILABLE = (
    "Google Play ist gerade nicht erreichbar. Dein Kauf geht nicht verloren – bitte später „Käufe wiederherstellen“ "
    "antippen."
)
MSG_STATUS_UNKNOWN = "Dein Premium-Stand kann gerade nicht geprüft werden. Bitte später noch einmal versuchen."
MSG_UNKNOWN_PRODUCT = "Dieses Produkt gibt es hier nicht."
MSG_OTHER_ACCOUNT = "Dieser Kauf ist schon mit einem anderen Konto verbunden."
MSG_BLOCKED = "Dieser Kauf wurde vom Betreiber gesperrt."
MSG_NOT_FOUND = "Dieser Kauf wurde bei Google Play nicht gefunden."
MSG_KEY_INVALID = "Schlüsseldatei ist ungültig."
MSG_UNREACHABLE = "Google ist nicht erreichbar."
# Steht bei einem Kauf, den Google bei der erneuten Prüfung nicht (mehr) kannte – er wird weiter nachgeprüft.
# Bei einem deswegen beendeten Kauf ist der Text zugleich das Merkmal dafür (siehe _suspect): Er bleibt vorn stehen,
# auch wenn eine spätere Nachprüfung an einer Störung scheitert – deren Meldung wird nur angehängt
MSG_NOT_FOUND_ON_RECHECK = (
    "Google kennt diesen Kauf nicht (Antwort 400/404). Stimmt der Paketname (PLAY_PACKAGE_NAME) und gehört das "
    "Dienstkonto zu dieser App?"
)
MSG_LAST_RECHECK = " Letzte Nachprüfung: "
MSG_ACKNOWLEDGE_FAILED = (
    "Der Kauf konnte bei Google noch nicht bestätigt werden – es wird erneut versucht (unbestätigte Käufe erstattet "
    "Google nach drei Tagen)."
)
MSG_ACKNOWLEDGE_NOT_FOUND = "Google kennt diesen Kauf nicht (400/404/410)."


@dataclass(frozen=True)
class SubscriptionInfo:
    """Was Google über einen Abo-Kauf sagt – schon in unsere Begriffe übersetzt."""

    state: str  # wie PlayPurchase.state (ohne "replaced")
    product_ids: tuple[str, ...]
    expires_at: datetime | None  # spätestes Ablaufdatum aller Posten (UTC)
    auto_renewing: bool
    acknowledged: bool
    order_id: str
    obfuscated_account_id: str  # "" wenn nicht gesetzt
    linked_purchase_token: str  # "" wenn nicht gesetzt
    is_test: bool
    # Laufzeit: Kennung des Basis-Abos und des Angebots laut Google ("" = unbekannt bzw. keins)
    base_plan_id: str = ""
    offer_id: str = ""


class PurchaseNotFound(Exception):
    """Google kennt den Token nicht (unbekannt, ungültig oder zu alt).

    `definite=False`: Die Antwort (400/404) kann auch von einer falschen Einstellung kommen (Paketname passt nicht
    zum Token). Für einen neu gemeldeten Kauf heißt beides „nicht gefunden“; ein bereits bekannter Kauf darf
    deswegen aber nicht sofort enden."""

    def __init__(self, *, definite: bool = True) -> None:
        super().__init__()
        self.definite = definite


class VerifierUnavailable(Exception):
    """Gerade keine Auskunft möglich: Netz, Zeitlimit, Störung bei Google, Schlüssel/Rechte, kaputte Antwort.

    Der Text ist für den Admin gedacht (Dashboard) und enthält nie Geheimnisse."""


class UnclearNotFound(VerifierUnavailable):
    """Google kennt einen bereits bekannten Kauf nicht (400/404) – toter Token oder falsche Einstellung
    (Paketname)? Für den Benutzer wie eine Störung („unbekannt“); der Admin bekommt den Hinweis im Text."""


class PurchaseVerifier(Protocol):
    def get_subscription(self, purchase_token: str) -> SubscriptionInfo: ...

    def acknowledge(self, product_id: str, purchase_token: str) -> None: ...

    def check_access(self) -> None: ...


# ------------------------------------------------------------------------------------------------ Google


def _parse_time(value: object) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError:
        return None
    return parsed.replace(tzinfo=UTC) if parsed.tzinfo is None else parsed.astimezone(UTC)


def parse_subscription(data: object) -> SubscriptionInfo:
    """Übersetzt die Antwort von `purchases.subscriptionsv2.get`. Unbekannte Zustände gelten als „kein Zugang“."""
    if not isinstance(data, dict):
        raise VerifierUnavailable("Google hat eine unverständliche Antwort geschickt.")
    items = [item for item in data.get("lineItems") or [] if isinstance(item, dict)]
    expiries = [t for t in (_parse_time(item.get("expiryTime")) for item in items) if t is not None]
    plans = [item.get("autoRenewingPlan") for item in items]
    external = data.get("externalAccountIdentifiers")
    # Laufzeit aus dem Posten mit dem spätesten Ablauf (ohne Ablauf: dem ersten)
    current = _latest_item(items)
    offer = current.get("offerDetails")
    offer = offer if isinstance(offer, dict) else {}
    return SubscriptionInfo(
        state=GOOGLE_STATES.get(str(data.get("subscriptionState", "")), "expired"),
        product_ids=tuple(str(item["productId"]) for item in items if item.get("productId")),
        expires_at=max(expiries) if expiries else None,
        auto_renewing=any(isinstance(plan, dict) and plan.get("autoRenewEnabled") is True for plan in plans),
        acknowledged=data.get("acknowledgementState") == "ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED",
        order_id=str(data.get("latestOrderId") or "")[:100],
        obfuscated_account_id=str(
            (external.get("obfuscatedExternalAccountId") if isinstance(external, dict) else "") or ""
        ),
        linked_purchase_token=str(data.get("linkedPurchaseToken") or ""),
        is_test="testPurchase" in data,
        base_plan_id=_text(offer.get("basePlanId"))[:64],
        offer_id=_text(offer.get("offerId"))[:64],
    )


def _latest_item(items: list[dict[str, Any]]) -> dict[str, Any]:
    """Der Posten mit dem spätesten Ablauf; hat keiner einen, der erste (keiner: leer)."""
    dated = [(t, item) for item in items if (t := _parse_time(item.get("expiryTime"))) is not None]
    if dated:
        return max(dated, key=lambda pair: pair[0])[1]
    return items[0] if items else {}


def _text(value: object) -> str:
    return value if isinstance(value, str) else ""


def load_service_account(key_file: Path) -> dict[str, str]:
    """Liest den Dienstkonto-Schlüssel. Fehlermeldungen nennen nie den Inhalt der Datei."""
    try:
        raw = key_file.read_text(encoding="utf-8")
    except OSError:
        raise VerifierUnavailable(f"Schlüsseldatei fehlt: {key_file}") from None
    try:
        data = json.loads(raw)
    except ValueError:
        raise VerifierUnavailable(MSG_KEY_INVALID) from None
    if not isinstance(data, dict):
        raise VerifierUnavailable(MSG_KEY_INVALID)
    values = {key: data.get(key) for key in ("client_email", "private_key", "token_uri")}
    if not all(isinstance(value, str) and value for value in values.values()):
        raise VerifierUnavailable(MSG_KEY_INVALID)
    # Der Schlüssel wird nur verschlüsselt verschickt – und nicht an eine Datei- oder sonstige Adresse
    if not str(values["token_uri"]).startswith("https://"):
        raise VerifierUnavailable(MSG_KEY_INVALID)
    return {key: str(value) for key, value in values.items()}


class GooglePlayVerifier:
    """Fragt die Google Play Developer API mit einem Dienstkonto."""

    def __init__(
        self,
        package_name: str,
        key_file: Path,
        *,
        opener: Callable[..., Any] = urllib.request.urlopen,
        timeout: float = 10,
    ) -> None:
        self._package = package_name
        self._key_file = key_file
        self._opener = opener
        self._timeout = timeout
        # Zugriffstoken von Google (im Speicher, bis kurz vor Ablauf); Endpunkte laufen in Threads
        self._lock = threading.Lock()
        self._access_token = ""
        self._access_until = 0.0

    # -- HTTP

    def _send(self, request: urllib.request.Request) -> tuple[int, bytes]:
        """Status und Inhalt der Antwort. Netzfehler -> VerifierUnavailable (ohne Adresse: sie enthält den Token)."""
        try:
            with self._opener(request, timeout=self._timeout) as response:
                return int(response.status), response.read()
        except urllib.error.HTTPError as exc:
            return int(exc.code), b""
        except (OSError, ValueError):  # URLError, Zeitlimit, Verbindungsabbruch
            raise VerifierUnavailable(MSG_UNREACHABLE) from None

    @staticmethod
    def _rejected(status_code: int) -> VerifierUnavailable:
        return VerifierUnavailable(
            f"Google lehnt den Schlüssel ab ({status_code}). Hat das Dienstkonto in der Play Console Zugriff auf "
            "die App?"
        )

    def _fetch_access_token(self) -> tuple[str, float]:
        account = load_service_account(self._key_file)
        now = int(time.time())
        claims = {
            "iss": account["client_email"],
            "scope": SCOPE,
            "aud": account["token_uri"],
            "iat": now,
            "exp": now + 3600,
        }
        try:
            assertion = jwt.encode(claims, account["private_key"], algorithm="RS256")
        except Exception:  # kaputter Schlüssel: nie den Inhalt in eine Meldung übernehmen
            raise VerifierUnavailable(MSG_KEY_INVALID) from None
        body = urllib.parse.urlencode(
            {"grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer", "assertion": assertion}
        ).encode()
        request = urllib.request.Request(
            account["token_uri"],
            data=body,
            method="POST",
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        status_code, raw = self._send(request)
        if status_code in (400, 401, 403):
            raise self._rejected(status_code)
        if status_code != 200:
            raise VerifierUnavailable(MSG_UNREACHABLE)
        try:
            data = json.loads(raw)
            token, lifetime = str(data["access_token"]), float(data.get("expires_in", 3600))
        except (ValueError, KeyError, TypeError):
            raise VerifierUnavailable("Google hat eine unverständliche Antwort geschickt.") from None
        # Fünf Minuten vor Ablauf erneuern
        return token, time.monotonic() + max(0.0, lifetime - 300)

    def _token(self, *, force: bool = False) -> str:
        with self._lock:
            if force or not self._access_token or time.monotonic() >= self._access_until:
                self._access_token, self._access_until = "", 0.0
                self._access_token, self._access_until = self._fetch_access_token()
            return self._access_token

    def _call(self, method: str, path: str, body: bytes | None = None) -> bytes:
        headers = {"Authorization": f"Bearer {self._token()}", "Accept": "application/json"}
        if body is not None:
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(
            f"{API_BASE}/{urllib.parse.quote(self._package, safe='')}/{path}",
            data=body,
            method=method,
            headers=headers,
        )
        status_code, raw = self._send(request)
        if 200 <= status_code < 300:
            return raw
        if status_code == 410:  # eindeutig: Der Token gilt nicht mehr
            raise PurchaseNotFound()
        if status_code in (400, 404):
            raise PurchaseNotFound(definite=False)
        if status_code in (401, 403):
            with self._lock:
                self._access_token, self._access_until = "", 0.0
            raise self._rejected(status_code)
        raise VerifierUnavailable(MSG_UNREACHABLE)

    # -- Schnittstelle

    def get_subscription(self, purchase_token: str) -> SubscriptionInfo:
        raw = self._call("GET", f"purchases/subscriptionsv2/tokens/{urllib.parse.quote(purchase_token, safe='')}")
        try:
            data = json.loads(raw)
        except ValueError:
            raise VerifierUnavailable("Google hat eine unverständliche Antwort geschickt.") from None
        return parse_subscription(data)

    def acknowledge(self, product_id: str, purchase_token: str) -> None:
        product = urllib.parse.quote(product_id, safe="")
        token = urllib.parse.quote(purchase_token, safe="")
        self._call("POST", f"purchases/subscriptions/{product}/tokens/{token}:acknowledge", b"{}")

    def check_access(self) -> None:
        """Holt nur ein frisches Zugriffstoken – zeigt, ob Schlüsseldatei und Verbindung stimmen."""
        self._token(force=True)


def build_verifier(settings: Settings) -> PurchaseVerifier | None:
    """None = Kaufprüfung nicht eingerichtet (Schlüsseldatei fehlt oder ist ungültig)."""
    try:
        load_service_account(settings.play_service_account_file)
    except VerifierUnavailable:
        return None
    return GooglePlayVerifier(settings.play_package_name, settings.play_service_account_file)


def current_verifier(state: Any, settings: Settings) -> PurchaseVerifier | None:
    """Die Kaufprüfung der laufenden App. Wurde die Schlüsseldatei erst nach dem Start abgelegt, wird sie jetzt
    gefunden – ein Neustart des Servers ist dafür nicht nötig."""
    verifier = getattr(state, "purchase_verifier", None)
    if verifier is None:
        verifier = build_verifier(settings)
        if verifier is not None:
            state.purchase_verifier = verifier
            logger.info("Kaufprüfung für Google Play eingerichtet (Paket %s).", settings.play_package_name)
    return verifier


# ------------------------------------------------------------------------------------------------ Regeln


def hash_token(purchase_token: str) -> str:
    return hashlib.sha256(purchase_token.encode("utf-8")).hexdigest()


def has_access(state: str, expires_at: datetime | None, now: datetime) -> bool:
    return state in ENTITLED and expires_at is not None and expires_at > now


def _end_license(license_: PremiumLicense | None, now: datetime) -> None:
    """Premium aus diesem Kauf endet sofort. Eine Play-Lizenz ist nie unbegrenzt (expires_at nie None)."""
    if license_ is None:
        return
    cut_short = license_.expires_at is None or license_.expires_at > now
    license_.expires_at = now if license_.expires_at is None else min(license_.expires_at, now)
    db = object_session(license_)
    if cut_short and db is not None and license_.revoked_at is None:
        # Vor dem bezahlten Ende beendet (Erstattung): Dahinter gehängte Codes beginnen jetzt statt erst dann
        close_gaps(db, license_.user_id, now)


def sync_license(purchase: PlayPurchase, info: SubscriptionInfo, now: datetime) -> None:
    """Gleicht die Lizenz an den Stand bei Google an. Ein Entzug durch den Admin (revoked_at) bleibt unberührt."""
    license_ = purchase.license
    if license_ is None:
        return
    if has_access(info.state, info.expires_at, now):
        license_.expires_at = info.expires_at
    else:
        # Kommt die Zahlung später doch (on_hold -> active), setzt die nächste Prüfung das Ende wieder hoch
        _end_license(license_, now)


def _apply(purchase: PlayPurchase, info: SubscriptionInfo, now: datetime) -> None:
    """Übernimmt eine frische Auskunft von Google in die Zeile und in die Lizenz."""
    if info.product_ids and purchase.product_id not in info.product_ids:
        purchase.product_id = info.product_ids[0][:100]  # Tarifwechsel innerhalb desselben Kaufs
    purchase.state = info.state
    purchase.expires_at = info.expires_at
    purchase.auto_renewing = info.auto_renewing
    purchase.acknowledged = info.acknowledged
    purchase.order_id = info.order_id or purchase.order_id
    purchase.is_test = info.is_test
    # Eine Antwort ohne Angabe löscht die bekannte Laufzeit nicht
    purchase.base_plan_id = info.base_plan_id or purchase.base_plan_id
    purchase.offer_id = info.offer_id or purchase.offer_id
    purchase.last_checked_at = now
    purchase.last_error = ""
    purchase.updated_at = now
    sync_license(purchase, info, now)


def _expire(purchase: PlayPurchase, now: datetime, *, checked: bool) -> None:
    purchase.state = "expired"
    purchase.auto_renewing = False
    purchase.updated_at = now
    if checked:
        purchase.last_checked_at = now
        purchase.last_error = ""
    _end_license(purchase.license, now)


def _account_is_gone(db: Session, account_id: str) -> bool:
    """Die Kennung im Kauf nennt eine Benutzer-Nummer, die es nicht mehr gibt (Konto gelöscht): Dann darf ein neues
    Konto den Kauf übernehmen. Alles andere (fremde Kennung, vorhandenes Konto) bleibt gesperrt."""
    if not account_id.isascii() or not account_id.isdigit() or len(account_id) > 18:
        return False
    return db.get(User, int(account_id)) is None


def register_purchase(
    db: Session, user: User, product_id: str, token: str, info: SubscriptionInfo, now: datetime
) -> PlayPurchase:
    """Ordnet einen von Google bestätigten Kauf dem Benutzer zu (oder aktualisiert ihn). Wirft PremiumError.

    Der Aufrufer hält `write_lock` und speichert; bei einem Fehler macht er alles rückgängig."""
    if product_id not in info.product_ids:
        raise PremiumError(400, MSG_UNKNOWN_PRODUCT)
    # Die App gibt beim Kauf die Benutzer-Nummer mit – Google liefert sie hier zurück
    if info.obfuscated_account_id and info.obfuscated_account_id != str(user.id) and not _account_is_gone(
        db, info.obfuscated_account_id
    ):
        raise PremiumError(409, MSG_OTHER_ACCOUNT)

    digest = hash_token(token)
    purchase = db.scalar(select(PlayPurchase).where(PlayPurchase.token_hash == digest))
    if purchase is not None and purchase.user_id != user.id:
        raise PremiumError(409, MSG_OTHER_ACCOUNT)
    if purchase is None:
        purchase = PlayPurchase(
            user_id=user.id,
            product_id=product_id,
            purchase_token=token,
            token_hash=digest,
            state=info.state,
            last_checked_at=now,
            created_at=now,
            updated_at=now,
        )
        db.add(purchase)

    if info.linked_purchase_token:
        linked_hash = hash_token(info.linked_purchase_token)
        purchase.linked_token_hash = linked_hash
        previous = db.scalar(select(PlayPurchase).where(PlayPurchase.token_hash == linked_hash))
        if previous is not None and previous is not purchase:
            if previous.user_id != user.id:
                raise PremiumError(409, MSG_OTHER_ACCOUNT)
            # Der neue Kauf ersetzt den alten und übernimmt dessen Lizenz – kein doppeltes Premium
            if purchase.license_id is None and purchase.license is None and previous.license is not None:
                purchase.license = previous.license
                previous.license = None
            previous.state = "replaced"
            previous.auto_renewing = False
            previous.updated_at = now

    license_ = purchase.license
    if license_ is not None and license_.revoked_at is not None:
        # Vom Admin entzogen: Der Kauf lässt sich nicht erneut übernehmen, nichts wird wiederbelebt
        raise PremiumError(409, MSG_BLOCKED)
    if license_ is None:
        # Befristet wie jede andere Lizenz; ohne Zugang (z. B. Zahlung noch offen) ist sie sofort zu Ende
        license_ = PremiumLicense(
            user_id=user.id,
            source="play",
            starts_at=now,
            expires_at=now,
            note=f"Google Play: {product_id}"[:200],
        )
        db.add(license_)
        purchase.license = license_
    purchase.product_id = product_id
    _apply(purchase, info, now)
    db.flush()
    return purchase


def needs_acknowledge(purchase: PlayPurchase, now: datetime) -> bool:
    return not purchase.acknowledged and has_access(purchase.state, purchase.expires_at, now)


def acknowledge(db: Session, purchase: PlayPurchase, verifier: PurchaseVerifier, now: datetime) -> bool:
    """Bestätigt den Kauf bei Google (ohne `write_lock` aufrufen). Scheitert das, gilt Premium trotzdem – der
    nächste Prüflauf versucht es wieder."""
    if not needs_acknowledge(purchase, now):
        return purchase.acknowledged
    try:
        verifier.acknowledge(purchase.product_id, purchase.purchase_token)
    except (PurchaseNotFound, VerifierUnavailable) as exc:
        logger.warning("Kauf %s konnte bei Google nicht bestätigt werden: %s", purchase.id, type(exc).__name__)
        # Auch in der Kaufliste zeigen: Bleibt das so, erstattet Google den Kauf. Die nächste gelungene Prüfung
        # leert die Meldung wieder (siehe _apply)
        reason = MSG_ACKNOWLEDGE_NOT_FOUND if isinstance(exc, PurchaseNotFound) else str(exc)
        with write_lock:
            purchase.last_error = f"{MSG_ACKNOWLEDGE_FAILED} {reason}".strip()[:300]
            db.commit()
        return False
    with write_lock:
        purchase.acknowledged = True
        purchase.updated_at = now
        db.commit()
    return True


def awaiting_renewal(purchase: PlayPurchase, now: datetime) -> bool:
    """Der Zeitraum ist gerade um, Google meldet das Abo aber (noch) als laufend: Die Verlängerung ist vermutlich
    nur noch nicht verbucht. Daraus darf niemand „kein Premium“ lesen."""
    return (
        purchase.state in RENEWING_STATES
        and purchase.expires_at is not None
        and purchase.expires_at <= now < purchase.expires_at + RENEWAL_TOLERANCE
    )


def _marked_not_found(purchase: PlayPurchase) -> bool:
    """Beendet, weil Google den Kauf bei der erneuten Prüfung nicht kannte (400/404) – nicht, weil Google das Ende
    gemeldet hat. Das Merkmal steht vorn in `last_error` und übersteht gescheiterte Nachprüfungen."""
    return purchase.state == "expired" and purchase.last_error.startswith(MSG_NOT_FOUND_ON_RECHECK)


def _suspect(purchase: PlayPurchase, now: datetime) -> bool:
    """Beendet, weil Google den Kauf bei der erneuten Prüfung nicht kannte – solange der Token noch gelten kann,
    wird weiter nachgesehen (nach einer korrigierten Einstellung lebt der Kauf von selbst wieder auf)."""
    return _marked_not_found(purchase) and (
        purchase.expires_at is None or purchase.expires_at >= now - TOKEN_LIFETIME_AFTER_EXPIRY
    )


def _is_due(purchase: PlayPurchase, now: datetime, recheck: timedelta) -> bool:
    age = now - purchase.last_checked_at
    if age >= recheck:
        return True
    if purchase.state in ENTITLED and purchase.expires_at is not None and purchase.expires_at <= now:
        # Der Zeitraum ist um: Sofort nachsehen, ob verlängert wurde – die Lizenz ist sonst zu Unrecht zu Ende.
        # Hat Google nach dem Ablauf schon geantwortet (Verlängerung noch nicht verbucht), nur noch minütlich
        return purchase.last_checked_at < purchase.expires_at or age >= OVERDUE_RECHECK
    if purchase.expires_at is not None and purchase.expires_at <= now + RENEWAL_WINDOW and age >= RENEWAL_RECHECK:
        return True
    return not purchase.acknowledged and age >= UNACKNOWLEDGED_RECHECK


def recheck_purchase(db: Session, purchase: PlayPurchase, verifier: PurchaseVerifier, now: datetime) -> None:
    """Fragt Google sofort nach diesem Kauf und übernimmt die Antwort. Wirft VerifierUnavailable, wenn gerade keine
    Auskunft möglich ist (dann wird nur `last_error` gesetzt)."""
    try:
        info = verifier.get_subscription(purchase.purchase_token)  # bewusst ohne write_lock (Netz)
    except PurchaseNotFound as exc:
        if exc.definite:
            with write_lock:
                _expire(purchase, now, checked=True)
                db.commit()
            return
        # 400/404: toter Token oder falsche Einstellung (Paketname)? Bis einige Tage nach dem bezahlten Ende nichts
        # beenden; danach gilt der Kauf als beendet, wird aber weiter nachgeprüft (siehe _suspect)
        paid_until = purchase.expires_at or purchase.last_checked_at
        with write_lock:
            if purchase.state == "expired" or now >= paid_until + NOT_FOUND_TOLERANCE:
                _expire(purchase, now, checked=True)
            purchase.last_error = MSG_NOT_FOUND_ON_RECHECK
            db.commit()
        if purchase.state == "expired":
            return
        raise UnclearNotFound(MSG_NOT_FOUND_ON_RECHECK) from None
    except VerifierUnavailable as exc:
        with write_lock:
            if _marked_not_found(purchase):
                # Das Merkmal „wird weiter nachgeprüft“ darf an einer Störung nicht verloren gehen: Der Kauf fiele
                # sonst für immer aus der Nachprüfung. Die Störung wird nur dahinter vermerkt
                purchase.last_error = f"{MSG_NOT_FOUND_ON_RECHECK}{MSG_LAST_RECHECK}{exc}"[:300]
            else:
                purchase.last_error = str(exc)[:300]
            db.commit()
        raise
    with write_lock:
        _apply(purchase, info, now)
        db.commit()
    acknowledge(db, purchase, verifier, now)


def open_purchases(db: Session, user_id: int) -> list[PlayPurchase]:
    rows = db.scalars(
        select(PlayPurchase)
        .where(PlayPurchase.user_id == user_id, PlayPurchase.state.in_(OPEN_STATES))
        .order_by(PlayPurchase.created_at, PlayPurchase.id)
    ).unique()
    # Vom Admin entzogen: Der Kauf wird nicht mehr geprüft
    return [row for row in rows if row.license is None or row.license.revoked_at is None]


def _suspect_purchases(db: Session, user_id: int, now: datetime) -> list[PlayPurchase]:
    rows = db.scalars(
        select(PlayPurchase)
        .where(
            PlayPurchase.user_id == user_id,
            PlayPurchase.state == "expired",
            PlayPurchase.last_error.startswith(MSG_NOT_FOUND_ON_RECHECK, autoescape=True),
        )
        .order_by(PlayPurchase.id)
    ).unique()
    return [row for row in rows if _suspect(row, now) and (row.license is None or row.license.revoked_at is None)]


def refresh_user(
    db: Session,
    user: User,
    verifier: PurchaseVerifier | None,
    now: datetime,
    *,
    recheck_hours: int = 12,
    backoff: dict[int, datetime] | None = None,
) -> bool:
    """Prüft die laufenden Käufe des Benutzers erneut bei Google, soweit fällig (gedrosselt).

    False = Der Premium-Stand ist gerade nicht prüfbar: Eine fällige Prüfung ist gescheitert, und ohne diesen Kauf
    hätte der Benutzer kein Premium. Dann darf niemand „kein Premium“ daraus lesen (die App löscht sonst Musik)."""
    recheck = timedelta(hours=recheck_hours)
    unclear: list[PlayPurchase] = []
    for purchase in _suspect_purchases(db, user.id, now):
        # Nebenbei und ohne Folgen für die Antwort: Der Kauf gilt als beendet, bis Google ihn wieder kennt
        failed_at = backoff.get(purchase.id) if backoff is not None else None
        if verifier is None or now - purchase.last_checked_at < recheck:
            continue
        if failed_at is not None and timedelta(0) <= now - failed_at < FAILURE_BACKOFF:
            continue
        try:
            recheck_purchase(db, purchase, verifier, now)
        except VerifierUnavailable:
            if backoff is not None:
                backoff[purchase.id] = now
    for purchase in open_purchases(db, user.id):
        if purchase.expires_at is not None and purchase.expires_at < now - TOKEN_LIFETIME_AFTER_EXPIRY:
            with write_lock:
                _expire(purchase, now, checked=False)
                db.commit()
            continue
        if not _is_due(purchase, now, recheck):
            continue
        if verifier is None:
            if purchase.last_error != MSG_NOT_CONFIGURED:
                with write_lock:
                    purchase.last_error = MSG_NOT_CONFIGURED
                    db.commit()
            unclear.append(purchase)
            continue
        failed_at = backoff.get(purchase.id) if backoff is not None else None
        if failed_at is not None and timedelta(0) <= now - failed_at < FAILURE_BACKOFF:
            unclear.append(purchase)
            continue
        try:
            recheck_purchase(db, purchase, verifier, now)
        except VerifierUnavailable:
            if backoff is not None:
                backoff[purchase.id] = now
            unclear.append(purchase)
        else:
            if backoff is not None:
                backoff.pop(purchase.id, None)
    # Zeitraum gerade um, Verlängerung bei Google noch nicht verbucht: „unbekannt“, nicht „kein Premium“
    known = {purchase.id for purchase in unclear}
    unclear += [p for p in open_purchases(db, user.id) if p.id not in known and awaiting_renewal(p, now)]
    if not unclear:
        return True
    # Reichen die übrigen Lizenzen (Code, Admin, andere Käufe) für Premium, ist der Stand trotzdem klar
    skip = {purchase.license_id for purchase in unclear if purchase.license_id is not None}
    others = [lic for lic in live_licenses(db, user.id, now) if lic.id not in skip]
    # Nur ein voller Umfang macht den Stand klar: Ein zusätzlicher Teil-Code (z. B. ohne Offline-Hören) hieße sonst
    # „klar ohne Offline“ – und die App löschte die Musik eines Abonnenten bei einer Störung
    return status_of(others, now).features == ALL_FEATURES


def premium_unsettled(db: Session, user_id: int, now: datetime) -> bool:
    """Nur anhand der gespeicherten Käufe, ohne Google zu fragen: Der bezahlte Zeitraum ist um, „kein Premium“ lässt
    sich daraus aber (noch) nicht lesen – der Abonnent zahlt vermutlich weiter.

    - Seit dem Ablauf wurde Google noch nicht gefragt (die App war nicht offen) oder nicht erreicht: Bis dahin ist
      offen, ob verlängert wurde. Das gilt, solange auch `refresh_user` den Kauf noch nachprüfen würde.
    - Google hat nach dem Ablauf geantwortet und meldet das Abo weiter als laufend: Die Verlängerung ist nur noch
      nicht verbucht (siehe `awaiting_renewal`).

    Zahlung hängt, pausiert, noch nicht bezahlt (on_hold/paused/pending): Das ist ein klarer Stand ohne Zugang."""
    for purchase in open_purchases(db, user_id):
        if purchase.state not in ENTITLED or purchase.expires_at is None or purchase.expires_at > now:
            continue
        if purchase.last_checked_at < purchase.expires_at:
            if now <= purchase.expires_at + TOKEN_LIFETIME_AFTER_EXPIRY:
                return True
        elif awaiting_renewal(purchase, now):
            return True
    return False


def current_subscription(db: Session, user_id: int) -> PlayPurchase | None:
    """Der jüngste noch laufende Kauf des Benutzers (für die Anzeige in der App)."""
    rows = open_purchases(db, user_id)
    return rows[-1] if rows else None
