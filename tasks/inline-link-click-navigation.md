# Inline link click → push onto NavigationStack

## Status

**Read-only path: done.** Inline `[text](page.md)` link taps inside
read-only rows now push the target onto the navigation stack. The
implementation lives in [App/Sources/ContentView.swift](../App/Sources/ContentView.swift)
(an `OpenURLAction` interceptor on the `NavigationStack`) plus
[Workspace.workspaceRelativeMarkdownPath](../App/Sources/Workspace.swift)
(URL → workspace-relative resolver, covered by
[WorkspaceRelativeLinkTests](../App/Tests/HunchUnitTests/WorkspaceRelativeLinkTests.swift)).

**Editor-mode path: not done.** When a link is inside the active
TextEditor, NSTextView (macOS) and UITextView (iOS) own the click. The
remainder of this note tracks that piece.

## Goal

Tapping an inline `[text](path.md)` link from inside an active
`BlockTextEditor` should also route through `WorkspaceWindow.openSubpage`
instead of (a) doing nothing, or (b) opening the link in the system
browser via `\.openURL`.

## Surfaces to extend

- **macOS** — implement
  `textView(_:clickedOnLink:at:)` in `MacBlockTextEditor.Coordinator`
  ([Packages/Editor/Sources/Editor/Text/BlockTextEditor.swift](../Packages/Editor/Sources/Editor/Text/BlockTextEditor.swift)).
  Walk up to the host's `OpenURLAction` (or expose a
  `EditorHost.onOpenURL(URL) -> Bool` so the editor stays
  filesystem-agnostic) and short-circuit if the host claims it.
- **iOS** — `UITextItemMenuConfiguration` /
  `textItemConfiguration(for:defaultMenu:)`. Same routing: ask the host
  first, fall through if it returns false.

Adding `EditorHost.onOpenURL` keeps the SPM package free of any
filesystem knowledge — the host (`EditorPageCoordinator`) already
holds `WorkspaceWindow` and can dispatch.

## Out of scope

- Wikilink syntax (`[[Page]]`). Not parsed today.
- Inline-link previews on hover (already a separate concern wired
  through `linkPreviewProvider`).

## Test loop

`./scripts/run.sh`, open a doc, enter edit mode on a paragraph that
contains an inline `[link](other.md)` mid-text, click the link, verify
the stack pushed and edge-swipe (iOS) / Cmd+[ (macOS) pops back.
