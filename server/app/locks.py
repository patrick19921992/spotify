"""Prozessweite Sperre für kurze „Prüfen, dann schreiben“-Abläufe.

SQLite lässt mehrere Anfragen gleichzeitig lesen. Prüft eine Anfrage etwas („schon eingelöst?“, „letzter Admin?“,
„Limit erreicht?“) und schreibt danach, kann eine zweite Anfrage dazwischenkommen und denselben alten Stand sehen.
Wer so einen Ablauf hat, hält diese Sperre von der Prüfung bis zum `commit()` – der Server läuft als ein Prozess.
Zusätzlich schützen Eindeutigkeits-Regeln in der Datenbank dort, wo es sie gibt.
"""

import threading

write_lock = threading.Lock()
