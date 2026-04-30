# Inline link click → push onto NavigationStack

## Goal

Tapping an inline `[text](path.md)` link inside body text should navigate
to that page the same way a subpage row does — i.e. push the target onto
`WorkspaceModel.path` so the new doc covers the current one and iOS
edge-swipe-from-left pops back.

## Current behavior

- The subpage-row path works: a paragraph containing exactly one `.md` link
  is detected as `.subpage` in `Packages/Core/Sources/Core/Markdown/Parser.swift`
  and rendered via `subpageRow` in `Packages/UI/Sources/UI/BlockRendering.swift`,
  which is wired through `onSubpageTap` → `WorkspaceModel.openSubpage`.
- Inline links inside other text render with the `.link` attribute on
  SwiftUI's `Text` (see `InlineRenderer.swiftUIAttributed` in
  `Packages/UI/Sources/UI/BlockRendering.swift:17`). They get the blue
  underline styling but tapping them does **not** push — SwiftUI's default
  `Text(.link)` tap routes through `\.openURL`, and we don't intercept.

## Desired behavior

Inline `.md` links resolved against the workspace push the target doc.
Non-`.md` URLs (http(s), mailto, etc.) keep the system default behavior.

## Sketch

In `App/Sources/ContentView.swift`, attach an `OpenURLAction` to the
NavigationStack (or to `pageDetail`):

```swift
.environment(\.openURL, OpenURLAction { url in
    if let relative = model.workspaceRelativePath(for: url, currentDocURL: model.path.last) {
        model.openSubpage(relativePath: relative)
        return .handled
    }
    return .systemAction
})
```

Add a `WorkspaceModel.workspaceRelativePath(for url: URL, currentDocURL: URL?) -> String?`
helper:
- If `url` is absolute and inside `workspaceURL`, return its workspace-relative
  path.
- If `url` is relative (no scheme / host), resolve against
  `currentDocURL?.deletingLastPathComponent()` and return relative-to-workspace
  if inside.
- Only return non-nil for `.md` (or `.markdown`) targets.

## Out of scope

- Editor-mode link taps. NSTextView and UITextView have their own link
  handling paths (`NSTextViewDelegate.textView(_:clickedOnLink:at:)` /
  `UITextItemMenuConfiguration`). Skip until someone reports it.
- Wikilink syntax (`[[Page]]`). Not parsed today and not needed for this
  task — the markdown-link form covers the use case.

## Test loop

`./scripts/run.sh`, open a doc that contains an inline `[link](other.md)`
in a paragraph alongside other text, click the link, verify the stack
pushed and edge-swipe (iOS) / Cmd+[ (macOS) pops back.
