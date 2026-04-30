# Console — Codex working notes

A native iOS 26 + macOS 26 markdown editor. Each block is its own row in a
SwiftUI VStack — sidesteps the hardest problems of Notion-style editors
(cross-block selection, cursor merge across types, hover-only floating UI
that doesn't translate to touch). Source of truth: plain `.md` files in a
user-picked workspace folder.

## Repo shape

- `Packages/Core/` — pure-Swift SPM. Model, swift-markdown parser/serializer,
  `NSFileCoordinator` storage, `DocumentSaveCoordinator` actor (per-URL
  serial, snapshot-coalescing). No SwiftUI imports. Tests live here.
- `Packages/UI/` — SwiftUI SPM. `BlockTextEditor` (NSTextView wrapper on
  macOS, plain TextEditor on iOS), `PageView`, `BlockRow`. Typography in
  `NotionStyle.swift` + `BlockSpacing.swift`. Depends on Core.
- `App/` — single multiplatform Xcode target. `ConsoleApp`/`ContentView` +
  Inter font registration.
- `project.yml` — XcodeGen spec. **Don't hand-edit the `.xcodeproj`** —
  it's generated, gitignored, overwritten by `xcodegen generate`.
- `References/typography/` — real Notion screenshots; see its README.
- `skills/`, `tasks/`, `docs/` — per-project Codex skills, unordered
  upcoming task notes, and accumulated working notes.

## Build & test

```sh
swift test --package-path Packages/Core
xcodegen generate --spec project.yml --project .
xcodebuild -project Hunch.xcodeproj -scheme Hunch -destination 'platform=macOS' -configuration Debug build
xcodebuild -project Hunch.xcodeproj -scheme Hunch -destination 'generic/platform=iOS Simulator' -configuration Debug build
./scripts/run.sh   # macOS — kills any running Hunch.app, launches the newest build
```

Use the `Hunch` scheme for macOS builds. Its build post-action copies the
newest macOS build to `~/Applications/Hunch.app`; prefer that path whenever
the user asks for a build they can run. If that copy ever stops happening,
check that the post-action is under `schemes.Hunch.build.postActions` in
`project.yml`, then regenerate the project with XcodeGen.

## Architecture you need to know to make changes

**One editor at a time.** Blocks render as read-only `Text` until
`editingBlock == block.id`; that row swaps in `BlockTextEditor`. N
simultaneous TextEditors are a focus-arbitration footgun on macOS — don't
go back to that.

**Nav mode is multi-select.** `PageView` holds `selection: Set<BlockID>`,
`cursor` (moving end), `anchor` (fixed end). ↑/↓ collapses to a single
block, Shift+↑/↓ extends, Return enters edit mode (only when
`selection.count == 1`), Esc exits, Delete removes the selection,
Option+↑/↓ slides, Tab/Shift-Tab indent/outdent list items in the
selection.

**Editor binding is `Binding<AttributedString>`** so inline marks
(bold/italic/code/strike/link) round-trip through edits.
`InlineMarksNSKit` (UI, macOS) bridges between the model's custom typed
`AttributedStringKey`s and `NSTextStorage`. Bold/italic/code are derived
from font symbolic traits on round-trip back, because that's what
NSTextView mutates during edits. Cmd-B/I/E/Shift-S toggle marks on the
selection.

**Markdown autotransforms.** Pure detection in
`Packages/Core/Sources/Core/Markdown/Autotransforms.swift`; replacement
blocks via `BlockTransform.apply(to:)`; spliced into the document by
`PageView.applyAutotransform`. Prefix triggers (`# `, `## `, `### `, `- `,
`* `, `1. `, `[] `, `[ ] `, `> ` for toggle, `" ` for quote) fire from
the coordinator's `textDidChange` (IME-marked-text guarded) before the
binding propagates. Enter triggers (`---`, ` ``` `) fire from
`splitBlock` when the row's tail is empty. The `" ` detector accepts
both `"` and `\u{201C}` — NSTextView's smart-quote substitution runs by
default.

**Click-to-position cursor.** A `SpatialTapGesture` on the read-only
`Text` captures the click point in editor-local coords (which doubles as
NSTextView local coords because the editor mounts in the same HStack
slot). `MacBlockTextEditor.applyPendingCursorPositionOrSeekToEnd` calls
`characterIndexForInsertion(at:)` after the focus grab. Clicks on
non-text parts (markers, paddings) fall through to the row's
`.onTapGesture` and seek-to-end.

**Up/Down at editor boundary exits edit mode.**
`cursorIsOnFirstLine()` / `cursorIsOnLastLine()` consult NSLayoutManager
so wrapped paragraphs still allow intra-block arrow nav in the middle.

**Autosave fans into `DocumentSaveCoordinator`** (Core actor, per-URL
in-flight + pending-snapshot coalesce). Triggers: 600ms debounce, blur,
`scenePhase != .active`, 30s backstop. `flushAndClose()` waits on
pending writes at document switch / app suspend.

## macOS NSTextView footguns (load-bearing)

Stock `TextEditor` on macOS bakes in `textContainerInset = (5, 0)` and
`lineFragmentPadding = 5`, breaking `firstTextBaseline` alignment with
list markers. `MacBlockTextEditor` wraps NSTextView directly, zeros
both, and adds `.alignmentGuide(.firstTextBaseline) { _ in
nsFont.ascender }`.

Three load-bearing focus details:

1. `MacBlockTextEditor` is constructed with `isFocused: true`
   unconditionally. `@FocusState` writes from `enterEditMode` are
   deferred and don't propagate before `makeNSView` /
   `viewDidMoveToWindow` fire.
2. `cancelOperation(_:)` is overridden to fire the `.escape` handler AND
   to call `window?.makeFirstResponder(nil)` first — without this,
   SwiftUI can't re-bind the page container after the editor unmounts,
   and arrow nav breaks post-Esc.
3. `exitEditMode` toggles `pageFocused = false` then `true` on the next
   runloop tick. A same-value setter is a no-op in SwiftUI focus state.

`.onKeyPress` on macOS doesn't reliably intercept keys NSTextView
consumes. Override `keyDown(_:)` on a custom NSTextView subclass instead
— see `ContainedTextView`.

## Project-level constraints

- **iOS 26 / macOS 26 minimum.** Unlocks
  `TextEditor(text: Binding<AttributedString>)` natively on iOS; macOS
  uses NSViewRepresentable for tight control over insets.
- **Single multiplatform target**, not two. `#if os(iOS)` / `#if
  os(macOS)` for the divergent bits.
- **swift-tools-version 6.2** in both Package.swift files.
- **No code signing** (`CODE_SIGNING_ALLOWED: NO`).
- **swift-markdown is the only third-party dep.** Its
  `MarkupFormatter.format()` normalises surface syntax — accepted; we
  don't try byte-exact preservation.
- **Toggles are encoded as `<details><summary>…</summary>…</details>`**
  HTML blocks. cmark splits these across siblings at blank lines;
  `BlockParser.assemble` stitches them back. If toggles stop
  round-tripping, suspect that pass.

## Notion typography target

Pre-March-2026 Notion. **Don't use `react-notion-x`'s CSS as truth** —
its values diverge from real Notion. Work from the screenshots in
`References/typography/`. Constants live in `NotionStyle.swift` (sizes,
colors, fonts) and `BlockSpacing.swift` (per-block margins, sibling-aware
gaps). Don't sprinkle magic numbers into `BlockRendering.swift`.

## Debugging UI runtime issues

```sh
pkill -f Console.app
/Users/joe/Library/Developer/Xcode/DerivedData/Console-*/Build/Products/Debug/Console.app/Contents/MacOS/Console > /tmp/console.log 2>&1 &
tail -f /tmp/console.log
```

Sprinkle `print("[CLI] ...")` at suspect transitions (state setters,
focus changes, key handlers, lifecycle hooks). Strip them before
committing: `grep -rn '\[CLI\]' Packages/UI App`. `print()` may buffer
when stdout isn't a tty — use `NSLog` (visible via `log show --predicate
'process == "Console"' --last 2m`) for real-time.

Xcode tools that earn their keep:
- **Accessibility Inspector** — what's hit-testable at a point; useful
  when a parent gesture is silently eating taps.
- **View Debugger** — overlapping frames, wrong z-order, hidden views.
  Requires running under Xcode (not the standalone binary).

## Style preferences

- The user is a senior engineer — don't over-explain.
- Prefer editing existing files over adding new ones.
- Comments explain *why*, never *what*. Skip them when the code is clear.
- Don't add CHANGELOG.md, TROUBLESHOOTING.md, etc. unless asked.
- Keep `swift test --package-path Packages/Core` green before committing
  UI changes — the parser/serializer is the load-bearing core.
