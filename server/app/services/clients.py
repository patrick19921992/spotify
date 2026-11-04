"""Welche App meldet sich? Die App schickt bei jeder Anfrage den Header
`X-Selfify-Client: platform=android; channel=play; version=1.0.0; build=54`.

Das Dashboard zeigt daraus, welche App-Versionen im Umlauf sind (z. B. wer noch ein altes Update braucht).
"""

import re
from dataclasses import dataclass

from app.models import UserSession

CLIENT_HEADER = "X-Selfify-Client"

_PLATFORM = re.compile(r"^[a-z]{2,20}$")
_CHANNEL = re.compile(r"^[a-z]{2,10}$")
_VERSION = re.compile(r"^[0-9A-Za-z.+-]{1,32}$")


@dataclass(frozen=True)
class ClientInfo:
    platform: str
    channel: str
    version: str
    build: int | None


def parse_client(value: str | None) -> ClientInfo | None:
    """Liest den Header. Alles Unklare wird ignoriert – der Header ist nur eine Anzeige, keine Sicherheit."""
    if not value or len(value) > 200:
        return None
    parts: dict[str, str] = {}
    for chunk in value.split(";"):
        key, _, text = chunk.partition("=")
        if key.strip() and text.strip():
            parts[key.strip().lower()] = text.strip()
    platform, channel, version = parts.get("platform", ""), parts.get("channel", ""), parts.get("version", "")
    if not _PLATFORM.match(platform) or not _CHANNEL.match(channel) or not _VERSION.match(version):
        return None
    build_text = parts.get("build", "")
    # Nur ASCII-Ziffern: str.isdigit() ließe auch „²“ durch, und int() würde daran scheitern (500 statt „ignoriert“)
    build = int(build_text) if re.fullmatch(r"[0-9]{1,9}", build_text) else None
    return ClientInfo(platform=platform, channel=channel, version=version, build=build)


def apply_client(session: UserSession, client: ClientInfo | None) -> bool:
    """Merkt sich die gemeldete Version am Gerät. True, wenn sich etwas geändert hat."""
    if client is None:
        return False
    current = (session.client_platform, session.client_channel, session.client_version, session.client_build)
    if current == (client.platform, client.channel, client.version, client.build):
        return False
    session.client_platform = client.platform
    session.client_channel = client.channel
    session.client_version = client.version
    session.client_build = client.build
    return True
