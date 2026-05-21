import CoreGraphics
import Testing
@testable import Editor

@Suite("BlockLayoutCache")
@MainActor
struct BlockLayoutCacheTests {
    @Test func setHeightGuardsSameValueWrites() {
        let cache = BlockLayoutCache()
        let id = BlockID()
        cache.updateOrder([id])
        #expect(cache.setHeight(40, for: id) == true)
        #expect(cache.setHeight(40, for: id) == false)
        #expect(cache.setHeight(42, for: id) == true)
    }

    @Test func offsetsAreCumulative() {
        let cache = BlockLayoutCache()
        let ids = (0..<4).map { _ in BlockID() }
        cache.updateOrder(ids)
        cache.setHeight(10, for: ids[0])
        cache.setHeight(20, for: ids[1])
        cache.setHeight(30, for: ids[2])
        cache.setHeight(40, for: ids[3])
        #expect(cache.offsets == [0, 10, 30, 60, 100])
        #expect(cache.contentHeight == 100)
    }

    @Test func indexAtInternalYBinarySearches() {
        let cache = BlockLayoutCache()
        let ids = (0..<4).map { _ in BlockID() }
        cache.updateOrder(ids)
        cache.setHeight(50, for: ids[0])
        cache.setHeight(50, for: ids[1])
        cache.setHeight(50, for: ids[2])
        cache.setHeight(50, for: ids[3])

        // y ∈ [0, 50) is row 0; [50, 100) is row 1; …
        #expect(cache.indexAtInternalY(0) == 0)
        #expect(cache.indexAtInternalY(49.9) == 0)
        #expect(cache.indexAtInternalY(50) == 1)
        #expect(cache.indexAtInternalY(149) == 2)
        #expect(cache.indexAtInternalY(199.9) == 3)
        // Outside the content extent.
        #expect(cache.indexAtInternalY(-1) == nil)
        #expect(cache.indexAtInternalY(200) == nil)
    }

    @Test func blockIDAtInternalYMapsThroughOrder() {
        let cache = BlockLayoutCache()
        let ids = (0..<3).map { _ in BlockID() }
        cache.updateOrder(ids)
        cache.setHeight(30, for: ids[0])
        cache.setHeight(30, for: ids[1])
        cache.setHeight(30, for: ids[2])
        #expect(cache.blockIDAtInternalY(0) == ids[0])
        #expect(cache.blockIDAtInternalY(45) == ids[1])
        #expect(cache.blockIDAtInternalY(75) == ids[2])
        #expect(cache.blockIDAtInternalY(90) == nil)
    }

    @Test func nearestBlockIDAtInternalYFallsBackToMidY() {
        let cache = BlockLayoutCache()
        let ids = (0..<3).map { _ in BlockID() }
        cache.updateOrder(ids)
        cache.setHeight(30, for: ids[0])
        cache.setHeight(30, for: ids[1])
        cache.setHeight(30, for: ids[2])
        // Outside content extent — falls back to closest midY.
        #expect(cache.nearestBlockIDAtInternalY(-100) == ids[0])
        #expect(cache.nearestBlockIDAtInternalY(1000) == ids[2])
        // Inside — same as blockIDAtInternalY.
        #expect(cache.nearestBlockIDAtInternalY(15) == ids[0])
    }

    @Test func updateOrderRecomputesOffsets() {
        let cache = BlockLayoutCache()
        let a = BlockID()
        let b = BlockID()
        let c = BlockID()
        cache.updateOrder([a, b, c])
        cache.setHeight(10, for: a)
        cache.setHeight(20, for: b)
        cache.setHeight(30, for: c)
        #expect(cache.contentHeight == 60)
        // Swap to a different order; cached heights survive (b, a, c).
        cache.updateOrder([b, a, c])
        #expect(cache.offsets == [0, 20, 30, 60])
        #expect(cache.indexByID[b] == 0)
        #expect(cache.indexByID[a] == 1)
    }

    @Test func unmeasuredRowsContributeZero() {
        let cache = BlockLayoutCache()
        let a = BlockID()
        let b = BlockID()
        cache.updateOrder([a, b])
        cache.setHeight(40, for: a)
        // b's height never set.
        #expect(cache.offsets == [0, 40, 40])
        #expect(cache.frame(of: b) == nil) // no synthetic frame without height
        #expect(cache.frame(of: a)?.height == 40)
    }

    @Test func pageCoordsApplyContentOrigin() {
        let cache = BlockLayoutCache()
        let id = BlockID()
        cache.updateOrder([id])
        cache.setHeight(50, for: id)
        cache.contentOriginX = 30
        cache.contentOriginY = 100
        cache.contentWidth = 600

        let frame = cache.frame(of: id)
        #expect(frame?.minX == 30)
        #expect(frame?.minY == 100)
        #expect(frame?.width == 600)
        #expect(frame?.height == 50)

        // blockIDAtY uses page coords: y in [100, 150) is the row.
        #expect(cache.blockIDAtY(99) == nil)
        #expect(cache.blockIDAtY(100) == id)
        #expect(cache.blockIDAtY(149) == id)
        #expect(cache.blockIDAtY(150) == nil)
    }
}
