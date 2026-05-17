import Testing
import Foundation
@testable import Editor

/// Verifies the patch-theoretic properties that `EditorView.mutate` relies
/// on: the op stream handed to the host (`EditorOp.insert` / `.remove`) is
/// the canonical pre→post diff. Text edits inside a single block (typing)
/// never reach `mutate`, so they're not tested here — the file covers the
/// structural-mutation path only.
@MainActor
@Suite("EditorView.mutate purge diff")
struct EditorViewPurgeDiffTests {

    private func block(_ text: String) -> Block {
        .paragraph(text: AttributedString(text))
    }

    /// Convenience: extract just the hashes of remove ops from a diff.
    private func removes(_ ops: [EditorOp]) -> Set<String> {
        var out: Set<String> = []
        for op in ops {
            if case .remove(let h) = op { out.insert(h) }
        }
        return out
    }

    /// Convenience: count insert ops in a diff.
    private func insertCount(_ ops: [EditorOp]) -> Int {
        ops.reduce(0) { acc, op in
            if case .insert = op { return acc + 1 }
            return acc
        }
    }

    // MARK: - BlockTreeDiff.derive (insert+remove ops)

    @Test func deriveEmitsInsertForFreshlyCreatedBlock() {
        let pre: [Block] = []
        let fresh = block("new one")
        let ops = BlockTreeDiff.derive(pre: pre, post: [fresh])
        #expect(ops == [
            .insert(hash: fresh.atomicHash, parent: nil, block: fresh)
        ])
    }

    @Test func deriveEmitsRemoveForVanishedBlock() {
        let gone = block("gone")
        let ops = BlockTreeDiff.derive(pre: [gone], post: [])
        #expect(ops == [.remove(hash: gone.atomicHash)])
    }

    @Test func deriveEmitsInsertWhenSameIdGetsDifferentHash() {
        // Structural-edit case: autotransform turns paragraph into heading;
        // id stays, hash changes. Derive sees this as one insert (the new
        // hash) — no remove (id is still present), and no need to tombstone
        // the old hash (it remains alive in the journal as a recoverable
        // prior version).
        let id = BlockID()
        let before = Block(id: id, kind: .paragraph(text: AttributedString("Title")))
        let after = Block(id: id, kind: .heading(level: .h1, text: AttributedString("Title")))
        let ops = BlockTreeDiff.derive(pre: [before], post: [after])
        #expect(ops == [
            .insert(hash: after.atomicHash, parent: nil, block: after)
        ])
    }

    @Test func deriveSkipsUnchangedIdHashPairs() {
        // Move or reorder: same id, same hash, different position. No ops.
        let a = block("a")
        let b = block("b")
        let ops = BlockTreeDiff.derive(pre: [a, b], post: [b, a])
        #expect(ops.isEmpty)
    }

    @Test func deriveEmitsRemovesBeforeInserts() {
        // Ordering invariant: log batch reads as "tombstone the gone, then
        // announce the new." Makes per-batch monotonic counters meaningful
        // when tail-reading the log.
        let gone = block("gone")
        let arriving = block("arriving")
        let ops = BlockTreeDiff.derive(pre: [gone], post: [arriving])
        #expect(ops.count == 2)
        if case .remove = ops[0] {} else { Issue.record("expected remove first, got \(ops[0])") }
        if case .insert = ops[1] {} else { Issue.record("expected insert second, got \(ops[1])") }
    }

    @Test func deriveEmitsRemovesForEntireRemovedSubtree() {
        // Removing a parent removes every descendant too — derive walks
        // pre into preByID, which captures all ids in the tree.
        let leaf1 = block("leaf-1")
        let leaf2 = block("leaf-2")
        let parent = Block.toggle(title: AttributedString("Parent"), children: [leaf1, leaf2])
        let ops = BlockTreeDiff.derive(pre: [parent], post: [])
        #expect(removes(ops) == Set([
            parent.atomicHash,
            leaf1.atomicHash,
            leaf2.atomicHash
        ]), "subtree removal purges every descendant hash")
        #expect(insertCount(ops) == 0)
    }

    @Test func deriveSkipsIdPreservingOutdent() {
        // Outdent / un-nest: a child gets lifted out from under its parent.
        // The child's id+hash are unchanged; the parent's atomic hash is
        // derived from kind alone (children don't contribute to a toggle's
        // hash), so it's also unchanged. No ops at all.
        let leaf = block("leaf")
        let parent = Block.toggle(title: AttributedString("Parent"), children: [leaf])
        let ops = BlockTreeDiff.derive(
            pre: [parent],
            post: [
                Block(id: parent.id, kind: parent.kind, children: []),
                leaf
            ]
        )
        #expect(ops.isEmpty, "id-preserving outdent is a move, not a log event")
    }

    @Test func deriveWalksChildrenPreorderAndCarriesParentHash() {
        // Parent and its descendants in one mutation: parent insert
        // precedes children's; children's `parent` field carries the new
        // parent's hash. Replays cleanly even if records arrive in batch
        // order on another device.
        let leaf = block("leaf")
        let parent = Block.toggle(title: AttributedString("Outer"), children: [leaf])
        let ops = BlockTreeDiff.derive(pre: [], post: [parent])
        let inserts = ops.compactMap { op -> (String, String?)? in
            if case .insert(let h, let p, _) = op { return (h, p) }
            return nil
        }
        #expect(inserts.count == 2)
        #expect(inserts[0].0 == parent.atomicHash, "parent comes first")
        #expect(inserts[0].1 == nil, "parent top-level")
        #expect(inserts[1].0 == leaf.atomicHash, "leaf second")
        #expect(inserts[1].1 == parent.atomicHash, "leaf references parent's hash")
    }
}
