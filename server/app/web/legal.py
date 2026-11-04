"""Seiten für Datenschutz, Impressum und „Konto löschen“ (Pflichtangaben für eine öffentliche App).

Die Texte sind eine Vorlage, die zur tatsächlichen Datenverarbeitung dieses Servers passt. Sie ersetzen keine
Rechtsberatung: Wer die App öffentlich anbietet, sollte sie prüfen und die Betreiberangaben (OPERATOR_NAME,
OPERATOR_ADDRESS, OPERATOR_EMAIL) in den Server-Einstellungen ausfüllen.
"""

from html import escape

from app.config import Settings

LAYOUT = """<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>{title}</title>
<link rel="stylesheet" href="/web/legal.css">
</head>
<body>
<main>
<h1>{title}</h1>
{body}
<footer>
<a href="/datenschutz">Datenschutz</a> · <a href="/impressum">Impressum</a> ·
<a href="/konto-loeschen">Konto löschen</a>
</footer>
</main>
{script}
</body>
</html>
"""


def _page(title: str, body: str, script: str = "") -> str:
    return LAYOUT.format(title=escape(title), body=body, script=script)


def _operator(settings: Settings) -> tuple[str, str, str]:
    return escape(settings.operator_name), escape(settings.operator_address), escape(settings.operator_email)


def _missing_notice(settings: Settings) -> str:
    if settings.operator_name and settings.operator_email:
        return ""
    return (
        '<p class="notice">Hinweis für den Betreiber: Die Angaben zum Betreiber fehlen noch. Trage '
        "<code>OPERATOR_NAME</code>, <code>OPERATOR_ADDRESS</code> und <code>OPERATOR_EMAIL</code> in den "
        "Server-Einstellungen ein (Unraid: Container bearbeiten).</p>"
    )


def privacy_page(settings: Settings) -> str:
    name, address, email = _operator(settings)
    contact = "<br>".join(part for part in (name, address, email) if part) or "<em>noch nicht angegeben</em>"
    server = escape(settings.server_name)
    body = f"""
{_missing_notice(settings)}
<p>Diese Datenschutzerklärung gilt für den Musikserver „{server}“ und die zugehörigen Apps (Android, Windows,
iPhone) sowie das Web-Dashboard.</p>

<h2>Verantwortlicher</h2>
<p>{contact}</p>

<h2>Welche Daten verarbeitet werden</h2>
<ul>
<li><strong>Konto:</strong> Benutzername, Anzeigename und ein Passwort-Hash (das Passwort selbst wird nicht
gespeichert). Das Konto wird vom Betreiber angelegt.</li>
<li><strong>Angemeldete Geräte:</strong> Gerätename, Browser- bzw. App-Kennung, IP-Adresse, Zeitpunkte der Anmeldung
und letzten Nutzung sowie die App-Version (Plattform, Kanal, Version).</li>
<li><strong>Nutzung:</strong> Hörverlauf, Lieblingssongs, Playlists, gespeicherte Alben und Künstler.</li>
<li><strong>Wünsche und Fehlermeldungen:</strong> Was du schickst („Song wünschen“, „Fehler melden“). Bei
Fehlermeldungen nur, wenn du sie absendest – auf Wunsch mit Geräteinformationen und den letzten Fehlermeldungen
der App.</li>
<li><strong>Premium:</strong> Welche Codes du eingelöst hast und wie lange dein Premium gilt.</li>
<li><strong>Technische Protokolle:</strong> Der Server kann Anfragen kurzzeitig protokollieren (z. B. zur Fehlersuche
und zum Schutz vor Missbrauch).</li>
</ul>

<h2>Wofür und auf welcher Grundlage</h2>
<p>Die Daten werden verarbeitet, um die App bereitzustellen (Anmeldung, Wiedergabe, Playlists, Premium), den Dienst
sicher zu betreiben (Art. 6 Abs. 1 lit. b und f DSGVO) und Rückmeldungen zu bearbeiten.</p>

<h2>Werbung (nur Play-Version)</h2>
<p>Die Android-Version aus dem Google Play Store kann Werbung von Google AdMob anzeigen, solange du kein Premium
hast. Dabei verarbeitet Google Daten wie Werbe-ID, IP-Adresse und Geräteinformationen. Vor der ersten Anzeige
fragt die App – wo nötig – nach deiner Einwilligung (Art. 6 Abs. 1 lit. a DSGVO); du kannst sie jederzeit in den
Einstellungen der App ändern. Mit Premium wird keine Werbung geladen. Weitere Informationen:
<a href="https://policies.google.com/privacy" rel="noopener noreferrer">policies.google.com/privacy</a>.</p>

<h2>Weitergabe</h2>
<p>Außer an Google für die Werbung (siehe oben) werden Daten nicht an Dritte weitergegeben. Der Server läuft beim
Betreiber; die App spricht nur mit diesem Server.</p>

<h2>Speicherdauer und Löschen</h2>
<p>Die Daten bleiben, solange das Konto besteht. Angemeldete Geräte laufen nach spätestens {settings.refresh_token_days}
Tagen ohne Nutzung ab. Du kannst dein Konto jederzeit selbst löschen – in der App unter „Einstellungen“ → „Konto
löschen“ oder auf der Seite <a href="/konto-loeschen">Konto löschen</a>. Dabei werden Konto, Playlists,
Lieblingssongs, Hörverlauf, Wünsche, Fehlermeldungen und Premium-Zuordnung endgültig gelöscht.</p>

<h2>Deine Rechte</h2>
<p>Du hast das Recht auf Auskunft, Berichtigung, Löschung, Einschränkung der Verarbeitung, Datenübertragbarkeit
und Widerspruch sowie auf Beschwerde bei einer Datenschutzaufsichtsbehörde. Schreibe dazu an die oben genannte
Adresse.</p>
"""
    return _page("Datenschutzerklärung", body)


def imprint_page(settings: Settings) -> str:
    name, address, email = _operator(settings)
    lines = "<br>".join(part for part in (name, address) if part) or "<em>noch nicht angegeben</em>"
    mail = f'<a href="mailto:{email}">{email}</a>' if email else "<em>noch nicht angegeben</em>"
    body = f"""
{_missing_notice(settings)}
<h2>Angaben zum Betreiber</h2>
<p>{lines}</p>
<h2>Kontakt</h2>
<p>E-Mail: {mail}</p>
"""
    return _page("Impressum", body)


def deletion_page(settings: Settings) -> str:
    body = """
<p>Hier kannst du dein Konto und alle dazugehörigen Daten (Playlists, Lieblingssongs, Hörverlauf, Wünsche,
Fehlermeldungen, Premium-Zuordnung) <strong>endgültig löschen</strong>. Das lässt sich nicht rückgängig machen.</p>
<p>In der App geht es auch unter „Einstellungen“ → „Konto löschen“.</p>
<form id="delete-form" autocomplete="off">
<label for="username">Benutzername</label>
<input id="username" name="username" type="text" autocapitalize="none" required>
<label for="password">Passwort</label>
<input id="password" name="password" type="password" required>
<label class="check"><input id="confirm" type="checkbox" required> Ich möchte mein Konto endgültig löschen.</label>
<button type="submit">Konto löschen</button>
<p id="message" role="status"></p>
</form>
<noscript><p class="notice">Zum Löschen wird JavaScript benötigt. Alternativ löscht dein Admin das Konto.</p></noscript>
"""
    return _page("Konto löschen", body, '<script src="/web/legal.js"></script>')
