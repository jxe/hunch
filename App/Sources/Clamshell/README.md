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
  `writeClosedPage(_:patch:)` and `append(_:toPage:)`).
- `Patch.adds(from observations: [PatchEngine.Observation])` — engine
  lifts from reconcile.
- `Patch.from(ops: [EditorOp])` — editor structural diffs.

`apply` mints sequential per-page Lamport counters for each entry in
the patch, encodes them as JSONL, and appends to our device's log file
in one batched write. No write-time dedup: every entry emits a record.
Duplicate `add`s for the same hash are harmless — intent is a
latest-`(counter, deviceID)`-wins fold, so the union collapses them to
the same intent at read time. The log just gets a little chattier on
the rare full-doc-walk callers (`writeClosedPage(_:patch:)` after a conflict
merge, `append(_:toPage:)` for subpage drops).

### Journal

A page's **journal** is the union of every device's per-page log.
`RecoveryLog.readJournal(page:)` returns it as a `LogJournal` value —
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

### Reconciliation paths

Hosts don't call reconcile directly. `openPage(at:onEvent:)` returns
as soon as the `.md` is loaded + parsed; the journal fold runs in a
background Task and fires `onEvent(.restored(count:))` if anything
was spliced. Deferring the fold keeps the home-page critical path
clear of the per-device JSONL iCloud reads, and the common case has
nothing to restore. Presenter-wakeup reconcile fires from the
internal file presenter on every wakeup and mutates the live
`Document` in place to preserve editor selection / cursor state.
Both paths go through `reconcileLive(_:)`, which gates on
`isQuiescent(at:)` — if the page isn't settled (a save chain entry
is still pending), it returns nil and the next wakeup retries after
the save lands. Log apply is awaited strictly before the file save
fires either way — the at-or-ahead invariant holds across crashes.

**Watermark fast path.** `RecoveryLog.reconcileAgainst(page:doc:mdMtime:)`
short-circuits the fold using per-page watermarks stored in
`UserDefaults` next to `DeviceID`. The watermark records, per device:
the log file's `(size, mtime)` at the time of our last fold, plus the
`.md` mtime then. On entry, stat each device log + the `.md`. Three
branches:

1. **Skip** — every device watermark and `.md` mtime match → no I/O
   beyond stat, the fold returns empty. Steady-state opens (nothing
   has changed since last time) cost a few milliseconds total.
2. **Tail** — `.md` mtime matches but one or more foreign logs grew →
   tail-read each grown file from its watermarked size to EOF, parse
   only the delta, build splice candidates with the records we just
   read in hand (their `m` carries the markdown). Bare-md absorption
   is skipped on this branch — the `.md` is unchanged, so the prior
   full fold already covered everything in the doc.
3. **Full** — no watermark, or `.md` changed externally, or a foreign
   log shrunk / disappeared (cache invalid for that device). The
   classic `readJournal` + `PatchEngine.intent` + `PatchEngine.reconcile`
   path, with full bare-md absorption and quarantine.

After every non-skip branch the watermark is refreshed. Our own
saves call `RecoveryLog.recordOwnSave(page:mdMtime:)` from
`postSaveBookkeeping` so the new `.md` mtime + grown own-log size
are captured immediately — the next open sees a match and skips
without ever opening a journal file.

**What the tail branch deliberately doesn't reconstruct.** Auto-
restore and the Recover sheet only care about "alive in journal,
missing from doc." We don't need a Lamport-correct `IntentState`
across the entire history — only across the records we observe in
the unread tails. Edge cases where ordering matters (delete-then-re-
add on different devices, observed in non-Lamport order via two
syncs) self-heal as more records arrive: on the next fold, the
later record dominates and the candidate flips. Auto-restore at
open time isn't sensitive to that transient inconsistency.

### Conflict merge (iCloud sibling alternates)

When iCloud Drive lands a sibling-file conflict (`<page> 2.md`,
`<page> (joe's iPad).md`), `PatchEngine.mergeConflict(survivor:
alternates: intent:)` splices any block present in an alternate but
absent from the survivor and not tombstoned in intent, under the
closest live ancestor in the merged tree. Driven by
`Clamshell.resolveConflictVersions`; called from Clamshell's internal
file-presenter wakeup (`Clamshell+Presenter.swift`) for the open page
and from `Workspace.resolveConflictsForClosedPages` for closed pages.
The closed-page sweep is **deferred until after the first successful
`openPage`** (kicked by `Workspace.scheduleConflictSweepIfNeeded()` from
`WorkspaceWindow.handlePathChange`), so the 49× `NSFileVersion`
query never competes with the home-page open for MainActor. Cmd-R's
`Workspace.rescan(includeConflictSweep: true)` forces the sweep
synchronously for user-driven reloads.

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

// Scan to populate `entries`. `entries` and `homeRelativePath` are
// `@Observable` properties — SwiftUI views read them directly and
// re-render when scan / title / home changes.
_ = try clamshell.rescan()

// Open a page: load + parse the `.md`, install the file presenter,
// return immediately. The journal fold runs in a background Task
// after openPage returns — `.restored` fires later if anything was
// auto-spliced. `.conflictMerged` fires from presenter wakeups when
// iCloud delivers a sibling-version conflict.
let open = try await clamshell.openPage(at: url) { event in
    switch event {
    case .restored(let n): // show "Restored N blocks..." banner
    case .conflictMerged(let n): // show "Merged N blocks..." banner
    case .externallyReloaded, .noteworthyNothing: break
    }
}

// Editor-driven write — commit-time atomic save. Non-empty ops are
// applied to the recovery log; then the .md is serialized and written.
// Calls for the same URL chain so concurrent commits land in order.
// Empty ops still saves the .md (used by reconcile/restore paths after
// they splice into a live doc).
clamshell.documentDidChange(ops: ops, in: open.document)

// Force-save (blur, scenePhase background, navigation away, shutdown).
await clamshell.flush(open.document)

// Symmetric inverse of openPage: flush + tear down the presenter.
await clamshell.closePage(open)

// Trash a page. If it was the home page, homeRelativePath gets cleared.
// The page's .history/<rel>/ dir is moved alongside the .md.
try clamshell.moveToTrash(at: open.document.url)

// Recover something
let trashed = try await clamshell.listTrashedPages()
let lost = await clamshell.listLostBlocks()

// Restore one lost or purged block (host passes `openDocument` so the
// splice mutates the live doc when the source page is open).
_ = try await clamshell.restore(.lost(entry), liveDoc: openDocument)
```

**One Clamshell per directory.** Construct with the root URL; never
reconfigure. When the user switches workspaces, throw away the
existing instance and build a new one.

---

## API

| Group | Methods |
|-------|---------|
| Path conversion | `relativePath(of:)`, `url(for:)` |
| Read | `loadDocument(at:)` |
| Page list (observable) | `entries`, `rescan()`, `lookupPage(_:)`, `pages(matching:excluding:)` |
| Open / close a page | `openPage(at:onEvent:)` → `OpenPage` (`{document}`), `closePage(_:)`. Load + parse + install presenter on open (journal fold runs deferred in a background Task, fires `onEvent(.restored)` if anything was auto-spliced); flush + tear down on close. |
| Editor-driven persistence | `documentDidChange(ops:in:)` (every commit; applies op batch to log and writes `.md` atomically per call, chained per URL), `flush(_:)` (await chain head + drain; for blur / scenePhase / navigate-away). |
| Non-editor write | `append(_:toPage:)` for appending blocks to a non-open subpage. Sequences log-then-file. |
| Restore | `restore(_:liveDoc:)` — the Recover-sheet entry point for both lost and purged blocks. |
| Create | `createPage(title:requestedPath:blocks:)` |
| Trash | `moveToTrash(at:)`, `listTrashedPages()`, `restorePage(_:)` |
| Recovery log | `listLostBlocks(filter:)`, `listPurgedBlocks(filter:since:)` |
| iCloud merge | `resolveConflictVersions(at:againstLive:)` → `ConflictResolution` (`{ salvaged, liveDocumentMutated }`) |
| Assets | `writeImage(_:)`, `resolveImage(source:)` |
| Metadata (observable) | `homeRelativePath`, `root` |

Every read/write path internally seeds a per-URL content-hash ring
buffer that the file presenter classifies against — echo (our write
came back) vs stomp (iCloud rolled us back) vs external (a different
editor wrote). Callers don't have to seed anything.

Engine orchestration (`reconcile`, `reconcileLive`, conflict-merge
wakeups, save chain) is internal to the module — see the Swift
docstrings in `Clamshell.swift`, `Clamshell+Reconcile.swift`, and
`Clamshell+Presenter.swift`.

---

## Behaviors worth knowing

**Title cache populates lazily.** `entries` carries a per-URL
title overlay on top of the raw scan result — cached titles win,
filename-derived fallback otherwise. The cache is **not** warmed at
scan time. Instead, `lookupPage(_:)` cache misses spawn a single-URL
off-MainActor warm (`requestTitleWarm`, deduped on
`pendingTitleWarms`); when the read + parse lands, the cache write
triggers an `@Observable` re-render and the next `lookupPage` returns
the resolved title. The eager-sweep alternative (read every `.md` on
rescan) costs ~1s/file on iCloud and dominated the workspace-open
critical path. On-demand warm trades that for a per-subpage-row
warm-up on first render — search-sheet rows for un-warmed pages
display the filename until clicked or rendered. Save-time
`postSaveBookkeeping` (`refreshTitleCache(from:)`) updates the cache
from the live `Document` directly — no disk read.

**Recovery log is per-device, append-only, no write-time dedup.**
Editor mutations are projected to a `Patch` and applied as one batched
write per mutation. The log actor mints sequential per-page Lamport
counters, encodes JSONL, appends to our device's file. There's no
device-hash cache short-circuiting duplicates: callers either filter
upstream (the editor's `BlockTreeDiff` only emits ops for structural
changes; reconcile's `unloggedObservations` filters against journal
intent) or accept a small amount of log bloat (full-doc-walk callers
like `writeClosedPage(_:patch:)` after a conflict merge). Intent is unchanged —
duplicate `add`s for the same hash resolve to the same alive intent at
read time, so chattier logs are correctness-equivalent.

**Log durable before file durable.** Every `documentDidChange` runs
log apply + file write inside a single Task, log first. At any point
a crash can happen, the log is at-or-ahead of the file → reconcile
heals on next open. The editor's `documentDidChange` entry stays
synchronous (it spawns the Task and returns); only the chained Task
pays the I/O.

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

**Bare-md and external edits are absorbed.** Reconcile emits an
`Observation` for any block present in `doc` but absent from the
journal, folded into the same batched Patch as unrestorable
quarantines. A `.md` opened with no `.history/` dir gets fully logged
on first reconcile; a block an external editor wrote gets logged on
the next file-presenter wakeup.

**Live filtering.** A journal entry is only "lost" if its hash isn't
in the live page's atomic-block set right now — re-creating the same
content (e.g. a recurring `# Today` heading) makes the entry live
again automatically without any log mutation.

**Trash invalidates home.** `moveToTrash(at:)` clears
`homeRelativePath` if the trashed page was the home page. The page's
`.history/<rel>/` directory moves alongside the `.md`, so trash +
restore is a page-bundle operation.

**Editor-driven persistence is `documentDidChange` + `flush`.** The
host calls `documentDidChange(ops:in:)` at every commit point: non-
empty `ops` are applied to the recovery log, then the `.md` is
serialized and written, in one awaited sequence per call. Calls for
the same URL chain so a fast burst (typing commit → focus blur →
navigation) lands in order. `flush(_:)` awaits the chain head and
drains the per-URL coordinator — for blur, scenePhase backgrounding,
navigation-away, app shutdown. Post-save bookkeeping (mtime refresh,
title cache, page rescan) fires internally on every successful save;
closed-doc paths (conflict merge, closed-page restore, drop-on-subpage
append) get the same bookkeeping for free.

**`append(_:toPage:)` is the non-editor public write path.** Awaits
the log apply strictly before the file write. Used by drop-on-subpage
to add blocks to the end of a closed page. Closed-page writes don't
go through `saveChain` (there's no live editor session to chain
against); they write directly and await durability inline.

**Editor mutations stream as ops.** Every `Document.transaction`
(forward and undo/redo) derives a pre→post `[EditorOp]` diff via
`BlockTreeDiff.derive(_:_:)` and fires
`Document.didCommitTransaction`, which the editor wires to
`host.documentDidChange(ops:on:)`. The host's adapter calls
`Clamshell.documentDidChange(ops:in:)`, which projects the batch onto
a `Patch` (inserts → `.add`, removes → `.purge`) and runs log apply +
file write atomically. Typing goes through the same path:
`commitLiveText` opens a `transaction(name:"Type", coalesceKey:)` and
the resulting diff flows through the same hook. Undo and redo fire it
too with the (inverted) diff so the journal stays symmetric. No
pre/post tree snapshot on the host side, no diff inference — the op
stream is the log update.

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
something they deleted on purpose. To restore, the host calls
`Clamshell.restore(.purged(entry), liveDoc:)`; internally, a fresh
`.add` for the hash gets appended to the log, and the new counter
beats the prior purge under `(c, device-id)` lex, lifting the
tombstone from the union.
`listPurgedBlocks` defaults to a 30-day window for surface area; pass
`since: nil` to see everything.

---

## Concurrency

`Clamshell` is `@MainActor`-isolated for its mutable property
(`homeRelativePath`) and the operations that touch it
(`moveToTrash`, `restorePage`, the save paths). Path conversions, raw
reads, and asset I/O are `nonisolated`. The underlying stores are
actors (`RecoveryLog`, `TrashStore`) or stateless `Sendable`
(`FileStore`); call them from background tasks freely. Per-URL save
ordering during a live editor session is handled by `saveChain` (a
plain `[URL: Task]` dictionary on Clamshell), not a queueing actor —
the chain inherits the surrounding MainActor isolation.

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
  outputs. Also owns the per-URL save chain: `documentDidChange`
  (commit-time atomic log + .md write) and `flush(_:)` (await
  durability). Engine-internal in-place saves go through the same
  `enqueueSave(doc, patch: .empty)` primitive.
- [Clamshell+Reconcile.swift](Clamshell+Reconcile.swift) — engine
  orchestration: open-doc reconcile, live-doc reconcile for presenter
  wakeups, and `restore(_:liveDoc:)` for the Recover sheet.
- [Clamshell+Presenter.swift](Clamshell+Presenter.swift) — the
  NSFilePresenter lifecycle, wakeup classification (echo / stomp /
  external), and `openPage` / `closePage`.
- [PatchEngine.swift](PatchEngine.swift) — the engine. Pure
  Sendable types: `LogJournal`, `LogRecord`, `IntentState`,
  `Reconciliation`. Pure functions: `intent(from:)`,
  `reconcile(intent:doc:)`, `insertion(rootHash:candidates:intent:doc:)`,
  `mergeConflict(survivor:alternates:intent:)`. Plus the
  `LostBlockForest` forest assembler used by both the engine and the
  host's Recover-sheet UI grouping.
- [FileStore.swift](FileStore.swift) — markdown file I/O and `Trash/`
  moves. Stateless, `Sendable`.
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

- **No UI.** The "Recover" sheet, the page picker, the home-page
  button — all live in [`App/Sources/Shell/`](../Shell/) and
  [`ContentView.swift`](../ContentView.swift).
- **No multi-page coordination.** "What's on the nav stack?", "which
  page is mounted in this window?" — all on per-window
  `WorkspaceWindow`. Clamshell handles one persistent format; the
  host splits workspace-wide vs. per-window state across `Workspace`
  and `WorkspaceWindow`.
- **No banners or recovery-sheet UI.** `Clamshell.openPage(...)` and
  `Clamshell.restore(_:liveDoc:)` do the engine work and return
  outcomes (summary + presenter events); the host (`WorkspaceWindow`)
  shows the resulting banner and routes from the Recover sheet's row
  taps.
- **No move-as-operation.** Moving a block between parents on a device
  that already logged it doesn't append a new record. The original `p`
  goes stale; restore relies on chain-climbing through still-alive
  hashes to find a live ancestor.
- **No log compaction yet.** Logs grow unbounded. For ordinary usage
  they stay small.
