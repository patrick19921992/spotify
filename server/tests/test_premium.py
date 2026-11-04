"""Premium: Codes erzeugen/einlösen, Laufzeiten, Stapeln, Entzug und Schutz gegen Raten."""

from collections.abc import Callable
from datetime import UTC, datetime, timedelta

from fastapi.testclient import TestClient
from sqlalchemy import select

from app.models import PremiumLicense, utcnow

from .conftest import bearer, login


def parse(value: str | None) -> datetime | None:
    return datetime.fromisoformat(value) if value else None


def new_codes(client: TestClient, admin_headers: dict[str, str], **body: object) -> list[dict]:
    payload = {"duration_days": 30, **body}
    response = client.post("/api/admin/premium/codes", headers=admin_headers, json=payload)
    assert response.status_code == 201, response.text
    return response.json()


def user_headers(client: TestClient, make_user: Callable[..., dict], name: str) -> tuple[dict, dict[str, str]]:
    user = make_user(name)
    return user, bearer(login(client, name, "kinder-passwort"))


def redeem(client: TestClient, headers: dict[str, str], code: str):  # type: ignore[no-untyped-def]
    return client.post("/api/premium/redeem", headers=headers, json={"code": code})


def status_of(client: TestClient, headers: dict[str, str]) -> dict:
    response = client.get("/api/premium", headers=headers)
    assert response.status_code == 200
    return response.json()


def test_code_format_and_listing(client: TestClient, admin_headers: dict[str, str]) -> None:
    (code,) = new_codes(client, admin_headers, label="Geburtstag")
    parts = code["code"].split("-")
    assert [len(p) for p in parts] == [4, 4, 4]
    assert code["label"] == "Geburtstag" and code["duration_days"] == 30 and code["unlimited"] is False
    assert code["state"] == "available" and code["redeemed_count"] == 0 and code["redemptions"] == []
    listing = client.get("/api/admin/premium/codes", headers=admin_headers).json()
    assert [c["id"] for c in listing] == [code["id"]]


def test_many_codes_are_unique(client: TestClient, admin_headers: dict[str, str]) -> None:
    codes = new_codes(client, admin_headers, count=50)
    assert len({c["code"] for c in codes}) == 50


def test_only_admins_manage_premium(client: TestClient, admin_headers: dict[str, str], make_user: Callable) -> None:
    user, headers = user_headers(client, make_user, "lena")
    assert client.get("/api/admin/premium/codes", headers=headers).status_code == 403
    assert client.post("/api/admin/premium/codes", headers=headers, json={"duration_days": 5}).status_code == 403
    grant = client.post(f"/api/admin/users/{user['id']}/premium", headers=headers, json={"unlimited": True})
    assert grant.status_code == 403
    assert client.delete(f"/api/admin/users/{user['id']}/premium", headers=headers).status_code == 403
    assert client.get("/api/admin/premium/licenses", headers=headers).status_code == 403
    assert client.get("/api/premium").status_code == 401


def test_duration_or_unlimited_but_never_both_or_neither(client: TestClient, admin_headers: dict[str, str]) -> None:
    both = client.post(
        "/api/admin/premium/codes", headers=admin_headers, json={"duration_days": 5, "unlimited": True}
    )
    assert both.status_code == 422
    neither = client.post("/api/admin/premium/codes", headers=admin_headers, json={})
    assert neither.status_code == 422
    assert client.post("/api/admin/premium/codes", headers=admin_headers, json={"duration_days": 0}).status_code == 422
    too_long = client.post("/api/admin/premium/codes", headers=admin_headers, json={"duration_days": 99999})
    assert too_long.status_code == 422
    unlimited = new_codes(client, admin_headers, duration_days=None, unlimited=True)[0]
    assert unlimited["unlimited"] is True and unlimited["duration_days"] is None


def test_redeem_starts_the_timer_at_redemption(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable
) -> None:
    (code,) = new_codes(client, admin_headers, duration_days=30)
    _, headers = user_headers(client, make_user, "lena")
    assert status_of(client, headers) == {"active": False, "unlimited": False, "until": None}
    response = redeem(client, headers, code["code"])
    assert response.status_code == 200, response.text
    state = response.json()
    assert state["active"] is True and state["unlimited"] is False
    assert abs((parse(state["until"]) - utcnow() - timedelta(days=30)).total_seconds()) < 60
    assert status_of(client, headers)["active"] is True


def test_code_input_is_forgiving(client: TestClient, admin_headers: dict[str, str], make_user: Callable) -> None:
    (code,) = new_codes(client, admin_headers)
    _, headers = user_headers(client, make_user, "lena")
    sloppy = " " + code["code"].lower().replace("-", " ") + " "
    assert redeem(client, headers, sloppy).status_code == 200


def test_single_use_code_works_only_once(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable
) -> None:
    (code,) = new_codes(client, admin_headers)
    _, first = user_headers(client, make_user, "lena")
    _, second = user_headers(client, make_user, "ben")
    assert redeem(client, first, code["code"]).status_code == 200
    again = redeem(client, second, code["code"])
    assert again.status_code == 409 and "so oft" in again.json()["detail"]
    assert status_of(client, second)["active"] is False
    detail = client.get("/api/admin/premium/codes", headers=admin_headers).json()[0]
    assert detail["state"] == "used_up" and detail["redeemed_count"] == 1
    assert [r["username"] for r in detail["redemptions"]] == ["lena"]


def test_one_user_cannot_redeem_a_multi_use_code_twice(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable
) -> None:
    (code,) = new_codes(client, admin_headers, max_redemptions=3)
    _, headers = user_headers(client, make_user, "lena")
    assert redeem(client, headers, code["code"]).status_code == 200
    again = redeem(client, headers, code["code"])
    assert again.status_code == 409 and "schon eingelöst" in again.json()["detail"]
    detail = client.get("/api/admin/premium/codes", headers=admin_headers).json()[0]
    assert detail["redeemed_count"] == 1 and detail["state"] == "available"


def test_multi_use_code_stops_at_its_limit(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable
) -> None:
    (code,) = new_codes(client, admin_headers, duration_days=None, unlimited=True, max_redemptions=2)
    users = [user_headers(client, make_user, name)[1] for name in ("lena", "ben", "mia")]
    assert redeem(client, users[0], code["code"]).json()["unlimited"] is True
    assert redeem(client, users[1], code["code"]).status_code == 200
    assert redeem(client, users[2], code["code"]).status_code == 409


def test_time_limited_premium_stacks(client: TestClient, admin_headers: dict[str, str], make_user: Callable) -> None:
    first, second = new_codes(client, admin_headers, count=2, duration_days=30)
    _, headers = user_headers(client, make_user, "lena")
    one = redeem(client, headers, first["code"]).json()
    two = redeem(client, headers, second["code"]).json()
    assert abs((parse(two["until"]) - parse(one["until"]) - timedelta(days=30)).total_seconds()) < 5


def test_unlimited_premium_beats_a_time_limited_code_which_stays_unused(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable
) -> None:
    unlimited, limited = (
        new_codes(client, admin_headers, duration_days=None, unlimited=True)[0],
        new_codes(client, admin_headers, duration_days=10)[0],
    )
    _, headers = user_headers(client, make_user, "lena")
    assert redeem(client, headers, unlimited["code"]).json()["unlimited"] is True
    response = redeem(client, headers, limited["code"])
    assert response.status_code == 409 and "unbegrenzt" in response.json()["detail"]
    codes = {c["id"]: c for c in client.get("/api/admin/premium/codes", headers=admin_headers).json()}
    assert codes[limited["id"]]["redeemed_count"] == 0, "der Code darf nicht verbraucht werden"


def test_unlimited_code_after_time_limited_premium_makes_it_unlimited(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable
) -> None:
    limited = new_codes(client, admin_headers, duration_days=10)[0]
    unlimited = new_codes(client, admin_headers, duration_days=None, unlimited=True)[0]
    _, headers = user_headers(client, make_user, "lena")
    assert redeem(client, headers, limited["code"]).json()["unlimited"] is False
    state = redeem(client, headers, unlimited["code"]).json()
    assert state["unlimited"] is True and state["until"] is None


def test_unknown_expired_and_revoked_codes_are_rejected(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable
) -> None:
    _, headers = user_headers(client, make_user, "lena")
    assert redeem(client, headers, "AAAA-BBBB-CCCC").status_code == 404
    assert redeem(client, headers, "---").status_code == 422  # zu kurz
    assert redeem(client, headers, "!!!!!!!!").status_code == 404  # nur Sonderzeichen

    (expired,) = new_codes(
        client, admin_headers, valid_until=(utcnow() + timedelta(days=1)).astimezone(UTC).isoformat()
    )
    with client.app.state.session_factory() as db:
        from app.models import PremiumCode

        row = db.scalar(select(PremiumCode).where(PremiumCode.id == expired["id"]))
        row.valid_until = utcnow() - timedelta(seconds=1)
        db.commit()
    gone = redeem(client, headers, expired["code"])
    assert gone.status_code == 410 and "abgelaufen" in gone.json()["detail"]

    (revoked,) = new_codes(client, admin_headers)
    assert client.post(
        f"/api/admin/premium/codes/{revoked['id']}/revoke", headers=admin_headers, json={}
    ).status_code == 200
    assert redeem(client, headers, revoked["code"]).status_code == 410


def test_valid_until_must_be_in_the_future(client: TestClient, admin_headers: dict[str, str]) -> None:
    past = (utcnow() - timedelta(days=1)).isoformat()
    response = client.post(
        "/api/admin/premium/codes", headers=admin_headers, json={"duration_days": 5, "valid_until": past}
    )
    assert response.status_code == 400


def test_revoking_a_code_keeps_or_removes_existing_premium(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable
) -> None:
    kept, removed = new_codes(client, admin_headers, count=2, duration_days=30)
    _, lena = user_headers(client, make_user, "lena")
    _, ben = user_headers(client, make_user, "ben")
    redeem(client, lena, kept["code"])
    redeem(client, ben, removed["code"])
    r1 = client.post(f"/api/admin/premium/codes/{kept['id']}/revoke", headers=admin_headers, json={})
    assert r1.json() == {"revoked": 0}
    assert status_of(client, lena)["active"] is True, "ohne revoke_licenses bleibt das Premium"
    r2 = client.post(
        f"/api/admin/premium/codes/{removed['id']}/revoke", headers=admin_headers, json={"revoke_licenses": True}
    )
    assert r2.json() == {"revoked": 1}
    assert status_of(client, ben)["active"] is False


def test_admin_can_grant_and_revoke_premium_directly(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable
) -> None:
    user, headers = user_headers(client, make_user, "lena")
    granted = client.post(
        f"/api/admin/users/{user['id']}/premium", headers=admin_headers, json={"duration_days": 7, "note": "Tester"}
    )
    assert granted.status_code == 201, granted.text
    body = granted.json()
    assert body["active"] is True and body["unlimited"] is False and body["licenses"][0]["source"] == "admin"
    assert body["licenses"][0]["note"] == "Tester" and body["licenses"][0]["code"] is None
    assert status_of(client, headers)["active"] is True

    unlimited = client.post(
        f"/api/admin/users/{user['id']}/premium", headers=admin_headers, json={"unlimited": True}
    ).json()
    assert unlimited["unlimited"] is True

    revoked = client.delete(f"/api/admin/users/{user['id']}/premium", headers=admin_headers)
    assert revoked.json() == {"revoked": 2}
    assert status_of(client, headers) == {"active": False, "unlimited": False, "until": None}
    assert client.delete(f"/api/admin/users/{user['id']}/premium", headers=admin_headers).json() == {"revoked": 0}
    missing = client.post("/api/admin/users/9999/premium", headers=admin_headers, json={"unlimited": True})
    assert missing.status_code == 404


def test_single_license_can_be_revoked_and_expired_premium_is_inactive(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable
) -> None:
    user, headers = user_headers(client, make_user, "lena")
    client.post(f"/api/admin/users/{user['id']}/premium", headers=admin_headers, json={"duration_days": 5})
    licenses = client.get("/api/admin/premium/licenses", headers=admin_headers).json()
    assert len(licenses) == 1 and licenses[0]["running"] is True
    assert client.get("/api/admin/premium/licenses?only_running=true", headers=admin_headers).json() != []

    with client.app.state.session_factory() as db:
        lic = db.scalar(select(PremiumLicense))
        lic.expires_at = utcnow() - timedelta(minutes=1)
        db.commit()
    assert status_of(client, headers)["active"] is False
    assert client.get("/api/admin/premium/licenses?only_running=true", headers=admin_headers).json() == []

    client.post(f"/api/admin/users/{user['id']}/premium", headers=admin_headers, json={"duration_days": 5})
    running = client.get("/api/admin/premium/licenses?only_running=true", headers=admin_headers).json()
    assert client.post(f"/api/admin/premium/licenses/{running[0]['id']}/revoke", headers=admin_headers).json() == {
        "revoked": 1
    }
    assert status_of(client, headers)["active"] is False
    assert client.post("/api/admin/premium/licenses/9999/revoke", headers=admin_headers).status_code == 404


def test_only_unused_codes_can_be_deleted(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable
) -> None:
    unused, used = new_codes(client, admin_headers, count=2)
    _, headers = user_headers(client, make_user, "lena")
    redeem(client, headers, used["code"])
    assert client.delete(f"/api/admin/premium/codes/{unused['id']}", headers=admin_headers).status_code == 204
    assert client.delete(f"/api/admin/premium/codes/{used['id']}", headers=admin_headers).status_code == 409
    assert client.delete("/api/admin/premium/codes/9999", headers=admin_headers).status_code == 404


def test_guessing_codes_is_slowed_down(client: TestClient, admin_headers: dict[str, str], make_user: Callable) -> None:
    (real,) = new_codes(client, admin_headers)
    _, headers = user_headers(client, make_user, "lena")
    limit = client.app.state.settings.login_max_failures_per_user
    for i in range(limit):
        assert redeem(client, headers, f"ZZZZ-ZZZZ-{i:04d}").status_code == 404
    blocked = redeem(client, headers, real["code"])
    assert blocked.status_code == 429 and "Retry-After" in blocked.headers


def test_deleting_the_user_removes_the_premium(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable
) -> None:
    (code,) = new_codes(client, admin_headers)
    user, headers = user_headers(client, make_user, "lena")
    redeem(client, headers, code["code"])
    assert client.delete(f"/api/users/{user['id']}", headers=admin_headers).status_code == 204
    detail = client.get("/api/admin/premium/codes", headers=admin_headers).json()[0]
    assert detail["redeemed_count"] == 1 and detail["redemptions"] == [], "das Konto ist weg, der Zähler bleibt"
