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

    @Test func pathToTopLevelIsSingleIndex() {
        let doc = makeDoc()
        let id = doc.children[2].id
        #expect(doc.path(to: id) == IndexPath(indexes: [2]))
    }

    @Test func pathToNestedIsTwoIndices() {
        let doc = makeDoc()
        let nestedID = doc.children[1].children[0].id
        #expect(doc.path(to: nestedID) == IndexPath(indexes: [1, 0]))
    }

    @Test func pathToMissingIsNil() {
        let doc = makeDoc()
        #expect(doc.path(to: BlockID()) == nil)
    }

    @Test func documentOrderIsPreorder() {
        let doc = makeDoc()
        // Tree: [paragraph(0), bullet a(1) [bullet b(2)], heading(3)]
        #expect(doc.documentOrder(of: doc.children[0].id) == 0)
        #expect(doc.documentOrder(of: doc.children[1].id) == 1)
        #expect(doc.documentOrder(of: doc.children[1].children[0].id) == 2)
        #expect(doc.documentOrder(of: doc.children[2].id) == 3)
    }

    @Test func preorderPredecessorOfFirstIsNil() {
        let doc = makeDoc()
        #expect(doc.preorderPredecessor(of: doc.children[0].id) == nil)
    }

    @Test func preorderPredecessorCrossesIntoSubtree() {
        let doc = makeDoc()
        // The heading at index 2 follows bullet "b" (last descendant of bullet "a").
        let bulletB = doc.children[1].children[0].id
        #expect(doc.preorderPredecessor(of: doc.children[2].id) == bulletB)
    }

    @Test func subtreeIDsIncludesSelfAndDescendants() {
        let doc = makeDoc()
        let bulletA = doc.children[1]
        let ids = doc.subtreeIDs(of: bulletA.id)
        #expect(ids == Set([bulletA.id, bulletA.children[0].id]))
    }

    @Test func subtreeIDsOfMissingIsEmpty() {
        let doc = makeDoc()
        #expect(doc.subtreeIDs(of: BlockID()).isEmpty)
    }

    @Test func walkVisitsEveryBlockInPreorder() {
        let doc = makeDoc()
        var visited: [BlockID] = []
        doc.walk { block, _, _ in visited.append(block.id) }
        #expect(visited == [
            doc.children[0].id,
            doc.children[1].id,
            doc.children[1].children[0].id,
            doc.children[2].id
        ])
    }

    @Test func removeSubtreeYanksNestedBlockOut() {
        let doc = makeDoc()
        let nestedID = doc.children[1].children[0].id
        let removed = doc.removeSubtree(nestedID)
        #expect(removed?.id == nestedID)
        #expect(doc.children[1].children.isEmpty)
        #expect(doc.find(nestedID) == nil)
    }

    @Test func removeBlockLiftingChildrenPromotesChildrenToSiblings() {
        let bodyA = Block.paragraph(text: AttributedString("a"))
        let bodyB = Block.paragraph(text: AttributedString("b"))
        let heading = Block.heading(level: .h1, text: AttributedString("H"), children: [bodyA, bodyB])
        let trailing = Block.paragraph(text: AttributedString("after"))
        let doc = Document(
            url: URL(fileURLWithPath: "/tmp/test.md"),
            children: [heading, trailing]
        )

        let husk = doc.removeBlockLiftingChildren(heading.id)

        #expect(husk?.id == heading.id)
        #expect(husk?.children.isEmpty == true)
        #expect(doc.children.map(\.id) == [bodyA.id, bodyB.id, trailing.id])
        #expect(doc.find(heading.id) == nil)
    }

    @Test func removeBlockLiftingChildrenWorksOnNestedBlock() {
        let leaf = Block.paragraph(text: AttributedString("leaf"))
        let inner = Block.heading(level: .h2, text: AttributedString("inner"), children: [leaf])
        let outer = Block.toggle(title: AttributedString("outer"), children: [inner])
        let doc = Document(
            url: URL(fileURLWithPath: "/tmp/test.md"),
            children: [outer]
        )

        _ = doc.removeBlockLiftingChildren(inner.id)

        #expect(doc.children[0].children.map(\.id) == [leaf.id])
    }

    @Test func removeBlockLiftingChildrenReturnsNilForMissing() {
        let doc = makeDoc()
        #expect(doc.removeBlockLiftingChildren(BlockID()) == nil)
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

    @Test func slideSiblingsDownAtEndExitsParentBeforeNextStructuralContainer() {
        // [bullet A {x, y}, bullet B {z}]
        // Slide-down y from end of A exits A and lands before B. Option-arrow
        // movement must not implicitly indent into structural containers.
        let doc = Document(
            url: URL(fileURLWithPath: "/tmp/test.md"),
            children: [
                .bullet(text: AttributedString("A"), children: [
                    .bullet(text: AttributedString("x")),
                    .bullet(text: AttributedString("y"))
                ]),
                .bullet(text: AttributedString("B"), children: [
                    .bullet(text: AttributedString("z"))
                ])
            ]
        )
        let yID = doc.children[0].children[1].id
        #expect(doc.slideSiblings([yID], by: 1))
        #expect(doc.children[0].children.count == 1)
        #expect(doc.children.map(\.id) == [doc.children[0].id, yID, doc.children[2].id])
        #expect(doc.children[2].children.count == 1)
    }

    @Test func slideSiblingsUpAtTopExitsParentAfterPreviousStructuralContainer() {
        // [bullet A {x}, bullet B {y, z}]
        // Slide-up y from top of B exits B and lands after A. Option-arrow
        // movement must not implicitly indent into structural containers.
        let doc = Document(
            url: URL(fileURLWithPath: "/tmp/test.md"),
            children: [
                .bullet(text: AttributedString("A"), children: [
                    .bullet(text: AttributedString("x"))
                ]),
                .bullet(text: AttributedString("B"), children: [
                    .bullet(text: AttributedString("y")),
                    .bullet(text: AttributedString("z"))
                ])
            ]
        )
        let yID = doc.children[1].children[0].id
        #expect(doc.slideSiblings([yID], by: -1))
        #expect(doc.children.map(\.id) == [doc.children[0].id, yID, doc.children[2].id])
        #expect(doc.children[0].children.count == 1)
        #expect(doc.children[2].children.count == 1)
    }

    @Test func slideSiblingsDownBeforeHeadingMovesToHeadingStart() {
        // [bullet x, heading Out {a, b}]
        // Slide-down x should land at the beginning of the heading body, not
        // after the heading where heading-containment would append it.
        let doc = Document(
            url: URL(fileURLWithPath: "/tmp/test.md"),
            children: [
                .bullet(text: AttributedString("x")),
                .heading(level: .h1, text: AttributedString("Out"), children: [
                    .bullet(text: AttributedString("a")),
                    .bullet(text: AttributedString("b"))
                ])
            ]
        )
        let xID = doc.children[0].id
        let aID = doc.children[1].children[0].id
        let bID = doc.children[1].children[1].id
        #expect(doc.slideSiblings([xID], by: 1))
        #expect(doc.children.count == 1)
        #expect(doc.children[0].children.map(\.id) == [xID, aID, bID])
    }

    @Test func slideSiblingsDownBeforeToggleSkipsToggleSubtree() {
        // [bullet x, toggle Out {a, b}]
        // Slide-down x skips the whole toggle subtree instead of indenting into
        // it. Toggles require explicit Tab/drop-on-toggle to receive children.
        let doc = Document(
            url: URL(fileURLWithPath: "/tmp/test.md"),
            children: [
                .bullet(text: AttributedString("x")),
                .toggle(title: AttributedString("Out"), children: [
                    .bullet(text: AttributedString("a")),
                    .bullet(text: AttributedString("b"))
                ])
            ]
        )
        let xID = doc.children[0].id
        let aID = doc.children[1].children[0].id
        let bID = doc.children[1].children[1].id
        #expect(doc.slideSiblings([xID], by: 1))
        #expect(doc.children.map(\.id) == [doc.children[0].id, xID])
        #expect(doc.children[0].children.map(\.id) == [aID, bID])
    }

    @Test func slideSiblingsUpBelowHeadingMovesToHeadingEnd() {
        // [heading Out {a, b}, bullet x]
        // Slide-up x enters the end of the heading body because headings are
        // section envelopes whose children render visually flush.
        let doc = Document(
            url: URL(fileURLWithPath: "/tmp/test.md"),
            children: [
                .heading(level: .h1, text: AttributedString("Out"), children: [
                    .bullet(text: AttributedString("a")),
                    .bullet(text: AttributedString("b"))
                ]),
                .bullet(text: AttributedString("x"))
            ]
        )
        let headingID = doc.children[0].id
        let aID = doc.children[0].children[0].id
        let bID = doc.children[0].children[1].id
        let xID = doc.children[1].id
        #expect(doc.slideSiblings([xID], by: -1))
        #expect(doc.children.map(\.id) == [headingID])
        #expect(doc.children[0].children.map(\.id) == [aID, bID, xID])
    }

    @Test func slideSiblingsDownInsideToggleReordersInsteadOfIndentingIntoNextChild() {
        let doc = Document(
            url: URL(fileURLWithPath: "/tmp/test.md"),
            children: [
                .toggle(title: AttributedString("Out"), children: [
                    .bullet(text: AttributedString("a")),
                    .bullet(text: AttributedString("b"), children: [
                        .bullet(text: AttributedString("c"))
                    ])
                ])
            ]
        )
        let aID = doc.children[0].children[0].id
        let bID = doc.children[0].children[1].id
        let cID = doc.children[0].children[1].children[0].id
        #expect(doc.slideSiblings([aID], by: 1))
        #expect(doc.children[0].children.map(\.id) == [bID, aID])
        #expect(doc.children[0].children[0].children.map(\.id) == [cID])
    }

    @Test func slideSiblingsAtToggleBoundariesCanExitToggle() {
        let doc = Document(
            url: URL(fileURLWithPath: "/tmp/test.md"),
            children: [
                .paragraph(text: AttributedString("before")),
                .toggle(title: AttributedString("Out"), children: [
                    .bullet(text: AttributedString("a")),
                    .bullet(text: AttributedString("b"))
                ]),
                .paragraph(text: AttributedString("after"))
            ]
        )
        let beforeID = doc.children[0].id
        let toggleID = doc.children[1].id
        let aID = doc.children[1].children[0].id
        let bID = doc.children[1].children[1].id
        let afterID = doc.children[2].id

        #expect(doc.slideSiblings([aID], by: -1))
        #expect(doc.children.map(\.id) == [beforeID, aID, toggleID, afterID])

        #expect(doc.slideSiblings([bID], by: 1))
        #expect(doc.children.map(\.id) == [beforeID, aID, toggleID, bID, afterID])
        #expect(doc.children[2].children.isEmpty)
    }

    @Test func outdentOnlyChildOfToggleLeavesToggleEmpty() {
        let doc = Document(
            url: URL(fileURLWithPath: "/tmp/test.md"),
            children: [
                .toggle(title: AttributedString("Out"), children: [
                    .bullet(text: AttributedString("a"))
                ]),
                .paragraph(text: AttributedString("after"))
            ]
        )
        let toggleID = doc.children[0].id
        let aID = doc.children[0].children[0].id
        let afterID = doc.children[1].id

        #expect(doc.canOutdent(aID))
        #expect(doc.outdent(aID))
        #expect(doc.children.map(\.id) == [toggleID, aID, afterID])
        #expect(doc.children[0].children.isEmpty)
    }

    @Test func slideSiblingsAtBoundaryFallsBackToOutdentWhenNeighborIsLeaf() {
        // [bullet A {x}, paragraph P]
        // Slide-down x from end of A → P is a leaf, can't accept; falls back
        // to outdent: x becomes a top-level sibling between A and P.
        let doc = Document(
            url: URL(fileURLWithPath: "/tmp/test.md"),
            children: [
                .bullet(text: AttributedString("A"), children: [
                    .bullet(text: AttributedString("x"))
                ]),
                .paragraph(text: AttributedString("P"))
            ]
        )
        let xID = doc.children[0].children[0].id
        #expect(doc.slideSiblings([xID], by: 1))
        #expect(doc.children.count == 3)
        #expect(doc.children[0].children.isEmpty)
        #expect(doc.children[1].id == xID)
    }

    @Test func childrenIsValueTypeSnapshot() {
        // `Document.children` is a `[Block]` value-type array, so capturing
        // it is a shallow-copy that doesn't track subsequent mutations. The
        // undo machinery relies on this — `let before = children` inside
        // `transaction` is enough to roll back to.
        let doc = makeDoc()
        let snapshot = doc.children
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

    // MARK: - Split-preserves-marks invariants
    //
    // EditorView.splitBlock isn't directly callable from tests (it's view-private),
    // but the underlying invariant is: slicing an AttributedString with bolded /
    // italicized / linked runs and feeding the slices back through
    // `Document.setText` (head) and a fresh paragraph block (tail) must preserve
    // every inline mark. A regression to plain-`String` slicing would fail these.

    private func boldedHello() -> AttributedString {
        // "hello world" with "hello" bolded.
        var attr = AttributedString("hello world")
        let end = attr.index(attr.startIndex, offsetByCharacters: 5)
        attr[attr.startIndex..<end][InlineAttributes.BoldAttribute.self] = true
        return attr
    }

    private func sliceMimickingSplit(_ attr: AttributedString, at offset: Int) -> (AttributedString, AttributedString) {
        let idx = attr.index(attr.startIndex, offsetByCharacters: offset)
        let head = AttributedString(attr[attr.startIndex..<idx])
        let tail = AttributedString(attr[idx..<attr.endIndex])
        return (head, tail)
    }

    private func runHasBold(_ s: AttributedString) -> Bool {
        s.runs.contains { $0[InlineAttributes.BoldAttribute.self] == true }
    }

    @Test func splitPreservesBoldOnHead() {
        let attr = boldedHello()
        let (head, _) = sliceMimickingSplit(attr, at: attr.characters.count)
        let doc = Document(
            url: URL(fileURLWithPath: "/tmp/test.md"),
            children: [.paragraph(text: attr)]
        )
        let id = doc.children[0].id
        _ = doc.setText(id, head)
        guard case .paragraph(let updated) = doc.find(id)?.kind else {
            Issue.record("expected paragraph"); return
        }
        #expect(String(updated.characters) == "hello world")
        #expect(runHasBold(updated))
    }

    @Test func splitPreservesBoldOnTail() {
        // Split before the bold: tail keeps the bolded "hello".
        var attr = AttributedString("xx hello")
        let boldStart = attr.index(attr.startIndex, offsetByCharacters: 3)
        attr[boldStart..<attr.endIndex][InlineAttributes.BoldAttribute.self] = true
        let (_, tail) = sliceMimickingSplit(attr, at: 3)
        #expect(String(tail.characters) == "hello")
        #expect(runHasBold(tail))
    }

    @Test func splitPreservesItalic() {
        var attr = AttributedString("italic word")
        let end = attr.index(attr.startIndex, offsetByCharacters: 6)
        attr[attr.startIndex..<end][InlineAttributes.ItalicAttribute.self] = true
        let (head, _) = sliceMimickingSplit(attr, at: attr.characters.count)
        let hasItalic = head.runs.contains { $0[InlineAttributes.ItalicAttribute.self] == true }
        #expect(hasItalic)
    }

    @Test func splitPreservesLink() {
        var attr = AttributedString("see docs")
        let linkStart = attr.index(attr.startIndex, offsetByCharacters: 4)
        attr[linkStart..<attr.endIndex].link = URL(string: "https://example.com/docs")
        let (head, tail) = sliceMimickingSplit(attr, at: 4)
        // head: "see " — no link. tail: "docs" — link preserved.
        #expect(head.runs.allSatisfy { $0.link == nil })
        #expect(tail.runs.contains { $0.link?.absoluteString == "https://example.com/docs" })
    }
}
