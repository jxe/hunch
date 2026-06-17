#!/bin/zsh
# scripts/run-ios.sh
#
# Reinstall and launch the most recently built Hunch.app on a booted iOS
# Simulator. Mirrors run.sh (macOS): assumes you've already built — typically
# via Xcode (Cmd-B) or:
#
#   xcodebuild -project Hunch.xcodeproj -scheme Hunch \
#     -destination 'generic/platform=iOS Simulator' -configuration Debug build
#
# If no simulator is booted, boots the first available iPhone and brings the
# Simulator window to the front.

set -euo pipefail

bundle_id="org.nxhx.Hunch"

# Pick the newest built simulator .app — same trick as run.sh: timestamp the
# binary, not the .app directory (the directory mtime lags its contents).
binary="$(ls -t ~/Library/Developer/Xcode/DerivedData/Hunch-*/Build/Products/Debug-iphonesimulator/Hunch.app/Hunch 2>/dev/null | head -1)"
if [[ -z "$binary" ]]; then
  echo "no built Hunch.app for iphonesimulator found — build for an iOS Simulator destination first" >&2
  exit 1
fi
app="$(dirname "$binary")"

# Find a booted sim, or boot the first available iPhone.
sim_id="$(xcrun simctl list devices booted -j | /usr/bin/python3 -c '
import json, sys
data = json.load(sys.stdin)
for runtime, devices in data["devices"].items():
    for d in devices:
        if d.get("state") == "Booted" and "iPhone" in d.get("name", ""):
            print(d["udid"]); sys.exit(0)
')"

if [[ -z "$sim_id" ]]; then
  sim_id="$(xcrun simctl list devices available -j | /usr/bin/python3 -c '
import json, sys
data = json.load(sys.stdin)
# Prefer the newest iOS runtime, newest iPhone within it.
runtimes = sorted(data["devices"].keys(), reverse=True)
for runtime in runtimes:
    if "iOS" not in runtime: continue
    iphones = [d for d in data["devices"][runtime] if "iPhone" in d.get("name", "") and d.get("isAvailable", True)]
    if iphones:
        print(iphones[0]["udid"]); sys.exit(0)
')"
  if [[ -z "$sim_id" ]]; then
    echo "no available iPhone simulator found" >&2
    exit 1
  fi
  echo "booting simulator $sim_id"
  xcrun simctl boot "$sim_id"
fi

open -a Simulator

# Terminate any previous instance, then install + launch.
xcrun simctl terminate "$sim_id" "$bundle_id" 2>/dev/null || true
xcrun simctl install "$sim_id" "$app"
xcrun simctl launch "$sim_id" "$bundle_id" >/dev/null
echo "launched $app on $sim_id"
