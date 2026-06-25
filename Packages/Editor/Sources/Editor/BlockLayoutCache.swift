import CoreGraphics
import Foundation

/// Display-shape subset of `BlockKind`, stripped of text payloads and children.
/// SwiftUI copies `VisibleRow` values aggressively while diffing and laying out a
/// `ForEach`; keeping recursive `Block` values out of this cache avoids copying
/// whole subtrees just to answer spacing / drag-target questions.
enum VisibleRowKind: Equatable {
    case paragraph
    case heading(HeadingLevel)
    case bullet
    case numbered
    case todo
    case quote
    case code
    case divider
    case toggle
    case templateButton
    case subpage(pageID: String)
    case image

    init(_ kind: BlockKind) {
        switch kind {
        case .paragraph:
            self = .paragraph
        case .heading(let level, _):
            self = .heading(level)
        case .bullet:
            self = .bullet
        case .numbered:
            self = .numbered
        case .todo:
            self = .todo
        case .quote:
            self = .quote
        case .code:
            self = .code
        case .divider:
            self = .divider
        case .toggle:
            self = .toggle
        case .templateButton:
            self = .templateButton
        case .subpage(_, let pageID):
            self = .subpage(pageID: pageID)
        case .image:
            self = .image
        }
    }

    var isHeading: Bool {
        if case .heading = self { return true }
        return false
    }

    var isCollapsedContainer: Bool {
        switch self {
        case .toggle, .templateButton:
            return true
        default:
            return false
        }
    }
}

/// Tree-aware visible-row layout entry. One per displayed block, in
/// document-preorder, with rows under collapsed toggles/templateButtons
/// elided. Carries id, kind, depth, parent, slot, and prev-sibling metadata so
/// `ForEach`-time consumers don't need a second walk to compute spacing
/// / drop targets. Lifted out of `EditorView` so `BlockLayoutCache` can
/// own the cached form alongside its height/offset machinery.
struct VisibleRow {
    let id: BlockID
    let kind: VisibleRowKind
    let depth: Int
    let parentID: BlockID?
    let slot: Int
    let prevKind: VisibleRowKind?
    let prevDepth: Int
}

/// Tree-preorder walk that emits one `VisibleRow` per visible block,
/// skipping any subtree under a closed toggle/templateButton.
/// `isCollapsed` is injected because expand state lives on
/// `EditorState`, which this file deliberately doesn't import — keeps
/// the cache + walker decoupled from the editor's session model.
func computeVisibleLayout(
    snapshot: [Block],
    hidden: Set<BlockID>,
    isCollapsed: (Block) -> Bool
) -> [VisibleRow] {
    var rows: [VisibleRow] = []
    rows.reserveCapacity(snapshot.count)
    var lastVisibleKind: VisibleRowKind? = nil
    var lastDepth: Int = 0
    appendVisible(
        in: snapshot, depth: 0, parentID: nil, hidden: hidden,
        isCollapsed: isCollapsed,
        rows: &rows,
        lastVisibleKind: &lastVisibleKind, lastDepth: &lastDepth
    )
    return rows
}

private func appendVisible(
    in blocks: [Block],
    depth: Int,
    parentID: BlockID?,
    hidden: Set<BlockID>,
    isCollapsed: (Block) -> Bool,
    rows: inout [VisibleRow],
    lastVisibleKind: inout VisibleRowKind?,
    lastDepth: inout Int
) {
    for block in blocks {
        let kind = VisibleRowKind(block.kind)
        if !hidden.contains(block.id) {
            rows.append(VisibleRow(
                id: block.id, kind: kind, depth: depth, parentID: parentID,
                slot: rows.count, prevKind: lastVisibleKind, prevDepth: lastDepth
            ))
            lastVisibleKind = kind
            lastDepth = depth
        }
        if !isCollapsed(block) {
            // Heading containers don't bump depth — their children render
            // flush with the heading itself (Notion-style).
            let childDepth = block.isHeading ? depth : depth + 1
            appendVisible(
                in: block.children, depth: childDepth, parentID: block.id,
                hidden: hidden, isCollapsed: isCollapsed,
                rows: &rows,
                lastVisibleKind: &lastVisibleKind, lastDepth: &lastDepth
            )
        }
    }
}

/// Set of block IDs hidden under a collapsed toggle/templateButton.
/// The container itself stays visible; only its descendants hide.
func hiddenBlockIDs(in blocks: [Block], isCollapsed: (Block) -> Bool) -> Set<BlockID> {
    var hidden: Set<BlockID> = []
    collectHidden(in: blocks, isCollapsed: isCollapsed, into: &hidden)
    return hidden
}

private func collectHidden(
    in blocks: [Block],
    isCollapsed: (Block) -> Bool,
    into hidden: inout Set<BlockID>
) {
    for block in blocks {
        if isCollapsed(block) {
            for child in block.children {
                insertSubtree(child, into: &hidden)
            }
        } else {
            collectHidden(in: block.children, isCollapsed: isCollapsed, into: &hidden)
        }
    }
}

private func insertSubtree(_ block: Block, into hidden: inout Set<BlockID>) {
    hidden.insert(block.id)
    for child in block.children {
        insertSubtree(child, into: &hidden)
    }
}

/// Generic source of row geometry for row-surface-backed editors. Replaces a
/// previous pattern of per-row `.onGeometryChange(for: CGRect)` observation
/// that fired on every layout pass (every scroll tick, every text-wrap delta,
/// every hover redispatch) and wrote a full CGRect into a dictionary, churning
/// four scalars per row per pass.
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
/// **Reference type.** Mutations must NOT invalidate the parent view's body,
/// so this is a class held by a `@State` slot. Same shape as the outgoing
/// `RowFramesStore` for that reason.
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
class RowSurfaceLayoutCache<ID: Hashable> {
    /// Measured height per block. Populated lazily as rows mount; survives
    /// unmount so an off-screen row's height stays available for hit-testing.
    private(set) var heights: [ID: CGFloat] = [:]

    /// Visible blocks in document order — matches the layout's `ForEach`
    /// iteration. Source of truth for slot/index space.
    private(set) var orderedIDs: [ID] = []

    /// Reverse index. O(1) lookup of a block's slot.
    private(set) var indexByID: [ID: Int] = [:]

    /// Row top positions in document-local space plus a trailing total content
    /// height. Top gaps shift row tops but do not become part of a row's
    /// hit-testable extent. Length: `orderedIDs.count + 1`.
    /// Unmeasured rows contribute zero height — drag-drop near them resolves
    /// to the nearest measured neighbor, which is the right behavior (an
    /// off-screen row whose height is unknown isn't selectable as a slot
    /// boundary).
    private(set) var offsets: [CGFloat] = [0]

    /// Extra layout space rendered before a row but not owned by the row
    /// itself. Row spacing, pinch gaps, and reorder gaps live here so
    /// hit-testing inside those gaps does not behave as though it were
    /// hovering over the row below.
    private(set) var topGaps: [ID: CGFloat] = [:]

    /// Cached row extents in document-local coordinates. These mirror
    /// `orderedIDs` and deliberately exclude `topGaps` from the row height.
    private var rowTops: [CGFloat] = []
    private var rowBottoms: [CGFloat] = []

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
    func setHeight(_ h: CGFloat, for id: ID) -> Bool {
        if let existing = heights[id], existing == h { return false }
        heights[id] = h
        recomputeOffsets()
        return true
    }

    /// Replace the ordered ID list and reverse index, then recompute offsets.
    /// Called once per body render with the same `[ID]` the `ForEach`
    /// iterates over. `topGaps` carries layout space before each row that is
    /// not part of that row's hit-testable frame.
    func updateOrder(_ ids: [ID], topGaps newTopGaps: [ID: CGFloat] = [:]) {
        let sanitizedTopGaps = newTopGaps.compactMapValues { gap in
            gap > 0 ? gap : nil
        }
        if ids == orderedIDs, sanitizedTopGaps == topGaps { return }
        orderedIDs = ids
        topGaps = sanitizedTopGaps
        indexByID.removeAll(keepingCapacity: true)
        for (i, id) in ids.enumerated() { indexByID[id] = i }
        recomputeOffsets()
    }

    /// Rebuild the prefix-sum table from `heights` + `orderedIDs`. Call this
    /// after a batch of `setHeight` writes when at least one returned true.
    /// O(N) but cheap — N here is visible rows, not document rows.
    func recomputeOffsets() {
        offsets.removeAll(keepingCapacity: true)
        rowTops.removeAll(keepingCapacity: true)
        rowBottoms.removeAll(keepingCapacity: true)
        offsets.reserveCapacity(orderedIDs.count + 1)
        rowTops.reserveCapacity(orderedIDs.count)
        rowBottoms.reserveCapacity(orderedIDs.count)
        var sum: CGFloat = 0
        for id in orderedIDs {
            sum += topGaps[id] ?? 0
            let top = sum
            let bottom = top + (heights[id] ?? 0)
            offsets.append(top)
            rowTops.append(top)
            rowBottoms.append(bottom)
            sum = bottom
        }
        offsets.append(sum)
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
    func blockIDAtY(_ pageY: CGFloat) -> ID? {
        indexAtY(pageY).map { orderedIDs[$0] }
    }

    /// Find the row whose leading gutter contains `point`.
    ///
    /// macOS page-level reorder gestures are mounted on the stable scroll
    /// container, not on recyclable row views. This helper keeps that gesture
    /// scoped to the visual drag-handle strip instead of letting any row-body
    /// vertical drag become a reorder/autoscroll.
    func blockIDAtHandlePoint(_ point: CGPoint, gutterWidth: CGFloat) -> ID? {
        guard let id = blockIDAtY(point.y),
              let frame = frame(of: id)
        else { return nil }
        let handleLeft = frame.minX - gutterWidth
        guard point.x >= handleLeft, point.x < frame.minX else { return nil }
        return id
    }

    /// "Nearest" semantics: prefer the row whose y-extent contains the point,
    /// fall back to the row whose midY is closest. Mirrors the outgoing
    /// `nearestRowID(to:in:)` helper — same hit-test the macOS hover and
    /// iOS reorder-shouldBegin both used.
    func nearestBlockID(toY pageY: CGFloat) -> ID? {
        if let id = blockIDAtY(pageY) { return id }
        guard !orderedIDs.isEmpty else { return nil }
        let docY = pageY - contentOriginY
        // Scan once for closest midY. Linear in visible rows; cheap.
        var bestIdx = 0
        var bestDist: CGFloat = .infinity
        for i in 0..<orderedIDs.count {
            let mid = (rowTops[i] + rowBottoms[i]) / 2
            let d = abs(mid - docY)
            if d < bestDist { bestDist = d; bestIdx = i }
        }
        return orderedIDs[bestIdx]
    }

    /// y-position (in PageHoverCoordinateSpace) of `id`'s top. Nil if `id`
    /// isn't in the visible-row order.
    func topY(of id: ID) -> CGFloat? {
        guard let i = indexByID[id] else { return nil }
        return contentOriginY + rowTops[i]
    }

    /// Synthetic CGRect for `id` in PageHoverCoordinateSpace. Reconstructed
    /// from `(contentOriginX, contentOriginY, contentWidth, offsets, heights)`.
    /// Returns nil if `id` is unknown or unmeasured.
    func frame(of id: ID) -> CGRect? {
        guard let i = indexByID[id], let h = heights[id] else { return nil }
        return CGRect(
            x: contentOriginX,
            y: contentOriginY + rowTops[i],
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

    func blockIDAtInternalY(_ internalY: CGFloat) -> ID? {
        indexAtInternalY(internalY).map { orderedIDs[$0] }
    }

    /// Nearest-by-midY fallback in LazyVStack-internal coords. Used for
    /// hover when the cursor isn't strictly inside a row (e.g. hovering in
    /// the inter-row top-gap area).
    func nearestBlockIDAtInternalY(_ internalY: CGFloat) -> ID? {
        if let id = blockIDAtInternalY(internalY) { return id }
        guard !orderedIDs.isEmpty else { return nil }
        var bestIdx = 0
        var bestDist: CGFloat = .infinity
        for i in 0..<orderedIDs.count {
            let mid = (rowTops[i] + rowBottoms[i]) / 2
            let d = abs(mid - internalY)
            if d < bestDist { bestDist = d; bestIdx = i }
        }
        return orderedIDs[bestIdx]
    }

    /// LazyVStack-internal frame of `id`. Origin (0, offsets[i]); height is
    /// the cached measurement. Width is `contentWidth`.
    func internalFrame(of id: ID) -> CGRect? {
        guard let i = indexByID[id], let h = heights[id] else { return nil }
        return CGRect(x: 0, y: rowTops[i], width: contentWidth, height: h)
    }

    // MARK: - Internals

    /// Binary search for the row whose [rowTops[i], rowBottoms[i]) range
    /// contains `docY`. Caller guarantees `docY` is in `[0, contentHeight)`.
    private func binarySearchContaining(docY: CGFloat) -> Int? {
        // Find smallest i with rowBottoms[i] > docY; then verify the point
        // is past that row's top so explicit gaps between rows hit no row.
        var lo = 0
        var hi = orderedIDs.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if rowBottoms[mid] <= docY {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        guard lo < orderedIDs.count, docY >= rowTops[lo], docY < rowBottoms[lo] else { return nil }
        return lo
    }
}

/// Block-specific structural cache layered on top of the generic row geometry.
/// `EditorView` owns block visibility, collapse state, and tree-aware slots;
/// `RowSurface` only needs the generic height/offset portion above.
@MainActor
final class BlockLayoutCache: RowSurfaceLayoutCache<BlockID> {
    // MARK: - Structural row cache
    //
    // Cached visible-row layout + hidden set. The drag-reorder and pinch
    // gestures both call `computeVisibleLayout` from per-tick callbacks
    // (drag onChanged, pinch update, auto-scroll's 16ms inner Task). The
    // tree shape doesn't change during an active gesture, so caching the
    // result for the duration of structurally-stable spans removes both
    // tree walks from the hot path. Invalidated explicitly on document
    // transactions and on expand/collapse state changes — both are wired by
    // `EditorView` at mount.

    private var cachedVisibleRows: [VisibleRow]?
    private var cachedHidden: Set<BlockID>?
    private var cachedKey: StructuralCacheKey?

    /// Bumped on every invalidation. Useful for diagnostics + asserting
    /// cache-hit behavior during smoke tests.
    private(set) var structuralVersion: UInt64 = 0

    /// Drop the cached structural-row layout. Called when the document's
    /// block tree mutates (insert/delete/move/etc.) or when expand state
    /// changes. Cheap — just nils two slots and bumps the version.
    func invalidateStructure() {
        cachedVisibleRows = nil
        cachedHidden = nil
        cachedKey = nil
        structuralVersion &+= 1
    }

    /// Cached accessor for the visible-row layout. Rebuilds on miss using the
    /// provided `snapshot` + `isCollapsed` closure; subsequent calls return the
    /// cached values without walking the tree. `isCollapsed` is invoked only
    /// during rebuild — the cache itself holds no reference to editor state.
    func currentVisibleRows(
        snapshot: [Block],
        isCollapsed: (Block) -> Bool
    ) -> (rows: [VisibleRow], hidden: Set<BlockID>) {
        let key = StructuralCacheKey(snapshot: snapshot, isCollapsed: isCollapsed)
        if let r = cachedVisibleRows, let h = cachedHidden, cachedKey == key {
            return (r, h)
        }
        if cachedKey != nil {
            structuralVersion &+= 1
        }
        let hidden = hiddenBlockIDs(in: snapshot, isCollapsed: isCollapsed)
        let rows = computeVisibleLayout(snapshot: snapshot, hidden: hidden, isCollapsed: isCollapsed)
        cachedHidden = hidden
        cachedVisibleRows = rows
        cachedKey = key
        return (rows, hidden)
    }
}

private struct StructuralCacheKey: Equatable {
    struct Entry: Equatable {
        let id: BlockID
        let kind: VisibleRowKind
        let childCount: Int
        let isCollapsed: Bool
    }

    let entries: [Entry]

    init(snapshot: [Block], isCollapsed: (Block) -> Bool) {
        var entries: [Entry] = []
        entries.reserveCapacity(snapshot.count)
        Self.append(snapshot, isCollapsed: isCollapsed, entries: &entries)
        self.entries = entries
    }

    private static func append(_ blocks: [Block], isCollapsed: (Block) -> Bool, entries: inout [Entry]) {
        for block in blocks {
            let kind = VisibleRowKind(block.kind)
            entries.append(Entry(
                id: block.id,
                kind: kind,
                childCount: block.children.count,
                isCollapsed: kind.isCollapsedContainer && isCollapsed(block)
            ))
            append(block.children, isCollapsed: isCollapsed, entries: &entries)
        }
    }
}
