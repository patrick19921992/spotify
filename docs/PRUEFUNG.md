# Abschließende Prüfung – Fortschritt

Unabhängige Prüfung des ganzen Projekts in sieben Bereichen. Jeder Fund wird vor dem Beheben im Code
nachvollzogen und bekommt einen Test, der ohne die Korrektur fehlschlägt.

Stand: 15.10.2026

## Bereiche

| Bereich | Prüfung | Funde | Behoben |
|---|---|---|---|
| Server-Sicherheit | ✅ fertig | 6 | 6 |
| Server-Logik | ✅ fertig | 11 | 11 |
| Schnittstelle App ↔ Server | ✅ fertig | 6 | 0 |
| Docker, Unraid, CI, Anleitung | ✅ fertig | 7 | 7 |
| App-Kern (Player, Offline, Downloads, Anmeldung) | ⏳ läuft | – | – |
| App-Bildschirme Teil A (Start, Suche, Bibliothek, Details) | ⏳ läuft | – | – |
| App-Bildschirme Teil B (Player, Downloads, Konto, Verwaltung) | ⏳ läuft | – | – |

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

## Schnittstelle App ↔ Server – offen

- [ ] mittel – Token-Erneuerung kann die Fehler-Warteschlange von dio blockieren: Anfragen hängen für immer
      (`mobile/lib/data/api.dart:144`)
- [ ] mittel – Gespeicherte Ziel-Rubrik wird ungeprüft gesendet: alle Downloads scheitern mit
      „Rubrik nicht gefunden“ (`mobile/lib/state/downloads.dart:168`)
- [ ] niedrig – Fertig-Meldungen enden nach Abmelden→Anmelden (`downloads.dart:67`)
- [ ] niedrig – Download-Knopf verwechselt Song und Video mit gleicher YouTube-ID (`downloads.dart:36`)
- [ ] niedrig – Verlorene Antwort bei Token-Erneuerung + über 60 s offline meldet das Gerät ab
      (`server/app/services/auth.py:94`)
- [ ] niedrig – Medien-Token läuft nach 7 Tagen ab, eingereihte Titel spielen dann nicht mehr
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

## Sonstiges

- [x] Android-Build: NDK-Download brach ab (CI rot bei 93f6c7c) → eigener Schritt mit 3 Versuchen

## Weitermachen nach einer Unterbrechung

- Fertige Prüfbereiche werden nicht wiederholt: Der Prüf-Durchlauf (`wf_bbbf3d22-7ca`) lässt sich
  fortsetzen, abgeschlossene Prüfer liefern ihr gespeichertes Ergebnis sofort.
- Die vollständigen Funde (mit Nachweis und Lösungsvorschlag) liegen zusätzlich im Arbeitsordner der
  Sitzung unter `pruefung/ergebnisse.json`.
- Reihenfolge beim Beheben: kritisch → hoch → mittel → niedrig; nach jedem Block testen, committen, pushen
  und diese Liste abhaken.
