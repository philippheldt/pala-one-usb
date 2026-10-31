#!/usr/bin/env python3
"""Upload a book to Pala One over USB serial.

Requires: pyserial  (pip install pyserial, or use the PlatformIO python)

Usage:
    python pala_upload.py <book.txt|book.epub> [port]
    python pala_upload.py --list
    python pala_upload.py --delete <name|number>

EPUB files are converted to plain text on the PC first (spine order,
HTML stripped), then uploaded as <name>.txt like any other book.
Default port: Auto-detected (cu.usbserial*, /dev/ttyUSB0, etc.)
"""
import os
import re
import sys
import time
import tempfile
import zipfile
import posixpath
import argparse
import xml.etree.ElementTree as ET
from io import BytesIO
from html.parser import HTMLParser

try:
    import serial
except ImportError:
    print("pyserial is missing. Install it with:  pip install pyserial")
    print("(or run this with the PlatformIO python, e.g. ~/.platformio/penv/bin/python pala_upload.py)")
    sys.exit(2)

BAUD = 115200
CHUNK = 256


# ---------------------------------------------------------------------------
#  EPUB -> plain text conversion (runs on the PC, stdlib only)
# ---------------------------------------------------------------------------
_BLOCK_TAGS = {
    "p", "div", "section", "article", "blockquote", "li", "dd", "dt",
    "tr", "td", "th", "table", "header", "footer", "figcaption",
    "caption", "address", "pre",
}
_SKIP_TAGS = {"script", "style", "noscript", "svg", "audio", "video", "head"}


class _TextExtract(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.lines = []
        self.cur = ""
        self.gap = False
        self.skip_depth = 0
        self.in_head = 0
        self.head_buf = []
        self.chapters = 0

    def handle_starttag(self, tag, attrs):
        t = tag.lower()
        if t in _SKIP_TAGS:
            self.skip_depth += 1
            return
        if self.skip_depth:
            return
        if t in ("h1", "h2", "h3"):
            self.in_head += 1
            if self.in_head == 1:
                self.head_buf = []
        elif t in ("br", "hr"):
            self._flush(para=False)

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)

    def handle_endtag(self, tag):
        t = tag.lower()
        if t in _SKIP_TAGS:
            self.skip_depth = max(0, self.skip_depth - 1)
            return
        if self.skip_depth:
            return
        if t in ("h1", "h2", "h3"):
            if self.in_head:
                self.in_head -= 1
            if self.in_head == 0:
                txt = " ".join("".join(self.head_buf).split())
                if txt:
                    self.chapters += 1
                    if self.gap and self.lines:
                        self.lines.append("")
                    self.lines.append(txt)
                    self.gap = True
                self.head_buf = []
            return
        if t in _BLOCK_TAGS:
            self._flush(para=True)

    def handle_data(self, data):
        if self.skip_depth:
            return
        if self.in_head:
            self.head_buf.append(data)
            return
        self.cur += data

    def _flush(self, para):
        line = " ".join(self.cur.split())
        self.cur = ""
        if line:
            if self.gap and self.lines:
                self.lines.append("")
            self.lines.append(line)
            self.gap = para
        elif para:
            self.gap = True


def _html_to_text(html):
    p = _TextExtract()
    try:
        p.feed(html)
        p.close()
    except Exception:
        pass
    p._flush(para=False)
    return "\n".join(p.lines), p.chapters


def _xml_local(el):
    return el.tag.rsplit("}", 1)[-1]


def convert_epub_to_text(epub_path):
    """Extract the readable text of an EPUB (spine order) as UTF-8 text."""
    with zipfile.ZipFile(epub_path) as z:
        names = z.namelist()

        container_name = None
        for n in names:
            if n.lower().endswith("container.xml"):
                container_name = n
                break
        if container_name is None:
            raise ValueError("not an EPUB (no META-INF/container.xml)")

        root = ET.fromstring(z.read(container_name))
        opf_path = None
        for rf in root.iter():
            if _xml_local(rf) == "rootfile":
                opf_path = rf.get("full-path")
                if opf_path:
                    break
        if not opf_path:
            raise ValueError("no rootfile found in container.xml")

        opf = ET.fromstring(z.read(opf_path))

        manifest = {}
        spine = []
        for el in opf.iter():
            t = _xml_local(el)
            if t == "item":
                manifest[el.get("id") or ""] = (
                    (el.get("href") or "").lstrip("/"),
                    el.get("media-type") or "",
                    (el.get("properties") or "").split(),
                )
            elif t == "itemref":
                spine.append(el.get("idref") or "")

        base = posixpath.dirname(opf_path)
        docs = []
        chapters = 0
        seen = set()

        for idref in spine:
            href, mtype, props = manifest.get(idref, ("", "", []))
            if not href or mtype != "application/xhtml+xml":
                continue
            if "nav" in props:
                continue
            low = href.lower()
            if low.endswith(".ncx") or low.split("/")[-1].startswith(("nav", "toc")):
                continue
            full = posixpath.normpath(posixpath.join(base, href))
            if full.startswith("..") or full in seen or full not in names:
                continue
            seen.add(full)
            try:
                html = z.read(full).decode("utf-8", errors="replace")
            except Exception:
                continue
            text, cnt = _html_to_text(html)
            chapters += cnt
            if text.strip():
                docs.append(text)

        body = re.sub(r"[ \t]*\n[ \t]*\n[ \t]*\n+", "\n\n", "\n\n".join(docs))
        body = body.strip() + "\n"
        return body, chapters


def find_port():
    import glob
    mac_ports = glob.glob("/dev/cu.usbserial*") + glob.glob("/dev/cu.usbmodem*")
    if mac_ports:
        return mac_ports[0]

    for cand in ("/dev/ttyUSB0", "/dev/ttyUSB1", "/dev/ttyACM0"):
        if os.path.exists(cand):
            return cand
    return None


def open_ser(port):
    ser = serial.Serial(port, BAUD, timeout=1)
    ser.reset_input_buffer()
    time.sleep(0.3)

    ser.write(b"PALA:NOPE\n")
    ser.flush()
    time.sleep(0.4)
    ser.reset_input_buffer()
    return ser


def read_until(ser, prefixes, deadline):
    end = time.time() + deadline
    while time.time() < end:
        line = ser.readline().decode(errors="replace").strip()
        if not line:
            continue
        if any(line.startswith(p) for p in prefixes):
            return line
    return None


def reset_device(port):
    dev = serial.Serial(port, BAUD)
    dev.setRTS(True)   # EN -> LOW
    time.sleep(0.2)
    dev.setRTS(False)  # EN -> HIGH
    dev.close()


def run_with_wake(port, attempt):
    ser = open_ser(port)
    result = attempt(ser, fast=True)
    if result is not None:
        ser.close()
        return result
    ser.close()
    print("Reader is not answering (asleep?) - waking it over USB and retrying ...")
    reset_device(port)
    time.sleep(3.0)
    ser = open_ser(port)
    result = attempt(ser, fast=False)
    ser.close()
    if result is None:
        print("Reader still not responding. Check that it is plugged in.")
        return 1
    return result


def cmds():
    return {"upload", "del", "list", "info", "help"}


def main():
    # Signalverarbeitung für Flags (--list, --delete) & Subcommands
    parser = argparse.ArgumentParser(description="Pala USB Upload & Sync Tool", add_help=False)
    parser.add_argument("--list", action="store_true", help="List all books on device (raw list)")
    parser.add_argument("--delete", "--del", type=str, help="Delete book by name or number")
    parser.add_argument("--info", action="store_true", help="Show device info")
    parser.add_argument("--port", type=str, help="Override serial port")

    known_args, remaining = parser.parse_known_args()

    port = known_args.port or find_port()

    if known_args.list:
        if not port:
            return 2
        books = fetch_books(port)
        for b in books:
            print(b)
        return 0

    if known_args.delete:
        if not port:
            print("No serial port found.")
            return 2
        return delete_book(port, known_args.delete)

    if known_args.info:
        if not port:
            print("No serial port found.")
            return 2
        return info_device(port)

    # Legacy CLI / Subcommands Fallback
    if not remaining or remaining[0] in ("help", "-h", "--help"):
        print("pala - Pala One USB tool\n")
        print("Usage:")
        print("  pala <book.txt|book.epub>   Upload a book (EPUB is converted to text)")
        print("  pala list / pala --list    List all books on the reader")
        print("  pala del <name>            Delete a book by number or name")
        print("  pala info                  Show firmware version, battery, settings")
        return 0

    cmd = remaining[0]
    args = remaining[1:]

    if not port:
        print("No serial port found. Plug in the reader over USB and try again.")
        return 2

    if cmd == "list":
        return list_books(port)
    elif cmd == "del":
        if not args:
            print("Usage: pala del <name.txt>")
            return 2
        return delete_book(port, args[0])
    elif cmd == "info":
        return info_device(port)
    else:
        # Standard: Datei hochladen (erstes Argument ist der Pfad)
        return upload_book(port, cmd)


def upload_book(port, book):
    if not os.path.isfile(book):
        print(f"File not found: {book}")
        return 2

    name = os.path.basename(book)
    stream_path = book
    tmp_path = None

    if name.lower().endswith(".epub"):
        name = name[:-len(".epub")] + ".txt"
        print(f"Converting EPUB '{os.path.basename(book)}' ...")
        try:
            text, chapters = convert_epub_to_text(book)
        except Exception as e:
            print(f"Epub conversion failed: {e}")
            return 2
        if not text.strip():
            print("This EPUB contains no readable text.")
            return 2
        if chapters:
            print(f"  Found {chapters} chapter heading(s) - navigation will work.")
        fd, tmp_path = tempfile.mkstemp(prefix="pala_", suffix=".txt")
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
            f.write(text)
        stream_path = tmp_path

    size = os.path.getsize(stream_path)
    if size == 0:
        print("Book file is empty.")
        if tmp_path:
            os.unlink(tmp_path)
        return 2

    print(f"Uploading '{name}' ({size} bytes) to {port} ...")

    def attempt(ser, fast):
        ser.write(f"PALA:UP:{name}:{size}\n".encode())
        ser.flush()

        ok_line = read_until(ser, ("PALA:OK:", "PALA:ERR:"), deadline=(5 if fast else 180))
        if ok_line is None:
            return None
        print("<-", ok_line)
        if ok_line.startswith("PALA:ERR:"):
            reason = ok_line[len("PALA:ERR:"):]
            if reason.startswith("Already exists"):
                print(f"'{name}' already exists on the reader - nothing uploaded.")
            elif reason.startswith("Not enough space"):
                print("File is too large for the reader (not enough space).")
            elif reason.startswith("Library full"):
                print("The reader's library is full (80 books max).")
            elif reason.startswith("Cancelled"):
                print("Upload declined on the reader.")
            elif reason.startswith("Not found"):
                print(f"Device could not find file: {reason[len('Not found:'):]}")
            else:
                print(f"Upload rejected by device: {reason}")
            return 1

        sent = 0
        acked = 0
        last = 0
        last_activity = time.time()
        resync_off = None
        with open(stream_path, "rb") as photo:
            while sent < size:
                data = photo.read(CHUNK)
                if not data:
                    break
                ser.write(data)
                ser.flush()
                sent += len(data)

                while acked < sent:
                    if time.time() - last_activity > 30:
                        print(f"\nStall: device stopped after {acked}/{sent} bytes ({sent} sent).")
                        print("Is the reader busy (library/reader drawing)? Retry with the reader idle.")
                        return 1
                    line = ser.readline().decode(errors="replace").strip()
                    if not line:
                        continue
                    last_activity = time.time()
                    if line.startswith("PALA:ACK:"):
                        acked = int(line[len("PALA:ACK:"):])
                    elif line.startswith("PALA:RSYNC:"):
                        resync_off = int(line[len("PALA:RSYNC:"):])
                        break
                    elif line.startswith("PALA:ERR:"):
                        print("<-", line)
                        print("Upload failed.")
                        return 1

                if resync_off is not None:
                    if 0 <= resync_off <= sent:
                        if resync_off != sent:
                            print(f"  resync to {resync_off} ...")
                            photo.seek(resync_off)
                            sent = resync_off
                            acked = resync_off
                        ser.write(f"PALA:FROM:{resync_off}\n".encode())
                        ser.flush()
                    resync_off = None

                pct = acked * 100 // size
                if pct != last:
                    last = pct
                    print(f"  {pct:3d}%  ({acked}/{size} bytes)")

        result = read_until(ser, ("PALA:DONE:", "PALA:ERR:"), deadline=15)
        print("<-", result if result else "(timeout)")
        if result and result.startswith("PALA:DONE:"):
            print(f"\nDone. '{result[len('PALA:DONE:'):]}' is now on the device.")
            return 0
        print("Upload failed (timeout).")
        return 1

    try:
        return run_with_wake(port, attempt)
    finally:
        if tmp_path:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass


def delete_book(port, needle):
    target = needle
    if str(needle).isdigit():
        idx = int(needle)
        books = fetch_books(port)
        if idx < 1 or idx > len(books):
            print(f"No book with number {idx}. Run 'pala list' first.")
            return 1
        target = books[idx - 1]
        print(f"Deleting book #{idx}: '{target}' ...")
    else:
        print(f"Deleting book matching '{needle}' ...")

    if not target.endswith(".txt") and not target.endswith(".epub"):
        target += ".txt"

    def attempt(ser, fast):
        ser.write(f"PALA:DEL:{target}\n".encode())
        ser.flush()

        resp = read_until(ser, ("PALA:OKDEL:", "PALA:ERR:"), deadline=(5 if fast else 180))
        if resp is None:
            return None
        print("<-", resp)
        if resp.startswith("PALA:OKDEL:"):
            print(f"Deleted '{resp[len('PALA:OKDEL:'):]}'.")
            return 0
        if resp.startswith("PALA:ERR:Cancelled"):
            print("Delete declined on the reader.")
            return 1
        print(f"Not found on device: {target}")
        return 1

    return run_with_wake(port, attempt)


def fetch_books(port):
    """Return list of book names as reported by the device."""
    def attempt(ser, fast):
        ser.write(b"PALA:LIST\n")
        ser.flush()
        books = []
        deadline = time.time() + (6 if fast else 15)
        while time.time() < deadline:
            line = ser.readline().decode(errors="replace").strip()
            if not line:
                continue
            if line.startswith("PALA:BOOK:"):
                books.append(line[len("PALA:BOOK:"):])
            elif line.startswith("PALA:LISTEND:"):
                n = int(line[len("PALA:LISTEND:"):])
                return books[:n]
        return None
    return run_with_wake(port, attempt)


def info_device(port):
    def attempt(ser, fast):
        ser.write(b"PALA:INFO\n")
        ser.flush()
        line = read_until(ser, ("PALA:INFO:",), deadline=(6 if fast else 15))
        if line is None:
            return None
        fields = {}
        for kv in line[len("PALA:INFO:"):].split(";"):
            if "=" in kv:
                k, v = kv.split("=", 1)
                fields[k] = v
        print(f"Firmware:        {fields.get('firmware', '?')}")
        batt_ok = "ok" if fields.get("battery_valid") == "1" else "n/a"
        print(f"Battery:         {fields.get('percent', '?')}%  ({fields.get('voltage', '?')} V)  [{batt_ok}]")
        print(f"Sleep timeout:   {fields.get('sleep_secs', '?')} s")
        print(f"Books on device: {fields.get('books', '?')}")
        try:
            free = int(fields.get("free", 0)) // 1024
            total = int(fields.get("total", 0)) // 1024
            print(f"Flash free:      {free} KB of {total} KB")
        except ValueError:
            pass
        return 0
    return run_with_wake(port, attempt)


def list_books(port):
    books = fetch_books(port)
    if not books:
        print("No books on the device.")
        return 0
    print(f"Books on the device ({len(books)}):")
    for i, b in enumerate(books, 1):
        print(f"  {i:2d}. {b}")
    return 0

def download_book(port, remote_path, local_save_path):
    """Liest eine Datei (z. B. /.zitate_log.txt) per USB-Serial direkt vom Pala aus."""
    def attempt(ser, fast):
        ser.write(f"PALA:READ:{remote_path}\n".encode())
        ser.flush()

        lines = []
        started = False
        deadline = time.time() + (5 if fast else 15)

        while time.time() < deadline:
            line = ser.readline().decode("utf-8", errors="ignore")
            if not line:
                continue
            line_str = line.strip()
            if "PALA:READ:START" in line_str:
                started = True
                continue
            if "PALA:READ:END" in line_str:
                break
            if started:
                lines.append(line)

        if lines:
            with open(local_save_path, "w", encoding="utf-8") as f:
                f.writelines(lines)
            return True
        return None

    res = run_with_wake(port, attempt)
    return True if res is True else False

if __name__ == "__main__":
    sys.exit(main())