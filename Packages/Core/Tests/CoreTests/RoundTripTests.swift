import Testing
import Foundation
@testable import Core

@Suite("Markdown round-trip")
struct RoundTripTests {
    /// Round-trip equivalence at the *block-shape* level: structure, indent, code language,
    /// toggle tree, plain text content. Inline attributes are checked separately because
    /// the surface markdown syntax can normalise (`*x*` → `_x_` or vice versa).
    @Test func paragraph() {
        roundTrip("Hello world.\n")
    }

    @Test func headings() {
        roundTrip("# H1\n\n## H2\n\n### H3\n")
    }

    @Test func bullets() {
        roundTrip("- one\n- two\n- three\n")
    }

    @Test func nestedBullets() {
        let src = """
        - a
          - a.1
            - a.1.1
        - b
        """
        let blocks = BlockParser.parse(src)
        let indents = blocks.compactMap { block -> Int? in
            if case .bullet(_, _, let i) = block { return i }
            return nil
        }
        #expect(indents == [0, 1, 2, 0])
    }

    @Test func numbered() {
        roundTrip("1. one\n1. two\n")
    }

    @Test func todo() {
        let blocks = BlockParser.parse("- [ ] open\n- [x] done\n")
        guard blocks.count == 2 else {
            Issue.record("expected 2 todo blocks, got \(blocks.count)")
            return
        }
        if case .todo(_, _, let done1, _) = blocks[0] { #expect(done1 == false) }
        else { Issue.record("first block not todo") }
        if case .todo(_, _, let done2, _) = blocks[1] { #expect(done2 == true) }
        else { Issue.record("second block not todo") }
    }

    @Test func quote() {
        let blocks = BlockParser.parse("> a quote\n")
        #expect(blocks.count == 1)
        if case .quote(_, let text) = blocks[0] {
            #expect(String(text.characters) == "a quote")
        } else {
            Issue.record("not a quote")
        }
    }

    @Test func codeBlock() {
        let blocks = BlockParser.parse("```swift\nlet x = 1\n```\n")
        #expect(blocks.count == 1)
        if case .code(_, let source, let lang) = blocks[0] {
            #expect(lang == "swift")
            #expect(source.contains("let x = 1"))
        } else {
            Issue.record("not a code block")
        }
    }

    @Test func divider() {
        let blocks = BlockParser.parse("---\n")
        #expect(blocks.count == 1)
        if case .divider = blocks[0] {} else { Issue.record("not divider") }
    }

    @Test func toggleSimple() {
        let src = """
        <details><summary>Title</summary>

        - a
        - b

        </details>
        """
        let blocks = BlockParser.parse(src)
        #expect(blocks.count == 1)
        guard case .toggle(_, let title, _, let children) = blocks[0] else {
            Issue.record("not a toggle")
            return
        }
        #expect(String(title.characters) == "Title")
        #expect(children.count == 2)
        if case .bullet(_, _, _) = children[0] {} else { Issue.record("first child not bullet") }
    }

    @Test func subpage() {
        let blocks = BlockParser.parse("[Notes](folder/page.md)\n")
        #expect(blocks.count == 1)
        if case .subpage(_, let title, let path) = blocks[0] {
            #expect(title == "Notes")
            #expect(path == "folder/page.md")
        } else {
            Issue.record("not a subpage")
        }
    }

    @Test func nonSubpageLink() {
        // External (non-.md) link should remain a paragraph
        let blocks = BlockParser.parse("[Apple](https://apple.com)\n")
        #expect(blocks.count == 1)
        if case .paragraph = blocks[0] {} else {
            Issue.record("expected paragraph, got \(blocks[0])")
        }
    }

    @Test func inlineEmphasisRoundTrip() {
        let blocks = BlockParser.parse("This is **bold** and *italic* and `code`.\n")
        #expect(blocks.count == 1)
        guard case .paragraph(_, let text) = blocks[0] else {
            Issue.record("not paragraph")
            return
        }
        // Verify each emphasis kind is present somewhere in the runs.
        var sawBold = false, sawItalic = false, sawCode = false
        for run in text.runs {
            if run[InlineAttributes.BoldAttribute.self] == true { sawBold = true }
            if run[InlineAttributes.ItalicAttribute.self] == true { sawItalic = true }
            if run[InlineAttributes.CodeAttribute.self] == true { sawCode = true }
        }
        #expect(sawBold)
        #expect(sawItalic)
        #expect(sawCode)

        // Re-serialize and re-parse: emphases survive
        let serialized = BlockSerializer.serialize(blocks)
        let parsed2 = BlockParser.parse(serialized)
        guard case .paragraph(_, let text2) = parsed2[0] else {
            Issue.record("re-parse not paragraph")
            return
        }
        var sawBold2 = false, sawItalic2 = false, sawCode2 = false
        for run in text2.runs {
            if run[InlineAttributes.BoldAttribute.self] == true { sawBold2 = true }
            if run[InlineAttributes.ItalicAttribute.self] == true { sawItalic2 = true }
            if run[InlineAttributes.CodeAttribute.self] == true { sawCode2 = true }
        }
        #expect(sawBold2)
        #expect(sawItalic2)
        #expect(sawCode2)
    }

    @Test func toggleNestedRoundTrip() {
        let src = """
        <details><summary>Outer</summary>

        - one
        - two

        <details><summary>Inner</summary>

        - inner-one

        </details>

        </details>
        """
        let blocks = BlockParser.parse(src)
        #expect(blocks.count == 1)
        guard case .toggle(_, _, _, let outerChildren) = blocks[0] else {
            Issue.record("outer not toggle")
            return
        }
        let innerToggle = outerChildren.first { if case .toggle = $0 { return true } else { return false } }
        #expect(innerToggle != nil)
    }

    // MARK: - helpers

    private func roundTrip(_ source: String, file: StaticString = #filePath, line: UInt = #line) {
        let parsed = BlockParser.parse(source)
        let serialized = BlockSerializer.serialize(parsed)
        let reparsed = BlockParser.parse(serialized)
        // Block-shape equivalence: count and case of each block.
        #expect(parsed.count == reparsed.count, "block count mismatch after round-trip")
        for (a, b) in zip(parsed, reparsed) {
            #expect(blockKind(a) == blockKind(b), "block kind mismatch: \(blockKind(a)) vs \(blockKind(b))")
            #expect(plainText(a) == plainText(b), "text mismatch")
        }
    }

    private func blockKind(_ b: Block) -> String {
        switch b {
        case .paragraph: return "paragraph"
        case .heading(_, let level, _): return "heading-\(level)"
        case .bullet(_, _, let i): return "bullet-\(i)"
        case .numbered(_, _, let i): return "numbered-\(i)"
        case .todo(_, _, _, let i): return "todo-\(i)"
        case .quote: return "quote"
        case .code(_, _, let lang): return "code-\(lang ?? "nil")"
        case .divider: return "divider"
        case .toggle: return "toggle"
        case .subpage: return "subpage"
        }
    }

    private func plainText(_ b: Block) -> String {
        switch b {
        case .paragraph(_, let t), .heading(_, _, let t),
             .bullet(_, let t, _), .numbered(_, let t, _),
             .todo(_, let t, _, _), .quote(_, let t),
             .toggle(_, let t, _, _):
            return String(t.characters)
        case .code(_, let s, _): return s.trimmingCharacters(in: .whitespacesAndNewlines)
        case .divider: return ""
        case .subpage(_, let title, _): return title
        }
    }
}
