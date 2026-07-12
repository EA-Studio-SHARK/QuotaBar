#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build_app.sh"

DEST="$HOME/Applications"
mkdir -p "$DEST"
rm -rf "$DEST/QuotaBar.app"
cp -R "$ROOT/dist/QuotaBar.app" "$DEST/QuotaBar.app"

# Stop every old instance (open + LaunchAgent can leave two)
pkill -x QuotaBar 2>/dev/null || true
sleep 0.5
pkill -x QuotaBar 2>/dev/null || true
sleep 0.2
open "$DEST/QuotaBar.app"

echo "==> Installed to $DEST/QuotaBar.app and launched"
echo "    Look for the gauge icon in the macOS menu bar."
