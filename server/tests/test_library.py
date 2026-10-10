"""Bibliothek: Einlesen, Künstler/Alben, Cover, Suche, Streaming."""

import time

import pytest

from .conftest import Library, bearer, login
from .media_factory import FFMPEG, make_audio

pytestmark = pytest.mark.skipif(FFMPEG is None, reason="ffmpeg wird für die Medien-Tests gebraucht")


def test_scan_finds_all_media(lib: Library) -> None:
    status = lib.get("/api/library/scan")
    assert status["running"] is False
    assert status["added"] == 6
    assert status["errors"] == 1  # kaputt.mp3
    assert status["error_files"] == ["Musik/kaputt.mp3"]
    stats = lib.get("/api/library")
    assert stats["tracks"] == 5
    assert stats["videos"] == 1


def test_tags_are_read(lib: Library) -> None:
    track = lib.track_by_title("Bohemian Rhapsody")
    assert track["artist_display"] == "Queen"
    assert track["album"]["title"] == "A Night at the Opera"
    assert track["track_number"] == 11
    assert track["year"] == 1975
    assert track["genre"] == "Rock"
    assert track["codec"] == "mp3"
    assert 300 <= track["bitrate"] <= 330
    assert 1.5 < track["duration"] < 2.6
    assert track["cover_id"] and track["cover_color"].startswith("#")

    m4a = lib.track_by_title("Love of My Life")
    assert m4a["codec"] == "aac"
    assert m4a["track_number"] == 9
    assert m4a["album"]["id"] == track["album"]["id"]


def test_album_groups_tracks_in_order(lib: Library) -> None:
    track = lib.track_by_title("Bohemian Rhapsody")
    album = lib.get(f"/api/albums/{track['album']['id']}")
    assert album["artist"]["name"] == "Queen"
    assert album["track_count"] == 2
    assert album["year"] == 1975
    assert [t["title"] for t in album["tracks"]] == ["Love of My Life", "Bohemian Rhapsody"]
    assert album["cover_id"] == track["cover_id"]


def test_featured_artists_are_split(lib: Library) -> None:
    track = lib.track_by_title("Get Lucky")
    assert track["artist_display"] == "Daft Punk feat. Pharrell Williams"
    assert [a["name"] for a in track["artists"]] == ["Daft Punk", "Pharrell Williams"]
    assert track["codec"] == "opus"
    pharrell = track["artists"][1]
    detail = lib.get(f"/api/artists/{pharrell['id']}")
    assert [t["title"] for t in detail["top_tracks"]] == ["Get Lucky"]
    # Album gehört Daft Punk -> bei Pharrell unter "Enthalten auf"
    assert [a["title"] for a in detail["appears_on"]] == ["Random Access Memories"]
    assert detail["albums"] == []


def test_untagged_file_uses_folders_and_cover_jpg(lib: Library) -> None:
    track = lib.track_by_title("Schrei nach Liebe")
    assert track["artist_display"] == "Die Ärzte"
    assert track["album"]["title"] == "Die Bestie in Menschengestalt"
    assert track["track_number"] == 3
    assert track["codec"] == "flac"
    assert track["cover_id"] is not None


def test_video_with_sidecar_thumbnail(lib: Library) -> None:
    videos = lib.get("/api/tracks", media_type="video")["items"]
    assert len(videos) == 1
    video = videos[0]
    assert video["title"] == "Bohemian Rhapsody (Official Video)"
    assert video["artist_display"] == "Queen"
    assert video["album"] is None
    assert (video["width"], video["height"]) == (320, 180)
    assert video["codec"] == "h264"
    assert video["cover_id"] is not None
    queen = next(a for a in video["artists"])
    assert [v["title"] for v in lib.get(f"/api/artists/{queen['id']}")["videos"]] == [video["title"]]


def test_artist_list_and_counts(lib: Library) -> None:
    artists = lib.get("/api/artists")["items"]
    names = [a["name"] for a in artists]
    # Sortiert ohne Artikel: "Die Ärzte" unter Ä/A, "Die drei ???" unter d
    assert names == ["Die Ärzte", "Daft Punk", "Die drei ???", "Pharrell Williams", "Queen"]
    queen = next(a for a in artists if a["name"] == "Queen")
    assert queen["track_count"] == 3  # 2 Songs + 1 Video
    assert queen["album_count"] == 1
    assert queen["cover_id"] is not None


def test_categories_show_counts_and_filter(lib: Library) -> None:
    categories = {c["folder"]: c for c in lib.get("/api/categories")}
    assert categories["Musik"]["item_count"] == 4
    assert categories["Hoerspiele"]["item_count"] == 1
    assert categories["Musikvideos"]["item_count"] == 1
    hoerspiele = categories["Hoerspiele"]["id"]
    tracks = lib.get("/api/tracks", category_id=hoerspiele)["items"]
    assert [t["title"] for t in tracks] == ["Kapitel 1"]
    albums = lib.get("/api/albums", category_id=hoerspiele)["items"]
    assert [a["title"] for a in albums] == ["Folge 1: und der Super-Papagei"]


def test_pagination_and_sorting(lib: Library) -> None:
    first = lib.get("/api/tracks", limit=2, offset=0, sort="title")
    second = lib.get("/api/tracks", limit=2, offset=2, sort="title")
    assert first["total"] == 6
    assert len(first["items"]) == 2
    assert {t["id"] for t in first["items"]}.isdisjoint({t["id"] for t in second["items"]})
    recent = lib.get("/api/tracks", sort="recent", limit=1)["items"]
    assert len(recent) == 1


def test_search(lib: Library) -> None:
    result = lib.get("/api/search", q="bohemian")
    assert [t["title"] for t in result["tracks"]] == ["Bohemian Rhapsody"]
    assert [v["title"] for v in result["videos"]] == ["Bohemian Rhapsody (Official Video)"]
    assert result["top_result"]["type"] == "track"

    queen = lib.get("/api/search", q="Queen")
    assert queen["top_result"]["type"] == "artist"
    assert queen["top_result"]["artist"]["name"] == "Queen"
    assert {t["title"] for t in queen["tracks"]} == {"Bohemian Rhapsody", "Love of My Life"}


def test_search_handles_umlauts_and_multiple_words(lib: Library) -> None:
    for query in ("ärzte", "aerzte", "arzte", "AERZTE"):
        result = lib.get("/api/search", q=query)
        assert [a["name"] for a in result["artists"]] == ["Die Ärzte"], query
    assert [t["title"] for t in lib.get("/api/search", q="queen opera love")["tracks"]] == ["Love of My Life"]
    assert lib.get("/api/search", q="gibtsnichtxyz")["top_result"] is None


def test_rescan_skips_unchanged_and_detects_changes(lib: Library) -> None:
    again = lib.scan()
    assert (again["added"], again["updated"], again["removed"]) == (0, 0, 0)
    # Die defekte Datei zählt weiter als Fehler, wird aber nicht ständig neu gemeldet
    assert again["errors"] == 1 and again["error_files"] == ["Musik/kaputt.mp3"]

    flac = lib.settings.media_dir / lib.paths["flac"]
    from .media_factory import tag_flac

    tag_flac(flac, title="Schrei nach Liebe (Live)", artist="Die Ärzte")
    changed = lib.scan()
    assert changed["updated"] == 1
    assert lib.track_by_title("Schrei nach Liebe (Live)")["album"]["title"] == "Die Bestie in Menschengestalt"


def test_deleted_files_and_empty_albums_disappear(lib: Library) -> None:
    opus = lib.settings.media_dir / lib.paths["opus"]
    opus.unlink()
    result = lib.scan()
    assert result["removed"] == 1
    names = [a["name"] for a in lib.get("/api/artists")["items"]]
    assert "Daft Punk" not in names and "Pharrell Williams" not in names
    assert all(a["title"] != "Random Access Memories" for a in lib.get("/api/albums")["items"])


def test_new_category_picks_up_existing_files(lib: Library) -> None:
    make_audio(lib.settings.media_dir / "Kinderlieder" / "Alle meine Entchen.mp3", "mp3")
    created = lib.client.post(
        "/api/categories", headers=lib.headers, json={"name": "Kinderlieder", "media_type": "audio"}
    ).json()
    lib.scan()
    tracks = lib.get("/api/tracks", category_id=created["id"])["items"]
    assert [t["title"] for t in tracks] == ["Alle meine Entchen"]


def test_nested_category_is_not_scanned_twice(lib: Library) -> None:
    make_audio(lib.settings.media_dir / "Hoerspiele" / "Kinder" / "Benjamin Bluemchen.mp3", "mp3")
    lib.client.post(
        "/api/categories",
        headers=lib.headers,
        json={"name": "Kinderhörspiele", "media_type": "audio", "folder": "Hoerspiele/Kinder"},
    )
    lib.scan()
    matches = lib.get("/api/tracks", q="benjamin")["items"]
    assert len(matches) == 1
    category = next(c for c in lib.get("/api/categories") if c["id"] == matches[0]["category_id"])
    assert category["name"] == "Kinderhörspiele"


def test_deleting_category_removes_tracks_but_keeps_files(lib: Library) -> None:
    hoerspiele = next(c for c in lib.get("/api/categories") if c["folder"] == "Hoerspiele")
    assert lib.client.delete(f"/api/categories/{hoerspiele['id']}", headers=lib.headers).status_code == 204
    assert all(a["name"] != "Die drei ???" for a in lib.get("/api/artists")["items"])
    assert (lib.settings.media_dir / lib.paths["hoerspiel"]).exists()


def test_children_cannot_start_scan(lib: Library, make_user) -> None:  # type: ignore[no-untyped-def]
    make_user("lena", "kinder-passwort")
    child = bearer(login(lib.client, "lena", "kinder-passwort"))
    assert lib.client.get("/api/tracks", headers=child).status_code == 200
    assert lib.client.post("/api/library/scan", headers=child, json={}).status_code == 403


# ------------------------------------------------------------------ Streaming


def test_stream_supports_range_requests(lib: Library) -> None:
    track = lib.track_by_title("Bohemian Rhapsody")
    full = lib.client.get(f"/api/tracks/{track['id']}/stream", headers=lib.headers)
    assert full.status_code == 200
    assert full.headers["content-type"] == "audio/mpeg"
    assert full.headers["accept-ranges"] == "bytes"
    assert len(full.content) == track["file_size"]

    part = lib.client.get(f"/api/tracks/{track['id']}/stream", headers={**lib.headers, "Range": "bytes=100-199"})
    assert part.status_code == 206
    assert part.content == full.content[100:200]
    assert part.headers["content-range"] == f"bytes 100-199/{track['file_size']}"


def test_stream_with_media_token_in_link(lib: Library) -> None:
    track = lib.track_by_title("Love of My Life")
    url = f"/api/tracks/{track['id']}/stream"
    assert lib.client.get(url).status_code == 401
    assert lib.client.get(url, params={"t": "kaputt"}).status_code == 401
    ok = lib.client.get(url, params={"t": lib.tokens["media_token"]})
    assert ok.status_code == 200
    assert ok.headers["content-type"] == "audio/mp4"
    # Der Medien-Token gilt NICHT für die normale API
    media_as_bearer = {"Authorization": f"Bearer {lib.tokens['media_token']}"}
    assert lib.client.get("/api/me", headers=media_as_bearer).status_code == 401
    # Nach dem Abmelden ist auch der Medien-Token ungültig
    lib.client.post("/api/auth/logout", headers=lib.headers)
    assert lib.client.get(url, params={"t": lib.tokens["media_token"]}).status_code == 401


def test_opus_is_converted_for_iphone(lib: Library) -> None:
    track = lib.track_by_title("Get Lucky")
    url = f"/api/tracks/{track['id']}/stream"
    original = lib.client.get(url, headers=lib.headers)
    assert original.headers["content-type"] == "audio/ogg"

    started = time.monotonic()
    converted = lib.client.get(url, headers=lib.headers, params={"compatible": "true"})
    assert converted.status_code == 200
    assert converted.headers["content-type"] == "audio/mp4"
    assert converted.content[4:8] == b"ftyp"
    first_duration = time.monotonic() - started
    cached = list(lib.settings.transcode_dir.rglob("*.m4a"))
    assert len(cached) == 1

    # Zweiter Abruf kommt aus dem Zwischenspeicher, Spulen funktioniert auch hier
    part = lib.client.get(
        url, headers={**lib.headers, "Range": "bytes=0-99"}, params={"compatible": "true"}
    )
    assert part.status_code == 206 and len(part.content) == 100
    assert len(list(lib.settings.transcode_dir.rglob("*.m4a"))) == 1
    assert first_duration < 30


def test_compatible_formats_are_not_converted(lib: Library) -> None:
    for title in ("Bohemian Rhapsody", "Love of My Life", "Schrei nach Liebe"):
        track = lib.track_by_title(title)
        lib.client.get(f"/api/tracks/{track['id']}/stream", headers=lib.headers, params={"compatible": "true"})
    assert list(lib.settings.transcode_dir.rglob("*.m4a")) == []


def test_data_saver_quality(lib: Library) -> None:
    track = lib.track_by_title("Bohemian Rhapsody")  # 320 kbit/s
    low = lib.client.get(f"/api/tracks/{track['id']}/stream", headers=lib.headers, params={"quality": "low"})
    assert low.status_code == 200
    assert low.headers["content-type"] == "audio/mp4"
    assert len(low.content) < track["file_size"]


def test_video_stream(lib: Library) -> None:
    video = lib.get("/api/tracks", media_type="video")["items"][0]
    response = lib.client.get(
        f"/api/tracks/{video['id']}/stream", headers={**lib.headers, "Range": "bytes=0-1023"}
    )
    assert response.status_code == 206
    assert response.headers["content-type"] == "video/mp4"


def test_missing_file_returns_404(lib: Library) -> None:
    track = lib.track_by_title("Love of My Life")
    (lib.settings.media_dir / lib.paths["m4a"]).unlink()
    assert lib.client.get(f"/api/tracks/{track['id']}/stream", headers=lib.headers).status_code == 404


# ---------------------------------------------------------------------- Cover


def test_cover_sizes_and_caching(lib: Library) -> None:
    track = lib.track_by_title("Bohemian Rhapsody")
    url = f"/api/covers/{track['cover_id']}"
    for size in (64, 300, 0):
        response = lib.client.get(url, params={"size": size, "t": lib.tokens["media_token"]})
        assert response.status_code == 200
        assert response.headers["content-type"] == "image/jpeg"
        assert "immutable" in response.headers["cache-control"]
    from io import BytesIO

    from PIL import Image

    small = lib.client.get(url, params={"size": 64}, headers=lib.headers)
    assert Image.open(BytesIO(small.content)).size == (64, 64)
    assert lib.client.get(url).status_code == 401
    assert lib.client.get("/api/covers/../../etc/passwd", headers=lib.headers).status_code == 404
    assert lib.client.get("/api/covers/" + "0" * 40, headers=lib.headers).status_code == 404


def test_cover_color_is_dominant_color(lib: Library) -> None:
    track = lib.track_by_title("Bohemian Rhapsody")  # rotes Cover
    color = track["cover_color"]
    r, g, b = int(color[1:3], 16), int(color[3:5], 16), int(color[5:7], 16)
    assert r > 150 and g < 80 and b < 80
