# Editor extraction Milestone 5 verification record

Recorded 2026-08-15. The package/product/module name remains `Editor` through
Milestone 5; the public naming decision is now the first task in Milestone 6.

## Result

- `EditorConfiguration` now carries theme, audio, haptic, and logging policy
  per editor instance. Package defaults use system typography, disable feedback,
  and derive diagnostics from the host bundle unless a subsystem is supplied.
- `EditorTheme` replaces the old product-inspired style namespace with explicit
  palette, typography, and load-bearing layout values. Hunch owns its Inter
  selection and shell presentation through `HunchStyle`.
- The package no longer reads Hunch preferences, publishes a Hunch Escape
  notification, hard-codes Hunch logging identifiers, or contains Hunch and
  Console naming. Hunch's fullscreen monitor bridges its process-global Escape
  event to the neutral `.escape` editor command.
- The emoji picker and inline attribute raw names are editor-owned. The host
  Markdown serializer translates typed inline attributes rather than persisting
  the raw key names, so no compatibility reader or data migration was needed.
- The public API audit internalized gesture, overlay, trigger, lifecycle,
  completion, hover, and mutable session implementation state. APIs with live
  Hunch call sites, including `DropPath`, page-title emoji replacement, and URL
  autolinking, remain public.
- All Hunch unit tests use normal `import Editor`; none requires package testable
  access.

## Toolchain

- Apple Swift 6.4 (`swiftlang-6.4.0.20.104`)
- Xcode 27.0 beta, build `27A5194q`
- XcodeGen 2.45.4
- iOS destination: iPhone 17 Pro, iOS 27.0 simulator,
  `C76DE979-27D7-4BE5-AD11-3FC223402AB9`

## Verification matrix

| Check | Result |
|---|---|
| Editor package suite | PASS — 241 tests in 25 suites, with no host font registration. |
| Project regeneration | PASS — `xcodegen generate`; the tracked project includes `HunchStyle` and the package configuration source. |
| Hunch macOS unit suite | PASS — 332 tests in 27 suites. |
| Hunch macOS build | PASS. |
| Hunch iOS Simulator build | PASS on the installed iOS 27 simulator. |
| Focused iOS 27 UI suite | PASS — all 17 drag/reorder, edit/scroll, and split-keyboard tests. |
| Package-policy searches | PASS — both Milestone 5 `rg` gates return no matches. |
| Exact-artifact smoke check | PASS — launched the `/tmp/hunch-editor-m5-macos-build` product, opened an isolated Markdown workspace, visually checked Hunch typography, palette, inline styling, bullets, quote treatment, and icons, then confirmed Escape exits text editing through the host bridge. |
| User smoke check | PASS — typography/colors, Escape and fullscreen behavior, feedback preferences, emoji completion, actions/reorder/formatting, icons, and light/dark appearance all matched normal Hunch behavior. |

## Contract coverage

- Package tests assert system-font, quiet-feedback, and neutral-subsystem
  defaults, plus stable `Editor.Inline.*` attribute names.
- Hunch tests assert its public theme selects `Inter Variable`, the registered
  semibold face resolves, haptics remain enabled, audio defaults on, and the
  `uiSoundsEnabled` host preference can mute it.
- Existing inline-mark and Markdown round-trip suites continue to cover the
  typed attribute translation path.
