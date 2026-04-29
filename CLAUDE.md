# Console — Claude working notes

A native iOS 26 + macOS 26 markdown editor. Each block in a document is its
own row in a SwiftUI `List`, so we sidestep the hardest problems of
Notion-style editors (cross-block selection, cursor merge/split across block
types, floating-UI hover targets that don't translate to touch). Source of
truth is plain `.md` files in a user-picked workspace folder.

## Repo shape

- `Packages/Core/` — pure-Swift SPM package. Model types, swift-markdown
  parser/serializer, `NSFileCoordinator`-backed storage,
  `DocumentSaveCoordinator` actor (per-URL serial, snapshot-coalescing),
  security-scoped bookmark for the workspace folder. No SwiftUI imports.
  Round-trip + mutation + save-coordinator tests live here.
- `Packages/UI/` — SwiftUI SPM package. `NotionStyle` typography constants,
  `BlockSpacing` (sibling-aware gap math), `BlockRow`/`PageView`/
  `PageListView` rendering, `BlockTextEditor` (NSViewRepresentable around
  NSTextView on macOS, plain TextEditor on iOS). Depends on Core.
- `App/` — single multiplatform Xcode app target. `ConsoleApp` (`@main`,
  owns the `WorkspaceModel`, declares `.commands` for Reload Pages /
  Switch Workspace…), `ContentView` (workspace picker → page list →
  page view), `FontRegistration` (Inter Variable via CTFontManager),
  `Resources/Fonts/InterVariable.ttf`.
- `project.yml` — XcodeGen spec. **Don't hand-edit the .xcodeproj** — it's
  generated, ignored by git, and overwritten by `xcodegen generate`.
- `References/typography/` — real Notion screenshots from 2023-2025 used to
  drive M2 typography iteration. See `References/typography/README.md`.
- `skills/` — per-project Claude skills. `m2-typography-iterate` for the
  reference-screenshot diff loop, `ui-debug-loop` for runtime UI debugging.
- `ROADMAP.md` — milestone status and what's next.

## Build & test

```sh
# Run unit tests (Core only — UI doesn't have tests yet)
swift test --package-path Packages/Core

# Regenerate the Xcode project after adding/removing files
xcodegen generate --spec project.yml --project .

# Build for macOS (no code signing required)
xcodebuild -project Console.xcodeproj -scheme Console \
  -destination 'platform=macOS' -configuration Debug build

# Build for iOS Simulator
xcodebuild -project Console.xcodeproj -scheme Console \
  -destination 'generic/platform=iOS Simulator' -configuration Debug build

# Run the macOS app — picks the newest build by binary mtime and kills any
# running instance first. Don't `open ~/.../Console-*/Console.app` directly:
# stale DerivedData folders can linger and the wildcard launches all of them.
./scripts/run.sh
```

## Editing architecture (M3+)

- **One editor at a time.** All blocks render as read-only `Text` by default.
  When `editingBlock == block.id`, that single row swaps in a
  `BlockTextEditor`. N simultaneous TextEditors are a focus-arbitration / hit-
  test footgun on macOS — don't go back to that.
- **Nav mode supports multi-select.** PageView holds `selection: Set<BlockID>`,
  `cursor: BlockID?` (moving end), `anchor: BlockID?` (fixed end of a Shift-
  extend). `editingBlock: BlockID?` mounts the single editor. ↑/↓ collapses
  to a single-block selection at the new cursor; Shift+↑/↓ extends from the
  anchor; Return enters edit mode (only when `selection.count == 1`); Esc
  exits edit mode and returns to nav. Click jumps straight to edit and
  resets selection to that one block.
- **Selection-wide operations.** In nav mode: Delete removes every block in
  the selection; Option+↑/↓ slides the contiguous selection up/down by one
  row; Tab / Shift-Tab indent/outdent every list-item block in the selection
  (paragraph/heading rows are skipped). Single-block edits (split, delete-
  empty, indent inside the editor) all flow through the editor's `keyDown`
  path, not the page-level handler.
- **Focus reliability is fragile on macOS.** Three load-bearing details in
  `BlockTextEditor`:
  - `MacBlockTextEditor` is constructed with `isFocused: true`
    unconditionally, because `@FocusState` writes from `enterEditMode` are
    deferred and don't propagate before `makeNSView` / `viewDidMoveToWindow`
    fire. With `isFocused: focused == blockID`, `wantsFocus` was still
    `false` when the view was added to the window and the focus grab
    silently no-op'd.
  - `ContainedTextView.viewDidMoveToWindow` retries `makeFirstResponder`
    when `wantsFocus` is true. This is the second-chance path; the first
    chance is in `updateNSView` if the view is already in a window.
  - `cancelOperation(_:)` is overridden to fire the `.escape` handler.
    NSTextView routes Esc through `cancelOperation`, NOT through
    `keyDown`'s normal switch, so a plain `keyDown` override misses it. The
    override also calls `window?.makeFirstResponder(nil)` before delegating
    so the window's first-responder slot is cleared synchronously before
    SwiftUI re-renders — without this, NSTextView remains nominal first
    responder during the unmount and SwiftUI can't re-bind the page
    container, leaving arrow-key nav broken post-Esc.
  - `exitEditMode` toggles `pageFocused = false` then `true` on the next
    runloop tick. A same-value setter is a no-op in SwiftUI's focus state,
    so without the toggle the page never re-takes focus after Esc.
- **macOS `BlockTextEditor` is an NSViewRepresentable around NSTextView**,
  not stock `TextEditor`. Stock TextEditor on macOS bakes in
  `textContainerInset = (5, 0)` and `lineFragmentPadding = 5` which break
  `firstTextBaseline` alignment with list markers. The wrapper zeros both,
  intercepts Return/Tab/Backspace/Cmd-K via `keyDown(_:)`, hooks Esc via
  `cancelOperation(_:)`, and provides an explicit
  `.alignmentGuide(.firstTextBaseline) { _ in nsFont.ascender }` so
  HStack(.firstTextBaseline) lines up.
- **Inline marks survive editing.** The editor's binding is
  `Binding<AttributedString>`; `InlineMarksNSKit` (UI, macOS) does
  bidirectional conversion between the model's custom typed `AttributedString`
  keys and the `NSAttributedString` in `NSTextStorage`. On round-trip back,
  bold/italic/code are derived from font symbolic traits (because that's
  what NSTextView mutates during edits) and strike from
  `.strikethroughStyle`. Cmd-B/I/E/Shift-S toggle the corresponding marks
  on the current selection (no-op on empty selection — pre-typing toggles
  via `typingAttributes` are a follow-up).
- **Click-to-position cursor.** Clicking on a row's editable text region
  captures the click point via a `SpatialTapGesture` in the `Text` view's
  local coords, which (since the `BlockTextEditor` mounts in the same
  HStack slot the `Text` occupied) doubles as `NSTextView` local coords.
  `MacBlockTextEditor.applyPendingCursorPositionOrSeekToEnd` calls
  `characterIndexForInsertion(at:)` after the focus grab. Clicks on
  non-text parts of the row (markers, paddings) fall through to the row's
  `.onTapGesture` and seek-to-end as before.
- **Up/Down at editor boundary exits.** When the cursor is on the
  editor's first line, `↑` is short-circuited to "Esc + ↑" — exit edit
  mode, then move the nav-mode cursor to the previous block. Symmetric
  for `↓` on the last line. `cursorIsOnFirstLine()` /
  `cursorIsOnLastLine()` consult the layout manager so wrapped paragraphs
  still allow intra-block arrow navigation in the middle.
- **Markdown autotransforms (M5).** Pure detection in
  `Packages/Core/Sources/Core/Markdown/Autotransforms.swift`; replacement
  blocks built by `BlockTransform.apply(to:)`; spliced into the document by
  `PageView.applyAutotransform`. Prefix triggers (`# `, `## `, `### `, `- `,
  `* `, `1. `, `[] `, `[ ] `, `> ` for toggle, `" ` for quote) fire from the
  coordinator's `textDidChange` — IME-marked-text guarded — before the
  binding propagates. Enter triggers (`---`, ` ``` `) fire from `splitBlock`
  when the row's tail is empty. The detector accepts both `"` and `\u{201C}`
  because NSTextView's smart-quote substitution runs by default.
- **Autosave fans into `DocumentSaveCoordinator`** (Core actor, per-URL
  in-flight + pending snapshot). Triggers: 600ms debounce after any
  `markEdited()`, blur (focus → nil), `scenePhase != .active`, 30s backstop
  while a doc is open. `flushAndClose()` waits for pending writes on
  document close / app suspend.
- **Code, divider, subpage stay read-only** in M3. Tapping them doesn't
  enter edit mode (subpage navigates).

## Key constraints

- **iOS 26 / macOS 26 minimum.** Unlocks
  `TextEditor(text: Binding<AttributedString>)` natively on iOS; on macOS
  we use NSViewRepresentable for tight control over text-container insets.
- **Single multiplatform target**, not two. `#if os(iOS) / os(macOS)` for the
  few platform-divergent bits.
- **swift-tools-version 6.2** in both Package.swift files (required for
  `.iOS(.v26)` / `.macOS(.v26)`).
- **No code signing** in CI/local builds — `CODE_SIGNING_ALLOWED: NO` in
  project.yml. The user can enable signing in Xcode when shipping.
- **swift-markdown is the only third-party dep.** It's CommonMark + GFM. Its
  `MarkupFormatter.format()` round-trips semantically but normalises surface
  syntax — that's accepted; we don't try to preserve byte-exact formatting.
- **Toggles are encoded as `<details><summary>...</summary>...</details>`
  HTML blocks.** cmark closes an HTML block at a blank line, so a real-world
  toggle parses as multiple sibling AST nodes — `BlockParser.assemble`
  stitches them back into a `.toggle`. If toggles ever stop round-tripping,
  suspect this stitching pass.

## Notion typography reference

The pre-March-2026 Notion typography is the visual target. **Do not use
`react-notion-x`'s CSS as the source of truth — its values diverge from real
Notion in subtle ways.** Instead, work from the screenshots in
`References/typography/`.

Key constants live in `Packages/UI/Sources/UI/NotionStyle.swift` (sizes,
colors, fonts) and `Packages/UI/Sources/UI/BlockSpacing.swift` (per-block
margins/padding, sibling-aware gaps). When tuning, change these and rebuild
— don't sprinkle magic numbers into BlockRendering.

## What's done, what's next

See `ROADMAP.md`. As of the most recent commit:
- **M1** (workspace + read-only render), **M3 + M4** (per-block editing,
  autosave, multi-select keyboard model), **M5** (markdown prefix
  autotransforms) — landed.
- **M2** (Notion typography) — in progress; iterate against
  `References/typography/` via the `skills/m2-typography-iterate/` loop.
- **M6** is next (inline formatting + AttributedString-binding flip),
  followed by M7 (gestures + Mac drag handles) and M8 (toggle/subpage
  editing).

When debugging UI runtime issues, see `skills/ui-debug-loop/SKILL.md` —
launch from terminal with stderr redirected, sprinkle `print("[CLI] ...")`,
drive interactions via computer-use, tail `/tmp/console.log`.

## Debugging view problems

For UI runtime problems that compile and pass tests but misbehave in the
running app:

1. **Run from terminal so `print()` is visible.**
   ```sh
   pkill -f Console.app
   /Users/joe/Library/Developer/Xcode/DerivedData/Console-*/Build/Products/Debug/Console.app/Contents/MacOS/Console > /tmp/console.log 2>&1 &
   tail -f /tmp/console.log
   ```
   `print()` may buffer for a while when stdout isn't a tty — switch to
   `NSLog(...)` (visible via `log show --predicate 'process == "Console"'
   --last 2m`) or write to a `FileHandle` directly if you need real-time.
   Prefix everything with `[CLI]` so you can grep.

2. **Sprinkle `print("[CLI] ...")` at suspect transitions.** State setters,
   focus changes, key handlers, binding setters, lifecycle hooks
   (`onAppear`, `viewDidMoveToWindow`). Cross-reference with screenshots
   to nail down which step in the chain failed.

3. **Strip the prints before committing.** `grep -rn '\[CLI\]' Packages/UI
   App/Sources` finds them.

4. **Accessibility Inspector** (in Xcode → Open Developer Tool) is the
   fastest way to inspect the focused element, hit-testable view at a
   point, and accessibility tree. Useful when "click does nothing" turns
   out to be a parent gesture intercepting hit tests.

5. **Xcode View Debugger** (Debug → View Debugging → Capture View
   Hierarchy) shows the full layer tree of the running app. Best for
   layout problems — overlapping frames, wrong z-order, hidden views.
   Run the app under Xcode (not the standalone binary) to enable.

6. **`.onKeyPress` on macOS doesn't always intercept keys NSTextView
   consumes.** When it doesn't, override `keyDown(_:)` on a custom
   NSTextView subclass — see `MacBlockTextEditor.ContainedTextView`.

## Style preferences

- The user is a senior engineer; don't over-explain.
- Prefer editing existing files over adding new ones.
- Don't write comments that explain *what* code does — only the *why* when
  it's non-obvious.
- Don't add CHANGELOG.md, TROUBLESHOOTING.md, or other meta-docs unless asked.
- Keep round-trip tests green (`swift test --package-path Packages/Core`)
  before committing UI/typography changes — the parser/serializer is the
  load-bearing core.
