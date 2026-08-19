# Plan: Finalize Quagmire 0.1 and migrate Hunch to one document-link row

> **Executor instructions**: Follow this plan stage by stage. Each stage is a
> separate commit and must be green before the next one starts. Run every
> verification command and confirm the expected result before moving on. If a
> STOP condition occurs, stop and report it instead of inventing a second row,
> a compatibility alias, or a serialization API in Quagmire. This plan changes
> the local package and Hunch together; it does not extract, publish, tag, or
> remotely consume Quagmire.
>
> **Drift check (run first)**:
>
> ```sh
> git -C /Users/joe/src/hunch log --oneline -5
> git -C /Users/joe/src/hunch status --short
> git -C /Users/joe/src/arbor show --stat --oneline 05bcf35
> ```
>
> This plan was written against Hunch `4c35f37` and Arbor `05bcf35`. Every
> line-number citation below is accurate at `4c35f37` and decays as soon as work
> starts — treat them as pointers, re-grep before editing. Stop if Quagmire was
> already extracted, Hunch no longer consumes `Packages/Quagmire`, or Arbor no
> longer uses the exact-source/provider-completed contract in `05bcf35`.

## Status

- **Status**: DONE — 2026-08-18, branch `codex/quagmire-document-link-foundation`
- **Priority**: P1
- **Effort**: L–XL
- **Risk**: HIGH
- **Depends on**: Arbor Plan 000 track, commit `05bcf35` (DONE)
- **Blocks**: `plans/editor-extraction-plan.md` Milestone 7 and Arbor Plan 001
- **Category**: architecture / migration
- **Planned at**: Hunch `4c35f37`, Arbor `05bcf35`, 2026-08-18
- **Revised**: 2026-08-18 after a full audit of the boundary (see
  "What the audit changed" below)

## Why this matters

Quagmire is still local, so its first public API can be neutral and complete
instead of publishing Hunch's flat-page terminology and immediately replacing
it. Hunch's `.subpage` is visually useful but conflates a presentation row, an
authored link label, a storage path, a target's live metadata, and Hunch's trash
policy. The replacement is one format-neutral `documentLink` block that can
reproduce every current Hunch interaction while also representing links to any
host-compatible document, including Arbor Markdown and provider-completed
directory Markdown.

This work also removes source-loss hazards before publication: H4–H6 currently
clamp to H3 and are rewritten on the next save, and unrepresentable Markdown
(tables, raw HTML) degrades to a paragraph of re-rendered text. Stable
`BlockID` behavior — not Markdown ranges, source snapshots, or source handles in
Quagmire — is the reusable seam that a future TreeHopper host will use for its
private source-reuse ledger.

### What the audit changed

The first draft of this plan renamed the host API but left every mechanism a
remote backend needs either synchronous or absent. Four additions came out of
auditing the code rather than the docs:

1. **`lookupPage` is synchronous and load-bearing.** It is called from
   `resolvePageLookups` during row construction and its result is stored on
   `BlockRow` and compared in `==` for `.equatable()` gating. Making it async
   would destroy that gating. The answer is to keep it synchronous and specify
   the pattern Clamshell already uses but Quagmire never documents: *sync read
   of host-owned cache + async warm + observation-driven re-render*. That needs
   a `pending` state and an explicit warm hook (Step 6).
2. **`suggestPages` is synchronous.** Not on the gated hot path, so it can
   simply become `async` with `.task(id: query)` cancellation.
3. **Whole-document replacement is the real integration seam and its current
   behavior is wrong.** Arbor's write contract returns provider-completed source
   that becomes the next base, so an ordinary save can hand the client a new
   body. Today the only mechanism is `Document.replaceChildren`, which
   unconditionally clears the undo stack. Its hook doc asserts "Fresh parse →
   fresh BlockIDs" — already false for three of Hunch's four production call
   sites, which are ID-*preserving* splices. Hunch therefore already wipes an
   open page's undo stack when another window appends to it. Step 2 splits this
   in two.
4. **`unsupported` does not make Markdown round-tripping lossless.** Several of
   Hunch's losses happen before the node switch that would produce one. The
   "Known-lossy paths" section below states exactly what survives and what does
   not, and the done criteria no longer overclaim.

## Decided public boundary

These decisions are requirements, not open design questions:

1. There is exactly one block-level reference row: `documentLink`. Delete
   `.subpage`; do not retain a deprecated alias or parallel compatibility case.
2. The row stores an authored `AttributedString` label and an opaque,
   string-backed host reference. It does not store a filesystem path, PageID,
   Arbor reference, target title cache, icon cache, missing state, permissions,
   or trash policy.
3. Host lookup supplies ephemeral presentation for the opaque reference. The
   state set is closed:

   | State | Meaning |
   |---|---|
   | `pending` | host has not resolved this reference yet; a warm is in flight or can be requested |
   | `present(title:icon:capabilities:)` | resolved and reachable |
   | `missing` | resolved and known not to exist (trashed, renamed, never created) |
   | `unavailable` | exists but not reachable right now (offline, permissions) |

   Display precedence is unchanged from today: presentation `title` when the
   host supplies one, authored `label` otherwise. That is what lets Hunch keep
   showing live titles while a host whose labels are authored source (Arbor)
   simply returns no presentation title.

4. Target capabilities are per-reference, not global. The set is closed:
   `navigate`, `receiveBlocks`, `inline`, `setIcon`, `delete`. `pending` and
   `missing` expose no destructive action and do not navigate. The two flags
   that are genuinely about the host rather than a target — document creation
   and the move-destination picker — stay global.
5. `lookupDocument` must remain a cheap synchronous read of host-owned state.
   The host must be observation-tracked so that completing a warm re-renders
   rows. `requestPresentation(for:)` is the non-blocking warm hook the editor
   calls from `.task` for references it rendered `pending`. This contract is
   what makes the `.equatable()` row-gating architecture legal for a remote
   host, and it must be stated in `Packages/Quagmire/README.md`.
6. Mentions offer one list of document candidates, fetched asynchronously.
   Selecting one is contextual, not a three-way insertion choice: a line-leading
   mention creates `documentLink`; an inline mention creates an inline link.
   "Create document from block" remains a separate Cmd-K/Turn Into action.
7. `HeadingLevel` represents H1 through H6. Existing creation menus and prefix
   transforms may remain H1–H3, but parsing, model operations, nesting,
   rendering, copy/paste, undo, and serialization must preserve H4–H6.
8. Add one read-only, leaf `unsupported` block with a host-opaque string payload
   and a neutral display label/preview. Quagmire never parses or rewrites the
   payload. This is a per-block value, not a document source snapshot, range,
   parser token, or source handle.
9. Quagmire remains format-neutral: no `swift-markdown`, Arbor types, Markdown
   codec, source ledger, source snapshot, byte/character ranges, opaque source
   handles, persisted annotations, or generic metadata bag.
10. `persistCommit` remains synchronous and `flush` awaits every generation the
    host admitted before the callback returned.
11. Document-level properties (title, icon, cover, frontmatter) stay host-owned
    and out of the block model. Hunch keeps home-page state in `.clamshell.json`
    and derives a row icon from the target's H1; Arbor preserves YAML
    frontmatter in its own codec. Say this explicitly in the README — it is
    adjacent to `setDocumentIcon`, which this plan renames.

## BlockID lifecycle contract

Document and test this exact matrix. IDs are scoped to one live `Document`;
they are editor identity, not persisted storage identity.

| Operation | Required identity behavior |
|---|---|
| edit text, marks, kind, label, reference, checkbox, language, or other in-place value | preserve the block ID |
| move, reorder, indent, outdent, or reparent a block/subtree in the same document | preserve every moved ID |
| forward mutation, undo, and redo | restore the exact IDs present in the corresponding snapshot |
| split | original ID stays with the leading/original row; trailing/new row receives a fresh ID |
| merge/backspace | receiving/surviving row keeps its ID; removed row's ID dies; moved descendants keep theirs |
| line-leading mention or Turn Into conversion replacing a row in place | replacement keeps the source row ID |
| paste, template instantiation, explicit duplicate/copy | recursively mint fresh IDs, regardless of IDs returned by a host parser |
| cross-document copy/move or inline of loaded blocks | destination copies receive fresh IDs; source IDs live until destination durability succeeds and source removal commits |
| **reconciled** system replacement (host splices into the existing tree, reusing IDs) | Quagmire preserves undo and remaps editor state by ID; no authored commit is emitted |
| **unreconciled** system replacement (host supplies an entirely new tree) | host supplies the replacement IDs; Quagmire does no source matching, emits no authored commit, clears unsafe undo, and revalidates editor state |

Add focused tests for every row. Do not promise that IDs survive process
restart, parsing the same file again, or two independently opened documents.

The two replacement rows are not hypothetical. At `4c35f37`, three of Hunch's
four production call sites are reconciled splices routed through the
unreconciled path:

| Call site | Shape |
|---|---|
| `App/Sources/Clamshell/Clamshell.swift:1737` (`append`) | `document.children + blocks` — every existing ID preserved |
| `App/Sources/Clamshell/Clamshell.swift:1722` (`setIcon`) | mutates one H1 in place within the existing tree |
| `App/Sources/Clamshell/Clamshell+Reconcile.swift:364` | auto-restore splice derived from `document.children` |
| `App/Sources/Clamshell/Clamshell+Presenter.swift:225` | genuine fresh parse (external edit) — stays unreconciled |

The paste and loaded-block remints below close a *latent* hazard, not a
reproducible bug: Hunch's `parseBlocksFromPasteboard` and `loadPageBlocks` both
go through `BlockParser`, which mints fresh IDs. Do not go looking for a failing
test against the current host — close it by construction at the editor boundary
so a third-party host cannot introduce duplicates.

## Hunch parity contract

Hunch's on-disk syntax remains ordinary Markdown: a standalone link to a `.md`
document (optionally with its current fragment) parses as `documentLink`, and
serialization emits the same standalone Markdown link. All of these existing
behaviors must work through the new row and neutral host names:

- row rendering, indentation/nesting, selection, Return/right-arrow/tap
  navigation, back navigation, and missing-target presentation;
- live target title and icon presentation plus the row icon picker;
- line-leading and inline mentions, inline-link classification, Cmd-K, and Turn
  Into → Document;
- crash-safe Create from Block: create the destination durably before replacing
  the source row, so failure may leave a duplicate but never loses the only copy;
- Turn Into another block: load the target before changing the parent, insert
  fresh-ID copies, flush the parent, then move the source document to Trash;
- drop/copy/move blocks onto a document link: durably append fresh-ID copies to
  the destination before removing the source blocks;
- Move To picker destinations, Add Current Page To, Copy Page Link, pasteboard
  serialization, and multi-window navigation splice;
- deleting a block-level document link and Hunch's orphan/trash prompt. The
  generic editor callback reports link deletion; the Hunch host alone decides
  whether to prompt. Deleting an inline link does not invoke it;
- rename/link healing, PageID-fragment handling, backlinks/link graph, search,
  recovery fingerprints, reconciliation de-duplication, and Trash/restore.

Hunch currently only offers Markdown page targets, so no existing behavior is
intentionally interrupted. A future host may omit actions when a reference is
missing, unavailable, read-only, or not document-compatible; Quagmire must
hide/disable those affordances before their first mutation. Do not encode that
future host policy as a second block kind.

**Two behaviors in this list are to be fixed, not preserved:**

- `didDeleteSubpageLink` (`App/Sources/WorkspaceWindow+EditorHost.swift:39-89`)
  raises the trash prompt off an in-memory `document.children` snapshot and a
  possibly-cached `LinkGraph`, awaiting no flush of the source document.
  Compare `trashAfterInlining` (`App/Sources/Clamshell/Clamshell.swift:1748-1752`),
  which does `await parent.flush()` before `moveToTrash` — that flush is the
  only place the inline-before-delete invariant is actually enforced, because
  the preceding `mutate` only enqueues. The delete path has the same shape and
  none of the protection.
- `serializeBlocksForPasteboard` and `serializeAtomic` pass
  `titleForPath = { _ in nil }` (`App/Sources/Clamshell/Serializer.swift:217, 240`),
  so pasteboard copies and recovery-log atomic snapshots carry the stale
  in-block title. Decide deliberately — probably resolve for the pasteboard and
  keep stale-but-stable for the recovery snapshot so fingerprints do not churn —
  and test it, because the requirement that recovery de-duplication keys on
  reference identity rather than presented title depends on it.

Neither ordering is covered by a test today. Nothing in `App/Tests` exercises
`inlineAndTrashPage` / `convertSubpage` end to end, nothing asserts
`moveBlocks(intoSubpagePath:)`'s append-before-remove ordering, and the
Quagmire-side tests stub the host. The orderings are asserted by comment only.

## Known-lossy paths this plan does NOT fix

`unsupported` covers the block kinds swift-markdown surfaces as distinct nodes
that Hunch's converter does not handle. It does not make Markdown round-tripping
lossless, and the done criteria must not claim it does.

| Loss | Where | Fixed by `unsupported`? |
|---|---|---|
| Tables | `App/Sources/Clamshell/Parser.swift:546` `default:` | Yes |
| Raw HTML blocks | `Parser.swift:530-533` | Yes |
| Unknown block directives / asides | `Parser.swift:544` | Yes |
| Link reference definitions (`[b]: url`) | cmark resolves them at parse time and emits no node | **No** — silently vanishes on next save |
| Footnotes (`[^1]`) | footnote extension is not attached; parses as ordinary text | **No** |
| Nested block-quote depth (`>>`) | `Parser.swift:506-516` flattens each child paragraph to a sibling `.quote` | **No** |
| Inline unknowns (math spans, footnote refs) | Quagmire's inline model is a closed `AttributedStringKey` set | **No** — flattens to text |
| Setext headings | re-emitted as ATX | No, and that is fine |

The `unsupported` payload must be **byte-exact**, built from the original source
substring via `Markup.range` — which is public, populated during parsing, and
referenced nowhere in this repo today. Do not build it from `markup.format()`:
`MarkupFormatter` re-renders from the AST and normalizes pipe alignment,
emphasis delimiters, escaping, and wrapping. Reading the range once at parse
time against the source string already in hand satisfies the "no document-wide
source tracker" STOP condition below.

## Current state

Quagmire:

- `Packages/Quagmire/Sources/Quagmire/Model/Block.swift:6-26` defines H1–H3
  only, with both a failable `init?(level:)` and a saturating `clamped(_:)`.
  Both need widening, and call sites that relied on `clamped` swallowing 4–6
  need review rather than mechanical widening. `BlockKind` at lines 31–44 stores
  `.subpage(title: String, pageID: String)`.
- `Block.swift:49-58` already gives every block an immutable, host-suppliable
  `BlockID`; `:180-186` recursively remints copies (`withFreshIDs()`). Its only
  call sites are `EditorView.swift:847` and three drag-copy sites in
  `EditorView+Reorder.swift` — notably *not* the paste path.
- `Packages/Quagmire/Sources/Quagmire/EditorHost.swift` is 291 lines with 21
  protocol requirements, every one of which has a default implementation
  (`:210-237`). `PageLookup` (`:12-28`) has two states; the three capability
  flags (`:38-48`) are global.
- `Packages/Quagmire/Sources/Quagmire/BlockRow.swift:690-705`
  (`resolvePageLookups`) is where the synchronous `lookupPage` call happens; its
  result is stored on `BlockRow` and compared in `==`. `:326-328` renders
  `lookup?.title ?? title`. `:340-348` (`headingRow`) picks the font with a
  `.h1/.h2/.h3` ternary chain. `:619-646` (`leadingEmojiIcon`) derives the row
  icon from the target's title string — there is no icon field anywhere.
- `Packages/Quagmire/Sources/Quagmire/EditorTheme.swift:111-113, 256-261` has
  `h1Size/h2Size/h3Size`; `:418-420` switches `BlockSpacing` on
  `.heading(.h1)/.h2/.h3`. Both need 4–6 or the model change ships
  un-renderable rows. The heading *fold* needs no change: `Block.canContain`
  uses `childLevel > myLevel` and `Document.applyHeadingContainment` is
  level-generic.
- `Packages/Quagmire/Sources/Quagmire/EditorView+Mention.swift:153-176` already
  has the correct contextual interaction, delegating to
  `MentionTrigger.swift:60-72` (`mentionStartsSubpageBlock`). Preserve that
  behavior; do not add insertion-mode choices to `MentionItem` or the menu.
  The marker list there needs `####`, `#####`, `######`.
- `Packages/Quagmire/Sources/Quagmire/Model/Document.swift:259-300` separates
  non-authored whole-tree system replacement from transactions and clears
  undo unconditionally. The `didReplaceChildren` doc comment (`:80-83`) asserts
  "Fresh parse → fresh BlockIDs" and is false for most callers.
- `Packages/Quagmire/Sources/Quagmire/EditorView.swift:1912-1980` trusts IDs in
  host-parsed paste blocks; `EditorView+TurnInto.swift:240-259` trusts IDs in
  host-loaded blocks. Remint recursively at the editor boundary in both. (The
  doc comments at `EditorView.swift:1905-1911` and `:1939-1946` are already
  stale relative to the tree-based implementation — fix them while you are there.)

Hunch:

- `App/Sources/Clamshell/Parser.swift:687-734` recognizes standalone `.md` links
  and list-child variants as subpages. Rename the concept but preserve the exact
  recognition rule and legacy healing. Note `detectSubpage` (`:713-734`) builds
  the title from direct `Markdown.Text` children only, so a formatted link
  label yields an empty title and falls back to the destination path — decide
  whether to fix that or document Hunch labels as plain text.
- `App/Sources/Clamshell/Serializer.swift:283-292` already serializes any
  represented heading depth mechanically; expanding `HeadingLevel` makes H4–H6
  lossless. `:339-342` serializes the current subpage row as ordinary Markdown
  and must do the same for `documentLink` — and unlike `.image` one line below,
  it does not escape the label, so a title containing `]` emits a broken link.
- `App/Sources/WorkspaceWindow+EditorHost.swift` is the compatibility harness
  for navigation, lookup, create/load/inline/append, icon, deletion policy,
  pasteboard, synchronous enqueue, and flush. Rename and adapt these methods
  without weakening their durability order.
- `Packages/Quagmire/scripts/verify.sh` is the package release-boundary gate:
  SwiftPM tests plus clean macOS and iOS Simulator builds. It runs
  `swift package clean` and two clean `xcodebuild`s — right as a gate, too slow
  for the inner loop.

Blast radius. `rg 'subpage|Subpage|pageID|PageID'` over `Packages/Quagmire` and
`App` returns **467 matches across 55 files**, not the handful cited above.
Concentration:

| Side | Files |
|---|---|
| Quagmire sources | `EditorView.swift` (50), `EditorView+TurnInto.swift` (40), `EditorHost.swift` (35), `BlockRow.swift` (26), `EditorView+Reorder.swift` (15), `Model/Block.swift` (11), `EditorTheme.swift` (10) |
| Hunch sources | `Clamshell/Clamshell.swift` (60), `WorkspaceWindow+EditorHost.swift` (44), `Clamshell/LinkGraph.swift` (43), `Clamshell/Serializer.swift` (23), `ContentView.swift` (18), `Clamshell/Parser.swift` (18), `RecordingButton.swift` (15) |
| Tests | `PageIDTests` (56), `RoundTripTests` (29), `EditorViewSubpageDeleteTests` (28), `LinkHealingTests` (24), `SubpageTrashDecisionTests` (20), `EditorViewToggleExpansionTests` (17), `PatchEngineTests` (14) |

`EditorTheme.swift`, `BlockLayoutCache.swift`, `EmojiCompletion.swift`,
`RecordingButton.swift`, `ContentView.swift`, and the `Document.replaceChildren*`
family are all in scope.

Repository conventions:

- `Packages/Quagmire` owns editing and neutral host calls; Clamshell owns
  Markdown and persistence; `WorkspaceWindow` adapts between them.
- `project.yml` is XcodeGen source of truth. Never hand-edit the project; run
  XcodeGen and commit the generated `Hunch.xcodeproj` diff when membership
  changes.
- Hunch unit tests link through the app target. Do not add Quagmire as a direct
  `HunchUnitTests` dependency or it will link a second copy.
- Preserve the one-editor/one-live-text-view model, `Document.transaction` as
  the sole authored mutation path, and the same-value guards on observable UI
  state described in `CLAUDE.md`.

## Commands you will need

Run Xcode commands sequentially.

| Purpose | Command | Expected on success |
|---|---|---|
| Package inner loop | `swift test --package-path Packages/Quagmire` | exit 0 |
| Hunch inner loop | `xcodebuild test -project Hunch.xcodeproj -scheme Hunch -destination 'platform=macOS' -derivedDataPath /tmp/hunch-doclink CODE_SIGNING_ALLOWED=NO` | exit 0, all tests pass |
| Quagmire release boundary | `Packages/Quagmire/scripts/verify.sh` | package tests and clean macOS/iOS Simulator builds exit 0 |
| Regenerate project | `xcodegen generate --spec project.yml --project .` | exit 0; only deterministic project membership changes |
| Hunch macOS build | `xcodebuild build -project Hunch.xcodeproj -scheme Hunch -destination 'platform=macOS' -derivedDataPath /tmp/hunch-document-link-macos-build CODE_SIGNING_ALLOWED=NO` | exit 0 |
| Hunch iOS 27 build | `xcodebuild build-for-testing -project Hunch.xcodeproj -scheme Hunch -destination 'platform=iOS Simulator,id=C76DE979-27D7-4BE5-AD11-3FC223402AB9' -derivedDataPath /tmp/hunch-document-link-ios CODE_SIGNING_ALLOWED=NO` | exit 0 (iPhone 17 Pro / iOS 27.0, verified present) |
| Stale API sweep | `rg -c 'subpage\|Subpage\|pageID\|PageID\|lookupPage\|suggestPages\|openPage' Packages/Quagmire/Sources Packages/Quagmire/Tests Packages/Quagmire/README.md` | **zero** — this is the surface being frozen. Hunch keeps its own vocabulary (`resolveSubpageTarget`, `SubpageTrashDecision`, `openSubpage`, the `pageID` field in the recovery format) because "subpage" is genuinely what Hunch calls this feature; the boundary is what matters, not the word |
| Boundary sweep | `rg -n 'Markdown\|Arbor\|sourceRange\|sourceSnapshot\|sourceHandle\|SourceHandle\|metadata:' Packages/Quagmire/Sources` | no new format/storage coupling; existing user-facing Markdown/paste comments must be reviewed, not blindly deleted |
| Diff check | `git diff --check` | no output |

## Scope

**In scope**:

- all `.subpage`/page-reference switches and names under
  `Packages/Quagmire/Sources/Quagmire/`, including `EditorTheme.swift`,
  `BlockLayoutCache.swift`, and the `Document.replaceChildren*` family;
- Quagmire tests and public API tests under `Packages/Quagmire/Tests/`;
- the Hunch adapter and every parser/serializer/link/recovery/search call site
  matched by the stale API sweep under `App/Sources/` and
  `App/Tests/HunchUnitTests/`;
- `Packages/Quagmire/README.md`, `README.md`, `CONTRIBUTING.md`, and `CLAUDE.md`;
- `project.yml` and generated `Hunch.xcodeproj` only if test/source membership
  changes require regeneration;
- `plans/README.md`, this plan's status, and the dependency note in
  `plans/editor-extraction-plan.md`.

**Out of scope**:

- extracting Quagmire, creating a repository, changing Hunch to a remote
  package, tagging/releasing `0.1.0`, pushing, or opening a PR;
- any code change in `/Users/joe/src/arbor` or any TreeHopper native adapter;
- Arbor's source ledger, Markdown codec, provider, protocol, browser, or cloud
  journal;
- changing Hunch bundle IDs, app name, app group, iCloud container, or
  Clamshell sidecar format;
- persisting editor `BlockID` in Markdown or recovery metadata;
- introducing a general plugin/action registry or a second document-link row;
- the known-lossy paths listed above (footnotes, link reference definitions,
  nested block-quote depth, inline unknowns);
- document-level properties as a block-model concept.

## Git workflow

- Branch if needed: `codex/quagmire-document-link-foundation`.
- **One commit per stage**, each building and passing its stated verification.
  The original single-commit instruction was dropped: this is a 55-file change
  bundling four independent concerns, and only Step 5 is a breaking rename.
  Staging keeps the diff reviewable and bisectable while preserving the property
  that no committed state leaves Hunch unable to build against its local package.
- Do not push, tag, publish, or remove `Packages/Quagmire`.

## Steps

### Step 0: Commit the plan docs

This plan was untracked. Commit it, `plans/README.md`, and the Milestone 7
dependency note in `plans/editor-extraction-plan.md` on their own before any
code changes, so the rest of the chain has a tracked artifact to point at.

**Verify**: `git status --short` shows no plan-doc changes.

### Step 1: Characterize the identity lifecycle, and close the two remint gaps

Add `Packages/Quagmire/Tests/QuagmireTests/BlockIdentityLifecycleTests.swift`
covering every row of the matrix against current behavior, using
`DocumentMutationTests.swift` and `DocumentTransactionTests.swift` as
structural patterns. The H1–H6 and unsupported-payload tests land in Steps 3
and 4 where they pass, rather than as red tests here — every stage commit stays
green, which is the stronger property.

Some of the operations under contract are `private`/`fileprivate` key handlers
(`splitBlock`, `deleteEmptyBlock`, `commitMention`, `spliceParsedBlocksAfter`,
`convertSubpage`). Relax them to `internal` so the matrix is executable against
the real code paths — `internal` is not public API, and asserting identity
through the actual handlers is the whole point.

Then close both remint gaps at the receiving editor boundary via the existing
`Block.withFreshIDs()`:

- `EditorView.spliceParsedBlocksAfter` (`EditorView.swift:1947-1980`);
- the loaded-blocks splice in `convertSubpage`
  (`EditorView+TurnInto.swift:240-259`).

Do not hunt for a failing test proving a live paste collision — there is none
against the current host (see the BlockID contract above).

**Verify**: `swift test --package-path Packages/Quagmire` → green.

### Step 2: Split the system-replacement seam

In `Model/Document.swift`:

- Add a reconciled replacement path that takes a host-supplied tree and, when
  the incoming ID set is compatible with the undo stack, **keeps** undo and
  fires a hook that lets the editor remap selection/cursor by ID instead of
  resetting it.
- Keep the existing clear-everything path for genuine fresh parses.
- Correct the `didReplaceChildren` doc comment (`:80-83`).
- Document both rows in `Packages/Quagmire/README.md`.

Migrate the three ID-preserving Hunch call sites (`Clamshell.swift:1722`
`setIcon`, `Clamshell.swift:1737` `append`, `Clamshell+Reconcile.swift:364`
link healing) to the reconciled path. Leave `Clamshell+Presenter.swift:225`
(external reload) and `Clamshell.swift:1798` (conflict merge) on the clearing
path.

`setIcon`'s no-H1 branch wraps the existing body under a new heading, which
reparents blocks that already existed. That is not expressible as a rebase, so
it degrades to a wholesale replacement on its own — no special-casing needed at
the call site, and the degradation is asserted by a test.

While here: `DocumentUndoControllerTests.macTextChangesCommitAfterCheckpointDelay`
slept a fixed 850ms against a 750ms checkpoint, which flaked under load and
became a hard failure once this stage's tests were added. It now polls with a
deadline.

**Verify**: package tests, plus Hunch macOS tests — `ClamshellSavingTests`,
`PageCoordinatorTests`, and `RecoveryLogTests` already exercise these call
sites. New test: appending to an open page from a second window preserves that
page's undo stack and cursor.

### Step 3: H1–H6 end to end

- `Model/Block.swift`: widen `HeadingLevel` (both `init?(level:)` and
  `clamped(_:)`); audit call sites that relied on clamping.
- `EditorTheme.swift`: heading sizes for 4–6 (prefer a `headingSize(_:)`
  accessor over three more stored properties) and `BlockSpacing` cases.
- `BlockRow.headingRow`: replace the ternary chain with the accessor.
  `BlockLayoutCache`: heading identity for 4–6.
- Decide and document: creation menus and prefix autotransforms stay H1–H3;
  `MentionTrigger` markers stay in sync with whatever prefixes exist; Turn Into
  on an existing H4–H6 maps to the nearest offered level and says so;
  page-title detection remains H1-only.
- Hunch: `Parser.swift` stops clamping. `Serializer.swift:284` already emits any
  depth mechanically.

**Verify**: package tests + Hunch macOS tests; new `RoundTripTests` case for
H4–H6 surviving parse → unrelated edit → serialize.

### Step 4: The `unsupported` leaf

- `BlockKind.unsupported(payload: String, display: String)` — leaf, no children,
  read-only, selectable/movable/deletable/copyable, participates in undo, may
  sit inside a list item or toggle for indentation fidelity. `Block.text`
  returns empty; `withText` is a no-op. Exhaustive-switch fallout across
  `Block.swift`, `BlockRow`, `BlockLayoutCache`, `BlockSpacing`,
  `EditorPlainTextCodec` (`EditorHost.swift:239-276`), and Turn Into gating.
- Hunch: the `default:` arm (`Parser.swift:546-552`) and the unrecognized
  `HTMLBlock` arm (`:530-533`) emit `.unsupported`, with the payload taken
  byte-exact from the source substring via `Markup.range`.
  `Serializer.swift` emits the payload verbatim at the block's indent depth.
- Do not build a document-wide source tracker in Hunch or Quagmire.
- Update the known-lossy table in this plan if anything moves between columns.

**Verify**: package tests; new Hunch round-trip fixtures containing a GFM table
and a raw HTML block surviving parse → edit elsewhere → serialize
byte-identically. These are the first tests of the parser's `default:` arm —
nothing in `App/Tests` or `Packages/Quagmire/Tests` currently mentions a table,
a footnote, `####`, or H4.

### Step 5: The mechanical rename

- Replace `.subpage(title: String, pageID: String)` with
  `.documentLink(label: AttributedString, reference: DocumentReference)`.
- Introduce a small public opaque string-backed reference type instead of
  leaking raw `pageID` names through every API. Hunch's ids already carry an
  optional `#fragment` (`ClamshellPageEnvelope.splitPageFragment`), which the
  opaque type carries unchanged.
- Rename host methods and state (`suggestDocuments`, `openDocument`,
  `lookupDocument`, `linkURL(for:)`, `didDeleteDocumentLink`, create/load/
  inline-and-trash/append, `resolveReference(from:in:)`, `setDocumentIcon`,
  move target, drop state, command names) consistently.
- Keep required persistence/flush methods unchanged.
- Use exhaustive compiler failures to find every switch. Do not add temporary
  aliases — the package and its only current host migrate together.
- Hunch: recognition rule and emitted Markdown unchanged. Two correctness fixes
  belong with the label type change: escape the label in `Serializer.swift:340`
  the way `.image` does one line below, and either preserve formatted link
  labels in `Parser.detectSubpage` or state in the README that Hunch labels are
  plain text.
- Rename test files whose names expose obsolete public vocabulary
  (`SubpageTrashDecisionTests`, `EditorViewSubpageDeleteTests`).

Behavior-identical. Disk syntax byte-identical against unchanged fixtures.

**Verify**: `Packages/Quagmire/scripts/verify.sh` + Hunch macOS tests + both
sweeps.

### Step 6: The host boundary complex backends need

- `DocumentPresentation` with the four states from the boundary section.
- `DocumentCapabilities` as a closed `OptionSet`: `navigate`, `receiveBlocks`,
  `inline`, `setIcon`. Replaces the per-target uses of
  `supportsSubpageInlining`; document creation and the move picker stay global.
  `pending`, `missing`, and `unavailable` expose nothing at all.
  `delete` was dropped: deleting the row is always allowed (it is this
  document's content) and whether that should also delete the target is host
  policy reported through the deletion callback, so the editor never gates on
  it. Only what the editor actually gates is in the set.
- ~~`requestPresentation(for:)` warm hook~~ — **dropped during implementation.**
  A separate hook would be a second mechanism doing what `lookupPage` already
  does: Hunch's implementation kicks a deduped background warm as a side effect
  of a cache miss and publishes through `@Observable`, and that pattern works
  for a remote host too. What was actually missing was a state to return while
  the warm runs. So `.pending` plus a documented contract — cheap sync read,
  deduped background work, observation-tracked host — rather than a hook every
  host would have to implement alongside the lookup it already has.
- `suggestDocuments` becomes `async`, driven by `.task(id: query)` with
  cancellation and a searching state in the mention menu.
- `MentionTrigger.swift:60-72` gains `####`, `#####`, `######`.
- Hunch supplies full capabilities for every present Markdown target, so no
  existing action is lost; missing targets remain visibly missing and inert.
- README: state the sync-read / async-warm / observation-tracked contract, and
  that presentation `icon` is derived from the title for Hunch (there is no
  icon store — `setDocumentIcon` rewrites the target file's H1) but exists so a
  backend with real icons can supply one.

**Verify**: `verify.sh` + Hunch macOS tests; a test host in
`QuagmirePublicAPITests` that answers `pending` first and `present` after a
warm, proving the row updates without a document mutation.

### Step 7: Parity, failure injection, durability fixes, docs, gate

Add or retain end-to-end unit coverage for every item in the Hunch parity
contract. Include failure injection for:

- destination create failure leaves the source intact;
- inline load failure leaves the parent link intact;
- parent flush failure prevents Trash;
- destination append failure prevents source removal;
- missing/unavailable/pending target exposes no destructive or navigation action;
- deleting a row fires one host callback after commit, while deleting an inline
  link does not;
- rename healing and recovery de-duplication use reference identity rather than
  the presented title;
- unsupported payload and H4–H6 survive parse → edit elsewhere → serialize.

Apply the two durability fixes from the parity contract: flush the source
document before raising the trash prompt, and resolve the stale-title question
for pasteboard vs recovery snapshots.

Use existing `RoundTripTests`, `LinkHealingTests`, `SubpageTrashDecisionTests`,
`PatchEngineTests`, and Quagmire row/mention tests as structural patterns.

Docs: `Packages/Quagmire/README.md` (block model, host protocol, identity
matrix, the sync-read/async-warm contract, stated non-goals), `README.md`,
`CONTRIBUTING.md`, `CLAUDE.md`, `plans/README.md`, and this plan's status.
Update prose from "subpage block/API" to "document-link row," while user-facing
prose may explain that a standalone page link is presented as the familiar
subpage row. Do not claim publication or remote installation.

Then run, sequentially:

1. `Packages/Quagmire/scripts/verify.sh`
2. `xcodegen generate --spec project.yml --project .`
3. Hunch macOS tests
4. Hunch macOS build
5. Hunch iOS 27 build-for-testing
6. both stale/boundary sweeps
7. `git diff --check`

Review the diff to confirm Quagmire contains no Hunch, Clamshell, Arbor,
Markdown-parser, source-ledger, or storage identity. Confirm all old Hunch
on-disk fixtures still parse and serialize compatibly. Update this plan and
`plans/README.md` to DONE with exact verification counts and the final Hunch
commit; leave extraction Milestone 7 TODO but unblocked.

**Verify**: every command exits 0 and `git status --short` is clean.

## Test plan

New Quagmire coverage should include:

- `BlockIdentityLifecycleTests.swift` for every identity matrix row, including
  both replacement rows;
- public consumer compilation of `DocumentReference`, `documentLink`,
  presentation/capability values, H4–H6, `unsupported`, and the neutral
  `EditorHost` defaults;
- a test host that answers `pending` then `present`, proving warm-driven
  re-render without a document mutation;
- mention tests proving one contextual candidate selection, with async
  suggestions;
- row/render/command/drop/Turn Into tests for present, missing, unavailable, and
  pending document references;
- duplicate-ID paste/copy defense and fresh-ID loaded-block inline.

Hunch coverage should migrate rather than erase the current behavior corpus,
especially round-trip, link healing, link graph, search, recovery fingerprint,
PatchEngine de-duplication, trash decision, icon, navigation, and durability
failure tests — and add the coverage that does not exist today: the parser's
`default:` arm, H4–H6, and the app-side durability orderings.

## Done criteria

- [ ] Quagmire has exactly one `documentLink` row and no `.subpage` alias.
- [ ] The row has an attributed authored label and opaque host reference;
      presentation/capabilities remain ephemeral, host-owned, and per-reference.
- [ ] `lookupDocument` stays synchronous, gains a `pending` state and a warm
      hook, and the README states the observation contract that makes it legal
      for a remote host.
- [ ] `suggestDocuments` is async and cancellable.
- [ ] Reconciled and unreconciled system replacement are separate operations;
      an ID-preserving splice no longer clears the undo stack.
- [ ] Mention selection has one candidate list and contextual line/inline
      insertion, not three insertion choices.
- [ ] H1–H6 survive parse, edit, and serialize, and render at all six levels.
- [ ] Table and raw-HTML blocks survive byte-identically through
      `unsupported`; the remaining lossy paths are documented, not claimed fixed.
- [ ] The complete BlockID lifecycle matrix is documented and tested.
- [ ] Quagmire contains no Markdown/Arbor/source-ledger/range/handle/storage
      coupling or generic metadata escape hatch.
- [ ] Every feasible Hunch subpage behavior passes through `documentLink`; no
      existing Hunch Markdown target loses an action.
- [ ] Cross-document failure tests prove duplicate-over-loss ordering, and the
      trash prompt flushes the source document first.
- [ ] `persistCommit` admission remains synchronous and `flush` cannot observe
      false quiescence.
- [ ] Package verification, Hunch macOS tests/build, and iOS 27 build all pass.
- [ ] Quagmire is still local and unpublished; extraction Milestone 7 is only
      unblocked, not executed.
- [ ] `plans/README.md` records DONE, verification evidence, and final commit.

## STOP conditions

Stop and report instead of improvising if:

- preserving a current Hunch interaction appears to require retaining
  `.subpage` beside `documentLink`;
- a proposed generic link action only works by putting filesystem, PageID,
  Arbor, Markdown, or Trash semantics into Quagmire;
- stable in-document IDs appear to require persisting IDs, source ranges,
  parser tokens, or source handles in Quagmire;
- making `lookupDocument` usable by a remote host appears to require making it
  async — that would destroy the `.equatable()` row gating; the answer is the
  warm hook plus a `pending` state;
- H4–H6 support requires exposing them in creation UI (it should not);
- a cross-document workflow can remove the only durable copy before the
  destination or parent is durable;
- the package passes only after weakening Hunch's log-before-file,
  synchronous-admission, undo, selection, or one-live-editor invariants;
- exact unsupported-source preservation in Hunch would require a document-wide
  source tracker. Reading `Markup.range` once at parse time is not one;
  anything that tracks moving offsets across edits is. Preserve the neutral
  block payload boundary and defer that host-specific codec rather than moving
  it into Quagmire;
- any step requires extraction, a remote dependency, tag, push, Arbor code
  change, or cloud-format migration.

## Maintenance notes

Arbor commit `05bcf35` accepts exact Markdown source plus
`baseContentRevision` and returns provider-completed directory Markdown — which
is exactly why Step 2 exists: that response becomes the next source base, so a
routine save can hand the client a new document body, and doing that through a
seam that clears undo would be unusable. Later TreeHopper integration will live
outside Quagmire: a private host codec/source ledger keyed by these stable
BlockIDs will reuse untouched source and submit exact source. Quagmire should
never gain that ledger.

Arbor's own block model is a useful cross-check on the boundary: it has
`mathBlock`, `footnoteDefinition`, `rawMarkdown` (the direct analogue of
`unsupported`), `standaloneLink` (the analogue of `documentLink`), and H1–H6 —
and no tables, embeds, or database blocks as block types. Quagmire's
`templateButton` has no Arbor equivalent and is the other Hunch/Notion-ism left
in `BlockKind`; it is kept for now, but it is not neutral vocabulary.

When reviewing this migration, scrutinize identity survival and durability
ordering more than mechanical renames. A compile-clean `.subpage` →
`.documentLink` replacement is insufficient if paste can duplicate IDs, an
inline operation trashes before flush, target capabilities are still global when
the host needs them per reference, or a provider-completed save still clears the
undo stack.


## Outcome

Executed 2026-08-18 on `codex/quagmire-document-link-foundation`, one commit
per step:

| Step | Commit | What it did |
|---|---|---|
| 0 | `727cd0d` | Tracked and revised this plan after auditing the code rather than the docs |
| 1 | `7b9c0ad` | BlockID lifecycle made executable (23 tests); reminted at the paste and cross-document-inline boundaries |
| 2 | `a43c27d` | Split the system-replacement seam; `SystemDelta` rebases outstanding undo snapshots instead of discarding them |
| 3 | `2d08d83` | H1–H6 representable, H1–H3 authorable |
| 4 | `f6f9acb` | `unsupported` leaf carrying byte-exact source via `Markup.range` |
| 6 | `869ab34` | Per-target capabilities, `pending`/`unavailable`, async suggestions; plus the two durability fixes from Step 7 |
| 5 | `d52c67f` | The vocabulary rename, 64 files |
| 7 | (this) | Cross-document failure injection, final gate |

Verification at the gate: package `verify.sh` (333 + 2 tests, clean macOS and
iOS Simulator builds), XcodeGen (no project change), Hunch macOS tests (348),
Hunch macOS build, Hunch iOS 27 build-for-testing, both sweeps,
`git diff --check`. All green.

Two bugs fixed that were live before this work and untested:

- H4–H6 parsed as H3 and were written back as `###`, so opening a document
  with deep headings and editing anything rewrote them.
- Tables and raw HTML were flattened into paragraphs of re-rendered text and
  destroyed on the next save.

Three deviations from the plan as written, each argued at the point it came up:

- **No `requestPresentation` warm hook.** `lookupDocument` already kicks a
  deduped background warm as a side effect of a cache miss; what was missing
  was a state to return meanwhile. `.pending` plus a documented contract beats
  a second mechanism every host would implement alongside the first.
- **No `delete` capability.** Deleting the row is always allowed and whether
  that should delete the target is host policy, so the editor never gates on
  it. Only what the editor gates on is in the set.
- **`inlineAndRetireDocument`, not `inlineAndTrashDocument`.** "Trash" is the
  Hunch policy this plan set out to get out of the API.

Left for Milestone 7: extraction. Nothing here published, tagged, or pushed.

### Review findings, closed

An external review after the fact caught three things, all real:

1. **`SystemDelta` refused reparenting but not reordering.** A system change
   that only reorders surviving siblings produced an *empty* delta — nothing to
   rebase — so snapshots kept the old order and the next undo quietly reverted
   the reorder. Reproduced at root and nested level, then fixed by comparing the
   surviving-sibling sequence per scope and refusing (`.wholesale`) when it
   differs. Refused rather than modelled, for the same reason as reparenting:
   applying "the system moved B before A" to a snapshot containing neither is a
   guess. Bounded by tests proving insertion and removal *between* survivors
   still reconcile.
2. **Two promised failure/observation tests were missing.** The package test for
   inline-then-retire only made the combined host call return false, which says
   nothing about the flush-before-Trash order inside `trashAfterInlining`. Added
   an app-level test that makes the parent's directory unwritable so the flush
   genuinely throws, and asserts the source is not trashed — verified
   non-vacuous by changing `try` to `try?`, which trashes it. Also added the
   `.pending → .present` test the Step 6 verify called for: same lookup call,
   new answer, row updates, no commit and no tree mutation, and the warm is
   deduped.
3. **Release docs carried stale signatures.** The `createDocument` row still
   read `requestedPath: String? -> String?` and `moveDestination` still said
   `.page`. Fixed, along with a `FullHost` comment still describing the
   blanket-default design.

### Follow-up, now closed

Every `EditorHost` requirement used to have a default implementation, which is
what let a host adopt with two methods. The cost was that a mistyped override
is an overload, not an error, and the default silently wins. Mid-rename the
entire Hunch host stopped conforming — twenty methods, still compiling, all
answering `.missing`/`nil`/`false` — and the app built clean.

Fixed by moving the defaults off `EditorHost` onto six opt-in marker protocols
(`DocumentLinksUnsupported`, `MoveDestinationUnsupported`,
`NavigationUnsupported`, `ImagesUnsupported`, `LinkPreviewsUnsupported`,
`BlockActionsUnsupported`), composed as `EditorHostDefaults` for a host that
only persists. Hunch now conforms to bare `EditorHost` with no defaults
available, so every one of its 24 methods is compile-checked. Verified by
mistyping one signature: previously a clean build, now

```
error: type 'WorkspaceWindow' does not conform to protocol 'EditorHost'
note: candidate has non-matching type '(String) -> DocumentLookup'
```

The pasteboard codec stays on `EditorHost`: its defaults do real work rather
than decline to, so a mistyped override still leaves copy and paste functional.

Worth doing before extraction rather than after — tightening conformance
requirements is a breaking change once there are hosts you do not control.
