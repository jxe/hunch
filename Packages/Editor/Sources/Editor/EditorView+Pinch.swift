import SwiftUI

// MARK: - Pinch-open-to-insert (iOS)

extension EditorView {
    static var pinchInsertCommitGap: CGFloat { 40 }
    static var pinchInsertFocusGap: CGFloat { 110 }
    /// Spread distance the user must cross before any gap or insertion-anchor
    /// commitment happens. Two reasons: (1) UIPinchGestureRecognizer.began
    /// fires only after its internal threshold is crossed, so the first
    /// `.changed` already arrives with `spreadDelta` in the 5–15 px range —
    /// without a deadzone the gap pops open visibly instead of growing from 0.
    /// (2) Fingers naturally drift while spreading (typically downward), so
    /// reading the midpoint at gesture start picks the wrong row; waiting
    /// until the gesture is clearly committed lets us read a settled location.
    static var pinchOpenDeadzone: CGFloat { 12 }

    /// Extra top-padding to reveal an opening pinch-gap above the row at
    /// `index`. Zero unless the active pinch preview is targeting that slot.
    func pinchExtraGap(forIndex index: Int) -> CGFloat {
        guard let preview = state.pinchPreview, preview.insertIndex == index else { return 0 }
        return preview.gapHeight
    }

    /// Soft asymptote past `soft` — gap continues to track fingers but tightens
    /// toward `max`. Replaces a hard clamp, which feels dead at the limit.
    fileprivate func pinchRubberBand(_ x: CGFloat, soft: CGFloat = 140, max: CGFloat = 240) -> CGFloat {
        guard x > soft else { return x }
        let over = x - soft
        let range = max - soft
        return soft + range * (1 - 1 / (1 + over / range))
    }

    /// Track the live finger spread: once the spread crosses `pinchOpenDeadzone`,
    /// open an inline gap at the row pair under the current midpoint; below
    /// that threshold the gesture is treated as not-yet-committed, so no
    /// preview opens and other gestures stay armed. Once the deadzone has
    /// been crossed at any point in the session, `pinchGestureActive` stays
    /// latched until `handlePinchCommit` clears it (so a brief pinch-back
    /// doesn't re-enable reorder/swipe mid-gesture). Pinch-close commits on
    /// release.
    func handlePinchUpdate(_ value: PagePinchValue) {
        guard state.editingBlock == nil else {
            if state.pinchPreview != nil { state.setPinchPreview(nil) }
            pinchPendingInsertIndex = nil
            stopPinchAutoScroll()
            return
        }
        if value.spreadDelta >= Self.pinchOpenDeadzone {
            pinchGestureActive = true
            updatePinchAutoScroll(for: value.location)
            // Subtract the deadzone so the gap opens at exactly 0 px when the
            // user first crosses the threshold and grows smoothly from there.
            let gapHeight = pinchRubberBand(value.spreadDelta - Self.pinchOpenDeadzone)
            // Compute insertIndex once at deadzone-crossing, from the CURRENT
            // midpoint (not value.startLocation). At this moment the gap hasn't
            // opened so rowFrames are still pre-shift, AND the user's fingers
            // have settled past whatever drift happened during recognizer
            // ramp-up. Anchor it for the rest of the gesture so the gap stays
            // put even as more layout shifts happen.
            let insertIndex = pinchPendingInsertIndex ?? pinchInsertIndex(for: value.location)
            let isFirstOpen = state.pinchPreview == nil
            pinchPendingInsertIndex = insertIndex
            let preview = PinchPreviewState(insertIndex: insertIndex, gapHeight: gapHeight)
            if isFirstOpen {
                // Smooth the nil → open transition. Subsequent updates stay
                // unanimated so the gap tracks fingers in real time.
                withAnimation(.spring(response: 0.18, dampingFraction: 0.85)) {
                    state.setPinchPreview(preview)
                }
            } else {
                state.setPinchPreview(preview)
            }
            if gapHeight >= Self.pinchInsertCommitGap, !pinchCrossedInsertThreshold {
                pinchCrossedInsertThreshold = true
                Haptics.medium()
                SoundFX.play(.pinchOpen)
            } else if gapHeight < Self.pinchInsertCommitGap {
                pinchCrossedInsertThreshold = false
            }
            if gapHeight >= Self.pinchInsertFocusGap, !pinchCrossedFocusThreshold {
                pinchCrossedFocusThreshold = true
                Haptics.medium()
                SoundFX.play(.pinchOpen)
            } else if gapHeight < Self.pinchInsertFocusGap {
                pinchCrossedFocusThreshold = false
            }
        } else if state.pinchPreview != nil {
            // Pinched back below deadzone after opening — close the preview
            // visually but keep `pinchGestureActive` latched so a re-open
            // doesn't ping-pong the swipe/reorder gates.
            withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
                state.setPinchPreview(nil)
            }
            clearPinchThresholds()
        }
    }

    /// Reset the pinch's per-gesture bookkeeping (insert-slot anchor + the
    /// two threshold-crossed latches). The preview state itself is owned by
    /// `EditorState.pinchPreview` and cleared separately.
    private func clearPinchThresholds() {
        pinchPendingInsertIndex = nil
        pinchCrossedInsertThreshold = false
        pinchCrossedFocusThreshold = false
    }

    func handlePinchCommit(_ value: PagePinchValue) {
        let preview = state.pinchPreview
        let gap = preview?.gapHeight ?? pinchRubberBand(max(0, value.spreadDelta))

        if gap >= Self.pinchInsertCommitGap, state.editingBlock == nil {
            let slot = pinchPendingInsertIndex
                ?? preview?.insertIndex
                ?? pinchInsertIndex(for: value.startLocation)
            // Resolve the visible slot to a tree DropPath, with the visible-row
            // above/below at that slot as neighbour context for kind inference.
            let hidden = hiddenBlockIDs(in: document.children)
            let rows = computeVisibleLayout(snapshot: document.children, hidden: hidden)
            let path = dropPath(forVisibleSlot: slot, rows: rows)
            let above: Block? = (slot - 1 >= 0 && slot - 1 < rows.count) ? rows[slot - 1].block : nil
            let below: Block? = (slot >= 0 && slot < rows.count) ? rows[slot].block : nil
            // Tier 1 (smaller pinch): pick a kind based on neighbours.
            // Tier 2 (larger pinch, past the second threshold): always H1.
            // Both tiers focus the new block.
            let newBlock: Block = (gap >= Self.pinchInsertFocusGap)
                ? .heading(level: 1, text: AttributedString())
                : smartInsertBlock(above: above, below: below)
            // Bundle the structural insert and the gap collapse into the same
            // spring transaction so the new row appears inside the opened gap
            // and the surrounding rows close in around it. Without the shared
            // animation transaction the gap snap-closes first and the new row
            // pops in afterwards — visually disjoint.
            Haptics.heavy()
            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                insertBlock(newBlock, at: path, focus: true)
                state.setPinchPreview(nil)
            }
        } else {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) {
                state.setPinchPreview(nil)
            }
        }
        clearPinchThresholds()
        pinchGestureActive = false
        stopPinchAutoScroll()
    }

    fileprivate func updatePinchAutoScroll(for location: CGPoint) {
        let threshold: CGFloat = 88
        let maxVelocity: CGFloat = 520
        let effectiveBottom = scrollMetrics.viewportHeight - scrollMetrics.topInset - scrollMetrics.bottomInset
        guard effectiveBottom > threshold * 2 else {
            stopPinchAutoScroll()
            return
        }

        let topDistance = location.y
        let bottomDistance = effectiveBottom - location.y
        let velocity: CGFloat
        if topDistance < threshold {
            let progress = min(1, max(0, (threshold - topDistance) / threshold))
            velocity = -maxVelocity * progress * progress
        } else if bottomDistance < threshold {
            let progress = min(1, max(0, (threshold - bottomDistance) / threshold))
            velocity = maxVelocity * progress * progress
        } else {
            velocity = 0
        }

        pinchAutoScrollVelocity = velocity
        if abs(velocity) > 1 {
            startPinchAutoScrollIfNeeded()
        } else {
            stopPinchAutoScroll()
        }
    }

    fileprivate func startPinchAutoScrollIfNeeded() {
        guard pinchAutoScrollTask == nil else { return }
        pinchAutoScrollTask = Task { @MainActor in
            let frameDuration: TimeInterval = 1.0 / 60.0
            while !Task.isCancelled {
                let velocity = pinchAutoScrollVelocity
                if abs(velocity) <= 1 { break }
                scrollBy(velocity * frameDuration)
                try? await Task.sleep(for: .milliseconds(16))
            }
            pinchAutoScrollTask = nil
        }
    }

    fileprivate func stopPinchAutoScroll() {
        pinchAutoScrollVelocity = 0
        pinchAutoScrollTask?.cancel()
        pinchAutoScrollTask = nil
    }

    /// Programmatic scroll by `deltaY` pixels — clamped to content extent. Shared
    /// by pinch and reorder auto-scroll. iOS routes through the UIScrollView
    /// bridge populated by `IOSScrollMetricsReader`; macOS uses SwiftUI's
    /// `ScrollPosition` populated alongside it.
    func scrollBy(_ deltaY: CGFloat) {
        let maxOffset = max(0, scrollMetrics.contentHeight - scrollMetrics.viewportHeight)
        let nextOffset = min(maxOffset, max(0, scrollMetrics.contentOffsetY + deltaY))
        guard abs(nextOffset - scrollMetrics.contentOffsetY) > 0.5 else { return }
        #if os(iOS)
        PageScrollController.shared.scroll(toY: nextOffset)
        #else
        scrollPosition.scrollTo(point: CGPoint(x: 0, y: nextOffset))
        #endif
    }

    /// The insert slot for a pinch whose midpoint is at `point` (page hover
    /// coordinate space — same space rowFrames live in). Returns a *visible-row
    /// slot index*, 0...visibleRows.count: the same space `dropPath` and the
    /// drag-drop indicator speak. Walks the visible-row stack (so nested rows
    /// participate) and resolves via `ReorderDropResolver` for parity with the
    /// reorder gesture.
    fileprivate func pinchInsertIndex(for point: CGPoint) -> Int {
        let hidden = hiddenBlockIDs(in: document.children)
        let rows = computeVisibleLayout(snapshot: document.children, hidden: hidden)
        return resolveDropSlot(forY: point.y, in: rows)
    }
}
