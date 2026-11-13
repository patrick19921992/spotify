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
| Premium kaufen (Abo über Google Play) | **nein** – Premium gibt es per Code oder vom Admin | ja – wenn du es im Dashboard einschaltest (Schritt 10), mit bis zu drei Laufzeiten (z. B. monatlich, halbjährlich, jährlich) |
| Offline-Hören | wie im Dashboard eingestellt (frei oder nur mit Premium) | wie im Dashboard eingestellt |
| Tonqualität, Videos, Songtexte, Wünsche, Überspringen, Abzeichen | wie im Dashboard eingestellt (Standard: für alle, wie bisher – Schritt 10.13) | wie im Dashboard eingestellt |
| Fehler melden, Konto löschen, Datenschutz | ja | ja |
| Konto in der App erstellen (wenn im Dashboard eingeschaltet) | ja | ja |
| Paketname | `de.selfify.selfify` | `de.selfify.selfify.play` |
| Server-Adresse | wird bei der Anmeldung eingetragen | **fest eingebaut** (Variable `PLAY_SERVER_URL`), kein Eingabefeld – bleibt leer = Feld wie in der GitHub-Version |

Beide Versionen lassen sich auf demselben Handy installieren (verschiedene Paketnamen).

Das **Werbe-SDK und die Kauf-Bibliothek (Google Play Billing) stecken nur in der Play-Version**. Die GitHub-Version
bekommt beim Bauen Platzhalter dafür (siehe README › Entwicklung), weil sie mit dem echten Werbe-SDK am Handy nicht
mehr startete – ein zweites natives Bauteil soll das nicht wiederholen.

---

## 1. Vorbereitung auf GitHub

Der Bau läuft automatisch bei jedem Stand auf `main` (Job **Play-Bundle** in `.github/workflows/app.yml`). Das
Ergebnis ist die Datei **`selfify-play.aab`** im Release **„App – aktuelle Version“** (`app-latest`) – sie
erscheint dort nur, wenn die Signatur-Secrets hinterlegt sind (dieselben wie für die APK, siehe README).

Vor dem ersten Bundle legst du unter *GitHub › Settings › Secrets and variables › Actions › **Variables***
Variablen an. Es sind keine Geheimnisse, deshalb „Variables“ und nicht „Secrets“:

| Variable | Wert | Wann |
|---|---|---|
| `PLAY_SERVER_URL` | Adresse deines Servers mit `https://`, z. B. `https://musik.technologyplanet.org` | **vor dem ersten Bundle** |
| `ADMOB_APP_ID` | App-ID aus AdMob, z. B. `ca-app-pub-1234567890123456~1234567890` | erst für die Werbung (Schritt 5) |
| `ADMOB_BANNER_ID` | Anzeigenblock-ID des Banners, z. B. `ca-app-pub-1234567890123456/1234567890` | erst für die Werbung (Schritt 5) |

**Feste Server-Adresse (`PLAY_SERVER_URL`):** Die Play-Version zeigt dann kein Feld „Server-Adresse“ mehr – weder
bei der Anmeldung (nur Benutzername und Passwort) noch in den Einstellungen. Nutzer aus dem Store sollen keine
Adresse abtippen müssen. Regeln dazu:

- Die Adresse muss mit `https://` beginnen (sonst bricht der Bau ab) und gilt nur für die Play-Version; die
  GitHub-Version, Windows und iPhone fragen weiter nach der Adresse.
- Ist die Variable leer, baut die CI die Play-Version trotzdem (mit Warnung) – die App fragt dann wie die
  GitHub-Version nach der Adresse.
- Ziehst du mit dem Server um und änderst die Variable, werden Nutzer der neuen App-Version einmal abgemeldet und
  melden sich neu an; ältere App-Versionen zeigen weiter auf die alte Adresse. Halte die Domain deshalb stabil.
- Sie ist in die App eingebaut und damit für jeden lesbar, der die App entpackt – sie ist keine geheime Angabe.
- **Eine geänderte Variable startet keinen Bau von selbst.** Setze sie am besten, bevor ein Stand auf `main` kommt.
  Danach (oder bei jeder Änderung): *Actions › App › letzter Lauf auf `main` › Re-run all jobs* – oder eine
  beliebige Änderung unter `mobile/` auf `main`. Im Protokoll des Schritts „Play-Bundle bauen“ steht dann
  „Feste Server-Adresse: …“; daran erkennst du, dass sie eingebaut wurde. Ein manueller Lauf („Run workflow“) legt
  das Bundle nur als Artefakt unter dem Lauf ab (14 Tage), nicht ins Release `app-latest`.
- Es gibt in dieser Version **keine Vorab-Prüfung** der Adresse (die gibt es nur beim Eintippen): Ein Tippfehler in
  der Variable zeigt sich erst bei der ersten Anmeldung als Fehlermeldung. Melde dich deshalb vor dem Hochladen
  einmal mit dem gebauten Stand an (siehe Checkliste).

Ohne die AdMob-Variablen zeigt die App nur **Test-Anzeigen** von Google (mit dem Hinweis „Test Ad“). Das ist
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
| **Kontoerstellung** (Datensicherheit) | Registrierung im Dashboard an („Mit Freigabe“ oder „Offen“): „Ja, mit Benutzername und Passwort“. Registrierung aus: „Nein, Konten legt der Betreiber an“. **Die Angaben müssen zur strengsten Einstellung passen, die du nutzt** – wer die Registrierung auch nur zeitweise einschaltet, gibt „Ja“ an |
| **Konto löschen** (Datensicherheit › Kontolöschung) | In der App: *Einstellungen › Konto löschen*. Konten, die noch auf Freischaltung warten: auf der Anmeldeseite der App „Registrierung zurückziehen“ (ohne Freischaltung löscht der Server sie nach 14 Tagen von selbst). Im Web (für beide): `https://deine-domain/konto-loeschen` |
| **Werbung** | „Ja, enthält Werbung“ (sobald du sie einschaltest – sicherheitshalber gleich „Ja“) |
| **Zielgruppe** | Erwachsene bzw. ab 13 – **nicht** „Kinder“ (für Kinder-Apps gelten strengere Werberegeln) |
| **Inhaltseinstufung** | Fragebogen ehrlich ausfüllen. Registrierung aus: Musik-/Medien-App ohne eigene nutzergenerierte Inhalte, außer Playlist-Namen/Wünschen. **Registrierung an („Mit Freigabe“ oder „Offen“):** Fremde können Konten anlegen, und ihre frei gewählten Anzeigenamen sowie Namen öffentlicher/gemeinsamer Playlists sehen alle anderen Benutzer – im Fragebogen also „Nutzer können interagieren / Inhalte teilen“ angeben. Google verlangt für nutzergenerierte Inhalte eine Möglichkeit, sie zu entfernen: Das machst du als Admin (Benutzer sperren oder löschen, Playlist löschen – Admins dürfen jede Playlist bearbeiten und löschen); Meldungen kommen über „Fehler melden“ oder die Kontakt-Adresse aus dem Impressum. Am sichersten bleibst du bei „Mit Freigabe“ |
| **Datensicherheit** | Siehe unten |
| **Berechtigungen/Foreground-Dienst** | Medienwiedergabe im Hintergrund (`FOREGROUND_SERVICE_MEDIA_PLAYBACK`): „Musik läuft weiter, wenn die App im Hintergrund ist.“ Benachrichtigungen: für die Wiedergabe-Steuerung |

**Datensicherheit – was die App sammelt** (stimmt mit der Datenschutzerklärung überein):

- *Persönliche Daten:* Name/Anzeigename, Benutzername (Konto) – für die Funktion der App; mit dem Server geteilt,
  den der Betreiber selbst betreibt. Ist die Registrierung eingeschaltet, werden **Benutzername, Anzeigename und
  Passwort** bei der Registrierung in der App erhoben; der Server speichert das Passwort nur als Hash, nie im
  Klartext.
- *Anzeigename für andere sichtbar:* Andere Nutzer desselben Servers sehen den Anzeigenamen an geteilten Playlists
  und an Titeln, die jemand dort hinzufügt.
- *IP-Adresse:* wird bei Anmeldung und Registrierung kurzzeitig zum Schutz vor Missbrauch (Ratenbegrenzung)
  verarbeitet – dafür nur im Speicher des Servers. Bei angemeldeten Geräten speichert der Server sie zusätzlich
  (siehe Datenschutzerklärung, „Angemeldete Geräte“).
- *App-Aktivität:* Hörverlauf, Lieblingssongs, Playlists – Funktion der App.
- *App-Aktivität › App-Interaktionen* – **Auf anderen Geräten abspielen:** Solange die App offen ist oder Musik
  spielt, überträgt sie den **Gerätenamen** (steht ohnehin schon bei den angemeldeten Geräten), den **Gerätetyp** (Handy, Tablet, Computer), die Plattform und den
  **aktuellen Wiedergabe-Status** (Titel, Position, Warteschlange, Zufall/Wiederholen) an den eigenen Server. Der
  Server zeigt das nur den Geräten **desselben Kontos**, gibt es nicht weiter und nutzt es nicht für Werbung.
  Gerätetyp und Wiedergabe-Status werden **nicht gespeichert** (nur im Arbeitsspeicher, weg nach 30 Minuten ohne
  Verbindung bzw. beim Neustart); gespeichert bleibt nur der Gerätename der Anmeldung, den der Benutzer ändern kann.
  Zweck: Funktion der App. Die Funktion lässt sich nicht abschalten, sendet aber nur an deinen Server.
- *App-Infos und Leistung:* Fehlermeldungen (nur wenn der Benutzer sie absendet), App-Version.
- *Geräte- oder andere IDs:* **Werbe-ID** (nur wenn Werbung eingeschaltet ist) – für Werbung.
- *Finanzdaten › Kaufverlauf:* nur wenn du den Kauf in der App einschaltest (Schritt 10) – der Server speichert
  die Kaufkennung von Google, das Produkt und die Laufzeit, um den Kauf dem Konto zuzuordnen (Funktion der App,
  Kontoverwaltung). Zahlungsdaten (Karte, Bankverbindung) sieht weder die App noch dein Server – die bleiben bei Google.
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
  die Sperre der App. Verkaufen darfst du Premium in der Play-Version nur über **Google Play Billing** – das ist
  eingebaut und wird in Schritt 10 eingerichtet. Codes und die Vergabe im Dashboard bleiben daneben bestehen und
  zählen genauso wie ein Kauf.
- **Was ein Code freischaltet, legst du beim Erzeugen fest.** Im Formular „Neue Codes erzeugen“ gibt es den Block
  **„Schaltet frei“**: Standard ist „Alle Leistungen“. Nimmst du den Haken weg, wählst du einzelne Leistungen aus
  (Offline-Hören, Keine Werbung, Höhere Tonqualität, Videos ansehen, Songtexte, Mehr Song-Wünsche, Unbegrenzt
  überspringen, Premium-Abzeichen – was sie bewirken, steht in Schritt 10.13). Mindestens eine muss angehakt sein.
  - Das Dashboard zeigt den Umfang bei jedem Code, in „Wer hat gerade Premium?“ und bei den Lizenzen eines Benutzers
    (Spalte **„Umfang“**: „Alle Leistungen“ oder die Liste). In der Benutzerliste steht bei Teil-Premium zusätzlich
    „Teilumfang“.
  - **Alle Codes und Lizenzen von vor diesem Update schalten alle Leistungen frei** – an ihnen ändert sich nichts.
    Ebenso Premium, das du unter *Benutzer › Premium* vergibst, und ein Abo über Google Play: Die schalten **immer
    alles** frei.
  - Eine Leistung wirkt nur, wenn sie unter *App-Einstellungen › Premium-Leistungen* auf „Nur Premium“ steht. Steht
    sie auf „Für alle“, hat sie ohnehin jeder – auch ohne Code.
  - **Zeiten:** Ein Code mit Teilumfang hängt sich nur hinter laufende Lizenzen, die **alles davon schon enthalten**;
    sonst beginnt er sofort beim Einlösen (ein Code „nur Videos“ wartet also nicht, bis ein „nur Songtexte“-Code
    abgelaufen ist). Wer schon **unbegrenzt** Premium mit allen Leistungen hat, kann keinen Code mehr einlösen (der
    Code bleibt unverbraucht); mit unbegrenztem **Teil**-Premium geht es.
  - Ältere Apps kennen den Umfang nicht: Dort macht **jedes** Premium werbefrei, auch ein Code ohne „Keine Werbung“.
- **Codes schalten auch das Offline-Hören frei** (wenn es in ihrem Umfang steht). Steht Offline-Hören auf „Nur
  Premium“ (Schritt 10.6), darf jeder mit Premium Musik aufs Gerät laden – egal ob das Premium aus einem Code, aus deiner Vergabe im Dashboard
  oder aus einem Kauf stammt. Umgekehrt gilt dasselbe Ende: **Läuft der Code ab, sperrst du ihn samt vergebenem
  Premium oder entziehst du die Lizenz, löscht die App die Offline-Musik vom Gerät**, sobald sie den Stand beim
  Server geprüft hat.

## 7. Zugang für die Google-Prüfer

Google prüft die App und braucht dafür ein **Konto**, mit dem man sich anmelden kann (Play Console › *App-Inhalte
› App-Zugriff*). Mit gesetzter `PLAY_SERVER_URL` sieht der Prüfer nur Benutzername und Passwort – die App
verbindet sich fest mit dem Server aus dieser Variable. Ohne die Variable sieht er zusätzlich das Feld
„Server-Adresse“.

1. Lege im Dashboard (*Benutzer*) ein Konto an, z. B. `playtest`. Das Prüfer-Konto legst du auch bei
   eingeschalteter Registrierung selbst an, mit „Alle Rubriken“ (Standard beim Anlegen im Dashboard). Ein selbst
   registriertes Konto sieht ohne Freigabe nichts und eignet sich deshalb nicht als Prüfer-Zugang.
2. Trage in der Play Console Benutzername und Passwort ein (ohne feste Adresse auch die Server-Adresse).

**Dringende Empfehlung:** Nimm dafür einen **eigenen Demo-Server mit lizenzfreier Musik** (z. B. Creative-Commons-
Titel), nicht deinen privaten Server. Grund: Der Prüfer (und bei Bekanntwerden jeder) bekommt sonst Zugriff auf
deine ganze Bibliothek – und urheberrechtlich geschützte Musik öffentlich zugänglich zu machen, kann
abgemahnt werden. Ein zweiter Selfify-Container mit einem kleinen Ordner Beispiel-Musik genügt.

**Wichtig mit fester Adresse:** Die App im Store zeigt immer auf `PLAY_SERVER_URL` – der Prüfer kommt also auf
genau diesen Server und nirgends sonst hin. Zwei saubere Wege:

- *Eigene Bibliothek öffentlich vermeiden:* Beim Einreichen `PLAY_SERVER_URL` auf den **Demo-Server** stellen,
  Bundle bauen und prüfen lassen. Danach `PLAY_SERVER_URL` auf deinen echten Server stellen und die
  freigegebene Version mit einem neuen Bundle aktualisieren (der Wechsel lässt sich unter „Hinweise für Prüfer“
  erklären).
- *Einfacher:* `PLAY_SERVER_URL` bleibt dein echter Server, und das Prüfer-Konto `playtest` bekommt dort nur,
  was du öffentlich zeigen darfst. Freigeben lassen sich nur ganze Rubriken (Benutzer › Rubriken…), keine
  einzelnen Titel – bei urheberrechtlich geschützter Musik auf demselben Server ist das also nicht empfehlenswert.

## 8. Realistische Hinweise

- **Registrierung:** Standardmäßig legst **du** die Benutzer an (Dashboard, *App-Einstellungen › Registrierung* =
  „Aus“). Für Familie und Freunde passt das. Schaltest du „Mit Freigabe“ oder „Offen“ ein, können Fremde Konten
  erstellen: Sie sehen nur die Rubriken, die du für neue Konten freigibst (ohne Auswahl: nichts), haben kein
  Download-Recht und sehen keine Admin-Bereiche. Gib deshalb nur Rubriken frei, die du öffentlich zeigen darfst, und
  denk an Kontoerstellung und Inhaltseinstufung oben.
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

## 10. Premium verkaufen (Google Play Billing)

Damit bietet die Play-Version Premium als **Abo über Google Play** an – ein Abo mit bis zu drei Laufzeiten
(z. B. monatlich, halbjährlich, jährlich; die Preise legst du in der Play Console fest).
Gekauft wird nur in der Play-Version; GitHub-Version, Windows und iPhone bekommen Premium weiter per Code oder von dir
im Dashboard. Alles hier ist **standardmäßig aus** – solange du nichts einschaltest, ändert sich an deinem Server und
an den Apps nichts.

**So hängt es zusammen:** Die App startet den Kauf bei Google und meldet ihn deinem Server. Der Server fragt bei
Google nach, ob der Kauf echt ist und wie lange er läuft (dafür braucht er ein „Dienstkonto“, Schritt 10.4), und
schaltet Premium für dieses Konto frei. Später fragt er regelmäßig nach, ob das Abo noch bezahlt wird.

*Die Menünamen der Play Console und der Google Cloud stammen aus Googles Anleitungen und aus Anleitungen Dritter;
Google benennt sie gelegentlich um. Von hier aus war weder die Play Console noch die Hilfe-Seite von Google
erreichbar – was nicht belegt werden konnte, steht unten unter „Nicht geprüft“.*

### 10.1 Zahlungsprofil

Um etwas zu verkaufen, verlangt Google ein **Zahlungsprofil** (Händlerangaben, Bankverbindung für die Auszahlung,
Steuerangaben). Richte es ein, bevor du das Abo anlegst – die Play Console weist dich darauf hin, wenn es fehlt.

### 10.2 Abo mit drei Laufzeiten anlegen

Bei Google heißt das: **ein Abo** (ein Produkt) mit **mehreren Basis-Abos** – je Laufzeit eins. Ein Basis-Abo legt
Abrechnungszeitraum, Verlängerung und Preis fest. Dazu kannst du je Basis-Abo **Angebote** anlegen (z. B. erster
Monat gratis).

1. Lade zuerst ein Bundle der Play-Version in einen Test-Track (Schritt 3) – es enthält die Berechtigung für Käufe
   (`com.android.vending.BILLING`); die CI prüft das bei jedem Bau.
2. Play Console › deine App › **Monetarisieren mit Play › Produkte › Abos** › *Abo erstellen*.
   - **Produkt-ID:** z. B. `premium`. Erlaubt sind Kleinbuchstaben, Ziffern, Punkt und Unterstrich (höchstens 40
     Zeichen) – genau diese ID trägst du später im Dashboard ein. Sie lässt sich nachträglich nicht ändern. Hast du
     schon ein Abo `premium_monat` aus Teil 1 angelegt, nimm einfach das weiter – die ID ist nur ein Name, die
     Laufzeiten kommen als Basis-Abos dazu.
   - **Name:** z. B. „Selfify Premium“ (sieht der Käufer im Kaufdialog von Google).
3. Im Abo **drei Basis-Abos** anlegen, jeweils mit **automatischer Verlängerung** (nicht „Prepaid“, nicht
   „Ratenzahlung“ – solche Basis-Abos zeigt die App nicht an):

   | Kennung des Basis-Abos | Abrechnungszeitraum | Preis (Beispiel) | Die App zeigt |
   |---|---|---|---|
   | `monatlich` | Monatlich | 0,99 € | „Monatlich – 0,99 € pro Monat“ |
   | `halbjaehrlich` | Alle 6 Monate | 4,99 € | „Halbjährlich – 4,99 € pro Halbjahr, entspricht 0,83 € pro Monat, spare 15 %“ |
   | `jaehrlich` | Jährlich | 8,99 € | „Jährlich – 8,99 € pro Jahr, entspricht 0,75 € pro Monat, spare 24 %“ |

   - **Kennungen:** nur Kleinbuchstaben, Ziffern und Bindestrich, am Anfang ein Buchstabe oder eine Ziffer, höchstens
     63 Zeichen – **keine Umlaute** (also `halbjaehrlich`, nicht `halbjährlich`). Nach dem Aktivieren lässt sich die
     Kennung nicht mehr ändern oder wiederverwenden. Du kannst andere Kennungen nehmen; im Dashboard trägst du dann
     genau diese ein (Schritt 10.6).
   - **Ersparnis:** Die App rechnet „entspricht … pro Monat“ und „spare … %“ selbst aus – immer gegenüber dem
     monatlichen Basis-Abo (gleiche Währung) und **abgerundet**, damit nie zu viel versprochen wird. Ist ein Plan
     nicht billiger als monatlich, zeigt sie keine Ersparnis. Gibt es kein monatliches Basis-Abo (oder zeigst du es
     nicht an), fehlt die Ersparnis ganz; „entspricht … pro Monat“ bleibt.
   - Google bietet als Abrechnungszeitraum u. a. wöchentlich, alle 4 Wochen, monatlich, alle 2, 3, 4, 6 und 8 Monate
     und jährlich an. Die App kann alle anzeigen; gedacht sind die drei oben.
4. **Preise festlegen.** Der Preis wird **nur in der Play Console** festgelegt (je Basis-Abo; Google rechnet ihn in
   andere Länder um, du kannst Länderpreise anpassen). Im Dashboard steht kein Preis – die App zeigt immer den Preis,
   den der Store liefert.
5. Alle drei Basis-Abos **aktivieren**. Erst dann kann man sie kaufen. (Ein Abo mit aktivem Basis-Abo lässt sich
   nicht mehr löschen – nur deaktivieren.)
6. **Angebote (freiwillig)** – je Basis-Abo, z. B.:
   - **Gratis-Testzeitraum:** „Erster Monat gratis“ (Phase „kostenlos“, Dauer 1 Monat). Die App zeigt dann
     „1 Monat gratis, danach 0,99 € pro Monat“ und auf dem Knopf **„Gratis testen“**.
   - **Einführungspreis:** z. B. „3 Monate für 0,49 € pro Monat“ (wiederkehrend) oder ein einmaliger Preis für einen
     Zeitraum. Die App zeigt z. B. „0,49 € pro Monat für 3 Monate, danach 0,99 € pro Monat“.
   - **Berechtigung:** **„Neukunden gewinnen“** (Google entscheidet, wer berechtigt ist – in der Regel nur, wer das
     Abo noch nie hatte). **Nicht** „Vom Entwickler festgelegt“: Solche Angebote liefert Google jedem Käufer, und die
     App würde sie allen anzeigen – sie prüft selbst nichts.
   - Die App zeigt je Laufzeit **höchstens ein** Angebot: bevorzugt ein Gratis-Angebot (bei mehreren das längste),
     sonst das günstigste. Wer nicht berechtigt ist, sieht nur den normalen Preis.
   - Ratenzahlungs-Pläne und Prepaid-Basis-Abos zeigt die App nicht.
7. **Laufzeit wechseln** brauchst du nicht einzurichten: Der Käufer wechselt in der App („Zu Jährlich wechseln“), Google
   rechnet die Restzeit an (siehe Schritt 10.14). Lies dort aber den Hinweis zum **Ersatzmodus** – das ist der Punkt,
   der beim ersten Testkauf am ehesten hakt.

**Preise später ändern:** Jederzeit in der Play Console beim Basis-Abo. Laut Google gilt der neue Preis **für neue
Käufer** innerhalb weniger Stunden; die App zeigt ihn von selbst (Ersparnis wird neu gerechnet). **Bestehende
Abonnenten** zahlen erst einmal weiter den alten Preis (Google nennt das „Legacy-Preiskohorte“). Willst du auch sie
umstellen, beendest du diese Kohorte in der Play Console:

- **Preissenkung:** gilt für sie ab der nächsten Zahlung; Google informiert per E-Mail.
- **Preiserhöhung:** in der Regel müssen die Abonnenten **zustimmen**. Google benachrichtigt sie (die erste Zahlung
  zum neuen Preis frühestens nach etwa 37 Tagen); wer nicht zustimmt, dessen Abo wird zur nächsten Verlängerung
  **beendet** – dann endet bei dir auch Premium (und ggf. die Offline-Musik). In manchen Ländern geht eine Erhöhung
  ohne Zustimmung (mit Vorankündigung, Grenzen für Höhe und Häufigkeit); dafür verlangt Google aber einen Hinweis
  **in der App** – einen eigenen Baustein dafür hat Selfify nicht. Nimm deshalb die Variante mit Zustimmung.
- Preise von **Angeboten** (Gratis-Zeit, Einführungspreis) gelten immer nur für neue Käufer.
- Ändere Preise nicht „zum Testen“ bei echten Abonnenten. Mehr: Googles Seite
  [Abopreise ändern](https://developer.android.com/google/play/billing/price-changes?hl=de).

### 10.3 Lizenztester eintragen (zum Ausprobieren ohne Geld)

Trag in der Play Console unter **Einstellungen › Lizenztests** die Gmail-Adressen ein, mit denen du testest
(Anleitung von Google: <https://support.google.com/googleplay/android-developer/answer/6062777>). Für Lizenztester gilt
laut Google ([Testanleitung](https://developer.android.com/google/play/billing/test)):

- Im Kaufdialog erscheinen **Test-Zahlungsarten** („Testkarte, immer genehmigt“ / „… immer abgelehnt“) – es wird
  **kein echtes Geld** abgebucht.
- Ein Monats-Abo verlängert sich im Test etwa **alle 5 Minuten** und endet nach **höchstens 6 Verlängerungen** von
  selbst. Zahlungsproblem-Phasen sind ebenfalls verkürzt (Kulanzzeit 5 Minuten, Kontosperre 10 Minuten).
- Ein Testkauf, den **niemand** innerhalb weniger Minuten bei Google bestätigt, wird automatisch erstattet (du
  bekommst eine E-Mail). Bestätigt wird doppelt: vom Server (über das Dienstkonto) **und** von der App auf dem
  Handy, sobald der Server den Kauf angenommen hat. Kommt die Erstattungs-Mail, hat also keins von beiden geklappt.
  **Bleibt sie aus, beweist das aber nicht, dass der Server bestätigen darf** – das Handy kann es allein getan
  haben. Wie du den Server prüfst, steht in Schritt 10.7.
- **Achtung:** Tester eines Test-Tracks, die **nicht** als Lizenztester eingetragen sind, zahlen echtes Geld.
- Das Google-Konto des Testers muss auf dem Handy angemeldet sein; die App muss den Paketnamen
  `de.selfify.selfify.play` haben.

### 10.4 Dienstkonto anlegen und berechtigen (damit dein Server Käufe prüfen kann)

Ein Dienstkonto ist ein technisches Google-Konto ohne Passwort. Dein Server weist sich damit bei Google aus – über
eine **Schlüsseldatei**. Wer diese Datei hat, kann die Käufe deiner App einsehen und Abos erstatten oder kündigen.
**Gib sie niemals weiter: nicht in einen Chat (auch nicht an eine KI), nicht per E-Mail, nicht ins Repository, nicht
in GitHub-Secrets oder -Variablen.** Sie gehört nur auf deinen Unraid.

1. <https://console.cloud.google.com> öffnen (mit dem Google-Konto deiner Play Console), ein **Projekt** anlegen
   (z. B. „Selfify“).
2. *APIs und Dienste › Bibliothek* › **„Google Play Android Developer API“** suchen › **Aktivieren**.
3. *IAM und Verwaltung › Dienstkonten* › **Dienstkonto erstellen** (Name z. B. `selfify-kaufpruefung`). Rollen im
   Cloud-Projekt braucht es keine – die Rechte vergibst du gleich in der Play Console.
4. Das Dienstkonto anklicken › *Schlüssel › Schlüssel hinzufügen › Neuen Schlüssel erstellen ›* **JSON**. Der Browser
   lädt eine `.json`-Datei herunter – das ist die Schlüsseldatei. Merke dir außerdem die E-Mail-Adresse des
   Dienstkontos (`…@….iam.gserviceaccount.com`).
5. Play Console › **Nutzer und Berechtigungen** › *Neue Nutzer einladen* › die E-Mail-Adresse des Dienstkontos
   eintragen. Bei den Berechtigungen **für die App Selfify**:
   - **Finanzdaten ansehen** (Finanzdaten, Bestellungen …)
   - **Bestellungen und Abos verwalten**

   Mehr braucht es nicht. Einladen/Speichern.
6. Es kann eine Weile dauern, bis Google die neuen Rechte anwendet. Lehnt „Verbindung testen“ (Schritt 10.6) den
   Schlüssel zunächst ab, später noch einmal versuchen.

### 10.5 Schlüsseldatei auf dem Unraid ablegen

1. Benenne die heruntergeladene Datei in **`play-service-account.json`** um und kopiere sie in den Datenordner des
   Containers: **`/mnt/user/appdata/selfify/`** (z. B. über die Netzwerkfreigabe `appdata` oder das Unraid-Dateiprogramm).
   Im Container ist das `/data/play-service-account.json` – genau dort sucht der Server.
2. Im Unraid-Terminal die Rechte so setzen, dass nur der Container die Datei liest:

   ```bash
   chown 99:100 /mnt/user/appdata/selfify/play-service-account.json
   chmod 600 /mnt/user/appdata/selfify/play-service-account.json
   ```
3. Lösche die Datei danach vom PC (Download-Ordner, Papierkorb). Brauchst du sie noch einmal, erzeugst du in der
   Google Cloud einfach einen neuen Schlüssel und löschst den alten.
4. Container-Einstellungen (Unraid › Docker › Selfify › *Edit*, „Show more settings“). Die Standardwerte passen, wenn
   du die Datei wie oben abgelegt hast:

   | Variable | Standard | Bedeutung |
   |---|---|---|
   | `PLAY_SERVICE_ACCOUNT_FILE` | `/data/play-service-account.json` | Pfad der Schlüsseldatei **im Container**. Fehlt die Datei, ist der Kauf in der App aus |
   | `PLAY_PACKAGE_NAME` | `de.selfify.selfify.play` | Paketname der Play-Version (nicht ändern) |
   | `PLAY_RECHECK_HOURS` | `12` | So oft fragt der Server Google höchstens, ob ein laufendes Abo noch bezahlt wird (1–168) |

5. Container neu starten. Der Server liest die Datei, gibt ihren Inhalt aber nie aus – weder im Protokoll noch im
   Dashboard (dort steht nur der Pfad).

Glaubst du, die Datei ist in falsche Hände geraten: In der Google Cloud beim Dienstkonto den Schlüssel **löschen**
und einen neuen erzeugen.

### 10.6 Im Dashboard einschalten

Dashboard › **App-Einstellungen**. Halte dich an die Reihenfolge – sonst verlieren Familie und Freunde ihre
Offline-Musik, bevor sie Premium haben.

1. Karte **„Kauf in der App (Google Play)“**: Oben muss **„Kaufprüfung eingerichtet“** stehen. **„Verbindung testen“**
   drücken → „Verbindung zu Google Play steht.“ Andere Meldungen:
   - „Schlüsseldatei fehlt: …“ → Datei liegt nicht am genannten Pfad (Schritt 10.5).
   - „Schlüsseldatei ist ungültig.“ → nicht die JSON-Datei des Dienstkontos oder beschädigt.
   - „Google lehnt den Schlüssel ab …“ → API nicht aktiviert oder Dienstkonto in der Play Console (noch) nicht
     berechtigt (Schritt 10.4).
   - „Google ist nicht erreichbar.“ → der Server kommt nicht ins Internet.

   Der Test prüft nur die Anmeldung bei Google. Ob das Dienstkonto wirklich auf die **Käufe deiner App** zugreifen
   darf, zeigt erst der erste Testkauf (Schritt 10.7).
2. **„Produkt-ID des Abos“**: genau wie in der Play Console, z. B. `premium` (oder `premium_monat`).
   Darunter der Abschnitt **„Laufzeiten“**:
   - Je Zeile eine **„Kennung des Basis-Abos“** genau wie in der Play Console: `monatlich`, `halbjaehrlich`,
     `jaehrlich` (höchstens 6; „Laufzeit hinzufügen“, „Entfernen“).
   - Mit **↑/↓** legst du die Reihenfolge in der App fest.
   - **„Empfohlen“** markiert eine Laufzeit (z. B. jährlich): Die App zeigt dort den Hinweis „Empfohlen“ und wählt
     sie vor. „Keine Empfehlung“ = vorgewählt ist die erste.
   - **Leer lassen** = die App zeigt alle Laufzeiten, die Google liefert, die kürzeste zuerst. Trägst du eine Kennung
     ein, die es im Store nicht gibt, fehlt sie in der App; passt keine, steht dort „Die eingestellten Laufzeiten
     wurden im Play Store nicht gefunden (…).“
   - Preise stehen hier nicht – die kommen aus dem Store.
3. **„Premium in der Play-Version zum Kauf anbieten“** einschalten, speichern. Die Kaufkarte erscheint in der
   Play-Version unter *Einstellungen › Premium* – nur, wenn Schalter, Produkt-ID **und** Kaufprüfung vorhanden sind.
4. Karte **„Premium-Leistungen“** (direkt über „Premium und Offline-Hören“): Hier legst du fest, was nur mit
   Premium geht – Offline-Hören und die anderen Leistungen. Was jede Zeile bewirkt: Schritt 10.13. Standard ist
   alles „Für alle“, also wie bisher.
5. Karte **„Premium und Offline-Hören“**:
   - **Texte** für die Premium-Seite der App: Überschrift, Beschreibung, Vorteile (ein Vorteil je Zeile). Preise
     und Laufzeiten musst du hier nicht nennen – die zeigt die App je Laufzeit aus dem Store. Lässt du die Vorteile
     leer, listet die App die Leistungen auf, die auf „Nur Premium“ stehen (Schritt 10.13).
   - **„Gnadenfrist ohne Verbindung (Tage)“** (Standard 7, 1–30): so lange bleibt Offline-Musik spielbar, wenn die
     App deinen Server nicht erreicht.
   - **Zuerst** allen, die weiter offline hören sollen, Premium geben (*Benutzer › Premium* oder ein Code).
     Admins brauchen kein Premium.
   - **Dann** in der Karte „Premium-Leistungen“ die Zeile **„Offline-Hören“** auf **„Nur Premium“** stellen (das ist
     der frühere Schalter „Offline-Hören nur mit Premium“ – gleiche Wirkung, neuer Platz). Das Dashboard fragt
     nach, weil ab jetzt alle ohne Premium ihre Offline-Musik auf dem Gerät verlieren, sobald ihre App den Stand
     geprüft hat. Der Schalter gilt
     für alle App-Ausgaben (Play, GitHub, Windows, iPhone) – **aber erst ab der App-Version, die die Sperre kennt.**
     Ältere Apps wissen nichts davon: Sie laden weiter aufs Gerät und löschen nie.
   - Deshalb gibt es darunter **„Sperre durchsetzen ab App-Build“** (`offline_min_client_build`, Standard 0 = aus).
     Trag dort die Build-Nummer der ersten App-Version mit Offline-Sperre ein, **sobald sie verteilt ist** (Play
     Store, GitHub-Release, Windows, iPhone – die Build-Nummer ist bei allen Ausgaben eines Standes dieselbe;
     *Geräte & Versionen* zeigt, wer welche hat). Solange der Schalter an ist, bekommt dann jeder **ohne Premium**,
     dessen App älter ist oder keine Build-Nummer meldet, vom Server keine Musik mehr (weder zum Abspielen noch zum
     Laden; HTTP 426) und sieht in der App **„Bitte aktualisiere die App.“** Premium-Nutzer und Admins sind nie
     betroffen, auch nicht mit alter App. Ist der Schalter aus, wirkt die Zahl nicht.
     Wer danach aktualisiert, hört wieder – und die neue App sperrt und löscht nach den Regeln oben.
     Für die Play-Version kannst du zusätzlich wie gewohnt die „mindestens nötige Build-Nummer“ setzen (Schritt 9);
     die zeigt den Update-Bildschirm mit Link zum Store.

Die beiden Schalter sind unabhängig: Du kannst das Offline-Hören an Premium binden, ohne etwas zu verkaufen (dann
gibt es Premium nur per Code oder von dir) – und umgekehrt.

### 10.7 Testen

Mit einem Lizenztester-Konto (Schritt 10.3) und der Play-Version aus dem Test-Track:

1. In der App *Einstellungen › Premium*: Je Laufzeit eine Karte mit dem Preis aus dem Store (z. B. „Jährlich“,
   „8,99 € pro Jahr“, „entspricht 0,75 € pro Monat“, „spare 24 %“), darunter ein Knopf („Jährlich abonnieren“ bzw.
   „Gratis testen“ bei einem Gratis-Angebot). Steht dort „Das Abo wurde im Play Store nicht gefunden“, stimmt die
   Produkt-ID nicht oder kein Basis-Abo ist aktiv; „Die eingestellten Laufzeiten wurden im Play Store nicht
   gefunden“ heißt: die Kennungen im Dashboard passen nicht zur Play Console.
2. Kaufen mit „Testkarte, immer genehmigt“ → „Premium ist freigeschaltet. Danke!“. Im Dashboard unter
   **Premium-Codes › Käufe über Google Play** steht der Kauf mit dem Zusatz „Test“.
3. Musik aufs Gerät laden – das geht jetzt.
4. Etwa 5 Minuten warten: Das Abo verlängert sich (Dashboard › „Neu prüfen“ zeigt das neue Enddatum). Kommt eine
   Erstattungs-Mail von Google, wurde der Kauf nicht bestätigt. **Keine Mail heißt nur: irgendwer hat bestätigt** –
   nach einem frischen Kauf tut das auch die App auf dem Handy. Ob dein **Server** bestätigen darf (Berechtigung
   „Bestellungen und Abos verwalten“ des Dienstkontos, Schritt 10.4), siehst du so:
   - Im Protokoll des Containers (Unraid › Docker › Selfify › *Logs*) darf nach dem Kauf **keine** Zeile
     „Kauf … konnte bei Google nicht bestätigt werden“ stehen. Das ist der verlässliche Nachweis: Die Zeile
     bleibt im Protokoll stehen.
   - Dieselbe Störung steht in der Kaufliste (*Premium-Codes › Käufe über Google Play*, Spalte „Zuletzt geprüft“)
     als Hinweis „Der Kauf konnte bei Google noch nicht bestätigt werden – es wird erneut versucht …“. Sieh
     **gleich nach dem Kauf** nach und drück vorher nicht „Neu prüfen“: Hat inzwischen die App bestätigt,
     verschwindet der Hinweis bei der nächsten gelungenen Prüfung wieder.
   - **Kein Beweis** ist das Feld `acknowledged` der Schnittstelle (`GET /api/admin/premium/purchases`): Der
     Server übernimmt es bei jeder Prüfung von Google. Es steht also auch dann auf `true`, wenn nur die App
     bestätigt hat und der Server es gar nicht dürfte.

   Das ist wichtig für Käufe, die die App erst später nachreicht (Server war beim Kauf nicht erreichbar): Die
   bestätigt nur der Server. Darf er das nicht, erstattet Google nach 3 Tagen und Premium endet.
5. Kündigen (in der App „Abo verwalten“ oder in Google Play bei den Abos des Kontos): Die App zeigt
   „Abo gekündigt – Premium bis …“. Nach dem Ablauf (im Test wenige Minuten) die App öffnen: Premium endet, die
   Offline-Musik wird gelöscht, die App meldet es.
6. **Wiederherstellen:** Auf einem zweiten Gerät mit demselben Google-Konto und demselben Selfify-Konto „Käufe
   wiederherstellen“ antippen. Mit einem **anderen** Selfify-Konto muss die Meldung „Dieser Kauf ist schon mit
   einem anderen Konto verbunden.“ kommen.
7. Flugmodus: Offline-Musik spielt weiter; in den Einstellungen steht kurz vor Ablauf der Gnadenfrist ein Hinweis.
8. Die **GitHub-Version** starten: kein Kaufknopf, „Code einlösen“ wie bisher.
9. **Code statt Kauf:** Einem Konto ohne Abo einen kurzen Code geben (oder Premium im Dashboard vergeben), Musik
   laden, dann die Lizenz im Dashboard entziehen bzw. den Code samt Premium sperren und die App öffnen: Die
   Offline-Musik wird gelöscht wie nach einem abgelaufenen Abo.
10. **Mindest-Build** (falls du „Sperre durchsetzen ab App-Build“ nutzt): eine höhere Zahl als die Build-Nummer
    deiner App eintragen und mit einem Konto **ohne** Premium einen Titel starten → „Bitte aktualisiere die App.“
    Mit Premium oder als Admin spielt derselbe Titel. Danach die Zahl wieder richtig stellen.
11. **Laufzeit wechseln:** Mit dem Lizenztester „Jährlich“ kaufen, dann in der App „Monatlich“ antippen und „Zu
    Monatlich wechseln“. Erwartet: Kaufdialog von Google, danach „Laufzeit gewechselt. Google rechnet die restliche
    Zeit deines bisherigen Abos an.“; Premium bleibt ohne Unterbrechung. Im Dashboard unter *Käufe über Google Play*
    steht der alte Kauf als **„ersetzt“** und der neue mit Laufzeit **`monatlich`**; der Benutzer hat nur **eine**
    Lizenz (kein doppeltes Premium). Im Test verlängert sich ein Jahres-Abo etwa alle 30 Minuten, ein Halbjahres-Abo
    alle 15, ein Monats-Abo alle 5 Minuten. **Scheitert der Wechsel mit einer Fehlermeldung von Google**, siehe
    Schritt 10.14 („Ersatzmodus“).
12. **Angebot:** Mit einem **zweiten** Lizenztester, der das Abo noch nie hatte, muss das Angebot erscheinen (z. B.
    „1 Monat gratis, danach 0,99 € pro Monat“, Knopf „Gratis testen“; im Test dauert die Gratis-Zeit etwa 3 Minuten).
    Beim ersten Tester, der schon gekauft hat, darf es nicht mehr erscheinen. (Mit der App „Play Billing Lab“ von
    Google lässt sich ein Angebot auch mehrfach mit demselben Tester testen.)
13. **Leistungen:** Ein Konto ohne Premium, eine Leistung auf „Nur Premium“ (z. B. Songtexte) – die App zeigt
    „Songtexte gibt es mit Premium.“; mit Premium oder als Admin erscheinen sie. Dann einen Code mit nur dieser
    Leistung erzeugen, einlösen: genau diese Leistung ist frei, die anderen gesperrten bleiben gesperrt (Schritt
    10.13, „So prüfst du es“).

### 10.8 Was passiert bei Kündigung, Erstattung und ohne Internet?

| Ereignis | Was der Server tut | Was am Handy passiert |
|---|---|---|
| Benutzer **kündigt** das Abo | Premium läuft bis zum bezahlten Enddatum weiter, danach endet es | Nach dem Enddatum, sobald die App den Server fragt: Offline-Musik wird **vom Gerät gelöscht**, Hinweis in der App |
| Abo **verlängert** sich | Enddatum wird hochgesetzt | nichts |
| Benutzer **wechselt die Laufzeit** (in der App) | Google erzeugt einen **neuen Kauf**, der auf den alten verweist (`linkedPurchaseToken`). Der Server führt den alten als „ersetzt“, die Lizenz wandert zum neuen Kauf; Enddatum und Laufzeit kommen vom neuen | nichts – Premium und Offline-Musik bleiben. Kurzer Zwischenstand möglich, siehe Schritt 10.14 |
| **Zahlungsproblem** (Kulanzzeit bei Google) | Premium bleibt, solange Google den Zugang verlängert | Hinweis „Zahlungsproblem – bitte in Google Play prüfen“ |
| Zahlung **ausgesetzt** / Abo **pausiert** | Premium endet sofort; zahlt der Benutzer nach, gilt es wieder | Offline-Musik wird gelöscht; nach der Zahlung muss neu geladen werden |
| **Erstattung mit Widerruf des Zugangs** (durch Google oder dich in der Play Console) | Premium endet, sobald der Server es bei Google sieht | Offline-Musik wird gelöscht |
| **Erstattung ohne Widerruf** (nur Geld zurück; das Abo bleibt bei Google bis zum Ende des Zeitraums aktiv) | Premium läuft bis zum Ende des Zeitraums weiter – der Server sieht bei Google weiter ein laufendes Abo. Soll es sofort enden: Premium im Dashboard **entziehen** | nichts, bis der Zeitraum endet oder du entziehst |
| **Code läuft ab**, Code wird samt Premium **gesperrt**, vergebenes Premium endet | Premium endet (bei Ablauf zum Enddatum, beim Sperren/Entziehen sofort) | Offline-Musik wird gelöscht – genau wie bei einem Abo |
| App ist **älter als „Sperre durchsetzen ab App-Build“** (Schalter an, kein Premium, kein Admin) | Weist das Abspielen und Laden ab (HTTP 426) | „Bitte aktualisiere die App.“ – nach dem Update gelten die Regeln dieser Tabelle |
| Du **entziehst** Premium im Dashboard | Premium endet sofort; der Kauf lässt sich nicht erneut übernehmen | Offline-Musik wird gelöscht. **Das Abo läuft bei Google weiter** – erstatte oder kündige es in der Play Console (Bestellverwaltung), sonst zahlt der Benutzer weiter |
| Handy **ohne Internet** / Server nicht erreichbar | – | Offline-Musik bleibt höchstens die **Gnadenfrist** (Standard 7 Tage seit der letzten erfolgreichen Prüfung) spielbar. Danach versucht die App einmal zu prüfen; gelingt das nicht, wird gesperrt und gelöscht |
| Google oder die Schlüsseldatei **gestört** | Antwortet der App „kann gerade nicht geprüft werden“ statt „kein Premium“ | Nichts wird gelöscht, solange die Gnadenfrist läuft |
| App wird **deinstalliert** | – | Android löscht den privaten Speicher der App samt Offline-Musik. Sie kommt auch nicht über die Google-Sicherung oder einen Geräteumzug zurück (gesichert werden nur die Einstellungen). **Das Abo endet dadurch nicht** – kündigen muss der Benutzer in Google Play |
| Premium wird **wieder aktiv** | – | Es wird nichts automatisch nachgeladen; der Benutzer lädt seine Musik neu |

Wichtig zu wissen:

- **Wie schnell merkt es der Server?** Es gibt keine Sofort-Benachrichtigung von Google. Der Server fragt bei Google
  nach, wenn die App den Premium-Stand abruft (beim Start, beim Zurückkehren, stündlich) – je Kauf höchstens alle
  `PLAY_RECHECK_HOURS` Stunden (Standard 12), rund um das Enddatum alle paar Minuten. Eine Erstattung **mit
  Widerruf** wirkt also spätestens nach einem halben Tag, wenn die App benutzt wird. Sofort geht es im Dashboard:
  *Premium-Codes › Käufe über Google Play ›* **„Neu prüfen“**.
- **Erstattung ist nicht gleich Ende.** Ob Premium nach einer Erstattung endet, hängt davon ab, ob Google dabei den
  Zugang widerruft. Erstattest du in der Play Console nur das Geld, meldet Google das Abo weiter als laufend, und
  Premium bleibt bis zum Ende des Zeitraums. Willst du sicher sein: zusätzlich im Dashboard entziehen (das wirkt
  sofort und sperrt den Kauf für eine erneute Übernahme). *Wie die Play Console die beiden Fälle heute nennt, war
  von hier aus nicht nachzusehen – siehe „Nicht geprüft“.*
- **Rund um die Verlängerung:** Ist der bezahlte Zeitraum gerade um und Google hat die Verlängerung noch nicht
  verbucht, antwortet der Server der App bis zu einer Stunde lang „kann gerade nicht geprüft werden“ statt „kein
  Premium“ – es wird nichts gelöscht. Aus demselben Grund bekommt ein Abonnent in dieser Zeit auch kein „Bitte
  aktualisiere die App.“ (HTTP 426), falls „Sperre durchsetzen ab App-Build“ gesetzt ist.
- **Google kennt einen Kauf plötzlich nicht mehr** (in der Kaufliste steht „Google kennt diesen Kauf nicht … Stimmt
  der Paketname?“): Das passiert bei einem toten Kauf – aber auch, wenn `PLAY_PACKAGE_NAME` falsch eingestellt ist.
  Der Server beendet Premium deshalb nicht sofort: Bis **3 Tage nach dem bezahlten Ende** gilt der Stand als
  „unbekannt“ (die App löscht nichts, solange ihre Gnadenfrist läuft), erst danach als beendet. Der Kauf wird
  weiter geprüft; nach der Korrektur der Einstellung lebt er von selbst wieder auf. Nur wenn Google ausdrücklich
  meldet, dass es den Kauf nicht mehr gibt (Antwort 410), endet Premium sofort.
- **Codes und Kauf zusammen:** Ein Code, der während eines laufenden Abos eingelöst wird, hängt sich hinter das
  aktuelle Abo-Ende. Verlängert Google das Abo danach, überlappen sich die Zeiten (die Code-Zeit „verfällt“ dann
  teilweise) – lös Codes also besser erst ein, wenn das Abo gekündigt ist. Endet das Abo vorzeitig (Erstattung mit
  Widerruf), beginnt die angehängte Code-Zeit sofort. Ein Code mit **Teilumfang** hängt sich nicht hinten an,
  sondern läuft sofort ab dem Einlösen (das Abo enthält seine Leistungen ja schon). Unbegrenztes Premium mit allen
  Leistungen (Code oder Vergabe) schlägt alles – so jemand braucht kein Abo und sieht keinen Kaufknopf; mit
  unbegrenztem **Teil**-Premium kann man ein Abo kaufen.
- **Premium aus Codes und aus dem Dashboard zählt für das Offline-Hören genauso wie ein Kauf** – und endet genauso:
  Nach Ablauf, Sperren oder Entziehen löscht die App die Offline-Musik. Ein Code ohne „Offline-Hören“ im Umfang
  erlaubt kein Offline-Hören.
- **Ein Kauf gehört zu einem Konto.** Derselbe Google-Kauf lässt sich nicht für ein zweites Selfify-Konto verwenden.
- **Mehrere Benutzer an einem Gerät:** Solange „Offline-Hören nur mit Premium“ **an** ist, gehört die Offline-Musik
  zu dem Konto, das sie geladen hat. Bei **jedem** Wechsel des Kontos oder des Servers wird sie gelöscht („Die
  Offline-Musik gehörte zu einem anderen Konto und wurde von diesem Gerät entfernt.“) – auch wenn das neue Konto
  selbst Premium hat oder der andere Server keine Sperre kennt. Sonst bliebe sie nach dem Ende von Premium über
  einen Kontowechsel spielbar. Wer sich ab- und mit **demselben** Konto wieder anmeldet, behält sie. Ist der
  Schalter **aus**, bleibt es wie bisher: Die Offline-Musik gehört zum Gerät und bleibt beim Wechsel liegen.
- **Die Sperre sitzt in der App – und gilt erst ab der App-Version, die sie kennt.** Der Server kann Offline-Laden
  nicht vom normalen Abspielen unterscheiden. Ältere Apps laden deshalb weiter; dagegen hilft „Sperre durchsetzen ab
  App-Build“ (Schritt 10.6): Der Server gibt zu alten Apps ohne Premium dann gar keine Musik mehr. Wer die App
  umbaut oder den Ton mitschneidet, umgeht die Sperre trotzdem – für 1 € unter Bekannten ist das vertretbar, ein
  Kopierschutz ist es nicht.

### 10.9 Was nimmt Google?

- **Servicegebühr:** Für Abos lag sie zuletzt bei **15 %**. Google hat für 2026 eine neue Gebührenordnung angekündigt;
  Berichte darüber nennen für Abos **10 % Servicegebühr plus 5 % Abrechnungsgebühr**, wenn über Google Play bezahlt
  wird (EWR, Großbritannien, USA) – zusammen also wieder etwa 15 %. Die offizielle Seite war von hier aus nicht
  abrufbar; **sieh vor dem Start selbst nach:** Play-Console-Hilfe „Servicegebühren“
  (<https://support.google.com/googleplay/android-developer/answer/112622>).
- **Umsatzsteuer:** Bei Käufern in der EU legt Google die Umsatzsteuer fest, zieht sie ein und führt sie ab
  ([Google-Zahlungscenter](https://support.google.com/paymentscenter/answer/7161449)). Der Preis in der Play Console
  ist der Preis, den der Käufer zahlt – die Steuer ist darin enthalten.
- **Überschlag, nicht verbindlich:** Von 0,99 € bleiben nach 19 % Umsatzsteuer rund 0,83 €, nach etwa 15 % Gebühr
  rund **70 Cent** im Monat je Abo. Wie Google genau rechnet, steht in deinen Auszahlungsberichten.
- Einnahmen sind zu versteuern, und wer öffentlich verkauft, braucht ein vollständiges Impressum – das ist keine
  Steuer- oder Rechtsberatung; frag im Zweifel einen Steuerberater.

### 10.10 Formulare in der Play Console anpassen

- **Datensicherheit:** zusätzlich *Finanzdaten › Kaufverlauf* angeben (erhoben, zur Funktion der App /
  Kontoverwaltung, nicht optional für Käufer). Siehe Liste in Schritt 4.
- **Store-Eintrag:** Schreib in die Beschreibung, was Premium kostet (alle Laufzeiten) und bringt – passend zu dem,
  was du unter „Premium-Leistungen“ auf „Nur Premium“ gestellt hast. Fragt ein Formular, ob die App
  In-App-Käufe enthält: „Ja“.
- **Datenschutzerklärung:** Die Vorlage unter `/datenschutz` nennt die Speicherung der Kaufkennung bereits.
- **Zugang für Prüfer** (Schritt 7): Das Prüfer-Konto `playtest` sollte Premium haben (Dashboard › Benutzer ›
  Premium), damit der Prüfer auch das Offline-Hören und die anderen Premium-Leistungen sieht – oder beschreibe unter
  „Hinweise für Prüfer“, was Premium braucht.
- **Codes:** weiterhin nur verschenken (Schritt 6).

### 10.11 Nicht geprüft – bitte selbst kontrollieren

Diese Anleitung und der Code dazu sind **ohne Play Console, ohne Google-Konto und ohne Handy** entstanden. Geprüft
ist alles, was sich mit Tests und Attrappen prüfen lässt; **ungeprüft** ist:

- **Jeder echte Kauf:** Kaufdialog, Bestätigung bei Google (ohne sie erstattet Google einen Kauf nach 3 Tagen, einen
  Testkauf nach wenigen Minuten), Verlängerung, Kündigung, Erstattung, Wiederherstellen.
- **Erstattung mit und ohne Widerruf:** Dass Google ein nur erstattetes (nicht widerrufenes) Abo bis zum Ende des
  Zeitraums als laufend meldet, stammt aus Googles Beschreibung der Schnittstelle; wie die Play Console die beiden
  Wege benennt und was sie voreinstellt, ist ungeprüft. Im Zweifel nach einer Erstattung im Dashboard „Neu prüfen“
  drücken und, wenn dort weiter „aktiv“ steht, entziehen.
- **Bestätigung durch den Server:** Dass ein Kauf **vom Server** bestätigt wurde, zeigt das Dashboard nicht an –
  nur das Gegenteil: Scheitert das Bestätigen, steht es im Protokoll und als Hinweis in der Kaufliste (Schritt
  10.7). Das Feld `acknowledged` der Schnittstelle sagt nur, dass *irgendwer* bestätigt hat. Ob das Dienstkonto
  bei Google wirklich bestätigen darf, zeigt erst ein echter Testkauf.
- **Start der Play-Version mit der Billing-Bibliothek** auf einem echten Gerät – und der Start der GitHub-Version
  ohne sie. (Ein natives Bauteil hat die GitHub-App schon einmal beim Start abstürzen lassen; deshalb steckt die
  Billing-Bibliothek nur im Play-Bundle, und die CI prüft das.)
- **Die Abfrage bei Google** (Adresse und Feldnamen der Schnittstelle `purchases.subscriptionsv2.get`) ist nach der
  Dokumentation gebaut, aber nie gegen Google gelaufen.
- **Menünamen** in Play Console und Google Cloud, die **nötigen Berechtigungen** des Dienstkontos (aus Anleitungen
  Dritter: „Finanzdaten ansehen“ und „Bestellungen und Abos verwalten“) und wie lange Google braucht, bis sie gelten.
- Ob die Play Console **vor dem Anlegen von Abos** ein hochgeladenes Bundle mit Billing-Berechtigung verlangt
  (deshalb oben: erst hochladen, dann Abo anlegen) und was sie beim **Zahlungsprofil** im Einzelnen abfragt.
- **Gebühren und Steuer** (Schritt 10.9) – nur aus Berichten, nicht von Googles eigener Seite.
- Ob 0,99 € bzw. 1,00 € in der Play Console als Preis **auswählbar** ist (Google gibt Preisgrenzen je Land vor).
- **Löschen bei der Deinstallation und Backup-Regeln:** am Code und an der Konfiguration geprüft (privater
  App-Speicher, Sicherung nur der Einstellungen), nicht auf einem Gerät.
- **Windows und iPhone:** Der Windows-Installer löscht bei der Deinstallation den Ordner der Offline-Musik
  (`%LOCALAPPDATA%\Selfify\Selfify\offline`) – der Pfad ist aus dem Code abgeleitet und **nicht an einem
  Windows-Rechner bestätigt**; wer die ZIP-Version nutzt, hat keinen Deinstaller und löscht den Ordner selbst. Das
  iPhone sichert den Dokumente-Ordner der App samt Offline-Musik in iCloud. Die Sperre und das Löschen bei
  abgelaufenem Premium gelten überall.
- **„Sperre durchsetzen ab App-Build“** ist mit Tests geprüft, nicht mit echten alten App-Versionen auf Geräten.
- **Premium Teil 2 (Laufzeiten, Angebote, Wechsel, Leistungen)** – zusätzlich ungeprüft:
  - **Ersatzmodus beim Wechsel der Laufzeit** (Schritt 10.14): Die App verlangt „Sofort abrechnen“
    (`CHARGE_FULL_PRICE`), einen der beiden Modi, die Googles Entwicklerseite für den Wechsel **zwischen Basis-Abos
    desselben Abos** nennt. **Ob der Wechsel so klappt, zeigt erst ein Testkauf.**
  - Die genauen **Menünamen** für Basis-Abos, Angebote, Phasen und die Berechtigung („Neukunden gewinnen“, „Vom
    Entwickler festgelegt“) in der deutschen Play Console. Belegt aus Googles englischer Hilfe und Entwicklerseiten:
    Basis-Abos und Angebote, die Berechtigungen *New customer acquisition / Upgrade / Developer determined*, die
    wählbaren Abrechnungszeiträume und die Regeln für Kennungen.
  - Ob 0,99 € / 4,99 € / 8,99 € als Preise **auswählbar** sind (Google gibt Preisgrenzen je Land vor).
  - **Preisänderungen bei Bestandskunden:** aus Googles Entwicklerseite „Abopreise ändern“ zusammengefasst; wie die
    Play Console das heute anbietet und wie lange die Fristen im Einzelfall sind, ist nicht ausprobiert.
  - Die Felder `lineItems[].offerDetails.basePlanId` / `offerId` der Abfrage `purchases.subscriptionsv2` (daraus liest
    der Server die Laufzeit für das Dashboard): laut Googles Schnittstellenbeschreibung und Berichten von Entwicklern
    vorhanden, aber nie gegen Google gelaufen. Fehlen sie, steht im Dashboard bei „Laufzeit“ nur „–“; Premium
    funktioniert trotzdem.
  - Dass Google **ein** Angebot für Neukunden einem Tester, der das Abo schon hatte, nicht mehr anbietet (Entwickler
    berichten teils Abweichungen beim Testen).
  - Das Play-Bundle mit dem jetzt direkt eingebundenen `in_app_purchase_android` und die GitHub-APK mit dem dritten
    Platzhalter auf einem echten Gerät.

### 10.12 Zurück auf die vorherige Server-Version (Rücksprung)

**Nur Premium Teil 2 zurücknehmen** (Laufzeiten, Leistungen, Codes mit Umfang; der Kauf über Google Play bleibt):

1. In der Karte „Premium-Leistungen“ alles außer Offline-Hören auf „Für alle“ stellen, das Abzeichen aus, speichern.
2. Sicherung des Datenordners anlegen.
3. Mit der noch laufenden neuen Version: `docker exec -u 99:100 selfify alembic downgrade 0007`
   Das entfernt den Umfang von Codes und Lizenzen und die Laufzeit der Käufe. **Lizenzen und Codes mit Teilumfang
   werden dabei zu vollem Premium** (die alte Version kennt keinen Umfang). Die neuen Einstellungen bleiben in der
   Datenbank liegen, die alte Version beachtet sie nicht.
4. Gleich danach auf das alte Image umstellen. Wer bei Google auf eine andere Laufzeit gewechselt hat, behält Premium
   (der Kauf bleibt verbucht, nur die Anzeige der Laufzeit fehlt). Die neue App zeigt gegen den alten Server alle
   Laufzeiten, die Google liefert (ohne Reihenfolge und „Empfohlen“ aus dem Dashboard), und keine Sperren der neuen
   Leistungen.

*Geprüft ist die Rückwärts-Migration mit einem automatischen Test, nicht im laufenden Unraid-Container.*

**Ganz zurück auf die Version vor dem Kauf über Google Play:** Falls nach dem Update etwas nicht stimmt und du den
Server auf die Version **vor** dem Kauf über Google Play zurückstellen willst:

1. **Zuerst die Schalter aus:** „Premium in der Play-Version zum Kauf anbieten“ und – wenn niemand seine Musik
   verlieren soll – „Offline-Hören nur mit Premium“ ausschalten, speichern. (Die alte Server-Version kennt beide
   Schalter nicht; die neue App verhält sich gegen einen alten Server wie ohne Schalter.)
2. **Sicherung** des Datenordners (`/mnt/user/appdata/selfify/`) anlegen.
3. **Datenbank zurückstellen, solange noch die neue Version läuft** – im Unraid-Terminal (als der Benutzer, unter
   dem der Server läuft, damit die Dateirechte stimmen):

   ```bash
   docker exec -u 99:100 selfify alembic downgrade 0006
   ```

   (Von der Version mit Premium Teil 2 aus nimmt derselbe Befehl Teil 2 gleich mit zurück – siehe oben.)

   Das entfernt die Tabelle der Käufe. Lizenzen aus Käufen bleiben als Historie stehen, werden aber **beendet** und
   als Vergabe mit dem Vermerk „Abo über Google Play (beendet beim Rücksprung) …“ geführt: Die alte Version kennt
   Käufe nicht (ihre Lizenzliste im Dashboard scheiterte sonst mit einem Fehler) und könnte nicht mehr prüfen, ob
   das Abo noch bezahlt wird.
4. Den Container **gleich danach** auf das alte Image umstellen. Startet vorher noch einmal die neue Version, zieht
   sie die Datenbank von selbst wieder hoch – dann Schritt 3 wiederholen.

*Geprüft ist die Rückwärts-Migration selbst (mit Bestandsdaten, automatischer Test); der Befehl im laufenden
Unraid-Container ist nicht ausprobiert – deshalb die Sicherung aus Schritt 2.*

Was das für Käufer heißt: **Ihr Abo läuft bei Google weiter und wird weiter abgebucht**, Premium haben sie auf dem
alten Server aber nicht mehr. Gib ihnen für die Zwischenzeit Premium von Hand (*Benutzer › Premium*) oder kündige/
erstatte die Abos in der Play Console. Nach einem erneuten Update auf die neue Version stellt **„Käufe
wiederherstellen“** in der App das gekaufte Premium wieder her (die Datenbank wird beim Start von selbst wieder
hochgezogen). Ohne Schritt 3 kennt die alte Version den Stand der Datenbank nicht und startet nicht – dann die
neue Version noch einmal starten und Schritt 3 nachholen.

### 10.13 Premium-Leistungen festlegen

Dashboard › **App-Einstellungen › Premium-Leistungen**. Je Leistung wählst du **„Für alle“** oder **„Nur
Premium“**. **Standard ist alles „Für alle“** – solange du nichts umstellst, verhalten sich Server und Apps genau wie
vor diesem Update. **Admins sind nie eingeschränkt.** Die Schalter gelten für alle App-Ausgaben (Play, GitHub,
Windows, iPhone); Premium gibt es außerhalb der Play-Version per Code oder von dir.

| Leistung | Ohne Premium, wenn „Nur Premium“ | Einstellung dazu | Wo durchgesetzt |
|---|---|---|---|
| **Offline-Hören** | Nichts aufs Gerät laden; vorhandene Offline-Musik wird gelöscht (Schritt 10.6, 10.8) | Gnadenfrist, „Sperre durchsetzen ab App-Build“ (Karte darunter) | **App**; ältere Apps nur über „Sperre durchsetzen ab App-Build“ |
| **Keine Werbung** | Werbung (Banner), wenn du sie eingeschaltet hast (Schritt 5) | – nicht schaltbar: immer ein Premium-Vorteil | **App** (nur Play-Version) |
| **Höhere Tonqualität** | Musik kommt höchstens in „Normal“ (160 kbit/s) oder „Datensparend“ (96 kbit/s) – auch beim Offline-Laden. In der App tragen höhere Stufen ein Schloss; die gespeicherte Einstellung bleibt und gilt mit Premium wieder | „Höchstens Normal (160 kbit/s)“ (Standard) oder „Höchstens Datensparend (96 kbit/s)“ | **Server** – er wandelt den Titel mit **ffmpeg** um. Fehlt ffmpeg, steht dort „ffmpeg fehlt auf dem Server – diese Leistung lässt sich nicht einschränken.“ und die Zeile lässt sich nicht auf „Nur Premium“ stellen |
| **Videos ansehen** | Videos laufen nur als Ton. Die App zeigt „Videos ansehen gibt es mit Premium.“ und die Knöpfe „Als Ton abspielen“ / „Zu Premium“ | – | **Server** (das Video selbst wird ohne Premium nicht ausgeliefert, der Ton schon) |
| **Songtexte** | Keine Songtexte; die App zeigt „Songtexte gibt es mit Premium.“ | – | **Server** |
| **Mehr Song-Wünsche** | Höchstens **N Wünsche in 7 Tagen**; die App zeigt „Noch 2 von 3 Wünschen diese Woche“. Mit Premium ohne Wochengrenze | „Wünsche pro Woche“ (Standard 3, 0–100; **0 = ohne Premium gar keine Wünsche**) | **Server** |
| **Überspringen** | Höchstens **N-mal pro Stunde** „Weiter“; danach „Du hast in dieser Stunde schon N-mal übersprungen. Mit Premium unbegrenzt.“ | „Mal pro Stunde“ (Standard 6, 1–100) | **nur App** (siehe unten) |
| **Auf anderen Geräten abspielen** | Die Geräte-Liste ist ausgegraut mit „Auf anderen Geräten abspielen gibt es nur mit Premium.“ und „Premium ansehen“; kein Übertragen, kein Fernsteuern, kein automatisches Anhalten – jedes Gerät spielt nur für sich | – | **Server** (beim Verbinden, alle 25 s und sofort nach Änderungen im Dashboard). **Codes mit Teilumfang** enthalten es nur, wenn es angehakt war – auch ältere Teilumfang-Codes nicht |
| **Premium-Abzeichen** | – (kein „Für alle“: es ist ein Ein/Aus) | Haken „Premium-Nutzer bekommen ein Abzeichen im Profil“ (Standard aus) | **App**; sieht nur der Benutzer selbst in seinem Profil (Einstellungen) |

Die Zusatzfelder (Qualität, Wünsche, Überspringen) sind ausgegraut, solange die Zeile auf „Für alle“ steht; ihr Wert
wird trotzdem gespeichert.

**Die Premium-Texte der App passen sich an:** Lässt du unter „Premium und Offline-Hören“ die Vorteile leer, listet
die Premium-Seite genau die Leistungen auf, die auf „Nur Premium“ stehen (z. B. „Beste Tonqualität – ohne Premium
höchstens 160 kbit/s“, „Unbegrenzt überspringen – ohne Premium 6-mal pro Stunde“). Steht nur Offline-Hören auf „Nur
Premium“, bleiben die Texte wörtlich wie bisher. Eigene Vorteile-Zeilen im Dashboard haben immer Vorrang – passe sie
dann selbst an.

**Ehrliche Grenzen:**

- **Überspringen lässt sich nur in der App begrenzen.** Der Server sieht nicht, wann jemand „Weiter“ drückt. Ältere
  App-Versionen zählen gar nicht mit; wer die App neu installiert oder ihre Daten löscht, fängt von vorn an. Nicht
  gezählt werden: Weiterspielen am Titelende, „Zurück“, Spulen und die Wahl eines früheren Titels in der Warteschlange.
  Ebenfalls nicht gezählt: das **Antippen eines anderen Titels in einer Liste** (Album, Playlist, Suche) – das startet
  die Liste neu und ist kein „Weiter“. Und **startet die App ohne Verbindung** (Einstellungen unbekannt), gilt bis zur
  nächsten Verbindung keine Grenze.
- **Qualität während eines Titels:** Endet Premium oder stellst du „Höhere Tonqualität“ auf „Nur Premium“, während
  jemand gerade in Originalqualität hört, kann das Spulen in diesem einen Titel abbrechen (der Server liefert unter
  derselben Adresse jetzt die gedeckelte Fassung). Der nächste Titel läuft normal.
- **Wünsche** zählen rollierend über die letzten 7 Tage (nicht Montag bis Sonntag). Ein zurückgezogener offener
  Wunsch gibt seinen Platz wieder frei. Die allgemeinen Grenzen gegen Missbrauch (höchstens 20 offene Wünsche,
  15 pro Tag) gelten für alle, auch mit Premium. Ohne Grenze („Für alle“) gilt nur diese allgemeine Grenze, wie bisher.
- **Ältere Apps** kennen die neuen Sperren nicht: Die Tonqualität wird trotzdem vom Server gedeckelt (die Musik
  läuft, nur leiser in der Qualität), bei gesperrten Videos und Songtexten zeigen sie nur eine allgemeine
  Fehlermeldung, Überspringen bleibt frei, und **jedes** Premium macht dort werbefrei (auch ein Code ohne „Keine
  Werbung“).
- **Kopierschutz ist das nicht.** Wer die App umbaut, umgeht die Sperren, die nur in der App sitzen (Offline,
  Überspringen, Werbung). Was der Server durchsetzt (Qualität, Videos, Songtexte, Wünsche), gilt auch dann.

**Reihenfolge:** Erst Familie und Freunden Premium geben (*Benutzer › Premium* oder Codes), **dann** Leistungen
auf „Nur Premium“ stellen – sonst merken sie es zuerst.

**So prüfst du es (Ende-zu-Ende):**

1. Unter Premium-Leistungen z. B. Offline-Hören, Höhere Tonqualität, Videos und Songtexte auf „Nur Premium“ stellen.
2. *Premium-Codes › Neue Codes erzeugen*: „Alle Leistungen“ abhaken, nur **Videos ansehen** und **Songtexte**
   anhaken, Code erzeugen. In der Liste steht bei „Umfang“: „Videos ansehen, Songtexte“.
3. Mit einem Konto ohne Premium einlösen. Erwartet: Videos und Songtexte gehen; Offline-Laden ist gesperrt; die
   Qualität ist gedeckelt. Im Benutzer-Dialog steht die Lizenz mit demselben Umfang, in der Benutzerliste
   „Teilumfang“.
4. Mit einem Admin-Konto: alles geht, auch ohne Premium.

### 10.14 Laufzeit wechseln – was Nutzer erleben

- **In der App:** Wer ein laufendes Abo hat, sieht bei seiner Laufzeit „Dein Abo“ und bei den anderen den Knopf
  **„Zu … wechseln“** (z. B. „Zu Jährlich wechseln“). Es öffnet sich der Kaufdialog von Google; danach meldet die App
  „Laufzeit gewechselt. Google rechnet die restliche Zeit deines bisherigen Abos an.“
- **Abrechnung:** Die App verlangt bei Google den Wechsel **sofort mit voller Zahlung** (`CHARGE_FULL_PRICE`,
  „Sofort abrechnen“): Die neue Laufzeit wird gleich bezahlt, die schon bezahlte Restzeit des alten Abos hängt Google
  anteilig hinten an – es geht also nichts verloren. Das ist einer der beiden Modi, die Google für den Wechsel
  **zwischen Basis-Abos desselben Abos** vorsieht (der andere wäre „Zum nächsten Abrechnungsdatum“). „Erst zum
  Laufzeitende wechseln“ bietet die App nicht an.
- **Vorbehalt (ungeprüft):** Ob Google den Wechsel so annimmt, zeigt erst ein Testkauf. Lehnt Google ihn ab
  (Fehlermeldung „Der Kauf hat nicht geklappt: …“ in der App), melde das – dann muss die App angepasst werden. Bis
  dahin können Käufer die Laufzeit in Google Play selbst ändern oder kündigen und neu abschließen.
- **Google Play gestört:** Lässt sich das laufende Abo gerade nicht abfragen, sagt die App „Google Play ist gerade
  nicht erreichbar. Versuche den Wechsel bitte gleich noch einmal.“
- **Anderes Google-Konto:** Gehört das Abo zu einem anderen Google-Konto als dem auf dem Handy, sagt die App „Dein
  Abo gehört zu einem anderen Google-Konto. Wechsle die Laufzeit bitte dort in Google Play.“
- **Zahlungsproblem, pausiert, ausstehend:** Dann gibt es keine Wechsel-Knöpfe, nur „Abo verwalten“.
- **Auf dem Server:** Google erzeugt beim Wechsel einen **neuen Kauf**, der auf den alten verweist
  (`linkedPurchaseToken`); der alte endet bei Google. Der Server führt den alten als „ersetzt“, hängt die Lizenz an
  den neuen Kauf und zeigt dessen Laufzeit im Dashboard. Es entsteht kein doppeltes Premium.
- **Kurzer Zwischenstand:** Kommt der neue Kauf nicht gleich beim Server an (Netz weg, App geschlossen), sieht der
  Server kurz nur den beendeten alten Kauf. Die App löscht in dieser Zeit keine Offline-Musik, solange sie sich den
  neuen Kauf gemerkt hat; spätestens beim nächsten Start meldet sie ihn nach. Ist die App genau dazwischen
  abgestürzt, kann Premium bis zum nächsten Start fehlen.
- **Angebote beim Wechsel:** Ein Gratis- oder Einführungsangebot für Neukunden bekommt beim Wechsel in der Regel
  niemand, der das Abo schon hat.

## Checkliste

- [ ] Server aktualisiert, `PUBLIC_URL` und `OPERATOR_*` gesetzt, `/datenschutz` und `/impressum` angesehen
- [ ] GitHub-Variable `PLAY_SERVER_URL` gesetzt (`https://…`), danach neu gebaut (Protokoll: „Feste Server-Adresse: …“), Anmeldung in der Play-Version zeigt kein Server-Feld und klappt mit einem echten Konto
- [ ] Demo-Server mit lizenzfreier Musik und Konto `playtest`
- [ ] Play Console: App angelegt, Bundle im geschlossenen Test, 12 Tester über 14 Tage
- [ ] Datenschutz-Link, Konto-löschen-Link, Datensicherheit, Zielgruppe, Inhaltseinstufung, App-Zugriff ausgefüllt
      (Registrierung an: in der Inhaltseinstufung „Nutzer können interagieren / Inhalte teilen“)
- [ ] AdMob: App-ID und Banner-ID als GitHub-Variablen, Einwilligungsmeldung eingerichtet
- [ ] Dashboard: Werbung **an**, wenn alles getestet ist
- [ ] Premium-Codes nur verschenkt

**Zusätzlich, wenn du Premium verkaufst (Schritt 10):**

- [ ] Zahlungsprofil fertig; Abo mit **drei** aktiven Basis-Abos (`monatlich`, `halbjaehrlich`, `jaehrlich`, Preise
      festgelegt) angelegt, Produkt-ID und Kennungen notiert
- [ ] Angebote (falls gewünscht) mit Berechtigung „Neukunden gewinnen“, **nicht** „Vom Entwickler festgelegt“
- [ ] Dashboard › Laufzeiten: Kennungen eingetragen, Reihenfolge und „Empfohlen“ gesetzt (oder leer = alle)
- [ ] Lizenztester eingetragen
- [ ] Dienstkonto angelegt, API aktiviert, in der Play Console für die App berechtigt
- [ ] `play-service-account.json` liegt in `/mnt/user/appdata/selfify/` (Rechte 600, Besitzer 99:100), nirgends sonst
- [ ] Dashboard: „Kaufprüfung eingerichtet“, „Verbindung testen“ grün, Produkt-ID eingetragen, Kauf eingeschaltet
- [ ] Premium-Texte geschrieben (oder leer gelassen – dann passen sich die Texte der App den Leistungen an),
      Gnadenfrist gewählt
- [ ] Familie/Freunde haben Premium, **danach** „Offline-Hören“ (und weitere Leistungen) auf „Nur Premium“ gestellt
- [ ] Für „Höhere Tonqualität“: ffmpeg auf dem Server vorhanden (sonst lässt sich die Zeile nicht umstellen)
- [ ] Neue App-Version überall verteilt, **danach** „Sperre durchsetzen ab App-Build“ auf ihre Build-Nummer gesetzt
      (vorher laden ältere Apps weiter); mit einem Konto ohne Premium und alter App: „Bitte aktualisiere die App.“
- [ ] Testkauf mit Lizenztester: Premium aktiv, Kauf im Dashboard, **keine** Erstattungs-Mail nach einigen Minuten
- [ ] Server hat den Testkauf selbst bestätigt: im Protokoll **keine** Zeile „… konnte bei Google nicht bestätigt
      werden“ (die ausbleibende Erstattungs-Mail allein beweist das nicht – auch das Handy bestätigt)
- [ ] Code getestet: schaltet Offline-Hören frei; nach Entziehen/Sperren wird die Offline-Musik gelöscht
- [ ] Kündigung getestet: Nach Ablauf wird die Offline-Musik vom Gerät gelöscht
- [ ] Laufzeitwechsel getestet (jährlich → monatlich): alter Kauf „ersetzt“, neuer mit Laufzeit `monatlich`, Premium
      ohne Unterbrechung – oder, falls Google den Wechsel ablehnt, gemeldet (Schritt 10.14)
- [ ] Angebot mit einem neuen Tester gesehen; beim Tester mit früherem Kauf nicht
- [ ] Code mit Teilumfang getestet: genau diese Leistungen frei, andere gesperrt
- [ ] „Käufe wiederherstellen“ auf zweitem Gerät; anderes Selfify-Konto wird abgelehnt
- [ ] Play-Version **und** GitHub-Version starten auf einem echten Handy
- [ ] Datensicherheit um „Kaufverlauf“ ergänzt; Gebühren auf Googles Seite nachgelesen
- [ ] Registrierungsmodus geprüft und Data-Safety-Angaben passend (Kontoerstellung, Konto löschen inkl. „Registrierung zurückziehen“, Anzeigename sichtbar, IP-Adresse)
- [ ] Data-Safety-Angaben um „Auf anderen Geräten abspielen“ ergänzt (Gerätename/-typ, Wiedergabe-Status, nur eigenes Konto, nicht gespeichert)
