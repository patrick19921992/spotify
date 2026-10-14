"""Playlists, Lieblingssongs, Bibliothek, Verlauf, Startseite, Mixe und Radio."""

from collections.abc import Callable

from .conftest import Library, bearer, login
from .media_factory import cover_bytes


def _ids(lib: Library) -> dict[str, int]:
    tracks = lib.get("/api/tracks", limit=500)["items"]
    return {t["title"]: t["id"] for t in tracks}


def _child(lib: Library, make_user: Callable[..., dict], name: str = "lena") -> dict[str, str]:
    make_user(name, "kinder-passwort")
    return bearer(login(lib.client, name, "kinder-passwort"))


def _create(lib: Library, headers: dict[str, str] | None = None, **body: object) -> dict:
    response = lib.client.post("/api/playlists", headers=headers or lib.headers, json={"name": "Test", **body})
    assert response.status_code == 201, response.text
    return response.json()


# ------------------------------------------------------------------ Playlists


def test_create_playlist_with_tracks(lib: Library) -> None:
    ids = _ids(lib)
    playlist = _create(lib, name="Roadtrip", description="Für die Fahrt",
                       track_ids=[ids["Bohemian Rhapsody"], ids["Get Lucky"]])
    assert playlist["name"] == "Roadtrip"
    assert playlist["track_count"] == 2
    assert 3 < playlist["duration"] < 6
    assert [i["track"]["title"] for i in playlist["items"]] == ["Bohemian Rhapsody", "Get Lucky"]
    assert [i["position"] for i in playlist["items"]] == [0, 1]
    assert playlist["is_owner"] and playlist["can_edit"]
    assert len(playlist["mosaic"]) == 2  # zwei verschiedene Cover
    assert playlist["cover_color"]


def test_add_insert_remove_and_move(lib: Library) -> None:
    ids = _ids(lib)
    playlist = _create(lib, track_ids=[ids["Bohemian Rhapsody"], ids["Get Lucky"]])
    url = f"/api/playlists/{playlist['id']}"

    inserted = lib.client.post(
        f"{url}/items", headers=lib.headers, json={"track_ids": [ids["Love of My Life"]], "position": 1}
    ).json()
    assert [i["track"]["title"] for i in inserted["items"]] == ["Bohemian Rhapsody", "Love of My Life", "Get Lucky"]

    first_item = inserted["items"][0]["item_id"]
    moved = lib.client.post(f"{url}/items/move", headers=lib.headers, json={"item_id": first_item, "position": 2})
    assert [i["track"]["title"] for i in moved.json()["items"]] == [
        "Love of My Life", "Get Lucky", "Bohemian Rhapsody"
    ]

    removed = lib.client.post(f"{url}/items/remove", headers=lib.headers, json={"item_ids": [first_item]}).json()
    assert [i["track"]["title"] for i in removed["items"]] == ["Love of My Life", "Get Lucky"]
    assert [i["position"] for i in removed["items"]] == [0, 1]
    assert removed["track_count"] == 2


def test_unknown_tracks_are_rejected(lib: Library) -> None:
    playlist = _create(lib)
    response = lib.client.post(
        f"/api/playlists/{playlist['id']}/items", headers=lib.headers, json={"track_ids": [999999]}
    )
    assert response.status_code == 404


def test_rename_and_delete(lib: Library) -> None:
    playlist = _create(lib)
    url = f"/api/playlists/{playlist['id']}"
    renamed = lib.client.patch(url, headers=lib.headers, json={"name": "  Sommer 2026  "}).json()
    assert renamed["name"] == "Sommer 2026"
    assert lib.client.delete(url, headers=lib.headers).status_code == 204
    assert lib.client.get(url, headers=lib.headers).status_code == 404


def test_private_playlists_are_private(lib: Library, make_user: Callable[..., dict]) -> None:
    playlist = _create(lib, name="Geheim")
    child = _child(lib, make_user)
    assert lib.client.get(f"/api/playlists/{playlist['id']}", headers=child).status_code == 404
    family = lib.client.get("/api/playlists", headers=child, params={"scope": "family"}).json()
    assert family == []


def test_public_playlist_can_be_followed_but_not_edited(lib: Library, make_user: Callable[..., dict]) -> None:
    ids = _ids(lib)
    playlist = _create(lib, name="Papas Hits", is_public=True, track_ids=[ids["Get Lucky"]])
    child = _child(lib, make_user)
    url = f"/api/playlists/{playlist['id']}"

    family = lib.client.get("/api/playlists", headers=child, params={"scope": "family"}).json()
    assert [p["name"] for p in family] == ["Papas Hits"]
    detail = lib.client.get(url, headers=child).json()
    assert detail["owner"]["display_name"] == "Admin"
    assert detail["can_edit"] is False and detail["is_owner"] is False

    add = lib.client.post(f"{url}/items", headers=child, json={"track_ids": [ids["Bohemian Rhapsody"]]})
    assert add.status_code == 403
    assert lib.client.patch(url, headers=child, json={"name": "Meins"}).status_code == 403
    assert lib.client.delete(url, headers=child).status_code == 403

    assert lib.client.put(f"{url}/follow", headers=child).status_code == 204
    library = lib.client.get("/api/playlists", headers=child).json()
    assert [p["name"] for p in library] == ["Papas Hits"]
    assert library[0]["is_following"] is True
    assert lib.client.delete(f"{url}/follow", headers=child).status_code == 204
    assert lib.client.get("/api/playlists", headers=child).json() == []


def test_collaborative_playlist(lib: Library, make_user: Callable[..., dict]) -> None:
    ids = _ids(lib)
    playlist = _create(lib, name="Familien-Party", is_collaborative=True)
    assert playlist["is_public"] is True  # gemeinsam heißt automatisch sichtbar
    child = _child(lib, make_user)
    url = f"/api/playlists/{playlist['id']}"
    added = lib.client.post(f"{url}/items", headers=child, json={"track_ids": [ids["Get Lucky"]]})
    assert added.status_code == 200
    item = added.json()["items"][0]
    assert item["added_by"]["display_name"] == "Lena"
    # Umbenennen bleibt dem Ersteller vorbehalten
    assert lib.client.patch(url, headers=child, json={"name": "Lenas Party"}).status_code == 403


def test_custom_cover_upload(lib: Library) -> None:
    playlist = _create(lib)
    url = f"/api/playlists/{playlist['id']}/cover"
    image = cover_bytes((0, 200, 0), fmt="PNG")
    uploaded = lib.client.put(url, headers=lib.headers, files={"file": ("cover.png", image)})
    assert uploaded.status_code == 200, uploaded.text
    cover_id = uploaded.json()["cover_id"]
    assert cover_id
    assert lib.client.get(f"/api/covers/{cover_id}", headers=lib.headers).status_code == 200
    # Ein Scan darf das Playlist-Cover nicht als "verwaist" löschen
    lib.scan()
    assert lib.client.get(f"/api/covers/{cover_id}", headers=lib.headers).status_code == 200

    bad = lib.client.put(url, headers=lib.headers, files={"file": ("x.png", b"kein bild")})
    assert bad.status_code == 400
    assert lib.client.delete(url, headers=lib.headers).json()["cover_id"] is None


def test_cover_upload_rejects_decompression_bomb(lib: Library) -> None:
    """Ein winziges PNG mit riesiger Auflösung wird abgelehnt, ohne es zu entpacken."""
    import io

    from PIL import Image

    buffer = io.BytesIO()
    Image.new("1", (9999, 9999)).save(buffer, "PNG")  # ca. 100 Megapixel, aber nur wenige KB
    playlist = _create(lib)
    response = lib.client.put(
        f"/api/playlists/{playlist['id']}/cover", headers=lib.headers, files={"file": ("x.png", buffer.getvalue())}
    )
    assert response.status_code == 400

def test_removed_files_disappear_from_playlists(lib: Library) -> None:
    ids = _ids(lib)
    playlist = _create(lib, track_ids=[ids["Get Lucky"], ids["Bohemian Rhapsody"]])
    (lib.settings.media_dir / lib.paths["opus"]).unlink()
    lib.scan()
    detail = lib.get(f"/api/playlists/{playlist['id']}")
    assert detail["track_count"] == 1
    assert [(i["track"]["title"], i["position"]) for i in detail["items"]] == [("Bohemian Rhapsody", 0)]


# -------------------------------------------------- Lieblingssongs & Bibliothek


def test_likes_and_library(lib: Library) -> None:
    ids = _ids(lib)
    for title in ("Bohemian Rhapsody", "Get Lucky"):
        assert lib.client.put(f"/api/me/likes/{ids[title]}", headers=lib.headers).status_code == 204
    # Doppelt liken schadet nicht
    assert lib.client.put(f"/api/me/likes/{ids['Get Lucky']}", headers=lib.headers).status_code == 204
    likes = lib.get("/api/me/likes")
    assert likes["total"] == 2
    assert likes["items"][0]["track"]["title"] == "Get Lucky"  # zuletzt geliked zuerst

    album_id = lib.track_by_title("Bohemian Rhapsody")["album"]["id"]
    artist_id = lib.track_by_title("Bohemian Rhapsody")["artists"][0]["id"]
    assert lib.client.put(f"/api/me/albums/{album_id}", headers=lib.headers).status_code == 204
    assert lib.client.put(f"/api/me/artists/{artist_id}", headers=lib.headers).status_code == 204

    saved = lib.get("/api/me/likes/ids")
    assert set(saved["tracks"]) == {ids["Bohemian Rhapsody"], ids["Get Lucky"]}
    assert saved["albums"] == [album_id] and saved["artists"] == [artist_id]

    library = lib.get("/api/me/library")
    assert library["liked_count"] == 2
    assert [a["title"] for a in library["albums"]] == ["A Night at the Opera"]
    assert [a["name"] for a in library["artists"]] == ["Queen"]

    assert lib.client.delete(f"/api/me/likes/{ids['Get Lucky']}", headers=lib.headers).status_code == 204
    assert lib.get("/api/me/likes")["total"] == 1
    assert lib.client.put("/api/me/likes/999999", headers=lib.headers).status_code == 404


def test_likes_are_per_user(lib: Library, make_user: Callable[..., dict]) -> None:
    ids = _ids(lib)
    lib.client.put(f"/api/me/likes/{ids['Get Lucky']}", headers=lib.headers)
    child = _child(lib, make_user)
    assert lib.client.get("/api/me/likes", headers=child).json()["total"] == 0


# ------------------------------------------------------- Verlauf & Startseite


def _play(lib: Library, track_id: int, seconds: float = 120, headers: dict[str, str] | None = None,
          context: tuple[str, int] | None = None) -> None:
    body: dict[str, object] = {"track_id": track_id, "seconds": seconds}
    if context:
        body["context_type"], body["context_id"] = context
    response = lib.client.post("/api/me/history", headers=headers or lib.headers, json=body)
    assert response.status_code == 204, response.text


def test_history_and_recent_contexts(lib: Library) -> None:
    track = lib.track_by_title("Bohemian Rhapsody")
    album_id = track["album"]["id"]
    playlist = _create(lib, name="Mix", track_ids=[track["id"]])
    _play(lib, track["id"], context=("album", album_id))
    _play(lib, track["id"], context=("album", album_id))
    _play(lib, lib.track_by_title("Get Lucky")["id"], context=("playlist", playlist["id"]))

    history = lib.get("/api/me/history")
    assert [h["track"]["title"] for h in history] == ["Get Lucky", "Bohemian Rhapsody"]  # Doppelte zusammengefasst
    recent = lib.get("/api/me/recent")
    assert [(c["type"], c["title"]) for c in recent] == [("playlist", "Mix"), ("album", "A Night at the Opera")]

    assert lib.client.delete("/api/me/history", headers=lib.headers).status_code == 204
    assert lib.get("/api/me/history") == []


def test_home_page(lib: Library, make_user: Callable[..., dict]) -> None:
    ids = _ids(lib)
    # Neuer Benutzer ohne Verlauf: trotzdem befüllte Startseite
    fresh = lib.get("/api/home")
    assert fresh["quick_access"], "Schnellzugriff soll mit neuen Alben aufgefüllt werden"
    assert "new_albums" in [s["key"] for s in fresh["sections"]]
    assert "videos" in [s["key"] for s in fresh["sections"]]

    lib.client.put(f"/api/me/likes/{ids['Get Lucky']}", headers=lib.headers)
    album_id = lib.track_by_title("Bohemian Rhapsody")["album"]["id"]
    for _ in range(3):
        _play(lib, ids["Bohemian Rhapsody"], context=("album", album_id))
    _play(lib, ids["Get Lucky"], seconds=5)  # zu kurz – zählt nicht für Top-Songs

    child = _child(lib, make_user)
    _play(lib, ids["Love of My Life"], headers=child)

    home = lib.get("/api/home")
    assert home["quick_access"][0]["type"] == "liked"
    sections = {s["key"]: s for s in home["sections"]}
    assert [c["title"] for c in sections["recent"]["contexts"]][:1] == ["A Night at the Opera"]
    assert [t["title"] for t in sections["top_tracks"]["tracks"]] == ["Bohemian Rhapsody"]
    assert {t["title"] for t in sections["family"]["tracks"]} == {"Bohemian Rhapsody", "Love of My Life"}
    assert [a["name"] for a in sections["artists"]["artists"]] == ["Queen"]
    assert any(c["id"] == "discover" for c in sections["mixes"]["contexts"])


def test_artist_top_tracks_follow_plays(lib: Library) -> None:
    ids = _ids(lib)
    queen = lib.track_by_title("Love of My Life")["artists"][0]["id"]
    for _ in range(2):
        _play(lib, ids["Love of My Life"])
    top = lib.get(f"/api/artists/{queen}")["top_tracks"]
    assert top[0]["title"] == "Love of My Life"


def test_mixes_and_radio(lib: Library) -> None:
    ids = _ids(lib)
    discover = lib.get("/api/mixes/discover")
    assert discover["title"] == "Entdecken"
    assert len(discover["tracks"]) == 5  # alle Audio-Titel, noch nichts gehört
    _play(lib, ids["Get Lucky"])
    assert "Get Lucky" not in [t["title"] for t in lib.get("/api/mixes/discover")["tracks"]]

    rock = lib.get("/api/mixes/genre:Rock")
    assert [t["title"] for t in rock["tracks"]] == ["Bohemian Rhapsody"]
    # Tagesmix bleibt über den Tag stabil
    assert lib.get("/api/mixes/discover")["tracks"] == lib.get("/api/mixes/discover")["tracks"]
    assert lib.client.get("/api/mixes/quatsch", headers=lib.headers).status_code == 404

    radio = lib.get(f"/api/tracks/{ids['Bohemian Rhapsody']}/radio")
    assert radio[0]["title"] == "Bohemian Rhapsody"
    assert "Love of My Life" in [t["title"] for t in radio]  # gleicher Künstler/Album
    assert all(t["media_type"] == "audio" for t in radio)
