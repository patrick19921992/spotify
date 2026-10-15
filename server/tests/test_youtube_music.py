"""YouTube-Music-Suche mit der echten ytmusicapi-Auswertung (nur die Antwort von YouTube ist nachgestellt)."""

from typing import Any

import pytest
from ytmusicapi import YTMusic

from app.config import Settings
from app.downloads.youtube import YouTubeMusic

# Überschrift der Trefferliste – YouTube liefert sie in der Sprache der Anfrage
SHELF_TITLE = {"en": "Songs", "de": "Titel"}


def _browse(browse_id: str, page_type: str) -> dict[str, Any]:
    return {
        "browseEndpoint": {
            "browseId": browse_id,
            "browseEndpointContextSupportedConfigs": {"browseEndpointContextMusicConfig": {"pageType": page_type}},
        }
    }


def _song(video_id: str, title: str, artist: str, album: str, album_id: str, duration: str) -> dict[str, Any]:
    artist_page = _browse("UCartist0000", "MUSIC_PAGE_TYPE_ARTIST")
    return {
        "musicResponsiveListItemRenderer": {
            "flexColumns": [
                {"musicResponsiveListItemFlexColumnRenderer": {"text": {"runs": [{"text": title}]}}},
                {
                    "musicResponsiveListItemFlexColumnRenderer": {
                        "text": {
                            "runs": [
                                {"text": artist, "navigationEndpoint": artist_page},
                                {"text": " • "},
                                {"text": album, "navigationEndpoint": _browse(album_id, "MUSIC_PAGE_TYPE_ALBUM")},
                                {"text": " • "},
                                {"text": duration},
                            ]
                        }
                    }
                },
            ],
            "overlay": {
                "musicItemThumbnailOverlayRenderer": {
                    "content": {
                        "musicPlayButtonRenderer": {
                            "playNavigationEndpoint": {
                                "watchEndpoint": {
                                    "videoId": video_id,
                                    "watchEndpointMusicSupportedConfigs": {
                                        "watchEndpointMusicConfig": {"musicVideoType": "MUSIC_VIDEO_TYPE_ATV"}
                                    },
                                }
                            }
                        }
                    }
                }
            },
            "thumbnail": {
                "musicThumbnailRenderer": {
                    "thumbnail": {
                        "thumbnails": [{"url": "https://lh3.googleusercontent.com/cover=w120-h120", "width": 120}]
                    }
                }
            },
        }
    }


@pytest.fixture
def youtube_answers(monkeypatch: pytest.MonkeyPatch) -> list[str]:
    """Beantwortet Suchanfragen wie YouTube Music – Überschrift in der Sprache des Clients."""
    languages: list[str] = []

    def send_request(self: YTMusic, endpoint: str, body: dict[str, Any], additionalParams: str = "") -> dict:
        languages.append(self.language)
        shelf = {
            "musicShelfRenderer": {
                "title": {"runs": [{"text": SHELF_TITLE.get(self.language, "?")}]},
                "contents": [
                    _song("gGdGFtwCNBE", "Mr. Brightside", "The Killers", "Hot Fuss", "MPREb_hotfuss01", "3:43"),
                    _song("Vs0TEUcUl5A", "Somebody Told Me", "The Killers", "Hot Fuss", "MPREb_hotfuss01", "3:17"),
                ],
            }
        }
        tabs = [{"tabRenderer": {"content": {"sectionListRenderer": {"contents": [shelf]}}}}]
        return {"contents": {"tabbedSearchResultsRenderer": {"tabs": tabs}}}

    monkeypatch.setattr(YTMusic, "_send_request", send_request)
    return languages


def test_search_with_default_settings_finds_songs(youtube_answers: list[str]) -> None:
    """ytmusicapi verwirft Trefferlisten, deren Überschrift nicht zum (englischen) Filternamen passt.

    Mit deutscher Oberfläche ("Titel", "Alben") fand die Suche deshalb nichts. Die Standard-Einstellung
    fragt YouTube Music daher auf Englisch an (das Land bleibt Deutschland).
    """
    defaults = Settings.model_fields
    youtube = YouTubeMusic(defaults["ytmusic_language"].default, defaults["ytmusic_location"].default)

    items = youtube.search("Mr. Brightside", "songs", 5)

    assert youtube_answers == ["en"]
    assert [(i.title, i.artists, i.video_id) for i in items] == [
        ("Mr. Brightside", ["The Killers"], "gGdGFtwCNBE"),
        ("Somebody Told Me", ["The Killers"], "Vs0TEUcUl5A"),
    ]
    first = items[0]
    assert (first.album, first.album_browse_id, first.duration) == ("Hot Fuss", "MPREb_hotfuss01", 223)
    assert first.thumbnail_url is not None
