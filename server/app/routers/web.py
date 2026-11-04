"""Web-Seiten ohne App: Admin-Dashboard, Datenschutz, Impressum und „Konto löschen“.

Alle Seiten laden nur eigene Dateien (strenge Content-Security-Policy, kein Inline-Code) – so kann Text aus
Wünschen oder Fehlermeldungen auch dann keinen Schadcode ausführen, wenn er einmal falsch angezeigt würde.
"""

from pathlib import Path

from fastapi import APIRouter, HTTPException, Response, status
from fastapi.responses import FileResponse, HTMLResponse

from app.deps import AppSettings
from app.web.legal import deletion_page, imprint_page, privacy_page

router = APIRouter(tags=["Web"], include_in_schema=False)

WEB_DIR = Path(__file__).resolve().parent.parent / "web"
# Nur diese Dateien werden ausgeliefert (kein freier Dateizugriff)
ASSETS = {
    "dashboard.css": "text/css; charset=utf-8",
    "dashboard.js": "text/javascript; charset=utf-8",
    "legal.css": "text/css; charset=utf-8",
    "legal.js": "text/javascript; charset=utf-8",
}
SECURITY_HEADERS = {
    "Content-Security-Policy": (
        "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; "
        "base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
    ),
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
    "Cache-Control": "no-store",
}


def _html(content: str) -> HTMLResponse:
    return HTMLResponse(content, headers=SECURITY_HEADERS)


@router.get("/dashboard")
def dashboard(settings: AppSettings) -> Response:
    if not settings.dashboard_enabled:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Das Dashboard ist abgeschaltet.")
    return FileResponse(WEB_DIR / "dashboard.html", media_type="text/html; charset=utf-8", headers=SECURITY_HEADERS)


@router.get("/web/{name}")
def asset(name: str) -> Response:
    media_type = ASSETS.get(name)
    if media_type is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Datei nicht gefunden.")
    headers = {**SECURITY_HEADERS, "Cache-Control": "no-cache"}
    return FileResponse(WEB_DIR / name, media_type=media_type, headers=headers)


@router.get("/datenschutz")
def privacy(settings: AppSettings) -> HTMLResponse:
    return _html(privacy_page(settings))


@router.get("/impressum")
def imprint(settings: AppSettings) -> HTMLResponse:
    return _html(imprint_page(settings))


@router.get("/konto-loeschen")
def account_deletion(settings: AppSettings) -> HTMLResponse:
    return _html(deletion_page(settings))
