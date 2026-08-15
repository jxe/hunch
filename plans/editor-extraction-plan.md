# Editor extraction plan

> **Executor instructions:** Complete the milestones in order. Keep the package
> at `Packages/Editor`, with the package/product/module name `Editor`, through
> Milestone 5. The selected public name is `Quagmire`; apply it locally in
> Milestone 6. Do not create a remote repository or remove the local package
> before Milestone 7.
>
> **Drift check:** This plan was written at commit `0c922ab` on 2026-08-13.
> Before starting a milestone, run:
>
> ```sh
> git diff --stat 0c922ab..HEAD -- Packages/Editor Packages/Quagmire App project.yml README.md CONTRIBUTING.md CLAUDE.md
> ```
>
> Compare any changed in-scope APIs with the “Current boundary” section before
> proceeding. Adapt straightforward file moves or renames, but stop for a design
> decision if a stated invariant no longer matches the live code.

## Outcome

Publish the block editor as a distinctive, independently versioned Swift
package that Hunch consumes through Swift Package Manager.

The work deliberately happens in three phases:

1. Make the editor genuinely reusable and independently verifiable while it is
   still inside the Hunch repository, where editor and host changes can land
   atomically.
2. Choose the public name and make the renamed local package independently
   documented and verifiable while Hunch can still adopt the rename atomically.
3. Perform the history-preserving extraction, publish `0.1.0`, and switch Hunch
   to the remote dependency.

This is a pre-1.0 API cleanup. Compatibility with an unpublished external
`Editor` API is not a goal; preserving Hunch behavior and its on-disk recovery
format is.

## Status and milestone order

| Milestone | Result | Effort | Risk | Depends on | Status |
|---|---|---:|---:|---|---|
| 0 | Baseline and behavior inventory | S | LOW | — | DONE |
| 1 | Storage-neutral document identity | L | HIGH | 0 | DONE |
| 2 | Semantic edit boundary; Clamshell-owned recovery identity | L | HIGH | 1 | DONE |
| 3 | Neutral defaults for optional host hooks | S | LOW | 2 | DONE |
| 4 | Host-supplied block actions | M | MED | 3 | DONE |
| 5 | Neutral configuration, styling, and public surface | L | MED | 4 | DONE |
| 6 | Choose name; standalone docs, dependency policy, and verification | L | MED | 5 | DONE |
| 7 | Extract, publish, and adopt remotely | L | HIGH | 6 | TODO |

Status values: `TODO`, `IN PROGRESS`, `DONE`, `BLOCKED — <reason>`.

Post-Milestone-4 stabilization on 2026-08-15 gated visible optional-host
affordances, refreshed the reusable-package documentation, and cleared the two
recorded iOS reorder failures by freezing destination geometry for each drag.
Milestone 5 then moved all remaining Hunch presentation and process policy
behind explicit host configuration, narrowed the public surface, and passed
the complete macOS and iOS 27 verification matrix. Milestone 6 selected and
applied the `Quagmire` identity, made the local package independently
verifiable, and passed the complete local package and Hunch gates. Milestone 7
has not started.

## Decisions already made

- The extraction is worth doing. The package, now at `Packages/Quagmire`,
  already has its own
  `Package.swift`, sources, resources, tests, and README; the remaining work is
  chiefly API honesty and release engineering.
- Naming happens at the start of Milestone 6, while the package is still local
  to Hunch. This lets the complete Hunch matrix verify the final module identity
  before repository extraction. Repository creation and publication remain
  deferred to Milestone 7.
- The selected public identity is `Quagmire`: repository slug `quagmire` and
  matching Swift package, product, and module. The recorded Python-package,
  repository-name, ordinary-meaning, and popular-culture collisions are known
  and explicitly accepted; no Swift module collision was found.
- A minimal host must not implement unrelated page, image, preview, move, or
  mention features. Only edit persistence and durability waiting remain
  mandatory; all other host hooks have neutral defaults. Do not introduce a
  comprehensive capability matrix before a real consumer demonstrates that
  one is needed.
- “Host-supplied block actions” means the reusable editor owns action
  presentation, selection snapshots, progress/error UI, stale-result checks,
  one undoable transaction, and persistence. The host supplies action metadata
  and an async transformation. The first consumer is Hunch’s transcript
  polishing action.
- The package should remain one library target for `0.1.0`. Do not split an
  `EditorCore` and `EditorUI` package without a real second consumer that needs
  the split.
- Hunch’s exact recovery hashes and journal compatibility are durable storage
  concerns. They must not accidentally change while the editor API is cleaned
  up.
- Do not build a general plugin system, capability matrix, or comprehensive
  design-system API. Add only the host actions and theme/configuration values
  required to remove current Hunch policy from the reusable package. Add a
  narrow support signal later only when a concrete visible affordance cannot
  degrade honestly without one.

## Current boundary

These are the load-bearing facts at the plan’s starting commit:

- `Packages/Editor/Sources/Editor/Model/Document.swift` makes a file `URL` the
  public document ID and filename-derived title fallback. It also carries a
  storage-oriented `modificationDate`.
- `Packages/Editor/Sources/Editor/BlockFingerprint.swift` defines
  `Block.atomicHash`, described as the identity stored in Hunch’s recovery log.
  `BlockTreeDiff.swift` emits those hashes through public `EditorOp` values.
  Clamshell and its tests depend on this exact projection.
- `Packages/Editor/Sources/Editor/EditorHost.swift` requires navigation, page
  creation/deletion, move-to, persistence, paste codecs, images, previews, and
  resolution in one protocol. Most unsupported features are represented by
  stubs rather than discoverable capabilities.
- `Packages/Editor/Sources/Editor/TranscriptPolisher.swift` imports
  `FoundationModels`; package UI and public command enums contain the
  Hunch-specific “Polish Transcription” product action.
- `EditorView.swift`, `Diag.swift`, `Feedback.swift`,
  `EmojiCompletion.swift`, `InlineAttributes.swift`, and `NotionStyle.swift`
  contain Hunch, Console, global-preference, Inter, or Notion policy that an
  unrelated host should not inherit.
- `Packages/Editor/Package.swift` forces static linkage and pins EmojiKit
  exactly to `3.0.0`.
- `Packages/Editor/README.md` says all host methods are required, but its
  quickstart omits required methods. It also links upward into Hunch’s `App/`
  tree and documents only headless package tests.
- Hunch consumes the package by local path in `project.yml`. Its app-hosted
  unit tests deliberately do not declare a second direct Editor dependency,
  but four test files use `@testable import Editor`.

## Invariants for every milestone

1. **No data-format migration.** Existing Markdown, recovery JSONL, page IDs,
   block hash values, and reconciliation behavior remain compatible.
2. **One save emission path.** Every user edit continues to flow through
   `Document.transaction`, the editor’s commit callback, the current
   `PageSession` queue, recovery-log application, and Markdown write in that
   order.
3. **No lost late edit.** Blur, navigation, scene changes, and close continue
   to await already-enqueued persistence.
4. **One editor per document session.** Do not disturb the stable
   `(Document, EditorState)` lifetime, shared undo manager, or native text-view
   focus choreography.
5. **Hunch behavior stays visible.** Page links, mentions, page icons,
   inline-and-trash, cross-page moves, custom Markdown paste, image paste,
   link previews, transcript polishing, sounds, gestures, and keyboard commands
   remain available in Hunch unless a milestone explicitly replaces their
   implementation.
6. **Both Apple platforms remain first-class.** Every public API must compile
   under iOS 26 and macOS 26 with Swift 6 strict concurrency.

## Verification commands

Use a fresh derived-data directory per Xcode command to avoid `build.db`
contention. The executor may choose a unique path under `/tmp`.

| Purpose | Command | Expected result |
|---|---|---|
| Package tests | `swift test --package-path Packages/Quagmire` | Exit 0; all suites pass |
| Regenerate project | `xcodegen generate --spec project.yml --project .` | Exit 0; generated project reflects `project.yml` |
| Hunch macOS tests | `xcodebuild test -project Hunch.xcodeproj -scheme Hunch -destination 'platform=macOS' -derivedDataPath /tmp/hunch-editor-plan-macos CODE_SIGNING_ALLOWED=NO` | Exit 0; Hunch unit tests pass |
| Hunch macOS build | `xcodebuild build -project Hunch.xcodeproj -scheme Hunch -destination 'platform=macOS' -derivedDataPath /tmp/hunch-editor-plan-macos-build CODE_SIGNING_ALLOWED=NO` | Exit 0 |
| Hunch iOS build | `xcodebuild build -project Hunch.xcodeproj -scheme Hunch -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/hunch-editor-plan-ios CODE_SIGNING_ALLOWED=NO` | Exit 0 |
| Focused iOS UI tests | Use the existing `HunchUITests` scheme with `-only-testing:` for `HunchDragAndDropUITests`, `HunchEditScrollUITests`, and `HunchSplitKeyboardUITests` on the installed iOS 27 simulator only | No new failures beyond those recorded in `plans/editor-extraction-baseline.md` |

If `xcodegen generate` changes `Hunch.xcodeproj/project.pbxproj`, include the
generated change when it is a consequence of an intentional `project.yml`
edit. Do not hand-edit the project file. The current `.gitignore` and docs
disagree about whether `Hunch.xcodeproj` is generated-only, while the file is
tracked; resolve that policy explicitly in Milestone 6 rather than silently
dropping or hand-maintaining it.

---

## Milestone 0 — Record the behavioral and compatibility baseline

### Goal

Make the risky boundary changes measurable. This milestone changes tests and
documentation only; it does not change runtime behavior.

### Work

1. Run the full verification matrix above and record the exact toolchain,
   simulator destination, suite counts, and any pre-existing failures in this
   document or a short file under `plans/`.
2. Add golden tests in `App/Tests/HunchUnitTests/BlockFingerprintTests.swift`
   or a new adjacent file for every `BlockKind`, whitespace normalization,
   inline-mark insensitivity, parent/child relationships, and representative
   Unicode. Assert full `atomicHash` values, not only equality relationships.
3. Add recovery-log fixtures that prove records written before the refactor
   still fold, reconcile, and round-trip afterward. Keep the fixtures small and
   checked in; do not generate expected hashes at test runtime.
4. Add characterization tests for the current `EditorHost` feature behavior:
   unavailable optional operations are no-ops, supported Hunch operations are
   presented, and an edit still synchronously enqueues persistence before
   `persistCommit` returns.
5. Inventory editor-generic UI tests currently living only in
   `App/UITests/`. Keep them as Hunch integration coverage unless a standalone
   test host later demonstrates a concrete gap.

### Files

- `App/Tests/HunchUnitTests/BlockFingerprintTests.swift`
- `App/Tests/HunchUnitTests/BlockFingerprintRoundtripTests.swift`
- `App/Tests/HunchUnitTests/RecoveryLogTests.swift`
- `Packages/Editor/Tests/EditorTests/`
- `App/UITests/HunchDragAndDropUITests.swift`
- `App/UITests/HunchEditScrollUITests.swift`
- `App/UITests/HunchSplitKeyboardUITests.swift`
- `plans/editor-extraction-plan.md`

### Gate

- The full pre-change matrix is recorded.
- Golden hash fixtures fail if any canonical string or digest changes.
- Recovery compatibility fixtures use literal pre-refactor data.
- No production source file changed.

---

## Milestone 1 — Give `Document` storage-neutral identity

### Goal

A consumer backed by a database, an in-memory model, or a remote service can
construct a document without inventing a file URL. Hunch keeps URLs in its
Clamshell/PageSession layer.

### Target API shape

Introduce a small, concrete, host-supplied identifier rather than a generic
`Document<ID>` that would infect the entire public surface:

```swift
public struct DocumentID: Hashable, Sendable {
    public init(_ rawValue: String)
}

@Observable @MainActor
public final class Document: Identifiable {
    public let id: DocumentID
    public var fallbackTitle: String?
    public internal(set) var children: [Block]

    public init(
        id: DocumentID,
        children: [Block],
        fallbackTitle: String? = nil
    )
}
```

The exact stored representation of `DocumentID` may remain private. It must be
stable, hashable, sendable, and supplied by the host. `Document.title` should
continue to prefer the first top-level H1, then use `fallbackTitle`, then a
neutral `"Untitled"` fallback. Remove `modificationDate` unless a package-only
caller with a demonstrated editor concern exists.

### Work

1. Add `DocumentID` and replace `Document.url` identity in the editor package.
   Update package tests to use readable synthetic IDs rather than `/tmp` or
   `/dev/null` URLs.
2. Make `Clamshell.PageSession` (or its existing page/coordinator handle) the
   owner of the page URL and modification metadata. Hunch code must resolve a
   `Document` back to its session through the existing object-identity session
   map, not through an editor-owned URL.
3. At materialization time, have Clamshell supply a stable document ID. Prefer
   the page’s durable Clamshell page ID when available; otherwise use a
   host-owned stable value whose lifecycle is explicit. Do not expose a file
   URL merely encoded as the new ID.
4. Replace all Hunch reads of `document.url` with PageSession/Clamshell access.
   This includes navigation comparison, registration of open URLs, relative
   link classification, title fallback, persistence lookup, and tests.
5. Update the README quickstart to construct an in-memory document without a
   URL, but do not otherwise rewrite the public docs yet.

### Files

- `Packages/Editor/Sources/Editor/Model/Document.swift`
- Package tests constructing `Document`
- `App/Sources/Clamshell/PageCoordinator.swift`
- `App/Sources/Clamshell/Clamshell.swift` and extensions that materialize or
  identify documents
- `App/Sources/WorkspaceWindow.swift`
- `App/Sources/WorkspaceWindow+EditorHost.swift`
- Hunch tests constructing or locating documents
- `Packages/Editor/README.md`

### Gate

```sh
rg -n 'public let url|var id: URL|Document\(url:' Packages/Editor
```

returns no matches. The package test and both Hunch build gates pass. Hunch’s
navigation, relative links, save routing, and title fallback have direct test
coverage after the move.

### STOP conditions

- Stop if no stable Clamshell page identity can be obtained without changing
  the on-disk format; propose a session-scoped ID instead of inventing a file
  migration.
- Stop if any persistence path must recover a URL by parsing `DocumentID`.
  That would recreate the old coupling under a new type name.

---

## Milestone 2 — Emit semantic edits and move recovery identity into Clamshell

### Goal

The editor describes what blocks changed; Hunch decides how those changes map
to its durable recovery log. Existing on-disk hashes remain byte-for-byte
compatible.

### Target boundary

Replace recovery-shaped public `EditorOp` values with semantic change values
that carry block snapshots and placement information, not hashes. A suitable
shape is:

```swift
public enum DocumentChange: Sendable, Equatable {
    case removed(block: Block)
    case inserted(block: Block, parent: Block?)
}
```

The exact names may change, but the host must have enough information to
reproduce today’s rules, including the special case where a child’s content is
unchanged but its same-ID parent’s content hash changed. Pure reorder/move
operations remain semantically visible as a committed document transaction
even if Clamshell emits no recovery-log record.

### Work

1. Refactor the editor’s pre/post tree diff to emit block snapshots and parent
   snapshots. Keep diff derivation in the editor because it owns transaction
   semantics, but remove recovery-log terminology from its public names and
   docs.
2. Move the canonical-string algorithm, SHA-256 projection,
   `Document.atomicHashSet`, and editor-change-to-`Patch` conversion into
   `App/Sources/Clamshell/`. Name them as Clamshell recovery/storage concepts,
   not editor identity.
3. Change `EditorHost.persistCommit` to accept the semantic change batch. In
   `WorkspaceWindow+EditorHost`, synchronously project the batch to the exact
   existing recovery operations and synchronously enqueue the current
   `PageSession` before returning.
4. Replace Hunch’s direct uses of `Block.atomicHash`, `BlockTreeDiff`, and
   `EditorOp` with the Clamshell-owned projector. Reconcile and other
   non-editor mutations may call the same Hunch-side semantic diff helper; do
   not keep a public editor hashing API solely for Hunch tests.
5. Move the hash and patch-projection tests into the Hunch test target. Preserve
   all Milestone 0 golden values and pre-refactor recovery fixtures.
6. Rename comments throughout Clamshell so the editor callback is a source of
   semantic changes, while the recovery log’s add/purge projection is explicitly
   Clamshell policy.

### Files

- `Packages/Editor/Sources/Editor/BlockFingerprint.swift` (remove or reduce to
  genuinely editor-owned helpers)
- `Packages/Editor/Sources/Editor/BlockTreeDiff.swift`
- `Packages/Editor/Sources/Editor/Model/Document.swift`
- `Packages/Editor/Sources/Editor/EditorHost.swift`
- `App/Sources/Clamshell/Commit.swift`
- `App/Sources/Clamshell/PatchEngine.swift`
- `App/Sources/Clamshell/RecoveryLog.swift`
- `App/Sources/Clamshell/Clamshell+Reconcile.swift`
- `App/Sources/Clamshell/PageCoordinator.swift`
- `App/Sources/WorkspaceWindow+EditorHost.swift`
- Corresponding Editor and Hunch tests

### Gate

- All golden full hashes from Milestone 0 are unchanged.
- All literal old recovery fixtures still load and reconcile.
- `rg -n 'atomicHash|EditorOp|BlockTreeDiff' Packages/Editor/Sources/Editor`
  returns no storage-shaped public API. A package-internal semantic diff helper
  may remain under a neutral name.
- The persistence-order tests prove enqueue visibility is still synchronous.
- Full package tests, Hunch macOS tests, and both platform builds pass.

### STOP conditions

- Stop if satisfying a test appears to require changing a golden hash, journal
  record, or old fixture. Treat it as a compatibility regression, not a fixture
  update.
- Stop if the proposed semantic change lacks enough old/new parent information
  to reproduce current recovery behavior. Enrich the semantic event; do not
  leak hashes back into the editor.

---

## Milestone 3 — Give optional host hooks neutral defaults

### Goal

A basic consumer implements persistence and flush only. Existing Hunch
integrations continue to work, while unrelated page, mention, move, image,
preview, navigation, and paste hooks become optional through honest neutral
defaults.

### Target API shape

`EditorHost` keeps only these methods mandatory:

```swift
func persistCommit(changes: [DocumentChange], in document: Document)
func flush(_ document: Document) async
```

All other existing methods receive safe defaults in a public protocol
extension: empty collections for suggestions, `.missing` or `nil` for lookup
and resolution, `false` for host mutations, no-op navigation/callbacks, empty
image results, and nil previews. Copy and paste receive useful package-owned
plain-text defaults rather than blank-string stubs.

Do not add `EditorCapabilities`, an `OptionSet`, capability subprotocols, or a
parallel feature registry in this milestone. Swift's protocol type checking is
the conformance proof: only persistence and flush remain requirements without
default implementations. A separate `MinimalHost` test type is unnecessary.

### Work

1. Add public neutral defaults for every host method except `persistCommit` and
   `flush`. Preserve the class-bound stable host identity and all existing
   method signatures so Hunch's conformer does not need a parallel migration.
2. Give copy and paste package-owned plain-text behavior when a host does not
   override the codecs. Keep custom Markdown or other rich serialization as an
   ordinary override, not a declared capability.
3. Audit each optional method's call site. Where existing editor state or the
   returned data naturally suppresses work—empty suggestions, missing page
   lookups, nil previews, failed image persistence—keep that simple behavior.
   Do not build new gating infrastructure pre-emptively.
4. Identify any affordance that would remain visibly misleading with the
   neutral default, such as an action that can only appear and then silently
   cancel. First try to hide it using existing state or returned data. Add one
   narrowly named support property only if the code demonstrates that no honest
   natural condition exists; do not generalize it into a capability system.
5. Keep page APIs and the existing load → inline → durability wait → trash
   sequence unchanged in this milestone. Reconsider that contract only if a
   concrete correctness bug or second host requires it.
6. Update the README host table and quickstart to distinguish the two required
   methods from optional hooks and to document every neutral default. Rely on
   compiler type checking, package tests, and Hunch builds rather than adding a
   synthetic minimal-host fixture.

### Files

- `Packages/Editor/Sources/Editor/EditorHost.swift`
- `Packages/Editor/Sources/Editor/EditorView.swift` and focused extension files
  only where the call-site audit proves a visible dead affordance
- `Packages/Editor/README.md`
- Focused existing Editor or Hunch tests only when behavior changes

### Gate

- Searching `EditorHost` shows only persistence and flush without default
  implementations.
- No `EditorCapabilities`, feature `OptionSet`, or synthetic `MinimalHost`
  fixture exists.
- The package type-checks, Editor package tests pass, and Hunch's existing full
  conformer and both platform builds still compile unchanged in behavior.
- The focused iOS 27 checks introduce no failure beyond the recorded baseline.

### STOP conditions

- Stop before adding a general feature registry, capability matrix, or family
  of support flags. Bring the concrete dead affordance back for a design
  decision instead.
- Stop if a neutral default could lose user content, claim a host mutation
  succeeded, or weaken persistence. Optional write operations must fail closed;
  persistence and flush never receive defaults.

---

## Milestone 4 — Introduce host-supplied block actions

### Goal

Reusable editing mechanics can host product actions without embedding their
model/provider or product wording. Hunch’s transcript polishing remains
behaviorally identical but Foundation Models leaves the package.

### Contract

Add a narrow action contract, not a plugin framework:

- The host returns action metadata: stable ID, title, system image, and an
  applicability predicate over immutable selected-block snapshots.
- On invocation, the editor snapshots selected text-bearing blocks in visible
  order and calls the host action asynchronously.
- The action returns proposed replacements keyed by `BlockID`; it does not
  mutate `Document` directly.
- The editor rechecks that each source block still exists and its relevant
  content matches the snapshot. Stale results are skipped.
- Applicable replacements land in one named `Document.transaction`, producing
  one undo step and one persistence emission.
- The editor owns progress presentation, cancellation/lifetime, success toast,
  and error presentation. Action results must not overwrite newer typing.

Names such as `EditorBlockAction`, `BlockActionContext`, and
`BlockReplacement` are acceptable placeholders until Milestone 6; do not put
the eventual package brand into type names now.

### Work

1. Add the action value types and a default-empty host hook. Availability is
   covered by the host action list; do not add a separate feature flag per action.
2. Render host actions in the existing block action surfaces after native
   editor actions. Preserve keyboard accessibility and stable ordering.
3. Add a neutral focused-command entry point that invokes an action by stable
   ID. Hunch’s macOS menu can use it without adding product-specific cases to
   `EditorAction` or `EditorPredicate`.
4. Move `TranscriptPolisher.swift`, its Foundation Models dependency, prompt,
   availability logic, and Hunch-specific labels into `App/Sources/`.
   `WorkspaceWindow` (or a small Hunch action provider) exposes the “Polish”
   action only when the model is available and the selected blocks are
   eligible.
5. Delete `polishTranscription` and `canPolishTranscription` from package command
   enums and remove all transcript-specific package state and UI strings.
6. Port tests for ordered selection, structural-row exclusion, stale-write
   protection, one undo transaction, unavailable model, errors, and success.
   Package tests exercise a fake action; Hunch tests exercise the polisher.

### Files

- New neutral action types under `Packages/Editor/Sources/Editor/Model/`
- `Packages/Editor/Sources/Editor/EditorHost.swift`
- `Packages/Editor/Sources/Editor/EditorCommands.swift`
- `Packages/Editor/Sources/Editor/EditorView.swift`
- `Packages/Editor/Sources/Editor/EditorView+TurnInto.swift`
- `Packages/Editor/Sources/Editor/EditorView+Wiring.swift`
- `Packages/Editor/Sources/Editor/TranscriptPolisher.swift` (remove)
- New Hunch-side polisher/action provider under `App/Sources/`
- `App/Sources/HunchApp.swift`
- Editor and Hunch tests

### Gate

```sh
rg -n 'FoundationModels|TranscriptPolisher|polishTranscription|Polish Transcription' Packages/Editor
```

returns no matches. A fake async package action proves stale-result rejection
and one-transaction application. Hunch still shows and runs Polish on both its
swipe/action surface and macOS menu when available.

---

## Milestone 5 — Remove Hunch policy and stabilize the public surface

### Goal

The remaining package API and runtime behavior are neutral enough to document
and version. Hunch can preserve its current visual treatment through explicit
configuration.

### Work

1. **Escape handling:** remove the public `hunchEscapeKeyDown` notification
   from the package. Keep the fullscreen AppKit monitor and any process-global
   notification in Hunch. Bridge it from the Hunch wrapper to the neutral
   `.escape` editor command/controller.
2. **Logging:** remove the hard-coded `org.nxhx.Hunch` subsystem. Use the host
   bundle identifier by default or an explicit editor configuration value;
   retain useful categories without publishing Hunch names.
3. **Feedback:** replace the process-global `uiSoundsEnabled` UserDefaults read
   with explicit configuration. The package may provide bundled sound effects,
   but the host decides whether audio/haptics are enabled. Defaults should be
   unsurprising for a reusable library and documented.
4. **Internal names:** rename `HunchEmojiPicker` neutrally. Replace legacy
   `Console.*` attributed-string key names with stable, neutral identifiers and
   add round-trip tests. If those raw names can cross persistence or pasteboard
   boundaries, provide a compatibility reader rather than silently breaking
   old values.
5. **Theme:** replace `NotionStyle` as public package policy with a modest
   `EditorTheme`/configuration boundary. It must cover only the tokens the
   editor actually consumes: palette, body/heading/monospace typography, and
   load-bearing layout metrics. Keep the current look as Hunch’s explicitly
   supplied theme. Move shell-only styling into a Hunch-owned style type.
6. **Fonts:** remove the requirement that every consumer register Hunch’s Inter
   resource. The default theme must render correctly with system fonts; Hunch
   may register Inter and select `"Inter Variable"` through its theme. Test the
   Hunch font contract through public behavior, not `@testable import Editor`.
7. **Public API audit:** review all `public` declarations. Make gesture/layout,
   overlay, hover, lifecycle, and other implementation types internal unless a
   concrete host call site needs them. Preserve read-only state hosts actually
   observe. Do not expose internals solely to retain tests.
8. Change Hunch test files from `@testable import Editor` to normal
   `import Editor`, or remove the import if symbols arrive through the app
   target. Rewrite tests that currently depend on package internals.

### Files

- `Packages/Editor/Sources/Editor/EditorView.swift`
- `Packages/Editor/Sources/Editor/Diag.swift`
- `Packages/Editor/Sources/Editor/Feedback.swift`
- `Packages/Editor/Sources/Editor/EmojiCompletion.swift`
- `Packages/Editor/Sources/Editor/Model/InlineAttributes.swift`
- `Packages/Editor/Sources/Editor/NotionStyle.swift`
- Other package files affected by `EditorTheme` and access-level cleanup
- `App/Sources/HunchApp.swift`
- `App/Sources/ContentView.swift`
- `App/Sources/Shell/`
- `App/Tests/HunchUnitTests/FontRegistrationTests.swift`
- `App/Tests/HunchUnitTests/RecoveryLogTests.swift`
- `App/Tests/HunchUnitTests/LinkHealingTests.swift`
- `App/Tests/HunchUnitTests/ClamshellRenameTests.swift`

### Gate

```sh
rg -n 'Hunch|hunch\.|org\.nxhx\.Hunch|uiSoundsEnabled|Console\.|NotionStyle' Packages/Editor
rg -n '^@testable import Editor' App/Tests/HunchUnitTests
```

Both commands return no matches, except a clearly documented historical
compatibility string in a test or decoder. Package tests pass with no host font
registration. Hunch’s current typography, colors, sounds, Escape behavior, and
icons are covered by focused tests/builds and manual smoke checks.

### STOP conditions

- Stop before renaming an attributed-string key if evidence shows it is stored
  durably and no compatibility reader has been designed.
- Stop if theme extraction turns into a general design system. Keep the
  boundary to values already varied by Hunch or required to eliminate its
  assumptions.

---

## Milestone 6 — Name and make the local package independently releasable

### Goal

Choose and verify the permanent public identity before any repository move.
The renamed local package has accurate standalone docs, a public-API consumer
contract test, a repeatable verification script, and consumer-friendly
dependency declarations.

### Name decision

The selected name is **Quagmire**. Consumers write `import Quagmire`; the
standalone repository slug is `quagmire`. The research and accepted tradeoffs
are recorded in `plans/editor-name-landscape.md`.

Apply these conventions:

- Repository slug: distinctive lowercase brand, optionally hyphenated.
- Swift package, library product, and module: the same distinctive
  `UpperCamelCase` brand so consumers write `import Brand`.
- Public types: role-based (`EditorView`, `Document`, `Block`,
  `EditorTheme`), not mechanically brand-prefixed.
- `Kit` is optional only if the package genuinely presents as a broad toolkit.
  A `Swift` prefix is unnecessary unless needed to disambiguate search/results.
- Avoid generic module names such as `Editor`, `BlockEditor`, or
  `HunchEditor`; the name should be searchable and collision-resistant.

Before deciding, search GitHub, Swift Package Index, package registries, App
Store/product results, and relevant trademark databases. Check exact name,
module spelling, repo slug, and close phonetic variants. Record the search date,
results, and rationale in the package documentation. Collision screening is not
legal clearance; stop and ask for a different candidate if material ambiguity
remains.

### Work

1. Record the selected `Quagmire` identity and its accepted collision tradeoffs
   from `plans/editor-name-landscape.md` in the package documentation.
2. Rename the package directory, Swift package, library product, module, source
   and test targets, imports, logging defaults, and local dependency references
   consistently. Regenerate the tracked Xcode project. Keep public type names
   role-based rather than mechanically brand-prefixing them.
3. Add a small public-API consumer contract test. It must use a normal
   `import Quagmire`, implement only the two required persistence methods, create
   an in-memory `Document` and `EditorState`, and construct `EditorView`. Keep
   the README quickstart aligned with this compiled contract.
4. Rewrite the package README so it stands alone: installation,
   supported platforms/toolchain, minimal quickstart, model and mutation
   semantics, optional host hooks and defaults, block actions,
   theme/configuration, resource behavior, threading/actor expectations, and
   versioning policy. Remove links that climb into Hunch’s `App/` tree; link to
   Hunch’s public repository as an external example only where useful.
5. Add a package-local `CONTRIBUTING.md`, `LICENSE` copy, and a concise
   architecture/maintenance note. Do not add speculative docs or a changelog
   before releases exist.
6. In `Package.swift`, let SwiftPM choose linkage by declaring
   `.library(name: "Quagmire", targets: ["Quagmire"])`. Change EmojiKit from an
   exact transitive pin to a compatible 3.x requirement after verifying the
   resolved version. Keep `Package.resolved` only if the chosen library-repo
   policy intentionally tracks it.
7. Add a package resource smoke test that locates and loads the bundled sound
   assets through the package bundle.
8. Add a package-local `scripts/verify.sh` (or an equivalently obvious command)
   that runs package tests and clean macOS and iOS Simulator package builds. It
   must locate the package relative to itself so it works both in the current
   subtree and after that subtree becomes a repository root.
9. Retain the already documented Xcode project policy: `project.yml` is the
   source of truth and `Hunch.xcodeproj/project.pbxproj` is tracked generated
   output. Confirm `.gitignore`, CONTRIBUTING, and repository state still agree
   after the dependency rename.

Do not add a demo/example app, copy Hunch UI tests into a second host, or add a
CI workflow. Hunch remains the end-to-end UI integration harness through the
extraction and first release.

### Files

- `Packages/Quagmire/Package.swift`
- `Packages/Quagmire/Package.resolved` (remove and ignore under the chosen
  library-repository policy)
- `Packages/Quagmire/README.md`
- `Packages/Quagmire/CONTRIBUTING.md` (new)
- `Packages/Quagmire/LICENSE` (new)
- `Packages/Quagmire/Tests/QuagmireTests/` (public consumer and resource tests)
- `Packages/Quagmire/scripts/verify.sh` (new)
- `.gitignore`, `CONTRIBUTING.md`, and possibly generated project policy docs

### Gate

- The chosen name is distinctive, collision-screened, and documented.
- Hunch and the public consumer contract compile against the renamed module.
- The README minimal host compiles without optional-feature stubs.
- Running the package-local verification script from a clean checkout exits 0.
- The package builds for macOS and the installed iOS 27 Simulator toolchain.
- A resource smoke test locates and loads the package sound assets.
- `Package.swift` no longer forces static linkage or an exact EmojiKit version.
- No package doc has a relative link outside the package root.
- Full Hunch verification still passes with the local-path dependency.

---

## Milestone 7 — Extract, publish, and switch Hunch

### Goal

Preserve the named package’s history, publish a tested `0.1.0`, and make Hunch
consume it as a remote SwiftPM dependency.

This is the first milestone allowed to create the standalone repository or
remove the local package.

### Extraction and publication sequence

1. Freeze editor-boundary changes in Hunch and run the complete Milestone 6
   verification script plus the full Hunch matrix.
2. In a disposable clone, use a history-preserving subtree extraction such as
   `git filter-repo --path Packages/Quagmire/ --path-rename Packages/Quagmire/:`.
   Never run history rewriting against the working Hunch repository.
3. Confirm the repository root contains `Package.swift`, `Sources`, `Tests`,
   `README.md`, `CONTRIBUTING.md`, `LICENSE`, and the verification script. Remove
   subtree-era paths from docs and scripts.
4. Push the new repository’s default branch and run the local clean-checkout
   verification. Do not tag yet.
5. In a Hunch branch, change `project.yml` from `path: Packages/Quagmire` to the
   new Git URL pinned to the tested commit revision. Rename the dependency key,
   product, and imports consistently; regenerate the Xcode project. Remove the
   local `Packages/Quagmire` subtree only after remote resolution succeeds.
6. Run package tests in the new repo and the full Hunch macOS/iOS/unit/UI matrix
   with a clean SwiftPM cache/resolution. Verify there is one linked copy of the
   library and that package resources load through the remote dependency.
7. Tag the tested editor commit `0.1.0`. In Hunch, replace the revision pin with
   an exact `0.1.0` requirement, resolve again from clean state, and rerun both
   platform builds plus Hunch unit tests.
8. Update Hunch’s README, CONTRIBUTING, CLAUDE/agent notes, links, dependency
   instructions, and local-development override instructions. Cross-repository
   work should use a local SwiftPM override during development, followed by a
   package tag and a separate Hunch dependency bump.
9. Keep exact `0.x` versions while the boundary is settling. Adopt compatible
    version ranges only once the public API has stabilized; treat `1.0.0` as an
    explicit compatibility commitment.

### Gate

- The new module has a distinctive, screened name and a documented rationale.
- The standalone repository retains meaningful pre-extraction file history.
- The package-local verification script passes in a clean clone.
- Hunch resolves the dependency from the tagged remote URL, not a local path or
  revision.
- `Packages/Quagmire` is absent from Hunch only after the remote builds pass.
- Hunch package resolution contains one copy of the renamed library and its
  resources.
- Full Hunch package/unit/build/UI verification passes at exact `0.1.0`.

### STOP conditions

- Stop if a meaningful active Swift/module/product collision or trademark
  concern appears beyond the tradeoffs already recorded and accepted for
  Quagmire.
- Stop if extraction loses relevant file history; redo it from a disposable
  clone rather than accepting a source-only copy.
- Stop if Hunch passes only with a local package override. Do not delete the
  in-repo package or tag a release until clean remote resolution works.
- Stop if the remote package links twice into `HunchUnitTests` or resources fail
  under remote resolution. Fix the target/dependency graph before publishing.

## Final done criteria

- [ ] The standalone package’s public model has no filesystem-required
  identity.
- [ ] Recovery hashing and on-disk compatibility are owned and tested by
  Clamshell/Hunch.
- [ ] A minimal host implements persistence and flush only.
- [ ] Optional host hooks have documented neutral defaults; any support signal
  is narrowly justified by a concrete otherwise-dead affordance.
- [ ] Product actions are host-supplied; Foundation Models is not a package
  dependency.
- [ ] The package contains no Hunch/Console/Notion policy or global Hunch
  preference keys.
- [ ] System-font defaults work; Hunch explicitly supplies its Inter-based
  treatment.
- [ ] Public docs and the public-API consumer contract test agree.
- [ ] The standalone verification script checks SwiftPM tests, both
  Apple-platform builds, and resources.
- [ ] The final package/module has a distinctive screened name.
- [ ] Hunch consumes exact remote version `0.1.0` through SwiftPM.
- [ ] The old local package is removed only after all clean remote gates pass.

## Explicitly deferred beyond `0.1.0`

- Splitting model/core and UI into separate products.
- A general plugin architecture or third-party action discovery.
- Broad theming beyond the existing editor’s real tokens.
- Lowering deployment targets below iOS 26/macOS 26.
- Promising source stability or a compatible SemVer range before the API has
  survived real external use.
