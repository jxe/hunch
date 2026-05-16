import Testing
import Foundation
@testable import Hunch
import Editor

@Suite("LostBlockForest")
struct LostBlockForestTests {
    private func attr(_ s: String) -> AttributedString { AttributedString(s) }

    /// Convenience: make a fake `LostBlock`-style record from a Block. The
    /// `parentHash` is supplied so callers can sketch the forest by hand
    /// without rebuilding a `Wire`.
    private func makeRecord(
        _ block: Block,
        parent: Block? = nil,
        source: String = "p.md",
        recordedAt: Date = Date(timeIntervalSince1970: 0)
    ) -> LostBlock {
        LostBlock.adapt(
            hash: block.atomicHash,
            parentHash: parent?.atomicHash,
            markdown: BlockSerializer.serializeAtomic(block),
            source: source,
            recordedAt: recordedAt
        )
    }

    @Test func emptyListYieldsNoRoots() {
        let roots = LostBlockForest.assemble([])
        #expect(roots.isEmpty)
    }

    @Test func flatListWithNilParentsYieldsRootsInOrder() {
        let a = Block.paragraph(text: attr("A"))
        let b = Block.paragraph(text: attr("B"))
        let c = Block.paragraph(text: attr("C"))
        let records = [
            makeRecord(a, recordedAt: Date(timeIntervalSince1970: 1)),
            makeRecord(b, recordedAt: Date(timeIntervalSince1970: 2)),
            makeRecord(c, recordedAt: Date(timeIntervalSince1970: 3)),
        ]
        let roots = LostBlockForest.assemble(records)
        #expect(roots.count == 3)
        #expect(roots.map { $0.lost.hash } == records.map(\.hash))
        #expect(roots.allSatisfy { $0.block.children.isEmpty })
    }

    @Test func parentAndChildBothLostYieldsOneNestedRoot() {
        let parent = Block.heading(level: .h1, text: attr("Parent"))
        let child = Block.paragraph(text: attr("Child"))
        let records = [
            makeRecord(parent, recordedAt: Date(timeIntervalSince1970: 1)),
            makeRecord(child, parent: parent, recordedAt: Date(timeIntervalSince1970: 2)),
        ]
        let roots = LostBlockForest.assemble(records)
        #expect(roots.count == 1)
        let root = try! #require(roots.first)
        #expect(root.lost.hash == parent.atomicHash)
        #expect(root.block.children.count == 1)
        #expect(root.hashes.count == 2)
    }

    @Test func threeLevelChainYieldsTwoDeepNesting() {
        let h1 = Block.heading(level: .h1, text: attr("H1"))
        let h2 = Block.heading(level: .h2, text: attr("H2"))
        let p = Block.paragraph(text: attr("P"))
        let records = [
            makeRecord(h1, recordedAt: Date(timeIntervalSince1970: 1)),
            makeRecord(h2, parent: h1, recordedAt: Date(timeIntervalSince1970: 2)),
            makeRecord(p, parent: h2, recordedAt: Date(timeIntervalSince1970: 3)),
        ]
        let roots = LostBlockForest.assemble(records)
        #expect(roots.count == 1)
        let root = try! #require(roots.first)
        #expect(root.block.children.count == 1)
        #expect(root.block.children.first?.children.count == 1)
        #expect(root.hashes.count == 3)
    }

    @Test func childWithParentOutsideLostSetIsItsOwnRoot() {
        // Parent isn't in the records — it's live in the doc somewhere.
        let livingParent = Block.heading(level: .h1, text: attr("Live"))
        let orphan = Block.paragraph(text: attr("Orphan"))
        let records = [
            makeRecord(orphan, parent: livingParent),
        ]
        let roots = LostBlockForest.assemble(records)
        #expect(roots.count == 1)
        let root = try! #require(roots.first)
        #expect(root.lost.hash == orphan.atomicHash)
        // Its `parentHash` is preserved on the root so the caller can resolve
        // to the live ancestor.
        #expect(root.lost.parentHash == livingParent.atomicHash)
    }

    @Test func cycleDoesNotInfiniteRecurse() {
        let a = Block.paragraph(text: attr("A"))
        let b = Block.paragraph(text: attr("B"))
        // Hand-craft a cycle: a.parent=b and b.parent=a (impossible in
        // practice but corrupt logs are a possibility).
        let records = [
            LostBlock.adapt(
                hash: a.atomicHash,
                parentHash: b.atomicHash,
                markdown: BlockSerializer.serializeAtomic(a),
                source: "p.md",
                recordedAt: Date(timeIntervalSince1970: 1)
            ),
            LostBlock.adapt(
                hash: b.atomicHash,
                parentHash: a.atomicHash,
                markdown: BlockSerializer.serializeAtomic(b),
                source: "p.md",
                recordedAt: Date(timeIntervalSince1970: 2)
            ),
        ]
        let roots = LostBlockForest.assemble(records)
        // Both blocks claim the other as parent → neither is a root because
        // both parents are present in the set. The assemble function should
        // either short-circuit on visited or produce zero roots gracefully,
        // never spin forever.
        #expect(roots.isEmpty || roots.count <= 2)
    }

    @Test func siblingsSortByRecordedAt() {
        let parent = Block.heading(level: .h1, text: attr("Parent"))
        let early = Block.paragraph(text: attr("early"))
        let late = Block.paragraph(text: attr("late"))
        let records = [
            makeRecord(parent, recordedAt: Date(timeIntervalSince1970: 1)),
            makeRecord(late, parent: parent, recordedAt: Date(timeIntervalSince1970: 3)),
            makeRecord(early, parent: parent, recordedAt: Date(timeIntervalSince1970: 2)),
        ]
        let roots = LostBlockForest.assemble(records)
        let root = try! #require(roots.first)
        // Children sorted by recordedAt ascending.
        let childTexts: [String] = root.block.children.compactMap { child in
            if case .paragraph(let t) = child.kind { return String(t.characters) }
            return nil
        }
        #expect(childTexts == ["early", "late"])
    }

    @Test func unparseableEntryIsSkipped() {
        let a = Block.paragraph(text: attr("A"))
        // An entry with markdown that BlockParser can't make sense of.
        // Empty string parses to empty block list → first is nil.
        let bad = LostBlock.adapt(
            hash: "broken",
            parentHash: nil,
            markdown: "",
            source: "p.md",
            recordedAt: Date(timeIntervalSince1970: 5)
        )
        let records = [
            bad,
            makeRecord(a, recordedAt: Date(timeIntervalSince1970: 1)),
        ]
        let roots = LostBlockForest.assemble(records)
        #expect(roots.count == 1)
        #expect(roots.first?.lost.hash == a.atomicHash)
    }

    @Test func rootedAtReturnsJustThatSubtree() {
        let h1 = Block.heading(level: .h1, text: attr("H1"))
        let h2 = Block.heading(level: .h2, text: attr("H2"))
        let p = Block.paragraph(text: attr("P"))
        let unrelated = Block.paragraph(text: attr("Sibling"))
        let records = [
            makeRecord(h1, recordedAt: Date(timeIntervalSince1970: 1)),
            makeRecord(h2, parent: h1, recordedAt: Date(timeIntervalSince1970: 2)),
            makeRecord(p, parent: h2, recordedAt: Date(timeIntervalSince1970: 3)),
            makeRecord(unrelated, recordedAt: Date(timeIntervalSince1970: 4)),
        ]
        let root = try! #require(LostBlockForest.assemble(records, rootedAt: h1.atomicHash))
        #expect(root.hashes.count == 3)
        #expect(!root.hashes.contains(unrelated.atomicHash))
    }

    @Test func rootedAtUnknownHashReturnsNil() {
        let a = Block.paragraph(text: attr("A"))
        let root = LostBlockForest.assemble([makeRecord(a)], rootedAt: "nonexistent")
        #expect(root == nil)
    }
}
