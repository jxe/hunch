# Quagmire

A single-page block editor for iOS 26 / macOS 26, written in SwiftUI. The
host owns three things per editing session: a `Document` (the persisted
content — a tree of `Block`s), an `EditorState` (the volatile session
state — selection, edit mode, gestures, expanded toggles), and an
`EditorHost` conforming class (file I/O, navigation, paste serialization,
@-mention candidate source). **No opinion on serialization, persistence,
or navigation.** The host wires those up.

Designed to be embedded in apps that want a native block editor without
inheriting a particular filesystem, serialization format, or visual identity.

The name is deliberate: rich-text editing is notoriously a quagmire, while the
package's job is to make that complexity embeddable. The known search tradeoffs
were accepted at naming time: an unrelated Python package already uses
`quagmire`, and the ordinary word and popular-culture associations are crowded;
no conflicting Swift module was found in the 2026-08-15 screening.

---

## Installation

Quagmire currently supports iOS 26 and macOS 26 with Swift 6.2. Until the
standalone repository and `0.1.0` release are published, add it as a local
SwiftPM dependency:

```swift
dependencies: [
    .package(path: "../Quagmire")
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "Quagmire", package: "Quagmire")
        ]
    )
]
```

Then use `import Quagmire`. A remote URL and exact-version installation snippet
will replace the local-path example when `0.1.0` is published; this README does
not advertise a repository or release that does not yet exist.

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
  midline with hysteresis. Destination frames are frozen for the lifetime of
  the drag, so the animated insertion gap cannot move the target being tested;
  the live page origin still projects those frames through autoscroll.
  Dropping onto a closed toggle, template button, or document-link row appends as a
  child instead of inserting between rows.

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
Type `@` followed by a query. The host's `suggestDocuments(_:in:)` returns up
to 8 `MentionItem`s. ↑/↓ navigates, Return inserts a document-link row,
Esc dismisses.

**Turn Into**
Cmd-/ in nav mode (on a single block) opens a 3-column grid: H1/H2/H3,
Bullet/Numbered/To-do, Text/Toggle/Page/Divider/Template. Each has a
keyboard shortcut while the menu is open. On a document-link row, "Turn Into
anything-but-page" inlines the child page's content (`loadDocumentBlocks(_:)`) and
trashes the source file (`inlineAndRetireDocument(_:parent:)`).

**Host-supplied block actions**
- Hosts can return `EditorBlockAction` values with a stable id, title, system
  image, applicability predicate, and async replacement handler.
- The editor snapshots explicitly selected text-bearing rows in document
  order, rejects results for blocks changed while the action was running, and
  applies the remaining replacements as one undoable transaction.
- A handler may replace any subset of the selected blocks, and each replacement
  may use any `BlockKind`; replacements do not have to preserve the source type.
- Host actions appear after native editor actions. A host menu can invoke the
  same action through `EditorCommands.performBlockAction` using its id.

**Pinch-to-insert** (trackpad / touchscreen)
Spread fingers between two rows to open a gap. Past threshold, releases
into a new empty paragraph at that index.

**Copy / paste**
The editor reads/writes the system pasteboard. The host owns the wire
format via `EditorHost.serializeBlocksForPasteboard` and
`parseBlocksFromPasteboard` (a markdown-backed host can wire these to its own
parser and serializer).

**Drag and drop**
In-app block drag uses a custom `BlockDragPayload` UTType — no host wiring
needed. Cross-app drag falls through to the pasteboard codecs.

**Document links**
- Tap a document-link row → host receives `openDocument(_:)` and pushes the
  child page on its navigation stack.
- Inline `[text](url)` clicks in read-only rows go through the editor's
  `OpenURLAction` interceptor: the editor classifies the URL via
  `host.resolveReference(from:in:)` (its own host-owned classifier — same hook
  used at render time for inline-link decoration). Internal hits dispatch
  to `host.openDocument(_:)`; external URLs fall through to the system
  handler via `OpenURLAction.systemAction`.
- Cmd-K / Turn Into → Page on a paragraph creates a document-link row via
  `createDocument` (async — the editor spawns a Task and splices the link
  row after the host returns the new id). The editor consults
  `host.resolveReference` to decide whether an existing link's URL names an
  internal page; it never inspects the URL itself. @-mention commit only
  references pages that already exist — it never calls `createDocument`.
- Drop blocks onto a document-link row → editor calls `appendToDocument` to move
  them into the child page.

**Toggle / template-button expand/collapse**
Click the chevron, or hit Return on a selected toggle. Toggle expansion is
page-local view state (not persisted to the model).

**Undo/redo**
Cmd-Z / Shift-Cmd-Z. The editor owns a `DocumentUndoController` that
registers structural ops (split/merge/indent/slide/delete/autotransform/
drag-drop) alongside 750 ms pause-delimited typing checkpoints on the same
shared `UndoManager`. Native text-view undo stays disabled because its entries
can retain a text view after SwiftUI unmounts it.

---

## Quickstart

`EditorView` takes a `Document` reference, an `EditorState`, and a host
conforming to `EditorHost`; an optional `EditorConfiguration` supplies visual,
feedback, and logging policy. `Document` is `@Observable` and
updated in place on external reloads, so a plain reference suffices — no
`Binding` needed. The host is class-bound and held
by reference; keep one stable instance per editor (e.g. `@State` on a
parent view) rather than constructing a fresh one each render — the
editor's row-level `.equatable()` gating relies on the host's identity
staying put.

```swift
import SwiftUI
import Quagmire

@MainActor
final class MyHost: EditorHostDefaults {
    func persistCommit(changes: [DocumentChange], in document: Document) {}
    func flush(_ document: Document) async {}
}

struct ContentView: View {
    @State var document = Document(
        id: DocumentID("welcome-note"),
        children: [.paragraph(text: AttributedString(""))],
        fallbackTitle: "Welcome"
    )
    @State var editorState = EditorState()
    @State var host = MyHost()

    private let editorConfiguration = EditorConfiguration(
        theme: EditorTheme(),
        isAudioFeedbackEnabled: false,
        isHapticFeedbackEnabled: false
    )

    var body: some View {
        EditorView(
            document: document,
            state: editorState,
            host: host,
            configuration: editorConfiguration
        )
    }
}
```

Only persistence and flush are required. `DocumentID` is opaque to the editor:
it can name a database row, remote object, or in-memory session and never needs
to encode a file URL. `persistCommit` reports semantic block snapshots through
`DocumentChange`; translating those changes into storage records is host policy.
Silently dropping the callback would leave a host with no persistence, so a
non-persisting integration must provide explicit empty bodies for both methods.

That's a working editor. `EditorHostDefaults` above is what makes two methods
enough — it opts out of every optional surface at once. Swap it for the
narrower markers as the host grows into them; see "Opting out of a surface".

**One `EditorView` per document.** The pair `(document, state)` is one
editing session — the editor caches focus, undo, and gesture state
internally and assumes both are stable. To switch documents (e.g. on
navigation), mount a fresh `EditorView` with a fresh `EditorState`. A
`NavigationStack` host can give each destination a wrapper view that owns the
state via `@State`.

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
    case documentLink(label: AttributedString, reference: DocumentReference)
    case image(source: String, alt: String)
    case unsupported(payload: String, display: String)
}

public enum HeadingLevel: Int, Comparable, Hashable, Sendable, CaseIterable {
    case h1 = 1, h2 = 2, h3 = 3, h4 = 4, h5 = 5, h6 = 6

    static let authorable: [HeadingLevel]   // [.h1, .h2, .h3]
    var isAuthorable: Bool
}
```

- **`BlockID`** is a `UUID` wrapper (`Hashable`, `Codable`, `Sendable`).
- **`unsupported` carries content this editor has no model for.** `payload` is
  opaque — Quagmire never parses, rewrites, or interprets it, and hands it back
  verbatim on serialization; `display` is a short neutral label for the row
  ("Table", "HTML"). The row renders read-only and is otherwise a normal leaf
  block: selectable, movable, deletable, undoable. Without it a host has two
  options for content it can't model, and both lose it — drop it, or degrade it
  into a paragraph that the serializer then escapes. This is a *per-block*
  value: no ranges, no offsets, nothing that has to stay in sync as the
  document changes around it, and no document-wide source tracker.

  It is not a general escape hatch and does not make a format round-trip
  lossless. It can only carry what the host's parser hands it as a discrete
  block. Constructs that dissolve before that point — inline content with no
  `InlineAttributes` equivalent, or syntax a parser resolves and discards —
  are still lost, and a host should say so rather than imply otherwise.
- **All six heading levels are representable; only three are authorable.**
  The creation UI (Turn Into, the `#`/`##`/`###` prefix transforms) offers
  H1–H3, matching Notion. H4–H6 exist so a document that already contains
  them survives being opened and edited — they parse, nest, render, copy,
  undo, and serialize at their true depth. A host whose format has deeper
  headings does not lose them just because this editor won't create them.
  `EditorTheme.headingSize(_:)` continues the type ramp down to body size for
  H4–H6; there is no Notion reference for those, so they are deliberately
  understated rather than invented.
- **One static factory per kind**: `Block.paragraph(text:)`,
  `Block.heading(level:text:)`, `Block.bullet(text:)`, etc. Each takes
  optional `id:` and `children:` parameters; defaults are a fresh
  `BlockID()` and an empty array.
- **Containment is enforced.** `Block.canContain(_:)` describes which
  kinds may hold which children: headings, toggles, list items, and
  template buttons accept children; paragraphs / quotes / code /
  dividers / document links / images do not. A heading at level L can contain
  any block except headings at level ≤ L (Notion-style heading scope).
- **`Block.text: AttributedString`** projects the underlying kind's text
  payload (paragraph/heading/bullet/numbered/todo/quote/toggle title) for
  uniform read access; `Block.withText(_:)` returns a copy with the text
  replaced. Inline marks are stored on `AttributedString` via the
  `InlineAttributes` keys exported from this package
  (`BoldAttribute`, `ItalicAttribute`, `CodeAttribute`,
  `StrikethroughAttribute`). The host's serializer translates these to
  surface syntax (markdown `**bold**`, HTML `<b>`, etc.).
- **`Block.documentLink`'s `reference`** is a `DocumentReference` — an opaque
  handle the host defines and the editor never inspects. See "Resolving
  reference targets" below.
- **`Block.documentLink`'s `label`** is what the author wrote. It is *not* the
  displayed title on its own: the host's live title from `lookupDocument` wins
  when it has one, so renaming a target updates every row pointing at it
  without rewriting any document. A host whose labels are authored source
  returns no title and the label stands.
- **Dedupe the background work.** This is called from a view body. An
  un-deduped fetch per call is an infinite loop, not a cache miss.
- **Be observation-tracked.** If completing the resolution doesn't invalidate
  the view, the row stays `.pending` forever.

`.pending` and `.unavailable` are not `.missing`, and the editor renders them
differently on purpose. An unresolved reference is probably fine and must not
look broken; an unreachable one still exists and must not invite the user to
clean it up. Both expose no capabilities, so nothing destructive is offered
against a target whose state is unknown.

**Capabilities are per-target.** A host may hold a mix — pages you own and pages
shared read-only, local files and ones behind a network that is down. The editor
hides or disables an affordance before its first mutation rather than letting
the user try and fail. Hosts with a uniform answer return `.all` and forget
about it. There is no `delete` capability: deleting the *row* is always allowed
because it is this document's content, and whether that should also delete the
target is host policy, reported through `didDeleteDocumentLink`.

- **`children` is `internal(set)`.** Mutations funnel through
  `transaction(name:_:)` (or its primitives `mutate` / `setText` /
  `insertSubtree` / `replaceSubtree`) so undo and heading containment
  are applied uniformly. For bulk non-authored replacement, use the narrowly
  named replacement helper for that path — and see below, because which one
  you pick has real consequences for the user.

### Replacing the tree from outside the editor

A host replaces a document's tree for two different reasons, and the editor
needs to be told which:

- **`replaceChildrenReconciled(_:)`** — you built the new tree by splicing into
  the current one, so surviving blocks kept their `BlockID`s and their parents.
  Another window appended blocks; a peer's journal restored a subtree; your
  backend returned a completed document on save. Outstanding undo entries are
  *rebased* against your change rather than discarded, so undoing restores the
  user's tree plus whatever you contributed. Returns `.reconciled` when that
  worked, or `.wholesale` when it couldn't. Two shapes can't be expressed as a
  rebase and degrade honestly instead: **reparenting** a block that already
  existed, and **reordering** surviving siblings. Both would require guessing
  where a moved block belongs in a stale snapshot that may not contain its new
  neighbours. Insertions, removals, and in-place value changes — the shapes a
  backend actually produces — all reconcile.
- **`replaceChildrenFromExternalReload(_:)` / `…FromConflictResolution(_:)` /
  `…FromSystemMutation(_:)`** — a fresh parse or a merge result. Nothing about
  the old id set survives, so the undo stack is discarded.

Reach for the reconciled variant whenever your ids survive. A backend whose
writes routinely come back changed — one that completes or normalizes a
document server-side — would otherwise clear the user's undo history on every
save, which makes the editor unusable. Undo entries are whole-tree snapshots;
reconciling is what keeps that design honest under a live backend.
- **`title` is derived.** No stored field, no risk of drift after children
  mutate — pulled from the first top-level H1, then `fallbackTitle`, then
  `"Untitled"`.
- **`id` is storage-neutral.** `DocumentID` is an opaque host-supplied
  identity. A document can live entirely in memory or behind a remote store;
  the host retains URLs, modification dates, and other storage metadata.
- **Hosts mostly read**: typically `children` (to serialize on save) and
  `title` (sidebar, window title). Structural mutation goes through the
  editor's `EditorView.mutate(_:_:)`, which wraps `document.transaction`,
  derives a storage-neutral pre→post `[DocumentChange]` diff, and fires
  `host.persistCommit(changes:in:)` afterward.

---

## EditorState

The volatile session state that lives alongside `Document`: selection,
edit mode, in-flight gestures, expanded toggles, hover, drop targets.
The host constructs and owns one `EditorState` per `EditorView`. Quagmire keeps
the transition machinery internal and exposes the stable read-only projections
a sibling host UI can use:

```swift
@Observable @MainActor
public final class EditorState {
    public init()
    public var selection: Set<BlockID> { get }
    public var anchor: BlockID? { get }
    public var cursor: BlockID? { get }
    public var editingBlock: BlockID? { get }
    public func appendBlocks(
        _ blocks: [Block],
        actionName: String = "Insert Blocks"
    )
}
```

`selection`, `anchor`, `cursor`, and `editingBlock` are computed views of the
internal editing state. Hover, menus, drop targets, expanded containers, and
gesture transitions are intentionally package-private implementation details.
This keeps hosts from constructing invalid transition combinations.

**`appendBlocks(_:actionName:)`** is the one externally-mutating method
exposed to hosts: a buffered append that the editor consumes via an
`.onChange` ticket. Used for things like a voice-transcription pipeline
where the host wants to append new content while honoring undo.

---

## Host protocol

Hosts conform to `EditorHost` (class-bound, `@MainActor`). Each method
is one extension point. Only `persistCommit` and `flush` are mandatory — but
the rest are not defaulted on `EditorHost` itself, so a host declares which
surfaces it does without. See "Opting out of a surface".

### Opting out of a surface

The defaults live on opt-in marker protocols rather than on `EditorHost`:

| Marker | Opts out of |
|---|---|
| `DocumentLinksUnsupported` | reference rows, `@`-mentions, lookup, create, inline, append, icons |
| `MoveDestinationUnsupported` | the "Move to…" picker |
| `NavigationUnsupported` | `navigateBack` |
| `ImagesUnsupported` | pasted-image storage and image resolution |
| `LinkPreviewsUnsupported` | favicon/title fetching for external links |
| `BlockActionsUnsupported` | host-supplied block-menu actions |

`EditorHostDefaults` composes all six, for a host that only persists.

This is deliberate, and the reason is worth stating plainly. If the defaults sat
in `extension EditorHost`, conformance would always succeed and there would be
nothing left for the compiler to check — a host that mistyped one signature
would get an *overload* rather than an override, the default would silently win,
and that feature would quietly do nothing with a clean build. During this
package's own development an entire twenty-method host stopped conforming that
way and the app still built.

With the defaults behind markers, everything a host claims is checked, and a
near miss produces the diagnostic you want rather than a mystery:

```
error: type 'MyHost' does not conform to protocol 'EditorHost'
note: candidate has non-matching type '(String) -> DocumentLookup'
```

Prefer the individual markers over `EditorHostDefaults` as soon as the host
implements anything: the composed alias opts out of *everything*, so it would
also swallow a typo in a method you did mean to provide.

The pasteboard codec is the exception and stays on `EditorHost`. Unlike the
rest, its defaults do real work — a line-per-block plain-text codec — rather
than declining to, so a mistyped override still leaves copy and paste working
and there is nothing for a marker to protect.

| Method | Supplied by | Default |
|--------|-------------|---------|
| `persistCommit` | Required | None; the host must explicitly own persistence. |
| `flush` | Required | None; durability may never be silently weakened. |
| `supportsDocumentCreation` | `DocumentLinksUnsupported` | `false`; hides Turn Into → Page and Cmd-K page creation. |
| `supportsDocumentInlining` | `DocumentLinksUnsupported` | `false`; hides non-page conversions for document-link rows. |
| `supportsMoveDestinationPicker` | `MoveDestinationUnsupported` | `false`; hides the "Move to" action. |
| `suggestDocuments` | `DocumentLinksUnsupported` | `[]` |
| `openDocument` | `DocumentLinksUnsupported` | No-op |
| `setDocumentIcon` | `DocumentLinksUnsupported` | `false` |
| `lookupDocument` | `DocumentLinksUnsupported` | `.missing` |
| `didDeleteDocumentLink` | `DocumentLinksUnsupported` | No-op |
| `resolveReference` | `DocumentLinksUnsupported` | `nil` |
| `linkURL` | `DocumentLinksUnsupported` | `nil` |
| `createDocument` | `DocumentLinksUnsupported` | `nil` |
| `loadDocumentBlocks` | `DocumentLinksUnsupported` | `nil` |
| `inlineAndRetireDocument` | `DocumentLinksUnsupported` | `false` |
| `appendToDocument` | `DocumentLinksUnsupported` | `false` |
| `moveDestination` | `MoveDestinationUnsupported` | `nil` |
| `navigateBack` | `NavigationUnsupported` | No-op |
| `serializeBlocksForPasteboard` | always available | Plain text in visible tree order, one block per line. |
| `parseBlocksFromPasteboard` | always available | Nonblank plain-text lines become paragraph blocks; blank input returns `nil`. |
| `saveImages` | `ImagesUnsupported` | `[]` |
| `linkPreview` | `LinkPreviewsUnsupported` | `nil` |
| `imageURL` | `ImagesUnsupported` | `nil` |
| `blockActions` | `BlockActionsUnsupported` | `[]` |

| Method | Signature | When it fires | Return semantics |
|--------|-----------|---------------|------------------|
| `suggestDocuments` | `(_ query: String, in: Document) async -> [MentionItem]` | Once per @-mention trigger change, in a task the next keystroke cancels. May be slow — the menu stays up showing the previous query's rows while it runs. | Up to 8 items shown; host owns ranking/filtering. Results are discarded if the query moved on. Empty array shows "No matching pages", but only once the search has finished. |
| `lookupDocument` | `(_ reference: DocumentReference) -> DocumentLookup` | While building any row that references a target. **Must be a cheap synchronous read** — see "Resolving reference targets" below. | `.present` renders normally and enables the affordances its `capabilities` allow; `.pending` renders with the block's stored label and offers nothing; `.unavailable` renders muted; `.missing` renders broken-link style. |
| `resolveReference` | `(_ url: URL, in: Document) -> DocumentReference?` | Classifies an inline-link URL as a reference to a document it owns. Called at render time for every inline `[text](url)` link (to decide internal-vs-external decoration), at Cmd-K-on-link time (to decide document-creation vs link-toggling), and at the `OpenURLAction` interceptor (to decide internal-nav vs `.systemAction`). One classifier governs all three sites. | Return the host's `DocumentReference` for the URL, or nil for external/unrelated URLs. Host owns the storage convention (file path, UUID, etc.) — the editor never inspects URL contents. |
| `openDocument` | `(_ reference: DocumentReference) -> Void` | User taps a document-link row, or clicks an inline `[text](url)` link the editor already classified as internal via `resolveReference`. | Host pushes the document on its navigation stack. External URLs never reach this method — the OpenURLAction site routes them to `.systemAction`. |
| `createDocument` | `(title: String, requestedReference: DocumentReference?, initialContent: [Block]?) async -> DocumentReference?` | Cmd-K on a paragraph that's a single link, or Turn Into → Document (the @-mention flow never creates documents). `initialContent` is the source block's tree-descendants when present. `requestedReference` is non-nil when the editor has a specific target in mind (redo, or Cmd-K on a link that already names one). | Host persists a new document (prepending a title heading + serializing `initialContent`) and returns its reference, or nil if creation failed (editor treats the action as a no-op — do not synthesize a fake reference). |
| `loadDocumentBlocks` | `(_ reference: DocumentReference) async -> [Block]?` | First step of Turn Into another block kind on a document-link row. Async so the host can read off MainActor. Paired with `inlineAndRetireDocument(_:)`. | Host returns the target document's blocks. nil makes the action a no-op. |
| `inlineAndRetireDocument` | `(_ reference: DocumentReference, parent: Document) async -> Bool` | Second step of Turn Into another block kind on a document-link row: after the editor inlined the loaded blocks into the parent, ask the host to flush the parent and retire the source. Async so the parent's save lands before the source goes away. | true = source retired; false = abort (editor surfaces an orphan warning). |
| `appendToDocument` | `(_ reference: DocumentReference, _ blocks: [Block]) async -> Bool` | User drops blocks onto a document-link row. Async so the host can sequence log-then-file durability before returning. | true = host wrote them (proceed with local removal). false = no-op. |
| `moveDestination` | `(for blockIDs: [BlockID], candidates: [InDocMoveTarget]) async -> MoveDestination?` | "Move To" picker. Editor supplies pre-filtered legal in-doc candidates; host merges with its own document list, presents UI, returns the user's `MoveDestination` (`.document` or `.block`) or nil to cancel. | Async — editor `await`s the picker result at the call site. |
| `navigateBack` | `() -> Void` | Cmd-[ in nav mode (or Cmd-[ in edit mode — that path commits live text first). | Host pops its navigation stack. |
| `persistCommit` | `(changes: [DocumentChange], in: Document) -> Void` | Once per `Document.transaction` (the unified mutation entry point): structural edits via `EditorView.mutate(_:_:)`, typing commits via `BlockTextEditor.Coordinator.commitLiveText`, autotransforms, paste, move-to, and undo/redo all funnel through it. Called *synchronously* on the mutation-commit thread (the editor can't await mid-transaction). `changes` carries removed and inserted block snapshots plus stable-child parent-reference updates; it contains no storage hashes or journal operations. On undo the semantic before/after snapshots are inverted. Empty changes means a pure reorder/move — the host should still persist the new tree shape. | Host should treat the call as its unit of save, translating semantic snapshots into whatever persistence model it owns. The host typically schedules async work internally and awaits it via `flush(_:)`; the editor's sync hook stays synchronous. |
| `flush` | `(_ document: Document) async -> Void` | Editor loses focus (window/key/scene transitions, document switch). Host also calls it directly from scene-phase / navigation paths. Async so callers can await durability where it matters. | Host should force-save the current document. |
| `serializeBlocksForPasteboard` | `(_ blocks: [Block]) -> String` | User cuts or copies. | Host returns a string for the system pasteboard (markdown, RTF, plain — host's choice). Empty string cancels the copy. |
| `parseBlocksFromPasteboard` | `(_ string: String) -> [Block]?` | User pastes. | Host returns blocks parsed from the pasteboard string. nil cancels the paste. |
| `saveImages` | `(_ items: [PastedImage]) -> [String]` | User pastes one or more images (or image URLs from another app). | Host writes them to disk; returns relative paths suitable for `BlockKind.image.source`. Empty / shorter array cancels the paste. |
| `linkPreview` | `(for url: URL) async -> LinkPreview?` | Editor calls this once per external `http`/`https` link in a rendered (read-only) row to fetch favicon + page title. Async; nil → no preview rendered. | Host returns metadata for the URL, or nil on fetch failure / known-failed state. |
| `imageURL` | `(for source: String) -> URL?` | Resolve an image block's `source` (markdown path like `Assets/foo.png`) to a file URL the renderer can load. | nil → renderer shows a missing-image placeholder. |
| `blockActions` | `(in document: Document) -> [EditorBlockAction]` | The block-action surface is rendered or a focused host command checks/invokes an action id. | Empty hides host actions. Each action decides applicability and returns proposed replacements; the editor owns validation, mutation, progress, success, and errors. |

---

## Hosting requirements

- **iOS 26 / macOS 26 minimum.** Uses `TextEditor(text: Binding<AttributedString>)`
  on iOS, NSViewRepresentable wrapping NSTextView on macOS.
- **System fonts by default.** Supply an `EditorTheme` with a registered custom
  family when the host needs branded typography. Palette, type sizes, and
  load-bearing layout metrics are also explicit theme values.
- **Feedback is host policy.** Audio and haptics default off. Enable them with
  `EditorConfiguration`; bundled sound resources remain package-owned.
- **Logging uses the host bundle identifier by default.** A host can override
  the subsystem through `EditorConfiguration.loggingSubsystem`.
- **Single multiplatform targets work fine.** `#if os(iOS)`
  / `#if os(macOS)` guards the platform-specific bits inside the package.
- **swift-tools 6.2** in the consumer's `Package.swift` (or modern Xcode
  project). Editor uses `swiftLanguageModes: [.v6]`.
- **No `UndoManager` provisioning.** `DocumentUndoController` is owned
  internally and recreated implicitly when `EditorView`'s SwiftUI identity
  resets; explicitly cleared on document switch via `.onChange(of:
  document.id)`.

### Actor and threading expectations

- `Document`, `EditorState`, `EditorView`, and `EditorHost` are main-actor
  APIs. Construct them and call their methods from `@MainActor` code.
- `persistCommit` is synchronous because it runs at the document mutation
  boundary. A host that performs asynchronous I/O should enqueue that work and
  make `flush(_:)` await everything already queued for the document.
- Async host hooks may suspend while doing storage or network work, but their
  protocol entry and result handling remain main-actor isolated.
- Value snapshots such as `Block`, `BlockID`, and `DocumentChange` are
  `Sendable`, so a host can copy the values it needs into its own background
  persistence task without passing the observable document object across
  actors.

---

## What the editor doesn't do

- **No file I/O, no markdown parsing/serialization, no recovery/trash.**
  The host owns its store, wire format, journal, and deletion policy.
- **No multi-page navigation.** The editor is single-page; the host
  manages the navigation stack and pushes/pops in response to
  `openDocument(_:)` / `navigateBack()`.
- **No sidebar, no @-mention list source, no history UI, no trash UI.**
  The host owns these surfaces.

---

## Tests

```sh
swift test
./scripts/verify.sh
```

`swift test` runs the internal behavior suite, the bundled-resource smoke test,
and a separate public-consumer target that uses a normal `import Quagmire` and
implements only `persistCommit` and `flush`. The verification script starts
from a clean package build, runs those tests, and then performs clean macOS and
iOS Simulator builds.

## Versioning

Quagmire follows Semantic Versioning. Before `1.0.0`, minor releases may refine
the public API and exact-version dependencies are recommended for production
consumers. Patch releases should remain source-compatible within their minor
line. `1.0.0` will be an explicit compatibility commitment after the host
boundary has been exercised outside Hunch.

The package manifest uses compatible dependency requirements so downstream
consumers can resolve one coherent graph. This library intentionally does not
track `Package.resolved`; verification records the version SwiftPM actually
selected.
