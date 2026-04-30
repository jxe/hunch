#!/bin/zsh
# scripts/use-fixture-ios.sh <fixture-name>
#
# iOS Simulator counterpart of use-fixture.sh.
#
# Copies References/typography/fixtures/<name>.md → the Hunch app sandbox
# at Documents/console-fixture/everything.md on the booted sim, then
# terminates and relaunches Hunch. The app's auto-open-last-page brings up
# the new content with no clicks (after a one-time workspace pick).
#
# One-time bootstrap (do this once per simulator):
#   1. Run scripts/run-ios.sh once.
#   2. Run scripts/use-fixture-ios.sh <fixture> — the fixture file is now on disk.
#   3. In the sim, the workspace picker appears. Pick the
#      `console-fixture` folder under On My iPhone → Console.
#   4. Done — every subsequent run-ios.sh + use-fixture-ios.sh pair launches
#      straight into the swapped fixture, no clicks.
#
# Usage: ./scripts/use-fixture-ios.sh rfc_prompt
#        ./scripts/use-fixture-ios.sh notion_page_example
#        ./scripts/use-fixture-ios.sh blog_post_draft
#        ./scripts/use-fixture-ios.sh ai_for_docs
#        ./scripts/use-fixture-ios.sh headings_and_bullets

set -euo pipefail

bundle_id="com.joeedelman.console"

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <fixture-name>"
  echo "available:"
  ls "$(dirname "$0")/../References/typography/fixtures/" | sed 's/\.md$//' | sed 's/^/  /'
  exit 1
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
src="$repo_root/References/typography/fixtures/$1.md"

if [[ ! -f "$src" ]]; then
  echo "no such fixture: $src" >&2
  exit 1
fi

# Resolve the booted simulator's app data container.
container="$(xcrun simctl get_app_container booted "$bundle_id" data 2>/dev/null || true)"
if [[ -z "$container" ]]; then
  echo "Hunch isn't installed on a booted simulator. Run scripts/run-ios.sh first." >&2
  exit 1
fi

dest_dir="$container/Documents/console-fixture"
mkdir -p "$dest_dir"
cp "$src" "$dest_dir/everything.md"
echo "fixture: $1 → $dest_dir/everything.md"

# Terminate + relaunch so the document store re-reads from disk.
xcrun simctl terminate booted "$bundle_id" 2>/dev/null || true
xcrun simctl launch booted "$bundle_id" >/dev/null
