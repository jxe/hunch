import Testing
import Foundation
@testable import Editor

private func plain(_ result: AutotransformResult?) -> String {
    guard let result else { return "<nil>" }
    return String(result.remainingText.characters)
}

@Suite("Markdown autotransforms — prefix detection")
struct PrefixAutotransformTests {
    private func detect(_ s: String, cursor: Int? = nil) -> AutotransformResult? {
        detectPrefixAutotransform(text: AttributedString(s), cursor: cursor ?? s.count)
    }

    @Test func headingOne() {
        let r = detect("# ")
        #expect(r?.transform == .heading(level: 1))
        #expect(plain(r) == "")
    }

    @Test func headingTwo() {
        let r = detect("## ")
        #expect(r?.transform == .heading(level: 2))
    }

    @Test func headingThree() {
        let r = detect("### ")
        #expect(r?.transform == .heading(level: 3))
    }

    @Test func headingCarriesRemainingText() {
        let r = detectPrefixAutotransform(text: AttributedString("# Hello world"), cursor: 2)
        #expect(r?.transform == .heading(level: 1))
        #expect(plain(r) == "Hello world")
    }

    @Test func bulletDash() {
        let r = detect("- ")
        #expect(r?.transform == .bullet)
    }

    @Test func bulletStar() {
        let r = detect("* ")
        #expect(r?.transform == .bullet)
    }

    @Test func dividerOnThirdDash() {
        let r = detect("---")
        #expect(r?.transform == .divider)
        #expect(plain(r) == "")
    }

    @Test func numbered() {
        let r = detect("1. ")
        #expect(r?.transform == .numbered)
    }

    @Test func todoEmpty() {
        let r = detect("[] ")
        #expect(r?.transform == .todo)
    }

    @Test func todoSpaced() {
        let r = detect("[ ] ")
        #expect(r?.transform == .todo)
    }

    @Test func toggle() {
        let r = detect("> ")
        #expect(r?.transform == .toggle)
    }

    @Test func quoteStraight() {
        let r = detect("\" ")
        #expect(r?.transform == .quote)
    }

    @Test func quoteCurly() {
        // U+201C LEFT DOUBLE QUOTATION MARK — what NSTextView's smart-quote
        // substitution produces from a typed `"`.
        let r = detect("\u{201C} ")
        #expect(r?.transform == .quote)
    }

    @Test func negativeNoTrailingSpace() {
        #expect(detect("#", cursor: 1) == nil)
        #expect(detect("-", cursor: 1) == nil)
        #expect(detect("[]", cursor: 2) == nil)
    }

    @Test func negativeTriggerNotAtStart() {
        let r = detectPrefixAutotransform(text: AttributedString("hello # world"), cursor: 8)
        #expect(r == nil)
    }

    @Test func negativeCursorPastTriggerEnd() {
        // user typed past the prefix — too late.
        let r = detectPrefixAutotransform(text: AttributedString("# hello"), cursor: 7)
        #expect(r == nil)
    }

    @Test func negativeCursorBeforeTriggerEnd() {
        let r = detectPrefixAutotransform(text: AttributedString("## "), cursor: 1)
        #expect(r == nil)
    }

    @Test func negativeUnrelatedText() {
        #expect(detect("hello", cursor: 5) == nil)
        #expect(detect("", cursor: 0) == nil)
    }

    // MARK: - Inline-mark preservation

    @Test func preservesBoldInRemaining() {
        // Type "hello", bold "hello", then prefix with "* " → bullet autotransform.
        // The bolded "hello" must ride through to the new block's text.
        var attr = AttributedString("* hello")
        let boldStart = attr.index(attr.startIndex, offsetByCharacters: 2)
        attr[boldStart..<attr.endIndex][InlineAttributes.BoldAttribute.self] = true
        let r = detectPrefixAutotransform(text: attr, cursor: 2)
        #expect(r?.transform == .bullet)
        #expect(plain(r) == "hello")
        let hasBold = r?.remainingText.runs.contains { $0[InlineAttributes.BoldAttribute.self] == true } ?? false
        #expect(hasBold)
    }

    @Test func preservesItalicInRemaining() {
        var attr = AttributedString("# heading")
        let italicStart = attr.index(attr.startIndex, offsetByCharacters: 2)
        attr[italicStart..<attr.endIndex][InlineAttributes.ItalicAttribute.self] = true
        let r = detectPrefixAutotransform(text: attr, cursor: 2)
        #expect(r?.transform == .heading(level: 1))
        let hasItalic = r?.remainingText.runs.contains { $0[InlineAttributes.ItalicAttribute.self] == true } ?? false
        #expect(hasItalic)
    }

    @Test func preservesLinkInRemaining() {
        var attr = AttributedString("- see docs")
        let linkStart = attr.index(attr.startIndex, offsetByCharacters: 6)
        attr[linkStart..<attr.endIndex].link = URL(string: "https://example.com")
        let r = detectPrefixAutotransform(text: attr, cursor: 2)
        #expect(r?.transform == .bullet)
        let hasLink = r?.remainingText.runs.contains { $0.link?.absoluteString == "https://example.com" } ?? false
        #expect(hasLink)
    }
}

@Suite("Markdown autotransforms — Enter detection")
struct EnterAutotransformTests {
    @Test func divider() {
        let r = detectEnterAutotransform(text: AttributedString("---"))
        #expect(r?.transform == .divider)
    }

    @Test func codeFence() {
        let r = detectEnterAutotransform(text: AttributedString("```"))
        #expect(r?.transform == .codeFence)
    }

    @Test func negativeWithTrailingText() {
        #expect(detectEnterAutotransform(text: AttributedString("--- foo")) == nil)
        #expect(detectEnterAutotransform(text: AttributedString("```swift")) == nil)
    }

    @Test func negativeShorterRunOfDashes() {
        #expect(detectEnterAutotransform(text: AttributedString("--")) == nil)
        #expect(detectEnterAutotransform(text: AttributedString("``")) == nil)
    }

    @Test func negativeEmpty() {
        #expect(detectEnterAutotransform(text: AttributedString("")) == nil)
    }
}

@Suite("Markdown autotransforms — inline style detection")
struct InlineStyleAutotransformTests {
    private func detect(_ s: String, cursor: Int? = nil) -> InlineAutotransformResult? {
        detectInlineStyleAutotransform(text: AttributedString(s), cursor: cursor ?? s.count)
    }

    private func plain(_ result: InlineAutotransformResult?) -> String {
        guard let result else { return "<nil>" }
        return String(result.text.characters)
    }

    @Test func bold() {
        let r = detect("say **hello**")
        #expect(plain(r) == "say hello")
        #expect(r?.cursor == 9)
        let hasBold = r?.text.runs.contains { $0[InlineAttributes.BoldAttribute.self] == true } ?? false
        #expect(hasBold)
    }

    @Test func italicStarAndUnderscore() {
        let star = detect("*hello*")
        #expect(plain(star) == "hello")
        #expect(star?.text.runs.contains { $0[InlineAttributes.ItalicAttribute.self] == true } == true)

        let underscore = detect("_hello_")
        #expect(plain(underscore) == "hello")
        #expect(underscore?.text.runs.contains { $0[InlineAttributes.ItalicAttribute.self] == true } == true)
    }

    @Test func code() {
        let r = detect("use `let x = 1`")
        #expect(plain(r) == "use let x = 1")
        #expect(r?.text.runs.contains { $0[InlineAttributes.CodeAttribute.self] == true } == true)
    }

    @Test func strikethrough() {
        let r = detect("~~done~~")
        #expect(plain(r) == "done")
        #expect(r?.text.runs.contains { $0[InlineAttributes.StrikethroughAttribute.self] == true } == true)
    }

    @Test func linkAllowsRelativeURL() {
        let r = detect("See [Docs](pages/docs.md)")
        #expect(plain(r) == "See Docs")
        #expect(r?.cursor == 8)
        #expect(r?.text.runs.contains { $0.link?.relativeString == "pages/docs.md" } == true)
    }

    @Test func preservesExistingInnerMarksAndSuffix() {
        var text = AttributedString("Say **hello** now")
        let innerStart = text.index(text.startIndex, offsetByCharacters: 6)
        let innerEnd = text.index(text.startIndex, offsetByCharacters: 11)
        text[innerStart..<innerEnd][InlineAttributes.ItalicAttribute.self] = true

        let r = detectInlineStyleAutotransform(text: text, cursor: 13)
        #expect(plain(r) == "Say hello now")
        #expect(r?.cursor == 9)
        #expect(r?.text.runs.contains {
            $0[InlineAttributes.BoldAttribute.self] == true &&
            $0[InlineAttributes.ItalicAttribute.self] == true
        } == true)
    }

    @Test func negativeEmptySpanAndBoldDoesNotBecomeItalic() {
        #expect(detect("****") == nil)
        let r = detect("**hello**")
        #expect(r?.text.runs.contains { $0[InlineAttributes.ItalicAttribute.self] == true } == false)
    }
}

@Suite("BlockTransform.apply")
struct BlockTransformApplyTests {
    private func attr(_ s: String) -> AttributedString { AttributedString(s) }

    @Test func headingProducesHeadingBlock() {
        let blocks = BlockTransform.heading(level: 2).apply(to: attr("Section"))
        #expect(blocks.count == 1)
        if case .heading(let level, let text) = blocks[0].kind {
            #expect(level == .h2)
            #expect(String(text.characters) == "Section")
        } else {
            Issue.record("expected heading")
        }
    }

    @Test func bulletProducesBullet() {
        let blocks = BlockTransform.bullet.apply(to: attr("item"))
        #expect(blocks.count == 1)
        if case .bullet(let text) = blocks[0].kind {
            #expect(String(text.characters) == "item")
        } else {
            Issue.record("expected bullet")
        }
    }

    @Test func numberedProducesNumbered() {
        let blocks = BlockTransform.numbered.apply(to: attr("first"))
        if case .numbered(let text) = blocks[0].kind {
            #expect(String(text.characters) == "first")
        } else {
            Issue.record("expected numbered")
        }
    }

    @Test func todoUnchecked() {
        let blocks = BlockTransform.todo.apply(to: attr("buy milk"))
        if case .todo(let text, let done) = blocks[0].kind {
            #expect(String(text.characters) == "buy milk")
            #expect(done == false)
        } else {
            Issue.record("expected todo")
        }
    }

    @Test func quote() {
        let blocks = BlockTransform.quote.apply(to: attr("said it"))
        if case .quote(let text) = blocks[0].kind {
            #expect(String(text.characters) == "said it")
        } else {
            Issue.record("expected quote")
        }
    }

    @Test func toggleProducesToggle() {
        let blocks = BlockTransform.toggle.apply(to: attr("Details"))
        #expect(blocks.count == 1)
        if case .toggle(let title) = blocks[0].kind {
            #expect(String(title.characters) == "Details")
        } else {
            Issue.record("expected toggle")
        }
    }

    @Test func dividerProducesTwoBlocks() {
        let blocks = BlockTransform.divider.apply(to: attr(""))
        #expect(blocks.count == 2)
        if case .divider = blocks[0].kind {} else { Issue.record("expected divider at 0") }
        if case .paragraph(let text) = blocks[1].kind {
            #expect(String(text.characters) == "")
        } else {
            Issue.record("expected paragraph at 1")
        }
        #expect(blocks[0].id != blocks[1].id)
    }

    @Test func codeFenceProducesTwoBlocks() {
        let blocks = BlockTransform.codeFence.apply(to: attr(""))
        #expect(blocks.count == 2)
        if case .code(let source, let language) = blocks[0].kind {
            #expect(source == "")
            #expect(language == nil)
        } else {
            Issue.record("expected code at 0")
        }
        if case .paragraph = blocks[1].kind {} else { Issue.record("expected paragraph at 1") }
    }

    @Test func focusReplacementIndex() {
        #expect(BlockTransform.heading(level: 1).focusReplacementIndex == 0)
        #expect(BlockTransform.bullet.focusReplacementIndex == 0)
        #expect(BlockTransform.divider.focusReplacementIndex == 1)
        #expect(BlockTransform.codeFence.focusReplacementIndex == 1)
    }
}
