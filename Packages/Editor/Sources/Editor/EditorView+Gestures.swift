import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

// Gesture / interaction plumbing for EditorView: cross-platform View
// modifiers that wrap the per-platform gestures, plus the iOS UIKit
// gesture-recognizer bridges (reorder / pinch / swipe), the scroll-metrics
// reader, the page-level drop delegate, and the small geometry helpers
// (preference key, PRNG) those depend on. None of this touches Editor
// model types directly — it's all closure-based callbacks.

extension View {
    @ViewBuilder
    func iosPageBlockDropTarget(
        onUpdate: @escaping (CGFloat) -> Void,
        onDrop: @escaping (BlockDragPayload, CGFloat) -> Void,
        onCancel: @escaping () -> Void
    ) -> some View {
        #if os(iOS)
        self.onDrop(
            of: [UTType.plainText],
            delegate: PageBlockDropDelegate(
                onUpdate: onUpdate,
                onDrop: onDrop,
                onCancel: onCancel
            )
        )
        #else
        self
        #endif
    }

    @ViewBuilder
    func macNearestRowHover(rowFrames: [BlockID: CGRect], onChange: @escaping (BlockID?) -> Void) -> some View {
        #if os(macOS)
        self.onContinuousHover { phase in
            switch phase {
            case .active(let location):
                onChange(nearestRowID(to: location, in: rowFrames))
            case .ended:
                onChange(nil)
            }
        }
        #else
        self
        #endif
    }

    @ViewBuilder
    func macRowReorder(
        isEnabled: Bool,
        onChanged: @escaping (DragGesture.Value) -> Void,
        onEnded: @escaping (DragGesture.Value) -> Void
    ) -> some View {
        #if os(macOS)
        if isEnabled {
            self.simultaneousGesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named(PageHoverCoordinateSpace.name))
                    .onChanged(onChanged)
                    .onEnded(onEnded)
            )
        } else {
            self
        }
        #else
        self
        #endif
    }

    @ViewBuilder
    func iosBlockTouchActions(
        isEnabled: Bool,
        onDelete: @escaping () -> Void,
        onShowMenu: @escaping () -> Void
    ) -> some View {
        #if os(iOS)
        // Apply unconditionally; gate the gesture via isEnabled so the row's
        // view tree (and its layout) stays stable across pinch / edit mode
        // toggles. Swapping the modifier in/out caused per-row layout churn.
        self.modifier(IOSRowSwipeActions(isEnabled: isEnabled, onDelete: onDelete, onShowMenu: onShowMenu))
        #else
        self
        #endif
    }

    @ViewBuilder
    func blockActionPopover<Content: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        self.popover(isPresented: isPresented) {
            content()
                #if os(iOS)
                .presentationCompactAdaptation(.popover)
                #endif
        }
    }

    @ViewBuilder
    func iosPageReorder(
        isEnabled: Bool,
        rowFrames: [BlockID: CGRect],
        onBegin: @escaping (BlockID, CGPoint) -> Void,
        onChanged: @escaping (CGPoint) -> Void,
        onEnded: @escaping (CGPoint) -> Void,
        onCancelled: @escaping () -> Void
    ) -> some View {
        #if os(iOS)
        // Apply unconditionally; gate the recognizer via isEnabled. Avoids
        // ViewBuilder branch flips on every pinch — same pattern as
        // iosBlockTouchActions / iosPagePinch.
        self.background(
            IOSPageReorderGestureBridge(
                isEnabled: isEnabled,
                rowFrames: rowFrames,
                onBegin: onBegin,
                onChanged: onChanged,
                onEnded: onEnded,
                onCancelled: onCancelled
            )
        )
        #else
        self
        #endif
    }

    /// Unified page-level pinch: forwards every magnification update so the page
    /// can drive a live insert-gap preview, and forwards `.onEnded` so it can
    /// commit insert (open) or close-to-page-list. Replaces the prior
    /// open-on-row + close-on-page split — both directions now arbitrate
    /// through a single gesture.
    @ViewBuilder
    func iosPagePinch(
        isEnabled: Bool,
        onUpdate: @escaping (PagePinchValue) -> Void,
        onCommit: @escaping (PagePinchValue) -> Void
    ) -> some View {
        #if os(iOS)
        self.background(
            IOSPagePinchGestureBridge(
                isEnabled: isEnabled,
                onUpdate: onUpdate,
                onCommit: onCommit
            )
        )
        #else
        self
        #endif
    }

    @ViewBuilder
    func iosScrollMetrics(_ metrics: Binding<PageScrollMetrics>) -> some View {
        #if os(iOS)
        self.background(IOSScrollMetricsReader(metrics: metrics))
        #else
        self
        #endif
    }

    /// macOS counterpart to `iosScrollMetrics` — wires SwiftUI's
    /// `.onScrollGeometryChange` to publish the same `PageScrollMetrics`. Pinch
    /// and reorder auto-scroll both read from this; programmatic scroll on
    /// macOS goes through `macScrollPosition` below.
    @ViewBuilder
    func macScrollMetrics(_ metrics: Binding<PageScrollMetrics>) -> some View {
        #if os(macOS)
        self
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, new in
                metrics.wrappedValue.contentOffsetY = new
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, new in
                metrics.wrappedValue.contentHeight = new
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height } action: { _, new in
                metrics.wrappedValue.viewportHeight = new
            }
        #else
        self
        #endif
    }

    /// macOS-only `.scrollPosition` binding for programmatic scroll (auto-scroll
    /// during pinch / reorder). NOT applied on iOS — there, programmatic scroll
    /// goes through the UIScrollView bridge in `PageScrollController`. Attaching
    /// `.scrollPosition` on iOS competes with that path and silently breaks it.
    @ViewBuilder
    func macScrollPosition(_ position: Binding<ScrollPosition>) -> some View {
        #if os(macOS)
        self.scrollPosition(position)
        #else
        self
        #endif
    }

    /// Tap-below-rows: clicking past the end of the document creates a fresh
    /// trailing paragraph at the document root. Cross-platform — the
    /// underlying `handleTapBelowRows` already gates on cursor position past
    /// the last row's frame, so a click anywhere in the empty trailing
    /// region triggers a new paragraph there.
    @ViewBuilder
    func tapBelowRows(_ onTap: @escaping (CGPoint) -> Void) -> some View {
        self.simultaneousGesture(
            SpatialTapGesture()
                .onEnded { value in
                    onTap(value.location)
                }
        )
    }

    @ViewBuilder
    func iosEdgeGateNavigateBack() -> some View {
        #if os(iOS)
        self.background(IOSNavigationBackGestureGate())
        #else
        self
        #endif
    }
}

// MARK: - Shared platform-neutral helpers

struct PagePinchValue {
    var startLocation: CGPoint
    var location: CGPoint
    var magnification: CGFloat
    var spread: CGFloat
    var spreadDelta: CGFloat
}

struct PageScrollMetrics: Equatable {
    var viewportHeight: CGFloat = 0
    var contentHeight: CGFloat = 0
    var contentOffsetY: CGFloat = 0
    /// Top + bottom adjusted-content-insets on iOS (nav bar + safe area on top,
    /// home-indicator safe area on bottom). The autoscroll edge bands are
    /// measured against the *content area* (`viewportHeight - topInset -
    /// bottomInset`), not the raw viewport: `pageLocation` already shifts y=0
    /// to "top of content area", and for the bottom band to be symmetric the
    /// edge must sit at the bottom of the content area too. Both default to 0
    /// on macOS — viewport == content area there.
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
}

enum PageHoverCoordinateSpace {
    static let name = "EditorView.hover"
}

struct RowFramePreferenceKey: PreferenceKey {
    static let defaultValue: [BlockID: CGRect] = [:]

    static func reduce(value: inout [BlockID: CGRect], nextValue: () -> [BlockID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

func nearestRowID(to point: CGPoint, in frames: [BlockID: CGRect]) -> BlockID? {
    frames.min { lhs, rhs in
        abs(lhs.value.midY - point.y) < abs(rhs.value.midY - point.y)
    }?.key
}

struct IOSPageReorderGeometry {
    static func pageLocation(
        forScrollViewLocation location: CGPoint,
        contentOffset: CGPoint,
        adjustedTopInset: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: location.x - contentOffset.x,
            y: location.y - effectiveScrollOffsetY(
                contentOffsetY: contentOffset.y,
                adjustedTopInset: adjustedTopInset
            )
        )
    }

    private static func effectiveScrollOffsetY(contentOffsetY: CGFloat, adjustedTopInset: CGFloat) -> CGFloat {
        max(0, contentOffsetY + adjustedTopInset)
    }
}

/// Linear-congruential PRNG — deterministic per seed so the grain pattern
/// stays put across re-renders (and frames during animation).
struct SeededLCG {
    private var state: UInt32
    init(seed: UInt32) { self.state = seed }
    mutating func next01() -> Double {
        state = state &* 1_664_525 &+ 1_013_904_223
        return Double(state) / Double(UInt32.max)
    }
}

#if os(iOS)

// MARK: - iOS UIKit bridges

struct IOSNavigationBackGestureGate: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.installWhenReady()
    }

    final class Controller: UIViewController {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            installWhenReady()
        }

        func installWhenReady() {
            guard let navigationController else { return }
            navigationController.interactiveContentPopGestureRecognizer?.isEnabled = false
            navigationController.interactivePopGestureRecognizer?.isEnabled = true
        }
    }
}

/// Page-level reorder gesture. Walks up to the enclosing `UIScrollView`,
/// attaches a `UILongPressGestureRecognizer` to it, and tells the scroll
/// view's pan recognizer to `require(toFail:)` it. UIKit-level coordination
/// is what lets the page scroll on a fast vertical drag (motion exceeds
/// `allowableMovement` before the timer fires → long-press fails → pan
/// proceeds) while still entering reorder on a deliberate hold (timer
/// fires within tolerance → long-press wins → pan never starts).
///
/// Prior SwiftUI implementation used `LongPressGesture.sequenced(before:
/// DragGesture(0))` per row. That triggered SwiftUI's "system gesture gate"
/// after `.first(true)` and stranded touches — no further events to either
/// the row gesture or the scroll view, leaving rows dimmed and scroll
/// blocked. Removing the SwiftUI long-press but keeping `DragGesture(0)`
/// didn't help either: `DragGesture(minimumDistance: 0)` claims the touch
/// at the SwiftUI layer and blocks the scroll view's pan even when our
/// handler ignores the events.
struct IOSPageReorderGestureBridge: UIViewRepresentable {
    var isEnabled: Bool
    var rowFrames: [BlockID: CGRect]
    var onBegin: (BlockID, CGPoint) -> Void
    var onChanged: (CGPoint) -> Void
    var onEnded: (CGPoint) -> Void
    var onCancelled: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = HostView()
        view.coordinator = context.coordinator
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.recognizer?.isEnabled = isEnabled
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class HostView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                coordinator?.attach(from: self)
            } else {
                coordinator?.detach()
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: IOSPageReorderGestureBridge
        weak var recognizer: UILongPressGestureRecognizer?
        weak var scrollView: UIScrollView?
        private var activeBlockID: BlockID?

        init(parent: IOSPageReorderGestureBridge) {
            self.parent = parent
        }

        func attach(from view: UIView) {
            guard recognizer == nil else { return }
            var current: UIView? = view.superview
            while let v = current {
                if let scroll = v as? UIScrollView {
                    let lp = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
                    lp.minimumPressDuration = 0.5
                    lp.allowableMovement = 8
                    lp.cancelsTouchesInView = false
                    lp.delegate = self
                    lp.isEnabled = parent.isEnabled
                    scroll.addGestureRecognizer(lp)
                    scroll.panGestureRecognizer.require(toFail: lp)
                    self.recognizer = lp
                    self.scrollView = scroll
                    return
                }
                current = v.superview
            }
        }

        func detach() {
            if let recognizer, let scrollView {
                scrollView.removeGestureRecognizer(recognizer)
            }
            recognizer = nil
            scrollView = nil
            activeBlockID = nil
        }

        @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard let scrollView else { return }
            let location = pageCoordinateLocation(for: recognizer, scrollView: scrollView)
            switch recognizer.state {
            case .began:
                guard let blockID = nearestRowID(to: location, frames: parent.rowFrames) else {
                    activeBlockID = nil
                    return
                }
                activeBlockID = blockID
                parent.onBegin(blockID, location)
            case .changed:
                guard activeBlockID != nil else { return }
                parent.onChanged(location)
            case .ended:
                if activeBlockID != nil {
                    parent.onEnded(location)
                }
                activeBlockID = nil
            case .cancelled, .failed:
                if activeBlockID != nil {
                    parent.onCancelled()
                }
                activeBlockID = nil
            default:
                break
            }
        }

        private func pageCoordinateLocation(
            for recognizer: UIGestureRecognizer,
            scrollView: UIScrollView
        ) -> CGPoint {
            IOSPageReorderGeometry.pageLocation(
                forScrollViewLocation: recognizer.location(in: scrollView),
                contentOffset: scrollView.contentOffset,
                adjustedTopInset: scrollView.adjustedContentInset.top
            )
        }

        private func nearestRowID(to point: CGPoint, frames: [BlockID: CGRect]) -> BlockID? {
            frames
                .filter { $0.value.contains(point) }
                .min(by: { abs($0.value.midY - point.y) < abs($1.value.midY - point.y) })?
                .key
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === recognizer,
                  let scrollView else {
                return true
            }
            let location = pageCoordinateLocation(for: gestureRecognizer, scrollView: scrollView)
            return nearestRowID(to: location, frames: parent.rowFrames) != nil
        }
    }
}

/// Page-level pinch gesture. Walks up to the enclosing `UIScrollView`, attaches
/// a `UIPinchGestureRecognizer` and reads the live finger positions via
/// `location(ofTouch:in:)` so we can emit the *actual* pixel distance the
/// fingers have spread. SwiftUI's `MagnifyGesture` only exposes a magnification
/// ratio, which forces a magic-number assumption about start finger distance —
/// pinch felt amplified at narrow grips and undersized at wide grips.
struct IOSPagePinchGestureBridge: UIViewRepresentable {
    var isEnabled: Bool
    var onUpdate: (PagePinchValue) -> Void
    var onCommit: (PagePinchValue) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = HostView()
        view.coordinator = context.coordinator
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.recognizer?.isEnabled = isEnabled
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class HostView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                coordinator?.attach(from: self)
            } else {
                coordinator?.detach()
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: IOSPagePinchGestureBridge
        weak var recognizer: UIPinchGestureRecognizer?
        weak var scrollView: UIScrollView?
        private var startDistance: CGFloat = 0
        private var startMidpoint: CGPoint = .zero

        init(parent: IOSPagePinchGestureBridge) {
            self.parent = parent
        }

        func attach(from view: UIView) {
            guard recognizer == nil else { return }
            var current: UIView? = view.superview
            while let v = current {
                if let scroll = v as? UIScrollView {
                    let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
                    pinch.cancelsTouchesInView = false
                    pinch.delegate = self
                    pinch.isEnabled = parent.isEnabled
                    scroll.addGestureRecognizer(pinch)
                    self.recognizer = pinch
                    self.scrollView = scroll
                    return
                }
                current = v.superview
            }
        }

        func detach() {
            if let recognizer, let scrollView {
                scrollView.removeGestureRecognizer(recognizer)
            }
            recognizer = nil
            scrollView = nil
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard let scrollView else { return }
            switch recognizer.state {
            case .began:
                guard recognizer.numberOfTouches >= 2 else { return }
                let p0 = recognizer.location(ofTouch: 0, in: scrollView)
                let p1 = recognizer.location(ofTouch: 1, in: scrollView)
                startDistance = hypot(p0.x - p1.x, p0.y - p1.y)
                let midScroll = CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
                startMidpoint = pageCoordinateLocation(for: midScroll, scrollView: scrollView)
                parent.onUpdate(makeValue(recognizer: recognizer, scrollView: scrollView, currentDistance: startDistance))
            case .changed:
                let distance = currentDistance(recognizer: recognizer, scrollView: scrollView)
                parent.onUpdate(makeValue(recognizer: recognizer, scrollView: scrollView, currentDistance: distance))
            case .ended, .cancelled, .failed:
                let distance = currentDistance(recognizer: recognizer, scrollView: scrollView)
                parent.onCommit(makeValue(recognizer: recognizer, scrollView: scrollView, currentDistance: distance))
            default:
                break
            }
        }

        private func currentDistance(recognizer: UIPinchGestureRecognizer, scrollView: UIScrollView) -> CGFloat {
            guard recognizer.numberOfTouches >= 2 else {
                // One finger lifted before .ended — fall back to scale × startDistance.
                return startDistance * recognizer.scale
            }
            let p0 = recognizer.location(ofTouch: 0, in: scrollView)
            let p1 = recognizer.location(ofTouch: 1, in: scrollView)
            return hypot(p0.x - p1.x, p0.y - p1.y)
        }

        private func makeValue(
            recognizer: UIPinchGestureRecognizer,
            scrollView: UIScrollView,
            currentDistance: CGFloat
        ) -> PagePinchValue {
            let midScroll: CGPoint
            if recognizer.numberOfTouches >= 2 {
                let p0 = recognizer.location(ofTouch: 0, in: scrollView)
                let p1 = recognizer.location(ofTouch: 1, in: scrollView)
                midScroll = CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
            } else {
                midScroll = recognizer.location(in: scrollView)
            }
            let midPage = pageCoordinateLocation(for: midScroll, scrollView: scrollView)
            return PagePinchValue(
                startLocation: startMidpoint,
                location: midPage,
                magnification: recognizer.scale,
                spread: currentDistance,
                spreadDelta: currentDistance - startDistance
            )
        }

        private func pageCoordinateLocation(
            for scrollLocation: CGPoint,
            scrollView: UIScrollView
        ) -> CGPoint {
            IOSPageReorderGeometry.pageLocation(
                forScrollViewLocation: scrollLocation,
                contentOffset: scrollView.contentOffset,
                adjustedTopInset: scrollView.adjustedContentInset.top
            )
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

struct PageBlockDropDelegate: DropDelegate {
    let onUpdate: (CGFloat) -> Void
    let onDrop: (BlockDragPayload, CGFloat) -> Void
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
            guard let string = object as? NSString,
                  let payload = BlockDragPayload(jsonString: string as String) else {
                Task { @MainActor in
                    withAnimation(dropSpring) { onCancel() }
                }
                return
            }
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

@MainActor
final class PageScrollController {
    static let shared = PageScrollController()

    weak var scrollView: UIScrollView?

    func scroll(toY y: CGFloat) {
        guard let scrollView else { return }
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: y), animated: false)
    }
}

struct IOSScrollMetricsReader: UIViewRepresentable {
    @Binding var metrics: PageScrollMetrics

    func makeCoordinator() -> Coordinator {
        Coordinator(metrics: $metrics)
    }

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: ReaderView, context: Context) {
        context.coordinator.metrics = $metrics
        uiView.coordinator = context.coordinator
        uiView.installIfNeeded()
    }

    @MainActor
    final class ReaderView: UIView {
        weak var coordinator: Coordinator?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            isUserInteractionEnabled = false
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            installIfNeeded()
            DispatchQueue.main.async { [weak self] in
                self?.installIfNeeded()
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            installIfNeeded()
            DispatchQueue.main.async { [weak self] in
                self?.installIfNeeded()
            }
        }

        func installIfNeeded() {
            guard let scrollView = nearestScrollView() else { return }
            PageScrollController.shared.scrollView = scrollView
            coordinator?.update(from: scrollView)
        }

        private func nearestScrollView() -> UIScrollView? {
            var current = superview
            while let view = current {
                if let scrollView = view as? UIScrollView {
                    return scrollView
                }
                current = view.superview
            }
            return nil
        }
    }

    @MainActor
    final class Coordinator {
        var metrics: Binding<PageScrollMetrics>
        private weak var observedScrollView: UIScrollView?
        private var observation: NSKeyValueObservation?
        private var boundsObservation: NSKeyValueObservation?
        private var contentSizeObservation: NSKeyValueObservation?

        init(metrics: Binding<PageScrollMetrics>) {
            self.metrics = metrics
        }

        func update(from scrollView: UIScrollView) {
            if observedScrollView !== scrollView {
                observedScrollView = scrollView
                observation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self, weak scrollView] _, _ in
                    Task { @MainActor in
                        guard let self, let scrollView else { return }
                        self.publish(scrollView)
                    }
                }
                boundsObservation = scrollView.observe(\.bounds, options: [.new]) { [weak self, weak scrollView] _, _ in
                    Task { @MainActor in
                        guard let self, let scrollView else { return }
                        self.publish(scrollView)
                    }
                }
                contentSizeObservation = scrollView.observe(\.contentSize, options: [.new]) { [weak self, weak scrollView] _, _ in
                    Task { @MainActor in
                        guard let self, let scrollView else { return }
                        self.publish(scrollView)
                    }
                }
            }
            // updateUIView / didMoveToWindow run inside SwiftUI's view-update pass —
            // writing the binding synchronously here trips "Modifying state during
            // view update" and a matching AttributeGraph cycle. Defer like the KVO
            // observers do.
            Task { @MainActor [weak self, weak scrollView] in
                guard let self, let scrollView else { return }
                self.publish(scrollView)
            }
        }

        private func publish(_ scrollView: UIScrollView) {
            let next = PageScrollMetrics(
                viewportHeight: scrollView.bounds.height,
                contentHeight: scrollView.contentSize.height,
                contentOffsetY: scrollView.contentOffset.y,
                topInset: scrollView.adjustedContentInset.top,
                bottomInset: scrollView.adjustedContentInset.bottom
            )
            if metrics.wrappedValue != next {
                metrics.wrappedValue = next
            }
        }
    }
}

/// Horizontal-swipe actions on a row: leading swipe (right) reveals an
/// `ellipsis.circle.fill` glyph and, past the trigger, opens the row's
/// action sheet. Trailing swipe (left) deletes. SwiftUI's `.swipeActions`
/// only fires inside a `List`, but the page is built on a `VStack` to keep
/// typography control, so this is a manual horizontal pan that tracks the
/// row offset, reveals per-edge action labels, and commits past a threshold.
///
/// The pan is a UIKit bridge rather than a SwiftUI `DragGesture` because
/// SwiftUI drag gestures claim the touch at the SwiftUI layer once their
/// minimum distance is crossed in *any* direction; the page's UIScrollView
/// pan can then never start, killing scrolls that began on a row. Same
/// failure mode the page-reorder bridge documents above. The bridge here
/// installs a `UIPanGestureRecognizer` on the enclosing scroll view and
/// fails it at `gestureRecognizerShouldBegin` time when initial motion is
/// vertical-dominant — releasing the touch back to the scroll view's pan.
struct IOSRowSwipeActions: ViewModifier {
    let isEnabled: Bool
    let onDelete: () -> Void
    let onShowMenu: () -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var triggered: Bool = false
    @State private var crossedDeleteThreshold: Bool = false

    private let trigger: CGFloat = 96
    private let revealCap: CGFloat = 140

    func body(content: Content) -> some View {
        let rightOffset = min(revealCap, max(0, dragOffset))
        let revealProgress = min(1, rightOffset / trigger)
        let deleteProgress = min(1, max(0, -dragOffset) / trigger)

        let crossed = revealProgress >= 1
        let iconSize: CGFloat = crossed ? 26 : 14 + (revealProgress * 8)

        let isSwiping = revealProgress > 0

        // Layout intent: row size is determined by typography (BlockSpacing /
        // BlockRow's intrinsic padding), NOT by these affordances. Icon goes
        // BEHIND content via .background so its 34pt capsule doesn't propagate
        // upward — overflowing visually if the row is shorter is fine and only
        // happens transiently during a swipe. Pencil line goes ON TOP via
        // .overlay, sized to content.
        content
            .background(isSwiping ? NotionStyle.background : Color.clear)
            .background(alignment: .leading) {
                if isSwiping {
                    ZStack {
                        Capsule()
                            .fill(Color.blue.opacity(0.18))
                            .frame(width: 44, height: 34)
                            .opacity(crossed ? 1 : 0)
                            .scaleEffect(crossed ? 1 : 0.6)

                        Image(systemName: "ellipsis")
                            .foregroundStyle(crossed ? Color.blue : Color.blue.opacity(0.65))
                            .font(.system(size: iconSize, weight: .semibold))
                    }
                    .padding(.leading, 4)
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: crossed)
                    .allowsHitTesting(false)
                }
            }
            .offset(x: rightOffset)
            .overlay {
                GeometryReader { geo in
                    pencilLine(
                        rowWidth: geo.size.width,
                        lineLength: geo.size.width * deleteProgress
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
                .allowsHitTesting(false)
            }
            .background {
                IOSRowSwipeGestureBridge(
                    isEnabled: isEnabled,
                    onChanged: { h in
                        guard !triggered else { return }
                        dragOffset = h
                        // The menu opens on threshold-crossed mid-gesture so the
                        // user can swipe-and-hold to peek the menu. Delete is
                        // destructive — only commits on release, but fire a haptic
                        // when the strike-through completes so the user knows
                        // releasing now will commit.
                        if h >= trigger {
                            fire(onShowMenu)
                        } else if h <= -trigger {
                            if !crossedDeleteThreshold {
                                crossedDeleteThreshold = true
                                Haptics.medium()
                            }
                        } else {
                            crossedDeleteThreshold = false
                        }
                    },
                    onEnded: { h in
                        if !triggered, h <= -trigger {
                            onDelete()
                            SoundFX.play(.delete)
                        }
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                            dragOffset = 0
                        }
                        triggered = false
                        crossedDeleteThreshold = false
                    },
                    onCancelled: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                            dragOffset = 0
                        }
                        triggered = false
                        crossedDeleteThreshold = false
                    }
                )
            }
            // Disabling the gesture mid-swipe (e.g. when a pinch starts) needs
            // to also reset the visual swipe state — otherwise a partially-
            // offset row stays offset until the user touches it again.
            .onChange(of: isEnabled) { _, newValue in
                guard !newValue else { return }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                    dragOffset = 0
                }
                triggered = false
                crossedDeleteThreshold = false
            }
    }

    private func fire(_ action: () -> Void) {
        triggered = true
        Haptics.medium()
        action()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            dragOffset = 0
        }
    }

    /// A graphite-style cross-out line drawn in a `Canvas`. Composited from a
    /// soft halo, a crisp core, and a deterministic scatter of grain dots that
    /// simulate the graphite catching on tooth of the paper. The grain pattern
    /// is keyed off a fixed seed so it stays put as the line extends — only the
    /// trailing-aligned mask grows with `lineLength`. At commit the stroke
    /// thickens/darkens and grain density bumps, like the pencil pressed harder.
    @ViewBuilder
    private func pencilLine(rowWidth: CGFloat, lineLength: CGFloat) -> some View {
        let armed = crossedDeleteThreshold
        let coreColor = Color(white: 0.18)
        let coreHeight: CGFloat = armed ? 2.4 : 1.6
        let coreOpacity: Double = armed ? 0.92 : 0.72
        let haloHeight: CGFloat = armed ? 6 : 4
        let haloOpacity: Double = armed ? 0.22 : 0.12
        let grainSpacing: CGFloat = armed ? 0.8 : 1.3
        let grainBoost: Double = armed ? 0.18 : 0

        Canvas { context, size in
            let centerY = size.height / 2

            let halo = Path(CGRect(
                x: 0, y: centerY - haloHeight / 2,
                width: size.width, height: haloHeight
            ))
            context.fill(halo, with: .color(coreColor.opacity(haloOpacity)))

            let core = Path(CGRect(
                x: 0, y: centerY - coreHeight / 2,
                width: size.width, height: coreHeight
            ))
            context.fill(core, with: .color(coreColor.opacity(coreOpacity)))

            var rng = SeededLCG(seed: 0xF1B2C3D4)
            let grainCount = Int(size.width / grainSpacing)
            for _ in 0..<grainCount {
                let x = CGFloat(rng.next01()) * size.width
                let yJitter = (CGFloat(rng.next01()) - 0.5) * 7
                let r = 0.25 + CGFloat(rng.next01()) * 0.7
                let opacity = 0.12 + rng.next01() * 0.42 + grainBoost
                let dot = Path(ellipseIn: CGRect(
                    x: x - r, y: centerY + yJitter - r,
                    width: r * 2, height: r * 2
                ))
                context.fill(dot, with: .color(coreColor.opacity(opacity)))
            }
        }
        .frame(width: rowWidth, height: 12)
        .mask(alignment: .trailing) {
            Color.black.frame(width: lineLength)
        }
        .animation(.spring(response: 0.18, dampingFraction: 0.7), value: armed)
    }
}

/// UIKit-bridged horizontal pan, scoped to one row, used by `IOSRowSwipeActions`.
/// Walks up to the enclosing `UIScrollView` and installs a
/// `UIPanGestureRecognizer` on it; gates recognition at begin time on
/// (a) initial touch landing within this row's host view and (b) translation
/// being horizontal-dominant. A vertical-dominant touch fails the recognizer,
/// releasing the touch to the scroll view's pan so the page can scroll.
struct IOSRowSwipeGestureBridge: UIViewRepresentable {
    var isEnabled: Bool
    var onChanged: (CGFloat) -> Void
    var onEnded: (CGFloat) -> Void
    var onCancelled: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = HostView()
        view.coordinator = context.coordinator
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.recognizer?.isEnabled = isEnabled
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class HostView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                coordinator?.attach(from: self)
            } else {
                coordinator?.detach()
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: IOSRowSwipeGestureBridge
        weak var recognizer: UIPanGestureRecognizer?
        weak var scrollView: UIScrollView?
        weak var hostView: UIView?

        init(parent: IOSRowSwipeGestureBridge) {
            self.parent = parent
        }

        func attach(from view: UIView) {
            guard recognizer == nil else { return }
            self.hostView = view
            var current: UIView? = view.superview
            while let v = current {
                if let scroll = v as? UIScrollView {
                    let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
                    pan.cancelsTouchesInView = false
                    pan.maximumNumberOfTouches = 1
                    pan.delegate = self
                    pan.isEnabled = parent.isEnabled
                    scroll.addGestureRecognizer(pan)
                    self.recognizer = pan
                    self.scrollView = scroll
                    return
                }
                current = v.superview
            }
        }

        func detach() {
            if let recognizer, let scrollView {
                scrollView.removeGestureRecognizer(recognizer)
            }
            recognizer = nil
            scrollView = nil
            hostView = nil
        }

        @objc func handlePan(_ rec: UIPanGestureRecognizer) {
            let t = rec.translation(in: rec.view)
            switch rec.state {
            case .changed:
                parent.onChanged(t.x)
            case .ended:
                parent.onEnded(t.x)
            case .cancelled, .failed:
                parent.onCancelled()
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === recognizer,
                  let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let host = hostView else {
                return true
            }
            // Initial touch must be on this row.
            let p = pan.location(in: host)
            guard host.bounds.contains(p) else { return false }
            // Initial motion must be horizontal-dominant — otherwise fail and
            // let the scroll view's pan take the touch.
            let t = pan.translation(in: host)
            return abs(t.x) > abs(t.y) * 1.4
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

#endif
