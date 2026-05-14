import Testing
import Foundation
@testable import Hunch
import Editor

@Suite("ConflictMerger") @MainActor
struct ConflictMergerTests {
    private func hash(_ block: Block) -> String {
        BlockFingerprint.atomicHash(block)
    }

    private func hashes(_ blocks: [Block]) -> Set<String> {
        var out: Set<String> = []
        func walk(_ blocks: [Block]) {
            for b in blocks {
                out.insert(hash(b))
                walk(b.children)
            }
        }
        walk(blocks)
        return out
    }

    @Test func disjointBlocksGetSpliced() {
        let a: Block = .paragraph(text: AttributedString("A"))
        let b: Block = .paragraph(text: AttributedString("B"))
        let c: Block = .paragraph(text: AttributedString("C"))
        let d: Block = .paragraph(text: AttributedString("D"))
        let e: Block = .paragraph(text: AttributedString("E"))

        let survivor: [Block] = [a, b, c]
        let alternate: [Block] = [a, b, c, d, e]

        let result = ConflictMerger.merge(
            survivor: survivor,
            alternates: [alternate],
            tombstones: [],
            parentHashLookup: { _ in nil }
        )

        let mergedHashes = hashes(result.merged)
        #expect(mergedHashes.contains(hash(a)))
        #expect(mergedHashes.contains(hash(b)))
        #expect(mergedHashes.contains(hash(c)))
        #expect(mergedHashes.contains(hash(d)))
        #expect(mergedHashes.contains(hash(e)))
        #expect(Set(result.salvagedHashes) == [hash(d), hash(e)])
    }

    @Test func tombstonedBlockIsSkipped() {
        let a: Block = .paragraph(text: AttributedString("A"))
        let dismissed: Block = .paragraph(text: AttributedString("Dismissed"))
        let kept: Block = .paragraph(text: AttributedString("Kept"))

        let result = ConflictMerger.merge(
            survivor: [a],
            alternates: [[a, dismissed, kept]],
            tombstones: [hash(dismissed)],
            parentHashLookup: { _ in nil }
        )

        let mergedHashes = hashes(result.merged)
        #expect(mergedHashes.contains(hash(a)))
        #expect(!mergedHashes.contains(hash(dismissed)))
        #expect(mergedHashes.contains(hash(kept)))
        #expect(Set(result.salvagedHashes) == [hash(kept)])
    }

    @Test func climbsParentChainViaLogWhenAncestorMissing() {
        let aliveAncestor: Block = .heading(level: .h1, text: AttributedString("Live"))
        let missingMid: Block = .heading(level: .h2, text: AttributedString("Mid"))
        let leaf: Block = .paragraph(text: AttributedString("Leaf"))

        // Survivor has only aliveAncestor; alternate has leaf with missingMid as
        // its direct parent. The log says missingMid's parent is aliveAncestor —
        // so leaf should land under aliveAncestor.
        let alternate: Block = .heading(
            level: .h2,
            text: AttributedString("Mid"),
            children: [leaf]
        )

        let result = ConflictMerger.merge(
            survivor: [aliveAncestor],
            alternates: [[alternate]],
            tombstones: [hash(missingMid)],
            parentHashLookup: { h in
                if h == hash(missingMid) { return hash(aliveAncestor) }
                return nil
            }
        )

        // Both missingMid (tombstoned, skipped) and leaf are accounted for.
        #expect(Set(result.salvagedHashes) == [hash(leaf)])
        // Find leaf in merged tree and check its parent is aliveAncestor.
        var leafParent: BlockID?
        let doc = Document(url: URL(fileURLWithPath: "/x"), title: "", children: result.merged)
        doc.walk { block, _, parent in
            if hash(block) == hash(leaf) { leafParent = parent }
        }
        #expect(leafParent != nil)
        if let parentID = leafParent, let parent = doc.find(parentID) {
            #expect(hash(parent) == hash(aliveAncestor))
        }
    }

    @Test func threeWayMergeUnionsAlternates() {
        let a: Block = .paragraph(text: AttributedString("A"))
        let fromMac: Block = .paragraph(text: AttributedString("Mac"))
        let fromIPad: Block = .paragraph(text: AttributedString("iPad"))

        let result = ConflictMerger.merge(
            survivor: [a],
            alternates: [[a, fromMac], [a, fromIPad]],
            tombstones: [],
            parentHashLookup: { _ in nil }
        )

        #expect(Set(result.salvagedHashes) == [hash(fromMac), hash(fromIPad)])
        let mergedHashes = hashes(result.merged)
        #expect(mergedHashes.contains(hash(fromMac)))
        #expect(mergedHashes.contains(hash(fromIPad)))
    }

    @Test func identicalSurvivorAndAlternateSalvagesNothing() {
        let a: Block = .paragraph(text: AttributedString("A"))
        let b: Block = .paragraph(text: AttributedString("B"))

        let result = ConflictMerger.merge(
            survivor: [a, b],
            alternates: [[a, b]],
            tombstones: [],
            parentHashLookup: { _ in nil }
        )

        #expect(result.salvagedHashes.isEmpty)
    }

    @Test func childUnderLiveParentInAlternate() {
        // Survivor has heading H with no children. Alternate has H with child X.
        // X should land under H in the merged tree, not at the top level.
        let h: Block = .heading(level: .h1, text: AttributedString("H"))
        let x: Block = .paragraph(text: AttributedString("X"))
        let hWithX: Block = .heading(level: .h1, text: AttributedString("H"), children: [x])

        let result = ConflictMerger.merge(
            survivor: [h],
            alternates: [[hWithX]],
            tombstones: [],
            parentHashLookup: { _ in nil }
        )

        #expect(Set(result.salvagedHashes) == [hash(x)])
        let doc = Document(url: URL(fileURLWithPath: "/x"), title: "", children: result.merged)
        var xParentHash: String?
        doc.walk { block, _, parent in
            guard hash(block) == hash(x), let parentID = parent else { return }
            if let parent = doc.find(parentID) { xParentHash = hash(parent) }
        }
        #expect(xParentHash == hash(h))
    }

    @Test func newTopLevelBlockGoesToTopLevel() {
        let a: Block = .paragraph(text: AttributedString("A"))
        let newTop: Block = .paragraph(text: AttributedString("NewTop"))

        let result = ConflictMerger.merge(
            survivor: [a],
            alternates: [[a, newTop]],
            tombstones: [],
            parentHashLookup: { _ in nil }
        )

        var newTopParent: BlockID?
        let doc = Document(url: URL(fileURLWithPath: "/x"), title: "", children: result.merged)
        doc.walk { block, _, parent in
            if hash(block) == hash(newTop) { newTopParent = parent }
        }
        #expect(newTopParent == nil, "new top-level block should have nil parent")
    }
}
