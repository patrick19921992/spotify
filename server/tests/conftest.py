"""Testaufbau: jeder Test bekommt eine frische App mit eigener Datenbank und eigenem Medienordner."""

import shutil
from collections.abc import Callable, Iterator
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app

from .media_factory import FFMPEG, build_library

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


@pytest.fixture(scope="session")
def library_template(tmp_path_factory: pytest.TempPathFactory) -> tuple[Path, dict[str, str]]:
    """Beispiel-Bibliothek (einmal pro Testlauf erzeugt, für jeden Test frisch kopiert)."""
    if FFMPEG is None:
        pytest.skip("ffmpeg wird für die Medien-Tests gebraucht")
    root = tmp_path_factory.mktemp("media-template")
    return root, build_library(root)


class Library:
    def __init__(self, client: TestClient, settings: Settings, paths: dict[str, str], tokens: dict) -> None:
        self.client = client
        self.settings = settings
        self.paths = paths
        self.tokens = tokens
        self.headers = bearer(tokens)

    def get(self, url: str, **params: object) -> dict:
        response = self.client.get(url, headers=self.headers, params=params)
        assert response.status_code == 200, response.text
        return response.json()

    def scan(self) -> dict:
        response = self.client.post("/api/library/scan", headers=self.headers, json={"wait": True})
        assert response.status_code == 202, response.text
        return response.json()

    def track_by_title(self, title: str) -> dict:
        items = self.get("/api/tracks", limit=500)["items"]
        return next(t for t in items if t["title"] == title)


@pytest.fixture
def lib(settings: Settings, library_template: tuple[Path, dict[str, str]]) -> Iterator[Library]:
    template, paths = library_template
    shutil.copytree(template, settings.media_dir, dirs_exist_ok=True)
    with TestClient(create_app(settings)) as client:
        library = Library(client, settings, paths, login(client, "admin", ADMIN_PASSWORD))
        library.scan()
        yield library
