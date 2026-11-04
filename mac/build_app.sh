#!/bin/bash
# Builds "Pala Sync.app" (SwiftUI menu bar app + bundled Python sync).
# Requires: macOS 13+, Xcode command line tools, python3 with
#           pyinstaller and pyserial installed.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
OUT="build"
APP="$OUT/Pala Sync.app"
ARCH="${ARCH:-arm64}"

rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> Swift app ($ARCH)"
swift build -c release --arch "$ARCH"
BIN="$(swift build -c release --arch "$ARCH" --show-bin-path)/PalaSync"

echo "==> Python sync (PyInstaller)"
python3 -m PyInstaller --noconfirm --clean --onedir --name pala-sync \
  --distpath "$OUT/py" --workpath "$OUT/pywork" --specpath "$OUT" \
  --paths "$ROOT/tools" --hidden-import serial --hidden-import serial.tools.list_ports \
  "$ROOT/tools/sync_books.py"

echo "==> Assemble bundle"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PalaSync"
sed "s/__BUILD__/${BUILD_NUMBER:-1}/" Info.plist > "$APP/Contents/Info.plist"
cp -R "$OUT/py/pala-sync" "$APP/Contents/Resources/pala-sync"

echo "==> Ad-hoc signing"
# Sign every Mach-O inside the bundled Python first, then the app itself.
find "$APP/Contents/Resources" -type f | while read -r f; do
  if file "$f" | grep -q "Mach-O"; then
    codesign --force --sign - "$f"
  fi
done
codesign --force --sign - "$APP"
codesign --verify --verbose "$APP"

echo "==> Zip"
ditto -c -k --keepParent "$APP" "$OUT/Pala-Sync.zip"
echo "Built $OUT/Pala-Sync.zip"
