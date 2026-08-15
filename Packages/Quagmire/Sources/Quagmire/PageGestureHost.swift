import SwiftUI

// MARK: - macOS page-level drag-reorder

/// Page-level macOS drag-reorder. Replaces a previous per-row
/// `simultaneousGesture(DragGesture(...))` chain mounted on every `BlockRow`
/// inside the LazyVStack. When autoscroll moved a source row out of the
/// materialization window, SwiftUI silently destroyed the row's gesture
/// without firing `.onEnded`; the recovery path was a pair of NSEvent
/// mouse-up monitors as a backstop.
///
/// Mounting the gesture on the EditorView's page container eliminates the
/// recycling vector — the container is the single per-document view and
/// never recycles. The lift survives autoscroll, edge-band scrolls, and any
/// amount of row remounting underneath. The NSEvent backstops are gone.
///
/// `.simultaneousGesture` with minimumDistance: 4 means a click-without-drag
/// goes through inner gestures (the text content's cursor positioner) while
/// a click-and-drag from the leading gutter starts reorder. Same arbitration
/// the old per-row `.macRowReorder` modifier provided, without letting row-body
/// vertical drags become reorder/autoscroll.
///
/// Hit-testing routes through `BlockLayoutCache`: `value.startLocation`
/// (page coords) → `cache.blockIDAtHandlePoint(_:gutterWidth:)` → that's the
/// source block. Drag-tick → `cache.indexAtY(_:)` resolves the drop slot
/// through the same offsets table, answering for off-screen rows too.
extension View {
    /// macOS-only page-level drag-reorder. iOS uses the existing
    /// `iosPageReorder` UIKit bridge.
    @ViewBuilder
    func macPageDragReorder<ID: Hashable>(
        layoutCache: RowSurfaceLayoutCache<ID>,
        gutterWidth: CGFloat,
        isReorderEnabled: Bool,
        onBegan: @escaping (ID, _ location: CGPoint, _ anchor: CGPoint) -> Void,
        onChanged: @escaping (_ location: CGPoint, _ anchor: CGPoint) -> Void,
        onEnded: @escaping (CGPoint) -> Void
    ) -> some View {
        #if os(macOS)
        self.modifier(
            MacPageDragReorder(
                layoutCache: layoutCache,
                gutterWidth: gutterWidth,
                isReorderEnabled: isReorderEnabled,
                onBegan: onBegan,
                onChanged: onChanged,
                onEnded: onEnded
            )
        )
        #else
        self
        #endif
    }
}

#if os(macOS)

/// Tracks lift state across DragGesture events: capture the source block
/// once on the first `.onChanged` (the gesture has no `.onBegan` callback;
/// the first `.onChanged` arrives just past minimumDistance), then keep
/// firing `onChanged` callbacks with that block id throughout.
private struct MacPageDragReorder<ID: Hashable>: ViewModifier {
    let layoutCache: RowSurfaceLayoutCache<ID>
    let gutterWidth: CGFloat
    let isReorderEnabled: Bool
    let onBegan: (ID, CGPoint, CGPoint) -> Void
    let onChanged: (CGPoint, CGPoint) -> Void
    let onEnded: (CGPoint) -> Void

    @State private var activeBlockID: ID?

    func body(content: Content) -> some View {
        // `.simultaneousGesture` so inner gestures (the text content's
        // SpatialTapGesture for cursor positioning) still get clicks-without-
        // drag. The drag claims touches only after movement past 4pt.
        //
        // Named coordinate space — locations come in PageHoverCoordinateSpace,
        // matching what the cache and the lift overlay use.
        content.simultaneousGesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .named(PageHoverCoordinateSpace.name))
                .onChanged { value in
                    guard isReorderEnabled else { return }
                    if let id = activeBlockID {
                        onChanged(value.location, value.startLocation)
                        _ = id
                    } else {
                        // First .onChanged after threshold crossed. Hit-test
                        // the original mouse-down point (startLocation) to
                        // identify the source block.
                        guard let id = layoutCache.blockIDAtHandlePoint(
                            value.startLocation,
                            gutterWidth: gutterWidth
                        ) else {
                            return
                        }
                        activeBlockID = id
                        onBegan(id, value.location, value.startLocation)
                    }
                }
                .onEnded { value in
                    guard isReorderEnabled, activeBlockID != nil else {
                        activeBlockID = nil
                        return
                    }
                    activeBlockID = nil
                    onEnded(value.location)
                }
        )
    }
}

#endif
