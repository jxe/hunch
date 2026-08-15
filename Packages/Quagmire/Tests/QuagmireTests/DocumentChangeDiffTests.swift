import Foundation
import Testing
@testable import Quagmire

@MainActor
@Suite("Document semantic change diff")
struct DocumentChangeDiffTests {
    private func block(_ text: String) -> Block {
        .paragraph(text: AttributedString(text))
    }

    @Test func emitsInsertForFreshBlock() {
        let fresh = block("new")
        #expect(DocumentChangeDiff.derive(pre: [], post: [fresh]) == [
            .inserted(block: fresh, parent: nil)
        ])
    }

    @Test func emitsRemoveForVanishedBlock() {
        let gone = block("gone")
        #expect(DocumentChangeDiff.derive(pre: [gone], post: []) == [
            .removed(block: gone)
        ])
    }

    @Test func emitsOldAndNewSnapshotsForContentChange() {
        let id = BlockID()
        let before = Block(id: id, kind: .paragraph(text: AttributedString("Title")))
        let after = Block(id: id, kind: .heading(level: .h1, text: AttributedString("Title")))
        #expect(DocumentChangeDiff.derive(pre: [before], post: [after]) == [
            .removed(block: before),
            .inserted(block: after, parent: nil)
        ])
    }

    @Test func refreshesChildPlacementWhenSameParentContentChanges() {
        let parentID = BlockID()
        let child = block("body")
        let before = Block(
            id: parentID,
            kind: .heading(level: .h3, text: AttributedString("Section")),
            children: [child]
        )
        let after = Block(
            id: parentID,
            kind: .heading(level: .h2, text: AttributedString("Section")),
            children: [child]
        )

        let changes = DocumentChangeDiff.derive(pre: [before], post: [after])
        #expect(changes.contains(.placementUpdated(
            block: child,
            previousParent: before,
            parent: after
        )))
    }

    @Test func reorderAndOutdentAreSemanticNoOps() {
        let a = block("a")
        let b = block("b")
        #expect(DocumentChangeDiff.derive(pre: [a, b], post: [b, a]).isEmpty)

        let leaf = block("leaf")
        let parent = Block.toggle(title: AttributedString("Parent"), children: [leaf])
        let outdented = Block(id: parent.id, kind: parent.kind, children: [])
        #expect(DocumentChangeDiff.derive(pre: [parent], post: [outdented, leaf]).isEmpty)
    }

    @Test func removedSubtreeReportsEverySnapshot() {
        let first = block("first")
        let second = block("second")
        let parent = Block.toggle(title: AttributedString("Parent"), children: [first, second])
        let removed = DocumentChangeDiff.derive(pre: [parent], post: []).compactMap { change -> Block? in
            if case .removed(let block) = change { return block }
            return nil
        }
        #expect(Set(removed.map(\.id)) == Set([parent.id, first.id, second.id]))
    }

    @Test func newSubtreeInsertsParentsBeforeChildren() {
        let leaf = block("leaf")
        let parent = Block.toggle(title: AttributedString("Outer"), children: [leaf])
        #expect(DocumentChangeDiff.derive(pre: [], post: [parent]) == [
            .inserted(block: parent, parent: nil),
            .inserted(block: leaf, parent: parent)
        ])
    }
}
