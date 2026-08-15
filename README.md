# Hunch

Open-source, improved Notion. Native iOS 26 + macOS 26. Your notes live as plain `.md` files in a folder you own — open them in any editor, sync them with iCloud, hand them to an agent.

## TL;DR

- ⚡  Native Swift, no Electron — fast cold start, fast typing, fast scroll
- 🎙️  Voice dictation built in, with a Siri shortcut and optional on-device cleanup
- 📱  native iOS gestures for delete line, pinch to open, drag to reorder
- 📂  Plain markdown files on disk — no database, no lock-in
- ☁️  iCloud-sync friendly; some hidden files enable robust recovery, version history, and conflict-free multi-device editing
- 🛟  Every block you've ever typed, recoverable across all devices — and automatic recovery if a block goes missing
- 🤝  Open source

## Just like Notion used to be, but better

- ✏️  **Block editor** — paragraph, H1/H2/H3, bullet/numbered/todo lists, toggles, quote, code, divider, image, subpage row, template button.
- ⚡  **Markdown autotransforms** — `# `, `## `, `### `, `- `, `* `, `1. `, `[] ` / `[ ] `, `> `, ` ``` `, `---`, `" `.
- 🎨  **Inline marks** — bold, italic, code, strike, link, with the obvious Cmd-shortcuts (Cmd-B / I / E / Shift-S, Cmd-K for link).
- 🔽  **Toggles** — `▸ Title` collapsible blocks with nested children.
- 📄  **Subpages** — open inside a stack, navigate back with the system back gesture.
- @  **@-mentions** — type `@` to link to another page.
- ↔️  **Indent / outdent / reorder** — Tab, Shift-Tab, Option+↑/↓, drag.
- 🔎  **Search** — Cmd+P opens a fuzzy page picker; the magnifying glass on iOS does the same.
- 🛟  **Recover** — one sheet over trash, lost blocks, and explicitly-purged blocks, scoped to the current page or workspace-wide. Cmd+Shift+\\ on macOS; long-press / context-menu on the undo button on iOS.
- 🖼️  **Image paste** — paste an image from the clipboard, drag one in from Finder; bytes land in `Assets/` and the row becomes an image block.

---

## Why Hunch — what it does better than Notion

### ⚡  Native Swift, fast everywhere it counts

Cold start, scroll, keyboard latency, and memory footprint are all measurably better than the Notion app on the same hardware. iOS 26 + macOS 26, single multiplatform target, no web view.

### 📂  Your notes are a folder of `.md` files

Hunch's storage format ("Clamshell") is a folder of plain markdown plus a small amount of sidecar state (recovery log, trash, assets). The folder is **durable, portable, readable, iCloud-friendly**. Drop it into Obsidian, hand it to an LLM agent, grep it, version-control it, import it into a Notion vault.

### 🖼️  Images are plain files too

Paste from the clipboard, drop one in from Finder, drag a screenshot off the desktop — the bytes get persisted into `Assets/` as a regular `.png` / `.jpg` / `.heic` and the row becomes a standard markdown image reference. No proprietary blob format, no CDN, no "image broke because the host expired". Open the folder and the images are just files — diffable, backup-able, AirDrop-able, hand-able to a model.

### 🎙️  Voice dictation, with a Siri shortcut

Mic button in the page toolbar on both macOS and iOS — press to speak, get text inserted at the cursor (or appended as a paragraph when nothing's focused). On iOS, a Siri intent (`VoiceRecordingIntents`) means you can wire dictation into the Action Button or a Shortcut and capture into the current page hands-free.

When Apple's on-device language model is available, select one or more
transcript blocks and choose **Polish** to clean up their wording without
sending the text to a hosted service.

### 🛟  More robust restore, by design

Notion has version history; Hunch has a per-device append-only recovery log. Every atomic block (paragraph, list item, heading, code block) ever saved on any device stays recoverable until you explicitly purge it, and recovery survives the live `.md` getting deleted, corrupted, or overwritten. Per-device JSONL files mean iCloud just appends.

Opening the **Recover** sheet (Cmd+Shift+\\) gives you one unified view over trash (soft-deleted pages), lost blocks (orphans whose surrounding tree changed), and purged blocks (explicit deletes you can still pull back) — filterable by current page or the whole workspace.

And recovery isn't only manual. If a block vanishes from the `.md` because of an external edit, a corrupted file, or a sync conflict dropping content, opening the page **automatically re-splices** the missing subtree from the journal and surfaces a banner so you know it happened.

### ☁️  Multi-device editing without losing edits

The data layer is built for iCloud from the floor up. The recovery log is one JSONL file **per device**, so two devices appending to the same page never write to the same file — iCloud just syncs them, no merge step required. When the `.md` itself collides (same page edited on Mac and iPad before either synced), Hunch reads iCloud's version history via `NSFileVersion`, runs a structural merge, and writes the union back instead of letting one device's edits win. Worst case is a duplicated paragraph you can delete; the common case is both edits land.

### 🪜  Move headings (and toggles) with their children

Slide a heading in nav mode and everything nested under it comes along. Notion makes you collapse the section first, then drag — Hunch tracks structure and moves the whole subtree.

### 🎯  One picker for "move to"

Cmd+Shift+M opens a single picker with two grouped sections: **destinations on this page** (every heading and toggle, indented to show outline) and **other pages** in the workspace. One search field filters both. Arrow keys traverse both groups. Return commits the top match.

### 🔎  Search is local and instant

Cmd+P searches page titles and visible body text through a local, disposable SQLite FTS5 index. It understands word stems, diacritics, partial words, and quoted phrases, ranks title matches first, and shows the best matching passage without exposing workspace paths. No page content leaves the device. Arrow keys + Return open the selected page; the magnifying-glass toolbar item does the same on iOS, with title-only search as a fallback when FTS5 is unavailable.

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

### 🪄  Smart inline links

Internal `[…](pages/foo.md)` links render the **live target title**, not the file path — rename a page and links to it update on next render. Paste a bare external URL and it picks up a **favicon + page title** chip, fetched via `LinkPresentation` and cached on disk at `~/Library/Application Support/Hunch/LinkPreviews/`. No iframe, no preview card, just inline text that doesn't look like a raw URL.

### 🪟  Many windows on one workspace

Cmd+N opens another window onto the same workspace; each window keeps its own navigation stack. Open a subpage from one window and another window that already has it open splices its stack to match — no duplicate editors fighting over the same file.

### 🅰️  Pre-March-2026 Notion typography, on purpose

We chase the typography Notion had before the 2026 redesign — the weights, sizes, and rhythm Notion users grew to like.

### 🤝  Open source

You can read the code, fork it, audit your own data layer, and ship patches. Licensed under [MIT](LICENSE).

---

## ⌨️  Keyboard shortcuts (macOS)

**Navigation**

- `Cmd+P` — search pages
- `Cmd+[` — back
- `Cmd+R` — reload pages
- `Cmd+Shift+O` — switch workspace
- `Cmd+Shift+\\` — open Recover sheet

**Editing**

- `Cmd+B` / `Cmd+I` / `Cmd+E` — bold / italic / inline code
- `Cmd+Shift+S` — strikethrough
- `Cmd+K` — link selection / promote to subpage
- `Cmd+/` — Turn Into…
- `Cmd+Z` / `Cmd+Shift+Z` — undo / redo

**Nav mode (no edit cursor)**

- `↑` / `↓` — move between blocks
- `Shift+↑` / `Shift+↓` — extend selection
- `Option+↑` / `Option+↓` — move selected block(s)
- `Tab` / `Shift+Tab` — indent / outdent
- `Return` — enter edit mode (or open the selected subpage)
- `Delete` — remove selection
- `Cmd+Shift+M` — move selection to another page…
- `Esc` — leave edit mode

---

## Probably never

- ❌ Real-time multiplayer collaboration
- ❌ Full databases (relations, formulas, rollups, views)
- ❌ Tables
- ❌ Embeds besides just fancy external link mentions
- ❌ Embedded general-purpose AI chat or agent UI

---

## Under the hood

Hunch is built on two reusable pieces, both documented in this repo:

- **[Quagmire](Packages/Quagmire/README.md)** — a SwiftUI block editor (paragraphs, headings, lists, toggles, code, inline marks, autotransforms, drag-reorder, @-mentions) with no opinion on storage, navigation, or serialization. Drop it into any iOS 26 / macOS 26 app and wire up an `EditorHost`.
- **[Clamshell](App/Sources/Clamshell/README.md)** — Hunch's on-disk format and storage engine: a folder of `.md`, a per-device append-only recovery log, trash, and assets. Durable, portable, iCloud-friendly, recoverable.

Want to build, hack on, or send a patch? See [CONTRIBUTING.md](CONTRIBUTING.md).
