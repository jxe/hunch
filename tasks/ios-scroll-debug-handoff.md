# Handoff: iOS scroll is being eaten by the row reorder gesture

This task is for a fresh agent. The previous agent burned through several
speculative fixes that didn't work, then was asked to stop and write this
plan. Please read in full before running anything.

## What the user observes (iOS Simulator, current `main`)

1. A vertical scroll attempt on a row does **not** scroll. The page stays put.
2. While the user is touching the screen, the row "near where they started"
   dims to opacity 0.12. A haptic fires at the same moment.
3. To the user, this happens **immediately on finger-down**. (See timing
   analysis below — it's actually 340ms, but feels immediate.)
4. The user's intent was to scroll. Reorder is a deliberate, separate gesture.

## What we know from instrumentation

The previous agent added `NSLog` to [`IOSRowReorderActions.handleChange`](../Packages/UI/Sources/UI/PageView.swift) and asked the user to capture the
log on iOS Simulator. The user produced this trace from one successful
reorder followed by two scroll attempts:

```
# Successful reorder
t=65747.879 .first(true) isReordering=false
t=65747.879 beginIfNeeded — onBegin firing
<system> Gesture: System gesture gate timed out.
t=65749.767 .second(first=true, drag=nil) isReordering=true        <-- 1.9s gap
t=65750.336 .second(... drag.translation=(0,0))                     <-- another 0.6s
t=65750.376 .second(... translation=(1,-2.7))
... drag continues ...
t=65751.218 onEnded isReordering=true

# Scroll attempt 1 — FAILS
t=65752.345 .first(true) isReordering=false
t=65752.345 beginIfNeeded — onBegin firing
# nothing else; no .second, no onEnded

# Scroll attempt 2 — FAILS
t=65754.760 .first(true) isReordering=false
t=65754.760 beginIfNeeded — onBegin firing
# nothing else
```

### Key facts the trace establishes

- The `LongPressGesture(0.34s, 36pt)` **does** time correctly — the user
  must hold for 340ms within 36pt for `.first(true)` to fire.
- After `.first(true)`, SwiftUI's gesture coordination prints
  "System gesture gate timed out" and **delays `.second` events by ~1.9s**.
  In the successful reorder, the user happened to keep their finger down
  past that gate, so drag events eventually arrived. In a typical scroll
  attempt the user lifts inside the gate window, and then **no further
  events fire — including no `onEnded`**.
- Because `.first(true)` already fired before the user lifted, `isReordering`
  is `true`, the haptic has fired, and `reorderLift` is non-nil — so the
  source row stays dimmed, the user can't scroll, and the gesture is in a
  zombie state.
- For scroll attempt 2 to log `isReordering=false`, the state had to reset
  somehow — probably SwiftUI cancelling without invoking our `onEnded`. We
  don't see a cancel callback either.

## What the previous agent tried (don't repeat)

All of these failed. They were reverted. They are listed here so you don't
waste a turn on them.

1. **`maximumDistance: 36 → 10`** — too lenient still; slow scrolls within
   10pt of the touch-down point during 340ms still fire `.first(true)`.
2. **Gating the lift overlay on `pendingAnchor`** — visual-only fix, didn't
   address the gate-timeout / scroll-blocked behaviour.
3. **Gating the source-row dim on `pendingAnchor`** — same.
4. **`minimumDuration: 0.34 → 0.5`, `maximumDistance: 36 → 5`** — the agent
   reverted this because the user reported scroll still didn't work after.
   Worth re-considering empirically (see "Things to try" below) but the
   core gate-timeout problem isn't solved by tightening parameters.

## The hypothesis worth testing first

The pathological behaviour is the **System gesture gate timeout**. Once
`.first(true)` fires, SwiftUI puts the touch in a coordination gate (apparently
to negotiate with system gestures, e.g. screen-edge swipes). The gate sits
for ~1.9s. If the user lifts during the gate, no events propagate — neither
to our reorder gesture (no `.second`/`onEnded`) nor to the parent ScrollView
(no scroll). The touch is stranded.

For real scroll-friendliness, the fix may have to be one of:

- **Replace the sequenced `LongPress→Drag` with a custom `DragGesture` that
  measures press duration in the closure.** No `LongPressGesture`, no gate.
  The closure tracks `Date()` and `value.translation`, fires reorder-begin
  when held >0.5s within 5pt without fast movement.
- **Move the row reorder to a dedicated drag handle (gutter)** like the
  macOS path. Tap-to-edit on the row body, no long-press anywhere on the
  row body. Scroll always works on the body. The handle on iOS would have
  to be permanently visible (no hover on touch).
- **Wrap a `UILongPressGestureRecognizer` in a `UIViewRepresentable`** with
  explicit `requireGestureRecognizerToFail` linkage to `UIScrollView`'s
  pan recognizer. UIKit-level coordination should make scroll always win
  for movement. This is the "correct" iOS path but the heaviest change.

Which is right depends on what UX the user wants. **Ask before implementing.**
The previous agent committed too eagerly. Don't.

## Existing test infrastructure

The repo already has XCUITest infra for drag-and-drop. Use and extend it.

- Test target: `HunchUITests` ([`App/UITests/HunchDragAndDropUITests.swift`](../App/UITests/HunchDragAndDropUITests.swift))
- The app accepts launch argument `--console-ui-testing` — when set,
  [`ContentView.installUITestWorkspace()`](../App/Sources/ContentView.swift) writes a fixed
  workspace to `/tmp/console-ui-tests/everything.md` with rows
  `Alpha, Bravo, Charlie, Delta, Echo, Foxtrot` and opens it. So tests
  always start from a known state.
- Each block row publishes accessibility ID `block-row-<slug>` (e.g.
  `block-row-bravo`). Look up via
  `app.descendants(matching: .any)["block-row-bravo"]`.
- Existing tests use `XCUICoordinate.press(forDuration:thenDragTo:)` and
  helpers `row(containing:)`, `assertRowOrder(_:)`,
  `waitForRowOrder(_:timeout:)`, `currentRowOrder(_:)`.

Run iOS UI tests:

```sh
xcodebuild test \
  -project Hunch.xcodeproj \
  -scheme Hunch \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:HunchUITests
```

(Pick whatever iOS simulator is available on the machine —
`xcrun simctl list devices available` to choose.)

## The tests you should add (in this order)

These are the smallest distinct probes that, taken together, pin down the
gate-timeout hypothesis and prove whatever fix you eventually try.

### 1. `testVerticalDragOnRowScrollsThePage`

The test that's failing for the user, made deterministic.

- Long enough doc that scrolling actually moves things — install a
  test-only workspace fixture with ~30 rows (extend
  `installUITestWorkspace()` to take a row count via a separate launch
  arg, e.g. `--console-ui-testing-tall-doc`).
- Capture the page's first-row Y before and after.
- Drag from `rowN` upward by ~200pt with `press(forDuration: 0.05, thenDragTo: ...)`
  (0.05s — *less* than the 0.34s long-press threshold; should clearly
  read as a scroll, not a long-press).
- Assert the page's first-row Y is **smaller** afterwards (scrolled up).

If this test fails on `main`, you've reproduced the bug in CI. Fix it.
If it passes, the bug is something else and you need a more targeted
test.

### 2. `testSlowVerticalDragOnRowStillScrolls`

Same as #1 but slower (the original bug seems to involve slow drags —
fast ones may exceed `maximumDistance` and cancel cleanly).

- Use a longer `forDuration` (e.g. 0.5s) and a small drag distance
  (e.g. 30pt vertical) so the *velocity* is in the same ballpark as a
  hesitant user-scroll.
- Same assertion: page scrolled.

This is the test that will most likely fail and best characterises the
gate-timeout behaviour.

### 3. `testTapDoesNotDimRow`

Locks in that a brief tap (no long-press) doesn't put the row into the
reorder state.

- Tap row with no duration: `row.tap()`.
- Wait briefly, then assert the row's accessibility traits don't include
  whatever accessibility marker the dim has.
- Today there's no accessibility marker for the dimmed state. **Add one**
  — e.g. an `accessibilityValue` on the row that reports
  `"reorder-source"` while dimmed. That's strictly additive and lets
  tests assert state without relying on screenshots.

### 4. `testQuickHoldThenLiftDoesntStrandTheGesture`

The "scroll attempt that didn't lift in time" case from the user trace.

- Press for 0.4s (just past long-press completion) without moving, then
  lift.
- Wait, then attempt a tap on a different row — assert it enters edit
  mode.
- Without a fix, the previous press leaves `reorderLift` non-nil and
  blocks subsequent interaction. With a fix, state should clean up.

### 5. `testHorizontalSwipeStillTriggersDelete`

Regression check for `IOSRowSwipeActions`. Whatever you do to the
reorder gesture, the swipe-to-delete must still work.

- Swipe a row leftward >96pt (the existing `trigger` constant).
- Assert the row is removed.

### 6. `testReorderViaLongPressStillWorks`

Already exists as `testLongPressReordersRows`. After your fix, **it must
still pass.**

## Investigation workflow

1. Read [`docs/drag-and-drop.md`](../docs/drag-and-drop.md) and
   [`Packages/UI/Sources/UI/PageView.swift`](../Packages/UI/Sources/UI/PageView.swift) — specifically
   `IOSRowReorderActions` (the gesture wiring), `iosBlockTouchActions`
   (where it's attached), and `preliftReorder` / `tickReorderLift` /
   `endReorderLift` (the lift state machine).
2. Re-add the gesture-state `NSLog` from commit `9557742` (now reverted)
   for your own diagnosis. **Don't commit it.** Strip before any commit
   per [CLAUDE.md](../CLAUDE.md)'s `[CLI]` rule.
3. Add tests #1 and #2 above and confirm they fail on `main`.
4. Form a hypothesis. Write down what you expect each fix to do to which
   test before trying it.
5. Try a fix. Run the failing tests. Don't manually retest in the
   simulator — make the test the authority.
6. **Don't commit anything until the user has verified.** The failure
   mode of the previous agent was committing eagerly between fix
   attempts. Hold changes uncommitted, push for user verification, only
   commit when confirmed.

## Things the previous agent didn't get to

- **Verify in a minimal SwiftUI playground project** whether
  `simultaneousGesture(LongPressGesture(0.34, 36).sequenced(before: DragGesture(0)))`
  on a row inside a `ScrollView` reproduces the gate timeout outside our
  codebase. If it does, this is a SwiftUI-level limitation and the
  custom-gesture / UIKit fallback paths are the only options.
- **Check whether iOS 26 / SwiftUI introduced new gesture coordination
  APIs** (e.g. `.exclusively(before:)` variants, `Gesture.fail` patterns,
  or new `.gesture(_:including:)` modes) that resolve this. The codebase
  targets iOS 26 minimum, so deprecated workarounds are fine to skip.
- **Look at the existing macOS path** in the same file — `macRowReorder`
  uses a plain `DragGesture(minimumDistance: 4)` without `LongPressGesture`
  at all, and the user reports it works well. The iOS path could
  potentially mirror it (with a longer `minimumDistance` or a manual
  press-duration check) and dispense with `LongPressGesture` entirely.

## Style + process notes

- Don't add comments that don't carry weight. Don't add CHANGELOG-style
  doc updates.
- Test changes go alongside fixes; don't ship a "test only" change first.
- The user explicitly asked for no eager commits. Hold work uncommitted
  until they've seen it work in their simulator.
- If you instrument with `NSLog`, use the `[CLI]` prefix and strip
  before committing.
- The docs at [`docs/drag-and-drop.md`](../docs/drag-and-drop.md) describe
  the intended UX. Update them only if your fix changes the contract.
