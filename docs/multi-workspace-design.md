# Multi-workspace support — design sketch

> **Superseded** by the Arbor design (`arbor://` links + mounts; see the arbor repo's `spec/urls.md` and `plan-native.md`). The `hunch://<uuid>` scheme and workspace registry described here will not be built. Retained for history.

> Stashed design notes — not implemented yet. Captures the shape of the
> change so we can return to it.

## Context

Today Hunch opens exactly one Clamshell (workspace folder) at a time. The user wants to:

1. **Manage multiple Clamshells concurrently** — each at its own point in its own
   navigation history.
2. **Support cross-workspace links** that survive the linked folder being moved
   on disk (don't hardcode absolute paths) or renamed (don't hardcode relative
   paths either — only the *content-relative* path inside the target Clamshell
   is stable).
3. **Identify Clamshells by UUID** — links carry the target's UUID, not its
   location.
4. **Maintain a registry** of Clamshells the app has observed (UUID → security-
   scoped bookmark + display name).
5. **Picker fallback** — clicking a link to an unknown workspace prompts the
   user to locate the folder; once located, mint a bookmark and remember it.
   After that, links to that workspace "just work."

This is a host-level change: the Editor package treats `pageID` as an opaque
`String` already, so cross-workspace addressing slots in by extending the
host's pageID format (and the URL it parses out of inline links) without
touching `EditorHost`'s shape.

## Design

### 1. Clamshell gets a UUID

Extend `.clamshell.json` metadata
(`App/Sources/Clamshell/Clamshell.swift:899`):

```swift
private struct Metadata: Codable {
    var id: UUID?              // NEW — minted on first open if absent
    var homeRelativePath: String?
}
```

On open, if `metadata.id == nil`, mint a fresh UUID and write it back. The ID
lives with the folder on disk — moving the folder preserves it; copying it is
the user's problem (we don't try to detect duplicates).

Expose `clamshell.id: UUID` on the `Clamshell` type for the host.

### 2. Link format — pages and blocks

Introduce a `hunch://` URL scheme for cross-workspace references, AND a
URL-fragment convention for block-level deep links — both same-workspace and
cross-workspace:

```
Page.md                              # current workspace, page
Page.md#abc123def4567890             # current workspace, specific block
hunch://<uuid>/Page.md               # other workspace, page
hunch://<uuid>/Page.md#abc123def4567890   # other workspace, specific block
```

The fragment is the **16-char BlockFingerprint prefix** — already minted
by `Packages/Editor/Sources/Editor/BlockFingerprint.swift` and used in the
recovery log. Same hash, used for a new purpose. Properties:

- Stable as long as the block content is unchanged. Edit the block → hash
  changes → the saved link breaks (graceful fallback below).
- 16 chars from SHA-256 — collision risk inside one page is negligible.
- Already computed during parse/serialize, so no new hashing pipeline.

**Graceful fallback when a block hash no longer matches anything on the
page**: navigate to the page anyway, then surface a transient banner ("Linked
block is no longer here"). The link still gets the user to the right page.
A `^block-id`–style persistent ID embedded in the markdown would be more
durable but pushes complexity into the serializer and changes file contents
— deferred.

Both classifiers need updating:

- **`Clamshell.pageID(for:relativeTo:)`** (`Clamshell.swift:160-180`) — accept
  `hunch://` URLs and preserve URL fragments. Returns:
  - `"Page.md"` or `"Folder/Page.md#abc1234567890123"` for same-workspace
    (relative path + optional fragment).
  - `"hunch://<uuid>/Page.md"` or `"hunch://<uuid>/Page.md#abc1234567890123"`
    for cross-workspace.
  - `nil` for external URLs or malformed inputs.
  Accept any well-formed `hunch://uuid/path.md` — don't reject unknown UUIDs
  at parse time; that's `openPage(pageID:)`'s job (it triggers the picker).
- **`BlockParser.detectSubpage`** (`App/Sources/Clamshell/Parser.swift:543-564`)
  — extend the predicate to accept `dest.hasSuffix(".md")` *or* `hunch://`
  URLs ending in `.md`. **But only when no fragment is present.** A
  fragment-bearing link is a *block reference*, not a child-page reference;
  it stays as an inline link rather than rendering as a subpage row.

A small helper type encapsulates parsing:

```swift
struct PageRef {
    let workspaceID: UUID?      // nil = current workspace
    let relativePath: String
    let blockHash: String?       // 16-char fragment; nil if page-level
    init?(_ pageID: String)
    var pageIDString: String     // round-trip
}
```

Lives next to the other URL helpers in `Clamshell.swift`.

### 3. Workspace registry

Replace today's single-slot bookmark with a registry:

`App/Sources/Clamshell/WorkspaceBookmark.swift` becomes
`WorkspaceRegistry.swift` (or grows alongside) — persisted as a single
UserDefaults key (`hunch.workspace.registry`) holding:

```swift
struct WorkspaceRegistry: Codable {
    var entries: [UUID: Entry]
    var activeID: UUID?         // last-opened, the implicit "current" on launch
}
struct Entry: Codable {
    var bookmark: Data          // security-scoped bookmark
    var displayName: String     // folder name at time of save
    var lastKnownPath: String   // for diagnostic display in picker
}
```

Resolution flow:
1. On launch, resolve `activeID`'s bookmark; if that fails (folder deleted/
   inaccessible), fall back to the legacy `console.workspace.bookmark` key
   once, then prompt picker.
2. On registry hit for a UUID, resolve+start security scope lazily; cache the
   live URL until app exit.
3. The legacy `console.workspace.bookmark` UserDefaults key is migrated to the
   registry on first launch with this feature (read once, write into registry
   as `activeID`, then leave the old key alone for safety).

### 4. Multi-Clamshell ownership

`Workspace` (`App/Sources/Workspace.swift`) becomes the registry-aware pool:

```swift
@Observable final class Workspace {
    private(set) var clamshells: [UUID: Clamshell] = [:]   // live, mounted
    var activeID: UUID?
    var registry: WorkspaceRegistry
    // existing: error, banner, conflictSweepRan keyed by UUID
}
```

- `mount(id:)` — if `clamshells[id]` exists, return it; else resolve bookmark
  from registry, build new `Clamshell`, store, return.
- `pickAndMount(suggestionFor: UUID?)` — present folder picker; on selection
  read `.clamshell.json`; if `id` matches the suggestion (or there's no
  suggestion), save the bookmark and mount. If the folder's `id` mismatches a
  suggested target, surface a confirmation: "This folder isn't the one this
  link points to. Use it anyway?" (records under the actual UUID, link
  remains broken).
- Security-scoped activation refcounted per Clamshell — released when the last
  reference goes away. Simplest: never release until app quit.

The Clamshell's `@Observable` `entries` / `homeRelativePath` keep working
unchanged. `Workspace.entries` and `Workspace.homeRelativePath` (the
passthroughs noted in CLAUDE.md) become passthroughs to the **active**
Clamshell — or we deprecate them in favor of `workspace.activeClamshell?.entries`.

### 5. Per-window navigation — same-window swap with frame stack

`WorkspaceWindow` (`App/Sources/WorkspaceWindow.swift`) extends from "one
clamshellID + one `path: [URL]`" to a stack of frames. **Each frame doubles
as a per-Clamshell `EditorHost` delegate**, so the host plumbing in the
Editor package doesn't need to learn about multi-workspace dispatch:

```swift
@Observable final class NavigationFrame: EditorHost {
    let clamshell: Clamshell
    var path: [URL]            // [] = that workspace's home page
    var openPage: Clamshell.OpenPage?
    var pendingScrollBlockHash: String?    // set when opening a hunch://…#hash link

    weak var window: WorkspaceWindow?      // for cross-frame ops (openPage, navigateBack)

    // EditorHost — storage / per-clamshell ops dispatch to self.clamshell:
    func persistCommit(changes: [DocumentChange], in document: Document) {
        session(for: document)?.enqueueEditorChanges(changes)
    }
    func lookupPage(_:)            { clamshell.lookupPage(...) }
    func suggestPages(_:)          { clamshell.pages(matching:) }
    func createPage(...)           { clamshell.createPage(...) }
    func resolvePageID(from:)      { clamshell.pageID(for:relativeTo:) }
    // …flush, loadPageBlocks, inlineAndTrashPage, appendToPage,
    //   moveDestination, saveImages, imageURL, link/paste/preview…

    // EditorHost — navigation ops route up to window because they may cross frames:
    func openPage(pageID: String)  { window?.openPage(pageID: pageID) }
    func navigateBack()            { window?.navigateBack() }
}

@Observable final class WorkspaceWindow {
    private(set) var frames: [NavigationFrame]
    var activeFrame: NavigationFrame { frames.last! }
}
```

Why split the protocol this way: every per-clamshell op (typing, lookup,
mention search, image resolution, etc.) is fully local to one Clamshell —
the frame is the natural owner. Only `openPage` (may cross workspaces) and
`navigateBack` (may pop frames) need cross-frame awareness, so they
delegate back up.

In the Editor wiring (`EditorView`'s `.environment(\.editorHost, host)`),
the host passed in is `window.activeFrame` — the frame *is* the host. When
the active frame changes, the EditorHost env value changes, the
NavigationStack remounts (via `.id(activeFrame.clamshellID)`), and the new
Editor instances see the new host. The `host` capture inside
`OpenURLAction` (`EditorView.swift:343-347`) still works unchanged.

State transitions, all handled on `WorkspaceWindow`:

- **Same-workspace nav** (existing flow) — mutates `activeFrame.path` via the
  Binding handed to NavigationStack.
- **Cross-workspace nav** (`hunch://<other-uuid>/path.md` click) — appends a
  new `NavigationFrame` for the target Clamshell with `path = [resolvedURL]`.
  Bind NavigationStack with `.id(activeFrame.clamshell.id)` so SwiftUI
  remounts when we cross frames (the URL domain — `file://` root — changed).
- **Back across frame boundary** — `navigateBack()` pops `activeFrame.path`
  first; when empty and `frames.count > 1`, pops the whole frame (returning
  to the prior workspace at its prior position).
- **`handlePathChange`** stays per-frame: each frame manages its own
  `openPage`/`closePage` lifecycle against its own Clamshell. The top frame's
  `handlePathChange` fires on its `path` changes; frame transitions are
  handled by `.onChange(of: activeFrame.id)` draining the outgoing frame
  before SwiftUI tears it down.

```swift
// WorkspaceWindow
func openPage(pageID: String) {
    guard let ref = PageRef(pageID) else { return }
    if let targetUUID = ref.workspaceID, targetUUID != activeFrame.clamshell.id {
        Task { await navigateToCrossWorkspace(ref) }
    } else {
        // Same-workspace push (active frame). Strip workspace, keep fragment.
        let url = activeFrame.clamshell.url(for: ref.relativePath)
        activeFrame.pendingScrollBlockHash = ref.blockHash
        if activeFrame.path.last != url {
            activeFrame.path.append(url)
        } else if ref.blockHash != nil {
            // Same page, just scroll to a new block — nudge EditorState
            activeFrame.requestScrollToPending()
        }
    }
}

private func navigateToCrossWorkspace(_ ref: PageRef) async {
    guard let clamshell = await workspace.ensureMounted(ref.workspaceID!) else { return }
    let url = clamshell.url(for: ref.relativePath)
    let frame = NavigationFrame(clamshell: clamshell, path: [url], window: self)
    frame.pendingScrollBlockHash = ref.blockHash
    frames.append(frame)
}

func navigateBack() {
    if activeFrame.path.count > 0 {
        activeFrame.path.removeLast()
    } else if frames.count > 1 {
        frames.removeLast()
    }
}
```

**Scroll-to-block on open**: when a frame's `pendingScrollBlockHash` is
non-nil at the point `openPage` completes loading the Document, the host
resolves `hash → BlockID` (Clamshell can serve this: it has BlockFingerprint
during parse) and pokes the frame's `EditorState` with a scroll request. The
Editor consumes the request on first layout and clears it. If the hash
matches no block, surface a transient banner.

Security-scoped resource: held per Clamshell while it's in
`Workspace.clamshells`. Simplest policy: once mounted, stay mounted until app
quit. No refcounting on frame pops.

### 6. Unknown-workspace picker

`workspace.ensureMounted(_ id: UUID) async -> Clamshell?` flow:

1. If `clamshells[id]` is already mounted → return it.
2. If `registry.entries[id]` exists → resolve bookmark, mount, return.
3. Else → present the locate-workspace sheet: "This link points to a
   workspace Hunch hasn't seen before. Locate the folder."
   - Folder picker → read `.clamshell.json` →
   - If `id` matches the requested UUID, save bookmark to registry, mount,
     return.
   - If UUID mismatches, show confirm-or-cancel ("This folder isn't the one
     this link points to. Use it anyway?"). Confirm → records under the
     folder's actual UUID; the link stays broken (so we don't silently bind
     a wrong workspace). Cancel → return nil.
4. Cancellation propagates as `nil`; the caller (`navigateToCrossWorkspace`)
   silently aborts and surfaces a non-fatal banner ("Couldn't open link to
   unknown workspace").

The picker UI is a small SwiftUI sheet (`LocateWorkspaceSheet`) — fits next
to `MoveDestinationSheet` in `App/Sources/Shell/`. The sheet binds via a
`CheckedContinuation` on the `WorkspaceWindow`, mirroring how
`moveDestination(for:candidates:)` already works.

### 7. Workspace switcher + File menu

Three affordances for explicitly working with the registry:

- **File → Open Workspace…** (`App/Sources/HunchApp.swift` commands) — folder
  picker that calls `workspace.pickAndRegister()`. New folder → mint UUID +
  write `.clamshell.json` + add to registry. Existing folder → read existing
  UUID + add to registry. Either way, push a new frame in the front window
  (or open a new window if none) onto that workspace's home.

- **In-window workspace switcher** — a toolbar item on `ContentView` (top
  leading): a menu showing the active workspace name with a chevron, opens
  to a list of all registered workspaces + "Open Workspace…" at the bottom.
  Selecting a different workspace pushes a frame for that workspace's home
  onto the current window. The active workspace's display name comes from
  `registry.entries[activeFrame.clamshell.id].displayName` (set to the
  folder name at registration time; user-renamable later — out of scope for
  v1).

  Keyboard: Cmd+1…Cmd+9 jump to the N-th registered workspace (push frame to
  its home). Convention copied from browsers/Slack.

### 8. Copy Link menu items

Two new commands for generating shareable links to the current location:

- **File → Copy Link to Current Page** (Cmd+Shift+L) — copies a markdown
  link `[<Page Title>](hunch://<uuid>/<path>.md)` to the clipboard. Always
  uses the `hunch://` form (regardless of pasting back into same workspace
  or different) so the link is location-stable. Available whenever a page
  is open; disabled on home if home has no relativePath yet.

- **File → Copy Link to Selected Block** (Cmd+Option+Shift+L) — copies
  `[<Page Title> › <block excerpt>](hunch://<uuid>/<path>.md#<hash16>)`.
  - Enabled when `state.sessionState` is `.navigating` with exactly one
    block selected, OR `.editing(blockID, _)` (the editing block is the
    target).
  - `<block excerpt>` is the first ~60 chars of the block's plain-text
    content, with newlines/markup stripped, trailing `…` if truncated.
  - `<hash16>` is the BlockFingerprint 16-char prefix computed live from the
    block's serialized form (Clamshell's existing fingerprint pipeline).
  - Implemented as an `EditorHost` method (`host.copyLinkToSelectedBlock()`)
    so the keybinding lives in `EditorView+Wiring.swift` and dispatches
    through `EditorCommands` — same plumbing as the rest of the nav-mode
    shortcuts.

Both items also accessible via the right-click context menu on a page (in
the workspace switcher dropdown / page tab area) and on a block row.

### 9. Out of scope for first cut (call out, don't implement)

- Cross-workspace @-mentions (mention picker stays current-workspace-only).
- Cross-workspace move-to / inline-and-trash / drop-on-subpage (the host
  methods that touch storage stay within one Clamshell).
- Cross-workspace link decoration (showing the target workspace's icon/name
  next to inline cross-workspace links). Initial render just shows the title
  if we can resolve it, falls back to the path.
- Persistent block IDs (Obsidian-style `^id` markers). v1 uses content hash
  with graceful fallback when content drifts.
- Block-link decoration showing the block excerpt inline (we resolve title
  from the link text the user already pasted). Auto-derive of fresher
  excerpt on hover/render is a follow-up.
- Workspace rename UI in the registry.

## Critical files

| Concern | File |
|---|---|
| UUID in metadata | `App/Sources/Clamshell/Clamshell.swift` (`Metadata` struct ~L899, init ~L101) |
| pageID classifier | `App/Sources/Clamshell/Clamshell.swift` (`pageID(for:relativeTo:)` L160) |
| Subpage parse classifier | `App/Sources/Clamshell/Parser.swift` (`detectSubpage` L543) |
| Subpage serializer | `App/Sources/Clamshell/Serializer.swift` (`.subpage` case L140) |
| Registry / bookmarks | `App/Sources/Clamshell/WorkspaceBookmark.swift` (replace single-slot) |
| Pool of Clamshells | `App/Sources/Workspace.swift` |
| Window → workspace binding + frame stack | `App/Sources/WorkspaceWindow.swift` |
| Per-frame EditorHost delegate | `App/Sources/WorkspaceWindow.swift` (new `NavigationFrame` type) + `App/Sources/WorkspaceWindow+EditorHost.swift` (move per-clamshell methods onto `NavigationFrame`) |
| Cross-workspace open + scroll-to-block | `App/Sources/WorkspaceWindow.swift` (`openPage`, `navigateToCrossWorkspace`, `navigateBack`) |
| NavigationStack remount on frame change | `App/Sources/ContentView.swift` (NavigationStack `.id(activeFrame.clamshell.id)`, host env = `activeFrame`) |
| File menu + commands (incl. Copy Link to Page / Block) | `App/Sources/HunchApp.swift` |
| Workspace switcher toolbar | `App/Sources/ContentView.swift` (top-leading toolbar item) |
| Block link keybinding wiring | `Packages/Editor/Sources/Editor/EditorView+Wiring.swift` (Cmd+Option+Shift+L) + new `EditorAction.copyLinkToSelectedBlock` |
| New: locate-workspace sheet | `App/Sources/Shell/LocateWorkspaceSheet.swift` |
| New: `PageRef` parser (uuid + path + #hash) | `App/Sources/Clamshell/Clamshell.swift` (inline next to existing pageID helpers) |

## Reused utilities

- `DeviceID` pattern (`App/Sources/Clamshell/DeviceID.swift`) — UUID-in-
  UserDefaults — informs the registry's UUID handling but we don't share
  storage.
- `WorkspaceBookmark` security-scoped bookmark create/resolve — becomes the
  per-entry helper in the new registry.
- `Clamshell.pageID(for:relativeTo:)` — single existing classifier we extend
  rather than duplicate.
- `OpenURLAction` interceptor in `EditorView.swift:343` already routes through
  `host.resolvePageID(from:)` → `host.openPage(pageID:)` — no Editor changes
  needed.

## Verification

1. **Single-workspace regression**: Open the existing workspace, navigate via
   subpage taps, inline links, search sheet, mentions. Confirm nothing
   regresses; the only on-disk change should be a new `id` field in
   `.clamshell.json`.
2. **Bootstrap a second workspace**: File → Open Workspace… (or whatever
   affordance we add) on a fresh folder. Confirm both registry entries persist
   across launches.
3. **Cross-workspace link, happy path**: In workspace A, hand-write
   `[Other page](hunch://<B-UUID>/Page.md)` (B already registered). Click.
   Same window swaps to B, shows `Page.md`. Cmd+[ (back) returns to A's prior
   state. Forward + back across the frame boundary several times — workspace
   B's nav state should be preserved when revisiting from A's back-stack.
4. **Cross-workspace link, unknown UUID**: Hand-write a `hunch://` link to a
   UUID not in the registry. Click → locate-workspace sheet appears. Pick the
   folder. `.clamshell.json` is read, UUID matched, bookmark saved, frame
   swaps. Quit + relaunch + click the same link → swaps directly, no picker.
5. **Mismatched folder picked**: In step 4, pick a folder whose
   `.clamshell.json` has a different UUID. Confirm the disambiguation prompt
   appears and we don't silently bind the wrong workspace.
6. **Moved workspace**: Pick a workspace, quit, mv the folder, relaunch. The
   stale bookmark should still resolve via security-scoped bookmark's
   tracking-via-inode behavior (this is macOS's built-in benefit and the
   reason for using bookmarks). Confirm.
7. **Switcher + File menu**: File → Open Workspace… picks a fresh folder; it
   becomes a frame on the front window. The toolbar switcher lists all
   registered workspaces; selecting one pushes a frame for its home. Cmd+1/2
   jumps to the first/second registered workspace.
8. **Frame stack edge cases**: Cross-link A→B→A→C. Confirm back-nav unwinds
   correctly. Confirm `handlePathChange` drives openPage/closePage on the
   right Clamshell during frame transitions (no leaked file presenters,
   pending saves drain on outgoing).
9. **Block links — same workspace**: Select a block in nav mode →
   Cmd+Option+Shift+L → paste into another page. Click the new link →
   navigates and scrolls to the source block. Edit the source block →
   click stale link → page opens, banner explains the block moved/changed.
10. **Block links — cross workspace**: Same flow but pasted into a page in
    workspace B. Click → swaps to A, scrolls to the block.
11. **Copy Link to Current Page**: Cmd+Shift+L on any page → paste into
    another workspace's page → click → cross-workspace navigation works.
    Paste back into the same workspace → click → same-workspace navigation
    works (the `hunch://` form resolves to "same workspace" automatically
    in `openPage`).
12. **Block-link doesn't render as subpage row**: Place a fragment-bearing
    link on a line by itself — confirm it renders inline, not as a subpage
    row.
13. **Tests**: Extend `App/Tests/HunchUnitTests/` with cases for the
    `PageRef` parser (all four shapes — same-WS page, same-WS block, cross-WS
    page, cross-WS block, plus malformed inputs), the Metadata UUID
    migration (load a `.clamshell.json` without `id` → see one minted), and
    `pageID(for:relativeTo:)` classifying `hunch://` URLs correctly with and
    without fragments. Also cover `BlockParser.detectSubpage` rejecting
    fragment-bearing links.
14. **SPM Editor tests**: `swift test --package-path Packages/Editor` should
    still be green. The `EditorAction.copyLinkToSelectedBlock` addition is
    one new enum case + one dispatch arm — likely no test surface to update
    inside the package, but verify.
