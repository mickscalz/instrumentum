#!/bin/bash
# Builds "In Strum Meants.app" for Intel Macs (macOS 13+) and zips it.
# Usage: Scripts/make-app.sh <build-number>
set -euo pipefail
BUILD="${1:?build number required}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/In Strum Meants.app"
ZIP="$ROOT/dist/In-Strum-Meants-build-$BUILD.zip"

cd "$ROOT"
swift build -c release --arch x86_64 --product InStrumMeants
BIN="$(swift build -c release --arch x86_64 --show-bin-path)/InStrumMeants"

rm -rf "$ROOT/dist"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/InStrumMeants"
# Sparkle (the in-app updater) rides in Contents/Frameworks; SwiftPM leaves it next to the binary, or in its artifacts.
BINDIR="$(dirname "$BIN")"
SPARKLE="$BINDIR/Sparkle.framework"
[ -d "$SPARKLE" ] || SPARKLE="$(find "$ROOT/.build/artifacts" -type d -name Sparkle.framework -path "*macos*" | head -n 1)"
test -d "$SPARKLE" || { echo "Sparkle.framework not found"; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/InStrumMeants" 2>/dev/null || true
sed "s/__BUILD__/$BUILD/g" "$ROOT/Packaging/Info.plist" > "$APP/Contents/Info.plist"
"$ROOT/Scripts/make-icon.sh" "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep -s - "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "$ZIP"
