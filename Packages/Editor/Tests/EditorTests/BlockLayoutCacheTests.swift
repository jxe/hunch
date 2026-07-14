import CoreGraphics
import Foundation
import Testing
@testable import Editor

@Suite("RowSurfaceLayoutCache")
@MainActor
struct RowSurfaceLayoutCacheTests {
    @Test func setHeightGuardsSameValueWritesForGenericIDs() {
        let cache = RowSurfaceLayoutCache<String>()
        cache.updateOrder(["a"])
        #expect(cache.setHeight(40, for: "a") == true)
        #expect(cache.setHeight(40, for: "a") == false)
        #expect(cache.setHeight(44, for: "a") == true)
    }

    @Test func orderAndOffsetsUseGenericIDs() {
        let cache = RowSurfaceLayoutCache<String>()
        cache.updateOrder(["a", "b", "c"])
        cache.setHeight(10, for: "a")
        cache.setHeight(20, for: "b")
        cache.setHeight(30, for: "c")

        #expect(cache.offsets == [0, 10, 30, 60])
        #expect(cache.blockIDAtInternalY(35) == "c")

        cache.updateOrder(["b", "a", "c"])
        #expect(cache.offsets == [0, 20, 30, 60])
        #expect(cache.indexByID["b"] == 0)
    }

    @Test func pageCoordinateHitTestingUsesContentOrigin() {
        let cache = RowSurfaceLayoutCache<String>()
        cache.updateOrder(["row"])
        cache.setHeight(50, for: "row")
        cache.contentOriginX = 24
        cache.contentOriginY = 100
        cache.contentWidth = 320

        #expect(cache.blockIDAtY(99) == nil)
        #expect(cache.blockIDAtY(100) == "row")
        #expect(cache.blockIDAtY(149) == "row")
        #expect(cache.blockIDAtY(150) == nil)
        #expect(cache.frame(of: "row") == CGRect(x: 24, y: 100, width: 320, height: 50))
    }

    @Test func handleHitTestingIsScopedToLeadingGutter() {
        let cache = RowSurfaceLayoutCache<String>()
        cache.updateOrder(["row"])
        cache.setHeight(50, for: "row")
        cache.contentOriginX = 24
        cache.contentOriginY = 100
        cache.contentWidth = 320

        #expect(cache.blockIDAtHandlePoint(CGPoint(x: -4, y: 120), gutterWidth: 28) == "row")
        #expect(cache.blockIDAtHandlePoint(CGPoint(x: 23.9, y: 120), gutterWidth: 28) == "row")
        #expect(cache.blockIDAtHandlePoint(CGPoint(x: 24, y: 120), gutterWidth: 28) == nil)
        #expect(cache.blockIDAtHandlePoint(CGPoint(x: -4, y: 99), gutterWidth: 28) == nil)
        #expect(cache.blockIDAtHandlePoint(CGPoint(x: -5, y: 120), gutterWidth: 28) == nil)
    }

    @Test func unmeasuredRowsDoNotProduceFrames() {
        let cache = RowSurfaceLayoutCache<String>()
        cache.updateOrder(["measured", "unmeasured"])
        cache.setHeight(25, for: "measured")

        #expect(cache.offsets == [0, 25, 25])
        #expect(cache.frame(of: "measured")?.height == 25)
        #expect(cache.frame(of: "unmeasured") == nil)
    }

    @Test func topGapIsEmptySpaceBeforeRow() {
        let cache = RowSurfaceLayoutCache<String>()
        cache.updateOrder(["a", "b", "c"], topGaps: ["b": 42])
        cache.setHeight(30, for: "a")
        cache.setHeight(30, for: "b")
        cache.setHeight(30, for: "c")
        cache.contentOriginX = 24
        cache.contentOriginY = 100
        cache.contentWidth = 320

        #expect(cache.offsets == [0, 72, 102, 132])
        #expect(cache.contentHeight == 132)
        #expect(cache.frame(of: "b") == CGRect(x: 24, y: 172, width: 320, height: 30))
        #expect(cache.blockIDAtY(130) == nil)
        #expect(cache.blockIDAtInternalY(45) == nil)
        #expect(cache.nearestBlockIDAtInternalY(31) == "a")
        #expect(cache.nearestBlockIDAtInternalY(60) == "b")
    }

    @Test func realizedFramesChooseTouchedRowDespiteStaleCumulativeHeights() {
        let cache = RowSurfaceLayoutCache<String>()
        cache.updateOrder(["heading", "tall", "target"])

        // Deliberately stale cumulative measurements put the synthesized
        // target frame far above its actual on-screen position.
        cache.setHeight(20, for: "heading")
        cache.setHeight(20, for: "tall")
        cache.setHeight(20, for: "target")
        cache.contentOriginY = 100

        cache.setRealizedInternalFrame(CGRect(x: 0, y: 0, width: 320, height: 48), for: "heading")
        cache.setRealizedInternalFrame(CGRect(x: 0, y: 88, width: 320, height: 104), for: "tall")
        cache.setRealizedInternalFrame(CGRect(x: 0, y: 200, width: 320, height: 30), for: "target")

        #expect(cache.blockIDAtY(315) == nil)
        #expect(cache.realizedBlockIDAtPageY(315) == "target")
        #expect(cache.realizedBlockIDAtPageY(296) == nil) // inter-row spacing

        cache.removeRealizedInternalFrame(for: "target")
        #expect(cache.realizedBlockIDAtPageY(315) == nil)

        cache.setRealizedInternalFrame(CGRect(x: 0, y: 200, width: 320, height: 30), for: "target")
        cache.updateOrder(["heading", "tall"])
        #expect(cache.realizedInternalFrames["target"] == nil)
    }
}

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

    // MARK: - Structural row cache

    @Test func currentVisibleRowsCachesWithinStableSpan() {
        let cache = BlockLayoutCache()
        let a = Block.paragraph(text: AttributedString("a"))
        let b = Block.paragraph(text: AttributedString("b"))
        let snapshot = [a, b]

        let v0 = cache.structuralVersion
        let (rows1, _) = cache.currentVisibleRows(snapshot: snapshot, isCollapsed: { _ in false })
        let (rows2, _) = cache.currentVisibleRows(snapshot: snapshot, isCollapsed: { _ in false })

        #expect(rows1.count == 2)
        #expect(rows1.map(\.id) == rows2.map(\.id))
        // No invalidation between calls — version should not advance.
        #expect(cache.structuralVersion == v0)
    }

    @Test func invalidateStructureForcesRebuild() {
        let cache = BlockLayoutCache()
        let a = Block.paragraph(text: AttributedString("a"))
        let b = Block.paragraph(text: AttributedString("b"))

        let v0 = cache.structuralVersion
        _ = cache.currentVisibleRows(snapshot: [a, b], isCollapsed: { _ in false })
        cache.invalidateStructure()
        #expect(cache.structuralVersion == v0 &+ 1)

        // After invalidation, a different snapshot must be honored.
        let c = Block.paragraph(text: AttributedString("c"))
        let (rows, _) = cache.currentVisibleRows(snapshot: [a, b, c], isCollapsed: { _ in false })
        #expect(rows.count == 3)
        #expect(rows.last?.id == c.id)
    }

    @Test func collapsedSubtreeIsHiddenFromVisibleRows() {
        let cache = BlockLayoutCache()
        let child = Block.paragraph(text: AttributedString("child"))
        let toggle = Block.toggle(title: AttributedString("toggle"), children: [child])
        let after = Block.paragraph(text: AttributedString("after"))

        // Toggle closed.
        let (rowsClosed, hiddenClosed) = cache.currentVisibleRows(
            snapshot: [toggle, after],
            isCollapsed: { $0.id == toggle.id }
        )
        #expect(rowsClosed.map(\.id) == [toggle.id, after.id])
        #expect(hiddenClosed.contains(child.id))

        cache.invalidateStructure()

        // Toggle open — child becomes visible.
        let (rowsOpen, hiddenOpen) = cache.currentVisibleRows(
            snapshot: [toggle, after],
            isCollapsed: { _ in false }
        )
        #expect(rowsOpen.map(\.id) == [toggle.id, child.id, after.id])
        #expect(!hiddenOpen.contains(child.id))
    }

    @Test func collapseStateChangeRefreshesVisibleRowsWithoutExplicitInvalidation() {
        let cache = BlockLayoutCache()
        let child = Block.paragraph(text: AttributedString("child"))
        let toggle = Block.toggle(title: AttributedString("toggle"), children: [child])
        let snapshot = [toggle]

        let (rowsClosed, _) = cache.currentVisibleRows(
            snapshot: snapshot,
            isCollapsed: { $0.id == toggle.id }
        )
        #expect(rowsClosed.map(\.id) == [toggle.id])

        let vAfterClosed = cache.structuralVersion
        let (rowsOpen, hiddenOpen) = cache.currentVisibleRows(
            snapshot: snapshot,
            isCollapsed: { _ in false }
        )

        #expect(rowsOpen.map(\.id) == [toggle.id, child.id])
        #expect(!hiddenOpen.contains(child.id))
        #expect(cache.structuralVersion == vAfterClosed &+ 1)
    }

    @Test func snapshotChangeRefreshesVisibleRowsWithoutExplicitInvalidation() {
        let cache = BlockLayoutCache()
        let a = Block.paragraph(text: AttributedString("a"))
        let b = Block.paragraph(text: AttributedString("b"))

        let (rows1, _) = cache.currentVisibleRows(snapshot: [a], isCollapsed: { _ in false })
        #expect(rows1.map(\.id) == [a.id])

        let vAfterFirstSnapshot = cache.structuralVersion
        let (rows2, _) = cache.currentVisibleRows(snapshot: [a, b], isCollapsed: { _ in false })

        #expect(rows2.map(\.id) == [a.id, b.id])
        #expect(cache.structuralVersion == vAfterFirstSnapshot &+ 1)
    }
}
