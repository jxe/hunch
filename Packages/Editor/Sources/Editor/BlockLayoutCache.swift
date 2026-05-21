import CoreGraphics
import Foundation

/// Canonical source of row geometry for the page editor. Replaces a previous
/// pattern of per-row `.onGeometryChange(for: CGRect)` observation that fired
/// on every layout pass (every scroll tick, every text-wrap delta, every hover
/// redispatch) and wrote a full CGRect into a dictionary, churning four
/// scalars per row per pass.
///
/// **What rows publish:** just their height, via a height-only
/// `.onGeometryChange(for: CGFloat) { $0.size.height }` modifier. SwiftUI fires
/// the action only when the closure's result actually changes, so steady-state
/// scrolling does zero writes. Height changes are infrequent — text-wrap on
/// edit, mode toggle, toggle expand/collapse — and each fires a single setter
/// call that same-value-guards before mutating.
///
/// **What the cache derives:** a row's y position in the page's named
/// coordinate space, by summing cached heights and offsetting by the
/// `contentOriginY` published from a single anchor view at the top of the
/// LazyVStack. One anchor publishes one number per scroll tick; the cache
/// gives every row's frame on demand without observing N positions.
///
/// **Reference type.** Mutations must NOT invalidate `EditorView.body`, so
/// this is a class held by an EditorView `@State` slot. Same shape as the
/// outgoing `RowFramesStore` for that reason.
///
/// **Why a separate cache instead of querying SwiftUI's layout?** SwiftUI
/// doesn't expose row positions for off-screen rows in a `LazyVStack`. The
/// drag-drop resolver needs to answer "what insertion slot is the cursor in"
/// for the full document, including rows above/below the materialization
/// window — that's only possible if we maintain our own layout view that
/// outlives a row's mount lifecycle. The cache also retains heights for
/// off-screen rows so drop targets snap correctly when scrolling past an
/// unmounted row mid-drag.
@MainActor
final class BlockLayoutCache {
    /// Measured height per block. Populated lazily as rows mount; survives
    /// unmount so an off-screen row's height stays available for hit-testing.
    private(set) var heights: [BlockID: CGFloat] = [:]

    /// Visible blocks in document order — matches the layout's `ForEach`
    /// iteration. Source of truth for slot/index space.
    private(set) var orderedIDs: [BlockID] = []

    /// Reverse index. O(1) lookup of a block's slot.
    private(set) var indexByID: [BlockID: Int] = [:]

    /// Prefix sum of heights. `offsets[i]` is the y-position of row `i`'s top
    /// in document-local space (0 = top of LazyVStack content). Length:
    /// `orderedIDs.count + 1`; the trailing entry is the total content height.
    /// Unmeasured rows contribute zero — drag-drop near them resolves to the
    /// nearest measured neighbor, which is the right behavior (an off-screen
    /// row whose height is unknown isn't selectable as a slot boundary).
    private(set) var offsets: [CGFloat] = [0]

    /// Y-position of the LazyVStack's top in PageHoverCoordinateSpace.
    /// Updated from a single anchor view at the top of the content area.
    /// One write per scroll tick — vs. N writes when each row published its
    /// own CGRect.
    var contentOriginY: CGFloat = 0

    /// X-origin of the page content column in PageHoverCoordinateSpace.
    /// Same source as `contentOriginY` (one anchor view). Used to synthesize
    /// CGRect frames for callers that still need the full rect.
    var contentOriginX: CGFloat = 0

    /// Width of a typical row (the content column). Same source as the
    /// origin. Used to synthesize CGRect frames.
    var contentWidth: CGFloat = 0

    /// Same-value guarded height write. Mutates `heights` and reruns the
    /// prefix-sum table if the value changed. Returns true on change.
    ///
    /// `recomputeOffsets` is O(visible rows); during initial mount of M new
    /// rows the cost is O(M²) (each setHeight triggers a recompute). For a
    /// 500-row doc that's still sub-millisecond on the main thread, and
    /// steady-state scrolling fires zero writes — `.onGeometryChange(for:
    /// CGFloat)` only fires on height delta, not on every layout pass.
    @discardableResult
    func setHeight(_ h: CGFloat, for id: BlockID) -> Bool {
        if let existing = heights[id], existing == h { return false }
        heights[id] = h
        recomputeOffsets()
        return true
    }

    /// Replace the ordered ID list and reverse index, then recompute offsets.
    /// Called once per body render with the same `[BlockID]` the `ForEach`
    /// iterates over. No-op if the order didn't change.
    func updateOrder(_ ids: [BlockID]) {
        if ids == orderedIDs { return }
        orderedIDs = ids
        indexByID.removeAll(keepingCapacity: true)
        for (i, id) in ids.enumerated() { indexByID[id] = i }
        recomputeOffsets()
    }

    /// Rebuild the prefix-sum table from `heights` + `orderedIDs`. Call this
    /// after a batch of `setHeight` writes when at least one returned true.
    /// O(N) but cheap — N here is visible rows, not document rows.
    func recomputeOffsets() {
        offsets.removeAll(keepingCapacity: true)
        offsets.reserveCapacity(orderedIDs.count + 1)
        offsets.append(0)
        var sum: CGFloat = 0
        for id in orderedIDs {
            sum += heights[id] ?? 0
            offsets.append(sum)
        }
    }

    /// Total content height (sum of all row heights). Excludes
    /// `contentOriginY` (which is a page-coord offset, not a content height).
    var contentHeight: CGFloat { offsets.last ?? 0 }

    // MARK: - Hit-testing

    /// Find the row index whose vertical extent contains `pageY` (a y-position
    /// in PageHoverCoordinateSpace). Returns nil if `pageY` is above the first
    /// row's top or at/below the last row's bottom — same shape as the
    /// outgoing `nearestRowID` containment check, but without iterating every
    /// row in a dict.
    func indexAtY(_ pageY: CGFloat) -> Int? {
        let docY = pageY - contentOriginY
        guard !orderedIDs.isEmpty, docY >= 0, docY < contentHeight else { return nil }
        return binarySearchContaining(docY: docY)
    }

    /// Find the block whose y-extent contains `pageY` in
    /// PageHoverCoordinateSpace. Convenience over `indexAtY`.
    func blockIDAtY(_ pageY: CGFloat) -> BlockID? {
        indexAtY(pageY).map { orderedIDs[$0] }
    }

    /// "Nearest" semantics: prefer the row whose y-extent contains the point,
    /// fall back to the row whose midY is closest. Mirrors the outgoing
    /// `nearestRowID(to:in:)` helper — same hit-test the macOS hover and
    /// iOS reorder-shouldBegin both used.
    func nearestBlockID(toY pageY: CGFloat) -> BlockID? {
        if let id = blockIDAtY(pageY) { return id }
        guard !orderedIDs.isEmpty else { return nil }
        let docY = pageY - contentOriginY
        // Scan once for closest midY. Linear in visible rows; cheap.
        var bestIdx = 0
        var bestDist: CGFloat = .infinity
        for i in 0..<orderedIDs.count {
            let mid = (offsets[i] + offsets[i+1]) / 2
            let d = abs(mid - docY)
            if d < bestDist { bestDist = d; bestIdx = i }
        }
        return orderedIDs[bestIdx]
    }

    /// y-position (in PageHoverCoordinateSpace) of `id`'s top. Nil if `id`
    /// isn't in the visible-row order.
    func topY(of id: BlockID) -> CGFloat? {
        guard let i = indexByID[id] else { return nil }
        return contentOriginY + offsets[i]
    }

    /// Synthetic CGRect for `id` in PageHoverCoordinateSpace. Reconstructed
    /// from `(contentOriginX, contentOriginY, contentWidth, offsets, heights)`.
    /// Returns nil if `id` is unknown or unmeasured.
    func frame(of id: BlockID) -> CGRect? {
        guard let i = indexByID[id], let h = heights[id] else { return nil }
        return CGRect(
            x: contentOriginX,
            y: contentOriginY + offsets[i],
            width: contentWidth,
            height: h
        )
    }

    // MARK: - LazyVStack-internal hit-testing
    //
    // The macOS gesture host attaches recognizers to the NSScrollView's
    // documentView (so they fire over the entire scroll content area), but
    // converts hit locations via `location(in: hostNSView)` where
    // hostNSView is a `.background()` of the LazyVStack itself. That gives
    // points in LazyVStack-internal coords (origin at LazyVStack top-left,
    // independent of scroll). Use the *internal* hit-testers below when the
    // caller has LazyVStack-internal coords; the page-coord versions above
    // are for SwiftUI gesture callers.

    /// Find the row whose y-extent contains `internalY` (LazyVStack-internal
    /// coords: 0 = top of LazyVStack, contentHeight = bottom).
    func indexAtInternalY(_ internalY: CGFloat) -> Int? {
        guard !orderedIDs.isEmpty, internalY >= 0, internalY < contentHeight else { return nil }
        return binarySearchContaining(docY: internalY)
    }

    func blockIDAtInternalY(_ internalY: CGFloat) -> BlockID? {
        indexAtInternalY(internalY).map { orderedIDs[$0] }
    }

    /// Nearest-by-midY fallback in LazyVStack-internal coords. Used for
    /// hover when the cursor isn't strictly inside a row (e.g. hovering in
    /// the inter-row top-gap area).
    func nearestBlockIDAtInternalY(_ internalY: CGFloat) -> BlockID? {
        if let id = blockIDAtInternalY(internalY) { return id }
        guard !orderedIDs.isEmpty else { return nil }
        var bestIdx = 0
        var bestDist: CGFloat = .infinity
        for i in 0..<orderedIDs.count {
            let mid = (offsets[i] + offsets[i+1]) / 2
            let d = abs(mid - internalY)
            if d < bestDist { bestDist = d; bestIdx = i }
        }
        return orderedIDs[bestIdx]
    }

    /// LazyVStack-internal frame of `id`. Origin (0, offsets[i]); height is
    /// the cached measurement. Width is `contentWidth`.
    func internalFrame(of id: BlockID) -> CGRect? {
        guard let i = indexByID[id], let h = heights[id] else { return nil }
        return CGRect(x: 0, y: offsets[i], width: contentWidth, height: h)
    }

    // MARK: - Internals

    /// Binary search for the row whose [offsets[i], offsets[i+1]) range
    /// contains `docY`. Caller guarantees `docY` is in `[0, contentHeight)`.
    private func binarySearchContaining(docY: CGFloat) -> Int? {
        // Find smallest i with offsets[i+1] > docY; that's the containing row.
        var lo = 0
        var hi = orderedIDs.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if offsets[mid + 1] <= docY {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo < orderedIDs.count ? lo : nil
    }
}
