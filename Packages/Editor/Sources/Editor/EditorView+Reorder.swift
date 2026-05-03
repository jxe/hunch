import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - Reorder lift, drop targets, and block-move helpers

extension EditorView {
    func orderedDropFrames(snapshot: [Block]) -> [ReorderDropFrame] {
        snapshot.compactMap { block in
            rowFrames[block.id].map { ReorderDropFrame(id: block.id, frame: $0) }
        }
    }

    func reorderDriftGap(for index: Int) -> CGFloat {
        guard state.dropHoverIndex == index else { return 0 }
        // Dropping the source row at its own slot is a no-op — don't open a
        // gap there. (Also avoids layout churn that would destabilise the
        // lift's frozen sourceFrame.)
        if let lift = state.reorderLift,
           index >= lift.sourceIndex && index <= lift.sourceEndIndex + 1 {
            return 0
        }
        return 42
    }

    func reorderSourceOpacity(for id: BlockID) -> Double {
        guard let lift = state.reorderLift, lift.ids.contains(id) else { return 1 }
        // Option-drag duplicates — keep originals fully visible so the user
        // sees both the source and the floating ghost at once.
        return lift.isCopy ? 1 : 0.12
    }

    func isMacDraggingFromRow(_ id: BlockID) -> Bool {
        #if os(macOS)
        return state.reorderLift?.ids.contains(id) == true
        #else
        return false
        #endif
    }

    @ViewBuilder
    func reorderLiftView() -> some View {
        if let lift = state.reorderLift {
            BlockRow(
                block: .constant(lift.block),
                editorFocused: $editorFocused,
                isPageTitle: false,
                numberingIndex: nil,
                isSelected: false,
                isEditing: false,
                pageTitle: pageTitle
            )
            .frame(width: lift.sourceFrame.width, height: lift.sourceFrame.height, alignment: .leading)
            .overlay(alignment: .topLeading) {
                if lift.isCopy {
                    copyBadge
                        .offset(x: -10, y: -10)
                }
            }
            .scaleEffect(1.035)
            .position(
                x: lift.location.x - lift.touchOffset.width + (lift.sourceFrame.width / 2),
                y: lift.location.y - lift.touchOffset.height + (lift.sourceFrame.height / 2)
            )
            .allowsHitTesting(false)
            .zIndex(100)
        }
    }

    private var copyBadge: some View {
        Image(systemName: "plus")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(Circle().fill(Color.green))
            .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
    }

    /// Pre-mounts the lift in a `pendingAnchor` state at the source row's
    /// center. iOS calls this on long-press completion (where the gesture
    /// value carries no cursor location) so the user gets immediate visual
    /// feedback — source row dims and lift overlay appears — instead of
    /// waiting for the first drag event. The next `tickReorderLift(at:)` call
    /// re-anchors `touchOffset` to the actual cursor location.
    func preliftReorder(blockID: BlockID, snapshot: [Block]) {
        guard let block = snapshot.first(where: { $0.id == blockID }),
              let sourceFrame = rowFrames[blockID],
              let sourceIndex = snapshot.firstIndex(where: { $0.id == blockID })
        else { return }
        let ids = dragIDs(for: blockID)
        let idSet = Set(ids)
        let sourceIndices = snapshot.enumerated()
            .compactMap { idSet.contains($0.element.id) ? $0.offset : nil }
        state.setReorderLift(ReorderLift(
            block: block,
            ids: ids,
            sourceFrame: sourceFrame,
            sourceIndex: sourceIndex,
            sourceEndIndex: sourceIndices.last ?? sourceIndex,
            touchOffset: CGSize(width: sourceFrame.width / 2, height: sourceFrame.height / 2),
            location: CGPoint(x: sourceFrame.midX, y: sourceFrame.midY),
            pendingAnchor: true
        ))
    }

    /// Per-event update: creates the lift if missing (macOS click-and-drag
    /// path), re-anchors `touchOffset` if a previous `preliftReorder` left it
    /// pending, then updates `location` and recomputes `dropHoverIndex`.
    ///
    /// `at location` is the current cursor position — drives lift placement
    /// and drop-slot resolution. `anchorAt` is the point that should sit
    /// under the cursor inside the lift; iOS passes the same value as
    /// `location` (the finger may drift up to 36pt during long-press, and we
    /// want the lift to lock to where the finger IS now), macOS passes
    /// `value.startLocation` (the click point — typically in the gutter,
    /// 4pt away from where the gesture-cleared `value.location` is).
    ///
    /// `sourceFrame`, `sourceIndex`, and `touchOffset` are frozen once the
    /// lift exists with a real anchor — `rowFrames[id]` keeps shifting as the
    /// drift gap animates open and recomputing against a moving frame would
    /// drift the lift away from the cursor.
    func tickReorderLift(blockID: BlockID, at location: CGPoint, anchorAt anchorPoint: CGPoint, snapshot: [Block]) {
        let isCopy = currentReorderCopyIntent()
        if state.reorderLift == nil {
            guard let block = snapshot.first(where: { $0.id == blockID }),
                  let sourceFrame = rowFrames[blockID],
                  let sourceIndex = snapshot.firstIndex(where: { $0.id == blockID })
            else { return }
            let ids = dragIDs(for: blockID)
            let idSet = Set(ids)
            let sourceIndices = snapshot.enumerated()
                .compactMap { idSet.contains($0.element.id) ? $0.offset : nil }
            state.setReorderLift(ReorderLift(
                block: block,
                ids: ids,
                sourceFrame: sourceFrame,
                sourceIndex: sourceIndex,
                sourceEndIndex: sourceIndices.last ?? sourceIndex,
                touchOffset: CGSize(
                    width: anchorPoint.x - sourceFrame.minX,
                    height: anchorPoint.y - sourceFrame.minY
                ),
                location: location,
                pendingAnchor: false,
                isCopy: isCopy
            ))
        } else if var lift = state.reorderLift {
            if lift.pendingAnchor {
                lift.touchOffset = CGSize(
                    width: anchorPoint.x - lift.sourceFrame.minX,
                    height: anchorPoint.y - lift.sourceFrame.minY
                )
                lift.pendingAnchor = false
            }
            lift.location = location
            lift.isCopy = isCopy
            state.setReorderLift(lift)
        }
        applyDropTarget(at: location.y, snapshot: snapshot)
        updateReorderAutoScroll(for: location)
    }

    /// Option held → drop performs a duplicate. macOS-only; iOS has no
    /// modifier keys during a drag so always returns false there.
    private func currentReorderCopyIntent() -> Bool {
        #if os(macOS)
        return NSEvent.modifierFlags.contains(.option)
        #else
        return false
        #endif
    }

    /// Resolves the drop slot from `y`, then clears the lift and applies the
    /// move inside one no-animation transaction so neither the gap close, the
    /// lift unmount, nor the row reflow springs.
    func endReorderLift(atY y: CGFloat, snapshot: [Block]) {
        guard let lift = state.reorderLift else { return }
        stopReorderAutoScroll()
        SoundFX.play(.drop)
        let hidden = hiddenBlockIDs(in: snapshot)
        let target = state.currentDropTarget ?? resolveDropTarget(atY: y, snapshot: snapshot, hidden: hidden)
        let ids = lift.ids
        // Re-check Option at drop time so a release-just-before-drop reverts
        // to a move; the drop is the load-bearing read.
        let isCopy = currentReorderCopyIntent()
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            state.dropHoverIndex = nil
            state.dropOntoBlockID = nil
            state.currentDropTarget = nil
            state.setReorderLift(nil)
            switch target {
            case .insertBefore(let index):
                if isCopy {
                    copyBlocks(ids: ids, toIndexBefore: index, snapshot: snapshot)
                } else {
                    moveBlocks(ids: ids, toIndexBefore: index)
                }
            case .asLastChildOf(let parentID):
                if isCopy {
                    copyBlocks(ids: ids, asChildrenOf: parentID, snapshot: snapshot, hidden: hidden)
                } else {
                    moveBlocks(ids: ids, asChildrenOf: parentID, snapshot: snapshot, hidden: hidden)
                }
            case .intoSubpage(_, let path):
                // Cross-document copy is out of scope for now — Option drop
                // onto a subpage falls through to a move.
                moveBlocks(ids: ids, intoSubpagePath: path)
            }
        }
    }

    func cancelReorderLift() {
        stopReorderAutoScroll()
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            state.dropHoverIndex = nil
            state.dropOntoBlockID = nil
            state.currentDropTarget = nil
            state.setReorderLift(nil)
        }
    }

    // MARK: - Auto-scroll while dragging near the viewport edge

    /// Edge-band autoscroll for an active reorder lift. Mirrors the pinch
    /// auto-scroll pattern in `EditorView+Pinch.swift` — same threshold/velocity
    /// curve, separate state so the two gestures don't fight over one Task.
    /// Bottom edge sits at the *content area* bottom (viewport minus top &
    /// bottom insets) so it's symmetric with the top: `pageLocation.y` already
    /// has top inset subtracted, so y=0 is the top of the content area; for the
    /// bottom band to fire at max velocity past the bottom edge, it must sit at
    /// the bottom of the content area too.
    func updateReorderAutoScroll(for location: CGPoint) {
        let threshold: CGFloat = 110
        let maxVelocity: CGFloat = 620
        let effectiveBottom = scrollMetrics.viewportHeight - scrollMetrics.topInset - scrollMetrics.bottomInset
        guard effectiveBottom > threshold * 2 else {
            stopReorderAutoScroll()
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

        reorderAutoScrollVelocity = velocity
        if abs(velocity) > 1 {
            startReorderAutoScrollIfNeeded()
        } else {
            stopReorderAutoScroll()
        }
    }

    fileprivate func startReorderAutoScrollIfNeeded() {
        guard reorderAutoScrollTask == nil else { return }
        reorderAutoScrollTask = Task { @MainActor in
            let frameDuration: TimeInterval = 1.0 / 60.0
            while !Task.isCancelled {
                let velocity = reorderAutoScrollVelocity
                if abs(velocity) <= 1 { break }
                scrollBy(velocity * frameDuration)
                if let liftY = state.reorderLift?.location.y {
                    applyDropTarget(at: liftY, snapshot: document.blocks)
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
            reorderAutoScrollTask = nil
        }
    }

    func stopReorderAutoScroll() {
        reorderAutoScrollVelocity = 0
        reorderAutoScrollTask?.cancel()
        reorderAutoScrollTask = nil
    }

    /// Update `dropHoverIndex` / `dropOntoBlockID` based on the live drop point.
    /// Source rows (the lift itself) are excluded from the drop-on hit-test so
    /// you can't drop onto your own collapsed parent.
    func applyDropTarget(at y: CGFloat, snapshot: [Block]) {
        let hidden = hiddenBlockIDs(in: snapshot)
        let target = resolveDropTarget(atY: y, snapshot: snapshot, hidden: hidden)
        state.currentDropTarget = target
        switch target {
        case .insertBefore(let index):
            state.dropOntoBlockID = nil
            state.dropHoverIndex = index
        case .asLastChildOf(let id):
            state.dropHoverIndex = nil
            state.dropOntoBlockID = id
        case .intoSubpage(let id, _):
            state.dropHoverIndex = nil
            state.dropOntoBlockID = id
        }
    }

    fileprivate func resolveDropTarget(atY y: CGFloat, snapshot: [Block], hidden: Set<BlockID>) -> DropTarget {
        let liftIDs = state.reorderLift?.ids ?? []
        // Hit-test for "drop on closed parent". Use a small edge band so the
        // gap above/below the row still feels reachable.
        let edgeBand: CGFloat = 6
        for block in snapshot where !hidden.contains(block.id) && !liftIDs.contains(block.id) {
            guard let frame = rowFrames[block.id] else { continue }
            if case .subpage(_, _, let path, _) = block,
               y >= frame.minY && y <= frame.maxY {
                return .intoSubpage(block.id, path)
            }
            guard y > frame.minY + edgeBand && y < frame.maxY - edgeBand else { continue }
            if isCollapsedSection(block) {
                return .asLastChildOf(block.id)
            }
        }
        let visibleCount = ReorderDropResolver.insertionIndex(
            forY: y,
            rowFrames: orderedDropFrames(snapshot: snapshot),
            previousIndex: state.dropHoverIndex
        )
        return .insertBefore(snapshotIndex(forVisibleCount: visibleCount, snapshot: snapshot, hidden: hidden))
    }

    func performPayloadDrop(_ payload: BlockDragPayload, atY y: CGFloat, snapshot: [Block]) {
        let hidden = hiddenBlockIDs(in: snapshot)
        let target = state.currentDropTarget ?? resolveDropTarget(atY: y, snapshot: snapshot, hidden: hidden)
        switch target {
        case .insertBefore(let index):
            moveBlocks(ids: payload.ids, toIndexBefore: index)
        case .asLastChildOf(let parentID):
            moveBlocks(ids: payload.ids, asChildrenOf: parentID, snapshot: snapshot, hidden: hidden)
        case .intoSubpage(_, let path):
            moveBlocks(ids: payload.ids, intoSubpagePath: path)
        }
    }

    /// Convert "kth visible row above the drop" into a snapshot index that lies
    /// outside any collapsed subtree. Without this, dropping in the gap below a
    /// closed toggle/templateButton lands as a hidden child.
    fileprivate func snapshotIndex(forVisibleCount k: Int, snapshot: [Block], hidden: Set<BlockID>) -> Int {
        if k <= 0 { return 0 }
        var seen = 0
        for i in snapshot.indices where !hidden.contains(snapshot[i].id) {
            seen += 1
            if seen == k {
                var j = i + 1
                while j < snapshot.count && hidden.contains(snapshot[j].id) { j += 1 }
                return j
            }
        }
        return snapshot.count
    }

    func handleDropHoverChange(_ index: Int?) {
        #if os(iOS)
        guard let index else {
            lastDropHapticIndex = nil
            return
        }
        guard lastDropHapticIndex != index else { return }
        lastDropHapticIndex = index
        Haptics.light()
        #else
        _ = index
        #endif
    }

    /// Drop target rendered inside a row's existing top-gap area (or the trailing
    /// page-bottom area). Adds no layout space — the hit area is provided by an
    /// in-flow `Color.clear` whose vertical extent exactly matches the existing gap.
    @ViewBuilder
    func gapDropTarget(at index: Int, height: CGFloat) -> some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .contentShape(Rectangle())
            .accessibilityIdentifier("block-drop-slot-\(index)")
            .accessibilityLabel("Drop before block \(index + 1)")
    }

    /// Compute the BlockIDs to include in a drag started from `blockID`. If the row
    /// is part of a multi-block selection, drag the whole selection (in document
    /// order); otherwise just the single row.
    func dragIDs(for blockID: BlockID) -> [BlockID] {
        if state.selection.contains(blockID) && state.selection.count > 1 {
            return effectiveSelectedIDsInDocumentOrder()
        }
        return document.indicesIncludingSections(of: [blockID]).map { document.blocks[$0].id }
    }

    /// Move the contiguous-or-not set of blocks identified by `ids` so they're
    /// inserted starting at `target` (an index in the *current* document blocks). The
    /// dragged blocks come out of the old positions and go in at `target`, with `target`
    /// adjusted for the count of dragged blocks that came from before it. No-op if the
    /// drop is into the dragged range itself.
    fileprivate func moveBlocks(ids: [BlockID], toIndexBefore target: Int) {
        let idSet = Set(ids)
        let sourceIndices = document.blocks.enumerated()
            .compactMap { (i, block) in idSet.contains(block.id) ? i : nil }
        guard !sourceIndices.isEmpty else { return }

        // Reject drops onto the dragged range — would be a visual no-op anyway and
        // saves a useless undo entry.
        if let first = sourceIndices.first, let last = sourceIndices.last,
           target >= first && target <= last + 1 {
            return
        }

        let removalsBeforeTarget = sourceIndices.filter { $0 < target }.count
        let adjustedTarget = target - removalsBeforeTarget

        mutate("Move Block") {
            let movingBlocks = sourceIndices.map { document.blocks[$0] }
            var blocks = document.blocks
            for i in sourceIndices.reversed() {
                blocks.remove(at: i)
            }
            blocks.insert(contentsOf: movingBlocks, at: adjustedTarget)
            document.blocks = blocks
        }
    }

    /// Drop-on-parent: append `ids` after the parent's hidden subtree (snapshot
    /// position = parent index + 1 + count of contiguous hidden blocks following)
    /// AND shift each dragged block's indent so the topmost dragged block lands
    /// at `parent.indent + 1`. Internal nesting within the dragged range is
    /// preserved by applying the same indent delta to every dragged block.
    fileprivate func moveBlocks(ids: [BlockID], asChildrenOf parentID: BlockID, snapshot: [Block], hidden: Set<BlockID>) {
        guard let parentIndex = snapshot.firstIndex(where: { $0.id == parentID }),
              !ids.contains(parentID)
        else { return }

        let parent = snapshot[parentIndex]
        var insertAt = parentIndex + 1
        while insertAt < snapshot.count && hidden.contains(snapshot[insertAt].id) {
            insertAt += 1
        }

        let idSet = Set(ids)
        let sourceIndices = document.blocks.enumerated()
            .compactMap { (i, block) in idSet.contains(block.id) ? i : nil }
        guard !sourceIndices.isEmpty else { return }

        // The drag-source must not include the parent (already guarded), and the
        // insertion point must not be inside the dragged range.
        if let first = sourceIndices.first, let last = sourceIndices.last,
           insertAt >= first && insertAt <= last + 1 {
            return
        }

        let movingBlocks = sourceIndices.map { document.blocks[$0] }
        let oldRootIndent = movingBlocks.map(\.indent).min() ?? 0
        let newRootIndent = parent.indent + 1
        let indentDelta = newRootIndent - oldRootIndent

        let removalsBeforeTarget = sourceIndices.filter { $0 < insertAt }.count
        let adjustedTarget = insertAt - removalsBeforeTarget

        mutate("Move Block") {
            var blocks = document.blocks
            for i in sourceIndices.reversed() {
                blocks.remove(at: i)
            }
            let shifted = movingBlocks.map { $0.withIndent(max(0, $0.indent + indentDelta)) }
            blocks.insert(contentsOf: shifted, at: adjustedTarget)
            document.blocks = blocks
        }

        // Auto-expand the parent so the user can see the result.
        switch parent {
        case .toggle(let id, _, _): state.expandedToggles.insert(id)
        case .templateButton(let id, _, _): state.expandedTemplates.insert(id)
        default: break
        }
    }

    /// Option-drag duplicate: insert fresh-ID copies of `ids` (in their original
    /// document order, indents preserved) at `target`, leaving the originals
    /// in place. Selects the new copies. The `snapshot` parameter is unused —
    /// we source from the live document to match `spliceParsedBlocksAfter` —
    /// but kept on the signature so the call site mirrors `moveBlocks`.
    fileprivate func copyBlocks(ids: [BlockID], toIndexBefore target: Int, snapshot _: [Block]) {
        let idSet = Set(ids)
        let sourceBlocks = document.blocks.filter { idSet.contains($0.id) }
        guard !sourceBlocks.isEmpty else { return }
        let copies = sourceBlocks.map { $0.withFreshID() }
        let clampedTarget = min(max(0, target), document.blocks.count)

        mutate(copies.count > 1 ? "Duplicate Blocks" : "Duplicate Block") {
            var blocks = document.blocks
            blocks.insert(contentsOf: copies, at: clampedTarget)
            document.blocks = blocks
        }
        selectAfterCopy(copies)
    }

    /// Option-drag onto a collapsed parent: append duplicates as the parent's
    /// last children, indent-shifted so the topmost copy lands at
    /// `parent.indent + 1` (mirrors the non-copy variant).
    fileprivate func copyBlocks(ids: [BlockID], asChildrenOf parentID: BlockID, snapshot _: [Block], hidden _: Set<BlockID>) {
        guard let liveParentIndex = document.blocks.firstIndex(where: { $0.id == parentID }),
              !ids.contains(parentID)
        else { return }

        let parent = document.blocks[liveParentIndex]
        let idSet = Set(ids)
        let sourceBlocks = document.blocks.filter { idSet.contains($0.id) }
        guard !sourceBlocks.isEmpty else { return }

        let oldRootIndent = sourceBlocks.map(\.indent).min() ?? 0
        let newRootIndent = parent.indent + 1
        let indentDelta = newRootIndent - oldRootIndent
        let copies = sourceBlocks.map { $0.withFreshID().withIndent(max(0, $0.indent + indentDelta)) }

        var insertAt = liveParentIndex + 1
        let liveHidden = hiddenBlockIDs(in: document.blocks)
        while insertAt < document.blocks.count && liveHidden.contains(document.blocks[insertAt].id) {
            insertAt += 1
        }

        mutate(copies.count > 1 ? "Duplicate Blocks" : "Duplicate Block") {
            var blocks = document.blocks
            blocks.insert(contentsOf: copies, at: insertAt)
            document.blocks = blocks
        }

        switch parent {
        case .toggle(let id, _, _): state.expandedToggles.insert(id)
        case .templateButton(let id, _, _): state.expandedTemplates.insert(id)
        default: break
        }
        selectAfterCopy(copies)
    }

    /// Set selection to the freshly-inserted copies in document order.
    private func selectAfterCopy(_ copies: [Block]) {
        let ids = copies.map(\.id)
        guard let first = ids.first, let last = ids.last else { return }
        state.setNavSelection(blocks: Set(ids), anchor: first, cursor: last)
    }

    /// Drop-on-subpage: append `ids` to the end of the child page's `.md` file
    /// (cross-document write via `onAppendToSubpage`) and remove them from this
    /// document. Indents are normalized so the topmost dragged block lands at 0
    /// in the destination; relative nesting within the dragged set is preserved.
    /// If the destination write fails, the source document is left untouched.
    fileprivate func moveBlocks(ids: [BlockID], intoSubpagePath path: String) {
        let idSet = Set(ids)
        let sourceIndices = document.blocks.enumerated()
            .compactMap { (i, block) in idSet.contains(block.id) ? i : nil }
        guard !sourceIndices.isEmpty else { return }

        let movingBlocks = sourceIndices.map { document.blocks[$0] }
        let oldRootIndent = movingBlocks.map(\.indent).min() ?? 0
        let indentDelta = -oldRootIndent
        let shifted = movingBlocks.map { $0.withIndent(max(0, $0.indent + indentDelta)) }

        guard onAppendToSubpage(path, shifted) else { return }

        mutate("Move to Subpage") {
            var blocks = document.blocks
            for i in sourceIndices.reversed() {
                blocks.remove(at: i)
            }
            document.blocks = blocks
        }
    }
}
