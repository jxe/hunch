# Editor extraction Milestone 7 verification record

Recorded 2026-08-23. This completes the Quagmire extraction plan.

## Result

- Quagmire is now a standalone public Swift package at
  <https://github.com/jxe/quagmire>.
- Release `0.1.0` points to Quagmire commit
  `4049fd4d1d941a123a329597984a34ac61c8c03c`.
- Hunch resolves Quagmire from the tagged remote URL with an exact `0.1.0`
  requirement. Its former `Packages/Quagmire` subtree was removed only after
  clean revision-pinned and tagged-remote verification passed.
- Hunch documentation now links to the standalone package and describes the
  cross-repository workflow: use a local SwiftPM override while developing,
  then tag Quagmire and make a separate Hunch dependency bump.

## History extraction

The extraction ran only in a disposable clone. The final filter included both
historical package locations so the rename from `Editor` to `Quagmire` did not
discard the package's earlier development:

```sh
git filter-repo --force \
  --path Packages/Editor/ \
  --path Packages/Quagmire/ \
  --path-rename Packages/Editor/: \
  --path-rename Packages/Quagmire/:
```

The resulting repository retained 190 relevant commits and 120 file-history
steps for `EditorView`. Its tracked release tree was byte-identical to the
verified Hunch package subtree before the standalone README installation
instructions were updated for the public release.

An initial literal extraction of only `Packages/Quagmire` retained 18 commits
and was rejected. No history rewriting was performed in the working Hunch
repository.

## Toolchain

- Apple Swift 6.4 (`swiftlang-6.4.0.20.104`)
- Xcode 27.0 beta, build `27A5194q`
- XcodeGen 2.45.4
- iOS destination: iPhone 17 Pro, iOS 27.0 simulator,
  `C76DE979-27D7-4BE5-AD11-3FC223402AB9`

## Verification matrix

| Check | Result |
|---|---|
| Pre-extraction package `scripts/verify.sh` | PASS — package tests plus clean macOS and iOS Simulator builds. |
| Pre-extraction Hunch integration | PASS — 352 macOS tests in 27 suites, iOS 27 build, and all 17 focused UI tests. |
| Standalone clean-checkout verification | PASS — 341 behavior tests in 33 suites, 2 normal-import public API tests, and clean macOS and iOS Simulator builds. |
| Untagged remote adoption | PASS — clean resolution at commit `4049fd4`, 352 Hunch macOS tests, iOS 27 build, and all 17 focused UI tests. |
| Tagged dependency resolution | PASS — clean resolution selects Quagmire `0.1.0` at revision `4049fd4`; Hunch's graph continues to select EmojiKit 3.0.0. |
| Exact `0.1.0` Hunch integration | PASS — 352 macOS tests, iOS 27 build, and all 17 focused UI tests. |
| Link and resource graph | PASS — one Quagmire product is linked and its resource bundles are copied under remote resolution. |
| Project generation and diff hygiene | PASS — `xcodegen generate` and `git diff --check`. |

The compiler continues to report the existing SwiftUI `Text + Text`
deprecation warnings in Quagmire. They did not fail verification and were not
introduced by the extraction.

## Release and ownership boundary

- Quagmire source, public API tests, package verification, architecture, and
  release tags now live in the standalone repository.
- Hunch owns its integration configuration, recovery compatibility, app-hosted
  unit coverage, and end-to-end UI tests.
- Hunch intentionally uses exact `0.x` versions while the public boundary is
  settling. Compatible ranges and a `1.0.0` compatibility commitment remain
  deferred.
