#!/bin/zsh
# scripts/run.sh
#
# Kill any running Hunch.app and launch the most recently built one. Picks the newest
# binary mtime across DerivedData folders (multiple sessions / Xcode runs can leave stale
# Hunch-* directories — `ls -t` on the .app directory itself doesn't always pick the
# right one because the directory's mtime lags behind its contents).

set -euo pipefail

binary="$(ls -t ~/Library/Developer/Xcode/DerivedData/Hunch-*/Build/Products/Debug/Hunch.app/Contents/MacOS/Hunch 2>/dev/null | head -1)"
if [[ -z "$binary" ]]; then
  echo "no built Hunch.app found — run xcodebuild first" >&2
  exit 1
fi

app="$(dirname "$(dirname "$(dirname "$binary")")")"

# Kill by bundle id so we catch both DerivedData and ~/Applications copies.
pkill -f "com.joeedelman.console" 2>/dev/null || true
pkill -x Hunch 2>/dev/null || true
sleep 0.3

open "$app"
echo "launched $app"
