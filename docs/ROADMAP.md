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

## Schritt 2 – Bibliothek & Streaming

- [ ] Scanner liest alle Rubrik-Ordner: Titel, Künstler, Album, Jahr, Genre, Tracknummer, Dauer, Cover
- [ ] Erkennt neue, geänderte und gelöschte Dateien automatisch (Ordner-Überwachung + nächtlicher Scan)
- [ ] Künstler-, Album-, Song- und Video-Ansichten wie bei Spotify
- [ ] Streaming mit Spulen (HTTP-Range), Cover in mehreren Größen
- [ ] Optional: Datensparmodus (Server wandelt beim Streamen in kleinere Qualität um)
- [ ] Suche in der eigenen Bibliothek (Songs, Künstler, Alben, Playlists, Videos)

## Schritt 3 – Playlists & persönliche Daten

- [ ] Playlists erstellen, umbenennen, Beschreibung, eigenes Cover oder automatisches 2×2-Mosaik
- [ ] Songs hinzufügen, entfernen und per Drag & Drop sortieren
- [ ] **Lieblingssongs** (Herz-Button) als feste Playlist
- [ ] Gemeinsame Playlists in der Familie (wie „Gemeinsame Playlist“ bei Spotify)
- [ ] Hörverlauf → „Zuletzt gehört“, „Deine Top-Songs“, „Beliebt in der Familie“
- [ ] Daten für die Startseite (Begrüßung je nach Tageszeit, Schnellzugriff-Kacheln, Mixe nach Genre/Künstler)

## Schritt 4 – YouTube-Downloader (der Unterschied zu Spotify)

- [ ] Suche bei YouTube Music mit sauberen Angaben (Titel, Künstler, Album, Cover statt „Official Video (HD)“)
- [ ] In den Suchergebnissen: „In deiner Bibliothek“ und darunter „Von YouTube holen“
- [ ] Download in bester verfügbarer Qualität, ohne erneutes Umwandeln (Opus/AAC); Videos bevorzugt H.264/H.265
- [ ] Download-Warteschlange mit **Live-Fortschritt** (Prozent, Tempo, Restzeit) per WebSocket
- [ ] Ablage im passenden Rubrik-Ordner: `Rubrik/Künstler/Album/Titel`
- [ ] Automatische Tags, Cover, Songtexte (synchron, wenn verfügbar)
- [ ] Ganze Alben oder Playlists von YouTube Music übernehmen
- [ ] Rechte: nur Benutzer mit `can_download` dürfen Downloads starten
- [ ] yt-dlp automatisch aktuell halten (YouTube ändert häufig etwas)

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
