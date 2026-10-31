#!/bin/zsh

echo "=========================================="
echo "   Pala One - Ordner-Spiegelung (Sync)"
echo "=========================================="
echo ""

cd "$HOME/pCloud Drive/pala-usb-tool/tools"
"$HOME/.platformio/penv/bin/python" sync_books.py

sleep 3
