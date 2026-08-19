# Editor extraction milestones 3–4 verification record

Recorded 2026-08-15. Work began from Milestone-2 commit `0a88055` and kept the
package/product/module name `Editor` as required by the extraction plan.

## Result

- Milestone 3 gives every `EditorHost` hook except `persistCommit` and `flush`
  a neutral default. Copy and paste use a package-owned, line-oriented plain
  text codec; unavailable mutations fail closed. No capability registry,
  feature `OptionSet`, or synthetic minimal-host fixture was added.
- Milestone 4 adds ordered immutable selection snapshots, host-supplied async
  block actions, stable-ID focused commands, editor-owned progress/errors, and
  stale-safe one-transaction replacement application.
- Hunch owns transcript polishing, its Foundation Models dependency and prompt,
  availability, and all product labels. Polish remains available from the
  block action surface and macOS menu when the on-device model is available.

## Toolchain

- Apple Swift 6.4 (`swiftlang-6.4.0.20.104`, arm64 macOS 27 target)
- Xcode 27.0 beta, build `27A5194q`
- XcodeGen 2.45.4
- UI destination: iPhone 17 Pro, iOS 27.0 simulator

## Verification matrix

| Check | Result |
|---|---|
| Editor package suite | PASS — 238 tests in 24 suites. |
| Project regeneration | PASS — `xcodegen generate`; the tracked project includes the moved app source and new tests. |
| Hunch macOS unit suite | PASS — 331 tests in 27 suites. |
| Hunch macOS build | PASS. |
| Hunch iOS Simulator build | PASS with the Xcode 27 simulator SDK. |
| Package-policy search | PASS — no `FoundationModels`, `TranscriptPolisher`, `polishTranscription`, `canPolishTranscription`, or `Polish Transcription` remains under `Packages/Editor`. |
| Capability search | PASS — no `EditorCapabilities`, feature `OptionSet`, or synthetic `MinimalHost` fixture was introduced. |
| Focused iOS 27 UI suite | 15 of 17 tests passed. The two reorder failures are baseline behavior: `testLongPressReordersRows` was already recorded, and `testLongPressReorderAfterScrollTargetsTouchedRow` reproduced identically from untouched commit `0a88055` on the same simulator. All edit/scroll and split-keyboard tests passed. |

The UI test process reached complete XCTest results but Xcode 27 then stalled
while saving its test record; it was interrupted after the assertions and suite
summaries had been emitted. The comparison run from `0a88055` exhibited the
same post-test log-finalization stall.

### Follow-up stabilization — 2026-08-15

The two historical reorder failures above are now resolved. Reorder destination
frames are frozen in document-local coordinates while the insertion gap
animates, then projected through the live page origin during autoscroll. The
Editor package suite passes with 239 tests, the Hunch macOS suite passes with
331 tests, and all 13 `HunchDragAndDropUITests` pass on the iPhone 17 Pro,
iOS 27.0 simulator.

## Action contract coverage

- Package tests prove selected text-bearing blocks are snapshotted in document
  order while structural and blank rows are excluded.
- A fake async action proves multiple replacements produce one persistence
  emission and one undo step.
- Stale and missing blocks are skipped without a commit.
- Hunch tests prove unavailable-model hiding, ordered successful replacements,
  and error propagation to the editor-owned presentation layer.
