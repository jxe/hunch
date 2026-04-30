# Inline styling stuff

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
