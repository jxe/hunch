#!/bin/zsh
# scripts/use-fixture.sh <fixture-name>
#
# Copies References/typography/fixtures/<name>.md → /tmp/console-fixture/everything.md
# and relaunches Hunch with `--workspace /tmp/console-fixture`, which overrides
# the user's saved workspace bookmark for that process only and opens the
# fixture directly without any clicks. The app's `installLaunchArgWorkspace`
# handles the `--workspace` flag in `Workspace.tryRestore`.
#
# Usage: ./scripts/use-fixture.sh rfc_prompt
#        ./scripts/use-fixture.sh notion_page_example
#        ./scripts/use-fixture.sh blog_post_draft
#        ./scripts/use-fixture.sh ai_for_docs

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <fixture-name>"
  echo "available:"
  ls "$(dirname "$0")/../References/typography/fixtures/" | sed 's/\.md$//' | sed 's/^/  /'
  exit 1
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
src="$repo_root/References/typography/fixtures/$1.md"

if [[ ! -f "$src" ]]; then
  echo "no such fixture: $src"
  exit 1
fi

mkdir -p /tmp/console-fixture
cp "$src" /tmp/console-fixture/everything.md
echo "fixture: $1"

# Relaunch the most recently built Hunch.app with the fixture workspace.
pkill -x Hunch 2>/dev/null || true
sleep 1
app="$(ls -td ~/Library/Developer/Xcode/DerivedData/Hunch-*/Build/Products/Debug/Hunch.app 2>/dev/null | head -1)"
if [[ -z "$app" ]]; then
  echo "no built Hunch.app found — run xcodebuild first"
  exit 1
fi
open "$app" --args --workspace /tmp/console-fixture
