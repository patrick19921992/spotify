# Abschließende Prüfung – Fortschritt

Unabhängige Prüfung des ganzen Projekts in sieben Bereichen. Jeder Fund wird vor dem Beheben im Code
nachvollzogen und bekommt einen Test, der ohne die Korrektur fehlschlägt.

Stand: 15.10.2026 (PR #1 ist zusammengeführt, App-Kern und Teil B kommen in PR #2)

## Bereiche

| Bereich | Prüfung | Funde | Behoben |
|---|---|---|---|
| Server-Sicherheit | ✅ fertig | 6 | 6 |
| Server-Logik | ✅ fertig | 11 | 11 |
| Schnittstelle App ↔ Server | ✅ fertig | 6 | 6 |
| Docker, Unraid, CI, Anleitung | ✅ fertig | 7 | 7 |
| App-Kern (Player, Offline, Downloads, Anmeldung) | ✅ fertig | 9 | 9 |
| App-Bildschirme Teil A (Start, Suche, Bibliothek, Details) | ✅ fertig | 5 | 5 |
| App-Bildschirme Teil B (Player, Downloads, Konto, Verwaltung) | ✅ fertig | 5 | 5 |

## Server-Sicherheit – alle behoben (Commit 19f3d3c)

- [x] Fremde konnten jedes Konto mit 10 falschen Passwörtern aussperren → Sperre je Benutzer **und** IP
- [x] Präpariertes Cover-Bild (100 Megapixel, wenige KB) fror den Server ein → Hilfs-Thread, Größengrenze
- [x] Lange japanische/Emoji-Titel: Dateiname über 255 Byte, Download scheiterte → Kürzen nach Bytes
- [x] Gleicher Song für zwei Familienmitglieder: zweiter bekam fremden Auftrag, Playlist ging verloren
- [x] Downloads überschrieben gleichnamige `.lrc`/`.jpg`, Löschen entfernte fremde Begleitdateien
- [x] Live-Verbindung blieb nach Sperre/Abmeldung/Entzug der Admin-Rechte offen

## Server-Logik – alle behoben

- [x] **kritisch** – Fehlender/nicht eingehängter Rubrik-Ordner löscht beim Scan alle Titel samt Playlists,
      Likes und Verlauf (`server/app/library/scanner.py:224`)
- [x] **hoch** – Scanner hält die SQLite-Schreibsperre über langsame Dateizugriffe: API-Fehler 500,
      Download-Worker sterben (`scanner.py:265`)
- [x] mittel – Neu-Nummerierung nach Entfernen von Titeln verwürfelt Playlist-Reihenfolge
      (`services/playlists.py:238`)
- [x] mittel – Jeder laufende Stream/Cover hält eine DB-Verbindung bis zum letzten Byte: 15 Streams
      blockieren die API (`routers/media.py:75`)
- [x] mittel – Später hinzugefügtes `cover.jpg`/`folder.jpg` wird nie übernommen (`scanner.py:243`)
- [x] mittel – Songs aus YouTube-Links (ohne thumbnail_url) bekommen kein Cover (`downloads/ytdlp.py:66`)
- [x] mittel – Container-Neustart markiert laufende Downloads als „abgebrochen“ statt sie neu einzureihen
      (`downloads/manager.py:341`)
- [x] mittel – WMA wird ungewandelt an Android geschickt, dort nicht abspielbar (`library/transcode.py:222`)
- [x] niedrig – Abbrechen während der Verarbeitung wird ignoriert (`manager.py:224`)
- [x] niedrig – Gleichzeitiges Aufräumen des Umwandlungs-Speichers kann Stream mit 500 abbrechen
      (`transcode.py:281`)
- [x] niedrig – Selbst aktualisiertes yt-dlp bleibt aktiv, auch wenn YTDL_AUTO_UPDATE=false (`ytdlp.py:52`)

## Schnittstelle App ↔ Server – alle behoben

- [x] mittel – Token-Erneuerung kann die Fehler-Warteschlange von dio blockieren: Anfragen hängen für immer
      (`mobile/lib/data/api.dart:144`)
- [x] mittel – Gespeicherte Ziel-Rubrik wird ungeprüft gesendet: alle Downloads scheitern mit
      „Rubrik nicht gefunden“ (`mobile/lib/state/downloads.dart:168`)
- [x] niedrig – Fertig-Meldungen enden nach Abmelden→Anmelden (`downloads.dart:67`)
- [x] niedrig – Download-Knopf verwechselt Song und Video mit gleicher YouTube-ID (`downloads.dart:36`)
- [x] niedrig – Verlorene Antwort bei Token-Erneuerung + über 60 s offline meldet das Gerät ab
      (`server/app/services/auth.py:94`)
- [x] niedrig – Medien-Token läuft nach 7 Tagen ab, eingereihte Titel spielen dann nicht mehr
      (`mobile/lib/player/audio_handler.dart:202`)

## Docker, Unraid, CI, Anleitung – alle behoben

- [x] **hoch** – Weg B: Schon der erste Lauf startet den Container, das Admin-Passwort aus dem Log geht
      beim dokumentierten zweiten Lauf verloren (`unraid/selfify-update.sh:39`)
- [x] mittel – PUID=0 lässt das Startskript endlos neu starten (`server/entrypoint.sh:10`)
- [x] mittel – Anleitung zum Reverse Proxy erwähnt keine Zeitlimits (lange Umwandlungen/Aufrufe)
      (`README.md:87`) – Anleitung ergänzt, App wartet bei Offline-Downloads bis 15 Min.
- [x] niedrig – Alte yt-dlp-Kopie in /data überdeckt neuere im Image (`ytdlp.py:52`, wie oben)
- [x] niedrig – iOS: `NSAllowsLocalNetworking` hebt `NSAllowsArbitraryLoads` auf, http im Heimnetz
      per Hostname blockiert (`mobile/ios/Runner/Info.plist:79`)
- [x] niedrig – README: „best“ verspricht 4K, YTDL_VIDEO_MAX_HEIGHT begrenzt aber auf 1080 (`README.md:247`)
- [x] niedrig – README: Konsolen-Befehle funktionieren so nicht in „Container-Symbol → Console“
      (`README.md:303`)

## App-Bildschirme Teil A – alle behoben

- [x] **hoch** – Admin: „Datei vom Server löschen“ im Song-Menü löscht nie und zeigt einen Fehler
      (`mobile/lib/ui/widgets/track_menu.dart:145`)
- [x] mittel – „Zu Playlist hinzufügen“ meldet einen Fehler, wenn der Server länger als 200 ms braucht
      (`mobile/lib/ui/widgets/playlist_picker.dart:58`)
- [x] niedrig – Playlist mit doppeltem Song: Tippen auf die zweite Kopie spielt ab der ersten
      (`mobile/lib/ui/widgets/track_tile.dart:47`)
- [x] niedrig – Kurz vor „Fertig“ hinzugefügte Songs fehlen auf der Playlist-Seite
      (`mobile/lib/ui/screens/library_playlist_sheets.dart:253`)
- [x] niedrig – Knopfleiste auf der Künstlerseite läuft bei großer Schrift über
      (`mobile/lib/ui/screens/artist_screen.dart:268`) – dazu neuer Test „kleines Handy mit großer Schrift“
      für alle Bildschirme; er fand drei weitere Überläufe (Geräte, Rubrik, leere Listen), alle behoben

## App-Kern – alle behoben

- [x] **hoch** – Zufallswiedergabe: „Als Nächstes spielen“, „Zur Warteschlange“ und Autoplay landen an
      zufälligen Stellen, oft vor dem aktuellen Song – sie werden dann nie gespielt (`audio_handler.dart:254`)
      – eigene Zufallsreihenfolge (`player/queue_shuffle_order.dart`)
- [x] mittel – Knopf „Zufallswiedergabe“ startet immer mit dem ersten Titel (`audio_handler.dart:236`)
- [x] mittel – Wechsel von WLAN zu mobilen Daten stellt die Warteschlange nicht auf die Mobil-Qualität um
      (`player.dart:26`) – kommende Titel bekommen neue Links, der laufende spielt ohne Unterbrechung weiter
- [x] mittel – Offline-Modus: Autoplay/Radio streamt trotzdem nicht heruntergeladene Songs (`player.dart:53`)
- [x] mittel – Download-Liste: Aktualisieren überschreibt neuere Live-Meldungen (fertiger Download steht
      ewig auf „lädt“), Fertig-Meldungen während Verbindungsabbruch gehen verloren (`downloads.dart:92`)
- [x] niedrig – Offline-Warteschlange läuft nach dem Neustart nicht weiter, wenn die Anmeldung später geladen
      wird (`offline.dart:294`)
- [x] niedrig – Entfernen eines Songs, der gerade aufs Handy lädt, speichert ihn trotzdem (`offline.dart:252`)
- [x] niedrig – Schlaf-Timer „Ende des Titels“ beim letzten Song: Play-Knopf reagiert danach nicht
      (`audio_handler.dart:184`)
- [x] niedrig – Autoplay hört nach einer Runde auf, wenn es per „Weiter“ im Pausenzustand ausgelöst wurde
      (`audio_handler.dart:199`)

Tests: `player_queue_test.dart` (nachgebautes just_audio), `downloads_refresh_test.dart` (echter WebSocket),
`offline_queue_test.dart` (echtes Dateisystem) – jeder schlägt ohne die Korrektur fehl.

## App-Bildschirme Teil B – alle behoben

- [x] **hoch** – Rubrik löschen entfernt die Titel aus allen Playlists, Lieblingssongs und Verläufen der
      Familie, die Abfrage behauptet aber, es gehe nichts verloren (`mobile/lib/ui/screens/admin_categories.dart:17`)
      – Abfrage nennt jetzt die Folgen, bei Rubriken mit Titeln muss der Name eingetippt werden.
      Offen als Vorschlag: Rubrik am Server nur ausblenden statt löschen (Daten blieben erhalten)
- [x] mittel – Warteschlange: Wischt man eine von zwei direkt aufeinanderfolgenden Kopien desselben Songs weg,
      verschwindet die andere unsichtbar mit (`mobile/lib/ui/screens/queue_screen.dart:49`)
- [x] mittel – Verwaltung „Alle“ Downloads: Für ein anderes Familienmitglied wiederholter/abgebrochener Auftrag
      friert ein und zählt beim Admin als „läuft“ (`mobile/lib/ui/screens/downloads_screen.dart:144`)
- [x] niedrig – Mini-Player-Herz: Fehler beim Liken (z. B. offline) werden verschluckt
      (`mobile/lib/ui/widgets/mini_player.dart:58`)
- [x] niedrig – Verwaltung: „Alle Downloads ansehen“ öffnet nur die eigenen (`admin_downloader.dart:118`)

Tests: `player_screens_test.dart`, `admin_screens_test.dart` – jeder schlägt ohne die Korrektur fehl.

## Sonstiges

- [x] Android-Build: NDK-Download brach ab (CI rot bei 93f6c7c) → eigener Schritt mit 3 Versuchen
- [x] „Stoppen“ direkt nach dem Start eines Downloads ging verloren (Abbruch-Signal entstand erst nach der
      Vorbereitung; CI rot bei 0a0374a) → Signal wird schon beim Übernehmen angelegt (`downloads/manager.py`)

## Abschlussprüfung von PR #2

- [ ] Unabhängige Gegenprüfung des ganzen PR-Stands auf Rückschritte (Workflow `wf_e930ef2d-137`) – ist
      ohne Ergebnis abgebrochen; PR #2 ist inzwischen gemergt. Bei Bedarf neu starten.

## Gegenprüfung von PR #4 (Anmelde-Diagnose + Update-Hinweis)

Workflow `wf_0cfa73a2-740`: 11 Funde, 10 bestätigt (der Desugaring-Fund war schon behoben).

- [x] hoch – Android-Build scheiterte: ota_update braucht Core Library Desugaring (`build.gradle.kts`)
- [x] mittel – „Abbrechen“/Zurück stoppte den Download nicht, der Installer ging später trotzdem auf
      → Abbrechen ruft jetzt `OtaUpdate().cancel()` (`state/app_update.dart`)
- [x] mittel – ota_update 7.1.0 vertauscht „läuft schon“ und „Installationsfehler“ zwischen Java und Dart:
      Die App riet fälschlich zum Deinstallieren (Offline-Musik weg) → beide heißen jetzt „läuft schon“
- [x] mittel – Gemerkte Prüfsumme veraltet, sobald auf main neu gebaut wurde („Datei beschädigt“ in
      Dauerschleife) → vor jedem Installieren und bei „Erneut versuchen“ wird `version.json` neu geholt
- [x] mittel – Hinweis-Banner auf schmalen Handys/großer Schrift zerquetscht → Knöpfe in eigener Zeile
- [x] niedrig/mittel – Ohne Signaturschlüssel wurden Updates angeboten, die Android ablehnen muss → CI
      veröffentlicht `version.json` (und baut die Update-Adresse ein) nur noch mit festem Schlüssel
- [x] niedrig – Einstellungen meldeten „neueste Version“, obwohl die Prüfung scheiterte (offline)
- [x] niedrig – `https://` auf einen reinen HTTP-Port wurde als Zertifikatsfehler gemeldet → Hinweis auf
      `http://` (`data/api.dart`)
- [x] niedrig – Update-Hinweis fehlte auf dem Anmeldebildschirm → dort jetzt ebenfalls
- [x] zusätzlich – Doppeltipp auf „Installieren“ öffnete zwei Dialoge (störte den laufenden Download)

Tests: `app_update_test.dart` (u. a. mit nachgebildeter Android-Seite des Plugins), `server_probe_test.dart`.

## Weitermachen nach einer Unterbrechung

- Fertige Prüfbereiche werden nicht wiederholt: Der Prüf-Durchlauf (`wf_bbbf3d22-7ca`) lässt sich
  fortsetzen, abgeschlossene Prüfer liefern ihr gespeichertes Ergebnis sofort.
- Die vollständigen Funde (mit Nachweis und Lösungsvorschlag) liegen zusätzlich im Arbeitsordner der
  Sitzung unter `pruefung/ergebnisse.json`.
- Reihenfolge beim Beheben: kritisch → hoch → mittel → niedrig; nach jedem Block testen, committen, pushen
  und diese Liste abhaken.
