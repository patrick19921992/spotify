# Abschließende Prüfung – Fortschritt

Unabhängige Prüfung des ganzen Projekts in sieben Bereichen. Jeder Fund wird vor dem Beheben im Code
nachvollzogen und bekommt einen Test, der ohne die Korrektur fehlschlägt.

Stand: 14.10.2026

## Bereiche

| Bereich | Prüfung | Funde | Behoben |
|---|---|---|---|
| Server-Sicherheit | ✅ fertig | 6 | 6 |
| Server-Logik | ✅ fertig | 11 | 0 |
| Schnittstelle App ↔ Server | ✅ fertig | 6 | 0 |
| Docker, Unraid, CI, Anleitung | ✅ fertig | 7 | 0 |
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

## Server-Logik – offen

- [ ] **kritisch** – Fehlender/nicht eingehängter Rubrik-Ordner löscht beim Scan alle Titel samt Playlists,
      Likes und Verlauf (`server/app/library/scanner.py:224`)
- [ ] **hoch** – Scanner hält die SQLite-Schreibsperre über langsame Dateizugriffe: API-Fehler 500,
      Download-Worker sterben (`scanner.py:265`)
- [ ] mittel – Neu-Nummerierung nach Entfernen von Titeln verwürfelt Playlist-Reihenfolge
      (`services/playlists.py:238`)
- [ ] mittel – Jeder laufende Stream/Cover hält eine DB-Verbindung bis zum letzten Byte: 15 Streams
      blockieren die API (`routers/media.py:75`)
- [ ] mittel – Später hinzugefügtes `cover.jpg`/`folder.jpg` wird nie übernommen (`scanner.py:243`)
- [ ] mittel – Songs aus YouTube-Links (ohne thumbnail_url) bekommen kein Cover (`downloads/ytdlp.py:66`)
- [ ] mittel – Container-Neustart markiert laufende Downloads als „abgebrochen“ statt sie neu einzureihen
      (`downloads/manager.py:341`)
- [ ] mittel – WMA wird ungewandelt an Android geschickt, dort nicht abspielbar (`library/transcode.py:222`)
- [ ] niedrig – Abbrechen während der Verarbeitung wird ignoriert (`manager.py:224`)
- [ ] niedrig – Gleichzeitiges Aufräumen des Umwandlungs-Speichers kann Stream mit 500 abbrechen
      (`transcode.py:281`)
- [ ] niedrig – Selbst aktualisiertes yt-dlp bleibt aktiv, auch wenn YTDL_AUTO_UPDATE=false (`ytdlp.py:52`)

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

## Docker, Unraid, CI, Anleitung – offen

- [ ] **hoch** – Weg B: Schon der erste Lauf startet den Container, das Admin-Passwort aus dem Log geht
      beim dokumentierten zweiten Lauf verloren (`unraid/selfify-update.sh:39`)
- [ ] mittel – PUID=0 lässt das Startskript endlos neu starten (`server/entrypoint.sh:10`)
- [ ] mittel – Anleitung zum Reverse Proxy erwähnt keine Zeitlimits (lange Umwandlungen/Aufrufe)
      (`README.md:87`)
- [ ] niedrig – Alte yt-dlp-Kopie in /data überdeckt neuere im Image (`ytdlp.py:52`, wie oben)
- [ ] niedrig – iOS: `NSAllowsLocalNetworking` hebt `NSAllowsArbitraryLoads` auf, http im Heimnetz
      per Hostname blockiert (`mobile/ios/Runner/Info.plist:79`)
- [ ] niedrig – README: „best“ verspricht 4K, YTDL_VIDEO_MAX_HEIGHT begrenzt aber auf 1080 (`README.md:247`)
- [ ] niedrig – README: Konsolen-Befehle funktionieren so nicht in „Container-Symbol → Console“
      (`README.md:303`)

## Weitermachen nach einer Unterbrechung

- Fertige Prüfbereiche werden nicht wiederholt: Der Prüf-Durchlauf (`wf_bbbf3d22-7ca`) lässt sich
  fortsetzen, abgeschlossene Prüfer liefern ihr gespeichertes Ergebnis sofort.
- Die vollständigen Funde (mit Nachweis und Lösungsvorschlag) liegen zusätzlich im Arbeitsordner der
  Sitzung unter `pruefung/ergebnisse.json`.
- Reihenfolge beim Beheben: kritisch → hoch → mittel → niedrig; nach jedem Block testen, committen, pushen
  und diese Liste abhaken.
