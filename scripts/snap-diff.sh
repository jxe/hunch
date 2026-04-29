#!/bin/zsh
# scripts/snap-diff.sh <fixture-name>
#
# Captures the Console window via screencapture (needs Screen Recording
# permission for whichever process invoked us — usually the terminal),
# maps <fixture-name> to its reference image, and runs the typography
# diff tool. Prints the diff PNG path so you can `open` it in Preview.
#
# Usage: ./scripts/snap-diff.sh rfc_prompt
#
# Mapping (kept in sync with References/typography/README.md):
#   rfc_prompt           → notion_prompt_example.png
#   notion_page_example  → notion_example_page_formatting.jpg
#   blog_post_draft      → notion_full_width_page.png
#   ai_for_docs          → notion_ai_for_docs.webp

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <fixture-name>" >&2
  exit 1
fi

name="$1"
case "$name" in
  rfc_prompt)            ref="notion_prompt_example.png" ;;
  notion_page_example)   ref="notion_example_page_formatting.jpg" ;;
  blog_post_draft)       ref="notion_full_width_page.png" ;;
  ai_for_docs)           ref="notion_ai_for_docs.webp" ;;
  headings_and_bullets)  ref="" ;;   # no Notion reference yet — capture-only
  *) echo "unknown fixture: $name" >&2; exit 1 ;;
esac

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
out_dir="/tmp/console-screenshots"
mkdir -p "$out_dir"

# Capture by window ID via CGWindowListCopyWindowInfo so overlapping
# windows (Claude chat panel, etc.) don't appear in the screenshot.
window_id="$(swift - <<'SWIFT'
import AppKit
import CoreGraphics
let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] ?? []
for w in info {
    if let owner = w["kCGWindowOwnerName"] as? String, owner == "Console",
       let num = w["kCGWindowNumber"] as? Int {
        print(num)
        exit(0)
    }
}
SWIFT
)"

if [[ -z "$window_id" ]]; then
  echo "Console isn't running. launch with ./scripts/use-fixture.sh $name first." >&2
  exit 1
fi

shot="$out_dir/$name-current.png"
diff="$out_dir/$name-diff.png"

screencapture -l "$window_id" -x "$shot"
echo "captured: $shot (window $window_id)"

if [[ -z "$ref" ]]; then
  echo
  echo "no Notion reference for '$name' yet — capture-only."
  echo "open with:  open '$shot'"
  exit 0
fi

# Crop out the Pages sidebar (~230pt logical = 460px on a 2x retina display)
# and the top toolbar (~50pt = 100px). The diff tool only sees page content.
python3 "$repo_root/scripts/compare-typography.py" \
  "$shot" \
  "$repo_root/References/typography/$ref" \
  --screenshot-region 460 100 2400 2000 \
  --out "$diff"

echo
echo "diff: $diff"
echo "open with:  open '$diff'"
