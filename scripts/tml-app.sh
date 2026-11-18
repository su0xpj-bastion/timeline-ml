#!/bin/sh
# Run `tml` as its own app (TimelineML.app), so macOS asks for speech permission on its behalf.
# A bare CLI inherits its launcher's privacy identity (Terminal, an IDE, an agent host); when that
# app lacks NSSpeechRecognitionUsageDescription, TCC kills the request (seen: SIGABRT,
# namespace TCC). Usage: scripts/tml-app.sh authorize | run [gate...] [--json]
set -e
cd "$(dirname "$0")/.."
B=${BUILD_DIR:-.build/local}
APP="$B/TimelineML.app"
mkdir -p "$APP/Contents/MacOS"
cp "$B/tml" "$APP/Contents/MacOS/tml"
cp Sources/tml/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string tml" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$APP/Contents/Info.plist" 2>/dev/null || true
codesign --force --sign - "$APP" >/dev/null 2>&1
OUT="$B/tml-app.out"
: > "$OUT"
open -W -n --stdout "$OUT" --stderr "$OUT" "$APP" --args "$@"
cat "$OUT"
