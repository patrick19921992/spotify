"""Einfacher Schutz gegen Passwort-Raten: zählt Fehlversuche je Benutzername+IP und je IP.

Der Benutzer-Zähler gilt bewusst nur für die IP, von der die Fehlversuche kommen: Sonst könnte jeder aus
dem Internet ein Konto (z. B. "admin") mit zehn falschen Passwörtern dauerhaft für alle sperren.
"""

import threading
import time
from collections import deque


class LoginRateLimiter:
    def __init__(self, max_per_user: int, max_per_ip: int, window_seconds: int) -> None:
        self._max_per_user = max_per_user
        self._max_per_ip = max_per_ip
        self._window = window_seconds
        self._failures: dict[str, deque[float]] = {}
        self._lock = threading.Lock()

    def _recent(self, key: str, now: float) -> deque[float]:
        entries = self._failures.get(key)
        if entries is None:
            return deque()
        while entries and entries[0] <= now - self._window:
            entries.popleft()
        if not entries:
            del self._failures[key]
        return entries

    def retry_after(self, username: str, ip: str) -> int | None:
        """Sekunden bis zum nächsten erlaubten Versuch – oder None, wenn nicht gesperrt."""
        now = time.monotonic()
        waits: list[float] = []
        with self._lock:
            for key, limit in ((self._user_key(username, ip), self._max_per_user), (f"ip:{ip}", self._max_per_ip)):
                entries = self._recent(key, now)
                if len(entries) >= limit:
                    waits.append(entries[0] + self._window - now)
        if not waits:
            return None
        return max(1, int(max(waits)) + 1)

    def record_failure(self, username: str, ip: str) -> None:
        now = time.monotonic()
        with self._lock:
            for key in (self._user_key(username, ip), f"ip:{ip}"):
                self._recent(key, now)
                self._failures.setdefault(key, deque()).append(now)

    def reset_user(self, username: str, ip: str) -> None:
        with self._lock:
            self._failures.pop(self._user_key(username, ip), None)

    @staticmethod
    def _user_key(username: str, ip: str) -> str:
        return f"u:{username}|{ip}"
