# Selfify im Google Play Store

Diese Anleitung führt dich von der fertigen App bis zur Veröffentlichung im Play Store. Die Play-Version ist
eine eigene Ausgabe der App („Flavor“ `play`), die Google-Regeln einhält. Die GitHub-Version (APK, Windows,
iPhone) bleibt unverändert.

## Was ist in der Play-Version anders?

| | GitHub-Version (`full`) | Play-Version (`play`) |
|---|---|---|
| YouTube-Suche, Link einfügen, Downloads, Downloader-Verwaltung | ja | **nein** (Play-Richtlinie) |
| Fehlende Songs | selbst von YouTube holen | **„Song wünschen“** – du (Admin) entscheidest im Dashboard |
| Update | App lädt und installiert selbst | **Google Play** aktualisiert (Hinweis in der App, Pflicht-Update möglich) |
| Berechtigung „Apps installieren“ | ja | **entfernt** (sonst lehnt Google ab) |
| Werbung | nein | ja – **nur ohne Premium** und nur, wenn du sie im Dashboard einschaltest |
| Premium-Code einlösen | ja | ja |
| Fehler melden, Konto löschen, Datenschutz | ja | ja |
| Paketname | `de.selfify.selfify` | `de.selfify.selfify.play` |

Beide Versionen lassen sich auf demselben Handy installieren (verschiedene Paketnamen).

---

## 1. Vorbereitung auf GitHub

Der Bau läuft automatisch bei jedem Stand auf `main` (Job **Play-Bundle** in `.github/workflows/app.yml`). Das
Ergebnis ist die Datei **`selfify-play.aab`** im Release **„App – aktuelle Version“** (`app-latest`) – sie
erscheint dort nur, wenn die Signatur-Secrets hinterlegt sind (dieselben wie für die APK, siehe README).

Für die Werbung (erst in Schritt 5 nötig) legst du unter *GitHub › Settings › Secrets and variables › Actions ›
**Variables*** zwei Variablen an. Es sind keine Geheimnisse, deshalb „Variables“ und nicht „Secrets“:

| Variable | Wert |
|---|---|
| `ADMOB_APP_ID` | App-ID aus AdMob, z. B. `ca-app-pub-1234567890123456~1234567890` |
| `ADMOB_BANNER_ID` | Anzeigenblock-ID des Banners, z. B. `ca-app-pub-1234567890123456/1234567890` |

Ohne diese Variablen zeigt die App nur **Test-Anzeigen** von Google (mit dem Hinweis „Test Ad“). Das ist
ungefährlich, bringt aber kein Geld.

## 2. Server vorbereiten

1. **Server aktualisieren** (Unraid: Container aktualisieren) – die Play-Version braucht den neuen Server mit
   Dashboard, Premium und Wünschen.
2. In den Container-Einstellungen **`PUBLIC_URL`** (deine Domain mit `https://`) und die Betreiberangaben
   **`OPERATOR_NAME`**, **`OPERATOR_ADDRESS`**, **`OPERATOR_EMAIL`** eintragen. Daraus entstehen die Seiten
   `https://deine-domain/datenschutz`, `/impressum` und `/konto-loeschen` (alle Pflicht für den Store).
   Die Texte sind eine **Vorlage und keine Rechtsberatung** – lies sie durch und passe sie bei Bedarf an.
3. Im Dashboard (`https://deine-domain/dashboard`) unter **App-Einstellungen** prüfen: „Premium-Bereich“ und
   „Song wünschen“ sind an, „Werbung“ vorerst **aus**.

## 3. Play Console: App anlegen

*Alle Menüpunkte heißen in der Play Console etwa so; Google benennt sie gelegentlich um.*

1. **App erstellen**: Name „Selfify“, Standardsprache Deutsch, „App“ (kein Spiel), „Kostenlos“.
2. **Paketname** ist `de.selfify.selfify.play` und steht in der hochgeladenen Datei – er lässt sich später nicht
   mehr ändern.
3. **Play App Signing** (Standard) einschalten. Der Schlüssel, mit dem GitHub das Bundle signiert, ist dein
   **Upload-Schlüssel**; den endgültigen Schlüssel verwaltet Google.
4. Unter **Testen › Geschlossene Tests** einen Test anlegen und `selfify-play.aab` hochladen (Datei aus dem
   Release `app-latest`).
   - Bei **neuen privaten Entwicklerkonten** verlangt Google vor der ersten Veröffentlichung einen
     geschlossenen Test mit **mindestens 12 Testern über 14 Tage** am Stück. Trag die Gmail-Adressen deiner
     Tester ein und schick ihnen den Test-Link.
5. Danach unter **Produktion** die Veröffentlichung beantragen.

**Ziel-API:** Neue Apps müssen aktuell auf Android 15 (API 35) zielen, ab 31.08.2026 auf API 36. Selfify baut mit
der Ziel-API des verwendeten Flutter (derzeit 36) – du musst nichts tun.

## 4. Store-Eintrag und Formulare

### Texte (Vorschlag)

- **Kurzbeschreibung (80 Zeichen):** „Deine Musik, dein Server – privat streamen mit Playlists und Offline-Modus.“
- **Beschreibung:** Selfify spielt die Musik von deinem eigenen Selfify-Server (Unraid/Docker) ab. Playlists,
  Lieblingssongs, Offline-Modus, mehrere Konten. **Wichtig:** Die App braucht einen Selfify-Server und ein Konto
  vom Betreiber – ohne beides kann man sie nicht benutzen.
- **Grafiken:** App-Symbol 512×512 (`docs/icon.png` skalieren), Feature-Grafik 1024×500, mindestens 2 Screenshots.

### Pflichtangaben unter „App-Inhalte“

| Formular | Angabe |
|---|---|
| **Datenschutzerklärung** | `https://deine-domain/datenschutz` |
| **Konto löschen** (Datensicherheit › Kontolöschung) | In der App: *Einstellungen › Konto löschen*. Im Web: `https://deine-domain/konto-loeschen` |
| **Werbung** | „Ja, enthält Werbung“ (sobald du sie einschaltest – sicherheitshalber gleich „Ja“) |
| **Zielgruppe** | Erwachsene bzw. ab 13 – **nicht** „Kinder“ (für Kinder-Apps gelten strengere Werberegeln) |
| **Inhaltseinstufung** | Fragebogen ehrlich ausfüllen (Musik-/Medien-App ohne eigene nutzergenerierte Inhalte, außer Playlist-Namen/Wünschen) |
| **Datensicherheit** | Siehe unten |
| **Berechtigungen/Foreground-Dienst** | Medienwiedergabe im Hintergrund (`FOREGROUND_SERVICE_MEDIA_PLAYBACK`): „Musik läuft weiter, wenn die App im Hintergrund ist.“ Benachrichtigungen: für die Wiedergabe-Steuerung |

**Datensicherheit – was die App sammelt** (stimmt mit der Datenschutzerklärung überein):

- *Persönliche Daten:* Name/Anzeigename, Benutzername (Konto) – für die Funktion der App; mit dem Server geteilt,
  den der Betreiber selbst betreibt.
- *App-Aktivität:* Hörverlauf, Lieblingssongs, Playlists – Funktion der App.
- *App-Infos und Leistung:* Fehlermeldungen (nur wenn der Benutzer sie absendet), App-Version.
- *Geräte- oder andere IDs:* **Werbe-ID** (nur wenn Werbung eingeschaltet ist) – für Werbung.
- Daten werden **verschlüsselt übertragen** (HTTPS über deine Domain), Benutzer können die **Löschung
  verlangen** (Konto löschen).

## 5. Werbung mit AdMob einrichten

1. Konto auf [admob.google.com](https://admob.google.com) anlegen (Zahlungsdaten und Steuerangaben ausfüllen).
2. **Apps › App hinzufügen** → Android → „Ist die App schon im Play Store?“ zunächst **Nein** (später
   verknüpfen) → Name „Selfify“. Du bekommst die **App-ID** (`ca-app-pub-…~…`).
3. **Anzeigenblock hinzufügen › Banner** → du bekommst die **Anzeigenblock-ID** (`ca-app-pub-…/…`).
4. Beide IDs als GitHub-Variablen eintragen (Schritt 1) und einen neuen Build auf `main` auslösen.
5. **Einwilligungsmeldung (Pflicht in der EU/UK):** In AdMob unter *Datenschutz & Mitteilungen* eine
   **Meldung für europäische Vorschriften** erstellen und der App zuweisen. Die App zeigt sie beim ersten Start
   automatisch; später steht in den Einstellungen „Datenschutz-Einstellungen für Werbung“.
6. Im Dashboard unter **App-Einstellungen › Werbung** einschalten. Ab dann sehen alle Benutzer **ohne Premium**
   einen Banner über der unteren Leiste.
7. Während du testest: **nie auf eigene echte Anzeigen klicken** (AdMob sperrt dafür Konten). Die Test-Anzeigen
   sind unbedenklich.

## 6. Premium-Codes

- Codes erstellst du im Dashboard unter **Premium-Codes**: beliebige Laufzeit in Tagen **oder unbegrenzt**, wie
  oft einlösbar, optional „einlösbar bis“. Der Benutzer gibt den Code in der App unter
  *Einstellungen › Premium* ein.
- Entziehen: je Lizenz, je Benutzer („Benutzer › Premium › Alles entziehen“) oder je Code (Sperren, auf Wunsch
  samt schon vergebenem Premium).
- **Wichtig:** Codes **nur verschenken**. Wer digitale Vorteile in der Play-Version gegen Geld außerhalb von
  Google Play verkauft (z. B. Codes per PayPal), verstößt gegen die **Zahlungsregeln** von Google und riskiert
  die Sperre der App. Ein Verkauf in der App müsste über Google Play Billing laufen – das ist hier nicht
  eingebaut.

## 7. Zugang für die Google-Prüfer

Google prüft die App und braucht dafür ein **Konto**, mit dem man sich anmelden kann (Play Console › *App-Inhalte
› App-Zugriff*). Der Prüfer sieht eine Anmeldemaske mit „Server-Adresse“, Benutzername und Passwort.

1. Lege im Dashboard (*Benutzer*) ein Konto an, z. B. `playtest`.
2. Trage in der Play Console Server-Adresse, Benutzername und Passwort ein.

**Dringende Empfehlung:** Nimm dafür einen **eigenen Demo-Server mit lizenzfreier Musik** (z. B. Creative-Commons-
Titel), nicht deinen privaten Server. Grund: Der Prüfer (und bei Bekanntwerden jeder) bekommt sonst Zugriff auf
deine ganze Bibliothek – und urheberrechtlich geschützte Musik öffentlich zugänglich zu machen, kann
abgemahnt werden. Ein zweiter Selfify-Container mit einem kleinen Ordner Beispiel-Musik genügt.

## 8. Realistische Hinweise

- **Registrierung:** Benutzer legst **du** an (Dashboard). Es gibt bewusst keine offene Registrierung – sonst
  könnte jeder deine Musikbibliothek abrufen. Für Familie und Freunde passt das; eine App „für alle“ im Store
  bräuchte ein anderes Modell.
- **Wünsche:** Die App holt nichts von selbst von YouTube. Wenn du einen Wunsch erfüllst („Suchen & holen“ im
  Dashboard), nutzt der **Server** den Downloader – das liegt in deiner Verantwortung (Urheberrecht, Nutzungs-
  bedingungen von YouTube). Google beurteilt nur die App, nicht deinen Server – eine rechtliche Freigabe
  bedeutet das aber nicht.
- **Ablehnung:** Google kann auch bei erfüllten Richtlinien ablehnen (z. B. wegen „nur mit eigenem Server
  nutzbar“). Der Demo-Zugang (Schritt 7) und eine klare Beschreibung senken das Risiko.

## 9. Updates

1. Änderungen auf `main` → GitHub baut automatisch ein neues `selfify-play.aab` (die **Build-Nummer** steigt von
   selbst; Google verlangt eine höhere Nummer bei jedem Upload).
2. Datei aus dem Release laden und in der Play Console als neue Version hochladen.
3. Wenn die neue Version im Store ist: im Dashboard unter **App-Einstellungen › Updates der Play-Version** die
   **neueste Build-Nummer** eintragen (und den Link zur Store-Seite). Ältere Apps zeigen dann „Neue
   App-Version verfügbar“.
4. Ist eine alte Version **nicht mehr benutzbar** (z. B. Server-Änderung), trag zusätzlich die **mindestens nötige
   Build-Nummer** ein. Ältere Apps zeigen dann nur noch „Update nötig“ mit Link zum Play Store.

Welche Versionen wie oft laufen, siehst du im Dashboard unter **Geräte & Versionen**.

## Checkliste

- [ ] Server aktualisiert, `PUBLIC_URL` und `OPERATOR_*` gesetzt, `/datenschutz` und `/impressum` angesehen
- [ ] Demo-Server mit lizenzfreier Musik und Konto `playtest`
- [ ] Play Console: App angelegt, Bundle im geschlossenen Test, 12 Tester über 14 Tage
- [ ] Datenschutz-Link, Konto-löschen-Link, Datensicherheit, Zielgruppe, Inhaltseinstufung, App-Zugriff ausgefüllt
- [ ] AdMob: App-ID und Banner-ID als GitHub-Variablen, Einwilligungsmeldung eingerichtet
- [ ] Dashboard: Werbung **an**, wenn alles getestet ist
- [ ] Premium-Codes nur verschenkt
