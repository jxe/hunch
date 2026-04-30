# iOS Gestural Polish

## Goal

Every iOS gesture should feel tactile and inevitable. Swipe delete,
swipe indent, pinch-open insert, pinch-close to page list, and long-press
reorder all have base plumbing today; the remaining work is preview,
haptics, springs, and release behavior.

## Swipe Progressive Reveal

`IOSRowSwipeActions` already tracks the finger and reveals an action label
past the trigger.

Still missing:

- Icon scales from roughly `0.6` to `1.0` as distance approaches threshold.
- Tint background deepens with distance.
- Icon pops to roughly `1.05` and fires a medium haptic at threshold.
- Release past threshold animates the commit: row slides off-screen on
  left swipe, neighbors close the gap on a spring.
- Below-threshold release rubber-bands back via
  `interpolatingSpring(stiffness: 280, damping: 22)` instead of snapping.

## Pinch-Open Inline Expansion

Current state: SwiftUI `MagnifyGesture` drives a live `pinchPreview` gap.
Commit past the gap-height threshold inserts a paragraph and collapses the
gap inside one spring transaction. Medium/heavy haptics fire on threshold
cross and commit.

Still missing:

- Tighter tactile feel from per-finger spread distance rather than scalar
  magnification.
- New-row entrance that reads as materializing in the opened space.
- Fallback to `CALayer` transforms on a snapshotted row tree if long
  documents choke on per-frame SwiftUI layout.

## Pinch-Close To Page List

Current state: `magnification < 0.82` calls `onPinchClose` and clears the
open document.

Desired behavior: page scales toward the page-list cell it came from,
the page list peeks through underneath, release past threshold commits,
and below-threshold release springs back to full size.

## Haptics Layer

Add a thin `Haptics.swift` wrapper so call sites read cleanly:
light at gesture begin, medium at threshold cross, heavy on commit.
Prepare generators on touch-down to avoid first-fire latency.

## Files In Scope

- `Packages/UI/Sources/UI/PageView.swift`
- `IOSRowSwipeActions`
- `iosPagePinch`
- `handlePinchUpdate`
- `handlePinchCommit`
- `pinchInsertIndex`
- `Packages/UI/Sources/UI/Haptics.swift`
