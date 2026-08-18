import Testing
import Foundation
@testable import Hunch
import Quagmire

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

    /// One document containing every construct the parser understands plus one
    /// it does not, asserted byte-for-byte. This is the guard on the claim that
    /// renaming the block model changed no on-disk syntax: if any of it drifts,
    /// existing files in someone's workspace get rewritten the first time they
    /// are opened.
    ///
    /// The consecutive list groups deliberately have no blank lines between
    /// them: adjacent list items pack tight (see
    /// `bulletAndNestedListSerializeTight`), so this is the canonical form, not
    /// a concession.
    @Test func aDocumentUsingEveryConstructRoundTripsByteForByte() {
        let source = """
        # Sample Page

        A paragraph with **bold** and a [link](https://example.com).

        [Child Page](Child-Page.md)

        [Fragmented](Other.md#x7f3q2)

        - bullet
          - nested
        1. first
        1. second
        - [ ] todo
        - [x] done

        > quote

        ```swift
        let x = 1
        ```

        | a | b |
        | --- | --- |
        | 1 | 2 |

        #### Deep Heading

        ##### Deeper

        ###### Deepest

        ---

        ![alt text](Assets/img.png)

        """
        let serialized = BlockSerializer.serialize(BlockParser.parse(source))
        #expect(
            serialized.trimmingCharacters(in: .newlines) == source.trimmingCharacters(in: .newlines)
        )
        assertIdempotent(source)
    }

    @Test func aFormattedLinkLabelSurvives() {
        // The parser used to read only direct text children of a link, so a
        // formatted label produced an empty title and fell back to showing the
        // raw path.
        let source = "[**Bold Name**](Target.md)\n"
        let blocks = BlockParser.parse(source)
        guard case .documentLink(let label, let reference) = blocks.first?.kind else {
            Issue.record("expected a document link, got \(String(describing: blocks.first?.kind))")
            return
        }
        #expect(String(label.characters) == "Bold Name")
        #expect(reference.rawValue == "Target.md")
        #expect(BlockSerializer.serialize(blocks).contains("[**Bold Name**](Target.md)"))
    }

    // MARK: - Stale link labels

    /// A subpage row stores the target's title at the time it was written, so
    /// it goes stale when the target is renamed. Full-page serialization
    /// resolves the live title; the atomic recovery snapshot deliberately does
    /// not, because it is filed under a hash derived from the block alone and
    /// has to serialize the same way every time.
    @Test func fullSerializationResolvesTheLiveTitle() {
        let block = Block.documentLink(label: AttributedString("Old Name"), reference: DocumentReference("target.md"))
        let serialized = BlockSerializer.serialize(
            [block],
            resolvingSubpageTitle: { $0 == "target.md" ? "New Name" : nil }
        )
        #expect(serialized.contains("[New Name](target.md)"))
    }

    @Test func fullSerializationFallsBackToTheStoredTitleWhenUnresolved() {
        let block = Block.documentLink(label: AttributedString("Old Name"), reference: DocumentReference("target.md"))
        let serialized = BlockSerializer.serialize([block], resolvingSubpageTitle: { _ in nil })
        #expect(serialized.contains("[Old Name](target.md)"))
    }

    @Test func atomicSnapshotKeepsTheStoredTitleForDeterminism() {
        let block = Block.documentLink(label: AttributedString("Old Name"), reference: DocumentReference("target.md"))
        #expect(BlockSerializer.serializeAtomic(block).contains("[Old Name](target.md)"))
    }

    // MARK: - Content this editor has no model for

    /// A table is not representable as blocks here, and used to be flattened
    /// into a paragraph of re-rendered text — which the serializer then wrote
    /// back as an escaped paragraph. Opening a document containing a table and
    /// saving it destroyed the table.
    @Test func tableSurvivesByteForByte() {
        let table = "| a | b |\n| --- | --- |\n| 1 | 2 |"
        let source = "# Title\n\n\(table)\n\ntrailing\n"

        let blocks = BlockParser.parse(source)
        let serialized = BlockSerializer.serialize(blocks)

        #expect(serialized.contains(table), "the table must come back out exactly as it went in")
        #expect(serialized.contains("trailing"))
        assertIdempotent(source)
    }

    @Test func tableParsesAsAnUnsupportedBlockNotAParagraph() {
        let blocks = BlockParser.parse("| a | b |\n| --- | --- |\n| 1 | 2 |\n")
        #expect(blocks.count == 1)
        guard case .unsupported(let payload, let display) = blocks[0].kind else {
            Issue.record("expected .unsupported, got \(blocks[0].kind)")
            return
        }
        #expect(payload == "| a | b |\n| --- | --- |\n| 1 | 2 |")
        #expect(display == "Table")
    }

    /// The payload is the source slice, not `MarkupFormatter` output. A table
    /// with ragged column padding proves the difference: reformatting would
    /// align the pipes.
    @Test func unsupportedPayloadIsSourceNotReformattedOutput() {
        let ragged = "|a|bbbbbb|\n|-|-|\n|1|2|"
        let blocks = BlockParser.parse(ragged + "\n")
        guard case .unsupported(let payload, _) = blocks.first?.kind else {
            Issue.record("expected .unsupported")
            return
        }
        #expect(payload == ragged)
    }

    @Test func rawHTMLBlockSurvives() {
        let html = "<figure class=\"x\">\n  <img src=\"a.png\">\n</figure>"
        let source = "before\n\n\(html)\n\nafter\n"
        let serialized = BlockSerializer.serialize(BlockParser.parse(source))
        #expect(serialized.contains(html))
        assertIdempotent(source)
    }

    /// The point of preserving it: editing an unrelated block must not disturb
    /// the parts of the document this editor cannot represent.
    @MainActor
    @Test func tableSurvivesAnEditElsewhere() {
        let table = "| a | b |\n| --- | --- |\n| 1 | 2 |"
        let blocks = BlockParser.parse("# Title\n\n\(table)\n\nbody\n")

        let document = Document(id: DocumentID("t"), children: blocks)
        var bodyID: BlockID?
        document.walk { block, _, _ in
            if String(block.text.characters) == "body" { bodyID = block.id }
        }
        document.transaction(name: "edit") {
            if let bodyID { document.setText(bodyID, AttributedString("body edited")) }
        }

        let serialized = BlockSerializer.serialize(document.children)
        #expect(serialized.contains(table))
        #expect(serialized.contains("body edited"))
    }

    /// Read-only, but a first-class block otherwise: it can be selected, moved,
    /// and deleted like anything else, and it participates in the recovery log.
    @Test func unsupportedBlockIsALeafThatAcceptsNoChildren() {
        let block = Block.unsupported(payload: "| a |", display: "Table")
        #expect(block.isLeaf)
        #expect(!block.isContainer)
        #expect(!block.canContain(.paragraph(text: AttributedString("x"))))
        #expect(String(block.text.characters).isEmpty)
        #expect(block.withText(AttributedString("nope")) == block, "text edits are a no-op")
    }

    // MARK: - H4–H6 survive

    /// Every level cmark can emit must come back out at the depth it went in.
    /// Before HeadingLevel covered 1–6, an H4 parsed as H3 and the serializer
    /// wrote `###` back — so opening a document with deep headings and touching
    /// anything at all silently rewrote it.
    @Test func allSixHeadingLevelsRoundTrip() {
        let source = "# One\n\n## Two\n\n### Three\n\n#### Four\n\n##### Five\n\n###### Six\n"
        let serialized = BlockSerializer.serialize(BlockParser.parse(source))
        // Trailing blank lines are the serializer's normal block separator and
        // are not what this test is about; the heading markers are.
        #expect(
            serialized.trimmingCharacters(in: .newlines) == source.trimmingCharacters(in: .newlines)
        )
        assertIdempotent(source)
    }

    @Test func deepHeadingLevelsParseAtTheirTrueDepth() {
        let blocks = BlockParser.parse("#### Four\n\n##### Five\n\n###### Six\n")
        // Heading containment nests them: H5 under H4, H6 under H5.
        #expect(blocks.count == 1)
        #expect(blocks[0].headingLevel == .h4)
        #expect(blocks[0].children.first?.headingLevel == .h5)
        #expect(blocks[0].children.first?.children.first?.headingLevel == .h6)
    }

    /// The point of preserving them: editing something else in the document
    /// must not disturb the heading depths on the way back to disk.
    @MainActor
    @Test func deepHeadingsSurviveAnEditElsewhere() {
        let source = "# Title\n\n#### Four\n\nbody\n"
        var blocks = BlockParser.parse(source)

        let document = Document(id: DocumentID("t"), children: blocks)
        var bodyID: BlockID?
        document.walk { block, _, _ in
            if String(block.text.characters) == "body" { bodyID = block.id }
        }
        #expect(bodyID != nil)
        document.transaction(name: "edit") {
            if let bodyID { document.setText(bodyID, AttributedString("body edited")) }
        }
        blocks = document.children

        let serialized = BlockSerializer.serialize(blocks)
        #expect(serialized.contains("#### Four"))
        #expect(!serialized.contains("\n### Four"))
        #expect(serialized.contains("body edited"))
    }

    @Test func headingLevelSixNestsUnderFive() {
        assertIdempotent("##### Five\n\n###### Six\n\nbody\n")
    }

    @Test func bulletAndNestedList() {
        assertIdempotent("- one\n  - nested\n- two\n")
    }

    @Test func bulletAndNestedListSerializeTight() {
        let tree = [
            Block.bullet(
                text: AttributedString("one"),
                children: [.bullet(text: AttributedString("nested"))]
            ),
            Block.bullet(text: AttributedString("two")),
        ]
        #expect(BlockSerializer.serialize(tree) == "- one\n  - nested\n- two\n")
    }

    @Test func numberedList() {
        assertIdempotent("1. first\n1. second\n")
    }

    @Test func todoList() {
        assertIdempotent("- [ ] open\n- [x] done\n")
    }

    @Test func emptyParagraphSerializesAsExtraBlankLine() {
        let tree = [
            Block.paragraph(text: AttributedString("before")),
            Block.paragraph(text: AttributedString("")),
            Block.paragraph(text: AttributedString("after")),
        ]
        let serialized = BlockSerializer.serialize(tree)
        #expect(serialized == "before\n\n\nafter\n\n")
        #expect(!serialized.contains("\u{00A0}"))

        let reparsed = BlockParser.parse(serialized)
        #expect(reparsed.count == 3)
        guard case .paragraph(let empty) = reparsed[1].kind else {
            Issue.record("expected empty paragraph in the middle")
            return
        }
        #expect(String(empty.characters).isEmpty)
    }

    @Test func emptyParagraphBetweenListItemsRoundTrips() {
        let tree = [
            Block.bullet(text: AttributedString("before")),
            Block.paragraph(text: AttributedString("")),
            Block.bullet(text: AttributedString("after")),
        ]
        let serialized = BlockSerializer.serialize(tree)
        #expect(serialized == "- before\n\n\n- after\n")
        let reparsed = BlockParser.parse(serialized)
        #expect(reparsed.count == 3)
        if case .paragraph(let text) = reparsed[1].kind {
            #expect(String(text.characters).isEmpty)
        } else {
            Issue.record("expected empty paragraph between list items")
        }
    }

    @Test func consecutiveEmptyParagraphsRoundTrip() {
        let tree = [
            Block.paragraph(text: AttributedString("before")),
            Block.paragraph(text: AttributedString("")),
            Block.paragraph(text: AttributedString("")),
            Block.paragraph(text: AttributedString("after")),
        ]
        let serialized = BlockSerializer.serialize(tree)
        #expect(serialized == "before\n\n\n\nafter\n\n")
        let reparsed = BlockParser.parse(serialized)
        #expect(reparsed.count == 4)
        for index in 1...2 {
            if case .paragraph(let text) = reparsed[index].kind {
                #expect(String(text.characters).isEmpty)
            } else {
                Issue.record("expected empty paragraph at index \(index)")
            }
        }
    }

    @Test func emptyParagraphAfterToggleRoundTrips() {
        let tree = [
            Block.toggle(
                title: AttributedString("before"),
                children: [.bullet(text: AttributedString("child"))]
            ),
            Block.paragraph(text: AttributedString("")),
            Block.toggle(
                title: AttributedString("after"),
                children: [.bullet(text: AttributedString("child"))]
            ),
        ]
        let serialized = BlockSerializer.serialize(tree)
        #expect(serialized == "▸ before\n  - child\n\n\n▸ after\n  - child\n")
        let reparsed = BlockParser.parse(serialized)
        #expect(reparsed.count == 3)
        if case .paragraph(let text) = reparsed[1].kind {
            #expect(String(text.characters).isEmpty)
        } else {
            Issue.record("expected empty paragraph between toggles")
        }
    }

    @Test func legacyNBSPEmptyParagraphStillParses() {
        let blocks = BlockParser.parse("before\n\n\u{00A0}\n\nafter\n")
        #expect(blocks.count == 3)
        if case .paragraph(let text) = blocks[1].kind {
            #expect(String(text.characters).isEmpty)
        } else {
            Issue.record("expected empty paragraph from NBSP marker")
        }
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

    @Test func siblingTogglesSerializeTight() {
        let tree = [
            Block.toggle(
                title: AttributedString("One"),
                children: [.bullet(text: AttributedString("a"))]
            ),
            Block.toggle(
                title: AttributedString("Two"),
                children: [.bullet(text: AttributedString("b"))]
            ),
        ]
        let serialized = BlockSerializer.serialize(tree)
        #expect(serialized == "▸ One\n  - a\n▸ Two\n  - b\n")
        let reparsed = BlockParser.parse(serialized)
        #expect(reparsed.count == 2)
        #expect(reparsed.allSatisfy {
            if case .toggle = $0.kind { return true }
            return false
        })
    }

    @Test func bulletWithToggleChildrenRoundTripsTree() {
        let tree = [
            Block.bullet(
                text: AttributedString("Next steps with writing"),
                children: [
                    .toggle(
                        title: AttributedString("FFF"),
                        children: [.bullet(text: AttributedString("enter edits"))]
                    ),
                    .toggle(
                        title: AttributedString("Valuation"),
                        children: [.bullet(text: AttributedString("get flow right"))]
                    ),
                    .toggle(
                        title: AttributedString("Change"),
                        children: [.bullet(text: AttributedString("review sections"))]
                    ),
                ]
            ),
            Block.bullet(text: AttributedString("Look through social and berlin")),
        ]
        let serialized = BlockSerializer.serialize(tree)
        #expect(serialized == """
        - Next steps with writing
          ▸ FFF
            - enter edits
          ▸ Valuation
            - get flow right
          ▸ Change
            - review sections
        - Look through social and berlin
        """ + "\n")

        let reparsed = BlockParser.parse(serialized)
        #expect(reparsed.count == 2)
        guard case .bullet(let text) = reparsed[0].kind else {
            Issue.record("expected leading bullet")
            return
        }
        #expect(String(text.characters) == "Next steps with writing")
        #expect(reparsed[0].children.count == 3)
        #expect(reparsed[0].children.allSatisfy {
            if case .toggle = $0.kind { return true }
            return false
        })
    }

    @Test func blankLineAfterBulletWithToggleChildrenRoundTrips() {
        let tree = [
            Block.bullet(
                text: AttributedString("Next steps with writing"),
                children: [
                    .toggle(
                        title: AttributedString("FFF"),
                        children: [.bullet(text: AttributedString("enter edits"))]
                    ),
                    .toggle(
                        title: AttributedString("Change"),
                        children: [.bullet(text: AttributedString("review sections"))]
                    ),
                ]
            ),
            Block.paragraph(text: AttributedString("")),
            Block.bullet(text: AttributedString("Look through social and berlin")),
        ]
        let serialized = BlockSerializer.serialize(tree)
        #expect(serialized == """
        - Next steps with writing
          ▸ FFF
            - enter edits
          ▸ Change
            - review sections


        - Look through social and berlin
        """ + "\n")

        let reparsed = BlockParser.parse(serialized)
        #expect(reparsed.count == 3)
        if case .paragraph(let text) = reparsed[1].kind {
            #expect(String(text.characters).isEmpty)
        } else {
            Issue.record("expected empty paragraph after nested toggles")
        }
    }

    @Test func indentedToggleSourceKeepsFollowingBlankLine() {
        let blocks = BlockParser.parse("""
        - Next steps with writing
          ▸ FFF
            - enter edits
          ▸ Change
            - review sections


        - Look through social and berlin
        """)
        #expect(blocks.count == 3)
        guard case .bullet(let text) = blocks[0].kind else {
            Issue.record("expected leading bullet")
            return
        }
        #expect(String(text.characters) == "Next steps with writing")
        #expect(blocks[0].children.count == 2)
        if case .paragraph(let empty) = blocks[1].kind {
            #expect(String(empty.characters).isEmpty)
        } else {
            Issue.record("expected empty paragraph after nested toggles")
        }
    }

    @Test func indentedToggleSourceStaysUnderListItem() {
        let blocks = BlockParser.parse("""
        - Next steps with writing
          ▸ FFF
            - enter edits
          ▸ Valuation
            - get flow right
        - Look through social and berlin
        """)
        #expect(blocks.count == 2)
        guard case .bullet(let text) = blocks[0].kind else {
            Issue.record("expected leading bullet")
            return
        }
        #expect(String(text.characters) == "Next steps with writing")
        #expect(blocks[0].children.count == 2)
        #expect(blocks[0].children.allSatisfy {
            if case .toggle = $0.kind { return true }
            return false
        })
    }

    @Test func indentedSiblingAfterToggleStaysUnderListItem() {
        let blocks = BlockParser.parse("""
        - foo
          - bar
          ▸ toggle
          - baz
        """)
        #expect(blocks.count == 1)
        guard case .bullet(let text) = blocks[0].kind else {
            Issue.record("expected root bullet")
            return
        }
        #expect(String(text.characters) == "foo")
        #expect(blocks[0].children.count == 3)
        if case .bullet(let bar) = blocks[0].children[0].kind {
            #expect(String(bar.characters) == "bar")
        } else {
            Issue.record("expected first child bullet")
        }
        if case .toggle(let title) = blocks[0].children[1].kind {
            #expect(String(title.characters) == "toggle")
        } else {
            Issue.record("expected toggle child")
        }
        if case .bullet(let baz) = blocks[0].children[2].kind {
            #expect(String(baz.characters) == "baz")
        } else {
            Issue.record("expected following child bullet to remain indented")
        }
    }

    @Test func bulletWithListToggleListChildrenRoundTripsTree() {
        let tree = [
            Block.bullet(
                text: AttributedString("foo"),
                children: [
                    .bullet(text: AttributedString("bar")),
                    .toggle(title: AttributedString("toggle")),
                    .bullet(text: AttributedString("baz")),
                ]
            ),
        ]
        let serialized = BlockSerializer.serialize(tree)
        #expect(serialized == """
        - foo
          - bar

          ▸ toggle

          - baz
        """ + "\n")
        let reparsed = BlockParser.parse(serialized)
        #expect(reparsed.count == 1)
        #expect(reparsed[0].children.count == 3)
        if case .bullet(let baz) = reparsed[0].children[2].kind {
            #expect(String(baz.characters) == "baz")
        } else {
            Issue.record("expected following child bullet to remain indented")
        }
    }

    @Test func templateButtonWithBody() {
        assertIdempotent(":::{template-button} Add Task\n- [ ] new\n:::\n")
    }

    @Test func subpageLink() {
        assertIdempotent("[Other Page](other.md)\n")
    }

    @Test func bareExternalURLLoadsAsInlineLink() {
        let blocks = BlockParser.parse("Visit https://example.com/docs today.\n")
        #expect(blocks.count == 1)
        guard case .paragraph(let text) = blocks[0].kind else {
            Issue.record("expected paragraph")
            return
        }

        let linkedRuns = text.runs.filter { $0.link?.absoluteString == "https://example.com/docs" }
        #expect(linkedRuns.count == 1)
        if let run = linkedRuns.first {
            #expect(String(text[run.range].characters) == "https://example.com/docs")
        }
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
    /// nested-child structure intact. The serializer emits the tight form and
    /// the parser peels the indented `.md` link back out of the leading
    /// paragraph.
    @Test func bulletWithSubpageChildRoundTripsTree() {
        let tree = [Block.bullet(
            text: AttributedString("Foo bullet"),
            children: [.documentLink(label: AttributedString("Subpage"), reference: DocumentReference("Subpage.md"))]
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
        guard case .documentLink(_, let pageID) = reparsed[0].children[0].kind else {
            Issue.record("expected .subpage child, got \(reparsed[0].children[0].kind)")
            return
        }
        #expect(pageID.rawValue == "Subpage.md")
    }

    @Test func bulletWithSubpageChildIdempotent() {
        assertIdempotent("- Foo bullet\n  [Subpage](Subpage.md)\n")
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
        guard case .documentLink(_, let pageID) = blocks[0].children[0].kind else {
            Issue.record("expected .subpage child, got \(blocks[0].children[0].kind)")
            return
        }
        #expect(pageID.rawValue == "Subpage.md")
    }

    /// Numbered items have a 3-char marker (`1. `), so children indent to
    /// column 3 — same content-column rule that keeps bullets working.
    @Test func numberedWithSubpageChildRoundTripsTree() {
        let tree = [Block.numbered(
            text: AttributedString("Foo"),
            children: [.documentLink(label: AttributedString("Sub"), reference: DocumentReference("sub.md"))]
        )]
        let reparsed = BlockParser.parse(BlockSerializer.serialize(tree))
        #expect(reparsed.count == 1)
        guard case .numbered = reparsed[0].kind else {
            Issue.record("expected .numbered root, got \(reparsed[0].kind)")
            return
        }
        #expect(reparsed[0].children.count == 1)
        if case .documentLink(_, let pageID) = reparsed[0].children[0].kind {
            #expect(pageID.rawValue == "sub.md")
        } else {
            Issue.record("expected .subpage child")
        }
    }

    @Test func numberedWithSubpageChildIdempotent() {
        assertIdempotent("1. Foo\n   [Sub](sub.md)\n")
    }

    /// Todos render `- [ ] ` but in GFM the list marker itself is just `- ` —
    /// the `[ ]` is content. Children indent to column 2, same as a bullet.
    @Test func todoWithSubpageChildRoundTripsTree() {
        let tree = [Block.todo(
            text: AttributedString("Foo"),
            done: false,
            children: [.documentLink(label: AttributedString("Sub"), reference: DocumentReference("sub.md"))]
        )]
        let reparsed = BlockParser.parse(BlockSerializer.serialize(tree))
        #expect(reparsed.count == 1)
        guard case .todo = reparsed[0].kind else {
            Issue.record("expected .todo root, got \(reparsed[0].kind)")
            return
        }
        #expect(reparsed[0].children.count == 1)
        if case .documentLink(_, let pageID) = reparsed[0].children[0].kind {
            #expect(pageID.rawValue == "sub.md")
        } else {
            Issue.record("expected .subpage child")
        }
    }

    @Test func todoWithSubpageChildIdempotent() {
        assertIdempotent("- [ ] Foo\n  [Sub](sub.md)\n")
    }

    // MARK: - Consecutive numbering (pasteboard path)

    /// Default flag preserves the on-disk `1. 1. 1.` form — load-bearing
    /// for minimal git diffs on insert/delete in the middle of a list.
    @Test func numberedListDefaultStaysAtOne() {
        let tree = [
            Block.numbered(text: AttributedString("a")),
            Block.numbered(text: AttributedString("b")),
            Block.numbered(text: AttributedString("c")),
        ]
        #expect(BlockSerializer.serialize(tree) == "1. a\n1. b\n1. c\n")
    }

    /// Pasteboard flag renumbers a run of consecutive `.numbered` siblings
    /// so external markdown / plain-text consumers render `1. 2. 3.`.
    @Test func numberedListConsecutiveFlagRenumbers() {
        let tree = [
            Block.numbered(text: AttributedString("a")),
            Block.numbered(text: AttributedString("b")),
            Block.numbered(text: AttributedString("c")),
        ]
        #expect(BlockSerializer.serialize(tree, consecutiveNumbering: true) == "1. a\n2. b\n3. c\n")
    }

    /// A non-numbered block between runs resets the counter.
    @Test func numberedListInterleavedResetsCounter() {
        let tree: [Block] = [
            .numbered(text: AttributedString("a")),
            .numbered(text: AttributedString("b")),
            .paragraph(text: AttributedString("break")),
            .numbered(text: AttributedString("c")),
            .numbered(text: AttributedString("d")),
        ]
        let out = BlockSerializer.serialize(tree, consecutiveNumbering: true)
        #expect(out == "1. a\n2. b\n\nbreak\n\n1. c\n2. d\n")
    }

    /// Double-digit indices need their child indent to widen to the
    /// marker width so a nested block stays inside the list item on
    /// re-parse. Build 10 numbered items where #10 has a paragraph child;
    /// re-parse must preserve the child relationship.
    @Test func numberedListDoubleDigitChildIndents() {
        var tree: [Block] = []
        for i in 1...9 {
            tree.append(.numbered(text: AttributedString("item \(i)")))
        }
        tree.append(.numbered(
            text: AttributedString("item 10"),
            children: [.paragraph(text: AttributedString("nested"))]
        ))
        let serialized = BlockSerializer.serialize(tree, consecutiveNumbering: true)
        let reparsed = BlockParser.parse(serialized)
        #expect(reparsed.count == 10)
        guard case .numbered = reparsed[9].kind else {
            Issue.record("expected .numbered as item 10, got \(reparsed[9].kind)")
            return
        }
        #expect(reparsed[9].children.count == 1, "item 10 should retain its nested paragraph; got \(reparsed[9].children.count) children — child indent likely under-counted for `10. `")
    }
}
