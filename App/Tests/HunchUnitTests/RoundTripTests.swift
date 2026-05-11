import Testing
import Foundation
@testable import Hunch
import Editor

/// Round-trip tests covering the parser/serializer/heading-fold pipeline.
/// The old indent-based assertions were retired with the tree refactor —
/// these test the new tree shape + idempotence property.
@Suite("Round-trip parser/serializer")
struct RoundTripTests {
    /// Helper: parse → serialize → parse → serialize. The second pass must
    /// match the first character-for-character (idempotence property).
    private func assertIdempotent(_ source: String) {
        let blocks1 = BlockParser.parse(source)
        let serialized1 = BlockSerializer.serialize(blocks1)
        let blocks2 = BlockParser.parse(serialized1)
        let serialized2 = BlockSerializer.serialize(blocks2)
        #expect(serialized1 == serialized2, "round-trip not idempotent for: \(source.prefix(80))")
    }

    // MARK: - Idempotence on representative inputs

    @Test func paragraphAndHeading() {
        assertIdempotent("# Title\n\nA paragraph.\n")
    }

    @Test func bulletAndNestedList() {
        assertIdempotent("- one\n  - nested\n- two\n")
    }

    @Test func numberedList() {
        assertIdempotent("1. first\n1. second\n")
    }

    @Test func todoList() {
        assertIdempotent("- [ ] open\n- [x] done\n")
    }

    @Test func quote() {
        assertIdempotent("> A quoted line.\n")
    }

    @Test func codeFence() {
        assertIdempotent("```swift\nlet x = 1\n```\n")
    }

    @Test func divider() {
        assertIdempotent("---\n\nbelow\n")
    }

    @Test func toggleWithBody() {
        assertIdempotent("▸ Title\n  body line\n")
    }

    @Test func templateButtonWithBody() {
        assertIdempotent(":::{template-button} Add Task\n- [ ] new\n:::\n")
    }

    @Test func subpageLink() {
        assertIdempotent("[Other Page](other.md)\n")
    }

    /// Regression: a bold run that includes its trailing whitespace must
    /// serialize with the whitespace OUTSIDE the `**` delimiters, otherwise
    /// CommonMark won't recognize the closing `**` as right-flanking and the
    /// markdown round-trips as literal asterisks.
    @Test func boldRunWithTrailingSpaceRoundTrips() {
        var bold = AttributeContainer()
        bold.inlineBold = true
        var s = AttributedString("But there's so many things that are unknown: ")
        s.mergeAttributes(bold)
        let blocks = [Block.paragraph(text: s)]
        let serialized = BlockSerializer.serialize(blocks)
        #expect(serialized == "**But there's so many things that are unknown:** \n\n")

        // The serialized form should re-parse as a single bold run.
        let reparsed = BlockParser.parse(serialized)
        #expect(reparsed.count == 1)
        guard case .paragraph(let text) = reparsed[0].kind else {
            Issue.record("expected paragraph")
            return
        }
        let runs = Array(text.runs)
        // Either a single bold run (with the trailing space outside merged in)
        // or two runs (bold + trailing space). Either way the bold word must
        // carry the bold attribute.
        let bolded = runs.filter { $0[InlineAttributes.BoldAttribute.self] == true }
        #expect(!bolded.isEmpty, "bold attribute lost on round-trip")
    }

    // MARK: - Heading containment (new tree semantics)

    @Test func h1OwnsTrailingParagraph() {
        let blocks = BlockParser.parse("# Title\n\nBody paragraph.\n")
        #expect(blocks.count == 1)
        guard case .heading(.h1, _) = blocks[0].kind else {
            Issue.record("expected H1 root")
            return
        }
        #expect(blocks[0].children.count == 1)
        if case .paragraph(let text) = blocks[0].children[0].kind {
            #expect(String(text.characters) == "Body paragraph.")
        } else {
            Issue.record("expected paragraph under H1")
        }
    }

    @Test func h2InsideH1IsItsChild() {
        let blocks = BlockParser.parse("# A\n\n## B\n\nbody\n")
        #expect(blocks.count == 1)
        guard case .heading(.h1, _) = blocks[0].kind else {
            Issue.record("expected H1 root")
            return
        }
        // H1's children: [H2 with body]
        #expect(blocks[0].children.count == 1)
        if case .heading(.h2, _) = blocks[0].children[0].kind {
            #expect(blocks[0].children[0].children.count == 1)
        } else {
            Issue.record("expected H2 under H1")
        }
    }

    @Test func sameLevelHeadingPopsParent() {
        let blocks = BlockParser.parse("# A\n\n## B\n\n# C\n\nbody\n")
        // [A {children: [B]}, C {children: [body]}]
        #expect(blocks.count == 2)
        guard case .heading(.h1, let aText) = blocks[0].kind,
              case .heading(.h1, let cText) = blocks[1].kind else {
            Issue.record("expected two top-level H1s")
            return
        }
        #expect(String(aText.characters) == "A")
        #expect(String(cText.characters) == "C")
        #expect(blocks[0].children.count == 1)  // B
        #expect(blocks[1].children.count == 1)  // body
    }

    @Test func deeperHeadingClosesShallowOne() {
        // H2 → H1 should close H2 (H1 doesn't nest inside H2).
        let blocks = BlockParser.parse("## A\n\n# B\n\nbody\n")
        #expect(blocks.count == 2)
        guard case .heading(.h2, _) = blocks[0].kind,
              case .heading(.h1, _) = blocks[1].kind else {
            Issue.record("expected H2 then H1 at root")
            return
        }
        #expect(blocks[0].children.isEmpty)
        #expect(blocks[1].children.count == 1)
    }

    @Test func cascadeH2H1H3() {
        // Tricky case: H2 followed by H1 — H1 should pop the H2 and start
        // anew. Then H3 is a child of the H1.
        let blocks = BlockParser.parse("## A\n\n# B\n\n### C\n")
        #expect(blocks.count == 2)
        guard case .heading(.h2, _) = blocks[0].kind,
              case .heading(.h1, _) = blocks[1].kind else {
            Issue.record("expected H2 then H1")
            return
        }
        #expect(blocks[1].children.count == 1)
        if case .heading(.h3, _) = blocks[1].children[0].kind {
            // ok
        } else {
            Issue.record("expected H3 under H1")
        }
    }

    @Test func headingInsideToggleStaysInsideToggle() {
        // The H2 inside a toggle's body should NOT escape the toggle.
        let source = "▸ Toggle Title\n  ## Inside\n  body\n"
        let blocks = BlockParser.parse(source)
        #expect(blocks.count == 1)
        guard case .toggle = blocks[0].kind else {
            Issue.record("expected toggle root")
            return
        }
        // Toggle's children should contain an H2 with a body paragraph.
        let body = blocks[0].children
        #expect(body.count == 1)
        if case .heading(.h2, _) = body[0].kind {
            #expect(body[0].children.count == 1)
        } else {
            Issue.record("expected H2 inside toggle")
        }
    }

    // MARK: - Subtree round-trip stability

    @Test func headingWithBulletListIdempotent() {
        assertIdempotent("# Section\n\n- item\n- item\n  - nested\n\nbelow\n")
    }

    // MARK: - List item with non-list child (bullet+subpage and friends)

    /// Bullet with a `.subpage` child must survive serialize → parse with the
    /// nested-child structure intact. The serializer puts a blank line between
    /// the marker line and the child so CommonMark doesn't fold the indented
    /// link into the bullet's paragraph.
    @Test func bulletWithSubpageChildRoundTripsTree() {
        let tree = [Block.bullet(
            text: AttributedString("Foo bullet"),
            children: [.subpage(title: "Subpage", pageID: "Subpage.md")]
        )]
        let serialized = BlockSerializer.serialize(tree)
        let reparsed = BlockParser.parse(serialized)
        #expect(reparsed.count == 1)
        guard case .bullet(let text) = reparsed[0].kind else {
            Issue.record("expected .bullet root, got \(reparsed[0].kind)")
            return
        }
        #expect(String(text.characters) == "Foo bullet")
        #expect(reparsed[0].children.count == 1)
        guard case .subpage(_, let pageID) = reparsed[0].children[0].kind else {
            Issue.record("expected .subpage child, got \(reparsed[0].children[0].kind)")
            return
        }
        #expect(pageID == "Subpage.md")
    }

    @Test func bulletWithSubpageChildIdempotent() {
        assertIdempotent("- Foo bullet\n\n  [Subpage](Subpage.md)\n")
    }

    /// Backward-compat: files written by the pre-blank-line serializer have
    /// the subpage line fused into the bullet via CommonMark lazy continuation.
    /// The parser peels a trailing softbreak + `.md` link off the leading
    /// paragraph and restores it as a `.subpage` child.
    @Test func bulletWithSubpageChildHealsPreFixFormat() {
        let blocks = BlockParser.parse("- Foo bullet\n  [Subpage](Subpage.md)\n")
        #expect(blocks.count == 1)
        guard case .bullet(let text) = blocks[0].kind else {
            Issue.record("expected .bullet root, got \(blocks[0].kind)")
            return
        }
        #expect(String(text.characters) == "Foo bullet")
        #expect(blocks[0].children.count == 1)
        guard case .subpage(_, let pageID) = blocks[0].children[0].kind else {
            Issue.record("expected .subpage child, got \(blocks[0].children[0].kind)")
            return
        }
        #expect(pageID == "Subpage.md")
    }

    /// Numbered items have a 3-char marker (`1. `), so children indent to
    /// column 3 — same content-column rule that keeps bullets working.
    @Test func numberedWithSubpageChildRoundTripsTree() {
        let tree = [Block.numbered(
            text: AttributedString("Foo"),
            children: [.subpage(title: "Sub", pageID: "sub.md")]
        )]
        let reparsed = BlockParser.parse(BlockSerializer.serialize(tree))
        #expect(reparsed.count == 1)
        guard case .numbered = reparsed[0].kind else {
            Issue.record("expected .numbered root, got \(reparsed[0].kind)")
            return
        }
        #expect(reparsed[0].children.count == 1)
        if case .subpage(_, let pageID) = reparsed[0].children[0].kind {
            #expect(pageID == "sub.md")
        } else {
            Issue.record("expected .subpage child")
        }
    }

    @Test func numberedWithSubpageChildIdempotent() {
        assertIdempotent("1. Foo\n\n   [Sub](sub.md)\n")
    }

    /// Todos render `- [ ] ` but in GFM the list marker itself is just `- ` —
    /// the `[ ]` is content. Children indent to column 2, same as a bullet.
    @Test func todoWithSubpageChildRoundTripsTree() {
        let tree = [Block.todo(
            text: AttributedString("Foo"),
            done: false,
            children: [.subpage(title: "Sub", pageID: "sub.md")]
        )]
        let reparsed = BlockParser.parse(BlockSerializer.serialize(tree))
        #expect(reparsed.count == 1)
        guard case .todo = reparsed[0].kind else {
            Issue.record("expected .todo root, got \(reparsed[0].kind)")
            return
        }
        #expect(reparsed[0].children.count == 1)
        if case .subpage(_, let pageID) = reparsed[0].children[0].kind {
            #expect(pageID == "sub.md")
        } else {
            Issue.record("expected .subpage child")
        }
    }

    @Test func todoWithSubpageChildIdempotent() {
        assertIdempotent("- [ ] Foo\n\n  [Sub](sub.md)\n")
    }
}
