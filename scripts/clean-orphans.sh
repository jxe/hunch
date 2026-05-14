#!/bin/zsh
# scripts/clean-orphans.sh
#
# Wipe orphan Hunch app bundles with the legacy bundle id
# `com.joeedelman.console` and refresh LaunchServices so it stops registering
# them. Safe to run standalone or as a prelude to scripts/run.sh.
#
# Why this exists: pre-rename builds used `com.joeedelman.console`. Bundles
# from those builds (and from an old `Console` Xcode scheme) accumulate in
# DerivedData. macOS LaunchServices keeps the bundle-id → path mapping in a
# database keyed on the binary's CFBundleIdentifier, which means tools that
# resolve "Hunch" by display name can still land on a legacy bundle even
# after the rename — Claude's computer-use accessibility grant store was the
# canonical instance of this. The fix is to remove every macOS .app on disk
# whose Info.plist says `com.joeedelman.console` and rebuild LS's index.

set -euo pipefail

LEGACY_BUNDLE_ID="com.joeedelman.console"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

# `mdfind` is the cheapest way to enumerate registered .app bundles by
# bundle id. iOS .app bundles in Debug-iphoneos/Debug-iphonesimulator also
# match — those can't launch on macOS so they're harmless, but we delete
# them too for consistency (and to keep DerivedData smaller).
found=("${(@f)$(mdfind "kMDItemCFBundleIdentifier == '$LEGACY_BUNDLE_ID'" 2>/dev/null)}")

if [[ ${#found[@]} -eq 0 || ( ${#found[@]} -eq 1 && -z "${found[1]}" ) ]]; then
  echo "no $LEGACY_BUNDLE_ID bundles on disk"
else
  echo "removing ${#found[@]} $LEGACY_BUNDLE_ID bundle(s):"
  for path in "${found[@]}"; do
    [[ -n "$path" ]] || continue
    echo "  rm -rf $path"
    rm -rf "$path"
  done
fi

# Rebuild the LaunchServices database. Stale entries pointing at paths we
# just removed (or that were already missing) get dropped on this pass.
# `-r` walks the standard domains; `-kill` would be more thorough but was
# removed in recent macOS as "dangerous and no longer useful".
"$LSREGISTER" -r -domain local -domain system -domain user >/dev/null 2>&1 || {
  echo "warning: lsregister rebuild returned non-zero; continuing" >&2
}

# Final verification — if any registrations survive, list them so the user
# can decide whether to unregister manually. They'll be paths LS still knows
# about but that don't exist anymore (LS prunes lazily).
remaining=("${(@f)$(mdfind "kMDItemCFBundleIdentifier == '$LEGACY_BUNDLE_ID'" 2>/dev/null)}")
if [[ ${#remaining[@]} -gt 0 && -n "${remaining[1]}" ]]; then
  echo "warning: $LEGACY_BUNDLE_ID still resolves to: ${remaining[1]}" >&2
fi

echo "done"
