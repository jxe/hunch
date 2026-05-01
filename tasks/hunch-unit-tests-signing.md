# HunchUnitTests can't load the Editor framework

## Goal

Make `xcodebuild -scheme Hunch -destination 'platform=macOS' test
-only-testing:HunchUnitTests` actually run the storage / parser /
serializer tests. Today it builds them but bombs at test-process startup
with a dyld/code-signing error.

## Current behavior

Symptom from `xcodebuild test`:

```
dyld: Library not loaded: @rpath/Editor_…_PackageProduct.framework/…/Editor_…_PackageProduct
  Reason: …'PackageFrameworks/Editor_…_PackageProduct.framework/…' (code signature in
  '…' not valid for use in process: mapping process and mapped file (non-platform)
  have different Team IDs)
…
Hunch encountered an error (Early unexpected exit, operation never finished
bootstrapping … Test crashed with signal abrt before establishing connection.)
```

Tried already (didn't help): on `HunchUnitTests` set `CODE_SIGN_IDENTITY: "-"`,
`CODE_SIGN_STYLE: Manual`, `DEVELOPMENT_TEAM: ""`, `CODE_SIGNING_REQUIRED:
NO`, `CODE_SIGNING_ALLOWED: NO`. The package framework's signature still
disagrees with whatever team owns the test process.

`build-for-testing` succeeds, so the test target compiles cleanly — this
is purely a runtime loader / signing-policy issue, not a refactor bug.

The same Editor framework loads fine inside the regular `Hunch` app
launched via `./scripts/run.sh` (which ad-hoc re-signs the bundle), so
the framework itself isn't broken.

## Desired behavior

`xcodebuild test -only-testing:HunchUnitTests` runs and reports
pass/fail for `FileStoreTests`, `DocumentSaveCoordinatorTests`,
`HistoryStoreTests`, `TrashStoreTests`, `WorkspaceBookmarkTests`,
`RoundTripTests`. Same for the Xcode UI test action on the Hunch scheme.

## Useful findings / hypotheses

- The package product is built into
  `…/PackageFrameworks/Editor_<hash>_PackageProduct.framework/`.
  Xcode auto-codesigns it (visible in build logs as
  `CodeSign … Editor_…_PackageProduct.framework`) using the Hunch
  target's Apple Development cert.
- The test-process complaint says "different Team IDs". Possibly the
  `xctest` runner inherits a stricter team policy than the loaded
  framework provides. macOS 14+ AppleSystemPolicy quirks around
  Apple-Development-signed bundles outside an Xcode debug session also
  apply (see comment in `scripts/run.sh`).
- Setting code-sign-off on the test target alone doesn't fix it because
  the loaded framework still has a developer-team signature. Would need
  to re-sign the framework ad-hoc *and* keep the host app signed
  consistently.

## Sketches to try

1. Mirror `scripts/run.sh`'s ad-hoc re-sign as a `preBuild` /
   `postBuild` script on `HunchUnitTests` that codesigns
   `$(BUILT_PRODUCTS_DIR)/PackageFrameworks/Editor_*_PackageProduct.framework`
   ad-hoc before the test runs.
2. Drop hardened runtime on the test build (`ENABLE_HARDENED_RUNTIME:
   NO`) for the test variant, and similarly for the package framework
   if Xcode allows.
3. Switch the unit-test bundle to `bundle.unit-test` *without* a
   `TEST_HOST` (a "library" unit-test target) — but that loses the
   ability to `@testable import Hunch`, which the storage tests need.
4. Move the storage code into its own SPM package (HCStorage or
   similar) — then `swift test` runs it natively, no Xcode signing
   involved. Largest refactor, cleanest outcome.

Option 4 is the structurally cleanest if the user is OK with a
3-package layout. Option 1 is the shortest path to a green test run.

## Test loop

```sh
xcodegen generate --spec project.yml --project .
xcodebuild -project Hunch.xcodeproj -scheme Hunch \
  -destination 'platform=macOS' test \
  -only-testing:HunchUnitTests 2>&1 | tail -30
```

Should print "Test Suite 'All tests' passed" rather than the dyld
diagnostic. Once that works, also verify the test action runs from the
Xcode UI (Cmd-U on the Hunch scheme).

## Out of scope

- Running these tests on iOS simulator. macOS-only is fine; the storage
  / parser / serializer code is platform-agnostic and macOS coverage is
  enough to catch regressions.
- The Editor SPM tests (`swift test --package-path Packages/Editor`).
  Those work fine and stay outside this task.
