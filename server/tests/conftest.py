"""Testaufbau: jeder Test bekommt eine frische App mit eigener Datenbank und eigenem Medienordner."""

from collections.abc import Callable, Iterator
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app

ADMIN_PASSWORD = "admin-passwort-123"


@pytest.fixture
def settings(tmp_path: Path) -> Settings:
    return Settings(
        _env_file=None,
        data_dir=tmp_path / "data",
        media_dir=tmp_path / "media",
        admin_username="admin",
        admin_password=ADMIN_PASSWORD,
        log_level="WARNING",
        # In Tests wird gezielt per scanner.scan() eingelesen – keine Hintergrund-Scans
        scan_on_startup=False,
        library_watch=False,
        scan_interval_minutes=0,
    )


@pytest.fixture
def client(settings: Settings) -> Iterator[TestClient]:
    with TestClient(create_app(settings)) as test_client:
        yield test_client


def login(client: TestClient, username: str, password: str, device: str = "Test") -> dict:
    response = client.post(
        "/api/auth/login", json={"username": username, "password": password, "device_name": device}
    )
    assert response.status_code == 200, response.text
    return response.json()


def bearer(tokens: dict) -> dict[str, str]:
    return {"Authorization": f"Bearer {tokens['access_token']}"}


@pytest.fixture
def admin_headers(client: TestClient) -> dict[str, str]:
    return bearer(login(client, "admin", ADMIN_PASSWORD))


@pytest.fixture
def make_user(client: TestClient, admin_headers: dict[str, str]) -> Callable[..., dict]:
    def _make(username: str = "lena", password: str = "kinder-passwort", **extra: object) -> dict:
        response = client.post(
            "/api/users", headers=admin_headers, json={"username": username, "password": password, **extra}
        )
        assert response.status_code == 201, response.text
        return response.json()

    return _make
