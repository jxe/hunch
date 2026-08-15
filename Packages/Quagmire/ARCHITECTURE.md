# Quagmire architecture

Quagmire is one SwiftPM library target. It intentionally presents a coherent
editor rather than a collection of independently versioned submodules.

## Ownership

Quagmire owns:

- the block-tree model and storage-neutral semantic change descriptions;
- `EditorView`, text-system bridges, selection, focus, undo, gestures, menus,
  autotransforms, and package resources;
- validation and one-transaction application of host-supplied block actions.

The embedding host owns:

- persistence, durability, serialization, and recovery;
- page identity resolution, navigation, images, previews, and page lifecycle;
- optional product actions, fonts, colors, feedback policy, and logging policy.

`EditorHost` is the seam between those responsibilities. Only
`persistCommit(changes:in:)` and `flush(_:)` are mandatory; every optional
feature has a neutral default and its unavailable UI fails closed.

## Data flow

`Document` is the observable, main-actor block tree. User edits and undo/redo
funnel through `Document.transaction`, producing storage-neutral
`DocumentChange` values. `EditorView` forwards each committed transaction to
`EditorHost.persistCommit`. The host may schedule asynchronous persistence, and
`flush(_:)` provides the durability barrier used during focus and lifecycle
transitions.

`EditorState` is one editing session's volatile state. A host owns the instance
but can mutate it only through the small public operations intended for host
use. Selection, focus transitions, overlays, expansion, and gestures otherwise
remain package-owned.

## Maintenance invariants

- Mount one stable `(Document, EditorState, EditorHost)` tuple per editor view.
- Treat `DocumentID`, subpage IDs, and image sources as host-defined opaque
  values.
- Keep public model snapshots value-typed and `Sendable`; keep observable UI
  state main-actor isolated.
- Load sounds and future packaged assets through `Bundle.module` and keep the
  resource smoke test exhaustive.
- Compile the minimal embedding contract in the separate normal-import test
  target so `@testable` access cannot mask an accidental API dependency.
- Keep the README quickstart synchronized with that compiled contract.

Hunch is the first end-to-end integration harness. Its public repository is
[github.com/jxe/hunch](https://github.com/jxe/hunch); Quagmire does not duplicate
Hunch's application or UI-test harness.
