"""Normalisierung für Suche, Sortierung und Zuordnung (z. B. "Die Ärzte" == "die aerzte")."""

import re
import unicodedata

_UMLAUTS = str.maketrans({"ä": "ae", "ö": "oe", "ü": "ue", "ß": "ss"})
_NON_ALNUM = re.compile(r"[^0-9a-z]+")
_SORT_ARTICLES = re.compile(r"^(the|die|der|das|a|an)\s+", re.IGNORECASE)


def _fold(value: str) -> str:
    """Kleinbuchstaben, Akzente entfernen (ö -> o), Sonderzeichen -> Leerzeichen."""
    value = unicodedata.normalize("NFKD", value.casefold())
    value = "".join(ch for ch in value if not unicodedata.combining(ch))
    return _NON_ALNUM.sub(" ", value).strip()


def match_key(value: str) -> str:
    """Schlüssel zum Zusammenführen gleicher Künstler/Alben."""
    return _fold(value)[:255]


def sort_key(value: str) -> str:
    """Sortiert "The Beatles" unter B – wie bei Spotify."""
    return _fold(_SORT_ARTICLES.sub("", value.strip()) or value)[:255]


def search_text(*parts: str | None, limit: int = 1500) -> str:
    """Suchtext mit beiden Schreibweisen: "hoerspiele" und "horspiele" finden "Hörspiele"."""
    words: list[str] = []
    for part in parts:
        if not part:
            continue
        for variant in (_fold(part), _fold(part.casefold().translate(_UMLAUTS))):
            if variant and variant not in words:
                words.append(variant)
    return " ".join(words)[:limit]


def search_terms(query: str) -> list[str]:
    """Zerlegt eine Suchanfrage in normalisierte Wörter."""
    terms: list[str] = []
    for term in _fold(query).split():
        if term not in terms:
            terms.append(term)
    return terms[:8]
