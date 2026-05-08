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

    /// Drift gap rendered above the visible-row at `slot` (or at the trailing
    /// slot == visibleRows.count). Both `hoverSlot` and `liftFootprint` are
    /// precomputed once per body pass — `hoverSlot` is the visible slot
    /// corresponding to the current `dropHoverPath`, `liftFootprint` is the
    /// contiguous range of visible-row slots occupied by the lifted subtree.
    /// The footprint suppression covers "drop where you already are":
    /// anywhere inside the lifted rows, or the slot directly after them.
    func reorderDriftGap(at slot: Int, hoverSlot: Int?, liftFootprint: ClosedRange<Int>?) -> CGFloat {
        guard hoverSlot == slot else { return 0 }
        if let f = liftFootprint, f.contains(slot) || slot == f.upperBound + 1 { return 0 }
        return 42
    }

    /// Visible-slot range covered by the active reorder lift's blocks (and
    /// any descendants that render in the visible-row stack). Returns nil if
    /// no lift is active or none of the lifted ids correspond to visible rows.
    func currentLiftFootprint(in rows: [EditorView.VisibleRow]) -> ClosedRange<Int>? {
        guard let lift = state.reorderLift else { return nil }
        var slots: [Int] = []
        for (k, row) in rows.enumerated() where lift.draggedSubtreeIDs.contains(row.block.id) {
            slots.append(k)
        }
        guard let lo = slots.min(), let hi = slots.max() else { return nil }
        return lo...hi
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
                block: lift.block,
                onBlockChange: { _ in },
                depth: 0,
                editorFocused: $editorFocused,
                isPageTitle: false,
                numberingIndex: nil,
                isSelected: false,
                isEditing: false,
                pageTitles: resolvePageTitles(for: lift.block, resolver: pageTitle)
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
        guard let lift = makeReorderLift(
            blockID: blockID,
            snapshot: snapshot,
            touchOffset: nil,
            location: nil,
            pendingAnchor: true,
            isCopy: false
        ) else { return }
        state.setReorderLift(lift)
    }

    /// Build a `ReorderLift` for `blockID` against `snapshot`. Returns nil if
    /// the block, its row frame, or its document position is missing.
    /// `touchOffset` / `location` default to the source row's center — used by
    /// the iOS prelift, which mounts before a real cursor anchor is known.
    private func makeReorderLift(
        blockID: BlockID,
        snapshot: [Block],
        touchOffset: CGSize?,
        location: CGPoint?,
        pendingAnchor: Bool,
        isCopy: Bool
    ) -> ReorderLift? {
        guard let block = document.find(blockID),
              let sourceFrame = rowFrames[blockID]
        else { return nil }
        let ids = dragIDs(for: blockID)
        let parentID = document.parent(of: blockID)
        // Compute the (parent, positions) pair: positions are the indices of
        // each lifted root within its parent's children list. Single-row
        // drags collapse to a single-position range.
        let siblings: [Block] = parentID.flatMap(document.find)?.children ?? document.children
        let positions = ids.compactMap { id in siblings.firstIndex { $0.id == id } }.sorted()
        let positionRange: ClosedRange<Int> = (positions.first ?? 0)...(positions.last ?? 0)
        // All ids inside any lifted subtree (cycle prevention on drop).
        var allDescendants: Set<BlockID> = []
        for id in ids {
            allDescendants.formUnion(document.subtreeIDs(of: id))
        }
        return ReorderLift(
            block: block,
            ids: ids,
            sourceParentID: parentID,
            sourcePositions: positionRange,
            draggedSubtreeIDs: allDescendants,
            sourceFrame: sourceFrame,
            touchOffset: touchOffset ?? CGSize(width: sourceFrame.width / 2, height: sourceFrame.height / 2),
            location: location ?? CGPoint(x: sourceFrame.midX, y: sourceFrame.midY),
            pendingAnchor: pendingAnchor,
            isCopy: isCopy
        )
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
            guard let sourceFrame = rowFrames[blockID],
                  let lift = makeReorderLift(
                      blockID: blockID,
                      snapshot: snapshot,
                      touchOffset: CGSize(
                          width: anchorPoint.x - sourceFrame.minX,
                          height: anchorPoint.y - sourceFrame.minY
                      ),
                      location: location,
                      pendingAnchor: false,
                      isCopy: isCopy
                  )
            else { return }
            state.setReorderLift(lift)
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
            state.currentDropTarget = nil
            state.setReorderLift(nil)
            switch target {
            case .insertAt(let path):
                if isCopy {
                    copyBlocks(ids: ids, to: path, snapshot: snapshot)
                } else {
                    moveBlocks(ids: ids, to: path)
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
                    var snapshot: [Block] = []
                    document.walk { block, _, _ in snapshot.append(block) }
                    applyDropTarget(at: liftY, snapshot: snapshot)
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

    /// Update `currentDropTarget` based on the live drop point. Source rows
    /// (the lift itself) are excluded from the drop-on hit-test so you can't
    /// drop onto your own collapsed parent.
    func applyDropTarget(at y: CGFloat, snapshot: [Block]) {
        let hidden = hiddenBlockIDs(in: snapshot)
        state.currentDropTarget = resolveDropTarget(atY: y, snapshot: snapshot, hidden: hidden)
    }

    fileprivate func resolveDropTarget(atY y: CGFloat, snapshot: [Block], hidden: Set<BlockID>) -> DropTarget {
        let liftIDs = state.reorderLift?.ids ?? []
        // Build the visible-flat layout once and use it for BOTH the hit-test
        // (drop on subpage / closed parent) and the between-rows slot
        // resolver. Iterating the top-level snapshot directly would miss
        // nested rows; iterating the legacy flat preorder of `snapshot`
        // would double-count blocks that also live inside their parent's
        // `children` array.
        let layout = computeVisibleLayout(snapshot: document.children, hidden: hidden)
        let rows = layout.rows

        // Hit-test for "drop on closed parent" / "drop onto subpage". Edge
        // band keeps the gap above/below the row reachable for between-rows
        // drops.
        let edgeBand: CGFloat = 6
        for row in rows where !liftIDs.contains(row.block.id) {
            guard let frame = rowFrames[row.block.id] else { continue }
            if case .subpage(_, let path) = row.block.kind,
               y >= frame.minY && y <= frame.maxY {
                return .intoSubpage(row.block.id, path)
            }
            guard y > frame.minY + edgeBand && y < frame.maxY - edgeBand else { continue }
            if isCollapsedSection(row.block) {
                return .asLastChildOf(row.block.id)
            }
        }

        // Between-rows insertion: resolve "kth visible slot" against the
        // visible-flat row frames, then convert to a tree DropPath using
        // the layout's depth + parent metadata.
        let slot = resolveDropSlot(forY: y, in: rows, previousIndex: visibleSlotForCurrentDropPath(in: rows))
        return .insertAt(dropPath(forVisibleSlot: slot, rows: rows))
    }

    /// Converts a Y-position into a slot index in `rows` (the full
    /// visible-row layout). Under `LazyVStack`, only on-screen rows have
    /// entries in `rowFrames`, so the resolver's "kth frame" answer lives in
    /// a sparser space than `rows` — this maps one to the other so callers
    /// always speak the `rows` index space (which is what `dropPath` and the
    /// gap renderers expect). Returns 0 when nothing is on screen, which
    /// `dropPath` handles as "top of document."
    func resolveDropSlot(forY y: CGFloat, in rows: [EditorView.VisibleRow], previousIndex: Int? = nil) -> Int {
        let knownFrames: [(rowsIndex: Int, frame: ReorderDropFrame)] = rows.enumerated().compactMap { (k, row) in
            rowFrames[row.block.id].map { (k, ReorderDropFrame(id: row.block.id, frame: $0)) }
        }
        guard !knownFrames.isEmpty else { return previousIndex ?? 0 }
        let prevInKnownSpace: Int? = previousIndex.map { prev in
            knownFrames.firstIndex { $0.rowsIndex >= prev } ?? knownFrames.count
        }
        let knownSlot = ReorderDropResolver.insertionIndex(
            forY: y,
            rowFrames: knownFrames.map { $0.frame },
            previousIndex: prevInKnownSpace
        )
        if knownSlot < knownFrames.count {
            return knownFrames[knownSlot].rowsIndex
        }
        return (knownFrames.last.map { $0.rowsIndex + 1 }) ?? rows.count
    }

    /// Convert a visible-flat slot index to a tree `DropPath`. Decides based
    /// on the parent relationship between the rows above and below the slot,
    /// not on visible depth — heading children render at the heading's
    /// depth (Notion-flush layout), so depth alone can't distinguish
    /// "first child of heading" from "next sibling of heading."
    ///
    /// - slot 0 → top of the document
    /// - trailing slot → append at the document root
    /// - row[k] is a direct child of row[k-1] → drop becomes first child of
    ///   row[k-1] (whether or not depths differ — heading-children look
    ///   visually flat with the heading)
    /// - row[k] and row[k-1] share a parent → drop as the next sibling of
    ///   row[k-1] under that shared parent
    /// - otherwise (we're exiting row[k-1]'s subtree to land in below's
    ///   parent) → drop "before row[k]" at row[k]'s depth
    func dropPath(forVisibleSlot slot: Int, rows: [EditorView.VisibleRow]) -> DropPath {
        if slot <= 0 {
            return DropPath(parent: nil, position: 0)
        }
        if slot >= rows.count {
            return DropPath(parent: nil, position: document.children.count)
        }
        let above = rows[slot - 1]
        let below = rows[slot]

        // First child of `above`. Catches the heading-flush case where above
        // and below share a depth value but below is structurally inside
        // above. Without this check, the slot would resolve to "next
        // sibling of above" — the wrong scope.
        if below.parentID == above.block.id {
            return DropPath(parent: above.block.id, position: 0)
        }

        // Sibling under a shared parent.
        if above.parentID == below.parentID {
            let parentID = above.parentID
            let siblings: [Block] = parentID.flatMap(document.find)?.children ?? document.children
            let i = siblings.firstIndex(where: { $0.id == above.block.id }) ?? siblings.count - 1
            return DropPath(parent: parentID, position: i + 1)
        }

        // Exiting above's subtree. Drop "before below" in below's parent.
        let parentID = below.parentID
        let siblings: [Block] = parentID.flatMap(document.find)?.children ?? document.children
        let i = siblings.firstIndex(where: { $0.id == below.block.id }) ?? 0
        return DropPath(parent: parentID, position: i)
    }

    /// Returns the visible-flat slot the current drop hover corresponds to
    /// (if any). Used as a stickiness hint for `ReorderDropResolver` so the
    /// slot doesn't oscillate near gap boundaries.
    func visibleSlotForCurrentDropPath(in rows: [EditorView.VisibleRow]) -> Int? {
        guard let path = state.dropHoverPath else { return nil }
        // Find the row whose (parent, position) matches — i.e. the row whose
        // insertion would land at this DropPath. The slot is "the index of the
        // row that would sit AT or AFTER this drop path's effective position."
        for (k, row) in rows.enumerated() {
            if row.parentID == path.parent {
                let parentChildren: [Block] = path.parent.flatMap(document.find)?.children ?? document.children
                if path.position < parentChildren.count {
                    let target = parentChildren[path.position].id
                    if row.block.id == target { return k }
                }
            }
        }
        return nil
    }

    func performPayloadDrop(_ payload: BlockDragPayload, atY y: CGFloat, snapshot: [Block]) {
        let hidden = hiddenBlockIDs(in: snapshot)
        let target = state.currentDropTarget ?? resolveDropTarget(atY: y, snapshot: snapshot, hidden: hidden)
        switch target {
        case .insertAt(let path):
            moveBlocks(ids: payload.ids, to: path)
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
    /// order); otherwise just the single row + its descendants.
    func dragIDs(for blockID: BlockID) -> [BlockID] {
        if state.selection.contains(blockID) && state.selection.count > 1 {
            return effectiveSelectedIDsInDocumentOrder()
        }
        // Single-row drag: the lifted root + all descendants travel together.
        guard let block = document.find(blockID) else { return [blockID] }
        var out: [BlockID] = []
        var seen: Set<BlockID> = []
        collectPreorderIDs(block, into: &out, seen: &seen)
        return out
    }

    /// Move the subtree-rooted set of blocks identified by `ids` to `target`.
    /// Validates with `Document.canDrop(ids:to:)` first (rejects descendant
    /// cycles and containment violations) and then funnels through
    /// `Document.moveSubtrees(_:to:)`.
    fileprivate func moveBlocks(ids: [BlockID], to target: DropPath) {
        guard !ids.isEmpty, document.canDrop(ids: ids, to: target) else { return }
        mutate("Move Block") {
            document.moveSubtrees(ids, to: target)
        }
    }

    /// Drop-on-parent: append `ids` as the parent's last children. Validates
    /// with `Document.canDrop` (rejects cycles + containment violations) then
    /// performs the move. No more indent math — the tree itself encodes depth.
    func moveBlocks(ids: [BlockID], asChildrenOf parentID: BlockID, snapshot _: [Block], hidden _: Set<BlockID>) {
        guard !ids.contains(parentID),
              let parent = document.find(parentID) else { return }
        let target = DropPath(parent: parentID, position: parent.children.count)
        guard document.canDrop(ids: ids, to: target) else { return }
        mutate("Move Block") {
            document.moveSubtrees(ids, to: target)
        }
        // Auto-expand the parent so the user can see the result.
        switch parent.kind {
        case .toggle: state.expandedToggles.insert(parent.id)
        case .templateButton: state.expandedTemplates.insert(parent.id)
        default: break
        }
        showActionToast("Moved")
    }

    /// Option-drag duplicate: insert fresh-ID copies of `ids` at `target`,
    /// leaving the originals in place. Selects the new copies.
    fileprivate func copyBlocks(ids: [BlockID], to target: DropPath, snapshot _: [Block]) {
        // Collect originals in document order (so a multi-block selection
        // duplicates in the right order) and deep-copy with fresh IDs.
        let ordered = ids.sorted { (a, b) in
            (document.documentOrder(of: a) ?? .max) < (document.documentOrder(of: b) ?? .max)
        }
        let copies = ordered.compactMap { document.find($0)?.withFreshIDs() }
        guard !copies.isEmpty else { return }
        mutate(copies.count > 1 ? "Duplicate Blocks" : "Duplicate Block") {
            document.insertSubtrees(copies, at: target)
        }
        selectAfterCopy(copies)
    }

    /// Option-drag onto a closed parent: append duplicates as that parent's
    /// last children. Mirrors `moveBlocks(ids:asChildrenOf:...)` for the copy
    /// variant.
    fileprivate func copyBlocks(ids: [BlockID], asChildrenOf parentID: BlockID, snapshot _: [Block], hidden _: Set<BlockID>) {
        guard !ids.contains(parentID),
              let parent = document.find(parentID) else { return }
        let target = DropPath(parent: parentID, position: parent.children.count)
        let ordered = ids.sorted { (a, b) in
            (document.documentOrder(of: a) ?? .max) < (document.documentOrder(of: b) ?? .max)
        }
        let copies = ordered.compactMap { document.find($0)?.withFreshIDs() }
        guard !copies.isEmpty else { return }
        mutate(copies.count > 1 ? "Duplicate Blocks" : "Duplicate Block") {
            document.insertSubtrees(copies, at: target)
        }
        switch parent.kind {
        case .toggle: state.expandedToggles.insert(parent.id)
        case .templateButton: state.expandedTemplates.insert(parent.id)
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

    /// Drop-on-subpage / Move-to picker: append `ids` to the end of the
    /// destination page (cross-document write via `onAppendToSubpage`) and
    /// remove them from this document. Tree shape and relative nesting are
    /// preserved verbatim — the destination receives the subtrees as-is.
    func moveBlocks(ids: [BlockID], intoSubpagePath path: String) {
        let ordered = ids.sorted { (a, b) in
            (document.documentOrder(of: a) ?? .max) < (document.documentOrder(of: b) ?? .max)
        }
        let movingBlocks = ordered.compactMap { document.find($0) }
        guard !movingBlocks.isEmpty else { return }

        guard onAppendToSubpage(path, movingBlocks) else { return }

        mutate("Move to Subpage") {
            for id in ordered {
                document.removeSubtree(id)
            }
        }
        showActionToast("Moved")
    }
}
