"""Passwörter (Argon2), Zugriffstoken (JWT) und Refresh-Token."""

import hashlib
import logging
import os
import secrets
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

import jwt
from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError, VerifyMismatchError

logger = logging.getLogger(__name__)

JWT_ALGORITHM = "HS256"
JWT_ISSUER = "selfify"

_hasher = PasswordHasher()
# Wird geprüft, wenn ein Benutzer nicht existiert – gleiche Antwortzeit, kein Ausspähen von Namen
_DUMMY_HASH = _hasher.hash("selfify-dummy-password")


def hash_password(password: str) -> str:
    return _hasher.hash(password)


def verify_password(password_hash: str | None, password: str) -> bool:
    try:
        return _hasher.verify(password_hash or _DUMMY_HASH, password) and password_hash is not None
    except (VerifyMismatchError, VerificationError, InvalidHashError):
        return False


def password_needs_rehash(password_hash: str) -> bool:
    return _hasher.check_needs_rehash(password_hash)


def generate_password(length: int = 16) -> str:
    alphabet = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    return "".join(secrets.choice(alphabet) for _ in range(length))


def load_or_create_secret_key(configured: str, data_dir: Path) -> str:
    """Nimmt SECRET_KEY aus der Umgebung oder legt ihn einmalig in data_dir/secret.key an."""
    if configured:
        return configured
    key_file = data_dir / "secret.key"
    if key_file.exists():
        return key_file.read_text(encoding="utf-8").strip()
    key = secrets.token_urlsafe(64)
    key_file.write_text(key, encoding="utf-8")
    os.chmod(key_file, 0o600)
    logger.info("Neuer geheimer Schlüssel erzeugt: %s", key_file)
    return key


def create_access_token(secret: str, user_id: int, session_id: int, minutes: int) -> str:
    now = datetime.now(UTC)
    payload = {
        "iss": JWT_ISSUER,
        "sub": str(user_id),
        "sid": session_id,
        "type": "access",
        "iat": now,
        "exp": now + timedelta(minutes=minutes),
    }
    return jwt.encode(payload, secret, algorithm=JWT_ALGORITHM)


def decode_access_token(secret: str, token: str) -> dict[str, Any] | None:
    try:
        payload = jwt.decode(
            token,
            secret,
            algorithms=[JWT_ALGORITHM],
            issuer=JWT_ISSUER,
            options={"require": ["exp", "iat", "sub", "sid", "type"]},
        )
    except jwt.PyJWTError:
        return None
    if payload.get("type") != "access":
        return None
    return payload


def new_refresh_token() -> str:
    return secrets.token_urlsafe(48)


def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()
