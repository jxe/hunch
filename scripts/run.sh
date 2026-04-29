#!/bin/zsh
# scripts/run.sh
#
# Kill any running Console.app and launch the most recently built one. Picks the newest
# binary mtime across DerivedData folders (multiple sessions / Xcode runs can leave stale
# Console-* directories — `ls -t` on the .app directory itself doesn't always pick the
# right one because the directory's mtime lags behind its contents).

set -euo pipefail

binary="$(ls -t ~/Library/Developer/Xcode/DerivedData/Console-*/Build/Products/Debug/Console.app/Contents/MacOS/Console 2>/dev/null | head -1)"
if [[ -z "$binary" ]]; then
  echo "no built Console.app found — run xcodebuild first" >&2
  exit 1
fi

app="$(dirname "$(dirname "$(dirname "$binary")")")"

pkill -9 -f "Console.app/Contents/MacOS/Console" 2>/dev/null || true
sleep 0.3

open "$app"
echo "launched $app"
