# Hunch — Claude working notes

(Repo dir is `hunch`, target/scheme/binary are `Hunch`. The product display name is Hunch; bundle id is `org.nxhx.Hunch` — pre-TestFlight builds used `com.joeedelman.console`, so any local installs from before the rename are orphaned and won't share UserDefaults / workspace bookmark with the new id. `scripts/clean-orphans.sh` purges those legacy bundles and rebuilds LaunchServices' index; `scripts/run.sh` calls it pre-launch so name-based resolution can't land on a stale bundle. The `console.workspace.bookmark` UserDefaults key and `--console-ui-testing` launch flag also predate the rename and are kept for compat.)

A native iOS 26 + macOS 26 markdown editor. Each block is its own row in a
SwiftUI `LazyVStack` — sidesteps the hardest problems of Notion-style editors
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
- `App/Sources/` — Hunch.app target. `HunchApp` (root, owns `Workspace`),
  `ContentView` (one per `WindowGroup` body, owns a `WorkspaceWindow`),
  `Workspace.swift` / `WorkspaceWindow.swift` (the host model — see below;
  `WorkspaceWindow` is also the `EditorHost`, naturally keyed on
  `openDocument`), and an `EditorPage` wrapper view inside
  `ContentView.swift` that owns one `EditorState` per navigation
  destination, plus Inter font registration:
  - `App/Sources/Clamshell/` — **Clamshell** is Hunch's persistent
    markdown format and its API. On disk a Clamshell is a folder of
    `*.md` plus `Trash/` (soft-deleted pages), `.history/<rel>/<device-id>.jsonl`
    (per-(device, page) append-only recovery log), `Assets/` (pasted
    images), and `.clamshell.json` (format metadata — currently just the
    home page pointer). `Clamshell` is the umbrella type — one per open
    directory, never reconfigured. Composes `FileStore`,
    `RecoveryLog` (per-device JSONL appender + cross-device read union;
    every write goes through one primitive, `apply(Patch, to:)`),
    and `TrashStore` privately and exposes a single API:
    `entries / rescan / title(for:) / lookupPage / pages(matching:) /
    loadDocument / openPage / closePage / documentDidChange / flush /
    append / createPage / moveToTrash / listTrashedPages / restorePage /
    listLostBlocks / listPurgedBlocks / resolveConflictVersions`,
    plus `relativePath(of:)` and `url(for:)` for path conversion.
    Internal helpers (`writeClosedPage(_:patch:)`, `scheduleSave(_:)`,
    `reconcile(at:)`, `reconcileLive`, `classifyDiskContent`,
    `isQuiescent`, `installPresenter` / `removePresenter`) and the `log`
    actor drive the engine from inside the module and aren't part of the
    host surface. **Clamshell is `@Observable`**: `entries` and
    `homeRelativePath` are tracked properties; SwiftUI re-renders
    automatically when scan / title cache / home changes. The title
    cache and post-save bookkeeping (mtime refresh, title update,
    selective rescan) all live inside Clamshell — the host doesn't
    thread any callbacks through it. **Editor-driven persistence** is
    `documentDidChange(ops:in:)` (the unified commit primitive — applies
    the op batch to the recovery log when non-empty, then serializes and
    writes the `.md`, in one awaited sequence) and `flush(_:)` (await
    any pending chain entry; used for blur/scenePhase/navigation).
    Concurrent calls for the same URL are chained on `saveChain[url]` —
    each spawned Task awaits the previous before its own log apply +
    file write — so the .md on disk always reflects the latest commit.
    No debounce, no separate "log-apply Task," no `.armed` state: every
    `Document.transaction` (typing via `commitLiveText`, structural via
    `mutate(_:_:)`, undo, redo) computes its pre→post diff and fires
    `DocumentUndoController.onCommit`, which forwards the ops to the
    host. That's the single save event. The "log durable
    before file durable" invariant is preserved structurally: every
    `documentDidChange` writes log before file inside a single Task.
    **Non-editor writes** (`writeClosedPage(_:patch:)` for conflict
    merge + restore-into-closed-page; `append(_:toPage:)` for
    drop-on-subpage) sequence log-then-file atomically without the
    chain, since they're for documents that have no live editor
    session. **Internal in-place mutations** (reconcile auto-restore
    splice, manual-restore splice) call `scheduleSave(_:)` to enqueue a
    .md write onto the same per-URL chain — no log apply, since the
    journal is already current. `moveToTrash`
    clears `homeRelativePath` if it matched and moves the page's
    `.history/<rel>/` dir along with the `.md`. Also where the
    markdown layer lives: `BlockParser`, `BlockSerializer` (swift-markdown
    lives here, not in the Editor), and `BlockFingerprint` (16-char
    prefix for compact display, full SHA-256 for the recovery log's
    `h` field). `DeviceID` mints + caches a per-install UUID in
    `UserDefaults` to name this device's log file. `WorkspaceBookmark`
    persists the security-scoped URL of the user's chosen Clamshell.
    See [`App/Sources/Clamshell/README.md`](App/Sources/Clamshell/README.md)
    for the on-disk format, log record shape, and operation reference.
  - `App/Sources/Shell/` — auxiliary views: `PagePickerView` (the row list
    used inside the search sheet), `MoveDestinationSheet` (block-move
    picker), `RecoveryView` (unified "Recover" sheet over trash + lost
    blocks), `BannerView` (transient toast). There is no sidebar — page
    navigation goes through the search sheet (Cmd+P / iOS toolbar
    magnifying-glass) or subpage rows.
  - `App/Sources/Workspace.swift` — `Workspace` (workspace-level model,
    one per app instance: clamshell handle, bookmark resolution,
    app-level UI state — `error` / `banner` — security-scoped URL,
    closed-page conflict resolution) and `WorkspaceEntry` (filesystem-
    flavoured page reference, host-side only — translated into
    `MentionItem` at the editor boundary). The page list and title
    cache live on `Clamshell`; `workspace.entries` and
    `workspace.homeRelativePath` are passthroughs.
  - `App/Sources/WorkspaceWindow.swift` — per-window navigation and
    edit-session state, AND the `EditorHost` implementation: `path: [URL]`
    (NavigationStack), `openDocument` (computed from a stored
    `openPage: Clamshell.OpenPage?`), move-to request plumbing.
    `handlePathChange` is the choreography: drain prior page via
    `clamshell.closePage(_:)`, then `await clamshell.openPage(at:)`
    which returns the Document + reconcile summary + presenter handle
    in one call (folds journal, auto-restores lost subtrees, installs
    file presenter). The host methods (`openLink`,
    `documentDidChange`, `flush`, …) live on the same type and
    forward to `Clamshell`. Move-to is async — the editor
    `await`s `host.onRequestMoveDestination(...)`, the host bridges to
    the sheet via a `CheckedContinuation`.
- `App/Tests/HunchUnitTests/` — Xcode unit-test bundle for the host's
  storage + parser/serializer (formerly SPM tests under `CoreTests/`).
  The test target depends only on the `Hunch` app target — Editor's
  symbols come through `BUNDLE_LOADER` (the test bundle's host is
  `Hunch.app/Contents/MacOS/Hunch`, which statically links Editor), so
  the test target must not list Editor as a direct dep or it would link
  a second copy.
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
`state.sessionState` is `.editing(block.id, _)`; that row swaps in
`BlockTextEditor`. N simultaneous TextEditors are a focus-arbitration
footgun on macOS — don't go back to that.

**Editor session state lives in `EditorState`.** Selection, edit mode,
in-flight gestures (reorder, pinch), expanded toggles, hover, drop targets
— all on the `EditorState` `@Observable` class. The state space is one
enum, `sessionState: SessionState`:
`.navigating(Selection, gesture: Gesture?)` or
`.editing(BlockID, overlay: Overlay?)`, plus ambient annotations.
Mention popover is `.editing(_, .mention(...))`, an overlay *within*
edit mode, not a peer mode. "Gesturing while editing" is structurally
impossible — the gesture slot lives inside `.navigating`, so beginning
a gesture commits or cancels any active edit first. Mutation goes
through named methods (`enterEditMode`, `setReorderLift`,
`setMentionMenu`, etc.) — `internal(set)` blocks external writes so the
host can read but not write.

**`@Observable` setters fire on every write, even same-value.** Writing
`state.hoveredBlock = id` from inside `.onContinuousHover` /
`.onHover` invalidates `EditorView.body` on every cursor tick AND every
SwiftUI hover redispatch (which fires whenever layout shifts row
frames). Combined with `LazyVStack`'s deeper per-row layout cost, this
closes a feedback loop and pegs CPU. Guard the write at the call site:
`if state.hoveredBlock != id { state.hoveredBlock = id }`. Same shape
for any other `@Observable` field reachable from a hover/layout/geometry
callback.

**One `EditorView` per document.** The pair `(document, state)` is one
editing session. The `EditorPage` wrapper view in `ContentView.swift`
owns `@State EditorState` so each navigation destination gets fresh
state. EditorView caches focus, undo, and gesture state internally and
assumes both inputs are stable.

**Page navigation is a `NavigationStack(path: [URL])`.** `WorkspaceWindow.path`
is the source of truth for what's open: `path == []` shows the home page,
`path.last` is the visible doc, and a `.onChange(of: path)` calls
`handlePathChange()` to flush the outgoing doc and load the new top.
Subpage taps fire `host.openLink(.workspacePage(pageID))` →
`window.openSubpage` and append to `path`, pushing deeper.
Search-sheet activation (`window.navigateFromSearch`) pushes a single
entry on top of home (or drains to root when the picked page *is*
home). `window.goBack()` pops; on iOS this is also driven by
edge-swipe-from-left, on macOS by the Cmd+[ menu and the system back
chevron. Subpage rows are the existing render path: a paragraph that
is a single `.md` link is detected in `BlockParser` and rendered via
`subpageRow` in `BlockRow.swift`. **Inline `[text](path.md)` clicks
inside read-only body text** route through an `OpenURLAction`
interceptor *inside* `EditorView` (so the editor owns its link
routing) → `host.openLink(.url(url))`. The host classifies the URL
(`Workspace.workspaceRelativeMarkdownPath` → `window.openSubpage` for
workspace-relative `.md`; return `false` to fall through to the system
handler for external `http`/`https`). Inline link taps *inside* an
active TextEditor are not yet intercepted (NSTextView / UITextView own
those gestures).

**Nav mode is multi-select.** `SessionState.navigating(Selection, gesture:)`
carries `blocks: Set<BlockID>`, `cursor` (moving end), `anchor` (fixed end).
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

**Save is commit-time atomic on `Clamshell`** ([`Clamshell.swift`](App/Sources/Clamshell/Clamshell.swift)):
`documentDidChange(ops:in:)` is the single primitive — applies the op
batch to the recovery log when non-empty, then serializes and writes
the `.md`, in one awaited sequence per call. Concurrent calls for the
same URL chain on `saveChain[url]` so a rapid burst (typing commit →
focus blur → navigation) lands in order. `flush(_:)` awaits the chain
head and drains the save coordinator. No debounce, no `.armed` /
queued state machine, no separate log-apply Task: edit-session commit
points (`commitLiveText` for typing; `mutate(_:_:)` for structural
ops) are themselves the save events. The "log durable before file
durable" invariant is preserved structurally — the log apply runs
inside the same Task before the file write. Crash recovery is trivial:
reconcile heals any divergence on next open. Post-save bookkeeping
(mtime, title cache, rescan-when-title-changed) runs inside
Clamshell's `postSaveBookkeeping(_:)` — fired by every successful save
path. No host hook is needed; Clamshell is `@Observable` and SwiftUI
re-renders pick up new entries/title state directly.

**Every edit funnels through `Document.transaction`.** The transaction
snapshots `children` *before* `preMutation` fires (so the snapshot
captures pre-typing state), runs `preMutation` (which flushes the live
editor's text through a nested transaction), runs the change closure,
re-enforces heading containment, snapshots `children` again, and
derives the pre→post diff via `BlockTreeDiff.derive(_:_:)`. The diff
is the transaction's return value and also drives the registered undo
inverse — on undo the inverted diff fires via `didApplyUndo`, on redo
the forward diff fires again. Same shape across forward/undo/redo, so
the recovery journal stays symmetric. Nested transactions return `[]`
and emit nothing — the outer's diff already covers their changes.

**`DocumentUndoController.onCommit` is the editor's single emission
point.** Wired in `EditorView.installUndoApply` to call
`host.documentDidChange(ops:on:)`. Both `EditorView.mutate(name:_:)`
(structural) and `BlockTextEditor.Coordinator.commitLiveText` (typing)
go through `undoController.transaction(name:coalesceKey:_:)`, which
runs the document transaction and fires `onCommit` with the diff.
Empty diff = pure reorder/move (id+hash stable); the host still
persists the new tree shape from the same call.

**Nav-mode keyboard goes through `EditorCommands`.**
`handleNavKeyPress` looks the press up in `EditorView.navBindings`
(`(KeyEquivalent, EventModifiers) → EditorAction`) and dispatches via
`editorCommands.perform(...)`. Wiring lives in
`EditorView+Wiring.swift`. To add a shortcut: append a row to
`navBindings`, an `EditorAction` case, and a switch arm in
`wireEditorCommands`. Modifiers match exactly — Cmd-B does NOT trigger
a binding declared for Cmd-Shift-B.

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
3. Re-grabbing page focus needs a `false → true` flip across two
   runloop ticks (a same-value `@FocusState` write is a no-op).
   `forcePageFocusGrab()` bumps `pageFocusToken`; one
   `.onChange(of: pageFocusToken)` in body owns the dispatch dance.
   Don't write `pageFocused` directly from call sites — bump the token.

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
committing: `grep -rn '\[CLI\]' Packages/Editor App`. `print()` may
buffer when stdout isn't a tty.

For diagnostics that need to outlive a single debug session — and to read
state from a build the user is running directly (no `> /tmp/console.log`
redirect) — use the `Diag.*` loggers (`Packages/Editor/.../Diag.swift`,
`App/Sources/Diag.swift`). They're `os.Logger` keyed to subsystem
`org.nxhx.Hunch` with categories `navkey` / `mode` / `subpage` / `speech`.
**Do not use `NSLog` for new diagnostics** — its message bodies land as
`<private>` in the unified log (Apple redacts dynamic string args by
default) and are unreadable without `sudo log config` mucking. The `Diag`
calls all mark their values `, privacy: .public` so they show up plain.
Tail with:

```sh
log stream --predicate 'subsystem == "org.nxhx.Hunch"'
# or narrow:
log stream --predicate 'subsystem == "org.nxhx.Hunch" AND category == "navkey"'
```

When attaching `lldb -p <pid>` to read live state, detach by sending
`SIGTERM` to the lldb process — `SIGKILL` takes the target down with
it. In Python breakpoint callbacks, use `frame.EvaluateExpression(...)`
rather than `interp.HandleCommand(...)` — the latter loses the frame
binding and expressions fail with `cannot find 'self' in scope`.

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
