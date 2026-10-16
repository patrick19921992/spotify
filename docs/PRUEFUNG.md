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

## Weitermachen nach einer Unterbrechung

- Fertige Prüfbereiche werden nicht wiederholt: Der Prüf-Durchlauf (`wf_bbbf3d22-7ca`) lässt sich
  fortsetzen, abgeschlossene Prüfer liefern ihr gespeichertes Ergebnis sofort.
- Die vollständigen Funde (mit Nachweis und Lösungsvorschlag) liegen zusätzlich im Arbeitsordner der
  Sitzung unter `pruefung/ergebnisse.json`.
- Reihenfolge beim Beheben: kritisch → hoch → mittel → niedrig; nach jedem Block testen, committen, pushen
  und diese Liste abhaken.
