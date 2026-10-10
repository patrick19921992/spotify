from datetime import timedelta

from fastapi.testclient import TestClient

from app.models import UserSession
from app.services import auth as auth_service

from .conftest import ADMIN_PASSWORD, bearer, login


def test_login_and_me(client: TestClient) -> None:
    tokens = login(client, "Admin", ADMIN_PASSWORD)  # Groß-/Kleinschreibung egal
    assert tokens["user"]["username"] == "admin"
    assert tokens["user"]["is_admin"] is True
    me = client.get("/api/me", headers=bearer(tokens))
    assert me.status_code == 200
    assert me.json()["username"] == "admin"


def test_wrong_password_and_unknown_user(client: TestClient) -> None:
    for username in ("admin", "gibtsnicht"):
        response = client.post("/api/auth/login", json={"username": username, "password": "falsch-falsch"})
        assert response.status_code == 401
        assert response.json()["detail"] == "Benutzername oder Passwort falsch."


def test_requires_token(client: TestClient) -> None:
    assert client.get("/api/me").status_code == 401
    assert client.get("/api/me", headers={"Authorization": "Bearer kaputt"}).status_code == 401


def test_refresh_rotates_token(client: TestClient) -> None:
    tokens = login(client, "admin", ADMIN_PASSWORD)
    refreshed = client.post("/api/auth/refresh", json={"refresh_token": tokens["refresh_token"]})
    assert refreshed.status_code == 200
    new_tokens = refreshed.json()
    assert new_tokens["refresh_token"] != tokens["refresh_token"]
    assert client.get("/api/me", headers=bearer(new_tokens)).status_code == 200
    # Neuer Token funktioniert weiter
    again = client.post("/api/auth/refresh", json={"refresh_token": new_tokens["refresh_token"]})
    assert again.status_code == 200


def test_old_refresh_token_within_grace_period(client: TestClient) -> None:
    """Wenn die Antwort am Handy verloren geht, darf der alte Token kurz noch einmal benutzt werden."""
    tokens = login(client, "admin", ADMIN_PASSWORD)
    first = client.post("/api/auth/refresh", json={"refresh_token": tokens["refresh_token"]})
    assert first.status_code == 200
    retry = client.post("/api/auth/refresh", json={"refresh_token": tokens["refresh_token"]})
    assert retry.status_code == 200


def test_reused_old_refresh_token_revokes_session(client: TestClient) -> None:
    tokens = login(client, "admin", ADMIN_PASSWORD)
    new_tokens = client.post("/api/auth/refresh", json={"refresh_token": tokens["refresh_token"]}).json()
    # Erneuerung künstlich in die Vergangenheit legen -> Gnadenfrist abgelaufen
    with client.app.state.session_factory() as db:
        session = db.query(UserSession).one()
        session.rotated_at = session.rotated_at - auth_service.REFRESH_GRACE - timedelta(seconds=1)
        db.commit()
    stolen = client.post("/api/auth/refresh", json={"refresh_token": tokens["refresh_token"]})
    assert stolen.status_code == 401
    # Zur Sicherheit ist das ganze Gerät abgemeldet
    assert client.post("/api/auth/refresh", json={"refresh_token": new_tokens["refresh_token"]}).status_code == 401
    assert client.get("/api/me", headers=bearer(new_tokens)).status_code == 401


def test_logout_revokes_device(client: TestClient) -> None:
    tokens = login(client, "admin", ADMIN_PASSWORD)
    assert client.post("/api/auth/logout", headers=bearer(tokens)).status_code == 204
    assert client.get("/api/me", headers=bearer(tokens)).status_code == 401
    assert client.post("/api/auth/refresh", json={"refresh_token": tokens["refresh_token"]}).status_code == 401


def test_rate_limit_after_failures(client: TestClient) -> None:
    for _ in range(10):
        response = client.post("/api/auth/login", json={"username": "admin", "password": "falsch-falsch"})
        assert response.status_code == 401
    blocked = client.post("/api/auth/login", json={"username": "admin", "password": ADMIN_PASSWORD})
    assert blocked.status_code == 429
    assert int(blocked.headers["Retry-After"]) > 0


def test_sessions_list_and_remote_logout(client: TestClient) -> None:
    phone = login(client, "admin", ADMIN_PASSWORD, device="Handy")
    tablet = login(client, "admin", ADMIN_PASSWORD, device="Tablet")
    sessions = client.get("/api/me/sessions", headers=bearer(phone)).json()
    assert {s["device_name"] for s in sessions} == {"Handy", "Tablet"}
    assert [s["current"] for s in sessions if s["device_name"] == "Handy"] == [True]

    tablet_id = next(s["id"] for s in sessions if s["device_name"] == "Tablet")
    assert client.delete(f"/api/me/sessions/{tablet_id}", headers=bearer(phone)).status_code == 204
    assert client.get("/api/me", headers=bearer(tablet)).status_code == 401
    assert client.get("/api/me", headers=bearer(phone)).status_code == 200


def test_change_password_logs_out_other_devices(client: TestClient) -> None:
    phone = login(client, "admin", ADMIN_PASSWORD, device="Handy")
    tablet = login(client, "admin", ADMIN_PASSWORD, device="Tablet")

    wrong = client.post(
        "/api/me/password",
        headers=bearer(phone),
        json={"current_password": "falsch-falsch", "new_password": "neues-passwort-1"},
    )
    assert wrong.status_code == 400

    changed = client.post(
        "/api/me/password",
        headers=bearer(phone),
        json={"current_password": ADMIN_PASSWORD, "new_password": "neues-passwort-1"},
    )
    assert changed.status_code == 200
    assert client.get("/api/me", headers=bearer(changed.json())).status_code == 200
    assert client.get("/api/me", headers=bearer(tablet)).status_code == 401
    login(client, "admin", "neues-passwort-1")


def test_update_display_name(client: TestClient) -> None:
    tokens = login(client, "admin", ADMIN_PASSWORD)
    response = client.patch("/api/me", headers=bearer(tokens), json={"display_name": "  Papa  "})
    assert response.status_code == 200
    assert response.json()["display_name"] == "Papa"
