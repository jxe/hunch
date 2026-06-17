#!/bin/zsh
# scripts/run.sh
#
# Kill any running Hunch.app and launch ~/Applications/Hunch.app. The bundle
# there is kept in sync by the Hunch target's "Install to ~/Applications" build
# phase (see project.yml), which fires after every macOS build — Xcode Run,
# `xcodebuild build`, or anything else that triggers the target. So this script
# only needs to handle Gatekeeper and process management, not installation.

set -euo pipefail

script_dir="${0:A:h}"

installed="$HOME/Applications/Hunch.app"
if [[ ! -d "$installed" ]]; then
  echo "no $installed — build the macOS target first (xcodebuild ... build, or Xcode Run)" >&2
  exit 1
fi

# Purge stale pre-rename bundles and rebuild the LaunchServices index.
# Without this, tools that resolve "Hunch" by display name (Spotlight,
# accessibility grants, `open -b`) can land on an old DerivedData build
# instead of the current app. Cheap to run unconditionally (~0.15s);
# script is also invocable standalone.
"$script_dir/clean-orphans.sh"

# Kill any running copy before relaunching.
pkill -x Hunch 2>/dev/null || true
sleep 0.3

# Strip the Apple Development signature and re-sign ad-hoc.
# Xcode auto-signs builds with an Apple Development cert (project.yml says
# CODE_SIGNING_ALLOWED: YES with automatic signing). AppleSystemPolicy on
# macOS 14+ rejects Development-signed apps launched outside an Xcode debug
# session — surfaces as launchd's POSIX 163 spawn failure. Re-signing ad-hoc
# tells AMFI "this is a local build, not a distribution attempt" and lets it
# through. Xcode's next build re-stamps its own signature, so this is fully
# reversible. The dylibs alongside Hunch (Hunch.debug.dylib, __preview.dylib)
# are load-bearing — the main binary @rpath-loads the debug dylib — so we
# re-sign in place rather than stripping anything.
for dylib in "$installed"/Contents/MacOS/*.dylib; do
  [[ -e "$dylib" ]] || continue
  codesign --force --sign - "$dylib" >/dev/null 2>&1 || {
    echo "warning: ad-hoc re-sign of $dylib failed; launch may be blocked by Gatekeeper" >&2
  }
done
codesign --force --sign - "$installed" >/dev/null 2>&1 || {
  echo "warning: ad-hoc re-sign of $installed failed; launch may be blocked by Gatekeeper" >&2
}

open "$installed"
echo "launched $installed"
