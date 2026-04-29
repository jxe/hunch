# Roadmap

Eight-milestone build order from the original plan. Each milestone is
independently shippable; don't start the next until the current one passes
its "Done when" criterion. Where work has landed, the relevant commit is
linked.

## ✅ M1 — Workspace + page list (read-only) — DONE

Pick a workspace folder (`UIDocumentPickerViewController` /
`NSOpenPanel`), persist a security-scoped bookmark, scan recursively for
`.md` files, render each opened page from `swift-markdown` AST → `[Block]` →
SwiftUI views.

**Verified:** macOS app, fixture covering every block type
(paragraph/heading/bullet/numbered/todo/quote/code/divider/subpage/toggle,
including nested toggles and bullets to depth 3), all rendering correctly.

Commit `94937f0`.

## 🟡 M2 — Pixel-correct Notion typography — IN PROGRESS

The visual target is **pre-March-2026 Notion**. The four reference
screenshots in `References/typography/` are the source of truth — *not*
`react-notion-x`'s CSS, which doesn't match real Notion in subtle ways.

**Goal:** screenshot diff vs each reference is visually indistinguishable
at 1× and 2×. Done when every `snap-diff` overlay reads as the same page
on both halves.

### What's confirmed-correct

| constant | value | source |
|----------|-------|--------|
| Body font | Inter Variable, 16pt | confirmed against `notion_example_page_formatting.jpg` |
| Body lineSpacing | 5pt (→ 24pt baseline-to-baseline = 1.5em) | matches Notion's `line-height: 1.5` |
| Heading font weight | 700 (`.bold`) | all four references show heavy headings |
| Page-title H1 (first H1 in file) | 40pt bold | matches `.notion-page-title-text` and renders right against `rfc_prompt` reference |
| Inline H1 | 30pt bold | not visually verified — derived from `1.875em × 16` |
| H2 | 24pt bold | matches `1.5em × 16` and renders right against `rfc_prompt` reference |
| H3 | 20pt bold | not visually verified — derived from `1.25em × 16` |
| Numbered list sequential numbering | yes (`NumberingContext`) | now matches `notion_prompt_example.png` |
| List item intrinsic vertical padding | 5pt | a 5pt-vs-3pt-vs-6pt sweep against `rfc_prompt` landed on 5 |

### What's still uncertain

- Paragraph→paragraph gap. Currently 6pt top + 6pt bottom margin → ~21pt
  total visible gap. Looked OK in the rfc_prompt diff but only a single
  reference-pass — re-run against `notion_page_example` and `blog_post_draft`.
- Heading→heading and heading→paragraph margins. Currently 28pt above an
  H2, 6pt below — guessed, not measured.
- Quote, code, divider, toggle, subpage spacing. Untouched since
  `9b96acd` and not yet verified against any reference.
- Reference body line-heights. Only `notion_prompt_example.png` (43px)
  was actually measured; the other three values in
  `scripts/compare-typography.py:REFERENCE_BODY_LH_PX` are guesses. Open
  each reference image in Preview, measure body baseline-to-baseline,
  and replace the guess. Until you do that the side-by-side diff for
  those references will be at the wrong scale.
- Inline code chip rendering. **Out of scope** for M2 — see "Spawned-task
  chips" below for the round-corner refactor that owns it.

### Iteration loop

Tooling shipped in this milestone (`ec3f0a0`, `59a2407`):

- `References/typography/fixtures/<name>.md` — checked-in markdown that
  mirrors a reference screenshot. Currently four: `rfc_prompt`,
  `notion_page_example`, `blog_post_draft`, `ai_for_docs`.
- `scripts/use-fixture.sh <name>` — copies the fixture into
  `/tmp/console-fixture/everything.md` and relaunches Console. The app
  auto-restores `console.lastOpenPage` on launch, so no clicks needed.
- `scripts/snap-diff.sh <name>` — captures the Console window via
  `screencapture -l <window-id>` (so overlapping windows don't show up),
  then runs `compare-typography.py` to produce a side-by-side PNG with
  the reference on the left and the screenshot scaled so its body
  line-height matches. The output lands in `/tmp/console-screenshots/<name>-diff.png`.
- `scripts/compare-typography.py` — does the cropping + scaling. Body
  line-heights are hardcoded per reference (see `REFERENCE_BODY_LH_PX`).

```sh
./scripts/use-fixture.sh rfc_prompt           # → notion_prompt_example.png
./scripts/use-fixture.sh notion_page_example  # → notion_example_page_formatting.jpg
./scripts/use-fixture.sh blog_post_draft      # → notion_full_width_page.png
./scripts/use-fixture.sh ai_for_docs          # → notion_ai_for_docs.webp

# rebuild the app whenever you touch UI sources
xcodebuild -project Console.xcodeproj -scheme Console \
  -destination 'platform=macOS' -configuration Debug build

# capture + diff against the matching reference
./scripts/snap-diff.sh rfc_prompt
open /tmp/console-screenshots/rfc_prompt-diff.png
```

**To pixel-compare:** open the diff PNG. If body type, headings, or
gaps don't sit at the same y-coordinate across the two halves, the
relevant block-spacing constant needs to be adjusted in
`Packages/UI/Sources/UI/BlockSpacing.swift` or
`Packages/UI/Sources/UI/NotionStyle.swift`.

**Editing rules:**
- Only edit `NotionStyle.swift` and `BlockSpacing.swift`. No magic
  numbers in `BlockRendering.swift`.
- Don't touch `Packages/Core/`. Don't change the parser or serializer.
- After every change: `swift test --package-path Packages/Core` — all
  16 round-trip tests must still pass.
- The "Round-corner inline code chip rendering" chip is OUT OF SCOPE.
  Inline code stays as flat-background until that task lands separately.

**Don't move on to M3 until** every reference passes the diff overlay.

## ⏳ M3 — Per-block editing + four-trigger autosave

`BlockTextEditor` wrapper around `TextEditor(text: Binding<AttributedString>)`
(iOS 26 native). Paragraphs first, then headings, bullets, todos. Undo via
SwiftUI `UndoManager`.

**Autosave triggers** (whichever fires first wins):
- Debounced 600ms after last keystroke.
- On blur (focus leaves the editor).
- On scene-phase change (background / inactive — fires before iOS suspends).
- Periodic 30s backstop while editing continuously.

All writes through a `DocumentSaveCoordinator` actor that serializes
per-document (no debounced/scene-phase race). `NSFileCoordinator` for the
actual write. Per-document `isDirty` flag — save is a no-op when clean.

**Done when:** force-quit the app from the multitasking switcher within 1s
of typing, reopen, change is there. Continuous-typing for 2 minutes writes
the file ~every 600ms (or every 30s as backstop), not on every keystroke.

## ⏳ M4 — Block-level keyboard model (no gestures yet)

- `Return`: insert new paragraph below.
- `Backspace` on empty row: delete row, focus previous.
- `Tab` / `Shift-Tab`: indent / outdent on bullet/numbered/todo (clamped 0..5).
- `Esc`: blur.
- `Cmd-K`: command palette stub.

**Done when:** can compose a multi-block document keyboard-only; indent
levels round-trip through markdown save/load.

## ⏳ M5 — Markdown autotransforms

On-type detection in `BlockTextEditor`'s `onChange`: at start-of-row, a
trigger consumes the prefix and changes the row's block type. Triggers:
`# `, `## `, `### `, `- `, `* `, `1. `, `[] `, `[ ] `, `> `, `` ``` ``,
`---\n`, and `>>` for toggles.

Inline transforms on closing trigger: `**…**`, `*…*`/`_…_`, `` `…` ``,
`~~…~~`, `[text](url)`.

Implement as pure functions in `Packages/Core/Sources/Core/Markdown/Autotransforms.swift`
taking `(AttributedString, cursor) → (AttributedString, cursor, blockTypeChange?)`.
Easy to unit test.

## ⏳ M6 — Inline formatting + iOS keyboard accessory bar

Hardware keyboard: `Cmd-B/I/U` toggle attributes on selection via iOS 26's
`AttributedTextSelection` and attribute-transform APIs. `Cmd-K` to insert a link.

**iOS soft-keyboard accessory bar** (via `.toolbar { ToolbarItemGroup(.keyboard) { … } }`):
1. Block-type chip (¶/H1/H2/H3/•/1./☐/❝/code) — tap → popover, change row type.
2. Outdent / Indent.
3. Bold / Italic / Code / Strikethrough toggles (highlighted when selection has the attr).
4. Link button (inline URL prompt).
5. Spacer.
6. Dismiss-keyboard (chevron-down) — blurs and triggers an immediate save (M3 trigger).

macOS: menu items only — there's no soft keyboard, no accessory bar.

## ⏳ M7 — Gestures

- Swipe left to delete (with undo toast).
- Swipe right to cycle indent.
- Long-press to drag-reorder (`List.onMove`).
- **Pinch open between rows to insert** — custom UIGestureRecognizer /
  NSGestureRecognizer bridged via UIViewRepresentable. SwiftUI doesn't expose
  this gesture natively. Budget time; this is the signature gesture.
- **Pinch close** to zoom out to page list.
- Pull-down within a page → in-page search bar.
- Pull-down on page list → workspace file-name search.

**Done when:** every gesture works on iPad + iPhone; pinch-to-insert is
fluid (60fps, no jank when keyboard appears).

## ⏳ M8 — Toggle and subpage editing

- Toggle children stored in the parent block; recursive renderer (already
  done read-only in M1). Add edit affordances.
- `.subpage(title, path)`: detect `[title](path.md)` paragraphs that
  resolve inside workspace, render as subpage row, push target on tap.
  Offer to create the file if missing.
- External-change detection via `NSFilePresenter` + foreground re-scan.

**Done when:** can create a toggle, nest blocks inside it, save, reopen —
same structure. Subpage navigation works; back button returns to parent.

---

## Out of scope (v1)

Tables (parse, render plain), images (parse, render placeholder), real-time
collab, in-content search across workspace, dark mode, web clipping, AI
features, cross-block selection, find-and-replace, PDF export.

## Spawned-task chips

When a follow-up surfaces during a milestone that would bloat the current
change, spawn it as a separate task rather than absorbing it. Existing chips:

- **Round-corner inline code chip rendering** — replace flat `.backgroundColor`
  with a custom `TextRenderer` that paints a 3pt rounded background per run.
