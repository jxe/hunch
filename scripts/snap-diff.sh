#!/bin/zsh
# scripts/snap-diff.sh <fixture-name>
#
# Captures the Hunch window via screencapture (needs Screen Recording
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
find_window_id() {
swift - <<'SWIFT'
import AppKit
import CoreGraphics
let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] ?? []
for w in info {
    if let owner = w["kCGWindowOwnerName"] as? String, owner == "Hunch",
       let num = w["kCGWindowNumber"] as? Int {
        print(num)
        exit(0)
    }
}
SWIFT
}

window_id=""
for _ in {1..20}; do
  window_id="$(find_window_id)"
  if [[ -n "$window_id" ]]; then
    break
  fi
  sleep 0.5
done

if [[ -z "$window_id" ]]; then
  echo "Hunch isn't running. launch with ./scripts/use-fixture.sh $name first." >&2
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

pixel_width="$(sips -g pixelWidth "$shot" 2>/dev/null | awk '/pixelWidth/ { print $2 }')"
pixel_height="$(sips -g pixelHeight "$shot" 2>/dev/null | awk '/pixelHeight/ { print $2 }')"

compare_args=(
  "$shot"
  "$repo_root/References/typography/$ref"
  --out "$diff"
)

# Large captures come from the full app layout with the Pages sidebar visible.
# Crop out the sidebar (~230pt logical = 460px on a 2x retina display) and the
# top toolbar (~50pt = 100px). For narrower windows, fall back to auto-detecting
# the content column; a fixed crop would cut away most of the page.
if [[ -n "$pixel_width" && -n "$pixel_height" && "$pixel_width" -ge 2400 && "$pixel_height" -ge 2000 ]]; then
  compare_args+=(--screenshot-region 460 100 2400 2000)
fi

python3 "$repo_root/scripts/compare-typography.py" "${compare_args[@]}"

echo
echo "diff: $diff"
echo "open with:  open '$diff'"
