# Editor

A single-page block editor for iOS 26 / macOS 26, written in SwiftUI. The
host owns three things per editing session: a `Document` (the persisted
content — a tree of `Block`s), an `EditorState` (the volatile session
state — selection, edit mode, gestures, expanded toggles), and an
`EditorHost` conforming class (file I/O, navigation, paste serialization,
@-mention candidate source). **No opinion on serialization, persistence,
or navigation.** The host wires those up.

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
Type `@` followed by a query. The host's `suggestPages(_:)` returns up
to 8 `MentionItem`s. ↑/↓ navigates, Return inserts a subpage block,
Esc dismisses.

**Turn Into**
Cmd-/ in nav mode (on a single block) opens a 3-column grid: H1/H2/H3,
Bullet/Numbered/To-do, Text/Toggle/Page/Divider/Template. Each has a
keyboard shortcut while the menu is open. On a subpage block, "Turn Into
anything-but-page" inlines the child page's content (`onLoadSubpage`) and
trashes the source file (`onAbsorbSubpage`).

**Pinch-to-insert** (trackpad / touchscreen)
Spread fingers between two rows to open a gap. Past threshold, releases
into a new empty paragraph at that index.

**Copy / paste**
The editor reads/writes the system pasteboard. The host owns the wire
format via `EditorHost.serializeBlocksForPasteboard` and
`parseBlocksFromPasteboard` (Hunch wires these to its markdown
parser/serializer).

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

`EditorView` takes three things: a `Document` binding, an `EditorState`,
and a host conforming to `EditorHost`. The host is class-bound and held
by reference; keep one stable instance per editor (e.g. `@State` on a
parent view) rather than constructing a fresh one each render — the
editor's row-level `.equatable()` gating relies on the host's identity
staying put.

```swift
import SwiftUI
import Editor

@MainActor
final class MyHost: EditorHost {
    func suggestPages(_ query: String) -> [MentionItem] { [] }
    func onSubpageTap(_ pageID: String) {}
    func pageTitle(_ pageID: String) -> String? { nil }
    func onCreateSubpage(_ title: String, _ requestedID: String?, _ initialContent: [Block]?) -> String? { nil }
    func onLoadSubpage(_ pageID: String) -> [Block]? { nil }
    func onAbsorbSubpage(_ pageID: String) -> Bool { false }
    func onAppendToSubpage(_ pageID: String, _ blocks: [Block]) -> Bool { false }
    func onRequestMoveDestination(_ blockIDs: [BlockID], _ inDocCandidates: [InDocMoveTarget], _ pick: @escaping (MoveDestination?) -> Void) {}
    func onNavigateBack() {}
    func onEdited() {}
    func onBlur() {}
    func onRecordBlockDeletion(_ indices: [Int], _ blocks: [Block], _ actionName: String) {}
    func serializeBlocksForPasteboard(_ blocks: [Block]) -> String { "" }
    func parseBlocksFromPasteboard(_ string: String) -> [Block]? { nil }
    func onSaveImages(_ items: [PastedImage]) -> [String] { [] }
    var linkPreviewProvider: LinkPreviewProvider? { nil }
    var imageURLResolver: ImageURLResolver? { nil }
}

struct ContentView: View {
    @State var document = Document(
        url: URL(fileURLWithPath: "/dev/null"),
        title: "Untitled",
        children: [.paragraph(text: AttributedString(""))]
    )
    @State var editorState = EditorState()
    @State var host = MyHost()

    var body: some View {
        EditorView(document: $document, state: editorState, host: host)
    }
}
```

That's a working editor. Most methods can be no-ops in early integration
— the editor degrades gracefully (paste is single-paragraph-only, @-mention
shows nothing, subpage taps are silent). Wire each method as you add the
corresponding feature.

**One `EditorView` per document.** The pair `(document, state)` is one
editing session — the editor caches focus, undo, and gesture state
internally and assumes both are stable. To switch documents (e.g. on
navigation), mount a fresh `EditorView` with a fresh `EditorState`. In
Hunch this is done by giving each `NavigationStack` destination its own
wrapper view that owns the state via `@State`.

---

## The Block model

A `Block` is a value-typed tree node: identity (`BlockID`), payload
(`BlockKind`), and children (`[Block]`). Depth is structural — there's
no per-block `indent` field; whether a block lives nested inside another
is the same fact as "is in that block's `children` array".

```swift
public struct Block: Identifiable, Equatable, Sendable {
    public let id: BlockID
    public var kind: BlockKind
    public var children: [Block]
}

public enum BlockKind: Equatable, Sendable {
    case paragraph(text: AttributedString)
    case heading(level: HeadingLevel, text: AttributedString)
    case bullet(text: AttributedString)
    case numbered(text: AttributedString)
    case todo(text: AttributedString, done: Bool)
    case quote(text: AttributedString)
    case code(source: String, language: String?)
    case divider
    case toggle(title: AttributedString)
    case templateButton(label: String)
    case subpage(title: String, pageID: String)
    case image(source: String, alt: String)
}

public enum HeadingLevel: Int, Comparable, Hashable, Sendable {
    case h1 = 1, h2 = 2, h3 = 3
}
```

- **`BlockID`** is a `UUID` wrapper (`Hashable`, `Codable`, `Sendable`).
- **One static factory per kind**: `Block.paragraph(text:)`,
  `Block.heading(level:text:)`, `Block.bullet(text:)`, etc. Each takes
  optional `id:` and `children:` parameters; defaults are a fresh
  `BlockID()` and an empty array.
- **Containment is enforced.** `Block.canContain(_:)` describes which
  kinds may hold which children: headings, toggles, list items, and
  template buttons accept children; paragraphs / quotes / code /
  dividers / subpages / images do not. A heading at level L can contain
  any block except headings at level ≤ L (Notion-style heading scope).
- **`Block.text: AttributedString`** projects the underlying kind's text
  payload (paragraph/heading/bullet/numbered/todo/quote/toggle title) for
  uniform read access; `Block.withText(_:)` returns a copy with the text
  replaced. Inline marks are stored on `AttributedString` via the
  `InlineAttributes` keys exported from this package
  (`BoldAttribute`, `ItalicAttribute`, `CodeAttribute`,
  `StrikethroughAttribute`). The host's serializer translates these to
  surface syntax (markdown `**bold**`, HTML `<b>`, etc.).
- **`Block.subpage`'s `pageID: String`** is opaque to the editor —
  whatever identifier the host uses (relative path, UUID, database key).
  The editor echoes it back unchanged in `onSubpageTap`, `onLoadSubpage`,
  `onAbsorbSubpage`, `onAppendToSubpage`.
- **`Block.subpage`'s `title: String`** is a fallback hint. The editor
  prefers `host.pageTitle(pageID)`; falls back to this when the host
  returns nil.

### Document

```swift
@Observable @MainActor
public final class Document {
    public let url: URL
    public var title: String
    public var children: [Block]   // root-level siblings
    public var modificationDate: Date?

    public init(url: URL, title: String, children: [Block], modificationDate: Date? = nil)

    // Read access
    public func snapshot() -> [Block]
    public func find(_ blockID: BlockID) -> Block?
    public func parent(of blockID: BlockID) -> BlockID?
    public func subtreeIDs(of blockID: BlockID) -> Set<BlockID>
    public func documentOrder(of blockID: BlockID) -> Int?
    public func walk(_ visit: (Block, Int, BlockID?) -> Void)

    // Mutation (used by the editor; hosts rarely need these directly)
    public func mutate(_ blockID: BlockID, _ transform: (inout Block) -> Void) -> Bool
    public func setText(_ blockID: BlockID, _ newText: AttributedString) -> Bool
    public func removeSubtree(_ blockID: BlockID) -> Block?
    public func insertSubtree(_ block: Block, at path: DropPath) -> Bool
    public func replaceSubtree(_ blockID: BlockID, with replacements: [Block]) -> Bool
    public func enforceHeadingContainment()
    // ... plus indent/outdent/slideSiblings/moveSubtrees/canDrop ...
}
```

- **`children` is the source of truth.** `@Observable` so SwiftUI
  subscribes to mutations; `Block` stays a value type so undo snapshots
  are cheap (the spine is array-shallow-copied; payloads are COW).
- **`url` is host-meaningful only.** The editor doesn't read or write to
  it; pass any stable URL (`/dev/null` for ephemeral cases works).
- **Hosts mostly read**: typically `children` (to serialize on save) and
  `title` (sidebar, window title). Mutation goes through the editor,
  which calls into the methods above.

---

## EditorState

The volatile session state that lives alongside `Document`: selection,
edit mode, in-flight gestures, expanded toggles, hover, drop targets.
The host constructs and owns one `EditorState` per `EditorView` (and can
`@Bindable` it for sibling UI like a status bar to observe). Mutation
flows through named methods inside the package — `internal(set)` blocks
external writes.

The state space is two orthogonal axes plus ambient annotations:

```swift
@Observable @MainActor
public final class EditorState {
    // Two orthogonal axes
    public internal(set) var mode: Mode               // .navigating | .editing
    public internal(set) var gesture: Gesture?        // .reordering | .pinchOpening | nil

    // Ambient — coexist with any (mode, gesture)
    public internal(set) var hoveredBlock: BlockID?
    public internal(set) var hoveredHandle: BlockID?
    public internal(set) var currentDropTarget: DropTarget?
    public internal(set) var expandedToggles: Set<BlockID>
    public internal(set) var expandedTemplates: Set<BlockID>
    public internal(set) var actionToast: String?
}

public enum Mode: Equatable, Sendable {
    case navigating(Selection)
    case editing(BlockID, overlay: Overlay?)
}

public enum Overlay: Equatable, Sendable {
    case mention(MentionMenuState)
}

public enum Gesture: Equatable, Sendable {
    case reordering(ReorderLift)
    case pinchOpening(PinchPreviewState)
}
```

- `mode` — what the user is fundamentally doing. `.navigating` carries
  block-level selection (`blocks: Set<BlockID>`, `anchor`, `cursor`);
  `.editing` names the block whose text is mounted in a live editor,
  with an optional modal overlay (currently the @-mention popover).
- `gesture` — a transient manipulation riding on top of nav mode.
  Invariant: a non-nil `gesture` only coexists with `mode == .navigating`
  — beginning a gesture commits or cancels any active edit first.
- Ambient state coexists with any `(mode, gesture)` combination.

**Computed read accessors** flatten the cases back to flat properties so
hosts that only want one axis don't have to switch on `mode`/`gesture`:
`state.selection`, `state.cursor`, `state.anchor`, `state.editingBlock`,
`state.mentionMenu`, `state.reorderLift`, `state.pinchPreview`,
`state.dropHoverPath` (the insertion-path projection of
`currentDropTarget`), `state.dropOntoBlockID` (the row-id projection).

**Mutation flows through named methods inside the package**
(`enterEditMode`, `setReorderLift`, `setMentionMenu`, etc.). Public
properties are `internal(set)` so the host can read but not write —
all transitions are funneled through methods that maintain invariants.

**`appendBlocks(_:actionName:)`** is the one externally-mutating method
exposed to hosts: a buffered append that the editor consumes via an
`.onChange` ticket. Used for things like a voice-transcription pipeline
where the host wants to append new content while honoring undo.

---

## Host protocol

Hosts conform to `EditorHost` (class-bound, `@MainActor`). Each method
is one extension point. There are no defaults — the protocol is small
enough that explicit no-op stubs in your host class read cleanly and
make it obvious which extension points you've left unwired.

| Method | Signature | When it fires | Return semantics |
|--------|-----------|---------------|------------------|
| `suggestPages` | `(_ query: String) -> [MentionItem]` | While the @-mention popover is visible, on every render. The query is whatever the user has typed after `@`. | Up to 8 items shown; host owns ranking/filtering. Empty array shows "No matching pages". |
| `pageTitle` | `(_ pageID: String) -> String?` | Whenever a subpage row needs a display title (rendering a `.subpage` block, an inline `[text](path.md)` link, an @-mention popover row). | nil falls back to the cached `title` on the Block / MentionItem. |
| `onSubpageTap` | `(_ pageID: String) -> Void` | User clicks/taps a subpage row, or hits Return / → on a selected subpage block. | Host pushes the child page onto its navigation stack. |
| `onCreateSubpage` | `(_ title: String, _ requestedID: String?, _ initialContent: [Block]?) -> String?` | Cmd-K on a paragraph that's a single link, @-mention "create new" path, or Turn Into → Page. `initialContent` is the source block's tree-descendants when present. | Host persists a new page (prepending a title heading + serializing `initialContent`), returns the assigned id. nil falls back to `requestedID` or a default. |
| `onLoadSubpage` | `(_ pageID: String) -> [Block]?` | Expand Subpage (inline this child's content here, **keep the file**). | Host returns the child page's blocks. nil makes the action a no-op. |
| `onAbsorbSubpage` | `(_ pageID: String) -> Bool` | Turn Into a non-page block on a subpage row (inline content **and trash the source file**). Always paired with `onLoadSubpage` first. | true = file trashed (proceed with inlining); false = abort. |
| `onAppendToSubpage` | `(_ pageID: String, _ blocks: [Block]) -> Bool` | User drops blocks onto a subpage row. | true = host wrote them to the child file. false = no-op. |
| `onRequestMoveDestination` | `(_ blockIDs: [BlockID], _ inDocCandidates: [InDocMoveTarget], _ pick: @escaping (MoveDestination?) -> Void) -> Void` | "Move To" picker. Editor supplies pre-filtered legal in-doc candidates; host merges with the workspace page list, presents UI, calls `pick` with a `MoveDestination` (`.page` or `.block`) or nil to cancel. | Move performed asynchronously via the `pick` continuation. |
| `onNavigateBack` | `() -> Void` | Cmd-[ in nav mode (or Cmd-[ in edit mode — that path commits live text first). | Host pops its navigation stack. |
| `onEdited` | `() -> Void` | After every mutation that changes the document. | Host marks dirty, kicks debounced save. |
| `onBlur` | `() -> Void` | Editor loses focus (window/key/scene transitions, document switch). | Host should flush any pending save. |
| `onRecordBlockDeletion` | `(_ indices: [Int], _ blocks: [Block], _ actionName: String) -> Void` | Right before a block-level deletion mutates the document. The host has the document's relative path; the editor supplies preorder indices, the about-to-be-deleted blocks (in flat preorder), and a friendly action name. | Host writes a trash record so the deletion is restorable. |
| `serializeBlocksForPasteboard` | `(_ blocks: [Block]) -> String` | User cuts or copies. | Host returns a string for the system pasteboard (markdown, RTF, plain — host's choice). Empty string cancels the copy. |
| `parseBlocksFromPasteboard` | `(_ string: String) -> [Block]?` | User pastes. | Host returns blocks parsed from the pasteboard string. nil cancels the paste. |
| `onSaveImages` | `(_ items: [PastedImage]) -> [String]` | User pastes one or more images (or image URLs from another app). | Host writes them to disk; returns relative paths suitable for `BlockKind.image.source`. Empty / shorter array cancels the paste. |
| `linkPreviewProvider` | `var: LinkPreviewProvider?` (`@Sendable (URL) async -> LinkPreview?`) | Editor calls this once per external `http`/`https` link in a rendered (read-only) row to fetch favicon + page title. | nil → links render undecorated, no fetching. |
| `imageURLResolver` | `var: ImageURLResolver?` | Resolve an image block's `source` to a file URL the renderer can load. | nil → renderer shows a missing-image placeholder. |

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
  internally and recreated implicitly when `EditorView`'s SwiftUI identity
  resets; explicitly cleared on document switch via `.onChange(of:
  document.id)`.

---

## What the editor doesn't do

- **No file I/O, no markdown parsing/serialization, no recovery/trash.**
  All the persistence machinery lives in Hunch's
  [`App/Sources/Clamshell/`](../../App/Sources/Clamshell/) — `FileStore`
  + `DocumentSaveCoordinator` for I/O, `BlockParser` / `BlockSerializer`
  (built on [swift-markdown](https://github.com/swiftlang/swift-markdown))
  for wire format, `RecoveryLog` (per-(device, page) JSONL) and
  `TrashStore` for soft-delete and the recoverable-blocks log.
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

Covers autotransforms, document tree mutations + walker semantics,
mention-trigger detection, the reorder drop resolver, and the nav-mode
key binding table. Headless, fast.
