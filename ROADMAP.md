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

**Status:** First two passes landed (commits `1df180f`, `9b96acd`):
- Inter Variable bundled and registered via CoreText.
- `BlockSpacing` introduced for sibling-aware gaps (CSS-margin-collapse style).
- Quote at 1.2em, code radius 8pt, list-item padding 6pt.

**Remaining:** Spacing still doesn't match real Notion. The values were
derived from `react-notion-x`'s CSS, which the user has flagged as not an
exact match. **Re-tune against the actual screenshots in
`References/typography/`** (see that folder's README for what to drop in
there).

**Done when:** screenshot diff against a reference Notion page is visually
indistinguishable at 1× and 2×.

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
