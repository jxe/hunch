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
  Each page carries a durable `clamshell-id: <6 chars>` line in its
  YAML frontmatter (minted at creation, or on first save for legacy
  pages). This ID is the page's stable identity across renames: links
  write it as a fragment (`[Title](My-Page.md#x7f3q2)`) so a rename —
  even one done in Finder — never breaks a link. See **Renaming &
  link identity** below.
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

A **patch** is one record on a per-(device, page) JSONL log. Three
record kinds, distinguished by `op`:

```jsonc
{"op":"add",    "h":"<full-sha256>","p":"<parent-hash>"|null,"m":"<atomic markdown>","t":1714867200.123,"c":42}
{"op":"observe","h":"<full-sha256>","p":"<parent-hash>"|null,"m":"<atomic markdown>","t":1714867200.123,"c":43}
{"op":"purge",  "h":"<full-sha256>",                                                 "t":1714867200.123,"c":44}
```

Two flavours: **authoritative** (`add`, `purge`) and **tentative**
(`observe`).

- **`add`** claims authorship. The block became alive via a direct
  edit on this device. `h` is the full SHA-256 of the canonical block
  (see [BlockRecoveryIdentity.swift](BlockRecoveryIdentity.swift)).
  `p` is the parent hash *at first observation* (may go stale; see
  below). `m` is the atomic markdown — the block on its own, no
  children. Authoritative for `.alive` classification → eligible for
  auto-restore if the hash later goes missing from `doc`.
- **`observe`** is structurally identical to `add` (same fields) but
  semantically distinct: "I noticed this block in my `.md` but I'm
  not claiming authorship." Written by reconcile when it finds a
  block in `doc` that no device's log has claimed yet — typically
  because iCloud delivered the foreign device's `.md` before its
  `.jsonl`. Carries a snapshot for the Recover sheet but is **not**
  authoritative for `.alive`, so a later foreign `purge` doesn't
  resurrect from our `observe` (the lift-bug fix). Also covers
  external edits (vim'd a block into `.md`): the journal still has
  a snapshot for recovery, but we don't take ownership we don't have.
- **`purge`** is a tombstone, appended at the moment of structural
  removal or content-identity replacement. The editor's transaction
  boundary derives a pre→post `[DocumentChange]` semantic diff and fires
  `host.persistCommit(changes:in:)` (the editor-facing `EditorHost`
  protocol method); the host bridges that to
  `PageSession.enqueueEditorChanges(_:)`, which projects the batch onto
  a `Patch` (inserts → `.add`, removes → `.purge`) and routes it to
  `RecoveryLog.apply(_:to:)` for one ordered append with sequential
  counters. Authoritative — drives `.tombstoned` and triggers engine
  removes for stale-but-still-in-doc subtrees on peer sync.
- **`t`** is unix seconds with millisecond precision. Used for display,
  the `since:` filter on `listPurgedBlocks`, and the engine's mtime
  gate (latest-snapshot timestamp compared to `.md` mtime).
- **`c`** is a per-page Lamport counter, monotonically incrementing per
  device. Records compare on `(c, device-id)` lex; legacy records (no
  `c`) fall back to `t` and always lose to modern records in mixed
  comparisons — they predate the upgrade in any realistic timeline.

Unknown `op` values are skipped on read for forward compatibility.

### Patches as the write unit

Every write to the log goes through one primitive:

```swift
actor RecoveryLog {
    func apply(_ patch: Patch, to rel: String) throws
}
```

A `Patch` is a batch of `add` / `purge` / `observe` entries (see
[PatchEngine.swift](PatchEngine.swift)). Static factories project from
the three callers' natural shapes onto the unified type:

- `Patch.adds(from blocks: [Block])` — full-doc walks for content this
  device is claiming as authored, such as the subpage-append host
  bridge. Emits `add`.
- `Patch.observations(from blocks: [Block])` — full-doc walks for
  merged or externally observed content this device should snapshot but
  not claim as authored, such as conflict-merge writes. Emits `observe`.
- `Patch.from(changes: [DocumentChange])` — editor semantic diffs. Emits
  `add` / `purge`.
- `Patch.Entry.observe(hash:parent:markdown:)` — used by reconcile
  to write snapshots of unclaimed blocks (see "Reconciliation" below).

`apply` mints sequential per-page Lamport counters for each entry in
the patch, encodes them as JSONL, and appends to our device's log file
in one batched write. No write-time dedup: every entry emits a record.
Duplicate `add`s for the same hash are harmless — intent is a
latest-`(counter, deviceID)`-wins fold, so the union collapses them to
the same intent at read time. The log just gets a little chattier on
the rare full-doc-walk callers (conflict merge in
`Page.resolveConflicts()`, subpage drops via
`EditorHost.appendToPage`).

### Journal

A page's **journal** is the union of every device's per-page log.
`RecoveryLog.readJournal(page:)` returns it as a `LogJournal` value —
the engine's input.

### Intent state

`PatchEngine.intent(from: journal) -> IntentState` is a pure function
that classifies every hash the journal mentions:

| Status         | Meaning                                                                                                                                |
|----------------|----------------------------------------------------------------------------------------------------------------------------------------|
| `.alive`       | Latest **authoritative** record (`add` / `purge`) is an `add`. Eligible for auto-restore.                                              |
| `.observed`    | No authoritative record exists, but at least one `observe` carries a snapshot. Not auto-restore-eligible; surfaceable via Recover sheet. |
| `.tombstoned`  | Latest authoritative record is a `purge`. Carries the latest prior snapshot (from `add` or `observe`) for restore display.             |

The classification ignores `observe` records when picking between
alive / tombstoned (only `add` and `purge` move that needle), but
collects them when computing the latest snapshot — so an `observe`
followed by a `purge` still leaves the snapshot recoverable.

`IntentState` also exposes `parent(of:)` (the latest snapshot's `p`,
useful even on tombstoned hashes for chain climbs) and `tombstones()`.

### Reconciliation

`PatchEngine.reconcile(intent:doc:mdMtime:)` is the engine's main
entry point. Given the page's intent state, the doc's current
children, and the `.md` file's modification date, it produces:

- **`inserts: [Insert]`** — subtrees to splice into the doc for hashes
  the intent says are `.alive` but the doc is missing. Each `Insert`
  carries the live ancestor's `BlockID` (resolved by climbing the
  recorded-parent chain through other alive hashes).
- **`removes: [Remove]`** — subtrees to strip from the doc for hashes
  the intent says are `.tombstoned` but the doc still has. Symmetric
  to inserts; this is how doc converges to the journal when a peer's
  purge arrives after the user's "stale-but-still-in-doc" state.
- **`toAppend: [Observation]`** — `observe` records the caller should
  append to *this device's* log for blocks present in the doc but
  absent from the journal. Drives bare-md absorption (`.md` files
  with no `.history/` dir get their blocks recorded as snapshots on
  first open) and external-edit absorption (vim'd blocks get a
  Recover-sheet handle without claimed authorship).
- **`unrestorable: [UnrestorableEntry]`** — hashes the journal calls
  alive but the engine can't materialise (markdown won't parse or
  round-trips to a different hash). Quarantined via a `purge` so they
  stop firing reconcile.

`PatchEngine.apply(_:to:)` is the @MainActor convenience that strips
every `Remove` then splices every `Insert`, plus re-enforces heading
containment. The orchestrator (`Clamshell+Reconcile.swift`) calls
`apply` and then projects the rest of the reconcile output —
`toAppend` observations and `unrestorable` quarantines — into a
single `Commit` via `Reconciliation.asCommit()`, which `commit(_:to:)`
routes through the URL's `PageCoordinator`.

#### The mtime gate

The engine takes the `.md` modification date as a parameter. It uses
that timestamp conservatively for delete propagation, but not for
add-backed auto-restore:

- **Insert / auto-restore**: if the log says a hash is alive and the
  hash is missing from the doc, restore it regardless of whether the
  `.md` mtime is newer than the add. Without an explicit purge, a newer
  `.md` write might be an unrelated local edit that raced ahead of a
  delayed peer log. Live hashes are still filtered out, so this does not
  duplicate blocks already present in the doc.
- **Remove suppression**: if `purge.recordedAt < mdMtime`, skip the
  remove. The `.md` was written *after* the purge — likely an
  external `vim` edit re-added the block. Don't strip user content
  out from under them.
- **Crash recovery / eager restore**: if the journal knows something
  the `.md` doesn't (log apply succeeded but save crashed, or a foreign
  log arrived before its `.md`), this falls out of the same insert rule:
  add-backed missing hashes restore.
- Pass `nil` to disable the remove gate (used by tests and manual
  recover paths where the caller has full control).

The remaining remove gate is small but load-bearing: it prevents a
stale purge from deleting content that the newer `.md` has reintroduced.
For missing add-backed blocks, Clamshell deliberately accepts the other
tradeoff: if a peer's deletion `.md` arrives before its purge log, the
block may briefly reappear until the explicit purge catches up.

The contract:

1. **Existence**: a block is in `doc'` iff its hash is `.alive` in
   intent OR present in `doc` and not `.tombstoned` (subject to the
   mtime gate on both inserts and removes).
2. **Order**: blocks already in `doc` keep their order; restored
   blocks land at end-of-children under the closest live ancestor.
3. **Observation**: blocks in `doc` whose hash is absent from intent
   get a synthesized `observe` (not `add` — we don't claim
   authorship for blocks we didn't author).
4. **Authority**: only `add` and `purge` records drive
   `.alive`/`.tombstoned`. `observe` records contribute a snapshot
   but never trigger auto-restore or auto-remove.
5. **Idempotence**: `reconcile(intent ∪ toAppend, doc', mdMtime)`
   produces zero inserts, zero removes, and zero new observations.

### Reconciliation paths

Hosts don't call reconcile directly. `Clamshell.page(at:)` returns a stable,
lightweight `Page` facade; operations resolve its current retiring
`PageCoordinator`, which owns the canonical in-memory `Document`, ordered
write generations, editor subscribers, presenters, and pending sync request.
`Page.open(onEvent:)` returns a `PageSession` as soon as the `.md` is loaded +
parsed; the coordinator requests a journal fold in its background sync loop and fires
`onEvent(.restored(count:))` if anything was spliced. Deferring the fold keeps
the home-page critical path clear of the per-device JSONL iCloud reads.

Presenter-wakeup reconcile fires from two presenters installed per
open page:

- **Document presenter** (`DocumentFilePresenter`) — watches the coordinator's URL
  itself. Fires when an external editor or iCloud-delivered foreign
  edit writes the `.md`. Triggers Phase 2 reload (classify echo /
  stomp / external; in-place children swap for external) plus Phase 3
  reconcile.
- **Directory presenter** (`DocumentHistoryPresenter`) — watches the
  per-page `.history/<rel>/` directory. Fires when any peer device's
  `.jsonl` arrives via iCloud (or grows, or a brand-new device's log
  first appears). Same wakeup handler; the journal-side update gets
  picked up even if no `.md` change accompanies it. Without this,
  peer purges that sync after their corresponding `.md` would never
  trigger a re-reconcile and the stale Recover-sheet entries would
  linger.

Both presenters set the same sticky synchronization request. The 250ms
debounce coalesces filesystem bursts; the coordinator waits for the latest
local write generation to become durable before classifying disk content and
folding the journal. A request that arrives during a save or sync remains
pending and runs afterward rather than relying on another presenter wakeup.

If a peer `.jsonl` arrives before its `.md`, records beyond the page envelope's
stamped frontier are treated as pending peer state, not as blocks to restore.
The coordinator leaves both the live tree and disk untouched until the peer
Markdown arrives, then refreshes the canonical document in place. This keeps
the peer's exact sibling order; the recovery log only knows the parent and
would otherwise append the block at the end of that parent's children. Future
records from this device are still restored automatically, preserving the
log-before-file crash guarantee. A peer record whose page never arrives remains
available through Recover rather than being synthesized into an open page.

Closed-page mutations (append, manual recovery, conflict sweep) acquire a
transient lease on the same URL coordinator. Consequently an editor and a
background operation cannot load competing `Document` snapshots for one page.

Log apply is awaited strictly before the file save fires either way
— the at-or-ahead invariant holds across crashes.

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
`Page.resolveConflicts()`; called from Clamshell's internal
file-presenter wakeup (`Clamshell+Presenter.swift`) for the open page
and from `Workspace.resolveConflictsForClosedPages` for closed pages.
The closed-page sweep is **deferred until after the first successful
page session** (kicked by `Workspace.scheduleConflictSweepIfNeeded()` from
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
try clamshell.rescan()

// Get a stable page facade, then open an editor session: load + parse
// the `.md`, install the file presenters, and return immediately. Its
// coordinator runs the journal fold in the background — `.restored` fires later if anything was
// auto-spliced. `.conflictMerged` fires from presenter wakeups when
// iCloud delivers a sibling-version conflict.
// `onEvent` fires only for noteworthy outcomes — non-noteworthy
// wakeups (echo, external reload, nothing) are handled internally.
let page = clamshell.page(at: url)
let session = try await page.open { event in
    switch event {
    case .restored(let n): // show "Restored N blocks..." banner
    case .conflictMerged(let n): // show "Merged N blocks..." banner
    }
}

// Editor-driven write — commit-time atomic save. Non-empty log entries
// are applied to the recovery log; then the .md is serialized and
// written. Calls for the same URL chain so concurrent commits land in
// order. `enqueueEditorChanges` installs the coordinator generation
// synchronously and returns its durability task (the host's sync
// persistCommit hook uses it, so flush cannot overlook the edit).
let durability = session.enqueueEditorChanges(changes)
try await durability.value

// Force-flush any in-flight commits (blur, scenePhase background,
// navigation away, shutdown). No-op if the chain is empty; never
// triggers a save on its own. Throws if the pending save failed.
try await session.flush()

// Close drops this editor attachment, then flushes
// and tears down the presenter when the final handle closes.
try await session.close()

// Trash a page. If it was the home page, homeRelativePath gets cleared.
// The page's .history/<rel>/ dir is moved alongside the .md.
try clamshell.moveToTrash(at: page.url)

// Recover something
let trashed = try await clamshell.listTrashedPages()
let lost = await clamshell.listLostBlocks()

// Restore one lost or purged block. The coordinator finds or loads the
// source page's canonical document.
try await clamshell.page(atPath: entry.source).restore(.lost(entry))
```

**One Clamshell per directory.** Construct with the root URL; never
reconfigure. When the user switches workspaces, throw away the
existing instance and build a new one.

---

## API

| Group | Methods |
|-------|---------|
| Get a page | `page(at:)`, `page(atPath:)` → stable lightweight `Page`; `relativePath(of:)`, `url(for:)`, `pagePath(for:relativeTo:)` remain workspace path conversions. |
| Page | `open(onEvent:)`, `readBlocks()`, `append(_:)`, `restore(_:)`, `resolveConflicts()`, `cloudSyncSnapshot()`, `compactThisDeviceLog()`, `trashAfterInlining(into:)`. Closed-page operations acquire the URL's canonical coordinator document transiently. |
| Page session | `document`, `enqueueEditorChanges(_:)`, `flush()`, `close()`, `cloudSyncSnapshot()`, `compactThisDeviceLog()`. Multiple sessions for one URL share one canonical document and coordinator. |
| Page list and search | `entries`, `entry(at:)`, `rescan()`, `lookupPage(_:)`, `pages(matching:excluding:filter:)` for synchronous title filtering, and async `searchPages(matching:limit:)` for full-text search. Search results carry an internal relative path, title, optional matching passage, modification date, and score; picker rows never display the path. |
| Workspace lifetime | `drain()` awaits all pending generations and shuts down every coordinator. Generic `Commit` construction and `commit(_:to:)` are engine-internal. |
| Create | `createPage(title:requestedPath:initialContent:)` |
| Trash | `moveToTrash(at:)`, `listTrashedPages()`, `restorePage(_:)` |
| Recovery log | `listLostBlocks(filter:)`, `listPurgedBlocks(filter:since:)` |
| Assets | `writeImage(_:)`, `resolveImage(source:)` |
| Home page | `homeURL`, `homeRelativePath` (read-only), `isHome(relativePath:)`, `setHome(relativePath:)` |
| Misc | `root` |

Canonical page loads and writes internally seed a per-URL content-hash
ring buffer that the file presenter classifies against — echo (our
write came back) vs stomp (iCloud rolled us back) vs external (a
different editor wrote). One-shot `Page.readBlocks()` deliberately does
not seed session history. Callers don't manage either case themselves.

Engine orchestration (`reconcile`, `reconcileLive`, conflict-merge
wakeups, coordinator state transitions) is internal to the module — see the Swift
docstrings in `Clamshell.swift`, `Clamshell+Reconcile.swift`, and
`Clamshell+Presenter.swift`, plus `PageCoordinator.swift`.

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

**Full-text search is local and disposable.** Each workspace gets a
SQLite FTS5 database under Application Support rather than inside the
Markdown workspace. The link-graph refresh shares its parse with the
search index for changed files, while successful saves and page lifecycle
operations update the index directly. Queries support ANDed prefix terms
and quoted phrases, use weighted BM25 ranking, and return a short body
passage when the body matched. Schema changes, corruption, and runtimes
without FTS5 fall back safely to title-only search.

**Recovery log is per-device, append-only, no write-time dedup.**
Editor mutations are projected to a `Patch` and applied as one batched
write per mutation. The log actor mints sequential per-page Lamport
counters, encodes JSONL, appends to our device's file. There's no
device-hash cache short-circuiting duplicates: callers either filter
upstream (Clamshell's semantic-change projection filters unchanged
recovery identities; reconcile's `unloggedObservations` filters against
journal intent) or accept a small amount of log bloat (full-doc-walk commits
from conflict-merge or closed-page restore). Intent is unchanged for
duplicates of the same op: duplicate `add`s for the same hash resolve
to the same alive intent, and duplicate `observe`s preserve snapshots
without claiming liveness.

**Log durable before file durable.** Every `commit(_:to:)` runs
log apply + file write inside a single Task, log first. At any point
a crash can happen, the log is at-or-ahead of the file → reconcile
heals on next open. The editor's `EditorHost.persistCommit` protocol
method stays synchronous (typing path can't await) — the host bridge
calls `PageSession.enqueueEditorChanges(_:)`, which installs the generation
before returning, then awaits the returned task only for the failure
banner; only the coordinator writer pays the I/O. Because the enqueue
is synchronous, `PageSession.flush()` (which awaits the current write tail)
can never miss a just-fired commit — blur / scenePhase / nav-away
callbacks land bytes on disk before the editor unmounts.

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

**Bare-md and external edits are absorbed as `observe`, not `add`.**
Reconcile emits an `Observation` for any block present in `doc` but
absent from the journal, folded into the same batched Patch as
unrestorable quarantines. The host writes these out as `observe`
records (not `add`) — we record a snapshot for recoverability
without claiming authorship of blocks we didn't actually author.
A `.md` opened with no `.history/` dir gets every block journaled
as `observe`; an external editor's write gets observed on the next
file-presenter wakeup. If the user later authors a real edit on the
block (typing replaces the content), the editor's diff produces a
genuine `add` for the new hash plus a `purge` for the old one — at
which point the journal has authoritative records and auto-restore
becomes available going forward.

**Live filtering.** A journal entry is only "lost" if its hash isn't
in the live page's atomic-block set right now — re-creating the same
content (e.g. a recurring `# Today` heading) makes the entry live
again automatically without any log mutation.

**Trash invalidates home.** `moveToTrash(at:)` clears
`homeRelativePath` if the trashed page was the home page. The page's
`.history/<rel>/` directory moves alongside the `.md`, so trash +
restore is a page-bundle operation.

**Renaming & link identity.** `renamePage(at:toMatchTitle:)` is O(1):
it moves the `.md`, moves the `.history/<rel>/` bundle (and its
reconcile watermark / counter, migrated inside `RecoveryLog.move`),
re-keys the in-memory caches, follows the home pointer, and rescans —
**it does not rewrite inbound links**. Link integrity comes from the
representation instead:

- Every page has a durable `clamshell-id` (see the on-disk layout).
  Links store it as a fragment; `resolve(pathRel:id:)` treats the ID
  as authoritative — when the index maps the fragment to an existing
  page, that page wins even if the path part now names a different
  file (a new page that reused the old name). Fragment-less links keep
  the historical purely-syntactic path behavior.
- `resolvePageTarget(_:displayText:)` adds a title fallback for legacy
  fragment-less links whose path went stale: a unique live page whose
  title equals the link text resolves the link. Refuses on duplicate
  titles.
- Bytes converge lazily: `healLinks(in:)` (a step in `synchronizePage`,
  so it runs whenever a page is open and quiet) rewrites stale
  destinations to canonical `rel#id` form and commits through the
  normal chain with semantic-change-derived purge/add records — so the
  journal follows the rewrite and reconcile never resurrects the
  stale-link block. This also progressively enriches legacy links with
  fragments. Idempotent: canonical links rewrite nothing.

The page-ID index (`id → rel`) is derived state: rebuilt from the
persisted link cache at init and on every graph build (the cache's
`LinkCacheEntry` gained a `pageID` field), and patched on save/load via
`rememberEnvelope`. It lives behind a `Mutex` because the nonisolated
`pagePath(for:relativeTo:)` (called off-main from the link-graph
classify pass) consults it. The subpage-link classifier that feeds the
graph is `resolveSubpageTarget(_:)` — it normalizes verbatim
destinations (fragment and all) to a live rel path so graph vertices
stay comparable.

**One session write API: `enqueueEditorChanges(_:)` + `flush()`.** The
editor submits its transaction diff without knowing about recovery-log
patches or `Commit`. Internally, every durable write — editor commit,
reconcile catch-up, manual restore, conflict merge, subpage append —
projects to a `Commit` and uses `commit(_:to:)`. The coordinator
generation snapshots the document immediately,
then lands recovery-log entries before its `.md` write. Same-URL
generations run in arrival order, and rapid commits may coalesce while
the tail has not started. `PageSession.flush()` awaits the current tail without
triggering work — for blur, scenePhase backgrounding, and navigation
away. `drain()` is terminal teardown: it awaits every pending generation
and shuts down remaining coordinators; the owner must hold the Clamshell
strongly until it returns (see `Workspace.switchWorkspace`).
Post-save bookkeeping (mtime refresh, title cache, page rescan) fires
internally on every successful commit.

**Editor mutations stream as semantic changes.** Every `Document.transaction`
(forward and undo/redo) derives a pre→post `[DocumentChange]` diff and fires
`Document.didCommitTransaction`, which the editor wires to
`EditorHost.persistCommit(changes:in:)`. The host's adapter projects the
changes onto a `Commit.fromEditorChanges(changes)` through
`PageSession.enqueueEditorChanges(_:)` synchronously (inserts → `.add`,
removes → `.purge`) — the editor's sync hook surface is preserved,
and durability is awaited in a follow-up Task only for the failure
banner. Clamshell owns the canonical SHA-256 recovery identity and filters
semantic snapshots whose on-disk identity is unchanged. Typing goes through the same path:
`commitLiveText` opens a `transaction(name:"Type", coalesceKey:)` and
the resulting diff flows through the same hook. Undo and redo fire it
too with the (inverted) diff so the journal stays symmetric. No
pre/post tree snapshot on the host side and no recovery-hash policy in
Editor — the semantic change stream is the storage adapter's input.

**Deletes and content replacements are explicit, not inferred by the host.**
The semantic diff emits `.removed(block:)` for every deleted block and for
the old snapshot of content changed under a stable block ID.
`Patch.from(changes:)` projects recovery-distinct removals to `.purge` entries that
`log.apply` writes as `purge` records. Save paths never infer
tombstones from comparing prior state to current state. Consequences:
- Typing inside a block produces old/new semantic snapshots. Clamshell
  purges the old recovery hash and adds the new one; formatting or
  whitespace changes with the same canonical recovery identity are filtered.
- External edits to the `.md` (iCloud / other markdown apps) surface
  missing blocks as "lost" in the Recover sheet, never as "Deleted on
  purpose" — Hunch can't infer intent from a write it didn't author.
- A block dragged across pages purges from the source's log; the
  destination's save adds it cleanly.

Reconcile's engine removes (`recon.removes`) **propagate** an explicit
peer-authored `purge` to the live doc; they don't infer one. When a
foreign device's purge log syncs and we have the now-tombstoned block
still in `doc`, we strip it — that's converging to the journal, not
inferring intent.

**Intentional deletions stay recoverable.** Manually-purged hashes
are tracked alongside "lost" entries — the union remembers both the
latest record (purge) and the latest prior `add` (carrying markdown +
parent). `listPurgedBlocks` surfaces them so the user can bring back
something they deleted on purpose. To restore, the host calls
`clamshell.page(atPath: entry.source).restore(.purged(entry))`; internally, a fresh
`.add` for the hash gets appended to the log, and the new counter
beats the prior purge under `(c, device-id)` lex, lifting the
tombstone from the union.
`listPurgedBlocks` defaults to a 30-day window for surface area; pass
`since: nil` to see everything.

---

## Concurrency

`Clamshell`, `Page`, `PageSession`, and `PageCoordinator` are
`@MainActor`-isolated. `Page` is a stable URL facade with no live state;
`PageSession` retains the coordinator for an editor attachment. The retiring
coordinator owns the canonical `Document`, editor subscribers, presenter
lifecycle, transient closed-page leases, ordered write generations, and sticky
synchronization requests for a URL. Keeping generation enqueue on
the MainActor makes installation synchronous; serialization and coordinated
file I/O still hop off the actor. Path conversions, raw reads, and asset I/O
are `nonisolated`. The underlying stores are actors (`RecoveryLog`,
`TrashStore`) or stateless `Sendable` (`FileStore`).

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

- [Clamshell.swift](Clamshell.swift) — workspace-level storage and API:
  page lookup, lists/search, create/trash, recovery lists, home metadata,
  assets, and terminal drain. Page-scoped operations live on `Page` and
  `PageSession`, backed by [PageCoordinator.swift](PageCoordinator.swift).
  The coordinator remains the internal per-URL state machine for canonical
  document ownership, leases, presenters, persistence, and synchronization.
- [PageSearchIndex.swift](PageSearchIndex.swift) — the per-workspace SQLite
  FTS5 index, visible-text extraction, safe live-query compilation, ranking,
  snippets, and disposable-database recovery.
- [Commit.swift](Commit.swift) — the `Commit` value type that
  unifies every durable write (editor commit, reconcile catch-up,
  manual restore, conflict-merge, subpage append). One Commit is the
  recovery-log entries associated with a document snapshot. Factories:
  `Commit.fromEditorChanges(_:)`, `Reconciliation.asCommit()`; the other
  call sites build the value directly.
- [Clamshell+Reconcile.swift](Clamshell+Reconcile.swift) — engine
  orchestration: open-doc reconcile, live-doc reconcile for presenter
  wakeups, and `Page.restore(_:)` for the Recover sheet.
- [Clamshell+Presenter.swift](Clamshell+Presenter.swift) — the
  NSFilePresenter lifecycle, wakeup classification (echo / stomp /
  external), used by `Page.open` / `PageSession.close`. Installs two presenters
  per open page: a `DocumentFilePresenter` on the `.md` and a
  `DocumentHistoryPresenter` on `.history/<rel>/` for peer-log
  changes. Both fire the same idempotent wakeup.
- [PatchEngine.swift](PatchEngine.swift) — the engine. Pure
  Sendable types: `LogJournal`, `LogRecord` (with three ops:
  `add` / `purge` / `observe`), `IntentState` (`.alive` /
  `.observed` / `.tombstoned`), `Reconciliation` (inserts,
  removes, toAppend, unrestorable). Pure functions:
  `intent(from:)`, `reconcile(intent:doc:mdMtime:)`,
  `insertion(rootHash:candidates:intent:doc:)`,
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
  [Quagmire package](../../../Packages/Quagmire/).
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
- **No banners or recovery-sheet UI.** `Page.open(...)` does
  the engine work and surfaces outcomes via `PresenterEvent`s on the
  `onEvent` callback; `Page.restore(_:)` and
  `Clamshell.restorePage(_:)` mutate state and throw on failure. The
  host (`WorkspaceWindow`) shows the resulting banner and routes from
  the Recover sheet's row taps.
- **No move-as-operation.** Moving a block between parents on a device
  that already logged it doesn't append a new record. The original `p`
  goes stale; restore relies on chain-climbing through still-alive
  hashes to find a live ancestor.
- **No log compaction yet.** Logs grow unbounded. For ordinary usage
  they stay small.
