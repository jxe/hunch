# Clamshell

Hunch's persistent markdown format and its API. A Clamshell is a folder of
markdown files plus a small amount of sidecar state — soft-deleted pages,
an append-only log of lost or edited blocks, and format metadata.

The format is **durable** (every edit is restorable from the lost-block
log), **portable** (everything lives in the folder — copy or sync it and
the home-page pointer travels with it), and **readable** (anyone with a
text editor can crack it open).

---

## On-disk layout

```
<clamshell-root>/
  *.md                          live pages
  Trash/<relpath>.md            soft-deleted pages (mirrors source structure)
  .history/<relpath>.md.jsonl   append-only log of lost / edited blocks
  .clamshell.json               format metadata (home page pointer)
```

- **Live pages** are plain markdown — Hunch's parser handles toggles
  (`▸ Title` paragraphs with indented body) and template buttons via
  convention (see [Parser.swift](Parser.swift) for the surface syntax).
- **`Trash/`** mirrors the workspace's directory structure. Restoring a
  trashed page moves it back to its original path (suffixed `-restored-2`
  etc. on collision).
- **`.history/`** has one JSONL log per source page. Each line is a
  `LostBlockRecord` — block fingerprint, markdown body, anchor for restore
  positioning, timestamp. Dedup is by content fingerprint. iCloud conflict
  siblings (`page.md 2.jsonl`) are merged into the canonical log on read.
- **`.clamshell.json`** is the only format-level metadata file. Currently
  just the home-page pointer; future fields go here.

---

## Quickstart

```swift
import Foundation

let clamshell = Clamshell(root: workspaceURL)
let entries = try clamshell.scan()

// Read
let doc = try clamshell.loadDocument(at: entries[0].url)

// Write — coalesced autosave path. Records edits to the lost-block log
// internally; the caller doesn't pass any "previous text".
try await clamshell.save(doc)

// Trash a page. If it was the home page, homeRelativePath gets cleared.
try clamshell.moveToTrash(at: doc.url)

// Recover something
let trashed = try await clamshell.listTrashedPages()
let lost = try await clamshell.listLostBlocks()
```

**One Clamshell per directory.** Construct with the root URL; never
reconfigure. When the user switches workspaces, throw away the existing
instance and build a new one. The first init for a given folder reads
`.clamshell.json` if it exists, or migrates the legacy
`console.workspace.homeRelativePath` UserDefaults key onto disk on
upgrade.

---

## API

| Group | Methods |
|-------|---------|
| Path conversion | `relativePath(of:)`, `url(for:)` |
| Read | `scan()`, `loadDocument(at:)`, `loadDocumentTitle(at:)` |
| Write | `save(_:resolvingSubpageTitle:)` (async, coalesced), `writeImmediately(_:resolvingSubpageTitle:)` (sync), `flush(url:)` |
| Create | `createPage(at:title:blocks:)`, `availablePagePath(for:)` |
| Trash | `moveToTrash(at:)`, `listTrashedPages()`, `restorePage(_:)` |
| Lost-block log | `recordDeletion(at:previousBlocks:removedIndices:)`, `listLostBlocks(filter:)`, `purgeLostBlock(_:)` |
| Metadata | `homeRelativePath` (read/write), `root` |

The `resolvingSubpageTitle: (String) -> String?` callback on the write
paths is used by the serializer to refresh stale subpage-link titles —
the host has a live page-title cache, so when serializing
`[Old Title](pages/foo.md)` the serializer asks the host for the current
title of `pages/foo.md`. nil = use whatever's in the doc already.

---

## Behaviors worth knowing

**Save records edits.** Every `save(_:)` and `writeImmediately(_:)` fires
a fire-and-forget `recordEdits` against `.history/<rel>.md.jsonl` after
the write lands. The diff is computed inside Clamshell — the caller
doesn't pass any "previous text". Blocks that disappeared are recorded as
`LostBlockRecord`s; an unchanged page is a no-op. Recovery is the only
reason to be aware of this — it just works.

**Trash invalidates home.** `moveToTrash(at:)` clears `homeRelativePath`
if the trashed page was the home page. The pointer can't reference a
file that's no longer at its live path.

**Coalesced vs immediate writes.** `save(_:) async` deduplicates concurrent
writes for the same URL — if a write is already in flight, the new
snapshot replaces any pending one and is written after the in-flight
write completes. Use it for the autosave path (debounced typing, blur,
scenePhase). `writeImmediately(_:) throws` bypasses the coalescer; use
it when the next operation depends on the file being on disk now —
trashing a dirty open doc, appending blocks to a non-open subpage,
restoring a lost block back into a closed page.

**Autotransform residue is filtered.** The lost-block log skips paragraphs
whose body is an autotransform trigger like `#`, `- `, `[]`, `> ` — these
appear momentarily as the user types their way to a heading or list and
shouldn't pollute the recovery feed.

**iCloud conflict siblings.** `RecoveryStore` merges sibling files like
`page.md 2.jsonl` into the canonical log on read (union by fingerprint,
earliest `recordedAt` wins on collision), then deletes the siblings.
You won't see them in `listLostBlocks` results.

---

## Concurrency

`Clamshell` is `@MainActor`-isolated for its mutable property
(`homeRelativePath`) and the `moveToTrash(at:)` operation that may mutate
it. Everything else is `nonisolated` — `scan`, `loadDocument`, `save`,
`writeImmediately`, the trash list/restore, the lost-block log, all the
`recordX` methods. Call them from background tasks freely; the underlying
stores (`FileStore` is Sendable, the rest are actors) handle isolation.

---

## Files in this directory

- [Clamshell.swift](Clamshell.swift) — the umbrella API.
- [FileStore.swift](FileStore.swift) — markdown file I/O and `Trash/` moves. Stateless.
- [DocumentSaveCoordinator.swift](DocumentSaveCoordinator.swift) — per-URL serial, snapshot-coalescing actor for autosaves.
- [RecoveryStore.swift](RecoveryStore.swift) — reads/writes `.history/<rel>.md.jsonl`. Records `LostBlockRecord` rows on edits and deletions; dedup by fingerprint. Merges iCloud conflict siblings on read.
- [TrashStore.swift](TrashStore.swift) — lists `Trash/` and restores from it.
- [WorkspaceBookmark.swift](WorkspaceBookmark.swift) — UserDefaults persistence of the security-scoped URL bookmark for the user's chosen Clamshell folder.
- [LostBlockRecord.swift](LostBlockRecord.swift) — the `.history/` JSON record type + JSONL codec.
- [BlockFingerprint.swift](BlockFingerprint.swift) — stable content-identity hash for a `Block`. Used by `RecoveryStore` for dedup and anchor matching.
- [Parser.swift](Parser.swift) / [Serializer.swift](Serializer.swift) — markdown ↔ `[Block]`. swift-markdown lives here, not in the [Editor package](../../../Packages/Editor/).

---

## What Clamshell doesn't do

- **No UI.** The "Recover" sheet, the page list, the home-page button —
  all live in [`App/Sources/Shell/`](../Shell/) and
  [`ContentView.swift`](../ContentView.swift).
- **No observation.** Clamshell is not `@Observable`. SwiftUI re-render
  plumbing is the host's job — Hunch's `WorkspaceModel` mirrors
  `homeRelativePath` for SwiftUI.
- **No multi-page coordination.** "Which page is open?", "what's dirty?",
  "the navigation stack" — all `WorkspaceModel`. Clamshell handles one
  persistent format; the model handles the editing session.
- **No restore-of-lost-block logic.** `purgeLostBlock(_:)` removes a
  record from the log, but parsing the recorded markdown, finding an
  anchor in the live document, and splicing the blocks back in lives in
  the host (`WorkspaceModel.restoreLostBlock`) — the operation is
  document-shape-aware in a way that's outside Clamshell's remit.
