import Testing
import Foundation
@testable import Editor

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
        if case .paragraph(_, let t, _) = doc.blocks[0] {
            #expect(String(t.characters) == "head")
        } else {
            Issue.record("expected paragraph at 0")
        }
        if case .paragraph(_, let t, _) = doc.blocks[1] {
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
        if case .paragraph(_, let t, _) = updated {
            #expect(String(t.characters) == "new")
        } else {
            Issue.record("expected paragraph")
        }
    }

    @Test func withTextPreservesHeadingLevel() {
        let original = Block.heading(level: 2, text: AttributedString("old"))
        let updated = original.withText(AttributedString("new"))
        if case .heading(_, let level, let t, _) = updated {
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
        let original = Block.toggle(title: AttributedString("old title"))
        let updated = original.withText(AttributedString("new title"))
        if case .toggle(let id, let title, _) = updated {
            #expect(id == original.id)
            #expect(String(title.characters) == "new title")
        } else {
            Issue.record("expected toggle")
        }
    }

    @Test func withTextOnTemplateButtonReplacesLabel() {
        let original = Block.templateButton(label: "old label")
        let updated = original.withText(AttributedString("new label"))
        if case .templateButton(let id, let label, _) = updated {
            #expect(id == original.id)
            #expect(label == "new label")
        } else {
            Issue.record("expected template button")
        }
    }

    @Test func withFreshIDPreservesTemplateButtonContent() {
        let original = Block.templateButton(label: "Insert", indent: 2)
        let copied = original.withFreshID()
        #expect(copied.id != original.id)
        if case .templateButton(_, let label, let indent) = copied {
            #expect(label == "Insert")
            #expect(indent == 2)
        } else {
            Issue.record("expected template button copy")
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

    @Test func withIndentUpdatesNonListBlock() {
        let p = Block.paragraph(text: AttributedString("x"))
        let updated = p.withIndent(2)
        #expect(updated.indent == 2)
    }

    @Test func sectionRangeEmptySectionIncludesOnlyBlock() {
        let doc = makeDoc()
        let range = doc.sectionRange(of: doc.blocks[0].id)
        #expect(range == 0..<1)
    }

    @Test func sectionRangeIncludesSingleDescendant() {
        let doc = makeDoc()
        let range = doc.sectionRange(of: doc.blocks[1].id)
        #expect(range == 1..<3)
    }

    @Test func sectionRangeStopsAtFirstSiblingOrAncestor() {
        let doc = Document(
            url: URL(fileURLWithPath: "/tmp/test.md"),
            title: "Test",
            blocks: [
                .bullet(text: AttributedString("root"), indent: 1),
                .bullet(text: AttributedString("child"), indent: 2),
                .paragraph(text: AttributedString("grandchild"), indent: 3),
                .quote(text: AttributedString("sibling"), indent: 1),
                .paragraph(text: AttributedString("after"), indent: 0)
            ]
        )
        #expect(doc.sectionRange(of: doc.blocks[0].id) == 0..<3)
    }

    @Test func indicesIncludingSectionsDedupesInDocumentOrder() {
        let doc = Document(
            url: URL(fileURLWithPath: "/tmp/test.md"),
            title: "Test",
            blocks: [
                .bullet(text: AttributedString("parent"), indent: 0),
                .paragraph(text: AttributedString("child"), indent: 1),
                .quote(text: AttributedString("grandchild"), indent: 2),
                .paragraph(text: AttributedString("sibling"), indent: 0),
                .bullet(text: AttributedString("paragraph child"), indent: 1)
            ]
        )
        let indices = doc.indicesIncludingSections(of: [doc.blocks[0].id, doc.blocks[1].id])
        #expect(indices == [0, 1, 2])
        #expect(doc.sectionRange(of: doc.blocks[3].id) == 3..<5)
    }

    @Test func moveRootSectionUpMovesBeforePreviousRootSection() {
        var doc = outlineDoc()
        let glassware = doc.blocks[3].id

        let moved = doc.moveSections(containing: [glassware], by: -1)
        #expect(moved)
        #expect(blockTexts(doc) == ["Glassware", "Food", "Carrots", "Chicken"])
    }

    @Test func moveRootSectionDownCarriesChildrenPastNextRootSection() {
        var doc = outlineDoc()
        let food = doc.blocks[0].id

        let moved = doc.moveSections(containing: [food], by: 1)
        #expect(moved)
        #expect(blockTexts(doc) == ["Glassware", "Food", "Carrots", "Chicken"])
    }

    @Test func moveChildSectionSwapsOnlyWithSibling() {
        var doc = outlineDoc()
        let chicken = doc.blocks[2].id

        let moved = doc.moveSections(containing: [chicken], by: -1)
        #expect(moved)
        #expect(blockTexts(doc) == ["Food", "Chicken", "Carrots", "Glassware"])
        #expect(doc.blocks.map(\.indent) == [0, 1, 1, 0])
    }

    @Test func moveFirstChildUpDoesNotPromotePastParent() {
        var doc = outlineDoc()
        let carrots = doc.blocks[1].id

        let moved = doc.moveSections(containing: [carrots], by: -1)
        #expect(!moved)
        #expect(blockTexts(doc) == ["Food", "Carrots", "Chicken", "Glassware"])
    }

    @Test func moveSelectedSectionCarriesDescendants() {
        var doc = Document(
            url: URL(fileURLWithPath: "/tmp/test.md"),
            title: "Test",
            blocks: [
                .bullet(text: AttributedString("Food"), indent: 0),
                .bullet(text: AttributedString("Produce"), indent: 1),
                .bullet(text: AttributedString("Carrots"), indent: 2),
                .bullet(text: AttributedString("Chicken"), indent: 1),
                .bullet(text: AttributedString("Glassware"), indent: 0)
            ]
        )
        let chicken = doc.blocks[3].id

        let moved = doc.moveSections(containing: [chicken], by: -1)
        #expect(moved)
        #expect(blockTexts(doc) == ["Food", "Chicken", "Produce", "Carrots", "Glassware"])
        #expect(doc.blocks.map(\.indent) == [0, 1, 1, 2, 0])
    }

    private func outlineDoc() -> Document {
        Document(
            url: URL(fileURLWithPath: "/tmp/test.md"),
            title: "Test",
            blocks: [
                .bullet(text: AttributedString("Food"), indent: 0),
                .bullet(text: AttributedString("Carrots"), indent: 1),
                .bullet(text: AttributedString("Chicken"), indent: 1),
                .bullet(text: AttributedString("Glassware"), indent: 0)
            ]
        )
    }

    private func blockTexts(_ doc: Document) -> [String] {
        doc.blocks.map { block in
            switch block {
            case .paragraph(_, let text, _),
                 .heading(_, _, let text, _),
                 .bullet(_, let text, _),
                 .numbered(_, let text, _),
                 .todo(_, let text, _, _),
                 .quote(_, let text, _),
                 .toggle(_, let text, _):
                return String(text.characters)
            case .templateButton(_, let label, _):
                return label
            case .code(_, let source, _, _):
                return source
            case .divider:
                return "---"
            case .subpage(_, let title, _, _):
                return title
            }
        }
    }
}
