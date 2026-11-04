# Pala Sync (Mac-App)

Kleine Menüleisten-App, die einen Ordner (z. B. in pCloud Drive) mit dem Pala One synchronisiert. Unter der Haube läuft dasselbe Python-Skript wie bisher (`tools/sync_books.py`). Es ist in die App eingebaut, du musst also kein Python installieren.

## Installation
1. Bei GitHub unter **Actions → Mac App** den neuesten erfolgreichen Lauf öffnen und unten das Artefakt **Pala-Sync** laden. Das Artefakt ist eine ZIP-Datei, in der eine zweite ZIP liegt. Beide entpacken.
2. `Pala Sync.app` nach **Programme** ziehen. Von dort funktioniert auch „Beim Anmelden starten“ zuverlässig.
3. Erster Start: Die App ist nicht von Apple notariell beglaubigt. Doppelklick → macOS blockiert. Dann **Systemeinstellungen → Datenschutz & Sicherheit → „Trotzdem öffnen“**. Das ist nur einmal pro Mac nötig.
   Alternativ im Terminal: `xattr -dr com.apple.quarantine "/Applications/Pala Sync.app"`

## Bedienung
- Das Buch-Symbol in der Menüleiste zeigt den Status. Ein gefülltes Buch heißt: Pala ist verbunden.
- **Automatisch beim Anstecken**: Sobald der Pala per USB erkannt wird, startet der Sync.
- **Jetzt synchronisieren** startet den Sync von Hand.
- **Sync-Ordner wählen …**: Ist `~/pCloud Drive/books-articles` vorhanden, wird dieser Ordner automatisch genommen.
- **Protokoll anzeigen**: Fortschritt und vollständige Ausgabe. Das Protokoll liegt zusätzlich unter `~/Library/Logs/PalaSync.log`.

Der Sync-Status (`.pala_state.json`) liegt im Sync-Ordner. Dadurch sehen alle Macs denselben Stand. Den alten Status aus `tools/` übernimmt der Sync beim ersten Mal automatisch.

## Selbst bauen (optional)
```bash
python3 -m pip install pyinstaller pyserial
./mac/build_app.sh        # -> mac/build/Pala-Sync.zip
```
