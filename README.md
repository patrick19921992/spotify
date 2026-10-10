# Selfify – dein eigenes Spotify auf dem Unraid

Selfify funktioniert wie Spotify, nur mit deiner eigenen Musik: Bibliothek, Playlists, Lieblingssongs,
Offline-Modus und mehrere Accounts für die ganze Familie. Fehlt ein Song, holt der Server ihn in bester
verfügbarer Qualität von YouTube (Music), und die App zeigt dabei an, wie lange es noch dauert.

> **Arbeitstitel:** „Selfify“ ist nur ein Platzhalter und lässt sich später ändern.

| Teil | Ordner | Technik | Status |
|------|--------|---------|--------|
| Server (läuft auf Unraid) | `server/` | Python, FastAPI, SQLite, Docker | **Schritt 1 fertig:** Accounts, Login, Rubriken |
| Handy-App (Android + iOS) | `mobile/` | Flutter | geplant (Schritt 5–6) |

Was noch kommt und in welcher Reihenfolge: siehe [docs/ROADMAP.md](docs/ROADMAP.md).

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

## Installation (Stand Schritt 1, zum Ausprobieren)

Ein fertiges Image und eine Unraid-Vorlage („Add Container“) kommen in Schritt 7. Bis dahin baust du das
Image direkt aus diesem Repository.

**Variante A – Unraid-Plugin „Docker Compose Manager“**

1. Plugin über *Apps* installieren.
2. Unter *Docker → Compose* einen neuen Stack `selfify` anlegen.
3. Repository auf den Unraid klonen, z. B. nach `/mnt/user/appdata/selfify-src`, und dort
   `docker-compose.yml` verwenden (oder den Inhalt in den Stack kopieren und `build:` auf den Pfad
   `/mnt/user/appdata/selfify-src/server` setzen).
4. In der `docker-compose.yml` mindestens `PUBLIC_URL` anpassen, dann *Compose Up*.

**Variante B – Unraid-Terminal**

```bash
cd /mnt/user/appdata
git clone https://github.com/patrick19921992/spotify.git selfify-src
cd selfify-src
# PUBLIC_URL usw. in docker-compose.yml anpassen
docker compose up -d --build
docker logs selfify        # zeigt beim ersten Start das Admin-Passwort
```

Danach ist der Server unter `http://<unraid-ip>:8080` erreichbar. Zum Ausprobieren ohne App öffnest du
**`http://<unraid-ip>:8080/api/docs`**. Dort kannst du dich anmelden (*Authorize*) und alle Funktionen
direkt im Browser testen.

### Erster Login

- Ist `ADMIN_PASSWORD` leer, erzeugt der Server beim ersten Start ein sicheres Passwort und schreibt es
  **einmalig ins Log** (Unraid: Container-Symbol → *Logs*).
- Bitte nach dem ersten Login ändern: `POST /api/me/password`, später geht das in der App.
- Admin-Passwort vergessen? Siehe [Konsolen-Befehle](#konsolen-befehle).

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
| `LOGIN_MAX_FAILURES_PER_USER` | `10` | Fehlversuche je Benutzer, bevor der Login kurz gesperrt wird |
| `LOGIN_MAX_FAILURES_PER_IP` | `30` | Fehlversuche je IP-Adresse |
| `LOGIN_WINDOW_MINUTES` | `15` | Zeitfenster bzw. Sperrdauer |
| `ENABLE_API_DOCS` | `true` | Test-Oberfläche unter `/api/docs` (ohne Login nutzlos) |
| `FORWARDED_ALLOW_IPS` | private Netze | Von welchen Proxys die echte Client-IP übernommen wird |
| `SECRET_KEY` | leer | Leer = wird erzeugt und in `/data/secret.key` gespeichert |
| `DATA_DIR` / `MEDIA_DIR` | `/data` / `/media` | Pfade **im** Container (nicht ändern) |

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

Dazu einen DNS-Eintrag (bzw. DynDNS) für `musik.example.de` auf deine Internetadresse und im Router
Port 443 auf den Proxy weiterleiten.

**Sicherheit, weil der Server aus dem Internet erreichbar ist:**

- Es gibt **keine offene Registrierung**. Nur Admins legen Konten an.
- Passwörter werden mit Argon2 gespeichert, Logins nach zu vielen Fehlversuchen kurz gesperrt.
- Jedes Handy ist eine eigene „Sitzung“ und kann einzeln abgemeldet werden, z. B. wenn ein Handy verloren geht.
- Port `8080` **nicht** direkt im Router freigeben, immer nur über den Proxy mit HTTPS.

---

## Konsolen-Befehle

Im Unraid-Terminal (oder Container-Symbol → *Console*):

```bash
docker exec -u 99:100 selfify python -m app.cli list-users
docker exec -u 99:100 selfify python -m app.cli reset-password admin 'NeuesSicheresPasswort'
docker exec -u 99:100 selfify python -m app.cli create-user papa 'SicheresPasswort' --admin
```

`reset-password` aktiviert das Konto auch wieder und meldet alle Geräte dieses Benutzers ab.

---

## API-Überblick (Stand Schritt 1)

Alle Endpunkte liegen unter `/api`. Die genaue Beschreibung steht unter `/api/docs`.

| Bereich | Endpunkte |
|---------|-----------|
| System | `GET /health`, `GET /server` |
| Anmeldung | `POST /auth/login`, `POST /auth/refresh`, `POST /auth/logout` |
| Mein Konto | `GET/PATCH /me`, `POST /me/password`, `GET /me/sessions`, `DELETE /me/sessions/{id}` |
| Benutzer (Admin) | `GET/POST /users`, `GET/PATCH/DELETE /users/{id}` |
| Rubriken | `GET /categories` (alle), `POST /categories`, `PATCH/DELETE /categories/{id}` (Admin) |

Benutzer haben das Recht **`can_download`**. Damit legst du z. B. fest, dass die Kinder Songs hören,
aber keine neuen Downloads starten dürfen.

---

## Entwicklung

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

---

## Rechtlicher Hinweis

Downloads von YouTube verstoßen gegen die Nutzungsbedingungen von YouTube. Selfify ist für die
**private Nutzung im eigenen Haushalt** gedacht. Biete heruntergeladene Inhalte nicht öffentlich an.
