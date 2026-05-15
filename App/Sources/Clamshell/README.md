# Clamshell

Hunch's persistent markdown format and its API. A Clamshell is a folder of
markdown files plus a small amount of sidecar state — soft-deleted pages,
a per-(device, page) append-only recovery log, pasted-image assets, and
format metadata.

The format is **durable** (every atomic block ever serialized lives in
the recovery log until purged), **portable** (everything lives in the
folder — copy or sync it and the home-page pointer travels with it),
**readable** (any text editor cracks it open), and **iCloud-friendly**
(few files, append-only writes, no cross-device write contention on any
single file).

---

## On-disk layout

```
<clamshell-root>/
  *.md                                       live pages
  Trash/<relpath>.md                         soft-deleted pages (mirrors source structure)
  .history/<relpath>/<device-id>.jsonl       per-(device, page) recovery log
  Assets/<filename>                          pasted images
  .clamshell.json                            format metadata (home page pointer)
```

- **Live pages** are plain markdown — Hunch's parser handles toggles
  (`▸ Title` paragraphs with indented body) and template buttons via
  convention; see [Parser.swift](Parser.swift) for the surface syntax.
- **`Trash/`** mirrors the workspace's directory structure. Restoring a
  trashed page moves it back to its original path (suffixed `-restored-2`
  etc. on collision). The page's `.history/<relpath>/` dir travels with
  it — trash and restore are page-bundle moves.
- **`.history/`** has one subdirectory per page (mirroring the page's
  rel path) and inside, one JSONL log per device that has ever written
  to that page. Each log line is one record (see "Recovery log format"
  below). Each device only writes to its own file → zero cross-device
  contention; reads union all device files.
- **`Assets/`** holds pasted images. Visible (Notion / Obsidian
  convention) so the same file opens cleanly in any markdown viewer.
- **`.clamshell.json`** is the only format-level metadata file.
  Currently just the home-page pointer; future fields go here.

---

## Recovery log format

Each device's per-page log file (`<device-id>.jsonl`) is a sequence of
JSON objects, one per line, append-only. Two record kinds, distinguished
by the `op` field:

```jsonc
{"op":"add","h":"<full-sha256>","p":"<parent-hash>"|null,"m":"<atomic markdown>","t":1714867200.123}
{"op":"purge","h":"<full-sha256>","t":1714867200.123}
```

- **`add`** is appended the first time this device observes a given
  atomic-block content (`h` = full SHA-256 of the canonical block —
  ignores inline marks and whitespace runs; see `BlockFingerprint`).
  `p` is the atomic hash of the block's immediate parent at first
  observation, or `null` for top-level. `m` is the block's atomic
  markdown — the block on its own, no children. Write-once: subsequent
  saves with the same `h` on the same device append nothing.
- **`purge`** is a tombstone. Appended when the user dismisses a
  recovered entry from the Recover sheet. Suppresses `h` from recovery
  results across every device's log union.
- **`t`** is Unix seconds with millisecond precision. On hash
  collisions across devices' logs, the latest `t` wins for parent
  metadata.

Recovery for a page reads every device's log under
`.history/<page-rel>/`, unions them, drops anything tombstoned,
filters out hashes that are still alive in the page's `.md`, and shows
the rest. The atomic markdown `m` is parsed back into a `Block` at
restore time and inserted under the closest live ancestor (climbing
the recorded parent chain through the log union if needed).

---

## Quickstart

```swift
import Foundation

let clamshell = Clamshell(root: workspaceURL)
let entries = try clamshell.scan()

// Read
let doc = try clamshell.loadDocument(at: entries[0].url)

// Write — coalesced autosave path. Records new atomic blocks into the
// recovery log internally; the caller doesn't pass any "previous text".
try await clamshell.save(doc)

// Trash a page. If it was the home page, homeRelativePath gets cleared.
// The page's .history/<rel>/ dir is moved to .history/Trash/<rel>/.
try clamshell.moveToTrash(at: doc.url)

// Recover something
let trashed = try await clamshell.listTrashedPages()
let lost = await clamshell.listLostBlocks()
```

**One Clamshell per directory.** Construct with the root URL; never
reconfigure. When the user switches workspaces, throw away the
existing instance and build a new one. The first init for a given
folder reads `.clamshell.json` if it exists, or migrates the legacy
`console.workspace.homeRelativePath` UserDefaults key onto disk on
upgrade. It also drops any leftover `.blocks/` directory left behind
by an earlier (now-retired) per-block-pool design.

---

## API

| Group | Methods |
|-------|---------|
| Path conversion | `relativePath(of:)`, `url(for:)` |
| Read | `scan()`, `loadDocument(at:)`, `loadDocumentAndRawText(at:)`, `loadDocumentTitle(at:)`, `readRawText(at:)` |
| Write | `save(_:resolvingSubpageTitle:)` (async, coalesced), `writeImmediately(_:resolvingSubpageTitle:)` (sync), `flush(url:)`, `snapshotIntoRecoveryLog(at:blocks:)` |
| Create | `createPage(title:requestedPath:blocks:)` |
| Search | `searchPages(in:query:excluding:)` |
| Trash | `moveToTrash(at:)`, `listTrashedPages()`, `restorePage(_:)` |
| Recovery log | `listLostBlocks(filter:)`, `listPurgedBlocks(filter:since:)`, `purgeLostBlock(_:)`, `purgeHash(_:in:)`, `unpurgeBlock(_:in:withParent:)`, `parentHash(forPage:hash:)` |
| iCloud merge | `resolveConflictVersions(at:againstLive:resolvingSubpageTitle:)`, `runAutoTombstoneMigrationIfNeeded()` |
| Assets | `writeImage(_:)`, `resolveImage(source:)` |
| Metadata | `homeRelativePath` (read/write), `autoTombstoneMigrationDone`, `root` |

The `resolvingSubpageTitle: (String) -> String?` callback on the write
paths is used by the serializer to refresh stale subpage-link titles
— the host has a live page-title cache, so when serializing
`[Old Title](pages/foo.md)` the serializer asks the host for the
current title of `pages/foo.md`. nil = use whatever's in the doc
already.

---

## Behaviors worth knowing

**Recovery log is per-device, write-once-per-content.** Every
`save(_:)` and `writeImmediately(_:)` walks the document's atomic
block tree; for any block whose hash this device hasn't already
recorded, it appends a single `add` line to *this device's* log file.
Steady-state saves with no new content perform zero file I/O — an
in-memory hash cache short-circuits ahead of the file open. New blocks
trigger one append per new content. iCloud sees one tail-grow per new
content, not many small files.

**Cross-device merging happens on read, not write.** Each device only
ever writes its own `<device-id>.jsonl`. Other devices' files are
read but never modified. Recovery's union-by-hash collapses
duplicates (latest `t` wins for parent metadata). Tombstones from any
device suppress the hash globally. There are no cross-device write
contention windows and no merge-on-read sibling-file plumbing.

**Live filtering.** A pool entry is only "lost" if its hash isn't in
the live page's atomic-block set right now — re-creating the same
content (e.g. a recurring `# Today` heading) makes the entry live
again automatically without any log mutation.

**Trash invalidates home.** `moveToTrash(at:)` clears
`homeRelativePath` if the trashed page was the home page. The
pointer can't reference a file that's no longer at its live path.
The page's `.history/<rel>/` directory moves alongside the `.md`,
so trash + restore is a page-bundle operation.

**Coalesced vs immediate writes.** `save(_:) async` deduplicates
concurrent writes for the same URL — if a write is already in flight,
the new snapshot replaces any pending one and is written after the
in-flight write completes. Use it for the autosave path (debounced
typing, blur, scenePhase). `writeImmediately(_:) throws` bypasses the
coalescer; use it when the next operation depends on the file being
on disk now — trashing a dirty open doc, appending blocks to a
non-open subpage, restoring a lost block back into a closed page.

**Pre-save snapshots.** `snapshotIntoRecoveryLog(at:blocks:)` exists
for the editor's destructive-mutation sites (multi-block delete,
cut). It records the about-to-be-deleted block tree into the log
*before* the mutation, covering the race where blocks live briefly
in the doc, get deleted, and the autosave never fires while they're
present.

**Stale parent metadata is acceptable.** A block's `p` field records
the parent observed *the first time this device logged the block*. If
the block later moves between parents, the recorded `p` goes stale;
restore handles this by climbing the recorded parent chain (via
`parentHash(forPage:hash:)`) until it finds a hash that's still
alive, falling back to top-of-page when none of the ancestors
survive.

**iCloud conflict versions auto-merge.** When iCloud Drive lands a
sibling-file conflict (`<page> 2.md`, `<page> (joe's iPad).md`, or any
file iCloud's `NSURLUbiquitousItemHasUnresolvedConflictsKey` flags),
`resolveConflictVersions(at:)` parses every alternate version, diffs
their atomic-block hashes against the survivor's, and splices any
unique-to-an-alternate block (that isn't tombstoned) under the closest
live ancestor. Block identity is by content hash (same as the recovery
log), so independent edits on two devices end up additive instead of
clobbering each other. The merge is delegated to `ConflictMerger` (a
pure block-tree function); the caller writes the merged result back
through the same save path. Driven by `Workspace` at scan time (closed
pages) and by `WorkspaceWindow.handlePresentedFileChange` for the open
page on file-presenter wakeups.

**Intentional deletions stay recoverable.** Auto-tombstoned and
manually-purged hashes are tracked separately from "lost" entries —
the log union remembers both the latest record (purge) and the
latest prior `add` (carrying markdown + parent). `listPurgedBlocks`
surfaces them so the user can bring back something they deleted on
purpose; `unpurgeBlock` appends a fresh `add` with a new timestamp,
which beats the prior purge under latest-`t` semantics and lifts
the tombstone from the union. Defaults to a 30-day window for
surface area; pass `since: nil` to see everything.

**Auto-tombstone migration runs once per Clamshell.** Until the
`autoTombstoneMigrationDone` flag in `.clamshell.json` is set, the
recovery log can hold orphan `add` records from before auto-tombstoning
was wired up. `runAutoTombstoneMigrationIfNeeded()` iterates pages,
auto-tombstones any of *this device's* log entries whose hashes aren't
live in the page or any other device's log, and sets the flag.
Idempotent; subsequent calls early-return. The host calls it on
workspace open. Auto-restore-on-page-open
(`WorkspaceWindow.autoRestoreLostBlocksOnOpen`) is gated on this flag
to avoid resurrecting legacy orphans.

---

## Concurrency

`Clamshell` is `@MainActor`-isolated for its mutable property
(`homeRelativePath`) and the operations that touch it
(`moveToTrash`, `restorePage`, the save paths). Path conversions,
raw reads, and asset I/O are `nonisolated`. The underlying stores
are actors (`RecoveryLog`, `TrashStore`, `DocumentSaveCoordinator`)
or stateless `Sendable` (`FileStore`); call them from background
tasks freely.

Recovery-log appends are serialized inside the `RecoveryLog` actor
and wrapped in `NSFileCoordinator` to avoid racing with iCloud Drive
sync. Each device's log is single-writer-per-device, so the only
realistic concurrency is "us appending while iCloud is uploading our
last append" — `NSFileCoordinator` handles that.

---

## Files in this directory

- [Clamshell.swift](Clamshell.swift) — the umbrella API.
- [FileStore.swift](FileStore.swift) — markdown file I/O and `Trash/` moves. Stateless, `Sendable`.
- [DocumentSaveCoordinator.swift](DocumentSaveCoordinator.swift) — per-URL serial, snapshot-coalescing actor for autosaves.
- [RecoveryLog.swift](RecoveryLog.swift) — reads/writes `.history/<rel>/<device-id>.jsonl`. Append-only `add` and `purge` records; per-page in-memory hash cache short-circuits steady-state saves; reads union every device's log.
- [DeviceID.swift](DeviceID.swift) — per-install UUID stored in `UserDefaults`. Names this device's recovery log file.
- [TrashStore.swift](TrashStore.swift) — lists `Trash/` and restores from it.
- [WorkspaceBookmark.swift](WorkspaceBookmark.swift) — UserDefaults persistence of the security-scoped URL bookmark for the user's chosen Clamshell folder.
- [BlockFingerprint.swift](BlockFingerprint.swift) — stable content-identity hash for a `Block`. Two outputs: a 16-char prefix for compact display, and the full SHA-256 used as `h` in the recovery log and elsewhere.
- [Parser.swift](Parser.swift) / [Serializer.swift](Serializer.swift) — markdown ↔ `[Block]`. swift-markdown lives here, not in the [Editor package](../../../Packages/Editor/). `Serializer.serializeAtomic(_:)` emits a single block without children — what the recovery log stores in its `m` field.
- [ConflictMerger.swift](ConflictMerger.swift) — pure block-tree merge for iCloud conflict resolution. Driven by `Clamshell.resolveConflictVersions`, called by `Workspace`/`WorkspaceWindow` from scan and file-presenter paths.

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
- **No restore-of-lost-block logic.** `purgeLostBlock(_:)` records a
  tombstone, but parsing the recovered markdown, climbing the parent
  chain to find a live ancestor in the document, and splicing the
  block back in lives in the host (`WorkspaceWindow.restoreLostBlock`)
  — the operation is document-shape-aware in a way that's outside
  Clamshell's remit.
- **No log compaction yet.** Logs grow unbounded. The plan supports
  two cheap compaction strategies (read-time `since:` filter for
  tail-first reads, and background log rewrite that drops live
  hashes) but neither is implemented. For ordinary usage the logs
  stay small.
