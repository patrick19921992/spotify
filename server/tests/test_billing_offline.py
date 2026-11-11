"""Premium = Offline-Hören: Schalter im Dashboard, Kauf über Google Play (mit Attrappe), erneute Prüfung, Entzug."""

import json
import sqlite3
import urllib.error
import urllib.parse
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

import jwt
import pytest
from alembic import command
from alembic.autogenerate import compare_metadata
from alembic.migration import MigrationContext
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select
from sqlalchemy.exc import IntegrityError

from app.config import Settings
from app.database import alembic_config
from app.main import create_app
from app.models import Base, PlayPurchase, PremiumLicense, utcnow
from app.services import play_billing
from app.services.play_billing import (
    GooglePlayVerifier,
    PurchaseNotFound,
    VerifierUnavailable,
    build_verifier,
    hash_token,
    parse_subscription,
)

from .conftest import ADMIN_PASSWORD, bearer, login
from .fake_play import FakePlayVerifier, sub
from .test_premium import new_codes, parse, redeem, user_headers

PRODUCT = "premium_monat"
TOKEN = "kauf-token-aaaaaaaaaaaaaaaa"
OTHER_TOKEN = "kauf-token-bbbbbbbbbbbbbbbb"


@pytest.fixture
def fake(client: TestClient) -> FakePlayVerifier:
    verifier = FakePlayVerifier()
    client.app.state.purchase_verifier = verifier
    return verifier


def put_config(client: TestClient, admin_headers: dict[str, str], **values: object):  # type: ignore[no-untyped-def]
    return client.put("/api/admin/config", headers=admin_headers, json=values)


@pytest.fixture
def shop(client: TestClient, admin_headers: dict[str, str], fake: FakePlayVerifier) -> FakePlayVerifier:
    """Kauf in der App eingeschaltet, Offline-Hören nur mit Premium."""
    response = put_config(
        client, admin_headers, billing_enabled=True, billing_product_ids=PRODUCT, offline_requires_premium=True
    )
    assert response.status_code == 200, response.text
    return fake


def verify(client: TestClient, headers: dict[str, str], token: str = TOKEN, product: str = PRODUCT):  # type: ignore[no-untyped-def]
    body = {"product_id": product, "purchase_token": token}
    return client.post("/api/premium/play/verify", headers=headers, json=body)


def premium(client: TestClient, headers: dict[str, str]) -> dict:
    response = client.get("/api/premium", headers=headers)
    assert response.status_code == 200, response.text
    return response.json()


def purchases(client: TestClient) -> list[PlayPurchase]:
    with client.app.state.session_factory() as db:
        return list(db.scalars(select(PlayPurchase).order_by(PlayPurchase.id)).unique())


def age_checks(client: TestClient, **delta: float) -> None:
    """Tut so, als läge die letzte Prüfung bei Google schon so lange zurück."""
    with client.app.state.session_factory() as db:
        for row in db.scalars(select(PlayPurchase)).unique():
            row.last_checked_at = utcnow() - timedelta(**delta)
        db.commit()


# ------------------------------------------------------------------------------------- Schalter aus = wie bisher


def test_with_all_switches_off_everything_behaves_as_before(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable
) -> None:
    config = client.get("/api/app/config", params={"channel": "play", "build": 60}).json()
    assert config["offline_requires_premium"] is False and config["offline_grace_days"] == 7
    assert config["billing_enabled"] is False and config["billing_product_ids"] == []
    assert config["premium_headline"] == "" and config["premium_description"] == "" and config["premium_benefits"] == []
    # die bisherigen Felder sind unverändert da
    assert config["premium_enabled"] is True and config["ads_enabled"] is False and config["update"]["level"] == "none"

    _, headers = user_headers(client, make_user, "lena")
    status = premium(client, headers)
    assert (status["active"], status["unlimited"], status["until"]) == (False, False, None)
    # ohne Schalter darf jeder offline hören – auch ohne Premium
    assert status["offline_requires_premium"] is False and status["offline_allowed"] is True
    assert status["offline_grace_days"] == 7 and status["play"] is None
    assert abs((parse(status["checked_at"]) - utcnow()).total_seconds()) < 30

    # Kaufen geht nicht, solange der Betreiber es nicht einschaltet
    refused = verify(client, headers)
    assert refused.status_code == 409
    assert refused.json()["detail"] == "Der Kauf in der App ist auf diesem Server nicht eingeschaltet."
    assert purchases(client) == []
    admin_config = client.get("/api/admin/config", headers=admin_headers).json()
    assert admin_config["offline_requires_premium"] is False and admin_config["billing_enabled"] is False
    assert admin_config["offline_grace_days"] == 7 and admin_config["billing_product_ids"] == ""


def test_redeem_answers_with_the_old_fields_plus_the_new_ones(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable
) -> None:
    _, headers = user_headers(client, make_user, "lena")
    (code,) = new_codes(client, admin_headers, duration_days=30)
    body = redeem(client, headers, code["code"]).json()
    assert body["active"] is True and body["unlimited"] is False and body["until"]
    assert body["offline_allowed"] is True and body["offline_requires_premium"] is False and "checked_at" in body


# ------------------------------------------------------------------------------------- Einstellungen


def test_new_settings_are_validated(client: TestClient, admin_headers: dict[str, str]) -> None:
    zero = put_config(client, admin_headers, offline_grace_days=0)
    assert zero.status_code == 400
    assert zero.json()["detail"] == "offline_grace_days: eine Zahl von 1 bis 30 erwartet."
    assert put_config(client, admin_headers, offline_grace_days=31).status_code == 400
    assert put_config(client, admin_headers, offline_grace_days=14).json()["offline_grace_days"] == 14

    ok = put_config(client, admin_headers, billing_product_ids=" premium_monat , premium.jahr ,")
    assert ok.json()["billing_product_ids"] == "premium_monat,premium.jahr"
    for bad in ("Premium", "a b", "_abc", "a,a", "a,b,c,d,e,f", "x" * 41, "a;b"):
        response = put_config(client, admin_headers, billing_product_ids=bad)
        assert response.status_code == 400, bad
        assert response.json()["detail"].startswith("billing_product_ids: Produkt-IDs bestehen aus")
    assert put_config(client, admin_headers, billing_product_ids="x" * 201).status_code == 400

    benefits = put_config(client, admin_headers, premium_benefits=" Offline hören \n\n  Keine Werbung\n")
    assert benefits.json()["premium_benefits"] == "Offline hören\nKeine Werbung"
    too_many = put_config(client, admin_headers, premium_benefits="\n".join(f"Vorteil {i}" for i in range(9)))
    assert too_many.status_code == 400
    assert too_many.json()["detail"] == "premium_benefits: höchstens 8 Zeilen mit je 100 Zeichen."
    assert put_config(client, admin_headers, premium_benefits="x" * 101).status_code == 400
    assert put_config(client, admin_headers, premium_headline="x" * 81).status_code == 400
    assert put_config(client, admin_headers, premium_description="x" * 501).status_code == 400
    assert put_config(client, admin_headers, offline_requires_premium="ja").status_code in (400, 422)

    texts = put_config(client, admin_headers, premium_headline=" Selfify Premium ", premium_description="Musik dabei.")
    assert texts.json()["premium_headline"] == "Selfify Premium"
    public = client.get("/api/app/config").json()
    assert public["premium_headline"] == "Selfify Premium" and public["premium_description"] == "Musik dabei."
    assert public["premium_benefits"] == ["Offline hören", "Keine Werbung"] and public["offline_grace_days"] == 14


def test_billing_cannot_be_switched_on_without_a_product(client: TestClient, admin_headers: dict[str, str]) -> None:
    response = put_config(client, admin_headers, billing_enabled=True)
    assert response.status_code == 400
    assert response.json()["detail"] == "billing_product_ids: Für den Kauf in der App fehlt die Produkt-ID des Abos."
    assert client.get("/api/admin/config", headers=admin_headers).json()["billing_enabled"] is False
    assert put_config(client, admin_headers, billing_enabled=True, billing_product_ids=PRODUCT).status_code == 200
    # und die Produkt-ID lässt sich nicht wieder leeren, solange der Kauf an ist
    assert put_config(client, admin_headers, billing_product_ids="").status_code == 400


def test_app_only_offers_buying_in_the_play_version_with_a_working_check(
    client: TestClient, admin_headers: dict[str, str]
) -> None:
    put_config(client, admin_headers, billing_enabled=True, billing_product_ids=f"{PRODUCT},premium_jahr")

    def billing(channel: str) -> tuple[bool, list[str]]:
        body = client.get("/api/app/config", params={"channel": channel, "build": 60}).json()
        return body["billing_enabled"], body["billing_product_ids"]

    # Schalter an, aber keine Schlüsseldatei: Die App zeigt keinen Kauf-Knopf, der ins Leere führt
    assert billing("play") == (False, [])
    client.app.state.purchase_verifier = FakePlayVerifier()
    assert billing("play") == (True, [PRODUCT, "premium_jahr"])
    # GitHub-Version, Windows, iPhone: nie
    assert billing("full") == (False, [])
    assert billing("") == (False, [])
    put_config(client, admin_headers, billing_enabled=False)
    assert billing("play") == (False, [])


# ------------------------------------------------------------------------------------- Offline-Sperre


def test_offline_needs_premium_only_when_switched_on_and_admins_are_exempt(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable
) -> None:
    user, headers = user_headers(client, make_user, "lena")
    assert premium(client, headers)["offline_allowed"] is True
    put_config(client, admin_headers, offline_requires_premium=True, offline_grace_days=3)
    locked = premium(client, headers)
    assert locked["offline_requires_premium"] is True and locked["offline_allowed"] is False
    assert locked["offline_grace_days"] == 3 and locked["active"] is False
    assert client.get("/api/app/config").json()["offline_requires_premium"] is True

    # Admin: kein Premium, darf trotzdem
    admin = premium(client, admin_headers)
    assert admin["active"] is False and admin["offline_allowed"] is True

    # Premium per Code zählt genauso wie ein Kauf
    (code,) = new_codes(client, admin_headers, duration_days=30)
    assert redeem(client, headers, code["code"]).json()["offline_allowed"] is True
    assert premium(client, headers)["offline_allowed"] is True
    # … und vom Admin vergeben ebenso; nach dem Entzug ist Schluss
    client.delete(f"/api/admin/users/{user['id']}/premium", headers=admin_headers)
    assert premium(client, headers)["offline_allowed"] is False
    client.post(f"/api/admin/users/{user['id']}/premium", headers=admin_headers, json={"unlimited": True})
    assert premium(client, headers)["offline_allowed"] is True


# ------------------------------------------------------------------------------------- Kauf melden


def test_valid_purchase_gives_premium_until_the_subscription_ends(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable, shop: FakePlayVerifier
) -> None:
    user, headers = user_headers(client, make_user, "lena")
    shop.subscriptions[TOKEN] = sub(account=str(user["id"]), test=True)
    response = verify(client, headers)
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["result"] == "active"
    status = body["premium"]
    assert status["active"] is True and status["unlimited"] is False and status["offline_allowed"] is True
    assert parse(status["until"]) == shop.subscriptions[TOKEN].expires_at
    assert status["play"] == {
        "product_id": PRODUCT,
        "state": "active",
        "expires_at": status["until"],
        "auto_renewing": True,
    }
    # bei Google bestätigt – sonst erstattet Google nach drei Tagen
    assert shop.acknowledged == [TOKEN]
    (row,) = purchases(client)
    assert row.user_id == user["id"] and row.acknowledged is True and row.is_test is True
    assert row.token_hash == hash_token(TOKEN) and row.order_id.startswith("GPA.")
    assert premium(client, headers)["play"]["state"] == "active"

    # Lizenz mit Quelle „play“, im Dashboard sichtbar
    listing = client.get(f"/api/admin/users/{user['id']}/premium", headers=admin_headers).json()
    (lic,) = listing["licenses"]
    assert lic["source"] == "play" and lic["running"] is True and lic["note"] == f"Google Play: {PRODUCT}"
    running = client.get("/api/admin/premium/licenses?only_running=true", headers=admin_headers).json()
    assert [item["source"] for item in running] == ["play"]

    # nochmal melden (Wiederherstellen, zweites Gerät): gleiches Ergebnis, kein zweiter Kauf, keine zweite Lizenz
    again = verify(client, headers)
    assert again.status_code == 200 and again.json()["result"] == "active"
    assert len(purchases(client)) == 1 and shop.acknowledged == [TOKEN]
    with client.app.state.session_factory() as db:
        assert len(list(db.scalars(select(PremiumLicense)).unique())) == 1


def test_the_purchase_token_never_leaves_the_server(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable, shop: FakePlayVerifier
) -> None:
    _, headers = user_headers(client, make_user, "lena")
    shop.subscriptions[TOKEN] = sub()
    texts = [verify(client, headers).text, client.get("/api/premium", headers=headers).text]
    listing = client.get("/api/admin/premium/purchases", headers=admin_headers)
    assert listing.status_code == 200
    (item,) = listing.json()
    assert set(item) == {
        "id", "user_id", "username", "display_name", "product_id", "order_id", "state", "expires_at", "auto_renewing",
        "acknowledged", "is_test", "license_id", "license_revoked", "last_checked_at", "last_error", "created_at",
    }  # fmt: skip
    assert item["username"] == "lena" and item["state"] == "active" and item["license_revoked"] is False
    texts.append(listing.text)
    texts.append(client.post(f"/api/admin/premium/purchases/{item['id']}/recheck", headers=admin_headers).text)
    for text in texts:
        assert TOKEN not in text and hash_token(TOKEN) not in text


def test_invented_tokens_are_refused_and_counted(
    client: TestClient, make_user: Callable, shop: FakePlayVerifier
) -> None:
    _, headers = user_headers(client, make_user, "lena")
    response = verify(client, headers, token="erfunden-0000000000")
    assert response.status_code == 404
    assert response.json()["detail"] == "Dieser Kauf wurde bei Google Play nicht gefunden."
    assert purchases(client) == [] and premium(client, headers)["active"] is False
    for _ in range(19):
        assert verify(client, headers, token="erfunden-0000000000").status_code == 404
    blocked = verify(client, headers, token="erfunden-0000000000")
    assert blocked.status_code == 429 and int(blocked.headers["Retry-After"]) > 0
    assert blocked.json()["detail"].startswith("Zu viele Versuche.")
    # andere Benutzer sind davon nicht betroffen
    _, other = user_headers(client, make_user, "tom")
    shop.subscriptions[TOKEN] = sub()
    assert verify(client, other).status_code == 200


def test_bad_requests_are_rejected(client: TestClient, make_user: Callable, shop: FakePlayVerifier) -> None:
    _, headers = user_headers(client, make_user, "lena")
    anonymous = client.post("/api/premium/play/verify", json={"product_id": PRODUCT, "purchase_token": TOKEN})
    assert anonymous.status_code == 401
    assert verify(client, headers, token="kurz").status_code == 422
    assert verify(client, headers, token="x" * 4001).status_code == 422
    assert verify(client, headers, product="").status_code == 422
    # Produkt, das hier nicht verkauft wird
    shop.subscriptions[TOKEN] = sub(product="anderes_abo")
    unknown = verify(client, headers, product="anderes_abo")
    assert unknown.status_code == 400 and unknown.json()["detail"] == "Dieses Produkt gibt es hier nicht."
    # Produkt stimmt hier, aber der Kauf bei Google ist für etwas anderes
    assert verify(client, headers).status_code == 400
    assert purchases(client) == [] and shop.acknowledged == []


@pytest.mark.parametrize(
    ("state", "days", "result"),
    [
        ("expired", -1, "inactive"),  # abgelaufen oder erstattet
        ("active", -1, "inactive"),  # Google sagt „aktiv“, das Ablaufdatum ist aber vorbei
        ("on_hold", 5, "inactive"),  # Zahlung ausgesetzt
        ("paused", 5, "inactive"),
        ("pending", 5, "pending"),  # Zahlung noch offen
        ("canceled", 5, "active"),  # gekündigt, läuft aber bis zum Ende der bezahlten Zeit
        ("grace", 5, "active"),  # Zahlungsproblem, Google gewährt noch Zugang
    ],
)
def test_result_follows_the_state_at_google(
    client: TestClient, make_user: Callable, shop: FakePlayVerifier, state: str, days: int, result: str
) -> None:
    _, headers = user_headers(client, make_user, "lena")
    shop.subscriptions[TOKEN] = sub(state=state, days=days)
    response = verify(client, headers)
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["result"] == result
    has_premium = result == "active"
    assert body["premium"]["active"] is has_premium and body["premium"]["offline_allowed"] is has_premium
    # nur Käufe mit Zugang werden bei Google bestätigt
    assert shop.acknowledged == ([TOKEN] if has_premium else [])
    assert premium(client, headers)["active"] is has_premium
    if state == "expired":
        assert body["premium"]["play"] is None
    with client.app.state.session_factory() as db:
        for lic in db.scalars(select(PremiumLicense)).unique():
            assert lic.expires_at is not None, "ein Kauf darf nie unbegrenztes Premium erzeugen"


def test_a_purchase_without_expiry_never_becomes_unlimited_premium(
    client: TestClient, make_user: Callable, shop: FakePlayVerifier
) -> None:
    _, headers = user_headers(client, make_user, "lena")
    shop.subscriptions[TOKEN] = replace(sub(), expires_at=None)
    body = verify(client, headers).json()
    assert body["result"] == "inactive" and body["premium"]["active"] is False and body["premium"]["unlimited"] is False


def test_one_purchase_belongs_to_one_account(
    client: TestClient, make_user: Callable, shop: FakePlayVerifier
) -> None:
    lena, lena_headers = user_headers(client, make_user, "lena")
    _, tom_headers = user_headers(client, make_user, "tom")
    shop.subscriptions[TOKEN] = sub()
    assert verify(client, lena_headers).status_code == 200
    stolen = verify(client, tom_headers)
    assert stolen.status_code == 409
    assert stolen.json()["detail"] == "Dieser Kauf ist schon mit einem anderen Konto verbunden."
    assert premium(client, tom_headers)["active"] is False
    assert [p.user_id for p in purchases(client)] == [lena["id"]]

    # Kauf, den die App für ein anderes Konto gestartet hat (Konto-Kennung von Google passt nicht)
    shop.subscriptions[OTHER_TOKEN] = sub(account=str(lena["id"]))
    foreign = verify(client, tom_headers, token=OTHER_TOKEN)
    assert foreign.status_code == 409 and len(purchases(client)) == 1
    assert shop.acknowledged == [TOKEN], "ein abgelehnter Kauf wird nicht bestätigt"


def test_two_accounts_sending_the_same_purchase_at_once(
    client: TestClient, make_user: Callable, shop: FakePlayVerifier
) -> None:
    names = [f"kind{i}" for i in range(6)]
    headers = [user_headers(client, make_user, name)[1] for name in names]
    shop.subscriptions[TOKEN] = sub()
    with ThreadPoolExecutor(max_workers=6) as pool:
        codes = sorted(r.status_code for r in pool.map(lambda h: verify(client, h), headers))
    assert codes == [200, 409, 409, 409, 409, 409]
    assert len(purchases(client)) == 1
    assert sum(premium(client, h)["active"] for h in headers) == 1


def test_database_refuses_the_same_token_twice(client: TestClient, make_user: Callable) -> None:
    """Die letzte Absicherung, falls die Sperre im Code einmal nicht greift."""
    lena, tom = make_user("lena"), make_user("tom")
    with client.app.state.session_factory() as db:
        for user in (lena, tom):
            db.add(
                PlayPurchase(
                    user_id=user["id"], product_id=PRODUCT, purchase_token=TOKEN, token_hash=hash_token(TOKEN),
                    state="active",
                )  # fmt: skip
            )
            if user is lena:
                db.commit()
        with pytest.raises(IntegrityError):
            db.commit()


def test_without_a_key_file_or_without_google_nothing_is_stored(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable
) -> None:
    _, headers = user_headers(client, make_user, "lena")
    put_config(client, admin_headers, billing_enabled=True, billing_product_ids=PRODUCT)
    missing = verify(client, headers)
    assert missing.status_code == 503
    assert missing.json()["detail"] == "Die Kaufprüfung ist auf dem Server nicht eingerichtet."

    fake = FakePlayVerifier()
    fake.subscriptions[TOKEN] = sub()
    fake.fail = VerifierUnavailable("Google ist nicht erreichbar.")
    client.app.state.purchase_verifier = fake
    down = verify(client, headers)
    assert down.status_code == 503 and down.json()["detail"].startswith("Google Play ist gerade nicht erreichbar.")
    assert "Käufe wiederherstellen" in down.json()["detail"]
    assert purchases(client) == []
    # eine Störung ist kein Ratversuch: später klappt es
    fake.fail = None
    assert verify(client, headers).json()["result"] == "active"


def test_failed_acknowledge_keeps_premium_and_is_retried(
    client: TestClient, make_user: Callable, shop: FakePlayVerifier
) -> None:
    _, headers = user_headers(client, make_user, "lena")
    shop.subscriptions[TOKEN] = sub()
    shop.fail_acknowledge = VerifierUnavailable("Google ist nicht erreichbar.")
    body = verify(client, headers).json()
    assert body["result"] == "active" and body["premium"]["active"] is True
    assert purchases(client)[0].acknowledged is False
    # vor Ablauf von zehn Minuten wird nicht erneut gefragt …
    calls = shop.calls
    premium(client, headers)
    assert shop.calls == calls
    # … danach schon – und dann klappt das Bestätigen
    shop.fail_acknowledge = None
    age_checks(client, minutes=11)
    assert premium(client, headers)["active"] is True
    assert shop.acknowledged == [TOKEN] and purchases(client)[0].acknowledged is True


# ------------------------------------------------------------------------------------- erneute Prüfung


def test_running_purchases_are_rechecked_but_not_on_every_request(
    client: TestClient, make_user: Callable, shop: FakePlayVerifier
) -> None:
    _, headers = user_headers(client, make_user, "lena")
    shop.subscriptions[TOKEN] = sub(days=30)
    verify(client, headers)
    calls = shop.calls
    for _ in range(5):
        premium(client, headers)
    assert shop.calls == calls, "frisch geprüft: Google wird nicht bei jeder Abfrage gefragt"

    # Google hat inzwischen verlängert
    renewed = sub(days=60, acknowledged=True)
    shop.subscriptions[TOKEN] = renewed
    age_checks(client, hours=11)
    assert parse(premium(client, headers)["until"]) != renewed.expires_at, "noch nicht fällig (12 Stunden)"
    age_checks(client, hours=13)
    assert parse(premium(client, headers)["until"]) == renewed.expires_at
    assert shop.calls == calls + 1


def test_around_the_renewal_date_the_check_runs_sooner(
    client: TestClient, make_user: Callable, shop: FakePlayVerifier
) -> None:
    _, headers = user_headers(client, make_user, "lena")
    shop.subscriptions[TOKEN] = sub(days=0.02)  # läuft in einer halben Stunde ab
    verify(client, headers)
    renewed = sub(days=30, acknowledged=True)
    shop.subscriptions[TOKEN] = renewed
    age_checks(client, minutes=3)
    assert parse(premium(client, headers)["until"]) != renewed.expires_at
    age_checks(client, minutes=6)
    assert parse(premium(client, headers)["until"]) == renewed.expires_at


@pytest.mark.parametrize("ending", ["refunded", "token_gone", "on_hold"])
def test_premium_ends_when_google_reports_it_and_offline_gets_locked(
    client: TestClient, make_user: Callable, shop: FakePlayVerifier, ending: str
) -> None:
    _, headers = user_headers(client, make_user, "lena")
    shop.subscriptions[TOKEN] = sub(days=30)
    verify(client, headers)
    assert premium(client, headers)["offline_allowed"] is True
    if ending == "refunded":  # Erstattung/Widerruf erscheint bei Google als „abgelaufen“
        shop.subscriptions[TOKEN] = sub(state="expired", days=20, acknowledged=True)
    elif ending == "token_gone":
        del shop.subscriptions[TOKEN]
    else:
        shop.subscriptions[TOKEN] = sub(state="on_hold", days=20, acknowledged=True)
    age_checks(client, hours=13)
    status = premium(client, headers)
    assert status["active"] is False and status["until"] is None
    assert status["offline_requires_premium"] is True and status["offline_allowed"] is False
    (row,) = purchases(client)
    if ending == "on_hold":
        assert row.state == "on_hold" and status["play"]["state"] == "on_hold"
        # Zahlung kommt doch noch: Premium läuft wieder
        back = sub(days=25, acknowledged=True)
        shop.subscriptions[TOKEN] = back
        age_checks(client, hours=13)
        again = premium(client, headers)
        assert again["active"] is True and parse(again["until"]) == back.expires_at
    else:
        assert row.state == "expired" and status["play"] is None
        # abgeschlossene Käufe werden nicht weiter geprüft
        calls = shop.calls
        age_checks(client, hours=100)
        premium(client, headers)
        assert shop.calls == calls


def test_cancelled_subscription_runs_until_the_paid_time_is_over(
    client: TestClient, make_user: Callable, shop: FakePlayVerifier
) -> None:
    _, headers = user_headers(client, make_user, "lena")
    shop.subscriptions[TOKEN] = sub(days=30)
    verify(client, headers)
    cancelled = sub(state="canceled", days=10, acknowledged=True)
    shop.subscriptions[TOKEN] = replace(cancelled, auto_renewing=False)
    age_checks(client, hours=13)
    status = premium(client, headers)
    assert status["active"] is True and parse(status["until"]) == cancelled.expires_at
    assert status["play"]["state"] == "canceled" and status["play"]["auto_renewing"] is False
    # Ablauf erreicht: Google meldet „abgelaufen“
    shop.subscriptions[TOKEN] = sub(state="expired", days=-0.01, acknowledged=True)
    age_checks(client, hours=13)
    assert premium(client, headers)["offline_allowed"] is False


def test_an_outage_at_google_never_reads_as_no_premium(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable, shop: FakePlayVerifier
) -> None:
    user, headers = user_headers(client, make_user, "lena")
    shop.subscriptions[TOKEN] = sub(days=30)
    verify(client, headers)
    age_checks(client, hours=13)
    shop.fail = VerifierUnavailable("Google ist nicht erreichbar.")
    calls = shop.calls
    response = client.get("/api/premium", headers=headers)
    assert response.status_code == 503
    assert response.json()["detail"] == (
        "Dein Premium-Stand kann gerade nicht geprüft werden. Bitte später noch einmal versuchen."
    )
    (row,) = purchases(client)
    assert row.state == "active" and row.last_error == "Google ist nicht erreichbar."
    with client.app.state.session_factory() as db:
        assert db.get(PremiumLicense, row.license_id).expires_at > utcnow(), "die Lizenz bleibt unangetastet"
    # während der Störung wird Google nicht bei jeder Abfrage erneut bemüht
    assert client.get("/api/premium", headers=headers).status_code == 503
    assert shop.calls == calls + 1

    # hat der Benutzer auch ohne diesen Kauf Premium (hier: unbegrenzt vom Admin), ist der Stand klar
    client.post(f"/api/admin/users/{user['id']}/premium", headers=admin_headers, json={"unlimited": True})
    assert premium(client, headers)["offline_allowed"] is True


def test_after_the_outage_the_state_is_checked_again(
    client: TestClient, make_user: Callable, shop: FakePlayVerifier
) -> None:
    _, headers = user_headers(client, make_user, "lena")
    shop.subscriptions[TOKEN] = sub(days=30)
    verify(client, headers)
    age_checks(client, hours=13)
    shop.fail = VerifierUnavailable("Google lehnt den Schlüssel ab (403). Hat das Dienstkonto …")
    assert client.get("/api/premium", headers=headers).status_code == 503
    shop.fail = None
    client.app.state.billing_backoff.clear()  # fünf Minuten später
    status = premium(client, headers)
    assert status["active"] is True and purchases(client)[0].last_error == ""


def test_removed_key_file_makes_the_state_unknown_not_expired(
    client: TestClient, make_user: Callable, shop: FakePlayVerifier
) -> None:
    _, headers = user_headers(client, make_user, "lena")
    shop.subscriptions[TOKEN] = sub(days=30)
    verify(client, headers)
    client.app.state.purchase_verifier = None  # Schlüsseldatei gelöscht, Server neu gestartet
    assert premium(client, headers)["active"] is True, "nicht fällig: der gespeicherte Stand gilt"
    age_checks(client, hours=13)
    assert client.get("/api/premium", headers=headers).status_code == 503
    assert purchases(client)[0].state == "active"


def test_very_old_purchases_are_closed_without_asking_google(
    client: TestClient, make_user: Callable, shop: FakePlayVerifier
) -> None:
    _, headers = user_headers(client, make_user, "lena")
    shop.subscriptions[TOKEN] = sub(state="on_hold", days=5)
    verify(client, headers)
    with client.app.state.session_factory() as db:
        row = db.scalars(select(PlayPurchase)).unique().one()
        row.expires_at = utcnow() - timedelta(days=61)
        db.commit()
    calls = shop.calls
    shop.fail = VerifierUnavailable("darf gar nicht gefragt werden")
    assert premium(client, headers)["active"] is False
    assert shop.calls == calls and purchases(client)[0].state == "expired"


# ------------------------------------------------------------------------------------- Stapeln, Entzug, Wechsel


def test_code_stacks_behind_a_running_subscription_and_unlimited_beats_all(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable, shop: FakePlayVerifier
) -> None:
    user, headers = user_headers(client, make_user, "lena")
    info = sub(days=30)
    shop.subscriptions[TOKEN] = info
    verify(client, headers)
    (code,) = new_codes(client, admin_headers, duration_days=10)
    stacked = redeem(client, headers, code["code"])
    assert stacked.status_code == 200
    # der Code hängt sich hinter das aktuelle Abo-Ende
    assert parse(stacked.json()["until"]) == info.expires_at + timedelta(days=10)
    assert stacked.json()["play"]["state"] == "active"

    # das Abo endet vor dem bezahlten Ende (Erstattung): Der Code beginnt jetzt – nicht erst am alten Abo-Ende,
    # sonst gäbe es trotz gültiger Lizenz kein Premium und die App löschte die Offline-Musik
    shop.subscriptions[TOKEN] = sub(state="expired", days=30, acknowledged=True)
    age_checks(client, hours=13)
    after = premium(client, headers)
    assert after["active"] is True and after["offline_allowed"] is True and after["play"] is None
    with client.app.state.session_factory() as db:
        code_license = db.scalars(select(PremiumLicense).where(PremiumLicense.source == "code")).unique().one()
        assert code_license.revoked_at is None
        # die Laufzeit des Codes bleibt bei seinen zehn Tagen
        assert code_license.expires_at - code_license.starts_at == timedelta(days=10)
        assert abs(code_license.starts_at - utcnow()) < timedelta(minutes=1)
        assert parse(after["until"]) == code_license.expires_at

    # unbegrenztes Premium vom Admin schlägt alles
    client.post(f"/api/admin/users/{user['id']}/premium", headers=admin_headers, json={"unlimited": True})
    forever = premium(client, headers)
    assert forever["active"] is True and forever["unlimited"] is True and forever["offline_allowed"] is True


def test_subscription_on_top_of_a_code_keeps_the_later_end(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable, shop: FakePlayVerifier
) -> None:
    _, headers = user_headers(client, make_user, "lena")
    (code,) = new_codes(client, admin_headers, duration_days=90)
    until_code = parse(redeem(client, headers, code["code"]).json()["until"])
    shop.subscriptions[TOKEN] = sub(days=30)
    body = verify(client, headers).json()
    assert body["result"] == "active" and parse(body["premium"]["until"]) == until_code
    # fällt Google aus, ist der Stand trotzdem klar: Der Code reicht
    age_checks(client, hours=13)
    shop.fail = VerifierUnavailable("Google ist nicht erreichbar.")
    assert premium(client, headers)["active"] is True


def test_revoked_purchase_stays_revoked(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable, shop: FakePlayVerifier
) -> None:
    user, headers = user_headers(client, make_user, "lena")
    shop.subscriptions[TOKEN] = sub(days=30)
    verify(client, headers)
    revoked = client.delete(f"/api/admin/users/{user['id']}/premium", headers=admin_headers)
    assert revoked.json() == {"revoked": 1}
    status = premium(client, headers)
    assert status["active"] is False and status["offline_allowed"] is False and status["play"] is None
    listing = client.get("/api/admin/premium/purchases", headers=admin_headers).json()
    assert listing[0]["license_revoked"] is True

    # das Abo läuft bei Google weiter – übernehmen lässt es sich trotzdem nicht mehr
    again = verify(client, headers)
    assert again.status_code == 409 and again.json()["detail"] == "Dieser Kauf wurde vom Betreiber gesperrt."
    # und es wird nicht mehr geprüft (also auch nicht wiederbelebt)
    calls = shop.calls
    age_checks(client, hours=13)
    assert premium(client, headers)["active"] is False
    assert shop.calls == calls
    # „Neu prüfen“ im Dashboard hebt den Entzug nicht auf
    client.post(f"/api/admin/premium/purchases/{listing[0]['id']}/recheck", headers=admin_headers)
    assert premium(client, headers)["active"] is False
    with client.app.state.session_factory() as db:
        assert db.scalars(select(PremiumLicense)).unique().one().revoked_at is not None


def test_single_play_license_can_be_revoked(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable, shop: FakePlayVerifier
) -> None:
    _, headers = user_headers(client, make_user, "lena")
    shop.subscriptions[TOKEN] = sub(days=30)
    verify(client, headers)
    (row,) = purchases(client)
    response = client.post(f"/api/admin/premium/licenses/{row.license_id}/revoke", headers=admin_headers)
    assert response.json() == {"revoked": 1}
    assert premium(client, headers)["active"] is False
    assert verify(client, headers).status_code == 409


def test_resubscription_replaces_the_old_purchase_without_doubling(
    client: TestClient, make_user: Callable, shop: FakePlayVerifier
) -> None:
    _, lena = user_headers(client, make_user, "lena")
    _, tom = user_headers(client, make_user, "tom")
    shop.subscriptions[TOKEN] = sub(days=3)
    verify(client, lena)
    # neuer Abschluss/Tarifwechsel: Google nennt den alten Token als Vorgänger
    new = sub(days=30, linked=TOKEN)
    shop.subscriptions[OTHER_TOKEN] = new
    # ein anderes Konto kann den Nachfolger nicht an sich ziehen
    assert verify(client, tom, token=OTHER_TOKEN).status_code == 409
    body = verify(client, lena, token=OTHER_TOKEN).json()
    assert body["result"] == "active" and parse(body["premium"]["until"]) == new.expires_at
    old, fresh = purchases(client)
    assert old.state == "replaced" and old.license_id is None
    assert fresh.state == "active" and fresh.license_id is not None and fresh.linked_token_hash == hash_token(TOKEN)
    with client.app.state.session_factory() as db:
        assert len(list(db.scalars(select(PremiumLicense)).unique())) == 1, "kein doppeltes Premium"
    # der ersetzte Kauf wird nicht mehr geprüft
    calls = shop.calls
    age_checks(client, hours=13)
    premium(client, lena)
    assert shop.calls == calls + 1


def test_replacing_a_revoked_purchase_does_not_bring_premium_back(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable, shop: FakePlayVerifier
) -> None:
    user, headers = user_headers(client, make_user, "lena")
    shop.subscriptions[TOKEN] = sub(days=30)
    verify(client, headers)
    client.delete(f"/api/admin/users/{user['id']}/premium", headers=admin_headers)
    shop.subscriptions[OTHER_TOKEN] = sub(days=30, linked=TOKEN)
    assert verify(client, headers, token=OTHER_TOKEN).status_code == 409
    assert len(purchases(client)) == 1 and premium(client, headers)["active"] is False


def test_deleting_the_account_removes_its_purchases(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable, shop: FakePlayVerifier
) -> None:
    user, headers = user_headers(client, make_user, "lena")
    shop.subscriptions[TOKEN] = sub(days=30)
    verify(client, headers)
    assert client.delete(f"/api/users/{user['id']}", headers=admin_headers).status_code == 204
    assert purchases(client) == []
    # der Kauf kann danach von einem neuen Konto übernommen werden
    _, tom = user_headers(client, make_user, "tom")
    assert verify(client, tom).json()["result"] == "active"


# ------------------------------------------------------------------------------------- Dashboard-Endpunkte


def test_admin_can_recheck_a_purchase_immediately(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable, shop: FakePlayVerifier
) -> None:
    _, headers = user_headers(client, make_user, "lena")
    shop.subscriptions[TOKEN] = sub(days=30)
    verify(client, headers)
    purchase_id = purchases(client)[0].id
    url = f"/api/admin/premium/purchases/{purchase_id}/recheck"
    assert client.post(url, headers=headers).status_code == 403
    assert client.get("/api/admin/premium/purchases", headers=headers).status_code == 403
    missing = client.post("/api/admin/premium/purchases/9999/recheck", headers=admin_headers)
    assert missing.status_code == 404 and missing.json()["detail"] == "Kauf nicht gefunden."

    shop.subscriptions[TOKEN] = sub(state="expired", days=30, acknowledged=True)  # erstattet – ohne Wartezeit sichtbar
    checked = client.post(url, headers=admin_headers)
    assert checked.status_code == 200 and checked.json()["state"] == "expired"
    assert premium(client, headers)["active"] is False

    shop.fail = VerifierUnavailable("Google ist nicht erreichbar.")
    down = client.post(url, headers=admin_headers)
    assert down.status_code == 503 and down.json()["detail"].startswith("Google Play ist gerade nicht erreichbar.")
    assert client.get("/api/admin/premium/purchases", headers=admin_headers).json()[0]["last_error"] != ""
    client.app.state.purchase_verifier = None
    assert client.post(url, headers=admin_headers).status_code == 503


def test_billing_status_and_connection_test(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable, settings: Settings
) -> None:
    _, headers = user_headers(client, make_user, "lena")
    assert client.get("/api/admin/billing/status", headers=headers).status_code == 403
    assert client.post("/api/admin/billing/test", headers=headers).status_code == 403

    status = client.get("/api/admin/billing/status", headers=admin_headers).json()
    assert status == {
        "configured": False,
        "package_name": "de.selfify.selfify.play",
        "key_file": str(settings.play_service_account_file),
        "product_ids": [],
        "enabled": False,
    }
    test = client.post("/api/admin/billing/test", headers=admin_headers)
    assert test.status_code == 200
    assert test.json() == {"ok": False, "message": f"Schlüsseldatei fehlt: {settings.play_service_account_file}"}

    fake = FakePlayVerifier()
    client.app.state.purchase_verifier = fake
    put_config(client, admin_headers, billing_enabled=True, billing_product_ids=PRODUCT)
    status = client.get("/api/admin/billing/status", headers=admin_headers).json()
    assert status["configured"] is True and status["enabled"] is True and status["product_ids"] == [PRODUCT]
    assert client.post("/api/admin/billing/test", headers=admin_headers).json() == {
        "ok": True,
        "message": "Verbindung zu Google Play steht.",
    }
    fake.fail = VerifierUnavailable("Google ist nicht erreichbar.")
    assert client.post("/api/admin/billing/test", headers=admin_headers).json() == {
        "ok": False,
        "message": "Google ist nicht erreichbar.",
    }


def test_dashboard_and_privacy_page_know_about_purchases(client: TestClient) -> None:
    script = client.get("/web/dashboard.js").text
    for needle in (
        "offline_requires_premium", "offline_grace_days", "billing_enabled", "billing_product_ids", "premium_benefits",
        "/admin/billing/status", "/admin/billing/test", "/admin/premium/purchases", "Käufe über Google Play",
        "Offline-Hören an Premium binden?", "Das Abo läuft bei Google weiter",
    ):  # fmt: skip
        assert needle in script, needle
    assert ".innerHTML" not in script and "insertAdjacentHTML" not in script
    assert "Kaufst du Premium über" in client.get("/datenschutz").text


# ------------------------------------------------------------------------------------- Verbindung zu Google


@pytest.fixture(scope="module")
def rsa_key() -> rsa.RSAPrivateKey:
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)


def write_key_file(path: Path, key: rsa.RSAPrivateKey, **overrides: object) -> Path:
    pem = key.private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
    ).decode()
    data = {
        "type": "service_account",
        "client_email": "selfify@projekt.iam.gserviceaccount.com",
        "private_key": pem,
        "token_uri": "https://oauth2.googleapis.com/token",
        **overrides,
    }
    path.write_text(json.dumps(data), encoding="utf-8")
    return path


class FakeResponse:
    def __init__(self, status: int, body: object) -> None:
        self.status = status
        self._body = body if isinstance(body, bytes) else json.dumps(body).encode()

    def read(self) -> bytes:
        return self._body

    def __enter__(self) -> "FakeResponse":
        return self

    def __exit__(self, *_: object) -> None:
        return None


class FakeGoogle:
    """Spielt Google: OAuth-Endpunkt und Play Developer API. Merkt sich alle Anfragen."""

    def __init__(self) -> None:
        self.requests: list[Any] = []
        self.api: Callable[[Any], FakeResponse] = lambda request: FakeResponse(200, {})
        self.token_status = 200
        self.timeouts: list[float] = []

    def __call__(self, request: Any, timeout: float = 0) -> FakeResponse:
        self.requests.append(request)
        self.timeouts.append(timeout)
        if request.full_url == "https://oauth2.googleapis.com/token":
            if self.token_status != 200:
                raise urllib.error.HTTPError(request.full_url, self.token_status, "nein", None, None)  # type: ignore[arg-type]
            return FakeResponse(200, {"access_token": "zugriff-123", "expires_in": 3600, "token_type": "Bearer"})
        return self.api(request)

    def http_error(self, status: int) -> None:
        def _raise(request: Any) -> FakeResponse:
            raise urllib.error.HTTPError(request.full_url, status, "Fehler", None, None)  # type: ignore[arg-type]

        self.api = _raise


GOOGLE_ANSWER = {
    "kind": "androidpublisher#subscriptionPurchaseV2",
    "subscriptionState": "SUBSCRIPTION_STATE_ACTIVE",
    "acknowledgementState": "ACKNOWLEDGEMENT_STATE_PENDING",
    "latestOrderId": "GPA.3345-1234-5678-90123",
    "linkedPurchaseToken": "alter-token",
    "externalAccountIdentifiers": {"obfuscatedExternalAccountId": "7"},
    "testPurchase": {},
    "lineItems": [
        {
            "productId": "premium_monat",
            "expiryTime": "2026-12-11T09:00:00.123456789Z",
            "autoRenewingPlan": {"autoRenewEnabled": True},
        },
        {"productId": "zusatz", "expiryTime": "2026-12-01T09:00:00Z"},
    ],
}


def test_google_answer_is_translated(tmp_path: Path, rsa_key: rsa.RSAPrivateKey) -> None:
    info = parse_subscription(GOOGLE_ANSWER)
    assert info.state == "active" and info.product_ids == ("premium_monat", "zusatz")
    assert info.expires_at == datetime.fromisoformat("2026-12-11T09:00:00.123456+00:00")
    assert info.auto_renewing is True and info.acknowledged is False and info.is_test is True
    assert info.order_id == "GPA.3345-1234-5678-90123" and info.obfuscated_account_id == "7"
    assert info.linked_purchase_token == "alter-token"

    states = {
        "SUBSCRIPTION_STATE_CANCELED": "canceled",
        "SUBSCRIPTION_STATE_IN_GRACE_PERIOD": "grace",
        "SUBSCRIPTION_STATE_ON_HOLD": "on_hold",
        "SUBSCRIPTION_STATE_PAUSED": "paused",
        "SUBSCRIPTION_STATE_PENDING": "pending",
        "SUBSCRIPTION_STATE_EXPIRED": "expired",
        # unbekannte und künftige Zustände geben keinen Zugang
        "SUBSCRIPTION_STATE_UNSPECIFIED": "expired",
        "SUBSCRIPTION_STATE_PENDING_PURCHASE_CANCELED": "expired",
        "SUBSCRIPTION_STATE_NEU_ERFUNDEN": "expired",
    }
    for google, ours in states.items():
        assert parse_subscription({"subscriptionState": google}).state == ours
    bare = parse_subscription({})
    assert bare.state == "expired" and bare.expires_at is None and bare.product_ids == ()
    assert bare.is_test is False and bare.acknowledged is False and bare.obfuscated_account_id == ""
    with pytest.raises(VerifierUnavailable):
        parse_subscription(["kaputt"])


def test_real_verifier_signs_in_with_the_service_account_and_asks_google(
    tmp_path: Path, rsa_key: rsa.RSAPrivateKey
) -> None:
    key_file = write_key_file(tmp_path / "konto.json", rsa_key)
    google = FakeGoogle()
    google.api = lambda request: FakeResponse(200, GOOGLE_ANSWER)
    verifier = GooglePlayVerifier("de.selfify.selfify.play", key_file, opener=google)
    token = "tok/mit+sonder zeichen=="
    info = verifier.get_subscription(token)
    assert info.state == "active" and info.product_ids[0] == "premium_monat"

    oauth, call = google.requests
    form = urllib.parse.parse_qs(oauth.data.decode())
    assert form["grant_type"] == ["urn:ietf:params:oauth:grant-type:jwt-bearer"]
    claims = jwt.decode(
        form["assertion"][0], rsa_key.public_key(), algorithms=["RS256"], audience="https://oauth2.googleapis.com/token"
    )
    assert claims["iss"] == "selfify@projekt.iam.gserviceaccount.com"
    assert claims["scope"] == "https://www.googleapis.com/auth/androidpublisher"
    assert claims["exp"] - claims["iat"] == 3600
    assert call.get_method() == "GET"
    assert call.full_url == (
        "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/de.selfify.selfify.play"
        "/purchases/subscriptionsv2/tokens/tok%2Fmit%2Bsonder%20zeichen%3D%3D"
    )
    assert call.get_header("Authorization") == "Bearer zugriff-123"
    assert google.timeouts == [10, 10]

    # das Zugriffstoken wird wiederverwendet
    verifier.acknowledge("premium_monat", token)
    assert len(google.requests) == 3
    ack = google.requests[2]
    assert ack.get_method() == "POST" and ack.data == b"{}"
    assert ack.full_url.endswith(
        "/purchases/subscriptions/premium_monat/tokens/tok%2Fmit%2Bsonder%20zeichen%3D%3D:acknowledge"
    )
    # „Verbindung testen“ holt bewusst ein frisches
    verifier.check_access()
    assert google.requests[3].full_url == "https://oauth2.googleapis.com/token"


def test_real_verifier_tells_unknown_purchases_from_outages(tmp_path: Path, rsa_key: rsa.RSAPrivateKey) -> None:
    key_file = write_key_file(tmp_path / "konto.json", rsa_key)
    google = FakeGoogle()
    verifier = GooglePlayVerifier("de.selfify.selfify.play", key_file, opener=google)
    secret_token = "geheimer-kauf-token-123"
    for status in (400, 404, 410):
        google.http_error(status)
        with pytest.raises(PurchaseNotFound) as missing:
            verifier.get_subscription(secret_token)
        # nur 410 heißt eindeutig „Token gilt nicht mehr“; 400/404 kann auch ein falscher Paketname sein
        assert missing.value.definite is (status == 410)
    for status in (401, 403):
        google.http_error(status)
        with pytest.raises(VerifierUnavailable) as rejected:
            verifier.get_subscription(secret_token)
        assert str(rejected.value) == (
            f"Google lehnt den Schlüssel ab ({status}). Hat das Dienstkonto in der Play Console Zugriff auf die App?"
        )
    for status in (429, 500, 503):
        google.http_error(status)
        with pytest.raises(VerifierUnavailable) as down:
            verifier.get_subscription(secret_token)
        assert str(down.value) == "Google ist nicht erreichbar."

    def offline(request: Any) -> FakeResponse:
        raise urllib.error.URLError(TimeoutError("timed out"))

    google.api = offline
    with pytest.raises(VerifierUnavailable) as unreachable:
        verifier.get_subscription(secret_token)
    google.api = lambda request: FakeResponse(200, b"<html>kein json</html>")
    with pytest.raises(VerifierUnavailable) as broken:
        verifier.get_subscription(secret_token)
    # weder Token noch Schlüssel tauchen in Meldungen auf
    private_key = json.loads(key_file.read_text())["private_key"]
    for error in (rejected.value, down.value, unreachable.value, broken.value):
        assert secret_token not in str(error) and private_key[:40] not in str(error)
        # auch nicht über eine angehängte Ursache (die Adresse der Anfrage enthält den Token)
        assert error.__cause__ is None and (error.__context__ is None or error.__suppress_context__)

    # Google lehnt schon die Anmeldung ab
    google.token_status = 401
    with pytest.raises(VerifierUnavailable) as denied:
        verifier.check_access()
    assert "Google lehnt den Schlüssel ab (401)" in str(denied.value)


def test_key_file_problems_mean_not_configured(
    tmp_path: Path, rsa_key: rsa.RSAPrivateKey, settings: Settings
) -> None:
    def with_file(path: Path) -> Settings:
        return settings.model_copy(update={"play_service_account_file": path})

    assert build_verifier(with_file(tmp_path / "fehlt.json")) is None
    broken = tmp_path / "kaputt.json"
    broken.write_text("{ kein json", encoding="utf-8")
    assert build_verifier(with_file(broken)) is None
    broken.write_text(json.dumps({"client_email": "a@b"}), encoding="utf-8")
    assert build_verifier(with_file(broken)) is None
    broken.write_text(json.dumps(["liste"]), encoding="utf-8")
    assert build_verifier(with_file(broken)) is None
    # der Schlüssel darf nur verschlüsselt und nur an eine Webadresse gehen
    for name, uri in (("http.json", "http://x/token"), ("file.json", "file:///etc/passwd")):
        assert build_verifier(with_file(write_key_file(tmp_path / name, rsa_key, token_uri=uri))) is None
    assert isinstance(build_verifier(with_file(write_key_file(tmp_path / "gut.json", rsa_key))), GooglePlayVerifier)

    # Schlüssel in der Datei ist kein Schlüssel: verständliche Meldung, ohne den Inhalt zu zeigen
    bad_key = write_key_file(tmp_path / "falsch.json", rsa_key, private_key="-----BEGIN PRIVATE KEY-----\nGEHEIM\n")
    with pytest.raises(VerifierUnavailable) as invalid:
        GooglePlayVerifier("paket", bad_key, opener=FakeGoogle()).check_access()
    assert str(invalid.value) == "Schlüsseldatei ist ungültig." and "GEHEIM" not in str(invalid.value)


def test_key_file_added_while_the_server_runs_is_picked_up(tmp_path: Path, rsa_key: rsa.RSAPrivateKey) -> None:
    key_file = tmp_path / "data" / "play-service-account.json"
    settings = Settings(
        _env_file=None, data_dir=tmp_path / "data", media_dir=tmp_path / "media", admin_username="admin",
        admin_password=ADMIN_PASSWORD, log_level="WARNING", scan_on_startup=False, library_watch=False,
        scan_interval_minutes=0, ytdl_auto_update=False, play_service_account_file=key_file,
    )  # fmt: skip
    with TestClient(create_app(settings)) as client:
        admin = bearer(login(client, "admin", ADMIN_PASSWORD))
        assert client.get("/api/admin/billing/status", headers=admin).json()["configured"] is False
        key_file.write_text("{}", encoding="utf-8")
        assert client.post("/api/admin/billing/test", headers=admin).json() == {
            "ok": False,
            "message": "Schlüsseldatei ist ungültig.",
        }
        write_key_file(key_file, rsa_key)
        status = client.get("/api/admin/billing/status", headers=admin)
        assert status.json()["configured"] is True
        # der Inhalt der Datei verlässt den Server nie
        assert "PRIVATE KEY" not in status.text and "gserviceaccount" not in status.text


def test_injected_verifier_is_used(settings: Settings) -> None:
    fake = FakePlayVerifier()
    app = create_app(settings, purchase_verifier=fake)
    assert app.state.purchase_verifier is fake
    assert play_billing.current_verifier(app.state, settings) is fake
    app.state.engine.dispose()


# ------------------------------------------------------------------------------------- Migration


def test_migration_0007_keeps_existing_data_and_matches_the_models(tmp_path: Path) -> None:
    db_file = tmp_path / "migration.db"
    url = f"sqlite:///{db_file}"
    config = alembic_config(url)
    command.upgrade(config, "0006")
    now = "2026-11-10 12:00:00.000000"
    with sqlite3.connect(db_file) as con:
        for user_id, name in ((1, "admin"), (2, "lena")):
            con.execute(
                "INSERT INTO users (id, username, display_name, password_hash, is_admin, is_active, can_download, "
                "created_at, updated_at) VALUES (?, ?, ?, 'x', ?, 1, 1, ?, ?)",
                (user_id, name, name.title(), int(user_id == 1), now, now),
            )
        con.execute(
            "INSERT INTO premium_codes (id, code, label, duration_days, max_redemptions, redeemed_count, created_at) "
            "VALUES (1, 'AAAABBBBCCCC', 'Geburtstag', 30, 1, 1, ?)",
            (now,),
        )
        con.execute(
            "INSERT INTO premium_licenses (id, user_id, code_id, source, starts_at, expires_at, note, created_at) "
            "VALUES (1, 2, 1, 'code', ?, '2027-01-01 00:00:00.000000', 'Geburtstag', ?)",
            (now, now),
        )
        con.execute(
            "INSERT INTO premium_licenses (id, user_id, code_id, source, starts_at, note, created_at) "
            "VALUES (2, 2, NULL, 'admin', ?, '', ?)",
            (now, now),
        )
        con.execute("INSERT INTO app_settings (key, value, updated_at) VALUES ('ads_enabled', '1', ?)", (now,))
    before = sqlite3.connect(db_file)
    licenses_before = before.execute("SELECT * FROM premium_licenses ORDER BY id").fetchall()
    before.close()

    command.upgrade(config, "0007")
    with sqlite3.connect(db_file) as con:
        con.execute("PRAGMA foreign_keys=ON")
        # Bestandsdaten sind unverändert
        assert con.execute("SELECT * FROM premium_licenses ORDER BY id").fetchall() == licenses_before
        assert con.execute("SELECT count(*) FROM users").fetchone()[0] == 2
        assert con.execute("SELECT value FROM app_settings WHERE key = 'ads_enabled'").fetchone()[0] == "1"
        # keine neuen Schalter in der Datenbank: Es gelten die Standardwerte (alles aus)
        assert con.execute("SELECT count(*) FROM app_settings").fetchone()[0] == 1
        assert con.execute("SELECT count(*) FROM play_purchases").fetchone()[0] == 0
        insert = (
            "INSERT INTO play_purchases (user_id, product_id, purchase_token, token_hash, order_id, state, "
            "auto_renewing, acknowledged, is_test, license_id, last_checked_at, last_error, created_at, updated_at) "
            "VALUES (?, 'premium_monat', 'tok', ?, '', 'active', 1, 1, 0, ?, ?, '', ?, ?)"
        )
        con.execute(insert, (2, "h" * 64, 2, now, now, now))
        with pytest.raises(sqlite3.IntegrityError):  # ein Kauf = ein Konto
            con.execute(insert, (1, "h" * 64, None, now, now, now))
        # Lizenz gelöscht -> Kauf bleibt (ohne Lizenz); Konto gelöscht -> Kauf weg
        con.execute("DELETE FROM premium_licenses WHERE id = 2")
        assert con.execute("SELECT license_id FROM play_purchases").fetchone()[0] is None
        con.execute("DELETE FROM users WHERE id = 2")
        assert con.execute("SELECT count(*) FROM play_purchases").fetchone()[0] == 0

    # Modelle und Datenbank stimmen überein (sonst hätte jemand eine Migration vergessen)
    engine = create_engine(url)
    with engine.connect() as connection:
        context = MigrationContext.configure(connection, opts={"compare_type": True, "render_as_batch": True})
        assert compare_metadata(context, Base.metadata) == []
    engine.dispose()

    # zurück: Die Tabelle verschwindet, Lizenzen aus Käufen bleiben als Historie – aber so, dass die Vorversion sie
    # versteht (sie kennt nur "code" und "admin") und nichts ungeprüft weiterläuft
    with sqlite3.connect(db_file) as con:
        for license_id, expires in ((9, "2099-12-01 00:00:00.000000"), (10, "2020-01-01 00:00:00.000000")):
            con.execute(
                "INSERT INTO premium_licenses (id, user_id, code_id, source, starts_at, expires_at, note, created_at) "
                "VALUES (?, 1, NULL, 'play', ?, ?, 'Google Play: premium_monat', ?)",
                (license_id, now, expires, now),
            )
        others_before = con.execute("SELECT * FROM premium_licenses WHERE source != 'play' ORDER BY id").fetchall()
    command.downgrade(config, "0006")
    with sqlite3.connect(db_file) as con:
        tables = {row[0] for row in con.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
        assert "play_purchases" not in tables
        assert con.execute("SELECT count(*) FROM premium_licenses WHERE source = 'play'").fetchone()[0] == 0
        running, ended = con.execute(
            "SELECT source, note, expires_at FROM premium_licenses WHERE id IN (9, 10) ORDER BY id"
        ).fetchall()
        note = "Abo über Google Play (beendet beim Rücksprung) – Google Play: premium_monat"
        assert running[:2] == ("admin", note) and ended[:2] == ("admin", note)
        # die laufende endet jetzt (niemand prüft dort mehr bei Google), die längst beendete bleibt, wie sie war
        ended_at = datetime.fromisoformat(running[2])
        assert abs(ended_at - utcnow().replace(tzinfo=None)) < timedelta(minutes=5)
        assert ended[2] == "2020-01-01 00:00:00.000000"
        # Lizenzen aus Codes und vom Admin sind unberührt
        unchanged = con.execute("SELECT * FROM premium_licenses WHERE id NOT IN (9, 10) ORDER BY id").fetchall()
        assert unchanged == others_before
    command.upgrade(config, "head")


def test_server_with_existing_data_starts_unchanged_after_the_update(settings: Settings) -> None:
    """Ein laufender Server (Stand 0006) bekommt das Update: Benutzer, Premium und Antworten bleiben, wie sie waren."""
    settings.data_dir.mkdir(parents=True, exist_ok=True)
    command.upgrade(alembic_config(settings.database_url), "0006")
    with TestClient(create_app(settings)) as client:  # der Start zieht 0007 nach
        admin = bearer(login(client, "admin", ADMIN_PASSWORD))
        created = client.post("/api/users", headers=admin, json={"username": "lena", "password": "kinder-passwort"})
        assert created.status_code == 201
        headers = bearer(login(client, "lena", "kinder-passwort"))
        (code,) = new_codes(client, admin, duration_days=30)
        assert redeem(client, headers, code["code"]).status_code == 200
        status = premium(client, headers)
        assert status["active"] is True and status["offline_allowed"] is True and status["play"] is None
        assert client.get("/api/admin/premium/purchases", headers=admin).json() == []
