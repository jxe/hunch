import CoreGraphics
import Testing
@testable import UI
import Core

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
            ReorderDropFrame(
                id: BlockID(),
                frame: CGRect(x: 0, y: CGFloat(i) * 60, width: 320, height: 60)
            )
        }
    }
}
