# Contributing to Quagmire

Quagmire is a native SwiftUI block editor for iOS and macOS. Contributions
should preserve its central boundary: the package owns editing behavior and
transient interaction state, while the host owns persistence, serialization,
navigation, product actions, and visual policy.

## Requirements

- macOS 26 or newer
- Xcode 26 or newer with Swift 6.2
- an installed iOS Simulator runtime for the simulator build

## Verify a change

From the repository root:

```sh
./scripts/verify.sh
```

For a quicker edit-test loop, run `swift test`. The full script cleans the
package, runs every test target, and performs clean macOS and iOS Simulator
builds. It is the local release gate; the project deliberately has no duplicate
example app or CI workflow.

## Change boundaries

- Keep `DocumentID` and subpage `pageID` values opaque. Do not infer storage
  paths or formats from them.
- Route document mutations through `Document.transaction` or the narrowly
  named system-replacement APIs so undo, semantic diffs, and containment stay
  coherent.
- Keep optional host features neutral by default. Persistence and durability
  waiting are the only mandatory `EditorHost` responsibilities.
- Preserve package resource lookup through `Bundle.module`.
- Add public API only when a real host needs it; prefer role-based names such as
  `EditorView`, `Document`, and `Block` over brand-prefixed type names.
- Update the README and public-consumer test whenever the minimal embedding
  contract changes.

## Dependency policy

Use compatible SwiftPM requirements for library dependencies and verify the
resolved graph locally. `Package.resolved` is intentionally ignored because a
library must not impose its development lockfile on consumers.

See [ARCHITECTURE.md](ARCHITECTURE.md) for ownership and data-flow details.
