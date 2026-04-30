# Drag and drop

How block reorder works on iOS and macOS, and what's shared vs platform-specific.

## Goals

The same UX on both platforms:

- The dragged row "lifts" — a copy of the row appears as a slight enlargement (×1.035) where you grabbed it. The cursor / finger stays anchored at the original grab point inside the lift for the entire drag, no drift.
- The original row dims (opacity 0.12) so it reads as "in flight."
- A 42pt gap springs open at the candidate drop slot. This gap *is* the drop indicator — no separate accent bars or highlight rectangles.
- The gap does **not** open at the source row's own slot (its index or index+1) because dropping there is a no-op.
- On drop, the gap closes and the row reorders with **no** animation: row positions, the gap, and the lift all clear inside a single `Transaction(animation: nil, disablesAnimations: true)`.

What's **deliberately not** in the design: shadows, card treatments, rotation, pulsing, magnification of neighbours, ghost blocks at the destination. The lift reads as the row itself, and the gap reads as where it'll go.

## Drop slot resolution (shared)

Both platforms resolve the candidate insertion index the same way: `ReorderDropResolver.insertionIndex(forY:rowFrames:previousIndex:hysteresis:)` ([ReorderDropResolver.swift](../Packages/UI/Sources/UI/ReorderDropResolver.swift)).

It maps the pointer's y-coordinate to a slot by counting how many rows have a midY above it, with a 10pt hysteresis band so a pointer hovering near a row boundary doesn't oscillate between two slots. `rowFrames` is published from the live layout via `RowFramePreferenceKey`, so dimensions track wrapping/edits.

Earlier iterations used per-slot `.dropDestination` / `isTargeted` callbacks — those produced a "buzzing" pattern where opening a gap shifted hit-testing, which closed the gap, which shifted hit-testing back. The page-level resolver against frozen frames is what fixed it.

Tests live next to `ReorderDropResolver`. Add coverage there before touching hover math.

## iOS

**Gesture** — `LongPressGesture(minimumDuration: 0.34, maximumDistance: 36)` sequenced before `DragGesture(minimumDistance: 0)`, attached as a `simultaneousGesture` to the row body via `IOSRowReorderActions`. The long-press is what distinguishes a reorder intent from a tap-to-edit; the drag-gesture half tracks the finger after the long-press completes.

**Source frame freeze** — when the lift first materialises (first `.second` event from the sequence), `updateIOSReorderLift` captures `sourceFrame`, `sourceIndex`, and `touchOffset` once and re-uses them for the duration of the drag. Subsequent events update only `lift.location`. If we instead read `rowFrames[id]` on each event, the lift would drift downward as the 42pt drift gap animates open above the source — every recomputed `touchOffset.height = startLocation.y - sourceFrame.minY` would be smaller than the last.

**Touch offset uses `drag.location`, not `drag.startLocation`** — during the 0.34s long-press the finger may drift up to 36pt within the long-press tolerance. Anchoring touchOffset to `drag.location` (where the finger is at lift time) keeps the lift under the *current* finger position, not the original press point.

**Cancellation** — the sequenced gesture exposes `.onEnded` for both successful drops and cancels. `onReorderCancel` clears state if the long-press fires but the drag never produces a `.second` event.

**Coexistence** — `simultaneousGesture` lets the row's swipe-actions still fire short horizontal swipes before the long-press completes. The pinch-to-insert gesture is disabled while a reorder drag is active (`pinchGestureActive` flag) so the two don't fight for the same touch.

**Haptics** — `Haptics.light()` fires on lift begin and on each `dropHoverIndex` slot transition.

## macOS

**Gesture** — `DragGesture(minimumDistance: 4, coordinateSpace: .named(PageHoverCoordinateSpace.name))` attached as a `simultaneousGesture` on the gutter `DragHandle` only (not the row body — clicking the row body still enters edit mode). 4pt of movement is enough to distinguish a click from a drag.

The handle is normally only hit-testable while the row is hovered. **During an active drag the handle's hit-testing is forced on for the source row**, even though `hoveredBlockID` shifts to whichever row the cursor is currently over. Without this, SwiftUI silently cancels the in-flight gesture (no `.onEnded` fires) the moment `allowsHitTesting(false)` flips on the still-tracking view, leaving the lift stuck on screen with no recovery. See `isMacDraggingFromRow(_:)` in [PageView.swift](../Packages/UI/Sources/UI/PageView.swift).

**Source frame freeze + anchor** — same pattern as iOS: `updateMacReorderLift` captures `sourceFrame`, `sourceIndex`, and `touchOffset` once on the first event, then only updates `location`. `touchOffset` uses `value.startLocation` here (no long-press, so it's where the click landed). Because the click typically lands in the gutter (left of `sourceFrame.minX`), `touchOffset.width` is negative — the cursor floats just left of the lift's leading edge throughout the drag, exactly as it sat against the gutter at click time.

**No drag preview from `.draggable`** — SwiftUI's `.draggable(_:preview:)` centers its preview on the cursor with no anchor control. We implement the lift as a SwiftUI `.overlay` on the page positioned by `.position(x:y:)` derived from `lift.location` and `lift.touchOffset`. This sacrifices cross-app drag (the system pasteboard isn't involved) — re-add `.draggable` separately if cross-app reorder ever becomes a goal.

**Cancellation** — SwiftUI's `DragGesture` only fires `.onEnded` on a successful drop. There's no public `.onCancel`. Today's safety nets:
1. The hit-testing override above (the most common cause of cancellation).
2. The drag is scoped to the DragHandle, which doesn't get unmounted during normal interaction.

If a cancellation path turns up that we haven't covered, the right escape hatch is an `NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp)` installed on lift-begin and torn down on lift-end — that fires regardless of whether SwiftUI's gesture is still tracking.

## What lives in `PageView.swift` (today)

- `iosReorderLift: IOSReorderLift?` / `macReorderLift: MacReorderLift?` — separate state, identical fields (`block`, `sourceFrame`, `sourceIndex`, `touchOffset`, `location`).
- `iosReorderLiftView()` / `macReorderLiftView()` — separate overlays, identical body.
- `updateIOSReorderLift(...)` / `updateMacReorderLift(...)` — separate update paths, identical "first call freezes, subsequent calls only update location" logic.
- `reorderDriftGap(for:)` — shared, dispatches to `iosReorderLift?.sourceIndex` or `macReorderLift?.sourceIndex` via `#if`.
- `reorderSourceOpacity(for:)` — shared, dispatches to `activeIOSReorderIDs` (a set, since iOS supports multi-block drag) or `macReorderLift?.block.id` (single).

## Parity opportunities

Worth doing when next touching this code:

- **Unify the lift struct, state, view, and update function.** The fields and logic are identical; only the *trigger* differs (sequenced long-press vs. plain drag). A single `reorderLift: ReorderLift?` plus a single `reorderLiftView()` would remove three pairs of near-duplicates. The only platform fork is which gesture sets it.
- **Multi-block drag on macOS.** iOS already drags the entire selection via `dragIDs(for:)` and `activeIOSReorderIDs`. macOS currently drags only the single block, dropping a multi-selection silently. Carrying `ids: [BlockID]` on `MacReorderLift` (and dimming all of them in `reorderSourceOpacity`) would close the gap.
- **Mouse-up safety net on macOS.** Add the `NSEvent.addLocalMonitorForEvents(.leftMouseUp)` fallback so a cancellation we haven't anticipated doesn't leave the lift stuck.
- **macOS row-body drag.** Currently only the gutter handle initiates a drag on macOS. The row body could too (with `minimumDistance: 4` it wouldn't conflict with click-to-edit), matching iOS where the whole row is the drag source.
- **Haptics on macOS where applicable** — feedback on lift begin and slot transitions, where the system supports it.

## Don't

- Don't reintroduce `.dropDestination` / `isTargeted` callbacks for the slot indicator. The page-level resolver against frozen frames is the fix; per-slot drop targets cause the buzzing pattern.
- Don't apply animations to the drop end. Wrapping `dropHoverIndex = nil`, `lift = nil`, and `moveBlocks(...)` in `Transaction(animation: nil, disablesAnimations: true)` is what keeps the post-drop reflow from springing.
- Don't recompute `touchOffset` against live `rowFrames[id]` — the source row's frame shifts during the drag (drift gap, document edits) and the lift will drift away from the cursor.
- Don't gate the source row's drag-source view on hover state alone during an in-flight drag (macOS) — the in-flight check has to keep the gesture-bearing view hit-testable.
