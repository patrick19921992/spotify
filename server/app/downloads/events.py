"""Verteilt Download-Ereignisse aus den Worker-Threads an die verbundenen WebSockets (Live-Fortschritt)."""

import asyncio
import contextlib
import threading
from dataclasses import dataclass
from typing import Any


@dataclass(eq=False)
class Subscriber:
    loop: asyncio.AbstractEventLoop
    queue: asyncio.Queue[dict[str, Any]]
    user_id: int
    is_admin: bool


class EventHub:
    def __init__(self) -> None:
        self._subscribers: set[Subscriber] = set()
        self._lock = threading.Lock()

    def subscribe(self, user_id: int, is_admin: bool) -> Subscriber:
        subscriber = Subscriber(asyncio.get_running_loop(), asyncio.Queue(maxsize=500), user_id, is_admin)
        with self._lock:
            self._subscribers.add(subscriber)
        return subscriber

    def unsubscribe(self, subscriber: Subscriber) -> None:
        with self._lock:
            self._subscribers.discard(subscriber)

    @property
    def count(self) -> int:
        with self._lock:
            return len(self._subscribers)

    def publish(self, event: dict[str, Any], owner_id: int | None) -> None:
        """Thread-sicher: jeder Benutzer sieht seine eigenen Downloads, Admins alle."""
        with self._lock:
            targets = [s for s in self._subscribers if s.is_admin or s.user_id == owner_id]
        for subscriber in targets:
            try:
                subscriber.loop.call_soon_threadsafe(_offer, subscriber.queue, event)
            except RuntimeError:  # Event-Loop bereits beendet
                self.unsubscribe(subscriber)


def _offer(queue: asyncio.Queue[dict[str, Any]], event: dict[str, Any]) -> None:
    if queue.full():  # langsamer Empfänger: ältestes Ereignis verwerfen
        with contextlib.suppress(asyncio.QueueEmpty):
            queue.get_nowait()
    queue.put_nowait(event)
