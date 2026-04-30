# iOS Drag And Drop Notes

## Slot Resolution

iOS reorder hover state is resolved at the page level from row frames, not
from competing row and gap drop targets. This avoids the buzzing pattern
where opening a gap changes hit-testing, which changes the active target,
which closes the gap again.

`ReorderDropResolver` maps pointer `y` to an insertion index using row
midlines and a small hysteresis band. Add tests there before changing hover
math.

## Visual Feedback

The open gap is the drop affordance. Avoid separate accent bars or blue
target areas unless they are tied to the same resolver state; extra
drop visuals can drift away from the actual insertion decision.

The lifted row should read as the row itself, slightly enlarged, without a
card treatment or shadow.

## Custom Lift

iOS reorder does not use SwiftUI `.draggable`. SwiftUI's standard drag
preview controls its own scale, anchor, and lift/drop behavior, which made
the row preview smaller and disconnected from the finger.

The row uses a sequenced long-press/drag gesture. During the drag,
`PageView` renders a separate `BlockRow` overlay for the lifted row, dims
the source row, scales the overlay slightly, and positions it from the
original touch offset so the same point remains under the finger.

Keep the reorder gesture simultaneous with row swipe actions so short
horizontal swipes can still win before the long press completes.
