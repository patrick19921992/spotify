"""Web-Seiten: Dashboard, Datenschutz, Impressum, „Konto löschen“ – Auslieferung, Header und Escapen."""

from collections.abc import Iterator
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app

from .conftest import ADMIN_PASSWORD, bearer, login


def assert_strict_headers(response) -> None:  # type: ignore[no-untyped-def]
    csp = response.headers["content-security-policy"]
    assert "default-src 'none'" in csp
    assert "script-src 'self'" in csp
    assert "unsafe-inline" not in csp and "unsafe-eval" not in csp
    assert "frame-ancestors 'none'" in csp
    assert response.headers["x-content-type-options"] == "nosniff"
    assert response.headers["referrer-policy"] == "no-referrer"


def test_dashboard_page_and_assets(client: TestClient) -> None:
    page = client.get("/dashboard")
    assert page.status_code == 200
    assert page.headers["content-type"].startswith("text/html")
    assert '<script src="/web/dashboard.js">' in page.text
    assert_strict_headers(page)
    # Die Seite braucht ohne Anmeldung nichts Geheimes – die Daten kommen erst über die API mit Token
    assets = (
        ("dashboard.js", "javascript"), ("dashboard.css", "css"), ("legal.js", "javascript"), ("legal.css", "css")
    )
    for name, kind in assets:
        asset = client.get(f"/web/{name}")
        assert asset.status_code == 200, name
        assert kind in asset.headers["content-type"]
        assert_strict_headers(asset)
        assert len(asset.content) > 100


@pytest.mark.parametrize(
    "name", ["../main.py", "..%2Fmain.py", "legal.py", "__init__.py", "dashboard.html", "nichts.js"]
)
def test_assets_are_a_whitelist(client: TestClient, name: str) -> None:
    assert client.get(f"/web/{name}").status_code == 404


def test_dashboard_can_be_switched_off(settings: Settings) -> None:
    off = settings.model_copy(update={"dashboard_enabled": False})
    with TestClient(create_app(off)) as client:
        assert client.get("/dashboard").status_code == 404
        # Datenschutz und „Konto löschen“ sind Pflicht und bleiben erreichbar
        assert client.get("/datenschutz").status_code == 200
        assert client.get("/konto-loeschen").status_code == 200


def test_legal_pages(client: TestClient) -> None:
    for path, needle in (("/datenschutz", "Datenschutz"), ("/impressum", "Impressum"), ("/konto-loeschen", "löschen")):
        page = client.get(path)
        assert page.status_code == 200, path
        assert needle in page.text
        assert_strict_headers(page)
        assert 'href="/web/legal.css"' in page.text
        assert "<script>" not in page.text and "onclick" not in page.text  # keine Inline-Skripte
    assert 'src="/web/legal.js"' in client.get("/konto-loeschen").text
    assert 'id="delete-form"' in client.get("/konto-loeschen").text


@pytest.fixture
def operator_client(settings: Settings) -> Iterator[TestClient]:
    configured = settings.model_copy(
        update={
            "operator_name": 'Max <b>Muster</b> & "Söhne"',
            "operator_address": "Weg 1<script>alert(1)</script>",
            "operator_email": "post@example.org",
            "server_name": "<img src=x onerror=alert(1)>",
        }
    )
    with TestClient(create_app(configured)) as test_client:
        yield test_client


def test_operator_details_are_escaped(operator_client: TestClient) -> None:
    for path in ("/datenschutz", "/impressum", "/konto-loeschen"):
        text = operator_client.get(path).text
        assert "<script>alert(1)" not in text, path
        assert "<img src=x" not in text, path
        assert "<b>Muster</b>" not in text, path
    imprint = operator_client.get("/impressum").text
    assert "Max &lt;b&gt;Muster&lt;/b&gt; &amp; &quot;Söhne&quot;" in imprint
    assert "post@example.org" in imprint
    # Sind die Angaben gesetzt, erscheint kein Hinweis „Angaben fehlen“
    assert "OPERATOR_NAME" not in imprint and "Hinweis für den Betreiber" not in imprint


def test_missing_operator_details_are_pointed_out(client: TestClient) -> None:
    text = client.get("/impressum").text
    assert "OPERATOR_NAME" in text


def test_public_config_links_point_to_the_pages(client: TestClient, settings: Settings) -> None:
    # Ohne PUBLIC_URL bleiben die Links leer – die App setzt dann die Adresse ihres Servers davor
    body = client.get("/api/app/config").json()
    assert body["privacy_url"] == "" and body["deletion_url"] == ""
    configured = settings.model_copy(update={"public_url": "https://musik.example.org"})
    with TestClient(create_app(configured)) as other:
        body = other.get("/api/app/config").json()
    assert body["privacy_url"] == "https://musik.example.org/datenschutz"
    assert body["deletion_url"] == "https://musik.example.org/konto-loeschen"


def test_static_files_exist_next_to_the_router() -> None:
    web = Path(__file__).resolve().parent.parent / "app" / "web"
    for name in ("dashboard.html", "dashboard.css", "dashboard.js", "legal.css", "legal.js"):
        assert (web / name).is_file(), name


def test_dashboard_api_needs_admin(client: TestClient, make_user) -> None:  # type: ignore[no-untyped-def]
    """Das Dashboard selbst ist öffentlich lesbar, seine Daten sind es nicht."""
    make_user("lena")
    member = bearer(login(client, "lena", "kinder-passwort"))
    admin = bearer(login(client, "admin", ADMIN_PASSWORD))
    paths = (
        "/api/admin/stats", "/api/admin/users", "/api/admin/clients", "/api/admin/config", "/api/admin/requests",
        "/api/admin/bugreports", "/api/admin/premium/codes", "/api/admin/premium/licenses",
    )
    for path in paths:
        assert client.get(path).status_code == 401, path
        assert client.get(path, headers=member).status_code == 403, path
        assert client.get(path, headers=admin).status_code == 200, path


def test_operator_email_cannot_break_out_of_the_mailto_attribute(settings: Settings) -> None:
    configured = settings.model_copy(
        update={"operator_name": "Max", "operator_email": 'a"onmouseover="alert(1)@example.org'}
    )
    with TestClient(create_app(configured)) as test_client:
        for path in ("/impressum", "/datenschutz"):
            text = test_client.get(path).text
            assert 'onmouseover="alert' not in text, path
            assert "&quot;onmouseover=" in text or "onmouseover" not in text, path


def test_registration_paths_are_public(client: TestClient) -> None:
    """Registrieren und Zurückziehen brauchen keine Anmeldung (und schon gar keinen Admin)."""
    off = client.post("/api/auth/register", json={"username": "neu", "password": "passwort-123"})
    assert off.status_code == 404  # Modus „aus“ – aber kein 401/403
    withdraw = client.post("/api/auth/withdraw", json={"username": "neu", "password": "passwort-123"})
    assert withdraw.status_code == 401
    assert withdraw.json()["detail"] == "Benutzername oder Passwort falsch."
    assert "www-authenticate" not in withdraw.headers


def test_dashboard_and_legal_cover_self_registration(client: TestClient) -> None:
    """Selbst-Registrierung: Dashboard (Registrierung, Freischalten, Rubriken), Datenschutz und „Konto löschen“."""
    script = client.get("/web/dashboard.js").text
    for text in (
        "Wer darf Konten anlegen?", "Aus – nur Admins legen Konten an",
        "Mit Freigabe – neue Konten warten, bis du sie freischaltest", "Offen – neue Konten sind sofort nutzbar",
        "Rubriken für neue Konten", "registration_default_categories", "Noch keine Rubriken angelegt.",
        "Ohne Auswahl sehen neue Konten nichts, bis du ihnen Rubriken freigibst.", "Registrierung öffnen?",
        "wartet auf Freigabe", "selbst registriert", "Alle (Admin)", "Freischalten…", "Freigeschaltet.",
        "Konto ablehnen?", "Abgelehnt und gelöscht.", "Rubriken…", "Alle Rubriken (auch künftige)", "Nur ausgewählte",
        "Rubriken gespeichert.", "users_pending",
    ):
        assert text in script, text
    assert ".innerHTML" not in script and "style:" not in script
    assert ".check-list" in client.get("/web/dashboard.css").text
    # Die Löschseite zieht wartende Konten über /auth/withdraw zurück
    legal_script = client.get("/web/legal.js").text
    assert "/api/auth/withdraw" in legal_script and "X-Selfify-Account-State" in legal_script
    privacy = client.get("/datenschutz").text
    assert "Das Konto wird vom Betreiber angelegt." not in privacy
    for text in ("Das Konto legt der Betreiber an.", "Für andere sichtbar:", "Registrierung zurückziehen"):
        assert text in privacy, text
    deletion = client.get("/konto-loeschen").text
    assert "Wartet dein Konto noch auf Freischaltung, wird es hier ebenfalls gelöscht." in deletion
