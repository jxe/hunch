# Improve iOS Drag And Drop

## Goal

Make iOS block drag-and-drop feel native and dependable: clear lift,
predictable insertion targeting, stable scrolling, and no accidental edit
entry while dragging.

## Current Behavior

First-pass reorder drift exists: targeted drop slots open a small springy
gap while SwiftUI's stock long-tap drag remains in charge.

Still missing:

- Replace SwiftUI's stock drag preview with a custom lift if needed.
- Row scale/shadow and lift haptic.
- Staggered adjacent row motion during hover.
- Tuned drop spring instead of the default drag stack feel.
- Robust edge-scroll behavior during long drags.

## Desired Behavior

- Long-pressing a row lifts it without entering edit mode.
- The lifted row has a visible scale/shadow treatment and a light haptic.
- Candidate drop slots open before commit, with enough gap to make the
  result obvious.
- Neighboring rows move smoothly and settle with a spring.
- Dragging near the top or bottom scrolls the page at a controllable pace.
- Dropping commits exactly once and leaves selection/edit focus in a
  coherent state.
- Cancelling returns the row to its original position without side effects.

## Agent Loop

1. Build the iOS simulator target:

   ```sh
   xcodebuild -project Console.xcodeproj -scheme Console -destination 'generic/platform=iOS Simulator' -configuration Debug build
   ```

2. Use a deterministic sample document with stable row text:
   `Alpha`, `Bravo`, `Charlie`, `Delta`, `Echo`, `Foxtrot`.

3. Add or preserve accessibility hooks that make the UI inspectable:
   stable row identifiers, stable drag-handle identifiers if handles
   exist, and readable labels for the block text.

4. Drive focused XCUITest gesture scenarios where possible:
   long-press `Bravo`, drag below `Delta`, release, then assert the
   visible/accessibility order. Repeat for upward drag, cancelled drag,
   and edge-scroll drag.

5. When automation is inconclusive, run the simulator, capture screenshot
   or video evidence, inspect logs, patch, and repeat. Keep temporary
   `[CLI]` logging local to the investigation and remove it before
   committing.

6. Finish with a short manual pass for feel:
   lift latency, insertion confidence, haptic timing, spring quality,
   edge-scroll pace, accidental edit-entry rate, and iPhone vs iPad feel.

## Files In Scope

- `Packages/UI/Sources/UI/PageView.swift`
- `iosBlockTouchActions`
- Any small iOS-only helper needed for haptics, lift previews, or
  gesture bridging.

## Notes

Prefer a simulator-driven loop plus accessibility assertions over broad
unit coverage. The hard part here is gesture integration and felt
behavior, not pure block-array mutation.

