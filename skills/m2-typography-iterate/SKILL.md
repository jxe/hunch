---
name: m2-typography-iterate
description: Use when the user is iterating on Notion-style typography in the Editor package — adjusting NotionStyle constants or the BlockSpacing enum (both in Packages/Editor/Sources/Editor/NotionStyle.swift) to match the pre-March-2026 Notion reference screenshots. Loop is: edit constants → rebuild → use-fixture → snap-diff → compare against References/typography/ → repeat.
---

# Pixel-correct Notion typography iteration

## When this fires

The user is tuning visible spacing, font sizes, line heights, heading weights,
or block margins in `Packages/Editor/Sources/Editor/NotionStyle.swift` (which
holds both the `NotionStyle` enum and the `BlockSpacing` enum), and wants to
verify the result against a real Notion reference shot. Not for non-typography
changes.

## Editing rules (load-bearing)

- Only edit `NotionStyle.swift`. No magic numbers in
  `Packages/Editor/Sources/Editor/BlockRow.swift`.
- Don't touch the markdown layer in `App/Sources/Clamshell/`. Parser /
  Serializer is the source of truth and `RoundTripTests` (in
  `App/Tests/HunchUnitTests/`) plus the SPM tests in
  `Packages/Editor/Tests/EditorTests/` gate any change.
- After every edit: `swift test --package-path Packages/Editor` — must stay
  green.

## The loop

1. **Pick a fixture that maps to a Notion screenshot.** Five fixtures live in
   `References/typography/fixtures/`:
   - `rfc_prompt` ↔ `notion_prompt_example.png`
   - `notion_page_example` ↔ `notion_example_page_formatting.jpg`
   - `blog_post_draft` ↔ `notion_full_width_page.png`
   - `ai_for_docs` ↔ `notion_ai_for_docs.webp`
   - `headings_and_bullets` (capture-only — no Notion reference, used for
     eyeballing transitions)

2. **Edit the constant.** Most useful constants:
   - `NotionStyle.bodyLineSpacing` — extra leading on body text (currently 5pt
     for 1.5em on 16pt Inter)
   - `NotionStyle.h1Size` / `h2Size` / `h3Size` — heading sizes
   - `NotionStyle.headingWeight` — confirmed `.bold` against all four refs
   - `BlockSpacing.topMargin(_:)` / `bottomMargin(_:)` — per-kind sibling
     margins (CSS-style margin-collapse computed in `gap(before:after:)`)
   - `BlockSpacing.intrinsicTopPadding(_:)` / `intrinsicBottomPadding(_:)` —
     padding inside the block's row frame. Asymmetric so headings can clip
     their oversized font line-leading on whichever side faces body text;
     negative values are allowed (they pull the row frame inside the font's
     built-in leading).

3. **Rebuild + relaunch with the fixture.**
   ```sh
   xcodebuild -project Hunch.xcodeproj -scheme Hunch \
     -destination 'platform=macOS' -configuration Debug build
   ./scripts/use-fixture.sh <fixture-name>
   ```
   The fixture script copies the markdown into `/tmp/console-fixture/everything.md`
   and relaunches Hunch. (The `console-` prefix in the temp path predates the
   rename; kept for compat.)

4. **Capture + diff.**
   ```sh
   ./scripts/snap-diff.sh <fixture-name>
   open /tmp/console-screenshots/<fixture-name>-diff.png
   ```
   For fixtures with a Notion reference, this produces a side-by-side PNG with
   the reference on the left and the Hunch screenshot on the right, scaled
   so body line-heights match. Red horizontal rules mark every detected
   text-band edge so misaligned gaps jump out.

5. **Read the diff overlay.** If body type, headings, or gaps don't sit at
   the same y-coordinate across the two halves, the relevant constant needs
   to move. Edit, rebuild, recapture.

## Tooling reference

- `scripts/use-fixture.sh <name>` — relaunches Hunch with that fixture.
- `scripts/snap-diff.sh <name>` — captures the Hunch window via
  `screencapture -l <window-id>` (overlapping windows don't show), runs
  `compare-typography.py` for a diff overlay.
- `scripts/compare-typography.py` — does the cropping, scaling, and band-rule
  overlay. Reference body line-heights are hardcoded in `REFERENCE_BODY_LH_PX`
  (all four measured, no guesses).
- `scripts/measure-typography.py` — projects ink onto the y-axis to detect
  text bands. Use with explicit `--xrange`/`--yrange` to isolate a multi-line
  body paragraph; auto-detected column on full-window shots picks up sidebar
  chrome and biases the estimate.

## What's verified vs. what's still uncertain

See `tasks/notion-typography.md`. Confirmed-correct constants are listed
with their measurement source. Quote, code, divider, toggle, and subpage
spacing are not yet verified against any reference — flag if you're
touching those.

## Stop signal

Don't move past M2 typography work until every fixture with a Notion
reference passes the diff overlay (no visible y-offset between halves on
body, headings, or block gaps).

## Out of scope

- **Inline code chip rendering** (round-corner backgrounds) is a separately
  tracked task. Inline code stays as flat-background until that lands.
