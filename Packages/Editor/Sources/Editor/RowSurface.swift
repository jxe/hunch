import SwiftUI
import UniformTypeIdentifiers

/// Render/layout facts for one row in a `RowSurface`.
///
/// This type is deliberately content-agnostic: no `Block`, no editor state, no
/// closures. Semantic rendering and mutation stay in the adapter above.
struct RowSurfaceRow<ID: Hashable>: Equatable {
    let id: ID
    let slot: Int
    let depth: Int
    let spacingBefore: CGFloat
    let pinchGap: CGFloat
    let reorderGap: CGFloat
    let isSourceDimmed: Bool
}

/// Geometry needed for placing the floating reorder lift. The content itself
/// is supplied by `liftContent`, so row semantics stay above the surface.
struct RowSurfaceLift<ID: Hashable>: Equatable {
    let id: ID
    let sourceFrame: CGRect
    let touchOffset: CGSize
    let location: CGPoint
}

/// One stable action boundary for `RowSurface`. Rows store no callbacks; the
/// surface maps gestures/hit-tests to IDs and coordinates, then calls these
/// top-level closures.
struct RowSurfaceActions<ID: Hashable> {
    var onHover: (ID?) -> Void = { _ in }
    var onTapRow: (ID) -> Void = { _ in }
    var onTapGutter: (ID) -> Void = { _ in }
    var onTapBelowRows: (CGPoint) -> Void = { _ in }

    var onReorderBegin: (ID, _ location: CGPoint, _ anchor: CGPoint) -> Void = { _, _, _ in }
    var onReorderChanged: (_ location: CGPoint, _ anchor: CGPoint) -> Void = { _, _ in }
    var onReorderEnded: (CGPoint) -> Void = { _ in }
    var onReorderCancelled: () -> Void = {}
    var onReorderAutoscroll: (CGPoint) -> Void = { _ in }

    /// Return true when the pinch has crossed the editor's semantic threshold
    /// and should drive edge autoscroll.
    var onPinchUpdate: (PagePinchValue) -> Bool = { _ in false }
    var onPinchCommit: (PagePinchValue) -> Void = { _ in }

    var onExternalDropUpdate: (CGFloat) -> Void = { _ in }
    var onExternalDrop: (_ plainTextPayload: String, _ y: CGFloat) -> Void = { _, _ in }
    var onExternalDropCancel: () -> Void = {}
}

/// Bare row surface: scroll container, row measurement, page-level gestures,
/// gaps, hover hit-testing, autoscroll, and lift placement.
struct RowSurface<ID: Hashable, RowContent: View, LiftContent: View>: View {
    let rows: [RowSurfaceRow<ID>]
    let layoutCache: RowSurfaceLayoutCache<ID>
    let maxContentWidth: CGFloat
    let horizontalPadding: CGFloat
    let topPadding: CGFloat
    let gutterWidth: CGFloat
    let trailingDropHeight: CGFloat
    let activeLift: RowSurfaceLift<ID>?
    let scrollMetrics: PageScrollMetrics
    @Binding var scrollPosition: ScrollPosition
    let isIOSReorderEnabled: Bool
    let isMacReorderEnabled: Bool
    let isPinchEnabled: Bool
    let footer: AnyView?
    let actions: RowSurfaceActions<ID>
    let rowContent: (ID) -> RowContent
    let liftContent: (ID, CGSize) -> LiftContent

    @State private var pinchAutoScrollTask: Task<Void, Never>?
    @State private var pinchAutoScrollVelocity: CGFloat = 0
    @State private var reorderAutoScrollTask: Task<Void, Never>?
    @State private var reorderAutoScrollVelocity: CGFloat = 0
    @State private var activeReorderLocation: CGPoint?

    init(
        rows: [RowSurfaceRow<ID>],
        layoutCache: RowSurfaceLayoutCache<ID>,
        maxContentWidth: CGFloat,
        horizontalPadding: CGFloat,
        topPadding: CGFloat = 32,
        gutterWidth: CGFloat,
        trailingDropHeight: CGFloat,
        activeLift: RowSurfaceLift<ID>?,
        scrollMetrics: PageScrollMetrics,
        scrollPosition: Binding<ScrollPosition>,
        isIOSReorderEnabled: Bool,
        isMacReorderEnabled: Bool,
        isPinchEnabled: Bool,
        footer: AnyView? = nil,
        actions: RowSurfaceActions<ID>,
        @ViewBuilder rowContent: @escaping (ID) -> RowContent,
        @ViewBuilder liftContent: @escaping (ID, CGSize) -> LiftContent
    ) {
        self.rows = rows
        self.layoutCache = layoutCache
        self.maxContentWidth = maxContentWidth
        self.horizontalPadding = horizontalPadding
        self.topPadding = topPadding
        self.gutterWidth = gutterWidth
        self.trailingDropHeight = trailingDropHeight
        self.activeLift = activeLift
        self.scrollMetrics = scrollMetrics
        self._scrollPosition = scrollPosition
        self.isIOSReorderEnabled = isIOSReorderEnabled
        self.isMacReorderEnabled = isMacReorderEnabled
        self.isPinchEnabled = isPinchEnabled
        self.footer = footer
        self.actions = actions
        self.rowContent = rowContent
        self.liftContent = liftContent
    }

    var body: some View {
        let rowReorderGaps = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.reorderGap) })
        let _ = layoutCache.updateOrder(rows.map(\.id), topGaps: rowReorderGaps)

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows, id: \.id) { row in
                    rowContent(row.id)
                        .padding(.top, row.spacingBefore + row.pinchGap)
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { newHeight in
                            layoutCache.setHeight(newHeight, for: row.id)
                        }
                        .padding(.top, row.reorderGap)
                        .opacity(row.isSourceDimmed ? 0.12 : 1)
                        .animation(.spring(response: 0.26, dampingFraction: 0.76), value: row.reorderGap)
                }
                trailingDropTarget
                if let footer {
                    footer
                }
            }
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(PageHoverCoordinateSpace.name))
            } action: { rect in
                layoutCache.contentOriginX = rect.minX
                layoutCache.contentOriginY = rect.minY
                layoutCache.contentWidth = rect.width
            }
            .frame(maxWidth: maxContentWidth, alignment: .leading)
            .padding(.horizontal, horizontalPadding)
            .padding(.top, topPadding)
            .frame(maxWidth: .infinity, alignment: .center)
            .iosPageReorder(
                isEnabled: isIOSReorderEnabled,
                layoutCache: layoutCache,
                onBegin: { id, location in
                    activeReorderLocation = location
                    actions.onReorderBegin(id, location, location)
                    updateReorderAutoScroll(for: location)
                },
                onChanged: { location in
                    activeReorderLocation = location
                    actions.onReorderChanged(location, location)
                    updateReorderAutoScroll(for: location)
                },
                onEnded: { location in
                    activeReorderLocation = nil
                    stopReorderAutoScroll()
                    actions.onReorderEnded(location)
                },
                onCancelled: {
                    activeReorderLocation = nil
                    stopReorderAutoScroll()
                    actions.onReorderCancelled()
                }
            )
            .iosPagePinch(
                isEnabled: isPinchEnabled,
                onUpdate: { value in
                    if actions.onPinchUpdate(value) {
                        updatePinchAutoScroll(for: value.location)
                    } else {
                        stopPinchAutoScroll()
                    }
                },
                onCommit: { value in
                    stopPinchAutoScroll()
                    actions.onPinchCommit(value)
                }
            )
            .iosScrollMetrics(scrollMetrics)
        }
        .coordinateSpace(name: PageHoverCoordinateSpace.name)
        .iosPageTextDropTarget(
            onUpdate: actions.onExternalDropUpdate,
            onDrop: actions.onExternalDrop,
            onCancel: actions.onExternalDropCancel
        )
        .macScrollMetrics(scrollMetrics)
        .macScrollPosition($scrollPosition)
        #if os(macOS)
        .macPageDragReorder(
            layoutCache: layoutCache,
            isReorderEnabled: isMacReorderEnabled,
            onBegan: { id, location, anchor in
                activeReorderLocation = location
                actions.onReorderBegin(id, location, anchor)
                updateReorderAutoScroll(for: location)
            },
            onChanged: { location, anchor in
                activeReorderLocation = location
                actions.onReorderChanged(location, anchor)
                updateReorderAutoScroll(for: location)
            },
            onEnded: { location in
                activeReorderLocation = nil
                stopReorderAutoScroll()
                actions.onReorderEnded(location)
            }
        )
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                actions.onHover(layoutCache.blockIDAtY(location.y))
            case .ended:
                actions.onHover(nil)
            }
        }
        #endif
        .tapBelowRows { point in
            handlePageLevelTap(at: point)
        }
        .overlay(alignment: .topLeading) {
            liftOverlay
        }
        .onDisappear {
            stopPinchAutoScroll()
            stopReorderAutoScroll()
        }
    }

    private var trailingDropTarget: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: trailingDropHeight)
            .contentShape(Rectangle())
            .accessibilityIdentifier("block-drop-slot-\(rows.count)")
            .accessibilityLabel("Drop before block \(rows.count + 1)")
            .animation(.spring(response: 0.26, dampingFraction: 0.76), value: trailingDropHeight)
    }

    @ViewBuilder
    private var liftOverlay: some View {
        if let lift = activeLift {
            let size = lift.sourceFrame.size
            liftContent(lift.id, size)
                .frame(width: size.width, height: size.height, alignment: .leading)
                .scaleEffect(1.035)
                .position(
                    x: lift.location.x - lift.touchOffset.width + (size.width / 2),
                    y: lift.location.y - lift.touchOffset.height + (size.height / 2)
                )
                .allowsHitTesting(false)
                .zIndex(100)
        }
    }

    private func handlePageLevelTap(at point: CGPoint) {
        if let rowID = layoutCache.blockIDAtY(point.y),
           let frame = layoutCache.frame(of: rowID) {
            let handleLeft = frame.minX - gutterWidth
            if point.x >= handleLeft, point.x < frame.minX {
                actions.onTapGutter(rowID)
                return
            }
            if point.x >= frame.minX, point.x <= frame.maxX {
                actions.onTapRow(rowID)
                return
            }
        }
        actions.onTapBelowRows(point)
    }

    private func updatePinchAutoScroll(for location: CGPoint) {
        let threshold: CGFloat = 88
        let maxVelocity: CGFloat = 520
        let velocity = edgeScrollVelocity(for: location, threshold: threshold, maxVelocity: maxVelocity)
        pinchAutoScrollVelocity = velocity
        if abs(velocity) > 1 {
            startPinchAutoScrollIfNeeded()
        } else {
            stopPinchAutoScroll()
        }
    }

    private func startPinchAutoScrollIfNeeded() {
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

    private func stopPinchAutoScroll() {
        pinchAutoScrollVelocity = 0
        pinchAutoScrollTask?.cancel()
        pinchAutoScrollTask = nil
    }

    private func updateReorderAutoScroll(for location: CGPoint) {
        let threshold: CGFloat = 110
        let maxVelocity: CGFloat = 620
        let velocity = edgeScrollVelocity(for: location, threshold: threshold, maxVelocity: maxVelocity)
        reorderAutoScrollVelocity = velocity
        if abs(velocity) > 1 {
            startReorderAutoScrollIfNeeded()
        } else {
            stopReorderAutoScroll()
        }
    }

    private func startReorderAutoScrollIfNeeded() {
        guard reorderAutoScrollTask == nil else { return }
        reorderAutoScrollTask = Task { @MainActor in
            let frameDuration: TimeInterval = 1.0 / 60.0
            while !Task.isCancelled {
                let velocity = reorderAutoScrollVelocity
                if abs(velocity) <= 1 { break }
                scrollBy(velocity * frameDuration)
                if let location = activeReorderLocation {
                    actions.onReorderAutoscroll(location)
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
            reorderAutoScrollTask = nil
        }
    }

    private func stopReorderAutoScroll() {
        reorderAutoScrollVelocity = 0
        reorderAutoScrollTask?.cancel()
        reorderAutoScrollTask = nil
    }

    private func edgeScrollVelocity(for location: CGPoint, threshold: CGFloat, maxVelocity: CGFloat) -> CGFloat {
        let effectiveBottom = scrollMetrics.viewportHeight - scrollMetrics.topInset - scrollMetrics.bottomInset
        guard effectiveBottom > threshold * 2 else { return 0 }

        let topDistance = location.y
        let bottomDistance = effectiveBottom - location.y
        if topDistance < threshold {
            let progress = min(1, max(0, (threshold - topDistance) / threshold))
            return -maxVelocity * progress * progress
        }
        if bottomDistance < threshold {
            let progress = min(1, max(0, (threshold - bottomDistance) / threshold))
            return maxVelocity * progress * progress
        }
        return 0
    }

    private func scrollBy(_ deltaY: CGFloat) {
        let maxOffset = max(0, scrollMetrics.contentHeight - scrollMetrics.viewportHeight)
        let nextOffset = min(maxOffset, max(0, scrollMetrics.contentOffsetY + deltaY))
        guard abs(nextOffset - scrollMetrics.contentOffsetY) > 0.5 else { return }
        #if os(iOS)
        PageScrollController.shared.scroll(toY: nextOffset)
        #else
        scrollPosition.scrollTo(point: CGPoint(x: 0, y: nextOffset))
        #endif
    }
}

extension View {
    @ViewBuilder
    func iosPageTextDropTarget(
        onUpdate: @escaping (CGFloat) -> Void,
        onDrop: @escaping (String, CGFloat) -> Void,
        onCancel: @escaping () -> Void
    ) -> some View {
        #if os(iOS)
        self.onDrop(
            of: [UTType.plainText],
            delegate: RowSurfaceTextDropDelegate(
                onUpdate: onUpdate,
                onDrop: onDrop,
                onCancel: onCancel
            )
        )
        #else
        self
        #endif
    }
}

#if os(iOS)
private struct RowSurfaceTextDropDelegate: DropDelegate {
    let onUpdate: (CGFloat) -> Void
    let onDrop: (String, CGFloat) -> Void
    let onCancel: () -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? {
        onUpdate(info.location.y)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        onCancel()
    }

    func performDrop(info: DropInfo) -> Bool {
        let y = info.location.y
        let dropSpring = Animation.spring(response: 0.26, dampingFraction: 0.76)

        guard let provider = info.itemProviders(for: [UTType.plainText]).first else {
            withAnimation(dropSpring) { onCancel() }
            return false
        }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? NSString else {
                Task { @MainActor in
                    withAnimation(dropSpring) { onCancel() }
                }
                return
            }
            let payload = String(string)
            Task { @MainActor in
                withAnimation(dropSpring) {
                    onDrop(payload, y)
                    onCancel()
                }
            }
        }
        return true
    }
}
#endif
