"""Regressionstests zu den Funden der unabhängigen Gegenprüfung (PR #11).

Jeder Test hält einen Fehler fest, der dort mit einem Ablaufskript nachgestellt wurde.
"""

import sqlite3
import time
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from pathlib import Path

from alembic import command
from alembic.autogenerate import compare_metadata
from alembic.migration import MigrationContext
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select

from app.database import alembic_config
from app.models import Base, DownloadJob, PremiumLicense, SongRequest, User, utcnow
from app.services.clients import parse_client

from .conftest import ADMIN_PASSWORD, bearer, login
from .test_premium import new_codes, parse, redeem, status_of, user_headers

# ------------------------------------------------------------------------------------------------ Premium


def test_same_user_redeeming_a_multi_use_code_in_parallel_gets_it_only_once(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable
) -> None:
    """Vorher: Alle gleichzeitigen Anfragen bestanden die Prüfung „schon eingelöst“, jede legte eine Lizenz an."""
    (code,) = new_codes(client, admin_headers, duration_days=30, max_redemptions=50)
    _, headers = user_headers(client, make_user, "lena")
    with ThreadPoolExecutor(max_workers=12) as pool:
        results = list(pool.map(lambda _: redeem(client, headers, code["code"]).status_code, range(12)))
    assert results.count(200) == 1 and results.count(409) == 11
    with client.app.state.session_factory() as db:
        licenses = db.scalars(select(PremiumLicense).where(PremiumLicense.code_id == code["id"])).all()
    assert len(licenses) == 1
    detail = next(
        c for c in client.get("/api/admin/premium/codes", headers=admin_headers).json() if c["id"] == code["id"]
    )
    assert detail["redeemed_count"] == 1, "es darf nur ein Platz des Codes verbraucht sein"


def test_database_refuses_a_second_license_for_the_same_code_and_user(client: TestClient) -> None:
    """Auch ohne die Sperre im Server schützt die Datenbank selbst (UNIQUE je Code und Benutzer)."""
    from sqlalchemy.exc import IntegrityError

    (code,) = new_codes(client, client_admin(client))
    with client.app.state.session_factory() as db:
        admin = db.scalar(select(User).where(User.username == "admin"))
        now = utcnow()
        db.add(PremiumLicense(user_id=admin.id, code_id=code["id"], starts_at=now, expires_at=now + timedelta(days=1)))
        db.commit()
        db.add(PremiumLicense(user_id=admin.id, code_id=code["id"], starts_at=now, expires_at=now + timedelta(days=1)))
        try:
            db.commit()
        except IntegrityError:
            db.rollback()
        else:
            raise AssertionError("zweite Lizenz für denselben Code und Benutzer hätte scheitern müssen")
        # vom Admin vergebene Lizenzen (ohne Code) bleiben beliebig oft möglich
        for _ in range(3):
            db.add(PremiumLicense(user_id=admin.id, code_id=None, source="admin", starts_at=now))
        db.commit()


def client_admin(client: TestClient) -> dict[str, str]:
    return bearer(login(client, "admin", ADMIN_PASSWORD))


def test_stacking_works_beyond_two_licenses(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable
) -> None:
    """Vorher: Ab dem dritten Code (oder der dritten Vergabe) hängte nichts mehr an – die Laufzeit ging verloren."""
    codes = new_codes(client, admin_headers, count=3, duration_days=30)
    user, headers = user_headers(client, make_user, "lena")
    started = utcnow()
    for code in codes:
        assert redeem(client, headers, code["code"]).status_code == 200
    until = parse(status_of(client, headers)["until"])
    assert abs((until - started - timedelta(days=90)).total_seconds()) < 60
    # eine Admin-Vergabe hängt sich hinten an alle drei an
    assert (
        client.post(
            f"/api/admin/users/{user['id']}/premium", headers=admin_headers, json={"duration_days": 10}
        ).status_code
        == 201
    )
    until = parse(status_of(client, headers)["until"])
    assert abs((until - started - timedelta(days=100)).total_seconds()) < 60
    licenses = client.get(f"/api/admin/users/{user['id']}/premium", headers=admin_headers).json()["licenses"]
    spans = sorted((parse(lic["starts_at"]), parse(lic["expires_at"])) for lic in licenses)
    for (_, end), (start, _) in zip(spans, spans[1:], strict=False):
        assert start >= end - timedelta(seconds=1), "Lizenzen dürfen sich nicht überlappen"


def test_the_whole_chain_is_capped_instead_of_failing_with_500(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable
) -> None:
    user, headers = user_headers(client, make_user, "lena")
    url = f"/api/admin/users/{user['id']}/premium"
    for _ in range(3):
        assert client.post(url, headers=admin_headers, json={"duration_days": 1200}).status_code == 201
    overflow = client.post(url, headers=admin_headers, json={"duration_days": 1200})
    assert overflow.status_code == 409 and "zehn Jahre" in overflow.json()["detail"]
    (code,) = new_codes(client, admin_headers, duration_days=3650)
    refused = redeem(client, headers, code["code"])
    assert refused.status_code == 409
    codes = {c["id"]: c for c in client.get("/api/admin/premium/codes", headers=admin_headers).json()}
    assert codes[code["id"]]["redeemed_count"] == 0, "ein abgelehnter Code darf nicht verbraucht werden"


def test_valid_until_without_timezone_or_absurd_values_never_cause_500(
    client: TestClient, admin_headers: dict[str, str]
) -> None:
    future = (utcnow() + timedelta(days=5)).replace(tzinfo=None).isoformat()
    naive = client.post(
        "/api/admin/premium/codes", headers=admin_headers, json={"duration_days": 5, "valid_until": future}
    )
    assert naive.status_code == 201, naive.text
    assert parse(naive.json()[0]["valid_until"]) is not None
    past = client.post(
        "/api/admin/premium/codes",
        headers=admin_headers,
        json={"duration_days": 5, "valid_until": "2020-01-01T00:00:00"},
    )
    assert past.status_code == 400
    for odd in ("2027-01-01", "9999-12-31T23:59:59-05:00", "9999-12-31T23:59:59Z", "2500-01-01T00:00:00Z"):
        response = client.post(
            "/api/admin/premium/codes", headers=admin_headers, json={"duration_days": 5, "valid_until": odd}
        )
        assert response.status_code < 500, (odd, response.text)


def test_running_licenses_list_is_not_cut_off_by_the_row_limit(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable
) -> None:
    """Vorher: erst die 1000 neuesten Lizenzen holen, dann auf „läuft“ filtern – ältere laufende fehlten."""
    user, _ = user_headers(client, make_user, "lena")
    now = utcnow()
    with client.app.state.session_factory() as db:
        db.add(
            PremiumLicense(
                user_id=user["id"], source="admin", starts_at=now - timedelta(days=400), note="alt, unbegrenzt"
            )
        )
        db.flush()
        for _ in range(1005):
            db.add(
                PremiumLicense(
                    user_id=user["id"],
                    source="admin",
                    starts_at=now - timedelta(days=30),
                    expires_at=now - timedelta(days=1),
                )
            )
        db.commit()
    running = client.get("/api/admin/premium/licenses?only_running=true", headers=admin_headers).json()
    assert [lic["note"] for lic in running] == ["alt, unbegrenzt"]


def test_revoking_does_not_relabel_licenses_that_already_ran_out(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable
) -> None:
    user, _ = user_headers(client, make_user, "lena")
    now = utcnow()
    with client.app.state.session_factory() as db:
        old = PremiumLicense(
            user_id=user["id"], source="admin", starts_at=now - timedelta(days=60), expires_at=now - timedelta(days=30)
        )
        db.add(old)
        db.add(
            PremiumLicense(
                user_id=user["id"],
                source="admin",
                starts_at=now - timedelta(days=1),
                expires_at=now + timedelta(days=9),
            )
        )
        db.commit()
        old_id = old.id
    assert client.post(f"/api/admin/premium/licenses/{old_id}/revoke", headers=admin_headers).json() == {"revoked": 0}
    revoked = client.delete(f"/api/admin/users/{user['id']}/premium", headers=admin_headers)
    assert revoked.json() == {"revoked": 1}, "nur die laufende Lizenz zählt als entzogen"
    with client.app.state.session_factory() as db:
        assert db.get(PremiumLicense, old_id).revoked_at is None, "eine abgelaufene Lizenz bleibt „abgelaufen“"


# ------------------------------------------------------------------------------------------------ Konten


def test_token_of_a_deleted_account_is_dead_even_if_the_ids_are_reused(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable
) -> None:
    """SQLite vergibt freie Nummern neu: Das nächste Konto bekommt dieselbe Benutzer- und Geräte-Nummer."""
    old = make_user("lena")
    old_tokens = login(client, "lena", "kinder-passwort")
    assert client.get("/api/me", headers=bearer(old_tokens)).status_code == 200
    assert client.delete(f"/api/users/{old['id']}", headers=admin_headers).status_code == 204
    time.sleep(1.1)  # die Token-Zeit ist auf Sekunden genau
    new = make_user("ben")
    assert new["id"] == old["id"], "Voraussetzung des Tests: die Nummer wird wiederverwendet"
    new_tokens = login(client, "ben", "kinder-passwort")
    assert client.get("/api/me", headers=bearer(new_tokens)).json()["username"] == "ben"
    stale = client.get("/api/me", headers=bearer(old_tokens))
    assert stale.status_code == 401, "das Token der gelöschten Lena darf Bens Konto nicht öffnen"


def test_two_admins_deleting_themselves_at_once_leave_one(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable
) -> None:
    make_user("zweiter", is_admin=True)
    first = bearer(login(client, "admin", ADMIN_PASSWORD))
    second = bearer(login(client, "zweiter", "kinder-passwort"))

    def delete(args: tuple[dict[str, str], str]) -> int:
        headers, password = args
        return client.post("/api/me/delete", headers=headers, json={"password": password}).status_code

    with ThreadPoolExecutor(max_workers=2) as pool:
        codes = list(pool.map(delete, [(first, ADMIN_PASSWORD), (second, "kinder-passwort")]))
    assert sorted(codes) == [204, 409], codes
    with client.app.state.session_factory() as db:
        assert len(db.scalars(select(User).where(User.is_admin.is_(True))).all()) == 1


def test_client_header_with_odd_digits_is_ignored_not_a_500() -> None:
    for build in ("²", "³", "١٢٣", "٤", "1２"):
        info = parse_client(f"platform=android; channel=play; version=1.0.0; build={build}")
        assert info is not None and info.build is None, build
    assert parse_client("platform=android; channel=play; version=1.0.0; build=54").build == 54


def test_admin_user_list_shows_the_last_activity(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable
) -> None:
    make_user("lena")
    headers = bearer(login(client, "lena", "kinder-passwort"))
    client.get("/api/me", headers=headers)
    users = {u["username"]: u for u in client.get("/api/admin/users", headers=admin_headers).json()}
    assert users["lena"]["last_active_at"] is not None


# ------------------------------------------------------------------------------------------------ Konfiguration


def test_config_rejects_a_forced_update_without_store_link_or_above_the_latest(
    client: TestClient, admin_headers: dict[str, str]
) -> None:
    """Vorher: Pflicht-Update ohne Store-Link ergab in der App einen Vollbildschirm ohne Knopf (Sackgasse)."""
    url = "/api/admin/config"
    no_link = client.put(url, headers=admin_headers, json={"play_min_build": 55})
    assert no_link.status_code == 400 and "Link" in no_link.json()["detail"]
    store = "https://play.google.com/store/apps/details?id=de.selfify.selfify.play"
    too_high = client.put(
        url, headers=admin_headers, json={"play_store_url": store, "play_latest_build": 10, "play_min_build": 500}
    )
    assert too_high.status_code == 400 and "größer" in too_high.json()["detail"]
    assert client.get(url, headers=admin_headers).json()["play_min_build"] == 0, "ein Fehler ändert nichts"
    ok = client.put(
        url, headers=admin_headers, json={"play_store_url": store, "play_latest_build": 60, "play_min_build": 55}
    )
    assert ok.status_code == 200
    # der Link darf nicht wieder geleert werden, solange ein Pflicht-Update eingestellt ist
    assert client.put(url, headers=admin_headers, json={"play_store_url": ""}).status_code == 400


# ------------------------------------------------------------------------------------------------ Wünsche


def test_wish_does_not_stay_in_progress_forever(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable
) -> None:
    make_user("lena")
    headers = bearer(login(client, "lena", "kinder-passwort"))
    wish = client.post("/api/requests", headers=headers, json={"title": "Du hast", "artist": "Rammstein"}).json()
    with client.app.state.session_factory() as db:
        job = DownloadJob(
            user_id=1, category_id=1, media_type="audio", video_id="vvvvvvvvvv1", title="Du hast", status="failed"
        )
        db.add(job)
        db.flush()
        item = db.get(SongRequest, wish["id"])
        item.status = "accepted"
        item.job_id = job.id
        db.commit()
    mine = client.get("/api/requests", headers=headers).json()
    assert mine[0]["status"] == "open", "ein gescheiterter Download macht den Wunsch wieder offen"
    # ohne Download-Eintrag wartet ein „in Arbeit“-Wunsch auch nicht ewig
    with client.app.state.session_factory() as db:
        db.get(SongRequest, wish["id"]).status = "accepted"
        db.get(SongRequest, wish["id"]).job_id = None
        db.commit()
    assert client.delete(f"/api/requests/{wish['id']}", headers=headers).status_code == 204


def test_support_limits_hold_under_parallel_requests(client: TestClient, make_user: Callable) -> None:
    make_user("lena")
    headers = bearer(login(client, "lena", "kinder-passwort"))
    with ThreadPoolExecutor(max_workers=10) as pool:
        codes = list(
            pool.map(
                lambda i: client.post("/api/requests", headers=headers, json={"title": f"Song {i}"}).status_code,
                range(40),
            )
        )
    assert codes.count(201) == 15, "Tageslimit von 15 Wünschen"
    with ThreadPoolExecutor(max_workers=10) as pool:
        codes = list(
            pool.map(
                lambda i: (
                    client.post(
                        "/api/bugreports", headers=headers, json={"message": f"Fehler Nummer {i} ist da"}
                    ).status_code
                ),
                range(30),
            )
        )
    assert codes.count(201) == 10, "Stundenlimit von 10 Fehlermeldungen"


# ------------------------------------------------------------------------------------------------ Downloads & Statistik


def test_clearing_the_download_list_does_not_wipe_the_dashboard_numbers(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable
) -> None:
    """Vorher: „Fertige entfernen“ löschte die Zeilen – danach zeigte das Dashboard überall 0."""
    user = make_user("lena")
    headers = bearer(login(client, "lena", "kinder-passwort"))
    with client.app.state.session_factory() as db:
        for i, status in enumerate(("done", "done", "done", "failed")):
            db.add(
                DownloadJob(
                    user_id=user["id"],
                    category_id=1,
                    media_type="audio",
                    video_id=f"aaaaaaaaaa{i}",
                    title=f"Song {i}",
                    status=status,
                )
            )
        db.commit()
    stats = client.get("/api/admin/stats", headers=admin_headers).json()
    assert (stats["downloads_total"], stats["downloads_done"], stats["downloads_failed"]) == (4, 3, 1)
    assert len(client.get("/api/downloads", headers=headers).json()) == 4

    assert client.delete("/api/downloads", headers=headers).status_code == 204
    assert client.get("/api/downloads", headers=headers).json() == [], "die Liste ist leer"
    stats = client.get("/api/admin/stats", headers=admin_headers).json()
    assert (stats["downloads_total"], stats["downloads_done"], stats["downloads_failed"]) == (4, 3, 1)
    assert stats["top_downloaders"][0]["count"] == 4
    assert sum(day["count"] for day in stats["downloads_by_day"]) == 4
    users = {u["username"]: u for u in client.get("/api/admin/users", headers=admin_headers).json()}
    assert users["lena"]["downloads"] == 4


def test_removing_a_single_download_hides_it_for_everyone_but_keeps_the_numbers(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable
) -> None:
    user = make_user("lena")
    headers = bearer(login(client, "lena", "kinder-passwort"))
    with client.app.state.session_factory() as db:
        job = DownloadJob(
            user_id=user["id"], category_id=1, media_type="audio", video_id="bbbbbbbbbb1", title="Song", status="done"
        )
        db.add(job)
        db.commit()
        job_id = job.id
    assert client.delete(f"/api/downloads/{job_id}", headers=admin_headers).status_code == 204  # Admin entfernt
    assert client.get("/api/downloads", headers=headers).json() == []
    assert client.get("/api/downloads?scope=all", headers=admin_headers).json() == []
    assert client.get("/api/admin/stats", headers=admin_headers).json()["downloads_total"] == 1


# ------------------------------------------------------------------------------------------------ Migration


def test_migration_0006_cleans_duplicates_and_matches_the_models(tmp_path: Path) -> None:
    db_file = tmp_path / "migration.db"
    url = f"sqlite:///{db_file}"
    config = alembic_config(url)
    command.upgrade(config, "0005")
    now = "2026-11-04 12:00:00.000000"
    with sqlite3.connect(db_file) as con:
        con.execute(
            "INSERT INTO users (id, username, display_name, password_hash, is_admin, is_active, can_download, "
            "created_at, updated_at) VALUES (1, 'a', 'A', 'x', 0, 1, 1, ?, ?)",
            (now, now),
        )
        con.execute(
            "INSERT INTO premium_codes (id, code, label, max_redemptions, redeemed_count, created_at) "
            "VALUES (1, 'AAAA', '', 5, 3, ?)",
            (now,),
        )
        for _ in range(3):  # drei Lizenzen desselben Benutzers für denselben Code (Folge des Einlöse-Rennens)
            con.execute(
                "INSERT INTO premium_licenses (user_id, code_id, source, starts_at, expires_at, note, created_at) "
                "VALUES (1, 1, 'code', ?, ?, '', ?)",
                (now, "2027-01-01 00:00:00.000000", now),
            )
        for _ in range(2):  # vom Admin vergebene Lizenzen (ohne Code) dürfen mehrfach vorkommen
            con.execute(
                "INSERT INTO premium_licenses (user_id, code_id, source, starts_at, note, created_at) "
                "VALUES (1, NULL, 'admin', ?, '', ?)",
                (now, now),
            )
    command.upgrade(config, "0006")
    with sqlite3.connect(db_file) as con:
        assert con.execute("SELECT count(*) FROM premium_licenses WHERE code_id = 1").fetchone()[0] == 1
        assert con.execute("SELECT count(*) FROM premium_licenses WHERE code_id IS NULL").fetchone()[0] == 2
        columns = [row[1] for row in con.execute("PRAGMA table_info(download_jobs)")]
        assert "hidden_at" in columns
    # Modelle und Datenbank stimmen überein (sonst hätte jemand eine Migration vergessen)
    engine = create_engine(url)
    with engine.connect() as connection:
        context = MigrationContext.configure(connection, opts={"compare_type": True, "render_as_batch": True})
        assert compare_metadata(context, Base.metadata) == []
    engine.dispose()
    # zurück und wieder hoch
    command.downgrade(config, "0005")
    command.upgrade(config, "head")
