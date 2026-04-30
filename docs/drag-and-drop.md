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

**Gesture** — `DragGesture(minimumDistance: 4, coordinateSpace: .named(PageHoverCoordinateSpace.name))` attached as a `simultaneousGesture` on both the gutter `DragHandle` and the row body. The 4pt threshold is what lets the row-body drag coexist with click-to-edit: a click without movement enters edit mode via `.onTapGesture`; movement past 4pt starts a drag instead. The gesture is gated off while `isEditing` is true so the editor's own selection drag isn't shadowed.

The handle is normally only hit-testable while the row is hovered. **During an active drag the handle's hit-testing is forced on for the source row**, even though `hoveredBlockID` shifts to whichever row the cursor is currently over. Without this, SwiftUI silently cancels the in-flight gesture (no `.onEnded` fires) the moment `allowsHitTesting(false)` flips on the still-tracking view, leaving the lift stuck on screen with no recovery. See `isMacDraggingFromRow(_:)` in [PageView.swift](../Packages/UI/Sources/UI/PageView.swift).

**Source frame freeze + anchor** — same pattern as iOS: `updateMacReorderLift` captures `sourceFrame`, `sourceIndex`, and `touchOffset` once on the first event, then only updates `location`. `touchOffset` uses `value.startLocation` here (no long-press, so it's where the click landed). Because the click typically lands in the gutter (left of `sourceFrame.minX`), `touchOffset.width` is negative — the cursor floats just left of the lift's leading edge throughout the drag, exactly as it sat against the gutter at click time.

**No drag preview from `.draggable`** — SwiftUI's `.draggable(_:preview:)` centers its preview on the cursor with no anchor control. We implement the lift as a SwiftUI `.overlay` on the page positioned by `.position(x:y:)` derived from `lift.location` and `lift.touchOffset`. This sacrifices cross-app drag (the system pasteboard isn't involved) — re-add `.draggable` separately if cross-app reorder ever becomes a goal.

**Cancellation** — SwiftUI's `DragGesture` only fires `.onEnded` on a successful drop. There's no public `.onCancel`. Today's safety nets:
1. The hit-testing override above (the most common cause of cancellation).
2. The drag is scoped to the DragHandle, which doesn't get unmounted during normal interaction.

If a cancellation path turns up that we haven't covered, the right escape hatch is an `NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp)` installed on lift-begin and torn down on lift-end — that fires regardless of whether SwiftUI's gesture is still tracking.

## Unified state (PageView)

A single `reorderLift: ReorderLift?` carries the lift across both platforms. Its fields are platform-agnostic:

- `block: Block` — the lead block, used for the lift overlay's content.
- `ids: [BlockID]` — every block participating in the drag (one for a single-row drag; the whole selection for a multi-block drag).
- `sourceFrame`, `sourceIndex`, `touchOffset`, `location` — geometry, frozen except for `location`.
- `pendingAnchor: Bool` — true while the lift is mounted but `touchOffset` is a placeholder waiting for a real cursor location. Set on iOS at long-press completion (where `LongPressGesture.Value` carries no location), cleared on the first `.second` drag event.

The shared methods are:

- `preliftReorder(blockID:snapshot:)` — pre-mounts the lift centered on the source row with `pendingAnchor: true`. iOS-only entry point (called from `onReorderBegin`).
- `tickReorderLift(blockID:at location:anchorAt anchor:snapshot:)` — per-event update. Creates the lift lazily if missing (macOS path), re-anchors `touchOffset` if pending, then sets `location` and recomputes `dropHoverIndex`. iOS passes `drag.location` for both `at` and `anchorAt`; macOS passes `value.location` for `at` and `value.startLocation` for `anchorAt` (the click point, before the 4pt minimum-distance kicked in).
- `endReorderLift(atY:snapshot:)` / `cancelReorderLift()` — both wrap their state changes (and `moveBlocks` in the end case) in one `Transaction(animation: nil, disablesAnimations: true)`.

`reorderDriftGap(for:)` and `reorderSourceOpacity(for:)` consult `reorderLift?.sourceIndex` and `reorderLift?.ids` directly — no `#if` fork. Multi-block drag dims all selected source rows on both platforms.

## Parity opportunities

Worth doing when next touching this code:

- **Mouse-up safety net on macOS.** Add the `NSEvent.addLocalMonitorForEvents(.leftMouseUp)` fallback so a cancellation we haven't anticipated doesn't leave the lift stuck.
- **Haptics on macOS where applicable** — feedback on lift begin and slot transitions, where the system supports it.
- **Reconsider the row-body drag's interaction with text selection in non-editing rows** if SwiftUI ever introduces inline text selection on read-only `Text` views. Today there's nothing to conflict with, but the 4pt drag threshold is a soft contract.

## Don't

- Don't reintroduce `.dropDestination` / `isTargeted` callbacks for the slot indicator. The page-level resolver against frozen frames is the fix; per-slot drop targets cause the buzzing pattern.
- Don't apply animations to the drop end. Wrapping `dropHoverIndex = nil`, `lift = nil`, and `moveBlocks(...)` in `Transaction(animation: nil, disablesAnimations: true)` is what keeps the post-drop reflow from springing.
- Don't recompute `touchOffset` against live `rowFrames[id]` — the source row's frame shifts during the drag (drift gap, document edits) and the lift will drift away from the cursor.
- Don't gate the source row's drag-source view on hover state alone during an in-flight drag (macOS) — the in-flight check has to keep the gesture-bearing view hit-testable.
