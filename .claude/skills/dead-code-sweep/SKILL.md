---
name: dead-code-sweep
description: Use when the user wants to prune dead code, audit a cross-component API surface, or align doc + `public`-marker hygiene with what's actually consumed. Variants include "find unused symbols", "what's dead in the editor", "what only exists for tests", "earn its keep", "is anything on the Clamshell / EditorHost / EditorCommands surface unused", "are the canonical consumers actually calling everything we expose", "are the READMEs listing things nobody uses". Runs Periphery against both targets for in-module dead code; runs a manual cross-component boundary audit for the surfaces Periphery can't see (intra-module callers and test-only callers slip through Periphery's filters); triages findings against actual usage and against the canonical doc files. Tests never count as a justification to keep a symbol — a test-only API gets deleted along with its tests.
---

# Dead-code & API-surface sweep

## When this fires

The user wants to remove dead code, audit a cross-component API
surface, or tidy the docs and `public` markers to match what's
actually consumed. Phrases: "find unused stuff", "is anything dead",
"what doesn't earn its keep", "are the canonical consumers calling
everything we expose", "the README is listing things nobody uses".

This is an iterative loop — removing one symbol typically reveals
cascade-dead symbols only it used.

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
1. Scan (Periphery — in-module dead code)
2. Audit (cross-component boundary audit — what canonical consumers don't call)
3. Triage findings against actual usage
4. Delete; fix docs; drop `public` where no consumer needs it
5. Verify builds + tests
6. Goto 1 until no real findings remain
```

Each round runs Periphery via the wrapper:

```sh
.claude/skills/dead-code-sweep/scripts/scan.sh
```

The wrapper runs Periphery against both targets and strips the
`@Test`-function "is unused" lines from the test bundles — Periphery
doesn't recognize Swift Testing roots, so every `@Test` flags as
unused even though `swift test` runs them.

Then audit the cross-component boundaries — Periphery can't see
these (read "Cross-component API audit" below):

```sh
.claude/skills/dead-code-sweep/scripts/audit-boundaries.sh
```

### Known false positives in this repo (skim past these)

Periphery's data-flow analysis misses these specific dispatch paths.
Don't silence them in config (that risks hiding a real regression in
the same file) — recognize and move on:

- **`BlockRow.swift:95–115`** — `EqualitySnapshot`'s 21 fields, read
  through a synthesized `==`. The compiler enforces the field list.
- **`Text/BlockTextEditor.swift:128,139`** — `font` / `isActive` are
  let-properties on a `View` struct read inside `Coordinator` /
  `NSViewRepresentable` methods.
- **`EditorView+Gestures.swift:286`** — `IOSPageReorderGeometry` is
  used by iOS production AND macOS tests, but Periphery sees neither
  (iOS code is `#if`-gated out of the macOS scan; `@Test` functions
  aren't traced).
- **`InlineMarksBridge.swift:6`** — `PlatformColor` typealias is only
  consumed by tests. Trivially cheap; not worth deleting.
- **`Shell/RecoveryView.swift` `StreamKey`** — `filter` and
  `showAllPurged` feed the synthesized `Hashable` used as a
  `.task(id:)` identity.
- **`VoiceRecordingIntents.swift`** — `HunchAppShortcuts` and
  `AppIntent.description` are registered via AppIntents reflection.

When you find a NEW false positive (a symbol whose grep proves
production+test usage, but Periphery still flags), prefer **silencing
at the source** over adding to this list — see "Silence iOS-only
producers at the source" below.

## Triage rules

**Every finding gets a grep before action.** Default to keeping the
symbol if the grep is ambiguous — the user prefers occasional noise
over hidden dead code.

**Tests don't count as a user.** A symbol with no production caller
but test callers is *test-only*. The action is delete the symbol AND
the tests, not preserve it.

### "Is unused" findings (Periphery scan)

For each Periphery `warning: ... is unused`:

1. Grep the full repo for the symbol name in production sources and
   in `App/Tests/` / `Packages/Editor/Tests/`.
2. Decide:
   - **Zero hits anywhere** → genuinely dead, delete.
   - **Production hits only** → false positive (Periphery missed a
     dispatch path — key bindings, command tables, `#selector`,
     SwiftUI environment values). Leave it; consider adding to the
     known-FP list above if it'll recur.
   - **Test hits only** → test-only API. Delete the symbol AND its
     tests. (Don't keep internal helpers alive purely for their own
     unit tests — that tests a fiction.)
   - **Production + test hits** → live, leave it.

Generic categories worth recognizing on first sight: SwiftUI `@State`
/ `@FocusedValue` / `@Bindable` (sometimes flagged even when used in
`body`); Previews (covered by `retain_swift_ui_previews: true` but
preview-only helper structs sometimes still surface); `#selector` /
Codable property reflection (covered by retain flags but exotic
dispatch paths can slip through).

### Cross-component API audit

The named cross-component API surfaces in this repo:

- **`clamshell`** — methods on the `Clamshell` class. Canonical
  consumer is the rest of `App/Sources` (anything outside the
  `Clamshell/` dir).
- **`editor-host`** — `EditorHost` protocol methods. Canonical
  consumer is the Editor SPM itself: the editor invokes them on its
  injected host.
- **`editor-action`** — `EditorAction` enum cases. Canonical
  consumer is "anywhere a case is dispatched" — `wireEditorCommands`,
  the menu bar, nav-mode key bindings.

The boundary audit answers a question Periphery can't: *does the
canonical consumer actually invoke this symbol?* Periphery's "is
unused" passes any symbol with an intra-component or test caller;
Periphery's "redundant public" is a visibility question, not a
deletion one. The user cares about deletion of unused API and
about doc/`public`-marker hygiene matching what's actually consumed.

```sh
.claude/skills/dead-code-sweep/scripts/audit-boundaries.sh
# or one surface:
.claude/skills/dead-code-sweep/scripts/audit-boundaries.sh clamshell
.claude/skills/dead-code-sweep/scripts/audit-boundaries.sh editor-host
.claude/skills/dead-code-sweep/scripts/audit-boundaries.sh editor-action
```

Output per symbol:

```
SYMBOL                   consumer=N producer=N docs=N test=N
```

| Column   | Meaning |
|----------|---------|
| consumer | Files OUTSIDE the producer scope that call this symbol. **Only column that justifies keeping the symbol on the API surface.** |
| producer | Files INSIDE the producer scope that mention the symbol (declaration line included — `producer=1` means "nobody else in the producer uses it either"). Helpful to tell intra-helper from truly dead. |
| docs     | Files among `CLAUDE.md`, `App/Sources/Clamshell/README.md`, and `Packages/Editor/README.md` that mention the symbol. `consumer=0` with `docs>0` is a parsimony hint — the docs may be advertising a dropped or internal API. |
| test     | Files in `App/Tests` or `Packages/Editor/Tests` that call it. Informational; doesn't justify keeping the symbol. |

**Verdicts:**

| Counts                                | Action |
|---------------------------------------|--------|
| `consumer>0`                          | Live API. If marked `public`, keep the `public`. Make sure it's listed in the relevant doc's API enumeration. |
| `consumer=0  test=0  producer=1`      | Dead. Delete the symbol. Sweep any doc mentions. |
| `consumer=0  test>0  producer=1`      | Test-only API. Delete the symbol AND its tests. Sweep doc mentions. |
| `consumer=0  any test  producer>1`    | Intra-component helper, not on the cross-component surface. Drop the `public` if it has one; remove from any "public API" listing in docs. The symbol itself stays (some other file in the producer scope still calls it). |

**Doc-mention follow-up.** When the audit says `docs>0` for a
non-`consumer>0` row, grep:

```sh
grep -n "<symbol-name>" CLAUDE.md \
  App/Sources/Clamshell/README.md \
  Packages/Editor/README.md
```

Inspect each hit. *API enumeration* lines (tables, "Group / Methods"
listings, the bullet "the public surface exposes X, Y, Z") should
shed the dropped/internal symbol. *Architecture narrative* lines
("internal helpers `X`, `Y`, and `Z` drive the engine") are fine to
keep when they correctly label the symbols as internal — they're
explaining implementation, not advertising API. The script can't
tell which kind of mention you're looking at; the operator has to
read the surrounding sentence.

**Soft case:** `consumer=0  test=1  producer>1` *can* happen when a
test uses an intra-helper as a sanity probe before a real
assertion. The probe line itself is usually dead weight — remove
just that line, keep the test and the helper. If the test has
nothing left to assert without the probe, treat it as test-only and
delete both.

#### Adding a new boundary

When a new cross-component surface appears (a new protocol, a new
host-facing class), add a `run <name>)` arm to `audit-boundaries.sh`
specifying:
- `producer_files` — the declaration site(s)
- `producer_exclude` — path fragment identifying the producer scope
  (excluded from the consumer-count grep)
- `consumer_paths` — where the canonical consumer code lives

The script is grep-driven; the surface needs to be enumerable by a
simple regex (one symbol per declaration line: `func name(...)` or
`case name`). Surfaces with macro-generated symbols or unusual
declaration syntax need a hand-written enumerator.

### Test-only convenience accessors

If a test uses a public/internal accessor that's a thin wrapper over
a visible data field (e.g. `IntentState.status(of: h)` is literally
`byHash[h]`), prefer **inlining the access at the test sites** over
keeping the accessor alive. `@testable import` lets tests reach
internal stored properties.

```swift
// Before
if case .alive = intent.status(of: h) { … }
// After
if case .alive = intent.byHash[h] { … }
```

## Verification gate

After **every** round of deletions/downgrades, all four gates must
pass — Editor SPM tests, macOS build, iOS Simulator build,
HunchUnitTests:

```sh
.claude/skills/dead-code-sweep/scripts/verify.sh
```

Runs them in parallel, prints PASS/FAIL summary, tails failing logs.
Exit 0 only if all four pass. Don't commit until that's the case.

## Silence iOS-only producers at the source

Periphery scans the macOS build by default. A symbol whose *only*
consumers live inside `#if os(iOS)` blocks looks dead to it even
though it's load-bearing on iOS. The right fix isn't a config
exception — wrap the *producer* in `#if os(iOS)` too. Build truth
then matches Periphery's view of the world, and the warning goes
away forever.

Before doing this, grep to confirm the symbol has no macOS consumer
anywhere — including tests. If a macOS test consumes it, leave the
producer visible on both platforms.

Examples in this repo: `SeededLCG`, `BlockDragPayload.init(jsonString:)`,
`EditorView.lastDropHapticTarget` / `lastDropHapticFireAt`.

## What NOT to do

- **Don't add per-file `retain_files` entries** to silence noise in
  `.periphery.yml`. Better to scroll past warnings than permanently
  hide a real regression.
- **Don't run `auto-remove`.** Periphery has an experimental
  `--auto-remove` flag — never use it. Triage by hand.
- **Don't restore `public` to make a test compile.** Use `@testable
  import` instead.
- **Don't delete tests to silence Periphery's `is unused` warning on
  `@Test` functions.** Those are false positives; `swift test` runs
  them. Test-only API deletion is a different rule — there the
  *API* is dead and its tests die with it.
- **Don't preserve a symbol because tests use it.** Tests aren't a
  consumer. If the only thing keeping a symbol alive is its own
  tests, both go.
- **Don't do a willy-nilly `public → internal` sweep.** The
  visibility question is only worth touching for symbols the
  boundary audit flagged. Trim the named surfaces; don't audit every
  `public` keyword in the repo.

## Commit shape

Group by intent, not by file. Title format:
"Periphery: <bucket> — prune <thing>" where bucket is one of
*test-only API*, *cross-component boundary*, *cascade*, *doc
parsimony*. Body lists the specific symbols.

Until no more findings remain, you're not done.
