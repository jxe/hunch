# Hunch — Claude working notes

(Repo dir is `console`, target/scheme/binary are `Hunch`. The product display name is Hunch; the bundle id `com.joeedelman.console` predates the rename and stays for user-data continuity.)

A native iOS 26 + macOS 26 markdown editor. Each block is its own row in a
SwiftUI VStack — sidesteps the hardest problems of Notion-style editors
(cross-block selection, cursor merge across types, hover-only floating UI
that doesn't translate to touch). Source of truth: plain `.md` files in a
user-picked workspace folder.

## Repo shape

- `Packages/Editor/` — single SwiftUI SPM package. The single-page editor:
  `Block` / `Document` model, `EditorView`, `EditorState`, `BlockTextEditor`
  (NSTextView wrapper on macOS, plain TextEditor on iOS), block rendering,
  autotransforms (`# `, `- `, `> `, ` ``` `, `---`, `[]/[ ]`, `1. `, `" `),
  @-mention detection, inline-mark `AttributedStringKey`s. **No
  swift-markdown dep.** Operates on the in-memory `Document` only — the
  host is responsible for serialization, persistence, navigation, and
  multi-page operations. SPM tests live here. See
  `Packages/Editor/README.md` for the embedding contract.
- `App/Sources/` — Hunch.app target. `HunchApp`/`ContentView` (with
  `WorkspaceModel` bridging the editor's id-based callbacks to filesystem
  paths, and a small `EditorPage` wrapper that owns one `EditorState` per
  navigation destination), Inter font registration, plus:
  - `App/Sources/Clamshell/` — **Clamshell** is Hunch's persistent
    markdown format and its API. On disk a Clamshell is a folder of
    `*.md` plus `Trash/` (soft-deleted pages), `.history/<rel>.md.jsonl`
    (append-only log of lost / edited blocks), and `.clamshell.json`
    (format metadata — currently just the home page pointer).
    `Clamshell` is the umbrella type — one per open directory, never
    reconfigured. Composes `FileStore`, `DocumentSaveCoordinator` (per-URL
    serial, snapshot-coalescing actor), `RecoveryStore` (the `.history/`
    log), and `TrashStore` privately and exposes a single API:
    `scan / loadDocument / save / writeImmediately / flush / createPage /
    moveToTrash / listTrashedPages / restorePage / recordDeletion /
    listLostBlocks / purgeLostBlock`, plus `relativePath(of:)` and
    `url(for:)` for path conversion. The format takes care of itself
    where it can — every `save`/`writeImmediately` fires fire-and-forget
    `recordEdits` against the lost-block log, and `moveToTrash` clears
    `homeRelativePath` if it matched. Also where the markdown layer
    lives: `BlockParser`, `BlockSerializer` (swift-markdown lives here,
    not in the Editor), and `BlockFingerprint`. `WorkspaceBookmark`
    persists the security-scoped URL of the user's chosen Clamshell.
  - `App/Sources/Shell/` — `PageListView` (sidebar) and `RecoveryView`
    (unified "Recover" sheet over trash + lost blocks).
  - `App/Sources/Workspace.swift` — `WorkspaceEntry` (filesystem-flavoured
    page reference, host-side only — translated into `MentionItem` at the
    editor boundary).
- `App/Tests/HunchUnitTests/` — Xcode unit-test bundle for the host's
  storage + parser/serializer (formerly SPM tests under `CoreTests/`).
  Compiles fine; `xcodebuild test` may need extra signing config to load
  the Editor framework into the test process.
- `project.yml` — XcodeGen spec. **Don't hand-edit the `.xcodeproj`** —
  it's generated, gitignored, overwritten by `xcodegen generate`.
- `References/typography/` — real Notion screenshots; see its README.
- `skills/`, `tasks/`, `docs/` — per-project Claude skills, unordered
  upcoming task notes, and accumulated working notes.

## Build & test

```sh
swift test --package-path Packages/Editor
xcodegen generate --spec project.yml --project .
xcodebuild -project Hunch.xcodeproj -scheme Hunch -destination 'platform=macOS' -configuration Debug build
xcodebuild -project Hunch.xcodeproj -scheme Hunch -destination 'generic/platform=iOS Simulator' -configuration Debug build
./scripts/run.sh   # macOS — kills any running Hunch.app, launches the newest build
```

## Architecture you need to know to make changes

**One editor at a time.** Blocks render as read-only `Text` until
`state.mode == .editing(block.id, _)`; that row swaps in `BlockTextEditor`.
N simultaneous TextEditors are a focus-arbitration footgun on macOS —
don't go back to that.

**Editor session state lives in `EditorState`.** Selection, edit mode,
in-flight gestures (reorder, pinch), expanded toggles, hover, drop targets
— all on the `EditorState` `@Observable` class. The state space is two
orthogonal axes: `mode: Mode` (`.navigating(Selection)` or
`.editing(BlockID, overlay: Overlay?)`) and `gesture: Gesture?`
(`.reordering(...)` / `.pinchOpening(...)`), plus ambient annotations.
Mention popover is `.editing(_, .mention(...))`, an overlay *within*
edit mode, not a peer mode. Invariant: a non-nil `gesture` only
coexists with `mode == .navigating(...)`. Mutation goes through named
methods (`enterEditMode`, `setReorderLift`, `setMentionMenu`, etc.) —
`internal(set)` blocks external writes so the host can read but not write.

**One `EditorView` per document.** The pair `(document, state)` is one
editing session. The `EditorPage` wrapper view in `ContentView.swift`
owns `@State EditorState` so each navigation destination gets fresh
state. EditorView caches focus, undo, and gesture state internally and
assumes both inputs are stable.

**Page navigation is a `NavigationStack(path: [URL])`.** `WorkspaceModel.path`
is the source of truth for what's open: `path == []` shows the page list root,
`path.last` is the visible doc, and a `.onChange(of: path)` calls
`handlePathChange()` to flush the outgoing doc and load the new top.
Subpage taps (`onSubpageTap` → `model.openSubpage`) append to `path`, pushing
deeper. Sidebar taps (`model.open`) reset `path` to a single entry.
`model.goBack()` pops; on iOS this is also driven by edge-swipe-from-left,
on macOS by the Cmd+[ menu and the system back chevron. Subpage rows are
the existing render path: a paragraph that is a single `.md` link is
detected in `BlockParser` and rendered via `subpageRow` in
`BlockRow.swift`. (Inline `[text](path.md)` clicks inside body text
don't navigate yet — see `tasks/inline-link-click-navigation.md`.)

**Nav mode is multi-select.** `Mode.navigating(Selection)` carries
`blocks: Set<BlockID>`, `cursor` (moving end), `anchor` (fixed end).
↑/↓ collapses to a single block, Shift+↑/↓ extends, Return enters edit
mode (only when `state.selection.count == 1`) or opens a selected
subpage, → also opens a selected subpage, Esc exits, Delete removes the
selection, Option+↑/↓ slides, Tab/Shift-Tab indent/outdent list items
in the selection.

**Editor binding is `Binding<AttributedString>`** so inline marks
(bold/italic/code/strike/link) round-trip through edits.
`InlineMarksBridge` (UI, macOS) bridges between the model's custom typed
`AttributedStringKey`s and `NSTextStorage`. Bold/italic/code are derived
from font symbolic traits on round-trip back, because that's what
NSTextView mutates during edits. Cmd-B/I/E/Shift-S toggle marks on the
selection.

**Markdown autotransforms.** Pure detection in
`Packages/Editor/Sources/Editor/Autotransforms.swift`;
replacement blocks via `BlockTransform.apply(to:)`; spliced into the
document by `EditorView.applyAutotransform`. Prefix triggers (`# `, `## `, `### `, `- `,
`* `, `1. `, `[] `, `[ ] `, `> ` for toggle, `" ` for quote) fire from
the coordinator's `textDidChange` (IME-marked-text guarded) before the
binding propagates. Enter triggers (`---`, ` ``` `) fire from
`splitBlock` when the row's tail is empty. The `" ` detector accepts
both `"` and `\u{201C}` — NSTextView's smart-quote substitution runs by
default.

**Click-to-position cursor.** A `SpatialTapGesture` on the read-only
`Text` captures the click point in editor-local coords (which doubles as
NSTextView local coords because the editor mounts in the same HStack
slot). `MacBlockTextEditor.applyPendingCursorPositionOrSeekToEnd` calls
`characterIndexForInsertion(at:)` after the focus grab. Clicks on
non-text parts (markers, paddings) fall through to the row's
`.onTapGesture` and seek-to-end.

**Up/Down at editor boundary exits edit mode.**
`cursorIsOnFirstLine()` / `cursorIsOnLastLine()` consult NSLayoutManager
so wrapped paragraphs still allow intra-block arrow nav in the middle.

**Autosave fans into `DocumentSaveCoordinator`** (Core actor, per-URL
in-flight + pending-snapshot coalesce). Triggers: 600ms debounce, blur,
`scenePhase != .active`, 30s backstop. `flushAndClose()` waits on
pending writes at document switch / app suspend.

## macOS NSTextView footguns (load-bearing)

Stock `TextEditor` on macOS bakes in `textContainerInset = (5, 0)` and
`lineFragmentPadding = 5`, breaking `firstTextBaseline` alignment with
list markers. `MacBlockTextEditor` wraps NSTextView directly, zeros
both, and adds `.alignmentGuide(.firstTextBaseline) { _ in
nsFont.ascender }`.

Three load-bearing focus details:

1. `MacBlockTextEditor` is constructed with `isFocused: true`
   unconditionally. `@FocusState` writes from `enterEditMode` are
   deferred and don't propagate before `makeNSView` /
   `viewDidMoveToWindow` fire.
2. `cancelOperation(_:)` is overridden to fire the `.escape` handler AND
   to call `window?.makeFirstResponder(nil)` first — without this,
   SwiftUI can't re-bind the page container after the editor unmounts,
   and arrow nav breaks post-Esc.
3. `exitEditMode` toggles `pageFocused = false` then `true` on the next
   runloop tick. A same-value setter is a no-op in SwiftUI focus state.

`.onKeyPress` on macOS doesn't reliably intercept keys NSTextView
consumes. Override `keyDown(_:)` on a custom NSTextView subclass instead
— see `ContainedTextView`.

## Project-level constraints

- **iOS 26 / macOS 26 minimum.** Unlocks
  `TextEditor(text: Binding<AttributedString>)` natively on iOS; macOS
  uses NSViewRepresentable for tight control over insets.
- **Single multiplatform target**, not two. `#if os(iOS)` / `#if
  os(macOS)` for the divergent bits.
- **swift-tools-version 6.2** in both Package.swift files.
- **No code signing** (`CODE_SIGNING_ALLOWED: NO`).
- **swift-markdown is the only third-party dep.** Its
  `MarkupFormatter.format()` normalises surface syntax — accepted; we
  don't try byte-exact preservation.
- **Toggles are encoded as `▸ Title` paragraphs** with body blocks
  indented one unit (2 spaces) deeper. The `parseToggleContainers`
  pre-pass in `BlockParser` lifts toggles by indent before
  swift-markdown sees the source — fenced code blocks are treated as
  opaque so a `▸ ` line inside code isn't lifted, and a code line
  outdented to column 0 inside a body fence doesn't terminate the
  body. The legacy `<details><summary>…</summary>…</details>` format
  is still parsed for backward compatibility (see the `assemble`
  function in `Parser.swift`); files convert to the new format on
  next save.

## Notion typography target

Pre-March-2026 Notion. **Don't use `react-notion-x`'s CSS as truth** —
its values diverge from real Notion. Work from the screenshots in
`References/typography/`. Constants live in `NotionStyle.swift` — both the `NotionStyle` enum
(sizes, colors, fonts) and the `BlockSpacing` enum (per-block margins,
sibling-aware gaps) are in that file. Don't sprinkle magic numbers
into `BlockRow.swift`.

## Debugging UI runtime issues

```sh
pkill -f Hunch.app
/Users/joe/Library/Developer/Xcode/DerivedData/Hunch-*/Build/Products/Debug/Hunch.app/Contents/MacOS/Hunch > /tmp/console.log 2>&1 &
tail -f /tmp/console.log
```

Sprinkle `print("[CLI] ...")` at suspect transitions (state setters,
focus changes, key handlers, lifecycle hooks). Strip them before
committing: `grep -rn '\[CLI\]' Packages/UI App`. `print()` may buffer
when stdout isn't a tty — use `NSLog` (visible via `log show --predicate
'process == "Hunch"' --last 2m`) for real-time.

Xcode tools that earn their keep:
- **Accessibility Inspector** — what's hit-testable at a point; useful
  when a parent gesture is silently eating taps.
- **View Debugger** — overlapping frames, wrong z-order, hidden views.
  Requires running under Xcode (not the standalone binary).

## Style preferences

- The user is a senior engineer — don't over-explain.
- Prefer editing existing files over adding new ones.
- Comments explain *why*, never *what*. Skip them when the code is clear.
- Don't add CHANGELOG.md, TROUBLESHOOTING.md, etc. unless asked.
- Keep `swift test --package-path Packages/Editor` green before committing
  UI changes — the autotransform / mention / reorder / mutation layer is
  load-bearing and the only test surface inside the package.
