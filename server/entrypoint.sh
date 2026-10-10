#!/bin/sh
# Startet den Server als PUID:PGID (Unraid-Standard 99:100), damit neue Dateien
# auf den Shares die richtigen Rechte haben.
set -e

PUID="${PUID:-99}"
PGID="${PGID:-100}"

if [ "$(id -u)" = "0" ]; then
    mkdir -p "$DATA_DIR" "$MEDIA_DIR"
    # Nur den Datenordner anpassen – der Medienordner (Unraid-Share) bleibt unangetastet
    chown -R "$PUID:$PGID" "$DATA_DIR"
    # setpriv ist im Basis-Image enthalten (util-linux) – Server läuft danach ohne Root-Rechte
    exec setpriv --reuid="$PUID" --regid="$PGID" --clear-groups "$0" "$@"
fi

umask "${UMASK:-002}"

if [ ! -w "$MEDIA_DIR" ]; then
    echo "WARNUNG: $MEDIA_DIR ist für Benutzer $(id -u):$(id -g) nicht beschreibbar – Rubrik-Ordner können nicht angelegt werden." >&2
fi

# Proxy-Header (echte Client-IP hinter Nginx Proxy Manager/SWAG) nur von privaten Netzen akzeptieren
exec uvicorn app.main:create_app --factory \
    --host 0.0.0.0 \
    --port "${PORT:-8080}" \
    --proxy-headers \
    --forwarded-allow-ips "${FORWARDED_ALLOW_IPS:-127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16}" \
    --no-server-header \
    "$@"
