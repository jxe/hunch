import SwiftUI

// MARK: - Pinch-open-to-insert (iOS)

extension EditorView {
    static var pinchInsertCommitGap: CGFloat { 40 }
    static var pinchInsertFocusGap: CGFloat { 110 }

    /// Soft asymptote past `soft` — gap continues to track fingers but tightens
    /// toward `max`. Replaces a hard clamp, which feels dead at the limit.
    fileprivate func pinchRubberBand(_ x: CGFloat, soft: CGFloat = 140, max: CGFloat = 240) -> CGFloat {
        guard x > soft else { return x }
        let over = x - soft
        let range = max - soft
        return soft + range * (1 - 1 / (1 + over / range))
    }

    /// Track the live finger spread: above the starting distance, open an inline
    /// gap at the row pair under the current midpoint; below the starting
    /// distance, no insert preview (pinch-close commits on release).
    func handlePinchUpdate(_ value: PagePinchValue) {
        pinchGestureActive = true
        guard state.editingBlock == nil else {
            if state.pinchPreview != nil { state.setPinchPreview(nil) }
            pinchPendingInsertIndex = nil
            stopPinchAutoScroll()
            return
        }
        updatePinchAutoScroll(for: value.location)
        if value.spreadDelta > 0 {
            let gapHeight = pinchRubberBand(value.spreadDelta)
            // Compute the insert index lazily on the first spread-positive update,
            // before the gap opens and starts shifting rowFrames. After that, hold
            // it fixed so the gap stays anchored where the user started pinching.
            let insertIndex = pinchPendingInsertIndex ?? pinchInsertIndex(for: value.startLocation)
            pinchPendingInsertIndex = insertIndex
            state.setPinchPreview(PinchPreviewState(insertIndex: insertIndex, gapHeight: gapHeight))
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
            state.setPinchPreview(nil)
            pinchPendingInsertIndex = nil
            pinchCrossedInsertThreshold = false
            pinchCrossedFocusThreshold = false
        }
    }

    func handlePinchCommit(_ value: PagePinchValue) {
        let preview = state.pinchPreview
        let gap = preview?.gapHeight ?? pinchRubberBand(max(0, value.spreadDelta))

        if gap >= Self.pinchInsertCommitGap, state.editingBlock == nil {
            let insertIndex = pinchPendingInsertIndex
                ?? preview?.insertIndex
                ?? pinchInsertIndex(for: value.startLocation)
            // Tier 1 (smaller pinch): pick a kind based on neighbors.
            // Tier 2 (larger pinch, past the second threshold): always H1.
            // Both tiers focus the new block.
            let newBlock: Block = (gap >= Self.pinchInsertFocusGap)
                ? .heading(level: 1, text: AttributedString())
                : smartInsertBlock(at: insertIndex)
            // Bundle the structural insert and the gap collapse into the same
            // spring transaction so the new row appears inside the opened gap
            // and the surrounding rows close in around it. Without the shared
            // animation transaction the gap snap-closes first and the new row
            // pops in afterwards — visually disjoint.
            Haptics.heavy()
            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                insertBlock(newBlock, at: insertIndex, focus: true)
                state.setPinchPreview(nil)
            }
        } else {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) {
                state.setPinchPreview(nil)
            }
        }
        pinchPendingInsertIndex = nil
        pinchCrossedInsertThreshold = false
        pinchCrossedFocusThreshold = false
        pinchGestureActive = false
        stopPinchAutoScroll()
    }

    fileprivate func updatePinchAutoScroll(for location: CGPoint) {
        let threshold: CGFloat = 88
        let maxVelocity: CGFloat = 520
        let viewportHeight = scrollMetrics.viewportHeight
        guard viewportHeight > threshold * 2 else {
            stopPinchAutoScroll()
            return
        }

        let topDistance = location.y
        let bottomDistance = viewportHeight - location.y
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

    fileprivate func scrollBy(_ deltaY: CGFloat) {
        let maxOffset = max(0, scrollMetrics.contentHeight - scrollMetrics.viewportHeight)
        let nextOffset = min(maxOffset, max(0, scrollMetrics.contentOffsetY + deltaY))
        guard abs(nextOffset - scrollMetrics.contentOffsetY) > 0.5 else { return }
        #if os(iOS)
        PageScrollController.shared.scroll(toY: nextOffset)
        #endif
    }

    /// The insert index for a pinch whose start midpoint is at `point` (in the
    /// page's hover-named coordinate space — same space rowFrames live in).
    /// Returns the index of the first row whose mid-Y is below the point; if
    /// every row sits above the point, returns `blocks.count` (insert at end).
    fileprivate func pinchInsertIndex(for point: CGPoint) -> Int {
        let blocks = document.blocks
        guard !blocks.isEmpty else { return 0 }
        for (i, block) in blocks.enumerated() {
            if let frame = rowFrames[block.id], point.y < frame.midY {
                return i
            }
        }
        return blocks.count
    }
}
