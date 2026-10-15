from collections.abc import Callable

from fastapi.testclient import TestClient

from .conftest import bearer, login


def test_admin_creates_child_account(client: TestClient, make_user: Callable[..., dict]) -> None:
    user = make_user("Lena", "kinder-passwort", display_name="Lena", can_download=False)
    assert user["username"] == "lena"
    assert user["is_admin"] is False
    assert user["can_download"] is False
    tokens = login(client, "lena", "kinder-passwort")
    assert tokens["user"]["display_name"] == "Lena"


def test_duplicate_and_invalid_usernames(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable[..., dict]
) -> None:
    make_user("tim")
    duplicate = client.post("/api/users", headers=admin_headers, json={"username": "TIM", "password": "passwort-123"})
    assert duplicate.status_code == 409
    for bad in ("ab", "mit leerzeichen", "ümlaut", "-start"):
        response = client.post("/api/users", headers=admin_headers, json={"username": bad, "password": "passwort-123"})
        assert response.status_code == 422, bad
    short_pw = client.post("/api/users", headers=admin_headers, json={"username": "kurz", "password": "1234"})
    assert short_pw.status_code == 422


def test_non_admin_cannot_manage_users(client: TestClient, make_user: Callable[..., dict]) -> None:
    make_user("lena", "kinder-passwort")
    child = bearer(login(client, "lena", "kinder-passwort"))
    assert client.get("/api/users", headers=child).status_code == 403
    body = {"username": "neu", "password": "passwort-123"}
    assert client.post("/api/users", headers=child, json=body).status_code == 403


def test_deactivate_user_logs_them_out(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable[..., dict]
) -> None:
    user = make_user("lena", "kinder-passwort")
    child = login(client, "lena", "kinder-passwort")
    response = client.patch(f"/api/users/{user['id']}", headers=admin_headers, json={"is_active": False})
    assert response.status_code == 200
    assert client.get("/api/me", headers=bearer(child)).status_code == 401
    blocked = client.post("/api/auth/login", json={"username": "lena", "password": "kinder-passwort"})
    assert blocked.status_code == 403


def test_admin_resets_password(
    client: TestClient, admin_headers: dict[str, str], make_user: Callable[..., dict]
) -> None:
    user = make_user("lena", "kinder-passwort")
    child = login(client, "lena", "kinder-passwort")
    response = client.patch(f"/api/users/{user['id']}", headers=admin_headers, json={"password": "neues-kinder-pw"})
    assert response.status_code == 200
    assert client.get("/api/me", headers=bearer(child)).status_code == 401
    login(client, "lena", "neues-kinder-pw")


def test_last_admin_is_protected(client: TestClient, admin_headers: dict[str, str]) -> None:
    me = client.get("/api/me", headers=admin_headers).json()
    assert client.patch(f"/api/users/{me['id']}", headers=admin_headers, json={"is_admin": False}).status_code == 409
    assert client.patch(f"/api/users/{me['id']}", headers=admin_headers, json={"is_active": False}).status_code == 409
    assert client.delete(f"/api/users/{me['id']}", headers=admin_headers).status_code == 409


def test_delete_user(client: TestClient, admin_headers: dict[str, str], make_user: Callable[..., dict]) -> None:
    user = make_user("tim")
    assert client.delete(f"/api/users/{user['id']}", headers=admin_headers).status_code == 204
    assert client.get(f"/api/users/{user['id']}", headers=admin_headers).status_code == 404
