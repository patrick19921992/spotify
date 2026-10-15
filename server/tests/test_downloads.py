"""YouTube-Suche und Downloader (mit yt-dlp-Attrappe und nachgestellter YouTube-Music-Antwort)."""

import time
from collections.abc import Callable, Iterator

import pytest
from fastapi.testclient import TestClient
from mutagen.oggopus import OggOpus

from app.config import Settings
from app.downloads import tagging
from app.downloads.youtube import LyricsResult, YouTubeAlbum, YouTubeError, YouTubeItem, parse_item
from app.main import create_app

from .conftest import ADMIN_PASSWORD, bearer, login
from .media_factory import FFMPEG, cover_bytes

pytestmark = pytest.mark.skipif(FFMPEG is None, reason="ffmpeg wird für die Downloader-Tests gebraucht")

THUMB = "https://lh3.googleusercontent.com/cover=w1200-h1200"
SONG = YouTubeItem(
    type="song", title="Mr. Brightside", artists=["The Killers"], video_id="aaaaaaaaaa1", album="Hot Fuss",
    album_browse_id="MPREb_hotfuss", duration=222, year=2004, thumbnail_url=THUMB,
)


class FakeYouTube:
    def __init__(self) -> None:
        self.fail = False

    def search(self, query: str, kind: str, limit: int) -> list[YouTubeItem]:
        if self.fail:
            raise YouTubeError("YouTube Music ist gerade nicht erreichbar (Test).")
        if kind == "albums":
            return [YouTubeItem(type="album", title="Hot Fuss", artists=["The Killers"], browse_id="MPREb_hotfuss",
                                year=2004, thumbnail_url=THUMB)]
        if kind == "videos":
            return [YouTubeItem(type="video", title="Mr. Brightside (Official Video)", artists=["The Killers"],
                                video_id="vvvvvvvvvv1", duration=230, thumbnail_url="https://i.ytimg.com/vi/x/hq.jpg")]
        return [SONG]

    def album(self, browse_id: str) -> YouTubeAlbum:
        tracks = [
            YouTubeItem(type="song", title=title, artists=["The Killers"], video_id=f"album000{n:03d}"[:11],
                        album="Hot Fuss", track_number=n, thumbnail_url=THUMB)
            for n, title in enumerate(["Jenny", "Mr. Brightside", "Smile Like You Mean It"], start=1)
        ]
        return YouTubeAlbum(browse_id=browse_id, title="Hot Fuss", artists=["The Killers"], year=2004,
                            thumbnail_url=THUMB, tracks=tracks)

    def lyrics(self, video_id: str) -> LyricsResult | None:
        if video_id == "aaaaaaaaaa1":
            lines = [(0, "Coming out of my cage"), (2500, "And I've been doing just fine")]
            return LyricsResult(synced=True, lines=lines)
        return None


class Env:
    def __init__(self, client: TestClient, settings: Settings, headers: dict[str, str], tokens: dict) -> None:
        self.client = client
        self.settings = settings
        self.headers = headers
        self.tokens = tokens
        self.youtube: FakeYouTube = client.app.state.youtube

    def post(self, url: str, body: dict, headers: dict[str, str] | None = None, expected: int = 201) -> dict | list:
        response = self.client.post(url, headers=headers or self.headers, json=body)
        assert response.status_code == expected, response.text
        return response.json()

    def wait(self, job_id: int, states: tuple[str, ...] = ("done", "failed", "cancelled"), timeout: float = 60) -> dict:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            job = self.client.get(f"/api/downloads/{job_id}", headers=self.headers).json()
            if job["status"] in states:
                return job
            time.sleep(0.1)
        raise AssertionError(f"Download {job_id} nicht fertig geworden: {job}")


@pytest.fixture
def env(settings: Settings, monkeypatch: pytest.MonkeyPatch) -> Iterator[Env]:
    album_art = cover_bytes((200, 40, 40), size=600)
    monkeypatch.setattr(tagging, "fetch_image", lambda url, timeout=20: album_art if url else None)
    monkeypatch.setattr(tagging, "fetch_lrclib", lambda meta, duration, timeout=10: None)
    app = create_app(settings)
    app.state.youtube = FakeYouTube()
    app.state.downloads.youtube = app.state.youtube
    with TestClient(app) as client:
        tokens = login(client, "admin", ADMIN_PASSWORD)
        yield Env(client, settings, bearer(tokens), tokens)


# -------------------------------------------------------------------- Suche


def test_parse_ytmusic_results() -> None:
    raw = {
        "resultType": "song", "title": "Song", "videoId": "abcdefghijk", "duration_seconds": 200,
        "artists": [{"name": "Band", "id": "x"}], "album": {"name": "Album", "id": "MPREb_1"}, "year": "2020",
        "thumbnails": [{"url": "https://lh3.googleusercontent.com/a=w60-h60", "width": 60, "height": 60},
                       {"url": "https://lh3.googleusercontent.com/a=w120-h120", "width": 120, "height": 120}],
    }
    item = parse_item(raw)
    assert item is not None
    assert item.thumbnail_url == "https://lh3.googleusercontent.com/a=w1200-h1200"
    assert (item.album, item.year, item.artists) == ("Album", 2020, ["Band"])
    assert parse_item({**raw, "videoId": "kaputt"}) is None
    evil = {**raw, "thumbnails": [{"url": "http://192.168.1.1/x.jpg", "width": 1, "height": 1}]}
    assert parse_item(evil).thumbnail_url is None  # type: ignore[union-attr]


def test_search_marks_library_items(env: Env) -> None:
    result = env.client.get("/api/youtube/search", headers=env.headers, params={"q": "brightside"}).json()
    assert result["results"][0]["title"] == "Mr. Brightside"
    assert result["results"][0]["in_library_track_id"] is None
    job = env.post("/api/downloads", {"video_id": "aaaaaaaaaa1", "title": "Mr. Brightside",
                                      "artists": ["The Killers"], "album": "Hot Fuss", "thumbnail_url": THUMB})
    done = env.wait(job["id"])
    again = env.client.get("/api/youtube/search", headers=env.headers, params={"q": "brightside"}).json()
    assert again["results"][0]["in_library_track_id"] == done["track_id"]


def test_search_reports_youtube_outage(env: Env) -> None:
    env.youtube.fail = True
    response = env.client.get("/api/youtube/search", headers=env.headers, params={"q": "x"})
    assert response.status_code == 502
    assert "nicht erreichbar" in response.json()["detail"]


# --------------------------------------------------------------- Downloads


def test_song_download_end_to_end(env: Env) -> None:
    playlist = env.post("/api/playlists", {"name": "Neu"})
    job = env.post("/api/downloads", {
        "video_id": "aaaaaaaaaa1", "title": "Mr. Brightside", "artists": ["The Killers"], "album": "Hot Fuss",
        "track_number": 2, "year": 2004, "thumbnail_url": THUMB, "playlist_id": playlist["id"],
    })
    assert job["status"] in ("queued", "downloading")
    done = env.wait(job["id"])
    assert done["status"] == "done", done
    assert done["progress"] == 1.0
    assert done["track_id"]

    track = env.client.get(f"/api/tracks/{done['track_id']}", headers=env.headers).json()
    assert track["title"] == "Mr. Brightside"
    assert track["artist_display"] == "The Killers"
    assert track["album"]["title"] == "Hot Fuss"
    assert track["track_number"] == 2 and track["year"] == 2004
    assert track["source"] == "youtube"
    assert track["codec"] == "opus"
    assert track["cover_id"] and track["cover_color"]

    path = env.settings.media_dir / "Musik" / "The Killers" / "Hot Fuss" / "02 - Mr. Brightside.opus"
    assert path.is_file()
    assert OggOpus(path)["youtube_id"] == ["aaaaaaaaaa1"]
    lyrics = env.client.get(f"/api/tracks/{done['track_id']}/lyrics", headers=env.headers).json()
    assert lyrics["synced"] is True
    assert lyrics["lines"][1] == {"time_ms": 2500, "text": "And I've been doing just fine"}

    detail = env.client.get(f"/api/playlists/{playlist['id']}", headers=env.headers).json()
    assert [i["track"]["title"] for i in detail["items"]] == ["Mr. Brightside"]
    assert not any(env.settings.downloads_tmp_dir.iterdir())  # Arbeitsordner aufgeräumt


def test_metadata_falls_back_to_ytdlp_info(env: Env) -> None:
    job = env.post("/api/downloads", {"video_id": "bbbbbbbbbb1"})
    done = env.wait(job["id"])
    track = env.client.get(f"/api/tracks/{done['track_id']}", headers=env.headers).json()
    assert (track["title"], track["artist_display"], track["album"]["title"]) == ("Yt Track", "Yt Artist", "Yt Album")


def test_video_download(env: Env) -> None:
    job = env.post("/api/downloads", {"video_id": "vvvvvvvvvv1", "media_type": "video",
                                      "title": "Mr. Brightside (Official Video)", "artists": ["The Killers"]})
    done = env.wait(job["id"])
    assert done["status"] == "done", done
    assert done["total_bytes"] == 400000  # Video + Ton zusammengerechnet
    folder = env.settings.media_dir / "Musikvideos" / "The Killers"
    assert (folder / "Mr. Brightside (Official Video).mp4").is_file()
    assert (folder / "Mr. Brightside (Official Video).jpg").is_file()
    track = env.client.get(f"/api/tracks/{done['track_id']}", headers=env.headers).json()
    assert track["media_type"] == "video"
    assert (track["width"], track["height"]) == (640, 360)
    assert track["artist_display"] == "The Killers"


def test_duplicate_is_instantly_done(env: Env) -> None:
    first = env.wait(env.post("/api/downloads", {"video_id": "aaaaaaaaaa1", "title": "Mr. Brightside",
                                                 "artists": ["The Killers"]})["id"])
    second = env.post("/api/downloads", {"video_id": "aaaaaaaaaa1"})
    assert second["status"] == "done"
    assert second["track_id"] == first["track_id"]


def test_failed_download_and_retry(env: Env) -> None:
    job = env.post("/api/downloads", {"video_id": "failfailfai", "title": "Kaputt"})
    failed = env.wait(job["id"])
    assert failed["status"] == "failed"
    assert "Video unavailable" in failed["error"]
    assert env.client.post(f"/api/downloads/{job['id']}/retry", headers=env.headers).json()["status"] == "queued"
    assert env.wait(job["id"])["status"] == "failed"


def test_cancel_running_download(env: Env) -> None:
    job = env.post("/api/downloads", {"video_id": "hanghanghan", "title": "Hängt"})
    env.wait(job["id"], states=("downloading",))
    response = env.client.post(f"/api/downloads/{job['id']}/cancel", headers=env.headers)
    assert response.status_code == 200
    cancelled = env.wait(job["id"], timeout=15)
    assert cancelled["status"] == "cancelled"
    assert not (env.settings.downloads_tmp_dir / f"job-{job['id']}").exists()


def test_album_download_keeps_track_numbers(env: Env) -> None:
    jobs = env.post("/api/downloads/album", {"browse_id": "MPREb_hotfuss"})
    assert [j["title"] for j in jobs] == ["Jenny", "Mr. Brightside", "Smile Like You Mean It"]
    finished = [env.wait(j["id"]) for j in jobs]
    assert all(j["status"] == "done" for j in finished), finished
    album_id = env.client.get(f"/api/tracks/{finished[0]['track_id']}", headers=env.headers).json()["album"]["id"]
    album = env.client.get(f"/api/albums/{album_id}", headers=env.headers).json()
    assert [(t["track_number"], t["title"]) for t in album["tracks"]] == [
        (1, "Jenny"), (2, "Mr. Brightside"), (3, "Smile Like You Mean It")
    ]


def test_url_import(env: Env) -> None:
    bad = env.client.post("/api/downloads/url", headers=env.headers, json={"url": "http://192.168.1.1/admin"})
    assert bad.status_code == 400
    jobs = env.post("/api/downloads/url", {"url": "https://www.youtube.com/playlist?list=PL123"})
    assert [j["video_id"] for j in jobs] == ["playlist001", "playlist002", "playlist003"]
    for job in jobs:
        assert env.wait(job["id"])["status"] == "done"


def test_download_rights_and_category_checks(env: Env, make_user: Callable[..., dict]) -> None:
    make_user("lena", "kinder-passwort", can_download=False)
    child = bearer(login(env.client, "lena", "kinder-passwort"))
    response = env.client.post("/api/downloads", headers=child, json={"video_id": "aaaaaaaaaa1"})
    assert response.status_code == 403
    assert env.client.get("/api/youtube/search", headers=child, params={"q": "x"}).status_code == 200

    categories = env.client.get("/api/categories", headers=env.headers).json()
    video_category = next(c for c in categories if c["media_type"] == "video")
    wrong = env.client.post("/api/downloads", headers=env.headers,
                            json={"video_id": "aaaaaaaaaa1", "category_id": video_category["id"]})
    assert wrong.status_code == 400
    bad_id = env.client.post("/api/downloads", headers=env.headers, json={"video_id": "../../etc"})
    assert bad_id.status_code == 422


def test_hoerspiel_category_target(env: Env) -> None:
    categories = env.client.get("/api/categories", headers=env.headers).json()
    hoerspiele = next(c for c in categories if c["folder"] == "Hoerspiele")
    job = env.post("/api/downloads", {"video_id": "ccccccccccc", "title": "Folge 1", "artists": ["Die drei ???"],
                                      "category_id": hoerspiele["id"]})
    done = env.wait(job["id"])
    # Album-Angabe kommt hier von yt-dlp ("Yt Album"), "???" ist im Ordnernamen nicht erlaubt
    assert (env.settings.media_dir / "Hoerspiele" / "Die drei" / "Yt Album" / "Folge 1.opus").is_file()
    track = env.client.get(f"/api/tracks/{done['track_id']}", headers=env.headers).json()
    assert track["category_id"] == hoerspiele["id"]


def test_downloads_are_private_per_user(env: Env, make_user: Callable[..., dict]) -> None:
    job = env.post("/api/downloads", {"video_id": "aaaaaaaaaa1"})
    env.wait(job["id"])
    make_user("tim", "kinder-passwort")
    child = bearer(login(env.client, "tim", "kinder-passwort"))
    assert env.client.get("/api/downloads", headers=child).json() == []
    assert env.client.get(f"/api/downloads/{job['id']}", headers=child).status_code == 404
    everyone = env.client.get("/api/downloads", headers=env.headers, params={"scope": "all"}).json()
    assert [j["id"] for j in everyone] == [job["id"]]


def test_websocket_live_progress(env: Env) -> None:
    with env.client.websocket_connect(f"/api/downloads/ws?token={env.tokens['access_token']}") as ws:
        assert ws.receive_json() == {"type": "snapshot", "jobs": []}
        job = env.post("/api/downloads", {"video_id": "vvvvvvvvvv2", "media_type": "video", "title": "Live"})
        seen: list[dict] = []
        while True:
            event = ws.receive_json()
            if event["type"] != "job" or event["job"]["id"] != job["id"]:
                continue
            seen.append(event["job"])
            if event["job"]["status"] in ("done", "failed"):
                break
    statuses = [e["status"] for e in seen]
    assert statuses[-1] == "done"
    assert "downloading" in statuses and "processing" in statuses
    progress = [e["progress"] for e in seen if e["status"] == "downloading"]
    assert progress == sorted(progress) and 0 < max(progress) < 1
    assert any(e["eta"] is not None and e["speed"] for e in seen)


def _next_job_event(ws, job_id: int | None = None) -> dict:
    """Nächstes Auftrags-Ereignis (Pings überspringen), optional nur für einen bestimmten Auftrag."""
    while True:
        event = ws.receive_json()
        if event["type"] == "job" and (job_id is None or event["job"]["id"] == job_id):
            return event["job"]


def test_websocket_shows_only_own_jobs_unless_admin_asks_for_all(env: Env, make_user: Callable[..., dict]) -> None:
    make_user("tim", "kinder-passwort")
    child_tokens = login(env.client, "tim", "kinder-passwort")
    url = "/api/downloads/ws?token="
    with (
        env.client.websocket_connect(url + env.tokens["access_token"]) as mine,
        env.client.websocket_connect(url + env.tokens["access_token"] + "&scope=all") as everyone,
        env.client.websocket_connect(url + child_tokens["access_token"] + "&scope=all") as kid,
    ):
        for ws in (mine, everyone, kid):
            assert ws.receive_json()["type"] == "snapshot"
        child_job = env.post("/api/downloads", {"video_id": "kkkkkkkkkk1", "title": "Kinderlied"},
                             headers=bearer(child_tokens))
        assert _next_job_event(kid)["id"] == child_job["id"]  # eigener Download
        assert _next_job_event(everyone)["id"] == child_job["id"]  # Admin mit scope=all
        env.wait(child_job["id"])
        own = env.post("/api/downloads", {"video_id": "aaaaaaaaaa1", "title": "Papas Lied"})
        # Ohne scope=all kommt beim Admin als Erstes sein eigener Download an, nichts vom Kind
        assert _next_job_event(mine)["id"] == own["id"]
        env.wait(own["id"])


def test_queue_positions_move_up_live(env: Env) -> None:
    env.client.app.state.downloads.stop()  # keine Worker: alles bleibt in der Warteschlange
    with env.client.websocket_connect(f"/api/downloads/ws?token={env.tokens['access_token']}") as ws:
        assert ws.receive_json()["type"] == "snapshot"
        jobs = [env.post("/api/downloads", {"video_id": f"qqqqqqqqqq{n}", "title": f"Q{n}"}) for n in range(3)]
        assert [j["queue_position"] for j in jobs] == [0, 1, 2]
        for job in jobs:
            assert _next_job_event(ws, job["id"])["status"] == "queued"
        cancelled = env.client.post(f"/api/downloads/{jobs[0]['id']}/cancel", headers=env.headers).json()
        assert cancelled["status"] == "cancelled"
        positions: dict[int, int | None] = {}
        while len(positions) < 2:
            event = ws.receive_json()
            assert event["type"] != "ping", "Die übrigen Aufträge wurden nicht mit neuem Platz gemeldet"
            if event["type"] == "job" and event["job"]["id"] != jobs[0]["id"]:
                positions[event["job"]["id"]] = event["job"]["queue_position"]
        assert positions == {jobs[1]["id"]: 0, jobs[2]["id"]: 1}


def test_websocket_closes_when_account_is_disabled(
    env: Env, make_user: Callable[..., dict], monkeypatch: pytest.MonkeyPatch
) -> None:
    from starlette.websockets import WebSocketDisconnect

    from app.routers import downloads as downloads_router

    monkeypatch.setattr(downloads_router, "ACCESS_CHECK_SECONDS", 0)  # bei jeder Runde prüfen
    kid = make_user("tim", "kinder-passwort")
    tokens = login(env.client, "tim", "kinder-passwort")
    with env.client.websocket_connect(f"/api/downloads/ws?token={tokens['access_token']}") as ws:
        assert ws.receive_json()["type"] == "snapshot"
        env.client.patch(f"/api/users/{kid['id']}", headers=env.headers, json={"is_active": False})
        ws.send_text("ping")  # nächste Runde auslösen
        with pytest.raises(WebSocketDisconnect) as closed:
            ws.receive_json()
    assert closed.value.code == 4401


def test_same_song_for_two_users_gives_each_their_own_job(env: Env, make_user: Callable[..., dict]) -> None:
    make_user("tim", "kinder-passwort")
    kid = bearer(login(env.client, "tim", "kinder-passwort"))
    playlist = env.post("/api/playlists", {"name": "Tims Lieder"}, headers=kid)
    parent_job = env.post("/api/downloads", {"video_id": "ddddddddddd", "title": "Gemeinsam"})
    kid_job = env.post("/api/downloads", {"video_id": "ddddddddddd", "title": "Gemeinsam",
                                          "playlist_id": playlist["id"]}, headers=kid)
    assert kid_job["id"] != parent_job["id"]
    assert kid_job["user"]["display_name"] != "Admin"
    # Das Kind sieht seinen Auftrag und kann ihn verfolgen
    assert env.client.get(f"/api/downloads/{kid_job['id']}", headers=kid).status_code == 200
    parent_done = env.wait(parent_job["id"])
    deadline = time.monotonic() + 60
    while (job := env.client.get(f"/api/downloads/{kid_job['id']}", headers=kid).json())["status"] != "done":
        assert job["status"] not in ("failed", "cancelled"), job
        assert time.monotonic() < deadline
        time.sleep(0.1)
    # Nur einmal geladen, und der Titel landet in der Playlist des Kindes
    assert job["track_id"] == parent_done["track_id"]
    items = env.client.get(f"/api/playlists/{playlist['id']}", headers=kid).json()["items"]
    assert [i["track"]["id"] for i in items] == [parent_done["track_id"]]


def test_long_japanese_title_fits_the_filesystem(env: Env) -> None:
    title = "【公式】" + "あ" * 90
    job = env.post("/api/downloads", {"video_id": "jjjjjjjjjjj", "media_type": "video", "title": title,
                                      "artists": ["歌手"]})
    done = env.wait(job["id"])
    assert done["status"] == "done", done
    files = list((env.settings.media_dir / "Musikvideos").rglob("*.mp4"))
    assert files and all(len(f.name.encode()) <= 255 for f in files)


def test_download_does_not_overwrite_or_delete_other_sidecars(env: Env) -> None:
    job = env.post("/api/downloads", {"video_id": "wwwwwwwwwww", "title": "Weg", "artists": ["Band"]})
    first = env.wait(job["id"])
    song = next((env.settings.media_dir / "Musik").rglob("Weg.opus"))
    # Neben dem Download liegt eine eigene FLAC gleichen Namens mit eigenem Songtext und Bild
    (song.parent / "Weg.flac").write_bytes(b"flac")
    (song.parent / "Weg.lrc").write_text("MEINE eigenen Lyrics", encoding="utf-8")
    (song.parent / "Weg.jpg").write_bytes(b"jpg")
    # Neuer Name, wenn schon eine gleichnamige Datei (egal welche Endung) existiert
    assert tagging.unique_path(song.parent / "Weg.m4a").name == "Weg (2).m4a"
    response = env.client.delete(f"/api/tracks/{first['track_id']}", headers=env.headers,
                                 params={"delete_file": True})
    assert response.status_code == 204
    assert not song.exists()
    # Die Begleitdateien gehören (auch) zur FLAC und bleiben
    assert (song.parent / "Weg.lrc").read_text(encoding="utf-8") == "MEINE eigenen Lyrics"
    assert (song.parent / "Weg.jpg").exists()


def test_worker_survives_locked_database(env: Env, monkeypatch: pytest.MonkeyPatch) -> None:
    """Ist die Datenbank kurz gesperrt (z. B. großer Scan), darf der Download-Worker nicht sterben."""
    from sqlalchemy.exc import OperationalError

    manager = env.client.app.state.downloads
    original = manager._claim
    failures = {"left": 2}

    def flaky_claim():  # type: ignore[no-untyped-def]
        if failures["left"] > 0:
            failures["left"] -= 1
            raise OperationalError("UPDATE download_jobs", {}, Exception("database is locked"))
        return original()

    monkeypatch.setattr(manager, "_claim", flaky_claim)
    job = env.post("/api/downloads", {"video_id": "lllllllllll", "title": "Trotzdem"})
    assert env.wait(job["id"])["status"] == "done"
    assert failures["left"] == 0


def test_download_without_thumbnail_url_gets_cover(env: Env) -> None:
    """Import per Link kennt kein Album-Cover: dann wird das YouTube-Vorschaubild zum Cover."""
    job = env.post("/api/downloads", {"video_id": "ttttttttttt", "title": "Ohne Bild", "artists": ["Band"]})
    done = env.wait(job["id"])
    assert done["status"] == "done", done
    track = env.client.get(f"/api/tracks/{done['track_id']}", headers=env.headers).json()
    assert track["cover_id"] is not None


def test_server_restart_requeues_running_download(env: Env) -> None:
    """Container-Neustart/Update: ein laufender Download wird beim nächsten Start fortgesetzt, nicht abgebrochen."""
    manager = env.client.app.state.downloads
    job = env.post("/api/downloads", {"video_id": "hangrestart", "title": "Lang"})
    env.wait(job["id"], states=("downloading",), timeout=15)
    manager.stop()
    assert env.client.get(f"/api/downloads/{job['id']}", headers=env.headers).json()["status"] == "queued"


def test_cancel_during_processing_is_respected(env: Env, monkeypatch: pytest.MonkeyPatch) -> None:
    """Abbrechen, während der Server die Datei verarbeitet: Der Titel landet nicht in der Bibliothek."""
    manager = env.client.app.state.downloads
    original = tagging.write_tags

    def tag_and_cancel(path, meta, cover):  # type: ignore[no-untyped-def]
        original(path, meta, cover)
        for flag in list(manager._cancel_flags.values()):  # Benutzer tippt jetzt auf "Abbrechen"
            flag.set()

    monkeypatch.setattr(tagging, "write_tags", tag_and_cancel)
    job = env.post("/api/downloads", {"video_id": "ppppppppppp", "title": "Doch nicht"})
    assert env.wait(job["id"])["status"] == "cancelled"
    assert not list((env.settings.media_dir / "Musik").rglob("Doch nicht*"))


def test_self_updated_ytdlp_only_wins_when_newer(settings: Settings) -> None:
    """Eine alte Kopie in DATA_DIR/ytdlp darf das neuere yt-dlp aus dem Image nicht überdecken."""
    from app.downloads import ytdlp

    package = settings.ytdlp_update_dir / "yt_dlp"
    package.mkdir(parents=True)
    (package / "version.py").write_text("__version__ = '2000.01.01'\n", encoding="utf-8")
    assert str(settings.ytdlp_update_dir) not in ytdlp.ytdlp_env(settings).get("PYTHONPATH", "")
    (package / "version.py").write_text("__version__ = '2999.01.01'\n", encoding="utf-8")
    assert str(settings.ytdlp_update_dir) in ytdlp.ytdlp_env(settings)["PYTHONPATH"]


def test_websocket_requires_login(env: Env) -> None:
    from starlette.websockets import WebSocketDisconnect

    with pytest.raises(WebSocketDisconnect), env.client.websocket_connect("/api/downloads/ws?token=kaputt") as ws:
        ws.receive_json()


def test_admin_status_and_track_delete(env: Env) -> None:
    status = env.client.get("/api/downloads-system", headers=env.headers).json()
    assert status["ytdlp_version"] == "2026.08.19-fake"
    assert status["ffmpeg_available"] is True
    done = env.wait(env.post("/api/downloads", {"video_id": "aaaaaaaaaa1", "title": "Weg",
                                                "artists": ["Band"]})["id"])
    path = env.settings.media_dir / "Musik" / "Band" / "Yt Album" / "Weg.opus"
    assert path.is_file() and path.with_suffix(".lrc").is_file()
    response = env.client.delete(f"/api/tracks/{done['track_id']}", headers=env.headers,
                                 params={"delete_file": "true"})
    assert response.status_code == 204
    assert not path.exists() and not path.with_suffix(".lrc").exists()


def test_stale_jobs_are_requeued_after_restart(settings: Settings, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(tagging, "fetch_image", lambda url, timeout=20: None)
    monkeypatch.setattr(tagging, "fetch_lrclib", lambda meta, duration, timeout=10: None)
    settings.download_workers = 1
    app = create_app(settings)
    app.state.youtube = FakeYouTube()
    app.state.downloads.youtube = app.state.youtube
    with TestClient(app) as client:
        headers = bearer(login(client, "admin", ADMIN_PASSWORD))
        app.state.downloads.stop()  # Worker anhalten, Auftrag "hängt" im Zustand downloading
        job = client.post("/api/downloads", headers=headers, json={"video_id": "ddddddddddd"}).json()
        from app.models import DownloadJob

        with app.state.session_factory() as db:
            db.get(DownloadJob, job["id"]).status = "downloading"
            db.commit()
        app.state.downloads.start()  # wie nach einem Neustart
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            current = client.get(f"/api/downloads/{job['id']}", headers=headers).json()
            if current["status"] == "done":
                break
            time.sleep(0.1)
        assert current["status"] == "done"


def test_lrc_parser() -> None:
    from app.library.lyrics import parse_lrc

    lines = parse_lrc("[ar:Band]\n[00:01.50]Eins\n[00:00.20][00:03.00]Refrain\nohne Zeit")
    assert lines == [(200, "Refrain"), (1500, "Eins"), (3000, "Refrain")]
    assert parse_lrc("nur\ntext") == [(None, "nur"), (None, "text")]


def test_safe_names() -> None:
    assert tagging.safe_name('AC/DC: "Live"?') == "ACDC Live"
    assert tagging.safe_name("...") == "Unbekannt"
    assert tagging.safe_name("Die drei ???") == "Die drei"
