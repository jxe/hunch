import CoreGraphics
import Testing
@testable import Editor

@Suite("Reorder drop resolver")
struct ReorderDropResolverTests {
    @Test func resolvesByRowMidlines() {
        let frames = makeFrames(count: 4)

        #expect(ReorderDropResolver.insertionIndex(forY: -20, rowFrames: frames) == 0)
        #expect(ReorderDropResolver.insertionIndex(forY: 10, rowFrames: frames) == 0)
        #expect(ReorderDropResolver.insertionIndex(forY: 31, rowFrames: frames) == 1)
        #expect(ReorderDropResolver.insertionIndex(forY: 91, rowFrames: frames) == 2)
        #expect(ReorderDropResolver.insertionIndex(forY: 260, rowFrames: frames) == 4)
    }

    @Test func keepsPreviousSlotInsideHysteresisBandWhenDraggingDown() {
        let frames = makeFrames(count: 3)

        #expect(
            ReorderDropResolver.insertionIndex(
                forY: 35,
                rowFrames: frames,
                previousIndex: 0,
                hysteresis: 10
            ) == 0
        )
        #expect(
            ReorderDropResolver.insertionIndex(
                forY: 41,
                rowFrames: frames,
                previousIndex: 0,
                hysteresis: 10
            ) == 1
        )
    }

    @Test func keepsPreviousSlotInsideHysteresisBandWhenDraggingUp() {
        let frames = makeFrames(count: 3)

        #expect(
            ReorderDropResolver.insertionIndex(
                forY: 25,
                rowFrames: frames,
                previousIndex: 1,
                hysteresis: 10
            ) == 1
        )
        #expect(
            ReorderDropResolver.insertionIndex(
                forY: 19,
                rowFrames: frames,
                previousIndex: 1,
                hysteresis: 10
            ) == 0
        )
    }

    @Test func doesNotAlternateForSmallJitterAroundBoundary() {
        let frames = makeFrames(count: 3)
        var index = 1

        for y in [29, 31, 28, 32, 27, 33, 30] as [CGFloat] {
            index = ReorderDropResolver.insertionIndex(
                forY: y,
                rowFrames: frames,
                previousIndex: index,
                hysteresis: 10
            )
            #expect(index == 1)
        }
    }

    // When the drift gap is rendered as layout space *between* row frames
    // (not absorbed into the row below's frame), a finger anywhere in the
    // visual gap region must stay at the slot above the gap. Before
    // EditorView's geometry observer was moved above the reorder padding,
    // the row below absorbed the gap into its frame, its midY shifted into
    // the gap, and dragging into the lower half of the open gap flipped the
    // slot to the next row.
    @Test func dropSlotStaysStableAcrossEntireGapRegion() {
        let frames: [ReorderDropFrame] = [
            ReorderDropFrame(frame: CGRect(x: 0, y: 0,   width: 320, height: 30)),
            ReorderDropFrame(frame: CGRect(x: 0, y: 72,  width: 320, height: 30)),
            ReorderDropFrame(frame: CGRect(x: 0, y: 102, width: 320, height: 30)),
        ]
        for y: CGFloat in [31, 45, 60, 71] {
            #expect(
                ReorderDropResolver.insertionIndex(
                    forY: y,
                    rowFrames: frames,
                    previousIndex: 1
                ) == 1
            )
        }
    }

    @MainActor
    @Test func cacheBackedFramesKeepDropSlotStableAcrossGapRegion() {
        let cache = RowSurfaceLayoutCache<String>()
        cache.updateOrder(["a", "b", "c"], topGaps: ["b": 42])
        cache.setHeight(30, for: "a")
        cache.setHeight(30, for: "b")
        cache.setHeight(30, for: "c")
        cache.contentWidth = 320

        let frames = ["a", "b", "c"].compactMap { id in
            cache.frame(of: id).map { ReorderDropFrame(frame: $0) }
        }

        for y: CGFloat in [31, 45, 60, 71] {
            #expect(
                ReorderDropResolver.insertionIndex(
                    forY: y,
                    rowFrames: frames,
                    previousIndex: 1
                ) == 1
            )
        }
    }

    @MainActor
    @Test func cacheBackedFramesKeepDropSlotStableAcrossLargeBeforeRowSpacing() {
        let cache = RowSurfaceLayoutCache<String>()
        cache.updateOrder(["a", "heading", "c"], topGaps: ["heading": 32])
        cache.setHeight(20, for: "a")
        cache.setHeight(16, for: "heading")
        cache.setHeight(20, for: "c")
        cache.contentWidth = 320

        let frames = ["a", "heading", "c"].compactMap { id in
            cache.frame(of: id).map { ReorderDropFrame(frame: $0) }
        }

        for y: CGFloat in [21, 34, 51] {
            #expect(
                ReorderDropResolver.insertionIndex(
                    forY: y,
                    rowFrames: frames,
                    previousIndex: 1
                ) == 1
            )
        }
    }

    @Test func acceptsLargeJumpsWithoutStickyIntermediateSlots() {
        let frames = makeFrames(count: 5)

        #expect(
            ReorderDropResolver.insertionIndex(
                forY: 301,
                rowFrames: frames,
                previousIndex: 0,
                hysteresis: 10
            ) == 5
        )
    }

    private func makeFrames(count: Int) -> [ReorderDropFrame] {
        (0..<count).map { i in
            ReorderDropFrame(frame: CGRect(x: 0, y: CGFloat(i) * 60, width: 320, height: 60))
        }
    }
}

@Suite("iOS page reorder geometry")
struct IOSPageReorderGeometryTests {
    @Test func convertsScrollViewLocationToPageCoordinateAfterScroll() {
        let scrollViewLocation = CGPoint(x: 160, y: 620)

        #expect(
            IOSPageReorderGeometry.pageLocation(
                forScrollViewLocation: scrollViewLocation,
                contentOffset: CGPoint(x: 0, y: 300),
                adjustedTopInset: 100
            ) == CGPoint(x: 160, y: 220)
        )
    }

    @Test func doesNotShiftTopPositionForAdjustedInsetAtRest() {
        let scrollViewLocation = CGPoint(x: 160, y: 220)

        #expect(
            IOSPageReorderGeometry.pageLocation(
                forScrollViewLocation: scrollViewLocation,
                contentOffset: CGPoint(x: 0, y: -100),
                adjustedTopInset: 100
            ) == CGPoint(x: 160, y: 220)
        )
    }
}
