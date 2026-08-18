import Testing
import Foundation
@testable import Hunch
import Quagmire

/// The load-bearing invariant that the recovery log + autorestore pipeline
/// rests on: an atomic-block record stored as `m` (atomic markdown) can be
/// parsed back into a `Block` whose `BlockFingerprint.atomicHash` matches the
/// hash recorded as `h`.
///
/// When this holds, the autorestore path is straightforward — after inserting
/// a restored block, the liveness check (`findAtomicHash`) finds it via the
/// same `h`, so the re-fire loop closes itself with no defensive memo.
///
/// When it fails for a kind, the recovery log accumulates spurious churn:
/// restoring `m` produces a block with a different hash, which still looks
/// "lost" on the next pass, and only the `autoRestoredHashes` session memo
/// (a band-aid) prevents an infinite re-insert. This suite is the principled
/// alternative — verify the invariant, then drop the memo.
@Suite("BlockFingerprint atomic round-trip")
struct BlockFingerprintRoundtripTests {

    /// The core property: `hash(parse(serializeAtomic(b))) == hash(b)`.
    /// `name` is included in failure messages so a failing case is identifiable.
    private func assertRoundTrip(_ block: Block, _ name: String) {
        let serialized = BlockSerializer.serializeAtomic(block)
        let reparsed = BlockParser.parse(serialized)
        #expect(reparsed.count == 1,
                "[\(name)] expected exactly one block after re-parse, got \(reparsed.count). Serialized:\n\(serialized)")
        guard let first = reparsed.first else { return }
        let originalHash = block.atomicHash
        let reparsedHash = first.atomicHash
        #expect(originalHash == reparsedHash,
                "[\(name)] hash drift on round-trip. Serialized:\n\(serialized)\nOriginal kind: \(block.kind)\nReparsed kind: \(first.kind)")
    }

    // MARK: - Paragraph

    @Test func paragraphPlain() {
        assertRoundTrip(.paragraph(text: AttributedString("Hello world")), "paragraph plain")
    }

    @Test func paragraphEmpty() {
        // Empty paragraphs serialize as U+00A0 and parse back as empty.
        assertRoundTrip(.paragraph(text: AttributedString()), "paragraph empty")
    }

    @Test func paragraphWhitespaceOnly() {
        // Whitespace-only text normalizes to empty in the hash, but must still
        // round-trip through serialize/parse without splitting the block.
        assertRoundTrip(.paragraph(text: AttributedString("   ")), "paragraph whitespace-only")
    }

    @Test func paragraphWithBoldMark() {
        var bold = AttributeContainer()
        bold.inlineBold = true
        var s = AttributedString("Hello ")
        var b = AttributedString("world")
        b.mergeAttributes(bold)
        s.append(b)
        assertRoundTrip(.paragraph(text: s), "paragraph with bold")
    }

    @Test func paragraphWithItalicMark() {
        var italic = AttributeContainer()
        italic.inlineItalic = true
        var s = AttributedString("plain ")
        var i = AttributedString("emphasized")
        i.mergeAttributes(italic)
        s.append(i)
        assertRoundTrip(.paragraph(text: s), "paragraph with italic")
    }

    @Test func paragraphWithInlineCode() {
        var code = AttributeContainer()
        code.inlineCode = true
        var s = AttributedString("use ")
        var c = AttributedString("foo()")
        c.mergeAttributes(code)
        s.append(c)
        s.append(AttributedString(" today"))
        assertRoundTrip(.paragraph(text: s), "paragraph with inline code")
    }

    @Test func paragraphWithStrikethrough() {
        var strike = AttributeContainer()
        strike.inlineStrikethrough = true
        var s = AttributedString("crossed")
        s.mergeAttributes(strike)
        assertRoundTrip(.paragraph(text: s), "paragraph with strikethrough")
    }

    @Test func paragraphWithLink() {
        var link = AttributeContainer()
        link.link = URL(string: "https://example.com")
        var s = AttributedString("Anthropic")
        s.mergeAttributes(link)
        assertRoundTrip(.paragraph(text: s), "paragraph with link")
    }

    // MARK: - Heading

    @Test func headingH1() {
        assertRoundTrip(.heading(level: .h1, text: AttributedString("Top")), "H1")
    }

    @Test func headingH2() {
        assertRoundTrip(.heading(level: .h2, text: AttributedString("Sub")), "H2")
    }

    @Test func headingH3() {
        assertRoundTrip(.heading(level: .h3, text: AttributedString("Subsub")), "H3")
    }

    @Test func headingWithBoldText() {
        var bold = AttributeContainer()
        bold.inlineBold = true
        var s = AttributedString("Bolded heading")
        s.mergeAttributes(bold)
        assertRoundTrip(.heading(level: .h2, text: s), "heading with bold")
    }

    // MARK: - Lists

    @Test func bulletPlain() {
        assertRoundTrip(.bullet(text: AttributedString("item")), "bullet")
    }

    @Test func bulletWithInlineMarks() {
        var code = AttributeContainer()
        code.inlineCode = true
        var s = AttributedString("call ")
        var c = AttributedString("fn()")
        c.mergeAttributes(code)
        s.append(c)
        assertRoundTrip(.bullet(text: s), "bullet with inline code")
    }

    @Test func numberedPlain() {
        assertRoundTrip(.numbered(text: AttributedString("first")), "numbered")
    }

    @Test func todoOpen() {
        assertRoundTrip(.todo(text: AttributedString("buy milk"), done: false), "todo open")
    }

    @Test func todoDone() {
        assertRoundTrip(.todo(text: AttributedString("buy milk"), done: true), "todo done")
    }

    // MARK: - Quote / divider

    @Test func quoteSingleLine() {
        assertRoundTrip(.quote(text: AttributedString("To be or not to be")), "quote")
    }

    @Test func divider() {
        assertRoundTrip(.divider(), "divider")
    }

    // MARK: - Code

    @Test func codeNoLanguage() {
        assertRoundTrip(.code(source: "let x = 1"), "code no-language")
    }

    @Test func codeWithLanguage() {
        assertRoundTrip(.code(source: "let x = 1", language: "swift"), "code swift")
    }

    @Test func codeMultiline() {
        assertRoundTrip(.code(source: "func f() {\n    return 1\n}", language: "swift"), "code multiline")
    }

    @Test func codeTrailingNewline() {
        // Source with trailing newline — serializer normalizes by adding one
        // when absent; either way the canonical form is the same on read.
        assertRoundTrip(.code(source: "let x = 1\n", language: "swift"), "code trailing newline")
    }

    @Test func codeEmpty() {
        assertRoundTrip(.code(source: "", language: nil), "code empty")
    }

    @Test func codeContainingToggleMarker() {
        // The toggle pre-pass lifts `▸ ` paragraphs to toggle containers but
        // explicitly treats fenced code as opaque. Round-trip must preserve
        // the literal text rather than re-interpret the line as a toggle.
        assertRoundTrip(
            .code(source: "▸ this is text, not a toggle\nstill code", language: nil),
            "code containing toggle marker"
        )
    }

    @Test func codeContainingFenceText() {
        // Three backticks inside the source. The serializer must escape or
        // disambiguate so the fence boundary is unambiguous on re-parse.
        assertRoundTrip(
            .code(source: "let s = \"```\"", language: "swift"),
            "code containing triple backticks"
        )
    }

    // MARK: - Toggle (atomic = title-only; children are not part of the record)

    @Test func togglePlain() {
        assertRoundTrip(.toggle(title: AttributedString("More")), "toggle plain")
    }

    @Test func toggleWithBoldTitle() {
        var bold = AttributeContainer()
        bold.inlineBold = true
        var s = AttributedString("Bolded")
        s.mergeAttributes(bold)
        assertRoundTrip(.toggle(title: s), "toggle bold title")
    }

    // MARK: - Template button

    @Test func templateButtonPlain() {
        assertRoundTrip(.templateButton(label: "Add Task"), "template button")
    }

    @Test func templateButtonEmptyLabel() {
        assertRoundTrip(.templateButton(label: ""), "template button empty label")
    }

    // MARK: - Subpage

    @Test func subpageSimple() {
        assertRoundTrip(
            .documentLink(label: AttributedString("Other Page"), reference: DocumentReference("other.md")),
            "subpage simple"
        )
    }

    @Test func subpageNestedPath() {
        assertRoundTrip(
            .documentLink(label: AttributedString("Nested"), reference: DocumentReference("folder/nested.md")),
            "subpage nested path"
        )
    }

    // MARK: - Image

    @Test func imagePlain() {
        assertRoundTrip(.image(source: "Assets/pic.png", alt: "a picture"), "image plain")
    }

    @Test func imageEmptyAlt() {
        assertRoundTrip(.image(source: "Assets/pic.png", alt: ""), "image empty alt")
    }

    // MARK: - Unicode / canonicalization

    @Test func paragraphWithSmartQuotes() {
        // Smart quotes from NSTextView's auto-substitution. The hash strips
        // inline marks but preserves characters — round-trip must preserve them.
        assertRoundTrip(.paragraph(text: AttributedString("\u{201C}hello\u{201D} world")),
                        "paragraph smart quotes")
    }

    @Test func paragraphWithNonBreakingSpace() {
        // NBSP is meaningful in markdown (it's the empty-paragraph marker but
        // also legal mid-paragraph). The hash normalizes whitespace runs.
        assertRoundTrip(.paragraph(text: AttributedString("foo\u{00A0}bar")),
                        "paragraph with NBSP")
    }

    @Test func paragraphWithEmoji() {
        assertRoundTrip(.paragraph(text: AttributedString("hello 🌍 world")), "paragraph with emoji")
    }

    // MARK: - Whitespace canonicalization invariants

    /// The hash collapses internal whitespace runs to single spaces; round-trip
    /// through markdown (which preserves whitespace inside text runs) must not
    /// change the hash.
    @Test func paragraphInternalWhitespaceRunStable() {
        let block: Block = .paragraph(text: AttributedString("a    b"))
        assertRoundTrip(block, "paragraph internal whitespace")
    }
}
