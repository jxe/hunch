# Doc model: universal indent + section-aware operations

## Context

Today the document is a flat `[Block]` array, but only `.bullet`,
`.numbered`, `.todo` carry an `indent: Int` (0–5). All other block kinds
behave as if indent = 0 with no way to nest them under a list item.

Two consequences the user wants to fix:

1. **A block's indented section doesn't travel with it.** Moving,
   indenting, or deleting a list-item parent strands the indented
   descendants. The user expects "section travels as one unit" for
   keyboard, drag, and iOS handle gestures.
2. **Paragraphs (and other block kinds) are legal children.** A
   paragraph indented under a bullet should round-trip and behave as a
   member of that bullet's section. Today it can't carry an indent at
   all.

The fix has two layers — extend the model so every block kind carries
indent, then make the operations section-aware via a new query.

A **section** of `blocks[i]` becomes simple: the contiguous run
`(i+1)..<j` where every block's indent is strictly greater than
`blocks[i].indent`. The first block with `indent <= blocks[i].indent`
terminates.

## Design

### Phase 1 — Universal indent on `Block`

[Packages/Core/Sources/Core/Block.swift](Packages/Core/Sources/Core/Block.swift):
add `indent: Int = 0` to every case.

```swift
case paragraph(id: BlockID = BlockID(), text: AttributedString, indent: Int = 0)
case heading(id: BlockID = BlockID(), level: Int, text: AttributedString, indent: Int = 0)
case bullet(...)            // already has indent
case numbered(...)           // already has indent
case todo(...)               // already has indent
case quote(id: BlockID = BlockID(), text: AttributedString, indent: Int = 0)
case code(id: BlockID = BlockID(), source: String, language: String?, indent: Int = 0)
case divider(id: BlockID = BlockID(), indent: Int = 0)
case toggle(id: BlockID = BlockID(), title: AttributedString, expanded: Bool, children: [Block], indent: Int = 0)
case subpage(id: BlockID = BlockID(), title: String, path: String, indent: Int = 0)
```

Replace the computed `indent` property with a real read of the stored
field. Update [DocumentMutation.swift](Packages/Core/Sources/Core/DocumentMutation.swift)
so `withIndent` and `withText` cover every case (including the cases
that previously returned `self` from `withIndent`).

### Phase 2 — Section helper

Add to [DocumentMutation.swift](Packages/Core/Sources/Core/DocumentMutation.swift):

```swift
extension Document {
    /// `i..<j` where `i` is the block itself and `(i+1)..<j` is its
    /// indented section (contiguous blocks with indent > blocks[i].indent).
    public func sectionRange(of blockID: BlockID) -> Range<Int>?

    /// Union of `sectionRange(of:)` for every id, returned as a sorted,
    /// deduplicated `[Int]` of indices in document order.
    public func indicesIncludingSections(of ids: some Sequence<BlockID>) -> [Int]
}
```

Tests in `Packages/Core/Tests/CoreTests/`:
- empty section (no descendants),
- single descendant,
- mixed indents 1→2→3 then back to 0,
- terminated by sibling at same indent,
- mixed kinds in section (paragraph as child of bullet, quote as child of bullet, bullet as child of paragraph).

### Phase 3 — Markdown round-trip

This is the load-bearing part. Today the serializer/parser only knows
about list-item nesting; with universal indent we need to handle
arbitrary indented blocks.

[Packages/Core/Sources/Core/Markdown/Serializer.swift](Packages/Core/Sources/Core/Markdown/Serializer.swift):

- For a list-item parent followed by indented children, use cmark's
  nested-list-item / continuation-paragraph syntax (4-space indent for
  paragraph/quote/code under a list item). This already works for
  list-item children; extend to non-list-item children.
- For an indented block whose parent is **not** a list item (e.g., an
  indented paragraph after a heading), use 4-space-indent continuation
  syntax — but cmark only honors that inside list contexts. If round-trip
  isn't safe, fall back to emitting with no indent and a TODO comment in
  the source. **Acceptable v1 behavior:** orphan-indented blocks (no
  list-item ancestor) get serialized at indent 0 with a console log; the
  parser still preserves indent during a session, but persisting to disk
  flattens. Document this explicitly.
- Toggle children stay in `<details><summary>` HTML blocks unchanged.

[Packages/Core/Sources/Core/Markdown/Parser.swift](Packages/Core/Sources/Core/Markdown/Parser.swift):

- When walking into a list item's children, propagate the parent's
  indent + 1 to *all* child blocks (not just sub-list-items).
- Continuation paragraphs / quotes / code under a list item already
  parse as children of that list item in cmark — they currently end up
  as flat `paragraph` blocks; tag them with the parent's indent + 1.

Round-trip tests in `Packages/Core/Tests/CoreTests/`:
- bullet with indented paragraph child,
- bullet with indented quote child,
- bullet with indented code child,
- nested bullet with paragraph child of the inner bullet.

### Phase 4 — Rendering

[Packages/UI/Sources/UI/BlockRendering.swift](Packages/UI/Sources/UI/BlockRendering.swift)
and [BlockSpacing.swift](Packages/UI/Sources/UI/BlockSpacing.swift): apply
left padding from `block.indent` uniformly across kinds, not just list
items. Reuse the existing list-item indent metric (`NotionStyle`).

Sanity-check sibling-aware spacing rules still hold when indent levels
mix kinds (e.g., bullet at indent 1 followed by paragraph at indent 1 —
the paragraph should still sit visually inside the same nested column).

### Phase 5 — Operations route through `sectionRange`

[Packages/UI/Sources/UI/PageView.swift](Packages/UI/Sources/UI/PageView.swift):

- **Move (Option+↑/↓)** — `moveSelectionInDocument(by:)` at line 981:
  expand selection to `indicesIncludingSections`, slide min..max range.
- **Drag** — `dragIDs(for:)` at line 543: expand the returned `[BlockID]`
  with descendants. `moveBlocks(ids:toIndexBefore:)` (line 610) and
  `DragPreviewChip` count update automatically. The self-drop-rejection
  check at line 618 still covers drops inside the now-larger range.
- **Indent in nav mode** — `indentSelection(by:)` at line 1062: expand
  via section, validity-gate the delta (apply only if `0 <=
  blocks[k].indent + delta <= 5` for every k in expanded set; else
  no-op the entire op), apply to all kinds (no longer just list items
  since every block has indent).
- **Indent in editor mode** — `changeIndent(_:by:)` at line 1231: same
  shape, single block + descendants, same validity gate.
- **iOS drag-handle tap** — replace `cycleIndent(blockID:)` (line 1045)
  with `indentByOne(blockID:)` that does +1 with descendants following,
  no-op at max. Wraparound 0→1→2→3→0 is gone.
- **Delete** — same expansion applied to:
  - `deleteSelection()` at line 1001 (Delete key in nav mode),
  - `deleteBlocks(ids:actionName:)` at line 1024 (iOS handle "Delete",
    invoked at line 364).

Validity-gate rule, in plain words: *delta is applied only if every
affected block stays in `[0, 5]` after the delta — otherwise the whole
operation is a no-op.* Per-block clamping in `withIndent` stays as a
safety net but never produces a flattened section.

Each call site already wraps in a single `mutate(...)`, so undo stays
atomic — no change there.

## Critical files

- [Packages/Core/Sources/Core/Block.swift](Packages/Core/Sources/Core/Block.swift)
  — extend every case with `indent: Int = 0`.
- [Packages/Core/Sources/Core/DocumentMutation.swift](Packages/Core/Sources/Core/DocumentMutation.swift)
  — `withIndent`/`withText` updates; add `sectionRange`,
  `indicesIncludingSections`.
- [Packages/Core/Sources/Core/Markdown/Parser.swift](Packages/Core/Sources/Core/Markdown/Parser.swift)
  — propagate parent indent to non-list-item children.
- [Packages/Core/Sources/Core/Markdown/Serializer.swift](Packages/Core/Sources/Core/Markdown/Serializer.swift)
  — emit indented non-list-item blocks via 4-space continuation; flag
  orphan-indented as a known v1 limitation.
- [Packages/UI/Sources/UI/BlockRendering.swift](Packages/UI/Sources/UI/BlockRendering.swift),
  [BlockSpacing.swift](Packages/UI/Sources/UI/BlockSpacing.swift) —
  uniform indent padding.
- [Packages/UI/Sources/UI/PageView.swift](Packages/UI/Sources/UI/PageView.swift)
  — six call sites listed above.
- [Packages/UI/Sources/UI/BlockDragPayload.swift](Packages/UI/Sources/UI/BlockDragPayload.swift)
  — no change; `ids` already carries multi-block payloads.

## Verification

Core tests:
```sh
swift test --package-path Packages/Core
```

Round-trip a test fixture with an indented paragraph child of a bullet;
re-parse; confirm indent survives.

macOS build + manual:
```sh
xcodegen generate --spec project.yml --project .
xcodebuild -project Console.xcodeproj -scheme Console \
  -destination 'platform=macOS' -configuration Debug build
./scripts/run.sh
```

On a doc shaped like:

```
- parent          (bullet, indent 0)
  - child A       (bullet, indent 1)
    paragraph     (paragraph, indent 2)  ← new: legal child
  - child B       (bullet, indent 1)
- sibling         (bullet, indent 0)
```

1. Click `parent`, press Option+↓. All four descendants slide with it
   past `sibling`.
2. Press Tab on `parent`. Every section row's indent increments by 1.
   Press Tab again — `paragraph` would hit 6, so the whole op is a
   no-op.
3. Press Shift-Tab on `parent`. Whole section decrements; pressing again
   from indent-0 parent is a no-op.
4. Drag `parent`'s handle. Chip reads "5 blocks". Drop above `sibling`;
   all five land in order, indents preserved.
5. Select `parent`, press Delete. Section gone. Undo restores all five.
6. iOS: tap drag-handle on `parent`. Section indents by 1; at max, tap
   is a no-op (no wraparound).
7. Save the doc, kill the app, re-open. Confirm the `paragraph` at
   indent 2 round-trips.

iOS build sanity:
```sh
xcodebuild -project Console.xcodeproj -scheme Console \
  -destination 'generic/platform=iOS Simulator' -configuration Debug build
```

## Suggested phasing

This is bigger than a single landing change. Recommended split:

- **PR 1**: Phase 1 + 2 (model extension + section helper + tests). No
  user-visible change yet — every existing block sits at indent 0.
  Verify the existing test suite stays green.
- **PR 2**: Phase 3 (parser/serializer round-trip).
- **PR 3**: Phase 4 (rendering).
- **PR 4**: Phase 5 (operations + iOS handle behavior).

Each PR is independently shippable and reviewable.
