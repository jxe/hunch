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
at 1× and 2×. Done when each `compare-typography.py` overlay shows text
bands aligning row-for-row across both halves.

### What's already landed

| pass | constants confirmed correct |
|------|----------------------------|
| `1df180f` | Inter Variable bundled and registered via CoreText. |
| `9b96acd` | `BlockSpacing` introduced for sibling-aware gaps. |
| (this branch) | Page-title H1 = 40pt; inline H1 = 30pt; H2 = 24pt; H3 = 20pt; all headings weight 700. List items pad 5pt top/bottom. Numbered lists actually number sequentially. |

### Iteration loop (run this every time you touch a typography constant)

The infrastructure is already in place — *use it*. Don't eyeball, measure.

```sh
# 0. one-time prep — make sure /tmp/console-fixture/everything.md is the
#    workspace's only file and that com.joe.console.workspace.bookmark
#    points at /tmp/console-fixture. The app auto-opens the last page,
#    so after the first manual click you never click again.

# 1. switch to a specific reference fixture
./scripts/use-fixture.sh rfc_prompt           # → notion_prompt_example.png
./scripts/use-fixture.sh notion_page_example  # → notion_example_page_formatting.jpg
./scripts/use-fixture.sh blog_post_draft      # → notion_full_width_page.png
./scripts/use-fixture.sh ai_for_docs          # → notion_ai_for_docs.webp

# 2. capture the Console window (you need Screen Recording permission)
osascript -e 'tell application "System Events" to tell process "Console"
  set p to position of window 1
  set s to size of window 1
  return (item 1 of p as string) & "," & (item 2 of p as string) & ","
       & (item 1 of s as string) & "," & (item 2 of s as string)
end tell'
# → e.g. 151,58,1089,812
screencapture -R "<that-rect>" -x /tmp/console-screenshots/<name>-current.png

# 3. produce the side-by-side diff
python3 scripts/compare-typography.py \
  /tmp/console-screenshots/<name>-current.png \
  References/typography/<reference-image> \
  --out /tmp/console-screenshots/<name>-diff.png

# 4. open the diff and read the text bands. Reference is on the LEFT,
#    your screenshot scaled to matching body-line-height on the RIGHT.
#    Red rule = top of each text band, blue rule = bottom. If a red line
#    on the reference doesn't have a matching red line at the same y on
#    your half, the gap above that band is wrong — adjust topMargin /
#    bottomMargin / intrinsicVerticalPadding for the relevant block type.

# 5. edit ONLY Packages/UI/Sources/UI/NotionStyle.swift and
#    Packages/UI/Sources/UI/BlockSpacing.swift. Rebuild + relaunch with:
xcodebuild -project Console.xcodeproj -scheme Console \
  -destination 'platform=macOS' -configuration Debug build
./scripts/use-fixture.sh <name>   # also kills + relaunches Console

# 6. re-screenshot, re-diff, repeat.
```

**Pixel measurement primitives:**
- `scripts/measure-typography.py <image>` prints raw band positions and
  expresses each gap as a multiple of the body line-height. Useful when
  the visual diff isn't clear enough — numbers don't lie about which
  gap is 1.4× vs 1.8× of body-LH.
- `scripts/compare-typography.py <screenshot> <reference>` produces the
  side-by-side overlay described above.

**Editing rules (don't break these):**
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
