#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> Building QuotaBar (release)"
swift build -c release

BIN="$ROOT/.build/release/QuotaBar"
APP="$ROOT/dist/QuotaBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/QuotaBar"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"

# Ad-hoc sign so Keychain / notifications prompts work better
if command -v codesign >/dev/null; then
  codesign --force --deep --sign - "$APP" 2>/dev/null || true
fi

echo "==> Built $APP"
echo "    Run: open \"$APP\""
