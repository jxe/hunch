# Editor extraction Milestone 6 verification record

Recorded 2026-08-15 at Hunch commit `1d3e7f5` plus the uncommitted Milestone 6
change set. Milestone 7 was not started.

## Result

- The local package, product, module, source target, test targets, imports, and
  Hunch dependency are now named `Quagmire`. Public editor types remain
  role-based.
- The naming landscape and accepted collision tradeoffs are recorded in
  `editor-name-landscape.md`.
- A separate `QuagmirePublicAPITests` target uses a normal
  `import Quagmire`, implements only `persistCommit` and `flush`, and constructs
  an in-memory `Document`, `EditorState`, and `EditorView`.
- The package README now documents local installation, the compiled minimal
  host, the public model and host contract, actor expectations, resources, and
  pre-1.0 versioning without advertising an unpublished repository or release.
- Package-local `CONTRIBUTING.md`, `ARCHITECTURE.md`, `LICENSE`, `.gitignore`,
  and `scripts/verify.sh` make the subtree ready for history-preserving
  extraction.
- SwiftPM now chooses library linkage and accepts compatible EmojiKit 3.x
  versions. The verified graph selected EmojiKit 3.0.0.
- `Package.resolved` is intentionally ignored for the library repository; the
  manifest range is the consumer contract and verification records the actual
  selected dependency.
- A resource smoke test loads all three CAF assets through the same
  `Bundle.module` lookup used by runtime feedback.
- No example app or CI workflow was added. Hunch remains the end-to-end
  integration harness.

## Toolchain

- Apple Swift 6.4 (`swiftlang-6.4.0.20.104`)
- Xcode 27.0 beta, build `27A5194q`
- XcodeGen 2.45.4
- iOS destination: iPhone 17 Pro, iOS 27.0 simulator,
  `C76DE979-27D7-4BE5-AD11-3FC223402AB9`

## Verification matrix

| Check | Result |
|---|---|
| Package-local `scripts/verify.sh` | PASS — clean package tests plus clean macOS and iOS Simulator package builds. |
| Quagmire behavior/resource suite | PASS — 242 tests in 26 suites. |
| Normal-import public consumer suite | PASS — 1 test in 1 suite. |
| Resource contract | PASS — `pinch-open.caf`, `drop.caf`, and `delete.caf` load from the package bundle and contain data. |
| Dependency resolution | PASS — compatible EmojiKit 3.x requirement resolved to 3.0.0. |
| Project regeneration | PASS — `xcodegen generate`; tracked output resolves the local Quagmire product. |
| Hunch macOS unit suite | PASS — 332 tests in 27 suites. |
| Hunch macOS build | PASS. |
| Hunch iOS Simulator build | PASS on the installed iOS 27 simulator. |
| Focused iOS 27 UI suite | PASS — all 17 drag/reorder, edit/scroll, and split-keyboard tests. |
| Package documentation boundary | PASS — no package document links outside the package root. |
| Package policy searches | PASS — no forced static linkage, exact EmojiKit requirement, old module import, or old operational package path remains. |
| Diff hygiene | PASS — `git diff --check`. |

The compiler continues to report the existing SwiftUI `Text + Text`
deprecation warnings in `InlineRenderer.swift` and `BlockRow.swift`; Milestone 6
did not introduce new warnings or change those rendering paths.
