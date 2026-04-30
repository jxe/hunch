# Deferred Editor Affordances

## Inline Closing-Trigger Autotransforms

Add transforms for:

- `**bold**`
- `*it*` / `_it_`
- `` `code` ``
- `~~strike~~`
- `[text](url)`

Plug detection into `Autotransforms.swift`.

## Pre-Typing Toggles

Cmd-B with no selection should bias `typingAttributes` so the next typed
character is bold. Same for italic, code, and strikethrough.

## Navigation And Search

- Pull-down within a page opens in-page search.
- Add find-and-replace later if the editing model can support it cleanly.

## Toggles And Subpages

- Toggle children edit affordances. Recursive renderer is read-only today.
- Detect `[title](path.md)` paragraphs that resolve inside the workspace,
  render them as subpage rows, and push target on tap.
- Offer to create the file if the target path does not exist.

