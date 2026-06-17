# TODO

Unordered list of work that seems in scope.

## Small ones

* Drop target feel on ios as you drag is not ideal.
* The disclosure triangles on toggle lists are not equilateral.
* I have mixed feelings about the way that sections act as blocks.
* I guess we should add "comes after" sibling info to the logs to make it easier to reconstruct the right tree structure when we have edit conflicts.
* Maybe instead of n device logs per file, we should have n device logs per clamshell directory?
* iOS swipe actions could go full-bleed

## Larger

## Classified-list primitive

A "poor man's database" — a bulleted list whose rows carry trailing
chips from a controlled vocabulary defined inside the same container.
Full design (model, fence syntax, parser/serializer, normalization
rules, risks) in
[docs/classified-list-primitive.md](docs/classified-list-primitive.md).

v1 scope: add/edit/remove tags only — no filter/sort/group views.

---

## iOS multi-select gesture

The swipe that currently triggers indent should instead enter selection
mode, where tapping a row adds/removes it from the selection. A
floating toolbar at the bottom would expose bulk actions (delete,
indent, outdent, Turn-into to convert several blocks at once or fold an
indented list into a toggle).

---

## Page containment tracking

Each page could know its ancestors: when you `@`-mention a page, it
gets added as a parent. That enables Notion-style containment semantics
for deletes and restores (deleting a page deletes its descendants by
default; restore brings the subtree back).

---

## Full-text search

`Cmd+P` is title-only today. Add an indexed full-text path across page
bodies — small enough to live in memory, rebuilt on rescan.

---

## On-device transcript cleanup

Pipe `SFSpeechRecognizer` output through an on-device model (or tune
the recognizer settings) to drop the spurious punctuation and filler
that show up in the raw transcript. Most useful for long voice-capture
sessions.

---

## Color (text + style-tag backgrounds)

Inline text color and configurable backgrounds for style-tag chips.
Lower priority — wait until the classified-list / chip story has
settled.

---

## Notion-typography pixel matching

Screenshot diff vs. each reference in `References/typography/` should
be visually indistinguishable at 1× and 2×. Still uncertain:
heading-to-heading and heading-to-paragraph margins; quote / code /
divider / toggle / subpage spacing; inline H1 and H3 values (derived
from `em` math, not measured). Iteration loop:

```sh
./scripts/use-fixture.sh <name>
xcodebuild -project Hunch.xcodeproj -scheme Hunch \
    -destination 'platform=macOS' -configuration Debug build
./scripts/snap-diff.sh <name>
open /tmp/console-screenshots/<name>-diff.png
```

Fixtures with Notion references: `rfc_prompt`, `notion_page_example`,
`blog_post_draft`, `ai_for_docs`. Capture-only: `headings_and_bullets`.

Only touch
[Packages/Editor/Sources/Editor/NotionStyle.swift](Packages/Editor/Sources/Editor/NotionStyle.swift)
(both the `NotionStyle` enum and the `BlockSpacing` enum) unless the
renderer has a real bug. Don't add magic numbers to
[BlockRow.swift](Packages/Editor/Sources/Editor/BlockRow.swift).

The `console-` prefixes in `/tmp/console-fixture/` and
`/tmp/console-screenshots/` are residual — fine to leave but can be
renamed when convenient.
