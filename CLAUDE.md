# Console — Claude working notes

A native iOS 26 + macOS 26 markdown editor. Each block in a document is its
own row in a SwiftUI `List`, so we sidestep the hardest problems of
Notion-style editors (cross-block selection, cursor merge/split across block
types, floating-UI hover targets that don't translate to touch). Source of
truth is plain `.md` files in a user-picked workspace folder.

## Repo shape

- `Packages/Core/` — pure-Swift SPM package. Model types, swift-markdown
  parser/serializer, `NSFileCoordinator`-backed storage,
  `DocumentSaveCoordinator` actor (per-URL serial, snapshot-coalescing),
  security-scoped bookmark for the workspace folder. No SwiftUI imports.
  Round-trip + mutation + save-coordinator tests live here.
- `Packages/UI/` — SwiftUI SPM package. `NotionStyle` typography constants,
  `BlockSpacing` (sibling-aware gap math), `BlockRow`/`PageView`/
  `PageListView` rendering, `BlockTextEditor` (NSViewRepresentable around
  NSTextView on macOS, plain TextEditor on iOS). Depends on Core.
- `App/` — single multiplatform Xcode app target. `ConsoleApp` (`@main`,
  owns the `WorkspaceModel`, declares `.commands` for Reload Pages /
  Switch Workspace…), `ContentView` (workspace picker → page list →
  page view), `FontRegistration` (Inter Variable via CTFontManager),
  `Resources/Fonts/InterVariable.ttf`.
- `project.yml` — XcodeGen spec. **Don't hand-edit the .xcodeproj** — it's
  generated, ignored by git, and overwritten by `xcodegen generate`.
- `References/typography/` — real Notion screenshots from 2023-2025 used to
  drive M2 typography iteration. See `References/typography/README.md`.
- `skills/` — per-project Claude skills. `m2-typography-iterate` for the
  reference-screenshot diff loop, `ui-debug-loop` for runtime UI debugging.
- `ROADMAP.md` — milestone status and what's next.

## Build & test

```sh
# Run unit tests (Core only — UI doesn't have tests yet)
swift test --package-path Packages/Core

# Regenerate the Xcode project after adding/removing files
xcodegen generate --spec project.yml --project .

# Build for macOS (no code signing required)
xcodebuild -project Console.xcodeproj -scheme Console \
  -destination 'platform=macOS' -configuration Debug build

# Build for iOS Simulator
xcodebuild -project Console.xcodeproj -scheme Console \
  -destination 'generic/platform=iOS Simulator' -configuration Debug build

# Run the macOS app (after build)
open ~/Library/Developer/Xcode/DerivedData/Console-*/Build/Products/Debug/Console.app
```

## Editing architecture (M3+)

- **One editor at a time.** All blocks render as read-only `Text` by default.
  When `editingBlock == block.id`, that single row swaps in a
  `BlockTextEditor`. N simultaneous TextEditors are a focus-arbitration / hit-
  test footgun on macOS — don't go back to that.
- **Two states, on the page level:** `selectedBlock` (highlight, no editor)
  and `editingBlock` (editor mounted, focused). ↑/↓ moves selection, Return
  enters edit mode, click jumps straight to edit. Esc exits edit mode and
  returns to nav (the user's habitual key — keep it that way).
- **macOS `BlockTextEditor` is an NSViewRepresentable around NSTextView**,
  not stock `TextEditor`. Stock TextEditor on macOS bakes in
  `textContainerInset = (5, 0)` and `lineFragmentPadding = 5` which break
  `firstTextBaseline` alignment with list markers. The wrapper zeros both,
  intercepts Return/Tab/Backspace/Esc/Cmd-K via `keyDown(_:)`, and provides
  an explicit `.alignmentGuide(.firstTextBaseline) { _ in nsFont.ascender }`
  so HStack(.firstTextBaseline) lines up.
- **Inline marks are stripped on first edit.** Editor binding is plain
  `String`. Read-only blocks render `**bold**` as bold via `InlineRenderer`,
  but the moment a block is focused and any keystroke goes through, its text
  becomes a plain `AttributedString`. Marks-aware editing (Cmd-B/I) is M5/M6.
- **Autosave fans into `DocumentSaveCoordinator`** (Core actor, per-URL
  in-flight + pending snapshot). Triggers: 600ms debounce after any
  `markEdited()`, blur (focus → nil), `scenePhase != .active`, 30s backstop
  while a doc is open. `flushAndClose()` waits for pending writes on
  document close / app suspend.
- **Code, divider, subpage stay read-only** in M3. Tapping them doesn't
  enter edit mode (subpage navigates).

## Key constraints

- **iOS 26 / macOS 26 minimum.** Unlocks
  `TextEditor(text: Binding<AttributedString>)` natively on iOS; on macOS
  we use NSViewRepresentable for tight control over text-container insets.
- **Single multiplatform target**, not two. `#if os(iOS) / os(macOS)` for the
  few platform-divergent bits.
- **swift-tools-version 6.2** in both Package.swift files (required for
  `.iOS(.v26)` / `.macOS(.v26)`).
- **No code signing** in CI/local builds — `CODE_SIGNING_ALLOWED: NO` in
  project.yml. The user can enable signing in Xcode when shipping.
- **swift-markdown is the only third-party dep.** It's CommonMark + GFM. Its
  `MarkupFormatter.format()` round-trips semantically but normalises surface
  syntax — that's accepted; we don't try to preserve byte-exact formatting.
- **Toggles are encoded as `<details><summary>...</summary>...</details>`
  HTML blocks.** cmark closes an HTML block at a blank line, so a real-world
  toggle parses as multiple sibling AST nodes — `BlockParser.assemble`
  stitches them back into a `.toggle`. If toggles ever stop round-tripping,
  suspect this stitching pass.

## Notion typography reference

The pre-March-2026 Notion typography is the visual target. **Do not use
`react-notion-x`'s CSS as the source of truth — its values diverge from real
Notion in subtle ways.** Instead, work from the screenshots in
`References/typography/`.

Key constants live in `Packages/UI/Sources/UI/NotionStyle.swift` (sizes,
colors, fonts) and `Packages/UI/Sources/UI/BlockSpacing.swift` (per-block
margins/padding, sibling-aware gaps). When tuning, change these and rebuild
— don't sprinkle magic numbers into BlockRendering.

## What's done, what's next

See `ROADMAP.md`. As of the most recent commit:
- **M1** (workspace + read-only render) — done, verified.
- **M2** (Notion typography) — first pass; the user has flagged that it
  doesn't match Notion closely enough. Iterate against `References/typography/`
  (see `skills/m2-typography-iterate/`).
- **M3** (per-block editing + autosave) and **M4** (block-level keyboard
  model) — landed in this session. Edit / nav / split / delete-empty /
  Tab-indent all working on macOS via the NSTextView wrapper. iOS path
  compiles but is not verified for M3.

When debugging UI runtime issues, see `skills/ui-debug-loop/SKILL.md` —
launch from terminal with stderr redirected, sprinkle `print("[CLI] ...")`,
drive interactions via computer-use, tail `/tmp/console.log`.

## Debugging view problems

For UI runtime problems that compile and pass tests but misbehave in the
running app:

1. **Run from terminal so `print()` is visible.**
   ```sh
   pkill -f Console.app
   /Users/joe/Library/Developer/Xcode/DerivedData/Console-*/Build/Products/Debug/Console.app/Contents/MacOS/Console > /tmp/console.log 2>&1 &
   tail -f /tmp/console.log
   ```
   `print()` may buffer for a while when stdout isn't a tty — switch to
   `NSLog(...)` (visible via `log show --predicate 'process == "Console"'
   --last 2m`) or write to a `FileHandle` directly if you need real-time.
   Prefix everything with `[CLI]` so you can grep.

2. **Sprinkle `print("[CLI] ...")` at suspect transitions.** State setters,
   focus changes, key handlers, binding setters, lifecycle hooks
   (`onAppear`, `viewDidMoveToWindow`). Cross-reference with screenshots
   to nail down which step in the chain failed.

3. **Strip the prints before committing.** `grep -rn '\[CLI\]' Packages/UI
   App/Sources` finds them.

4. **Accessibility Inspector** (in Xcode → Open Developer Tool) is the
   fastest way to inspect the focused element, hit-testable view at a
   point, and accessibility tree. Useful when "click does nothing" turns
   out to be a parent gesture intercepting hit tests.

5. **Xcode View Debugger** (Debug → View Debugging → Capture View
   Hierarchy) shows the full layer tree of the running app. Best for
   layout problems — overlapping frames, wrong z-order, hidden views.
   Run the app under Xcode (not the standalone binary) to enable.

6. **`.onKeyPress` on macOS doesn't always intercept keys NSTextView
   consumes.** When it doesn't, override `keyDown(_:)` on a custom
   NSTextView subclass — see `MacBlockTextEditor.ContainedTextView`.

## Style preferences

- The user is a senior engineer; don't over-explain.
- Prefer editing existing files over adding new ones.
- Don't write comments that explain *what* code does — only the *why* when
  it's non-obvious.
- Don't add CHANGELOG.md, TROUBLESHOOTING.md, or other meta-docs unless asked.
- Keep round-trip tests green (`swift test --package-path Packages/Core`)
  before committing UI/typography changes — the parser/serializer is the
  load-bearing core.
