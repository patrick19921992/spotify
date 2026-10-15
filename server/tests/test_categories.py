from collections.abc import Callable
from pathlib import Path

from fastapi.testclient import TestClient

from app.config import Settings

from .conftest import bearer, login


def test_default_categories_and_folders(client: TestClient, admin_headers: dict[str, str], settings: Settings) -> None:
    categories = client.get("/api/categories", headers=admin_headers).json()
    assert [c["name"] for c in categories] == ["Musik", "Musikvideos", "Hörspiele & Hörbücher", "Videos"]
    for category in categories:
        assert (settings.media_dir / category["folder"]).is_dir()
    defaults = {c["media_type"]: c["name"] for c in categories if c["is_default"]}
    assert defaults == {"audio": "Musik", "video": "Musikvideos"}


def test_create_category_creates_folder(client: TestClient, admin_headers: dict[str, str], settings: Settings) -> None:
    response = client.post(
        "/api/categories", headers=admin_headers, json={"name": "Kinderlieder", "media_type": "audio"}
    )
    assert response.status_code == 201, response.text
    category = response.json()
    assert category["folder"] == "Kinderlieder"
    assert category["slug"] == "kinderlieder"
    assert (settings.media_dir / "Kinderlieder").is_dir()


def test_folder_name_from_umlauts(client: TestClient, admin_headers: dict[str, str], settings: Settings) -> None:
    category = client.post(
        "/api/categories", headers=admin_headers, json={"name": "Märchen & Lieder", "media_type": "audio"}
    ).json()
    assert category["folder"] == "Maerchen und Lieder"
    assert category["slug"] == "maerchen-lieder"
    assert (settings.media_dir / "Maerchen und Lieder").is_dir()


def test_rejects_unsafe_folders(client: TestClient, admin_headers: dict[str, str], settings: Settings) -> None:
    for folder in ("../ausbruch", "/etc", "a/../../b", ".versteckt", "a:b"):
        body = {"name": f"Test {folder}", "media_type": "audio", "folder": folder}
        response = client.post("/api/categories", headers=admin_headers, json=body)
        assert response.status_code == 400, folder
    assert not (settings.media_dir.parent / "ausbruch").exists()


def test_nested_folder_allowed(client: TestClient, admin_headers: dict[str, str], settings: Settings) -> None:
    response = client.post(
        "/api/categories",
        headers=admin_headers,
        json={"name": "Konzerte", "media_type": "video", "folder": "Videos/Konzerte"},
    )
    assert response.status_code == 201
    assert (settings.media_dir / "Videos" / "Konzerte").is_dir()


def test_duplicate_name_or_folder(client: TestClient, admin_headers: dict[str, str]) -> None:
    same_name = client.post("/api/categories", headers=admin_headers, json={"name": "musik", "media_type": "audio"})
    assert same_name.status_code == 409
    same_folder = client.post(
        "/api/categories", headers=admin_headers, json={"name": "Neu", "media_type": "audio", "folder": "Musik"}
    )
    assert same_folder.status_code == 409


def test_switch_default_category(client: TestClient, admin_headers: dict[str, str]) -> None:
    categories = client.get("/api/categories", headers=admin_headers).json()
    hoerspiele = next(c for c in categories if c["folder"] == "Hoerspiele")
    response = client.patch(f"/api/categories/{hoerspiele['id']}", headers=admin_headers, json={"is_default": True})
    assert response.status_code == 200
    categories = client.get("/api/categories", headers=admin_headers).json()
    audio_defaults = [c["folder"] for c in categories if c["media_type"] == "audio" and c["is_default"]]
    assert audio_defaults == ["Hoerspiele"]


def test_rename_category_keeps_folder(client: TestClient, admin_headers: dict[str, str]) -> None:
    categories = client.get("/api/categories", headers=admin_headers).json()
    musik = next(c for c in categories if c["name"] == "Musik")
    renamed = client.patch(f"/api/categories/{musik['id']}", headers=admin_headers, json={"name": "Meine Musik"}).json()
    assert renamed["name"] == "Meine Musik"
    assert renamed["slug"] == "meine-musik"
    assert renamed["folder"] == "Musik"


def test_delete_category_keeps_files(client: TestClient, admin_headers: dict[str, str], settings: Settings) -> None:
    categories = client.get("/api/categories", headers=admin_headers).json()
    musik = next(c for c in categories if c["name"] == "Musik")
    song = settings.media_dir / "Musik" / "song.opus"
    song.write_bytes(b"x")
    assert client.delete(f"/api/categories/{musik['id']}", headers=admin_headers).status_code == 204
    assert song.exists()
    remaining = client.get("/api/categories", headers=admin_headers).json()
    # Eine andere Audio-Rubrik übernimmt automatisch als Standard
    assert [c["folder"] for c in remaining if c["media_type"] == "audio" and c["is_default"]] == ["Hoerspiele"]


def test_children_can_read_but_not_change(client: TestClient, make_user: Callable[..., dict]) -> None:
    make_user("lena", "kinder-passwort")
    child = bearer(login(client, "lena", "kinder-passwort"))
    assert client.get("/api/categories", headers=child).status_code == 200
    response = client.post("/api/categories", headers=child, json={"name": "Hack", "media_type": "audio"})
    assert response.status_code == 403


def test_bootstrap_is_idempotent(settings: Settings) -> None:
    """Ein Neustart legt nichts doppelt an."""
    from app.main import create_app

    for _ in range(2):
        with TestClient(create_app(settings)) as client:
            headers = bearer(login(client, "admin", "admin-passwort-123"))
            assert len(client.get("/api/categories", headers=headers).json()) == 4
            assert len(client.get("/api/users", headers=headers).json()) == 1
    assert Path(settings.media_dir / "Musik").is_dir()
