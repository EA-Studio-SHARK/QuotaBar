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
cp "$ROOT/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/orbit-panel/orbit-icon.png" "$APP/Contents/Resources/orbit-icon.png"
cp "$ROOT/orbit-panel/notch.html" "$APP/Contents/Resources/notch.html"
cp "$ROOT/orbit-panel/app.html" "$APP/Contents/Resources/app.html"
mkdir -p "$APP/Contents/Resources/clawd" && cp "$ROOT"/orbit-panel/clawd/*.svg "$APP/Contents/Resources/clawd/"
mkdir -p "$APP/Contents/Resources/icons" && cp "$ROOT"/orbit-panel/icons/* "$APP/Contents/Resources/icons/"

# Prefer a stable development identity: ad-hoc signatures change their identity
# with every build and macOS then rejects previously granted data access.
if command -v codesign >/dev/null; then
  SIGNING_IDENTITY="${QUOTABAR_SIGNING_IDENTITY:--}"
  if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    VALID_IDENTITIES="$(security find-identity -v -p codesigning | awk '/"Apple Development:/ {print $2}')"
    IDENTITY_COUNT="$(printf '%s\n' "$VALID_IDENTITIES" | awk 'NF {n++} END {print n+0}')"
    if [[ "$IDENTITY_COUNT" == "1" ]]; then
      SIGNING_IDENTITY="$VALID_IDENTITIES"
    fi
  fi
  codesign --force --deep --timestamp=none --sign "$SIGNING_IDENTITY" "$APP"
  codesign --verify --deep "$APP"
fi

echo "==> Built $APP"
echo "    Run: open \"$APP\""
