# Selfify – dein eigenes Spotify auf dem Unraid

<img src="docs/icon.png" alt="Selfify" width="96" align="right">

Selfify funktioniert wie Spotify, nur mit deiner eigenen Musik: Startseite mit Mixen, Suche, Bibliothek,
Playlists (auch gemeinsame für die Familie), Lieblingssongs, Offline-Modus, Hörspiele und Videos – mit
mehreren Konten für die ganze Familie. **Fehlt ein Song, holt der Server ihn in bester verfügbarer Qualität
von YouTube (Music)**, und die App zeigt dabei live an, wie lange es noch dauert.

> **Arbeitstitel:** „Selfify“ lässt sich jederzeit umbenennen.

| Teil | Ordner | Technik |
|------|--------|---------|
| Server (läuft auf Unraid) | `server/` | Python, FastAPI, SQLite, ffmpeg, yt-dlp + Deno, Docker |
| Handy-App (Android + iOS) | `mobile/` | Flutter (just_audio, audio_service, Riverpod) |
| Unraid-Vorlage | `unraid/selfify.xml` | „Add Container“ mit allen Feldern vorbelegt |
| Automatische Builds | `.github/workflows/` | Docker-Image (GHCR), Android-APK, iOS-IPA |

Den Funktionsumfang im Detail findest du in [docs/ROADMAP.md](docs/ROADMAP.md).

**Schnellstart:** [Server auf Unraid installieren](#installation-auf-unraid) → [Domain einrichten](#zugriff-über-eine-domain-reverse-proxy)
→ [App installieren](#die-app-installieren) → [Erste Schritte](#erste-schritte).

---

## Installation auf Unraid

**Vorbereitung:** Unraid → *Shares* → *Add Share* → Name `selfify`. Hier landen Musik, Hörspiele und
Videos. Die Rechte (nobody:users) stimmen automatisch.

Danach gibt es zwei Wege. **Weg A** ist der bequemste. **Weg B** brauchst du, solange das Repository privat
ist und GitHub das fertige Image nicht speichern kann.

### Weg A – fertiges Image + Unraid-Vorlage

GitHub baut das Image bei jeder Änderung automatisch (`ghcr.io/patrick19921992/selfify-server`).

> **Voraussetzung:** Bei einem **privaten** Repository speichert GitHub im kostenlosen Tarif nur 500 MB für
> Images und Build-Dateien zusammen. Ist das voll, wird kein Image veröffentlicht (der Build zeigt dann
> eine Warnung). Abhilfe: Repository öffentlich machen. Es enthält keine Passwörter oder Daten, nur den
> Code. Danach ist alles kostenlos und ohne Anmeldung nutzbar. Sonst → Weg B.

1. Vorlage einspielen (Unraid-Terminal):
   ```bash
   wget -O /boot/config/plugins/dockerMan/templates-user/my-selfify.xml \
     https://raw.githubusercontent.com/patrick19921992/spotify/main/unraid/selfify.xml
   ```
   Bei privatem Repository klappt `wget` nicht: Dann `unraid/selfify.xml` per SMB nach
   `\\tower\flash\config\plugins\dockerMan\templates-user\my-selfify.xml` kopieren und vorher
   einmalig `docker login ghcr.io -u <github-name>` mit einem Token mit Recht `read:packages` ausführen.
2. *Docker* → *Add Container* → Vorlage **selfify** wählen, Pfade prüfen (`/mnt/user/appdata/selfify`,
   `/mnt/user/selfify`), **Öffentliche Adresse** eintragen → *Apply*.
3. Container-Symbol → *Logs*: Dort steht beim ersten Start das erzeugte Admin-Passwort.

Updates: *Docker* → *Check for Updates* → *Apply Update*.

### Weg B – auf dem Unraid selbst bauen (klappt immer)

1. Plugin **„Docker Compose Manager“** aus den *Apps* installieren (bringt `docker compose` mit).
2. Bei privatem Repository ein Token anlegen: GitHub → *Settings* → *Developer settings* →
   *Fine-grained tokens* → nur dieses Repository → *Contents: Read-only*.
3. Das Skript [`unraid/selfify-update.sh`](unraid/selfify-update.sh) aufs Unraid kopieren (oder als neues
   Skript im Plugin **„User Scripts“** einfügen), oben `GITHUB_TOKEN` eintragen und ausführen:
   ```bash
   bash /boot/config/selfify-update.sh
   ```
   Beim ersten Lauf legt es nur `/mnt/user/appdata/selfify-config.yml` an und hört dann auf. Dort trägst du
   `PUBLIC_URL` (und bei Bedarf ein eigenes `ADMIN_PASSWORD` oder andere Ordner) ein und startest das Skript
   noch einmal. Erst dann lädt es den Code, baut das Image (ein paar Minuten) und startet den Container
   `selfify`.
4. Admin-Passwort: dein `ADMIN_PASSWORD` – oder, falls leer gelassen, das erzeugte aus `docker logs selfify`.
   `ADMIN_PASSWORD` wirkt nur beim allerersten Start. Später hilft
   `docker exec -u 99:100 selfify python -m app.cli reset-password admin 'NeuesPasswort'`.

Updates: Skript erneut ausführen. Im Plugin „User Scripts“ geht das z. B. automatisch jede Woche. Deine
Einstellungen in `selfify-config.yml` bleiben erhalten.

> Nimm nur **einen** der beiden Wege. Beide legen einen Container namens `selfify` an.

Der Server ist danach unter `http://<unraid-ip>:8080` erreichbar. Unter `/api/docs` gibt es eine
Testoberfläche für alle Funktionen.

---

## Zugriff über eine Domain (Reverse Proxy)

Damit alle in der Familie ohne VPN zugreifen können, läuft Selfify hinter einem Reverse Proxy mit HTTPS,
z. B. **Nginx Proxy Manager** oder **SWAG** auf dem Unraid.

**Nginx Proxy Manager → Proxy Hosts → Add Proxy Host**

- *Domain Names:* `musik.example.de`
- *Forward Hostname/IP:* IP deines Unraid, *Port:* `8080`, *Scheme:* `http`
- **Websockets Support: an.** Wird ab Schritt 4 für die Live-Anzeige des Download-Fortschritts gebraucht.
- *Block Common Exploits:* an
- Tab *SSL:* Let's-Encrypt-Zertifikat anfordern, **Force SSL** und **HTTP/2** an
- Tab *Advanced → Custom Nginx Configuration:* längere Wartezeiten eintragen. Lange Hörbücher werden fürs
  iPhone erst umgewandelt, ein yt-dlp-Update dauert ein paar Minuten – sonst bricht der Proxy nach 60–90
  Sekunden mit Fehler 504 ab:
  ```nginx
  proxy_read_timeout 900s;
  proxy_send_timeout 900s;
  ```

Dazu einen DNS-Eintrag (bzw. DynDNS) für `musik.example.de` auf deine Internetadresse und im Router
Port 443 auf den Proxy weiterleiten.

**Sicherheit, weil der Server aus dem Internet erreichbar ist:**

- Es gibt **keine offene Registrierung**. Nur Admins legen Konten an.
- Passwörter werden mit Argon2 gespeichert, Logins nach zu vielen Fehlversuchen kurz gesperrt.
- Jedes Handy ist eine eigene „Sitzung“ und kann einzeln abgemeldet werden, z. B. wenn ein Handy verloren geht.
- Port `8080` **nicht** direkt im Router freigeben, immer nur über den Proxy mit HTTPS.

---

## Die App installieren

Die App baut GitHub automatisch. Die aktuelle Android-Version liegt nach jeder Änderung auf `main` unter
**Releases → „App – aktuelle Version“** (`selfify.apk`). Bei Versions-Tags (`v1.0.0` …) gibt es zusätzlich
feste Releases mit APK und IPA.

### Android

1. `selfify.apk` aus dem Release herunterladen, am besten direkt am Handy (GitHub-App oder Browser, angemeldet).
2. Installieren. Android fragt einmalig, ob Apps aus dieser Quelle erlaubt sind.
3. Bei der ersten Wiedergabe die Benachrichtigungen erlauben (für die Steuerung auf dem Sperrbildschirm).

> **Wichtig für Updates:** Damit sich neue Versionen über die alte installieren lassen (und die Offline-Musik
> erhalten bleibt), braucht der Build immer denselben Signaturschlüssel. Einmalig erzeugen:
>
> ```bash
> keytool -genkey -v -keystore selfify.keystore -alias selfify -keyalg RSA -keysize 2048 -validity 10000
> base64 -w0 selfify.keystore    # Ausgabe kopieren
> ```
>
> Dann im Repository unter *Settings → Secrets and variables → Actions* anlegen:
> `ANDROID_KEYSTORE_BASE64` (die base64-Ausgabe), `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`
> (`selfify`) und `ANDROID_KEY_PASSWORD`. Ohne diese Secrets signiert GitHub jeden Build mit einem anderen
> Test-Schlüssel. Updates gehen dann nur nach Deinstallation.

### iPhone / iPad

Apple erlaubt eigene Apps nur über einen dieser Wege:

| Weg | Kosten | Hinweis |
|-----|--------|---------|
| **AltStore / SideStore** | kostenlos | *Actions → App → „Run workflow“* mit Haken bei iOS starten. Danach liegt `selfify.ipa` unter *Releases → „iOS – aktuelle Version“*. Mit AltStore/SideStore installieren. Mit kostenloser Apple-ID muss die App **alle 7 Tage** neu signiert werden (macht AltStore/SideStore automatisch im WLAN). |
| **Apple-Developer-Account** | 99 €/Jahr | Signieren über Xcode (`mobile/ios/Runner.xcworkspace`) oder TestFlight. Ein Jahr gültig, bis zu 100 Geräte. |
| **Xcode mit eigener Apple-ID** | kostenlos, Mac nötig | Handy per Kabel, in Xcode „Run“ – ebenfalls 7 Tage gültig. |

### Erste Anmeldung in der App

Server-Adresse eintragen, z. B. `https://musik.example.de` oder im Heimnetz `http://192.168.1.10:8080`, dann
*Verbinden*, Benutzername und Passwort eingeben.

---

## Erste Schritte

1. **Als Admin anmelden** (Passwort aus dem Log) und unter *Einstellungen → Konto* das Passwort ändern.
2. **Konten anlegen:** *Einstellungen → Admin-Bereich → Benutzer*. Bei den Kindern kannst du
   „Darf YouTube-Downloads starten“ ausschalten. Sie können dann hören und suchen, aber nichts laden.
3. **Musik reinlegen:** Vorhandene Dateien per SMB in `\\tower\selfify\Musik` (bzw. `Hoerspiele`,
   `Videos` …) kopieren. Sie erscheinen nach wenigen Sekunden.
4. **Fehlende Songs holen:** *Suche* → Song eintippen → unter „Von YouTube holen“ auf **Holen** tippen.
5. **Offline hören:** In einer Playlist, einem Album oder bei den Lieblingssongs auf den Download-Pfeil tippen.

---

## Ordner auf dem Unraid

Selfify verwendet **eigene Ordner**, getrennt von MeTube und anderen Downloadern:

```
/mnt/user/appdata/selfify/      -> /data   im Container (Datenbank, Schlüssel, Cache)
/mnt/user/selfify/              -> /media  im Container (eigener Share für die Medien)
├── Musik/                       Rubrik „Musik“                 (Audio, Standardziel für Song-Downloads)
├── Musikvideos/                 Rubrik „Musikvideos“           (Video, Standardziel für Video-Downloads)
├── Hoerspiele/                  Rubrik „Hörspiele & Hörbücher“ (Audio)
└── Videos/                      Rubrik „Videos“                (Video)
```

**Rubriken** sind die Kategorien, die später in der App als eigene Bereiche erscheinen. Jede Rubrik hat
**einen eigenen Ordner** im Medien-Share. Die vier oben werden beim ersten Start automatisch angelegt.
Als Admin kannst du weitere anlegen, z. B. „Kinderlieder“ oder „Konzerte“. Der Ordner wird dabei sofort
mitangelegt, und Unterordner wie `Videos/Konzerte` sind möglich.

- Beim Download wählst du die Rubrik aus. Ohne Auswahl landet ein Song in der Standard-Rubrik seines Typs.
- Wird eine Rubrik gelöscht, verschwindet sie nur aus der App. **Der Ordner und alle Dateien bleiben erhalten.**
- Der Ordner einer Rubrik kann nachträglich nicht geändert werden, damit keine Dateien „verloren“ gehen.
  Name, Icon, Reihenfolge und Standard-Rubrik lassen sich jederzeit ändern.

> **Tipp:** Lege in Unraid unter *Shares* einen neuen Share `selfify` an. Die Rechte stimmen dann
> automatisch: Unraid verwendet `nobody:users` (99:100), und genau so läuft der Container.

---

## Bibliothek: So werden deine Dateien erkannt

Der Server liest alle Rubrik-Ordner automatisch ein:

- **beim Start**,
- **sofort bei Änderungen**: Neue oder gelöschte Dateien tauchen nach etwa 5 Sekunden in der App auf bzw. verschwinden,
- **zur Sicherheit alle 30 Minuten**.

Unveränderte Dateien werden übersprungen, ein erneuter Scan dauert deshalb nur Sekunden.

**Unterstützte Formate**

| Rubrik-Typ | Dateien |
|-----------|---------|
| Audio | MP3, M4A, M4B (Hörbücher), AAC, Opus, Ogg, FLAC, WAV, WMA, WebM |
| Video | MP4, M4V, MKV, WebM, MOV |

**Woher die Angaben kommen**

1. Aus den **Tags** der Datei: Titel, Künstler, Album, Album-Künstler, Track- und CD-Nummer, Jahr, Genre, Cover.
2. Fehlen Tags, aus **Ordner- und Dateinamen**. Empfohlene Ordnerstruktur:
   ```
   Musik/Künstler/Album/01 - Titel.mp3
   Hoerspiele/Die drei Fragezeichen/Folge 001 - Titel/01 Kapitel.mp3
   Musikvideos/Künstler - Titel.mp4
   ```
3. **Cover:** im Lied eingebettet → gleichnamiges Bild (`Titel.jpg`) → `cover.jpg`/`folder.jpg` im
   Ordner → bei Videos ein Standbild aus dem Video.

„feat.“-Künstler werden getrennt erkannt, z. B. „Daft Punk feat. Pharrell Williams“. Der Song erscheint
dann bei beiden Künstlern, wie bei Spotify. Unfertige Downloads (`.part`), versteckte Dateien und defekte
Dateien werden übersprungen. Defekte Dateien siehst du unter `GET /api/library/scan`.

**Abspielen auf dem iPhone**

iPhones können Opus, Ogg und WebM nicht abspielen. Die App fragt solche Titel deshalb mit
`compatible=true` an. Der Server wandelt sie dann einmalig in AAC (256 kbit/s) um und speichert das
Ergebnis zwischen (`/data/transcode`). Danach geht auch das Spulen sofort. Android spielt alles direkt.
Den gleichen Mechanismus nutzt der **Datensparmodus** (`quality=low|normal|high`).

> **Videos** werden nicht umgewandelt, dafür bräuchte ein Unraid ohne Grafikkarte zu viel Rechenleistung.
> MP4 mit H.264 läuft überall. MKV und WebM laufen auf Android, auf dem iPhone aber nicht zuverlässig.
> Deshalb lädt der Downloader in Schritt 4 Videos bevorzugt als MP4.

---

## Fehlende Songs: der YouTube-Downloader

1. In der App suchen. Unter den eigenen Treffern stehen die Treffer von **YouTube Music** mit sauberen Angaben
   zu Titel, Künstler, Album und Cover.
2. Auf **„Holen“** tippen. Der Server lädt im Hintergrund in **bester verfügbarer Qualität** und zeigt live
   Prozent, Geschwindigkeit und Restzeit. Danach ist der Titel sofort in der Bibliothek und auf Wunsch
   gleich in einer Playlist.
3. Ganze Alben lassen sich mit einem Tipp holen. Ein YouTube-Link (Video oder Playlist) geht auch.

| Was | Wie |
|-----|-----|
| Ton | Originalspur **ohne Umwandlung**, meist Opus mit ca. 130–160 kbit/s. Das ist die beste Qualität, die YouTube liefert. Mit YouTube-Music-Premium-Cookies gibt es AAC mit 256 kbit/s. |
| Video | H.264 + AAC als MP4 bis 1080p (läuft auf jedem Handy). Mit `YTDL_VIDEO_CODEC=best` und `YTDL_VIDEO_MAX_HEIGHT=2160` VP9/AV1 bis 4K, das läuft aber nicht auf jedem iPhone. |
| Tags | Titel, Künstler, Album, Tracknummer, Jahr, Album-Cover (quadratisch) und YouTube-ID werden in die Datei geschrieben. |
| Songtexte | Zeitsynchron von YouTube Music, ersatzweise von LRCLIB, gespeichert als `.lrc` neben dem Titel |
| Ablage | `Rubrik/Künstler/Album/01 - Titel.opus` bzw. `Musikvideos/Künstler/Titel.mp4` (+ Vorschaubild) |
| Doppelte | Gibt es den Titel schon (gleiche YouTube-ID), ist der Download sofort „fertig“. |
| Rechte | Nur Benutzer mit **Download-Recht** (`can_download`) dürfen Downloads starten. Suchen dürfen alle. |
| Aktualität | yt-dlp aktualisiert sich **täglich selbst** (YouTube ändert häufig etwas), ohne Neustart. |

Laufende Downloads überstehen einen Neustart des Containers und werden danach fortgesetzt. Downloads lassen
sich abbrechen und bei einem Fehler erneut starten.

> **YouTube-Music-Premium (optional):** Cookies im Netscape-Format als `youtube-cookies.txt` in den
> Datenordner (`/mnt/user/appdata/selfify/`) legen. Dann lädt yt-dlp in Premium-Qualität und auch
> altersbeschränkte Videos.

---

## Einstellungen (Umgebungsvariablen)

| Variable | Standard | Bedeutung |
|----------|----------|-----------|
| `PUBLIC_URL` | – | Adresse über deine Domain, z. B. `https://musik.example.de` |
| `SERVER_NAME` | `Selfify` | Name, der in der App angezeigt wird |
| `ADMIN_USERNAME` | `admin` | Erster Admin (nur beim allerersten Start) |
| `ADMIN_PASSWORD` | leer | Leer = wird erzeugt und im Log angezeigt |
| `PUID` / `PGID` | `99` / `100` | Benutzer/Gruppe für Dateien (Unraid: nobody/users) |
| `UMASK` | `002` | Rechte für neue Dateien (Gruppe darf schreiben) |
| `TZ` | `Europe/Berlin` | Zeitzone für Logs |
| `ACCESS_TOKEN_MINUTES` | `30` | Gültigkeit des Zugriffs-Tokens; die App erneuert ihn automatisch |
| `REFRESH_TOKEN_DAYS` | `90` | So lange bleibt ein Handy angemeldet, ohne die App zu nutzen |
| `MEDIA_TOKEN_HOURS` | `168` | Gültigkeit der Stream-/Cover-Links (Player-Warteschlangen) |
| `SCAN_ON_STARTUP` | `true` | Bibliothek beim Start einlesen |
| `SCAN_INTERVAL_MINUTES` | `30` | Regelmäßiger Sicherheits-Scan (`0` = aus) |
| `LIBRARY_WATCH` | `true` | Ordner live überwachen (neue Dateien sofort sichtbar) |
| `TRANSCODE_CACHE_MB` | `2048` | Zwischenspeicher für umgewandelte Titel (iPhone/Datensparmodus) |
| `FFMPEG_PATH` / `FFPROBE_PATH` | `ffmpeg` / `ffprobe` | Nur ändern, wenn ffmpeg woanders liegt |
| `DOWNLOAD_WORKERS` | `2` | Wie viele Downloads gleichzeitig laufen |
| `YTDL_AUDIO_FORMAT` | `best` | `best` = Originalspur (Opus), `m4a` = AAC (iPhone-nativ), `mp3` = MP3 320k |
| `YTDL_VIDEO_MAX_HEIGHT` | `1080` | Höchste Video-Auflösung |
| `YTDL_VIDEO_CODEC` | `compatible` | `compatible` = H.264/MP4, `best` = VP9/AV1 (höher, nicht überall abspielbar) |
| `YTDL_AUTO_UPDATE` | `true` | yt-dlp täglich aktualisieren |
| `YTDL_COOKIES_FILE` | `/data/youtube-cookies.txt` | Optionale Cookies (Premium-Qualität) |
| `YTMUSIC_LANGUAGE` / `YTMUSIC_LOCATION` | `de` / `DE` | Sprache/Land der YouTube-Music-Suche |
| `LYRICS_ENABLED` | `true` | Songtexte beim Download mitladen |
| `LOGIN_MAX_FAILURES_PER_USER` | `10` | Fehlversuche je Benutzer, bevor der Login kurz gesperrt wird |
| `LOGIN_MAX_FAILURES_PER_IP` | `30` | Fehlversuche je IP-Adresse |
| `LOGIN_WINDOW_MINUTES` | `15` | Zeitfenster bzw. Sperrdauer |
| `ENABLE_API_DOCS` | `true` | Test-Oberfläche unter `/api/docs` (ohne Login nutzlos) |
| `FORWARDED_ALLOW_IPS` | private Netze | Von welchen Proxys die echte Client-IP übernommen wird |
| `SECRET_KEY` | leer | Leer = wird erzeugt und in `/data/secret.key` gespeichert |
| `DATA_DIR` / `MEDIA_DIR` | `/data` / `/media` | Pfade **im** Container (nicht ändern) |

---

## Konsolen-Befehle

Im Unraid-Terminal (oben rechts in der Unraid-Oberfläche, **nicht** in der Container-Konsole – dort gibt es
kein `docker`):

```bash
docker exec -u 99:100 selfify python -m app.cli list-users
docker exec -u 99:100 selfify python -m app.cli reset-password admin 'NeuesSicheresPasswort'
docker exec -u 99:100 selfify python -m app.cli create-user papa 'SicheresPasswort' --admin
```

`reset-password` aktiviert das Konto auch wieder und meldet alle Geräte dieses Benutzers ab.

---

## API-Überblick

Alle Endpunkte liegen unter `/api`. Die genaue Beschreibung steht unter `/api/docs`.

| Bereich | Endpunkte |
|---------|-----------|
| System | `GET /health`, `GET /server` |
| Anmeldung | `POST /auth/login`, `POST /auth/refresh`, `POST /auth/logout` |
| Mein Konto | `GET/PATCH /me`, `POST /me/password`, `GET /me/sessions`, `DELETE /me/sessions/{id}` |
| Benutzer (Admin) | `GET/POST /users`, `GET/PATCH/DELETE /users/{id}` |
| Rubriken | `GET /categories` (alle, inkl. Anzahl Titel), `POST /categories`, `PATCH/DELETE /categories/{id}` (Admin) |
| Bibliothek | `GET /artists`, `GET /artists/{id}`, `GET /albums`, `GET /albums/{id}`, `GET /tracks`, `GET /tracks/{id}` |
| Suche | `GET /search?q=…` – Top-Treffer, Songs, Künstler, Alben, Videos (findet „Ärzte“ auch als „aerzte“) |
| Scan | `GET /library` (Statistik), `GET /library/scan` (Status), `POST /library/scan` (Admin) |
| Streaming | `GET /tracks/{id}/stream` (Spulen per Range; `quality`, `compatible`), `GET /covers/{id}?size=64\|128\|300\|600` |
| Songtexte | `GET /tracks/{id}/lyrics` (zeitsynchron, wenn vorhanden) |
| Playlists | `GET/POST /playlists`, `GET/PATCH/DELETE /playlists/{id}`, `POST …/items`, `POST …/items/remove`, `POST …/items/move`, `PUT/DELETE …/cover`, `PUT/DELETE …/follow` |
| Persönlich | `GET /home`, `GET /me/library`, `GET /me/likes`, `GET /me/likes/ids`, `PUT/DELETE /me/likes/{track}`, `PUT/DELETE /me/albums/{id}`, `PUT/DELETE /me/artists/{id}` |
| Verlauf | `POST /me/history`, `GET /me/history`, `DELETE /me/history`, `GET /me/recent`, `GET /me/top-tracks` |
| Mixe & Radio | `GET /mixes/{genre:Rock\|discover\|artist:ID\|category:ID\|recent}`, `GET /tracks/{id}/radio` |
| YouTube | `GET /youtube/search?q=…&type=songs\|videos\|albums`, `GET /youtube/albums/{browseId}` |
| Downloads | `POST /downloads`, `POST /downloads/album`, `POST /downloads/url`, `GET /downloads`, `POST /downloads/{id}/cancel\|retry`, `DELETE /downloads/{id}` |
| Live-Fortschritt | WebSocket `/api/downloads/ws?token=<access_token>` – `snapshot`, dann `job`-Ereignisse (eigene Downloads; Admins mit `&scope=all` alle) |
| Admin | `DELETE /tracks/{id}?delete_file=true`, `GET /downloads-system`, `POST /downloads-system/update` |

Listen sind seitenweise (`limit`, `offset`) und sortierbar (`sort=title|recent|…`). Streams und Cover
akzeptieren statt des `Authorization`-Headers auch den **Medien-Token** aus dem Login als `?t=…`. So
funktionieren lange Wiedergabelisten im Player auch nach Ablauf des 30-Minuten-Tokens.

Benutzer haben das Recht **`can_download`**. Damit legst du z. B. fest, dass die Kinder Songs hören,
aber keine neuen Downloads starten dürfen.

---

## Entwicklung

**Server** (Python 3.13):

```bash
cd server
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements-dev.txt
pytest                 # Tests
ruff check app tests   # Code-Prüfung

# Lokal starten (Daten landen in ./dev-data)
DATA_DIR=../dev-data/data MEDIA_DIR=../dev-data/media ADMIN_PASSWORD=admin12345 \
  uvicorn app.main:create_app --factory --reload --port 8080
```

Neue Datenbank-Migration nach einer Modelländerung:
`DATA_DIR=../dev-data/data alembic revision --autogenerate -m "beschreibung"`.
Beim Serverstart werden Migrationen automatisch ausgeführt.

**App** (Flutter 3.47):

```bash
cd mobile
flutter pub get
flutter analyze
flutter test
flutter run            # Handy/Emulator angeschlossen
```

Aufbau: `lib/data` (Modelle, Server-Client), `lib/state` (Anmeldung, Einstellungen, Downloads,
Offline-Speicher), `lib/player` (Hintergrund-Wiedergabe), `lib/ui` (Navigation, Bildschirme, Bausteine).

---

## Rechtlicher Hinweis

Downloads von YouTube verstoßen gegen die Nutzungsbedingungen von YouTube. Selfify ist für die
**private Nutzung im eigenen Haushalt** gedacht. Biete heruntergeladene Inhalte nicht öffentlich an.
