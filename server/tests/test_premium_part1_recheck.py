"""Restpunkte aus der Nachprüfung von „Premium Teil 1“: Nachprüfen trotz Störung, Hinweis für den Admin bei 400/404,
kein 426 für Abonnenten rund um die Verlängerung, gescheitertes Bestätigen in der Kaufliste."""

from collections.abc import Callable
from datetime import timedelta

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select

from app.models import PlayPurchase
from app.services import play_billing
from app.services.play_billing import PurchaseNotFound, VerifierUnavailable

from .fake_play import FakePlayVerifier, sub
from .test_billing_offline import (
    TOKEN,
    age_checks,
    fake,  # noqa: F401  (Fixture)
    premium,
    purchases,
    put_config,
    shop,  # noqa: F401  (Fixture)
    verify,
)
from .test_premium import parse, user_headers
from .test_premium_part1_fixes import app_header, move_expiry, stream


def admin_purchases(client: TestClient, admin_headers: dict[str, str]) -> list[dict]:
    response = client.get("/api/admin/premium/purchases", headers=admin_headers)
    assert response.status_code == 200, response.text
    return response.json()


# ------------------------------------------------------------------------------------- 400/404, dann Störung


@pytest.mark.parametrize("by", ["app", "admin"])
def test_an_outage_does_not_drop_a_not_found_purchase_from_the_rechecks(
    client: TestClient,
    admin_headers: dict[str, str],
    make_user: Callable,
    shop: FakePlayVerifier,  # noqa: F811
    by: str,
) -> None:
    _, headers = user_headers(client, make_user, "lena")
    shop.subscriptions[TOKEN] = sub(days=30)
    verify(client, headers)
    # falscher Paketname, einige Tage über das bezahlte Ende hinaus: Der Kauf gilt als beendet
    shop.fail = PurchaseNotFound(definite=False)
    move_expiry(client, checked=timedelta(hours=13), days=-4)
    assert premium(client, headers)["active"] is False
    (row,) = purchases(client)
    assert row.state == "expired" and row.last_error == play_billing.MSG_NOT_FOUND_ON_RECHECK

    # die nächste Nachprüfung trifft auf eine Störung bei Google
    shop.fail = VerifierUnavailable("Google ist nicht erreichbar.")
    age_checks(client, hours=13)
    calls = shop.calls
    if by == "app":
        assert premium(client, headers)["active"] is False
    else:
        down = client.post(f"/api/admin/premium/purchases/{row.id}/recheck", headers=admin_headers)
        assert down.status_code == 503
    assert shop.calls == calls + 1
    (row,) = purchases(client)
    # der Admin sieht beides: warum der Kauf beendet ist und woran die letzte Nachprüfung scheiterte
    assert row.state == "expired" and row.last_error.startswith(play_billing.MSG_NOT_FOUND_ON_RECHECK)
    assert row.last_error.endswith("Letzte Nachprüfung: Google ist nicht erreichbar.") and len(row.last_error) <= 300

    # Störung vorbei, Paketname stimmt wieder: Der Kauf wird weiter nachgeprüft und lebt von selbst auf
    shop.fail = None
    renewed = sub(days=30, acknowledged=True)
    shop.subscriptions[TOKEN] = renewed
    client.app.state.billing_backoff.clear()
    back = premium(client, headers)
    assert back["active"] is True and parse(back["until"]) == renewed.expires_at
    (row,) = purchases(client)
    assert row.state == "active" and row.last_error == ""


def test_a_purchase_google_reported_as_over_is_not_rechecked_after_an_outage(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable, shop: FakePlayVerifier  # noqa: F811
) -> None:
    """Gegenprobe: Das Merkmal entsteht nicht durch eine Störung – ein von Google beendeter Kauf bleibt beendet."""
    _, headers = user_headers(client, make_user, "lena")
    shop.subscriptions[TOKEN] = sub(days=30)
    verify(client, headers)
    shop.subscriptions[TOKEN] = sub(state="expired", days=-1, acknowledged=True)
    age_checks(client, hours=13)
    assert premium(client, headers)["active"] is False
    (row,) = purchases(client)
    shop.fail = VerifierUnavailable("Google ist nicht erreichbar.")
    assert client.post(f"/api/admin/premium/purchases/{row.id}/recheck", headers=admin_headers).status_code == 503
    assert purchases(client)[0].last_error == "Google ist nicht erreichbar."
    age_checks(client, hours=13)
    calls = shop.calls
    assert premium(client, headers)["active"] is False and shop.calls == calls


# ------------------------------------------------------------------------------------- „Neu prüfen“ im Dashboard


def test_admin_recheck_names_the_package_name_on_an_unclear_not_found(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable, shop: FakePlayVerifier  # noqa: F811
) -> None:
    _, headers = user_headers(client, make_user, "lena")
    shop.subscriptions[TOKEN] = sub(days=30)
    verify(client, headers)
    (row,) = purchases(client)
    shop.fail = PurchaseNotFound(definite=False)
    unclear = client.post(f"/api/admin/premium/purchases/{row.id}/recheck", headers=admin_headers)
    assert unclear.status_code == 503
    detail = unclear.json()["detail"]
    assert detail == play_billing.MSG_NOT_FOUND_ON_RECHECK and "PLAY_PACKAGE_NAME" in detail
    assert "wiederherstellen" not in detail and "Dein Kauf" not in detail
    # nichts ist beendet, der Hinweis steht auch in der Kaufliste
    (item,) = admin_purchases(client, admin_headers)
    assert item["state"] == "active" and item["last_error"] == detail
    # der Benutzer bekommt weiter nur „unbekannt“ – ohne Hinweise auf die Einstellungen des Servers
    age_checks(client, hours=13)
    unknown = client.get("/api/premium", headers=headers)
    assert unknown.status_code == 503 and unknown.json()["detail"] == play_billing.MSG_STATUS_UNKNOWN


# ------------------------------------------------------------------------------------- Stream: kein 426 für Abonnenten


def set_purchase(client: TestClient, **values: object) -> None:
    with client.app.state.session_factory() as db:
        for row in db.scalars(select(PlayPurchase)).unique():
            for key, value in values.items():
                setattr(row, key, value)
        db.commit()


def test_a_subscriber_around_the_renewal_never_gets_426(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable, shop: FakePlayVerifier  # noqa: F811
) -> None:
    user, headers = user_headers(client, make_user, "lena")
    put_config(client, admin_headers, offline_min_client_build=60)
    old = {**headers, **app_header(59)}
    assert stream(client, old).status_code == 426
    shop.subscriptions[TOKEN] = sub(days=30)
    verify(client, headers)
    assert stream(client, old).status_code == 404

    # Zeitraum seit zwei Stunden um, die App hat den Premium-Stand seitdem nicht abgefragt: Die Lizenz ist lokal
    # abgelaufen, ob Google verlängert hat, weiß der Server noch nicht – der Abonnent hört weiter
    move_expiry(client, checked=timedelta(hours=3), hours=-2)
    calls = shop.calls
    assert stream(client, old).status_code == 404
    # auch als gekündigt gemerkt: Er kann die Kündigung bei Google zurückgenommen haben
    set_purchase(client, state="canceled", auto_renewing=False)
    assert stream(client, old).status_code == 404
    set_purchase(client, state="active", auto_renewing=True)
    # Google hat nach dem Ablauf geantwortet und meldet das Abo weiter als laufend (Verlängerung nicht verbucht)
    move_expiry(client, checked=timedelta(minutes=1), minutes=-30)
    assert stream(client, old).status_code == 404
    # der Stream-Endpunkt fragt Google nie
    assert shop.calls == calls

    # klarer Stand ohne Zugang: wieder 426
    move_expiry(client, checked=timedelta(minutes=1), hours=-2)  # Toleranz für die Verlängerung vorbei
    assert stream(client, old).status_code == 426
    move_expiry(client, checked=timedelta(hours=3), hours=-2)
    for state in ("on_hold", "paused", "pending", "expired", "replaced"):
        set_purchase(client, state=state)
        assert stream(client, old).status_code == 426, state
    # zu alt, um noch nachgeprüft zu werden
    set_purchase(client, state="active")
    move_expiry(client, checked=timedelta(days=62), days=-61)
    assert stream(client, old).status_code == 426
    # vom Admin entzogen
    move_expiry(client, checked=timedelta(hours=3), hours=-2)
    assert stream(client, old).status_code == 404
    client.delete(f"/api/admin/users/{user['id']}/premium", headers=admin_headers)
    assert stream(client, old).status_code == 426
    assert shop.calls == calls


# ------------------------------------------------------------------------------------- Bestätigen gescheitert


@pytest.mark.parametrize(
    ("error", "reason"),
    [
        (VerifierUnavailable("Google ist nicht erreichbar."), "Google ist nicht erreichbar."),
        (PurchaseNotFound(definite=False), play_billing.MSG_ACKNOWLEDGE_NOT_FOUND),
    ],
)
def test_a_failed_acknowledge_shows_up_in_the_purchase_list(
    client: TestClient,
    admin_headers: dict[str, str],
    make_user: Callable,
    shop: FakePlayVerifier,  # noqa: F811
    error: Exception,
    reason: str,
) -> None:
    _, headers = user_headers(client, make_user, "lena")
    shop.subscriptions[TOKEN] = sub()
    shop.fail_acknowledge = error
    assert verify(client, headers).json()["result"] == "active"
    (item,) = admin_purchases(client, admin_headers)
    assert item["acknowledged"] is False and item["state"] == "active"
    assert item["last_error"] == f"{play_billing.MSG_ACKNOWLEDGE_FAILED} {reason}"
    assert "erstattet" in item["last_error"] and TOKEN not in item["last_error"]
    # auch nach dem nächsten gescheiterten Versuch noch
    age_checks(client, minutes=11)
    assert premium(client, headers)["active"] is True
    assert admin_purchases(client, admin_headers)[0]["last_error"].startswith(play_billing.MSG_ACKNOWLEDGE_FAILED)
    # klappt das Bestätigen, verschwindet die Meldung
    shop.fail_acknowledge = None
    age_checks(client, minutes=11)
    assert premium(client, headers)["active"] is True
    (item,) = admin_purchases(client, admin_headers)
    assert item["acknowledged"] is True and item["last_error"] == ""
