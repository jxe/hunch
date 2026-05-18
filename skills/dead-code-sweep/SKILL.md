---
name: dead-code-sweep
description: Use when the user wants to prune dead code or tighten the public API surface — variants include "find unused symbols", "what's dead in the editor", "tighten public to internal where possible", "what only exists for tests", "earn its keep". Runs Periphery against both the Hunch app target and the Editor SPM package, triages findings against the project's actual usage (manual grep — Periphery's heuristics aren't sufficient on their own), then deletes test-only APIs and downgrades `public` to `internal` where nothing cross-module consumes a symbol.
---

# Dead-code & redundant-`public` sweep

## When this fires

The user wants to remove dead code or tighten access levels. Phrases like
"find unused stuff", "is anything dead", "what doesn't earn its keep",
"clean up redundant public", "test-only APIs should go". The work spans
both the Hunch app target and the Editor SPM package (different scan
config for each — see below).

This is not a one-shot delete. It's an iterative loop because removing
one symbol typically reveals downstream symbols that only that symbol
used (cascade-dead code). Each round shortens.

## Required tools

```sh
periphery --version    # 2.21.2 or later
```

Install: `brew install peripheryapp/periphery/periphery`. The configs
at `.periphery.yml` (repo root) and `Packages/Editor/.periphery.yml`
already exist — don't recreate. They're conservative on purpose
(better an occasional false positive than permanently hidden dead
code).

## The loop

```
1. Scan
2. Triage findings against actual usage
3. Delete / downgrade
4. Verify builds + tests
5. Goto 1 until no real findings remain
```

Each round runs both scans:

```sh
# Hunch app target — includes HunchUnitTests so `@testable import` counts.
periphery scan 2>&1 | grep "warning:"

# Editor SPM package.
( cd Packages/Editor && periphery scan 2>&1 | grep "warning:" )
```

## Triage rules

Periphery is precise but not omniscient. **Every finding gets a grep
before action.** Default to keeping the symbol if the grep is ambiguous
— the user prefers occasional noise over hidden dead code.

### "Is unused" findings

For each Periphery `warning: ... is unused`:

1. Grep the full repo for the symbol name in production sources, then
   in `App/Tests/` and `Packages/Editor/Tests/`.
2. Decide based on what shows up:
   - **Zero hits anywhere** → genuinely dead, delete it.
   - **Production hits only** → false positive (Periphery missed a
     dispatch path — common with key bindings, command tables,
     `#selector`, SwiftUI environment values). Leave it.
   - **Test hits only** → **test-only API: delete it AND the tests
     that exercised it.** This is the rule the user cares about most.
     Don't preserve tests by keeping internal helpers alive purely
     for them; integration tests catch the user-visible bug surface,
     and unit tests against an internal helper that no production
     code uses test a fiction.
   - **Production + test hits** → live, leave it.

Known false-positive categories (Periphery doesn't trace through these,
so flags are expected — don't suppress them in config, just skim past):

- **Swift Testing `@Test` functions** — Periphery doesn't recognize
  them as roots, so every `@Test` shows as `is unused`. Tests still
  run via `swift test`.
- **`BlockRow.EqualitySnapshot`** — 21 properties of a synthesized-`==`
  struct used for `.equatable()` gating. Periphery doesn't trace the
  synthesized read.
- **SwiftUI `@State` / `@FocusedValue` / `@Bindable`** — sometimes
  flagged even when used in `body`. Verify with grep.
- **App Intents framework** (`AppShortcutsProvider`, `AppIntent`
  `description` properties) — registered at runtime via reflection.
- **`SwiftUI` Previews** — covered by `retain_swift_ui_previews: true`,
  but Preview-only helper structs sometimes still surface.

### "Declared public, but not used outside of …" findings

For each `warning: ... is declared public, but not used outside of
<Module>`:

1. **In the Hunch app target.** The app is a single Swift target, so
   *every* `public` is documentary, not scope. **Default action:
   downgrade to internal.** The only `public` markers worth keeping
   are on symbols the Editor SPM package consumes from the Hunch app
   — and there aren't any (the dependency is one-directional). Use
   `sed`-style `replace_all "public " → ""` per file once you've
   confirmed no `public` strings live in comments or string literals
   inside that file. Watch out for `public internal(set) var`: drop
   the `public` and (usually) the `internal(set)` too, since
   internal-on-internal is redundant.

2. **In the Editor SPM package.** Periphery's "redundant public"
   analysis here is *unreliable*: when scanning the Editor package
   alone, Periphery doesn't see the Hunch app target consuming it.
   Many symbols Periphery flags as redundant are in fact consumed
   cross-module. **Cross-check every Editor finding with a manual
   grep against `App/Sources`:**

   ```sh
   for sym in <Periphery's flagged symbol list>; do
     count=$(grep -rln "\b$sym\b" /Users/joe/src/hunch/App/Sources \
       2>/dev/null | wc -l | tr -d ' ')
     echo "$sym: $count Hunch app files"
   done
   ```

   - **0 hits in `App/Sources`** → safe to downgrade to internal.
   - **≥1 hits in `App/Sources`** → leave it public. Spot-check the
     hits aren't just doc-comment mentions (e.g. CLAUDE.md or README
     refs).

   By default the `Packages/Editor/.periphery.yml` has `retain_public:
   true` so this analysis is silent. To get the list, run with a
   one-off config:

   ```sh
   cat > /tmp/editor-no-retain.yml <<'EOF'
   retain_public: false
   retain_swift_ui_previews: true
   relative_results: true
   disable_update_check: true
   EOF
   ( cd Packages/Editor && periphery scan --config /tmp/editor-no-retain.yml ) \
     2>&1 | grep "declared public, but not used outside"
   ```

   When a downgraded symbol turns out to be needed by a Hunch *test*
   (not by Hunch source), add `@testable import Editor` to that test
   file rather than restoring `public`. (Example: `RecoveryLogTests.swift`
   uses `BlockTreeDiff.derive` to build test ops — `BlockTreeDiff`
   stays internal, the test uses `@testable`.)

### Test-only convenience accessors

If a test uses a public/internal accessor that's a thin wrapper over a
visible data field (e.g. `IntentState.status(of: h)` is literally
`byHash[h]`), prefer **inlining the access at the test sites** over
keeping the accessor alive. The `byHash` field is already `internal`,
so `@testable import` sees it.

```swift
// Before
if case .alive = intent.status(of: h) { … }
// After
if case .alive = intent.byHash[h] { … }
```

This pattern lets the test coverage stay intact without leaving a
test-only API alive.

## Verification gate

After **every** round of deletions/downgrades, all four must pass:

```sh
swift test --package-path Packages/Editor
xcodebuild -project Hunch.xcodeproj -scheme Hunch \
  -destination 'platform=macOS' -configuration Debug build
xcodebuild -project Hunch.xcodeproj -scheme Hunch \
  -destination 'generic/platform=iOS Simulator' -configuration Debug build
xcodebuild -project Hunch.xcodeproj -scheme Hunch \
  -destination 'platform=macOS' test -only-testing HunchUnitTests
```

Don't commit until the full grid is green. Run them in parallel.

## Doc sweep

When a removed/renamed/downgraded symbol is mentioned in:

- `Packages/Editor/README.md`
- `App/Sources/Clamshell/README.md`
- `CLAUDE.md`

…fix the reference (rename, remove, or rephrase). One pass at the end
is fine — find them with:

```sh
grep -n "<symbol-name>" Packages/Editor/README.md \
  App/Sources/Clamshell/README.md CLAUDE.md
```

Doc text that describes *internal* architecture by naming types
(e.g. "the editor uses `BlockTreeDiff.derive` to compute the diff
that fires `persistCommit`") is fine to keep when those types
become internal — they're not advertising a public API, they're
describing implementation.

## What NOT to do

- **Don't add per-file `retain_files` entries** to silence noise in
  `.periphery.yml`. Better to scroll past 21 BlockRow EqualitySnapshot
  warnings every run than to permanently hide a real regression in
  that file.
- **Don't run `auto-remove`.** Periphery has an experimental
  `--auto-remove` flag — never use it. Triage by hand.
- **Don't restore `public` to make a test compile.** Use `@testable
  import` instead. The whole point of the sweep is that nothing
  outside the module needs the public marker.
- **Don't delete tests just to silence Periphery's `is unused`
  warning on `@Test` functions.** Those are false positives; `swift
  test` will run them. Test-only API deletion is a different rule —
  there the *API* is dead and its tests die with it.

## Commit shape

Group by intent, not by file:

1. One commit for new `.periphery.yml` configs.
2. Subsequent commits per loop iteration — title like
   "Periphery: <bucket> — prune <thing>" where bucket is one of
   *test-only API*, *redundant public (Hunch app)*, *redundant
   public (Editor SPM)*, *cascade*. Body lists the specific
   symbols.

Until no more findings remain, you're not done.
