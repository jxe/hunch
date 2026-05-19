---
name: dead-code-sweep
description: Use when the user wants to prune dead code, tighten the public API surface, or check whether cross-component API surfaces are still consumed — variants include "find unused symbols", "what's dead in the editor", "tighten public to internal where possible", "what only exists for tests", "earn its keep", "is anything on the Clamshell / EditorHost / EditorCommands surface unused", "are the canonical consumers actually calling everything we expose". Runs Periphery against both the Hunch app target and the Editor SPM package; runs a manual cross-component boundary audit for surfaces Periphery can't analyze (intra-module callers and test-only callers slip through both filters). Triages findings against actual usage (manual grep — Periphery's heuristics aren't sufficient on their own), then deletes dead API and tests, and downgrades `public` to `internal` where nothing cross-module consumes a symbol.
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
1. Scan (Periphery — intra-module dead code)
2. Audit cross-component API boundaries (manual — boundary script)
3. Triage findings against actual usage
4. Delete / downgrade
5. Verify builds + tests
6. Goto 1 until no real findings remain
```

Each round runs both Periphery scans via the bundled wrapper:

```sh
.claude/skills/dead-code-sweep/scripts/scan.sh
```

The wrapper runs Periphery against both targets and strips the
`@Test`-function "is unused" lines from the test bundles — Periphery
doesn't recognize Swift Testing roots, so every `@Test` flags as
unused even though `swift test` runs them. The noise dominates the
output if you don't filter, and the real findings get lost in it.

Then audit cross-component boundaries (Periphery can't see these —
read "Cross-component API audit" below):

```sh
.claude/skills/dead-code-sweep/scripts/audit-boundaries.sh
```

### Known false positives in this repo (skim past these)

Periphery's data-flow analysis misses these specific dispatch paths.
The warnings will keep appearing every run; *don't* silence them in
config (that risks hiding a real regression in the same file) — just
recognize them and move on:

- **`BlockRow.swift:95–115`** — `EqualitySnapshot`'s 21 fields, read
  through a synthesized `==`. The compiler enforces the field list (a
  missing field fails to type-check), so adding fields without thinking
  isn't a risk.
- **`Text/BlockTextEditor.swift:128,139`** — `font` / `isActive` are
  let-properties on a `View` struct read inside `Coordinator` /
  `NSViewRepresentable` / `UIViewRepresentable` methods. Periphery's
  data-flow doesn't trace into those.
- **`EditorView+Gestures.swift:286`** — `IOSPageReorderGeometry` is
  used by iOS production AND macOS tests, but Periphery sees neither
  (iOS code is `#if`-gated out of the macOS scan, and `@Test` functions
  aren't traced). Leave it.
- **`InlineMarksBridge.swift:6`** — `PlatformColor` typealias is only
  consumed by tests. Trivially cheap; not worth deleting.
- **`Shell/RecoveryView.swift` `StreamKey`** — `filter` and
  `showAllPurged` feed the synthesized `Hashable` used as a
  `.task(id:)` identity. Periphery doesn't trace the synthesized read.
- **`VoiceRecordingIntents.swift`** — `HunchAppShortcuts` and
  `AppIntent.description` are registered via AppIntents reflection at
  runtime.

When you find a NEW false positive (a symbol whose grep proves
production+test usage, but Periphery still flags), prefer **silencing
at the source** over adding to this list — see "Silence iOS-only
producers at the source" below.

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

Beyond the repo-specific known false positives listed above, these
generic categories are worth recognizing on first sight:

- **SwiftUI `@State` / `@FocusedValue` / `@Bindable`** — sometimes
  flagged even when used in `body`. Verify with grep.
- **`SwiftUI` Previews** — covered by `retain_swift_ui_previews: true`,
  but Preview-only helper structs sometimes still surface.
- **`#selector` / Obj-C runtime dispatch / Codable property
  reflection** — handled by `retain_objc_accessible` and
  `retain_codable_properties` in the root config, but exotic dispatch
  paths can still slip through.

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
   cross-module. The default `Packages/Editor/.periphery.yml` sets
   `retain_public: true` to keep these false positives out of the
   normal scan — opt in explicitly when doing the redundant-public
   bucket via:

   ```sh
   .claude/skills/dead-code-sweep/scripts/triage-public.sh
   ```

   The wrapper writes the no-retain config, runs the scan, extracts
   each flagged symbol, and greps `App/Sources` for it — emitting one
   line per symbol:

   - `DROP:     <sym>` — zero hits in `App/Sources`. Safe to convert
     `public` → `internal`.
   - `KEEP (N): <sym>` — N files in `App/Sources` reference it.
     Spot-check N>0 isn't all doc-comment mentions (CLAUDE.md,
     READMEs masquerade as usages), but otherwise leave public.
   - `MANUAL:   init(...)` — call sites use the parent type's name,
     not `init`, so the grep can't decide. Look at the parent type's
     own row to infer (parent KEEP → init usually KEEP too).

   When a `DROP` symbol turns out to be needed by a Hunch *test*
   (not by Hunch source), add `@testable import Editor` to that test
   file rather than restoring `public`. (Example: `RecoveryLogTests.swift`
   uses `BlockTreeDiff.derive` to build test ops — `BlockTreeDiff`
   stays internal, the test uses `@testable`.)

### Cross-component API audit (Periphery's blind spot)

Periphery's two filters — `is unused` (zero callers in module) and
`declared public, but not used outside of <Module>` (no cross-module
callers) — both pass a class of dead API: **symbols on a named
cross-component surface that have intra-component or test callers
but no canonical consumer**. Examples:

- A `Clamshell` method called only from another `Clamshell+*.swift`
  file but never by host code outside the Clamshell directory. Looks
  used to Periphery; doesn't earn its place on the host-facing
  surface.
- An `EditorHost` protocol method that the editor itself never
  invokes — the host implements it for nothing.
- An `EditorAction` enum case with no dispatch site in
  `wireEditorCommands`, the menu bar, or the nav-mode key bindings.

The user cares about deletion here, not visibility. The
boundary-audit wrapper does the manual grep work:

```sh
.claude/skills/dead-code-sweep/scripts/audit-boundaries.sh
# or one surface:
.claude/skills/dead-code-sweep/scripts/audit-boundaries.sh clamshell
.claude/skills/dead-code-sweep/scripts/audit-boundaries.sh editor-host
.claude/skills/dead-code-sweep/scripts/audit-boundaries.sh editor-action
```

It emits one line per declared symbol on each surface:

```
SYMBOL                           consumer=N producer=N test=N
```

Verdicts:

| Counts                                  | Verdict                        |
|-----------------------------------------|--------------------------------|
| `consumer>0`                            | live API. Leave alone.         |
| `consumer=0` `test>0`                   | test-only. Delete symbol AND its tests. |
| `consumer=0` `test=0` `producer>1`      | intra-component helper, not actually on the boundary. Leave (or `private` if you also want to clean visibility — separate question). |
| `consumer=0` `test=0` `producer=1`      | dead. Delete.                  |

There's also a soft case: `consumer=0` `test=1` `producer>1`. The
symbol is live as an intra-component helper, and a *test*
incidentally uses it as a sanity probe. Often the test asserts
something else after the probe; the probe line itself is dead
weight. Remove just the probe call from the test, keep the helper
and the rest of the test.

#### Adding a new boundary

When a new cross-component surface appears (a new protocol, a new
host-facing class), add a `run <name>)` arm to `audit-boundaries.sh`
specifying:
- `producer_files` — the declaration site(s)
- `producer_exclude` — the path fragment that identifies the producer
  scope (excluded from the consumer-count grep)
- `consumer_paths` — where the canonical consumer code lives

The script is grep-driven, so the surface needs to be enumerable by
a simple regex (one symbol per line declaration: `func name(...)` or
`case name`). Surfaces with macro-generated symbols or unusual
declaration syntax need a hand-written enumerator.

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

After **every** round of deletions/downgrades, all four gates must
pass — Editor SPM tests, macOS build, iOS Simulator build,
HunchUnitTests. Run them via:

```sh
.claude/skills/dead-code-sweep/scripts/verify.sh
```

The wrapper runs all four in parallel and prints a PASS/FAIL summary;
on failure it tails the failing log so you can see what broke
without scrolling. Exit code is 0 only if everything passed. Don't
commit until that's the case.

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

## Silence iOS-only producers at the source

Periphery scans the macOS build by default. A symbol whose *only*
consumers live inside `#if os(iOS)` blocks looks dead to it, even
though it's load-bearing on iOS. The right fix isn't a config exception
— it's wrapping the *producer* in `#if os(iOS)` too. That makes the
build truth match Periphery's view of the world, and the warning goes
away forever.

Before doing this, grep to confirm the symbol has no macOS consumer
anywhere — including tests. If a macOS test consumes it (the typical
trap: a behavioural test runs cross-platform), leave the producer
visible on both platforms.

Examples in this repo where this was applied:
`SeededLCG`, `BlockDragPayload.init(jsonString:)`,
`EditorView.lastDropHapticTarget` / `lastDropHapticFireAt`.

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
   public (Editor SPM)*, *cross-component boundary*, *cascade*.
   Body lists the specific symbols.

Until no more findings remain, you're not done.
