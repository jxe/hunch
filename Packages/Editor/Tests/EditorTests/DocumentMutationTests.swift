import Testing
import Foundation
@testable import Editor

/// These tests cover the tree-based Document API: find / mutate / removeSubtree
/// / insertSubtrees / replaceSubtree / canIndent / canOutdent / canDrop /
/// indent / outdent / slideSiblings. They don't try to retain the old
/// indent-based assertions — depth is now structural, asserted by inspecting
/// `parent.children` rather than per-block ints.
@MainActor
@Suite("Document mutation helpers")
struct DocumentMutationTests {
    private func makeDoc() -> Document {
        Document(
            url: URL(fileURLWithPath: "/tmp/test.md"),
            title: "Test",
            children: [
                .paragraph(text: AttributedString("first")),
                .bullet(text: AttributedString("a"), children: [
                    .bullet(text: AttributedString("b"))
                ]),
                .heading(level: .h2, text: AttributedString("section"))
            ]
        )
    }

    @Test func findReturnsTopLevelBlock() {
        let doc = makeDoc()
        let id = doc.children[0].id
        #expect(doc.find(id)?.id == id)
    }

    @Test func findReturnsNestedBlock() {
        let doc = makeDoc()
        let nestedID = doc.children[1].children[0].id
        let found = doc.find(nestedID)
        #expect(found?.id == nestedID)
        if case .bullet(let text) = found?.kind {
            #expect(String(text.characters) == "b")
        } else {
            Issue.record("expected bullet")
        }
    }

    @Test func findReturnsNilForMissing() {
        let doc = makeDoc()
        #expect(doc.find(BlockID()) == nil)
    }

    @Test func parentOfNestedBlockReturnsTopLevel() {
        let doc = makeDoc()
        let parent = doc.children[1]
        let nested = parent.children[0]
        #expect(doc.parent(of: nested.id) == parent.id)
    }

    @Test func parentOfTopLevelIsNil() {
        let doc = makeDoc()
        #expect(doc.parent(of: doc.children[0].id) == nil)
    }

    @Test func removeSubtreeYanksNestedBlockOut() {
        let doc = makeDoc()
        let nestedID = doc.children[1].children[0].id
        let removed = doc.removeSubtree(nestedID)
        #expect(removed?.id == nestedID)
        #expect(doc.children[1].children.isEmpty)
        #expect(doc.find(nestedID) == nil)
    }

    @Test func replaceSubtreeSwapsAtTopLevel() {
        let doc = makeDoc()
        let target = doc.children[0].id
        doc.replaceSubtree(target, with: [
            .paragraph(text: AttributedString("head")),
            .paragraph(text: AttributedString("tail"))
        ])
        #expect(doc.children.count == 4)
        if case .paragraph(let t) = doc.children[0].kind {
            #expect(String(t.characters) == "head")
        } else {
            Issue.record("expected paragraph at 0")
        }
    }

    @Test func mutateUpdatesKind() {
        let doc = makeDoc()
        let target = doc.children[0].id
        doc.mutate(target) { block in
            block.kind = .heading(level: .h1, text: AttributedString("Hello"))
        }
        if case .heading(.h1, let text) = doc.children[0].kind {
            #expect(String(text.characters) == "Hello")
        } else {
            Issue.record("expected H1")
        }
    }

    @Test func canIndentReturnsTrueWhenPreviousSiblingExists() {
        let doc = Document(
            url: URL(fileURLWithPath: "/tmp/test.md"),
            title: "Test",
            children: [
                .bullet(text: AttributedString("first")),
                .bullet(text: AttributedString("second"))
            ]
        )
        #expect(doc.canIndent(doc.children[1].id))
    }

    @Test func canIndentRefusesFirstSibling() {
        let doc = makeDoc()
        #expect(!doc.canIndent(doc.children[0].id))
    }

    @Test func indentReparentsToPreviousSibling() {
        let doc = Document(
            url: URL(fileURLWithPath: "/tmp/test.md"),
            title: "Test",
            children: [
                .bullet(text: AttributedString("first")),
                .bullet(text: AttributedString("second"))
            ]
        )
        let secondID = doc.children[1].id
        #expect(doc.indent(secondID))
        #expect(doc.children.count == 1)
        #expect(doc.children[0].children.count == 1)
        #expect(doc.children[0].children[0].id == secondID)
    }

    @Test func outdentMovesNestedToGrandparent() {
        let doc = makeDoc()
        let nestedID = doc.children[1].children[0].id
        #expect(doc.canOutdent(nestedID))
        #expect(doc.outdent(nestedID))
        // After outdent, the nested bullet is the next sibling of its parent.
        #expect(doc.children.count == 4)
        #expect(doc.children[2].id == nestedID)
    }

    @Test func canDropRefusesIntoOwnDescendant() {
        let doc = makeDoc()
        let parent = doc.children[1]
        let nestedID = parent.children[0].id
        // Trying to drop the parent INTO its own child is a cycle.
        let target = DropPath(parent: nestedID, position: 0)
        #expect(!doc.canDrop(ids: [parent.id], to: target))
    }

    @Test func canDropRefusesHeadingIntoSameLevelHeadingChildren() {
        let doc = Document(
            url: URL(fileURLWithPath: "/tmp/test.md"),
            title: "Test",
            children: [
                .heading(level: .h2, text: AttributedString("Outer"))
            ]
        )
        let outerID = doc.children[0].id
        // An H2 cannot be a child of another H2 — the markdown round-trip
        // would just close the outer H2's body.
        let h2Drop = Block.heading(level: .h2, text: AttributedString("Inner"))
        doc.children[0].children.append(h2Drop)
        #expect(!doc.canDrop(ids: [h2Drop.id], to: DropPath(parent: outerID, position: 0)))
    }

    @Test func moveSubtreesShiftsTopLevel() {
        let doc = Document(
            url: URL(fileURLWithPath: "/tmp/test.md"),
            title: "Test",
            children: [
                .paragraph(text: AttributedString("a")),
                .paragraph(text: AttributedString("b")),
                .paragraph(text: AttributedString("c"))
            ]
        )
        let cID = doc.children[2].id
        #expect(doc.moveSubtrees([cID], to: DropPath(parent: nil, position: 0)))
        #expect(doc.children.count == 3)
        #expect(doc.children[0].id == cID)
    }

    @Test func slideSiblingsRefusesAcrossParents() {
        let doc = makeDoc()
        let topID = doc.children[0].id
        let nestedID = doc.children[1].children[0].id
        // Two ids under different parents — the new policy refuses to slide.
        #expect(!doc.slideSiblings([topID, nestedID], by: -1))
    }

    @Test func snapshotIsShallowArrayCopy() {
        let doc = makeDoc()
        let snapshot = doc.snapshot()
        doc.children[0] = .paragraph(text: AttributedString("changed"))
        // Snapshot reflects pre-mutation state.
        if case .paragraph(let t) = snapshot[0].kind {
            #expect(String(t.characters) == "first")
        } else {
            Issue.record("expected paragraph")
        }
    }

    @Test func withFreshIDsAssignsFreshIDsRecursively() {
        let original = Block.bullet(
            text: AttributedString("parent"),
            children: [
                .bullet(text: AttributedString("child"))
            ]
        )
        let copy = original.withFreshIDs()
        #expect(copy.id != original.id)
        #expect(copy.children[0].id != original.children[0].id)
    }

    @Test func canContainHeadingByLevel() {
        let h1 = Block.heading(level: .h1, text: AttributedString(""))
        let h2 = Block.heading(level: .h2, text: AttributedString(""))
        let h3 = Block.heading(level: .h3, text: AttributedString(""))
        #expect(h1.canContain(h2))
        #expect(h1.canContain(h3))
        #expect(!h2.canContain(h1))
        #expect(!h2.canContain(h2))
    }

    @Test func leafBlocksRefuseChildren() {
        let para = Block.paragraph(text: AttributedString(""))
        let bullet = Block.bullet(text: AttributedString(""))
        #expect(!para.canContain(bullet))
        #expect(!para.isContainer)
        #expect(bullet.isContainer)
    }
}
