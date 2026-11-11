"""Premium Teil 2: Leistungen einzeln schaltbar, Codes mit Leistungsumfang, Laufzeiten (Basis-Abos) bei Google Play.

Grundsatz: Mit den Standardeinstellungen ändert sich nichts – das prüfen die ersten Tests ausdrücklich.
"""

import sqlite3
from collections.abc import Callable
from datetime import timedelta
from pathlib import Path
from typing import Any

import pytest
from alembic import command
from alembic.autogenerate import compare_metadata
from alembic.migration import MigrationContext
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select

from app.database import alembic_config
from app.models import Base, PlayPurchase, PremiumLicense, SongRequest, User, utcnow
from app.services import features
from app.services.features import FEATURES
from app.services.play_billing import VerifierUnavailable, parse_subscription
from app.services.premium import close_gaps

from .conftest import Library, bearer, login
from .fake_play import FakePlayVerifier, sub
from .test_premium import new_codes, parse, redeem, user_headers

PRODUCT = "premium"
TOKEN_A = "kauf-token-monatlich-aaaaaaaa"
TOKEN_B = "kauf-token-jaehrlich-bbbbbbbb"
ALL_SWITCHES = {
    "offline_requires_premium": True,
    "hq_audio_requires_premium": True,
    "video_requires_premium": True,
    "lyrics_requires_premium": True,
    "requests_requires_premium": True,
    "skips_requires_premium": True,
}
DAILY_LIMIT_TEXT = "Du hast heute schon sehr viele Wünsche geschickt. Versuche es morgen wieder."


def put_config(client: TestClient, headers: dict[str, str], **values: object):  # type: ignore[no-untyped-def]
    return client.put("/api/admin/config", headers=headers, json=values)


def configure(client: TestClient, headers: dict[str, str], **values: object) -> dict:
    response = put_config(client, headers, **values)
    assert response.status_code == 200, response.text
    return response.json()


def premium(client: TestClient, headers: dict[str, str]) -> dict:
    response = client.get("/api/premium", headers=headers)
    assert response.status_code == 200, response.text
    return response.json()


def wish(client: TestClient, headers: dict[str, str], n: int):  # type: ignore[no-untyped-def]
    return client.post("/api/requests", headers=headers, json={"title": f"Lied {n}", "artist": "Band"})


def quota(client: TestClient, headers: dict[str, str]) -> dict:
    response = client.get("/api/requests/quota", headers=headers)
    assert response.status_code == 200, response.text
    return response.json()


def lib_user(lib: Library, name: str) -> tuple[dict, dict[str, str]]:
    created = lib.client.post("/api/users", headers=lib.headers, json={"username": name, "password": "kinder-passwort"})
    assert created.status_code == 201, created.text
    return created.json(), bearer(login(lib.client, name, "kinder-passwort"))


def give_code(client: TestClient, admin: dict[str, str], user: dict[str, str], **body: object) -> dict:
    (code,) = new_codes(client, admin, **body)
    response = redeem(client, user, code["code"])
    assert response.status_code == 200, response.text
    return code


class SpyTranscoder:
    """Merkt sich, mit welcher Bitrate umgewandelt wird (und wandelt wirklich um)."""

    def __init__(self, real: Any, available: bool | None = None) -> None:
        self.real = real
        self.bitrates: list[int] = []
        self._available = available

    @property
    def available(self) -> bool:
        return self.real.available if self._available is None else self._available

    def get(self, path: Path, version: str, bitrate: int) -> Path:
        self.bitrates.append(bitrate)
        return self.real.get(path, version, bitrate)


def stream(lib: Library, track_id: int, headers: dict[str, str], **params: object):  # type: ignore[no-untyped-def]
    return lib.client.get(f"/api/tracks/{track_id}/stream", headers=headers, params=params)


def add_lyrics(lib: Library) -> dict:
    """Legt eine .lrc-Datei neben „Bohemian Rhapsody“."""
    (mp3,) = lib.settings.media_dir.rglob("01 - Bohemian Rhapsody.mp3")
    mp3.with_suffix(".lrc").write_text("[00:01.00]Is this the real life?\n[00:02.50]Is this just fantasy?\n")
    return lib.track_by_title("Bohemian Rhapsody")


# ------------------------------------------------------------------------- Standard: nichts ändert sich


def test_public_config_keeps_old_fields_and_adds_defaults(client: TestClient, admin_headers: dict[str, str]) -> None:
    config = client.get("/api/app/config", params={"channel": "play", "build": 60}).json()
    # bisherige Felder unverändert
    assert config["offline_requires_premium"] is False and config["offline_grace_days"] == 7
    assert config["billing_enabled"] is False and config["billing_product_ids"] == []
    assert config["premium_enabled"] is True and config["ads_enabled"] is False and config["update"]["level"] == "none"
    # neue Felder mit Standardwerten = heutiges Verhalten
    assert config["premium_only"] == []
    assert config["free_audio_quality"] == "normal"
    assert config["free_requests_per_week"] == 3 and config["free_skips_per_hour"] == 6
    assert config["premium_badge_enabled"] is False
    assert config["billing_base_plans"] == [] and config["billing_recommended_plan"] == ""

    admin = client.get("/api/admin/config", headers=admin_headers).json()
    for key in ALL_SWITCHES:
        assert admin[key] is False, key
    assert admin["free_audio_quality"] == "normal" and admin["premium_badge_enabled"] is False
    assert admin["billing_base_plans"] == "" and admin["billing_recommended_plan"] == ""
    assert isinstance(admin["transcode_available"], bool)
    # nur lesbar: wird beim Speichern ignoriert und nicht in der Datenbank abgelegt
    saved = configure(client, admin_headers, transcode_available=False, ads_enabled=False)
    assert saved["transcode_available"] == admin["transcode_available"]


def test_premium_status_with_old_code_has_all_features_and_nothing_locked(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable
) -> None:
    _, plain = user_headers(client, make_user, "tom")
    status = premium(client, plain)
    assert status["active"] is False and status["features"] == [] and status["locked"] == []
    assert status["premium_only"] == [] and status["badge"] is False and status["offline_allowed"] is True

    _, lena = user_headers(client, make_user, "lena")
    code = give_code(client, admin_headers, lena)
    assert code["features"] is None, "ohne Auswahl schaltet ein Code alles frei (wie bisher)"
    status = premium(client, lena)
    assert status["active"] is True and status["features"] == list(FEATURES)
    assert status["locked"] == [] and status["offline_allowed"] is True and status["badge"] is False
    licenses = client.get("/api/admin/premium/licenses", headers=admin_headers).json()
    assert [lic["features"] for lic in licenses] == [None]
    users = client.get("/api/admin/users", headers=admin_headers).json()
    assert next(u for u in users if u["username"] == "lena")["premium"]["features"] == list(FEATURES)


def test_defaults_keep_streams_videos_and_lyrics_as_before(lib: Library) -> None:
    _, headers = lib_user(lib, "lena")
    spy = SpyTranscoder(lib.client.app.state.transcoder)
    lib.client.app.state.transcoder = spy
    track = add_lyrics(lib)
    original = stream(lib, track["id"], headers, quality="original")
    assert original.status_code == 200 and original.headers["content-type"] == "audio/mpeg"
    assert len(original.content) == track["file_size"] and spy.bitrates == []
    video = lib.get("/api/tracks", media_type="video")["items"][0]
    full = stream(lib, video["id"], headers)
    assert full.status_code == 200 and full.headers["content-type"] == "video/mp4"
    lyrics = lib.client.get(f"/api/tracks/{track['id']}/lyrics", headers=headers)
    assert lyrics.status_code == 200 and lyrics.json()["lines"][0]["text"] == "Is this the real life?"


def test_defaults_keep_the_old_wish_limits(client: TestClient, make_user: Callable) -> None:
    _, headers = user_headers(client, make_user, "lena")
    for n in range(15):
        assert wish(client, headers, n).status_code == 201
    blocked = wish(client, headers, 15)
    assert blocked.status_code == 429 and blocked.json()["detail"] == DAILY_LIMIT_TEXT
    assert quota(client, headers) == {"limited": False, "limit": None, "used": 15, "left": None, "resets_at": None}


# ------------------------------------------------------------------------- Migration 0008


def test_migration_0008_keeps_existing_data_and_matches_the_models(tmp_path: Path) -> None:
    db_file = tmp_path / "migration.db"
    url = f"sqlite:///{db_file}"
    config = alembic_config(url)
    command.upgrade(config, "0007")
    now = "2026-11-10 12:00:00.000000"
    with sqlite3.connect(db_file) as con:
        con.execute(
            "INSERT INTO users (id, username, display_name, password_hash, is_admin, is_active, can_download, "
            "created_at, updated_at) VALUES (2, 'lena', 'Lena', 'x', 0, 1, 1, ?, ?)",
            (now, now),
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
            "INSERT INTO premium_licenses (id, user_id, code_id, source, starts_at, expires_at, note, created_at) "
            "VALUES (2, 2, NULL, 'play', ?, '2026-12-10 12:00:00.000000', 'Google Play: premium', ?)",
            (now, now),
        )
        con.execute(
            "INSERT INTO play_purchases (user_id, product_id, purchase_token, token_hash, order_id, state, "
            "auto_renewing, acknowledged, is_test, license_id, last_checked_at, last_error, created_at, updated_at) "
            "VALUES (2, 'premium', 'tok', ?, 'GPA.1', 'active', 1, 1, 0, 2, ?, '', ?, ?)",
            ("h" * 64, now, now, now),
        )
        licenses_before = con.execute("SELECT * FROM premium_licenses ORDER BY id").fetchall()
        purchases_before = con.execute("SELECT * FROM play_purchases ORDER BY id").fetchall()
        codes_before = con.execute("SELECT * FROM premium_codes ORDER BY id").fetchall()

    command.upgrade(config, "0008")
    with sqlite3.connect(db_file) as con:
        # Bestandsdaten bleiben; die neuen Spalten stehen auf „alle Leistungen“ bzw. „Laufzeit unbekannt“
        assert con.execute("SELECT features FROM premium_codes").fetchall() == [(None,)]
        assert con.execute("SELECT features FROM premium_licenses ORDER BY id").fetchall() == [(None,), (None,)]
        assert con.execute("SELECT base_plan_id, offer_id FROM play_purchases").fetchall() == [("", "")]
        assert [row[:-1] for row in con.execute("SELECT * FROM premium_licenses ORDER BY id")] == licenses_before
        # die neuen Spalten stehen jeweils hinten
        assert [row[:-1] for row in con.execute("SELECT * FROM premium_codes ORDER BY id")] == codes_before
        assert [row[:-2] for row in con.execute("SELECT * FROM play_purchases ORDER BY id")] == purchases_before
        # keine neuen Schalter in der Datenbank: Es gelten die Standardwerte
        assert con.execute("SELECT count(*) FROM app_settings").fetchone()[0] == 0

    # Seit 0009 (Selbst-Registrierung) passen die Modelle erst zum neuesten Stand – deshalb vorher bis head; den
    # Stand 0009 prüft tests/test_visibility.py
    command.upgrade(config, "head")
    engine = create_engine(url)
    with engine.connect() as connection:
        context = MigrationContext.configure(connection, opts={"compare_type": True, "render_as_batch": True})
        assert compare_metadata(context, Base.metadata) == []
    engine.dispose()

    # Teil-Lizenz anlegen, dann zurück: Die Spalten verschwinden, die Daten (auch der Bezug Kauf -> Lizenz) bleiben
    with sqlite3.connect(db_file) as con:
        con.execute("UPDATE premium_licenses SET features = 'video,lyrics' WHERE id = 1")
        con.execute("UPDATE play_purchases SET base_plan_id = 'jaehrlich'")
    command.downgrade(config, "0007")
    with sqlite3.connect(db_file) as con:
        assert con.execute("SELECT * FROM premium_licenses ORDER BY id").fetchall() == licenses_before
        assert con.execute("SELECT * FROM play_purchases ORDER BY id").fetchall() == purchases_before
        assert con.execute("SELECT * FROM premium_codes ORDER BY id").fetchall() == codes_before
        cols = {row[1] for row in con.execute("PRAGMA table_info(premium_licenses)")}
        assert "features" not in cols
    command.upgrade(config, "head")
    with sqlite3.connect(db_file) as con:
        assert con.execute("SELECT features FROM premium_licenses ORDER BY id").fetchall() == [(None,), (None,)]


# ------------------------------------------------------------------------- Einstellungen


@pytest.mark.parametrize(
    ("values", "message"),
    [
        ({"free_audio_quality": "high"}, "free_audio_quality: „normal“ oder „low“ erwartet."),
        ({"free_requests_per_week": 101}, "free_requests_per_week: eine Zahl von 0 bis 100 erwartet."),
        ({"free_requests_per_week": -1}, "free_requests_per_week: eine Zahl von 0 bis 100 erwartet."),
        ({"free_skips_per_hour": 0}, "free_skips_per_hour: eine Zahl von 1 bis 100 erwartet."),
        ({"free_skips_per_hour": 101}, "free_skips_per_hour: eine Zahl von 1 bis 100 erwartet."),
        ({"billing_base_plans": "monatlich,jährlich"}, "billing_base_plans: Kennungen"),
        ({"billing_base_plans": "Monatlich"}, "billing_base_plans: Kennungen"),
        ({"billing_base_plans": "-monatlich"}, "billing_base_plans: Kennungen"),
        ({"billing_base_plans": "a,b,c,d,e,f,g"}, "billing_base_plans: Kennungen"),
        ({"billing_base_plans": "monatlich,monatlich"}, "billing_base_plans: Kennungen"),
        ({"billing_base_plans": "a" * 64}, "billing_base_plans: Kennungen"),
        (
            {"billing_base_plans": "monatlich", "billing_recommended_plan": "jaehrlich"},
            "billing_recommended_plan: Die empfohlene Laufzeit muss in der Liste der Laufzeiten stehen.",
        ),
        (
            {"billing_recommended_plan": "monatlich"},
            "billing_recommended_plan: Die empfohlene Laufzeit muss in der Liste der Laufzeiten stehen.",
        ),
    ],
)
def test_new_settings_are_checked(
    client: TestClient, admin_headers: dict[str, str], values: dict, message: str
) -> None:
    response = put_config(client, admin_headers, **values)
    assert response.status_code == 400, response.text
    assert response.json()["detail"].startswith(message)
    # nichts gespeichert
    assert client.get("/api/admin/config", headers=admin_headers).json()["billing_base_plans"] == ""


def test_base_plans_are_normalized_and_the_recommendation_must_stay_in_the_list(
    client: TestClient, admin_headers: dict[str, str]
) -> None:
    saved = configure(
        client, admin_headers, billing_base_plans=" jaehrlich , monatlich,, halbjaehrlich ",
        billing_recommended_plan="jaehrlich",
    )
    assert saved["billing_base_plans"] == "jaehrlich,monatlich,halbjaehrlich"
    assert saved["billing_recommended_plan"] == "jaehrlich"
    # Laufzeit aus der Liste nehmen, die noch empfohlen ist -> abgelehnt
    refused = put_config(client, admin_headers, billing_base_plans="monatlich")
    assert refused.status_code == 400
    assert configure(client, admin_headers, billing_base_plans="monatlich", billing_recommended_plan="")[
        "billing_base_plans"
    ] == "monatlich"
    assert configure(client, admin_headers, billing_base_plans="")["billing_base_plans"] == ""
    # Grenzen sind erlaubt
    edges = configure(
        client, admin_headers, free_requests_per_week=0, free_skips_per_hour=100, free_audio_quality="low"
    )
    assert (edges["free_requests_per_week"], edges["free_skips_per_hour"], edges["free_audio_quality"]) == (
        0, 100, "low",
    )


def test_quality_switch_needs_ffmpeg(client: TestClient, admin_headers: dict[str, str]) -> None:
    client.app.state.transcoder = SpyTranscoder(client.app.state.transcoder, available=False)
    assert client.get("/api/admin/config", headers=admin_headers).json()["transcode_available"] is False
    refused = put_config(client, admin_headers, hq_audio_requires_premium=True)
    assert refused.status_code == 400 and refused.json()["detail"] == features.MSG_HQ_NEEDS_FFMPEG
    assert client.get("/api/admin/config", headers=admin_headers).json()["hq_audio_requires_premium"] is False
    # die anderen Leistungen gehen ohne ffmpeg
    assert configure(client, admin_headers, video_requires_premium=True)["video_requires_premium"] is True
    # war es schon an (ffmpeg später entfernt), lässt es sich weiter speichern und ausschalten
    client.app.state.transcoder._available = True
    configure(client, admin_headers, hq_audio_requires_premium=True)
    client.app.state.transcoder._available = False
    assert configure(client, admin_headers, hq_audio_requires_premium=True, ads_enabled=True)["ads_enabled"] is True
    assert configure(client, admin_headers, hq_audio_requires_premium=False)["hq_audio_requires_premium"] is False


def test_public_config_lists_premium_only_and_plans_only_with_working_billing(
    client: TestClient, admin_headers: dict[str, str]
) -> None:
    configure(
        client, admin_headers, video_requires_premium=True, lyrics_requires_premium=True, offline_requires_premium=True,
        free_audio_quality="low", free_requests_per_week=5, free_skips_per_hour=2, premium_badge_enabled=True,
        billing_enabled=True, billing_product_ids=PRODUCT, billing_base_plans="monatlich,jaehrlich",
        billing_recommended_plan="jaehrlich",
    )
    config = client.get("/api/app/config", params={"channel": "play"}).json()
    # FEATURES-Reihenfolge, ohne no_ads und badge
    assert config["premium_only"] == ["offline", "video", "lyrics"]
    assert (config["free_audio_quality"], config["free_requests_per_week"], config["free_skips_per_hour"]) == (
        "low", 5, 2,
    )
    assert config["premium_badge_enabled"] is True
    # Kaufprüfung nicht eingerichtet -> keine Laufzeiten (wie billing_product_ids)
    assert config["billing_enabled"] is False and config["billing_base_plans"] == []
    assert config["billing_recommended_plan"] == ""
    client.app.state.purchase_verifier = FakePlayVerifier()
    config = client.get("/api/app/config", params={"channel": "play"}).json()
    assert config["billing_base_plans"] == ["monatlich", "jaehrlich"]
    assert config["billing_recommended_plan"] == "jaehrlich"
    github = client.get("/api/app/config", params={"channel": "full"}).json()
    assert github["billing_base_plans"] == [] and github["premium_only"] == ["offline", "video", "lyrics"]


# ------------------------------------------------------------------------- Leistungen auf dem Server


def test_quality_is_capped_without_premium(lib: Library) -> None:
    configure(lib.client, lib.headers, hq_audio_requires_premium=True)
    _, plain = lib_user(lib, "tom")
    _, paid = lib_user(lib, "lena")
    give_code(lib.client, lib.headers, paid)
    spy = SpyTranscoder(lib.client.app.state.transcoder)
    lib.client.app.state.transcoder = spy
    track = lib.track_by_title("Bohemian Rhapsody")  # 320 kbit/s mp3

    capped = stream(lib, track["id"], plain, quality="original")
    assert capped.status_code == 200 and capped.headers["content-type"] == "audio/mp4"
    assert spy.bitrates == [160]
    assert stream(lib, track["id"], plain, quality="high").status_code == 200 and spy.bitrates[-1] == 160
    # niedriger als die Grenze bleibt, wie gewünscht
    assert stream(lib, track["id"], plain, quality="low").status_code == 200 and spy.bitrates[-1] == 96
    status = premium(lib.client, plain)
    assert status["locked"] == ["hq_audio"] and status["premium_only"] == ["hq_audio"]

    configure(lib.client, lib.headers, free_audio_quality="low")
    spy.bitrates.clear()
    assert stream(lib, track["id"], plain, quality="original").status_code == 200 and spy.bitrates == [96]

    # Premium und Admin: Original
    spy.bitrates.clear()
    for headers in (paid, lib.headers):
        full = stream(lib, track["id"], headers, quality="original")
        assert full.headers["content-type"] == "audio/mpeg" and len(full.content) == track["file_size"]
    assert spy.bitrates == []
    assert premium(lib.client, paid)["locked"] == [] and premium(lib.client, lib.headers)["locked"] == []


def test_videos_play_only_as_sound_without_premium(lib: Library) -> None:
    configure(lib.client, lib.headers, video_requires_premium=True)
    _, plain = lib_user(lib, "tom")
    _, paid = lib_user(lib, "lena")
    give_code(lib.client, lib.headers, paid)
    video = lib.get("/api/tracks", media_type="video")["items"][0]

    refused = stream(lib, video["id"], plain)
    assert refused.status_code == 403 and refused.json()["detail"] == features.MSG_VIDEO
    sound = stream(lib, video["id"], plain, audio_only="true")
    assert sound.status_code == 200 and sound.headers["content-type"] == "audio/mp4"
    # Musik ist nicht betroffen
    song = lib.track_by_title("Bohemian Rhapsody")
    assert stream(lib, song["id"], plain).headers["content-type"] == "audio/mpeg"
    for headers in (paid, lib.headers):
        full = stream(lib, video["id"], headers)
        assert full.status_code == 200 and full.headers["content-type"] == "video/mp4"


def test_lyrics_need_premium_when_switched(lib: Library) -> None:
    configure(lib.client, lib.headers, lyrics_requires_premium=True)
    _, plain = lib_user(lib, "tom")
    _, paid = lib_user(lib, "lena")
    give_code(lib.client, lib.headers, paid)
    track = add_lyrics(lib)
    url = f"/api/tracks/{track['id']}/lyrics"
    refused = lib.client.get(url, headers=plain)
    assert refused.status_code == 403 and refused.json()["detail"] == features.MSG_LYRICS
    assert lib.client.get(url, headers=paid).status_code == 200
    assert lib.client.get(url, headers=lib.headers).status_code == 200
    # unbekannter Titel bleibt 404 (vor der Sperre)
    missing = lib.client.get("/api/tracks/99999/lyrics", headers=plain)
    assert missing.status_code == 404 and missing.json()["detail"] == "Titel nicht gefunden."


def test_weekly_wish_limit_without_premium(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable
) -> None:
    configure(client, admin_headers, requests_requires_premium=True)
    _, headers = user_headers(client, make_user, "lena")
    assert quota(client, headers) == {"limited": True, "limit": 3, "used": 0, "left": 3, "resets_at": None}
    created = [wish(client, headers, n) for n in range(3)]
    assert all(r.status_code == 201 for r in created)
    blocked = wish(client, headers, 3)
    assert blocked.status_code == 429
    assert blocked.json()["detail"] == (
        "Du hast diese Woche schon 3 Wünsche geschickt. Mit Premium kannst du unbegrenzt wünschen."
    )
    state = quota(client, headers)
    assert (state["limited"], state["limit"], state["used"], state["left"]) == (True, 3, 3, 0)
    first_created = parse(created[0].json()["created_at"])
    assert first_created is not None
    assert parse(state["resets_at"]) == first_created + timedelta(days=7)

    # Zurückziehen gibt den Platz frei
    assert client.delete(f"/api/requests/{created[2].json()['id']}", headers=headers).status_code == 204
    assert quota(client, headers)["left"] == 1
    assert wish(client, headers, 4).status_code == 201
    assert wish(client, headers, 5).status_code == 429

    # nach 7 Tagen wieder frei (rollierend)
    with client.app.state.session_factory() as db:
        for row in db.scalars(select(SongRequest)).unique():
            row.created_at = utcnow() - timedelta(days=7, minutes=1)
        db.commit()
    assert quota(client, headers)["used"] == 0
    assert wish(client, headers, 6).status_code == 201

    # Einzahl
    configure(client, admin_headers, free_requests_per_week=1)
    one = wish(client, headers, 7)
    assert one.status_code == 429
    assert one.json()["detail"] == (
        "Du hast diese Woche schon 1 Wunsch geschickt. Mit Premium kannst du unbegrenzt wünschen."
    )

    # 0 = ohne Premium gar keine Wünsche
    configure(client, admin_headers, free_requests_per_week=0)
    none = wish(client, headers, 8)
    assert none.status_code == 403 and none.json()["detail"] == features.MSG_REQUESTS_NONE
    assert quota(client, headers)["left"] == 0


def test_premium_wishes_have_no_weekly_limit_but_keep_the_old_limits(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable
) -> None:
    configure(client, admin_headers, requests_requires_premium=True, free_requests_per_week=0)
    _, headers = user_headers(client, make_user, "lena")
    give_code(client, admin_headers, headers, features=["requests"])
    for n in range(15):
        assert wish(client, headers, n).status_code == 201
    assert wish(client, headers, 15).json()["detail"] == DAILY_LIMIT_TEXT
    assert quota(client, headers) == {"limited": False, "limit": None, "used": 15, "left": None, "resets_at": None}
    # Admins: ebenfalls ohne Wochengrenze
    assert wish(client, admin_headers, 1).status_code == 201
    assert quota(client, admin_headers)["limited"] is False


def test_offline_follows_the_scope_of_the_code(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable
) -> None:
    configure(client, admin_headers, offline_requires_premium=True, offline_min_client_build=100)
    _, without = user_headers(client, make_user, "tom")
    _, with_offline = user_headers(client, make_user, "lena")
    give_code(client, admin_headers, without, features=["video"])
    give_code(client, admin_headers, with_offline, features=["offline"])
    status = premium(client, without)
    assert status["active"] is True and status["features"] == ["video"]
    assert status["offline_allowed"] is False and status["locked"] == ["offline"]
    assert premium(client, with_offline)["offline_allowed"] is True
    # 426 für alte Apps: Ausgenommen ist nur, wessen Premium Offline-Hören umfasst (Titel 99999 gibt es nicht ->
    # ohne Sperre käme 404)
    old_app = {"X-Selfify-Client": "platform=android; channel=play; version=1.0.0; build=50"}
    assert client.get("/api/tracks/99999/stream", headers={**without, **old_app}).status_code == 426
    assert client.get("/api/tracks/99999/stream", headers={**with_offline, **old_app}).status_code == 404


def test_badge_needs_switch_and_premium(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable
) -> None:
    _, paid = user_headers(client, make_user, "lena")
    _, partial = user_headers(client, make_user, "tom")
    give_code(client, admin_headers, paid)
    give_code(client, admin_headers, partial, features=["video"])
    assert premium(client, paid)["badge"] is False, "Schalter aus"
    configure(client, admin_headers, premium_badge_enabled=True)
    assert premium(client, paid)["badge"] is True
    assert premium(client, partial)["badge"] is False
    assert premium(client, admin_headers)["badge"] is False, "Admin ohne Premium"
    # das Abzeichen sperrt nichts
    assert premium(client, partial)["locked"] == []


# ------------------------------------------------------------------------- Codes mit Leistungsumfang


def test_code_with_partial_scope_end_to_end(lib: Library) -> None:
    """Pflicht: Code mit Teilumfang erzeugen -> einlösen -> genau diese Leistungen frei, andere nicht."""
    configure(
        lib.client, lib.headers, offline_requires_premium=True, video_requires_premium=True,
        lyrics_requires_premium=True, hq_audio_requires_premium=True,
    )
    (code,) = new_codes(lib.client, lib.headers, features=["lyrics", "video"])
    assert code["features"] == ["video", "lyrics"]
    listed = lib.client.get("/api/admin/premium/codes", headers=lib.headers).json()
    assert listed[0]["features"] == ["video", "lyrics"]

    user, headers = lib_user(lib, "lena")
    before = premium(lib.client, headers)
    assert before["locked"] == ["offline", "hq_audio", "video", "lyrics"]
    redeemed = redeem(lib.client, headers, code["code"])
    assert redeemed.status_code == 200, redeemed.text
    status = redeemed.json()
    assert status["active"] is True and status["features"] == ["video", "lyrics"]
    assert status == {**premium(lib.client, headers), "checked_at": status["checked_at"]}
    assert status["locked"] == ["offline", "hq_audio"]
    assert status["offline_allowed"] is False
    assert status["premium_only"] == ["offline", "hq_audio", "video", "lyrics"]

    spy = SpyTranscoder(lib.client.app.state.transcoder)
    lib.client.app.state.transcoder = spy
    video = lib.get("/api/tracks", media_type="video")["items"][0]
    watched = stream(lib, video["id"], headers)
    assert watched.status_code == 200 and watched.headers["content-type"] == "video/mp4"
    track = add_lyrics(lib)
    assert lib.client.get(f"/api/tracks/{track['id']}/lyrics", headers=headers).status_code == 200
    capped = stream(lib, track["id"], headers, quality="original")
    assert capped.headers["content-type"] == "audio/mp4" and spy.bitrates == [160]

    # Lizenzlisten zeigen den Umfang
    running = lib.client.get("/api/admin/premium/licenses?only_running=true", headers=lib.headers).json()
    assert [(lic["username"], lic["features"]) for lic in running] == [("lena", ["video", "lyrics"])]
    mine = lib.client.get(f"/api/admin/users/{user['id']}/premium", headers=lib.headers).json()
    assert mine["features"] == ["video", "lyrics"] and mine["licenses"][0]["features"] == ["video", "lyrics"]
    users = lib.client.get("/api/admin/users", headers=lib.headers).json()
    assert next(u for u in users if u["username"] == "lena")["premium"]["features"] == ["video", "lyrics"]


def test_code_scope_is_validated(client: TestClient, admin_headers: dict[str, str]) -> None:
    url = "/api/admin/premium/codes"
    empty = client.post(url, headers=admin_headers, json={"duration_days": 30, "features": []})
    assert empty.status_code == 422 and "Bitte mindestens eine Leistung wählen." in empty.text
    unknown = client.post(url, headers=admin_headers, json={"duration_days": 30, "features": ["video", "kaffee"]})
    assert unknown.status_code == 422
    (everything,) = new_codes(client, admin_headers, features=list(reversed(FEATURES)))
    assert everything["features"] is None
    (merged,) = new_codes(client, admin_headers, features=["lyrics", "video", "lyrics"])
    assert merged["features"] == ["video", "lyrics"]
    assert client.get(url, headers=admin_headers).status_code == 200
    with client.app.state.session_factory() as db:
        from app.models import PremiumCode

        stored = {row.id: row.features for row in db.scalars(select(PremiumCode))}
    assert stored == {everything["id"]: None, merged["id"]: "video,lyrics"}


def _licenses(client: TestClient, username: str) -> list[PremiumLicense]:
    with client.app.state.session_factory() as db:
        user = db.scalar(select(User).where(User.username == username))
        assert user is not None
        return list(
            db.scalars(select(PremiumLicense).where(PremiumLicense.user_id == user.id).order_by(PremiumLicense.id))
            .unique()
        )


def test_stacking_respects_the_scope(client: TestClient, admin_headers: dict[str, str], make_user: Callable) -> None:
    _, lena = user_headers(client, make_user, "lena")
    give_code(client, admin_headers, lena, duration_days=30)
    # voller Code hinter vollem: angehängt (wie bisher)
    give_code(client, admin_headers, lena, duration_days=10)
    full1, full2 = _licenses(client, "lena")
    assert full2.starts_at == full1.expires_at
    # Teil-Code während voller Lizenzen: Die vollen enthalten ihn ganz -> angehängt (hinter beide)
    give_code(client, admin_headers, lena, duration_days=5, features=["video"])
    *_, partial = _licenses(client, "lena")
    assert partial.starts_at == full2.expires_at

    _, tom = user_headers(client, make_user, "tom")
    give_code(client, admin_headers, tom, duration_days=30, features=["video"])
    # voller Code während eines Teil-Codes: Der Teil-Code enthält ihn nicht -> beginnt sofort
    give_code(client, admin_headers, tom, duration_days=10)
    part, full = _licenses(client, "tom")
    assert abs(full.starts_at - utcnow()) < timedelta(minutes=1)
    assert set(premium(client, tom)["features"]) == set(FEATURES)
    # Teil-Code hinter Teil-Code mit gleichem Umfang: angehängt
    give_code(client, admin_headers, tom, duration_days=7, features=["video"])
    *_, same = _licenses(client, "tom")
    assert same.starts_at == part.expires_at
    # anderer Teilumfang (Songtexte): Die Video-Lizenzen enthalten ihn nicht, die volle schon -> er hängt sich nur
    # hinter die volle Lizenz
    give_code(client, admin_headers, tom, duration_days=3, features=["lyrics"])
    *_, other = _licenses(client, "tom")
    assert other.starts_at == full.expires_at

    _, mia = user_headers(client, make_user, "mia")
    # unbegrenzter Teil-Code + voller befristeter Code -> erlaubt, beginnt sofort
    give_code(client, admin_headers, mia, unlimited=True, duration_days=None, features=["video"])
    give_code(client, admin_headers, mia, duration_days=30)
    _, timed = _licenses(client, "mia")
    assert abs(timed.starts_at - utcnow()) < timedelta(minutes=1)
    status = premium(client, mia)
    assert status["unlimited"] is True and status["features"] == list(FEATURES)
    # ein weiterer Teil-Code mit Video: das unbegrenzte enthält ihn ganz -> 409 wie bisher
    (code,) = new_codes(client, admin_headers, duration_days=5, features=["video"])
    refused = redeem(client, mia, code["code"])
    assert refused.status_code == 409
    assert refused.json()["detail"] == "Du hast schon unbegrenzt Premium – der Code bleibt unverbraucht."

    _, ben = user_headers(client, make_user, "ben")
    give_code(client, admin_headers, ben, unlimited=True, duration_days=None)
    (code,) = new_codes(client, admin_headers, duration_days=5, features=["lyrics"])
    assert redeem(client, ben, code["code"]).status_code == 409, "unbegrenzt voll + Teil-Code -> 409 wie heute"


def test_close_gaps_moves_licenses_only_behind_covering_ones(client: TestClient, make_user: Callable) -> None:
    user = make_user("lena")
    now = utcnow()
    with client.app.state.session_factory() as db:

        def add(start: float, end: float, scope: str | None) -> PremiumLicense:
            lic = PremiumLicense(
                user_id=user["id"], source="code", starts_at=now + timedelta(days=start),
                expires_at=now + timedelta(days=end), features=scope,
            )
            db.add(lic)
            return lic

        video = add(-1, 25, "video")  # läuft, nur Videos
        play = add(-1, 10, None)  # Abo, wird gleich erstattet
        video_next = add(10, 20, "video")  # hinter das Abo gehängt
        full_next = add(10, 15, None)  # voller Code, hinter das Abo gehängt
        lyrics = add(25, 35, "lyrics")  # Songtexte, wartet am Ende der Kette
        db.commit()
        play.expires_at = now  # Erstattung
        close_gaps(db, user["id"], now)
        db.commit()
        day = timedelta(days=1)
        # die Video-Lizenz davor enthält „video“ und läuft bis +25: Die angehängte bleibt, wo sie ist
        assert (video_next.starts_at, video_next.expires_at) == (now + 10 * day, now + 20 * day)
        # den vollen Code enthält keine Lizenz davor (die Video-Lizenz nicht): Er rückt auf jetzt vor (5 Tage bleiben)
        assert (full_next.starts_at, full_next.expires_at) == (now, now + 5 * day)
        # Songtexte enthält nur der volle Code: Die Lizenz rückt an dessen Ende (vorher hätte sie bis +25 gewartet)
        assert (lyrics.starts_at, lyrics.expires_at) == (now + 5 * day, now + 15 * day)
        assert (video.starts_at, video.expires_at) == (now - day, now + 25 * day)


def test_admin_grant_always_unlocks_everything(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable
) -> None:
    configure(client, admin_headers, **ALL_SWITCHES)
    user, headers = user_headers(client, make_user, "lena")
    client.post(f"/api/admin/users/{user['id']}/premium", headers=admin_headers, json={"duration_days": 30})
    status = premium(client, headers)
    assert status["features"] == list(FEATURES) and status["locked"] == [] and status["offline_allowed"] is True


# ------------------------------------------------------------------------- Google Play: Laufzeiten und Wechsel


@pytest.fixture
def shop(client: TestClient, admin_headers: dict[str, str]) -> FakePlayVerifier:
    verifier = FakePlayVerifier()
    client.app.state.purchase_verifier = verifier
    configure(
        client, admin_headers, billing_enabled=True, billing_product_ids=PRODUCT, offline_requires_premium=True,
        billing_base_plans="monatlich,halbjaehrlich,jaehrlich", billing_recommended_plan="jaehrlich",
    )
    return verifier


def verify(client: TestClient, headers: dict[str, str], token: str):  # type: ignore[no-untyped-def]
    body = {"product_id": PRODUCT, "purchase_token": token}
    return client.post("/api/premium/play/verify", headers=headers, json=body)


def purchases(client: TestClient) -> list[PlayPurchase]:
    with client.app.state.session_factory() as db:
        return list(db.scalars(select(PlayPurchase).order_by(PlayPurchase.id)).unique())


def test_parse_subscription_reads_base_plan_and_offer_of_the_latest_item() -> None:
    data = {
        "subscriptionState": "SUBSCRIPTION_STATE_ACTIVE",
        "lineItems": [
            {"productId": PRODUCT, "expiryTime": "2026-12-01T00:00:00Z",
             "offerDetails": {"basePlanId": "monatlich", "offerId": "gratis-monat"}},
            {"productId": PRODUCT, "expiryTime": "2027-11-01T00:00:00Z",
             "offerDetails": {"basePlanId": "jaehrlich", "offerTags": ["x"]}},
        ],
    }  # fmt: skip
    info = parse_subscription(data)
    assert (info.base_plan_id, info.offer_id) == ("jaehrlich", "")
    assert (parse_subscription({"lineItems": [{"productId": PRODUCT}]}).base_plan_id, "") == ("", "")
    no_expiry = parse_subscription(
        {"lineItems": [{"productId": PRODUCT, "offerDetails": {"basePlanId": "x" * 100, "offerId": 5}}]}
    )
    assert no_expiry.base_plan_id == "x" * 64 and no_expiry.offer_id == ""
    assert parse_subscription({"lineItems": [{"offerDetails": "kaputt"}]}).base_plan_id == ""


def test_plan_change_moves_the_license_and_is_booked_on_the_server(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable, shop: FakePlayVerifier
) -> None:
    user, headers = user_headers(client, make_user, "lena")
    shop.subscriptions[TOKEN_A] = sub(days=30, product=PRODUCT, account=str(user["id"]), base_plan="monatlich")
    assert verify(client, headers, TOKEN_A).json()["premium"]["play"]["base_plan_id"] == "monatlich"
    # Wechsel zu jährlich: neuer Token, Google nennt den alten als Vorgänger
    new = sub(days=365, product=PRODUCT, account=str(user["id"]), linked=TOKEN_A, base_plan="jaehrlich",
              offer="einfuehrung")  # fmt: skip
    shop.subscriptions[TOKEN_B] = new
    body = verify(client, headers, TOKEN_B).json()
    assert body["result"] == "active"
    status = body["premium"]
    assert parse(status["until"]) == new.expires_at and status["features"] == list(FEATURES)
    assert status["play"]["base_plan_id"] == "jaehrlich" and status["play"]["offer_id"] == "einfuehrung"
    old, fresh = purchases(client)
    assert old.state == "replaced" and old.license_id is None
    assert fresh.license_id is not None and fresh.base_plan_id == "jaehrlich"
    assert len(_licenses(client, "lena")) == 1, "kein doppeltes Premium"

    listing = client.get("/api/admin/premium/purchases", headers=admin_headers).json()
    assert [(p["base_plan_id"], p["offer_id"], p["state"]) for p in listing] == [
        ("jaehrlich", "einfuehrung", "active"),
        ("monatlich", "", "replaced"),
    ]
    # der alte Kauf endet bei Google – das berührt den neuen nicht
    shop.subscriptions[TOKEN_A] = sub(state="expired", days=-1, product=PRODUCT, base_plan="monatlich")
    assert client.post(f"/api/admin/premium/purchases/{old.id}/recheck", headers=admin_headers).status_code == 200
    after = premium(client, headers)
    assert after["active"] is True and parse(after["until"]) == new.expires_at
    assert after["play"]["base_plan_id"] == "jaehrlich"
    # eine Antwort ohne Laufzeit löscht die bekannte nicht
    shop.subscriptions[TOKEN_B] = sub(days=365, product=PRODUCT, account=str(user["id"]), linked=TOKEN_A)
    client.post(f"/api/admin/premium/purchases/{fresh.id}/recheck", headers=admin_headers)
    assert purchases(client)[1].base_plan_id == "jaehrlich"


def test_plan_change_when_the_old_purchase_ended_first(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable, shop: FakePlayVerifier
) -> None:
    user, headers = user_headers(client, make_user, "lena")
    shop.subscriptions[TOKEN_A] = sub(days=30, product=PRODUCT, account=str(user["id"]), base_plan="monatlich")
    verify(client, headers, TOKEN_A)
    (old,) = purchases(client)
    # Google meldet den alten Kauf zuerst als beendet (Wechsel), der neue ist noch nicht beim Server
    shop.subscriptions[TOKEN_A] = sub(state="expired", days=-0.001, product=PRODUCT, base_plan="monatlich")
    client.post(f"/api/admin/premium/purchases/{old.id}/recheck", headers=admin_headers)
    assert premium(client, headers)["active"] is False
    new = sub(days=365, product=PRODUCT, account=str(user["id"]), linked=TOKEN_A, base_plan="jaehrlich")
    shop.subscriptions[TOKEN_B] = new
    assert verify(client, headers, TOKEN_B).json()["result"] == "active"
    status = premium(client, headers)
    assert status["active"] is True and parse(status["until"]) == new.expires_at
    assert status["offline_allowed"] is True and status["play"]["base_plan_id"] == "jaehrlich"
    assert len(_licenses(client, "lena")) == 1


def test_disrupted_check_with_a_partial_code_is_still_unknown(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable, shop: FakePlayVerifier
) -> None:
    """Abo + unbegrenzter Teil-Code ohne Offline-Hören: Bei einer Störung ist der Stand weiter „unbekannt“ (503) –
    nicht „klar ohne Offline“, sonst löschte die App die Musik eines Abonnenten."""
    user, headers = user_headers(client, make_user, "lena")
    shop.subscriptions[TOKEN_A] = sub(days=30, product=PRODUCT, account=str(user["id"]))
    verify(client, headers, TOKEN_A)
    give_code(client, admin_headers, headers, unlimited=True, duration_days=None, features=["video"])
    with client.app.state.session_factory() as db:
        for row in db.scalars(select(PlayPurchase)).unique():
            row.last_checked_at = utcnow() - timedelta(hours=13)
        db.commit()
    shop.fail = VerifierUnavailable("Google ist nicht erreichbar.")
    assert client.get("/api/premium", headers=headers).status_code == 503
    # mit vollem Premium daneben ist der Stand klar
    client.post(f"/api/admin/users/{user['id']}/premium", headers=admin_headers, json={"unlimited": True})
    assert premium(client, headers)["offline_allowed"] is True


# ------------------------------------------------------------------------- Dashboard


def test_dashboard_script_has_the_new_parts_without_inline_styles(client: TestClient) -> None:
    script = client.get("/web/dashboard.js").text
    for text in ("Premium-Leistungen", "Schaltet frei", "Laufzeiten", "Teilumfang", "Alle Leistungen",
                 "Bitte mindestens eine Leistung wählen.", "Keine Empfehlung", "billing_recommended_plan"):  # fmt: skip
        assert text in script, text
    # strenge CSP: keine style-Attribute, kein innerHTML
    assert ".innerHTML" not in script and "style:" not in script
    for key, label in features.LABELS.items():
        assert f"{key}: \"{label}\"" in script or f"{key}: '{label}'" in script, key


# --- Funde der Gegenprüfung ---


def test_subscriber_keeps_everything_while_the_renewal_is_not_checked_yet(lib: Library) -> None:
    """Abo-Zeitraum gerade um, Google hat (vermutlich) verlängert, die App hat /premium aber noch nicht neu gefragt:
    Videos, Songtexte und Qualität bleiben frei (wie bei der 426-Regel aus Teil 1)."""
    from app.services import play_billing

    verifier = FakePlayVerifier()
    lib.client.app.state.purchase_verifier = verifier  # type: ignore[attr-defined]
    configure(
        lib.client,
        lib.headers,
        billing_enabled=True,
        billing_product_ids=PRODUCT,
        video_requires_premium=True,
        lyrics_requires_premium=True,
    )
    user, headers = lib_user(lib, "abo")
    verifier.subscriptions[TOKEN_A] = sub(days=30, product=PRODUCT, account=str(user["id"]))
    assert verify(lib.client, headers, TOKEN_A).status_code == 200
    video = lib.get("/api/tracks", media_type="video")["items"][0]
    track = add_lyrics(lib)
    with lib.client.app.state.session_factory() as db:  # type: ignore[attr-defined]
        now = utcnow()
        purchase = db.scalar(select(PlayPurchase))
        assert purchase is not None
        license_ = db.get(PremiumLicense, purchase.license_id)
        assert license_ is not None
        purchase.expires_at = license_.expires_at = now - timedelta(minutes=5)
        purchase.last_checked_at = now - timedelta(days=1)
        db.commit()
        assert play_billing.premium_unsettled(db, user["id"], now)
    assert stream(lib, video["id"], headers).status_code == 200
    assert lib.client.get(f"/api/tracks/{track['id']}/lyrics", headers=headers).status_code == 200


def test_close_gaps_is_not_stopped_by_an_unlimited_partial_license(client: TestClient, make_user: Callable) -> None:
    user = make_user("lena")
    now = utcnow()
    with client.app.state.session_factory() as db:  # type: ignore[attr-defined]
        badge = PremiumLicense(
            user_id=user["id"], source="code", starts_at=now - timedelta(days=5), expires_at=None, features="badge"
        )
        play = PremiumLicense(
            user_id=user["id"], source="play", starts_at=now - timedelta(days=1), expires_at=now + timedelta(days=29)
        )
        full = PremiumLicense(
            user_id=user["id"], source="code", starts_at=now + timedelta(days=29), expires_at=now + timedelta(days=59)
        )
        db.add_all([badge, play, full])
        db.commit()
        play.expires_at = now  # erstattet
        close_gaps(db, user["id"], now)
        db.commit()
        assert full.starts_at == now
        assert full.expires_at == now + timedelta(days=30)
        # eine volle unbegrenzte Lizenz deckt dagegen alles ab: dann bleibt alles, wie es ist
        db.add(PremiumLicense(user_id=user["id"], source="admin", starts_at=now - timedelta(days=1), expires_at=None))
        later = PremiumLicense(
            user_id=user["id"], source="code", starts_at=now + timedelta(days=40), expires_at=now + timedelta(days=50)
        )
        db.add(later)
        db.commit()
        close_gaps(db, user["id"], now)
        assert later.starts_at == now + timedelta(days=40)


def test_quota_names_the_day_a_wish_is_free_again_when_more_were_counted(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable
) -> None:
    _, headers = user_headers(client, make_user, "max")
    for n in range(5):
        assert wish(client, headers, n).status_code == 201
    configure(client, admin_headers, requests_requires_premium=True, free_requests_per_week=3)
    with client.app.state.session_factory() as db:  # type: ignore[attr-defined]
        times = sorted(db.scalars(select(SongRequest.created_at)))
    result = quota(client, headers)
    assert result["used"] == 5 and result["left"] == 0
    # 5 gezählt, Grenze 3: frei wird erst etwas, wenn der dritte älteste herausfällt
    assert parse(result["resets_at"]) == times[2] + timedelta(days=7)
