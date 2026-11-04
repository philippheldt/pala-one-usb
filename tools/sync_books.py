#!/usr/bin/env python3
import os
import sys
import glob
import re
import json
import tempfile
import argparse
from datetime import datetime
import pala_upload

DEFAULT_SOURCE_DIR = os.path.expanduser("~/pCloud Drive/books-articles")
SOURCE_DIR = DEFAULT_SOURCE_DIR
NOTES_DIR = os.path.join(SOURCE_DIR, "Notes")
# The sync state lives in the sync folder itself, so every Mac (and the
# Mac app as well as this script) sees the same state via pCloud.
STATE_FILE = os.path.join(SOURCE_DIR, ".pala_state.json")
# Older versions kept the state next to this script.
LEGACY_STATE_FILES = [
    os.path.join(os.path.dirname(os.path.abspath(__file__)), ".pala_state.json"),
    os.path.expanduser("~/pCloud Drive/pala-usb-tool/tools/.pala_state.json"),
]

# Machine-readable progress for the Mac app (enabled with --events).
EVENTS = False
STATS = {"uploaded": 0, "upload_failed": 0, "deleted_local": 0, "deleted_pala": 0, "quotes": 0}


def emit(event, **data):
    if EVENTS:
        print("@@PALA " + json.dumps(dict(event=event, **data), ensure_ascii=False), flush=True)


def configure(source_dir):
    global SOURCE_DIR, NOTES_DIR, STATE_FILE
    SOURCE_DIR = os.path.abspath(os.path.expanduser(source_dir))
    NOTES_DIR = os.path.join(SOURCE_DIR, "Notes")
    STATE_FILE = os.path.join(SOURCE_DIR, ".pala_state.json")

def simplify_name(name):
    return re.sub(r'[^a-zA-Z0-9]', '', name).lower()

def clean_and_merge_quotes(page_quotes):
    """
    Sortiert Zitate nach Seitenzahlen, fügt aufeinanderfolgende Seiten zusammen,
    bereinigt Zeilenumbrüche und schneidet unvollständige Rand-Sätze strikt ab.
    """
    if not page_quotes:
        return []

    # 1. Nach Seitenzahl sortieren
    sorted_quotes = sorted(page_quotes, key=lambda x: int(x[0]))

    merged_groups = []
    current_group = []

    # 2. Zusammenhängende Seiten gruppieren (z. B. Seite 3 und 4)
    for page_num_str, text in sorted_quotes:
        p_num = int(page_num_str)
        if not current_group:
            current_group.append((p_num, text))
        else:
            last_p = current_group[-1][0]
            if p_num == last_p + 1:
                current_group.append((p_num, text))
            elif p_num == last_p:
                pass
            else:
                merged_groups.append(current_group)
                current_group = [(p_num, text)]
    if current_group:
        merged_groups.append(current_group)

    final_quotes = []

    # 3. Gruppen verarbeiten
    for group in merged_groups:
        start_page = group[0][0]
        end_page = group[-1][0]

        page_label = f"Seite {start_page}" if start_page == end_page else f"Seiten {start_page}–{end_page}"

        # 3a. Umbrüche innerhalb von Sätzen säubern
        raw_combined = " ".join([t.strip() for _, t in group])
        combined_text = re.sub(r'\s+', ' ', raw_combined).strip()

        # 3b. Bei Einzelseiten (oder isolierten Blöcken) Randsätze strikt abschneiden:
        if len(group) == 1 and combined_text:
            # ERSTEN UNVOLLSTÄNDIGEN SATZ ABSCHNEIDEN:
            if not combined_text[0].isupper():
                first_punc = re.search(r'[\.\!\?]', combined_text)
                if first_punc:
                    combined_text = combined_text[first_punc.end():].strip()

            # LETZTEN UNVOLLSTÄNDIGEN SATZ ABSCHNEIDEN:
            last_punc = max(
                combined_text.rfind('.'),
                combined_text.rfind('!'),
                combined_text.rfind('?')
            )
            if last_punc != -1:
                combined_text = combined_text[:last_punc + 1].strip()

        clean_text = combined_text.strip()
        if clean_text:
            final_quotes.append((page_label, clean_text))

    return final_quotes

def extract_existing_quotes_from_md(md_path):
    """Liest bereits bestehende Zitate aus einer existierenden Markdown-Datei aus."""
    existing_quotes = []
    if not os.path.exists(md_path):
        return existing_quotes

    try:
        with open(md_path, "r", encoding="utf-8") as f:
            content = f.read()

        # Parst bestehende Zitate-Blöcke (> "Text" \n *(Seite X)*)
        matches = re.findall(r'>\s*"?([\s\S]*?)"?\s*\n\*\((?:Seiten|Seite)\s*([0-9–\-]+)\)\*', content)
        for text, page_num in matches:
            # Bei Bereichen wie "3–4" nehmen wir die erste Seite für die Sortierung
            first_page = page_num.split("–")[0].split("-")[0].strip()
            existing_quotes.append((first_page, text.strip()))
    except Exception as e:
        print(f"   Hinweis: Konnte bestehende Markdown-Zitate nicht parsen: {e}")

    return existing_quotes

def generate_markdown_note(book_name, processed_quotes):
    """Generiert ein sauber strukturiertes Markdown-Dokument."""
    base_name = os.path.splitext(book_name)[0]
    display_title = base_name.replace('_', ' ').strip().title()
    sync_date = datetime.now().strftime("%d.%m.%Y um %H:%M Uhr")

    lines = [
        f"# 📝 Zitate: {display_title}",
        f"**Quelle:** `{book_name}`  ",
        f"**Zuletzt aktualisiert:** {sync_date}  ",
        f"**Anzahl Zitate:** {len(processed_quotes)}",
        "\n---",
        "\n## 📌 Wichtige Zitate\n"
    ]

    for page_label, quote_text in processed_quotes:
        lines.append(f"> \"{quote_text}\"")
        lines.append(f"*({page_label})*\n")

    return "\n".join(lines)

def clear_pala_log(port):
    """Befiehlt dem Pala über USB, die /.zitate_log.txt auf 0 Bytes zu leeren."""
    def attempt(ser, fast):
        ser.write(b"PALA:CLEAR_QUOTES\n")
        ser.flush()
        line = pala_upload.read_until(ser, ("PALA:OKCLEAR", "PALA:ERR:"), deadline=(5 if fast else 10))
        return True if line and "PALA:OKCLEAR" in line else False
    return pala_upload.run_with_wake(port, attempt)

def sync_quotes_log(port):
    """Liest Zitate aus, verknüpft sie mit bestehenden MD-Dateien und leert das Log auf dem Pala."""
    os.makedirs(NOTES_DIR, exist_ok=True)

    remote_log_path = "/.zitate_log.txt"
    temp_dir = tempfile.gettempdir()
    temp_log = os.path.join(temp_dir, "pala_zitate_temp.txt")

    if hasattr(pala_upload, 'download_book') and pala_upload.download_book(port, remote_log_path, temp_log):
        if os.path.exists(temp_log) and os.path.getsize(temp_log) > 0:
            print("\n--- ZITATE VERARBEITEN & MARKDOWN ERSTELLEN/ANHÄNGEN ---")

            with open(temp_log, "r", encoding="utf-8", errors="ignore") as tf:
                content = tf.read()

            raw_blocks = content.split("---BOOK_START---")
            new_quotes_by_book = {}

            for block in raw_blocks:
                if "---BOOK_END---" not in block:
                    continue

                book_match = re.search(r"BOOK:(.+)", block)
                page_match = re.search(r"PAGE:(.+)", block)
                content_match = re.search(r"CONTENT:\n([\s\S]+?)\n---BOOK_END---", block)

                if book_match and page_match and content_match:
                    book_name = book_match.group(1).strip()
                    page_num = page_match.group(1).strip()
                    quote_text = content_match.group(1).strip()

                    if book_name not in new_quotes_by_book:
                        new_quotes_by_book[book_name] = []

                    new_quotes_by_book[book_name].append((page_num, quote_text))

            # Für jedes Buch: Alte Zitate aus bestehender MD laden + Neue anfügen
            for book_name, raw_new_quotes in new_quotes_by_book.items():
                base_name = os.path.splitext(book_name)[0]
                md_filename = f"Note_{base_name}.md"
                md_path = os.path.join(NOTES_DIR, md_filename)

                # 1. Vorhandene Zitate aus bestehender MD-Datei auslesen
                all_raw_quotes = extract_existing_quotes_from_md(md_path)

                # 2. Neue Zitate hinzufügen
                all_raw_quotes.extend(raw_new_quotes)

                # 3. Bereinigen, sortieren und zusammenführen
                processed_quotes = clean_and_merge_quotes(all_raw_quotes)

                # 4. Markdown erzeugen und speichern
                md_code = generate_markdown_note(book_name, processed_quotes)

                with open(md_path, "w", encoding="utf-8") as mf:
                    mf.write(md_code)

                print(f"✅ Zitate angehängt & aktualisiert: Notes/{md_filename}")
                STATS["quotes"] += len(raw_new_quotes)
                emit("quotes", book=book_name, count=len(raw_new_quotes), file=md_filename)

            os.remove(temp_log)

            # 5. Datei auf dem Pala leeren (auf 0 Bytes zurücksetzen)
            print("🧹 Leere Zitate-Log auf dem Pala...")
            clear_pala_log(port)
        else:
            print("\n    (Keine neuen Zitate auf dem Pala vorhanden)")

def load_state():
    for path in [STATE_FILE] + LEGACY_STATE_FILES:
        if os.path.exists(path):
            try:
                with open(path, "r") as f:
                    state = set(json.load(f))
                if path != STATE_FILE:
                    print(f"   Übernehme bisherigen Sync-Status aus {path}")
                return state
            except Exception:
                pass
    return set()

def save_state(state_set):
    try:
        with open(STATE_FILE, "w") as f:
            json.dump(list(state_set), f)
    except Exception as e:
        print(f"Warnung: Status konnte nicht gespeichert werden: {e}")

import locale
import re
import os
import tempfile
from datetime import datetime

def truncate_txt_to_today(txt_path):
    """
    Sucht in einer existierenden .txt-Datei nach dem heutigen Datum
    (z.B. 'Donnerstag, 29. Oktober') und gibt den Pfad zu einer temporären
    Datei zurück, die nur den Text ab heute enthält.
    """
    try:
        for loc in ["de_DE.UTF-8", "de_DE", "deu_deu", ""]:
            try:
                locale.setlocale(locale.LC_TIME, loc)
                break
            except Exception:
                pass

        now = datetime.now()
        wochentag = now.strftime("%A")  # z. B. Donnerstag
        tag = str(now.day)              # z. B. 29
        monat = now.strftime("%B")      # z. B. Oktober

        pattern = re.compile(rf"{wochentag},\s+{tag}\.\s+{monat}", re.IGNORECASE)

        with open(txt_path, "r", encoding="utf-8", errors="ignore") as f:
            content = f.read()

        match = pattern.search(content)
        if match:
            print(f"   📅 Datum '{wochentag}, {tag}. {monat}' in .txt gefunden! Schneide alten Text ab...")
            truncated_content = content[match.start():].strip()

            # Temporäre Datei im Temp-Ordner anlegen
            temp_dir = tempfile.gettempdir()
            prep_path = os.path.join(temp_dir, "Bibel-fuer-heute.txt")

            with open(prep_path, "w", encoding="utf-8") as tf:
                tf.write(truncated_content)

            # Absoluten Pfad zurückgeben
            return os.path.abspath(prep_path)
        else:
            print(f"   ⚠️ Datum '{wochentag}, {tag}. {monat}' nicht in der .txt gefunden.")

    except Exception as e:
        print(f"   Fehler beim Kürzen der .txt-Datei: {e}")

    return os.path.abspath(txt_path)

def run_sync(port=None):
    if not os.path.isdir(SOURCE_DIR):
        print(f"Sync-Ordner nicht gefunden: {SOURCE_DIR}")
        emit("error", message=f"Sync-Ordner nicht gefunden: {SOURCE_DIR}")
        return 1

    port = port or pala_upload.find_port()
    if not port:
        print("Kein Pala über USB gefunden. Bitte anschließen!")
        emit("error", message="Kein Pala über USB gefunden.")
        return 1

    # 1. Zitate verarbeiten & Pala Log leeren
    emit("step", name="Zitate abholen")
    sync_quotes_log(port)

    print("\n--> Lese aktuelle Dateien vom Pala...")
    emit("step", name="Bücherliste lesen")
    pala_books = pala_upload.fetch_books(port)
    if not isinstance(pala_books, list):
        # Never continue without a valid list: an empty list would make every
        # book look "read" and delete it from pCloud.
        print("Konnte die Bücherliste nicht vom Pala lesen. Abbruch.")
        emit("error", message="Konnte die Bücherliste nicht vom Pala lesen.")
        return 1

    pala_simple_set = set()
    for b in pala_books:
        pala_simple_set.add(simplify_name(b))
        pala_simple_set.add(simplify_name(os.path.basename(b)))

    previous_pala_state = load_state()

    # 2. Lokale pCloud-Dateien scannen
    local_files = {}

    for filepath in glob.glob(os.path.join(SOURCE_DIR, "**", "*"), recursive=True):
        if not os.path.isfile(filepath):
            continue

        if "Notes" in filepath.split(os.sep):
            continue

        ext = os.path.splitext(filepath)[1].lower()
        if ext not in ('.epub', '.txt', '.md'):
            continue

        rel_path = os.path.relpath(filepath, SOURCE_DIR)
        expected_name = rel_path[:-5] + ".txt" if rel_path.lower().endswith(".epub") else rel_path

        simple_full = simplify_name(expected_name)
        simple_base = simplify_name(os.path.basename(expected_name))

        local_files[simple_full] = (filepath, expected_name)
        local_files[simple_base] = (filepath, expected_name)

    # 3. AUTOMATISCHES LÖSCHEN IN PCLOUD (wenn auf Pala fertig gelesen/gelöscht):
    print("\n--- PRÜFE AUF AUF DEM PALA GELESENE / GELÖSCHTE BÜCHER ---")
    processed_removals = set()
    for simple_name in list(local_files.keys()):
        filepath, expected_name = local_files[simple_name]

        if filepath in processed_removals:
            continue

        # Bibel NIEMALS automatisch aus der pCloud löschen!
        if "bibelfuerheute" in simple_name or "bibelheute" in simple_name:
            continue

        if simple_name in previous_pala_state and simple_name not in pala_simple_set:
            print(f"--> Fertig gelesen! Lösche lokal aus pCloud: {os.path.basename(filepath)}")
            try:
                if os.path.exists(filepath):
                    os.remove(filepath)
                processed_removals.add(filepath)
                STATS["deleted_local"] += 1
                emit("deleted_local", name=os.path.basename(filepath))
            except Exception as e:
                print(f"    Fehler beim Löschen der pCloud-Datei: {e}")

    # 4. LÖSCHEN AUF DEM PALA (wenn manuell aus pCloud gelöscht):
    print("\n--- PRÜFE AUF VOM MAC GELÖSCHTE BÜCHER ---")
    for remote_file in pala_books:
        if remote_file.endswith("zitate_log.txt") or remote_file.endswith(".zitate_log.txt"):
            continue

        simple_remote = simplify_name(remote_file)
        simple_remote_base = simplify_name(os.path.basename(remote_file))

        if simple_remote not in local_files and simple_remote_base not in local_files:
            print(f"--> Lösche vom Pala (in pCloud entfernt): {remote_file}")
            if pala_upload.delete_book(port, remote_file) == 0:
                STATS["deleted_pala"] += 1
                emit("deleted_pala", name=remote_file)

    # 5. HOCHLADEN NEUER BÜCHER & TÄGLICHES BIBEL-UPDATE:
    print("\n--- PRÜFE AUF NEUE BÜCHER & BIBEL-UPDATES ---")
    current_pala_state = set()
    uploaded_paths = set()

    for simple_key, (local_path, expected_name) in local_files.items():
        if local_path in uploaded_paths or local_path in processed_removals:
            # just deleted from pCloud because it was read on the Pala
            continue
        uploaded_paths.add(local_path)

        simple_full = simplify_name(expected_name)
        simple_base = simplify_name(os.path.basename(expected_name))

        is_daily_bible = "bibelfuerheute" in simple_base or "bibelheute" in simple_base

        if is_daily_bible:
            print(f"📖 Verarbeite Tages-Bibel aus pCloud: {os.path.basename(local_path)}")

            # 1. Text ab dem heutigen Datum kürzen
            upload_src = truncate_txt_to_today(local_path)

            # 2. Alte Bibel auf dem Pala löschen (resettet den Lesestand auf Seite 1)
            pala_upload.delete_book(port, expected_name)

            # 3. Gekürzten Text neu hochladen
            print(f"--> Übertrage tagesaktuelle Bibel auf Pala: {os.path.basename(upload_src)}")
            emit("uploading", name=os.path.basename(expected_name))
            pala_upload.upload_book(port, upload_src)

        else:
            if simple_full not in pala_simple_set and simple_base not in pala_simple_set:
                print(f"--> Übertrage neu auf Pala: {os.path.basename(local_path)}")
                emit("uploading", name=os.path.basename(local_path))
                if pala_upload.upload_book(port, local_path) == 0:
                    STATS["uploaded"] += 1
                    emit("uploaded", name=os.path.basename(local_path))
                else:
                    STATS["upload_failed"] += 1
                    emit("upload_failed", name=os.path.basename(local_path))
            else:
                print(f"    Bereits auf Pala: {os.path.basename(local_path)}")

        current_pala_state.add(simple_full)
        current_pala_state.add(simple_base)

    save_state(current_pala_state)

    print("\nSpiegelung erfolgreich beendet!")
    emit("done", **STATS)
    return 0


def main():
    global EVENTS
    parser = argparse.ArgumentParser(description="Pala One: pCloud-Ordner mit dem Pala synchronisieren")
    parser.add_argument("--source", default=DEFAULT_SOURCE_DIR, help="Sync-Ordner (Standard: ~/pCloud Drive/books-articles)")
    parser.add_argument("--port", help="Serieller Port (Standard: automatisch)")
    parser.add_argument("--events", action="store_true", help="Maschinenlesbare Fortschrittszeilen ausgeben (für die Mac-App)")
    args = parser.parse_args()

    try:
        sys.stdout.reconfigure(line_buffering=True)
    except Exception:
        pass

    EVENTS = args.events
    configure(args.source)
    try:
        return run_sync(args.port)
    except Exception as e:
        print(f"Fehler: {e}")
        emit("error", message=str(e))
        return 1


if __name__ == "__main__":
    sys.exit(main())