"""Selbst-Registrierung: drei Modi, Freischalten/Ablehnen, Zurückziehen, Ratenbegrenzung, Einstellungen."""

from collections.abc import Callable
from datetime import timedelta

import pytest
from fastapi.testclient import TestClient

from app.models import User, utcnow
from app.ratelimit import LoginRateLimiter
from app.routers import auth as auth_router
from app.routers.auth import register_key
from app.security import hash_password

from .conftest import ADMIN_PASSWORD, bearer, login

PASSWORD = "selbst-passwort-1"
MSG_OFF = "Auf diesem Server kann man sich nicht selbst registrieren."
MSG_TAKEN = "Dieser Benutzername ist nicht verfügbar. Bitte wähle einen anderen."
MSG_PENDING = (
    "Dein Konto wurde angelegt und wartet auf Freischaltung durch den Betreiber. "
    "Du kannst dich anmelden, sobald es freigeschaltet ist. Ohne Freischaltung wird es nach 14 Tagen gelöscht."
)
MSG_LOGIN_PENDING = "Dein Konto wartet noch auf Freischaltung durch den Betreiber."


def set_config(client: TestClient, admin_headers: dict[str, str], **values: object) -> dict:
    response = client.put("/api/admin/config", headers=admin_headers, json=values)
    assert response.status_code == 200, response.text
    return response.json()


def register(client: TestClient, username: str = "neu", password: str = PASSWORD, **extra: object):  # type: ignore[no-untyped-def]
    return client.post("/api/auth/register", json={"username": username, "password": password, **extra})


def category_ids(client: TestClient, admin_headers: dict[str, str]) -> dict[str, int]:
    return {c["name"]: c["id"] for c in client.get("/api/categories", headers=admin_headers).json()}


def admin_user(client: TestClient, admin_headers: dict[str, str], username: str) -> dict:
    return next(u for u in client.get("/api/users", headers=admin_headers).json() if u["username"] == username)


# ----------------------------------------------------------------------------- Modus „aus“


def test_mode_off_is_the_default_and_answers_404(client: TestClient, admin_headers: dict[str, str]) -> None:
    response = register(client)
    assert response.status_code == 404
    assert response.json()["detail"] == MSG_OFF
    # nichts angelegt, die App bekommt „off“ gemeldet
    assert [u["username"] for u in client.get("/api/users", headers=admin_headers).json()] == ["admin"]
    assert client.get("/api/server").json()["registration_mode"] == "off"
    assert client.get("/api/app/config").json()["registration_mode"] == "off"
    config = client.get("/api/admin/config", headers=admin_headers).json()
    assert config["registration_mode"] == "off" and config["registration_default_categories"] == ""
    # im Modus „aus“ zählt kein Versuch (die Ratenbegrenzung kommt erst danach)
    for _ in range(8):
        assert register(client).status_code == 404


def test_existing_and_admin_created_accounts_keep_all_categories(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable[..., dict]
) -> None:
    created = make_user("lena")
    assert created["all_categories"] is True and created["category_ids"] == []
    assert created["approval_pending"] is False and created["self_registered"] is False
    me = client.get("/api/me", headers=bearer(login(client, "lena", "kinder-passwort"))).json()
    assert me["all_categories"] is True and me["approval_pending"] is False
    admin = client.get("/api/me", headers=admin_headers).json()
    assert admin["all_categories"] is True and admin["self_registered"] is False


# ------------------------------------------------------------------------- Modus „approval“


def test_approval_flow_pending_login_unlock(client: TestClient, admin_headers: dict[str, str]) -> None:
    set_config(client, admin_headers, registration_mode="approval")
    assert client.get("/api/server").json()["registration_mode"] == "approval"
    assert client.get("/api/app/config").json()["registration_mode"] == "approval"

    response = register(client, " Neu ", device_name="Pixel")
    assert response.status_code == 202, response.text
    assert response.json() == {"status": "pending", "message": MSG_PENDING, "tokens": None}

    user = admin_user(client, admin_headers, "neu")
    assert user["display_name"] == "Neu"
    assert user["is_active"] is False and user["approval_pending"] is True and user["self_registered"] is True
    assert user["is_admin"] is False and user["can_download"] is False
    assert user["all_categories"] is False and user["category_ids"] == []
    dashboard = next(u for u in client.get("/api/admin/users", headers=admin_headers).json() if u["username"] == "neu")
    assert dashboard["approval_pending"] is True and dashboard["self_registered"] is True
    assert dashboard["all_categories"] is False and dashboard["category_ids"] == []
    assert client.get("/api/admin/stats", headers=admin_headers).json()["users_pending"] == 1

    # Login: erst nach richtigem Passwort die Wartemeldung mit Header
    wrong = client.post("/api/auth/login", json={"username": "neu", "password": "falsch-falsch"})
    assert wrong.status_code == 401 and "x-selfify-account-state" not in wrong.headers
    pending = client.post("/api/auth/login", json={"username": "neu", "password": PASSWORD})
    assert pending.status_code == 403
    assert pending.json()["detail"] == MSG_LOGIN_PENDING
    assert pending.headers["x-selfify-account-state"] == "pending"

    # Ein PATCH ohne is_active lässt den Wartestatus stehen
    changed = client.patch(f"/api/users/{user['id']}", headers=admin_headers, json={"display_name": "Neuling"})
    assert changed.status_code == 200
    assert changed.json()["approval_pending"] is True and changed.json()["is_active"] is False

    # Freischalten = is_active: true
    unlocked = client.patch(f"/api/users/{user['id']}", headers=admin_headers, json={"is_active": True})
    assert unlocked.status_code == 200
    assert unlocked.json()["approval_pending"] is False and unlocked.json()["is_active"] is True
    assert unlocked.json()["self_registered"] is True
    assert client.get("/api/admin/stats", headers=admin_headers).json()["users_pending"] == 0
    tokens = login(client, "neu", PASSWORD)
    me = client.get("/api/me", headers=bearer(tokens)).json()
    assert me["approval_pending"] is False and me["all_categories"] is False and me["category_ids"] == []


def test_disabled_account_keeps_the_old_message(client: TestClient, admin_headers: dict[str, str], make_user) -> None:  # type: ignore[no-untyped-def]
    user = make_user("lena")
    client.patch(f"/api/users/{user['id']}", headers=admin_headers, json={"is_active": False})
    response = client.post("/api/auth/login", json={"username": "lena", "password": "kinder-passwort"})
    assert response.status_code == 403
    assert response.json()["detail"] == "Dieses Konto ist deaktiviert."
    assert "x-selfify-account-state" not in response.headers


def test_reject_deletes_the_account(client: TestClient, admin_headers: dict[str, str]) -> None:
    set_config(client, admin_headers, registration_mode="approval")
    assert register(client).status_code == 202
    user = admin_user(client, admin_headers, "neu")
    assert client.delete(f"/api/users/{user['id']}", headers=admin_headers).status_code == 204
    assert client.get(f"/api/users/{user['id']}", headers=admin_headers).status_code == 404
    assert client.post("/api/auth/login", json={"username": "neu", "password": PASSWORD}).status_code == 401
    assert client.get("/api/admin/stats", headers=admin_headers).json()["users_pending"] == 0


def test_too_many_pending_accounts(client: TestClient, admin_headers: dict[str, str]) -> None:
    set_config(client, admin_headers, registration_mode="approval")
    password_hash = hash_password("egal-egal-egal")
    with client.app.state.session_factory() as db:  # type: ignore[attr-defined]
        for n in range(50):
            db.add(
                User(username=f"wartet{n}", display_name="W", password_hash=password_hash, is_active=False,
                     approval_pending=True, self_registered=True, all_categories=False, can_download=False,
                     created_at=utcnow() - timedelta(hours=2))  # älter als eine Stunde: zählt nicht zur Stundengrenze
            )
        db.commit()
    response = register(client)
    assert response.status_code == 503
    assert response.json()["detail"] == (
        "Gerade warten zu viele neue Konten auf Freischaltung. Bitte versuche es später noch einmal."
    )
    assert client.get("/api/admin/stats", headers=admin_headers).json()["users_pending"] == 50
    # Im offenen Modus gibt es keine Warteschlange und damit keine Grenze für wartende Konten
    set_config(client, admin_headers, registration_mode="open")
    assert register(client).status_code == 201


# ----------------------------------------------------------------------------- Modus „open“


def test_open_mode_returns_tokens(client: TestClient, admin_headers: dict[str, str]) -> None:
    set_config(client, admin_headers, registration_mode="open")
    response = register(client, "neu", display_name="  Neue Person ", device_name="Pixel 8")
    assert response.status_code == 201, response.text
    body = response.json()
    assert body["status"] == "active" and body["message"] == "Dein Konto ist eingerichtet."
    tokens = body["tokens"]
    assert tokens["access_token"] and tokens["refresh_token"] and tokens["media_token"]
    assert tokens["user"]["display_name"] == "Neue Person"
    me = client.get("/api/me", headers=bearer(tokens)).json()
    assert me["can_download"] is False and me["is_admin"] is False and me["all_categories"] is False
    assert me["is_active"] is True and me["approval_pending"] is False and me["self_registered"] is True
    assert me["last_login_at"] is not None
    sessions = client.get("/api/me/sessions", headers=bearer(tokens)).json()
    assert [s["device_name"] for s in sessions] == ["Pixel 8"]
    # Admin-Bereiche bleiben zu
    assert client.get("/api/admin/stats", headers=bearer(tokens)).status_code == 403
    assert client.get("/api/users", headers=bearer(tokens)).status_code == 403
    # normaler Login klappt ebenfalls
    login(client, "neu", PASSWORD)


def test_default_categories_are_applied_and_deleted_ones_ignored(
    client: TestClient, admin_headers: dict[str, str]
) -> None:
    ids = category_ids(client, admin_headers)
    musik, hoer = ids["Musik"], ids["Hörspiele & Hörbücher"]
    config = set_config(
        client, admin_headers, registration_mode="open", registration_default_categories=f" {hoer}, {musik},{hoer} "
    )
    assert config["registration_default_categories"] == ",".join(str(i) for i in sorted((musik, hoer)))
    assert client.delete(f"/api/categories/{hoer}", headers=admin_headers).status_code == 204
    tokens = register(client).json()["tokens"]
    assert tokens["user"]["category_ids"] == [musik]
    categories = client.get("/api/categories", headers=bearer(tokens)).json()
    assert [c["id"] for c in categories] == [musik]


def test_deleted_default_category_id_is_not_reused_for_new_accounts(
    client: TestClient, admin_headers: dict[str, str]
) -> None:
    """SQLite vergibt die höchste freie ID neu. Eine gelöschte Standard-Rubrik darf eine später angelegte Rubrik mit
    derselben ID nicht automatisch an neue Konten freigeben."""
    ids = category_ids(client, admin_headers)
    musik, highest = ids["Musik"], max(ids.values())
    set_config(client, admin_headers, registration_mode="open", registration_default_categories=f"{musik},{highest}")
    assert client.delete(f"/api/categories/{highest}", headers=admin_headers).status_code == 204
    config = client.get("/api/admin/config", headers=admin_headers).json()
    assert config["registration_default_categories"] == str(musik)
    created = client.post(
        "/api/categories", headers=admin_headers, json={"name": "Privat", "media_type": "audio", "folder": "Privat"}
    )
    assert created.status_code == 201, created.text
    assert created.json()["id"] == highest  # dieselbe ID wie die gelöschte Rubrik
    tokens = register(client).json()["tokens"]
    assert tokens["user"]["category_ids"] == [musik]
    assert [c["id"] for c in client.get("/api/categories", headers=bearer(tokens)).json()] == [musik]


def test_conflicts_reserved_names_and_validation(client: TestClient, admin_headers: dict[str, str], make_user) -> None:  # type: ignore[no-untyped-def]
    set_config(client, admin_headers, registration_mode="open")
    client.app.state.register_limiter = LoginRateLimiter(10**9, 10**9, 3600)  # type: ignore[attr-defined]
    make_user("lena")
    for name in ("lena", "LENA", "admin", "Administrator", "root", "selfify", "betreiber", "null", "undefined"):
        response = register(client, name)
        assert response.status_code == 409, name
        assert response.json()["detail"] == MSG_TAKEN
        assert name.lower() not in response.json()["detail"].lower()
    # ungültige Namen und Passwörter: gewohnte 422-Form
    for body in (
        {"username": "x", "password": PASSWORD},
        {"username": "mit leerzeichen", "password": PASSWORD},
        {"username": "gut", "password": "kurz"},
        {"username": "gut", "password": PASSWORD, "display_name": "x" * 65},
        {"password": PASSWORD},
    ):
        response = client.post("/api/auth/register", json=body)
        assert response.status_code == 422, body
        detail = response.json()["detail"]
        assert isinstance(detail, list) and detail[0]["loc"][0] == "body"
    for raw in (b"kein json", b"", b"[1, 2]"):
        response = client.post("/api/auth/register", content=raw, headers={"content-type": "application/json"})
        assert response.status_code == 422, raw
    users = [u["username"] for u in client.get("/api/users", headers=admin_headers).json()]
    assert users == ["admin", "lena"]


def test_rate_limit_counts_every_attempt(client: TestClient, admin_headers: dict[str, str]) -> None:
    set_config(client, admin_headers, registration_mode="approval")
    assert register(client, "erste").status_code == 202  # Erfolg zählt
    assert register(client, "erste").status_code == 409  # Konflikt zählt
    assert register(client, "x").status_code == 422  # ungültig zählt
    assert register(client, "zweite").status_code == 202
    assert register(client, "admin").status_code == 409
    response = register(client, "dritte")
    assert response.status_code == 429
    assert response.json()["detail"].startswith("Zu viele Registrierungen von diesem Anschluss. Bitte in ")
    assert response.json()["detail"].endswith(" Minute(n) erneut versuchen.")
    assert int(response.headers["retry-after"]) > 60 * 50
    assert "dritte" not in [u["username"] for u in client.get("/api/users", headers=admin_headers).json()]
    # Der Login ist davon nicht betroffen
    login(client, "admin", ADMIN_PASSWORD)


def test_register_key_groups_ipv6_by_64_prefix() -> None:
    assert register_key("203.0.113.7") == "203.0.113.7"
    assert register_key("::ffff:203.0.113.7") == "203.0.113.7"
    assert register_key("2001:db8:1:2::1") == register_key("2001:db8:1:2:ffff::9") == "2001:db8:1:2::/64"
    assert register_key("2001:db8:1:3::1") != register_key("2001:db8:1:2::1")
    assert register_key("testclient") == "testclient"


def test_rate_limit_covers_the_whole_ipv6_64(
    client: TestClient, admin_headers: dict[str, str], monkeypatch: pytest.MonkeyPatch
) -> None:
    set_config(client, admin_headers, registration_mode="open")
    addresses = iter(f"2001:db8:1:2::{n:x}" for n in range(1, 100))
    monkeypatch.setattr(auth_router, "client_ip", lambda _request: next(addresses))
    for n in range(5):
        assert register(client, f"neu{n}").status_code == 201
    # Neue Adresse aus demselben /64 – die Sperre greift trotzdem
    assert register(client, "neu5").status_code == 429
    # Ein anderes /64 ist ein anderer Anschluss
    monkeypatch.setattr(auth_router, "client_ip", lambda _request: "2001:db8:9:9::1")
    assert register(client, "neu6").status_code == 201


def test_hourly_cap_for_new_accounts_also_in_open_mode(
    client: TestClient, admin_headers: dict[str, str], monkeypatch: pytest.MonkeyPatch
) -> None:
    set_config(client, admin_headers, registration_mode="open")
    client.app.state.register_limiter = LoginRateLimiter(10**9, 10**9, 3600)  # type: ignore[attr-defined]
    monkeypatch.setattr(auth_router, "MAX_REGISTRATIONS_PER_HOUR", 3)
    for n in range(3):
        assert register(client, f"neu{n}").status_code == 201
    response = register(client, "neu3")
    assert response.status_code == 503
    assert response.json()["detail"] == (
        "Gerade werden sehr viele neue Konten angelegt. Bitte versuche es später noch einmal."
    )
    assert "neu3" not in [u["username"] for u in client.get("/api/users", headers=admin_headers).json()]
    # Vom Admin angelegte Konten zählen nicht mit, ältere selbst registrierte auch nicht
    with client.app.state.session_factory() as db:  # type: ignore[attr-defined]
        for user in db.query(User).filter(User.self_registered.is_(True)):
            user.created_at = utcnow() - timedelta(hours=2)
        db.commit()
    assert register(client, "neu3").status_code == 201


# ---------------------------------------------------------------------------- Zurückziehen


def test_withdraw_pending_registration(client: TestClient, admin_headers: dict[str, str], make_user) -> None:  # type: ignore[no-untyped-def]
    set_config(client, admin_headers, registration_mode="approval")
    assert register(client, "neu").status_code == 202
    assert register(client, "zweiter").status_code == 202
    make_user("lena")

    wrong = client.post("/api/auth/withdraw", json={"username": "neu", "password": "falsch-falsch"})
    assert wrong.status_code == 401 and wrong.json()["detail"] == "Benutzername oder Passwort falsch."
    unknown = client.post("/api/auth/withdraw", json={"username": "gibtsnicht", "password": PASSWORD})
    assert unknown.status_code == 401 and unknown.json()["detail"] == "Benutzername oder Passwort falsch."

    active = client.post("/api/auth/withdraw", json={"username": "lena", "password": "kinder-passwort"})
    assert active.status_code == 409
    assert active.json()["detail"] == (
        "Dieses Konto ist schon freigeschaltet. Melde dich an und lösche es unter „Einstellungen“ → „Konto löschen“."
    )

    done = client.post("/api/auth/withdraw", json={"username": " Neu ", "password": PASSWORD})
    assert done.status_code == 204
    names = [u["username"] for u in client.get("/api/users", headers=admin_headers).json()]
    assert names == ["admin", "lena", "zweiter"]
    # freigeschaltet -> zurückziehen geht nicht mehr
    second = admin_user(client, admin_headers, "zweiter")
    client.patch(f"/api/users/{second['id']}", headers=admin_headers, json={"is_active": True})
    assert client.post("/api/auth/withdraw", json={"username": "zweiter", "password": PASSWORD}).status_code == 409


def test_withdraw_is_rate_limited_like_the_login(client: TestClient, admin_headers: dict[str, str]) -> None:
    set_config(client, admin_headers, registration_mode="approval")
    assert register(client, "neu").status_code == 202
    for _ in range(10):
        client.post("/api/auth/withdraw", json={"username": "neu", "password": "falsch-falsch"})
    response = client.post("/api/auth/withdraw", json={"username": "neu", "password": PASSWORD})
    assert response.status_code == 429
    assert response.json()["detail"].startswith("Zu viele Fehlversuche.")
    assert "retry-after" in response.headers


# ------------------------------------------------------------------------- Admin: Rubriken


def test_admin_assigns_categories(client: TestClient, admin_headers: dict[str, str]) -> None:
    ids = category_ids(client, admin_headers)
    musik, hoer = ids["Musik"], ids["Hörspiele & Hörbücher"]
    body = {"username": "kim", "password": "kinder-passwort", "all_categories": False, "category_ids": [hoer, musik]}
    unknown = client.post("/api/users", headers=admin_headers, json={**body, "category_ids": [musik, 9999]})
    assert unknown.status_code == 404 and unknown.json()["detail"] == "Rubrik nicht gefunden."
    created = client.post("/api/users", headers=admin_headers, json=body)
    assert created.status_code == 201
    user = created.json()
    assert user["all_categories"] is False and user["category_ids"] == sorted((musik, hoer))

    url = f"/api/users/{user['id']}"
    bad = client.patch(url, headers=admin_headers, json={"category_ids": [9999]})
    assert bad.status_code == 404 and bad.json()["detail"] == "Rubrik nicht gefunden."
    assert client.get(url, headers=admin_headers).json()["category_ids"] == sorted((musik, hoer))
    replaced = client.patch(url, headers=admin_headers, json={"category_ids": [hoer]}).json()
    assert replaced["category_ids"] == [hoer]
    # „Alle“ einschalten behält die Auswahl
    everything = client.patch(url, headers=admin_headers, json={"all_categories": True}).json()
    assert everything["all_categories"] is True and everything["category_ids"] == [hoer]
    # Rubrik gelöscht -> Freigabe verschwindet mit (CASCADE)
    assert client.delete(f"/api/categories/{hoer}", headers=admin_headers).status_code == 204
    assert client.get(url, headers=admin_headers).json()["category_ids"] == []
    too_many = client.patch(url, headers=admin_headers, json={"category_ids": list(range(1, 502))})
    assert too_many.status_code == 422


# ---------------------------------------------------------------------------- Einstellungen


def test_config_validates_mode_and_categories(client: TestClient, admin_headers: dict[str, str]) -> None:
    ids = category_ids(client, admin_headers)

    def put(**values: object):  # type: ignore[no-untyped-def]
        return client.put("/api/admin/config", headers=admin_headers, json=values)

    response = put(registration_mode="jeder")
    assert response.status_code == 400
    assert response.json()["detail"] == "registration_mode: „off“, „approval“ oder „open“ erwartet."
    for value in ("abc", "1;2", "0", "-1", "1,,x", ",".join(str(n) for n in range(1, 102))):
        response = put(registration_default_categories=value)
        assert response.status_code == 400, value
        assert response.json()["detail"] == (
            "registration_default_categories: Rubrik-Nummern durch Komma getrennt erwartet."
        ), value
    response = put(registration_default_categories="1,9999")
    assert response.status_code == 400
    assert response.json()["detail"] == "registration_default_categories: Rubrik 9999 gibt es nicht."
    # ein Fehler ändert nichts
    assert client.get("/api/admin/config", headers=admin_headers).json()["registration_default_categories"] == ""

    first, second = sorted(ids.values())[:2]
    saved = put(registration_mode="open", registration_default_categories=f" {second}, {first},{second} ").json()
    assert saved["registration_mode"] == "open"
    assert saved["registration_default_categories"] == f"{first},{second}"
    assert put(registration_default_categories="").json()["registration_default_categories"] == ""
    assert client.get("/api/app/config").json()["registration_mode"] == "open"
    assert client.get("/api/server").json()["registration_mode"] == "open"


# ------------------------------------------------------------------------- Wartende Konten verfallen nach 14 Tagen


def test_pending_registrations_are_deleted_after_14_days(client: TestClient, admin_headers: dict[str, str]) -> None:
    from app.services.registration import PENDING_MAX_DAYS, purge_expired_pending

    assert PENDING_MAX_DAYS == 14
    set_config(client, admin_headers, registration_mode="approval")
    assert register(client, "alt").status_code == 202
    assert register(client, "frisch").status_code == 202
    assert register(client, "freigegeben").status_code == 202
    session_factory = client.app.state.session_factory  # type: ignore[attr-defined]
    with session_factory() as db:
        users = {u.username: u for u in db.query(User).filter(User.username.in_(["alt", "frisch", "freigegeben"]))}
        now = utcnow()
        users["alt"].created_at = now - timedelta(days=14, minutes=1)
        users["frisch"].created_at = now - timedelta(days=13, hours=23)
        # freigeschaltet und alt: bleibt
        users["freigegeben"].created_at = now - timedelta(days=30)
        users["freigegeben"].approval_pending = False
        users["freigegeben"].is_active = True
        db.commit()
        assert purge_expired_pending(db, now) == 1
        assert purge_expired_pending(db, now) == 0
        left = {u.username for u in db.query(User).filter(User.username.in_(["alt", "frisch", "freigegeben"]))}
    assert left == {"frisch", "freigegeben"}
    # Anmeldung mit dem gelöschten Konto: wie ein unbekannter Name
    assert login_status(client, "alt") == 401
    # vom Admin angelegte Bestandskonten sind nie betroffen
    with session_factory() as db:
        assert db.query(User).filter(User.username == "admin").count() == 1


def test_expired_pending_accounts_do_not_block_the_pending_limit(
    client: TestClient, admin_headers: dict[str, str], monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(auth_router, "MAX_PENDING_ACCOUNTS", 1)
    set_config(client, admin_headers, registration_mode="approval")
    assert register(client, "erster").status_code == 202
    assert register(client, "zweiter").status_code == 503
    with client.app.state.session_factory() as db:  # type: ignore[attr-defined]
        first = db.query(User).filter(User.username == "erster").one()
        first.created_at = utcnow() - timedelta(days=15)
        db.commit()
    # das abgelaufene Konto wird beim nächsten Versuch zuerst gelöscht
    assert register(client, "zweiter").status_code == 202
    with client.app.state.session_factory() as db:  # type: ignore[attr-defined]
        assert db.query(User).filter(User.username == "erster").count() == 0


def login_status(client: TestClient, username: str) -> int:
    return client.post("/api/auth/login", json={"username": username, "password": PASSWORD}).status_code
