# Roadmap

What's left. The code (and `CLAUDE.md`) document _what was built_; this
file is for _what's left_.

## ✅ Done

- **M1** — Workspace + page list (read-only).
- **M3 + M4** — Per-block editing, autosave, multi-select keyboard model.
- **M5** — Markdown autotransforms (prefix triggers).
- **M6** — Inline formatting controls on macOS + iOS:
  Cmd-B/I/E/Shift-S toggle bold/italic/code/strikethrough on the current
  selection; iOS uses `AttributedTextSelection` plus a soft-keyboard
  accessory bar. Editor binding is `Binding<AttributedString>` so marks
  round-trip.
- **M7** — Gestures + drag handles: macOS row drag handles and row-level
  drag, iOS swipe delete/indent, iOS drag-reorder, pinch-open insert,
  pinch-close to page list, and workspace file-name search.
- **M8** — File change handling via `NSFilePresenter` + foreground
  re-scan.

**Recently shipped iOS work** (sits between M8 and M9):
- iPhone sidebar tap actually navigates (single persistent
  `NavigationSplitView`, selection-binding-driven push).
- iOS workspace switcher (sidebar toolbar button).
- iOS keyboard accessory bar with horizontal scroll + indent/outdent
  (so iPhone widths can't clip the controls).
- iOS now wraps `UITextView` directly (`IOSBlockTextEditorView`) — same
  shape as the macOS `MacBlockTextEditor`. Soft-keyboard Return splits
  the block (intercepted in `insertText("\n")`); soft-keyboard Backspace
  on a blank row collapses non-paragraphs to paragraph and removes
  paragraphs (intercepted in `deleteBackward()`). Mark toggles route
  through `IOSEditorBridge` against the UITextView's textStorage.
  Synchronous `becomeFirstResponder` in `didMoveToWindow` keeps the
  keyboard alive across row-to-row transfer.
- `InlineMarksKit` (was `InlineMarksNSKit` + `InlineMarksUIKit`) is now
  one cross-platform file with `PlatformFont` / `PlatformColor`
  typealiases.
- Two-step empty-row backspace: blank heading/bullet/etc. collapses to
  empty paragraph; empty paragraph removes the row.
- Page-level `MagnifyGesture` with a live gap preview drives
  pinch-to-insert. Functional but not Clear.app-grade — see M9 §3.
- Custom `IOSRowSwipeActions` (DragGesture-based) replaces SwiftUI's
  `.swipeActions`, which silently no-ops outside a `List`.

Carry-overs nibbling around the edges:
- Cross-block undo as a single op (split/merge/indent should coalesce).
- Backspace-at-0 merge into the previous non-empty row (currently no-op
  — distinct from the empty-row two-step that just landed).

---

## Next up

### M9 — Clear.app-grade iOS gestural polish

**Goal:** every iOS gesture feels inevitable and tactile — Clear.app
(2012) is the bar. Base plumbing for swipe-delete/swipe-indent,
pinch-open insert, pinch-close to page list, and long-press reorder
all work today, but mechanically: thresholds fire boolean actions with
no preview, no haptics, no springs. Done when each gesture has a
visible promise of its outcome before commit, a haptic at threshold,
and a spring at release.

**What "Clear-grade" means here:**

1. **Swipe progressive reveal.** `IOSRowSwipeActions` already tracks the
   finger and reveals an action label (trash / increase.indent) past the
   trigger. What's missing: icon scales from ~0.6 → 1.0 as distance
   approaches threshold, tint background deepens, icon pops to 1.05 +
   medium haptic at threshold cross. Release past threshold should
   animate the commit (row slides off-screen on left swipe, neighbours
   close the gap on a spring). Below-threshold release should
   rubber-band back via `interpolatingSpring(stiffness: 280, damping:
   22)` — currently snaps instantly because the offset is `@GestureState`
   only.

2. **Reorder lift + drift.** The current `.draggable` lift is the
   system default — flat chip preview, no haptic. Replace with an
   in-place lift: row scales to ~1.03, soft shadow, light haptic on
   lift. Adjacent rows shift to make room with a stagger; drop springs
   into place rather than the default ease. Likely needs UIKit
   `UIDragInteraction` via `UIViewRepresentable` since SwiftUI's stock
   lift isn't tunable.

3. **Pinch-open inline expansion polish.** A SwiftUI `MagnifyGesture` on
   the page chain already drives a live `pinchPreview` gap that opens
   between the two rows the gesture's `startLocation` falls between
   (`pinchInsertIndex` walks `rowFrames` to find the pair). Commit on
   release past `magnification > 1.18` runs `insertParagraph` and the
   gap-collapse inside one spring transaction so the new row appears in
   the open gap. **What's left:**

   - **Tactile feel.** Per-finger spread distance (rather than the
     scalar `magnification`) for tighter physics — promote to a UIKit
     `UIPinchGestureRecognizer` (reach via `UIViewRepresentable` host
     or `Introspect` style). Use `location(ofTouch: 0/1, in:)` to get
     the actual finger positions. Set `cancelsTouchesInView = false`
     and implement `gestureRecognizer(_:shouldRecognizeSimultaneouslyWith:)`
     so taps + `.draggable` still work alongside it.
   - **Haptics.** Light on gesture begin, medium when the gap crosses
     the commit threshold height, heavy on the actual commit.
   - **New-row entrance.** Currently SwiftUI's default opacity fade.
     Replace with a slide-from-gap or scale-in that reads as "the row
     materialised in the space you opened."
   - **Frame-rate fallback.** If the per-frame SwiftUI layout chokes on
     long documents, drop to `CALayer` transforms on a snapshotted row
     tree during the pinch (structural insert only on commit).

4. **Pinch-close to page list.** Currently `magnification < 0.82` calls
   `onPinchClose` which clears the open document. Promote to a
   coordinated morph: the page scales toward the page-list cell it came
   from, page list peeks through underneath, full commit on release
   past threshold. Below threshold, spring back to full size.

5. **Haptics layer.** Light at gesture begin, medium at threshold
   cross, heavy on commit. Use `UIImpactFeedbackGenerator` and
   `.prepare()` it on touch-down to avoid first-fire latency. Centralise
   in a thin `Haptics.swift` so call sites read clean.

**Files in scope:**

- `IOSRowSwipeActions` in `Packages/UI/Sources/UI/PageView.swift` —
  reveal animation, haptics, commit/rubber-band, threshold pop.
- `iosBlockTouchActions` — replace `.draggable` with custom UIKit lift
  if needed.
- `iosPagePinch` + `handlePinchUpdate` / `handlePinchCommit` /
  `pinchInsertIndex` in `PageView.swift` — promote to
  `UIPinchGestureRecognizer`, add haptics + entrance animation.
- New `Packages/UI/Sources/UI/Haptics.swift` — wrapper.

**Iteration loop:** iPhone simulator + a real device, side-by-side with
Clear.app on identical hardware. Record 60fps video for frame-by-frame
review — visual stutter at gesture boundaries is the only failure mode
that doesn't show up in screenshots. No automated assertion exists for
"feels right."

**Out of scope for M9:** macOS hover/drag polish. macOS is already
mouse-precise; the felt-quality gap is an iOS problem.

---

## Later

### Deferred editor affordances

- **Inline closing-trigger autotransforms:**
  `**bold**`, `*it*` / `_it_`, `` `code` ``, `~~strike~~`, `[text](url)`.
  Plug into `Autotransforms.swift`.
- **Pre-typing toggles:** Cmd-B with no selection should bias
  `typingAttributes` so the next typed character is bold. Same for
  italic/code/strike.
- Pull-down within a page → in-page search bar.
- Toggle children edit affordances (recursive renderer is read-only
  today).
- `.subpage(title, path)`: detect `[title](path.md)` paragraphs that
  resolve inside the workspace, render as a subpage row, push target on
  tap. Offer to create the file if missing.

### M2 — Pixel-correct Notion typography

**Goal:** screenshot diff vs each reference is visually indistinguishable
at 1× and 2×. Done when every `snap-diff` overlay reads as the same page
on both halves. The visual target is **pre-March-2026 Notion**; the four
reference screenshots in `References/typography/` are the source of
truth, *not* `react-notion-x`'s CSS.

**Still uncertain:**

- Heading→heading and heading→paragraph margins. Currently 28pt above an
  H2, 6pt below — guessed, not measured. Need a Notion reference shot
  with stacked headings.
- Quote, code, divider, toggle, subpage spacing. Untouched since
  `9b96acd`. No fixture exercises these yet.
- Inline H1 (30pt) and H3 (20pt) values are derived from `em` math, not
  measured. The `headings_and_bullets` fixture exercises both but lacks
  a Notion reference.

**Iteration loop:**

```sh
./scripts/use-fixture.sh <name>
xcodebuild -project Console.xcodeproj -scheme Console \
  -destination 'platform=macOS' -configuration Debug build
./scripts/snap-diff.sh <name>
open /tmp/console-screenshots/<name>-diff.png
```

Fixtures that mirror a Notion reference: `rfc_prompt`,
`notion_page_example`, `blog_post_draft`, `ai_for_docs`. Capture-only
(no Notion reference yet): `headings_and_bullets`.

Editing rules: only touch `NotionStyle.swift` and `BlockSpacing.swift`;
no magic numbers in `BlockRendering.swift`; don't touch `Packages/Core/`;
keep round-trip tests green.

---

## Out of scope (v1)

Tables (parse, render plain), images (parse, render placeholder),
real-time collab, in-content workspace search, dark mode, web clipping,
AI features, cross-block selection, find-and-replace, PDF export.

## Spawned-task chips

When a follow-up surfaces during a milestone that would bloat the
current change, spawn it as a separate task:

- **Round-corner inline code chip rendering** — replace flat
  `.backgroundColor` with a custom `TextRenderer` that paints a 3pt
  rounded background per run.
- **Shared text-view Coordinator base.** `MacBlockTextEditor.Coordinator`
  and `IOSBlockTextEditorView.Coordinator` have parallel structure
  (delegate text-change → autotransform check → undo register → push
  binding; focus boundaries break coalescing). Extract a tiny base or
  protocol to dedupe ~40 lines, but only if a third platform-specific
  text view shows up. Two parallel files read fine.
