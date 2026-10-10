from alembic.autogenerate import compare_metadata
from alembic.migration import MigrationContext
from fastapi.testclient import TestClient
from sqlalchemy import create_engine

from app.config import Settings
from app.models import Base


def test_health_and_server_info(client: TestClient) -> None:
    assert client.get("/api/health").json() == {"status": "ok"}
    info = client.get("/api/server").json()
    assert info["name"] == "Selfify"
    assert info["api_version"] == 1


def test_migrations_match_models(client: TestClient, settings: Settings) -> None:
    """Schützt davor, Modelle zu ändern und die Migration zu vergessen."""
    engine = create_engine(settings.database_url)
    with engine.connect() as connection:
        diff = compare_metadata(MigrationContext.configure(connection), Base.metadata)
    engine.dispose()
    assert diff == []


def test_secret_key_is_persisted(client: TestClient, settings: Settings) -> None:
    key_file = settings.data_dir / "secret.key"
    assert key_file.exists()
    assert len(key_file.read_text()) > 40


def test_docs_can_be_disabled(settings: Settings) -> None:
    from app.main import create_app

    settings.enable_api_docs = False
    with TestClient(create_app(settings)) as client:
        assert client.get("/api/docs").status_code == 404
