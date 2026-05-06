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
}
