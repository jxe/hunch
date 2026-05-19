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
    `entries / entry(at:) / rescan / lookupPage / pages(matching:) /
    loadDocument(at:) / readBlocks(at:) / openPage / closePage /
    commit / flush / inlineAndTrash / createPage /
    moveToTrash / listTrashedPages / restorePage / listLostBlocks /
    listPurgedBlocks / resolveConflictVersions / homeURL /
    homeRelativePath / isHome / setHome`, plus `relativePath(of:)`,
    `url(for:)`, and `pageID(for:relativeTo:)` for path conversion
    (the inline-link URL classifier lives next to the other URL ↔
    pageID helpers so they share one home).
    Internal helpers (`reconcileLive`, `classifyDiskContent`,
    `isQuiescent`) and the `log` actor drive the engine from inside the
    module and aren't part of the host surface. **Journal records have three ops**: `add` (authoritative
    — claim authorship), `purge` (authoritative — tombstone), and
    `observe` (tentative — snapshot of a block seen in `.md` without
    claimed authorship; written by reconcile for unlogged-but-in-doc
    blocks). Only `add`/`purge` drive `.alive`/`.tombstoned` intent;
    `observe` produces `.observed` (recoverable via Recover sheet but
    not auto-restore-eligible). **`PatchEngine.reconcile` takes an
    `mdMtime` parameter** and uses it to gate both auto-restore inserts
    (skip if `add.t < mdMtime` — trust the .md) and auto-removes (skip
    if `purge.t < mdMtime` — likely an external re-add). Engine emits
    `removes` for tombstoned-but-still-in-doc subtrees so doc converges
    to the journal when peer purges arrive after the user's stale-state.
    The journal fold uses a watermark fast path
    (`RecoveryLog.reconcileAgainst`) — per-page `(deviceLog stats, .md
    mtime)` cached in `UserDefaults` lets the steady-state open skip
    every journal read; foreign-log growth triggers a tail read from
    the watermark offset rather than a full re-fold; only an external
    `.md` edit or a shrinking log forces a full read. Saves refresh
    the watermark via `RecoveryLog.recordOwnSave` so our own writes
    don't trigger spurious refolds. **Clamshell is `@Observable`**: `entries` and
    `homeRelativePath` are tracked properties; SwiftUI re-renders
    automatically when scan / title cache / home changes. The title
    cache populates lazily through `lookupPage` cache misses
    (`requestTitleWarm` off-MainActor, deduped on `pendingTitleWarms`)
    — never eagerly on rescan, because each iCloud cold-cache read
    costs ~1s and 50× of that would stall the home page open. Post-
    save bookkeeping (mtime refresh, title update from the live
    `Document`, selective rescan) all live inside Clamshell — the host
    doesn't thread any callbacks through it. **One write API:**
    `commit(_:to:)` is the unified commit primitive — applies
    the `Commit`'s log entries to the recovery log when non-empty,
    then serializes and writes the `.md`, in one awaited sequence
    per call; `flush(_:)` awaits the chain head without triggering
    work (blur / scenePhase / navigation). Every flow — editor
    commit, reconcile catch-up, manual restore, conflict-merge,
    subpage append — projects to a `Commit` value (log entries + a
    `CommitSummary` the host displays) and calls `commit(_:to:)`.
    Concurrent calls for the same URL are chained on `saveChain[url]`
    — each spawned Task awaits the previous before its own log apply
    + file write, and the top-level `await` returns when *this*
    commit's bytes are durable. No debounce, no `.armed` state: every
    `Document.transaction` (typing via `commitLiveText`, structural
    via `mutate(_:_:)`, undo, redo) computes its pre→post diff and
    fires `Document.didCommitTransaction`, which the editor forwards
    to `EditorHost.persistCommit` (sync, typing-thread-safe); the
    host bridge wraps that in a Task that calls
    `clamshell.commit(_:to:)` and awaits durability. That's the
    single save event. The "log durable before file durable"
    invariant is preserved structurally: every `commit` runs log
    apply strictly before file write inside one Task. **Internal
    in-place mutations** (reconcile auto-restore splice, manual-
    restore splice) commit with `Commit(logEntries: [])` — no log
    apply (journal already current), just an awaited `.md` write
    through the same chain. `moveToTrash`
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
    `workspace.homeRelativePath` are passthroughs. The closed-page
    conflict sweep (`resolveConflictsForClosedPages`) is deferred —
    `rescan()` no longer fires it; `WorkspaceWindow.handlePathChange`
    calls `scheduleConflictSweepIfNeeded()` after the first successful
    `openPage` so the 49× `NSFileVersion` query doesn't race the
    home-page load. Cmd-R uses `rescan(includeConflictSweep: true)`.
  - `App/Sources/WorkspaceWindow.swift` — per-window navigation and
    edit-session state, AND the `EditorHost` implementation: `path: [URL]`
    (NavigationStack), `openDocument` (computed from a stored
    `openPage: Clamshell.OpenPage?`), move-to request plumbing.
    `handlePathChange` is the choreography: drain prior page via
    `clamshell.closePage(_:)`, then `await clamshell.openPage(at:)`
    which returns the parsed Document + presenter handle (two
    presenters per page: one on the `.md`, one on `.history/<rel>/`
    so peer-log syncs trigger reconcile even without an accompanying
    `.md` change). The journal
    fold (auto-restore of lost subtrees) is deferred — `openPage`
    spawns a background reconcile Task and surfaces any restores via
    `onEvent(.restored(count:))`, same as a presenter-wakeup restore.
    The host methods (`openPage`, `persistCommit`, `flush`, …) live on the
    same type and forward to `Clamshell`. The host's `persistCommit`
    conforms to `EditorHost`; internally it spawns a Task that calls
    `clamshell.commit(.fromEditorOps(ops), to: doc)` so durability is
    awaited while keeping the editor's sync hook contract intact. Move-to is
    async — the editor `await`s `host.moveDestination(for:candidates:)`,
    the host bridges to the sheet via a `CheckedContinuation`.
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
- `.claude/skills/`, `tasks/`, `docs/` — per-project Claude skills, unordered
  upcoming task notes, and accumulated working notes.

## Build & test

The full build / test loop lives in [CONTRIBUTING.md](CONTRIBUTING.md). The
short version: `swift test --package-path Packages/Editor` for the SPM
tests; `xcodegen generate --spec project.yml --project .` to refresh the
Xcode project (it's gitignored — don't hand-edit); `xcodebuild … -scheme
Hunch -destination 'platform=macOS'` to build, then `./scripts/run.sh` to
launch the freshest macOS build.

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
Subpage taps fire `host.openPage(pageID: path)` →
`window.openSubpage` and append to `path`, pushing deeper.
Search-sheet activation (`window.navigateFromSearch`) pushes a single
entry on top of home (or drains to root when the picked page *is*
home). `window.goBack()` pops; on iOS this is also driven by
edge-swipe-from-left, on macOS by the Cmd+[ menu and the system back
chevron. Subpage rows are the existing render path: a paragraph that
is a single `.md` link is detected in `BlockParser` (Clamshell owns
the `.md` convention) and rendered via `subpageRow` in `BlockRow.swift`.
**Inline `[text](url)` clicks inside read-only body text** route
through an `OpenURLAction` interceptor *inside* `EditorView` (so the
editor owns its link routing). The editor classifies the URL via
`host.resolvePageID(from:)` — the *same* hook used at render time (to
decorate internal-vs-external inline links) and at Cmd-K-on-link time
(to decide subpage-creation). Internal hits dispatch to
`host.openPage(pageID:)`; external URLs fall through to the system
handler via `OpenURLAction.systemAction`. One classifier, one source
of truth; the editor is storage-agnostic about what counts as an
internal page. The Hunch
impl forwards to `Clamshell.pageID(for:relativeTo:)`; external URLs
return `nil`, the editor falls through to the system handler. Inline
link taps *inside* an active TextEditor are not yet intercepted
(NSTextView / UITextView own those gestures).

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
`commit(_:to:)` is the single primitive — applies the `Commit`'s
log entries to the recovery log when non-empty, then serializes and
writes the `.md`, in one awaited sequence per call. Concurrent calls
for the same URL chain on `saveChain[url]` so a rapid burst (typing
commit → focus blur → navigation) lands in order; the top-level
`await` returns when *this* commit's bytes are on disk. `flush(_:)`
awaits the chain head without triggering work. Every flow projects
to a `Commit`: editor commits via `Commit.fromEditorOps(ops)`,
reconcile via `Reconciliation.asCommit()`, manual restore /
conflict-merge / subpage-append build the value directly. No
debounce, no `.armed` / queued state machine, no separate log-apply
Task: edit-session commit points (`commitLiveText` for typing;
`mutate(_:_:)` for structural ops) are themselves the save events.
The "log durable before file durable" invariant is preserved
structurally — the log apply runs inside the same Task before the
file write. Crash recovery is trivial: reconcile heals any divergence
on next open. Post-save bookkeeping (mtime, title cache,
rescan-when-title-changed) runs inside Clamshell's
`postSaveBookkeeping(_:)` — fired by every successful commit. No
host hook is needed; Clamshell is `@Observable` and SwiftUI re-
renders pick up new entries/title state directly.

**Every edit funnels through `Document.transaction`.** The transaction
snapshots `children` *before* `preMutation` fires (so the snapshot
captures pre-typing state), runs `preMutation` (which flushes the live
editor's text through a nested transaction), runs the change closure,
re-enforces heading containment, snapshots `children` again, derives
the pre→post diff via `BlockTreeDiff.derive(_:_:)`, and fires
`Document.didCommitTransaction` with the diff. Forward, undo, and redo
all funnel through the same hook — undo with the *inverted* diff so
the journal stays symmetric across the round-trip. Nested transactions
absorb into the outer (no new undo entry, no diff fired); the outer's
diff already covers their changes.

**`Document.didCommitTransaction` is the editor's single emission
point.** Wired in `EditorView.installUndoApply` to revalidate
`EditorState` against the new block set and forward the ops to
`host.persistCommit(ops:on:)`. Both `EditorView.mutate(name:_:)`
(structural) and `BlockTextEditor.Coordinator.commitLiveText` (typing)
ultimately call `Document.transaction`, which fires the hook. Empty
diff = pure reorder/move (id+hash stable); the host still persists
the new tree shape from the same call.

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

General platform / toolchain constraints (iOS 26 + macOS 26 min, single
multiplatform target, swift-tools 6.2, no code signing, swift-markdown as
only third-party dep) are in [CONTRIBUTING.md](CONTRIBUTING.md). The
constraint worth always having in context, because it shapes parser
changes:

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
- **swift-markdown's `MarkupFormatter.format()` normalises surface
  syntax** — we accept that and don't try byte-exact preservation.

## Notion typography target

Pre-March-2026 Notion. **Don't use `react-notion-x`'s CSS as truth** —
its values diverge from real Notion. Reference screenshots and the
constants file location are documented in
[CONTRIBUTING.md](CONTRIBUTING.md); the rule worth keeping in context is
that **constants live in `NotionStyle.swift`** (both the `NotionStyle`
enum and the `BlockSpacing` enum) — don't sprinkle magic numbers into
`BlockRow.swift`.

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
