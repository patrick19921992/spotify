#!/bin/bash
# Selfify auf dem Unraid selbst bauen und (neu) starten.
#
# Für alle, die das fertige Image aus der GitHub Container Registry nicht nutzen können
# (z. B. privates Repository mit vollem Speicher). Läuft in der Unraid-Konsole oder als
# Skript im Plugin "User Scripts" (z. B. wöchentlich für Updates).
#
# Einmalig: GITHUB_TOKEN unten eintragen (nur nötig, solange das Repository privat ist).
# Token erstellen: GitHub → Settings → Developer settings → Fine-grained tokens →
# nur dieses Repository, Berechtigung "Contents: Read-only".

GITHUB_TOKEN=""
REPO="patrick19921992/spotify"
BRANCH="main"
SRC="/mnt/user/appdata/selfify-src"
# Deine Einstellungen (Domain, Passwort, Pfade …) – bleiben bei Updates erhalten
CONFIG="/mnt/user/appdata/selfify-config.yml"

set -euo pipefail

if [ -n "$GITHUB_TOKEN" ]; then
    URL="https://x-access-token:${GITHUB_TOKEN}@github.com/${REPO}.git"
else
    URL="https://github.com/${REPO}.git"
fi

if [ -d "$SRC/.git" ]; then
    echo "==> Quellcode aktualisieren"
    git -C "$SRC" remote set-url origin "$URL"
    git -C "$SRC" fetch --depth 1 origin "$BRANCH"
    git -C "$SRC" reset --hard "origin/$BRANCH"
else
    echo "==> Quellcode herunterladen nach $SRC"
    git clone --depth 1 --branch "$BRANCH" "$URL" "$SRC"
fi
# Token nicht dauerhaft in der Git-Konfiguration speichern
git -C "$SRC" remote set-url origin "https://github.com/${REPO}.git"

if [ ! -f "$CONFIG" ]; then
    echo "==> Lege $CONFIG an – bitte dort PUBLIC_URL usw. anpassen und das Skript erneut starten"
    cat > "$CONFIG" <<'YAML'
# Eigene Einstellungen für Selfify (überschreiben docker-compose.yml, bleiben bei Updates erhalten).
# Alle Möglichkeiten: siehe README, Abschnitt "Einstellungen".
services:
  selfify:
    environment:
      PUBLIC_URL: https://musik.example.de
      ADMIN_USERNAME: admin
      ADMIN_PASSWORD: ""
      TZ: Europe/Berlin
    # Andere Ordner? Dann hier anpassen:
    # volumes:
    #   - /mnt/user/appdata/selfify:/data
    #   - /mnt/user/selfify:/media
YAML
fi

if ! docker compose version >/dev/null 2>&1; then
    echo "FEHLER: 'docker compose' fehlt – bitte das Unraid-Plugin 'Docker Compose Manager' installieren." >&2
    exit 1
fi

echo "==> Image bauen und Container (neu) starten"
cd "$SRC"
docker compose -p selfify -f docker-compose.yml -f unraid/compose.build.yml -f "$CONFIG" up -d --build --remove-orphans

echo "==> Alte, unbenutzte Images aufräumen"
docker image prune -f >/dev/null

echo "==> Fertig. Logs: docker logs selfify"
