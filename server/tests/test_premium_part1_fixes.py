"""Korrekturen nach der Gegenprüfung von „Premium Teil 1“: Entzug bei Play-Lizenzen, unklare Antworten von Google,
Code hinter dem Abo, Konto-Neuanlage, Verlängerung – und die Mindest-Build-Nummer für die Offline-Sperre."""

from collections.abc import Callable
from dataclasses import replace
from datetime import timedelta

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select

from app.models import PlayPurchase, PremiumLicense, utcnow
from app.services import play_billing
from app.services.play_billing import PurchaseNotFound

from .conftest import bearer, login
from .fake_play import FakePlayVerifier, sub
from .test_billing_offline import (
    OTHER_TOKEN,
    TOKEN,
    age_checks,
    fake,  # noqa: F401  (Fixture)
    premium,
    purchases,
    put_config,
    shop,  # noqa: F401  (Fixture)
    verify,
)
from .test_premium import new_codes, parse, redeem, user_headers


def move_expiry(client: TestClient, *, checked: timedelta, **delta: float) -> None:
    """Tut so, als wäre der bezahlte Zeitraum (Kauf und Lizenz) um `delta` verschoben und zuletzt vor `checked`
    bei Google nachgesehen worden."""
    with client.app.state.session_factory() as db:
        for row in db.scalars(select(PlayPurchase)).unique():
            row.expires_at = utcnow() + timedelta(**delta)
            row.last_checked_at = utcnow() - checked
            assert row.license is not None
            row.license.expires_at = row.expires_at
        db.commit()


# ------------------------------------------------------------------------------------- Entzug


@pytest.mark.parametrize("lapsed", ["period_over", "on_hold"])
@pytest.mark.parametrize("how", ["everything", "single_license"])
def test_revoking_hits_a_play_license_that_is_only_momentarily_expired(
    client: TestClient,
    admin_headers: dict[str, str],
    make_user: Callable,
    shop: FakePlayVerifier,  # noqa: F811
    lapsed: str,
    how: str,
) -> None:
    user, headers = user_headers(client, make_user, "lena")
    shop.subscriptions[TOKEN] = sub(days=30)
    verify(client, headers)
    if lapsed == "period_over":
        # Zeitraum seit zwei Stunden um, die App war seitdem nicht offen (Google wurde also nicht gefragt)
        move_expiry(client, checked=timedelta(hours=3), hours=-2)
    else:
        shop.subscriptions[TOKEN] = sub(state="on_hold", days=20, acknowledged=True)
        age_checks(client, hours=13)
        assert premium(client, headers)["active"] is False
    (row,) = purchases(client)
    assert row.license is not None and row.license.expires_at <= utcnow()

    if how == "everything":
        revoked = client.delete(f"/api/admin/users/{user['id']}/premium", headers=admin_headers)
    else:
        revoked = client.post(f"/api/admin/premium/licenses/{row.license_id}/revoke", headers=admin_headers)
    assert revoked.json() == {"revoked": 1}

    # Google verlängert bzw. die Zahlung kommt: Das Premium bleibt weg, der Kauf wird nicht mehr geprüft
    shop.subscriptions[TOKEN] = sub(days=30, acknowledged=True)
    age_checks(client, hours=13)
    calls = shop.calls
    assert premium(client, headers)["active"] is False
    assert shop.calls == calls
    again = verify(client, headers)
    assert again.status_code == 409 and again.json()["detail"] == "Dieser Kauf wurde vom Betreiber gesperrt."
    assert premium(client, headers)["active"] is False


def test_revoking_leaves_long_expired_licenses_as_history(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable, shop: FakePlayVerifier  # noqa: F811
) -> None:
    user, headers = user_headers(client, make_user, "lena")
    (code,) = new_codes(client, admin_headers, duration_days=10)
    redeem(client, headers, code["code"])
    with client.app.state.session_factory() as db:
        license_ = db.scalars(select(PremiumLicense)).unique().one()
        license_.expires_at = utcnow() - timedelta(days=1)
        db.commit()
    assert client.delete(f"/api/admin/users/{user['id']}/premium", headers=admin_headers).json() == {"revoked": 0}


# ------------------------------------------------------------------------------------- 400/404 von Google


def test_an_unclear_not_found_does_not_end_a_running_purchase(
    client: TestClient, make_user: Callable, shop: FakePlayVerifier  # noqa: F811
) -> None:
    _, headers = user_headers(client, make_user, "lena")
    shop.subscriptions[TOKEN] = sub(days=30)
    verify(client, headers)
    # falscher Paketname: Google antwortet für jeden Kauf mit 400/404
    shop.fail = PurchaseNotFound(definite=False)
    age_checks(client, hours=13)
    # wie bei einer Störung: „unbekannt“ (503) statt „kein Premium“ – nichts endet, die App löscht nichts
    unknown = client.get("/api/premium", headers=headers)
    assert unknown.status_code == 503 and unknown.json()["detail"] == play_billing.MSG_STATUS_UNKNOWN
    (row,) = purchases(client)
    assert row.state == "active" and row.last_error == play_billing.MSG_NOT_FOUND_ON_RECHECK
    assert "PLAY_PACKAGE_NAME" in row.last_error
    assert row.license is not None and row.license.expires_at > utcnow() + timedelta(days=29)

    # auch kurz nach dem Ende des bezahlten Zeitraums noch
    move_expiry(client, checked=timedelta(hours=13), hours=-2)
    client.app.state.billing_backoff.clear()
    assert client.get("/api/premium", headers=headers).status_code == 503
    assert purchases(client)[0].state == "active"

    # Einstellung korrigiert: Der Kauf wird wieder gefunden, alles läuft weiter
    shop.fail = None
    renewed = sub(days=30, acknowledged=True)
    shop.subscriptions[TOKEN] = renewed
    client.app.state.billing_backoff.clear()
    back = premium(client, headers)
    assert back["active"] is True and parse(back["until"]) == renewed.expires_at
    assert purchases(client)[0].last_error == ""


def test_a_lasting_not_found_ends_the_purchase_but_it_is_still_looked_after(
    client: TestClient, make_user: Callable, shop: FakePlayVerifier  # noqa: F811
) -> None:
    _, headers = user_headers(client, make_user, "lena")
    shop.subscriptions[TOKEN] = sub(days=30)
    verify(client, headers)
    shop.fail = PurchaseNotFound(definite=False)
    # einige Tage über das bezahlte Ende hinaus kennt Google den Kauf nicht: Jetzt gilt er als beendet
    move_expiry(client, checked=timedelta(hours=13), days=-4)
    gone = premium(client, headers)
    assert gone["active"] is False and gone["play"] is None
    (row,) = purchases(client)
    assert row.state == "expired" and row.last_error == play_billing.MSG_NOT_FOUND_ON_RECHECK

    # … wird aber weiter nachgeprüft (gedrosselt), ohne dass daraus „unbekannt“ wird
    calls = shop.calls
    assert premium(client, headers)["active"] is False and shop.calls == calls
    age_checks(client, hours=13)
    assert premium(client, headers)["active"] is False and shop.calls == calls + 1

    # der Paketname stimmt wieder: Der Kauf lebt von selbst auf, niemand muss „Käufe wiederherstellen“ antippen
    shop.fail = None
    renewed = sub(days=30, acknowledged=True)
    shop.subscriptions[TOKEN] = renewed
    age_checks(client, hours=13)
    back = premium(client, headers)
    assert back["active"] is True and parse(back["until"]) == renewed.expires_at
    assert purchases(client)[0].state == "active"


def test_a_new_purchase_google_does_not_know_is_still_refused(
    client: TestClient, make_user: Callable, shop: FakePlayVerifier  # noqa: F811
) -> None:
    _, headers = user_headers(client, make_user, "lena")
    shop.fail = PurchaseNotFound(definite=False)
    assert verify(client, headers).status_code == 404
    assert purchases(client) == []


# ------------------------------------------------------------------------------------- Code hinter dem Abo


def test_refund_pulls_attached_licenses_forward_without_overlap(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable, shop: FakePlayVerifier  # noqa: F811
) -> None:
    user, headers = user_headers(client, make_user, "lena")
    grant = {"duration_days": 5, "note": "Probe"}
    assert client.post(f"/api/admin/users/{user['id']}/premium", headers=admin_headers, json=grant).status_code == 201
    info = sub(days=30)
    shop.subscriptions[TOKEN] = info
    verify(client, headers)
    (code,) = new_codes(client, admin_headers, duration_days=10)
    assert parse(redeem(client, headers, code["code"]).json()["until"]) == info.expires_at + timedelta(days=10)

    shop.subscriptions[TOKEN] = sub(state="expired", days=30, acknowledged=True)
    age_checks(client, hours=13)
    after = premium(client, headers)
    assert after["active"] is True
    with client.app.state.session_factory() as db:
        by_source = {lic.source: lic for lic in db.scalars(select(PremiumLicense)).unique()}
    # der Code schließt an die laufende Admin-Lizenz an (keine Lücke, keine verschenkten Tage)
    assert by_source["code"].starts_at == by_source["admin"].expires_at
    assert by_source["code"].expires_at - by_source["code"].starts_at == timedelta(days=10)
    assert parse(after["until"]) == by_source["code"].expires_at


# ------------------------------------------------------------------------------------- Konto-Neuanlage


def test_a_purchase_made_in_the_app_can_be_taken_over_after_the_account_was_deleted(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable, shop: FakePlayVerifier  # noqa: F811
) -> None:
    lena, headers = user_headers(client, make_user, "lena")
    # die App gibt beim Kauf die Benutzer-Nummer mit; Google liefert sie bei jeder Abfrage zurück
    shop.subscriptions[TOKEN] = sub(days=30, account=str(lena["id"]))
    assert verify(client, headers).json()["result"] == "active"
    # ein weiteres Konto, damit die Nummer des gelöschten nicht neu vergeben wird
    _, max_headers = user_headers(client, make_user, "max")
    # solange das Konto besteht, bekommt niemand sonst den Kauf
    assert verify(client, max_headers).status_code == 409
    assert client.delete(f"/api/users/{lena['id']}", headers=admin_headers).status_code == 204

    tom, tom_headers = user_headers(client, make_user, "tom")
    assert tom["id"] != lena["id"]
    taken = verify(client, tom_headers)
    assert taken.status_code == 200 and taken.json()["result"] == "active"
    assert purchases(client)[0].user_id == tom["id"]


def test_a_purchase_marked_for_an_existing_or_foreign_account_stays_refused(
    client: TestClient, make_user: Callable, shop: FakePlayVerifier  # noqa: F811
) -> None:
    lena, _ = user_headers(client, make_user, "lena")
    _, tom_headers = user_headers(client, make_user, "tom")
    shop.subscriptions[TOKEN] = sub(days=30, account=str(lena["id"]))
    shop.subscriptions[OTHER_TOKEN] = sub(days=30, account="kein-konto-von-hier")
    for token in (TOKEN, OTHER_TOKEN):
        refused = verify(client, tom_headers, token=token)
        assert refused.status_code == 409
        assert refused.json()["detail"] == "Dieser Kauf ist schon mit einem anderen Konto verbunden."
    assert purchases(client) == []


# ------------------------------------------------------------------------------------- Verlängerung


def test_renewal_between_two_requests_is_noticed_at_once(
    client: TestClient, make_user: Callable, shop: FakePlayVerifier  # noqa: F811
) -> None:
    _, headers = user_headers(client, make_user, "lena")
    shop.subscriptions[TOKEN] = sub(days=30)
    verify(client, headers)
    # Stand vor vier Minuten geprüft, Ablauf vor einer Minute – Google hat inzwischen verlängert
    move_expiry(client, checked=timedelta(minutes=4), minutes=-1)
    renewed = sub(days=30, acknowledged=True)
    shop.subscriptions[TOKEN] = renewed
    status = premium(client, headers)
    assert status["active"] is True and status["offline_allowed"] is True
    assert parse(status["until"]) == renewed.expires_at


def test_a_renewal_google_has_not_booked_yet_reads_as_unknown_not_as_no_premium(
    client: TestClient, make_user: Callable, shop: FakePlayVerifier  # noqa: F811
) -> None:
    _, headers = user_headers(client, make_user, "lena")
    shop.subscriptions[TOKEN] = sub(days=30)
    verify(client, headers)
    # Google meldet das Abo weiter als laufend, das Enddatum liegt aber eine Minute zurück
    late = replace(sub(days=30, acknowledged=True), expires_at=utcnow() - timedelta(minutes=1))
    shop.subscriptions[TOKEN] = late
    move_expiry(client, checked=timedelta(minutes=4), minutes=-1)
    calls = shop.calls
    unknown = client.get("/api/premium", headers=headers)
    assert unknown.status_code == 503 and unknown.json()["detail"] == play_billing.MSG_STATUS_UNKNOWN
    assert shop.calls == calls + 1
    # gleich noch einmal: weiter „unbekannt“, aber Google wird nicht bei jeder Anfrage gefragt
    assert client.get("/api/premium", headers=headers).status_code == 503
    assert shop.calls == calls + 1
    # auch „Käufe wiederherstellen“ meldet in dieser Lage nicht „kein Premium“
    assert verify(client, headers).status_code == 503

    # eine Minute später ist die Verlängerung da
    age_checks(client, minutes=2)
    renewed = sub(days=30, acknowledged=True)
    shop.subscriptions[TOKEN] = renewed
    assert parse(premium(client, headers)["until"]) == renewed.expires_at


def test_without_a_renewal_premium_ends_after_the_tolerance(
    client: TestClient, make_user: Callable, shop: FakePlayVerifier  # noqa: F811
) -> None:
    _, headers = user_headers(client, make_user, "lena")
    shop.subscriptions[TOKEN] = sub(days=30)
    verify(client, headers)
    shop.subscriptions[TOKEN] = replace(sub(days=30, acknowledged=True), expires_at=utcnow() - timedelta(hours=2))
    move_expiry(client, checked=timedelta(hours=3), hours=-2)
    status = premium(client, headers)
    assert status["active"] is False and status["offline_allowed"] is False
    # ein gekündigtes Abo endet am bezahlten Ende ohne Wartezeit
    shop.subscriptions[TOKEN] = replace(
        sub(state="canceled", days=30, acknowledged=True), expires_at=utcnow() - timedelta(minutes=1)
    )
    move_expiry(client, checked=timedelta(minutes=4), minutes=-1)
    assert premium(client, headers)["active"] is False


# ------------------------------------------------------------------------------------- Mindest-Build der App

CLIENT = "X-Selfify-Client"


def app_header(build: int) -> dict[str, str]:
    return {CLIENT: f"platform=android; channel=full; version=1.2.0; build={build}"}


def stream(client: TestClient, headers: dict[str, str]):  # type: ignore[no-untyped-def]
    # Titel 999 gibt es nicht: 404 heißt „durchgelassen“, 426 heißt „App zu alt“
    return client.get("/api/tracks/999/stream", headers=headers)


def test_min_client_build_is_a_setting_the_app_can_read(client: TestClient, admin_headers: dict[str, str]) -> None:
    assert client.get("/api/app/config").json()["offline_min_client_build"] == 0
    assert client.get("/api/admin/config", headers=admin_headers).json()["offline_min_client_build"] == 0
    assert put_config(client, admin_headers, offline_min_client_build=-1).status_code == 400
    assert put_config(client, admin_headers, offline_min_client_build=10_000_001).status_code == 400
    saved = put_config(client, admin_headers, offline_min_client_build=60)
    assert saved.status_code == 200 and saved.json()["offline_min_client_build"] == 60
    assert client.get("/api/app/config").json()["offline_min_client_build"] == 60
    assert saved.json()["offline_requires_premium"] is False


def test_old_apps_get_no_music_without_premium_while_the_lock_is_on(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable
) -> None:
    user, headers = user_headers(client, make_user, "lena")
    # Mindest-Build allein bewirkt nichts, der Schalter allein auch nicht
    put_config(client, admin_headers, offline_min_client_build=60)
    assert stream(client, headers).status_code == 404
    put_config(client, admin_headers, offline_min_client_build=0, offline_requires_premium=True)
    assert stream(client, headers).status_code == 404

    put_config(client, admin_headers, offline_min_client_build=60)
    for old in (headers, {**headers, **app_header(59)}, {**headers, CLIENT: "kaputt"}):
        refused = stream(client, old)
        assert refused.status_code == 426 and refused.json()["detail"] == "Bitte aktualisiere die App."
    assert stream(client, {**headers, **app_header(60)}).status_code == 404
    assert stream(client, {**headers, **app_header(75)}).status_code == 404
    # Admins nie
    assert stream(client, admin_headers).status_code == 404
    assert stream(client, {**admin_headers, **app_header(1)}).status_code == 404
    # mit Premium nie – egal wie alt die App ist
    client.post(f"/api/admin/users/{user['id']}/premium", headers=admin_headers, json={"unlimited": True})
    assert stream(client, headers).status_code == 404
    assert stream(client, {**headers, **app_header(1)}).status_code == 404
    # Premium entzogen: wieder gesperrt; Schalter aus: wieder frei
    client.delete(f"/api/admin/users/{user['id']}/premium", headers=admin_headers)
    assert stream(client, {**headers, **app_header(59)}).status_code == 426
    put_config(client, admin_headers, offline_requires_premium=False)
    assert stream(client, {**headers, **app_header(59)}).status_code == 404


def test_player_links_without_header_count_what_the_app_reported_on_this_device(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable
) -> None:
    make_user("lena")
    put_config(client, admin_headers, offline_requires_premium=True, offline_min_client_build=60)
    tokens = login(client, "lena", "kinder-passwort")
    link = {"t": tokens["media_token"]}
    # die App hat sich auf diesem Gerät noch mit keiner Build-Nummer gemeldet
    assert client.get("/api/tracks/999/stream", params=link).status_code == 426
    # alte App meldet Build 59
    client.get("/api/premium", headers={**bearer(tokens), **app_header(59)})
    assert client.get("/api/tracks/999/stream", params=link).status_code == 426
    # nach dem Update meldet sie Build 60: Der Player (Link ohne Header) bekommt wieder Musik
    client.get("/api/premium", headers={**bearer(tokens), **app_header(60)})
    assert client.get("/api/tracks/999/stream", params=link).status_code == 404
    # Cover bleiben für alle erreichbar (die App muss den Hinweis ja noch anzeigen können)
    assert client.get("/api/covers/" + "a" * 40, params=link).status_code == 404


def test_dashboard_and_deletion_page_explain_the_new_parts(client: TestClient) -> None:
    script = client.get("/web/dashboard.js").text
    for needle in ("offline_min_client_build", "Sperre durchsetzen ab App-Build", "Bitte aktualisiere die App."):
        assert needle in script, needle
    assert "Gilt für alle App-Versionen" not in script
    page = client.get("/konto-loeschen").text
    assert "kündigt ein laufendes Abo nicht" in page and "Google Play" in page
    assert "https://play.google.com/store/account/subscriptions" in page
