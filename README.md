# Hunch

Open-source, improved Notion. Native iOS 26 + macOS 26. Your notes live as plain `.md` files in a folder you own — open them in any editor, sync them with iCloud, hand them to an agent.

## TL;DR

- ⚡  Native Swift, no Electron — fast cold start, fast typing, fast scroll
- 🎙️  Voice dictation built in, with a Siri shortcut
- 📂  Plain markdown files on disk — no database, no lock-in
- ☁️  iCloud-friendly by design — append-only writes, no merge fights
- 🛟  Every block you've ever typed is recoverable across all devices
- 🪜  Move a heading and its children come with it
- 🎯  One picker for "move to" — in-page sections + other pages, fuzzy-find both
- 🤝  Open source

---

## Why Hunch — what it does better than Notion

### ⚡  Native Swift, fast everywhere it counts

Cold start, scroll, keyboard latency, and memory footprint are all measurably better than the Notion app on the same hardware. iOS 26 + macOS 26, single multiplatform target, no web view.

### 📂  Your notes are a folder of `.md` files

Hunch's storage format ("Clamshell") is a folder of plain markdown plus a small amount of sidecar state (recovery log, trash, assets). The folder is **durable, portable, readable, iCloud-friendly**. Drop it into Obsidian, hand it to an LLM agent, grep it, version-control it, import it into a Notion vault. See [App/Sources/Clamshell/README.md](App/Sources/Clamshell/README.md).

### 🎙️  Voice dictation, with a Siri shortcut

Press to speak, get text. A Siri intent (`VoiceRecordingIntents`) means you can wire dictation into the iOS Action Button or a Shortcut and capture into the current page hands-free.

### 🛟  More robust restore, by design

Notion has version history; Hunch has a per-device append-only recovery log. Every atomic block (paragraph, list item, heading, code block) ever saved on any device stays recoverable until you explicitly purge it, and recovery survives the live `.md` getting deleted, corrupted, or overwritten. Per-device JSONL files mean iCloud just appends.

### 🪜  Move headings (and toggles) with their children

Slide a heading in nav mode and everything nested under it comes along. Notion makes you collapse the section first, then drag — Hunch tracks structure and moves the whole subtree.

### 🎯  One picker for "move to"

Cmd+Shift+M opens a single picker with two grouped sections: **destinations on this page** (every heading and toggle, indented to show outline) and **other pages** in the workspace. One search field filters both. Arrow keys traverse both groups. Return commits the top match. ([MoveDestinationSheet.swift](App/Sources/Shell/MoveDestinationSheet.swift))

### ⌨️  Two modes, no hover-floating-handle UI

Notion's block UI hangs off hover. That doesn't translate to touch and makes the eye chase a moving target on desktop. Hunch has two distinct modes:

- **Edit mode**: one block at a time, full-fidelity text editing.
- **Nav mode**: arrow keys move between blocks, Shift-arrow extends multi-block selection, Option+↑/↓ slides selected blocks, Tab/Shift-Tab indents, Delete removes, Return enters edit.

### 🏠  Home page, not a sidebar

Each workspace points at one home page. Subpages branch from there. There's no permanent sidebar tax — open by typing or by following a subpage row, not by scanning a tree.

### 📱  iOS gestures that feel native

Edge-swipe pops navigation. Pinch on a heading or toggle opens its nested view as its own page. Drag-to-reorder works without a hover state.

### 🔗  One link type — that's it

Page mention, page link, subpage row, database relation — Notion has four overlapping things. Hunch has one: `[Title](pages/foo.md)`. A paragraph that contains nothing but a link of that form renders as a subpage row; the same link inline renders as text. Done.

### 🅰️  Pre-March-2026 Notion typography, on purpose

We chase the typography Notion had before the 2026 redesign — the weights, sizes, and rhythm Notion users grew to like. References live under `References/typography/`; constants in `NotionStyle.swift`.

### 🤝  Open source

You can read the code, fork it, audit your own data layer, and ship patches. (License: TBD — currently no LICENSE in the repo.)

---

## What it does the same as Notion

- ✏️  **Block editor** — paragraph, H1/H2/H3, bullet/numbered/todo lists, toggles, quote, code, divider, image, subpage row.
- ⚡  **Markdown autotransforms** — `# `, `## `, `### `, `- `, `* `, `1. `, `[] `, `> `, ` ``` `, `---`, `" `.
- 🎨  **Inline marks** — bold, italic, code, strike, link, with the obvious Cmd-shortcuts (Cmd-B / I / E / Shift-S).
- 🔽  **Toggles** — `▸ Title` collapsible blocks with nested children.
- 📄  **Subpages** — open inside a stack, navigate back with the system back gesture.
- @  **@-mentions** — type `@` to link to another page.
- ↔️  **Indent / outdent / reorder** — Tab, Shift-Tab, Option+↑/↓, drag.

---

## Out of scope

- ❌  Real-time multiplayer collaboration
- ❌  Full databases (relations, formulas, rollups, views) — tables are parsed and rendered, not editable as a database
- ❌  Web clipping

---

## Coming later

- 🎨  Color (text and `style`-tag backgrounds)
- 🗂️  Category-style list rendering
- 🔎  Full-text search across the workspace
- 🔗  Inline link clicks for navigation (`[text](page.md)` mid-paragraph)
- 🖼️  Image paste outside edit mode
- 🅰️  Refresh of the Notion typography constants against the latest reference shots

---

## Building

See [CLAUDE.md](CLAUDE.md) for the full dev loop.

```sh
swift test --package-path Packages/Editor
xcodegen generate --spec project.yml --project .
xcodebuild -project Hunch.xcodeproj -scheme Hunch \
  -destination 'platform=macOS' -configuration Debug build
```
