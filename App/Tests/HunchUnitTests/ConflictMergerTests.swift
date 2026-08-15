import Testing
import Foundation
@testable import Hunch
import Quagmire

@Suite("ConflictMerger") @MainActor
struct ConflictMergerTests {
    private func hash(_ block: Block) -> String { block.atomicHash }

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

    /// Build an `IntentState` directly from raw fields. `tombstones` marks
    /// hashes as latest-record-is-purge; `parents` maps hash → recorded
    /// parent hash via a synthetic `latestAdd`. The engine's `parent(of:)`
    /// climbs both `.alive` and `.tombstoned` records' latestAdd parent, so
    /// a tombstoned hash with a parent in this map still climbs correctly.
    private func intent(
        tombstones: [String] = [],
        parents: [String: String] = [:]
    ) -> IntentState {
        let now = Date()
        var byHash: [String: IntentState.Status] = [:]
        for (child, parent) in parents {
            byHash[child] = .alive(latestAdd: .init(
                parent: parent, markdown: "", recordedAt: now
            ))
        }
        for h in tombstones {
            let latestAdd: IntentState.AddSnapshot? = parents[h].map {
                .init(parent: $0, markdown: "", recordedAt: now)
            }
            byHash[h] = .tombstoned(
                latestAdd: latestAdd,
                latestPurge: .init(purgedAt: now, counter: nil, deviceID: nil)
            )
        }
        return IntentState(byHash: byHash)
    }

    @Test func disjointBlocksGetSpliced() {
        let a: Block = .paragraph(text: AttributedString("A"))
        let b: Block = .paragraph(text: AttributedString("B"))
        let c: Block = .paragraph(text: AttributedString("C"))
        let d: Block = .paragraph(text: AttributedString("D"))
        let e: Block = .paragraph(text: AttributedString("E"))

        let result = PatchEngine.mergeConflict(
            survivor: [a, b, c],
            alternates: [[a, b, c, d, e]],
            intent: intent()
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

        let result = PatchEngine.mergeConflict(
            survivor: [a],
            alternates: [[a, dismissed, kept]],
            intent: intent(tombstones: [hash(dismissed)])
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

        // Survivor has only aliveAncestor; alternate has leaf with missingMid
        // as its direct parent. Intent says missingMid is tombstoned but its
        // recorded parent is aliveAncestor — so leaf climbs through and
        // lands under aliveAncestor.
        let alternate: Block = .heading(
            level: .h2,
            text: AttributedString("Mid"),
            children: [leaf]
        )

        let result = PatchEngine.mergeConflict(
            survivor: [aliveAncestor],
            alternates: [[alternate]],
            intent: intent(
                tombstones: [hash(missingMid)],
                parents: [hash(missingMid): hash(aliveAncestor)]
            )
        )

        #expect(Set(result.salvagedHashes) == [hash(leaf)])
        var leafParent: BlockID?
        let doc = Document(id: DocumentID("conflict-merge"), children: result.merged)
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

        let result = PatchEngine.mergeConflict(
            survivor: [a],
            alternates: [[a, fromMac], [a, fromIPad]],
            intent: intent()
        )

        #expect(Set(result.salvagedHashes) == [hash(fromMac), hash(fromIPad)])
        let mergedHashes = hashes(result.merged)
        #expect(mergedHashes.contains(hash(fromMac)))
        #expect(mergedHashes.contains(hash(fromIPad)))
    }

    @Test func identicalSurvivorAndAlternateSalvagesNothing() {
        let a: Block = .paragraph(text: AttributedString("A"))
        let b: Block = .paragraph(text: AttributedString("B"))

        let result = PatchEngine.mergeConflict(
            survivor: [a, b],
            alternates: [[a, b]],
            intent: intent()
        )

        #expect(result.salvagedHashes.isEmpty)
    }

    @Test func childUnderLiveParentInAlternate() {
        // Survivor has heading H with no children. Alternate has H with
        // child X. X should land under H in the merged tree, not at top.
        let h: Block = .heading(level: .h1, text: AttributedString("H"))
        let x: Block = .paragraph(text: AttributedString("X"))
        let hWithX: Block = .heading(level: .h1, text: AttributedString("H"), children: [x])

        let result = PatchEngine.mergeConflict(
            survivor: [h],
            alternates: [[hWithX]],
            intent: intent()
        )

        #expect(Set(result.salvagedHashes) == [hash(x)])
        let doc = Document(id: DocumentID("conflict-merge"), children: result.merged)
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

        let result = PatchEngine.mergeConflict(
            survivor: [a],
            alternates: [[a, newTop]],
            intent: intent()
        )

        var newTopParent: BlockID?
        let doc = Document(id: DocumentID("conflict-merge"), children: result.merged)
        doc.walk { block, _, parent in
            if hash(block) == hash(newTop) { newTopParent = parent }
        }
        #expect(newTopParent == nil)
    }
}
