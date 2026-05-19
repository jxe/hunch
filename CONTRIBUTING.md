# Contributing to Hunch

Thanks for poking around. Hunch is a small codebase by design — three layers
that each earn their keep — so once you've found the right layer, changes
tend to be local. This doc points you at the layer you want.

## Requirements

- macOS 26 (Tahoe) with Xcode 26+
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen) for the project file
- Swift 6.2 toolchain (ships with Xcode 26)

The repo is two products in one workspace:

- a **multiplatform Swift app** (`Hunch.app`) targeting iOS 26 and macOS 26;
- a **standalone SwiftPM package** (`Packages/Editor/`) the app depends on
  and that's reusable in other hosts.

No third-party dependencies except [swift-markdown](https://github.com/swiftlang/swift-markdown).

## Build & test

```sh
# 1. Editor package — tests live here; keep them green before pushing UI changes
swift test --package-path Packages/Editor

# 2. Generate the Xcode project (don't hand-edit .xcodeproj — it's gitignored)
xcodegen generate --spec project.yml --project .

# 3. Build for macOS or iOS Simulator
xcodebuild -project Hunch.xcodeproj -scheme Hunch \
  -destination 'platform=macOS' -configuration Debug build
xcodebuild -project Hunch.xcodeproj -scheme Hunch \
  -destination 'generic/platform=iOS Simulator' -configuration Debug build

# 4. Run the freshly built macOS app
./scripts/run.sh
```

`scripts/run.sh` kills any running `Hunch.app` and launches the newest
Debug build.

`project.yml` is the source of truth for the Xcode project. If a file
doesn't show up in the build, regenerate the project rather than dragging
it into Xcode by hand.

## Source layout

The codebase splits into three layers, in increasing host-specificity:

### 1. `Packages/Editor/` — the reusable block editor

A SwiftUI block editor with **no opinion on serialization, persistence,
or navigation**. The host owns three things per editing session:

- a `Document` (a tree of `Block`s — paragraph, heading, list item,
  toggle, code, image, subpage row, divider, template button);
- an `EditorState` (volatile session state — selection, edit mode,
  in-flight gestures, expanded toggles, hover); and
- an `EditorHost`-conforming object (file I/O, navigation, paste
  serialization, @-mention candidate source).

Inside the package: the model (`Block`, `Document`), `EditorView`, the
`BlockTextEditor` NSViewRepresentable/UIViewRepresentable wrappers,
prefix autotransforms (`# `, `- `, `> `, `[] `, `" `, etc.), @-mention
detection, inline-mark `AttributedStringKey`s. The package's tests cover
the autotransform / mention / reorder / mutation layer — this is the only
test target with meaningful coverage, so keep `swift test
--package-path Packages/Editor` green.

Deeper docs: **[Packages/Editor/README.md](Packages/Editor/README.md)** —
embedding contract, full feature list, the `EditorHost` protocol surface.

### 2. `App/Sources/Clamshell/` — the storage format & engine

Clamshell is Hunch's persistent markdown format: a folder of `*.md`
plus a small amount of sidecar state (a per-(device, page) append-only
recovery log, a `Trash/` directory, an `Assets/` directory, and a
`.clamshell.json` metadata file).

`Clamshell` is the umbrella type — one per open directory — that
composes `FileStore`, `RecoveryLog`, and `TrashStore` privately and
exposes a single API for the host (`entries`, `lookupPage`,
`openPage`, `closePage`, `persistCommit`, `createPage`,
`moveToTrash`, `restorePage`, `listLostBlocks`, …). The markdown
parser/serializer (`Parser.swift`, `Serializer.swift`) and the
reconciliation engine that heals divergence between the journal and
the live `.md` (`PatchEngine.swift`, `Clamshell+Reconcile.swift`)
also live here.

Clamshell is `@Observable`; SwiftUI re-renders as the page list, title
cache, or home pointer change. The host doesn't thread callbacks
through it.

Deeper docs: **[App/Sources/Clamshell/README.md](App/Sources/Clamshell/README.md)** —
on-disk format, log record shape, operation reference, the
log-as-intent / file-as-order reconciliation model.

### 3. `App/Sources/` — the Hunch app shell

The glue: `HunchApp` (root, owns the workspace), `ContentView` (one per
window), `Workspace` / `WorkspaceWindow` (the per-window host model
and the `EditorHost` implementation), plus auxiliary views in
`App/Sources/Shell/` (search sheet, move-to picker, Recover sheet,
banners).

This layer is where the editor and the storage engine meet: navigation
(`NavigationStack(path: [URL])`), the security-scoped workspace bookmark,
voice dictation, link previews, paste handling, drag-and-drop, the menu
bar, and the iOS-specific gestures and Siri intents.

There is no permanent sidebar — page navigation is via the search sheet
(Cmd+P) or via subpage rows in the page body.

Tests for this layer live in `App/Tests/HunchUnitTests/` and cover the
parser/serializer + storage round-trips. The test target links against
the app target (`BUNDLE_LOADER`), so don't add a direct dependency on
`Editor` from the test target — that would link a second copy.

## Working notes for AI agents

`CLAUDE.md` at the repo root captures load-bearing details that aren't
obvious from reading the code: SwiftUI / NSTextView footguns, the
focus-grab dance, the `@Observable` same-value-write trap, the
edit-session state-machine shape, and the way commits funnel through
`Document.transaction`. It's written for Claude but useful for any
contributor wading into the editor internals.

## Style

- Editing existing files > adding new ones.
- Comments explain *why*, never *what*. Skip them when the code is clear.
- Don't add CHANGELOG.md, TROUBLESHOOTING.md, etc. unless the
  surrounding work needs them.
- iOS 26 / macOS 26 minimum. Single multiplatform target, not two —
  `#if os(iOS)` / `#if os(macOS)` for divergent bits.
- swift-tools-version 6.2.

## Typography

The visual target is Notion's typography from before the March 2026
redesign. Reference screenshots live under `References/typography/`;
constants live in `Packages/Editor/Sources/Editor/NotionStyle.swift`
(both the `NotionStyle` enum and the `BlockSpacing` enum). Don't sprinkle
magic numbers into `BlockRow.swift`.
