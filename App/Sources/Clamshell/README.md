# Clamshell

Hunch's persistent markdown format and its API. A Clamshell is a folder of
markdown files plus a small amount of sidecar state — soft-deleted pages,
a per-(device, page) append-only recovery log, pasted-image assets, and
format metadata.

The format is **durable** (every atomic block ever serialized lives in the
recovery log until purged), **portable** (everything lives in the folder —
copy or sync it and the home-page pointer travels with it), **readable**
(any text editor cracks it open), and **iCloud-friendly** (few files,
append-only writes, no cross-device write contention on any single file).

---

## On-disk layout

```
<clamshell-root>/
  *.md                                       live pages
  Trash/<relpath>.md                         soft-deleted pages (mirrors source structure)
  .history/<relpath>/<device-id>.jsonl       per-(device, page) append-only recovery log
  Assets/<filename>                          pasted images
  .clamshell.json                            format metadata (home page pointer)
```

- **Live pages** are plain markdown — Hunch's parser handles toggles
  (`▸ Title` paragraphs with indented body) and template buttons via
  convention; see [Parser.swift](Parser.swift) for the surface syntax.
- **`Trash/`** mirrors the workspace's directory structure. Restoring a
  trashed page moves it back to its original path (suffixed
  `-restored-2` etc. on collision). The page's `.history/<relpath>/` dir
  travels with it — trash and restore are page-bundle moves.
- **`.history/`** has one subdirectory per page (mirroring the page's
  rel path) and inside, one JSONL log per device that has ever written
  to that page. Each device only writes its own file → zero cross-device
  contention; reads union all device files.
- **`Assets/`** holds pasted images. Visible (Notion / Obsidian
  convention) so the same file opens cleanly in any markdown viewer.
- **`.clamshell.json`** is the only format-level metadata file.
  Currently just the home-page pointer; future fields go here.

---

## The model: log as source of truth

Clamshell treats the recovery log as the source of truth for **intent**
(what content should exist and what's been deleted on purpose) and the
`.md` file as the source of truth for **order** and **current text**.
The engine ([PatchEngine.swift](PatchEngine.swift)) reconciles the
two on every page open.

### Patches

A **patch** is one record on a per-(device, page) JSONL log. Two record
kinds, distinguished by `op`:

```jsonc
{"op":"add","h":"<full-sha256>","p":"<parent-hash>"|null,"m":"<atomic markdown>","t":1714867200.123,"c":42}
{"op":"purge","h":"<full-sha256>","t":1714867200.123,"c":43}
```

- **`add`** carries content. `h` is the full SHA-256 of the canonical
  block (see
  [BlockFingerprint](../../../Packages/Editor/Sources/Editor/BlockFingerprint.swift)).
  `p` is the parent hash *at first observation* (may go stale; see
  below). `m` is the atomic markdown — the block on its own, no
  children.
- **`purge`** is a tombstone, appended at the moment of structural
  removal. The editor's `mutate(_:_:)` derives a pre→post `[EditorOp]`
  diff via `BlockTreeDiff.derive(_:_:)` and fires
  `host.documentDidChange(ops:on:)`; the host projects the batch onto
  a `Patch` (inserts → `.add`, removes → `.purge`) and routes it to
  `RecoveryLog.apply(_:to:)` for one ordered append with sequential
  counters. Removes also appear in the patches assembled by reconcile
  (unrestorable quarantines) and by the manual Recover-sheet sweep.
- **`t`** is unix seconds with millisecond precision. Used for display
  and the `since:` filter on `listPurgedBlocks`. Not the order resolver.
- **`c`** is a per-page Lamport counter, monotonically incrementing per
  device. Records compare on `(c, device-id)` lex; legacy records (no
  `c`) fall back to `t` and always lose to modern records in mixed
  comparisons — they predate the upgrade in any realistic timeline.

### Patches as the write unit

Every write to the log goes through one primitive:

```swift
public actor RecoveryLog {
    public func apply(_ patch: Patch, to rel: String) throws
}
```

A `Patch` is a batch of `add` / `purge` entries (see
[PatchEngine.swift](PatchEngine.swift)). Static factories project from
the three callers' natural shapes onto the unified type:

- `Patch.adds(from blocks: [Block])` — full-doc walks (used by
  `writeExternal`).
- `Patch.adds(from observations: [PatchEngine.Observation])` — engine
  lifts from reconcile.
- `Patch.from(ops: [EditorOp])` — editor structural diffs.

`apply` mints sequential per-page Lamport counters for each entry in
the patch, encodes them as JSONL, and appends to our device's log file
in one batched write. No write-time dedup: every entry emits a record.
Duplicate `add`s for the same hash are harmless — intent is a
latest-`(counter, deviceID)`-wins fold, so the union collapses them to
the same intent at read time. The log just gets a little chattier on
the rare `writeExternal`-style full-doc-walk callers.

### Journal

A page's **journal** is the union of every device's per-page log.
`Clamshell.readJournal(forPage:)` returns it as a `LogJournal` value —
the engine's input.

### Intent state

`PatchEngine.intent(from: journal) -> IntentState` is a pure function
that classifies every hash the journal mentions:

| Status         | Meaning                                                                 |
|----------------|-------------------------------------------------------------------------|
| `.alive`       | Latest record (across all devices, `(c, device-id)` lex) is an `add`.   |
| `.tombstoned`  | Latest record is a `purge`. Carries the prior `add` for restore display.|

`IntentState` also exposes `parent(of:)` (the latest add's `p`, useful
even on tombstoned hashes for chain climbs), `tombstones()`, and
`parentChain(from:)`.

### Reconciliation

`PatchEngine.reconcile(intent:doc:)` is the engine's main entry
point. Given the page's intent state and the doc's current children, it
produces:

- **`inserts: [Insert]`** — subtrees to splice into the doc for hashes
  the intent says are alive but the doc is missing. Each `Insert`
  carries the live ancestor's `BlockID` (resolved by climbing the
  recorded-parent chain through other alive hashes). Applied via
  `PatchEngine.apply(_:to:)`.
- **`toAppend: [Observation]`** — synthesized `add` records for blocks
  present in the doc but absent from the journal. Drives bare-md
  absorption (`.md` files with no `.history/` dir get their blocks
  logged on first open) and external-edit absorption (blocks an
  external editor wrote that no device has logged).

The contract is four rules:

1. **Existence**: a block is in `doc'` iff its hash is `.alive` in
   intent OR present in `doc` and not `.tombstoned`.
2. **Order**: blocks already in `doc` keep their order; restored
   blocks land at end-of-children under the closest live ancestor.
3. **Observation**: blocks in `doc` whose hash is absent from intent
   get a synthesized `add`.
4. **Idempotence**: `reconcile(intent ∪ toAppend, doc') == (doc', [])`.

### reconcileFromDisk: the open-doc entry point

The open-doc path uses a thin wrapper over `reconcile`:

```swift
public static func reconcileFromDisk(
    rawMarkdown: String,
    journal: LogJournal
) -> (blocks: [Block], patch: Patch, summary: ReconcileSummary)
```

Parses markdown, folds the journal, splices auto-restore inserts via a
throwaway Document, and returns:
- **`blocks`** — what the user should see (disk content with restored
  subtrees spliced in).
- **`patch`** — the single batched Patch combining observation lifts
  + unrestorable quarantines.
- **`summary`** — restored hashes / lifted hashes / unrestorable
  entries for banners and diagnostics.

`Clamshell.loadAndReconcile(at:)` composes this with file I/O, log
apply (awaited), and a debounced save (if anything was spliced). One
function for the host's open-doc path; no `isClean` gate inside, no
live-doc mutation. The output Document is fresh, identity is the
host's to assign.

The presenter-wakeup path is different: it must update the live
`Document` in place to preserve the editor's selection/cursor state,
so it still uses `WorkspaceWindow.reconcileOpenDocumentAgainstLog`,
which calls `PatchEngine.apply(_:to:)` on the live doc. That path
gates on `Clamshell.isClean(at:)` — the engine assumes
`doc.children == parsed(.md)`, only true when nothing is pending.

### Conflict merge (iCloud sibling alternates)

When iCloud Drive lands a sibling-file conflict (`<page> 2.md`,
`<page> (joe's iPad).md`), `PatchEngine.mergeConflict(survivor:
alternates: intent:)` splices any block present in an alternate but
absent from the survivor and not tombstoned in intent, under the
closest live ancestor in the merged tree. Driven by
`Clamshell.resolveConflictVersions`; called from `Workspace` at scan
time and `WorkspaceWindow.handlePresentedFileChange` for the open
page.

### Known weakness: stale parent metadata

A block's `p` records the parent observed *the first time this device
logged the block*. If the block later moves between parents on this
device, the cache short-circuits the re-record and `p` goes stale.
Restore handles this by climbing the recorded parent chain via
`IntentState.parent(of:)` until it finds a hash that's still alive,
falling back to top-level when none survive. The chain-climb is a
heuristic — moves between parents are not represented as first-class
operations in the log.

---

## Quickstart

```swift
import Foundation

let clamshell = Clamshell(root: workspaceURL)
clamshell.subpageTitleResolver = { path in ... }   // optional
clamshell.didSave = { doc in ... }                 // optional

let entries = try clamshell.scan()

// Read
let doc = try clamshell.loadDocument(at: entries[0].url)

// Editor-driven write — appends ops to the recovery log and arms the
// 600ms debounced save. Empty ops means a text-only edit. The host
// fires this on every mutation; the lifecycle is owned by Clamshell.
clamshell.documentDidChange(ops: ops, in: doc)

// Force-save (blur, scenePhase background, navigation away, shutdown).
await clamshell.flush(doc)

// Trash a page. If it was the home page, homeRelativePath gets cleared.
// The page's .history/<rel>/ dir is moved alongside the .md.
try clamshell.moveToTrash(at: doc.url)

// Recover something
let trashed = try await clamshell.listTrashedPages()
let lost = await clamshell.listLostBlocks()

// Open + reconcile in one step (host's open-doc path).
let (doc, summary) = try await clamshell.loadAndReconcile(at: url)
if summary.didChange { /* banner: "Restored N blocks..." */ }

// Engine-direct (for the presenter-wakeup path, which must mutate the
// live Document in place to preserve editor state):
let journal = clamshell.readJournal(forPage: rel)
let intent = PatchEngine.intent(from: journal)
let recon = PatchEngine.reconcile(intent: intent, doc: doc.children)
PatchEngine.apply(recon, to: doc)
var entries: [Patch.Entry] = []
for obs in recon.toAppend { entries.append(.add(hash: obs.hash, parent: obs.parent, markdown: obs.markdown)) }
for q in recon.unrestorable { entries.append(.purge(hash: q.hash)) }
try await clamshell.applyPatch(Patch(entries: entries), forPage: rel)
```

**One Clamshell per directory.** Construct with the root URL; never
reconfigure. When the user switches workspaces, throw away the
existing instance and build a new one.

---

## API

| Group | Methods |
|-------|---------|
| Path conversion | `relativePath(of:)`, `url(for:)` |
| Read | `scan()`, `loadDocument(at:)`, `loadAndReconcile(at:)`, `loadDocumentTitle(at:)`, `readRawText(at:)` |
| Editor-driven persistence | `documentDidChange(ops:in:)`, `flush(_:)`, `isClean(at:)` |
| Configuration | `subpageTitleResolver`, `didSave` (set once by the host) |
| External write | `writeExternal(_:)` for callers that didn't flow through `documentDidChange` (conflict merge, restoring a lost block into a closed page, appending to a non-open subpage) |
| Disk classification | `classifyDiskContent(at:expectingModificationDate:)` → `DiskClassification` (`.unchanged / .echo / .stomp / .external / .unreadable`) |
| Create | `createPage(title:requestedPath:blocks:)` |
| Search | `searchPages(in:query:excluding:)` |
| Trash | `moveToTrash(at:)`, `listTrashedPages()`, `restorePage(_:)` |
| Recovery log | `readJournal(forPage:)`, `applyPatch(_:forPage:)`, `listLostBlocks(filter:)`, `listPurgedBlocks(filter:since:)` |
| iCloud merge | `resolveConflictVersions(at:againstLive:)` → `ConflictResolution` (`{ salvaged, liveDocumentMutated }`) |
| Assets | `writeImage(_:)`, `resolveImage(source:)` |
| Metadata | `homeRelativePath` (read/write), `root` |

`loadDocument(at:)`, debounced editor saves (via `documentDidChange` /
`flush(_:)`), and `writeExternal(_:)` all seed the internal per-URL
content-hash ring buffer that `classifyDiskContent` reads — so the
file presenter can tell our own writes echoing back (`.echo`) from an
iCloud rollback to an earlier state (`.stomp`) from a genuine external
edit (`.external`). Callers don't have to seed anything; the ring
buffer is cleared automatically on `moveToTrash`.

The engine itself is at the same layer as Clamshell. Callers reaching
into engine territory use `clamshell.readJournal` → `PatchEngine.intent`
→ `PatchEngine.reconcile` directly.

---

## Behaviors worth knowing

**Recovery log is per-device, append-only, no write-time dedup.**
Editor mutations are projected to a `Patch` and applied as one batched
write per mutation. The log actor mints sequential per-page Lamport
counters, encodes JSONL, appends to our device's file. There's no
device-hash cache short-circuiting duplicates: callers either filter
upstream (the editor's `BlockTreeDiff` only emits ops for structural
changes; reconcile's `unloggedObservations` filters against journal
intent) or accept a small amount of log bloat (full-doc-walk callers
like `writeExternal` after a conflict merge). Intent is unchanged —
duplicate `add`s for the same hash resolve to the same alive intent at
read time, so chattier logs are correctness-equivalent.

**Log durable before file durable.** `Clamshell+Saving.swift` tracks
the most-recent log-apply Task on the pending entry. `fireScheduledSave`
and `flush` await it before writing the `.md`. At any point a crash
can happen, the log is at-or-ahead of the file on disk → reconcile
heals on next open. The save side gets a barrier; the editor's
`documentDidChange` stays synchronous so the typing path doesn't pay
an actor-hop per structural mutation.

**Cross-device merging happens on read, not write.** Each device only
ever writes its own `<device-id>.jsonl`. Other devices' files are read
but never modified. The union compares on `(c, device-id)` lex
(Lamport, clock-skew-immune); legacy records without a `c` fall back
to `t` and lose to any modern record. Tombstones from any device
suppress the hash globally when their `(c, device-id)` is the latest
pair. Counter mints rescan foreign device logs every call, so a
record sync'd in via iCloud after our last write still raises our
next mint — purges authored after observing a foreign add reliably
beat that add in the union.

**Bare-md and external edits are absorbed.** `reconcile()` emits an
`Observation` for any block present in `doc` but absent from the
journal. The open-doc path (`loadAndReconcile`) folds these into the
same Patch that carries unrestorable quarantines, applied as one log
write. A `.md` opened with no `.history/` dir gets fully logged on
first reconcile; a block an external editor wrote gets logged on the
next file-presenter wakeup.

**Live filtering.** A journal entry is only "lost" if its hash isn't
in the live page's atomic-block set right now — re-creating the same
content (e.g. a recurring `# Today` heading) makes the entry live
again automatically without any log mutation.

**Trash invalidates home.** `moveToTrash(at:)` clears
`homeRelativePath` if the trashed page was the home page. The page's
`.history/<rel>/` directory moves alongside the `.md`, so trash +
restore is a page-bundle operation.

**Editor-driven persistence is `documentDidChange` + `flush`.** The
host calls `documentDidChange(ops:in:)` on every mutation: non-empty
`ops` are appended to the recovery log, and a per-URL 600ms debounce is
(re)armed for the markdown save. `flush(_:)` cancels the debounce,
force-saves, and drains the per-URL coordinator — for blur, scenePhase
backgrounding, navigation-away, app shutdown. Post-save bookkeeping
(mtime refresh, title cache, page rescan) fires through the `didSave`
callback the host wires once at startup. `isClean(at:)` lets the
file-presenter / reconcile paths gate on "is the in-memory doc equal
to disk".

**`writeExternal(_:)` is the escape hatch.** It bypasses the
coalescer AND writes a fire-and-forget recovery-log catch-up; use it
when the next operation depends on the file being on disk now AND the
caller didn't flow through the editor op stream — conflict merge,
restoring a lost block into a closed page, appending blocks to a
non-open subpage. The internal coalesced `save` path that
`documentDidChange` schedules deduplicates concurrent writes per URL —
if a write is already in flight, the new snapshot replaces any pending
one and is written after the in-flight write completes.

**Editor mutations stream as ops.** Each `EditorView.mutate(_:_:)`
transaction derives a pre→post `[EditorOp]` diff via
`BlockTreeDiff.derive(_:_:)` and fires `host.documentDidChange(ops:on:)`.
The host's adapter calls `Clamshell.documentDidChange(ops:in:)`, which
projects the batch onto a `Patch` (inserts → `.add`, removes →
`.purge`), spawns a Task that calls `log.apply` (tracked on the
pending entry), and rearms the debounce. No pre/post tree snapshot,
no diff inference: the op stream IS the log update. The debounced
save awaits the latest log Task before writing the `.md` — log
durability is the file save's barrier.

**Deletes are explicit, not inferred.** The op diff emits a
`.remove(hash)` for every block id present in pre but absent in post.
`Patch.from(ops:)` projects those to `.purge` entries that
`log.apply` writes as `purge` records. Save paths never infer
tombstones from comparing prior state to current state. Consequences:
- Typing inside a block (same id, different hash) does NOT fire a
  purge — text editing is not deletion.
- External edits to the `.md` (iCloud / other markdown apps) surface
  missing blocks as "lost" in the Recover sheet, never as "Deleted on
  purpose" — Hunch can't infer intent from a write it didn't author.
- A block dragged across pages purges from the source's log; the
  destination's save adds it cleanly.

**Intentional deletions stay recoverable.** Manually-purged hashes
are tracked alongside "lost" entries — the union remembers both the
latest record (purge) and the latest prior `add` (carrying markdown +
parent). `listPurgedBlocks` surfaces them so the user can bring back
something they deleted on purpose. To restore, the host builds a
`Patch` with a fresh `.add` for the hash and calls
`Clamshell.applyPatch`; the new counter beats the prior purge under
`(c, device-id)` lex, lifting the tombstone from the union.
`listPurgedBlocks` defaults to a 30-day window for surface area; pass
`since: nil` to see everything.

---

## Concurrency

`Clamshell` is `@MainActor`-isolated for its mutable property
(`homeRelativePath`) and the operations that touch it
(`moveToTrash`, `restorePage`, the save paths). Path conversions, raw
reads, and asset I/O are `nonisolated`. The underlying stores are
actors (`RecoveryLog`, `TrashStore`, `DocumentSaveCoordinator`) or
stateless `Sendable` (`FileStore`); call them from background tasks
freely.

`PatchEngine` is pure — no actors, no I/O. `reconcile` and the
helpers are `@MainActor` only because they hand back / accept `Block`
values that travel between Document mutations.

Recovery-log appends are serialized inside the `RecoveryLog` actor and
wrapped in `NSFileCoordinator` to avoid racing with iCloud Drive sync.
Each device's log is single-writer-per-device, so the only realistic
concurrency is "us appending while iCloud is uploading our last
append" — `NSFileCoordinator` handles that.

---

## Files in this directory

- [Clamshell.swift](Clamshell.swift) — the umbrella API. Orchestrates
  reads/writes, hands the engine its inputs, applies the engine's
  outputs.
- [PatchEngine.swift](PatchEngine.swift) — the engine. Pure
  Sendable types: `LogJournal`, `LogRecord`, `IntentState`,
  `Reconciliation`. Pure functions: `intent(from:)`,
  `reconcile(intent:doc:)`, `insertion(rootHash:candidates:intent:doc:)`,
  `mergeConflict(survivor:alternates:intent:)`. Plus the
  `LostBlockForest` forest assembler used by both the engine and the
  host's Recover-sheet UI grouping.
- [FileStore.swift](FileStore.swift) — markdown file I/O and `Trash/`
  moves. Stateless, `Sendable`.
- [DocumentSaveCoordinator.swift](DocumentSaveCoordinator.swift) —
  per-URL serial, snapshot-coalescing actor for autosaves.
- [RecoveryLog.swift](RecoveryLog.swift) — JSONL persistence only.
  Reads return `LogJournal`s for the engine; writes go through one
  primitive, `apply(_ patch: Patch, to:)`. The only other write is
  `move(fromPage:toPage:)` for page renames. All business logic lives
  in `PatchEngine`.
- [DeviceID.swift](DeviceID.swift) — per-install UUID stored in
  `UserDefaults`. Names this device's recovery log file.
- [TrashStore.swift](TrashStore.swift) — lists `Trash/` and restores
  from it.
- [WorkspaceBookmark.swift](WorkspaceBookmark.swift) — UserDefaults
  persistence of the security-scoped URL bookmark for the user's
  chosen Clamshell folder.
- [Parser.swift](Parser.swift) / [Serializer.swift](Serializer.swift) —
  markdown ↔ `[Block]`. swift-markdown lives here, not in the
  [Editor package](../../../Packages/Editor/).
  `Serializer.serializeAtomic(_:)` emits a single block without
  children — what the recovery log stores in its `m` field.

---

## What Clamshell doesn't do

- **No UI.** The "Recover" sheet, the page list, the home-page button —
  all live in [`App/Sources/Shell/`](../Shell/) and
  [`ContentView.swift`](../ContentView.swift).
- **No observation.** Clamshell is not `@Observable`. SwiftUI
  re-render plumbing is the host's job — Hunch's shared `Workspace`
  mirrors `homeRelativePath` for SwiftUI.
- **No multi-page coordination.** "Which page is open?", "what's
  dirty?", "the navigation stack" — all on per-window
  `WorkspaceWindow`. Clamshell handles one persistent format; the
  host splits workspace-wide vs. per-window state across `Workspace`
  and `WorkspaceWindow`.
- **No restore-of-lost-block live-doc plumbing.** The engine produces
  insertion instructions; mutating the live `Document` and saving is
  the host's job (`WorkspaceWindow.restoreLostBlock`).
- **No move-as-operation.** Moving a block between parents on a device
  that already logged it doesn't append a new record. The original `p`
  goes stale; restore relies on chain-climbing through still-alive
  hashes to find a live ancestor.
- **No log compaction yet.** Logs grow unbounded. For ordinary usage
  they stay small.
