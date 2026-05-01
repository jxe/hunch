# Editor

A single-page block editor for iOS 26 / macOS 26, written in SwiftUI. Operates
on an in-memory `Document` — a list of `Block` cases. **No opinion on
serialization, persistence, or navigation.** The host wires those up.

Built for [Hunch](https://github.com/joeedelman/hunch). Designed to be
embeddable in other apps that want Notion-flavoured block editing without
inheriting Hunch's filesystem-and-markdown setup.

---

## User-facing features

What the editor does for the end user, regardless of how the host wraps it:

**Selection and edit-mode**
- Two modes: **nav mode** (block-level selection, no caret) and **edit mode**
  (one block has a live `BlockTextEditor`).
- ↑/↓ collapses the selection to a single block; Shift+↑/↓ extends it.
  Selection is always contiguous in document order.
- Return on a single-block selection enters edit mode. Esc exits back to nav.
- Click on a row enters edit mode and drops the cursor where you clicked
  (`characterIndexForInsertion(at:)`-precise — works on wrapped paragraphs).
  Click on a non-text part (marker, padding) seeks to end of the row.
- Up/Down at the editor's first/last visual line exits edit mode and moves
  to the previous/next block (intra-block arrow nav still works in the
  middle of wrapped paragraphs).

**Block reordering**
- Option+↑/↓ slides the selected block up or down (carries indent-descendants
  for headings/toggles).
- Drag the leading-gutter handle to reorder. Drop targets resolve by row
  midline with hysteresis. Dropping onto a closed toggle, template button,
  or subpage row appends as a child instead of inserting between rows.

**Indent**
- Tab / Shift-Tab indent and outdent in both nav mode (over the whole
  selection) and edit mode (the focused block). List items indent into a
  parent's structure; non-list blocks indent visually.

**Inline marks**
- Cmd-B bold, Cmd-I italic, Cmd-E code, Cmd-Shift-S strike. Toggles on the
  selection in edit mode; on the whole block(s) in nav mode.
- Marks round-trip through edits because the editor stores them on
  `Block.text: AttributedString` using `InlineAttributes` keys (defined in
  this package — `InlineAttributes.BoldAttribute`, `.ItalicAttribute`,
  `.CodeAttribute`, `.StrikethroughAttribute`).
- Cmd-K toggles a link on the selection.

**Block-prefix autotransforms**
Type these at the start of a paragraph; they fire on the trailing space:

| Trigger | Result |
|---------|--------|
| `# ` | H1 |
| `## ` | H2 |
| `### ` | H3 |
| `- ` or `* ` | Bullet |
| `1. ` | Numbered |
| `[]` or `[ ] ` | To-do |
| `> ` | Quote |
| `" ` | Toggle |

Enter triggers (on an empty-tail row): `---` → divider, ` ``` ` → code fence.

**@-mention popover**
Type `@` followed by a query. The host's `suggestPages(query:)` callback
returns up to 8 `MentionItem`s. ↑/↓ navigates, Return inserts a subpage
block, Esc dismisses.

**Turn Into**
Cmd-/ in nav mode (on a single block) opens a 3-column grid: H1/H2/H3,
Bullet/Numbered/To-do, Text/Toggle/Page/Divider/Template. Each has a
keyboard shortcut while the menu is open. On a subpage block, "Turn Into
anything-but-page" inlines the child page's content (`onLoadSubpage`) and
trashes the source file (`onAbsorbSubpage`).

**Pinch-to-insert** (trackpad / touchscreen)
Spread fingers between two rows to open a gap. Past threshold, releases
into a new empty paragraph at that index.

**Voice recording**
Cmd-Shift-V starts a `PageSpeechRecorder`; transcripts append to the
focused block in real time. The host can also kick off a recording via
`VoiceRecordingLaunchRequest.requestStart()` (e.g. from a Siri intent) —
the editor consumes the pending request on its next `onChange(of: scenePhase)`.

**Copy / paste**
The editor reads/writes the system pasteboard. The host owns the wire
format via `serializeBlocksForPasteboard` and `parseBlocksFromPasteboard`
callbacks (Hunch wires these to its markdown parser/serializer).

**Drag and drop**
In-app block drag uses a custom `BlockDragPayload` UTType — no host wiring
needed. Cross-app drag falls through to the pasteboard codecs.

**Subpage navigation and management**
- Tap a subpage row → host receives `onSubpageTap(pageID)` and pushes the
  child page on its navigation stack.
- Cmd-K on a paragraph that is a single markdown link, or @-mention commit,
  creates a subpage block via `onCreateSubpage`.
- Drop blocks onto a subpage row → editor calls `onAppendToSubpage` to move
  them into the child page.

**Toggle / template-button expand/collapse**
Click the chevron, or hit Return on a selected toggle. Toggle expansion is
page-local view state (not persisted to the model).

**Undo/redo**
Cmd-Z / Shift-Cmd-Z. The editor owns a `DocumentUndoController` that
registers structural ops (split/merge/indent/slide/delete/autotransform/
drag-drop) alongside NSTextView's typing-undo on the same shared
`UndoManager`.

---

## Quickstart

```swift
import SwiftUI
import Editor

struct ContentView: View {
    @State var document = Document(
        url: URL(fileURLWithPath: "/dev/null"),
        title: "Untitled",
        blocks: [.paragraph(text: AttributedString(""))]
    )

    var body: some View {
        PageView(document: $document)
    }
}
```

That's a working editor. No serialization, no navigation, no @-mention —
all defaults. Add callbacks as you need features:

```swift
PageView(
    document: $document,
    suggestPages: { query in myCatalog.search(query) },
    onSubpageTap: { pageID in router.push(pageID) },
    pageTitle: { pageID in myCatalog.title(for: pageID) },
    serializeBlocksForPasteboard: { blocks in myMarkdown.serialize(blocks) },
    parseBlocksFromPasteboard: { string in myMarkdown.parse(string) }
)
```

---

## The Block model

```swift
public enum Block: Identifiable, Equatable, Sendable {
    case paragraph(id: BlockID, text: AttributedString, indent: Int)
    case heading(id: BlockID, level: Int, text: AttributedString, indent: Int)
    case bullet(id: BlockID, text: AttributedString, indent: Int)
    case numbered(id: BlockID, text: AttributedString, indent: Int)
    case todo(id: BlockID, text: AttributedString, done: Bool, indent: Int)
    case quote(id: BlockID, text: AttributedString, indent: Int)
    case code(id: BlockID, source: String, language: String?, indent: Int)
    case divider(id: BlockID, indent: Int)
    case toggle(id: BlockID, title: AttributedString, indent: Int)
    case templateButton(id: BlockID, label: String, indent: Int)
    case subpage(id: BlockID, title: String, pageID: String, indent: Int)
}
```

- **`BlockID`** is a UUID wrapper (Hashable, Codable, Sendable).
- **`indent: Int`** is 0–5. Indent is structural (a heading at indent 1 is
  a child of the previous heading-at-indent-0); rendering reflects that.
- **`Block.text: AttributedString`** carries inline marks via the
  `InlineAttributes` keys exported from this package. The host's serializer
  translates these to whatever surface syntax (markdown `**bold**`, HTML
  `<b>`, etc.).
- **`Block.subpage`'s `pageID: String`** is opaque to the editor — whatever
  identifier the host uses (relative path, UUID, database key). The editor
  echoes it back unchanged in `onSubpageTap`, `onLoadSubpage`,
  `onAbsorbSubpage`, `onAppendToSubpage`.
- **`Block.subpage`'s `title: String`** is a fallback hint. The editor
  prefers `pageTitle(pageID)` from the host; falls back to this when the
  callback returns nil.

`Document` carries `url: URL`, `title: String`, `blocks: [Block]`,
`modificationDate: Date?`. The `url` field is host-meaningful only —
the editor doesn't read or write to it.

---

## Callback contract

Every `PageView` callback has a sensible default (no-op or pass-through)
so partially-wired hosts compile.

| Callback | Type | When it fires | Return semantics |
|----------|------|---------------|------------------|
| `suggestPages` | `(query: String) -> [MentionItem]` | While the @-mention popover is visible, on every render. The query is whatever the user has typed after `@`. | Up to 8 items shown; host owns ranking/filtering. Empty array shows "No matching pages". |
| `pageTitle` | `(pageID: String) -> String?` | Whenever a subpage row needs a display title (rendering a `.subpage` block, an @-mention popover row). | nil falls back to the cached `title` on the Block / MentionItem. |
| `onSubpageTap` | `(pageID: String) -> Void` | User clicks/taps a subpage row, or hits Return / → on a selected subpage block. | Host pushes the child page onto its navigation stack. |
| `onCreateSubpage` | `(title: String, requestedID: String?, initialContent: [Block]?) -> String?` | Cmd-K on a paragraph that's a single link, @-mention "create new" path, or Turn Into → Page. `initialContent` is the source block's indent-descendants when present. | Host persists a new page (prepending a title heading + serializing `initialContent`), returns the assigned id. nil falls back to `requestedID` or a default. |
| `onLoadSubpage` | `(pageID: String) -> [Block]?` | Expand Subpage (inline this child's content here, **keep the file**). | Host returns the child page's blocks. nil makes the action a no-op. |
| `onAbsorbSubpage` | `(pageID: String) -> Bool` | Turn Into a non-page block on a subpage row (inline content **and trash the source file**). Always paired with `onLoadSubpage` first. | true = file trashed (proceed with inlining); false = abort. |
| `onAppendToSubpage` | `(pageID: String, [Block]) -> Bool` | User drops blocks onto a subpage row. | true = host wrote them to the child file. false = no-op. |
| `onNavigateBack` | `() -> Void` | Cmd-[ in nav mode. | Host pops its navigation stack. |
| `onEdited` | `() -> Void` | After every mutation that changes the document. | Host marks dirty, kicks debounced save. |
| `onBlur` | `() -> Void` | Editor loses focus (window/key/scene transitions, document switch). | Host should flush any pending save. |
| `onRecordBlockDeletion` | `([Int], [Block], String) -> Void` | Right before a block-level deletion mutates the document. The host has the document's relative path; the editor supplies the indices, the about-to-be-deleted blocks, and a friendly action name. | Host writes a trash record so the deletion is restorable. |
| `serializeBlocksForPasteboard` | `([Block]) -> String` | User cuts or copies. | Host returns a string for the system pasteboard (markdown, RTF, plain — host's choice). Empty string cancels the copy. |
| `parseBlocksFromPasteboard` | `(String) -> [Block]?` | User pastes. | Host returns blocks parsed from the pasteboard string. nil cancels the paste. |

---

## Hosting requirements

- **iOS 26 / macOS 26 minimum.** Uses `TextEditor(text: Binding<AttributedString>)`
  on iOS, NSViewRepresentable wrapping NSTextView on macOS.
- **Inter font.** The host registers it (Hunch does this in
  [`FontRegistration.swift`](../../App/Sources/FontRegistration.swift)). The
  editor's typography assumes Inter is available — fallback to system fonts
  is fine for development but won't match the intended look.
- **Single multiplatform target works fine** (Hunch is one). `#if os(iOS)`
  / `#if os(macOS)` guards the platform-specific bits inside the package.
- **swift-tools 6.2** in the consumer's `Package.swift` (or modern Xcode
  project). Editor uses `swiftLanguageModes: [.v6]`.
- **No `UndoManager` provisioning.** `DocumentUndoController` is owned
  internally and recreated implicitly when `PageView`'s SwiftUI identity
  resets; explicitly cleared on document switch via `.onChange(of:
  document.id)`.

---

## What the editor doesn't do

- **No file I/O.** The host owns disk reads/writes. Hunch implements this
  via `FileStore` + `DocumentSaveCoordinator` in
  [`App/Sources/Storage/`](../../App/Sources/Storage/).
- **No markdown parsing/serialization.** The host owns wire formats. Hunch
  uses [swift-markdown](https://github.com/swiftlang/swift-markdown) wired
  through [`App/Sources/Markdown/`](../../App/Sources/Markdown/).
- **No multi-page navigation.** The editor is single-page; the host
  manages the navigation stack and pushes/pops in response to
  `onSubpageTap` / `onNavigateBack`. Hunch uses
  `NavigationStack(path: [URL])` in
  [`App/Sources/ContentView.swift`](../../App/Sources/ContentView.swift).
- **No sidebar, no @-mention list source, no history UI, no trash UI.**
  The host owns these. Hunch's implementations live in
  [`App/Sources/Shell/`](../../App/Sources/Shell/).

---

## Tests

```sh
swift test --package-path Packages/Editor
```

Covers autotransforms, document mutations, mention-trigger detection, and
the reorder drop resolver. Headless, fast.
