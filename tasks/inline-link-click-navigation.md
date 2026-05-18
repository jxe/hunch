# Inline link click → push onto NavigationStack

## Status

**Read-only path: done.** Inline `[text](url)` link taps inside
read-only rows now push the target onto the navigation stack. The
`OpenURLAction` interceptor lives *inside* `EditorView` (so the editor
owns its link routing) and dispatches via
[EditorHost.openLink(_ target: LinkTarget) -> Bool](../Packages/Editor/Sources/Editor/EditorHost.swift).
The host (`WorkspaceWindow`) classifies the URL via
[EditorHost.resolveWorkspacePageID(from:)](../Packages/Editor/Sources/Editor/EditorHost.swift)
— the same hook the editor uses at render time for inline-link
decoration and at Cmd-K-on-link time for subpage creation. The Hunch
impl wraps
[Workspace.workspaceRelativeMarkdownPath](../App/Sources/Workspace.swift)
(covered by
[WorkspaceRelativeLinkTests](../App/Tests/HunchUnitTests/WorkspaceRelativeLinkTests.swift));
non-nil pageIDs route through `openSubpage`, nil falls through to the
system handler.

**Editor-mode path: not done.** When a link is inside the active
TextEditor, NSTextView (macOS) and UITextView (iOS) own the click. The
remainder of this note tracks that piece.

## Goal

Tapping an inline `[text](url)` link from inside an active
`BlockTextEditor` should also route through `host.openLink(.url(...))`
instead of (a) doing nothing, or (b) opening the link in the system
browser via `\.openURL`.

## Surfaces to extend

- **macOS** — implement `textView(_:clickedOnLink:at:)` in
  `MacBlockTextEditor.Coordinator`
  ([Packages/Editor/Sources/Editor/Text/BlockTextEditor.swift](../Packages/Editor/Sources/Editor/Text/BlockTextEditor.swift)).
  Call `host.openLink(.url(url))`; return true if the host handled it.
- **iOS** — `UITextItemMenuConfiguration` /
  `textItemConfiguration(for:defaultMenu:)`. Same routing: ask the host
  first, fall through if `openLink` returns false.

`EditorHost.openLink` already exists; both surfaces just need to call it
and let the host decide.

## Out of scope

- Wikilink syntax (`[[Page]]`). Not parsed today.
- Inline-link previews on hover (already a separate concern wired
  through `linkPreviewProvider`).

## Test loop

`./scripts/run.sh`, open a doc, enter edit mode on a paragraph that
contains an inline `[link](other-page.md)` mid-text, click the link,
verify the stack pushed and edge-swipe (iOS) / Cmd+[ (macOS) pops back.
