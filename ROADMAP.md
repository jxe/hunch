# Roadmap

What's left. The code (and `CLAUDE.md`) document _what was built_; this
file is for _what's left_.

## ✅ Done

- **M1** — Workspace + page list (read-only).
- **M3 + M4** — Per-block editing, autosave, multi-select keyboard model.
- **M5** — Markdown autotransforms (prefix triggers).
- **M6 (partial)** — macOS hardware-keyboard inline formatting:
  Cmd-B/I/E/Shift-S toggle bold/italic/code/strikethrough on the current
  selection; editor binding is `Binding<AttributedString>` so marks
  round-trip.

Carry-overs nibbling around the edges:
- Cross-block undo as a single op (split/merge/indent should coalesce).
- Backspace-at-0 merge into the previous non-empty row (currently no-op).
- Toggle-child editing inside the toggle.
- iOS verification of the M3+ keyboard model.

---

## 🟡 M2 — Pixel-correct Notion typography

**Goal:** screenshot diff vs each reference is visually indistinguishable
at 1× and 2×. Done when every `snap-diff` overlay reads as the same page
on both halves. The visual target is **pre-March-2026 Notion**; the four
reference screenshots in `References/typography/` are the source of
truth, *not* `react-notion-x`'s CSS.

**Still uncertain:**

- Heading→heading and heading→paragraph margins. Currently 28pt above an
  H2, 6pt below — guessed, not measured. Need a Notion reference shot
  with stacked headings.
- Quote, code, divider, toggle, subpage spacing. Untouched since
  `9b96acd`. No fixture exercises these yet.
- Inline H1 (30pt) and H3 (20pt) values are derived from `em` math, not
  measured. The `headings_and_bullets` fixture exercises both but lacks
  a Notion reference.

**Iteration loop:**

```sh
./scripts/use-fixture.sh <name>
xcodebuild -project Console.xcodeproj -scheme Console \
  -destination 'platform=macOS' -configuration Debug build
./scripts/snap-diff.sh <name>
open /tmp/console-screenshots/<name>-diff.png
```

Fixtures that mirror a Notion reference: `rfc_prompt`,
`notion_page_example`, `blog_post_draft`, `ai_for_docs`. Capture-only
(no Notion reference yet): `headings_and_bullets`.

Editing rules: only touch `NotionStyle.swift` and `BlockSpacing.swift`;
no magic numbers in `BlockRendering.swift`; don't touch `Packages/Core/`;
keep round-trip tests green.

---

## ⏳ M6 (rest)

- **iOS hardware keyboard.** Same Cmd-B/I/E/Shift-S shortcuts via iOS
  26's `AttributedTextSelection` and attribute-transform APIs. `Cmd-K`
  for link insertion.
- **Inline closing-trigger autotransforms** (lifted out of M5):
  `**bold**`, `*it*` / `_it_`, `` `code` ``, `~~strike~~`, `[text](url)`.
  Plug into `Autotransforms.swift` — now unblocked by the
  `AttributedString` flip.
- **Pre-typing toggles** — Cmd-B with no selection should bias
  `typingAttributes` so the next typed character is bold. Same for
  italic/code/strike.
- **iOS soft-keyboard accessory bar** via
  `.toolbar { ToolbarItemGroup(.keyboard) { … } }`:
  block-type chip → outdent/indent → bold/italic/code/strike → link →
  spacer → dismiss-keyboard (blurs and triggers an immediate save).
  macOS: no accessory bar — menu items only.

---

## ⏳ M7 — Gestures + drag handles

- **macOS hover-revealed drag handles per row.** Drag the handle to
  reorder. When the dragged row is part of the current multi-selection,
  the whole selection moves. PageView is a `VStack` inside a
  `ScrollView` (not a `List`), so this needs custom drag-and-drop —
  `.draggable` on the handle, `.dropDestination` between rows.
- **Drag a row by clicking outside the handle**, too — at least when the
  click would otherwise miss the editor (e.g. on the marker side).
- iOS swipes: left-to-delete with undo toast; right-to-cycle-indent.
- Long-press to drag-reorder on iOS (parallel to mac drag handles).
- **Pinch open between rows to insert** — custom UIGestureRecognizer /
  NSGestureRecognizer bridged via UIViewRepresentable. SwiftUI doesn't
  expose this gesture natively. Budget time; this is the signature
  gesture.
- **Pinch close** to zoom out to page list.
- Pull-down within a page → in-page search bar.
- Pull-down on page list → workspace file-name search.

**Done when:** every gesture works on iPad + iPhone; pinch-to-insert is
fluid (60fps, no jank when the keyboard appears).

---

## ⏳ M8 — Toggle and subpage editing

- Toggle children edit affordances (recursive renderer is read-only
  today).
- `.subpage(title, path)`: detect `[title](path.md)` paragraphs that
  resolve inside the workspace, render as a subpage row, push target on
  tap. Offer to create the file if missing.
- External-change detection via `NSFilePresenter` + foreground re-scan.

**Done when:** create a toggle, nest blocks inside, save, reopen — same
structure. Subpage navigation works; back returns to parent.

---

## Out of scope (v1)

Tables (parse, render plain), images (parse, render placeholder),
real-time collab, in-content workspace search, dark mode, web clipping,
AI features, cross-block selection, find-and-replace, PDF export.

## Spawned-task chips

When a follow-up surfaces during a milestone that would bloat the
current change, spawn it as a separate task:

- **Round-corner inline code chip rendering** — replace flat
  `.backgroundColor` with a custom `TextRenderer` that paints a 3pt
  rounded background per run.
