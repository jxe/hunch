import Testing
import Foundation
@testable import Editor

/// Verifies the patch-theoretic property that `EditorView.mutate` relies on:
/// the purge set fired to the host is exactly the set of *atomic hashes of
/// blocks whose id existed before the mutation and is gone after*. Text edits
/// (same id, different hash) do not produce purges; structural removes do.
@MainActor
@Suite("EditorView.mutate purge diff")
struct EditorViewPurgeDiffTests {

    private func block(_ text: String) -> Block {
        .paragraph(text: AttributedString(text))
    }

    @Test func textEditOnSameIdProducesNoPurge() {
        let id = BlockID()
        let pre: [Block] = [
            Block(id: id, kind: .paragraph(text: AttributedString("Hello")))
        ]
        let preByID = BlockTreeDiff.idToAtomicHash(pre)
        let post: [Block] = [
            Block(id: id, kind: .paragraph(text: AttributedString("Hello world")))
        ]
        let removed = BlockTreeDiff.removedHashes(preByID: preByID, post: post)
        #expect(removed.isEmpty,
                "same id, different content — typing is not a deletion")
    }

    @Test func structuralRemoveFiresPurgeForRemovedId() {
        let keep = block("keep")
        let drop = block("drop")
        let preByID = BlockTreeDiff.idToAtomicHash([keep, drop])
        let dropHash = drop.atomicHash
        let removed = BlockTreeDiff.removedHashes(preByID: preByID, post: [keep])
        #expect(removed == [dropHash])
    }

    @Test func cascadingChildDeletionFiresPurgesForEveryDescendantId() {
        let leaf1 = block("leaf-1")
        let leaf2 = block("leaf-2")
        let parent = Block.toggle(title: AttributedString("Parent"), children: [leaf1, leaf2])
        let preByID = BlockTreeDiff.idToAtomicHash([parent])
        let removed = Set(BlockTreeDiff.removedHashes(preByID: preByID, post: []))
        #expect(removed == Set([
            parent.atomicHash,
            leaf1.atomicHash,
            leaf2.atomicHash
        ]), "removing a subtree purges every descendant hash")
    }

    @Test func replacingBlockFiresPurgeForOldId() {
        // Replace block B with a fresh block C (different id) — the pattern
        // a Turn-Into mutation produces. The old id disappears, the new id
        // is added — fire a purge for the old hash; the new hash will be
        // captured by the recovery log on the next save.
        let oldBlock = block("before")
        let newBlock = block("after")
        let preByID = BlockTreeDiff.idToAtomicHash([oldBlock])
        let removed = BlockTreeDiff.removedHashes(preByID: preByID, post: [newBlock])
        #expect(removed == [oldBlock.atomicHash])
    }

    @Test func reorderingProducesNoPurges() {
        // Moving blocks around (same ids, different order) is not a delete.
        let a = block("a")
        let b = block("b")
        let preByID = BlockTreeDiff.idToAtomicHash([a, b])
        let removed = BlockTreeDiff.removedHashes(preByID: preByID, post: [b, a])
        #expect(removed.isEmpty)
    }

    @Test func liftingChildToSiblingProducesNoPurges() {
        // Outdent / un-nest is an id-preserving move. No purge.
        let leaf = block("leaf")
        let parent = Block.toggle(title: AttributedString("Parent"), children: [leaf])
        let preByID = BlockTreeDiff.idToAtomicHash([parent])
        let removed = BlockTreeDiff.removedHashes(
            preByID: preByID,
            post: [
                Block(id: parent.id, kind: parent.kind, children: []),
                leaf
            ]
        )
        #expect(removed.isEmpty)
    }
}
