# Roadmap – Spotify nachbauen, nur mit eigenen Downloads

Vorbild ist die echte Spotify-App mit ihrem Aufbau, ihren Funktionen und ihrem Bedienkonzept. Der
Unterschied: Statt eines Musikkatalogs aus der Cloud gibt es die eigene Bibliothek auf dem Unraid. Fehlt
ein Song, wird er von YouTube (Music) heruntergeladen. Ein eigenes Logo und ein eigener Name ersetzen
die Spotify-Marke.

Jeder Schritt endet mit einer Pause, einer Zusammenfassung und deiner Freigabe.

---

## Schritt 1 – Server-Grundgerüst ✅

- [x] Docker-Container für Unraid (läuft als `nobody:users`, 99:100)
- [x] SQLite-Datenbank mit automatischen Migrationen
- [x] Mehrere Accounts, Login, angemeldete Geräte, Abmelden aus der Ferne
- [x] Admin-Bereich: Benutzer anlegen, sperren, Passwort zurücksetzen, Download-Recht je Person
- [x] Schutz gegen Passwort-Raten (wichtig wegen Zugriff über eine Domain)
- [x] **Rubriken mit eigenen Ordnern** (Musik, Musikvideos, Hörspiele & Hörbücher, Videos, weitere frei anlegbar)
- [x] Konsolen-Befehle (Passwort zurücksetzen, Benutzer anlegen)

## Schritt 2 – Bibliothek & Streaming ✅

- [x] Scanner liest alle Rubrik-Ordner: Titel, Künstler, Album, Jahr, Genre, Tracknummer, Dauer, Qualität, Cover
- [x] Fehlende Tags werden aus Ordner-/Dateinamen ergänzt, „feat.“-Künstler getrennt erkannt
- [x] Erkennt neue, geänderte und gelöschte Dateien automatisch (Live-Überwachung + Scan alle 30 Min.)
- [x] Künstler- (beliebte Titel, Alben, „Enthalten auf“, Videos), Album-, Song- und Video-Ansichten
- [x] Streaming mit Spulen (HTTP-Range), Cover in mehreren Größen + Hauptfarbe für Farbverläufe
- [x] Umwandlung Opus/Ogg → AAC fürs iPhone und **Datensparmodus** (mit Zwischenspeicher)
- [x] Suche in der eigenen Bibliothek mit Top-Treffer (Umlaute egal: „Ärzte“ = „aerzte“)
- [x] Stream-Links mit eigenem Medien-Token (Player-Warteschlangen laufen auch nach 30 Minuten weiter)

## Schritt 3 – Playlists & persönliche Daten ✅

- [x] Playlists erstellen, umbenennen, Beschreibung, eigenes Cover oder automatisches 2×2-Mosaik
- [x] Titel hinzufügen (auch an bestimmter Stelle), entfernen und verschieben
- [x] **Lieblingssongs** (Herz), gespeicherte Alben, gefolgte Künstler
- [x] Öffentliche Playlists für die Familie, folgen, **gemeinsame Playlists** (alle dürfen Titel hinzufügen)
- [x] Hörverlauf → „Zuletzt gehört“, „Deine Top-Songs“, „Beliebt in der Familie“
- [x] Startseite: Schnellzugriff-Kacheln, Abschnitte, **Tagesmixe** (Genre, Entdecken, Künstler, Rubrik), Radio

## Schritt 4 – YouTube-Downloader (der Unterschied zu Spotify) ✅

- [x] Suche bei YouTube Music mit sauberen Angaben (Titel, Künstler, Album, Cover statt „Official Video (HD)“)
- [x] Treffer zeigen, ob es den Titel schon gibt bzw. ob er gerade geladen wird
- [x] Download in bester verfügbarer Qualität ohne Umwandlung (Opus/AAC); Videos als H.264/MP4 bis 1080p
- [x] Warteschlange mit **Live-Fortschritt** (Prozent, Tempo, Restzeit) per WebSocket, Abbrechen, Wiederholen
- [x] Ablage im passenden Rubrik-Ordner: `Rubrik/Künstler/Album/01 - Titel`
- [x] Tags, quadratisches Album-Cover, YouTube-ID, Songtexte (zeitsynchron, YouTube Music oder LRCLIB)
- [x] Ganze Alben von YouTube Music übernehmen, YouTube-Links (Video oder Playlist) einfügen
- [x] Rechte: nur Benutzer mit `can_download` dürfen Downloads starten
- [x] yt-dlp aktualisiert sich täglich selbst (mit Deno/EJS, wie YouTube es inzwischen verlangt)
- [x] Admin: Titel samt Datei löschen, Downloader-Status

## Schritt 5 – App Teil 1: Aussehen & Abspielen

- [ ] Spotify-ähnliches dunkles Design, Startseite / Suche / Bibliothek als untere Leiste
- [ ] Server-Adresse eingeben, Login, mehrere Konten auf einem Gerät
- [ ] Startseite, Suche mit farbigen Rubrik-Kacheln, Bibliothek mit Filtern (Playlists, Alben, Künstler, Heruntergeladen)
- [ ] Künstler- und Albumseiten
- [ ] Mini-Player über der unteren Leiste, Vollbild-Player mit Hintergrundfarbe passend zum Cover
- [ ] Wiedergabe im Hintergrund, Steuerung über Sperrbildschirm/Benachrichtigung, Kopfhörer- und Auto-Tasten
- [ ] Warteschlange („Als Nächstes spielen“), Zufall, Wiederholen, Schlaf-Timer, Geschwindigkeit (für Hörspiele)
- [ ] Lückenlose Wiedergabe und Überblenden

## Schritt 6 – App Teil 2: Playlists, Offline, Downloads, Videos

- [ ] Playlists in der App verwalten, Song-Menü (Liken, zu Playlist, Warteschlange, Zum Album/Künstler)
- [ ] **Offline-Modus**: Playlists, Alben und Lieblingssongs aufs Handy laden, Speicher verwalten
- [ ] „Holen“-Button mit Fortschrittsbalken und Restzeit, Benachrichtigung, wenn der Download fertig ist
- [ ] Videos und Musikvideos abspielen (Vollbild, Querformat)
- [ ] Songtexte im Player
- [ ] Einstellungen: Streaming- und Download-Qualität, Überblenden, Lautstärke angleichen, nur WLAN
- [ ] Admin-Bereich in der App: Benutzer, Rubriken, Downloads, Bibliothek neu scannen

## Schritt 7 – Fertig machen für Unraid & Handys

- [ ] GitHub Actions: Docker-Image automatisch bauen (GitHub Container Registry)
- [ ] Unraid-Vorlage („Add Container“ mit allen Feldern vorbelegt)
- [ ] Android: APK automatisch bauen
- [ ] iOS: Build für Developer-Account oder Sideloading (AltStore/SideStore)
- [ ] Ausführliche Anleitung: Unraid, Domain, Reverse Proxy, App installieren

---

## Bewusst nicht geplant (wäre möglich, aber großer Aufwand)

- Podcasts
- „Spotify Connect“ (auf einem anderen Gerät weiterspielen)
- Spotify-artige Empfehlungen fremder Musik (es gibt keinen Katalog, nur die eigene Bibliothek)
