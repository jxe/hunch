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

- **`add`** is appended the first time a device observes a given atomic
  block content. `h` is the full SHA-256 of the canonical block (see
  [BlockFingerprint](../../../Packages/Editor/Sources/Editor/BlockFingerprint.swift)).
  `p` is the parent hash *at first observation* (may go stale; see
  below). `m` is the atomic markdown — the block on its own, no
  children.
- **`purge`** is a tombstone, appended explicitly by the editor at the
  moment of structural removal (`EditorView.mutate` diffs pre/post block
  IDs and fires one purge per removed id) or by the user dismissing a
  recovered entry from the Recover sheet.
- **`t`** is unix seconds with millisecond precision. Used for display
  and the `since:` filter on `listPurgedBlocks`. Not the order resolver.
- **`c`** is a per-page Lamport counter, monotonically incrementing per
  device. Records compare on `(c, device-id)` lex; legacy records (no
  `c`) fall back to `t` and always lose to modern records in mixed
  comparisons — they predate the upgrade in any realistic timeline.

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

`WorkspaceWindow.reconcileOpenDocumentAgainstLog` calls it on every
page open and every file-presenter wakeup. Held off while the doc is
dirty or a save is in flight — the engine assumes
`doc.children == parsed(.md)`.

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
let entries = try clamshell.scan()

// Read
let doc = try clamshell.loadDocument(at: entries[0].url)

// Write — coalesced autosave. The save path records new atomic blocks
// into the recovery log internally; the caller doesn't pass any
// "previous text."
try await clamshell.save(doc)

// Trash a page. If it was the home page, homeRelativePath gets cleared.
// The page's .history/<rel>/ dir is moved alongside the .md.
try clamshell.moveToTrash(at: doc.url)

// Recover something
let trashed = try await clamshell.listTrashedPages()
let lost = await clamshell.listLostBlocks()

// Engine-direct: open a page, reconcile, apply.
let journal = clamshell.readJournal(forPage: rel)
let intent = PatchEngine.intent(from: journal)
let recon = PatchEngine.reconcile(intent: intent, doc: doc.children)
PatchEngine.apply(recon, to: doc)
clamshell.appendObservations(recon.toAppend, forPage: rel)
```

**One Clamshell per directory.** Construct with the root URL; never
reconfigure. When the user switches workspaces, throw away the
existing instance and build a new one.

---

## API

| Group | Methods |
|-------|---------|
| Path conversion | `relativePath(of:)`, `url(for:)` |
| Read | `scan()`, `loadDocument(at:)`, `loadDocumentAndRawText(at:)`, `loadDocumentTitle(at:)`, `readRawText(at:)` |
| Write | `save(_:resolvingSubpageTitle:)`, `writeImmediately(_:resolvingSubpageTitle:)`, `flush(url:)`, `snapshotIntoRecoveryLog(at:blocks:)` |
| Create | `createPage(title:requestedPath:blocks:)` |
| Search | `searchPages(in:query:excluding:)` |
| Trash | `moveToTrash(at:)`, `listTrashedPages()`, `restorePage(_:)` |
| Recovery log | `readJournal(forPage:)`, `appendObservations(_:forPage:)`, `listLostBlocks(filter:)`, `listPurgedBlocks(filter:since:)`, `purgeHash(_:in:)`, `unpurgeBlock(_:in:parentHash:)` |
| iCloud merge | `resolveConflictVersions(at:againstLive:resolvingSubpageTitle:)` |
| Assets | `writeImage(_:)`, `resolveImage(source:)` |
| Metadata | `homeRelativePath` (read/write), `root` |

The engine itself is at the same layer as Clamshell. Callers reaching
into engine territory use `clamshell.readJournal` → `PatchEngine.intent`
→ `PatchEngine.reconcile` directly.

---

## Behaviors worth knowing

**Recovery log is per-device, write-once-per-content.** Every
`save(_:)` and `writeImmediately(_:)` walks the document's atomic block
tree; for any block whose hash this device hasn't already recorded, it
appends a single `add` line to *this device's* log file. Steady-state
saves with no new content perform zero file I/O — an in-memory hash
cache short-circuits ahead of the file open.

**The hash cache replays adds AND purges.** Hydration walks our
device's log in file order and applies `add` (insert) and `purge`
(remove) as transitions. Retyping content this device previously
purged produces a fresh `add` whose counter beats the prior purge in
the union, restoring intent to alive. Without this transition replay,
the log would lie that content is dead while the live `.md` shows it
alive.

**Cross-device merging happens on read, not write.** Each device only
ever writes its own `<device-id>.jsonl`. Other devices' files are read
but never modified. The union compares on `(c, device-id)` lex
(Lamport, clock-skew-immune); legacy records without a `c` fall back
to `t` and lose to any modern record. Tombstones from any device
suppress the hash globally when their `(c, device-id)` is the latest
pair.

**Bare-md and external edits are absorbed.** `reconcile()` emits an
`Observation` for any block present in `doc` but absent from the
journal. `Clamshell.appendObservations` writes them as fresh `add`
records on this device's log. A `.md` opened with no `.history/` dir
gets fully logged on first reconcile; a block an external editor wrote
gets logged on the next file-presenter wakeup.

**Live filtering.** A journal entry is only "lost" if its hash isn't
in the live page's atomic-block set right now — re-creating the same
content (e.g. a recurring `# Today` heading) makes the entry live
again automatically without any log mutation.

**Trash invalidates home.** `moveToTrash(at:)` clears
`homeRelativePath` if the trashed page was the home page. The page's
`.history/<rel>/` directory moves alongside the `.md`, so trash +
restore is a page-bundle operation.

**Coalesced vs immediate writes.** `save(_:) async` deduplicates
concurrent writes for the same URL — if a write is already in flight,
the new snapshot replaces any pending one and is written after the
in-flight write completes. Use it for the autosave path. `writeImmediately(_:) throws`
bypasses the coalescer; use it when the next operation depends on the
file being on disk now — trashing a dirty open doc, appending blocks to
a non-open subpage, restoring a lost block back into a closed page.

**Pre-save snapshots.** `snapshotIntoRecoveryLog(at:blocks:)` exists
for the editor's destructive-mutation sites (multi-block delete, cut).
It records the about-to-be-deleted block tree into the log *before* the
mutation, covering the race where blocks live briefly in the doc, get
deleted, and the autosave never fires while they're present.

**Deletes are explicit, not inferred.** The editor calls
`purgeHash(_:in:)` from inside `EditorView.mutate(_:_:)` for every
block id present before a structural mutation but absent after.
Save paths emit only `add` records; they never infer tombstones from
diffing prior state. Consequences:
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
something they deleted on purpose; `unpurgeBlock` appends a fresh
`add` whose counter beats the prior purge under `(c, device-id)` lex,
lifting the tombstone from the union. Defaults to a 30-day window for
surface area; pass `since: nil` to see everything.

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
  Reads return `LogJournal`s for the engine; writes are `record`
  (save-path tree walk), `append(observations:)` (engine-driven),
  `purge` (explicit deletes), `reAdd` (restore from tombstone), and
  `move` (page renames). All business logic lives in `PatchEngine`.
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
