# Console — Claude working notes

A native iOS 26 + macOS 26 markdown editor. Each block in a document is its
own row in a SwiftUI `List`, so we sidestep the hardest problems of
Notion-style editors (cross-block selection, cursor merge/split across block
types, floating-UI hover targets that don't translate to touch). Source of
truth is plain `.md` files in a user-picked workspace folder.

## Repo shape

- `Packages/Core/` — pure-Swift SPM package. Model types, swift-markdown
  parser/serializer, `NSFileCoordinator`-backed storage, security-scoped
  bookmark for the workspace folder. No SwiftUI imports. Round-trip + storage
  tests live here.
- `Packages/UI/` — SwiftUI SPM package. `NotionStyle` typography constants,
  `BlockSpacing` (sibling-aware gap math), `BlockRow`/`BlockStack`/`PageView`/
  `PageListView` rendering. Depends on Core.
- `App/` — single multiplatform Xcode app target. `ConsoleApp` (`@main`),
  `ContentView` (workspace picker → page list → page view), `FontRegistration`
  (Inter Variable via CTFontManager), `Resources/Fonts/InterVariable.ttf`.
- `project.yml` — XcodeGen spec. **Don't hand-edit the .xcodeproj** — it's
  generated, ignored by git, and overwritten by `xcodegen generate`.
- `References/typography/` — real Notion screenshots from 2023-2025 used to
  drive M2 typography iteration. See `References/typography/README.md`.
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

## Key constraints

- **iOS 26 / macOS 26 minimum.** This is what unlocks `TextEditor(text:
  Binding<AttributedString>)` natively (no UITextView/NSTextView wrappers).
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

See `ROADMAP.md`. As of the most recent commit, M1 (workspace + read-only
render) is complete and verified end-to-end on macOS. M2 (Notion typography)
has a first pass but the user has flagged that it doesn't match Notion's
actual rendering closely enough. Iterate against the screenshots in
`References/typography/`.

## Style preferences

- The user is a senior engineer; don't over-explain.
- Prefer editing existing files over adding new ones.
- Don't write comments that explain *what* code does — only the *why* when
  it's non-obvious.
- Don't add CHANGELOG.md, TROUBLESHOOTING.md, or other meta-docs unless asked.
- Keep round-trip tests green (`swift test --package-path Packages/Core`)
  before committing UI/typography changes — the parser/serializer is the
  load-bearing core.
