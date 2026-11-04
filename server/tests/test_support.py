"""Song-Wünsche, Fehlermeldungen, App-Konfiguration, Konto löschen und die gemeldeten App-Versionen."""

from collections.abc import Callable

from fastapi.testclient import TestClient
from sqlalchemy import select

from app.models import BugReport, Category, DownloadJob, SongRequest, User

from .conftest import ADMIN_PASSWORD, bearer, login


def member(client: TestClient, make_user: Callable[..., dict], name: str = "lena") -> tuple[dict, dict[str, str]]:
    user = make_user(name)
    return user, bearer(login(client, name, "kinder-passwort"))


def wish(client: TestClient, headers: dict[str, str], title: str = "Du hast", artist: str = "Rammstein", **extra):  # type: ignore[no-untyped-def]
    return client.post("/api/requests", headers=headers, json={"title": title, "artist": artist, **extra})


# ----------------------------------------------------------------------------------------------- Wünsche


def test_wish_roundtrip(client: TestClient, admin_headers: dict[str, str], make_user: Callable) -> None:
    _, headers = member(client, make_user)
    created = wish(client, headers, note="Bitte die Albumversion")
    assert created.status_code == 201, created.text
    body = created.json()
    assert body["status"] == "open" and body["title"] == "Du hast" and body["artist"] == "Rammstein"
    assert body["note"] == "Bitte die Albumversion" and body["job_status"] is None
    mine = client.get("/api/requests", headers=headers).json()
    assert [w["id"] for w in mine] == [body["id"]]

    everything = client.get("/api/admin/requests", headers=admin_headers).json()
    assert everything[0]["user"]["username"] == "lena"
    assert client.get("/api/admin/requests?state=done", headers=admin_headers).json() == []

    note = {"status": "declined", "admin_note": "Gibt es nicht"}
    declined = client.patch(f"/api/admin/requests/{body['id']}", headers=admin_headers, json=note)
    assert declined.status_code == 200 and declined.json()["status"] == "declined"
    seen = client.get("/api/requests", headers=headers).json()[0]
    assert seen["status"] == "declined" and seen["admin_note"] == "Gibt es nicht"


def test_wishes_are_private_and_validated(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable
) -> None:
    _, lena = member(client, make_user, "lena")
    _, ben = member(client, make_user, "ben")
    created = wish(client, lena).json()
    assert client.get("/api/requests", headers=ben).json() == []
    assert client.delete(f"/api/requests/{created['id']}", headers=ben).status_code == 404
    assert client.get("/api/admin/requests", headers=ben).status_code == 403
    assert client.patch(f"/api/admin/requests/{created['id']}", headers=ben, json={"status": "done"}).status_code == 403
    assert wish(client, lena, title="   ").status_code == 422
    assert wish(client, lena, title="x" * 201).status_code == 422
    assert client.post("/api/requests", json={"title": "x"}).status_code == 401
    assert client.delete(f"/api/requests/{created['id']}", headers=lena).status_code == 204
    assert client.delete(f"/api/requests/{created['id']}", headers=lena).status_code == 404


def test_duplicate_and_flood_protection(client: TestClient, make_user: Callable) -> None:
    _, headers = member(client, make_user)
    assert wish(client, headers, title="Sonne").status_code == 201
    twin = wish(client, headers, title="  sonne ")
    assert twin.status_code == 409
    for i in range(14):  # bis zur Tagesgrenze von 15
        assert wish(client, headers, title=f"Lied {i}").status_code == 201
    assert wish(client, headers, title="Eins zu viel").status_code == 429


def test_wish_with_download_becomes_done(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable
) -> None:
    _, headers = member(client, make_user)
    created = wish(client, headers).json()
    with client.app.state.session_factory() as db:
        category = db.scalar(select(Category).where(Category.media_type == "audio"))
        job = DownloadJob(
            user_id=db.scalar(select(User.id).where(User.username == "admin")),
            category_id=category.id,
            media_type="audio",
            video_id="aaaaaaaaaaa",
            status="downloading",
        )
        db.add(job)
        db.commit()
        job_id = job.id
    accepted = client.patch(f"/api/admin/requests/{created['id']}", headers=admin_headers, json={"job_id": job_id})
    assert accepted.status_code == 200
    assert accepted.json()["status"] == "accepted" and accepted.json()["job_status"] == "downloading"
    # Laufender Wunsch lässt sich nicht zurückziehen
    assert client.delete(f"/api/requests/{created['id']}", headers=headers).status_code == 409

    with client.app.state.session_factory() as db:
        db.get(DownloadJob, job_id).status = "done"
        db.commit()
    mine = client.get("/api/requests", headers=headers).json()[0]
    assert mine["status"] == "done" and mine["job_status"] == "done"

    missing = client.patch(f"/api/admin/requests/{created['id']}", headers=admin_headers, json={"job_id": 9999})
    assert missing.status_code == 404
    assert client.delete(f"/api/admin/requests/{created['id']}", headers=admin_headers).status_code == 204
    assert client.delete(f"/api/admin/requests/{created['id']}", headers=admin_headers).status_code == 404


# ------------------------------------------------------------------------------------------ Fehlermeldungen


def report(
    client: TestClient, headers: dict[str, str], message: str = "Die Wiedergabe bleibt hängen", **extra: object
):  # type: ignore[no-untyped-def]
    info = {"app_version": "1.0.0", "app_build": 54, "platform": "android", "channel": "play"}
    return client.post("/api/bugreports", headers=headers, json={"message": message, **info, **extra})


def test_bug_report_roundtrip(client: TestClient, admin_headers: dict[str, str], make_user: Callable) -> None:
    _, headers = member(client, make_user)
    created = report(client, headers, device="Pixel 8 (Android 16)", log="Exception: kaputt")
    assert created.status_code == 201, created.text
    listing = client.get("/api/admin/bugreports", headers=admin_headers).json()
    assert len(listing) == 1
    item = listing[0]
    assert item["user"]["username"] == "lena" and item["status"] == "new" and item["log"] == "Exception: kaputt"
    assert item["app_build"] == 54 and item["channel"] == "play" and item["device"] == "Pixel 8 (Android 16)"

    note = {"status": "seen", "admin_note": "Schaue ich an"}
    patched = client.patch(f"/api/admin/bugreports/{item['id']}", headers=admin_headers, json=note)
    assert patched.json()["status"] == "seen" and patched.json()["admin_note"] == "Schaue ich an"
    assert client.get("/api/admin/bugreports?state=new", headers=admin_headers).json() == []
    assert client.delete(f"/api/admin/bugreports/{item['id']}", headers=admin_headers).status_code == 204
    assert client.delete(f"/api/admin/bugreports/{item['id']}", headers=admin_headers).status_code == 404


def test_bug_reports_are_validated_limited_and_admin_only(client: TestClient, make_user: Callable) -> None:
    _, headers = member(client, make_user)
    assert report(client, headers, message="zu kurz").status_code == 422
    assert report(client, headers, message="x" * 4001).status_code == 422
    assert report(client, headers, log="x" * 20_001).status_code == 422
    assert client.get("/api/admin/bugreports", headers=headers).status_code == 403
    assert client.post("/api/bugreports", json={"message": "ohne Anmeldung unmöglich"}).status_code == 401
    for _ in range(10):
        assert report(client, headers).status_code == 201
    assert report(client, headers).status_code == 429


# ------------------------------------------------------------------------------------- App-Konfiguration


def test_public_config_defaults(client: TestClient) -> None:
    response = client.get("/api/app/config")
    assert response.status_code == 200, response.text
    config = response.json()
    assert config["ads_enabled"] is False, "Werbung bleibt aus, bis der Admin sie einschaltet"
    assert config["premium_enabled"] is True and config["wishlist_enabled"] is True
    assert config["maintenance_message"] == "" and config["update"]["level"] == "none"


def test_admin_changes_config_and_update_levels(client: TestClient, admin_headers: dict[str, str]) -> None:
    changed = client.put(
        "/api/admin/config",
        headers=admin_headers,
        json={
            "ads_enabled": True,
            "play_latest_build": 70,
            "play_min_build": 60,
            "play_store_url": "https://play.google.com/store/apps/details?id=de.selfify.selfify.play",
            "update_message": "Neue Version mit Fehlerkorrekturen",
            "maintenance_message": "Heute Abend kurz nicht erreichbar",
        },
    )
    assert changed.status_code == 200, changed.text
    assert changed.json()["ads_enabled"] is True and changed.json()["play_min_build"] == 60

    def level(**params: object) -> str:
        return client.get("/api/app/config", params=params).json()["update"]["level"]

    assert level(channel="play", build=54) == "required"
    assert level(channel="play", build=60) == "available"
    assert level(channel="play", build=70) == "none"
    assert level(channel="full", build=1) == "none", "die GitHub-Version prüft selbst"
    assert level(channel="play") == "none", "ohne Build-Nummer kein Zwang"
    public = client.get("/api/app/config", params={"channel": "play", "build": 54}).json()
    assert public["update"]["store_url"].startswith("https://play.google.com/")
    assert public["update"]["message"] == "Neue Version mit Fehlerkorrekturen"
    assert public["maintenance_message"] == "Heute Abend kurz nicht erreichbar" and public["ads_enabled"] is True

    # Teiländerung lässt den Rest stehen
    client.put("/api/admin/config", headers=admin_headers, json={"ads_enabled": False})
    after = client.get("/api/admin/config", headers=admin_headers).json()
    assert after["ads_enabled"] is False and after["play_latest_build"] == 70


def test_config_rejects_bad_values_and_normal_users(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable
) -> None:
    bad_url = client.put("/api/admin/config", headers=admin_headers, json={"play_store_url": "http://evil.example/"})
    assert bad_url.status_code == 400
    negative = client.put("/api/admin/config", headers=admin_headers, json={"play_min_build": -1})
    assert negative.status_code == 400
    long_text = client.put("/api/admin/config", headers=admin_headers, json={"update_message": "x" * 301})
    assert long_text.status_code == 400
    mixed = client.put("/api/admin/config", headers=admin_headers, json={"ads_enabled": True, "play_min_build": -5})
    assert mixed.status_code == 400
    unchanged = client.get("/api/admin/config", headers=admin_headers).json()
    assert unchanged["ads_enabled"] is False, "ein Fehler ändert nichts"
    _, headers = member(client, make_user)
    assert client.put("/api/admin/config", headers=headers, json={"ads_enabled": True}).status_code == 403
    assert client.get("/api/admin/config", headers=headers).status_code == 403


def test_public_config_links_use_the_public_url(client: TestClient) -> None:
    client.app.state.settings.public_url = "https://musik.example.de"
    config = client.get("/api/app/config").json()
    assert config["privacy_url"] == "https://musik.example.de/datenschutz"
    assert config["deletion_url"] == "https://musik.example.de/konto-loeschen"


# --------------------------------------------------------------------------------------- Konto löschen


def test_delete_own_account(client: TestClient, admin_headers: dict[str, str], make_user: Callable) -> None:
    _, headers = member(client, make_user)
    wish(client, headers)
    report(client, headers)
    wrong = client.post("/api/me/delete", headers=headers, json={"password": "falsch"})
    assert wrong.status_code == 400
    assert client.post("/api/me/delete", json={"password": "kinder-passwort"}).status_code == 401
    ok = client.post("/api/me/delete", headers=headers, json={"password": "kinder-passwort"})
    assert ok.status_code == 204
    again = client.post("/api/auth/login", json={"username": "lena", "password": "kinder-passwort"})
    assert again.status_code == 401
    assert client.get("/api/me", headers=headers).status_code == 401
    with client.app.state.session_factory() as db:
        assert db.scalars(select(SongRequest)).all() == [] and db.scalars(select(BugReport)).all() == []
    assert [u["username"] for u in client.get("/api/users", headers=admin_headers).json()] == ["admin"]


def test_last_admin_cannot_delete_the_account(client: TestClient, admin_headers: dict[str, str]) -> None:
    blocked = client.post("/api/me/delete", headers=admin_headers, json={"password": ADMIN_PASSWORD})
    assert blocked.status_code == 409
    assert client.get("/api/me", headers=admin_headers).status_code == 200


def test_wrong_password_on_delete_is_rate_limited(client: TestClient, make_user: Callable) -> None:
    _, headers = member(client, make_user)
    limit = client.app.state.settings.login_max_failures_per_user
    for _ in range(limit):
        assert client.post("/api/me/delete", headers=headers, json={"password": "falsch"}).status_code == 400
    blocked = client.post("/api/me/delete", headers=headers, json={"password": "kinder-passwort"})
    assert blocked.status_code == 429


# ------------------------------------------------------------------------ Geräte, Versionen und Zahlen


def test_client_versions_are_recorded(client: TestClient, admin_headers: dict[str, str], make_user: Callable) -> None:
    make_user("lena")
    header = {"X-Selfify-Client": "platform=android; channel=play; version=1.0.0; build=54"}
    credentials = {"username": "lena", "password": "kinder-passwort", "device_name": "Pixel"}
    tokens = client.post("/api/auth/login", headers=header, json=credentials).json()
    clients = client.get("/api/admin/clients", headers=admin_headers).json()
    assert [(c["channel"], c["version"], c["build"], c["devices"]) for c in clients] == [("play", "1.0.0", 54, 1)]
    assert clients[0]["platform"] == "android" and clients[0]["users"] == 1

    # Update der App: nächste Anfrage meldet die neue Version
    newer = {"X-Selfify-Client": "platform=android; channel=play; version=1.1.0; build=60", **bearer(tokens)}
    assert client.get("/api/me", headers=newer).status_code == 200
    clients = client.get("/api/admin/clients", headers=admin_headers).json()
    assert [(c["version"], c["build"]) for c in clients] == [("1.1.0", 60)]
    users = {u["username"]: u for u in client.get("/api/admin/users", headers=admin_headers).json()}
    assert users["lena"]["last_client"] == "play 1.1.0 (60)" and users["admin"]["last_client"] == ""


def test_garbage_client_headers_are_ignored(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable
) -> None:
    make_user("lena")
    garbage = ("", "unsinn", "platform=a; channel=play; version=1", "platform=android; channel=play; version=<x>")
    for value in (*garbage, "x" * 300):
        client.post(
            "/api/auth/login",
            headers={"X-Selfify-Client": value},
            json={"username": "lena", "password": "kinder-passwort"},
        )
    assert client.get("/api/admin/clients", headers=admin_headers).json() == []
    odd_build = "platform=windows; channel=full; version=1.0.0; build=abc"
    credentials = {"username": "lena", "password": "kinder-passwort"}
    client.post("/api/auth/login", headers={"X-Selfify-Client": odd_build}, json=credentials)
    (entry,) = client.get("/api/admin/clients", headers=admin_headers).json()
    assert entry["build"] is None and entry["platform"] == "windows"


def test_admin_user_list_and_stats(client: TestClient, admin_headers: dict[str, str], make_user: Callable) -> None:
    user, headers = member(client, make_user)
    client.post(f"/api/admin/users/{user['id']}/premium", headers=admin_headers, json={"unlimited": True})
    wish(client, headers)
    report(client, headers)
    users = {u["username"]: u for u in client.get("/api/admin/users", headers=admin_headers).json()}
    assert users["lena"]["premium"]["unlimited"] is True and users["admin"]["premium"]["active"] is False
    assert users["lena"]["devices"] == 1 and users["lena"]["downloads"] == 0
    assert client.get("/api/admin/users", headers=headers).status_code == 403

    stats = client.get("/api/admin/stats", headers=admin_headers).json()
    assert stats["users_total"] == 2 and stats["users_active"] == 2
    assert stats["premium_users"] == 1 and stats["premium_unlimited"] == 1
    assert stats["requests_open"] == 1 and stats["bugs_new"] == 1 and stats["downloads_total"] == 0
    assert len(stats["downloads_by_day"]) == 14 and len(stats["plays_by_day"]) == 14
    assert sum(d["count"] for d in stats["downloads_by_day"]) == 0
    assert client.get("/api/admin/stats", headers=headers).status_code == 403
