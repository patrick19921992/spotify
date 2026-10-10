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
