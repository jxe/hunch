# Pixel-Correct Notion Typography

## Goal

Screenshot diff vs each reference should be visually indistinguishable at
1x and 2x. The target is pre-March-2026 Notion; screenshots in
`References/typography/` are the source of truth, not `react-notion-x`
CSS.

## Still Uncertain

- Heading-to-heading and heading-to-paragraph margins.
- Quote, code, divider, toggle, and subpage spacing.
- Inline H1 and H3 values are derived from `em` math, not measured.

## Iteration Loop

```sh
./scripts/use-fixture.sh <name>
xcodebuild -project Hunch.xcodeproj -scheme Hunch -destination 'platform=macOS' -configuration Debug build
./scripts/snap-diff.sh <name>
open /tmp/console-screenshots/<name>-diff.png
```

(The `console-` prefixes in `/tmp/console-fixture/` and
`/tmp/console-screenshots/` predate the rename and are kept for compat.)

Fixtures with Notion references: `rfc_prompt`, `notion_page_example`,
`blog_post_draft`, `ai_for_docs`.

Capture-only fixture: `headings_and_bullets`.

## Editing Rules

Only touch `Packages/Editor/Sources/Editor/NotionStyle.swift` (which
holds both the `NotionStyle` enum and the `BlockSpacing` enum) unless
the renderer has a real bug. Do not add magic numbers to
`Packages/Editor/Sources/Editor/BlockRow.swift`.

