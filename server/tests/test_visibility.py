"""Sichtbarkeit je Rubrik: Ein eingeschränktes Konto sieht nur seine Rubriken – überall, mit Zählern je Betrachter.

Aufbau: die Beispiel-Bibliothek plus ein „Bonus Track“ von Queen im Album „A Night at the Opera“, der in der Rubrik
Hörspiele liegt. Damit sind das Album und der Künstler Queen gemischt (Musik + Hörspiele, bei Queen auch Musikvideos).
Das eingeschränkte Konto „kim“ sieht nur die Rubrik Musik.
"""

import shutil
import sqlite3
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path

import pytest
from alembic import command
from alembic.autogenerate import compare_metadata
from alembic.migration import MigrationContext
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, update
from sqlalchemy import text as sql_text

from app.config import Settings
from app.database import alembic_config
from app.downloads.youtube import YouTubeItem
from app.main import create_app
from app.models import Album, Artist, Base, Cover, Track, User
from app.services.visibility import UNRESTRICTED, Visibility, cover_visible, visibility_for

from .conftest import ADMIN_PASSWORD, Library, bearer, login
from .media_factory import FFMPEG, cover_bytes, make_audio, tag_mp3

pytestmark = pytest.mark.skipif(FFMPEG is None, reason="ffmpeg wird für die Medien-Tests gebraucht")

VISIBLE = {"Bohemian Rhapsody", "Love of My Life", "Get Lucky", "Schrei nach Liebe"}
HIDDEN = {"Kapitel 1", "Bonus Track", "Bohemian Rhapsody (Official Video)"}


@dataclass
class Env:
    lib: Library
    admin: dict[str, str]
    kim: dict[str, str]
    kim_id: int
    categories: dict[str, int]
    tracks: dict[str, dict]

    @property
    def client(self) -> TestClient:
        return self.lib.client

    def get(self, headers: dict[str, str], url: str, **params: object) -> dict:
        response = self.client.get(url, headers=headers, params=params)
        assert response.status_code == 200, (url, response.text)
        return response.json()

    def status(self, headers: dict[str, str], url: str, **params: object) -> tuple[int, str]:
        response = self.client.get(url, headers=headers, params=params)
        return response.status_code, response.json().get("detail", "")

    def track(self, title: str) -> dict:
        return self.tracks[title]

    def make_user(self, username: str, **extra: object) -> tuple[int, dict[str, str]]:
        body = {"username": username, "password": "kinder-passwort", **extra}
        response = self.client.post("/api/users", headers=self.admin, json=body)
        assert response.status_code == 201, response.text
        return response.json()["id"], bearer(login(self.client, username, "kinder-passwort"))

    def patch_user(self, user_id: int, **body: object) -> dict:
        response = self.client.patch(f"/api/users/{user_id}", headers=self.admin, json=body)
        assert response.status_code == 200, response.text
        return response.json()

    def config(self, **values: object) -> None:
        response = self.client.put("/api/admin/config", headers=self.admin, json=values)
        assert response.status_code == 200, response.text


@pytest.fixture
def env(settings: Settings, library_template: tuple[Path, dict[str, str]]) -> Iterator[Env]:
    template, paths = library_template
    shutil.copytree(template, settings.media_dir, dirs_exist_ok=True)
    bonus = make_audio(settings.media_dir / "Hoerspiele" / "Queen Bonus" / "03 - Bonus Track.mp3", "mp3", freq=500)
    tag_mp3(bonus, title="Bonus Track", artist="Queen", album="A Night at the Opera", track="3", year="1975",
            genre="Rock", cover=cover_bytes((10, 200, 10)))
    with TestClient(create_app(settings)) as client:
        lib = Library(client, settings, paths, login(client, "admin", ADMIN_PASSWORD))
        lib.scan()
        categories = {c["name"]: c["id"] for c in lib.get("/api/categories")}
        tracks = {t["title"]: t for t in lib.get("/api/tracks", limit=500)["items"]}
        assert set(tracks) == VISIBLE | HIDDEN
        environment = Env(lib, lib.headers, {}, 0, categories, tracks)
        environment.kim_id, environment.kim = environment.make_user(
            "kim", all_categories=False, category_ids=[categories["Musik"]]
        )
        yield environment


def titles(items: list[dict]) -> set[str]:
    return {item["title"] for item in items}


def all_track_titles(home: dict) -> set[str]:
    return {t["title"] for section in home["sections"] for t in section["tracks"]}


# ------------------------------------------------------------------------- Bibliothek


def test_lists_and_counts_per_viewer(env: Env) -> None:
    tracks = env.get(env.kim, "/api/tracks", limit=500)
    assert titles(tracks["items"]) == VISIBLE and tracks["total"] == 4
    assert env.get(env.kim, "/api/tracks", media_type="video")["total"] == 0
    hidden_category = env.get(env.kim, "/api/tracks", category_id=env.categories["Hörspiele & Hörbücher"])
    assert hidden_category == {"items": [], "total": 0, "limit": 50, "offset": 0}
    # Seiten zählen die gefilterte Abfrage
    page = env.get(env.kim, "/api/tracks", limit=2, offset=2)
    assert page["total"] == 4 and len(page["items"]) == 2

    opera_id = env.track("Bohemian Rhapsody")["album"]["id"]
    albums = env.get(env.kim, "/api/albums", limit=500)
    by_title = {a["title"]: a for a in albums["items"]}
    assert set(by_title) == {"A Night at the Opera", "Random Access Memories", "Die Bestie in Menschengestalt"}
    assert albums["total"] == 3
    opera = by_title["A Night at the Opera"]
    expected_duration = env.track("Bohemian Rhapsody")["duration"] + env.track("Love of My Life")["duration"]
    assert opera["track_count"] == 2 and opera["duration"] == pytest.approx(expected_duration)
    assert env.get(env.admin, f"/api/albums/{opera_id}")["track_count"] == 3  # gespeicherter Zähler bleibt global

    artists = {a["name"]: a for a in env.get(env.kim, "/api/artists", limit=500)["items"]}
    assert "Die drei ???" not in artists
    assert artists["Queen"]["track_count"] == 2 and artists["Queen"]["album_count"] == 1
    admin_queen = next(a for a in env.get(env.admin, "/api/artists", limit=500)["items"] if a["name"] == "Queen")
    assert admin_queen["track_count"] > 2
    assert env.get(env.kim, "/api/artists", limit=500)["total"] == len(artists)
    assert {a["name"] for a in env.get(env.kim, "/api/artists", sort="tracks")["items"]} == set(artists)


def test_detail_pages_and_404_for_hidden_ids(env: Env) -> None:
    opera_id = env.track("Bohemian Rhapsody")["album"]["id"]
    opera = env.get(env.kim, f"/api/albums/{opera_id}")
    assert titles(opera["tracks"]) == {"Bohemian Rhapsody", "Love of My Life"} and opera["track_count"] == 2

    folge = env.track("Kapitel 1")["album"]["id"]
    assert env.status(env.kim, f"/api/albums/{folge}") == (404, "Album nicht gefunden.")
    assert env.status(env.kim, "/api/albums/999999") == (404, "Album nicht gefunden.")

    drei = env.track("Kapitel 1")["artists"][0]["id"]
    assert env.status(env.kim, f"/api/artists/{drei}") == (404, "Künstler nicht gefunden.")
    assert env.status(env.kim, "/api/artists/999999") == (404, "Künstler nicht gefunden.")

    for title in HIDDEN:
        track_id = env.track(title)["id"]
        assert env.status(env.kim, f"/api/tracks/{track_id}") == (404, "Titel nicht gefunden.")
    assert env.status(env.kim, "/api/tracks/999999") == (404, "Titel nicht gefunden.")
    assert env.get(env.kim, f"/api/tracks/{env.track('Get Lucky')['id']}")["title"] == "Get Lucky"

    queen_id = env.track("Bohemian Rhapsody")["artists"][0]["id"]
    queen = env.get(env.kim, f"/api/artists/{queen_id}")
    assert titles(queen["top_tracks"]) == {"Bohemian Rhapsody", "Love of My Life"}
    assert queen["videos"] == []
    assert [a["title"] for a in queen["albums"]] == ["A Night at the Opera"]
    assert queen["albums"][0]["track_count"] == 2
    assert queen["track_count"] == 2 and queen["album_count"] == 1
    admin_queen = env.get(env.admin, f"/api/artists/{queen_id}")
    assert "Bonus Track" in titles(admin_queen["top_tracks"]) and admin_queen["videos"]


def test_category_filter_on_hidden_category_is_empty(env: Env) -> None:
    """Filter auf eine verborgene Rubrik verhält sich wie eine Rubrik, die es nicht gibt – auch bei gemischten
    Alben und Künstlern (Queen hat einen „Bonus Track“ in den Hörspielen)."""
    hidden = env.categories["Hörspiele & Hörbücher"]
    empty_page = {"items": [], "total": 0, "limit": 50, "offset": 0}
    for category_id in (hidden, 999999):
        assert env.get(env.kim, "/api/albums", category_id=category_id) == empty_page
        assert env.get(env.kim, "/api/artists", category_id=category_id) == empty_page
        for query in ("Queen", "Opera", "Bonus"):
            found = env.get(env.kim, "/api/search", q=query, category_id=category_id)
            assert found["tracks"] == found["artists"] == found["albums"] == found["videos"] == []
            assert found["top_result"] is None
    # Die freigegebene Rubrik filtert weiter wie gewohnt
    musik = env.categories["Musik"]
    assert "Queen" in {a["name"] for a in env.get(env.kim, "/api/artists", category_id=musik)["items"]}
    assert "A Night at the Opera" in titles(env.get(env.kim, "/api/albums", category_id=musik)["items"])
    assert env.get(env.kim, "/api/search", q="Queen", category_id=musik)["artists"]
    # Uneingeschränkt: Filter auf die Hörspiele findet das gemischte Album wie bisher
    assert "A Night at the Opera" in titles(env.get(env.admin, "/api/albums", category_id=hidden)["items"])
    assert "Queen" in {a["name"] for a in env.get(env.admin, "/api/artists", category_id=hidden)["items"]}


def test_search_only_finds_visible_items(env: Env) -> None:
    result = env.get(env.kim, "/api/search", q="Queen")
    assert titles(result["tracks"]) <= VISIBLE and "Bohemian Rhapsody" in titles(result["tracks"])
    assert result["videos"] == []
    queen = next(a for a in result["artists"] if a["name"] == "Queen")
    assert queen["track_count"] == 2
    assert env.get(env.admin, "/api/search", q="Bonus")["tracks"]
    hidden = env.get(env.kim, "/api/search", q="Bonus")
    assert hidden["tracks"] == [] and hidden["top_result"] is None
    for query in ("Fragezeichen", "drei", "Kapitel", "Official Video"):
        found = env.get(env.kim, "/api/search", q=query)
        assert found["tracks"] == [] and found["artists"] == [] and found["albums"] == [] and found["videos"] == []
        assert found["top_result"] is None, query
    opera = env.get(env.kim, "/api/search", q="Night at the Opera")
    assert opera["albums"][0]["track_count"] == 2
    assert opera["top_result"]["type"] == "album" and opera["top_result"]["album"]["track_count"] == 2


def test_library_stats_and_scan_status(env: Env) -> None:
    stats = env.get(env.kim, "/api/library")
    assert stats["tracks"] == 4 and stats["videos"] == 0 and stats["albums"] == 3
    names = {a["name"] for a in env.get(env.kim, "/api/artists", limit=500)["items"]}
    assert stats["artists"] == len(names)
    expected = sum(env.track(t)["duration"] for t in VISIBLE)
    assert stats["total_duration"] == pytest.approx(expected)
    assert stats["total_size"] == sum(env.track(t)["file_size"] for t in VISIBLE)
    # Fehlerdateien verraten Ordner – eingeschränkte Konten sehen sie nicht
    assert stats["scan"]["error_files"] == [] and stats["scan"]["last_error"] is None
    scan = env.get(env.kim, "/api/library/scan")
    assert scan["error_files"] == [] and scan["last_error"] is None
    # Zähler des Scans gelten für die ganze Sammlung – eingeschränkt alle 0, Zeitstempel bleiben
    for key in ("files_seen", "added", "updated", "removed", "errors"):
        assert scan[key] == 0 and stats["scan"][key] == 0, key
    admin_scan = env.get(env.admin, "/api/library/scan")
    assert admin_scan["error_files"] == ["Musik/kaputt.mp3"] and admin_scan["errors"] == 1
    assert admin_scan["files_seen"] > 0 and admin_scan["added"] > 0
    assert scan["finished_at"] == admin_scan["finished_at"]
    # Uneingeschränkte Nicht-Admins sehen den Stand wie bisher
    _, lena = env.make_user("lena")
    assert env.get(lena, "/api/library/scan")["error_files"] == ["Musik/kaputt.mp3"]


def test_categories_only_the_released_ones(env: Env) -> None:
    mine = env.get(env.kim, "/api/categories")
    admin = {c["id"]: c for c in env.get(env.admin, "/api/categories")}
    assert [c["id"] for c in mine] == [env.categories["Musik"]]
    assert mine[0] == admin[env.categories["Musik"]]  # die Rubrik ist ganz sichtbar, Zähler wie beim Admin


def test_404_comes_before_the_premium_403(env: Env) -> None:
    env.config(video_requires_premium=True, lyrics_requires_premium=True)
    video = env.track("Bohemian Rhapsody (Official Video)")["id"]
    bonus = env.track("Bonus Track")["id"]
    visible = env.track("Bohemian Rhapsody")["id"]
    assert env.status(env.kim, f"/api/tracks/{video}/stream") == (404, "Titel nicht gefunden.")
    assert env.status(env.kim, f"/api/tracks/{bonus}/stream") == (404, "Titel nicht gefunden.")
    assert env.status(env.kim, f"/api/tracks/{bonus}/lyrics") == (404, "Titel nicht gefunden.")
    assert env.status(env.kim, f"/api/tracks/{visible}/lyrics")[0] == 403
    assert env.client.get(f"/api/tracks/{visible}/stream", headers=env.kim).status_code == 200
    # mit dem Medien-Token im Link (Offline-Downloads, Player) genauso
    media = login(env.client, "kim", "kinder-passwort")["media_token"]
    assert env.client.get(f"/api/tracks/{bonus}/stream", params={"t": media}).status_code == 404
    assert env.client.get(f"/api/tracks/{visible}/stream", params={"t": media}).status_code == 200
    # ein uneingeschränktes Konto ohne Premium bekommt wie bisher das 403
    _, lena = env.make_user("lena")
    assert env.status(lena, f"/api/tracks/{video}/stream")[0] == 403
    assert env.status(lena, f"/api/tracks/{bonus}/lyrics")[0] == 403


def test_cover_rule(env: Env) -> None:
    def cover(headers: dict[str, str], cover_id: str) -> int:
        return env.client.get(f"/api/covers/{cover_id}", headers=headers).status_code

    queen_cover = env.track("Bohemian Rhapsody")["cover_id"]
    bonus_cover = env.track("Bonus Track")["cover_id"]
    video_cover = env.track("Bohemian Rhapsody (Official Video)")["cover_id"]
    assert queen_cover and bonus_cover and video_cover and bonus_cover != queen_cover
    assert cover(env.kim, queen_cover) == 200
    assert cover(env.kim, env.track("Get Lucky")["cover_id"]) == 200
    assert cover(env.kim, bonus_cover) == 404
    assert cover(env.kim, video_cover) == 404
    assert env.client.get(f"/api/covers/{bonus_cover}", headers=env.kim).json()["detail"] == "Cover nicht gefunden."
    assert cover(env.admin, bonus_cover) == 200

    # Cover einer Playlist: nur, wenn der Benutzer die Playlist sehen darf
    playlist = env.client.post("/api/playlists", headers=env.admin, json={"name": "Geheim"}).json()
    upload = env.client.put(
        f"/api/playlists/{playlist['id']}/cover", headers=env.admin,
        files={"file": ("c.png", cover_bytes((1, 2, 250), fmt="PNG"), "image/png")},
    )
    playlist_cover = upload.json()["cover_id"]
    assert cover(env.kim, playlist_cover) == 404
    env.client.patch(f"/api/playlists/{playlist['id']}", headers=env.admin, json={"is_public": True})
    assert cover(env.kim, playlist_cover) == 200


def test_cover_check_for_albums_and_artists_uses_cover_index(env: Env) -> None:
    """Cover nur an Album bzw. Künstler (an keinem Titel): Prüfung über den direkten Join, Abfragen über den Index."""
    opera_id = env.track("Bohemian Rhapsody")["album"]["id"]
    folge_id = env.track("Kapitel 1")["album"]["id"]
    queen_id = env.track("Bohemian Rhapsody")["artists"][0]["id"]
    drei_id = env.track("Kapitel 1")["artists"][0]["id"]
    with env.client.app.state.session_factory() as db:  # type: ignore[attr-defined]
        for n in range(4):
            db.add(Cover(id=f"{n:040d}", width=1, height=1, color="#000000"))
        db.flush()
        db.get(Album, opera_id).cover_id = f"{0:040d}"  # type: ignore[union-attr]
        db.get(Album, folge_id).cover_id = f"{1:040d}"  # type: ignore[union-attr]
        db.get(Artist, queen_id).cover_id = f"{2:040d}"  # type: ignore[union-attr]
        db.get(Artist, drei_id).cover_id = f"{3:040d}"  # type: ignore[union-attr]
        db.commit()
        kim = visibility_for(db, db.get(User, env.kim_id))  # type: ignore[arg-type]
        assert kim.restricted
        expected = {0: True, 1: False, 2: True, 3: False}
        assert {n: cover_visible(db, kim, f"{n:040d}") for n in range(4)} == expected
        assert all(cover_visible(db, UNRESTRICTED, f"{n:040d}") for n in range(4))
        # Indizes auf cover_id gibt es, und die Titel-Prüfung nutzt ihn
        for table in ("tracks", "albums", "artists"):
            indexes = {row[1] for row in db.execute(sql_text(f"PRAGMA index_list({table})"))}
            assert f"ix_{table}_cover_id" in indexes, table
        query = sql_text("EXPLAIN QUERY PLAN SELECT id FROM tracks WHERE cover_id = 'x'")
        plan = " ".join(str(row[-1]) for row in db.execute(query))
        assert "ix_tracks_cover_id" in plan


# ----------------------------------------------------------------------- Persönliches


def test_likes_saves_and_history(env: Env) -> None:
    bonus, visible = env.track("Bonus Track")["id"], env.track("Get Lucky")["id"]
    folge = env.track("Kapitel 1")["album"]["id"]
    drei = env.track("Kapitel 1")["artists"][0]["id"]
    opera = env.track("Bohemian Rhapsody")["album"]["id"]
    queen = env.track("Bohemian Rhapsody")["artists"][0]["id"]
    put, delete = env.client.put, env.client.delete

    # Unsichtbar = nicht vorhanden
    for url, text in (
        (f"/api/me/likes/{bonus}", "Titel nicht gefunden."),
        (f"/api/me/albums/{folge}", "Album nicht gefunden."),
        (f"/api/me/artists/{drei}", "Künstler nicht gefunden."),
    ):
        response = put(url, headers=env.kim)
        assert response.status_code == 404 and response.json()["detail"] == text, url
    assert put("/api/me/likes/999999", headers=env.kim).json()["detail"] == "Titel nicht gefunden."
    history = env.client.post("/api/me/history", headers=env.kim, json={"track_id": bonus, "seconds": 40})
    assert history.status_code == 404 and history.json()["detail"] == "Titel nicht gefunden."
    # Entfernen geht immer – und verrät nichts: verborgen und nicht vorhanden ergeben beide 204
    for url in (f"/api/me/likes/{bonus}", f"/api/me/albums/{folge}", f"/api/me/artists/{drei}",
                "/api/me/likes/999999", "/api/me/albums/999999", "/api/me/artists/999999"):
        assert delete(url, headers=env.kim).status_code == 204, url
    # Bestandskonten (uneingeschränkt) bekommen für unbekannte IDs weiter 404
    assert delete("/api/me/likes/999999", headers=env.admin).json()["detail"] == "Titel nicht gefunden."

    # Vorher alles freigegeben: Likes, Speicherungen und Verlauf auch für verborgene Inhalte anlegen
    env.patch_user(env.kim_id, all_categories=True)
    for url in (f"/api/me/likes/{bonus}", f"/api/me/likes/{visible}", f"/api/me/albums/{folge}",
                f"/api/me/albums/{opera}", f"/api/me/artists/{drei}", f"/api/me/artists/{queen}"):
        assert put(url, headers=env.kim).status_code == 204, url
    for track_id, context in ((bonus, {"context_type": "album", "context_id": folge}), (visible, {})):
        body = {"track_id": track_id, "seconds": 60, **context}
        assert env.client.post("/api/me/history", headers=env.kim, json=body).status_code == 204
    assert env.get(env.kim, "/api/me/likes")["total"] == 2

    # Rubriken wieder eingeschränkt: Verborgenes ist ausgeblendet, aber nicht gelöscht
    env.patch_user(env.kim_id, all_categories=False)
    likes = env.get(env.kim, "/api/me/likes")
    assert likes["total"] == 1 and [i["track"]["title"] for i in likes["items"]] == ["Get Lucky"]
    ids = env.get(env.kim, "/api/me/likes/ids")
    assert ids["tracks"] == [visible] and ids["albums"] == [opera] and ids["artists"] == [queen]
    library = env.get(env.kim, "/api/me/library")
    assert library["liked_count"] == 1
    assert [a["id"] for a in library["albums"]] == [opera] and library["albums"][0]["track_count"] == 2
    assert [a["id"] for a in library["artists"]] == [queen] and library["artists"][0]["track_count"] == 2
    assert titles([e["track"] for e in env.get(env.kim, "/api/me/history")]) == {"Get Lucky"}
    assert titles(env.get(env.kim, "/api/me/top-tracks")) == {"Get Lucky"}
    recent = env.get(env.kim, "/api/me/recent")
    assert all(not (c["type"] == "album" and c["id"] == str(folge)) for c in recent)

    env.patch_user(env.kim_id, all_categories=True)
    assert env.get(env.kim, "/api/me/likes")["total"] == 2  # nach erneuter Freigabe wieder da

    # Eingeschränkt lässt sich ein bestehender Like auf einen verborgenen Titel weiter löschen
    env.patch_user(env.kim_id, all_categories=False)
    assert delete(f"/api/me/likes/{bonus}", headers=env.kim).status_code == 204
    env.patch_user(env.kim_id, all_categories=True)
    assert env.get(env.kim, "/api/me/likes")["total"] == 1
    assert any(c["type"] == "album" and c["id"] == str(folge) for c in env.get(env.kim, "/api/me/recent"))


def test_home_shows_nothing_hidden(env: Env) -> None:
    # Die Familie hört verborgene Titel; sie dürfen bei kim nirgends auftauchen
    for title in HIDDEN | VISIBLE:
        body = {"track_id": env.track(title)["id"], "seconds": 100}
        assert env.client.post("/api/me/history", headers=env.admin, json=body).status_code == 204
    env.patch_user(env.kim_id, all_categories=True)
    for title in ("Bonus Track", "Get Lucky"):
        body = {"track_id": env.track(title)["id"], "seconds": 100, "context_type": "album",
                "context_id": env.track(title)["album"]["id"]}
        assert env.client.post("/api/me/history", headers=env.kim, json=body).status_code == 204
    env.patch_user(env.kim_id, all_categories=False)

    admin_home = env.get(env.admin, "/api/home")
    assert HIDDEN & all_track_titles(admin_home)
    home = env.get(env.kim, "/api/home")
    shown = all_track_titles(home)
    assert shown and shown <= VISIBLE
    sections = {s["key"]: s for s in home["sections"]}
    assert titles(sections["family"]["tracks"]) <= VISIBLE
    assert "videos" not in sections
    visible_albums = {a["id"] for a in env.get(env.kim, "/api/albums", limit=500)["items"]}
    visible_artists = {a["id"] for a in env.get(env.kim, "/api/artists", limit=500)["items"]}
    for section in home["sections"]:
        assert {a["id"] for a in section["albums"]} <= visible_albums
        assert {a["id"] for a in section["artists"]} <= visible_artists
        for artist in section["artists"]:
            if artist["name"] == "Queen":
                assert artist["track_count"] == 2
    for context in home["quick_access"] + sections.get("recent", {"contexts": []})["contexts"]:
        if context["type"] == "album":
            assert int(context["id"]) in visible_albums
    mixes = sections.get("mixes", {"contexts": []})["contexts"]
    assert "genre:Hörspiel" not in {m["id"] for m in mixes}


def test_mixes_and_radio(env: Env) -> None:
    drei = env.track("Kapitel 1")["artists"][0]["id"]
    queen = env.track("Bohemian Rhapsody")["artists"][0]["id"]
    for key in (f"artist:{drei}", f"category:{env.categories['Hörspiele & Hörbücher']}", "genre:Hörspiel",
                "artist:999999"):
        assert env.status(env.kim, f"/api/mixes/{key}") == (404, "Mix nicht gefunden."), key
    assert env.get(env.admin, "/api/mixes/genre:Hörspiel")["tracks"]
    rock = env.get(env.kim, "/api/mixes/genre:Rock")
    assert titles(rock["tracks"]) == {"Bohemian Rhapsody"}
    assert "Bonus Track" in titles(env.get(env.admin, "/api/mixes/genre:Rock")["tracks"])
    assert titles(env.get(env.kim, f"/api/mixes/artist:{queen}")["tracks"]) <= VISIBLE
    assert titles(env.get(env.kim, f"/api/mixes/category:{env.categories['Musik']}")["tracks"]) == VISIBLE
    assert titles(env.get(env.kim, "/api/mixes/discover")["tracks"]) <= VISIBLE
    assert titles(env.get(env.kim, "/api/mixes/recent")["tracks"]) <= VISIBLE

    bonus = env.track("Bonus Track")["id"]
    assert env.status(env.kim, f"/api/tracks/{bonus}/radio") == (404, "Titel nicht gefunden.")
    radio = env.get(env.kim, f"/api/tracks/{env.track('Bohemian Rhapsody')['id']}/radio")
    assert titles(radio) <= VISIBLE and "Love of My Life" in titles(radio)
    assert "Bonus Track" in titles(env.get(env.admin, f"/api/tracks/{env.track('Bohemian Rhapsody')['id']}/radio"))


# ---------------------------------------------------------------------------- Playlists


def test_playlist_of_another_user_with_mixed_tracks(env: Env) -> None:
    order = ["Bohemian Rhapsody", "Bonus Track", "Love of My Life", "Kapitel 1", "Get Lucky"]
    created = env.client.post(
        "/api/playlists", headers=env.admin,
        json={"name": "Gemischt", "is_collaborative": True, "track_ids": [env.track(t)["id"] for t in order]},
    ).json()
    url = f"/api/playlists/{created['id']}"

    def view(headers: dict[str, str]) -> dict:
        return env.get(headers, url)

    def item_titles(detail: dict) -> list[str]:
        return [i["track"]["title"] for i in detail["items"]]

    mine = view(env.kim)
    assert item_titles(mine) == ["Bohemian Rhapsody", "Love of My Life", "Get Lucky"]
    assert [i["position"] for i in mine["items"]] == [0, 1, 2]
    assert mine["track_count"] == 3
    expected = sum(env.track(t)["duration"] for t in ("Bohemian Rhapsody", "Love of My Life", "Get Lucky"))
    assert mine["duration"] == pytest.approx(expected)
    assert env.track("Bonus Track")["cover_id"] not in mine["mosaic"]
    admin = view(env.admin)
    assert admin["track_count"] == 5 and [i["position"] for i in admin["items"]] == [0, 1, 2, 3, 4]
    family = {p["id"]: p for p in env.get(env.kim, "/api/playlists", scope="family")}
    assert family[created["id"]]["track_count"] == 3

    # Verschieben: sichtbarer Index 2 -> 0 rückt vor den bisher ersten sichtbaren Eintrag
    lucky = mine["items"][2]["item_id"]
    moved = env.client.post(f"{url}/items/move", headers=env.kim, json={"item_id": lucky, "position": 0})
    assert moved.status_code == 200
    assert item_titles(moved.json()) == ["Get Lucky", "Bohemian Rhapsody", "Love of My Life"]
    assert item_titles(view(env.admin)) == ["Get Lucky", "Bohemian Rhapsody", "Bonus Track", "Love of My Life",
                                            "Kapitel 1"]
    # ans Ende (Index >= n) und ein verborgener Eintrag gilt als nicht vorhanden
    to_end = env.client.post(f"{url}/items/move", headers=env.kim, json={"item_id": lucky, "position": 7}).json()
    assert item_titles(to_end) == ["Bohemian Rhapsody", "Love of My Life", "Get Lucky"]
    assert item_titles(view(env.admin))[-1] == "Get Lucky"
    hidden_item = next(i["item_id"] for i in view(env.admin)["items"] if i["track"]["title"] == "Bonus Track")
    response = env.client.post(f"{url}/items/move", headers=env.kim, json={"item_id": hidden_item, "position": 0})
    assert response.status_code == 404 and response.json()["detail"] == "Eintrag nicht in dieser Playlist."

    # Hinzufügen an sichtbarer Position 1 = vor dem zweiten sichtbaren Eintrag (global hinter „Bonus Track“)
    schrei = env.track("Schrei nach Liebe")["id"]
    added = env.client.post(f"{url}/items", headers=env.kim, json={"track_ids": [schrei], "position": 1}).json()
    assert item_titles(added) == ["Bohemian Rhapsody", "Schrei nach Liebe", "Love of My Life", "Get Lucky"]
    assert item_titles(view(env.admin)) == ["Bohemian Rhapsody", "Bonus Track", "Schrei nach Liebe",
                                            "Love of My Life", "Kapitel 1", "Get Lucky"]
    at_end = env.client.post(f"{url}/items", headers=env.kim, json={"track_ids": [schrei], "position": 99}).json()
    assert item_titles(at_end)[-1] == "Schrei nach Liebe" and item_titles(view(env.admin))[-1] == "Schrei nach Liebe"
    # verborgene Titel lassen sich nicht hinzufügen – gleiche Antwort wie bei unbekannten
    bonus = env.track("Bonus Track")["id"]
    hidden = env.client.post(f"{url}/items", headers=env.kim, json={"track_ids": [bonus]})
    assert hidden.status_code == 404 and hidden.json()["detail"] == f"Titel nicht gefunden: [{bonus}]"
    unknown = env.client.post(f"{url}/items", headers=env.kim, json={"track_ids": [999999]})
    assert unknown.json()["detail"] == "Titel nicht gefunden: [999999]"

    # Entfernen: verborgene IDs werden wie unbekannte übergangen
    before = view(env.admin)["track_count"]
    removed = env.client.post(f"{url}/items/remove", headers=env.kim, json={"item_ids": [hidden_item, 999999]})
    assert removed.status_code == 200
    assert view(env.admin)["track_count"] == before
    visible_item = removed.json()["items"][0]["item_id"]
    env.client.post(f"{url}/items/remove", headers=env.kim, json={"item_ids": [visible_item]})
    assert view(env.admin)["track_count"] == before - 1
    assert "Bonus Track" in item_titles(view(env.admin))


def test_own_playlist_with_hidden_tracks_keeps_global_stats(env: Env) -> None:
    # Playlist eines Kontos, das früher alles sah – die gespeicherten Werte bleiben global
    env.patch_user(env.kim_id, all_categories=True)
    ids = [env.track(t)["id"] for t in ("Bonus Track", "Get Lucky")]
    created = env.client.post("/api/playlists", headers=env.kim, json={"name": "Meins", "track_ids": ids}).json()
    assert created["track_count"] == 2
    env.patch_user(env.kim_id, all_categories=False)
    mine = env.get(env.kim, f"/api/playlists/{created['id']}")
    assert mine["track_count"] == 1 and [i["track"]["title"] for i in mine["items"]] == ["Get Lucky"]
    library = env.get(env.kim, "/api/me/library")
    assert next(p for p in library["playlists"] if p["id"] == created["id"])["track_count"] == 1
    # der Admin sieht die gespeicherten (globalen) Werte
    assert env.get(env.admin, f"/api/playlists/{created['id']}")["track_count"] == 2


# ----------------------------------------------------------------------------- Downloads


class FakeYouTube:
    def __init__(self, items: list[YouTubeItem]) -> None:
        self.items = items

    def search(self, query: str, kind: str, limit: int) -> list[YouTubeItem]:
        return self.items


def test_youtube_search_and_download_target(env: Env) -> None:
    # Zwei lokale Titel bekommen eine YouTube-Kennung: einer sichtbar, einer verborgen
    with env.client.app.state.session_factory() as db:  # type: ignore[attr-defined]
        for title, video_id in (("Bohemian Rhapsody", "vis00000001"), ("Bonus Track", "hid00000001")):
            db.execute(update(Track).where(Track.id == env.track(title)["id"]).values(source_id=video_id))
        db.commit()
    env.client.app.state.youtube = FakeYouTube(  # type: ignore[attr-defined]
        [YouTubeItem(type="song", title=t, artists=["Queen"], video_id=v)
         for t, v in (("Bohemian Rhapsody", "vis00000001"), ("Bonus Track", "hid00000001"))]
    )

    # eingeschränkt ohne Download-Recht (wie alle selbst registrierten Konten): keine YouTube-Suche
    env.patch_user(env.kim_id, can_download=False)
    response = env.client.get("/api/youtube/search", headers=env.kim, params={"q": "queen"})
    assert response.status_code == 403
    assert response.json()["detail"] == "Downloads sind für dein Konto nicht freigeschaltet."
    assert env.status(env.kim, "/api/youtube/albums/MPREb_x")[0] == 403
    # uneingeschränkt ohne Download-Recht: wie bisher
    _, lena = env.make_user("lena", can_download=False)
    results = env.get(lena, "/api/youtube/search", q="queen")["results"]
    assert [r["in_library_track_id"] for r in results] == [env.track("Bohemian Rhapsody")["id"],
                                                          env.track("Bonus Track")["id"]]
    # eingeschränkt mit Download-Recht: verborgene Treffer gelten als „nicht in der Bibliothek“
    env.patch_user(env.kim_id, can_download=True)
    results = env.get(env.kim, "/api/youtube/search", q="queen")["results"]
    assert [r["in_library_track_id"] for r in results] == [env.track("Bohemian Rhapsody")["id"], None]

    # Ziel-Rubrik: eine verborgene gilt als nicht vorhanden
    hoer = env.categories["Hörspiele & Hörbücher"]
    body = {"video_id": "neu00000001", "media_type": "audio", "title": "Neu", "category_id": hoer}
    response = env.client.post("/api/downloads", headers=env.kim, json=body)
    assert response.status_code == 404 and response.json()["detail"] == "Rubrik nicht gefunden."
    # ohne sichtbare Video-Rubrik kein Video-Download
    body = {"video_id": "neu00000002", "media_type": "video", "title": "Neu"}
    response = env.client.post("/api/downloads", headers=env.kim, json=body)
    assert response.status_code == 409
    assert response.json()["detail"] == "Für dein Konto ist keine Rubrik freigegeben, in die geladen werden kann."


def test_default_download_category_for_restricted_accounts(env: Env) -> None:
    from app.routers.downloads import _target_category

    musik, hoer = env.categories["Musik"], env.categories["Hörspiele & Hörbücher"]
    with env.client.app.state.session_factory() as db:  # type: ignore[attr-defined]
        assert _target_category(db, None, "audio", UNRESTRICTED).id == musik
        assert _target_category(db, None, "audio", Visibility(frozenset({musik, hoer}))).id == musik
        # Standard-Rubrik verborgen -> die erste sichtbare
        assert _target_category(db, None, "audio", Visibility(frozenset({hoer}))).id == hoer
        assert _target_category(db, hoer, "audio", Visibility(frozenset({hoer}))).id == hoer


# ----------------------------------------------------------------- leer / uneingeschränkt


def test_empty_selection_sees_nothing(env: Env) -> None:
    _, nobody = env.make_user("leer", all_categories=False, category_ids=[])
    assert env.get(nobody, "/api/tracks")["total"] == 0
    assert env.get(nobody, "/api/albums")["total"] == 0
    assert env.get(nobody, "/api/artists")["total"] == 0
    assert env.get(nobody, "/api/categories") == []
    assert env.get(nobody, "/api/home") == {"quick_access": [], "sections": []}
    found = env.get(nobody, "/api/search", q="Queen")
    assert found["tracks"] == found["artists"] == found["albums"] == found["videos"] == []
    stats = env.get(nobody, "/api/library")
    assert (stats["tracks"], stats["videos"], stats["artists"], stats["albums"]) == (0, 0, 0, 0)
    me = env.get(nobody, "/api/me")
    assert me["all_categories"] is False and me["category_ids"] == []
    assert env.client.get(f"/api/covers/{env.track('Get Lucky')['cover_id']}", headers=nobody).status_code == 404


def test_release_takes_effect_immediately(env: Env) -> None:
    assert env.get(env.kim, "/api/tracks")["total"] == 4
    env.patch_user(env.kim_id, category_ids=[env.categories["Musik"], env.categories["Hörspiele & Hörbücher"]])
    assert env.get(env.kim, "/api/tracks")["total"] == 6  # gleicher Token, neue Freigabe
    env.patch_user(env.kim_id, all_categories=True)
    assert env.get(env.kim, "/api/tracks")["total"] == 7
    env.patch_user(env.kim_id, all_categories=False, category_ids=[])
    assert env.get(env.kim, "/api/tracks")["total"] == 0


def test_unrestricted_accounts_get_identical_answers(env: Env) -> None:
    """Ein per POST /users angelegtes Konto, ein Admin und ein Admin mit beliebigen Rubrik-Feldern sehen dasselbe."""
    _, lena = env.make_user("lena")
    _, other_admin = env.make_user("chefin", is_admin=True, all_categories=False, category_ids=[])
    opera = env.track("Bohemian Rhapsody")["album"]["id"]
    queen = env.track("Bohemian Rhapsody")["artists"][0]["id"]
    urls = [
        ("/api/tracks", {"limit": 500}), ("/api/albums", {"limit": 500}), ("/api/artists", {"limit": 500}),
        ("/api/artists", {"sort": "tracks"}), (f"/api/albums/{opera}", {}), (f"/api/artists/{queen}", {}),
        ("/api/search", {"q": "Queen"}), ("/api/search", {"q": "Bonus"}), ("/api/categories", {}),
        ("/api/library", {}),
    ]
    for url, params in urls:
        reference = env.get(env.admin, url, **params)
        assert env.get(lena, url, **params) == reference, url
        assert env.get(other_admin, url, **params) == reference, url
    # die Zähler entsprechen den gespeicherten (globalen) Werten
    assert env.get(lena, f"/api/albums/{opera}")["track_count"] == 3
    assert len(env.get(lena, "/api/tracks", limit=500)["items"]) == 7


# ------------------------------------------------------------------------------ Migration


def test_migration_0009_keeps_existing_accounts_unrestricted(tmp_path: Path) -> None:
    db_file = tmp_path / "migration.db"
    url = f"sqlite:///{db_file}"
    config = alembic_config(url)
    command.upgrade(config, "0008")
    now = "2026-11-11 12:00:00.000000"
    with sqlite3.connect(db_file) as con:
        for user_id, name, admin, active in ((1, "admin", 1, 1), (2, "lena", 0, 1), (3, "gesperrt", 0, 0)):
            con.execute(
                "INSERT INTO users (id, username, display_name, password_hash, is_admin, is_active, can_download, "
                "created_at, updated_at) VALUES (?, ?, ?, 'x', ?, ?, 1, ?, ?)",
                (user_id, name, name.title(), admin, active, now, now),
            )
        con.execute(
            "INSERT INTO categories (id, name, slug, folder, media_type, icon, sort_order, is_default, created_at) "
            "VALUES (1, 'Musik', 'musik', 'Musik', 'audio', 'music_note', 0, 1, ?)",
            (now,),
        )
        users_before = con.execute("SELECT * FROM users ORDER BY id").fetchall()

    command.upgrade(config, "0009")
    with sqlite3.connect(db_file) as con:
        con.execute("PRAGMA foreign_keys=ON")
        # Bestandsdaten bleiben; alle Konten sehen weiter alles, keiner wartet, keiner ist selbst registriert
        assert [row[:-3] for row in con.execute("SELECT * FROM users ORDER BY id")] == users_before
        assert con.execute(
            "SELECT all_categories, approval_pending, self_registered FROM users ORDER BY id"
        ).fetchall() == [(1, 0, 0)] * 3
        assert con.execute("SELECT count(*) FROM user_categories").fetchone()[0] == 0
        # CASCADE beim Löschen von Rubrik und Konto
        con.execute("INSERT INTO user_categories (user_id, category_id) VALUES (2, 1)")
        con.execute("INSERT INTO user_categories (user_id, category_id) VALUES (3, 1)")
        con.execute("DELETE FROM users WHERE id = 3")
        assert con.execute("SELECT user_id FROM user_categories").fetchall() == [(2,)]
        con.execute("DELETE FROM categories WHERE id = 1")
        assert con.execute("SELECT count(*) FROM user_categories").fetchone()[0] == 0
        # keine neuen Schalter in der Datenbank: Registrierung bleibt „aus“
        assert con.execute("SELECT count(*) FROM app_settings").fetchone()[0] == 0

    engine = create_engine(url)
    with engine.connect() as connection:
        context = MigrationContext.configure(connection, opts={"compare_type": True, "render_as_batch": True})
        assert compare_metadata(context, Base.metadata) == []
    engine.dispose()

    # wartendes Konto anlegen, dann zurück: Spalten und Tabelle verschwinden, das Konto bleibt gesperrt
    with sqlite3.connect(db_file) as con:
        con.execute(
            "INSERT INTO users (id, username, display_name, password_hash, is_admin, is_active, can_download, "
            "created_at, updated_at, all_categories, approval_pending, self_registered) "
            "VALUES (4, 'wartet', 'Wartet', 'x', 0, 0, 0, ?, ?, 0, 1, 1)",
            (now, now),
        )
        con.execute("INSERT INTO user_categories (user_id, category_id) SELECT 4, id FROM categories")
    command.downgrade(config, "0008")
    with sqlite3.connect(db_file) as con:
        tables = {row[0] for row in con.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
        assert "user_categories" not in tables
        columns = [row[1] for row in con.execute("PRAGMA table_info(users)")]
        assert "all_categories" not in columns and "approval_pending" not in columns
        assert "self_registered" not in columns
        assert con.execute("SELECT is_active FROM users WHERE id = 4").fetchone() == (0,)
        assert [row for row in con.execute("SELECT * FROM users WHERE id < 4 ORDER BY id")] == users_before[:2]
    command.upgrade(config, "head")
    with sqlite3.connect(db_file) as con:
        assert con.execute("SELECT all_categories FROM users WHERE id = 4").fetchone() == (1,)
