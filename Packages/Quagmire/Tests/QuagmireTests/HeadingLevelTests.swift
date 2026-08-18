import Foundation
import Testing
@testable import Quagmire

/// H1–H6 are all representable; only H1–H3 are authorable.
///
/// The split matters: Notion has three heading levels and Hunch's creation UI
/// deliberately matches it, but a Markdown document can carry six. Collapsing
/// the other three at parse time meant the serializer wrote the collapsed depth
/// back out, so opening someone's document and editing an unrelated line
/// silently rewrote their headings.
@MainActor
@Suite("HeadingLevel")
struct HeadingLevelTests {

    @Test func everyMarkdownLevelIsRepresentable() {
        #expect(HeadingLevel.allCases.map(\.rawValue) == [1, 2, 3, 4, 5, 6])
        for level in 1...6 {
            #expect(HeadingLevel(level: level)?.rawValue == level)
        }
    }

    @Test func outOfRangeLevelsHaveNoRepresentation() {
        #expect(HeadingLevel(level: 0) == nil)
        #expect(HeadingLevel(level: 7) == nil)
    }

    @Test func clampingSaturatesRatherThanFoldingToH1() {
        #expect(HeadingLevel.clamped(0) == .h1)
        #expect(HeadingLevel.clamped(4) == .h4)
        #expect(HeadingLevel.clamped(6) == .h6)
        #expect(HeadingLevel.clamped(9) == .h6)
    }

    @Test func onlyTheFirstThreeAreOfferedForAuthoring() {
        #expect(HeadingLevel.authorable == [.h1, .h2, .h3])
        #expect(HeadingLevel.h3.isAuthorable)
        #expect(!HeadingLevel.h4.isAuthorable)
        #expect(!HeadingLevel.h6.isAuthorable)
    }

    @Test func levelsOrderByDepth() {
        #expect(HeadingLevel.h1 < HeadingLevel.h6)
        #expect(HeadingLevel.h4 < HeadingLevel.h5)
    }

    // MARK: - Containment

    @Test func aDeepHeadingCanNestUnderAShallowerOne() {
        let h4 = Block.heading(level: .h4, text: AttributedString("four"))
        let h2 = Block.heading(level: .h2, text: AttributedString("two"))
        #expect(h2.canContain(h4))
        #expect(!h4.canContain(h2))
    }

    @Test func aHeadingCannotContainOneAtItsOwnLevel() {
        let a = Block.heading(level: .h5, text: AttributedString("a"))
        let b = Block.heading(level: .h5, text: AttributedString("b"))
        #expect(!a.canContain(b))
    }

    @Test func containmentFoldsAllSixLevels() {
        let doc = Document(id: DocumentID("t"), children: (1...6).map {
            Block.heading(level: HeadingLevel(level: $0)!, text: AttributedString("h\($0)"))
        })
        doc.transaction(name: "fold") {}

        // Each level nests inside the one above it.
        var node = doc.children.first
        #expect(doc.children.count == 1)
        for level in 1...6 {
            #expect(node?.headingLevel?.rawValue == level)
            node = node?.children.first
        }
    }

    // MARK: - Rendering

    @Test func everyLevelHasADistinctOrNonIncreasingSize() {
        let theme = EditorTheme.default
        let sizes = HeadingLevel.allCases.map { theme.headingSize($0) }
        #expect(sizes == sizes.sorted(by: >), "heading sizes must not grow with depth")
        #expect(sizes.last == theme.typography.bodySize, "H6 bottoms out at body size")
    }
}
