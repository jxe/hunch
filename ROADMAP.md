# Roadmap

Eight-milestone build order. Each milestone is independently shippable;
don't start the next until the current one passes its "Done when"
criterion. The code (and `CLAUDE.md`) document _what was built_; this
file is for _what's left_.

## ✅ M1 — Workspace + page list (read-only) — DONE
## 🟢 M3 + M4 — Per-block editing, autosave, keyboard model — DONE
## 🟢 M5 — Markdown autotransforms (prefix triggers) — DONE

See `CLAUDE.md` for the editing architecture and load-bearing details.
Core has 63 tests across round-trip, mutation, autotransforms, and the
save coordinator.

Carry-overs to address in a later milestone:
- Cross-block undo as a single op (split/merge/indent should coalesce).
- Backspace-at-0 merge into the previous non-empty row (currently no-op).
- Toggle-child editing inside the toggle.

---

## 🟡 M2 — Pixel-correct Notion typography — IN PROGRESS

**Goal:** screenshot diff vs each reference is visually indistinguishable
at 1× and 2×. Done when every `snap-diff` overlay reads as the same page
on both halves. The visual target is **pre-March-2026 Notion**; the four
reference screenshots in `References/typography/` are the source of
truth, *not* `react-notion-x`'s CSS.

**What's still uncertain:**

- Heading→heading and heading→paragraph margins. Currently 28pt above an
  H2, 6pt below — guessed, not measured. `headings_and_bullets` fixture
  exercises H2→H3-stacked and H2→bullets-directly, but a Notion
  reference shot is needed to diff against.
- Quote, code, divider, toggle, subpage spacing. Untouched since
  `9b96acd`. No fixture exercises these yet.
- Inline H1 (30pt) and H3 (20pt) values are derived from `em` math, not
  measured. The `headings_and_bullets` fixture exercises both but lacks
  a Notion reference.

**Iteration loop:**

```sh
./scripts/use-fixture.sh <name>      # rfc_prompt, notion_page_example,
                                     # blog_post_draft, ai_for_docs,
                                     # headings_and_bullets (capture-only)

xcodebuild -project Console.xcodeproj -scheme Console \
  -destination 'platform=macOS' -configuration Debug build

./scripts/snap-diff.sh <name>        # side-by-side w/ red band rules
open /tmp/console-screenshots/<name>-diff.png
```

**Editing rules:**

- Only edit `NotionStyle.swift` and `BlockSpacing.swift`. No magic
  numbers in `BlockRendering.swift`.
- Don't touch `Packages/Core/`. Don't change the parser or serializer.
- After every change: `swift test --package-path Packages/Core`.
- Round-corner inline code chip rendering is OUT OF SCOPE — see
  "Spawned-task chips" below.

---

## ⏳ M6 — Inline formatting + iOS keyboard accessory bar

**Hardware keyboard (macOS + iOS):** `Cmd-B/I/U` toggle attributes on the
selection. `Cmd-K` insert a link. Underpinned by flipping the editor's
binding from `String` to `AttributedString` so model marks survive
editing — today they're stripped on first edit per the M3 scope decision
([`BlockRendering.swift:textBinding`](Packages/UI/Sources/UI/BlockRendering.swift)
is the lossy projection that needs to go).

**Inline closing-trigger autotransforms** (lifted out of M5): `**bold**`,
`*it*` / `_it_`, `` `code` ``, `~~strike~~`, `[text](url)`. Plug into
the same `Autotransforms.swift` module. Detection runs on each typed
character; transform applies the model attribute and consumes the
delimiters.

**iOS soft-keyboard accessory bar** (`.toolbar { ToolbarItemGroup(.keyboard) { … } }`):

1. Block-type chip (¶/H1/H2/H3/•/1./☐/❝/code) — tap → popover, change row type.
2. Outdent / Indent.
3. Bold / Italic / Code / Strikethrough toggles (highlighted when selection has the attr).
4. Link button (inline URL prompt).
5. Spacer.
6. Dismiss-keyboard (chevron-down) — blurs and triggers an immediate save (M3 trigger).

macOS: menu items only — there's no soft keyboard, no accessory bar.

---

## ⏳ M7 — Gestures + drag handles

- **macOS: hover-revealed drag handles per row.** Click-and-drag the
  handle to reorder. When the dragged row is part of the current
  multi-selection, the whole selection moves. PageView is a `VStack`
  inside a `ScrollView` (not a `List`), so this needs custom drag-and-
  drop — `.draggable` on the handle, `.dropDestination` between rows.
- iOS swipes: left-to-delete with undo toast, right-to-cycle-indent.
- Long-press to drag-reorder on iOS (parallel to mac drag handles).
- **Pinch open between rows to insert** — custom UIGestureRecognizer /
  NSGestureRecognizer bridged via UIViewRepresentable. SwiftUI doesn't
  expose this gesture natively. Budget time; this is the signature gesture.
- **Pinch close** to zoom out to page list.
- Pull-down within a page → in-page search bar.
- Pull-down on page list → workspace file-name search.

**Done when:** every gesture works on iPad + iPhone; pinch-to-insert is
fluid (60fps, no jank when keyboard appears).

---

## ⏳ M8 — Toggle and subpage editing

- Toggle children stored in the parent block; recursive renderer
  (already done read-only in M1). Add edit affordances.
- `.subpage(title, path)`: detect `[title](path.md)` paragraphs that
  resolve inside workspace, render as subpage row, push target on tap.
  Offer to create the file if missing.
- External-change detection via `NSFilePresenter` + foreground re-scan.

**Done when:** can create a toggle, nest blocks inside it, save, reopen —
same structure. Subpage navigation works; back button returns to parent.

---

## Out of scope (v1)

Tables (parse, render plain), images (parse, render placeholder),
real-time collab, in-content search across workspace, dark mode, web
clipping, AI features, cross-block selection, find-and-replace, PDF
export.

## Spawned-task chips

When a follow-up surfaces during a milestone that would bloat the
current change, spawn it as a separate task rather than absorbing it.
Existing chips:

- **Round-corner inline code chip rendering** — replace flat
  `.backgroundColor` with a custom `TextRenderer` that paints a 3pt
  rounded background per run.
