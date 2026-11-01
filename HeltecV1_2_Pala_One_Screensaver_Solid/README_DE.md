# PALA One E-Reader — Custom-Firmware (Heltec Wireless Paper V1.2)

Angepasstes Build der PALA-One-Firmware für den **Heltec Wireless Paper (V1.2)** mit einem
sauberen, soliden **„PALA"-Screensaver** und einigen Verbesserungen gegenüber der Stock-Firmware.

## Dateien

| Datei | Zweck |
|-------|-------|
| `src/HeltecV1_2_Pala_One_2_0.ino` | Haupt-Firmware (Arduino-Sketch) |
| `boards/heltec_wireless_paper.json` | PlatformIO-Boarddefinition |
| `lib/heltec-eink-modules/` | E-Ink-Treiberbibliothek (notwendig zum Bauen) |
| `include/pala_one_sleep_black_icon_v4.h` | Optionales Schlafbild-Bitmap (standardmäßig *nicht* verwendet) |
| `platformio.ini` | PlatformIO-Konfiguration |
| `partitions.csv` | Partitionstabelle |

## Screensaver

Der Standardschlafbildschirm zeigt den **„PALA"-Schriftzug in großen, klaren Buchstaben**
(logisoso 58, zentriert) und darunter den **Akku-Stand** als Balken mit Prozentanzeige.

Unterschreitet der Akku **10 %**, erscheint stattdessen ein **Warn-Dreieck mit „Please charge!"**.

Optional kannst du ein eigenes, vollflächiges Bild (`/sleep.bin`, 250×122, XBM, 3904 Bytes)
hochladen — existiert es, wird es statt des Schriftzugs angezeigt.

## Änderungen gegenüber der Stock-Firmware

- **Akku-Prozent in der Statusleiste** (6x10-Font) neben dem Akku-Symbol.
- **Akku-Anzeige im Screensaver** mit Prozent und „Please charge!"-Warnung unter 10 %.
- **Eigenes Screensaver-Bild** über `/sleep.bin` (statt festem Standard-Logo).
- **Automatische Kapitelerkennung und -navigation** (siehe unten).
- **Bibliothek**:
  - 12×12-Buch-Icon in der Buchliste.
  - Virtueller **„Books"-Ordner**, der alle `.epub`/`.txt`/`.bin`-Bücher bündelt.
  - Lange Titel **laufen (Marquee)**, damit sie komplett lesbar sind.
- **Upload über USB (seriell)**: Bücher werden direkt über die USB-Serial-Verbindung übertragen;
  das Gerät wartet **nicht** auf einen Bestätigungsbutton. Fehler beim Upload erscheinen nur im PC-Terminal.
- **Upload auch über WiFi (Web-App)**: Der Reader stellt eine Webseite auf seinem AP bereit;
  dort lässt sich per Drag & Drop ein Buch (oder ein Schlafbild) hochladen.
- **Englische Gerätetexte** (einheitlich).
- **Schnellerer Boot** (CPU 240 MHz, wird im Idle gedrosselt).
- **Seriell auf 115200 Baud** (passend zum Upload-Tool).
- Deep Sleep bleibt aktiv.

## Bücher per USB/Serial hochladen

Das PC-Tool `pala_upload.py` (dieses Paket → `tools/`) spricht über die USB-Serialschnittstelle
mit dem Reader, erkennt den Port automatisch und weckt das Gerät aus dem Deep-Sleep auf.

```bash
# Buch hochladen (EPUB wird automatisch in Text umgewandelt)
python pala_upload.py book.epub
python pala_upload.py book.txt

# Bücher auflisten (nummeriert)
python pala_upload.py list

# Buch löschen (per Nummer aus "list" oder per Name/Teilname)
python pala_upload.py del 3
python pala_upload.py del "mybook.txt"

# Firmware-Version, Akku, Sleep-Timeout, Bücherzahl anzeigen
python pala_upload.py info
```

Es gibt **keine Bestätigungsabfrage** am Gerät; der Fortschritt läuft im CLI-Tool.
Benötigt Python 3 (ggf. `~/platformio/penv/bin/python pala_upload.py …`).

## Automatische Kapitel

Beim Öffnen scannt der Reader jedes Buch nach Kapitelüberschriften und legt das Ergebnis
als Cache ab — beim nächsten Öffnen ist die Navigation sofort da.

**Erkennung:** Eine Zeile gilt als Kapitelüberschrift, wenn sie kurz ist (≤ 60 Zeichen) und:

- eine reine **Zahl** ist, z. B. `12` oder `12:` (angezeigt als „Kapitel 12")
- eine **römische Zahl**, z. B. `III` oder `IV.`
- ein Präfix hat: `Kapitel`, `Chapter`, `Teil`, `Part`, `Abschnitt`, `Akt`, `Stück`, `Prolog`, `Epilog`, `Einleitung`, `Vorspiel`/`Proem`
- aus **Trennzeichen** besteht: `***`, `---`, `===`, `___` oder `~~~` (≥ 3 Zeichen)
- eine kurze **GROSSGESCHRIEBENE** Zeile ist (z. B. `THE HUNT BEGINS`)

Die erste Zeile der Datei (meist Titel/Autor) wird nie als Kapitel gewertet.
Hat ein Buch keine erkannten Überschriften, zeigt die Kapitelansicht „No chapters".

> Hinweis: Die Kapitelliste ist aus dem Lesemodus derzeit **nicht erreichbar** (Triple-Klick öffnet jetzt die Bücherliste, siehe *Bedienung*). Erkennung und Cache laufen weiterhin.

**Nutzung der Kapitelliste** (wenn geöffnet):

- **kurzer Klick** – nächstes Kapitel
- **Doppelklick** – vorheriges Kapitel
- **langer Klick** – zum markierten Kapitel springen

## Bedienung

| Wo | Kurzer Klick | Doppelklick | Langer Klick | Triple-Klick |
|---|---|---|---|---|
| Lesemodus | nächste Seite | vorherige Seite | Seite als Zitat speichern | → Bücherliste (aktuelles Buch markiert) |
| Bücherliste | nächster Eintrag | Buch öffnen | Buch löschen (mit Rückfrage) | → Startseite |
| Startseite | nächster Eintrag | Eintrag öffnen | – | – |
| Rückfrage-Dialog | Option wechseln | markierte Option wählen | abbrechen | abbrechen |

Wer über die letzte Seite hinaus weiterblättert, wird gefragt, ob das fertig gelesene Buch gelöscht werden soll („Behalten“ ist vorausgewählt). Ohne Eingabe bricht der Dialog nach 30 s ab. Löschanfragen vom PC (`pala_upload.py del`, Sync) nutzen denselben Dialog.

## Bauen & Flashen

```bash
cd "HeltecV1_2_Pala_One_Screensaver_Solid"
pio run -t upload
```

- Boarddefinition liegt lokal in `boards/` → kein Custom-Board-Install nötig.
- `upload_port`/`monitor_port` stehen auf `/dev/ttyUSB0`; ggf. in `platformio.ini` anpassen.

## Hinweise

- Der `.pio`-Ordner ist Build-Ausgabe und kann gelöscht werden (wird neu erzeugt).
- `include/pala_one_sleep_black_icon_v4.h` ist nur Referenzmaterial — standardmäßig wird der
  textbasierte Schriftzug verwendet.