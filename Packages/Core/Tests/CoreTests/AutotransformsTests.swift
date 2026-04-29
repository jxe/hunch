import Testing
import Foundation
@testable import Core

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

@Suite("BlockTransform.apply")
struct BlockTransformApplyTests {
    private func attr(_ s: String) -> AttributedString { AttributedString(s) }

    @Test func headingProducesHeadingBlock() {
        let blocks = BlockTransform.heading(level: 2).apply(to: attr("Section"))
        #expect(blocks.count == 1)
        if case .heading(_, let level, let text) = blocks[0] {
            #expect(level == 2)
            #expect(String(text.characters) == "Section")
        } else {
            Issue.record("expected heading")
        }
    }

    @Test func bulletProducesBulletAtIndentZero() {
        let blocks = BlockTransform.bullet.apply(to: attr("item"))
        #expect(blocks.count == 1)
        if case .bullet(_, let text, let indent) = blocks[0] {
            #expect(String(text.characters) == "item")
            #expect(indent == 0)
        } else {
            Issue.record("expected bullet")
        }
    }

    @Test func numberedProducesNumbered() {
        let blocks = BlockTransform.numbered.apply(to: attr("first"))
        if case .numbered(_, let text, let indent) = blocks[0] {
            #expect(String(text.characters) == "first")
            #expect(indent == 0)
        } else {
            Issue.record("expected numbered")
        }
    }

    @Test func todoUnchecked() {
        let blocks = BlockTransform.todo.apply(to: attr("buy milk"))
        if case .todo(_, let text, let done, _) = blocks[0] {
            #expect(String(text.characters) == "buy milk")
            #expect(done == false)
        } else {
            Issue.record("expected todo")
        }
    }

    @Test func quote() {
        let blocks = BlockTransform.quote.apply(to: attr("said it"))
        if case .quote(_, let text) = blocks[0] {
            #expect(String(text.characters) == "said it")
        } else {
            Issue.record("expected quote")
        }
    }

    @Test func toggleCollapsedNoChildren() {
        let blocks = BlockTransform.toggle.apply(to: attr("Details"))
        if case .toggle(_, let title, let expanded, let children) = blocks[0] {
            #expect(String(title.characters) == "Details")
            #expect(expanded == false)
            #expect(children.isEmpty)
        } else {
            Issue.record("expected toggle")
        }
    }

    @Test func dividerProducesTwoBlocks() {
        let blocks = BlockTransform.divider.apply(to: attr(""))
        #expect(blocks.count == 2)
        if case .divider = blocks[0] {} else { Issue.record("expected divider at 0") }
        if case .paragraph(_, let text) = blocks[1] {
            #expect(String(text.characters) == "")
        } else {
            Issue.record("expected paragraph at 1")
        }
        #expect(blocks[0].id != blocks[1].id)
    }

    @Test func codeFenceProducesTwoBlocks() {
        let blocks = BlockTransform.codeFence.apply(to: attr(""))
        #expect(blocks.count == 2)
        if case .code(_, let source, let language) = blocks[0] {
            #expect(source == "")
            #expect(language == nil)
        } else {
            Issue.record("expected code at 0")
        }
        if case .paragraph = blocks[1] {} else { Issue.record("expected paragraph at 1") }
    }

    @Test func focusReplacementIndex() {
        #expect(BlockTransform.heading(level: 1).focusReplacementIndex == 0)
        #expect(BlockTransform.bullet.focusReplacementIndex == 0)
        #expect(BlockTransform.divider.focusReplacementIndex == 1)
        #expect(BlockTransform.codeFence.focusReplacementIndex == 1)
    }
}
