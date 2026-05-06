# Classified-list primitive

## Context

Add a "poor man's database" to Hunch: a bulleted list whose rows can be tagged from a controlled vocabulary. The vocabulary defines fields (e.g. `rating: ⭐, ⭐⭐, ⭐⭐⭐`, `type: animal, vegetable, mineral`) and each row in the list can carry up to one value per field. Tags render as trailing chips on each row, edited via a popover.

The whole thing — vocabulary plus rows — is **one container** in both the model and on disk. The vocabulary lives *inside* the container as nested bullets (field at indent+1, values at indent+2), so the user edits vocab with the exact same UI as the rest of the list (pinch-to-insert, indent/outdent, type to edit). A divider separates the vocab section from the rows.

v1 scope: add/edit/remove tags only — no filter, sort, or group views.

User-confirmed: list-scoped vocabulary; trailing-chip rendering; one container, not two peer blocks; vocabulary editable as normal nested bullets; no autotransform.

## Design

### Model — two new `Block` cases

In [Block.swift](Packages/Editor/Sources/Editor/Model/Block.swift):

```swift
case classifiedList(id: BlockID = BlockID(), indent: Int = 0)
case classifiedRow(id: BlockID = BlockID(), text: AttributedString, tags: [TagAssignment], indent: Int = 0)

public struct TagAssignment: Equatable, Sendable, Hashable {
    public var fieldKey: String     // e.g. "rating"
    public var value: String        // e.g. "⭐⭐"
}
```

`classifiedList` is a container header — it "owns" the blocks at `indent+1` below it (toggle-style indent encoding, exactly like `Block.toggle`). It carries no own text or fields: the vocabulary is **stored as nested bullets in the body**, not as structured data on the container. This is what makes "edit vocab like a list" trivially work.

`classifiedRow` is a single data row — like a bullet, plus a `tags` array. It exists separately from `bullet` so chip rendering and the tag picker can operate on structured data without hiding raw `#field:value` text in the live text editor.

Update the six switches in `Block.swift` (`id`, `indent`, `text`, `withText`, `withIndent`, `withFreshID`).

### Container body shape

Inside a `classifiedList` body (siblings at `containerIndent+1`):

1. **Vocabulary section** — regular `bullet` blocks. Top-level body bullets (at `containerIndent+1`) are field names. Their sub-bullets (at `containerIndent+2`) are the allowed values. **No new Block kind**: vocab uses ordinary nested bullets, edited with the existing list UI.
2. **Separator** — a single `divider` block (existing `---`) at `containerIndent+1`.
3. **Rows section** — `classifiedRow` blocks at `containerIndent+1`. Each carries its body text plus structured `tags`.

Storage example for a Document.blocks slice:

```
classifiedList                       (indent 0)
  bullet "rating"                    (indent 1)
    bullet "⭐"                      (indent 2)
    bullet "⭐⭐"                    (indent 2)
    bullet "⭐⭐⭐"                  (indent 2)
  bullet "type"                      (indent 1)
    bullet "animal"                  (indent 2)
    bullet "vegetable"               (indent 2)
    bullet "mineral"                 (indent 2)
  divider                            (indent 1)
  classifiedRow "Bear" tags=[type:animal, rating:⭐⭐]   (indent 1)
  classifiedRow "Carrot" tags=[type:vegetable]          (indent 1)
```

### Markdown — one fenced container

Reuse the `:::label` fence machinery in [parseTemplateContainers](App/Sources/Clamshell/Parser.swift:156). Add a `:::list` arm. Body is regular markdown (bullets, sub-bullets, divider, more bullets); the fence is the only thing tying them together.

```
:::list
- rating
  - ⭐
  - ⭐⭐
  - ⭐⭐⭐
- type
  - animal
  - vegetable
  - mineral
---
- Bear #type:animal #rating:⭐⭐
- Carrot #type:vegetable
:::
```

This is **one markdown block** — the fence — even though its body contains nested lists. It round-trips cleanly through cmark-gfm because everything inside is plain markdown.

**Tag-suffix rule (parser, applied to bullets in the rows section):** scan from the end of the bullet's text for a contiguous run of whitespace-separated `#[A-Za-z_][A-Za-z0-9_-]*:[^\s#]+` tokens, **stopping at the first whitespace-bounded token that doesn't match**. Only split if at least one token's `fieldKey` matches a field defined in the container's vocab. Rows of the form `- Issue #42 in repo #type:bug` correctly split only `#type:bug`.

**Serializer:** strip `tags` from `classifiedRow.text`, append `" "` + `#k:v` tokens **in vocab field order** (stable diffs). v1: reject tag values containing `#` or whitespace at vocab-edit time; defer escaping.

### Parser — fence arm + body interpretation

In [Parser.swift](App/Sources/Clamshell/Parser.swift), add a `:::list` arm next to `:::template-button` in `parseTemplateContainers`. The body is parsed recursively as markdown into `[Block]`. Then a small post-pass interprets the body:

1. Walk body blocks at `containerIndent+1`.
2. Up to the first `divider`: those bullets (and their indent+2 sub-bullet values) are the vocabulary.
3. The `divider` itself stays in the model as a real `divider` block (rendered as a thin horizontal line — see "rendering" below).
4. After the divider: every `bullet` at `containerIndent+1` becomes a `classifiedRow`, with trailing `#field:value` tags split off into the structured `tags` array (validated against the parsed vocab).

Add to [Document.swift](Packages/Editor/Sources/Editor/Model/Document.swift): a `vocab(forRow rowID:) -> [VocabField]?` helper that walks back from a `classifiedRow` to its parent `classifiedList` and reads the vocab by walking forward through the body's pre-divider bullets. Renderer + tag picker call this. `VocabField` is a derived value (`{key: String, values: [String]}`), not stored on the container.

### Serializer

In [Serializer.swift](App/Sources/Clamshell/Serializer.swift), `classifiedList` is a container that "owns" its body, exactly like `templateButton` does today (lines 19–44). Emit `:::list` + `\n`, then serialize body blocks (dedented to relative indent), then `:::`. The body emission uses the existing per-block serialization for bullets/dividers, plus a new arm for `classifiedRow` (bullet line with appended `#k:v` tokens in field order).

### Rendering

Add to the switch in [BlockRow.swift](Packages/Editor/Sources/Editor/BlockRow.swift):

- `classifiedListRow(indent:)` — a small "List" header pill at `containerIndent`. Compact, no editable text. Works like the templateButton header — just a visual marker that something below it is owned.
- `classifiedRow(text:, tags:, indent:)` — same structure as `bulletRow` (bullet circle + editable text), with **trailing chips inside the same `HStack(alignment: .firstTextBaseline)`** so vertical alignment doesn't drift on wrap. Layout: `circle | editableText | Spacer(minLength: 8) | chips`. Chips need an `.alignmentGuide(.firstTextBaseline)` matching the bullet marker's offset — mirror the existing `bulletMarkerBaselineOffset` pattern. **This is the trickiest piece of UI.** Chip styling: small rounded-rect pill, color-coded per field key (hash → palette).

Vocab bullets in the body render as **completely normal bullets** — no special treatment. The user reads "rating" and its child "⭐", "⭐⭐", "⭐⭐⭐" exactly as nested list items. The chip palette is implicit from the structure.

The divider in the body renders as the existing thin horizontal line — visually marks the vocab/rows boundary inside the container.

### Tag picker overlay

Promote to a new `Overlay` variant in [EditorState.swift](Packages/Editor/Sources/Editor/EditorState.swift) — **not** ambient state. Mirrors `MentionMenuState` exactly (it's the same "modal popover anchored to a block" pattern).

```swift
public enum Overlay: Equatable, Sendable {
    case mention(MentionMenuState)
    case tagPicker(TagPickerState)
}

public struct TagPickerState: Equatable, Sendable {
    public let blockID: BlockID
    public var fieldKey: String?     // nil = field list; set = value list for that field
    public var query: String
    public var selectedIndex: Int
}
```

Opening the picker (chip-area click on a `classifiedRow`, or hotkey on a selected one) **enters edit mode on the row** with `overlay: .tagPicker(...)`. Cursor parks at end-of-text. Esc closes the popover but stays in edit mode (matches mention behaviour). Add `setTagPicker(_:)` / `closeTagPicker()` next to the existing mention transitions.

### Document maintenance — normalize on every structural mutation

Edge cases the in-editor flow must handle, all funneled through one helper `Document.normalizeClassifiedScopes()` called after every structural mutation (insert/delete/move/drop):

1. **Drag a `classifiedRow` out of its container** → convert to `bullet`, restoring `#field:value` text suffix from `tags`.
2. **Drag a `bullet` into the rows section of a container** → convert to `classifiedRow` (split trailing tags from text against the container's vocab).
3. **Insert a new bullet at end of the rows section** → becomes `classifiedRow` with empty tags.
4. **Delete the divider** → all subsequent rows become vocab bullets (or vice-versa) — edge case; the user fix is to add another divider.
5. **Delete the `classifiedList` container** → all body blocks orphan. The classifiedRows become regular bullets with their `#field:value` text restored.
6. **A row's tag references a field that no longer exists in the vocab** → keep the tag in the model on round-trip; the chip renders in a "muted/unknown" style. The user can remove it via the picker.

The same logic runs at parse time (matches the disk → model conversion) and in the editor on every mutation. One helper, idempotent.

### Creation surface — deferred

No autotransform. v1 doesn't specify an entry point in this plan; the next iteration adds it via the existing "Turn into" menu (see [EditorView+TurnInto.swift](Packages/Editor/Sources/Editor/EditorView+TurnInto.swift)) — "Turn into → Classified list" wraps the current block in a `classifiedList` container with an empty vocab and one empty row.

## Files

**Touched:**
- [Packages/Editor/Sources/Editor/Model/Block.swift](Packages/Editor/Sources/Editor/Model/Block.swift) — two cases, `TagAssignment`, six switches.
- [Packages/Editor/Sources/Editor/Model/Document.swift](Packages/Editor/Sources/Editor/Model/Document.swift) — `vocab(forRow:)`, `normalizeClassifiedScopes()`.
- [Packages/Editor/Sources/Editor/EditorState.swift](Packages/Editor/Sources/Editor/EditorState.swift) — `Overlay.tagPicker`, `TagPickerState`, transitions.
- [Packages/Editor/Sources/Editor/BlockRow.swift](Packages/Editor/Sources/Editor/BlockRow.swift) — `classifiedListRow`, `classifiedRow`, switch update.
- [Packages/Editor/Sources/Editor/EditorView.swift](Packages/Editor/Sources/Editor/EditorView.swift) — popover wiring (mirror the mention pattern); hook `normalizeClassifiedScopes` into mutation paths.
- [Packages/Editor/Sources/Editor/NotionStyle.swift](Packages/Editor/Sources/Editor/NotionStyle.swift) — chip styling, container header dimensions.
- [App/Sources/Clamshell/Parser.swift](App/Sources/Clamshell/Parser.swift) — `:::list` arm in `parseTemplateContainers`; body post-pass that splits vocab/rows at the divider and converts trailing-tag bullets to `classifiedRow`.
- [App/Sources/Clamshell/Serializer.swift](App/Sources/Clamshell/Serializer.swift) — `:::list` fence emission with body lookahead-consume (like `templateButton`); `classifiedRow` line emission with stable tag ordering.

**New:**
- `Packages/Editor/Sources/Editor/EditorView+TagPicker.swift` — picker logic, `tagPickerContent` view, mirrors [EditorView+Mention.swift](Packages/Editor/Sources/Editor/EditorView+Mention.swift).

**Reuse:**
- Fence open/close from `parseTemplateOpen` / `findTemplateClose` in Parser.swift.
- Body lookahead-consume pattern from `templateButton` serialization.
- `MentionItem` filtering pattern from EditorView+Mention.swift.
- `blockActionPopover` from EditorView+Gestures.swift.

## Implementation order

Two-session split:

**Session 1 — model + round-trip green:**
1. `Block.swift`: two cases, `TagAssignment`, six switches.
2. `Document.swift`: `vocab(forRow:)`, `normalizeClassifiedScopes()`.
3. `Parser.swift`: `:::list` arm + body post-pass.
4. `Serializer.swift`: `:::list` fence + `classifiedRow` emission.
5. Round-trip tests in [App/Tests/HunchUnitTests/](App/Tests/HunchUnitTests/).

**Session 2 — UI:**
6. `BlockRow.swift`: `classifiedListRow`, `classifiedRow` (chip alignment is the load-bearing detail).
7. `EditorState.swift`: `Overlay.tagPicker` + transitions.
8. `EditorView+TagPicker.swift`: picker view, keyboard nav, commit/cancel.
9. Wire `normalizeClassifiedScopes()` into structural mutation paths (insert/delete/move/drop).

## Verification

```sh
swift test --package-path Packages/Editor
xcodebuild test -project Hunch.xcodeproj -scheme Hunch \
    -destination 'platform=macOS' -only-testing:HunchUnitTests
xcodegen generate --spec project.yml --project .
xcodebuild -project Hunch.xcodeproj -scheme Hunch \
    -destination 'platform=macOS' -configuration Debug build
./scripts/run.sh
```

Manual end-to-end on macOS — for v1, manually construct a test `.md` with the format above and verify it renders correctly:

1. Place a `:::list` fence file in the workspace, populated with sample fields and rows. Open it.
2. Verify: container header pill renders. Vocab section shows nested bullets exactly as authored. Divider renders as a thin line. Rows render as bullets with chips trailing the text. Chip colors are consistent per field.
3. Edit a row's text — chips stay attached, text edits normally.
4. Pinch-insert a new bullet in the vocab section — appears as a regular bullet, indent/outdent works, sub-bullets work.
5. Click a chip on a row → tag picker popover opens with the row's vocab. Pick a different value → chip updates. Esc closes picker, stays in edit mode.
6. Save (blur or 30s backstop). Open the `.md` in any text editor — verify format matches the spec exactly, tag tokens in field order.
7. Quit and relaunch Hunch. Verify lossless round-trip.
8. Edge cases: drag a `classifiedRow` out of the container (becomes plain bullet, tags become trailing `#k:v` text). Drag back in (tags split off, chips reappear). Delete the `classifiedList` container (all rows convert to plain bullets with `#k:v` text preserved). Type `Issue #42 #type:animal` in a row — only `#type:animal` should chip.

## Risks

- **firstTextBaseline + chips inside the wrap-aware HStack** is the single most likely-to-look-wrong piece of UI. Test with rows that wrap, rows with no text, rows with no tags. Match the bullet marker's baseline guide exactly.
- **Drag-reorder normalization** must run on every structural mutation path. Funneling through one helper called from `applyDrop`/`splitBlock`/`mergeBlock`/`moveSections` is the cheap, correct answer.
- **Tag-suffix scan** must be tested against rows whose text contains `#` characters. The trailing-run-with-vocab-key gate is the load-bearing rule.
- **Stable tag ordering** on serialize: two semantically-identical rows must produce byte-identical lines.
- **Vocab as nested bullets** means a free-form structure inside the container — any deformation (e.g. user types a paragraph in the vocab section) must degrade gracefully. Renderer treats non-bullet pre-divider blocks as no-op for vocab purposes; they still render as themselves.
