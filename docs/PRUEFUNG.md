# Abschließende Prüfung – Fortschritt

Unabhängige Prüfung des ganzen Projekts in sieben Bereichen. Jeder Fund wird vor dem Beheben im Code
nachvollzogen und bekommt einen Test, der ohne die Korrektur fehlschlägt.

Stand: 15.10.2026 (PR #1 ist zusammengeführt, App-Kern und Teil B kommen in PR #2)

## Bereiche

| Bereich | Prüfung | Funde | Behoben |
|---|---|---|---|
| Server-Sicherheit | ✅ fertig | 6 | 6 |
| Server-Logik | ✅ fertig | 11 | 11 |
| Schnittstelle App ↔ Server | ✅ fertig | 6 | 6 |
| Docker, Unraid, CI, Anleitung | ✅ fertig | 7 | 7 |
| App-Kern (Player, Offline, Downloads, Anmeldung) | ✅ fertig | 9 | 9 |
| App-Bildschirme Teil A (Start, Suche, Bibliothek, Details) | ✅ fertig | 5 | 5 |
| App-Bildschirme Teil B (Player, Downloads, Konto, Verwaltung) | ✅ fertig | 5 | 5 |

## Server-Sicherheit – alle behoben (Commit 19f3d3c)

- [x] Fremde konnten jedes Konto mit 10 falschen Passwörtern aussperren → Sperre je Benutzer **und** IP
- [x] Präpariertes Cover-Bild (100 Megapixel, wenige KB) fror den Server ein → Hilfs-Thread, Größengrenze
- [x] Lange japanische/Emoji-Titel: Dateiname über 255 Byte, Download scheiterte → Kürzen nach Bytes
- [x] Gleicher Song für zwei Familienmitglieder: zweiter bekam fremden Auftrag, Playlist ging verloren
- [x] Downloads überschrieben gleichnamige `.lrc`/`.jpg`, Löschen entfernte fremde Begleitdateien
- [x] Live-Verbindung blieb nach Sperre/Abmeldung/Entzug der Admin-Rechte offen

## Server-Logik – alle behoben

- [x] **kritisch** – Fehlender/nicht eingehängter Rubrik-Ordner löscht beim Scan alle Titel samt Playlists,
      Likes und Verlauf (`server/app/library/scanner.py:224`)
- [x] **hoch** – Scanner hält die SQLite-Schreibsperre über langsame Dateizugriffe: API-Fehler 500,
      Download-Worker sterben (`scanner.py:265`)
- [x] mittel – Neu-Nummerierung nach Entfernen von Titeln verwürfelt Playlist-Reihenfolge
      (`services/playlists.py:238`)
- [x] mittel – Jeder laufende Stream/Cover hält eine DB-Verbindung bis zum letzten Byte: 15 Streams
      blockieren die API (`routers/media.py:75`)
- [x] mittel – Später hinzugefügtes `cover.jpg`/`folder.jpg` wird nie übernommen (`scanner.py:243`)
- [x] mittel – Songs aus YouTube-Links (ohne thumbnail_url) bekommen kein Cover (`downloads/ytdlp.py:66`)
- [x] mittel – Container-Neustart markiert laufende Downloads als „abgebrochen“ statt sie neu einzureihen
      (`downloads/manager.py:341`)
- [x] mittel – WMA wird ungewandelt an Android geschickt, dort nicht abspielbar (`library/transcode.py:222`)
- [x] niedrig – Abbrechen während der Verarbeitung wird ignoriert (`manager.py:224`)
- [x] niedrig – Gleichzeitiges Aufräumen des Umwandlungs-Speichers kann Stream mit 500 abbrechen
      (`transcode.py:281`)
- [x] niedrig – Selbst aktualisiertes yt-dlp bleibt aktiv, auch wenn YTDL_AUTO_UPDATE=false (`ytdlp.py:52`)

## Schnittstelle App ↔ Server – alle behoben

- [x] mittel – Token-Erneuerung kann die Fehler-Warteschlange von dio blockieren: Anfragen hängen für immer
      (`mobile/lib/data/api.dart:144`)
- [x] mittel – Gespeicherte Ziel-Rubrik wird ungeprüft gesendet: alle Downloads scheitern mit
      „Rubrik nicht gefunden“ (`mobile/lib/state/downloads.dart:168`)
- [x] niedrig – Fertig-Meldungen enden nach Abmelden→Anmelden (`downloads.dart:67`)
- [x] niedrig – Download-Knopf verwechselt Song und Video mit gleicher YouTube-ID (`downloads.dart:36`)
- [x] niedrig – Verlorene Antwort bei Token-Erneuerung + über 60 s offline meldet das Gerät ab
      (`server/app/services/auth.py:94`)
- [x] niedrig – Medien-Token läuft nach 7 Tagen ab, eingereihte Titel spielen dann nicht mehr
      (`mobile/lib/player/audio_handler.dart:202`)

## Docker, Unraid, CI, Anleitung – alle behoben

- [x] **hoch** – Weg B: Schon der erste Lauf startet den Container, das Admin-Passwort aus dem Log geht
      beim dokumentierten zweiten Lauf verloren (`unraid/selfify-update.sh:39`)
- [x] mittel – PUID=0 lässt das Startskript endlos neu starten (`server/entrypoint.sh:10`)
- [x] mittel – Anleitung zum Reverse Proxy erwähnt keine Zeitlimits (lange Umwandlungen/Aufrufe)
      (`README.md:87`) – Anleitung ergänzt, App wartet bei Offline-Downloads bis 15 Min.
- [x] niedrig – Alte yt-dlp-Kopie in /data überdeckt neuere im Image (`ytdlp.py:52`, wie oben)
- [x] niedrig – iOS: `NSAllowsLocalNetworking` hebt `NSAllowsArbitraryLoads` auf, http im Heimnetz
      per Hostname blockiert (`mobile/ios/Runner/Info.plist:79`)
- [x] niedrig – README: „best“ verspricht 4K, YTDL_VIDEO_MAX_HEIGHT begrenzt aber auf 1080 (`README.md:247`)
- [x] niedrig – README: Konsolen-Befehle funktionieren so nicht in „Container-Symbol → Console“
      (`README.md:303`)

## App-Bildschirme Teil A – alle behoben

- [x] **hoch** – Admin: „Datei vom Server löschen“ im Song-Menü löscht nie und zeigt einen Fehler
      (`mobile/lib/ui/widgets/track_menu.dart:145`)
- [x] mittel – „Zu Playlist hinzufügen“ meldet einen Fehler, wenn der Server länger als 200 ms braucht
      (`mobile/lib/ui/widgets/playlist_picker.dart:58`)
- [x] niedrig – Playlist mit doppeltem Song: Tippen auf die zweite Kopie spielt ab der ersten
      (`mobile/lib/ui/widgets/track_tile.dart:47`)
- [x] niedrig – Kurz vor „Fertig“ hinzugefügte Songs fehlen auf der Playlist-Seite
      (`mobile/lib/ui/screens/library_playlist_sheets.dart:253`)
- [x] niedrig – Knopfleiste auf der Künstlerseite läuft bei großer Schrift über
      (`mobile/lib/ui/screens/artist_screen.dart:268`) – dazu neuer Test „kleines Handy mit großer Schrift“
      für alle Bildschirme; er fand drei weitere Überläufe (Geräte, Rubrik, leere Listen), alle behoben

## App-Kern – alle behoben

- [x] **hoch** – Zufallswiedergabe: „Als Nächstes spielen“, „Zur Warteschlange“ und Autoplay landen an
      zufälligen Stellen, oft vor dem aktuellen Song – sie werden dann nie gespielt (`audio_handler.dart:254`)
      – eigene Zufallsreihenfolge (`player/queue_shuffle_order.dart`)
- [x] mittel – Knopf „Zufallswiedergabe“ startet immer mit dem ersten Titel (`audio_handler.dart:236`)
- [x] mittel – Wechsel von WLAN zu mobilen Daten stellt die Warteschlange nicht auf die Mobil-Qualität um
      (`player.dart:26`) – kommende Titel bekommen neue Links, der laufende spielt ohne Unterbrechung weiter
- [x] mittel – Offline-Modus: Autoplay/Radio streamt trotzdem nicht heruntergeladene Songs (`player.dart:53`)
- [x] mittel – Download-Liste: Aktualisieren überschreibt neuere Live-Meldungen (fertiger Download steht
      ewig auf „lädt“), Fertig-Meldungen während Verbindungsabbruch gehen verloren (`downloads.dart:92`)
- [x] niedrig – Offline-Warteschlange läuft nach dem Neustart nicht weiter, wenn die Anmeldung später geladen
      wird (`offline.dart:294`)
- [x] niedrig – Entfernen eines Songs, der gerade aufs Handy lädt, speichert ihn trotzdem (`offline.dart:252`)
- [x] niedrig – Schlaf-Timer „Ende des Titels“ beim letzten Song: Play-Knopf reagiert danach nicht
      (`audio_handler.dart:184`)
- [x] niedrig – Autoplay hört nach einer Runde auf, wenn es per „Weiter“ im Pausenzustand ausgelöst wurde
      (`audio_handler.dart:199`)

Tests: `player_queue_test.dart` (nachgebautes just_audio), `downloads_refresh_test.dart` (echter WebSocket),
`offline_queue_test.dart` (echtes Dateisystem) – jeder schlägt ohne die Korrektur fehl.

## App-Bildschirme Teil B – alle behoben

- [x] **hoch** – Rubrik löschen entfernt die Titel aus allen Playlists, Lieblingssongs und Verläufen der
      Familie, die Abfrage behauptet aber, es gehe nichts verloren (`mobile/lib/ui/screens/admin_categories.dart:17`)
      – Abfrage nennt jetzt die Folgen, bei Rubriken mit Titeln muss der Name eingetippt werden.
      Offen als Vorschlag: Rubrik am Server nur ausblenden statt löschen (Daten blieben erhalten)
- [x] mittel – Warteschlange: Wischt man eine von zwei direkt aufeinanderfolgenden Kopien desselben Songs weg,
      verschwindet die andere unsichtbar mit (`mobile/lib/ui/screens/queue_screen.dart:49`)
- [x] mittel – Verwaltung „Alle“ Downloads: Für ein anderes Familienmitglied wiederholter/abgebrochener Auftrag
      friert ein und zählt beim Admin als „läuft“ (`mobile/lib/ui/screens/downloads_screen.dart:144`)
- [x] niedrig – Mini-Player-Herz: Fehler beim Liken (z. B. offline) werden verschluckt
      (`mobile/lib/ui/widgets/mini_player.dart:58`)
- [x] niedrig – Verwaltung: „Alle Downloads ansehen“ öffnet nur die eigenen (`admin_downloader.dart:118`)

Tests: `player_screens_test.dart`, `admin_screens_test.dart` – jeder schlägt ohne die Korrektur fehl.

## Sonstiges

- [x] Android-Build: NDK-Download brach ab (CI rot bei 93f6c7c) → eigener Schritt mit 3 Versuchen
- [x] „Stoppen“ direkt nach dem Start eines Downloads ging verloren (Abbruch-Signal entstand erst nach der
      Vorbereitung; CI rot bei 0a0374a) → Signal wird schon beim Übernehmen angelegt (`downloads/manager.py`)

## Abschlussprüfung von PR #2

- [ ] Unabhängige Gegenprüfung des ganzen PR-Stands auf Rückschritte (Workflow `wf_e930ef2d-137`) – ist
      ohne Ergebnis abgebrochen; PR #2 ist inzwischen gemergt. Bei Bedarf neu starten.

## Gegenprüfung von PR #4 (Anmelde-Diagnose + Update-Hinweis)

Workflow `wf_0cfa73a2-740`: 11 Funde, 10 bestätigt (der Desugaring-Fund war schon behoben).

- [x] hoch – Android-Build scheiterte: ota_update braucht Core Library Desugaring (`build.gradle.kts`)
- [x] mittel – „Abbrechen“/Zurück stoppte den Download nicht, der Installer ging später trotzdem auf
      → Abbrechen ruft jetzt `OtaUpdate().cancel()` (`state/app_update.dart`)
- [x] mittel – ota_update 7.1.0 vertauscht „läuft schon“ und „Installationsfehler“ zwischen Java und Dart:
      Die App riet fälschlich zum Deinstallieren (Offline-Musik weg) → beide heißen jetzt „läuft schon“
- [x] mittel – Gemerkte Prüfsumme veraltet, sobald auf main neu gebaut wurde („Datei beschädigt“ in
      Dauerschleife) → vor jedem Installieren und bei „Erneut versuchen“ wird `version.json` neu geholt
- [x] mittel – Hinweis-Banner auf schmalen Handys/großer Schrift zerquetscht → Knöpfe in eigener Zeile
- [x] niedrig/mittel – Ohne Signaturschlüssel wurden Updates angeboten, die Android ablehnen muss → CI
      veröffentlicht `version.json` (und baut die Update-Adresse ein) nur noch mit festem Schlüssel
- [x] niedrig – Einstellungen meldeten „neueste Version“, obwohl die Prüfung scheiterte (offline)
- [x] niedrig – `https://` auf einen reinen HTTP-Port wurde als Zertifikatsfehler gemeldet → Hinweis auf
      `http://` (`data/api.dart`)
- [x] niedrig – Update-Hinweis fehlte auf dem Anmeldebildschirm → dort jetzt ebenfalls
- [x] zusätzlich – Doppeltipp auf „Installieren“ öffnete zwei Dialoge (störte den laufenden Download)

Tests: `app_update_test.dart` (u. a. mit nachgebildeter Android-Seite des Plugins), `server_probe_test.dart`.

## Windows-App (PR #5)

Vorab Planung mit Gegenkritik (`wf_a53e5ff2-5d0`), danach Gegenprüfung des PRs (`wf_3fa73ce4-8fa`, 3 Blickwinkel).

- [x] blockierend – Weiterschalten, während ein Titel noch öffnet, hängte die Wiedergabe (libmpv-Ladevorgang
      endet nie) → überholte Ladevorgänge werden beendet (`player/windows_audio.dart`)
- [x] mittel – Weiter/Warteschlangen-Klick/Spulen während des Öffnens wurden verschluckt (just_audio ignoriert
      Spulen bei „lädt“) → eigene Ladevorgänge melden „puffert“, Spulen wird nachgeholt
- [x] mittel – Ziehen mit der Maus überall: Klicks mit 1–2 px Mausbewegung gingen verloren, Text ließ sich
      nicht markieren → app-weites Maus-Ziehen entfernt (Mausrad/Scrollleiste)
- [x] Windows meldet „keine Verbindung“, wenn sein Internet-Test scheitert → am Computer nie „offline“
- [x] Leertaste startete auf der Videoseite zusätzlich die Musik; auf fokussierten Knöpfen betätigt sie jetzt
      den Knopf; gedrückt halten schaltet nur einmal um
- [x] Strg+F bei offenem Dialog zog den Fokus hinter den Dialog; Alt+← umging PopScope
- [x] Player-Leiste bei großer Windows-Schrift zu niedrig; Songtext/Warteschlange-Knöpfe auf Vollbildseiten
      ohne Wirkung → ausgeblendet
- [x] fehlende libmpv-2.dll verhinderte den Start → App startet, Abspielen meldet den Grund; CI prüft die DLL
- [x] Installer: nur pro Benutzer, fester Ordner (kein Löschen von „data“ in fremden Ordnern)
- [x] Folgeschritt: systemweite Medientasten und Windows-Medienübersicht (smtc_windows, flutter_rust_bridge
      exakt 2.11.1); Medientasten im Fenster nur ohne Medienübersicht (sonst doppelt)
- [x] Folgeschritt: Update-Hinweis für Windows (version.json mit Windows-Installer, Prüfsumme, stilles Update
      mit Neustart; ZIP-Variante bekommt den Assistenten)
- [ ] offen: Fenstergröße merken, lückenlose Übergänge zwischen Titeln
- [x] Videoplayer am PC ohne Lautstärkeregler (nur Stummschalten) → Regler in der Leiste des Videos (auch im
      Vollbild), ↑/↓ lauter/leiser, M stumm mit Anzeige im Bild; gleiche Lautstärke wie die Musik (Strg+↑/↓ und
      Regler wirken auf beides, bleibt für den nächsten Start gespeichert). Tests mit nachgebautem Videoplayer
- [x] Gegenprüfung Lautstärke (`wf_10a680b2-ff7`):
      - mittel – „Ton an“ sprang auf 100 %, weil Player-Leiste und Video sich den Wert vor dem Stummschalten
        getrennt merkten → gemeinsam (`toggleDesktopMute`), ohne gemerkten Wert halbe Lautstärke
      - mittel – gleiche Einstellung, ungleich laut: libmpv (Musik) rechnet die Lautstärke kubisch, der
        Videoplayer von Windows linear (30 % ≈ 20 dB lauter) → Video bekommt unter Windows dieselbe Kurve
      - mittel – Hochkant-Video/kleines Fenster: Leiste lief über, Vollbild-Knopf nicht mehr klickbar, Zeitangabe
        abgeschnitten → schmaler Player: nur Lautsprecher-Knopf (↑/↓ gehen weiter)
      - mittel – beim langen Ziehen am Regler blendete chewie die Leiste aus → Ziehen zählt wie Mausbewegung
      - niedrig – zehnmal „leiser“ ergab 1e-16 statt 0 (kein „Stumm“, M brachte keinen Ton) → auf ganze Prozent
        gerundet; Tab erreichte Lautsprecher/Regler (Leertaste wirkte doppelt) → nicht per Tab erreichbar;
        Lautstärke-Anzeige lief bei schmalem Player über → verkleinert sich
      - geprüft, kein Fehler: Strg+↑/↓ auf der Videoseite (wirkt, ohne Anzeige – gewollt)

### Gegenprüfung PR #6 (`wf_0d99c533-5a2`)

- [x] mittel – Scheiterte im Windows-Job das Herunterladen von version.json kurz, wurde sie durch eine reine
      Windows-Datei ersetzt (Handys ohne Update-Hinweis) → neu nur, wenn sie wirklich fehlt; gh-Fehler brechen ab
- [x] niedrig – fehlgeschlagener Installer-Upload blieb unbemerkt → Schritt bricht ab, version.json bleibt
- [x] niedrig – Medienübersicht behielt Cover/Album des vorigen Titels; Aufrufe an Windows konnten sich
      überholen → bei Titelwechsel erst leeren, alle Aufrufe nacheinander
- [x] niedrig – „Abspielen“ ohne Titel (nach dem Abmelden) zeigte „spielt“ → ignoriert
- [x] niedrig – ZIP-Variante bot nach dem Assistenten immer wieder dasselbe Update an → Hinweis: Startmenü
      nutzen, ZIP-Ordner löschen
- [x] geprüft, kein Fehler: Medientaste auf der Videoseite (die Videoseite pausiert die Musik selbst)

### Begriffe: Server-Bibliothek vs. Gerätespeicher

- [x] „Heruntergeladen“ (Musik, die auf dem Gerät gespeichert ist) hieß fast wie „Downloads“ (YouTube-Downloads
      auf den Server) → umbenannt in „Auf diesem Gerät“ (Bibliothek-Filter, Startseite, Gerätespeicher-Seite,
      Einstellungen, Offline-Hinweise); „Download entfernen“ → „Vom Gerät entfernen“, Pfeil an Playlist, Album und
      Lieblingssongs → „Aufs Gerät laden“. Server-Texte (Downloads-Seite, Verwaltung) bleiben unverändert
- [x] Gegenprüfung (`wf_43fc5dde-384`, 9 Prüfer wegen Limit abgebrochen → Funde selbst nachgeprüft):
      übersehen waren „Lade … herunter“ (Startseite ohne Netz), „Download-Qualität“ (Einstellungen und
      Gerätespeicher-Seite → „Qualität auf diesem Gerät“), „Download-Pfeil“ (→ „Pfeil nach unten“), der Album-Pfeil
      („Aufs Handy laden“ → „Aufs Gerät laden“, wie an Playlists); „Alles von diesem Gerät löschen?“ klang nach
      Zurücksetzen → „Alle Musik von diesem Gerät löschen?“; „Warteschlange“ war mit der Wiedergabe-Warteschlange
      verwechselbar; „bereits“ fehlte im Qualitäts-Hinweis; Einstellungs-Schalter kürzten den längeren Text bei sehr
      großer Schrift → Titel darf 3 Zeilen haben
- [ ] offen (Vorschlag): Einzelne Texte sagen noch „Handy“ (z. B. „wird aufs Handy geladen“) – unter Windows
      wäre „Gerät“ passender

### Handy-Ansicht: „alles verschoben und überlappt“ (Bildschirmfotos mit echten Systemleisten)

Die bisherigen Bildschirm-Tests rendern ohne Status- und Navigationsleiste und mit Ersatzschrift – Überlappungen
sieht man dort nicht. Neu geprüft: 88 Bildschirmfotos (14 Seiten; 412×915 und 360×780; Schrift 100/130/200 %;
quer; Statusleiste oben, 3-Tasten-Navigation unten; Roboto), gesichtet von 8 Prüfern (`wf_7c914d1b-22f`).

- [x] hoch – Querformat: Systemleisten, Update-Hinweis, Mini-Player und untere Leiste ließen kaum Platz für den
      Inhalt → Handys nur Hochformat (wie Spotify), Tablets und Computer drehen weiter
- [x] hoch – Update-Hinweis 100–160 px hoch (auf kleinen Handys mit großer Schrift ein Fünftel des Bildschirms)
      → eine flache Zeile (Installieren, × für „Später“); nur wenn der Text sonst unlesbar wäre, zweizeilig
- [x] mittel – Player: Songtext-Karte lag unter der Navigationsleiste des Handys → unteren Rand abgezogen
- [x] mittel – Wörter brachen mitten im Wort um („Lieblingssong / s“, „Musikvideo / s“) → Schrift wird so weit
      verkleinert, dass das längste Wort passt; Kacheln wachsen mit großer Schrift statt abzuschneiden
- [x] mittel – Rubrik: Abspielknopf ~30 px nach links versetzt, „Zufalls…“ unnötig gekürzt; Gerätespeicher:
      „Einstellung…“ gekürzt (Flexible + Spacer teilten den Platz je zur Hälfte) → behoben
- [x] niedrig – Künstler-Kopf endete mit harter Kante → läuft in die Seitenfarbe aus
- [x] geprüft, kein Fehler: Inhalt „unter“ Hinweis/Mini-Player ist das normale Ende des Scrollbereichs; harter
      Balken unter Covern = Schatten im Test; Einstellungen haben unten Abstand für die Navigationsleiste
- [x] Gegenprüfung (`wf_4858b1b0-317`):
      - hoch – Video-Vollbild gab danach alle Ausrichtungen frei (chewie-Standard) → stellt die App-Ausrichtung
        wieder her (`appOrientations`)
      - hoch – Sperre wurde in main() entschieden, wo Android oft noch 0×0 meldet → auch Tablets gesperrt; das
        Warten darauf konnte den Start im Hintergrund (Wiedergabe ohne Fenster) blockieren → neu: `OrientationLock`
        im Widget-Baum, misst den ganzen Bildschirm (Tablet im geteilten Bildschirm bleibt Tablet), wartet nie,
        prüft bei Größenänderung und beim Zurückkehren (neues Android-Fenster) neu
      - mittel – Textanpassung rechnete linear, Android 14+ vergrößert nicht linear → in echten Pixeln; passt ein
        Wort auch verkleinert nicht → eine Zeile mit „…“; Bindestriche dürfen umbrechen; Schnellzugriff-Cover
        bleibt 56 breit (sonst weniger Platz für den Titel bei großer Schrift)
      - mittel – Update-Hinweis: Schwelle für die flache Zeile wächst mit der Schrift
- [x] zweite Gegenprüfung (`wf_a063e2d6-a1a`):
      - mittel – Video im Vollbild kippte beim Zurückkehren (Benachrichtigungsleiste, Sperrbildschirm) hochkant →
        während des Vollbilds gilt dessen Ausrichtung (`fullScreenOrientations`)
      - mittel – Balken-Zuschnitt hätte dunklen Bildinhalt echter 16:9-Bilder entfernt → nur so viel, wie ein
        16:9-Bild an Balken hätte
      - niedrig – Foldable während des Videos auf-/zugeklappt: nach dem Vollbild alte Ausrichtung →
        `LiveAppOrientations` (gelesen beim Verlassen)
      - niedrig – Android kannte beim Start die Bildschirmgröße nicht (Engine von audio_service ohne Activity) →
        MainActivity reicht sie nach (`ViewUtils.calculateMaximumDisplayMetrics`)
      - niedrig – rundes Künstlerbild in der Schnellzugriff-Kachel wurde bei großer Schrift zur Tonne → mittig 56 px
- [ ] offen (niedrig): Downloads-Liste – Text bei Video-Vorschaubildern (16:9) weiter eingerückt als bei Covern;
      Warteschlange bei großer Schrift „4 Songs · 13…“ gekürzt; ungleiche Abstände auf der Startseite

### YouTube-Videos nur als Musik holen

- [x] Titel, die es bei YouTube nur als Video gibt (z. B. Kinderlieder), ließen sich nur als Video holen → „Holen“
      fragt bei Videos „Nur Musik“ (Ton als Song bei der Musik, quadratisches Cover) oder „Video“; das Menü eines
      Videos bietet „Nur Musik holen“ und „Musik holen und zu Playlist hinzufügen“. Der Server meldet, wenn der Ton
      eines Videos schon da ist (`in_library_audio_track_id`) – dann „Musik abspielen“ statt „Holen“
- [x] Gegenprüfung (`wf_c04ef623-658`): Cover von „Nur Musik“ kam aus dem kleinen Such-Vorschaubild (~225 px)
      → das größere Bild gewinnt (yt-dlp lädt 1280×720 mit), schwarze Balken alter 4:3-Vorschaubilder werden
      abgeschnitten (quadratische Album-Cover bleiben unberührt); laufender Musik-Download im Menü nicht
      abbrechbar, „Download abbrechen“ traf das Video → eigener „Musik-Download abbrechen“, Video-Einträge
      eindeutig beschriftet
- [x] Einstellung statt jedes Mal fragen: *Einstellungen › YouTube-Downloads › YouTube-Videos holen als*
      („Jedes Mal fragen“ / „Immer nur Musik“ / „Immer als Video“, pro Gerät, `s.videoFetch`); im Auswahlblatt
      „Wahl merken“. Songs werden immer als Musik geholt, das Menü eines Videos bietet weiterhin beides
- [x] Gegenprüfung (`wf_7dfe21e2-66c`): „Erneut versuchen“ nach fehlgeschlagenem Video holte bei „Immer nur
      Musik“ wieder das Video → der Knopf folgt der Einstellung; Link-Dialog wählte bei „Immer als Video“ auch für
      Playlists/Alben „Video“ vor → beide Link-Dialoge bleiben bei „Musik“; „Wahl merken“ waren zwei Bedienziele
      ohne gemeinsamen Namen → `MergeSemantics` + `ExcludeFocus` wie bei `CheckboxListTile`; fehlende Tests ergänzt

### Verwaltung am PC

- [x] „Benutzer anlegen“ am Windows-PC: Texte standen Buchstabe für Buchstabe untereinander. Ursache: Das Blatt
      ist auf breiten Bildschirmen auf 640 px begrenzt, `AdminSheet` rechnete den Seitenrand aber aus der
      Fensterbreite (bei 1260 px je 310 px Rand → ~20 px Inhalt). Betraf alle Blätter der Verwaltung (Benutzer und
      Rubriken anlegen/bearbeiten, Rubrik wählen) → Rand aus der Breite des Blatts (`LayoutBuilder`);
      `admin_sheet_width_test.dart` prüft Handy, Windows-Fenster und großen Bildschirm
- [x] „Mein Player zeigt kein Update“ (Windows): Die App prüfte nur beim Start – am PC bleibt Selfify aber
      tagelang offen → `UpdateWatcher`: stündlich und beim Zurückkehren in die App (Fenster wieder im
      Vordergrund, höchstens alle 30 Minuten); scheitert eine Nachprüfung (offline), bleibt der bisherige Stand
- [x] Gegenprüfung (`wf_a691a425-8f9`): Build 31 (erste Windows-Version) sucht gar nicht nach Updates → Nutzer
      informiert, Hinweis im README (einmal von Hand installieren); Test „beim Start offline, später online“
      ergänzt; Tests für Sperrfrist-Grenzen, nur beim Zurückkehren und „Wächter bleibt still“ geschärft

### Videos in Lieblingssongs/Playlists

- [x] „Er hält einfach“: Der Musik-Player filterte Videos aus der Warteschlange – Song + Video in den
      Lieblingssongs endete nach dem Song → Videos laufen als Ton mit; der Server liefert mit `audio_only=true`
      nur die Tonspur als AAC (Zwischenspeicher wie beim iPhone-Umwandeln), Antippen öffnet weiterhin das Video;
      „Abspielen“ geht auch bei einer Playlist nur aus Videos. Offline bleiben Videos außen vor
- [x] Gegenprüfung (`wf_507585aa-2c4`, kritisch): Die Korrektur wirkte nicht – der Audio-Handler
      (`playTracks`, `addTracks`, `playNext`) filterte Videos ein zweites Mal; die Tests nutzten einen
      Ersatz-Handler und merkten es nicht → Filter im Handler entfernt, „Zur Warteschlange“/„Als Nächstes“
      nehmen Videos mit, Radio/Autoplay bleiben reine Musik; Tests laufen jetzt mit dem echten Handler

### Play-Store-Version, Teil 1: Server und Dashboard

- [x] Premium: Codes mit freier Laufzeit (Tage oder unbegrenzt), Mehrfach-Einlösung, „einlösbar bis“, Sperren;
      Lizenzen stapeln sich, Entzug je Lizenz/Benutzer/Code; Zähler atomar (`UPDATE … WHERE`), Ratebremse
      (nur „gibt es nicht“ zählt als Fehlversuch); 20 Tests
- [x] Song-Wünsche (Admin entscheidet, Download läuft im Hintergrund auf dem Server), „Fehler melden“, Konto
      löschen (Passwort nötig, letzter Admin geschützt), App-Konfiguration (Werbung/Premium/Wunschliste,
      Update-Stufe none/available/required nur für die Play-Version, Wartungshinweis), gemeldete App-Versionen,
      Statistik; 16 Tests
- [x] Dashboard `/dashboard` (acht Ansichten) und Rechtsseiten `/datenschutz`, `/impressum`, `/konto-loeschen`:
      kein `innerHTML`, strenge Content-Security-Policy (nur eigene Dateien), Whitelist für Dateien, HTML-Escaping
      der Betreiberangaben; 14 Tests. Im Headless-Chromium durchgeklickt (Anmeldung, Codes erzeugen/sperren,
      Premium vergeben/entziehen, Wunsch ablehnen, Fehlermeldung, Einstellungen, Handy-Ansicht): Schadcode in
      Wünschen/Meldungen erscheint nur als Text
- [x] Beim Browser-Test gefunden und behoben: Such-Dialog „Wunsch erfüllen“ schloss über einen unsicheren
      Umweg (`.overlay:last-of-type`) → Dialoge geben ihre Schließen-Funktion jetzt selbst heraus; nach
      Abmelden/Anmelden liefen doppelte Listener und der Badge-Zeitgeber weiter → Listener einmalig, Zeitgeber
      wird beim Abmelden gestoppt

### Play-Store-Version, Teil 2: App, CI, Anleitung

- [x] Android-Flavors `full` (GitHub, `de.selfify.selfify`) und `play` (`….play`): Manifest-Overlay der Play-Version
      entfernt `REQUEST_INSTALL_PACKAGES`, `INSTALL_PACKAGES`, `WRITE_EXTERNAL_STORAGE` und die Installer-Bauteile des
      Update-Plugins; die GitHub-Version entfernt dafür die Werbe-ID und den Auto-Start des Werbe-SDKs
- [x] `lib/core/flavor.dart` entscheidet zentral (Flavor oder `--dart-define=CHANNEL=play`): In der Play-Version
      fehlen YouTube-Suche, Link einfügen, Downloads-Symbol/-Bildschirm-Einstieg, Downloader-Reiter, Download-
      Rechte-Schalter und Selbst-Update; stattdessen „Song wünschen“ (Suche, „Meine Wünsche“)
- [x] Premium-Code einlösen (Einstellungen › Premium, beide Versionen), Fehler melden (mit Fehlerprotokoll nur auf
      Wunsch, Zugangsdaten vorher unkenntlich), Konto löschen (Passwort nötig), Datenschutz-Link, Wartungshinweis,
      Update-Hinweis (Store-Link) und Pflicht-Update-Bildschirm; Header `X-Selfify-Client` an jeder Anfrage
- [x] Werbung (AdMob, nur Play + Android): erst Einwilligungsabfrage (UMP), dann SDK; Banner nur, wenn vom Admin
      eingeschaltet, **Premium geladen und nicht aktiv** (unklarer Stand = keine Werbung) und online; Test-IDs von
      Google als Standard
- [x] CI: Job „Play-Bundle“ (`selfify-play.aab` ins Release `app-latest`, nur signiert) mit Prüfung des
      zusammengeführten Manifests auf Selbst-Installation und AdMob-App-ID; GitHub-APK wird mit `--flavor full`
      gebaut und auf `REQUEST_INSTALL_PACKAGES` geprüft
- [x] 45 neue App-Tests (`play_version_test.dart`), 446 App-Tests insgesamt grün, `flutter analyze` sauber.
      Nicht lokal prüfbar (kein Android-SDK): Gradle-Bau, Manifest-Zusammenführung, echte Werbung – das prüft die CI

### Gegenprüfung der Play-Store-Version (PR #11)

Fünf unabhängige Prüfer (Sicherheit, Premium-Logik, Wünsche/Konfiguration, Dashboard, Datenbank/Migration) fanden
46 mögliche Fehler. Zwei Skeptiker je Fund versuchten, ihn zu widerlegen oder nachzustellen: **32 bestätigt, 14
widerlegt** (u. a. „Cover bleiben nach Konto-Löschen“ – die bestehende Aufräum-Routine entfernt sie).

- [x] **Einlöse-Rennen** (hoch): Gleichzeitige Anfragen desselben Benutzers vervielfachten Premium-Zeit und
      verbrauchten Plätze eines Mehrfach-Codes → `UNIQUE(code_id, user_id)` (Migration 0006, bereinigt
      vorhandene Doppelte), Lizenz zuerst anlegen, prozessweite Sperre (`app/locks.py`); Test mit 12 Threads
- [x] **Stapeln** (hoch): Ab dem dritten Code/der dritten Vergabe wurde nichts mehr angehängt → die ganze Kette
      zählt, Obergrenze zehn Jahre (409 statt 500)
- [x] **Statistik** (hoch): „Fertige entfernen“ löschte die Zeilen, das Dashboard zeigte danach überall 0 →
      Einträge werden nur noch ausgeblendet (`hidden_at`); Wünsche bleiben dadurch auch auffindbar
- [x] **Dashboard** (hoch): Nach „Benutzer anlegen“ sprang „Darf Downloads starten“ auf AUS (`form.reset()`)
- [x] Mittel: Token eines gelöschten Kontos galt für ein später angelegtes mit derselben Nummer (SQLite) →
      Token älter als das Gerät werden abgelehnt; „letzter Admin“ unter Sperre; Wunsch blieb ewig „in Arbeit“;
      Pflicht-Update ohne Store-Link (Sackgasse in der App) wird abgelehnt; Dashboard: Ladefehler machte Ansichten
      dauerhaft tot, Statusabfrage startete alle 4 s einen yt-dlp-Prozess, „yt-dlp aktualisieren“ war nach 4 s wieder
      klickbar (jetzt auch serverseitig gesperrt), Doppelklick erzeugte doppelte Codes/Lizenzen
- [x] Niedrig: `valid_until` ohne Zeitzone → 500; Header `build=²` → 500; Entzug zählte abgelaufene Lizenzen;
      laufende Lizenzen fielen hinter dem 1000er-Limit weg; Abmelden mit abgelaufenem Token ließ die Sitzung
      bestehen; veraltete Antworten beim Filterwechsel; Fehlerprotokoll klappte alle 30 s zu; ungültiges verstecktes
      Feld blockierte das Absenden; Tagesdiagramme als UTC beschriftet; „Zuletzt“ zeigt die letzte Aktivität
- [x] 17 neue Regressionstests (`tests/test_review_fixes.py`), Browser-Test aller Dashboard-Korrekturen
- Bewusst nicht geändert: `FORWARDED_ALLOW_IPS` (Standard: private Netze; nötig für Cloudflare-Tunnel/Proxy) – wer
  den Container-Port direkt im Heimnetz anbietet, sollte ihn auf den Proxy begrenzen; die Einlöse-Bremse hängt
  aber nicht mehr an der IP. Zahlen im Dashboard-Diagramm sind UTC-Tage.
- Reste: Das Token-Alter wird auf die Sekunde verglichen (ein Token, das in derselben Sekunde wie das neue Gerät
  ausgestellt wurde, bliebe gültig – praktisch ausgeschlossen); `INTEGER PRIMARY KEY AUTOINCREMENT` wäre die
  vollständige Lösung, braucht aber einen riskanten Tabellen-Umbau.

### Absturz beim Start der GitHub-App (Build 58)

- [x] **Fehler:** Nach dem Update auf Build 58 (Play-Store-Version) zeigte die GitHub-App nur das Logo und schloss sich
      – auch nach einer Neuinstallation. Die Tests und alle CI-Jobs waren grün; ein Absturz beim Start lässt sich ohne
      Gerät oder Emulator dort nicht sehen.
- [x] **Eingrenzung:** Vier Test-APKs (Release `app-test`): Die Version **ohne Werbe-SDK startet**. Ursache ist also das
      Werbe-SDK (`google_mobile_ads` samt WorkManager und Werbe-Diensten), das auch ohne Aufruf beim Start
      mitläuft. Das Paket war ohnehin nur für die Play-Version gedacht.
- [x] **Behebung:** GitHub-APK, Windows und iPhone werden mit einem Platzhalter-Paket gebaut
      (`mobile/packages/google_mobile_ads_stub`, per `pubspec_overrides.yaml` in der CI); die CI prüft, dass im Manifest
      der GitHub-APK nichts vom Werbe-SDK steht, und analysiert die App zusätzlich gegen den Platzhalter
- [ ] **Offen:** Ob die **Play-Version** (mit dem echten SDK) am Handy startet, ist noch nicht bestätigt – vor dem
      Hochladen in die Play Console auf einem Gerät prüfen (Test-APK `test-2-play.apk` im Release `app-test`)
- Lehre: Neue native Bauteile (SDKs mit eigenem Start-Code) brauchen einen Start-Test auf einem echten Gerät, bevor sie
  in die Version kommen, die Nutzer per Update bekommen.
### Play-Version: feste Server-Adresse

- [x] **Wunsch:** Im Play Store soll niemand eine Server-Adresse eintippen müssen („server einfügen muss dann im
      Playstore-Release nicht mehr sein“).
- [x] **Umsetzung:** `--dart-define=SERVER_URL=…` (nur wirksam in der Play-Version; CI nimmt die GitHub-Variable
      `PLAY_SERVER_URL`, verlangt `https://` und warnt, wenn sie fehlt). Anmeldung ohne Server-Feld (gleich Benutzername
      und Passwort, keine Vorab-Prüfung), Einstellungen ohne Kachel „Server-Adresse“ (die Kachel „Server“ mit Name und
      Version bleibt). Die Adresse steckt in `fixedServerUrl` (`state/auth.dart`) und gilt für Anmeldung, zuletzt
      benutzten Server und den Konfig-Abruf vor der Anmeldung.
- [x] **Randfall:** Eine gespeicherte Anmeldung bei einem *anderen* Server als der festen Adresse (Umzug des Betreibers)
      wird verworfen – einmal neu anmelden.
- [x] **Unverändert:** GitHub-Version, Windows und iPhone (auch wenn dort `SERVER_URL` gesetzt wäre); Play-Version ohne
      Variable verhält sich wie bisher.
- [x] **Tests:** 15 neue Tests in `play_version_test.dart` (Anmeldung, Einstellungen, gespeicherte Anmeldung,
      GitHub-Version unverändert); gegengeprüft, dass sie ohne die Änderung fehlschlagen.
- [ ] **Offen:** Der Bau mit gesetzter Variable `PLAY_SERVER_URL` ist in der CI noch nicht gelaufen (die Variable war
      beim Prüfen nicht gesetzt, der Bau lief im Zweig „fragt nach der Adresse“); das Verhalten auf einem echten Gerät
      ist ungeprüft (kein Android-Emulator hier). Nach dem Setzen der Variable neu bauen (siehe docs/PLAYSTORE.md).
- [x] **Gegenprüfung (4 Prüfer, je Fund 2 Skeptiker):** 11 Funde, kein Fehler im Code für die GitHub-Version oder
      Play ohne Variable. Umgesetzt: CI verlangt einen Servernamen hinter `https://`; Doku zum Neubau nach geänderter
      Variable und zur fehlenden Vorab-Prüfung. Bewusst nicht geändert (klein, selten, Änderung würde auch die
      GitHub-Version berühren):
      - Der Konfig-Abruf vor der Anmeldung wird nach dem Anmelden nicht wiederholt. Scheitert er beim allerersten
        Start, gelten bis zum nächsten Abruf (Rückkehr in die App nach 10 Minuten, spätestens nach einer Stunde) die
        Standardwerte (keine Werbung/Hinweise). Gleiches gilt schon lange für jeden Kaltstart mit gemerktem Server.
      - Ohne Vorab-Prüfung fehlen bei einer Netzsperre (z. B. Cloudflare „Bot fight mode“) die ausführlichen Hinweise
        samt „Technische Details“ der Server-Prüfung; die Anmeldung zeigt dann nur ihre allgemeine Meldung. Dieselbe
        Domain muss für die GitHub-Version ohnehin freigegeben sein.
      - Ein Abbruch mitten im TLS-Handshake meldet (wie schon vorher überall) „… Adresse mit http:// versuchen“; in der
        Play-Version gibt es kein Adressfeld dafür. Erneutes Anmelden hilft.
- Für die Google-Prüfer: Die App zeigt fest auf diesen Server → Demo-Server-Hinweise in `docs/PLAYSTORE.md` (Abschnitt 7).

### Premium: Offline-Hören und Kauf über Google Play

Auftrag: „1 € für Offline-Musikhören; wird Premium nicht mehr bezahlt, muss die Musik vom Gerät; wird die App
deinstalliert, muss erst die Musik runter.“ Vertrag der drei Bereiche (Server/Dashboard, App, Build/CI/Doku) mit
allen Feldnamen, Regeln und Texten: Arbeitsordner der Sitzung, `entwurf-premium-offline.md`. Alle neuen Schalter sind
standardmäßig **aus**; ohne sie verhalten sich Server und alle App-Ausgaben wie bisher.

**Build, CI, Anleitung (dieser Bereich – geprüft wie angegeben)**

- [x] CI (`.github/workflows/app.yml`): GitHub-APK, Windows und iPhone bekommen **eine** `pubspec_overrides.yaml`
      mit beiden Platzhaltern (`google_mobile_ads_stub`, `in_app_purchase_stub`); der zweite Analyse-Schritt prüft
      die App gegen beide. YAML geprüft (`yaml.safe_load`), alle Shell-Schritte mit `bash -n`, die erzeugte
      Override-Datei als YAML gelesen
- [x] In einer Kopie der App ausprobiert: mit beiden Platzhaltern `flutter pub get` + `flutter analyze` ohne Befund;
      `.flutter-plugins-dependencies` enthält dann weder `in_app_purchase_android` noch `google_mobile_ads`
- [x] Neue CI-Prüfungen: GitHub-APK ohne `com.android.vending.BILLING`/`com.android.billingclient` (Manifest,
      APK-Inhalt, Plugin-Liste); Play-Bundle **mit** `com.android.vending.BILLING`; beide Android-Ausgaben mit
      `dataExtractionRules` und ohne `hasFragileUserData="true"` (Play- und Backup-Prüfung waren so nicht
      belastbar – verschärft, siehe „Gegenprüfung Teil 1“)
- [x] Anleitung für den Betreiber: `docs/PLAYSTORE.md` Schritt 10 (Zahlungsprofil, Abo, Lizenztester, Dienstkonto,
      Schlüsseldatei auf Unraid, Dashboard, Testen, Kündigung/Löschen/Gnadenfrist, Gebühren, Datensicherheit,
      „Nicht geprüft“); README (Schalter, Regeln, Umgebungsvariablen, API, zweiter Platzhalter)
- [ ] **Die neuen CI-Prüfungen sind noch nie gelaufen** (kein Android-SDK hier): erster Lauf auf GitHub zeigt, ob die
      Muster im zusammengeführten Manifest und in der APK greifen (insbesondere `unzip -l … | grep billingclient`
      und der Pfad `.flutter-plugins-dependencies`)

**Server, Dashboard, App (Bereiche S und A – Abschlusslauf hakt ab und trägt die Testzahlen ein)**

- [ ] Server: neue Einstellungen (`offline_requires_premium`, `offline_grace_days`, `billing_enabled`,
      `billing_product_ids`, Premium-Texte), Tabelle `play_purchases` (Migration 0007), `POST /premium/play/verify`,
      erneute Prüfung bei `GET /premium` (gedrosselt), 503 bei unklarem Stand, Admin-Endpunkte; alle Tests und `ruff` grün
- [ ] Dashboard: Karten „Premium und Offline-Hören“ und „Kauf in der App (Google Play)“, Tabelle „Käufe über Google
      Play“; im Browser durchgeklickt, Sonderzeichen erscheinen als Text
- [ ] App: Offline-Sperre an allen Stellen, Löschen bei bestätigtem Ablauf und nach der Gnadenfrist, **kein** Löschen
      bei unbekanntem Stand; Kauf/Wiederherstellen mit Attrappe; GitHub-Kanal ohne Kaufknopf; `flutter analyze` und
      alle Tests grün
- [ ] Android: Backup-Regeln (`backup_rules.xml`, `data_extraction_rules.xml` – nur Einstellungen), Billing-
      Berechtigung nur im Play-Manifest; Gradle-Bau und Manifest-Zusammenführung laufen erst in der CI
- [ ] Schalter aus: GitHub-Version, Windows, iPhone und Play-Version verhalten sich exakt wie vorher (alte App gegen
      neuen Server, neue App gegen alten Server)

**Offen / hier nicht prüfbar (kein Android-SDK, kein Gerät, kein Google-Zugang)**

- [ ] **Start auf echten Geräten:** Play-Version mit der Billing-Bibliothek **und** GitHub-Version ohne sie – vor
      jeder Verteilung (Lehre aus Build 58)
- [ ] **Echter Kauf mit Lizenztester:** Kaufdialog, Preis aus dem Store, Freischaltung, Eintrag im Dashboard
- [ ] **Bestätigung bei Google** (acknowledge): keine automatische Erstattung (Testkauf: nach wenigen Minuten,
      echter Kauf: nach 3 Tagen); doppeltes Bestätigen durch Server und App ohne Fehler
- [ ] **Kündigung, Erstattung, Zahlungsproblem, Verlängerung** am Testkonto: Server beendet/verlängert Premium, App
      löscht die Offline-Musik und zeigt den Hinweis
- [ ] **Wiederherstellen** auf zweitem Gerät; fremdes Selfify-Konto wird abgelehnt (409)
- [ ] **Google-Schnittstelle:** Adresse und Feldnamen von `purchases.subscriptionsv2.get` und `…:acknowledge` gegen
      die Referenz prüfen (`developers.google.com` war nicht erreichbar); Dienstkonto-Anmeldung gegen echtes Google
- [ ] **Play Console:** Menünamen, nötige Berechtigungen des Dienstkontos, Wartezeit bis sie gelten, ob 0,99 €
      wählbar ist, ob vor dem Anlegen des Abos ein Bundle mit Billing-Berechtigung hochgeladen sein muss
- [ ] **Gebühren/Steuer** auf Googles eigener Seite nachlesen (`support.google.com` war nicht erreichbar; in der
      Anleitung stehen Werte aus Berichten Dritter, als solche gekennzeichnet)
- [ ] **Deinstallation und Sicherung auf einem Gerät:** Offline-Dateien weg, nach Neuinstallation mit
      Google-Sicherung nicht zurück (bisher nur an Code und Regeln geprüft)
- [ ] **Gnadenfrist am Gerät:** 7 Tage Flugmodus (oder Uhr vorstellen) → Sperre und Löschen; Uhr zurückstellen
      verlängert nicht
- [ ] Datensicherheit in der Play Console um „Kaufverlauf“ ergänzt

**Bewusst nicht Teil dieses Laufs / bekannte Grenzen**

- Keine Echtzeit-Benachrichtigungen von Google: Kündigung/Erstattung wirkt erst bei der nächsten Premium-Abfrage nach
  der Drosselzeit (`PLAY_RECHECK_HOURS`); wer die App nie öffnet, steht im Dashboard bis zum Ablauf als „aktiv“.
- Die Sperre sitzt in der App (der Server kann Offline-Laden nicht vom Streamen unterscheiden).
- Ein Basis-Abo je Produkt, keine Angebote/Testphasen/Jahres-Abo, kein Kauf auf iPhone/Windows; der
  Abrechnungszeitraum steht nicht auf dem Kaufknopf.
- Windows: Offline-Dateien bleiben nach der Deinstallation in `AppData` liegen; iPhone: iCloud sichert den
  Dokumente-Ordner samt Offline-Musik.
- Offline-Dateien: Unter der Sperre geladene Musik wird bei jedem Wechsel des Kontos oder Servers gelöscht (auch
  wenn das neue Konto Premium hat); ohne Sperre gehört sie wie bisher zum Gerät.
- Entzieht der Admin gekauftes Premium, läuft das Abo bei Google weiter (Hinweis im Dashboard und in der Anleitung).
- Selbst-Registrierung und Sichtbarkeit je Rubrik kommen danach.

### Gegenprüfung Teil 1

Vier unabhängige Prüfer (Geld/Sicherheit, Offline-Löschen, „unverändert“ und Build, Kauf-Ablauf und Doku) haben den
Stand von „Premium Teil 1“ gegengeprüft: **16 bestätigte Funde** (3 hoch, 4 mittel, 9 niedrig). Die vollständigen
Funde mit Nachweis und Lösungsvorschlag liegen im Arbeitsordner der Sitzung (`funde-teil1.json`). Abgehakt ist, was im Code
nachvollzogen wurde und einen Test hat (Server: `tests/test_premium_part1_fixes.py`, `tests/test_premium_part1_recheck.py`,
Rücksprung in `tests/test_billing_offline.py`; App: `test/premium_offline_test.dart`, `test/installer_test.dart`). Die
beiden CI-Funde haben keinen Test im Repository – sie sind mit Attrappen der Bau-Ergebnisse nachgestellt und auf
GitHub noch nie gelaufen (siehe „Offen“).

**Geld und Sicherheit (Server)**

- [x] **Entzug bei gerade abgelaufener Play-Lizenz** (hoch): „Alles entziehen“ traf eine Lizenz nicht, deren
      Zeitraum eben um war oder deren Zahlung hing – Premium kam bei der nächsten Prüfung von selbst zurück → Entzug
      trifft auch abgelaufene Lizenzen, solange der Kauf sie wieder verlängern könnte
- [x] **HTTP 400/404 von Google beendete Premium endgültig** (mittel), auch bei falsch eingestelltem Paketnamen →
      nur 410 gilt sofort als „beendet“; 400/404 bei einem bekannten Kauf heißt „unbekannt“ (Hinweis in der
      Kaufliste), beendet wird erst 3 Tage nach dem bezahlten Ende, der Kauf wird weiter nachgeprüft
- [x] **Code hinter dem Abo** (mittel): Endete das Abo vorzeitig, gab es trotz gültiger Code-Lizenz kein Premium
      (Musik gelöscht) → angehängte Lizenzen rücken beim vorzeitigen Ende sofort nach; Doku: Codes besser erst nach
      der Kündigung einlösen (bei Verlängerung überlappen sich die Zeiten weiterhin)
- [x] **Kauf nach Konto-Neuanlage nicht übernehmbar** (niedrig): Die Konto-Kennung im Kauf nannte die alte
      Benutzer-Nummer → Übernahme erlaubt, wenn es das genannte Konto nicht mehr gibt
- [x] **Rücksprung auf die alte Version** (niedrig): Lizenzen mit `source='play'` ließen die Lizenzliste der
      Vorversion mit 500 scheitern und liefen ungeprüft weiter → `downgrade()` beendet sie und führt sie als Vergabe
      mit Vermerk; Anleitung `docs/PLAYSTORE.md` 10.12 (Reihenfolge, Folgen für Käufer)

**Offline-Sperre und Löschen (App, Server)**

- [x] **Ältere App-Versionen laden weiter und löschen nie** (hoch) → neue Einstellung `offline_min_client_build`
      („Sperre durchsetzen ab App-Build“, Standard 0 = aus): Schalter an und Wert > 0 → Nicht-Admins ohne Premium mit
      älterer oder unbekannter Build-Nummer (`X-Selfify-Client`) bekommen beim Stream HTTP 426 „Bitte aktualisiere
      die App.“; `GET /api/app/config` liefert das Feld; die App zeigt die Meldung; Dashboard-Text, README und
      `docs/PLAYSTORE.md` (10.6, 10.7, 10.8, Checkliste) sagen jetzt „gilt erst ab der App-Version, die die Sperre
      kennt“
- [x] **Gnadenfrist mit vorgestellter Geräteuhr verlängerbar** (mittel) → Abgleich mit der Serverzeit
      (`checked_at`); ein Stand aus der Zukunft verlangt eine neue Prüfung
- [x] **Anderer Server/anderes Konto ließ die Offline-Musik liegen** (niedrig, GitHub-Version) → der Offline-Speicher
      merkt sich Server und Konto und wird beim Wechsel geleert
- [x] **Beim Sperren lief die Wiedergabe weiter; unter Windows blieb die offene Datei liegen** (niedrig) →
      Wiedergabe vor dem Löschen beenden, fehlgeschlagene Löschungen und verwaiste Dateien nachholen

**Build und CI**

- [x] **Play-Job: Billing-Prüfung war immer grün** (mittel) – sie suchte nur die Berechtigung, die fest im
      Play-Manifest steht → der Play-Job bricht vor `flutter pub get` ab, wenn `pubspec_overrides.yaml` existiert,
      und prüft nach dem Bau positiv: Plugin `in_app_purchase_android` in `.flutter-plugins-dependencies`,
      `com.android.billingclient` im zusammengeführten Manifest **oder** im Manifest des Bundles, dazu die
      Berechtigung; `pubspec_overrides.yaml` steht in `mobile/.gitignore`. Nachgestellt mit Attrappen der
      Bau-Ergebnisse (alter Schritt grün bei Platzhalter-Bundle, neuer rot; echtes Bundle grün)
- [x] **Backup-Prüfung wurde vom eigenen Kommentar im Manifest erfüllt** (niedrig) → beide Android-Jobs prüfen
      `android:dataExtractionRules="@xml/data_extraction_rules"` **und**
      `android:fullBackupContent="@xml/backup_rules"` (Attribut samt Wert); nachgestellt wie oben
- [x] **Windows: Offline-Musik blieb nach der Deinstallation liegen** (niedrig) → `[UninstallDelete]` im Installer
      für `%LOCALAPPDATA%\Selfify\Selfify\offline`; README und Anleitung angepasst. iPhone (iCloud-Sicherung)
      bleibt eine bekannte Grenze

**Kauf-Ablauf und Doku**

- [x] **Verlängerung: kurz nach dem Enddatum „kein Premium“** (hoch) – die App löschte die Musik eines zahlenden
      Kunden → nach Ablauf wird sofort bei Google nachgesehen; solange Google das Abo noch als laufend meldet, gilt
      der Stand bis zu einer Stunde als „unbekannt“ (503) statt „kein Premium“
- [x] **Bezahlte Käufe wurden beim App-Start nicht nachgeholt** (mittel) → stilles Wiederherstellen beim Start und
      beim Zurückkehren in die App; Käufe im Zustand „ausstehend“ werden dem Server gemeldet
- [x] **Gemerkte unbestätigte Käufe galten für das Gerät statt für das Konto** (niedrig) → Konto und Server werden
      mit dem Token gespeichert, fremde Einträge bleiben liegen
- [x] **Doku: „keine Erstattungs-Mail = Server hat bestätigt“ und „Erstattung beendet Premium“** (niedrig) →
      `docs/PLAYSTORE.md` 10.3/10.7/10.8/Checkliste und README: Bestätigt wird vom Server **und** vom Gerät; den
      Server prüft man am Protokoll bzw. am Hinweis in der Kaufliste (`last_error`) – **nicht** am Feld
      `acknowledged`, das bei jeder Prüfung von Google übernommen wird (in der Nachprüfung berichtigt); eine Erstattung beendet Premium nur mit Widerruf des
      Zugangs, sonst zum Ende des Zeitraums (sofort: im Dashboard entziehen)

**Zusätzlich in der Anleitung (README, `docs/PLAYSTORE.md` Abschnitt 6 und 10.8)**

- [x] Premium-Codes und die Vergabe im Dashboard schalten das Offline-Hören genauso frei wie ein Kauf; bei Ablauf,
      Sperren oder Entziehen wird die Offline-Musik gelöscht (Test: `docs/PLAYSTORE.md` 10.7 Nr. 9)

**Nachprüfung der Korrekturen**

- [x] **Play-Job, Billing-Prüfung:** `unzip -p … | grep -a -q …` wäre unter `bash -eo pipefail` trotz Treffer
      gescheitert (grep endet beim ersten Treffer, unzip bekommt SIGPIPE) → das Manifest wird erst in eine Datei
      ausgepackt, dann durchsucht. Nachgestellt mit einem 64 MB großen Manifest im Bundle: alter Schritt rot trotz
      Treffer, neuer grün; ohne Bibliothek weiter rot. Ebenso `yes | sdkmanager …` in beiden Android-Jobs (jetzt
      `< <(yes)`). Die Schritte laufen heute mit der Standard-Shell von GitHub (`bash -e`, ohne `pipefail`) – der
      Fehler wäre erst mit `shell: bash` aufgetreten. Übrige Pipelines durchgesehen (`unzip -l … | grep`,
      `grep -m1 … | sed`, `sha256sum | cut`, `echo | base64`): Dort liest der hintere Befehl alles. YAML und
      `bash -n` aller 29 Shell-Schritte geprüft. Kein Test im Repository (CI-Datei)
- [x] **Doku 10.7 Nr. 4:** Das Feld `acknowledged` beweist nicht, dass der Server bestätigen darf → Verweis auf die
      Protokollzeile und den Hinweis in der Kaufliste; ein gescheitertes Bestätigen steht jetzt als `last_error` in
      der Kaufliste (Test `test_a_failed_acknowledge_shows_up_in_the_purchase_list`)
- [x] **Doku „Mehrere Benutzer an einem Gerät“** (README, `docs/PLAYSTORE.md` 10.8): Unter der Sperre geladene Musik
      wird bei **jedem** Konto- oder Serverwechsel gelöscht, ohne Sperre gehört sie weiter zum Gerät (so steht es in
      `mobile/lib/state/offline.dart`, `_applyAccess`)
- [x] **Doku zu den Server-Änderungen:** `offline_min_client_build`/HTTP 426, 400/404 = „unbekannt“ bis 3 Tage nach
      dem bezahlten Ende, eine Stunde „unbekannt“ bei noch nicht verbuchter Verlängerung (dann auch kein 426 für
      Abonnenten), vorgezogene Code-Zeit bei Erstattung, Rücksprung der Migration – README und `docs/PLAYSTORE.md`
      10.6–10.8, 10.12
- [x] Tests in diesem Stand: Server `test_premium_part1_fixes.py`, `test_premium_part1_recheck.py`,
      `test_billing_offline.py`, `test_premium.py` grün; App `premium_offline_test.dart` und `installer_test.dart`
      grün (125 Tests). Die vollständigen Läufe (alle Tests, `ruff`, `flutter analyze`) macht der Abschlusslauf

**Offen nach der Gegenprüfung**

- [ ] Die geänderten CI-Schritte sind **noch nie auf GitHub gelaufen** (kein Android-SDK hier): erster Lauf zeigt, ob
      `com.android.billingclient` im zusammengeführten Manifest bzw. im Manifest des Bundles
      (`base/manifest/AndroidManifest.xml`) gefunden wird und ob der Merger die Backup-Attribute wörtlich so schreibt
- [ ] Das Dashboard zeigt nicht an, **dass** der Server einen Kauf bestätigt hat – nur ein gescheitertes Bestätigen
      (Hinweis in der Kaufliste, verschwindet bei der nächsten gelungenen Prüfung wieder; dauerhaft steht es nur im
      Protokoll). Ob das Dienstkonto bei Google bestätigen darf, zeigt erst ein echter Testkauf
- [ ] Keine der Korrekturen ist auf einem Gerät oder gegen Google gelaufen: 426 mit einer echten alten App,
      Kontowechsel mit Offline-Musik am Handy, Löschen bei laufender Wiedergabe unter Windows, stilles Nachholen
      eines Kaufs beim Start, Verlängerung/400/404 gegen die echte Schnittstelle – alles nur mit Tests und Attrappen
- [ ] Rücksprung-Befehl (`docker exec -u 99:100 selfify alembic downgrade 0006`) im echten Unraid-Container
      ausprobieren; Pfad des Offline-Ordners unter Windows an einem Rechner bestätigen
- [ ] Erstattung mit/ohne Widerruf in der Play Console am Testkonto nachstellen (Benennung dort ungeprüft)

### Premium Teil 2: Laufzeiten, Leistungen, Codes mit Umfang

Auftrag: ein Abo mit drei Laufzeiten (monatlich, halbjährlich, jährlich) mit echtem Store-Preis, Ersparnis und
Angeboten von Google, Wechsel der Laufzeit; Premium-Leistungen im Dashboard einzeln schaltbar; Codes mit wählbarem
Leistungsumfang. Vertrag der drei Bereiche (S = Server/Dashboard, A = App, B = CI/Doku) mit allen Feldnamen, Regeln
und Texten: Arbeitsordner der Sitzung, `entwurf-premium-teil2.md`. Alle neuen Einstellungen stehen standardmäßig so,
dass sich nichts ändert (alles „Für alle“, kein Abzeichen, Laufzeiten leer = alle aus dem Store). Migration **0008**
(0007 unverändert).

**CI und Doku (Bereich B – geprüft wie angegeben)**

- [x] CI (`.github/workflows/app.yml`): alle vier Stellen, die `pubspec_overrides.yaml` schreiben (Analyse-Schritt,
      GitHub-APK, Windows als PowerShell-Here-String, iPhone), haben den dritten Platzhalter
      `in_app_purchase_android: path: packages/in_app_purchase_android_stub`. YAML mit `yaml.safe_load` gelesen, alle
      29 Shell-Schritte mit `bash -n` ohne Befund, die erzeugte Override-Datei (printf und PowerShell-Block) als YAML
      gelesen: drei Einträge
- [x] Bestehende Prüfungen unverändert: GitHub-APK ohne `in_app_purchase_android` in `.flutter-plugins-dependencies`
      und ohne Billing; Play-Job bricht ab, wenn `pubspec_overrides.yaml` existiert, und prüft positiv auf das Plugin
- [x] In einer Kopie der App (Stand Bereich A von heute) mit allen drei Platzhaltern: `flutter pub get` und
      `flutter analyze` ohne Befund; `.flutter-plugins-dependencies` enthält weder `in_app_purchase_android` noch
      `google_mobile_ads`
- [x] `docs/PLAYSTORE.md`: Vergleichstabelle; Abschnitt 6 (Codes mit „Schaltet frei“, Spalte „Umfang“, Stapelregel,
      alte Codes = alle); 10.2 neu („Abo mit drei Laufzeiten anlegen“: Basis-Abos `monatlich`/`halbjaehrlich`/
      `jaehrlich`, Kennungsregeln, Ersparnis, Preise festlegen und **später ändern** inkl. Bestandskunden, Angebote
      mit „Neukunden gewinnen“); 10.6 (Laufzeiten-Editor, Karte „Premium-Leistungen“, Offline-Schalter am neuen Platz);
      10.7 Testschritte 11–13 (Wechsel, Angebot, Leistungen); 10.8 Zeile „Laufzeit gewechselt“; 10.11 „Nicht geprüft“
      für Teil 2; 10.12 Rücksprung auf 0007; **neu 10.13** „Premium-Leistungen festlegen“ (alle 8 Leistungen, wo
      durchgesetzt, ffmpeg, ehrliche Grenzen, Ende-zu-Ende-Prüfung); **neu 10.14** „Laufzeit wechseln – was Nutzer
      erleben“; Checkliste ergänzt
- [x] README: Ansichten-Tabelle, Code-Umfang in den Premium-Regeln, Tabelle der Premium-Leistungen mit Schlüsseln,
      Standardwerten und Ort der Durchsetzung, „Laufzeiten“, API (`features`, `locked`, `premium_only`, `badge`,
      `play.base_plan_id/offer_id`, `/requests/quota`, 403/429-Meldungen, stille Qualitätsdeckelung), Rücksprung
      0007, dritter Platzhalter im Abschnitt Entwicklung
- [x] Fakten zu Google per Websuche/Abruf geprüft (Quellen in 10.11 genannt bzw. verlinkt): Basis-Abos und Angebote,
      Abrechnungszeiträume, Regeln für Kennungen von Basis-Abos (Kleinbuchstaben/Ziffern/Bindestrich, ≤ 63 Zeichen,
      nach Aktivierung unveränderlich), Berechtigungen für Angebote, Preisänderungen (Legacy-Preiskohorte, Zustimmung
      bei Erhöhung, Angebotspreise nur für Neue), Testzeiten für Lizenztester (6 Monate ≈ 15 min, 1 Jahr ≈ 30 min,
      Gratis-Zeit ≈ 3 min), `linkedPurchaseToken` beim Ersetzen, `offerDetails.basePlanId/offerId` in `lineItems`.
      `support.google.com` war nicht abrufbar; die deutschen Menünamen der Play Console sind als ungeprüft markiert
- [ ] Doku gegen den fertigen Code gegenlesen (Abschlusslauf): jede Zahl und jeder Text aus Vertrag 1.2/1.7/2.5 –
      bei diesem Lauf mit dem Zwischenstand von S und A abgeglichen (Meldungen, Dashboard-Beschriftungen, App-Texte)

**Server und Dashboard (Bereich S – Abschlusslauf hakt ab und trägt die Testzahlen ein)**

- [ ] `app/services/features.py` (8 Leistungen, feste Reihenfolge, `encode`/`decode`, `Access`, `clamp_quality`);
      neue Einstellungen in `app_config.py` mit Grenzen und Fehltexten; `billing_recommended_plan` muss in
      `billing_base_plans` stehen
- [ ] Migration 0008: `features` an Codes und Lizenzen (NULL = alle), `base_plan_id`/`offer_id` an Käufen;
      Upgrade auf 0007-Datenbank mit Bestandsdaten, Downgrade 0007 und wieder hoch
- [ ] Unverändert-Garantie: alle Schalter aus → `/app/config` alte Felder identisch, Stream `original` liefert
      Original, Video liefert Video, Songtext 200, alte Wunschgrenzen; alter Code → `features` = alle 8, `locked` = []
- [ ] Je Leistung (ohne Premium / mit Premium / Admin): Qualitätsdeckel (160 bzw. 96 kbit/s), 400 ohne ffmpeg,
      Video 403 / `audio_only` 200, Songtexte 403, Wünsche 429/403 inkl. Rückzug und 7-Tage-Fenster,
      `/requests/quota`, `offline_allowed` nach Umfang, `badge`
- [ ] **Ende-zu-Ende Codes mit Umfang:** Code `["video","lyrics"]` erzeugen → einlösen → `features` genau diese,
      `locked` = `["offline","hq_audio"]`, Video und Songtext 200, Qualität gedeckelt; `[]` → 422; alle 8 → `null`
- [ ] Stapelregeln (Teil-Code beginnt sofort, voll hinter voll angehängt, `close_gaps` mit gemischten Umfängen);
      `refresh_user` mit Teil-Code + gestörter Prüfung bleibt 503
- [ ] Laufzeiten: `parse_subscription` liest `offerDetails` (spätester Posten), Wechsel A→B mit `linkedPurchaseToken`
      (A „ersetzt“, eine Lizenz, `base_plan_id` von B), umgekehrte Reihenfolge; `PurchaseOut.base_plan_id/offer_id`
- [ ] Dashboard im Browser: Karte „Premium-Leistungen“, Laufzeiten-Editor (↑/↓, Empfohlen, höchstens 6), „Schaltet
      frei“ beim Erzeugen, Spalten „Umfang“ und „Laufzeit“, Pille „Teilumfang“; Sonderzeichen als Text, keine
      CSP-Meldung
- [ ] Alle Server-Tests und `ruff` grün

**App (Bereich A – Abschlusslauf hakt ab)**

- [ ] `lib/billing/plans.dart`: Perioden, Beschriftungen, Monatspreis und „spare … %“ (Prüfwerte 15 % / 24 % /
      kein Chip bei 0 oder teurer / keine Ersparnis ohne Monatsplan oder bei anderer Währung), Angebotswahl und
      -text, Reihenfolge/Filter/Empfehlung
- [ ] Premium-Seite: Karten je Laufzeit, „Empfohlen“, „Dein Abo“, „Gratis testen“, „Zu … wechseln“ →
      `change:<plan>:<produkt>:<konto>`, `BillingText.changed`, `changeNotOnDevice`, keine Wechsel-Knöpfe bei
      `on_hold`
- [ ] `premiumAccessProvider` (Admin, alter Server, Stand unbekannt → erlaubt); Qualitätsdeckel in Player und
      Offline-Laden (Einstellung bleibt gespeichert); Video-Sperransicht + „Als Ton abspielen“, Video-403; Songtexte
      gesperrt ohne Abruf und bei 403; Wünsche-Kopfzeile; Überspring-Grenze (Ablauf nach 1 h, Titelende zählt
      nicht, Schalter aus → `allowSkip == null`); Abzeichen; Werbung nach `no_ads`
- [ ] Premium-Texte passen sich an; mit nur Offline auf „Nur Premium“ wörtlich wie bisher
- [ ] Offline: gemerkter unbestätigter Kauf + Server „nicht erlaubt“ → kein Löschen
- [ ] Neues Platzhalter-Paket `packages/in_app_purchase_android_stub` ohne nativen Teil; direkte Abhängigkeit
      `in_app_purchase_android: ^0.5.5` (war schon transitiv da – kein neues SDK)
- [ ] `flutter analyze` und alle Tests grün; bestehende Tests nur auf `buy(StorePlan)` umgestellt, nicht abgeschwächt
- [ ] Schalter aus: GitHub-Version, Windows, iPhone und Play-Version exakt wie bisher (alte App ↔ neuer Server,
      neue App ↔ alter Server)

**Offen / hier nicht prüfbar (kein Android-SDK, kein Gerät, kein Google-Zugang)**

- [ ] **Ersatzmodus beim Wechsel der Laufzeit:** Nach der Gegenprüfung auf `ReplacementMode.chargeFullPrice`
      umgestellt (vorher `withTimeProration`). Hintergrund: Googles
      Entwicklerseite (Subscriptions, „Resubscribe or switch plans within the same subscription“) nennt für den
      Wechsel zwischen Basis-Abos **desselben** Abos nur `CHARGE_FULL_PRICE` und `WITHOUT_PRORATION` (Standard-
      Ersatzmodus in der Play Console) als maßgeblich; eine Drittquelle (RevenueCat) berichtet, dass Zeit-Anrechnung
      dabei scheitert. **Am ersten Testkauf klären**; scheitert er, muss Bereich A den Modus ändern (z. B. ohne
      `replacementMode` den Standard der Play Console nutzen) und Doku 10.14 angepasst werden
- [ ] Echter Kauf mit drei Basis-Abos und Angebot (Lizenztester), Anzeige der echten Preise und Angebote, „spare … %“
      mit echten Store-Preisen
- [ ] Wechsel jährlich ↔ monatlich am Gerät inkl. Zeit-Anrechnung; Dashboard zeigt alten Kauf „ersetzt“
- [ ] Feldnamen `lineItems[].offerDetails.basePlanId/offerId` gegen die echte Schnittstelle
- [ ] Angebot „Neukunden gewinnen“ erscheint für neuen Tester, nicht für Tester mit früherem Kauf
- [ ] Deutsche Menünamen der Play Console (Basis-Abo, Angebot, Phasen, Berechtigung, Standard-Ersatzmodus), Preise
      0,99 € / 4,99 € / 8,99 € wählbar
- [ ] Play-Bundle mit direkt eingebundenem `in_app_purchase_android` und GitHub-APK mit drittem Platzhalter starten
      auf einem echten Gerät; erster CI-Lauf mit den geänderten Override-Schritten
- [ ] Rücksprung `alembic downgrade 0007` im echten Unraid-Container

**Bewusst offen / bekannte Grenzen**

- Überspring-Grenze nur in der App: ältere oder umgebaute Apps zählen nicht, Neuinstallation/App-Daten löschen setzt
  zurück, Sprünge zurück und zu früheren Titeln zählen nicht.
- Wünsche: rollierende 7 Tage; ein zurückgezogener offener Wunsch gibt den Platz frei; Premium heißt „ohne
  Wochengrenze“ – die Grenzen gegen Missbrauch (20 offen, 15 pro Tag) gelten weiter für alle.
- Ältere Apps kennen die neuen Sperren nicht: Qualität wird still gedeckelt, gesperrte Videos/Songtexte zeigen nur
  einen allgemeinen Fehler, Überspringen bleibt frei, Werbefreiheit dort weiter nach „Premium aktiv“ (ein Teil-Code
  ohne `no_ads` macht in alten Apps werbefrei).
- Abzeichen sieht nur der Benutzer selbst (kein öffentliches Profil).
- Admin-Vergabe schaltet immer alle Leistungen frei; nur Codes haben einen Umfang. Ein Abo schaltet immer alle frei.
- Wechsel immer sofort mit voller Zahlung (Restzeit hängt Google an); „erst zum Laufzeitende wechseln“ wird nicht
  angeboten (siehe Offen).
- Überspring-Grenze: Antippen eines Titels in einer Liste zählt nicht; App-Start ohne Verbindung → keine Grenze.
- Qualitätsdeckel ändert sich mitten im Titel (Premium endet, Schalter umgelegt): Spulen in diesem Titel kann
  abbrechen, der nächste läuft normal.
- Angebote „vom Entwickler festgelegt“ werden nicht unterschieden (Doku rät ab); ein Angebot je Laufzeit.
- Der Server kennt keine Preise; das Dashboard liest die Basis-Abos nicht bei Google aus (Kennungen trägt der
  Betreiber ein).
- Rücksprung auf 0007 macht Teil-Lizenzen zu vollem Premium.
- Laufzeitwechsel bei gestörter Verbindung: bis der neue Kauf beim Server ist, sieht er nur den beendeten alten;
  abgefedert durch den gemerkten Kauf in der App, sonst bis zum nächsten Start.
- iPhone/Windows: weiter kein Kauf; die Leistungsschalter gelten dort trotzdem (Server entscheidet), Premium per Code.

## Weitermachen nach einer Unterbrechung

- Fertige Prüfbereiche werden nicht wiederholt: Der Prüf-Durchlauf (`wf_bbbf3d22-7ca`) lässt sich
  fortsetzen, abgeschlossene Prüfer liefern ihr gespeichertes Ergebnis sofort.
- Die vollständigen Funde (mit Nachweis und Lösungsvorschlag) liegen zusätzlich im Arbeitsordner der
  Sitzung unter `pruefung/ergebnisse.json`.
- Reihenfolge beim Beheben: kritisch → hoch → mittel → niedrig; nach jedem Block testen, committen, pushen
  und diese Liste abhaken.
