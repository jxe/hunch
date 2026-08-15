# Editor extraction milestones 0–2 verification record

Recorded 2026-08-14. The extraction plan was written at `0c922ab`; work began
from `d6aed6f`. This record accompanies milestones 0–2 without changing the
milestone-3 proposal.

## Toolchain

- Apple Swift 6.4 (`swiftlang-6.4.0.20.104`, arm64 macOS 27 target)
- Xcode 27.0 beta, build `27A5194q`
- XcodeGen 2.45.4
- UI verification destination: iPhone 17 Pro, iOS 27.0 simulator

Only iOS 27 should be used for subsequent Hunch verification. Temporary
derived-data and baseline archive directories created during this work were
removed after the runs.

## Compatibility fixtures

- `BlockFingerprintTests` pins the full, literal SHA-256 recovery hash for
  every `BlockKind`, normalized whitespace, representative Unicode, and tree
  relationships. Inline formatting remains recovery-hash-insensitive.
- `RecoveryLogTests` contains literal pre-refactor JSONL and hash data and
  proves that the old record still folds, reconciles into a document, and
  round-trips through the current log format.
- `RecoveryChangeProjectionTests` proves that formatting-only semantic changes
  do not churn recovery records and that a changed parent recovery identity
  refreshes a stable child's parent reference.
- `DocumentChangeDiffTests` characterizes insertion, removal, content
  replacement, subtree removal, parent-before-child insertion, reorder/move
  no-ops, and stable-child placement refreshes without storage hashes.
- `DocumentTransactionTests` proves that in-memory/remote-style `DocumentID`
  values and fallback titles require no file URL.

## Verification matrix

| Check | Result |
|---|---|
| Entry package baseline at `d6aed6f` | 236 tests discovered. One timing-sensitive failure in `macTextChangesCommitAfterCheckpointDelay`; it passed when rerun alone. |
| Final Editor package suite | PASS — 235 tests in 23 suites. The old recovery-hash diff tests were replaced by storage-neutral semantic-change tests. |
| Project regeneration | PASS — `xcodegen generate`; the tracked project includes the new Clamshell source and test. |
| Hunch macOS unit suite | PASS — 328 tests in 26 suites. |
| Hunch macOS build | PASS. |
| Hunch iOS Simulator build | PASS with the Xcode 27 simulator SDK. |
| iOS 27 split-keyboard check | PASS — `testKeyboardStaysUpAcrossSplit`. |
| iOS 27 edit/scroll check | PASS — `testTypeThenDismissThenScroll`. |
| iOS 27 reorder checks | BASELINE FAILURES — `testLongPressReordersRows` consistently moves Bravo before Delta rather than after Delta. `testLongPressReorderAfterScrollTargetsTouchedRow` moves Row 12 before Row 14 rather than after it; this second failure was discovered during Milestones 3–4 verification and reproduced identically from untouched Milestone-2 commit `0a88055` on the same iOS 27 simulator. No editor gesture/layout source changed in Milestones 0–4. |

The reorder failures are recorded rather than repaired here because milestones
0–4 concern storage identity, semantic persistence, host defaults, and host
actions, and changing gesture behavior would broaden their scope.

## UI test inventory for a standalone example

Copy these editor-generic integration checks into the milestone-6 standalone
example. Keep the Hunch copies until the example suite is established so Hunch
continues to verify its real host adapter.

- `HunchSplitKeyboardUITests`: copy `testKeyboardStaysUpAcrossSplit`.
- `HunchEditScrollUITests`: copy `testTypeThenDismissThenScroll`,
  `testSplitThenDismissThenScroll`, and `testNavModeScrollFromRow`.
- `HunchDragAndDropUITests`: copy the full suite. It covers reorder targeting,
  variable-height and scrolled layouts, scroll-versus-reorder gesture
  arbitration, row/gutter hit testing, swipe actions, tap/hold cleanup, and
  transformed-row mobile actions.

Keep these Hunch-only because they exercise application chrome, search, or
navigation outside the reusable editor:

- `HunchEditScrollUITests.testHomeToolbarSurvivesReturningFromChildPage`
- `HunchEditScrollUITests.testSearchFindsBodyTextWithoutShowingPathAndOpensPage`

## Boundary result after milestone 2

- `Document` carries only a host-supplied `DocumentID`, children, and optional
  fallback title. Clamshell owns URLs and modification dates.
- `Editor` emits `[DocumentChange]` semantic snapshots. It contains no recovery
  hashing, canonicalization, journal operations, or Clamshell diff policy.
- Clamshell owns the unchanged canonical recovery hash and projects semantic
  changes into its existing add/purge records before the Markdown write.
- Empty semantic change batches still persist reorder/move tree shape, and the
  existing synchronous enqueue plus asynchronous `flush` durability contract
  remains intact.
