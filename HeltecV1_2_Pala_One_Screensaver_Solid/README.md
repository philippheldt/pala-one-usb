# PALA One E-Reader — Custom Firmware (Heltec Wireless Paper V1.2)

Custom build of the PALA One E-Reader firmware for the **Heltec Wireless Paper (V1.2)** with a clean, solid **"PALA"** screensaver logo and several quality-of-life improvements over the stock firmware.

## What's inside

| File | Purpose |
|------|---------|
| `src/HeltecV1_2_Pala_One_2_0.ino` | Main firmware sketch |
| `boards/heltec_wireless_paper.json` | PlatformIO board definition |
| `lib/heltec-eink-modules/` | E-Ink display driver library (required) |
| `include/pala_one_sleep_black_icon_v4.h` | Optional embedded sleep-screen bitmap (not used by default) |
| `platformio.ini` | PlatformIO project configuration |
| `partitions.csv` | Partition table (SPIFFS/LittleFS aware) |

## Screensaver

The default sleep screen shows the **"PALA" wordmark in large, clean letters** (logisoso 58, centered), with the battery level drawn below it.

You can also upload your **own full-screen image** (`/sleep.bin`, 250×122, XBM layout, 3904 bytes, black = stored as `0`, background white):

- If `/sleep.bin` exists (≥ 3904 bytes) it is shown instead of the wordmark.
- Otherwise the built-in "PALA" wordmark is drawn.

The helper upload tool shows a "Sleep" target for this purpose (see `tools/` in the original firmware package).

## Changes vs. stock firmware

- **Battery percentage in the status bar** (6x10 font) next to the battery icon.
- **Screensaver battery indicator**: battery outline with percentage, plus a warning triangle and "Please charge!" when below 10%.
- **Custom screensaver image support** via `/sleep.bin` upload (was fixed default logo only).
- **Automatic chapter detection & navigation** (see below).
- **Library improvements**:
  - 12×12 book icon shown for book entries.
  - Virtual **"Books" folder** that aggregates all `.epub`/`.txt`/`.bin` books on the device into a single menu entry.
  - Long titles **scroll (marquee)** so the full name is readable.
- **Upload over USB (serial)**: books are pushed straight over the USB/serial connection; the device does **not** wait for a button press. Errors while uploading are reported only on the PC terminal.
- **Upload also over WiFi (web app)**: the reader serves a web page on its AP where you can drag & drop a book (or a sleep image, see `Upload → Sleep image` in the device menu).
- **English device messages** (UI consistent with the reviewer's language).
- **Faster boot**: CPU boosted to 240 MHz at start, throttled down dynamically when idle.
- **Serial at 115200** (matches the upload tool).
- Light-sleep idle throttling removed; device deep-sleeps properly (deep sleep still enabled).

## Uploading books (USB / serial)

The PC tool `pala_upload.py` (from `tools/` in the original firmware package) talks to the reader over the USB serial connection. It auto-detects the port and wakes the reader if it is in deep sleep.

```bash
# Upload a book. EPUB files are converted to text automatically.
python pala_upload.py book.epub
python pala_upload.py book.txt

# List all books on the reader (numbered)
python pala_upload.py list

# Delete a book by number (from "list") or by name / partial name
python pala_upload.py del 3
python pala_upload.py del "mybook.txt"

# Show firmware version, battery level, sleep timeout and book count
python pala_upload.py info
```

There is no confirmation dialog on the reader during uploads; the progress is shown by the CLI tool. Use Python 3. On some systems you may need to run it with the PlatformIO python:

```bash
~/path/to/platformio/penv/bin/python pala_upload.py list
```

> If `pala` (or `pala_upload.py`) is on your PATH you can also call it as `pala list`, `pala del 2`, `pala info`, etc.

## Automatic chapters

The reader scans every book for chapter-like headings while it is opened, and caches the result so navigation is instant on later openings.

### How chapters are detected

A line is treated as a chapter heading when it is short (≤ 60 characters) and matches any of:

- a pure **number** line, e.g. `12` or `12:` (_shown as "Kapitel 12"_)
- a **Roman numeral**, e.g. `III` or `IV.`
- an explicit prefix: `Kapitel`, `Chapter`, `Teil`, `Part`, `Abschnitt`, `Akt`, `Stück`, `Prolog`, `Epilog`, `Einleitung`, `Vorspiel`/`Proem`
- a **separator** line of `***`, `---`, `===`, `___` or `~~~` (≥ 3 characters)
- a short **ALL-CAPS** line (e.g. `THE HUNT BEGINS`)

The first line of the file (usually the book title/author) is never treated as a chapter.

If a book has no detected headings, the Chapters screen simply says "No chapters".

### Using chapters

> Note: the chapter list is currently **not reachable** from the reader (triple-click now opens the Books list, see *Controls* below). Detection and caching still run.

The Chapters list (when opened) works like this:

- **short click** – next chapter
- **double click** – previous chapter
- **long click** – jump to the selected chapter

The selected entry scrolls to stay centered; up to six entries are visible at once.

## Controls

| Where | Short click | Double click | Long click | Triple click |
|---|---|---|---|---|
| Reader | next page | previous page | save page as quote | → Books list (current book selected) |
| Books list | next entry | open book | delete book (asks first) | → Home |
| Home | next entry | open entry | – | – |
| Confirm dialog | switch option | choose selected option | cancel | cancel |

Paging past the last page of a book asks whether the finished book should be deleted ("Behalten" is preselected). The confirm dialog cancels itself after 30 s without input. Deleting requested by the PC tool (`pala_upload.py del`, sync) uses the same dialog.

## Prerequisites

- [PlatformIO Core](https://platformio.org/) (tested with the `espressif32` platform).
- Python 3 for PlatformIO.
- The original `pala_upload.py` tool from the firmware package (EPUB conversion + upload).

## Build & flash

```bash
cd "Heltec V1.2/HeltecV1_2_Pala_One_Screensaver_Solid"
pio run -t upload
```

Notes:

- The board definition is included locally (`boards/`), so no custom board install is needed.
- `upload_port` / `monitor_port` are preset to `/dev/ttyUSB0`; adjust in `platformio.ini` if your device is on another port.

## Regenerating the sleep-screen bitmap

If you want to embed a different built-in screensaver, replace the `drawXBitmap` fallback inside `drawSleepScreen()` with the content of `include/pala_one_sleep_black_icon_v4.h` (black = `1` bit convention; the canvas is cleared to white with `fillScreen(0)`).

Tip: preferred runtime logo rendering uses `u8g2_font_logisoso58_tf` (full Latin glyph range; `logisoso62/78/92` are numbers-only in this build).

## Uploading books

Use the PC tool from the original release (`tools/pala_upload.py`):

```bash
python pala_upload.py list          # list books on device
python pala_upload.py upload ebook.epub   # convert + upload
python pala_upload.py info          # show battery/sleep/books
```

Books are stored in LittleFS; the library menu refreshes on boot.

## Known limitations

- The `include/pala_one_sleep_black_icon_v4.h` is only a reference asset in this variant; it is **not** included by the source (the default is the text-based wordmark).
- Removing the `.pio` directory is safe (regenerated on first build).