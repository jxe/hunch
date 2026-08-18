import Foundation
import Quagmire

/// Seed content for the welcome page that's dropped into a fresh workspace.
/// Returned as parsed `[Block]` so `Clamshell.createDocument` can serialize it
/// uniformly with the rest of the writer pipeline. The `# Welcome to Hunch`
/// heading is added by `createDocument` from the `title` argument — don't repeat
/// it here.
func welcomeContentBlocks() -> [Block] {
    BlockParser.parse(welcomeMarkdown)
}

private let welcomeMarkdown = """
Hunch is a markdown editor where every block is its own row. Try editing this page — what you type lives on disk as a plain `.md` file.

## A few things to try

- Type `## ` at the start of a line to make it a heading.
- Type `- ` for a bullet, `[] ` for a todo, `1. ` for a numbered list.
- Type three backticks for a code block, or `▸ ` for a toggle.
- Type `@` to mention another page in this workspace.

## Keyboard shortcuts (macOS)

▸ Show shortcuts
  - **↑ / ↓** — move between blocks
  - **Return** — edit the focused block
  - **Esc** — leave edit mode
  - **Cmd+B / I / E** — bold / italic / inline code
  - **Cmd+K** — turn the selection into a link or subpage
  - **Cmd+P** — search pages

## Your workspace

This file lives in the folder you picked. Everything Hunch writes is a plain `.md` file — open the folder in Finder (or Files, on iOS) anytime.
"""
