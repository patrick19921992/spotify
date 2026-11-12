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
| App (Android, iOS, Windows) | `mobile/` | Flutter (just_audio, audio_service, Riverpod; Windows: libmpv) |
| Unraid-Vorlage | `unraid/selfify.xml` | „Add Container“ mit allen Feldern vorbelegt |
| Automatische Builds | `.github/workflows/` | Docker-Image (GHCR), Android-APK, Windows-App, iOS-IPA |

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
- **Websockets Support: an.** Wird ab Schritt 4 für die Live-Anzeige des Download-Fortschritts gebraucht und
  für [Auf anderen Geräten abspielen](#auf-anderen-geräten-abspielen) (`/api/connect/ws`). Ohne WebSockets bleibt
  der Geräte-Knopf in der App einfach weg.
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

**Cloudflare-Tunnel statt Portfreigabe:** WebSockets leitet der Tunnel ohne Zusatz-Einstellung weiter. Die
Geräte-Verbindung schickt alle 25 Sekunden ein Lebenszeichen (App und Server), das liegt unter dem Leerlauf-Limit
von Cloudflare (rund 100 Sekunden). Ausprobiert ist das bisher nur in Tests, nicht an einem echten Tunnel.

**Sicherheit, weil der Server aus dem Internet erreichbar ist:**

- Standardmäßig gibt es **keine offene Registrierung** (*App-Einstellungen › Registrierung* = „Aus“), nur Admins
  legen Konten an. Schaltest du sie ein, siehe [Selbst-Registrierung](#selbst-registrierung-und-rubriken-freigeben):
  5 Versuche je Anschluss und Stunde, höchstens 20 neue Konten je Stunde, auf Wunsch mit Freigabe durch dich, und
  neue Konten sehen nur die Rubriken, die du freigibst.
- Passwörter werden mit Argon2 gespeichert, Logins nach zu vielen Fehlversuchen kurz gesperrt.
- Jedes Handy ist eine eigene „Sitzung“ und kann einzeln abgemeldet werden, z. B. wenn ein Handy verloren geht.
- Port `8080` **nicht** direkt im Router freigeben, immer nur über den Proxy mit HTTPS.

---

## Die App installieren

Die App baut GitHub automatisch. Die aktuelle Android- und Windows-Version liegt nach jeder Änderung auf
`main` unter **Releases → „App – aktuelle Version“** (`selfify.apk`, `selfify-windows-setup.exe`,
`selfify-windows.zip`). Bei Versions-Tags (`v1.0.0` …) gibt es zusätzlich feste Releases mit APK, Windows-App
und IPA.

### Android

> **Google Play:** Es gibt auch eine Play-Store-Version (ohne YouTube-Funktionen, mit „Song wünschen“, Premium
> und Werbung). Wie du sie veröffentlichst, steht in **[docs/PLAYSTORE.md](docs/PLAYSTORE.md)**. Das Bundle
> `selfify-play.aab` liegt im selben Release wie die APK – zum Installieren auf dem Handy ist es **nicht** gedacht.
>
> Die Play-Version kennt die **Server-Adresse fest**: Setze dafür unter *GitHub › Settings › Secrets and variables ›
> Actions › Variables* die Variable `PLAY_SERVER_URL` (z. B. `https://musik.technologyplanet.org`). Dann fragt die
> App im Store nicht mehr danach – nur noch Benutzername und Passwort. Ohne die Variable fragt sie wie die
> GitHub-Version.

1. `selfify.apk` aus dem Release herunterladen, am besten direkt am Handy (GitHub-App oder Browser, angemeldet).
2. Installieren. Android fragt einmalig, ob Apps aus dieser Quelle erlaubt sind.
3. Bei der ersten Wiedergabe die Benachrichtigungen erlauben (für die Steuerung auf dem Sperrbildschirm).

**Updates:** Die App schaut beim Start nach einer neueren Version (Datei `version.json` im Release), danach
stündlich und beim Zurückkehren in die App (höchstens alle 30 Minuten), und zeigt dann „Neue App-Version
verfügbar“. *Installieren* lädt die APK und öffnet den Android-Installer. Beim ersten
Mal fragt Android, ob Selfify Apps installieren darf. Von Hand: *Einstellungen → Nach Updates suchen*. Der
Hinweis erscheint auch auf dem Anmeldebildschirm – falls die Anmeldung erst mit der neuen Version klappt.

> **Wichtig für Updates:** Damit sich neue Versionen über die alte installieren lassen (und die Offline-Musik
> erhalten bleibt), braucht der Build immer denselben Signaturschlüssel. Einmalig erzeugen – ohne Java auf dem
> PC geht das im Unraid-Terminal per Docker (Passwort zweimal eingeben, Fragen mit Enter überspringen, am Ende
> `yes`):
>
> ```bash
> mkdir -p /mnt/user/appdata/selfify-signing
> docker run --rm -it -v /mnt/user/appdata/selfify-signing:/out eclipse-temurin:21-jre keytool -genkeypair \
>   -keystore /out/selfify.keystore -alias selfify -keyalg RSA -keysize 2048 -validity 10000 -storetype PKCS12
> base64 -w0 /mnt/user/appdata/selfify-signing/selfify.keystore; echo    # Ausgabe kopieren
> ```
>
> Die Datei `selfify.keystore` zusätzlich sichern – geht sie verloren, ist wieder eine Neuinstallation nötig.
>
> Dann im Repository unter *Settings → Secrets and variables → Actions* anlegen:
> `ANDROID_KEYSTORE_BASE64` (die base64-Ausgabe), `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`
> (`selfify`) und `ANDROID_KEY_PASSWORD` (bei PKCS12 dasselbe Passwort). Ohne diese Secrets signiert GitHub jeden Build mit einem anderen
> Test-Schlüssel. Updates gehen dann nur nach Deinstallation, und die App zeigt keinen Update-Hinweis.

### Windows (PC/Laptop)

Selfify gibt es auch als Desktop-App für **Windows 10 und 11 (64 Bit)**. Sie entsteht aus demselben Code wie
die Handy-App und liegt ebenfalls unter **Releases → „App – aktuelle Version“**. Sie kommt ein paar Minuten
nach der APK dazu, weil GitHub sie erst danach auf einem eigenen Windows-Rechner baut.

| Datei | Wofür |
|-------|-------|
| `selfify-windows-setup.exe` | **Empfohlen.** Installiert Selfify mit Eintrag im Startmenü (auf Wunsch auch ein Desktop-Symbol) und lässt sich unter *Einstellungen → Apps* wieder entfernen. Keine Admin-Rechte nötig. |
| `selfify-windows.zip` | Ohne Installation, z. B. zum Ausprobieren oder für einen USB-Stick. |

**Installieren**

1. `selfify-windows-setup.exe` herunterladen und starten.
2. Windows zeigt beim Start **„Der Computer wurde durch Windows geschützt“** (Microsoft Defender SmartScreen).
   Das liegt nur daran, dass die App nicht mit einem kostenpflichtigen Zertifikat signiert ist. Auf
   **„Weitere Informationen“** klicken, dann auf **„Trotzdem ausführen“**.
   Warnt schon der Browser beim Herunterladen („wird selten heruntergeladen“), in der Download-Liste bei der
   Datei auf **…** → **Beibehalten** klicken (in Edge eventuell noch *Mehr anzeigen → Trotzdem beibehalten*).
3. Den Assistenten durchklicken. Selfify landet ohne Admin-Rechte in `%LOCALAPPDATA%\Programs\Selfify`.
4. Server-Adresse eintragen und anmelden, genau wie am Handy (siehe [Erste Anmeldung in der App](#erste-anmeldung-in-der-app)).

**Ohne Installation (ZIP):** Vor dem Entpacken *Rechtsklick auf die ZIP → Eigenschaften → unten „Zulassen“
anhaken → OK*. Sonst fragt SmartScreen bei jedem Start nach. Dann entpacken und im Ordner `Selfify` die Datei
`selfify.exe` starten. Alle Dateien im Ordner gehören zusammen (DLLs und Ordner `data`). Die `.exe` allein
funktioniert nicht.

**Updates:** Wie am Handy zeigt Selfify „Neue App-Version verfügbar“ – auch wenn das Programm die ganze Zeit
offen bleibt (es schaut stündlich nach und wenn das Fenster wieder in den Vordergrund kommt). *Installieren* lädt den neuen Installer,
prüft ihn, schließt Selfify, aktualisiert im Hintergrund und startet Selfify wieder – ohne erneute
SmartScreen-Warnung. Von Hand: *Einstellungen → Nach Updates suchen*, oder die neue
`selfify-windows-setup.exe` einfach darüber installieren. Anmeldung, Einstellungen und Offline-Musik bleiben
erhalten. Wer die ZIP-Version nutzt, bekommt beim ersten Update den normalen Installations-Assistenten; danach
Selfify über das Startmenü starten und den alten ZIP-Ordner löschen.
Die allererste Windows-Version (Build 31) sucht noch nicht nach Updates (in den Einstellungen fehlt dort
„Nach Updates suchen“): einmal `selfify-windows-setup.exe` aus dem Release `app-latest` von Hand darüber
installieren – danach kommen Updates von selbst.

**Deinstallieren:** *Einstellungen → Apps → Installierte Apps → Selfify → Deinstallieren*. Die **Offline-Musik
wird dabei gelöscht** (Ordner `%LOCALAPPDATA%\Selfify\Selfify\offline`; bei einem Update bleibt sie erhalten).
Anmeldung und Einstellungen bleiben auf dem PC. Wer alles entfernen will, löscht danach noch die Ordner
`%APPDATA%\Selfify` (Anmeldung, Einstellungen) und `%LOCALAPPDATA%\Selfify` (Zwischenspeicher). Wer die
ZIP-Version nutzt, hat keinen Deinstaller und löscht die Ordner selbst.

> **Warum die Warnung?** Ohne (kostenpflichtiges) Code-Signatur-Zertifikat kennt SmartScreen den Herausgeber
> nicht und warnt bei jeder neuen Version. Die Dateien baut GitHub direkt aus diesem Repository.

**Bedienung wie bei Spotify:** Links die Seitenleiste mit Start, Suche, Bibliothek und deinen Playlists, unten
die Player-Leiste, rechts auf Wunsch Warteschlange oder Songtext. Ist das Fenster schmal (unter etwa 840
Punkten), zeigt Selfify die Handy-Ansicht.

| Taste | Wirkung |
|-------|---------|
| Leertaste | Abspielen/Pause (nicht beim Tippen im Suchfeld und nicht auf der Videoseite) |
| Strg + F oder Strg + L | Suche |
| Strg + → / Strg + ← | Nächster / vorheriger Titel |
| Umschalt + → / Umschalt + ← | 5 Sekunden vor / zurück |
| Strg + ↑ / Strg + ↓ | Lauter / leiser |
| Alt + ← oder seitliche Maustaste | Zurück |
| Medientasten (Tastatur, Headset) | Abspielen/Pause, Weiter, Zurück – auch wenn Selfify im Hintergrund ist. Titel und Cover erscheinen zusätzlich in der Windows-Medienübersicht (Lautstärke-Popup bzw. Schnelleinstellungen) |

Im **Videoplayer** (Maus über dem Video): Leertaste Abspielen/Pause, ← / → spulen, ↑ / ↓ lauter/leiser, M stumm,
F Vollbild, Esc Vollbild beenden. Den Lautstärkeregler gibt es in der Leiste des Videos (auch im Vollbild); Musik
und Videos haben dieselbe Lautstärke, wie bei Spotify.

> **Unterschied zum Handy:** Zwischen zwei Titeln gibt es unter Windows eine kurze Pause (der nächste Titel
> wird erst am Ende des vorherigen geöffnet) – bei Live-Alben oder DJ-Mixen hörbar.
>
> **Windows „N“/„KN“-Editionen** (ohne Mediaplayer) brauchen zuerst das kostenlose *Media Feature Pack*
> (*Einstellungen → Apps → Optionale Features → Feature hinzufügen → Media Feature Pack*), sonst startet die
> App nicht. Videos im MKV/WebM-Format brauchen unter Windows oft die *VP9-Videoerweiterung* aus dem
> Microsoft Store – am einfachsten Videos als MP4 laden.

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
   Gibt es einen Titel nur als **Video** (oft bei Kinderliedern), fragt **Holen**: **Nur Musik** holt nur den
   Ton als Song (ohne Bild, viel kleiner), **Video** das ganze Video. Wer nicht jedes Mal gefragt werden will
   (z. B. auf dem Handy der Kinder): *Einstellungen › YouTube-Downloads › YouTube-Videos holen als* auf
   **Immer nur Musik** stellen – oder im Auswahlblatt **Wahl merken** anhaken. Die Einstellung gilt pro Gerät;
   im Menü eines Videos (antippen) lässt sich trotzdem beides holen.
5. **Offline hören:** In einer Playlist, einem Album oder bei den Lieblingssongs auf den Pfeil nach unten tippen
   („Aufs Gerät laden“). Die Musik findest du dann unter *Bibliothek › Auf diesem Gerät*.
6. **Videos in Playlists:** Steht ein Video in den Lieblingssongs oder einer Playlist, läuft es beim Abspielen
   als Ton mit (wie Musikvideos bei Spotify) – der Server schickt dafür nur die Tonspur. Antippen öffnet es
   weiterhin als Video. Offline gibt es Videos nicht.

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
- Wird eine Rubrik gelöscht, verschwindet sie samt ihrer Titel aus der App – auch aus den Playlists,
  Lieblingssongs und dem Verlauf aller Konten (kommt beim Neuanlegen nicht zurück). **Der Ordner und alle
  Dateien bleiben erhalten.** Zum Umbenennen reicht „Speichern“, dabei geht nichts verloren.
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

## Dashboard, Premium und Play-Store-Funktionen (Server)

Der Server bringt eine Verwaltungsseite für Admins mit: **`https://deine-domain/dashboard`** (oder
`http://<Unraid-IP>:8080/dashboard`). Anmelden kannst du dich mit jedem Admin-Konto; die Seite läuft ohne
Zusatzsoftware im Browser (Handy und PC).

| Ansicht | Was du dort siehst und tust |
|---------|-----------------------------|
| Übersicht | Zahlen (Benutzer, Songs, Downloads, Premium, offene Wünsche …), Diagramme der letzten 14 Tage, wer am meisten holt, welche App-Versionen im Umlauf sind |
| Downloads | Alle Downloads aller Benutzer live, abbrechen / nochmal / entfernen, yt-dlp aktualisieren |
| Wünsche | Songs, die sich Benutzer wünschen: „Suchen & holen“ startet den Download auf deinem Server, „Ablehnen“ (mit Nachricht), „Erledigt“ |
| Benutzer | Anlegen, sperren, Passwort setzen, Downloads erlauben, löschen, **Premium vergeben oder entziehen**, **Rubriken freigeben** und selbst registrierte Konten **freischalten oder ablehnen** (Filter „Wartend“, Zahl am Menüpunkt) |
| Premium-Codes | Codes erzeugen (beliebig viele, **Laufzeit frei in Tagen oder unbegrenzt**, mehrfach einlösbar, optional „einlösbar bis“, **welche Leistungen der Code freischaltet** – Standard alle), kopieren, sperren (auf Wunsch samt schon vergebenem Premium), Liste aller aktuellen Premium-Nutzer mit Umfang, **Käufe über Google Play** (Laufzeit, Stand, gilt bis, „Neu prüfen“) |
| Fehlermeldungen | „Fehler melden“ aus der App, mit Geräteinfo und Fehlerprotokoll; als gesehen/erledigt markieren |
| Geräte & Versionen | Welche App-Version (Play oder GitHub) auf wie vielen Geräten läuft, wer ein Update braucht |
| App-Einstellungen | **Registrierung** (wer Konten anlegen darf, Rubriken für neue Konten), Werbung an/aus, Premium-Bereich an/aus, „Song wünschen“ an/aus, **Premium-Leistungen** (je Leistung „Für alle“ oder „Nur Premium“), Gnadenfrist und Texte der Premium-Seite, **Kauf in der App** (Play-Version, Laufzeiten), Update-Hinweis und Pflicht-Update der Play-Version, Wartungshinweis |

**Premium-Regeln**

- Ein Code besteht aus 12 Zeichen (`XXXX-XXXX-XXXX`, Groß-/Kleinschreibung und Bindestriche sind beim
  Eintippen egal). Verwechselbare Zeichen (0/O, 1/I/L) kommen nicht vor.
- Du legst fest: Laufzeit in Tagen **oder** unbegrenzt, wie oft der Code einlösbar ist (ein Benutzer löst
  denselben Code höchstens einmal ein) und optional bis wann er eingelöst werden darf.
- Die Laufzeit beginnt beim Einlösen. Wer schon Premium hat, bekommt die neue Laufzeit **hinten angehängt**.
  Wer schon unbegrenzt hat, kann keinen Code mehr einlösen, dessen Leistungen er schon alle hat (der Code bleibt
  unverbraucht).
- Entziehen geht je Lizenz, je Benutzer („Alles entziehen“) und je Code. Entzogenes Premium gilt sofort nicht
  mehr.
- Premium direkt an einen Benutzer vergeben (ohne Code): Benutzer → **Premium**.
- **Leistungsumfang eines Codes:** Beim Erzeugen wählst du unter „Schaltet frei“, welche Leistungen der Code
  freischaltet (Standard: „Alle Leistungen“). Die Lizenz übernimmt den Umfang beim Einlösen; das Dashboard zeigt ihn
  bei jedem Code und jeder Lizenz (Spalte „Umfang“). **Alle Codes und Lizenzen von vor diesem Update, vom Admin
  vergebenes Premium und ein Abo über Google Play schalten immer alle Leistungen frei.** Ein Code mit Teilumfang
  hängt sich nur hinter Lizenzen, die alles davon schon enthalten – sonst läuft er sofort ab dem Einlösen.
- **Codes und vergebenes Premium schalten frei, was ihr Umfang enthält** – auch das Offline-Hören, wenn es auf
  „Nur Premium“ steht (siehe unten), genau wie ein Kauf über Google Play. Läuft der Code ab, sperrst du ihn samt
  vergebenem Premium oder entziehst du die Lizenz, löscht die App die Offline-Musik vom Gerät, sobald sie den Stand
  beim Server geprüft hat (ebenso bei einem Code ohne „Offline-Hören“ im Umfang).
- Falsche Codes werden wie falsche Passwörter gebremst (nach zu vielen Fehlversuchen kurze Sperre).
- **Wichtig für den Play Store:** Verschenke Codes. Wer Codes gegen Geld außerhalb von Google Play verkauft und
  in der App einlösen lässt, verstößt gegen die Zahlungsregeln von Google. Verkaufen geht in der Play-Version nur
  über Google Play (siehe unten).

**Was Premium beinhaltet – und der Kauf in der App** (*App-Einstellungen*; alles standardmäßig **aus** bzw. „Für
alle“, ohne diese Schalter verhalten sich Server und Apps wie bisher):

Karte **„Premium-Leistungen“** – je Leistung „Für alle“ (Standard) oder „Nur Premium“. **Admins sind nie
eingeschränkt.** Die Premium-Texte der App richten sich nach dem, was auf „Nur Premium“ steht.

| Leistung | Schlüssel (`/admin/config`) | Ohne Premium, wenn „Nur Premium“ | Durchgesetzt |
|----------|-----------------------------|-----------------------------------|--------------|
| Offline-Hören | `offline_requires_premium` | nichts aufs Gerät laden, vorhandene Offline-Musik wird gelöscht (Tabelle darunter) | App (+ `offline_min_client_build` auf dem Server) |
| Keine Werbung | – (immer Premium-Vorteil) | Werbung, wenn sie eingeschaltet ist (nur Play-Version) | App |
| Höhere Tonqualität | `hq_audio_requires_premium`, `free_audio_quality` (`normal` = 160 kbit/s, Standard, oder `low` = 96 kbit/s) | Stream höchstens in dieser Qualität – auch beim Offline-Laden | **Server** (Umwandlung mit ffmpeg; ohne ffmpeg lässt sich der Schalter nicht einschalten) |
| Videos ansehen | `video_requires_premium` | Videos nur als Ton | **Server** (Video-Stream ohne `audio_only` → 403) |
| Songtexte | `lyrics_requires_premium` | keine Songtexte | **Server** (403) |
| Mehr Song-Wünsche | `requests_requires_premium`, `free_requests_per_week` (Standard 3, 0–100; 0 = keine Wünsche) | höchstens so viele Wünsche in 7 Tagen (rollierend) | **Server** (429 bzw. 403) |
| Überspringen | `skips_requires_premium`, `free_skips_per_hour` (Standard 6, 1–100) | höchstens so oft pro Stunde „Weiter“ | **nur App** (ältere Apps zählen nicht mit, Neuinstallation setzt zurück, Antippen eines Titels in einer Liste und App-Start ohne Verbindung zählen nicht) |
| Auf anderen Geräten abspielen | `remote_requires_premium` | jedes Gerät spielt nur für sich: kein Übertragen, kein Fernsteuern, kein automatisches Anhalten des anderen Geräts (Geräte-Liste ausgegraut mit Hinweis) | **Server** (Prüfung beim Verbinden und alle 25 s; nach Änderungen im Dashboard sofort) – siehe [Auf anderen Geräten abspielen](#auf-anderen-geräten-abspielen) |
| Premium-Abzeichen | `premium_badge_enabled` (Ein/Aus) | – (Premium-Nutzer sehen ein Abzeichen in ihrem Profil) | App |

**Codes mit Teilumfang** enthalten „Auf anderen Geräten abspielen“ nur, wenn es beim Erzeugen angehakt war. Codes
und Lizenzen mit „Alle Leistungen“ (auch alle von vor diesem Update) enthalten es automatisch; ältere Codes mit
Teilumfang dagegen nicht – steht die Zeile auf „Nur Premium“, können deren Besitzer nicht fernsteuern. Ältere Apps
zeigen in diesem Fall auf der Premium-Seite womöglich eine leere Zeile „Mit Premium: “ (nur Kosmetik).

Weitere Einstellungen:

| Einstellung | Wirkung |
|-------------|---------|
| **Offline-Hören: Nur Premium** (Karte „Premium-Leistungen“, Schlüssel `offline_requires_premium`) | Ohne Premium lässt sich nichts mehr aufs Gerät laden; vorhandene Offline-Musik wird vom Gerät gelöscht, sobald die App den Stand beim Server geprüft hat. Gilt für alle App-Ausgaben (Play, GitHub, Windows, iPhone), **aber erst ab der App-Version, die die Sperre kennt** – ältere Apps laden weiter und löschen nie (dafür die nächste Zeile). **Admins sind ausgenommen.** Gib Familie und Freunden Premium, *bevor* du einschaltest |
| **Sperre durchsetzen ab App-Build** (`offline_min_client_build`) | Standard 0 = aus; wirkt nur, solange der Schalter darüber an ist. Benutzer **ohne Premium**, deren App eine kleinere Build-Nummer hat (oder keine meldet, Header `X-Selfify-Client`), bekommen vom Server keine Musik mehr (HTTP 426 beim Abspielen/Laden) und sehen „Bitte aktualisiere die App.“ Premium-Nutzer und Admins sind nie betroffen. Trag die Build-Nummer der ersten App-Version mit Offline-Sperre ein, sobald sie verteilt ist (*Geräte & Versionen* zeigt, wer welche hat) |
| **Gnadenfrist ohne Verbindung (Tage)** | Standard 7 (1–30). So lange bleibt Offline-Musik spielbar, wenn die App den Server nicht erreicht – gerechnet ab der letzten erfolgreichen Prüfung. Danach wird gesperrt und gelöscht |
| **Überschrift, Beschreibung, Vorteile** | Texte der Premium-Seite in der App (Vorteile: eine Zeile je Vorteil, höchstens 8). Leer = Standardtexte |
| **Premium in der Play-Version zum Kauf anbieten** | Abo über Google Play Billing, nur in der Play-Version. Braucht die **Produkt-ID des Abos** (wie in der Play Console, mehrere mit Komma) und die eingerichtete Kaufprüfung (Schlüsseldatei, „Verbindung testen“). **Der Preis wird in der Play Console festgelegt** und von der App aus dem Store angezeigt |
| **Laufzeiten** (`billing_base_plans`, `billing_recommended_plan`) | Kennungen der Basis-Abos (z. B. `monatlich,halbjaehrlich,jaehrlich`, höchstens 6) in Anzeigereihenfolge und optional eine „Empfohlen“-Markierung. Leer = die App zeigt alle Laufzeiten, die Google liefert (kürzeste zuerst). Die App zeigt je Laufzeit den echten Preis, „entspricht … pro Monat“, „spare … %“ gegenüber monatlich (abgerundet) und ein Angebot von Google (z. B. Gratis-Monat), wenn es eins gibt. Laufzeit wechseln geht in der App; der Server verbucht den neuen Kauf über `linkedPurchaseToken` |

- **Löschen vom Gerät:** Läuft Premium ab (Abo gekündigt und abgelaufen, Kauf widerrufen, von dir entzogen, Code
  abgelaufen oder gesperrt), löscht die App die Offline-Musik, sobald der Server das bestätigt. Ist der Stand nur *unbekannt*
  (kein Netz, Server oder Google gestört), wird nichts gelöscht, solange die Gnadenfrist läuft. Kommt Premium
  wieder, lädt der Benutzer seine Musik neu.
- **Deinstallation:** Unter Android liegt die Offline-Musik im privaten Speicher der App und verschwindet mit ihr;
  die Google-Sicherung und der Geräteumzug sichern nur die Einstellungen, keine Dateien. Unter Windows löscht der
  Deinstaller den Offline-Ordner. Das iPhone sichert die Offline-Musik dagegen mit in iCloud.
- **Kauf, Code und Vergabe zählen gleich** – auch für das Offline-Hören (ein Code nur mit dem Umfang, den er hat).
  Ein Code mit allen Leistungen hängt sich während eines laufenden Abos hinter das aktuelle Abo-Ende; verlängert
  Google danach, überlappen sich die Zeiten (Codes also besser erst nach der Kündigung einlösen). Endet das Abo
  vorzeitig, beginnt die Code-Zeit sofort. Ein Code mit Teilumfang läuft dagegen sofort ab dem Einlösen (ein Abo
  enthält ja schon alles). Unbegrenztes Premium mit allen Leistungen schlägt alles.
- **Kaufprüfung:** Der Server prüft jeden Kauf bei Google (ein Kauf = ein Konto) und fragt laufende Abos erneut ab,
  wenn die App den Premium-Stand holt – höchstens alle `PLAY_RECHECK_HOURS` Stunden, rund um das Enddatum öfter.
  Kündigung und Ablauf beenden Premium von selbst (bei Kündigung zum Ende des bezahlten Zeitraums). Eine
  **Erstattung beendet Premium nur, wenn Google dabei den Zugang widerruft** – erstattest du in der Play Console nur
  das Geld, bleibt das Abo bis zum Ende des Zeitraums aktiv; zum sofortigen Beenden zusätzlich im Dashboard
  entziehen. Sofort nachsehen: *Premium-Codes › Käufe über Google Play › Neu prüfen*.
- **Bestätigung des Kaufs:** Google erstattet einen Kauf, den niemand bestätigt (nach 3 Tagen, Testkäufe nach
  Minuten). Bestätigt wird vom Server und zusätzlich von der App auf dem Gerät – dass keine Erstattungs-Mail kommt,
  beweist also nicht, dass das Dienstkonto des Servers bestätigen darf. Scheitert der Server, steht im Protokoll
  „Kauf … konnte bei Google nicht bestätigt werden“ und in der Kaufliste ein Hinweis (Prüfung: `docs/PLAYSTORE.md`,
  Schritt 10.7).
- **Unklarer Stand statt „kein Premium“:** Ist der bezahlte Zeitraum gerade um und die Verlängerung bei Google noch
  nicht verbucht, gilt der Stand bis zu einer Stunde als *unbekannt* (auch kein HTTP 426 für Abonnenten). Kennt
  Google einen bekannten Kauf plötzlich nicht mehr (Antwort 400/404 – oft ein falscher `PLAY_PACKAGE_NAME`), gilt
  er bis 3 Tage nach dem bezahlten Ende als *unbekannt* und erst dann als beendet; der Hinweis steht in der Kaufliste.
- **Mehrere Konten an einem Gerät:** Musik, die bei eingeschalteter Sperre geladen wurde, wird bei **jedem** Wechsel
  des Kontos oder des Servers vom Gerät gelöscht – auch wenn das neue Konto Premium hat. Ohne die Sperre gehört die
  Offline-Musik wie bisher zum Gerät und bleibt beim Wechsel liegen.
- **Entziehst du** gekauftes Premium im Dashboard, läuft das Abo bei Google weiter – in der Play Console erstatten
  oder kündigen.
- **Schlüsseldatei:** Die Kaufprüfung braucht den JSON-Schlüssel eines Google-Dienstkontos als Datei im Datenordner
  (`/mnt/user/appdata/selfify/play-service-account.json`). Nie weitergeben, nie ins Repository, nie in einen Chat.
- Die Sperre sitzt in der App; ein Kopierschutz ist sie nicht (der Server kann Offline-Laden nicht vom Abspielen
  unterscheiden). Gegen ältere Apps, die die Sperre nicht kennen, hilft nur „Sperre durchsetzen ab App-Build“.
- **Zurück auf die vorherige Server-Version:** erst die Schalter aus, dann mit der noch laufenden neuen Version
  `docker exec -u 99:100 selfify alembic downgrade 0007` (Version vor Premium Teil 2: Lizenzen mit Teilumfang werden
  dabei zu vollem Premium) bzw. `… downgrade 0006` (vor dem Kauf über Google Play: Lizenzen aus Käufen werden
  beendet, das Abo bei Google läuft weiter), dann das alte Image. Schritt für Schritt: `docs/PLAYSTORE.md`,
  Schritt 10.12.

Die ganze Einrichtung Schritt für Schritt (Play Console mit drei Laufzeiten und Angeboten, Dienstkonto, Testkäufe,
Premium-Leistungen, Gebühren, was ungeprüft ist):
**[docs/PLAYSTORE.md](docs/PLAYSTORE.md), Schritt 10.**

**Pflichtseiten für den Play Store:** `/datenschutz`, `/impressum` und `/konto-loeschen` (der Benutzer kann
sein Konto auch ohne App löschen). Trage dafür `OPERATOR_NAME`, `OPERATOR_ADDRESS` und `OPERATOR_EMAIL` ein –
die Texte sind eine Vorlage und ersetzen keine Rechtsberatung. Alle diese Seiten laden nur eigene Dateien
(strenge Content-Security-Policy, kein Inline-Code); Texte von Benutzern werden nur als Text angezeigt.

### Selbst-Registrierung und Rubriken freigeben

Standardmäßig legst nur du (bzw. ein Admin) Konten an – daran ändert sich nichts, solange du nichts einstellst.
Unter *App-Einstellungen › Registrierung* wählst du, **wer Konten anlegen darf**:

| Modus | Was passiert |
|-------|--------------|
| **Aus** (Standard) | Nur Admins legen Konten an. Die App zeigt keinen Knopf „Konto erstellen“, `POST /api/auth/register` antwortet mit 404. |
| **Mit Freigabe** | Jeder, der die Adresse deines Servers kennt, kann in der App ein Konto erstellen. Es **wartet**, bis du es freischaltest; vorher ist keine Anmeldung möglich (die App zeigt „Dein Konto wartet noch auf Freischaltung durch den Betreiber.“). |
| **Offen** | Neue Konten sind sofort nutzbar. Das Dashboard fragt vor dem Umschalten nach – jeder mit der Adresse kann dann ohne dich ein Konto anlegen und die Rubriken für neue Konten hören. |

- **Rubriken für neue Konten:** Häkchen-Liste derselben Karte. Diese Rubriken bekommt jedes selbst erstellte Konto
  automatisch. Ohne Auswahl sieht ein neues Konto **nichts**, bis du ihm Rubriken freigibst (die App zeigt dann
  „Noch nichts freigeschaltet“).
- **Freischalten und Ablehnen** (*Benutzer*, Filter „Wartend (n)“, die Zahl steht auch am Menüpunkt):
  „Freischalten…“ öffnet die Rubriken-Auswahl (vorbelegt mit den Rubriken des Kontos) und schaltet das Konto damit
  frei. „Ablehnen“ **löscht** das Konto sofort und endgültig – einen Zustand „abgelehnt“ gibt es nicht. Wer noch
  wartet, kann seine Registrierung in der App („Registrierung zurückziehen“) oder unter `/konto-loeschen` selbst
  zurückziehen.
- **Rubriken je Benutzer:** „Rubriken…“ bei jedem Nicht-Admin: „Alle Rubriken (auch künftige)“ oder „Nur
  ausgewählte“. Die Änderung wirkt beim Server sofort, auch für angemeldete Geräte (die App zeigt neue Rubriken nach
  dem Aktualisieren). Spalte „Rubriken“: „Alle (Admin)“, „Alle“, „keine“ oder „k von m“.
- **Bestandskonten sehen weiter alles:** Beim Update bekommen alle vorhandenen Konten „Alle Rubriken“. Konten, die
  du unter *Benutzer anlegen* erstellst, ebenfalls. **Admins sehen immer alles**, egal was eingestellt ist.
- **Eingeschränkte Konten** sehen nur Titel aus ihren Rubriken – in Listen, Suche, Zählern, Startseite, Mixen,
  Verlauf, Favoriten, Playlists, Stream, Cover und Songtexten. Alles andere antwortet so, als gäbe es es nicht (404).
  Ein Album oder Künstler erscheint, sobald mindestens ein Titel davon sichtbar ist. Ein Filter auf eine verborgene
  Rubrik (`category_id`) ergibt überall leere Ergebnisse, wie bei einer Rubrik, die es nicht gibt. Die Zähler des
  Scans (`/library`, `/library/scan`: gesehene, neue, geänderte, entfernte und fehlerhafte Dateien) stehen für sie auf
  0, weil sie für die ganze Sammlung gelten; „Entfernen“ von Likes, gespeicherten Alben und gefolgten Künstlern
  antwortet immer mit 204, auch für IDs, die es nicht gibt.
- **Gelöschte Rubriken** verschwinden automatisch aus den „Rubriken für neue Konten“ – eine später angelegte Rubrik
  mit derselben Nummer wird also nicht ungewollt an neue Konten freigegeben.
- **Offline auf dem Gerät:** Entziehst du einem eingeschränkten Konto eine Rubrik, löscht die App deren Titel vom
  Gerät, sobald sie das Konto neu geladen hat (beim Start, beim Aktualisieren). Sie verschwinden aus gespeicherten
  Alben und Playlists; Sammlungen, die dadurch leer werden, fallen ganz weg. Bis dahin spielt die App sie schon nicht
  mehr vom Gerät ab. Liefert der Server beim Abgleich einer gespeicherten Sammlung 404 (gelöscht oder nicht mehr
  sichtbar), entfernt die App die Sammlung vom Gerät.
- **Selbst registrierte Konten** dürfen nichts von YouTube laden (kein Download-Recht, auch die YouTube-Suche ist
  gesperrt – die App zeigt ihnen deshalb in der Suche keinen YouTube-Bereich) und sehen keine Admin-Bereiche. Das Download-Recht kannst du ihnen wie jedem Benutzer geben; sie laden
  dann nur in Rubriken, die sie sehen.
- **Schutz vor Missbrauch:** höchstens **5 Registrierungsversuche je Anschluss und Stunde** (IPv4: je Adresse,
  IPv6: je /64-Netz, weil ein Anschluss dort meist ein ganzes /64 hat; auch fehlgeschlagene Versuche zählen; die
  Zählung liegt nur im Speicher und beginnt nach einem Neustart von vorn), höchstens **20 neue selbst registrierte
  Konten je Stunde** insgesamt – auch im Modus „Offen“ (danach 503 „Gerade werden sehr viele neue Konten
  angelegt …“) – und höchstens **50 wartende Konten** gleichzeitig (danach 503, bis du freischaltest oder ablehnst). Reservierte Namen wie `admin`, `root`
  oder `support` sind gesperrt; die Meldung bei einem vergebenen Namen nennt den Namen nicht.

**Grenzfälle, die du kennen solltest:**

- Cover von Alben und Künstlern sowie die Sortierung nach Beliebtheit können aus der ganzen Sammlung stammen, also
  Titel aus verborgenen Rubriken mitzählen.
- Ein Wunsch, den du als „erledigt“ markierst, zeigt beim Benutzer „erledigt“, auch wenn der geholte Titel in einer
  Rubrik liegt, die er nicht sieht. Hol Wünsche eingeschränkter Benutzer in eine Rubrik, die sie sehen.
- Verborgene Likes, Verlaufseinträge und gespeicherte Alben werden nicht gelöscht, nur ausgeblendet. Gibst du die
  Rubrik später frei, sind sie wieder da.
- In geteilten Playlists sehen andere Benutzer deinen Anzeigenamen (steht so auch in der Datenschutzerklärung).
  Eine fremde Playlist zeigt eingeschränkten Konten nur die sichtbaren Titel (Länge und Dauer passend dazu).
- Offline-Speichern aufs Gerät hängt an Premium bzw. der Offline-Regel, **nicht** am Download-Recht. Steht
  Offline-Hören auf „Für alle“, kann also auch ein selbst registriertes Konto ohne Premium speichern – aber nur
  sichtbare Titel.
- **Ältere Apps** kennen die Registrierung nicht (kein Knopf). Wartende Konten sehen dort beim Anmelden trotzdem
  die Server-Meldung; eingeschränkte Konten sehen leere Listen mit den alten Leertexten.
- **Zurück auf die vorherige Server-Version:** erst Registrierung „Aus“, wartende Konten ablehnen, dann
  `docker exec -u 99:100 selfify alembic downgrade 0008` und das alte Image. Rubriken-Freigaben gehen dabei
  verloren (danach sieht jedes Konto wieder alles); noch wartende Konten blieben als gesperrte Konten stehen.

---

## Auf anderen Geräten abspielen

Wie „Spotify Connect“: Du siehst in der App alle Geräte, auf denen du mit **demselben Konto** angemeldet bist, und
kannst die Wiedergabe dorthin übertragen oder das andere Gerät fernsteuern – z. B. am Handy aussuchen, am PC hören.

**Was geht**

- **Geräte-Liste:** Knopf „Geräte“ im Mini-Player, im Vollbild-Player (neben „Warteschlange“) und am PC in der
  Player-Leiste. Die Liste zeigt das eigene Gerät („Dieses Gerät“), das gerade spielende („Spielt gerade“) und alle
  weiteren verbundenen Geräte mit Symbol für PC, Handy oder Tablet.
- **Übertragen:** Antippen eines anderen Geräts. Das bisherige Gerät hält an, das neue spielt an derselben Stelle
  weiter – mit Warteschlange, Zufallsreihenfolge, Wiederholen und „Wird gespielt von …“. Klappt es auf dem Ziel
  nicht (z. B. Titel dort nicht offline verfügbar), spielt das alte Gerät weiter und die App zeigt den Grund.
- **Fernsteuern:** Spielt ein anderes Gerät, steuert diese App es: Abspielen/Pause, Weiter, Zurück, Spulen, Zufall,
  Wiederholen, Titel oder Album antippen, „Als Nächstes spielen“, „Zur Warteschlange“, Radio, Warteschlange
  (springen, entfernen, verschieben, leeren). Ist das Ziel ein PC, gibt es im Vollbild-Player des Handys und in der
  Player-Leiste am PC einen Lautstärke-Regler für den PC (die Lautstärketasten des Handys regeln weiter nur das
  Handy). Tastenkürzel und
  Medientasten am PC steuern dann ebenfalls das andere Gerät. Eine schmale Leiste „Spielt auf …“ zeigt, wohin die
  Befehle gehen.
- **Live-Anzeige:** Titel, Cover, Fortschritt und Warteschlange des anderen Geräts laufen mit.
- **Zurückholen:** in der Geräte-Liste auf „Dieses Gerät“ tippen.
- **Umbenennen:** in der Geräte-Liste neben dem eigenen Gerät oder unter *Einstellungen › Angemeldete Geräte* →
  „Umbenennen“. Der Name ist derselbe wie in der Sitzungsverwaltung.
- **Wer zuletzt Play drückt, gewinnt:** Startest du auf einem zweiten Gerät etwas, hält das erste automatisch an
  (nur für Geräte mit der neuen App, siehe unten).

**Voraussetzungen:** Server und App mindestens in der Version mit dieser Funktion (der Server meldet sie in
`GET /api/server` als `features: ["connect"]`; fehlt das, zeigt die App keinen Geräte-Knopf), WebSockets am
Reverse Proxy an, auf allen Geräten dasselbe Konto. Ein gemeinsames WLAN ist **nicht** nötig: Alle Geräte reden nur
mit deinem Server, jedes Zielgerät lädt die Musik selbst über seine eigene Verbindung (mit seinen eigenen
Einstellungen: Tonqualität, Offline-Dateien, iPhone-Umwandlung). Eine Direktverbindung im Heimnetz gibt es nicht.

**Premium:** Unter *App-Einstellungen › Premium-Leistungen* gibt es die Zeile „Auf anderen Geräten abspielen“
(Standard „Für alle“). Steht sie auf „Nur Premium“, sieht ein Konto ohne Premium die Geräte ausgegraut mit dem
Hinweis „Auf anderen Geräten abspielen gibt es nur mit Premium.“; der Server lehnt jeden Befehl ab und hält auch
kein Gerät mehr automatisch an – jedes Gerät spielt dann nur für sich. Durchgesetzt wird das vom **Server**.

**Grenzen – bitte kennen:**

- **Handys und Tablets erscheinen nur, solange die App geöffnet ist oder Musik spielt.** Geht die App in den
  Hintergrund und spielt nichts, trennt sie nach 10 Sekunden. Grund: Android hält die App im Hintergrund nur am
  Leben, solange sie Musik abspielt (Vordergrund-Dienst für Medienwiedergabe), das iPhone friert die Verbindung ohne
  laufenden Ton ein. Ein Dauer-Dienst nur fürs Erreichbarbleiben würde den Akku leeren – Spotify macht das auch
  nicht. Der PC bleibt verbunden, solange die App offen ist.
- **Ein pausiertes Handy in der Tasche lässt sich also nicht vom PC aus starten.** Erst die App öffnen.
- **Kein Speicher über Neustarts:** Der Server hält alles nur im Arbeitsspeicher. Nach einem Neustart melden sich
  die Geräte von selbst wieder an; was gerade spielt, ist sofort wieder „aktiv“, ein pausierter Stand ist weg.
  Bricht die Verbindung des spielenden Geräts ab, bleibt es 60 Sekunden als „aktiv“ stehen (Netzwechsel), sein
  letzter Stand bleibt 30 Minuten zum Übertragen erhalten. Das passiert auch, wenn ein pausiertes Handy in den
  Hintergrund geht. In dieser Zeit steuern die anderen Geräte es **nicht** fern (es ist ja nicht erreichbar): Wer am
  PC Play drückt, spielt am PC; „Weiterhören“ vom letzten Stand des Handys geht über die Geräte-Liste.
- **Netzwechsel:** Wechselt das Handy das Netz (WLAN ↔ Mobilfunk), baut die App die Geräte-Verbindung sofort neu
  auf. Startet die App ohne Netz oder während der Server neu startet, fragt sie später von selbst wieder nach.
- **Gelöschte Konten:** Wird ein Konto gelöscht, vergisst der Server auch dessen Geräte-Stand sofort – ein neues
  Konto, das dieselbe Benutzer-Nummer bekommt, sieht davon nichts.
- **Nur ein Server-Prozess:** Die Geräte-Verwaltung liegt im Speicher **eines** uvicorn-Prozesses. Starte den
  Container nicht mit mehreren Workern (keine Zusatzargumente wie `--workers` an `entrypoint.sh` bzw. den
  Container-Befehl übergeben) – sonst sehen sich Geräte, die an verschiedenen Prozessen hängen, nicht.
- **Lautstärke** lässt sich nur bei einem PC als Ziel fernsteuern (von jedem Gerät aus). Handy und iPhone haben
  keine eigene Lautstärke in der App.
- **Überspringen ohne Premium** zählt auf dem Gerät, das spielt: „Weiter“ vom Handy aus verbraucht das Kontingent
  des PCs, wenn der PC spielt; der Hinweis erscheint auf beiden.
- **Das Web-Dashboard ist kein Wiedergabe-Gerät** und erscheint nicht in der Liste.
- **Videos** werden nie ferngestartet; landet ein Video in einer ferngesteuerten Warteschlange, läuft es wie bisher
  als Ton. Geschwindigkeit und Schlaf-Timer gibt es nur für die Wiedergabe auf dem eigenen Gerät.
- **Ältere Apps** verbinden sich nicht: Sie erscheinen nicht in der Liste und werden auch nicht automatisch
  angehalten. Windows-PCs ohne funktionierende Wiedergabe (libmpv fehlt) erscheinen ausgegraut mit „Kann gerade
  nicht abspielen“.
- **Sehr lange Warteschlangen:** Übertragen und angezeigt werden höchstens 1000 Titel (um den aktuellen herum);
  wer ferngesteuert in einer längeren Liste einen Titel antippt, schickt 1000 Titel um den gewählten herum.
  Springen, Entfernen und Verschieben treffen trotzdem den richtigen Titel (das Zielgerät prüft, ob dort noch der
  gemeinte Titel steht; hat sich die Warteschlange gerade geändert, kommt „Die Warteschlange hat sich gerade
  geändert. Bitte noch einmal versuchen.“). Die Vorschau „Als Nächstes“ auf dem steuernden Gerät zeigt höchstens 50. Bei „Alle wiederholen“ zeigt sie am Ende
  der Liste nicht wieder den Anfang.
- **Sichtbarkeit:** Ein eingeschränktes Konto kann auch über ein anderes Gerät nur Titel aus seinen Rubriken
  abspielen; der Server filtert jede Titelliste. Nimmt der Admin einem Konto eine Rubrik weg, verschwinden deren
  Titel sofort auch aus der Anzeige der anderen Geräte. Nur Geräte desselben Kontos sehen und steuern sich – auch
  Admins sehen keine fremden Geräte.
- **Token im Log:** Die App meldet sich im Header an. Ein Token im Link (`?token=…`, für andere Clients) schreibt
  der Server nicht ins Log (`token=***`).
- **Abmelden wirkt sofort:** Meldest du ein Gerät ab (*Angemeldete Geräte* oder Abmelden in der App), änderst
  das Passwort, löschst, sperrst oder setzt du ein Konto zurück, trennt der Server die Geräte-Verbindung sofort.
  Wird ein Anmelde-Token missbraucht und deshalb gesperrt, merkt der Server das bei der regelmäßigen Prüfung
  spätestens nach 25 Sekunden.

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
| `YTMUSIC_LANGUAGE` / `YTMUSIC_LOCATION` | `en` / `DE` | Sprache/Land der YouTube-Music-Suche. Die Sprache bitte auf `en` lassen – mit anderen Sprachen findet die Suche nichts |
| `LYRICS_ENABLED` | `true` | Songtexte beim Download mitladen |
| `LOGIN_MAX_FAILURES_PER_USER` | `10` | Fehlversuche je Benutzer, bevor der Login kurz gesperrt wird |
| `LOGIN_MAX_FAILURES_PER_IP` | `30` | Fehlversuche je IP-Adresse |
| `LOGIN_WINDOW_MINUTES` | `15` | Zeitfenster bzw. Sperrdauer |
| `ENABLE_API_DOCS` | `true` | Test-Oberfläche unter `/api/docs` (ohne Login nutzlos) |
| `DASHBOARD_ENABLED` | `true` | Verwaltungsseite unter `/dashboard` (`false` = abgeschaltet; die Daten dahinter sind ohnehin nur für Admins) |
| `OPERATOR_NAME` / `OPERATOR_ADDRESS` / `OPERATOR_EMAIL` | leer | Betreiberangaben für `/datenschutz` und `/impressum` (Pflicht, sobald die App öffentlich angeboten wird) |
| `PLAY_SERVICE_ACCOUNT_FILE` | `/data/play-service-account.json` | Nur für den Kauf in der Play-Version: JSON-Schlüssel des Google-Dienstkontos (Pfad im Container). Fehlt die Datei, ist der Kauf aus. **Geheim** – nur als Datei auf dem Server |
| `PLAY_PACKAGE_NAME` | `de.selfify.selfify.play` | Paketname der Play-Version (für die Kaufprüfung bei Google) |
| `PLAY_RECHECK_HOURS` | `12` | So oft wird ein laufender Kauf höchstens neu bei Google geprüft (1–168) |
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
| System | `GET /health`, `GET /server` (mit `registration_mode`: `off`/`approval`/`open` und `features`: `["connect"]` = Server kann „Auf anderen Geräten abspielen“) |
| Anmeldung | `POST /auth/login` (wartendes Konto: **403** mit Header `X-Selfify-Account-State: pending`), `POST /auth/refresh`, `POST /auth/logout` |
| Registrierung | `POST /auth/register` {username, password, display_name?, device_name?} (ohne Login): **201** mit Tokens (Modus offen), **202** (wartet auf Freigabe), 404 (Modus aus), 409, 422, 429, 503; `POST /auth/withdraw` {username, password}: wartende Registrierung zurückziehen (**204**, 401, 409, 429) |
| Mein Konto | `GET/PATCH /me`, `POST /me/password`, `GET /me/sessions`, `PATCH /me/sessions/{id}` {device_name} (eigenes Gerät umbenennen, 1–100 Zeichen; 404 „Gerät nicht gefunden.“, 422 bei leerem Namen), `DELETE /me/sessions/{id}` |
| Benutzer (Admin) | `GET/POST /users`, `GET/PATCH/DELETE /users/{id}` (Felder `all_categories`, `category_ids`; `PATCH {is_active: true}` schaltet ein wartendes Konto frei, `DELETE` lehnt ab) |
| Rubriken | `GET /categories` (alle bzw. bei eingeschränkten Konten nur die freigegebenen, inkl. Anzahl Titel), `POST /categories`, `PATCH/DELETE /categories/{id}` (Admin) |
| Bibliothek | `GET /artists`, `GET /artists/{id}`, `GET /albums`, `GET /albums/{id}`, `GET /tracks`, `GET /tracks/{id}` |
| Suche | `GET /search?q=…` – Top-Treffer, Songs, Künstler, Alben, Videos (findet „Ärzte“ auch als „aerzte“) |
| Scan | `GET /library` (Statistik), `GET /library/scan` (Status), `POST /library/scan` (Admin) |
| Streaming | `GET /tracks/{id}/stream` (Spulen per Range; `quality`, `compatible`, `audio_only`; **426** „Bitte aktualisiere die App.“, wenn `offline_min_client_build` gilt und die App ohne Premium zu alt ist; steht „Höhere Tonqualität“ auf „Nur Premium“, wird `quality` ohne Premium **still** auf `free_audio_quality` gedeckelt; steht „Videos ansehen“ auf „Nur Premium“, liefert ein Video ohne `audio_only=true` ohne Premium **403** „Videos ansehen gibt es nur mit Premium. Als Ton kannst du sie weiter abspielen.“), `GET /covers/{id}?size=64\|128\|300\|600` |
| Songtexte | `GET /tracks/{id}/lyrics` (zeitsynchron, wenn vorhanden; **403** „Songtexte gibt es nur mit Premium.“, wenn „Songtexte“ auf „Nur Premium“ steht) |
| Playlists | `GET/POST /playlists`, `GET/PATCH/DELETE /playlists/{id}`, `POST …/items`, `POST …/items/remove`, `POST …/items/move`, `PUT/DELETE …/cover`, `PUT/DELETE …/follow` |
| Persönlich | `GET /home`, `GET /me/library`, `GET /me/likes`, `GET /me/likes/ids`, `PUT/DELETE /me/likes/{track}`, `PUT/DELETE /me/albums/{id}`, `PUT/DELETE /me/artists/{id}` |
| Verlauf | `POST /me/history`, `GET /me/history`, `DELETE /me/history`, `GET /me/recent`, `GET /me/top-tracks` |
| Mixe & Radio | `GET /mixes/{genre:Rock\|discover\|artist:ID\|category:ID\|recent}`, `GET /tracks/{id}/radio` |
| YouTube | `GET /youtube/search?q=…&type=songs\|videos\|albums`, `GET /youtube/albums/{browseId}` |
| Downloads | `POST /downloads`, `POST /downloads/album`, `POST /downloads/url`, `GET /downloads`, `POST /downloads/{id}/cancel\|retry`, `DELETE /downloads/{id}` |
| Live-Fortschritt | WebSocket `/api/downloads/ws?token=<access_token>` – `snapshot`, dann `job`-Ereignisse (eigene Downloads; Admins mit `&scope=all` alle) |
| Geräte-Steuerung | WebSocket `/api/connect/ws` – Anmeldung per Header `Authorization: Bearer <access_token>` (ersatzweise `?token=`, im Log unkenntlich), Protokoll Version 1 mit JSON-Nachrichten: App → Server `hello`, `state`, `cmd`, `ack`, `auth`, `ping`; Server → App `welcome`, `devices`, `state`, `exec`, `result`, `access`, `auth_ok`, `ping`. Close-Codes: 4001 Anmeldung erneuern, 4400 ungültige Nachricht/Protokoll, 4401 nicht angemeldet, 4408 keine Antwort, 4409 auf diesem Gerät neu verbunden, 4429 zu viele Nachrichten/Geräte, 1001 Server fährt herunter. Nur Geräte desselben Kontos |
| Admin | `DELETE /tracks/{id}?delete_file=true`, `GET /downloads-system`, `POST /downloads-system/update` |
| App-Konfiguration | `GET /app/config?channel=play&build=54` (ohne Login): Schalter, Update-Stufe, Wartungshinweis, Datenschutz-Links, Offline-Regel (`offline_requires_premium`, `offline_grace_days`, `offline_min_client_build`), Premium-Leistungen (`premium_only`, `free_audio_quality`, `free_requests_per_week`, `free_skips_per_hour`, `premium_badge_enabled`), Kauf (`billing_enabled`, `billing_product_ids`, `billing_base_plans`, `billing_recommended_plan`), Premium-Texte, `registration_mode` |
| Premium | `GET /premium` (Stand samt `features` = freigeschaltete Leistungen, `premium_only`, `locked` = was dieser Benutzer gerade nicht darf, `badge`, `offline_allowed`, `checked_at`, Abo `play` mit `base_plan_id`/`offer_id`; 503 = gerade nicht prüfbar), `POST /premium/redeem` {code}, `POST /premium/play/verify` {product_id, purchase_token} (Kauf oder Wiederherstellung melden) |
| Wünsche & Fehler melden | `POST/GET /requests` (mit Wochengrenze ohne Premium: **429** „Du hast diese Woche schon … Wünsche geschickt. …“, bei Grenze 0 **403**), `GET /requests/quota` (`limited`, `limit`, `used`, `left`, `resets_at`), `DELETE /requests/{id}`, `POST /bugreports` |
| Konto löschen | `POST /me/delete` {password} |
| Dashboard (Admin) | `GET /admin/stats` (mit `users_pending`), `/admin/users` (mit `all_categories`, `category_ids`, `approval_pending`, `self_registered`), `/admin/clients`, `GET/PUT /admin/config` (mit `registration_mode`, `registration_default_categories` = Rubrik-IDs mit Komma), `/admin/premium/codes` (Feld `features`: Liste der Leistungen oder `null` = alle), `/admin/premium/licenses` (mit `features`), `GET /admin/premium/purchases`, `POST /admin/premium/purchases/{id}/recheck`, `GET /admin/billing/status`, `POST /admin/billing/test`, `/admin/users/{id}/premium`, `/admin/requests`, `/admin/bugreports` |

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
flutter run --flavor full           # Android-Handy/Emulator angeschlossen (GitHub-Version)
flutter run --flavor play --dart-define=CHANNEL=play   # Android: die Play-Version (ohne YouTube)
flutter run --flavor play --dart-define=CHANNEL=play --dart-define=SERVER_URL=https://musik.example.de   # … mit fester Server-Adresse
flutter run -d windows # auf einem Windows-PC (Visual Studio mit „Desktopentwicklung mit C++“ und
                       # unter Windows „Entwicklermodus“ eingeschaltet – nötig für die Plugins)
```

Aufbau: `lib/data` (Modelle, Server-Client), `lib/state` (Anmeldung, Einstellungen, Downloads,
Offline-Speicher, Server-Einstellungen/Premium), `lib/player` (Hintergrund-Wiedergabe), `lib/ui` (Navigation,
Bildschirme, Bausteine), `lib/ads` (Werbung, nur Play-Version), `lib/billing` (Kauf über Google Play, nur
Play-Version), `lib/core/flavor.dart` (welche Version läuft).

Android hat zwei **Flavors**: `full` (GitHub-Version) und `play` (Google Play, Paketname `….play`). Ohne `--flavor`
bricht ein Android-Bau ab. Windows und iPhone brauchen keinen Flavor und sind immer die GitHub-Version.

**Werbe-SDK und Kauf-Bibliothek nur in der Play-Version:** Das Paket `google_mobile_ads` bringt native Dienste mit,
die beim App-Start laufen – mit ihm startete die GitHub-App am Handy nicht mehr. Deshalb ersetzt die CI es in allen
Versionen ohne Werbung (GitHub-APK, Windows, iPhone) durch einen Platzhalter
(`mobile/packages/google_mobile_ads_stub`). Dasselbe gilt für `in_app_purchase` (Google Play Billing) und
`in_app_purchase_android` (Laufzeiten, Angebote, Wechsel der Laufzeit): Gekauft wird nur in der Play-Version, alle
anderen bekommen `mobile/packages/in_app_purchase_stub` und `mobile/packages/in_app_purchase_android_stub`. Die CI prüft, dass in der
GitHub-APK weder Werbe-SDK noch Billing stecken und dass im Play-Bundle das echte Kauf-Bauteil steckt (Plugin
`in_app_purchase_android`, Billing-Bibliothek und Berechtigung – nicht der Platzhalter). Für einen lokalen Bau der
GitHub-Version legst du dieselbe Datei an (**nie einchecken** – sie steht in `mobile/.gitignore`, und der Play-Job
der CI bricht ab, wenn sie im Repository liegt):

```bash
cd mobile
printf 'dependency_overrides:\n  google_mobile_ads:\n    path: packages/google_mobile_ads_stub\n  in_app_purchase:\n    path: packages/in_app_purchase_stub\n  in_app_purchase_android:\n    path: packages/in_app_purchase_android_stub\n' > pubspec_overrides.yaml
flutter pub get && flutter run --flavor full
rm pubspec_overrides.yaml   # zurück zu den echten Paketen (Tests und Play-Version)
```

`lib/billing/play_gateway.dart` ist die einzige Datei, die `in_app_purchase` und `in_app_purchase_android` einbindet.
Nutzt sie einen neuen Namen aus einem der Pakete, muss der passende Platzhalter ihn auch kennen – sonst schlägt der zweite Analyse-Schritt der CI fehl.

---

## Rechtlicher Hinweis

Downloads von YouTube verstoßen gegen die Nutzungsbedingungen von YouTube. Selfify ist für die
**private Nutzung im eigenen Haushalt** gedacht. Biete heruntergeladene Inhalte nicht öffentlich an.
