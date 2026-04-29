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

Carry-overs nibbling around the edges:
- Cross-block undo as a single op (split/merge/indent should coalesce).
- Backspace-at-0 merge into the previous non-empty row (currently no-op).

---

## Next up

### M9 — Clear.app-grade iOS gestural polish

**Goal:** every iOS gesture feels inevitable and tactile — Clear.app
(2012) is the bar. The plumbing for swipe-delete/swipe-indent,
pinch-open insert, pinch-close to page list, and long-press reorder is
in place but mechanical: thresholds fire boolean actions with no
preview, no haptics, no springs. Done when each gesture has a visible
promise of its outcome before commit, a haptic at threshold, and a
spring at release.

**What "Clear-grade" means here:**

1. **Swipe progressive reveal.** As the row tracks the finger, the
   action icon (trash / increase.indent) scales from ~0.6 → 1.0 and the
   tint background deepens as distance approaches threshold. Past
   threshold the icon pops to 1.05 and a medium haptic fires. Release
   past threshold animates the commit (row slides off-screen on left
   swipe, indent ramps in on right swipe; neighbour rows close the gap
   on a spring). Below threshold, rubber-band back with
   `interpolatingSpring(stiffness: 280, damping: 22)`.

2. **Reorder lift + drift.** The current `.draggable` lift is the
   system default — flat chip preview, no haptic. Replace with an
   in-place lift: row scales to ~1.03, soft shadow, light haptic on
   lift. Adjacent rows shift to make room with a stagger; drop springs
   into place rather than the default ease. Likely needs UIKit
   `UIDragInteraction` via `UIViewRepresentable` since SwiftUI's stock
   lift isn't tunable.

3. **Pinch-open inline expansion.** This is the hard one and the
   reason M9 exists as its own milestone — neither the gap-target nor
   row-attached `MagnifyGesture` worked because SwiftUI's `MagnifyGesture`
   gives a single scalar (magnification) with no per-finger position
   info, and a bare `.gesture` on a row that's also `.draggable` /
   `.onTapGesture` loses arbitration. Real shape:

   - **Page-level recognizer.** A UIKit `UIPinchGestureRecognizer`
     installed on the page's underlying `UIScrollView` (reach via
     `UIViewRepresentable` host wrapping the SwiftUI tree, or
     `Introspect`-style scrollview lookup). Set `cancelsTouchesInView =
     false` so taps and `.draggable` still work. Implement
     `gestureRecognizer(_:shouldRecognizeSimultaneouslyWith:)` to
     coexist with the scroll-view's pan and the editor's text gestures.
   - **Two-finger position math.** From the recognizer get
     `location(ofTouch: 0/1, in: scrollContentView)`. The midpoint
     between the two fingers in document coordinates is the insert
     anchor. Look up which adjacent row pair it falls between using
     the `rowFrames` preference dict the page already maintains
     ([PageView.swift](Packages/UI/Sources/UI/PageView.swift)
     `RowFramePreferenceKey`). The vertical distance between the two
     fingers (or the recognizer's `scale` × initial distance) drives
     the gap-open amount.
   - **Live gap.** During the pinch, push a state that inserts a
     phantom row of variable height between the two adjacent rows.
     SwiftUI re-layout per frame is fine for content this size, but if
     it stutters, drop down to `CALayer` transforms on a snapshotted
     row tree (do the structural insert only on commit; during the
     pinch, animate transforms on existing layers).
   - **Commit / cancel.** Past a pixel threshold (e.g., gap height ≥
     row height) on `.ended`, do the real `insertParagraph(at:)` and
     fade the new block's text into focus. Below threshold, spring the
     gap closed.
   - **Edge cases.** Pinch that starts inside an editing block —
     ignore. Pinch where one finger is on a row and the other is below
     the last row — insert at end. Pinch that converges (close
     gesture) instead of diverges — fall through to
     `iosPinchCloseToPageList`.

4. **Pinch-close to page list.** Currently `magnification < 0.82` snaps
   back to the sidebar. Promote to a coordinated morph: the page scales
   toward the page-list cell it came from, page list peeks through
   underneath, full commit on release past threshold. Below threshold,
   spring back to full size.

5. **Haptics layer.** Light at gesture begin, medium at threshold
   cross, heavy on commit. Use `UIImpactFeedbackGenerator` and
   `.prepare()` it on touch-down to avoid first-fire latency. Centralise
   in a thin `Haptics.swift` so call sites read clean.

**Files in scope:**

- `IOSRowSwipeActions` in `Packages/UI/Sources/UI/PageView.swift` —
  reveal animation, haptics, commit/rubber-band, threshold pop.
- `iosBlockTouchActions` — replace `.draggable` with custom UIKit lift
  if needed.
- `iosPinchOpenToInsert` — track magnification live, open an inline gap.
- `iosPinchCloseToPageList` — morph coordinated with the parent
  `NavigationSplitView`.
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
