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

    @Test func bulletWithParagraphChild() {
        let src = """
        - parent

          child paragraph
        """
        let blocks = BlockParser.parse(src)
        guard blocks.count == 2 else {
            Issue.record("expected 2 blocks, got \(blocks.count)")
            return
        }
        if case .paragraph(_, let text, let indent) = blocks[1] {
            #expect(String(text.characters) == "child paragraph")
            #expect(indent == 1)
        } else {
            Issue.record("expected paragraph child")
        }
        roundTrip(src)
    }

    @Test func bulletWithQuoteChild() {
        let src = """
        - parent
          > child quote
        """
        let blocks = BlockParser.parse(src)
        #expect(blocks.count == 2)
        if case .quote(_, let text, let indent) = blocks[1] {
            #expect(String(text.characters) == "child quote")
            #expect(indent == 1)
        } else {
            Issue.record("expected quote child")
        }
        roundTrip(src)
    }

    @Test func bulletWithCodeChild() {
        let src = """
        - parent

          ```swift
          let x = 1
          ```
        """
        let blocks = BlockParser.parse(src)
        guard blocks.count == 2 else {
            Issue.record("expected 2 blocks, got \(blocks.count)")
            return
        }
        if case .code(_, let source, let language, let indent) = blocks[1] {
            #expect(language == "swift")
            #expect(source.contains("let x = 1"))
            #expect(indent == 1)
        } else {
            Issue.record("expected code child")
        }
        roundTrip(src)
    }

    @Test func nestedBulletWithParagraphChild() {
        let src = """
        - parent
          - child

            paragraph
        """
        let blocks = BlockParser.parse(src)
        guard blocks.count == 3 else {
            Issue.record("expected 3 blocks, got \(blocks.count)")
            return
        }
        if case .paragraph(_, let text, let indent) = blocks[2] {
            #expect(String(text.characters) == "paragraph")
            #expect(indent == 2)
        } else {
            Issue.record("expected paragraph child")
        }
        roundTrip(src)
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
        if case .quote(_, let text, _) = blocks[0] {
            #expect(String(text.characters) == "a quote")
        } else {
            Issue.record("not a quote")
        }
    }

    @Test func codeBlock() {
        let blocks = BlockParser.parse("```swift\nlet x = 1\n```\n")
        #expect(blocks.count == 1)
        if case .code(_, let source, let lang, _) = blocks[0] {
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
        // Body blocks are flat siblings at indent + 1, not nested in a children array.
        #expect(blocks.count == 3)
        guard case .toggle(_, let title, let toggleIndent) = blocks[0] else {
            Issue.record("not a toggle")
            return
        }
        #expect(String(title.characters) == "Title")
        #expect(toggleIndent == 0)
        if case .bullet(_, _, let i) = blocks[1] {
            #expect(i == 1)
        } else { Issue.record("first body block not bullet") }
        if case .bullet(_, _, let i) = blocks[2] {
            #expect(i == 1)
        } else { Issue.record("second body block not bullet") }
    }

    @Test func subpage() {
        let blocks = BlockParser.parse("[Notes](folder/page.md)\n")
        #expect(blocks.count == 1)
        if case .subpage(_, let title, let path, _) = blocks[0] {
            #expect(title == "Notes")
            #expect(path == "folder/page.md")
        } else {
            Issue.record("not a subpage")
        }
    }

    @Test func subpageSerializationCanResolveCurrentTitle() {
        let blocks: [Block] = [
            .subpage(title: "Old Link Text", path: "folder/page.md")
        ]

        let serialized = BlockSerializer.serialize(blocks) { path in
            path == "folder/page.md" ? "Current Page Title" : nil
        }

        #expect(serialized == "[Current Page Title](folder/page.md)\n\n")
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
        guard case .paragraph(_, let text, _) = blocks[0] else {
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
        guard case .paragraph(_, let text2, _) = parsed2[0] else {
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

    @Test func toggleBodyEditableAndRoundTrips() {
        // The whole point of the flat-toggle change: a toggle's body lives as siblings at
        // indent + 1, so it goes through the normal block-row path and edits naturally.
        // Verify a paragraph in the body is at the right indent on parse, that it survives
        // re-serialize, and that adding an indent + 1 sibling extends the toggle's section.
        let src = """
        <details><summary>Toggle</summary>

        Body paragraph.

        - bullet

        </details>
        """
        var blocks = BlockParser.parse(src)
        #expect(blocks.count == 3)
        guard case .toggle(let toggleID, _, 0) = blocks[0] else { Issue.record("not a toggle"); return }
        if case .paragraph(_, _, let i) = blocks[1] { #expect(i == 1) } else { Issue.record("body not paragraph") }
        if case .bullet(_, _, let i) = blocks[2] { #expect(i == 1) } else { Issue.record("body not bullet") }

        // Append a new sibling at indent 1 — section extends.
        blocks.append(.paragraph(text: AttributedString("appended"), indent: 1))
        let doc = Document(url: URL(fileURLWithPath: "/tmp/x.md"), title: "Toggle", blocks: blocks)
        #expect(doc.sectionRange(of: toggleID) == 0..<4)

        // Re-serialize / re-parse keeps the new sibling inside the toggle.
        let reparsed = BlockParser.parse(BlockSerializer.serialize(blocks))
        #expect(reparsed.count == 4)
        if case .paragraph(_, let t, let i) = reparsed[3] {
            #expect(String(t.characters) == "appended")
            #expect(i == 1)
        } else { Issue.record("appended not paragraph at indent 1") }
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
        // Outer toggle, two outer-body bullets at indent 1, inner toggle at indent 1, one
        // inner-body bullet at indent 2.
        guard case .toggle(_, let outerTitle, let outerIndent) = blocks[0] else {
            Issue.record("outer not toggle")
            return
        }
        #expect(String(outerTitle.characters) == "Outer")
        #expect(outerIndent == 0)
        let innerIdx = blocks.firstIndex { if case .toggle = $0 { return $0.id != blocks[0].id } else { return false } }
        guard let innerIdx, case .toggle(_, let innerTitle, let innerIndent) = blocks[innerIdx] else {
            Issue.record("inner toggle not found")
            return
        }
        #expect(String(innerTitle.characters) == "Inner")
        #expect(innerIndent == 1)
        // Re-serialize and re-parse: structure preserved.
        let serialized = BlockSerializer.serialize(blocks)
        let reparsed = BlockParser.parse(serialized)
        #expect(reparsed.count == blocks.count)
        for (a, b) in zip(blocks, reparsed) {
            #expect(blockKind(a) == blockKind(b))
        }
    }

    @Test func templateButtonSimple() {
        let src = """
        :::{template-button} Meeting notes
        ## Agenda
        - Topic
        :::
        """
        let blocks = BlockParser.parse(src)
        #expect(blocks.count == 3)
        guard case .templateButton(_, let label, let indent) = blocks[0] else {
            Issue.record("not a template button")
            return
        }
        #expect(label == "Meeting notes")
        #expect(indent == 0)
        if case .heading(_, 2, let text, let i) = blocks[1] {
            #expect(String(text.characters) == "Agenda")
            #expect(i == 1)
        } else {
            Issue.record("body heading missing")
        }
        if case .bullet(_, let text, let i) = blocks[2] {
            #expect(String(text.characters) == "Topic")
            #expect(i == 1)
        } else {
            Issue.record("body bullet missing")
        }
        roundTrip(src)
    }

    @Test func templateButtonNestedAndIndented() {
        let src = """
          :::{template-button} Outer: punctuation, ok!
          - one
            - two
          :::{template-button} Inner
          Body
          :::
          :::
        """
        let blocks = BlockParser.parse(src)
        guard case .templateButton(_, let outer, 1) = blocks[0] else {
            Issue.record("outer template missing")
            return
        }
        #expect(outer == "Outer: punctuation, ok!")
        let innerIndex = blocks.firstIndex {
            if case .templateButton(_, "Inner", _) = $0 { return true }
            return false
        }
        guard let innerIndex, case .templateButton(_, _, let innerIndent) = blocks[innerIndex] else {
            Issue.record("inner template missing")
            return
        }
        #expect(innerIndent == 2)
        roundTrip(src)
    }

    @Test func templateButtonFenceCollisionUsesLongerFence() {
        let blocks: [Block] = [
            .templateButton(label: "Snippet"),
            .paragraph(text: AttributedString("::::"), indent: 1)
        ]
        let serialized = BlockSerializer.serialize(blocks)
        #expect(serialized.hasPrefix(":::::{template-button} Snippet"))
        let reparsed = BlockParser.parse(serialized)
        #expect(reparsed.count == 2)
        if case .paragraph(_, let text, let indent) = reparsed[1] {
            #expect(String(text.characters) == "::::")
            #expect(indent == 1)
        } else {
            Issue.record("body paragraph missing")
        }
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
        case .paragraph(_, _, let i): return "paragraph-\(i)"
        case .heading(_, let level, _, let i): return "heading-\(level)-\(i)"
        case .bullet(_, _, let i): return "bullet-\(i)"
        case .numbered(_, _, let i): return "numbered-\(i)"
        case .todo(_, _, _, let i): return "todo-\(i)"
        case .quote(_, _, let i): return "quote-\(i)"
        case .code(_, _, let lang, let i): return "code-\(lang ?? "nil")-\(i)"
        case .divider(_, let i): return "divider-\(i)"
        case .toggle(_, _, let i): return "toggle-\(i)"
        case .templateButton(_, _, let i): return "template-\(i)"
        case .subpage(_, _, _, let i): return "subpage-\(i)"
        }
    }

    private func plainText(_ b: Block) -> String {
        switch b {
        case .paragraph(_, let t, _), .heading(_, _, let t, _),
             .bullet(_, let t, _), .numbered(_, let t, _),
             .todo(_, let t, _, _), .quote(_, let t, _),
             .toggle(_, let t, _):
            return String(t.characters)
        case .templateButton(_, let label, _):
            return label
        case .code(_, let s, _, _): return s.trimmingCharacters(in: .whitespacesAndNewlines)
        case .divider: return ""
        case .subpage(_, let title, _, _): return title
        }
    }
}
