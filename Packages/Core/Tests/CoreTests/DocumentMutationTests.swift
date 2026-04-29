import Testing
import Foundation
@testable import Core

@Suite("Document mutation helpers")
struct DocumentMutationTests {
    private func makeDoc() -> Document {
        Document(
            url: URL(fileURLWithPath: "/tmp/test.md"),
            title: "Test",
            blocks: [
                .paragraph(text: AttributedString("first")),
                .bullet(text: AttributedString("a"), indent: 0),
                .bullet(text: AttributedString("b"), indent: 1),
                .heading(level: 2, text: AttributedString("section"))
            ]
        )
    }

    @Test func indexOfFindsBlock() {
        let doc = makeDoc()
        let target = doc.blocks[2].id
        #expect(doc.index(of: target) == 2)
    }

    @Test func indexOfReturnsNilForMissing() {
        let doc = makeDoc()
        #expect(doc.index(of: BlockID()) == nil)
    }

    @Test func removeDeletesAndReturnsBlock() {
        var doc = makeDoc()
        let target = doc.blocks[1].id
        let removed = doc.remove(blockID: target)
        #expect(removed?.id == target)
        #expect(doc.blocks.count == 3)
        #expect(doc.index(of: target) == nil)
    }

    @Test func removeMissingIsNoop() {
        var doc = makeDoc()
        let originalCount = doc.blocks.count
        let removed = doc.remove(blockID: BlockID())
        #expect(removed == nil)
        #expect(doc.blocks.count == originalCount)
    }

    @Test func replaceWithMultipleBlocks() {
        var doc = makeDoc()
        let target = doc.blocks[0].id
        doc.replace(blockID: target, with: [
            .paragraph(text: AttributedString("head")),
            .paragraph(text: AttributedString("tail"))
        ])
        #expect(doc.blocks.count == 5)
        if case .paragraph(_, let t) = doc.blocks[0] {
            #expect(String(t.characters) == "head")
        } else {
            Issue.record("expected paragraph at 0")
        }
        if case .paragraph(_, let t) = doc.blocks[1] {
            #expect(String(t.characters) == "tail")
        } else {
            Issue.record("expected paragraph at 1")
        }
    }

    @Test func insertAfterAppendsRightAfterTarget() {
        var doc = makeDoc()
        let target = doc.blocks[1].id
        let newBlock = Block.bullet(text: AttributedString("inserted"), indent: 0)
        doc.insert(newBlock, after: target)
        #expect(doc.blocks.count == 5)
        if case .bullet(_, let t, _) = doc.blocks[2] {
            #expect(String(t.characters) == "inserted")
        } else {
            Issue.record("expected inserted bullet at 2")
        }
    }

    @Test func withTextReplacesParagraphBody() {
        let original = Block.paragraph(text: AttributedString("old"))
        let updated = original.withText(AttributedString("new"))
        #expect(updated.id == original.id)
        if case .paragraph(_, let t) = updated {
            #expect(String(t.characters) == "new")
        } else {
            Issue.record("expected paragraph")
        }
    }

    @Test func withTextPreservesHeadingLevel() {
        let original = Block.heading(level: 2, text: AttributedString("old"))
        let updated = original.withText(AttributedString("new"))
        if case .heading(_, let level, let t) = updated {
            #expect(level == 2)
            #expect(String(t.characters) == "new")
        } else {
            Issue.record("expected heading")
        }
    }

    @Test func withTextOnDividerIsNoop() {
        let original = Block.divider()
        let updated = original.withText(AttributedString("ignored"))
        #expect(updated.id == original.id)
        if case .divider = updated {
            // ok
        } else {
            Issue.record("divider should stay divider")
        }
    }

    @Test func withTextOnToggleReplacesTitle() {
        let original = Block.toggle(
            title: AttributedString("old title"),
            expanded: true,
            children: [.paragraph(text: AttributedString("kid"))]
        )
        let updated = original.withText(AttributedString("new title"))
        if case .toggle(_, let title, let expanded, let children) = updated {
            #expect(String(title.characters) == "new title")
            #expect(expanded == true)
            #expect(children.count == 1)
        } else {
            Issue.record("expected toggle")
        }
    }

    @Test func withIndentClamps() {
        let bullet = Block.bullet(text: AttributedString("x"), indent: 0)
        if case .bullet(_, _, let i) = bullet.withIndent(99) {
            #expect(i == 5)
        } else { Issue.record("expected bullet") }
        if case .bullet(_, _, let i) = bullet.withIndent(-1) {
            #expect(i == 0)
        } else { Issue.record("expected bullet") }
    }

    @Test func withIndentNoopOnNonListBlock() {
        let p = Block.paragraph(text: AttributedString("x"))
        let updated = p.withIndent(2)
        #expect(updated.indent == 0)
    }
}
